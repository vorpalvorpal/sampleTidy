# Plan 08 - R/reconcile.R: the reconciler.
#
# `reconcile_event(event, con)` -> `list(clean, review, skipped, counts)`.
# Read-only against the DB (CONTRACT A32) - every access below is a
# `DBI::dbGetQuery()`; there are no raw table-write calls anywhere in this
# file. Deterministic rules only; no LLM (DESIGN Sec7).
#
# See dev/plans/PLAN-08-reconcile.md (R-8.1..R-8.8) and CONTRACT.md
# (A6, A11, A12, A14, A32) for the rules implemented stage-by-stage below.

# ---- registry loading (read-only snapshot of the small core tables) ------

#' Pull the small core registry tables into memory once per reconcile run
#' @keywords internal
#' @noRd
.rc_load_registry <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT * FROM feature"),
    feature_mask = DBI::dbGetQuery(con, "SELECT * FROM feature_mask"),
    analyte = DBI::dbGetQuery(con, "SELECT * FROM analyte"),
    lab_method = DBI::dbGetQuery(con, "SELECT * FROM lab_method"),
    project = DBI::dbGetQuery(con, "SELECT * FROM project")
  )
}

# ---- small shared helpers --------------------------------------------------

#' Squish + case-fold a text key for exact (non-fuzzy) matching
#' @keywords internal
#' @noRd
.rc_key <- function(x) {
  tolower(stringr::str_squish(normalise_lab_text(x)))
}

.rc_proto_skip <- function() {
  tibble::tibble(source_ref = character(0), reason = character(0), payload = character(0))
}
.rc_proto_review <- function() {
  tibble::tibble(source_ref = character(0), kind = character(0), payload = character(0), n_rows = integer(0))
}

# ---- R-8.1: QC filter -------------------------------------------------------

#' Split `results` into QC-filtered-out rows and survivors (R-8.1)
#' @keywords internal
#' @noRd
.rc_qc_filter <- function(results) {
  st <- results$sample_type
  is_ok <- is.na(st) | st %in% c("Normal", "unknown")
  qc_rows <- results[!is_ok, , drop = FALSE]
  skipped <- if (nrow(qc_rows) > 0) {
    tibble::tibble(
      source_ref = qc_rows$source_ref,
      reason = paste0("qc_", qc_rows$sample_type),
      payload = NA_character_
    )
  } else {
    .rc_proto_skip()
  }
  list(kept = results[is_ok, , drop = FALSE], skipped = skipped)
}

# ---- R-8.2: feature resolution ---------------------------------------------

#' Candidate feature uuids for one `feature_raw` string (R-8.2): exact,
#' case-insensitive match against `feature.name` then `feature_mask.name`.
#' No fuzzy matching.
#' @keywords internal
#' @noRd
.rc_feature_candidates <- function(feature_raw, registry) {
  key <- .rc_key(feature_raw)
  direct <- registry$feature$uuid[.rc_key(registry$feature$name) == key]
  masked <- registry$feature_mask$uuid_feature[.rc_key(registry$feature_mask$name) == key]
  unique(c(direct, masked))
}

#' Resolve `feature_raw` -> `uuid_feature` for every row (R-8.2)
#'
#' Zero-hit and ambiguous rows are grouped by normalised `feature_raw` into
#' one review item per group (never one item per row).
#'
#' @param rows the active working tibble.
#' @param registry from [.rc_load_registry()].
#' @param work_order the event's work order (for review payload context).
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_features <- function(rows, registry, work_order) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, review = .rc_proto_review()))

  uuid_feature <- rep(NA_character_, n)
  status <- rep(NA_character_, n)
  cand_list <- vector("list", n)

  for (i in seq_len(n)) {
    cand <- .rc_feature_candidates(rows$feature_raw[[i]], registry)
    if (length(cand) == 1) {
      uuid_feature[[i]] <- cand
      status[[i]] <- "hit"
    } else if (length(cand) == 0) {
      status[[i]] <- "unknown"
    } else {
      status[[i]] <- "ambiguous"
      cand_list[[i]] <- cand
    }
  }

  hit_idx <- which(status == "hit")
  kept <- rows[hit_idx, , drop = FALSE]
  kept$uuid_feature <- uuid_feature[hit_idx]

  review_list <- list()
  for (sub in c("unknown", "ambiguous")) {
    idx <- which(status == sub)
    if (length(idx) == 0) next
    groups <- split(idx, .rc_key(rows$feature_raw[idx]))
    for (g in groups) {
      refs <- rows$source_ref[g]
      fr <- rows$feature_raw[[g[[1]]]]
      base <- paste0(
        paste(refs, collapse = ","), ",feature_raw=", fr,
        ",work_order=", work_order, ",n_rows=", length(g)
      )
      payload <- if (sub == "ambiguous") {
        paste0(base, ",subkind=ambiguous,candidates=", paste(cand_list[[g[[1]]]], collapse = "|"))
      } else {
        base
      }
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = paste(refs, collapse = ","), kind = "unknown_feature",
        payload = payload, n_rows = length(g)
      )
    }
  }
  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, review = review)
}

