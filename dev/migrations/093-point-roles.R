# Operator-run migration: record what each monitoring point is FOR (its role), the
# features whose identity or position is doubted, one rename, and the positions of
# the old bores and Katoomba building gas points that sat on site-centroid
# placeholders. Marker 1093. Requires 1091 (independent of 1092: 092 changes K.G
# date_start and comments, never lon/lat, and this migration guards only the fields
# it writes). Authority: the data owner, 2026-10-29 (the edited role table v2 and
# the rulings on its open questions).
#
# ---- SCHEMA ----------------------------------------------------------------------
# Two side tables keyed by feature, created by .feature_role_create_schema()
# (R/feature-role.R), on the precedent of 048's qc_feature (a feature-level side
# table, no declared FOREIGN KEY) and 082's receipt schema (DDL held in package
# code, created by the migration that first needs it):
#   * feature_role(uuid_feature PK, water_type, role, source_cell, treatment,
#     lmf_end_member, end_member_note, comments): one row per monitoring point in
#     the role table (65). NULL source_cell / treatment = not applicable.
#   * feature_dubious(uuid_feature PK, reason, date_flagged): features whose
#     identity or position is doubted.
# The vocabularies (.st_water_types, .st_point_roles, .st_source_cells,
# .st_treatments) live in package code and are policed by the hourly error check
# vocab_feature_role, as feature.flow is by vocab_feature_flow; orphans by
# orphan_feature_role_refs. Not CHECK constraints: DuckDB cannot drop one.
#
# ---- WHAT IS WRITTEN -------------------------------------------------------------
# INPUT CSVs, frozen from the table (its section 1, where the owner's edits are):
#   * INPUT-roles.csv: water_type, role, source_cell, treatment per point.
#     lmf_end_member = role 'leachate' (the table's convention: all of a site's
#     leachate-role points are LMF end-members); K.L01 is one, noted 'very dilute'.
#     Rulings applied: K.L07's source_cell 'other' (the transfer station);
#     B.TS24's 'street sweepings'; B.L01 'partly treated'.
#   * INPUT-dubious.csv: feature + short reason.
#   * INPUT-renames.csv: K.TS24 -> K.L08. The feature row is renamed in place (same
#     uuid, so samples and assets follow); its old self alias row is kept, with its
#     uuid, as kind 'historical_code' (samples recorded against it keep pointing at
#     it, and the old code still resolves), and a new self alias is added. Position
#     left as stored (flagged dubious instead).
#   * INPUT-positions.csv: from (the stored placeholder, which must still be there)
#     -> new lon/lat; geom_wkt rewritten to agree; a dated note appended to
#     feature.comments giving the method and precision.
#   * INPUT-aliases.csv: the three one-off bottle mislabellings (another point's code
#     on one visit) must be single-day historical_code arms. Each is checked; one
#     found unbounded is bounded to its day (its samples must all fall on it); one
#     bounded otherwise stops the run.
# Feature notes start "093 (2026-10-29)" and are appended (existing text kept); a
# note already present is not added again.
#
# ---- PHASES ----------------------------------------------------------------------
# One transaction: create the two tables, the rename, role and dubious rows,
# positions, alias bounds, mig_db_checks_gate(), marker 1093. Before it: the
# feature and feature_alias rows that change go to BACKUP CSVs and the whole file is
# backed up and verified. After it: everything is re-checked against the INPUT, and
# the sample and analysis tables must be byte-identical (content digest) to before.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/093-point-roles.R", envir = env)
#   env$mig093_run(db = st_config("live_db"), snapshot_dir = ..., dry_run = TRUE)

.mig093_marker_version <- 1093L
.mig093_requires <- 1091L
.mig093_name <- "093-point-roles"
.mig093_actor <- .mig093_name
.mig093_day <- as.Date("2026-10-29")
.mig093_note_prefix <- "093 (2026-10-29)"
.mig093_tz <- "Australia/Sydney"

.mig093_cols <- list(
  roles = c("feature", "water_type", "role", "source_cell", "treatment", "lmf_end_member", "end_member_note", "comments"),
  dubious = c("feature", "reason"),
  renames = c("old", "new"),
  aliases = c("alias_name", "feature", "date"),
  positions = c("feature", "from_lon", "from_lat", "lon", "lat", "precision_m", "method")
)
.mig093_role_cols <- setdiff(.mig093_cols$roles, "feature")

