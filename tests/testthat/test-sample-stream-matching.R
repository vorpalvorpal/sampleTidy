# tests/testthat/test-sample-stream-matching.R
#
# A91 - a sample is matched within its contractor STREAM; an ambiguous match is
# reviewed, not refused (dev/plans/OPERATING-RULES.md A91, amending A84's import
# half). Design: scratchpad/2026-10-17-acirlmatch/DESIGN.md, rule R2 (section 3)
# and its test list (section 5). Robin's rulings, 2026-10-17:
#   D1  gas readings get their own samples (stream `gas`) and never share the
#       ACIRL field sample;
#   D2  review-not-abort applies to EVERY adapter, ALS included;
#   D3  on a day holding only an ALS sample, an ACIRL field row creates a
#       separate ACIRL sample.
#
# Written test-first (TDD red). The numbers in each test name ("[5.n]") are the
# DESIGN.md section-5 item the test covers.
#
# ---- INTERFACES THIS FILE PINS (the implementer builds to these) -------------
#
#   .rc_lab_stream(uuid_lab, registry)        -> character, one per uuid_lab
#       The stream of an ANALYSIS, from its lab_method: "gas" when the method's
#       analyte has type 'gas'; otherwise the lab_method's `organisation`
#       ("ACIRL", "ALS", "legacy", "Internal", ...; NA when that is NULL).
#       `registry` is `.rc_load_registry(con)`.
#
#   .rc_row_stream(rows, registry)            -> character, one per row
#       The stream of an INCOMING row (columns uuid_lab, uuid_analyte,
#       matrix_raw, org): `.rc_lab_stream()` of its resolved uuid_lab; with no
#       known lab_method, "gas" when matrix_raw == "Gas", otherwise `org`.
#
#   .ct_sample_match(con, pending, match_feature, alias_uuid, sample_date,
#                    sample_datetime, stream)  -> list(outcome, uuid, candidates)
#       READ-ONLY, NEVER aborts. `outcome` is one of "new", "reuse",
#       "ambiguous", "cross_stream_instant". `uuid` is the reused sample (NA
#       otherwise). `candidates` is the SORTED character vector of sample uuids
#       the outcome is about (the survivors for "ambiguous"; the other-stream
#       sample(s) at the same instant for "cross_stream_instant"; character(0)
#       for "new").
#
#   review item: kind = "sample_ambiguous"; subkind "cross_stream_instant" for
#       DESIGN 3.1 step 5 (and NOT that for the in-stream case). The JSON
#       payload carries `rows` (the withheld rows, A88 shape, so
#       release_review() can place them) and `candidate_samples` (the sorted
#       candidate sample uuids). NB `review_queue_candidate` cannot carry a
#       sample uuid (its only target column is `uuid_feature NOT NULL`), so the
#       payload is where the candidate samples are pinned.
#
#   release_review(uuid, overrides = list(sample = <candidate uuid> | "new"),
#                  resolved_by, db)
#       places the withheld rows on that sample, or on a new one; a uuid that
#       is not one of the item's candidates is refused (sampletidy_error) and
#       the item stays open.
#
# Every fixture is synthetic, built on seed_db() (helper-db.R) with extra
# lab_methods of the real live shapes (DESIGN 1.1). Events are built directly
# and driven through the real reconcile_event() and commit_event(), the
# test-commit.R pattern; nothing touches a live database.

# ---- fixture -------------------------------------------------------------------

ss_day <- "2025-09-04"            # a September Thursday; AEST (UTC+10), no DST

# A Sydney wall-clock time on `date` as the UTC instant duckdb stores.
ss_utc <- function(date, hm) {
  format(as.POSIXct(paste(date, hm), tz = "Australia/Sydney"), tz = "UTC",
         "%Y-%m-%d %H:%M:%S")
}

ss_db <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS) VALUES
    ('a-ch4', 'CH4', 'L/L', 1, 'gas', NULL),
    ('a-h2s', 'H2S', 'ppm', 1, 'gas', NULL),
    ('a-dins', 'Total Insoluble Solids', 'g/m2/month', NULL, 'particulate', NULL),
    ('a-dcom', 'Combustible Matter', 'g/m2/month', NULL, 'particulate', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-fph',  'a-0001', 'Field pH', 'field', 'ACIRL', NULL, 'pH', NULL),
    ('lm-fec',  'a-0003', 'Field EC', 'field', 'ACIRL', NULL, 'mS/cm', NULL),
    ('lm-ch4',  'a-ch4',  'CH4 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL),
    ('lm-h2s',  'a-h2s',  'H2S Reading', 'field', 'ACIRL', NULL, 'ppm', NULL),
    ('lm-dins', 'a-dins', 'INSOLUBLE SOLIDS', 'AS3580.10.1-2003', 'ACIRL', NULL, 'g/m2/month', NULL),
    ('lm-dcom', 'a-dcom', '*COMBUSTIBLE MATTER', 'AS3580.10.1-2003', 'ACIRL', NULL, 'g/m2/month', NULL),
    ('lm-en67', 'a-0001', 'pH (field)', 'EN67 - Client Supplied Data', 'ALS', NULL, 'pH', NULL),
    ('lm-legph', 'a-0001', 'pH', 'field', 'legacy', NULL, 'pH', NULL),
    ('lm-intph', 'a-0001', 'pH', 'field', 'Internal', NULL, 'pH', NULL),
    ('lm-nullorg', 'a-0002', 'Computed thing', NULL, NULL, NULL, 'mg/L', NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES
    ('p-es1', NULL, NULL, 'ES2527711', 'Work order'),
    ('p-es2', NULL, NULL, 'ES2527799', 'Work order'),
    ('p-gascamp', NULL, 'p-gascamp', 'Monthly gas monitoring', NULL),
    ('p-gasleg', 'p-gascamp', 'p-gascamp', '2400-9900-08-01', 'Monthly gas monitoring'),
    ('p-dust', NULL, NULL, 'Dust 2024', 'Dust monitoring')")
  list(path = path, con = con)
}

# One existing sample. `date` is the Sydney day; it is stored the LEGACY way
# (Sydney midnight as its UTC instant, the 024 shape) unless `naive = TRUE`
# (the pipeline's naive midnight). `hm` is a Sydney wall-clock time, or NA.
ss_sample <- function(con, uuid, alias = "fa-0003", date = ss_day, hm = NA,
                      project = "p-es1", labs = character(0), values = NULL,
                      naive = FALSE, date_start = NA) {
  stored_date <- if (naive) paste(date, "00:00:00") else ss_utc(date, "00:00")
  dt <- if (is.na(hm)) NA_character_ else ss_utc(date, hm)
  ds <- if (is.na(date_start)) NA_character_ else ss_utc(date_start, "00:00")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
    VALUES (?, ?, ?, CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), CAST(? AS TIMESTAMP), 'ACIRL')",
    params = list(uuid, alias, project, stored_date, ds, dt))
  if (is.null(values)) values <- rep(1, length(labs))
  for (k in seq_along(labs)) {
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                         VALUES (?, ?, ?, ?, TRUE, NULL)",
                   params = list(paste0("an-", uuid, "-", labs[[k]]), uuid, labs[[k]], values[[k]]))
  }
  invisible(uuid)
}

