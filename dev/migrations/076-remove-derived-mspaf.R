# REHEARSED, NOT APPLIED (rehearsed 2026-10-25 on a plain-cp copy of live at marker 1074). See
# dev/MIGRATIONS.md row 1076.
# Operator-run migration: remove the derived msPAF measure from the measurement DB.
# Marker 1076. Requires 1074 (075 is a separate, independent migration).
#
# Authority: Robin, 2026-10-25. msPAF ("Adjusted msPAF", analyte AmsPAF) is a derived
# measure BMCC calculated (add_metal_index(), "Computed during ETL build"), not a
# measurement, so it must not live in the measurement DB. It is removed entirely.
#
# ---- WHAT (frozen in 076-remove-derived-mspaf-INPUT.csv; one group, all or nothing) ----
#   E1 delete, in foreign-key order, through db_delete() so change_log records every row:
#      903 analysis rows (uuid_lab = the 00000000-...-0004 lab_method), 4 guideline rows
#      (AmsPAF thresholds 1/5/10/20), 1 analyte_mask row (b3b1f259 / 'long'), the lab_method
#      'Computed: Adjusted msPAF' (organisation NULL) and the analyte AmsPAF (b3b1f259).
#   All five kinds of row stand or fall together (the analyte cannot go while an analysis
#   still points at it), so there is ONE group: if any guard fails the whole migration is
#   SKIPPED, listed in 076-...-SKIPPED.csv, and nothing is written.
#
# ---- CHECKS -----------------------------------------------------------------------------
#   Before (a failing guard SKIPS the group): every frozen row is byte for byte as frozen
#   (sha1); the set is closed (no other analysis on the lab_method, no other lab_method /
#   guideline / analyte_mask row on the analyte); no OTHER table or column outside
#   change_log holds the analyte uuid, the lab_method uuid, or any frozen analysis or
#   guideline uuid (every VARCHAR column of every base table is scanned: review_queue,
#   lab_qc_outlier, sample_lab_id, flags ...); no sample would be left with zero analyses
#   (a sample holding ONLY msPAF analyses is reported and skips the group: deciding
#   whether it goes is not this migration's job).
#   Around the writes (three transactions, see .mig076_apply: DuckDB cannot delete a parent in the
#   transaction that deleted its children; the checks run in the last): baseline <- db_checks(con, tier = "migration") and an
#   all-tier baseline before; after the deletes every planned row is gone and nothing else
#   moved (whole-table checksums of every other table; counts: analysis -903, guideline -4,
#   analyte_mask -1, lab_method -1, analyte -1, change_log +910, schema_version +1, sample
#   unchanged); v_measurement loses exactly the 903 AmsPAF rows and every view still
#   builds; mig_db_checks_gate(con, baseline); and on the all tier no check gains an
#   offender key or a new error.
#
# guideline is not in the mutation-layer allowlist, so its 4 deletes are a keyed DELETE plus
# .st_write_change_log() (the writer db_delete() uses): the same change_log rows.
# Rows are keyed by uuid, except analyte_mask (no uuid): keyed (uuid_analyte, variant), id
# 'uuid_analyte|variant' in the INPUT. change_log keeps only the key (old = uuid), so the
# BACKUP CSVs hold the FULL rows: re-inserting them (analyte, lab_method, analyte_mask,
# guideline, then analysis) reverses the migration. A verified whole-file snapshot is taken
# first. Idempotent: marker present -> re-verify against the SKIPPED CSV, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/076-remove-derived-mspaf.R", envir = env)
#   env$mig076_run(db = ..., snapshot_dir = ..., dry_run = TRUE)
#   env$mig076_freeze(db = ...)   # regenerates the INPUT csv from a db that still holds msPAF

.mig076_marker_version <- 1076L
.mig076_requires <- 1074L
.mig076_name <- "076-remove-derived-mspaf"
.mig076_actor <- .mig076_name
.mig076_reason <- "076 (Robin 2026-10-25: msPAF is a derived measure, not a measurement; removed)"
.mig076_analyte <- "b3b1f259-a05d-4dde-b153-3b91f03b51c5"
.mig076_lab <- "00000000-0000-0000-0000-000000000004"
.mig076_gid <- "mspaf"
# Delete order (children first). The planned counts are frozen: a drifting INPUT is refused.
.mig076_order <- c("analysis", "guideline", "analyte_mask", "lab_method", "analyte")
.mig076_n_rows <- c(analysis = 903L, guideline = 4L, analyte_mask = 1L, lab_method = 1L, analyte = 1L)
# Every row is addressed by this expression (the INPUT `id`); analyte_mask has no uuid.
.mig076_idexpr <- c(analysis = "uuid", guideline = "uuid", analyte_mask = "uuid_analyte || '|' || variant",
                    lab_method = "uuid", analyte = "uuid")
