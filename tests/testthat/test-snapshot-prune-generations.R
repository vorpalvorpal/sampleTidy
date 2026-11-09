# PLAN-21 phase (a), section 3a: prune_snapshots() with generation names.
#
#   names      monitoring_YYYY-MM-DD.duckdb and monitoring_YYYY-MM-DD_g<N>.duckdb
#              (N a non-negative integer string) are both snapshots
#   retention  unchanged (7 days all / 8 weeks weekly / monthly forever)
#   per date   several files on one date: only the highest generation is a
#              candidate (an old name ranks below any _g<N>); the rest are
#              deleted in every age zone
#   manifest   <name without .duckdb>.manifest.json goes with a deleted snapshot;
#              an orphan manifest and every other file are left alone
# Synthetic empty files only.

gp_name <- function(date, gen = NA) {
  if (is.na(gen)) sprintf("monitoring_%s.duckdb", as.character(date))
  else sprintf("monitoring_%s_g%s.duckdb", as.character(date), gen)
}
gp_manifest <- function(snap) sub("\\.duckdb$", ".manifest.json", snap)
gp_mk <- function(dir, date, gen = NA, manifest = TRUE) {
  f <- gp_name(date, gen)
  writeLines("", file.path(dir, f))
  if (manifest) writeLines("{}", file.path(dir, gp_manifest(f)))
  invisible(f)
}
gp_snaps <- function(dir) {
  sort(list.files(dir, pattern = "^monitoring_\\d{4}-\\d{2}-\\d{2}(_g\\d+)?\\.duckdb$"))
}
gp_manifests <- function(dir) sort(list.files(dir, pattern = "\\.manifest\\.json$"))
gp_dates <- function(files) as.Date(substr(sub("^monitoring_", "", files), 1, 10))

# Independent oracle: dates -> retained dates (as in test-snapshot.R).
gp_oracle <- function(dates, today, keep_days = 7, keep_weeks = 8) {
  dates <- sort(unique(dates))
  age <- as.numeric(today - dates)
  z1 <- dates[age <= keep_days]
  z2 <- dates[age > keep_days & age <= keep_days + 7 * keep_weeks]
  z3 <- dates[age > keep_days + 7 * keep_weeks]
  newest_per <- function(x, key) {
    if (length(x) == 0) return(x[0])
    as.Date(vapply(split(as.numeric(x), key), max, numeric(1)), origin = "1970-01-01")
  }
  sort(c(z1, newest_per(z2, format(z2, "%G-W%V")), newest_per(z3, format(z3, "%Y-%m"))))
}

test_that("prune_snapshots() recognises generation names and keeps recent ones", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  keep <- c(gp_mk(d, today, 1), gp_mk(d, today - 1, 12), gp_mk(d, today - 3),
            gp_mk(d, today - 7, 0))
  prune_snapshots(d)
  expect_identical(gp_snaps(d), sort(keep))
  expect_identical(gp_manifests(d), sort(gp_manifest(keep)))
})

test_that("old and new names are pruned under the same retention (400 daily files)", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  all_dates <- today - 0:399
  for (i in seq_along(all_dates)) {
    gp_mk(d, all_dates[i], gen = if (i %% 2 == 0) 3 else NA)
  }
  prune_snapshots(d)
  got <- gp_snaps(d)
  expect_identical(as.character(gp_dates(got)), as.character(gp_oracle(all_dates, today)))
  # the format of each survivor is the one it was created with
  idx <- match(as.character(gp_dates(got)), as.character(all_dates))
  expect_identical(grepl("_g3\\.duckdb$", got), idx %% 2 == 0)
  # one manifest per survivor, none for the pruned
  expect_identical(gp_manifests(d), sort(gp_manifest(got)))
})

test_that("keep_days and keep_weeks are honoured for generation names", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  gp_mk(d, today - 2, 1)
  gp_mk(d, today - 20, 1)
  prune_snapshots(d, keep_days = 1, keep_weeks = 0)
  # age 2 is past keep_days and there is no weekly zone, so it is monthly: the
  # newest of its month; ages 2 and 20 may share a month
  left <- gp_dates(gp_snaps(d))
  expect_identical(as.character(left),
                   as.character(gp_oracle(c(today - 2, today - 20), today, 1, 0)))
})

