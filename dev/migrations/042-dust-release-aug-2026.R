# Operator-run migration: release the 2 Blaxland A77 dust blocks of ACIRL report
# 2400-7538-08 (August 2026 monthly; B.D07 and B.D08) withheld by the
# 2026-10-19 email import, file them under the ALS work order ES2626883 (the
# report project's only child; Blaxland visit 2026-08-19), and set datetime =
# date on them. Marker 1042. Requires 1041. Template: 037-dust-release-mar-jul-2026.R.
#
# Robin's standing ruling (035/037): month-label a77 blocks are released. Here
# the Results `Month` cell reads "August" (the COLLECTION month) where the
# adapter expects the exposure month; the payload dates agree with the report
# number convention (report -08 = exposed 2026-07-01, collected 2026-08-01).
#   2400-7538-08  B.D07 insoluble solids 1.99; B.D08 0.77  (each: 3 dust + Appearance)
# NOT released: the 2400-7453-03 Amended 01 a77 items (a stale copy of Feb 2025).
# Each release creates one new sample per gauge (2 samples, 8 analyses). Same
# mechanics, index handling, backups and idempotence as 037.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/042-dust-release-aug-2026.R", envir = env)
#   env$mig042_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig042_marker_version <- 1042L
.mig042_requires <- 1041L
.mig042_name <- "042-dust-release-aug-2026"
.mig042_actor <- .mig042_name
.mig042_index_name <- "ux_sample_identity"
.mig042_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

# total = INSOLUBLE SOLIDS (stored as dust-total).
.mig042_items <- utils::read.csv(text = "uuid,report,gauge,date_start,date,confidence,report_proj,proj_uuid,proj_name,total
7ca9aa13-53f1-458d-98b2-a4ecdd6c6f6b,2400-7538-08,B.D07,2026-07-01,2026-08-01,high,9de43092-80af-4bb1-83e6-203bc20d83d4,2cbce5dc-61fd-4acb-9907-b695cbb2e5c9,ES2626883,1.99
59b2b7cf-d59c-42e1-9827-ee8d910e4a5f,2400-7538-08,B.D08,2026-07-01,2026-08-01,high,9de43092-80af-4bb1-83e6-203bc20d83d4,2cbce5dc-61fd-4acb-9907-b695cbb2e5c9,ES2626883,0.77",
  stringsAsFactors = FALSE, colClasses = "character")

.mig042_dust_uuid_sql <- "SELECT DISTINCT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
  JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%'"
.mig042_null_dt <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE datetime IS NULL AND uuid IN (%s) ORDER BY uuid",
                               .mig042_dust_uuid_sql))$uuid
}
# 021's invariant over every dust sample: datetime = date, datetime_start = date_start.
.mig042_invariant_bad <- function(con) {
  .mig042_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN (%s) AND
    (datetime IS DISTINCT FROM date OR datetime_start IS DISTINCT FROM date_start)", .mig042_dust_uuid_sql))
}

.mig042_default <- function(x, default) if (is.null(x)) default else x
.mig042_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig042_fail <- function(msg) cli::cli_abort(paste0(.mig042_name, ": ", msg), class = "sampletidy_error")
.mig042_in <- function(x) paste0("('", paste(x, collapse = "','"), "')")
.mig042_syd <- function(col) sprintf("(%s AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE", col)
.mig042_dmy <- function(iso) format(as.Date(iso), "%d/%m/%Y")

.mig042_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig042_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every dust sample (a sample carrying a dust-* analysis) at B.D07/B.D08.
.mig042_dust <- function(con) {
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
    ORDER BY f.name, s.date", .mig042_syd("COALESCE(s.datetime, s.date)"), .mig042_syd("s.date_start")))
}

.mig042_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?", params = list(.mig042_index_name))$sql
}

