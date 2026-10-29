# Operator-run migration: attach the bore logs to their monitoring-point features
# and record each bore's construction in feature.comments.
# Marker 1091. Requires 1089 (independent of 090: it touches no row 090 writes
# except feature.comments, which it appends to as it finds them). Authority: Robin,
# 2026-10-29 (asked for the bore logs to be attached to the features, with the
# construction notes in the features' comments).
#
# ---- WHAT THIS DOES -----------------------------------------------------------------
# A bore log is a document about a monitoring point, not a lab deliverable. The
# schema has had a slot for that since the WEM.input design: asset.uuid_feature. No
# asset used it before this migration. Each log becomes ONE asset:
#   * uuid_feature = the bore's feature; uuid_project = NULL (it belongs to no lab
#     job or report project);
#   * type 'Bore log'; name = the document's own title; organisation = the author
#     (company); date = the document date (Sydney midnight); person NULL;
#   * the file is copied to <archive_dir>/<asset uuid>/<filename>, as archive_file()
#     lays out ingested files (directory per asset, A70), and the copy's hash is
#     checked against the frozen INPUT hash;
#   * asset.hash is the file's xxHash128 (hash_file()). No ingest_file row: nothing
#     was received through the inbox.
#   * asset uuids are derived from the marker and the file hash, so a re-run or a
#     second rehearsal produces the same rows.
#
# ONE FEATURE PER ASSET, ANY NUMBER OF ASSETS PER FEATURE. asset.uuid_feature holds
# one feature, and dup_asset_hash (db_checks) allows one asset per hash among the
# project-less assets, so one file cannot be linked to several bores by repeating it.
# Multi-bore documents are therefore split, one bore's pages per asset, with
# `qpdf --deterministic-id --empty --pages <source> <pages> -- <out>.pdf`:
#   * the Douglas Partners Katoomba logs MW:1-MW:4 (one 4-page PDF, Nov 2014);
#   * Douglas Partners' 1996 Blaxland Bores 1-7 (Working Paper No. 3, June 1997:
#     each bore's piezometer completion sheet and test bore report);
#   * Douglas Partners' 1996 Katoomba Bores 8 and 12 (the Katoomba site
#     investigation report, June 1997). Bores 10 and 11 of that report are not
#     attached: whether they are today's K.MW10A and K.MW11B is not established.
# The source page numbers are in each asset's comment. The Blaxland files sent to
# the EPA in May 2026 (Response Point 5) are kept as Council holds them, alongside
# the 1996 extracts where both exist; B.MW09.pdf also repeats the MW10 and MW8 logs
# on pages 1-2, and B.MW02.pdf is a geotechnical hole, not B.MW02's log, as their
# asset comments and the feature notes say.
#
# THE TRIM FILER. bmcc-monitoring's filer reads `asset WHERE uuid_project IS NOT
# NULL` (and leftover ingest_file rows that carry a message_id); sampleTidy's
# completed_work() reads the same subset. A project-less, feature-linked asset is
# therefore never offered for filing. Where the document is already in TRIM, its
# record is still registered (register_filing(), system 'trim', as 089 did), so the
# database says where it lives and a future filer change cannot file it twice. The
# record numbers are NOT in this public repo: they are read from the untracked
# 091-bore-logs-TRIM.csv, which may list only some of the assets.
#
# FEATURE NOTES. INPUT-notes.csv holds one dated paragraph per feature, each
# starting "091 (2026-10-29) bore record:". It is appended to feature.comments after
# a newline (existing text kept), or becomes the comment when there was none. A
# feature whose comments already contain the paragraph is left alone, so the
# append is idempotent and does not care what 089, 090 or anyone else has appended
# before it. Notes are also written for the points with no log attached (K.MW05,
# K.MW10A, K.MW11B) and for the cut-off walls, which are not bores (B.CW01, B.CW02).
#
# ---- PHASES ----------------------------------------------------------------------
# One transaction: the asset rows (each copy registered with .st_on_rollback() so a
# rollback removes it), the feature comments (db_update), the TRIM filings
# (register_filing), mig_db_checks_gate() and marker 1091. Before it: the feature rows that change go to
# BACKUP-feature.csv and the whole file is backed up and verified. After it: every
# asset, copy, note and filing is re-checked, and the sample and analysis tables
# must be byte-identical (content digest) to before.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/091-bore-logs.R", envir = env)
#   env$mig091_run(db = st_config("live_db"), snapshot_dir = ..., archive_dir = st_config("archive_dir"),
#                  files_dir = "dev/migrations/091-bore-logs-FILES",
#                  trim_csv = "dev/migrations/091-bore-logs-TRIM.csv", dry_run = TRUE)

