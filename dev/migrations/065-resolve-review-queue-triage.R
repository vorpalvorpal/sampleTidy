# Operator-run migration: apply the CLEAR verdicts of the 2026-10-21 review-queue
# triage. Marker 1065. Requires 1064 (post-import step; after 063).
#
# ---- WHY -----------------------------------------------------------------------
# After the corpus import (053-064), 791 review_queue items were open. Six
# investigators triaged them by kind (units, value-conflict, sample-batch,
# uf-self-precedence, wo-project, uf-other), a seventh pass re-checked every
# data-changing pattern against the frozen copy of live (taken 2026-10-21 20:59)
# and the source files, and the CLEAR verdicts that survived are applied here.
# `recommend` and `leave` items stay open. The per-item evidence is in the
# triage work dirs (scratchpad/2026-10-21-review/<slice>/, consolidate/); every
# item's resolution text is in the INPUT-review CSV.
#
# ---- WHAT (frozen in the INPUT CSVs beside this file) ----------------------------
#   INPUT-review.csv          611 items closed (status resolved, resolution, resolved_by,
#                             resolved_at), plus 2 wo-project items whose verified rows are
#                             inserted but which stay OPEN (close = FALSE: 5 ESdat Coliforms
#                             rows carry Result = 1 with Comments "~<2"/"~<10"; not inserted,
#                             they need a ruling). Of the 624 clear verdicts, 11 value-conflict
#                             G06 items (2400-7222-12-04) were demoted to recommend on
#                             verification and are not here.
#   INPUT-analysis-insert.csv 842 new analyses with fixed uuids, values exactly as the
#                             package's own reconcile/commit path produced them on the
#                             frozen copy (units 36; sample-batch releases 218, i.e. 228
#                             minus 10 Magnesium / C6-C10 rows already stored under the
#                             methods the rows name; wo-project backfill 588, i.e. 596 minus
#                             the 5 Coliforms rows and 3 SAR rows a release inserts), plus 7
#                             re-inserts (origin "reinsert") of the analyses of the 3
#                             re-pointed samples.
#   INPUT-analysis-change.csv 4 value updates (value-conflict G12/G13: field sheets), 14
#                             moves of the only copy of a FIX-A Flow observation/Comments
#                             onto the same-day B.TS39 twin, 51 deletes (21 FIX-A duplicate
#                             pH/EC/T readings, 22 gas-slot CH4 0.0, 1 exact duplicate
#                             observation, 7 to be re-inserted).
#   INPUT-sample-change.csv   30 sample deletes (7 FIX-A B.TS40 May-2023 duplicates, 22
#                             gas-template slots, 1 exact duplicate) and 3 re-points from
#                             pending aliases onto 053's curated aliases ('B.E01 Effluent' ->
#                             c5df73af, 'BORE 8' -> 350f261e).
#   INPUT-alias-delete.csv    5 pending aliases deleted (3 gas slots B.G201/K.G365/K.G366,
#                             032/034 ruling; 2 emptied by the re-points).
# Items and operations are grouped into `gid`s: a group applies whole or not at all.
#
# ---- LIVE HAS MOVED ON (the hourly import) --------------------------------------
# The plan was frozen from the 20:59 copy. Before writing, every group is checked
# against the target DB: its items still open with the same source_hash; every row it
# updates, moves, deletes or re-points still byte-for-byte what the frozen copy held
# (sha1 of the row, `.mig065_row_sha()`); every insert's sample and lab_method exist,
# its uuid is free and its (sample, lab_method) holds no analysis; a sample to delete
# or re-point holds no analysis outside the plan; an alias to delete holds no sample
# outside the plan; a re-point's target alias is unchanged and no ux_sample_identity
# collision results. A group that fails any check is SKIPPED (nothing of it written,
# its items stay open) and reported in `065-...-SKIPPED.csv` (written on apply, in
# csv_dir, possibly empty). The run refuses outright only if the inputs are malformed
# or the marker chain is missing.
#
# ---- COMMITS (duckdb 1.4: FK checks do not see deletes made earlier in the same
# transaction; a sample's uuid_feature_alias cannot change while analyses reference
# it - 029, 032) -------------------------------------------------------------------
#   A. analyses: set-based DELETE of the 51 (+ change_log rows) and the 14 moves
#      (db_update uuid_sample)                                         (commit)
#   B. samples: set-based DELETE of the 30; the 3 re-points (db_update) (commit)
#   C. aliases: set-based DELETE of the 5; re-insert the 7 and insert the 842
#      (db_append, fixed uuids); the 4 value updates (db_update); close the items
#      (db_update review_queue); marker; verify; counts; checksums      (commit)
# A re-run after a failure resumes at the first unfinished step (phase read from the
# DB against the recorded plan in the SKIPPED CSV); any other state refuses.
#
# NOT DONE: ingest_file.state is left as it is. The package has no convention that
# closing a file's review items advances it (resolve_review()/release_review() do not;
# the inbox already counts needs_review-with-asset as done).
#
# KNOCK-ON: 025's re-verify fails after 065 on one row it planned: K.S06 2024-04-22 Stage
# ba76e0f4 ("Low flow", split from the legacy "Low Flow Clear"), which 065 sets to the
# ACIRL workbook's "Pooled" (value-conflict G12). On the rehearsal copies every other
# earlier migration's re-verify gives the same verdict before and after 065: 034, which
# failed on the re-imported gas-slot aliases, passes again; 032 still fails, now on a
# later check (its letter-O keys on 11 rows) that already failed before 065.
#
# Backups: verified whole-file snapshot, plus BACKUP CSVs of every analysis, sample,
# feature_alias and review_queue row the plan touches, as found (written on a fresh
# phase-A apply only).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/065-resolve-review-queue-triage.R", envir = env)
#   env$mig065_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig065_marker_version <- 1065L
.mig065_requires <- 1064L
.mig065_name <- "065-resolve-review-queue-triage"
.mig065_actor <- .mig065_name
.mig065_resolved_by <- "065-resolve-review-queue-triage"
.mig065_date <- "2026-10-21"
.mig065_n <- list(review = 613L, review_close = 611L, insert = 849L, change = 69L, sample = 33L, alias = 5L)
.mig065_reason <- "065 (review-queue triage 2026-10-21, clear verdicts)"

