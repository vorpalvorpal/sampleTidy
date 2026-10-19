# 2026-10-19 bug (PLAN-18 section 2): the dated imports note said "no sample
# dates" for deliveries whose samples carry only `sample.date` (datetime NULL -
# live: ES2626883, every ACIRL field / gas / dust row). The import line's date
# range must use COALESCE(datetime, date), the LOCAL_DATE rule of R/flags.R.
#
# ingest_dir() is mocked (namespace binding, as test-inbox.R does) to commit one
# work order's samples directly, so the test controls which column is set.

sd_run <- function(ts_col, stamps, wo = "ES2626883") {
  s <- inbox_setup(env = parent.frame())
  now <- sydney_midday()
  make_inbox_folder(s$input_dir, "input2026-10-19 0900 dates", inbox_proj_a_files(), now = now)
  testthat::local_mocked_bindings(ingest_dir = function(path, ..., db) {
    con <- seed_con(db)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-sd', ?, 'Work order')",
                   params = list(wo))
    for (i in seq_along(stamps)) {
      DBI::dbExecute(con, sprintf(
        "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, %s, organisation)
         VALUES (?, 'fa-0001', 'p-sd', CAST(? AS TIMESTAMP), 'ACIRL')", ts_col),
        params = list(sprintf("s-sd-%d", i), stamps[[i]]))
      DBI::dbExecute(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                           VALUES (?, ?, NULL, 7, TRUE)",
                     params = list(sprintf("a-sd-%d", i), sprintf("s-sd-%d", i)))
    }
    list(n_events_committed = 1L, rows_new = length(stamps), rows_already_present = 0L,
         rows_superseded = 0L, review_items_opened = 0L)
  }, .env = parent.frame())
  run_inbox(s, now = now)
  sec <- md_section(read_report(s$report_dir, now), "Imported today")
  sec[grepl(wo, sec, fixed = TRUE)]
}

test_that("dated note: samples with only `date` (datetime NULL) show their date range, not 'no sample dates'", {
  line <- sd_run("date", c("2026-09-14 00:00:00", "2026-09-16 00:00:00"))
  expect_length(line, 1)
  expect_false(grepl("no sample dates", line, fixed = TRUE))
  expect_match(line, "2026-09-14 to 2026-09-16", fixed = TRUE)
})

test_that("dated note: samples with `datetime` still show their date range", {
  line <- sd_run("datetime", c("2026-09-14 01:00:00", "2026-09-16 01:00:00"))
  expect_length(line, 1)
  expect_match(line, "2026-09-14 to 2026-09-16", fixed = TRUE)
})
