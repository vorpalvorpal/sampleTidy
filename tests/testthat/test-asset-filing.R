# PLAN-20 phase 1, P20.5: external filing records - the asset_filing table
# (ensure_schema ops-schema version 9), register_filing() and filed_assets().
# Spec: dev/plans/PLAN-20-phase1-spec.md section P20.5.

af_cols <- c("uuid_asset", "system", "external_id", "external_uri", "container",
             "filed_at", "title", "comments")

# A seed DB (ensure_schema has run, so it has asset_filing once version 9 exists)
# with two assets.
af_db <- function(env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "INSERT INTO asset (uuid, uuid_project, filename, hash) VALUES
    ('as-1', 'p-0001', 'one.csv', 'h-one'), ('as-2', 'p-0001', 'two.csv', 'h-two')")
  db
}

af_q <- function(db, sql, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = list(...))
}

af_rows <- function(db) af_q(db, "SELECT * FROM asset_filing ORDER BY uuid_asset, system")

af_log <- function(db) {
  af_q(db, "SELECT * FROM change_log WHERE tbl = 'asset_filing' ORDER BY \"at\", uuid")
}

af_n_log <- function(db) af_q(db, "SELECT count(*) AS n FROM change_log")$n

af_utc <- function(x) as.POSIXct(x, tz = "UTC")

# ---- the table (ensure_schema version 9) -------------------------------------------------

