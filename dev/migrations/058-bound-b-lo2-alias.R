# Operator-run migration: take Sydney day 2024-06-13 out of the 'B.LO2' -> B.L02
# alias and send that day to B.E01 instead. Marker 1058. Requires 1057.
#
# Authority: Robin, 2026-10-20 (corpus import phase 2): the corpus ALS
# ES2419948 'B.LO2' row on 2024-06-13 has Temp 11.8 / pH 8.3, equal to live
# B.E01 that day; Robin ruled that row is B.E01. Every other day stays B.L02.
#
# ---- WHAT ----------------------------------------------------------------------
# Alias 95ce1c0a-c0da-463e-bdcb-15ed4c34dd51 ('B.LO2' -> B.L02,
# transcription_error, auto, undated, confirmed_by 'R. Shannon', registered by
# migration 032) is split around 2024-06-13:
#   * db_update on the existing row: date_end = 2024-06-12; comments <-
#     "<existing>; 058 2026-10-20: split around 2024-06-13 (ES2419948 B.LO2 row
#     that day is B.E01 - its values equal live B.E01; Robin ruled 2026-10-20)";
#   * db_append of a second arm: same name / alias_key / uuid_feature / kind /
#     auto_assign / confirmed_by, date_start 2024-06-14, date_end NULL, n_seen 0,
#     first_seen/last_seen NULL, comments naming it the post-2024-06-13
#     continuation of 95ce1c0a;
#   * db_append of a one-day arm 'B.LO2' -> B.E01 (transcription_error - a
#     code written for another point, as 053 D - auto, confirmed_by
#     'R. Shannon'), date_start = date_end = 2024-06-13, n_seen 0, comments
#     giving the evidence (Temp 11.8 / pH 8.3 equal live B.E01 that day) and
#     Robin's ruling of 2026-10-20.
# Both new uuids are derived from (marker, key, target, window) exactly as 053's
# .mig053_uuid does, so rehearsals are reproducible. On 2024-06-13 the key
# 'b.lo2' then has exactly one live arm, B.E01.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1057 present;
#   * alias 95ce1c0a is exactly as described above (name, key, feature B.L02,
#     kind, auto_assign, confirmed_by, undated, the 032 comment verbatim);
#   * no other feature_alias row carries key 'b.lo2';
#   * feature B.L02 is not ended before 2024-06-14; feature B.E01 is exactly one
#     row and not ended before 2024-06-13;
#   * NO sample references alias 95ce1c0a on Sydney 2024-06-13
#     (cast(coalesce(date, datetime) + interval 11 hour as date)); at 1052 the
#     alias holds 0 samples in total;
#   * neither new uuid exists yet.
#
# Writes, in one transaction (actor "058-bound-b-lo2-alias"): 1 db_update (2
# change_log rows: date_end, comments), 2 db_append (1 change_log insert row
# each), the marker. Every other table, and every other feature_alias row and the split
# row's other columns, is checksummed before and after. Backups: verified
# whole-file snapshot, `058-...-BACKUP-feature_alias.csv` (the updated row,
# before) and `058-...-INSERTED-feature_alias.csv` (the two new arms, after).
#
# Verify: change_log exactly as above; both rows as planned; and the package
# resolver (.rc_resolve_features, the reconcile conveyor, with no report site and
# with report site 'B' = Blaxland) yields B.L02 for raw 'B.LO2' on 2024-06-12
# (through 95ce1c0a) and on 2024-06-14 (through the continuation arm), and
# B.E01 through the one-day arm on 2024-06-13.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/058-bound-b-lo2-alias.R", envir = env)
#   env$mig058_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig058_marker_version <- 1058L
.mig058_requires <- 1057L
.mig058_name <- "058-bound-b-lo2-alias"
.mig058_actor <- .mig058_name

.mig058_uuid_old <- "95ce1c0a-c0da-463e-bdcb-15ed4c34dd51"
.mig058_alias_name <- "B.LO2"
.mig058_key <- "b.lo2"
.mig058_target <- "B.L02"
.mig058_kind <- "transcription_error"
.mig058_confirmed_by <- "R. Shannon"
.mig058_old_comments <- paste0("032 (Robin, 2026-10-17: \"I'm happy for them to be registered now\"): B.LO2 -> B.L02, ",
                               "letter O for digit 0 (A78 table); registered undated so earlier workbooks resolve too.")
