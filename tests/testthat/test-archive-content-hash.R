# The content hash on assets (spec sections 3-6).
#
#   3. `asset.content_hash` / `asset.content_hash_alg` exist in the test core
#      DDL; every code path also works on an `asset` table WITHOUT them.
#   4. archive_file() writes them, and dedupes on them after the byte hash.
#   5. archive_settle() accepts a store rewrite of any size when the stored
#      copy's content hash still equals the asset's.
#   6. .ig_remove_verified() removes a source whose content equals the copy's.
#
# Fixtures are synthetic compound files from helper-cfb.R. The helpers here
# are prefixed `ch_` and local to this file (the settle file's `st_*` helpers
# live in that test file, not in a helper-*.R, so they are not shared).

# ---- fixtures -------------------------------------------------------------

ch_base <- function() {
  list(
    "Workbook" = cfb_bytes(9000, 1),
    "\001CompObj" = cfb_bytes(113, 2),
    "\005SummaryInformation" = cfb_bytes(240, 3),
    "Sub/Data" = cfb_bytes(300, 5),
    "MsoDataStore/Store1/Item" = cfb_bytes(2000, 20),
    "MsoDataStore/Store1/Properties" = cfb_bytes(400, 21)
  )[c("Workbook", "\001CompObj", "\005SummaryInformation", "Sub/Data")]
}
ch_mso <- function(seed = 20, n = 2000) {
  list("MsoDataStore/Store1/Item" = cfb_bytes(n, seed),
       "MsoDataStore/Store1/Properties" = cfb_bytes(400, seed + 1))
}

ch_old_asset_ddl <- "
  CREATE TABLE asset (
    uuid VARCHAR PRIMARY KEY, name VARCHAR, date TIMESTAMP, file_format VARCHAR,
    type VARCHAR, purpose VARCHAR, organisation VARCHAR, person VARCHAR,
    uuid_project VARCHAR, uuid_feature VARCHAR, filename VARCHAR, hash VARCHAR,
    comments VARCHAR
  )"

# A seeded DB held open read-write. `columns = FALSE` swaps in an `asset`
# table as the live database has it before the operator migration.
ch_con_setup <- function(columns = TRUE, env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  if (columns) {
    ensure_test_asset_table(con)
  } else {
    DBI::dbExecute(con, "DROP TABLE IF EXISTS asset")
    DBI::dbExecute(con, ch_old_asset_ddl)
  }
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-ch01', 'ZZ7700001', 'Work order')")
  archive_dir <- withr::local_tempdir(.local_envir = env)
  src_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.archive_settle" = NULL,
    "sampletidy.content_fingerprinters" = NULL
  ), .local_envir = env)
  withr::defer(if (DBI::dbIsValid(con)) DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  list(db = db, con = con, archive_dir = archive_dir, src_dir = src_dir)
}

ch_cols <- function(con) names(DBI::dbGetQuery(con, "SELECT * FROM asset LIMIT 0"))
ch_q <- function(con, sql, ...) DBI::dbGetQuery(con, sql, params = if (...length()) list(...) else NULL)

# Write a compound file as a fixture; returns what the tests need about it.
ch_xls <- function(dir, name, streams, ...) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, name)
  cfb_write(path, streams, ...)
  list(path = path, name = name, hash = hash_file(path), size = file.size(path), streams = streams)
}
ch_plain <- function(dir, name, text) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, name)
  writeBin(charToRaw(text), path)
  list(path = path, name = name, hash = hash_file(path), size = file.size(path))
}

# Record an ingest_file row for the file, as the pipeline does before archiving.
ch_ingest_row <- function(con, f) {
  DBI::dbExecute(con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, size, state)
     VALUES (?, ?, ?, ?, 'quarantined')",
    params = list(f$hash, f$name, f$path, f$size))
}

ch_archive <- function(setup, f, wo = "ZZ7700001") {
  ch_ingest_row(setup$con, f)
  uuid <- archive_file(setup$con, f$path, f$hash, event = list(work_order = wo))
  f$uuid <- uuid
  f$stored <- file.path(setup$archive_dir, uuid, f$name)
  f
}