test_that("P20.5: ensure_schema() creates asset_filing on a BARE database (no asset table), columns in spec order", {
  db <- file.path(withr::local_tempdir(), "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)
  expect_true("asset_filing" %in% DBI::dbListTables(con))
  expect_false("asset" %in% DBI::dbListTables(con))
  cols <- DBI::dbGetQuery(con, "SELECT column_name, data_type, is_nullable
                                  FROM information_schema.columns
                                 WHERE table_name = 'asset_filing' ORDER BY ordinal_position")
  expect_identical(cols$column_name, af_cols)
  expect_identical(cols$data_type, c("VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR", "VARCHAR",
                                     "TIMESTAMP", "VARCHAR", "VARCHAR"))
  expect_identical(cols$is_nullable,
                   c("NO", "NO", "NO", "YES", "YES", "NO", "YES", "YES"))
})

test_that("P20.5: asset_filing is created empty and records ops-schema version 9", {
  db <- file.path(withr::local_tempdir(), "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset_filing")$n, 0)
  expect_true(9 %in% DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version)
})

test_that("P20.5: the migration ladder is versions 1..9, strictly ascending in list order", {
  ns <- asNamespace("sampleTidy")
  versions <- vapply(get(".st_schema_migrations", envir = ns), function(m) m$version, integer(1))
  expect_identical(versions, 1:9)
})

test_that("P20.5: the primary key is (uuid_asset, system)", {
  db <- file.path(withr::local_tempdir(), "bare.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)
  ins <- function(a, s) DBI::dbExecute(con, sprintf(
    "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
     VALUES ('%s', '%s', 'x', TIMESTAMP '2026-10-01 00:00:00')", a, s))
  ins("a1", "TRIM")
  expect_error(ins("a1", "TRIM"))        # same key twice
  expect_no_error(ins("a1", "SharePoint"))  # same asset, other system
  expect_no_error(ins("a2", "TRIM"))        # other asset, same system
  # NOT NULL on the key and on external_id / filed_at
  expect_error(DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                                    VALUES (NULL, 'S', 'x', TIMESTAMP '2026-10-01 00:00:00')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                                    VALUES ('a3', 'S', NULL, TIMESTAMP '2026-10-01 00:00:00')"))
  expect_error(DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                                    VALUES ('a3', 'S', 'x', NULL)"))
})

test_that("P20.5: no declared foreign key - filings can be written on a bare DB and an asset can still be deleted", {
  db <- af_db()
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                       VALUES ('as-1', 'TRIM', 'x', TIMESTAMP '2026-10-01 00:00:00')")
  expect_no_error(DBI::dbExecute(con, "DELETE FROM asset WHERE uuid = 'as-1'"))
})

test_that("P20.5: ensure_schema() re-applies version 9 on a DB that lacks it, and a second call is a no-op", {
  db <- af_db()
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "DROP TABLE asset_filing")
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 9")
  ensure_schema(con)
  expect_true("asset_filing" %in% DBI::dbListTables(con))
  expect_true(9 %in% DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version)
  v1 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  expect_no_error(ensure_schema(con))
  expect_identical(DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version, v1)
})

test_that("P20.5: ensure_schema() keeps existing asset_filing rows", {
  db <- af_db()
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
                       VALUES ('as-1', 'TRIM', 'x', TIMESTAMP '2026-10-01 00:00:00')")
  DBI::dbExecute(con, "DELETE FROM schema_version WHERE version = 9")
  ensure_schema(con)
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset_filing")$n, 1)
})

# ---- register_filing(): insert -----------------------------------------------------------

test_that("P20.5 register_filing(): a new (asset, system) is inserted; returns 'inserted' invisibly; the row holds what was passed", {
  db <- af_db()
  at <- af_utc("2026-10-02 03:04:05")
  v <- withVisible(register_filing(db, uuid_asset = "as-1", system = "TRIM", external_id = "26/154397",
                                   external_uri = "https://trim.example/26-154397",
                                   container = "F17440", filed_at = at,
                                   title = "ES2600001 results", comments = "filed by hand"))
  expect_false(v$visible)
  expect_identical(v$value, "inserted")
  r <- af_rows(db)
  expect_identical(nrow(r), 1L)
  expect_identical(names(r), af_cols)
  expect_identical(r$uuid_asset, "as-1")
  expect_identical(r$system, "TRIM")
  expect_identical(r$external_id, "26/154397")
  expect_identical(r$external_uri, "https://trim.example/26-154397")
  expect_identical(r$container, "F17440")
  expect_equal(as.numeric(r$filed_at), as.numeric(at))
  expect_identical(r$title, "ES2600001 results")
  expect_identical(r$comments, "filed by hand")
})

test_that("P20.5 register_filing(): the optional fields default to NULL in the table", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "26/154397")
  r <- af_rows(db)
  expect_true(is.na(r$external_uri))
  expect_true(is.na(r$container))
  expect_true(is.na(r$title))
  expect_true(is.na(r$comments))
})

test_that("P20.5 register_filing(): filed_at = NULL on insert stores the current time", {
  db <- af_db()
  before <- Sys.time()
  register_filing(db, "as-1", "TRIM", "26/154397")
  after <- Sys.time()
  at <- as.numeric(af_rows(db)$filed_at)
  expect_gte(at, as.numeric(before) - 2)
  expect_lte(at, as.numeric(after) + 2)
})

test_that("P20.5 register_filing(): a filed_at in another time zone is stored as the same instant", {
  db <- af_db()
  at <- as.POSIXct("2026-10-02 13:04:05", tz = "Australia/Sydney")
  register_filing(db, "as-1", "TRIM", "x", filed_at = at)
  expect_equal(as.numeric(af_rows(db)$filed_at), as.numeric(at))
})

test_that("P20.5 register_filing(): one asset may be filed in several systems, and one system holds several assets", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "t1")
  register_filing(db, "as-1", "SharePoint", "s1")
  register_filing(db, "as-2", "TRIM", "t2")
  r <- af_rows(db)
  expect_identical(nrow(r), 3L)
  expect_identical(paste(r$uuid_asset, r$system), c("as-1 SharePoint", "as-1 TRIM", "as-2 TRIM"))
})

test_that("P20.5 register_filing(): the system is any non-empty string, stored verbatim (case-sensitive, never interpreted)", {
  db <- af_db()
  odd <- c("TRIM", "trim", "Some System / v2 ü", " padded ", "a'b\"c")
  for (s in odd) expect_identical(register_filing(db, "as-1", s, paste0("id-", s)), "inserted")
  r <- af_rows(db)
  expect_setequal(r$system, odd)
  expect_identical(nrow(r), length(odd))
})

# ---- register_filing(): update / unchanged ------------------------------------------------

test_that("P20.5 register_filing(): re-registering the identical filing returns 'unchanged', invisibly, and writes nothing", {
  db <- af_db()
  at <- af_utc("2026-10-02 03:04:05")
  args <- list(db, "as-1", "TRIM", "26/154397", external_uri = "u", container = "c",
               filed_at = at, title = "t", comments = "k")
  do.call(register_filing, args)
  rows0 <- af_rows(db)
  n0 <- af_n_log(db)
  v <- withVisible(do.call(register_filing, args))
  expect_false(v$visible)
  expect_identical(v$value, "unchanged")
  expect_identical(af_rows(db), rows0)
  expect_identical(af_n_log(db), n0)
})

test_that("P20.5 register_filing(): with filed_at = NULL the stored filed_at is kept, so a repeat is 'unchanged'", {
  db <- af_db()
  at <- af_utc("2026-10-02 03:04:05")
  register_filing(db, "as-1", "TRIM", "x", filed_at = at)
  n0 <- af_n_log(db)
  expect_identical(register_filing(db, "as-1", "TRIM", "x"), "unchanged")
  expect_equal(as.numeric(af_rows(db)$filed_at), as.numeric(at))
  expect_identical(af_n_log(db), n0)
})

test_that("P20.5 register_filing(): a differing field is updated; the others (and filed_at, when NULL) keep their stored values; returns 'updated'", {
  db <- af_db()
  at <- af_utc("2026-10-02 03:04:05")
  register_filing(db, "as-1", "TRIM", "id-1", external_uri = "u1", container = "c1",
                  filed_at = at, title = "t1", comments = "k1")
  v <- withVisible(register_filing(db, "as-1", "TRIM", "id-2", external_uri = "u1",
                                   container = "c1", title = "t1", comments = "k1"))
  expect_false(v$visible)
  expect_identical(v$value, "updated")
  r <- af_rows(db)
  expect_identical(nrow(r), 1L)
  expect_identical(r$external_id, "id-2")
  expect_identical(r$external_uri, "u1")
  expect_identical(r$container, "c1")
  expect_equal(as.numeric(r$filed_at), as.numeric(at))
  expect_identical(r$title, "t1")
  expect_identical(r$comments, "k1")
})

test_that("P20.5 register_filing(): a different explicit filed_at is an update", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "x", filed_at = af_utc("2026-10-02 03:04:05"))
  new <- af_utc("2026-10-03 00:00:00")
  expect_identical(register_filing(db, "as-1", "TRIM", "x", filed_at = new), "updated")
  expect_equal(as.numeric(af_rows(db)$filed_at), as.numeric(new))
})

