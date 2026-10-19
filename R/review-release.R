# release_review(): commit the rows an adapter WITHHELD for review, with the
# human's chosen dates, then resolve the review item (OPERATING-RULES A-number
# recorded there). The withheld rows live IN the review payload
# (`payload$rows`, written by reconcile's STAGE-0), so release depends on
# neither the archived file nor a re-parse.

#' Coerce a payload `rows` data frame back to assembled-`results` shape
#' @keywords internal
#' @noRd
.rv_rows_from_payload <- function(rows) {
  rows <- tibble::as_tibble(rows)
  n <- nrow(rows)
  for (col in names(.st_ir_results_types)) {
    type <- .st_ir_results_types[[col]]
    v <- if (col %in% names(rows)) rows[[col]] else rep(NA, n)
    rows[[col]] <- switch(type,
      character = as.character(v),
      integer = as.integer(v),
      double = as.double(v),
      logical = as.logical(v),
      Date = as.Date(as.character(v)),
      v
    )
  }
  for (col in c("sample_datetime_raw", "sample_date_start_raw", "sampler", "matrix_raw",
                "parent_sample")) {
    rows[[col]] <- if (col %in% names(rows)) as.character(rows[[col]]) else rep(NA_character_, n)
  }
  rows$needs_review <- rep(FALSE, n)
  rows$review_kind <- rep(NA_character_, n)
  rows$review_payload <- vector("list", n)
  rows
}

