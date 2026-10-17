# Operator-run migration: delete the redundant second copy of the legacy ACIRL
# field readings on the legacy feature-days where ONE visit was filed under TWO
# ALS work orders and the SAME readings were loaded into both samples.
#
# Authorised by Robin, 2026-10-17 ("Fix those 16 legacy days"; the keep rule
# and the exclusions below are this file's proposal, for his review).
#
# ---- WHAT WAS MEASURED (live, marker 1026; scratchpad/2026-10-17-mig027/) -------
#
# scratchpad/2026-10-17-acirlmatch/DESIGN.md §1.3 lists 16 MERGED+MERGED
# feature + Sydney days: two samples, each under its own ALS work order, each
# holding ACIRL field readings (lab_method organisation ACIRL, method `field`,
# analyte not gas) AND its own order's ALS lab results. Every one of them is a
# Blaxland/Katoomba day on which ACIRL issued TWO field reports, one per ALS
# order (a routine "Quarterly"/"Monthly"/"Annual" report and a "Special
# Wednesday"/incident report; checked against the workbooks and pdfs in
# assets/unprocessed: each report cites exactly one of the two ES orders). So
# each sample's readings are the transcription of its own report, and the two
# copies are duplicates only where the two reports carry the same reading.
#
# Compared exactly (value, value_chr, quantified, rl_low, rl_high, purpose; the
# pairs share `uuid_lab`, so units are identical by construction):
#   * 7 days: every shared reading identical.
#   * 9 days: the copies DIFFER - two different readings, not a duplicate.
#     EXCLUDED (below), untouched.
# Of the 7, the keep rule settles 5 (16 rows); 2 are EXCLUDED as unsettled.
#
# ---- THE KEEP RULE (first test that discriminates wins) -------------------------
#
#   1 REPORT. A copy whose value its OWN work order's ACIRL report contradicts
#     is the redundant one: it was copied from the other report.
#   2 COMPLETE. Otherwise keep the copy on the sample holding the visit's
#     complete field set, so the visit's field readings stay on one sample.
#   3 TIME. Otherwise keep the copy on the sample at the observed visit time:
#     the legacy load put one order at the field-sheet time and its twin one
#     minute later to keep the two samples distinct (stated in its own sample
#     comments on 2023-06-14 and 2023-09-13), so the later time is fabricated.
#   None discriminates -> the day is EXCLUDED.
#
# DELETED (16 analyses; no sample loses all its analyses - each keeps its own
# order's ALS lab results - so no sample is deleted):
#   2022-06-22 B.S01, B.S03, B.S05  drop ES2222088 (+1 min), keep ES2222099   rule 3
#     (both reports print T/pH/EC identically: 2400-7222-06-03, 2400-7222-06-06)
#   2022-09-07 B.S01                drop ES2232312, keep ES2232317            rule 1
#     (both copies pH 7.04 = 2400-7222-09 / ES2232317; ES2232312's own report
#     2400-7222-09-01 reads pH 7.4)
#   2023-09-13 B.E01                drop ES2331527 (4), keep ES2331525 (5)    rule 2
#     (EC 518 is only in 2400-7286-09-01 / ES2331525; the 4 shared rows - T, pH,
#     Stage, Appearance - are in both reports. These 4 include two rows 025
#     split; 025's re-verify skips rows 027 deleted once marker 1027 exists.)
# The deleted 2022-06-22 copies carry analysis.comments "mod flow. clear" (the
# kept ones "clear"); that text is also their sample's `comments` (asserted),
# so nothing is lost.
#
# EXCLUDED, identical but unsettled (same time, both complete, both reports agree
# to their printed precision):
#   2022-09-07 B.S03  ES2232312 / ES2232317
#   2023-05-10 B.S01  ES2315749 / ES2315766
# EXCLUDED, the copies differ:
#   2022-09-07 B.S05  ES2232312 / ES2232317  Temperature 14.1 / 14.7
#   2022-09-07 B.S06  ES2232312 / ES2232317  pH, EC, Temperature
#   2023-05-10 B.S05  ES2315749 / ES2315766  pH, EC, Temperature
#   2023-06-14 B.S01  ES2320105 / ES2320129  pH, EC, Temperature
#   2023-06-14 B.S03  ES2320105 / ES2320129  pH, EC, Temperature
#   2023-09-13 B.S01  ES2331525 / ES2331527  Temperature, pH, EC (S01/S03 swapped)
#   2023-09-13 B.S03  ES2331525 / ES2331527  Temperature, pH, EC (S01/S03 swapped)
#   2023-09-13 B.S05  ES2331525 / ES2331527  Appearance Clear / Cloudy
#   2024-04-22 K.S09  ES2413139 / ES2413148  Temperature, pH
#
# The 16 deletes are ONE set-based `DELETE ... WHERE uuid IN (...)` (count
# asserted) with the change_log rows db_delete() would write beside it: duckdb
# 1.4.1 keeps a stale FK index key after per-row DELETE/UPDATE of analysis rows
# (024-026's pattern). Nothing references `analysis` by FK. One transaction:
# the database is either wholly pre-027 or wholly post-027. Everything else is
# checksummed before and after.
#
# BACKUP OF THE ROWS: `027-dedupe-legacy-field-readings-BACKUP-analysis.csv` (the
# 16 analyses as they were), plus the verified whole-file backup in `snapshot_dir`.
#
# Marker 1027. Requires 1026. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/027-dedupe-legacy-field-readings.R", envir = env)
#   env$mig027_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig027_marker_version <- 1027L
.mig027_requires <- 1026L
.mig027_name <- "027-dedupe-legacy-field-readings"
.mig027_actor <- .mig027_name

