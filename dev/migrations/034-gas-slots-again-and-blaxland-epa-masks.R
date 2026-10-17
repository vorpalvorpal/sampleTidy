# Operator-run migration: (1) K.G365 / K.G366 again, (2) B.L04's blank EPA
# feature_mask name, (3) three EPA analyte_mask rows for Blaxland licence
# 10039. Marker 1034. Requires 1033. Rehearsal and research:
# scratchpad/2026-10-17-mig034/.
#
# (1) K.G365, K.G366 - SECOND TIME. Robin's 032 ruling (2026-10-17) stands:
#     "Are they existing features in the database with known locations? If
#     not, we don't want them." 032 deleted the first batch. The pending-
#     documents import of 2026-10-17 08:45 (actor "pipeline"; outside the
#     migration system, logged in ingest_file and change_log) re-minted them
#     from two Katoomba gas workbooks, sheet "Gas Landfil #2", cells I11/I12:
#       2400-7539-06-02 June 2026 Gas Monitoring Katoomba WMF.xls
#         (ingest_file 5c181c34..., samples dated 2026-06-23, project 2400-7539-06-02)
#       2400-7539-09-01 September 2026 Gas Monitoring Katoomba WMF.xls
#         (ingest_file 58317417..., samples dated 2026-09-14, project 2400-7539-09)
#     Verified on live 2026-10-17 at marker 1033: exactly 2 pending aliases
#     (kind pending, uuid_feature NULL), 4 samples, 4 CH4 analyses (all value
#     0, quantified FALSE) and 4 open unknown_feature/structural review items;
#     no other review item, review_queue_candidate or sample cites them, and
#     no feature is named K.G365/K.G366. This migration, as 032:
#       - deletes the 4 analyses and the 4 samples (set-based);
#       - deletes the 2 pending aliases;
#       - closes the 4 review items (status resolved, resolved_by
#         "R. Shannon", resolution citing the ruling and 034).
#     The two projects keep their other 292 samples each and are untouched.
#     A future import of a workbook carrying these labels re-mints them again:
#     no data-only switch tells the gas adapter or resolver to skip a label
#     (see scratchpad/2026-10-17-mig034/ and MIGRATIONS.md).
#
# (2) B.L04 feature_mask (variant EPA) name '' -> NULL. The EPA report already
#     treats '' as NULL (epa-monitoring-report.R assumption O); this makes the
#     row match the K.MW02 / K.MW04 convention (cleared mask = NULL).
#
# (3) EPA analyte_mask rows for Blaxland licence 10039 (V28, M2.3; names as in
#     dev/epa_licence_requirements.csv). Shape = the existing EPA rows:
#     variant 'EPA', the licence name, the EPA unit symbol, an explicit
#     conversion_constant (1 when the stored unit is already the EPA unit).
#     The report emits value * COALESCE(am.conversion_constant,
#     a.conversion_constant) in COALESCE(am.units, a.units).
#       DO (b681edf5)          "Dissolved Oxygen"  mg/L       1    stored mg/L
#       Faecal Coliforms
#         (279a3d10)           "Faecal Coliforms"  CFU/100mL  100  stored CFU/mL
#       P-reactive (95489b2b)  "Phosphate"         mg/L       1    stored mg/L as P
#     Faecal coliforms: analyte.units is CFU/mL, and the values are ALS's
#     CFU/100mL divided by 100 - checked row by row against the ALS ESdat
#     files ES2006691 and ES2008702 (e.g. B.S01 580 CFU/100mL -> 5.8, B.S06
#     6500 -> 65, B.MW11 3300 -> 33, Borehole #2 <2 -> 0.02 non-detect), and
#     the legacy rl_low repair of 2026-07-23 (PLAN-15) found the CFU divisor is
#     100. So x100 returns ALS's own CFU/100mL numbers.
#     Phosphate: Robin's ran-with ruling "Phosphate = P-reactive"; reported
#     as P, in mg/L, no stoichiometric conversion. Only P-reactive is mapped;
#     the legacy PO4 analyte (20 rows, 2003-2016) is left unmapped.
#     analyte_mask has no site column, so these rows are in scope at
#     Katoomba too (Faecal Coliforms 9 rows, Phosphate 224 rows at K).
#
# COMMITS. duckdb 1.4.1: FK checks do not see deletes made earlier in the same
# transaction, and per-row DELETEs leave stale FK index keys. So three commits,
# each a set-based DELETE plus the change_log rows db_delete() would write:
#   A. DELETE the 4 analyses                                   (commit)
#   B. DELETE the 4 samples                                    (commit)
#   C. DELETE the 2 pending aliases; close the 4 review items (db_update);
#      B.L04 mask name -> NULL (db_update, key); INSERT the 3 analyte_mask
#      rows (db_append); marker; verify                         (commit)
# A re-run after a failure resumes at the first unfinished step: the phase is
# read from which planned rows still exist, and any other state refuses.
# change_log (actor "034-gas-slots-again-and-blaxland-epa-masks"): 4 + 4 + 2
# deletes, 4 x 4 review fields, 1 feature_mask update, 3 analyte_mask inserts
# = 30 rows. (The two mask tables have no uuid column, so their change_log
# uuid_row is NULL, as db_update/db_append write it; the reason names the row.)
#
# BACKUP OF THE ROWS (written on apply, beside this file):
# `034-...-BACKUP-{analysis,sample,feature_alias,review_queue,feature_mask}.csv`
# (the rows as they were) and `034-...-INSERTED-analyte_mask.csv`, plus the
# verified whole-file backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/034-gas-slots-again-and-blaxland-epa-masks.R", envir = env)
#   env$mig034_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig034_marker_version <- 1034L
.mig034_requires <- 1033L
.mig034_name <- "034-gas-slots-again-and-blaxland-epa-masks"
.mig034_actor <- .mig034_name
.mig034_confirmed_by <- "R. Shannon"

