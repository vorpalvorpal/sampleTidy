# Plan 09 - R/mutate.R: the mutation layer, the only write door.
#
# `db_append(con, table, df, actor, reason, source_hash = NA)`,
# `db_update(con, table, uuid, changes, actor, reason, source_hash = NA)`,
# `db_delete(con, table, uuid, actor, reason)` all write `change_log` rows in
# the same transaction as the mutation they record.
#
# CONTRACT shows `correct_value(uuid_analysis, new_value, reason, actor)`
# with NO `con` argument (unlike `db_append(con, ...)`), so the domain
# helpers (`correct_value()`, `add_feature()`, `add_analyte()`,
# `add_project()`) are assumed to resolve their own connection from
# `st_config("live_db")`, consistent with DESIGN §9.3 ("one set of write
# functions used by pipeline and humans alike" - humans calling these
# interactively won't have an open `con` lying around). Tests point
# `st_config("live_db")` at the throwaway seeded DB via
# `withr::local_options()`. See dev/plans/PLAN-CHANGE-REQUESTS.md.

count_change_log <- function(con) {
  DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
}

# ---- db_append / db_update: change_log recording ---------------------------

test_that("R-9.1: db_append() of 2 rows writes 2 change_log rows with one shared `at` and the actor recorded", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  # lon/lat added (R-11.17): the live `feature` table declares them DOUBLE NOT
  # NULL (helper-db.R's DDL now mirrors that), so a fixture omitting them
  # fails on an unrelated NOT NULL constraint rather than testing db_append()
  # itself - reconciled per the P11-mutate brief.
  new_features <- tibble::tibble(
    uuid = c("f-1001", "f-1002"), name = c("T.NEW1", "T.NEW2"),
    site = c("TestSite", "TestSite"), flow = c("surface", "surface"),
    matrix = c("water", "water"), lon = c(150.1001, 150.1002),
    lat = c(-33.1001, -33.1002)
  )
  db_append(con, "feature", new_features, actor = "tester", reason = "bulk add")

  after <- count_change_log(con)
  expect_equal(after - before, 2)

  log_rows <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'feature' ORDER BY uuid_row")
  expect_equal(nrow(log_rows), 2)
  expect_equal(length(unique(log_rows$at)), 1)
  expect_true(all(log_rows$actor == "tester"))
  expect_true(all(log_rows$action == "insert"))
  expect_setequal(log_rows$uuid_row, c("f-1001", "f-1002"))

  # Counts the appended rows specifically rather than the seed total: plan 11
  # grew the seed's feature count (3 -> 7) and a pinned absolute broke. The
  # WHERE-filtered form matches this file's own idiom (cf. the add_feature test
  # below) and asserts the stronger thing -- that these two rows landed.
  n_features <- DBI::dbGetQuery(
    con, "SELECT count(*) AS n FROM feature WHERE uuid IN ('f-1001', 'f-1002')"
  )$n
  expect_equal(n_features, 2)
})

test_that("R-9.1: db_update() changing 2 fields writes 2 change_log rows with correct old/new", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  db_update(con, "sample", "s-0001",
            changes = list(organisation = "ACIRL", person = "J. Tester"),
            actor = "tester", reason = "correction")

  after <- count_change_log(con)
  expect_equal(after - before, 2)

  log_rows <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE tbl = 'sample' AND uuid_row = 's-0001' ORDER BY field")
  expect_equal(nrow(log_rows), 2)
  org_row <- log_rows[log_rows$field == "organisation", ]
  person_row <- log_rows[log_rows$field == "person", ]
  expect_equal(org_row$old, "ALS")
  expect_equal(org_row$new, "ACIRL")
  expect_equal(person_row$new, "J. Tester")
  expect_true(all(log_rows$action == "update"))

  updated <- DBI::dbGetQuery(con, "SELECT organisation, person FROM \"sample\" WHERE uuid = 's-0001'")
  expect_equal(updated$organisation, "ACIRL")
  expect_equal(updated$person, "J. Tester")
})

test_that("R-9.1: a failing update (bad column) rolls back the change_log too (atomicity)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  err <- tryCatch(
    db_update(con, "sample", "s-0001",
              changes = list(not_a_real_column = "x"),
              actor = "tester", reason = "should fail"),
    error = function(e) e
  )
  expect_s3_class(err, "condition")
  after <- count_change_log(con)
  expect_equal(after, before)
})

test_that("R-9.1: db_delete() removes the row and writes a change_log delete entry", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # lon/lat added (R-11.17 reconciliation - see the db_append test above).
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-9999', 'T.THROWAWAY', 'TestSite', 'surface', 'water', 150.9999, -33.9999)")
  before <- count_change_log(con)

  db_delete(con, "feature", uuid = "f-9999", actor = "tester", reason = "cleanup")

  n_left <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature WHERE uuid = 'f-9999'")$n
  expect_equal(n_left, 0)
  after <- count_change_log(con)
  expect_equal(after - before, 1)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'f-9999' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(log_row$action, "delete")
})

test_that("PLAN-14 R-14.1/M6a: db_delete() with a composite `key` ANDs every column - it does not over-delete on an OR", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # `analyte_mask` (already on `.st_mutate_allowlist`) has no `uuid` column -
  # it is keyed on (uuid_analyte, variant) - so this is the only allowlisted
  # shape that forces db_delete() through its composite-key `WHERE ... AND
  # ...` path (mutate.R:363-370) rather than the scalar-uuid path every
  # production caller uses. Not part of helper-db.R's shared seed schema
  # (that mirrors the LIVE db; analyte_mask is PLAN-14), so it is created
  # locally in this test body only - no shared helper DDL is touched.
  DBI::dbExecute(con, "CREATE TABLE analyte_mask (uuid_analyte VARCHAR, variant VARCHAR, name VARCHAR)")
  DBI::dbExecute(con, "INSERT INTO analyte_mask (uuid_analyte, variant, name) VALUES
    ('A', 'long', 'Analyte A (long)'),
    ('A', 'short', 'Analyte A (short)'),
    ('B', 'long', 'Analyte B (long)')")

  db_delete(con, "analyte_mask", key = list(uuid_analyte = "A", variant = "long"),
            actor = "tester", reason = "composite-key delete test")

  remaining <- DBI::dbGetQuery(con, "SELECT uuid_analyte, variant FROM analyte_mask ORDER BY uuid_analyte, variant")
  # Exactly the (A, long) row is gone; (A, short) and (B, long) - each of
  # which matches only ONE of the two key columns - must both survive. Under
  # an `OR` these would be wrongly deleted too (over-delete).
  expect_equal(nrow(remaining), 2)
  expect_setequal(paste(remaining$uuid_analyte, remaining$variant), c("A short", "B long"))
})