# Items: all 2 must exist as date_conflict/a77 with the planned report, gauge,
# payload dates and withheld INSOLUBLE SOLIDS; each open, or resolved by THIS
# migration (a resumed run).
.mig042_item_state <- function(con) {
  it <- DBI::dbGetQuery(con, sprintf(
    "SELECT uuid, kind, subkind, work_order, status, resolved_by, payload FROM review_queue WHERE uuid IN %s",
    .mig042_in(.mig042_items$uuid)))
  if (nrow(it) != nrow(.mig042_items)) .mig042_fail(sprintf("%d of the 2 review items exist.", nrow(it)))
  it <- it[match(.mig042_items$uuid, it$uuid), ]
  for (i in seq_len(nrow(it))) {
    pl <- .mig042_items[i, ]
    p <- jsonlite::fromJSON(it$payload[[i]], simplifyVector = TRUE)
    if (!identical(it$kind[[i]], "date_conflict") || !identical(it$subkind[[i]], "a77") ||
        !identical(it$work_order[[i]], pl$report) || !identical(p$gauge, pl$gauge)) {
      .mig042_fail(sprintf("item %s is not the planned a77 block %s %s.", it$uuid[[i]], pl$report, pl$gauge))
    }
    ins <- p$withheld$value[p$withheld$analyte == "INSOLUBLE SOLIDS"]
    if (!identical(p$exposure_date, pl$date_start) || !identical(p$collection_date, pl$date) ||
        any(p$rows$sample_date_start_raw != .mig042_dmy(pl$date_start)) ||
        any(p$rows$sample_datetime_raw != .mig042_dmy(pl$date)) ||
        length(ins) != 1L || !isTRUE(all.equal(as.numeric(ins), as.numeric(pl$total))) ||
        NROW(p$rows) != 4L) {
      .mig042_fail(sprintf("item %s (%s %s): payload dates/values are not as planned.", it$uuid[[i]], pl$report, pl$gauge))
    }
    if (!(it$status[[i]] == "open" || (it$status[[i]] == "resolved" && identical(it$resolved_by[[i]], .mig042_actor)))) {
      .mig042_fail(sprintf("item %s is %s by %s, not open.", it$uuid[[i]], it$status[[i]], it$resolved_by[[i]]))
    }
  }
  it$status
}

.mig042_check_preconditions <- function(con) {
  if (.mig042_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig042_requires) == 0L) {
    .mig042_fail(sprintf("marker %d (041) is required first.", .mig042_requires))
  }
  def <- .mig042_index_def(con)
  if (length(def) != 1L || !identical(def, .mig042_index_sql)) {
    .mig042_fail(sprintf("index %s is %s, not 009's definition. If a previous run was killed mid-way, re-create it with: %s",
                         .mig042_index_name, if (length(def)) def else "MISSING", .mig042_index_sql))
  }
  status <- .mig042_item_state(con)
  # Target ALS work orders exist, are named as planned, and are children of the report.
  pr <- unique(.mig042_items[, c("report", "report_proj", "proj_uuid", "proj_name")])
  got <- DBI::dbGetQuery(con, sprintf("SELECT c.uuid, c.name, c.uuid_parent, p.name AS parent_name FROM project c
    LEFT JOIN project p ON p.uuid = c.uuid_parent WHERE c.uuid IN %s", .mig042_in(pr$proj_uuid)))
  got <- got[match(pr$proj_uuid, got$uuid), ]
  if (anyNA(got$uuid) || !identical(got$name, pr$proj_name) || !identical(got$uuid_parent, pr$report_proj) ||
      !identical(got$parent_name, pr$report)) {
    .mig042_fail("a target ALS work-order project is missing, misnamed, or not the report's child.")
  }
  d <- .mig042_dust(con)
  # Blocks still open: nothing may sit at that gauge + Sydney collection day.
  for (i in which(status == "open")) {
    x <- d[d$gauge == .mig042_items$gauge[[i]] & as.character(d$syd_date) == .mig042_items$date[[i]], ]
    if (nrow(x) != 0L) .mig042_fail(sprintf("%s %s: a dust sample already exists on %s.", .mig042_items$report[[i]], .mig042_items$gauge[[i]], .mig042_items$date[[i]]))
  }
  # B2 precondition: on a fresh run no dust sample has NULL datetime.
  nd <- .mig042_null_dt(con)
  if (all(status == "open") && length(nd) > 0L)
    .mig042_fail(sprintf("unexpected NULL-datetime dust samples before the run: %s.", paste(nd, collapse = ", ")))
  invisible(list(status = status))
}

# The 2 samples part A created: one per item.
.mig042_released_samples <- function(con) {
  d <- .mig042_dust(con)
  vapply(seq_len(nrow(.mig042_items)), function(i) {
    it <- .mig042_items[i, ]
    x <- d[d$gauge == it$gauge & as.character(d$syd_date) == it$date, ]
    if (nrow(x) != 1L) .mig042_fail(sprintf("%s %s: %d dust samples on %s, expected 1.", it$report, it$gauge, nrow(x), it$date))
    if (as.character(x$syd_start) != it$date_start) .mig042_fail(sprintf("%s %s: exposure %s, expected %s.", it$report, it$gauge, x$syd_start, it$date_start))
    if (!isTRUE(all.equal(x$total, as.numeric(it$total)))) .mig042_fail(sprintf("%s %s: dust-total %s, expected %s.", it$report, it$gauge, x$total, it$total))
    if (x$n_analyses != 4L) .mig042_fail(sprintf("%s %s: %d analyses, expected 4 (3 dust + Appearance).", it$report, it$gauge, x$n_analyses))
    x$uuid
  }, character(1))
}

.mig042_done_problem <- function(con, check_index = TRUE) {
  if (.mig042_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig042_marker_version) != 1L) return("marker 1042 missing")
  it <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolved_by FROM review_queue WHERE uuid IN %s", .mig042_in(.mig042_items$uuid)))
  if (nrow(it) != 2L || any(it$status != "resolved") || any(it$resolved_by != .mig042_actor)) return("not all 2 items are resolved by 042")
  s <- tryCatch(.mig042_released_samples(con), error = function(e) conditionMessage(e))
  if (length(s) == 1L) return(s)
  if (length(unique(s)) != 2L) return("expected 2 distinct released samples")
  pr <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_project FROM \"sample\" WHERE uuid IN %s", .mig042_in(s)))
  want <- stats::setNames(.mig042_items$proj_uuid, s)
  if (nrow(pr) != 2L || !identical(unname(want[pr$uuid]), pr$uuid_project)) return("a released sample is not in its planned ALS work order")
  bad <- .mig042_invariant_bad(con)
  if (bad > 0L) return(sprintf("%d dust samples break 021's datetime = date / datetime_start = date_start", bad))
  if (check_index) {
    def <- .mig042_index_def(con)
    if (length(def) != 1L || !identical(def, .mig042_index_sql)) return("ux_sample_identity is missing or changed")
  }
  NULL
}

