# Operator-run migration: register the UNPADDED spellings of the Blaxland and
# Katoomba gas grid numbers as confirmed aliases of the zero-padded registered
# points - "B.G1" / "B.G01" -> B.G001, "K.G26" -> K.G026, "K.G1" -> K.G01.
# Marker 1041. Requires 1040.
#
# Authority: Robin, 2026-10-19: "G1 is G001". Same site, same integer gas grid
# number -> the same point. Gas grid numbers only; NOT a licence for any other
# numeric folding (memory cypher-and-feature-alias, padding bullet).
#
# ---- WHAT --------------------------------------------------------------------
# The plan is DERIVED from the registry, not typed in: every feature named
# `<site>.G<digits>` with site B or K (the name prefix is its own `site`). For a
# point of integer n written with w digits, every SHORTER zero-padded spelling
# (widths nchar(n) .. w-1) becomes one alias - B.G001 -> B.G1 and B.G01;
# B.G045 -> B.G45; K.G026 -> K.G26; K.G01 -> K.G1. A point already written
# unpadded (B.G100, K.G13, K.G186) yields nothing.
#
# Measured on live at 1040 (2026-10-19): 108 B aliases (B.G1-B.G9 x2 widths,
# B.G10-B.G99) and 83 K aliases (K.G1-K.G9 -> K.G01-K.G09, K.G26-K.G99 ->
# K.G026-K.G099); 191 in all, zero skipped. The corpus rehearsal's unpadded
# codes (scratchpad/2026-10-19-corpus, review_items_new_pass1.csv) are exactly
# B.G1-B.G99, all inside the plan; the K workbooks write K.G026.. padded already.
#
# SKIPPED, and reported (never written), per candidate spelling:
#   * the (site, integer) reaches 0 or >1 registered gas grid features;
#   * the spelling is itself a registered feature name (case-insensitive);
#   * ANY feature_alias row already carries the key (an existing alias is
#     never touched - it is reported, with the feature it points at).
# A 0- or >1-candidate integer cannot arise from a derived plan unless the
# registry changes, so a non-empty skip list on live means "re-measure before
# applying": the run aborts if the plan is not exactly the 191 measured above
# (.mig041_expected_n), rather than silently writing a different set.
#
# ---- ROWS ---------------------------------------------------------------------
# kind transcription_error (a notational variant of the registered name, as
# 032/033's dropped-separator rows; `kind` is provenance only - the one branch
# on it in R/ is `kind == "self"`), auto_assign TRUE, confirmed_by "R. Shannon",
# n_seen 0, and DATE-BOUNDED to the target feature's own live window: alias
# date_start = feature.date_start, alias date_end = feature.date_end (NULL where
# the feature's is NULL). The equivalence holds only while the padded point is
# live (coordinator, 2026-10-19): B.G001 ends 2023-02-08, and 2023 Blaxland
# workbooks still write "B.G1" after that, when the current grid is
# B.G182-367 - those readings must NOT be mapped onto B.G001, so the alias
# itself stops at the feature's end rather than relying on the feature-side
# narrowing alone. Bounds are inclusive (.rc_alias_live). Feature date bounds
# are NOT touched.
#
# ---- WHAT THIS DOES NOT FIX (read before expecting the gas items to clear) ------
# The 2,943 corpus unknown_feature items come from 32 workbooks dated
# 2023-03 .. 2025-09. 2,918 of them are the OLD grids sampled AFTER the
# registry says those grids ended: B.G001-B.G178 have date_end 2023-02-08 and
# K.G026-K.G185 date_end 2023-03-08, yet live already holds legacy samples on
# them to 2024-01-22 (B) and 2023-12-19 (K), and the successor grids
# (B.G182-367, K.G186-364) have no sample before 2024-02-19 / 2024-03-04.
# What those post-end readings are (the old grid still being read, or template
# slots as 032/034's B.G201 / K.G365 / K.G366 - the other 25 items) is a
# question for Robin.
# Feature-side date narrowing is unconditional (R/reconcile.R:403,
# .rc_feature_candidates -> .rc_narrow_live_feature, the drop at :419; the
# structural path the same at .rc_structural_hit :681-684), so an expired feature is never
# a candidate however it is spelt. 041 makes the unpadded spellings resolve
# whenever the feature IS live (e.g. the 2021-22 workbooks, which today reach
# B.G001 only via the structural parse at confidence 0.9) and, by its alias
# bounds, never outside it. Pending aliases are not touched: a key that already
# has ANY row (pending included) is a skip -> precondition failure, never a rewrite.
#
# Writes: 191 feature_alias rows via db_append() (one change_log insert row
# each, actor "041-gas-grid-unpadded-aliases") and the marker, in one
# transaction; everything else checksummed before and after. No BACKUP CSV (no
# existing row changes); the inserted rows go to
# `041-gas-grid-unpadded-aliases-INSERTED-feature_alias.csv`, plus the verified
# whole-file backup in snapshot_dir.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/041-gas-grid-unpadded-aliases.R", envir = env)
#   env$mig041_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig041_marker_version <- 1041L
.mig041_requires <- 1040L
.mig041_name <- "041-gas-grid-unpadded-aliases"
.mig041_actor <- .mig041_name
.mig041_sites <- c("B", "K")
.mig041_expected_n <- c(B = 108L, K = 83L)
.mig041_confirmed_by <- "R. Shannon"
.mig041_comment <- function(target) {
  sprintf("041 (Robin, 2026-10-19: \"G1 is G001\"): unpadded gas grid number -> %s (same site, same integer); bounded to %s's own live window.", target, target)
}
.mig041_reason <- "041 (Robin, 2026-10-19: \"G1 is G001\"): register unpadded gas grid spellings as confirmed aliases of the zero-padded points"

