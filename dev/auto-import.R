# Hourly auto-import entry point (PLAN-18 section 3). Called by dev/auto-import.sh
# or dev/auto-import.cmd, which have already checked that this machine holds the
# live DB and that something changed. inbox_run() re-checks and holds the lock.
args <- commandArgs(trailingOnly = FALSE)
here <- gsub("~+~", " ", sub("^--file=", "", args[grepl("^--file=", args)]), fixed = TRUE)  # Rscript encodes spaces
repo <- if (length(here)) dirname(dirname(normalizePath(here[1]))) else getwd()
suppressMessages(devtools::load_all(repo, quiet = TRUE))

# A deployment attaches its hooks by naming a file in SAMPLETIDY_HOOKS_FILE; it
# never errors, a bad file shows up in the status Problems.
load_hooks_file()

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

# Phase 2 (PLAN-18 section 4): the status note's Flags. The package never reads
# dev/, so the schedule and licence tables are passed from here. Invoice
# evidence comes from the invoice-automation contractor work ledger (PLAN-18
# 4.6); a missing ledger gives zero rows, an unreadable one NULL - either way
# only invoiced_not_received is affected.
dev_dir <- file.path(repo, "dev")
ledger <- nz(Sys.getenv("SAMPLETIDY_AUTOIMPORT_LEDGER")) %||%
  file.path(path.expand("~"), "OneDrive - Blue Mountains City Council",
            "invoice-automation", "contractor-work.json")
invoices <- tryCatch(sampling_rounds(ledger)[, c("site", "stream", "sampled_on", "ref")],
                     error = function(e) NULL)
# The EPA licence tables belong to the deployment, not this repo.
licence_dir <- path.expand(Sys.getenv("SAMPLETIDY_AUTOIMPORT_LICENCE_DIR",
                                      "~/dev/bmcc-monitoring/epa"))
checks <- list(
  schedule = file.path(dev_dir, "expected_schedule.csv"),
  limits = file.path(licence_dir, "epa_licence_limits.csv"),
  requirements = file.path(licence_dir, "epa_licence_requirements.csv"),
  points = file.path(licence_dir, "epa_licence_points.csv"),
  invoices = invoices,
  # PLAN-19: field QC criteria and the QC samples each round must carry.
  qc = list(criteria = file.path(dev_dir, "qc_criteria.csv"),
            requirements = file.path(dev_dir, "qc_requirements.csv"))
)

inbox_run(input_dir = input_dir, db = db,
          backup_dir = file.path(dirname(db), "migration-backups"),
          report_dir = report_dir, checks = checks)
