# Memory cap on every DuckDB connection. DuckDB's own default is 80% of RAM,
# which on a small machine can exhaust memory. `st_duckdb_config()` supplies
# the `config` list for every connection the package opens.

# NB: duckdb 1.4 ignores `config` in dbConnect() for an in-memory database;
# the config therefore goes to the driver, duckdb::duckdb(config = ).
# What DuckDB itself reports for a plain connection opened with `limit`
# (DuckDB reformats the value, e.g. "1.8 GiB", so never compare strings
# against the input).
duckdb_reported_limit <- function(limit = NULL) {
  config <- if (is.null(limit)) list() else list(memory_limit = limit)
  db <- tempfile(fileext = ".duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(config = config), dbdir = db)
  on.exit({
    DBI::dbDisconnect(con, shutdown = TRUE)
    unlink(c(db, paste0(db, ".wal")))
  }, add = TRUE)
  DBI::dbGetQuery(con, "SELECT current_setting('memory_limit') AS v")$v
}

reported_limit <- function(con) {
  DBI::dbGetQuery(con, "SELECT current_setting('memory_limit') AS v")$v
}

# Clear both sources so each test states exactly what it sets.
local_no_limit_sources <- function(env = parent.frame()) {
  withr::local_options(sampleTidy.duckdb_memory_limit = NULL, .local_envir = env)
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = NA, .local_envir = env)
}

test_that("st_duckdb_config() defaults to 2GB", {
  local_no_limit_sources()
  expect_equal(st_duckdb_config()$memory_limit, "2GB")
})

test_that("st_duckdb_config() reads the environment variable", {
  local_no_limit_sources()
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "1GB")
  expect_equal(st_duckdb_config()$memory_limit, "1GB")
})

test_that("st_duckdb_config() reads the option", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  expect_equal(st_duckdb_config()$memory_limit, "512MB")
})

test_that("the option wins over the environment variable", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "512MB")
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "1GB")
  expect_equal(st_duckdb_config()$memory_limit, "512MB")
})

test_that("an empty environment variable falls through to the default", {
  local_no_limit_sources()
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "")
  expect_equal(st_duckdb_config()$memory_limit, "2GB")
})

test_that("'none' in the option omits memory_limit", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "none")
  cfg <- st_duckdb_config()
  expect_type(cfg, "list")
  expect_false("memory_limit" %in% names(cfg))
})

test_that("'none' in the environment variable omits memory_limit", {
  local_no_limit_sources()
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "none")
  expect_false("memory_limit" %in% names(st_duckdb_config()))
})

test_that("'none' in the option beats a limit in the environment variable", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "none")
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "1GB")
  expect_false("memory_limit" %in% names(st_duckdb_config()))
})

test_that("a limit in the option beats 'none' in the environment variable", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "1GB")
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "none")
  expect_equal(st_duckdb_config()$memory_limit, "1GB")
})

test_that("st_duckdb_config() is exported", {
  expect_true("st_duckdb_config" %in% getNamespaceExports("sampleTidy"))
})

test_that("st_connect(read_only = FALSE) applies the default cap", {
  local_no_limit_sources()
  db <- withr::local_tempfile(fileext = ".duckdb")
  con <- st_connect(db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(reported_limit(con), duckdb_reported_limit("2GB"))
  expect_false(identical(reported_limit(con), duckdb_reported_limit(NULL)))
})

test_that("st_connect(read_only = TRUE) applies the cap", {
  local_no_limit_sources()
  db <- withr::local_tempfile(fileext = ".duckdb")
  rw <- st_connect(db, read_only = FALSE)
  DBI::dbDisconnect(rw, shutdown = TRUE)

  withr::local_options(sampleTidy.duckdb_memory_limit = "1GB")
  con <- st_connect(db, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(reported_limit(con), duckdb_reported_limit("1GB"))
})

test_that("st_connect() honours the environment variable", {
  local_no_limit_sources()
  withr::local_envvar(SAMPLETIDY_DUCKDB_MEMORY_LIMIT = "768MB")
  db <- withr::local_tempfile(fileext = ".duckdb")
  con <- st_connect(db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(reported_limit(con), duckdb_reported_limit("768MB"))
})

test_that("st_connect() with 'none' leaves DuckDB's own default", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "none")
  db <- withr::local_tempfile(fileext = ".duckdb")
  con <- st_connect(db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(reported_limit(con), duckdb_reported_limit(NULL))
})

test_that("with_db_write() connects with the cap", {
  local_no_limit_sources()
  withr::local_options(sampleTidy.duckdb_memory_limit = "1GB")
  db <- withr::local_tempfile(fileext = ".duckdb")
  got <- with_db_write(reported_limit, db = db, max_wait = 0)
  expect_equal(got, duckdb_reported_limit("1GB"))
})

test_that("no R/ source passes the config to dbConnect() instead of the driver", {
  r_dir <- testthat::test_path("..", "..", "R")
  skip_if_not(dir.exists(r_dir), "R/ source not available")
  offenders <- character()
  for (f in list.files(r_dir, pattern = "[.][Rr]$", full.names = TRUE)) {
    lines <- readLines(f, warn = FALSE)
    code <- sub("#.*$", "", lines) # blank comments, incl. roxygen
    hits <- grep("dbConnect\\(\\s*duckdb::duckdb\\(", code)
    for (i in hits) {
      window <- paste(code[i:min(i + 4L, length(code))], collapse = " ")
      if (!grepl("duckdb::duckdb\\(\\s*config\\s*=\\s*st_duckdb_config\\(\\)",
                 window)) {
        offenders <- c(offenders, sprintf("%s:%d", basename(f), i))
      }
    }
  }
  expect_equal(offenders, character())
})
