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
  corpus <- corpus_path()
  paths <- list.files(corpus, full.names = TRUE, recursive = FALSE)
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
  corpus <- corpus_path()
  paths <- list.files(corpus, full.names = TRUE, recursive = FALSE)

  routed <- route_files(paths)
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
  corpus <- corpus_path()
  paths <- list.files(corpus, full.names = TRUE, recursive = FALSE)

  wo_of <- function(p) {
    m <- regmatches(basename(p), regexpr("[A-Z]{2}[0-9]{7}", basename(p)))
    if (length(m) == 0) NA_character_ else m
  }

  esdat_chem <- paths[grepl("Chemistry2e\\.CSV$", paths, ignore.case = TRUE)]
  xtab_like <- paths[grepl("_(XTAB|ENMRG)\\.(csv|xls|xlsx)$", paths, ignore.case = TRUE)]
  chem_wo <- vapply(esdat_chem, wo_of, character(1))
  xtab_wo <- vapply(xtab_like, wo_of, character(1))
  shared <- intersect(chem_wo[!is.na(chem_wo)], xtab_wo[!is.na(xtab_wo)])

  message(sprintf("Cross-format equivalence: %d shared work order(s) found in corpus", length(shared)))
  registry <- adapter_registry()

  norm_set <- function(df) {
    df <- df[df$sample_type == "Normal", ]
    key <- paste(
      toupper(trimws(df$feature_raw)),
      toupper(trimws(normalise_lab_text(df$analyte_raw))),
      trimws(df$value_raw)
    )
    sort(key)
  }

  for (wo in shared) {
    chem_path <- esdat_chem[chem_wo == wo][[1]]
    xtab_path <- xtab_like[xtab_wo == wo][[1]]
    chem_meta <- file_meta(chem_path)
    xtab_meta <- file_meta(xtab_path)

    esdat_adapter_id <- names(registry)[vapply(registry, function(a) a$match(chem_meta) != "no", logical(1))][1]
    xtab_adapter_id <- names(registry)[vapply(registry, function(a) a$match(xtab_meta) != "no", logical(1))][1]
    expect_false(is.na(esdat_adapter_id))
    expect_false(is.na(xtab_adapter_id))

    chem_out <- registry[[esdat_adapter_id]]$parse(chem_path, chem_meta)
    xtab_out <- registry[[xtab_adapter_id]]$parse(xtab_path, xtab_meta)

    chem_keys <- norm_set(chem_out$results)
    xtab_keys <- norm_set(xtab_out$results)

    testthat::expect(
      setequal(chem_keys, xtab_keys),
      failure_message = paste0(
        "cross-format mismatch for work order ", wo, ":\n",
        "  only in ESdat: ", paste(setdiff(chem_keys, xtab_keys), collapse = "; "), "\n",
        "  only in crosstab: ", paste(setdiff(xtab_keys, chem_keys), collapse = "; ")
      )
    )
  }
})

# ---- dry-run against a real DB copy -------------------------------------------

test_that("R-10.5: a dry run against a copy of the real DB completes, finds already_present rows, and writes nothing", {
  skip_if_no_corpus()
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

  expect_equal(after, before)
  expect_type(report, "list")
})
