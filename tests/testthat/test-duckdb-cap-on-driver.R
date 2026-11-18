# duckdb 1.4 silently ignores `config` passed to DBI::dbConnect(); the memory
# cap only takes effect when given to the driver: duckdb::duckdb(config = ).
# These tests check what DuckDB itself reports, using temporary databases only.

cap_reported <- function(con) {
  DBI::dbGetQuery(con, "SELECT current_setting('memory_limit') AS v")$v
}

# "512MB" is reported as roughly 488 MiB.
cap_512_regex <- "^4[0-9]{2}(\\.[0-9])? MiB$"

# A fresh temp database, created read-write so read-only opens can follow.
local_seeded_db <- function(env = parent.frame()) {
  db <- withr::local_tempfile(fileext = ".duckdb", .local_envir = env)
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  DBI::dbDisconnect(con, shutdown = TRUE)
  db
}

test_that("st_connect(read_only = FALSE) enforces the cap", {
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  db <- withr::local_tempfile(fileext = ".duckdb")
  con <- st_connect(db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_match(cap_reported(con), cap_512_regex)
})

test_that("st_connect(read_only = TRUE) enforces the cap", {
  db <- local_seeded_db()
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  con <- st_connect(db, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_match(cap_reported(con), cap_512_regex)
})

test_that("with_db_write() enforces the cap", {
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  db <- withr::local_tempfile(fileext = ".duckdb")
  got <- with_db_write(cap_reported, db = db, max_wait = 0)
  expect_match(got, cap_512_regex)
})

test_that("the inbox read connection enforces the cap", {
  db <- local_seeded_db()
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  con <- .inbox_read_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_match(cap_reported(con), cap_512_regex)
})

# duckdb 1.4.1 ignores dbConnect(config=) for an in-memory database (file
# databases happen to honour it), so these are the cases that fail today.
test_that("st_connect() enforces the cap on an in-memory database", {
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  con <- st_connect(":memory:", read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_match(cap_reported(con), cap_512_regex)
})

test_that("with_db_write() enforces the cap on an in-memory database", {
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  got <- with_db_write(cap_reported, db = ":memory:", max_wait = 0)
  expect_match(got, cap_512_regex)
})

test_that("with the option 'none' the connection is not capped to 512MB", {
  withr::local_options(sampleTidy.duckdb_memory_limit = "none")
  db <- withr::local_tempfile(fileext = ".duckdb")
  con <- st_connect(db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_no_match(cap_reported(con), cap_512_regex)
  # DuckDB's own default for a plain connection
  ref_db <- withr::local_tempfile(fileext = ".duckdb")
  ref <- DBI::dbConnect(duckdb::duckdb(), ref_db)
  withr::defer(DBI::dbDisconnect(ref, shutdown = TRUE))
  expect_equal(cap_reported(con), cap_reported(ref))
})

# Source guard. Comments and strings are blanked, then for every
# `dbConnect(duckdb::duckdb(...), ...)` we look for `config =` among the
# arguments of dbConnect() outside the duckdb::duckdb(...) call.
test_that("no R/ source passes config to dbConnect() with a duckdb driver", {
  r_dir <- testthat::test_path("..", "..", "R")
  skip_if_not(dir.exists(r_dir), "R/ source not available")

  match_close <- function(chars, open) {
    depth <- 0L
    for (i in seq(open, length(chars))) {
      if (chars[i] == "(") depth <- depth + 1L
      if (chars[i] == ")") {
        depth <- depth - 1L
        if (depth == 0L) return(i)
      }
    }
    length(chars)
  }

  offenders <- character()
  for (f in list.files(r_dir, pattern = "[.][Rr]$", full.names = TRUE)) {
    lines <- readLines(f, warn = FALSE)
    lines <- sub("#.*$", "", lines)
    lines <- gsub('"[^"]*"', '""', lines)
    txt <- paste(lines, collapse = "\n")
    starts <- gregexpr("dbConnect\\(\\s*duckdb::duckdb\\(", txt)[[1]]
    if (starts[1] == -1L) next
    chars <- strsplit(txt, "")[[1]]
    for (s in starts) {
      open <- s + nchar("dbConnect") # index of dbConnect's "("
      close <- match_close(chars, open)
      drv_open <- open + regexpr("duckdb::duckdb\\(", substr(txt, open, close)) +
        nchar("duckdb::duckdb") - 1L
      drv_close <- match_close(chars, drv_open)
      outer <- paste0(
        substr(txt, open, drv_open - 1L),
        substr(txt, drv_close + 1L, close)
      )
      if (grepl("\\bconfig\\s*=", outer)) {
        line_no <- lengths(regmatches(substr(txt, 1, s), gregexpr("\n", substr(txt, 1, s)))) + 1L
        offenders <- c(offenders, sprintf("%s:%d", basename(f), line_no))
      }
    }
  }
  expect_equal(offenders, character())
})