.mig058_parked_day <- as.Date("2024-06-13")
.mig058_old_end <- as.Date("2024-06-12")
.mig058_new_start <- as.Date("2024-06-14")
.mig058_new_comments_old_row <- paste0(.mig058_old_comments, "; 058 2026-10-20: split around 2024-06-13 ",
                                       "(ES2419948 B.LO2 row that day is B.E01 - its values equal live B.E01; Robin ruled 2026-10-20)")
.mig058_comment_new_arm <- paste0("058 2026-10-20: post-2024-06-13 continuation of alias 95ce1c0a (B.LO2 -> B.L02, ",
  "letter O for digit 0, registered by 032), which now ends 2024-06-12. Sydney 2024-06-13 is covered by the ",
  "one-day B.LO2 -> B.E01 arm instead: the ALS ES2419948 'B.LO2' row that day has Temp 11.8 / pH 8.3 equal to ",
  "live B.E01 (Robin ruled 2026-10-20)")
.mig058_e01_target <- "B.E01"
.mig058_comment_e01_arm <- paste0("058 2026-10-20: Sydney 2024-06-13 only, 'B.LO2' -> B.E01: the ALS ES2419948 'B.LO2' ",
  "row that day has Temp 11.8 / pH 8.3, equal to live B.E01 that day; Robin ruled 2026-10-20 that it is B.E01. ",
  "Every other day B.LO2 is B.L02 (alias 95ce1c0a and its continuation)")
.mig058_reason_update <- paste0("058 (Robin 2026-10-20): end B.LO2 -> B.L02 alias 2024-06-12; ",
                                "ES2419948 2024-06-13 B.LO2 row is B.E01")
.mig058_reason_insert <- paste0("058 (Robin 2026-10-20): B.LO2 -> B.L02 again from 2024-06-14 ",
                                "(continuation of 95ce1c0a)")
.mig058_reason_insert_e01 <- paste0("058 (Robin 2026-10-20): B.LO2 -> B.E01 for Sydney 2024-06-13 only ",
                                    "(ES2419948 values Temp 11.8 / pH 8.3 equal live B.E01)")

.mig058_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig058_fail <- function(msg) cli::cli_abort(paste0(.mig058_name, ": ", msg), class = "sampletidy_error")
.mig058_same_chr <- function(x, y) length(x) == 1L && length(y) == 1L && ((is.na(x) && is.na(y)) || (!is.na(x) && !is.na(y) && x == y))
.mig058_same_date <- function(x, y) {
  x <- as.Date(x); y <- as.Date(y)
  length(x) == 1L && length(y) == 1L && ((is.na(x) && is.na(y)) || (!is.na(x) && !is.na(y) && x == y))
}
# Deterministic uuid, as .mig053_uuid (053) derives it.
.mig058_uuid <- function(key, target, ds, de) {
  h <- digest::digest(paste(.mig058_marker_version, key, target, format(ds), format(de), sep = "|"),
                      algo = "sha1", serialize = FALSE)
  ch <- strsplit(substr(h, 1, 32), "")[[1]]
  ch[13] <- "5"
  ch[17] <- c("8", "9", "a", "b")[strtoi(ch[17], 16L) %% 4L + 1L]
  h <- paste(ch, collapse = "")
  paste(substr(h, 1, 8), substr(h, 9, 12), substr(h, 13, 16), substr(h, 17, 20), substr(h, 21, 32), sep = "-")
}
.mig058_uuid_new <- .mig058_uuid(.mig058_key, .mig058_target, .mig058_new_start, NA)
.mig058_uuid_e01 <- .mig058_uuid(.mig058_key, .mig058_e01_target, .mig058_parked_day, .mig058_parked_day)

.mig058_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analysis", "sample", "project", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig058_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig058_alias_row <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT fa.*, f.name AS fname, f.date_end AS f_date_end FROM feature_alias fa
                        LEFT JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.uuid = ?", params = list(uuid))
}

