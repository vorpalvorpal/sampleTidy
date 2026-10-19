# tests/testthat/test-date-overrides.R
#
# TDD "red" tests for C3 (spec: per-file sample-date overrides).
#   .ig_date_overrides(path)            loader for inst/extdata/sample-date-overrides.csv
#   .ig_apply_date_overrides(samples, overrides)   pure IR applier
#   integration: ingest_dir() applies overrides before reconcile; the overrides
#   path is injected through option `sampletidy.date_overrides_path`, which is
#   the default of `.ig_date_overrides(path = ...)`.
#
# Assumption: `.rc_datetime_formats` has NO ISO format, so an ISO raw such as
# "2023-04-14" does not parse and is (by spec) "unparseable -> untouched"; the
# applier tests therefore use the supported dialects (d/m/Y, d b Y, d-b-y).

ov_csv <- function(rows = character(0), dir = withr::local_tempdir(.local_envir = parent.frame())) {
  p <- file.path(dir, "overrides.csv")
  writeLines(c("hash,date_from,date_to,authority,reason", rows), p)
  p
}

ov_load <- function(p) sampleTidy:::.ig_date_overrides(p)
ov_apply <- function(s, o) sampleTidy:::.ig_apply_date_overrides(s, o)

ov_table <- function(hash, date_from, date_to) {
  data.frame(hash = hash, date_from = as.Date(date_from), date_to = as.Date(date_to),
             authority = rep("test", length(hash)), reason = rep("test", length(hash)),
             stringsAsFactors = FALSE)
}

ov_samples <- function(hash, raw, extra_hash = NULL) {
  n <- length(raw)
  hashes <- rep(hash, n)
  if (!is.null(extra_hash)) hashes <- extra_hash
  ir_samples(
    source_hash = hashes, source_ref = paste0("r", seq_len(n)),
    work_order = rep("WO1", n), org = rep("ACIRL", n), adapter = rep("test", n),
    lab_sample_id = rep(NA_character_, n), feature_raw = paste0("F", seq_len(n)),
    sample_datetime_raw = raw, sample_type = rep("Normal", n),
    parent_sample = rep(NA_character_, n), matrix_raw = rep("water", n),
    sampler = rep(NA_character_, n), comments = rep(NA_character_, n),
    confidence = rep(1, n)
  )
}

ov_parse <- function(x) {
  sampleTidy:::parse_lab_datetime(x, sampleTidy:::.rc_datetime_formats)
}
ov_day <- function(x) as.Date(format(ov_parse(x), "%Y-%m-%d", tz = "Australia/Sydney"))
ov_clock <- function(x) format(ov_parse(x), "%H:%M", tz = "Australia/Sydney")

H1 <- "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
H2 <- "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ---- loader -----------------------------------------------------------------

test_that("loader: a well-formed file loads with exactly the five columns, dates as Date", {
  p <- ov_csv(c(paste0(H1, ",2023-04-14,2023-04-13,ALS COC,dragged fill"),
                paste0(H1, ",2023-04-15,2023-04-13,ALS COC,dragged fill"),
                paste0(H2, ",2022-01-05,2023-01-05,Robin,previous year")))
  o <- ov_load(p)
  expect_s3_class(o, "data.frame")
  expect_identical(names(o), c("hash", "date_from", "date_to", "authority", "reason"))
  expect_equal(nrow(o), 3L)
  expect_s3_class(o$date_from, "Date")
  expect_s3_class(o$date_to, "Date")
  expect_equal(o$date_to[[1]], as.Date("2023-04-13"))
  expect_identical(o$hash[[3]], H2)
})

test_that("loader: a header-only file returns 0 rows with the right columns", {
  o <- ov_load(ov_csv())
  expect_equal(nrow(o), 0L)
  expect_identical(names(o), c("hash", "date_from", "date_to", "authority", "reason"))
  expect_s3_class(o$date_from, "Date")
})

