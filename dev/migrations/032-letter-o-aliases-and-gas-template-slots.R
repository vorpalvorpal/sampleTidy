# Operator-run migration: Robin's rulings of 2026-10-17 on the pre-corpus
# alias proposal (scratchpad/2026-10-17-precorpus/PROPOSAL.md, issue 3) and on
# the three unregistered gas points (PLAN-17 ruling 8;
# scratchpad/DECISIONS-FOR-ROBIN.md). Marker 1032. Requires 1031.
# Rehearsal and research: scratchpad/2026-10-17-mig032/.
#
# (1) LETTER-O / DOT-DRIFT ALIASES. Robin: "Is this where a 0 is written as O
#     mistakenly? I'm happy for them to be registered now." Nine
#     `transcription_error` aliases, the A78 table's rows, registered by hand
#     (Robin overrides A78's "confirm through review" for these nine):
#       K.SO9 -> K.S09   K.SO6 -> K.S06   K.SO7 -> K.S07
#       B.LO1 -> B.L01   B.LO2 -> B.L02   B.SO5 -> B.S05     (letter O for 0)
#       KS07  -> K.S07   KS05  -> K.S05   KE01  -> K.E01     (dropped dot)
#     Row shape = the existing confirmed transcription_error aliases (b.lo01,
#     b.eo1): kind transcription_error, auto_assign TRUE, confirmed_by
#     "R. Shannon"; n_seen 0 and first_seen = last_seen = now, as 028's
#     hand-registered aliases. UNDATED (date_start / date_end NULL): a dated
#     alias silently misses earlier workbooks (the b.eo1 trap, fixed in 030),
#     and a misspelling has no validity window (A78).
#     alias_key = .rc_feature_key(name), the resolver's own normaliser
#     (tolower + unicode trim, punctuation kept). Preconditions: no existing
#     alias has any of the 9 keys or names (case-insensitive), and no existing
#     alias with the same FOLDED key (.rc_method_key, punctuation stripped)
#     points at a different feature. Every target is one live feature
#     (date_end NULL). The sweep (sweep_feature_raw.csv) has no other pure
#     letter-O code without an alias (B.EO1 and K.SO10 already resolve).
#     EXCLUDED, not ruled / ambiguous: KL01 (dot drift, 1 row, not in the
#     ruling), "K.E02/K.SO6" (two points in one label), "B.SO1 S1" and
#     "B.SO3 S3" (A78 "odd forms", target unruled).
#
# (2) B.G201, K.G365, K.G366. Robin: "Are they existing features in the
#     database with known locations? If not, we don't want them." Verified
#     (scratchpad/2026-10-17-mig032/): no feature at the reporting site carries
#     those numbers. The same NUMBERS exist at the OTHER site - K.G201
#     (Katoomba) and B.G365/B.G366 (Blaxland, the 2023 re-aligned grid) - but
#     they are different probes ~30 km apart: the pending rows come from the
#     Blaxland sheet (B.G201, 2400-7399-08-01) and the Katoomba sheet
#     (K.G365/366, 2400-7454/7593); K.G201 has its own Katoomba readings on
#     the same Katoomba days, and B.G365/366 have their own Blaxland readings.
#     ACIRL prints "does not exist" against Blaxland G201 from May 2025. So
#     they are not aliased to anything. This migration:
#       - deletes their 9 analyses (CH4, all 0 = non-detect) and 9 samples;
#       - deletes the 3 pending aliases (b.g201, k.g365, k.g366);
#       - closes their 9 open unknown_feature/structural review items
#         (status resolved, resolved_by "R. Shannon", resolution citing the
#         ruling), the same four fields resolve_review() writes.
#     A future ingest of a workbook carrying these labels would mint a fresh
#     pending alias and review item; the 16 gas workbooks are archived and
#     guarded, so that needs a deliberate re-import.
#
# (3) NO CHANGE (recorded in MIGRATIONS.md and the decisions file): K.MW11B
#     Mar-2023 stays ("probably lost to the sands of time"); the 4 bore-height
#     rows at 2024-08-26 22:00 stay ("If they are in the db, assume they are
#     meant to be there").
#
# COMMITS. duckdb 1.4.1: FK checks do not see deletes made earlier in the same
# transaction, and per-row DELETEs leave stale FK index keys. So three commits,
# each one set-based DELETE plus the change_log rows db_delete() would write:
#   A. DELETE the 9 analyses                                   (commit)
#   B. DELETE the 9 samples                                    (commit)
#   C. DELETE the 3 pending aliases; INSERT the 9 aliases (db_append); close
#      the 9 review items (db_update); marker; verify            (commit)
# A re-run after a failure resumes at the first unfinished step: the phase is
# read from which planned rows still exist, and any other state refuses.
# change_log (actor "032-letter-o-aliases-and-gas-template-slots"): 9 + 9 + 3
# deletes, 9 inserts, 9 x 4 review fields = 66 rows.
#
# BACKUP OF THE ROWS (written on apply, beside this file):
# `032-...-BACKUP-{analysis,sample,feature_alias,review_queue}.csv` (the rows
# as they were) and `032-...-INSERTED-feature_alias.csv`, plus the verified
# whole-file backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/032-letter-o-aliases-and-gas-template-slots.R", envir = env)
#   env$mig032_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig032_marker_version <- 1032L
.mig032_requires <- 1031L
.mig032_name <- "032-letter-o-aliases-and-gas-template-slots"
.mig032_actor <- .mig032_name
.mig032_confirmed_by <- "R. Shannon"

