# Operator-run migration: a `fraction` column on lab_method, the naphthalene method
# preference, and a fraction-aware ranking in the five v_measurement* views.
# Marker 1070. Requires 1069.
#
# Authority: Robin, 2026-10-22 ("fractions"): keep both the total and the dissolved
# result of a sample; keep both TDS methods (prefer measured EA015) and both
# naphthalene methods (prefer the more precise EP075(SIM)B; Robin 2026-10-22: the two
# EP075(SIM)B methods must not tie - choose one and stick to it). The views choose:
# for a feature with flow = 'groundwater' prefer dissolved, everywhere else prefer
# total; then lab_method.preference; then the lower reporting limit.
#
# ---- WHY -----------------------------------------------------------------------
# The views rank the results of one (feature, Sydney date, analyte) partition with
#     COALESCE(lm.preference, 500) ASC, is_field DESC, is_als DESC, s.uuid, a.uuid
# (005; date from 022). A dissolved and a total result of one analyte tie on every
# key but the uuids, so which one a consumer gets as preference_rank = 1 is
# arbitrary. 31 live partitions hold both today (B.L01, B.L05, B.S01, B.S05,
# B.TS39); the fractions backfill adds more.
#
# ---- WHAT (frozen in 070-lab-method-fraction-INPUT-lab_method.csv) --------------
#   1  ALTER TABLE lab_method ADD COLUMN fraction VARCHAR, filled for the ALS
#      methods whose code is ED/EG + 3 digits + an optional "(...)" + F or T:
#      F -> 'dissolved', T -> 'total'. The code is the text before the first
#      colon after dropping any ESdat "CODE - " prefix (R/reconcile.R
#      .rc_strip_method_code_prefix). 47 rows: 24 dissolved, 23 total. Every
#      other lab_method stays NULL. At run time the rule is re-applied to EVERY
#      lab_method and must give exactly the frozen set (a method minted since the
#      freeze refuses the run: re-freeze).
#   2  lab_method.preference (lower ranks first; NULL = 500, neutral, per 005):
#      EP075(SIM)B "Naphthalene" (f206058c) 100, EP075(SIM)B "Naphthalene (Ex SVOC)"
#      (9b1c6e2f) 110, EP080 naphthalene (6c08a2df) 200 - a strict order, the
#      shape TDS already has (EA015 100, EA016 200: no change there; the verify
#      asserts it).
#   3  The five views' preference_rank ORDER BY becomes
#        fraction_rank ASC, COALESCE(lm.preference, 500) ASC, is_field DESC,
#        is_als DESC, rl_rank ASC NULLS LAST, s.uuid, a.uuid
#      with
#        fraction_rank = 0 for the preferred fraction of the feature's flow
#                        (dissolved for 'groundwater', total otherwise),
#                        1 for a method with no fraction (or no lab_method),
#                        2 for the other fraction;
#        rl_rank       = a.rl_low when it is > 0, else NULL (an rl_low of 0 or
#                        NULL says nothing about precision).
#      rl_rank sits AFTER is_field/is_als, not straight after preference: placed
#      before them it would rank a lab pH/EC (rl_low 0.01/1) above the field
#      reading (rl_low NULL) in ~941 live partitions, overturning the
#      field-beats-lab ruling of 2026-07-24. Nothing else in the SQL changes; the
#      new text is generated from duckdb_views() and must read back byte for byte.
#
# ---- NOT DONE ---------------------------------------------------------------------
#   The two EP075(SIM)B naphthalene methods (f206058c "Naphthalene", 9b1c6e2f
#   "Naphthalene (Ex SVOC)", minted by 056 D13) are NOT merged: all 93 samples with
#   an Ex SVOC result also hold the plain one at the same value (a repoint would
#   collide on (sample, lab_method)), and the lab's name is half of the registry's
#   match key, so deleting 9b1c6e2f would make the next "Naphthalene (Ex SVOC)"
#   row an unknown analyte. They do NOT tie (Robin 2026-10-22: choose one and stick to
#   it): the plain one (230 results) gets 100, Ex SVOC (93, every one duplicated on the
#   plain one at the same value) 110, so the plain one is always preference_rank 1.
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before: marker 1069; no fraction column; every frozen lab_method row byte for
#   byte as frozen (sha1); the rule over all lab_methods = the frozen set; each of
#   the five views holds the two ORDER BY anchors exactly once and no other view
#   mentions preference_rank.
#   After (same transaction): stored view SQL = planned; every view's output other
#   than preference_rank unchanged (checksum); preference_rank changes only in
#   partitions holding both fractions or a method whose preference changed;
#   every base table except lab_method checksummed unchanged, and lab_method
#   unchanged outside the planned (row, column) cells; change_log rows as planned.
#
# One transaction: ALTER, the 47 + 3 updates (db_update -> change_log), the five
# CREATE OR REPLACE VIEWs, the marker, the verify. Backups: verified whole-file
# snapshot, BACKUP CSVs of the 50 lab_method rows and the 5 old view definitions.
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/070-lab-method-fraction.R", envir = env)
#   env$mig070_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig070_marker_version <- 1070L
.mig070_requires <- 1069L
.mig070_name <- "070-lab-method-fraction"
.mig070_actor <- .mig070_name
.mig070_n <- list(fraction = 47L, dissolved = 24L, total = 23L, preference = 3L)
.mig070_reason <- "070 (Robin 2026-10-22: keep both fractions; views prefer dissolved for groundwater, total elsewhere)"
.mig070_views <- c("v_measurement", "v_measurement_epa", "v_measurement_gas_report",
                   "v_measurement_long", "v_measurement_old")

