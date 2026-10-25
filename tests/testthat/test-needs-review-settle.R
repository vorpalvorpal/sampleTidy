# R-22.N (Robin 2026-10-25, "fix"): files parked on needs_review are settled
# when their review items are.
#
# Found by migration 081 (dev/migrations/081-settle-needs-review-files.R,
# dev/MIGRATIONS.md row 1081). commit_event() parks a delivery's kept files on
# `needs_review` when its rows were all withheld (review items and no clean
# row) or the F.10 work_order_reingest guard blocked it. Nothing moved them on
# afterwards: resolve_review(), review_queue_close() and release_review()
# wrote review_queue only, and inbox.R counted needs_review-with-asset as done,
# which hid it. 302 files accumulated; 081 settled 301 by hand.
#
# The rules pinned here:
#
#   1. `.ct_set_file_states()` records `ingest_file.work_order` (from the
#      event's work order) on every file it transitions. It sets exactly three
#      states: needs_review, committed, archived (it never sets `failed`).
#      Tested through commit_event(), so the pin does not depend on how the
#      work order reaches the helper.
#
#   2. Settling. A review item COVERS a needs_review file when the item's
#      source_hash is the file's hash, or the item's work_order equals the
#      file's (non-NULL) ingest_file.work_order. When resolve_review(),
#      review_queue_close() or release_review() closes an item, every
#      needs_review file the item covered that no OPEN item still covers moves
#      needs_review -> committed -> archived, in the same transaction, through
#      ingest_file_set_state() (legal transitions only). Files in any other
#      state are not touched. A delivery is the set of files sharing a work
#      order, so a delivery of two files where only one carries the item
#      settles whole.
#
#   3. Guard dedupe. When the F.10 guard blocks a LATER delivery of a work
#      order that already has an open work_order_reingest item, the later file
#      gets ITS OWN work_order_reingest/blocked row (source_hash = its hash,
#      same work_order and uuid_target). Chosen over appending the hash to the
#      first item's payload because:
#        * every blocked file is then named by a typed column
#          (review_queue.source_hash), which is what settling, the db_check and
#          migration 081's `.mig081_governing()` all key on - no JSON parsing;
#        * resolving or reading one item never silently answers for a file the
#          reviewer did not see;
#        * the dedupe that still matters - a RETRY of the same blocked file
#          must not mint a second row - stays exact, keyed on
#          (kind, work_order, source_hash, open).
#      Consequence, pinned below: both items carry the work order, so each
#      covers both files by work_order. Resolving ONE leaves both files
#      parked; resolving the second settles both. review_queue_close() on the
#      shared project uuid_target closes both at once and settles both.
#      `.ct_reingest_guard_preview()` mirrors commit_event() and must count the
#      later file's new row.
#
#   4. db_check `ingest_file_needs_review_resolved` (hourly, warn): a
#      needs_review file that no open review item covers. When work_order is
#      NULL (legacy rows), the work order is read from a state_reason of the
#      form "commit_event: <WO>". Key = the file's hash. Its failing case is
#      table-driven in helper-db-checks.R (`dbc_violation_cases`).
#
#   (5. the inbox rule lives in test-inbox-leftovers.R, with its fixtures.)
#
# Fixtures: synthetic, on seed_db() (helper-db.R). The commit-path fixtures
# mirror test-commit.R's commit_test_setup()/mk_clean_row() (file-local there,
# so the few needed are copied with an `nr_` prefix); the release fixture
# reuses test-release-sample-override.R's rs_* helpers the way
# test-release-sample-new.R does. Nothing touches a live database.

for (rs_expr in parse(test_path("test-release-sample-override.R"), keep.source = FALSE)) {
  if (is.call(rs_expr) && identical(rs_expr[[1]], as.name("<-"))) eval(rs_expr, environment())
}
rm(rs_expr)

# ---- local helpers (definitions only) ------------------------------------------------

