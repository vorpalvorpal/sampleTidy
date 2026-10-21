# Operator-run migration: correct LIVE data that the historical corpus shows is
# wrong, before the corpus import (Robin, 2026-10-20: the TRIAGE.md D-items are
# accepted; every change gets a note in the comments of the affected sample /
# project). Marker 1056. Requires 1055.
#
# Evidence: /private/tmp/claude-501/scr/hist/triage/ (TRIAGE.md, vc_detail.csv,
# items_classified.csv) and the F2 rehearsal's review items, re-checked here
# against the corpus source files and the live series. Each item below says what
# was done or why it was left alone. Robin accepted the recommendations; where
# the evidence contradicts a recommendation the item is PARKED (no write) and
# the reason given, rather than applied blind.
#
# ---- APPLIED -------------------------------------------------------------------
#
# D1  ES2421689 / ACIRL 2400-7400-07. The ALS ENMRG/XTAB and the ACIRL July
#     workbook date ES2421689 1 Jul 2024; ACIRL 2400-7400-06-01 (all 12 sheets)
#     cites ES2420251 for the 19 Jun 2024 quarterly visit, and its field values
#     equal live's 19 Jun ACIRL readings while its transcribed ALS values (e.g.
#     K.S03 Ca 20, EC 189) differ from the ALS values live holds on 19 Jun (Ca 17
#     = ES2421689). So live's 19 Jun samples are the ES2420251 visit carrying
#     ES2421689's ALS results.
#       * project ES2420251 created (Work order, under EPL quarterly a8ce3eff,
#         like ES2421689; dates 2024-06-19); the 22 19-Jun samples re-filed from
#         ES2421689 to it (uuid_project only);
#       * project ES2421689 date_start/date_end 2024-06-19 -> 2024-07-01;
#       * 5 new samples, uuid = ALS lab id ES2421689001..005 (K.S03, K.S05, K.S06,
#         K.S07, K.S09; self aliases), date = 1 Jul 2024 Sydney midnight
#         (2024-06-30 14:00 UTC, the legacy convention), no time (no source
#         gives one), organisation ACIRL;
#       * the 135 ES2421689 ALS analyses (27 per point) moved onto them
#         (uuid_sample only; INPUT-d1-moves.csv);
#       * the 25 1-Jul ACIRL field readings of 2400-7400-07 Surface Sites
#         (Temperature, pH, EC, flow, appearance; INPUT-d1-field.csv, exactly
#         what acirl_field_xlsx parses) inserted on the same samples, the shape
#         legacy keeps (ACIRL field + ALS on one sample). Without them the
#         workbook's ACIRL rows find only ALS-stream samples for ES2421689 and
#         the re-ingest guard blocks the workbook.
#     Migration 054 no longer holds the workbook (d1597914...).
#
# D2  2400-7222-04-02 (27 Apr 2022, ES2214496): live's ACIRL field values are a
#     one-column shift of the report; the ALS EC agrees with the report at every
#     point (E01 594 vs report 580 / live 130; S06 662 vs 659 / 580; S30 1570 vs
#     1374 / 659; TS28 2010 vs 1881 / 1374). 17 values set to the report
#     (INPUT-values.csv, item D2).
#
# D3  Single-value transcription disagreements, live -> report (10 values,
#     INPUT-values.csv, item D3): 2022-09-19 K.S05 EC 457 -> 459; 2022-09-21
#     B.S06 EC 816 -> 876; 2022-09-28 B.S01 pH 6.1 -> 6.7; 2022-11-02 B.MW11
#     Temperature 14.8 -> 12.1; 2022-12-28 B.S03 EC 203 -> 208; 2023-01-18 B.S05
#     Temperature 13 -> 23 and B.S06 16.4 -> 26.4; 2023-05-24 B.MW11 EC 72 ->
#     71.9 and B.S05 Temperature 10.06 -> 10.6; 2023-05-31 B.MW11 Temperature
#     14.4 -> 14.1. Each is the only live sample of its point that day and the
#     report is its own work order's report.
#
# D10 Point identity, applied where the evidence is unambiguous:
#     * "Discharge Point - Lawson STP" (ES2110710, ES2110714, ES2111587,
#       ES2207732, ES2207740, ES2208774, ES2208775): ESdat field ID "Discharge
#       Point - Lawson STP" (files "Discharge Point - Lawson (Sydney Water)");
#       the registry already maps that name to B.L05 (alias e84a562a, PLAN-15
#       D.2: B.L01 leachate tankered to Lawson STP and sampled at delivery),
#       and the same days' main-dam samples are separate B.L01 samples under
#       their own WOs (ES2110709, ES2111586; "Main Dam - Blaxland", different
#       values). The 7 samples are re-pointed B.L01 -> B.L05 (self alias
#       77cfbc41) with all their analyses. Two pairs are same-day deliveries
#       under separate orders (ES2207732/ES2207740 on 3 Mar 2022,
#       ES2208774/ES2208775 on 10 Mar 2022) that live holds at the legacy
#       11:00/11:01 placeholder times; their datetime/datetime_start are set to
#       the ALS-sampled times, so each order's rows match their own sample.
#     * B.S22 vs B.S06, Dec 2022 (ES2245792, sample 62ce42dc) and Dec 2023
#       (ES2344024, 97d64b49): ALS labels the sample B.S22 and the quarterly
#       ACIRL report lists B.S22 with exactly live's field values (2400-7222-12-04
#       S22 511 / 6.3 / 22.1; 2400-7286-12-1 S22 EC 412); neither ALS order has
#       a B.S06 sample; the quarterly B.S22 series (Jun/Sep 2022, Mar/Jun/Sep
#       2023, Mar 2024) has its only gaps at exactly these two quarters, and
#       the weekly B.S06 series is broken by the Dec 2022 sample (NH3-N 3.49
#       between 0.13 and 0.04). Re-pointed B.S06 -> B.S22 (self alias e24bdbc4).
#       (The special 2400-7222-12-02 lists the same values under "B.S06"; its
#       front page carries report no 2400-7222-12-01.)
#
# D13 Two ALS lab_methods, in the shape of the existing ALS rows (api 'false',
#     units / rl / reported_as / conversion NULL, preference NULL):
#     "Decachlorobiphenyl" / "EP066S: PCB Surrogate" -> analyte
#     Decachlorobiphenyl (540ffdc7, %, QC; until now only an ACIRL method);
#     "Naphthalene (Ex SVOC)" / "EP075(SIM)B: Polynuclear Aromatic
#     Hydrocarbons" -> analyte Naphthalene (a66c5035), rl_low 0.001 as the
#     existing EP075(SIM)B Naphthalene. These are the exact name + method the
#     ENMRG (ES2322707) and ESdat (ES2028911) rows carry, so the resolver's
#     exact match takes them.
#
# ---- PARKED (nothing written; for Robin) ---------------------------------------
#
# D2  ES2331527 (13 Sep 2023, B.S01/B.S03 ALS): live's swap is a documented human
#     correction (sample comment: "it looks like ACIRL switched the samples for
#     S3 and S1 ... so I have changed those around"); 029 kept it on that
#     ground. Reverting it to the lab file would undo that ruling.
# D2  2400-7286-05-09 (15 May 2023): the MW08/MW11 swap is physically
#     impossible in the report/ESdat direction - MW11 always runs Cl 9-12 /
#     NH3-N < 0.4 and MW08 Cl 57-140 / NH3-N 3-7 (Apr-Jul 2023 series), and live
#     already has them that way; the report's MW02 EC 552 and MW09 1127 break
#     both series (MW02 1086-1348, MW09 581-767). Live is right; the file is
#     mislabelled. (Same for D7 ES2316166 below.)
# D2  2400-7222-12-04 (14 Dec 2022): S04/S05 and MW07/MW09. Two ACIRL reports
#     for this visit disagree (12-02 gives S05 122 / 6.8 / 22.0, 12-04 111 / 5.6
#     / 21.6, live 100 / 6.7 / 22.6, ALS EC 121); for MW07/MW09 the ALS file's
#     Cl/NH3-N pair with live's field EC, not the report's. Not confident.
# D3  2400-7222-09-01 B.S01 pH (live 7.04 = its own work order's report
#     2400-7222-09, ES2232317; 09-01 is ES2232312's report - 029's ruling);
#     2400-7222-10-02 B.MW02 EC 1120 vs report 120 (the report dropped a digit:
#     MW02 runs ~1100); 2400-7286-05-08 B.S05 EC 140.6 vs report 1406 (slipped
#     decimal, ALS EC 141; 029 excluded it); 2400-7222-12-02 (7 values; two
#     reports for the same visit, see above); 2400-7286-06-02 B.S05 (EC 3883,
#     pH, T, stage: not B.S05 water - S05 runs 100-350 - and ES2320105's "B.S05"
#     carries leachate values, NH3-N 88.8; a different point, unidentified).
#     The 2400-7286-03-02 stage items compare two corpus files, not live.
# D7  ES2316166 (MW08/MW11) and ES2317541 (MW02/MW08 NH3-N, TKN): the ESdat
#     values are swapped against the bores' own series; live is right.
# D8  ES2415638 "Ammonia as NH3": live is NOT double-converted. analysis.value
#     is stored post-conversion (commit.R .ct_commit_analyses, reconcile.R
#     A63/D7): lab 2.14 mg/L NH3 x 0.8224428 = 1.760 mg/L NH3-N, which is what
#     live holds. "Correcting" it to 2.14 would store an NH3 value as NH3-N.
# D9  ES2314728: live did not file B.TS40 under B.S05. The ESdat "B.TS40 - OLD
#     DIVERSION PIPE OUTLET" (002) values (Al 0.04, Zn 0.061, Fe 1.32) are on
#     live B.TS39 (B.TS40 is the 2022 code for TS39; TS40 the feature starts
#     2024-04-08), and S05 (001) equals the file. The remaining "differs" rows
#     are dissolved vs total metals of the two revisions.
# D10 B.S22 vs B.S06 in April 2021 (ES2112331, ES2112339, ES2114638): live B.S06
#     is right - before the Nov 2021 renumbering "B.S22" was the stormwater
#     dam (B.S06's cypher; alias 'B.S22' -> B.S06, n_seen 12; 053 part F's
#     2020-03-06 'S22' -> B.S06). But no alias can carry it: the B.S22 self
#     arm always wins (.rc_self_precedence), so these stay blocked until the
#     resolver honours a dated arm over a self arm. Same for B.TS41 vs B.TMW15
#     (ES2411267, 2024-04-08): live is right (B.TS41 starts 2026-01-21; a dated
#     alias TS41 -> TMW15 on that day already exists) but the self arm wins.
#     B.TS18 vs B.S30 (ES2208920, 2022-03-14): the sample (EC 719, NH3-N 18.3)
#     fits neither the S30 series (~1300 / 55) nor the one TS18 sample; not
#     confident.
# D11 ES2006927: revision 1 (reported 2020-03-10) does not repeat ES2006494's
#     results (the detected values differ at every point: e.g. "Roadway"
#     TPH C10-C40 1280 vs 100, Al 1.86 vs 0.12), so it is not a duplicate of
#     ES2006494 and the later-issue rule does not reach it. Rev 1 and rev 0
#     (2020-03-06) carry byte-identical results and differ only in dates (rev 1
#     moves S3 and the dam 27 -> 25 Feb); live holds all of ES2006927 on 27 Feb
#     with the comment "COC incorrectly recorded date as 25-02-2020", and both
#     revisions' COC number is "ALSE-Sydney 27-Feb-20". RULED by Robin
#     2026-10-21: live's 27 Feb stands; 054 ignores rev 1 (and its identical
#     chemistry) permanently and notes the ruling on project ES2006927, so
#     nothing duplicates. 056 writes nothing for ES2006927.
#
# ---- HOW (the FK steps; 029's and 031's patterns) --------------------------------
#
# sample.uuid_feature_alias is an FK column and ux_sample_identity covers
# (uuid_feature_alias, datetime, uuid_project): an UPDATE of either is delete +
# insert in duckdb 1.4.1, which the analysis -> sample FK refuses while analyses
# reference the sample. So:
#   A. one set-based DELETE of the 191 analyses of the 9 D10 samples (count
#      asserted; the change_log rows db_delete() would write), COMMIT;
#   DROP INDEX ux_sample_identity (autocommit);
#   B. one transaction: lab_method, project, sample and analysis writes through
#      db_append()/db_update() - the 9 re-points, the 191 analyses re-inserted
#      unchanged (same uuids, INPUT-d10-analyses.csv), the D1 project/sample
#      writes and moves, the value updates, every comment, the marker; verify;
#      checksum of everything else;
#   CREATE UNIQUE INDEX ux_sample_identity in a finally (inside a function: a
#      top-level on.exit() is inert under Rscript).
# RESUMABLE: if B fails after A committed, a re-run recognises the post-A state
# (the 191 analyses and nothing else gone; 056's change_log is exactly their
# deletes) and runs B alone. Any other state is refused; restore from the
# printed backup.
#
# Comments: every touched sample and both projects get "<existing>; 2026-10-20
# corpus import (056, <item>): <what and why>" (the existing text kept). Every
# changed field is in change_log with old and new (actor
# "056-corpus-live-corrections").
#
# BACKUPS (written on apply, beside this file): 056-...-BACKUP-{analysis,sample,
# project}.csv (every analysis / sample / project row written, as it was before)
# and -BACKUP-lab_method.csv (header-only), plus the verified whole-file backup.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/056-corpus-live-corrections.R", envir = env)
#   env$mig056_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig056_marker_version <- 1056L
.mig056_requires <- 1055L
.mig056_name <- "056-corpus-live-corrections"
.mig056_actor <- .mig056_name
.mig056_note_date <- "2026-10-20"
.mig056_index_name <- "ux_sample_identity"
.mig056_index_sql <- 'CREATE UNIQUE INDEX ux_sample_identity ON "sample"(uuid_feature_alias, datetime, uuid_project);'

