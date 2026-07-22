# Plan 07 - R/assemble.R: R-7.1 grouping, R-7.2 source preference, R-7.3
# sample-metadata join, R-7.4 multi-work-order partitioning, R-7.5 event
# object shape. See dev/plans/PLAN-07-assembly.md and CONTRACT A22/A23.

# --- pinned tables / small helpers -----------------------------------------

# Source-preference rank table (R-7.2/DESIGN §2.1). Rank is a property of
# the *adapter id* (the `adapter` IR column stripped of its `/<version>`
# suffix). `acirl_field_xlsx` is rank-exempt (handled separately, never
# looked up here) - field data, not a lab rendering.
.st_source_rank <- c(esdat = 3L, als_enmrg = 2L, als_xtab = 1L)

# Combined datetime-format vector covering both dialects seen across
# `sample_datetime_raw` values at assembly time (ESdat + crosstab/ACIRL).
# The two `%d-%b-%y` forms cover the ESdat short-date rendering
# (`"07-May-24 11:30"`); keep this union in sync with `.rc_datetime_formats`
# (reconcile.R) and the `esdat` preset (dates.R).
.st_join_datetime_formats <- c("%d %b %Y %H:%M", "%d %b %Y",
                               "%d-%b-%y %H:%M", "%d-%b-%y", "%d/%m/%Y")

#' Strip the `/<version>` suffix from an `adapter` IR column value
#' @keywords internal
#' @noRd
.st_adapter_id <- function(adapter_full) {
  if (is.na(adapter_full)) {
    return(NA_character_)
  }
  sub("/.*$", "", adapter_full)
}

#' Look up an adapter id's source-preference rank (R-7.2); unknown ids rank 0
#' @keywords internal
#' @noRd
.st_source_rank_of <- function(adapter_id) {
  if (is.na(adapter_id) || !(adapter_id %in% names(.st_source_rank))) {
    return(0L)
  }
  unname(.st_source_rank[[adapter_id]])
}

#' A file's home work order (A23): `report$header$work_order` if present,
#' else `meta$work_order_guess`. `NA_character_` if neither is available.
#' @keywords internal
#' @noRd
.st_home_work_order <- function(report, meta) {
  wo <- report$header$work_order
  if (is.null(wo) || length(wo) == 0 || (length(wo) == 1 && is.na(wo))) {
    wo <- meta$work_order_guess
  }
  if (is.null(wo) || length(wo) == 0) {
    return(NA_character_)
  }
  as.character(wo[[1]])
}

#' A file's adapter id (full, with version), read off its first results row,
#' else its first samples row, else `NA` (metadata-only files).
#' @keywords internal
#' @noRd
.st_file_adapter_full <- function(results, samples) {
  if (nrow(results) > 0) {
    return(results$adapter[[1]])
  }
  if (nrow(samples) > 0) {
    return(samples$adapter[[1]])
  }
  NA_character_
}

#' Normalise a text join key: squish whitespace, case-fold (R-7.3)
#' @keywords internal
#' @noRd
.st_normalise_key <- function(x) {
  tolower(stringr::str_squish(x))
}

# --- R-7.1 grouping ----------------------------------------------------

#' Partition `parsed` hashes into event groups keyed on home work order
#'
#' Files sharing a non-`NA` home work order (A23) form one event group.
#' Each file with a `NA` home work order forms its own single-file (orphan)
#' group. Every input hash appears in exactly one group.
#'
#' @param parsed the `assemble_events()` input.
#' @return a list of `list(hashes, work_order)`.
#' @keywords internal
#' @noRd
.st_group_events <- function(parsed) {
  hashes <- names(parsed)
  home_wo <- vapply(hashes, function(h) {
    .st_home_work_order(parsed[[h]]$report, parsed[[h]]$meta)
  }, character(1))

  groups <- list()
  order_keys <- character(0)
  for (h in hashes) {
    wo <- home_wo[[h]]
    key <- if (is.na(wo)) paste0("__orphan__::", h) else paste0("wo::", wo)
    if (is.null(groups[[key]])) {
      groups[[key]] <- character(0)
      order_keys <- c(order_keys, key)
    }
    groups[[key]] <- c(groups[[key]], h)
  }

  lapply(order_keys, function(key) {
    hs <- groups[[key]]
    list(hashes = hs, work_order = unname(home_wo[[hs[[1]]]]))
  })
}

# --- R-7.3 sample-metadata join -----------------------------------------