# Part 1: the rows the 2026-10-17 08:45 import minted (verified on live).
.mig034_pending <- data.frame(
  uuid = c("cf0e13ac-d526-4682-98c1-e246f44d6cfb", "71eb456f-572e-4aae-a55a-74d7d9d0ed24"),
  name = c("K.G365", "K.G366"),
  stringsAsFactors = FALSE)
.mig034_samples <- c(
  "cace8f6d-62b8-4307-bc72-040e95a29d8f",  # K.G365 2026-06-23 2400-7539-06-02
  "373a9296-27f4-4eec-b7b6-ac27a162819b",  # K.G366 2026-06-23 2400-7539-06-02
  "27a8015d-1157-477b-9419-7d874695f0a3",  # K.G365 2026-09-14 2400-7539-09(-01)
  "90814adf-3880-4344-ad9f-8f1e201b0b57")  # K.G366 2026-09-14 2400-7539-09(-01)
.mig034_analyses <- c(
  "795d2399-9ddc-4c33-9ece-8b79d97c05be", "022d66d4-8245-4eab-96b7-354f9392f372",
  "30444910-180e-4529-b967-5e2073585747", "3cea4559-9243-47f6-b3a2-6fcdadc8b9e9")
.mig034_reviews <- c(
  "243d3323-a45a-4c7a-8701-540f33e365e0", "eb339d5e-1f87-4bee-b510-b06fa068d1d6",  # 2400-7539-06-02
  "9195e56c-9da2-43ba-98ba-168b6663c4ef", "779014b9-8a25-4a1a-8003-cf879b457bf8")  # 2400-7539-09-01
.mig034_resolution <- paste0(
  "not a feature: no probe with this number and a known location exists at this site ",
  "(Robin, 2026-10-17: \"Are they existing features in the database with known locations? ",
  "If not, we don't want them.\"); re-minted by the 2026-10-17 pending-documents import; ",
  "its pending alias, sample and reading deleted by migration 034 (as 032)")
.mig034_reason_gas <- "034 (Robin, 2026-10-17, the 032 ruling: \"Are they existing features in the database with known locations? If not, we don't want them.\"): K.G365/K.G366 re-minted by the 2026-10-17 pending-documents import match no located feature (ACIRL template slots); deleted"

# Part 2.
.mig034_l04 <- list(uuid_feature = "68180929-55a7-4711-bcbe-d890b6d14247", name = "B.L04", variant = "EPA")

# Part 3.
.mig034_masks <- data.frame(
  uuid_analyte = c("b681edf5-f6b5-4214-a3a6-ecc9d7530418", "279a3d10-489f-4786-b1af-aca55d4e67dc",
                   "95489b2b-80be-4b29-ac34-76a878103c6a"),
  analyte = c("DO", "Faecal Coliforms", "P-reactive"),
  stored_units = c("mg/L", "CFU/mL", "mg/L"),
  variant = "EPA",
  name = c("Dissolved Oxygen", "Faecal Coliforms", "Phosphate"),
  units = c("mg/L", "CFU/100mL", "mg/L"),
  conversion_constant = c(1, 100, 1),
  stringsAsFactors = FALSE)
