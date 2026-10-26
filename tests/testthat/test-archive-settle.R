# Settling archive files that the file store rewrites after archiving.
#
# THE PROBLEM. Some file stores change a file after sampleTidy has archived
# it. SharePoint, for one, rewrites an embedded metadata block inside
# old-format Office files (.xls/.doc/.ppt) some seconds or hours after
# OneDrive uploads them (MIGRATIONS 1055, 1085, 1087). The content is
# unchanged and the size stays the same, but the bytes differ, so
# `asset.hash` (`hash_file()`) stops matching the stored file. The rewritten
# hash is NOT a content identity - a later rewrite changes it again - so
# de-duplication stays on the AS-RECEIVED hash.
#
# THE RULED DESIGN.
#   * `asset.hash` is the stored file's current, settled hash.
#   * `ingest_file(hash, uuid_asset)` is the as-received lookup (the column
#     has existed since schema v1; no schema bump). `archive_file()` writes
#     `ingest_file.uuid_asset` on its new-asset AND its reuse path, and its
#     own dedup also checks `ingest_file.uuid_asset`.
#   * Consumers resolve a file through `ingest_file.uuid_asset` first, then
#     fall back to `asset.hash`: `.ig_remove_verified()`, ingest_dir()'s
#     `removable_pending`, the folder -> project fallback
#     (`.ig_folder_work_order()`), the stem own-bytes exclusion
#     (`.ig_stem_work_order()`), `.ct_wo_prior_asset_hashes()` and
#     `completed_work()`.
#   * Config: `st_config("archive_settle")`, list-valued, NULL by default
#     (= off), in `.st_config_list_keys` (so the env-var form is refused).
#     Fields: `ext` (default c("xls", "doc", "ppt")), `hold_secs` (default
#     900), `window_hours` (default 72), optional `accept`, a predicate
#     `function(path, old_hash, asset)` that can veto a rewrite. `list()`
#     turns it on with every default. Bad config aborts `sampletidy_error`.
#   * `archive_settle()` runs at the start of each ingest_dir() write phase
#     and is callable on its own. It looks at assets with a configured
#     extension archived within `window_hours` (archive time = the asset's
#     `insert` row in `change_log`), re-hashes each stored file, and when the
#     hash differs AND the size is unchanged AND `accept` (if set) allows it,
#     updates `asset.hash` via `db_update()` with a change_log row carrying
#     the old hash and reason "storage rewrite". One transaction per asset.
#     It never changes `ingest_file.hash`. A settle counts as `did_something`
#     (so the run snapshots).
#   * Inbox sources with a configured extension are kept until `hold_secs`
#     after archiving, then deleted when the copy's hash equals the source
#     hash OR the asset's current `asset.hash` (found through `uuid_asset`).
#     Other extensions are deleted immediately, as now.
#   * Rejected mismatches - a change after the window, a size change, an
#     unconfigured extension (a rewritten .pdf), an `accept` veto - are warned
#     about (cli warning), never accepted, and `asset.hash` is left alone.
#
# SEAMS SPECIFIED HERE (none existed):
#   * `archive_settle(db = st_config("live_db"), now = Sys.time())`, exported.
#     `db` is a path (opened read-write) or an open read-write DBIConnection
#     (used as is, left open). `now` is the clock for the window. Returns,
#     invisibly, a tibble with one row per asset settled in this call and
#     columns `uuid`, `old_hash`, `new_hash` (zero rows when nothing settled,
#     including when the config is NULL).
#   * ingest_dir() takes no clock argument. Its tests age an archive by moving
#     the asset's `insert` change_log row's `at` back in time
#     (`st_backdate()`), which IS the ruled archive time; that is equivalent to
#     moving `now` forward and does not depend on how the implementation reads
#     the clock.
#   * Extension matching ignores case (an `.XLS` settles under ext "xls";
#     test 2b). Real ALS XTAB files arrive as `.XLS`.
#   * An unknown field in the config list (a typo such as `holdsecs`) is bad
#     config and aborts.
#   * Warnings about a rejected mismatch name the file (its filename appears
#     in the warning text).
#
# NOT TESTED HERE - the backfill migration (a separate dev/migrations script
# with its own rehearsal). What it must do:
#   * From the 055 and 087 BACKUP old -> new hashes, plus every row where
#     `ingest_file.hash = asset.hash`, set `ingest_file.uuid_asset`.
#   * Precondition: exactly one `ingest_file` row per old hash, with
#     `uuid_asset` NULL or already equal to the target asset.
#   * Hashes belonging to 061's multi-project assets (one report filed under
#     several projects, so one hash -> several asset rows) are not linked;
#     they go to the SKIPPED CSV.
#
# FIXTURES are synthetic: work orders ZZ77000NN (no real work order, host or
# site code), fake byte content.

# ---- fixture helpers -----------------------------------------------------

st_wo <- "ZZ7700001"

# A seeded DB with project ZZ7700001, archive/snapshot/inbox dirs, removal on
# and the settle config cleared. Cleanups bind to the calling test's frame.
st_ingest_setup <- function(env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  ensure_test_asset_table(con)
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-st01', 'ZZ7700001', 'Work order')")
  DBI::dbDisconnect(con, shutdown = TRUE)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  input_root <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = TRUE,
    "sampletidy.archive_settle" = NULL
  ), .local_envir = env)
  list(db = db, archive_dir = archive_dir, snapshot_dir = snapshot_dir,
       input_root = input_root)
}