.mig056_dir <- function() if (dir.exists("dev/migrations")) "dev/migrations" else "."
.mig056_input <- function(which) {
  p <- file.path(.mig056_dir(), sprintf("%s-INPUT-%s.csv", .mig056_name, which))
  if (!file.exists(p)) cli::cli_abort("056: input {p} is missing (run from the repo root).", class = "sampletidy_error")
  utils::read.csv(p, stringsAsFactors = FALSE, colClasses = "character", na.strings = "", encoding = "UTF-8")
}
.mig056_num <- function(x) as.numeric(x)
.mig056_lgl <- function(x) ifelse(is.na(x), NA, x == "TRUE")
.mig056_inlist <- function(x) paste0("(", paste0("'", x, "'", collapse = ","), ")")
.mig056_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig056_fail <- function(msg) cli::cli_abort(paste0(.mig056_name, ": ", msg), class = "sampletidy_error")
.mig056_same <- function(a, b) (length(a) == 1L && length(b) == 1L) && ((is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && a == b))
.mig056_num_eq <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && abs(a - b) <= 1e-9 * max(1, abs(b)))
# Exact: a re-inserted row must be bit-identical. (INPUT-d10-analyses.csv holds
# doubles as hex, "%a": R's as.numeric() of a 17-significant-digit decimal is
# not correctly rounded - 7 of the 191 values drifted by an ulp that way.)
.mig056_num_ident <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && a == b)
.mig056_utc <- function(x) as.POSIXct(x, tz = "UTC")
.mig056_syd_day <- function(x) format(x, tz = "Australia/Sydney", "%Y-%m-%d")
.mig056_append_note <- function(existing, note) {
  n <- sprintf("%s corpus import (056, %s", .mig056_note_date, note)
  if (is.na(existing) || !nzchar(trimws(existing))) n else paste0(existing, "; ", n)
}

