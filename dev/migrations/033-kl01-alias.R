# Operator-run migration: register KL01 -> K.L01 as an undated
# `transcription_error` (dropped site separator) alias, exactly as 032's
# KS07 / KS05 / KE01 rows. Marker 1033. Requires 1032.
#
# Authorised by the main session, 2026-10-17, in the spirit of Robin's 032
# ruling ("I'm happy for them to be registered now"). 032 left KL01 out as
# "not in the ruling" (1 corpus row); ALS ES2620363, not yet imported, carries
# 40 rows under "KL01", ahead of tonight's live import.
#
# Preconditions: K.L01 is exactly one feature, with no date_end; no alias has
# the key `kl01` or the name KL01 (case-insensitive); every alias sharing
# the FOLDED key (.rc_method_key, "kl01") points at K.L01 (on live: only its
# self alias k.l01). No feature site is "KL" (sites B, BH, K, L), so the
# dropped-dot reading is the only one.
#
# Writes: 1 feature_alias row via db_append() (1 change_log row, actor
# "033-kl01-alias") and the marker. Everything else is checksummed before and
# after. No backup CSV of existing rows (none change); the inserted row is in
# `033-kl01-alias-INSERTED-feature_alias.csv`, plus the verified whole-file
# backup in `snapshot_dir`. Rehearsal: scratchpad/2026-10-17-mig032/ (r033a, r033b).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/033-kl01-alias.R", envir = env)
#   env$mig033_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig033_marker_version <- 1033L
.mig033_requires <- 1032L
.mig033_name <- "033-kl01-alias"
.mig033_actor <- .mig033_name
.mig033_alias <- "KL01"
.mig033_target <- "K.L01"
.mig033_comment <- "033 (main session, 2026-10-17, following Robin's 032 ruling \"I'm happy for them to be registered now\"): KL01 -> K.L01, dropped site separator (as KS07/KS05/KE01); registered undated so earlier workbooks resolve too."

.mig033_default <- function(x, default) if (is.null(x)) default else x
.mig033_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig033_fail <- function(msg) cli::cli_abort(paste0(.mig033_name, ": ", msg), class = "sampletidy_error")
.mig033_key <- function() .rc_feature_key(.mig033_alias)

.mig033_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig033_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig033_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE alias_key <> '%s' ORDER BY uuid", .mig033_key()))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig033_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig033_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig033_target_uuid <- function(con) {
  f <- DBI::dbGetQuery(con, "SELECT uuid, date_end FROM feature WHERE name = ?", params = list(.mig033_target))
  if (nrow(f) != 1L) .mig033_fail(sprintf("%s is %d features, expected exactly 1.", .mig033_target, nrow(f)))
  if (!is.na(f$date_end)) .mig033_fail(sprintf("%s has a date_end.", .mig033_target))
  if (.mig033_scalar(con, "SELECT COUNT(*) FROM feature WHERE site = 'KL'")) .mig033_fail("a feature site 'KL' exists; KL01 would be ambiguous.")
  f$uuid
}

.mig033_check_preconditions <- function(con) {
  if (.mig033_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig033_requires) == 0L) {
    .mig033_fail(sprintf("marker %d (032) is required first.", .mig033_requires))
  }
  tgt <- .mig033_target_uuid(con)
  fa <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature, name, alias_key FROM feature_alias")
  if (any(fa$alias_key == .mig033_key())) .mig033_fail(sprintf("key %s already exists. Nothing written.", .mig033_key()))
  if (any(tolower(fa$name) == tolower(.mig033_alias))) .mig033_fail(sprintf("name %s already exists. Nothing written.", .mig033_alias))
  twin <- fa[!is.na(fa$alias_key) & .rc_method_key(fa$alias_key) == .rc_method_key(.mig033_key()), , drop = FALSE]
  if (any(is.na(twin$uuid_feature) | twin$uuid_feature != tgt))
    .mig033_fail("the folded key kl01 is shared with an alias of another feature. Nothing written.")
  invisible(list(target = tgt))
}

.mig033_done_problem <- function(con) {
  tgt <- DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(.mig033_target))$uuid
  fa <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = ?", params = list(.mig033_key()))
  if (nrow(fa) != 1L) return(sprintf("%d rows carry key %s, expected 1", nrow(fa), .mig033_key()))
  if (length(tgt) != 1L || !identical(fa$uuid_feature, tgt) || !identical(fa$name, .mig033_alias) ||
      !identical(fa$kind, "transcription_error") || !isTRUE(fa$auto_assign) || !identical(fa$confirmed_by, "R. Shannon") ||
      !is.na(fa$date_start) || !is.na(fa$date_end) || !identical(fa$n_seen, 0L) || !identical(fa$comments, .mig033_comment))
    return("the kl01 alias is not the planned undated, confirmed, auto_assign transcription_error row to K.L01")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row FROM change_log WHERE actor = ?", params = list(.mig033_actor))
  if (nrow(cl) != 1L || cl$tbl != "feature_alias" || cl$action != "insert" || cl$uuid_row != fa$uuid)
    return("change_log does not hold exactly the one insert row")
  reg <- .rc_load_registry(con)
  for (d in c("2015-01-01", "2024-04-15", "2030-01-01")) {
    cand <- .rc_feature_candidates(.mig033_alias, as.Date(d), reg)
    if (nrow(cand) != 1L || cand$uuid_feature != tgt) return(sprintf("KL01 does not resolve to K.L01 at %s", d))
  }
  NULL
}

.mig033_verify <- function(con) {
  p <- .mig033_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("033 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig033_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig033_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig033_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig033_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig033_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig033_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("033: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig033_apply <- function(con, target, recorded_at) {
  sums_before <- .mig033_checksum(con)
  want <- .mig033_counts(con)
  want$feature_alias <- want$feature_alias + 1L
  want$change_log <- want$change_log + 1L
  want$schema_version <- want$schema_version + 1L
  now <- Sys.time()
  row <- tibble::tibble(
    uuid = uuid::UUIDgenerate(), uuid_feature = target, name = .mig033_alias, alias_key = .mig033_key(),
    kind = "transcription_error", n_seen = 0L, auto_assign = TRUE, first_seen = now, last_seen = now,
    confirmed_by = "R. Shannon", comments = .mig033_comment, date_start = as.Date(NA), date_end = as.Date(NA))
  db_transaction(con, function(con) {
    db_append(con, "feature_alias", row, actor = .mig033_actor,
              reason = "033 (main session, 2026-10-17, after Robin's 032 ruling): register KL01 -> K.L01 as an undated transcription_error alias")
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig033_marker_version, recorded_at))
    .mig033_verify(con)
    if (!identical(.mig033_counts(con), want)) {
      cli::cli_abort("033 verify failed: counts are not before plus exactly 1 alias, 1 change_log, 1 marker.", class = "sampletidy_error")
    }
    if (!identical(sums_before, .mig033_checksum(con))) {
      cli::cli_abort("033 verify failed: something outside the planned row moved.", class = "sampletidy_error")
    }
    NULL
  })
  row
}

mig033_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig033_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig033_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("033 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig033_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: register KL01 -> K.L01 (transcription_error, undated). No collision.")
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig033_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig033_default(.now, Sys.time())

  row <- with_db_write(function(con) {
    p <- .mig033_check_preconditions(con)   # re-read under the write lock
    .mig033_apply(con, p$target, recorded_at)
  }, db = db)
  .mig033_write_csv(row, file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig033_name)))

  logf("%s migrated successfully (marker %d).", .mig033_name, .mig033_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
