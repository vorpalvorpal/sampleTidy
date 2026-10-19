# Historical corpus import (Robin's 5-step plan, 2026-10-19/20). Ingests every
# non-PDF file of a LOCAL copy of OneDrive assets/{processed,unprocessed} into DB,
# one ingest_dir() per source folder (processed/ flattened) and one per ACIRL
# workbook (chronological by name). Per-file and per-batch results go to
# <run_root>/out/run/. Called by dev/corpus-import/apply-corpus-import.sh; run
# from the repo root.
# Usage: Rscript dev/corpus-import/run-corpus.R <db> <run_root> <rehearsal|live> <src_dir>
#   rehearsal: archive_dir and snapshot_dir under <run_root> (db must be under it too)
#   live:      db must be st_config("live_db"); archive_dir = SAMPLETIDY_ARCHIVE_DIR
#              (Sharepoint assets/processed); snapshot_dir is local (<run_root>/snapshots)
# Skipped while staging (logged in stage_log.csv):
#   * byte-identical copies within a batch / of an earlier ACIRL workbook;
# Files already archived (src/processed/<asset uuid>/<name>) are NOT skipped: an
# unchanged file reuses its asset row (archive_file dedupes on hash), and the 18
# that SharePoint rewrote are re-hashed by migration 055 first, so none creates a
# second asset.
args <- commandArgs(trailingOnly = TRUE)
stopifnot(length(args) == 4)
suppressMessages(devtools::load_all(".", quiet = TRUE))
SRC <- normalizePath(args[[4]], mustWork = TRUE)
W <- normalizePath(args[[2]], mustWork = TRUE)
db <- normalizePath(args[[1]], mustWork = TRUE)
mode <- args[[3]]; stopifnot(mode %in% c("rehearsal", "live"))
LIVE <- normalizePath("~/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb")
label <- "run"
out <- file.path(W, "out", label); dir.create(out, recursive = TRUE, showWarnings = FALSE)
snapshot_dir <- file.path(W, "snapshots"); dir.create(snapshot_dir, showWarnings = FALSE)
if (mode == "rehearsal") {
  stopifnot(startsWith(db, W), db != LIVE)
  archive_dir <- file.path(W, "archive"); dir.create(archive_dir, showWarnings = FALSE)
} else {
  stopifnot(identical(db, LIVE))
  archive_dir <- normalizePath(Sys.getenv("SAMPLETIDY_ARCHIVE_DIR"), mustWork = TRUE)   # the normal live archive (Sharepoint processed)
  stopifnot(grepl("assets/processed$", archive_dir))
}
Sys.setenv(SAMPLETIDY_SNAPSHOT_DIR = snapshot_dir, SAMPLETIDY_ARCHIVE_DIR = archive_dir,
           SAMPLETIDY_INPUT_DIR = SRC)
st_config("live_db", db); st_config("archive_dir", archive_dir)
st_config("snapshot_dir", snapshot_dir); st_config("input_dir", SRC)
st_config("remove_ingested", FALSE)
for (k in c("live_db", "archive_dir", "snapshot_dir", "input_dir")) {
  v <- normalizePath(st_config(k), mustWork = FALSE); cat(sprintf("%-13s %s\n", k, v))
}
stopifnot(identical(normalizePath(st_config("live_db")), db), identical(st_config("remove_ingested"), FALSE))
if (mode == "rehearsal") for (k in c("archive_dir", "snapshot_dir")) stopifnot(startsWith(normalizePath(st_config(k)), W))
stopifnot(startsWith(normalizePath(st_config("snapshot_dir")), W))

