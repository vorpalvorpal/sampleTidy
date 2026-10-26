# Operator-run migration: backfill `ingest_file.uuid_asset`, the as-received -> asset link of
# the archive-settle design, for the rows archived before archive_file() wrote it.
# Marker 1088. Requires 1087.
#
# Authority: Robin, 2026-10-26 (approved the archive-settle design; this backfill is part of
# it: dev/STATE.md "Still to do", spec in the header of tests/testthat/test-archive-settle.R).
#
# ---- WHY ------------------------------------------------------------------------------
# `asset.hash` is the stored copy's SETTLED hash; `ingest_file(hash, uuid_asset)` is the
# as-received lookup that dedup and every received-file consumer resolve through first
# (`.ar_asset_for_hash()`), falling back to `asset.hash`. archive_file() now writes the link
# for new archives, but no package code wrote it before, so almost every existing row is NA.
# For the 56 assets 055/087 re-hashed, the fallback no longer finds them from the
# as-received hash: a re-sent original is not linked to its asset, so its inbox copy is never
# counted as removable (R-9.10 stall), and the folder/stem/completed-work lookups miss it.
#
# ---- WHAT (frozen in 088-backfill-ingest-file-uuid-asset-INPUT.csv) ---------------------
# For every ingest_file row with uuid_asset NULL, the candidate assets for its hash are
#   (a) every asset whose asset.hash equals ingest_file.hash (as received = settled), and
#   (b) every asset that 055 or 087 re-hashed away from that hash (their old -> new hashes,
#       from 055's frozen literals and 087's BACKUP CSV, each cross-checked against the
#       migration's own change_log rows and BACKUP CSVs at freeze).
# Exactly one candidate -> action "link": ingest_file.uuid_asset <- it, updated_at <- the
# migration time, as ingest_file_set_uuid_asset() does. More than one (061's multi-project
# assets, or a hash that is both one asset's hash and another's 055/087 old hash) -> action
# "skip", never guessed. None -> left alone (no asset holds those bytes: delivery emails,
# ignored or unclaimed files that were never archived).
# A (b) link also needs the asset's current hash to be 055/087's new hash and the asset's
# `insert` change_log row (actor ingest) to carry the as-received hash as source_hash, i.e.
# archive_file() made this asset from exactly those bytes; otherwise skip. Size is NOT a
# gate: 9 of the 17 linked 055 copies grew 15,872-22,528 bytes when SharePoint rewrote them
# (MsoDataStore only; for the 6 whose source survives the OLE Workbook stream is byte-identical,
# checked 2026-10-26), which 055 accepted by hand; INPUT's note records each.
# `size` is not filled: archive_settle() only reads it within window_hours of archiving.
#
# STATUSES. Every state is linked. archive_file() links whatever ingest_file row exists for
# the hash on both its new-asset and its reuse path, whatever that row's state, and the link
# records byte identity, not a routing verdict. So archived (commit_event, retained_sibling,
# 080/081 settled), ignored superseded_by_better_source (archived with the event), the one
# needs_review row and quarantined/unclaimed rows whose bytes an asset already holds are all
# linked. For an (a) row the link changes no lookup today, because `.ar_asset_for_hash()`
# already reaches the same asset through `asset.hash`. It keeps that true after a later settle.
#
# ---- CHECKS ---------------------------------------------------------------------------
# Pre-flight per link row (a failing row is SKIPPED, written to SKIPPED.csv, reported): the
# ingest_file row's sha1 is as frozen (so uuid_asset is still NULL); the target asset exists
# with asset.hash as frozen; source a: it is the ONLY asset with that hash; source 055/087:
# no asset holds the as-received hash, and the migration's change_log row records exactly
# this asset leaving it. Then ONE transaction: db_checks baseline, whole-table checksums of
# everything else (ingest_file outside uuid_asset/updated_at of the linked rows included),
# counts, mig_db_checks_gate(), and no all-tier check gains an offender. Idempotent: marker
# present -> re-verify, no-op.
#
#   Rscript dev/migrations/apply-088-backfill-ingest-file-uuid-asset.R

.mig088_marker_version <- 1088L
.mig088_requires <- 1087L
.mig088_name <- "088-backfill-ingest-file-uuid-asset"
.mig088_actor <- .mig088_name
.mig088_date <- "2026-10-26"
.mig088_reason <- "088 (Robin 2026-10-26, archive-settle design): backfill ingest_file.uuid_asset, the as-received -> asset link"
.mig088_cols <- c("hash", "action", "source", "uuid_asset", "asset_hash", "row_sha1", "note")
.mig088_sources <- c("a", "055", "087")
.mig088_rehash_actor <- c("055" = "055-rehash-sharepoint-rewritten-assets", "087" = "087-rehash-sharepoint-rewritten-xls")

