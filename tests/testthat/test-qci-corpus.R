# PLAN-19 phase 1b calibration: the QCI parser on the REAL corpus must
# reproduce PLAN-19 Appendix A's counts (the known positive), before migration
# 052 runs on a copy of live (section 8/9).
#
# Gated: skipped unless SAMPLETIDY_QCI_CORPUS (or R-19.18's spelling,
# SAMPLETIDY_QC_CORPUS) names a local folder holding the QCI PDFs, e.g. a
# HYDRATED copy of `.../waste_data - Environmental monitoring/assets/` (both
# `processed/` and `unprocessed/`; searched recursively). Never point it at the
# OneDrive Files-On-Demand tree itself: reading 171 PDFs there downloads them.
#
# Method, as Appendix A.1: every `*_QCI*.pdf`, one per distinct file NAME
# (171 files, 167 names - bracketed copies such as `ES2503947_0_QCI[41].pdf`
# are distinct names), read with pdftools::pdf_text() exactly as
# lab_qc_ingest() reads it, then `.qci_parse()`. One name (ES2607384, 0 bytes)
# is unreadable, so the counts are over 166 files.

qci_corpus_dir <- function() {
  d <- Sys.getenv("SAMPLETIDY_QCI_CORPUS", Sys.getenv("SAMPLETIDY_QC_CORPUS", ""))
  if (!nzchar(d) || !dir.exists(d)) {
    testthat::skip("SAMPLETIDY_QCI_CORPUS not set to a local folder of QCI PDFs")
  }
  d
}

qci_corpus_parse <- function(dir) {
  files <- list.files(dir, pattern = "_QCI.*\\.pdf$", recursive = TRUE, full.names = TRUE,
                      ignore.case = TRUE)
  files <- files[!duplicated(basename(files))]
  lapply(files, function(p) {
    lines <- tryCatch({
      pages <- suppressMessages(pdftools::pdf_text(p))
      strsplit(paste(pages, collapse = "\f"), "\n", fixed = TRUE)[[1]]
    }, error = function(e) NULL)
    res <- if (is.null(lines)) NULL else .qci_parse(lines)
    list(file = basename(p), wo = substr(basename(p), 1, 9), res = res)
  })
}

