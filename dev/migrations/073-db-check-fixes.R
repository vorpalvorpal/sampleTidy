# Operator-run migration: fix the live-DB problems the PLAN-22 standing checks found
# (PLAN-22 Part C), where the right value is clear and the schema allows it.
# Marker 1073. Requires 1072.
#
# Authority: Robin, 2026-10-22 (accepted the PLAN-22 C recommendations for the
# offenders of db_checks(tier = "all") on live at marker 1072).
#
# ---- WHAT (frozen in 073-db-check-fixes-INPUT.csv; `item` = recommendation) ----------
#   C1 dup_analysis_sample_method (4 groups): an ACIRL field reading stored twice on
#      one sample under one lab_method with identical values (3x CH4 Reading 0 on
#      B.G368, 2024-05-09 / 06-13 / 07-11; 1x Electrical Conductivity 186 on K.S06,
#      2024-04-21). Both copies were inserted by one commit_event of one file, 15-18 ms
#      apart. The EARLIEST-CREATED copy (change_log insert `at`) is kept, the other
#      deleted. Guard: the pair is still exactly the two analyses on that (sample,
#      lab_method), both as frozen, values identical, the kept one inserted first.
#   C6 alias_window_ambiguous (1): the two b.s22 historical_code arms -> B.TS18
#      (0f90862a, date_end 2021-11-12) and -> B.S06 (6ca0abf7, date_end 2021-04-14)
#      both start open, so they overlap before 2021-04-14. The B.TS18 arm exists for
#      one visit: its only sighting is ES2141063 on 2021-11-12 (n_seen 1; 003 set the
#      end to that day by the target's-last-sample rule; 065 review triage: "on
#      2021-11-12 label B.S22 = B.TS18"; DECISIONS 2026-10-21 item 21: "12 Nov 2021
#      'B.S22' -> B.TS18"). B.TS18 has no other sample labelled B.S22. So 0f90862a
#      gets date_start 2021-11-12 and the windows no longer overlap. The B.S06 arm is
#      NOT given a start: the evidence (053 F 2020-03-06, decision 6 ES2111128
#      2021-03-26, "Mar-Apr 2021 overflow series") does not fix one (see MIGRATIONS.md).
#   C7 sample_in_feature_window (3): B.TS28 has samples on 2022-03-07, 03-09 and 03-11
#      (ES2208272, ES2208698, ES2208640; 26 analyses each) before its date_start
#      2022-03-14. date_start -> 2022-03-07, the first sample. No feature on the site
#      ends or starts adjacent to it (B.TS29 starts 2022-03-07 independently; no
#      predecessor feature ends in Feb-Mar 2022); its dated descriptive arms (from
#      2022-03-14, 053's observed range) are left as they are.
#   C8 sample_date_datetime_agree (1): K.MW11B sample b7286aa9 (ES2307793-013) has
#      datetime 2023-03-07 22:20 UTC = 8 Mar 2023 09:20 Sydney but date / date_start
#      2023-03-08 13:00 UTC = 9 Mar. It is 8 Mar: the time sits in the sequence of the
#      12 other Katoomba samples of ES2307793 (all dated 8 Mar, 21:30-01:05 UTC); the
#      ACIRL field sample merged into it by 066 (decision 12, 'BORE11B') was dated
#      2023-03-08; and its own comment says ALS recorded 09/03 instead of 08/03. date
#      and date_start -> 2023-03-07 13:00:00 (the stored Sydney-midnight convention).
#
# ---- NOT DONE HERE (reported, see MIGRATIONS.md) ----------------------------------
#   C2 dup_asset_hash (4 pairs): 061 (Robin, 2026-10-20) ruled each pair "one report
#      filed under more than one project, not a duplicate", and 057's own rule refuses
#      to merge across projects (it would drop a project link). Not merged.
#   C3 dup_sample_identity_null_datetime (53 pairs): the split is A91 ruling D3
#      (Robin, 2026-10-17) working as designed (an ACIRL field row on an ALS-only day
#      creates a separate ACIRL sample). Merging needs D3 revisited first.
#   C5 feature_coords (3: B.S02, B.MW05, B.MW03; lon/lat NaN, geom_wkt 'POINT
#      EMPTY'): NOT done. feature.lon and feature.lat are NOT NULL in the schema (the
#      first rehearsal's UPDATE failed on the constraint), so NaN is the only "no
#      coordinates" value the table can hold; and feature_coords flags NULL too.
#   C4 hash_format (13 SHA-256 ingest_file rows): none of the 13 files is reachable on
#      local disk (input/batch-2026-07-23/ is gone from OneDrive; no file of those
#      sizes in the OneDrive tree, ~/dev or the scratchpads). Skipped.
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before, per group (a failing group is SKIPPED whole, listed in
#   073-...-SKIPPED.csv): every row the group touches (and the C1 kept copy and the
#   C6 B.S06 arm, which are not written) is byte for byte as frozen (sha1); each
#   updated field still holds its frozen old value; each deleted analysis is
#   referenced by no VARCHAR column of any base table but change_log; C1 as above.
#   Inside the one write transaction: baseline <- db_checks(con, tier = "migration")
#   and an all-tier baseline before the change; after it every planned row is as
#   planned and nothing else moved (checksums; counts: analysis -n, change_log +n,
#   schema_version +1); mig_db_checks_gate(con, baseline); and on the all tier no
#   check gains an offender key or a new error, and the targeted checks lose exactly
#   the planned keys (dup_analysis_sample_method, alias_window_ambiguous,
#   sample_in_feature_window, sample_date_datetime_agree).
#
# One commit: none of these writes changes an indexed sample column or deletes a row
# another table references through a foreign key (the duckdb 1.4 limits that made
# 066-069 commit in phases).
#
# Backups: verified whole-file snapshot; BACKUP CSVs of every analysis, feature,
# feature_alias and sample row frozen in the INPUT. Idempotent: marker present ->
# re-verify against the SKIPPED CSV, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/073-db-check-fixes.R", envir = env)
#   env$mig073_run(db = ..., snapshot_dir = ..., dry_run = TRUE)

.mig073_marker_version <- 1073L
.mig073_requires <- 1072L
.mig073_name <- "073-db-check-fixes"
.mig073_actor <- .mig073_name
.mig073_items <- c("C1", "C6", "C7", "C8")
.mig073_reason <- "073 (Robin 2026-10-22, PLAN-22 C: fix what the standing DB checks found)"
# Planned group counts per item; and per (tbl|op) row counts.
.mig073_n_groups <- c(C1 = 4L, C6 = 1L, C7 = 1L, C8 = 1L)
# The check each item clears, and how a group's offender key is built from its rows.
.mig073_target <- c(C1 = "dup_analysis_sample_method", C6 = "alias_window_ambiguous",
                    C7 = "sample_in_feature_window", C8 = "sample_date_datetime_agree")
# Columns written, by table, and how a frozen text value becomes an R value.
.mig073_types <- list(
  feature = c(date_start = "date"),
  feature_alias = c(date_start = "date"),
  sample = c(date = "ts", date_start = "ts")
)

.mig073_fail <- function(msg) cli::cli_abort(paste0(.mig073_name, ": ", msg), class = "sampletidy_error")
.mig073_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig073_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig073_value <- function(tbl, field, v) {
  ty <- .mig073_types[[tbl]][[field]]
  na <- is.na(v) || !nzchar(v)
  switch(ty,
         num = if (na) NA_real_ else as.numeric(v),
         chr = if (na) NA_character_ else v,
         date = if (na) as.Date(NA) else as.Date(v),
         ts = if (na) as.POSIXct(NA, tz = "UTC") else as.POSIXct(v, tz = "UTC"))
}
.mig073_str <- function(x) { s <- .st_changelog_str(x); if (length(s) != 1L || is.na(s)) NA_character_ else s }

.mig073_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- inputs ---------------------------------------------------------------------------

.mig073_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig073_name))
  if (!file.exists(p)) .mig073_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  need <- c("gid", "item", "op", "tbl", "uuid", "field", "old", "new", "row_sha1", "note")
  if (!all(need %in% names(x))) .mig073_fail("INPUT lacks a column.")
  if (!all(x$item %in% .mig073_items)) .mig073_fail("INPUT has an unknown item.")
  if (!all(x$op %in% c("keep", "delete", "update"))) .mig073_fail("INPUT has an unknown op.")
  if (anyNA(x$row_sha1) || anyNA(x$uuid) || anyNA(x$gid)) .mig073_fail("INPUT misses a uuid, gid or sha.")
  u <- x$op == "update"
  if (anyNA(x$field[u])) .mig073_fail("an INPUT update names no field.")
  ok <- mapply(function(t, f) !is.null(.mig073_types[[t]]) && f %in% names(.mig073_types[[t]]), x$tbl[u], x$field[u])
  if (!all(ok)) .mig073_fail("an INPUT update writes a column this migration does not.")
  if (anyDuplicated(paste(x$tbl, x$uuid, x$field, x$op)[x$op != "keep"])) .mig073_fail("INPUT repeats a write.")
  if (any(x$op == "delete" & x$tbl != "analysis")) .mig073_fail("INPUT deletes outside analysis.")
  g <- tapply(x$item, x$gid, function(z) length(unique(z)))
  if (any(g != 1L)) .mig073_fail("an INPUT group spans items.")
  ng <- table(factor(x$item[!duplicated(x$gid)], levels = .mig073_items))
  if (!identical(as.integer(ng), unname(.mig073_n_groups[.mig073_items]))) .mig073_fail("INPUT group counts are not as planned.")
  for (gid in x$gid[x$item == "C1" & !duplicated(x$gid)]) {
    r <- x[x$gid == gid, , drop = FALSE]
    if (nrow(r) != 2L || !setequal(r$op, c("keep", "delete"))) .mig073_fail(sprintf("C1 group %s is not one keep + one delete.", gid))
  }
  x
}

