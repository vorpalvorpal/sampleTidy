# tests/testthat/test-report-match-by-type.R
#
# Ruling 2026-11-03 (Robin), REPLACING the 2026-08-02 "collisions merge" ruling:
# a report project is matched by NAME AND TYPE.
#
#   * Water/ACIRL events (ALS work orders citing an ACIRL report, ACIRL
#     field/water/dust workbooks, adapter acirl_field_xlsx) match only
#     `ACIRL report` projects.
#   * Gas events (adapter acirl_gas_xlsx) match only `Monthly gas monitoring`
#     projects.
#   * No project of the right type -> one of the right type is created, same
#     parent/campaign rules as before, even though a same-named project of the
#     other type exists. No review is raised merely because the other type
#     shares the name.
#   * Same-type merging is unchanged; the C8 year-key logic runs WITHIN the type.
#   * More than one project of the right type still matches -> the pick is
#     deterministic and independent of row insertion order, and the existing
#     `duplicate_report_number/ambiguous_year` review is still raised.
#
# Fixtures: synthetic report numbers only. Helpers are `rm_`-prefixed copies of
# test-report-year-key-c8.R's `c8_` ones (test files do not share locals).

rm_clean_row <- function(...) {
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

rm_resolved <- function(clean) {
  list(clean = clean, review = tibble::tibble(), skipped = tibble::tibble(),
       counts = c(new = nrow(clean)))
}

rm_seed_project <- function(con, name, type, parent = NA_character_, root = NA_character_,
                            uuid = uuid::UUIDgenerate()) {
  if (is.na(root)) root <- if (is.na(parent)) uuid else parent
  DBI::dbExecute(
    con,
    "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES (?, ?, ?, ?, ?)",
    params = list(uuid, parent, root, name, type)
  )
  uuid
}

rm_seed_sample <- function(con, project_uuid, day, alias = "fa-0001",
                           uuid = uuid::UUIDgenerate()) {
  utc <- format(as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney"),
                tz = "UTC", "%Y-%m-%d %H:%M:%S")
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
    VALUES (?, ?, ?, CAST(? AS TIMESTAMP), NULL, NULL, 'ACIRL')",
    params = list(uuid, alias, project_uuid, utc))
  uuid
}

rm_setup <- function(env = parent.frame()) {
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

rm_event <- function(con, src_dir, report_no, cited = character(0), tag = "a",
                     dates = "2025-06-10", gas = FALSE) {
  path <- file.path(src_dir, sprintf("%s_%s_WMF.xls", report_no, tag))
  writeLines(sprintf("acirl workbook %s %s", report_no, tag), path)
  hash <- hash_file(path)
  DBI::dbExecute(
    con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', NULL, 0)",
    params = list(hash, basename(path), path)
  )
  raw <- format(as.Date(dates), "%d/%m/%Y")
  adapter <- if (gas) "acirl_gas_xlsx/1" else "acirl_field_xlsx/1"
  src <- list(
    hash = hash, filename = basename(path), report_no = report_no,
    als_work_orders = cited, feature_aliases = list(), als_candidates = list()
  )
  list(
    hash = hash, path = path, dates = dates, gas = gas,
    event = list(
      work_order = NA_character_, orphan = TRUE,
      results = tibble::tibble(source_hash = rep(hash, length(raw)), adapter = adapter),
      samples = tibble::tibble(source_hash = rep(hash, length(raw)), sample_datetime_raw = raw),
      files = tibble::tibble(hash = hash, kept = TRUE),
      report = list(sources = stats::setNames(list(src), hash))
    )
  )
}

# Water and gas events sample DIFFERENT features, so a gas row can never be
# mistaken for an already-present water row of the same day (and vice versa).
rm_clean <- function(ev, report_no, feature = if (ev$gas) "T.MW01" else "T.S02",
                     uuid_feature = if (ev$gas) "f-0003" else "f-0002") {
  rows <- lapply(seq_along(ev$dates), function(i) rm_clean_row(
    source_hash = ev$hash, source_ref = paste0("r", i), work_order = report_no,
    org = "ACIRL", adapter = if (ev$gas) "acirl_gas_xlsx/1" else "acirl_field_xlsx/1",
    feature_raw = feature, uuid_feature = uuid_feature,
    sample_datetime_raw = format(as.Date(ev$dates[[i]]), "%d/%m/%Y"),
    sample_date = as.Date(ev$dates[[i]]), sample_datetime = as.POSIXct(NA)
  ))
  dplyr::bind_rows(rows)
}

rm_commit <- function(con, ev, report_no, ...) {
  commit_event(ev$event, rm_resolved(rm_clean(ev, report_no, ...)), con)
}

# Water / gas shorthands: build the event and commit it. Returns the uuids of
# the projects that received NEW samples.
rm_run <- function(s, report_no, gas, cited = character(0), dates = "2025-06-10", tag = "a") {
  ev <- rm_event(s$con, s$src, report_no, cited = cited, tag = tag, dates = dates, gas = gas)
  before <- DBI::dbGetQuery(s$con, 'SELECT uuid FROM "sample"')$uuid
  rm_commit(s$con, ev, report_no)
  rows <- DBI::dbGetQuery(s$con, 'SELECT uuid, uuid_project FROM "sample"')
  unique(rows$uuid_project[!(rows$uuid %in% before)])
}

rm_rows <- function(con, report_no) {
  DBI::dbGetQuery(
    con, "SELECT uuid, uuid_parent, uuid_root, name, type FROM project
           WHERE name = ? OR name LIKE ? ORDER BY type, name, uuid",
    params = list(report_no, paste0(report_no, " (%)"))
  )
}

rm_type_of <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT type FROM project WHERE uuid = ?", params = list(uuid))$type
}

