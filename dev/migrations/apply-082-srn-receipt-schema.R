# Apply migration 082 (Robin 2026-10-25, R-22.S): add the SRN receipt schema to the live
# database and backfill it (every stored SRN parsed; every QC/QCI report re-parsed to parser
# version 2 so received_at is filled). Dry run, migrate, re-run (no-op), with table counts and
# db_checks(tier = "all") before and after. Requires marker 1081. Run from the repo root:
#   Rscript dev/migrations/apply-082-srn-receipt-schema.R
# Rehearsal: set SAMPLETIDY_MIG082_DB / _SNAPSHOT_DIR / _CSV_DIR (and _ARCHIVE_DIR). Unset, it
# targets the LIVE db and the live archive. The ~220 QC PDFs are READ from the archive
# (OneDrive Files-On-Demand downloads them); nothing is written there.
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/082-srn-receipt-schema.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG082_DB", unset = st_config("live_db"))
backup_dir <- Sys.getenv("SAMPLETIDY_MIG082_SNAPSHOT_DIR",
                         unset = file.path(tools::R_user_dir("sampleTidy"), "migration-backups"))
csv_dir <- Sys.getenv("SAMPLETIDY_MIG082_CSV_DIR", unset = "dev/migrations")
archive_dir <- Sys.getenv("SAMPLETIDY_MIG082_ARCHIVE_DIR", unset = st_config("archive_dir"))
stopifnot(dir.exists(backup_dir), dir.exists(csv_dir))
cat("db:", db, "\narchive_dir:", archive_dir, "\n")
report <- function(label) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  cat(label, ":\n")
  cn <- c("lab_qc_report", "lab_qc_outlier", "change_log", "schema_version")
  print(vapply(cn, function(t) env$.mig082_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t)), 1L))
  print(DBI::dbGetQuery(con, "SELECT max(version) AS marker FROM schema_version"))
  if (.lab_receipt_ready(con)) {
    s <- env$.mig082_summary(con)
    print(s$srn); print(s$reparsed); print(s$kids)
    print(DBI::dbGetQuery(con, "SELECT work_order, status, received_at, client_due_date, scheduled_report_date,
      delivery_mode, security_seal, n_coolers, temp_min_c, temp_max_c, cooling_medium, cooling_present,
      n_container_noncompliances, n_holding_breaches, parser_version
      FROM lab_qc_report WHERE kind = 'SRN'"))
  }
  r <- db_checks(con, tier = "all")
  print(r[r$status != "pass", c("name", "tier", "severity", "status", "n")], row.names = FALSE)
  invisible(r)
}
report("before")
for (dr in c(TRUE, FALSE, FALSE)) {
  r <- env$mig082_run(db = db, snapshot_dir = backup_dir, dry_run = dr, csv_dir = csv_dir, archive_dir = archive_dir)
  cat("dry_run =", dr, "->", r$status, "\n")
}
report("after")
