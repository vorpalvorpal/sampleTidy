# Operator-run migration: correct the start date (feature.date_start) of the
# Blaxland SUCCESSOR gas grid (B.G182-B.G367, 185 points) to the day its first round was
# sampled, 2024-02-19 (Sydney), the day after the old grid's date_end (044).
# Marker 1046. Requires 1045.
#
# Authority: Robin, 2026-10-19: "Same fix for Blaxland" (as 045 for Katoomba).
# The registry says 2023-02-09, which is wrong. Katoomba (045) is NOT touched.
#
# ---- WHAT ----------------------------------------------------------------------
# Successors are DERIVED, not typed: the B gas grid features (`B.G<digits>`,
# name prefix = site) whose feature_mask `old` name is a K gas grid feature
# (as 045, matched by point number: 185 points). new_start = the earliest Sydney sample date on any of them
# (stored timestamps are 13:00 UTC = Sydney midnight, so Sydney dates are
# used throughout, never UTC dates) and it must equal the day after the old
# grid's date_end (B.G001 etc., 2024-02-18 after 044).
#   * each successor with date_start <> new_start gets date_start := new_start;
#   * each feature_alias on a successor with a NON-NULL date_start equal to the
#     feature's old date_start gets the same date_start (on live: none - the
#     self and mask_long aliases are undated), end untouched.
# The resolver never reads a feature date_start; this is a registry correction.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1045 present;
#   * the plan is exactly the measured one (.mig046_expected): feature count,
#     uniform old date_start, new_start, alias count;
#   * NO SAMPLE precedes new_start on any successor (a start is never moved
#     past an existing sample) - exceptions are listed in the error;
#   * every dated alias on a successor carries the feature's old date_start.
#
# Writes, in one transaction: db_update of feature.date_start (and any dated
# alias), actor "046-blaxland-gas-grid-start-dates", and the marker; every
# other table, row and column is checksummed before and after. Backups:
# verified whole-file snapshot, plus `046-...-BACKUP-{feature,feature_alias}.csv`
# (touched rows, before; the alias file is header-only if none).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/046-blaxland-gas-grid-start-dates.R", envir = env)
#   env$mig046_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig046_marker_version <- 1046L
.mig046_requires <- 1045L
.mig046_name <- "046-blaxland-gas-grid-start-dates"
.mig046_actor <- .mig046_name
.mig046_site <- "B"
.mig046_expected <- list(n_feature = 185L, n_alias = 0L, old_start = as.Date("2023-02-09"),
                         new_start = as.Date("2024-02-19"), old_grid_end = as.Date("2024-02-18"))
.mig046_reason <- function(old_start, new_start) {
  sprintf("046 (Robin, 2026-10-19: Same fix for Blaxland): successor gas grid first sampled %s; date_start %s -> %s",
          format(new_start), format(old_start), format(new_start))
}

.mig046_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig046_fail <- function(msg) cli::cli_abort(paste0(.mig046_name, ": ", msg), class = "sampletidy_error")
.mig046_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", x, "'", collapse = ","), ")")
.mig046_syd <- function(x) as.Date(x, tz = "Australia/Sydney")

.mig046_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analysis", "sample", "project", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig046_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig046_grid <- function(con) {
  f <- DBI::dbGetQuery(con, "SELECT uuid, name, site, date_start, date_end FROM feature WHERE site IN ('B', 'K')")
  m <- regmatches(f$name, regexec("^([A-Z]+)\\.G([0-9]+)$", f$name))
  ok <- lengths(m) == 3L
  f <- f[ok, , drop = FALSE]
  f$prefix <- vapply(m[ok], `[[`, character(1), 2L)
  f <- f[f$prefix == f$site, , drop = FALSE]
  f$date_start <- as.Date(f$date_start); f$date_end <- as.Date(f$date_end)
  f
}

# `old` names are compared by point NUMBER (digits as an integer) within the
# site, because one can be unpadded (K.G232's old name is "K.G99", which 044's
# literal match missed; Blaxland has no such typo: all 185 match literally too).
.mig046_gnum <- function(x) {
  m <- regmatches(x, regexec("^([A-Z]+)\\.G([0-9]+)$", x))
  vapply(m, function(v) if (length(v) == 3L) paste0(v[[2]], "|", as.integer(v[[3]])) else NA_character_, character(1))
}
.mig046_successors <- function(con, grid, site) {
  fm <- DBI::dbGetQuery(con, "SELECT uuid_feature, name FROM feature_mask WHERE variant = 'old' AND name IS NOT NULL")
  g <- grid[grid$site == site, , drop = FALSE]
  fm <- fm[fm$uuid_feature %in% g$uuid, , drop = FALSE]
  fm$k <- .mig046_gnum(fm$name)
  fm$self <- .mig046_gnum(g$name[match(fm$uuid_feature, g$uuid)])
  fm <- fm[!is.na(fm$k) & fm$k != fm$self & fm$k %in% .mig046_gnum(g$name), , drop = FALSE]
  unique(fm$uuid_feature)
}

