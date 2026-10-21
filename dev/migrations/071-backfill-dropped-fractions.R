# Operator-run migration: restore the 60 results that R-8.6 method preference dropped
# at import, now that lab_method.fraction (070) lets the views rank them.
# Marker 1071. Requires 1070.
#
# Authority: Robin, 2026-10-22: (a) "fractions": keep both the total and the dissolved
# result of a sample, the views choosing dissolved for groundwater and total elsewhere
# (070); (b) TDS: keep both EA015 (measured) and EA016 (calculated from EC), prefer the
# measured EA015 (EA015 preference 100 < EA016 200, already so in live).
#
# ---- WHY -----------------------------------------------------------------------
# R/reconcile.R .rc_method_preference (R-8.6) keeps one method per (feature, date,
# analyte) and drops the rest as `method_duplicate`. Where the lab reported both a
# dissolved (ED/EG...F) and a total (...T) result, or both TDS methods, one of the two
# never reached live. The files are archived; the dropped rows were re-derived from
# them (scratchpad/2026-10-21-review/fractions/, the R-8.6 skip records re-run).
#
# ---- WHAT (frozen in 071-backfill-dropped-fractions-INPUT-analysis.csv) --------------
#   60 analysis inserts, each with a frozen uuid, through db_append() -> change_log
#   (source_hash = the lab file's hash, the reason naming file and cell):
#     fraction  56: 32 dissolved, 24 total, on 10 samples - ES2314728 (B.S01, B.S05,
#                   B.TS39, 3 May 2023), ES2515424/445/446 (B.L01, 24 May 2025),
#                   ES2626900 (B.MW06, 19 Aug 2026).
#     tds        4: EA015 TDS on ES2626883 (B.MW02/08/09) and ES2626900 (B.MW06),
#                   19 Aug 2026; each sample keeps its EA016 value.
#   Each row names the kept sibling: the stored analysis of the same sample and
#   analyte at the other fraction (or EA016), which R-8.6 kept.
#   `expect` says which of the pair the views must rank first: new_first when the
#   inserted row is the preferred fraction for the feature's flow (dissolved for
#   groundwater, total otherwise) or is EA015; sibling_first otherwise (40 / 20).
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before, per row (a failing sample group is SKIPPED whole, listed in
#   071-...-SKIPPED.csv): the target sample exists and is byte for byte as frozen
#   (sha1); the lab_method exists, has an analyte, and carries the row's fraction
#   (TDS: EA015, fraction NULL); no analysis holds the (sample, lab_method) pair or the
#   frozen uuid; the kept sibling exists on the same sample, as frozen (sha1), at the
#   same analyte, with the other fraction (TDS: EA016).
#   After (same transaction): every planned row stored as planned; nothing else in any
#   base table moved (checksums; change_log/schema_version outside this run's rows);
#   counts +n analyses, +n change_log, +1 schema_version; change_log = n analysis
#   inserts; every inserted row is in v_measurement, ranked against its sibling as
#   `expect` says; in every (feature, date, analyte) partition holding an inserted
#   fraction row the preference_rank = 1 row has the preferred fraction; in every
#   TDS partition touched the rank-1 row is EA015.
#
# Backups: verified whole-file snapshot; BACKUP CSVs of the target sample rows and the
# kept sibling analyses (neither is written). Idempotent: marker present -> re-verify
# against the SKIPPED CSV, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/071-backfill-dropped-fractions.R", envir = env)
#   env$mig071_run(db = ..., snapshot_dir = ..., dry_run = TRUE)

.mig071_marker_version <- 1071L
.mig071_requires <- 1070L
.mig071_name <- "071-backfill-dropped-fractions"
.mig071_actor <- .mig071_name
.mig071_n <- list(insert = 60L, fraction = 56L, tds = 4L, dissolved = 32L, total = 24L)
.mig071_reason <- paste0("071 (Robin 2026-10-22: keep both total and dissolved results; TDS keep both, prefer ",
                         "measured EA015): restore the result R-8.6 method preference dropped at import")

.mig071_fail <- function(msg) cli::cli_abort(paste0(.mig071_name, ": ", msg), class = "sampletidy_error")
.mig071_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig071_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig071_num <- function(x) ifelse(is.na(x) | !nzchar(x), NA_real_, suppressWarnings(as.numeric(x)))
.mig071_chr <- function(x) ifelse(is.na(x) | !nzchar(x), NA_character_, x)
.mig071_lgl <- function(x) ifelse(is.na(x) | !nzchar(x), NA, toupper(x) == "TRUE")

.mig071_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- inputs ---------------------------------------------------------------------------

.mig071_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT-analysis.csv", .mig071_name))
  if (!file.exists(p)) .mig071_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (anyDuplicated(x$uuid)) .mig071_fail("INPUT repeats an analysis uuid.")
  if (anyDuplicated(paste(x$uuid_sample, x$uuid_lab))) .mig071_fail("INPUT repeats a (sample, lab_method) pair.")
  if (!all(x$item %in% c("fraction", "tds"))) .mig071_fail("INPUT has an unknown item.")
  if (!all(x$expect %in% c("new_first", "sibling_first"))) .mig071_fail("INPUT has an unknown expect.")
  if (!all(x$gid == x$uuid_sample)) .mig071_fail("INPUT gid is not the target sample.")
  got <- list(insert = nrow(x), fraction = sum(x$item == "fraction"), tds = sum(x$item == "tds"),
              dissolved = sum(x$fraction %in% "dissolved"), total = sum(x$fraction %in% "total"))
  if (!identical(got, .mig071_n)) .mig071_fail(sprintf("INPUT counts are %s, not as planned.",
                                                       paste(names(got), unlist(got), sep = "=", collapse = " ")))
  if (any(x$item == "fraction" & is.na(x$fraction)) || any(x$item == "tds" & !is.na(x$fraction)))
    .mig071_fail("an INPUT fraction does not match its item.")
  if (anyNA(.mig071_num(x$value)) || anyNA(.mig071_lgl(x$quantified))) .mig071_fail("an INPUT value or quantified is missing.")
  x
}

