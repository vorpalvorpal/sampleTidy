# tests/testthat/test-report-year-key-c8.R
#
# C8 / TRIAGE D14: key the ACIRL report project by (report number, year).
# Spec: scr/hist/post/D14-SPEC.md, "Required behaviour" 1-7.
#
# ACIRL reuses report numbers across years (2400-7399-04 Apr 2024 / Apr 2026,
# 2400-7430-01 May 2024 / May 2025, 2400-7453-03 Mar 2025 / Mar 2026,
# 2400-7453-03-01 gas Mar 2025 / Mar 2026). Today `project.name = report_no` is
# the only key, so the second year either merges into the first year's report
# (raising duplicate_report_number) or, when its ALS order sits under another
# campaign, cannot be adopted (project_parent_conflict).
#
# Rulings pinned here (coordinator, 2026-10-20):
#   * the year already holding the bare name keeps it - existing projects are
#     NEVER renamed (duckdb 1.4.1 self-FK, Bug D);
#   * a new year gets "<report_no> (<yyyy>)", yyyy = min of the event's
#     sample-date Sydney years;
#   * within one year a different ALS order still raises
#     duplicate_report_number/acirl, as today.
#
# Fixture style follows test-commit.R's A80 block (commit_event() on events
# built the way assembly builds them, seeded temp DB) and test-acirl-gas-e2e.R
# (ingest_dir() on a synthetic gas workbook). The A80 helpers are local to
# test-commit.R, so the ones needed are copied below under a `c8_` prefix.
#
# Year source (spec): the Sydney years of `event$samples$sample_datetime_raw`
# (already C3-overridden by ingest), else the front-page SAMPLE DATE carried
# into `event$report$sources[[h]]$sample_date` (ASSUMED field name and a
# "%d/%m/%Y" string, the gas adapter's `header$sample_date` format).

# ---- local helpers (copies of test-commit.R's) -----------------------------------

c8_clean_row <- function(...) {
  defaults <- list(
    source_hash = "hash-x", source_ref = "row1", work_order = "XX1234567", revision = 0L,
    org = "ALS", adapter = "esdat/1", lab_sample_id = "XX1234567099", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", total_or_filtered = "T", units_raw = "pH Unit",
    value_raw = "6.50", value_num = 6.50, value_chr = NA_character_, below_detection = FALSE,
    rl = NA_real_, lab_qualifier = NA_character_, analysed_date = as.Date("2025-06-10"),
    comments = NA_character_, confidence = 1, sample_datetime_raw = "10 Jun 2025 09:00",
    sampler = NA_character_, matrix_raw = "WATER", parent_sample = NA_character_,
    uuid_feature = "f-0001", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_converted = 6.50, rl_converted = NA_real_,
    sample_date = as.Date("2025-06-10"),
    sample_datetime = as.POSIXct("2025-06-10 09:00:00", tz = "Australia/Sydney"),
    supersedes = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

c8_resolved <- function(clean) {
  list(clean = clean, review = tibble::tibble(), skipped = tibble::tibble(),
       counts = c(new = nrow(clean)))
}

c8_seed_project <- function(con, name, type = "Work order",
                            parent = NA_character_, root = NA_character_) {
  u <- uuid::UUIDgenerate()
  DBI::dbExecute(
    con,
    "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES (?, ?, ?, ?, ?)",
    params = list(u, parent, root, name, type)
  )
  u
}

c8_project <- function(con, name) {
  DBI::dbGetQuery(
    con, "SELECT uuid, uuid_parent, uuid_root, name, type FROM project WHERE name = ?",
    params = list(name)
  )
}

# Every project row named `report_no` or `report_no (yyyy)`.
c8_report_rows <- function(con, report_no) {
  DBI::dbGetQuery(
    con, "SELECT uuid, uuid_parent, uuid_root, name, type FROM project
           WHERE name = ? OR name LIKE ? ORDER BY name",
    params = list(report_no, paste0(report_no, " (%)"))
  )
}

# A legacy-shaped sample (Sydney midnight stored as its UTC instant) under
# `project_uuid` on Sydney day `day`.
c8_seed_sample <- function(con, project_uuid, day, alias = "fa-0001",
                           uuid = uuid::UUIDgenerate()) {
  utc <- format(as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney"),
                tz = "UTC", "%Y-%m-%d %H:%M:%S")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
    VALUES (?, ?, ?, CAST(? AS TIMESTAMP), NULL, NULL, 'ACIRL')",
    params = list(uuid, alias, project_uuid, utc))
  uuid
}

c8_setup <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  db_path <- seed_db(dir = dir)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  withr::local_options(
    list("sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env)),
    .local_envir = env
  )
  list(con = con, src = withr::local_tempdir(.local_envir = env))
}

# An ACIRL event as assembly builds one (orphan, per-hash `sources`), carrying
# its own sample dates in `samples$sample_datetime_raw` (date-only "%d/%m/%Y",
# as the field and gas adapters emit them). `dates = NULL` gives an event with
# no parseable sample date; `front_date` then sets the front-page fallback.
c8_event <- function(con, src_dir, report_no, cited = character(0), tag = "a",
                     dates = "2025-06-10", front_date = NULL, gas = FALSE) {
  path <- file.path(src_dir, sprintf("%s_%s_WMF.xls", report_no, tag))
  writeLines(sprintf("acirl workbook %s %s", report_no, tag), path)
  hash <- hash_file(path)
  DBI::dbExecute(
    con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', NULL, 0)",
    params = list(hash, basename(path), path)
  )
  raw <- if (is.null(dates)) NA_character_ else format(as.Date(dates), "%d/%m/%Y")
  adapter <- if (gas) "acirl_gas_xlsx/1" else "acirl_field_xlsx/1"
  src <- list(
    hash = hash, filename = basename(path), report_no = report_no,
    als_work_orders = cited, feature_aliases = list(), als_candidates = list()
  )
  if (!is.null(front_date)) src$sample_date <- format(as.Date(front_date), "%d/%m/%Y")
  list(
    hash = hash, path = path, dates = dates,
    event = list(
      work_order = NA_character_, orphan = TRUE,
      results = tibble::tibble(source_hash = rep(hash, length(raw)), adapter = adapter),
      samples = tibble::tibble(source_hash = rep(hash, length(raw)), sample_datetime_raw = raw),
      files = tibble::tibble(hash = hash, kept = TRUE),
      report = list(sources = stats::setNames(list(src), hash))
    )
  )
}

# One clean ACIRL row per sample date of `ev` (date-only, report number in
# work_order, as the adapter emits it).
c8_clean <- function(ev, report_no, feature = "T.S01", uuid_feature = "f-0001",
                     dates = ev$dates, gas = FALSE) {
  if (is.null(dates)) dates <- "2025-06-10"
  rows <- lapply(seq_along(dates), function(i) c8_clean_row(
    source_hash = ev$hash, source_ref = paste0("r", i), work_order = report_no,
    org = "ACIRL", adapter = if (gas) "acirl_gas_xlsx/1" else "acirl_field_xlsx/1",
    feature_raw = feature, uuid_feature = uuid_feature,
    sample_datetime_raw = format(as.Date(dates[[i]]), "%d/%m/%Y"),
    sample_date = as.Date(dates[[i]]), sample_datetime = as.POSIXct(NA)
  ))
  dplyr::bind_rows(rows)
}

c8_commit <- function(con, ev, report_no, ...) {
  commit_event(ev$event, c8_resolved(c8_clean(ev, report_no, ...)), con)
}

c8_sample_uuids <- function(con) DBI::dbGetQuery(con, 'SELECT uuid FROM "sample"')$uuid
c8_new_sample_projects <- function(con, before) {
  rows <- DBI::dbGetQuery(con, 'SELECT uuid, uuid_project FROM "sample"')
  unique(rows$uuid_project[!(rows$uuid %in% before)])
}

c8_reviews <- function(con, kind) {
  DBI::dbGetQuery(con, "SELECT kind, subkind, work_order, payload FROM review_queue WHERE kind = ?",
                  params = list(kind))
}

c8_project_changes <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) n FROM change_log WHERE tbl = 'project'")$n
}

