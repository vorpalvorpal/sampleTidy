# R-3.8 registry fingerprint (Robin's ruling 2026-10-17, "option 3").
#
# R-3.7 made the router's registry verdicts - `quarantined/unclaimed`,
# `quarantined/adapter_tie` and router-written `failed` (match() threw or
# returned a bad tier) - reconsiderable, but only on an explicit
# `reconsider = TRUE`. So when a new adapter lands, the operator must remember
# to re-check. Option 3 removes that memory burden: each registry verdict
# records a REGISTRY FINGERPRINT (a stable hash of the registered adapters'
# ids and versions) in `ingest_file.registry_fingerprint`, and a later run
# re-decides any stored registry verdict whose fingerprint differs from the
# current registry's, exactly as `reconsider = TRUE` would. A matching
# fingerprint stays skipped. A fingerprint change never re-decides `archived`,
# `ignored` or parse-/commit-written `failed`. `archived`/`ignored` are never
# re-decided at any setting; parse-/commit-`failed` still are under an
# explicit `reconsider = TRUE` (amended ruling, 2026-10-17: the escape hatch
# for a since-fixed parser bug).
#
# Names assumed here (the ruling gave the column as an example; the function
# name is this file's choice):
#   * `registry_fingerprint()` - internal, no arguments, returns a single
#     non-empty string for the CURRENT adapter registry.
#   * `ingest_file.registry_fingerprint` - VARCHAR, added by an ops-schema
#     migration so `seed_db()` (which runs `ensure_schema()`) carries it.
#
# Every "is NOT re-decided" assertion below is backed by a match() call
# counter, not by the stored state alone: a re-decision that happens to land
# on the same verdict leaves the state unchanged, so state alone cannot tell
# "skipped" from "re-decided to the same answer".

fp_adapter <- function(id, tier_for, version = "1.0", counter = NULL) {
  force(tier_for)
  list(
    id = id,
    version = version,
    match = function(file_meta) {
      if (!is.null(counter)) counter$n <- counter$n + 1L
      tier_for(file_meta)
    },
    parse = function(path, file_meta) {
      list(results = ir_results(), samples = ir_samples(), report = list())
    }
  )
}

new_counter <- function() {
  e <- new.env(parent = emptyenv())
  e$n <- 0L
  e
}

fp_stored <- function(con, hash) {
  DBI::dbGetQuery(
    con,
    "SELECT state, state_reason, adapter, registry_fingerprint
       FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )
}

fp_count <- function(con, table) {
  DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n
}

fp_local_registry <- function(env = parent.frame()) {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() }, envir = env)
}

fp_local_db <- function(env = parent.frame()) {
  dir <- withr::local_tempdir(.local_envir = env)
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  list(dir = dir, db = db, con = con)
}

# --- 1. determinism -----------------------------------------------------------

test_that("R-3.8: registry_fingerprint() is a single non-empty string, independent of registration order", {
  fp_local_registry()

  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "2.3"))
  register_adapter(fp_adapter("gamma", function(fm) "no", version = "0.9"))
  fp_abc <- registry_fingerprint()

  expect_true(checkmate::test_string(fp_abc, min.chars = 1))
  expect_identical(registry_fingerprint(), fp_abc,
                   info = "R-3.8: two calls on an unchanged registry must agree")

  clear_adapters()
  register_adapter(fp_adapter("gamma", function(fm) "no", version = "0.9"))
  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "2.3"))
  expect_identical(registry_fingerprint(), fp_abc,
                   info = "R-3.8: registration order must not affect the fingerprint")
})

