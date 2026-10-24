# Operator-run migration: map ALS "Thermotolerant Coliforms" (method MW006) to Faecal Coliforms.
# Marker 1075. Requires 1074.
#
# Authority: Robin, 2026-10-25 (ALS now reports MW006 as "Thermotolerant Coliforms"; it is
# the same analyte as "Faecal Coliforms").
#
# ---- WHY ------------------------------------------------------------------------------
# Work order ES2631587 (committed 2026-10-24) carried an analyte name no lab_method knew, so
# commit minted a DANGLING lab_method (ed24b16d, uuid_analyte NULL, units CFU/100mL) and three
# analyses on it (values stored raw: 31, 290, 130; rl_low 1), and left an open
# unknown_analyte review item (ae4491dc). The historical Faecal Coliforms method
# (a881148c, "MW006: Faecal Coliforms & E.coli by MF") maps to the analyte 279a3d10
# (units CFU/mL); its 102 analyses are ALS's CFU/100mL divided by 100 (migration 034).
#
# ---- WHAT (frozen in 075-map-thermotolerant-coliforms-INPUT.csv; one group, all or none) --
#   F1 lab_method ed24b16d: uuid_analyte -> 279a3d10; comments -> "ALS renamed MW006 Faecal
#      Coliforms to Thermotolerant Coliforms (same analyte)." conversion_constant stays NULL
#      and units stays 'CFU/100mL' - see CONVERSION below.
#   F2 the method's 3 analyses (302e63f8, c20b480a, 59aa65b2): value /100 (31 -> 0.31,
#      290 -> 2.9, 130 -> 1.3) and rl_low 1 -> 0.01, exactly what a re-import would store
#      now the method is mapped. rl_high is NULL on all three (nothing to convert);
#      value_chr is NULL (quantified numbers); no other numeric column exists on analysis.
#   F3 review_queue ae4491dc (unknown_analyte, open): status 'resolved', resolution text,
#      resolved_by this migration, resolved_at = run time (as 066 / 067).
#
# ---- HOW (the FK step; 056's pattern) ------------------------------------------------------
# lab_method.uuid_analyte is an FK column: an UPDATE of it is delete + insert in duckdb 1.4.1,
# which the analysis -> lab_method FK refuses while analyses reference the method (verified on
# a copy; comments / conversion_constant updates are fine). So:
#   A. one set-based DELETE of the method's 3 analyses (count asserted; the change_log rows
#      db_delete() would write), COMMIT;
#   B. one transaction: lab_method update, the 3 analyses re-inserted with the same uuids and
#      every column as frozen except value / rl_low (converted), the review item, the marker;
#      verify; checksum of everything else; mig_db_checks_gate; all-tier comparison.
# If B fails after A committed, the 3 original rows are re-inserted unchanged (with change_log
# rows saying so) and the error is re-raised naming the backup; a re-run then refuses (075
# change_log rows without the marker) until the backup is restored.
#
# ---- CONVERSION (why conversion_constant is NOT set to 0.01) -----------------------------
# For a row whose analyte RESOLVES, .rc_convert_units() (R/reconcile.R ~2180) already runs
# unify_value(value, units_raw, analyte.units): CFU/100mL -> CFU/mL divides by 100
# (verified: unify_value(c(31, 1), "CFU/100mL", "CFU/mL") = 0.31, 0.01). Only AFTER that
# does .ct_commit_analyses() (R/commit.R ~2225) MULTIPLY by lab_method.conversion_constant.
# A constant of 0.01 would therefore divide twice (31 -> 0.0031). Mapped methods are
# stored with the constant NULL (a881148c: NULL; 569 of 573 mapped methods), so this one
# is too. The stored analyses are made to equal what that path would have written.
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before: every row touched is byte for byte as frozen (sha1); each field still holds its
#   frozen old value; the lab_method has exactly the 3 frozen analyses and nothing else uses
#   it; the target analyte and the sibling method are as frozen; the review item is open.
#   A failing check skips the whole group (SKIPPED CSV). Inside the one write transaction:
#   baseline <- db_checks(con, tier = "migration"); afterwards every planned row is as
#   planned, nothing else moved (checksums; counts; change_log +n; schema_version +1),
#   mig_db_checks_gate(con, baseline), and on the all tier no check gains an offender key.
#
# Backups: verified whole-file snapshot; BACKUP CSVs of the touched rows. Idempotent: marker
# present -> re-verify, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/075-map-thermotolerant-coliforms.R", envir = env)
#   env$mig075_run(db = ..., snapshot_dir = ..., dry_run = TRUE)