# Shapes (DESIGN 1.2): the lab_methods a sample of each class holds.
ss_labs <- list(
  ALS = c("lm-0001", "lm-0003"),
  AF = c("lm-fph", "lm-fec"),
  MERGED = c("lm-fph", "lm-0001"),
  GAS = "lm-ch4",
  DUST = c("lm-dins", "lm-dcom"),
  NEUTRAL = "lm-legph"
)

# ---- incoming rows ---------------------------------------------------------------

ss_row <- function(...) {
  defaults <- list(
    source_hash = "hash-x", source_ref = "r1", work_order = "ES2527711",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = "ES2527711001", sample_type = "Normal",
    feature_raw = "T.MW01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", total_or_filtered = "T",
    units_raw = "pH Unit", value_raw = "7.20", value_num = 7.20,
    value_chr = NA_character_, below_detection = FALSE, rl = NA_real_,
    lab_qualifier = NA_character_, analysed_date = as.Date(NA),
    comments = NA_character_, confidence = 1,
    sample_datetime_raw = "04 Sep 2025 09:25", sampler = NA_character_,
    matrix_raw = "WATER", parent_sample = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

# An ALS (ESdat) row; `when` is the raw sample datetime ("04 Sep 2025 09:25",
# or "04/09/2025" for a date-only XTAB-shaped row).
ss_als <- function(analyte = "pH", value = 7.2, feature = "T.MW01",
                   when = "04 Sep 2025 09:25", wo = "ES2527711", ref = NULL) {
  spec <- switch(analyte,
    pH = list(a = "pH Value", m = "EA005P: pH by PC Titrator", u = "pH Unit"),
    EC = list(a = "Electrical Conductivity @ 25°C", m = "EA010P: Conductivity by PC Titrator", u = "µS/cm")
  )
  ss_row(source_ref = if (is.null(ref)) paste0("als-", feature, "-", analyte) else ref,
         work_order = wo, feature_raw = feature, analyte_raw = spec$a, method_raw = spec$m,
         units_raw = spec$u, value_raw = format(value), value_num = value,
         sample_datetime_raw = when)
}

# An ACIRL field-sheet row: date-only, method_raw NA (as the adapter emits).
ss_field <- function(analyte = "pH", value = 7.1, feature = "T.MW01",
                     when = "04/09/2025", report_no = "2400-9902-09", ref = NULL) {
  spec <- switch(analyte,
    pH = list(a = "Field pH", u = "pH"),
    EC = list(a = "Field EC", u = "mS/cm"),
    SWL = list(a = "Standing Water Level", u = "m")
  )
  ss_row(source_ref = if (is.null(ref)) paste0("fld-", feature, "-", analyte) else ref,
         work_order = report_no, org = "ACIRL", adapter = "acirl_field_xlsx/1",
         lab_sample_id = feature, feature_raw = feature, analyte_raw = spec$a,
         method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = spec$u,
         value_raw = format(value), value_num = value, sample_datetime_raw = when,
         matrix_raw = "Water")
}

# An ACIRL monthly-gas row, exactly as R/adapter-acirl-gas.R emits it.
ss_gas <- function(value = 0.5, feature = "T.MW01", when = "04/09/2025",
                   report_no = "2400-9904-09-01", ref = NULL) {
  ss_row(source_ref = if (is.null(ref)) paste0("gas-", feature) else ref,
         work_order = report_no, org = "ACIRL", adapter = "acirl_gas_xlsx/1",
         lab_sample_id = feature, feature_raw = feature, analyte_raw = "CH4 Reading % v/v",
         method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = "%",
         value_raw = format(value), value_num = value, below_detection = isTRUE(value == 0),
         sample_datetime_raw = when, matrix_raw = "Gas")
}

# ---- driving one event through reconcile + commit ---------------------------------

# Writes a real source file, registers it in ingest_file at `reconciled`, and
# builds the event as assembly does: an ALS event carries its work order; an
# ACIRL event is an orphan carrying PLAN-07's per-hash `sources` (A80).
# Returns list(resolved, result, error, hash). `error` is the condition if
# reconcile or commit raised one (so a test can show WHAT failed), else NULL.
ss_ingest <- function(con, rows, kind = c("als", "acirl"), work_order = "ES2527711",
                      report_no = NA_character_, cited = character(0), tag = NULL) {
  kind <- match.arg(kind)
  src <- withr::local_tempdir(.local_envir = parent.frame())
  if (is.null(tag)) tag <- paste(sample(letters, 8, TRUE), collapse = "")
  fname <- if (kind == "als") sprintf("ESDAT_%s_%s.csv", work_order, tag) else
    sprintf("%s %s WMF.xlsx", report_no, tag)
  path <- file.path(src, fname)
  writeLines(paste("a91 fixture", tag, kind), path)
  hash <- hash_file(path)
  DBI::dbExecute(con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', ?, 0)",
    params = list(hash, fname, path, if (kind == "als") work_order else NA_character_))
  rows$source_hash <- hash
  event <- if (kind == "als") {
    list(
      work_order = work_order, orphan = FALSE, results = rows,
      samples = tibble::tibble(sample_datetime_raw = unique(rows$sample_datetime_raw)),
      files = tibble::tibble(hash = hash, filename = fname, adapter = "esdat/1",
                             rank = 1L, kept = TRUE),
      report = list(n_results = nrow(rows), n_by_sample_type = list(), n_ncp_foreign = 0L,
                    skipped = tibble::tibble(hash = character(), source_ref = character(),
                                             reason = character()),
                    warnings = character())
    )
  } else {
    list(
      work_order = NA_character_, orphan = TRUE, results = rows,
      samples = tibble::tibble(sample_datetime_raw = unique(rows$sample_datetime_raw)),
      files = tibble::tibble(hash = hash, filename = fname, adapter = rows$adapter[[1]],
                             rank = 1L, kept = TRUE),
      report = list(sources = stats::setNames(list(list(
        hash = hash, filename = fname, report_no = report_no,
        als_work_orders = cited, feature_aliases = list(), als_candidates = list()
      )), hash))
    )
  }
  resolved <- NULL
  result <- NULL
  err <- tryCatch({
    resolved <- reconcile_event(event, con)
    result <- commit_event(event, resolved, con)
    NULL
  }, error = function(e) e)
  list(resolved = resolved, result = result, error = err, hash = hash, event = event)
}

ss_als_event <- function(con, rows, wo = "ES2527711", ...) {
  ss_ingest(con, rows, "als", work_order = wo, ...)
}
ss_field_event <- function(con, rows, report_no = "2400-9902-09", cited = "ES2527711", ...) {
  ss_ingest(con, rows, "acirl", report_no = report_no, cited = cited, ...)
}
ss_gas_event <- function(con, rows, report_no = "2400-9904-09-01", ...) {
  ss_ingest(con, rows, "acirl", report_no = report_no, ...)
}

# Fail with the condition's own message rather than a later count mismatch.
ss_expect_ok <- function(run) {
  msg <- if (is.null(run$error)) "" else conditionMessage(run$error)
  expect_null(run$error, label = paste("reconcile/commit error:", msg))
}

# ---- reading the result back --------------------------------------------------------

# Every sample at a feature on ss_day, with its project name and the sorted
# set of lab_methods it holds.
ss_samples_at <- function(con, uuid_feature, day = ss_day) {
  s <- DBI::dbGetQuery(con, paste0(
    "SELECT s.uuid, s.datetime, p.name AS project, p.uuid AS uuid_project,
            pp.name AS project_parent, pr.name AS project_root
       FROM \"sample\" s
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
       LEFT JOIN project p ON p.uuid = s.uuid_project
       LEFT JOIN project pp ON pp.uuid = p.uuid_parent
       LEFT JOIN project pr ON pr.uuid = p.uuid_root
      WHERE fa.uuid_feature = ? AND ", sampleTidy:::.ct_sydney_day_sql("s.date"), " = ?
      ORDER BY s.uuid"), params = list(uuid_feature, day))
  s$labs <- vapply(s$uuid, function(u) {
    paste(sort(DBI::dbGetQuery(con, "SELECT uuid_lab FROM analysis WHERE uuid_sample = ?",
                               params = list(u))$uuid_lab), collapse = "+")
  }, character(1))
  s
}

ss_labs_of <- function(con, sample_uuid) {
  sort(DBI::dbGetQuery(con, "SELECT uuid_lab FROM analysis WHERE uuid_sample = ?",
                       params = list(sample_uuid))$uuid_lab)
}

ss_reviews <- function(con, kind = "sample_ambiguous") {
  DBI::dbGetQuery(con, "SELECT uuid, kind, subkind, status, payload, source_hash
                          FROM review_queue WHERE kind = ? ORDER BY uuid",
                  params = list(kind))
}

# The parsed payload of ONE review row; an empty list when there is not
# exactly one (so a missing item fails its own count expectation, not a
# JSON parse error).
ss_payload <- function(p) {
  if (length(p) != 1 || is.na(p)) return(list())
  jsonlite::fromJSON(p, simplifyVector = TRUE)
}

ss_match <- function(con, stream, hm = NA, feature = "f-0003", alias = "fa-0003", day = ss_day) {
  sampleTidy:::.ct_sample_match(
    con, pending = FALSE, match_feature = feature, alias_uuid = alias,
    sample_date = as.Date(day),
    sample_datetime = if (is.na(hm)) as.POSIXct(NA) else
      as.POSIXct(paste(day, hm), tz = "Australia/Sydney"),
    stream = stream)
}

# A comparable, uuid-free picture of every sample and analysis the pipeline
# wrote at a feature on ss_day (for the order-independence tests).
ss_signature <- function(con, uuid_feature) {
  s <- ss_samples_at(con, uuid_feature)
  sig <- sprintf("%s | %s | %s",
                 ifelse(is.na(s$datetime), "NA", format(s$datetime, "%Y-%m-%d %H:%M:%S", tz = "UTC")),
                 s$project, s$labs)
  sort(sig)
}

# ================================================================================
# Stream attribution (DESIGN 5.1, 5.2)
# ================================================================================

test_that("[5.1] an analysis's stream comes from its lab_method: gas analyte -> 'gas', else the organisation", {
  db <- ss_db()
  withr::defer(DBI::dbDisconnect(db$con, shutdown = TRUE))
  reg <- sampleTidy:::.rc_load_registry(db$con)
  labs <- c("lm-ch4", "lm-h2s", "lm-fph", "lm-dins", "lm-0005", "lm-0001",
            "lm-en67", "lm-legph", "lm-intph", "lm-nullorg")
  expect_identical(
    sampleTidy:::.rc_lab_stream(labs, reg),
    c("gas", "gas", "ACIRL", "ACIRL", "ACIRL", "ALS", "ALS", "legacy", "Internal", NA_character_)
  )
})

test_that("[5.2] an incoming row's stream: resolved lab first; with no lab_method, matrix 'Gas' -> gas, else org", {
  db <- ss_db()
  withr::defer(DBI::dbDisconnect(db$con, shutdown = TRUE))
  reg <- sampleTidy:::.rc_load_registry(db$con)
  rows <- tibble::tibble(
    uuid_lab = c("lm-ch4", "lm-fph", "lm-0001", NA, NA, NA, "lm-0009"),
    uuid_analyte = c("a-ch4", "a-0001", "a-0001", NA, NA, NA, NA),
    matrix_raw = c("WATER", "Gas", "WATER", "Gas", "Water", "WATER", "WATER"),
    org = c("ACIRL", "ACIRL", "ALS", "ACIRL", "ACIRL", "ALS", "ALS")
  )
  expect_identical(
    sampleTidy:::.rc_row_stream(rows, reg),
    c("gas", "ACIRL", "ALS", "gas", "ACIRL", "ALS", "ALS")
  )
})

# ================================================================================
# Matching (DESIGN 5.3 - 5.18): .ct_sample_match(), read-only, never aborts
# ================================================================================

test_that("[5.3] gas row, day holds only an ALS sample -> new (June K.MW01/03/04)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)
  m <- ss_match(con, "gas")
  expect_identical(m$outcome, "new")
  expect_true(is.na(m$uuid))
})

test_that("[5.4] gas row, day holds an ACIRL-field-only sample AND an ALS sample -> new (Sept K.MW03)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "11:10", labs = ss_labs$AF)
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)
  m <- ss_match(con, "gas")
  expect_identical(m$outcome, "new")
})

test_that("[5.5] gas row, day holds a MERGED (ACIRL field + ALS) sample -> new (Sept K.MW01)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-merged", hm = "09:25", labs = ss_labs$MERGED)
  expect_identical(ss_match(con, "gas")$outcome, "new")
})