# A seeded DB with the asset table and an archive dir. Returns list(path, con,
# src); the connection is closed when the calling test ends.
nr_db <- function(env = parent.frame()) {
  path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(path)
  withr::defer(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE), envir = env)
  ensure_test_asset_table(con)
  withr::local_options(list("sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env)),
                       .local_envir = env)
  list(path = path, con = con, src = withr::local_tempdir(.local_envir = env))
}

# Write a real source file and register it `reconciled` with work_order NULL
# (as ingest leaves it: nothing records the work order before commit).
nr_file <- function(db, filename) {
  p <- file.path(db$src, filename)
  writeLines(paste("SampleCode,ChemCode", filename), p)
  h <- hash_file(p)
  DBI::dbExecute(db$con, "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
                          VALUES (?, ?, ?, 'reconciled', NULL, 0)",
                 params = list(h, filename, p))
  list(hash = h, path = p, filename = filename)
}

nr_files_tbl <- function(...) {
  fs <- list(...)
  tibble::tibble(hash = vapply(fs, `[[`, "", "hash"),
                 filename = vapply(fs, `[[`, "", "filename"),
                 adapter = "esdat/1", rank = 3L, kept = TRUE)
}

nr_event <- function(files, work_order) {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(), files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(), reason = character()),
                  warnings = character())
  )
}

# test-commit.R's mk_clean_row(), trimmed to the arguments used here.
nr_clean_row <- function(source_hash, work_order, day = "2025-06-10") {
  tibble::tibble(
    source_hash = source_hash, source_ref = paste0("row-", source_hash), work_order = work_order,
    revision = 0L, org = "ALS", adapter = "esdat/1", lab_sample_id = paste0(work_order, "001"),
    sample_type = "Normal", feature_raw = "T.S01", analyte_raw = "pH Value", cas_number = NA_character_,
    method_raw = "EA005P: pH by PC Titrator", total_or_filtered = "T", units_raw = "pH Unit",
    value_raw = "6.50", value_num = 6.50, value_chr = NA_character_, below_detection = FALSE,
    rl = NA_real_, lab_qualifier = NA_character_, analysed_date = as.Date(day),
    comments = NA_character_, confidence = 1, sample_datetime_raw = paste(day, "09:00"),
    sampler = NA_character_, matrix_raw = "WATER", parent_sample = NA_character_,
    uuid_feature = "f-0001", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_converted = 6.50, rl_converted = NA_real_,
    sample_date = as.Date(day),
    sample_datetime = as.POSIXct(paste(day, "09:00:00"), tz = "Australia/Sydney"),
    supersedes = NA_character_
  )
}

nr_resolved <- function(clean, review = tibble::tibble()) {
  list(clean = clean, review = review, skipped = tibble::tibble(), counts = c(new = nrow(clean)))
}

nr_file_row <- function(con, hash) {
  DBI::dbGetQuery(con, "SELECT state, work_order, state_reason FROM ingest_file WHERE hash = ?",
                  params = list(hash))
}
nr_state <- function(con, hash) nr_file_row(con, hash)$state[[1]]

nr_guard_rows <- function(con) {
  DBI::dbGetQuery(con, "SELECT uuid, work_order, source_hash, subkind, status, uuid_target
                          FROM review_queue WHERE kind = 'work_order_reingest' ORDER BY created_at, uuid")
}

# A needs_review file inserted directly (for the settling rules, which read the
# DB only). `work_order` may be NA.
nr_parked <- function(con, hash, work_order, state = "needs_review",
                      reason = paste0("commit_event: ", work_order)) {
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, state, state_reason, work_order, revision, updated_at)
                       VALUES (?, ?, ?, ?, ?, 0, TIMESTAMP '2026-01-01 00:00:00')",
                 params = list(hash, paste0(hash, ".csv"), state, reason, work_order))
  invisible(hash)
}