.mig065_fail <- function(msg) cli::cli_abort(paste0(.mig065_name, ": ", msg), class = "sampletidy_error")
.mig065_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig065_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")
.mig065_chr <- function(x) if (is.na(x) || !nzchar(x)) NA_character_ else x
.mig065_num <- function(x) if (is.na(x) || !nzchar(x)) NA_real_ else as.numeric(x)
.mig065_lgl <- function(x) if (is.na(x) || !nzchar(x)) NA else as.logical(x)

# ---- inputs ------------------------------------------------------------------------

.mig065_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-INPUT-%s.csv", .mig065_name, suffix))
    if (!file.exists(p)) .mig065_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  x <- list(review = rd("review"), insert = rd("analysis-insert"), change = rd("analysis-change"),
            sample = rd("sample-change"), alias = rd("alias-delete"))
  n_close <- sum(x$review$close == "TRUE")
  if (nrow(x$review) != .mig065_n$review || n_close != .mig065_n$review_close || nrow(x$insert) != .mig065_n$insert ||
      nrow(x$change) != .mig065_n$change || nrow(x$sample) != .mig065_n$sample || nrow(x$alias) != .mig065_n$alias)
    .mig065_fail(sprintf("INPUT row counts are review %d (close %d) / insert %d / change %d / sample %d / alias %d, not as planned.",
                         nrow(x$review), n_close, nrow(x$insert), nrow(x$change), nrow(x$sample), nrow(x$alias)))
  if (anyDuplicated(x$review$uuid) || anyDuplicated(x$insert$uuid) || anyDuplicated(x$sample$uuid) ||
      anyDuplicated(x$alias$uuid) || anyDuplicated(paste(x$change$uuid, x$change$op)))
    .mig065_fail("an INPUT CSV repeats a uuid.")
  if (anyDuplicated(paste(x$insert$uuid_sample, x$insert$uuid_lab)))
    .mig065_fail("INPUT-analysis-insert repeats a (sample, lab_method) pair.")
  if (!all(x$change$op %in% c("update", "move", "delete")) || !all(x$sample$op %in% c("delete", "repoint")) ||
      !all(x$insert$origin %in% c("units", "release", "backfill", "reinsert")))
    .mig065_fail("an INPUT CSV has an unknown op/origin.")
  gids <- unique(c(x$review$gid, x$insert$gid, x$change$gid, x$sample$gid, x$alias$gid))
  if (anyNA(gids) || !all(gids %in% x$review$gid)) .mig065_fail("every gid must own at least one review item.")
  # a reinsert is the same uuid as a planned delete
  re <- x$insert$uuid[x$insert$origin == "reinsert"]
  if (!setequal(re, x$change$uuid[x$change$op == "delete" & x$change$note == "reinsert"]))
    .mig065_fail("re-inserts do not match the deletes marked reinsert.")
  x
}