.mig041_same_date <- function(x, y) {
  x <- as.Date(x); y <- as.Date(y)
  (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y)
}
.mig041_default <- function(x, default) if (is.null(x)) default else x
.mig041_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig041_fail <- function(msg) cli::cli_abort(paste0(.mig041_name, ": ", msg), class = "sampletidy_error")

.mig041_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analysis", "sample", "project", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig041_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# The gas grid features of B and K: name `<site>.G<digits>`, prefix = own site.
.mig041_grid <- function(con) {
  f <- DBI::dbGetQuery(con, "SELECT uuid, name, site, date_start, date_end FROM feature WHERE site IN ('B', 'K')")
  m <- regmatches(f$name, regexec("^([A-Z]+)\\.G([0-9]+)$", f$name))
  ok <- vapply(m, length, integer(1)) == 3L
  f <- f[ok, , drop = FALSE]
  m <- m[ok]
  f$prefix <- vapply(m, `[[`, character(1), 2L)
  f$digits <- vapply(m, `[[`, character(1), 3L)
  f <- f[f$prefix == f$site, , drop = FALSE]
  f$n <- as.integer(f$digits)
  f
}

# Plan + skip list. Pure function of the registry.
.mig041_plan <- function(con) {
  grid <- .mig041_grid(con)
  fa <- DBI::dbGetQuery(con, "SELECT fa.uuid, fa.name, fa.alias_key, fa.kind, f.name AS feature_name
    FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature")
  feat_names <- tolower(DBI::dbGetQuery(con, "SELECT name FROM feature")$name)
  rows <- list(); skips <- list()
  for (i in seq_len(nrow(grid))) {
    w <- nchar(grid$digits[[i]]); n <- grid$n[[i]]
    nw <- nchar(as.character(n))
    if (nw >= w) next
    for (k in nw:(w - 1L)) {
      nm <- sprintf("%s.G%s", grid$site[[i]], formatC(n, width = k, flag = "0"))
      key <- .rc_feature_key(nm)
      same <- grid[grid$site == grid$site[[i]] & grid$n == n, , drop = FALSE]
      why <- NA_character_
      if (nrow(same) != 1L) {
        why <- sprintf("%d registered gas features at (%s, %d): %s", nrow(same), grid$site[[i]], n,
                       paste(same$name, collapse = ", "))
      } else if (tolower(nm) %in% feat_names) {
        why <- "the spelling is itself a registered feature name"
      } else if (any(!is.na(fa$alias_key) & fa$alias_key == key)) {
        ex <- fa[!is.na(fa$alias_key) & fa$alias_key == key, , drop = FALSE]
        why <- sprintf("key %s already has alias row(s): %s", key,
                       paste(sprintf("%s -> %s (%s)", ex$name, ex$feature_name, ex$kind), collapse = "; "))
      }
      if (!is.na(why)) {
        skips[[length(skips) + 1L]] <- data.frame(alias = nm, target = grid$name[[i]], why = why, stringsAsFactors = FALSE)
      } else {
        rows[[length(rows) + 1L]] <- data.frame(name = nm, alias_key = key, uuid_feature = grid$uuid[[i]],
                                               target = grid$name[[i]], site = grid$site[[i]],
                                               date_start = grid$date_start[[i]], date_end = grid$date_end[[i]],
                                               stringsAsFactors = FALSE)
      }
    }
  }
  plan <- if (length(rows)) do.call(rbind, rows) else
    data.frame(name = character(0), alias_key = character(0), uuid_feature = character(0),
               target = character(0), site = character(0), date_start = as.Date(character(0)),
               date_end = as.Date(character(0)))
  skip <- if (length(skips)) do.call(rbind, skips) else
    data.frame(alias = character(0), target = character(0), why = character(0))
  plan <- plan[order(plan$site, plan$name), , drop = FALSE]
  if (anyDuplicated(plan$alias_key)) .mig041_fail("the plan holds a duplicate alias_key.")
  list(plan = plan, skip = skip)
}

.mig041_check_preconditions <- function(con) {
  if (.mig041_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig041_requires) == 0L)
    .mig041_fail(sprintf("marker %d (040) is required first.", .mig041_requires))
  p <- .mig041_plan(con)
  if (nrow(p$skip) > 0L) {
    .mig041_fail(sprintf("%d candidate spelling(s) would be skipped - re-measure before applying. Nothing written. %s",
                         nrow(p$skip), paste(sprintf("%s (%s): %s", p$skip$alias, p$skip$target, p$skip$why), collapse = " | ")))
  }
  got <- vapply(.mig041_sites, function(s) sum(p$plan$site == s), integer(1))
  if (!identical(got, .mig041_expected_n))
    .mig041_fail(sprintf("plan is B=%d K=%d, measured B=%d K=%d. Nothing written.",
                         got[["B"]], got[["K"]], .mig041_expected_n[["B"]], .mig041_expected_n[["K"]]))
  p
}

