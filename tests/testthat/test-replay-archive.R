# replay_archive(): re-import archived files that a database does not know.
#
# A deployment that moves its importer to another machine from a snapshot
# (a forced takeover) can lose the imports made after that snapshot. Their
# inputs are not lost: every imported file was copied into the archive
# (`<archive_dir>/<asset uuid>/<original name>`, archive_file()) before its
# input was removed. replay_archive() lists the archived files the database
# does not know and, on request, puts copies back into the input folder so
# the normal import takes them again, KEEPING THEIR ORIGINAL ASSET UUIDS.
#
# ---------------------------------------------------------------- API (spec)
#
# replay_archive(db = st_config("live_db"), archive_dir = st_config("archive_dir"),
#                input_dir = st_config("input_dir"), batch = NULL, dry_run = TRUE)
#
# - `db` is opened READ-ONLY and never written (not even a WAL or a lock left
#   behind); a missing `db` aborts `sampletidy_error` and creates nothing.
#   A missing `archive_dir` aborts `sampletidy_error`.
# - Known to `db`: asset uuids (`asset.uuid`, `ingest_file.uuid_asset`), byte
#   hashes (`ingest_file.hash`, `asset.hash`) and content hashes
#   (`asset.content_hash`, non-NULL). A database lacking any of these tables
#   or columns is tolerated: what is absent is simply not known.
# - The archive walk: only TOP-LEVEL folders whose name is a UUID
#   (8-4-4-4-12 hex digits) are considered; anything else at the top level (a
#   leftovers folder such as `filed-mail`, loose files, `.DS_Store`) is
#   ignored. A folder named by a KNOWN asset uuid is skipped WITHOUT READING
#   its files (the archive is a cloud folder that downloads on read). In the
#   other folders every non-hidden regular file is hashed with `hash_file()`
#   (the seam the tests count); a known byte hash -> not listed; else
#   `content_fingerprint()`; a non-NA content hash that is known -> not
#   listed (an Office file the cloud store rewrote). Everything else is
#   listed.
# - Returns a data frame, one row per listed file, ordered by folder then
#   file: `path`, `folder` (the folder name = the original asset uuid),
#   `file`, `size`, `hash`, `content_hash` (NA when none), `duplicate`,
#   `copied_to` (NA in a dry run). Two listed files with the same byte hash
#   are both listed; all but the first (in that order) have
#   `duplicate = TRUE`, and only the first is ever copied. Invisible when
#   `dry_run = FALSE`.
# - `dry_run = FALSE` copies each non-duplicate listed file into
#   `file.path(input_dir, batch)` (created if needed; `input_dir` itself must
#   exist, else abort `sampletidy_error`). `batch` defaults to `replay-g<N>`,
#   `N` being the db's `db_meta` `writer_generation`, or `replay` when it has
#   none. If the configured batch recogniser (`st_config("inbox_batches")`)
#   has a pattern the batch name does not match, it aborts `sampletidy_error`
#   before copying anything (the import would never see the files).
#   A file already in the batch folder with the same byte hash is not copied
#   again; a name taken by different content gets the first 8 characters of
#   its source folder name as a prefix. Copies go through a temporary name
#   and a rename. The batch folder's visible (non-hidden) files are exactly
#   the copies: any bookkeeping it needs is hidden.
# - Keeping the uuid: when the import archives a replayed file, the new asset
#   row takes the ORIGINAL uuid (the archive folder it came from) and the
#   file is not copied into a new archive folder. A second replay after that
#   import lists nothing; a second replay before it copies nothing new.
#
# Every database here is a tiny synthetic DuckDB; archives and inputs are temp
# folders. The end-to-end test uses the synthetic esdat fixtures of
# helper-inbox.R.

# ---- helpers ---------------------------------------------------------------------------------

ra_uuid <- function() uuid::UUIDgenerate()

