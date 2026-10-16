# Operator-run migration: repair the 2021-22 legacy dust block (B.D07 and B.D08),
# whose dates disagree with ACIRL's workbooks.
#
# STATUS: DRAFTED AND REHEARSED, NOT APPLIED. Robin's ruling (2026-10-16) is
# "workbook wins; re-date", with "report before applying". Nothing here has
# touched the live database. See dev/MIGRATIONS.md.
#
# Dating convention (Robin, 2026-10-16; 015): EXPOSURE date = `date_start`,
# COLLECTION date = `date`. Gauges go out on the 1st and come in on the 1st of
# the next month.
#
# ---- WHAT THE EVIDENCE SAYS (scratchpad: Part B lineup) -------------------
#
# Sources that cover 2020-09..2022-07, every one found (assets/ was searched for
# any dust table, xls or pdf):
#   DB  "Blaxland WMF Dust Results Database.xlsx" (2400-6852/6989, exposures
#       Jul-2019..Dec-2020, 2 dp, with exposure + collection dates)
#   P6  2400-7127-06 pdf (exposures Mar-May 2021, 1 dp)
#   P7  2400-7127-07 pdf (exposures Jun-Aug 2021, 1 dp)
#   W1  2400-7127-01-02 xls = ACIRL 2400-7222-01-02 (exposures Sep-21, Dec-21;
#       2 dp; its pdf prints the same at 1 dp)
#   W3  2400-7127-03-02 xls = ACIRL 2400-7222-03-02 (exposures Jan-22, Feb-22)
# Nothing covers exposures Jan-21, Feb-21, Oct-21, Nov-21 or Mar-22..Jul-22.
#
# Every legacy row in the block has date == date_start (one date). Two loads
# are visible, told apart on the four same-day pairs by `datetime` (01:01 vs
# 01:00 UTC - the loader nudged one of each pair by a minute):
#
#   LOAD A (2020-09..2021-07, plus the 01:01 rows of 2021-08/-09): the stored
#   date is the COLLECTION month, both gauges, every sourced row (DB, P6, P7).
#   `date` is therefore already right; `date_start` is one month late. Not
#   touched here (it does not affect matching; flagged for a later ruling).
#
#   LOAD B (the 01:00 rows of 2021-08 onward, 12 per gauge for the 12 labels
#   Aug-21..Jul-22, but only 11 exposure months Sep-21..Jul-22 exist):
#     B.D08: stored date = EXPOSURE month on all 4 sourced rows (Sep, Dec, Jan,
#            Feb). So `date_start` is right and `date` is one month early.
#            Its 12th row, bb955fc9 at Aug-21 (1.0/0.4/0.6), is no B.D08 value
#            (B.D08 Aug-21 is 1.7/0.4/1.3, P7, held by 9708cb86); it is exactly
#            B.D07's Aug-21 (P7, held by 145bd575) - a wrong-gauge copy.
#     B.D07: stored ONE MONTH EARLY for Sep-21..Feb-22 (sourced: Sep at Aug,
#            Jan at Dec, Feb at Jan; Dec sits at Oct - see below), then a 12th
#            row bcf15e0f at Feb-22 (1.0/0.5/0.5) which is W3's Feb-22
#            (0.99/0.49/0.5) at 1 dp - the same measurement twice - and
#            from Mar-22 the labels are exposure months again. The shift cannot
#            run past Feb-22: shifting Jul-22 (4.8) to Aug-22 would collide with
#            the sourced Aug-22 (1.58, 2400-7222-11-04, 941a09bd).
#   So each gauge's load B has exactly one spurious row, and each is a copy.
#
#   The four same-day pairs are NOT duplicates of each other: each is one
#   LOAD-A row (01:01) and one LOAD-B row (01:00) landing on the same label.
#     B.D07 2021-08  0924301a = Jul-21 (P7)    | 78674243 = Sep-21 (W1, 1 dp)
#     B.D07 2021-09  145bd575 = Aug-21 (P7)    | 23110556 = no source
#     B.D08 2021-08  ca99940b = Jul-21 (P7)    | bb955fc9 = B.D07 Aug-21 copy
#     B.D08 2021-09  9708cb86 = Aug-21 (P7)    | 83fa60f2 = Sep-21 (W1)
#
# ---- WHAT 016 DOES --------------------------------------------------------
#
# (1) RE-DATE 22 load-B samples to exposure/collection:
#   B.D07, workbook-proven: 78674243 Sep-21, e034e78a Dec-21, 494a0147 Jan-22,
#     5a795c13 Feb-22. e034e78a (2.2/1.2/1.0) sits TWO months early, not one:
#     its values are W1's Dec-21 at 1 dp, and the only other candidate rows
#     (Sep 1.8, Nov 0.9) match nothing.
#   B.D07, NO WORKBOOK - placed by elimination, FLAGGED: 23110556 (1.8/0.8/1.0)
#     -> Oct-21 and f5c09052 (0.9/0.5/0.4) -> Nov-21, the two months left
#     between Sep and Dec, in stored order. The order is an assumption.
#   B.D07, NO WORKBOOK, exposure month kept, collection set +1 month, FLAGGED:
#     31e8affa Mar-22, 5ae2e450 Apr-22, da14dd5c May-22, 808e817a Jun-22,
#     919c8665 Jul-22.
#   B.D08, workbook-proven, collection set +1 month: 83fa60f2 Sep-21,
#     d25cc99d Dec-21, 83943100 Jan-22, c07460da Feb-22.
#   B.D08, NO WORKBOOK, collection set +1 month by the same rule, FLAGGED:
#     07d2d100 Oct-21, 9ed8a001 Nov-21, 74335296 Mar-22, ad100fc9 Apr-22,
#     0fb09fc8 May-22, 35fcbb82 Jun-22, 486703e0 Jul-22.
#   The unsourced rows HAVE to move with the sourced ones: leaving them would
#   put two samples on one gauge and Sydney day (ruling 9), e.g. 494a0147 onto
#   bcf15e0f's 2022-02-01, 83fa60f2 onto 07d2d100's 2021-10-01.
# (2) DELETE the two load-B copies (and their 3 analyses each), merging them
#   into the row that already holds the measurement: bcf15e0f -> 5a795c13
#   (workbook wins: the 2 dp row survives) and bb955fc9 -> 145bd575 (B.D07).
#   The precondition re-proves each value equality at run time.
# (3) WORKBOOK VALUES: three re-dated rows were typed from the 1 dp pdf and
#   would still raise a rounding value_conflict against the 2 dp workbook:
#     78674243 dust-total 4.2 -> 4.15, dust-combustible 2.0 -> 1.95
#     e034e78a dust-total 2.2 -> 2.16, dust-combustible 1.2 -> 1.16
#     d25cc99d dust-total 0.8 -> 0.82, dust-combustible 0.3 -> 0.32
#   (incombustible already equal). Drop this step to keep legacy values and
#   resolve those three as review items instead.
#
# NOT DONE, FLAGGED FOR A RULING:
#   * LOAD A's date_start is the collection month (should be exposure) on all
#     26 rows 2020-09..2021-09(01:01), both gauges.
#   * Legacy 2021-02-01 and 2021-03-01, BOTH gauges (0763faf8 5.4, 8c8aef7a
#     13.1, 4735d1dd 1.03, 20fda4f9 3.06) are the DB's Jan-2020 and Feb-2020
#     exposures (5.4/13.06, 1.03/3.06) - a year out. The true Jan-21 and Feb-21
#     exposures are in no source found.
#
# REPRESENTATION / INDEX: as 015. New dates are Sydney midnight held as the UTC
# instant (the legacy form). Only `date` and `date_start` are written;
# `datetime` (in 009's ux_sample_identity) stays as loaded. Projects: every row
# here links to the root "Dust monitoring" project (230bd429), which has no
# period, so no project row moves.
#
# FK: duckdb refuses deleting a sample in the same transaction that deleted its
# analyses (008's header). The deletes therefore run as a PRE-PASS after the
# verified backup, each statement committing alone; then one transaction does
# the re-dates, the value updates and the marker. A failure between the two
# leaves the deletes done and no marker: restore from the printed backup.
#
# BACKUP OF THE ROWS: `016-redate-legacy-dust-2021-22-BACKUP-{sample,analysis}.csv`
# beside this file (the 24 samples and every analysis on them), plus the
# verified whole-file backup in `snapshot_dir`.
#
# Marker 1016. Requires 1015. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/016-redate-legacy-dust-2021-22.R", envir = env)
#   env$mig016_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig016_marker_version <- 1016L
.mig016_requires <- 1015L
.mig016_actor <- "016-redate-legacy-dust-2021-22"
.mig016_expected_legacy_n <- 102L