test_that("P20.5 register_filing(): each optional field can be updated on its own", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "x")
  expect_identical(register_filing(db, "as-1", "TRIM", "x", external_uri = "u"), "updated")
  expect_identical(register_filing(db, "as-1", "TRIM", "x", external_uri = "u", container = "c"), "updated")
  expect_identical(register_filing(db, "as-1", "TRIM", "x", external_uri = "u", container = "c",
                                   title = "t"), "updated")
  expect_identical(register_filing(db, "as-1", "TRIM", "x", external_uri = "u", container = "c",
                                   title = "t", comments = "k"), "updated")
  r <- af_rows(db)
  expect_identical(c(r$external_uri, r$container, r$title, r$comments), c("u", "c", "t", "k"))
})

test_that("P20.5 register_filing(): a supplied NA differs from a stored value and clears it (the supplied value is what counts)", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "x", external_uri = "u", title = "t")
  expect_identical(register_filing(db, "as-1", "TRIM", "x"), "updated")
  r <- af_rows(db)
  expect_true(is.na(r$external_uri))
  expect_true(is.na(r$title))
  # and NA against a stored NA is unchanged
  expect_identical(register_filing(db, "as-1", "TRIM", "x"), "unchanged")
})

test_that("P20.5 register_filing(): updating one filing leaves other (asset, system) rows alone", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "a")
  register_filing(db, "as-1", "SharePoint", "b")
  register_filing(db, "as-2", "TRIM", "c")
  register_filing(db, "as-1", "TRIM", "a2")
  r <- af_rows(db)
  expect_identical(r$external_id[r$uuid_asset == "as-1" & r$system == "TRIM"], "a2")
  expect_identical(r$external_id[r$uuid_asset == "as-1" & r$system == "SharePoint"], "b")
  expect_identical(r$external_id[r$uuid_asset == "as-2" & r$system == "TRIM"], "c")
})

