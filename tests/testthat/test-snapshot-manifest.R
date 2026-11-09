# PLAN-21 phase (a), section 3: the snapshot's generation in its name, the
# manifest written beside it, and read_snapshot_manifest() / verify_snapshot() /
# list_snapshots().
#
#   name      monitoring_YYYY-MM-DD_gN.duckdb when db_meta.writer_generation is a
#             non-negative integer string N, else monitoring_YYYY-MM-DD.duckdb
#   manifest  <name without .duckdb>.manifest.json beside it, written LAST
#   fields    format "sampleTidy-snapshot-manifest", manifest_version 1, file,
#             sha256, size, schema_version, db_meta {}, row_counts {},
#             max_ingest_updated_at, duckdb_version, created_at
#
# prune_snapshots() is out of scope here (another branch is changing it).
# Synthetic databases only.

# ---- helpers -------------------------------------------------------------------------------

sm_today <- function() format(Sys.Date(), "%Y-%m-%d")

sm_iso_utc <- "^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}Z$"

# Write db_meta rows straight into a database file (the table is created if
# missing, so these tests do not lean on db_meta_set()). `meta` is a named
# character vector.
sm_set_meta <- function(db, meta) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS db_meta (
    key VARCHAR PRIMARY KEY, value VARCHAR, updated_at TIMESTAMP)")
  for (k in names(meta)) {
    DBI::dbExecute(con, "DELETE FROM db_meta WHERE key = ?", params = list(k))
    DBI::dbExecute(con, "INSERT INTO db_meta VALUES (?, ?, NULL)", params = list(k, meta[[k]]))
  }
  invisible(db)
}

sm_drop_meta <- function(db) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "DROP TABLE IF EXISTS db_meta")
  invisible(db)
}

sm_exec <- function(db, sql) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, sql)
}

sm_query <- function(db, sql) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql)
}

sm_manifest_path <- function(snapshot) sub("\\.duckdb$", ".manifest.json", snapshot)

sm_read <- function(path) jsonlite::read_json(path, simplifyVector = FALSE)

sm_raw <- function(path) paste(readLines(path, warn = FALSE), collapse = "\n")

sm_sha <- function(path) digest::digest(file = path, algo = "sha256")

sm_snap <- function(db, dest) suppressMessages(snapshot_db(db = db, dest_dir = dest))