.mig075_marker_version <- 1075L
.mig075_requires <- 1074L
.mig075_name <- "075-map-thermotolerant-coliforms"
.mig075_actor <- .mig075_name
.mig075_items <- c("F1", "F2", "F3")
.mig075_reason <- "075 (Robin 2026-10-25: ALS Thermotolerant Coliforms is Faecal Coliforms)"
.mig075_lm <- "ed24b16d-8851-4ee6-a032-d9181f4e9d76"
.mig075_sibling <- "a881148c-28a1-484c-95dc-3a0bec782470"
.mig075_analyte <- "279a3d10-489f-4786-b1af-aca55d4e67dc"
.mig075_review <- "ae4491dc-b6e4-4865-a9b5-2019accd24d0"
.mig075_run_time <- "RUN_TIME"
.mig075_pk <- c(lab_method = "uuid", analysis = "uuid", review_queue = "uuid", analyte = "uuid")
.mig075_types <- list(
  lab_method = c(uuid_analyte = "chr", comments = "chr"),
  analysis = c(value = "num", rl_low = "num"),
  review_queue = c(status = "chr", resolution = "chr", resolved_by = "chr", resolved_at = "ts")
)

.mig075_fail <- function(msg) cli::cli_abort(paste0(.mig075_name, ": ", msg), class = "sampletidy_error")
.mig075_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig075_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig075_str <- function(x) { s <- .st_changelog_str(x); if (length(s) != 1L || is.na(s)) NA_character_ else s }
.mig075_value <- function(tbl, field, v, recorded_at) {
  ty <- .mig075_types[[tbl]][[field]]
  na <- is.na(v) || !nzchar(v)
  switch(ty,
         num = if (na) NA_real_ else as.numeric(v),
         chr = if (na) NA_character_ else v,
         ts = if (na) as.POSIXct(NA) else recorded_at)
}
# Does a current value equal a frozen text value? Numbers compare exactly; resolved_at
# "RUN_TIME" means any non-NULL timestamp.
.mig075_same <- function(tbl, field, cur, frozen) {
  ty <- .mig075_types[[tbl]][[field]]
  if (identical(ty, "num")) {
    if (is.na(frozen)) return(is.na(cur))
    return(!is.na(cur) && identical(as.numeric(cur), as.numeric(frozen)))
  }
  if (identical(ty, "ts")) {
    if (is.na(frozen)) return(is.na(cur))
    if (identical(frozen, .mig075_run_time)) return(!is.na(cur))
  }
  s <- .mig075_str(cur)
  (is.na(s) && is.na(frozen)) || (!is.na(s) && !is.na(frozen) && s == frozen)
}

# ---- inputs ---------------------------------------------------------------------------

.mig075_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig075_name))
  if (!file.exists(p)) .mig075_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  need <- c("gid", "item", "op", "tbl", "id", "field", "old", "new", "row_sha1", "note")
  if (!all(need %in% names(x))) .mig075_fail("INPUT lacks a column.")
  if (!all(x$item %in% .mig075_items)) .mig075_fail("INPUT has an unknown item.")
  if (!all(x$op %in% c("keep", "update"))) .mig075_fail("INPUT has an unknown op.")
  if (!all(x$tbl %in% names(.mig075_pk))) .mig075_fail("INPUT names a table this migration does not touch.")
  if (anyNA(x$row_sha1) || anyNA(x$id) || anyNA(x$gid)) .mig075_fail("INPUT misses an id, gid or sha.")
  u <- x$op == "update"
  if (anyNA(x$field[u])) .mig075_fail("an INPUT update names no field.")
  ok <- mapply(function(t, f) !is.null(.mig075_types[[t]]) && f %in% names(.mig075_types[[t]]), x$tbl[u], x$field[u])
  if (!all(ok)) .mig075_fail("an INPUT update writes a column this migration does not.")
  if (anyDuplicated(paste(x$tbl, x$id, x$field, x$op))) .mig075_fail("INPUT repeats a row.")
  if (length(unique(x$gid)) != 1L) .mig075_fail("INPUT is not one group.")
  n <- table(factor(x$item[u], levels = .mig075_items))
  if (!identical(as.integer(n), c(2L, 6L, 4L))) .mig075_fail("INPUT update counts are not as planned (2, 6, 4).")
  if (sum(x$op == "keep") != 2L) .mig075_fail("INPUT does not freeze the sibling method and the analyte.")
  x
}

