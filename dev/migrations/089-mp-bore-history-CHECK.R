# Read-only pre-flight for migration 089 (MP bore history). Prints PASS or the
# problems and exits non-zero. Opens the database read-only; writes nothing.
#   Rscript dev/migrations/089-mp-bore-history-CHECK.R            # live
#   SAMPLETIDY_MIG089_DB=<copy> SAMPLETIDY_MIG089_REQUIRES=1082 Rscript ...   # a rehearsal copy
# Env: SAMPLETIDY_MIG089_FILES_DIR (default dev/migrations/089-mp-bore-history-FILES),
#      SAMPLETIDY_MIG089_TRIM_CSV (default dev/migrations/089-mp-bore-history-TRIM.csv),
#      SAMPLETIDY_MIG089_INPUT_DIR (default dev/migrations).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/089-mp-bore-history.R", envir = env)
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG089_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG089_DB", unset = st_config("live_db"))
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG089_REQUIRES", unset = env$.mig089_requires)) else
  env$.mig089_requires
files_dir <- Sys.getenv("SAMPLETIDY_MIG089_FILES_DIR", unset = "dev/migrations/089-mp-bore-history-FILES")
trim_csv <- Sys.getenv("SAMPLETIDY_MIG089_TRIM_CSV", unset = "dev/migrations/089-mp-bore-history-TRIM.csv")
input_dir <- Sys.getenv("SAMPLETIDY_MIG089_INPUT_DIR", unset = "dev/migrations")
problems <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))

inp <- tryCatch(env$mig089_read_inputs(input_dir), error = function(e) { add("inputs: %s", conditionMessage(e)); NULL })
if (!is.null(inp)) {
  tryCatch(env$mig089_read_trim(trim_csv, inp$files), error = function(e) add("TRIM CSV: %s", conditionMessage(e)))
  for (i in seq_len(nrow(inp$files))) {
    p <- file.path(files_dir, inp$files$staged_name[[i]])
    if (!file.exists(p)) add("missing file %s", p) else if (!identical(hash_file(p), inp$files$hash[[i]]))
      add("hash differs: %s", p)
  }
  parsed <- tryCatch(env$mig089_parse_all(inp), error = function(e) { add("parse: %s", conditionMessage(e)); NULL })
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) add("marker %s missing", paste(requires, collapse = ","))
    if (env$.mig089_marker_version %in% have) add("marker 1089 already present")
    if (env$.mig089_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", env$.mig089_actor) > 0)
      add("change_log already holds 089 rows")
    n <- env$.mig089_scalar(con, sprintf("SELECT COUNT(*) FROM asset WHERE hash IN %s", env$.mig089_inlist(inp$files$hash)))
    if (n > 0) add("%d of the PDFs are already assets", n)
    n <- env$.mig089_scalar(con, sprintf("SELECT COUNT(*) FROM ingest_file WHERE hash IN %s", env$.mig089_inlist(inp$files$hash)))
    if (n > 0) add("%d of the PDFs already have ingest_file rows", n)
    plan <- env$mig089_plan_registry(con, inp)
    pr <- env$mig089_registry_problems(con, plan)
    if (length(pr)) add("registry: %s", paste(pr, collapse = "; "))
    # no MP-bore sample already on any planned day (the history must be new)
    days <- unique(format(env$.mig089_day_of(inp$values$sample_datetime_raw)))
    hit <- DBI::dbGetQuery(con, sprintf("SELECT f.name, %s AS day FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f ON f.uuid = fa.uuid_feature WHERE f.name IN %s AND %s IN %s",
      env$.mig089_syd("coalesce(s.date, s.datetime)"), env$.mig089_inlist(env$.mig089_bores$feature),
      env$.mig089_syd("coalesce(s.date, s.datetime)"), sprintf("(%s)", paste0("DATE '", days, "'", collapse = ","))))
    if (nrow(hit)) add("already sampled: %s", paste(unique(paste(hit$name, hit$day)), collapse = ", "))
    # every report project / ALS work order the import would create is free
    rn <- unique(c(inp$files$report_no, unlist(strsplit(stats::na.omit(inp$files$als_work_order), ";"))))
    taken <- DBI::dbGetQuery(con, sprintf("SELECT name FROM project WHERE name IN %s", env$.mig089_inlist(rn)))$name
    if (length(taken)) add("project name(s) already exist: %s", paste(taken, collapse = ", "))
  }, error = function(e) add("db: %s", conditionMessage(e)), finally = DBI::dbDisconnect(con, shutdown = TRUE))
  if (!is.null(parsed)) cat(sprintf("%d PDFs, %d cells, %d result rows, %d samples\n", nrow(inp$files), nrow(inp$values),
                                    sum(vapply(parsed, function(p) nrow(p$results), 0L)),
                                    sum(vapply(parsed, function(p) nrow(p$samples), 0L))))
}
if (length(problems)) {
  cat("FAIL\n", paste0(" - ", problems, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
cat("PASS\n")
