# Operator-run migration: release the 8 Blaxland A77 dust blocks withheld by
# the 2026-10-17 16:25 email import (exposure months Mar-Jun 2026), file them
# under the ALS work order each workbook cites (A80), and set datetime = date
# on them (the pipeline's NULL-datetime dust bug, as 035 part B4). Marker 1037.
# Requires 1036. Template: 035-dust-release.R.
#
# ---- A. RELEASE (release_review(), A88) ----------------------------------------
# Eight `date_conflict`/`a77` items, one per gauge-block. In every one the
# Observations sheet agrees with the report-number convention (report -NN =
# exposure 1st of month NN-1, collection 1st of month NN); A77 fired only
# because the Results `Month` cell gives the COLLECTION month (serial 46113 /
# 46143, text "June" / "Jul") where the adapter expects the exposure month -
# the Month-cell noise documented in scratchpad/2026-10-17-dust/PLAN.md.
# Observations year is 2026 in all four (no stale template year), DAYS EXPOSED
# equals the exposure month's length, and the chain is unbroken
# (Mar->Apr->May->Jun->Jul). Workbooks: scratchpad/2026-10-18-email/staged/.
#   2400-7399-04     2026-03-01 / 2026-04-01  high  31 d; visit 2026-04-01, issued 2026-04-30; ES2610538
#   2400-7538-05-02  2026-04-01 / 2026-05-01  high  30 d; visit 2026-05-04, issued 2026-05-18; ES2614070
#   2400-7538-06     2026-05-01 / 2026-06-01  high  31 d; visit 2026-06-02, issued 2026-08-03; ES2617789
#   2400-7538-07     2026-06-01 / 2026-07-01  high  30 d; visit 2026-07-20, issued 2026-07-30; ES2623357
# None duplicates dust already in the DB: no B.D07/B.D08 dust sample exists on
# any of the four Sydney collection days (asserted), so each release creates
# one new sample per gauge-block (8 samples, 32 analyses: 3 dust + Appearance).
# Each release_review() call is its own transaction and idempotent (a resolved
# item releases nothing), so a run interrupted in A resumes cleanly.
#
# ---- B. RE-FILE + DATETIME (one transaction) ------------------------------------
# B1  release_review() files the event under the item's work_order - the ACIRL
#     REPORT number - so the 8 new samples land in the report projects. A80
#     files ACIRL samples under the CITED ALS work order ("ALS Sydney Report
#     No." on every Sampling Sites sheet), which is where each file's other
#     rows went at import and which is the report project's child:
#     7399-04 -> ES2610538, 7538-05-02 -> ES2614070, 7538-06 -> ES2617789,
#     7538-07 -> ES2623357. Each new sample's uuid_project is re-pointed there.
# B2  datetime = date, datetime_start = date_start on the 8 released samples
#     (021's invariant). Asserted: before the run NO dust sample has NULL
#     datetime, and after part A exactly the 8 released ones do.
#
# `uuid_project` and `datetime` are in 009's ux_sample_identity, and duckdb
# 1.4.1 runs an UPDATE of an indexed column as delete+insert, which the
# analysis -> sample FK refuses. So B uses 021's/035's sequence: drop the index
# (own commit), update in one transaction, and re-create it in a finally
# whenever it is missing. A precondition proves the post-update key set is
# unique.
#
# Writes: A via release_review(resolved_by = "037-dust-release-mar-jul-2026");
# B via db_update() (same actor); marker 1037. Row backups (before):
# 037-dust-release-mar-jul-2026-BACKUP-review_queue.csv; rows created by A:
# 037-dust-release-mar-jul-2026-INSERTED-{sample,analysis}.csv (written after
# B, so they show the final project and datetime). Plus the verified
# whole-file backup in snapshot_dir.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/037-dust-release-mar-jul-2026.R", envir = env)
#   env$mig037_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig037_marker_version <- 1037L
.mig037_requires <- 1036L
.mig037_name <- "037-dust-release-mar-jul-2026"
.mig037_actor <- .mig037_name
.mig037_index_name <- "ux_sample_identity"
.mig037_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