# A tiny database with `asset`, `ingest_file` and (optionally) `db_meta`.
# `assets` / `ingest` are data frames of the rows to insert (columns as named
# in the DDL; missing columns are NULL). Returns the closed path.
ra_db <- function(dir, assets = NULL, ingest = NULL, generation = NA_character_,
                  asset_table = TRUE, content_cols = TRUE, ingest_table = TRUE) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  db <- file.path(dir, "live.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbExecute(con, "CREATE TABLE other (x INTEGER)")
  if (ingest_table) {
    DBI::dbExecute(con, paste("CREATE TABLE ingest_file (hash VARCHAR PRIMARY KEY, filename VARCHAR,",
                              "state VARCHAR, uuid_asset VARCHAR)"))
    if (!is.null(ingest)) DBI::dbAppendTable(con, "ingest_file", ingest)
  }
  if (asset_table) {
    DBI::dbExecute(con, if (content_cols) {
      paste("CREATE TABLE asset (uuid VARCHAR PRIMARY KEY, filename VARCHAR, hash VARCHAR,",
            "content_hash VARCHAR, content_hash_alg VARCHAR)")
    } else {
      "CREATE TABLE asset (uuid VARCHAR PRIMARY KEY, filename VARCHAR, hash VARCHAR)"
    })
    if (!is.null(assets)) DBI::dbAppendTable(con, "asset", assets)
  }
  if (!is.na(generation)) {
    DBI::dbExecute(con, "CREATE TABLE db_meta (key VARCHAR PRIMARY KEY, value VARCHAR, updated_at TIMESTAMP)")
    DBI::dbExecute(con, "INSERT INTO db_meta VALUES ('writer_generation', ?, TIMESTAMP '2026-11-09 00:00:00')",
                   params = list(as.character(generation)))
  }
  db
}

# Writes `<archive>/<folder>/<name>` holding `text` (or raw `bytes`).
ra_put <- function(archive, folder, name, text = NULL, bytes = NULL) {
  d <- file.path(archive, folder)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  p <- file.path(d, name)
  if (!is.null(bytes)) writeBin(bytes, p) else writeLines(text, p)
  p
}

# A world: an archive, an input folder and a db folder in one temp root, and
# the batch recogniser cleared (a test sets its own).
ra_world <- function(env = parent.frame()) {
  root <- normalizePath(withr::local_tempdir(.local_envir = env))
  dirs <- list(root = root, archive = file.path(root, "archive"), input = file.path(root, "input"),
               dbdir = file.path(root, "db"))
  dir.create(dirs$archive)
  dir.create(dirs$input)
  withr::local_options(list(sampletidy.inbox_batches = NULL), .local_envir = env)
  dirs
}

ra_quiet <- function(expr) suppressWarnings(suppressMessages(expr))

# Every file under `dir` -> "size|mtime|md5" (proves nothing was written).
ra_tree <- function(dir) {
  f <- list.files(dir, recursive = TRUE, all.files = TRUE, full.names = TRUE, no.. = TRUE)
  if (!length(f)) return(character(0))
  info <- file.info(f)
  stats::setNames(paste(info$size, as.numeric(info$mtime), unname(tools::md5sum(f)), sep = "|"),
                  substring(f, nchar(dir) + 2L))
}

ra_visible <- function(dir) {
  if (!dir.exists(dir)) return(character(0))
  f <- list.files(dir, full.names = TRUE)
  sort(basename(f[!dir.exists(f)]))
}

ra_cols <- c("path", "folder", "file", "size", "hash", "content_hash", "duplicate", "copied_to")

# ---- what is listed --------------------------------------------------------------------------

test_that("replay_archive() exists and is exported", {
  expect_true("replay_archive" %in% getNamespaceExports("sampleTidy"))
})

test_that("an archive whose folders are all known lists nothing, with the documented columns", {
  w <- ra_world()
  u1 <- ra_uuid(); u2 <- ra_uuid()
  ra_put(w$archive, u1, "a.csv", "known by asset uuid")
  ra_put(w$archive, u2, "b.csv", "known by ingest_file.uuid_asset only")
  db <- ra_db(w$dbdir,
              assets = data.frame(uuid = u1, filename = "a.csv", hash = "h-a"),
              ingest = data.frame(hash = "h-b", filename = "b.csv", state = "archived", uuid_asset = u2))
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_s3_class(r, "data.frame")
  expect_true(all(ra_cols %in% names(r)))
  expect_equal(nrow(r), 0L)
})