# Every base table in schema main of a database file, with its row count.
sm_counts <- function(db) {
  t <- sm_query(db, "SELECT table_name FROM information_schema.tables
                      WHERE table_schema = 'main' AND table_type = 'BASE TABLE'")$table_name
  out <- vapply(t, function(x) {
    as.integer(sm_query(db, sprintf('SELECT count(*) AS n FROM "%s"', x))$n)
  }, integer(1))
  out[order(names(out))]
}

# A database with one plain table `t` holding 3 rows: no ops schema at all.
sm_plain_db <- function(env = parent.frame()) {
  db <- file.path(withr::local_tempdir(.local_envir = env), "plain.duckdb")
  sm_exec(db, "CREATE TABLE t (x INTEGER)")
  sm_exec(db, "INSERT INTO t VALUES (1), (2), (3)")
  db
}

#' A synthetic snapshot + manifest pair in `dir` (list_snapshots() reads only
#' the manifest). `gen` NA means no writer_generation in db_meta and no _g in
#' the name. The snapshot file holds `bytes` bytes, deliberately not `size`.
sm_fake <- function(dir, date, gen = NA, created_at, size = 1000, sha = NULL,
                    bytes = 10, label = "machine-a") {
  name <- if (is.na(gen)) sprintf("monitoring_%s", date) else sprintf("monitoring_%s_g%d", date, gen)
  snap <- file.path(dir, paste0(name, ".duckdb"))
  writeBin(as.raw(rep(1L, bytes)), snap)
  meta <- if (is.na(gen)) stats::setNames(list(), character(0)) else
    list(writer_generation = as.character(gen), writer_label = label)
  if (is.null(sha)) sha <- digest::digest(paste(name, created_at), algo = "sha256", serialize = FALSE)
  m <- list(format = "sampleTidy-snapshot-manifest", manifest_version = 1L,
            file = basename(snap), sha256 = sha, size = size, schema_version = 11L,
            db_meta = meta, row_counts = list(t = 3L), max_ingest_updated_at = NULL,
            duckdb_version = "1.0.0", created_at = created_at)
  jsonlite::write_json(m, file.path(dir, paste0(name, ".manifest.json")),
                       auto_unbox = TRUE, pretty = TRUE, null = "null", digits = NA)
  snap
}

sm_cols <- c("file", "path", "manifest", "date", "generation", "created_at", "size", "sha256")

# ---- the name -------------------------------------------------------------------------------

test_that("with no db_meta table the snapshot keeps today's name, with its manifest beside it", {
  db <- seed_db()
  sm_drop_meta(db)
  dest <- withr::local_tempdir()
  p <- sm_snap(db, dest)
  expect_identical(basename(p), sprintf("monitoring_%s.duckdb", sm_today()))
  expect_true(file.exists(p))
  expect_true(file.exists(file.path(dest, sprintf("monitoring_%s.manifest.json", sm_today()))))
})

test_that("db_meta without writer_generation: today's name", {
  db <- seed_db()
  sm_set_meta(db, c(writer_label = "machine-a"))
  p <- sm_snap(db, withr::local_tempdir())
  expect_identical(basename(p), sprintf("monitoring_%s.duckdb", sm_today()))
})

test_that("writer_generation N puts _gN in the snapshot's and the manifest's names, and snapshot_db() returns that path", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "1", writer_label = "machine-a"))
  dest <- withr::local_tempdir()
  p <- sm_snap(db, dest)
  expect_identical(basename(p), sprintf("monitoring_%s_g1.duckdb", sm_today()))
  expect_true(file.exists(p))
  expect_true(file.exists(file.path(dest, sprintf("monitoring_%s_g1.manifest.json", sm_today()))))
  expect_false(file.exists(file.path(dest, sprintf("monitoring_%s.duckdb", sm_today()))))
})

test_that("generation 0 and a multi-digit generation are used as given", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "0"))
  expect_identical(basename(sm_snap(db, withr::local_tempdir())),
                   sprintf("monitoring_%s_g0.duckdb", sm_today()))
  sm_set_meta(db, c(writer_generation = "12"))
  expect_identical(basename(sm_snap(db, withr::local_tempdir())),
                   sprintf("monitoring_%s_g12.duckdb", sm_today()))
})

test_that("a writer_generation that is not a non-negative integer string is ignored: today's name", {
  db <- seed_db()
  for (g in c("-1", "1.5", "abc", "", "g2")) {
    sm_set_meta(db, c(writer_generation = g))
    p <- sm_snap(db, withr::local_tempdir())
    expect_identical(basename(p), sprintf("monitoring_%s.duckdb", sm_today()), info = g)
  }
})

# ---- the manifest -----------------------------------------------------------------------------

