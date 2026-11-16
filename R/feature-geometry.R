# PLAN-23 (the site feature register): the DDL, vocabularies, WKT reader and
# geometry functions.
#
# `feature` carries no coordinates. A position (or a line, or an area) is a row
# of `feature_geometry`, in EPSG:7856 (GDA2020 / MGA zone 56) metres, and is
# read back through the view `v_feature_location`. A geometry row is NEVER
# edited in place: `superseded` and `date_end` are stamped once, a correction
# adds a row that names its predecessor in `supersedes`, and nothing is
# deleted.
#
# The DDL constants below are the single source: a deployment migration executes
# them, and the test fixture is checked against them. `ensure_schema()` does
# NOT create these tables - DuckDB cannot drop a column or a constraint on a
# table a foreign key points at, so `feature` is rebuilt by an operator-run
# migration against a verified backup, never by the package (A50).
#
# Everything here is plain R and plain DuckDB SQL: no `sf`, no spatial
# extension. Converting from other datums is the caller's job.

# ---- vocabularies and ranges -------------------------------------------------

#' EPSG code every `feature_geometry.geom_wkt` is stored in (GDA2020 / MGA 56).
#' @keywords internal
#' @noRd
.st_geometry_epsg <- 7856L

#' @keywords internal
#' @noRd
.st_geometry_roles <- c("location", "extent", "route", "outline")

#' The WKT types each role allows.
#' @keywords internal
#' @noRd
.st_geometry_role_types <- list(
  location = "POINT",
  route = c("LINESTRING", "MULTILINESTRING"),
  extent = c("POLYGON", "MULTIPOLYGON"),
  outline = c("POLYGON", "MULTIPOLYGON")
)

#' @keywords internal
#' @noRd
.st_geometry_qualities <- c("surveyed", "field_gps", "plan", "imagery", "inferred", "approximate")

#' The valid range of any southern-hemisphere MGA/UTM grid, in metres. A point
#' stored in degrees (`150.6 -33.7`) falls outside it.
#' @keywords internal
#' @noRd
.st_geometry_grid_range <- c(xmin = 100000, ymin = 1000000, xmax = 900000, ymax = 10000000)

#' The `feature.class` vocabulary: generic words only. A deployment extends it
#' through `st_config("feature_classes_extra")` (for `add_feature()`) and
#' `db_checks_params(feature_classes =)` (for the check).
#' @keywords internal
#' @noRd
.st_feature_classes <- c(
  "bore", "gas_well", "gas_point", "dust_gauge", "weather_station", "surface_point",
  "seep", "tap", "dam", "pond", "cell", "landfill", "gas_field", "wall", "sump", "pit",
  "pump", "valve", "meter", "pipe", "drain", "culvert", "inlet", "headwall", "aerator",
  "dosing_unit", "tank", "switchboard", "telemetry", "building", "cable"
)

# ---- DDL (executed by migration 117; one string per table, `;`-separated) -----

#' @keywords internal
#' @noRd
.st_core_ddl_feature <- "
CREATE TABLE feature (
  uuid         VARCHAR PRIMARY KEY,
  name         VARCHAR NOT NULL,
  site         VARCHAR NOT NULL,
  class        VARCHAR,
  flow         VARCHAR,
  matrix       VARCHAR,
  depth        DOUBLE,
  installed_by VARCHAR,
  permanent    BOOLEAN,
  reference    BOOLEAN,
  date_start   DATE,
  date_end     DATE,
  cypher       VARCHAR,
  elevation    DOUBLE,
  uuid_project VARCHAR,
  comments     VARCHAR,
  virtual      BOOLEAN DEFAULT FALSE
);
CREATE INDEX idx_feature_site ON feature(site)"

#' @keywords internal
#' @noRd
.st_core_ddl_feature_mask <- "
CREATE TABLE feature_mask (
  uuid_feature VARCHAR NOT NULL REFERENCES feature(uuid),
  variant      VARCHAR NOT NULL,
  name         VARCHAR,
  PRIMARY KEY (uuid_feature, variant)
);
CREATE INDEX idx_feature_mask_variant ON feature_mask(variant)"