test_that("PLAN-14 R-14.1/A32: db_update()/db_delete() abort when a composite `key` matches MORE than one row, leaving both rows and change_log untouched", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # `feature_mask` (already on `.st_mutate_allowlist`) has no `uuid` column
  # and no uniqueness constraint on (uuid_feature, variant) - so two rows can
  # legitimately share a key value. The table is already part of
  # helper-db.R's shared seed schema (seeded with f-0001/f-0002/f-0003), so
  # only the two extra F1/long rows for this test are inserted here - 'F1'
  # does not collide with the seeded uuid_feature values.
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('F1', 'long', 'Bore Twelve'),
    ('F1', 'long', 'Borehole 12')")

  before <- count_change_log(con)

  expect_error(
    db_update(con, "feature_mask", key = list(uuid_feature = "F1", variant = "long"),
               changes = list(name = "X"), actor = "tester", reason = "ambiguous-key update"),
    class = "sampletidy_error"
  )

  after_update <- count_change_log(con)
  expect_equal(after_update, before)

  rows_after_update <- DBI::dbGetQuery(
    con, "SELECT name FROM feature_mask WHERE uuid_feature = 'F1' AND variant = 'long' ORDER BY name"
  )
  expect_equal(nrow(rows_after_update), 2)
  expect_setequal(rows_after_update$name, c("Bore Twelve", "Borehole 12"))

  expect_error(
    db_delete(con, "feature_mask", key = list(uuid_feature = "F1", variant = "long"),
               actor = "tester", reason = "ambiguous-key delete"),
    class = "sampletidy_error"
  )

  after_delete <- count_change_log(con)
  expect_equal(after_delete, before)

  rows_after_delete <- DBI::dbGetQuery(
    con, "SELECT name FROM feature_mask WHERE uuid_feature = 'F1' AND variant = 'long' ORDER BY name"
  )
  expect_equal(nrow(rows_after_delete), 2)
  expect_setequal(rows_after_delete$name, c("Bore Twelve", "Borehole 12"))
})

# ---- Phase-7b round-2 item 9: the A32/R-9.1 "only write door" lint -------
#
# The OLD scanner (`grepl(pattern, lines)` over `readLines()`, one element
# per file line) had three independent defects, all measured on decoys: (1)
# it matched per LINE, so a multi-line `DBI::dbExecute(\n con,\n "DELETE
# FROM ...")` call was never caught - `[^)]*` is a character class (it DOES
# span newlines) but a per-line `grepl()` never even hands it a newline to
# span; (2) `duckdb_register()` + `paste0("INSERT INTO ", ...)` +
# `dbExecute(con, sql)` - `.st_append_rows()`'s OWN pattern - built its SQL
# in a variable, so no INSERT/UPDATE/DELETE literal ever sat inside the
# `dbExecute(...)` call itself; (3) a comment merely NAMING a forbidden
# function (`# never call dbAppendTable() directly`) false-positived, because
# the old pattern never stripped comments. Its own inline comment ("Trivially
# passes while R/ has no adapter/commit/etc. sources yet") was stale too - R/
# now holds 28 files.
#
# Fix: strip real comment tokens via `getParseData()` (not a `#` line regex -
# a `#` inside a string literal must survive), search the WHOLE joined
# source text rather than per-line so a multi-line call is not blind, and add
# `dbSendStatement`/`dbWriteTable`/`duckdb_register` as UNCONDITIONALLY
# forbidden identifiers (not just inside an INSERT/UPDATE/DELETE dbExecute
# call), which is what actually catches the register()+paste0()+dbExecute()
# shape.

.rq9_write_door_pattern <- "dbAppendTable|dbSendStatement|dbWriteTable|duckdb_register|dbExecute\\s*\\([^)]*(INSERT|UPDATE|DELETE)"

#' Strip real `#` comment tokens (via `getParseData()`) out of `lines`,
#' returning the WHOLE file as one joined string - never comment text
#' matching a forbidden identifier by coincidence, and never blind to a call
#' that spans more than one line.
#' @keywords internal
.rq9_strip_comments <- function(lines) {
  text <- paste(lines, collapse = "\n")
  pd <- tryCatch(
    utils::getParseData(parse(text = text, keep.source = TRUE)),
    error = function(e) NULL
  )
  if (is.null(pd) || nrow(pd) == 0) {
    return(text)
  }
  comments <- pd[pd$token == "COMMENT", ]
  if (nrow(comments) == 0) {
    return(text)
  }
  out_lines <- lines
  for (i in seq_len(nrow(comments))) {
    ln <- comments$line1[[i]]
    col1 <- comments$col1[[i]]
    s <- out_lines[[ln]]
    if (col1 <= nchar(s) + 1) {
      out_lines[[ln]] <- substr(s, 1, col1 - 1)
    }
  }
  paste(out_lines, collapse = "\n")
}

#' TRUE if `lines` (a file's raw `readLines()` output) contains a forbidden
#' raw-write call, comment-and-continuation-line-aware.
#' @keywords internal
.rq9_scan <- function(lines) {
  grepl(.rq9_write_door_pattern, .rq9_strip_comments(lines), perl = TRUE)
}

test_that("R-9.1: direct-write bypass is lint-guarded - no forbidden raw SQL writes in R/ (comment/string-aware, continuation-line-aware; Phase-7b round-2 item 9)", {
  pkg_root <- normalizePath(file.path(testthat::test_path(), "..", ".."))
  r_dir <- file.path(pkg_root, "R")
  r_files <- if (dir.exists(r_dir)) list.files(r_dir, pattern = "\\.R$", full.names = TRUE) else character(0)
  r_files <- r_files[!basename(r_files) %in% c("mutate.R", "db-schema.R")]
  # The scan must be non-vacuous - R/ now holds well over 20 production
  # files, not zero, so this cannot silently pass for the "empty r_files"
  # reason the old comment excused.
  expect_gt(length(r_files), 20)

  hits <- character(0)
  for (f in r_files) {
    lines <- readLines(f, warn = FALSE)
    if (.rq9_scan(lines)) hits <- c(hits, basename(f))
  }
  expect_true(length(hits) == 0, info = paste("forbidden direct writes found in:", paste(hits, collapse = "; ")))
})

