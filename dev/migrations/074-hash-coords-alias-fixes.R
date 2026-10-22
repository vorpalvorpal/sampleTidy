# Operator-run migration: the three standing-check findings 073 left for Robin, now ruled.
# Marker 1074. Requires 1073.
#
# Authority: Robin, 2026-10-22 (rulings on 073's NOT DONE items C4, C5 and the b.s22 ->
# B.S06 arm's start date).
#
# ---- WHAT (frozen in 074-hash-coords-alias-fixes-INPUT.csv; `item` = ruling) ------------
#   D1 hash_format (13 groups, one per row): delete the 13 ingest_file rows still keyed
#      by SHA-256. They are 'quarantined'/'unclaimed' records first seen 2026-07-23 (the
#      batch-2026-07-23 input folder) for files that no longer exist anywhere (073 C4).
#      Guard, per row: nothing references the hash outside change_log (history, stays):
#      every VARCHAR column of every other base table is scanned (ingest_sighting.hash,
#      asset.hash, review_queue.source_hash, sample_lab_id.source_hash, ...); a
#      referenced row is SKIPPED and reported. change_log rows naming the hash as
#      source_hash would become change_log_dangling_source_hash offenders: the all-tier
#      comparison refuses that (at the freeze there are none).
#   D2 feature_coords (3 groups): B.S02, B.MW05, B.MW03 have lon/lat NaN and geom_wkt
#      'POINT EMPTY' (feature.lon/lat are NOT NULL, so NaN was the only "unknown").
#      lon, lat and geom_wkt take the B.centroid feature's values (read from live at the
#      freeze and frozen here; B.centroid's row is frozen too, and must still hold
#      them); comments gets "Old monitoring point; location unknown. Coordinates are the
#      Blaxland site centroid as a placeholder (Robin, 2026-10-22)." (appended with
#      '; ' to a non-NULL comment).
#   D3 the b.s22 historical_code arm -> B.S06 (6ca0abf7, date_end 2021-04-14, open
#      start): date_start -> 2021-03-26. Guard: no sample resolving via that arm
#      (sample.uuid_feature_alias) is dated before 2021-03-26 in Australia/Sydney (any
#      such sample skips the group and is listed); the other b.s22 arm (-> B.TS18,
#      0f90862a, 2021-11-12) is frozen; alias_window_ambiguous must not change.
#
# ---- CHECKS -------------------------------------------------------------------------
#   Before, per group (a failing group is SKIPPED whole, listed in
#   074-...-SKIPPED.csv): every row the group touches (and the frozen-only rows:
#   B.centroid, the B.TS18 arm) is byte for byte as frozen (sha1); each updated field
#   still holds its frozen old value; D1 as above; D2 B.centroid still holds the frozen
#   lon/lat/geom_wkt exactly; D3 as above.
#   Inside the one write transaction: baseline <- db_checks(con, tier = "migration")
#   and an all-tier baseline before the change; after it every planned row is as
#   planned and nothing else moved (checksums; counts: ingest_file -n, change_log +n,
#   schema_version +1); mig_db_checks_gate(con, baseline); and on the all tier no check
#   gains an offender key or a new error, hash_format and feature_coords lose exactly
#   the planned keys, and alias_window_ambiguous is unchanged.
#
# One commit: no write changes an indexed sample column or deletes a row another table
# references through a foreign key.
#
# Rows are keyed by `id`: the hash for ingest_file, the uuid elsewhere. db_delete() on
# ingest_file is keyed by `key = list(hash =)`, so its change_log row has no uuid_row;
# the reason names the hash.
#
# Backups: verified whole-file snapshot; BACKUP CSVs of every ingest_file, feature and
# feature_alias row frozen in the INPUT. Idempotent: marker present -> re-verify against
# the SKIPPED CSV, no-op.
#
# Use:
#   env <- new.env(); sys.source("dev/migrations/074-hash-coords-alias-fixes.R", envir = env)
#   env$mig074_run(db = ..., snapshot_dir = ..., dry_run = TRUE)