test_that("loader: a duplicate (hash, date_from) aborts with sampletidy_error", {
  p <- ov_csv(c(paste0(H1, ",2023-04-14,2023-04-13,a,r"),
                paste0(H1, ",2023-04-14,2023-04-12,a,r")))
  expect_error(ov_load(p), class = "sampletidy_error")
})

test_that("loader: same date_from under different hashes is fine (key is the pair)", {
  p <- ov_csv(c(paste0(H1, ",2023-04-14,2023-04-13,a,r"),
                paste0(H2, ",2023-04-14,2023-04-13,a,r")))
  expect_equal(nrow(ov_load(p)), 2L)
})

test_that("loader: a malformed date aborts with sampletidy_error", {
  expect_error(ov_load(ov_csv(paste0(H1, ",14/04/2023,2023-04-13,a,r"))), class = "sampletidy_error")
  expect_error(ov_load(ov_csv(paste0(H1, ",2023-04-14,not-a-date,a,r"))), class = "sampletidy_error")
  expect_error(ov_load(ov_csv(paste0(H1, ",2023-02-30,2023-04-13,a,r"))), class = "sampletidy_error")
})

test_that("loader: date_from == date_to aborts with sampletidy_error", {
  expect_error(ov_load(ov_csv(paste0(H1, ",2023-04-14,2023-04-14,a,r"))), class = "sampletidy_error")
})

test_that("loader: the shipped package file loads without error", {
  shipped <- system.file("extdata", "sample-date-overrides.csv", package = "sampleTidy")
  expect_true(nzchar(shipped))
  o <- expect_no_error(sampleTidy:::.ig_date_overrides())
  expect_identical(names(o), c("hash", "date_from", "date_to", "authority", "reason"))
})

test_that("loader: the default path honours option sampletidy.date_overrides_path", {
  p <- ov_csv(paste0(H1, ",2023-04-14,2023-04-13,a,r"))
  withr::local_options(sampletidy.date_overrides_path = p)
  o <- sampleTidy:::.ig_date_overrides()
  expect_equal(nrow(o), 1L)
  expect_identical(o$hash, H1)
})

# ---- applier ----------------------------------------------------------------

test_that("applier: matching hash and date are rewritten to date_to (date-only stays date-only)", {
  s <- ov_samples(H1, c("14/04/2023", "14 Apr 2023", "14-Apr-23"))
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_true(all(ov_day(out$sample_datetime_raw) == as.Date("2023-04-13")))
  expect_true(all(ov_clock(out$sample_datetime_raw) == "00:00"))
  # a date-only value stays date-only: no clock time appears in the string
  expect_false(any(grepl(":", out$sample_datetime_raw)))
})

test_that("applier: same hash but a different date is untouched", {
  s <- ov_samples(H1, c("14/04/2023", "20/04/2023"))
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_identical(out$sample_datetime_raw[[2]], "20/04/2023")
  expect_equal(ov_day(out$sample_datetime_raw[[1]]), as.Date("2023-04-13"))
})

test_that("applier: matching date but another hash is untouched", {
  s <- ov_samples(H1, c("14/04/2023", "14/04/2023"), extra_hash = c(H1, H2))
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_identical(out$sample_datetime_raw[[2]], "14/04/2023")
  expect_equal(ov_day(out$sample_datetime_raw[[1]]), as.Date("2023-04-13"))
})

test_that("applier: a datetime keeps its Sydney clock time after the rewrite", {
  s <- ov_samples(H1, c("14 Apr 2023 09:30", "14-Apr-23 16:05"))
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_true(all(ov_day(out$sample_datetime_raw) == as.Date("2023-04-13")))
  expect_identical(ov_clock(out$sample_datetime_raw), c("09:30", "16:05"))
})

test_that("applier: the clock time survives a move across a DST boundary", {
  # AEDT ends 2023-04-02 03:00; move a post-DST date to a pre-DST one.
  s <- ov_samples(H1, "05 Apr 2023 09:30")
  out <- ov_apply(s, ov_table(H1, "2023-04-05", "2023-03-30"))
  expect_equal(ov_day(out$sample_datetime_raw), as.Date("2023-03-30"))
  expect_identical(ov_clock(out$sample_datetime_raw), "09:30")
})

