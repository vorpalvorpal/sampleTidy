# Operator-run migration: convert the legacy ACIRL `Appearance` rows whose text
# conflates the watercourse STAGE with the water's APPEARANCE ("Low flow Clear")
# to the A76 split vocabulary - exactly the Stage / Appearance pair the ACIRL
# field adapter emits for the same text - so a re-import of the source workbook
# finds every converted row `already_present` instead of raising an Appearance
# `value_conflict` and minting a second, new Stage row.
#
# Authorised by Robin, 2026-10-17 ("convert legacy ACIRL Appearance rows to the
# A76 split vocabulary"). This REVERSES A76's 2026-08-01 "historical rows that
# conflate the two are left alone" for those rows; the A76 vocabulary itself is
# unchanged.
#
# ---- WHAT THE ROWS ARE (scratchpad/2026-10-17-mig025/, survey2.R / gen.R) -----
#
# lab_method 6d11d0c5 "Comments" (ACIRL, field) -> analyte `Appearance` holds
# 291 analyses: 5 inserted by the pipeline (A76-split already, re-pointed by
# 024) and 286 legacy rows (no pipeline insert in change_log). Each legacy text
# is run through the adapter's own `.st_acirl_split_observation()` (after the
# `str_squish()` the adapter applies to the cell):
#
#   stage + appearance  105 rows, 40 texts   -> action `split`
#   stage only           53 rows,  6 texts   -> action `to_stage` (50) / EXCLUDED (3)
#   already A76         106 rows (Clear 45, Cloudy 59, Slightly cloudy 2) - untouched
#   no water / other     22 rows, 19 texts ("Couldnt find", "Decomissioned", ...)
#                        - untouched: the adapter emits NEITHER analyte for them,
#                        so a re-import adds nothing and conflicts with nothing.
#
# `split` (105): the Appearance row keeps its uuid and sample; only `value_chr`
#   changes (legacy text -> the adapter's Appearance term, db_update). A NEW
#   Stage analysis (fixed uuid from the plan, db_append) goes on the same
#   sample on lab_method 45c91544 "Flow observation" (ACIRL, field) -> analyte
#   `Stage` - the lab_method the adapter's `analyte_raw = "Flow observation"`
#   resolves to (all 24 existing Stage rows, incl. the 4 pipeline ones, are on
#   it). value NA, quantified NA, rl_low/rl_high/purpose/comments NA: what the
#   commit path writes for a qualitative observation row.
# `to_stage` (50): "Dry" 43, "Non Discharge" 4, "No flow" 2, "Not running, no
#   sample" 1 carry no appearance term, so the adapter emits a Stage row only.
#   The analysis keeps its uuid and sample and moves to lab_method 45c91544
#   with `value_chr` = the adapter's Stage term ("Dry", "No discharge").
#   Moving `uuid_lab` is done as ONE set-based `DELETE ... WHERE uuid IN (50)`
#   (count asserted) plus a same-uuid db_append re-insert, with the delete's
#   change_log rows written beside it (024's pattern): duckdb 1.4.1 keeps a
#   stale FK index key after per-row DELETE/UPDATE of `analysis.uuid_lab`.
#
# Every planned sample holds exactly one Appearance analysis and NO Stage
# analysis before 025 (asserted), so after it each holds exactly one Stage and
# (split) one / (to_stage) zero Appearance - the "one Stage + one Appearance per
# sample column" the adapter emits.
#
# ---- EXCLUDED - NEED A HUMAN (025-split-legacy-appearance-EXCLUDED.csv) -------
#
# The three legacy Appearance rows whose sample ALREADY has a Stage row:
#   L.L01 2023-11-22 (ES2340624) Appearance "low Level" / Stage "Slightly Cloudy"  - swapped
#   L.L02 2023-11-22 (ES2340624) Appearance "Pooled"    / Stage "Cloudy"           - swapped
#   B.S10 2024-08-07 (ES2425916) Appearance "Dry"       / Stage "Dry" (pipeline, moved by 024)
# They are asserted untouched.
#
# ---- NOT WRITTEN ----------------------------------------------------------------
#
# `sample.comments` is not touched: the commit path never writes it on a reused
# sample, so a re-import would not either. The one legacy text carrying more than
# a stage and an appearance ("Mod flow, Clear. Only field data collected, will be
# sampled in April") therefore survives only in change_log `old` and the CSV
# backup - flagged in the report, not decided here.
#
# PLAN: `025-split-legacy-appearance-PLAN.csv` beside this file (155 rows: uuid,
# uuid_sample, feat, date_sydney, project, action, legacy_value_chr, stage,
# appearance, uuid_stage_new). Its sha1 is pinned below; an edited plan is
# refused. Every row is re-proved against the database AND against the adapter's
# split before anything is written.
#
# Every write goes through db_update()/db_append() (actor
# "025-split-legacy-appearance"), except the one set-based delete, which writes
# the change_log rows db_delete() would. One transaction (no parent rows are
# deleted, so there is no FK reason to split it): the database is either wholly
# pre-025 or wholly post-025. Everything outside the planned analysis rows is
# checksummed before and after.
#
# BACKUP OF THE ROWS: `025-split-legacy-appearance-BACKUP-analysis.csv` (the 155
# analyses as they were), plus the verified whole-file backup in `snapshot_dir`.
#
# Marker 1025. Requires 1024. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/025-split-legacy-appearance.R", envir = env)
#   env$mig025_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig025_marker_version <- 1025L
.mig025_requires <- 1024L
.mig025_actor <- "025-split-legacy-appearance"
.mig025_lm_app <- "6d11d0c5-9da8-4909-a69a-31ceab12aa50"    # ACIRL field "Comments" -> Appearance
.mig025_lm_stage <- "45c91544-e2f7-4782-b896-8e01c45d3959"  # ACIRL field "Flow observation" -> Stage
.mig025_plan_default <- "dev/migrations/025-split-legacy-appearance-PLAN.csv"
.mig025_plan_sha1 <- "8c60ec1948808b049e2abc464ddebd385f5e516a"
.mig025_n <- c(split = 105L, to_stage = 50L)
# The three Appearance analyses that need a human; asserted untouched.
.mig025_excluded <- data.frame(
  uuid = c("97146a7d-04fb-494f-8a9c-091f2107cc86", "3d0ac883-521a-45f9-b1ca-1be1f6e7dff7", "11ec50bf-b7a6-46ee-859d-6cbe4e6e800d"),
  uuid_stage = c("6ddea23b-8ed8-4a5a-8fd8-0ad0c26c0185", "14c64fc4-2b43-4c02-ab4e-bbe30ade78d8", "68e98fec-69d5-4ad3-bdd5-58e34000843f"),
  value_chr = c("low Level", "Pooled", "Dry"),
  stage_value_chr = c("Slightly Cloudy", "Cloudy", "Dry"),
  stringsAsFactors = FALSE)