# The two anchors in each view's stored SQL, and what each becomes. The inserted
# expressions are written in DuckDB's own normalised form so the stored text reads
# back byte for byte.
.mig070_old1 <- "ORDER BY COALESCE(lm.preference, 500) ASC, "
.mig070_old2 <- "CAST('f' AS BOOLEAN)) DESC, s.uuid, a.uuid) AS preference_rank"
.mig070_frac_sql <- paste0("CASE  WHEN ((lm.fraction IS NULL)) THEN (1) WHEN (((lm.fraction = 'dissolved') = ",
                           "COALESCE((f.flow = 'groundwater'), CAST('f' AS BOOLEAN)))) THEN (0) ELSE 2 END ASC, ")
.mig070_rl_sql <- "CASE  WHEN ((a.rl_low > 0)) THEN (a.rl_low) ELSE NULL END ASC NULLS LAST, "
.mig070_new1 <- paste0("ORDER BY ", .mig070_frac_sql, "COALESCE(lm.preference, 500) ASC, ")
.mig070_new2 <- paste0("CAST('f' AS BOOLEAN)) DESC, ", .mig070_rl_sql, "s.uuid, a.uuid) AS preference_rank")

.mig070_fail <- function(msg) cli::cli_abort(paste0(.mig070_name, ": ", msg), class = "sampletidy_error")
.mig070_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig070_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig070_count_fixed <- function(x, pat) lengths(regmatches(x, gregexpr(pat, x, fixed = TRUE)))
.mig070_int <- function(x) if (is.na(x) || !nzchar(x)) NA_integer_ else as.integer(x)

.mig070_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- the classification rule --------------------------------------------------------

# Method code: the text before the first colon, after dropping an ESdat "CODE - "
# prefix (everything up to the last " - " before that colon). NA without a colon.
.mig070_method_code <- function(method) {
  out <- rep(NA_character_, length(method))
  has <- !is.na(method) & grepl(":", method, fixed = TRUE)
  head <- sub(":.*$", "", method[has])
  head <- ifelse(grepl(" - ", head, fixed = TRUE), sub("^.* - ", "", head), head)
  out[has] <- trimws(head)
  out
}

# 'dissolved' / 'total' / NA from a lab_method.method.
.mig070_fraction <- function(method) {
  code <- .mig070_method_code(method)
  out <- rep(NA_character_, length(method))
  out[!is.na(code) & grepl("^E[DG][0-9]{3}(\\([^)]*\\))?F$", code)] <- "dissolved"
  out[!is.na(code) & grepl("^E[DG][0-9]{3}(\\([^)]*\\))?T$", code)] <- "total"
  out
}

# ---- inputs ---------------------------------------------------------------------------