# ---- R-8.3: analyte / method resolution ------------------------------------

#' Resolve one row's `(analyte_raw, org, method_raw)` against `lab_method`
#' (R-8.3 step a). Method is used to disambiguate only when the name+org
#' match is not already unique.
#' @keywords internal
#' @noRd
.rc_lab_method_candidates <- function(analyte_raw, org, method_raw, registry) {
  lm <- registry$lab_method
  key <- .rc_key(analyte_raw)
  cand <- lm[.rc_key(lm$name) == key & !is.na(lm$organisation) & lm$organisation == org, , drop = FALSE]
  if (nrow(cand) > 1 && !is.na(method_raw)) {
    mkey <- .rc_key(method_raw)
    narrowed <- cand[!is.na(cand$method) & .rc_key(cand$method) == mkey, , drop = FALSE]
    if (nrow(narrowed) >= 1) cand <- narrowed
  }
  cand
}

#' Resolve `analyte_raw`/`method_raw` -> `uuid_lab`/`uuid_analyte` for every
#' row (R-8.3). Lookup order: lab_method (name+org, method-disambiguated) ->
#' analyte.CAS (still queues `known_analyte_no_method`) -> grouped
#' `unknown_analyte` by `(analyte_raw, org)`.
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_analytes <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, review = .rc_proto_review()))

  uuid_lab <- rep(NA_character_, n)
  uuid_analyte <- rep(NA_character_, n)
  status <- rep(NA_character_, n)

  for (i in seq_len(n)) {
    cand <- .rc_lab_method_candidates(rows$analyte_raw[[i]], rows$org[[i]], rows$method_raw[[i]], registry)
    if (nrow(cand) == 1) {
      uuid_lab[[i]] <- cand$uuid[[1]]
      uuid_analyte[[i]] <- cand$uuid_analyte[[1]]
      status[[i]] <- "hit"
      next
    }
    cas <- rows$cas_number[[i]]
    if (!is.na(cas)) {
      a <- registry$analyte[!is.na(registry$analyte$CAS) & registry$analyte$CAS == cas, , drop = FALSE]
      if (nrow(a) >= 1) {
        uuid_analyte[[i]] <- a$uuid[[1]]
        status[[i]] <- "cas"
        next
      }
    }
    status[[i]] <- "miss"
  }

  hit_idx <- which(status == "hit")
  kept <- rows[hit_idx, , drop = FALSE]
  kept$uuid_lab <- uuid_lab[hit_idx]
  kept$uuid_analyte <- uuid_analyte[hit_idx]

  review_list <- list()

  for (i in which(status == "cas")) {
    review_list[[length(review_list) + 1]] <- tibble::tibble(
      source_ref = rows$source_ref[[i]], kind = "unknown_analyte",
      payload = paste0(
        rows$source_ref[[i]], ",subkind=known_analyte_no_method,analyte_raw=", rows$analyte_raw[[i]],
        ",org=", rows$org[[i]], ",cas_number=", rows$cas_number[[i]], ",uuid_analyte=", uuid_analyte[[i]]
      ),
      n_rows = 1L
    )
  }

  miss_idx <- which(status == "miss")
  if (length(miss_idx) > 0) {
    key <- paste(.rc_key(rows$analyte_raw[miss_idx]), rows$org[miss_idx], sep = "||")
    groups <- split(miss_idx, key)
    for (g in groups) {
      refs <- rows$source_ref[g]
      ar <- rows$analyte_raw[[g[[1]]]]
      org <- rows$org[[g[[1]]]]
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = paste(refs, collapse = ","), kind = "unknown_analyte",
        payload = paste0(
          paste(refs, collapse = ","), ",analyte_raw=", ar, ",org=", org, ",n_rows=", length(g)
        ),
        n_rows = length(g)
      )
    }
  }

  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, review = review)
}