test_that("[5.6] gas row, day holds a timed legacy gas sample -> reuse it (Blaxland probes)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-gas", hm = "11:01", project = "p-gasleg", labs = ss_labs$GAS)
  m <- ss_match(con, "gas")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-gas")
})

test_that("[5.7] field row, day holds a MERGED sample and an ALS-only sample -> reuse the MERGED one", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-merged", hm = "09:25", labs = ss_labs$MERGED)
  ss_sample(con, "s-als2", hm = "13:00", project = "p-es2", labs = ss_labs$ALS)
  m <- ss_match(con, "ACIRL")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-merged")
})

test_that("[5.8] field row, day holds a separate field sample and an ALS sample in one project -> reuse the field one", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "11:10", labs = ss_labs$AF)
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)
  m <- ss_match(con, "ACIRL")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-af")
})

test_that("[5.9] field row, day holds only ALS sample(s), one or three -> new (D3)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-als-a", hm = "09:25", labs = ss_labs$ALS)
  expect_identical(ss_match(con, "ACIRL")$outcome, "new")
  ss_sample(con, "s-als-b", hm = "10:25", project = "p-es2", labs = ss_labs$ALS)
  ss_sample(con, "s-als-c", hm = "11:25", project = "p-0003", labs = ss_labs$ALS)
  expect_identical(ss_match(con, "ACIRL")$outcome, "new")
})

test_that("[5.10] field row, day holds two ACIRL-field-bearing samples -> ambiguous, both uuids, sorted", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # MERGED + MERGED: one visit filed under two ALS orders (inserted in reverse
  # uuid order so storage order and sorted order disagree).
  ss_sample(con, "s-mm-z", hm = "09:25", project = "p-es2", labs = ss_labs$MERGED)
  ss_sample(con, "s-mm-a", hm = "09:25", project = "p-es1", labs = ss_labs$MERGED)
  m <- ss_match(con, "ACIRL")
  expect_identical(m$outcome, "ambiguous")
  expect_true(is.na(m$uuid))
  expect_identical(m$candidates, c("s-mm-a", "s-mm-z"))

  # AF + AF at T.S01: one visit split into two field samples.
  ss_sample(con, "s-ff-2", alias = "fa-0001", hm = "10:00", labs = ss_labs$AF)
  ss_sample(con, "s-ff-1", alias = "fa-0001", hm = "10:40", project = "p-es2", labs = ss_labs$AF)
  m2 <- ss_match(con, "ACIRL", feature = "f-0001", alias = "fa-0001")
  expect_identical(m2$outcome, "ambiguous")
  expect_identical(m2$candidates, c("s-ff-1", "s-ff-2"))
})

