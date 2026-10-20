# Post-import review actions for the historical corpus import (2026-10-20).
#
# Acts on the review items the corpus import opened, per Robin's accepted
# recommendations in TRIAGE.md "Decisions for Robin" (PHASE 2, 2026-10-20):
#   D4  2400-7399-04 April 2024 stale Sampling Sites 2-4 (dated 2024-02-19):
#       drop - dismiss the items those sheets raised (their rows were never
#       committed: the file's 8 new rows are sheet 1 / dust, 2024-04-18/04-01).
#       There is no per-sheet exclusion mechanism in the package, and a C3
#       date override would RE-date the rows, which is the opposite of the
#       ruling, so dismissal after import is the clean route.
#   D5  2400-7399-12 blank "Date of Sample" (21 parse_error/datetime items):
#       PARKED. TRIAGE assumed 2024-12-04, but Excel serial 45629 is
#       2024-12-03, and ES2439599 (ENMRG "Sample date: 03/12/2024", P0 and F2)
#       is 3 Dec 2024, so the brief's condition "confirm 4 Dec" fails. The
#       items also carry no withheld rows (payload$rows is absent), so
#       release_review() cannot release them; a re-ingest is needed instead.
#   D6  A77 dust in 2400-7399-12 and 2400-7453-06 (4 items, absent from live):
#       release_review() at the payload's own exposure/collection dates
#       (2024-11-01 -> 2024-12-01; 2025-05-01 -> 2025-06-01), the same shape as
#       migrations 035/037/042's releases. A C3 override cannot do this: A77
#       withholds in the adapter, before overrides apply, and C3 rewrites only
#       sample_datetime_raw.
#   D12 ES2111255 field duplicate (9 batch_duplicate items): keep withheld -
#       dismiss with a reason.
#   D15 2400-7453-02 Feb 2025 stale dust copy (8 value_conflict items on
#       Dust Results / Dust Observations): withhold - dismiss with a reason.
#       (The file's 44 committed rows are its 2025-02-10 water data.)
#
# Items are identified by stable keys - source_hash + kind/subkind + payload
# fields - never by review uuid. Each rule states how many items it expects;
# a mismatch aborts --apply (the corpus or the code has moved; re-triage).
#
# Usage: Rscript dev/corpus-import/post-import-review.R <db> <out_dir> [--apply]
#   default: dry run - writes <out_dir>/post-import-review-plan.csv, no writes.
#   --apply: performs every action in ONE transaction (the package's own
#            release_review()/resolve_review(), whose connection is pointed at
#            this transaction), appends a note to each released sample's
#            comments, writes <out_dir>/post-import-review-log.csv.
# Idempotent: an item already resolved is skipped; a re-run has nothing to do.
# Run from the repo root.

args <- commandArgs(trailingOnly = TRUE)
apply <- "--apply" %in% args
args <- setdiff(args, "--apply")
if (length(args) != 2L) {
  stop("usage: Rscript dev/corpus-import/post-import-review.R <db> <out_dir> [--apply]")
}
suppressMessages(devtools::load_all(".", quiet = TRUE))
db <- normalizePath(args[[1]], mustWork = TRUE)
out_dir <- args[[2]]
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_dir <- normalizePath(out_dir, mustWork = TRUE)

ACTOR <- "post-import-review (corpus import 2026-10-20; Robin's TRIAGE rulings)"
NOTE_DATE <- "2026-10-20"
cat(sprintf("db       %s\nout_dir  %s\nmode     %s\n", db, out_dir,
            if (apply) "APPLY" else "dry run"))

# ---- rules ------------------------------------------------------------------
refs_all <- function(p, pattern) {
  r <- as.character(unlist(p$source_ref))
  length(r) > 0L && all(grepl(pattern, r))
}
D4_HASH <- c("c56b5bdc259af882788a61d7b038d725", "5655aa4002922c7620d50ed1c3d2a88f",
             "800b663f337223a9a541ea98e7e0ad79", "548fa44d8bc9d8bb4c12e21467779c93",
             "d589962d5c33161c930aca7e467d104b")
D6_DATES <- list(  # source_hash -> exposure / collection, from TRIAGE a77_detail.csv
  d1794cf468afd28d5b87c518a684dfef = c(date_start = "2024-11-01", date = "2024-12-01"),
  "2d728062cf33733b97ce26cfc879636f" = c(date_start = "2025-05-01", date = "2025-06-01")
)