.mig032_aliases <- data.frame(
  name = c("K.SO9", "K.SO6", "K.SO7", "B.LO1", "B.LO2", "B.SO5", "KS07", "KS05", "KE01"),
  target = c("K.S09", "K.S06", "K.S07", "B.L01", "B.L02", "B.S05", "K.S07", "K.S05", "K.E01"),
  form = c(rep("letter O for digit 0", 6), rep("dropped site separator", 3)),
  stringsAsFactors = FALSE)
.mig032_alias_comment <- function(i) {
  sprintf("032 (Robin, 2026-10-17: \"I'm happy for them to be registered now\"): %s -> %s, %s (A78 table); registered undated so earlier workbooks resolve too.",
          .mig032_aliases$name[[i]], .mig032_aliases$target[[i]], .mig032_aliases$form[[i]])
}

# The three gas codes and every row hanging off them (verified on live 2026-10-17).
.mig032_pending <- data.frame(
  uuid = c("b8622be1-bdb1-4e58-a226-5dca6aebd3fd", "d6c7941f-e2f1-475f-8817-c08c81662938",
           "f00d9e39-69cf-4029-9217-2f4aba6f753a"),
  name = c("B.G201", "K.G365", "K.G366"),
  stringsAsFactors = FALSE)
.mig032_samples <- c(
  "171e7b0b-fa63-4649-9b16-d5eab895c980",  # B.G201 2024-08-07 2400-7399-08-01
  "28e6821f-cf33-494d-a1bc-70aac3e9b3e2", "54c375d2-5ffb-4f5c-a42d-3c47c0c25fee",
  "db869dac-fbeb-4058-8f2b-7ed6e063b542", "6d143402-b8a7-4cd7-b336-287a35a4c4f2",  # K.G365
  "7ed254fd-8f9b-4854-a196-af8244a88044", "3bdfabc2-b6c4-4b21-b670-db8f4c28b2e3",
  "7f705d2f-9cb6-4e07-9d06-8ea861abfd32", "09674a15-1204-425c-94a3-51a0a1f8afa2")  # K.G366
.mig032_analyses <- c(
  "66a16c8e-875a-4ee6-982f-067c26d973d0",
  "5ad345e0-6011-4e2d-a499-e4ff3a03adce", "1852be81-3186-4f5e-b5ca-0047f10404f4",
  "da553c87-e013-4978-b091-1c2e82698fc2", "ebd7def3-5c91-4c84-b024-9762859baf4c",
  "cef5e3cb-dd2f-4b47-9040-3d1d8228ac22", "0ecb4ae1-7cca-4bca-a0e4-efc128cde34e",
  "ef9378b9-1c3f-4e87-960b-8ed896d7f7bc", "98748a06-464e-4476-88c9-d4b4bf279362")
.mig032_reviews <- c(
  "5af15df0-851f-4393-aa59-f7cf028fb488",
  "879c8d71-c418-457b-8103-8d2438b3d9af", "25aa49f6-815a-480c-a698-439ef2eace07",
  "8259ddf8-7cb5-4832-be9b-bca843292fb5", "9edb71d5-2967-47fc-8527-e88e7d4491e7",
  "f6e3cf00-ee35-48a7-8a76-441ba7a94274", "7e71514a-8f7a-4a02-a1fe-e063050af77e",
  "2d572890-a117-462b-8a42-5962b5715958", "b139157e-85c2-454c-8554-97755c547a08")