.mig088_fail <- function(msg) cli::cli_abort(paste0(.mig088_name, ": ", msg), class = "sampletidy_error")
.mig088_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig088_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig088_row_reason <- function(source) sprintf("%s [%s]", .mig088_reason,
  if (source == "a") "as received = asset.hash" else sprintf("as received = %s's old hash", source))

.mig088_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}
.mig088_irow <- function(con, h) DBI::dbGetQuery(con, "SELECT * FROM ingest_file WHERE hash = ?", params = list(h))
# The asset was archived by ingest from exactly these received bytes: its change_log insert
# row carries them as source_hash (archive_file() passes the as-received hash).
.mig088_ingested_from <- function(con, uuid, h)
  .mig088_scalar(con, "SELECT COUNT(*) FROM change_log WHERE tbl = 'asset' AND action = 'insert' AND actor = 'ingest'
                         AND uuid_row = ? AND source_hash = ?", uuid, h) == 1L

.mig088_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "lab_qc_outlier", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig088_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig088_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig088_name))
  if (!file.exists(p)) .mig088_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig088_cols)) .mig088_fail("INPUT columns are not as planned.")
  if (!nrow(x) || anyDuplicated(x$hash) || anyNA(x$hash) || anyNA(x$row_sha1) || !all(x$action %in% c("link", "skip")))
    .mig088_fail("INPUT is empty, repeats a hash, has gaps, or has an unknown action.")
  l <- x[x$action == "link", , drop = FALSE]
  if (!nrow(l) || anyNA(l$uuid_asset) || anyNA(l$asset_hash) || !all(l$source %in% .mig088_sources) ||
      any((l$source == "a") != (l$asset_hash == l$hash)))
    .mig088_fail("INPUT link rows are incomplete, or a source disagrees with its hashes.")
  x
}
.mig088_links <- function(x) x[x$action == "link", , drop = FALSE]

# ---- freeze (run once, read-only, to write INPUT) --------------------------------------
# The 055/087 old -> new maps, each cross-checked three ways (frozen literals or INPUT, the
# untracked BACKUP CSV, the migration's own change_log rows).
.mig088_rehash_map <- function(con, mig_dir = "dev/migrations") {
  e <- new.env()
  sys.source(file.path(mig_dir, "055-rehash-sharepoint-rewritten-assets.R"), envir = e)
  m55 <- data.frame(uuid = e$.mig055_assets$uuid, old_hash = e$.mig055_assets$old_hash,
                    new_hash = e$.mig055_assets$new_hash, source = "055", stringsAsFactors = FALSE)
  b55 <- utils::read.csv(file.path(mig_dir, "055-rehash-sharepoint-rewritten-assets-BACKUP-asset.csv"), colClasses = "character")
  if (!setequal(paste(b55$uuid, b55$hash), paste(m55$uuid, m55$old_hash))) .mig088_fail("055 BACKUP disagrees with 055's literals.")
  i87 <- utils::read.csv(file.path(mig_dir, "087-rehash-sharepoint-rewritten-xls-INPUT.csv"), colClasses = "character")
  b87 <- utils::read.csv(file.path(mig_dir, "087-rehash-sharepoint-rewritten-xls-BACKUP-asset.csv"), colClasses = "character")
  m87 <- data.frame(uuid = b87$uuid, old_hash = b87$old_hash, new_hash = b87$new_hash, source = "087", stringsAsFactors = FALSE)
  if (!setequal(paste(i87$uuid, i87$old_hash, i87$new_hash), paste(m87$uuid, m87$old_hash, m87$new_hash)) ||
      !identical(b87$hash, b87$old_hash))
    .mig088_fail("087 BACKUP disagrees with 087's INPUT.")
  m <- rbind(m55, m87)
  for (s in names(.mig088_rehash_actor)) {
    cl <- DBI::dbGetQuery(con, "SELECT uuid_row, old, new FROM change_log WHERE actor = ? AND tbl = 'asset' AND field = 'hash'",
                          params = list(.mig088_rehash_actor[[s]]))
    ms <- m[m$source == s, ]
    if (!setequal(paste(cl$uuid_row, cl$old, cl$new), paste(ms$uuid, ms$old_hash, ms$new_hash)))
      .mig088_fail(sprintf("%s's change_log hash rows disagree with its BACKUP.", s))
  }
  m
}