# ---- the plan --------------------------------------------------------------------

# D1
.mig056_epl_quarterly <- "a8ce3eff-e293-401c-8225-6d0c57d06993"
.mig056_p21689 <- "ecb9c654-6c12-4e00-a9fa-d506767e51ca"
.mig056_p20251 <- "6b0a2f6e-56d0-4c1e-9b51-2b0e4e4a7056"   # new project ES2420251 (fixed literal)
.mig056_new <- data.frame(
  uuid = sprintf("ES2421689%03d", 1:5),
  feature = c("K.S03", "K.S05", "K.S06", "K.S07", "K.S09"),
  alias = c("2a644747-1abe-4f97-883b-0554254355cc", "d5fb5a66-c5f2-4f6e-aec0-7e3298cbf027", "bfd28eba-e141-4538-b545-4baa9a3e6fca",
            "a53ff2dd-d500-4b45-b982-d9f0b5936669", "5543d2cc-d9ff-45ad-8585-89a3e4afe1d4"),
  stringsAsFactors = FALSE)
.mig056_d1_date <- "2024-06-30 14:00:00"    # 1 Jul 2024 00:00 Sydney

# D10
.mig056_repoint <- data.frame(
  uuid = c("5ddfbe73-df7f-4554-b50b-813eaf2b774f", "f43dd947-a72f-4654-a66b-7c41aedbc4d1", "1153d59e-c622-4fff-9172-1384b31a2cc6",
           "6feaa3c1-8840-48fe-87fc-e3161bc38c08", "69acb409-4937-4a6d-bc34-af29509eb072", "fb0d7f76-689c-42b7-835d-2f3f2a6d681a",
           "18030c46-f279-4aa3-a83a-b099d3b3ac25", "62ce42dc-a5db-4740-85c6-17fe4e88a1c8", "97d64b49-f116-439e-b0b8-bc8e398fdfea"),
  wo = c("ES2110710", "ES2110714", "ES2111587", "ES2207732", "ES2207740", "ES2208774", "ES2208775", "ES2245792", "ES2344024"),
  day = c("2021-03-23", "2021-03-21", "2021-03-26", "2022-03-03", "2022-03-03", "2022-03-10", "2022-03-10", "2022-12-14", "2023-12-18"),
  from_alias = c(rep("32298247-a658-4cf0-947e-171bde131278", 7), rep("20969dd8-5001-40f6-83d7-56ecb76aacf7", 2)),
  from_feat = c(rep("B.L01", 7), rep("B.S06", 2)),
  to_alias = c(rep("77cfbc41-c9de-49a8-a471-fd44f6d47196", 7), rep("e24bdbc4-7436-419d-a91f-892eb900d8e9", 2)),
  to_feat = c(rep("B.L05", 7), rep("B.S22", 2)),
  # Two Lawson deliveries on 3 Mar and on 10 Mar 2022, each its own ALS order.
  # Live holds them at the legacy 11:00 / 11:01 Sydney placeholder times
  # (migration 005's lab twins), which the matcher treats as time-unknown, so
  # each order's new rows would be ambiguous between the two. The ALS Sample
  # files give the sampled times (Sydney): ES2207732 03-Mar-22 12:30, ES2207740
  # 03-Mar-22 09:30, ES2208774 10-Mar-22 11:30, ES2208775 10-Mar-22 14:00.
  old_dt = c(NA, NA, NA, "2022-03-03 00:01:00", "2022-03-03 00:00:00", "2022-03-10 00:01:00", "2022-03-10 00:00:00", NA, NA),
  new_dt = c(NA, NA, NA, "2022-03-03 01:30:00", "2022-03-02 22:30:00", "2022-03-10 00:30:00", "2022-03-10 03:00:00", NA, NA),
  syd_time = c(NA, NA, NA, "12:30", "09:30", "11:30", "14:00", NA, NA),
  twin_wo = c(NA, NA, NA, "ES2207740", "ES2207732", "ES2208775", "ES2208774", NA, NA),
  stringsAsFactors = FALSE)
.mig056_dt_fix <- which(!is.na(.mig056_repoint$new_dt))
.mig056_repoint_note <- function(i) {
  r <- .mig056_repoint[i, ]
  if (r$to_feat == "B.L05") {
    twin <- c(ES2110710 = " The day's main-dam B.L01 sample is ES2110709.", ES2111587 = " The day's main-dam B.L01 sample is ES2111586.")
    dt <- if (is.na(r$new_dt)) "" else sprintf(" Time set from the legacy placeholder (%s UTC) to the ALS-sampled %s Sydney (%s UTC, ESdat Sample file), which tells it from the same day's other Lawson delivery %s.",
                                               substr(r$old_dt, 12, 16), r$syd_time, substr(r$new_dt, 1, 16), r$twin_wo)
    sprintf("D10): re-pointed B.L01 -> B.L05 with all its analyses: ALS field ID 'Discharge Point - Lawson STP' is tankered B.L01 leachate sampled at delivery to Lawson STP, which the registry maps to B.L05 (alias e84a562a); it is not a main-dam sample.%s%s",
            if (r$wo %in% names(twin)) twin[[r$wo]] else "", dt)
  } else {
    rep_no <- c(ES2245792 = "2400-7222-12-04", ES2344024 = "2400-7286-12-1")[[r$wo]]
    sprintf("D10): re-pointed B.S06 -> B.S22 with all its analyses: ALS %s labels this sample B.S22 and ACIRL %s lists B.S22 with these field values; the order has no B.S06 sample, and the quarterly B.S22 series has no other sample this quarter", r$wo, rep_no)
  }
}

