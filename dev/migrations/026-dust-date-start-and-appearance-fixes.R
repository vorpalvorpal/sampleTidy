# Operator-run migration: (A) give the four 7453-03 / 7453-08 legacy dust
# samples their exposure date in `date_start`, and (B) settle the legacy ACIRL
# `Appearance` rows that 025 left alone (its EXCLUDED pairs, its "no water /
# other" texts, and the K.S09 note its split dropped).
#
# Authorised by Robin, 2026-10-17 (rulings A, B1-B4, all approved).
#
# ---- A. DUST EXPOSURE DATES ----------------------------------------------------
#
# Dating convention (Robin, 2026-10-16; 015): EXPOSURE = `date_start`,
# COLLECTION = `date`. These four legacy samples hold date = date_start = the
# 1st of the COLLECTION month (asserted). The workbooks' Observations sheets
# (scratchpad/2026-10-17-a77dates/RESULTS.md: unique text, issue dates rule out
# the later month, values match legacy) give:
#   a0948ef0 B.D07, 3ff06304 B.D08  2400-7453-03  exposed 2025-02-01  collected 2025-03-01
#   f2b590d1 B.D07, c11dbd53 B.D08  2400-7453-08  exposed 2025-07-01  collected 2025-08-01
# `date` is untouched; `date_start` moves back one month.
#
# REPRESENTATION: Sydney midnight held as the UTC instant (the TIMESTAMP form
# every dust date / date_start uses, as 015-021 wrote them).
#
# `datetime_start` IS WRITTEN TOO, to the same instant: 021 (Robin, 2026-10-17)
# made `datetime_start` = `date_start` byte-for-byte on every dust sample, and
# 021's re-verify checks exactly that on all 122 - leaving it would leave these
# four with a stale exposure instant and make a re-run of 021 fail. `date` and
# `datetime` (the latter in 009's ux_sample_identity) are NOT written, so the
# index is never in the way: date_start / datetime_start / comments are in no
# index (ux_sample_identity is (uuid_feature_alias, datetime, uuid_project)),
# and 017 updated date_start with the index in place.
#
# ---- B. LEGACY ACIRL APPEARANCE ROWS (from 025's EXCLUDED csv and survey) -------
#
# B1  L.L01 / L.L02 2023-11-22 (ES2340624): the legacy load put the stage in the
#     Appearance row and the appearance in the Stage row. Swap `value_chr`
#     between each pair, written in the adapter's own terms
#     (`.st_acirl_split_observation()` of the other row's text, asserted):
#       L.L01 Appearance 97146a7d 'low Level' -> 'Slightly cloudy'; Stage 6ddea23b 'Slightly Cloudy' -> 'Low level'
#       L.L02 Appearance 3d0ac883 'Pooled'    -> 'Cloudy';          Stage 14c64fc4 'Cloudy'          -> 'Pooled'
#     value_chr only; neither row changes lab_method or sample.
# B2  B.S10 2024-08-07 (ES2425916): delete the legacy Appearance 11ec50bf 'Dry';
#     the Stage 'Dry' (68e98fec, pipeline, moved by 024) is kept.
# B3  The 22 legacy Appearance rows whose text records why there is no sample
#     ("Couldnt find", "Decomissioned", ...; the adapter emits neither Stage nor
#     Appearance for any of them, asserted): the text is appended to the
#     sample's `comments` (verbatim; "; " separator if comments is non-empty;
#     skipped if already contained), then the row is deleted. Each was its
#     sample's only analysis, so these 22 samples are left with no analyses
#     and the note in `comments` - deliberately: the sample is the record that
#     the visit happened and why nothing was taken.
# B4  K.S09 2024-03-04: 025 split "Mod flow, Clear. Only field data collected,
#     will be sampled in April" into Stage 'Mod flow' + Appearance 'Clear'; the
#     tail note is appended to the sample's comments, verbatim from 025's
#     change_log `old` (asserted present there).
#
# The 23 deletes (B2 + B3) are ONE set-based `DELETE ... WHERE uuid IN (...)`
# (count asserted) with the change_log rows db_delete() would write beside it:
# duckdb 1.4.1 keeps a stale FK index key after per-row DELETE/UPDATE of
# analysis rows (024/025's pattern). Every other write goes through
# db_update() (actor "026-dust-date-start-and-appearance-fixes"). One
# transaction: the database is either wholly pre-026 or wholly post-026.
# Everything else is checksummed before and after.
#
# 025's re-verify asserts its three EXCLUDED pairs untouched; it skips that
# check once marker 1026 exists (this file verifies them instead) - the
# 012/013 precedent.
#
# BACKUP OF THE ROWS: `026-dust-date-start-and-appearance-fixes-BACKUP-{analysis,sample}.csv`
# (the 27 analyses and 27 samples as they were), plus the verified whole-file
# backup in `snapshot_dir`.
#
# Marker 1026. Requires 1025. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/026-dust-date-start-and-appearance-fixes.R", envir = env)
#   env$mig026_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig026_marker_version <- 1026L
.mig026_requires <- 1025L
.mig026_name <- "026-dust-date-start-and-appearance-fixes"
.mig026_actor <- .mig026_name
.mig026_lm_app <- "6d11d0c5-9da8-4909-a69a-31ceab12aa50"    # ACIRL field "Comments" -> Appearance
.mig026_lm_stage <- "45c91544-e2f7-4782-b896-8e01c45d3959"  # ACIRL field "Flow observation" -> Stage