# ---- R-8.4: units & value ---------------------------------------------------

#' Convert `value_num`/`rl` to the resolved analyte's canonical units, and
#' route `parse_value(value_raw)` skips / unit errors out (R-8.4).
#' @return `list(kept, skipped, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_units_values <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) {
    return(list(kept = rows, skipped = .rc_proto_skip(), review = .rc_proto_review()))
  }

  parsed <- parse_value(rows$value_raw)

  keep <- rep(TRUE, n)
  value_converted <- rep(NA_real_, n)
  rl_converted <- rep(NA_real_, n)
  quantified <- rep(NA, n)

  skipped_list <- list()
  review_list <- list()

  for (i in seq_len(n)) {
    if (!is.na(parsed$skip_reason[[i]])) {
      keep[[i]] <- FALSE
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], reason = parsed$skip_reason[[i]], payload = NA_character_
      )
      next
    }

    is_text <- !is.na(rows$value_chr[[i]])
    if (is_text) {
      quantified[[i]] <- TRUE
      next
    }

    quantified[[i]] <- !isTRUE(rows$below_detection[[i]])

    analyte_row <- registry$analyte[registry$analyte$uuid == rows$uuid_analyte[[i]], , drop = FALSE]
    units_to <- normalise_lab_text(analyte_row$units[[1]])
    units_from <- normalise_lab_text(rows$units_raw[[i]])

    conv <- tryCatch(
      unify_value(c(rows$value_num[[i]], rows$rl[[i]]), c(units_from, units_from), c(units_to, units_to)),
      sampletidy_units_error = function(e) e
    )
    if (inherits(conv, "condition")) {
      keep[[i]] <- FALSE
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], kind = "unknown_unit",
        payload = paste0(
          rows$source_ref[[i]], ",units_raw=", rows$units_raw[[i]], ",analyte=", analyte_row$name[[1]],
          ",value_raw=", rows$value_raw[[i]]
        ),
        n_rows = 1L
      )
      next
    }
    value_converted[[i]] <- conv[[1]]
    rl_converted[[i]] <- conv[[2]]
  }

  kept <- rows[keep, , drop = FALSE]
  kept$value_converted <- value_converted[keep]
  kept$rl_converted <- rl_converted[keep]
  kept$quantified <- quantified[keep]

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()
  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, skipped = skipped, review = review)
}

# ---- R-8.5: sample datetime -------------------------------------------------

.rc_datetime_formats <- c("%d %b %Y %H:%M", "%d %b %Y", "%d/%m/%Y")

#' Parse `sample_datetime_raw` into `sample_date`/`sample_datetime` (R-8.5,
#' A11). Unparseable strings queue a `parse_error` review item (per row - not
#' grouped, since these are typically singleton anomalies).
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_datetime <- function(rows) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, review = .rc_proto_review()))

  parsed_dt <- parse_lab_datetime(rows$sample_datetime_raw, .rc_datetime_formats)
  has_time <- has_clock_time(rows$sample_datetime_raw)

  keep <- !is.na(parsed_dt)

  sample_date <- as.Date(rep(NA, n))
  sample_date[keep] <- as.Date(parsed_dt[keep], tz = "Australia/Sydney")

  sample_datetime <- as.POSIXct(rep(NA_real_, n), origin = "1970-01-01", tz = "Australia/Sydney")
  set_dt <- keep & .rc_is_true_vec(has_time)
  sample_datetime[set_dt] <- parsed_dt[set_dt]

  review_list <- list()
  for (i in which(!keep)) {
    review_list[[length(review_list) + 1]] <- tibble::tibble(
      source_ref = rows$source_ref[[i]], kind = "parse_error",
      payload = paste0(
        rows$source_ref[[i]], ",subkind=datetime,sample_datetime_raw=", rows$sample_datetime_raw[[i]]
      ),
      n_rows = 1L
    )
  }

  kept <- rows[keep, , drop = FALSE]
  kept$sample_date <- sample_date[keep]
  kept$sample_datetime <- sample_datetime[keep]

  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, review = review)
}

