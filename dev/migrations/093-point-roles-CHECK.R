# Read-only check for migration 093 (monitoring-point roles). Prints PASS or FAIL
# with the problems (exit status 1). Opens the database read-only; writes nothing.
#
# Two modes (SAMPLETIDY_MIG093_CHECK):
#   pre  (default) the database is READY for 093: inputs valid, marker 1091 present,
#        1093 absent, no 093 change_log rows, the plan has no problem (every feature
#        found, K.L08 free, each placeholder position still stored, each one-off
#        alias arm bounded or boundable). PASS before applying; FAIL once 093 has run.
#   post 093 is applied correctly: marker 1093; feature_role and feature_dubious
#        exactly as the INPUT; the rename, positions and alias arms as planned; the
#        role, alias and coordinate db_checks pass. FAIL before applying; PASS after.
#
#   Rscript dev/migrations/093-point-roles-CHECK.R                                  # live, pre
#   SAMPLETIDY_MIG093_CHECK=post Rscript dev/migrations/093-point-roles-CHECK.R     # live, post
#   SAMPLETIDY_MIG093_DB=<copy> Rscript dev/migrations/093-point-roles-CHECK.R      # a rehearsal copy
# Env: SAMPLETIDY_MIG093_REQUIRES (rehearsal only; default 1091),
#      SAMPLETIDY_MIG093_INPUT_DIR (default dev/migrations).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/093-point-roles.R", envir = env)
mode <- Sys.getenv("SAMPLETIDY_MIG093_CHECK", unset = "pre")
if (!mode %in% c("pre", "post")) stop("SAMPLETIDY_MIG093_CHECK must be 'pre' or 'post'.")
rehearsal <- nzchar(Sys.getenv("SAMPLETIDY_MIG093_DB"))
db <- Sys.getenv("SAMPLETIDY_MIG093_DB", unset = st_config("live_db"))
requires <- if (rehearsal) as.integer(Sys.getenv("SAMPLETIDY_MIG093_REQUIRES", unset = env$.mig093_requires)) else
  env$.mig093_requires
input_dir <- Sys.getenv("SAMPLETIDY_MIG093_INPUT_DIR", unset = "dev/migrations")
problems <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))

inp <- tryCatch(env$mig093_read_inputs(input_dir), error = function(e) { add("inputs: %s", conditionMessage(e)); NULL })
if (!is.null(inp)) {
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    if (!all(requires %in% have)) add("marker %s missing", paste(requires, collapse = ","))
    done <- env$.mig093_marker_version %in% have
    if (mode == "pre") {
      if (done) add("marker 1093 already present")
      if (env$.mig093_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", env$.mig093_actor) > 0)
        add("change_log already holds 093 rows")
      plan <- env$mig093_plan(con, inp)
      if (length(plan$problems)) add("%s", plan$problems)
      cat(sprintf("%d role row(s); %d dubious; %d rename(s); %d position(s); one-off alias arms: %d bounded, %d to bound\n",
                  nrow(plan$roles), nrow(plan$dubious), nrow(plan$renames), nrow(plan$positions),
                  sum(!plan$aliases$fix & !is.na(plan$aliases$uuid)), sum(plan$aliases$fix)))
    } else {
      if (!done) add("marker 1093 missing")
      pr <- env$mig093_verify(con, inp)
      if (length(pr)) add("%s", pr)
      n <- env$.mig093_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ? AND tbl NOT IN ('feature', 'feature_alias', 'feature_role', 'feature_dubious')",
                              env$.mig093_actor)
      if (n > 0) add("%d change_log row(s) by 093 outside feature/feature_alias/feature_role/feature_dubious", n)
      chk <- db_checks(con, tier = "all")
      watch <- c("orphan_feature_role_refs", "vocab_feature_role", "alias_self_arm", "alias_key_normalised",
                 "vocab_feature_alias_kind", "feature_coords", "feature_geom_matches_lonlat", "date_windows_ordered")
      bad <- chk[chk$name %in% watch & chk$status != "pass", , drop = FALSE]
      if (nrow(bad)) add("db_checks: %s", paste(bad$name, bad$status, collapse = ", "))
      if (!all(c("orphan_feature_role_refs", "vocab_feature_role") %in% chk$name)) add("the feature_role checks are not in db_checks()")
      if (env$.mig093_scalar(con, "SELECT COUNT(*) FROM information_schema.tables WHERE table_name IN ('feature_role', 'feature_dubious')") == 2) {
        print(DBI::dbGetQuery(con, "SELECT role, water_type, count(*) AS n, count(*) FILTER (WHERE lmf_end_member) AS end_members
                                     FROM feature_role GROUP BY ALL ORDER BY ALL"), row.names = FALSE)
        cat(sprintf("%d dubious feature(s)\n", env$.mig093_scalar(con, "SELECT COUNT(*) FROM feature_dubious")))
      }
    }
  }, error = function(e) add("db: %s", conditionMessage(e)), finally = DBI::dbDisconnect(con, shutdown = TRUE))
}
if (length(problems)) {
  cat("FAIL (", mode, ")\n", paste0(" - ", problems, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
cat("PASS (", mode, ")\n", sep = "")