# A seeded DB held open read-write, for calling archive_file()/commit_event()/
# archive_settle() directly. The caller defers the disconnect.
st_con_setup <- function(env = parent.frame()) {
  db <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db)
  ensure_test_asset_table(con)
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-st01', 'ZZ7700001', 'Work order')")
  archive_dir <- withr::local_tempdir(.local_envir = env)
  src_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.archive_settle" = NULL
  ), .local_envir = env)
  list(db = db, con = con, archive_dir = archive_dir, src_dir = src_dir)
}

st_settle_on <- function(cfg = list(), env = parent.frame()) {
  withr::local_options(list("sampletidy.archive_settle" = cfg), .local_envir = env)
}

# Fake file bytes with a run of 'A's in the middle for a same-size rewrite to
# overwrite (a stand-in for SharePoint's MsoDataStore block).
st_bytes <- function(tag) {
  charToRaw(paste(
    c(sprintf("fake deliverable %s", tag),
      sprintf("line %02d: metadata block AAAAAAAAAAAAAAAAAAAAAAAA", 1:20)),
    collapse = "\n"
  ))
}

st_write <- function(dir, name, tag = name) {
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  path <- file.path(dir, name)
  bytes <- st_bytes(tag)
  writeBin(bytes, path)
  list(path = path, name = name, hash = hash_file(path), bytes = bytes,
       size = length(bytes))
}

# Rewrite `path` in place: same length, different bytes, different hash.
# Each call writes a different pattern, so a second rewrite differs again.
st_rewrite_counter <- new.env()
st_rewrite_same_size <- function(path) {
  st_rewrite_counter$n <- (if (is.null(st_rewrite_counter$n)) 0L else st_rewrite_counter$n) + 1L
  before <- hash_file(path)
  bytes <- readBin(path, "raw", n = file.size(path))
  mid <- floor(length(bytes) / 2)
  stamp <- charToRaw(sprintf("rewrite%09d", st_rewrite_counter$n))
  bytes[mid + seq_along(stamp) - 1L] <- stamp
  writeBin(bytes, path)
  stopifnot(file.size(path) == length(bytes), !identical(hash_file(path), before))
  invisible(hash_file(path))
}

st_truncate <- function(path, by = 10L) {
  bytes <- readBin(path, "raw", n = file.size(path))
  writeBin(bytes[seq_len(length(bytes) - by)], path)
  invisible(hash_file(path))
}

st_q <- function(db, sql, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = if (...length()) list(...) else NULL)
}

st_qc <- function(con, sql, ...) {
  DBI::dbGetQuery(con, sql, params = if (...length()) list(...) else NULL)
}

st_asset_by_name <- function(db, filename) {
  st_q(db, "SELECT * FROM asset WHERE filename = ?", filename)
}

st_stored_path <- function(archive_dir, asset) {
  file.path(archive_dir, asset$uuid[[1]], asset$filename[[1]])
}

st_rewrite_rows <- function(q, uuid) {
  rows <- q("SELECT * FROM change_log WHERE tbl = 'asset' AND uuid_row = ? AND field = 'hash'", uuid)
  rows[grepl("storage rewrite", rows$reason, ignore.case = TRUE), , drop = FALSE]
}

# Age an archive: move the asset's insert change_log row back by `secs`.
st_backdate <- function(db, uuid, secs) {
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  st_backdate_con(con, uuid, secs)
}
st_backdate_con <- function(con, uuid, secs) {
  at <- st_archived_at(con, uuid)
  DBI::dbExecute(con,
    "UPDATE change_log SET \"at\" = ? WHERE tbl = 'asset' AND action = 'insert' AND uuid_row = ?",
    params = list(at - secs, uuid))
  invisible(at - secs)
}

st_archived_at <- function(con, uuid) {
  at <- DBI::dbGetQuery(con,
    "SELECT \"at\" FROM change_log WHERE tbl = 'asset' AND action = 'insert' AND uuid_row = ?",
    params = list(uuid))$at
  stopifnot(length(at) == 1)
  at
}