# D13
.mig056_lab_methods <- data.frame(
  uuid = c("2f4e8d1a-7c3b-4a56-9e21-56c0d1a3b7e4", "9b1c6e2f-3d48-4f7a-8c05-56d2e4f6a8b1"),
  uuid_analyte = c("540ffdc7-f3a7-4e18-9db4-41300e3a8fa0", "a66c5035-f3a3-4cfd-bcfa-9c7a25cd3531"),
  name = c("Decachlorobiphenyl", "Naphthalene (Ex SVOC)"),
  method = c("EP066S: PCB Surrogate", "EP075(SIM)B: Polynuclear Aromatic Hydrocarbons"),
  organisation = c("ALS", "ALS"),
  rl_low = c(NA_real_, 0.001), rl_high = NA_real_, reported_as = NA_character_, api = "false",
  uuid_project = NA_character_, uuid_feature = NA_character_,
  comments = c("056 D13: ALS PCB surrogate (ENMRG ES2322707 EP066S); the analyte had only an ACIRL method",
               "056 D13: ALS reports naphthalene from the SVOC/PAH run as 'Naphthalene (Ex SVOC)' (ESdat ES2028911)"),
  units = NA_character_, conversion_constant = NA_real_, preference = NA_integer_,
  stringsAsFactors = FALSE)

# Plan tables from the INPUT CSVs, with the 19-Jun sample list and the 5
# source samples derived from the moves and asserted against live.
.mig056_load <- function() {
  mv <- .mig056_input("d1-moves")
  fld <- .mig056_input("d1-field")
  d10 <- .mig056_input("d10-analyses")
  val <- .mig056_input("values")
  if (nrow(mv) != 135L || anyDuplicated(mv$uuid) || !all(table(mv$to_sample) == 27L) ||
      !setequal(mv$to_sample, .mig056_new$uuid)) .mig056_fail("INPUT-d1-moves is malformed.")
  if (nrow(fld) != 25L || anyDuplicated(fld$uuid) || !all(fld$sample %in% .mig056_new$uuid)) .mig056_fail("INPUT-d1-field is malformed.")
  if (nrow(d10) != 191L || anyDuplicated(d10$uuid) || !setequal(d10$uuid_sample, .mig056_repoint$uuid)) .mig056_fail("INPUT-d10-analyses is malformed.")
  if (nrow(val) != 27L || anyDuplicated(val$uuid) || !all(val$item %in% c("D2", "D3")) || any(val$old == val$new) ||
      !all(val$field %in% c("value", "value_chr"))) .mig056_fail("INPUT-values is malformed.")
  ids <- c(mv$uuid, fld$uuid, d10$uuid, val$uuid)
  if (anyDuplicated(ids)) .mig056_fail("an analysis is planned twice.")
  src <- unique(mv[, c("from_sample", "to_sample")])
  if (nrow(src) != 5L || anyDuplicated(src$from_sample) || anyDuplicated(src$to_sample)) .mig056_fail("the D1 moves do not pair 5 samples to 5.")
  new <- .mig056_new
  new$from <- src$from_sample[match(new$uuid, src$to_sample)]
  if (any(val$uuid_sample %in% c(.mig056_repoint$uuid, new$from, new$uuid))) .mig056_fail("a value-plan sample is also a D1/D10 sample.")
  list(mv = mv, fld = fld, d10 = d10, val = val, new = new)
}

# The 22 samples of ES2421689 at marker 1055 (all 19 Jun 2024).
.mig056_samples19_of <- function(con, project) {
  DBI::dbGetQuery(con, 'SELECT s.*, f.name AS feat FROM "sample" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature WHERE s.uuid_project = ? AND s.uuid NOT IN (SELECT unnest(?::VARCHAR[])) ORDER BY s.uuid',
    params = list(project, list(.mig056_new$uuid)))
}

.mig056_counts <- function(con) {
  tabs <- c("analysis", "sample", "project", "lab_method", "feature_alias", "asset", "ingest_file", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig056_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 056 must not touch; valid pre-056, post-A and post-056.
.mig056_checksum <- function(con, P, s19) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "project", "lab_method", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  a_ids <- c(P$mv$uuid, P$fld$uuid, P$d10$uuid, P$val$uuid)
  s_ids <- c(s19, .mig056_new$uuid, .mig056_repoint$uuid, unique(P$val$uuid_sample))
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig056_inlist(a_ids)))
  out$analysis_moves_cols <- q(sprintf("SELECT uuid, uuid_lab, value, value_chr, quantified, rl_low, rl_high, purpose, comments
    FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig056_inlist(P$mv$uuid)))
  out$sample_rest <- q(sprintf('SELECT * FROM "sample" WHERE uuid NOT IN %s ORDER BY uuid', .mig056_inlist(s_ids)))
  out$sample_s19_cols <- q(sprintf('SELECT uuid, uuid_feature_alias, date, date_start, datetime, datetime_start, organisation, person, purpose
    FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig056_inlist(s19)))
  dtfix <- .mig056_inlist(.mig056_repoint$uuid[.mig056_dt_fix])
  out$sample_repoint_cols <- q(sprintf('SELECT uuid, uuid_project, date, date_start,
      CASE WHEN uuid IN %s THEN NULL ELSE datetime END AS dt, CASE WHEN uuid IN %s THEN NULL ELSE datetime_start END AS dts,
      organisation, person, purpose
    FROM "sample" WHERE uuid IN %s ORDER BY uuid', dtfix, dtfix, .mig056_inlist(.mig056_repoint$uuid)))
  out$sample_val_cols <- q(sprintf('SELECT uuid, uuid_feature_alias, uuid_project, date, date_start, datetime, datetime_start, organisation, person, purpose
    FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig056_inlist(unique(P$val$uuid_sample))))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY uuid", .mig056_inlist(c(.mig056_p21689, .mig056_p20251))))
  out$project_21689_cols <- q(sprintf("SELECT uuid, uuid_parent, uuid_root, uuid_project, name, type, purpose, regulated_by, cypher, site, value
    FROM project WHERE uuid = '%s'", .mig056_p21689))
  out$lab_method_rest <- q(sprintf("SELECT * FROM lab_method WHERE uuid NOT IN %s ORDER BY uuid", .mig056_inlist(.mig056_lab_methods$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig056_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig056_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig056_analyses <- function(con, ids) DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig056_inlist(ids)))
.mig056_samples <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf('SELECT s.*, f.name AS feat, p.name AS proj FROM "sample" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature LEFT JOIN project p ON p.uuid = s.uuid_project WHERE s.uuid IN %s ORDER BY s.uuid', .mig056_inlist(ids)))
}
.mig056_d10_rows <- function(d10) {
  data.frame(uuid = d10$uuid, uuid_sample = d10$uuid_sample, uuid_lab = d10$uuid_lab, value = .mig056_num(d10$value),
             value_chr = d10$value_chr, quantified = .mig056_lgl(d10$quantified), rl_low = .mig056_num(d10$rl_low),
             rl_high = .mig056_num(d10$rl_high), purpose = d10$purpose, comments = d10$comments, stringsAsFactors = FALSE)
}
.mig056_fld_rows <- function(fld) {
  data.frame(uuid = fld$uuid, uuid_sample = fld$sample, uuid_lab = fld$uuid_lab, value = .mig056_num(fld$value),
             value_chr = fld$value_chr, quantified = .mig056_lgl(fld$quantified), rl_low = NA_real_, rl_high = NA_real_,
             purpose = NA_character_, comments = NA_character_, stringsAsFactors = FALSE)
}
.mig056_rows_problem <- function(got, want, tag) {
  if (nrow(got) != nrow(want)) return(sprintf("%s: %d of %d rows", tag, nrow(got), nrow(want)))
  got <- got[match(want$uuid, got$uuid), , drop = FALSE]
  for (f in c("uuid_sample", "uuid_lab", "value_chr", "purpose", "comments", "quantified")) {
    bad <- which(!mapply(.mig056_same, got[[f]], want[[f]]))
    if (length(bad)) return(sprintf("%s: analysis %s differs in %s", tag, substr(want$uuid[bad[[1]]], 1, 8), f))
  }
  for (f in c("value", "rl_low", "rl_high")) {
    bad <- which(!mapply(.mig056_num_ident, got[[f]], want[[f]]))
    if (length(bad)) return(sprintf("%s: analysis %s differs in %s", tag, substr(want$uuid[bad[[1]]], 1, 8), f))
  }
  NULL
}

# ---- state checks -----------------------------------------------------------------

.mig056_static_problem <- function(con, P) {
  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig056_inlist(P$fld$uuid_lab)))
  if (nrow(lm) != 5L) return("an ACIRL field lab_method of INPUT-d1-field is missing")
  an <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM analyte WHERE uuid IN %s", .mig056_inlist(.mig056_lab_methods$uuid_analyte)))
  if (nrow(an) != 2L) return("a D13 analyte is missing")
  ta <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, fa.kind, f.name FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.uuid IN %s",
                                     .mig056_inlist(unique(c(.mig056_repoint$to_alias, .mig056_new$alias)))))
  want <- unique(rbind(data.frame(u = .mig056_repoint$to_alias, n = .mig056_repoint$to_feat), data.frame(u = .mig056_new$alias, n = .mig056_new$feature)))
  for (i in seq_len(nrow(want))) {
    r <- ta[ta$uuid == want$u[i], ]
    if (nrow(r) != 1L || r$kind != "self" || r$name != want$n[i]) return(sprintf("alias %s is not %s's self alias", substr(want$u[i], 1, 8), want$n[i]))
  }
  # D10 targets: no other sample of the target feature on the day
  day_sql <- .ct_sydney_day_sql("coalesce(s.date, s.datetime)")
  for (i in seq_len(nrow(.mig056_repoint))) {
    r <- .mig056_repoint[i, ]
    n <- .mig056_scalar(con, sprintf('SELECT COUNT(*) FROM "sample" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      JOIN feature f ON f.uuid = fa.uuid_feature WHERE f.name = ? AND %s = CAST(? AS DATE) AND s.uuid NOT IN %s', day_sql,
      .mig056_inlist(.mig056_repoint$uuid)), r$to_feat, r$day)
    if (n != 0L) return(sprintf("another %s sample exists on %s", r$to_feat, r$day))
  }
  NULL
}