nr_item <- function(con, work_order, source_hash, kind = "value_conflict") {
  review_queue_add(con, kind = kind, work_order = work_order, source_hash = source_hash,
                   payload = paste("nr fixture", kind, source_hash))
}

nr_hex <- function(i) sprintf("%032x", as.integer(i))

# A work order committed clean once (file A0 archived), then a re-download A1
# blocked by the F.10 guard. Returns the db plus the files and the project uuid.
nr_blocked_once <- function(wo, env = parent.frame()) {
  db <- nr_db(env)
  a0 <- nr_file(db, paste0(wo, "_A0.CSV"))
  commit_event(nr_event(nr_files_tbl(a0), wo), nr_resolved(nr_clean_row(a0$hash, wo)), db$con)
  a1 <- nr_file(db, paste0(wo, "_A1_REDL.CSV"))
  out <- commit_event(nr_event(nr_files_tbl(a1), wo),
                      nr_resolved(nr_clean_row(a1$hash, wo, day = "2025-09-01")), db$con)
  testthat::expect_true(isTRUE(out$blocked))
  proj <- DBI::dbGetQuery(db$con, "SELECT uuid FROM project WHERE name = ? AND type = 'Work order'",
                          params = list(wo))$uuid[[1]]
  c(db, list(a0 = a0, a1 = a1, wo = wo, proj = proj))
}

# The later delivery A2 of the same work order, blocked while A1's item is open.
nr_block_later <- function(b, name = "_A2_REDL2.CSV", day = "2025-09-02") {
  a2 <- nr_file(b, paste0(b$wo, name))
  ev <- nr_event(nr_files_tbl(a2), b$wo)
  res <- nr_resolved(nr_clean_row(a2$hash, b$wo, day = day))
  list(file = a2, event = ev, resolved = res)
}

# ======================================================================================
# 1. .ct_set_file_states() records ingest_file.work_order
# ======================================================================================

test_that("R-22.N: a clean commit records the event's work order on every file it archives", {
  db <- nr_db()
  wo <- "XY8880001"
  f1 <- nr_file(db, paste0(wo, "_0.Chemistry2e.CSV"))
  f2 <- nr_file(db, paste0(wo, "_0.Sample2e.CSV"))
  commit_event(nr_event(nr_files_tbl(f1, f2), wo), nr_resolved(nr_clean_row(f1$hash, wo)), db$con)
  for (f in list(f1, f2)) {
    r <- nr_file_row(db$con, f$hash)
    expect_identical(r$state[[1]], "archived", info = f$filename)
    expect_identical(r$work_order[[1]], wo, info = f$filename)
  }
})

test_that("R-22.N: a review-only commit records the event's work order on every file it parks on needs_review", {
  db <- nr_db()
  wo <- "XY8880002"
  f1 <- nr_file(db, paste0(wo, "_0.Chemistry2e.CSV"))
  f2 <- nr_file(db, paste0(wo, "_0.Header.XML"))
  rq <- .rq_row(kind = "value_conflict", work_order = wo, source_hash = f1$hash,
                diagnostics = list(note = "nr fixture"))
  out <- commit_event(nr_event(nr_files_tbl(f1, f2), wo),
                      nr_resolved(nr_clean_row(f1$hash, wo)[0, ], review = rq$review), db$con)
  expect_false(isTRUE(out$blocked))
  for (f in list(f1, f2)) {
    r <- nr_file_row(db$con, f$hash)
    expect_identical(r$state[[1]], "needs_review", info = f$filename)
    expect_identical(r$work_order[[1]], wo, info = f$filename)
  }
})

test_that("R-22.N: a guard-blocked commit records the event's work order on the file it parks", {
  b <- nr_blocked_once("XY8880003")
  r <- nr_file_row(b$con, b$a1$hash)
  expect_identical(r$state[[1]], "needs_review")
  expect_identical(r$work_order[[1]], "XY8880003")
  # the clean first delivery, too
  expect_identical(nr_file_row(b$con, b$a0$hash)$work_order[[1]], "XY8880003")
})