# A. Dust: `collected` is today's Sydney day of date, date_start, datetime and
# datetime_start; `exposed` becomes date_start and datetime_start.
.mig026_dust <- data.frame(
  uuid = c("a0948ef0-6a2e-4bb1-8d3e-337080cea1e1", "3ff06304-59e5-4e80-a9ea-9cddd72bf13d",
           "f2b590d1-420e-44dc-a0cd-1006de8b39c7", "c11dbd53-2707-4eb6-b4e1-b006baeadfa3"),
  gauge = c("B.D07", "B.D08", "B.D07", "B.D08"),
  report = c("2400-7453-03", "2400-7453-03", "2400-7453-08", "2400-7453-08"),
  collected = c("2025-03-01", "2025-03-01", "2025-08-01", "2025-08-01"),
  exposed = c("2025-02-01", "2025-02-01", "2025-07-01", "2025-07-01"),
  stringsAsFactors = FALSE)

# B1. The swapped pairs; new values are the adapter split of the OTHER row's text.
.mig026_swap <- data.frame(
  feat = c("L.L01", "L.L02"),
  uuid_sample = c("5e8b6bec-2f85-4e57-8371-8be37889386e", "b8420276-cb24-4d40-a820-3bb587328c0b"),
  uuid_app = c("97146a7d-04fb-494f-8a9c-091f2107cc86", "3d0ac883-521a-45f9-b1ca-1be1f6e7dff7"),
  uuid_stage = c("6ddea23b-8ed8-4a5a-8fd8-0ad0c26c0185", "14c64fc4-2b43-4c02-ab4e-bbe30ade78d8"),
  app_old = c("low Level", "Pooled"),
  stage_old = c("Slightly Cloudy", "Cloudy"),
  app_new = c("Slightly cloudy", "Cloudy"),
  stage_new = c("Low level", "Pooled"),
  stringsAsFactors = FALSE)
.mig026_swap_day <- "2023-11-22"

# B2. Redundant Appearance 'Dry' beside a Stage 'Dry'.
.mig026_dry <- list(uuid = "11ec50bf-b7a6-46ee-859d-6cbe4e6e800d", uuid_sample = "a1888b09-d660-49b2-a68a-6dba12e62073",
                    uuid_stage = "68e98fec-69d5-4ad3-bdd5-58e34000843f", feat = "B.S10", day = "2024-08-07",
                    value_chr = "Dry")