.mig042_verify <- function(con, check_index = TRUE) {
  p <- .mig042_done_problem(con, check_index)
  if (!is.null(p)) cli::cli_abort(paste0("042 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig042_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig042_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig042_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig042_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig042_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig042_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("042: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Checksums of everything part A may not touch (fresh run only).
.mig042_checksum_a <- function(con, pre_samples, pre_analyses) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "project", "asset", "ingest_file", "review_queue_candidate")
  out <- lapply(tabs, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- tabs
  out$review_queue_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig042_in(.mig042_items$uuid)))
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
.mig042_checksum_b <- function(con, touched) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig042_in(touched)))
  out$sample_touched_other_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, datetime, datetime_start) FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig042_in(touched)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig042_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig042_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# Part A: the 2 releases. Fresh runs are checked against counts + checksums.
.mig042_part_a <- function(db, status, logf) {
  con <- st_connect(db, read_only = TRUE)
  fresh <- all(status == "open")
  if (fresh) {
    pre_s <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\"")$uuid
    pre_a <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis")$uuid
    counts0 <- .mig042_counts(con)
    sums0 <- .mig042_checksum_a(con, pre_s, pre_a)
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  for (i in seq_len(nrow(.mig042_items))) {
    it <- .mig042_items[i, ]
    r <- release_review(it$uuid, overrides = list(date_start = as.Date(it$date_start), date = as.Date(it$date)),
                        resolved_by = .mig042_actor, db = db)
    logf("A: %s %s %s -> %s / %s (%s): %s", it$uuid, it$report, it$gauge, it$date_start, it$date, it$confidence,
         if (isTRUE(r)) "released" else "already resolved")
  }
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  if (fresh) {
    want <- counts0
    want$sample <- want$sample + 2L
    want$analysis <- want$analysis + 8L
    got <- .mig042_counts(con)
    got$change_log <- want$change_log <- 0L   # release_review's own logging; checked via sums
    if (!identical(got, want)) {
      .mig042_fail(sprintf("part A counts are not before + 2 samples + 8 analyses: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums0, .mig042_checksum_a(con, pre_s, pre_a))) .mig042_fail("part A changed something it should not have.")
  } else {
    logf("A: resumed run - count and checksum checks skipped for part A; the verify still applies.")
  }
  rel <- .mig042_released_samples(con)
  it <- DBI::dbGetQuery(con, sprintf("SELECT status, resolved_by FROM review_queue WHERE uuid IN %s", .mig042_in(.mig042_items$uuid)))
  if (any(it$status != "resolved") || any(it$resolved_by != .mig042_actor)) .mig042_fail("part A left an item open.")
  rel
}

# Part B: re-file the 2 samples and set their datetime, marker - one
# transaction, with ux_sample_identity dropped and re-created around it.
.mig042_part_b <- function(con, rel, recorded_at, logf) {
  moves <- data.frame(uuid = rel, to = .mig042_items$proj_uuid,
                      why = sprintf("042 (A80 as 037): released %s %s dust filed under its cited ALS work order %s, not the report project",
                                    .mig042_items$report, .mig042_items$gauge, .mig042_items$proj_name),
                      stringsAsFactors = FALSE)
  if (anyDuplicated(moves$uuid)) .mig042_fail("a sample is planned to move twice.")
  # B2: every NULL-datetime dust sample must be exactly the 2 released.
  dated <- .mig042_null_dt(con)
  if (!identical(sort(dated), sort(rel)))
    .mig042_fail(sprintf("NULL-datetime dust samples are not exactly the 2 released: %s.", paste(dated, collapse = ", ")))
  dd <- DBI::dbGetQuery(con, sprintf("SELECT uuid, date, date_start FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig042_in(dated)))
  if (anyNA(dd$date) || anyNA(dd$date_start)) .mig042_fail("a NULL-datetime dust sample lacks date or date_start.")
  # Post-update key uniqueness (alias, datetime, project): moved rows vs everything.
  coll <- .mig042_scalar(con, sprintf("
    WITH m(uuid, to_p) AS (VALUES %s), k AS (
      SELECT s.uuid_feature_alias, CASE WHEN s.uuid IN %s THEN s.date ELSE s.datetime END AS dt,
             COALESCE(m.to_p, s.uuid_project) AS p
      FROM \"sample\" s LEFT JOIN m ON m.uuid = s.uuid)
    SELECT COUNT(*) FROM (SELECT uuid_feature_alias, dt, p FROM k WHERE dt IS NOT NULL GROUP BY uuid_feature_alias, dt, p HAVING COUNT(*) > 1)",
    paste(sprintf("('%s','%s')", moves$uuid, moves$to), collapse = ", "), .mig042_in(dated)))
  if (coll > 0L) .mig042_fail(sprintf("%d (alias, datetime, project) keys would collide; nothing written.", coll))
  counts_before <- .mig042_counts(con)
  sums_before <- .mig042_checksum_b(con, moves$uuid)

  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig042_index_name))
  logf("B: dropped %s (committed).", .mig042_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(moves))) {
        db_update(con, "sample", uuid = moves$uuid[[i]], changes = list(uuid_project = moves$to[[i]]),
                  actor = .mig042_actor, reason = moves$why[[i]])
      }
      for (i in seq_len(nrow(dd))) {
        db_update(con, "sample", uuid = dd$uuid[[i]],
                  changes = list(datetime = dd$date[[i]], datetime_start = dd$date_start[[i]]),
                  actor = .mig042_actor,
                  reason = sprintf("042 (021's invariant): dust datetime = date, datetime_start = date_start; exposed %s collected %s",
                                   format(dd$date_start[[i]], tz = "Australia/Sydney", "%Y-%m-%d"),
                                   format(dd$date[[i]], tz = "Australia/Sydney", "%Y-%m-%d")))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig042_marker_version, recorded_at))
      want <- counts_before
      want$change_log <- want$change_log + nrow(moves) + 2L * nrow(dd)
      want$schema_version <- want$schema_version + 1L
      if (!identical(.mig042_counts(con), want)) .mig042_fail("part B counts are not before + the planned change_log rows + 1 marker.")
      if (!identical(sums_before, .mig042_checksum_b(con, moves$uuid))) .mig042_fail("part B changed something outside the planned columns.")
      .mig042_verify(con, check_index = FALSE)   # the index is re-created after commit
      NULL
    })
    logf("B: re-filed %d samples, set datetime/datetime_start on %d dust samples, marker %d (committed).",
         nrow(moves), nrow(dd), .mig042_marker_version)
  }, finally = {
    if (length(.mig042_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig042_index_sql)
      logf("B: re-created %s.", .mig042_index_name)
    }
  })
  .mig042_verify(con)
  invisible(moves)
}

