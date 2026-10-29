# Read-only check for migration 090 (Katoomba whole-site report history). It is the
# migration's test: it prints FAIL (with the reasons) and exits non-zero until 090
# has been applied correctly, and PASS after. Before the migration it also reports
# the pre-flight blockers the run itself would refuse on (a stored sample on a
# planned point-day, a cited ALS work order already holding ALS results, a registry
# conflict, an unexpected ingest_file state), so a FAIL that lists ONLY the
# "not applied yet" items means the database is ready for 090.
# Opens the database read-only; writes nothing.
#   Rscript dev/migrations/090-kat-history-CHECK.R            # live
#   SAMPLETIDY_MIG090_DB=<copy> Rscript ...                    # a rehearsal copy
# Env: SAMPLETIDY_MIG090_FILES_DIR (default dev/migrations/090-kat-history-FILES),
#      SAMPLETIDY_MIG090_TRIM_CSV (default dev/migrations/090-kat-history-TRIM.csv),
#      SAMPLETIDY_MIG090_INPUT_DIR (default dev/migrations).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/090-kat-history.R", envir = env)
db <- Sys.getenv("SAMPLETIDY_MIG090_DB", unset = st_config("live_db"))
files_dir <- Sys.getenv("SAMPLETIDY_MIG090_FILES_DIR", unset = "dev/migrations/090-kat-history-FILES")
trim_csv <- Sys.getenv("SAMPLETIDY_MIG090_TRIM_CSV", unset = "dev/migrations/090-kat-history-TRIM.csv")
input_dir <- Sys.getenv("SAMPLETIDY_MIG090_INPUT_DIR", unset = "dev/migrations")
problems <- character(0)
pending <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))
todo <- function(...) pending <<- c(pending, sprintf(...))
tag <- env$.mig090_adapter_id  # ingest_file.adapter holds the id alone