test_that("[5.10] the matcher never aborts, whatever the candidate set", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-mm-a", hm = "09:25", project = "p-es1", labs = ss_labs$MERGED)
  ss_sample(con, "s-mm-z", hm = "09:25", project = "p-es2", labs = ss_labs$MERGED)
  expect_no_error(ss_match(con, "ACIRL"))
  expect_no_error(ss_match(con, "ALS"))
  expect_no_error(ss_match(con, "ALS", hm = "09:25"))
})

test_that("[5.11] field row, day holds a gas-only sample -> new (field never joins gas, D1)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-gas", hm = "11:01", project = "p-gasleg", labs = ss_labs$GAS)
  expect_identical(ss_match(con, "ACIRL")$outcome, "new")
})

test_that("[5.12] timed ALS row, day holds a date-only ACIRL field sample -> new (today: reuse)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = NA, naive = TRUE, labs = ss_labs$AF)
  expect_identical(ss_match(con, "ALS", hm = "09:25")$outcome, "new")
})

test_that("[5.13] ALS row, day holds a gas sample -> new", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-gas", hm = "11:01", project = "p-gasleg", labs = ss_labs$GAS)
  expect_identical(ss_match(con, "ALS")$outcome, "new")              # date-only XTAB row
})

test_that("[5.14] ALS row, two ALS samples at the same datetime -> ambiguous (ruling-9 shape, no abort)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-l2", hm = "00:00", project = "p-es2", labs = ss_labs$ALS)
  ss_sample(con, "s-l1", hm = "00:00", project = "p-es1", labs = ss_labs$ALS)
  m <- ss_match(con, "ALS", hm = "00:00")
  expect_identical(m$outcome, "ambiguous")
  expect_identical(m$candidates, c("s-l1", "s-l2"))
  expect_identical(ss_match(con, "ALS")$outcome, "ambiguous")        # date-only too
})

test_that("[5.15] a sample with zero analyses is reused by a row of ANY stream", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-empty", hm = NA, naive = TRUE)
  for (st in c("gas", "ACIRL", "ALS")) {
    m <- ss_match(con, st)
    expect_identical(m$outcome, "reuse", label = st)
    expect_identical(m$uuid, "s-empty", label = st)
  }
})

test_that("[5.16] a neutral (legacy-field-only) sample is reused by neither ACIRL nor ALS rows", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-neutral", hm = NA, naive = TRUE, project = NA_character_, labs = ss_labs$NEUTRAL)
  expect_identical(ss_match(con, "ACIRL")$outcome, "new")
  expect_identical(ss_match(con, "ALS")$outcome, "new")
  expect_identical(ss_match(con, "legacy")$outcome, "reuse")
})

test_that("[5.17] A62 still decides INSIDE the stream: equal -> that one, distinct -> new, NA -> ambiguous", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af-am", hm = "09:00", labs = ss_labs$AF)
  ss_sample(con, "s-af-pm", hm = "14:00", project = "p-es2", labs = ss_labs$AF)
  # an ALS sample at 17:30 is another stream's and must not be the "equal" one
  ss_sample(con, "s-als", hm = "17:30", project = "p-0003", labs = ss_labs$ALS)

  m <- ss_match(con, "ACIRL", hm = "14:00")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-af-pm")

  m_new <- ss_match(con, "ACIRL", hm = "16:00")
  expect_identical(m_new$outcome, "new")

  m_na <- ss_match(con, "ACIRL")
  expect_identical(m_na$outcome, "ambiguous")
  expect_identical(m_na$candidates, c("s-af-am", "s-af-pm"))
})

test_that("[5.18] cross-stream instant: a timed ALS row whose only same-day sample is ACIRL at that instant -> withheld", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "09:25", labs = ss_labs$AF)
  m <- ss_match(con, "ALS", hm = "09:25")
  expect_identical(m$outcome, "cross_stream_instant")
  expect_true(is.na(m$uuid))
  expect_identical(m$candidates, "s-af")
  # a date-only ALS row cannot collide on an instant: plain new
  expect_identical(ss_match(con, "ALS")$outcome, "new")
})

# ================================================================================
# Matching end to end (DESIGN 2.2 concrete cases, through reconcile + commit)
# ================================================================================

test_that("[5.3 e2e] June K.MW01: a gas file on an ALS-only day makes its own gas sample in the gas campaign", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)

  run <- ss_gas_event(con, ss_gas(0.5))
  ss_expect_ok(run)

  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_identical(ss_labs_of(con, "s-als"), sort(ss_labs$ALS))     # untouched
  gas <- s[s$uuid != "s-als", , drop = FALSE]
  expect_identical(gas$labs, "lm-ch4")
  expect_identical(gas$project_root, "Monthly gas monitoring")
})

test_that("[5.4 e2e] Sept K.MW03: the gas file COMMITS (no abort) and the bore reading gets its own gas sample", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "11:10", labs = ss_labs$AF)
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)

  run <- ss_gas_event(con, dplyr::bind_rows(ss_gas(0.5), ss_gas(0.2, feature = "T.S02")))
  ss_expect_ok(run)

  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 3)
  expect_identical(ss_labs_of(con, "s-af"), sort(ss_labs$AF))
  expect_identical(ss_labs_of(con, "s-als"), sort(ss_labs$ALS))
  gas <- s[!s$uuid %in% c("s-af", "s-als"), , drop = FALSE]
  expect_identical(gas$labs, "lm-ch4")
  expect_false(identical(gas$project, "ES2527711"))
  expect_identical(gas$project_root, "Monthly gas monitoring")
  # and the rest of the file landed too
  expect_equal(nrow(ss_samples_at(con, "f-0002")), 1)
  st <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(run$hash))$state
  expect_true(st %in% c("committed", "archived"))
})

test_that("[5.5 e2e] Sept K.MW01: gas on a MERGED legacy visit does not join the merged (ALS-order) sample", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-merged", hm = "09:25", labs = ss_labs$MERGED)

  run <- ss_gas_event(con, ss_gas(0.5))
  ss_expect_ok(run)
  expect_identical(ss_labs_of(con, "s-merged"), sort(ss_labs$MERGED))
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_identical(s$project_root[s$uuid != "s-merged"], "Monthly gas monitoring")
})

test_that("[5.6 e2e] Blaxland probes: a gas re-ingest reuses the legacy gas sample and stays already_present", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-gas", hm = "11:01", project = "p-gasleg", labs = "lm-ch4", values = 0.005)

  run <- ss_gas_event(con, ss_gas(0.5), report_no = "2400-9900-08-01")
  ss_expect_ok(run)
  expect_equal(nrow(run$resolved$clean), 0)
  expect_true("already_present" %in% run$resolved$skipped$reason)
  expect_identical(ss_samples_at(con, "f-0003")$uuid, "s-gas")
})