# No foreign key to `feature` on purpose: it would drag this table into the
# next `feature` rebuild. `orphan_feature_geometry` checks the link instead.
#' @keywords internal
#' @noRd
.st_core_ddl_feature_geometry <- "
CREATE TABLE feature_geometry (
  uuid         VARCHAR PRIMARY KEY,
  uuid_feature VARCHAR NOT NULL,
  role         VARCHAR NOT NULL,
  geom_wkt     VARCHAR NOT NULL,
  source       VARCHAR NOT NULL,
  source_crs   VARCHAR NOT NULL,
  quality      VARCHAR NOT NULL,
  date_start   DATE,
  date_end     DATE,
  recorded     TIMESTAMP NOT NULL,
  supersedes   VARCHAR UNIQUE REFERENCES feature_geometry(uuid),
  superseded   TIMESTAMP,
  comments     VARCHAR,
  CHECK (date_start IS NULL OR date_end IS NULL OR date_end >= date_start),
  CHECK (supersedes IS NULL OR supersedes <> uuid)
);
CREATE INDEX idx_feature_geometry_feature ON feature_geometry(uuid_feature)"

# One row per feature that has a current `location` row (see PLAN-23 2.3 for
# which piece is chosen, and for the inverse transverse Mercator it spells out
# in SQL: no spatial extension exists).
#' @keywords internal
#' @noRd
.st_view_feature_location_sql <- r"---(CREATE VIEW v_feature_location AS
WITH loc AS (
  SELECT g.uuid AS uuid_geometry, g.uuid_feature, g.quality, g.source, g.source_crs,
         g.date_start, g.date_end, g.recorded,
         TRY_CAST(regexp_extract(upper(g.geom_wkt),
           '^\s*POINT\s*\(\s*([-+0-9.E]+)\s+([-+0-9.E]+)\s*\)\s*$', 1) AS DOUBLE) AS easting,
         TRY_CAST(regexp_extract(upper(g.geom_wkt),
           '^\s*POINT\s*\(\s*([-+0-9.E]+)\s+([-+0-9.E]+)\s*\)\s*$', 2) AS DOUBLE) AS northing
  FROM feature_geometry g
  WHERE g.role = 'location' AND g.superseded IS NULL
  QUALIFY row_number() OVER (
    PARTITION BY g.uuid_feature
    ORDER BY (g.date_end IS NULL) DESC, g.date_end DESC NULLS LAST, g.recorded DESC, g.uuid) = 1
),
k AS (
  -- GRS80; MGA2020 zone 56 (EPSG:7856): k0 0.9996, E0 500000, N0 10000000, CM 153
  SELECT (1 / 298.257222101) / (2 - 1 / 298.257222101) AS n
),
t1 AS (
  SELECT loc.*, k.n,
    (northing - 10000000) / (0.9996 * 6378137 / (1 + k.n) * (1 + k.n^2 / 4 + k.n^4 / 64)) AS xi1,
    (easting - 500000)    / (0.9996 * 6378137 / (1 + k.n) * (1 + k.n^2 / 4 + k.n^4 / 64)) AS eta1,
    k.n / 2 - 2 * k.n^2 / 3 + 37 * k.n^3 / 96 - k.n^4 / 360 AS b1,
    k.n^2 / 48 + k.n^3 / 15 - 437 * k.n^4 / 1440            AS b2,
    17 * k.n^3 / 480 - 37 * k.n^4 / 840                      AS b3,
    4397 * k.n^4 / 161280                                    AS b4
  FROM loc, k
),
t2 AS (
  SELECT *,
    xi1 - (b1 * sin(2 * xi1) * cosh(2 * eta1) + b2 * sin(4 * xi1) * cosh(4 * eta1)
         + b3 * sin(6 * xi1) * cosh(6 * eta1) + b4 * sin(8 * xi1) * cosh(8 * eta1)) AS xi,
    eta1 - (b1 * cos(2 * xi1) * sinh(2 * eta1) + b2 * cos(4 * xi1) * sinh(4 * eta1)
          + b3 * cos(6 * xi1) * sinh(6 * eta1) + b4 * cos(8 * xi1) * sinh(8 * eta1)) AS eta
  FROM t1
),
t3 AS (
  SELECT *, asin(sin(xi) / cosh(eta)) AS chi, atan2(sinh(eta), cos(xi)) AS dlon FROM t2
)
SELECT t3.uuid_feature, f.name, f.site, f.class, t3.uuid_geometry,
       t3.easting, t3.northing,
       153 + degrees(t3.dlon) AS lon,
       degrees(t3.chi
         + (2 * n - 2 * n^2 / 3 - 2 * n^3 + 116 * n^4 / 45) * sin(2 * t3.chi)
         + (7 * n^2 / 3 - 8 * n^3 / 5 - 227 * n^4 / 45)    * sin(4 * t3.chi)
         + (56 * n^3 / 15 - 136 * n^4 / 35)                 * sin(6 * t3.chi)
         + (4279 * n^4 / 630)                               * sin(8 * t3.chi)) AS lat,
       t3.quality, t3.source, t3.source_crs, t3.date_start, t3.date_end, t3.recorded
