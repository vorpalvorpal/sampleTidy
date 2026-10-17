# Operator-run migration: release the 10 Blaxland A77 dust blocks withheld by
# the 2026-10-17 pending-documents import, file them under their ALS work
# orders (A80), and re-home the Feb-2025 dust that the legacy load attached
# to the 2026 annual ES2608464. Marker 1035. Requires 1034.
#
# Authorised by the main session, 2026-10-17 (pre-authorised for high and
# medium confidence blocks). Evidence and the decision table:
# scratchpad/2026-10-17-dust/PLAN.md.
#
# ---- A. RELEASE (release_review(), A88) ----------------------------------------
# Ten `date_conflict`/`a77` items, one per gauge-block, released with the
# exposure (date_start) and collection (date) dates the evidence supports:
# report -NN = exposure 1st of NN-1 -> collection 1st of NN (12/12 reports
# with trustworthy Observations), the chain from 7453-10 (exp 2025-09-01,
# coll 2025-10-01), and each sheet's Observations (stale-year in 7538-02).
#   7453-08  2025-07-01 / 2025-08-01  high    DUPLICATE of legacy ES2525054 -> already_present
#   7453-11  2025-10-01 / 2025-11-01  high
#   7453-12  2025-11-01 / 2025-12-01  high
#   7538-01  2025-12-01 / 2026-01-01  high
#   7538-02  2026-01-01 / 2026-02-01  medium  (Observations year stale: 2024)
# Each release_review() call is its own transaction and idempotent (a resolved
# item releases nothing), so a run interrupted in A resumes cleanly.
#
# ---- B. RE-FILE (one transaction) ----------------------------------------------
# B1  release_review() builds its event from the item's work_order - the ACIRL
#     REPORT number - so the 8 new samples land in the report project
#     (2400-7453-11 is even a gas-monitoring project that reused the number).
#     A80 files ACIRL samples under the CITED ALS work order, which is where
#     the same files' other rows went at import: 7453-11 -> ES2537534,
#     7453-12 -> ES2538342, 7538-01 -> ES2600194, 7538-02 -> ES2604522.
#     Each new sample's uuid_project is re-pointed there.
# B2  a0948ef0 (B.D07) / 3ff06304 (B.D08), exposed 2025-02-01, collected
#     2025-03-01, are the 2400-7453-03 "Annual March 2025" workbook's dust
#     (values, Observations dates and text identical). Their dates are RIGHT;
#     their project is wrong: ES2608464 is the 16 Mar 2026 annual (ACIRL
#     reused 2400-7453-03 for it). Re-pointed to ES2506846, the 2025-03-10
#     Blaxland annual that holds that visit and the March 2025 field sheet.
# B3  ES2608464.date_start was dragged to 2025-03-01 by that dust; set to
#     2026-03-16 (its earliest remaining sample; naive midnight as its
#     date_end). Its 5 asset dates (which follow project date_start) move from
#     2025-03-01 to 2026-03-16 (Sydney midnight as UTC, the assets' form).
# B4  021's invariant (datetime = date, datetime_start = date_start on every dust
#     sample, byte-for-byte) was broken by the pipeline: the Oct-2025 dust
#     (7453-10, ES2531465, 96ec8738/cf42b987) and the 8 samples part A releases
#     carry NULL datetime/datetime_start. Set them per 021 (coordinator's
#     instruction, 2026-10-17). Asserted: those 10 are the only NULL-datetime
#     dust samples.
#
# `uuid_project` and `datetime` are in 009's ux_sample_identity, and duckdb 1.4.1 runs an
# UPDATE of an indexed column as delete+insert, which the analysis -> sample
# FK refuses. So B uses 021's tested sequence: drop the index (own commit),
# update in one transaction, and re-create it in a finally whenever it is
# missing. A precondition proves the post-update key set is unique.
#
# Writes: A via release_review(resolved_by = "035-dust-release"); B via
# db_update() (actor "035-dust-release"); marker 1035. Row backups (before):
# 035-dust-release-BACKUP-{review_queue,sample,project,asset}.csv; rows created
# by A: 035-dust-release-INSERTED-{sample,analysis}.csv. Plus the verified
# whole-file backup in snapshot_dir. Rehearsal: scratchpad/2026-10-17-dust/.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/035-dust-release.R", envir = env)
#   env$mig035_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig035_marker_version <- 1035L
.mig035_requires <- 1034L
.mig035_name <- "035-dust-release"
.mig035_actor <- .mig035_name
.mig035_index_name <- "ux_sample_identity"
.mig035_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig035_items <- utils::read.csv(text = "uuid,report,gauge,date_start,date,confidence,expect,proj_uuid,proj_name,total
c9e31171-b309-4f38-a945-074af26b4e55,2400-7453-08,B.D07,2025-07-01,2025-08-01,high,already_present,ebd388c3-de29-437c-9f15-403caf99a453,ES2525054,1.19
1e97d455-530e-412f-94a0-3e79765f5f68,2400-7453-08,B.D08,2025-07-01,2025-08-01,high,already_present,ebd388c3-de29-437c-9f15-403caf99a453,ES2525054,25.56
e16486f4-cda0-451a-99b2-bd68bc8aec25,2400-7453-11,B.D07,2025-10-01,2025-11-01,high,new,a73870ef-431a-47b6-8168-ee455b7e15fd,ES2537534,3.46
65b427c1-41ec-4d27-8024-55a2af9dbc23,2400-7453-11,B.D08,2025-10-01,2025-11-01,high,new,a73870ef-431a-47b6-8168-ee455b7e15fd,ES2537534,2.85
4a73af2c-81f3-4983-8576-deaf0bc96b9f,2400-7453-12,B.D07,2025-11-01,2025-12-01,high,new,fa806613-2d8d-4cc6-82c6-e1111dd9712a,ES2538342,1.02
9b2136b9-e24f-4909-b1bb-beb1c8951344,2400-7453-12,B.D08,2025-11-01,2025-12-01,high,new,fa806613-2d8d-4cc6-82c6-e1111dd9712a,ES2538342,1.44
0f273779-aee0-4509-8e15-6a4616142e42,2400-7538-01,B.D07,2025-12-01,2026-01-01,high,new,93f99101-88c6-4eae-9145-5788c2ef0988,ES2600194,0.66
6cbb7e8a-707a-4263-863a-ce98acb05563,2400-7538-01,B.D08,2025-12-01,2026-01-01,high,new,93f99101-88c6-4eae-9145-5788c2ef0988,ES2600194,0.23
e37a589e-43e8-4a37-991b-30b0ef74872c,2400-7538-02,B.D07,2026-01-01,2026-02-01,medium,new,4222dbe9-c4a2-446d-bd16-02dbf1982f3e,ES2604522,2.5
0acdba8b-54f7-4798-a0c3-72fa597aba30,2400-7538-02,B.D08,2026-01-01,2026-02-01,medium,new,4222dbe9-c4a2-446d-bd16-02dbf1982f3e,ES2604522,0.4",
  stringsAsFactors = FALSE, colClasses = "character")