test_that("the manifest has every field, describing the snapshot file on disk", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "3", writer_label = "machine-a"))
  sm_exec(db, "UPDATE ingest_file SET updated_at = TIMESTAMP '2026-10-01 00:00:00'")
  sm_exec(db, "INSERT INTO ingest_file (hash, state, updated_at)
               VALUES ('h-later', 'archived', TIMESTAMP '2026-10-05 03:04:05')")
  dest <- withr::local_tempdir()
  t0 <- Sys.time()
  p <- sm_snap(db, dest)
  mp <- sm_manifest_path(p)
  m <- sm_read(mp)
  expect_gte(as.numeric(file.mtime(mp)), as.numeric(file.mtime(p)))   # written last

  expect_setequal(names(m), c("format", "manifest_version", "file", "sha256", "size",
                              "schema_version", "db_meta", "row_counts",
                              "max_ingest_updated_at", "duckdb_version", "created_at"))
  expect_identical(m$format, "sampleTidy-snapshot-manifest")
  expect_identical(as.integer(m$manifest_version), 1L)
  expect_identical(m$file, basename(p))
  expect_identical(m$sha256, sm_sha(p))
  expect_match(m$sha256, "^[0-9a-f]{64}$")
  expect_true(is.numeric(m$size))
  expect_equal(m$size, file.size(p))
  want_sv <- max(sm_query(p, "SELECT version FROM schema_version")$version)
  expect_equal(m$schema_version, want_sv)
  expect_identical(m$db_meta, list(writer_generation = "3", writer_label = "machine-a")[names(m$db_meta)])
  expect_setequal(names(m$db_meta), c("writer_generation", "writer_label"))
  rc <- unlist(m$row_counts)
  expect_identical(sort(names(rc)), names(sm_counts(p)))
  expect_equal(rc[names(sm_counts(p))], sm_counts(p))
  expect_true(all(c("analysis", "ingest_file", "db_meta") %in% names(rc)))
  expect_equal(unname(rc[["ingest_file"]]), 2)
  expect_identical(m$max_ingest_updated_at, "2026-10-05T03:04:05Z")
  expect_identical(m$duckdb_version, as.character(utils::packageVersion("duckdb")))
  expect_match(m$created_at, sm_iso_utc)
  created <- as.POSIXct(m$created_at, format = "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  expect_true(created >= t0 - 5 && created <= Sys.time() + 5)
})

test_that("the manifest is pretty JSON with scalars unboxed", {
  db <- seed_db()
  p <- sm_snap(db, withr::local_tempdir())
  raw <- sm_raw(sm_manifest_path(p))
  expect_gt(length(strsplit(raw, "\n")[[1]]), 5)
  expect_match(raw, "\"format\":\\s*\"sampleTidy-snapshot-manifest\"")
  expect_match(raw, "\"manifest_version\":\\s*1\\b")
  expect_match(raw, "\"size\":\\s*[0-9]")
})

test_that("a database with no ops schema: schema_version and max_ingest_updated_at null, db_meta {}, row_counts of its one table", {
  db <- sm_plain_db()
  dest <- withr::local_tempdir()
  p <- sm_snap(db, dest)
  expect_identical(basename(p), sprintf("monitoring_%s.duckdb", sm_today()))
  mp <- sm_manifest_path(p)
  m <- sm_read(mp)
  expect_true("schema_version" %in% names(m))
  expect_null(m$schema_version)
  expect_true("max_ingest_updated_at" %in% names(m))
  expect_null(m$max_ingest_updated_at)
  raw <- sm_raw(mp)
  expect_match(raw, "\"schema_version\":\\s*null")
  expect_match(raw, "\"max_ingest_updated_at\":\\s*null")
  expect_match(raw, "\"db_meta\":\\s*\\{\\s*\\}")
  expect_identical(m$row_counts, list(t = 3L))
})

test_that("an ingest_file with no updated_at values: max_ingest_updated_at is null; an empty db_meta is {}", {
  db <- seed_db()
  sm_exec(db, "UPDATE ingest_file SET updated_at = NULL")
  sm_exec(db, "CREATE TABLE IF NOT EXISTS db_meta (key VARCHAR PRIMARY KEY, value VARCHAR, updated_at TIMESTAMP)")
  sm_exec(db, "DELETE FROM db_meta")
  p <- sm_snap(db, withr::local_tempdir())
  m <- sm_read(sm_manifest_path(p))
  expect_null(m$max_ingest_updated_at)
  expect_match(sm_raw(sm_manifest_path(p)), "\"db_meta\":\\s*\\{\\s*\\}")
})

test_that("after a snapshot into an empty folder it holds exactly the snapshot and its manifest (no tmp files)", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "2"))
  dest <- withr::local_tempdir()
  p <- sm_snap(db, dest)
  expect_setequal(list.files(dest, all.files = TRUE, no.. = TRUE),
                  c(basename(p), basename(sm_manifest_path(p))))
})

