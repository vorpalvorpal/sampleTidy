# Plan 10 - R-10.5: real-corpus gates (A3). Every test here calls
# `skip_if_no_corpus()` first - the only permitted skip in the plans 07-10
# suites. The dry-run-against-a-real-DB gate additionally checks
# `SAMPLETIDY_CORPUS_DB` (a second, narrower opt-in for an even more
# sensitive artifact - a real monitoring.duckdb copy); that second skip is
# logged as a deliberate, narrowly-scoped extension of the same A3 allowance
# rather than a new kind of skip (see dev/plans/PLAN-CHANGE-REQUESTS.md).

tier_rank <- c(exact = 1L, format = 2L, fallback = 3L, no = 99L)

# ---- route sweep ------------------------------------------------------------

test_that("R-10.5: route sweep - router_matrix() over the corpus has no adapter tie", {
  skip_if_no_corpus()
  use_builtin_adapters()
  paths <- corpus_files()
  expect_true(length(paths) > 0, info = "corpus directory is empty")

  matrix <- router_matrix(paths)
  matrix$rank <- tier_rank[matrix$tier]

  by_path <- split(matrix, matrix$path)
  n_unclaimed <- sum(vapply(by_path, function(df) all(df$tier == "no"), logical(1)))
  message(sprintf("Corpus route sweep: %d files, %d unclaimed (informational only)", length(paths), n_unclaimed))

  ties <- Filter(function(df) {
    claimed <- df[df$tier != "no", ]
    if (nrow(claimed) == 0) return(FALSE)
    win <- min(claimed$rank)
    sum(claimed$rank == win) > 1
  }, by_path)

  testthat::expect(
    length(ties) == 0,
    failure_message = paste0(
      "adapter tie(s) found for: ", paste(names(ties), collapse = "; "), "\n",
      paste(vapply(ties, function(df) paste(utils::capture.output(print(df)), collapse = "\n"), character(1)), collapse = "\n\n")
    )
  )
})

# ---- parse sweep -------------------------------------------------------------

test_that("R-10.5: parse sweep - every corpus file claimed at exact/format parses without error and validates", {
  skip_if_no_corpus()
  use_builtin_adapters()
  paths <- corpus_files()

  routed <- corpus_route(paths)
  # Guard the sweep itself: route_files() turns any per-file error into a
  # `failed` row, so an all-failed routing must be a loud failure here, not
  # a vacuously-passing empty sweep.
  testthat::expect(
    !all(routed$state == "failed"),
    failure_message = paste0(
      "every corpus file routed to `failed` - the sweep never ran. First reason: ",
      routed$reason[[1]]
    )
  )
  claimed <- routed[routed$state == "claimed", ]
  expect_true(nrow(claimed) > 0, info = "no files were claimed by any adapter")

  registry <- adapter_registry()
  skip_tally <- list()

  for (i in seq_len(nrow(claimed))) {
    p <- claimed$path[[i]]
    adapter <- registry[[claimed$adapter[[i]]]]
    meta <- file_meta(p)
    out <- tryCatch(adapter$parse(p, meta), error = function(e) e)
    testthat::expect(
      !inherits(out, "error"),
      failure_message = paste("parse() errored on", p, ":", if (inherits(out, "error")) conditionMessage(out) else "")
    )
    if (!inherits(out, "error")) {
      expect_no_error(ir_validate(out$results, "results"))
      expect_no_error(ir_validate(out$samples, "samples"))
      skipped <- out$report$skipped
      if (!is.null(skipped) && nrow(skipped) > 0) {
        tab <- table(skipped$reason)
        for (r in names(tab)) {
          skip_tally[[r]] <- if (is.null(skip_tally[[r]])) unname(tab[[r]]) else skip_tally[[r]] + unname(tab[[r]])
        }
      }
    }
  }
  message("Corpus parse sweep - aggregate skip reasons:")
  message(paste(capture.output(print(skip_tally)), collapse = "\n"))
})

# ---- cross-format equivalence -------------------------------------------------

