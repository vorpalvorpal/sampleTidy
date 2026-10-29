# Read-only check for migration 091 (bore logs). Prints PASS or FAIL with the
# problems (exit status 1). Opens the database read-only; writes nothing.
#
# Two modes (SAMPLETIDY_MIG091_CHECK):
#   pre  (default) pre-flight: inputs valid, every file present with its frozen
#        hash, markers in place, 1091 absent, no planned hash/uuid/archive dir taken.
#        PASS before applying; FAIL once 091 has run.
#   post the applied state: marker 1091; every asset row, archived copy, feature
#        note and TRIM filing as planned; no 091 asset reachable by the TRIM filer
#        (it reads only assets with a project, and ingest_file rows); the asset
#        db_checks pass. FAIL before applying; PASS once 091 has run.
#
#   Rscript dev/migrations/091-bore-logs-CHECK.R                                   # live, pre
#   SAMPLETIDY_MIG091_CHECK=post Rscript dev/migrations/091-bore-logs-CHECK.R      # live, post
#   SAMPLETIDY_MIG091_DB=<copy> SAMPLETIDY_MIG091_ARCHIVE_DIR=<dir> Rscript ...    # a rehearsal copy
# Env: SAMPLETIDY_MIG091_REQUIRES (rehearsal only; default 1089),
#      SAMPLETIDY_MIG091_FILES_DIR (default dev/migrations/091-bore-logs-FILES),
#      SAMPLETIDY_MIG091_TRIM_CSV (default dev/migrations/091-bore-logs-TRIM.csv),
#      SAMPLETIDY_MIG091_INPUT_DIR (default dev/migrations).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/091-bore-logs.R", envir = env)
mode <- Sys.getenv("SAMPLETIDY_MIG091_CHECK", unset = "pre")
if (!mode %in% c("pre", "post")) stop("SAMPLETIDY_MIG091_CHECK must be 'pre' or 'post'.")
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG091_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG091_DB", unset = st_config("live_db"))
archive_dir <- Sys.getenv("SAMPLETIDY_MIG091_ARCHIVE_DIR", unset = if (rehearsal) "" else st_config("archive_dir"))
if (!nzchar(archive_dir)) stop("a rehearsal needs SAMPLETIDY_MIG091_ARCHIVE_DIR.")
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG091_REQUIRES", unset = env$.mig091_requires)) else
  env$.mig091_requires
files_dir <- Sys.getenv("SAMPLETIDY_MIG091_FILES_DIR", unset = "dev/migrations/091-bore-logs-FILES")
trim_csv <- Sys.getenv("SAMPLETIDY_MIG091_TRIM_CSV", unset = "dev/migrations/091-bore-logs-TRIM.csv")
input_dir <- Sys.getenv("SAMPLETIDY_MIG091_INPUT_DIR", unset = "dev/migrations")
problems <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))

inp <- tryCatch(env$mig091_read_inputs(input_dir), error = function(e) { add("inputs: %s", conditionMessage(e)); NULL })
if (!is.null(inp)) {
  trim <- tryCatch(env$mig091_read_trim(trim_csv, inp$assets),
                   error = function(e) { add("TRIM CSV: %s", conditionMessage(e)); NULL })
  uuids <- vapply(inp$assets$hash, function(h) env$.mig091_uuid("asset", h), "", USE.NAMES = FALSE)
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) add("marker %s missing", paste(requires, collapse = ","))
    done <- env$.mig091_marker_version %in% have
    if (mode == "pre") {
      if (done) add("marker 1091 already present")
      if (env$.mig091_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", env$.mig091_actor) > 0)
        add("change_log already holds 091 rows")
      plan <- env$mig091_plan(con, inp)
      pr <- env$mig091_problems(con, plan, files_dir, archive_dir)
      if (length(pr)) add("%s", pr)
      if (any(plan$notes$present)) add("note(s) already present for %s", paste(plan$notes$feature[plan$notes$present], collapse = ", "))
      cat(sprintf("%d bore log(s) for %d feature(s); %d feature note(s); %d TRIM adoption(s)\n",
                  nrow(inp$assets), length(unique(inp$assets$feature)), nrow(inp$notes), if (is.null(trim)) NA else nrow(trim)))
    } else {
      if (!done) add("marker 1091 missing")
      if (!is.null(trim)) {
        pr <- env$mig091_verify(con, inp, trim, archive_dir)
        if (length(pr)) add("%s", pr)
      }
      # The TRIM filer (bmcc-monitoring R/filer-snapshot.R) and completed_work()
      # read only assets with a project, and ingest_file rows (by hash).
      n <- env$.mig091_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE uuid IN %s AND uuid_project IS NOT NULL",
                                           env$.mig091_inlist(uuids)))
      if (n > 0) add("%d 091 asset(s) carry a project (the filer would see them)", n)
      n <- env$.mig091_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s OR uuid_asset IN %s",
                                           env$.mig091_inlist(inp$assets$hash), env$.mig091_inlist(uuids)))
      if (n > 0) add("%d ingest_file row(s) reach a 091 asset (the filer would see them)", n)
      n <- env$.mig091_scalar(con, sprintf("SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl NOT IN ('asset', 'feature', 'asset_filing', 'schema_version')"),
                              env$.mig091_actor)
      if (n > 0) add("%d change_log row(s) by 091 outside asset/feature/asset_filing", n)
      chk <- db_checks(con, tier = "all")
      bad <- chk[chk$name %in% c("orphan_asset_refs", "dup_asset_hash", "hash_format") & chk$status != "pass", , drop = FALSE]
      if (nrow(bad)) add("db_checks: %s", paste(bad$name, bad$status, collapse = ", "))
      cat(sprintf("%d bore log(s) linked; %d feature note(s); %d TRIM adoption(s)\n",
                  env$.mig091_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE uuid IN %s", env$.mig091_inlist(uuids))),
                  nrow(inp$notes), if (is.null(trim)) NA else nrow(trim)))
    }
  }, error = function(e) add("db: %s", conditionMessage(e)), finally = DBI::dbDisconnect(con, shutdown = TRUE))
}
if (length(problems)) {
  cat("FAIL (", mode, ")\n", paste0(" - ", problems, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
cat("PASS (", mode, ")\n", sep = "")