.mig093_fail <- function(msg) cli::cli_abort(paste0(.mig093_name, ": ", msg), class = "sampletidy_error")
.mig093_scalar <- function(con, sql, ...) {
  as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
}
.mig093_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig093_csv_path <- function(dir, what) file.path(dir, sprintf("%s-%s.csv", .mig093_name, what))
.mig093_read <- function(p, cols) {
  if (!file.exists(p)) .mig093_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), cols)) .mig093_fail(sprintf("%s: columns are not as planned.", basename(p)))
  x
}
.mig093_code_ok <- function(x) !is.na(x) & grepl("^[A-Z]+\\.[A-Z]+[0-9]+[A-Z]?$", x)

# ---- inputs ----------------------------------------------------------------------

mig093_read_inputs <- function(input_dir = "dev/migrations") {
  inp <- lapply(stats::setNames(names(.mig093_cols), names(.mig093_cols)),
                function(k) .mig093_read(.mig093_csv_path(input_dir, paste0("INPUT-", k)), .mig093_cols[[k]]))
  r <- inp$roles
  if (!all(.mig093_code_ok(r$feature)) || anyDuplicated(r$feature)) .mig093_fail("INPUT-roles: a feature code is malformed or repeated.")
  if (!all(r$water_type %in% .st_water_types)) .mig093_fail("INPUT-roles: water_type outside the vocabulary.")
  if (!all(r$role %in% .st_point_roles)) .mig093_fail("INPUT-roles: role outside the vocabulary.")
  if (!all(is.na(r$source_cell) | r$source_cell %in% .st_source_cells)) .mig093_fail("INPUT-roles: source_cell outside the vocabulary.")
  if (!all(is.na(r$treatment) | r$treatment %in% .st_treatments)) .mig093_fail("INPUT-roles: treatment outside the vocabulary.")
  if (!all(r$lmf_end_member %in% c("TRUE", "FALSE"))) .mig093_fail("INPUT-roles: lmf_end_member is not TRUE/FALSE.")
  if (!identical(r$lmf_end_member == "TRUE", r$role == "leachate"))
    .mig093_fail("INPUT-roles: LMF end-members are not exactly the leachate-role points.")
  if (any(!is.na(r$end_member_note) & r$lmf_end_member != "TRUE")) .mig093_fail("INPUT-roles: an end_member_note on a non-end-member.")
  d <- inp$dubious
  if (!all(.mig093_code_ok(d$feature)) || anyDuplicated(d$feature) || anyNA(d$reason) || any(!nzchar(trimws(d$reason))))
    .mig093_fail("INPUT-dubious: a feature is malformed or repeated, or a reason is blank.")
  n <- inp$renames
  if (anyNA(n) || !all(.mig093_code_ok(c(n$old, n$new))) || anyDuplicated(c(n$old, n$new)))
    .mig093_fail("INPUT-renames: malformed or repeated code.")
  if (any(r$feature %in% n$old) || any(d$feature %in% n$old)) .mig093_fail("INPUT names a feature by its pre-rename code.")
  a <- inp$aliases
  if (anyNA(a) || !all(.mig093_code_ok(a$feature)) || anyNA(as.Date(a$date, optional = TRUE)))
    .mig093_fail("INPUT-aliases: a value is missing or malformed.")
  p <- inp$positions
  num <- c("from_lon", "from_lat", "lon", "lat", "precision_m")
  if (anyNA(p) || !all(.mig093_code_ok(p$feature)) || anyDuplicated(p$feature)) .mig093_fail("INPUT-positions: missing or repeated value.")
  for (k in num) {
    v <- suppressWarnings(as.numeric(p[[k]]))
    if (anyNA(v)) .mig093_fail(sprintf("INPUT-positions: %s is not numeric.", k))
    p[[k]] <- v
  }
  if (!all(p$lon > 150 & p$lon < 151 & p$lat > -34 & p$lat < -33.5)) .mig093_fail("INPUT-positions: a position is off the map.")
  if (any(grepl("[\r\n]", c(r$comments, d$reason, p$method), perl = TRUE))) .mig093_fail("INPUT holds a line break.")
  inp$positions <- p
  inp
}

# ---- plan ------------------------------------------------------------------------