test_that("a file in an unknown folder is listed with its path, folder, size, hashes and no copy", {
  w <- ra_world()
  u <- ra_uuid()
  p <- ra_put(w$archive, u, "ES0000001_results.csv", c("a,b", "1,2"))
  db <- ra_db(w$dbdir)
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_equal(nrow(r), 1L)
  expect_equal(normalizePath(r$path[[1]]), normalizePath(p))
  expect_identical(r$folder[[1]], u)
  expect_identical(r$file[[1]], "ES0000001_results.csv")
  expect_equal(as.numeric(r$size[[1]]), as.numeric(file.size(p)))
  expect_identical(r$hash[[1]], hash_file(p))
  expect_true(is.na(r$content_hash[[1]]))
  expect_false(r$duplicate[[1]])
  expect_true(is.na(r$copied_to[[1]]))
})

test_that("a known byte hash (ingest_file.hash or asset.hash) is not listed: a duplicate archive copy", {
  w <- ra_world()
  p1 <- ra_put(w$archive, ra_uuid(), "x.csv", "same bytes as an ingest_file row")
  p2 <- ra_put(w$archive, ra_uuid(), "y.csv", "same bytes as an asset row")
  p3 <- ra_put(w$archive, ra_uuid(), "z.csv", "unknown")
  db <- ra_db(w$dbdir,
              assets = data.frame(uuid = ra_uuid(), filename = "y.csv", hash = hash_file(p2)),
              ingest = data.frame(hash = hash_file(p1), filename = "x.csv", state = "archived",
                                  uuid_asset = NA_character_))
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r$file, "z.csv")
})

test_that("an Office file the cloud store rewrote (same content hash, other bytes) is not listed", {
  w <- ra_world()
  base <- list("Workbook" = cfb_bytes(9000, 1), "\001CompObj" = cfb_bytes(113, 2),
               "\005SummaryInformation" = cfb_bytes(240, 3))
  rewritten <- c(base, list("MsoDataStore/Store1/Item" = cfb_bytes(2000, 20),
                            "MsoDataStore/Store1/Properties" = cfb_bytes(400, 21)))
  orig <- file.path(w$root, "orig.xls")
  cfb_write(orig, base)
  fp <- content_fingerprint(orig)
  skip_if(is.na(fp$content_hash), "no content fingerprinter for compound files")
  p <- file.path(w$archive, ra_uuid(), "site.xls")
  dir.create(dirname(p))
  cfb_write(p, rewritten)
  expect_false(identical(hash_file(p), hash_file(orig)))
  expect_identical(content_fingerprint(p)$content_hash, fp$content_hash)
  db <- ra_db(w$dbdir, assets = data.frame(uuid = ra_uuid(), filename = "site.xls",
                                           hash = hash_file(orig), content_hash = fp$content_hash,
                                           content_hash_alg = fp$content_hash_alg))
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_equal(nrow(r), 0L)

  # The same file with an unknown content hash is listed, with its content hash.
  db2 <- ra_db(file.path(w$root, "db2"))
  r2 <- ra_quiet(replay_archive(db = db2, archive_dir = w$archive, input_dir = w$input))
  expect_equal(nrow(r2), 1L)
  expect_identical(r2$content_hash[[1]], fp$content_hash)
})