# sha1 of each row as text (the same function produces the frozen value in the INPUT
# CSV, so a row that changed in any column since 20:59 no longer matches). NA = absent.
.mig065_row_sha <- function(con, tbl, uuids) {
  out <- stats::setNames(rep(NA_character_, length(uuids)), uuids)
  if (!length(uuids)) return(out)
  df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s', tbl, .mig065_inlist(unique(uuids))))
  for (i in seq_len(nrow(df))) {
    v <- vapply(names(df), function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[df$uuid[[i]]]] <- digest::digest(paste(names(df), v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  out
}

# ---- plan: which groups still hold on this DB ---------------------------------------

# Problems per gid on a FRESH (nothing of 065 written) database. Returns a data.frame
# (gid, problem); a gid absent from it passes.
.mig065_gid_problems <- function(con, x) {
  P <- list()
  add <- function(g, msg) if (length(g)) P[[length(P) + 1L]] <<- data.frame(gid = g, problem = msg, stringsAsFactors = FALSE)
  rv <- x$review
  rq <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, source_hash FROM review_queue WHERE uuid IN %s", .mig065_inlist(rv$uuid)))
  m <- rq[match(rv$uuid, rq$uuid), , drop = FALSE]
  bad <- is.na(m$uuid) | m$status != "open" | !mapply(identical, .mig065_na(m$source_hash), .mig065_na(rv$source_hash))
  add(rv$gid[bad], sprintf("review item %s is no longer open (or its source_hash changed)", rv$uuid[bad]))

  # analysis rows changed / moved / deleted: still as frozen
  ch <- x$change
  sha <- .mig065_row_sha(con, "analysis", ch$uuid)
  bad <- is.na(sha[ch$uuid]) | sha[ch$uuid] != ch$row_sha1
  add(ch$gid[bad], sprintf("analysis %s (%s) is not as frozen", ch$uuid[bad], ch$op[bad]))
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv)) {
    tgt <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig065_inlist(mv$new)))$uuid
    bad <- !(mv$new %in% tgt)
    add(mv$gid[bad], sprintf("move target sample %s is gone", mv$new[bad]))
    have <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s",
                                         .mig065_inlist(mv$new)))$k
    lab <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_lab FROM analysis WHERE uuid IN %s", .mig065_inlist(mv$uuid)))
    k <- paste(mv$new, lab$uuid_lab[match(mv$uuid, lab$uuid)], sep = "|")
    bad <- k %in% have
    add(mv$gid[bad], sprintf("move target %s already holds that lab_method", mv$new[bad]))
  }

  # samples deleted / re-pointed: as frozen, and holding only planned analyses
  sc <- x$sample
  sha <- .mig065_row_sha(con, "sample", sc$uuid)
  bad <- is.na(sha[sc$uuid]) | sha[sc$uuid] != sc$row_sha1
  add(sc$gid[bad], sprintf("sample %s (%s) is not as frozen", sc$uuid[bad], sc$op[bad]))
  planned_a <- ch$uuid[ch$op %in% c("delete", "move")]
  on <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig065_inlist(sc$uuid)))
  extra <- unique(on$uuid_sample[!(on$uuid %in% planned_a)])
  add(sc$gid[sc$uuid %in% extra], sprintf("sample %s holds an analysis outside the plan", sc$uuid[sc$uuid %in% extra]))
  sl <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample FROM sample_lab_id WHERE uuid_sample IN %s", .mig065_inlist(sc$uuid[sc$op == "delete"])))$uuid_sample
  add(sc$gid[sc$uuid %in% sl], sprintf("sample %s to delete has a sample_lab_id row", sc$uuid[sc$uuid %in% sl]))
  rp <- sc[sc$op == "repoint", , drop = FALSE]
  if (nrow(rp)) {
    al <- .mig065_row_sha(con, "feature_alias", rp$to_alias)
    bad <- is.na(al[rp$to_alias]) | al[rp$to_alias] != rp$to_alias_sha1
    add(rp$gid[bad], sprintf("re-point target alias %s is not as frozen", rp$to_alias[bad]))
    for (i in seq_len(nrow(rp))) {
      n <- .mig065_scalar(con, "SELECT COUNT(*) FROM sample t JOIN sample s ON s.uuid = ? WHERE t.uuid_feature_alias = ?
                                 AND t.datetime IS NOT DISTINCT FROM s.datetime AND t.uuid_project IS NOT DISTINCT FROM s.uuid_project",
                          rp$uuid[[i]], rp$to_alias[[i]])
      if (n > 0L) add(rp$gid[[i]], sprintf("re-pointing sample %s would collide on ux_sample_identity", rp$uuid[[i]]))
    }
  }

  # aliases deleted: as frozen, holding only planned samples
  al <- x$alias
  sha <- .mig065_row_sha(con, "feature_alias", al$uuid)
  bad <- is.na(sha[al$uuid]) | sha[al$uuid] != al$row_sha1
  add(al$gid[bad], sprintf("alias %s is not as frozen", al$uuid[bad]))
  ons <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature_alias FROM sample WHERE uuid_feature_alias IN %s", .mig065_inlist(al$uuid)))
  extra <- unique(ons$uuid_feature_alias[!(ons$uuid %in% sc$uuid)])
  add(al$gid[al$uuid %in% extra], sprintf("alias %s holds a sample outside the plan", al$uuid[al$uuid %in% extra]))

  # inserts
  ins <- x$insert
  new <- ins[ins$origin != "reinsert", , drop = FALSE]
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM analysis WHERE uuid IN %s", .mig065_inlist(new$uuid)))$uuid
  add(new$gid[new$uuid %in% taken], sprintf("insert uuid %s is already taken", new$uuid[new$uuid %in% taken]))
  smp <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig065_inlist(ins$uuid_sample)))$uuid
  bad <- !(ins$uuid_sample %in% c(smp))
  add(ins$gid[bad], sprintf("insert target sample %s is gone", ins$uuid_sample[bad]))
  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig065_inlist(ins$uuid_lab)))$uuid
  bad <- !(ins$uuid_lab %in% lm)
  add(ins$gid[bad], sprintf("insert lab_method %s is gone", ins$uuid_lab[bad]))
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s",
                                       .mig065_inlist(new$uuid_sample)))
  bad <- paste(new$uuid_sample, new$uuid_lab, sep = "|") %in% have$k
  add(new$gid[bad], sprintf("sample %s already holds an analysis of lab_method %s", new$uuid_sample[bad], new$uuid_lab[bad]))
  # value updates: the field still holds `old`
  up <- ch[ch$op == "update", , drop = FALSE]
  for (i in seq_len(nrow(up))) {
    cur <- DBI::dbGetQuery(con, sprintf('SELECT "%s" AS v FROM analysis WHERE uuid = ?', up$field[[i]]), params = list(up$uuid[[i]]))$v
    if (length(cur) != 1L || !identical(.mig065_na(.st_changelog_str(cur)), .mig065_na(up$old[[i]])))
      add(up$gid[[i]], sprintf("analysis %s %s is no longer %s", up$uuid[[i]], up$field[[i]], up$old[[i]]))
  }
  if (!length(P)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  P <- do.call(rbind, P)
  P[!duplicated(P), , drop = FALSE]
}
.mig065_na <- function(x) { x <- as.character(x); x[!is.na(x) & !nzchar(x)] <- NA_character_; x }