# The columns of the five tables that legitimately hold these uuids (own keys, the FKs
# between the five): not "other references".
.mig076_allow <- c("analysis.uuid", "analysis.uuid_lab", "guideline.uuid", "guideline.uuid_analyte",
                   "analyte_mask.uuid_analyte", "lab_method.uuid", "lab_method.uuid_analyte", "analyte.uuid")

.mig076_fail <- function(msg) cli::cli_abort(paste0(.mig076_name, ": ", msg), class = "sampletidy_error")
.mig076_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig076_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
`%||%` <- function(a, b) if (is.null(a)) b else a

.mig076_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- rows, sha1 ---------------------------------------------------------------------------

# Full rows of `tbl` addressed by id (the idexpr), with the id as the first column `.id`.
.mig076_rows <- function(con, tbl, ids) {
  ex <- .mig076_idexpr[[tbl]]
  DBI::dbGetQuery(con, sprintf('SELECT (%s) AS ".id", * FROM "%s" WHERE (%s) IN %s ORDER BY 1', ex, tbl, ex,
                               .mig076_inlist(ids)))
}

# sha1 of each row as text (as 073/074), over every column but the synthetic .id.
.mig076_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- setdiff(names(df), ".id")
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[".id"]])
}

.mig076_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  s <- .mig076_df_sha(.mig076_rows(con, tbl, ids))
  out[names(s)] <- s
  out[ids]
}

# The full row set the migration targets, read from a db that still holds msPAF.
.mig076_target_ids <- function(con) {
  list(
    analysis = DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_lab = ? ORDER BY uuid", params = list(.mig076_lab))$uuid,
    guideline = DBI::dbGetQuery(con, "SELECT uuid FROM guideline WHERE uuid_analyte = ? ORDER BY uuid", params = list(.mig076_analyte))$uuid,
    analyte_mask = DBI::dbGetQuery(con, "SELECT uuid_analyte || '|' || variant AS id FROM analyte_mask WHERE uuid_analyte = ? ORDER BY 1",
                                   params = list(.mig076_analyte))$id,
    lab_method = DBI::dbGetQuery(con, "SELECT uuid FROM lab_method WHERE uuid = ?", params = list(.mig076_lab))$uuid,
    analyte = DBI::dbGetQuery(con, "SELECT uuid FROM analyte WHERE uuid = ?", params = list(.mig076_analyte))$uuid
  )
}

# ---- freeze (writes the INPUT csv) ------------------------------------------------------------

mig076_freeze <- function(db, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  ids <- .mig076_target_ids(con)
  note <- c(analysis = "msPAF analysis row (lab_method 'Computed: Adjusted msPAF'): derived, deleted",
            guideline = "AmsPAF guideline threshold row: deleted",
            analyte_mask = "AmsPAF analyte_mask row ('Metal Toxicity Unit Index', long): deleted",
            lab_method = "lab_method 'Computed: Adjusted msPAF' (organisation NULL): deleted",
            analyte = "analyte AmsPAF (%, indicator, 'Generated by add_metal_index()'): deleted")
  out <- do.call(rbind, lapply(.mig076_order, function(t) {
    s <- .mig076_row_sha(con, t, ids[[t]])
    data.frame(gid = .mig076_gid, item = "E1", op = "delete", tbl = t, id = names(s), row_sha1 = unname(s),
               note = note[[t]], stringsAsFactors = FALSE)
  }))
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig076_name))
  utils::write.csv(out, p, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  invisible(out)
}