# sha1 of each row as text (as 069/070; the frozen value comes from the same function).
.mig071_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df$uuid)
}

.mig071_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s', tbl, .mig071_inlist(ids)))
  s <- .mig071_df_sha(df)
  out[names(s)] <- s
  out[ids]
}

# ---- preconditions -----------------------------------------------------------------

# Hard failures abort; per-row problems come back as (gid, problem) for SKIPPED.
.mig071_check_preconditions <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig071_requires, have)
  if (length(miss)) .mig071_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  cols <- DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns WHERE table_name = 'lab_method'")$column_name
  if (!("fraction" %in% cols)) .mig071_fail("lab_method has no fraction column (070).")
  probs <- list()
  add <- function(gid, msg) if (length(gid)) probs[[length(probs) + 1]] <<- data.frame(gid = gid, problem = msg, stringsAsFactors = FALSE)

  ss <- .mig071_row_sha(con, "sample", x$uuid_sample)
  bad <- is.na(ss) | ss != x$sample_row_sha1
  add(x$gid[bad], sprintf("sample %s missing or not as frozen", x$uuid_sample[bad]))

  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_analyte, method, fraction FROM lab_method WHERE uuid IN %s",
                                     .mig071_inlist(c(x$uuid_lab))))
  l <- lm[match(x$uuid_lab, lm$uuid), , drop = FALSE]
  bad <- is.na(l$uuid) | is.na(l$uuid_analyte)
  add(x$gid[bad], sprintf("lab_method %s missing or has no analyte", x$uuid_lab[bad]))
  okf <- ifelse(x$item == "tds", is.na(l$fraction) & startsWith(l$method %|% "", "EA015:"),
                !is.na(l$fraction) & l$fraction == x$fraction %|% "")
  bad <- !is.na(l$uuid) & !okf
  add(x$gid[bad], sprintf("lab_method %s does not carry the planned fraction/method", x$uuid_lab[bad]))

  ex <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample, uuid_lab FROM analysis WHERE uuid IN %s OR uuid_sample IN %s",
                                     .mig071_inlist(x$uuid), .mig071_inlist(x$uuid_sample)))
  bad <- x$uuid %in% ex$uuid
  add(x$gid[bad], sprintf("analysis uuid %s already exists", x$uuid[bad]))
  bad <- paste(x$uuid_sample, x$uuid_lab) %in% paste(ex$uuid_sample, ex$uuid_lab)
  add(x$gid[bad], sprintf("pair (%s, %s) already stored", x$uuid_sample[bad], x$uuid_lab[bad]))

  sb <- .mig071_row_sha(con, "analysis", x$kept_sibling_uuid)
  bad <- is.na(sb) | sb != x$sibling_row_sha1
  add(x$gid[bad], sprintf("kept sibling %s missing or not as frozen", x$kept_sibling_uuid[bad]))
  sib <- DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.uuid_sample, lm.uuid_analyte, lm.method, lm.fraction FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab WHERE a.uuid IN %s", .mig071_inlist(x$kept_sibling_uuid)))
  s <- sib[match(x$kept_sibling_uuid, sib$uuid), , drop = FALSE]
  oks <- !is.na(s$uuid) & s$uuid_sample == x$uuid_sample & !is.na(l$uuid_analyte) & s$uuid_analyte == l$uuid_analyte &
    ifelse(x$item == "tds", is.na(s$fraction) & startsWith(s$method %|% "", "EA016:"),
           !is.na(s$fraction) & s$fraction != x$fraction %|% "")
  oks[is.na(oks)] <- FALSE
  bad <- !is.na(s$uuid) & !oks
  add(x$gid[bad], sprintf("kept sibling %s is not the same sample and analyte at the other fraction/EA016", x$kept_sibling_uuid[bad]))

  if (!length(probs)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  p <- do.call(rbind, probs)
  stats::aggregate(problem ~ gid, data = p, FUN = function(z) paste(unique(z), collapse = "; "))
}