.mig032_resolution <- paste0(
  "not a feature: no probe with this number and a known location exists at this site ",
  "(Robin, 2026-10-17: \"Are they existing features in the database with known locations? ",
  "If not, we don't want them.\"); its pending alias, sample and reading deleted by migration 032")
.mig032_n_cl <- 9L + 9L + 3L + 9L + 4L * 9L

.mig032_default <- function(x, default) if (is.null(x)) default else x
.mig032_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig032_fail <- function(msg) cli::cli_abort(paste0(.mig032_name, ": ", msg), class = "sampletidy_error")
.mig032_inlist <- function(ids) paste0("(", paste(DBI::dbQuoteString(DBI::ANSI(), ids), collapse = ", "), ")")
.mig032_keys <- function() .rc_feature_key(.mig032_aliases$name)

.mig032_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "project", "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig032_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig032_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

# Everything 032 must not touch: invariant across phases A-C.
.mig032_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "feature_alias", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig032_inlist(.mig032_analyses)))
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN %s ORDER BY uuid", .mig032_inlist(.mig032_samples)))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s AND alias_key NOT IN %s ORDER BY uuid",
                                      .mig032_inlist(.mig032_pending$uuid), .mig032_inlist(.mig032_keys())))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig032_inlist(.mig032_reviews)))
  out$review_fixed <- q(sprintf("SELECT * EXCLUDE (status, resolution, resolved_by, resolved_at) FROM review_queue WHERE uuid IN %s ORDER BY uuid",
                                .mig032_inlist(.mig032_reviews)))
  out$review_candidates <- q("SELECT * FROM review_queue_candidate ORDER BY ALL")
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig032_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig032_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig032_n_present <- function(con, table, ids) {
  .mig032_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE uuid IN %s', table, .mig032_inlist(ids)))
}

.mig032_targets <- function(con) {
  f <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, date_end FROM feature WHERE name IN %s",
                                    .mig032_inlist(unique(.mig032_aliases$target))))
  n <- table(factor(f$name, levels = unique(.mig032_aliases$target)))
  if (any(n != 1L)) .mig032_fail(sprintf("targets not exactly one feature each: %s", paste(names(n)[n != 1L], collapse = ", ")))
  if (any(!is.na(f$date_end))) .mig032_fail(sprintf("target(s) have a date_end: %s", paste(f$name[!is.na(f$date_end)], collapse = ", ")))
  f$uuid[match(.mig032_aliases$target, f$name)]
}

# The 9 new keys must be free, and no folded twin may point elsewhere.
.mig032_alias_collisions <- function(con, targets) {
  fa <- DBI::dbGetQuery(con, "SELECT uuid, uuid_feature, name, alias_key FROM feature_alias")
  keys <- .mig032_keys()
  probs <- character(0)
  for (i in seq_along(keys)) {
    if (any(fa$alias_key == keys[[i]])) probs <- c(probs, sprintf("key %s already exists", keys[[i]]))
    if (any(tolower(fa$name) == tolower(.mig032_aliases$name[[i]]))) probs <- c(probs, sprintf("name %s already exists", .mig032_aliases$name[[i]]))
    twin <- fa[!is.na(fa$alias_key) & .rc_method_key(fa$alias_key) == .rc_method_key(keys[[i]]), , drop = FALSE]
    if (any(is.na(twin$uuid_feature) | twin$uuid_feature != targets[[i]]))
      probs <- c(probs, sprintf("folded key of %s is shared with an alias of another feature", keys[[i]]))
  }
  if (anyDuplicated(keys)) probs <- c(probs, "duplicate new keys")
  probs
}

# Which step is next: "A" (nothing done), "B" (analyses gone), "C" (samples
# gone), or the problem text when the state is none of these.
.mig032_phase <- function(con) {
  na <- .mig032_n_present(con, "analysis", .mig032_analyses)
  ns <- .mig032_n_present(con, "sample", .mig032_samples)
  nf <- .mig032_n_present(con, "feature_alias", .mig032_pending$uuid)
  nopen <- .mig032_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND uuid IN %s", .mig032_inlist(.mig032_reviews)))
  nnew <- .mig032_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE alias_key IN %s", .mig032_inlist(.mig032_keys())))
  if (nf != 3L || nopen != 9L || nnew != 0L)
    return(list(problem = sprintf("pending aliases %d/3, open review items %d/9, new keys present %d/0", nf, nopen, nnew)))
  cl <- function(tbl) .mig032_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl = ? AND action = 'delete'", .mig032_actor, tbl)
  if (na == 9L && ns == 9L && cl("analysis") == 0L) return(list(phase = "A"))
  if (na == 0L && ns == 9L && cl("analysis") == 9L && cl("sample") == 0L) return(list(phase = "B"))
  if (na == 0L && ns == 0L && cl("analysis") == 9L && cl("sample") == 9L) return(list(phase = "C"))
  list(problem = sprintf("analyses %d/9, samples %d/9 present, with %d/%d analysis/sample delete log rows", na, ns, cl("analysis"), cl("sample")))
}