# The uuid a `.ct_report_project_key()` result points at, or NA for "create".
# The spec says the helper "returns the project row to use or 'create'"; the
# exact shape of either is not pinned, so this accepts a data.frame row or a
# list carrying `uuid`, and treats anything else as "create".
c8_key_uuid <- function(res) {
  if (is.data.frame(res)) {
    if (nrow(res) >= 1 && "uuid" %in% names(res)) return(as.character(res$uuid[[1]]))
    return(NA_character_)
  }
  if (is.list(res) && !is.null(res$uuid) && length(res$uuid) >= 1 && !is.na(res$uuid[[1]])) {
    return(as.character(res$uuid[[1]]))
  }
  NA_character_
}

# The 2400-7399-04 starting state in live: the Apr 2026 report, a root, with
# its ALS order ES2610538 as a child holding 2026 samples.
c8_seed_2026_report <- function(con, report_no = "2400-7399-04", child = "ES2610538",
                                day = "2026-04-08", type = "ACIRL report") {
  rep <- c8_seed_project(con, report_no, type = type)
  DBI::dbExecute(con, "UPDATE project SET uuid_root = uuid WHERE uuid = ?", params = list(rep))
  kid <- if (is.na(child)) NA_character_ else c8_seed_project(con, child, parent = rep, root = rep)
  c8_seed_sample(con, if (is.na(child)) rep else kid, day)
  list(report = rep, child = kid)
}

# ==============================================================================
# Criterion 1 - the resolution helper, unit level
# ==============================================================================

test_that("C8 helper: no candidate at all -> create", {
  s <- c8_setup()
  res <- .ct_report_project_key(s$con, "2400-7399-04", 2024L)
  expect_false(is.null(res))
  expect_true(is.na(c8_key_uuid(res)))
})

test_that("C8 helper: a bare report whose (child) samples are in another year does not match -> create", {
  s <- c8_setup()
  seeded <- c8_seed_2026_report(s$con)
  expect_true(is.na(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2024L))))
  # ... but the same year matches it, through the CHILD work order's samples.
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2026L)),
                   seeded$report)
})