# B3. No-water texts (025 survey class "no water / other"; 22 rows).
.mig026_nw <- function(uuid, uuid_sample, feat, day, text) {
  data.frame(uuid = uuid, uuid_sample = uuid_sample, feat = feat, day = day, text = text, stringsAsFactors = FALSE)
}
.mig026_nowater <- rbind(
  .mig026_nw("4f233532-1877-4ac9-a39a-39c10559c63a", "4d459d3e-9b93-4c60-861f-4d7cb0099c55", "B.CW02", "2024-06-13", "Couldnt find"),
  .mig026_nw("a21cb56b-7efa-4cf7-a917-d4276e94e390", "4c2900e4-2779-44ff-925a-1b8d0581f7a7", "B.CW02", "2024-09-11", "Overgrown coulnt find"),
  .mig026_nw("b900f81c-2481-4cc7-9326-75d10486c67b", "30fc5565-28cf-4e9f-bb29-bb42ccfee2c7", "B.MW06", "2023-12-18", "Not located"),
  .mig026_nw("5ab7fb4f-6ff7-4305-9d16-6469bb53bbf9", "49fa5c4d-20ed-47ab-b08b-7a574e147321", "B.MW06", "2024-03-18", "Cant locate"),
  .mig026_nw("0a9dfad4-385d-452d-afc2-16b4e913ee33", "5c68387a-a25b-4eb9-88e8-ab6432d62256", "B.MW06", "2024-06-13", "Can not locate due to long grass"),
  .mig026_nw("cf5c0cfa-5c20-4218-b29c-d571be1f66c4", "ae12bf6d-c019-4a6a-be5b-0b2ff788a5bd", "B.MW06", "2024-09-11", "No Access snakes"),
  .mig026_nw("c267a31b-980a-4c15-b797-0f845b4d34e8", "0b476f20-0f89-4ef3-8abf-b93517a5fa5f", "B.MW07", "2024-09-11", "Overgrown coulnt find"),
  .mig026_nw("9e07c199-cfd8-4fb2-adea-0bec644aa62b", "547f9199-ff69-4c94-89aa-0ba60e166617", "B.MW10", "2023-12-18", "Not there"),
  .mig026_nw("543d83c3-adc3-4720-bc2a-1666b8ee28b0", "9355f6f0-7052-435e-99a5-d298a523a11a", "B.S03", "2024-09-11", "No Access"),
  .mig026_nw("252b00dd-bcf3-4dba-9edb-fff9ab8fbee7", "16c13675-7f0c-46a2-bfa7-f990c09599d6", "B.S12", "2024-05-09", "No longer exist"),
  .mig026_nw("f6b7ed7f-7c04-4195-9ed4-7d3f400fbdb6", "8ca3d38a-d3fb-475f-8367-8bb82285d3f7", "B.S12", "2024-07-11", "Decomissioned"),
  .mig026_nw("383ec410-7be0-4209-9ac4-3f65525dc19d", "2ae5e48b-f73d-47e8-ab6a-a80e299c46d8", "B.S12", "2024-08-07", "Decomissoned"),
  .mig026_nw("7520be8b-128b-4af4-b116-edea3ffeeb42", "2d25aa09-f243-4f0c-b348-a1ee185eb176", "B.S12", "2024-09-11", "Decomisison"),
  .mig026_nw("63cc5d7d-ddb5-4a83-9dba-bdf911db8e63", "1e7ff559-6fc6-4991-acd1-88bc14eb13cf", "BH.MW02", "2024-05-29", "No sample due to snakes and over grown grass"),
  .mig026_nw("fcf8b32f-2603-4a81-aad4-0b95eef5b126", "6b6d97b0-aac2-47ab-9965-99f107cf7567", "BH.MW05", "2024-05-29", "No sample due to snakes and over grown grass"),
  .mig026_nw("0cae0bc2-f0e9-4bda-835d-3515b479f0f1", "0c6e3e3f-90e8-4487-9bf0-cdf2b213d05c", "K.L01", "2024-03-04", "Samplers could not find site, will be sampled in April"),
  .mig026_nw("16ebf228-3b34-4cf1-94ce-30427500e762", "e1e312b6-0b1d-4397-b8d1-2e95a9d119a8", "K.L05", "2024-06-19", "No Sample"),
  .mig026_nw("b97e4c6f-4816-4bd0-8a70-bcc6453416f2", "9151650b-e8aa-45d9-a9ca-5dc0f3b6d282", "K.MW02", "2023-12-19", "Could not find due to long grass"),
  .mig026_nw("a0062034-dbb5-4a2c-ba3c-9606b446f6b0", "ec912bbe-7221-4e6f-b600-0df57198add8", "K.MW02", "2024-06-19", "Couldn’t be found"),
  .mig026_nw("f291ec93-42c2-4bd1-ab1a-ec85b3d442cc", "9fd7afad-8606-4833-b144-40416e2be90e", "K.MW12", "2023-12-19", "Could not find due to long grass"),
  .mig026_nw("09ce79f3-0711-4b2d-b87a-7472d8167eb1", "65daa096-992a-4669-90f1-0b4506fc0486", "K.MW12", "2024-06-19", "Couldn’t be found"),
  .mig026_nw("836ba345-fd39-40e1-a385-f8ac4d91e605", "c6e46ca5-6a16-4420-a209-b1fb4ae386bb", "K.S10", "2024-02-22", "No Location"))