# Run `expr`, muffling and collecting every warning.
st_warnings <- function(expr) {
  msgs <- character(0)
  value <- withCallingHandlers(
    suppressMessages(expr),
    warning = function(w) {
      msgs <<- c(msgs, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  list(value = value, warnings = msgs)
}

st_warned_about <- function(msgs, filename) any(grepl(filename, msgs, fixed = TRUE))

st_ingest <- function(dir, db) st_warnings(ingest_dir(dir, db = db))

# Archive a synthetic file at the con level the way .ig_retain_siblings()
# does: an ingest_file row first, then archive_file(), then archived/
# retained_sibling.
st_archive_con <- function(setup, name, wo = st_wo, tag = name) {
  f <- st_write(setup$src_dir, name, tag)
  DBI::dbExecute(setup$con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, size, state)
     VALUES (?, ?, ?, ?, 'quarantined')",
    params = list(f$hash, f$name, f$path, f$size))
  uuid <- archive_file(setup$con, f$path, f$hash, event = list(work_order = wo))
  ingest_file_set_state(setup$con, f$hash, "archived", reason = "retained_sibling", reset = TRUE)
  f$uuid <- uuid
  f$stored <- file.path(setup$archive_dir, uuid, name)
  f
}

st_find_stored <- function(archive_dir, filename) {
  all <- list.files(archive_dir, recursive = TRUE, full.names = TRUE)
  all[basename(all) == filename]
}

# removed_files carries ingest_dir()'s own spelling of the path (tempdir()
# can contribute a doubled slash), so compare normalised paths.
st_was_removed <- function(run, path) {
  removed <- run$value$removed_files
  if (length(removed) == 0) return(FALSE)
  norm <- function(p) file.path(normalizePath(dirname(p), mustWork = FALSE), basename(p))
  norm(path) %in% norm(removed)
}

st_n_dirs <- function(archive_dir) length(list.dirs(archive_dir, recursive = FALSE))

# ---- 1. off by default ---------------------------------------------------

test_that("archive-settle 1: the setting is off by default and nothing changes - archive_settle() is a no-op on a rewritten file and an .xls source is still removed in the same run", {
  withr::local_options(list("sampletidy.archive_settle" = NULL))
  withr::local_envvar(SAMPLETIDY_ARCHIVE_SETTLE = NA)
  expect_null(st_config("archive_settle"))

  # Standalone: a rewritten stored .xls is left alone while the key is NULL.
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.xls")
  st_rewrite_same_size(a$stored)
  n_log <- st_qc(con, "SELECT count(*) AS n FROM change_log")$n
  out <- archive_settle(con, now = st_archived_at(con, a$uuid) + 1000)
  expect_equal(nrow(out), 0L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, a$hash)
  expect_equal(st_qc(con, "SELECT count(*) AS n FROM change_log")$n, n_log)

  # Through ingest_dir(): an .xls source is deleted in the run that archives
  # it, exactly as before.
  s <- st_ingest_setup()
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_XTAB.xls")
  run <- st_ingest(dir, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  expect_equal(nrow(asset), 1L)
  expect_identical(asset$hash[[1]], x$hash)
  expect_false(file.exists(x$path))
  expect_true(st_was_removed(run, x$path))

  # A later run over an empty folder, with the stored copy rewritten, settles
  # nothing and so has nothing to snapshot.
  st_rewrite_same_size(st_stored_path(s$archive_dir, asset))
  empty <- file.path(s$input_root, "email-02")
  dir.create(empty)
  run2 <- st_ingest(empty, s$db)
  expect_true(is.na(run2$value$snapshot_path))
  expect_identical(st_asset_by_name(s$db, x$name)$hash[[1]], x$hash)
})

# ---- 2. a same-size rewrite settles -------------------------------------

test_that("archive-settle 2: a same-size rewrite of a configured file is settled - asset.hash becomes the stored file's hash, change_log keeps the old hash with reason 'storage rewrite', and ingest_file.hash and uuid_asset are untouched", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())

  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.xls")
  expect_identical(st_qc(con, "SELECT uuid_asset FROM ingest_file WHERE hash = ?", a$hash)$uuid_asset, a$uuid)
  new_hash <- st_rewrite_same_size(a$stored)

  out <- archive_settle(con, now = st_archived_at(con, a$uuid) + 1000)

  expect_equal(nrow(out), 1L)
  expect_identical(out$uuid[[1]], a$uuid)
  expect_identical(out$old_hash[[1]], a$hash)
  expect_identical(out$new_hash[[1]], new_hash)

  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, new_hash)
  log <- st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), a$uuid)
  expect_equal(nrow(log), 1L)
  expect_identical(log$old[[1]], a$hash)
  expect_identical(log$new[[1]], new_hash)
  expect_identical(log$action[[1]], "update")

  # ingest_file is the as-received record: its hash is never rewritten, and it
  # still points at the asset.
  inf <- st_qc(con, "SELECT hash, uuid_asset FROM ingest_file WHERE filename = ?", a$name)
  expect_equal(nrow(inf), 1L)
  expect_identical(inf$hash[[1]], a$hash)
  expect_identical(inf$uuid_asset[[1]], a$uuid)
  expect_equal(nrow(st_qc(con, "SELECT 1 FROM ingest_file WHERE hash = ?", new_hash)), 0L)

  # A second pass finds nothing more to do.
  again <- archive_settle(con, now = st_archived_at(con, a$uuid) + 2000)
  expect_equal(nrow(again), 0L)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), a$uuid)), 1L)
})

test_that("archive-settle 2b: extension matching ignores case - an .XLS settles under ext = 'xls'", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list(ext = "xls"))

  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.XLS")
  new_hash <- st_rewrite_same_size(a$stored)
  out <- archive_settle(con, now = st_archived_at(con, a$uuid) + 60)
  expect_equal(nrow(out), 1L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, new_hash)
})

test_that("archive-settle 2c: an ingest_dir() run whose only work is a settle takes a snapshot (a settle counts as did_something)", {
  s <- st_ingest_setup()
  st_settle_on(list(hold_secs = 0))
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_XTAB.xls")
  st_ingest(dir, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  expect_false(file.exists(x$path))   # hold 0, copy matched: removed in run 1

  new_hash <- st_rewrite_same_size(st_stored_path(s$archive_dir, asset))
  empty <- file.path(s$input_root, "email-02")
  dir.create(empty)
  run2 <- st_ingest(empty, s$db)
  expect_identical(st_asset_by_name(s$db, x$name)$hash[[1]], new_hash)
  expect_false(is.na(run2$value$snapshot_path))
})

# ---- 3. a file that never changes ---------------------------------------

test_that("archive-settle 3: a configured file that never changes is never written to, and its source is kept for hold_secs and removed after", {
  s <- st_ingest_setup()
  st_settle_on(list())   # defaults: hold 900 s
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_XTAB.xls")

  run1 <- st_ingest(dir, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  expect_equal(nrow(asset), 1L)
  expect_true(file.exists(x$path))
  expect_false(st_was_removed(run1, x$path))

  # The pass on its own writes nothing.
  n_log <- st_q(s$db, "SELECT count(*) AS n FROM change_log")$n
  out <- archive_settle(s$db, now = Sys.time())
  expect_equal(nrow(out), 0L)
  expect_equal(st_q(s$db, "SELECT count(*) AS n FROM change_log")$n, n_log)

  # Once hold_secs have passed, the next run removes the source.
  st_backdate(s$db, asset$uuid[[1]], 901)
  run2 <- st_ingest(dir, s$db)
  expect_false(file.exists(x$path))
  expect_true(st_was_removed(run2, x$path))

  asset2 <- st_asset_by_name(s$db, x$name)
  expect_identical(asset2$hash[[1]], x$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_q(s$db, sql, ...), asset$uuid[[1]])), 0L)
  inf <- st_q(s$db, "SELECT hash, uuid_asset FROM ingest_file WHERE filename = ?", x$name)
  expect_identical(inf$hash[[1]], x$hash)
  expect_identical(inf$uuid_asset[[1]], asset$uuid[[1]])
})