test_that("C8 helper: a bare report holding its OWN samples matches on their year (gas shape, no child)", {
  s <- c8_setup()
  seeded <- c8_seed_2026_report(s$con, "2400-7453-03-01", child = NA_character_,
                                day = "2025-03-12", type = "Monthly gas monitoring")
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7453-03-01", 2025L)),
                   seeded$report)
  expect_true(is.na(c8_key_uuid(.ct_report_project_key(s$con, "2400-7453-03-01", 2026L))))
})

test_that("C8 helper: a bare report with no samples matches any year", {
  s <- c8_setup()
  rep <- c8_seed_project(s$con, "2400-7538-02", type = "ACIRL report")
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7538-02", 2019L)), rep)
})

test_that("C8 helper: a year-suffixed row matches its year; a year SET intersecting it matches", {
  s <- c8_setup()
  c8_seed_2026_report(s$con)
  y24 <- c8_seed_project(s$con, "2400-7399-04 (2024)", type = "ACIRL report")
  c8_seed_sample(s$con, y24, "2024-04-10")
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2024L)), y24)
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", c(2023L, 2024L))), y24)
  expect_true(is.na(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2025L))))
})

test_that("C8 helper: two matches are resolved deterministically to the BARE name", {
  s <- c8_setup()
  # A bare row with no samples matches every year, and so does `(2024)` for
  # 2024: ambiguous. Inserted suffixed-first so storage order cannot decide.
  y24 <- c8_seed_project(s$con, "2400-7399-04 (2024)", type = "ACIRL report")
  bare <- c8_seed_project(s$con, "2400-7399-04", type = "ACIRL report")
  expect_identical(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2024L)), bare)
})

test_that("C8 helper: only ACIRL report / Monthly gas monitoring rows are candidates", {
  s <- c8_setup()
  c8_seed_project(s$con, "2400-7399-04", type = "Work order")
  c8_seed_project(s$con, "2400-7399-04 (2024)", type = NA_character_)
  expect_true(is.na(c8_key_uuid(.ct_report_project_key(s$con, "2400-7399-04", 2024L))))
})

# ==============================================================================
# Criteria 2/3 - the four measured shapes, through commit_event()
# ==============================================================================

test_that("C8 7399-04: a 2024 report reusing a 2026 number gets its own (2024) project under the order's campaign; no flag", {
  s <- c8_setup()
  con <- s$con
  seeded <- c8_seed_2026_report(con)
  campaign <- c8_seed_project(con, "Monthly monitoring", type = NA_character_)
  DBI::dbExecute(con, "UPDATE project SET uuid_root = uuid WHERE uuid = ?", params = list(campaign))
  es24 <- c8_seed_project(con, "ES2412736", parent = campaign, root = campaign)

  ev <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412736", dates = "2024-04-10")
  before <- c8_sample_uuids(con)
  res <- c8_commit(con, ev, "2400-7399-04")
  expect_false(isTRUE(res$blocked))

  y24 <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(y24), 1)
  expect_identical(y24$type[[1]], "ACIRL report")
  expect_identical(y24$uuid_parent[[1]], campaign)
  expect_identical(y24$uuid_root[[1]], campaign)

  wo <- c8_project(con, "ES2412736")
  expect_identical(wo$uuid[[1]], es24)
  expect_identical(wo$uuid_parent[[1]], y24$uuid[[1]])
  expect_identical(c8_new_sample_projects(con, before), es24)

  # The 2026 report is untouched: same row, same name, same child.
  bare <- c8_project(con, "2400-7399-04")
  expect_equal(nrow(bare), 1)
  expect_identical(bare$uuid[[1]], seeded$report)
  expect_true(is.na(bare$uuid_parent[[1]]))
  expect_identical(c8_project(con, "ES2610538")$uuid_parent[[1]], seeded$report)

  expect_equal(nrow(c8_reviews(con, "duplicate_report_number")), 0)
  expect_equal(nrow(c8_reviews(con, "project_parent_conflict")), 0)
})

test_that("C8 7453-03: a 2026 report reusing a 2025 number (orders under no campaign) -> two report rows, no flag", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7453-03", cited = "ES2506846", tag = "a", dates = "2025-03-12")
  c8_commit(con, ev1, "2400-7453-03")
  ev2 <- c8_event(con, s$src, "2400-7453-03", cited = "ES2608464", tag = "b", dates = "2026-03-11")
  before <- c8_sample_uuids(con)
  res <- c8_commit(con, ev2, "2400-7453-03", feature = "T.S02", uuid_feature = "f-0002")
  expect_false(isTRUE(res$blocked))

  rows <- c8_report_rows(con, "2400-7453-03")
  expect_identical(rows$name, c("2400-7453-03", "2400-7453-03 (2026)"))
  expect_identical(rows$type, c("ACIRL report", "ACIRL report"))

  bare <- rows[rows$name == "2400-7453-03", ]
  y26 <- rows[rows$name == "2400-7453-03 (2026)", ]
  expect_identical(c8_project(con, "ES2506846")$uuid_parent[[1]], bare$uuid[[1]])
  expect_identical(c8_project(con, "ES2608464")$uuid_parent[[1]], y26$uuid[[1]])
  # No campaign anywhere: the new report is its own root.
  expect_true(is.na(y26$uuid_parent[[1]]))
  expect_identical(y26$uuid_root[[1]], y26$uuid[[1]])
  expect_identical(c8_new_sample_projects(con, before), c8_project(con, "ES2608464")$uuid[[1]])

  expect_equal(nrow(c8_reviews(con, "duplicate_report_number")), 0)
  expect_equal(nrow(c8_reviews(con, "project_parent_conflict")), 0)
})

