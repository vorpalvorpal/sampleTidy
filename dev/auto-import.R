# Hourly auto-import entry point (PLAN-18 section 3). Called by dev/auto-import.sh
# or dev/auto-import.cmd, which have already checked that this machine holds the
# live DB and that something changed. inbox_run() re-checks and holds the lock.
args <- commandArgs(trailingOnly = FALSE)
here <- gsub("~+~", " ", sub("^--file=", "", args[grepl("^--file=", args)]), fixed = TRUE)  # Rscript encodes spaces
repo <- if (length(here)) dirname(dirname(normalizePath(here[1]))) else getwd()
# helpers = FALSE: test helpers must never run in a live import.
suppressMessages(devtools::load_all(repo, quiet = TRUE, helpers = FALSE))

# A deployment attaches its hooks by naming a file in SAMPLETIDY_HOOKS_FILE; it
# never errors, a bad file shows up in the status Problems.
hooks_problem <- load_hooks_file()

nz <- function(x) if (nzchar(x)) x else NULL
db <- nz(Sys.getenv("SAMPLETIDY_AUTOIMPORT_DB")) %||% st_config("live_db")

# st_config("input_dir") is the bare `.../assets/input` folder; the flow writes
# `.../assets/input<date> <subject>/` beside it, so scan its parent.
input_dir <- nz(Sys.getenv("SAMPLETIDY_AUTOIMPORT_INPUT")) %||% {
  d <- st_config("input_dir")
  if (basename(d) == "input") dirname(d) else d
}

vault <- nz(Sys.getenv("PKM_VAULT")) %||% file.path(path.expand("~"), "pkm")
report_dir <- nz(Sys.getenv("SAMPLETIDY_AUTOIMPORT_REPORT")) %||%
  file.path(vault, "0 Misc", "00 Misc", "00.09 Import triage")

# Phase 2 (PLAN-18 section 4): the status note's Flags. The check inputs (the
# schedule, licence and QC tables, streams, invoices) belong to the deployment:
# its hooks file sets st_config("checks"), typically to a function so the tables
# are re-read on every status build.

# The deployment's recogniser (st_config("inbox_batches")) normally comes from
# the hooks file. If that failed to load, sweep nothing rather than fall back on
# the generic default (every subfolder, no settle time); "^$" matches no folder,
# so the status is still refreshed and carries the problem.
batch <- if (length(hooks_problem)) inbox_batches(pattern = "^$") else
  st_config("inbox_batches") %||% inbox_batches()

inbox_run(input_dir = input_dir, db = db,
          backup_dir = file.path(dirname(db), "migration-backups"),
          report_dir = report_dir, checks = st_config("checks"), batch = batch)

# Exit non-zero so that auto-import.sh records the failure and notifies.
if (length(hooks_problem)) {
  cat("hooks file problem:", hooks_problem, "\n", file = stderr())
  quit(save = "no", status = 3)
}
