# tests/testthat/test-crosstab-latin1.R
#
# 2026-10-19 corpus finding (PLAN-05 R-5.4a): 103 real ALS crosstabs (101
# als_xtab, 2 als_enmrg) are genuinely latin-1 - bare 0xB0 (degree), 0xB5
# (micro), 0xB1 (plus-minus) bytes - and every one ended `failed` with
# "input string N is invalid UTF-8" from gsub() inside normalise_lab_text().
# The crosstab CSV read is UTF-8 first (R-5.4); readr hands back the invalid
# bytes unconverted, and the mojibake probe in the encoding fallback runs
# normalise_lab_text() on them and aborts before the latin-1 alternate is
# ever tried.
#
# Decided behaviour: a primary read whose text is not valid UTF-8 is a
# damaged read; the fallback re-reads it as latin-1, and the parse of the
# latin-1 file equals the parse of its UTF-8 twin.
#
# Fixtures (anonymized real, byte-level ASCII only - REAL-FIXTURES.md):
#   corpus-2026-10-19/latin1/ES2422258_0_XTAB.csv     the latin-1 export (b0 b5 b1 b0)
#   corpus-2026-10-19/utf8-twin/ES2422258_0_XTAB.csv  the archived UTF-8 copy of the
#     same report (c2b0 c2b5 c2b1 c2b0); `iconv -f latin1` of the first is
#     byte-identical to it apart from a trailing newline.

xtab_adapter  <- function() sampleTidy:::adapter_registry()[["als_xtab"]]
enmrg_adapter <- function() sampleTidy:::adapter_registry()[["als_enmrg"]]

latin1_path <- test_path("fixtures", "corpus-2026-10-19", "latin1", "ES2422258_0_XTAB.csv")
twin_path   <- test_path("fixtures", "corpus-2026-10-19", "utf8-twin", "ES2422258_0_XTAB.csv")
enmrg_real_path <- test_path("fixtures", "crosstab", "ES2537534_0_ENMRG.CSV")

parse_xtab <- function(p) {
  suppressMessages(xtab_adapter()$parse(p, sampleTidy:::file_meta(p)))
}

# Every column that legitimately differs between two byte-different copies of
# the same report: the file hash (and nothing else).
drop_hash <- function(df) df[, setdiff(names(df), "source_hash"), drop = FALSE]

test_that("fixture precondition: the latin-1 file really is invalid UTF-8 and the twin is valid", {
  raw_l1 <- readBin(latin1_path, "raw", file.size(latin1_path))
  raw_u8 <- readBin(twin_path, "raw", file.size(twin_path))
  expect_true(any(raw_l1 == as.raw(0xb0)))
  expect_true(any(raw_l1 == as.raw(0xb5)))
  expect_false(validUTF8(rawToChar(raw_l1)))
  expect_true(validUTF8(rawToChar(raw_u8)))
})

test_that("R-5.4a: both copies are claimed by als_xtab", {
  expect_identical(xtab_adapter()$match(sampleTidy:::file_meta(latin1_path)), "format")
  expect_identical(xtab_adapter()$match(sampleTidy:::file_meta(twin_path)), "format")
})

test_that("R-5.4a: a genuinely latin-1 XTAB parses (no invalid-UTF-8 abort)", {
  expect_no_error(parse_xtab(latin1_path))
})

test_that("R-5.4a: the latin-1 XTAB parses equal to its UTF-8 twin (results and samples)", {
  l1 <- parse_xtab(latin1_path)
  u8 <- parse_xtab(twin_path)
  expect_equal(nrow(u8$results), 24) # sanity: the twin itself parses fully
  expect_equal(drop_hash(l1$results), drop_hash(u8$results))
  expect_equal(drop_hash(l1$samples), drop_hash(u8$samples))
})

test_that("R-5.4a: latin-1 degree/micro bytes decode to the real characters", {
  out <- parse_xtab(latin1_path)
  ec <- out$results[grepl("Conductivity", out$results$analyte_raw), ]
  expect_equal(nrow(ec), 1)
  expect_identical(ec$analyte_raw, "Electrical Conductivity @ 25°C")
  expect_identical(ec$units_raw, "µS/cm")
  tss <- out$results[grepl("^Suspended Solids", out$results$analyte_raw), ]
  expect_true(grepl("104 ± 2°C", tss$method_raw, fixed = TRUE))
})

test_that("R-5.4a: every text cell the latin-1 parse emits is valid UTF-8", {
  out <- parse_xtab(latin1_path)
  for (df in list(out$results, out$samples)) {
    chr <- unlist(df[vapply(df, is.character, logical(1))], use.names = FALSE)
    chr <- chr[!is.na(chr)]
    expect_true(all(validUTF8(chr)))
  }
})

test_that("R-5.4a: a latin-1 ENMRG parses equal to its UTF-8 original", {
  # The two failing ENMRG exports were latin-1 too. The committed ENMRG
  # fixture is UTF-8 and every char in it is latin-1-representable, so a
  # latin-1 transcoding of it is the same report in the failing encoding.
  l1 <- withr::local_tempdir()
  l1_path <- file.path(l1, basename(enmrg_real_path))
  txt <- readBin(enmrg_real_path, "raw", file.size(enmrg_real_path))
  conv <- iconv(list(txt), from = "UTF-8", to = "latin1", toRaw = TRUE)[[1]]
  expect_false(is.null(conv))
  writeBin(conv, l1_path)
  expect_false(validUTF8(rawToChar(conv))) # precondition: it has high bytes

  orig <- suppressMessages(enmrg_adapter()$parse(enmrg_real_path, sampleTidy:::file_meta(enmrg_real_path)))
  got <- expect_no_error(suppressMessages(enmrg_adapter()$parse(l1_path, sampleTidy:::file_meta(l1_path))))
  expect_equal(drop_hash(got$results), drop_hash(orig$results))
  expect_equal(drop_hash(got$samples), drop_hash(orig$samples))
})

# ---- the shared helper (R/read-encoding.R) ----------------------------------

test_that("R-5.4a: a primary read holding invalid UTF-8 is damaged: probe does not abort, latin-1 alternate adopted", {
  fallback <- sampleTidy:::.st_read_grid_with_encoding_fallback
  # What readr returns for a latin-1 file read under a UTF-8 locale: the raw
  # 0xB0 / 0xB5 bytes, flagged UTF-8, i.e. invalid UTF-8 strings.
  bad <- c("Electrical Conductivity @ 25\xb0C", "\xb5S/cm", "pH Value")
  Encoding(bad) <- "UTF-8"
  stopifnot(!all(validUTF8(bad)))
  good <- c("Electrical Conductivity @ 25°C", "µS/cm", "pH Value")
  primary_mat <- matrix(bad, ncol = 1)
  alt_mat <- matrix(good, ncol = 1)
  read_fn <- function(enc) if (identical(enc, "latin1")) alt_mat else primary_mat

  res <- NULL
  expect_no_error(suppressMessages(
    res <- fallback(read_fn, "UTF-8", "latin1", function(m) as.vector(m), "ES2422258_0_XTAB.csv")
  ))
  expect_identical(res, alt_mat)
})
