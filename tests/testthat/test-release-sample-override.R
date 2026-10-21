# tests/testthat/test-release-sample-override.R
#
# Bug (2026-10-21): `release_review(uuid, overrides = list(sample = <uuid>))`
# places a `sample_ambiguous` item's withheld rows on the sample the reviewer
# names, but reconcile's existing-analysis lookup (`.rc_find_existing()`,
# reached through `.rc_three_way()`) ignores that choice and compares the rows
# with analyses on ANY sample at the same feature and Sydney day. With two
# samples at one point-day (two work orders that day), releasing two items
# onto the two samples lets the first release "win": the second is compared
# with the FIRST sample's analyses, so it raises a false `value_conflict`
# (values differ) or is skipped as `already_present` (values equal), and the
# second sample never gets its rows.
#
# Required: when a release names an existing sample, the existing-analysis
# lookup considers only analyses on THAT sample. With no sample override,
# behaviour is unchanged (an equal analysis at the point-day is still
# already_present).
#
# Written test-first (TDD red). Fixtures are synthetic, on seed_db()
# (helper-db.R), built the way test-sample-stream-matching.R builds its A91
# fixtures (those helpers are file-local there, so the few needed are copied
# here with an `rs_` prefix). Nothing touches a live database.

rs_day <- "2025-09-04"            # AEST (UTC+10), no DST

rs_utc <- function(date, hm) {
  format(as.POSIXct(paste(date, hm), tz = "Australia/Sydney"), tz = "UTC",
         "%Y-%m-%d %H:%M:%S")
}

rs_db <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-fph',  'a-0001', 'Field pH', 'field', 'ACIRL', NULL, 'pH', NULL),
    ('lm-fec',  'a-0003', 'Field EC', 'field', 'ACIRL', NULL, 'mS/cm', NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES
    ('p-es1', NULL, NULL, 'ES2527711', 'Work order'),
    ('p-es2', NULL, NULL, 'ES2527799', 'Work order')")
  list(path = path, con = con)
}

# One existing ACIRL-org sample at T.MW01 (fa-0003) on rs_day, 09:25 Sydney,
# holding the given lab_methods with the given values.
rs_sample <- function(con, uuid, project, labs = character(0), values = NULL,
                      alias = "fa-0003", hm = "09:25") {
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
    VALUES (?, ?, ?, CAST(? AS TIMESTAMP), NULL, CAST(? AS TIMESTAMP), 'ACIRL')",
    params = list(uuid, alias, project, rs_utc(rs_day, "00:00"), rs_utc(rs_day, hm)))
  if (is.null(values)) values <- rep(1, length(labs))
  for (k in seq_along(labs)) {
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                         VALUES (?, ?, ?, ?, TRUE, NULL)",
                   params = list(paste0("an-", uuid, "-", labs[[k]]), uuid, labs[[k]], values[[k]]))
  }
  invisible(uuid)
}

# An ACIRL field-sheet row (date-only, method_raw NA, as the adapter emits).
rs_field <- function(analyte = "EC", value = 0.9, feature = "T.MW01",
                     report_no = "2400-9902-09", ref = NULL) {
  spec <- switch(analyte,
    pH = list(a = "Field pH", u = "pH"),
    EC = list(a = "Field EC", u = "mS/cm")
  )
  tibble::tibble(
    source_hash = "hash-x",
    source_ref = if (is.null(ref)) paste0("fld-", feature, "-", analyte, "-", report_no) else ref,
    work_order = report_no, revision = 0L, org = "ACIRL", adapter = "acirl_field_xlsx/1",
    lab_sample_id = feature, sample_type = "Normal", feature_raw = feature,
    analyte_raw = spec$a, cas_number = NA_character_, method_raw = NA_character_,
    total_or_filtered = NA_character_, units_raw = spec$u,
    value_raw = format(value), value_num = value, value_chr = NA_character_,
    below_detection = FALSE, rl = NA_real_, lab_qualifier = NA_character_,
    analysed_date = as.Date(NA), comments = NA_character_, confidence = 1,
    sample_datetime_raw = "04/09/2025", sampler = NA_character_,
    matrix_raw = "Water", parent_sample = NA_character_
  )
}