ch_archived_at <- function(con, uuid) {
  ch_q(con, "SELECT \"at\" FROM change_log WHERE tbl = 'asset' AND action = 'insert' AND uuid_row = ?", uuid)$at
}
ch_backdate <- function(con, uuid, secs) {
  at <- ch_archived_at(con, uuid)
  DBI::dbExecute(con,
    "UPDATE change_log SET \"at\" = ? WHERE tbl = 'asset' AND action = 'insert' AND uuid_row = ?",
    params = list(at - secs, uuid))
}

ch_warnings <- function(expr) {
  msgs <- character(0)
  value <- withCallingHandlers(
    suppressMessages(expr),
    warning = function(w) { msgs <<- c(msgs, conditionMessage(w)); invokeRestart("muffleWarning") }
  )
  list(value = value, warnings = msgs)
}
ch_warned_about <- function(msgs, what) any(grepl(what, msgs, fixed = TRUE))

ch_settle <- function(setup, f, ...) {
  ch_warnings(archive_settle(setup$con, now = ch_archived_at(setup$con, f$uuid) + 1000))
}
ch_settle_on <- function(cfg = list(), env = parent.frame()) {
  withr::local_options(list("sampletidy.archive_settle" = cfg), .local_envir = env)
}
ch_asset <- function(con, uuid) ch_q(con, "SELECT * FROM asset WHERE uuid = ?", uuid)
ch_hash_rows <- function(con, uuid) {
  ch_q(con, "SELECT * FROM change_log WHERE tbl = 'asset' AND uuid_row = ? AND field = 'hash' AND action = 'update'", uuid)
}

# Overwrite the stored copy with a compound file of these streams.
ch_overwrite <- function(f, streams, ...) {
  cfb_write(f$stored, streams, ...)
  invisible(hash_file(f$stored))
}

# ---- 3. schema ------------------------------------------------------------

test_that("content-hash 3: the test core DDL has content_hash and content_hash_alg on asset, both nullable VARCHAR", {
  setup <- ch_con_setup()
  expect_true(all(c("content_hash", "content_hash_alg") %in% ch_cols(setup$con)))
  ddl <- `.st_test_core_ddl`$asset
  expect_match(ddl, "content_hash VARCHAR", fixed = TRUE)
  expect_match(ddl, "content_hash_alg VARCHAR", fixed = TRUE)
  # a seeded database built from the core DDL has them too
  db <- seed_db(dir = withr::local_tempdir())
  con2 <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con2, shutdown = TRUE))
  expect_true(all(c("content_hash", "content_hash_alg") %in% ch_cols(con2)))
})

# ---- 4. archive_file() ----------------------------------------------------

test_that("content-hash 4a: archive_file() writes the content hash for an OLE file and NA for anything else", {
  setup <- ch_con_setup()
  ole <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  csv <- ch_archive(setup, ch_plain(setup$src_dir, "ZZ7700001_b.csv", "a,b\n1,2\n"))
  xml <- ch_archive(setup, ch_plain(setup$src_dir, "ZZ7700001_c.xls", "<?xml version=\"1.0\"?><Workbook/>"))

  a <- ch_asset(setup$con, ole$uuid)
  expect_identical(a$content_hash, ole1_expected(ch_base()))
  expect_identical(a$content_hash_alg, "ole1")
  expect_identical(a$hash, ole$hash)               # the byte hash is unchanged
  for (u in c(csv$uuid, xml$uuid)) {
    b <- ch_asset(setup$con, u)
    expect_true(is.na(b$content_hash))
    expect_true(is.na(b$content_hash_alg))
  }
})

test_that("content-hash 4b: archive_file() works unchanged on an asset table WITHOUT the columns - no error, no warning, no columns appear", {
  setup <- ch_con_setup(columns = FALSE)
  expect_false(any(c("content_hash", "content_hash_alg") %in% ch_cols(setup$con)))
  f <- ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base())
  res <- ch_warnings(ch_archive(setup, f))
  expect_length(res$warnings, 0L)
  expect_false(any(c("content_hash", "content_hash_alg") %in% ch_cols(setup$con)))
  row <- ch_asset(setup$con, res$value$uuid)
  expect_identical(row$hash, f$hash)
  expect_true(file.exists(res$value$stored))

  # byte-hash dedupe is unchanged too: same bytes, same uuid, no new row
  again <- ch_warnings(archive_file(setup$con, f$path, f$hash, event = list(work_order = "ZZ7700001")))
  expect_length(again$warnings, 0L)
  expect_identical(again$value, res$value$uuid)
  expect_equal(ch_q(setup$con, "SELECT count(*) AS n FROM asset")$n, 1)
})