# B2: the Feb-2025 dust moved from ES2608464 to ES2506846.
.mig035_legacy <- utils::read.csv(text = "uuid,gauge,total
a0948ef0-6a2e-4bb1-8d3e-337080cea1e1,B.D07,2.0
3ff06304-59e5-4e80-a9ea-9cddd72bf13d,B.D08,0.2", stringsAsFactors = FALSE, colClasses = "character")
# B4: the pipeline's Oct-2025 dust (7453-10, ES2531465), committed with NULL datetime.
.mig035_oct <- c("96ec8738-cbe6-4baa-b539-a2579d9c3bcc", "cf42b987-b1e8-4069-a89c-5ca046838edd")
.mig035_dust_uuid_sql <- "SELECT DISTINCT a.uuid_sample FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
  JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE an.name LIKE 'dust-%'"
.mig035_null_dt <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE datetime IS NULL AND uuid IN (%s) ORDER BY uuid",
                               .mig035_dust_uuid_sql))$uuid
}
# 021's invariant over every dust sample: datetime = date, datetime_start = date_start.
.mig035_invariant_bad <- function(con) {
  .mig035_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN (%s) AND
    (datetime IS DISTINCT FROM date OR datetime_start IS DISTINCT FROM date_start)", .mig035_dust_uuid_sql))
}
.mig035_es26 <- "212e78a9-1f18-4b5c-8503-ed521d21556b"    # ES2608464
.mig035_es25 <- "25740b48-17d3-4405-86ba-7da9fe5c5532"    # ES2506846
.mig035_es26_old_start <- as.POSIXct("2025-03-01 00:00:00", tz = "UTC")
.mig035_es26_new_start <- as.POSIXct("2026-03-16 00:00:00", tz = "UTC")
.mig035_asset_old <- as.POSIXct("2025-02-28 13:00:00", tz = "UTC")   # Sydney 2025-03-01 00:00
.mig035_asset_new <- as.POSIXct("2026-03-15 13:00:00", tz = "UTC")   # Sydney 2026-03-16 00:00
.mig035_n_assets <- 5L

