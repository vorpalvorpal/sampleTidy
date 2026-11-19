# PLAN-23 3.2 / 2.5 rule 5 (D17-76, D17-77): feature_labels(), the one
# implementation of the label rule.
#   R-23.29  the common name on a date inside its row's window, the systematic
#            name on a date outside it; `prefer` is honoured; a moved common name
#            (one feature until D - 1, another from D) labels each feature by date
# Seed (helper-db.R): the common name T.SN01 is held by f-0002 (T.S02) until
# 2024-12-31 and by f-0007 (T.S07) from 2025-01-01 (D = 2025-01-01). f-0001
# (T.S01) has the undated long name 'Test Surface 01'; f-0004 (T.S04) has no
# mask row at all.

lab_of <- function(res, uuid) res[res$uuid == uuid, , drop = FALSE]

test_that("R-23.29: feature_labels() returns data.frame(uuid, label, kind), one row per requested feature, and only reads", {
  s <- t23_setup()
  before <- t23_reg_fingerprint(s$con)
  res <- feature_labels(s$con, uuids = c("f-0001", "f-0004"), date = as.Date("2025-06-01"))
  expect_s3_class(res, "data.frame")
  expect_identical(names(res), c("uuid", "label", "kind"))
  expect_setequal(res$uuid, c("f-0001", "f-0004"))
  expect_equal(nrow(res), 2L)
  expect_type(res$label, "character")
  expect_type(res$kind, "character")
  t23_expect_unchanged(s$con, before)
})

test_that("R-23.29: the default prefers common: inside the row's window the label is the common name, kind 'common'", {
  s <- t23_setup()
  res <- feature_labels(s$con, uuids = "f-0007", date = as.Date("2025-06-01"))
  expect_identical(res$label, "T.SN01")
  expect_identical(res$kind, "common")
})

test_that("R-23.29: on a date outside the common row's window the label falls back to the systematic name", {
  s <- t23_setup()
  res <- feature_labels(s$con, uuids = "f-0007", date = as.Date("2024-06-01"))
  expect_identical(res$label, "T.S07")
  expect_identical(res$kind, "systematic")
})

test_that("R-23.29: a moved common name labels each feature by date: T.S02 until D - 1, T.S07 from D", {
  s <- t23_setup()
  before_d <- feature_labels(s$con, uuids = c("f-0002", "f-0007"), date = as.Date("2024-12-31"))
  expect_identical(lab_of(before_d, "f-0002")$label, "T.SN01")
  expect_identical(lab_of(before_d, "f-0002")$kind, "common")
  expect_identical(lab_of(before_d, "f-0007")$label, "T.S07")
  expect_identical(lab_of(before_d, "f-0007")$kind, "systematic")
  on_d <- feature_labels(s$con, uuids = c("f-0002", "f-0007"), date = as.Date("2025-01-01"))
  expect_identical(lab_of(on_d, "f-0002")$label, "T.S02")
  expect_identical(lab_of(on_d, "f-0002")$kind, "systematic")
  expect_identical(lab_of(on_d, "f-0007")$label, "T.SN01")
  expect_identical(lab_of(on_d, "f-0007")$kind, "common")
  # never both at once
  expect_equal(sum(on_d$label == "T.SN01"), 1L)
  expect_equal(sum(before_d$label == "T.SN01"), 1L)
})

test_that("R-23.29: prefer = 'systematic' first gives feature.name even where a common name exists", {
  s <- t23_setup()
  res <- feature_labels(s$con, uuids = "f-0007", date = as.Date("2025-06-01"),
                        prefer = c("systematic", "common", "long"))
  expect_identical(res$label, "T.S07")
  expect_identical(res$kind, "systematic")
})

test_that("R-23.29: prefer = c('long', 'systematic') gives the long name where there is one, the systematic name otherwise", {
  s <- t23_setup()
  res <- feature_labels(s$con, uuids = c("f-0001", "f-0004"), date = as.Date("2025-06-01"),
                        prefer = c("long", "systematic"))
  expect_identical(lab_of(res, "f-0001")$label, "Test Surface 01")
  expect_identical(lab_of(res, "f-0001")$kind, "long")
  expect_identical(lab_of(res, "f-0004")$label, "T.S04")
  expect_identical(lab_of(res, "f-0004")$kind, "systematic")
})

test_that("R-23.29: the long name is read on the date too (a dated long row outside the date is skipped)", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "UPDATE feature_mask SET date_start = DATE '2026-01-01' WHERE uuid = 'fm-0001'")
  res <- feature_labels(s$con, uuids = "f-0001", date = as.Date("2025-06-01"), prefer = c("long", "systematic"))
  expect_identical(res$kind, "systematic")
  res2 <- feature_labels(s$con, uuids = "f-0001", date = as.Date("2026-06-01"), prefer = c("long", "systematic"))
  expect_identical(res2$kind, "long")
})

test_that("R-23.29: window ends are inclusive; a row whose window holds the date wins over others of the variant", {
  s <- t23_setup()
  DBI::dbExecute(s$con, "INSERT INTO feature_mask (uuid, uuid_feature, variant, name, date_start, date_end) VALUES
                         ('fm-l1', 'f-0004', 'common', 'T.C40', DATE '2020-01-01', DATE '2022-12-31'),
                         ('fm-l2', 'f-0004', 'common', 'T.C41', DATE '2023-01-01', NULL)")
  expect_identical(feature_labels(s$con, uuids = "f-0004", date = as.Date("2022-12-31"))$label, "T.C40")
  expect_identical(feature_labels(s$con, uuids = "f-0004", date = as.Date("2023-01-01"))$label, "T.C41")
  expect_identical(feature_labels(s$con, uuids = "f-0004", date = as.Date("2019-12-31"))$label, "T.S04")
})

test_that("R-23.29: uuids = NULL labels every feature, once each", {
  s <- t23_setup()
  res <- feature_labels(s$con, date = as.Date("2025-06-01"))
  all_f <- DBI::dbGetQuery(s$con, "SELECT uuid FROM feature")$uuid
  expect_setequal(res$uuid, all_f)
  expect_false(anyDuplicated(res$uuid) > 0)
  expect_identical(lab_of(res, "f-0007")$label, "T.SN01")
})

test_that("R-23.29: the date defaults to today", {
  s <- t23_setup()
  # T.SN01 is f-0007's from 2025-01-01, open: today it is still f-0007's.
  expect_identical(feature_labels(s$con, uuids = "f-0007")$label, "T.SN01")
})

test_that("R-23.29: the SQL twin .st_feature_label_sql is the same rule: it runs on the database and agrees with feature_labels() for the default prefer", {
  s <- t23_setup()
  sql <- .st_feature_label_sql
  # The twin is written for a given date; whichever placeholder it uses for the
  # date, it must not be a hard-coded one. We bind the date the way DBI does
  # for a single positional parameter.
  got <- tryCatch(DBI::dbGetQuery(s$con, sql, params = list(as.Date("2025-06-01"))), error = function(e) NULL)
  expect_false(is.null(got), info = "the label SQL must accept one date parameter")
  if (!is.null(got)) {
    expect_true(all(c("uuid", "label", "kind") %in% names(got)))
    want <- feature_labels(s$con, date = as.Date("2025-06-01"))
    m <- merge(want, got, by = "uuid", suffixes = c(".r", ".sql"))
    expect_equal(nrow(m), nrow(want))
    expect_identical(m$label.r, m$label.sql)
    expect_identical(m$kind.r, m$kind.sql)
  }
})