#' NA-safe vectorised `isTRUE()` (`has_clock_time()` never returns NA, but
#' guard anyway since it's used as a logical index).
#' @keywords internal
#' @noRd
.rc_is_true_vec <- function(x) !is.na(x) & x

# ---- R-8.6: method preference ----------------------------------------------

#' Within `(uuid_feature, sample_date, uuid_analyte)`, when surviving rows
#' come from different `uuid_lab`, keep the lowest `lab_method.rl_low` (NA
#' loses to any number); tie -> keep the higher `value_num` (R-8.6).
#' @return `list(kept, skipped)`.
#' @keywords internal
#' @noRd
.rc_method_preference <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, skipped = .rc_proto_skip()))

  key <- paste(rows$uuid_feature, as.character(rows$sample_date), rows$uuid_analyte, sep = "||")
  rl_low <- registry$lab_method$rl_low[match(rows$uuid_lab, registry$lab_method$uuid)]

  keep <- rep(TRUE, n)
  skipped_list <- list()

  for (k in unique(key)) {
    idx <- which(key == k)
    if (length(idx) <= 1) next
    labs <- unique(rows$uuid_lab[idx])
    if (length(labs) <= 1) next

    ord <- order(is.na(rl_low[idx]), rl_low[idx], -rows$value_num[idx])
    winner <- idx[ord[[1]]]
    losers <- setdiff(idx, winner)
    keep[losers] <- FALSE

    kept_uuid_lab <- rows$uuid_lab[[winner]]
    for (li in losers) {
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[li]], reason = "method_duplicate",
        payload = paste0("kept_uuid_lab=", kept_uuid_lab)
      )
    }
  }

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()

  list(kept = rows[keep, , drop = FALSE], skipped = skipped)
}

# ---- R-8.7: three-way outcome vs DB -----------------------------------------

#' Find an existing `analysis` row matching `(uuid_feature, sample_date,
#' sample_datetime, uuid_analyte)` (A11: date-granularity first, then
#' datetime to disambiguate when both sides have one).
#' @return a one-row data frame, or `NULL` if no candidate.
#' @keywords internal
#' @noRd
.rc_find_existing <- function(con, uuid_feature, sample_date, sample_datetime, uuid_analyte) {
  cand <- DBI::dbGetQuery(
    con,
    '
    SELECT a.uuid AS analysis_uuid, a.value, a.value_chr, a.quantified, a.rl_low, a.rl_high, a.uuid_lab,
           s.datetime AS s_datetime
    FROM "sample" s
    JOIN analysis a ON a.uuid_sample = s.uuid
    JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE s.uuid_feature = ? AND CAST(s.date AS DATE) = ? AND lm.uuid_analyte = ?
    ',
    params = list(uuid_feature, as.character(sample_date), uuid_analyte)
  )
  if (nrow(cand) == 0) return(NULL)

  if (!is.na(sample_datetime) && nrow(cand) > 1) {
    has_dt <- !is.na(cand$s_datetime)
    if (any(has_dt)) {
      match_dt <- has_dt & (cand$s_datetime == sample_datetime)
      if (any(match_dt)) cand <- cand[match_dt, , drop = FALSE]
    }
  }
  cand[1, , drop = FALSE]
}