.mig025_default <- function(x, default) if (is.null(x)) default else x
.mig025_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig025_fail <- function(msg) cli::cli_abort(paste0("025-split-legacy-appearance: ", msg), class = "sampletidy_error")
.mig025_inlist <- function(ids) paste0("(", paste(sprintf("'%s'", ids), collapse = ", "), ")")
.mig025_same <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))

.mig025_read_plan <- function(path) {
  if (!file.exists(path)) .mig025_fail(sprintf("plan %s not found.", path))
  sha <- digest::digest(file = path, algo = "sha1")
  if (!identical(sha, .mig025_plan_sha1)) .mig025_fail(sprintf("plan %s has sha1 %s, not the pinned %s.", path, sha, .mig025_plan_sha1))
  P <- utils::read.csv(path, stringsAsFactors = FALSE, encoding = "UTF-8", na.strings = "",
                       colClasses = "character")
  want <- c("uuid", "uuid_sample", "feat", "date_sydney", "project", "action", "legacy_value_chr",
            "stage", "appearance", "uuid_stage_new")
  if (!identical(names(P), want)) .mig025_fail("plan columns are not the expected ten.")
  n <- table(factor(P$action, levels = names(.mig025_n)))
  if (nrow(P) != sum(.mig025_n) || !identical(as.integer(n), unname(.mig025_n))) .mig025_fail("plan row counts are not 105 split + 50 to_stage.")
  if (anyDuplicated(P$uuid) || anyDuplicated(P$uuid_sample)) .mig025_fail("plan repeats an analysis or a sample.")
  sp <- P$action == "split"
  if (any(is.na(P$stage)) || any(is.na(P$appearance[sp])) || any(!is.na(P$appearance[!sp])) ||
      any(is.na(P$uuid_stage_new[sp])) || any(!is.na(P$uuid_stage_new[!sp])) ||
      anyDuplicated(stats::na.omit(P$uuid_stage_new)) ||
      length(intersect(stats::na.omit(P$uuid_stage_new), P$uuid))) {
    .mig025_fail("plan rows are not internally consistent.")
  }
  if (length(intersect(P$uuid, .mig025_excluded$uuid))) .mig025_fail("plan contains an excluded analysis.")
  P
}