test_that("Phase-7b round-2 item 9 (decoy A): the scanner catches a multi-line dbExecute(...DELETE...) call - the per-line [^)]* blind spot", {
  decoy <- c(
    "f <- function(con) {",
    "  DBI::dbExecute(",
    "    con,",
    "    \"DELETE FROM sample WHERE uuid = 'x'\")",
    "}"
  )
  expect_true(.rq9_scan(decoy))
})

test_that("Phase-7b round-2 item 9 (decoy B): the scanner catches the register()+paste0(INSERT)+dbExecute(con, sql) shape (.st_append_rows()'s own pattern) even with no INSERT/UPDATE/DELETE literal inside the dbExecute() call itself", {
  decoy <- c(
    "g <- function(con, df) {",
    "  duckdb::duckdb_register(con, 'v', df)",
    "  sql <- paste0(\"INSERT INTO t SELECT * FROM v\")",
    "  DBI::dbExecute(con, sql)",
    "}"
  )
  expect_true(.rq9_scan(decoy))
})

test_that("Phase-7b round-2 item 9 (decoy C): the scanner does NOT false-positive on a comment merely naming a forbidden function", {
  decoy <- c(
    "h <- function() {",
    "  # never call dbAppendTable() directly - use db_append() instead",
    "  invisible(NULL)",
    "}"
  )
  expect_false(.rq9_scan(decoy))
})

# ---- domain helpers ---------------------------------------------------------

test_that("R-9.1: add_feature() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  # lon/lat added (R-11.17 reconciliation): the fixed add_feature() signature
  # requires them (live `feature.lon`/`lat` are DOUBLE NOT NULL) - see the
  # dedicated R-11.17 tests below for the missing-lon/lat and round-trip
  # cases this baseline test doesn't cover.
  add_feature(name = "T.NEW1", site = "TestSite", lon = 150.5001, lat = -33.5001,
              flow = "surface", matrix = "water",
              actor = "tester", reason = "new monitoring point")

  n_features <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature WHERE name = 'T.NEW1'")$n
  expect_equal(n_features, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: add_analyte() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  add_analyte(name = "Sulfate", units = "mg/L", type = "anion", CAS = "14808-79-8",
              actor = "tester", reason = "new analyte")

  n_analytes <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM analyte WHERE name = 'Sulfate'")$n
  expect_equal(n_analytes, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: add_project() inserts a row and a change_log entry", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  add_project(name = "ZZ0000099", type = "Work order", actor = "tester", reason = "new work order")

  n_projects <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE name = 'ZZ0000099'")$n
  expect_equal(n_projects, 1)
  after <- count_change_log(con)
  expect_gt(after, before)
})

test_that("R-9.1: correct_value() updates the analysis and logs the old value", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  correct_value(uuid_analysis = "an-0001", new_value = 150, reason = "lab reissue", actor = "tester")

  updated <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid = 'an-0001'")
  expect_equal(updated$value, 150)
  after <- count_change_log(con)
  expect_gt(after, before)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'an-0001' ORDER BY \"at\" DESC LIMIT 1")
  expect_equal(log_row$old, "100")
})

# ---- review_queue reader -----------------------------------------------------

test_that("R-9.1: review_queue() filters by status", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, work_order, status) VALUES
    ('rq-0001', CURRENT_TIMESTAMP, 'unknown_feature', 'XX1234567', 'open'),
    ('rq-0002', CURRENT_TIMESTAMP, 'unknown_analyte', 'XX1234567', 'resolved')")

  open_items <- review_queue(con, status = "open")
  expect_equal(nrow(open_items), 1)
  expect_identical(open_items$uuid, "rq-0001")

  resolved_items <- review_queue(con, status = "resolved")
  expect_equal(nrow(resolved_items), 1)
  expect_identical(resolved_items$uuid, "rq-0002")
})

test_that("R-9.1: review_queue() has stable columns on a zero-row result", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  empty <- review_queue(con, status = "open")
  expect_equal(nrow(empty), 0)
  expect_true(all(c("uuid", "created_at", "kind", "work_order", "source_hash", "payload",
                     "status", "resolution", "resolved_by", "resolved_at") %in% names(empty)))
})

test_that("Phase-7b round-2 item 5b: review_queue() also returns the typed uuid_incoming column (schema ladder version 7) alongside uuid_existing - it was written but not read back", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO review_queue
    (uuid, created_at, kind, subkind, status, uuid_existing, uuid_incoming) VALUES
    ('rq-9501', CURRENT_TIMESTAMP, 'value_conflict', 'alias_merge', 'open', 'an-existing', 'an-incoming')")

  rows <- review_queue(con, status = "open")
  expect_true("uuid_incoming" %in% names(rows))
  hit <- rows[rows$uuid == "rq-9501", ]
  expect_equal(nrow(hit), 1)
  expect_identical(hit$uuid_existing[[1]], "an-existing")
  expect_identical(hit$uuid_incoming[[1]], "an-incoming")
})

# ---- R-11.17: add_feature() aligned to the live `feature` schema (F5/A-4) --
#
# The live `feature` table is 19 columns, `lon`/`lat` DOUBLE NOT NULL, and
# `add_feature()` (mutate.R:324-338) omits them - a broken exported API that
# cannot insert against the live-shaped DDL. Fix: add lon/lat as required
# (no-default) arguments, checkmate-validated as numbers, aborting
# `sampletidy_error` at the argument check (not a raw DB constraint error)
# when omitted. `virtual` stays (A58/A67).

test_that("R-11.17: add_feature() with lon/lat inserts against the live-shaped DDL and the row round-trips coordinates + virtual", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  add_feature(name = "T.NEWCOORD", site = "SiteA", lon = 150.1234, lat = -33.5678,
              virtual = TRUE, actor = "tester", reason = "new monitoring point")

  row <- DBI::dbGetQuery(
    con, "SELECT lon, lat, virtual FROM feature WHERE name = 'T.NEWCOORD'"
  )
  expect_equal(nrow(row), 1)
  expect_equal(row$lon, 150.1234)
  expect_equal(row$lat, -33.5678)
  expect_true(row$virtual)
})