test_that("a folder named by a known uuid is skipped without reading (hashing) its files", {
  w <- ra_world()
  known <- ra_uuid(); unknown <- ra_uuid()
  ra_put(w$archive, known, "known.csv", "do not read me")
  pu <- ra_put(w$archive, unknown, "new.csv", "read me")
  db <- ra_db(w$dbdir, assets = data.frame(uuid = known, filename = "known.csv", hash = "h"))
  hashed <- character(0)
  fingerprinted <- character(0)
  real_hash <- hash_file
  real_fp <- content_fingerprint
  testthat::local_mocked_bindings(
    hash_file = function(path, ...) {
      hashed <<- c(hashed, normalizePath(path))
      real_hash(path, ...)
    },
    content_fingerprint = function(path, ...) {
      fingerprinted <<- c(fingerprinted, normalizePath(path))
      real_fp(path, ...)
    })
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r$file, "new.csv")
  expect_true(normalizePath(pu) %in% hashed)
  expect_false(any(grepl(known, c(hashed, fingerprinted), fixed = TRUE)))
})

test_that("only uuid-named top-level folders are walked: leftovers folders, loose and hidden files are ignored", {
  w <- ra_world()
  u <- ra_uuid()
  ra_put(w$archive, u, "data.csv", "listed")
  ra_put(w$archive, u, ".DS_Store", "hidden: not listed")
  ra_put(w$archive, "filed-mail", "note.txt", "a leftovers folder")
  ra_put(w$archive, "filed-mail/sub", "deep.txt", "deeper")
  ra_put(w$archive, "not-a-uuid-1234", "x.csv", "not a uuid folder")
  writeLines("loose", file.path(w$archive, "loose.csv"))
  writeLines("ds", file.path(w$archive, ".DS_Store"))
  db <- ra_db(w$dbdir)
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r$folder, u)
  expect_identical(r$file, "data.csv")
})

test_that("rows are ordered by folder then file; equal bytes in two folders: both listed, all but the first are duplicates", {
  w <- ra_world()
  us <- sort(c(ra_uuid(), ra_uuid(), ra_uuid()))
  ra_put(w$archive, us[3], "late.csv", "same bytes")
  ra_put(w$archive, us[1], "b.csv", "other bytes")
  ra_put(w$archive, us[1], "a.csv", "same bytes")
  ra_put(w$archive, us[2], "c.csv", "same bytes")
  db <- ra_db(w$dbdir)
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r$folder, c(us[1], us[1], us[2], us[3]))
  expect_identical(r$file, c("a.csv", "b.csv", "c.csv", "late.csv"))
  expect_identical(r$duplicate, c(FALSE, FALSE, TRUE, TRUE))
})

test_that("a database without asset, without its content columns, or without ingest_file is tolerated", {
  w <- ra_world()
  u <- ra_uuid()
  p <- ra_put(w$archive, u, "a.csv", "bytes")
  u2 <- ra_uuid()
  ra_put(w$archive, u2, "b.csv", "more bytes")

  db1 <- ra_db(file.path(w$root, "d1"), asset_table = FALSE,
               ingest = data.frame(hash = hash_file(p), filename = "a.csv", state = "archived",
                                   uuid_asset = NA_character_))
  r1 <- ra_quiet(replay_archive(db = db1, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r1$file, "b.csv")

  db2 <- ra_db(file.path(w$root, "d2"), content_cols = FALSE,
               assets = data.frame(uuid = u, filename = "a.csv", hash = "h"))
  r2 <- ra_quiet(replay_archive(db = db2, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r2$file, "b.csv")

  db3 <- ra_db(file.path(w$root, "d3"), ingest_table = FALSE,
               assets = data.frame(uuid = u2, filename = "b.csv", hash = "h2",
                                   content_hash = NA_character_, content_hash_alg = NA_character_))
  r3 <- ra_quiet(replay_archive(db = db3, archive_dir = w$archive, input_dir = w$input))
  expect_identical(r3$file, "a.csv")
})

# ---- refusals and read-only ------------------------------------------------------------------

test_that("a missing db aborts and creates nothing; a missing archive aborts", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "a.csv", "x")
  missing_db <- file.path(w$root, "nope", "live.duckdb")
  expect_error(ra_quiet(replay_archive(db = missing_db, archive_dir = w$archive, input_dir = w$input)),
               class = "sampletidy_error")
  expect_false(file.exists(missing_db))
  expect_false(dir.exists(dirname(missing_db)))
  db <- ra_db(w$dbdir)
  expect_error(ra_quiet(replay_archive(db = db, archive_dir = file.path(w$root, "no-archive"),
                                       input_dir = w$input)),
               class = "sampletidy_error")
})