test_that("R-10.5: cross-format equivalence holds for Normal rows shared between ESdat and crosstab work orders", {
  skip_if_no_corpus()
  use_builtin_adapters()
  paths <- corpus_files()
  registry <- adapter_registry()

  wo_of <- function(p) {
    m <- regmatches(basename(p), regexpr("[A-Z]{2}[0-9]{7}", basename(p)))
    if (length(m) == 0) NA_character_ else m
  }

  claiming_adapter <- function(p) {
    fm <- file_meta(p)
    hits <- names(registry)[vapply(registry, function(a) a$match(fm) != "no", logical(1))]
    if (length(hits) == 0) NA_character_ else hits[[1]]
  }

  # Both sides go through `assemble_events()`, not bare `parse()`. An ESdat
  # Chemistry2e file carries NO feature or sample_type - that metadata lives
  # in its companion Sample2e file, and the sample->result join is
  # assemble.R's job (R-7.3; the seam A44.2 fixed). Comparing a lone
  # Chemistry2e parse would put `feature_raw = NA` / `sample_type =
  # "unknown"` on every row and silently compare nothing at all.
  assembled_results <- function(files) {
    parsed <- list()
    for (f in files) {
      adapter_id <- claiming_adapter(f)
      if (is.na(adapter_id)) next
      fm <- file_meta(f)
      out <- registry[[adapter_id]]$parse(f, fm)
      parsed[[hash_file(f)]] <- list(
        ir = list(results = out$results, samples = out$samples),
        report = out$report, meta = fm
      )
    }
    if (length(parsed) == 0) return(NULL)
    asm <- assemble_events(parsed)
    if (length(asm$events) == 0) return(NULL)
    asm$events[[1]]$results
  }

  norm_set <- function(df) {
    df <- df[!is.na(df$sample_type) & df$sample_type == "Normal", ]
    sort(paste(
      toupper(trimws(df$feature_raw)),
      toupper(trimws(normalise_lab_text(df$analyte_raw))),
      trimws(df$value_raw)
    ))
  }

  # The ESdat side needs the COMPLETE pair; the corpus holds several
  # Chemistry2e files whose Sample2e companion was never downloaded, and
  # those carry no comparable feature/sample_type at all.
  esdat_files <- paths[grepl("\\.(Chemistry2e|Sample2e)\\.CSV$", paths, ignore.case = TRUE)]

  # `.bak` twins are included deliberately. The old pipeline renamed each
  # crosstab CSV to `.bak` once it had ingested it, so *every* work order
  # that has both formats has its crosstab only as a `.bak`; excluding them
  # leaves this gate with zero real comparisons. `ignore_rule()`'s `.bak`
  # skip governs INGESTION (what we commit and archive), not this read-only
  # format cross-check, and the content is genuine crosstab output. They are
  # copied to a de-`.bak`'d temp name purely so the adapter's filename-based
  # `match()` sees the real extension.
  xtab_files <- paths[grepl("_(XTAB|ENMRG)\\.(csv|xls|xlsx)(\\.bak)?$", paths, ignore.case = TRUE)]

  esdat_wo <- vapply(esdat_files, wo_of, character(1))
  xtab_wo <- vapply(xtab_files, wo_of, character(1))

  complete_pair_wo <- intersect(
    unique(esdat_wo[grepl("Chemistry2e", esdat_files, ignore.case = TRUE) & !is.na(esdat_wo)]),
    unique(esdat_wo[grepl("Sample2e", esdat_files, ignore.case = TRUE) & !is.na(esdat_wo)])
  )
  shared <- sort(intersect(complete_pair_wo, unique(xtab_wo[!is.na(xtab_wo)])))

  staging <- withr::local_tempdir()
  compared <- character(0)

  for (wo in shared) {
    candidates <- xtab_files[!is.na(xtab_wo) & xtab_wo == wo]
    xtab_path <- NULL
    for (cand in candidates) {
      staged <- file.path(staging, sub("\\.bak$", "", basename(cand)))
      file.copy(cand, staged, overwrite = TRUE)
      if (!is.na(claiming_adapter(staged))) {
        xtab_path <- staged
        break
      }
    }
    if (is.null(xtab_path)) {
      # e.g. a work order whose only crosstab is a SpreadsheetML .XLS (A37).
      message(sprintf("  work order %s: no claimable crosstab twin (%s)", wo,
                      paste(basename(candidates), collapse = ", ")))
      next
    }

    esdat_keys <- norm_set(assembled_results(esdat_files[!is.na(esdat_wo) & esdat_wo == wo]))
    xtab_keys <- norm_set(assembled_results(xtab_path))

    testthat::expect(
      setequal(esdat_keys, xtab_keys),
      failure_message = paste0(
        "cross-format mismatch for work order ", wo, " (",
        length(esdat_keys), " ESdat vs ", length(xtab_keys), " crosstab Normal rows):\n",
        "  only in ESdat: ", paste(setdiff(esdat_keys, xtab_keys), collapse = "; "), "\n",
        "  only in crosstab: ", paste(setdiff(xtab_keys, esdat_keys), collapse = "; ")
      )
    )
    compared <- c(compared, wo)
    message(sprintf("  work order %s: %d Normal rows agree across ESdat and crosstab",
                    wo, length(esdat_keys)))
  }

  message(sprintf("Cross-format equivalence: %d comparable work order(s), %d compared",
                  length(shared), length(compared)))

  # [MEASURE TWICE] means this gate must actually measure something: a corpus
  # that yields no comparison is a failure of the gate, not a silent pass.
  # (A test that makes zero expectations is reported as "skipped", which is
  # exactly how this criterion went unverified before.)
  testthat::expect(
    length(compared) > 0,
    failure_message = paste0(
      "no work order could be compared across formats - the equivalence gate ",
      "verified nothing. Shared work orders: ", paste(shared, collapse = ", ")
    )
  )
})