#' Release the rows withheld by a review item, with chosen dates
#'
#' An adapter can withhold rows it does not trust (a `needs_review` flag on
#' its results) - for example a dust gauge-block whose `Month` and exposure
#' date disagree (A77, `date_conflict`/`a77`). Those rows are not committed;
#' they wait in `review_queue`, whole, in the item's payload.
#' `release_review()` is how a human lets them through: it applies
#' `overrides` to the withheld rows' sample dates, commits them through the
#' normal reconcile and commit path, then resolves the item - all in one
#' transaction, so a failure commits nothing and leaves the item open.
#'
#' Releasing an item that is already resolved (or does not exist) does
#' nothing, so calling it twice commits the rows once.
#'
#' @param uuid the `review_queue.uuid` of the item to release.
#' @param overrides a named list; `date_start` (exposure, the sample's
#'   `date_start`) and `date` (collection, the sample's `date`) are each a
#'   `Date` (or an ISO string) that replaces the withheld rows' own. Omit a
#'   name to keep the date the row arrived with. `sample` places the rows of
#'   a `sample_ambiguous` item (A91): one of the item's candidate sample
#'   uuids, or `"new"` for a new sample. It is required for that kind, and any
#'   other uuid is refused.
#' @param resolved_by who released it - mandatory, no default (A55).
#' @param db path to the DuckDB file; defaults to `st_config("live_db")`.
#' @return `invisible(TRUE)` if rows were released, `invisible(FALSE)` if
#'   `uuid` did not match an open item.
#' @export
release_review <- function(uuid, overrides = list(), resolved_by,
                           db = st_config("live_db")) {
  checkmate::assert_string(uuid)
  checkmate::assert_list(overrides, names = "unique")
  checkmate::assert_subset(names(overrides), c("date_start", "date", "sample"))
  if (!is.null(overrides$sample)) checkmate::assert_string(overrides$sample)
  checkmate::assert_string(resolved_by)
  checkmate::assert_string(db)

  result <- with_db_write(
    function(con) {
      db_transaction(con, function(con) {
        item <- DBI::dbGetQuery(
          con, "SELECT uuid, kind, subkind, work_order, source_hash, payload
                  FROM review_queue WHERE uuid = ? AND status = 'open'",
          params = list(uuid)
        )
        if (nrow(item) == 0L) {
          return(FALSE)
        }
        payload <- jsonlite::fromJSON(item$payload[[1]], simplifyVector = TRUE)
        if (is.null(payload$rows) || NROW(payload$rows) == 0L) {
          cli::cli_abort(
            "release_review(): review item {.val {uuid}} ({item$kind[[1]]}) carries no withheld rows.",
            class = "sampletidy_error"
          )
        }
        rows <- .rv_rows_from_payload(payload$rows)
        # A91: a sample_ambiguous item is released onto a sample the reviewer
        # names. Without one, reconcile would only withhold the rows again.
        cands <- as.character(unlist(payload$candidate_samples))
        if (identical(item$kind[[1]], "sample_ambiguous") &&
            !(isTRUE(overrides$sample %in% c(cands, "new")))) {
          cli::cli_abort(
            c("release_review(): {.val {uuid}} is a {.val sample_ambiguous} item, so
               {.code overrides$sample} must name one of its candidate samples or {.val new}.",
              "i" = "candidates: {.val {cands}}",
              "x" = "got {.val {if (is.null(overrides$sample)) 'nothing' else overrides$sample}}"),
            class = "sampletidy_error"
          )
        }
        if (!is.null(overrides$sample)) {
          if (!identical(item$kind[[1]], "sample_ambiguous")) {
            cli::cli_abort(
              "release_review(): {.code overrides$sample} applies only to a
               {.val sample_ambiguous} item; {.val {uuid}} is {.val {item$kind[[1]]}}.",
              class = "sampletidy_error"
            )
          }
          rows$sample_override <- rep(overrides$sample, nrow(rows))
        }
        fmt <- function(d) format(as.Date(d), "%d/%m/%Y")
        if (!is.null(overrides$date)) rows$sample_datetime_raw <- rep(fmt(overrides$date), nrow(rows))
        if (!is.null(overrides$date_start)) {
          rows$sample_date_start_raw <- rep(fmt(overrides$date_start), nrow(rows))
        }

        wo <- if (is.na(item$work_order[[1]])) rows$work_order[[1]] else item$work_order[[1]]
        hash <- item$source_hash[[1]]
        acirl <- any(startsWith(rows$adapter, "acirl_"), na.rm = TRUE)
        event <- list(
          work_order = wo, orphan = FALSE, results = rows,
          samples = tibble::tibble(sample_datetime_raw = unique(rows$sample_datetime_raw)),
          files = tibble::tibble(hash = hash),
          report = if (acirl) list(sources = stats::setNames(
            list(list(report_no = wo)), hash
          )) else list()
        )
        reason <- sprintf("release_review(): uuid=%s", uuid)
        actor <- resolved_by

        resolved <- reconcile_event(event, con)
        tree <- .ct_ensure_project_tree(con, event, reason)
        clean <- resolved$clean
        review <- resolved$review
        if (!is.null(tree$review) && nrow(tree$review) > 0) {
          review <- dplyr::bind_rows(review, tree$review)
        }
        if (nrow(clean) > 0) {
          clean <- .ct_materialise_feature_aliases(con, clean, event, actor, reason)
          clean <- .ct_materialise_lab_methods(con, clean, event, actor, reason)
          clean$uuid_sample <- .ct_resolve_samples(con, clean, tree$uuid_project, reason, event)
          .ct_record_resolution_provenance(con, clean, actor)
        }
        .ct_commit_analyses(con, clean, actor, reason)
        .ct_record_already_present(con, resolved$skipped, actor, reason)
        review <- .ct_commit_review(con, review, event, actor, reason)
        if (nrow(clean) > 0 && nrow(review) > 0) {
          .ct_rewrite_review_payloads(con, review, clean)
        }

        db_update(
          con, "review_queue", uuid = uuid,
          changes = list(
            status = "resolved",
            resolution = sprintf("released %d row(s) with overrides: %s", nrow(rows),
                                 paste(names(overrides), vapply(overrides, format, ""),
                                       sep = "=", collapse = ", ")),
            resolved_by = resolved_by, resolved_at = Sys.time()
          ),
          actor = resolved_by, reason = reason
        )
        TRUE
      })
    },
    db = db
  )
  invisible(result)
}