.mig093_uuid <- function(...) {
  d <- digest::digest(paste(c(.mig093_marker_version, ...), collapse = "\u001f"), algo = "md5", serialize = FALSE)
  paste(substr(d, 1, 8), substr(d, 9, 12), paste0("4", substr(d, 14, 16)),
        paste0("8", substr(d, 18, 20)), substr(d, 21, 32), sep = "-")
}

.mig093_append <- function(old, note) {
  if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "\n", note)
}
.mig093_has <- function(old, note) !is.na(old) & grepl(note, old, fixed = TRUE)

.mig093_geom <- function(lon, lat) sprintf("POINT (%s %s)", as.character(lon), as.character(lat))

.mig093_rename_note <- function(old, new) sprintf("%s renamed from %s (the old code is kept as an alias).", .mig093_note_prefix, old)
.mig093_position_note <- function(method, precision) {
  sprintf("%s position: %s, +/- %s m (replaces the site-centroid placeholder).", .mig093_note_prefix, method,
          format(precision, trim = TRUE))
}

.mig093_features <- function(con, names) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid, name, lon, lat, geom_wkt, comments FROM feature WHERE name IN %s",
                               .mig093_inlist(names)))
}

# Map codes to feature uuids, reading a renamed code through its old name when the
# rename has not happened yet.
.mig093_uuid_of <- function(f, codes, renames) {
  u <- f$uuid[match(codes, f$name)]
  via <- is.na(u) & codes %in% renames$new
  u[via] <- f$uuid[match(renames$old[match(codes[via], renames$new)], f$name)]
  u
}