# ---- stage batches -----------------------------------------------------------
src <- SRC
wk <- file.path(W, "work", label); unlink(wk, recursive = TRUE); dir.create(wk, recursive = TRUE)
all_f <- list.files(src, recursive = TRUE, full.names = TRUE)
is_acirl <- grepl("^(2400|24[0-9]{6})", basename(all_f)) & grepl("\\.(xls|xlsx)$", basename(all_f), ignore.case = TRUE)
rel <- sub(paste0("^", src, "/"), "", all_f)
group <- ifelse(startsWith(rel, "processed/"), "processed", dirname(rel))
group <- gsub("/", "_", group)
batches <- list(); log <- list()
note <- function(...) log[[length(log) + 1]] <<- data.frame(...)
seen_hash <- character(0)
# ALS-ish / other: one ingest_dir per source folder (processed/ flattened)
for (g in sort(unique(group[!is_acirl]))) {
  d <- file.path(wk, paste0("B_", g)); dir.create(d)
  idx <- which(!is_acirl & group == g)
  for (i in idx) {
    f <- all_f[i]; h <- hash_file(f); nm <- basename(f)
    dest <- file.path(d, nm)
    if (file.exists(dest)) {
      if (identical(hash_file(dest), h)) { note(file = rel[i], batch = g, action = "dup_same_content_skipped"); next }
      k <- 2; repeat { dest <- file.path(d, sprintf("%s__dup%d", nm, k)); if (!file.exists(dest)) break; k <- k + 1 }
      note(file = rel[i], batch = g, action = paste("name_collision_renamed", basename(dest)))
    }
    file.copy(f, dest, copy.date = TRUE)
  }
  batches[[paste0("B_", g)]] <- d
}
# ACIRL workbooks: one ingest_dir each, own work dir, chronological-ish by name
ai <- which(is_acirl); ai <- ai[order(basename(all_f[ai]), rel[ai])]
n <- 0
for (i in ai) {
  f <- all_f[i]; h <- hash_file(f)
  if (h %in% seen_hash) { note(file = rel[i], batch = "acirl", action = "dup_same_content_skipped"); next }
  seen_hash <- c(seen_hash, h); n <- n + 1
  d <- file.path(wk, sprintf("A%03d", n)); dir.create(d); file.copy(f, file.path(d, basename(f)), copy.date = TRUE)
  batches[[sprintf("A%03d", n)]] <- d
}
stage_log <- if (length(log)) do.call(rbind, log) else data.frame()
write.csv(stage_log, file.path(out, "stage_log.csv"), row.names = FALSE)
cat("batches:", length(batches), " (ACIRL one-file batches:", n, ")\n")

# ---- helpers ----------------------------------------------------------------
ro <- function(f) { con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE)); f(con) }
cnt <- function() ro(function(con) vapply(c("analysis", "sample", "project", "feature", "feature_alias", "review_queue", "ingest_file", "asset", "change_log"),
  function(t) DBI::dbGetQuery(con, sprintf('SELECT count(*) n FROM "%s"', t))$n, numeric(1)))