# Restrict the inputs to the gids that pass. `skipped` is data.frame(gid, problem).
.mig065_restrict <- function(x, skipped) {
  sk <- unique(skipped$gid)
  for (n in names(x)) x[[n]] <- x[[n]][!(x[[n]]$gid %in% sk), , drop = FALSE]
  x$skipped <- skipped
  x
}

.mig065_skipped_rows <- function(x_all, skipped) {
  if (!nrow(skipped)) return(data.frame(gid = character(), items = character(), problem = character(), stringsAsFactors = FALSE))
  agg <- stats::aggregate(problem ~ gid, data = skipped, FUN = function(p) paste(unique(p), collapse = "; "))
  agg$items <- vapply(agg$gid, function(g) paste(x_all$review$uuid[x_all$review$gid == g], collapse = " "), "")
  agg[, c("gid", "items", "problem")]
}

# ---- phase -----------------------------------------------------------------------

.mig065_logged <- function(con, tbl, action, uuids, field = NULL) {
  if (!length(uuids)) return(character())
  sql <- sprintf("SELECT DISTINCT uuid_row FROM change_log WHERE actor = ? AND tbl = ? AND action = ? AND uuid_row IN %s%s",
                 .mig065_inlist(uuids), if (is.null(field)) "" else sprintf(" AND field = '%s'", field))
  DBI::dbGetQuery(con, sql, params = list(.mig065_actor, tbl, action))$uuid_row
}