.mig046_plan <- function(con) {
  grid <- .mig046_grid(con)
  s <- .mig046_site
  succ <- .mig046_successors(con, grid, s)
  succ_f <- grid[grid$uuid %in% succ, , drop = FALSE]
  smp <- if (length(succ)) DBI::dbGetQuery(con, sprintf("SELECT fa.uuid_feature, s.date FROM sample s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias WHERE fa.uuid_feature IN %s", .mig046_inlist(succ)))
  else data.frame(uuid_feature = character(0), date = as.POSIXct(character(0)))
  smp$d <- .mig046_syd(smp$date)
  if (!nrow(smp)) .mig046_fail("the successor grid has no samples - nothing to derive the start from.")
  new_start <- min(smp$d)
  # The old grid's (post-045) retirement date: B gas grid features not successors with a date_end.
  old <- grid[grid$site == s & !(grid$uuid %in% succ) & !is.na(grid$date_end) & grid$date_end >= as.Date("2023-01-01"), , drop = FALSE]
  first_by <- tapply(as.numeric(smp$d), smp$uuid_feature, min)
  succ_f$first_sample <- as.Date(unname(first_by[succ_f$uuid]), origin = "1970-01-01")
  early <- succ_f[!is.na(succ_f$first_sample) & succ_f$first_sample < new_start, , drop = FALSE]
  fa <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias")
  a <- fa[fa$uuid_feature %in% succ & !is.na(fa$date_start), , drop = FALSE]
  a$f_start <- succ_f$date_start[match(a$uuid_feature, succ_f$uuid)]
  a$target <- succ_f$name[match(a$uuid_feature, succ_f$uuid)]
  feat <- succ_f[is.na(succ_f$date_start) | succ_f$date_start != new_start, , drop = FALSE]
  list(new_start = new_start, old_grid_end = unique(old$date_end), successors = succ_f, feature = feat,
       alias = a, early = early, last_first = max(succ_f$first_sample, na.rm = TRUE),
       n_no_sample = sum(is.na(succ_f$first_sample)))
}

.mig046_problems <- function(p) {
  x <- .mig046_expected; probs <- character(0)
  if (p$new_start != x$new_start) probs <- c(probs, sprintf("new_start derives to %s, measured %s", p$new_start, x$new_start))
  if (!identical(as.character(p$old_grid_end), format(x$old_grid_end)))
    probs <- c(probs, sprintf("old grid date_end is %s, expected the single value %s", paste(p$old_grid_end, collapse = ","), x$old_grid_end))
  if (length(p$old_grid_end) == 1L && p$new_start != p$old_grid_end + 1L)
    probs <- c(probs, sprintf("new_start %s is not the day after the old grid's date_end %s", p$new_start, p$old_grid_end))
  if (nrow(p$feature) != x$n_feature) probs <- c(probs, sprintf("plan moves %d features, measured %d", nrow(p$feature), x$n_feature))
  if (nrow(p$feature) && any(p$feature$date_start != x$old_start))
    probs <- c(probs, sprintf("a successor's date_start is not %s", x$old_start))
  if (nrow(p$alias) != x$n_alias) probs <- c(probs, sprintf("%d dated aliases on successors, measured %d", nrow(p$alias), x$n_alias))
  if (nrow(p$alias) && any(p$alias$date_start != p$alias$f_start))
    probs <- c(probs, "a dated alias on a successor does not carry its feature's date_start")
  if (nrow(p$early))
    probs <- c(probs, sprintf("%d successor(s) have a sample before %s (not moved past it): %s", nrow(p$early), p$new_start,
                              paste(sprintf("%s %s", p$early$name, p$early$first_sample), collapse = ", ")))
  probs
}

.mig046_check_preconditions <- function(con) {
  if (.mig046_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig046_requires) == 0L)
    .mig046_fail(sprintf("marker %d (045) is required first.", .mig046_requires))
  p <- .mig046_plan(con)
  probs <- .mig046_problems(p)
  if (length(probs)) .mig046_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  p
}