test_that("C8 7430-01: a dust-only (uncited) reuse in a later year files its samples on the (yyyy) report itself", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7430-01", tag = "a", dates = "2024-05-29")
  c8_commit(con, ev1, "2400-7430-01")
  ev2 <- c8_event(con, s$src, "2400-7430-01", tag = "b", dates = "2025-05-27")
  before <- c8_sample_uuids(con)
  c8_commit(con, ev2, "2400-7430-01", feature = "T.S02", uuid_feature = "f-0002")

  y25 <- c8_project(con, "2400-7430-01 (2025)")
  expect_equal(nrow(y25), 1)
  expect_identical(c8_new_sample_projects(con, before), y25$uuid[[1]])
  expect_equal(nrow(c8_project(con, "2400-7430-01")), 1)
})

test_that("C8: the new year's suffix is the MIN of the event's sample years (a Dec/Jan report reusing an older number)", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7454-12-01", tag = "a", dates = "2023-12-06")
  c8_commit(con, ev1, "2400-7454-12-01")
  ev2 <- c8_event(con, s$src, "2400-7454-12-01", tag = "b",
                  dates = c("2024-12-10", "2025-01-05"))
  c8_commit(con, ev2, "2400-7454-12-01", feature = "T.S02", uuid_feature = "f-0002")

  expect_identical(c8_report_rows(con, "2400-7454-12-01")$name,
                   c("2400-7454-12-01", "2400-7454-12-01 (2024)"))
})

test_that("C8: with no parseable sample date the front-page SAMPLE DATE year keys the report", {
  s <- c8_setup()
  con <- s$con
  c8_seed_2026_report(con)
  ev <- c8_event(con, s$src, "2400-7399-04", dates = NULL, front_date = "2024-04-10")
  before <- c8_sample_uuids(con)
  c8_commit(con, ev, "2400-7399-04", dates = "2024-04-10")

  y24 <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(y24), 1)
  expect_identical(c8_new_sample_projects(con, before), y24$uuid[[1]])
})

test_that("C8: the front-page SAMPLE DATE survives assembly into event$report$sources", {
  parsed <- list(h1 = list(
    ir = list(
      results = ir_results(source_hash = "h1", source_ref = "row1", work_order = "2400-7399-04",
                           revision = 0L, org = "ACIRL", adapter = "acirl_field_xlsx/1",
                           lab_sample_id = NA_character_, sample_type = "Normal",
                           feature_raw = "T.S01", analyte_raw = "Field pH",
                           cas_number = NA_character_, method_raw = NA_character_,
                           total_or_filtered = NA_character_, units_raw = "pH",
                           value_raw = "7.1", value_num = 7.1, value_chr = NA_character_,
                           below_detection = FALSE, rl = NA_real_,
                           lab_qualifier = NA_character_, analysed_date = as.Date(NA),
                           comments = NA_character_, confidence = 1),
      samples = ir_samples(source_hash = "h1", source_ref = "row1", work_order = "2400-7399-04",
                           org = "ACIRL", adapter = "acirl_field_xlsx/1",
                           lab_sample_id = NA_character_, feature_raw = "T.S01",
                           sample_datetime_raw = NA_character_, sample_type = "Normal",
                           parent_sample = NA_character_, matrix_raw = "Water",
                           sampler = NA_character_, comments = NA_character_, confidence = 1)
    ),
    report = list(header = list(report_no = "2400-7399-04", sample_date = "10/04/2024"),
                  als_work_orders = "ES2412736"),
    meta = list(filename = "2400-7399-04 April 2024 Monthly Blaxland WMF.xls")
  ))
  src <- assemble_events(parsed)$events[[1]]$report$sources[["h1"]]
  expect_identical(src$sample_date, "10/04/2024")
})

# ==============================================================================
# Criterion 4 - inside one year the duplicate rule is unchanged
# ==============================================================================

test_that("C8: same year, different ALS order (2400-7222-12-05 shape) still raises duplicate_report_number/acirl and makes no (yyyy) row", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7222-12-05", cited = "ES2246801", tag = "a", dates = "2022-12-05")
  c8_commit(con, ev1, "2400-7222-12-05")
  ev2 <- c8_event(con, s$src, "2400-7222-12-05", cited = "ES2246501", tag = "b", dates = "2022-12-07")
  res <- c8_commit(con, ev2, "2400-7222-12-05", feature = "T.S02", uuid_feature = "f-0002")
  expect_false(isTRUE(res$blocked))

  flag <- c8_reviews(con, "duplicate_report_number")
  expect_equal(nrow(flag), 1)
  expect_identical(flag$subkind[[1]], "acirl")
  expect_identical(flag$work_order[[1]], "2400-7222-12-05")
  expect_identical(c8_report_rows(con, "2400-7222-12-05")$name, "2400-7222-12-05")
  rep <- c8_project(con, "2400-7222-12-05")
  kids <- DBI::dbGetQuery(con, "SELECT name FROM project WHERE uuid_parent = ? ORDER BY name",
                          params = list(rep$uuid[[1]]))$name
  expect_identical(kids, c("ES2246501", "ES2246801"))
})