test_that("R-3.8: registry_fingerprint() changes when an adapter is added, removed, or bumps its version - and only then", {
  fp_local_registry()

  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "1.0"))
  base <- registry_fingerprint()

  # Added.
  register_adapter(fp_adapter("gamma", function(fm) "no", version = "1.0"))
  added <- registry_fingerprint()
  expect_false(identical(added, base), info = "R-3.8: adding an adapter must change the fingerprint")

  # Removed (back to alpha + beta) - and the fingerprint is a pure function of
  # the (id, version) set, so it returns to the base value.
  clear_adapters()
  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "1.0"))
  expect_identical(registry_fingerprint(), base)
  clear_adapters()
  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  removed <- registry_fingerprint()
  expect_false(identical(removed, base), info = "R-3.8: removing an adapter must change the fingerprint")

  # Version bump on an existing id.
  register_adapter(fp_adapter("beta", function(fm) "no", version = "1.1"))
  bumped <- registry_fingerprint()
  expect_false(identical(bumped, base), info = "R-3.8: a version bump must change the fingerprint")

  # Ids and versions only: a different match() body under the same
  # (id, version) is the same fingerprint. That is the ruling's contract -
  # an adapter author signals a behaviour change by bumping `version`.
  clear_adapters()
  register_adapter(fp_adapter("alpha", function(fm) "exact", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "format", version = "1.0"))
  expect_identical(registry_fingerprint(), base,
                   info = "R-3.8: the fingerprint hashes ids and versions, not function bodies")

  # The (id, version) pairing matters, not just the multiset of strings.
  clear_adapters()
  register_adapter(fp_adapter("alpha", function(fm) "no", version = "2.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "1.0"))
  ab1 <- registry_fingerprint()
  clear_adapters()
  register_adapter(fp_adapter("alpha", function(fm) "no", version = "1.0"))
  register_adapter(fp_adapter("beta", function(fm) "no", version = "2.0"))
  expect_false(identical(registry_fingerprint(), ab1),
               info = "R-3.8: swapping versions between ids must change the fingerprint")
})

# --- 2. unclaimed stores the fingerprint; unchanged registry skips it ----------

test_that("R-3.8: an unclaimed file stores the current fingerprint, and a re-run under an unchanged registry does not re-decide it", {
  fp_local_registry()
  calls <- new_counter()
  register_adapter(fp_adapter("picky", function(fm) "no", counter = calls))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_NOBODY_0.fpt", content = "nothing claims this")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "quarantined")
  expect_equal(first$reason[[1]], "unclaimed")

  stored <- fp_stored(db$con, hash)
  expect_identical(stored$registry_fingerprint[[1]], registry_fingerprint(),
                   info = "R-3.8: an unclaimed verdict must record the registry it was decided against")

  calls$n <- 0L
  second <- route_files(c(path), db$con)
  expect_equal(second$state[[1]], "quarantined")
  expect_equal(second$reason[[1]], "unclaimed")
  expect_identical(calls$n, 0L,
                   info = "R-3.8: an unchanged registry must not re-run match() on a stored verdict")
  expect_identical(fp_stored(db$con, hash)$registry_fingerprint[[1]], registry_fingerprint())
})

# --- 3. a new claimant re-decides automatically -------------------------------

test_that("R-3.8: after a new adapter that claims the file is registered, a plain re-route (reconsider = FALSE) re-decides and claims it", {
  fp_local_registry()
  register_adapter(fp_adapter("picky", function(fm) "no"))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_LATE_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$reason[[1]], "unclaimed")

  register_adapter(fp_adapter("late", function(fm) if (fm$ext == "fpt") "format" else "no"))

  redone <- route_files(c(path), db$con)
  expect_equal(redone$state[[1]], "claimed")
  expect_equal(redone$adapter[[1]], "late")

  stored <- fp_stored(db$con, hash)
  expect_identical(stored$state[[1]], "claimed",
                   info = "R-3.8: the re-decision must be PERSISTED, not merely returned")
  expect_identical(stored$adapter[[1]], "late")
})