.mig035_default <- function(x, default) if (is.null(x)) default else x
.mig035_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig035_fail <- function(msg) cli::cli_abort(paste0(.mig035_name, ": ", msg), class = "sampletidy_error")
.mig035_in <- function(x) paste0("('", paste(x, collapse = "','"), "')")
.mig035_syd <- function(col) sprintf("(%s AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney')::DATE", col)

.mig035_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analyte", "lab_method", "analysis", "sample", "project", "asset",
            "review_queue", "review_queue_candidate", "ingest_file", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig035_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every dust sample (a sample carrying a dust-* analysis) at B.D07/B.D08.
.mig035_dust <- function(con) {
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
    ORDER BY f.name, s.date", .mig035_syd("COALESCE(s.datetime, s.date)"), .mig035_syd("s.date_start")))
}

.mig035_index_def <- function(con) {
  DBI::dbGetQuery(con, "SELECT sql FROM duckdb_indexes() WHERE index_name = ?", params = list(.mig035_index_name))$sql
}

# Items: all 10 must exist as date_conflict/a77 with the planned report/gauge,
# each open, or resolved by THIS migration (a resumed run).
.mig035_item_state <- function(con) {
  it <- DBI::dbGetQuery(con, sprintf(
    "SELECT uuid, kind, subkind, work_order, status, resolved_by, payload FROM review_queue WHERE uuid IN %s",
    .mig035_in(.mig035_items$uuid)))
  if (nrow(it) != nrow(.mig035_items)) .mig035_fail(sprintf("%d of the 10 review items exist.", nrow(it)))
  it <- it[match(.mig035_items$uuid, it$uuid), ]
  for (i in seq_len(nrow(it))) {
    p <- jsonlite::fromJSON(it$payload[[i]], simplifyVector = TRUE)
    if (!identical(it$kind[[i]], "date_conflict") || !identical(it$subkind[[i]], "a77") ||
        !identical(it$work_order[[i]], .mig035_items$report[[i]]) || !identical(p$gauge, .mig035_items$gauge[[i]])) {
      .mig035_fail(sprintf("item %s is not the planned a77 block %s %s.", it$uuid[[i]], .mig035_items$report[[i]], .mig035_items$gauge[[i]]))
    }
    if (!(it$status[[i]] == "open" || (it$status[[i]] == "resolved" && identical(it$resolved_by[[i]], .mig035_actor)))) {
      .mig035_fail(sprintf("item %s is %s by %s, not open.", it$uuid[[i]], it$status[[i]], it$resolved_by[[i]]))
    }
  }
  it$status
}