# ---- 4. a rewrite before removal in the same run ------------------------

test_that("archive-settle 4: a store rewrite that lands before removal in the same run keeps the source; the next run settles the file, removes the source and empties the inbox folder", {
  s <- st_ingest_setup()
  # hold 0, so only the hash comparison can keep the source in run 1.
  st_settle_on(list(hold_secs = 0))
  folder <- file.path(s$input_root, "email-01")
  x <- st_write(folder, "ZZ7700001_0_XTAB.xls")

  # The store rewrites the copy between archiving and removal: simulated by
  # rewriting it just before the snapshot that unlocks removal.
  real_snapshot <- sampleTidy:::snapshot_db
  rewritten <- NA_character_
  run1 <- testthat::with_mocked_bindings(
    st_warnings(ingest_inbox(s$input_root, db = s$db)),
    snapshot_db = function(...) {
      stored <- st_find_stored(s$archive_dir, x$name)
      for (p in stored) rewritten <<- st_rewrite_same_size(p)
      real_snapshot(...)
    }
  )
  asset <- st_asset_by_name(s$db, x$name)
  expect_equal(nrow(asset), 1L)
  expect_false(is.na(rewritten))
  expect_true(file.exists(x$path))
  expect_true(dir.exists(folder))
  expect_identical(asset$hash[[1]], x$hash)   # not settled within run 1

  run2 <- st_warnings(ingest_inbox(s$input_root, db = s$db))

  asset2 <- st_asset_by_name(s$db, x$name)
  expect_identical(asset2$hash[[1]], rewritten)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_q(s$db, sql, ...), asset$uuid[[1]])), 1L)
  expect_false(file.exists(x$path))
  expect_false(dir.exists(folder))
  expect_equal(run2$value$n_folders_removed, 1L)
  inf <- st_q(s$db, "SELECT hash, uuid_asset FROM ingest_file WHERE filename = ?", x$name)
  expect_identical(inf$hash[[1]], x$hash)
  expect_identical(inf$uuid_asset[[1]], asset$uuid[[1]])
})

# ---- 5. a .pdf is removed at once ---------------------------------------

test_that("archive-settle 5: with settling on, a .pdf source is still removed in the run that archives it, while a configured .xls beside it is held", {
  s <- st_ingest_setup()
  st_settle_on(list())
  dir <- file.path(s$input_root, "email-01")
  pdf <- st_write(dir, "ZZ7700001_0_COA.pdf")
  xls <- st_write(dir, "ZZ7700001_0_XTAB.xls")

  run <- st_ingest(dir, s$db)

  expect_equal(nrow(st_asset_by_name(s$db, pdf$name)), 1L)
  expect_equal(nrow(st_asset_by_name(s$db, xls$name)), 1L)
  expect_false(file.exists(pdf$path))
  expect_true(st_was_removed(run, pdf$path))
  expect_true(file.exists(xls$path))
})

# ---- 6. rejected mismatches ---------------------------------------------

test_that("archive-settle 6a: a change after window_hours is not accepted - archive_settle() leaves asset.hash alone, and ingest_dir() warns and keeps the source", {
  # Standalone.
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())
  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.xls")
  st_rewrite_same_size(a$stored)
  out <- suppressWarnings(archive_settle(con, now = st_archived_at(con, a$uuid) + 73 * 3600))
  expect_equal(nrow(out), 0L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, a$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), a$uuid)), 0L)

  # Through ingest_dir(): held in run 1, then no run for three days, then the
  # store rewrites the copy.
  s <- st_ingest_setup()
  st_settle_on(list())
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_XTAB.xls")
  st_ingest(dir, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  expect_true(file.exists(x$path))
  st_backdate(s$db, asset$uuid[[1]], 73 * 3600)
  st_rewrite_same_size(st_stored_path(s$archive_dir, asset))

  run2 <- st_ingest(dir, s$db)
  expect_true(st_warned_about(run2$warnings, x$name))
  expect_true(file.exists(x$path))
  expect_identical(st_asset_by_name(s$db, x$name)$hash[[1]], x$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_q(s$db, sql, ...), asset$uuid[[1]])), 0L)
})

