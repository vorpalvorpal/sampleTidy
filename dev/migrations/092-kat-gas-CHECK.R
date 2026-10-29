# Read-only check for migration 092 (Katoomba landfill-gas history from the ACIRL
# reports). Two modes (SAMPLETIDY_MIG092_CHECK):
#   pre  (default) - the database is READY for 092: 1090 present, 1092 absent, the
#        24 PDFs archived by 089's/090's adapter with one asset and one trim filing
#        each, no stored CH4 reading at a planned point-day, the registry resolves
#        every printed name to its mapped feature (counting the planned arms and
#        self aliases), K.G15/K.G19/K.G20/K.G25 and the biofilter notes absent.
#        Prints "PASS (pre)".
#   post - 092 is applied correctly: marker present, every PDF archived by
#        acirl_pdf_092, exactly one ACIRL CH4 sample and analysis per planned
#        point-day, matching the INPUT, the alias arms present, the four created
#        features (unlocated at the K.centroid, date_end 2022-01-01) and their self
#        aliases present, every biofilter note present. Prints "PASS (post)".
# Exits non-zero with the reasons on FAIL. Opens the database read-only.
#   Rscript dev/migrations/092-kat-gas-CHECK.R                       # live, pre
#   SAMPLETIDY_MIG092_CHECK=post Rscript dev/migrations/092-kat-gas-CHECK.R
#   SAMPLETIDY_MIG092_DB=<copy> ...                                   # a rehearsal copy
# Env: SAMPLETIDY_MIG092_FILES_ROOT (default dev/migrations: the PDFs are read from
#      089-mp-bore-history-FILES/ and 090-kat-history-FILES/ under it),
#      SAMPLETIDY_MIG092_INPUT_DIR (default dev/migrations).
suppressMessages(devtools::load_all(quiet = TRUE))
env <- new.env()
sys.source("dev/migrations/092-kat-gas.R", envir = env)
mode <- Sys.getenv("SAMPLETIDY_MIG092_CHECK", unset = "pre")
stopifnot(mode %in% c("pre", "post"))
db <- Sys.getenv("SAMPLETIDY_MIG092_DB", unset = st_config("live_db"))
files_root <- Sys.getenv("SAMPLETIDY_MIG092_FILES_ROOT", unset = "dev/migrations")
input_dir <- Sys.getenv("SAMPLETIDY_MIG092_INPUT_DIR", unset = "dev/migrations")
problems <- character(0)
add <- function(...) problems <<- c(problems, sprintf(...))
tag <- env$.mig092_adapter_id