.mig016_row <- function(uuid, gauge, old, new_start, new_date, total, source) {
  data.frame(uuid = uuid, gauge = gauge, old = old, new_start = new_start, new_date = new_date,
             total = total, source = source, stringsAsFactors = FALSE)
}
# `old` is the stored Sydney day of BOTH date and date_start (load B: equal).
# `source` NA = no workbook (flagged in the header).
.mig016_redates <- rbind(
  .mig016_row("78674243-4f92-4563-9754-3ad1d5e2a085", "B.D07", "2021-08-01", "2021-09-01", "2021-10-01", 4.2,  "2400-7222-01-02"),
  .mig016_row("23110556-cc12-4774-bb71-32d95318b8f2", "B.D07", "2021-09-01", "2021-10-01", "2021-11-01", 1.8,  NA),
  .mig016_row("e034e78a-f4a0-41be-8f33-f710e22d8b8a", "B.D07", "2021-10-01", "2021-12-01", "2022-01-01", 2.2,  "2400-7222-01-02"),
  .mig016_row("f5c09052-7487-4c12-b456-a563319e9d8d", "B.D07", "2021-11-01", "2021-11-01", "2021-12-01", 0.9,  NA),
  .mig016_row("494a0147-45bb-4244-8744-3efbffc5322f", "B.D07", "2021-12-01", "2022-01-01", "2022-02-01", 0.71, "2400-7222-03-02"),
  .mig016_row("5a795c13-8622-4b30-8726-e73946b30818", "B.D07", "2022-01-01", "2022-02-01", "2022-03-01", 0.99, "2400-7222-03-02"),
  .mig016_row("31e8affa-99de-4fb2-a21a-1abcc5d2f235", "B.D07", "2022-03-01", "2022-03-01", "2022-04-01", 0.3,  NA),
  .mig016_row("5ae2e450-b23f-4453-9bdd-7089dc5f2f96", "B.D07", "2022-04-01", "2022-04-01", "2022-05-01", 0.6,  NA),
  .mig016_row("da14dd5c-eb48-48dc-bcf7-fdbc8c175bd2", "B.D07", "2022-05-01", "2022-05-01", "2022-06-01", 1.4,  NA),
  .mig016_row("808e817a-1229-4b6e-9762-6e857fbcc340", "B.D07", "2022-06-01", "2022-06-01", "2022-07-01", 1.1,  NA),
  .mig016_row("919c8665-ece5-4f62-9852-6c286dacd1ee", "B.D07", "2022-07-01", "2022-07-01", "2022-08-01", 4.8,  NA),
  .mig016_row("83fa60f2-1e83-4568-876a-835d6cc91950", "B.D08", "2021-09-01", "2021-09-01", "2021-10-01", 1.4,  "2400-7222-01-02"),
  .mig016_row("07d2d100-aefa-4f12-94a6-2ee258761d2d", "B.D08", "2021-10-01", "2021-10-01", "2021-11-01", 1.1,  NA),
  .mig016_row("9ed8a001-7069-4c30-a99d-4a7c4a6006bd", "B.D08", "2021-11-01", "2021-11-01", "2021-12-01", 1.0,  NA),
  .mig016_row("d25cc99d-8931-47b5-acfe-1d2bd1905071", "B.D08", "2021-12-01", "2021-12-01", "2022-01-01", 0.8,  "2400-7222-01-02"),
  .mig016_row("83943100-4ddd-4ed0-846d-5fa417c89220", "B.D08", "2022-01-01", "2022-01-01", "2022-02-01", 2.44, "2400-7222-03-02"),
  .mig016_row("c07460da-dbbf-4a76-ba57-e9672448e7d5", "B.D08", "2022-02-01", "2022-02-01", "2022-03-01", 0.64, "2400-7222-03-02"),
  .mig016_row("74335296-f43e-40b8-afed-ce596062bf58", "B.D08", "2022-03-01", "2022-03-01", "2022-04-01", 0.4,  NA),
  .mig016_row("ad100fc9-086c-4d7d-9ed6-d7ae63e52118", "B.D08", "2022-04-01", "2022-04-01", "2022-05-01", 1.2,  NA),
  .mig016_row("0fb09fc8-eb71-4b81-bf86-8c497ef84553", "B.D08", "2022-05-01", "2022-05-01", "2022-06-01", 1.5,  NA),
  .mig016_row("35fcbb82-f6d1-4f22-97c4-bca86e4024aa", "B.D08", "2022-06-01", "2022-06-01", "2022-07-01", 1.2,  NA),
  .mig016_row("486703e0-f26a-4e06-9ada-8a5d9207eb0d", "B.D08", "2022-07-01", "2022-07-01", "2022-08-01", 0.9,  NA)
)