test_that("archive-settle 6b: a size change (a truncated copy) is warned about and not accepted, standalone and through ingest_dir()", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())
  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.xls")
  st_truncate(a$stored)
  expect_warning(
    out <- archive_settle(con, now = st_archived_at(con, a$uuid) + 60),
    regexp = a$name, fixed = TRUE
  )
  expect_equal(nrow(out), 0L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, a$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), a$uuid)), 0L)

  s <- st_ingest_setup()
  st_settle_on(list())
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_XTAB.xls")
  st_ingest(dir, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  expect_true(file.exists(x$path))
  st_backdate(s$db, asset$uuid[[1]], 901)
  st_truncate(st_stored_path(s$archive_dir, asset))

  run2 <- st_ingest(dir, s$db)
  expect_true(st_warned_about(run2$warnings, x$name))
  expect_true(file.exists(x$path))
  expect_identical(st_asset_by_name(s$db, x$name)$hash[[1]], x$hash)
})

test_that("archive-settle 6c: a rewritten file of an unconfigured extension (.pdf) is warned about and not accepted, and its source is kept", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())
  a <- st_archive_con(setup, "ZZ7700001_0_COA.pdf")
  st_rewrite_same_size(a$stored)
  out <- suppressWarnings(archive_settle(con, now = st_archived_at(con, a$uuid) + 60))
  expect_equal(nrow(out), 0L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, a$hash)

  s <- st_ingest_setup()
  st_settle_on(list())
  dir <- file.path(s$input_root, "email-01")
  x <- st_write(dir, "ZZ7700001_0_COA.pdf")
  real_snapshot <- sampleTidy:::snapshot_db
  run1 <- testthat::with_mocked_bindings(
    st_ingest(dir, s$db),
    snapshot_db = function(...) {
      stored <- st_find_stored(s$archive_dir, x$name)
      for (p in stored) st_rewrite_same_size(p)
      real_snapshot(...)
    }
  )
  expect_true(st_warned_about(run1$warnings, x$name))
  expect_true(file.exists(x$path))

  run2 <- st_ingest(dir, s$db)
  expect_true(st_warned_about(run2$warnings, x$name))
  expect_true(file.exists(x$path))
  asset <- st_asset_by_name(s$db, x$name)
  expect_identical(asset$hash[[1]], x$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_q(s$db, sql, ...), asset$uuid[[1]])), 0L)
})

test_that("archive-settle 6d: an accept() veto is warned about and not accepted; accept() is called with the stored path, the old hash and the asset row, and a TRUE verdict settles", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  calls <- list()
  st_settle_on(list(accept = function(path, old_hash, asset) {
    calls[[length(calls) + 1L]] <<- list(path = path, old_hash = old_hash, asset = asset)
    FALSE
  }))
  a <- st_archive_con(setup, "ZZ7700001_0_XTAB.xls")
  new_hash <- st_rewrite_same_size(a$stored)
  expect_warning(
    out <- archive_settle(con, now = st_archived_at(con, a$uuid) + 60),
    regexp = a$name, fixed = TRUE
  )
  expect_equal(nrow(out), 0L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, a$hash)
  expect_equal(nrow(st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), a$uuid)), 0L)

  expect_length(calls, 1L)
  if (length(calls) == 1L) {
    expect_identical(normalizePath(calls[[1]]$path), normalizePath(a$stored))
    expect_identical(calls[[1]]$old_hash, a$hash)
    expect_identical(as.character(calls[[1]]$asset$uuid[[1]]), a$uuid)
  }

  # Positive control: the same rewrite settles once accept() allows it.
  st_settle_on(list(accept = function(path, old_hash, asset) TRUE))
  out2 <- archive_settle(con, now = st_archived_at(con, a$uuid) + 120)
  expect_equal(nrow(out2), 1L)
  expect_identical(st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", a$uuid)$hash, new_hash)
})

# ---- 7. re-sending the original after settling ---------------------------