# total = INSOLUBLE SOLIDS (stored as dust-total).
.mig037_items <- utils::read.csv(text = "uuid,report,gauge,date_start,date,confidence,report_proj,proj_uuid,proj_name,total
fc86f70b-ab05-4a8a-82ee-3300e0866f2b,2400-7399-04,B.D07,2026-03-01,2026-04-01,high,ebecc431-f79f-400a-9f91-9e6491bd29af,f76e3780-cdcd-4235-a6fb-fcddd3c241ad,ES2610538,0.4
94ce3099-468d-4431-8cb9-235d86e1b424,2400-7399-04,B.D08,2026-03-01,2026-04-01,high,ebecc431-f79f-400a-9f91-9e6491bd29af,f76e3780-cdcd-4235-a6fb-fcddd3c241ad,ES2610538,0.3
e3e85a04-7dcc-4ffe-9e13-3fe482793303,2400-7538-05-02,B.D07,2026-04-01,2026-05-01,high,7ecce219-edb2-47ce-b5e4-f58bde18fe33,f0194514-cc54-46ef-a075-a8221cc7f074,ES2614070,1.8
95152c17-6198-4133-9964-8caaa8be881a,2400-7538-05-02,B.D08,2026-04-01,2026-05-01,high,7ecce219-edb2-47ce-b5e4-f58bde18fe33,f0194514-cc54-46ef-a075-a8221cc7f074,ES2614070,0.2
19fae771-0364-4571-a235-d45388707246,2400-7538-06,B.D07,2026-05-01,2026-06-01,high,9efea518-790b-4780-91c1-ebe1beec75fb,c843d807-57b0-46ab-9024-719d016a80c4,ES2617789,9.4
1045fcaf-e0a7-49c1-bc38-8c3b1f969ab0,2400-7538-06,B.D08,2026-05-01,2026-06-01,high,9efea518-790b-4780-91c1-ebe1beec75fb,c843d807-57b0-46ab-9024-719d016a80c4,ES2617789,1.6
eda1b732-37b9-4e95-97d1-e4b69ade5d8a,2400-7538-07,B.D07,2026-06-01,2026-07-01,high,a75997e7-1ddd-469c-b3e8-665e97deb274,2a398160-1ca5-48ab-b8a8-c515f3749ccf,ES2623357,3
e6512aa9-95ba-4024-bef7-14cef7d09ca7,2400-7538-07,B.D08,2026-06-01,2026-07-01,high,a75997e7-1ddd-469c-b3e8-665e97deb274,2a398160-1ca5-48ab-b8a8-c515f3749ccf,ES2623357,1.9",
  stringsAsFactors = FALSE, colClasses = "character")

.mig037_dust_uuid_sql <- "SELECT DISTINCT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
  JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%'"
.mig037_null_dt <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE datetime IS NULL AND uuid IN (%s) ORDER BY uuid",
                               .mig037_dust_uuid_sql))$uuid
}
# 021's invariant over every dust sample: datetime = date, datetime_start = date_start.
.mig037_invariant_bad <- function(con) {
  .mig037_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN (%s) AND
    (datetime IS DISTINCT FROM date OR datetime_start IS DISTINCT FROM date_start)", .mig037_dust_uuid_sql))
}

.mig037_default <- function(x, default) if (is.null(x)) default else x
.mig037_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig037_fail <- function(msg) cli::cli_abort(paste0(.mig037_name, ": ", msg), class = "sampletidy_error")
.mig037_in <- function(x) paste0("('", paste(x, collapse = "','"), "')")
.mig037_syd <- function(col) sprintf("(%s AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE", col)
.mig037_dmy <- function(iso) format(as.Date(iso), "%d/%m/%Y")

.mig037_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig037_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every dust sample (a sample carrying a dust-* analysis) at B.D07/B.D08.
.mig037_dust <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.uuid_project, p.name AS proj,
           %s AS syd_date, %s AS syd_start, s.datetime,
           (SELECT a.value FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
              JOIN analyte an ON an.uuid = lm.uuid_analyte
             WHERE a.uuid_sample = s.uuid AND an.name = 'dust-total' LIMIT 1) AS total,
           (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid) AS n_analyses
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN project p ON p.uuid = s.uuid_project
    WHERE f.name IN ('B.D07', 'B.D08')
      AND s.uuid IN (SELECT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
                       JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%%')
    ORDER BY f.name, s.date", .mig037_syd("COALESCE(s.datetime, s.date)"), .mig037_syd("s.date_start")))
}