# The rows hanging off the pending aliases must be exactly the planned ones.
.mig032_rows_problem <- function(con) {
  s <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE uuid_feature_alias IN %s", .mig032_inlist(.mig032_pending$uuid)))$uuid
  if (length(setdiff(s, .mig032_samples))) return(sprintf("unplanned sample(s) on the pending aliases: %s", paste(setdiff(s, .mig032_samples), collapse = ", ")))
  if (length(s) > 0L) {
    a <- DBI::dbGetQuery(con, sprintf("SELECT uuid, value, quantified FROM analysis WHERE uuid_sample IN %s", .mig032_inlist(s)))
    if (length(setdiff(a$uuid, .mig032_analyses))) return("unplanned analysis rows on the pending samples")
    if (any(a$value != 0) || any(a$quantified)) return("a pending-point reading is not a 0 non-detect")
  }
  p <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, kind, uuid_feature FROM feature_alias WHERE uuid IN %s", .mig032_inlist(.mig032_pending$uuid)))
  if (nrow(p) && (any(p$kind != "pending") || any(!is.na(p$uuid_feature)) || !all(p$name == .mig032_pending$name[match(p$uuid, .mig032_pending$uuid)])))
    return("the 3 pending aliases are not the dangling pending B.G201/K.G365/K.G366")
  r <- DBI::dbGetQuery(con, sprintf("SELECT uuid, kind, subkind, uuid_alias FROM review_queue WHERE uuid IN %s", .mig032_inlist(.mig032_reviews)))
  if (nrow(r) != 9L || any(r$kind != "unknown_feature") || any(r$subkind != "structural") || !all(r$uuid_alias %in% .mig032_pending$uuid))
    return("the 9 review items are not the unknown_feature/structural items of the 3 pending aliases")
  others <- .mig032_scalar(con, sprintf("SELECT COUNT(*) FROM review_queue WHERE status = 'open' AND (uuid_alias IN %s OR uuid_target IN %s) AND uuid NOT IN %s",
                                        .mig032_inlist(.mig032_pending$uuid), .mig032_inlist(.mig032_pending$uuid), .mig032_inlist(.mig032_reviews)))
  if (others) return(sprintf("%d other open review item(s) cite the pending aliases", others))
  # No located feature at the reporting site carries these names.
  nf <- .mig032_scalar(con, sprintf("SELECT COUNT(*) FROM feature WHERE name IN %s", .mig032_inlist(.mig032_pending$name)))
  if (nf) return("a feature named B.G201/K.G365/K.G366 now exists")
  NULL
}

