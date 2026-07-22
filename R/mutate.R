# Plan 09 - R/mutate.R: the mutation layer, the only write door (R-9.1).
#
# `db_append()`/`db_update()`/`db_delete()` are the generic write door:
# explicit `con`, validated table/columns, and one `change_log` row per
# inserted record / changed field / deleted row, written in the *same*
# transaction as the mutation itself (A32: all raw DB writes for core data
# tables live only in this file and db-schema.R).
#
# Transaction participation (needed by commit.R, R-9.2): `db_transaction(con,
# fn)` opens exactly one transaction per call chain. A standalone
# db_append()/db_update()/db_delete() call (no transaction open yet) opens
# its own via db_transaction() and is therefore atomic on its own. When
# several mutations must be one atomic unit (commit_event()), the caller
# wraps its whole body in a single `db_transaction(con, function(con) {
# ...calls db_append()/db_update()/db_delete() with this con... })`; the
# *tagged* `con` handed to the inner calls carries an attribute
# ("sampletidy_mutate_txn") marking a transaction as already open on it, so
# nested db_*() calls detect this (`.st_in_txn()`) and participate instead of
# nesting a second `dbBegin()` (DuckDB errors on nested BEGIN). The tag rides
# on the `con` object itself as it is passed down the call stack - no
# separate global/environment registry is needed because R's normal
# call-by-value-of-reference semantics carry the tagged object forward to
# every nested call within that one transaction's dynamic scope.
#
# Domain helpers (A16: `add_feature()`, `add_analyte()`, `add_project()`,
# `correct_value()`) take NO `con` argument - they resolve their own
# connection via `with_db_write(st_config("live_db"))`, consistent with
# DESIGN Sec9.3 ("one set of write functions used by pipeline and humans
# alike") and PLAN-CHANGE-REQUESTS.md's [pipeline-tests] R-9.1 note. They are
# thin wrappers over db_append()/db_update() with a fresh
# `uuid::UUIDgenerate()` for the new row's own uuid.

# ---- table/column validation (A32 allowlist) -------------------------------

# Tables the mutation layer is willing to write to: the core business tables
# (CONTRACT "Existing DB schema") plus `asset` and the ops table
# `review_queue`. `ingest_*` ops tables are allowlisted too (PLAN-09 R-9.1
# text: "core + ops tables") even though the pipeline in practice writes them
# exclusively through db-schema.R's own helpers (A32) rather than db_append().
.st_mutate_allowlist <- c(
  "feature", "feature_mask", "analyte", "analyte_mask", "lab_method",
  "project", "sample", "analysis", "asset", "review_queue", "feature_alias"
)

#' @keywords internal
#' @noRd
.st_validate_table <- function(table) {
  checkmate::assert_string(table)
  ok <- table %in% .st_mutate_allowlist || grepl("^ingest_", table)
  if (!ok) {
    cli::cli_abort(
      "Table {.val {table}} is not in the mutation-layer allowlist.",
      class = "sampletidy_error"
    )
  }
}

#' @keywords internal
#' @noRd
.st_validate_columns <- function(con, table, cols) {
  actual <- DBI::dbListFields(con, table)
  bad <- setdiff(cols, actual)
  if (length(bad) > 0) {
    cli::cli_abort(
      "Column{?s} {.val {bad}} not found on table {.val {table}}.",
      class = "sampletidy_error"
    )
  }
}

# ---- transaction participation ---------------------------------------------

#' @keywords internal
#' @noRd
.st_in_txn <- function(con) {
  isTRUE(attr(con, "sampletidy_mutate_txn", exact = TRUE))
}