test_that("archive-settle 7: re-sending the original bytes after the asset has settled makes no new asset and no new directory and removes the source; archive_file() with the original hash returns the existing uuid", {
  s <- st_ingest_setup()
  st_settle_on(list())
  dir1 <- file.path(s$input_root, "email-01")
  x <- st_write(dir1, "ZZ7700001_0_XTAB.xls")

  st_ingest(dir1, s$db)
  asset <- st_asset_by_name(s$db, x$name)
  uuid <- asset$uuid[[1]]
  new_hash <- st_rewrite_same_size(st_stored_path(s$archive_dir, asset))
  st_backdate(s$db, uuid, 901)
  st_ingest(dir1, s$db)
  expect_identical(st_asset_by_name(s$db, x$name)$hash[[1]], new_hash)
  expect_false(file.exists(x$path))

  n_assets <- st_q(s$db, "SELECT count(*) AS n FROM asset")$n
  n_dirs <- st_n_dirs(s$archive_dir)

  # The same email arrives again, original bytes.
  dir2 <- file.path(s$input_root, "email-02")
  dir.create(dir2)
  resent <- file.path(dir2, x$name)
  writeBin(x$bytes, resent)
  expect_identical(hash_file(resent), x$hash)
  run3 <- st_ingest(dir2, s$db)

  expect_equal(st_q(s$db, "SELECT count(*) AS n FROM asset")$n, n_assets)
  expect_equal(st_n_dirs(s$archive_dir), n_dirs)
  expect_false(file.exists(resent))
  expect_true(st_was_removed(run3, resent))

  # archive_file()'s own dedup resolves the as-received hash via uuid_asset.
  con <- DBI::dbConnect(duckdb::duckdb(), s$db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  again <- file.path(withr::local_tempdir(), x$name)
  writeBin(x$bytes, again)
  got <- archive_file(con, again, x$hash, event = list(work_order = st_wo))
  expect_identical(got, uuid)
  expect_equal(st_qc(con, "SELECT count(*) AS n FROM asset")$n, n_assets)
  expect_equal(st_n_dirs(s$archive_dir), n_dirs)
})

# ---- 8. the re-ingest guard ----------------------------------------------

# Local copies of test-commit.R's builders (test files do not share them).
st_mk_row <- function(...) {
  defaults <- list(
    source_hash = "hash-1", source_ref = "row1", work_order = "ZZ7700003",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = "ZZ7700003001", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "Fluoride",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    total_or_filtered = "T", units_raw = "mg/L", value_raw = "<0.1",
    value_num = 0.1, value_chr = NA_character_, below_detection = TRUE,
    rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
    comments = NA_character_, confidence = 1,
    sample_datetime_raw = "24 May 2025 11:45", sampler = NA_character_,
    matrix_raw = "WATER", parent_sample = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

st_mk_event <- function(results, work_order) {
  list(
    work_order = work_order, orphan = FALSE, results = results,
    samples = tibble::tibble(),
    files = tibble::tibble(hash = character(), filename = character(),
                           adapter = character(), rank = integer(), kept = logical()),
    report = list(n_results = nrow(results), n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                          reason = character()),
                  warnings = character())
  )
}

st_mk_commit_event <- function(files, work_order) {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(), files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

# A lab file registered as `reconciled`, as commit_event() expects to find it.
st_reconciled_file <- function(setup, filename, work_order) {
  path <- file.path(setup$src_dir, filename)
  writeLines(paste("SampleCode,ChemCode", filename, strrep("A", 40)), path)
  hash <- hash_file(path)
  DBI::dbExecute(setup$con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, work_order, revision)
    VALUES (?, ?, ?, 'reconciled', ?, 0)",
    params = list(hash, filename, path, work_order))
  list(hash = hash, path = path, name = filename,
       files = tibble::tibble(hash = hash, filename = filename,
                              adapter = "esdat/1", rank = 3L, kept = TRUE))
}

st_guard_rows <- function(con, wo) {
  st_qc(con, "SELECT * FROM review_queue WHERE kind = 'work_order_reingest' AND work_order = ?", wo)
}

test_that("archive-settle 8a: a settled retained sibling is still not prior-ingest evidence - a work order's first pipeline delivery commits with no work_order_reingest item", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())
  wo <- "ZZ7700002"

  # A legacy work order: samples, no asset of its own.
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-st02', 'ZZ7700002', 'Work order')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation)
    VALUES ('s-st02', 'fa-0001', 'p-st02', TIMESTAMP '2025-06-01 00:00:00', TIMESTAMP '2025-05-31 23:00:00', 'ALS')")

  # Its retained sibling, archived and then rewritten by the store.
  sib <- st_archive_con(setup, "ZZ7700002_0_XTAB.xls", wo = wo)
  st_rewrite_same_size(sib$stored)
  settled <- archive_settle(con, now = st_archived_at(con, sib$uuid) + 1000)
  expect_equal(nrow(settled), 1L)

  # The work order's lab data now arrives through the pipeline.
  f <- st_reconciled_file(setup, "PROJ_A.ESDAT_ZZ7700002_0.Chemistry2e.csv", wo)
  event <- st_mk_event(st_mk_row(source_hash = f$hash, work_order = wo,
                                 lab_sample_id = "ZZ7700002001",
                                 sample_datetime_raw = "03 Aug 2025 09:00"), wo)
  out <- commit_event(st_mk_commit_event(f$files, wo), reconcile_event(event, con), con)

  expect_false(isTRUE(out$blocked))
  expect_equal(nrow(st_guard_rows(con, wo)), 0L)
})

test_that("archive-settle 8b: retrying a blocked event after its archived file has settled adds no work_order_reingest item, no asset row and no archive directory", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list(ext = "csv"))
  wo <- "ZZ7700003"

  f0 <- st_reconciled_file(setup, "PROJ_A.ESDAT_ZZ7700003_0.Chemistry2e.csv", wo)
  event0 <- st_mk_event(st_mk_row(source_hash = f0$hash, work_order = wo,
                                  sample_datetime_raw = "01 Aug 2025 09:00"), wo)
  commit_event(st_mk_commit_event(f0$files, wo), reconcile_event(event0, con), con)

  # A differently-named re-download trips the F.10 guard; its file is archived
  # on the blocked branch.
  lo <- st_reconciled_file(setup, "PROJ_A.ESDAT_ZZ7700003_0_REDOWNLOAD.Chemistry2e.csv", wo)
  event_lo <- st_mk_event(st_mk_row(source_hash = lo$hash, work_order = wo,
                                    sample_datetime_raw = "03 Aug 2025 09:00"), wo)
  resolved_lo <- reconcile_event(event_lo, con)
  out1 <- commit_event(st_mk_commit_event(lo$files, wo), resolved_lo, con)
  expect_true(isTRUE(out1$blocked))
  expect_equal(nrow(st_guard_rows(con, wo)), 1L)

  lo_asset <- st_qc(con, "SELECT * FROM asset WHERE hash = ?", lo$hash)
  expect_equal(nrow(lo_asset), 1L)
  lo_uuid <- lo_asset$uuid[[1]]
  expect_identical(st_qc(con, "SELECT uuid_asset FROM ingest_file WHERE hash = ?", lo$hash)$uuid_asset, lo_uuid)

  st_rewrite_same_size(file.path(setup$archive_dir, lo_uuid, lo_asset$filename[[1]]))
  settled <- archive_settle(con, now = st_archived_at(con, lo_uuid) + 1000)
  expect_identical(settled$uuid, lo_uuid)

  n_review <- st_qc(con, "SELECT count(*) AS n FROM review_queue")$n
  n_assets <- st_qc(con, "SELECT count(*) AS n FROM asset")$n
  n_dirs <- st_n_dirs(setup$archive_dir)

  out2 <- commit_event(st_mk_commit_event(lo$files, wo), resolved_lo, con)
  expect_true(isTRUE(out2$blocked))
  expect_equal(out2$n_review, 0)
  expect_equal(st_qc(con, "SELECT count(*) AS n FROM review_queue")$n, n_review)
  expect_equal(nrow(st_guard_rows(con, wo)), 1L)
  expect_equal(st_qc(con, "SELECT count(*) AS n FROM asset")$n, n_assets)
  expect_equal(st_n_dirs(setup$archive_dir), n_dirs)
  expect_identical(st_qc(con, "SELECT uuid_asset FROM ingest_file WHERE hash = ?", lo$hash)$uuid_asset, lo_uuid)
})

