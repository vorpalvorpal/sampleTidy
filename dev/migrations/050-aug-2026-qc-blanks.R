# Operator-run migration: the Aug 2026 pre-scheme blanks of ES2626883 (sampled
# 2026-08-19) become QC samples (PLAN-19 R19-6, R19-10 (1)). Marker 1050.
# Requires 1049.
#
# Authority: Robin, 2026-10-19 (R19-6: Sealed is the trip blank B.JT00;
# Bailer/Scoop and Lab sample are type-only QC features with no parent point;
# R19-10 (1): the names B.JF00 field blank and B.JA00 lab/source blank).
#
# ---- MEASURED (copy of live at marker 1047, 2026-10-19) ---------------------------
# The plan expected 90 rows withheld behind three unknown_feature items and
# asked whether release_review() can release them. It cannot, and need not:
#   * release_review() commits only the rows held in an item's payload$rows
#     (written by reconcile STAGE-0 for adapter-withheld rows); the three
#     unknown_feature items carry source_ref/feature_raw diagnostics only, no
#     rows, so there is nothing for it to release;
#   * the rows are NOT withheld. ES2626883 committed one sample per label on
#     its `pending` alias (uuid_feature NULL): Lab sample 27 analyses,
#     Bailer/Scoop 28, Sealed 27 = 82 of the 90 source rows;
#   * the other 8 rows (SAR x3, EC "<1" x2, Anions-total "<0.01" x3) are held by
#     units_implausible items that hit the real points of the same work order
#     too (e.g. SAR on every column). They are a units question, not a QC one,
#     and this migration leaves them alone.
# So no re-commit from the archived ENMRG is needed (unlike 040): pointing the
# three pending aliases at their QC features resolves the 82 committed rows in
# place, exactly as confirm_feature_aliases() would, and the three
# unknown_feature items are resolved.
#
# ---- WHAT ----------------------------------------------------------------------
#   * features B.JF00 (field_blank) and B.JA00 (source_blank): type-only QC
#     codes tied to no point (R-19.3). Shaped as 049's: virtual, permanent,
#     matrix/lon/lat copied from B.JT00, self alias, qc_feature row with
#     uuid_parent NULL, date_start 2026-08-19, open end;
#   * the pending aliases Sealed -> B.JT00, Bailer/Scoop -> B.JF00, Lab sample ->
#     B.JA00: uuid_feature set, kind 'descriptive', auto_assign TRUE,
#     confirmed_by 'R. Shannon', date_start = date_end = 2026-08-19, so a later
#     "Sealed" anywhere else never auto-resolves;
#   * the three open unknown_feature items on ES2626883 (one per alias,
#     review_queue.uuid_alias) -> resolved.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1049 present; 1050 absent;
#   * B.JT00 is one feature, a transport_blank qc_feature with no parent;
#     no feature or alias named B.JF00 / B.JA00;
#   * each label is exactly one alias, kind 'pending', uuid_feature NULL, with
#     exactly one sample, in ES2626883, on Sydney 2026-08-19, holding analyses;
#   * each has exactly one open unknown_feature item on ES2626883 keyed to it;
#   * no sample already on B.JT00 dated 2026-08-19 (no collision);
#   * no other auto alias arm of the three alias keys is live on 2026-08-19.
#
# Writes, in one transaction (actor "050-aug-2026-qc-blanks", change_log rows by
# db_append/db_update): 2 feature, 2 feature_alias, 2 qc_feature inserts; 3
# feature_alias updates; 3 review_queue updates; the marker. Every other table
# is checksummed before and after. Backups: verified whole-file snapshot, plus
# `050-...-BACKUP-{feature_alias,review_queue}.csv` (touched rows, before). No
# confidential content: the three codes are tied to no point.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/050-aug-2026-qc-blanks.R", envir = env)
#   env$mig050_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig050_marker_version <- 1050L
.mig050_requires <- 1049L
.mig050_name <- "050-aug-2026-qc-blanks"
.mig050_actor <- .mig050_name
.mig050_confirmed_by <- "R. Shannon"
.mig050_wo <- "ES2626883"
.mig050_day <- as.Date("2026-08-19")
.mig050_new <- data.frame(code = c("B.JF00", "B.JA00"), qc_type = c("field_blank", "source_blank"),
                          comments = c("Type-only field blank, tied to no point (PLAN-19 R19-6/R-19.3).",
                                       "Type-only lab/source blank, tied to no point (PLAN-19 R19-6/R-19.3)."),
                          stringsAsFactors = FALSE)