.mig076_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig076_name))
  if (!file.exists(p)) .mig076_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  need <- c("gid", "item", "op", "tbl", "id", "row_sha1", "note")
  if (!all(need %in% names(x))) .mig076_fail("INPUT lacks a column.")
  if (anyNA(x$row_sha1) || anyNA(x$id) || anyNA(x$gid)) .mig076_fail("INPUT misses an id, gid or sha.")
  if (!all(x$op == "delete") || !all(x$item == "E1") || !all(x$gid == .mig076_gid)) .mig076_fail("INPUT is not one group of deletes.")
  if (!all(x$tbl %in% .mig076_order)) .mig076_fail("INPUT names a table this migration does not touch.")
  if (anyDuplicated(paste(x$tbl, x$id))) .mig076_fail("INPUT repeats a row.")
  n <- table(factor(x$tbl, levels = .mig076_order))
  if (!identical(as.integer(n), unname(.mig076_n_rows[.mig076_order]))) .mig076_fail("INPUT row counts are not as planned.")
  if (!identical(x$id[x$tbl == "analyte"], .mig076_analyte) || !identical(x$id[x$tbl == "lab_method"], .mig076_lab))
    .mig076_fail("INPUT does not name the msPAF analyte / lab_method.")
  x[order(match(x$tbl, .mig076_order)), , drop = FALSE]
}

# ---- preconditions -------------------------------------------------------------------------

# Every VARCHAR column of every base table except change_log (history) holding any of `ids`.
.mig076_refs <- function(con, ids, allow) {
  cols <- DBI::dbGetQuery(con, "SELECT c.table_name, c.column_name FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'main' AND t.table_type = 'BASE TABLE' AND c.data_type = 'VARCHAR'
      AND c.table_name <> 'change_log' ORDER BY 1, 2")
  hits <- list()
  for (i in seq_len(nrow(cols))) {
    tc <- paste(cols$table_name[[i]], cols$column_name[[i]], sep = ".")
    if (tc %in% allow) next
    h <- DBI::dbGetQuery(con, sprintf('SELECT DISTINCT "%s" AS v FROM "%s" WHERE "%s" IN %s', cols$column_name[[i]],
                                      cols$table_name[[i]], cols$column_name[[i]], .mig076_inlist(ids)))$v
    if (length(h)) hits[[length(hits) + 1]] <- data.frame(id = h, where = tc, stringsAsFactors = FALSE)
  }
  if (!length(hits)) return(data.frame(id = character(), where = character()))
  do.call(rbind, hits)
}

# Problems (character vector) that stop the migration; empty = go.
.mig076_problems <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig076_requires, have)
  if (length(miss)) .mig076_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- character()
  for (t in .mig076_order) {
    r <- x[x$tbl == t, , drop = FALSE]
    s <- .mig076_row_sha(con, t, r$id)
    bad <- is.na(s) | s != r$row_sha1
    if (any(bad)) pr <- c(pr, sprintf("%s: %d row(s) missing or not as frozen (e.g. %s)", t, sum(bad), r$id[bad][[1]]))
  }
  # closed set: nothing else hangs off the lab_method / analyte
  ids <- .mig076_target_ids(con)
  for (t in .mig076_order) {
    extra <- setdiff(ids[[t]], x$id[x$tbl == t])
    if (length(extra)) pr <- c(pr, sprintf("%s: %d row(s) now target msPAF that the INPUT does not list (e.g. %s)", t, length(extra), extra[[1]]))
  }
  # no reference from anywhere else
  keys <- c(.mig076_analyte, .mig076_lab, x$id[x$tbl %in% c("analysis", "guideline")])
  h <- .mig076_refs(con, keys, allow = .mig076_allow)
  if (nrow(h)) pr <- c(pr, sprintf("%s is referenced by %s", h$id, h$where))
  # no sample left without analyses
  a <- x$id[x$tbl == "analysis"]
  orphan <- DBI::dbGetQuery(con, sprintf("SELECT s.uuid FROM \"sample\" s
    WHERE EXISTS (SELECT 1 FROM analysis a WHERE a.uuid_sample = s.uuid AND a.uuid IN %s)
      AND NOT EXISTS (SELECT 1 FROM analysis a WHERE a.uuid_sample = s.uuid AND a.uuid NOT IN %s)
    ORDER BY 1", .mig076_inlist(a), .mig076_inlist(a)))$uuid
  if (length(orphan)) pr <- c(pr, sprintf("%d sample(s) hold ONLY msPAF analyses and would be left empty (e.g. %s)", length(orphan), orphan[[1]]))
  pr
}

.mig076_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = .mig076_gid, problem = paste(unique(pr), collapse = "; "), stringsAsFactors = FALSE)
}

# ---- verify ----------------------------------------------------------------------------------