# Copies to delete. `digits`: the partner's values rounded to this many places
# must equal the copy's (bcf15e0f is the 1 dp print of 5a795c13).
.mig016_deletes <- data.frame(
  uuid = c("bcf15e0f-7460-4324-867e-eb695d1abeb7", "bb955fc9-bbd8-4511-b52d-eb561b07269e"),
  gauge = c("B.D07", "B.D08"),
  old = c("2022-02-01", "2021-08-01"),
  partner = c("5a795c13-8622-4b30-8726-e73946b30818", "145bd575-ceb0-442d-8fdd-8b72f07d1ba8"),
  partner_gauge = c("B.D07", "B.D07"),
  digits = c(1L, 2L),
  why = c("the same Feb-2022 measurement as 5a795c13 (2400-7222-03-02: 0.99/0.49/0.5), printed at 1 dp",
          "B.D07's Aug-2021 values (2400-7127-07: 1.0/0.4/0.6, held by 145bd575) loaded under B.D08; B.D08 Aug-2021 is 9708cb86"),
  stringsAsFactors = FALSE
)

.mig016_values <- data.frame(
  sample = c("78674243-4f92-4563-9754-3ad1d5e2a085", "78674243-4f92-4563-9754-3ad1d5e2a085",
             "e034e78a-f4a0-41be-8f33-f710e22d8b8a", "e034e78a-f4a0-41be-8f33-f710e22d8b8a",
             "d25cc99d-8931-47b5-acfe-1d2bd1905071", "d25cc99d-8931-47b5-acfe-1d2bd1905071"),
  analyte = rep(c("dust-total", "dust-combustible"), 3),
  old = c(4.2, 2.0, 2.2, 1.2, 0.8, 0.3),
  new = c(4.15, 1.95, 2.16, 1.16, 0.82, 0.32),
  source = c("2400-7222-01-02", "2400-7222-01-02", "2400-7222-01-02", "2400-7222-01-02", "2400-7222-01-02", "2400-7222-01-02"),
  stringsAsFactors = FALSE
)