rules <- list(
  list(
    id = "D4", action = "dismiss", hashes = D4_HASH, expected = 25L,
    match = function(it, p) {
      it$kind %in% c("value_conflict", "sample_ambiguous", "unknown_feature") &&
        refs_all(p, "^Sampling Sites [234]!") &&
        (it$kind != "sample_ambiguous" || identical(p$sample_date, "2024-02-19"))
    },
    resolution = paste(
      NOTE_DATE, "corpus import: dismissed (D4, Robin accepted TRIAGE). 2400-7399-04",
      "April 2024 Sampling Sites 2-4 carry 2024-02-19, against the front page and",
      "ES2412736 (2024-04-18), and are partly a stale copy of the February report;",
      "the sheets are dropped, not redated. Their rows were not committed; live keeps its values."
    )
  ),
  list(
    id = "D5", action = "park", hashes = "d1794cf468afd28d5b87c518a684dfef", expected = 21L,
    match = function(it, p) {
      identical(it$kind, "parse_error") && identical(it$subkind, "datetime") &&
        refs_all(p, "^Sampling Sites [24]!")
    },
    resolution = paste(
      "PARKED: TRIAGE's 2024-12-04 is wrong - serial 45629 and ES2439599 both say 2024-12-03;",
      "and the items carry no withheld rows, so release_review() cannot release them."
    )
  ),
  list(
    id = "D6", action = "release", hashes = names(D6_DATES), expected = 4L,
    match = function(it, p) {
      d <- D6_DATES[[it$source_hash]]
      identical(it$kind, "date_conflict") && identical(it$subkind, "a77") &&
        isTRUE(p$gauge %in% c("B.D07", "B.D08")) &&
        identical(p$exposure_date, d[["date_start"]]) &&
        identical(p$collection_date, d[["date"]])
    },
    resolution = NA_character_
  ),
  list(
    id = "D12", action = "dismiss", hashes = "b1e385692b934330d883c556456f779a", expected = 9L,
    match = function(it, p) {
      identical(it$kind, "batch_duplicate") && identical(it$work_order, "ES2111255") &&
        refs_all(p, "^row(1[0-8])$")
    },
    resolution = paste(
      NOTE_DATE, "corpus import: dismissed (D12, Robin accepted TRIAGE). ES2111255 has",
      "a second sample at the same point and datetime with near-identical values - a",
      "field duplicate. It stays withheld; the first sample (rows 1-9) is the one kept."
    )
  ),
  list(
    id = "D15", action = "dismiss", hashes = "53d29779bcc38bdaa705c0fddb082110", expected = 8L,
    match = function(it, p) {
      identical(it$kind, "value_conflict") && identical(it$subkind, "measurement") &&
        refs_all(p, "^Dust (Results|Observations)!")
    },
    resolution = paste(
      NOTE_DATE, "corpus import: dismissed (D15, Robin accepted TRIAGE). The dust in",
      "2400-7453-02 Feb 2025 is dated 2024-02-01 and its values differ from live:",
      "a stale copy. Withheld; live keeps its values."
    )
  )
)

# ---- find the items ---------------------------------------------------------
find_items <- function(con) {
  hashes <- unique(unlist(lapply(rules, `[[`, "hashes")))
  rq <- dplyr::bind_rows(review_queue(con, "open"), review_queue(con, "resolved"))
  rq <- rq[rq$source_hash %in% hashes, ]
  files <- DBI::dbGetQuery(con, "SELECT hash, filename FROM ingest_file")
  out <- list()
  for (r in rules) {
    cand <- rq[rq$source_hash %in% r$hashes, ]
    for (i in seq_len(nrow(cand))) {
      it <- as.list(cand[i, ])
      it$subkind <- if (is.na(it$subkind)) NA_character_ else it$subkind
      p <- jsonlite::fromJSON(it$payload, simplifyVector = TRUE)
      if (!isTRUE(r$match(it, p))) next
      key <- paste(it$source_hash, it$kind, ifelse(is.na(it$subkind), "-", it$subkind),
                   paste(unlist(p$source_ref), collapse = "|"),
                   if (!is.null(p$gauge)) p$gauge else "", sep = " / ")
      out[[length(out) + 1L]] <- tibble::tibble(
        decision = r$id, action = r$action, key = key,
        source_hash = it$source_hash, kind = it$kind, subkind = it$subkind,
        work_order = it$work_order,
        filename = files$filename[match(it$source_hash, files$hash)],
        status = it$status, resolved_by = it$resolved_by,
        review_uuid = it$uuid,
        date_start = if (r$id == "D6") D6_DATES[[it$source_hash]][["date_start"]] else NA_character_,
        date = if (r$id == "D6") D6_DATES[[it$source_hash]][["date"]] else NA_character_
      )
    }
  }
  items <- dplyr::bind_rows(out)
  if (anyDuplicated(items$key[items$action != "park"]) > 0L) {
    stop("post-import-review: two actionable items share a stable key - refusing")
  }
  items
}