test_that("R-11.17: add_feature() omitting lon/lat aborts as sampletidy_error at the argument check, not a DB error", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  err <- tryCatch(
    add_feature(name = "T.NOLONLAT", site = "TestSite", actor = "tester",
                reason = "missing coordinates"),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  # NB db_transaction() (mutate.R:106-115) already wraps *any* error raised
  # inside its fn(con) body - including a raw DB constraint failure - as
  # class sampletidy_error with the prefix "Mutation transaction failed and
  # was rolled back: ...". So `class = "sampletidy_error"` alone does not
  # discriminate "argument check fired first" from "DB write was attempted
  # and failed" - both look identical on class. The two ARE distinguishable
  # on the message: a DB-path failure carries that specific wrapper prefix
  # (verified against the transaction-wrap code, not guessed); an
  # argument-check failure never enters db_transaction() at all, so it can
  # never carry it.
  expect_false(
    grepl("Mutation transaction failed", conditionMessage(err), fixed = TRUE),
    info = paste("error passed through db_transaction()'s DB-failure wrapper",
                 "instead of failing at the argument check:", conditionMessage(err))
  )

  n_features <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature WHERE name = 'T.NOLONLAT'")$n
  expect_equal(n_features, 0)
  after <- count_change_log(con)
  expect_equal(after, before)
})

test_that("R-11.17: .st_test_core_ddl's feature columns match the live schema (drift detector; SAMPLETIDY_CORPUS_DB-gated)", {
  corpus_db <- Sys.getenv("SAMPLETIDY_CORPUS_DB")
  skip_if(corpus_db == "", "SAMPLETIDY_CORPUS_DB not set")

  # Materialise the real test DDL (run the interpreter, don't regex the
  # string) into a throwaway in-memory DuckDB so we introspect what it
  # actually creates, then diff against the live authoritative schema.
  mem_con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(mem_con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(mem_con, .st_test_core_ddl$feature)
  test_cols <- DBI::dbGetQuery(
    mem_con,
    "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'feature'"
  )

  live_con <- DBI::dbConnect(duckdb::duckdb(), corpus_db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(live_con, shutdown = TRUE), add = TRUE)
  live_cols <- DBI::dbGetQuery(
    live_con,
    "SELECT column_name, is_nullable FROM information_schema.columns WHERE table_name = 'feature'"
  )

  missing_live <- setdiff(test_cols$column_name, live_cols$column_name)
  expect_true(
    length(missing_live) == 0,
    info = paste("test DDL columns absent from the live feature table:",
                 paste(missing_live, collapse = ", "))
  )

  live_nullable <- setNames(live_cols$is_nullable, live_cols$column_name)
  for (col in test_cols$column_name) {
    test_nullable <- test_cols$is_nullable[test_cols$column_name == col]
    expect_identical(
      test_nullable, unname(live_nullable[[col]]),
      info = paste0("nullability drift on feature.", col, ": test DDL says ",
                     test_nullable, ", live says ", live_nullable[[col]])
    )
  }
})

test_that("R-11.17: .st_test_core_ddl's feature DDL declares `virtual` (A58/A67 - the column exists live, not test-only drift)", {
  mem_con <- DBI::dbConnect(duckdb::duckdb())
  on.exit(DBI::dbDisconnect(mem_con, shutdown = TRUE))
  DBI::dbExecute(mem_con, .st_test_core_ddl$feature)
  cols <- DBI::dbGetQuery(
    mem_con,
    "SELECT column_name, data_type FROM information_schema.columns
     WHERE table_name = 'feature' AND column_name = 'virtual'"
  )
  expect_equal(nrow(cols), 1)
  expect_equal(cols$data_type, "BOOLEAN")
})

# ---- R-11.20: `feature_alias` in `.st_mutate_allowlist` (Phase-3 D1) -------
#
# `.st_mutate_allowlist` (mutate.R:40-43) did not list `feature_alias`, so
# every db_append() in the pending-alias materialisation / confirmation path
# aborted - the entire commit-everything path. Fix: add "feature_alias".

test_that("R-11.20: db_append() to `feature_alias` succeeds and writes a change_log row (D1 fix)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  new_alias <- tibble::tibble(
    uuid = "fa-9001", uuid_feature = "f-0001", name = "T.NEWALIAS",
    alias_key = "tnewalias", kind = "pending", n_seen = 0L, auto_assign = TRUE
  )
  db_append(con, "feature_alias", new_alias, actor = "tester", reason = "new pending alias")

  n_alias <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias WHERE uuid = 'fa-9001'")$n
  expect_equal(n_alias, 1)

  after <- count_change_log(con)
  expect_equal(after - before, 1)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'fa-9001'")
  expect_equal(nrow(log_row), 1)
  expect_equal(log_row$tbl, "feature_alias")
  expect_equal(log_row$action, "insert")
})

test_that("R-11.20: db_append() to a still-non-allowlisted table (e.g. 'guideline') is still refused with sampletidy_error (allowlist regression)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  df <- tibble::tibble(uuid = "g-0001", name = "some guideline")
  err <- tryCatch(
    db_append(con, "guideline", df, actor = "tester", reason = "should be refused"),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  after <- count_change_log(con)
  expect_equal(after, before)
})

test_that("R-11.20: the pre-existing .st_mutate_allowlist entries are unchanged - feature_alias is an addition, not a replacement (security boundary regression)", {
  pre_existing <- c(
    "feature", "feature_mask", "analyte", "analyte_mask", "lab_method",
    "project", "sample", "analysis", "asset", "review_queue"
  )
  dropped <- setdiff(pre_existing, .st_mutate_allowlist)
  expect_true(
    length(dropped) == 0,
    info = paste("allowlist entries dropped:", paste(dropped, collapse = ", "))
  )
  expect_true("feature_alias" %in% .st_mutate_allowlist)
})

