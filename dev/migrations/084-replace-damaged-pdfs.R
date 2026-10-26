# Operator-run migration: replace three damaged archived PDFs with the intact originals
# saved from the delivery emails, and re-hash their asset rows. Marker 1084. Requires 1083.
#
# Authority: Robin, 2026-10-26 (approved replacing the three damaged PDFs).
#
# ---- WHY ------------------------------------------------------------------------------
# An archive integrity scan (2026-10-26) found three archived PDFs that do not parse: no
# %%EOF, qpdf "unable to find trailer dictionary" / "root of pages tree has no /Kids". Their
# asset.hash matches the damaged bytes, so they were damaged before they were hashed, i.e. on
# the way in (legacy loader; none has an ingest_file row). Against the email originals each
# stored copy is byte-identical up to an offset, then is the original's bit stream slipped by
# a few bits (the stored file's last 64 bytes occur in the original's bit stream at a bit
# offset that is not a multiple of 8), which is why each is 3-4 bytes short:
#   f8f0096e  Monthly 5-05.pdf      (ACIRL field sheet scan, May 2025 Blaxland monthly; under
#             ES2512915)  stored 8,181,423 B, original 8,181,426 B, identical first 8,144,374 B;
#             original 5 pages, qpdf clean.
#   baadda76  ES2512915_0_COA.pdf   (ALS COA, ES2512915)  stored 831,849 B, original 831,853 B,
#             identical first 503,718 B; original 4 pages; qpdf: one warning, "dictionary has
#             duplicated key /Reference", which every archived ALS COA carries (ALS's producer),
#             no damage.
#   ed2c1409  ES2602084_0_QC.pdf    (ALS QC report, ES2602084)  stored 736,302 B, original
#             736,305 B, identical first 98,977 B; original 8 pages, qpdf clean.
# Sources (Outlook, read-only `ow save`): the first two are attachments of "Blaxland Report
# April" (ALS, 2025-05-21 10:55), the email that also carries ES2512915's XTAB/ENMRG and the
# 2400-7453-05 report; the QC report is an attachment of "RESULTS & EDD for ALS Workorder :
# ES2602084" (2026-01-30 15:25). (The 2026-02-11 "EDD for ALS Workorder : ES2602084" email
# carries only the XTAB.) Same file name, same leading bytes, and page 1 names the work order.
#
# ---- WHAT (frozen in 084-replace-damaged-pdfs-INPUT.csv) ---------------------------------
# Per asset (G1-G3): processed/<uuid>/<filename> is replaced by the original (written to a
# temp name in the same folder, then renamed into place, then re-hashed); asset.hash <- the
# original's rlang::hash_file() (xxHash128, as archive_file()); a 084 note (old hash, damage)
# is appended to asset.comments. No other column records these files' size or hash: they
# have no ingest_file / ingest_sighting / review_queue / sample_lab_id row; change_log keeps
# its history. G3 only: ES2602084's lab_qc_report row 70c012a5 is "unreadable" (PDF parsing
# failure, from 082's re-parse of the damaged file); it is re-parsed from the replaced file
# with lab_qc_reparse() (as 082), which must give what the other 109 QC reports hold:
# status "partial", "QC.pdf not parsed yet (PLAN-19 phase 3)", no outliers.
#
# ---- CHECKS ---------------------------------------------------------------------------
# Pre-flight: row sha1 of the three asset rows and the report row as frozen; asset.hash =
# old hash; no asset / ingest_file / ingest_sighting row holds a new hash; each original
# (dev/migrations/084-replace-damaged-pdfs-ORIGINALS/<uuid>/<filename>, untracked) has the
# frozen size and new hash, passes `qpdf --check` (exit 0, or 3 with only the duplicated-key
# warning) and shares the frozen leading bytes with the stored file; the stored file hashes
# to the old hash (or, after an interrupted run, already to the new one). Files: the old file
# is copied to dev/migrations/084-replace-damaged-pdfs-OLDFILES/<uuid>/<filename> (untracked)
# and verified before anything is written; the DB is snapshotted; files are swapped; then ONE
# transaction: db_checks baseline, whole-table checksums of everything else, counts,
# mig_db_checks_gate(), no all-tier check gains an offender. If the transaction fails, the
# old files are put back (temp + rename, re-verified). BACKUP CSVs (asset, lab_qc_report,
# lab_qc_outlier, files) and SKIPPED, untracked. Allowed: change_log_dangling_source_hash may
# gain the replaced files' old hashes (082's provenance rows for the damaged QC.pdf). Idempotent: marker present -> re-verify DB and
# file hashes, no-op.
#
#   Rscript dev/migrations/apply-084-replace-damaged-pdfs.R