#' Run `fn(con)` inside exactly one mutation-layer transaction
#'
#' If `con` already has an open mutation-layer transaction (because an outer
#' `db_transaction()` call further up the stack tagged it), just calls
#' `fn(con)` so the caller's transaction is not nested (DuckDB errors on a
#' second `BEGIN`). Otherwise opens a new transaction, tags a local copy of
#' `con` so calls made *within* `fn` participate rather than re-beginning,
#' commits on success, and rolls back (then re-raises) on error.
#'
#' `commit.R`'s `commit_event()` calls this directly to make several
#' `db_append()`/`db_update()`/`db_delete()` calls one atomic unit.
#'
#' @param con an open read-write DBI connection.
#' @param fn function of one argument (the possibly-tagged connection).
#' @return `fn(con)`'s return value.
#' @keywords internal
#' @noRd
db_transaction <- function(con, fn) {
  checkmate::assert_function(fn)

  if (.st_in_txn(con)) {
    return(fn(con))
  }

  DBI::dbBegin(con)
  attr(con, "sampletidy_mutate_txn") <- TRUE

  result <- tryCatch(
    {
      out <- fn(con)
      DBI::dbCommit(con)
      out
    },
    error = function(e) {
      try(DBI::dbRollback(con), silent = TRUE)
      cli::cli_abort(
        "Mutation transaction failed and was rolled back: {conditionMessage(e)}",
        class = "sampletidy_error",
        parent = e
      )
    }
  )

  result
}

# ---- change_log writer ------------------------------------------------------

#' @keywords internal
#' @noRd
.st_write_change_log <- function(con, at, actor, action, tbl, uuid_row, field,
                                  old, new, reason, source_hash) {
  DBI::dbExecute(
    con,
    "INSERT INTO change_log
       (uuid, \"at\", actor, action, tbl, uuid_row, field, old, new, reason, source_hash)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
    params = list(
      uuid::UUIDgenerate(), at, actor, action, tbl, uuid_row, field,
      old, new, reason, source_hash
    )
  )
  invisible(NULL)
}

# ---- generic write door: db_append / db_update / db_delete -----------------

#' Insert rows into a core/ops table, logging one `change_log` row per record
#'
#' Validates `table` against the mutation-layer allowlist and every column of
#' `df` against the table's real columns, then inserts all rows of `df` and
#' writes one `change_log` row per inserted record (`action = "insert"`,
#' `field = NA`, `new` = the row's own `uuid`). All log rows from one call
#' share a single `"at"` timestamp. Participates in the caller's open
#' mutation-layer transaction if there is one (see `db_transaction()`);
#' otherwise atomic on its own.
#'
#' @param con an open read-write DBI connection.
#' @param table target table name.
#' @param df data frame/tibble of rows to insert; must include a `uuid`
#'   column for the per-row `change_log` linkage.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @param source_hash optional content hash provenance (A1), stored on every
#'   `change_log` row.
#' @return `df`, invisibly.
#' @export
db_append <- function(con, table, df, actor, reason, source_hash = NA) {
  checkmate::assert_string(table)
  checkmate::assert_data_frame(df)
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)

  .st_validate_table(table)
  .st_validate_columns(con, table, names(df))

  db_transaction(con, function(con) {
    at <- Sys.time()
    DBI::dbAppendTable(con, table, df)

    row_uuids <- if ("uuid" %in% names(df)) {
      as.character(df$uuid)
    } else {
      rep(NA_character_, nrow(df))
    }

    for (i in seq_len(nrow(df))) {
      .st_write_change_log(
        con, at = at, actor = actor, action = "insert", tbl = table,
        uuid_row = row_uuids[[i]], field = NA_character_,
        old = NA_character_, new = row_uuids[[i]],
        reason = reason, source_hash = source_hash
      )
    }
  })

  invisible(df)
}

#' Update fields on one row, logging one `change_log` row per changed field
#'
#' Validates `table` against the mutation-layer allowlist and every field
#' name in `changes` against the table's real columns *before* writing
#' anything, so a bad column aborts with no partial write. Reads the current
#' row, applies each change, and writes one `change_log` row per changed
#' field (`action = "update"`, with `old`/`new`). Any failure (bad column, or
#' a lower-level DB error mid-update) rolls back the whole call, including
#' any `change_log` rows already written in this call - atomicity.
#' Participates in the caller's open mutation-layer transaction if there is
#' one; otherwise atomic on its own.
#'
#' Alternate/composite key: `key` (PLAN-14 R-14.1) --------------------------
#'
#' `analyte_mask`/`feature_mask` have no `uuid` column - they are keyed by
#' `(uuid_analyte, variant)` / `(uuid_feature, variant)`. `db_update()` and
#' `db_delete()` accept EITHER the original scalar `uuid` (back-compat: every
#' existing caller is byte-for-byte unchanged - internally this is just
#' `key = list(uuid = uuid)`) OR a named-list `key` giving the WHERE as the
#' AND of `col = ?` pairs. Exactly one of `uuid`/`key` must be supplied.
#'
#' @keywords internal
#' @noRd
.st_resolve_key <- function(table, uuid, key) {
  if (!is.null(uuid) && !is.null(key)) {
    cli::cli_abort(
      "Supply either `uuid` or `key` to table {.val {table}}, not both.",
      class = "sampletidy_error"
    )
  }
  if (!is.null(uuid)) {
    checkmate::assert_string(uuid)
    return(list(uuid = uuid))
  }
  checkmate::assert_list(key, min.len = 1, names = "unique")
  key
}