.mig074_marker_version <- 1074L
.mig074_requires <- 1073L
.mig074_name <- "074-hash-coords-alias-fixes"
.mig074_actor <- .mig074_name
.mig074_items <- c("D1", "D2", "D3")
.mig074_reason <- "074 (Robin 2026-10-22: rulings on the standing-check findings 073 left open)"
.mig074_n_groups <- c(D1 = 13L, D2 = 3L, D3 = 1L)
# The check each item clears (D3 clears none: alias_window_ambiguous must stay as it is).
.mig074_target <- c(D1 = "hash_format", D2 = "feature_coords", D3 = "alias_window_ambiguous")
.mig074_pk <- c(ingest_file = "hash", feature = "uuid", feature_alias = "uuid")
.mig074_types <- list(
  feature = c(lon = "num", lat = "num", geom_wkt = "chr", comments = "chr"),
  feature_alias = c(date_start = "date")
)
.mig074_d3_tz <- "Australia/Sydney"

.mig074_fail <- function(msg) cli::cli_abort(paste0(.mig074_name, ": ", msg), class = "sampletidy_error")
.mig074_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig074_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig074_value <- function(tbl, field, v) {
  ty <- .mig074_types[[tbl]][[field]]
  na <- is.na(v) || !nzchar(v)
  switch(ty,
         num = if (na) NA_real_ else as.numeric(v),
         chr = if (na) NA_character_ else v,
         date = if (na) as.Date(NA) else as.Date(v))
}
.mig074_str <- function(x) { s <- .st_changelog_str(x); if (length(s) != 1L || is.na(s)) NA_character_ else s }
# A frozen number is written with 17 significant digits, so it round-trips exactly.
.mig074_num_str <- function(x) if (is.nan(x)) "NaN" else if (is.na(x)) NA_character_ else sprintf("%.17g", x)
# Does a current value equal a frozen text value? Numbers compare exactly.
.mig074_same <- function(tbl, field, cur, frozen) {
  ty <- .mig074_types[[tbl]][[field]]
  if (identical(ty, "num")) {
    if (is.na(frozen)) return(is.na(cur) && !is.nan(cur))
    if (frozen == "NaN") return(is.nan(cur))
    return(!is.na(cur) && identical(as.numeric(cur), as.numeric(frozen)))
  }
  s <- .mig074_str(cur)
  (is.na(s) && is.na(frozen)) || (!is.na(s) && !is.na(frozen) && s == frozen)
}

.mig074_ensure_icu <- function(con) {
  DBI::dbExecute(con, "INSTALL icu")
  DBI::dbExecute(con, "LOAD icu")
  invisible(NULL)
}

# ---- inputs ---------------------------------------------------------------------------

.mig074_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig074_name))
  if (!file.exists(p)) .mig074_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  need <- c("gid", "item", "op", "tbl", "id", "field", "old", "new", "row_sha1", "note")
  if (!all(need %in% names(x))) .mig074_fail("INPUT lacks a column.")
  if (!all(x$item %in% .mig074_items)) .mig074_fail("INPUT has an unknown item.")
  if (!all(x$op %in% c("keep", "delete", "update"))) .mig074_fail("INPUT has an unknown op.")
  if (!all(x$tbl %in% names(.mig074_pk))) .mig074_fail("INPUT names a table this migration does not touch.")
  if (anyNA(x$row_sha1) || anyNA(x$id) || anyNA(x$gid)) .mig074_fail("INPUT misses an id, gid or sha.")
  u <- x$op == "update"
  if (anyNA(x$field[u])) .mig074_fail("an INPUT update names no field.")
  ok <- mapply(function(t, f) !is.null(.mig074_types[[t]]) && f %in% names(.mig074_types[[t]]), x$tbl[u], x$field[u])
  if (!all(ok)) .mig074_fail("an INPUT update writes a column this migration does not.")
  if (anyDuplicated(paste(x$tbl, x$id, x$field, x$op)[x$op != "keep"])) .mig074_fail("INPUT repeats a write.")
  if (any(x$op == "delete" & x$tbl != "ingest_file")) .mig074_fail("INPUT deletes outside ingest_file.")
  if (any(x$op == "delete" & x$item != "D1") || any(x$op == "update" & x$item == "D1")) .mig074_fail("INPUT ops do not fit their items.")
  g <- tapply(x$item, x$gid, function(z) length(unique(z)))
  if (any(g != 1L)) .mig074_fail("an INPUT group spans items.")
  ng <- table(factor(x$item[!duplicated(x$gid)], levels = .mig074_items))
  if (!identical(as.integer(ng), unname(.mig074_n_groups[.mig074_items]))) .mig074_fail("INPUT group counts are not as planned.")
  for (gid in unique(x$gid[x$item == "D1"]))
    if (sum(x$gid == gid) != 1L) .mig074_fail(sprintf("D1 group %s is not one delete.", gid))
  for (gid in unique(x$gid[x$item == "D2"])) {
    r <- x[x$gid == gid, , drop = FALSE]
    if (!setequal(r$field[r$op == "update"], names(.mig074_types$feature)) || sum(r$op == "keep") != 1L)
      .mig074_fail(sprintf("D2 group %s is not 4 feature updates + the frozen centroid.", gid))
  }
  x
}