#' Recorded revision (A12): max over (i) `ingest_file.revision` of
#' committed/archived files of `work_order`, excluding the current event's
#' own files, and (ii) `revision_guess` parsed from `asset.filename` for
#' assets of the work order's project. `NA` when neither source has data.
#' @keywords internal
#' @noRd
.rc_recorded_revision <- function(con, work_order, own_hashes) {
  if (is.na(work_order)) return(NA_integer_)

  ifq <- DBI::dbGetQuery(
    con, "SELECT hash, revision, state FROM ingest_file WHERE work_order = ?",
    params = list(work_order)
  )
  if (nrow(ifq) > 0) {
    ifq <- ifq[ifq$state %in% c("committed", "archived") & !(ifq$hash %in% own_hashes), , drop = FALSE]
  }
  rev_a <- ifq$revision[!is.na(ifq$revision)]

  proj <- DBI::dbGetQuery(
    con, "SELECT uuid FROM project WHERE name = ? AND type = 'Work order'",
    params = list(work_order)
  )
  rev_b <- integer(0)
  if (nrow(proj) > 0) {
    assets <- DBI::dbGetQuery(con, "SELECT filename FROM asset WHERE uuid_project = ?", params = list(proj$uuid[[1]]))
    if (nrow(assets) > 0) {
      guesses <- vapply(assets$filename, function(fn) {
        g <- .st_guess_work_order_revision(fn)
        if (is.na(g$revision_guess)) NA_integer_ else as.integer(g$revision_guess)
      }, integer(1))
      rev_b <- guesses[!is.na(guesses)]
    }
  }

  all_rev <- c(rev_a, rev_b)
  if (length(all_rev) == 0) return(NA_integer_)
  as.integer(max(all_rev))
}

#' A14 value equality: numeric within `abs(a-b) <= 1e-9*max(1,|a|,|b|)`, plus
#' equal `quantified`; text values compared by identity.
#' @keywords internal
#' @noRd
.rc_values_equal <- function(inc_value, inc_chr, inc_quant, exist_value, exist_chr, exist_quant) {
  if (is.na(inc_quant) || is.na(exist_quant) || !identical(inc_quant, exist_quant)) return(FALSE)
  if (!is.na(inc_value) && !is.na(exist_value)) {
    return(abs(inc_value - exist_value) <= 1e-9 * max(1, abs(inc_value), abs(exist_value)))
  }
  if (is.na(inc_value) && is.na(exist_value)) {
    return(identical(inc_chr, exist_chr))
  }
  FALSE
}

#' Three-way outcome vs the DB for every surviving row (R-8.7; A11/A12/A14).
#' @return `list(kept, skipped, review)`. `kept` gains a `supersedes` column.
#' @keywords internal
#' @noRd
.rc_three_way <- function(rows, con, event) {
  n <- nrow(rows)
  if (n == 0) {
    rows$supersedes <- character(0)
    return(list(kept = rows, skipped = .rc_proto_skip(), review = .rc_proto_review()))
  }

  own_hashes <- unique(c(event$results$source_hash, event$files$hash))
  own_hashes <- own_hashes[!is.na(own_hashes)]

  keep <- rep(TRUE, n)
  supersedes <- rep(NA_character_, n)
  skipped_list <- list()
  review_list <- list()

  for (i in seq_len(n)) {
    existing <- .rc_find_existing(
      con, rows$uuid_feature[[i]], rows$sample_date[[i]], rows$sample_datetime[[i]], rows$uuid_analyte[[i]]
    )
    if (is.null(existing)) next

    inc_value <- rows$value_converted[[i]]
    inc_chr <- rows$value_chr[[i]]
    inc_quant <- rows$quantified[[i]]
    exist_value <- existing$value[[1]]
    exist_chr <- existing$value_chr[[1]]
    exist_quant <- existing$quantified[[1]]

    if (.rc_values_equal(inc_value, inc_chr, inc_quant, exist_value, exist_chr, exist_quant)) {
      keep[[i]] <- FALSE
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], reason = "already_present",
        payload = existing$analysis_uuid[[1]]
      )
      next
    }

    recorded_rev <- .rc_recorded_revision(con, rows$work_order[[i]], own_hashes)
    incoming_rev <- rows$revision[[i]]

    if (!is.na(recorded_rev) && !is.na(incoming_rev) && incoming_rev > recorded_rev) {
      supersedes[[i]] <- existing$analysis_uuid[[1]]
    } else {
      keep[[i]] <- FALSE
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], kind = "value_conflict",
        payload = paste0(
          rows$source_ref[[i]], ",existing_value=", exist_value, ",incoming_value=", inc_value,
          ",existing_uuid=", existing$analysis_uuid[[1]], ",existing_quantified=", exist_quant,
          ",incoming_quantified=", inc_quant, ",recorded_revision=", recorded_rev,
          ",incoming_revision=", incoming_rev
        ),
        n_rows = 1L
      )
    }
  }

  kept <- rows[keep, , drop = FALSE]
  kept$supersedes <- supersedes[keep]

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()
  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, skipped = skipped, review = review)
}

