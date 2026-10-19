# Operator-run migration: register the field QC codes as features (PLAN-19
# R-19.2, R-19.11). Marker 1049. Requires 1048.
#
# Authority: Robin, 2026-10-19 (PLAN-19 R19-1: a QC code is a feature of its
# own; R19-3: the code -> parent mapping is confidential).
#
# ---- CONFIDENTIALITY (R-19.10/R-19.11) ------------------------------------------
# The code -> point mapping is NEVER in this repo. It is read from the CSV named
# by the environment variable SAMPLETIDY_QC_CODES (no default), which Robin keeps
# beside the Council-only vault note (51.16 .../attachments/qc-codes.csv). The
# migration refuses a file inside this repository. Its row record goes to
# `snapshot_dir`, never to dev/migrations/. This header, the log lines and
# MIGRATIONS.md state COUNTS ONLY.
#
#   CSV columns: code, qc_type, parent, date_start, comments
#     code        the QC code, e.g. "<site>.JDnn"; its site is the text before "."
#     qc_type     duplicate | field_blank | rinsate_blank | transport_blank |
#                 filter_blank | source_blank
#     parent      the parent point's feature name, or empty for a code tied to
#                 no point
#     date_start  YYYY-MM-DD, when the pairing starts (open-ended)
#     comments    free text, may be empty
#
# ---- WHAT ----------------------------------------------------------------------
# 92 codes (30 points x 3 + 2 tied to no point). For each code:
#   * one `feature` row: name = code, site = the code's prefix, matrix, lon/lat
#     = the parent's (a parentless code takes the site's parents' modal matrix
#     and mean lon/lat), virtual = TRUE, permanent = TRUE, no date bounds;
#   * its self alias (kind 'self', auto_assign TRUE), as every feature has;
#   * one `qc_feature` row: qc_type, uuid_parent (NULL when no parent),
#     date_start, date_end NULL, comments.
# No feature_mask row of any variant, so no EPA, gas or report view maps a QC
# feature (R-19.2).
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1048 present; marker 1049 absent;
#   * SAMPLETIDY_QC_CODES set, the file exists and is not inside this repo;
#   * exactly 92 rows, every column present, codes unique and shaped
#     <SITE>.J<A-Z><2 digits>, qc_type in the vocabulary, date_start a date;
#   * every parent exists as exactly one feature of the code's site and is live
#     on the code's date_start (date_end NULL or >= it);
#   * no code is already a feature name or an alias key;
#   * qc_feature is empty.
#
# Writes, in one transaction, via db_append (change_log insert rows, actor
# "049-qc-features"): 92 feature, 92 feature_alias, 92 qc_feature rows and the
# marker. Every other table is checksummed before and after. Backups: verified
# whole-file snapshot, plus `049-qc-features-INSERTED-qc_feature.csv` in
# `snapshot_dir` (the inserted rows - confidential, so never in the repo).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   Sys.setenv(SAMPLETIDY_QC_CODES = "<vault>/5 Compliance/51 Blaxland/51.16 .../attachments/qc-codes.csv")
#   env <- new.env()
#   sys.source("dev/migrations/049-qc-features.R", envir = env)
#   env$mig049_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig049_marker_version <- 1049L
.mig049_requires <- 1048L
.mig049_name <- "049-qc-features"
.mig049_actor <- .mig049_name
.mig049_n_codes <- 92L
.mig049_reason <- "049 (PLAN-19 R19-1, Robin 2026-10-19): field QC code registered as a feature of its own"
.mig049_types <- c("duplicate", "field_blank", "rinsate_blank", "transport_blank", "filter_blank",
                   "source_blank")

.mig049_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig049_fail <- function(msg) cli::cli_abort(paste0(.mig049_name, ": ", msg), class = "sampletidy_error")

# The repository (source tree) this migration belongs to: the loaded package's
# root, plus any ancestor of the codes file that is a sampleTidy source tree.
.mig049_inside_repo <- function(path) {
  p <- normalizePath(path, mustWork = TRUE)
  roots <- character(0)
  pkg <- tryCatch(system.file(package = "sampleTidy"), error = function(e) "")
  if (nzchar(pkg)) roots <- c(roots, normalizePath(pkg))
  d <- dirname(p)
  repeat {
    desc <- file.path(d, "DESCRIPTION")
    if (file.exists(desc) && any(grepl("^Package:\\s*sampleTidy\\s*$", readLines(desc, warn = FALSE))))
      roots <- c(roots, d)
    up <- dirname(d)
    if (identical(up, d)) break
    d <- up
  }
  roots <- unique(roots)
  any(vapply(roots, function(r) startsWith(p, paste0(sub("/+$", "", r), "/")), logical(1)))
}

