# tests/testthat/test-acirl-gas-e2e.R
#
# End-to-end TDD "red" tests for the ACIRL monthly-gas adapter (PLAN-17
# "Tests first" 11-14, plus the commit side of 6, 7 and 9). Each test builds a
# small Blaxland-2025-geometry workbook (helper-acirl-gas.R), ingests it with
# ingest_dir() into a throwaway seed DB, and reads the DB back. No live DB.
#
# Rulings pinned here (coordinator, 2026-10-16):
#   * a zero CH4 commits value 0, quantified FALSE, and rl_low taken from
#     lab_method.rl_low (1e-4 L/L) when the adapter supplies none;
#   * adapter-raised review signals reach review_queue. The mechanism is being
#     designed, so only the OUTCOME is pinned: a review_queue row the control
#     run does not have, with a non-empty kind, whose kind or payload names the
#     offending value. Choice of withheld/committed (from the plan):
#       - >2 dp reading     -> WITHHELD (no analysis), review row opened;
#       - filename/REPORT NO mismatch -> data COMMITTED under the cell's number,
#         review row opened (A80: "the data still imports; the flag exists").
#
# Every test fails today on gas_adapter()'s "not registered" message (called
# first, so the failure reads clearly rather than as a DB count mismatch).

gas_sample_date <- "2025-07-22"
gas_sydney_midnight_utc <- "2025-07-21 14:00:00"   # 2025-07-22 00:00 AEST

# Mini workbook: G182 0, G183 0.03, G184 0.0299999999999999 (noise -> 0.03),
# G185 `g185`, then G368 (building point on a landfill sheet), G179 (-> TG179),
# G382 on #3.
gas_e2e_workbook <- function(dir, g185 = 0.12, report_no = "2400-9901-07-01",
                             filename = paste0(report_no, " July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx")) {
  build_gas_blaxland_2025(
    dir, report_no = report_no, sample_date = gas_sample_date, filename = filename,
    l1 = list(list(G182 = 0, G183 = 0.03, G184 = 0.0299999999999999, G185 = g185)),
    l2 = list(list(G368 = 0, G179 = 0.01)), l2_rows = 8:9,
    l3 = list(list(G382 = 0))
  )
}

gas_features <- c(`f-g182` = "B.G182", `f-g183` = "B.G183", `f-g184` = "B.G184",
                  `f-g185` = "B.G185", `f-g368` = "B.G368", `f-tg179` = "B.TG179",
                  `f-g382` = "B.G382")

gas_db_setup <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  i <- 0
  for (u in names(gas_features)) {
    i <- i + 1
    nm <- gas_features[[u]]
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat)
                         VALUES (?, ?, 'B', NULL, 'air', NULL, ?, ?)",
                   params = list(u, nm, 150.6 + i / 1000, -33.7 - i / 1000))
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by)
      VALUES (?, ?, ?, ?, 'self', 0, TRUE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
      params = list(paste0("fa-", sub("^f-", "", u)), u, nm, tolower(nm)))
  }
  # Registry aliases the adapter must NOT pre-empt (rulings 3 and 4).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('fa-g368-long', 'f-g368', 'Gatehouse - Meal Room', 'gatehouse - meal room', 'mask_long', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', 'test'),
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