test_that("content-hash 4c: a content-duplicate (same streams, different bytes) reuses the asset - no new row, no copy, ingest_file linked", {
  setup <- ch_con_setup()
  first <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  # Same logical content, rewritten by a "store": MsoDataStore added, other layout.
  second <- ch_xls(file.path(setup$src_dir, "again"), "ZZ7700001_a.xls",
                   c(ch_base(), ch_mso()), version = 4L, shuffle = TRUE)
  expect_false(identical(second$hash, first$hash))
  ch_ingest_row(setup$con, second)
  n_dirs <- length(list.dirs(setup$archive_dir, recursive = FALSE))

  uuid <- archive_file(setup$con, second$path, second$hash, event = list(work_order = "ZZ7700001"))

  expect_identical(uuid, first$uuid)
  expect_equal(ch_q(setup$con, "SELECT count(*) AS n FROM asset")$n, 1)
  expect_equal(length(list.dirs(setup$archive_dir, recursive = FALSE)), n_dirs)
  inf <- ch_q(setup$con, "SELECT uuid_asset, size FROM ingest_file WHERE hash = ?", second$hash)
  expect_identical(inf$uuid_asset, first$uuid)
  expect_equal(inf$size, second$size)
  # the stored asset row is untouched
  expect_identical(ch_asset(setup$con, first$uuid)$hash, first$hash)
})

test_that("content-hash 4d: different content, a different algorithm tag, or no fingerprint is NOT a content duplicate", {
  setup <- ch_con_setup()
  first <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))

  changed <- ch_base()
  changed$Workbook[10] <- as.raw(bitwXor(as.integer(changed$Workbook[10]), 255L))
  other <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_b.xls", changed))
  expect_false(identical(other$uuid, first$uuid))

  # same content hash but a different alg tag: not a match
  DBI::dbExecute(setup$con, "UPDATE asset SET content_hash_alg = 'other' WHERE uuid = ?", params = list(first$uuid))
  twin <- ch_archive(setup, ch_xls(file.path(setup$src_dir, "t"), "ZZ7700001_c.xls", ch_base(), version = 4L))
  expect_false(identical(twin$uuid, first$uuid))

  # two non-OLE files: NA never matches NA
  c1 <- ch_archive(setup, ch_plain(setup$src_dir, "one.csv", "a\n1\n"))
  c2 <- ch_archive(setup, ch_plain(setup$src_dir, "two.csv", "a\n2\n"))
  expect_false(identical(c1$uuid, c2$uuid))
  expect_equal(ch_q(setup$con, "SELECT count(*) AS n FROM asset")$n, 5)
})

test_that("content-hash 4e: with several assets of the same content hash, the lowest uuid is reused", {
  setup <- ch_con_setup()
  h <- ole1_expected(ch_base())
  for (u in c("bbbbbbbb-0000-0000-0000-000000000002", "aaaaaaaa-0000-0000-0000-000000000001",
              "cccccccc-0000-0000-0000-000000000003")) {
    DBI::dbExecute(setup$con,
      "INSERT INTO asset (uuid, filename, hash, uuid_project, type, content_hash, content_hash_alg)
       VALUES (?, 'x.xls', ?, 'p-ch01', 'Chemical analysis', ?, 'ole1')",
      params = list(u, paste0("hash-", u), h))
  }
  f <- ch_xls(setup$src_dir, "ZZ7700001_new.xls", ch_base(), shuffle = TRUE)
  ch_ingest_row(setup$con, f)
  uuid <- archive_file(setup$con, f$path, f$hash, event = list(work_order = "ZZ7700001"))
  expect_identical(uuid, "aaaaaaaa-0000-0000-0000-000000000001")
  expect_equal(ch_q(setup$con, "SELECT count(*) AS n FROM asset")$n, 3)
})

test_that("content-hash 4f: a byte-hash match still wins and the dedupe works without any fingerprint", {
  setup <- ch_con_setup()
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  DBI::dbExecute(setup$con, "UPDATE asset SET content_hash = NULL, content_hash_alg = NULL")
  expect_identical(archive_file(setup$con, f$path, f$hash, event = list(work_order = "ZZ7700001")), f$uuid)
  expect_equal(ch_q(setup$con, "SELECT count(*) AS n FROM asset")$n, 1)
})