test_that("a same-day re-snapshot replaces the manifest too: it describes the new file", {
  db <- seed_db()
  dest <- withr::local_tempdir()
  p1 <- sm_snap(db, dest)
  m1 <- sm_read(sm_manifest_path(p1))
  sm_exec(db, "CREATE TABLE extra AS SELECT range AS i FROM range(5000)")
  p2 <- sm_snap(db, dest)
  expect_identical(p2, p1)
  m2 <- sm_read(sm_manifest_path(p2))
  expect_identical(m2$sha256, sm_sha(p2))
  expect_equal(m2$size, file.size(p2))
  expect_false(identical(m2$sha256, m1$sha256))
  expect_equal(m2$row_counts$extra, 5000)
  expect_length(list.files(dest, pattern = "manifest", all.files = TRUE), 1)
})

test_that("a stale same-day manifest describing other bytes is replaced by one describing the new snapshot", {
  db <- seed_db()
  dest <- withr::local_tempdir()
  stale <- file.path(dest, sprintf("monitoring_%s.manifest.json", sm_today()))
  jsonlite::write_json(list(format = "sampleTidy-snapshot-manifest", manifest_version = 1L,
                            file = sprintf("monitoring_%s.duckdb", sm_today()),
                            sha256 = strrep("0", 64), size = 1),
                       stale, auto_unbox = TRUE)
  p <- sm_snap(db, dest)
  m <- sm_read(stale)
  expect_identical(m$sha256, sm_sha(p))
  expect_identical(verify_snapshot(p), TRUE)
})

test_that("a failed same-day re-snapshot leaves no manifest that disagrees with the snapshot on disk", {
  db <- seed_db()
  dest <- withr::local_tempdir()
  good <- sm_snap(db, dest)
  empty <- file.path(withr::local_tempdir(), "empty.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), empty, read_only = FALSE)
  DBI::dbDisconnect(con, shutdown = TRUE)
  err <- tryCatch(sm_snap(empty, dest), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  mp <- sm_manifest_path(good)
  if (file.exists(mp)) {
    expect_identical(sm_read(mp)$sha256, sm_sha(good))
    expect_equal(sm_read(mp)$size, file.size(good))
  } else {
    succeed("the manifest was removed before the replacement was attempted")
  }
})

test_that("a refused snapshot (missing db) writes no manifest", {
  dest <- withr::local_tempdir()
  err <- tryCatch(sm_snap(file.path(withr::local_tempdir(), "nope.duckdb"), dest),
                  error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_length(list.files(dest, all.files = TRUE, no.. = TRUE), 0)
})

# ---- read_snapshot_manifest() -----------------------------------------------------------------

test_that("read_snapshot_manifest, verify_snapshot and list_snapshots are exported", {
  ex <- getNamespaceExports("sampleTidy")
  expect_true(all(c("read_snapshot_manifest", "verify_snapshot", "list_snapshots") %in% ex))
})

test_that("read_snapshot_manifest() reads a manifest given its own path or its snapshot's path", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "2", writer_label = "machine-b"))
  p <- sm_snap(db, withr::local_tempdir())
  a <- read_snapshot_manifest(sm_manifest_path(p))
  b <- read_snapshot_manifest(p)
  expect_type(a, "list")
  expect_identical(a, b)
  expect_identical(a$format, "sampleTidy-snapshot-manifest")
  expect_identical(a$file, basename(p))
  expect_identical(a$sha256, sm_sha(p))
  expect_identical(a$db_meta$writer_generation, "2")
  expect_identical(a$db_meta$writer_label, "machine-b")
})

test_that("read_snapshot_manifest() aborts sampletidy_error when the manifest is missing", {
  dir <- withr::local_tempdir()
  snap <- file.path(dir, "monitoring_2026-11-01.duckdb")
  writeBin(as.raw(1:10), snap)
  expect_error(read_snapshot_manifest(snap), class = "sampletidy_error")
  expect_error(read_snapshot_manifest(file.path(dir, "monitoring_2026-11-02.manifest.json")),
               class = "sampletidy_error")
})