check_counts <- function(items, strict) {
  ok <- TRUE
  for (r in rules) {
    n <- sum(items$decision == r$id)
    n_open <- sum(items$decision == r$id & items$status == "open")
    msg <- sprintf("%-4s %-8s expected %2d, found %2d (%d open)", r$id, r$action,
                   r$expected, n, n_open)
    cat(msg, "\n")
    if (n != r$expected) {
      ok <- FALSE
      cat("     ^ COUNT MISMATCH - re-triage before applying\n")
    }
  }
  if (strict && !ok) stop("post-import-review: item counts differ from the triage; nothing applied")
  invisible(ok)
}

# ---- dry run ----------------------------------------------------------------
con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
items <- find_items(con)
DBI::dbDisconnect(con, shutdown = TRUE)
todo <- items[items$status == "open" & items$action != "park", ]
plan <- items
plan$planned <- ifelse(plan$action == "park", "park (no action)",
                       ifelse(plan$status == "open", plan$action, "already resolved - skip"))
utils::write.csv(plan, file.path(out_dir, "post-import-review-plan.csv"), row.names = FALSE)
check_counts(items, strict = apply)
tab <- table(todo$decision)
cat(sprintf("to do: %d item(s) (%s)\n", nrow(todo), paste(names(tab), tab, sep = "=", collapse = ", ")))
if (!apply) {
  cat("dry run - nothing written. Plan:", file.path(out_dir, "post-import-review-plan.csv"), "\n")
  quit(save = "no", status = 0)
}
if (nrow(todo) == 0L) {
  cat("nothing to do\n")
  quit(save = "no", status = 0)
}

# ---- apply: one transaction -------------------------------------------------
append_note <- function(con, table, uuid, note, reason) {
  cur <- DBI::dbGetQuery(con, sprintf("SELECT comments FROM %s WHERE uuid = ?", table),
                         params = list(uuid))$comments
  if (length(cur) != 1L) stop(sprintf("no %s row %s", table, uuid))
  if (!is.na(cur) && grepl(note, cur, fixed = TRUE)) return(FALSE)
  new <- if (is.na(cur) || !nzchar(cur)) note else paste0(cur, "; ", note)
  db_update(con, table, uuid = uuid, changes = list(comments = new),
            actor = ACTOR, reason = reason)
  TRUE
}

log_rows <- with_db_write(function(con) {
  db_transaction(con, function(tcon) {
    # release_review()/resolve_review() each open their own connection via
    # with_db_write(); point that at this transaction's connection, so every
    # action commits or rolls back together (db_transaction() does not nest).
    testthat::with_mocked_bindings(
      with_db_write = function(fn, db, ...) fn(tcon),
      .package = "sampleTidy",
      {
        rows <- list()
        for (i in seq_len(nrow(todo))) {
          t <- todo[i, ]
          n_comm <- 0L
          if (t$action == "dismiss") {
            res <- rules[[which(vapply(rules, `[[`, "", "id") == t$decision)]]$resolution
            done <- resolve_review(t$review_uuid, resolution = res, resolved_by = ACTOR, db = db)
          } else if (t$action == "release") {
            done <- release_review(t$review_uuid,
                                   overrides = list(date_start = t$date_start, date = t$date),
                                   resolved_by = ACTOR, db = db)
            reason <- sprintf("release_review(): uuid=%s", t$review_uuid)
            samp <- DBI::dbGetQuery(tcon,
              "SELECT DISTINCT a.uuid_sample FROM change_log c JOIN analysis a ON a.uuid = c.uuid_row
                WHERE c.tbl = 'analysis' AND c.action = 'insert' AND c.reason = ?",
              params = list(reason))$uuid_sample
            if (isTRUE(done) && length(samp) == 0L) {
              stop(sprintf("release of %s committed no analyses", t$key))
            }
            note <- sprintf(paste(
              "%s corpus import: dust released from %s at exposure %s, collection %s",
              "(D6, Robin accepted TRIAGE): the A77 Month label disagreed with the",
              "observation dates; the data was absent from live"),
              NOTE_DATE, t$filename, t$date_start, t$date)
            for (s in samp) n_comm <- n_comm + append_note(tcon, "sample", s, note, reason)
          }
          rows[[i]] <- tibble::tibble(t[c("decision", "action", "key", "source_hash", "kind",
                                          "subkind", "work_order", "filename", "review_uuid")],
                                      done = isTRUE(done), samples_commented = n_comm)
        }
        dplyr::bind_rows(rows)
      }
    )
  })
}, db = db)

utils::write.csv(log_rows, file.path(out_dir, "post-import-review-log.csv"), row.names = FALSE)
print(as.data.frame(dplyr::count(log_rows, decision, action, done, name = "n")))
cat(sprintf("samples commented: %d\n", sum(log_rows$samples_commented)))
cat("log:", file.path(out_dir, "post-import-review-log.csv"), "\n")