test_that("applier: NA and unparseable raws are untouched", {
  s <- ov_samples(H1, c(NA_character_, "garbage", "14/04/2023"))
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_true(is.na(out$sample_datetime_raw[[1]]))
  expect_identical(out$sample_datetime_raw[[2]], "garbage")
  expect_equal(ov_day(out$sample_datetime_raw[[3]]), as.Date("2023-04-13"))
})

test_that("applier: only sample_datetime_raw changes; order, other columns and types are identical", {
  s <- ov_samples(H1, c("15/04/2023", "01/01/2020", "14/04/2023"))
  s$sample_date_start_raw <- c("01/04/2023", "01/04/2023", "14/04/2023")
  out <- ov_apply(s, ov_table(H1, "2023-04-14", "2023-04-13"))
  expect_identical(names(out), names(s))
  expect_identical(vapply(out, typeof, ""), vapply(s, typeof, ""))
  expect_identical(vapply(out, function(c) class(c)[[1]], ""), vapply(s, function(c) class(c)[[1]], ""))
  strip <- function(x) { attr(x, "date_overrides_applied") <- NULL; x }
  expect_identical(strip(out)[setdiff(names(s), "sample_datetime_raw")],
                   s[setdiff(names(s), "sample_datetime_raw")])
  expect_identical(out$sample_date_start_raw, s$sample_date_start_raw)
  expect_identical(out$sample_datetime_raw[1:2], s$sample_datetime_raw[1:2])
  expect_identical(out$source_ref, s$source_ref)
  expect_equal(nrow(out), 3L)
})

test_that("applier: empty overrides (or zero rows) return the input unchanged", {
  s <- ov_samples(H1, c("14/04/2023", "15/04/2023"))
  out <- ov_apply(s, ov_table(character(0), character(0), character(0)))
  expect_identical(as.data.frame(out)[names(s)], as.data.frame(s)[names(s)])
  applied <- attr(out, "date_overrides_applied")
  expect_equal(nrow(applied), 0L)
})

test_that("applier: attribute date_overrides_applied lists only matching overrides with n_rows", {
  s <- ov_samples(H1, c("14/04/2023", "14/04/2023", "15/04/2023", "20/04/2023"))
  o <- rbind(ov_table(H1, "2023-04-14", "2023-04-13"),
             ov_table(H1, "2023-04-15", "2023-04-13"),
             ov_table(H1, "2023-05-01", "2023-04-30"),   # no matching row
             ov_table(H2, "2023-04-14", "2023-04-13"))   # other hash: no match
  out <- ov_apply(s, o)
  applied <- attr(out, "date_overrides_applied")
  expect_s3_class(applied, "data.frame")
  expect_identical(names(applied), c("hash", "date_from", "date_to", "n_rows"))
  expect_equal(nrow(applied), 2L)
  expect_true(all(applied$hash == H1))
  expect_equal(applied$n_rows[applied$date_from == as.Date("2023-04-14")], 2L)
  expect_equal(applied$n_rows[applied$date_from == as.Date("2023-04-15")], 1L)
  expect_equal(unique(applied$date_to), as.Date("2023-04-13"))
})

test_that("applier: several dates of one hash (dragged fill 14..18) all map to 13", {
  raws <- sprintf("%02d/04/2023", 14:18)
  s <- ov_samples(H1, c(raws, "13/04/2023"))
  o <- do.call(rbind, lapply(14:18, function(d) {
    ov_table(H1, sprintf("2023-04-%02d", d), "2023-04-13")
  }))
  out <- ov_apply(s, o)
  expect_true(all(ov_day(out$sample_datetime_raw) == as.Date("2023-04-13")))
  expect_equal(nrow(attr(out, "date_overrides_applied")), 5L)
  expect_equal(sum(attr(out, "date_overrides_applied")$n_rows), 5L)
})