# The adapter's own split of the text it would read from the sheet.
.mig025_split <- function(txt) .st_acirl_split_observation(stringr::str_squish(txt))

# Every analysis row 025 writes, deletes or creates.
.mig025_touched <- function(P) unique(c(P$uuid, stats::na.omit(P$uuid_stage_new)))

.mig025_analyses <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig025_inlist(ids)))
}

.mig025_counts <- function(con) {
  tabs <- c("analysis", "sample", "lab_method", "feature_alias", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig025_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 025 must not touch.
.mig025_checksum <- function(con, P) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig025_inlist(.mig025_touched(P))))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig025_actor))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig025_lab_problem <- function(con) {
  lm <- DBI::dbGetQuery(con, "SELECT lm.uuid, lm.name, lm.organisation, lm.method, an.name AS analyte, an.type
    FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid IN (?, ?)",
    params = list(.mig025_lm_app, .mig025_lm_stage))
  a <- lm[lm$uuid == .mig025_lm_app, ]; s <- lm[lm$uuid == .mig025_lm_stage, ]
  if (nrow(a) != 1L || a$name != "Comments" || a$organisation != "ACIRL" || a$method != "field" || a$analyte != "Appearance") return("lab_method 6d11d0c5 is not ACIRL field Comments -> Appearance")
  if (nrow(s) != 1L || s$name != "Flow observation" || s$organisation != "ACIRL" || s$method != "field" || s$analyte != "Stage") return("lab_method 45c91544 is not ACIRL field Flow observation -> Stage")
  # The adapter's two labels must resolve to these two methods and nothing else
  # under ACIRL (exact name, then the folded key - .rc_resolve_one_analyte()).
  acirl <- DBI::dbGetQuery(con, "SELECT uuid, name FROM lab_method WHERE organisation = 'ACIRL'")
  k <- tolower(gsub("[^[:alnum:]]", "", acirl$name))
  if (!identical(acirl$uuid[!is.na(k) & k == "flowobservation"], .mig025_lm_stage)) return("ACIRL 'Flow observation' does not fold to 45c91544 alone")
  if (!identical(acirl$uuid[!is.na(k) & k == "comments"], .mig025_lm_app)) return("ACIRL 'Comments' does not fold to 6d11d0c5 alone")
  NULL
}

.mig025_excluded_problem <- function(con) {
  E <- .mig025_analyses(con, c(.mig025_excluded$uuid, .mig025_excluded$uuid_stage))
  for (i in seq_len(nrow(.mig025_excluded))) {
    a <- E[E$uuid == .mig025_excluded$uuid[[i]], ]; s <- E[E$uuid == .mig025_excluded$uuid_stage[[i]], ]
    if (nrow(a) != 1L || a$uuid_lab != .mig025_lm_app || !.mig025_same(a$value_chr, .mig025_excluded$value_chr[[i]]) ||
        nrow(s) != 1L || s$uuid_lab != .mig025_lm_stage || !.mig025_same(s$value_chr, .mig025_excluded$stage_value_chr[[i]])) {
      return(sprintf("excluded pair %s is not as recorded", substr(.mig025_excluded$uuid[[i]], 1, 8)))
    }
  }
  NULL
}