# sha1 of each row as text (as 073; the frozen value comes from the same function).
.mig074_df_sha <- function(df, pk) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df[[pk]])
}

.mig074_rows <- function(con, tbl, ids) {
  pk <- .mig074_pk[[tbl]]
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY "%s"', tbl, pk, .mig074_inlist(ids), pk))
}

.mig074_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  s <- .mig074_df_sha(.mig074_rows(con, tbl, ids), .mig074_pk[[tbl]])
  out[names(s)] <- s
  out[ids]
}

# Every VARCHAR column of every base table except change_log (history) holding any of `ids`.
.mig074_refs <- function(con, ids, allow) {
  cols <- DBI::dbGetQuery(con, "SELECT c.table_name, c.column_name FROM information_schema.columns c
    JOIN information_schema.tables t ON t.table_name = c.table_name AND t.table_schema = c.table_schema
    WHERE c.table_schema = 'main' AND t.table_type = 'BASE TABLE' AND c.data_type = 'VARCHAR'
      AND c.table_name <> 'change_log' ORDER BY 1, 2")
  hits <- list()
  for (i in seq_len(nrow(cols))) {
    tc <- paste(cols$table_name[[i]], cols$column_name[[i]], sep = ".")
    if (tc %in% allow) next
    h <- DBI::dbGetQuery(con, sprintf('SELECT DISTINCT "%s" AS v FROM "%s" WHERE "%s" IN %s', cols$column_name[[i]],
                                      cols$table_name[[i]], cols$column_name[[i]], .mig074_inlist(ids)))$v
    if (length(h)) hits[[length(hits) + 1]] <- data.frame(id = h, where = tc, stringsAsFactors = FALSE)
  }
  if (!length(hits)) return(data.frame(id = character(), where = character()))
  do.call(rbind, hits)
}

# D3: samples resolving via the arm, dated (Sydney) before the new date_start.
.mig074_d3_early <- function(con, arm, start) {
  DBI::dbGetQuery(con, sprintf("SELECT s.uuid, CAST(CAST(timezone('%s', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) AS VARCHAR) AS d
    FROM \"sample\" s WHERE s.uuid_feature_alias = ?
      AND CAST(timezone('%s', timezone('UTC', coalesce(s.datetime, s.date))) AS DATE) < CAST(? AS DATE) ORDER BY 2, 1",
    .mig074_d3_tz, .mig074_d3_tz), params = list(arm, start))
}

# ---- preconditions -----------------------------------------------------------------

# Hard failures abort; per-group problems come back as (gid, problem) for SKIPPED.
.mig074_check_preconditions <- function(con, x) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig074_requires, have)
  if (length(miss)) .mig074_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  probs <- list()
  add <- function(gid, msg) if (length(gid)) probs[[length(probs) + 1]] <<- data.frame(gid = gid, problem = msg, stringsAsFactors = FALSE)

  for (t in unique(x$tbl)) {
    r <- x[x$tbl == t, , drop = FALSE]
    s <- .mig074_row_sha(con, t, r$id)
    bad <- is.na(s) | s != r$row_sha1
    add(r$gid[bad], sprintf("%s %s missing or not as frozen", t, r$id[bad]))
    up <- r[r$op == "update", , drop = FALSE]
    if (nrow(up)) {
      cur <- .mig074_rows(con, t, up$id)
      pk <- .mig074_pk[[t]]
      ok <- vapply(seq_len(nrow(up)), function(i) {
        k <- match(up$id[[i]], cur[[pk]]); if (is.na(k)) return(FALSE)
        .mig074_same(t, up$field[[i]], cur[[up$field[[i]]]][[k]], up$old[[i]])
      }, TRUE)
      add(up$gid[!ok], sprintf("%s %s.%s is no longer %s", t, up$id[!ok], up$field[!ok], up$old[!ok]))
    }
  }

  # D1: nothing outside change_log references the hash.
  del <- x[x$op == "delete", , drop = FALSE]
  if (nrow(del)) {
    h <- .mig074_refs(con, del$id, allow = "ingest_file.hash")
    if (nrow(h)) add(del$gid[match(h$id, del$id)], sprintf("ingest_file %s is referenced by %s", h$id, h$where))
  }

  # D2: the centroid still holds exactly the frozen lon / lat / geom_wkt.
  d2 <- x[x$item == "D2", , drop = FALSE]
  for (gid in unique(d2$gid)) {
    r <- d2[d2$gid == gid, , drop = FALSE]
    c0 <- .mig074_rows(con, "feature", r$id[r$op == "keep"])
    if (nrow(c0) != 1L) next   # reported by the sha check
    for (f in c("lon", "lat", "geom_wkt")) {
      want <- r$new[r$op == "update" & r$field == f]
      if (!.mig074_same("feature", f, c0[[f]][[1]], want)) add(gid, sprintf("B.centroid %s is no longer %s", f, want))
    }
  }

  # D3: no sample on the arm before the new start.
  d3 <- x[x$item == "D3" & x$op == "update" & x$field == "date_start", , drop = FALSE]
  for (i in seq_len(nrow(d3))) {
    e <- .mig074_d3_early(con, d3$id[[i]], d3$new[[i]])
    if (nrow(e)) add(d3$gid[[i]], sprintf("sample(s) on the arm dated before %s: %s", d3$new[[i]],
                                          paste(sprintf("%s (%s)", e$uuid, e$d), collapse = ", ")))
  }

  if (!length(probs)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  p <- do.call(rbind, probs)
  stats::aggregate(problem ~ gid, data = p, FUN = function(z) paste(unique(z), collapse = "; "))
}