.mig070_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT-lab_method.csv", .mig070_name))
  if (!file.exists(p)) .mig070_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (anyDuplicated(x$uuid)) .mig070_fail("INPUT repeats a lab_method.")
  if (!all(x$op %in% c("fraction", "preference"))) .mig070_fail("INPUT has an unknown op.")
  fr <- x[x$op == "fraction", , drop = FALSE]
  pf <- x[x$op == "preference", , drop = FALSE]
  got <- list(fraction = nrow(fr), dissolved = sum(fr$fraction == "dissolved"), total = sum(fr$fraction == "total"),
              preference = nrow(pf))
  if (!identical(got, .mig070_n)) .mig070_fail(sprintf("INPUT counts are %s, not as planned.",
                                                       paste(names(got), unlist(got), sep = "=", collapse = " ")))
  if (!identical(.mig070_fraction(fr$method), fr$fraction)) .mig070_fail("an INPUT fraction does not follow the rule.")
  if (!all(fr$organisation == "ALS")) .mig070_fail("a classified lab_method is not ALS.")
  if (any(is.na(pf$preference_new))) .mig070_fail("a preference row has no new value.")
  list(fraction = fr, preference = pf, all = x)
}

# sha1 of each row as text (as 069; the frozen value in the INPUT comes from this
# same function over the pre-migration row).
.mig070_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df$uuid)
}

.mig070_row_sha <- function(con, ids, cols = NULL) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  sel <- if (is.null(cols)) "*" else paste0('"', cols, '"', collapse = ", ")
  df <- DBI::dbGetQuery(con, sprintf("SELECT %s FROM lab_method WHERE uuid IN %s", sel, .mig070_inlist(ids)))
  s <- .mig070_df_sha(df)
  out[names(s)] <- s
  out
}

# ---- views ----------------------------------------------------------------------------