test_that("the db is never written, in a dry run or a real one", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "a.csv", "x")
  db <- ra_db(w$dbdir, generation = "3")
  before <- ra_tree(w$dbdir)
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = TRUE))
  expect_identical(ra_tree(w$dbdir), before)
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  expect_identical(ra_tree(w$dbdir), before)
})

test_that("a dry run writes nothing anywhere", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "a.csv", "x")
  db <- ra_db(w$dbdir, generation = "2")
  before <- ra_tree(w$root)
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input))
  expect_equal(nrow(r), 1L)
  expect_identical(ra_tree(w$root), before)
  expect_identical(list.files(w$input, all.files = TRUE, no.. = TRUE), character(0))
})

# ---- copying into the input folder -----------------------------------------------------------

test_that("dry_run = FALSE copies each listed file into input/replay-g<N>, byte for byte, invisibly", {
  w <- ra_world()
  u1 <- ra_uuid(); u2 <- ra_uuid()
  p1 <- ra_put(w$archive, u1, "one.csv", "first")
  p2 <- ra_put(w$archive, u2, "two.csv", "second")
  db <- ra_db(w$dbdir, generation = "7")
  vis <- withVisible(ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input,
                                             dry_run = FALSE)))
  expect_false(vis$visible)
  r <- vis$value
  batch <- file.path(w$input, "replay-g7")
  expect_true(dir.exists(batch))
  expect_identical(ra_visible(batch), c("one.csv", "two.csv"))
  expect_identical(unname(tools::md5sum(file.path(batch, "one.csv"))), unname(tools::md5sum(p1)))
  expect_identical(unname(tools::md5sum(file.path(batch, "two.csv"))), unname(tools::md5sum(p2)))
  expect_equal(normalizePath(r$copied_to), normalizePath(file.path(batch, c("one.csv", "two.csv"))))
  # no temporary file is left anywhere under the input folder
  left <- list.files(w$input, recursive = TRUE, all.files = TRUE)
  expect_false(any(grepl("\\.tmp$|~$|\\.part$", left)))
  # the archive is untouched
  expect_true(file.exists(p1) && file.exists(p2))
})

test_that("without a writer_generation the batch is input/replay; an explicit batch is used as given", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "one.csv", "first")
  db <- ra_db(w$dbdir)
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  expect_identical(ra_visible(file.path(w$input, "replay")), "one.csv")
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, batch = "input-replay-g9",
                          dry_run = FALSE))
  expect_identical(ra_visible(file.path(w$input, "input-replay-g9")), "one.csv")
})

test_that("only the first of equal-byte files is copied", {
  w <- ra_world()
  us <- sort(c(ra_uuid(), ra_uuid()))
  ra_put(w$archive, us[1], "a.csv", "same")
  ra_put(w$archive, us[2], "b.csv", "same")
  db <- ra_db(w$dbdir, generation = "2")
  r <- ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  expect_identical(ra_visible(file.path(w$input, "replay-g2")), "a.csv")
  expect_identical(r$duplicate, c(FALSE, TRUE))
  expect_true(is.na(r$copied_to[[2]]))
})

test_that("a name taken by different content gets the source folder's first 8 characters as a prefix", {
  w <- ra_world()
  us <- sort(c(ra_uuid(), ra_uuid()))
  ra_put(w$archive, us[1], "results.csv", "first content")
  ra_put(w$archive, us[2], "results.csv", "second content")
  db <- ra_db(w$dbdir, generation = "2")
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  got <- ra_visible(file.path(w$input, "replay-g2"))
  expect_length(got, 2L)
  expect_true("results.csv" %in% got)
  other <- setdiff(got, "results.csv")
  expect_true(startsWith(other, substr(us[2], 1, 8)) || startsWith(other, substr(us[1], 1, 8)))
  expect_true(endsWith(other, "results.csv"))
  contents <- vapply(file.path(w$input, "replay-g2", got), function(f) readLines(f), "")
  expect_setequal(unname(contents), c("first content", "second content"))
})