mig042_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig042_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig042_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("042 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    p <- .mig042_check_preconditions(pre_con)
    p$rq <- DBI::dbGetQuery(pre_con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig042_in(.mig042_items$uuid)))
    p
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: release %d a77 items (%d still open), re-file the 2 new dust samples under their ALS work orders, set their datetime.",
       nrow(.mig042_items), sum(pre$status == "open"))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig042_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig042_default(.now, Sys.time())

  # Row backup BEFORE anything is written (a resumed run keeps the first set).
  if (all(pre$status == "open")) {
    .mig042_write_csv(pre$rq, file.path(csv_dir, sprintf("%s-BACKUP-review_queue.csv", .mig042_name)))
  }

  rel <- .mig042_part_a(db, pre$status, logf)

  with_db_write(function(con) {
    p <- .mig042_check_preconditions(con)   # re-read under the write lock
    if (any(p$status != "resolved")) .mig042_fail("items reopened between part A and part B.")
    rel2 <- .mig042_released_samples(con)
    if (!identical(rel, rel2)) .mig042_fail("the released sample set changed between part A and part B.")
    .mig042_part_b(con, rel2, recorded_at, logf)
  }, db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig042_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig042_in(rel))),
                      file.path(csv_dir, sprintf("%s-INSERTED-sample.csv", .mig042_name)))
    .mig042_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN %s ORDER BY uuid", .mig042_in(rel))),
                      file.path(csv_dir, sprintf("%s-INSERTED-analysis.csv", .mig042_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d).", .mig042_name, .mig042_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