.mig070_view_defs <- function(con) {
  DBI::dbGetQuery(con, "SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
}

.mig070_new_sql <- function(sql) {
  out <- sub(.mig070_old1, .mig070_new1, sql, fixed = TRUE)
  sub(.mig070_old2, .mig070_new2, out, fixed = TRUE)
}

# Every view's output in a fixed order, preference_rank split off: `rest` is the
# sha1 of everything else, `rank` the (uuid_analysis, preference_rank) pairs.
.mig070_view_state <- function(con) {
  out <- list()
  for (v in .mig070_view_defs(con)$view_name) {
    df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" ORDER BY ALL', v))
    if ("preference_rank" %in% names(df)) {
      rk <- df[, c("uuid_analysis", "preference_rank")]
      df$preference_rank <- NULL
      df <- df[do.call(order, unname(as.list(df))), , drop = FALSE]
      rownames(df) <- NULL
      out[[v]] <- list(n = nrow(df), rest = digest::digest(df, algo = "sha1"), rank = rk)
    } else {
      out[[v]] <- list(n = nrow(df), rest = digest::digest(df, algo = "sha1"), rank = NULL)
    }
  }
  out
}

# Partition key of each analysis, exactly as the views form it.
.mig070_partition_sql <- "
  SELECT a.uuid AS uuid_analysis,
         f.uuid || '|' || CAST(CAST(timezone('Australia/Sydney', timezone('UTC', COALESCE(s.datetime, s.date))) AS DATE) AS VARCHAR)
           || '|' || COALESCE(lm.uuid_analyte, ('analysis:' || a.uuid)) AS part,
         lm.uuid AS uuid_lab, lm.fraction
  FROM analysis a JOIN sample s ON a.uuid_sample = s.uuid
  JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON fa.uuid_feature = f.uuid
  LEFT JOIN lab_method lm ON a.uuid_lab = lm.uuid"

# Partitions where a rank change is planned: two fractions, or a method whose
# preference changes.
.mig070_allowed_parts <- function(con, pref_uuids) {
  P <- DBI::dbGetQuery(con, .mig070_partition_sql)
  nfr <- tapply(P$fraction, P$part, function(z) length(unique(z[!is.na(z)])))
  two <- names(nfr)[nfr >= 2L]
  pref <- unique(P$part[!is.na(P$uuid_lab) & P$uuid_lab %in% pref_uuids])
  list(parts = P, allowed = union(two, pref), two = two, pref = pref)
}

.mig070_rank_diff <- function(before, after, parts) {
  out <- list()
  for (v in .mig070_views) {
    b <- before[[v]]$rank; a <- after[[v]]$rank
    m <- merge(b, a, by = "uuid_analysis", suffixes = c("_old", "_new"))
    ch <- m[m$preference_rank_old != m$preference_rank_new, , drop = FALSE]
    ch$part <- parts$part[match(ch$uuid_analysis, parts$uuid_analysis)]
    out[[v]] <- ch
  }
  out
}

# ---- preconditions -----------------------------------------------------------------

.mig070_check_preconditions <- function(con, x) {
  fail <- .mig070_fail
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig070_requires, have)
  if (length(miss)) fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  cols <- DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns WHERE table_name = 'lab_method'")$column_name
  if ("fraction" %in% cols) fail("lab_method already has a fraction column.")
  if (!("preference" %in% cols)) fail("lab_method has no preference column (005).")
  # frozen rows as frozen
  sha <- .mig070_row_sha(con, x$all$uuid)
  bad <- x$all$uuid[is.na(sha[x$all$uuid]) | sha[x$all$uuid] != x$all$row_sha1]
  if (length(bad)) fail(sprintf("lab_method row(s) not as frozen: %s.", paste(bad, collapse = ", ")))
  # the rule over the whole registry gives exactly the frozen set
  lm <- DBI::dbGetQuery(con, "SELECT uuid, method FROM lab_method")
  fr <- .mig070_fraction(lm$method)
  got <- sort(paste(lm$uuid[!is.na(fr)], fr[!is.na(fr)]))
  want <- sort(paste(x$fraction$uuid, x$fraction$fraction))
  if (!identical(got, want)) fail(sprintf("the fraction rule now classifies %d lab_methods, not the %d frozen: re-freeze.",
                                          length(got), length(want)))
  # preference: frozen old values; TDS already EA015 < EA016
  cur <- DBI::dbGetQuery(con, sprintf("SELECT uuid, preference FROM lab_method WHERE uuid IN %s", .mig070_inlist(x$preference$uuid)))
  old <- vapply(x$preference$preference_old, .mig070_int, 0L)
  if (!identical(cur$preference[match(x$preference$uuid, cur$uuid)], unname(old)))
    fail("a naphthalene preference is not as frozen.")
  # views
  defs <- .mig070_view_defs(con)
  rk <- defs$view_name[grepl("preference_rank", defs$sql, fixed = TRUE)]
  if (!setequal(rk, .mig070_views)) fail(sprintf("views with preference_rank are {%s}, expected {%s}.",
                                                 paste(rk, collapse = ", "), paste(.mig070_views, collapse = ", ")))
  defs <- defs[match(.mig070_views, defs$view_name), ]
  n1 <- .mig070_count_fixed(defs$sql, .mig070_old1)
  n2 <- .mig070_count_fixed(defs$sql, .mig070_old2)
  nf <- .mig070_count_fixed(defs$sql, "fraction")
  if (any(n1 != 1L) || any(n2 != 1L) || any(nf != 0L))
    fail(sprintf("view anchors not found exactly once (or fraction already present) in: %s.",
                 paste(defs$view_name[n1 != 1L | n2 != 1L | nf != 0L], collapse = ", ")))
  defs
}

# ---- verify ---------------------------------------------------------------------------