# Plan every ingest_file row with uuid_asset NULL. Returns list(input, summary, skipped).
mig088_plan <- function(con, archive_dir, mig_dir = "dev/migrations") {
  m <- .mig088_rehash_map(con, mig_dir)
  f <- DBI::dbGetQuery(con, "SELECT * FROM ingest_file WHERE uuid_asset IS NULL ORDER BY hash")
  a <- DBI::dbGetQuery(con, "SELECT uuid, hash, filename FROM asset WHERE hash IS NOT NULL")
  linked <- DBI::dbGetQuery(con, "SELECT i.hash, i.uuid_asset, a.hash AS ahash FROM ingest_file i
                                  LEFT JOIN asset a ON a.uuid = i.uuid_asset WHERE i.uuid_asset IS NOT NULL")
  rows <- list()
  for (k in seq_len(nrow(f))) {
    h <- f$hash[[k]]
    ca <- a$uuid[a$hash == h]
    cb <- m[m$old_hash == h, , drop = FALSE]
    cand <- unique(c(ca, cb$uuid))
    if (!length(cand)) next
    src <- c(rep("a", length(ca)), cb$source)
    r <- list(hash = h, action = "link", source = NA_character_, uuid_asset = NA_character_, asset_hash = NA_character_,
              row_sha1 = .mig088_sha(f[k, , drop = FALSE]), note = NA_character_)
    if (length(cand) > 1L) {
      r$action <- "skip"; r$source <- paste(unique(src), collapse = "+")
      r$note <- sprintf("one hash, %d assets: %s", length(cand),
                        paste(sprintf("%s (%s)", substr(cand, 1, 8), src[match(cand, c(ca, cb$uuid))]), collapse = ", "))
      if (nrow(cb)) {
        st <- vapply(cb$uuid, function(u) { p <- file.path(archive_dir, u, a$filename[a$uuid == u][1]); as.character(file.size(p)) }, "")
        r$note <- sprintf("%s; as-received size %s, stored size of %s", r$note, f$size[[k]],
                          paste(sprintf("%s %s", substr(cb$uuid, 1, 8), st), collapse = ", "))
      }
      rows[[length(rows) + 1L]] <- r; next
    }
    u <- cand[[1]]
    r$uuid_asset <- u
    r$asset_hash <- a$hash[a$uuid == u]
    r$source <- src[[1]]
    if (r$source != "a") {
      if (!length(r$asset_hash) || !identical(r$asset_hash, cb$new_hash[cb$uuid == u])) {
        r$action <- "skip"; r$note <- sprintf("asset %s no longer holds %s's new hash", substr(u, 1, 8), r$source)
      } else if (!.mig088_ingested_from(con, u, h)) {
        r$action <- "skip"; r$note <- sprintf("asset %s has no ingest insert row with this source hash", substr(u, 1, 8))
      } else {
        fn <- a$filename[a$uuid == u]
        sz <- suppressWarnings(file.size(file.path(archive_dir, u, fn)))
        if (is.na(sz)) { r$action <- "skip"; r$note <- "stored copy missing" }
        else if (!is.na(f$size[[k]]) && as.numeric(f$size[[k]]) != sz)
          r$note <- sprintf("stored copy grew %s -> %s bytes after archiving (%s accepted it)", f$size[[k]], sz, r$source)
      }
    }
    if (r$action == "skip") { r$uuid_asset <- NA_character_; r$asset_hash <- NA_character_ }
    rows[[length(rows) + 1L]] <- r
  }
  x <- do.call(rbind, lapply(rows, as.data.frame, stringsAsFactors = FALSE))[, .mig088_cols]
  bad_linked <- linked[is.na(linked$ahash) | linked$ahash != linked$hash &
                         !paste(linked$hash, linked$uuid_asset) %in% paste(m$old_hash, m$uuid), , drop = FALSE]
  list(input = x, n_null = nrow(f), n_unlinkable = nrow(f) - nrow(x), already_linked = nrow(linked),
       already_linked_inconsistent = bad_linked)
}

mig088_freeze <- function(db, archive_dir, input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig088_plan(con, archive_dir, input_dir)
  if (nrow(p$already_linked_inconsistent)) .mig088_fail("an already-linked ingest_file row points elsewhere; resolve first.")
  utils::write.csv(p$input, file.path(input_dir, sprintf("%s-INPUT.csv", .mig088_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

# ---- run-time checks -------------------------------------------------------------------
# Per-row problems for link rows; named by hash. Names appear only for rows that fail.
.mig088_problems <- function(con, l) {
  out <- character(0)
  add <- function(h, msg) out[[h]] <<- if (h %in% names(out)) paste(out[[h]], msg, sep = "; ") else msg
  f <- DBI::dbGetQuery(con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s", .mig088_inlist(l$hash)))
  a <- DBI::dbGetQuery(con, sprintf("SELECT uuid, hash FROM asset WHERE uuid IN %s OR hash IN %s",
                                    .mig088_inlist(l$uuid_asset), .mig088_inlist(l$hash)))
  cl <- DBI::dbGetQuery(con, sprintf("SELECT actor, uuid_row, old, new FROM change_log WHERE tbl = 'asset' AND field = 'hash'
                                      AND action = 'update' AND actor IN %s", .mig088_inlist(unname(.mig088_rehash_actor))))
  for (i in seq_len(nrow(l))) {
    h <- l$hash[[i]]; u <- l$uuid_asset[[i]]; s <- l$source[[i]]
    fr <- f[f$hash == h, , drop = FALSE]
    if (nrow(fr) != 1L) { add(h, "ingest_file row missing"); next }
    if (!identical(.mig088_sha(fr), l$row_sha1[[i]])) add(h, "ingest_file row is not as frozen")
    if (!is.na(fr$uuid_asset[[1]]) && !identical(fr$uuid_asset[[1]], u)) add(h, sprintf("uuid_asset is already %s", fr$uuid_asset[[1]]))
    ar <- a[a$uuid == u, , drop = FALSE]
    if (nrow(ar) != 1L) { add(h, sprintf("asset %s missing", u)); next }
    if (!identical(ar$hash[[1]], l$asset_hash[[i]])) add(h, sprintf("asset %s hash is %s, expected %s", u, ar$hash[[1]], l$asset_hash[[i]]))
    holders <- a$uuid[a$hash %in% h]
    if (s == "a" && !identical(holders, u)) add(h, sprintf("%d assets hold this hash", length(holders)))
    if (s != "a") {
      if (length(holders)) add(h, sprintf("asset %s also holds the as-received hash", holders[[1]]))
      if (!.mig088_ingested_from(con, u, h)) add(h, sprintf("asset %s has no ingest insert row with this source hash", u))
      c1 <- cl[cl$old == h, , drop = FALSE]
      if (nrow(c1) != 1L || c1$actor[[1]] != .mig088_rehash_actor[[s]] || c1$uuid_row[[1]] != u ||
          c1$new[[1]] != l$asset_hash[[i]])
        add(h, sprintf("%s's change_log does not record asset %s leaving this hash", s, u))
    }
  }
  out
}

.mig088_done_problem <- function(con, l) {
  if (.mig088_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig088_marker_version) != 1L)
    return("marker 1088 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new, source_hash FROM change_log WHERE actor = ?",
                        params = list(.mig088_actor))
  if (nrow(cl) != 2L * nrow(l) || any(cl$tbl != "ingest_file") || any(cl$action != "update") || !all(is.na(cl$uuid_row)) ||
      !setequal(cl$field, c("uuid_asset", "updated_at")) || !all(table(cl$field) == nrow(l)))
    return(sprintf("088 change_log is %d row(s), not %d ingest_file uuid_asset + updated_at updates", nrow(cl), 2L * nrow(l)))
  u <- cl[cl$field == "uuid_asset", , drop = FALSE]
  if (!setequal(paste(u$source_hash, u$new), paste(l$hash, l$uuid_asset)) || !all(is.na(u$old)))
    return("088 change_log uuid_asset rows are not NA -> the planned asset per hash")
  f <- DBI::dbGetQuery(con, sprintf("SELECT hash, uuid_asset FROM ingest_file WHERE hash IN %s", .mig088_inlist(l$hash)))
  if (nrow(f) != nrow(l) || !setequal(paste(f$hash, f$uuid_asset), paste(l$hash, l$uuid_asset)))
    return("an ingest_file row does not carry its planned uuid_asset")
  NULL
}

.mig088_checksum <- function(con, l) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("ingest_file", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  h <- .mig088_inlist(l$hash)
  out$ingest_file_rest <- q(sprintf("SELECT * FROM ingest_file WHERE hash NOT IN %s ORDER BY hash", h))
  out$ingest_file_cols <- q(sprintf("SELECT * EXCLUDE (uuid_asset, updated_at) FROM ingest_file WHERE hash IN %s ORDER BY hash", h))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig088_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig088_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig088_checks_problem <- function(before, after) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], if (nrow(b)) b$keys[[1]] else character())
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

.mig088_apply <- function(con, l, recorded_at, logf) {
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig088_checksum(con, l)
    want <- .mig088_counts(con)
    want$change_log <- want$change_log + 2L * nrow(l)
    want$schema_version <- want$schema_version + 1L
    for (i in seq_len(nrow(l))) {
      db_update(con, "ingest_file", key = list(hash = l$hash[[i]]),
                changes = list(uuid_asset = l$uuid_asset[[i]], updated_at = recorded_at),
                actor = .mig088_actor, reason = .mig088_row_reason(l$source[[i]]), source_hash = l$hash[[i]])
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig088_marker_version, recorded_at))
    pr <- .mig088_done_problem(con, l)
    if (!is.null(pr)) .mig088_fail(paste0("verify failed: ", pr))
    got <- .mig088_counts(con)
    if (!identical(got, want))
      .mig088_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig088_checksum(con, l))) .mig088_fail("something outside the planned rows/columns moved.")
    mig_db_checks_gate(con, baseline)
    pr <- .mig088_checks_problem(before_all, db_checks(con, tier = "all"))
    if (!is.null(pr)) .mig088_fail(paste0("standing checks: ", pr))
    logf("Linked %d ingest_file row(s).", nrow(l))
    NULL
  })
  invisible(NULL)
}

mig088_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig088_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig088_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig088_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig088_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("088: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}
.mig088_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig088_name, what))