# ---- R-12.6: mutation-layer correctness (F12) -------------------------------
#
# Three independent defects in mutate.R: (1) db_update() logs a change_log
# row for every field in `changes` with no old != new comparison - phantom
# "update" records for unchanged fields; (2) db_delete() on a nonexistent
# uuid runs a 0-row DELETE but still writes a delete change_log row - a
# phantom delete record; (3) DBI::dbCommit() sits outside db_transaction()'s
# tryCatch, so a commit-time error escapes unwrapped with no rollback
# attempt. Fix: (1) db_update() skips a field whose as.character(new) equals
# as.character(old) - no UPDATE, no log row; (2) db_delete() captures the
# affected-row count and, when zero, ABORTS sampletidy_error and writes no
# log row (PINNED 2026-07-22, Phase-3 D2, CONTRACT A72 - matches
# db_update()'s existing "no row" behaviour; PLAN-14 R-14.1 depends on this);
# (3) dbCommit() moves inside the tryCatch so a commit failure rolls back and
# re-throws as sampletidy_error.

test_that("R-12.6: db_update() skips the change_log row for a field whose new value equals its current value, logging only the field that actually changed", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  # s-0001's seeded organisation is already 'ALS' (helper-db.R) - unchanged;
  # person is unseeded (NULL) -> 'J. Tester' - changed.
  db_update(con, "sample", "s-0001",
            changes = list(organisation = "ALS", person = "J. Tester"),
            actor = "tester", reason = "one field unchanged, one changed")

  after <- count_change_log(con)
  expect_equal(after - before, 1)

  log_rows <- DBI::dbGetQuery(
    con, "SELECT * FROM change_log WHERE tbl = 'sample' AND uuid_row = 's-0001'"
  )
  expect_equal(nrow(log_rows), 1)
  expect_equal(log_rows$field, "person")
  expect_equal(log_rows$new, "J. Tester")
  expect_true(all(log_rows$field != "organisation"))

  updated <- DBI::dbGetQuery(con, "SELECT organisation, person FROM \"sample\" WHERE uuid = 's-0001'")
  expect_equal(updated$organisation, "ALS")
  expect_equal(updated$person, "J. Tester")
})

test_that("R-12.6: db_update() where every field in `changes` is unchanged writes zero change_log rows (degenerate all-unchanged shape)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  db_update(con, "sample", "s-0001",
            changes = list(organisation = "ALS"),
            actor = "tester", reason = "no-op update, nothing actually changes")

  after <- count_change_log(con)
  expect_equal(after, before)

  log_rows <- DBI::dbGetQuery(
    con, "SELECT * FROM change_log WHERE tbl = 'sample' AND uuid_row = 's-0001'"
  )
  expect_equal(nrow(log_rows), 0)
})

test_that("R-12.6: db_delete() on a nonexistent uuid aborts sampletidy_error and writes no delete change_log row (A72, pinned Phase-3 D2)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before <- count_change_log(con)
  err <- tryCatch(
    db_delete(con, "feature", uuid = "f-does-not-exist", actor = "tester",
              reason = "delete of a row that was never there"),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  after <- count_change_log(con)
  expect_equal(after, before)

  log_rows <- DBI::dbGetQuery(
    con, "SELECT * FROM change_log WHERE uuid_row = 'f-does-not-exist'"
  )
  expect_equal(nrow(log_rows), 0)
})

# ---- PLAN-11/A32: db_update() TIMESTAMP change_log tz normalization --------
#
# db_update() logged change_log.old/new for TIMESTAMP fields via bare
# as.character() on the two POSIXct values. `old_val` (read back from duckdb)
# is always UTC-tagged; a caller-supplied `new_val` in a non-UTC tz formats in
# ITS OWN tzone, so change_log.old/new land in different timezones and `new`
# does not match the value actually stored. Fix: .st_changelog_str() renders
# any POSIXct in UTC before logging/comparing. Pinning the whole test under a
# non-UTC local tz (Australia/Sydney) makes it deterministic and exercises
# the bug (it would be silently UTC-equivalent under a UTC session tz).