test_that("several generations on one date: only the highest survives, in every zone", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  # recent zone (all kept by age, but one per date)
  for (g in c(1, 2, 10)) gp_mk(d, today - 1, g)         # 10 > 2 numerically, not as text
  # old name vs new name on one date: the generation wins
  gp_mk(d, today - 2); gp_mk(d, today - 2, 0)
  # old name alone
  gp_mk(d, today - 3)
  # monthly zone, one date with two generations; the date is alone in its month
  far <- today - 300
  gp_mk(d, far, 4); gp_mk(d, far, 5)
  prune_snapshots(d)
  expect_identical(gp_snaps(d), sort(c(gp_name(today - 1, 10), gp_name(today - 2, 0),
                                       gp_name(today - 3), gp_name(far, 5))))
  expect_identical(gp_manifests(d),
                   sort(gp_manifest(c(gp_name(today - 1, 10), gp_name(today - 2, 0),
                                      gp_name(today - 3), gp_name(far, 5)))))
})

test_that("in the weekly zone the newest DATE wins; generations never outrank dates", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  # a Monday and the Tuesday after it, in the weekly zone (ages 8..63)
  cand <- today - 20:50
  mon <- cand[as.integer(format(cand, "%u")) == 1L][1]
  tue <- mon + 1
  expect_gt(as.numeric(today - tue), 7)
  gp_mk(d, mon, 9)          # high generation but the older date
  gp_mk(d, tue, 1)
  gp_mk(d, tue, 2)
  prune_snapshots(d)
  expect_identical(gp_snaps(d), gp_name(tue, 2))
  expect_identical(gp_manifests(d), gp_manifest(gp_name(tue, 2)))
})

test_that("pruning a snapshot deletes its manifest; a snapshot without one is still pruned", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  far <- today - 300
  gp_mk(d, far, 1)                         # superseded by the next
  gp_mk(d, far, 2, manifest = FALSE)       # kept, has no manifest
  gp_mk(d, far + 1, 1)                     # same month: older date pruned (or newest kept)
  prune_snapshots(d)
  left <- gp_snaps(d)
  gone <- setdiff(c(gp_name(far, 1), gp_name(far, 2), gp_name(far + 1, 1)), left)
  expect_gte(length(gone), 1L)
  for (g in gone) {
    expect_false(file.exists(file.path(d, g)))
    expect_false(file.exists(file.path(d, gp_manifest(g))), info = g)
  }
  for (k in left) {
    expect_equal(file.exists(file.path(d, gp_manifest(k))), k != gp_name(far, 2), info = k)
  }
})

test_that("old-format snapshots are pruned along with their manifests", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  gp_mk(d, today - 300)
  gp_mk(d, today - 299)
  prune_snapshots(d)
  expect_length(gp_snaps(d), 1L)
  expect_identical(gp_manifests(d), gp_manifest(gp_snaps(d)))
})

test_that("prune_snapshots() never touches other files", {
  d <- withr::local_tempdir()
  today <- Sys.Date()
  old <- today - 400
  gp_mk(d, today - 300, 1); gp_mk(d, today - 299, 1)       # one of these is pruned
  others <- c(
    "README.txt",
    sprintf("monitoring_%s.duckdb.tmp", old),
    sprintf("monitoring_%s_g1.duckdb.tmp", old),
    sprintf("monitoring_%s_g1.duckdb.bak", old),
    sprintf("monitoring_%s_gx.duckdb", old),                # not a valid generation
    sprintf("monitoring_%s_g-1.duckdb", old),
    sprintf("monitoring_%s_g1_extra.duckdb", old),
    sprintf("other_%s.duckdb", old),
    sprintf("xmonitoring_%s.duckdb", old),
    sprintf("monitoring_%s.manifest.json", old),            # orphan manifest
    sprintf("monitoring_%s_g7.manifest.json", old),         # orphan manifest
    "notes.manifest.json"
  )
  for (o in others) writeLines("keep me", file.path(d, o))
  dir.create(file.path(d, "sub"))
  nested <- file.path(d, "sub", gp_name(old, 1))
  writeLines("keep me", nested)
  writeLines("keep me", sub("\\.duckdb$", ".manifest.json", nested))
  prune_snapshots(d)
  for (o in others) {
    expect_true(file.exists(file.path(d, o)), info = o)
    expect_identical(readLines(file.path(d, o)), "keep me", info = o)
  }
  expect_true(file.exists(nested))
  expect_true(file.exists(sub("\\.duckdb$", ".manifest.json", nested)))
})

test_that("an empty or snapshot-free directory is a no-op", {
  d <- withr::local_tempdir()
  expect_no_error(prune_snapshots(d))
  writeLines("x", file.path(d, "README.txt"))
  expect_no_error(prune_snapshots(d))
  expect_identical(list.files(d), "README.txt")
})