.mig074_restrict <- function(x, skipped) x[!(x$gid %in% skipped$gid), , drop = FALSE]

# ---- targeted checks ---------------------------------------------------------------------

# The offender keys each planned group clears.
.mig074_cleared_keys <- function(planned) {
  out <- list()
  d1 <- planned[planned$item == "D1", , drop = FALSE]
  if (nrow(d1)) out$hash_format <- unique(d1$id)
  d2 <- planned[planned$item == "D2" & planned$op == "update", , drop = FALSE]
  if (nrow(d2)) out$feature_coords <- unique(d2$id)
  out
}

# Compare the all-tier checks before/after: no new key or error anywhere; the
# targeted checks lose exactly the cleared keys; a watched check is unchanged. NULL = fine.
.mig074_checks_problem <- function(before, after, cleared) {
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
    } else if (nm %in% .mig074_target && !setequal(ak, bk)) {
      return(sprintf("check %s changed unexpectedly", nm))
    }
  }
  NULL
}

`%||%` <- function(a, b) if (is.null(a)) b else a

# Absolute form for a re-verify (no baseline): no planned key is still an offender,
# and no alias_window_ambiguous key names a D3 arm.
.mig074_targets_problem <- function(con, planned) {
  now <- db_checks(con, tier = "all")
  cleared <- .mig074_cleared_keys(planned)
  cleared$alias_window_ambiguous <- character()
  for (nm in names(cleared)) {
    if (now$status[now$name == nm] == "error") return(sprintf("check %s errors", nm))
    k <- now$keys[[which(now$name == nm)]]
    if (any(cleared[[nm]] %in% k)) return(sprintf("check %s still lists a key 074 clears", nm))
  }
  arms <- unique(planned$id[planned$item == "D3"])
  k <- now$keys[[which(now$name == "alias_window_ambiguous")]]
  if (length(arms) && any(vapply(arms, function(a) any(grepl(a, k, fixed = TRUE)), TRUE)))
    return("check alias_window_ambiguous lists a b.s22 arm")
  NULL
}