.mig035_check_preconditions <- function(con) {
  if (.mig035_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig035_requires) == 0L) {
    .mig035_fail(sprintf("marker %d (034) is required first.", .mig035_requires))
  }
  def <- .mig035_index_def(con)
  if (length(def) != 1L || !identical(def, .mig035_index_sql)) {
    .mig035_fail(sprintf("index %s is %s, not 009's definition. If a previous run was killed mid-way, re-create it with: %s",
                         .mig035_index_name, if (length(def)) def else "MISSING", .mig035_index_sql))
  }
  status <- .mig035_item_state(con)
  projs <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name FROM project WHERE uuid IN %s",
                                        .mig035_in(c(.mig035_items$proj_uuid, .mig035_es25, .mig035_es26))))
  want <- unique(rbind(.mig035_items[, c("proj_uuid", "proj_name")],
                       data.frame(proj_uuid = c(.mig035_es25, .mig035_es26), proj_name = c("ES2506846", "ES2608464"))))
  got <- projs$name[match(want$proj_uuid, projs$uuid)]
  if (!identical(got, want$proj_name)) .mig035_fail("a target project is missing or misnamed.")

  d <- .mig035_dust(con)
  # 7453-08's twins: the legacy ES2525054 samples, one per gauge, same values.
  for (i in which(.mig035_items$expect == "already_present")) {
    x <- d[d$gauge == .mig035_items$gauge[[i]] & as.character(d$syd_date) == .mig035_items$date[[i]], ]
    if (nrow(x) != 1L || x$proj != .mig035_items$proj_name[[i]] || as.character(x$syd_start) != .mig035_items$date_start[[i]] ||
        !isTRUE(all.equal(x$total, as.numeric(.mig035_items$total[[i]]))))
      .mig035_fail(sprintf("%s %s: the legacy twin in %s is not as planned.", .mig035_items$report[[i]], .mig035_items$gauge[[i]], .mig035_items$proj_name[[i]]))
  }
  # New blocks still open: nothing may sit at that gauge + Sydney collection day.
  for (i in which(.mig035_items$expect == "new" & status == "open")) {
    x <- d[d$gauge == .mig035_items$gauge[[i]] & as.character(d$syd_date) == .mig035_items$date[[i]], ]
    if (nrow(x) != 0L) .mig035_fail(sprintf("%s %s: a dust sample already exists on %s.", .mig035_items$report[[i]], .mig035_items$gauge[[i]], .mig035_items$date[[i]]))
  }
  # B4 precondition: the only NULL-datetime dust samples are the Oct-2025 pair
  # (plus, on a resumed run, the samples part A released - checked in part B).
  nd <- .mig035_null_dt(con)
  if (!all(.mig035_oct %in% nd)) .mig035_fail("the Oct-2025 dust pair no longer has NULL datetime.")
  if (all(status == "open") && !identical(sort(nd), sort(.mig035_oct)))
    .mig035_fail(sprintf("unexpected NULL-datetime dust samples: %s.", paste(setdiff(nd, .mig035_oct), collapse = ", ")))
  # B2/B3 preconditions.
  lg <- d[d$uuid %in% .mig035_legacy$uuid, ]
  lg <- lg[match(.mig035_legacy$uuid, lg$uuid), ]
  if (nrow(lg) != 2L || anyNA(lg$uuid) || !identical(lg$gauge, .mig035_legacy$gauge) || any(lg$uuid_project != .mig035_es26) ||
      any(as.character(lg$syd_date) != "2025-03-01") || any(as.character(lg$syd_start) != "2025-02-01") ||
      !isTRUE(all.equal(lg$total, as.numeric(.mig035_legacy$total))))
    .mig035_fail("a0948ef0/3ff06304 are not the planned Feb-2025 dust in ES2608464.")
  pj <- DBI::dbGetQuery(con, "SELECT date_start FROM project WHERE uuid = ?", params = list(.mig035_es26))
  if (!identical(as.numeric(pj$date_start), as.numeric(.mig035_es26_old_start))) .mig035_fail("ES2608464.date_start is not 2025-03-01.")
  ast <- DBI::dbGetQuery(con, "SELECT uuid, date FROM asset WHERE uuid_project = ? ORDER BY uuid", params = list(.mig035_es26))
  if (nrow(ast) != .mig035_n_assets || any(as.numeric(ast$date) != as.numeric(.mig035_asset_old)))
    .mig035_fail("ES2608464's assets are not the planned 5 rows dated 2025-03-01 Sydney.")
  # The rest of ES2608464 starts 2026-03-16 (Sydney).
  rest <- DBI::dbGetQuery(con, sprintf("SELECT MIN(%s) AS d FROM \"sample\" s WHERE uuid_project = ? AND uuid NOT IN %s",
                                       .mig035_syd("COALESCE(s.datetime, s.date)"), .mig035_in(.mig035_legacy$uuid)),
                          params = list(.mig035_es26))$d
  if (!identical(as.character(rest), "2026-03-16")) .mig035_fail("ES2608464's remaining samples do not start 2026-03-16.")
  invisible(list(status = status, assets = ast$uuid))
}