# The ACIRL field lab_methods involved: uuid -> (lab_method name, analyte name).
.mig027_lms <- data.frame(
  uuid = c("eaf02028-6d7a-47e4-a3ab-d5a26120585c", "5f77a675-a895-46b5-a800-ea7c11fea3d3",
           "d99b91ab-6eca-483e-be29-16233b3e1533", "6d11d0c5-9da8-4909-a69a-31ceab12aa50",
           "45c91544-e2f7-4782-b896-8e01c45d3959"),
  name = c("Electrical Conductivity", "Temperature", "pH", "Comments", "Flow observation"),
  analyte = c("EC", "Temperature", "pH", "Appearance", "Stage"),
  stringsAsFactors = FALSE)

.mig027_row <- function(uuid, uuid_sample, uuid_keep, uuid_sample_keep, uuid_lab, feat, day, wo_drop, wo_keep, analyte, rule) {
  data.frame(uuid = uuid, uuid_sample = uuid_sample, uuid_keep = uuid_keep, uuid_sample_keep = uuid_sample_keep,
             uuid_lab = uuid_lab, feat = feat, day = day, wo_drop = wo_drop, wo_keep = wo_keep,
             analyte = analyte, rule = rule, stringsAsFactors = FALSE)
}

# One row per deleted analysis (uuid) and the identical twin it leaves (uuid_keep).
.mig027_plan <- rbind(
  .mig027_row("6f7d322d-95d1-43ef-b175-4c9bdfe81a43", "7273420e-8ad2-4fc1-9a98-3dd9453b39c8", "413c9e29-aa6c-4bfe-818c-a589cb73e1c8", "43a29510-e7ac-4792-a0fa-815435b435f6", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2022-06-22", "ES2222088", "ES2222099", "EC", "time"),
  .mig027_row("3bdf0d2a-1d33-4e52-974a-98f39c285b2f", "7273420e-8ad2-4fc1-9a98-3dd9453b39c8", "645c0d0f-7e8c-49c4-b6b2-9010355631e1", "43a29510-e7ac-4792-a0fa-815435b435f6", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S01", "2022-06-22", "ES2222088", "ES2222099", "Temperature", "time"),
  .mig027_row("09ee8e1f-a889-4a57-97d6-eb8b7689dd55", "7273420e-8ad2-4fc1-9a98-3dd9453b39c8", "ddd520e3-670a-412e-8996-0ab45b4d588a", "43a29510-e7ac-4792-a0fa-815435b435f6", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S01", "2022-06-22", "ES2222088", "ES2222099", "pH", "time"),
  .mig027_row("1ff50419-2ebd-4341-8fc3-086af5ce1eab", "464487b5-40e0-4333-ae4f-644f314868ba", "f8314275-b730-48c3-ad88-670ea1ccc248", "fdd99afa-694a-46ca-a915-40b6c32ac4eb", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2022-06-22", "ES2222088", "ES2222099", "EC", "time"),
  .mig027_row("6a81c58d-f340-435e-a46a-20d4d30f4909", "464487b5-40e0-4333-ae4f-644f314868ba", "2836be6d-d5d1-4e6b-bbd1-583278cbc6e8", "fdd99afa-694a-46ca-a915-40b6c32ac4eb", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S03", "2022-06-22", "ES2222088", "ES2222099", "Temperature", "time"),
  .mig027_row("22368414-0e22-43cc-a34b-50bd3f3d9eb0", "464487b5-40e0-4333-ae4f-644f314868ba", "d1a1ae88-1a7d-44c5-9de6-6fea1b243392", "fdd99afa-694a-46ca-a915-40b6c32ac4eb", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S03", "2022-06-22", "ES2222088", "ES2222099", "pH", "time"),
  .mig027_row("f33c1a29-ca22-4550-983c-6adaf3c21f67", "e687eed8-5f7e-4bff-ad1d-97f4bf5b35c7", "bbb1240f-c495-4dc7-a104-eb1869a999d5", "09b04ca8-f645-4447-bfb4-4786d85fdd2a", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2022-06-22", "ES2222088", "ES2222099", "EC", "time"),
  .mig027_row("c3db7f47-0e23-4c65-b15b-1b852f9803e7", "e687eed8-5f7e-4bff-ad1d-97f4bf5b35c7", "328e93e3-b65c-443b-a7be-20b7680f35db", "09b04ca8-f645-4447-bfb4-4786d85fdd2a", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S05", "2022-06-22", "ES2222088", "ES2222099", "Temperature", "time"),
  .mig027_row("1a58e3ed-3b28-444a-93fe-72955e8253b1", "e687eed8-5f7e-4bff-ad1d-97f4bf5b35c7", "571e7558-7a2a-4656-b670-0f0365c4f1b3", "09b04ca8-f645-4447-bfb4-4786d85fdd2a", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S05", "2022-06-22", "ES2222088", "ES2222099", "pH", "time"),
  .mig027_row("df9b71c0-b223-433e-a533-a81e7d5bd92c", "f884ffd7-b303-42c3-b274-a61a94a819c7", "511827cf-03e6-45d4-95d4-2824c619b116", "0d2e1d09-abf0-449c-869e-aaf9666c5119", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2022-09-07", "ES2232312", "ES2232317", "EC", "report"),
  .mig027_row("326ff923-ce7c-4bf5-98b3-5e263554a170", "f884ffd7-b303-42c3-b274-a61a94a819c7", "dfeb0d06-6804-42e1-b600-ae302951117b", "0d2e1d09-abf0-449c-869e-aaf9666c5119", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S01", "2022-09-07", "ES2232312", "ES2232317", "Temperature", "report"),
  .mig027_row("146720bc-b64a-4789-8c98-0c9baa2c1d1d", "f884ffd7-b303-42c3-b274-a61a94a819c7", "639421fc-fe19-43ee-85cf-80355bfefc72", "0d2e1d09-abf0-449c-869e-aaf9666c5119", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S01", "2022-09-07", "ES2232312", "ES2232317", "pH", "report"),
  .mig027_row("ce2154d6-4f71-4974-a963-d83bc54b6f70", "8a014c89-af8e-4ce1-b4b1-7aae5c4dd445", "48498ef3-0d4a-4489-8cde-0ff4c10b65a6", "606bc6a8-7832-43df-a712-5bfccfd98fa1", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "B.E01", "2023-09-13", "ES2331527", "ES2331525", "Appearance", "complete"),
  .mig027_row("8d14a732-0533-4eb7-947a-2f22a8280532", "8a014c89-af8e-4ce1-b4b1-7aae5c4dd445", "759202b5-32a6-442c-a130-afcd734ef74d", "606bc6a8-7832-43df-a712-5bfccfd98fa1", "45c91544-e2f7-4782-b896-8e01c45d3959", "B.E01", "2023-09-13", "ES2331527", "ES2331525", "Stage", "complete"),
  .mig027_row("207115cf-bf0d-4324-9e9a-7b7faa7c9eba", "8a014c89-af8e-4ce1-b4b1-7aae5c4dd445", "cbe34ded-5a7f-486d-a181-5944e2500280", "606bc6a8-7832-43df-a712-5bfccfd98fa1", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.E01", "2023-09-13", "ES2331527", "ES2331525", "Temperature", "complete"),
  .mig027_row("af887ad5-9f94-40f6-a949-3ef2b777090e", "8a014c89-af8e-4ce1-b4b1-7aae5c4dd445", "d9ce2200-d9f1-46d0-b888-c25aa7bbba94", "606bc6a8-7832-43df-a712-5bfccfd98fa1", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.E01", "2023-09-13", "ES2331527", "ES2331525", "pH", "complete"))
.mig027_n <- 16L

.mig027_rule_text <- c(
  time = "rule 3: both copies identical, both reports agree, both samples complete; kept on the sample at the observed visit time (the legacy load put this order's twin one minute later)",
  report = "rule 1: both copies identical, but this order's own ACIRL report 2400-7222-09-01 reads pH 7.4; the stored 7.04 is the other report's (2400-7222-09 / ES2232317)",
  complete = "rule 2: the 4 shared copies identical; kept on the sample holding the visit's complete field set (EC 518 is only in 2400-7286-09-01 / ES2331525)")

.mig027_default <- function(x, default) if (is.null(x)) default else x
.mig027_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig027_fail <- function(msg) cli::cli_abort(paste0(.mig027_name, ": ", msg), class = "sampletidy_error")
.mig027_inlist <- function(ids) paste0("(", paste(sprintf("'%s'", ids), collapse = ", "), ")")
.mig027_same <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))
.mig027_syd_day <- function(x) format(x, tz = "Australia/Sydney", "%Y-%m-%d")

.mig027_deleted <- function() .mig027_plan$uuid
.mig027_kept <- function() .mig027_plan$uuid_keep
.mig027_samples_all <- function() unique(c(.mig027_plan$uuid_sample, .mig027_plan$uuid_sample_keep))

.mig027_analyses <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig027_inlist(ids)))
}
.mig027_samples <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf('SELECT s.*, f.name AS feat, p.name AS proj,
      (SELECT COUNT(*) FROM analysis a WHERE a.uuid_sample = s.uuid)::INTEGER AS n_analyses
    FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project
    WHERE s.uuid IN %s ORDER BY s.uuid', .mig027_inlist(ids)))
}
# Every ACIRL field (non-gas) analysis on the given samples.
.mig027_field_rows <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT a.uuid, a.uuid_sample FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE lm.organisation = 'ACIRL' AND lm.method = 'field' AND an.type IS DISTINCT FROM 'gas'
      AND a.uuid_sample IN %s ORDER BY a.uuid", .mig027_inlist(ids)))
}
# Samples at a feature + Sydney day holding ACIRL field (non-gas) readings.
.mig027_field_samples_on_day <- function(con, feat, day) {
  day_sql <- .ct_sydney_day_sql("s.date")
  DBI::dbGetQuery(con, sprintf("SELECT DISTINCT s.uuid FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    JOIN analysis a ON a.uuid_sample = s.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
    JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE f.name = ? AND %s = CAST(? AS DATE)
      AND lm.organisation = 'ACIRL' AND lm.method = 'field' AND an.type IS DISTINCT FROM 'gas'
    ORDER BY s.uuid", day_sql), params = list(feat, day))$uuid
}

.mig027_counts <- function(con) {
  tabs <- c("analysis", "sample", "lab_method", "feature_alias", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig027_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 027 must not touch.
.mig027_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig027_inlist(.mig027_deleted())))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig027_actor))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig027_lab_problem <- function(con) {
  lm <- DBI::dbGetQuery(con, sprintf("SELECT lm.uuid, lm.name, lm.organisation, lm.method, an.name AS analyte, an.type
    FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid IN %s", .mig027_inlist(.mig027_lms$uuid)))
  for (i in seq_len(nrow(.mig027_lms))) {
    w <- .mig027_lms[i, ]; r <- lm[lm$uuid == w$uuid, ]
    if (nrow(r) != 1L || !.mig027_same(r$name, w$name) || !.mig027_same(r$organisation, "ACIRL") || !.mig027_same(r$method, "field") ||
        !.mig027_same(r$analyte, w$analyte) || .mig027_same(r$type, "gas")) {
      return(sprintf("lab_method %s is not ACIRL field '%s' -> %s", substr(w$uuid, 1, 8), w$name, w$analyte))
    }
  }
  if (!all(.mig027_plan$uuid_lab %in% .mig027_lms$uuid)) return("a planned row's lab_method is not one of the five recorded")
  NULL
}

# The samples are where the plan says (feature, Sydney day, work order) and the
# kept ones are untouched by 027 in any way that could matter.
.mig027_sample_problem <- function(con) {
  S <- .mig027_samples(con, .mig027_samples_all())
  if (nrow(S) != length(.mig027_samples_all())) return("a planned sample is missing")
  for (i in seq_len(nrow(.mig027_plan))) {
    r <- .mig027_plan[i, ]
    d <- S[S$uuid == r$uuid_sample, ]; k <- S[S$uuid == r$uuid_sample_keep, ]
    tag <- sprintf("%s %s", r$feat, r$day)
    if (d$feat != r$feat || .mig027_syd_day(d$date) != r$day || !.mig027_same(d$proj, r$wo_drop)) return(paste(tag, "drop sample is not at that feature/day/order"))
    if (k$feat != r$feat || .mig027_syd_day(k$date) != r$day || !.mig027_same(k$proj, r$wo_keep)) return(paste(tag, "keep sample is not at that feature/day/order"))
  }
  NULL
}

.mig027_initial_problem <- function(con) {
  p <- .mig027_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig027_sample_problem(con); if (!is.null(p)) return(p)
  if (anyDuplicated(.mig027_plan$uuid) || anyDuplicated(.mig027_plan$uuid_keep) || nrow(.mig027_plan) != .mig027_n) return("the plan is malformed")
  D <- .mig027_analyses(con, .mig027_deleted()); K <- .mig027_analyses(con, .mig027_kept())
  if (nrow(D) != .mig027_n) return(sprintf("%d of the %d rows to delete exist", nrow(D), .mig027_n))
  if (nrow(K) != .mig027_n) return(sprintf("%d of the %d kept twins exist", nrow(K), .mig027_n))
  S <- .mig027_samples(con, unique(.mig027_plan$uuid_sample))
  for (i in seq_len(nrow(.mig027_plan))) {
    r <- .mig027_plan[i, ]; d <- D[D$uuid == r$uuid, ]; k <- K[K$uuid == r$uuid_keep, ]
    tag <- sprintf("%s %s %s %s", r$feat, r$day, r$analyte, substr(r$uuid, 1, 8))
    if (d$uuid_sample != r$uuid_sample || d$uuid_lab != r$uuid_lab) return(paste(tag, "is not on its sample / lab_method"))
    if (k$uuid_sample != r$uuid_sample_keep || k$uuid_lab != r$uuid_lab) return(paste(tag, "twin is not on the kept sample / lab_method"))
    for (f in c("value", "value_chr", "quantified", "rl_low", "rl_high", "purpose")) {
      if (!.mig027_same(d[[f]], k[[f]])) return(sprintf("%s differs from its twin in %s", tag, f))
    }
    # A comment on the deleted copy must survive in its sample's comments.
    if (!is.na(d$comments)) {
      sc <- S$comments[S$uuid == r$uuid_sample]
      if (is.na(sc) || !grepl(d$comments, sc, fixed = TRUE)) return(sprintf("%s comment '%s' is not in its sample's comments", tag, d$comments))
    }
  }
  # Completeness: the planned rows are ALL the ACIRL field readings on the drop
  # samples, and each feature-day holds exactly the two planned samples.
  fr <- .mig027_field_rows(con, unique(.mig027_plan$uuid_sample))
  if (!setequal(fr$uuid, .mig027_deleted())) return("the drop samples hold ACIRL field readings outside the plan")
  for (k in unique(paste(.mig027_plan$feat, .mig027_plan$day))) {
    r <- .mig027_plan[paste(.mig027_plan$feat, .mig027_plan$day) == k, ][1, ]
    got <- .mig027_field_samples_on_day(con, r$feat, r$day)
    if (!setequal(got, c(r$uuid_sample, r$uuid_sample_keep))) return(sprintf("%s does not hold exactly the two planned field-bearing samples", k))
  }
  # No sample may be emptied (each keeps its own order's lab results).
  for (u in unique(.mig027_plan$uuid_sample)) {
    n_left <- S$n_analyses[S$uuid == u] - sum(.mig027_plan$uuid_sample == u)
    if (n_left < 1L) return(sprintf("sample %s would be left with no analyses", substr(u, 1, 8)))
  }
  NULL
}

.mig027_done_problem <- function(con) {
  p <- .mig027_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig027_sample_problem(con); if (!is.null(p)) return(p)
  if (nrow(.mig027_analyses(con, .mig027_deleted())) != 0L) return("a deleted copy still exists")
  K <- .mig027_analyses(con, .mig027_kept())
  if (nrow(K) != .mig027_n) return(sprintf("%d of the %d kept twins exist", nrow(K), .mig027_n))
  for (i in seq_len(nrow(.mig027_plan))) {
    r <- .mig027_plan[i, ]; k <- K[K$uuid == r$uuid_keep, ]
    if (k$uuid_sample != r$uuid_sample_keep || k$uuid_lab != r$uuid_lab) return(sprintf("%s %s %s twin moved", r$feat, r$day, r$analyte))
  }
  if (nrow(.mig027_field_rows(con, unique(.mig027_plan$uuid_sample))) != 0L) return("a drop sample holds ACIRL field readings again")
  for (k in unique(paste(.mig027_plan$feat, .mig027_plan$day))) {
    r <- .mig027_plan[paste(.mig027_plan$feat, .mig027_plan$day) == k, ][1, ]
    got <- .mig027_field_samples_on_day(con, r$feat, r$day)
    if (!identical(got, r$uuid_sample_keep)) return(sprintf("%s holds ACIRL field readings on %d samples, not only the kept one", k, length(got)))
  }
  S <- .mig027_samples(con, unique(.mig027_plan$uuid_sample))
  if (any(S$n_analyses < 1L)) return("a drop sample has no analyses left")
  cl <- .mig027_scalar(con, sprintf("SELECT COUNT(*) FROM change_log WHERE actor = '%s' AND action = 'delete' AND tbl = 'analysis' AND uuid_row IN %s",
                                    .mig027_actor, .mig027_inlist(.mig027_deleted())))
  if (cl != .mig027_n) return(sprintf("%d of the %d delete change_log rows exist", cl, .mig027_n))
  NULL
}

.mig027_verify <- function(con) {
  p <- .mig027_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("027 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig027_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig027_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig027_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig027_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig027_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig027_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back$value_chr, as.character(out$value_chr)) ||
      !identical(back$comments, as.character(out$comments))) {
    cli::cli_abort("027: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig027_check_preconditions <- function(con) {
  if (.mig027_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig027_requires) == 0L) {
    .mig027_fail(sprintf("marker %d (026) is required first.", .mig027_requires))
  }
  p <- .mig027_initial_problem(con)
  if (!is.null(p)) .mig027_fail(sprintf("the database is not in the pre-027 state (%s). Nothing written.", p))
  invisible(TRUE)
}

.mig027_write <- function(con, recorded_at, sums_before) {
  db_transaction(con, function(con) {
    ids <- .mig027_deleted()
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig027_inlist(ids)))
    if (n != length(ids)) cli::cli_abort("027: set-based delete removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
    at <- Sys.time()
    for (i in seq_len(nrow(.mig027_plan))) {
      r <- .mig027_plan[i, ]
      .st_write_change_log(con, at = at, actor = .mig027_actor, action = "delete", tbl = "analysis",
                           uuid_row = r$uuid, field = NA_character_, old = r$uuid, new = NA_character_,
                           reason = sprintf("027: %s %s ACIRL field %s also stored on sample %s (%s) as analysis %s; redundant copy on sample %s (%s) deleted - %s",
                                            r$feat, r$day, r$analyte, r$uuid_sample_keep, r$wo_keep, r$uuid_keep,
                                            r$uuid_sample, r$wo_drop, .mig027_rule_text[[r$rule]]),
                           source_hash = NA_character_)
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig027_marker_version, recorded_at))
    .mig027_verify(con)
    if (!identical(sums_before, .mig027_checksum(con))) {
      cli::cli_abort("027 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig027_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig027_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig027_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("027 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    .mig027_check_preconditions(pre_con)
    list(analysis = .mig027_analyses(pre_con, .mig027_deleted()))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  days <- unique(paste(.mig027_plan$feat, .mig027_plan$day))
  logf("Plan: delete %d redundant ACIRL field analyses on %d feature-days (%s); no sample deleted.",
       nrow(.mig027_plan), length(days), paste(days, collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig027_write_csv(pre$analysis, file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig027_name)))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig027_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig027_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig027_check_preconditions(con)   # re-read under the write lock
    sums_before <- .mig027_checksum(con)
    .mig027_write(con, recorded_at, sums_before)
  }, db = db)

  logf("Committed: %d analyses deleted; marker %d.", nrow(.mig027_plan), .mig027_marker_version)
  logf("%s migrated successfully.", .mig027_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
