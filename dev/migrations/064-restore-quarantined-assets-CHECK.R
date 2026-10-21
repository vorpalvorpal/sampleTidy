# Read-only pre-flight for migration 064. Robin runs this against LIVE after the
# historical corpus import and BEFORE applying 064. It writes nothing and moves
# nothing. It confirms that live matches the rehearsal assumptions: every target
# project exists; none of the 121 quarantine uuids is already an asset; no restore
# file's hash is already an asset hash; every skipped item is represented by an
# asset; no target processed/<uuid>/<filename> is occupied; every restore file is
# still in the quarantine with its frozen size and hash; and the row count is the
# rehearsed 78. Prints RESULT: PASS or RESULT: FAIL (exit status 1 on FAIL).
# 064 itself runs the same checks and aborts on any mismatch.
#
#   Rscript dev/migrations/064-restore-quarantined-assets-CHECK.R
#
# Unset, it reads the LIVE db and archive_dir = SAMPLETIDY_ARCHIVE_DIR from
# ~/.Renviron; SAMPLETIDY_MIG064_DB / _ARCHIVE_DIR / _QUARANTINE_DIR override them.
# Hashing hydrates the 121 quarantine files (~340 MB) from OneDrive on first run.
live_archive <- Sys.getenv("SAMPLETIDY_ARCHIVE_DIR")   # read before load_all (test helpers isolate config)
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/064-restore-quarantined-assets.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG064_DB", unset = st_config("live_db"))
archive_dir <- Sys.getenv("SAMPLETIDY_MIG064_ARCHIVE_DIR", unset = live_archive)
quarantine_dir <- Sys.getenv("SAMPLETIDY_MIG064_QUARANTINE_DIR", unset = env$.mig064_default_quarantine(archive_dir))
stopifnot(nzchar(archive_dir))
r <- env$mig064_check(db = db, archive_dir = archive_dir, quarantine_dir = quarantine_dir)
if (!r$ok) quit(status = 1)