# ---- 9. completed_work() -------------------------------------------------

test_that("archive-settle 9: completed_work() is still blocked by an open review item that carries a settled file's as-received hash", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())
  wo <- "ZZ7700004"

  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-st04', 'ZZ7700004', 'Work order')")
  DBI::dbExecute(con, "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime)
    VALUES ('s-st04', 'fa-0001', 'p-st04', TIMESTAMP '2025-06-01 00:00:00', TIMESTAMP '2025-05-31 23:00:00')")
  a <- st_archive_con(setup, "ZZ7700004_0_XTAB.xls", wo = wo)
  st_rewrite_same_size(a$stored)
  settled <- archive_settle(con, now = st_archived_at(con, a$uuid) + 1000)
  expect_equal(nrow(settled), 1L)

  expect_true("p-st04" %in% completed_work(con)$uuid)   # control: complete

  DBI::dbExecute(con, "INSERT INTO review_queue (uuid, created_at, kind, source_hash, status)
    VALUES ('rq-st04', CURRENT_TIMESTAMP, 'other', ?, 'open')", params = list(a$hash))
  expect_false("p-st04" %in% completed_work(con)$uuid)
})

# ---- 10. bad config -------------------------------------------------------

test_that("archive-settle 10: bad archive_settle config aborts with sampletidy_error, valid config is accepted, and the env-var form is refused", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  expect_true("archive_settle" %in% sampleTidy:::.st_config_list_keys)

  bad <- list(
    "not a list"             = "xls",
    "logical scalar"         = TRUE,
    "negative hold"          = list(hold_secs = -1),
    "character hold"         = list(hold_secs = "900"),
    "NA hold"                = list(hold_secs = NA_real_),
    "two holds"              = list(hold_secs = c(1, 2)),
    "zero window"            = list(window_hours = 0),
    "negative window"        = list(window_hours = -5),
    "character window"       = list(window_hours = "72"),
    "empty ext"              = list(ext = character(0)),
    "numeric ext"            = list(ext = 1),
    "NA ext"                 = list(ext = NA_character_),
    "accept not a function"  = list(accept = "yes"),
    "unknown field"          = list(holdsecs = 900)
  )
  for (nm in names(bad)) {
    withr::with_options(list("sampletidy.archive_settle" = NULL), {
      expect_error(
        {
          st_config("archive_settle", bad[[nm]])
          archive_settle(con, now = Sys.time())
        },
        class = "sampletidy_error",
        info = nm
      )
    })
  }

  good <- list(
    list(),
    list(ext = "xls"),
    list(ext = c("xls", "doc", "ppt"), hold_secs = 0, window_hours = 1),
    list(accept = function(path, old_hash, asset) TRUE)
  )
  for (i in seq_along(good)) {
    withr::with_options(list("sampletidy.archive_settle" = NULL), {
      expect_no_error({
        st_config("archive_settle", good[[i]])
        archive_settle(con, now = Sys.time())
      })
    })
  }

  withr::with_options(list("sampletidy.archive_settle" = NULL), {
    withr::with_envvar(c(SAMPLETIDY_ARCHIVE_SETTLE = "xls"), {
      expect_error(st_config("archive_settle"), class = "sampletidy_error")
    })
  })
})

# ---- 11. a crash part-way through the pass --------------------------------