mig093_plan <- function(con, inp) {
  pr <- character(0)
  rn <- inp$renames
  codes <- unique(c(inp$roles$feature, inp$dubious$feature, inp$positions$feature, inp$aliases$feature, rn$old, rn$new))
  f <- .mig093_features(con, codes)
  if (anyDuplicated(f$name)) pr <- c(pr, "a feature name is repeated")

  # rename
  ren <- rn
  ren$uuid <- f$uuid[match(rn$old, f$name)]
  ren$old_comments <- f$comments[match(rn$old, f$name)]
  for (i in seq_len(nrow(ren))) {
    if (is.na(ren$uuid[[i]])) { pr <- c(pr, sprintf("feature %s missing", ren$old[[i]])); next }
    if (rn$new[[i]] %in% f$name) pr <- c(pr, sprintf("a feature is already named %s", rn$new[[i]]))
    k <- .mig093_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE alias_key = ?", .rc_feature_key(rn$new[[i]]))
    if (k > 0) pr <- c(pr, sprintf("an alias already holds the key of %s", rn$new[[i]]))
  }
  self <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature, name, kind, comments FROM feature_alias
    WHERE kind = 'self' AND uuid_feature IN %s", .mig093_inlist(ren$uuid[!is.na(ren$uuid)])))
  ren$uuid_self <- self$uuid[match(ren$uuid, self$uuid_feature)]
  if (anyDuplicated(self$uuid_feature) || (nrow(ren) && anyNA(ren$uuid_self[!is.na(ren$uuid)])))
    pr <- c(pr, "a renamed feature does not have exactly one self alias")
  ren$uuid_new_self <- vapply(ren$new, function(x) .mig093_uuid("self-alias", x), "", USE.NAMES = FALSE)
  ren$note <- .mig093_rename_note(ren$old, ren$new)
  ren$new_comments <- mapply(.mig093_append, ren$old_comments, ren$note, USE.NAMES = FALSE)

  # roles, dubious
  ro <- inp$roles
  ro$uuid_feature <- .mig093_uuid_of(f, ro$feature, rn)
  if (anyNA(ro$uuid_feature)) pr <- c(pr, sprintf("role features missing: %s", paste(ro$feature[is.na(ro$uuid_feature)], collapse = ", ")))
  du <- inp$dubious
  du$uuid_feature <- .mig093_uuid_of(f, du$feature, rn)
  if (anyNA(du$uuid_feature)) pr <- c(pr, sprintf("dubious features missing: %s", paste(du$feature[is.na(du$uuid_feature)], collapse = ", ")))
  if (.feature_role_ready(con)) {
    n <- .mig093_scalar(con, "SELECT (SELECT COUNT(*) FROM feature_role) + (SELECT COUNT(*) FROM feature_dubious)")
    if (n > 0) pr <- c(pr, sprintf("feature_role/feature_dubious already hold %d row(s)", n))
  }

  # positions: the stored placeholder must still be there
  po <- inp$positions
  i <- match(po$feature, f$name)
  po$uuid <- f$uuid[i]
  po$cur_lon <- f$lon[i]; po$cur_lat <- f$lat[i]; po$old_comments <- f$comments[i]
  if (anyNA(po$uuid)) pr <- c(pr, sprintf("position features missing: %s", paste(po$feature[is.na(po$uuid)], collapse = ", ")))
  moved <- !is.na(po$uuid) & (is.na(po$cur_lon) | is.na(po$cur_lat) |
                              abs(po$cur_lon - po$from_lon) > 1e-9 | abs(po$cur_lat - po$from_lat) > 1e-9)
  if (any(moved)) pr <- c(pr, sprintf("stored position is not the frozen placeholder: %s", paste(po$feature[moved], collapse = ", ")))
  po$geom_wkt <- .mig093_geom(po$lon, po$lat)
  po$note <- .mig093_position_note(po$method, po$precision_m)
  po$new_comments <- mapply(.mig093_append, po$old_comments, po$note, USE.NAMES = FALSE)

  # one-off mislabelling arms
  al <- inp$aliases
  al$alias_key <- vapply(al$alias_name, .rc_feature_key, "", USE.NAMES = FALSE)
  al$uuid_feature <- f$uuid[match(al$feature, f$name)]
  arms <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature, alias_key, kind, date_start, date_end FROM feature_alias
    WHERE alias_key IN %s AND kind <> 'self'", .mig093_inlist(al$alias_key)))
  al$uuid <- NA_character_
  al$fix <- FALSE
  for (j in seq_len(nrow(al))) {
    a <- arms[arms$alias_key == al$alias_key[[j]] & arms$uuid_feature %in% al$uuid_feature[[j]], , drop = FALSE]
    if (nrow(a) != 1) { pr <- c(pr, sprintf("alias %s -> %s: %d arm(s), expected 1", al$alias_name[[j]], al$feature[[j]], nrow(a))); next }
    al$uuid[[j]] <- a$uuid
    day <- as.Date(al$date[[j]])
    ds <- as.Date(a$date_start); de <- as.Date(a$date_end)
    if (!identical(a$kind, "historical_code")) pr <- c(pr, sprintf("alias %s -> %s is kind %s", al$alias_name[[j]], al$feature[[j]], a$kind))
    if (!is.na(ds) && !is.na(de) && ds == day && de == day) next
    if (is.na(ds) && is.na(de)) {
      off <- .mig093_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid_feature_alias = ?
        AND CAST(timezone('%s', timezone('UTC', coalesce(datetime, date))) AS DATE) <> ?", .mig093_tz), a$uuid, day)
      if (off > 0) pr <- c(pr, sprintf("alias %s -> %s is unbounded and %d of its samples fall off %s", al$alias_name[[j]],
                                       al$feature[[j]], off, al$date[[j]]))
      al$fix[[j]] <- TRUE
    } else {
      pr <- c(pr, sprintf("alias %s -> %s is bounded %s..%s, not to %s", al$alias_name[[j]], al$feature[[j]],
                          format(ds), format(de), al$date[[j]]))
    }
  }
  list(renames = ren, roles = ro, dubious = du, positions = po, aliases = al, problems = pr)
}

.mig093_role_rows <- function(ro) {
  tibble::tibble(uuid_feature = ro$uuid_feature, water_type = ro$water_type, role = ro$role,
                 source_cell = ro$source_cell, treatment = ro$treatment,
                 lmf_end_member = ro$lmf_end_member == "TRUE", end_member_note = ro$end_member_note,
                 comments = ro$comments)
}

# ---- apply -----------------------------------------------------------------------