# sha1 of each row as text (as 069/070/071; the frozen value comes from the same function).
.mig073_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df$uuid)
}

.mig073_rows <- function(con, tbl, ids) {
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s ORDER BY uuid', tbl, .mig073_inlist(ids)))
}

.mig073_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  s <- .mig073_df_sha(.mig073_rows(con, tbl, ids))
  out[names(s)] <- s
  out[ids]
}

# Every VARCHAR column of every base table except change_log (history) holding any of `ids`.
.mig073_refs <- function(con, ids, allow) {
  cols <- DBI::dbGetQuery(con, "SELECT c.table_name, c.column_name FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'main' AND t.table_type = 'BASE TABLE' AND c.data_type = 'VARCHAR'
      AND c.table_name <> 'change_log' ORDER BY 1, 2")
  hits <- list()
  for (i in seq_len(nrow(cols))) {
    tc <- paste(cols$table_name[[i]], cols$column_name[[i]], sep = ".")
    if (tc %in% allow) next
    h <- DBI::dbGetQuery(con, sprintf('SELECT DISTINCT "%s" AS v FROM "%s" WHERE "%s" IN %s', cols$column_name[[i]],
                                      cols$table_name[[i]], cols$column_name[[i]], .mig073_inlist(ids)))$v
    if (length(h)) hits[[length(hits) + 1]] <- data.frame(id = h, where = tc, stringsAsFactors = FALSE)
  }
  if (!length(hits)) return(data.frame(id = character(), where = character()))
  do.call(rbind, hits)
}

# ---- preconditions -----------------------------------------------------------------

# Hard failures abort; per-group problems come back as (gid, problem) for SKIPPED.
.mig073_check_preconditions <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig073_requires, have)
  if (length(miss)) .mig073_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  probs <- list()
  add <- function(gid, msg) if (length(gid)) probs[[length(probs) + 1]] <<- data.frame(gid = gid, problem = msg, stringsAsFactors = FALSE)

  for (t in unique(x$tbl)) {
    r <- x[x$tbl == t, , drop = FALSE]
    s <- .mig073_row_sha(con, t, r$uuid)
    bad <- is.na(s) | s != r$row_sha1
    add(r$gid[bad], sprintf("%s %s missing or not as frozen", t, r$uuid[bad]))
    up <- r[r$op == "update", , drop = FALSE]
    if (nrow(up)) {
      cur <- .mig073_rows(con, t, up$uuid)
      have_old <- vapply(seq_len(nrow(up)), function(i) {
        k <- match(up$uuid[[i]], cur$uuid); if (is.na(k)) return("<missing>")
        .mig073_str(cur[[up$field[[i]]]][[k]])
      }, "")
      bad <- !((is.na(have_old) & is.na(up$old)) | (!is.na(have_old) & !is.na(up$old) & have_old == up$old))
      add(up$gid[bad], sprintf("%s %s.%s is no longer %s", t, up$uuid[bad], up$field[bad], up$old[bad]))
    }
  }

  # C1: the pair is still exactly the two analyses on its (sample, lab_method), with
  # identical values, the kept copy inserted first.
  c1 <- x[x$item == "C1", , drop = FALSE]
  if (nrow(c1)) {
    A <- .mig073_rows(con, "analysis", c1$uuid)
    L <- DBI::dbGetQuery(con, sprintf("SELECT uuid_row, min(\"at\") AS at_ FROM change_log WHERE tbl = 'analysis'
      AND action = 'insert' AND uuid_row IN %s GROUP BY uuid_row", .mig073_inlist(c1$uuid)))
    vals <- c("value", "value_chr", "quantified", "rl_low", "rl_high", "purpose", "comments")
    for (gid in unique(c1$gid)) {
      r <- c1[c1$gid == gid, , drop = FALSE]
      k <- A[match(r$uuid[r$op == "keep"], A$uuid), , drop = FALSE]
      d <- A[match(r$uuid[r$op == "delete"], A$uuid), , drop = FALSE]
      if (is.na(k$uuid) || is.na(d$uuid)) next   # already reported by the sha check
      if (k$uuid_sample != d$uuid_sample || k$uuid_lab != d$uuid_lab) { add(gid, "the pair is not on one (sample, lab_method)"); next }
      n <- .mig073_scalar(con, "SELECT count(*) FROM analysis WHERE uuid_sample = ? AND uuid_lab = ?", k$uuid_sample, k$uuid_lab)
      if (n != 2L) add(gid, sprintf("(sample, lab_method) now holds %d analyses, not 2", n))
      same <- vapply(vals, function(f) identical(.mig073_str(k[[f]][[1]]), .mig073_str(d[[f]][[1]])), TRUE)
      if (!all(same)) add(gid, sprintf("values differ (%s): not a pure duplicate", paste(vals[!same], collapse = ", ")))
      tk <- L$at_[match(k$uuid, L$uuid_row)]; td <- L$at_[match(d$uuid, L$uuid_row)]
      if (length(tk) != 1L || length(td) != 1L || is.na(tk) || is.na(td) || !(tk < td))
        add(gid, "the kept copy is not the earlier-created one")
    }
  }

  del <- x[x$op == "delete", , drop = FALSE]
  if (nrow(del)) {
    h <- .mig073_refs(con, del$uuid, allow = "analysis.uuid")
    if (nrow(h)) add(del$gid[match(h$id, del$uuid)], sprintf("analysis %s is referenced by %s", h$id, h$where))
  }

  if (!length(probs)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  p <- do.call(rbind, probs)
  stats::aggregate(problem ~ gid, data = p, FUN = function(z) paste(unique(z), collapse = "; "))
}

.mig073_restrict <- function(x, skipped) x[!(x$gid %in% skipped$gid), , drop = FALSE]

# ---- targeted checks ---------------------------------------------------------------------

# The offender keys each planned group clears.
.mig073_cleared_keys <- function(con, planned) {
  out <- list()
  c1 <- planned[planned$item == "C1" & planned$op == "keep", , drop = FALSE]
  if (nrow(c1)) {
    A <- .mig073_rows(con, "analysis", c1$uuid)
    out$dup_analysis_sample_method <- paste(A$uuid_sample, A$uuid_lab)
  }
  c6 <- planned[planned$item == "C6", , drop = FALSE]
  if (nrow(c6)) out$alias_window_ambiguous <- paste(sort(unique(c6$uuid)), collapse = " ")
  c7 <- planned[planned$item == "C7" & planned$tbl == "feature", , drop = FALSE]
  if (nrow(c7)) {
    # the feature's samples dated in [new date_start, old date_start)
    r <- c7[c7$field == "date_start", , drop = FALSE]
    out$sample_in_feature_window <- unlist(lapply(seq_len(nrow(r)), function(i) DBI::dbGetQuery(con, "
      SELECT s.uuid FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      WHERE fa.uuid_feature = ?
        AND CAST(timezone('Australia/Sydney', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) >= CAST(? AS DATE)
        AND CAST(timezone('Australia/Sydney', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) < CAST(? AS DATE)",
      params = list(r$uuid[[i]], r$new[[i]], r$old[[i]]))$uuid))
  }
  c8 <- planned[planned$item == "C8", , drop = FALSE]
  if (nrow(c8)) out$sample_date_datetime_agree <- unique(c8$uuid)
  out
}

# Compare the all-tier checks before/after: no new key or error anywhere; the
# targeted checks lose exactly the cleared keys. NULL = fine.
.mig073_checks_problem <- function(before, after, cleared) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    bk <- if (nrow(b)) b$keys[[1]] else character()
    ak <- after$keys[[i]]
    added <- setdiff(ak, bk)
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
    want <- setdiff(bk, cleared[[nm]] %||% character())
    if (nm %in% names(cleared)) {
      if (!all(cleared[[nm]] %in% bk)) return(sprintf("check %s did not list a key this migration clears", nm))
      if (!setequal(ak, want)) return(sprintf("check %s has %d offenders, not the expected %d", nm, length(ak), length(want)))
    } else if (nm %in% .mig073_target && !setequal(ak, bk)) {
      return(sprintf("check %s changed unexpectedly", nm))
    }
  }
  NULL
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Absolute form for a re-verify (no baseline): no planned key is still an offender.
.mig073_targets_problem <- function(con, planned) {
  now <- db_checks(con, tier = "all")
  cleared <- .mig073_cleared_keys(con, planned)
  for (nm in names(cleared)) {
    k <- now$keys[[which(now$name == nm)]]
    if (now$status[now$name == nm] == "error") return(sprintf("check %s errors", nm))
    if (any(cleared[[nm]] %in% k)) return(sprintf("check %s still lists a key 073 clears", nm))
  }
  NULL
}

# ---- verify ---------------------------------------------------------------------------

.mig073_expected_log <- function(planned) {
  u <- planned[planned$op == "update", , drop = FALSE]
  d <- planned[planned$op == "delete", , drop = FALSE]
  e <- c(table(paste(u$tbl, "update", sep = "|")), table(paste(d$tbl, "delete", sep = "|")))
  stats::setNames(as.integer(e), names(e))
}

.mig073_done_problem <- function(con, x, planned) {
  if (.mig073_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig073_marker_version) != 1L)
    return("marker 1073 missing")
  sk <- x[!(x$gid %in% planned$gid), , drop = FALSE]
  # skipped groups untouched by this migration
  if (nrow(sk)) {
    L <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT uuid_row FROM change_log WHERE actor = ? AND uuid_row IN %s",
                                      .mig073_inlist(sk$uuid)), params = list(.mig073_actor))
    if (nrow(L)) return(sprintf("skipped row %s was written", L$uuid_row[[1]]))
  }
  # deletes gone; kept rows as frozen
  d <- planned[planned$op == "delete", , drop = FALSE]
  if (nrow(d) && .mig073_scalar(con, sprintf("SELECT count(*) FROM analysis WHERE uuid IN %s", .mig073_inlist(d$uuid))) > 0L)
    return("a planned analysis delete is still present")
  k <- planned[planned$op == "keep", , drop = FALSE]
  for (t in unique(k$tbl)) {
    r <- k[k$tbl == t, , drop = FALSE]
    s <- .mig073_row_sha(con, t, r$uuid)
    if (any(is.na(s) | s != r$row_sha1)) return(sprintf("kept %s row %s changed", t, r$uuid[is.na(s) | s != r$row_sha1][[1]]))
  }
  # updates hold their new values
  u <- planned[planned$op == "update", , drop = FALSE]
  for (t in unique(u$tbl)) {
    r <- u[u$tbl == t, , drop = FALSE]
    cur <- .mig073_rows(con, t, r$uuid)
    for (i in seq_len(nrow(r))) {
      j <- match(r$uuid[[i]], cur$uuid)
      if (is.na(j)) return(sprintf("%s %s missing", t, r$uuid[[i]]))
      got <- .mig073_str(cur[[r$field[[i]]]][[j]])
      want <- .mig073_str(.mig073_value(t, r$field[[i]], r$new[[i]]))
      if (!identical(got, want)) return(sprintf("%s %s.%s is %s, not %s", t, r$uuid[[i]], r$field[[i]], got, want))
    }
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig073_actor))
  got <- stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
  want <- .mig073_expected_log(planned)
  if (!identical(got[sort(names(got))], want[sort(names(want))]))
    return(sprintf("073 change_log rows are %s, not %s", paste(names(got), got, collapse = " "),
                   paste(names(want), want, collapse = " ")))
  NULL
}