# Pre-056 (if `post_a`, the D10 analyses have been deleted by step A).
.mig056_pre_problem <- function(con, P, post_a = FALSE) {
  p <- .mig056_static_problem(con, P); if (!is.null(p)) return(p)
  if (.mig056_scalar(con, "SELECT COUNT(*) FROM project WHERE uuid = ? OR name = 'ES2420251'", .mig056_p20251) != 0L) return("project ES2420251 already exists")
  pr <- DBI::dbGetQuery(con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig056_p21689))
  if (nrow(pr) != 1L || pr$name != "ES2421689" || pr$type != "Work order" || !.mig056_same(pr$uuid_parent, .mig056_epl_quarterly) ||
      format(pr$date_start, tz = "UTC") != "2024-06-19" || format(pr$date_end, tz = "UTC") != "2024-06-19" || !is.na(pr$comments))
    return("project ES2421689 is not the 2024-06-19 work order under EPL quarterly")
  s19 <- .mig056_samples19_of(con, .mig056_p21689)
  if (nrow(s19) != 22L || any(.mig056_syd_day(s19$date) != "2024-06-19")) return(sprintf("ES2421689 holds %d samples, not 22 on 19 Jun 2024", nrow(s19)))
  if (!all(P$new$from %in% s19$uuid) || !all(s19$feat[match(P$new$from, s19$uuid)] == P$new$feature)) return("the D1 source samples are not ES2421689's K.S03/05/06/07/09")
  if (.mig056_scalar(con, sprintf('SELECT COUNT(*) FROM "sample" WHERE uuid IN %s', .mig056_inlist(.mig056_new$uuid))) != 0L) return("a 1 Jul sample already exists")
  if (nrow(.mig056_analyses(con, P$fld$uuid)) != 0L) return("a D1 field analysis already exists")
  a <- .mig056_analyses(con, P$mv$uuid)
  if (nrow(a) != 135L || !all(a$uuid_sample == P$mv$from_sample[match(a$uuid, P$mv$uuid)])) return("the 135 ES2421689 ALS analyses are not on their 19 Jun samples")
  n_als <- .mig056_scalar(con, sprintf("SELECT COUNT(*) FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE lm.organisation = 'ALS' AND a.uuid_sample IN %s", .mig056_inlist(s19$uuid)))
  if (n_als != 135L) return(sprintf("ES2421689's samples hold %d ALS analyses, not 135", n_als))
  S <- .mig056_samples(con, .mig056_repoint$uuid)
  if (nrow(S) != 9L) return("a D10 sample is missing")
  S <- S[match(.mig056_repoint$uuid, S$uuid), ]
  if (any(S$uuid_feature_alias != .mig056_repoint$from_alias) || any(S$proj != .mig056_repoint$wo) || any(.mig056_syd_day(S$date) != .mig056_repoint$day))
    return("a D10 sample is not on its from-alias / work order / day")
  k <- .mig056_dt_fix
  if (any(format(S$datetime[k], tz = "UTC", "%Y-%m-%d %H:%M:%S") != .mig056_repoint$old_dt[k]) ||
      any(format(S$datetime_start[k], tz = "UTC", "%Y-%m-%d %H:%M:%S") != .mig056_repoint$old_dt[k]))
    return("a Lawson 2022 sample is not at its placeholder time")
  d10 <- .mig056_d10_rows(P$d10)
  if (post_a) {
    if (nrow(.mig056_analyses(con, d10$uuid)) != 0L || .mig056_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_sample IN %s", .mig056_inlist(.mig056_repoint$uuid))) != 0L)
      return("not post-A: D10 analyses exist")
  } else {
    p <- .mig056_rows_problem(.mig056_analyses(con, d10$uuid), d10, "D10 snapshot"); if (!is.null(p)) return(p)
    if (.mig056_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_sample IN %s", .mig056_inlist(.mig056_repoint$uuid))) != 191L)
      return("the D10 samples hold analyses outside INPUT-d10-analyses")
  }
  v <- .mig056_analyses(con, P$val$uuid)
  if (nrow(v) != nrow(P$val)) return("a value-plan analysis is missing")
  v <- v[match(P$val$uuid, v$uuid), ]
  for (i in seq_len(nrow(P$val))) {
    r <- P$val[i, ]
    ok <- if (r$field == "value") .mig056_num_eq(v$value[i], .mig056_num(r$old)) else .mig056_same(v$value_chr[i], r$old)
    if (!ok || v$uuid_sample[i] != r$uuid_sample) return(sprintf("value plan %s %s %s does not hold %s", r$feature, r$day, r$analyte, r$old))
  }
  if (.mig056_scalar(con, sprintf("SELECT COUNT(*) FROM lab_method WHERE uuid IN %s OR (organisation = 'ALS' AND (name, method) IN (('Decachlorobiphenyl', 'EP066S: PCB Surrogate'), ('Naphthalene (Ex SVOC)', 'EP075(SIM)B: Polynuclear Aromatic Hydrocarbons')))",
                               .mig056_inlist(.mig056_lab_methods$uuid))) != 0L) return("a D13 lab_method already exists")
  n_log <- .mig056_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig056_actor)
  if (post_a) {
    cl <- DBI::dbGetQuery(con, "SELECT tbl, action, uuid_row FROM change_log WHERE actor = ?", params = list(.mig056_actor))
    if (nrow(cl) != 191L || any(cl$tbl != "analysis") || any(cl$action != "delete") || !setequal(cl$uuid_row, d10$uuid)) return("not post-A: 056's change_log is not exactly the 191 deletes")
  } else if (n_log != 0L) return("056 change_log rows already exist")
  if (.mig056_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig056_index_name) != 1L) return("ux_sample_identity is missing")
  NULL
}