# ---- register_filing(): change_log --------------------------------------------------------

test_that("P20.5 register_filing(): an insert writes change_log rows with tbl 'asset_filing' and actor 'register_filing'", {
  db <- af_db()
  n0 <- af_n_log(db)
  register_filing(db, "as-1", "TRIM", "x")
  lg <- af_log(db)
  expect_gt(nrow(lg), 0)
  expect_true(all(lg$actor == "register_filing"))
  expect_gt(af_n_log(db), n0)
  # nothing was logged against any other table by this call
  expect_identical(af_n_log(db) - n0, nrow(lg))
})

test_that("P20.5 register_filing(): an update logs only the differing field(s) with actor 'register_filing'; 'unchanged' logs nothing", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "x", title = "old")
  seen <- af_log(db)$uuid
  register_filing(db, "as-1", "TRIM", "x", title = "new")
  lg <- af_log(db)
  fresh <- lg[!(lg$uuid %in% seen), , drop = FALSE]
  expect_gt(nrow(fresh), 0)
  expect_true(all(fresh$actor == "register_filing"))
  expect_identical(unique(fresh$field), "title")
  expect_identical(fresh$new[[1]], "new")
  expect_identical(fresh$old[[1]], "old")
  n <- af_n_log(db)
  register_filing(db, "as-1", "TRIM", "x", title = "new")
  expect_identical(af_n_log(db), n)
})

# ---- register_filing(): refusals ---------------------------------------------------------

test_that("P20.5 register_filing(): an unknown asset is refused with class sampletidy_error and nothing is written", {
  db <- af_db()
  n0 <- af_n_log(db)
  expect_error(register_filing(db, "no-such-asset", "TRIM", "x"), class = "sampletidy_error")
  expect_identical(nrow(af_rows(db)), 0L)
  expect_identical(af_n_log(db), n0)
})

