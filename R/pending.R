# Pending backlog readers (PLAN-11 R-11.12).
#
# ensure_schema() creates no views (A24), so these are reader pairs over the
# live connection, in the review_queue() style (R/mutate.R) - not views. A
# dangling row (feature_alias.uuid_feature IS NULL / lab_method.uuid_analyte
# IS NULL) is invisible to every view BY DESIGN, since every view joins
# through feature/analyte with an INNER JOIN. Without this pair, that work
# is silent.

# ---- reader: pending_features() ---------------------------------------------

#' Read dangling `feature_alias` rows (unresolved incoming feature labels)
#'
#' Returns one row per `feature_alias` with `uuid_feature IS NULL`, i.e. an
#' alias an event arrived under that has not yet been resolved to a known
#' `feature`. `n_samples` is a LEFT JOIN + COUNT against `sample` so a
#' zero-referenced dangling alias is still surfaced (never dropped).
#'
#' @param con an open DBI connection.
#' @return a tibble with stable columns `uuid_alias`, `name`, `alias_key`,
#'   `n_seen`, `n_samples`, `first_seen`, `last_seen`, even on a zero-row
#'   result.
#' @export
pending_features <- function(con) {
  rows <- DBI::dbGetQuery(
    con,
    "SELECT fa.uuid AS uuid_alias, fa.name AS name, fa.alias_key AS alias_key,
            fa.n_seen AS n_seen, COUNT(s.uuid) AS n_samples,
            fa.first_seen AS first_seen, fa.last_seen AS last_seen
     FROM feature_alias fa
     LEFT JOIN \"sample\" s ON s.uuid_feature_alias = fa.uuid
     WHERE fa.uuid_feature IS NULL
     GROUP BY fa.uuid, fa.name, fa.alias_key, fa.n_seen, fa.first_seen,
              fa.last_seen"
  )
  tibble::as_tibble(rows)
}

# ---- reader: pending_analytes() ---------------------------------------------

#' Read dangling `lab_method` rows (unresolved incoming analyte/method rows)
#'
#' Returns one row per `lab_method` with `uuid_analyte IS NULL`, i.e. a
#' method an event arrived under that has not yet been resolved to a known
#' `analyte`. `n_analyses` is a LEFT JOIN + COUNT against `analysis` so a
#' zero-referenced dangling method is still surfaced (never dropped).
#' `units_raw` is this tibble's own output-column name (matching the IR
#' field it flows into, R/ir.R) - the DB column it reads is
#' `lab_method.units` (D7 reversed, A63); `analysis` has no units column.
#'
#' @param con an open DBI connection.
#' @return a tibble with stable columns `uuid_lab`, `name`, `organisation`,
#'   `method`, `units_raw`, `n_analyses`, even on a zero-row result.
#' @export
pending_analytes <- function(con) {
  rows <- DBI::dbGetQuery(
    con,
    "SELECT lm.uuid AS uuid_lab, lm.name AS name,
            lm.organisation AS organisation, lm.method AS method,
            lm.units AS units_raw, COUNT(a.uuid) AS n_analyses
     FROM lab_method lm
     LEFT JOIN analysis a ON a.uuid_lab = lm.uuid
     WHERE lm.uuid_analyte IS NULL
     GROUP BY lm.uuid, lm.name, lm.organisation, lm.method, lm.units"
  )
  tibble::as_tibble(rows)
}