# "A" nothing done; "B" analyses done; "C" analyses + samples done. NULL = inconsistent.
.mig065_phase <- function(con, p) {
  n_log <- .mig065_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig065_actor)
  if (n_log == 0L) return("A")
  del_a <- p$change$uuid[p$change$op == "delete"]
  mv <- p$change$uuid[p$change$op == "move"]
  a_done <- setequal(.mig065_logged(con, "analysis", "delete", del_a), del_a) &&
    setequal(.mig065_logged(con, "analysis", "update", mv, "uuid_sample"), mv) &&
    .mig065_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid IN %s", .mig065_inlist(del_a))) == 0L
  if (!a_done) return(NULL)
  del_s <- p$sample$uuid[p$sample$op == "delete"]
  rp <- p$sample$uuid[p$sample$op == "repoint"]
  b_any <- length(.mig065_logged(con, "sample", "delete", del_s)) + length(.mig065_logged(con, "sample", "update", rp))
  if (b_any == 0L) return("B")
  b_done <- setequal(.mig065_logged(con, "sample", "delete", del_s), del_s) &&
    setequal(.mig065_logged(con, "sample", "update", rp, "uuid_feature_alias"), rp)
  if (b_done && .mig065_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl NOT IN ('analysis', 'sample')", .mig065_actor) == 0L &&
      .mig065_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl = 'analysis' AND action <> 'delete' AND field IS DISTINCT FROM 'uuid_sample'", .mig065_actor) == 0L)
    return("C")
  NULL
}

# ---- apply -----------------------------------------------------------------------

.mig065_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature_alias", "sample_lab_id", "lab_method", "project", "asset", "ingest_file",
            "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig065_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig065_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

.mig065_checksum <- function(con, p) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "feature_alias", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  a_touch <- c(p$change$uuid, p$insert$uuid)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig065_inlist(a_touch)))
  out$sample_rest <- q(sprintf("SELECT * FROM sample WHERE uuid NOT IN %s ORDER BY uuid", .mig065_inlist(p$sample$uuid)))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", .mig065_inlist(p$alias$uuid)))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid",
                               .mig065_inlist(p$review$uuid[p$review$close == "TRUE"])))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig065_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig065_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig065_delete_logged <- function(con, table, ids, reasons) {
  if (!length(ids)) return(invisible(0L))
  n <- DBI::dbExecute(con, sprintf('DELETE FROM "%s" WHERE uuid IN %s', table, .mig065_inlist(ids)))
  if (n != length(ids)) .mig065_fail(sprintf("set-based delete on %s removed %d rows, not %d.", table, n, length(ids)))
  at <- Sys.time()
  for (i in seq_along(ids)) {
    .st_write_change_log(con, at = at, actor = .mig065_actor, action = "delete", tbl = table,
                         uuid_row = ids[[i]], field = NA_character_, old = ids[[i]], new = NA_character_,
                         reason = reasons[[i]], source_hash = NA_character_)
  }
  invisible(n)
}

.mig065_why <- function(p, gid, what) {
  sl <- unique(p$review$slice[p$review$gid == gid])
  sprintf("%s [%s; group %s]: %s", .mig065_reason, paste(sl, collapse = "+"), gid, what)
}

.mig065_expected_log <- function(p) {
  ch <- p$change
  n_close <- sum(p$review$close == "TRUE")
  sum(ch$op == "delete") + sum(ch$op == "move") + sum(ch$op == "update") +
    nrow(p$sample) + nrow(p$alias) + nrow(p$insert) + 4L * n_close
}

