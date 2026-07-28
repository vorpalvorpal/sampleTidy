# Plan 03 - R-3.4 ignore_rule(file_meta), R-3.5 route_files(paths, con),
# R-3.6 router_matrix(paths).
#
# NOTE: route_files()'s exact signature beyond `paths` is not pinned in
# PLAN-03 (CONTRACT's bare-call example shows only `route_files(paths)`, but
# R-3.5 says it "persists to ingest_file via plan-01 helpers", which require
# a connection). We assume `route_files(paths, con)`. See
# dev/plans/PLAN-CHANGE-REQUESTS.md.

# --- R-3.4 ignore rules ----------------------------------------------------

test_that("R-3.4: files with ext bak/tmp are ignored", {
  dir <- withr::local_tempdir()
  bak <- file_meta(st_test_write_file(dir, "old_export.bak", content = "x"))
  tmp <- file_meta(st_test_write_file(dir, "scratch.tmp", content = "x"))
  expect_false(is.na(ignore_rule(bak)))
  expect_false(is.na(ignore_rule(tmp)))
})

test_that("R-3.4: .DS_Store is ignored", {
  dir <- withr::local_tempdir()
  ds <- file_meta(st_test_write_file(dir, ".DS_Store", content = "x"))
  expect_false(is.na(ignore_rule(ds)))
})

test_that("R-3.4: a '[N]' duplicate-download marker filename is NOT ignored (content-hash dedup handles those)", {
  dir <- withr::local_tempdir()
  dup <- file_meta(st_test_write_file(dir, "ES2609437_0_Sample2e[94].CSV", content = "a,b\n1,2\n"))
  expect_true(is.na(ignore_rule(dup)))
})

test_that("R-3.4: a zero-byte file is ignored with reason 'empty_file'", {
  dir <- withr::local_tempdir()
  empty <- file_meta(st_test_write_file(dir, "empty.csv", content = character(0)))
  expect_equal(file.size(empty$path), 0)
  expect_equal(ignore_rule(empty), "empty_file")
})

test_that("R-3.4: a normal nonzero-byte file with an unmatched extension is not ignored", {
  dir <- withr::local_tempdir()
  normal <- file_meta(st_test_write_file(dir, "ES2600194_0_XTAB.csv", content = "a,b\n1,2\n"))
  expect_true(is.na(ignore_rule(normal)))
})

# --- R-3.5 route_files() ----------------------------------------------------

make_matcher_adapter <- function(id, tier_for) {
  list(
    id = id,
    version = "1.0",
    match = tier_for,
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  )
}

test_that("R-3.5: exactly one adapter at the winning tier claims the file", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("exact_adapter", function(fm) if (grepl("TARGET", fm$filename)) "exact" else "no"))
  register_adapter(make_matcher_adapter("format_adapter", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "TARGET_0_XTAB.csv", content = "a,b\n1,2\n")
  result <- route_files(c(path), con)

  expect_equal(result$state[[1]], "claimed")
  expect_equal(result$adapter[[1]], "exact_adapter")
  expect_equal(result$tier[[1]], "exact")
})

test_that("R-3.5: a tie at the winning tier quarantines with reason adapter_tie and both ids in the review_queue payload", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("tie_a", function(fm) if (grepl("TIEFILE", fm$filename)) "exact" else "no"))
  register_adapter(make_matcher_adapter("tie_b", function(fm) if (grepl("TIEFILE", fm$filename)) "exact" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  # ES1234567 matches .st_work_order_re ("[A-Z]{2}\\d{7}") so fm$work_order_guess
  # is non-NA, giving us something concrete to assert on the typed work_order column.
  path <- st_test_write_file(dir, "ES1234567_TIEFILE_0_XTAB.csv", content = "a,b\n1,2\n")
  result <- route_files(c(path), con)

  expect_equal(result$state[[1]], "quarantined")
  expect_equal(result$reason[[1]], "adapter_tie")

  queue <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'adapter_tie'")
  expect_equal(nrow(queue), 1)

  # Typed columns.
  expect_identical(queue$kind[[1]], "adapter_tie")
  expect_true(is.na(queue$subkind[[1]]))
  expect_identical(queue$work_order[[1]], "ES1234567")
  expect_identical(queue$source_hash[[1]], result$hash[[1]])

  # Raw stored payload TEXT (not run through the JSON parser) - so a
  # serialisation-shape regression (e.g. the pipe-joined k=v grammar PLAN-16
  # deletes, or a dropped `tier` diagnostic) cannot hide behind fromJSON()'s
  # own normalisation.
  expect_identical(
    queue$payload[[1]],
    '{"tier":"exact","adapters":["tie_a","tie_b"]}'
  )

  # Parsed JSON diagnostics: `tier` is a scalar and unboxes; `adapters` is a
  # semantically-plural key and must always serialise as a JSON array
  # (policy landing in R/db-schema.R during this same round - asserted here
  # as the array shape per that policy, not as whatever happens to come back).
  d <- jsonlite::fromJSON(queue$payload[[1]])
  expect_identical(d$tier, "exact")
  expect_length(d$adapters, 2L)
  expect_identical(sort(d$adapters), c("tie_a", "tie_b"))
})