.mig084_marker_version <- 1084L
.mig084_requires <- 1083L
.mig084_name <- "084-replace-damaged-pdfs"
.mig084_actor <- .mig084_name
.mig084_reason <- "084 (Robin 2026-10-26: damaged archived PDF replaced by the intact email original)"
.mig084_cols <- c("gid", "op", "tbl", "id", "label", "from_value", "to_value", "new_size", "prefix_bytes", "row_sha1")
.mig084_pk <- c(asset = "uuid", lab_qc_report = "uuid")
.mig084_qc_status <- "partial"
.mig084_qc_message <- "QC.pdf not parsed yet (PLAN-19 phase 3)"
.mig084_qpdf_ok_warning <- "dictionary has duplicated key /Reference"

.mig084_plan_rows <- data.frame(
  gid = c("G1", "G2", "G3", "G3"),
  op = c("replace_file", "replace_file", "replace_file", "reparse"),
  tbl = c("asset", "asset", "asset", "lab_qc_report"),
  id = c("f8f0096e-3ba7-47ef-974b-e73489b69959", "baadda76-20ef-422c-8a27-fd3751541712",
         "ed2c1409-db04-4414-a348-93f5867fd1d1", "70c012a5-d22c-44ed-b2e2-517fba61f05e"),
  label = c("Monthly 5-05.pdf", "ES2512915_0_COA.pdf", "ES2602084_0_QC.pdf", "ES2602084 QC report"),
  from_value = c("829e8c3aadab2d5c1d33ad93907560dd", "d606accdbde4d300b6da917bcb31d36c",
                 "26add24a9834c50ad565bd128f3a28d9", "unreadable"),
  to_value = c("b986a29f30596958c6a434b7c7034815", "90326863f18e7383d89e12b9f0d44d53",
               "65dc5ef611d3f3b9724772acc6162447", "partial"),
  new_size = c("8181426", "831853", "736305", NA),
  prefix_bytes = c("8144374", "503718", "98977", NA),
  stringsAsFactors = FALSE)

.mig084_damage <- c(G1 = "stored copy 8181423 B, identical to the original only for its first 8144374 B",
                    G2 = "stored copy 831849 B, identical to the original only for its first 503718 B",
                    G3 = "stored copy 736302 B, identical to the original only for its first 98977 B")
.mig084_source <- c(G1 = "email \"Blaxland Report April\" (ALS, 2025-05-21)",
                    G2 = "email \"Blaxland Report April\" (ALS, 2025-05-21)",
                    G3 = "email \"RESULTS & EDD for ALS Workorder : ES2602084\" (ALS, 2026-01-30)")
.mig084_note <- function(gid, old_hash) {
  paste0("2026-10-26 084: archived file replaced by the intact original from the ", .mig084_source[[gid]],
         "; the archived copy was damaged before hashing (", .mig084_damage[[gid]],
         ", then bit-slipped; no %%EOF); hash was ", old_hash, " (Robin, 2026-10-26)")
}

.mig084_fail <- function(msg) cli::cli_abort(paste0(.mig084_name, ": ", msg), class = "sampletidy_error")
.mig084_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig084_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig084_append <- function(old, note) if (is.na(old) || !nzchar(trimws(old))) note else paste0(old, "; ", note)
.mig084_hash <- function(path) if (file.exists(path)) rlang::hash_file(path) else NA_character_