# The one row to insert, built from the existing row (so it carries its
# uuid_feature / name / kind / auto_assign / confirmed_by verbatim).
.mig058_new_row <- function(old) {
  tibble::tibble(
    uuid = .mig058_uuid_new, uuid_feature = old$uuid_feature, name = old$name, alias_key = old$alias_key,
    kind = old$kind, n_seen = 0L, auto_assign = old$auto_assign,
    first_seen = as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"),
    confirmed_by = old$confirmed_by, comments = .mig058_comment_new_arm,
    date_start = .mig058_new_start, date_end = as.Date(NA))
}

# The one-day B.E01 arm.
.mig058_e01_row <- function(old, uuid_e01_feature) {
  tibble::tibble(
    uuid = .mig058_uuid_e01, uuid_feature = uuid_e01_feature, name = old$name, alias_key = old$alias_key,
    kind = .mig058_kind, n_seen = 0L, auto_assign = TRUE,
    first_seen = as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(NA_real_, origin = "1970-01-01", tz = "UTC"),
    confirmed_by = .mig058_confirmed_by, comments = .mig058_comment_e01_arm,
    date_start = .mig058_parked_day, date_end = .mig058_parked_day)
}
.mig058_e01_feature <- function(con) {
  DBI::dbGetQuery(con, "SELECT uuid, date_end FROM feature WHERE name = ?", params = list(.mig058_e01_target))
}

.mig058_problems <- function(con) {
  probs <- character(0)
  old <- .mig058_alias_row(con, .mig058_uuid_old)
  if (nrow(old) != 1L || !identical(old$name, .mig058_alias_name) || !identical(old$alias_key, .mig058_key) ||
      !identical(old$fname, .mig058_target) || !identical(old$kind, .mig058_kind) || !isTRUE(old$auto_assign) ||
      !.mig058_same_chr(old$confirmed_by, .mig058_confirmed_by) || !is.na(old$date_start) || !is.na(old$date_end) ||
      !.mig058_same_chr(old$comments, .mig058_old_comments))
    probs <- c(probs, sprintf("alias %s is not 'B.LO2' -> B.L02, transcription_error, auto, confirmed 'R. Shannon', undated, 032 comment",
                              .mig058_uuid_old))
  if (nrow(old) == 1L) {
    fde <- .rc_as_date_bound(old$f_date_end)
    if (!is.na(fde) && fde < .mig058_new_start) probs <- c(probs, sprintf("feature B.L02 ended %s", fde))
  }
  n_k <- .mig058_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE alias_key = ? AND uuid <> ?",
                        .mig058_key, .mig058_uuid_old)
  if (n_k != 0L) probs <- c(probs, sprintf("%d other alias row(s) carry key '%s'", n_k, .mig058_key))
  n_s <- .mig058_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_feature_alias = ?
    AND CAST(coalesce(date, datetime) + INTERVAL 11 HOUR AS DATE) = ?", .mig058_uuid_old, .mig058_parked_day)
  if (n_s != 0L) probs <- c(probs, sprintf("%d sample(s) on alias %s on Sydney %s would lose their alias window",
                                           n_s, .mig058_uuid_old, .mig058_parked_day))
  for (u in c(.mig058_uuid_new, .mig058_uuid_e01))
    if (.mig058_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE uuid = ?", u) != 0L)
      probs <- c(probs, sprintf("planned uuid %s already exists", u))
  fe <- .mig058_e01_feature(con)
  if (nrow(fe) != 1L) {
    probs <- c(probs, sprintf("feature %s is %d rows, expected 1", .mig058_e01_target, nrow(fe)))
  } else {
    fde <- .rc_as_date_bound(fe$date_end)
    if (!is.na(fde) && fde < .mig058_parked_day) probs <- c(probs, sprintf("feature B.E01 ended %s", fde))
  }
  probs
}

.mig058_check_preconditions <- function(con) {
  if (.mig058_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig058_requires) == 0L)
    .mig058_fail(sprintf("marker %d (057) is required first.", .mig058_requires))
  probs <- .mig058_problems(con)
  if (length(probs)) .mig058_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  n_all <- .mig058_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_feature_alias = ?", .mig058_uuid_old)
  list(old = .mig058_alias_row(con, .mig058_uuid_old), n_samples = n_all, e01 = .mig058_e01_feature(con)$uuid)
}