test_that("C8: a different ALS order matched to a (yyyy) report in its own year still raises duplicate_report_number", {
  s <- c8_setup()
  con <- s$con
  c8_seed_2026_report(con)
  ev1 <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412736", tag = "a", dates = "2024-04-10")
  c8_commit(con, ev1, "2400-7399-04")
  ev2 <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412999", tag = "b", dates = "2024-04-12")
  c8_commit(con, ev2, "2400-7399-04", feature = "T.S02", uuid_feature = "f-0002")

  expect_identical(c8_report_rows(con, "2400-7399-04")$name,
                   c("2400-7399-04", "2400-7399-04 (2024)"))
  flag <- c8_reviews(con, "duplicate_report_number")
  expect_equal(nrow(flag), 1)
  expect_identical(flag$subkind[[1]], "acirl")
})

# ==============================================================================
# Criterion 7 - idempotency, archive/commit agreement, order independence
# ==============================================================================

test_that("C8: a re-saved copy of the (2024) report resolves to the same row - no new project, no project change_log churn, no flag", {
  s <- c8_setup()
  con <- s$con
  c8_seed_2026_report(con)
  campaign <- c8_seed_project(con, "Monthly monitoring", type = NA_character_)
  c8_seed_project(con, "ES2412736", parent = campaign, root = campaign)

  ev1 <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412736", tag = "a", dates = "2024-04-10")
  c8_commit(con, ev1, "2400-7399-04")
  y24 <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(y24), 1)
  n_proj <- DBI::dbGetQuery(con, "SELECT count(*) n FROM project")$n
  n_log <- c8_project_changes(con)

  ev2 <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412736", tag = "b", dates = "2024-04-10")
  before <- c8_sample_uuids(con)
  c8_commit(con, ev2, "2400-7399-04", feature = "T.S02", uuid_feature = "f-0002")

  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM project")$n, n_proj)
  expect_equal(c8_project_changes(con), n_log)
  expect_identical(c8_project(con, "2400-7399-04 (2024)")$uuid, y24$uuid)
  expect_identical(c8_new_sample_projects(con, before), c8_project(con, "ES2412736")$uuid[[1]])
  expect_equal(nrow(c8_reviews(con, "duplicate_report_number")), 0)
  expect_equal(nrow(c8_reviews(con, "project_parent_conflict")), 0)
})

test_that("C8: the archive path and the commit path land on the same (yyyy) project", {
  s <- c8_setup()
  con <- s$con
  c8_seed_2026_report(con)
  ev <- c8_event(con, s$src, "2400-7399-04", dates = "2024-04-10")   # uncited: samples on the report
  before <- c8_sample_uuids(con)
  c8_commit(con, ev, "2400-7399-04")

  y24 <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(y24), 1)
  asset <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE hash = ?", params = list(ev$hash))
  expect_equal(nrow(asset), 1)
  expect_identical(asset$uuid_project[[1]], y24$uuid[[1]])
  expect_identical(c8_new_sample_projects(con, before), y24$uuid[[1]])
})

test_that("C8: archive-THEN-commit (the blocked-branch order) resolves to one and the same (yyyy) row", {
  s <- c8_setup()
  con <- s$con
  c8_seed_2026_report(con)
  campaign <- c8_seed_project(con, "Monthly monitoring", type = NA_character_)
  es24 <- c8_seed_project(con, "ES2412736", parent = campaign, root = campaign)
  ev <- c8_event(con, s$src, "2400-7399-04", cited = "ES2412736", dates = "2024-04-10")

  archive_file(con, ev$path, ev$hash, ev$event)
  asset <- DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE hash = ?", params = list(ev$hash))
  y24 <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(y24), 1)
  expect_identical(asset$uuid_project[[1]], y24$uuid[[1]])
  # The bare 2026 row was not touched by the archive path.
  expect_identical(c8_project(con, "ES2610538")$uuid_parent[[1]],
                   c8_project(con, "2400-7399-04")$uuid[[1]])

  c8_commit(con, ev, "2400-7399-04")
  after <- c8_project(con, "2400-7399-04 (2024)")
  expect_equal(nrow(after), 1)
  expect_identical(after$uuid, y24$uuid)
  # The commit completes the row the archive minted (empty parent filled).
  expect_identical(after$uuid_parent[[1]], campaign)
  expect_identical(c8_project(con, "ES2412736")$uuid_parent[[1]], after$uuid[[1]])
  expect_equal(nrow(c8_reviews(con, "project_parent_conflict")), 0)
})