# ---- rows, sha1 -------------------------------------------------------------------------

.mig084_row <- function(con, tbl, id) {
  DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" = ?', tbl, .mig084_pk[[tbl]]), params = list(id))
}

.mig084_sha <- function(df) {
  if (nrow(df) != 1L) return(NA_character_)
  cols <- names(df)
  v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][1]); if (is.na(s)) "<NA>" else s }, "")
  digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
}

# ---- files ------------------------------------------------------------------------------

.mig084_files <- function(x, archive_dir, input_dir) {
  a <- x[x$op == "replace_file", , drop = FALSE]
  data.frame(gid = a$gid, id = a$id, label = a$label, old = a$from_value, new = a$to_value,
             size = as.numeric(a$new_size), prefix = as.numeric(a$prefix_bytes),
             stored = file.path(archive_dir, a$id, a$label),
             original = file.path(input_dir, paste0(.mig084_name, "-ORIGINALS"), a$id, a$label),
             oldcopy = file.path(input_dir, paste0(.mig084_name, "-OLDFILES"), a$id, a$label),
             stringsAsFactors = FALSE)
}

.mig084_qpdf_problem <- function(path) {
  out <- suppressWarnings(system2("qpdf", c("--check", shQuote(path)), stdout = TRUE, stderr = TRUE))
  st <- attr(out, "status"); if (is.null(st)) st <- 0L
  if (st == 0L) return(NULL)
  w <- grep("^WARNING", out, value = TRUE)
  if (st == 3L && length(w) && all(grepl(.mig084_qpdf_ok_warning, w, fixed = TRUE))) return(NULL)
  sprintf("qpdf --check exit %d: %s", st, paste(utils::head(c(w, out), 2), collapse = " | "))
}

.mig084_same_prefix <- function(a, b, n) {
  ca <- file(a, "rb"); on.exit(close(ca), add = TRUE)
  cb <- file(b, "rb"); on.exit(close(cb), add = TRUE)
  identical(readBin(ca, "raw", n), readBin(cb, "raw", n))
}

# Copy `from` over `to` through a temp name in to's folder; verify the result's hash.
.mig084_swap <- function(from, to, want) {
  tmp <- file.path(dirname(to), paste0(".", basename(to), ".084tmp"))
  if (file.exists(tmp)) unlink(tmp)
  if (!isTRUE(file.copy(from, tmp, overwrite = FALSE, copy.date = FALSE)))
    .mig084_fail(sprintf("could not write %s", tmp))
  if (!identical(.mig084_hash(tmp), want)) { unlink(tmp); .mig084_fail(sprintf("temp copy %s does not hash to %s", tmp, want)) }
  if (!isTRUE(file.rename(tmp, to))) { unlink(tmp); .mig084_fail(sprintf("could not rename %s into place", tmp)) }
  got <- .mig084_hash(to)
  if (!identical(got, want)) .mig084_fail(sprintf("%s hashes to %s after the swap, not %s", to, got, want))
  invisible(TRUE)
}

# ---- plan, freeze, inputs ----------------------------------------------------------------

mig084_plan_con <- function(con) {
  x <- .mig084_plan_rows
  x$row_sha1 <- vapply(seq_len(nrow(x)), function(i) .mig084_sha(.mig084_row(con, x$tbl[[i]], x$id[[i]])), "")
  if (anyNA(x$row_sha1)) .mig084_fail(sprintf("row(s) missing at freeze: %s", paste(x$id[is.na(x$row_sha1)], collapse = ", ")))
  x[, .mig084_cols]
}