test_that("Appendix A: the QCI parser reproduces the corpus counts", {
  dir <- qci_corpus_dir()
  all <- qci_corpus_parse(dir)

  # A.1 inventory
  expect_equal(length(all), 167)
  ok <- Filter(function(x) !is.null(x$res), all)
  expect_equal(length(ok), 166)
  bad <- vapply(Filter(function(x) is.null(x$res), all), `[[`, "", "file")
  expect_identical(bad, "ES2607384_0_QCI.pdf")

  # A.2 Summary-of-Outliers bullets: exactly one of each pair per file.
  sm <- do.call(rbind, lapply(ok, function(x) qci_summary(x$res)))
  expect_false(anyNA(sm))
  expect_equal(colSums(sm),
               c(mb = 0, dup = 0, lcs = 12, ms = 108, surrogate = 0, holding_time = 143,
                 frequency = 76))
  expect_true(all(vapply(ok, function(x) length(x$res$warnings) == 0, logical(1))))

  o <- do.call(rbind, lapply(ok, function(x) {
    d <- as.data.frame(x$res$outliers, stringsAsFactors = FALSE)
    if (nrow(d) == 0) return(NULL)
    data.frame(file = x$file, wo = x$wo, kind = d$kind, method = d$method,
               analyte_raw = d$analyte_raw, lab_id = d$lab_id, client_id = d$client_id,
               value_pct = d$value_pct, limit_low = d$limit_low, limit_high = d$limit_high,
               comment = d$comment, days_overdue = d$days_overdue, stringsAsFactors = FALSE)
  }))

  # 159 of 166 have an MS, LCS or holding-time outlier; these 7 have none.
  with_any <- unique(o$wo[o$kind %in% c("ms", "lcs", "holding_time")])
  none <- setdiff(vapply(ok, `[[`, "", "wo"), with_any)
  expect_setequal(none, c("ES2014537", "ES2015000", "ES2026608", "ES2028902", "ES2311620",
                          "ES2314145", "ES2609416"))
  expect_equal(sum(vapply(ok, function(x) x$wo %in% with_any, logical(1))), 159)

  # A.2/A.3 LCS: 13 rows in these 12 files; 11 EC low, 2 TKN high; no lab ID.
  lcs <- o[o$kind == "lcs", , drop = FALSE]
  expect_equal(nrow(lcs), 13)
  expect_setequal(unique(lcs$wo), c("ES2011067", "ES2011595", "ES2027610", "ES2027611",
                                    "ES2027719", "ES2027720", "ES2028155", "ES2028156",
                                    "ES2028157", "ES2028911", "ES2303512", "ES2401369"))
  expect_equal(sum(lcs$method == "EA010P" & lcs$value_pct < lcs$limit_low), 11)
  expect_true(all(lcs$value_pct[lcs$method == "EA010P"] >= 89.8 &
                    lcs$value_pct[lcs$method == "EA010P"] <= 94.2))
  expect_equal(sum(lcs$method == "EK061G" & lcs$value_pct > lcs$limit_high), 2)
  expect_true(all(is.na(lcs$lab_id)))

  # A.3 MS: 184 rows, 176 not determined, 8 numeric - all on Anonymous samples.
  ms <- o[o$kind == "ms", , drop = FALSE]
  expect_equal(nrow(ms), 184)
  expect_equal(sum(is.na(ms$value_pct)), 176)
  expect_equal(sum(grepl("^MS recovery not determined", ms$comment)), 176)
  num <- ms[!is.na(ms$value_pct), , drop = FALSE]
  expect_equal(nrow(num), 8)
  expect_true(all(num$client_id == "Anonymous"))
  expect_true(all(num$comment == "Recovery less than lower data quality objective"))
  expect_equal(sum(num$wo == "ES2519223"), 5)
  # 24 MS rows on our own samples (lab ID in the file's own work order), in 17
  # work orders, every one "not determined"; 160 on other work orders' samples.
  own <- ms[!is.na(ms$lab_id) & substr(ms$lab_id, 1, 9) == ms$wo, , drop = FALSE]
  expect_equal(nrow(own), 24)
  expect_equal(length(unique(own$wo)), 17)
  expect_true(all(is.na(own$value_pct)))
  # Lab sample ID prefixes, all normalised to <WO>-<nnn>.
  expect_true(all(grepl("^E[A-Z][0-9]{7}-[0-9]{3}$", ms$lab_id)))
  expect_equal(as.vector(table(factor(substr(ms$lab_id, 1, 2), c("ES", "EN", "ED", "EM")))),
               c(164, 12, 7, 1))

  # A.4 holding time: method blocks = distinct (file, method).
  ht <- o[o$kind == "holding_time", , drop = FALSE]
  expect_equal(length(unique(ht$file)), 143)
  blocks <- unique(ht[, c("file", "method")])
  tb <- table(blocks$method)
  expect_equal(as.vector(tb[c("EA005P", "EP030", "EK057G", "EK071G", "ED093F", "EA065",
                              "EA006", "EP005", "EA025", "EP080/071", "EK067G", "EK061G",
                              "EK059G", "EK055G", "EA015")]),
               c(137, 44, 22, 17, 8, 8, 8, 4, 3, 2, 2, 1, 1, 1, 1))
  expect_equal(nrow(blocks), 259)
  expect_equal(length(unique(blocks$file[blocks$method != "EA005P"])), 66)
  expect_equal(range(as.integer(ht$days_overdue)), c(1L, 16L))
  expect_equal(nrow(unique(ht[, c("wo", "client_id")])), 412)

  # A.5 frequency outliers in 76 files.
  expect_equal(length(unique(o$file[o$kind == "frequency"])), 76)
})