# The 8 samples part A created (or the twins, for 7453-08): one per item.
.mig035_released_samples <- function(con) {
  d <- .mig035_dust(con)
  vapply(seq_len(nrow(.mig035_items)), function(i) {
    x <- d[d$gauge == .mig035_items$gauge[[i]] & as.character(d$syd_date) == .mig035_items$date[[i]], ]
    if (nrow(x) != 1L) .mig035_fail(sprintf("%s %s: %d dust samples on %s, expected 1.", .mig035_items$report[[i]], .mig035_items$gauge[[i]], nrow(x), .mig035_items$date[[i]]))
    if (as.character(x$syd_start) != .mig035_items$date_start[[i]]) .mig035_fail(sprintf("%s %s: exposure %s, expected %s.", .mig035_items$report[[i]], .mig035_items$gauge[[i]], x$syd_start, .mig035_items$date_start[[i]]))
    if (!isTRUE(all.equal(x$total, as.numeric(.mig035_items$total[[i]])))) .mig035_fail(sprintf("%s %s: dust-total %s, expected %s.", .mig035_items$report[[i]], .mig035_items$gauge[[i]], x$total, .mig035_items$total[[i]]))
    if (x$n_analyses != 4L) .mig035_fail(sprintf("%s %s: %d analyses, expected 4 (3 dust + Appearance).", .mig035_items$report[[i]], .mig035_items$gauge[[i]], x$n_analyses))
    x$uuid
  }, character(1))
}

.mig035_done_problem <- function(con, check_index = TRUE) {
  if (.mig035_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig035_marker_version) != 1L) return("marker 1035 missing")
  it <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolved_by FROM review_queue WHERE uuid IN %s", .mig035_in(.mig035_items$uuid)))
  if (nrow(it) != 10L || any(it$status != "resolved") || any(it$resolved_by != .mig035_actor)) return("not all 10 items are resolved by 035")
  s <- tryCatch(.mig035_released_samples(con), error = function(e) conditionMessage(e))
  if (length(s) == 1L) return(s)
  pr <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_project FROM \"sample\" WHERE uuid IN %s", .mig035_in(c(s, .mig035_legacy$uuid))))
  want <- c(stats::setNames(.mig035_items$proj_uuid, s), stats::setNames(rep(.mig035_es25, 2), .mig035_legacy$uuid))
  if (nrow(pr) != 12L || !identical(unname(want[pr$uuid]), pr$uuid_project)) return("a re-filed sample is not in its planned project")
  if (length(unique(s)) != 10L) return("expected 8 distinct released samples plus the 2 ES2525054 twins")
  pj <- DBI::dbGetQuery(con, "SELECT date_start FROM project WHERE uuid = ?", params = list(.mig035_es26))
  if (!identical(as.numeric(pj$date_start), as.numeric(.mig035_es26_new_start))) return("ES2608464.date_start is not 2026-03-16")
  ast <- DBI::dbGetQuery(con, "SELECT date FROM asset WHERE uuid_project = ?", params = list(.mig035_es26))
  if (nrow(ast) != .mig035_n_assets || any(as.numeric(ast$date) != as.numeric(.mig035_asset_new))) return("ES2608464's assets are not dated 2026-03-16 Sydney")
  bad <- .mig035_invariant_bad(con)
  if (bad > 0L) return(sprintf("%d dust samples break 021's datetime = date / datetime_start = date_start", bad))
  if (check_index) {
    def <- .mig035_index_def(con)
    if (length(def) != 1L || !identical(def, .mig035_index_sql)) return("ux_sample_identity is missing or changed")
  }
  NULL
}

