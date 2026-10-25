# PLAN-22 Part A: standing database checks.
#
# A check is data (`db_check()`): a name, a tier, a severity and a query that
# returns the OFFENDING rows - zero rows is a pass. Every query's result
# carries a VARCHAR `key` column naming the offender, so a migration gate can
# tell an old failure from a new one by key. A query is either a SQL string
# (with `{param}` tokens, see `.dbc_tokens()`) or an R function
# `function(con, params)` returning a data.frame - used where the rule
# already lives in R (alias-key normalisation, fraction from method code),
# so it is not copied into SQL.
#
# Tiers nest: hourly < migration < all (all adds the on_demand checks).
# `db_checks()` never aborts on a check: a query error is status "error".

# ---- vocabularies not defined elsewhere ----------------------------------------------
# (alias kinds: `.fa_kind_vocabulary`; ingest states: `.st_ingest_transitions`;
# fraction: `.st_fraction_vocabulary` in R/commit.R.)

# review_queue.status: 'open' until resolve_review() stamps 'resolved' (D4).
.st_review_statuses <- c("open", "resolved")

# feature.flow. v_measurement's fraction preference keys on 'groundwater'.
.st_feature_flows <- c("groundwater", "still", "seep", "flowing")

# Core mask variants (feature_mask / analyte_mask); a deployment adds its own
# through db_checks_params(mask_variants =).
.st_core_mask_variants <- c("long", "old", "gas_report")

.dbc_tiers <- c("hourly", "migration", "on_demand")
.dbc_severities <- c("error", "warn")
# Which check tiers each db_checks(tier =) runs.
.dbc_tier_runs <- list(
  hourly = "hourly",
  migration = c("hourly", "migration"),
  all = c("hourly", "migration", "on_demand")
)

# ---- constructors ----------------------------------------------------------------------

#' Define a standing database check
#'
#' A check's query returns the offending rows; zero rows is a pass. Its
#' result must carry a `key` column (coerced to character) that names each
#' offender - [mig_db_checks_gate()] compares keys to tell a new failure from
#' an old one.
#'
#' @param name a unique check name.
#' @param sql either one SQL string, in which `{param}` tokens are filled from
#'   [db_checks_params()] (`{min_date}`, `{tz}`, `{mask_variants}`,
#'   `{bbox_xmin}`/`{bbox_ymin}`/`{bbox_xmax}`/`{bbox_ymax}`), or a function
#'   `function(con, params)` returning a data.frame with a `key` column.
#' @param description what the check asserts.
#' @param tier `"hourly"`, `"migration"` or `"on_demand"`.
#' @param severity `"error"` (a broken invariant) or `"warn"` (suspicious;
#'   needs a human).
#' @return a one-row data.frame (`name`, `sql` - a list column -,
#'   `description`, `tier`, `severity`). Combine checks with [rbind()].
#' @seealso [db_checks()]
#' @export
db_check <- function(name, sql, description, tier = "hourly", severity = "error") {
  checkmate::assert_string(name, min.chars = 1)
  if (!(checkmate::test_string(sql, min.chars = 1) || is.function(sql))) {
    cli::cli_abort("{.arg sql} must be one SQL string or a function(con, params), not {.cls {class(sql)}}.",
                   class = "sampletidy_error")
  }
  checkmate::assert_string(description)
  if (!checkmate::test_choice(tier, .dbc_tiers)) {
    cli::cli_abort("{.arg tier} must be one of {.val {(.dbc_tiers)}}, not {.val {tier}}.",
                   class = "sampletidy_error")
  }
  if (!checkmate::test_choice(severity, .dbc_severities)) {
    cli::cli_abort("{.arg severity} must be one of {.val {(.dbc_severities)}}, not {.val {severity}}.",
                   class = "sampletidy_error")
  }
  out <- data.frame(name = name, description = description, tier = tier,
                    severity = severity, stringsAsFactors = FALSE)
  out$sql <- I(list(sql))
  out[, c("name", "sql", "description", "tier", "severity")]
}

#' Parameters for the standing database checks
#'
#' @param ... named overrides of the defaults:
#'   * `min_date`: samples dated before this are implausible (default
#'     `"1980-01-01"`);
#'   * `bbox`: `c(xmin, ymin, xmax, ymax)` that physical features must lie
#'     in, or `NULL` (default) for no box - finite coordinates suffice;
#'   * `tz`: the time zone whose calendar day `sample.date` names (default
#'     `"Australia/Sydney"`);
#'   * `mask_variants`: the registered mask variants (default the core
#'     `long`, `old`, `gas_report`; a deployment adds its own);
#'   * `receipt_max_temp_c`, `receipt_lookback_days`: the SRN receipt
#'     temperature above which `lab_receipt_warm` warns (default 6), and how
#'     many days back it looks (default 90).
#' @return a named list.
#' @export
db_checks_params <- function(...) {
  p <- list(
    min_date = "1980-01-01",
    bbox = NULL,
    tz = .inbox_tz,
    mask_variants = .st_core_mask_variants,
    # R-22.S: lab_receipt_warm flags an SRN whose warmest cooler is above
    # receipt_max_temp_c (ALS's own "chilled to <= 6 C" note), received within
    # the last receipt_lookback_days.
    receipt_max_temp_c = 6,
    receipt_lookback_days = 90
  )
  over <- list(...)
  if (length(over)) {
    nm <- names(over)
    if (is.null(nm) || any(!nzchar(nm))) {
      cli::cli_abort("db_checks_params() takes named arguments only.", class = "sampletidy_error")
    }
    bad <- setdiff(nm, names(p))
    if (length(bad)) {
      cli::cli_abort("Unknown db_checks parameter{?s} {.val {bad}}; known: {.val {names(p)}}.",
                     class = "sampletidy_error")
    }
    for (k in nm) p[k] <- list(over[[k]])
  }
  d <- tryCatch(as.Date(p$min_date), error = function(e) NA)
  if (length(p$min_date) != 1 || is.na(d)) {
    cli::cli_abort("{.arg min_date} must be one date.", class = "sampletidy_error")
  }
  if (!is.null(p$bbox)) {
    b <- p$bbox
    if (!is.numeric(b) || length(b) != 4 || anyNA(b) ||
        !setequal(names(b), c("xmin", "ymin", "xmax", "ymax"))) {
      cli::cli_abort("{.arg bbox} must be NULL or a numeric c(xmin =, ymin =, xmax =, ymax =).",
                     class = "sampletidy_error")
    }
  }
  if (!checkmate::test_string(p$tz) || !grepl("^[A-Za-z0-9_/+-]+$", p$tz)) {
    cli::cli_abort("{.arg tz} must be one time-zone name.", class = "sampletidy_error")
  }
  checkmate::assert_character(p$mask_variants, any.missing = FALSE, min.len = 1)
  checkmate::assert_number(p$receipt_max_temp_c, finite = TRUE)
  checkmate::assert_number(p$receipt_lookback_days, lower = 0, finite = TRUE)
  p
}