test_that("C8: import order decides the bare name, deterministically - year 2 first gives year 2 the bare name", {
  run <- function(first, second) {
    s <- c8_setup(env = parent.frame())
    con <- s$con
    ea <- c8_event(con, s$src, "2400-7453-03", cited = first$wo, tag = "a", dates = first$date)
    c8_commit(con, ea, "2400-7453-03")
    eb <- c8_event(con, s$src, "2400-7453-03", cited = second$wo, tag = "b", dates = second$date)
    c8_commit(con, eb, "2400-7453-03", feature = "T.S02", uuid_feature = "f-0002")
    rows <- c8_report_rows(con, "2400-7453-03")
    parent_of <- function(wo) {
      p <- c8_project(con, wo)$uuid_parent[[1]]
      rows$name[rows$uuid == p]
    }
    list(names = rows$name,
         y25 = parent_of("ES2506846"), y26 = parent_of("ES2608464"),
         n_dup = nrow(c8_reviews(con, "duplicate_report_number")))
  }
  y25 <- list(wo = "ES2506846", date = "2025-03-12")
  y26 <- list(wo = "ES2608464", date = "2026-03-11")

  forward <- run(y25, y26)
  expect_identical(forward$names, c("2400-7453-03", "2400-7453-03 (2026)"))
  expect_identical(forward$y25, "2400-7453-03")
  expect_identical(forward$y26, "2400-7453-03 (2026)")
  expect_equal(forward$n_dup, 0)

  backward <- run(y26, y25)
  expect_identical(backward$names, c("2400-7453-03", "2400-7453-03 (2025)"))
  expect_identical(backward$y26, "2400-7453-03")
  expect_identical(backward$y25, "2400-7453-03 (2025)")
  expect_equal(backward$n_dup, 0)

  # Deterministic: the same order twice gives the same names.
  expect_identical(run(y26, y25)$names, backward$names)
})

# ==============================================================================
# Criterion 5 - gas (commit level and end to end)
# ==============================================================================

test_that("C8 gas: a Dec/Jan single file (2400-7454-12-01 shape) is ONE report row, and its re-save stays on it", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7454-12-01", tag = "a", gas = TRUE,
                  dates = c("2025-12-10", "2026-01-05"))
  c8_commit(con, ev1, "2400-7454-12-01", gas = TRUE)
  rows <- c8_report_rows(con, "2400-7454-12-01")
  expect_identical(rows$name, "2400-7454-12-01")
  expect_identical(rows$type, "Monthly gas monitoring")

  ev2 <- c8_event(con, s$src, "2400-7454-12-01", tag = "b", gas = TRUE,
                  dates = c("2025-12-10", "2026-01-05"))
  c8_commit(con, ev2, "2400-7454-12-01", feature = "T.S02", uuid_feature = "f-0002", gas = TRUE)
  expect_identical(c8_report_rows(con, "2400-7454-12-01")$uuid, rows$uuid)
  expect_equal(nrow(c8_reviews(con, "duplicate_report_number")), 0)
})

test_that("C8 gas: a Dec/Jan file whose December is already filed under the bare gas report joins it", {
  s <- c8_setup()
  con <- s$con
  seeded <- c8_seed_2026_report(con, "2400-7454-12-01", child = NA_character_,
                                day = "2025-12-10", type = "Monthly gas monitoring")
  ev <- c8_event(con, s$src, "2400-7454-12-01", gas = TRUE, dates = c("2025-12-10", "2026-01-05"))
  before <- c8_sample_uuids(con)
  c8_commit(con, ev, "2400-7454-12-01", feature = "T.S02", uuid_feature = "f-0002", gas = TRUE)
  expect_identical(c8_report_rows(con, "2400-7454-12-01")$uuid, seeded$report)
  expect_identical(c8_new_sample_projects(con, before), seeded$report)
})

test_that("C8 gas: a gas report number reused a year later is a new (yyyy) project, not an acirl_gas flag", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7453-03-01", tag = "a", gas = TRUE, dates = "2025-03-12")
  c8_commit(con, ev1, "2400-7453-03-01", gas = TRUE)
  ev2 <- c8_event(con, s$src, "2400-7453-03-01", tag = "b", gas = TRUE, dates = "2026-03-11")
  before <- c8_sample_uuids(con)
  c8_commit(con, ev2, "2400-7453-03-01", gas = TRUE)

  rows <- c8_report_rows(con, "2400-7453-03-01")
  expect_identical(rows$name, c("2400-7453-03-01", "2400-7453-03-01 (2026)"))
  expect_identical(rows$type, c("Monthly gas monitoring", "Monthly gas monitoring"))
  expect_identical(rows$uuid_parent[[2]], rows$uuid_parent[[1]])   # same campaign
  expect_identical(c8_new_sample_projects(con, before), rows$uuid[[2]])
  expect_equal(nrow(c8_reviews(con, "duplicate_report_number")), 0)
})