test_that("[5.8 e2e] Sept K.MW03 field-sheet re-ingest: joins the separate field sample, no abort", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "11:10", labs = "lm-fph", values = 7.1)
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)

  run <- ss_field_event(con, dplyr::bind_rows(ss_field("pH", 7.1), ss_field("EC", 0.9)))
  ss_expect_ok(run)
  expect_true("already_present" %in% run$resolved$skipped$reason)   # pH
  expect_identical(ss_labs_of(con, "s-af"), c("lm-fec", "lm-fph"))  # EC joined the field sample
  expect_identical(ss_labs_of(con, "s-als"), sort(ss_labs$ALS))
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 2)
})

test_that("[5.9 e2e] D3: a field sheet on an ALS-only day makes a separate ACIRL sample", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)

  run <- ss_field_event(con, ss_field("pH", 7.1))
  ss_expect_ok(run)
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_identical(ss_labs_of(con, "s-als"), sort(ss_labs$ALS))
  expect_identical(s$labs[s$uuid != "s-als"], "lm-fph")
})

test_that("[5.12 e2e] a timed ESdat file after a date-only pipeline field sample makes its own ALS sample", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = NA, naive = TRUE, labs = ss_labs$AF)

  run <- ss_als_event(con, ss_als("pH", 7.2))
  ss_expect_ok(run)
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_identical(ss_labs_of(con, "s-af"), sort(ss_labs$AF))
  expect_identical(s$labs[s$uuid != "s-af"], "lm-0001")
})

test_that("[5.18 e2e] cross-stream instant: withheld for review, no sample created, no ux_sample_identity error", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # A80 files the ACIRL field sample under the ALS order, so the ALS sample a
  # naive "new" would create shares (alias, datetime, project) with it.
  ss_sample(con, "s-af", hm = "09:25", project = "p-es1", labs = ss_labs$AF)
  n_before <- nrow(DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"'))

  run <- ss_als_event(con, dplyr::bind_rows(ss_als("pH", 7.2),
                                            ss_als("pH", 7.4, feature = "T.S02")))
  ss_expect_ok(run)
  expect_identical(ss_labs_of(con, "s-af"), sort(ss_labs$AF))       # no ALS row merged in
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 1)
  expect_equal(nrow(ss_samples_at(con, "f-0002")), 1)               # the other row committed
  expect_equal(nrow(DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"')), n_before + 1)

  rq <- ss_reviews(con)
  expect_equal(nrow(rq), 1)
  expect_identical(rq$subkind, "cross_stream_instant")
  p <- ss_payload(rq$payload)
  expect_identical(p$candidate_samples, "s-af")
  expect_equal(NROW(p$rows), 1)
})

# ================================================================================
# Order independence (DESIGN 5.19 - 5.21)
# ================================================================================

test_that("[5.19] gas-then-field and field-then-gas leave the same state: 2 samples, gas campaign + A80 project", {
  run_order <- function(first) {
    db <- ss_db(env = parent.frame())
    con <- db$con
    gas <- function() ss_gas_event(con, ss_gas(0.5))
    fld <- function() ss_field_event(con, dplyr::bind_rows(ss_field("pH", 7.1), ss_field("EC", 0.9)))
    if (first == "gas") { r1 <- gas(); r2 <- fld() } else { r1 <- fld(); r2 <- gas() }
    ss_expect_ok(r1); ss_expect_ok(r2)
    sig <- ss_signature(con, "f-0003")
    s <- ss_samples_at(con, "f-0003")
    DBI::dbDisconnect(con, shutdown = TRUE)
    list(sig = sig, s = s)
  }
  a <- run_order("gas")
  b <- run_order("field")
  expect_equal(nrow(a$s), 2)
  expect_identical(a$sig, b$sig)
  gas_a <- a$s[a$s$labs == "lm-ch4", , drop = FALSE]
  fld_a <- a$s[a$s$labs == "lm-fec+lm-fph", , drop = FALSE]
  expect_equal(nrow(gas_a), 1)
  expect_equal(nrow(fld_a), 1)
  expect_identical(gas_a$project_root, "Monthly gas monitoring")
  expect_identical(fld_a$project, "ES2527711")                       # A80: the cited ALS order
})

test_that("[5.20] field-then-ESdat and ESdat-then-field leave the same state: 2 samples", {
  run_order <- function(first) {
    db <- ss_db(env = parent.frame())
    con <- db$con
    als <- function() ss_als_event(con, dplyr::bind_rows(ss_als("pH", 7.2), ss_als("EC", 900)))
    fld <- function() ss_field_event(con, dplyr::bind_rows(ss_field("pH", 7.1), ss_field("EC", 0.9)))
    if (first == "als") { r1 <- als(); r2 <- fld() } else { r1 <- fld(); r2 <- als() }
    ss_expect_ok(r1); ss_expect_ok(r2)
    sig <- ss_signature(con, "f-0003")
    DBI::dbDisconnect(con, shutdown = TRUE)
    sig
  }
  a <- run_order("als")
  b <- run_order("field")
  expect_length(a, 2)
  expect_identical(a, b)
})

test_that("[5.21] re-running gas, field and ESdat files makes 0 new samples: every row already_present", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  gas_rows <- ss_gas(0.5)
  fld_rows <- dplyr::bind_rows(ss_field("pH", 7.1), ss_field("EC", 0.9))
  als_rows <- dplyr::bind_rows(ss_als("pH", 7.2), ss_als("EC", 900))
  ss_expect_ok(ss_gas_event(con, gas_rows))
  ss_expect_ok(ss_field_event(con, fld_rows))
  ss_expect_ok(ss_als_event(con, als_rows))
  before <- ss_signature(con, "f-0003")
  expect_length(before, 3)

  # re-downloads: same rows, new file bytes (so a new hash)
  r_gas <- ss_gas_event(con, gas_rows, tag = "again-gas")
  r_fld <- ss_field_event(con, fld_rows, tag = "again-fld")
  r_als <- ss_als_event(con, als_rows, tag = "again-als")
  for (r in list(r_gas, r_fld, r_als)) {
    ss_expect_ok(r)
    expect_equal(nrow(r$resolved$clean), 0)
    expect_true(all(r$resolved$skipped$reason == "already_present"))
  }
  expect_identical(ss_signature(con, "f-0003"), before)
  expect_equal(nrow(ss_reviews(con)), 0)
})

# ================================================================================
# Review path (DESIGN 5.22 - 5.25)
# ================================================================================

# A MERGED+MERGED day at T.MW01 (one visit under two ALS orders, field readings
# copied into both) plus nothing at T.S02. Returns a field file's rows: pH
# already present (on both), EC new at the ambiguous T.MW01 day, pH at T.S02.
ss_ambiguous_day <- function(con) {
  ss_sample(con, "s-mm-z", hm = "09:25", project = "p-es2", labs = c("lm-fph", "lm-0001"),
            values = c(7.1, 7.3))
  ss_sample(con, "s-mm-a", hm = "09:25", project = "p-es1", labs = c("lm-fph", "lm-0001"),
            values = c(7.1, 7.3))
  dplyr::bind_rows(
    ss_field("pH", 7.1),                   # already present (on both)
    ss_field("EC", 0.9),                   # new at an ambiguous feature-day
    ss_field("pH", 6.8, feature = "T.S02") # unambiguous
  )
}