# ---- 5. archive_settle() --------------------------------------------------

test_that("content-hash 5a: a GROWN rewrite (MsoDataStore added) with the same content is settled - hash updated, change_log keeps the old hash, result row, content hash untouched", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  new_hash <- ch_overwrite(f, c(ch_base(), ch_mso()), shuffle = TRUE, seed = 4)
  expect_gt(file.size(f$stored), f$size)

  res <- ch_settle(setup, f)

  out <- res$value
  expect_equal(nrow(out), 1L)
  expect_identical(out$uuid[[1]], f$uuid)
  expect_identical(out$old_hash[[1]], f$hash)
  expect_identical(out$new_hash[[1]], new_hash)
  expect_length(res$warnings, 0L)
  a <- ch_asset(setup$con, f$uuid)
  expect_identical(a$hash, new_hash)
  expect_identical(a$content_hash, ole1_expected(ch_base()))
  expect_identical(a$content_hash_alg, "ole1")
  log <- ch_hash_rows(setup$con, f$uuid)
  expect_equal(nrow(log), 1L)
  expect_identical(log$old, f$hash)
  expect_identical(log$new, new_hash)
  expect_identical(log$actor, "archive_settle")
  expect_identical(log$source_hash, f$hash)
  expect_match(log$reason, "storage rewrite", ignore.case = TRUE)
  expect_match(log$reason, "content unchanged", ignore.case = TRUE)
  inf <- ch_q(setup$con, "SELECT hash, uuid_asset FROM ingest_file WHERE filename = ?", f$name)
  expect_identical(inf$hash, f$hash)
  expect_identical(inf$uuid_asset, f$uuid)
})

test_that("content-hash 5b: a grown rewrite is accepted even when the as-received size is unknown", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  DBI::dbExecute(setup$con, "UPDATE ingest_file SET size = NULL")
  new_hash <- ch_overwrite(f, c(ch_base(), ch_mso()))
  res <- ch_settle(setup, f)
  expect_equal(nrow(res$value), 1L)
  expect_length(res$warnings, 0L)
  expect_identical(ch_asset(setup$con, f$uuid)$hash, new_hash)

  # ... and with no ingest_file row at all
  g <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_g.xls", c(ch_base(), list(G = cfb_bytes(70, 9)))))
  DBI::dbExecute(setup$con, "DELETE FROM ingest_file WHERE hash = ?", params = list(g$hash))
  new_g <- ch_overwrite(g, c(ch_base(), list(G = cfb_bytes(70, 9)), ch_mso()), version = 4L)
  res2 <- ch_settle(setup, g)
  expect_equal(nrow(res2$value), 1L)
  expect_identical(ch_asset(setup$con, g$uuid)$hash, new_g)
})

test_that("content-hash 5c: a same-size MsoDataStore rewrite is settled too", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", c(ch_base(), ch_mso(20))))
  new_hash <- ch_overwrite(f, c(ch_base(), ch_mso(88)))
  expect_equal(file.size(f$stored), f$size)
  expect_false(identical(new_hash, f$hash))
  res <- ch_settle(setup, f)
  expect_equal(nrow(res$value), 1L)
  expect_identical(ch_asset(setup$con, f$uuid)$hash, new_hash)
})

test_that("content-hash 5d: the accept() veto still applies to a content-path rewrite", {
  setup <- ch_con_setup()
  seen <- new.env()
  ch_settle_on(list(accept = function(path, old_hash, asset) {
    seen$args <- list(path = path, old_hash = old_hash, asset = asset)
    FALSE
  }))
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  ch_overwrite(f, c(ch_base(), ch_mso()))
  res <- ch_settle(setup, f)
  expect_equal(nrow(res$value), 0L)
  expect_true(ch_warned_about(res$warnings, f$name))
  expect_identical(ch_asset(setup$con, f$uuid)$hash, f$hash)
  expect_equal(nrow(ch_hash_rows(setup$con, f$uuid)), 0L)
  expect_identical(seen$args$old_hash, f$hash)
  expect_identical(seen$args$asset$uuid, f$uuid)

  # A TRUE verdict settles.
  ch_settle_on(list(accept = function(path, old_hash, asset) TRUE))
  res2 <- ch_settle(setup, f)
  expect_equal(nrow(res2$value), 1L)
})

