# Shared helpers for plan 07-10 tests: real-corpus gating (A3) and e2e input
# directory assembly. Owned by plan 10 (PLAN-10-e2e-corpus.md), referenced by
# plan 09's ingest tests too. Only DEFINES functions - no top-level calls -
# so this file can be sourced even before any production R/ functions exist.

#' Path to a local copy of real `input/` files (A3)
#'
#' The env var points at a directory the operator maintains locally; it is
#' never committed to the repo (A3 - public repo, no real lab data). Tests
#' that need it must call `skip_if_no_corpus()` first.
#'
#' @return the value of `Sys.getenv("SAMPLETIDY_CORPUS")` (possibly `""`)
corpus_path <- function() {
  Sys.getenv("SAMPLETIDY_CORPUS", unset = "")
}

#' Skip the current test unless a real corpus directory is configured
#'
#' This is the ONLY permitted `skip()` in the plan 07-10 suites - every other
#' criterion gets a real, non-skipped assertion (per the pipeline-tests
#' brief). Corpus tests are gated because the corpus is real lab data (A3)
#' and is never present in CI or a fresh checkout.
#'
#' @return (invisibly) the corpus path, if not skipped
skip_if_no_corpus <- function() {
  path <- corpus_path()
  if (identical(path, "") || !dir.exists(path)) {
    testthat::skip("SAMPLETIDY_CORPUS not set to an existing directory (A3) - real-corpus test skipped")
  }
  invisible(path)
}

#' Every real *file* directly inside the corpus directory (non-recursive)
#'
#' Mirrors `ingest_dir()`'s own listing (`fs::dir_ls(type = "file",
#' recurse = FALSE)`, A8) rather than using `list.files()`, which also
#' returns subdirectories: the real corpus holds several subdirectories
#' (e.g. the operator's curated `sampleTidy example/` folder) that
#' `ingest_dir()` never recurses into and that `file_meta()`/`hash_file()`
#' cannot hash - passing one to `router_matrix()` aborts the sweep.
#'
#' @param path corpus directory (defaults to `corpus_path()`)
#' @return character vector of absolute file paths
corpus_files <- function(path = corpus_path()) {
  as.character(fs::dir_ls(path, type = "file", all = TRUE, recurse = FALSE))
}

#' Restore the canonical built-in adapter registry
#'
#' The adapter registry is global mutable state and other test files leave it
#' dirty: test-adapter-registry.R clears it, and several register throwaway
#' test adapters that claim everything. A corpus sweep run after them sees a
#' registry that is neither empty nor canonical - which is how a sweep can
#' report "0 unclaimed" out of 266 real files and pass in isolation while
#' failing in the full suite. Same guard as test-e2e-pipeline.R's R-10.1.
#' (`ingest_dir()` self-registers per A33; `router_matrix()` does not.)
#'
#' @return invisibly, the restored registry's adapter ids
use_builtin_adapters <- function() {
  clear_adapters()
  register_builtin_adapters()
  invisible(names(adapter_registry()))
}

#' Route a set of paths against a throwaway, schema-only DuckDB
#'
#' `route_files()` takes `(paths, con)` and persists `ingest_file` state, so
#' a read-only sweep still needs a writable DB. This gives it a fresh temp
#' one (never the real corpus DB), so a route sweep records its state
#' bookkeeping somewhere disposable. NB `route_files()` catches per-file
#' errors and reports them as `state = "failed"` rows, so calling it with a
#' wrong signature fails *silently* as an all-failed sweep - always assert
#' on the returned states, never just on "it didn't error".
#'
#' @param paths character vector of file paths
#' @param env frame to scope the temp dir's cleanup to (the calling test)
#' @return the `route_files()` tibble
corpus_route <- function(paths, env = parent.frame()) {
  db <- file.path(withr::local_tempdir(.local_envir = env), "corpus-route.duckdb")
  with_db_write(
    function(con) {
      ensure_schema(con)
      route_files(paths, con)
    },
    db = db
  )
}

#' Path to a local copy of the real monitoring.duckdb, if configured
#'
#' Used only by the plan-10 R-10.5 dry-run-against-a-real-DB-copy gate.
#' Distinct from `SAMPLETIDY_CORPUS` because a real DB copy is a heavier,
#' separate opt-in (FIXTURES.md / PLAN-10 R-10.5: "a temp copy of the real
#' monitoring.duckdb if SAMPLETIDY_CORPUS_DB also set").
#'
#' @return the value of `Sys.getenv("SAMPLETIDY_CORPUS_DB")` (possibly `""`)
corpus_db_path <- function() {
  Sys.getenv("SAMPLETIDY_CORPUS_DB", unset = "")
}