# ---- verify ---------------------------------------------------------------------------

.mig074_expected_log <- function(planned) {
  u <- planned[planned$op == "update", , drop = FALSE]
  d <- planned[planned$op == "delete", , drop = FALSE]
  e <- c(table(paste(u$tbl, "update", sep = "|")), table(paste(d$tbl, "delete", sep = "|")))
  stats::setNames(as.integer(e), names(e))
}

.mig074_done_problem <- function(con, x, planned) {
  if (.mig074_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig074_marker_version) != 1L)
    return("marker 1074 missing")
  sk <- x[!(x$gid %in% planned$gid) & x$op != "keep", , drop = FALSE]
  # skipped groups untouched by this migration (an ingest_file delete has no uuid_row; its reason names the hash)
  if (nrow(sk)) {
    L <- DBI::dbGetQuery(con, "SELECT uuid_row, reason FROM change_log WHERE actor = ?", params = list(.mig074_actor))
    for (id in unique(sk$id)) {
      if (any(L$uuid_row %in% id) || any(grepl(id, L$reason, fixed = TRUE))) return(sprintf("skipped row %s was written", id))
    }
  }
  d <- planned[planned$op == "delete", , drop = FALSE]
  if (nrow(d) && .mig074_scalar(con, sprintf("SELECT count(*) FROM ingest_file WHERE hash IN %s", .mig074_inlist(d$id))) > 0L)
    return("a planned ingest_file delete is still present")
  k <- planned[planned$op == "keep", , drop = FALSE]
  for (t in unique(k$tbl)) {
    r <- k[k$tbl == t & !duplicated(paste(k$tbl, k$id)), , drop = FALSE]
    s <- .mig074_row_sha(con, t, r$id)
    if (any(is.na(s) | s != r$row_sha1)) return(sprintf("kept %s row %s changed", t, r$id[is.na(s) | s != r$row_sha1][[1]]))
  }
  u <- planned[planned$op == "update", , drop = FALSE]
  for (t in unique(u$tbl)) {
    r <- u[u$tbl == t, , drop = FALSE]
    cur <- .mig074_rows(con, t, r$id)
    pk <- .mig074_pk[[t]]
    for (i in seq_len(nrow(r))) {
      j <- match(r$id[[i]], cur[[pk]])
      if (is.na(j)) return(sprintf("%s %s missing", t, r$id[[i]]))
      if (!.mig074_same(t, r$field[[i]], cur[[r$field[[i]]]][[j]], r$new[[i]]))
        return(sprintf("%s %s.%s is %s, not %s", t, r$id[[i]], r$field[[i]], .mig074_str(cur[[r$field[[i]]]][[j]]), r$new[[i]]))
    }
  }
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig074_actor))
  got <- stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
  want <- .mig074_expected_log(planned)
  if (!identical(got[sort(names(got))], want[sort(names(want))]))
    return(sprintf("074 change_log rows are %s, not %s", paste(names(got), got, collapse = " "),
                   paste(names(want), want, collapse = " ")))
  NULL
}