test_that("R-3.5: a file no adapter claims quarantines with reason unclaimed", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("picky", function(fm) "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "NOBODY_WANTS_THIS.xyz", content = "irrelevant")
  result <- route_files(c(path), con)

  expect_equal(result$state[[1]], "quarantined")
  expect_equal(result$reason[[1]], "unclaimed")
})

test_that("R-3.5: re-routing the same path is a no-op (state unchanged, no new sighting)", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("claimer", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "SAME_PATH_0.csv", content = "a,b\n1,2\n")
  first <- route_files(c(path), con)
  second <- route_files(c(path), con)

  expect_equal(second$state[[1]], first$state[[1]])
  expect_equal(second$adapter[[1]], first$adapter[[1]])

  sightings <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?",
    params = list(first$hash[[1]])
  )$n
  expect_equal(sightings, 0)
})

test_that("R-3.5: a different path with an identical file (same hash) records a sighting and does not re-claim", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("claimer2", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path1 <- st_test_write_file(dir, "first_name.csv", content = "identical,content\n1,2\n")
  path2 <- st_test_write_file(dir, "second_name.csv", content = "identical,content\n1,2\n")

  first <- route_files(c(path1), con)
  second <- route_files(c(path2), con)

  expect_equal(first$hash[[1]], second$hash[[1]])
  expect_equal(second$adapter[[1]], first$adapter[[1]])
  expect_equal(second$state[[1]], first$state[[1]])

  sightings <- DBI::dbGetQuery(
    con, "SELECT COUNT(*) AS n FROM ingest_sighting WHERE hash = ?",
    params = list(first$hash[[1]])
  )$n
  expect_equal(sightings, 1)
})

test_that("R-3.5: match() throwing inside an adapter marks only that file failed and continues with remaining files", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("thrower", function(fm) {
    if (grepl("THROWS", fm$filename)) stop("kaboom from match()") else "no"
  }))
  register_adapter(make_matcher_adapter("normal_one", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path_throws <- st_test_write_file(dir, "THROWS_0.csv", content = "a,b\n1,2\n")
  path_normal <- st_test_write_file(dir, "FINE_0.csv", content = "c,d\n3,4\n")

  result <- route_files(c(path_throws, path_normal), con)

  throw_row <- result[result$path == path_throws, ]
  normal_row <- result[result$path == path_normal, ]

  expect_equal(throw_row$state[[1]], "failed")
  expect_match(throw_row$reason[[1]], "kaboom from match()", fixed = TRUE)
  expect_equal(normal_row$state[[1]], "claimed")
})

# --- R-3.6 router_matrix() smoke test ---------------------------------------

test_that("R-3.6: router_matrix() returns (path, adapter, tier) for every adapter x path, with no state changes", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("m1", function(fm) if (grepl("A", fm$filename)) "exact" else "no"))
  register_adapter(make_matcher_adapter("m2", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  path_a <- st_test_write_file(dir, "A_file.csv", content = "1")
  path_b <- st_test_write_file(dir, "B_file.csv", content = "2")

  matrix <- router_matrix(c(path_a, path_b))

  expect_equal(nrow(matrix), 4)
  expect_setequal(names(matrix), c("path", "adapter", "tier"))

  tier_of <- function(p, a) matrix$tier[matrix$path == p & matrix$adapter == a]
  expect_equal(tier_of(path_a, "m1"), "exact")
  expect_equal(tier_of(path_a, "m2"), "format")
  expect_equal(tier_of(path_b, "m1"), "no")
  expect_equal(tier_of(path_b, "m2"), "format")
})