#' Assemble a flat temp input directory from the plan-04/05/06 fixtures + cruft
#'
#' Copies every non-README fixture file from
#' `tests/testthat/fixtures/{esdat,crosstab,acirl}` into `dest` (flat --
#' `ingest_dir()` is non-recursive per A8/R-9.5), then adds:
#'   - a `.bak` file (cruft; must be ignored)
#'   - a `.DS_Store` file (cruft; must be ignored)
#'   - a subdirectory containing a copy of one valid fixture file (must be
#'     left completely untouched -- `ingest_dir()` never recurses)
#'
#' Silently skips a fixture family whose directory doesn't exist yet or is
#' still empty (parallel plans 05/06 land their fixtures independently), so
#' this helper keeps working incrementally as those land.
#'
#' @param dest destination directory (defaults to a fresh withr temp dir
#'   scoped to the calling test)
#' @return the path to `dest`, invisibly usable directly as `ingest_dir(path=)`
build_e2e_input_dir <- function(dest = NULL) {
  # NB: a bare `withr::local_tempdir()` used as a *default argument* would
  # bind its deferred cleanup to this helper's own frame (default-arg
  # promises evaluate in the function's frame), deleting the tempdir the
  # instant this function returns and handing the caller a dead path - the
  # same class of bug as CONTRACT A38/A41. Bind cleanup to the *caller's*
  # frame instead so the directory lives for the whole calling test.
  env <- parent.frame()
  if (is.null(dest)) dest <- withr::local_tempdir(.local_envir = env)
  fixture_root <- testthat::test_path("fixtures")
  families <- c("esdat", "crosstab", "acirl")

  copied <- character(0)
  for (fam in families) {
    fam_dir <- file.path(fixture_root, fam)
    if (!dir.exists(fam_dir)) next
    files <- list.files(fam_dir, full.names = TRUE, recursive = FALSE)
    files <- files[!basename(files) %in% c("README.md", "generate.R")]
    for (f in files) {
      dest_file <- file.path(dest, basename(f))
      file.copy(f, dest_file, overwrite = TRUE)
      copied <- c(copied, dest_file)
    }
  }

  # cruft: a stale .bak file
  writeLines("stale backup, pre-dates sampleTidy", file.path(dest, "old_export.bak"))
  # cruft: a macOS .DS_Store
  writeLines("", file.path(dest, ".DS_Store"))
  # cruft: a subdirectory holding a copy of one valid fixture - proves
  # ingest_dir() never recurses into subfolders (A8/DESIGN MVP scope)
  subdir <- file.path(dest, "subdir")
  dir.create(subdir, showWarnings = FALSE)
  if (length(copied) > 0) {
    file.copy(copied[[1]], file.path(subdir, basename(copied[[1]])), overwrite = TRUE)
  }

  dest
}

#' Ensure a throwaway `asset` table exists on a seeded test DB
#'
#' GAP: `tests/testthat/helper-db.R` (`seed_db()`, owned by the core-tests
#' agent per FIXTURES.md) creates the CONTRACT core tables that FIXTURES.md
#' pins *rows* for (feature, feature_mask, analyte, lab_method, project,
#' sample, analysis) - but FIXTURES.md's "Seed DB" section never mentions
#' `asset`, so `seed_db()` doesn't create it, even though `asset` is part of
#' the CONTRACT "Existing DB schema" and plan 09 (archive_file(), db_append()
#' provenance rows, commit_event()'s archival step) needs a real `asset`
#' table to write into. This helper adds it, idempotently, matching the
#' CONTRACT column list exactly, so plan 09/10 tests aren't blocked on that
#' gap. Logged to dev/plans/PLAN-CHANGE-REQUESTS.md; safe to delete once
#' helper-db.R grows an empty `asset` table itself.
#'
#' @param con an open DBI connection to a `seed_db()`-created database
ensure_test_asset_table <- function(con) {
  DBI::dbExecute(con, "CREATE TABLE IF NOT EXISTS asset (
    uuid VARCHAR PRIMARY KEY,
    name VARCHAR,
    date TIMESTAMP,
    file_format VARCHAR,
    type VARCHAR,
    purpose VARCHAR,
    organisation VARCHAR,
    person VARCHAR,
    uuid_project VARCHAR,
    uuid_feature VARCHAR,
    filename VARCHAR,
    hash VARCHAR,
    comments VARCHAR
  )")
  invisible(con)
}