.mig037_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?", params = list(.mig037_index_name))$sql
}

# Items: all 8 must exist as date_conflict/a77 with the planned report, gauge,
# payload dates and withheld INSOLUBLE SOLIDS; each open, or resolved by THIS
# migration (a resumed run).
.mig037_item_state <- function(con) {
  it <- DBI::dbGetQuery(con, sprintf(
    "SELECT uuid, kind, subkind, work_order, status, resolved_by, payload FROM review_queue WHERE uuid IN %s",
    .mig037_in(.mig037_items$uuid)))
  if (nrow(it) != nrow(.mig037_items)) .mig037_fail(sprintf("%d of the 8 review items exist.", nrow(it)))
  it <- it[match(.mig037_items$uuid, it$uuid), ]
  for (i in seq_len(nrow(it))) {
    pl <- .mig037_items[i, ]
    p <- jsonlite::fromJSON(it$payload[[i]], simplifyVector = TRUE)
    if (!identical(it$kind[[i]], "date_conflict") || !identical(it$subkind[[i]], "a77") ||
        !identical(it$work_order[[i]], pl$report) || !identical(p$gauge, pl$gauge)) {
      .mig037_fail(sprintf("item %s is not the planned a77 block %s %s.", it$uuid[[i]], pl$report, pl$gauge))
    }
    ins <- p$withheld$value[p$withheld$analyte == "INSOLUBLE SOLIDS"]
    if (!identical(p$exposure_date, pl$date_start) || !identical(p$collection_date, pl$date) ||
        any(p$rows$sample_date_start_raw != .mig037_dmy(pl$date_start)) ||
        any(p$rows$sample_datetime_raw != .mig037_dmy(pl$date)) ||
        length(ins) != 1L || !isTRUE(all.equal(as.numeric(ins), as.numeric(pl$total))) ||
        NROW(p$rows) != 4L) {
      .mig037_fail(sprintf("item %s (%s %s): payload dates/values are not as planned.", it$uuid[[i]], pl$report, pl$gauge))
    }
    if (!(it$status[[i]] == "open" || (it$status[[i]] == "resolved" && identical(it$resolved_by[[i]], .mig037_actor)))) {
      .mig037_fail(sprintf("item %s is %s by %s, not open.", it$uuid[[i]], it$status[[i]], it$resolved_by[[i]]))
    }
  }
  it$status
}