test_that("C8 gas: a different day in the SAME year still raises duplicate_report_number/acirl_gas (unchanged)", {
  s <- c8_setup()
  con <- s$con
  ev1 <- c8_event(con, s$src, "2400-7453-03-01", tag = "a", gas = TRUE, dates = "2025-03-12")
  c8_commit(con, ev1, "2400-7453-03-01", gas = TRUE)
  ev2 <- c8_event(con, s$src, "2400-7453-03-01", tag = "b", gas = TRUE, dates = "2025-04-09")
  c8_commit(con, ev2, "2400-7453-03-01", feature = "T.S02", uuid_feature = "f-0002", gas = TRUE)

  expect_identical(c8_report_rows(con, "2400-7453-03-01")$name, "2400-7453-03-01")
  flag <- c8_reviews(con, "duplicate_report_number")
  expect_equal(nrow(flag), 1)
  expect_identical(flag$subkind[[1]], "acirl_gas")
})

# ---- gas end to end (ingest_dir on a synthetic Blaxland-2025 workbook) ----------
#
# gas_db_setup()/gas_add_legacy() are local to test-acirl-gas-e2e.R; trimmed
# copies follow.

c8_gas_features <- c(`f-g182` = "B.G182", `f-g183` = "B.G183", `f-g184` = "B.G184",
                     `f-g185` = "B.G185", `f-g368` = "B.G368", `f-tg179` = "B.TG179",
                     `f-g382` = "B.G382", `f-g383` = "B.G383", `f-g384` = "B.G384")

c8_gas_db <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  i <- 0
  for (u in names(c8_gas_features)) {
    i <- i + 1
    nm <- c8_gas_features[[u]]
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat)
                         VALUES (?, ?, 'B', NULL, 'air', NULL, ?, ?)",
                   params = list(u, nm, 150.6 + i / 1000, -33.7 - i / 1000))
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by)
      VALUES (?, ?, ?, ?, 'self', 0, TRUE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
      params = list(paste0("fa-", sub("^f-", "", u)), u, nm, tolower(nm)))
  }
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-g179-hist', 'f-tg179', 'B.G179', 'b.g179', 'historical_code', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', 'test')")
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS)
                       VALUES ('a-ch4', 'CH4', 'L/L', 1, 'gas', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant)
    VALUES ('lm-ch4', 'a-ch4', 'CH4 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                       VALUES ('p-gascamp', NULL, 'p-gascamp', 'Monthly gas monitoring', NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

# A legacy gas project row (under the campaign) holding one CH4 analysis per
# entry of `values` on Sydney day `day`; `an_prefix` sets the analysis uuids so
# a test controls which is the lowest.
c8_gas_legacy <- function(db_path, project_uuid, name, day, values, an_prefix = "an-leg-",
                          type = "Monthly gas monitoring", parent = "p-gascamp") {
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE uuid = ?", params = list(project_uuid))) == 0) {
    DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                         VALUES (?, ?, ?, ?, ?)",
                   params = list(project_uuid, parent, if (is.na(parent)) project_uuid else parent,
                                 name, type))
  }
  utc <- format(as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney"),
                tz = "UTC", "%Y-%m-%d %H:%M:%S")
  for (u in names(values)) {
    su <- paste0("s-", project_uuid, "-", u)
    DBI::dbExecute(con, "INSERT INTO \"sample\"
      (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
      VALUES (?, ?, ?, CAST(? AS TIMESTAMP), NULL, NULL, 'ACIRL')",
      params = list(su, paste0("fa-", sub("^f-", "", u)), project_uuid, utc))
    v <- values[[u]]
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                         VALUES (?, ?, 'lm-ch4', ?, ?, NULL)",
                   params = list(paste0(an_prefix, u), su, v, v != 0))
  }
  invisible(db_path)
}

c8_gas_workbook <- function(dir, report_no, sample_date, month = "March",
                            g182 = 0, g183 = 0.03) {
  build_gas_blaxland_2025(
    dir, report_no = report_no, sample_date = sample_date,
    filename = sprintf("%s %s %s Monthly Gas Monitoring Blaxland WMF.xlsx",
                       report_no, month, format(as.Date(sample_date), "%Y")),
    l1 = list(list(G182 = g182, G183 = g183)),
    l2 = list(list(G368 = 0)), l2_rows = 8L,
    l3 = list(list(G382 = 0))
  )
}

c8_gas_ingest <- function(db_path, ..., overrides = NULL, env = parent.frame()) {
  input <- withr::local_tempdir(.local_envir = env)
  path <- c8_gas_workbook(input, ...)
  if (is.null(path) || !file.exists(as.character(path))) {
    path <- list.files(input, full.names = TRUE)[[1]]
  }
  if (!is.null(overrides)) {
    csv <- file.path(withr::local_tempdir(.local_envir = env), "overrides.csv")
    utils::write.csv(data.frame(hash = hash_file(path), date_from = overrides[["from"]],
                                date_to = overrides[["to"]], authority = "test",
                                reason = "C8 test", stringsAsFactors = FALSE),
                     csv, row.names = FALSE)
    withr::local_options(list(sampletidy.date_overrides_path = csv), .local_envir = env)
  }
  ingest_dir(input, db = db_path)
}

c8_ro <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

c8_gas_sample_project <- function(con, uuid_feature, day) {
  DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT s.uuid_project FROM \"sample\" s
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      WHERE fa.uuid_feature = ? AND CAST(%s AS VARCHAR) = ?",
    .ct_sydney_day_sql("s.date")), params = list(uuid_feature, day))$uuid_project
}