test_that("[5.22] ambiguous rows -> ONE sample_ambiguous item with the candidates; the rest of the file commits", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  rows <- ss_ambiguous_day(con)
  run <- ss_field_event(con, rows)
  ss_expect_ok(run)

  # already-present rows are still skipped on an ambiguous day
  ap <- run$resolved$skipped[run$resolved$skipped$reason == "already_present", , drop = FALSE]
  expect_equal(nrow(ap), 1)

  rq <- ss_reviews(con)
  expect_equal(nrow(rq), 1)
  expect_identical(rq$status, "open")
  expect_false(identical(rq$subkind, "cross_stream_instant"))
  p <- ss_payload(rq$payload)
  expect_identical(p$candidate_samples, c("s-mm-a", "s-mm-z"))
  expect_equal(NROW(p$rows), 1)
  expect_identical(as.character(p$rows$analyte_raw), "Field EC")

  # nothing landed on either candidate; the T.S02 row committed
  expect_identical(ss_labs_of(con, "s-mm-a"), c("lm-0001", "lm-fph"))
  expect_identical(ss_labs_of(con, "s-mm-z"), c("lm-0001", "lm-fph"))
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 2)
  s02 <- ss_samples_at(con, "f-0002")
  expect_identical(s02$labs, "lm-fph")
  st <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(run$hash))$state
  expect_false(identical(st, "failed"))
  expect_true(st %in% c("archived", "needs_review", "committed"))
})

test_that("[5.22] the item is ONE per (feature, day, stream): two new rows at one ambiguous feature-day fold", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_ambiguous_day(con)
  run <- ss_field_event(con, dplyr::bind_rows(ss_field("EC", 0.9), ss_field("SWL", 3.2)))
  ss_expect_ok(run)
  rq <- ss_reviews(con)
  expect_equal(nrow(rq), 1)
  p <- ss_payload(rq$payload)
  expect_setequal(as.character(p$rows$analyte_raw), c("Field EC", "Standing Water Level"))
  expect_identical(p$candidate_samples, c("s-mm-a", "s-mm-z"))
})

test_that("[5.22] D2: an ALS (XTAB, date-only) row at a two-ALS-sample day is reviewed, not a whole-file abort", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-l1", hm = "00:00", project = "p-es1", labs = "lm-0003")
  ss_sample(con, "s-l2", hm = "00:00", project = "p-es2", labs = "lm-0003")
  run <- ss_als_event(con, dplyr::bind_rows(
    ss_als("pH", 7.9, when = "04/09/2025"),
    ss_als("pH", 7.4, feature = "T.S02", when = "04/09/2025")
  ), wo = "ES2527800")
  ss_expect_ok(run)
  rq <- ss_reviews(con)
  expect_equal(nrow(rq), 1)
  expect_identical(ss_payload(rq$payload)$candidate_samples, c("s-l1", "s-l2"))
  expect_identical(ss_labs_of(con, "s-l1"), "lm-0003")
  expect_identical(ss_labs_of(con, "s-l2"), "lm-0003")
  expect_identical(ss_samples_at(con, "f-0002")$labs, "lm-0001")
})

test_that("[5.23] the same file re-ingested opens no second identical sample_ambiguous item (A88 fold)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_ambiguous_day(con)
  # only the ambiguous row: nothing commits, so the file stays non-terminal
  # and the same bytes (same hash) can come round again
  run <- ss_field_event(con, ss_field("EC", 0.9))
  ss_expect_ok(run)
  expect_equal(nrow(ss_reviews(con)), 1)
  st <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?", params = list(run$hash))$state
  expect_identical(st, "needs_review")

  again <- tryCatch({
    commit_event(run$event, reconcile_event(run$event, con), con)
    NULL
  }, error = function(e) e)
  expect_null(again, label = if (is.null(again)) "" else conditionMessage(again))
  expect_equal(nrow(ss_reviews(con)), 1)
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 2)
})

