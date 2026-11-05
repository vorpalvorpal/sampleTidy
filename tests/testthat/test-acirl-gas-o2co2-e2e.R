# tests/testthat/test-acirl-gas-o2co2-e2e.R
#
# End-to-end: a gas workbook with CH4, O2 and CO2 columns, ingested into a
# throwaway seed DB (analytes O2 / CO2 and their ACIRL field lab_methods seeded
# as bmcc migration 105 did, beside CH4). Each probe row must become ONE
# sample carrying three analyses.

test_that("each row is one sample with three analyses (CH4, O2, CO2)", {
  db <- gxo_db_setup()
  gxo_ingest(db)
  con <- gxo_ro(db)
  for (u in names(gxo_features)) {
    a <- gxo_analyses_at(con, u)
    expect_equal(nrow(a), 3, info = u)
    expect_setequal(a$uuid_lab, c("lm-ch4", "lm-o2", "lm-co2"))
    expect_equal(length(unique(a$uuid_sample)), 1, info = u)
  }
  n_samples <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM \"sample\" s
                                       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                                      WHERE fa.uuid_feature IN ('f-g182', 'f-g183')")$n
  expect_equal(n_samples, 2)
})

test_that("O2 20.9 % is stored as 0.209 L/L, quantified", {
  db <- gxo_db_setup()
  gxo_ingest(db)
  con <- gxo_ro(db)
  a <- gxo_analyses_at(con, "f-g182")
  o2 <- a[a$uuid_lab == "lm-o2", ]
  expect_equal(nrow(o2), 1)
  expect_true(abs(o2$value - 0.209) < 1e-12)
  expect_true(o2$quantified)
  c2 <- gxo_analyses_at(con, "f-g183")
  expect_true(abs(c2$value[c2$uuid_lab == "lm-co2"] - 0.015) < 1e-12)
  expect_true(abs(c2$value[c2$uuid_lab == "lm-ch4"] - 3e-4) < 1e-12)
})

test_that("an O2 or CO2 zero is a non-detect taking its lab_method rl_low", {
  db <- gxo_db_setup()
  gxo_ingest(db)
  con <- gxo_ro(db)
  z <- gxo_analyses_at(con, "f-g183")
  o2 <- z[z$uuid_lab == "lm-o2", ]               # O2 0
  expect_identical(o2$value, 0)
  expect_false(o2$quantified)
  expect_equal(o2$rl_low, 0.001)
  z2 <- gxo_analyses_at(con, "f-g182")
  co2 <- z2[z2$uuid_lab == "lm-co2", ]           # CO2 0
  expect_identical(co2$value, 0)
  expect_false(co2$quantified)
  expect_equal(co2$rl_low, 1e-4)
  ch4 <- z2[z2$uuid_lab == "lm-ch4", ]           # CH4 0 (unchanged behaviour)
  expect_false(ch4$quantified)
  expect_equal(ch4$rl_low, 1e-4)
})

test_that("all analyses of a row share the sample's day (Sydney) and a NULL datetime", {
  db <- gxo_db_setup()
  gxo_ingest(db)
  con <- gxo_ro(db)
  a <- gxo_analyses_at(con, "f-g182")
  expect_equal(nrow(a), 3)
  expect_equal(length(unique(a$date)), 1)
  expect_identical(as.character(as.Date(format(a$date[[1]], tz = "Australia/Sydney"))), gxo_sample_date)
  expect_true(all(is.na(a$datetime)))
})