test_that("content-hash 5e: a content change at the SAME size is refused with a warning naming the file", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  changed <- ch_base()
  changed$Workbook[100] <- as.raw(bitwXor(as.integer(changed$Workbook[100]), 255L))
  new_hash <- ch_overwrite(f, changed)
  expect_equal(file.size(f$stored), f$size)
  expect_false(identical(new_hash, f$hash))

  res <- ch_settle(setup, f)

  expect_equal(nrow(res$value), 0L)
  expect_true(ch_warned_about(res$warnings, f$name))
  expect_identical(ch_asset(setup$con, f$uuid)$hash, f$hash)
  expect_equal(nrow(ch_hash_rows(setup$con, f$uuid)), 0L)
})

test_that("content-hash 5f: a content change that also grows the file, and a stored copy whose fingerprint is NA, are refused with a warning", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  ch_overwrite(f, c(ch_base(), list(Extra = cfb_bytes(200, 3))))
  res <- ch_settle(setup, f)
  expect_equal(nrow(res$value), 0L)
  expect_true(ch_warned_about(res$warnings, f$name))
  expect_identical(ch_asset(setup$con, f$uuid)$hash, f$hash)

  ch_overwrite(f, c(ch_base(), ch_mso()), fault = "truncate")     # a truncated compound file
  res2 <- ch_settle(setup, f)
  expect_equal(nrow(res2$value), 0L)
  expect_true(ch_warned_about(res2$warnings, f$name))
  expect_identical(ch_asset(setup$con, f$uuid)$hash, f$hash)

  writeBin(charToRaw("not a compound file at all"), f$stored)      # no longer OLE
  res3 <- ch_settle(setup, f)
  expect_equal(nrow(res3$value), 0L)
  expect_true(ch_warned_about(res3$warnings, f$name))
  expect_identical(ch_asset(setup$con, f$uuid)$hash, f$hash)
})

test_that("content-hash 5g: an asset with NULL content_hash keeps the old size-gated behaviour", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  same <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_s.xls", c(ch_base(), ch_mso(20))))
  grown <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_g.xls", c(ch_base(), list(G = cfb_bytes(70, 9)))))
  unknown <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_u.xls", c(ch_base(), list(U = cfb_bytes(70, 8)))))
  DBI::dbExecute(setup$con, "UPDATE asset SET content_hash = NULL, content_hash_alg = NULL")
  DBI::dbExecute(setup$con, "UPDATE ingest_file SET size = NULL WHERE hash = ?", params = list(unknown$hash))

  new_same <- ch_overwrite(same, c(ch_base(), ch_mso(88)))                 # same size: settles
  ch_overwrite(grown, c(ch_base(), list(G = cfb_bytes(70, 9)), ch_mso())) # grown: refused (size)
  ch_overwrite(unknown, c(ch_base(), list(U = cfb_bytes(70, 8)), ch_mso(88)))  # unknown size: refused

  res <- ch_warnings(archive_settle(setup$con, now = Sys.time() + 1000))
  expect_equal(res$value$uuid, same$uuid)
  expect_identical(ch_asset(setup$con, same$uuid)$hash, new_same)
  expect_identical(ch_asset(setup$con, grown$uuid)$hash, grown$hash)
  expect_identical(ch_asset(setup$con, unknown$uuid)$hash, unknown$hash)
  expect_true(ch_warned_about(res$warnings, grown$name))
  expect_true(ch_warned_about(res$warnings, unknown$name))
  expect_false(ch_warned_about(res$warnings, same$name))
  expect_true(is.na(ch_asset(setup$con, same$uuid)$content_hash))        # still NULL: not filled in
})

test_that("content-hash 5h: on an asset table WITHOUT the columns settling behaves exactly as before, with no error", {
  setup <- ch_con_setup(columns = FALSE)
  ch_settle_on(list())
  same <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_s.xls", c(ch_base(), ch_mso(20))))
  grown <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_g.xls", c(ch_base(), list(G = cfb_bytes(70, 9)))))
  new_same <- ch_overwrite(same, c(ch_base(), ch_mso(88)))
  ch_overwrite(grown, c(ch_base(), list(G = cfb_bytes(70, 9)), ch_mso()))

  res <- ch_warnings(archive_settle(setup$con, now = Sys.time() + 1000))

  expect_equal(res$value$uuid, same$uuid)
  expect_identical(ch_asset(setup$con, same$uuid)$hash, new_same)
  expect_identical(ch_asset(setup$con, grown$uuid)$hash, grown$hash)
  expect_true(ch_warned_about(res$warnings, grown$name))
  expect_false(ch_warned_about(res$warnings, same$name))
  expect_false(any(c("content_hash", "content_hash_alg") %in% ch_cols(setup$con)))
})