# A legacy report project (type `Monthly gas monitoring` under the campaign)
# holding legacy-shaped samples: date = Sydney midnight as UTC, a synthetic
# +1 min datetime per probe, CH4 stored in L/L, zeros value 0 quantified FALSE.
gas_add_legacy <- function(db_path, report_no, utc_date, values) {
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  if (nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = ?", params = list(report_no))) == 0) {
    DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                         VALUES (?, 'p-gascamp', 'p-gascamp', ?, 'Monthly gas monitoring')",
                   params = list(paste0("p-", report_no), report_no))
  }
  k <- 0
  for (u in names(values)) {
    k <- k + 1
    su <- paste0("s-leg-", report_no, "-", u)
    dt <- format(as.POSIXct(utc_date, tz = "UTC") + 11 * 3600 + k * 60, "%Y-%m-%d %H:%M:%S")
    DBI::dbExecute(con, "INSERT INTO \"sample\"
      (uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, organisation)
      VALUES (?, ?, ?, CAST(? AS TIMESTAMP), NULL, CAST(? AS TIMESTAMP), 'ACIRL')",
      params = list(su, paste0("fa-", sub("^f-", "", u)), paste0("p-", report_no), utc_date, dt))
    v <- values[[u]]
    DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                         VALUES (?, ?, 'lm-ch4', ?, ?, NULL)",
                   params = list(paste0("an-", su), su, v, v != 0))
  }
  invisible(db_path)
}

gas_ingest <- function(db_path, ..., env = parent.frame()) {
  gas_adapter()                                  # fail first, and clearly, if absent
  input <- withr::local_tempdir(.local_envir = env)
  gas_e2e_workbook(input, ...)
  ingest_dir(input, db = db_path)
}

gas_ro <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

