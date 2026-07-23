suppressMessages(pkgload::load_all(".", quiet=TRUE))
options(warn = -1)

sharepoint <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring"
live_db <- file.path(sharepoint, "data", "monitoring.duckdb")
input_dir <- file.path(sharepoint, "assets", "input")

scratch <- "/private/tmp/claude-501/qc-dryrun"
dir.create(scratch, recursive = TRUE, showWarnings = FALSE)
db <- file.path(scratch, "monitoring_dryrun.duckdb")
snapdir <- file.path(scratch, "snapshots"); dir.create(snapdir, showWarnings = FALSE)
file.copy(live_db, db, overwrite = TRUE)
cat(sprintf("copied live db -> %s (%.1f MB)\n", db, file.info(db)$size/1e6))

# --- bring the copy up to current schema + migrations ---
sampleTidy::with_db_write(function(con) sampleTidy::ensure_schema(con), db = db)
env <- new.env(parent = asNamespace("sampleTidy"))
sys.source("dev/migrations/001-alias-indirection.R", envir = env)
sys.source("dev/migrations/002-registry-remediation.R", envir = env)
invisible(env$mig001_run(db, snapdir, dry_run = FALSE))
invisible(env$mig002_run(db, snapdir, dry_run = FALSE))
cat("migrations applied\n")

# --- front half of ingest_dir, dry: collect per-event review tibbles ---
register_builtin_adapters()
paths <- as.character(fs::dir_ls(input_dir, type = "file", all = TRUE, recurse = FALSE))
cat(sprintf("input files: %d\n", length(paths)))

res <- sampleTidy::with_db_write(function(con) {
  ensure_schema(con)
  routed <- sampleTidy:::route_files(paths, con)
  parsed <- sampleTidy:::.ig_parse_claimed(con, routed)
  events <- list()
  if (length(parsed) > 0) {
    asm <- assemble_events(parsed)
    sampleTidy:::.ig_apply_assemble_states(con, asm$states)
    events <- asm$events
  }
  review_all <- list(); skip_all <- list(); n_new <- 0L; n_events <- 0L
  for (event in events) {
    resolved <- tryCatch(reconcile_event(event, con), error = function(e) e)
    if (inherits(resolved, "error")) next
    n_events <- n_events + 1L
    n_new <- n_new + nrow(resolved$clean)
    if (nrow(resolved$review) > 0) review_all[[length(review_all)+1]] <- resolved$review
    if (nrow(resolved$skipped) > 0) skip_all[[length(skip_all)+1]] <- resolved$skipped
  }
  list(review = if(length(review_all)) dplyr::bind_rows(review_all) else NULL,
       skipped = if(length(skip_all)) dplyr::bind_rows(skip_all) else NULL,
       n_new = n_new, n_events = n_events, routed = routed)
}, db = db)

rv <- res$review
saveRDS(rv, file.path(scratch, "review_all.rds"))
saveRDS(res$skipped, file.path(scratch, "skipped_all.rds"))
cat(sprintf("\nevents=%d  new_rows=%d  review_items=%d\n", res$n_events, res$n_new,
            if(is.null(rv)) 0 else nrow(rv)))
cat("\n=== review items by kind ===\n")
if (!is.null(rv)) print(table(rv$kind, useNA="ifany"))

xtr <- function(p, key){ m <- regmatches(p, regexpr(paste0(key,"=[^,]+"), p)); if(length(m)) sub(paste0(key,"="),"",m) else NA_character_ }
# subkind (parsed from payload) breakdown
if (!is.null(rv)) {
  rv$subkind <- vapply(rv$payload, xtr, character(1), key="subkind")
  cat("\n=== kind x subkind ===\n")
  print(table(rv$kind, rv$subkind, useNA="ifany"))
}

# unknown_feature detail: the point names + whether a candidate suggestion exists
if (!is.null(rv)) {
  uf <- rv[rv$kind == "unknown_feature", ]
  cat(sprintf("\n=== unknown_feature: %d grouped items ===\n", nrow(uf)))
  feat <- vapply(uf$payload, xtr, character(1), key="feature_raw")
  wo   <- vapply(uf$payload, xtr, character(1), key="work_order")
  cand <- vapply(uf$payload, xtr, character(1), key="candidates")
  det <- data.frame(feature_raw=feat, work_order=wo, n_rows=uf$n_rows, candidates=cand, stringsAsFactors=FALSE)
  det <- det[order(-det$n_rows), ]
  cat(sprintf("with a candidate suggestion: %d ; without: %d\n", sum(!is.na(cand)), sum(is.na(cand))))
  print(det, row.names=FALSE)
  saveRDS(det, file.path(scratch, "unknown_feature_detail.rds"))
}
# unknown_analyte detail
if (!is.null(rv)) {
  ua <- rv[rv$kind == "unknown_analyte", ]
  cat(sprintf("\n=== unknown_analyte: %d items ===\n", nrow(ua)))
  ana <- vapply(ua$payload, xtr, character(1), key="analyte_raw")
  print(sort(table(ana), decreasing=TRUE))
  cat("\n-- sample payloads --\n"); print(utils::head(ua$payload, 14))
}
cat("\nDONE\n")