.mig037_check_preconditions <- function(con) {
  if (.mig037_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig037_requires) == 0L) {
    .mig037_fail(sprintf("marker %d (036) is required first.", .mig037_requires))
  }
  def <- .mig037_index_def(con)
  if (length(def) != 1L || !identical(def, .mig037_index_sql)) {
    .mig037_fail(sprintf("index %s is %s, not 009's definition. If a previous run was killed mid-way, re-create it with: %s",
                         .mig037_index_name, if (length(def)) def else "MISSING", .mig037_index_sql))
  }
  status <- .mig037_item_state(con)
  # Target ALS work orders exist, are named as planned, and are children of the report.
  pr <- unique(.mig037_items[, c("report", "report_proj", "proj_uuid", "proj_name")])
  got <- DBI::dbGetQuery(con, sprintf("SELECT c.uuid, c.name, c.uuid_parent, p.name AS parent_name FROM project c
    LEFT JOIN project p ON p.uuid = c.uuid_parent WHERE c.uuid IN %s", .mig037_in(pr$proj_uuid)))
  got <- got[match(pr$proj_uuid, got$uuid), ]
  if (anyNA(got$uuid) || !identical(got$name, pr$proj_name) || !identical(got$uuid_parent, pr$report_proj) ||
      !identical(got$parent_name, pr$report)) {
    .mig037_fail("a target ALS work-order project is missing, misnamed, or not the report's child.")
  }
  d <- .mig037_dust(con)
  # Blocks still open: nothing may sit at that gauge + Sydney collection day.
  for (i in which(status == "open")) {
    x <- d[d$gauge == .mig037_items$gauge[[i]] & as.character(d$syd_date) == .mig037_items$date[[i]], ]
    if (nrow(x) != 0L) .mig037_fail(sprintf("%s %s: a dust sample already exists on %s.", .mig037_items$report[[i]], .mig037_items$gauge[[i]], .mig037_items$date[[i]]))
  }
  # B2 precondition: on a fresh run no dust sample has NULL datetime.
  nd <- .mig037_null_dt(con)
  if (all(status == "open") && length(nd) > 0L)
    .mig037_fail(sprintf("unexpected NULL-datetime dust samples before the run: %s.", paste(nd, collapse = ", ")))
  invisible(list(status = status))
}

# The 8 samples part A created: one per item.
.mig037_released_samples <- function(con) {
  d <- .mig037_dust(con)
  vapply(seq_len(nrow(.mig037_items)), function(i) {
    it <- .mig037_items[i, ]
    x <- d[d$gauge == it$gauge & as.character(d$syd_date) == it$date, ]
    if (nrow(x) != 1L) .mig037_fail(sprintf("%s %s: %d dust samples on %s, expected 1.", it$report, it$gauge, nrow(x), it$date))
    if (as.character(x$syd_start) != it$date_start) .mig037_fail(sprintf("%s %s: exposure %s, expected %s.", it$report, it$gauge, x$syd_start, it$date_start))
    if (!isTRUE(all.equal(x$total, as.numeric(it$total)))) .mig037_fail(sprintf("%s %s: dust-total %s, expected %s.", it$report, it$gauge, x$total, it$total))
    if (x$n_analyses != 4L) .mig037_fail(sprintf("%s %s: %d analyses, expected 4 (3 dust + Appearance).", it$report, it$gauge, x$n_analyses))
    x$uuid
  }, character(1))
}

.mig037_done_problem <- function(con, check_index = TRUE) {
  if (.mig037_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig037_marker_version) != 1L) return("marker 1037 missing")
  it <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolved_by FROM review_queue WHERE uuid IN %s", .mig037_in(.mig037_items$uuid)))
  if (nrow(it) != 8L || any(it$status != "resolved") || any(it$resolved_by != .mig037_actor)) return("not all 8 items are resolved by 037")
  s <- tryCatch(.mig037_released_samples(con), error = function(e) conditionMessage(e))
  if (length(s) == 1L) return(s)
  if (length(unique(s)) != 8L) return("expected 8 distinct released samples")
  pr <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_project FROM \"sample\" WHERE uuid IN %s", .mig037_in(s)))
  want <- stats::setNames(.mig037_items$proj_uuid, s)
  if (nrow(pr) != 8L || !identical(unname(want[pr$uuid]), pr$uuid_project)) return("a released sample is not in its planned ALS work order")
  bad <- .mig037_invariant_bad(con)
  if (bad > 0L) return(sprintf("%d dust samples break 021's datetime = date / datetime_start = date_start", bad))
  if (check_index) {
    def <- .mig037_index_def(con)
    if (length(def) != 1L || !identical(def, .mig037_index_sql)) return("ux_sample_identity is missing or changed")
  }
  NULL
}

.mig037_verify <- function(con, check_index = TRUE) {
  p <- .mig037_done_problem(con, check_index)
  if (!is.null(p)) cli::cli_abort(paste0("037 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig037_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig037_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig037_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig037_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig037_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig037_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("037: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Checksums of everything part A may not touch (fresh run only).
.mig037_checksum_a <- function(con, pre_samples, pre_analyses) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "project", "asset", "ingest_file", "review_queue_candidate")
  out <- lapply(tabs, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- tabs
  out$review_queue_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig037_in(.mig037_items$uuid)))
  sp <- DBI::dbGetQuery(con, "SELECT * FROM \"sample\" ORDER BY uuid")
  sp <- sp[sp$uuid %in% pre_samples, , drop = FALSE]
  rownames(sp) <- NULL
  out$sample_pre <- digest::digest(sp, algo = "sha1")
  a <- DBI::dbGetQuery(con, "SELECT * FROM analysis ORDER BY uuid")
  a <- a[a$uuid %in% pre_analyses, , drop = FALSE]
  rownames(a) <- NULL
  out$analysis_pre <- digest::digest(a, algo = "sha1")
  out
}