mig093_apply <- function(con, plan, recorded_at, logf) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    .feature_role_create_schema(con)
    acols <- DBI::dbListFields(con, "feature_alias")
    rn <- plan$renames
    for (i in seq_len(nrow(rn))) {
      db_update(con, "feature", uuid = rn$uuid[[i]], changes = list(name = rn$new[[i]], comments = rn$new_comments[[i]]),
                actor = .mig093_actor, reason = sprintf("093: renamed %s -> %s", rn$old[[i]], rn$new[[i]]))
      db_update(con, "feature_alias", uuid = rn$uuid_self[[i]],
                changes = list(kind = "historical_code",
                               comments = sprintf("093: old code of %s (renamed 2026-10-29).", rn$new[[i]])),
                actor = .mig093_actor, reason = sprintf("093: %s kept as an alias of %s", rn$old[[i]], rn$new[[i]]))
      al <- tibble::tibble(uuid = rn$uuid_new_self[[i]], uuid_feature = rn$uuid[[i]], name = rn$new[[i]],
                           alias_key = .rc_feature_key(rn$new[[i]]), kind = "self", n_seen = 0L, auto_assign = TRUE,
                           first_seen = recorded_at, last_seen = recorded_at, confirmed_by = NA_character_,
                           comments = sprintf("Self alias of %s (093 rename from %s).", rn$new[[i]], rn$old[[i]]))
      db_append(con, "feature_alias", al[, intersect(names(al), acols), drop = FALSE], actor = .mig093_actor,
                reason = sprintf("093: self alias of %s", rn$new[[i]]))
    }
    db_append(con, "feature_role", .mig093_role_rows(plan$roles), actor = .mig093_actor,
              reason = "093: monitoring-point role from the role table v2")
    db_append(con, "feature_dubious",
              tibble::tibble(uuid_feature = plan$dubious$uuid_feature, reason = plan$dubious$reason, date_flagged = .mig093_day),
              actor = .mig093_actor, reason = "093: identity or position doubted")
    po <- plan$positions
    for (i in seq_len(nrow(po))) {
      ch <- list(lon = po$lon[[i]], lat = po$lat[[i]], geom_wkt = po$geom_wkt[[i]])
      if (!.mig093_has(po$old_comments[[i]], po$note[[i]])) ch$comments <- po$new_comments[[i]]
      db_update(con, "feature", uuid = po$uuid[[i]], changes = ch, actor = .mig093_actor,
                reason = "093: position replaces the site-centroid placeholder")
    }
    fx <- plan$aliases[plan$aliases$fix, , drop = FALSE]
    for (i in seq_len(nrow(fx))) {
      d <- as.Date(fx$date[[i]])
      db_update(con, "feature_alias", uuid = fx$uuid[[i]], changes = list(date_start = d, date_end = d),
                actor = .mig093_actor, reason = "093: one-off bottle mislabelling bounded to its day")
    }
    mig_db_checks_gate(con, baseline)
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig093_marker_version, recorded_at))
    logf("Applied: %d rename(s); %d role row(s) (%d LMF end-member(s)); %d dubious; %d position(s); %d alias arm(s) bounded (%d already bounded); marker %d.",
         nrow(rn), nrow(plan$roles), sum(plan$roles$lmf_end_member == "TRUE"), nrow(plan$dubious), nrow(po),
         nrow(fx), nrow(plan$aliases) - nrow(fx), .mig093_marker_version)
    invisible(NULL)
  })
}

# ---- verification ------------------------------------------------------------------

