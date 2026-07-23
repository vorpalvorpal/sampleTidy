# dev/cutover/verify.R
#
# Post-cutover verification battery. Run READ-ONLY against the LOCAL live DB
# after ensure_schema() + 001 + 002 (+ 003) + registry-changes.R:
#
#   devtools::load_all("/Users/rjs/dev/sampleTidy")
#   env <- new.env()
#   sys.source("dev/cutover/verify.R", envir = env)
#   res <- env$cutover_verify(db = st_config("live_db"))
#   #  -> prints a PASS/FAIL line per check; returns invisibly a tibble;
#   #     `attr(res, "ok")` is FALSE if anything failed.
#
# EVERY CHECK MUST BE ABLE TO FAIL. Each `.v_check()` call below carries a
# `catches` string naming the concrete wrong outcome it detects; a check whose
# `catches` cannot be stated is not a check, it is decoration. The battery
# deliberately pins EXACT expected numbers rather than "> 0" wherever the number
# is knowable, so a silently doubled or silently dropped row set fails.
#
# BASELINE (measured 2026-07-23, read-only, against the authoritative file
#   /Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/
#     waste_data - Environmental monitoring/data/monitoring.duckdb
#   which is the same inode as the CloudStorage form of that path):
#     feature 894 | sample 15,113 | analysis 95,737 | lab_method 360
#     analyte 247 | asset 2,530   | feature_alias absent (pre-001)
#   Post-001 (verified on the qc-dryrun snapshot): feature_alias 1,989.

# ---------------------------------------------------------------------------
# expected end state
# ---------------------------------------------------------------------------

#' Expected row counts after a complete cutover.
#'
#' Every delta is attributable to a numbered step; nothing is a fudge factor.
.v_expected <- list(
  feature       = 894L  + 1L,     # + B.L05 (D.1)
  feature_alias = 1989L + 3L,     # + b.l05 self, + trade waste dam, + discharge point - lawson stp
  sample        = 15113L,         # unchanged - D.4b corrects a date, adds no row
  analysis      = 95737L + 2L,    # + the two EA005P lab pH values (D.4a)
  lab_method    = 360L  + 1L,     # + EN67 - Client Supplied Data (D.4a)
  analyte       = 247L  - 1L,     # - the duplicate Carbophenothion merged by migration 002
  asset         = 2530L + 16L     # + the 16 retained Chemistry2e files (D.3)
)

.v_orphan_work_orders <- c(
  "ES2413933", "ES2417442", "ES2422258", "ES2515449", "ES2515450", "ES2515987",
  "ES2516159", "ES2517594", "ES2519217", "ES2520710", "ES2606533", "ES2606534",
  "ES2606550", "ES2607370", "ES2607372", "ES2608966"
)

# ---------------------------------------------------------------------------
# tiny harness
# ---------------------------------------------------------------------------

.v_new_env <- function() {
  e <- new.env(parent = emptyenv())
  e$rows <- list()
  e
}

#' Record one check.
#'
#' @param env the accumulator from `.v_new_env()`.
#' @param id short stable id, e.g. "V03".
#' @param what one line saying what is asserted.
#' @param catches the WRONG OUTCOME this check detects if it fails.
#' @param expr expression evaluated to TRUE/FALSE (errors count as FAIL).
#' @param detail optional observed-value string for the log.
.v_check <- function(env, id, what, catches, expr, detail = NULL) {
  ok <- tryCatch(isTRUE(expr), error = function(e) structure(FALSE, err = conditionMessage(e)))
  err <- attr(ok, "err")
  ok <- isTRUE(ok)
  env$rows[[length(env$rows) + 1L]] <- tibble::tibble(
    id = id, ok = ok, what = what, catches = catches,
    detail = if (!is.null(err)) paste0("ERROR: ", err) else (detail %||% NA_character_)
  )
  cat(sprintf("[%s] %-4s %s%s\n", if (ok) "PASS" else "FAIL", id, what,
              if (!is.null(detail) || !is.null(err))
                sprintf("  -- %s", if (!is.null(err)) paste0("ERROR: ", err) else detail) else ""))
  invisible(ok)
}

`%||%` <- function(x, y) if (is.null(x)) y else x

.v_n <- function(con, sql, params = list()) {
  as.integer(DBI::dbGetQuery(con, sql, params = params)[[1]][[1]])
}

# ---------------------------------------------------------------------------
# the battery
# ---------------------------------------------------------------------------

