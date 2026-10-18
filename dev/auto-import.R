# Hourly auto-import entry point (PLAN-18 section 3). Called by dev/auto-import.sh
# or dev/auto-import.cmd, which have already checked that this machine holds the
# live DB and that something changed. inbox_run() re-checks and holds the lock.
args <- commandArgs(trailingOnly = FALSE)
here <- sub("^--file=", "", args[grepl("^--file=", args)])
repo <- if (length(here)) dirname(dirname(normalizePath(here[1]))) else getwd()
suppressMessages(devtools::load_all(repo, quiet = TRUE))

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

inbox_run(input_dir = input_dir, db = db,
          backup_dir = file.path(dirname(db), "migration-backups"),
          report_dir = report_dir)