# Checksums of everything part B may not touch.
.mig037_checksum_b <- function(con, touched) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig037_in(touched)))
  out$sample_touched_other_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, datetime, datetime_start) FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig037_in(touched)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig037_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig037_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# Part A: the 8 releases. Fresh runs are checked against counts + checksums.
.mig037_part_a <- function(db, status, logf) {
  con <- st_connect(db, read_only = TRUE)
  fresh <- all(status == "open")
  if (fresh) {
    pre_s <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\"")$uuid
    pre_a <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis")$uuid
    counts0 <- .mig037_counts(con)
    sums0 <- .mig037_checksum_a(con, pre_s, pre_a)
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  for (i in seq_len(nrow(.mig037_items))) {
    it <- .mig037_items[i, ]
    r <- release_review(it$uuid, overrides = list(date_start = as.Date(it$date_start), date = as.Date(it$date)),
                        resolved_by = .mig037_actor, db = db)
    logf("A: %s %s %s -> %s / %s (%s): %s", it$uuid, it$report, it$gauge, it$date_start, it$date, it$confidence,
         if (isTRUE(r)) "released" else "already resolved")
  }
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  if (fresh) {
    want <- counts0
    want$sample <- want$sample + 8L
    want$analysis <- want$analysis + 32L
    got <- .mig037_counts(con)
    got$change_log <- want$change_log <- 0L   # release_review's own logging; checked via sums
    if (!identical(got, want)) {
      .mig037_fail(sprintf("part A counts are not before + 8 samples + 32 analyses: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums0, .mig037_checksum_a(con, pre_s, pre_a))) .mig037_fail("part A changed something it should not have.")
  } else {
    logf("A: resumed run - count and checksum checks skipped for part A; the verify still applies.")
  }
  rel <- .mig037_released_samples(con)
  it <- DBI::dbGetQuery(con, sprintf("SELECT status, resolved_by FROM review_queue WHERE uuid IN %s", .mig037_in(.mig037_items$uuid)))
  if (any(it$status != "resolved") || any(it$resolved_by != .mig037_actor)) .mig037_fail("part A left an item open.")
  rel
}

# Part B: re-file the 8 samples and set their datetime, marker - one
# transaction, with ux_sample_identity dropped and re-created around it.
.mig037_part_b <- function(con, rel, recorded_at, logf) {
  moves <- data.frame(uuid = rel, to = .mig037_items$proj_uuid,
                      why = sprintf("037 (A80): released %s %s dust filed under its cited ALS work order %s, not the report project",
                                    .mig037_items$report, .mig037_items$gauge, .mig037_items$proj_name),
                      stringsAsFactors = FALSE)
  if (anyDuplicated(moves$uuid)) .mig037_fail("a sample is planned to move twice.")
  # B2: every NULL-datetime dust sample must be exactly the 8 released.
  dated <- .mig037_null_dt(con)
  if (!identical(sort(dated), sort(rel)))
    .mig037_fail(sprintf("NULL-datetime dust samples are not exactly the 8 released: %s.", paste(dated, collapse = ", ")))
  dd <- DBI::dbGetQuery(con, sprintf("SELECT uuid, date, date_start FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig037_in(dated)))
  if (anyNA(dd$date) || anyNA(dd$date_start)) .mig037_fail("a NULL-datetime dust sample lacks date or date_start.")
  # Post-update key uniqueness (alias, datetime, project): moved rows vs everything.
  coll <- .mig037_scalar(con, sprintf("
    WITH m(uuid, to_p) AS (VALUES %s), k AS (
      SELECT s.uuid_feature_alias, CASE WHEN s.uuid IN %s THEN s.date ELSE s.datetime END AS dt,
             COALESCE(m.to_p, s.uuid_project) AS p
      FROM \"sample\" s LEFT JOIN m ON m.uuid = s.uuid)
    SELECT COUNT(*) FROM (SELECT uuid_feature_alias, dt, p FROM k WHERE dt IS NOT NULL GROUP BY uuid_feature_alias, dt, p HAVING COUNT(*) > 1)",
    paste(sprintf("('%s','%s')", moves$uuid, moves$to), collapse = ", "), .mig037_in(dated)))
  if (coll > 0L) .mig037_fail(sprintf("%d (alias, datetime, project) keys would collide; nothing written.", coll))
  counts_before <- .mig037_counts(con)
  sums_before <- .mig037_checksum_b(con, moves$uuid)

  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig037_index_name))
  logf("B: dropped %s (committed).", .mig037_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(moves))) {
        db_update(con, "sample", uuid = moves$uuid[[i]], changes = list(uuid_project = moves$to[[i]]),
                  actor = .mig037_actor, reason = moves$why[[i]])
      }
      for (i in seq_len(nrow(dd))) {
        db_update(con, "sample", uuid = dd$uuid[[i]],
                  changes = list(datetime = dd$date[[i]], datetime_start = dd$date_start[[i]]),
                  actor = .mig037_actor,
                  reason = sprintf("037 (021's invariant): dust datetime = date, datetime_start = date_start; exposed %s collected %s",
                                   format(dd$date_start[[i]], tz = "Australia/Sydney", "%Y-%m-%d"),
                                   format(dd$date[[i]], tz = "Australia/Sydney", "%Y-%m-%d")))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig037_marker_version, recorded_at))
      want <- counts_before
      want$change_log <- want$change_log + nrow(moves) + 2L * nrow(dd)
      want$schema_version <- want$schema_version + 1L
      if (!identical(.mig037_counts(con), want)) .mig037_fail("part B counts are not before + the planned change_log rows + 1 marker.")
      if (!identical(sums_before, .mig037_checksum_b(con, moves$uuid))) .mig037_fail("part B changed something outside the planned columns.")
      .mig037_verify(con, check_index = FALSE)   # the index is re-created after commit
      NULL
    })
    logf("B: re-filed %d samples, set datetime/datetime_start on %d dust samples, marker %d (committed).",
         nrow(moves), nrow(dd), .mig037_marker_version)
  }, finally = {
    if (length(.mig037_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig037_index_sql)
      logf("B: re-created %s.", .mig037_index_name)
    }
  })
  .mig037_verify(con)
  invisible(moves)
}