.mig034_mask_reason <- function(i) {
  why <- c("stored mg/L = EPA mg/L",
           "stored CFU/mL (ALS CFU/100mL / 100, verified against ES2006691 and ES2008702); x100 -> CFU/100mL",
           "Robin's ran-with ruling \"Phosphate = P-reactive\"; mg/L as P, no conversion")[[i]]
  sprintf("034: EPA analyte_mask for licence 10039 M2.3: %s (%s) -> \"%s\" %s x%s; %s",
          .mig034_masks$analyte[[i]], .mig034_masks$uuid_analyte[[i]], .mig034_masks$name[[i]],
          .mig034_masks$units[[i]], format(.mig034_masks$conversion_constant[[i]]), why)
}

.mig034_n_cl <- 4L + 4L + 2L + 4L * 4L + 1L + 3L

.mig034_default <- function(x, default) if (is.null(x)) default else x
.mig034_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig034_fail <- function(msg) cli::cli_abort(paste0(.mig034_name, ": ", msg), class = "sampletidy_error")
.mig034_inlist <- function(ids) paste0("(", paste(DBI::dbQuoteString(DBI::ANSI(), ids), collapse = ", "), ")")

.mig034_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analyte_mask", "analysis", "sample", "project",
            "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig034_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig034_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