mig084_freeze <- function(db, archive_dir = st_config("archive_dir"), input_dir = "dev/migrations") {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  p <- mig084_plan_con(con)
  pr <- .mig084_problems(con, p, archive_dir, input_dir)
  if (length(pr)) .mig084_fail(sprintf("plan does not hold at freeze: %s", paste(names(pr), unlist(pr), collapse = "; ")))
  utils::write.csv(p, file.path(input_dir, sprintf("%s-INPUT.csv", .mig084_name)), row.names = FALSE, na = "",
                   fileEncoding = "UTF-8")
  invisible(p)
}

.mig084_read_inputs <- function(input_dir = "dev/migrations") {
  p <- file.path(input_dir, sprintf("%s-INPUT.csv", .mig084_name))
  if (!file.exists(p)) .mig084_fail(sprintf("input %s not found.", p))
  x <- utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  if (!identical(names(x), .mig084_cols)) .mig084_fail("INPUT columns are not as planned.")
  if (anyNA(x$row_sha1) || anyDuplicated(paste(x$tbl, x$id))) .mig084_fail("INPUT misses or repeats a row.")
  pl <- x[, setdiff(.mig084_cols, "row_sha1")]
  rownames(pl) <- NULL
  if (!identical(pl, .mig084_plan_rows)) .mig084_fail("INPUT does not match Robin's ruling.")
  x
}

# ---- preconditions -----------------------------------------------------------------------