test_that("R-3.8: ingest_dir() with no reconsider flag picks up an unclaimed file once a claimant lands, and parses it", {
  clear_adapters()
  register_builtin_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })

  db_dir <- withr::local_tempdir()
  db_path <- seed_db(db_dir)
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(),
    "sampletidy.snapshot_dir" = withr::local_tempdir(),
    "sampletidy.remove_ingested" = FALSE
  ))

  input <- withr::local_tempdir()
  path <- st_test_write_file(input, "FP_INGEST_0.fpt", content = "late adapter food\n")
  hash <- sampleTidy:::file_meta(path)$hash

  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  con <- seed_con(db_path)
  first <- fp_stored(con, hash)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_identical(first$state[[1]], "quarantined")
  expect_identical(first$state_reason[[1]], "unclaimed")

  parsed <- new_counter()
  late <- fp_adapter("late_fpt", function(fm) if (fm$ext == "fpt") "exact" else "no")
  late$parse <- function(path, file_meta) {
    parsed$n <- parsed$n + 1L
    list(results = ir_results(), samples = ir_samples(), report = list())
  }
  register_adapter(late)

  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  con <- seed_con(db_path)
  after <- fp_stored(con, hash)
  DBI::dbDisconnect(con, shutdown = TRUE)

  expect_identical(after$adapter[[1]], "late_fpt",
                   info = "R-3.8: the new adapter must have claimed the file without reconsider = TRUE")
  expect_false(after$state[[1]] %in% c("quarantined", "seen", "claimed"),
               info = "R-3.8: the claimed file must be carried on through the pipeline, not left at the router")
  expect_identical(parsed$n, 1L,
                   info = "R-3.8: the new adapter's parse() must run on the re-decided file")
})

# --- 4. router-failed: re-decided on a version bump, not otherwise -------------

test_that("R-3.8: a router-failed file (match() threw) is NOT re-decided under an unchanged registry, and IS once the adapter bumps its version", {
  fp_local_registry()

  throws <- TRUE
  calls <- new_counter()
  flaky_match <- function(fm) {
    if (!grepl("FLAKY", fm$filename)) return("no")
    if (throws) stop("buggy match() we later fixed")
    "format"
  }
  register_adapter(fp_adapter("flaky", flaky_match, version = "1.0", counter = calls))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_FLAKY_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "failed")
  expect_identical(fp_stored(db$con, hash)$registry_fingerprint[[1]], registry_fingerprint(),
                   info = "R-3.8: a router-written failed verdict must record the registry fingerprint")

  # The bug is fixed in place but the version is NOT bumped: the registry
  # fingerprint is unchanged, so the verdict stands.
  throws <- FALSE
  calls$n <- 0L
  control <- route_files(c(path), db$con)
  expect_equal(control$state[[1]], "failed",
               info = "R-3.8: an unchanged fingerprint must leave a router-failed verdict alone")
  expect_identical(calls$n, 0L)

  # Ship the fix properly: same id, bumped version.
  register_adapter(fp_adapter("flaky", flaky_match, version = "1.1", counter = calls), quiet = TRUE)
  redone <- route_files(c(path), db$con)
  expect_equal(redone$state[[1]], "claimed")
  expect_equal(redone$adapter[[1]], "flaky")
  expect_identical(fp_stored(db$con, hash)$state[[1]], "claimed")
})

test_that("R-3.8: a router-failed file from a bad tier value is re-decided after a version bump", {
  fp_local_registry()
  bad <- TRUE
  weird_match <- function(fm) if (bad) "weird" else "exact"
  register_adapter(fp_adapter("weird", weird_match, version = "1.0"))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_WEIRD_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "failed")

  bad <- FALSE
  register_adapter(fp_adapter("weird", weird_match, version = "1.1"), quiet = TRUE)
  redone <- route_files(c(path), db$con)
  expect_equal(redone$state[[1]], "claimed")
  expect_identical(fp_stored(db$con, hash)$state[[1]], "claimed")
})

# --- 5. still-unclaimed under a changed registry ------------------------------