FROM t3 JOIN feature f ON f.uuid = t3.uuid_feature;)---"

#' Has this database been through migration 117?
#'
#' `TRUE` when the table `feature_geometry` exists AND `feature` has no column
#' `lon`; `FALSE` on a pre-117 database. Every register function and check
#' asks this first, so the package still opens a database that is in the old
#' shape.
#' @param con an open DBI connection.
#' @keywords internal
#' @noRd
.st_has_feature_register <- function(con) {
  has_geom <- nrow(DBI::dbGetQuery(
    con, "SELECT 1 FROM information_schema.tables WHERE table_name = 'feature_geometry' LIMIT 1")) > 0
  if (!has_geom) return(FALSE)
  has_lon <- nrow(DBI::dbGetQuery(
    con, "SELECT 1 FROM information_schema.columns
          WHERE table_name = 'feature' AND column_name = 'lon' LIMIT 1")) > 0
  !has_lon
}

# ---- the WKT reader ----------------------------------------------------------
#
# "Valid" means WELL-FORMED, not OGC-valid: without GEOS there is no
# self-intersection test, and none is attempted.

.st_wkt_number_re <- "^[-+]?[0-9]+(\\.[0-9]+)?([eE][-+]?[0-9]+)?$"
.st_wkt_nesting <- c(POINT = 0L, LINESTRING = 0L, POLYGON = 1L, MULTILINESTRING = 1L, MULTIPOLYGON = 2L)

.st_wkt_empty <- function(problem) {
  list(type = NA_character_, coords = matrix(numeric(0), ncol = 2L), parts = list(), problem = problem)
}

#' Parse one WKT string (2-D POINT, LINESTRING, POLYGON, MULTILINESTRING or
#' MULTIPOLYGON).
#' @param wkt one string.
#' @return `list(type, coords, parts, problem)`: the upper-case type, every
#'   vertex as an n x 2 numeric matrix, the lines or rings as a list of
#'   matrices, and `problem` (`NA` when well-formed, else a short reason).
#' @keywords internal
#' @noRd
.st_wkt_parse <- function(wkt) {
  if (length(wkt) != 1L || is.na(wkt) || !is.character(wkt)) return(.st_wkt_empty("missing"))
  txt <- trimws(wkt)
  if (!nzchar(txt)) return(.st_wkt_empty("empty"))
  m <- regmatches(txt, regexec("^([A-Za-z]+)\\s*(\\(.*\\))$", txt, perl = TRUE))[[1]]
  if (length(m) != 3L) return(.st_wkt_empty("not a supported WKT form"))
  type <- toupper(m[[2]])
  if (!type %in% names(.st_wkt_nesting)) {
    return(.st_wkt_empty(paste0("unsupported geometry type ", type)))
  }
  toks <- regmatches(m[[3]], gregexpr("[(),]|[^(),[:space:]]+", m[[3]], perl = TRUE))[[1]]
  i <- 1L
  fail <- function(why) stop(structure(class = c("st_wkt_problem", "error", "condition"),
                                       list(message = why, call = NULL)))
  position <- function() {
    # two numbers, then "," or ")"
    vals <- character()
    while (i <= length(toks) && !toks[[i]] %in% c(",", ")", "(")) {
      vals <- c(vals, toks[[i]]); i <<- i + 1L
    }
    if (length(vals) != 2L) fail("a position must be exactly two numbers")
    if (!all(grepl(.st_wkt_number_re, vals))) fail("a coordinate is not a number")
    v <- as.numeric(vals)
    if (!all(is.finite(v))) fail("a coordinate is not finite")
    v
  }
  group <- function(level) {
    if (i > length(toks) || toks[[i]] != "(") fail("expected '('")
    i <<- i + 1L
    out <- list()
    repeat {
      out[[length(out) + 1L]] <- if (level == 0L) position() else group(level - 1L)
      if (i > length(toks)) fail("unbalanced parentheses")
      if (toks[[i]] == ",") { i <<- i + 1L; next }
      if (toks[[i]] == ")") { i <<- i + 1L; break }
      fail("unexpected token")
    }
    out
  }
  res <- tryCatch({
    tree <- group(.st_wkt_nesting[[type]])
    if (i <= length(toks)) fail("text after the closing parenthesis")
    tree
  }, st_wkt_problem = function(e) e)
  if (inherits(res, "condition")) return(.st_wkt_empty(conditionMessage(res)))

  # flatten to a list of position-matrices (the lines or rings)
  lvl <- .st_wkt_nesting[[type]]
  flatten <- function(node, level) {
    if (level == 0L) return(list(do.call(rbind, node)))
    unlist(lapply(node, flatten, level = level - 1L), recursive = FALSE)
  }
  parts <- flatten(res, lvl)
  problem <- NA_character_
  if (type == "POINT") {
    if (nrow(parts[[1]]) != 1L) problem <- "a POINT has exactly one position"
  } else if (type %in% c("LINESTRING", "MULTILINESTRING")) {
    for (p in parts) {
      if (nrow(p) < 2L) { problem <- "a line needs at least 2 positions"; break }
      if (nrow(unique(p)) < 2L) { problem <- "a line's positions are all identical"; break }
    }
  } else {
    for (p in parts) {
      if (nrow(p) < 4L) { problem <- "a ring needs at least 4 positions"; break }
      if (!identical(unname(p[1L, ]), unname(p[nrow(p), ]))) { problem <- "a ring is not closed"; break }
    }
  }
  coords <- do.call(rbind, parts)
  colnames(coords) <- NULL
  list(type = type, coords = coords, parts = parts, problem = problem)
}

#' Check WKT strings: `NA` for fine, else the problem.
#'
#' Vectorised over `wkt`; `role` (recycled) additionally requires the geometry
#' type to be one the role allows. A role outside the vocabulary adds no type
#' problem here (`vocab_feature_geometry` reports it).
#' @param wkt character vector.
#' @param role `NULL`, or a character vector of roles.
#' @return a character vector as long as `wkt`.
#' @keywords internal
#' @noRd
.st_wkt_check <- function(wkt, role = NULL) {
  n <- length(wkt)
  if (n == 0L) return(character(0))
  roles <- if (is.null(role)) rep(NA_character_, n) else rep_len(as.character(role), n)
  out <- rep(NA_character_, n)
  for (k in seq_len(n)) {
    p <- .st_wkt_parse(wkt[[k]])
    if (!is.na(p$problem)) { out[[k]] <- p$problem; next }
    r <- roles[[k]]
    allowed <- if (is.na(r)) NULL else .st_geometry_role_types[[r]]
    if (!is.null(allowed) && !p$type %in% allowed) {
      out[[k]] <- paste0("a ", p$type, " cannot be a ", r, " (allowed: ", paste(allowed, collapse = ", "), ")")
    }
  }
  out
}

# Does any vertex lie outside a c(xmin, ymin, xmax, ymax) box?
.st_coords_outside <- function(coords, box) {
  nrow(coords) > 0L && any(coords[, 1] < box[["xmin"]] | coords[, 1] > box[["xmax"]] |
                             coords[, 2] < box[["ymin"]] | coords[, 2] > box[["ymax"]])
}

# ---- name key ------------------------------------------------------------------

#' The canonical key of a feature name: upper case, leading zeros dropped from
#' every digit run, over the WHOLE trimmed name. Reuses `.rc_canonical_point()`;
#' it is not a second normaliser.
#' @keywords internal
#' @noRd
.st_feature_name_key <- function(x) .rc_canonical_point(trimws(x))

# ---- the geometry functions -----------------------------------------------------

.st_geom_abort <- function(msg, .envir = parent.frame()) {
  cli::cli_abort(msg, class = "sampletidy_error", .envir = .envir)
}

# Abort on a database that migration 117 has not reached.
.st_require_feature_register <- function(con, what) {
  if (!.st_has_feature_register(con)) {
    .st_geom_abort(paste0(
      what, ": this database has not had migration 117 applied (the site feature ",
      "register: `feature_geometry`, and `feature` without `lon`/`lat`). Run the ",
      "migration first."))
  }
  invisible(TRUE)
}

# A Date from a Date or a YYYY-MM-DD string; NA is unknown. NULL stays NULL.
.st_geom_date <- function(x, arg) {
  if (is.null(x)) return(NULL)
  if (length(x) != 1L) .st_geom_abort("{.arg {arg}} must be a single date (or NA).")
  if (inherits(x, "Date")) return(x)
  if (is.na(x)) return(as.Date(NA))
  d <- if (is.character(x)) tryCatch(as.Date(x, format = "%Y-%m-%d"), error = function(e) as.Date(NA))
       else as.Date(NA)
  if (is.na(d)) .st_geom_abort("{.arg {arg}} must be a Date or a YYYY-MM-DD string, not {.val {x}}.")
  d
}

# A string argument that may be NA (comments) or not (the rest).
.st_geom_string <- function(x, arg, na_ok = FALSE) {
  if (!(is.character(x) && length(x) == 1L && (na_ok || !is.na(x)))) {
    .st_geom_abort("{.arg {arg}} must be a single string{if (na_ok) ' (or NA)' else ''}.")
  }
  x
}

# The first problem with a would-be geometry row, or NULL. `con` is only used
# to confirm that the feature exists.
.st_geom_problem <- function(con, uuid_feature, role, geom_wkt, source, source_crs, quality,
                             date_start, date_end) {
  ex <- DBI::dbGetQuery(con, "SELECT 1 AS one FROM feature WHERE uuid = ?", params = list(uuid_feature))
  if (nrow(ex) == 0L) return(paste0("uuid_feature ", encodeString(uuid_feature, quote = "'"), " is not a feature"))
  if (is.na(role) || !role %in% .st_geometry_roles) {
    return(paste0("role must be one of ", paste(.st_geometry_roles, collapse = ", ")))
  }
  if (is.na(quality) || !quality %in% .st_geometry_qualities) {
    return(paste0("quality must be one of ", paste(.st_geometry_qualities, collapse = ", ")))
  }
  if (is.na(source_crs) || !(grepl("^EPSG:[0-9]+$", source_crs) || identical(source_crs, "unknown"))) {
    return("source_crs must be 'EPSG:<digits>' or 'unknown'")
  }
  if (is.na(source) || !nzchar(trimws(source))) return("source must not be blank")
  p <- .st_wkt_check(geom_wkt, role)
  if (!is.na(p)) return(paste0("geom_wkt: ", p))
  if (.st_coords_outside(.st_wkt_parse(geom_wkt)$coords, .st_geometry_grid_range)) {
    return(paste0("geom_wkt has a vertex outside the MGA grid range (is it in degrees? ",
                  "geometry is stored in EPSG:", .st_geometry_epsg, " metres)"))
  }
  if (!is.na(date_start) && !is.na(date_end) && date_end < date_start) {
    return("date_end is before date_start")
  }
  NULL
}

# `recorded`/`superseded` stamp: now, to the millisecond (so the stamp the new
# row and the old row carry is one exact instant however it is bound).
.st_geom_now <- function() {
  as.POSIXct(floor(as.numeric(Sys.time()) * 1000) / 1000, origin = "1970-01-01", tz = "UTC")
}

.st_geom_row <- function(con, uuid) {
  DBI::dbGetQuery(con, "SELECT * FROM feature_geometry WHERE uuid = ?", params = list(uuid))
}

# The row `uuid`, or abort; `current` additionally refuses a superseded row.
.st_geom_fetch <- function(con, uuid, what, current = TRUE) {
  row <- .st_geom_row(con, uuid)
  if (nrow(row) == 0L) .st_geom_abort("{what}: no feature_geometry row {.val {uuid}}.")
  if (current && !is.na(row$superseded)) {
    .st_geom_abort(paste0(
      "{what}: row {.val {uuid}} was already superseded; act on the current version, ",
      "not on history."))
  }
  row
}

#' Add a geometry piece to a feature
#'
#' Inserts one row into `feature_geometry`: a position (`role = "location"`),
#' a line (`"route"`) or an area (`"extent"`, `"outline"`) for an existing
#' feature, in EPSG:7856 metres. The row is new and current
#' (`supersedes` and `superseded` are `NA`); `recorded` is now. Nothing is
#' reprojected: convert from other datums first.
#'
#' A geometry row is never edited in place. To correct one use
#' [supersede_feature_geometry()]; to retract a drawing made in error use
#' [withdraw_feature_geometry()]; for a change on the ground use
#' [end_feature_geometry()] or [replace_feature_geometry()].
#'
#' Refused (nothing written): an unknown feature; a `role`, `quality` or
#' `source_crs` outside its vocabulary; a blank `source`; a malformed
#' `geom_wkt`, one whose type does not suit the role, or one with a vertex
#' outside the MGA grid range (a point in degrees falls outside it);
#' `date_end` before `date_start`; and a second in-use `location` (one with no
#' `date_end`) for a feature that already has one. On a database that
#' migration 117 has not reached it aborts saying so.
#'
#' @param uuid_feature the feature's `uuid`.
#' @param role one of `"location"`, `"extent"`, `"route"`, `"outline"`.
#' @param geom_wkt 2-D WKT in EPSG:7856 (easting, northing): a `POINT` for a
#'   location, a `LINESTRING` or `MULTILINESTRING` for a route, a `POLYGON` or
#'   `MULTIPOLYGON` for an extent or outline.
#' @param source where the drawing came from, as free text; never blank.
#' @param source_crs the coordinate reference system the source was in before
#'   conversion: `"EPSG:<digits>"` or `"unknown"`.
#' @param quality one of `"surveyed"`, `"field_gps"`, `"plan"`, `"imagery"`,
#'   `"inferred"`, `"approximate"`.
#' @param date_start,date_end when this piece existed on the ground, both ends
#'   inclusive: `Date`s or `"YYYY-MM-DD"` strings; `NA` means unknown or open.
#' @param comments free text, optional.
#' @param actor who is making this change.
#' @param reason free-text reason, stored on the `change_log` row.
#' @param db path to the DuckDB database file (default the live one).
#' @return the new geometry row's uuid, invisibly.
#' @seealso [supersede_feature_geometry()], [withdraw_feature_geometry()],
#'   [end_feature_geometry()], [replace_feature_geometry()]
#' @export
add_feature_geometry <- function(uuid_feature, role, geom_wkt, source, source_crs, quality,
                                 date_start = as.Date(NA), date_end = as.Date(NA),
                                 comments = NA_character_, actor, reason,
                                 db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid_feature <- .st_geom_string(uuid_feature, "uuid_feature")
  role <- .st_geom_string(role, "role", na_ok = TRUE)
  quality <- .st_geom_string(quality, "quality", na_ok = TRUE)
  source_crs <- .st_geom_string(source_crs, "source_crs", na_ok = TRUE)
  source <- .st_geom_string(source, "source", na_ok = TRUE)
  comments <- .st_geom_string(comments, "comments", na_ok = TRUE)
  geom_wkt <- if (length(geom_wkt) == 1L && (is.na(geom_wkt) || is.character(geom_wkt))) geom_wkt else
    .st_geom_abort("{.arg geom_wkt} must be a single string.")
  date_start <- .st_geom_date(date_start, "date_start")
  date_end <- .st_geom_date(date_end, "date_end")
  new_uuid <- uuid::UUIDgenerate()
  with_db_write(function(con) {
    .st_require_feature_register(con, "add_feature_geometry()")
    db_transaction(con, function(con) {
      p <- .st_geom_problem(con, uuid_feature, role, geom_wkt, source, source_crs, quality,
                            date_start, date_end)
      if (!is.null(p)) .st_geom_abort("add_feature_geometry(): {p}.")
      if (identical(role, "location") && is.na(date_end)) {
        n <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM feature_geometry
                                   WHERE uuid_feature = ? AND role = 'location'
                                     AND superseded IS NULL AND date_end IS NULL",
                             params = list(uuid_feature))$n
        if (n > 0) {
          .st_geom_abort(paste0(
            "add_feature_geometry(): feature {.val {uuid_feature}} already has an in-use ",
            "location; supersede, withdraw or end-date it first."))
        }
      }
      row <- tibble::tibble(
        uuid = new_uuid, uuid_feature = uuid_feature, role = role, geom_wkt = geom_wkt,
        source = source, source_crs = source_crs, quality = quality,
        date_start = date_start, date_end = date_end, recorded = .st_geom_now(),
        supersedes = NA_character_, superseded = as.POSIXct(NA), comments = comments
      )
      db_append(con, "feature_geometry", row, actor = actor, reason = reason)
    })
  }, db = db)
  invisible(new_uuid)
}

#' Correct a geometry piece (supersede it)
#'
#' For when the drawing, or its metadata, was wrong. Inserts a new row that
#' copies the old row's feature and role and every field left `NULL` in the
#' call, with `supersedes` naming the old row and a fresh `recorded`, then
#' stamps the old row's `superseded` with the same instant. The old row is
#' otherwise untouched. The new row is validated as in
#' [add_feature_geometry()], except that the in-use-location rule does not
#' apply (the old row is leaving).
#'
#' Refused (nothing written): a missing row; a row already superseded (correct
#' the current version, not history); a call that supplies nothing, or only
#' values equal to the old row's; a new row that fails validation; a
#' database that migration 117 has not reached.
#'
#' @param uuid the geometry row to correct.
#' @param geom_wkt,source,source_crs,quality,date_start,date_end,comments the
#'   replacement values, as for [add_feature_geometry()]; `NULL` keeps the old
#'   row's value (`NA` for a date or `comments` sets it to unknown).
#' @inheritParams add_feature_geometry
#' @return the new row's uuid, invisibly.
#' @seealso [withdraw_feature_geometry()], [replace_feature_geometry()]
#' @export
supersede_feature_geometry <- function(uuid, geom_wkt = NULL, source = NULL, source_crs = NULL,
                                       quality = NULL, date_start = NULL, date_end = NULL,
                                       comments = NULL, actor, reason,
                                       db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  for (a in c("geom_wkt", "source", "source_crs", "quality", "comments")) {
    v <- get(a)
    if (!is.null(v)) .st_geom_string(v, a, na_ok = TRUE)
  }
  date_start <- .st_geom_date(date_start, "date_start")
  date_end <- .st_geom_date(date_end, "date_end")
  new_uuid <- uuid::UUIDgenerate()
  with_db_write(function(con) {
    .st_require_feature_register(con, "supersede_feature_geometry()")
    db_transaction(con, function(con) {
      old <- .st_geom_fetch(con, uuid, "supersede_feature_geometry()")
      supplied <- list(geom_wkt = geom_wkt, source = source, source_crs = source_crs,
                       quality = quality, date_start = date_start, date_end = date_end,
                       comments = comments)
      supplied <- supplied[!vapply(supplied, is.null, NA)]
      differs <- vapply(names(supplied), function(f) {
        !identical(.st_changelog_str(supplied[[f]]), .st_changelog_str(old[[f]]))
      }, NA)
      if (!any(differs)) {
        .st_geom_abort(paste0(
          "supersede_feature_geometry(): nothing to correct; no supplied field differs ",
          "from row {.val {uuid}}."))
      }
      new <- lapply(c(geom_wkt = "geom_wkt", source = "source", source_crs = "source_crs",
                      quality = "quality", date_start = "date_start", date_end = "date_end",
                      comments = "comments"),
                    function(f) if (!is.null(supplied[[f]])) supplied[[f]] else old[[f]])
      p <- .st_geom_problem(con, old$uuid_feature, old$role, new$geom_wkt, new$source,
                            new$source_crs, new$quality, new$date_start, new$date_end)
      if (!is.null(p)) .st_geom_abort("supersede_feature_geometry(): {p}.")
      now <- .st_geom_now()
      old_uuid <- uuid
      row <- tibble::tibble(
        uuid = new_uuid, uuid_feature = old$uuid_feature, role = old$role,
        geom_wkt = new$geom_wkt, source = new$source, source_crs = new$source_crs,
        quality = new$quality, date_start = new$date_start, date_end = new$date_end,
        recorded = now, supersedes = old_uuid, superseded = as.POSIXct(NA), comments = new$comments
      )
      db_append(con, "feature_geometry", row, actor = actor, reason = reason)
      db_update(con, "feature_geometry", uuid = uuid, changes = list(superseded = now),
                actor = actor, reason = reason)
    })
  }, db = db)
  invisible(new_uuid)
}

#' Withdraw a geometry piece drawn in error
#'
#' Stamps the row `superseded` and adds no successor, so the feature has no
#' current piece of that role. The row stays (nothing is deleted).
#'
#' Refused: a missing row, one already superseded, a database that migration
#' 117 has not reached.
#'
#' @param uuid the geometry row to withdraw.
#' @inheritParams add_feature_geometry
#' @return `uuid`, invisibly.
#' @export
withdraw_feature_geometry <- function(uuid, actor, reason, db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  with_db_write(function(con) {
    .st_require_feature_register(con, "withdraw_feature_geometry()")
    db_transaction(con, function(con) {
      .st_geom_fetch(con, uuid, "withdraw_feature_geometry()")
      db_update(con, "feature_geometry", uuid = uuid, changes = list(superseded = .st_geom_now()),
                actor = actor, reason = reason)
    })
  }, db = db)
  invisible(uuid)
}

#' End-date a geometry piece
#'
#' A change on the ground with no replacement drawn yet (a removed pipe): sets
#' `date_end` and nothing else. The row stays current, because it was true in
#' its time.
#'
#' Refused: a missing row, a superseded row, a row that already has a
#' `date_end`, `date_end` before the row's `date_start`, an `NA` `date_end`, a
#' database that migration 117 has not reached.
#'
#' @param uuid the geometry row to end.
#' @param date_end the last day it existed (inclusive): a `Date` or
#'   `"YYYY-MM-DD"`.
#' @inheritParams add_feature_geometry
#' @return `uuid`, invisibly.
#' @seealso [replace_feature_geometry()]
#' @export
end_feature_geometry <- function(uuid, date_end, actor, reason, db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  date_end <- .st_geom_date(date_end, "date_end")
  if (is.na(date_end)) .st_geom_abort("end_feature_geometry(): {.arg date_end} must be a date.")
  with_db_write(function(con) {
    .st_require_feature_register(con, "end_feature_geometry()")
    db_transaction(con, function(con) {
      old <- .st_geom_fetch(con, uuid, "end_feature_geometry()")
      if (!is.na(old$date_end)) {
        .st_geom_abort("end_feature_geometry(): row {.val {uuid}} already has a date_end.")
      }
      if (!is.na(old$date_start) && date_end < old$date_start) {
        .st_geom_abort("end_feature_geometry(): date_end is before the row's date_start.")
      }
      db_update(con, "feature_geometry", uuid = uuid, changes = list(date_end = date_end),
                actor = actor, reason = reason)
    })
  }, db = db)
  invisible(uuid)
}

#' Replace a geometry piece after a change on the ground
#'
#' For a change on the ground whose new shape is known (a rerouted pipe).
#' Atomically ends the old row at `date_changed - 1` (ends are inclusive) and
#' adds a new row, from `date_changed`, with the old row's feature and role and
#' the supplied geometry and metadata. Both rows stay current; the new row does
#' not name the old one in `supersedes` (that is for corrections).
#'
#' Refused (nothing written, the old row is not ended): a missing row, a
#' superseded row, an already-ended row; `date_changed` on or before the old
#' row's `date_start`; a new row that fails validation (as in
#' [add_feature_geometry()]); a database that migration 117 has not reached.
#'
#' @param uuid the geometry row being replaced.
#' @param geom_wkt,source,source_crs,quality,comments the new row's values, as
#'   for [add_feature_geometry()].
#' @param date_changed the first day of the new row: a `Date` or
#'   `"YYYY-MM-DD"`.
#' @inheritParams add_feature_geometry
#' @return the new row's uuid, invisibly.
#' @seealso [end_feature_geometry()], [supersede_feature_geometry()]
#' @export
replace_feature_geometry <- function(uuid, geom_wkt, date_changed, source, source_crs, quality,
                                     comments = NA_character_, actor, reason,
                                     db = st_config("live_db")) {
  checkmate::assert_string(actor)
  checkmate::assert_string(reason)
  uuid <- .st_geom_string(uuid, "uuid")
  source <- .st_geom_string(source, "source", na_ok = TRUE)
  source_crs <- .st_geom_string(source_crs, "source_crs", na_ok = TRUE)
  quality <- .st_geom_string(quality, "quality", na_ok = TRUE)
  comments <- .st_geom_string(comments, "comments", na_ok = TRUE)
  geom_wkt <- if (length(geom_wkt) == 1L && (is.na(geom_wkt) || is.character(geom_wkt))) geom_wkt else
    .st_geom_abort("{.arg geom_wkt} must be a single string.")
  date_changed <- .st_geom_date(date_changed, "date_changed")
  if (is.na(date_changed)) .st_geom_abort("replace_feature_geometry(): {.arg date_changed} must be a date.")
  new_uuid <- uuid::UUIDgenerate()
  with_db_write(function(con) {
    .st_require_feature_register(con, "replace_feature_geometry()")
    db_transaction(con, function(con) {
      old <- .st_geom_fetch(con, uuid, "replace_feature_geometry()")
      if (!is.na(old$date_end)) {
        .st_geom_abort("replace_feature_geometry(): row {.val {uuid}} is already ended.")
      }
      if (!is.na(old$date_start) && date_changed <= old$date_start) {
        .st_geom_abort(paste0(
          "replace_feature_geometry(): date_changed must be after the old row's date_start ",
          "({old$date_start})."))
      }
      p <- .st_geom_problem(con, old$uuid_feature, old$role, geom_wkt, source, source_crs,
                            quality, date_changed, as.Date(NA))
      if (!is.null(p)) .st_geom_abort("replace_feature_geometry(): {p}.")
      db_update(con, "feature_geometry", uuid = uuid, changes = list(date_end = date_changed - 1),
                actor = actor, reason = reason)
      row <- tibble::tibble(
        uuid = new_uuid, uuid_feature = old$uuid_feature, role = old$role, geom_wkt = geom_wkt,
        source = source, source_crs = source_crs, quality = quality,
        date_start = date_changed, date_end = as.Date(NA), recorded = .st_geom_now(),
        supersedes = NA_character_, superseded = as.POSIXct(NA), comments = comments
      )
      db_append(con, "feature_geometry", row, actor = actor, reason = reason)
    })
  }, db = db)
  invisible(new_uuid)
}