.mig073_verify <- function(con, x, planned) {
  pr <- .mig073_done_problem(con, x, planned)
  if (!is.null(pr)) cli::cli_abort(paste0("073 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig073_counts <- function(con) {
  tabs <- c("analysis", "sample", "sample_lab_id", "feature", "feature_alias", "lab_method", "asset", "ingest_file",
            "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig073_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table whole, except the touched ones outside this migration's rows.
.mig073_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "feature", "feature_alias", "sample", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  for (t in c("analysis", "feature", "feature_alias", "sample"))
    out[[paste0(t, "_rest")]] <- q(sprintf('SELECT * FROM "%s" WHERE uuid NOT IN %s ORDER BY uuid', t,
                                           .mig073_inlist(x$uuid[x$tbl == t])))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig073_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig073_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# ---- apply ---------------------------------------------------------------------------------

.mig073_why <- function(r) sprintf("%s [%s %s]: %s", .mig073_reason, r$item[[1]], r$gid[[1]], r$note[[1]])

.mig073_apply <- function(con, x, planned, recorded_at, logf) {
  baseline <- db_checks(con, tier = "migration")
  before_all <- db_checks(con, tier = "all")
  cleared <- .mig073_cleared_keys(con, planned)
  sums_before <- .mig073_checksum(con, x)
  counts_want <- .mig073_counts(con)
  n_del <- sum(planned$op == "delete")
  counts_want$analysis <- counts_want$analysis - n_del
  counts_want$change_log <- counts_want$change_log + sum(.mig073_expected_log(planned))
  counts_want$schema_version <- counts_want$schema_version + 1L
  db_transaction(con, function(con) {
    d <- planned[planned$op == "delete", , drop = FALSE]
    for (i in seq_len(nrow(d)))
      db_delete(con, "analysis", uuid = d$uuid[[i]], actor = .mig073_actor, reason = .mig073_why(d[i, , drop = FALSE]))
    u <- planned[planned$op == "update", , drop = FALSE]
    for (key in unique(paste(u$tbl, u$uuid))) {
      r <- u[paste(u$tbl, u$uuid) == key, , drop = FALSE]
      ch <- stats::setNames(lapply(seq_len(nrow(r)), function(i) .mig073_value(r$tbl[[i]], r$field[[i]], r$new[[i]])), r$field)
      db_update(con, r$tbl[[1]], uuid = r$uuid[[1]], changes = ch, actor = .mig073_actor, reason = .mig073_why(r))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig073_marker_version, recorded_at))
    .mig073_verify(con, x, planned)
    if (!identical(.mig073_counts(con), counts_want)) .mig073_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig073_checksum(con, x))) .mig073_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig073_checks_problem(before_all, after_all, cleared)
    if (!is.null(pr)) .mig073_fail(paste0("standing checks: ", pr))
    for (nm in unname(.mig073_target)) {
      b <- before_all[before_all$name == nm, ]; a <- after_all[after_all$name == nm, ]
      logf("check %-34s %s n=%s -> %s n=%s", nm, b$status, b$n, a$status, a$n)
    }
    logf("Deleted %d duplicate analyses; updated %d rows (%d fields).", n_del,
         length(unique(paste(u$tbl, u$uuid))), nrow(u))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig073_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig073_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig073_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig073_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig073_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("073: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig073_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig073_name, what))

.mig073_read_skipped <- function(csv_dir) {
  f <- .mig073_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ----------------------------------------------------------------------------------

mig073_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig073_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig073_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig073_read_skipped(csv_dir)
    if (is.null(sk)) .mig073_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig073_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      .mig073_ensure_icu(check_con)
      planned <- .mig073_restrict(x, sk)
      .mig073_verify(check_con, x, planned)
      pr <- .mig073_targets_problem(check_con, planned)
      if (!is.null(pr)) .mig073_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("073 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  skipped <- tryCatch({
    if (.mig073_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig073_actor) > 0L)
      .mig073_fail("change_log already holds 073 rows but the marker is absent; refusing.")
    .mig073_check_preconditions(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  planned <- .mig073_restrict(x, skipped)
  gi <- planned[!duplicated(planned$gid), , drop = FALSE]
  logf("Plan: %s; %d analysis deletes, %d field updates; %d group(s) skipped.",
       paste(sprintf("%s %d", names(table(gi$item)), as.integer(table(gi$item))), collapse = ", "),
       sum(planned$op == "delete"), sum(planned$op == "update"), nrow(skipped))
  if (nrow(skipped)) for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    for (t in unique(x$tbl))
      .mig073_write_csv(.mig073_rows(bk_con, t, x$uuid[x$tbl == t]), .mig073_csv(csv_dir, paste0("BACKUP-", t)), "uuid")
    .mig073_write_csv(skipped, .mig073_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig073_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig073_ensure_icu(con)
    again <- .mig073_check_preconditions(con, x)
    if (!identical(again, skipped)) .mig073_fail("the skip set changed since the dry check; re-run.")
    .mig073_apply(con, x, planned, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig073_name, .mig073_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