# ---- integration: ingest_dir() ---------------------------------------------

di_features <- c(`f-g182` = "B.G182", `f-g183` = "B.G183", `f-g184` = "B.G184",
                 `f-g185` = "B.G185", `f-g368` = "B.G368", `f-tg179` = "B.TG179",
                 `f-g382` = "B.G382")

di_db_setup <- function() {
  env <- parent.frame()
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  i <- 0
  for (u in names(di_features)) {
    i <- i + 1
    nm <- di_features[[u]]
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat)
                         VALUES (?, ?, 'B', NULL, 'air', NULL, ?, ?)",
                   params = list(u, nm, 150.6 + i / 1000, -33.7 - i / 1000))
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by)
      VALUES (?, ?, ?, ?, 'self', 0, TRUE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
      params = list(paste0("fa-", sub("^f-", "", u)), u, nm, tolower(nm)))
  }
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

# Build the gas workbook (dated `date_from`), ingest it with the given overrides
# CSV rows (NULL = option not set), return the Sydney dates of the committed
# G183 sample(s) and the file hash.
di_run <- function(rows = NULL, hash_rows = NULL) {
  env <- parent.frame()
  db <- di_db_setup()
  input <- withr::local_tempdir(.local_envir = env)
  path <- build_gas_blaxland_2025(
    input, report_no = "2400-9902-07-01", sample_date = "2025-07-22",
    l1 = list(list(G182 = 0, G183 = 0.03)), l2 = list(list(G368 = 0)), l2_rows = 8:9,
    l3 = list(list(G382 = 0)))
  hash <- hash_file(path)
  if (!is.null(hash_rows)) {
    p <- ov_csv(hash_rows(hash), dir = withr::local_tempdir(.local_envir = env))
    withr::local_options(sampletidy.date_overrides_path = p, .local_envir = env)
  }
  suppressMessages(suppressWarnings(ingest_dir(input, db = db)))
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  smp <- DBI::dbGetQuery(con, "SELECT s.date, s.datetime, s.comments, fa.uuid_feature
                                 FROM \"sample\" s
                                 JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                                WHERE fa.uuid_feature IN ('f-g182', 'f-g183', 'f-g368', 'f-g382')")
  list(samples = smp, hash = hash,
       days = function(feat) as.character(as.Date(format(smp$date[smp$uuid_feature == feat],
                                                         tz = "Australia/Sydney"))))
}

test_that("integration control: with no override row the sample is committed on date_from", {
  r <- di_run(hash_rows = function(h) paste0("cccccccccccccccccccccccccccccccc,2025-07-22,2025-07-20,t,other file"))
  expect_equal(nrow(r$samples), 4L)
  expect_identical(r$days("f-g183"), "2025-07-22")
  expect_identical(r$days("f-g382"), "2025-07-22")
})

test_that("integration control: unset option (shipped CSV) also commits on date_from", {
  r <- di_run()
  expect_identical(r$days("f-g183"), "2025-07-22")
})

test_that("integration: an override row for the file's hash commits every sample on date_to", {
  r <- di_run(hash_rows = function(h) paste0(h, ",2025-07-22,2025-07-20,ALS COC,dragged fill"))
  expect_equal(nrow(r$samples), 4L)
  for (f in c("f-g182", "f-g183", "f-g368", "f-g382")) {
    expect_identical(r$days(f), "2025-07-20", info = f)
  }
  # provenance is the CSV row: the committed comments are not rewritten
  ctl <- di_run()
  expect_identical(r$samples$comments[order(r$samples$uuid_feature)],
                   ctl$samples$comments[order(ctl$samples$uuid_feature)])
})

test_that("integration: an override for a different date_from does not touch the file's samples", {
  r <- di_run(hash_rows = function(h) paste0(h, ",2025-07-23,2025-07-20,t,wrong day"))
  expect_identical(r$days("f-g183"), "2025-07-22")
})