#' Update fields on one row, logging one `change_log` row per changed field
#'
#' Validates `table` against the mutation-layer allowlist and every field
#' name in `changes` against the table's real columns *before* writing
#' anything, so a bad column aborts with no partial write. Reads the current
#' row, applies each change, and writes one `change_log` row per changed
#' field (`action = "update"`, with `old`/`new`). Any failure (bad column, or
#' a lower-level DB error mid-update) rolls back the whole call, including
#' any `change_log` rows already written in this call - atomicity.
#' Participates in the caller's open mutation-layer transaction if there is
#' one; otherwise atomic on its own.
#'
#' Keyed on either the scalar `uuid` (back-compat, default path - every
#' existing caller unchanged) OR a named-list `key` for tables with no `uuid`
#' column (e.g. `analyte_mask`, keyed on `(uuid_analyte, variant)`; PLAN-14
#' R-14.1). `change_log.uuid_row` is the scalar uuid when keyed that way,
#' else `NA` (no single row-id exists for a composite key).
#'
#' @param con an open read-write DBI connection.
#' @param table target table name.
#' @param uuid the row's primary key (scalar-uuid path; mutually exclusive
#'   with `key`).
#' @param changes named list of field -> new value.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on every `change_log` row.
#' @param source_hash optional content hash provenance (A1), stored on every
#'   `change_log` row.
#' @param key named list of column -> value giving an alternate/composite
#'   key (mutually exclusive with `uuid`).
#' @return `uuid` (or `key`, when keyed that way), invisibly.
#' @export
db_update <- function(con, table, uuid = NULL, changes, actor, reason,
                       source_hash = NA, key = NULL) {
  checkmate::assert_string(table)
  key <- .st_resolve_key(table, uuid, key)
  checkmate::assert_list(changes, min.len = 1, names = "unique")
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)

  .st_validate_table(table)
  .st_validate_columns(con, table, names(changes))

  quoted_table <- DBI::dbQuoteIdentifier(con, table)
  where_sql <- paste(
    vapply(
      names(key),
      function(f) paste0(DBI::dbQuoteIdentifier(con, f), " = ?"),
      character(1)
    ),
    collapse = " AND "
  )
  key_params <- unname(key)
  uuid_row <- if (!is.null(uuid)) uuid else NA_character_

  db_transaction(con, function(con) {
    current <- DBI::dbGetQuery(
      con,
      sprintf("SELECT * FROM %s WHERE %s", quoted_table, where_sql),
      params = key_params
    )
    if (nrow(current) == 0) {
      cli::cli_abort(
        "No row matching the given key found in table {.val {table}}.",
        class = "sampletidy_error"
      )
    }

    at <- Sys.time()
    for (field in names(changes)) {
      old_val <- current[[field]][[1]]
      new_val <- changes[[field]]

      if (identical(as.character(new_val), as.character(old_val))) {
        next
      }

      quoted_field <- DBI::dbQuoteIdentifier(con, field)

      DBI::dbExecute(
        con,
        sprintf("UPDATE %s SET %s = ? WHERE %s", quoted_table, quoted_field, where_sql),
        params = c(list(new_val), key_params)
      )
      .st_write_change_log(
        con, at = at, actor = actor, action = "update", tbl = table,
        uuid_row = uuid_row, field = field,
        old = as.character(old_val), new = as.character(new_val),
        reason = reason, source_hash = source_hash
      )
    }
  })

  invisible(if (!is.null(uuid)) uuid else key)
}