# Everything 034 must not touch: invariant across phases A-C.
.mig034_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "feature_alias", "review_queue", "feature_mask", "analyte_mask",
               "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig034_inlist(.mig034_analyses)))
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig034_inlist(.mig034_samples)))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", .mig034_inlist(.mig034_pending$uuid)))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig034_inlist(.mig034_reviews)))
  out$review_fixed <- q(sprintf("SELECT * EXCLUDE (status, resolution, resolved_by, resolved_at) FROM review_queue WHERE uuid IN %s ORDER BY uuid",
                                .mig034_inlist(.mig034_reviews)))
  out$feature_mask_rest <- q(sprintf("SELECT * FROM feature_mask WHERE NOT (uuid_feature = '%s' AND variant = 'EPA') ORDER BY ALL", .mig034_l04$uuid_feature))
  out$feature_mask_fixed <- q(sprintf("SELECT uuid_feature, variant FROM feature_mask WHERE uuid_feature = '%s' AND variant = 'EPA'", .mig034_l04$uuid_feature))
  out$analyte_mask_rest <- q(sprintf("SELECT * FROM analyte_mask WHERE NOT (uuid_analyte IN %s AND variant = 'EPA') ORDER BY ALL",
                                     .mig034_inlist(.mig034_masks$uuid_analyte)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig034_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig034_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig034_n_present <- function(con, table, ids) {
  .mig034_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE uuid IN %s', table, .mig034_inlist(ids)))
}

.mig034_l04_name <- function(con) {
  DBI::dbGetQuery(con, "SELECT name FROM feature_mask WHERE uuid_feature = ? AND variant = ?",
                  params = list(.mig034_l04$uuid_feature, .mig034_l04$variant))$name
}

.mig034_n_new_masks <- function(con) {
  .mig034_scalar(con, sprintf("SELECT COUNT(*) FROM analyte_mask WHERE variant = 'EPA' AND uuid_analyte IN %s",
                              .mig034_inlist(.mig034_masks$uuid_analyte)))
}

# Which step is next: "A" (nothing done), "B" (analyses gone), "C" (samples
# gone), or the problem text when the state is none of these.
.mig034_phase <- function(con) {
  na <- .mig034_n_present(con, "analysis", .mig034_analyses)
  ns <- .mig034_n_present(con, "sample", .mig034_samples)
  nf <- .mig034_n_present(con, "feature_alias", .mig034_pending$uuid)
  nopen <- .mig034_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND uuid IN %s", .mig034_inlist(.mig034_reviews)))
  l04 <- .mig034_l04_name(con)
  nm <- .mig034_n_new_masks(con)
  if (nf != 2L || nopen != 4L || !identical(l04, "") || nm != 0L)
    return(list(problem = sprintf("pending aliases %d/2, open review items %d/4, B.L04 EPA mask name %s (want ''), new EPA analyte masks present %d/0",
                                  nf, nopen, if (length(l04)) encodeString(l04, quote = "'") else "<no row>", nm)))
  cl <- function(tbl) .mig034_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl = ? AND action = 'delete'", .mig034_actor, tbl)
  if (na == 4L && ns == 4L && cl("analysis") == 0L) return(list(phase = "A"))
  if (na == 0L && ns == 4L && cl("analysis") == 4L && cl("sample") == 0L) return(list(phase = "B"))
  if (na == 0L && ns == 0L && cl("analysis") == 4L && cl("sample") == 4L) return(list(phase = "C"))
  list(problem = sprintf("analyses %d/4, samples %d/4 present, with %d/%d analysis/sample delete log rows", na, ns, cl("analysis"), cl("sample")))
}

# The rows hanging off the pending aliases must be exactly the planned ones,
# and the mask targets must be the analytes 034 was written against.
.mig034_rows_problem <- function(con) {
  s <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE uuid_feature_alias IN %s", .mig034_inlist(.mig034_pending$uuid)))$uuid
  if (length(setdiff(s, .mig034_samples))) return(sprintf("unplanned sample(s) on the pending aliases: %s", paste(setdiff(s, .mig034_samples), collapse = ", ")))
  if (length(s) > 0L) {
    a <- DBI::dbGetQuery(con, sprintf("SELECT uuid, value, quantified FROM analysis WHERE uuid_sample IN %s", .mig034_inlist(s)))
    if (length(setdiff(a$uuid, .mig034_analyses))) return("unplanned analysis rows on the pending samples")
    if (any(a$value != 0) || any(a$quantified)) return("a pending-point reading is not a 0 non-detect")
  }
  p <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, kind, uuid_feature FROM feature_alias WHERE uuid IN %s", .mig034_inlist(.mig034_pending$uuid)))
  if (nrow(p) && (any(p$kind != "pending") || any(!is.na(p$uuid_feature)) || !all(p$name == .mig034_pending$name[match(p$uuid, .mig034_pending$uuid)])))
    return("the 2 pending aliases are not the dangling pending K.G365/K.G366")
  r <- DBI::dbGetQuery(con, sprintf("SELECT uuid, kind, subkind, uuid_alias FROM review_queue WHERE uuid IN %s", .mig034_inlist(.mig034_reviews)))
  if (nrow(r) != 4L || any(r$kind != "unknown_feature") || any(r$subkind != "structural") || !all(r$uuid_alias %in% .mig034_pending$uuid))
    return("the 4 review items are not the unknown_feature/structural items of the 2 pending aliases")
  others <- .mig034_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND (uuid_alias IN %s OR uuid_target IN %s) AND uuid NOT IN %s",
                                        .mig034_inlist(.mig034_pending$uuid), .mig034_inlist(.mig034_pending$uuid), .mig034_inlist(.mig034_reviews)))
  if (others) return(sprintf("%d other open review item(s) cite the pending aliases", others))
  if (.mig034_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue_candidate WHERE uuid_review IN %s", .mig034_inlist(.mig034_reviews))))
    return("a review_queue_candidate row hangs off the 4 review items")
  if (.mig034_scalar(con, sprintf("SELECT COUNT(*) FROM feature WHERE name IN %s", .mig034_inlist(.mig034_pending$name))))
    return("a feature named K.G365/K.G366 now exists")
  f <- DBI::dbGetQuery(con, "SELECT name FROM feature WHERE uuid = ?", params = list(.mig034_l04$uuid_feature))$name
  if (!identical(f, .mig034_l04$name)) return("the B.L04 feature uuid does not name B.L04")
  a <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, units FROM analyte WHERE uuid IN %s", .mig034_inlist(.mig034_masks$uuid_analyte)))
  a <- a[match(.mig034_masks$uuid_analyte, a$uuid), ]
  if (!identical(a$name, .mig034_masks$analyte) || !identical(a$units, .mig034_masks$stored_units))
    return(sprintf("the mask analytes are not DO/Faecal Coliforms/P-reactive in mg/L, CFU/mL, mg/L (found %s)",
                   paste(a$name, a$units, collapse = ", ")))
  taken <- .mig034_scalar(con, sprintf("SELECT COUNT(*) FROM analyte_mask WHERE variant = 'EPA' AND name IN %s", .mig034_inlist(.mig034_masks$name)))
  if (taken) return("an EPA analyte_mask row already carries one of the 3 new names")
  NULL
}

.mig034_done_problem <- function(con) {
  if (.mig034_n_present(con, "analysis", .mig034_analyses)) return("planned analyses still present")
  if (.mig034_n_present(con, "sample", .mig034_samples)) return("planned samples still present")
  if (.mig034_n_present(con, "feature_alias", .mig034_pending$uuid)) return("pending aliases still present")
  if (.mig034_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE alias_key IN %s",
                                  .mig034_inlist(tolower(.mig034_pending$name)))))
    return("an alias with key k.g365/k.g366 exists")
  r <- DBI::dbGetQuery(con, sprintf("SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid IN %s", .mig034_inlist(.mig034_reviews)))
  if (nrow(r) != 4L || any(r$status != "resolved") || any(r$resolution != .mig034_resolution) ||
      any(r$resolved_by != .mig034_confirmed_by) || anyNA(r$resolved_at)) return("the 4 review items are not resolved as planned")
  l04 <- .mig034_l04_name(con)
  if (length(l04) != 1L || !is.na(l04)) return("the B.L04 EPA feature_mask row is not present with a NULL name")
  m <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analyte_mask WHERE variant = 'EPA' AND uuid_analyte IN %s",
                                    .mig034_inlist(.mig034_masks$uuid_analyte)))
  if (nrow(m) != 3L) return(sprintf("%d EPA analyte_mask rows for the 3 analytes, expected 3", nrow(m)))
  m <- m[match(.mig034_masks$uuid_analyte, m$uuid_analyte), ]
  if (!identical(m$name, .mig034_masks$name) || !identical(m$units, .mig034_masks$units) ||
      !identical(as.numeric(m$conversion_constant), .mig034_masks$conversion_constant))
    return("the 3 EPA analyte_mask rows are not the planned name/units/constant")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, COUNT(*) n FROM change_log WHERE actor = ? GROUP BY ALL ORDER BY ALL", params = list(.mig034_actor))
  want <- data.frame(tbl = c("analysis", "analyte_mask", "feature_alias", "feature_mask", "review_queue", "sample"),
                     action = c("delete", "insert", "delete", "update", "update", "delete"), n = c(4, 3, 2, 1, 16, 4))
  if (nrow(cl) != nrow(want) || !all(cl$tbl == want$tbl) || !all(cl$action == want$action) || !all(cl$n == want$n))
    return(sprintf("change_log rows by table/action are %s", paste(sprintf("%s/%s=%d", cl$tbl, cl$action, cl$n), collapse = ", ")))
  NULL
}