test_that("read_snapshot_manifest() aborts sampletidy_error on a file that is not a manifest of this format", {
  dir <- withr::local_tempdir()
  other <- file.path(dir, "monitoring_2026-11-01.manifest.json")
  jsonlite::write_json(list(format = "something-else", manifest_version = 1L), other, auto_unbox = TRUE)
  expect_error(read_snapshot_manifest(other), class = "sampletidy_error")
  writeLines("not json {", other)
  expect_error(read_snapshot_manifest(other), class = "sampletidy_error")
  writeLines("[1, 2, 3]", other)
  expect_error(read_snapshot_manifest(other), class = "sampletidy_error")
})

# ---- verify_snapshot() ------------------------------------------------------------------------

test_that("verify_snapshot() is TRUE for a fresh snapshot, with and without a generation", {
  db <- seed_db()
  dest <- withr::local_tempdir()
  expect_identical(verify_snapshot(sm_snap(db, dest)), TRUE)
  sm_set_meta(db, c(writer_generation = "5"))
  expect_identical(verify_snapshot(sm_snap(db, dest)), TRUE)
})

test_that("verify_snapshot(): one changed byte (same size) is a sha256 problem", {
  db <- seed_db()
  p <- sm_snap(db, withr::local_tempdir())
  n <- file.size(p)
  bytes <- readBin(p, "raw", n)
  bytes[n - 10] <- as.raw(bitwXor(as.integer(bytes[n - 10]), 0xFFL))
  writeBin(bytes, p)
  expect_equal(file.size(p), n)
  v <- verify_snapshot(p)   # a problem, never an error
  expect_type(v, "character")
  expect_gte(length(v), 1)
  expect_true(any(grepl("sha256", v, ignore.case = TRUE)))
  expect_false(any(grepl("size", v, ignore.case = TRUE)))
})

test_that("verify_snapshot(): a truncated snapshot is a size problem", {
  db <- seed_db()
  p <- sm_snap(db, withr::local_tempdir())
  n <- file.size(p)
  writeBin(readBin(p, "raw", n)[seq_len(n %/% 2)], p)
  v <- verify_snapshot(p)   # a problem, never an error
  expect_type(v, "character")
  expect_true(any(grepl("size", v, ignore.case = TRUE)))
})

test_that("verify_snapshot(): a missing manifest is a problem, not an error", {
  db <- seed_db()
  p <- sm_snap(db, withr::local_tempdir())
  file.remove(sm_manifest_path(p))
  v <- verify_snapshot(p)   # a problem, never an error
  expect_type(v, "character")
  expect_gte(length(v), 1)
  expect_true(any(grepl("manifest", v, ignore.case = TRUE)))
})

test_that("verify_snapshot(): a missing snapshot (manifest still there) is a problem, not an error", {
  db <- seed_db()
  p <- sm_snap(db, withr::local_tempdir())
  file.remove(p)
  v <- verify_snapshot(p)   # a problem, never an error
  expect_type(v, "character")
  expect_gte(length(v), 1)
  expect_false(isTRUE(v))
})

test_that("verify_snapshot(): neither snapshot nor manifest is a problem, not an error", {
  v <- verify_snapshot(file.path(withr::local_tempdir(), "monitoring_2026-11-01.duckdb"))
  expect_type(v, "character")
  expect_gte(length(v), 1)
})

# ---- list_snapshots() -------------------------------------------------------------------------

test_that("list_snapshots() of an empty folder is zero rows with the same columns and types", {
  x <- list_snapshots(withr::local_tempdir())
  expect_s3_class(x, "data.frame")
  expect_identical(nrow(x), 0L)
  expect_identical(names(x), sm_cols)
  expect_type(x$file, "character")
  expect_type(x$path, "character")
  expect_type(x$manifest, "character")
  expect_s3_class(x$date, "Date")
  expect_type(x$generation, "integer")
  expect_s3_class(x$created_at, "POSIXct")
  expect_type(x$sha256, "character")
  expect_true(is.numeric(x$size))
})