.mig070_done_problem <- function(con, x) {
  if (.mig070_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig070_marker_version) != 1L)
    return("marker 1070 missing")
  cols <- DBI::dbGetQuery(con, "SELECT column_name, data_type FROM information_schema.columns WHERE table_name = 'lab_method'")
  if (!identical(cols$data_type[cols$column_name == "fraction"], "VARCHAR")) return("lab_method.fraction missing or not VARCHAR")
  lm <- DBI::dbGetQuery(con, "SELECT uuid, method, fraction, preference FROM lab_method")
  want <- stats::setNames(rep(NA_character_, nrow(lm)), lm$uuid)
  want[x$fraction$uuid] <- x$fraction$fraction
  if (!identical(stats::setNames(lm$fraction, lm$uuid), want)) return("lab_method.fraction is not as planned")
  if (!identical(lm$fraction, .mig070_fraction(lm$method))) return("lab_method.fraction does not follow the rule")
  pf <- x$preference
  if (!identical(lm$preference[match(pf$uuid, lm$uuid)], unname(vapply(pf$preference_new, .mig070_int, 0L))))
    return("a naphthalene preference is not as planned")
  # strict order, no tie (Robin 2026-10-22): plain EP075(SIM)B < Ex SVOC EP075(SIM)B < EP080
  np <- lm$preference[match(c("f206058c-6b19-415b-90d6-b2c0061f80ad", "9b1c6e2f-3d48-4f7a-8c05-56d2e4f6a8b1",
                              "6c08a2df-fd54-42d3-b915-af74bfaaf8b0"), lm$uuid)]
  if (anyNA(np) || !(np[[1]] < np[[2]] && np[[2]] < np[[3]])) return("the naphthalene methods are not strictly ordered EP075(SIM)B < Ex SVOC < EP080")
  tds <- DBI::dbGetQuery(con, "SELECT method, preference FROM lab_method WHERE organisation = 'ALS'
    AND (method LIKE 'EA015:%' OR method LIKE 'EA016:%') AND uuid_analyte IS NOT NULL")
  p15 <- tds$preference[startsWith(tds$method, "EA015:")]; p16 <- tds$preference[startsWith(tds$method, "EA016:")]
  if (!length(p15) || !length(p16) || anyNA(c(p15, p16)) || max(p15) >= min(p16)) return("TDS EA015 does not rank above EA016")
  defs <- .mig070_view_defs(con)
  defs <- defs[match(.mig070_views, defs$view_name), ]
  if (anyNA(defs$view_name)) return("a view is missing")
  if (any(.mig070_count_fixed(defs$sql, .mig070_new1) != 1L) || any(.mig070_count_fixed(defs$sql, .mig070_new2) != 1L) ||
      any(.mig070_count_fixed(defs$sql, .mig070_old1) != 0L))
    return("a view does not carry the fraction ranking exactly once")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, field, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL ORDER BY ALL",
                       params = list(.mig070_actor))
  got <- stats::setNames(as.integer(L$n), paste(L$tbl, L$action, L$field, sep = "|"))
  exp <- c("lab_method|update|fraction" = nrow(x$fraction), "lab_method|update|preference" = nrow(x$preference))
  if (!identical(got[sort(names(got))], exp[sort(names(exp))])) return(sprintf("070 change_log rows are %s",
                                                                    paste(names(got), got, sep = "=", collapse = " ")))
  NULL
}