# ---- 6. .ig_remove_verified() --------------------------------------------

ch_remove <- function(setup, files) {
  if (DBI::dbIsValid(setup$con)) DBI::dbDisconnect(setup$con, shutdown = TRUE)
  routed <- tibble::tibble(path = vapply(files, function(f) f$path, ""),
                           hash = vapply(files, function(f) f$hash, ""))
  ch_warnings(sampleTidy:::.ig_remove_verified(setup$db, routed))
}

test_that("content-hash 6a: a source is removed when the stored copy is a store rewrite of the same content (bytes differ)", {
  setup <- ch_con_setup()
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  ch_overwrite(f, c(ch_base(), ch_mso()), version = 4L)          # not settled: asset.hash is still the old one
  expect_false(identical(hash_file(f$stored), f$hash))

  res <- ch_remove(setup, list(f))

  expect_length(res$warnings, 0L)
  expect_equal(basename(res$value), f$name)
  expect_false(file.exists(f$path))
})

test_that("content-hash 6b: a source that is a content-duplicate of an existing asset is removed", {
  setup <- ch_con_setup()
  first <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  dup <- ch_xls(file.path(setup$src_dir, "again"), "ZZ7700001_a.xls", c(ch_base(), ch_mso()), shuffle = TRUE)
  # link the duplicate's as-received hash to the existing asset by hand
  ch_ingest_row(setup$con, dup)
  DBI::dbExecute(setup$con, "UPDATE ingest_file SET uuid_asset = ? WHERE hash = ?",
                 params = list(first$uuid, dup$hash))

  res <- ch_remove(setup, list(dup))

  expect_length(res$warnings, 0L)
  expect_false(file.exists(dup$path))
  expect_true(file.exists(first$stored))
})

test_that("content-hash 6c: a source whose content differs from the copy is kept, with a warning", {
  setup <- ch_con_setup()
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  changed <- ch_base()
  changed$Workbook[7] <- as.raw(bitwXor(as.integer(changed$Workbook[7]), 255L))
  ch_overwrite(f, changed)

  res <- ch_remove(setup, list(f))

  expect_length(res$value, 0L)
  expect_true(file.exists(f$path))
  expect_true(ch_warned_about(res$warnings, f$name))
})

test_that("content-hash 6d: a non-OLE source whose copy differs is still kept with a warning; an unchanged one is still removed", {
  setup <- ch_con_setup()
  keep <- ch_archive(setup, ch_plain(setup$src_dir, "ZZ7700001_k.csv", "a,b\n1,2\n"))
  gone <- ch_archive(setup, ch_plain(setup$src_dir, "ZZ7700001_g.csv", "a,b\n3,4\n"))
  writeBin(charToRaw("a,b\n9,9\n"), keep$stored)

  res <- ch_remove(setup, list(keep, gone))

  expect_true(file.exists(keep$path))
  expect_false(file.exists(gone$path))
  expect_true(ch_warned_about(res$warnings, keep$name))
})

test_that("content-hash 6e: the settle hold still comes first - a held .xls source is kept silently even though its content matches, then removed after the hold", {
  setup <- ch_con_setup()
  ch_settle_on(list())
  f <- ch_archive(setup, ch_xls(setup$src_dir, "ZZ7700001_a.xls", ch_base()))
  ch_overwrite(f, c(ch_base(), ch_mso()))

  held <- ch_remove(setup, list(f))
  expect_true(file.exists(f$path))
  expect_length(held$warnings, 0L)
  expect_length(held$value, 0L)

  con <- DBI::dbConnect(duckdb::duckdb(), setup$db)
  ch_backdate(con, f$uuid, 901)
  DBI::dbDisconnect(con, shutdown = TRUE)
  released <- ch_remove(setup, list(f))
  expect_false(file.exists(f$path))
  expect_length(released$warnings, 0L)
})