.mig049_read_codes <- function() {
  path <- Sys.getenv("SAMPLETIDY_QC_CODES", unset = NA_character_)
  if (is.na(path) || !nzchar(path)) .mig049_fail("SAMPLETIDY_QC_CODES is not set (no default, R-19.11). Nothing written.")
  if (!file.exists(path)) .mig049_fail("the SAMPLETIDY_QC_CODES file does not exist. Nothing written.")
  if (.mig049_inside_repo(path))
    .mig049_fail("the SAMPLETIDY_QC_CODES file is inside the repository; it must stay outside git (R-19.10). Nothing written.")
  d <- tryCatch(utils::read.csv(path, colClasses = "character", na.strings = character(0),
                                strip.white = TRUE, check.names = FALSE, encoding = "UTF-8"),
                error = function(e) .mig049_fail(paste("cannot read the codes CSV:", conditionMessage(e))))
  need <- c("code", "qc_type", "parent", "date_start", "comments")
  miss <- setdiff(need, names(d))
  if (length(miss)) .mig049_fail(sprintf("the codes CSV lacks column(s) %s. Nothing written.", paste(miss, collapse = ", ")))
  d <- d[, need, drop = FALSE]
  for (cl in need) d[[cl]] <- trimws(d[[cl]])
  list(path = normalizePath(path), codes = d)
}

.mig049_plan <- function(con, d) {
  probs <- character(0)
  if (nrow(d) != .mig049_n_codes) probs <- c(probs, sprintf("%d codes, expected %d", nrow(d), .mig049_n_codes))
  dup <- unique(d$code[duplicated(d$code)])
  if (length(dup)) probs <- c(probs, sprintf("%d duplicated code(s)", length(dup)))
  bad <- !grepl("^[A-Z]+\\.J[A-Z][0-9]{2}$", d$code)
  if (any(bad)) probs <- c(probs, sprintf("%d code(s) not shaped <SITE>.J<letter><2 digits>", sum(bad)))
  bt <- !d$qc_type %in% .mig049_types
  if (any(bt)) probs <- c(probs, sprintf("%d row(s) with an unknown qc_type", sum(bt)))
  ds <- suppressWarnings(as.Date(d$date_start, "%Y-%m-%d"))
  if (anyNA(ds) || any(!grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", d$date_start)))
    probs <- c(probs, sprintf("%d row(s) without a YYYY-MM-DD date_start", sum(is.na(ds))))
  site <- sub("\\..*$", "", d$code)
  feat <- DBI::dbGetQuery(con, "SELECT uuid, name, site, matrix, lon, lat, date_start, date_end FROM feature")
  has_parent <- nzchar(d$parent)
  pu <- rep(NA_character_, nrow(d))
  n_unknown <- 0L; n_dead <- 0L; n_site <- 0L
  for (i in which(has_parent)) {
    hit <- which(feat$name == d$parent[[i]])
    if (length(hit) != 1L) { n_unknown <- n_unknown + 1L; next }
    if (!identical(feat$site[[hit]], site[[i]])) n_site <- n_site + 1L
    de <- as.Date(feat$date_end[[hit]])
    if (!is.na(de) && !is.na(ds[[i]]) && de < ds[[i]]) n_dead <- n_dead + 1L
    pu[[i]] <- feat$uuid[[hit]]
  }
  if (n_unknown) probs <- c(probs, sprintf("%d parent(s) not exactly one registered feature", n_unknown))
  if (n_dead) probs <- c(probs, sprintf("%d parent(s) not live on the code's date_start", n_dead))
  if (n_site) probs <- c(probs, sprintf("%d parent(s) at a different site from the code", n_site))
  taken_f <- sum(d$code %in% feat$name)
  keys <- .rc_feature_key(d$code)
  taken_a <- .mig049_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE alias_key IN (%s)",
                                         paste(DBI::dbQuoteString(con, keys), collapse = ",")))
  if (taken_f || taken_a) probs <- c(probs, sprintf("%d code(s) already a feature, %d already an alias", taken_f, taken_a))
  if (.mig049_scalar(con, "SELECT COUNT(*) FROM qc_feature") != 0L) probs <- c(probs, "qc_feature is not empty")
  if (length(probs)) return(list(problems = probs))

  # Matrix and location: the parent's; a parentless code takes its site's
  # parents' modal matrix and mean location.
  pi <- match(pu, feat$uuid)
  matrix <- feat$matrix[pi]
  lon <- feat$lon[pi]
  lat <- feat$lat[pi]
  # A site with no parent in the file falls back to all the file's parents'
  # matrix and the site's own features' mean location.
  modal <- function(x) {
    tb <- sort(table(x), decreasing = TRUE)
    if (length(tb)) names(tb)[[1]] else NA_character_
  }
  for (i in which(!has_parent)) {
    same <- has_parent & site == site[[i]]
    if (any(same)) {
      matrix[[i]] <- modal(feat$matrix[pi[same]])
      lon[[i]] <- mean(feat$lon[pi[same]])
      lat[[i]] <- mean(feat$lat[pi[same]])
    } else {
      at_site <- feat$site %in% site[[i]] & is.finite(feat$lon) & is.finite(feat$lat)
      matrix[[i]] <- modal(feat$matrix[pi[has_parent]])
      lon[[i]] <- if (any(at_site)) mean(feat$lon[at_site]) else NA_real_
      lat[[i]] <- if (any(at_site)) mean(feat$lat[at_site]) else NA_real_
    }
  }
  if (any(!is.finite(lon)) || any(!is.finite(lat))) return(list(problems = "a parentless code's site has no parent to place it"))
  list(problems = character(0), codes = d, site = site, uuid_parent = pu, date_start = ds,
       matrix = matrix, lon = lon, lat = lat)
}