test_that("C8 gas e2e: Mar 2025 then Mar 2026 workbooks under one report number -> two Monthly gas monitoring rows, no flag", {
  db <- c8_gas_db()
  c8_gas_ingest(db, report_no = "2400-7453-03-01", sample_date = "2025-03-12")
  c8_gas_ingest(db, report_no = "2400-7453-03-01", sample_date = "2026-03-11")
  con <- c8_ro(db)

  rows <- c8_report_rows(con, "2400-7453-03-01")
  expect_identical(rows$name, c("2400-7453-03-01", "2400-7453-03-01 (2026)"))
  expect_identical(rows$type, c("Monthly gas monitoring", "Monthly gas monitoring"))
  expect_identical(rows$uuid_parent, c("p-gascamp", "p-gascamp"))
  expect_identical(c8_gas_sample_project(con, "f-g183", "2025-03-12"), rows$uuid[[1]])
  expect_identical(c8_gas_sample_project(con, "f-g183", "2026-03-11"), rows$uuid[[2]])
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue
                                      WHERE kind = 'duplicate_report_number'")$n, 0)
})

test_that("C8 gas e2e: the live 7453-03-01 shape - legacy Mar 2025 report, new Mar 2026 workbook -> (2026) row; legacy keeps the bare name", {
  db <- c8_gas_db()
  c8_gas_legacy(db, "p-7453", "2400-7453-03-01", "2025-03-12", list(`f-g182` = 0, `f-g183` = 3e-4))
  c8_gas_ingest(db, report_no = "2400-7453-03-01", sample_date = "2026-03-11")
  con <- c8_ro(db)

  rows <- c8_report_rows(con, "2400-7453-03-01")
  expect_identical(rows$name, c("2400-7453-03-01", "2400-7453-03-01 (2026)"))
  expect_identical(rows$uuid[[1]], "p-7453")
  expect_identical(c8_gas_sample_project(con, "f-g183", "2026-03-11"), rows$uuid[[2]])
  expect_identical(c8_gas_sample_project(con, "f-g183", "2025-03-12"), "p-7453")
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue
                                      WHERE kind = 'duplicate_report_number'")$n, 0)
})

test_that("C8 gas e2e: the report year is taken AFTER C3 overrides (a stale 2026 front page overridden to 2025)", {
  db <- c8_gas_db()
  c8_gas_legacy(db, "p-7453", "2400-7453-03-01", "2026-03-11", list(`f-g182` = 0))
  c8_gas_ingest(db, report_no = "2400-7453-03-01", sample_date = "2026-03-25",
                overrides = c(from = "2026-03-25", to = "2025-03-12"))
  con <- c8_ro(db)

  rows <- c8_report_rows(con, "2400-7453-03-01")
  expect_identical(rows$name, c("2400-7453-03-01", "2400-7453-03-01 (2025)"))
  expect_identical(c8_gas_sample_project(con, "f-g183", "2025-03-12"), rows$uuid[[2]])
})

# ==============================================================================
# Criterion 6 - reconcile sees the RESOLVED project name as the row's work order
# ==============================================================================
#
# Observable through the existing-row preference (test-existing-row-preference.R
# rule 2): when two committed analyses match an incoming row and it equals
# neither, the value_conflict names the candidate filed under one of the row's
# own work orders, else the lowest analysis uuid. An ACIRL row's own work order
# is its report project; once the 2025 report is `2400-7453-03-01 (2025)`, a
# row still carrying the bare number matches neither candidate and falls back
# to the lowest uuid - another project's copy.

test_that("C8 criterion 6: a 2025 gas row is compared against its own (2025) report's sample, not the lowest-uuid copy elsewhere", {
  db <- c8_gas_db()
  # The bare number belongs to 2026; the 2025 report already carries its year.
  c8_gas_legacy(db, "p-7453-26", "2400-7453-03-01", "2026-03-11", list(`f-g182` = 0))
  c8_gas_legacy(db, "p-7453-25", "2400-7453-03-01 (2025)", "2025-03-12",
                list(`f-g183` = 2e-4), an_prefix = "an-2-")
  # A second copy of the same reading on the same day under an unrelated
  # project, with the LOWER analysis uuid (today's cand[1]).
  c8_gas_legacy(db, "p-other", "ES2599999", "2025-03-12", list(`f-g183` = 4e-4),
                an_prefix = "an-1-", type = "Work order", parent = NA_character_)

  # Incoming 0.07 % = 7e-4 L/L: equal to neither candidate.
  c8_gas_ingest(db, report_no = "2400-7453-03-01", sample_date = "2025-03-12", g183 = 0.07)
  con <- c8_ro(db)

  # Resolution itself: no new report row, 2025 data on the (2025) project.
  expect_identical(c8_report_rows(con, "2400-7453-03-01")$uuid, c("p-7453-26", "p-7453-25"))

  vc <- DBI::dbGetQuery(con, "SELECT uuid_existing FROM review_queue WHERE kind = 'value_conflict'")
  expect_equal(nrow(vc), 1)
  expect_identical(vc$uuid_existing[[1]], "an-2-f-g183")
})