.mig056_note_sample <- function(P) {
  # one note per touched sample, as appended by step B
  notes <- list()
  add <- function(u, n) notes[[u]] <<- c(notes[[u]], n)
  for (u in P$s19) {
    n <- "D1): re-filed from ALS ES2421689 to ES2420251, the ALS work order ACIRL 2400-7400-06-01 cites for this 19 Jun 2024 quarterly visit; ES2421689 is the 1 Jul 2024 Katoomba monthly (ALS ENMRG/XTAB and ACIRL 2400-7400-07)"
    k <- match(u, P$new$from)
    if (!is.na(k)) n <- sprintf("%s; its 27 ES2421689 ALS results moved to the 1 Jul 2024 sample %s", n, P$new$uuid[[k]])
    add(u, n)
  }
  for (k in seq_len(nrow(P$new))) {
    add(P$new$uuid[[k]], sprintf("D1): created for ALS sample %s (%s), sampled 1 Jul 2024 per the ALS ENMRG/XTAB and ACIRL 2400-7400-07; holds the 27 ALS results legacy had filed on the 19 Jun 2024 sample %s, and the 1 Jul field readings of 2400-7400-07 Surface Sites (temperature, pH, EC, flow, appearance); no time of day is recorded",
                                 P$new$uuid[[k]], P$new$feature[[k]], substr(P$new$from[[k]], 1, 8)))
  }
  for (i in seq_len(nrow(.mig056_repoint))) add(.mig056_repoint$uuid[[i]], .mig056_repoint_note(i))
  for (u in unique(P$val$uuid_sample)) {
    r <- P$val[P$val$uuid_sample == u, ]
    item <- paste(unique(r$item), collapse = "/")
    add(u, sprintf("%s): ACIRL field %s corrected to the ACIRL report %s (%s)", item,
                   paste(sprintf("%s %s -> %s", r$analyte, r$old, r$new), collapse = ", "),
                   r$report[[1]], paste(r$cell, collapse = ", ")))
  }
  vapply(notes, function(x) paste(x, collapse = "; "), character(1))
}

.mig056_note_p21689 <- "D1): date_start/date_end 2024-06-19 -> 2024-07-01 (the ALS sample date); its 19 Jun 2024 samples, the quarterly visit, re-filed under ES2420251 and its ALS results moved to 1 Jul samples ES2421689001-005"
.mig056_note_p20251 <- "D1): created: the 19 Jun 2024 Katoomba quarterly visit, which ACIRL 2400-7400-06-01 files under ALS ES2420251; legacy had filed its 22 samples under ES2421689. No ES2420251 ALS results are held."

.mig056_done_problem <- function(con, P) {
  if (.mig056_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig056_marker_version) != 1L) return("marker 1056 missing")
  p <- .mig056_static_problem(con, P); if (!is.null(p)) return(p)
  pr <- DBI::dbGetQuery(con, sprintf("SELECT * FROM project WHERE uuid IN %s", .mig056_inlist(c(.mig056_p21689, .mig056_p20251))))
  a <- pr[pr$uuid == .mig056_p21689, ]; b <- pr[pr$uuid == .mig056_p20251, ]
  if (nrow(a) != 1L || format(a$date_start, tz = "UTC") != "2024-07-01" || format(a$date_end, tz = "UTC") != "2024-07-01" ||
      !.mig056_same(a$comments, .mig056_append_note(NA, .mig056_note_p21689))) return("project ES2421689 is not as planned")
  if (nrow(b) != 1L || b$name != "ES2420251" || b$type != "Work order" || !.mig056_same(b$uuid_parent, .mig056_epl_quarterly) ||
      !.mig056_same(b$uuid_root, .mig056_epl_quarterly) || format(b$date_start, tz = "UTC") != "2024-06-19" ||
      !.mig056_same(b$comments, .mig056_append_note(NA, .mig056_note_p20251))) return("project ES2420251 is not as planned")
  s19 <- .mig056_samples(con, P$s19)
  if (nrow(s19) != 22L || any(s19$uuid_project != .mig056_p20251)) return("the 22 19-Jun samples are not on ES2420251")
  if (.mig056_scalar(con, 'SELECT COUNT(*) FROM "sample" WHERE uuid_project = ?', .mig056_p21689) != 5L) return("ES2421689 does not hold exactly the 5 1-Jul samples")
  ns <- .mig056_samples(con, .mig056_new$uuid)
  ns <- ns[match(.mig056_new$uuid, ns$uuid), ]
  if (nrow(ns) != 5L || any(ns$uuid_feature_alias != .mig056_new$alias) || any(ns$uuid_project != .mig056_p21689) ||
      any(format(ns$date, tz = "UTC", "%Y-%m-%d %H:%M:%S") != .mig056_d1_date) || any(!is.na(ns$datetime)) ||
      any(.mig056_syd_day(ns$date) != "2024-07-01") || any(ns$organisation != "ACIRL")) return("the 1 Jul samples are not as planned")
  mvd <- .mig056_analyses(con, P$mv$uuid)
  if (nrow(mvd) != 135L || !all(mvd$uuid_sample == P$mv$to_sample[match(mvd$uuid, P$mv$uuid)])) return("the 135 ALS analyses are not on the 1 Jul samples")
  p <- .mig056_rows_problem(.mig056_analyses(con, P$fld$uuid), .mig056_fld_rows(P$fld), "D1 field"); if (!is.null(p)) return(p)
  if (.mig056_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_sample IN %s", .mig056_inlist(.mig056_new$uuid))) != 160L) return("the 1 Jul samples do not hold exactly 160 analyses")
  S <- .mig056_samples(con, .mig056_repoint$uuid); S <- S[match(.mig056_repoint$uuid, S$uuid), ]
  if (nrow(S) != 9L || any(S$uuid_feature_alias != .mig056_repoint$to_alias)) return("a D10 sample is not on its target alias")
  k <- .mig056_dt_fix
  if (any(format(S$datetime[k], tz = "UTC", "%Y-%m-%d %H:%M:%S") != .mig056_repoint$new_dt[k]) ||
      any(format(S$datetime_start[k], tz = "UTC", "%Y-%m-%d %H:%M:%S") != .mig056_repoint$new_dt[k]))
    return("a Lawson 2022 sample is not at its ALS-sampled time")
  p <- .mig056_rows_problem(.mig056_analyses(con, P$d10$uuid), .mig056_d10_rows(P$d10), "D10 re-insert"); if (!is.null(p)) return(p)
  v <- .mig056_analyses(con, P$val$uuid); v <- v[match(P$val$uuid, v$uuid), ]
  for (i in seq_len(nrow(P$val))) {
    r <- P$val[i, ]
    ok <- if (r$field == "value") .mig056_num_eq(v$value[i], .mig056_num(r$new)) else .mig056_same(v$value_chr[i], r$new)
    if (!ok) return(sprintf("value plan %s %s %s does not hold %s", r$feature, r$day, r$analyte, r$new))
  }
  lm <- DBI::dbGetQuery(con, sprintf("SELECT * FROM lab_method WHERE uuid IN %s ORDER BY uuid", .mig056_inlist(.mig056_lab_methods$uuid)))
  if (nrow(lm) != 2L) return("a D13 lab_method is missing")
  w <- .mig056_lab_methods[order(.mig056_lab_methods$uuid), ]
  for (f in c("uuid_analyte", "name", "method", "organisation", "api", "comments"))
    if (!all(mapply(.mig056_same, lm[[f]], w[[f]]))) return(sprintf("a D13 lab_method differs in %s", f))
  if (!all(mapply(.mig056_num_eq, lm$rl_low, w$rl_low))) return("a D13 lab_method differs in rl_low")
  if (.mig056_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig056_index_name) != 1L) return("ux_sample_identity is missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL", params = list(.mig056_actor))
  key <- paste(cl$tbl, cl$action); got <- stats::setNames(cl$n, key)
  want <- .mig056_want_log(P)
  if (!setequal(names(got), names(want)) || any(got[names(want)] != want)) {
    return(sprintf("056 change_log is %s, not %s", paste(names(got), got, collapse = ", "), paste(names(want), want, collapse = ", ")))
  }
  NULL
}