# ---- top-level entry point --------------------------------------------------

#' Reconcile one assembled event against the registry/analysis DB (R-8.1..8.8)
#'
#' Read-only: every DB access is a `DBI::dbGetQuery()` (CONTRACT A32). Applies,
#' in order: QC filter (R-8.1), feature resolution (R-8.2), analyte/method
#' resolution (R-8.3), units & value conversion (R-8.4), sample datetime
#' parsing (R-8.5), method preference dedup (R-8.6), and the three-way
#' outcome vs the DB (R-8.7; A11/A12/A14). `clean`/`review`/`skipped` are
#' disjoint and their `source_ref` union equals the input rows (R-8.8).
#'
#' @param event a plan-07 event object (`work_order`, `results`, `files`, ...).
#' @param con an open read-write (but here, read-only-used) DBI connection.
#' @return `list(clean, review, skipped, counts)`.
#' @keywords internal
#' @noRd
reconcile_event <- function(event, con) {
  results <- event$results

  if (nrow(results) == 0) {
    return(list(clean = results, review = .rc_proto_review()[, c("source_ref", "kind", "payload")],
                skipped = .rc_proto_skip(), counts = c(clean = 0L)))
  }

  registry <- .rc_load_registry(con)

  skipped_acc <- list()
  review_acc <- list()
  count_acc <- list()

  add_skip <- function(df) {
    if (nrow(df) == 0) return(invisible())
    skipped_acc[[length(skipped_acc) + 1]] <<- df[, c("source_ref", "reason", "payload")]
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$reason, n = 1L, stringsAsFactors = FALSE)
  }
  add_review <- function(df) {
    if (nrow(df) == 0) return(invisible())
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$kind, n = df$n_rows, stringsAsFactors = FALSE)
    review_acc[[length(review_acc) + 1]] <<- df[, c("source_ref", "kind", "payload")]
  }

  # R-8.1
  qc <- .rc_qc_filter(results)
  add_skip(qc$skipped)
  active <- qc$kept

  # R-8.2
  feat <- .rc_resolve_features(active, registry, event$work_order)
  add_review(feat$review)
  active <- feat$kept

  # R-8.3
  an <- .rc_resolve_analytes(active, registry)
  add_review(an$review)
  active <- an$kept

  # R-8.4
  uv <- .rc_resolve_units_values(active, registry)
  add_skip(uv$skipped)
  add_review(uv$review)
  active <- uv$kept

  # R-8.5
  dt <- .rc_resolve_datetime(active)
  add_review(dt$review)
  active <- dt$kept

  # R-8.6
  mp <- .rc_method_preference(active, registry)
  add_skip(mp$skipped)
  active <- mp$kept

  # R-8.7
  tw <- .rc_three_way(active, con, event)
  add_skip(tw$skipped)
  add_review(tw$review)
  clean <- tw$kept

  skipped <- if (length(skipped_acc) > 0) dplyr::bind_rows(skipped_acc) else .rc_proto_skip()
  review <- if (length(review_acc) > 0) dplyr::bind_rows(review_acc) else .rc_proto_review()[, c("source_ref", "kind", "payload")]

  count_df <- if (length(count_acc) > 0) dplyr::bind_rows(count_acc) else data.frame(key = character(0), n = integer(0))
  counts <- c(clean = as.integer(nrow(clean)))
  if (nrow(count_df) > 0) {
    tbl <- tapply(count_df$n, count_df$key, sum)
    counts <- c(stats::setNames(as.integer(tbl), names(tbl)), counts)
  }

  list(clean = clean, review = review, skipped = skipped, counts = counts)
}