mig093_verify <- function(con, inp) {
  pr <- character(0)
  if (!.feature_role_ready(con)) return("feature_role / feature_dubious tables missing")
  rn <- inp$renames
  f <- .mig093_features(con, unique(c(inp$roles$feature, inp$dubious$feature, inp$positions$feature, inp$aliases$feature, rn$old, rn$new)))
  for (i in seq_len(nrow(rn))) {
    if (rn$old[[i]] %in% f$name) pr <- c(pr, sprintf("a feature is still named %s", rn$old[[i]]))
    u <- f$uuid[match(rn$new[[i]], f$name)]
    if (is.na(u)) { pr <- c(pr, sprintf("no feature named %s", rn$new[[i]])); next }
    a <- DBI::dbGetQuery(con, "SELECT uuid, alias_key, kind FROM feature_alias WHERE uuid_feature = ? AND alias_key IN (?, ?)",
                         params = list(u, .rc_feature_key(rn$old[[i]]), .rc_feature_key(rn$new[[i]])))
    want <- c(.rc_feature_key(rn$new[[i]]), .rc_feature_key(rn$old[[i]]))
    if (!identical(a$kind[match(want, a$alias_key)], c("self", "historical_code")) ||
        !identical(a$uuid[match(want[1], a$alias_key)], .mig093_uuid("self-alias", rn$new[[i]])))
      pr <- c(pr, sprintf("aliases of %s are not as planned", rn$new[[i]]))
  }
  got <- DBI::dbGetQuery(con, "SELECT f.name AS feature, r.water_type, r.role, r.source_cell, r.treatment,
      CASE WHEN r.lmf_end_member THEN 'TRUE' ELSE 'FALSE' END AS lmf_end_member, r.end_member_note, r.comments
    FROM feature_role r LEFT JOIN feature f ON f.uuid = r.uuid_feature ORDER BY f.name")
  want <- inp$roles[order(inp$roles$feature, method = "radix"), , drop = FALSE]
  rownames(want) <- NULL
  if (!identical(got, want)) pr <- c(pr, sprintf("feature_role differs from INPUT-roles (%d rows held, %d planned)", nrow(got), nrow(want)))
  gd <- DBI::dbGetQuery(con, "SELECT f.name AS feature, d.reason, d.date_flagged FROM feature_dubious d
    LEFT JOIN feature f ON f.uuid = d.uuid_feature ORDER BY f.name")
  wd <- inp$dubious[order(inp$dubious$feature, method = "radix"), , drop = FALSE]
  if (!identical(gd$feature, wd$feature) || !identical(gd$reason, wd$reason) || any(as.Date(gd$date_flagged) != .mig093_day))
    pr <- c(pr, "feature_dubious differs from INPUT-dubious")
  po <- inp$positions
  i <- match(po$feature, f$name)
  bad <- is.na(i) | abs(f$lon[i] - po$lon) > 1e-9 | abs(f$lat[i] - po$lat) > 1e-9 |
    f$geom_wkt[i] != .mig093_geom(po$lon, po$lat)
  bad[is.na(bad)] <- TRUE
  if (any(bad)) pr <- c(pr, sprintf("positions not as planned: %s", paste(po$feature[bad], collapse = ", ")))
  k <- vapply(seq_len(nrow(po)), function(j) {
    cm <- f$comments[i[[j]]]
    if (is.na(cm)) 0L else lengths(regmatches(cm, gregexpr(.mig093_position_note(po$method[[j]], po$precision_m[[j]]), cm, fixed = TRUE)))
  }, 0L)
  if (any(k != 1L)) pr <- c(pr, sprintf("position note not present exactly once: %s", paste(po$feature[k != 1L], collapse = ", ")))
  al <- inp$aliases
  for (j in seq_len(nrow(al))) {
    a <- DBI::dbGetQuery(con, "SELECT fa.kind, fa.date_start, fa.date_end FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
      WHERE fa.alias_key = ? AND f.name = ? AND fa.kind <> 'self'", params = list(.rc_feature_key(al$alias_name[[j]]), al$feature[[j]]))
    d <- as.Date(al$date[[j]])
    if (nrow(a) != 1 || a$kind != "historical_code" || is.na(a$date_start) || is.na(a$date_end) ||
        as.Date(a$date_start) != d || as.Date(a$date_end) != d)
      pr <- c(pr, sprintf("alias %s -> %s is not a single-day arm on %s", al$alias_name[[j]], al$feature[[j]], al$date[[j]]))
  }
  pr
}

.mig093_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "asset", "change_log", "schema_version")
  tabs <- c(tabs, intersect(c("feature_role", "feature_dubious"), DBI::dbListTables(con)))
  stats::setNames(vapply(tabs, function(t) .mig093_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 0L), tabs)
}

# Content digest of the result tables: 093 must not change a sample or analysis.
mig093_data_digest <- function(con) {
  vapply(c("sample", "analysis"), function(t) {
    digest::digest(DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" ORDER BY uuid', t)), algo = "sha1")
  }, "")
}

# ---- backup ------------------------------------------------------------------------

mig093_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig093_name,
                                          format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")))
  n0 <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    n <- .mig093_counts(con)
    if (!isTRUE(file.copy(db, dest, overwrite = FALSE))) .mig093_fail(sprintf("could not write backup %s", dest))
    n
  }, db = db)
  v <- DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE)
  on.exit(DBI::dbDisconnect(v, shutdown = TRUE), add = TRUE)
  if (!identical(n0, .mig093_counts(v))) .mig093_fail("backup verification failed: counts differ.")
  dest
}