inp <- tryCatch(env$mig090_read_inputs(input_dir), error = function(e) { add("inputs: %s", conditionMessage(e)); NULL })
if (!is.null(inp)) {
  trim <- tryCatch(env$mig090_read_trim(trim_csv, inp$files), error = function(e) { add("TRIM CSV: %s", conditionMessage(e)); NULL })
  for (i in seq_len(nrow(inp$files))) {
    p <- file.path(files_dir, inp$files$staged_name[[i]])
    if (!file.exists(p)) add("missing file %s", p) else if (!identical(hash_file(p), inp$files$hash[[i]]))
      add("hash differs: %s", p)
  }
  parsed <- tryCatch(env$mig090_parse_all(inp), error = function(e) { add("parse: %s", conditionMessage(e)); NULL })
  if (!is.null(parsed)) {
    res <- dplyr::bind_rows(lapply(parsed, function(p) p$results))
    smp <- dplyr::bind_rows(lapply(parsed, function(p) p$samples))
    cat(sprintf("%d PDFs, %d cells, %d result rows, %d samples\n", nrow(inp$files), nrow(inp$values), nrow(res), nrow(smp)))
    # expected analyses per point-day and lab_method name
    res$feature <- env$.mig090_point_of(res$feature_raw)
    res$day <- format(as.Date(vapply(strsplit(res$lab_sample_id, "!", fixed = TRUE), function(z) z[[3]], ""), "%d%b%Y"))
    want <- stats::aggregate(list(n = rep(1L, nrow(res))), res[, c("feature", "day", "analyte_raw")], sum)
  }
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(env$.mig090_requires %in% have)) add("marker %d (089) missing", env$.mig090_requires)
    applied <- env$.mig090_marker_version %in% have
    if (!applied) todo("marker %d not present (090 not applied)", env$.mig090_marker_version)

    # ingest_file / asset / filing state of the 17 PDFs
    st <- env$mig090_file_states(con, inp)
    n_done <- sum(!is.na(st$hash) & st$state == "archived" & st$adapter == tag)
    if (n_done < nrow(inp$files)) todo("%d of %d PDFs archived by %s", n_done, nrow(inp$files), tag)
    odd <- st[!is.na(st$hash) & !(st$state %in% c("archived", "seen")), , drop = FALSE]
    if (nrow(odd)) add("unexpected ingest_file state(s): %s", paste(unique(odd$state), collapse = ", "))
    na <- DBI::dbGetQuery(con, sprintf("SELECT hash, count(*) AS n FROM asset WHERE hash IN %s GROUP BY 1",
                                       env$.mig090_inlist(inp$files$hash)))
    if (any(na$n > 1)) add("a PDF is more than one asset")
    if (applied && nrow(na) != nrow(inp$files)) add("%d assets for %d PDFs", nrow(na), nrow(inp$files))
    if (!is.null(trim) && nrow(na) == nrow(inp$files)) {
      fp <- env$mig090_filing_plan(con, inp, trim)
      if (any(!is.na(fp$filed_as) & fp$filed_as != fp$trim_record)) add("a PDF is filed under a record the TRIM CSV does not name")
      if (any(is.na(fp$filed_as))) todo("%d PDF(s) have no TRIM filing row", sum(is.na(fp$filed_as)))
    } else if (nrow(na) < nrow(inp$files)) todo("%d PDF(s) not yet assets", nrow(inp$files) - nrow(na))

    # alias arms
    if (!is.null(parsed)) {
      plan <- env$mig090_plan_registry(con, inp, parsed)
      got <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", env$.mig090_inlist(plan$alias$uuid)))$uuid
      if (length(got) < nrow(plan$alias)) todo("%d of %d alias arms absent", nrow(plan$alias) - length(got), nrow(plan$alias))
      pr <- env$mig090_registry_problems(con, plan)
      if (length(pr)) add("registry: %s", paste(pr, collapse = "; "))

      # stored analyses at the planned point-days, by lab_method
      pd <- env$mig090_planned_point_days(parsed)
      DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m090_pd (feature VARCHAR, day DATE)")
      DBI::dbAppendTable(con, "m090_pd", unique(pd[, c("feature", "day")]))
      stored <- DBI::dbGetQuery(con, sprintf("
        SELECT f.name AS feature, CAST(%s AS VARCHAR) AS day, lm.name AS analyte_raw, lm.organisation AS lab_org,
               s.organisation, count(*) AS n
        FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
        JOIN m090_pd pd ON pd.feature = f.name AND pd.day = %s
        JOIN analysis a ON a.uuid_sample = s.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
        GROUP BY ALL", env$.mig090_syd("coalesce(s.date, s.datetime)"), env$.mig090_syd("coalesce(s.date, s.datetime)")))
      nsmp <- DBI::dbGetQuery(con, sprintf("
        SELECT f.name AS feature, CAST(%s AS VARCHAR) AS day, count(*) AS n
        FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
        JOIN m090_pd pd ON pd.feature = f.name AND pd.day = %s GROUP BY ALL",
        env$.mig090_syd("coalesce(s.date, s.datetime)"), env$.mig090_syd("coalesce(s.date, s.datetime)")))
      if (!applied) {
        # pre-flight: the history must be new, and its ALS originals absent
        if (nrow(nsmp)) add("pre-flight: %d planned point-day(s) already hold samples: %s", nrow(nsmp),
                            paste(utils::head(paste(nsmp$feature, nsmp$day), 10), collapse = ", "))
        als <- env$mig090_als_held(con, inp)
        if (nrow(als)) add("pre-flight: cited ALS work order(s) already hold ALS results: %s", paste(als$name, collapse = ", "))
        if (nrow(stored) == 0) todo("no analyses at the %d planned point-days", nrow(unique(pd[, c("feature", "day")])))
      } else {
        if (any(stored$lab_org != "ACIRL" | stored$organisation != "ACIRL"))
          add("non-ACIRL rows at planned point-days")
        if (nrow(nsmp) != nrow(unique(pd[, c("feature", "day")])) || any(nsmp$n != 1))
          add("point-days with no sample or more than one: %d of %d as planned", sum(nsmp$n == 1),
              nrow(unique(pd[, c("feature", "day")])))
        m <- merge(want, stored[, c("feature", "day", "analyte_raw", "n")], by = c("feature", "day", "analyte_raw"),
                   all = TRUE, suffixes = c("_want", "_got"))
        m[is.na(m)] <- 0L
        bad <- m[m$n_want != m$n_got, , drop = FALSE]
        if (nrow(bad)) add("%d (point-day, analyte) count(s) differ from the INPUT, e.g. %s", nrow(bad),
                           paste(utils::head(sprintf("%s %s %s want %d got %d", bad$feature, bad$day, bad$analyte_raw,
                                                     bad$n_want, bad$n_got), 5), collapse = "; "))
        if (env$.mig090_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", env$.mig090_actor) == 0)
          add("change_log holds no 090 rows")
        cat(sprintf("stored: %d samples, %d analyses at %d point-days\n", sum(nsmp$n), sum(stored$n), nrow(nsmp)))
      }
    }
  }, error = function(e) add("db: %s", conditionMessage(e)), finally = DBI::dbDisconnect(con, shutdown = TRUE))
}
if (length(problems) || length(pending)) {
  cat("FAIL\n", paste0(" - ", c(pending, problems), collapse = "\n"), "\n", sep = "")
  if (!length(problems)) cat("(only 'not applied yet' items: the database is ready for 090)\n")
  quit(status = 1)
}
cat("PASS\n")