.mig034_verify <- function(con) {
  p <- .mig034_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("034 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig034_check_preconditions <- function(con) {
  if (.mig034_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig034_requires) == 0L) {
    .mig034_fail(sprintf("marker %d (033) is required first.", .mig034_requires))
  }
  ph <- .mig034_phase(con)
  if (!is.null(ph$problem)) .mig034_fail(sprintf("the database is not in a pre-034 or resumable state (%s). Nothing written.", ph$problem))
  p <- .mig034_rows_problem(con)
  if (!is.null(p)) .mig034_fail(sprintf("%s. Nothing written.", p))
  invisible(list(phase = ph$phase))
}

mig034_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig034_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig034_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig034_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig034_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

# Round-trip check on the first column (the mask tables have no uuid).
.mig034_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  k <- names(out)[[1]]
  if (nrow(back) != nrow(df) || !identical(back[[k]], as.character(out[[k]]))) {
    cli::cli_abort("034: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Only written on a fresh (phase A) apply: a resumed run must not overwrite
# the as-found backups with partial state.
.mig034_write_backups <- function(con, csv_dir) {
  f <- function(tbl) file.path(csv_dir, sprintf("%s-BACKUP-%s.csv", .mig034_name, tbl))
  .mig034_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig034_inlist(.mig034_analyses))), f("analysis"))
  .mig034_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig034_inlist(.mig034_samples))), f("sample"))
  .mig034_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY uuid", .mig034_inlist(.mig034_pending$uuid))), f("feature_alias"))
  .mig034_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig034_inlist(.mig034_reviews))), f("review_queue"))
  .mig034_write_csv(DBI::dbGetQuery(con, "SELECT * FROM feature_mask WHERE uuid_feature = ? AND variant = ?",
                                    params = list(.mig034_l04$uuid_feature, .mig034_l04$variant)), f("feature_mask"))
}