test_that("archive-settle 11: a crash part-way through the pass keeps the settles already made, and the next pass settles the rest exactly once each", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())

  files <- lapply(c("ZZ7700001_0_XTAB.xls", "ZZ7700001_1_XTAB.xls", "ZZ7700001_2_XTAB.xls"),
                  function(n) st_archive_con(setup, n))
  new_hash <- vapply(files, function(f) st_rewrite_same_size(f$stored), character(1))
  names(new_hash) <- vapply(files, `[[`, character(1), "uuid")
  latest <- max(do.call(c, lapply(files, function(f) st_archived_at(con, f$uuid))))

  # Inject the crash at the second asset the pass updates.
  real_update <- sampleTidy:::db_update
  seen <- character(0)
  run1 <- testthat::with_mocked_bindings(
    tryCatch(suppressWarnings(archive_settle(con, now = latest + 1000)), error = function(e) e),
    db_update = function(con, table, uuid = NULL, changes, actor, reason,
                         source_hash = NA, key = NULL) {
      if (identical(table, "asset") && !is.null(uuid)) {
        if (!(uuid %in% seen)) seen <<- c(seen, uuid)
        if (length(seen) >= 2L && identical(uuid, seen[[2]])) {
          cli::cli_abort("injected crash during the settle pass")
        }
      }
      real_update(con, table, uuid = uuid, changes = changes, actor = actor,
                  reason = reason, source_hash = source_hash, key = key)
    }
  )
  expect_gte(length(seen), 2L)
  if (length(seen) >= 2L) {
    first <- seen[[1]]
    crashed <- seen[[2]]
    hash_of <- function(u) st_qc(con, "SELECT hash FROM asset WHERE uuid = ?", u)$hash
    log_n <- function(u) nrow(st_rewrite_rows(function(sql, ...) st_qc(con, sql, ...), u))
    # The asset settled before the crash is committed, with its log row.
    expect_identical(hash_of(first), new_hash[[first]])
    expect_equal(log_n(first), 1L)
    # The crashed asset rolled back whole: old hash, no log row.
    orig <- files[[which(names(new_hash) == crashed)]]$hash
    expect_identical(hash_of(crashed), orig)
    expect_equal(log_n(crashed), 0L)

    # The next pass settles everything left, and nothing twice.
    run2 <- archive_settle(con, now = latest + 2000)
    expect_true(crashed %in% run2$uuid)
    expect_false(first %in% run2$uuid)
    for (u in names(new_hash)) {
      expect_identical(hash_of(u), new_hash[[u]])
      expect_equal(log_n(u), 1L)
    }
  }
})

# ---- 12. archive_file() writes uuid_asset ----------------------------------

test_that("archive-settle 12: archive_file() writes ingest_file.uuid_asset on the new-asset path and on the reuse path", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # New-asset path.
  f <- st_write(setup$src_dir, "ZZ7700001_0_XTAB.xls")
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, path_first_seen, state)
    VALUES (?, ?, ?, 'quarantined')", params = list(f$hash, f$name, f$path))
  uuid <- archive_file(con, f$path, f$hash, event = list(work_order = st_wo))
  expect_identical(st_qc(con, "SELECT uuid_asset FROM ingest_file WHERE hash = ?", f$hash)$uuid_asset, uuid)

  # Reuse path: a legacy asset row already holds these bytes and the
  # ingest_file row is unlinked.
  g <- st_write(setup$src_dir, "ZZ7700001_0_COA.pdf")
  DBI::dbExecute(con, "INSERT INTO asset (uuid, filename, hash, uuid_project, type)
    VALUES ('as-st-legacy', ?, ?, 'p-st01', 'Certificate of analysis')", params = list(g$name, g$hash))
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, path_first_seen, state)
    VALUES (?, ?, ?, 'quarantined')", params = list(g$hash, g$name, g$path))
  n_assets <- st_qc(con, "SELECT count(*) AS n FROM asset")$n
  got <- archive_file(con, g$path, g$hash, event = list(work_order = st_wo))
  expect_identical(got, "as-st-legacy")
  expect_equal(st_qc(con, "SELECT count(*) AS n FROM asset")$n, n_assets)
  expect_identical(st_qc(con, "SELECT uuid_asset FROM ingest_file WHERE hash = ?", g$hash)$uuid_asset,
                   "as-st-legacy")

  # With no ingest_file row at all, archiving and reuse still work.
  h <- st_write(setup$src_dir, "ZZ7700001_0_COC.pdf")
  uuid_h <- archive_file(con, h$path, h$hash, event = list(work_order = st_wo))
  expect_identical(archive_file(con, h$path, h$hash, event = list(work_order = st_wo)), uuid_h)
})

# ---- 13/14. the inbox fallbacks resolve through uuid_asset ------------------

test_that("archive-settle 13: the folder -> project fallback finds a settled file's project through uuid_asset", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())

  # A gas-style project with no ALS work order token in its file names.
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES ('p-st05', 'ZZ gas report 05', 'ACIRL report')")
  wb <- st_archive_con(setup, "Monthly gas report 05.xls", wo = st_wo)
  DBI::dbExecute(con, "UPDATE asset SET uuid_project = 'p-st05' WHERE uuid = ?", params = list(wb$uuid))
  st_rewrite_same_size(wb$stored)
  expect_equal(nrow(archive_settle(con, now = st_archived_at(con, wb$uuid) + 1000)), 1L)

  folder <- file.path(withr::local_tempdir(), "email-05")
  scan <- file.path(folder, "scanned field sheet.pdf")
  routed <- tibble::tibble(
    path = c(file.path(folder, wb$name), scan),
    filename = c(wb$name, basename(scan)),
    hash = c(wb$hash, "h-st-scan")
  )
  expect_identical(sampleTidy:::.ig_folder_work_order(con, routed, scan), "ZZ gas report 05")
})

test_that("archive-settle 14: the stem match ignores a settled file's own asset, found through uuid_asset", {
  setup <- st_con_setup()
  con <- setup$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  st_settle_on(list())

  # The only asset with this stem is the file's own (settled) copy, so there
  # is no OTHER report to attach it to.
  a <- st_archive_con(setup, "Monthly gas report 06.xls", wo = st_wo)
  st_rewrite_same_size(a$stored)
  expect_equal(nrow(archive_settle(con, now = st_archived_at(con, a$uuid) + 1000)), 1L)

  expect_identical(
    sampleTidy:::.ig_stem_work_order(con, a$path, hash = a$hash),
    NA_character_
  )
})