# ---- dry-run against a real DB copy -------------------------------------------

test_that("R-10.5: a dry run against a copy of the real DB completes, finds already_present rows, and writes nothing", {
  skip_if_no_corpus()
  use_builtin_adapters()
  corpus <- corpus_path()
  db_copy_src <- corpus_db_path()
  if (identical(db_copy_src, "") || !file.exists(db_copy_src)) {
    testthat::skip("SAMPLETIDY_CORPUS_DB not set to an existing file - dry-run-against-real-DB gate skipped (A3, narrower opt-in)")
  }

  dest <- withr::local_tempdir()
  db_copy <- file.path(dest, basename(db_copy_src))
  file.copy(db_copy_src, db_copy)

  count_all <- function(path) {
    con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = TRUE)
    on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
    tables <- DBI::dbListTables(con)
    vapply(tables, function(t) DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', t))$n, numeric(1))
  }

  before <- count_all(db_copy)
  report <- ingest_dir(corpus, db = db_copy, dry_run = TRUE)
  after <- count_all(db_copy)

  # "Writes nothing" is scoped to the *data* the real DB already holds: a
  # dry run must not add, remove or change a single row of any table that
  # existed before it ran. It does legitimately create sampleTidy's own
  # bookkeeping tables (the real DB predates this package and has no
  # `ingest_file`/`change_log`/`review_queue`/`schema_version`), because
  # `ensure_schema()` runs before the dry-run branch is reached - so compare
  # only the pre-existing tables, and pin the new ones separately below.
  expect_equal(after[names(before)], before)

  # The provenance/review tables are created but must stay empty: nothing was
  # committed, so nothing may be logged or queued.
  expect_equal(unname(after[["change_log"]]), 0)
  expect_equal(unname(after[["review_queue"]]), 0)

  # Hash bookkeeping IS persisted by a dry run (see dev/HANDOVER.md - this is
  # a known, deliberate-for-now wart: a dry run followed by a real run over
  # the same directory finds the files already past `seen`). Pinned here so
  # the behaviour is a visible decision rather than an accident.
  expect_true(after[["ingest_file"]] > 0)

  expect_type(report, "list")
  # DESIGN §7 / R-10.5: the point of this gate is old-pipeline overlap - the
  # real DB already holds these analyses, so a dry run must recognise them
  # rather than propose them all as new.
  testthat::expect(
    report$rows_already_present > 0,
    failure_message = paste0(
      "dry run against the real DB found no already_present rows ",
      "(new=", report$rows_new, ", already_present=", report$rows_already_present,
      ") - expected overlap with the old pipeline's data"
    )
  )
})