inp <- tryCatch(env$mig092_read_inputs(input_dir), error = function(e) { add("inputs: %s", conditionMessage(e)); NULL })
if (!is.null(inp)) {
  for (i in seq_len(nrow(inp$files))) {
    p <- file.path(files_root, inp$files$source_dir[[i]], inp$files$staged_name[[i]])
    if (!file.exists(p)) add("missing file %s", p) else if (!identical(hash_file(p), inp$files$hash[[i]]))
      add("hash differs: %s", p)
  }
  parsed <- tryCatch(env$mig092_parse_all(inp), error = function(e) { add("parse: %s", conditionMessage(e)); NULL })
  con <- st_connect(db, read_only = TRUE)
  tryCatch({
    have <- DBI::dbGetQuery(con, "SELECT version FROM schema_version")$version
    applied <- env$.mig092_marker_version %in% have
    if (!all(env$.mig092_requires %in% have)) add("marker %d (090) missing", env$.mig092_requires)
    if (mode == "pre" && applied) add("marker %d present: 092 already applied", env$.mig092_marker_version)
    if (mode == "post" && !applied) add("marker %d absent: 092 not applied", env$.mig092_marker_version)

    st <- env$mig092_file_states(con, inp)
    if (anyNA(st$hash)) add("%d PDF(s) not in ingest_file", sum(is.na(st$hash)))
    if (mode == "pre") {
      bad <- st[!is.na(st$hash) & !(st$state == "archived" & st$adapter %in% inp$files$prior_adapter[match(st$hash, inp$files$hash)]), ]
      if (nrow(bad)) add("%d PDF(s) not archived by their 089/090 adapter: %s", nrow(bad),
                         paste(unique(paste(bad$state, bad$adapter)), collapse = ", "))
    } else {
      n_done <- sum(!is.na(st$hash) & st$state == "archived" & st$adapter == tag)
      if (n_done < nrow(inp$files)) add("%d of %d PDFs archived by %s", n_done, nrow(inp$files), tag)
    }
    fl <- env$mig092_filing_state(con, inp)
    if (anyNA(fl$uuid) || any(fl$n_filed != 1)) add("a PDF is not exactly one asset with one trim filing")
    na <- DBI::dbGetQuery(con, sprintf("SELECT hash, count(*) AS n FROM asset WHERE hash IN %s GROUP BY 1",
                                       env$.mig092_inlist(inp$files$hash)))
    if (any(na$n > 1)) add("a PDF is more than one asset")

    if (!is.null(parsed)) {
      res <- dplyr::bind_rows(lapply(parsed, function(p) p$results))
      cat(sprintf("%d PDFs, %d cells, %d CH4 readings to import\n", nrow(inp$files), nrow(inp$values), nrow(res)))
      plan <- env$mig092_plan_registry(con, inp, parsed)
      got <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", env$.mig092_inlist(plan$alias$uuid)))$uuid
      if (mode == "pre" && length(got)) add("%d alias arm(s) already present", length(got))
      if (mode == "post" && length(got) < nrow(plan$alias)) add("%d of %d alias arms absent", nrow(plan$alias) - length(got), nrow(plan$alias))
      nf <- plan$new_features
      if (!setequal(nf$name, env$.mig092_new_features)) add("the planned new features are not %s",
                                                           paste(env$.mig092_new_features, collapse = ", "))
      self <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", env$.mig092_inlist(nf$self_uuid)))$uuid
      if (mode == "pre" && (any(nf$present) || length(self))) add("%d 092 feature(s) already present", sum(nf$present))
      if (mode == "post") {
        if (!all(nf$present) || length(self) != nrow(nf)) add("%d of %d 092 features (or their self aliases) absent",
                                                             sum(!nf$present), nrow(nf))
        f <- DBI::dbGetQuery(con, sprintf("SELECT name, site, matrix, date_start, date_end, lon, lat, geom_wkt, comments
          FROM feature WHERE uuid IN %s", env$.mig092_inlist(nf$uuid)))
        f <- f[match(nf$name, f$name), , drop = FALSE]
        if (any(f$site != "K" | f$matrix != "air" | !is.na(f$date_start) | format(as.Date(f$date_end)) != env$.mig092_new_feature_end |
                abs(f$lon - nf$lon) > 1e-9 | abs(f$lat - nf$lat) > 1e-9 | f$geom_wkt != nf$geom_wkt |
                !startsWith(f$comments, "UNLOCATED - placed at the K site centroid"), na.rm = TRUE) || anyNA(f$name))
          add("a 092 feature is not as planned (site K, air, unlocated at the K.centroid, date_end %s)", env$.mig092_new_feature_end)
      }
      bn <- plan$notes
      if (mode == "pre" && any(bn$present)) add("%d biofilter note(s) already present", sum(bn$present))
      if (mode == "post" && !all(bn$present)) add("%d of %d biofilter notes absent", sum(!bn$present), nrow(bn))
      pr <- env$mig092_registry_problems(con, plan)
      if (length(pr)) add("registry: %s", paste(pr, collapse = "; "))

      pd <- unique(env$mig092_planned_point_days(inp, parsed)[, c("feature", "day")])
      DBI::dbExecute(con, "CREATE OR REPLACE TEMP TABLE m092_pd (feature VARCHAR, day DATE)")
      DBI::dbAppendTable(con, "m092_pd", pd)
      stored <- DBI::dbGetQuery(con, sprintf("
        SELECT f.name AS feature, %s AS day, s.organisation, p.name AS project, a.value, a.quantified, a.rl_low
        FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
        JOIN m092_pd pd ON pd.feature = f.name AND pd.day = %s
        JOIN analysis a ON a.uuid_sample = s.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
        LEFT JOIN project p ON p.uuid = s.uuid_project
        WHERE lm.name = ?", env$.mig092_syd("coalesce(s.date, s.datetime)"), env$.mig092_syd("coalesce(s.date, s.datetime)")),
        params = list(env$.mig092_analyte_raw))
      if (mode == "pre") {
        if (nrow(stored)) add("%d planned point-day(s) already hold a CH4 reading, e.g. %s", nrow(stored),
                              paste(utils::head(paste(stored$feature, stored$day), 5), collapse = ", "))
      } else {
        res$feature <- env$.mig092_point_of(inp, res$feature_raw)
        res$day <- as.Date(sub("^.*!", "", res$lab_sample_id), format = "%Y%m%d")
        res$project <- res$work_order
        key <- function(d) paste(d$feature, format(as.Date(d$day)), d$project)
        if (any(stored$organisation != "ACIRL")) add("a CH4 reading at a planned point-day is not ACIRL")
        if (anyDuplicated(key(stored))) add("a planned point-day holds more than one CH4 reading")
        if (!setequal(key(stored), key(res))) add("stored CH4 point-days differ from the INPUT: %d stored, %d planned",
                                                 nrow(stored), nrow(res))
        # stored in L/L: the printed % v/v / 100; a zero is a non-detect with the method's limit
        m <- merge(data.frame(k = key(res), want = res$value_num * env$.mig092_to_canonical,
                              want_q = !res$below_detection & !grepl("^>", res$value_raw),
                              want_rl = res$rl * env$.mig092_to_canonical),
                   data.frame(k = key(stored), got = stored$value, got_q = stored$quantified, got_rl = stored$rl_low))
        if (nrow(m) != nrow(res) || any(abs(m$want - m$got) > 1e-12))
          add("stored CH4 values differ from the INPUT: %d of %d", sum(abs(m$want - m$got) > 1e-12), nrow(res))
        if (any(m$want_q != m$got_q)) add("%d stored quantified flags differ from the INPUT", sum(m$want_q != m$got_q))
        zr <- !is.na(m$want_rl)
        if (any(is.na(m$got_rl[zr]) | abs(m$got_rl[zr] - m$want_rl[zr]) > 1e-12))
          add("stored zero readings do not carry the method limit")
        if (!identical(DBI::dbGetQuery(con, "SELECT units FROM analyte WHERE name = 'CH4'")$units, "L/L"))
          add("analyte CH4 is no longer in L/L")
        if (env$.mig092_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", env$.mig092_actor) == 0)
          add("change_log holds no 092 rows")
        cat(sprintf("stored: %d CH4 readings at %d point-days\n", nrow(stored), nrow(pd)))
      }
    }
  }, error = function(e) add("db: %s", conditionMessage(e)), finally = DBI::dbDisconnect(con, shutdown = TRUE))
}
if (length(problems)) {
  cat(sprintf("FAIL (%s)\n", mode), paste0(" - ", problems, collapse = "\n"), "\n", sep = "")
  quit(status = 1)
}
cat(sprintf("PASS (%s)\n", mode))
