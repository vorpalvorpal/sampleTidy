# PLAN-19 phase 1, the small pure pieces: R-19.4 `.qc_features(con)`, R-19.6
# `.qc_norm_lab_id()` and R-19.14 `.qc_secondary_type()`.
#
# Codes and parents are invented (site Q; helper-qc.R).

.qc_features_cols <- c("uuid_feature", "name", "site", "qc_type", "uuid_parent", "parent_name",
                       "date_start", "date_end")

test_that("R-19.4 .qc_features(con): one row per qc_feature, with names, site, parent and dates", {
  db <- qc_db()
  ids <- list()
  fl_with(db, function(con) {
    ids$jd <<- qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2026-09-01",
                      date_end = "2028-06-30")
    ids$ja <<- qc_add(con, "Q.JA00", "source_blank")
    ids$x01 <<- fl_one(con, "SELECT uuid FROM feature WHERE name = 'Q.X01'")
  })
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  q <- sampleTidy:::.qc_features(con)
  expect_s3_class(q, "data.frame")
  expect_identical(names(q), .qc_features_cols)
  expect_equal(nrow(q), 2)
  q <- q[order(q$name), , drop = FALSE]
  expect_identical(q$name, c("Q.JA00", "Q.JD42"))
  expect_identical(q$uuid_feature, c(ids$ja, ids$jd))
  expect_identical(q$site, c("Q", "Q"))
  expect_identical(q$qc_type, c("source_blank", "duplicate"))
  expect_identical(q$uuid_parent, c(NA, ids$x01))
  expect_identical(q$parent_name, c(NA, "Q.X01"))
  expect_s3_class(q$date_start, "Date")
  expect_identical(q$date_start, as.Date(c("2026-09-01", "2026-09-01")))
  expect_identical(q$date_end, as.Date(c(NA, "2028-06-30")))
})

test_that("R-19.4 .qc_features(con): no qc_feature table -> zero rows, same columns", {
  # [invented: the plan says a missing table means "no rows and no error" for
  #  the checks; .qc_features() is where that is decided.]
  db <- qc_db(tables = FALSE)
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  q <- sampleTidy:::.qc_features(con)
  expect_identical(names(q), .qc_features_cols)
  expect_equal(nrow(q), 0)
})

test_that("R-19.6 .qc_norm_lab_id(): the three corpus spellings normalise to <WO>-<nnn>", {
  norm <- sampleTidy:::.qc_norm_lab_id
  expect_identical(norm(c("ES2626883001", "ES2609437-001", "ES2609442--001")),
                   c("ES2626883-001", "ES2609437-001", "ES2609442-001"))
  # other ALS branch prefixes seen in QCI (EN, ED, EM), surrounding whitespace
  expect_identical(norm(c("EN2600123--012", " ED2600456-003 ", "EM2600789007")),
                   c("EN2600123-012", "ED2600456-003", "EM2600789-007"))
  # [invented: anything that is not a lab number - an ACIRL synthetic id, a QC
  #  lot, '----', empty, NA - normalises to NA]
  expect_identical(norm(c("Sampling Sites 1!c4", "QC-MRG2-4858132002", "----", "", NA)),
                   rep(NA_character_, 5))
})

test_that("R-19.14 .qc_secondary_type(): case-insensitive, trimmed label -> qc_type; anything else NA", {
  st <- sampleTidy:::.qc_secondary_type
  x <- c("Field Blank", "Trip Blank", "Transport Blank", "Rinsate Blank", "Equipment Blank",
         "Filter Blank", "Lab Blank", "Duplicate", "Field Duplicate", "Dup")
  expect_identical(st(x), c("field_blank", "transport_blank", "transport_blank", "rinsate_blank",
                            "rinsate_blank", "filter_blank", "source_blank", "duplicate",
                            "duplicate", "duplicate"))
  expect_identical(st(c("  field blank ", "TRIP BLANK", "dUp")),
                   c("field_blank", "transport_blank", "duplicate"))
  expect_identical(st(c("12", "23", "Sealed", "Blank", "", NA)), rep(NA_character_, 6))
})