# Named list gid -> problems.
.mig084_problems <- function(con, x, archive_dir, input_dir) {
  have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
  miss <- setdiff(.mig084_requires, have)
  if (length(miss)) .mig084_fail(sprintf("marker(s) %s required first.", paste(miss, collapse = ", ")))
  pr <- list()
  add <- function(g, m) pr[[g]] <<- c(pr[[g]], m)
  for (i in seq_len(nrow(x))) {
    s <- .mig084_sha(.mig084_row(con, x$tbl[[i]], x$id[[i]]))
    if (is.na(s) || s != x$row_sha1[[i]]) add(x$gid[[i]], sprintf("%s %s missing or not as frozen", x$tbl[[i]], x$id[[i]]))
  }
  f <- .mig084_files(x, archive_dir, input_dir)
  for (k in seq_len(nrow(f))) {
    r <- f[k, , drop = FALSE]; g <- r$gid
    a <- DBI::dbGetQuery(con, "SELECT hash, filename FROM asset WHERE uuid = ?", params = list(r$id))
    if (nrow(a) != 1L || !identical(a$hash[[1]], r$old) || !identical(a$filename[[1]], r$label))
      add(g, sprintf("asset %s hash/filename not as planned", r$id))
    for (t in c("asset", "ingest_file", "ingest_sighting"))
      if (.mig084_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE hash = ?', t), r$new) > 0L)
        add(g, sprintf("%s already holds the new hash %s", t, r$new))
    for (t in c("ingest_file", "ingest_sighting"))
      if (.mig084_scalar(con, sprintf('SELECT COUNT(*) FROM "%s" WHERE hash = ?', t), r$old) > 0L)
        add(g, sprintf("%s holds the old hash %s (not planned)", t, r$old))
    if (!file.exists(r$original)) { add(g, sprintf("original %s missing", r$original)); next }
    if (!identical(file.size(r$original), r$size)) add(g, sprintf("original %s is not %.0f B", r$label, r$size))
    if (!identical(.mig084_hash(r$original), r$new)) add(g, sprintf("original %s does not hash to %s", r$label, r$new))
    qp <- .mig084_qpdf_problem(r$original)
    if (!is.null(qp)) add(g, sprintf("original %s: %s", r$label, qp))
    if (!file.exists(r$stored)) { add(g, sprintf("stored file %s missing", r$stored)); next }
    sh <- .mig084_hash(r$stored)
    if (identical(sh, r$old)) {
      if (!.mig084_same_prefix(r$stored, r$original, r$prefix))
        add(g, sprintf("stored %s does not share the frozen %.0f leading bytes with the original", r$label, r$prefix))
    } else if (!identical(sh, r$new)) {
      add(g, sprintf("stored %s hashes to %s: neither the old nor the new hash", r$label, sh))
    }
  }
  qc <- x[x$op == "reparse", , drop = FALSE]
  for (k in seq_len(nrow(qc))) {
    rr <- DBI::dbGetQuery(con, "SELECT uuid_asset, kind, status FROM lab_qc_report WHERE uuid = ?", params = list(qc$id[[k]]))
    asset_id <- x$id[x$gid == qc$gid[[k]] & x$op == "replace_file"]
    if (nrow(rr) != 1L || !identical(rr$uuid_asset[[1]], asset_id) || !identical(rr$kind[[1]], "QC") ||
        !identical(rr$status[[1]], qc$from_value[[k]]))
      add(qc$gid[[k]], sprintf("lab_qc_report %s not the asset's unreadable QC row", qc$id[[k]]))
    if (.mig084_scalar(con, "SELECT COUNT(*) FROM lab_qc_report WHERE uuid_asset = ?", asset_id) != 1L)
      add(qc$gid[[k]], "asset has more than one lab_qc_report row")
    if (.mig084_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier WHERE uuid_report = ?", qc$id[[k]]) != 0L)
      add(qc$gid[[k]], "the unreadable report has outlier rows")
  }
  pr
}

.mig084_skipped_df <- function(pr) {
  if (!length(pr)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  data.frame(gid = names(pr), problem = vapply(pr, function(p) paste(unique(p), collapse = "; "), ""),
             stringsAsFactors = FALSE)
}

# ---- verify ------------------------------------------------------------------------------

.mig084_done_problem <- function(con, x, archive_dir, input_dir) {
  if (.mig084_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig084_marker_version) != 1L)
    return("marker 1084 missing")
  f <- .mig084_files(x, archive_dir, input_dir)
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row, field, old, new FROM change_log WHERE actor = ?",
                       params = list(.mig084_actor))
  La <- L[L$tbl == "asset", , drop = FALSE]
  if (nrow(La) != 2L * nrow(f)) return(sprintf("084 asset change_log has %d row(s), not %d", nrow(La), 2L * nrow(f)))
  for (k in seq_len(nrow(f))) {
    r <- f[k, , drop = FALSE]
    a <- DBI::dbGetQuery(con, "SELECT hash, comments FROM asset WHERE uuid = ?", params = list(r$id))
    if (nrow(a) != 1L || !identical(a$hash[[1]], r$new)) return(sprintf("asset %s hash is not %s", r$id, r$new))
    lh <- La[La$uuid_row %in% r$id & La$field %in% "hash", , drop = FALSE]
    lc <- La[La$uuid_row %in% r$id & La$field %in% "comments", , drop = FALSE]
    if (nrow(lh) != 1L || nrow(lc) != 1L) return(sprintf("asset %s change_log rows not as planned", r$id))
    if (!identical(lh$old[[1]], r$old) || !identical(lh$new[[1]], r$new)) return(sprintf("asset %s hash change_log not as planned", r$id))
    if (!identical(a$comments[[1]], .mig084_append(lc$old[[1]], .mig084_note(r$gid, r$old))) || !identical(lc$new[[1]], a$comments[[1]]))
      return(sprintf("asset %s comments are not the old text plus the 084 note", r$id))
    h <- .mig084_hash(r$stored)
    if (!identical(h, r$new)) return(sprintf("archived %s hashes to %s, not %s", r$label, h, r$new))
  }
  qc <- x[x$op == "reparse", , drop = FALSE]
  for (k in seq_len(nrow(qc))) {
    asset_id <- x$id[x$gid == qc$gid[[k]] & x$op == "replace_file"]
    if (.mig084_scalar(con, "SELECT COUNT(*) FROM lab_qc_report WHERE uuid = ?", qc$id[[k]]) != 0L)
      return(sprintf("old lab_qc_report %s still present", qc$id[[k]]))
    rr <- DBI::dbGetQuery(con, "SELECT uuid, kind, status, message FROM lab_qc_report WHERE uuid_asset = ?", params = list(asset_id))
    if (nrow(rr) != 1L || !identical(rr$kind[[1]], "QC") || !identical(rr$status[[1]], .mig084_qc_status) ||
        !identical(rr$message[[1]], .mig084_qc_message))
      return(sprintf("asset %s lab_qc_report is not one QC row '%s'", asset_id, .mig084_qc_status))
    if (.mig084_scalar(con, "SELECT COUNT(*) FROM lab_qc_outlier WHERE uuid_report = ?", rr$uuid[[1]]) != 0L)
      return("re-parsed QC report has outlier rows")
    lq <- L[L$tbl == "lab_qc_report", , drop = FALSE]
    if (sum(lq$action == "delete" & lq$uuid_row == qc$id[[k]]) != 1L || sum(lq$action == "insert" & lq$uuid_row == rr$uuid[[1]]) != 1L)
      return("lab_qc_report change_log rows not as planned")
  }
  if (nrow(L) != nrow(La) + 2L * nrow(qc)) return(sprintf("084 change_log has %d row(s), not %d", nrow(L), nrow(La) + 2L * nrow(qc)))
  NULL
}

.mig084_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "lab_method", "analyte", "asset", "ingest_file", "ingest_sighting",
            "project", "review_queue", "lab_qc_report", "lab_qc_outlier", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig084_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig084_checksum <- function(con, x) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("asset", "lab_qc_report", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  ids <- x$id[x$op == "replace_file"]
  out$asset_rest <- q(sprintf("SELECT * FROM asset WHERE uuid NOT IN %s ORDER BY ALL", .mig084_inlist(ids)))
  out$asset_cols <- q(sprintf("SELECT * EXCLUDE (hash, comments) FROM asset WHERE uuid IN %s ORDER BY uuid", .mig084_inlist(ids)))
  qa <- x$id[x$op == "replace_file" & x$gid %in% x$gid[x$op == "reparse"]]
  out$lab_qc_report_rest <- q(sprintf("SELECT * FROM lab_qc_report WHERE uuid_asset NOT IN %s ORDER BY ALL", .mig084_inlist(qa)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig084_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig084_marker_version))
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

# `allow`: check name -> offender keys that may appear. The only one: change_log rows written
# from a damaged file (082's parse of ES2602084_0_QC.pdf) keep that file's old hash as their
# provenance, and no file has it once the original is in place. change_log is history, so it
# is not rewritten; the asset's 084 note names the old hash.
.mig084_checks_problem <- function(before, after, allow = list()) {
  for (i in seq_len(nrow(after))) {
    nm <- after$name[[i]]
    b <- before[before$name == nm, , drop = FALSE]
    if (after$status[[i]] == "error") {
      if (!nrow(b) || b$status[[1]] != "error") return(sprintf("check %s now errors: %s", nm, after$message[[i]]))
      next
    }
    added <- setdiff(after$keys[[i]], c(if (nrow(b)) b$keys[[1]] else character(), allow[[nm]]))
    if (length(added)) return(sprintf("check %s gains offender(s) %s", nm, paste(utils::head(added, 3), collapse = ", ")))
  }
  NULL
}

# ---- apply -------------------------------------------------------------------------------

.mig084_apply <- function(con, x, f, recorded_at, logf) {
  qc <- x[x$op == "reparse", , drop = FALSE]
  db_transaction(con, function(con) {
    baseline <- db_checks(con, tier = "migration")
    before_all <- db_checks(con, tier = "all")
    sums_before <- .mig084_checksum(con, x)
    want <- .mig084_counts(con)
    want$change_log <- want$change_log + 2L * nrow(f) + 2L * nrow(qc)
    want$schema_version <- want$schema_version + 1L
    for (k in seq_len(nrow(f))) {
      r <- f[k, , drop = FALSE]
      old <- DBI::dbGetQuery(con, "SELECT comments FROM asset WHERE uuid = ?", params = list(r$id))
      db_update(con, "asset", uuid = r$id,
                changes = list(hash = r$new, comments = .mig084_append(old$comments[[1]], .mig084_note(r$gid, r$old))),
                actor = .mig084_actor, reason = sprintf("%s [%s]", .mig084_reason, r$gid), source_hash = r$new)
    }
    for (k in seq_len(nrow(qc))) {
      r <- f[f$gid == qc$gid[[k]], , drop = FALSE]
      st <- lab_qc_reparse(con, r$id, path = r$stored, actor = .mig084_actor)
      if (!identical(st, .mig084_qc_status)) .mig084_fail(sprintf("re-parse of %s gave status %s", r$label, format(st)))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig084_marker_version, recorded_at))
    pr <- .mig084_done_problem(con, x, attr(f, "archive_dir"), attr(f, "input_dir"))
    if (!is.null(pr)) .mig084_fail(paste0("verify failed: ", pr))
    got <- .mig084_counts(con)
    if (!identical(got, want))
      .mig084_fail(sprintf("table counts are not as planned: %s",
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig084_checksum(con, x))) .mig084_fail("something outside the planned rows moved.")
    mig_db_checks_gate(con, baseline)
    after_all <- db_checks(con, tier = "all")
    pr <- .mig084_checks_problem(before_all, after_all, allow = list(change_log_dangling_source_hash = f$old))
    if (!is.null(pr)) .mig084_fail(paste0("standing checks: ", pr))
    logf("Re-hashed %d asset(s); re-parsed %d QC report(s).", nrow(f), nrow(qc))
    NULL
  })
  invisible(NULL)
}

# ---- backups ------------------------------------------------------------------------------

mig084_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig084_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig084_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig084_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig084_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("084: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig084_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig084_name, what))

.mig084_read_skipped <- function(csv_dir) {
  f <- .mig084_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
}

# BACKUP CSVs: the asset rows (old hash), the QC report row and its (zero) outlier rows; plus
# a FILES CSV of old/new hash and size per file.
.mig084_write_backups <- function(con, x, f, csv_dir) {
  ids <- list(asset = x$id[x$op == "replace_file"], lab_qc_report = x$id[x$op == "reparse"])
  for (tb in names(ids)) {
    df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE "%s" IN %s ORDER BY 1', tb, .mig084_pk[[tb]], .mig084_inlist(ids[[tb]])))
    .mig084_write_csv(df, .mig084_csv(csv_dir, paste0("BACKUP-", tb)), .mig084_pk[[tb]])
  }
  o <- DBI::dbGetQuery(con, sprintf("SELECT * FROM lab_qc_outlier WHERE uuid_report IN %s ORDER BY 1", .mig084_inlist(ids$lab_qc_report)))
  .mig084_write_csv(o, .mig084_csv(csv_dir, "BACKUP-lab_qc_outlier"), "uuid")
  fl <- data.frame(gid = f$gid, uuid_asset = f$id, filename = f$label, old_hash = f$old,
                   old_size = vapply(f$stored, function(p) as.character(file.size(p)), ""),
                   new_hash = f$new, new_size = format(f$size, scientific = FALSE),
                   old_copy = f$oldcopy, stringsAsFactors = FALSE)
  .mig084_write_csv(fl, .mig084_csv(csv_dir, "BACKUP-files"), "uuid_asset")
}

# Old file -> OLDFILES (verified) before anything is written; an existing verified copy is kept.
.mig084_backup_files <- function(f) {
  for (k in seq_len(nrow(f))) {
    r <- f[k, , drop = FALSE]
    if (identical(.mig084_hash(r$oldcopy), r$old)) next
    if (!identical(.mig084_hash(r$stored), r$old)) .mig084_fail(sprintf("stored %s is not the old file; no old-file backup to take", r$label))
    dir.create(dirname(r$oldcopy), recursive = TRUE, showWarnings = FALSE)
    if (!isTRUE(file.copy(r$stored, r$oldcopy, overwrite = TRUE, copy.date = TRUE)) || !identical(.mig084_hash(r$oldcopy), r$old))
      .mig084_fail(sprintf("old-file backup of %s failed", r$label))
  }
}

.mig084_restore_files <- function(f, logf) {
  for (k in seq_len(nrow(f))) {
    r <- f[k, , drop = FALSE]
    if (identical(.mig084_hash(r$stored), r$old)) next
    tryCatch({ .mig084_swap(r$oldcopy, r$stored, r$old); logf("restored the old %s", r$label) },
             error = function(e) logf("COULD NOT RESTORE %s from %s: %s", r$stored, r$oldcopy, conditionMessage(e)))
  }
}

# ---- run ---------------------------------------------------------------------------------

mig084_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations",
                       archive_dir = st_config("archive_dir")) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x0 <- .mig084_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig084_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig084_read_skipped(csv_dir)
    if (is.null(sk)) .mig084_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig084_csv(csv_dir, "SKIPPED")))
    x <- x0[!x0$gid %in% sk$gid, , drop = FALSE]
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      pr <- .mig084_done_problem(check_con, x, archive_dir, input_dir)
      if (!is.null(pr)) .mig084_fail(paste0("re-verify: ", pr))
    }, finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("084 already applied at %s; re-verified (DB and file hashes); nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  problems <- tryCatch({
    if (.mig084_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig084_actor) > 0L)
      .mig084_fail("change_log already holds 084 rows but the marker is absent; refusing.")
    .mig084_problems(pre_con, x0, archive_dir, input_dir)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  skipped <- .mig084_skipped_df(problems)
  x <- x0[!x0$gid %in% skipped$gid, , drop = FALSE]
  f <- .mig084_files(x, archive_dir, input_dir)
  attr(f, "archive_dir") <- archive_dir
  attr(f, "input_dir") <- input_dir
  logf("Plan: %d group(s) of %d; %d skipped.", length(unique(x$gid)), length(unique(x0$gid)), nrow(skipped))
  for (i in seq_len(nrow(x))) logf("  %s %s %s %s: %s -> %s", x$gid[[i]], x$op[[i]], x$tbl[[i]], x$label[[i]],
                                   x$from_value[[i]], x$to_value[[i]])
  for (i in seq_len(nrow(skipped))) logf("SKIP %s: %s", skipped$gid[[i]], skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition checked (files hashed, qpdf run). No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }
  if (!nrow(f)) .mig084_fail("every group is skipped; nothing to do (no marker written).")

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig084_backup_files(f)
    .mig084_write_backups(bk_con, x, f, csv_dir)
    .mig084_write_csv(skipped, .mig084_csv(csv_dir, "SKIPPED"), "gid")
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Old files backed up to %s; row backups and the SKIPPED plan written to %s",
       dirname(dirname(f$oldcopy[[1]])), csv_dir)
  backup_path <- mig084_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s (and copy each OLDFILES file back)", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  tryCatch({
    for (k in seq_len(nrow(f))) {
      if (identical(.mig084_hash(f$stored[[k]]), f$new[[k]])) next
      .mig084_swap(f$original[[k]], f$stored[[k]], f$new[[k]])
      logf("  %s %s replaced; hash verified %s", f$gid[[k]], f$label[[k]], f$new[[k]])
    }
    with_db_write(function(con) {
      again <- .mig084_problems(con, x, archive_dir, input_dir)
      if (length(again)) .mig084_fail("a precondition changed since the dry check; re-run.")
      .mig084_apply(con, x, f, recorded_at, logf)
    }, db = db)
  }, error = function(e) {
    logf("FAILED: %s -- putting the old files back.", conditionMessage(e))
    .mig084_restore_files(f, logf)
    stop(e)
  })

  logf("%s migrated successfully (marker %d).", .mig084_name, .mig084_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at))
}