#' Delete a row, logging one `change_log` delete row
#'
#' Validates `table` against the mutation-layer allowlist, deletes the row,
#' and writes one `change_log` row (`action = "delete"`). Participates in the
#' caller's open mutation-layer transaction if there is one; otherwise atomic
#' on its own.
#'
#' Keyed on either the scalar `uuid` (back-compat, default path - every
#' existing caller unchanged) OR a named-list `key` for tables with no `uuid`
#' column (PLAN-14 R-14.1); see `db_update()`'s doc for the shared key
#' mechanism. `change_log.uuid_row` is the scalar uuid when keyed that way,
#' else `NA`. CONTRACT A72 (delete-missing aborts `sampletidy_error`) applies
#' identically to both key forms.
#'
#' @param con an open read-write DBI connection.
#' @param table target table name.
#' @param uuid the row's primary key (scalar-uuid path; mutually exclusive
#'   with `key`).
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` row.
#' @param key named list of column -> value giving an alternate/composite
#'   key (mutually exclusive with `uuid`).
#' @return `uuid` (or `key`, when keyed that way), invisibly.
#' @export
db_delete <- function(con, table, uuid = NULL, actor, reason, key = NULL) {
  checkmate::assert_string(table)
  key <- .st_resolve_key(table, uuid, key)
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)

  .st_validate_table(table)
  quoted_table <- DBI::dbQuoteIdentifier(con, table)
  where_sql <- paste(
    vapply(
      names(key),
      function(f) paste0(DBI::dbQuoteIdentifier(con, f), " = ?"),
      character(1)
    ),
    collapse = " AND "
  )
  key_params <- unname(key)
  uuid_row <- if (!is.null(uuid)) uuid else NA_character_

  db_transaction(con, function(con) {
    at <- Sys.time()
    n_affected <- DBI::dbExecute(
      con,
      sprintf("DELETE FROM %s WHERE %s", quoted_table, where_sql),
      params = key_params
    )
    if (n_affected == 0) {
      cli::cli_abort(
        "No row matching the given key found in table {.val {table}}.",
        class = "sampletidy_error"
      )
    }
    .st_write_change_log(
      con, at = at, actor = actor, action = "delete", tbl = table,
      uuid_row = uuid_row, field = NA_character_,
      old = uuid_row, new = NA_character_,
      reason = reason, source_hash = NA_character_
    )
  })

  invisible(if (!is.null(uuid)) uuid else key)
}

# ---- domain helpers (A16: resolve their own connection) --------------------

#' Add a new feature (monitoring point) to the registry
#'
#' Resolves its own connection via `with_db_write(st_config("live_db"))`
#' (A16) - human-callable, no `con` argument. Thin wrapper over `db_append()`
#' with a fresh `uuid::UUIDgenerate()` for the new row.
#'
#' @param name feature name.
#' @param site site name.
#' @param lon longitude, `DOUBLE NOT NULL` on the live schema.
#' @param lat latitude, `DOUBLE NOT NULL` on the live schema.
#' @param flow flow type (e.g. `"surface"`), optional.
#' @param matrix sample matrix (e.g. `"water"`), optional.
#' @param geom_wkt optional WKT geometry string.
#' @param virtual optional logical flag, defaults to `FALSE`.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` row.
#' @return the new feature's uuid, invisibly.
#' @export
add_feature <- function(name, site, lon, lat, flow = NA_character_,
                         matrix = NA_character_, geom_wkt = NA_character_,
                         virtual = FALSE, actor, reason) {
  checkmate::assert_string(name)
  checkmate::assert_string(site)
  if (missing(lon) || missing(lat)) {
    cli::cli_abort(
      "add_feature() requires both {.arg lon} and {.arg lat}.",
      class = "sampletidy_error"
    )
  }
  checkmate::assert_number(lon)
  checkmate::assert_number(lat)
  new_uuid <- uuid::UUIDgenerate()
  row <- tibble::tibble(
    uuid = new_uuid, name = name, site = site, lon = lon, lat = lat,
    flow = flow, matrix = matrix, geom_wkt = geom_wkt, virtual = virtual
  )
  with_db_write(
    function(con) db_append(con, "feature", row, actor = actor, reason = reason),
    db = st_config("live_db")
  )
  invisible(new_uuid)
}