.mig041_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN
    (SELECT uuid_row FROM change_log WHERE actor = '%s' AND uuid_row IS NOT NULL) ORDER BY uuid", .mig041_actor))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig041_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig041_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig041_done_problem <- function(con) {
  if (.mig041_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig041_marker_version) != 1L)
    return("marker 1041 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row FROM change_log WHERE actor = ?", params = list(.mig041_actor))
  want_n <- sum(.mig041_expected_n)
  if (nrow(cl) != want_n || any(cl$tbl != "feature_alias") || any(cl$action != "insert") || anyDuplicated(cl$uuid_row))
    return(sprintf("041 change_log is %d row(s), expected %d feature_alias inserts", nrow(cl), want_n))
  fa <- DBI::dbGetQuery(con, sprintf("SELECT fa.*, f.name AS target, f.site, f.date_start AS f_date_start, f.date_end AS f_date_end
    FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.uuid IN (SELECT uuid_row FROM change_log WHERE actor = '%s')", .mig041_actor))
  if (nrow(fa) != want_n) return(sprintf("%d of the %d logged alias rows exist", nrow(fa), want_n))
  if (any(is.na(fa$target))) return("an 041 alias points at no feature")
  bad <- fa$kind != "transcription_error" | !fa$auto_assign | fa$confirmed_by != .mig041_confirmed_by |
    !.mig041_same_date(fa$date_start, fa$f_date_start) | !.mig041_same_date(fa$date_end, fa$f_date_end) | fa$n_seen != 0L | fa$alias_key != .rc_feature_key(fa$name) |
    fa$comments != .mig041_comment(fa$target)
  if (any(bad)) return(sprintf("%d 041 alias row(s) are not the planned confirmed transcription_error rows bounded to their feature's window", sum(bad)))
  # Same site, same integer, shorter spelling - for every row.
  an <- as.integer(sub("^[A-Z]+\\.G", "", fa$name)); tn <- as.integer(sub("^[A-Z]+\\.G", "", fa$target))
  if (any(an != tn) || any(sub("\\..*$", "", fa$name) != fa$site) || any(nchar(fa$name) >= nchar(fa$target)))
    return("an 041 alias is not a shorter spelling of its target's own site and integer")
  dup <- DBI::dbGetQuery(con, sprintf("SELECT alias_key, COUNT(*) n FROM feature_alias WHERE alias_key IN (%s) GROUP BY 1 HAVING COUNT(*) > 1",
                                      paste0("'", fa$alias_key, "'", collapse = ",")))
  if (nrow(dup)) return(sprintf("%d 041 key(s) are shared with another alias row", nrow(dup)))
  # Each spelling resolves to its target through the real candidate path on the
  # last day the target is live (its date_end, inclusive; else a current date),
  # and to NOTHING the day after a date_end (the post-window "B.G1" readings).
  reg <- .rc_load_registry(con)
  for (i in seq_len(nrow(fa))) {
    de <- fa$f_date_end[[i]]
    d <- if (is.na(de)) as.Date("2026-01-01") else as.Date(de)
    cand <- .rc_feature_candidates(fa$name[[i]], d, reg)
    if (nrow(cand) != 1L || cand$uuid_feature != fa$uuid_feature[[i]])
      return(sprintf("%s does not resolve to %s at %s", fa$name[[i]], fa$target[[i]], d))
    if (!is.na(de)) {
      after <- .rc_feature_candidates(fa$name[[i]], as.Date(de) + 1L, reg)
      if (nrow(after) != 0L) return(sprintf("%s still resolves the day after %s ends (%s)", fa$name[[i]], fa$target[[i]], de))
    }
  }
  NULL
}

.mig041_verify <- function(con) {
  p <- .mig041_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("041 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig041_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig041_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig041_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig041_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig041_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig041_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("041: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig041_apply <- function(con, plan, recorded_at) {
  sums_before <- .mig041_checksum(con)
  n <- nrow(plan)
  want <- .mig041_counts(con)
  want$feature_alias <- want$feature_alias + n
  want$change_log <- want$change_log + n
  want$schema_version <- want$schema_version + 1L
  now <- Sys.time()
  rows <- tibble::tibble(
    uuid = vapply(seq_len(n), function(i) uuid::UUIDgenerate(), character(1)),
    uuid_feature = plan$uuid_feature, name = plan$name, alias_key = plan$alias_key,
    kind = "transcription_error", n_seen = 0L, auto_assign = TRUE, first_seen = now, last_seen = now,
    confirmed_by = .mig041_confirmed_by, comments = .mig041_comment(plan$target),
    date_start = as.Date(plan$date_start), date_end = as.Date(plan$date_end))
  db_transaction(con, function(con) {
    db_append(con, "feature_alias", rows, actor = .mig041_actor, reason = .mig041_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig041_marker_version, recorded_at))
    .mig041_verify(con)
    got <- .mig041_counts(con)
    if (!identical(got, want))
      .mig041_fail(sprintf("counts are not before + %d alias, + %d change_log, + 1 marker: %s", n, n,
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig041_checksum(con))) .mig041_fail("something outside the planned rows moved.")
    NULL
  })
  rows
}

mig041_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig041_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig041_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("041 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  p <- tryCatch(.mig041_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: %d aliases (B %d, K %d), 0 skipped. First/last: %s -> %s ... %s -> %s.", nrow(p$plan),
       sum(p$plan$site == "B"), sum(p$plan$site == "K"), p$plan$name[[1]], p$plan$target[[1]],
       p$plan$name[[nrow(p$plan)]], p$plan$target[[nrow(p$plan)]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p$plan)))
  }

  backup_path <- mig041_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig041_default(.now, Sys.time())

  rows <- with_db_write(function(con) {
    p <- .mig041_check_preconditions(con)   # re-read under the write lock
    .mig041_apply(con, p$plan, recorded_at)
  }, db = db)
  .mig041_write_csv(rows, file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig041_name)))

  logf("%s migrated successfully (marker %d): %d aliases.", .mig041_name, .mig041_marker_version, nrow(rows))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