mig037_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig037_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig037_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("037 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    p <- .mig037_check_preconditions(pre_con)
    p$rq <- DBI::dbGetQuery(pre_con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig037_in(.mig037_items$uuid)))
    p
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: release %d a77 items (%d still open), re-file the 8 new dust samples under their ALS work orders, set their datetime.",
       nrow(.mig037_items), sum(pre$status == "open"))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig037_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig037_default(.now, Sys.time())

  # Row backup BEFORE anything is written (a resumed run keeps the first set).
  if (all(pre$status == "open")) {
    .mig037_write_csv(pre$rq, file.path(csv_dir, sprintf("%s-BACKUP-review_queue.csv", .mig037_name)))
  }

  rel <- .mig037_part_a(db, pre$status, logf)

  with_db_write(function(con) {
    p <- .mig037_check_preconditions(con)   # re-read under the write lock
    if (any(p$status != "resolved")) .mig037_fail("items reopened between part A and part B.")
    rel2 <- .mig037_released_samples(con)
    if (!identical(rel, rel2)) .mig037_fail("the released sample set changed between part A and part B.")
    .mig037_part_b(con, rel2, recorded_at, logf)
  }, db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig037_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig037_in(rel))),
                      file.path(csv_dir, sprintf("%s-INSERTED-sample.csv", .mig037_name)))
    .mig037_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN %s ORDER BY uuid", .mig037_in(rel))),
                      file.path(csv_dir, sprintf("%s-INSERTED-analysis.csv", .mig037_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d).", .mig037_name, .mig037_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