.mig091_marker_version <- 1091L
.mig091_requires <- 1089L
.mig091_name <- "091-bore-logs"
.mig091_actor <- .mig091_name
.mig091_trim_system <- "trim"
.mig091_asset_type <- "Bore log"
.mig091_note_prefix <- "091 (2026-10-29) bore record:"

.mig091_asset_cols <- c("hash", "filename", "feature", "name", "organisation", "doc_date", "pages", "comments")
.mig091_note_cols <- c("feature", "note")
.mig091_trim_cols <- c("hash", "trim_record", "trim_uri", "container", "title", "record_date", "note")

.mig091_fail <- function(msg) cli::cli_abort(paste0(.mig091_name, ": ", msg), class = "sampletidy_error")
.mig091_scalar <- function(con, sql, ...) {
  as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
}
.mig091_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig091_csv_path <- function(dir, what) file.path(dir, sprintf("%s-%s.csv", .mig091_name, what))
.mig091_read <- function(p, cols) {
  if (!file.exists(p)) .mig091_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), cols)) .mig091_fail(sprintf("%s: columns are not as planned.", basename(p)))
  x
}
.mig091_iso_date <- function(x) !is.na(x) & grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x) & !is.na(as.Date(x, optional = TRUE))

# ---- inputs ----------------------------------------------------------------------

mig091_read_inputs <- function(input_dir = "dev/migrations") {
  a <- .mig091_read(.mig091_csv_path(input_dir, "INPUT-assets"), .mig091_asset_cols)
  n <- .mig091_read(.mig091_csv_path(input_dir, "INPUT-notes"), .mig091_note_cols)
  if (anyNA(a[, setdiff(.mig091_asset_cols, "doc_date")])) .mig091_fail("INPUT-assets misses a value.")
  if (!all(grepl("^[0-9a-f]{32}$", a$hash))) .mig091_fail("INPUT-assets holds a hash that is not xxHash128.")
  if (anyDuplicated(a$hash) || anyDuplicated(a$filename)) .mig091_fail("INPUT-assets repeats a hash or filename.")
  if (!all(grepl("^[A-Za-z0-9._ -]+\\.pdf$", a$filename))) .mig091_fail("INPUT-assets holds an unexpected filename.")
  if (!all(is.na(a$doc_date) | .mig091_iso_date(a$doc_date))) .mig091_fail("INPUT-assets holds a malformed doc_date.")
  if (!all(grepl("^[1-9][0-9]*$", a$pages))) .mig091_fail("INPUT-assets holds a malformed page count.")
  if (!all(startsWith(a$comments, "091: "))) .mig091_fail("an INPUT-assets comment does not start '091: '.")
  if (anyNA(n) || anyDuplicated(n$feature)) .mig091_fail("INPUT-notes misses or repeats a value.")
  if (!all(startsWith(n$note, paste0(.mig091_note_prefix, " ")))) .mig091_fail("an INPUT-notes note lacks the dated prefix.")
  if (any(grepl("[\r\n]", n$note))) .mig091_fail("an INPUT-notes note holds a line break.")
  if (!all(a$feature %in% n$feature)) .mig091_fail("an asset's feature has no INPUT-notes paragraph.")
  feats <- unique(c(a$feature, n$feature))
  if (!all(grepl("^[BK]\\.(MW|CW)[0-9A-Z]+$", feats))) .mig091_fail("INPUT names a feature outside the bores and cut-off walls.")
  list(assets = a, notes = n)
}

# The TRIM CSV may list any subset of the assets (one row at most each).
mig091_read_trim <- function(trim_csv, assets) {
  t <- .mig091_read(trim_csv, .mig091_trim_cols)
  if (anyNA(t)) .mig091_fail("the TRIM CSV misses a value.")
  if (anyDuplicated(t$hash) || !all(t$hash %in% assets$hash)) .mig091_fail("the TRIM CSV names a file twice or a file not in INPUT-assets.")
  if (!all(.mig091_iso_date(t$record_date))) .mig091_fail("the TRIM CSV holds a malformed record_date.")
  t
}

# ---- plan ------------------------------------------------------------------------

.mig091_uuid <- function(...) {
  d <- digest::digest(paste(c(.mig091_marker_version, ...), collapse = "\u001f"), algo = "md5", serialize = FALSE)
  paste(substr(d, 1, 8), substr(d, 9, 12), paste0("4", substr(d, 14, 16)),
        paste0("8", substr(d, 18, 20)), substr(d, 21, 32), sep = "-")
}