test_that("PLAN-11/A32: db_update() logs TIMESTAMP change_log old/new in a single (UTC) timezone, matching the stored column", {
  withr::local_timezone("Australia/Sydney")

  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # fa-0001's seeded last_seen is TIMESTAMP '2025-01-01 00:00:00' (helper-db.R).
  # 2025-01-01 20:00:00 AEDT (Australia/Sydney, UTC+11 in Jan) = 2025-01-01
  # 09:00:00 UTC - a different instant from the seeded value, expressed in a
  # non-UTC tz, the real shape of the R-14.x/.ct_materialise_feature_aliases()
  # `last_seen` bump path.
  new_instant_syd <- as.POSIXct("2025-01-01 20:00:00", tz = "Australia/Sydney")

  before <- count_change_log(con)
  db_update(con, "feature_alias", "fa-0001",
            changes = list(last_seen = new_instant_syd),
            actor = "tester", reason = "bump last_seen (tz test)")
  after <- count_change_log(con)
  expect_equal(after - before, 1)

  stored <- DBI::dbGetQuery(
    con, "SELECT last_seen FROM feature_alias WHERE uuid = 'fa-0001'"
  )$last_seen
  stored_utc_str <- format(stored, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
  expect_equal(stored_utc_str, "2025-01-01 09:00:00")

  log_row <- DBI::dbGetQuery(
    con,
    "SELECT * FROM change_log WHERE tbl = 'feature_alias' AND uuid_row = 'fa-0001' AND field = 'last_seen'"
  )
  expect_equal(nrow(log_row), 1)
  # Non-vacuous: fails under bare as.character() (Sydney "2025-01-01 20:00:00"
  # instead of the UTC-matching stored string).
  expect_equal(log_row$new, stored_utc_str)
  expect_equal(log_row$new, "2025-01-01 09:00:00")

  # tz-robust skip-unchanged: re-submitting the SAME instant, still expressed
  # in the non-UTC Sydney tz (a tz different from the UTC tz the stored value
  # carries), must skip - no new change_log row for that field. Fails under
  # bare as.character() (the two tz-differing strings never compare equal, so
  # the field is spuriously logged as "changed" every time).
  before2 <- count_change_log(con)
  db_update(con, "feature_alias", "fa-0001",
            changes = list(last_seen = new_instant_syd),
            actor = "tester", reason = "no-op re-submit, same instant, same tz expression")
  after2 <- count_change_log(con)
  expect_equal(after2, before2)
})

# ---- R-15.30: add_feature() creates a self alias, resolves by name (F.9) --
#
# `add_feature()` (mutate.R:452) appends to `feature` only - no `feature_alias`
# row - so a feature created through it is unreachable by its own name until
# someone hand-curates an alias, and migration 003's table-wide self-arm rule
# has nothing to flip for it (PLAN-15 F.9, S-15.8). The fix must create the
# `kind = 'self'` alias in the SAME transaction as the `feature` insert, with
# its own `change_log` row. Asserting merely "a feature_alias row exists" is
# too weak - it would pass on a self alias of the wrong kind, or one with
# auto_assign = FALSE, that `.rc_feature_candidates()`'s Layer-1 exact match
# never reaches. So this test reconciles a raw carrying exactly the new
# feature's own canonical name through the REAL Layer-1 resolver
# (`.rc_resolve_features()`, R-11.5) and asserts it RESOLVES, not queues as
# `unknown_feature`.

test_that("R-15.30: add_feature() creates a self alias in the same transaction that a raw naming the feature actually RESOLVES against", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- count_change_log(con)

  new_uuid <- add_feature(
    name = "T.NEWSELF9001", site = "T", lon = 150.7001, lat = -33.7001,
    flow = "surface", matrix = "water",
    actor = "tester", reason = "F.9: post-001 feature must get a self alias"
  )

  # The self alias itself: kind='self', auto_assign TRUE (the ONLY combination
  # `.rc_feature_candidates()`'s Layer-1 exact match reaches), alias_key the
  # punctuation-preserving fold of the feature's own name (matches migration
  # 001's `.mig001_normalize` / `.rc_feature_key`). Single-bracket indexing
  # throughout so a zero-row result (today's broken code) fails as a clean
  # assertion mismatch rather than an R "subscript out of bounds" error.
  self_alias <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM feature_alias WHERE uuid_feature = '%s' AND kind = 'self'", new_uuid
  ))
  expect_equal(nrow(self_alias), 1)
  expect_true(isTRUE(self_alias$auto_assign[1]))
  expect_equal(self_alias$alias_key[1], .rc_feature_key("T.NEWSELF9001"))

  # change_log provenance for the alias creation, same transaction as the
  # feature insert (S-15.8): exactly 2 new rows sharing one `at`.
  after <- count_change_log(con)
  expect_equal(after - before, 2)
  alias_uuid <- self_alias$uuid[1]
  log_rows <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM change_log WHERE uuid_row IN ('%s', '%s')", new_uuid, alias_uuid
  ))
  expect_equal(nrow(log_rows), 2)
  # Phase-5 audit round 2 B3: `length(unique(log_rows$at)), 1)` was
  # unsatisfiable by construction - `db_append()` stamps its OWN
  # `Sys.time()` per call (R/mutate.R:192) and takes no `at` argument, so
  # the feature append and the alias append of one add_feature() call NEVER
  # share a timestamp, even inside one transaction (measured 8.3ms apart).
  # It passed only vacuously, because today just one log row exists at all.
  # Timestamp identity is not a proxy for atomicity - see the real
  # atomicity test below instead (mirrors R-12.6's fault-injection idiom).
  alias_log <- log_rows[log_rows$tbl == "feature_alias", ]
  expect_equal(nrow(alias_log), 1)
  expect_equal(alias_log$action[1], "insert")
  expect_equal(alias_log$uuid_row[1], alias_uuid)

  # The trap: a feature_alias row of the wrong kind/auto_assign would pass a
  # weaker "a row exists" check while leaving the feature UNREACHABLE. Feed a
  # raw naming the new feature through the REAL Layer-1 resolver and assert it
  # RESOLVES rather than landing `feature_pending`/`unknown_feature`.
  registry <- .rc_load_registry(con)
  rows <- tibble::tibble(
    source_ref = "r-selfcheck",
    feature_raw = "T.NEWSELF9001",
    sample_datetime_raw = NA_character_,
    source_hash = "selfcheck-hash"
  )
  result <- .rc_resolve_features(rows, registry, work_order = "WO-TEST", orphan = FALSE)
  row <- result$kept[result$kept$source_ref == "r-selfcheck", ]
  expect_equal(nrow(row), 1)
  expect_false(row$feature_pending[1])
  expect_equal(row$uuid_feature[1], new_uuid)
  expect_false(is.na(row$uuid_feature_alias[1]))
  expect_false("unknown_feature" %in% result$review$kind)
})

test_that("R-15.30/B3: a failure on the SECOND write of add_feature()'s atomic pair rolls back the FIRST write too - the feature insert and the self-alias insert are one transaction, not two independent ones", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_feature <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  before_log <- count_change_log(con)

  # Phase-5 audit round 2 B3's real atomicity assertion (replacing the
  # unsatisfiable `unique(log_rows$at)` check above): let the FIRST
  # db_append() (feature) run for real, then force the SECOND
  # (feature_alias) to fail BEFORE it writes anything, mirroring R-12.6's
  # fault-injection idiom below but targeting add_feature()'s own two-table
  # write instead of a single db_update(). A genuinely atomic add_feature()
  # - both writes inside ONE db_transaction() - must roll the first write
  # back too; two independent with_db_write() calls would leak it.
  real_db_append <- db_append
  call_n <- 0L
  testthat::local_mocked_bindings(
    db_append = function(...) {
      call_n <<- call_n + 1L
      if (call_n >= 2L) stop("simulated second-write failure")
      real_db_append(...)
    },
    .package = "sampleTidy"
  )

  err <- tryCatch(
    add_feature(
      name = "T.NEWSELF9002", site = "T", lon = 150.7002, lat = -33.7002,
      flow = "surface", matrix = "water",
      actor = "tester", reason = "B3: second-write failure must roll back the first"
    ),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")
  expect_equal(call_n, 2,
    info = "the mock must actually reach a second db_append() call, or this proves nothing about atomicity")

  after_feature <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  after_log <- count_change_log(con)
  expect_equal(after_feature, before_feature,
    info = "the FIRST write (feature) must be rolled back when the SECOND (self alias) fails")
  expect_equal(after_log, before_log,
    info = "no change_log row may survive a rolled-back transaction")
})