.mig065_apply <- function(con, p, phase, recorded_at, logf) {
  sums_before <- .mig065_checksum(con, p)
  want <- .mig065_counts(con)
  ch <- p$change
  del_a <- ch[ch$op == "delete", , drop = FALSE]
  mv <- ch[ch$op == "move", , drop = FALSE]
  up <- ch[ch$op == "update", , drop = FALSE]
  del_s <- p$sample[p$sample$op == "delete", , drop = FALSE]
  rp <- p$sample[p$sample$op == "repoint", , drop = FALSE]
  if (phase == "A") want$analysis <- want$analysis - nrow(del_a)
  if (phase %in% c("A", "B")) want$sample <- want$sample - nrow(del_s)
  want$analysis <- want$analysis + nrow(p$insert)
  want$feature_alias <- want$feature_alias - nrow(p$alias)
  want$review_open <- want$review_open - sum(p$review$close == "TRUE")
  want$schema_version <- want$schema_version + 1L
  want$change_log <- want$change_log + .mig065_expected_log(p) -
    .mig065_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig065_actor)

  if (phase == "A") {
    db_transaction(con, function(con) {
      .mig065_delete_logged(con, "analysis", del_a$uuid,
                            vapply(seq_len(nrow(del_a)), function(i) .mig065_why(p, del_a$gid[[i]], del_a$reason[[i]]), ""))
      for (i in seq_len(nrow(mv)))
        db_update(con, "analysis", uuid = mv$uuid[[i]], changes = list(uuid_sample = mv$new[[i]]),
                  actor = .mig065_actor, reason = .mig065_why(p, mv$gid[[i]], mv$reason[[i]]))
      NULL
    })
    logf("A: deleted %d analyses, moved %d (committed).", nrow(del_a), nrow(mv))
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) {
      .mig065_delete_logged(con, "sample", del_s$uuid,
                            vapply(seq_len(nrow(del_s)), function(i) .mig065_why(p, del_s$gid[[i]], del_s$reason[[i]]), ""))
      for (i in seq_len(nrow(rp)))
        db_update(con, "sample", uuid = rp$uuid[[i]], changes = list(uuid_feature_alias = rp$to_alias[[i]]),
                  actor = .mig065_actor, reason = .mig065_why(p, rp$gid[[i]], rp$reason[[i]]))
      NULL
    })
    logf("B: deleted %d samples, re-pointed %d (committed).", nrow(del_s), nrow(rp))
    phase <- "C"
  }
  db_transaction(con, function(con) {
    .mig065_delete_logged(con, "feature_alias", p$alias$uuid,
                          vapply(seq_len(nrow(p$alias)), function(i) .mig065_why(p, p$alias$gid[[i]], p$alias$reason[[i]]), ""))
    ins <- p$insert
    for (i in seq_len(nrow(ins))) {
      row <- tibble::tibble(uuid = ins$uuid[[i]], uuid_sample = ins$uuid_sample[[i]], uuid_lab = ins$uuid_lab[[i]],
                            value = .mig065_num(ins$value[[i]]), value_chr = .mig065_chr(ins$value_chr[[i]]),
                            quantified = .mig065_lgl(ins$quantified[[i]]), rl_low = .mig065_num(ins$rl_low[[i]]),
                            rl_high = .mig065_num(ins$rl_high[[i]]), comments = .mig065_chr(ins$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig065_actor,
                reason = .mig065_why(p, ins$gid[[i]], ins$reason[[i]]), source_hash = .mig065_chr(ins$source_hash[[i]]))
    }
    for (i in seq_len(nrow(up))) {
      v <- if (up$field[[i]] == "value") as.numeric(up$new[[i]]) else up$new[[i]]
      db_update(con, "analysis", uuid = up$uuid[[i]], changes = stats::setNames(list(v), up$field[[i]]),
                actor = .mig065_actor, reason = .mig065_why(p, up$gid[[i]], up$reason[[i]]),
                source_hash = .mig065_chr(up$source_hash[[i]]))
    }
    at <- Sys.time()
    cl <- p$review[p$review$close == "TRUE", , drop = FALSE]
    for (i in seq_len(nrow(cl)))
      db_update(con, "review_queue", uuid = cl$uuid[[i]],
                changes = list(status = "resolved", resolution = cl$resolution[[i]],
                               resolved_by = .mig065_resolved_by, resolved_at = at),
                actor = .mig065_actor, reason = .mig065_why(p, cl$gid[[i]], sprintf("close review item %s", cl$uuid[[i]])))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig065_marker_version, recorded_at))
    .mig065_verify(con, p)
    got <- .mig065_counts(con)
    if (!identical(got, want))
      .mig065_fail(sprintf("counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig065_checksum(con, p))) .mig065_fail("something outside the planned rows moved.")
    NULL
  })
  logf("C: deleted %d aliases, inserted %d analyses (%d re-inserts), %d value updates, closed %d items, marker %d (committed).",
       nrow(p$alias), nrow(p$insert), sum(p$insert$origin == "reinsert"), nrow(up), sum(p$review$close == "TRUE"),
       .mig065_marker_version)
  invisible(TRUE)
}

# ---- verify ----------------------------------------------------------------------