.mig091_doc_ts <- function(d) {
  out <- as.POSIXct(rep(NA_real_, length(d)), origin = "1970-01-01", tz = "UTC")
  ok <- !is.na(d)
  out[ok] <- as.POSIXct(paste(d[ok], "00:00:00"), tz = "Australia/Sydney")
  out
}

.mig091_append <- function(old, note) {
  if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "\n", note)
}

mig091_plan <- function(con, inp) {
  feats <- unique(c(inp$assets$feature, inp$notes$feature))
  f <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, comments FROM feature WHERE name IN %s", .mig091_inlist(feats)))
  if (anyDuplicated(f$name) || !setequal(f$name, feats)) {
    .mig091_fail(sprintf("features missing or repeated: %s",
                         paste(c(setdiff(feats, f$name), f$name[duplicated(f$name)]), collapse = ", ")))
  }
  a <- inp$assets
  a$uuid <- vapply(a$hash, function(h) .mig091_uuid("asset", h), "", USE.NAMES = FALSE)
  a$uuid_feature <- f$uuid[match(a$feature, f$name)]
  n <- inp$notes
  n$uuid <- f$uuid[match(n$feature, f$name)]
  n$old_comments <- f$comments[match(n$feature, f$name)]
  n$present <- !is.na(n$old_comments) & vapply(seq_len(nrow(n)), function(i)
    grepl(n$note[[i]], n$old_comments[[i]], fixed = TRUE), logical(1))
  n$new_comments <- ifelse(n$present, n$old_comments,
                           mapply(.mig091_append, n$old_comments, n$note, USE.NAMES = FALSE))
  list(assets = a, notes = n)
}

.mig091_asset_rows <- function(a) {
  tibble::tibble(
    uuid = a$uuid, name = a$name, date = .mig091_doc_ts(a$doc_date), file_format = "pdf",
    type = .mig091_asset_type, purpose = NA_character_, organisation = a$organisation, person = NA_character_,
    uuid_project = NA_character_, uuid_feature = a$uuid_feature, filename = a$filename, hash = a$hash,
    comments = a$comments)
}

# What stops the run: a file missing or not as frozen; a hash already held by
# another asset or an ingest_file row; a planned asset uuid already present with
# other content; an archive directory already in the way.
mig091_problems <- function(con, plan, files_dir, archive_dir) {
  pr <- character(0)
  a <- plan$assets
  for (i in seq_len(nrow(a))) {
    p <- file.path(files_dir, a$filename[[i]])
    if (!file.exists(p)) pr <- c(pr, sprintf("missing file %s", p))
    else if (!identical(hash_file(p), a$hash[[i]])) pr <- c(pr, sprintf("hash differs: %s", p))
  }
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, hash, uuid_feature, uuid_project, filename FROM asset WHERE hash IN %s OR uuid IN %s",
                                       .mig091_inlist(a$hash), .mig091_inlist(a$uuid)))
  if (nrow(have)) pr <- c(pr, sprintf("%d asset row(s) already hold a planned hash or uuid", nrow(have)))
  n <- .mig091_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s", .mig091_inlist(a$hash)))
  if (n > 0) pr <- c(pr, sprintf("%d ingest_file row(s) hold a planned hash", n))
  if (!is.null(archive_dir)) {
    busy <- a$uuid[dir.exists(file.path(archive_dir, a$uuid))]
    if (length(busy)) pr <- c(pr, sprintf("archive directory already exists for %s", paste(substr(busy, 1, 8), collapse = ",")))
  }
  pr
}

# ---- apply -----------------------------------------------------------------------