# Sample context for every planned row: feature and Sydney day.
.mig025_samples <- function(con, P) {
  DBI::dbGetQuery(con, sprintf('SELECT s.uuid, s.date, f.name AS feat FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN %s', .mig025_inlist(P$uuid_sample)))
}

.mig025_per_sample <- function(con, P) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid_sample,
      SUM(CASE WHEN uuid_lab = '%s' THEN 1 ELSE 0 END)::INTEGER AS n_app,
      SUM(CASE WHEN uuid_lab = '%s' THEN 1 ELSE 0 END)::INTEGER AS n_stage
    FROM analysis WHERE uuid_sample IN %s GROUP BY uuid_sample",
    .mig025_lm_app, .mig025_lm_stage, .mig025_inlist(P$uuid_sample)))
}

.mig025_blank_rest <- function(a) {
  is.na(a$value) && is.na(a$quantified) && is.na(a$rl_low) && is.na(a$rl_high) && is.na(a$purpose) && is.na(a$comments)
}

# The pre-025 state, proved row by row. NULL if it holds, else the first reason.
.mig025_initial_problem <- function(con, P) {
  p <- .mig025_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig025_excluded_problem(con); if (!is.null(p)) return(p)
  A <- .mig025_analyses(con, P$uuid)
  if (nrow(A) != nrow(P)) return(sprintf("%d of the %d planned analyses exist", nrow(A), nrow(P)))
  if (nrow(.mig025_analyses(con, stats::na.omit(P$uuid_stage_new))) != 0L) return("a planned new Stage uuid already exists")
  S <- .mig025_samples(con, P)
  if (nrow(S) != nrow(P)) return("a planned sample is missing")
  ps <- .mig025_per_sample(con, P)
  legacy <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT uuid_row FROM change_log WHERE action = 'insert' AND actor = 'pipeline' AND uuid_row IN %s",
                                         .mig025_inlist(P$uuid)))
  if (nrow(legacy)) return("a planned analysis was inserted by the pipeline, not legacy")
  for (i in seq_len(nrow(P))) {
    r <- P[i, ]; a <- A[A$uuid == r$uuid, ]; s <- S[S$uuid == r$uuid_sample, ]
    tag <- sprintf("%s %s %s", r$feat, r$date_sydney, substr(r$uuid, 1, 8))
    if (a$uuid_lab != .mig025_lm_app || a$uuid_sample != r$uuid_sample) return(paste(tag, "is not the planned Appearance row"))
    if (!.mig025_same(a$value_chr, r$legacy_value_chr)) return(paste(tag, "legacy text changed"))
    if (!.mig025_blank_rest(a)) return(paste(tag, "carries a value / quantified / rl / purpose / comments"))
    if (s$feat != r$feat || format(s$date, tz = "Australia/Sydney", "%Y-%m-%d") != r$date_sydney) return(paste(tag, "sample is not at that feature on that day"))
    sp <- .mig025_split(r$legacy_value_chr)
    if (!.mig025_same(sp$stage, r$stage) || !.mig025_same(sp$appearance, r$appearance)) {
      return(sprintf("%s: the adapter now splits '%s' as (%s, %s), not the planned (%s, %s)", tag, r$legacy_value_chr,
                     sp$stage, sp$appearance, r$stage, r$appearance))
    }
    k <- ps[ps$uuid_sample == r$uuid_sample, ]
    if (nrow(k) != 1L || k$n_app != 1L || k$n_stage != 0L) return(paste(tag, "sample does not hold exactly one Appearance and no Stage"))
  }
  NULL
}