`%|%` <- function(a, b) ifelse(is.na(a), b, a)

.mig071_restrict <- function(x, skipped) x[!(x$gid %in% skipped$gid), , drop = FALSE]

# ---- verify ---------------------------------------------------------------------------

# Partition key of the views (005/022): feature, Sydney date, analyte.
.mig071_rank_sql <- "
  SELECT v.uuid_analysis, v.uuid_sample, v.uuid_feature, v.date, v.analyte_name, v.analyte_units,
         v.preference_rank, lm.fraction, lm.method, f.flow
  FROM v_measurement v
  JOIN analysis a ON a.uuid = v.uuid_analysis
  JOIN lab_method lm ON lm.uuid = a.uuid_lab
  JOIN feature f ON f.uuid = v.uuid_feature
  WHERE v.uuid_sample IN %s"

.mig071_done_problem <- function(con, x, planned) {
  if (.mig071_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig071_marker_version) != 1L)
    return("marker 1071 missing")
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig071_inlist(x$uuid)))
  sk <- x$uuid[!(x$uuid %in% planned$uuid)]
  if (any(sk %in% A$uuid)) return("a skipped row was inserted")
  a <- A[match(planned$uuid, A$uuid), , drop = FALSE]
  eqn <- function(p, q) (is.na(p) & is.na(q)) | (!is.na(p) & !is.na(q) & p == q)
  eqc <- function(p, q) (is.na(p) & is.na(q)) | (!is.na(p) & !is.na(q) & p == q)
  ok <- !is.na(a$uuid) & a$uuid_sample == planned$uuid_sample & a$uuid_lab == planned$uuid_lab &
    eqn(a$value, .mig071_num(planned$value)) & eqn(a$rl_low, .mig071_num(planned$rl_low)) &
    eqn(a$rl_high, .mig071_num(planned$rl_high)) & eqc(a$value_chr, .mig071_chr(planned$value_chr)) &
    eqn(a$quantified, .mig071_lgl(planned$quantified)) & eqc(a$comments, .mig071_chr(planned$comments)) &
    eqc(a$purpose, .mig071_chr(planned$purpose))
  ok[is.na(ok)] <- FALSE
  if (!all(ok)) return(sprintf("analysis %s is not as planned", planned$uuid[!ok][[1]]))
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig071_actor))
  if (nrow(planned) && !(nrow(L) == 1L && L$tbl == "analysis" && L$action == "insert" && L$n == nrow(planned)))
    return(sprintf("071 change_log rows are %s", paste(L$tbl, L$action, L$n, collapse = " ")))
  if (!nrow(planned)) return(if (nrow(L)) "071 change_log rows exist for an empty plan" else NULL)
  # the views
  V <- DBI::dbGetQuery(con, sprintf(.mig071_rank_sql, .mig071_inlist(planned$uuid_sample)))
  rn <- V$preference_rank[match(planned$uuid, V$uuid_analysis)]
  rs <- V$preference_rank[match(planned$kept_sibling_uuid, V$uuid_analysis)]
  if (anyNA(rn)) return(sprintf("inserted analysis %s is not in v_measurement", planned$uuid[is.na(rn)][[1]]))
  if (anyNA(rs)) return(sprintf("kept sibling %s is not in v_measurement", planned$kept_sibling_uuid[is.na(rs)][[1]]))
  okr <- ifelse(planned$expect == "new_first", rn < rs, rs < rn)
  if (!all(okr)) return(sprintf("analysis %s ranks against its sibling the wrong way", planned$uuid[!okr][[1]]))
  V$part <- paste(V$uuid_feature, V$date, V$analyte_name, V$analyte_units, sep = "|")
  parts <- unique(V$part[match(planned$uuid, V$uuid_analysis)])
  for (pt in parts) {
    P <- V[V$part == pt, , drop = FALSE]
    top <- P[P$preference_rank == 1L, , drop = FALSE]
    if (nrow(top) != 1L) return(sprintf("partition %s has %d rank-1 rows", pt, nrow(top)))
    pref <- if (identical(P$flow[[1]], "groundwater")) "dissolved" else "total"
    if (any(startsWith(P$method, "EA015:")) && !startsWith(top$method, "EA015:"))
      return(sprintf("TDS partition %s does not pick EA015", pt))
    if (any(P$fraction %in% pref) && !(top$fraction %in% pref))
      return(sprintf("partition %s does not pick the %s result", pt, pref))
  }
  NULL
}