mig091_apply <- function(con, plan, trim, files_dir, archive_dir, recorded_at, logf) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    a <- plan$assets
    for (i in seq_len(nrow(a))) {
      dir <- file.path(archive_dir, a$uuid[[i]])
      if (!dir.create(dir, recursive = FALSE, showWarnings = FALSE)) .mig091_fail(sprintf("could not create %s", dir))
      .st_on_rollback(con, local({ d <- dir; function() unlink(d, recursive = TRUE) }))
      dest <- file.path(dir, a$filename[[i]])
      if (!isTRUE(file.copy(file.path(files_dir, a$filename[[i]]), dest, copy.date = TRUE)))
        .mig091_fail(sprintf("could not copy %s", a$filename[[i]]))
      if (!identical(hash_file(dest), a$hash[[i]])) .mig091_fail(sprintf("archived copy of %s differs", a$filename[[i]]))
      db_append(con, "asset", .mig091_asset_rows(a[i, , drop = FALSE]), actor = .mig091_actor,
                reason = "091: bore log attached to its feature", source_hash = a$hash[[i]])
    }
    n <- plan$notes[!plan$notes$present, , drop = FALSE]
    for (i in seq_len(nrow(n))) {
      db_update(con, "feature", uuid = n$uuid[[i]], changes = list(comments = n$new_comments[[i]]),
                actor = .mig091_actor, reason = "091: bore construction notes appended")
    }
    res <- vapply(seq_len(nrow(trim)), function(i) {
      register_filing(con, uuid_asset = a$uuid[match(trim$hash[[i]], a$hash)], system = .mig091_trim_system,
                      external_id = trim$trim_record[[i]], external_uri = trim$trim_uri[[i]],
                      container = trim$container[[i]],
                      filed_at = as.POSIXct(paste(trim$record_date[[i]], "00:00:00"), tz = "Australia/Sydney"),
                      title = trim$title[[i]], comments = trim$note[[i]])
    }, character(1))
    mig_db_checks_gate(con, baseline)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig091_marker_version, recorded_at))
    logf("Applied: %d asset(s) archived and linked; %d feature comment(s) appended (%d already present); %d filing(s) %s; marker %d.",
         nrow(a), nrow(n), sum(plan$notes$present), nrow(trim),
         if (length(res)) paste(names(table(res)), table(res), sep = "=", collapse = ", ") else "-",
         .mig091_marker_version)
    res
  })
}

# ---- verification ------------------------------------------------------------------

mig091_verify <- function(con, inp, trim, archive_dir) {
  pr <- character(0)
  a <- inp$assets
  a$uuid <- vapply(a$hash, function(h) .mig091_uuid("asset", h), "", USE.NAMES = FALSE)
  got <- DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.hash, a.filename, a.type, a.uuid_project, f.name AS feature
    FROM asset a LEFT JOIN feature f ON f.uuid = a.uuid_feature WHERE a.uuid IN %s", .mig091_inlist(a$uuid)))
  got <- got[match(a$uuid, got$uuid), , drop = FALSE]
  bad <- is.na(got$uuid) | got$hash != a$hash | got$filename != a$filename | is.na(got$feature) |
    got$feature != a$feature | !is.na(got$uuid_project) | got$type != .mig091_asset_type
  if (any(bad)) pr <- c(pr, sprintf("asset rows not as planned: %s", paste(a$filename[bad], collapse = ", ")))
  if (!is.null(archive_dir)) {
    p <- file.path(archive_dir, a$uuid, a$filename)
    miss <- !file.exists(p)
    if (any(miss)) pr <- c(pr, sprintf("archived copy missing: %s", paste(a$filename[miss], collapse = ", ")))
    okp <- p[!miss]
    diff <- okp[vapply(okp, hash_file, "") != a$hash[!miss]]
    if (length(diff)) pr <- c(pr, sprintf("archived copy differs: %s", paste(basename(diff), collapse = ", ")))
  }
  f <- DBI::dbGetQuery(con, sprintf("SELECT name, comments FROM feature WHERE name IN %s", .mig091_inlist(inp$notes$feature)))
  k <- vapply(inp$notes$feature, function(nm) {
    cm <- f$comments[match(nm, f$name)]
    if (is.na(cm)) 0L else lengths(regmatches(cm, gregexpr(inp$notes$note[inp$notes$feature == nm], cm, fixed = TRUE)))
  }, 0L)
  if (any(k != 1L)) pr <- c(pr, sprintf("note not present exactly once: %s", paste(names(k)[k != 1L], collapse = ", ")))
  if (nrow(trim)) {
    fl <- DBI::dbGetQuery(con, sprintf("SELECT uuid_asset, external_id FROM asset_filing WHERE system = '%s' AND uuid_asset IN %s",
                                       .mig091_trim_system, .mig091_inlist(a$uuid)))
    want <- a$uuid[match(trim$hash, a$hash)]
    if (!identical(fl$external_id[match(want, fl$uuid_asset)], trim$trim_record)) pr <- c(pr, "filing rows are not as planned")
  }
  pr
}

.mig091_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "ingest_file", "change_log", "schema_version")
  if ("asset_filing" %in% DBI::dbListTables(con)) tabs <- c(tabs, "asset_filing")
  stats::setNames(vapply(tabs, function(t) .mig091_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 0L), tabs)
}