# sha1 of each row as text (as 073 / 074).
.mig075_df_sha <- function(df, pk) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[pk]])
}

.mig075_rows <- function(con, tbl, ids) {
  pk <- .mig075_pk[[tbl]]
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY "%s"', tbl, pk, .mig075_inlist(ids), pk))
}

.mig075_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  s <- .mig075_df_sha(.mig075_rows(con, tbl, ids), .mig075_pk[[tbl]])
  out[names(s)] <- s
  out[ids]
}

# ---- preconditions -----------------------------------------------------------------

# Hard failures abort; problems come back as a one-column data.frame (empty = fine).
.mig075_check_preconditions <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig075_requires, have)
  if (length(miss)) .mig075_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  probs <- character()
  for (t in unique(x$tbl)) {
    r <- x[x$tbl == t, , drop = FALSE]
    ids <- unique(r$id)
    s <- .mig075_row_sha(con, t, ids)
    fr <- r$row_sha1[match(ids, r$id)]
    bad <- is.na(s) | s != fr
    probs <- c(probs, sprintf("%s %s missing or not as frozen", t, ids[bad]))
    up <- r[r$op == "update", , drop = FALSE]
    if (nrow(up)) {
      cur <- .mig075_rows(con, t, up$id)
      pk <- .mig075_pk[[t]]
      ok <- vapply(seq_len(nrow(up)), function(i) {
        k <- match(up$id[[i]], cur[[pk]]); if (is.na(k)) return(FALSE)
        .mig075_same(t, up$field[[i]], cur[[up$field[[i]]]][[k]], up$old[[i]])
      }, TRUE)
      probs <- c(probs, sprintf("%s %s.%s is no longer %s", t, up$id[!ok], up$field[!ok], up$old[!ok]))
    }
  }
  # Exactly the frozen analyses use the method, and nothing else points at it.
  frozen_an <- sort(unique(x$id[x$tbl == "analysis"]))
  have_an <- sort(DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_lab = ?", params = list(.mig075_lm))$uuid)
  if (!identical(frozen_an, have_an)) probs <- c(probs, "the method's analyses are not the frozen three")
  # Another method already carrying this name / org / method string would make the resolver ambiguous.
  dup <- .mig075_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid <> ? AND organisation = 'ALS' AND name = 'Thermotolerant Coliforms'",
                        .mig075_lm)
  if (dup > 0L) probs <- c(probs, "another ALS 'Thermotolerant Coliforms' lab_method exists")
  data.frame(problem = unique(probs), stringsAsFactors = FALSE)
}

# ---- targeted checks ---------------------------------------------------------------------

# No check gains an offender key or a new error; checks may lose keys.
.mig075_checks_problem <- function(before, after) {
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

# ---- verify ---------------------------------------------------------------------------

.mig075_expected_log <- function(planned) {
  u <- planned[planned$op == "update", , drop = FALSE]
  # the analysis value / rl_low updates are a delete + insert per analysis (see HOW)
  e <- table(c(paste(u$tbl[u$tbl != "analysis"], "update", sep = "|"),
               rep(c("analysis|delete", "analysis|insert"), each = length(unique(u$id[u$tbl == "analysis"])))))
  stats::setNames(as.integer(e), names(e))
}

.mig075_done_problem <- function(con, planned) {
  if (.mig075_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig075_marker_version) != 1L)
    return("marker 1075 missing")
  k <- planned[planned$op == "keep", , drop = FALSE]
  for (t in unique(k$tbl)) {
    r <- k[k$tbl == t & !duplicated(k$id), , drop = FALSE]
    s <- .mig075_row_sha(con, t, r$id)
    if (any(is.na(s) | s != r$row_sha1)) return(sprintf("kept %s row %s changed", t, r$id[is.na(s) | s != r$row_sha1][[1]]))
  }
  u <- planned[planned$op == "update", , drop = FALSE]
  for (t in unique(u$tbl)) {
    r <- u[u$tbl == t, , drop = FALSE]
    cur <- .mig075_rows(con, t, r$id)
    pk <- .mig075_pk[[t]]
    for (i in seq_len(nrow(r))) {
      j <- match(r$id[[i]], cur[[pk]])
      if (is.na(j)) return(sprintf("%s %s missing", t, r$id[[i]]))
      if (!.mig075_same(t, r$field[[i]], cur[[r$field[[i]]]][[j]], r$new[[i]]))
        return(sprintf("%s %s.%s is %s, not %s", t, r$id[[i]], r$field[[i]], .mig075_str(cur[[r$field[[i]]]][[j]]), r$new[[i]]))
    }
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig075_actor))
  got <- stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
  want <- .mig075_expected_log(planned)
  if (!identical(got[sort(names(got))], want[sort(names(want))]))
    return(sprintf("075 change_log rows are %s, not %s", paste(names(got), got, collapse = " "),
                   paste(names(want), want, collapse = " ")))
  NULL
}