.mig056_want_log <- function(P) {
  # db_update logs one row per changed field; db_append one per row.
  # sample: 22 x (uuid_project, comments) + 9 x (alias, comments) + the
  # value-plan samples' comments; project: ES2421689 date_start, date_end, comments.
  c("analysis delete" = 191, "analysis insert" = 191 + 25, "analysis update" = 135 + nrow(P$val),
    "sample update" = 22 * 2 + 9 * 2 + 2 * length(.mig056_dt_fix) + length(unique(P$val$uuid_sample)), "sample insert" = 5,
    "project insert" = 1, "project update" = 3, "lab_method insert" = 2)
}

.mig056_verify <- function(con, P) {
  p <- .mig056_done_problem(con, P)
  if (!is.null(p)) cli::cli_abort(paste0("056 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backup, CSVs -------------------------------------------------------------

mig056_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig056_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig056_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig056_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig056_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) {
    if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
    else if (is.double(out[[f]])) out[[f]] <- ifelse(is.na(out[[f]]), NA_character_, sprintf("%.17g", out[[f]]))
  }
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) > 0 && !identical(back$uuid, as.character(out$uuid))))
    cli::cli_abort("056: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

# ---- apply ----------------------------------------------------------------------

.mig056_step_a <- function(con, P) {
  db_transaction(con, function(con) {
    ids <- P$d10$uuid
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig056_inlist(ids)))
    if (n != length(ids)) cli::cli_abort("056: set-based delete removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
    at <- Sys.time()
    for (u in ids) {
      .st_write_change_log(con, at = at, actor = .mig056_actor, action = "delete", tbl = "analysis",
                           uuid_row = u, field = NA_character_, old = u, new = NA_character_,
                           reason = "056 step A (D10): analysis removed so its sample can be re-pointed to another feature (duckdb FK limitation); re-inserted unchanged with the same uuid in step B",
                           source_hash = NA_character_)
    }
    NULL
  })
}