.mig093_write_csv <- function(df, path) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df)) .mig093_fail(sprintf("CSV %s did not round-trip.", basename(path)))
}

# ---- run -------------------------------------------------------------------------------

mig093_run <- function(db, snapshot_dir, dry_run = FALSE, csv_dir = "dev/migrations", input_dir = "dev/migrations",
                       requires = .mig093_requires, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", basename(db), sprintf(fmt, ...)))
  checkmate::assert_directory_exists(snapshot_dir)
  checkmate::assert_directory_exists(csv_dir)
  inp <- mig093_read_inputs(input_dir)
  logf("Inputs: %d role row(s), %d dubious, %d rename(s), %d position(s), %d one-off alias arm(s).",
       nrow(inp$roles), nrow(inp$dubious), nrow(inp$renames), nrow(inp$positions), nrow(inp$aliases))

  con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) .mig093_fail(sprintf("marker %s required first.", paste(requires, collapse = ", ")))
    done <- .mig093_marker_version %in% have
    if (!done && .mig093_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig093_actor) > 0)
      .mig093_fail("change_log holds 093 rows but marker 1093 is absent.")
    list(done = done, plan = if (done) NULL else mig093_plan(con, inp),
         problems = if (done) mig093_verify(con, inp) else NULL)
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))

  if (st$done) {
    if (length(st$problems)) .mig093_fail(paste0("re-verify: ", paste(st$problems, collapse = "; ")))
    logf("093 already applied; re-verified; nothing to do.")
    return(invisible(list(status = "already_migrated")))
  }
  plan <- st$plan
  if (length(plan$problems)) .mig093_fail(paste(plan$problems, collapse = "; "))
  logf("Plan: rename %s; %d role row(s); dubious %s; %d position(s); alias arms to bound: %s.",
       paste(sprintf("%s->%s", plan$renames$old, plan$renames$new), collapse = ", "), nrow(plan$roles),
       paste(plan$dubious$feature, collapse = ", "), nrow(plan$positions),
       if (any(plan$aliases$fix)) paste(plan$aliases$alias_name[plan$aliases$fix], collapse = ", ") else "none")
  if (isTRUE(dry_run)) {
    logf("DRY RUN: inputs and preconditions checked. Nothing written.")
    return(invisible(list(status = "dry_run", plan = plan)))
  }

  con <- st_connect(db, read_only = TRUE)
  before <- tryCatch({
    fu <- unique(c(plan$renames$uuid, plan$positions$uuid))
    .mig093_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE uuid IN %s ORDER BY name", .mig093_inlist(fu))),
                      .mig093_csv_path(csv_dir, "BACKUP-feature"))
    au <- c(plan$renames$uuid_self, plan$aliases$uuid[plan$aliases$fix])
    .mig093_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY uuid", .mig093_inlist(au))),
                      .mig093_csv_path(csv_dir, "BACKUP-feature_alias"))
    list(digest = mig093_data_digest(con), counts = .mig093_counts(con))
  }, finally = DBI::dbDisconnect(con, shutdown = TRUE))
  backup_path <- mig093_backup(db, snapshot_dir, .now)
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: cp %s %s", shQuote(backup_path), shQuote(db))
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) mig093_apply(con, plan, recorded_at, logf), db = db)

  con <- st_connect(db, read_only = TRUE)
  after <- tryCatch(list(problems = mig093_verify(con, inp), digest = mig093_data_digest(con), counts = .mig093_counts(con)),
                    finally = DBI::dbDisconnect(con, shutdown = TRUE))
  if (!identical(before$digest, after$digest)) after$problems <- c(after$problems, "sample or analysis content changed")
  nm <- names(after$counts)
  delta <- after$counts - ifelse(nm %in% names(before$counts), before$counts[nm], 0L)
  logf("Row deltas: %s", paste(nm[delta != 0], delta[delta != 0], sep = " +", collapse = ", "))
  if (length(after$problems)) .mig093_fail(paste0("verify: ", paste(after$problems, collapse = "; "), ". Restore from ", backup_path))
  logf("%s migrated successfully (marker %d).", .mig093_name, .mig093_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, delta = delta))
}
