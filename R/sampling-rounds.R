# Sampling rounds from the contractor work ledger (PLAN-18 section 4.6).
# Read-only. The ledger is written by the t1 tool; see
# invoice-automation/docs/contractor-work-ledger.md.

sr_streams <- c("acirl_water", "acirl_gas", "acirl_dust", "als_lab")
sr_sites <- c(Blaxland = "B", Katoomba = "K")

sr_empty <- function() {
  data.frame(
    site = character(), stream = character(), sampled_on = as.Date(character()),
    ref = character(), section = character(), note = character(),
    stringsAsFactors = FALSE
  )
}

sr_chr <- function(x) if (is.null(x) || length(x) != 1L || is.na(x)) NA_character_ else as.character(x)

#' Read sampling rounds from the contractor work ledger
#'
#' Reads `contractor-work.json` and returns one row per invoiced sampling
#' round item (`kind == "sampling_round"`), the evidence that a delivery
#' should exist. Other kinds, unknown sites and unknown streams are dropped
#' silently. Read-only.
#'
#' @param ledger Path to `contractor-work.json`. A missing file gives a
#'   zero-row frame; corrupt JSON is a `sampletidy_parse_error`; a `version`
#'   other than 1 is an error.
#' @return A data frame with columns `site` (`"B"`/`"K"`), `stream`,
#'   `sampled_on` (`Date`), `ref` (the invoice key), `section` and `note`
#'   (`NA` when the ledger's is null).
#' @export
sampling_rounds <- function(ledger) {
  if (!file.exists(ledger)) return(sr_empty())
  x <- tryCatch(
    jsonlite::fromJSON(ledger, simplifyVector = FALSE),
    error = function(e) {
      rlang::abort(
        paste0("Cannot parse contractor work ledger ", ledger, ": ", conditionMessage(e)),
        class = "sampletidy_parse_error"
      )
    }
  )
  if (!is.list(x) || !identical(as.integer(x$version), 1L)) {
    rlang::abort(paste0("Unsupported contractor work ledger version in ", ledger, " (need 1)."))
  }
  rows <- list()
  for (ref in names(x$invoices)) {
    for (it in x$invoices[[ref]]$items) {
      if (!identical(it$kind, "sampling_round")) next
      site <- unname(sr_sites[sr_chr(it$site)])
      stream <- sr_chr(it$activity)
      if (is.na(site) || is.na(stream) || !stream %in% sr_streams) next
      rows[[length(rows) + 1L]] <- data.frame(
        site = site, stream = stream, sampled_on = as.Date(sr_chr(it$date)),
        ref = ref, section = sr_chr(it$section), note = sr_chr(it$note),
        stringsAsFactors = FALSE
      )
    }
  }
  if (!length(rows)) return(sr_empty())
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out
}