.mig049_check_preconditions <- function(con, d) {
  if (.mig049_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig049_requires) == 0L)
    .mig049_fail(sprintf("marker %d (048) is required first.", .mig049_requires))
  if (!DBI::dbExistsTable(con, "qc_feature")) .mig049_fail("qc_feature does not exist (apply 048). Nothing written.")
  p <- .mig049_plan(con, d)
  if (length(p$problems)) .mig049_fail(sprintf("%s. Nothing written.", paste(p$problems, collapse = " | ")))
  p
}

.mig049_counts <- function(con) {
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  stats::setNames(lapply(tabs, function(t) .mig049_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig049_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("feature", "feature_alias", "qc_feature", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  qc <- "(SELECT uuid_feature FROM qc_feature)"
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", qc))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid_feature IS NULL OR uuid_feature NOT IN %s ORDER BY uuid", qc))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig049_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig049_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig049_done_problem <- function(con) {
  if (.mig049_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig049_marker_version) != 1L)
    return("marker 1049 missing")
  q <- DBI::dbGetQuery(con, "
    SELECT q.uuid_feature, q.qc_type, q.uuid_parent, q.date_start, q.date_end, f.name, f.site, f.virtual,
           p.name AS parent, p.site AS parent_site
      FROM qc_feature q
      LEFT JOIN feature f ON f.uuid = q.uuid_feature
      LEFT JOIN feature p ON p.uuid = q.uuid_parent")
  if (nrow(q) != .mig049_n_codes) return(sprintf("qc_feature has %d rows, expected %d", nrow(q), .mig049_n_codes))
  if (anyNA(q$name)) return("a qc_feature row names no feature")
  if (any(!is.na(q$uuid_parent) & is.na(q$parent))) return("a qc_feature parent is not a feature")
  if (any(!is.na(q$parent_site) & q$parent_site != q$site)) return("a QC code and its parent are at different sites")
  if (!all(q$virtual %in% TRUE)) return("a QC feature is not virtual")
  if (any(q$uuid_feature %in% q$uuid_parent)) return("a QC feature is itself a parent (R-19.1)")
  if (!all(q$qc_type %in% .mig049_types)) return("an unknown qc_type")
  if ("permanent" %in% DBI::dbListFields(con, "feature") &&
      .mig049_scalar(con, "SELECT COUNT(*) FROM feature WHERE uuid IN (SELECT uuid_feature FROM qc_feature)
                            AND permanent IS NOT TRUE") != 0L) return("a QC feature is not permanent")
  n_self <- .mig049_scalar(con, "SELECT COUNT(*) FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
                                  WHERE fa.uuid_feature IN (SELECT uuid_feature FROM qc_feature)
                                    AND fa.kind = 'self' AND fa.auto_assign AND fa.name = f.name")
  n_alias <- .mig049_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE uuid_feature IN (SELECT uuid_feature FROM qc_feature)")
  if (n_self != .mig049_n_codes || n_alias != .mig049_n_codes)
    return(sprintf("QC features have %d aliases (%d self), expected %d self only", n_alias, n_self, .mig049_n_codes))
  if (.mig049_scalar(con, "SELECT COUNT(*) FROM feature_mask WHERE uuid_feature IN (SELECT uuid_feature FROM qc_feature)") != 0L)
    return("a QC feature has a feature_mask row")
  n_log <- .mig049_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig049_actor)
  if (n_log != 3L * .mig049_n_codes) return(sprintf("049 change_log has %d rows, expected %d", n_log, 3L * .mig049_n_codes))
  NULL
}

.mig049_verify <- function(con) {
  p <- .mig049_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("049 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig049_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig049_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig049_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig049_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig049_rows <- function(con, p, at) {
  d <- p$codes
  n <- nrow(d)
  u <- vapply(seq_len(n), function(i) uuid::UUIDgenerate(), "")
  fcols <- DBI::dbListFields(con, "feature")
  feat <- tibble::tibble(uuid = u, name = d$code, site = p$site, matrix = p$matrix,
                         lon = p$lon, lat = p$lat,
                         geom_wkt = sprintf("POINT (%s %s)", format(p$lon, digits = 15), format(p$lat, digits = 15)),
                         virtual = TRUE, permanent = TRUE, reference = FALSE,
                         comments = "Field QC code (PLAN-19 R-19.2): virtual, no masks; pairing in qc_feature.")
  feat <- feat[, intersect(names(feat), fcols), drop = FALSE]
  acols <- DBI::dbListFields(con, "feature_alias")
  alias <- tibble::tibble(uuid = vapply(seq_len(n), function(i) uuid::UUIDgenerate(), ""),
                          uuid_feature = u, name = d$code, alias_key = .rc_feature_key(d$code),
                          kind = "self", n_seen = 0L, auto_assign = TRUE, first_seen = at, last_seen = at,
                          confirmed_by = NA_character_,
                          comments = "Self alias of a field QC code (049).")
  alias <- alias[, intersect(names(alias), acols), drop = FALSE]
  qc <- tibble::tibble(uuid_feature = u, qc_type = d$qc_type, uuid_parent = p$uuid_parent,
                       date_start = p$date_start, date_end = as.Date(NA),
                       comments = ifelse(nzchar(d$comments), d$comments, NA_character_))
  list(feature = feat, feature_alias = alias, qc_feature = qc)
}

.mig049_apply <- function(con, rows, recorded_at) {
  sums_before <- .mig049_checksum(con)
  want <- .mig049_counts(con)
  n <- nrow(rows$qc_feature)
  want$feature <- want$feature + n
  want$feature_alias <- want$feature_alias + n
  want$qc_feature <- want$qc_feature + n
  want$change_log <- want$change_log + 3L * n
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    db_append(con, "feature", rows$feature, actor = .mig049_actor, reason = .mig049_reason)
    db_append(con, "feature_alias", rows$feature_alias, actor = .mig049_actor, reason = .mig049_reason)
    db_append(con, "qc_feature", rows$qc_feature, actor = .mig049_actor, reason = .mig049_reason)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig049_marker_version, recorded_at))
    .mig049_verify(con)
    got <- .mig049_counts(con)
    if (!identical(got, want))
      .mig049_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want[names(got)]), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig049_checksum(con))) .mig049_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig049_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig049_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig049_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("049 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  src <- .mig049_read_codes()
  pre_con <- st_connect(db, read_only = TRUE)
  p <- tryCatch(.mig049_check_preconditions(pre_con, src$codes),
                finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  tt <- table(factor(p$codes$qc_type, levels = .mig049_types))
  logf("Will register %d QC codes (%s); %d tied to a point, %d to none.",
       nrow(p$codes), paste(names(tt), tt, sep = " ", collapse = ", "),
       sum(!is.na(p$uuid_parent)), sum(is.na(p$uuid_parent)))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig049_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  rows <- NULL
  with_db_write(function(con) {
    p2 <- .mig049_check_preconditions(con, src$codes)   # re-read under the write lock
    rows <<- .mig049_rows(con, p2, recorded_at)
    .mig049_apply(con, rows, recorded_at)
  }, db = db)

  # The inserted rows, named, for the record - confidential, so beside the
  # whole-file snapshot and never in dev/migrations/ (R-19.11).
  rec <- rows$qc_feature
  rec$code <- rows$feature$name
  rec$parent <- p$codes$parent
  rec$date_start <- format(rec$date_start)
  rec$date_end <- NA_character_
  rec_path <- file.path(snapshot_dir, sprintf("%s-INSERTED-qc_feature.csv", .mig049_name))
  utils::write.csv(rec, rec_path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  logf("Inserted-row record written to %s", rec_path)

  logf("%s migrated successfully (marker %d): %d features, %d self aliases, %d qc_feature rows.",
       .mig049_name, .mig049_marker_version, nrow(rows$feature), nrow(rows$feature_alias), nrow(rows$qc_feature))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