.mig050_map <- data.frame(label = c("Sealed", "Bailer/Scoop", "Lab sample"),
                          target = c("B.JT00", "B.JF00", "B.JA00"), stringsAsFactors = FALSE)
.mig050_reason <- "050 (PLAN-19 R19-6, Robin 2026-10-19): Aug 2026 pre-scheme blank of ES2626883"

.mig050_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig050_fail <- function(msg) cli::cli_abort(paste0(.mig050_name, ": ", msg), class = "sampletidy_error")
.mig050_syd <- function(x) format(x, "%Y-%m-%d", tz = "Australia/Sydney")

.mig050_alias <- function(con, label) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE name = ?", params = list(label))
}

.mig050_alias_samples <- function(con, uuid_alias) {
  DBI::dbGetQuery(con, "
    SELECT s.uuid, s.datetime, s.date, p.name AS project,
           (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid) AS n_analysis
      FROM \"sample\" s LEFT JOIN project p ON p.uuid = s.uuid_project
     WHERE s.uuid_feature_alias = ?", params = list(uuid_alias))
}

.mig050_items <- function(con, uuid_alias) {
  DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'unknown_feature' AND status = 'open'
                          AND work_order = ? AND uuid_alias = ?", params = list(.mig050_wo, uuid_alias))
}

.mig050_plan <- function(con) {
  probs <- character(0)
  jt <- DBI::dbGetQuery(con, "SELECT f.*, q.qc_type, q.uuid_parent FROM feature f
                               LEFT JOIN qc_feature q ON q.uuid_feature = f.uuid WHERE f.name = 'B.JT00'")
  if (nrow(jt) != 1L || !identical(jt$qc_type[[1]], "transport_blank") || !is.na(jt$uuid_parent[[1]]))
    probs <- c(probs, "B.JT00 is not one transport_blank qc_feature tied to no point (apply 049)")
  n_new <- .mig050_scalar(con, sprintf("SELECT COUNT(*) FROM feature WHERE name IN ('%s')",
                                       paste(.mig050_new$code, collapse = "','")))
  n_new_a <- .mig050_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE alias_key IN ('%s')",
                                         paste(.rc_feature_key(.mig050_new$code), collapse = "','")))
  if (n_new || n_new_a) probs <- c(probs, sprintf("B.JF00/B.JA00 already registered (%d features, %d aliases)", n_new, n_new_a))
  plan <- list()
  for (i in seq_len(nrow(.mig050_map))) {
    lb <- .mig050_map$label[[i]]
    a <- .mig050_alias(con, lb)
    if (nrow(a) != 1L || !identical(a$kind[[1]], "pending") || !is.na(a$uuid_feature[[1]])) {
      probs <- c(probs, sprintf("'%s' is %d alias row(s), not one dangling pending alias", lb, nrow(a)))
      next
    }
    s <- .mig050_alias_samples(con, a$uuid[[1]])
    ts <- if (nrow(s)) ifelse(is.na(s$datetime), .mig050_syd(s$date), .mig050_syd(s$datetime)) else character(0)
    if (nrow(s) != 1L || !identical(s$project[[1]], .mig050_wo) || !identical(ts[[1]], format(.mig050_day)) ||
        s$n_analysis[[1]] < 1L)
      probs <- c(probs, sprintf("'%s' has %d sample(s), not one %s sample on %s with analyses", lb, nrow(s),
                                .mig050_wo, format(.mig050_day)))
    it <- .mig050_items(con, a$uuid[[1]])
    if (nrow(it) != 1L) probs <- c(probs, sprintf("'%s' has %d open unknown_feature item(s) on %s, expected 1",
                                                  lb, nrow(it), .mig050_wo))
    others <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE alias_key = ? AND uuid <> ?
                                      AND uuid_feature IS NOT NULL AND auto_assign
                                      AND (date_start IS NULL OR date_start <= ?)
                                      AND (date_end IS NULL OR date_end >= ?)",
                              params = list(a$alias_key[[1]], a$uuid[[1]], .mig050_day, .mig050_day))
    if (nrow(others)) probs <- c(probs, sprintf("another live auto arm of '%s' exists on %s", lb, format(.mig050_day)))
    plan[[lb]] <- list(alias = a, sample = s, item = it)
  }
  if (nrow(jt) == 1L) {
    clash <- .mig050_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                                   WHERE fa.uuid_feature = ?
                                     AND CAST(%s AS VARCHAR) = ?", .ct_sydney_day_sql("COALESCE(s.datetime, s.date)")),
                            jt$uuid[[1]], format(.mig050_day))
    if (clash) probs <- c(probs, sprintf("B.JT00 already has %d sample(s) on %s", clash, format(.mig050_day)))
  }
  list(problems = probs, jt = jt, labels = plan)
}