test_that("[5.24] release_review(overrides = list(sample = <candidate>)) attaches the rows to that sample", {
  db <- ss_db(); con <- db$con
  rows <- ss_ambiguous_day(con)
  run <- ss_field_event(con, rows)
  ss_expect_ok(run)
  rq <- ss_reviews(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_equal(nrow(rq), 1)

  sampleTidy::release_review(rq$uuid[[1]], overrides = list(sample = "s-mm-z"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_identical(ss_labs_of(con, "s-mm-z"), c("lm-0001", "lm-fec", "lm-fph"))
  expect_identical(ss_labs_of(con, "s-mm-a"), c("lm-0001", "lm-fph"))
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 2)
  expect_identical(ss_reviews(con)$status, "resolved")
})

test_that("[5.24] release_review(overrides = list(sample = 'new')) creates one new sample for the rows", {
  db <- ss_db(); con <- db$con
  rows <- ss_ambiguous_day(con)
  ss_expect_ok(ss_field_event(con, rows))
  rq <- ss_reviews(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_equal(nrow(rq), 1)

  sampleTidy::release_review(rq$uuid[[1]], overrides = list(sample = "new"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 3)
  expect_identical(s$labs[!s$uuid %in% c("s-mm-a", "s-mm-z")], "lm-fec")
  expect_identical(ss_labs_of(con, "s-mm-a"), c("lm-0001", "lm-fph"))
  expect_identical(ss_labs_of(con, "s-mm-z"), c("lm-0001", "lm-fph"))
})

test_that("[5.24] release_review() refuses a sample uuid outside the item's candidates; the item stays open", {
  db <- ss_db(); con <- db$con
  rows <- ss_ambiguous_day(con)
  ss_sample(con, "s-elsewhere", alias = "fa-0001", hm = "09:00", labs = ss_labs$AF)
  ss_expect_ok(ss_field_event(con, rows))
  rq <- ss_reviews(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_equal(nrow(rq), 1)

  expect_error(
    sampleTidy::release_review(rq$uuid[[1]], overrides = list(sample = "s-elsewhere"),
                               resolved_by = "tester", db = db$path),
    class = "sampletidy_error"
  )
  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_identical(ss_reviews(con)$status, "open")
  expect_identical(ss_labs_of(con, "s-elsewhere"), sort(ss_labs$AF))
})

test_that("[5.25] .ct_existing_sample_uuid() reached with an ambiguous set still aborts (invariant kept)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-mm-a", hm = "09:25", project = "p-es1", labs = ss_labs$MERGED)
  ss_sample(con, "s-mm-z", hm = "09:25", project = "p-es2", labs = ss_labs$MERGED)
  expect_error(
    sampleTidy:::.ct_existing_sample_uuid(
      con, pending = FALSE, match_feature = "f-0003", alias_uuid = "fa-0003",
      sample_date = as.Date(ss_day), sample_datetime = as.POSIXct(NA)),
    class = "sampletidy_error")
})

# ================================================================================
# Unchanged behaviour (DESIGN 5.26 - 5.30) and already_present across streams
# ================================================================================

test_that("[5.26] 024 shape: a legacy merged visit's field-sheet re-ingest skips what is there and adds EC to it", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # Sydney-midnight legacy date (stored the previous day 14:00 UTC)
  ss_sample(con, "s-merged", hm = "09:25", labs = c("lm-fph", "lm-0001"), values = c(7.1, 7.3))
  n_before <- nrow(DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"'))

  run <- ss_field_event(con, dplyr::bind_rows(ss_field("pH", 7.1), ss_field("EC", 0.9)))
  ss_expect_ok(run)
  expect_identical(run$resolved$skipped$reason, "already_present")
  expect_identical(ss_labs_of(con, "s-merged"), c("lm-0001", "lm-fec", "lm-fph"))
  expect_equal(nrow(DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"')), n_before)
})

test_that("[5.27] A79: an ALS row committed to its OWN sample still deletes the ACIRL transcription twin", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # a date-only ACIRL sample holding a transcription of the ALS pH (lm-0005,
  # ACIRL, NULL method) and a field reading
  ss_sample(con, "s-acirl", hm = NA, naive = TRUE, labs = c("lm-0005", "lm-fec"), values = c(7.3, 0.9))
  run <- ss_als_event(con, ss_als("pH", 7.2))
  ss_expect_ok(run)
  # A79 unchanged: the transcription is gone
  expect_identical(ss_labs_of(con, "s-acirl"), "lm-fec")
  # A91: the ALS result sits on its own ALS sample, not on the ACIRL one
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_identical(s$labs[s$uuid != "s-acirl"], "lm-0001")
})

test_that("[5.28] dust: a gauge re-ingest with date_start reuses the dust sample exactly as today", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-dust", alias = "fa-0001", date = "2024-07-02", project = "p-dust",
            labs = "lm-dins", values = 1.53, date_start = "2024-06-01")
  dust <- function(analyte, value, ref) ss_row(
    source_ref = ref, work_order = "2400-7401-07", org = "ACIRL", adapter = "acirl_field_xlsx/1",
    lab_sample_id = "T.S01", feature_raw = "T.S01", analyte_raw = analyte,
    method_raw = NA_character_, total_or_filtered = NA_character_, units_raw = "g/m2/month",
    value_raw = format(value), value_num = value, sample_datetime_raw = "02/07/2024",
    matrix_raw = "Dust", sample_date_start_raw = "01/06/2024")
  run <- ss_field_event(con, dplyr::bind_rows(dust("INSOLUBLE SOLIDS", 1.53, "d1"),
                                              dust("*COMBUSTIBLE MATTER", 0.33, "d2")),
                        report_no = "2400-7401-07", cited = character(0))
  ss_expect_ok(run)
  expect_identical(run$resolved$skipped$reason, "already_present")
  s <- ss_samples_at(con, "f-0001", day = "2024-07-02")
  expect_identical(s$uuid, "s-dust")
  expect_identical(s$labs, "lm-dcom+lm-dins")
})

test_that("[5.29] the F.10 guard's .ct_unmatched_clean_rows() uses the stream-aware matcher and never aborts", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-als", hm = "09:25", labs = ss_labs$ALS)                       # T.MW01
  ss_sample(con, "s-l1", alias = "fa-0001", hm = "00:00", project = "p-es1", labs = "lm-0003")
  ss_sample(con, "s-l2", alias = "fa-0001", hm = "00:00", project = "p-es2", labs = "lm-0003")
  clean <- dplyr::bind_rows(
    # 1: a gas row on T.MW01 -> no gas sample there -> unmatched (today: matched)
    ss_row(uuid_feature = "f-0003", uuid_feature_alias = NA_character_, feature_pending = FALSE,
           uuid_lab = "lm-ch4", uuid_analyte = "a-ch4", org = "ACIRL", matrix_raw = "Gas",
           sample_date = as.Date(ss_day), sample_datetime = as.POSIXct(NA)),
    # 2: an ALS row on T.MW01 at the ALS sample's own instant -> matched
    ss_row(uuid_feature = "f-0003", uuid_feature_alias = NA_character_, feature_pending = FALSE,
           uuid_lab = "lm-0001", uuid_analyte = "a-0001",
           sample_date = as.Date(ss_day),
           sample_datetime = as.POSIXct(paste(ss_day, "09:25"), tz = "Australia/Sydney")),
    # 3: an ALS date-only row on T.S01 where two ALS samples tie -> no abort
    ss_row(uuid_feature = "f-0001", uuid_feature_alias = NA_character_, feature_pending = FALSE,
           uuid_lab = "lm-0001", uuid_analyte = "a-0001",
           sample_date = as.Date(ss_day), sample_datetime = as.POSIXct(NA))
  )
  clean$supersedes <- NA_character_
  got <- NULL
  expect_no_error(got <- sampleTidy:::.ct_unmatched_clean_rows(con, clean))
  expect_true(1L %in% got)
  expect_false(2L %in% got)
})

test_that("[5.30] within one event, same-tuple rows share one sample, and the tuple key includes the stream", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  src <- withr::local_tempdir()
  path <- file.path(src, "2400-9905-09 mixed WMF.xlsx")
  writeLines("a91 mixed", path)
  hash <- hash_file(path)
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
                       VALUES (?, ?, ?, 'reconciled', NULL, 0)",
                 params = list(hash, basename(path), path))
  mk <- function(ref, lab, analyte, matrix) {
    r <- ss_row(source_hash = hash, source_ref = ref, work_order = "2400-9905-09", org = "ACIRL",
                adapter = "acirl_field_xlsx/1", matrix_raw = matrix,
                uuid_feature = "f-0003", uuid_lab = lab, uuid_analyte = analyte,
                value_converted = 1, rl_converted = NA_real_, quantified = TRUE,
                sample_date = as.Date(ss_day), sample_datetime = as.POSIXct(NA),
                supersedes = NA_character_)
    r
  }
  clean <- dplyr::bind_rows(
    mk("c1", "lm-fph", "a-0001", "Water"),
    mk("c2", "lm-fec", "a-0003", "Water"),
    mk("c3", "lm-ch4", "a-ch4", "Gas")
  )
  ev <- list(
    work_order = NA_character_, orphan = TRUE, results = clean,
    samples = tibble::tibble(sample_datetime_raw = "04/09/2025"),
    files = tibble::tibble(hash = hash, kept = TRUE),
    report = list(sources = stats::setNames(list(list(
      hash = hash, filename = basename(path), report_no = "2400-9905-09",
      als_work_orders = character(0), feature_aliases = list(), als_candidates = list()
    )), hash))
  )
  commit_event(ev, list(clean = clean, review = tibble::tibble(), skipped = tibble::tibble(),
                        counts = c(clean = 3L)), con)
  s <- ss_samples_at(con, "f-0003")
  expect_equal(nrow(s), 2)
  expect_setequal(s$labs, c("lm-fec+lm-fph", "lm-ch4"))
})

test_that("already_present across streams: a twin on a MERGED sample is found whatever else the day holds", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-merged", hm = "09:25", labs = c("lm-fph", "lm-0001"), values = c(7.1, 7.3))
  ss_sample(con, "s-af", hm = "11:10", project = "p-es2", labs = "lm-fec", values = 0.9)
  ss_sample(con, "s-gas", hm = "11:01", project = "p-gasleg", labs = "lm-ch4", values = 0.005)

  r_als <- ss_als_event(con, ss_als("pH", 7.3, when = "04/09/2025"), wo = "ES2527711")
  ss_expect_ok(r_als)
  expect_identical(r_als$resolved$skipped$reason, "already_present")
  expect_identical(r_als$resolved$skipped$existing_uuid, "an-s-merged-lm-0001")

  r_gas <- ss_gas_event(con, ss_gas(0.5), report_no = "2400-9900-08-01")
  ss_expect_ok(r_gas)
  expect_identical(r_gas$resolved$skipped$reason, "already_present")

  expect_equal(nrow(ss_samples_at(con, "f-0003")), 3)
  expect_equal(nrow(ss_reviews(con)), 0)
})