# The CH4 analyses at one feature (through whatever alias the sample arrived under).
gas_analyses_at <- function(con, uuid_feature) {
  DBI::dbGetQuery(con, "SELECT a.uuid, a.value, a.quantified, a.rl_low, s.uuid AS uuid_sample,
                               s.date, s.datetime, s.uuid_project, s.uuid_feature_alias
                          FROM analysis a
                          JOIN \"sample\" s ON s.uuid = a.uuid_sample
                          JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                         WHERE fa.uuid_feature = ? AND a.uuid_lab = 'lm-ch4'
                         ORDER BY a.uuid", params = list(uuid_feature))
}

gas_sydney_day <- function(x) as.character(as.Date(format(x, tz = "Australia/Sydney")))

gas_reviews <- function(con) {
  DBI::dbGetQuery(con, "SELECT kind, work_order, payload FROM review_queue ORDER BY kind")
}

# ==============================================================================
# 11 - `%` -> L/L end to end
# ==============================================================================

test_that("11: 0.03 % commits as 3e-4 L/L, quantified TRUE (and the 0.0299999999999999 noise likewise)", {
  db <- gas_db_setup()
  gas_ingest(db)
  con <- gas_ro(db)
  for (u in c("f-g183", "f-g184")) {
    a <- gas_analyses_at(con, u)
    expect_equal(nrow(a), 1, info = u)
    expect_true(abs(a$value - 3e-4) < 1e-12, info = u)
    expect_true(a$quantified, info = u)
  }
})

# ==============================================================================
# 9 - zero = non-detect, rl_low from lab_method
# ==============================================================================

test_that("9: a zero commits as value 0, quantified FALSE, rl_low = lab_method.rl_low (1e-4 L/L)", {
  db <- gas_db_setup()
  gas_ingest(db)
  con <- gas_ro(db)
  a <- gas_analyses_at(con, "f-g182")
  expect_equal(nrow(a), 1)
  expect_identical(a$value, 0)
  expect_false(a$quantified)
  expect_equal(a$rl_low, 1e-4)
  # a non-zero reading stays quantified (reachability of the zero rule)
  expect_true(gas_analyses_at(con, "f-g183")$quantified)
})

test_that("9: the rl_low comes from the METHOD, not a constant - a different method limit flows through", {
  db <- gas_db_setup()
  con <- seed_con(db)
  DBI::dbExecute(con, "UPDATE lab_method SET rl_low = 2e-4 WHERE uuid = 'lm-ch4'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  gas_ingest(db)
  ro <- gas_ro(db)
  expect_equal(gas_analyses_at(ro, "f-g182")$rl_low, 2e-4)
})

# ==============================================================================
# 10 - date-only samples
# ==============================================================================

test_that("10: samples are dated by SAMPLE DATE (Sydney day) with datetime NULL", {
  db <- gas_db_setup()
  gas_ingest(db)
  con <- gas_ro(db)
  for (u in c("f-g182", "f-g183", "f-g368", "f-g382")) {
    a <- gas_analyses_at(con, u)
    expect_equal(nrow(a), 1, info = u)
    expect_identical(gas_sydney_day(a$date), gas_sample_date, info = u)
    expect_true(is.na(a$datetime), info = u)
  }
})

# ==============================================================================
# 7 - more than 2 dp -> review (withheld)
# ==============================================================================

test_that("7: a >2 dp reading opens a review_queue row and is WITHHELD; the 2 dp control commits", {
  db_ctl <- gas_db_setup()
  gas_ingest(db_ctl, g185 = 0.12)
  ctl <- gas_ro(db_ctl)
  expect_equal(nrow(gas_analyses_at(ctl, "f-g185")), 1)
  expect_true(abs(gas_analyses_at(ctl, "f-g185")$value - 1.2e-3) < 1e-12)
  ctl_kinds <- gas_reviews(ctl)$kind

  db <- gas_db_setup()
  gas_ingest(db, g185 = 0.125)
  con <- gas_ro(db)
  expect_equal(nrow(gas_analyses_at(con, "f-g185")), 0)     # withheld, never rounded
  rv <- gas_reviews(con)
  expect_gt(nrow(rv), length(ctl_kinds))
  expect_true(all(!is.na(rv$kind) & nzchar(rv$kind)))
  expect_true(any(grepl("0.125", paste(rv$kind, rv$payload), fixed = TRUE)))
  # the rest of the file still commits
  expect_equal(nrow(gas_analyses_at(con, "f-g182")), 1)
  expect_equal(nrow(gas_analyses_at(con, "f-g183")), 1)
})

# ==============================================================================
# 6 - filename/REPORT NO mismatch -> review (committed under the cell)
# ==============================================================================

test_that("6: a filename/REPORT NO mismatch opens a review_queue row; the data commits under the CELL's number", {
  db_ctl <- gas_db_setup()
  gas_ingest(db_ctl)
  ctl <- gas_ro(db_ctl)
  n_ctl <- nrow(gas_reviews(ctl))

  db <- gas_db_setup()
  gas_ingest(db, filename = "2400-9901-07 July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx")
  con <- gas_ro(db)
  rv <- gas_reviews(con)
  expect_gt(nrow(rv), n_ctl)
  expect_true(all(!is.na(rv$kind) & nzchar(rv$kind)))
  hit <- grepl("2400-9901-07", paste(rv$kind, rv$payload, rv$work_order), fixed = TRUE)
  expect_true(any(hit))
  # committed, filed under the cell's number - no project named by the filename
  a <- gas_analyses_at(con, "f-g182")
  expect_equal(nrow(a), 1)
  p <- DBI::dbGetQuery(con, "SELECT name FROM project WHERE uuid = ?", params = list(a$uuid_project))
  expect_identical(p$name, "2400-9901-07-01")
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM project WHERE name = '2400-9901-07'")), 0)
})

# ==============================================================================
# 12 - filing under `Monthly gas monitoring`
# ==============================================================================

test_that("12: a new report files as a `Monthly gas monitoring` project under the campaign", {
  db <- gas_db_setup()
  gas_ingest(db)
  con <- gas_ro(db)
  p <- DBI::dbGetQuery(con, "SELECT uuid, uuid_parent, type FROM project WHERE name = '2400-9901-07-01'")
  expect_equal(nrow(p), 1)
  expect_identical(p$type, "Monthly gas monitoring")
  expect_identical(p$uuid_parent, "p-gascamp")
  for (u in c("f-g182", "f-g183", "f-g368", "f-tg179", "f-g382")) {
    expect_identical(gas_analyses_at(con, u)$uuid_project, p$uuid, info = u)
  }
})

test_that("12: an existing report project is MERGED into, not duplicated; same date raises no duplicate_report_number", {
  db <- gas_db_setup()
  gas_add_legacy(db, "2400-9901-07-01", gas_sydney_midnight_utc, list(`f-g182` = 0))
  gas_ingest(db)
  con <- gas_ro(db)
  p <- DBI::dbGetQuery(con, "SELECT uuid FROM project WHERE name = '2400-9901-07-01'")
  expect_equal(nrow(p), 1)
  expect_identical(p$uuid, "p-2400-9901-07-01")
  expect_identical(gas_analyses_at(con, "f-g183")$uuid_project, "p-2400-9901-07-01")
  expect_equal(nrow(gas_analyses_at(con, "f-g182")), 1)      # legacy row, already_present
  expect_false(any(gas_reviews(con)$kind == "duplicate_report_number"))
})

test_that("12: duplicate_report_number fires when the existing project holds samples on a DIFFERENT date in the SAME year; data still imports", {
  db <- gas_db_setup()
  # C8/D14: a different date in a different YEAR is keyed apart as
  # "<report_no> (<yyyy>)" instead (test-report-year-key-c8.R); inside one
  # year the acirl_gas flag is unchanged. 2025-06-24 Sydney, a month earlier.
  gas_add_legacy(db, "2400-9901-07-01", "2025-06-23 14:00:00", list(`f-g182` = 0, `f-g183` = 2e-4))
  gas_ingest(db)
  con <- gas_ro(db)
  rv <- gas_reviews(con)
  expect_true(any(rv$kind == "duplicate_report_number"))
  expect_true(any(rv$work_order[rv$kind == "duplicate_report_number"] == "2400-9901-07-01"))
  a <- gas_analyses_at(con, "f-g183")
  expect_equal(nrow(a), 2)                                     # June legacy + July new
  expect_true(gas_sample_date %in% gas_sydney_day(a$date))
})

# ==============================================================================
# 13 - re-ingesting a loaded month writes nothing
# ==============================================================================

test_that("13: re-ingesting a month legacy already holds writes nothing new (all already_present)", {
  db <- gas_db_setup()
  legacy <- list(`f-g182` = 0, `f-g183` = 3e-4, `f-g184` = 3e-4, `f-g185` = 1.2e-3,
                 `f-g368` = 0, `f-tg179` = 1e-4, `f-g382` = 0)
  gas_add_legacy(db, "2400-9901-07-01", gas_sydney_midnight_utc, legacy)
  before <- local({
    con <- gas_ro(db)
    c(s = DBI::dbGetQuery(con, "SELECT count(*) n FROM \"sample\"")$n,
      a = DBI::dbGetQuery(con, "SELECT count(*) n FROM analysis")$n,
      p = DBI::dbGetQuery(con, "SELECT count(*) n FROM project")$n)
  })
  rep <- gas_ingest(db)
  con <- gas_ro(db)
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM \"sample\"")$n, before[["s"]])
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM analysis")$n, before[["a"]])
  expect_equal(DBI::dbGetQuery(con, "SELECT count(*) n FROM project")$n, before[["p"]])
  expect_equal(rep$rows_new, 0L)
  expect_equal(rep$rows_already_present, length(legacy))
  expect_false(any(gas_reviews(con)$kind %in% c("value_conflict", "work_order_reingest")))
})

