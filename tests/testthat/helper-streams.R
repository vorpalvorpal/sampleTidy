# Helpers for the stream-table tests (stage 1 of the layer move: `checks$streams`,
# `checks$site_names`, the limits behaviour columns). Only DEFINES functions.
#
# Everything here is synthetic: site N (features N.W01, N.P01, N.X01 ...),
# organisations FIELDCO (field sheets) and LABCO (a laboratory), project types
# "Gas round" and "Deposition round". None of it names a real deployment.

#' A stream table from row specs. Each row is a named list; an absent column
#' takes the spec's default (NA / FALSE / 0). A character vector of rows is
#' NOT accepted: pass `list(stream = "s1", ...)` per row.
sx_streams <- function(...) {
  rows <- list(...)
  d <- lapply(rows, function(r) {
    base <- list(stream = NA_character_, project_type = NA_character_,
                 feature_pattern = NA_character_, matrix = NA_character_,
                 organisation = NA_character_, kind = NA_character_,
                 water = FALSE, gas = FALSE, window_months = 0L, expects_qci = FALSE)
    base[names(r)] <- r
    as.data.frame(base, stringsAsFactors = FALSE)
  })
  do.call(rbind, d)
}

#' The two evidence streams most tests want: FIELDCO field sheets and LABCO lab
#' results, both water streams; only the lab stream expects a QCI.
sx_evidence <- function() {
  sx_streams(
    list(stream = "field", organisation = "FIELDCO", kind = "field", water = TRUE),
    list(stream = "lab", organisation = "LABCO", kind = "lab", water = TRUE,
         expects_qci = TRUE))
}

#' fl_checks() with `streams` (and `site_names`) set explicitly. `site_names`
#' defaults to NULL here, so a note shows raw site codes.
sx_checks <- function(streams = sx_evidence(), site_names = NULL, ..., extra = list()) {
  ch <- fl_checks(...)
  ch["streams"] <- list(streams)
  ch["site_names"] <- list(site_names)
  for (nm in names(extra)) ch[nm] <- list(extra[[nm]])
  ch
}

#' import_flags() with exactly the checks given (no fl_with_defaults()), so a
#' test can leave `streams` out.
sx_raw_flags <- function(db, checks, now = fl_now()) {
  suppressWarnings(suppressMessages(import_flags(db = db, now = now, checks = checks)))
}

#' The streams that have a missing_point flag at `site` in month `ym`
#' ("2026-09"), read from the keys `missing_point|<site>|<ym>|<stream>`.
sx_mp_streams <- function(f, ym, site = "N") {
  k <- f$key[f$check == "missing_point"]
  p <- strsplit(k, "|", fixed = TRUE)
  hit <- vapply(p, function(x) length(x) == 4 && x[[2]] == site && x[[3]] == ym, NA)
  sort(vapply(p[hit], `[`, "", 4L))
}

#' A schedule row per stream for site N, all months, whose single expected
#' feature (N.ZZ9) is never sampled - so every stream with a recent sample in a
#' round raises a missing_point flag for it, and the flags reveal which streams
#' the round's samples counted for.
sx_probe_schedule <- function(streams, features = "N.ZZ9") {
  do.call(fl_schedule, lapply(streams, function(s) {
    list(site = "N", stream = s, months = "all", features = features, due_days = "30")
  }))
}
