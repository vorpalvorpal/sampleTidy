# Block-level gate measurement, WHOLE PACKAGE.
#
# Why this exists alongside p16_counts.R: the Phase-7 audit (slice C, FC11) found that
# p16_counts.R silently omitted whole test files, so the project's own verdict tool showed
# NOTHING for those slices. A measurement instrument that silently omits a file reads as
# "covered" exactly where it is blind — measure the measurer.
#
# Round-3 audit (2026-07-25) found this tool had inherited two defects of its own, reported
# independently by all three slices (G/FG-9, H/H1+H2, I/F11):
#
#   1. SCOPE. It ran a hand-maintained list of 10 files — 326 of the package's 661 blocks.
#      Everything `.st_append_rows()` touches (test-ingest, test-archive, test-assemble,
#      test-e2e-pipeline, test-migration-*) sat outside it, i.e. the write path this run
#      actually changed was the part it could not see. The list is now DISCOVERED, not
#      maintained: a new test file is measured the day it lands.
#   2. DOUBLE COUNT. `fail` and `err` are independent sums over the same blocks, so a block
#      that both fails an assertion AND errors was counted in both. Adding them gave "33 RED"
#      when the true figure was 31. RED is now computed and printed as its own column, so the
#      headline number cannot be got wrong by adding the wrong two things.
#
# The stale claim about test-migration-006.R is gone: migration 006 was RETIRED in bc3d146
# (its rows no longer exist), so it is legitimately absent, not omitted.
suppressMessages(devtools::load_all(quiet = TRUE))
files <- sort(sub("\\.R$", "", basename(
  list.files("tests/testthat", pattern = "^test-.*\\.R$", full.names = TRUE)
)))
tot <- list(blocks = 0L, ok = 0L, red = 0L, fail = 0L, err = 0L, skip = 0L)
for (f in files) {
  path <- file.path("tests/testthat", paste0(f, ".R"))
  if (!file.exists(path)) { cat(sprintf("%-30s MISSING\n", f)); next }
  r <- testthat::test_file(path, reporter = "silent")
  d <- as.data.frame(r)
  # A SKIPPED block is NOT a verified block: counting it as "ok" is the vacuous-pass this
  # harness exists to catch, so skips are broken out and NAMED.
  skipped <- d$skipped
  # RED is the DISTINCT count of broken blocks. fail/err remain visible for diagnosis but are
  # overlapping subsets of it — never add them together.
  bad <- d$failed > 0 | d$error
  cat(sprintf(paste0("%-30s blocks=%-4d ok=%-4d RED=%-3d skip=%-3d ",
                     "(fail=%-3d err=%-3d overlap=%-2d) | asserts pass=%-4d fail=%-3d\n"),
              f, nrow(d), sum(!bad & !skipped), sum(bad), sum(skipped),
              sum(d$failed > 0), sum(d$error), sum(d$failed > 0 & d$error),
              sum(d$passed), sum(d$failed)))
  # Print NAMES, not just counts: an unchanged count with changed names is a regression in
  # disguise, and that is exactly what caught the R-16.6 violation in Phase 6.
  if (any(bad)) cat(paste0("   RED:  ", substr(d$test[bad], 1, 95), collapse = "\n"), "\n")
  if (any(skipped)) cat(paste0("   SKIP: ", substr(d$test[skipped], 1, 95), collapse = "\n"), "\n")
  tot$blocks <- tot$blocks + nrow(d); tot$ok <- tot$ok + sum(!bad & !skipped)
  tot$red <- tot$red + sum(bad)
  tot$fail <- tot$fail + sum(d$failed > 0); tot$err <- tot$err + sum(d$error)
  tot$skip <- tot$skip + sum(skipped)
}
cat(sprintf("\n%-30s blocks=%-4d ok=%-4d RED=%-3d skip=%-3d (fail=%-3d err=%-3d)\n",
            sprintf("TOTAL (%d files)", length(files)),
            tot$blocks, tot$ok, tot$red, tot$skip, tot$fail, tot$err))
# Identity check: the instrument must account for every block exactly once.
stopifnot(tot$ok + tot$red + tot$skip == tot$blocks)
cat(sprintf("%-30s ok+RED+skip == blocks  (%d + %d + %d == %d)\n",
            "IDENTITY OK", tot$ok, tot$red, tot$skip, tot$blocks))