test_that("P20.5 register_filing(): a missing asset_filing table is refused with class sampletidy_error naming migration 060; nothing is written", {
  db <- af_db()
  con <- seed_con(db)
  DBI::dbExecute(con, "DROP TABLE asset_filing")
  DBI::dbDisconnect(con, shutdown = TRUE)
  n0 <- af_n_log(db)
  expect_error(register_filing(db, "as-1", "TRIM", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", "x"), "060")
  expect_false("asset_filing" %in% af_q(db, "SELECT table_name FROM information_schema.tables")$table_name)
  expect_identical(af_n_log(db), n0)
})

test_that("P20.5 register_filing(): uuid_asset, system and external_id must be non-empty single strings", {
  db <- af_db()
  expect_error(register_filing(db, "", "TRIM", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, NA_character_, "TRIM", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, c("as-1", "as-2"), "TRIM", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, 1, "TRIM", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "", "x"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", NA_character_, "x"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", NULL, "x"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", ""), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", NA_character_), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", c("a", "b")), class = "sampletidy_error")
  expect_identical(nrow(af_rows(db)), 0L)
})

test_that("P20.5 register_filing(): external_uri, container, title and comments must each be a single string or NA", {
  db <- af_db()
  for (arg in c("external_uri", "container", "title", "comments")) {
    expect_error(do.call(register_filing, c(list(db, "as-1", "TRIM", "x"), stats::setNames(list(1), arg))),
                 class = "sampletidy_error", info = arg)
    expect_error(do.call(register_filing, c(list(db, "as-1", "TRIM", "x"),
                                            stats::setNames(list(c("a", "b")), arg))),
                 class = "sampletidy_error", info = arg)
  }
  expect_identical(nrow(af_rows(db)), 0L)
})

test_that("P20.5 register_filing(): filed_at must be NULL or a length-1 POSIXct", {
  db <- af_db()
  expect_error(register_filing(db, "as-1", "TRIM", "x", filed_at = "2026-10-02"), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", "x", filed_at = as.Date("2026-10-02")),
               class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", "x", filed_at = 1e9), class = "sampletidy_error")
  expect_error(register_filing(db, "as-1", "TRIM", "x",
                               filed_at = af_utc(c("2026-10-02 00:00:00", "2026-10-03 00:00:00"))),
               class = "sampletidy_error")
  expect_identical(nrow(af_rows(db)), 0L)
})

# ---- register_filing(): db argument ------------------------------------------------------

test_that("P20.5 register_filing(): accepts an open read-write connection, uses it as is, and leaves it open", {
  db <- af_db()
  con <- seed_con(db)
  withr::defer(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE))
  expect_identical(register_filing(con, "as-1", "TRIM", "x"), "inserted")
  expect_true(DBI::dbIsValid(con))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM asset_filing")$n, 1)
  expect_identical(register_filing(con, "as-1", "TRIM", "y"), "updated")
  expect_true(DBI::dbIsValid(con))
  expect_identical(DBI::dbGetQuery(con, "SELECT external_id FROM asset_filing")$external_id, "y")
  expect_gt(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log WHERE tbl = 'asset_filing'")$n, 0)
})

test_that("P20.5 register_filing(): given a path it closes its own connection (a later read-write open works)", {
  db <- af_db()
  register_filing(db, "as-1", "TRIM", "x")
  con <- seed_con(db)
  expect_true(DBI::dbIsValid(con))
  DBI::dbDisconnect(con, shutdown = TRUE)
})

# ---- filed_assets() ----------------------------------------------------------------------

af_fill <- function(db) {
  con <- seed_con(db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ins <- function(a, s, at) DBI::dbExecute(con, sprintf(
    "INSERT INTO asset_filing (uuid_asset, system, external_id, filed_at)
     VALUES ('%s', '%s', 'id-%s-%s', TIMESTAMP '%s')", a, s, a, s, at))
  # inserted in scrambled order
  ins("as-2", "TRIM", "2026-10-02 00:00:00")
  ins("as-9", "SharePoint", "2026-10-05 00:00:00")
  ins("as-1", "TRIM", "2026-10-02 00:00:00")      # same system + time as as-2: uuid_asset breaks the tie
  ins("as-3", "TRIM", "2026-10-01 00:00:00")
  ins("as-1", "SharePoint", "2026-10-09 00:00:00")
  invisible(db)
}

test_that("P20.5 filed_assets(): returns exactly the asset_filing columns in table order, filed_at as POSIXct", {
  db <- af_db()
  af_fill(db)
  fa <- filed_assets(db)
  expect_s3_class(fa, "tbl_df")
  expect_identical(names(fa), af_cols)
  for (col in setdiff(af_cols, "filed_at")) expect_type(fa[[col]], "character")
  expect_s3_class(fa$filed_at, "POSIXct")
  expect_identical(nrow(fa), 5L)
})

test_that("P20.5 filed_assets(): ordered by system, then filed_at, then uuid_asset", {
  db <- af_db()
  af_fill(db)
  fa <- filed_assets(db)
  expect_identical(paste(fa$system, fa$uuid_asset),
                   c("SharePoint as-9", "SharePoint as-1",
                     "TRIM as-3", "TRIM as-1", "TRIM as-2"))
})

test_that("P20.5 filed_assets(): system = NULL returns every row; a character vector keeps rows whose system is in it", {
  db <- af_db()
  af_fill(db)
  expect_identical(nrow(filed_assets(db, system = NULL)), 5L)
  expect_identical(unique(filed_assets(db, system = "TRIM")$system), "TRIM")
  expect_identical(nrow(filed_assets(db, system = "TRIM")), 3L)
  expect_identical(nrow(filed_assets(db, system = c("TRIM", "SharePoint"))), 5L)
  expect_identical(nrow(filed_assets(db, system = c("SharePoint", "nope"))), 2L)
  # case-sensitive, no partial match
  expect_identical(nrow(filed_assets(db, system = "trim")), 0L)
  expect_identical(nrow(filed_assets(db, system = "TR")), 0L)
})

test_that("P20.5 filed_assets(): no match gives a 0-row tibble with the same columns and types", {
  db <- af_db()
  af_fill(db)
  fa <- filed_assets(db, system = "nope")
  expect_s3_class(fa, "tbl_df")
  expect_identical(nrow(fa), 0L)
  expect_identical(names(fa), af_cols)
  expect_s3_class(fa$filed_at, "POSIXct")
  expect_type(fa$uuid_asset, "character")
})

test_that("P20.5 filed_assets(): an empty table gives the same 0-row shape", {
  db <- af_db()
  fa <- filed_assets(db)
  expect_identical(nrow(fa), 0L)
  expect_identical(names(fa), af_cols)
  expect_s3_class(fa$filed_at, "POSIXct")
})

test_that("P20.5 filed_assets(): when the table does not exist it returns a 0-row tibble with those columns (no error)", {
  db <- af_db()
  con <- seed_con(db)
  DBI::dbExecute(con, "DROP TABLE asset_filing")
  DBI::dbDisconnect(con, shutdown = TRUE)
  fa <- expect_no_error(filed_assets(db))
  expect_s3_class(fa, "tbl_df")
  expect_identical(nrow(fa), 0L)
  expect_identical(names(fa), af_cols)
  expect_s3_class(fa$filed_at, "POSIXct")
  expect_identical(nrow(filed_assets(db, system = "TRIM")), 0L)
})

test_that("P20.5 filed_assets(): given a path it opens read-only (file unchanged); given a connection it uses it and leaves it open", {
  db <- af_db()
  af_fill(db)
  before <- file_md5(db)
  expect_identical(nrow(filed_assets(db)), 5L)
  expect_identical(file_md5(db), before)

  con <- seed_con(db)
  withr::defer(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE))
  expect_identical(nrow(filed_assets(con)), 5L)
  expect_true(DBI::dbIsValid(con))
  DBI::dbExecute(con, "DELETE FROM asset_filing WHERE system = 'SharePoint'")
  expect_identical(nrow(filed_assets(con)), 3L)
  expect_true(DBI::dbIsValid(con))
})

test_that("P20.5: register_filing() and filed_assets() round-trip", {
  db <- af_db()
  at <- af_utc("2026-10-02 03:04:05")
  register_filing(db, "as-2", "TRIM", "26/1", container = "F1", filed_at = at)
  fa <- filed_assets(db)
  expect_identical(nrow(fa), 1L)
  expect_identical(fa$uuid_asset, "as-2")
  expect_identical(fa$external_id, "26/1")
  expect_identical(fa$container, "F1")
  expect_equal(as.numeric(fa$filed_at), as.numeric(at))
})