.mig016_default <- function(x, default) if (is.null(x)) default else x
.mig016_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig016_sydney_midnight <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney")
.mig016_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig016_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig016_fail <- function(msg) cli::cli_abort(paste0("016-redate-legacy-dust-2021-22: ", msg), class = "sampletidy_error")
.mig016_all_ids <- function() c(.mig016_redates$uuid, .mig016_deletes$uuid)

.mig016_rows <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.date, s.date_start, %s AS sd, %s AS sds
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN (%s) ORDER BY s.uuid", .mig016_syd("s.date"), .mig016_syd("s.date_start"), .mig016_ids_sql(ids)))
}

# Dust values of one sample, named by analyte.
.mig016_dust <- function(con, uuid) {
  d <- DBI::dbGetQuery(con, "
    SELECT an.name, a.value, a.uuid FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE a.uuid_sample = ?", params = list(uuid))
  stats::setNames(d$value, d$name)
}

.mig016_legacy_dust_n <- function(con) {
  .mig016_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig016_counts <- function(con) {
  list(
    analysis = .mig016_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig016_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig016_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig016_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Same-gauge, same-Sydney-day groups on the two dust gauges.
.mig016_same_day <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT f.name AS gauge, %s AS day, COUNT(*) AS n, string_agg(s.uuid, ',') AS uuids
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08') AND s.date IS NOT NULL
    GROUP BY ALL HAVING COUNT(*) > 1 ORDER BY 1, 2", .mig016_syd("s.date")))
}

# Everything the main transaction must not touch.
.mig016_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  ids <- .mig016_ids_sql(.mig016_redates$uuid)
  list(
    sample_other = q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", ids)),
    sample_target_rest = q(sprintf("SELECT uuid, uuid_feature_alias, uuid_project, datetime, datetime_start,
                                    organisation, person, purpose, comments FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
    analysis_rest = q("SELECT uuid, uuid_sample, uuid_lab, value_chr, quantified, rl_low, rl_high, purpose, comments FROM analysis ORDER BY uuid"),
    analysis_value_other = q(sprintf("SELECT uuid, value FROM analysis WHERE uuid_sample NOT IN (%s) ORDER BY uuid",
                                     .mig016_ids_sql(unique(.mig016_values$sample))))
  )
}

.mig016_check_preconditions <- function(con) {
  fail <- .mig016_fail
  if (.mig016_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig016_requires) == 0L) {
    fail(sprintf("marker %d (015) is required first.", .mig016_requires))
  }
  n_leg <- .mig016_legacy_dust_n(con)
  if (n_leg != .mig016_expected_legacy_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", n_leg, .mig016_expected_legacy_n))
  rows <- .mig016_rows(con, .mig016_all_ids())
  if (nrow(rows) != length(.mig016_all_ids())) fail(sprintf("%d of %d samples found.", nrow(rows), length(.mig016_all_ids())))
  for (r in seq_len(nrow(.mig016_redates))) {
    tg <- .mig016_redates[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (row$gauge != tg$gauge) fail(sprintf("%s is on %s, expected %s.", tg$uuid, row$gauge, tg$gauge))
    if (!identical(row$sd, tg$old) || !identical(row$sds, tg$old)) {
      fail(sprintf("%s is dated %s / %s (Sydney), expected %s for both.", tg$uuid, row$sds, row$sd, tg$old))
    }
    if (as.numeric(row$date) != as.numeric(.mig016_sydney_midnight(tg$old))) fail(sprintf("%s is not in the legacy representation.", tg$uuid))
    tot <- .mig016_dust(con, tg$uuid)[["dust-total"]]
    if (is.null(tot) || abs(tot - tg$total) > 1e-9) fail(sprintf("%s dust-total is %s, expected %s.", tg$uuid, format(tot), format(tg$total)))
  }
  for (i in seq_len(nrow(.mig016_deletes))) {
    d <- .mig016_deletes[i, ]; row <- rows[rows$uuid == d$uuid, ]
    if (row$gauge != d$gauge || !identical(row$sd, d$old)) fail(sprintf("copy %s is not on %s at %s.", d$uuid, d$gauge, d$old))
    a <- .mig016_dust(con, d$uuid); p <- .mig016_dust(con, d$partner)
    an <- c("dust-total", "dust-combustible", "dust-incombustible")
    n_all <- .mig016_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_sample = ?", d$uuid)
    if (n_all != 3L || !setequal(names(a), an) || !all(an %in% names(p)) ||
        any(abs(a[an] - round(p[an], d$digits)) > 1e-9)) {
      fail(sprintf("copy %s no longer equals partner %s (%s vs %s).", d$uuid, d$partner,
                   paste(format(a[an]), collapse = "/"), paste(format(p[an]), collapse = "/")))
    }
  }
  for (i in seq_len(nrow(.mig016_values))) {
    v <- .mig016_values[i, ]; cur <- .mig016_dust(con, v$sample)[[v$analyte]]
    if (is.null(cur) || abs(cur - v$old) > 1e-9) fail(sprintf("%s %s is %s, expected %s.", v$sample, v$analyte, format(cur), format(v$old)))
  }
  # Simulate the end state: no two samples on a gauge share a Sydney day.
  sim <- DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, %s AS day FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08') AND s.date IS NOT NULL AND s.uuid NOT IN (%s)",
    .mig016_syd("s.date"), .mig016_ids_sql(.mig016_deletes$uuid)))
  m <- match(sim$uuid, .mig016_redates$uuid)
  sim$day[!is.na(m)] <- .mig016_redates$new_date[m[!is.na(m)]]
  dup <- sim[duplicated(sim[, c("gauge", "day")]) | duplicated(sim[, c("gauge", "day")], fromLast = TRUE), ]
  if (nrow(dup) > 0) fail(paste("the end state would put two samples on one gauge and day:",
                                paste(sprintf("%s %s %s", dup$gauge, dup$day, substr(dup$uuid, 1, 8)), collapse = "; ")))
  invisible(rows)
}

.mig016_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("016 verify failed: ", msg), class = "sampletidy_error")
  rows <- .mig016_rows(con, .mig016_redates$uuid)
  if (nrow(rows) != nrow(.mig016_redates)) fail("re-dated samples missing.")
  for (r in seq_len(nrow(.mig016_redates))) {
    tg <- .mig016_redates[r, ]; row <- rows[rows$uuid == tg$uuid, ]
    if (!identical(row$sd, tg$new_date) || !identical(row$sds, tg$new_start) ||
        as.numeric(row$date) != as.numeric(.mig016_sydney_midnight(tg$new_date)) ||
        as.numeric(row$date_start) != as.numeric(.mig016_sydney_midnight(tg$new_start))) {
      fail(sprintf("%s is %s / %s, expected %s / %s.", tg$uuid, row$sds, row$sd, tg$new_start, tg$new_date))
    }
  }
  if (nrow(.mig016_rows(con, .mig016_deletes$uuid)) != 0L) fail("a copy still exists.")
  for (i in seq_len(nrow(.mig016_values))) {
    v <- .mig016_values[i, ]
    if (abs(.mig016_dust(con, v$sample)[[v$analyte]] - v$new) > 1e-9) fail(sprintf("%s %s not updated.", v$sample, v$analyte))
  }
  sd <- .mig016_same_day(con)
  if (nrow(sd) > 0) fail(sprintf("%d same-day groups remain on B.D07/B.D08.", nrow(sd)))
  n_leg <- .mig016_legacy_dust_n(con)
  if (n_leg != .mig016_expected_legacy_n - nrow(.mig016_deletes)) fail(sprintf("%d dust samples.", n_leg))
  invisible(TRUE)
}

mig016_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig016_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-016-redate-legacy-dust-2021-22_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig016_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig016_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig016_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("016: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig016_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig016_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig016_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("016 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig016_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (r in seq_len(nrow(.mig016_redates))) {
    tg <- .mig016_redates[r, ]
    logf("(1) %s %s: %s/%s -> start %s, date %s (%s)", tg$uuid, tg$gauge, tg$old, tg$old, tg$new_start, tg$new_date,
         ifelse(is.na(tg$source), "NO WORKBOOK", tg$source))
  }
  for (i in seq_len(nrow(.mig016_deletes))) logf("(2) delete %s %s: %s", .mig016_deletes$uuid[[i]], .mig016_deletes$gauge[[i]], .mig016_deletes$why[[i]])
  for (i in seq_len(nrow(.mig016_values))) {
    v <- .mig016_values[i, ]; logf("(3) %s %s %s -> %s", v$sample, v$analyte, format(v$old), format(v$new))
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  with_db_write(function(con) {
    ids <- .mig016_ids_sql(.mig016_all_ids())
    .mig016_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "016-redate-legacy-dust-2021-22-BACKUP-sample.csv"))
    .mig016_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "016-redate-legacy-dust-2021-22-BACKUP-analysis.csv"))
  }, db = db)
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig016_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig016_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig016_counts(con)
    # (2) FK PRE-PASS: each delete commits on its own (see header).
    for (i in seq_len(nrow(.mig016_deletes))) {
      d <- .mig016_deletes[i, ]
      reason <- sprintf("016: legacy dust copy merged into %s (%s) - %s", d$partner, d$partner_gauge, d$why)
      for (a in DBI::dbGetQuery(con, "SELECT uuid FROM analysis WHERE uuid_sample = ? ORDER BY uuid", params = list(d$uuid))$uuid) {
        db_delete(con, "analysis", uuid = a, actor = .mig016_actor, reason = reason)
      }
      db_delete(con, "sample", uuid = d$uuid, actor = .mig016_actor, reason = reason)
    }
    sums_before <- .mig016_checksum(con)
    db_transaction(con, function(con) {
      for (r in seq_len(nrow(.mig016_redates))) {
        tg <- .mig016_redates[r, ]
        db_update(con, "sample", uuid = tg$uuid,
                  changes = list(date_start = .mig016_sydney_midnight(tg$new_start), date = .mig016_sydney_midnight(tg$new_date)),
                  actor = .mig016_actor,
                  reason = sprintf("016: dust %s legacy load B dated %s; exposed %s, collected %s (%s). Exposure = date_start, collection = date (Robin, 2026-10-16)",
                                   tg$gauge, tg$old, tg$new_start, tg$new_date,
                                   ifelse(is.na(tg$source), "no workbook: placed by the load-B rule", paste("per", tg$source))))
      }
      for (i in seq_len(nrow(.mig016_values))) {
        v <- .mig016_values[i, ]
        a <- DBI::dbGetQuery(con, "
          SELECT a.uuid FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
          WHERE a.uuid_sample = ? AND an.name = ?", params = list(v$sample, v$analyte))$uuid
        if (length(a) != 1L) cli::cli_abort("016: {v$sample} {v$analyte} is not one row.", class = "sampletidy_error")
        db_update(con, "analysis", uuid = a, changes = list(value = v$new), actor = .mig016_actor,
                  reason = sprintf("016: workbook wins (Robin, 2026-10-16): %s prints %s at 2 dp; legacy was typed from the 1 dp pdf (%s)",
                                   v$source, format(v$new), format(v$old)))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig016_marker_version, recorded_at))
      .mig016_verify(con)
      sums_after <- .mig016_checksum(con)
      counts_after <- .mig016_counts(con)
      expect <- counts_before; expect$sample <- expect$sample - 2L; expect$analysis <- expect$analysis - 6L
      if (!identical(expect, counts_after) || !identical(sums_before, sums_after)) {
        cli::cli_abort("016 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("016-redate-legacy-dust-2021-22 migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