# One ACIRL orphan event (a field file) through the real reconcile_event() and
# commit_event(), as test-sample-stream-matching.R's ss_ingest() does.
# Returns list(error, hash).
rs_field_event <- function(con, rows, report_no, cited = character(0)) {
  src <- withr::local_tempdir(.local_envir = parent.frame())
  tag <- paste(sample(letters, 8, TRUE), collapse = "")
  fname <- sprintf("%s %s WMF.xlsx", report_no, tag)
  path <- file.path(src, fname)
  writeLines(paste("release-sample-override fixture", tag), path)
  hash <- hash_file(path)
  DBI::dbExecute(con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', NULL, 0)",
    params = list(hash, fname, path))
  rows$source_hash <- hash
  event <- list(
    work_order = NA_character_, orphan = TRUE, results = rows,
    samples = tibble::tibble(sample_datetime_raw = unique(rows$sample_datetime_raw)),
    files = tibble::tibble(hash = hash, filename = fname, adapter = rows$adapter[[1]],
                           rank = 1L, kept = TRUE),
    report = list(sources = stats::setNames(list(list(
      hash = hash, filename = fname, report_no = report_no,
      als_work_orders = cited, feature_aliases = list(), als_candidates = list()
    )), hash))
  )
  err <- tryCatch({
    commit_event(event, reconcile_event(event, con), con)
    NULL
  }, error = function(e) e)
  list(error = err, hash = hash)
}

rs_expect_ok <- function(run) {
  msg <- if (is.null(run$error)) "" else conditionMessage(run$error)
  expect_null(run$error, label = paste("reconcile/commit error:", msg))
}

rs_reviews <- function(con, kind = "sample_ambiguous") {
  DBI::dbGetQuery(con, "SELECT uuid, kind, status, payload, source_hash
                          FROM review_queue WHERE kind = ? ORDER BY uuid",
                  params = list(kind))
}

# The values a sample holds for one lab_method.
rs_values <- function(con, sample_uuid, lab = "lm-fec") {
  DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid_sample = ? AND uuid_lab = ?",
                  params = list(sample_uuid, lab))$value
}

# Two samples at T.MW01 on rs_day (two ALS work orders, one visit; the field
# pH copied into both), then two field files, each with one Field EC reading
# at that point-day: each opens its own sample_ambiguous item. Returns the
# db plus the two items' uuids, in file order. The connection is closed.
rs_two_items <- function(value_1, value_2, env = parent.frame()) {
  db <- rs_db(env)
  con <- db$con
  rs_sample(con, "s-a", project = "p-es1", labs = c("lm-fph", "lm-0001"), values = c(7.1, 7.3))
  rs_sample(con, "s-b", project = "p-es2", labs = c("lm-fph", "lm-0001"), values = c(7.1, 7.3))
  run1 <- rs_field_event(con, rs_field("EC", value_1, report_no = "2400-9902-09"),
                         report_no = "2400-9902-09", cited = "ES2527711")
  rs_expect_ok(run1)
  run2 <- rs_field_event(con, rs_field("EC", value_2, report_no = "2400-9902-10"),
                         report_no = "2400-9902-10", cited = "ES2527799")
  rs_expect_ok(run2)
  rq <- rs_reviews(con)
  item_1 <- rq$uuid[rq$source_hash == run1$hash]
  item_2 <- rq$uuid[rq$source_hash == run2$hash]
  # Setup sanity: two separate open items, each holding its own EC row, with
  # both samples as candidates; nothing committed onto either sample yet.
  expect_equal(nrow(rq), 2)
  expect_length(item_1, 1)
  expect_length(item_2, 1)
  for (p in rq$payload) {
    pl <- jsonlite::fromJSON(p, simplifyVector = TRUE)
    expect_identical(sort(as.character(unlist(pl$candidate_samples))), c("s-a", "s-b"))
    expect_identical(as.character(pl$rows$analyte_raw), "Field EC")
  }
  expect_length(rs_values(con, "s-a"), 0)
  expect_length(rs_values(con, "s-b"), 0)
  DBI::dbDisconnect(con, shutdown = TRUE)
  list(path = db$path, item_1 = item_1, item_2 = item_2)
}

