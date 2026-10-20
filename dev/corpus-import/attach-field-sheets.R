# Attach the corpus's two scanned field-sheet PDFs as assets (2026-10-20).
#
# PLAN-20 R20-4 (Robin): every document received is kept and filed. The corpus
# import leaves two scanned ACIRL field-sheet PDFs as ingest_file
# 'quarantined' / 'unclaimed' with no asset: their names carry neither an
# ES####### token nor the ACIRL 2400-* shape, so .ig_retain_siblings()
# (R/ingest.R) never selects them. Ingest behaviour is deliberately NOT
# changed; this post-import step attaches each one explicitly.
#
# Filing follows what ingest already does for the same email's ACIRL report
# PDF: .ig_retain_siblings() files "2400-7538-06 2026 Quarterly Blaxland
# WMF.pdf" under its folder's ALS work order (ES2617789, whose parent is the
# report project 2400-7538-06), not under the report project itself (R-9.12;
# the legacy system did the same for 104 of 124 ACIRL assets). So each sheet is
# filed under its ALS work order, and the script refuses unless that work
# order's project row exists AND is a child of the report project.
#
# asset.type 'QA': a scanned field sheet is sampling-record evidence, the same
# kind as the chain of custody (_COC -> 'QA', R-15.36b), not chemistry data.
#
# Per file, in ONE with_db_write() + db_transaction():
#   archive_file()  copies it to <archive_dir>/<new asset uuid>/<basename>,
#                   writes the asset row (db_append -> change_log) and
#                   registers .st_on_rollback() to unlink the copy if the
#                   transaction rolls back (C4);
#   db_update(asset)        appends the note to comments;
#   db_update(ingest_file)  state 'archived', state_reason 'retained_sibling'
#                           (the terminal state ingest gives retained
#                           siblings) and uuid_asset.
#
# Refuses (exit 1, nothing written) if a file's hash is already an asset that
# is not this step's own finished attachment (reported), if the report or work
# order project is missing / not linked, if the ingest_file row is missing or
# in an unexpected state, or if the source file's hash does not match.
# Idempotent: a re-run finds every file done and has nothing to do.
#
# Usage: Rscript dev/corpus-import/attach-field-sheets.R <db> <archive_dir> <src_dir> [--apply]
#   <src_dir> is the corpus root (holds unprocessed/). Dry run by default.
# Run from the repo root.

args <- commandArgs(trailingOnly = TRUE)
apply <- "--apply" %in% args
args <- setdiff(args, "--apply")
if (length(args) != 3L) {
  stop("usage: Rscript dev/corpus-import/attach-field-sheets.R <db> <archive_dir> <src_dir> [--apply]")
}
suppressMessages(devtools::load_all(".", quiet = TRUE))
db <- normalizePath(args[[1]], mustWork = TRUE)
archive_dir <- normalizePath(args[[2]], mustWork = TRUE)   # archive_file() never creates it
src_dir <- normalizePath(args[[3]], mustWork = TRUE)
st_config("archive_dir", archive_dir)

ACTOR <- "attach-field-sheets (corpus import 2026-10-20; PLAN-20 R20-4)"
REASON <- "attach scanned field sheets (PLAN-20 R20-4)"
TYPE <- "QA"
SHEETS <- data.frame(
  rel = c("unprocessed/email-2026-08-03/jun/20. Quarterly 02-06.pdf",
          "unprocessed/email-2026-08-03/jul/23. WMF Monthly 20-07.pdf"),
  report = c("2400-7538-06", "2400-7538-07"),
  wo = c("ES2617789", "ES2623357"),
  stringsAsFactors = FALSE
)
note_for <- function(report, wo) sprintf(paste0(
  "2026-10-20 corpus import: scanned field sheets for %s / %s, received by email ",
  "2026-08-03 (Adriana); attached explicitly (PLAN-20 R20-4) because ingest does ",
  "not claim scanned sheets"), report, wo)

cat(sprintf("db           %s\narchive_dir  %s\nsrc_dir      %s\nmode         %s\n",
            db, archive_dir, src_dir, if (apply) "APPLY" else "dry run"))

q1 <- function(con, sql, ...) DBI::dbGetQuery(con, sql, params = list(...))