.mig058_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN ('%s', '%s', '%s') ORDER BY uuid",
                                      .mig058_uuid_old, .mig058_uuid_new, .mig058_uuid_e01))
  out$feature_alias_split <- q(sprintf("SELECT * EXCLUDE (date_end, comments) FROM feature_alias WHERE uuid = '%s'",
                                       .mig058_uuid_old))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig058_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig058_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# Resolve raw 'B.LO2' on `day` through the reconcile conveyor itself
# (.rc_resolve_features, as reconcile calls it per event), optionally inside an
# ACIRL report of `report_site`. Returns list(uuid_feature, uuid_alias, pending).
.mig058_resolve <- function(day, reg, report_site = NA_character_) {
  rows <- tibble::tibble(feature_raw = .mig058_alias_name,
                         sample_datetime_raw = format(as.Date(day), "%d %b %Y"),
                         source_ref = "058-verify", source_hash = "058-verify")
  r <- .rc_resolve_features(rows, reg, work_order = "058-verify", orphan = FALSE, report_site = report_site)$kept
  list(uuid_feature = r$uuid_feature[[1]], uuid_alias = r$uuid_feature_alias[[1]], pending = r$feature_pending[[1]])
}

.mig058_done_problem <- function(con) {
  if (.mig058_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig058_marker_version) != 1L)
    return("marker 1058 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ? ORDER BY action, field",
                        params = list(.mig058_actor))
  ins <- cl[cl$action == "insert", , drop = FALSE]
  upd <- cl[cl$action == "update", , drop = FALSE]
  ue <- upd[upd$field %in% "date_end", , drop = FALSE]
  uc <- upd[upd$field %in% "comments", , drop = FALSE]
  if (nrow(cl) != 4L || nrow(ins) != 2L || any(ins$tbl != "feature_alias") ||
      !setequal(ins$uuid_row, c(.mig058_uuid_new, .mig058_uuid_e01)) ||
      nrow(upd) != 2L || any(upd$tbl != "feature_alias") || any(upd$uuid_row != .mig058_uuid_old) ||
      nrow(ue) != 1L || !is.na(ue$old) || ue$new != .st_changelog_str(.mig058_old_end) ||
      nrow(uc) != 1L || !.mig058_same_chr(uc$old, .mig058_old_comments) ||
      !.mig058_same_chr(uc$new, .mig058_new_comments_old_row))
    return(sprintf("058 change_log is %d row(s), not 2 inserts + date_end/comments updates as planned", nrow(cl)))
  old <- .mig058_alias_row(con, .mig058_uuid_old)
  new <- .mig058_alias_row(con, .mig058_uuid_new)
  if (nrow(old) != 1L || !identical(old$fname, .mig058_target) || !is.na(old$date_start) ||
      !.mig058_same_date(old$date_end, .mig058_old_end) || !.mig058_same_chr(old$comments, .mig058_new_comments_old_row))
    return(sprintf("alias %s is not -> B.L02 ending %s with the 058 comment", .mig058_uuid_old, .mig058_old_end))
  if (nrow(new) != 1L || !identical(new$uuid_feature, old$uuid_feature) || !identical(new$name, old$name) ||
      !identical(new$alias_key, old$alias_key) || !identical(new$kind, old$kind) ||
      !identical(new$auto_assign, old$auto_assign) || !.mig058_same_chr(new$confirmed_by, old$confirmed_by) ||
      !.mig058_same_date(new$date_start, .mig058_new_start) || !is.na(new$date_end) ||
      !.mig058_same_chr(new$comments, .mig058_comment_new_arm) || new$n_seen != 0L ||
      !is.na(new$first_seen) || !is.na(new$last_seen))
    return(sprintf("new arm %s differs from the plan", .mig058_uuid_new))
  e01 <- .mig058_alias_row(con, .mig058_uuid_e01)
  fe <- .mig058_e01_feature(con)
  if (nrow(e01) != 1L || nrow(fe) != 1L || !identical(e01$uuid_feature, fe$uuid) || !identical(e01$name, old$name) ||
      !identical(e01$alias_key, .mig058_key) || !identical(e01$kind, .mig058_kind) || !isTRUE(e01$auto_assign) ||
      !.mig058_same_chr(e01$confirmed_by, .mig058_confirmed_by) ||
      !.mig058_same_date(e01$date_start, .mig058_parked_day) || !.mig058_same_date(e01$date_end, .mig058_parked_day) ||
      !.mig058_same_chr(e01$comments, .mig058_comment_e01_arm) || e01$n_seen != 0L ||
      !is.na(e01$first_seen) || !is.na(e01$last_seen))
    return(sprintf("B.E01 arm %s differs from the plan", .mig058_uuid_e01))
  if (.mig058_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE alias_key = ?", .mig058_key) != 3L)
    return("key 'b.lo2' does not carry exactly the three 058 arms")
  # Through the reconcile conveyor, without and with a Blaxland report site.
  reg <- .rc_load_registry(con)
  for (rs in c(NA_character_, "B")) {
    lbl <- if (is.na(rs)) "no report site" else paste0("report site ", rs)
    for (ck in list(list(.mig058_old_end, .mig058_uuid_old), list(.mig058_new_start, .mig058_uuid_new))) {
      r <- .mig058_resolve(ck[[1]], reg, rs)
      if (isTRUE(r$pending) || !.mig058_same_chr(r$uuid_feature, old$uuid_feature) || !.mig058_same_chr(r$uuid_alias, ck[[2]]))
        return(sprintf("'B.LO2' on %s (%s) does not resolve to B.L02 through %s", ck[[1]], lbl, ck[[2]]))
    }
    r <- .mig058_resolve(.mig058_parked_day, reg, rs)
    if (isTRUE(r$pending) || !.mig058_same_chr(r$uuid_feature, fe$uuid) || !.mig058_same_chr(r$uuid_alias, .mig058_uuid_e01))
      return(sprintf("'B.LO2' on %s (%s) resolves (%s / %s), not to B.E01 through %s", .mig058_parked_day, lbl,
                     r$uuid_feature, r$uuid_alias, .mig058_uuid_e01))
  }
  NULL
}