.mig046_checksum <- function(con, fu, au) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("feature", "feature_alias", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  f <- .mig046_inlist(fu); a <- .mig046_inlist(au)
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", f))
  out$feature_fixed <- q(sprintf("SELECT * EXCLUDE (date_start) FROM feature WHERE uuid IN %s ORDER BY uuid", f))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", a))
  out$alias_fixed <- q(sprintf("SELECT * EXCLUDE (date_start) FROM feature_alias WHERE uuid IN %s ORDER BY uuid", a))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig046_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig046_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig046_done_problem <- function(con) {
  x <- .mig046_expected
  if (.mig046_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig046_marker_version) != 1L)
    return("marker 1046 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig046_actor))
  if (nrow(cl) != x$n_feature + x$n_alias || any(cl$action != "update") || any(cl$field != "date_start") ||
      anyDuplicated(cl$uuid_row) || sum(cl$tbl == "feature") != x$n_feature || sum(cl$tbl == "feature_alias") != x$n_alias)
    return(sprintf("046 change_log is %d row(s), expected %d feature + %d feature_alias date_start updates",
                   nrow(cl), x$n_feature, x$n_alias))
  if (any(cl$old != format(x$old_start)) || any(cl$new != format(x$new_start)))
    return(sprintf("a 046 change_log row is not %s -> %s", x$old_start, x$new_start))
  grid <- .mig046_grid(con)
  succ <- .mig046_successors(con, grid, .mig046_site)
  if (length(succ) != x$n_feature || !setequal(succ, cl$uuid_row[cl$tbl == "feature"]))
    return("the logged features are not exactly the derived successor set")
  sf <- grid[grid$uuid %in% succ, , drop = FALSE]
  if (any(is.na(sf$date_start)) || any(sf$date_start != x$new_start)) return("a successor's date_start is not the new start")
  # Nothing sampled before the start; the first sample is exactly the start.
  smp <- DBI::dbGetQuery(con, sprintf("SELECT s.date FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    WHERE fa.uuid_feature IN %s", .mig046_inlist(succ)))
  d <- .mig046_syd(smp$date)
  if (!length(d) || min(d) != x$new_start) return(sprintf("successor first sample is %s, not %s", if (length(d)) min(d) else NA, x$new_start))
  # Old-grid retirement (044) is intact and abuts the new start.
  old <- grid[grid$site == .mig046_site & !(grid$uuid %in% succ) & !is.na(grid$date_end) & grid$date_end >= as.Date("2023-01-01"), , drop = FALSE]
  if (!identical(format(unique(old$date_end)), format(x$old_grid_end))) return("old grid date_end is no longer 2024-02-18")
  # Successors still resolve by their own names (date_start is never read, so nothing may move).
  reg <- .rc_load_registry(con)
  for (i in seq_len(nrow(sf))) {
    c1 <- .rc_feature_candidates(sf$name[[i]], x$new_start, reg)
    if (nrow(c1) != 1L || c1$uuid_feature != sf$uuid[[i]]) return(sprintf("%s does not resolve uniquely to itself on %s", sf$name[[i]], x$new_start))
  }
  # Katoomba untouched (045 set its successors to 2024-03-04).
  k <- grid[grid$site == "K" & grid$uuid %in% .mig046_successors(con, grid, "K"), , drop = FALSE]
  if (any(is.na(k$date_start)) || any(k$date_start != as.Date("2024-03-04"))) return("Katoomba successors' date_start changed")
  NULL
}

.mig046_verify <- function(con) {
  p <- .mig046_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("046 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig046_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig046_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig046_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig046_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig046_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("046: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig046_apply <- function(con, p, recorded_at) {
  fu <- p$feature$uuid; au <- p$alias$uuid
  sums_before <- .mig046_checksum(con, fu, au)
  want <- .mig046_counts(con)
  want$change_log <- want$change_log + length(fu) + length(au)
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(p$feature))) {
      r <- p$feature[i, ]
      db_update(con, "feature", uuid = r$uuid, changes = list(date_start = as.Date(p$new_start)),
                actor = .mig046_actor, reason = .mig046_reason(r$date_start, p$new_start))
    }
    for (i in seq_len(nrow(p$alias))) {
      r <- p$alias[i, ]
      db_update(con, "feature_alias", uuid = r$uuid, changes = list(date_start = as.Date(p$new_start)),
                actor = .mig046_actor, reason = paste0(.mig046_reason(r$date_start, p$new_start),
                                                       sprintf("; alias %s -> %s follows its feature", r$name, r$target)))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig046_marker_version, recorded_at))
    .mig046_verify(con)
    got <- .mig046_counts(con)
    if (!identical(got, want))
      .mig046_fail(sprintf("counts are not before + %d change_log, + 1 marker: %s", length(fu) + length(au),
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig046_checksum(con, fu, au))) .mig046_fail("something outside the planned rows/column moved.")
    NULL
  })
  invisible(NULL)
}

mig046_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig046_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig046_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("046 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  p <- tryCatch(.mig046_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  sf <- p$successors
  logf("B successor grid %d features (%s..%s), first sampled %s (latest first-sample %s; %d without samples); old grid ends %s.",
       nrow(sf), min(sf$name), max(sf$name), p$new_start, p$last_first, p$n_no_sample, p$old_grid_end)
  logf("Move date_start %s -> %s on %d features; %d dated aliases follow; 0 successors sampled before the new start.",
       paste(unique(format(p$feature$date_start)), collapse = ","), p$new_start, nrow(p$feature), nrow(p$alias))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p[c("feature", "alias")])))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig046_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM feature WHERE uuid IN %s ORDER BY name",
                                                      .mig046_inlist(p$feature$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-feature.csv", .mig046_name)))
    .mig046_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY name",
                                                      .mig046_inlist(p$alias$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig046_name)))
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig046_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    p <- .mig046_check_preconditions(con)   # re-read under the write lock
    .mig046_apply(con, p, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d features, %d aliases.", .mig046_name, .mig046_marker_version,
       nrow(p$feature), nrow(p$alias))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
