# PLAN-19 section 3 (R-19.10, R-19.12, R-19.13): the QC code -> point table is
# confidential and is never in git. These tests guard the repository itself,
# so they need the source tree and git; they skip in an installed-package
# check (no .git, no dev/).

repo_root <- function() normalizePath(test_path("..", ".."), mustWork = FALSE)

git_files <- function(root) {
  out <- tryCatch(system2("git", c("-C", shQuote(root), "-c", "core.quotepath=off", "ls-files"),
                          stdout = TRUE, stderr = FALSE),
                  error = function(e) NULL, warning = function(w) NULL)
  if (is.null(out) || length(out) == 0) return(NULL)
  out[nzchar(out)]
}

# A real-looking code (B.JD/B.JF/B.JR + two digits, not 00) within 200
# characters of a real point name (B.MW/B.S/B.L/B.E/B.CW + a digit).
.qc_code_re <- "B\\.J[DFR](?!00)[0-9]{2}"
.qc_point_re <- "B\\.(MW|S|L|E|CW)[0-9]"

qc_pairing_hits <- function(text) {
  m <- gregexpr(.qc_code_re, text, perl = TRUE)[[1]]
  if (m[[1]] == -1) return(character(0))
  hits <- character(0)
  for (i in seq_along(m)) {
    lo <- max(1L, m[[i]] - 200L)
    hi <- min(nchar(text, type = "bytes"), m[[i]] + attr(m, "match.length")[[i]] - 1L + 200L)
    win <- substr(text, lo, hi)
    if (grepl(.qc_point_re, win, perl = TRUE)) hits <- c(hits, substr(text, m[[i]], m[[i]] + 5L))
  }
  hits
}

test_that("R-19.13 lint: the pairing detector itself finds a pairing and ignores the safe shapes", {
  # Built by paste0 so this file never contains the pattern it forbids.
  code <- paste0("B.J", "D", "57")
  expect_length(qc_pairing_hits(paste0(code, " -> ", "B.MW", "04")), 1)
  expect_length(qc_pairing_hits(paste0(code, strrep(" ", 250), "B.MW", "04")), 0)
  expect_length(qc_pairing_hits(paste0("B.J", "D", "00 -> B.MW", "04")), 0)
  expect_length(qc_pairing_hits(paste0("B.JDxx -> B.MW", "04")), 0)
  expect_length(qc_pairing_hits(paste0("Q.J", "D", "57 -> Q.MW", "04")), 0)
})

test_that("R-19.13 lint: no committed file pairs a real-looking B.J code with a real point", {
  root <- repo_root()
  files <- git_files(root)
  skip_if(is.null(files), "not a git checkout")
  bad <- character(0)
  for (f in files) {
    p <- file.path(root, f)
    if (!file.exists(p) || dir.exists(p)) next
    sz <- file.size(p)
    if (is.na(sz) || sz == 0 || sz > 20e6) next
    raw <- readBin(p, "raw", sz)
    if (any(raw == as.raw(0))) next                     # binary
    text <- rawToChar(raw)
    Encoding(text) <- "bytes"
    h <- qc_pairing_hits(text)
    if (length(h)) bad <- c(bad, sprintf("%s: %s", f, paste(unique(h), collapse = ", ")))
  }
  expect_identical(bad, character(0))
})

test_that("R-19.12: .gitignore backstops the codes CSV and migration 049's backups", {
  gi <- file.path(repo_root(), ".gitignore")
  skip_if_not(file.exists(gi), "no .gitignore (installed package)")
  lines <- trimws(readLines(gi, warn = FALSE))
  for (pat in c("qc-codes*.csv", "**/qc-codes*.csv", "dev/migrations/049-*-BACKUP-*.csv")) {
    expect_true(pat %in% lines, label = pat)
  }
})

test_that("R-19.13: the committed fake codes table uses only the invented site Q and invented parents", {
  p <- test_path("fixtures", "qc", "qc-codes-FAKE.csv")
  d <- utils::read.csv(p, colClasses = "character", na.strings = character(0))
  expect_identical(names(d), c("code", "qc_type", "parent", "date_start", "comments"))
  expect_equal(nrow(d), 92)                                  # 30 points x 3 + 2
  expect_true(all(grepl("^Q\\.J[A-Z][0-9]{2}$", d$code)))
  expect_true(all(d$parent == "" | grepl("^Q\\.X[0-9]{2}$", d$parent)))
  expect_equal(sum(d$parent == ""), 2)
})