#' Join merged event `samples` onto assembled `results` (R-7.3)
#'
#' Matches by `lab_sample_id` (exact) when the result row has one; falls
#' back to normalised `feature_raw` when it doesn't (the "date part" side of
#' the fallback key is left unresolved for the `results` side - see
#' PLAN-CHANGE-REQUESTS.md). Fills `sample_datetime_raw` (only when NA),
#' `sampler`, `matrix_raw`, `parent_sample`, and always overrides
#' `sample_type` with a matched non-NA sample-metadata value (authoritative).
#' A date-part disagreement among a result row's matched sample rows marks
#' that row `needs_review` (`value_conflict` / `sample_datetime_mismatch`)
#' without blocking any other row.
#'
#' @param results the pre-join assembled `results` tibble (already carries
#'   `sample_datetime_raw`/`sampler`/`matrix_raw`/`parent_sample`/
#'   `needs_review`/`review_kind`/`review_payload` columns).
#' @param samples the event's merged `samples` tibble.
#' @return `results`, same rows/order, columns filled/flagged in place.
#' @keywords internal
#' @noRd
.st_join_samples_onto_results <- function(results, samples) {
  n <- nrow(results)
  if (n == 0 || nrow(samples) == 0) {
    return(results)
  }

  samples_date <- as.Date(
    parse_lab_datetime(samples$sample_datetime_raw, .st_join_datetime_formats),
    tz = "Australia/Sydney"
  )
  samples_feature_key <- .st_normalise_key(samples$feature_raw)
  results_feature_key <- .st_normalise_key(results$feature_raw)

  # R-12.14 (A45): `lab_sample_id` here is IR-internal ONLY - a per-file/
  # per-source-column linkage device (e.g. the ACIRL adapter's synthetic
  # "<sheet>!c<col>" id, R-11.15) used to pick the right sample-metadata row
  # for a result. It is NEVER part of the sample/analysis DB identity key.
  # The identity key is (feature, date, analyte, method) - see A45 in
  # CONTRACT.md and the reconciler's three-way match (R/reconcile.R
  # `.rc_find_existing`, R-8.7). Do not repurpose `lab_sample_id` (or this
  # exact-match branch) as an identity join outside this file - that was
  # the A39 fixture bug this comment exists to prevent a recurrence of.
  for (i in seq_len(n)) {
    lab_id <- results$lab_sample_id[[i]]
    if (!is.na(lab_id)) {
      match_idx <- which(!is.na(samples$lab_sample_id) & samples$lab_sample_id == lab_id)
    } else {
      match_idx <- which(samples_feature_key == results_feature_key[[i]])
    }
    if (length(match_idx) == 0) {
      next
    }

    m_datetime <- samples$sample_datetime_raw[match_idx]
    m_date <- samples_date[match_idx]
    m_type <- samples$sample_type[match_idx]
    m_sampler <- samples$sampler[match_idx]
    m_matrix <- samples$matrix_raw[match_idx]
    m_parent <- samples$parent_sample[match_idx]
    m_feature <- samples$feature_raw[match_idx]

    non_na_dates <- unique(m_date[!is.na(m_date)])
    if (length(non_na_dates) > 1) {
      results$needs_review[[i]] <- TRUE
      if (is.na(results$review_kind[[i]])) {
        results$review_kind[[i]] <- "value_conflict"
      }
      results$review_payload[[i]] <- list(
        kind = "value_conflict", subkind = "sample_datetime_mismatch",
        candidates = unique(m_datetime[!is.na(m_datetime)])
      )
    }

    if (is.na(results$sample_datetime_raw[[i]])) {
      nn <- m_datetime[!is.na(m_datetime)]
      if (length(nn) > 0) {
        results$sample_datetime_raw[[i]] <- nn[[1]]
      }
    }

    nn_type <- m_type[!is.na(m_type)]
    if (length(nn_type) > 0) {
      results$sample_type[[i]] <- nn_type[[1]]
    }

    if (is.na(results$sampler[[i]])) {
      nn <- m_sampler[!is.na(m_sampler)]
      if (length(nn) > 0) results$sampler[[i]] <- nn[[1]]
    }
    if (is.na(results$matrix_raw[[i]])) {
      nn <- m_matrix[!is.na(m_matrix)]
      if (length(nn) > 0) results$matrix_raw[[i]] <- nn[[1]]
    }
    if (is.na(results$parent_sample[[i]])) {
      nn <- m_parent[!is.na(m_parent)]
      if (length(nn) > 0) results$parent_sample[[i]] <- nn[[1]]
    }
    # ESdat carries the feature only on Sample2e, so its Chemistry2e results
    # start with feature_raw = NA; fill it from the matched sample. Guarded by
    # is.na() so crosstab results, which already carry feature_raw inline, are
    # never clobbered (A44).
    if (is.na(results$feature_raw[[i]])) {
      nn <- m_feature[!is.na(m_feature)]
      if (length(nn) > 0) results$feature_raw[[i]] <- nn[[1]]
    }
  }

  results
}