.mig056_step_b <- function(con, P, recorded_at, sums_before, want_counts) {
  db_transaction(con, function(con) {
    act <- .mig056_actor
    notes <- .mig056_note_sample(P)
    cur <- .mig056_samples(con, names(notes))
    cur_comment <- stats::setNames(cur$comments, cur$uuid)
    # D13
    db_append(con, "lab_method", .mig056_lab_methods, actor = act,
              reason = "056 D13: ALS lab_methods for the corpus's Decachlorobiphenyl (EP066S) surrogate and 'Naphthalene (Ex SVOC)' (EP075(SIM)B) rows")
    # D1 projects
    prj <- data.frame(uuid = .mig056_p20251, uuid_parent = .mig056_epl_quarterly, uuid_root = .mig056_epl_quarterly,
                      uuid_project = NA_character_, name = "ES2420251", type = "Work order", purpose = NA_character_,
                      date_start = .mig056_utc("2024-06-19 00:00:00"), date_end = .mig056_utc("2024-06-19 00:00:00"),
                      regulated_by = NA_character_, cypher = NA_character_, site = NA_character_, value = NA_real_,
                      comments = .mig056_append_note(NA, .mig056_note_p20251), stringsAsFactors = FALSE)
    db_append(con, "project", prj, actor = act, reason = "056 D1: ALS ES2420251, the 19 Jun 2024 Katoomba quarterly (ACIRL 2400-7400-06-01)")
    db_update(con, "project", uuid = .mig056_p21689,
              changes = list(date_start = .mig056_utc("2024-07-01 00:00:00"), date_end = .mig056_utc("2024-07-01 00:00:00"),
                             comments = .mig056_append_note(NA, .mig056_note_p21689)),
              actor = act, reason = "056 D1: ES2421689 was sampled 1 Jul 2024 (ALS ENMRG/XTAB, ACIRL 2400-7400-07)")
    # D1 samples
    for (u in P$s19) {
      db_update(con, "sample", uuid = u, changes = list(uuid_project = .mig056_p20251), actor = act,
                reason = "056 D1: 19 Jun 2024 sample re-filed from ES2421689 to ES2420251 (ACIRL 2400-7400-06-01)")
    }
    ns <- data.frame(uuid = .mig056_new$uuid, uuid_feature_alias = .mig056_new$alias, uuid_project = .mig056_p21689,
                     date = .mig056_utc(.mig056_d1_date), date_start = .mig056_utc(NA), datetime = .mig056_utc(NA),
                     datetime_start = .mig056_utc(NA), organisation = "ACIRL", person = NA_character_, purpose = NA_character_,
                     comments = .mig056_append_note(NA, notes[.mig056_new$uuid]), stringsAsFactors = FALSE)
    db_append(con, "sample", ns, actor = act, reason = "056 D1: ALS ES2421689's 1 Jul 2024 samples (uuid = ALS lab id)")
    for (i in seq_len(nrow(P$mv))) {
      db_update(con, "analysis", uuid = P$mv$uuid[[i]], changes = list(uuid_sample = P$mv$to_sample[[i]]), actor = act,
                reason = sprintf("056 D1: ES2421689 ALS result moved from the 19 Jun 2024 sample %s to the 1 Jul 2024 sample %s",
                                 substr(P$mv$from_sample[[i]], 1, 8), P$mv$to_sample[[i]]))
    }
    db_append(con, "analysis", .mig056_fld_rows(P$fld), actor = act,
              reason = "056 D1: 1 Jul 2024 ACIRL field readings of 2400-7400-07 Surface Sites (temperature, pH, EC, flow, appearance)")
    # D10
    for (i in seq_len(nrow(.mig056_repoint))) {
      r <- .mig056_repoint[i, ]
      db_update(con, "sample", uuid = r$uuid, changes = list(uuid_feature_alias = r$to_alias), actor = act,
                reason = sprintf("056 D10: %s %s re-pointed %s -> %s (%s self alias)", r$wo, r$day, r$from_feat, r$to_feat, substr(r$to_alias, 1, 8)))
      if (!is.na(r$new_dt)) {
        db_update(con, "sample", uuid = r$uuid, changes = list(datetime = .mig056_utc(r$new_dt), datetime_start = .mig056_utc(r$new_dt)), actor = act,
                  reason = sprintf("056 D10: %s sampled %s Sydney per the ALS ESdat Sample file (was the legacy placeholder time); tells it from %s, the same day's other Lawson delivery",
                                   r$wo, r$syd_time, r$twin_wo))
      }
    }
    db_append(con, "analysis", .mig056_d10_rows(P$d10), actor = act,
              reason = "056 step B (D10): re-inserted unchanged (same uuid, every column as at marker 1055) on its re-pointed sample")
    # D2/D3 values
    for (i in seq_len(nrow(P$val))) {
      r <- P$val[i, ]
      ch <- if (r$field == "value") list(value = .mig056_num(r$new)) else list(value_chr = r$new)
      db_update(con, "analysis", uuid = r$uuid, changes = ch, actor = act,
                reason = sprintf("056 %s: %s %s %s ACIRL field %s %s -> %s per ACIRL %s %s", r$item, r$feature, r$day, r$work_order,
                                 r$analyte, r$old, r$new, r$report, r$cell))
    }
    # comments (every touched existing sample)
    for (u in setdiff(names(notes), .mig056_new$uuid)) {
      db_update(con, "sample", uuid = u, changes = list(comments = .mig056_append_note(cur_comment[[u]], notes[[u]])), actor = act,
                reason = "056: note of the corpus-import correction appended to the sample comments")
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)", params = list(.mig056_marker_version, recorded_at))
    .mig056_verify_b(con, P, cur_comment)
    got <- .mig056_counts(con)
    if (!identical(got, want_counts)) .mig056_fail(sprintf("counts are not as planned: %s",
      paste(names(got), unlist(got), unlist(want_counts), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig056_checksum(con, P, P$s19))) .mig056_fail("something outside the planned rows moved.")
    NULL
  })
}

# Inside B the index is dropped; verify everything but the index, and that the
# comments are the pre-056 text plus the note.
.mig056_verify_b <- function(con, P, cur_comment) {
  notes <- .mig056_note_sample(P)
  S <- .mig056_samples(con, names(notes))
  for (u in names(notes)) {
    want <- .mig056_append_note(if (u %in% names(cur_comment)) cur_comment[[u]] else NA, notes[[u]])
    if (!.mig056_same(S$comments[S$uuid == u], want)) .mig056_fail(sprintf("sample %s comments are not as planned", substr(u, 1, 8)))
  }
  p <- .mig056_done_problem_noindex(con, P)
  if (!is.null(p)) .mig056_fail(paste("verify failed:", p))
}
.mig056_done_problem_noindex <- function(con, P) {
  p <- .mig056_done_problem(con, P)
  if (!is.null(p) && p == "ux_sample_identity is missing") return(NULL)
  p
}

.mig056_apply <- function(con, P, recorded_at, state, logf) {
  if (identical(state, "pre")) {
    .mig056_step_a(con, P)
    logf("Step A: deleted the 191 analyses of the 9 D10 samples (committed).")
  }
  s19 <- P$s19
  sums_before <- .mig056_checksum(con, P, s19)
  want <- .mig056_counts(con)
  want$analysis <- want$analysis + 191L + 25L
  want$sample <- want$sample + 5L
  want$project <- want$project + 1L
  want$lab_method <- want$lab_method + 2L
  wl <- .mig056_want_log(P)
  want$change_log <- want$change_log + as.integer(sum(wl) - 191)
  want$schema_version <- want$schema_version + 1L
  DBI::dbExecute(con, sprintf("DROP INDEX %s", .mig056_index_name))
  logf("Dropped %s (committed).", .mig056_index_name)
  tryCatch({
    .mig056_step_b(con, P, recorded_at, sums_before, want)
    logf("Step B committed.")
  }, finally = {
    if (.mig056_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = ?", .mig056_index_name) == 0L) {
      DBI::dbExecute(con, .mig056_index_sql)
      logf("Re-created %s.", .mig056_index_name)
    }
  })
  invisible(TRUE)
}

.mig056_check_preconditions <- function(con, P) {
  if (.mig056_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig056_requires) == 0L)
    .mig056_fail(sprintf("marker %d (055) is required first.", .mig056_requires))
  p <- .mig056_pre_problem(con, P, post_a = FALSE)
  if (is.null(p)) return("pre")
  q <- .mig056_pre_problem(con, P, post_a = TRUE)
  if (is.null(q)) return("post_a")
  .mig056_fail(sprintf("the database is neither pre-056 (%s) nor post-step-A (%s). Nothing written; restore from the backup if a step failed.", p, q))
}

.mig056_plan <- function(con) {
  P <- .mig056_load()
  s19 <- .mig056_samples19_of(con, .mig056_p21689)$uuid
  if (length(s19) == 0L) s19 <- .mig056_samples19_of(con, .mig056_p20251)$uuid   # post-056
  P$s19 <- sort(s19)
  P
}

mig056_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig056_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig056_verify(check_con, .mig056_plan(check_con)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("056 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  st <- tryCatch({ P <- .mig056_plan(pre_con); .mig056_check_preconditions(pre_con, P) },
                 finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("State: %s. Plan: D1 project ES2420251 + 22 samples re-filed, 5 1-Jul samples, 135 ALS analyses moved, 25 field readings; D10 9 samples re-pointed (191 analyses re-inserted); D2/D3 %d values; D13 2 lab_methods; notes on %d samples and 2 projects.",
       st, nrow(P$val), length(.mig056_note_sample(P)))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_, recorded_at = NA)))
  }

  if (identical(st, "pre")) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch({
      a_ids <- c(P$mv$uuid, P$d10$uuid, P$val$uuid)
      .mig056_write_csv(.mig056_analyses(bk_con, a_ids), file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig056_name)))
      s_ids <- c(P$s19, .mig056_repoint$uuid, unique(P$val$uuid_sample))
      .mig056_write_csv(DBI::dbGetQuery(bk_con, sprintf('SELECT * FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig056_inlist(s_ids))),
                        file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig056_name)))
      .mig056_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM project WHERE uuid = ?", params = list(.mig056_p21689)),
                        file.path(csv_dir, sprintf("%s-BACKUP-project.csv", .mig056_name)))
      .mig056_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM lab_method WHERE uuid IN %s", .mig056_inlist(.mig056_lab_methods$uuid))),
                        file.path(csv_dir, sprintf("%s-BACKUP-lab_method.csv", .mig056_name)))
    }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    logf("Row backups written to %s", csv_dir)
  }
  backup_path <- mig056_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    st2 <- .mig056_check_preconditions(con, P)   # re-read under the write lock
    .mig056_apply(con, P, recorded_at, st2, logf)
  }, db = db)
  vcon <- st_connect(db, read_only = TRUE)
  tryCatch(.mig056_verify(vcon, .mig056_plan(vcon)), finally = DBI::dbDisconnect(vcon, shutdown = TRUE))
  logf("%s migrated successfully (marker %d).", .mig056_name, .mig056_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command, recorded_at = recorded_at))
}