.mig032_done_problem <- function(con) {
  if (.mig032_n_present(con, "analysis", .mig032_analyses)) return("planned analyses still present")
  if (.mig032_n_present(con, "sample", .mig032_samples)) return("planned samples still present")
  if (.mig032_n_present(con, "feature_alias", .mig032_pending$uuid)) return("pending aliases still present")
  if (.mig032_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE alias_key IN %s",
                                  .mig032_inlist(tolower(.mig032_pending$name)))))
    return("an alias with key b.g201/k.g365/k.g366 exists")
  r <- DBI::dbGetQuery(con, sprintf("SELECT status, resolution, resolved_by, resolved_at FROM review_queue WHERE uuid IN %s", .mig032_inlist(.mig032_reviews)))
  if (nrow(r) != 9L || any(r$status != "resolved") || any(r$resolution != .mig032_resolution) ||
      any(r$resolved_by != .mig032_confirmed_by) || anyNA(r$resolved_at)) return("the 9 review items are not resolved as planned")
  targets <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name FROM feature WHERE name IN %s", .mig032_inlist(unique(.mig032_aliases$target))))
  fa <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE alias_key IN %s", .mig032_inlist(.mig032_keys())))
  if (nrow(fa) != 9L || anyDuplicated(fa$alias_key)) return(sprintf("%d rows carry the 9 new keys, expected 9", nrow(fa)))
  fa <- fa[match(.mig032_keys(), fa$alias_key), ]
  want_feat <- targets$uuid[match(.mig032_aliases$target, targets$name)]
  if (!identical(fa$uuid_feature, want_feat) || !identical(fa$name, .mig032_aliases$name) ||
      any(fa$kind != "transcription_error") || !all(fa$auto_assign) || any(fa$confirmed_by != .mig032_confirmed_by) ||
      !all(is.na(fa$date_start)) || !all(is.na(fa$date_end)) || any(fa$n_seen != 0L))
    return("the 9 new aliases are not the planned undated, confirmed, auto_assign transcription_error rows")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, COUNT(*) n FROM change_log WHERE actor = ? GROUP BY ALL ORDER BY ALL", params = list(.mig032_actor))
  want <- data.frame(tbl = c("analysis", "feature_alias", "feature_alias", "review_queue", "sample"),
                     action = c("delete", "delete", "insert", "update", "delete"), n = c(9, 3, 9, 36, 9))
  if (nrow(cl) != nrow(want) || !all(cl$tbl == want$tbl) || !all(cl$action == want$action) || !all(cl$n == want$n))
    return(sprintf("change_log rows by table/action are %s", paste(sprintf("%s/%s=%d", cl$tbl, cl$action, cl$n), collapse = ", ")))
  # The resolver itself: every new raw resolves to its target at any date.
  reg <- .rc_load_registry(con)
  for (i in seq_len(nrow(.mig032_aliases))) for (d in c("2015-01-01", "2024-04-15", "2030-01-01")) {
    cand <- .rc_feature_candidates(.mig032_aliases$name[[i]], as.Date(d), reg)
    if (nrow(cand) != 1L || cand$uuid_feature != want_feat[[i]])
      return(sprintf("%s does not resolve to %s at %s", .mig032_aliases$name[[i]], .mig032_aliases$target[[i]], d))
  }
  NULL
}

.mig032_verify <- function(con) {
  p <- .mig032_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("032 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig032_check_preconditions <- function(con) {
  if (.mig032_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig032_requires) == 0L) {
    .mig032_fail(sprintf("marker %d (031) is required first.", .mig032_requires))
  }
  ph <- .mig032_phase(con)
  if (!is.null(ph$problem)) .mig032_fail(sprintf("the database is not in a pre-032 or resumable state (%s). Nothing written.", ph$problem))
  p <- .mig032_rows_problem(con)
  if (!is.null(p)) .mig032_fail(sprintf("%s. Nothing written.", p))
  targets <- .mig032_targets(con)
  coll <- .mig032_alias_collisions(con, targets)
  if (length(coll)) .mig032_fail(sprintf("alias collision(s): %s. Nothing written.", paste(coll, collapse = "; ")))
  invisible(list(phase = ph$phase, targets = targets))
}

mig032_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig032_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig032_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig032_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig032_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig032_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid))) {
    cli::cli_abort("032: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

# Only written on a fresh (phase A) apply: a resumed run must not overwrite
# the as-found backups with partial state.
.mig032_write_backups <- function(con, csv_dir) {
  f <- function(tbl) file.path(csv_dir, sprintf("%s-BACKUP-%s.csv", .mig032_name, tbl))
  .mig032_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig032_inlist(.mig032_analyses))), f("analysis"))
  .mig032_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN %s ORDER BY uuid", .mig032_inlist(.mig032_samples))), f("sample"))
  .mig032_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY uuid", .mig032_inlist(.mig032_pending$uuid))), f("feature_alias"))
  .mig032_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM review_queue WHERE uuid IN %s ORDER BY uuid", .mig032_inlist(.mig032_reviews))), f("review_queue"))
}