.mig034_delete_logged <- function(con, table, ids, reason) {
  n <- DBI::dbExecute(con, sprintf('DELETE FROM "%s" WHERE uuid IN %s', table, .mig034_inlist(ids)))
  if (n != length(ids)) cli::cli_abort("034: set-based delete on {table} removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
  at <- Sys.time()
  for (u in ids) {
    .st_write_change_log(con, at = at, actor = .mig034_actor, action = "delete", tbl = table,
                         uuid_row = u, field = NA_character_, old = u, new = NA_character_,
                         reason = reason, source_hash = NA_character_)
  }
}

.mig034_apply <- function(con, phase, recorded_at, logf) {
  sums_before <- .mig034_checksum(con)
  want <- .mig034_counts(con)
  # Final counts = now minus whatever is still to delete, plus the inserts.
  if (phase == "A") want$analysis <- want$analysis - 4L
  if (phase %in% c("A", "B")) want$sample <- want$sample - 4L
  want$feature_alias <- want$feature_alias - 2L
  want$analyte_mask <- want$analyte_mask + 3L
  want$review_open <- want$review_open - 4L
  want$schema_version <- want$schema_version + 1L
  want$change_log <- want$change_log + .mig034_n_cl -
    .mig034_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig034_actor)
  if (phase == "A") {
    db_transaction(con, function(con) .mig034_delete_logged(con, "analysis", .mig034_analyses, paste(.mig034_reason_gas, "(reading)")))
    logf("A: deleted the 4 analyses (committed).")
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) .mig034_delete_logged(con, "sample", .mig034_samples, paste(.mig034_reason_gas, "(sample)")))
    logf("B: deleted the 4 samples (committed).")
    phase <- "C"
  }
  inserted <- NULL
  db_transaction(con, function(con) {
    .mig034_delete_logged(con, "feature_alias", .mig034_pending$uuid, paste(.mig034_reason_gas, "(pending alias)"))
    at <- Sys.time()
    for (u in .mig034_reviews) {
      db_update(con, "review_queue", uuid = u,
                changes = list(status = "resolved", resolution = .mig034_resolution,
                               resolved_by = .mig034_confirmed_by, resolved_at = at),
                actor = .mig034_actor, reason = sprintf("034: closed per Robin's 2026-10-17 ruling (as 032); uuid=%s", u))
    }
    db_update(con, "feature_mask", key = list(uuid_feature = .mig034_l04$uuid_feature, variant = .mig034_l04$variant),
              changes = list(name = NA_character_), actor = .mig034_actor,
              reason = sprintf("034: B.L04 (%s) EPA feature_mask name '' -> NULL (a cleared mask is NULL, as K.MW02/K.MW04)", .mig034_l04$uuid_feature))
    inserted <<- .mig034_masks[, c("uuid_analyte", "variant", "name", "units", "conversion_constant")]
    for (i in seq_len(nrow(inserted))) {
      db_append(con, "analyte_mask", inserted[i, ], actor = .mig034_actor, reason = .mig034_mask_reason(i))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig034_marker_version, recorded_at))
    .mig034_verify(con)
    got <- .mig034_counts(con)
    if (!identical(got, want)) {
      cli::cli_abort(sprintf("034 verify failed: counts are %s, expected %s.",
                             paste(names(got), unlist(got), sep = "=", collapse = " "),
                             paste(names(want), unlist(want), sep = "=", collapse = " ")), class = "sampletidy_error")
    }
    if (!identical(sums_before, .mig034_checksum(con))) {
      cli::cli_abort("034 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
  logf("C: deleted the 2 pending aliases, closed the 4 review items, B.L04 EPA mask name -> NULL, inserted 3 EPA analyte_mask rows, marker %d (committed).", .mig034_marker_version)
  invisible(inserted)
}

mig034_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig034_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig034_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("034 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch(.mig034_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan (starting at step %s): delete 4 analyses + 4 samples + 2 pending aliases (K.G365, K.G366); close 4 review items; B.L04 EPA mask '' -> NULL; add EPA analyte masks %s.",
       pre$phase, paste(sprintf("%s->\"%s\" %s x%s", .mig034_masks$analyte, .mig034_masks$name, .mig034_masks$units,
                                format(.mig034_masks$conversion_constant)), collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  if (pre$phase == "A") {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig034_write_backups(bk_con, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    logf("Row backups written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig034_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig034_default(.now, Sys.time())

  inserted <- with_db_write(function(con) {
    p <- .mig034_check_preconditions(con)   # re-read under the write lock
    .mig034_apply(con, p$phase, recorded_at, logf)
  }, db = db)
  .mig034_write_csv(inserted, file.path(csv_dir, sprintf("%s-INSERTED-analyte_mask.csv", .mig034_name)))

  logf("%s migrated successfully (marker %d).", .mig034_name, .mig034_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