.mig058_verify <- function(con) {
  p <- .mig058_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("058 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig058_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig058_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig058_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig058_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig058_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("058: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig058_apply <- function(con, pre, recorded_at) {
  sums_before <- .mig058_checksum(con)
  want <- .mig058_counts(con)
  want$feature_alias <- want$feature_alias + 2L
  want$change_log <- want$change_log + 4L
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    db_update(con, "feature_alias", uuid = .mig058_uuid_old,
              changes = list(date_end = .mig058_old_end, comments = .mig058_new_comments_old_row),
              actor = .mig058_actor, reason = .mig058_reason_update)
    db_append(con, "feature_alias", .mig058_new_row(pre$old), actor = .mig058_actor, reason = .mig058_reason_insert)
    db_append(con, "feature_alias", .mig058_e01_row(pre$old, pre$e01), actor = .mig058_actor,
              reason = .mig058_reason_insert_e01)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig058_marker_version, recorded_at))
    .mig058_verify(con)
    got <- .mig058_counts(con)
    if (!identical(got, want))
      .mig058_fail(sprintf("counts are not before + 2 alias, + 4 change_log, + 1 marker: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig058_checksum(con))) .mig058_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig058_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig058_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig058_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("058 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch(.mig058_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: alias %s ('B.LO2' -> B.L02, %d sample(s), none on %s) date_end -> %s, comment appended; new arm %s from %s, open end; one-day arm %s -> B.E01 on %s.",
       .mig058_uuid_old, pre$n_samples, .mig058_parked_day, .mig058_old_end, .mig058_uuid_new, .mig058_new_start,
       .mig058_uuid_e01, .mig058_parked_day)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig058_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM feature_alias WHERE uuid = ?",
                                             params = list(.mig058_uuid_old)),
                             file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig058_name))),
           finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig058_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    pre <- .mig058_check_preconditions(con)   # re-read under the write lock
    .mig058_apply(con, pre, recorded_at)
  }, db = db)

  out_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig058_write_csv(DBI::dbGetQuery(out_con, "SELECT * FROM feature_alias WHERE uuid IN (?, ?) ORDER BY date_start",
                                             params = list(.mig058_uuid_new, .mig058_uuid_e01)),
                             file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig058_name))),
           finally = DBI::dbDisconnect(out_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d): 1 alias updated, 2 inserted.", .mig058_name, .mig058_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