# ---- Phase-7b round-2 item 10: add_feature() name-clash guard -------------
#
# `add_feature()` did not check the name's `.rc_feature_key()` was unused.
# Two calls with the same name created TWO features and TWO 'self'/
# auto_assign=TRUE arms sharing one alias_key - `.rc_feature_candidates()`
# then returns 2 candidates for that name, and `.rc_resolve_features()`
# routes it to feature_pending/unknown_feature. BOTH features become
# unreachable by their own name - the exact failure F.9 exists to prevent,
# reachable again through F.9's own fix.

test_that("Phase-7b round-2 item 10: add_feature() aborts when the name's .rc_feature_key() is already used by an existing feature_alias row, instead of minting a second unreachable 'self' arm", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  add_feature(name = "T.DUPNAME9010", site = "T", lon = 150.9010, lat = -33.9010,
              actor = "tester", reason = "first")

  before_features <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  before_aliases <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n

  err <- tryCatch(
    add_feature(name = "T.DUPNAME9010", site = "T", lon = 150.9011, lat = -33.9011,
                actor = "tester", reason = "second, same name"),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  after_features <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature")$n
  after_aliases <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_alias")$n
  expect_equal(after_features, before_features) # nothing written by the aborted second call
  expect_equal(after_aliases, before_aliases)

  # the name still resolves to exactly ONE feature through the real resolver
  # - never routed to feature_pending/unknown_feature by a phantom duplicate.
  registry <- .rc_load_registry(con)
  cand <- .rc_feature_candidates("T.DUPNAME9010", as.Date("2026-07-25"), registry)
  expect_equal(nrow(cand), 1L)
})

# ---- Phase-7b round-2 item 11: add_feature()'s self alias is not a human --
#      confirmation (CONTRACT A55) -------------------------------------------

test_that("Phase-7b round-2 item 11: add_feature()'s self alias is NOT stamped confirmed_by = actor - a machine-created arm is not a human confirmation, so it never trips .fa_confirm_one_alias()'s already_confirmed guard", {
  path <- seed_db()
  withr::local_options(list("sampletidy.live_db" = path))
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  new_uuid <- add_feature(
    name = "T.NOCONFIRM9011", site = "T", lon = 150.9021, lat = -33.9021,
    actor = "tester", reason = "F.9 self alias, no confirmed_by"
  )

  self_alias <- DBI::dbGetQuery(con, sprintf(
    "SELECT * FROM feature_alias WHERE uuid_feature = '%s' AND kind = 'self'", new_uuid
  ))
  expect_equal(nrow(self_alias), 1)
  expect_true(is.na(self_alias$confirmed_by[[1]])) # NOT actor - provenance lives in change_log alone
  expect_true(isTRUE(self_alias$auto_assign[[1]])) # F.9 still marks it auto_assign TRUE

  log_rows <- DBI::dbGetQuery(con, sprintf(
    "SELECT actor FROM change_log WHERE uuid_row = '%s'", self_alias$uuid[[1]]
  ))
  expect_true(all(log_rows$actor == "tester")) # provenance: the real actor, via change_log
})

# ---- W-F (round-2 remediation): db_append() surfaces the ORIGINAL DB error -
#
# `DBI::dbAppendTable()` on duckdb registers `df` as a temp view, INSERTs,
# then unregisters the view in an `on.exit()`. A constraint violation on the
# INSERT aborts the transaction; the `on.exit()` unregister-cleanup THEN ALSO
# fails (because the transaction is aborted), and it is that SECONDARY
# "TransactionContext Error: ... rapi_unregister_df" which used to escape -
# the primary constraint text was swallowed before db_append() ever saw it.
# Fix: `.st_append_rows()` does the register/INSERT/unregister dance itself,
# captures the primary INSERT error first, and never lets a best-effort
# cleanup failure overwrite it.

test_that("W-F: db_append() surfaces the real NOT NULL constraint text, not the masked rapi_unregister_df cleanup error", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status) VALUES
    ('rq-wf-1', CURRENT_TIMESTAMP, 'unknown_feature', 'open')")

  before_cand <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue_candidate")$n
  before_log <- count_change_log(con)

  # uuid_feature is NOT NULL on review_queue_candidate (db-schema.R version-6
  # DDL) - the exact defect scenario from the P16 Phase-7b brief.
  bad_row <- tibble::tibble(
    uuid = "rqc-wf-1", uuid_review = "rq-wf-1", uuid_feature = NA_character_,
    kind = "candidate", rank = 1L
  )

  expect_error(
    db_append(con, "review_queue_candidate", bad_row, actor = "tester", reason = "should fail"),
    regexp = "NOT NULL constraint failed", class = "sampletidy_error"
  )

  # Non-vacuous: the pre-fix wrapper message never contained this text at
  # all (only the secondary rapi_unregister_df error), so this assertion
  # would fail before the fix and only passes now that the primary error
  # reaches the caller.
  err <- tryCatch(
    db_append(con, "review_queue_candidate", bad_row, actor = "tester", reason = "should fail"),
    error = function(e) e
  )
  expect_false(
    grepl("rapi_unregister_df", conditionMessage(err), fixed = TRUE),
    info = paste("secondary cleanup error leaked through instead of the primary cause:",
                 conditionMessage(err))
  )

  # Atomicity: still zero row-count delta on the target table AND change_log.
  after_cand <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue_candidate")$n
  after_log <- count_change_log(con)
  expect_equal(after_cand, before_cand)
  expect_equal(after_log, before_log)
})

test_that("W-F: db_append() surfaces the real FOREIGN KEY constraint text, not the masked rapi_unregister_df cleanup error", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  before_cand <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue_candidate")$n
  before_log <- count_change_log(con)

  # uuid_review REFERENCES review_queue(uuid) - no such review_queue row
  # exists here, so this is a genuine FK violation, not the NOT NULL case
  # above.
  bad_row <- tibble::tibble(
    uuid = "rqc-wf-2", uuid_review = "rq-does-not-exist", uuid_feature = "f-0001",
    kind = "candidate", rank = 1L
  )

  expect_error(
    db_append(con, "review_queue_candidate", bad_row, actor = "tester", reason = "should fail"),
    regexp = "Constraint Error|foreign key", class = "sampletidy_error"
  )

  after_cand <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue_candidate")$n
  after_log <- count_change_log(con)
  expect_equal(after_cand, before_cand)
  expect_equal(after_log, before_log)
})