# ==============================================================================
# 1. Different values: each release lands on its own sample, no false conflict
# ==============================================================================

test_that("releasing two sample_ambiguous items onto two samples at one point-day gives each sample its own value", {
  db <- rs_two_items(0.9, 1.2)

  sampleTidy::release_review(db$item_1, overrides = list(sample = "s-a"),
                             resolved_by = "tester", db = db$path)
  sampleTidy::release_review(db$item_2, overrides = list(sample = "s-b"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(rs_values(con, "s-a"), 0.9)
  expect_equal(rs_values(con, "s-b"), 1.2)
  # s-b's EC was never compared with s-a's: no value_conflict was raised.
  expect_equal(nrow(rs_reviews(con, "value_conflict")), 0)
  expect_identical(rs_reviews(con)$status, c("resolved", "resolved"))
})

# ==============================================================================
# 2. Equal values: the second release is NOT silently skipped as already present
# ==============================================================================

test_that("releasing two equal-valued sample_ambiguous items onto two samples gives BOTH samples the row", {
  db <- rs_two_items(0.9, 0.9)

  sampleTidy::release_review(db$item_1, overrides = list(sample = "s-a"),
                             resolved_by = "tester", db = db$path)
  sampleTidy::release_review(db$item_2, overrides = list(sample = "s-b"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(rs_values(con, "s-a"), 0.9)
  expect_equal(rs_values(con, "s-b"), 0.9)
  expect_equal(nrow(rs_reviews(con, "value_conflict")), 0)
  expect_identical(rs_reviews(con)$status, c("resolved", "resolved"))
})

# ==============================================================================
# 3. Regressions: the existing-analysis lookup still works where it should
# ==============================================================================

test_that("a release with no sample override still finds an equal analysis at the point-day as already present", {
  # A non-sample_ambiguous item (an adapter-raised date_conflict), released
  # with no overrides at all, at a point-day whose one sample already holds
  # the equal reading: the row is already present and is not committed again.
  db <- rs_db(); con <- db$con
  rs_sample(con, "s-a", project = "p-es1", labs = c("lm-fph", "lm-fec"), values = c(7.1, 0.9))
  rows <- rs_field("EC", 0.9)
  rows$needs_review <- TRUE
  rows$review_kind <- "date_conflict"
  rows$review_payload <- list(list(subkind = "a77", gauge = "T.MW01"))
  rs_expect_ok(rs_field_event(con, rows, report_no = "2400-9902-09", cited = "ES2527711"))
  rq <- rs_reviews(con, "date_conflict")
  expect_equal(nrow(rq), 1)
  expect_identical(rs_values(con, "s-a"), 0.9)
  DBI::dbDisconnect(con, shutdown = TRUE)

  sampleTidy::release_review(rq$uuid[[1]], resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ec <- DBI::dbGetQuery(con,
    "SELECT a.uuid_sample, a.value FROM analysis a
       JOIN \"sample\" s ON s.uuid = a.uuid_sample
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      WHERE fa.uuid_feature = 'f-0003' AND a.uuid_lab = 'lm-fec'")
  expect_equal(nrow(ec), 1)
  expect_identical(ec$uuid_sample, "s-a")
  expect_equal(nrow(rs_reviews(con, "value_conflict")), 0)
  expect_identical(rs_reviews(con, "date_conflict")$status, "resolved")
})

test_that("a release naming a sample that already holds the equal reading is still already present", {
  # The fix must narrow the lookup to the named sample, not drop it. The item
  # is opened while neither sample holds EC; s-a then gains the equal EC 0.9
  # (another route committed it), so releasing the held EC 0.9 onto s-a adds
  # nothing and raises nothing.
  db <- rs_two_items(0.9, 1.2)
  con <- seed_con(db$path)
  DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                       VALUES ('an-s-a-lm-fec', 's-a', 'lm-fec', 0.9, TRUE, NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)

  sampleTidy::release_review(db$item_1, overrides = list(sample = "s-a"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(rs_values(con, "s-a"), 0.9)
  expect_length(rs_values(con, "s-b"), 0)
  expect_equal(nrow(rs_reviews(con, "value_conflict")), 0)
})