#' Run every post-cutover check.
#'
#' @param db path to the LOCAL live DuckDB file.
#' @param expected named list overriding `.v_expected` (e.g. to allow for
#'   new data ingested between cutover and verification).
#' @param require_003 if TRUE, the migration-003 marker must be present. Leave
#'   FALSE until `003-alias-date-bounds.R` exists.
#' @return invisibly a tibble of results; `attr(., "ok")` is the overall verdict.
cutover_verify <- function(db, expected = .v_expected, require_003 = FALSE) {
  checkmate::assert_string(db)
  con <- st_connect(db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  e <- .v_new_env()

  cat(sprintf("cutover_verify(): %s\n\n", db))

  # -- V01..V07 row counts --------------------------------------------------
  # Catches, jointly: a migration that silently dropped rows (001 rebuilds
  # `sample`, `lab_method` and `analysis` from TEMP copies - a bad JOIN loses
  # rows without erroring), a registry script run twice (doubled inserts), and
  # a registry script that no-oped (missing inserts).
  for (tbl in names(expected)) {
    n <- .v_n(con, sprintf('SELECT COUNT(*) FROM "%s"', tbl))
    .v_check(
      e, sprintf("V01.%s", tbl),
      sprintf("%s row count == %d", tbl, expected[[tbl]]),
      sprintf("row loss during the 001 table rebuilds, or a doubled/absent cutover insert into %s", tbl),
      n == expected[[tbl]],
      detail = sprintf("observed %d, expected %d", n, expected[[tbl]])
    )
  }

  # -- V02 feature_alias is counted at all ----------------------------------
  # KNOWN GAP: `mig001_counts_checksum()` covers feature/sample/analysis/
  # lab_method only. `feature_alias` - the table 001 *creates*, and the sole
  # path from a sample to its feature - is in neither the count set nor the
  # checksum, so 001's own step-11 gate would pass with a truncated or
  # duplicated alias table. V01.feature_alias above and V03/V04 below are the
  # compensating controls.
  n_self <- .v_n(con, "SELECT COUNT(*) FROM feature_alias WHERE kind = 'self'")
  n_feat <- .v_n(con, "SELECT COUNT(*) FROM feature")
  .v_check(
    e, "V02",
    "exactly one `self` feature_alias per feature",
    "migration 001 dropping or duplicating self-aliases (the 001 checksum does not cover feature_alias at all), or a feature added post-001 with no self alias, which is silently unreachable by its own name forever",
    n_self == n_feat,
    detail = sprintf("self aliases %d, features %d", n_self, n_feat)
  )

  # -- V03 every sample reaches a feature -----------------------------------
  n_sample <- .v_n(con, 'SELECT COUNT(*) FROM "sample"')
  n_joined <- .v_n(con, '
    SELECT COUNT(*) FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature')
  .v_check(
    e, "V03",
    "every sample joins to a feature through its alias",
    "a sample stranded on a dangling/unresolved alias (uuid_feature NULL) or on an alias uuid that no longer exists - the exact failure mode 001's uuid_feature -> uuid_feature_alias rewrite could introduce, and one no row count would reveal",
    n_joined == n_sample,
    detail = sprintf("%d of %d samples reach a feature", n_joined, n_sample)
  )

  # -- V04 no analysis orphaned --------------------------------------------
  n_an <- .v_n(con, "SELECT COUNT(*) FROM analysis")
  n_an_joined <- .v_n(con, '
    SELECT COUNT(*) FROM analysis a
    JOIN "sample" s ON s.uuid = a.uuid_sample
    JOIN lab_method lm ON lm.uuid = a.uuid_lab')
  .v_check(
    e, "V04",
    "every analysis joins to a sample AND a lab_method",
    "a torn migration-002 FK detach/reattach leaving analysis.uuid_lab permanently NULL (002's own torn-guard only detects this from change_log, not from the data), or an analysis re-pointed at a deleted sample",
    n_an_joined == n_an,
    detail = sprintf("%d of %d analyses fully joined", n_an_joined, n_an)
  )

  # -- V05 schema_version ---------------------------------------------------
  sv <- DBI::dbGetQuery(con, "SELECT version, applied_at FROM schema_version ORDER BY version")
  want <- c(1L, 2L, 3L, 4L, 1001L)
  .v_check(
    e, "V05a",
    "schema_version contains the 4 ops migrations + the 001 marker (1001)",
    "ensure_schema() not run (no ops tables -> every mutation-layer write fails), or migration 001 not applied / applied but rolled back after its marker",
    all(want %in% sv$version),
    detail = sprintf("versions present: %s", paste(sv$version, collapse = ", "))
  )
  .v_check(
    e, "V05b",
    "schema_version has no duplicate version rows",
    "a re-applied migration double-inserting its marker, which would make `already applied?` gates read inconsistently",
    !any(duplicated(sv$version)),
    detail = sprintf("%d rows, %d distinct", nrow(sv), length(unique(sv$version)))
  )
  if (isTRUE(require_003)) {
    .v_check(
      e, "V05c",
      "schema_version contains the migration-003 marker",
      "migration 003 (alias date bounds + the 17 auto_assign flips) not applied, which makes every E.5 bound inert",
      any(sv$version %in% c(1002L, 1003L)),
      detail = sprintf("versions present: %s", paste(sv$version, collapse = ", "))
    )
  }

  # -- V06 ops tables exist -------------------------------------------------
  tabs <- DBI::dbListTables(con)
  need <- c("ingest_file", "ingest_sighting", "review_queue", "change_log",
            "schema_version", "feature_alias")
  .v_check(
    e, "V06",
    "all ops tables + feature_alias exist",
    "promoting the SharePoint file without running ensure_schema(), which leaves every mutation-layer call to fail on its change_log INSERT after the data write in the same transaction",
    all(need %in% tabs),
    detail = sprintf("missing: %s", paste(setdiff(need, tabs), collapse = ", ") )
  )

  # -- V07 migration 001's additive lab_method columns ----------------------
  lm_cols <- DBI::dbListFields(con, "lab_method")
  .v_check(
    e, "V07",
    "lab_method has `units` and `conversion_constant`",
    "migration 001's R-13.2 ALTER TABLEs not applied - `confirm_analyte_methods()` reads lab_method$units and would convert every value from NA units",
    all(c("units", "conversion_constant") %in% lm_cols),
    detail = sprintf("missing: %s", paste(setdiff(c("units", "conversion_constant"), lm_cols), collapse = ", "))
  )

  # -- V08 migration 002 landed --------------------------------------------
  n_carb <- .v_n(con, "SELECT COUNT(*) FROM analyte WHERE name = 'Carbophenothion'")
  .v_check(
    e, "V08a",
    "exactly one Carbophenothion analyte remains",
    "migration 002's R-14.1 merge not run (2 rows) or run twice past its guard (0 rows)",
    n_carb == 1L, detail = sprintf("observed %d", n_carb)
  )
  n_rep <- .v_n(con, "SELECT COUNT(*) FROM lab_method WHERE reported_as IS NOT NULL")
  .v_check(
    e, "V08b",
    "lab_method.reported_as is backfilled (> 0 rows)",
    "migration 002's R-14.2 backfill not run - `reported_as` was NULL in all 360 rows before it",
    n_rep > 0L, detail = sprintf("%d rows have reported_as", n_rep)
  )

  # -- V09 B.L05 ------------------------------------------------------------
  bl05 <- DBI::dbGetQuery(con, "SELECT uuid, name, site, lon, lat, matrix FROM feature WHERE name = 'B.L05'")
  .v_check(
    e, "V09a", "B.L05 present exactly once",
    "registry-changes.R run twice without its idempotency guard (2 rows), or not run (0 rows)",
    nrow(bl05) == 1L, detail = sprintf("%d row(s)", nrow(bl05))
  )
  .v_check(
    e, "V09b", "B.L05 site == 'B' and coordinates are WGS84 decimal degrees",
    "the coordinates reprojected (Web Mercator would give lon ~1.67e7, moving the point thousands of km), sign-flipped, or lat/lon swapped; and a site prefix mismatch, which breaks the 894/894 name-prefix-equals-site invariant Work B depends on",
    nrow(bl05) == 1L && identical(bl05$site[[1]], "B") &&
      abs(bl05$lon[[1]] - 150.431198) < 1e-9 && abs(bl05$lat[[1]] - (-33.732518)) < 1e-9,
    detail = if (nrow(bl05) == 1L)
      sprintf("site=%s lon=%.6f lat=%.6f matrix=%s", bl05$site[[1]], bl05$lon[[1]], bl05$lat[[1]], bl05$matrix[[1]]) else "absent"
  )

  # -- V10 D.2 aliases ------------------------------------------------------
  al <- DBI::dbGetQuery(con, "
    SELECT fa.alias_key, fa.kind, fa.auto_assign, fa.confirmed_by, f.name AS feature
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE fa.alias_key IN ('trade waste dam', 'discharge point - lawson stp', 'b.l05')
    ORDER BY fa.alias_key")
  want_map <- c("b.l05" = "B.L05",
                "discharge point - lawson stp" = "B.L05",
                "trade waste dam" = "B.L01")
  ok10 <- nrow(al) == 3L &&
    all(al$alias_key %in% names(want_map)) &&
    all(al$feature == unname(want_map[al$alias_key])) &&
    all(!is.na(al$confirmed_by)) && all(al$auto_assign)
  .v_check(
    e, "V10", "the 3 curated aliases resolve to the right feature, confirmed and auto_assign = TRUE",
    "an alias created but never confirmed - `.rc_feature_candidates()` filters on auto_assign BEFORE anything else, so an unconfirmed alias is completely inert and the string keeps landing in review; also catches `discharge point - lawson stp` pointed at B.L01 instead of B.L05",
    ok10,
    detail = if (nrow(al) > 0)
      paste(sprintf("%s->%s(auto=%s,by=%s)", al$alias_key, al$feature, al$auto_assign, al$confirmed_by), collapse = "; ")
    else "none found"
  )

  # -- V11 the 16 assets ----------------------------------------------------
  a16 <- DBI::dbGetQuery(con, paste0("
    SELECT p.name AS wo, a.uuid, a.filename, a.hash
    FROM asset a JOIN project p ON p.uuid = a.uuid_project
    WHERE a.name = 'ESdat Chemistry2e' AND p.name IN ('",
    paste(.v_orphan_work_orders, collapse = "','"), "')"))
  .v_check(
    e, "V11a", "all 16 orphaned Chemistry2e files are registered, one per work order",
    "a work order silently skipped (e.g. its file renamed in the input dir), or a work order registered twice",
    nrow(a16) == 16L && length(unique(a16$wo)) == 16L,
    detail = sprintf("%d asset row(s), %d distinct work orders", nrow(a16), length(unique(a16$wo)))
  )
  .v_check(
    e, "V11b", "every registered asset carries a 64-hex SHA-256 hash",
    "an asset row written with a NULL or truncated hash, which destroys the point of retaining the file (you could no longer prove which bytes were kept)",
    nrow(a16) > 0 && all(!is.na(a16$hash)) && all(nchar(a16$hash) == 64L),
    detail = sprintf("hash lengths: %s", paste(unique(nchar(a16$hash)), collapse = ", "))
  )

  # -- V12 D.4a ES2520710 pH ------------------------------------------------
  ph <- DBI::dbGetQuery(con, "
    SELECT s.uuid AS sample, a.value, lm.name AS lm_name, lm.method
    FROM analysis a
    JOIN \"sample\" s ON s.uuid = a.uuid_sample
    JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE s.uuid IN ('ES2520710001','ES2520710002')
      AND (lm.method LIKE 'EA005P%' OR lm.method LIKE 'EN67%')
    ORDER BY s.uuid, lm.method")
  want_ph <- data.frame(
    sample = c("ES2520710001","ES2520710001","ES2520710002","ES2520710002"),
    method_prefix = c("EA005P","EN67","EA005P","EN67"),
    value = c(6.40, 7.41, 7.15, 6.67), stringsAsFactors = FALSE
  )
  got_ph <- if (nrow(ph) == 0) ph else data.frame(
    sample = ph$sample,
    method_prefix = ifelse(grepl("^EA005P", ph$method), "EA005P", "EN67"),
    value = ph$value, stringsAsFactors = FALSE
  )
  ok12 <- nrow(got_ph) == 4L &&
    all(mapply(function(s, m, v) any(got_ph$sample == s & got_ph$method_prefix == m &
                                       abs(got_ph$value - v) < 1e-9),
               want_ph$sample, want_ph$method_prefix, want_ph$value))
  .v_check(
    e, "V12", "ES2520710001/002 each carry BOTH pH values, each under its own method",
    "the DB still holding only the client-supplied field pH mislabelled as EA005P (the defect), or the lab value added but the field value never re-attributed (3 rows), or the field value re-attributed onto `EA005: pH` instead of `EN67 - Client Supplied Data`",
    ok12,
    detail = if (nrow(ph)) paste(sprintf("%s %s=%s", ph$sample, substr(ph$method, 1, 6), ph$value), collapse = "; ") else "no pH rows found"
  )

  # -- V13 D.4b ES2517594 date ---------------------------------------------
  d <- DBI::dbGetQuery(con, '
    SELECT uuid, CAST(date AS DATE) AS d, datetime
    FROM "sample" WHERE uuid IN (\'ES2517594001\',\'ES2517594002\') ORDER BY uuid')
  ok13 <- nrow(d) == 2L && all(as.character(d$d) == "2025-05-28") &&
    all(format(d$datetime, "%Y-%m-%d", tz = "UTC") == "2025-05-29")
  .v_check(
    e, "V13a", "ES2517594001/002 are dated 2025-05-28 (stored) = 2025-05-29 local",
    "the impossible sampled-after-analysed date (2025-09-08, three months after the 2025-06-12..18 analysis) still in place; also catches a correction written one day out by using local midnight instead of the legacy AEST-midnight-as-naive-UTC convention every other row uses",
    ok13,
    detail = if (nrow(d)) paste(sprintf("%s date=%s datetime=%s", d$uuid, d$d, format(d$datetime, tz = "UTC")), collapse = "; ") else "not found"
  )
  same_day <- .v_n(con, '
    SELECT COUNT(*) FROM "sample"
    WHERE uuid IN (\'ES2516159001\',\'ES2516159002\',\'ES2516159003\',\'ES2517594001\',\'ES2517594002\')
      AND CAST(date AS DATE) = DATE \'2025-05-28\'')
  .v_check(
    e, "V13b", "ES2517594 now shares its sampling day with ES2516159 (5 rows on 2025-05-28)",
    "a correction applied to the wrong rows, or applied to only one of the two samples",
    same_day == 5L, detail = sprintf("%d of 5 rows on 2025-05-28", same_day)
  )

  # -- V14 change_log covers every registry change --------------------------
  # Positive control first: the whole point of the mutation layer is that no
  # registry change can happen without a log row. An empty change_log with
  # changed data means something bypassed the write door.
  n_cl <- .v_n(con, "SELECT COUNT(*) FROM change_log")
  .v_check(
    e, "V14a", "change_log is non-empty",
    "registry changes hand-INSERTed with raw SQL instead of going through db_append()/db_update() - the provenance story would be gone and CONTRACT A32 violated",
    n_cl > 0L, detail = sprintf("%d rows", n_cl)
  )

  cl_feature <- .v_n(con, "
    SELECT COUNT(*) FROM change_log cl JOIN feature f ON f.uuid = cl.uuid_row
    WHERE cl.tbl = 'feature' AND cl.action = 'insert' AND f.name = 'B.L05'")
  .v_check(
    e, "V14b", "change_log has an insert row for B.L05",
    "B.L05 inserted outside the mutation layer",
    cl_feature >= 1L, detail = sprintf("%d row(s)", cl_feature))

  cl_asset <- .v_n(con, paste0("
    SELECT COUNT(DISTINCT cl.uuid_row) FROM change_log cl
    JOIN asset a ON a.uuid = cl.uuid_row
    JOIN project p ON p.uuid = a.uuid_project
    WHERE cl.tbl = 'asset' AND cl.action = 'insert' AND p.name IN ('",
    paste(.v_orphan_work_orders, collapse = "','"), "')"))
  .v_check(
    e, "V14c", "change_log has an insert row for each of the 16 assets",
    "assets appended without provenance, or fewer than 16 appended",
    cl_asset == 16L, detail = sprintf("%d of 16", cl_asset))

  cl_sample <- .v_n(con, "
    SELECT COUNT(*) FROM change_log
    WHERE tbl = 'sample' AND action = 'update'
      AND uuid_row IN ('ES2517594001','ES2517594002') AND field IN ('date','datetime')")
  .v_check(
    e, "V14d", "change_log records the ES2517594 date correction with old and new values",
    "the date edited by raw SQL, losing the record of what the DB used to claim - the single most important thing to be able to answer later about a corrected date",
    cl_sample >= 4L, detail = sprintf("%d date/datetime update rows", cl_sample))

  cl_analysis <- .v_n(con, "
    SELECT COUNT(*) FROM change_log
    WHERE tbl = 'analysis' AND action = 'update' AND field = 'uuid_lab'
      AND reason LIKE '%D.4a%'")
  .v_check(
    e, "V14e", "change_log records the ES2520710 pH re-attribution",
    "the two field-pH rows silently re-pointed, leaving no record that they were once labelled EA005P",
    cl_analysis >= 2L, detail = sprintf("%d uuid_lab update rows", cl_analysis))

  cl_actor <- .v_n(con, "SELECT COUNT(*) FROM change_log WHERE actor IS NULL OR reason IS NULL")
  .v_check(
    e, "V14f", "every change_log row has both an actor and a reason",
    "a change logged anonymously or without justification, which makes the log unauditable",
    cl_actor == 0L, detail = sprintf("%d rows missing actor or reason", cl_actor))

  # -- V15 nothing was lost: spot-check preserved identities ----------------
  # A whole-table checksum is migration 001's job; this is the cheap
  # end-to-end control that the promoted data is the SAME data.
  spot <- .v_n(con, "
    SELECT COUNT(*) FROM feature WHERE name IN
      ('B.L01','B.S01','B.E01','B.TS39','K.E01','K.E02','L.centroid')")
  .v_check(
    e, "V15", "seven known pre-existing features survived the promotion",
    "promoting the wrong file (e.g. the dashboard's derived copy, or the stale leachatetools copy - CONTRACT A67 records that all three were once treated as interchangeable)",
    spot == 7L, detail = sprintf("%d of 7", spot))

  # -- summary ---------------------------------------------------------------
  res <- dplyr::bind_rows(e$rows)
  ok <- all(res$ok)
  cat(sprintf("\n%d checks, %d passed, %d FAILED -> %s\n",
              nrow(res), sum(res$ok), sum(!res$ok), if (ok) "OK" else "NOT OK"))
  if (!ok) print(res[!res$ok, c("id", "what", "catches", "detail")], n = Inf)
  attr(res, "ok") <- ok
  invisible(res)
}

# ---------------------------------------------------------------------------
# snapshot round-trip (Runbook step 9) - separate, because it WRITES a snapshot
# ---------------------------------------------------------------------------

#' Verify the one-way snapshot flow end to end.
#'
#' Takes a real `snapshot_db()` into `dest_dir` (the SharePoint-synced
#' `data/backups/`), then re-opens the landed file READ-ONLY and compares row
#' counts against the live DB.
#'
#' CATCHES: a snapshot that never lands (the `.tmp` -> final `file.rename()`
#' silently failing across a synced folder), a snapshot taken without a
#' CHECKPOINT (WAL contents missing, so the copy is short), a snapshot the
#' reader cannot open (torn write - the entire reason DESIGN Sec9.1 keeps the
#' live DB out of OneDrive), and `st_config("snapshot_dir")` being unset, which
#' aborts `snapshot_db()` outright.
cutover_verify_snapshot <- function(db, dest_dir = st_config("snapshot_dir")) {
  checkmate::assert_string(db)
  checkmate::assert_string(dest_dir)
  tables <- c("feature", "feature_alias", "sample", "analysis", "lab_method", "analyte", "asset", "change_log")

  live <- with_db_write(function(con) {
    vapply(tables, function(t) as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) FROM "%s"', t))[[1]]), integer(1))
  }, db = db)

  t0 <- Sys.time()
  path <- snapshot_db(db = db, dest_dir = dest_dir)
  elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
  cat(sprintf("snapshot_db() -> %s (%.1fs, %s bytes)\n", path, elapsed, format(file.size(path), big.mark = ",")))

  stale <- list.files(dest_dir, pattern = "\\.tmp$", full.names = TRUE)
  if (length(stale) > 0) {
    cli::cli_abort("Snapshot left {length(stale)} .tmp file(s) behind: {stale}", class = "sampletidy_error")
  }

  con <- st_connect(path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  snap <- vapply(tables, function(t) as.integer(DBI::dbGetQuery(con, sprintf('SELECT COUNT(*) FROM "%s"', t))[[1]]), integer(1))

  cmp <- tibble::tibble(table = tables, live = unname(live), snapshot = unname(snap),
                        ok = unname(live) == unname(snap))
  print(cmp)
  if (!all(cmp$ok)) {
    cli::cli_abort("Snapshot row counts differ from the live DB.", class = "sampletidy_error")
  }
  cat("snapshot round-trip OK\n")
  invisible(list(path = path, elapsed = elapsed, counts = cmp))
}