.mig074_verify <- function(con, x, planned) {
  pr <- .mig074_done_problem(con, x, planned)
  if (!is.null(pr)) cli::cli_abort(paste0("074 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- counts, checksums ------------------------------------------------------------------

.mig074_counts <- function(con) {
  tabs <- c("analysis", "sample", "sample_lab_id", "feature", "feature_alias", "lab_method", "asset", "ingest_file",
            "ingest_sighting", "project", "review_queue", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig074_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Every base table whole, except the touched ones outside this migration's rows.
.mig074_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c(names(.mig074_pk), "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  w <- x[x$op != "keep", , drop = FALSE]
  for (t in names(.mig074_pk)) {
    pk <- .mig074_pk[[t]]
    out[[paste0(t, "_rest")]] <- q(sprintf('SELECT * FROM "%s" WHERE "%s" NOT IN %s ORDER BY "%s"', t, pk,
                                           .mig074_inlist(w$id[w$tbl == t]), pk))
  }
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig074_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig074_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# ---- apply ---------------------------------------------------------------------------------

.mig074_why <- function(r) sprintf("%s [%s %s]: %s", .mig074_reason, r$item[[1]], r$gid[[1]], r$note[[1]])

.mig074_apply <- function(con, x, planned, recorded_at, logf) {
  baseline <- db_checks(con, tier = "migration")
  before_all <- db_checks(con, tier = "all")
  cleared <- .mig074_cleared_keys(planned)
  sums_before <- .mig074_checksum(con, x)
  counts_want <- .mig074_counts(con)
  n_del <- sum(planned$op == "delete")
  counts_want$ingest_file <- counts_want$ingest_file - n_del
  counts_want$change_log <- counts_want$change_log + sum(.mig074_expected_log(planned))
  counts_want$schema_version <- counts_want$schema_version + 1L
  db_transaction(con, function(con) {
    d <- planned[planned$op == "delete", , drop = FALSE]
    for (i in seq_len(nrow(d)))
      db_delete(con, "ingest_file", key = list(hash = d$id[[i]]), actor = .mig074_actor,
                reason = .mig074_why(d[i, , drop = FALSE]))
    u <- planned[planned$op == "update", , drop = FALSE]
    for (key in unique(paste(u$tbl, u$id))) {
      r <- u[paste(u$tbl, u$id) == key, , drop = FALSE]
      ch <- stats::setNames(lapply(seq_len(nrow(r)), function(i) .mig074_value(r$tbl[[i]], r$field[[i]], r$new[[i]])), r$field)
      db_update(con, r$tbl[[1]], uuid = r$id[[1]], changes = ch, actor = .mig074_actor, reason = .mig074_why(r))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig074_marker_version, recorded_at))
    .mig074_verify(con, x, planned)
    if (!identical(.mig074_counts(con), counts_want)) .mig074_fail("table counts are not as planned.")
    if (!identical(sums_before, .mig074_checksum(con, x))) .mig074_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig074_checks_problem(before_all, after_all, cleared)
    if (!is.null(pr)) .mig074_fail(paste0("standing checks: ", pr))
    for (nm in unname(.mig074_target)) {
      b <- before_all[before_all$name == nm, ]; a <- after_all[after_all$name == nm, ]
      logf("check %-34s %s n=%s -> %s n=%s", nm, b$status, b$n, a$status, a$n)
    }
    logf("Deleted %d ingest_file rows; updated %d rows (%d fields).", n_del,
         length(unique(paste(u$tbl, u$id))), nrow(u))
    NULL
  })
  invisible(TRUE)
}

# ---- backups, files ------------------------------------------------------------------------

mig074_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig074_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig074_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig074_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig074_write_csv <- function(df, path, key) {
  utils::write.csv(df, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(df[[key]]))))
    cli::cli_abort("074: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig074_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig074_name, what))

.mig074_read_skipped <- function(csv_dir) {
  f <- .mig074_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# ---- run ----------------------------------------------------------------------------------

mig074_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x <- .mig074_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig074_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig074_read_skipped(csv_dir)
    if (is.null(sk)) .mig074_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig074_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      .mig074_ensure_icu(check_con)
      planned <- .mig074_restrict(x, sk)
      .mig074_verify(check_con, x, planned)
      pr <- .mig074_targets_problem(check_con, planned)
      if (!is.null(pr)) .mig074_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("074 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  skipped <- tryCatch({
    if (.mig074_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig074_actor) > 0L)
      .mig074_fail("change_log already holds 074 rows but the marker is absent; refusing.")
    .mig074_ensure_icu(pre_con)
    .mig074_check_preconditions(pre_con, x)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  planned <- .mig074_restrict(x, skipped)
  gi <- planned[!duplicated(planned$gid), , drop = FALSE]
  logf("Plan: %s; %d ingest_file deletes, %d field updates; %d group(s) skipped.",
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
      .mig074_write_csv(.mig074_rows(bk_con, t, unique(x$id[x$tbl == t])), .mig074_csv(csv_dir, paste0("BACKUP-", t)), .mig074_pk[[t]])
    .mig074_write_csv(skipped, .mig074_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  backup_path <- mig074_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    .mig074_ensure_icu(con)
    again <- .mig074_check_preconditions(con, x)
    if (!identical(again, skipped)) .mig074_fail("the skip set changed since the dry check; re-run.")
    .mig074_apply(con, x, planned, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig074_name, .mig074_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