# ======================================================================================
# 2. Settling on resolution
# ======================================================================================

test_that("R-22.N: resolve_review() of a delivery's last open item archives every needs_review file of the delivery, and only those", {
  db <- nr_db()
  con <- db$con
  wo <- "XY8880010"
  nr_parked(con, nr_hex(1), wo)                 # carries the item
  nr_parked(con, nr_hex(2), wo)                 # same delivery, no item of its own
  nr_parked(con, nr_hex(3), wo, state = "reconciled", reason = NA_character_)  # not parked: untouched
  nr_parked(con, nr_hex(4), "XY8880011")        # another delivery: untouched
  nr_item(con, "XY8880011", nr_hex(4))          # ...which still has its own open item
  item <- nr_item(con, wo, nr_hex(1))

  expect_true(isTRUE(resolve_review(item, resolution = "checked", resolved_by = "tester", db = db$path)))

  expect_identical(nr_state(con, nr_hex(1)), "archived")
  expect_identical(nr_state(con, nr_hex(2)), "archived")
  expect_identical(nr_state(con, nr_hex(3)), "reconciled")
  expect_identical(nr_state(con, nr_hex(4)), "needs_review")
})

test_that("R-22.N: an item covering a file by source_hash alone (work_order NULL on both) settles that file", {
  db <- nr_db()
  con <- db$con
  nr_parked(con, nr_hex(5), NA_character_, reason = "commit_event: NA")
  item <- nr_item(con, NA_character_, nr_hex(5))
  resolve_review(item, resolution = "checked", resolved_by = "tester", db = db$path)
  expect_identical(nr_state(con, nr_hex(5)), "archived")
})

test_that("R-22.N: a partially resolved delivery stays needs_review until its last covering item is resolved", {
  db <- nr_db()
  con <- db$con
  wo <- "XY8880020"
  nr_parked(con, nr_hex(11), wo)
  nr_parked(con, nr_hex(12), wo)
  item_a <- nr_item(con, wo, nr_hex(11))
  # covers the delivery by work order only (raised on neither file)
  item_b <- nr_item(con, wo, NA_character_, kind = "unknown_feature")

  resolve_review(item_a, resolution = "checked", resolved_by = "tester", db = db$path)
  expect_identical(nr_state(con, nr_hex(11)), "needs_review")
  expect_identical(nr_state(con, nr_hex(12)), "needs_review")

  resolve_review(item_b, resolution = "checked", resolved_by = "tester", db = db$path)
  expect_identical(nr_state(con, nr_hex(11)), "archived")
  expect_identical(nr_state(con, nr_hex(12)), "archived")
})

test_that("R-22.N: an open item raised on the file itself holds it even when the work-order item is resolved", {
  db <- nr_db()
  con <- db$con
  wo <- "XY8880021"
  nr_parked(con, nr_hex(13), wo)
  own <- nr_item(con, NA_character_, nr_hex(13))   # by source_hash only
  wo_item <- nr_item(con, wo, NA_character_)       # by work order only
  resolve_review(wo_item, resolution = "checked", resolved_by = "tester", db = db$path)
  expect_identical(nr_state(con, nr_hex(13)), "needs_review")
  resolve_review(own, resolution = "checked", resolved_by = "tester", db = db$path)
  expect_identical(nr_state(con, nr_hex(13)), "archived")
})