t0_all <- Sys.time()
perfile <- list(); perbatch <- list(); newrq_all <- list()
for (bn in names(batches)) {
  d <- batches[[bn]]; fp <- list.files(d, full.names = TRUE)
  if (!length(fp)) next
  hs <- vapply(fp, hash_file, character(1))
  c0 <- cnt(); rq0 <- ro(function(con) DBI::dbGetQuery(con, "select uuid from review_queue")$uuid)
  cl0 <- ro(function(con) DBI::dbGetQuery(con, "select count(*) n from change_log")$n)
  err <- NA_character_; tb <- NA_character_; msgs <- character(0); rep <- NULL
  t1 <- Sys.time()
  rep <- withCallingHandlers(
    tryCatch(withCallingHandlers(ingest_dir(d, db = db),
        error = function(e) tb <<- paste(utils::capture.output(print(sys.calls())), collapse = "\n")),
      error = function(e) { err <<- conditionMessage(e); NULL }),
    warning = function(w) { msgs <<- c(msgs, paste("WARN:", conditionMessage(w))); invokeRestart("muffleWarning") },
    message = function(m) { msgs <<- c(msgs, paste("MSG:", conditionMessage(m))); invokeRestart("muffleMessage") })
  secs <- as.numeric(difftime(Sys.time(), t1, units = "secs"))
  c1 <- cnt()
  new_rq <- ro(function(con) DBI::dbGetQuery(con, "select * from review_queue"))
  new_rq <- new_rq[!new_rq$uuid %in% rq0, ]
  files <- ro(function(con) DBI::dbGetQuery(con, sprintf(
    "SELECT hash, filename, state, state_reason, adapter, work_order FROM ingest_file WHERE hash IN (%s)",
    paste0("'", hs, "'", collapse = ","))))
  clnew <- ro(function(con) DBI::dbGetQuery(con, sprintf(
    "select source_hash, tbl, action, count(*) n from (select * from change_log order by \"at\" desc limit %d) group by all",
    as.integer(c1[["change_log"]] - cl0))))
  if (nrow(new_rq)) { new_rq$batch <- bn; newrq_all[[bn]] <- new_rq }
  fdf <- data.frame(batch = bn, file = basename(fp), hash = unname(hs), stringsAsFactors = FALSE)
  fdf <- merge(fdf, files[, c("hash", "state", "state_reason", "adapter", "work_order")], by = "hash", all.x = TRUE)
  fdf$review_items <- vapply(fdf$hash, function(h) {
    x <- new_rq[new_rq$source_hash %in% h, ]
    if (!nrow(x)) return("")
    tt <- table(paste0(x$kind, "/", ifelse(is.na(x$subkind), "-", x$subkind)))
    paste0(names(tt), "x", as.integer(tt), collapse = "; ")
  }, character(1))
  nf <- nrow(fdf)
  fdf$rows_new <- if (!is.null(rep) && nf == 1) rep$rows_new else NA
  fdf$rows_already_present <- if (!is.null(rep) && nf == 1) rep$rows_already_present else NA
  fdf$error <- err
  perfile[[bn]] <- fdf
  perbatch[[bn]] <- data.frame(batch = bn, n_files = nf, secs = round(secs, 1), error = err,
    n_events = if (!is.null(rep)) rep$n_events else NA, events_committed = if (!is.null(rep)) rep$n_events_committed else NA,
    events_failed = if (!is.null(rep)) rep$events_failed else NA,
    rows_new = if (!is.null(rep)) rep$rows_new else NA, rows_already = if (!is.null(rep)) rep$rows_already_present else NA,
    rows_superseded = if (!is.null(rep)) rep$rows_superseded else NA, rows_skipped = if (!is.null(rep)) rep$rows_skipped else NA,
    review_opened = if (!is.null(rep)) rep$review_items_opened else NA,
    d_analysis = c1[["analysis"]] - c0[["analysis"]], d_sample = c1[["sample"]] - c0[["sample"]],
    d_project = c1[["project"]] - c0[["project"]], d_feature = c1[["feature"]] - c0[["feature"]],
    d_rq = c1[["review_queue"]] - c0[["review_queue"]], n_msgs = length(msgs))
  cat(sprintf("[%s] %-34s files=%d %5.1fs new=%s already=%s rq+%d %s\n", format(Sys.time(), "%H:%M:%S"), bn, nf, secs,
      if (!is.null(rep)) rep$rows_new else "NA", if (!is.null(rep)) rep$rows_already_present else "NA",
      c1[["review_queue"]] - c0[["review_queue"]], if (!is.na(err)) paste("ERROR:", err) else ""))
  if (!is.na(err)) cat("  traceback:", substr(tb, 1, 1500), "\n")
  if (length(msgs)) writeLines(c(paste("==", bn), msgs), file.path(out, sprintf("msgs_%s.txt", bn)))
  saveRDS(list(rep = rep, err = err, tb = tb, msgs = msgs, clnew = clnew), file.path(out, sprintf("rep_%s.rds", bn)))
  # incremental saves so a crash loses nothing
  write.csv(do.call(rbind, perfile), file.path(out, "per_file.csv"), row.names = FALSE)
  write.csv(do.call(rbind, perbatch), file.path(out, "per_batch.csv"), row.names = FALSE)
  if (length(newrq_all)) saveRDS(do.call(rbind, newrq_all), file.path(out, "new_review.rds"))
}
cat("\nTOTAL elapsed (min):", round(as.numeric(difftime(Sys.time(), t0_all, units = "mins")), 1), "\n")
cat("final counts:\n"); print(cnt())