test_that("W-F: db_append() success path is unaffected by the .st_append_rows() rewrite - rows and change_log provenance still land", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, status) VALUES
    ('rq-wf-3', CURRENT_TIMESTAMP, 'unknown_feature', 'open')")
  before_log <- count_change_log(con)

  good_row <- tibble::tibble(
    uuid = "rqc-wf-3", uuid_review = "rq-wf-3", uuid_feature = "f-0001",
    kind = "candidate", rank = 1L
  )
  db_append(con, "review_queue_candidate", good_row, actor = "tester", reason = "normal insert")

  n <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM review_queue_candidate WHERE uuid = 'rqc-wf-3'")$n
  expect_equal(n, 1)
  after_log <- count_change_log(con)
  expect_equal(after_log - before_log, 1)
  log_row <- DBI::dbGetQuery(con, "SELECT * FROM change_log WHERE uuid_row = 'rqc-wf-3'")
  expect_equal(nrow(log_row), 1)
  expect_equal(log_row$action, "insert")
})

test_that("W-F: db_update() does NOT share the dbAppendTable masking hazard - a constraint violation already surfaces the real text (no code change needed here)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, lon, lat) VALUES
    ('f-wf-1', 'T.WF1', 'TestSite', 'surface', 'water', 150.0, -33.0)")
  before_log <- count_change_log(con)

  # feature.lon is DOUBLE NOT NULL (R-11.17); db_update() never calls
  # DBI::dbAppendTable() (plain parameterised UPDATE), so it has no
  # register/unregister step to mask the error - verified directly.
  expect_error(
    db_update(con, "feature", "f-wf-1", changes = list(lon = NA_real_),
              actor = "tester", reason = "should fail"),
    regexp = "NOT NULL constraint failed", class = "sampletidy_error"
  )

  after_log <- count_change_log(con)
  expect_equal(after_log, before_log)
  unchanged <- DBI::dbGetQuery(con, "SELECT lon FROM feature WHERE uuid = 'f-wf-1'")$lon
  expect_equal(unchanged, 150.0)
})

test_that("R-12.6: a commit-time failure rolls back the whole call and aborts sampletidy_error, leaving no partial write (dbCommit() must sit inside the tryCatch)", {
  path <- seed_db()
  con <- seed_con(path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))

  # Force DBI::dbCommit() itself to fail - a commit-time error, distinct from
  # a mutation error inside fn(con). Mocks the DBI generic the same way
  # test-commit.R mocks uuid::UUIDgenerate() (an already-loaded namespace
  # function referenced via `::` from production code).
  testthat::local_mocked_bindings(
    dbCommit = function(...) stop("simulated commit failure"),
    .package = "DBI"
  )

  before <- count_change_log(con)
  err <- tryCatch(
    db_update(con, "sample", "s-0001",
              changes = list(organisation = "ACIRL"),
              actor = "tester", reason = "forced commit failure"),
    error = function(e) e
  )
  expect_s3_class(err, "sampletidy_error")

  after <- count_change_log(con)
  expect_equal(after, before,
    info = "change_log row from the pre-commit UPDATE must be rolled back, not just uncommitted")

  unchanged <- DBI::dbGetQuery(con, "SELECT organisation FROM \"sample\" WHERE uuid = 's-0001'")
  expect_equal(unchanged$organisation, "ALS",
    info = "the pre-commit UPDATE must be rolled back, leaving no partial write")
})

test_that("round-3 S9: .st_validate_columns() names the bad columns and is classed", {
  # Before this fix the message string carried `{?s}` with TWO pluralisable
  # substitutions, so cli raised its own bare `simpleError` reading "Multiple
  # quantities for pluralization": no column named, and NOT a
  # `sampletidy_error`, so every class-based handler in the package missed the
  # column guard for the entire mutation layer. Assert the three things that
  # regression destroyed - class, the offending column name, and the table -
  # in BOTH the singular and plural branches, because the defect was in the
  # pluralisation machinery itself.
  con <- DBI::dbConnect(duckdb::duckdb())
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con, "CREATE TABLE t (a VARCHAR, b VARCHAR)")

  one <- tryCatch(.st_validate_columns(con, "t", c("a", "zzz")), error = function(e) e)
  expect_s3_class(one, "sampletidy_error")
  expect_match(conditionMessage(one), "zzz", fixed = TRUE)
  expect_match(conditionMessage(one), "\"t\"", fixed = TRUE)
  expect_false(grepl("Multiple quantities", conditionMessage(one), fixed = TRUE))

  two <- tryCatch(.st_validate_columns(con, "t", c("zzz", "yyy")), error = function(e) e)
  expect_s3_class(two, "sampletidy_error")
  expect_match(conditionMessage(two), "zzz", fixed = TRUE)
  expect_match(conditionMessage(two), "yyy", fixed = TRUE)
  expect_false(grepl("Multiple quantities", conditionMessage(two), fixed = TRUE))

  # And the guard still passes a wholly-valid column set.
  expect_silent(.st_validate_columns(con, "t", c("a", "b")))

  # Reached through a real mutation-layer entry point, not just the helper:
  # db_append() is where an operator actually meets this error. Must be an
  # ALLOWLISTED table, or `.st_validate_table()` aborts first and this stops
  # exercising the column guard at all.
  DBI::dbExecute(con, 'CREATE TABLE feature (uuid VARCHAR, name VARCHAR)')
  DBI::dbExecute(con, 'CREATE TABLE change_log (uuid VARCHAR PRIMARY KEY,
    "at" TIMESTAMP, actor VARCHAR, "action" VARCHAR, tbl VARCHAR, uuid_row VARCHAR,
    field VARCHAR, "old" VARCHAR, "new" VARCHAR, reason VARCHAR, source_hash VARCHAR)')
  appended <- tryCatch(
    db_append(con, "feature", tibble::tibble(uuid = "f1", nope = "y"),
              actor = "test", reason = "S9"),
    error = function(e) e
  )
  expect_s3_class(appended, "sampletidy_error")
  expect_match(conditionMessage(appended), "nope", fixed = TRUE)
  expect_false(grepl("Multiple quantities", conditionMessage(appended), fixed = TRUE))
})