.mig050_check_preconditions <- function(con) {
  if (.mig050_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig050_requires) == 0L)
    .mig050_fail(sprintf("marker %d (049) is required first.", .mig050_requires))
  p <- .mig050_plan(con)
  if (length(p$problems)) .mig050_fail(sprintf("%s. Nothing written.", paste(p$problems, collapse = " | ")))
  p
}

.mig050_counts <- function(con) {
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  stats::setNames(lapply(tabs, function(t) .mig050_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig050_checksum <- function(con, alias_uuids, item_uuids) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  inl <- function(x) paste0("('", paste(x, collapse = "','"), "')")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("feature", "feature_alias", "qc_feature", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  new <- inl(.mig050_new$code)
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE name NOT IN %s ORDER BY uuid", new))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s AND name NOT IN %s ORDER BY uuid",
                                      inl(alias_uuids), new))
  out$feature_alias_fixed <- q(sprintf("SELECT uuid, name, alias_key, n_seen, first_seen, last_seen FROM feature_alias
                                         WHERE uuid IN %s ORDER BY uuid", inl(alias_uuids)))
  out$qc_feature_rest <- q(sprintf("SELECT * FROM qc_feature WHERE uuid_feature NOT IN
                                     (SELECT uuid FROM feature WHERE name IN %s) ORDER BY ALL", new))
  out$review_queue_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", inl(item_uuids)))
  out$review_queue_fixed <- q(sprintf("SELECT * EXCLUDE (status, resolution, resolved_by, resolved_at) FROM review_queue
                                        WHERE uuid IN %s ORDER BY uuid", inl(item_uuids)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig050_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig050_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig050_done_problem <- function(con) {
  if (.mig050_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig050_marker_version) != 1L)
    return("marker 1050 missing")
  for (i in seq_len(nrow(.mig050_new))) {
    r <- DBI::dbGetQuery(con, "SELECT f.uuid, f.virtual, q.qc_type, q.uuid_parent, q.date_start FROM feature f
                                JOIN qc_feature q ON q.uuid_feature = f.uuid WHERE f.name = ?",
                         params = list(.mig050_new$code[[i]]))
    if (nrow(r) != 1L || !identical(r$qc_type[[1]], .mig050_new$qc_type[[i]]) || !is.na(r$uuid_parent[[1]]) ||
        !isTRUE(r$virtual[[1]]) || !identical(as.Date(r$date_start[[1]]), .mig050_day))
      return(sprintf("%s is not one virtual %s qc_feature tied to no point from %s", .mig050_new$code[[i]],
                     .mig050_new$qc_type[[i]], format(.mig050_day)))
    n_self <- .mig050_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE uuid_feature = ? AND kind = 'self' AND name = ?",
                             r$uuid[[1]], .mig050_new$code[[i]])
    if (n_self != 1L) return(sprintf("%s has %d self aliases", .mig050_new$code[[i]], n_self))
  }
  reg <- .rc_load_registry(con)
  for (i in seq_len(nrow(.mig050_map))) {
    lb <- .mig050_map$label[[i]]
    tg <- .mig050_map$target[[i]]
    a <- DBI::dbGetQuery(con, "SELECT fa.*, f.name AS feature FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
                                WHERE fa.name = ?", params = list(lb))
    if (nrow(a) != 1L || !identical(a$feature[[1]], tg) || !identical(a$kind[[1]], "descriptive") ||
        !isTRUE(a$auto_assign[[1]]) || !identical(a$confirmed_by[[1]], .mig050_confirmed_by) ||
        !identical(as.Date(a$date_start[[1]]), .mig050_day) || !identical(as.Date(a$date_end[[1]]), .mig050_day))
      return(sprintf("alias '%s' is not a confirmed descriptive arm of %s bounded to %s", lb, tg, format(.mig050_day)))
    s <- .mig050_alias_samples(con, a$uuid[[1]])
    if (nrow(s) != 1L || !identical(s$project[[1]], .mig050_wo)) return(sprintf("alias '%s' samples moved", lb))
    # The resolver: the label reaches its QC feature on the day, and nothing on the next.
    on_day <- unique(.rc_feature_candidates(lb, .mig050_day, reg)$uuid_feature)
    after <- unique(.rc_feature_candidates(lb, .mig050_day + 1, reg)$uuid_feature)
    if (length(on_day) != 1L || !identical(reg$feature$name[match(on_day, reg$feature$uuid)], tg) || length(after) != 0L)
      return(sprintf("'%s' does not resolve to %s on %s only", lb, tg, format(.mig050_day)))
    n_open <- .mig050_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE kind = 'unknown_feature' AND status = 'open'
                                    AND uuid_alias = ?", a$uuid[[1]])
    if (n_open != 0L) return(sprintf("'%s' still has an open unknown_feature item", lb))
  }
  n_log <- .mig050_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig050_actor)
  if (n_log < 6L) return(sprintf("050 change_log has %d rows", n_log))
  NULL
}

.mig050_verify <- function(con) {
  p <- .mig050_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("050 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig050_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig050_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig050_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig050_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig050_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("050: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig050_apply <- function(con, p, recorded_at) {
  alias_uuids <- vapply(p$labels, function(x) x$alias$uuid[[1]], "")
  item_uuids <- vapply(p$labels, function(x) x$item$uuid[[1]], "")
  sums_before <- .mig050_checksum(con, alias_uuids, item_uuids)
  want <- .mig050_counts(con)
  want$feature <- want$feature + 2L
  want$feature_alias <- want$feature_alias + 2L
  want$qc_feature <- want$qc_feature + 2L
  want$schema_version <- want$schema_version + 1L
  jt <- p$jt
  fcols <- DBI::dbListFields(con, "feature")
  acols <- DBI::dbListFields(con, "feature_alias")
  db_transaction(con, function(con) {
    n_log0 <- .mig050_scalar(con, "SELECT COUNT(*) FROM change_log")
    target <- c(B.JT00 = jt$uuid[[1]])
    for (i in seq_len(nrow(.mig050_new))) {
      u <- uuid::UUIDgenerate()
      code <- .mig050_new$code[[i]]
      feat <- tibble::tibble(uuid = u, name = code, site = "B", matrix = jt$matrix[[1]],
                             lon = jt$lon[[1]], lat = jt$lat[[1]], geom_wkt = jt$geom_wkt[[1]],
                             virtual = TRUE, permanent = TRUE, reference = FALSE,
                             comments = "Field QC code (PLAN-19 R-19.2): virtual, no masks; pairing in qc_feature.")
      db_append(con, "feature", feat[, intersect(names(feat), fcols), drop = FALSE],
                actor = .mig050_actor, reason = .mig050_reason)
      al <- tibble::tibble(uuid = uuid::UUIDgenerate(), uuid_feature = u, name = code,
                           alias_key = .rc_feature_key(code), kind = "self", n_seen = 0L, auto_assign = TRUE,
                           first_seen = recorded_at, last_seen = recorded_at, confirmed_by = NA_character_,
                           comments = "Self alias of a field QC code (050).")
      db_append(con, "feature_alias", al[, intersect(names(al), acols), drop = FALSE],
                actor = .mig050_actor, reason = .mig050_reason)
      db_append(con, "qc_feature",
                tibble::tibble(uuid_feature = u, qc_type = .mig050_new$qc_type[[i]], uuid_parent = NA_character_,
                               date_start = .mig050_day, date_end = as.Date(NA), comments = .mig050_new$comments[[i]]),
                actor = .mig050_actor, reason = .mig050_reason)
      target[[code]] <- u
    }
    for (i in seq_len(nrow(.mig050_map))) {
      lb <- .mig050_map$label[[i]]
      db_update(con, "feature_alias", uuid = p$labels[[lb]]$alias$uuid[[1]],
                changes = list(uuid_feature = target[[.mig050_map$target[[i]]]], kind = "descriptive",
                               auto_assign = TRUE, confirmed_by = .mig050_confirmed_by,
                               date_start = .mig050_day, date_end = .mig050_day),
                actor = .mig050_actor,
                reason = sprintf("%s: '%s' -> %s, bounded to %s", .mig050_reason, lb, .mig050_map$target[[i]],
                                 format(.mig050_day)))
      db_update(con, "review_queue", uuid = p$labels[[lb]]$item$uuid[[1]],
                changes = list(status = "resolved",
                               resolution = sprintf("confirmed: '%s' is %s (050, PLAN-19 R19-6)", lb, .mig050_map$target[[i]]),
                               resolved_by = .mig050_confirmed_by, resolved_at = recorded_at),
                actor = .mig050_actor, reason = .mig050_reason)
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig050_marker_version, recorded_at))
    .mig050_verify(con)
    got <- .mig050_counts(con)
    want$change_log <- n_log0 + (.mig050_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig050_actor))
    if (!identical(got, want))
      .mig050_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want[names(got)]), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig050_checksum(con, alias_uuids, item_uuids)))
      .mig050_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig050_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig050_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig050_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("050 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  p <- tryCatch(.mig050_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Will create B.JF00 (field_blank) and B.JA00 (source_blank), type-only, from %s.", format(.mig050_day))
  for (i in seq_len(nrow(.mig050_map))) {
    lb <- .mig050_map$label[[i]]
    x <- p$labels[[lb]]
    logf("Alias '%s' (%s) -> %s, descriptive, bounded to %s: 1 sample, %d analyses; closes item %s.",
         lb, x$alias$uuid[[1]], .mig050_map$target[[i]], format(.mig050_day), x$sample$n_analysis[[1]],
         x$item$uuid[[1]])
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    au <- vapply(p$labels, function(x) x$alias$uuid[[1]], "")
    iu <- vapply(p$labels, function(x) x$item$uuid[[1]], "")
    inl <- function(x) paste0("('", paste(x, collapse = "','"), "')")
    .mig050_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY uuid", inl(au))),
                      file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig050_name)))
    .mig050_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", inl(iu))),
                      file.path(csv_dir, sprintf("%s-BACKUP-review_queue.csv", .mig050_name)))
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig050_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    p2 <- .mig050_check_preconditions(con)   # re-read under the write lock
    .mig050_apply(con, p2, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): 2 QC features, 3 aliases resolved, 3 review items closed.",
       .mig050_name, .mig050_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
