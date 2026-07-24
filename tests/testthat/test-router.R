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

  path <- st_test_write_file(dir, "TIEFILE_0_XTAB.csv", content = "a,b\n1,2\n")
  result <- route_files(c(path), con)

  expect_equal(result$state[[1]], "quarantined")
  expect_equal(result$reason[[1]], "adapter_tie")

  queue <- DBI::dbGetQuery(con, "SELECT * FROM review_queue WHERE kind = 'adapter_tie'")
  expect_equal(nrow(queue), 1)
  expect_match(queue$payload[[1]], "tie_a", fixed = TRUE)
  expect_match(queue$payload[[1]], "tie_b", fixed = TRUE)
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