# Classify every sheet: "todo", "done", or a refusal message.
plan_sheets <- function(con) {
  out <- vector("list", nrow(SHEETS))
  for (i in seq_len(nrow(SHEETS))) {
    s <- SHEETS[i, ]
    path <- file.path(src_dir, s$rel)
    r <- list(path = path, report = s$report, wo = s$wo, note = note_for(s$report, s$wo),
              hash = NA_character_, uuid_project = NA_character_, status = NA_character_,
              uuid_asset = NA_character_)
    out[[i]] <- local({
      refuse <- function(msg) { r$status <- paste("REFUSE:", msg); r }
      if (!file.exists(path)) return(refuse(sprintf("source file not found: %s", path)))
      r$hash <- hash_file(path)
      rep_p <- q1(con, "SELECT uuid, type FROM project WHERE name = ?", s$report)
      if (nrow(rep_p) != 1L) return(refuse(sprintf("report project %s: %d rows", s$report, nrow(rep_p))))
      wo_p <- q1(con, "SELECT uuid, uuid_parent FROM project WHERE name = ?", s$wo)
      if (nrow(wo_p) != 1L) return(refuse(sprintf("work order project %s: %d rows", s$wo, nrow(wo_p))))
      if (!identical(wo_p$uuid_parent, rep_p$uuid)) {
        return(refuse(sprintf("%s is not a child of report project %s", s$wo, s$report)))
      }
      r$uuid_project <- wo_p$uuid
      ig <- q1(con, "SELECT filename, state, state_reason, uuid_asset FROM ingest_file WHERE hash = ?", r$hash)
      if (nrow(ig) != 1L) return(refuse(sprintf("no ingest_file row for hash %s", r$hash)))
      if (!identical(ig$filename, basename(path))) {
        return(refuse(sprintf("ingest_file %s is named '%s', not '%s'", r$hash, ig$filename, basename(path))))
      }
      a <- q1(con, paste("SELECT a.uuid, a.filename, a.comments, a.uuid_project, p.name project",
                         "FROM asset a LEFT JOIN project p ON p.uuid = a.uuid_project WHERE a.hash = ?"), r$hash)
      if (nrow(a) == 0L) {
        if (!(identical(ig$state, "quarantined") && identical(ig$state_reason, "unclaimed"))) {
          return(refuse(sprintf("ingest_file %s is %s/%s with no asset (expected quarantined/unclaimed)",
                                r$hash, ig$state, ig$state_reason)))
        }
        r$status <- "todo"
        return(r)
      }
      done <- nrow(a) == 1L && identical(a$uuid_project, r$uuid_project) &&
        !is.na(a$comments) && grepl(r$note, a$comments, fixed = TRUE) &&
        identical(ig$state, "archived") && identical(ig$state_reason, "retained_sibling") &&
        identical(ig$uuid_asset, a$uuid)
      if (done) {
        r$uuid_asset <- a$uuid
        r$status <- "done"
        return(r)
      }
      refuse(sprintf("hash %s is already an asset elsewhere: %s", r$hash,
                     paste(sprintf("%s '%s' (project %s)", a$uuid, a$filename, a$project), collapse = "; ")))
    })
  }
  do.call(rbind, lapply(out, as.data.frame, stringsAsFactors = FALSE))
}

show <- function(p) {
  print(p[, c("status", "report", "wo", "hash", "uuid_asset")], right = FALSE)
  cat(sprintf("  %s\n", basename(p$path)))
}

ro <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
plan <- plan_sheets(ro)
DBI::dbDisconnect(ro, shutdown = TRUE)
show(plan)
if (any(startsWith(plan$status, "REFUSE"))) {
  cat("REFUSED:\n", paste0("  ", plan$status[startsWith(plan$status, "REFUSE")], "\n"), sep = "")
  quit(save = "no", status = 1)
}
if (!any(plan$status == "todo")) {
  cat("nothing to do\n")
  quit(save = "no", status = 0)
}
if (!apply) {
  cat(sprintf("dry run - nothing written; %d to attach under %s (type %s)\n",
              sum(plan$status == "todo"), archive_dir, TYPE))
  quit(save = "no", status = 0)
}

# ---- apply: one transaction ------------------------------------------------
res <- with_db_write(function(con) {
  db_transaction(con, function(con) {
    p <- plan_sheets(con)   # re-plan under the write lock
    if (any(startsWith(p$status, "REFUSE"))) stop(paste(p$status, collapse = "\n"))
    for (i in which(p$status == "todo")) {
      uuid <- archive_file(con, p$path[[i]], p$hash[[i]], event = list(work_order = p$wo[[i]]), type = TYPE)
      a <- q1(con, "SELECT uuid_project, comments FROM asset WHERE uuid = ?", uuid)
      if (!identical(a$uuid_project, p$uuid_project[[i]])) stop(sprintf("asset %s filed under the wrong project", uuid))
      cur <- a$comments
      new <- if (is.na(cur) || !nzchar(cur)) p$note[[i]] else paste0(cur, "; ", p$note[[i]])
      db_update(con, "asset", uuid = uuid, changes = list(comments = new),
                actor = ACTOR, reason = REASON, source_hash = p$hash[[i]])
      db_update(con, "ingest_file", key = list(hash = p$hash[[i]]),
                changes = list(state = "archived", state_reason = "retained_sibling",
                               uuid_asset = uuid, updated_at = Sys.time()),
                actor = ACTOR, reason = REASON, source_hash = p$hash[[i]])
      dest <- file.path(archive_dir, uuid, basename(p$path[[i]]))
      if (!identical(hash_file(dest), p$hash[[i]])) stop(sprintf("archive copy %s does not hash to %s", dest, p$hash[[i]]))
      p$uuid_asset[[i]] <- uuid
      p$status[[i]] <- "attached"
    }
    p
  })
}, db = db)
show(res)
cat(sprintf("attached %d file(s)\n", sum(res$status == "attached")))