# ==============================================================================
# 14 - registry resolution of the building and temporary points
# ==============================================================================

test_that("14: G368 on a landfill sheet lands on the B.G368 building feature; G179 lands on B.TG179", {
  db <- gas_db_setup()
  gas_ingest(db)
  con <- gas_ro(db)
  a368 <- gas_analyses_at(con, "f-g368")
  expect_equal(nrow(a368), 1)
  expect_identical(a368$value, 0)
  a179 <- gas_analyses_at(con, "f-tg179")
  expect_equal(nrow(a179), 1)
  expect_true(abs(a179$value - 1e-4) < 1e-12)
  expect_false(any(gas_reviews(con)$kind == "unknown_feature"))
})

# ==============================================================================
# 16 - template slots B.G201 / K.G365 / K.G366 never reach the DB (032/034)
# ==============================================================================
#
# Robin (migrations 032/034): "If not [existing located features], we don't
# want them." Before the fix every import of such a workbook minted a pending
# alias, a dangling sample with a CH4 0 reading, and an unknown_feature review
# item for each slot (034 deleted the ones the 2026-10-17 import re-minted).

gas_counts <- function(con) {
  c(sample = DBI::dbGetQuery(con, "SELECT count(*) n FROM \"sample\"")$n,
    analysis = DBI::dbGetQuery(con, "SELECT count(*) n FROM analysis")$n,
    alias = DBI::dbGetQuery(con, "SELECT count(*) n FROM feature_alias")$n,
    review = DBI::dbGetQuery(con, "SELECT count(*) n FROM review_queue")$n)
}