.mig026_nowater_n <- 22L

# B4. K.S09 2024-03-04: the note 025's split dropped.
.mig026_ks09 <- list(uuid_sample = "253391ad-2376-430c-950f-88f627aaf895", uuid_app = "8f960e8b-8a00-470f-a738-9693cc05cf8d",
                     feat = "K.S09", day = "2024-03-04",
                     legacy = "Mod flow, Clear. Only field data collected, will be sampled in April",
                     note = "Only field data collected, will be sampled in April")

.mig026_default <- function(x, default) if (is.null(x)) default else x
.mig026_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig026_fail <- function(msg) cli::cli_abort(paste0(.mig026_name, ": ", msg), class = "sampletidy_error")
.mig026_inlist <- function(ids) paste0("(", paste(sprintf("'%s'", ids), collapse = ", "), ")")
.mig026_same <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))
.mig026_sydney_midnight <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney")
.mig026_syd_day <- function(x) format(x, tz = "Australia/Sydney", "%Y-%m-%d")
.mig026_split <- function(txt) .st_acirl_split_observation(stringr::str_squish(txt))

# The comments a note-append produces (NULL-safe, never duplicates).
.mig026_append <- function(old, note) {
  if (is.na(old) || !nzchar(trimws(old))) return(note)
  if (grepl(note, old, fixed = TRUE)) return(old)
  paste(old, note, sep = "; ")
}

.mig026_deleted <- function() c(.mig026_dry$uuid, .mig026_nowater$uuid)
.mig026_touched_analyses <- function() c(.mig026_swap$uuid_app, .mig026_swap$uuid_stage, .mig026_deleted())
.mig026_comment_samples <- function() c(.mig026_nowater$uuid_sample, .mig026_ks09$uuid_sample)
.mig026_touched_samples <- function() c(.mig026_dust$uuid, .mig026_comment_samples())

.mig026_analyses <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig026_inlist(ids)))
}
.mig026_samples <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf('SELECT s.*, f.name AS feat FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN %s ORDER BY s.uuid', .mig026_inlist(ids)))
}