# --- R-12.1 match() return-value validation (F6, contained registry lookup) --

test_that("R-12.1: an adapter match() returning NA fails only that file (reason names the adapter); other files route normally", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("na_adapter", function(fm) if (grepl("BADNA", fm$filename)) NA_character_ else "no"))
  register_adapter(make_matcher_adapter("normal_adapter", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path_bad <- st_test_write_file(dir, "BADNA_0.csv", content = "a,b\n1,2\n")
  path_ok <- st_test_write_file(dir, "FINE_0.csv", content = "c,d\n3,4\n")

  result <- route_files(c(path_bad, path_ok), con)

  bad_row <- result[result$path == path_bad, ]
  ok_row <- result[result$path == path_ok, ]

  expect_equal(bad_row$state[[1]], "failed")
  expect_match(bad_row$reason[[1]], "na_adapter", fixed = TRUE)
  expect_equal(ok_row$state[[1]], "claimed")
  expect_equal(ok_row$adapter[[1]], "normal_adapter")
})

test_that("R-12.1: an adapter match() returning a value outside the tier vocabulary ('weird') fails only that file (reason names the adapter and the bad value); other files route normally", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("weird_adapter", function(fm) if (grepl("BADWEIRD", fm$filename)) "weird" else "no"))
  register_adapter(make_matcher_adapter("normal_adapter2", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path_bad <- st_test_write_file(dir, "BADWEIRD_0.csv", content = "a,b\n1,2\n")
  path_ok <- st_test_write_file(dir, "FINE2_0.csv", content = "c,d\n3,4\n")

  result <- route_files(c(path_bad, path_ok), con)

  bad_row <- result[result$path == path_bad, ]
  ok_row <- result[result$path == path_ok, ]

  expect_equal(bad_row$state[[1]], "failed")
  expect_match(bad_row$reason[[1]], "weird_adapter", fixed = TRUE)
  expect_match(bad_row$reason[[1]], "weird", fixed = TRUE)
  expect_equal(ok_row$state[[1]], "claimed")
})

test_that("R-12.1 regression: an adapter match() that throws still fails only that file, unchanged by the return-value validation fix", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("thrower2", function(fm) {
    if (grepl("THROWS2", fm$filename)) stop("kaboom2 from match()") else "no"
  }))
  register_adapter(make_matcher_adapter("normal3", function(fm) if (fm$ext == "csv") "format" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path_throws <- st_test_write_file(dir, "THROWS2_0.csv", content = "a,b\n1,2\n")
  path_ok <- st_test_write_file(dir, "FINE3_0.csv", content = "c,d\n3,4\n")

  result <- route_files(c(path_throws, path_ok), con)

  throw_row <- result[result$path == path_throws, ]
  ok_row <- result[result$path == path_ok, ]

  expect_equal(throw_row$state[[1]], "failed")
  expect_match(throw_row$reason[[1]], "kaboom2 from match()", fixed = TRUE)
  expect_equal(ok_row$state[[1]], "claimed")
})

# --- R-3.7 reconsider: registry verdicts are not durable facts --------------
#
# `already_routed` short-circuits on ANY non-`seen` state, and unclaimed /
# adapter_tie / router-failed are terminal under R-1.6, so an adapter-registry
# verdict is permanent. It should not be: R/adapter-crosstab.R:104 records that
# real ALS `.XLS` is SpreadsheetML which readxl cannot open ("parked
# post-MVP"), and eight XTAB.XLS files sit `unclaimed` in the live DB behind
# exactly that. Unpark it, re-run, and nothing happens.
#
# Every arm below pairs the reconsider = TRUE assertion with a reconsider =
# FALSE control on the SAME setup. Without the control a test that "passes"
# proves nothing about reconsider: the file could be getting claimed for some
# unrelated reason (a stale registry, a hash collision, an ordering fluke), and
# a negative result could just mean the fixture never reached the branch.

# A file's stored state/reason/adapter, read back from ingest_file rather than
# from route_files()'s return value - the RETURN can report a verdict the DB
# does not hold (that is precisely the dry_run contract), so an assertion that
# only reads the return cannot distinguish "decided" from "persisted".
stored_route <- function(con, hash) {
  DBI::dbGetQuery(
    con,
    "SELECT state, state_reason, adapter FROM ingest_file WHERE hash = ?",
    params = list(hash)
  )
}