.mig065_done_problem <- function(con, p) {
  if (.mig065_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig065_marker_version) != 1L)
    return("marker 1065 missing")
  ins <- p$insert
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig065_inlist(c(ins$uuid, p$change$uuid))))
  a <- A[match(ins$uuid, A$uuid), , drop = FALSE]
  if (anyNA(a$uuid)) return(sprintf("%d planned inserts are missing", sum(is.na(a$uuid))))
  eqn <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & abs(x - y) <= 1e-9 * pmax(1, abs(y)))
  ok <- a$uuid_sample == ins$uuid_sample & a$uuid_lab == ins$uuid_lab &
    eqn(a$value, as.numeric(.mig065_na(ins$value))) & eqn(a$rl_low, as.numeric(.mig065_na(ins$rl_low))) &
    eqn(a$rl_high, as.numeric(.mig065_na(ins$rl_high))) &
    mapply(identical, .mig065_na(a$value_chr), .mig065_na(ins$value_chr)) &
    mapply(identical, .mig065_na(as.character(a$quantified)), .mig065_na(toupper(ins$quantified))) &
    mapply(identical, .mig065_na(a$comments), .mig065_na(ins$comments))
  if (!all(ok)) return(sprintf("insert %s is not as planned", ins$uuid[!ok][[1]]))
  ch <- p$change
  gone <- ch$uuid[ch$op == "delete" & ch$note != "reinsert"]
  if (any(gone %in% A$uuid)) return("a deleted analysis is still present")
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv) && !all(A$uuid_sample[match(mv$uuid, A$uuid)] == mv$new)) return("a moved analysis is not on its B.TS39 twin")
  up <- ch[ch$op == "update", , drop = FALSE]
  for (i in seq_len(nrow(up))) {
    cur <- A[A$uuid == up$uuid[[i]], up$field[[i]]]
    if (!identical(.mig065_na(.st_changelog_str(cur)), .mig065_na(up$new[[i]]))) return(sprintf("analysis %s %s is not %s", up$uuid[[i]], up$field[[i]], up$new[[i]]))
  }
  sc <- p$sample
  S <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature_alias FROM sample WHERE uuid IN %s", .mig065_inlist(sc$uuid)))
  if (any(sc$uuid[sc$op == "delete"] %in% S$uuid)) return("a deleted sample is still present")
  rp <- sc[sc$op == "repoint", , drop = FALSE]
  if (nrow(rp) && !all(S$uuid_feature_alias[match(rp$uuid, S$uuid)] == rp$to_alias)) return("a re-pointed sample is not on its 053 alias")
  if (.mig065_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE uuid IN %s", .mig065_inlist(p$alias$uuid))) != 0L)
    return("a deleted alias is still present")
  cl <- p$review[p$review$close == "TRUE", , drop = FALSE]
  R <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolution, resolved_by FROM review_queue WHERE uuid IN %s", .mig065_inlist(cl$uuid)))
  r <- R[match(cl$uuid, R$uuid), , drop = FALSE]
  if (anyNA(r$uuid) || any(r$status != "resolved") || any(r$resolution != cl$resolution) || any(r$resolved_by != .mig065_resolved_by))
    return("a planned review item is not resolved with its planned resolution")
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL", params = list(.mig065_actor))
  n <- function(t, a) { v <- L$n[L$tbl == t & L$action == a]; if (length(v)) as.integer(v) else 0L }
  exp <- c(analysis_delete = sum(ch$op == "delete"), analysis_insert = nrow(ins),
           analysis_update = sum(ch$op %in% c("move", "update")), sample_delete = sum(sc$op == "delete"),
           sample_update = sum(sc$op == "repoint"), feature_alias_delete = nrow(p$alias), review_queue_update = 4L * nrow(cl))
  got <- c(analysis_delete = n("analysis", "delete"), analysis_insert = n("analysis", "insert"),
           analysis_update = n("analysis", "update"), sample_delete = n("sample", "delete"),
           sample_update = n("sample", "update"), feature_alias_delete = n("feature_alias", "delete"),
           review_queue_update = n("review_queue", "update"))
  if (!identical(got, exp) || sum(L$n) != sum(exp))
    return(sprintf("065 change_log rows are %s, expected %s", paste(names(got), got, sep = "=", collapse = " "),
                   paste(names(exp), exp, sep = "=", collapse = " ")))
  NULL
}