test_that("R-22.N: settling runs in resolve_review()'s transaction, through ingest_file_set_state() - a failed transition leaves the item open and the file parked", {
  db <- nr_db()
  con <- db$con
  wo <- "XY8880022"
  nr_parked(con, nr_hex(14), wo)
  item <- nr_item(con, wo, nr_hex(14))
  real <- ingest_file_set_state
  seen <- character(0)
  testthat::local_mocked_bindings(ingest_file_set_state = function(con, hash, state, ...) {
    seen <<- c(seen, state)
    if (identical(state, "archived")) stop("nr: injected failure")
    real(con, hash, state, ...)
  })
  expect_error(resolve_review(item, resolution = "checked", resolved_by = "tester", db = db$path))
  # needs_review -> committed was attempted first, through the state machine
  expect_identical(seen, c("committed", "archived"))
  expect_identical(nr_state(con, nr_hex(14)), "needs_review")
  st <- DBI::dbGetQuery(con, "SELECT status FROM review_queue WHERE uuid = ?", params = list(item))$status
  expect_identical(st, "open")
})

test_that("R-22.N: review_queue_close() settles the needs_review files of the items it closes", {
  db <- nr_db()
  con <- db$con
  wo <- "XY8880030"
  nr_parked(con, nr_hex(21), wo)
  nr_parked(con, nr_hex(22), wo)
  review_queue_add(con, kind = "unknown_feature", work_order = wo, source_hash = nr_hex(21),
                   uuid_target = "fa-0010", payload = "nr fixture")
  n <- review_queue_close(con, uuid_target = "fa-0010", resolution = "alias confirmed",
                          resolved_by = "tester", kind = "unknown_feature")
  expect_equal(n, 1L)
  expect_identical(nr_state(con, nr_hex(21)), "archived")
  expect_identical(nr_state(con, nr_hex(22)), "archived")
})

test_that("R-22.N: release_review() that releases a delivery's withheld rows ends with its file archived; the other delivery stays needs_review", {
  db <- rs_two_items(0.9, 1.2)
  con <- seed_con(db$path)
  hashes <- DBI::dbGetQuery(con, "SELECT uuid, source_hash FROM review_queue WHERE kind = 'sample_ambiguous'")
  h1 <- hashes$source_hash[hashes$uuid == db$item_1]
  h2 <- hashes$source_hash[hashes$uuid == db$item_2]
  expect_identical(nr_state(con, h1), "needs_review")   # setup: withheld whole
  expect_identical(nr_state(con, h2), "needs_review")
  DBI::dbDisconnect(con, shutdown = TRUE)

  sampleTidy::release_review(db$item_1, overrides = list(sample = "s-a"),
                             resolved_by = "tester", db = db$path)

  con <- seed_con(db$path)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(rs_values(con, "s-a"), 0.9)              # the rows were released
  expect_identical(nr_state(con, h1), "archived")
  expect_identical(nr_state(con, h2), "needs_review")
})

# ======================================================================================
# 3. F.10 guard: a later blocked delivery records its own hash
# ======================================================================================

test_that("R-22.N: a later delivery blocked under an already-open work_order_reingest item gets its own guard row; a retry adds none", {
  b <- nr_blocked_once("XY8880040")
  later <- nr_block_later(b)

  pv <- .ct_reingest_guard_preview(b$con, later$event, later$resolved)
  expect_true(isTRUE(pv$blocked))
  expect_equal(pv$n_review, 1)   # the preview mirrors the write below

  out <- commit_event(later$event, later$resolved, b$con)
  expect_true(isTRUE(out$blocked))
  expect_equal(out$n_review, 1)

  g <- nr_guard_rows(b$con)
  expect_equal(nrow(g), 2)
  expect_setequal(g$source_hash, c(b$a1$hash, later$file$hash))
  expect_true(all(g$status == "open"))
  expect_true(all(g$work_order == b$wo))
  expect_true(all(g$subkind == "blocked"))
  expect_true(all(g$uuid_target == b$proj))
  expect_identical(nr_state(b$con, later$file$hash), "needs_review")

  # a retry of the same blocked file is still a clean no-op
  out2 <- commit_event(later$event, later$resolved, b$con)
  expect_true(isTRUE(out2$blocked))
  expect_equal(out2$n_review, 0)
  expect_equal(nrow(nr_guard_rows(b$con)), 2)
})