.mig071_verify <- function(con, x, planned) {
  pr <- .mig071_done_problem(con, x, planned)
  if (!is.null(pr)) cli::cli_abort(paste0("071 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig071_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_alias", "lab_method", "analyte", "project", "change_log", "schema_version")
  tabs <- intersect(tabs, DBI::dbListTables(con))
  stats::setNames(lapply(tabs, function(t) .mig071_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table except analysis/change_log/schema_version whole; those three
# outside this migration's own rows.
.mig071_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig071_inlist(x$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig071_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig071_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# ---- apply ---------------------------------------------------------------------------------

.mig071_why <- function(p, i) sprintf("%s [%s %s %s; %s; kept %s]", .mig071_reason, p$item[[i]], p$source_file[[i]],
                                      p$source_ref[[i]], p$lab_sample_id[[i]], p$kept_sibling_uuid[[i]])

.mig071_apply <- function(con, x, planned, recorded_at, logf) {
  sums_before <- .mig071_checksum(con, x)
  counts_want <- .mig071_counts(con)
  counts_want$analysis <- counts_want$analysis + nrow(planned)
  counts_want$change_log <- counts_want$change_log + nrow(planned)
  counts_want$schema_version <- counts_want$schema_version + 1L
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(planned))) {
      row <- tibble::tibble(uuid = planned$uuid[[i]], uuid_sample = planned$uuid_sample[[i]], uuid_lab = planned$uuid_lab[[i]],
                            value = .mig071_num(planned$value[[i]]), value_chr = .mig071_chr(planned$value_chr[[i]]),
                            quantified = .mig071_lgl(planned$quantified[[i]]), rl_low = .mig071_num(planned$rl_low[[i]]),
                            rl_high = .mig071_num(planned$rl_high[[i]]), purpose = .mig071_chr(planned$purpose[[i]]),
                            comments = .mig071_chr(planned$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig071_actor, reason = .mig071_why(planned, i),
                source_hash = planned$source_hash[[i]])
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig071_marker_version, recorded_at))
    .mig071_verify(con, x, planned)
    if (!identical(.mig071_counts(con), counts_want)) .mig071_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig071_checksum(con, x))) .mig071_fail("something outside the planned rows moved.")
    V <- DBI::dbGetQuery(con, sprintf(.mig071_rank_sql, .mig071_inlist(planned$uuid_sample)))
    r1 <- V[V$uuid_analysis %in% planned$uuid & V$preference_rank == 1L, , drop = FALSE]
    logf("Inserted %d analyses; %d of them now preference_rank 1 in v_measurement, %d rank behind their kept sibling.",
         nrow(planned), nrow(r1), sum(planned$expect == "sibling_first"))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig071_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig071_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig071_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig071_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig071_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("071: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig071_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig071_name, what))

.mig071_read_skipped <- function(csv_dir) {
  f <- .mig071_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ----------------------------------------------------------------------------------

mig071_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig071_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig071_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig071_read_skipped(csv_dir)
    if (is.null(sk)) .mig071_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig071_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      .mig071_ensure_icu(check_con)
      .mig071_verify(check_con, x, .mig071_restrict(x, sk))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("071 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  skipped <- tryCatch({
    if (.mig071_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig071_actor) > 0L)
      .mig071_fail("change_log already holds 071 rows but the marker is absent; refusing.")
    .mig071_check_preconditions(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  planned <- .mig071_restrict(x, skipped)
  logf("Plan: %d analysis inserts (%d fraction: %d dissolved, %d total; %d TDS EA015) on %d samples; %d sample group(s) skipped.",
       nrow(planned), sum(planned$item == "fraction"), sum(planned$fraction %in% "dissolved"),
       sum(planned$fraction %in% "total"), sum(planned$item == "tds"), length(unique(planned$gid)), nrow(skipped))
  if (nrow(skipped)) for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig071_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid",
                                                      .mig071_inlist(x$uuid_sample))),
                      .mig071_csv(csv_dir, "BACKUP-sample"), "uuid")
    .mig071_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid",
                                                      .mig071_inlist(x$kept_sibling_uuid))),
                      .mig071_csv(csv_dir, "BACKUP-analysis"), "uuid")
    .mig071_write_csv(skipped, .mig071_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig071_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig071_ensure_icu(con)
    again <- .mig071_check_preconditions(con, x)
    if (!identical(again, skipped)) .mig071_fail("the skip set changed since the dry check; re-run.")
    .mig071_apply(con, x, planned, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig071_name, .mig071_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