.mig026_counts <- function(con) {
  tabs <- c("analysis", "sample", "lab_method", "feature_alias", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig026_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 026 must not touch.
.mig026_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "sample", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig026_inlist(.mig026_touched_analyses())))
  out$analysis_touched_fixed <- q(sprintf("SELECT uuid, uuid_sample, uuid_lab, value, quantified, rl_low, rl_high, purpose, comments
    FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig026_inlist(c(.mig026_swap$uuid_app, .mig026_swap$uuid_stage))))
  out$sample_rest <- q(sprintf('SELECT * FROM "sample" WHERE uuid NOT IN %s ORDER BY uuid', .mig026_inlist(.mig026_touched_samples())))
  out$sample_dust_fixed <- q(sprintf('SELECT * EXCLUDE (date_start, datetime_start) FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig026_inlist(.mig026_dust$uuid)))
  out$sample_comment_fixed <- q(sprintf('SELECT * EXCLUDE (comments) FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig026_inlist(.mig026_comment_samples())))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig026_actor))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig026_lab_problem <- function(con) {
  lm <- DBI::dbGetQuery(con, "SELECT lm.uuid, lm.name, lm.organisation, lm.method, an.name AS analyte
    FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid IN (?, ?)",
    params = list(.mig026_lm_app, .mig026_lm_stage))
  a <- lm[lm$uuid == .mig026_lm_app, ]; s <- lm[lm$uuid == .mig026_lm_stage, ]
  if (nrow(a) != 1L || a$name != "Comments" || a$organisation != "ACIRL" || a$analyte != "Appearance") return("lab_method 6d11d0c5 is not ACIRL Comments -> Appearance")
  if (nrow(s) != 1L || s$name != "Flow observation" || s$organisation != "ACIRL" || s$analyte != "Stage") return("lab_method 45c91544 is not ACIRL Flow observation -> Stage")
  NULL
}

# The adapter's terms the rulings rely on (code, not data - re-proved every run).
.mig026_adapter_problem <- function() {
  for (i in seq_len(nrow(.mig026_swap))) {
    r <- .mig026_swap[i, ]
    a <- .mig026_split(r$stage_old); s <- .mig026_split(r$app_old)
    if (!is.na(a$stage) || !.mig026_same(a$appearance, r$app_new)) return(sprintf("the adapter splits '%s' as (%s, %s), not Appearance '%s'", r$stage_old, a$stage, a$appearance, r$app_new))
    if (!.mig026_same(s$stage, r$stage_new) || !is.na(s$appearance)) return(sprintf("the adapter splits '%s' as (%s, %s), not Stage '%s'", r$app_old, s$stage, s$appearance, r$stage_new))
  }
  for (t in unique(.mig026_nowater$text)) {
    sp <- .mig026_split(t)
    if (!is.na(sp$stage) || !is.na(sp$appearance)) return(sprintf("the adapter now reads no-water text '%s' as (%s, %s)", t, sp$stage, sp$appearance))
  }
  sp <- .mig026_split(.mig026_dry$value_chr)
  if (!.mig026_same(sp$stage, "Dry") || !is.na(sp$appearance)) return("the adapter no longer reads 'Dry' as Stage only")
  NULL
}

.mig026_dust_problem <- function(con, done) {
  S <- .mig026_samples(con, .mig026_dust$uuid)
  if (nrow(S) != nrow(.mig026_dust)) return("a dust sample is missing")
  for (i in seq_len(nrow(.mig026_dust))) {
    tg <- .mig026_dust[i, ]; r <- S[S$uuid == tg$uuid, ]
    tag <- sprintf("%s %s (%s)", tg$gauge, substr(tg$uuid, 1, 8), tg$report)
    if (r$feat != tg$gauge) return(paste(tag, "is not at its gauge"))
    coll <- as.numeric(.mig026_sydney_midnight(tg$collected))
    want_start <- as.numeric(.mig026_sydney_midnight(if (done) tg$exposed else tg$collected))
    if (anyNA(c(r$date, r$datetime, r$date_start, r$datetime_start))) return(paste(tag, "has a NULL date"))
    if (as.numeric(r$date) != coll || as.numeric(r$datetime) != coll) return(paste(tag, "date / datetime is not collection", tg$collected))
    if (as.numeric(r$date_start) != want_start || as.numeric(r$datetime_start) != want_start) {
      return(sprintf("%s date_start / datetime_start is %s / %s, expected %s", tag, .mig026_syd_day(r$date_start),
                     .mig026_syd_day(r$datetime_start), if (done) tg$exposed else tg$collected))
    }
  }
  # Each uuid prefix the ruling named resolves to exactly one sample.
  for (p in substr(.mig026_dust$uuid, 1, 8)) {
    if (.mig026_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid LIKE '%s%%'", p)) != 1L) return(sprintf("prefix %s does not resolve to exactly one sample", p))
  }
  NULL
}

# Swapped pairs: before = legacy values, after = adapter terms.
.mig026_swap_problem <- function(con, done) {
  A <- .mig026_analyses(con, c(.mig026_swap$uuid_app, .mig026_swap$uuid_stage))
  S <- .mig026_samples(con, .mig026_swap$uuid_sample)
  for (i in seq_len(nrow(.mig026_swap))) {
    r <- .mig026_swap[i, ]; a <- A[A$uuid == r$uuid_app, ]; s <- A[A$uuid == r$uuid_stage, ]; sm <- S[S$uuid == r$uuid_sample, ]
    if (nrow(a) != 1L || nrow(s) != 1L || nrow(sm) != 1L) return(paste(r$feat, "pair or sample missing"))
    if (sm$feat != r$feat || .mig026_syd_day(sm$date) != .mig026_swap_day) return(paste(r$feat, "sample is not at that feature on that day"))
    if (a$uuid_lab != .mig026_lm_app || s$uuid_lab != .mig026_lm_stage || a$uuid_sample != r$uuid_sample || s$uuid_sample != r$uuid_sample) return(paste(r$feat, "pair is not Appearance + Stage on its sample"))
    wa <- if (done) r$app_new else r$app_old; ws <- if (done) r$stage_new else r$stage_old
    if (!.mig026_same(a$value_chr, wa) || !.mig026_same(s$value_chr, ws)) return(sprintf("%s pair is ('%s', '%s'), expected ('%s', '%s')", r$feat, a$value_chr, s$value_chr, wa, ws))
    n <- DBI::dbGetQuery(con, "SELECT uuid_lab, COUNT(*) AS n FROM analysis WHERE uuid_sample = ? AND uuid_lab IN (?, ?) GROUP BY uuid_lab",
                         params = list(r$uuid_sample, .mig026_lm_app, .mig026_lm_stage))
    if (nrow(n) != 2L || any(n$n != 1L)) return(paste(r$feat, "sample does not hold exactly one Appearance and one Stage"))
  }
  NULL
}

.mig026_delete_problem <- function(con, done) {
  A <- .mig026_analyses(con, .mig026_deleted())
  st <- .mig026_analyses(con, .mig026_dry$uuid_stage)
  if (nrow(st) != 1L || st$uuid_lab != .mig026_lm_stage || st$uuid_sample != .mig026_dry$uuid_sample || !.mig026_same(st$value_chr, "Dry")) return("B.S10 Stage 'Dry' 68e98fec is not as recorded")
  if (done) {
    if (nrow(A) != 0L) return("a B2/B3 Appearance row still exists")
    return(NULL)
  }
  if (nrow(A) != length(.mig026_deleted())) return(sprintf("%d of the %d rows to delete exist", nrow(A), length(.mig026_deleted())))
  d <- A[A$uuid == .mig026_dry$uuid, ]
  if (d$uuid_lab != .mig026_lm_app || d$uuid_sample != .mig026_dry$uuid_sample || !.mig026_same(d$value_chr, .mig026_dry$value_chr)) return("B.S10 Appearance 11ec50bf is not as recorded")
  S <- .mig026_samples(con, .mig026_nowater$uuid_sample)
  if (nrow(S) != .mig026_nowater_n) return("a no-water sample is missing")
  for (i in seq_len(nrow(.mig026_nowater))) {
    r <- .mig026_nowater[i, ]; a <- A[A$uuid == r$uuid, ]; s <- S[S$uuid == r$uuid_sample, ]
    tag <- sprintf("%s %s %s", r$feat, r$day, substr(r$uuid, 1, 8))
    if (a$uuid_lab != .mig026_lm_app || a$uuid_sample != r$uuid_sample || !.mig026_same(a$value_chr, r$text)) return(paste(tag, "is not the recorded no-water Appearance row"))
    if (!(is.na(a$value) && is.na(a$quantified) && is.na(a$rl_low) && is.na(a$rl_high) && is.na(a$comments))) return(paste(tag, "carries more than the text"))
    if (s$feat != r$feat || .mig026_syd_day(s$date) != r$day) return(paste(tag, "sample is not at that feature on that day"))
  }
  NULL
}

.mig026_ks09_problem <- function(con) {
  s <- .mig026_samples(con, .mig026_ks09$uuid_sample)
  if (nrow(s) != 1L || s$feat != .mig026_ks09$feat || .mig026_syd_day(s$date) != .mig026_ks09$day) return("K.S09 2024-03-04 sample is not as recorded")
  cl <- DBI::dbGetQuery(con, "SELECT old FROM change_log WHERE actor = '025-split-legacy-appearance' AND action = 'update'
    AND uuid_row = ? AND field = 'value_chr'", params = list(.mig026_ks09$uuid_app))
  if (nrow(cl) != 1L || !identical(cl$old, .mig026_ks09$legacy) || !grepl(.mig026_ks09$note, cl$old, fixed = TRUE)) return("025's change_log old value for K.S09 8f960e8b is not the recorded legacy text")
  a <- .mig026_analyses(con, .mig026_ks09$uuid_app)
  if (nrow(a) != 1L || a$uuid_sample != .mig026_ks09$uuid_sample) return("K.S09 Appearance 8f960e8b is not on its sample")
  NULL
}

# The comments each comment-sample must end with, computed from what it holds now.
.mig026_comment_plan <- function(con) {
  S <- .mig026_samples(con, .mig026_comment_samples())
  notes <- rbind(data.frame(uuid_sample = .mig026_nowater$uuid_sample, note = .mig026_nowater$text, stringsAsFactors = FALSE),
                 data.frame(uuid_sample = .mig026_ks09$uuid_sample, note = .mig026_ks09$note, stringsAsFactors = FALSE))
  if (anyDuplicated(notes$uuid_sample)) .mig026_fail("a sample receives two notes.")
  notes$old <- S$comments[match(notes$uuid_sample, S$uuid)]
  notes$new <- mapply(.mig026_append, notes$old, notes$note, USE.NAMES = FALSE)
  notes
}

.mig026_comments_done_problem <- function(con) {
  S <- .mig026_samples(con, .mig026_comment_samples())
  if (nrow(S) != length(.mig026_comment_samples())) return("a comment sample is missing")
  notes <- c(.mig026_nowater$text, .mig026_ks09$note)
  for (i in seq_along(notes)) {
    c <- S$comments[S$uuid == .mig026_comment_samples()[[i]]]
    if (is.na(c) || !grepl(notes[[i]], c, fixed = TRUE)) return(sprintf("sample %s comments lack '%s'", substr(.mig026_comment_samples()[[i]], 1, 8), notes[[i]]))
  }
  NULL
}

.mig026_initial_problem <- function(con) {
  for (p in list(.mig026_lab_problem(con), .mig026_adapter_problem(), .mig026_dust_problem(con, FALSE),
                 .mig026_swap_problem(con, FALSE), .mig026_delete_problem(con, FALSE), .mig026_ks09_problem(con))) {
    if (!is.null(p)) return(p)
  }
  NULL
}

.mig026_done_problem <- function(con) {
  for (p in list(.mig026_lab_problem(con), .mig026_dust_problem(con, TRUE), .mig026_swap_problem(con, TRUE),
                 .mig026_delete_problem(con, TRUE), .mig026_ks09_problem(con), .mig026_comments_done_problem(con))) {
    if (!is.null(p)) return(p)
  }
  NULL
}

.mig026_verify <- function(con) {
  p <- .mig026_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("026 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig026_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig026_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig026_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig026_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig026_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig026_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  chk <- if ("value_chr" %in% names(out)) "value_chr" else "comments"
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back[[chk]], as.character(out[[chk]]))) {
    cli::cli_abort("026: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig026_check_preconditions <- function(con) {
  if (.mig026_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig026_requires) == 0L) {
    .mig026_fail(sprintf("marker %d (025) is required first.", .mig026_requires))
  }
  p <- .mig026_initial_problem(con)
  if (!is.null(p)) .mig026_fail(sprintf("the database is not in the pre-026 state (%s). Nothing written.", p))
  invisible(TRUE)
}

.mig026_write <- function(con, recorded_at, sums_before) {
  notes <- .mig026_comment_plan(con)
  db_transaction(con, function(con) {
    # A. Dust exposure dates.
    for (i in seq_len(nrow(.mig026_dust))) {
      tg <- .mig026_dust[i, ]; x <- .mig026_sydney_midnight(tg$exposed)
      db_update(con, "sample", uuid = tg$uuid, changes = list(date_start = x, datetime_start = x), actor = .mig026_actor,
                reason = sprintf("026 (ruling A, Robin 2026-10-17): dust %s %s exposed %s, collected %s (date kept) per the workbook Observations; datetime_start = date_start as 021",
                                 tg$gauge, tg$report, tg$exposed, tg$collected))
    }
    # B1. Swap.
    for (i in seq_len(nrow(.mig026_swap))) {
      r <- .mig026_swap[i, ]
      db_update(con, "analysis", uuid = r$uuid_app, changes = list(value_chr = r$app_new), actor = .mig026_actor,
                reason = sprintf("026 (ruling B1): %s %s Appearance held the stage '%s' and Stage held the appearance '%s'; swapped to the ACIRL adapter's terms (Stage analysis %s now '%s')",
                                 r$feat, .mig026_swap_day, r$app_old, r$stage_old, r$uuid_stage, r$stage_new))
      db_update(con, "analysis", uuid = r$uuid_stage, changes = list(value_chr = r$stage_new), actor = .mig026_actor,
                reason = sprintf("026 (ruling B1): %s %s Stage held the appearance '%s' and Appearance held the stage '%s'; swapped to the ACIRL adapter's terms (Appearance analysis %s now '%s')",
                                 r$feat, .mig026_swap_day, r$stage_old, r$app_old, r$uuid_app, r$app_new))
    }
    # B3 / B4. Notes into sample.comments (before the rows carrying them go).
    for (i in seq_len(nrow(notes))) {
      n <- notes[i, ]
      if (.mig026_same(n$old, n$new)) next
      db_update(con, "sample", uuid = n$uuid_sample, changes = list(comments = n$new), actor = .mig026_actor,
                reason = if (n$uuid_sample == .mig026_ks09$uuid_sample) {
                  sprintf("026 (ruling B4): K.S09 2024-03-04 note dropped by 025's split of legacy Appearance '%s' (analysis %s)", .mig026_ks09$legacy, .mig026_ks09$uuid_app)
                } else {
                  r <- .mig026_nowater[.mig026_nowater$uuid_sample == n$uuid_sample, ]
                  sprintf("026 (ruling B3): %s %s no-water text from legacy Appearance analysis %s (deleted by 026) moved to sample comments", r$feat, r$day, r$uuid)
                })
    }
    # B2 + B3. ONE set-based delete, with db_delete()'s change_log rows.
    ids <- .mig026_deleted()
    old <- .mig026_analyses(con, ids)
    if (nrow(old) != length(ids) || any(old$uuid_lab != .mig026_lm_app)) cli::cli_abort("026: the rows to delete are not the planned Appearance rows.", class = "sampletidy_error")
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig026_inlist(ids)))
    if (n != length(ids)) cli::cli_abort("026: set-based delete removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
    at <- Sys.time()
    .st_write_change_log(con, at = at, actor = .mig026_actor, action = "delete", tbl = "analysis",
                         uuid_row = .mig026_dry$uuid, field = NA_character_, old = .mig026_dry$uuid, new = NA_character_,
                         reason = sprintf("026 (ruling B2): B.S10 2024-08-07 legacy Appearance 'Dry' is a stage, already held by Stage analysis %s 'Dry'", .mig026_dry$uuid_stage),
                         source_hash = NA_character_)
    for (i in seq_len(nrow(.mig026_nowater))) {
      r <- .mig026_nowater[i, ]
      .st_write_change_log(con, at = at, actor = .mig026_actor, action = "delete", tbl = "analysis",
                           uuid_row = r$uuid, field = NA_character_, old = r$uuid, new = NA_character_,
                           reason = sprintf("026 (ruling B3): %s %s legacy Appearance '%s' records why there is no sample, not an appearance; text kept in sample %s comments",
                                            r$feat, r$day, r$text, r$uuid_sample),
                           source_hash = NA_character_)
    }

    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig026_marker_version, recorded_at))
    .mig026_verify(con)
    if (!identical(sums_before, .mig026_checksum(con))) {
      cli::cli_abort("026 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig026_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig026_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig026_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("026 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    .mig026_check_preconditions(pre_con)
    list(analysis = .mig026_analyses(pre_con, .mig026_touched_analyses()),
         sample = DBI::dbGetQuery(pre_con, sprintf('SELECT * FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig026_inlist(.mig026_touched_samples()))),
         notes = .mig026_comment_plan(pre_con))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: A %d dust date_start (+datetime_start) back one month; B1 %d Appearance/Stage pairs swapped; B2 1 + B3 %d Appearance rows deleted; %d sample comments appended (B3 + B4 K.S09).",
       nrow(.mig026_dust), nrow(.mig026_swap), nrow(.mig026_nowater), sum(!mapply(.mig026_same, pre$notes$old, pre$notes$new)))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig026_write_csv(pre$analysis, file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig026_name)))
  .mig026_write_csv(pre$sample, file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig026_name)))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig026_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig026_default(.now, Sys.time())

  with_db_write(function(con) {
    .mig026_check_preconditions(con)   # re-read under the write lock
    sums_before <- .mig026_checksum(con)
    .mig026_write(con, recorded_at, sums_before)
  }, db = db)

  logf("Committed: %d dust date_start, %d analyses re-valued, %d analyses deleted, sample comments appended; marker %d.",
       nrow(.mig026_dust), 2L * nrow(.mig026_swap), length(.mig026_deleted()), .mig026_marker_version)
  logf("%s migrated successfully.", .mig026_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