rm_n <- function(con, table) DBI::dbGetQuery(con, sprintf('SELECT count(*) n FROM "%s"', table))$n

rm_dup_reviews <- function(con) {
  DBI::dbGetQuery(
    con, "SELECT kind, subkind FROM review_queue
           WHERE kind IN ('duplicate_report_number', 'project_parent_conflict')"
  )
}

rm_samples_in <- function(con, uuid) {
  DBI::dbGetQuery(con, 'SELECT count(*) n FROM "sample" WHERE uuid_project = ?',
                  params = list(uuid))$n
}

rm_gas_campaign <- function(con) {
  rm_seed_project(con, "Monthly gas monitoring", type = NA_character_)
}

# A gas project X under the gas campaign, holding one sample on `day`.
rm_seed_gas <- function(con, report_no, day = "2025-06-10", name = report_no,
                        uuid = uuid::UUIDgenerate(), campaign = NULL) {
  if (is.null(campaign)) campaign <- rm_gas_campaign(con)
  u <- rm_seed_project(con, name, "Monthly gas monitoring", parent = campaign,
                       root = campaign, uuid = uuid)
  rm_seed_sample(con, u, day)
  u
}

# An ACIRL report X (a root) holding one sample on `day` directly.
rm_seed_acirl <- function(con, report_no, day = "2025-06-10", name = report_no,
                          uuid = uuid::UUIDgenerate()) {
  u <- rm_seed_project(con, name, "ACIRL report", uuid = uuid)
  rm_seed_sample(con, u, day)
  u
}

# ==============================================================================
# 1 - a gas project X exists; a water report X arrives
# ==============================================================================