test_that("R-3.7: an unclaimed file is re-decided under reconsider = TRUE once an adapter claims it, and is NOT re-decided under reconsider = FALSE", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "ES2617126_0_XTAB.csv", content = "a,b\n1,2\n")

  # Round 1: no adapter claims it at all -> quarantined/unclaimed.
  first <- route_files(c(path), con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "quarantined")
  expect_equal(first$reason[[1]], "unclaimed")
  expect_identical(stored_route(con, hash)$state[[1]], "quarantined")

  # The registry changes - the file did not. This is the SpreadsheetML case.
  register_adapter(make_matcher_adapter(
    "late_adapter", function(fm) if (fm$ext == "csv") "format" else "no"
  ))

  # CONTROL, and it must run BEFORE the reconsider call: with the new adapter
  # registered, a default re-route still returns the stale verdict. If this
  # arm ever goes green as "claimed", the test below proves nothing - the file
  # would be getting claimed with or without reconsider.
  control <- route_files(c(path), con)
  expect_equal(control$state[[1]], "quarantined",
               info = "R-3.7 control: reconsider defaults FALSE, so the stale verdict must survive a plain re-route")
  expect_identical(stored_route(con, hash)$state[[1]], "quarantined")

  # The behaviour under test.
  redone <- route_files(c(path), con, reconsider = TRUE)
  expect_equal(redone$state[[1]], "claimed")
  expect_equal(redone$adapter[[1]], "late_adapter")

  persisted <- stored_route(con, hash)
  expect_identical(persisted$state[[1]], "claimed",
                   info = "R-3.7: the new verdict must be PERSISTED, not merely returned")
  expect_identical(persisted$adapter[[1]], "late_adapter")
})

test_that("R-3.7: a router-failed file whose match() no longer throws is re-decided under reconsider = TRUE", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })

  # A registry whose one adapter throws on the first pass and behaves on the
  # second, mimicking "we shipped a buggy match() and then fixed it". The flag
  # lives outside the closure so flipping it does not re-register anything -
  # the ADAPTER SET is identical across both passes, which is what isolates
  # `reconsider` as the only variable.
  throws <- TRUE
  register_adapter(make_matcher_adapter("flaky", function(fm) {
    if (!grepl("FLAKY", fm$filename)) return("no")
    if (throws) stop("buggy match() we later fixed")
    "format"
  }))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "FLAKY_0.csv", content = "a,b\n1,2\n")

  first <- route_files(c(path), con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "failed")
  expect_match(first$reason[[1]], "buggy match()", fixed = TRUE)

  throws <- FALSE

  control <- route_files(c(path), con)
  expect_equal(control$state[[1]], "failed",
               info = "R-3.7 control: a fixed adapter alone must not un-fail the file")

  redone <- route_files(c(path), con, reconsider = TRUE)
  expect_equal(redone$state[[1]], "claimed")
  expect_identical(stored_route(con, hash)$state[[1]], "claimed")
})

test_that("R-3.7: an adapter_tie file is re-decided under reconsider = TRUE, and a still-tied re-pass opens no SECOND review_queue item", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  register_adapter(make_matcher_adapter("tie_x", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))
  register_adapter(make_matcher_adapter("tie_y", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "ES1234567_TIED_0.csv", content = "a,b\n1,2\n")

  first <- route_files(c(path), con)
  hash <- first$hash[[1]]
  expect_equal(first$reason[[1]], "adapter_tie")
  expect_equal(nrow(DBI::dbGetQuery(con, "SELECT 1 FROM review_queue WHERE kind = 'adapter_tie'")), 1)

  # Reconsider while the tie is STILL live. The verdict is correctly the same,
  # but the review item must not be duplicated - a reconsider pass that opens
  # a fresh item every time turns an operator's queue into noise, and this is
  # the arm a naive "reset to seen and re-run" implementation fails.
  still_tied <- route_files(c(path), con, reconsider = TRUE)
  expect_equal(still_tied$reason[[1]], "adapter_tie")
  expect_equal(
    nrow(DBI::dbGetQuery(con, "SELECT 1 FROM review_queue WHERE kind = 'adapter_tie'")), 1,
    info = "R-3.7: re-passing a still-tied file must not open a second review_queue item"
  )

  # Resolve the tie, then reconsider: now it claims.
  clear_adapters()
  register_adapter(make_matcher_adapter("tie_x", function(fm) if (grepl("TIED", fm$filename)) "exact" else "no"))
  resolved <- route_files(c(path), con, reconsider = TRUE)
  expect_equal(resolved$state[[1]], "claimed")
  expect_equal(resolved$adapter[[1]], "tie_x")
  expect_identical(stored_route(con, hash)$state[[1]], "claimed")
})

