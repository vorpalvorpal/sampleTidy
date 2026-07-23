# The gate that actually matters: a dry run over ONLY the 8 work orders the
# first real run will ingest, not the whole input directory.
# Runs against a COPY. Never touches the authoritative DB.
suppressMessages(pkgload::load_all("/Users/rjs/dev/sampleTidy", quiet = TRUE))
options(warn = -1)

sharepoint <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring"
live_db   <- file.path(sharepoint, "data", "monitoring.duckdb")
input_dir <- file.path(sharepoint, "assets", "input")

WO8 <- c("ES2600185","ES2610538","ES2612444","ES2614070",
         "ES2614957","ES2616162","ES2616703","ES2617126")

scratch <- "/private/tmp/claude-501/qc-dryrun-8wo"
unlink(scratch, recursive = TRUE); dir.create(scratch, recursive = TRUE)
stage <- file.path(scratch, "stage"); dir.create(stage)
db <- file.path(scratch, "monitoring.duckdb")
snapdir <- file.path(scratch, "snapshots"); dir.create(snapdir)

# --- stage: the 8 work orders' files, EXCLUDING macOS bracket duplicates ---
all_files <- list.files(input_dir, full.names = TRUE)
keep <- all_files[
  grepl(paste(WO8, collapse = "|"), basename(all_files)) &
  !grepl("\\[[0-9]+\\]", basename(all_files))
]
file.copy(keep, file.path(stage, basename(keep)))
cat(sprintf("staged %d files for %d work orders\n", length(keep), length(WO8)))
print(sort(basename(keep)))

# --- migrated copy of the live DB ---
file.copy(live_db, db, overwrite = TRUE)
with_db_write(function(con) ensure_schema(con), db = db)
env <- new.env(parent = asNamespace("sampleTidy"))
sys.source("/Users/rjs/dev/sampleTidy/dev/migrations/001-alias-indirection.R", envir = env)
sys.source("/Users/rjs/dev/sampleTidy/dev/migrations/002-registry-remediation.R", envir = env)
invisible(env$mig001_run(db, snapdir, dry_run = FALSE))
invisible(env$mig002_run(db, snapdir, dry_run = FALSE))
cat("\nmigrations applied\n")

# --- reconcile-only pass (no commit), same shape as the whole-corpus gate ---
register_builtin_adapters()
paths <- as.character(fs::dir_ls(stage, type = "file", all = TRUE, recurse = FALSE))

res <- with_db_write(function(con) {
  ensure_schema(con)
  routed <- sampleTidy:::route_files(paths, con)
  parsed <- sampleTidy:::.ig_parse_claimed(con, routed)
  events <- list()
  if (length(parsed) > 0) {
    asm <- assemble_events(parsed)
    sampleTidy:::.ig_apply_assemble_states(con, asm$states)
    events <- asm$events
  }
  review_all <- list(); n_new <- 0L; n_events <- 0L; n_skip <- 0L
  for (event in events) {
    r <- tryCatch(reconcile_event(event, con), error = function(e) e)
    if (inherits(r, "error")) { cat("EVENT ERROR:", conditionMessage(r), "\n"); next }
    n_events <- n_events + 1L
    n_new  <- n_new  + nrow(r$clean)
    n_skip <- n_skip + nrow(r$skipped)
    if (nrow(r$review) > 0) review_all[[length(review_all) + 1L]] <- r$review
  }
  list(review = if (length(review_all)) dplyr::bind_rows(review_all) else NULL,
       n_new = n_new, n_events = n_events, n_skip = n_skip, routed = routed)
}, db = db)

cat(sprintf("\n=== 8-work-order dry run ===\nevents=%d  clean_rows=%d  skipped=%d  review_items=%d\n",
            res$n_events, res$n_new, res$n_skip,
            if (is.null(res$review)) 0L else nrow(res$review)))

xtr <- function(p, k) { m <- regmatches(p, regexpr(paste0(k, "=[^,]+"), p))
                        if (length(m)) sub(paste0(k, "="), "", m) else NA_character_ }
rv <- res$review
if (!is.null(rv)) {
  cat("\n--- by kind ---\n"); print(table(rv$kind, useNA = "ifany"))
  d <- data.frame(
    kind = rv$kind,
    fr   = vapply(rv$payload, xtr, character(1), "feature_raw"),
    sk   = vapply(rv$payload, xtr, character(1), "subkind"),
    an   = vapply(rv$payload, xtr, character(1), "analyte_raw"),
    n    = as.integer(vapply(rv$payload, xtr, character(1), "n_rows")))
  cat("\n--- detail ---\n"); print(d, row.names = FALSE)
  cat("\nrows held in review:", sum(d$n, na.rm = TRUE), "\n")
  saveRDS(rv, file.path(scratch, "review.rds"))
} else {
  cat("\nNO REVIEW ITEMS.\n")
}
cat("\nDONE\n")