test_that("R-3.8: a file still unclaimed under a changed registry is re-decided, stays unclaimed, takes the NEW fingerprint, and has no other side effect", {
  fp_local_registry()
  calls <- new_counter()
  register_adapter(fp_adapter("picky", function(fm) "no", counter = calls))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "ES2617126_FP_0_COA.fpt", content = "%PDF-1.4 nothing claims this")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  old_fp <- fp_stored(db$con, hash)$registry_fingerprint[[1]]

  before <- c(
    review_queue = fp_count(db$con, "review_queue"),
    change_log = fp_count(db$con, "change_log"),
    ingest_sighting = fp_count(db$con, "ingest_sighting"),
    ingest_file = fp_count(db$con, "ingest_file")
  )

  # An unrelated adapter lands; it does not claim this file either.
  register_adapter(fp_adapter("also_picky", function(fm) "no"))
  new_fp <- registry_fingerprint()
  expect_false(identical(new_fp, old_fp))

  calls$n <- 0L
  redone <- route_files(c(path), db$con)
  expect_gt(calls$n, 0L, label = "match() calls on the re-decision pass")
  expect_equal(redone$state[[1]], "quarantined")
  expect_equal(redone$reason[[1]], "unclaimed")

  stored <- fp_stored(db$con, hash)
  expect_identical(stored$state[[1]], "quarantined",
                   info = "R-3.8: the re-decided row must be terminal again, never stranded at `seen`")
  expect_identical(stored$state_reason[[1]], "unclaimed")
  expect_identical(stored$registry_fingerprint[[1]], new_fp,
                   info = "R-3.8: a re-decided verdict must take the NEW fingerprint, or it is re-decided on every run")

  after <- c(
    review_queue = fp_count(db$con, "review_queue"),
    change_log = fp_count(db$con, "change_log"),
    ingest_sighting = fp_count(db$con, "ingest_sighting"),
    ingest_file = fp_count(db$con, "ingest_file")
  )
  expect_identical(after, before,
                   info = "R-3.8: re-deciding an unclaimed file must open no review item, log no change, add no row")

  # And having taken the new fingerprint, the NEXT run skips it.
  calls$n <- 0L
  route_files(c(path), db$con)
  expect_identical(calls$n, 0L,
                   info = "R-3.8: once re-stamped, the verdict must not be re-decided again")
})