# The post-025 state. Once 026 (marker 1026) has settled the three excluded
# pairs they are no longer "untouched"; 026 verifies them instead.
.mig025_done_problem <- function(con, P) {
  p <- .mig025_lab_problem(con); if (!is.null(p)) return(p)
  if (.mig025_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = 1026") == 0L) {
    p <- .mig025_excluded_problem(con); if (!is.null(p)) return(p)
  }
  # Once 027 (marker 1027) has deleted a redundant duplicate copy of a split
  # pair (B.E01 2023-09-13 on ES2331527), that pair is no longer 025's to
  # verify; 027 verifies its deletions. Both halves of a pair must have gone.
  if (.mig025_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = 1027") > 0L) {
    gone <- DBI::dbGetQuery(con, "SELECT uuid_row FROM change_log WHERE actor = '027-dedupe-legacy-field-readings'
      AND action = 'delete' AND tbl = 'analysis'")$uuid_row
    hit <- P$uuid %in% gone
    if (any(!is.na(P$uuid_stage_new[hit]) & !(P$uuid_stage_new[hit] %in% gone))) return("027 deleted an Appearance but not its Stage")
    if (any(P$uuid_stage_new[!hit] %in% gone)) return("027 deleted a Stage but not its Appearance")
    P <- P[!hit, , drop = FALSE]
  }
  A <- .mig025_analyses(con, .mig025_touched(P))
  if (nrow(A) != length(.mig025_touched(P))) return("a planned analysis is missing")
  ps <- .mig025_per_sample(con, P)
  for (i in seq_len(nrow(P))) {
    r <- P[i, ]; tag <- sprintf("%s %s %s", r$feat, r$date_sydney, substr(r$uuid, 1, 8))
    a <- A[A$uuid == r$uuid, ]
    if (a$uuid_sample != r$uuid_sample || !.mig025_blank_rest(a)) return(paste(tag, "moved or gained a value"))
    k <- ps[ps$uuid_sample == r$uuid_sample, ]
    if (r$action == "split") {
      st <- A[A$uuid == r$uuid_stage_new, ]
      if (a$uuid_lab != .mig025_lm_app || !.mig025_same(a$value_chr, r$appearance)) return(paste(tag, "Appearance is not the split value"))
      if (st$uuid_lab != .mig025_lm_stage || st$uuid_sample != r$uuid_sample || !.mig025_same(st$value_chr, r$stage) ||
          !.mig025_blank_rest(st)) return(paste(tag, "new Stage row is not as planned"))
      if (nrow(k) != 1L || k$n_app != 1L || k$n_stage != 1L) return(paste(tag, "sample does not hold one Appearance + one Stage"))
    } else {
      if (a$uuid_lab != .mig025_lm_stage || !.mig025_same(a$value_chr, r$stage)) return(paste(tag, "row is not the Stage value"))
      if (nrow(k) != 1L || k$n_app != 0L || k$n_stage != 1L) return(paste(tag, "sample does not hold one Stage and no Appearance"))
    }
  }
  # The stored terms are fixed points of the split, as the pipeline's are.
  for (v in unique(stats::na.omit(P$appearance))) {
    sp <- .mig025_split(v); if (!is.na(sp$stage) || !.mig025_same(sp$appearance, v)) return(sprintf("Appearance '%s' does not split to itself", v))
  }
  for (v in unique(P$stage)) {
    sp <- .mig025_split(v); if (!.mig025_same(sp$stage, v) || !is.na(sp$appearance)) return(sprintf("Stage '%s' does not split to itself", v))
  }
  NULL
}

.mig025_verify <- function(con, P) {
  p <- .mig025_done_problem(con, P)
  if (!is.null(p)) cli::cli_abort(paste0("025 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig025_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig025_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-025-split-legacy-appearance_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig025_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig025_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig025_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back$value_chr, out$value_chr)) {
    cli::cli_abort("025: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig025_check_preconditions <- function(con, P) {
  if (.mig025_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig025_requires) == 0L) {
    .mig025_fail(sprintf("marker %d (024) is required first.", .mig025_requires))
  }
  p <- .mig025_initial_problem(con, P)
  if (!is.null(p)) .mig025_fail(sprintf("the database is not in the pre-025 state (%s). Nothing written.", p))
  invisible(TRUE)
}

.mig025_write <- function(con, P, recorded_at, sums_before) {
  db_transaction(con, function(con) {
    # (i) split: Appearance value_chr in place + a new Stage row.
    S <- P[P$action == "split", ]
    for (i in seq_len(nrow(S))) {
      r <- S[i, ]
      db_update(con, "analysis", uuid = r$uuid, changes = list(value_chr = r$appearance), actor = .mig025_actor,
                reason = sprintf("025: legacy %s %s Appearance '%s' split per A76 (as the ACIRL field adapter splits it): Appearance '%s' + new Stage '%s' (analysis %s)",
                                 r$feat, r$date_sydney, r$legacy_value_chr, r$appearance, r$stage, r$uuid_stage_new))
      db_append(con, "analysis",
                data.frame(uuid = r$uuid_stage_new, uuid_sample = r$uuid_sample, uuid_lab = .mig025_lm_stage,
                           value = NA_real_, value_chr = r$stage, quantified = NA, rl_low = NA_real_, rl_high = NA_real_,
                           purpose = NA_character_, comments = NA_character_, stringsAsFactors = FALSE),
                actor = .mig025_actor,
                reason = sprintf("025: Stage '%s' split per A76 out of legacy %s %s Appearance '%s' (analysis %s, now Appearance '%s')",
                                 r$stage, r$feat, r$date_sydney, r$legacy_value_chr, r$uuid, r$appearance))
    }

    # (ii) to_stage: ONE set-based delete, then same-uuid re-insert on Stage.
    T <- P[P$action == "to_stage", ]
    old <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig025_inlist(T$uuid)))
    if (nrow(old) != nrow(T) || any(old$uuid_lab != .mig025_lm_app)) cli::cli_abort("025: the to_stage rows are not the planned Appearance rows.", class = "sampletidy_error")
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig025_inlist(T$uuid)))
    if (n != nrow(T)) cli::cli_abort("025: set-based delete removed {n} rows, not {nrow(T)}.", class = "sampletidy_error")
    at <- Sys.time()
    for (i in seq_len(nrow(T))) {
      r <- T[i, ]
      .st_write_change_log(con, at = at, actor = .mig025_actor, action = "delete", tbl = "analysis",
                           uuid_row = r$uuid, field = NA_character_, old = r$uuid, new = NA_character_,
                           reason = sprintf("025: legacy %s %s Appearance '%s' is a stage-only observation per A76; row re-inserted with the same uuid on lab_method 45c91544 (Stage) as '%s' (delete half; legacy value_chr '%s')",
                                            r$feat, r$date_sydney, r$legacy_value_chr, r$stage, r$legacy_value_chr),
                           source_hash = NA_character_)
    }
    for (i in seq_len(nrow(T))) {
      r <- T[i, ]
      row <- old[old$uuid == r$uuid, , drop = FALSE]
      row$uuid_lab <- .mig025_lm_stage
      row$value_chr <- r$stage
      db_append(con, "analysis", row, actor = .mig025_actor,
                reason = sprintf("025: same uuid, same sample; uuid_lab 6d11d0c5 (Appearance) -> 45c91544 (Stage), value_chr '%s' -> '%s' as the ACIRL field adapter splits it (insert half)",
                                 r$legacy_value_chr, r$stage))
    }

    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig025_marker_version, recorded_at))
    .mig025_verify(con, P)
    if (!identical(sums_before, .mig025_checksum(con, P))) {
      cli::cli_abort("025 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig025_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       plan = .mig025_plan_default) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  P <- .mig025_read_plan(plan)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig025_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig025_verify(check_con, P), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("025 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    .mig025_check_preconditions(pre_con, P)
    list(analysis = .mig025_analyses(pre_con, P$uuid))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: %d split (Appearance re-valued + new Stage), %d to_stage (Appearance -> Stage, same uuid); 3 excluded pairs untouched.",
       sum(P$action == "split"), sum(P$action == "to_stage"))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig025_write_csv(pre$analysis, file.path(csv_dir, "025-split-legacy-appearance-BACKUP-analysis.csv"))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig025_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig025_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig025_check_preconditions(con, P)   # re-read under the write lock
    sums_before <- .mig025_checksum(con, P)
    .mig025_write(con, P, recorded_at, sums_before)
  }, db = db)

  logf("Committed: %d Appearance re-valued, %d Stage rows added, %d rows moved to Stage; marker %d.",
       sum(P$action == "split"), sum(P$action == "split"), sum(P$action == "to_stage"), .mig025_marker_version)
  logf("025-split-legacy-appearance migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