.mig032_delete_logged <- function(con, table, ids, reason) {
  n <- DBI::dbExecute(con, sprintf('DELETE FROM "%s" WHERE uuid IN %s', table, .mig032_inlist(ids)))
  if (n != length(ids)) cli::cli_abort("032: set-based delete on {table} removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
  at <- Sys.time()
  for (u in ids) {
    .st_write_change_log(con, at = at, actor = .mig032_actor, action = "delete", tbl = table,
                         uuid_row = u, field = NA_character_, old = u, new = NA_character_,
                         reason = reason, source_hash = NA_character_)
  }
}

.mig032_reason_gas <- "032 (Robin, 2026-10-17: \"Are they existing features in the database with known locations? If not, we don't want them.\"): B.G201/K.G365/K.G366 match no located feature at their site (ACIRL template slots); deleted"

.mig032_apply <- function(con, phase, targets, recorded_at, logf) {
  sums_before <- .mig032_checksum(con)
  want <- .mig032_counts(con)
  # Final counts = now minus whatever is still to delete, plus the inserts.
  if (phase == "A") want$analysis <- want$analysis - 9L
  if (phase %in% c("A", "B")) want$sample <- want$sample - 9L
  want$feature_alias <- want$feature_alias - 3L + 9L
  want$review_open <- want$review_open - 9L
  want$schema_version <- want$schema_version + 1L
  want$change_log <- want$change_log + .mig032_n_cl -
    .mig032_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig032_actor)
  if (phase == "A") {
    db_transaction(con, function(con) .mig032_delete_logged(con, "analysis", .mig032_analyses, paste(.mig032_reason_gas, "(reading)")))
    logf("A: deleted the 9 analyses (committed).")
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) .mig032_delete_logged(con, "sample", .mig032_samples, paste(.mig032_reason_gas, "(sample)")))
    logf("B: deleted the 9 samples (committed).")
    phase <- "C"
  }
  inserted <- NULL
  db_transaction(con, function(con) {
    .mig032_delete_logged(con, "feature_alias", .mig032_pending$uuid, paste(.mig032_reason_gas, "(pending alias)"))
    now <- Sys.time()
    inserted <<- tibble::tibble(
      uuid = vapply(seq_len(nrow(.mig032_aliases)), function(i) uuid::UUIDgenerate(), character(1)),
      uuid_feature = targets, name = .mig032_aliases$name, alias_key = .mig032_keys(),
      kind = "transcription_error", n_seen = 0L, auto_assign = TRUE,
      first_seen = now, last_seen = now, confirmed_by = .mig032_confirmed_by,
      comments = vapply(seq_len(nrow(.mig032_aliases)), .mig032_alias_comment, character(1)),
      date_start = as.Date(NA), date_end = as.Date(NA))
    for (i in seq_len(nrow(inserted))) {
      db_append(con, "feature_alias", inserted[i, ], actor = .mig032_actor,
                reason = sprintf("032 (Robin, 2026-10-17): register %s -> %s as an undated transcription_error alias",
                                 .mig032_aliases$name[[i]], .mig032_aliases$target[[i]]))
    }
    at <- Sys.time()
    for (u in .mig032_reviews) {
      db_update(con, "review_queue", uuid = u,
                changes = list(status = "resolved", resolution = .mig032_resolution,
                               resolved_by = .mig032_confirmed_by, resolved_at = at),
                actor = .mig032_actor, reason = sprintf("032: closed per Robin's 2026-10-17 ruling; uuid=%s", u))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig032_marker_version, recorded_at))
    .mig032_verify(con)
    got <- .mig032_counts(con)
    if (!identical(got, want)) {
      cli::cli_abort(sprintf("032 verify failed: counts are %s, expected %s.",
                             paste(names(got), unlist(got), sep = "=", collapse = " "),
                             paste(names(want), unlist(want), sep = "=", collapse = " ")), class = "sampletidy_error")
    }
    if (!identical(sums_before, .mig032_checksum(con))) {
      cli::cli_abort("032 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
  logf("C: deleted the 3 pending aliases, inserted the 9 aliases, closed the 9 review items, marker %d (committed).", .mig032_marker_version)
  invisible(inserted)
}

mig032_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig032_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig032_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("032 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch(.mig032_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan (starting at step %s): delete 9 analyses + 9 samples + 3 pending aliases (B.G201, K.G365, K.G366); close 9 review items; register 9 aliases %s.",
       pre$phase, paste(sprintf("%s->%s", .mig032_aliases$name, .mig032_aliases$target), collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  if (pre$phase == "A") {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig032_write_backups(bk_con, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    logf("Row backups written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig032_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig032_default(.now, Sys.time())

  inserted <- with_db_write(function(con) {
    p <- .mig032_check_preconditions(con)   # re-read under the write lock
    .mig032_apply(con, p$phase, p$targets, recorded_at, logf)
  }, db = db)
  .mig032_write_csv(inserted, file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig032_name)))

  logf("%s migrated successfully (marker %d).", .mig032_name, .mig032_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