# Content digest of the result tables: 091 must not change a sample or analysis.
mig091_data_digest <- function(con) {
  vapply(c("sample", "analysis"), function(t) {
    digest::digest(DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" ORDER BY uuid', t)), algo = "sha1")
  }, "")
}

# ---- backup ------------------------------------------------------------------------

mig091_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig091_name,
                                          format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")))
  n0 <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    n <- .mig091_counts(con)
    if (!isTRUE(file.copy(db, dest, overwrite = FALSE))) .mig091_fail(sprintf("could not write backup %s", dest))
    n
  }, db = db)
  v <- DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE)
  on.exit(DBI::dbDisconnect(v, shutdown = TRUE), add = TRUE)
  if (!identical(n0, .mig091_counts(v))) .mig091_fail("backup verification failed: counts differ.")
  dest
}

.mig091_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df)) .mig091_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

# ---- run -------------------------------------------------------------------------------

mig091_run <- function(db, snapshot_dir, archive_dir, files_dir, trim_csv, dry_run = FALSE,
                       csv_dir = "dev/migrations", input_dir = "dev/migrations", requires = .mig091_requires,
                       .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", basename(db), sprintf(fmt, ...)))
  checkmate::assert_directory_exists(archive_dir)
  checkmate::assert_directory_exists(snapshot_dir)
  checkmate::assert_directory_exists(csv_dir)
  inp <- mig091_read_inputs(input_dir)
  trim <- mig091_read_trim(trim_csv, inp$assets)
  logf("Inputs: %d bore log(s) for %d feature(s); %d feature note(s); %d TRIM record(s) to adopt (%d asset(s) with none).",
       nrow(inp$assets), length(unique(inp$assets$feature)), nrow(inp$notes), nrow(trim),
       nrow(inp$assets) - nrow(trim))

  con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) .mig091_fail(sprintf("marker %s required first.", paste(requires, collapse = ", ")))
    done <- .mig091_marker_version %in% have
    list(done = done, plan = if (done) NULL else mig091_plan(con, inp),
         problems = if (done) character(0) else NULL)
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))

  if (st$done) {
    con <- st_connect(db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    pr <- mig091_verify(con, inp, trim, archive_dir)
    if (length(pr)) .mig091_fail(paste0("re-verify: ", paste(pr, collapse = "; ")))
    logf("091 already applied; re-verified; nothing to do.")
    return(invisible(list(status = "already_migrated")))
  }

  con <- st_connect(db, read_only = TRUE)
  pr <- tryCatch(mig091_problems(con, st$plan, files_dir, archive_dir), finally = DBI::dbDisconnect(con, shutdown = TRUE))
  if (length(pr)) .mig091_fail(paste(pr, collapse = "; "))
  logf("Plan: assets %s; notes for %s (%d already present).",
       paste(sprintf("%s->%s", st$plan$assets$filename, st$plan$assets$feature), collapse = ", "),
       paste(st$plan$notes$feature, collapse = ", "), sum(st$plan$notes$present))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: inputs, files and preconditions checked. Nothing written.")
    return(invisible(list(status = "dry_run", plan = st$plan)))
  }

  con <- st_connect(db, read_only = TRUE)
  before <- tryCatch({
    .mig091_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE uuid IN %s ORDER BY name",
                                                   .mig091_inlist(st$plan$notes$uuid))),
                      .mig091_csv_path(csv_dir, "BACKUP-feature"))
    list(digest = mig091_data_digest(con), counts = .mig091_counts(con))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  backup_path <- mig091_backup(db, snapshot_dir, .now)
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: cp %s %s (and remove the new <archive_dir>/<uuid>/ dirs listed in the BACKUP-assets CSV)",
       shQuote(backup_path), shQuote(db))
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  .mig091_write_csv(data.frame(uuid = st$plan$assets$uuid, filename = st$plan$assets$filename,
                               feature = st$plan$assets$feature, stringsAsFactors = FALSE),
                    .mig091_csv_path(csv_dir, "BACKUP-assets"))
  res <- with_db_write(function(con) mig091_apply(con, st$plan, trim, files_dir, archive_dir, recorded_at, logf), db = db)

  con <- st_connect(db, read_only = TRUE)
  after <- tryCatch(list(problems = mig091_verify(con, inp, trim, archive_dir), digest = mig091_data_digest(con),
                         counts = .mig091_counts(con)),
                    finally = DBI::dbDisconnect(con, shutdown = TRUE))
  if (!identical(before$digest, after$digest)) after$problems <- c(after$problems, "sample or analysis content changed")
  delta <- after$counts[names(before$counts)] - before$counts
  logf("Row deltas: %s", paste(names(delta)[delta != 0], delta[delta != 0], sep = " +", collapse = ", "))
  if (length(after$problems)) .mig091_fail(paste0("verify: ", paste(after$problems, collapse = "; "), ". Restore from ", backup_path))
  logf("%s migrated successfully (marker %d).", .mig091_name, .mig091_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, filings = res, delta = delta))
}