# ---- token filling ---------------------------------------------------------------------

.dbc_sql_list <- function(x) paste(DBI::dbQuoteString(DBI::ANSI(), as.character(x)), collapse = ", ")

.dbc_core_version <- function() max(vapply(.st_schema_migrations, function(m) as.integer(m$version), 0L))

# The text each `{token}` is replaced by. Only these names are tokens, so a
# regex quantifier such as `{32}` in a check's SQL is left alone.
.dbc_tokens <- function(params) {
  b <- params$bbox
  num <- function(x) if (is.infinite(x)) sprintf("CAST('%sinf' AS DOUBLE)", if (x < 0) "-" else "") else
    format(x, digits = 15)
  if (is.null(b)) b <- c(xmin = -Inf, ymin = -Inf, xmax = Inf, ymax = Inf)
  c(
    min_date = as.character(as.Date(params$min_date)),
    tz = params$tz,
    mask_variants = .dbc_sql_list(params$mask_variants),
    bbox_xmin = num(b[["xmin"]]), bbox_ymin = num(b[["ymin"]]),
    bbox_xmax = num(b[["xmax"]]), bbox_ymax = num(b[["ymax"]]),
    core_version = as.character(.dbc_core_version()),
    alias_kinds = .dbc_sql_list(c(.fa_kind_vocabulary, "pending")),
    ingest_states = .dbc_sql_list(unique(c(names(.st_ingest_transitions), unlist(.st_ingest_transitions)))),
    review_statuses = .dbc_sql_list(.st_review_statuses),
    fractions = .dbc_sql_list(.st_fraction_vocabulary),
    flows = .dbc_sql_list(.st_feature_flows)
  )
}

.dbc_fill <- function(sql, tokens) {
  for (k in names(tokens)) sql <- gsub(paste0("{", k, "}"), tokens[[k]], sql, fixed = TRUE)
  sql
}

# ---- R-computed checks -----------------------------------------------------------------