# ================================================================================
# C1 - legacy placeholder datetimes (11:00 / 11:01 Sydney) are not "provably
# distinct" within the SAME work order. Spec: C1-placeholder-datetime.md.
# ================================================================================

c1_match <- function(con, hm, wo, stream = "ALS", day = ss_day, with_wo = TRUE) {
  args <- list(con, pending = FALSE, match_feature = "f-0003", alias_uuid = NA,
               sample_date = as.Date(day),
               sample_datetime = as.POSIXct(ss_utc(day, hm), tz = "UTC"),
               stream = stream)
  # Pass work_orders only once the argument exists, so tests fail on the
  # BEHAVIOUR (outcome) rather than on an "unused argument" error.
  if (with_wo && "work_orders" %in% names(formals(sampleTidy:::.ct_sample_match))) args$work_orders <- wo
  do.call(sampleTidy:::.ct_sample_match, args)
}

test_that("[C1.1] .rc_placeholder_datetime(): Sydney 11:00 / 11:01 are placeholders, DST-aware; nothing else", {
  f <- sampleTidy:::.rc_placeholder_datetime
  utc <- function(d, hm) as.POSIXct(ss_utc(d, hm), tz = "UTC")
  expect_true(f(utc("2025-07-10", "11:00")))
  expect_true(f(utc("2025-01-10", "11:00")))
  expect_true(f(utc("2025-01-10", "11:01")))
  expect_false(f(utc("2025-07-10", "10:00")))
  expect_false(f(utc("2025-07-10", "11:02")))
  expect_false(f(utc("2025-07-10", "11:00:30")))
  expect_false(f(as.POSIXct(NA)))
  # numeric epoch seconds, vectorised, same length
  x <- c(as.numeric(utc("2025-07-10", "11:00")), as.numeric(utc("2025-07-10", "10:00")), NA)
  expect_identical(f(x), c(TRUE, FALSE, FALSE))
})

test_that("[C1.2] same-WO placeholder candidate is reused, not provably distinct", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = ss_labs$ALS)
  m <- c1_match(con, "09:25", "ES2527711")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-leg")
})

test_that("[C1.3] the 11:01 lab-twin placeholder clock also reuses", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:01", project = "p-es1", labs = ss_labs$ALS)
  m <- c1_match(con, "09:25", "ES2527711")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-leg")
})

test_that("[C1.4] a placeholder in a DIFFERENT work order stays provably distinct", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es2", labs = ss_labs$ALS)
  expect_identical(c1_match(con, "09:25", "ES2527711")$outcome, "new")
})

test_that("[C1.5] a non-placeholder clock in the same work order stays new", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-ten", hm = "10:00", project = "p-es1", labs = ss_labs$ALS)
  ss_sample(con, "s-1102", hm = "11:02", project = "p-es1", labs = ss_labs$ALS)
  expect_identical(c1_match(con, "09:25", "ES2527711")$outcome, "new")
})

test_that("[C1.6] default work_orders reproduces today's behaviour", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = ss_labs$ALS)
  expect_identical(c1_match(con, "09:25", NULL, with_wo = FALSE)$outcome, "new")
  expect_identical(c1_match(con, "09:25", character(0))$outcome, "new")
})

test_that("[C1.7] control: exact instant still wins against a same-WO 11:00 placeholder", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = ss_labs$ALS)
  m <- c1_match(con, "11:00", "ES2527711")
  expect_identical(m$outcome, "reuse")
  expect_identical(m$uuid, "s-leg")
})

test_that("[C1.8] mixed set: real 10:30 + placeholder 11:00 in the same WO", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-real", hm = "10:30", project = "p-es1", labs = ss_labs$ALS)
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = ss_labs$ALS)
  m1 <- c1_match(con, "10:30", "ES2527711")
  expect_identical(m1$outcome, "reuse")
  expect_identical(m1$uuid, "s-real")
  m2 <- c1_match(con, "13:30", "ES2527711")
  expect_identical(m2$outcome, "ambiguous")
  expect_identical(m2$candidates, c("s-leg", "s-real"))
})

test_that("[C1.9] stream scoping happens first: an ACIRL-field-only 11:00 sample is not an ALS candidate", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-af", hm = "11:00", project = "p-es1", labs = ss_labs$AF)
  expect_identical(c1_match(con, "09:25", "ES2527711", stream = "ALS")$outcome, "new")
})

test_that("[C1.10] .rc_find_existing applies the same rule at analysis level", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = "lm-0001", values = 7.2)
  find <- function(wo) sampleTidy:::.rc_find_existing(
    con, "f-0003", NA, FALSE, as.Date(ss_day), as.POSIXct(ss_utc(ss_day, "09:25"), tz = "UTC"),
    "lm-0001",
    incoming = list(value = 7.2, value_chr = NA, quantified = TRUE, value_raw = "7.2"),
    work_orders = wo)
  hit <- find("ES2527711")
  expect_false(is.null(hit))
  expect_equal(nrow(hit), 1)
  expect_identical(hit$analysis_uuid, "an-s-leg-lm-0001")
  expect_null(find("ES2527799"))
})

test_that("[C1.11] end to end: a lab row at 09:25 lands on the same-WO 11:00 legacy sample", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = "lm-0001", values = 7.2)
  n0 <- nrow(ss_samples_at(con, "f-0003"))
  r <- ss_als_event(con, dplyr::bind_rows(
    ss_als("pH", 7.2, when = "04 Sep 2025 09:25"),
    ss_als("EC", 410, when = "04 Sep 2025 09:25")))
  ss_expect_ok(r)
  expect_equal(nrow(ss_samples_at(con, "f-0003")), n0)
  expect_equal(sum(r$resolved$skipped$reason == "already_present"), 1)
  expect_equal(nrow(r$resolved$clean), 1)
  ec <- DBI::dbGetQuery(con, "SELECT uuid_sample FROM analysis WHERE uuid_lab = 'lm-0003'")
  expect_identical(ec$uuid_sample, "s-leg")
  expect_equal(nrow(ss_reviews(con)), 0)
})

test_that("[C1.12] end to end, different work order: a new sample is created (control)", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es2", labs = "lm-0001", values = 7.2)
  r <- ss_als_event(con, dplyr::bind_rows(
    ss_als("pH", 7.2, when = "04 Sep 2025 09:25"),
    ss_als("EC", 410, when = "04 Sep 2025 09:25")))
  ss_expect_ok(r)
  expect_equal(nrow(ss_samples_at(con, "f-0003")), 2)
})

test_that("[C1.13] idempotent: re-running the C1.11 event adds no rows and no samples", {
  db <- ss_db(); con <- db$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ss_sample(con, "s-leg", hm = "11:00", project = "p-es1", labs = "lm-0001", values = 7.2)
  rows <- dplyr::bind_rows(ss_als("pH", 7.2, when = "04 Sep 2025 09:25"),
                           ss_als("EC", 410, when = "04 Sep 2025 09:25"))
  ss_expect_ok(ss_als_event(con, rows, tag = "first"))
  n_s <- nrow(ss_samples_at(con, "f-0003"))
  n_a <- DBI::dbGetQuery(con, "SELECT count(*) n FROM analysis")$n
  r2 <- ss_als_event(con, rows, tag = "second")
  ss_expect_ok(r2)
  expect_equal(nrow(r2$resolved$clean), 0)
  expect_equal(nrow(ss_samples_at(con, "f-0003")), n_s)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM analysis")$n, n_a)
  expect_equal(n_s, 1)
})