mig088_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig088_read_inputs(input_dir)
  l0 <- .mig088_links(x0)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig088_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig088_csv(csv_dir, "SKIPPED")
    skipped_h <- if (file.exists(sk)) utils::read.csv(sk, colClasses = "character", na.strings = "")$hash else character()
    l <- l0[!l0$hash %in% skipped_h, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig088_done_problem(check_con, l)
      if (!is.null(pr)) .mig088_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("088 already applied at %s; re-verified (%d links); nothing to do.", format(mine$applied_at[[1]]), nrow(l))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    if (.mig088_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig088_requires) == 0L)
      .mig088_fail(sprintf("marker %d is required first.", .mig088_requires))
    if (.mig088_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig088_actor) > 0L)
      .mig088_fail("change_log already holds 088 rows but the marker is absent; refusing.")
    list(problems = .mig088_problems(pre_con, l0),
         fn = DBI::dbGetQuery(pre_con, sprintf("SELECT hash, filename, state, state_reason, size FROM ingest_file WHERE hash IN %s",
                                               .mig088_inlist(x0$hash))))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  problems <- pre$problems
  frozen_skip <- x0[x0$action == "skip", , drop = FALSE]
  skipped <- rbind(
    data.frame(hash = frozen_skip$hash, source = frozen_skip$source, problem = paste("frozen skip:", frozen_skip$note),
               stringsAsFactors = FALSE),
    data.frame(hash = names(problems), source = l0$source[match(names(problems), l0$hash)], problem = unname(problems),
               stringsAsFactors = FALSE))
  m <- match(skipped$hash, pre$fn$hash)
  skipped$filename <- pre$fn$filename[m]; skipped$state <- pre$fn$state[m]; skipped$size <- pre$fn$size[m]
  l <- l0[!l0$hash %in% names(problems), , drop = FALSE]
  by_src <- table(factor(l$source, levels = .mig088_sources))
  logf("Plan: %d ingest_file row(s) linked (a: %d, 055: %d, 087: %d); %d skipped (%d frozen, %d by pre-flight).",
       nrow(l), by_src[["a"]], by_src[["055"]], by_src[["087"]], nrow(skipped), nrow(frozen_skip), length(problems))
  for (i in seq_len(nrow(skipped))) logf("SKIP %s [%s]: %s", skipped$hash[[i]], skipped$source[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA,
                          n_link = nrow(l), by_source = by_src, n_skipped = nrow(skipped))))
  }
  if (!nrow(l)) .mig088_fail("every row is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    b <- DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM ingest_file WHERE hash IN %s ORDER BY hash", .mig088_inlist(l$hash)))
    if (nrow(b) != nrow(l) || any(!is.na(b$uuid_asset))) .mig088_fail("backup: a planned row is missing or already linked.")
    b$new_uuid_asset <- l$uuid_asset[match(b$hash, l$hash)]
    b$source <- l$source[match(b$hash, l$hash)]
    .mig088_write_csv(b, .mig088_csv(csv_dir, "BACKUP-ingest_file"), "hash")
    .mig088_write_csv(skipped, .mig088_csv(csv_dir, "SKIPPED"), "hash")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups and SKIPPED written to %s", csv_dir)
  backup_path <- mig088_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    again <- .mig088_problems(con, l)
    if (length(again)) .mig088_fail("a precondition changed since the dry check; re-run.")
    .mig088_apply(con, l, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d ingest_file rows linked.", .mig088_name, .mig088_marker_version, nrow(l))
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, n_link = nrow(l), by_source = by_src, n_skipped = nrow(skipped)))
}