.mig065_verify <- function(con, p) {
  pr <- .mig065_done_problem(con, p)
  if (!is.null(pr)) cli::cli_abort(paste0("065 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backups, files ----------------------------------------------------------------

mig065_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig065_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig065_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig065_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig065_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("065: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig065_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig065_name, what))

.mig065_write_backups <- function(con, p, csv_dir) {
  g <- function(tbl, ids, key = "uuid") DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE %s IN %s ORDER BY %s', tbl, key, .mig065_inlist(ids), key))
  .mig065_write_csv(g("analysis", p$change$uuid), .mig065_csv(csv_dir, "BACKUP-analysis"), "uuid")
  .mig065_write_csv(g("sample", p$sample$uuid), .mig065_csv(csv_dir, "BACKUP-sample"), "uuid")
  .mig065_write_csv(g("feature_alias", c(p$alias$uuid, p$sample$to_alias[p$sample$op == "repoint"])),
                    .mig065_csv(csv_dir, "BACKUP-feature_alias"), "uuid")
  .mig065_write_csv(g("review_queue", p$review$uuid), .mig065_csv(csv_dir, "BACKUP-review_queue"), "uuid")
}

# The recorded plan: SKIPPED.csv (gids not applied, with why). Read back on a resume and
# on the already_migrated re-verify, so both see the plan the first apply chose.
.mig065_read_skipped <- function(csv_dir) {
  f <- .mig065_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  s <- utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
  data.frame(gid = s$gid, problem = s$problem, stringsAsFactors = FALSE)
}

# ---- run -------------------------------------------------------------------------

mig065_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x_all <- .mig065_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig065_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig065_read_skipped(csv_dir)
    if (is.null(sk)) .mig065_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig065_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig065_verify(check_con, .mig065_restrict(x_all, sk)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("065 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  # Plan on the DB as it is. A fresh DB: check every group. A resumed one (065 rows in
  # change_log, no marker): the plan recorded by the first attempt.
  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    for (m in .mig065_requires)
      if (.mig065_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
        .mig065_fail(sprintf("marker %d is required first.", m))
    started <- .mig065_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig065_actor) > 0L
    if (!started) {
      sk <- .mig065_gid_problems(pre_con, x_all)
    } else {
      sk <- .mig065_read_skipped(csv_dir)
      if (is.null(sk)) .mig065_fail("a previous attempt wrote change_log rows but its SKIPPED CSV is missing; refusing.")
    }
    p <- .mig065_restrict(x_all, sk)
    ph <- .mig065_phase(pre_con, p)
    if (is.null(ph)) .mig065_fail("the database is part-way through 065 in a state no phase explains; refusing.")
    list(p = p, phase = ph, started = started)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- pre$p
  n_sk <- length(unique(p$skipped$gid))
  logf("Plan (step %s): %d groups, %d skipped (%d items left open by a skip). Close %d items; insert %d analyses (%d re-inserts); %d value updates; %d moves; delete %d analyses, %d samples, %d aliases; re-point %d samples.",
       pre$phase, length(unique(x_all$review$gid)), n_sk, sum(x_all$review$gid %in% p$skipped$gid),
       sum(p$review$close == "TRUE"), nrow(p$insert), sum(p$insert$origin == "reinsert"),
       sum(p$change$op == "update"), sum(p$change$op == "move"), sum(p$change$op == "delete"),
       sum(p$sample$op == "delete"), nrow(p$alias), sum(p$sample$op == "repoint"))
  if (n_sk) for (i in seq_len(nrow(p$skipped))) logf("SKIP %s: %s", p$skipped$gid[[i]], p$skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: no backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p)))
  }

  if (!pre$started) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig065_write_backups(bk_con, p, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    .mig065_write_csv(.mig065_skipped_rows(x_all, p$skipped), .mig065_csv(csv_dir, "SKIPPED"), "gid")
    logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups and SKIPPED plan from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig065_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    # re-read under the write lock: the phase, and on a fresh run the group checks
    if (!pre$started) {
      sk2 <- .mig065_gid_problems(con, x_all)
      if (!setequal(unique(sk2$gid), unique(p$skipped$gid)))
        .mig065_fail("the database changed between the plan and the write lock; re-run.")
    }
    ph <- .mig065_phase(con, p)
    if (!identical(ph, pre$phase)) .mig065_fail("the phase changed between the plan and the write lock; re-run.")
    .mig065_apply(con, p, ph, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig065_name, .mig065_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, skipped = p$skipped))
}