test_that("R-22.N: resolving the guard items settles both blocked deliveries - one alone leaves both parked", {
  b <- nr_blocked_once("XY8880041")
  later <- nr_block_later(b)
  commit_event(later$event, later$resolved, b$con)
  g <- nr_guard_rows(b$con)
  expect_equal(nrow(g), 2)
  first <- g$uuid[g$source_hash == b$a1$hash]
  second <- g$uuid[g$source_hash == later$file$hash]
  expect_length(first, 1)
  expect_length(second, 1)

  resolve_review(first, resolution = "re-download, nothing new", resolved_by = "tester", db = b$path)
  expect_identical(nr_state(b$con, b$a1$hash), "needs_review")
  expect_identical(nr_state(b$con, later$file$hash), "needs_review")

  resolve_review(second, resolution = "re-download, nothing new", resolved_by = "tester", db = b$path)
  expect_identical(nr_state(b$con, b$a1$hash), "archived")
  expect_identical(nr_state(b$con, later$file$hash), "archived")
  expect_identical(nr_state(b$con, b$a0$hash), "archived")   # the clean original, unchanged
})

test_that("R-22.N: review_queue_close() on the work order's project closes both guard items and settles both blocked deliveries", {
  b <- nr_blocked_once("XY8880042")
  later <- nr_block_later(b)
  commit_event(later$event, later$resolved, b$con)
  n <- review_queue_close(b$con, uuid_target = b$proj, resolution = "re-downloads",
                          resolved_by = "tester", kind = "work_order_reingest")
  expect_equal(n, 2L)
  expect_identical(nr_state(b$con, b$a1$hash), "archived")
  expect_identical(nr_state(b$con, later$file$hash), "archived")
})

# ======================================================================================
# 4. db_check ingest_file_needs_review_resolved
# ======================================================================================

test_that("R-22.N: ingest_file_needs_review_resolved is an hourly warn check", {
  core <- db_checks_core()
  r <- core[core$name == "ingest_file_needs_review_resolved", , drop = FALSE]
  expect_equal(nrow(r), 1)
  expect_identical(r$tier, "hourly")
  expect_identical(r$severity, "warn")
})

test_that("R-22.N: ingest_file_needs_review_resolved passes a needs_review file covered by an open item - by source_hash, by work_order, or by the legacy state_reason work order", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    nr_parked(con, dbc_hex(931), NA_character_, reason = "commit_event: NA")   # by source_hash
    review_queue_add(con, kind = "value_conflict", source_hash = dbc_hex(931), payload = "x")
    nr_parked(con, dbc_hex(932), "XX7000003")                                  # by work_order
    review_queue_add(con, kind = "value_conflict", work_order = "XX7000003", payload = "x")
    nr_parked(con, dbc_hex(933), NA_character_, reason = "commit_event: XX7000004")  # legacy
    review_queue_add(con, kind = "value_conflict", work_order = "XX7000004", payload = "x")
    db_checks(con, tier = "all")
  })
  r <- dbc_row(res, "ingest_file_needs_review_resolved")
  expect_identical(r$status, "pass", info = dbc_bad(res))
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
})

test_that("R-22.N: ingest_file_needs_review_resolved flags a legacy needs_review file whose state_reason work order has only resolved items", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    nr_parked(con, dbc_hex(934), NA_character_, reason = "commit_event: XX7000005")
    u <- review_queue_add(con, kind = "value_conflict", work_order = "XX7000005", payload = "x")
    DBI::dbExecute(con, "UPDATE review_queue SET status = 'resolved', resolution = 'ok', resolved_by = 'test',
                         resolved_at = TIMESTAMP '2026-01-02 00:00:00' WHERE uuid = ?", params = list(u))
    db_checks(con, tier = "all")
  })
  dbc_expect_only(res, "ingest_file_needs_review_resolved", dbc_hex(934))
})