.mig075_verify <- function(con, planned) {
  pr <- .mig075_done_problem(con, planned)
  if (!is.null(pr)) cli::cli_abort(paste0("075 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig075_counts <- function(con) {
  tabs <- c("analysis", "sample", "sample_lab_id", "feature", "feature_alias", "lab_method", "analyte", "asset",
            "ingest_file", "ingest_sighting", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig075_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table whole, except the touched ones outside this migration's rows.
.mig075_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c(names(.mig075_pk), "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  w <- x[x$op != "keep", , drop = FALSE]
  for (t in names(.mig075_pk)) {
    pk <- .mig075_pk[[t]]
    out[[paste0(t, "_rest")]] <- q(sprintf('SELECT * FROM "%s" WHERE "%s" NOT IN %s ORDER BY "%s"', t, pk,
                                           .mig075_inlist(w$id[w$tbl == t]), pk))
  }
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig075_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig075_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# ---- apply ---------------------------------------------------------------------------------

.mig075_why <- function(r) sprintf("%s [%s]: %s", .mig075_reason, r$item[[1]], r$note[[1]])

.mig075_apply <- function(con, x, planned, recorded_at, logf) {
  baseline <- db_checks(con, tier = "migration")
  before_all <- db_checks(con, tier = "all")
  sums_before <- .mig075_checksum(con, x)
  counts_want <- .mig075_counts(con)
  counts_want$change_log <- counts_want$change_log + sum(.mig075_expected_log(planned))
  counts_want$schema_version <- counts_want$schema_version + 1L
  u <- planned[planned$op == "update", , drop = FALSE]
  an_ids <- unique(u$id[u$tbl == "analysis"])
  orig <- .mig075_rows(con, "analysis", an_ids)
  if (nrow(orig) != length(an_ids)) .mig075_fail("an analysis to convert is missing.")
  # Step A: set-based delete of the method's analyses (committed), with the change_log rows db_delete() writes.
  db_transaction(con, function(con) {
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig075_inlist(an_ids)))
    if (n != length(an_ids)) .mig075_fail(sprintf("set-based delete removed %d rows, not %d.", n, length(an_ids)))
    at <- Sys.time()
    for (id in an_ids)
      .st_write_change_log(con, at = at, actor = .mig075_actor, action = "delete", tbl = "analysis", uuid_row = id,
                           field = NA_character_, old = id, new = NA_character_,
                           reason = paste0(.mig075_reason, " step A: analysis removed so its lab_method can be mapped (duckdb FK limitation); re-inserted with the same uuid in step B, value / rl_low converted CFU/100mL -> CFU/mL"),
                           source_hash = NA_character_)
    NULL
  })
  # Step B: the rest, one transaction. A failure re-inserts the originals unchanged.
  tryCatch(db_transaction(con, function(con) {
    # the lab_method mapping and the review item
    for (key in unique(paste(u$tbl, u$id)[u$tbl != "analysis"])) {
      r <- u[paste(u$tbl, u$id) == key, , drop = FALSE]
      ch <- stats::setNames(lapply(seq_len(nrow(r)), function(i)
        .mig075_value(r$tbl[[i]], r$field[[i]], r$new[[i]], recorded_at)), r$field)
      db_update(con, r$tbl[[1]], uuid = r$id[[1]], changes = ch, actor = .mig075_actor, reason = .mig075_why(r))
    }
    # the analyses, same uuids, converted
    for (i in seq_len(nrow(orig))) {
      r <- u[u$tbl == "analysis" & u$id == orig$uuid[[i]], , drop = FALSE]
      row <- tibble::as_tibble(orig[i, , drop = FALSE])
      for (k in seq_len(nrow(r))) row[[r$field[[k]]]] <- .mig075_value("analysis", r$field[[k]], r$new[[k]], recorded_at)
      db_append(con, "analysis", row, actor = .mig075_actor, reason = .mig075_why(r))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig075_marker_version, recorded_at))
    .mig075_verify(con, planned)
    if (!identical(.mig075_counts(con), counts_want)) .mig075_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig075_checksum(con, x))) .mig075_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig075_checks_problem(before_all, after_all)
    if (!is.null(pr)) .mig075_fail(paste0("standing checks: ", pr))
    logf("all-tier checks: %d non-passing before, %d after; no new offender.",
         sum(before_all$status != "pass"), sum(after_all$status != "pass"))
    logf("Updated lab_method %s (analyte), %d analyses, closed review item %s.", substr(.mig075_lm, 1, 8),
         length(unique(u$id[u$tbl == "analysis"])), substr(.mig075_review, 1, 8))
    NULL
  }), error = function(e) {
    back <- tryCatch(db_transaction(con, function(con) {
      for (i in seq_len(nrow(orig)))
        db_append(con, "analysis", tibble::as_tibble(orig[i, , drop = FALSE]), actor = .mig075_actor,
                  reason = paste0(.mig075_reason, " step B failed: original analysis row re-inserted unchanged"))
      NULL
    }), error = function(e2) e2)
    .mig075_fail(paste0("step B failed (", conditionMessage(e), "); ",
                        if (inherits(back, "error")) paste0("RE-INSERTING THE ANALYSES FAILED TOO (", conditionMessage(back), "); RESTORE THE BACKUP.")
                        else "the original analyses were re-inserted unchanged; restore the backup before re-running."))
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig075_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig075_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig075_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig075_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig075_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("075: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig075_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig075_name, what))

.mig075_read_skipped <- function(csv_dir) {
  f <- .mig075_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ----------------------------------------------------------------------------------

mig075_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig075_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig075_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig075_read_skipped(csv_dir)
    if (is.null(sk)) .mig075_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig075_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      planned <- if (nrow(sk)) x[0, , drop = FALSE] else x
      if (nrow(sk)) { logf("075 marker present and the group was skipped (%s); nothing to verify.", sk$problem[[1]])
      } else .mig075_verify(check_con, planned)
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("075 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  skipped <- tryCatch({
    if (.mig075_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig075_actor) > 0L)
      .mig075_fail("change_log already holds 075 rows but the marker is absent; refusing.")
    .mig075_check_preconditions(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  if (nrow(skipped)) {
    for (p in skipped$problem) logf("SKIP: %s", p)
    logf("Precondition(s) failed: the group is SKIPPED whole; nothing written.")
    if (isTRUE(dry_run)) return(invisible(list(status = "dry_run_skipped", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
    .mig075_write_csv(skipped, .mig075_csv(csv_dir, "SKIPPED"), "problem")
    return(invisible(list(status = "skipped", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  planned <- x
  logf("Plan: %d field updates on %d rows; 0 skipped.", sum(planned$op == "update"),
       length(unique(paste(planned$tbl, planned$id)[planned$op == "update"])))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    for (t in c("lab_method", "analysis", "review_queue"))
      .mig075_write_csv(.mig075_rows(bk_con, t, unique(x$id[x$tbl == t])), .mig075_csv(csv_dir, paste0("BACKUP-", t)), .mig075_pk[[t]])
    .mig075_write_csv(skipped, .mig075_csv(csv_dir, "SKIPPED"), "problem")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig075_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig075_check_preconditions(con, x)
    if (nrow(again)) .mig075_fail("the preconditions changed since the dry check; re-run.")
    .mig075_apply(con, x, planned, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig075_name, .mig075_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