# --- event construction (R-7.2/R-7.4/R-7.5) -------------------------------

#' Build one event from a group of files sharing a home work order (or a
#' single orphan file), applying source preference, multi-WO partitioning,
#' and the sample-metadata join.
#'
#' @param hashes character vector of member hashes.
#' @param work_order the group's home work order (`NA` for an orphan).
#' @param parsed the full `assemble_events()` input (for lookups by hash).
#' @return `list(event, states)` - `event` is the R-7.5 shape; `states` is a
#'   tibble covering exactly this group's hashes.
#' @keywords internal
#' @noRd
.st_build_event <- function(hashes, work_order, parsed) {
  orphan <- is.na(work_order)

  file_summary <- dplyr::bind_rows(lapply(hashes, function(h) {
    entry <- parsed[[h]]
    results_i <- entry$ir$results
    samples_i <- entry$ir$samples
    adapter_full <- .st_file_adapter_full(results_i, samples_i)
    aid <- .st_adapter_id(adapter_full)
    fn <- entry$meta$filename
    filename <- if (is.null(fn) || length(fn) == 0) NA_character_ else as.character(fn[[1]])
    revision <- NA_integer_
    if (nrow(results_i) > 0) {
      r <- suppressWarnings(max(results_i$revision, na.rm = TRUE))
      if (!is.infinite(r)) revision <- as.integer(r)
    }
    tibble::tibble(
      hash = h, filename = filename, adapter = adapter_full, adapter_id = aid,
      rank = .st_source_rank_of(aid), is_acirl = identical(aid, "acirl_field_xlsx"),
      has_results = nrow(results_i) > 0, revision = revision
    )
  }))

  warnings_acc <- character(0)

  # --- R-7.2 source preference -----------------------------------------

  acirl_kept <- file_summary$hash[file_summary$is_acirl & file_summary$has_results]
  competitors <- file_summary[!file_summary$is_acirl & file_summary$has_results, , drop = FALSE]

  kept_from_competition <- character(0)
  dropped_from_competition <- character(0)

  if (nrow(competitors) > 0) {
    max_rank <- max(competitors$rank)
    top <- competitors[competitors$rank == max_rank, , drop = FALSE]
    if (nrow(top) == 1) {
      kept_from_competition <- top$hash
    } else {
      max_rev <- suppressWarnings(max(top$revision, na.rm = TRUE))
      rev_top <- top[!is.na(top$revision) & top$revision == max_rev, , drop = FALSE]
      if (nrow(rev_top) == 0) {
        rev_top <- top
      }
      if (nrow(rev_top) == 1) {
        kept_from_competition <- rev_top$hash
      } else {
        # Same rank, same (or unknown) revision: content-identical by
        # construction - keep one deterministically, warn naming all.
        kept_from_competition <- rev_top$hash[[1]]
        warnings_acc <- c(warnings_acc, sprintf(
          "Equal-rank, equal-revision duplicate result files kept arbitrarily (content-identical by construction): %s",
          paste(rev_top$hash, collapse = ", ")
        ))
      }
    }
    dropped_from_competition <- setdiff(competitors$hash, kept_from_competition)
  }

  kept_result_hashes <- c(acirl_kept, kept_from_competition)

  # --- R-7.4 multi-work-order partitioning, only for surviving files ----

  contributed_list <- list()
  flag_list <- list()
  n_ncp_foreign <- 0L

  for (h in kept_result_hashes) {
    results_i <- parsed[[h]]$ir$results
    home_wo_i <- .st_home_work_order(parsed[[h]]$report, parsed[[h]]$meta)

    if (is.na(home_wo_i) || nrow(results_i) == 0) {
      own_idx <- rep(TRUE, nrow(results_i))
    } else {
      own_idx <- !is.na(results_i$work_order) & results_i$work_order == home_wo_i
    }
    foreign_idx <- !own_idx
    ncp_idx <- foreign_idx & !is.na(results_i$sample_type) & results_i$sample_type == "NCP"
    other_foreign_idx <- foreign_idx & !ncp_idx

    n_ncp_foreign <- n_ncp_foreign + sum(ncp_idx)

    if (any(other_foreign_idx)) {
      warnings_acc <- c(warnings_acc, sprintf(
        "File %s: %d row(s) with a foreign work order kept for review (foreign_work_order).",
        h, sum(other_foreign_idx)
      ))
    }

    keep_idx <- own_idx | other_foreign_idx
    contributed_list[[length(contributed_list) + 1]] <- results_i[keep_idx, , drop = FALSE]
    flag_list[[length(flag_list) + 1]] <- other_foreign_idx[keep_idx]
  }

  if (length(contributed_list) == 0) {
    final_results <- ir_results()
    all_flags <- logical(0)
  } else {
    final_results <- dplyr::bind_rows(contributed_list)
    all_flags <- unlist(flag_list, use.names = FALSE)
  }

  final_results$sample_datetime_raw <- NA_character_
  final_results$sampler <- NA_character_
  final_results$matrix_raw <- NA_character_
  final_results$parent_sample <- NA_character_
  final_results$needs_review <- all_flags
  final_results$review_kind <- ifelse(all_flags, "other", NA_character_)
  final_results$review_payload <- vector("list", nrow(final_results))
  for (i in which(all_flags)) {
    final_results$review_payload[[i]] <- list(
      kind = "other", subkind = "foreign_work_order",
      work_order = final_results$work_order[[i]], home_work_order = work_order
    )
  }

  # --- R-7.3 sample-metadata join (samples merge from ALL member files) -

  samples_list <- lapply(hashes, function(h) parsed[[h]]$ir$samples)
  event_samples <- dplyr::bind_rows(samples_list)
  event_samples <- if (nrow(event_samples) == 0) ir_samples() else dplyr::distinct(event_samples)

  final_results <- .st_join_samples_onto_results(final_results, event_samples)

  # --- R-7.5 files/report/event assembly ---------------------------------

  files <- file_summary
  files$kept <- files$hash %in% kept_result_hashes | !files$has_results
  files <- files[, c("hash", "filename", "adapter", "rank", "kept")]

  n_by_sample_type <- as.list(table(final_results$sample_type, useNA = "no"))

  skipped <- if (length(dropped_from_competition) > 0) {
    tibble::tibble(
      hash = dropped_from_competition, source_ref = NA_character_,
      reason = "superseded_by_better_source"
    )
  } else {
    tibble::tibble(hash = character(0), source_ref = character(0), reason = character(0))
  }

  report <- list(
    n_results = nrow(final_results), n_by_sample_type = n_by_sample_type,
    n_ncp_foreign = as.integer(n_ncp_foreign), skipped = skipped, warnings = warnings_acc
  )

  event <- list(
    work_order = work_order, orphan = orphan, results = final_results,
    samples = event_samples, files = files, report = report
  )

  states <- tibble::tibble(
    hash = hashes,
    state = ifelse(hashes %in% dropped_from_competition, "ignored", "assembled"),
    reason = ifelse(hashes %in% dropped_from_competition, "superseded_by_better_source", NA_character_)
  )

  list(event = event, states = states)
}

# --- public(ish) entry point ---------------------------------------------

#' Assemble parsed files into events (R-7.1..R-7.5)
#'
#' Groups per-file parse outputs (`parsed`, one entry per file in state
#' `parsed`) into events keyed on home work order (R-7.1/A23), applies
#' source preference between competing lab renderings (R-7.2), joins
#' sample metadata onto results (R-7.3), partitions a multi-work-order
#' file's rows to its own event (R-7.4), and returns the pinned event shape
#' (R-7.5) plus a per-file state-transition tibble.
#'
#' @param parsed `list(<hash> = list(ir = list(results, samples), report,
#'   meta))`, one entry per file in state `parsed`.
#' @return `list(events = list(<event>...), states = tibble(hash, state,
#'   reason))`. `states` covers every input hash exactly once.
#' @keywords internal
#' @noRd
assemble_events <- function(parsed) {
  checkmate::assert_list(parsed, names = "unique")

  groups <- .st_group_events(parsed)

  built <- lapply(groups, function(g) .st_build_event(g$hashes, g$work_order, parsed))

  events <- lapply(built, function(b) b$event)
  states <- dplyr::bind_rows(lapply(built, function(b) b$states))

  list(events = events, states = states)
}