test_that("1: a water report X citing a new ALS order creates its own 'ACIRL report' X; the gas project is untouched; no review", {
  s <- rm_setup()
  con <- s$con
  campaign <- rm_gas_campaign(con)
  gas <- rm_seed_gas(con, "2400-9990-01", campaign = campaign)
  n_gas_samples <- rm_samples_in(con, gas)

  new_proj <- rm_run(s, "2400-9990-01", gas = FALSE, cited = "ES9990001")

  rows <- rm_rows(con, "2400-9990-01")
  expect_identical(sort(rows$type), c("ACIRL report", "Monthly gas monitoring"))
  acirl <- rows[rows$type == "ACIRL report", ]
  expect_equal(nrow(acirl), 1)
  expect_identical(acirl$name, "2400-9990-01")
  expect_false(identical(acirl$uuid, gas))

  wo <- DBI::dbGetQuery(con, "SELECT uuid, uuid_parent FROM project WHERE name = 'ES9990001'")
  expect_equal(nrow(wo), 1)
  expect_identical(wo$uuid_parent, acirl$uuid)
  expect_identical(new_proj, wo$uuid)

  g <- rows[rows$type == "Monthly gas monitoring", ]
  expect_identical(g$uuid, gas)
  expect_identical(g$uuid_parent, campaign)
  expect_equal(rm_samples_in(con, gas), n_gas_samples)
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE uuid_parent = ?", params = list(gas))), 0)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

test_that("1: a dust-only water report X (no ALS order) files its samples on a new 'ACIRL report', not on the gas project", {
  s <- rm_setup()
  con <- s$con
  gas <- rm_seed_gas(con, "2400-9990-02")
  new_proj <- rm_run(s, "2400-9990-02", gas = FALSE)
  expect_false(identical(new_proj, gas))
  expect_identical(rm_type_of(con, new_proj), "ACIRL report")
  expect_equal(rm_samples_in(con, gas), 1L)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

# ==============================================================================
# 2 - an 'ACIRL report' X exists; a gas workbook X arrives
# ==============================================================================

test_that("2: a gas workbook X creates a 'Monthly gas monitoring' X under the gas campaign; nothing gas attaches to the ACIRL report", {
  s <- rm_setup()
  con <- s$con
  acirl <- rm_seed_project(con, "2400-9990-03", "ACIRL report")
  wo <- rm_seed_project(con, "ES9990003", "Work order", parent = acirl, root = acirl)
  rm_seed_sample(con, wo, "2025-06-10")
  campaign <- rm_gas_campaign(con)

  new_proj <- rm_run(s, "2400-9990-03", gas = TRUE)

  rows <- rm_rows(con, "2400-9990-03")
  gas <- rows[rows$type == "Monthly gas monitoring", ]
  expect_equal(nrow(gas), 1)
  expect_identical(gas$uuid_parent, campaign)
  expect_identical(new_proj, gas$uuid)
  expect_identical(rows[rows$type == "ACIRL report", ]$uuid, acirl)
  # nothing gas on the ACIRL report or its work order
  expect_equal(rm_samples_in(con, acirl), 0L)
  expect_equal(rm_samples_in(con, wo), 1L)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

# ==============================================================================
# 3 - both exist (same name, same year): each event finds its own type,
#     whichever row was inserted first
# ==============================================================================

test_that("3: water finds the ACIRL report and gas finds the gas project, regardless of insertion order", {
  for (acirl_first in c(TRUE, FALSE)) {
    s <- rm_setup()
    con <- s$con
    campaign <- rm_gas_campaign(con)
    if (acirl_first) {
      acirl <- rm_seed_acirl(con, "2400-9990-04")
      gas <- rm_seed_gas(con, "2400-9990-04", campaign = campaign)
    } else {
      gas <- rm_seed_gas(con, "2400-9990-04", campaign = campaign)
      acirl <- rm_seed_acirl(con, "2400-9990-04")
    }
    n_proj <- rm_n(con, "project")
    lab <- if (acirl_first) "acirl first" else "gas first"

    expect_identical(rm_run(s, "2400-9990-04", gas = FALSE, tag = "w"), acirl, info = lab)
    expect_identical(rm_run(s, "2400-9990-04", gas = TRUE, tag = "g"), gas, info = lab)
    expect_equal(rm_n(con, "project"), n_proj, info = lab)
    expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM review_queue")), 0, info = lab)
  }
})

# ==============================================================================
# 4 - same-type merge is unchanged
# ==============================================================================

test_that("4: a second water report X in the same year merges into the existing ACIRL report", {
  s <- rm_setup()
  con <- s$con
  acirl <- rm_seed_acirl(con, "2400-9990-05")
  n_proj <- rm_n(con, "project")
  expect_identical(rm_run(s, "2400-9990-05", gas = FALSE), acirl)
  expect_equal(rm_n(con, "project"), n_proj)
  expect_equal(nrow(rm_rows(con, "2400-9990-05")), 1)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

test_that("4: a re-sent gas workbook X merges into the existing gas project", {
  s <- rm_setup()
  con <- s$con
  gas <- rm_seed_gas(con, "2400-9990-06")
  n_proj <- rm_n(con, "project")
  expect_identical(rm_run(s, "2400-9990-06", gas = TRUE), gas)
  expect_equal(rm_n(con, "project"), n_proj)
  expect_equal(nrow(rm_rows(con, "2400-9990-06")), 1)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

# ==============================================================================
# 5 - the C8 year key runs within the type
# ==============================================================================

test_that("5: gas X (2025) exists, water X for 2026 arrives -> bare 'ACIRL report' X, not 'X (2026)'", {
  s <- rm_setup()
  con <- s$con
  gas <- rm_seed_gas(con, "2400-9990-07", day = "2025-06-10")
  new_proj <- rm_run(s, "2400-9990-07", gas = FALSE, dates = "2026-06-09")
  rows <- rm_rows(con, "2400-9990-07")
  expect_identical(rows$name[rows$type == "ACIRL report"], "2400-9990-07")
  expect_false("2400-9990-07 (2026)" %in% rows$name)
  expect_identical(rm_type_of(con, new_proj), "ACIRL report")
  expect_equal(rm_samples_in(con, gas), 1L)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

test_that("5: ACIRL report X (2025) exists, water X for 2026 arrives -> 'X (2026)' as before, with the gas project of the same name left alone", {
  s <- rm_setup()
  con <- s$con
  acirl <- rm_seed_acirl(con, "2400-9990-08", day = "2025-06-10")
  gas <- rm_seed_gas(con, "2400-9990-08", day = "2025-06-10")
  new_proj <- rm_run(s, "2400-9990-08", gas = FALSE, dates = "2026-06-09")
  rows <- rm_rows(con, "2400-9990-08")
  y26 <- rows[rows$name == "2400-9990-08 (2026)", ]
  expect_equal(nrow(y26), 1)
  expect_identical(y26$type, "ACIRL report")
  expect_identical(new_proj, y26$uuid)
  expect_equal(rm_samples_in(con, acirl), 1L)
  expect_equal(rm_samples_in(con, gas), 1L)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

test_that("5: ACIRL report X (2025) exists, gas X for 2026 arrives -> bare 'Monthly gas monitoring' X (no gas X exists)", {
  s <- rm_setup()
  con <- s$con
  acirl <- rm_seed_acirl(con, "2400-9990-09", day = "2025-06-10")
  new_proj <- rm_run(s, "2400-9990-09", gas = TRUE, dates = "2026-06-09")
  rows <- rm_rows(con, "2400-9990-09")
  expect_identical(rows$name[rows$type == "Monthly gas monitoring"], "2400-9990-09")
  expect_identical(rm_type_of(con, new_proj), "Monthly gas monitoring")
  expect_equal(rm_samples_in(con, acirl), 1L)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

# ==============================================================================
# 6 - the archive path
# ==============================================================================

rm_asset_project <- function(con, hash) {
  DBI::dbGetQuery(con, "SELECT uuid_project FROM asset WHERE hash = ?", params = list(hash))$uuid_project
}

test_that("6: archiving a water workbook X when only gas X exists files the asset on a new 'ACIRL report', never the gas project", {
  s <- rm_setup()
  con <- s$con
  gas <- rm_seed_gas(con, "2400-9990-10")
  ev <- rm_event(con, s$src, "2400-9990-10", gas = FALSE)
  archive_file(con, ev$path, ev$hash, ev$event)
  up <- rm_asset_project(con, ev$hash)
  expect_equal(length(up), 1)
  expect_false(identical(up, gas))
  expect_identical(rm_type_of(con, up), "ACIRL report")
  expect_equal(sum(rm_rows(con, "2400-9990-10")$type == "ACIRL report"), 1)
  expect_equal(nrow(rm_dup_reviews(con)), 0)
})

test_that("6: archiving a water workbook X when both exist files the asset on the ACIRL report", {
  for (acirl_first in c(TRUE, FALSE)) {
    s <- rm_setup()
    con <- s$con
    if (acirl_first) {
      acirl <- rm_seed_acirl(con, "2400-9990-11")
      rm_seed_gas(con, "2400-9990-11")
    } else {
      rm_seed_gas(con, "2400-9990-11")
      acirl <- rm_seed_acirl(con, "2400-9990-11")
    }
    ev <- rm_event(con, s$src, "2400-9990-11", gas = FALSE)
    archive_file(con, ev$path, ev$hash, ev$event)
    expect_identical(rm_asset_project(con, ev$hash), acirl, info = as.character(acirl_first))
  }
})

test_that("6: archiving a gas workbook X when only an ACIRL report X exists files the asset on a gas project, never the ACIRL report", {
  s <- rm_setup()
  con <- s$con
  acirl <- rm_seed_acirl(con, "2400-9990-12")
  ev <- rm_event(con, s$src, "2400-9990-12", gas = TRUE)
  archive_file(con, ev$path, ev$hash, ev$event)
  up <- rm_asset_project(con, ev$hash)
  expect_false(identical(up, acirl))
  expect_identical(rm_type_of(con, up), "Monthly gas monitoring")
})

# ==============================================================================
# 7 - two same-type candidates: the pick does not depend on insertion order
# ==============================================================================

test_that("7: two same-name ACIRL reports are picked identically whichever was inserted first, and the ambiguity is still raised", {
  picks <- character(0)
  for (order in list(c("p-aaa", "p-bbb"), c("p-bbb", "p-aaa"))) {
    s <- rm_setup()
    con <- s$con
    for (u in order) rm_seed_project(con, "2400-9990-13", "ACIRL report", uuid = u)
    picks <- c(picks, rm_run(s, "2400-9990-13", gas = FALSE))
    rv <- rm_dup_reviews(con)
    expect_true(any(rv$kind == "duplicate_report_number"), info = paste(order, collapse = ","))
  }
  expect_length(unique(picks), 1)
})

test_that("7: two same-name gas projects are picked identically whichever was inserted first, and the ambiguity is still raised", {
  picks <- character(0)
  for (order in list(c("p-aaa", "p-bbb"), c("p-bbb", "p-aaa"))) {
    s <- rm_setup()
    con <- s$con
    campaign <- rm_gas_campaign(con)
    for (u in order) {
      rm_seed_project(con, "2400-9990-14", "Monthly gas monitoring", parent = campaign,
                      root = campaign, uuid = u)
    }
    picks <- c(picks, rm_run(s, "2400-9990-14", gas = TRUE))
    rv <- rm_dup_reviews(con)
    expect_true(any(rv$kind == "duplicate_report_number"), info = paste(order, collapse = ","))
  }
  expect_length(unique(picks), 1)
})

test_that("7: with a gas twin present, two ACIRL candidates are still picked order-independently and the gas project is never chosen", {
  picks <- character(0)
  for (order in list(c("p-aaa", "p-bbb", "p-gas"), c("p-gas", "p-bbb", "p-aaa"))) {
    s <- rm_setup()
    con <- s$con
    campaign <- rm_gas_campaign(con)
    for (u in order) {
      if (u == "p-gas") {
        rm_seed_project(con, "2400-9990-15", "Monthly gas monitoring", parent = campaign,
                        root = campaign, uuid = u)
      } else {
        rm_seed_project(con, "2400-9990-15", "ACIRL report", uuid = u)
      }
    }
    picks <- c(picks, rm_run(s, "2400-9990-15", gas = FALSE))
  }
  expect_length(unique(picks), 1)
  expect_true(picks[[1]] %in% c("p-aaa", "p-bbb"))
})