.mig076_gone_problem <- function(con, x) {
  if (.mig076_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig076_marker_version) != 1L)
    return("marker 1076 missing")
  for (t in .mig076_order) {
    n <- nrow(.mig076_rows(con, t, x$id[x$tbl == t]))
    if (n > 0L) return(sprintf("%d planned %s row(s) still present", n, t))
  }
  if (.mig076_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ?", .mig076_lab) > 0L) return("analysis still on the msPAF lab_method")
  if (.mig076_scalar(con, "SELECT COUNT(*) FROM analyte WHERE uuid = ? OR name = 'AmsPAF'", .mig076_analyte) > 0L) return("analyte AmsPAF is back")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig076_actor))
  got <- stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
  want <- stats::setNames(as.integer(.mig076_n_rows), paste(names(.mig076_n_rows), "delete", sep = "|"))
  if (!identical(got[sort(names(got))], want[sort(names(want))]))
    return(sprintf("076 change_log rows are %s, not %s", paste(names(got), got, collapse = " "), paste(names(want), want, collapse = " ")))
  NULL
}

# ---- counts, checksums ----------------------------------------------------------------------------

.mig076_counts <- function(con) {
  tabs <- c("analysis", "sample", "sample_lab_id", "feature", "feature_alias", "lab_method", "analyte", "analyte_mask",
            "guideline", "asset", "ingest_file", "ingest_sighting", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig076_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig076_view_counts <- function(con) {
  vs <- DBI::dbGetQuery(con, "SELECT view_name FROM duckdb_views() WHERE NOT internal ORDER BY view_name")$view_name
  stats::setNames(vapply(vs, function(v) {
    r <- tryCatch(.mig076_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', v)), error = function(e) NA_integer_)
    r
  }, 1L), vs)
}

# Every base table whole, except the five touched ones outside this migration's rows.
.mig076_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c(.mig076_order, "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  for (t in .mig076_order)
    out[[paste0(t, "_rest")]] <- q(sprintf('SELECT * FROM "%s" WHERE (%s) NOT IN %s ORDER BY ALL', t,
                                           .mig076_idexpr[[t]], .mig076_inlist(x$id[x$tbl == t])))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig076_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig076_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# All-tier checks before/after: no new offender key and no new error anywhere. NULL = fine.
.mig076_checks_problem <- function(before, after) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], if (nrow(b)) b$keys[[1]] else character())
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

# ---- apply -------------------------------------------------------------------------------------

.mig076_apply <- function(con, x, recorded_at, logf) {
  baseline <- db_checks(con, tier = "migration")
  before_all <- db_checks(con, tier = "all")
  sums_before <- .mig076_checksum(con, x)
  views_before <- .mig076_view_counts(con)
  if (anyNA(views_before)) .mig076_fail(sprintf("view(s) do not build before the change: %s", paste(names(views_before)[is.na(views_before)], collapse = ", ")))
  n_m_before <- .mig076_scalar(con, "SELECT COUNT(*) FROM v_measurement WHERE analyte_name = 'AmsPAF'")
  counts_want <- .mig076_counts(con)
  for (t in .mig076_order) counts_want[[t]] <- counts_want[[t]] - .mig076_n_rows[[t]]
  counts_want$change_log <- counts_want$change_log + sum(.mig076_n_rows)
  counts_want$schema_version <- counts_want$schema_version + 1L
  del_tbl <- function(con, t) {
    r <- x[x$tbl == t, , drop = FALSE]
    for (i in seq_len(nrow(r))) {
      why <- sprintf("%s [E1 %s]: %s", .mig076_reason, r$gid[[i]], r$note[[i]])
      if (t == "analyte_mask") {
        p <- strsplit(r$id[[i]], "|", fixed = TRUE)[[1]]
        db_delete(con, t, key = list(uuid_analyte = p[[1]], variant = p[[2]]), actor = .mig076_actor, reason = why)
      } else if (t == "guideline") {
        # guideline is not in the mutation-layer allowlist (.st_mutate_allowlist), so db_delete()
        # refuses it: a keyed DELETE plus .st_write_change_log(), the same change_log row db_delete() writes.
        n <- DBI::dbExecute(con, "DELETE FROM guideline WHERE uuid = ?", params = list(r$id[[i]]))
        if (n != 1L) .mig076_fail(sprintf("guideline %s: delete matched %d rows.", r$id[[i]], n))
        .st_write_change_log(con, at = Sys.time(), actor = .mig076_actor, action = "delete", tbl = "guideline",
                             uuid_row = r$id[[i]], field = NA_character_, old = r$id[[i]], new = NA_character_,
                             reason = why, source_hash = NA_character_)
      } else {
        db_delete(con, t, uuid = r$id[[i]], actor = .mig076_actor, reason = why)
      }
    }
  }
  # THREE TRANSACTIONS, NOT ONE (precedent: 011-delete-lmf.R). DuckDB cannot delete a parent row
  # in the same transaction that deleted its children ("key is still referenced by a foreign key
  # in a different table"): (1) the analyses; (2) guideline, analyte_mask, lab_method; (3) the
  # analyte, the marker and every check. If (2) or (3) fails the earlier ones stay committed with
  # no marker: a re-run then refuses (076 change_log rows without the marker) -- restore the
  # verified snapshot and re-run.
  db_transaction(con, function(con) { del_tbl(con, "analysis"); NULL })
  db_transaction(con, function(con) { for (t in c("guideline", "analyte_mask", "lab_method")) del_tbl(con, t); NULL })
  db_transaction(con, function(con) {
    del_tbl(con, "analyte")
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig076_marker_version, recorded_at))
    pr <- .mig076_gone_problem(con, x)
    if (!is.null(pr)) .mig076_fail(paste0("verify failed: ", pr))
    if (!identical(.mig076_counts(con), counts_want)) .mig076_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig076_checksum(con, x))) .mig076_fail("something outside the planned rows moved.")
    views_after <- .mig076_view_counts(con)
    if (anyNA(views_after)) .mig076_fail(sprintf("view(s) no longer build: %s", paste(names(views_after)[is.na(views_after)], collapse = ", ")))
    if (!identical(names(views_after), names(views_before))) .mig076_fail("the set of views changed.")
    d <- views_before[["v_measurement"]] - views_after[["v_measurement"]]
    if (n_m_before != .mig076_n_rows[["analysis"]] || d != n_m_before) .mig076_fail(sprintf("v_measurement lost %d rows (%d AmsPAF before), not %d.", d, n_m_before, .mig076_n_rows[["analysis"]]))
    if (.mig076_scalar(con, "SELECT COUNT(*) FROM v_measurement WHERE analyte_name = 'AmsPAF'") != 0L) .mig076_fail("v_measurement still shows AmsPAF.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig076_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig076_fail(paste0("standing checks: ", pr))
    for (v in names(views_before)) logf("view %-26s %7d -> %7d", v, views_before[[v]], views_after[[v]])
    logf("Deleted %s.", paste(sprintf("%d %s", .mig076_n_rows, names(.mig076_n_rows)), collapse = ", "))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files --------------------------------------------------------------------------------

mig076_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig076_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig076_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig076_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig076_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("076: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig076_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig076_name, what))

.mig076_read_skipped <- function(csv_dir) {
  f <- .mig076_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ------------------------------------------------------------------------------------------

mig076_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig076_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig076_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig076_read_skipped(csv_dir)
    if (is.null(sk)) .mig076_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig076_csv(csv_dir, "SKIPPED")))
    if (nrow(sk)) .mig076_fail("marker present but the SKIPPED plan is not empty: the migration should not have run.")
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      .mig076_ensure_icu(check_con)
      pr <- .mig076_gone_problem(check_con, x)
      if (!is.null(pr)) .mig076_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("076 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig076_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig076_actor) > 0L)
      .mig076_fail("change_log already holds 076 rows but the marker is absent; refusing.")
    .mig076_ensure_icu(pre_con)
    .mig076_problems(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig076_skipped_df(problems)
  logf("Plan: delete %s; %d problem(s).", paste(sprintf("%d %s", .mig076_n_rows, names(.mig076_n_rows)), collapse = ", "), length(problems))
  for (p in problems) logf("SKIP: %s", p)
  if (length(problems)) {
    if (!isTRUE(dry_run)) {
      .mig076_write_csv(skipped, .mig076_csv(csv_dir, "SKIPPED"), "gid")
      logf("SKIPPED plan written to %s; nothing else written.", csv_dir)
    }
    return(invisible(list(status = "skipped", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    for (t in .mig076_order)
      .mig076_write_csv(.mig076_rows(bk_con, t, x$id[x$tbl == t]), .mig076_csv(csv_dir, paste0("BACKUP-", t)), ".id")
    .mig076_write_csv(skipped, .mig076_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig076_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig076_ensure_icu(con)
    again <- .mig076_problems(con, x)
    if (length(again)) .mig076_fail("a precondition changed since the dry check; re-run.")
    .mig076_apply(con, x, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig076_name, .mig076_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