.mig035_verify <- function(con, check_index = TRUE) {
  p <- .mig035_done_problem(con, check_index)
  if (!is.null(p)) cli::cli_abort(paste0("035 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig035_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig035_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig035_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig035_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig035_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig035_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("035: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Checksums of everything part A may not touch (fresh run only).
.mig035_checksum_a <- function(con, pre_samples, pre_analyses) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  out <- lapply(c("feature", "feature_alias", "analyte", "lab_method", "project", "asset", "ingest_file",
                  "review_queue_candidate"), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- c("feature", "feature_alias", "analyte", "lab_method", "project", "asset", "ingest_file", "review_queue_candidate")
  out$review_queue_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig035_in(.mig035_items$uuid)))
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
.mig035_checksum_b <- function(con, moved, assets, dated) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("sample", "project", "asset", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  touched <- union(moved, dated)
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig035_in(touched)))
  out$sample_touched_other_cols <- q(sprintf("SELECT * EXCLUDE (uuid_project, datetime, datetime_start) FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(touched)))
  if (length(setdiff(dated, moved))) out$sample_dated_only_project <- q(sprintf("SELECT uuid, uuid_project FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(setdiff(dated, moved))))
  if (length(setdiff(moved, dated))) out$sample_moved_only_dt <- q(sprintf("SELECT uuid, datetime, datetime_start FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(setdiff(moved, dated))))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid <> '%s' ORDER BY uuid", .mig035_es26))
  out$project_es26_other_cols <- q(sprintf("SELECT * EXCLUDE (date_start) FROM project WHERE uuid = '%s'", .mig035_es26))
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY uuid", .mig035_in(assets)))
  out$asset_other_cols <- q(sprintf("SELECT * EXCLUDE (date) FROM asset WHERE uuid IN %s ORDER BY uuid", .mig035_in(assets)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig035_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig035_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# Part A: the 10 releases. Fresh runs are checked against counts + checksums.
.mig035_part_a <- function(db, status, logf) {
  con <- st_connect(db, read_only = TRUE)
  fresh <- all(status == "open")
  if (fresh) {
    pre_s <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\"")$uuid
    pre_a <- DBI::dbGetQuery(con, "SELECT uuid FROM analysis")$uuid
    counts0 <- .mig035_counts(con)
    sums0 <- .mig035_checksum_a(con, pre_s, pre_a)
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  for (i in seq_len(nrow(.mig035_items))) {
    it <- .mig035_items[i, ]
    r <- release_review(it$uuid, overrides = list(date_start = as.Date(it$date_start), date = as.Date(it$date)),
                        resolved_by = .mig035_actor, db = db)
    logf("A: %s %s %s -> %s / %s (%s): %s", it$uuid, it$report, it$gauge, it$date_start, it$date, it$confidence,
         if (isTRUE(r)) "released" else "already resolved")
  }
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  if (fresh) {
    want <- counts0
    want$sample <- want$sample + 8L
    want$analysis <- want$analysis + 32L
    got <- .mig035_counts(con)
    got$change_log <- want$change_log <- 0L   # release_review's own logging; checked via sums
    if (!identical(got, want)) {
      .mig035_fail(sprintf("part A counts are not before + 8 samples + 32 analyses: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    }
    if (!identical(sums0, .mig035_checksum_a(con, pre_s, pre_a))) .mig035_fail("part A changed something it should not have.")
  } else {
    logf("A: resumed run - count and checksum checks skipped for part A; the verify still applies.")
  }
  rel <- .mig035_released_samples(con)
  it <- DBI::dbGetQuery(con, sprintf("SELECT status, resolved_by FROM review_queue WHERE uuid IN %s", .mig035_in(.mig035_items$uuid)))
  if (any(it$status != "resolved") || any(it$resolved_by != .mig035_actor)) .mig035_fail("part A left an item open.")
  rel
}

# Part B: re-file 10 samples, ES2608464 + asset dates, marker - one transaction,
# with ux_sample_identity dropped and re-created around it (021's sequence).
.mig035_part_b <- function(con, rel, assets, recorded_at, logf) {
  new_idx <- which(.mig035_items$expect == "new")
  moves <- data.frame(uuid = c(rel[new_idx], .mig035_legacy$uuid),
                      to = c(.mig035_items$proj_uuid[new_idx], rep(.mig035_es25, 2)),
                      why = c(sprintf("035 (A80): released %s %s dust filed under its cited ALS work order %s, not the report project",
                                      .mig035_items$report[new_idx], .mig035_items$gauge[new_idx], .mig035_items$proj_name[new_idx]),
                              sprintf("035: %s Feb-2025 dust (exposed 2025-02-01, collected 2025-03-01; ACIRL 2400-7453-03 Annual March 2025) re-homed from ES2608464 (16 Mar 2026 annual; ACIRL reused the report number) to ES2506846 (2025-03-10 annual)",
                                      .mig035_legacy$gauge)),
                      stringsAsFactors = FALSE)
  if (anyDuplicated(moves$uuid)) .mig035_fail("a sample is planned to move twice.")
  # B4: every NULL-datetime dust sample must be exactly the Oct pair + the 8 released.
  dated <- .mig035_null_dt(con)
  if (!identical(sort(dated), sort(c(.mig035_oct, rel[new_idx]))))
    .mig035_fail(sprintf("NULL-datetime dust samples are not the Oct pair + the 8 released: %s.", paste(dated, collapse = ", ")))
  dd <- DBI::dbGetQuery(con, sprintf("SELECT uuid, date, date_start FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(dated)))
  if (anyNA(dd$date) || anyNA(dd$date_start)) .mig035_fail("a NULL-datetime dust sample lacks date or date_start.")
  # Post-update key uniqueness (alias, datetime, project): moved rows vs everything.
  coll <- .mig035_scalar(con, sprintf("
    WITH m(uuid, to_p) AS (VALUES %s), k AS (
      SELECT s.uuid_feature_alias, CASE WHEN s.uuid IN %s THEN s.date ELSE s.datetime END AS dt,
             COALESCE(m.to_p, s.uuid_project) AS p
      FROM \"sample\" s LEFT JOIN m ON m.uuid = s.uuid)
    SELECT COUNT(*) FROM (SELECT uuid_feature_alias, dt, p FROM k WHERE dt IS NOT NULL GROUP BY uuid_feature_alias, dt, p HAVING COUNT(*) > 1)",
    paste(sprintf("('%s','%s')", moves$uuid, moves$to), collapse = ", "), .mig035_in(dated)))
  if (coll > 0L) .mig035_fail(sprintf("%d (alias, datetime, project) keys would collide; nothing written.", coll))
  counts_before <- .mig035_counts(con)
  sums_before <- .mig035_checksum_b(con, moves$uuid, assets, dated)

  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig035_index_name))
  logf("B: dropped %s (committed).", .mig035_index_name)
  tryCatch({
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(moves))) {
        db_update(con, "sample", uuid = moves$uuid[[i]], changes = list(uuid_project = moves$to[[i]]),
                  actor = .mig035_actor, reason = moves$why[[i]])
      }
      for (i in seq_len(nrow(dd))) {
        db_update(con, "sample", uuid = dd$uuid[[i]],
                  changes = list(datetime = dd$date[[i]], datetime_start = dd$date_start[[i]]),
                  actor = .mig035_actor,
                  reason = sprintf("035 (021's invariant): dust datetime = date, datetime_start = date_start; exposed %s collected %s",
                                   format(dd$date_start[[i]], tz = "Australia/Sydney", "%Y-%m-%d"),
                                   format(dd$date[[i]], tz = "Australia/Sydney", "%Y-%m-%d")))
      }
      db_update(con, "project", uuid = .mig035_es26, changes = list(date_start = .mig035_es26_new_start),
                actor = .mig035_actor,
                reason = "035: ES2608464 date_start 2025-03-01 -> 2026-03-16 (was dragged back by the mis-filed Feb-2025 dust; its samples are 2026-03-16)")
      for (a in assets) {
        db_update(con, "asset", uuid = a, changes = list(date = .mig035_asset_new), actor = .mig035_actor,
                  reason = "035: ES2608464 asset date follows its project date_start, 2025-03-01 -> 2026-03-16 (Sydney)")
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig035_marker_version, recorded_at))
      want <- counts_before
      want$change_log <- want$change_log + nrow(moves) + 2L * nrow(dd) + 1L + length(assets)
      want$schema_version <- want$schema_version + 1L
      if (!identical(.mig035_counts(con), want)) .mig035_fail("part B counts are not before + the planned change_log rows + 1 marker.")
      if (!identical(sums_before, .mig035_checksum_b(con, moves$uuid, assets, dated))) .mig035_fail("part B changed something outside the planned columns.")
      .mig035_verify(con, check_index = FALSE)   # the index is re-created after commit
      NULL
    })
    logf("B: re-filed %d samples, set datetime/datetime_start on %d dust samples, ES2608464 date_start + %d asset dates, marker %d (committed).",
         nrow(moves), nrow(dd), length(assets), .mig035_marker_version)
  }, finally = {
    if (length(.mig035_index_def(con)) == 0L) {
      DBI::dbExecute(con, .mig035_index_sql)
      logf("B: re-created %s.", .mig035_index_name)
    }
  })
  .mig035_verify(con)
  invisible(moves)
}

mig035_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig035_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig035_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("035 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    p <- .mig035_check_preconditions(pre_con)
    p$rq <- DBI::dbGetQuery(pre_con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig035_in(.mig035_items$uuid)))
    p$sample <- DBI::dbGetQuery(pre_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(.mig035_legacy$uuid)))
    p$project <- DBI::dbGetQuery(pre_con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig035_es26))
    p$asset <- DBI::dbGetQuery(pre_con, "SELECT * FROM asset WHERE uuid_project = ? ORDER BY uuid", params = list(.mig035_es26))
    p
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: release %d a77 items (%d still open), re-file 8 new + 2 Feb-2025 dust samples, fix ES2608464 dates.",
       nrow(.mig035_items), sum(pre$status == "open"))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig035_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig035_default(.now, Sys.time())

  # Row backups BEFORE anything is written (a resumed run keeps the first set).
  bk <- function(tab) file.path(csv_dir, sprintf("%s-BACKUP-%s.csv", .mig035_name, tab))
  if (all(pre$status == "open")) {
    .mig035_write_csv(pre$rq, bk("review_queue"))
    .mig035_write_csv(pre$sample, bk("sample"))
    .mig035_write_csv(pre$project, bk("project"))
    .mig035_write_csv(pre$asset, bk("asset"))
  }

  rel <- .mig035_part_a(db, pre$status, logf)

  with_db_write(function(con) {
    p <- .mig035_check_preconditions(con)   # re-read under the write lock
    if (any(p$status != "resolved")) .mig035_fail("items reopened between part A and part B.")
    rel2 <- .mig035_released_samples(con)
    if (!identical(rel, rel2)) .mig035_fail("the released sample set changed between part A and part B.")
    .mig035_part_b(con, rel2, p$assets, recorded_at, logf)
  }, db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    new_s <- rel[.mig035_items$expect == "new"]
    .mig035_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig035_in(new_s))),
                      file.path(csv_dir, sprintf("%s-INSERTED-sample.csv", .mig035_name)))
    .mig035_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN %s ORDER BY uuid", .mig035_in(new_s))),
                      file.path(csv_dir, sprintf("%s-INSERTED-analysis.csv", .mig035_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d).", .mig035_name, .mig035_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
