# PLAN-23 3.2, 17/18 Nov revision: ending a feature, dated masks and common
# names, the predecessor and flow links, and the one label rule.
#
# Every writer here resolves its connection with `with_db_write(db)`, writes
# through the mutation layer in one `db_transaction()` (so `change_log` records
# each write under `actor`/`reason`), refuses with a `sampletidy_error` and
# nothing written, and refuses on a database that migration 117 has not
# reached. Dates are `Date`s or `YYYY-MM-DD` strings; windows are inclusive and
# a NULL end is open.

# ---- shared helpers --------------------------------------------------------------

# The `date_start, date_end` select list for a reader of `feature_mask fm`:
# the row's window after migration 117, two NULL dates (open: every date) on
# a pre-117 database whose mask is undated. Every mask reader matches on the
# date (PLAN-23 3.6).
.st_mask_window_cols <- function(con) {
  dated <- nrow(DBI::dbGetQuery(con, "SELECT 1 FROM information_schema.columns
    WHERE table_catalog = current_database() AND table_name = 'feature_mask'
      AND column_name = 'date_start' LIMIT 1")) > 0
  if (dated) "fm.date_start AS date_start, fm.date_end AS date_end"
  else "CAST(NULL AS DATE) AS date_start, CAST(NULL AS DATE) AS date_end"
}

# Which of the rows with windows [ds, de] hold date `d`? NULL ends open.
.st_in_window <- function(d, ds, de) (is.na(ds) | ds <= d) & (is.na(de) | de >= d)

# One feature row, or abort naming the uuid.
.st_reg_feature <- function(con, uuid, what) {
  f <- DBI::dbGetQuery(con, "SELECT * FROM feature WHERE uuid = ?", params = list(uuid))
  if (nrow(f) == 0L) .st_geom_abort("{what}: no feature {.val {uuid}}.")
  f
}

# The calendar day (configured time zone) each sample is matched on: its
# datetime, else its date (as `sample_in_feature_window` reads it).
.st_reg_sample_day_sql <- function() {
  sprintf("CAST(timezone('%s', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE)", .st_tz())
}

# A required single date (not NA).
.st_reg_date_required <- function(x, arg, what) {
  d <- .st_geom_date(x, arg)
  if (is.null(d) || is.na(d)) .st_geom_abort("{what}: {.arg {arg}} must be a date.")
  d
}

# ---- end_feature() -------------------------------------------------------------------

#' End a feature
#'
#' Sets `feature.date_end` and the `date_end` of the feature's `self` alias arm
#' to `date_end`, in one transaction (two `change_log` updates). A bounded self
#' arm stops claiming the feature's name after the end, so an ended feature
#' does not hold its name against a later, mislabelled sample. Other arms (a
#' former code, a descriptive name) keep their windows.
#'
#' Refused (nothing written): a feature that does not exist; one already ended
#' (re-opening a feature is a migration, not a function); a `date_end` before
#' the feature's `date_start`; a feature with a sample, reached through any of
#' its alias arms, dated after `date_end` (the sample's calendar day in the
#' configured time zone; a sample on `date_end` is fine); and a database that
#' migration 117 has not reached.
#'
#' @param uuid the feature's uuid.
#' @param date_end the feature's last day (inclusive): a `Date` or
#'   `"YYYY-MM-DD"`.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` rows.
#' @param db path to the DuckDB database file (default the live one).
#' @return `uuid`, invisibly.
#' @seealso [add_feature()]
#' @export
end_feature <- function(uuid, date_end, actor, reason, db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  date_end <- .st_reg_date_required(date_end, "date_end", "end_feature()")
  with_db_write(function(con) {
    .st_require_feature_register(con, "end_feature()")
    db_transaction(con, function(con) {
      f <- .st_reg_feature(con, uuid, "end_feature()")
      if (!is.na(f$date_end)) {
        .st_geom_abort("end_feature(): feature {.val {f$name}} is already ended ({f$date_end}).")
      }
      if (!is.na(f$date_start) && date_end < f$date_start) {
        .st_geom_abort("end_feature(): date_end {date_end} is before the feature's date_start ({f$date_start}).")
      }
      late <- DBI::dbGetQuery(con, sprintf("
        SELECT count(*) AS n, max(%1$s) AS last_day
        FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
        WHERE fa.uuid_feature = ? AND %1$s > CAST(? AS DATE)", .st_reg_sample_day_sql()),
        params = list(uuid, date_end))
      if (late$n > 0) {
        .st_geom_abort(paste0(
          "end_feature(): feature {.val {f$name}} has samples dated after {date_end} ",
          "({late$n}; the last on {late$last_day}). Either it has not ended, or those samples are mislabelled."))
      }
      arms <- DBI::dbGetQuery(con, "SELECT uuid FROM feature_alias WHERE uuid_feature = ? AND kind = 'self'
                                    ORDER BY uuid", params = list(uuid))
      db_update(con, "feature", uuid = uuid, changes = list(date_end = date_end),
                actor = actor, reason = reason)
      for (a in arms$uuid) {
        db_update(con, "feature_alias", uuid = a, changes = list(date_end = date_end),
                  actor = actor, reason = reason)
      }
    })
  }, db = db)
  invisible(uuid)
}

# ---- set_feature_mask() ----------------------------------------------------------------

#' Set a dated name (mask) on a feature
#'
#' Masks are a feature's other names, one variant per row, each dated: `long`
#' (a descriptive name), `gas_report`, `common` (the code on site signs and
#' field sheets) and any deployment variant registered in
#' `st_config("mask_variants_extra")` (such as `EPA`). At most one row per
#' feature and variant holds any date.
#'
#' * With a `date_start`, the feature's current row of that variant (the one
#'   with no `date_end`) is ended at `date_start - 1` and a new row is inserted
#'   from `date_start` (one update and one insert in `change_log`).
#' * With `date_start = NA`, an undated current row is replaced in place (same
#'   uuid, one update per changed field); with no current row an undated row is
#'   inserted.
#' * `name = NA` only ends the current row (it needs a `date_start`).
#'
#' For `variant = "common"` the name must not be held by another feature's
#' `common` row on any day of the new window, nor equal any other feature's
#' systematic name (both by canonical key, ended features included); and the
#' feature gets a `historical_code` alias arm of the same key from
#' `date_start` (auto-assigning, unconfirmed) unless one already covers the
#' window, so a sample labelled with the common name still resolves.
#'
#' Refused (nothing written): a variant outside the core and configured ones; a
#' missing feature; a `date_start` on or before the current row's
#' `date_start`; a window that would overlap another row of the variant; the
#' common-name clashes above; and a database that migration 117 has not
#' reached.
#'
#' @param uuid the feature's uuid.
#' @param variant the mask variant.
#' @param name the name, or `NA` to end the current row only.
#' @param date_start the first day of the new row: a `Date`, `"YYYY-MM-DD"`, or
#'   `NA`.
#' @param comments free text for the new row, optional.
#' @inheritParams end_feature
#' @return the uuid of the row inserted, replaced, or (for `name = NA`) ended,
#'   invisibly.
#' @seealso [feature_labels()]
#' @export
set_feature_mask <- function(uuid, variant, name, date_start = as.Date(NA), comments = NA_character_,
                             actor, reason, db = st_config("live_db")) {
  what <- "set_feature_mask()"
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  variant <- .st_geom_string(variant, "variant")
  name <- .st_geom_string(name, "name", na_ok = TRUE)
  comments <- .st_geom_string(comments, "comments", na_ok = TRUE)
  date_start <- .st_geom_date(date_start, "date_start")
  allowed <- unique(c(.st_core_mask_variants, st_config("mask_variants_extra")))
  if (!variant %in% allowed) {
    .st_geom_abort(paste0(
      "{what}: variant {.val {variant}} is not a registered mask variant ({.val {allowed}}); ",
      "a deployment adds its own through st_config(\"mask_variants_extra\")."))
  }
  if (!is.na(name) && !nzchar(trimws(name))) .st_geom_abort("{what}: {.arg name} must not be blank.")
  new_uuid <- uuid::UUIDgenerate()
  feature_uuid <- uuid
  out <- with_db_write(function(con) {
    .st_require_feature_register(con, what)
    db_transaction(con, function(con) {
      .st_reg_feature(con, uuid, what)
      rows <- DBI::dbGetQuery(con, "SELECT * FROM feature_mask WHERE uuid_feature = ? AND variant = ?
                                    ORDER BY uuid", params = list(uuid, variant))
      cur <- rows[is.na(rows$date_end), , drop = FALSE]
      if (nrow(cur) > 1L) {
        .st_geom_abort(paste0(
          "{what}: feature {.val {uuid}} already has {nrow(cur)} open {variant} rows ",
          "({.val {cur$uuid}}); fix the overlap first."))
      }
      in_place <- is.na(date_start) && nrow(cur) == 1L && is.na(cur$date_start)
      if (is.na(date_start) && nrow(cur) == 1L && !in_place) {
        .st_geom_abort(paste0(
          "{what}: the current {variant} row starts {cur$date_start}; give a date_start after it."))
      }
      if (!is.na(date_start) && nrow(cur) == 1L && !is.na(cur$date_start) && date_start <= cur$date_start) {
        .st_geom_abort(paste0(
          "{what}: date_start {date_start} is on or before the current {variant} row's date_start ",
          "({cur$date_start}); the old row cannot end before it began."))
      }
      if (is.na(name) && (nrow(cur) == 0L || is.na(date_start))) {
        .st_geom_abort(if (nrow(cur) == 0L)
          "{what}: feature {.val {uuid}} has no current {variant} row to end."
        else "{what}: name = NA ends the current row and needs a date_start (the first day without it).")
      }
      # The new row's window, and the rows it must not overlap.
      win_start <- if (in_place) cur$date_start else date_start
      others <- rows[!rows$uuid %in% cur$uuid, , drop = FALSE]
      if (!is.na(name) && !in_place && nrow(others) > 0L &&
          any(.st_windows_overlap(win_start, as.Date(NA), others$date_start, others$date_end))) {
        .st_geom_abort(paste0(
          "{what}: a {variant} row from {if (is.na(win_start)) 'the beginning' else win_start} would ",
          "overlap an earlier row ({.val {others$uuid}})."))
      }
      if (!is.na(name) && identical(variant, "common")) {
        .st_reg_common_free(con, uuid, name, win_start, what)
      }
      # Writes: end (or replace) the current row, then insert, then the arm.
      result <- NULL
      if (in_place) {
        changes <- list()
        if (!identical(cur$name, name)) changes$name <- name
        if (!is.na(comments) && !identical(cur$comments, comments)) changes$comments <- comments
        if (length(changes)) {
          db_update(con, "feature_mask", uuid = cur$uuid, changes = changes, actor = actor, reason = reason)
        }
        result <- cur$uuid
      } else {
        if (nrow(cur) == 1L) {
          db_update(con, "feature_mask", uuid = cur$uuid, changes = list(date_end = date_start - 1),
                    actor = actor, reason = reason)
          result <- cur$uuid
        }
        if (!is.na(name)) {
          # (tibble() evaluates in order: `uuid` below would be the new column)
          db_append(con, "feature_mask", tibble::tibble(
            uuid = new_uuid, uuid_feature = feature_uuid, variant = variant, name = name,
            date_start = date_start, date_end = as.Date(NA), comments = comments
          ), actor = actor, reason = reason)
          result <- new_uuid
        }
      }
      if (!is.na(name) && identical(variant, "common")) {
        .st_reg_common_arm(con, uuid, name, win_start, actor, reason)
      }
      result
    })
  }, db = db)
  invisible(out)
}

# Refuse a common name that another feature holds (its systematic name, ended
# features included, or a common row overlapping [win_start, open)).
.st_reg_common_free <- function(con, uuid, name, win_start, what) {
  k <- .st_feature_name_key(name)
  f <- DBI::dbGetQuery(con, "SELECT uuid, name FROM feature WHERE uuid <> ?", params = list(uuid))
  hit <- f$name[!is.na(.st_feature_name_key(f$name)) & .st_feature_name_key(f$name) == k]
  if (length(hit)) {
    .st_geom_abort(paste0(
      "{what}: common name {.val {name}} is the systematic name of another feature ",
      "({.val {hit[[1]]}}); names are never reused."))
  }
  m <- DBI::dbGetQuery(con, "SELECT m.uuid_feature, m.name, m.date_start, m.date_end, f.name AS feature
                             FROM feature_mask m JOIN feature f ON f.uuid = m.uuid_feature
                             WHERE m.variant = 'common' AND m.name IS NOT NULL AND m.uuid_feature <> ?",
                       params = list(uuid))
  m <- m[!is.na(.st_feature_name_key(m$name)) & .st_feature_name_key(m$name) == k, , drop = FALSE]
  held <- m[.st_windows_overlap(win_start, as.Date(NA), m$date_start, m$date_end), , drop = FALSE]
  if (nrow(held)) {
    .st_geom_abort(paste0(
      "{what}: common name {.val {name}} is held by feature {.val {held$feature[[1]]}} on part of ",
      "the new window ({if (is.na(held$date_start[[1]])) 'from the beginning' else held$date_start[[1]]} to ",
      "{if (is.na(held$date_end[[1]])) 'now' else held$date_end[[1]]}); end its row first."))
  }
  invisible(TRUE)
}

# Make sure the feature has an alias arm of the common name's key covering
# [win_start, open); add a historical_code arm when none does.
.st_reg_common_arm <- function(con, uuid, name, win_start, actor, reason) {
  key <- .rc_feature_key(name)
  arms <- DBI::dbGetQuery(con, "SELECT uuid, date_start, date_end FROM feature_alias
                                WHERE uuid_feature = ? AND alias_key = ?", params = list(uuid, key))
  if (nrow(arms) && any(.st_window_covers(arms$date_start, arms$date_end, win_start, as.Date(NA)))) {
    return(invisible(NULL))
  }
  now <- Sys.time()
  feature_uuid <- uuid
  db_append(con, "feature_alias", tibble::tibble(
    uuid = uuid::UUIDgenerate(), uuid_feature = feature_uuid, name = name, alias_key = key,
    kind = "historical_code", n_seen = 0L, auto_assign = TRUE, first_seen = now, last_seen = now,
    # machine-created: never confirmed (A55)
    confirmed_by = NA_character_,
    comments = "Common name arm created by set_feature_mask() (PLAN-23 2.5 rule 5).",
    date_start = win_start, date_end = as.Date(NA)
  ), actor = actor, reason = reason)
  invisible(NULL)
}

# ---- feature_predecessor -------------------------------------------------------------------

#' Link a feature to the earlier feature whose record it continues
#'
#' A predecessor is an earlier, different feature whose record `uuid` extends
#' from `date_break` (a replacement point beside a destroyed one, say). A
#' feature's own former codes are alias arms, never predecessors. A feature may
#' have several predecessors and a predecessor several successors.
#'
#' Refused (nothing written): a missing feature at either end; a feature as its
#' own predecessor; a pair already linked; a blank `source`; a link that would
#' close a loop; a database that migration 117 has not reached.
#'
#' @param uuid the later feature.
#' @param uuid_predecessor the earlier feature.
#' @param date_break the first day of the later feature's record: a `Date`,
#'   `"YYYY-MM-DD"`, or `NA` (unknown).
#' @param source the document the link rests on; never blank.
#' @param comments free text, optional.
#' @inheritParams end_feature
#' @return the new link's uuid, invisibly.
#' @export
add_feature_predecessor <- function(uuid, uuid_predecessor, date_break, source, comments = NA_character_,
                                    actor, reason, db = st_config("live_db")) {
  what <- "add_feature_predecessor()"
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  uuid_predecessor <- .st_geom_string(uuid_predecessor, "uuid_predecessor")
  date_break <- .st_geom_date(date_break, "date_break")
  source <- .st_geom_string(source, "source", na_ok = TRUE)
  comments <- .st_geom_string(comments, "comments", na_ok = TRUE)
  new_uuid <- uuid::UUIDgenerate()
  with_db_write(function(con) {
    .st_require_feature_register(con, what)
    db_transaction(con, function(con) {
      if (is.na(source) || !nzchar(trimws(source))) .st_geom_abort("{what}: {.arg source} must not be blank.")
      if (identical(uuid, uuid_predecessor)) {
        .st_geom_abort("{what}: a feature cannot be its own predecessor ({.val {uuid}}).")
      }
      .st_reg_feature(con, uuid, what)
      .st_reg_feature(con, uuid_predecessor, what)
      p <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature, uuid_predecessor FROM feature_predecessor")
      dup <- p$uuid[p$uuid_feature == uuid & p$uuid_predecessor == uuid_predecessor]
      if (length(dup)) {
        .st_geom_abort("{what}: {.val {uuid}} is already linked to predecessor {.val {uuid_predecessor}} ({.val {dup[[1]]}}).")
      }
      if (.st_reaches(p$uuid_feature, p$uuid_predecessor, from = uuid_predecessor, to = uuid)) {
        .st_geom_abort(paste0(
          "{what}: {.val {uuid_predecessor}} already continues the record of {.val {uuid}}, directly or ",
          "through other links; this link would close a loop."))
      }
      feature_uuid <- uuid
      db_append(con, "feature_predecessor", tibble::tibble(
        uuid = new_uuid, uuid_feature = feature_uuid, uuid_predecessor = uuid_predecessor,
        date_break = date_break, source = source, comments = comments
      ), actor = actor, reason = reason)
    })
  }, db = db)
  invisible(new_uuid)
}

# ---- feature_flow -----------------------------------------------------------------------------

#' Record that water flows from one feature to another
#'
#' A flow link says that water (`carries`) goes from `uuid_from` to `uuid_to`,
#' by gravity or pumped, from `date_start` on (open until
#' [end_feature_flow()] ends it). Links join the structures and points the
#' water passes between, not the pipes that carry it: name the pipe in
#' `comments`. A change on the ground ends the link and adds a new one.
#'
#' Refused (nothing written): a missing feature at either end; `uuid_from ==
#' uuid_to`; a `drive` other than `"gravity"` or `"pumped"`; a blank `source`; a
#' window that overlaps an existing link in the same direction between the
#' same two features (ended links included); a database that migration 117 has
#' not reached.
#'
#' @param uuid_from,uuid_to the features the water leaves and reaches.
#' @param drive `"gravity"` or `"pumped"`.
#' @param carries what flows (leachate, stormwater, ...), optional.
#' @param date_start the link's first day: a `Date`, `"YYYY-MM-DD"`, or `NA`
#'   (unknown).
#' @param source the document the link rests on; never blank.
#' @param comments free text, optional (for example the pipe that carries it).
#' @inheritParams end_feature
#' @return the new link's uuid, invisibly.
#' @seealso [end_feature_flow()]
#' @export
add_feature_flow <- function(uuid_from, uuid_to, drive, carries = NA_character_, date_start = as.Date(NA),
                             source, comments = NA_character_, actor, reason,
                             db = st_config("live_db")) {
  what <- "add_feature_flow()"
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid_from <- .st_geom_string(uuid_from, "uuid_from")
  uuid_to <- .st_geom_string(uuid_to, "uuid_to")
  drive <- .st_geom_string(drive, "drive", na_ok = TRUE)
  carries <- .st_geom_string(carries, "carries", na_ok = TRUE)
  date_start <- .st_geom_date(date_start, "date_start")
  source <- .st_geom_string(source, "source", na_ok = TRUE)
  comments <- .st_geom_string(comments, "comments", na_ok = TRUE)
  new_uuid <- uuid::UUIDgenerate()
  with_db_write(function(con) {
    .st_require_feature_register(con, what)
    db_transaction(con, function(con) {
      if (is.na(drive) || !drive %in% .st_flow_drives) {
        .st_geom_abort("{what}: {.arg drive} must be one of {.val {(.st_flow_drives)}}, not {.val {drive}}.")
      }
      if (is.na(source) || !nzchar(trimws(source))) .st_geom_abort("{what}: {.arg source} must not be blank.")
      if (identical(uuid_from, uuid_to)) {
        .st_geom_abort("{what}: a link needs two different features ({.val {uuid_from}} twice).")
      }
      .st_reg_feature(con, uuid_from, what)
      .st_reg_feature(con, uuid_to, what)
      w <- DBI::dbGetQuery(con, "SELECT uuid, date_start, date_end FROM feature_flow
                                 WHERE uuid_from = ? AND uuid_to = ?", params = list(uuid_from, uuid_to))
      clash <- w$uuid[.st_windows_overlap(date_start, as.Date(NA), w$date_start, w$date_end)]
      if (length(clash)) {
        .st_geom_abort(paste0(
          "{what}: the window overlaps the existing link {.val {clash[[1]]}} from {.val {uuid_from}} to ",
          "{.val {uuid_to}}; end it first (end_feature_flow()) and start the new one after its end."))
      }
      db_append(con, "feature_flow", tibble::tibble(
        uuid = new_uuid, uuid_from = uuid_from, uuid_to = uuid_to, carries = carries, drive = drive,
        date_start = date_start, date_end = as.Date(NA), source = source, comments = comments
      ), actor = actor, reason = reason)
    })
  }, db = db)
  invisible(new_uuid)
}

#' End a flow link
#'
#' Sets the link's `date_end` (inclusive), once.
#'
#' Refused (nothing written): a link that does not exist; one already ended; a
#' `date_end` before the link's `date_start`; an `NA` `date_end`; a database
#' that migration 117 has not reached.
#'
#' @param uuid the link's uuid.
#' @param date_end the link's last day: a `Date` or `"YYYY-MM-DD"`.
#' @inheritParams end_feature
#' @return `uuid`, invisibly.
#' @seealso [add_feature_flow()]
#' @export
end_feature_flow <- function(uuid, date_end, actor, reason, db = st_config("live_db")) {
  what <- "end_feature_flow()"
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  date_end <- .st_reg_date_required(date_end, "date_end", what)
  with_db_write(function(con) {
    .st_require_feature_register(con, what)
    db_transaction(con, function(con) {
      w <- DBI::dbGetQuery(con, "SELECT * FROM feature_flow WHERE uuid = ?", params = list(uuid))
      if (nrow(w) == 0L) .st_geom_abort("{what}: no feature_flow row {.val {uuid}}.")
      if (!is.na(w$date_end)) .st_geom_abort("{what}: link {.val {uuid}} is already ended ({w$date_end}).")
      if (!is.na(w$date_start) && date_end < w$date_start) {
        .st_geom_abort("{what}: date_end {date_end} is before the link's date_start ({w$date_start}).")
      }
      db_update(con, "feature_flow", uuid = uuid, changes = list(date_end = date_end),
                actor = actor, reason = reason)
    })
  }, db = db)
  invisible(uuid)
}

# ---- labels -----------------------------------------------------------------------------------

# Every feature with its systematic name and the `common` and `long` mask names
# whose windows hold the date (one positional parameter). Where two rows of a
# variant hold the date (an overlap the checks report), the latest-starting
# wins, then the lower uuid.
.st_feature_label_candidates_sql <- "
WITH d AS (SELECT CAST(? AS DATE) AS d),
m AS (
  SELECT fm.uuid_feature, fm.variant, fm.name,
         row_number() OVER (PARTITION BY fm.uuid_feature, fm.variant
                            ORDER BY fm.date_start DESC NULLS LAST, fm.uuid) AS rn
  FROM feature_mask fm, d
  WHERE fm.variant IN ('common', 'long') AND fm.name IS NOT NULL AND trim(fm.name) <> ''
    AND (fm.date_start IS NULL OR fm.date_start <= d.d)
    AND (fm.date_end IS NULL OR fm.date_end >= d.d)
),
cand AS (
  SELECT f.uuid, f.name AS systematic, c.name AS common, l.name AS long
  FROM feature f
  LEFT JOIN m c ON c.uuid_feature = f.uuid AND c.variant = 'common' AND c.rn = 1
  LEFT JOIN m l ON l.uuid_feature = f.uuid AND l.variant = 'long' AND l.rn = 1
)"

#' The SQL of [feature_labels()] for the default `prefer` (common, then
#' systematic), for readers that hold only an extract: one positional date
#' parameter; returns `uuid`, `label`, `kind`.
#' @keywords internal
#' @noRd
.st_feature_label_sql <- paste0(.st_feature_label_candidates_sql, "
SELECT uuid, coalesce(common, systematic) AS label,
       CASE WHEN common IS NOT NULL THEN 'common' ELSE 'systematic' END AS kind
FROM cand ORDER BY uuid")

#' Label features by their common, systematic or long name on a date
#'
#' The one implementation of the label rule (PLAN-23 2.5 rule 5): for each
#' feature, the first name in `prefer` that it has on `date`. `"common"` is the
#' `common` mask row whose window holds `date`; `"systematic"` is
#' `feature.name`; `"long"` is the `long` mask row holding `date`. Common is
#' the default for anything read on site; a feature with no common name on the
#' date falls back to its systematic name. If no name in `prefer` applies, the
#' systematic name is used. Reads only.
#'
#' @param con an open DBI connection.
#' @param uuids feature uuids to label, or `NULL` for every feature. A uuid
#'   that is not a feature gets `NA` label and kind.
#' @param date the date the labels are read on (`Date` or `"YYYY-MM-DD"`).
#' @param prefer the order to try the names in: some or all of `"common"`,
#'   `"systematic"`, `"long"`.
#' @return a data.frame with columns `uuid`, `label` and `kind` (which name was
#'   used), one row per feature (in `uuids` order when given).
#' @seealso [set_feature_mask()]
#' @export
feature_labels <- function(con, uuids = NULL, date = Sys.Date(),
                           prefer = c("common", "systematic", "long")) {
  what <- "feature_labels()"
  if (!is.null(uuids)) checkmate::assert_character(uuids, any.missing = FALSE)
  date <- .st_reg_date_required(date, "date", what)
  kinds <- c("common", "systematic", "long")
  if (!is.character(prefer) || length(prefer) == 0L || anyNA(prefer) ||
      !all(prefer %in% kinds) || anyDuplicated(prefer)) {
    .st_geom_abort("{what}: {.arg prefer} must be distinct values from {.val {kinds}}.")
  }
  .st_require_feature_register(con, what)
  cand <- DBI::dbGetQuery(con, paste0(.st_feature_label_candidates_sql, "
SELECT uuid, systematic, common, long FROM cand ORDER BY uuid"), params = list(date))
  if (!is.null(uuids)) {
    cand <- cand[match(uuids, cand$uuid), , drop = FALSE]
    cand$uuid <- uuids
  }
  label <- rep(NA_character_, nrow(cand))
  kind <- rep(NA_character_, nrow(cand))
  for (k in c(prefer, "systematic")) {
    v <- cand[[k]]
    take <- is.na(label) & !is.na(v)
    label[take] <- v[take]
    kind[take] <- k
  }
  data.frame(uuid = as.character(cand$uuid), label = label, kind = kind, stringsAsFactors = FALSE)
}