test_that("R-3.8: a still-tied file under a changed registry is re-decided, takes the new fingerprint, and opens no SECOND review_queue item", {
  fp_local_registry()
  register_adapter(fp_adapter("tie_x", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))
  register_adapter(fp_adapter("tie_y", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "ES1234567_FP_TIED_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$reason[[1]], "adapter_tie")
  expect_identical(fp_stored(db$con, hash)$registry_fingerprint[[1]], registry_fingerprint(),
                   info = "R-3.8: an adapter_tie verdict must record the registry fingerprint")
  expect_equal(fp_count(db$con, "review_queue"), 1)

  register_adapter(fp_adapter("bystander", function(fm) "no"))
  still <- route_files(c(path), db$con)
  expect_equal(still$reason[[1]], "adapter_tie")
  expect_identical(fp_stored(db$con, hash)$registry_fingerprint[[1]], registry_fingerprint())
  expect_equal(
    nrow(DBI::dbGetQuery(con = db$con, "SELECT 1 FROM review_queue WHERE kind = 'adapter_tie'")), 1,
    info = "R-3.8: an automatic re-decision of a still-tied file must not open a second review item"
  )

  # Resolve the tie by REMOVING an adapter (a registry change): it now claims.
  clear_adapters()
  register_adapter(fp_adapter("tie_x", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))
  resolved <- route_files(c(path), db$con)
  expect_equal(resolved$state[[1]], "claimed")
  expect_equal(resolved$adapter[[1]], "tie_x")
})

# --- 6. facts about the file are never re-decided -------------------------------

# Drive a file to each never-reconsider state via the transitions production
# itself uses: `ignored` by ignore_rule(); `archived` by reset (as R-3.7's own
# test does); parse-`failed` as `.ig_parse_claimed()` writes it (claimed ->
# failed, adapter set); commit-`failed` as `.ig_reconcile_and_commit()` writes
# it (claimed -> parsed -> assembled -> failed).
fp_drive_fact_states <- function(con, dir) {
  bak <- st_test_write_file(dir, "fp_old_export.bak", content = "x")
  arch <- st_test_write_file(dir, "FP_ARCH_0.fpt", content = "archived bytes")
  pfail <- st_test_write_file(dir, "FP_PARSEFAIL_0.fpt", content = "parse failed bytes")
  cfail <- st_test_write_file(dir, "FP_COMMITFAIL_0.fpt", content = "commit failed bytes")
  paths <- c(bak = bak, arch = arch, pfail = pfail, cfail = cfail)

  routed <- route_files(unname(paths), con)
  h <- stats::setNames(routed$hash, names(paths))

  ingest_file_set_state(con, h[["arch"]], "archived", reset = TRUE)
  ingest_file_set_state(con, h[["pfail"]], "failed", "parse() threw: malformed sheet")
  ingest_file_set_state(con, h[["cfail"]], "parsed")
  ingest_file_set_state(con, h[["cfail"]], "assembled")
  ingest_file_set_state(con, h[["cfail"]], "failed", "commit step threw: constraint")
  list(paths = paths, hash = h)
}

fp_assert_facts_unmoved <- function(con, h, calls, info) {
  expect_identical(fp_stored(con, h[["bak"]])$state[[1]], "ignored", info = info)
  expect_identical(fp_stored(con, h[["arch"]])$state[[1]], "archived", info = info)
  pf <- fp_stored(con, h[["pfail"]])
  expect_identical(pf$state[[1]], "failed", info = info)
  expect_identical(pf$state_reason[[1]], "parse() threw: malformed sheet", info = info)
  cf <- fp_stored(con, h[["cfail"]])
  expect_identical(cf$state[[1]], "failed", info = info)
  expect_identical(cf$state_reason[[1]], "commit step threw: constraint", info = info)
  expect_identical(calls$n, 0L, info = paste(info, "- match() must not even be consulted"))
}

test_that("R-3.8: archived, ignored, and parse-/commit-written failed rows are NEVER re-decided by a fingerprint change", {
  fp_local_registry()
  calls <- new_counter()
  # A claimant for every file, so a wrong re-decision would visibly move them.
  register_adapter(fp_adapter("greedy", function(fm) "format", counter = calls))
  db <- fp_local_db()

  fx <- fp_drive_fact_states(db$con, db$dir)

  # Change the registry, then route everything again.
  register_adapter(fp_adapter("newcomer", function(fm) "no", counter = calls))
  calls$n <- 0L
  redone <- route_files(unname(fx$paths), db$con)

  fp_assert_facts_unmoved(db$con, fx$hash, calls, "R-3.8: fingerprint change")
  expect_identical(redone$state[match(fx$hash[["arch"]], redone$hash)], "archived")
})

test_that("R-3.8: a NULL (legacy) fingerprint does not make archived, ignored, or parse-/commit-failed rows re-decidable", {
  fp_local_registry()
  calls <- new_counter()
  register_adapter(fp_adapter("greedy", function(fm) "format", counter = calls))
  db <- fp_local_db()

  fx <- fp_drive_fact_states(db$con, db$dir)
  DBI::dbExecute(db$con, "UPDATE ingest_file SET registry_fingerprint = NULL")

  calls$n <- 0L
  route_files(unname(fx$paths), db$con)
  fp_assert_facts_unmoved(db$con, fx$hash, calls, "R-3.8: legacy NULL fingerprint")
})

test_that("R-3.8: reconsider = TRUE keeps today's escape hatch - parse-/commit-failed rows ARE re-decided - while archived and ignored never are", {
  # Amended ruling (2026-10-17): the fingerprint never touches parse-/commit-
  # written `failed`, but an explicit `reconsider = TRUE` still re-routes ANY
  # `failed` row, as R-3.7 does today. It is the only way to retry a file whose
  # parse() failed on a since-fixed parser bug. `archived`/`ignored` stay
  # never-re-decided at every setting.
  fp_local_registry()
  calls <- new_counter()
  register_adapter(fp_adapter("greedy", function(fm) "format", counter = calls))
  db <- fp_local_db()

  fx <- fp_drive_fact_states(db$con, db$dir)
  register_adapter(fp_adapter("newcomer", function(fm) "no", counter = calls))

  redone <- route_files(unname(fx$paths), db$con, reconsider = TRUE)

  expect_identical(fp_stored(db$con, fx$hash[["bak"]])$state[[1]], "ignored",
                   info = "R-3.8: ignored is never re-decided, even under reconsider = TRUE")
  expect_identical(fp_stored(db$con, fx$hash[["arch"]])$state[[1]], "archived",
                   info = "R-3.8: archived is never re-decided, even under reconsider = TRUE")
  for (k in c("pfail", "cfail")) {
    st <- fp_stored(db$con, fx$hash[[k]])
    expect_identical(st$state[[1]], "claimed",
                     info = sprintf("R-3.8: reconsider = TRUE must still re-route a %s row", k))
    expect_identical(st$adapter[[1]], "greedy")
    expect_identical(redone$state[match(fx$hash[[k]], redone$hash)], "claimed")
  }
})

# --- 7. dry run persists nothing -----------------------------------------------

test_that("R-3.8: a dry run under a changed registry previews the new verdict but persists neither it nor the new fingerprint", {
  fp_local_registry()
  register_adapter(fp_adapter("picky", function(fm) "no"))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_DRY_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  old_fp <- fp_stored(db$con, hash)$registry_fingerprint[[1]]
  expect_true(checkmate::test_string(old_fp, min.chars = 1))

  register_adapter(fp_adapter("late", function(fm) if (fm$ext == "fpt") "format" else "no"))
  rq_before <- fp_count(db$con, "review_queue")

  preview <- route_files(c(path), db$con, dry_run = TRUE)
  expect_equal(preview$state[[1]], "claimed",
               info = "R-3.8: a preview reports what a real run would conclude")

  stored <- fp_stored(db$con, hash)
  expect_identical(stored$state[[1]], "quarantined",
                   info = "R-3.8/F12: a dry run must not persist the re-decided verdict")
  expect_identical(stored$state_reason[[1]], "unclaimed")
  expect_identical(stored$registry_fingerprint[[1]], old_fp,
                   info = "R-3.8/F12: a dry run must not re-stamp the fingerprint, or the next real run would skip the file")
  expect_identical(fp_count(db$con, "review_queue"), rq_before)

  # The next REAL run still sees the stale fingerprint and claims the file.
  real <- route_files(c(path), db$con)
  expect_equal(real$state[[1]], "claimed")
  expect_identical(fp_stored(db$con, hash)$state[[1]], "claimed")
})

test_that("R-3.8: a dry run over a NEW file persists no verdict and no fingerprint", {
  fp_local_registry()
  register_adapter(fp_adapter("picky", function(fm) "no"))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_DRYNEW_0.fpt", content = "fresh bytes")
  preview <- route_files(c(path), db$con, dry_run = TRUE)
  expect_equal(preview$reason[[1]], "unclaimed")

  stored <- fp_stored(db$con, preview$hash[[1]])
  expect_identical(stored$state[[1]], "seen")
  expect_true(is.na(stored$registry_fingerprint[[1]]),
              info = "R-3.8/F12: a dry run must not stamp a fingerprint on a row it left at `seen`")
})

# --- 8. legacy NULL fingerprints are stale --------------------------------------

test_that("R-3.8: a legacy registry verdict with a NULL fingerprint is treated as stale and re-decided exactly once", {
  fp_local_registry()
  calls <- new_counter()
  register_adapter(fp_adapter("picky", function(fm) "no", counter = calls))
  db <- fp_local_db()

  unc <- st_test_write_file(db$dir, "FP_LEGACY_UNC_0.fpt", content = "legacy unclaimed")
  claimable <- st_test_write_file(db$dir, "FP_LEGACY_LATE_0.fpt", content = "legacy, now claimable")
  first <- route_files(c(unc, claimable), db$con)
  h_unc <- first$hash[first$path == unc][[1]]
  h_late <- first$hash[first$path == claimable][[1]]
  expect_true(all(first$reason == "unclaimed"))

  # Simulate rows written before the column existed (the 19 live rows).
  DBI::dbExecute(db$con, "UPDATE ingest_file SET registry_fingerprint = NULL")

  # Note: the registry is UNCHANGED from the run that wrote these rows. A NULL
  # fingerprint must count as stale on its own.
  calls$n <- 0L
  route_files(c(unc), db$con)
  expect_gt(calls$n, 0L, label = "match() calls when re-deciding a NULL-fingerprint row")
  stored <- fp_stored(db$con, h_unc)
  expect_identical(stored$state[[1]], "quarantined")
  expect_identical(stored$state_reason[[1]], "unclaimed")
  expect_identical(stored$registry_fingerprint[[1]], registry_fingerprint(),
                   info = "R-3.8: re-deciding a legacy row must stamp the current fingerprint")

  # Exactly once: the next run skips it.
  calls$n <- 0L
  route_files(c(unc), db$con)
  expect_identical(calls$n, 0L, info = "R-3.8: a legacy row is re-decided once, not on every run")

  # And the payoff case: a legacy unclaimed row that a now-registered adapter
  # claims is picked up with no reconsider flag. The claimant is registered
  # by toggling the existing adapter's behaviour WITHOUT a version bump, so the
  # NULL fingerprint - not a registry change - is the only reason to re-decide.
  clear_adapters()
  register_adapter(fp_adapter(
    "picky", function(fm) if (grepl("LEGACY_LATE", fm$filename)) "exact" else "no"
  ))
  DBI::dbExecute(db$con, "UPDATE ingest_file SET registry_fingerprint = NULL WHERE hash = ?",
                 params = list(h_late))
  redone <- route_files(c(claimable), db$con)
  expect_equal(redone$state[[1]], "claimed")
  expect_identical(fp_stored(db$con, h_late)$adapter[[1]], "picky")
})

test_that("R-3.8: a legacy router-failed row (NULL fingerprint, no adapter) is re-decided", {
  fp_local_registry()
  throws <- TRUE
  register_adapter(fp_adapter("flaky", function(fm) {
    if (throws) stop("old bug")
    "format"
  }))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_LEGACY_FAIL_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "failed")
  DBI::dbExecute(db$con, "UPDATE ingest_file SET registry_fingerprint = NULL")

  throws <- FALSE
  redone <- route_files(c(path), db$con)
  expect_equal(redone$state[[1]], "claimed")
  expect_identical(fp_stored(db$con, hash)$state[[1]], "claimed")
})

# --- 9. reconsider = TRUE still forces ------------------------------------------

test_that("R-3.8: reconsider = TRUE still forces re-decision of a registry verdict whose fingerprint matches", {
  fp_local_registry()
  wants <- FALSE
  calls <- new_counter()
  register_adapter(fp_adapter(
    "shy", function(fm) if (wants) "format" else "no", counter = calls
  ))
  db <- fp_local_db()

  path <- st_test_write_file(db$dir, "FP_FORCE_0.fpt", content = "a,b\n1,2\n")
  first <- route_files(c(path), db$con)
  hash <- first$hash[[1]]
  expect_equal(first$reason[[1]], "unclaimed")
  fp <- registry_fingerprint()
  expect_identical(fp_stored(db$con, hash)$registry_fingerprint[[1]], fp)

  # Behaviour changes, registry fingerprint does not.
  wants <- TRUE
  expect_identical(registry_fingerprint(), fp)

  calls$n <- 0L
  control <- route_files(c(path), db$con)
  expect_equal(control$state[[1]], "quarantined",
               info = "R-3.8 control: matching fingerprint, no flag -> skipped")
  expect_identical(calls$n, 0L)

  forced <- route_files(c(path), db$con, reconsider = TRUE)
  expect_equal(forced$state[[1]], "claimed")
  expect_identical(fp_stored(db$con, hash)$state[[1]], "claimed")
})