gas_slot_traces <- function(con, keys) {
  in_list <- paste(sprintf("'%s'", keys), collapse = ", ")
  list(
    alias = DBI::dbGetQuery(con, sprintf(
      "SELECT uuid, kind FROM feature_alias WHERE alias_key IN (%s)", in_list)),
    sample = DBI::dbGetQuery(con, sprintf(
      "SELECT s.uuid FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
        WHERE fa.alias_key IN (%s)", in_list)),
    review = DBI::dbGetQuery(con, "SELECT kind, payload FROM review_queue")
  )
}

test_that("16: a Blaxland workbook carrying a numeric B.G201 commits exactly what the same workbook without it does - no pending alias, sample or review item", {
  l1_ctl <- list(list(G182 = 0, G183 = 0.03))
  l1_slot <- list(list(G182 = 0, G183 = 0.03, G201 = 0))
  run <- function(l1, env = parent.frame()) {
    db <- gas_db_setup(env = env)
    gas_adapter()
    input <- withr::local_tempdir(.local_envir = env)
    build_gas_blaxland_2025(input, report_no = "2400-9901-07-01", sample_date = gas_sample_date,
                            l1 = l1, l2 = list(list(G368 = 0)), l2_rows = 8L,
                            l3 = list(list(G382 = 0)))
    ingest_dir(input, db = db)
    db
  }
  ctl <- gas_ro(run(l1_ctl))
  db <- run(l1_slot)
  con <- gas_ro(db)

  expect_identical(gas_counts(con), gas_counts(ctl))
  tr <- gas_slot_traces(con, "b.g201")
  expect_equal(nrow(tr$alias), 0)
  expect_equal(nrow(tr$sample), 0)
  expect_false(any(grepl("G201", tr$review$payload, fixed = TRUE)))
  # the real points in the same file commit as usual
  expect_equal(nrow(gas_analyses_at(con, "f-g182")), 1)
  expect_equal(nrow(gas_analyses_at(con, "f-g183")), 1)
  expect_equal(nrow(gas_analyses_at(con, "f-g368")), 1)
})

test_that("16: a Katoomba workbook mints no pending alias or sample for K.G365 / K.G366, while its genuinely unregistered probes still go pending", {
  db <- gas_db_setup()          # registers Blaxland probes only: every K. label is unknown here
  gas_adapter()
  input <- withr::local_tempdir()
  build_gas_katoomba(input)
  ingest_dir(input, db = db)
  con <- gas_ro(db)

  tr <- gas_slot_traces(con, c("k.g365", "k.g366"))
  expect_equal(nrow(tr$alias), 0)
  expect_equal(nrow(tr$sample), 0)
  expect_false(any(grepl("G365|G366", tr$review$payload)))
  # reachability: K.G362, printed in the same column right above the slots,
  # is unknown to this DB and DOES go pending - so the absence above is the skip
  near <- gas_slot_traces(con, "k.g362")
  expect_equal(nrow(near$alias), 1)
  expect_identical(near$alias$kind, "pending")
  expect_equal(nrow(near$sample), 1)
})