#' Add a new analyte to the registry
#'
#' Resolves its own connection via `with_db_write(st_config("live_db"))`
#' (A16). Thin wrapper over `db_append()` with a fresh
#' `uuid::UUIDgenerate()` for the new row.
#'
#' @param name analyte name.
#' @param units canonical units.
#' @param conversion_constant optional numeric conversion constant.
#' @param type analyte type (e.g. `"anion"`, `"field"`).
#' @param CAS optional CAS registry number.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` row.
#' @return the new analyte's uuid, invisibly.
#' @export
add_analyte <- function(name, units = NA_character_, conversion_constant = NA_real_,
                         type = NA_character_, CAS = NA_character_,
                         actor, reason) {
  checkmate::assert_string(name)
  new_uuid <- uuid::UUIDgenerate()
  row <- tibble::tibble(
    uuid = new_uuid, name = name, units = units,
    conversion_constant = conversion_constant, type = type, CAS = CAS
  )
  with_db_write(
    function(con) db_append(con, "analyte", row, actor = actor, reason = reason),
    db = st_config("live_db")
  )
  invisible(new_uuid)
}

#' Add a new project (e.g. a work order) to the registry
#'
#' Resolves its own connection via `with_db_write(st_config("live_db"))`
#' (A16). Thin wrapper over `db_append()` with a fresh
#' `uuid::UUIDgenerate()` for the new row.
#'
#' @param name project name (work order id for lab-report projects).
#' @param type project type, defaults to `"Work order"`.
#' @param purpose,site,value,cypher,regulated_by optional free-text fields.
#' @param uuid_parent,uuid_root,uuid_project optional project-hierarchy links.
#' @param date_start,date_end optional `POSIXct`/`Date` bounds.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` row.
#' @return the new project's uuid, invisibly.
#' @export
add_project <- function(name, type = "Work order", uuid_parent = NA_character_,
                         uuid_root = NA_character_, uuid_project = NA_character_,
                         purpose = NA_character_,
                         date_start = as.POSIXct(NA), date_end = as.POSIXct(NA),
                         regulated_by = NA_character_, cypher = NA_character_,
                         site = NA_character_, value = NA_character_,
                         actor, reason) {
  checkmate::assert_string(name)
  new_uuid <- uuid::UUIDgenerate()
  row <- tibble::tibble(
    uuid = new_uuid, uuid_parent = uuid_parent, uuid_root = uuid_root,
    uuid_project = uuid_project, name = name, type = type, purpose = purpose,
    date_start = date_start, date_end = date_end, regulated_by = regulated_by,
    cypher = cypher, site = site, value = value
  )
  with_db_write(
    function(con) db_append(con, "project", row, actor = actor, reason = reason),
    db = st_config("live_db")
  )
  invisible(new_uuid)
}

#' Correct a single analysis value, logging the old value
#'
#' Resolves its own connection via `with_db_write(st_config("live_db"))`
#' (A16). Thin wrapper over `db_update()`.
#'
#' @param uuid_analysis the analysis row's uuid.
#' @param new_value the corrected numeric value.
#' @param reason free-text reason, stored on the `change_log` row.
#' @param actor who is making this change.
#' @return `uuid_analysis`, invisibly.
#' @export
correct_value <- function(uuid_analysis, new_value, reason, actor) {
  checkmate::assert_string(uuid_analysis)
  checkmate::assert_number(new_value)
  with_db_write(
    function(con) {
      db_update(
        con, "analysis", uuid_analysis,
        changes = list(value = new_value), actor = actor, reason = reason
      )
    },
    db = st_config("live_db")
  )
  invisible(uuid_analysis)
}

# ---- reader: review_queue() -------------------------------------------------

#' Read `review_queue` rows, filtered by status
#'
#' Returns queue rows as a tibble with stable columns (all 10) even on a
#' zero-row result, since the `SELECT` names every column explicitly.
#' `payload` is left as-is (JSON text).
#'
#' @param con an open DBI connection.
#' @param status status to filter on, defaults to `"open"`.
#' @return a tibble of `review_queue` rows.
#' @export
review_queue <- function(con, status = "open") {
  checkmate::assert_string(status)
  rows <- DBI::dbGetQuery(
    con,
    "SELECT uuid, created_at, kind, work_order, source_hash, payload,
            status, resolution, resolved_by, resolved_at
     FROM review_queue
     WHERE status = ?",
    params = list(status)
  )
  tibble::as_tibble(rows)
}