# Every user view binds and returns at least one row.
.dbc_view_nonempty <- function(con, params) {
  vs <- DBI::dbGetQuery(con, "
    SELECT schema_name, view_name FROM duckdb_views()
    WHERE NOT internal AND NOT temporary AND database_name = current_database()
    ORDER BY schema_name, view_name")
  bad <- character()
  why <- character()
  for (i in seq_len(nrow(vs))) {
    q <- sprintf("SELECT 1 AS one FROM %s.%s LIMIT 1",
                 DBI::dbQuoteIdentifier(con, vs$schema_name[[i]]),
                 DBI::dbQuoteIdentifier(con, vs$view_name[[i]]))
    r <- tryCatch(DBI::dbGetQuery(con, q), error = function(e) conditionMessage(e))
    if (is.character(r)) {
      bad <- c(bad, vs$view_name[[i]]); why <- c(why, r)
    } else if (nrow(r) == 0) {
      bad <- c(bad, vs$view_name[[i]]); why <- c(why, "empty")
    }
  }
  data.frame(key = bad, problem = why, stringsAsFactors = FALSE)
}

# alias_key is what .rc_feature_key() makes of the alias name.
.dbc_alias_key_normalised <- function(con, params) {
  fa <- DBI::dbGetQuery(con, "SELECT uuid, name, alias_key FROM feature_alias")
  want <- .rc_feature_key(fa$name)
  bad <- !((is.na(want) & is.na(fa$alias_key)) |
             (!is.na(want) & !is.na(fa$alias_key) & want == fa$alias_key))
  out <- fa[bad, , drop = FALSE]
  data.frame(key = as.character(out$uuid), name = out$name, alias_key = out$alias_key,
             expected = want[bad], stringsAsFactors = FALSE)
}

# fraction agrees with what commit mints from the method code. Only fractions
# in the vocabulary are judged (anything else is vocab_lab_method_fraction's).
.dbc_fraction_matches_code <- function(con, params) {
  lm <- DBI::dbGetQuery(con, "SELECT uuid, method, fraction FROM lab_method")
  lm <- lm[is.na(lm$fraction) | lm$fraction %in% .st_fraction_vocabulary, , drop = FALSE]
  want <- .st_fraction_from_method(lm$method)
  bad <- !((is.na(want) & is.na(lm$fraction)) |
             (!is.na(want) & !is.na(lm$fraction) & want == lm$fraction))
  out <- lm[bad, , drop = FALSE]
  data.frame(key = as.character(out$uuid), method = out$method, fraction = out$fraction,
             expected = want[bad], stringsAsFactors = FALSE)
}

# NULL-datetime sample identity duplicates, stream-aware (A91 D3). A group of
# samples sharing (alias, date, project) with a NULL datetime is a duplicate
# unless every sample carries exactly ONE analysis stream and no two samples
# share one - an ALS sample beside an ACIRL field sample is two contractors'
# readings, not a duplicate. A sample with no analyses (or an unattributable
# NA stream) matches any stream, so its group is flagged. The stream of a
# stored analysis is .rc_lab_stream() (R/reconcile.R), the rule
# .rc_row_stream() and .ct_sample_match() use; it is not re-written here.
.dbc_dup_sample_identity_null_datetime <- function(con, params) {
  grp <- DBI::dbGetQuery(con, "
SELECT concat_ws(' ', s.uuid_feature_alias, CAST(s.date AS VARCHAR), s.uuid_project) AS key,
       s.uuid
FROM \"sample\" s
JOIN (SELECT uuid_feature_alias, date, uuid_project FROM \"sample\" WHERE datetime IS NULL
      GROUP BY uuid_feature_alias, date, uuid_project HAVING count(*) > 1) g
  ON g.uuid_feature_alias IS NOT DISTINCT FROM s.uuid_feature_alias
 AND g.date IS NOT DISTINCT FROM s.date
 AND g.uuid_project IS NOT DISTINCT FROM s.uuid_project
WHERE s.datetime IS NULL
ORDER BY key, s.uuid")
  empty <- data.frame(key = character(0), n = integer(0), uuids = character(0),
                      stringsAsFactors = FALSE)
  if (nrow(grp) == 0L) return(empty)
  an <- DBI::dbGetQuery(con, "
SELECT DISTINCT a.uuid_sample, a.uuid_lab FROM analysis a
WHERE a.uuid_sample IN (SELECT uuid FROM \"sample\" WHERE datetime IS NULL)")
  registry <- list(
    lab_method = DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte, organisation FROM lab_method"),
    analyte = DBI::dbGetQuery(con, "SELECT uuid, type FROM analyte")
  )
  an$stream <- .rc_lab_stream(an$uuid_lab, registry)
  streams <- split(an$stream, an$uuid_sample)
  flagged <- vapply(split(grp$uuid, grp$key), function(uuids) {
    per <- lapply(uuids, function(u) unique(streams[[u]]))
    one_each <- all(vapply(per, function(x) length(x) == 1L && !is.na(x), logical(1)))
    !one_each || anyDuplicated(unlist(per)) > 0L
  }, logical(1))
  keys <- names(flagged)[flagged]
  if (length(keys) == 0L) return(empty)
  data.frame(
    key = keys,
    n = vapply(keys, function(k) sum(grp$key == k), integer(1), USE.NAMES = FALSE),
    uuids = vapply(keys, function(k) paste(grp$uuid[grp$key == k], collapse = " "),
                   character(1), USE.NAMES = FALSE),
    stringsAsFactors = FALSE
  )
}

# ---- R-22.S: QC tables and sample receipt notifications ------------------------------------

.dbc_orphan_qc_refs_sql <- "
SELECT uuid AS key, 'lab_qc_outlier.uuid_report' AS col FROM lab_qc_outlier
WHERE uuid_report NOT IN (SELECT uuid FROM lab_qc_report)
UNION ALL SELECT uuid, 'lab_qc_outlier.uuid_sample' FROM lab_qc_outlier
WHERE uuid_sample IS NOT NULL AND uuid_sample NOT IN (SELECT uuid FROM \"sample\")
UNION ALL SELECT uuid_sample, 'sample_lab_id.uuid_sample' FROM sample_lab_id
WHERE uuid_sample NOT IN (SELECT uuid FROM \"sample\")
UNION ALL SELECT uuid_feature, 'qc_feature.uuid_feature' FROM qc_feature
WHERE uuid_feature NOT IN (SELECT uuid FROM feature)
UNION ALL SELECT uuid_feature, 'qc_feature.uuid_parent' FROM qc_feature
WHERE uuid_parent IS NOT NULL AND uuid_parent NOT IN (SELECT uuid FROM feature)"

# The receipt child tables exist only after the operator migration; before it
# the check is the 048 arms alone.
.dbc_orphan_qc_refs <- function(con, params) {
  sql <- .dbc_orphan_qc_refs_sql
  if (.lab_receipt_ready(con)) {
    for (t in names(.lab_receipt_ddl)) {
      sql <- paste0(sql, sprintf("
UNION ALL SELECT uuid, '%1$s.uuid_report' FROM %1$s
WHERE uuid_report NOT IN (SELECT uuid FROM lab_qc_report)", t))
    }
  }
  DBI::dbGetQuery(con, sql)
}

# key = work_order. temp_max_c is the warmest reported cooler; the rule is
# "above" the limit, so exactly receipt_max_temp_c passes.
.dbc_lab_receipt_warm <- function(con, params) {
  if (!.lab_receipt_ready(con)) return(data.frame(key = character(0), stringsAsFactors = FALSE))
  DBI::dbGetQuery(con, "
SELECT work_order AS key, temp_max_c, received_at FROM lab_qc_report
WHERE kind = 'SRN' AND temp_max_c IS NOT NULL AND temp_max_c > ?
  AND received_at >= timezone('UTC', now()) - to_days(CAST(? AS INTEGER))
ORDER BY received_at",
                  params = list(params$receipt_max_temp_c, as.integer(ceiling(params$receipt_lookback_days))))
}

# ---- the core catalogue ----------------------------------------------------------------

#' The generic standing database checks
#'
#' The checks every sampleTidy database should satisfy (PLAN-22 A2):
#' orphan references the DB does not enforce, duplicates, alias invariants,
#' vocabularies, value and hash shape, date and coordinate sanity, the core
#' schema version, and (migration tier) view coverage and expected
#' constraints. A deployment adds its own through `db_checks(extra =)`.
#'
#' @return a data.frame of [db_check()] rows.
#' @export
db_checks_core <- function() {
  ck <- db_check
  rbind(
    # ---- views
    ck("view_nonempty", .dbc_view_nonempty,
       "Every user view binds and returns at least one row.", "hourly", "error"),
    ck("measurement_view_coverage", "
SELECT a.uuid AS key, fa.name AS alias
FROM analysis a JOIN \"sample\" s ON s.uuid = a.uuid_sample
JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
JOIN lab_method lm ON lm.uuid = a.uuid_lab
WHERE fa.uuid_feature IS NOT NULL AND lm.uuid_analyte IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM v_measurement v WHERE v.uuid_analysis = a.uuid)",
       "Every analysis on a resolved alias and analyte appears in v_measurement (catches an INNER JOIN dropping rows).",
       "migration", "error"),
    ck("measurement_view_no_fanout", "
SELECT CAST(uuid_analysis AS VARCHAR) AS key, count(*) AS n FROM v_measurement
GROUP BY uuid_analysis HAVING count(*) > 1",
       "v_measurement has at most one row per analysis (catches a join fan-out).", "migration", "error"),
    ck("measurement_rank1_unique", "
SELECT concat_ws(' ', uuid_feature, CAST(date AS VARCHAR), analyte_name) AS key, count(*) AS n
FROM v_measurement WHERE preference_rank = 1
GROUP BY uuid_feature, date, analyte_name HAVING count(*) > 1",
       "Exactly one preferred row per (feature, day, analyte) in v_measurement.", "migration", "error"),
    ck("expected_constraints_present", "
WITH want(table_name, constraint_type, col) AS (VALUES
  ('analysis','FOREIGN KEY','uuid_sample'), ('analysis','FOREIGN KEY','uuid_lab'),
  ('sample','FOREIGN KEY','uuid_feature_alias'), ('lab_method','FOREIGN KEY','uuid_analyte'),
  ('feature_mask','FOREIGN KEY','uuid_feature'), ('analyte_mask','FOREIGN KEY','uuid_analyte'),
  ('review_queue_candidate','FOREIGN KEY','uuid_review'),
  ('analysis','PRIMARY KEY','uuid'), ('sample','PRIMARY KEY','uuid'), ('feature','PRIMARY KEY','uuid'),
  ('feature_alias','PRIMARY KEY','uuid'), ('lab_method','PRIMARY KEY','uuid'), ('analyte','PRIMARY KEY','uuid'),
  ('ingest_file','PRIMARY KEY','hash'), ('lab_qc_report','UNIQUE','uuid_asset'))
SELECT w.table_name || '.' || w.col || ' ' || w.constraint_type AS key FROM want w WHERE NOT EXISTS (
  SELECT 1 FROM duckdb_constraints() c WHERE c.table_name = w.table_name
   AND c.constraint_type = w.constraint_type AND list_contains(c.constraint_column_names, w.col))
UNION ALL
SELECT 'ux_sample_identity' AS key
WHERE NOT EXISTS (SELECT 1 FROM duckdb_indexes() WHERE index_name = 'ux_sample_identity')",
       "Constraints and indexes the code relies on still exist (a table rebuild can silently drop them).",
       "migration", "error"),
    # ---- schema markers
    ck("schema_version_no_duplicates", "
SELECT CAST(version AS VARCHAR) AS key, count(*) AS n FROM schema_version GROUP BY version HAVING count(*) > 1",
       "No schema_version marker is recorded twice (the table has no key).", "migration", "error"),
    ck("schema_version_core_current", "
SELECT coalesce(CAST(max(version) AS VARCHAR), 'none') AS key, {core_version} AS expected
FROM schema_version WHERE version < 1000 HAVING max(version) IS DISTINCT FROM {core_version}",
       "The core ops-schema ladder is at the version this package build expects.", "hourly", "error"),
    ck("schema_version_core_contiguous", "
SELECT CAST(g.v AS VARCHAR) AS key FROM range(1, {core_version} + 1) g(v)
WHERE g.v NOT IN (SELECT version FROM schema_version WHERE version IS NOT NULL)",
       "Core ops-schema versions 1..N are all recorded.", "migration", "error"),
    # ---- orphans (references without a DDL foreign key)
    ck("orphan_alias_feature", "
SELECT uuid AS key, name FROM feature_alias
WHERE uuid_feature IS NOT NULL AND uuid_feature NOT IN (SELECT uuid FROM feature)",
       "feature_alias.uuid_feature points at a feature.", "hourly", "error"),
    ck("orphan_sample_project", "
SELECT uuid AS key FROM \"sample\" WHERE uuid_project IS NULL OR uuid_project NOT IN (SELECT uuid FROM project)",
       "sample.uuid_project is set and points at a project.", "hourly", "error"),
    ck("orphan_project_refs", "
SELECT uuid AS key, 'uuid_root' AS col FROM project
WHERE uuid_root IS NOT NULL AND uuid_root NOT IN (SELECT uuid FROM project)
UNION ALL SELECT uuid, 'uuid_project' FROM project
WHERE uuid_project IS NOT NULL AND uuid_project NOT IN (SELECT uuid FROM project)",
       "project.uuid_root and project.uuid_project point at projects.", "hourly", "error"),
    ck("orphan_asset_refs", "
SELECT uuid AS key, 'asset.uuid_project' AS col FROM asset
WHERE uuid_project IS NOT NULL AND uuid_project NOT IN (SELECT uuid FROM project)
UNION ALL SELECT uuid, 'asset.uuid_feature' FROM asset
WHERE uuid_feature IS NOT NULL AND uuid_feature NOT IN (SELECT uuid FROM feature)
UNION ALL SELECT hash, 'ingest_file.uuid_asset' FROM ingest_file
WHERE uuid_asset IS NOT NULL AND uuid_asset NOT IN (SELECT uuid FROM asset)
UNION ALL SELECT uuid, 'lab_qc_report.uuid_asset' FROM lab_qc_report
WHERE uuid_asset IS NULL OR uuid_asset NOT IN (SELECT uuid FROM asset)",
       "asset, ingest_file and lab_qc_report links resolve.", "hourly", "error"),
    ck("orphan_ingest_sighting", "
SELECT DISTINCT hash AS key FROM ingest_sighting WHERE hash NOT IN (SELECT hash FROM ingest_file)",
       "ingest_sighting.hash points at an ingest_file.", "hourly", "error"),
    # R-22.E (Robin 2026-10-25): keyed by the ingest_file row, like the
    # ingest_file.uuid_asset arm above.
    ck("ingest_file_email_dangling", "
SELECT hash AS key, message_id FROM ingest_file
WHERE message_id IS NOT NULL AND message_id NOT IN (SELECT message_id FROM ingest_email)",
       "ingest_file.message_id names an ingest_email row.", "hourly", "error"),
    # R-22.N (Robin 2026-10-25): a needs_review file with no open review item
    # covering it was never settled. Covered = an open item whose source_hash
    # is the file's hash or whose work_order is the file's; a legacy row with
    # work_order NULL reads the work order from "commit_event: <WO>".
    ck("ingest_file_needs_review_resolved", "
SELECT f.hash AS key FROM (
  SELECT hash, COALESCE(work_order, NULLIF(NULLIF(regexp_extract(state_reason, '^commit_event: (.+)$', 1), ''), 'NA')) AS wo
  FROM ingest_file WHERE state = 'needs_review') f
WHERE NOT EXISTS (
  SELECT 1 FROM review_queue r WHERE r.status = 'open'
    AND (r.source_hash = f.hash OR (r.work_order IS NOT NULL AND r.work_order = f.wo)))",
       "A needs_review file is covered by an open review item.", "hourly", "warn"),
    ck("orphan_qc_refs", .dbc_orphan_qc_refs,
       "The QC tables point at their parents.", "hourly", "error"),
    # R-22.S (Robin 2026-10-25): lab_qc_report.kind is one of the parsed
    # report kinds, and an SRN received warm is worth a human's look.
    ck("vocab_lab_qc_kind", "
SELECT uuid AS key, kind FROM lab_qc_report WHERE kind IS NULL OR kind NOT IN ('QC', 'QCI', 'SRN')",
       "lab_qc_report.kind is QC, QCI or SRN.", "hourly", "error"),
    ck("lab_receipt_warm", .dbc_lab_receipt_warm,
       "A recent SRN reports a receipt temperature above receipt_max_temp_c.", "hourly", "warn"),
    ck("orphan_registry_refs", "
SELECT uuid AS key, 'lab_method.uuid_project' AS col FROM lab_method
WHERE uuid_project IS NOT NULL AND uuid_project NOT IN (SELECT uuid FROM project)
UNION ALL SELECT uuid, 'lab_method.uuid_feature' FROM lab_method
WHERE uuid_feature IS NOT NULL AND uuid_feature NOT IN (SELECT uuid FROM feature)
UNION ALL SELECT uuid, 'feature.uuid_project' FROM feature
WHERE uuid_project IS NOT NULL AND uuid_project NOT IN (SELECT uuid FROM project)",
       "lab_method and feature soft references resolve.", "hourly", "error"),
    ck("orphan_review_open_refs", "
SELECT uuid AS key, kind, 'uuid_alias' AS col FROM review_queue
WHERE status = 'open' AND uuid_alias IS NOT NULL AND uuid_alias NOT IN (SELECT uuid FROM feature_alias)
UNION ALL SELECT uuid, kind, 'uuid_existing' FROM review_queue
WHERE status = 'open' AND uuid_existing IS NOT NULL AND uuid_existing NOT IN (SELECT uuid FROM analysis)
UNION ALL SELECT uuid, kind, 'uuid_target' FROM review_queue
WHERE status = 'open' AND uuid_target IS NOT NULL AND uuid_target NOT IN (
  SELECT uuid FROM feature_alias UNION ALL SELECT uuid FROM project
  UNION ALL SELECT uuid FROM feature UNION ALL SELECT uuid FROM \"sample\")
UNION ALL SELECT uuid, kind, 'source_hash' FROM review_queue
WHERE status = 'open' AND source_hash IS NOT NULL AND source_hash NOT IN (
  SELECT hash FROM ingest_file UNION ALL SELECT hash FROM asset WHERE hash IS NOT NULL)
UNION ALL SELECT c.uuid, 'candidate', 'review_queue_candidate.uuid_feature'
FROM review_queue_candidate c JOIN review_queue r ON r.uuid = c.uuid_review
WHERE r.status = 'open' AND c.uuid_feature NOT IN (SELECT uuid FROM feature)",
       "Open review items point at rows that still exist (resolved items are history).", "hourly", "error"),
    ck("review_resolved_dangling", "
SELECT uuid AS key, kind, subkind, uuid_alias FROM review_queue
WHERE status <> 'open' AND uuid_alias IS NOT NULL AND uuid_alias NOT IN (SELECT uuid FROM feature_alias)",
       "Resolved review items whose alias has since been deleted (expected after merges; informational).",
       "on_demand", "warn"),
    ck("change_log_dangling_source_hash", "
SELECT source_hash AS key, count(*) AS n FROM change_log
WHERE source_hash IS NOT NULL AND source_hash NOT IN (
  SELECT hash FROM ingest_file UNION ALL SELECT hash FROM asset WHERE hash IS NOT NULL)
GROUP BY source_hash",
       "change_log provenance hashes that no longer resolve to a file.", "on_demand", "warn"),
    # ---- duplicates / identity
    ck("dup_analysis_sample_method", "
SELECT uuid_sample || ' ' || uuid_lab AS key, count(*) AS n, string_agg(uuid, ' ') AS uuids
FROM analysis GROUP BY uuid_sample, uuid_lab HAVING count(*) > 1",
       "At most one analysis per (sample, lab_method).", "hourly", "error"),
    ck("dup_sample_identity_null_datetime", .dbc_dup_sample_identity_null_datetime,
       paste("Sample identity duplicates with a NULL datetime, which ux_sample_identity treats as distinct;",
             "a group whose samples each carry exactly one analysis stream, all different, is exempt (A91 D3)."),
       "hourly", "warn"),
    ck("dup_asset_hash", "
SELECT hash AS key, sum(n) AS n, string_agg(uuids, ' ') AS uuids FROM (
  SELECT hash, uuid_project, count(*) AS n, string_agg(uuid, ' ') AS uuids FROM asset
  WHERE hash IS NOT NULL GROUP BY hash, uuid_project HAVING count(*) > 1)
GROUP BY hash",
       "One asset per content hash within a project (a NULL project is one group); one report filed under several projects is legitimate (migration 061).",
       "hourly", "error"),
    ck("dup_lab_method_key", "
SELECT concat_ws(' | ', name, method, organisation, fraction, uuid_analyte) AS key,
       count(*) AS n, string_agg(uuid, ' ') AS uuids
FROM lab_method GROUP BY uuid_analyte, method, organisation, fraction, name HAVING count(*) > 1",
       "No two lab_method rows share a natural key.", "hourly", "error"),
    # ---- alias invariants
    ck("alias_self_arm", "
SELECT f.uuid AS key, f.name, count(fa.uuid) AS n_self FROM feature f
LEFT JOIN feature_alias fa ON fa.uuid_feature = f.uuid AND fa.kind = 'self'
GROUP BY f.uuid, f.name HAVING count(fa.uuid) <> 1
UNION ALL
SELECT f.uuid, f.name || ' <> ' || fa.name, -1 FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
WHERE fa.kind = 'self' AND fa.name IS DISTINCT FROM f.name",
       "Every feature has exactly one self alias, named as the feature.", "hourly", "error"),
    ck("alias_pending_consistent", "
SELECT uuid AS key, name, kind AS problem FROM feature_alias
WHERE (kind = 'pending') <> (uuid_feature IS NULL)
UNION ALL
SELECT fa.uuid, fa.name, 'pending without open review' FROM feature_alias fa
WHERE fa.kind = 'pending' AND NOT EXISTS (
  SELECT 1 FROM review_queue r WHERE r.uuid_alias = fa.uuid AND r.status = 'open')",
       "Unresolved aliases are exactly the pending ones, and each has an open review item.", "hourly", "error"),
    ck("alias_key_normalised", .dbc_alias_key_normalised,
       "feature_alias.alias_key is the normalised alias name (.rc_feature_key()).", "hourly", "warn"),
    ck("alias_window_ambiguous", "
SELECT a.uuid || ' ' || b.uuid AS key, a.alias_key, a.kind AS kind_a, b.kind AS kind_b,
       a.date_start AS ds_a, a.date_end AS de_a, b.date_start AS ds_b, b.date_end AS de_b
FROM feature_alias a JOIN feature_alias b ON a.alias_key = b.alias_key AND a.uuid < b.uuid
WHERE a.auto_assign AND b.auto_assign AND a.kind <> 'self' AND b.kind <> 'self'
  AND a.uuid_feature IS DISTINCT FROM b.uuid_feature
  AND ((a.date_start IS NULL AND a.date_end IS NULL) = (b.date_start IS NULL AND b.date_end IS NULL))
  AND coalesce(a.date_start, DATE '1900-01-01') <= coalesce(b.date_end, DATE '2999-12-31')
  AND coalesce(b.date_start, DATE '1900-01-01') <= coalesce(a.date_end, DATE '2999-12-31')",
       "Two equally specific auto-assign arms of one key, overlapping, on different features (an import on the overlap goes to review).",
       "on_demand", "warn"),
    # ---- accepted values
    ck("vocab_lab_method_fraction", "
SELECT uuid AS key, fraction FROM lab_method WHERE fraction IS NOT NULL AND fraction NOT IN ({fractions})",
       "lab_method.fraction is in the fraction vocabulary or NULL.", "hourly", "error"),
    ck("fraction_matches_code", .dbc_fraction_matches_code,
       "lab_method.fraction agrees with the method code commit mints it from.", "migration", "warn"),
    ck("vocab_feature_alias_kind", "
SELECT uuid AS key, kind FROM feature_alias WHERE kind IS NULL OR kind NOT IN ({alias_kinds})",
       "feature_alias.kind is an alias kind or 'pending'.", "hourly", "error"),
    ck("vocab_ingest_state", "
SELECT hash AS key, state FROM ingest_file WHERE state IS NULL OR state NOT IN ({ingest_states})",
       "ingest_file.state is a state of the ingest state machine.", "hourly", "error"),
    ck("vocab_review_status", "
SELECT uuid AS key, status, resolved_at, resolution FROM review_queue
WHERE status IS NULL OR status NOT IN ({review_statuses})
   OR (status = 'resolved' AND (resolved_at IS NULL OR resolution IS NULL))
   OR (status = 'open' AND resolved_at IS NOT NULL)",
       "review_queue.status is known and its resolved_* fields agree with it.", "hourly", "error"),
    ck("vocab_mask_variant", "
SELECT 'feature_mask:' || variant AS key, count(*) AS n FROM feature_mask
WHERE variant NOT IN ({mask_variants}) GROUP BY variant
UNION ALL SELECT 'analyte_mask:' || variant, count(*) FROM analyte_mask
WHERE variant NOT IN ({mask_variants}) GROUP BY variant",
       "Mask variants are registered (core: long, old, gas_report; a deployment adds its own).",
       "hourly", "warn"),
    ck("vocab_feature_flow", "
SELECT uuid AS key, name, flow FROM feature WHERE flow IS NOT NULL AND flow NOT IN ({flows})",
       "feature.flow is in the flow vocabulary or NULL.", "hourly", "warn"),
    ck("analysis_value_shape", "
SELECT uuid AS key, value, value_chr, quantified, rl_low, rl_high FROM analysis
WHERE (value IS NULL) = (value_chr IS NULL)
   OR (value IS NOT NULL AND (isnan(value) OR isinf(value)))
   OR (value IS NOT NULL AND quantified IS NULL)
   OR rl_low < 0 OR rl_low > rl_high",
       "Exactly one of value / value_chr; finite numbers; numeric rows carry quantified; 0 <= rl_low <= rl_high.",
       "hourly", "error"),
    ck("hash_format", "
SELECT hash AS key, 'ingest_file' AS tbl FROM ingest_file
WHERE hash IS NULL OR NOT regexp_full_match(hash, '[0-9a-f]{32}')
UNION ALL SELECT hash, 'asset' FROM asset
WHERE hash IS NOT NULL AND NOT regexp_full_match(hash, '[0-9a-f]{32}')
UNION ALL SELECT uuid || ' ' || source_hash, 'review_queue' FROM review_queue
WHERE source_hash IS NOT NULL AND NOT regexp_full_match(source_hash, '[0-9a-f]{32}')",
       "Content hashes are xxHash128 (32 lower-case hex; R/hash.R).", "hourly", "error"),
    ck("change_log_shape", "
SELECT uuid AS key, tbl, action, actor FROM change_log
WHERE actor IS NULL OR reason IS NULL OR action IS NULL
   OR action NOT IN ('insert', 'update', 'delete', 'provenance')
   OR tbl IS NULL OR tbl NOT IN (SELECT table_name FROM duckdb_tables())
   OR (source_hash IS NOT NULL AND NOT regexp_full_match(source_hash, '[0-9a-f]{32}'))",
       "change_log rows carry actor and reason, a known action and table, and xxHash provenance.",
       "on_demand", "warn"),
    # ---- dates
    ck("sample_date_plausible", "
SELECT uuid AS key, date, datetime FROM \"sample\"
WHERE coalesce(datetime, date) IS NULL
   OR date > now()::TIMESTAMP + INTERVAL 2 DAY OR datetime > now()::TIMESTAMP + INTERVAL 2 DAY
   OR coalesce(datetime, date) < TIMESTAMP '{min_date}'
   OR datetime_start > datetime OR date_start > date",
       "Sample dates exist, are not in the future or before min_date, and start <= end.", "hourly", "error"),
    ck("sample_date_datetime_agree", "
SELECT uuid AS key, date, datetime FROM \"sample\" WHERE datetime IS NOT NULL
  AND CAST(timezone('{tz}', timezone('UTC', datetime)) AS DATE)
   <> CAST(timezone('{tz}', timezone('UTC', date)) AS DATE)",
       "sample.date and sample.datetime name the same day in the configured time zone.", "hourly", "warn"),
    ck("sample_in_feature_window", "
SELECT s.uuid AS key, f.name, f.date_start, f.date_end, coalesce(s.datetime, s.date) AS at_
FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
JOIN feature f ON f.uuid = fa.uuid_feature
WHERE (f.date_start IS NOT NULL
       AND CAST(timezone('{tz}', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) < f.date_start)
   OR (f.date_end IS NOT NULL
       AND CAST(timezone('{tz}', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) > f.date_end)",
       "Samples fall inside their feature's live window.", "on_demand", "warn"),
    ck("date_windows_ordered", "
SELECT uuid AS key, 'feature' AS tbl FROM feature WHERE date_start > date_end
UNION ALL SELECT uuid, 'feature_alias' FROM feature_alias WHERE date_start > date_end
UNION ALL SELECT uuid_feature, 'qc_feature' FROM qc_feature WHERE date_start > date_end
UNION ALL SELECT uuid, 'project' FROM project WHERE date_start > date_end",
       "No transposed validity windows.", "hourly", "error"),
    # ---- coordinates
    ck("feature_coords", "
SELECT uuid AS key, name, lon, lat, geom_wkt FROM feature WHERE NOT coalesce(virtual, false) AND (
     lon IS NULL OR lat IS NULL OR isnan(lon) OR isnan(lat) OR isinf(lon) OR isinf(lat)
  OR NOT (lon BETWEEN {bbox_xmin} AND {bbox_xmax} AND lat BETWEEN {bbox_ymin} AND {bbox_ymax}))",
       "Physical features have finite coordinates, inside the bbox when one is configured.", "hourly", "warn"),
    ck("feature_geom_matches_lonlat", "
SELECT uuid AS key, name, lon, lat, geom_wkt FROM feature
WHERE NOT isnan(lon) AND NOT isnan(lat) AND (geom_wkt IS NULL OR
  abs(CAST(regexp_extract(geom_wkt, 'POINT \\(([-0-9.eE]+) ', 1) AS DOUBLE) - lon) > 1e-4 OR
  abs(CAST(regexp_extract(geom_wkt, ' ([-0-9.eE]+)\\)$', 1) AS DOUBLE) - lat) > 1e-4)",
       "geom_wkt and lon/lat agree to 1e-4 degrees.", "on_demand", "warn")
  )
}

# ---- running ---------------------------------------------------------------------------

.dbc_run_one <- function(con, sql, tokens, params) {
  r <- if (is.function(sql)) sql(con, params) else DBI::dbGetQuery(con, .dbc_fill(sql, tokens))
  if (!is.data.frame(r)) stop("the check did not return a data.frame")
  if (!"key" %in% names(r)) stop("the check's result has no `key` column")
  r$key <- as.character(r$key)
  r
}

#' Run the standing database checks
#'
#' Runs each check's query on `con` and reports one row per check. It never
#' aborts on a check: a query that errors gets `status = "error"` and the
#' rest still run. Read-only: safe on a `read_only = TRUE` connection.
#'
#' Outside a transaction each query runs on its own, so one failing check
#' cannot affect the others. Inside an open transaction DuckDB aborts the
#' whole transaction on an execution-time error, so after such an error the
#' later checks report `"error"` too (see [mig_db_checks_gate()]).
#'
#' @param con an open DBI connection to a sampleTidy DuckDB database.
#' @param tier `"hourly"`, `"migration"` (hourly + migration checks) or
#'   `"all"` (adds the on-demand checks).
#' @param extra a deployment's own checks ([db_check()] rows), or `NULL`. A
#'   name that clashes with a core check, or repeats within `extra`, is an
#'   error.
#' @param params [db_checks_params()].
#' @param sample_n how many offending rows to keep per check.
#' @return a data.frame, one row per check run: `name`, `tier`, `severity`,
#'   `status` (`"pass"`, `"fail"` or `"error"`), `n` (offenders; `NA` on
#'   error), `ms`, `sample` (a list column of the first `sample_n` offending
#'   rows), `message` (the error message, else `NA`) and `keys` (a list
#'   column of every offender's key).
#' @export
db_checks <- function(con, tier = "hourly", extra = NULL, params = db_checks_params(), sample_n = 5) {
  if (!checkmate::test_choice(tier, names(.dbc_tier_runs))) {
    cli::cli_abort("{.arg tier} must be one of {.val {names(.dbc_tier_runs)}}, not {.val {tier}}.",
                   class = "sampletidy_error")
  }
  checkmate::assert_list(params)
  checkmate::assert_count(sample_n)
  checks <- db_checks_core()
  if (!is.null(extra)) {
    checkmate::assert_data_frame(extra)
    if (!all(c("name", "sql", "tier", "severity") %in% names(extra))) {
      cli::cli_abort("{.arg extra} must be db_check() rows.", class = "sampletidy_error")
    }
    clash <- unique(c(intersect(extra$name, checks$name), extra$name[duplicated(extra$name)]))
    if (length(clash)) {
      cli::cli_abort("Duplicate db check name{?s}: {.val {clash}}.", class = "sampletidy_error")
    }
    checks <- rbind(checks, extra[, names(checks)])
  }
  checks <- checks[checks$tier %in% .dbc_tier_runs[[tier]], , drop = FALSE]
  tokens <- .dbc_tokens(params)

  k <- nrow(checks)
  status <- character(k); n <- integer(k); ms <- numeric(k); msg <- rep(NA_character_, k)
  sample <- vector("list", k); keys <- vector("list", k)
  for (i in seq_len(k)) {
    t0 <- proc.time()[["elapsed"]]
    r <- tryCatch(.dbc_run_one(con, checks$sql[[i]], tokens, params), error = function(e) e)
    ms[i] <- (proc.time()[["elapsed"]] - t0) * 1000
    if (inherits(r, "error")) {
      status[i] <- "error"; n[i] <- NA_integer_
      msg[i] <- gsub("\\s+", " ", trimws(conditionMessage(r)))
      sample[[i]] <- data.frame(key = character(), stringsAsFactors = FALSE)
      keys[[i]] <- character()
    } else {
      n[i] <- nrow(r)
      status[i] <- if (n[i] == 0) "pass" else "fail"
      sample[[i]] <- utils::head(r, sample_n)
      rownames(sample[[i]]) <- NULL
      keys[[i]] <- unique(r$key)
    }
  }
  out <- data.frame(name = checks$name, tier = checks$tier, severity = checks$severity,
                    status = status, n = n, ms = ms, stringsAsFactors = FALSE)
  out$sample <- sample
  out$message <- msg
  out$keys <- keys
  rownames(out) <- NULL
  out
}

#' Gate a migration on the standing database checks
#'
#' Call before COMMIT, inside the migration's transaction, with a `baseline`
#' taken by [db_checks()] before the change:
#'
#' ```
#' baseline <- db_checks(con, tier = "migration")
#' # ... the migration's writes, inside its transaction ...
#' mig_db_checks_gate(con, baseline)
#' ```
#'
#' Re-runs the migration-tier checks and aborts (class `sampletidy_error`) on
#' a NEW failure: a check that passed or was absent in the baseline and now
#' fails or errors, a check that errored in the baseline and now fails, or a
#' failing check whose offending keys (all of them, not just the sample)
#' include one the baseline did not. Failures already present are printed
#' but do not block. The gate never opens or closes a transaction: the
#' caller's transaction wrapper rolls back on the abort.
#'
#' Inside a transaction, DuckDB aborts the transaction on an execution-time
#' error, so one check that errors makes every later check error too. The
#' gate then aborts, which is the right outcome (the change is rolled back),
#' but the list of failing checks it names is longer than the real cause.
#'
#' @param con the connection the migration writes on.
#' @param baseline the [db_checks()] result from before the change.
#' @param allow names of checks exempt from the gate (a migration that changes
#'   an invariant on purpose).
#' @param extra,params passed to [db_checks()].
#' @return the new [db_checks()] result, invisibly.
#' @export
mig_db_checks_gate <- function(con, baseline, allow = character(), extra = NULL,
                               params = db_checks_params()) {
  checkmate::assert_data_frame(baseline)
  checkmate::assert_character(allow, any.missing = FALSE)
  now <- db_checks(con, tier = "migration", extra = extra, params = params)
  bad <- now[now$status != "pass" & !now$name %in% allow, , drop = FALSE]
  new <- character()
  old <- character()
  for (i in seq_len(nrow(bad))) {
    nm <- bad$name[[i]]
    b <- baseline[baseline$name == nm, , drop = FALSE]
    is_new <- if (nrow(b) == 0 || b$status[[1]] == "pass") {
      TRUE
    } else if (bad$status[[i]] == "error") {
      b$status[[1]] != "error"
    } else if (b$status[[1]] == "error") {
      TRUE
    } else {
      bkeys <- if ("keys" %in% names(b)) b$keys[[1]] else as.character(b$sample[[1]]$key)
      added <- setdiff(bad$keys[[i]], bkeys)
      if (length(added)) {
        bad$message[[i]] <- paste0("new offender(s): ", paste(utils::head(added, 5), collapse = ", "))
      }
      length(added) > 0
    }
    lab <- sprintf("%s (%s%s)", nm, bad$status[[i]],
                   if (is.na(bad$message[[i]])) sprintf(", n = %s", bad$n[[i]]) else paste0(": ", bad$message[[i]]))
    lab <- gsub("}", "}}", gsub("{", "{{", lab, fixed = TRUE), fixed = TRUE)  # literal for cli
    if (is_new) new <- c(new, lab) else old <- c(old, lab)
  }
  if (length(old)) {
    cli::cli_inform(c("DB checks already failing before this change (not blocking):",
                      stats::setNames(old, rep("*", length(old)))))
  }
  if (length(new)) {
    cli::cli_abort(c("The change breaks {length(new)} DB check{?s}:",
                     stats::setNames(new, rep("x", length(new)))),
                   class = "sampletidy_error")
  }
  invisible(now)
}