test_that("list_snapshots() lists only snapshots that have a manifest, newest generation first, then date, NA generation last", {
  dir <- withr::local_tempdir()
  sm_fake(dir, "2026-11-01", 10, "2026-11-01T01:00:00Z")   # A
  sm_fake(dir, "2026-11-05", 9, "2026-11-05T01:00:00Z")    # B
  sm_fake(dir, "2026-11-03", 10, "2026-11-03T01:00:00Z")   # C
  sm_fake(dir, "2026-11-09", NA, "2026-11-09T01:00:00Z")   # D
  sm_fake(dir, "2026-11-08", NA, "2026-11-08T01:00:00Z")   # F
  # no manifest: not listed
  writeBin(as.raw(1:10), file.path(dir, "monitoring_2026-11-07.duckdb"))
  writeBin(as.raw(1:10), file.path(dir, "monitoring_2026-11-10_g11.duckdb"))
  writeLines("x", file.path(dir, "notes.txt"))

  x <- list_snapshots(dir)
  expect_identical(names(x), sm_cols)
  expect_identical(x$file, c("monitoring_2026-11-03_g10.duckdb", "monitoring_2026-11-01_g10.duckdb",
                             "monitoring_2026-11-05_g9.duckdb", "monitoring_2026-11-09.duckdb",
                             "monitoring_2026-11-08.duckdb"))
  expect_identical(x$generation, c(10L, 10L, 9L, NA, NA))
  expect_identical(x$date, as.Date(c("2026-11-03", "2026-11-01", "2026-11-05", "2026-11-09", "2026-11-08")))
})

test_that("list_snapshots() columns: path and manifest beside each other, created_at POSIXct UTC, size and sha256 from the manifest", {
  dir <- withr::local_tempdir()
  sha <- strrep("ab", 32)
  snap <- sm_fake(dir, "2026-11-04", 2, "2026-11-04T05:06:07Z", size = 123456, sha = sha, bytes = 7)
  x <- list_snapshots(dir)
  expect_identical(nrow(x), 1L)
  expect_identical(x$file, basename(snap))
  expect_identical(normalizePath(x$path), normalizePath(snap))
  expect_identical(normalizePath(x$manifest),
                   normalizePath(file.path(dir, "monitoring_2026-11-04_g2.manifest.json")))
  expect_s3_class(x$created_at, "POSIXct")
  expect_identical(attr(x$created_at, "tzone"), "UTC")
  expect_equal(as.numeric(x$created_at),
               as.numeric(as.POSIXct("2026-11-04 05:06:07", tz = "UTC")))
  expect_equal(as.numeric(x$size), 123456)
  expect_identical(x$sha256, sha)
})

test_that("list_snapshots() never reads snapshot bytes: unreadable snapshot files are still listed from their manifests", {
  skip_on_os("windows")
  skip_if(identical(Sys.info()[["user"]], "root"), "root can read a mode-000 file")
  dir <- withr::local_tempdir()
  a <- sm_fake(dir, "2026-11-01", 1, "2026-11-01T01:00:00Z", size = 999)
  b <- sm_fake(dir, "2026-11-02", 1, "2026-11-02T01:00:00Z", size = 888)
  Sys.chmod(c(a, b), "000")
  withr::defer(Sys.chmod(c(a, b), "644"))
  x <- list_snapshots(dir)
  expect_identical(x$file, basename(c(b, a)))
  expect_equal(as.numeric(x$size), c(888, 999))
})

test_that("list_snapshots() agrees with a real snapshot_db() run", {
  db <- seed_db()
  sm_set_meta(db, c(writer_generation = "4", writer_label = "machine-a"))
  dest <- withr::local_tempdir()
  p <- sm_snap(db, dest)
  x <- list_snapshots(dest)
  expect_identical(nrow(x), 1L)
  expect_identical(x$file, basename(p))
  expect_identical(x$generation, 4L)
  expect_identical(x$date, Sys.Date())
  expect_identical(x$sha256, sm_sha(p))
  expect_equal(as.numeric(x$size), file.size(p))
})