.mig070_verify <- function(con, x) {
  pr <- .mig070_done_problem(con, x)
  if (!is.null(pr)) cli::cli_abort(paste0("070 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig070_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_alias", "lab_method", "analyte", "project", "change_log", "schema_version")
  tabs <- intersect(tabs, DBI::dbListTables(con))
  stats::setNames(lapply(tabs, function(t) .mig070_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table except lab_method/change_log/schema_version whole; lab_method on
# its pre-070 columns, with the preference of the 3 planned rows blanked; change_log
# and schema_version outside this migration's own rows.
.mig070_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("lab_method", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  lm_cols <- setdiff(DBI::dbGetQuery(con, "SELECT column_name FROM information_schema.columns
    WHERE table_name = 'lab_method' ORDER BY ordinal_position")$column_name, "fraction")
  sel <- paste0('"', lm_cols, '"', collapse = ", ")
  sel <- sub('"preference"', sprintf("CASE WHEN uuid IN %s THEN NULL ELSE preference END AS preference",
                                     .mig070_inlist(x$preference$uuid)), sel, fixed = TRUE)
  out$lab_method_rest <- q(sprintf("SELECT %s FROM lab_method ORDER BY uuid", sel))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig070_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig070_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# ---- apply ---------------------------------------------------------------------------------

.mig070_apply <- function(con, x, defs, recorded_at, logf) {
  want_sql <- .mig070_new_sql(defs$sql)
  sums_before <- .mig070_checksum(con, x)
  counts_want <- .mig070_counts(con)
  counts_want$change_log <- counts_want$change_log + nrow(x$fraction) + nrow(x$preference)
  counts_want$schema_version <- counts_want$schema_version + 1L
  vs_before <- .mig070_view_state(con)
  pref_uuids <- x$preference$uuid
  db_transaction(con, function(con) {
    DBI::dbExecute(con, "ALTER TABLE lab_method ADD COLUMN fraction VARCHAR")
    fr <- x$fraction
    for (i in seq_len(nrow(fr)))
      db_update(con, "lab_method", uuid = fr$uuid[[i]], changes = list(fraction = fr$fraction[[i]]), actor = .mig070_actor,
                reason = sprintf("%s [item 1]: method code %s -> %s", .mig070_reason, fr$code[[i]], fr$fraction[[i]]))
    pf <- x$preference
    for (i in seq_len(nrow(pf)))
      db_update(con, "lab_method", uuid = pf$uuid[[i]], changes = list(preference = .mig070_int(pf$preference_new[[i]])),
                actor = .mig070_actor, reason = sprintf("%s [item 2]: %s", .mig070_reason, pf$reason[[i]]))
    for (i in seq_len(nrow(defs)))
      DBI::dbExecute(con, sub("^CREATE VIEW ", "CREATE OR REPLACE VIEW ", want_sql[[i]]))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig070_marker_version, recorded_at))
    .mig070_verify(con, x)
    now <- .mig070_view_defs(con)
    if (!identical(now$sql[match(.mig070_views, now$view_name)], want_sql))
      .mig070_fail("a stored view definition is not the planned text.")
    if (!identical(.mig070_counts(con), counts_want)) .mig070_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig070_checksum(con, x))) .mig070_fail("something outside the planned cells moved.")
    vs_after <- .mig070_view_state(con)
    for (v in names(vs_before)) {
      if (!identical(vs_before[[v]]$n, vs_after[[v]]$n) || !identical(vs_before[[v]]$rest, vs_after[[v]]$rest))
        .mig070_fail(sprintf("view %s changed outside preference_rank.", v))
    }
    ap <- .mig070_allowed_parts(con, pref_uuids)
    d <- .mig070_rank_diff(vs_before, vs_after, ap$parts)
    stray <- unique(unlist(lapply(d, function(z) setdiff(z$part, ap$allowed))))
    if (length(stray)) .mig070_fail(sprintf("preference_rank moved in %d unplanned partition(s), e.g. %s.", length(stray), stray[[1]]))
    nd <- vapply(d, function(z) length(unique(z$part)), 0L)
    logf("preference_rank changed in partitions per view: %s (allowed: %d with both fractions, %d with a re-preferred method).",
         paste(names(nd), nd, sep = "=", collapse = ", "), length(ap$two), length(ap$pref))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig070_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig070_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig070_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig070_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig070_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("070: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig070_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig070_name, what))

# ---- run ----------------------------------------------------------------------------------

mig070_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig070_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig070_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig070_verify(check_con, x), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("070 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  defs <- tryCatch({
    .mig070_ensure_icu(pre_con)
    .mig070_check_preconditions(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: lab_method.fraction on %d methods (%d dissolved, %d total); %d naphthalene preferences; %d views re-ranked.",
       nrow(x$fraction), sum(x$fraction$fraction == "dissolved"), sum(x$fraction$fraction == "total"),
       nrow(x$preference), nrow(defs))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig070_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_method WHERE uuid IN %s ORDER BY uuid",
                                                      .mig070_inlist(x$all$uuid))),
                      .mig070_csv(csv_dir, "BACKUP-lab_method"), "uuid")
    .mig070_write_csv(defs, .mig070_csv(csv_dir, "BACKUP-views"), "view_name")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row and view-definition backups written to %s", csv_dir)
  backup_path <- mig070_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig070_ensure_icu(con)
    again <- .mig070_check_preconditions(con, x)
    if (!identical(again$sql, defs$sql)) .mig070_fail("view definitions changed since the dry check; re-run.")
    .mig070_apply(con, x, again, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig070_name, .mig070_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