test_that("R-3.7: `ignored` and `archived` are NEVER reconsidered - they are facts about the file, not about the registry", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })
  # An adapter that would happily claim BOTH files if it were ever consulted.
  # That is the whole point: the guard must hold even when a claimant exists.
  register_adapter(make_matcher_adapter("greedy", function(fm) "format"))

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  bak <- st_test_write_file(dir, "old_export.bak", content = "x")
  arch <- st_test_write_file(dir, "ES2617126_0_XTAB.csv", content = "a,b\n1,2\n")

  first <- route_files(c(bak, arch), con)
  bak_hash <- first$hash[first$path == bak][[1]]
  arch_hash <- first$hash[first$path == arch][[1]]
  expect_identical(stored_route(con, bak_hash)$state[[1]], "ignored")

  # Drive the second file to `archived`, the strongest guard: reconsidering an
  # archived file could re-commit data already in the DB.
  ingest_file_set_state(con, arch_hash, "archived", reset = TRUE)

  redone <- route_files(c(bak, arch), con, reconsider = TRUE)

  expect_identical(stored_route(con, bak_hash)$state[[1]], "ignored",
                   info = "R-3.7: an ignored file stays ignored - ignore_rule() decides that, not the registry")
  expect_identical(stored_route(con, arch_hash)$state[[1]], "archived",
                   info = "R-3.7: an archived file must never be reconsidered")
  expect_equal(redone$state[redone$path == bak][[1]], "ignored")
  expect_equal(redone$state[redone$path == arch][[1]], "archived")
})

test_that("R-3.7: reconsider = TRUE under dry_run = TRUE writes nothing - the stored verdict is unchanged", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "ES2617126_0_XTAB.csv", content = "a,b\n1,2\n")
  first <- route_files(c(path), con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "quarantined")

  register_adapter(make_matcher_adapter(
    "late_adapter2", function(fm) if (fm$ext == "csv") "format" else "no"
  ))

  preview <- route_files(c(path), con, dry_run = TRUE, reconsider = TRUE)

  # The RETURN may report the new verdict (that is what a preview is for), but
  # the DB must not have moved - neither to `claimed` nor, critically, to the
  # intermediate `seen` a reset would leave behind.
  persisted <- stored_route(con, hash)
  expect_identical(persisted$state[[1]], "quarantined",
                   info = "R-3.7: a dry run must not persist the reconsidered verdict")
  expect_identical(persisted$state_reason[[1]], "unclaimed")
  expect_false(identical(persisted$state[[1]], "seen"),
               info = "R-3.7: a dry run must not strand the row at `seen` either")
  expect_equal(preview$state[[1]], "claimed")
})

test_that("R-3.7: a file still unclaimed after reconsideration ends terminal (quarantined/unclaimed), never stranded at `seen`", {
  clear_adapters()
  withr::defer({ clear_adapters(); register_builtin_adapters() })

  dir <- withr::local_tempdir()
  db <- seed_db(dir)
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))

  path <- st_test_write_file(dir, "ES2617126_0_COA.pdf", content = "%PDF-1.4 nothing claims this")
  first <- route_files(c(path), con)
  hash <- first$hash[[1]]
  expect_equal(first$state[[1]], "quarantined")

  # Nothing registered that could claim it: reconsideration re-decides and
  # lands on the same verdict. The row must be terminal again afterwards - a
  # "reset to seen, then re-decide" that fails to re-decide would leave the
  # row non-terminal, which silently re-opens it to any later transition.
  redone <- route_files(c(path), con, reconsider = TRUE)
  expect_equal(redone$state[[1]], "quarantined")
  expect_equal(redone$reason[[1]], "unclaimed")

  persisted <- stored_route(con, hash)
  expect_identical(persisted$state[[1]], "quarantined")
  expect_identical(persisted$state_reason[[1]], "unclaimed")
})