test_that("a second replay before the import copies nothing new", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "one.csv", "first")
  db <- ra_db(w$dbdir, generation = "4")
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  before <- ra_tree(w$input)
  Sys.sleep(1.1)
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input, dry_run = FALSE))
  expect_identical(ra_tree(w$input), before)
})

test_that("a missing input folder aborts a real run and creates nothing", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "one.csv", "first")
  db <- ra_db(w$dbdir, generation = "2")
  gone <- file.path(w$root, "no-input")
  expect_error(ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = gone,
                                       dry_run = FALSE)),
               class = "sampletidy_error")
  expect_false(dir.exists(gone))
})

test_that("a batch name the configured recogniser would not see aborts before copying", {
  w <- ra_world()
  ra_put(w$archive, ra_uuid(), "one.csv", "first")
  db <- ra_db(w$dbdir, generation = "2")
  withr::local_options(list(sampletidy.inbox_batches = inbox_batches("^input.+")))
  expect_error(ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input,
                                       dry_run = FALSE)),
               class = "sampletidy_error")
  expect_identical(list.files(w$input, all.files = TRUE, no.. = TRUE), character(0))
  # a name it does see is accepted
  ra_quiet(replay_archive(db = db, archive_dir = w$archive, input_dir = w$input,
                          batch = "input-replay-g2", dry_run = FALSE))
  expect_identical(ra_visible(file.path(w$input, "input-replay-g2")), "one.csv")
})

# ---- end to end: the import keeps the original uuids -----------------------------------------

test_that("replayed files are imported under their original asset uuids, with no new archive folder", {
  s <- inbox_setup()
  uuid_dirs <- function() {
    d <- list.dirs(s$archive_dir, recursive = FALSE, full.names = FALSE)
    sort(d[grepl("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", d)])
  }
  asset_uuids <- function(db) {
    con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
    DBI::dbGetQuery(con, "SELECT uuid FROM asset")$uuid
  }
  # The "snapshot": the database before the imports that will be lost.
  snap <- file.path(withr::local_tempdir(), "snapshot.duckdb")
  expect_true(file.copy(s$db, snap))
  expect_length(uuid_dirs(), 0L)

  # An import the snapshot does not hold.
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "batch-a", inbox_proj_a_files(), now = now)
  run_inbox(s, now = now)
  arch <- uuid_dirs()
  expect_gt(length(arch), 0L)
  expect_true(all(arch %in% asset_uuids(s$db)))
  batch_a_left <- dir.exists(file.path(s$input_dir, "batch-a"))

  # The dry run against the snapshot lists every archived file, by its folder.
  r <- ra_quiet(replay_archive(db = snap, archive_dir = s$archive_dir, input_dir = s$input_dir))
  expect_setequal(unique(r$folder), arch)

  # Install the snapshot as live (a forced takeover), replay, import.
  unlink(paste0(s$db, ".wal"))
  expect_true(file.copy(snap, s$db, overwrite = TRUE))
  ra_quiet(replay_archive(db = s$db, archive_dir = s$archive_dir, input_dir = s$input_dir,
                          batch = "batch-replay", dry_run = FALSE))
  expect_gt(length(ra_visible(file.path(s$input_dir, "batch-replay"))), 0L)
  later <- now + 3600
  run_inbox(s, now = later)

  # The original uuids are the assets again, and no archive folder was added.
  expect_identical(uuid_dirs(), arch)
  expect_true(all(arch %in% asset_uuids(s$db)))
  # The replay batch ends as an ordinary batch does.
  expect_identical(dir.exists(file.path(s$input_dir, "batch-replay")), batch_a_left)

  # Nothing is left to replay.
  r2 <- ra_quiet(replay_archive(db = s$db, archive_dir = s$archive_dir, input_dir = s$input_dir))
  expect_equal(nrow(r2), 0L)
})
