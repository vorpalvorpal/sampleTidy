# Operator-run migration: register the sampling-point aliases the historical
# corpus import needs - the confident proposals of the corpus alias analysis,
# the date split of "Lined leachate dam", and two groups of site-less /
# wrong-site labels bounded to the reports that wrote them.
# Marker 1053. Requires 1052.
#
# Authority: Robin (B accepted: Aug 2020 "Lined leachate dam" is
# Katoomba K.L01). A and C/D AWAIT Robin's check of the alias list
# (dev/MIGRATIONS.md) - do not apply before he has seen
# 053-corpus-feature-aliases-INPUT.csv. F: Robin's ruling of 2026-10-20 (a raw
# point whose same-day values equal a named point's live values takes that
# point); its 27 rows await his check of 053-corpus-feature-aliases-INPUT-F.csv.
#
# ---- WHAT ----------------------------------------------------------------------
# A. 162 CONFIDENT proposals (149 descriptive, 13 transcription_error), read
#    from `053-corpus-feature-aliases-INPUT.csv` beside this file (columns
#    raw_spelling, alias_key, target_feature, kind, date_start, date_end,
#    evidence; copied from the corpus analysis' proposed_aliases.csv, rows
#    confidence == "confident"). One row each: name = the first spelling of
#    raw_spelling (15 rows list case variants joined by " | "; every variant
#    folds to the same key, asserted), alias_key = .rc_feature_key(name), which
#    must equal the CSV's alias_key; uuid_feature = the one feature named
#    target_feature; kind from the CSV; auto_assign TRUE; confirmed_by NULL;
#    date_start/date_end from the CSV (empty = unbounded); comments
#    "053: <evidence>".
# B. "Lined leachate dam" (evidence: corpus3/leachdam/lined_leachate_verdicts.csv;
#    the Aug 2020 samples' chemistry is Katoomba's and live already holds them
#    on K.L01; Robin accepted):
#      * alias 8cfed697-333a-44fb-96bb-df2f7b53bc68 (-> B.L02, descriptive,
#        undated): date_end = 2020-07-31;
#      * a copy of it (same name/kind/auto_assign/confirmed_by, -> B.L02) from
#        2020-09-01, open end;
#      * an arm -> K.L01, descriptive, auto, confirmed_by 'R. Shannon',
#        2020-08-01..2020-08-31.
# C. Site-less Blaxland labels of ACIRL reports 24006989-09, 24006989-10,
#    24006989-12, 2400-7127-03 (Sep 2020 - Mar 2021): 'S3' -> B.S03 and
#    'Bore 8' -> B.MW08, descriptive, auto, confirmed_by NULL, bounded
#    2020-09-28..2021-03-30. The existing undated 'S3' -> K.S03 and
#    'Bore 8' -> K.MW08 arms are untouched.
# D. Katoomba Sep-2023 quarterly 2400-7287-08-01 (ALS ES2332504) writes the
#    Katoomba bores as B.MW01..B.MW04: 'B.MW01'..'B.MW04' -> K.MW01..K.MW04,
#    transcription_error, auto, confirmed_by NULL, bounded 2023-09-20..2023-09-20.
# E. 84 VISIT-BOUNDED proposals (83 descriptive, 1 transcription_error), read
#    from `053-corpus-feature-aliases-INPUT-E.csv` (raw_spelling, alias_key,
#    target_feature, kind, day, wo, n_equal, n_overlap; from the corpus
#    analysis' proposed_visit_aliases.csv, sorted by key/day): one arm per row,
#    date_start = date_end = the Sydney day of the visit, auto, confirmed_by
#    NULL, comments "053 E: same-visit evidence <wo> <day>: <n_equal>/<n_overlap>
#    equal". A key may carry several arms, to different features on different
#    days (e.g. "Effluent (E1)" -> B.E01 on 2020-02-07/07-27, K.E01 on
#    2020-07-28/08-10); the collision check below forbids any two of them, or
#    any of them and an existing arm, to different features on one day.
#    9 arms fall before their feature's date_start (MP#1/2/4, MP # 1/2/4 ->
#    K.MW01/02/04 in Nov 2020 - May 2021; the features start 2021-09-08). The
#    resolver reads feature.date_end only (.rc_narrow_live_feature), never
#    date_start, so they resolve and ARE included; asserted at 9.
# F. 27 SAME-DAY VALUE-MATCH arms (25 descriptive, 2 transcription_error) on
#    23 spellings, read from `053-corpus-feature-aliases-INPUT-F.csv` (same
#    columns as E). Robin, 2026-10-20: where a raw point's values equal the
#    values live already holds for a named point on the same Sydney day,
#    Robin resolved that alias when he filed it - use that mapping unless
#    there is strong reason not to. Evidence: every pending corpus sample of
#    the spelling on that day has a unique conflict-free match (>= 2 equal
#    analytes, field and lab readings compared separately, no conflicting
#    analyte) to one named feature's live (1052) sample of that day, at the
#    report's site (corpus alias analysis phase 2, proposed_value_aliases.csv;
#    rejects and parked spellings are listed there). Built exactly as E: one
#    arm per row, date_start = date_end = day, auto, confirmed_by NULL,
#    comments "053 F: same-day value match <wo> <day>: <n_equal>/<n_overlap>
#    equal to live". No F (key, day) repeats an E (key, day); F arms sit on
#    other days of E keys, to the same feature. The value match
#    'S22' 2020-03-06 -> B.S06 (33/121 equal, ES2007947) is NOT included: it
#    contradicts its label, so it is parked for Robin (coordinator 2026-10-20).
#    4 arms (MP # 1..4 -> K.MW01..04, 2020-08-11) predate their feature's
#    date_start 2021-09-08 - kept, as for E; asserted at 4.
#
# C and D deliberately leave TWO live auto arms on four keys inside their
# windows (the new arm and the existing K.S03 / K.MW08 / B.MW02 / B.MW04 arm):
# by alias alone such a label is ambiguous (2 candidates -> review), and it is
# the ACIRL site-from-cited-work-order veto (corpus fix C2) that picks the
# right site. B.MW01 and B.MW03 are retired (2008), so their self arms are not
# live and D's B.MW01/B.MW03 arms resolve to K alone. Those four collisions are
# planned and asserted exactly; any other overlap of an inserted arm with a
# live auto arm to a different feature aborts.
#
# New rows: n_seen 0, first_seen/last_seen NULL (never seen yet), uuid derived
# from (marker, key, target, window) so a rehearsal's INSERTED CSV is
# byte-identical to the next.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1052 present;
#   * the A input is 162 rows, kinds descriptive/transcription_error, keys unique
#     and equal to .rc_feature_key of every spelling, ISO dates, start <= end;
#     the E input is 84 rows and the F input 27, no empty cell, one row per
#     (key, day) within each and across the two;
#   * every target names exactly one feature, not ended (feature date_end)
#     before the alias window opens; exactly 9 E and 4 F arms before feature date_start; B.S03/B.MW08 live over all of C's window,
#     K.MW01..04 on 2023-09-20;
#   * alias 8cfed697 is exactly as described above, and no other alias row has
#     key 'lined leachate dam';
#   * the pre-existing rows sharing a key with any inserted row are exactly:
#     s3 -> K.S03, bore 8 -> K.MW08, b.mw0n -> B.MW0n (self), and the pending
#     'B.E01 Effluent' (uuid_feature NULL, auto FALSE; left as it is - it holds
#     3 live samples and 3 open unknown_feature items, see MIGRATIONS.md);
#     no E or F key has any pre-existing row;
#   * the planned key collisions (inserted arm vs live auto arm to another
#     feature, overlapping windows - alias bounds narrowed by the feature's
#     date_end, as the resolver does - after B's split) are exactly the four of
#     C/D: s3/K.S03, bore 8/K.MW08, b.mw02/B.MW02, b.mw04/B.MW04;
#   * K.MW01..04 each have exactly one sample on Sydney 2023-09-20 in project
#     ES2332504, and no B.MW01..04 sample exists on Sydney 2023-09-20;
#   * no planned uuid exists yet.
#
# Writes, in one transaction (actor "053-corpus-feature-aliases"): 281
# feature_alias inserts by db_append (162 A + 2 B + 2 C + 4 D + 84 E + 27 F; one change_log
# insert row each), 1 db_update (B's date_end; one change_log row), the marker.
# Every other table, and every untouched feature_alias row and column, is
# checksummed before and after. Backups: verified whole-file snapshot,
# `053-...-BACKUP-feature_alias.csv` (the updated row, before) and
# `053-...-INSERTED-feature_alias.csv` (the 281 rows, after).
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/053-corpus-feature-aliases.R", envir = env)
#   env$mig053_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig053_marker_version <- 1053L
.mig053_requires <- 1052L
.mig053_name <- "053-corpus-feature-aliases"
.mig053_actor <- .mig053_name
.mig053_input_default <- c(A = file.path("dev", "migrations", "053-corpus-feature-aliases-INPUT.csv"),
                           E = file.path("dev", "migrations", "053-corpus-feature-aliases-INPUT-E.csv"),
                           F = file.path("dev", "migrations", "053-corpus-feature-aliases-INPUT-F.csv"))
.mig053_expected_n <- c(A = 162L, B = 2L, C = 2L, D = 4L, E = 84L, F = 27L)
# E arms dated before their target feature's date_start (K.MW01/02/04 start
# 2021-09-08). The resolver does not read feature.date_start, so they resolve.
.mig053_expected_pre_start <- 9L
# F arms dated before their feature's date_start (MP # 1..4 -> K.MW01..04 on 2020-08-11).
.mig053_expected_pre_start_f <- 4L
.mig053_kinds <- c("descriptive", "transcription_error")
.mig053_confirmed_by <- "R. Shannon"

.mig053_ll_uuid <- "8cfed697-333a-44fb-96bb-df2f7b53bc68"
.mig053_ll_key <- "lined leachate dam"
.mig053_ll_end <- as.Date("2020-07-31")
.mig053_ll_k_start <- as.Date("2020-08-01")
.mig053_ll_k_end <- as.Date("2020-08-31")
.mig053_ll_resume <- as.Date("2020-09-01")
.mig053_c_start <- as.Date("2020-09-28")
.mig053_c_end <- as.Date("2021-03-30")
.mig053_d_day <- as.Date("2023-09-20")
.mig053_d_project <- "ES2332504"

# Pre-existing rows that share a key with an inserted row (B's own key aside):
# key -> feature name (NA = pending, no feature).
.mig053_expected_existing <- c(`s3` = "K.S03", `bore 8` = "K.MW08", `b.mw01` = "B.MW01", `b.mw02` = "B.MW02",
                               `b.mw03` = "B.MW03", `b.mw04` = "B.MW04", `b.e01 effluent` = NA_character_)
# Planned collisions: key -> the other feature that keeps a live auto arm in the
# window. B.MW01 (date_end 2008-12-31) and B.MW03 (2008-05-08) are retired, and
# the resolver drops an expired feature unconditionally, so their self arms are
# NOT live in 2023: D's B.MW01/B.MW03 arms resolve to K alone.
.mig053_planned_collisions <- c(`s3` = "K.S03", `bore 8` = "K.MW08", `b.mw02` = "B.MW02", `b.mw04` = "B.MW04")

.mig053_reason <- c(
  A = "053 (corpus alias analysis, confident proposals; awaiting Robin's check): register corpus spelling as alias",
  B = "053 (Robin, accepted): Aug 2020 'Lined leachate dam' is Katoomba K.L01; split the B.L02 alias around it",
  C = "053: site-less Blaxland labels S3 / Bore 8 in ACIRL reports 24006989-09/-10/-12, 2400-7127-03 (Sep 2020-Mar 2021)",
  D = "053: Katoomba Sep-2023 quarterly 2400-7287-08-01 (ES2332504) labels Katoomba bores B.MW01-04",
  E = "053 E (corpus alias analysis, visit-bounded proposals; awaiting Robin's check): alias for one Sydney day, same-visit evidence",
  F = "053 F (Robin 2026-10-20: same-day values equal live -> Robin's own resolution): alias for one Sydney day")
.mig053_comment_b_copy <- paste0("053: 'Lined leachate dam' is Blaxland B.L02 again from Sep 2020; copy of alias ",
                                 "8cfed697 (ended 2020-07-31) - Aug 2020 is Katoomba K.L01 (lined_leachate_verdicts.csv)")
.mig053_comment_b_k <- paste0("053: Aug 2020 'Lined leachate dam' samples (ES2027524 .. ES2028983) are Katoomba K.L01: ",
                              "chemistry nearer K than B, live already holds them on K.L01 (lined_leachate_verdicts.csv; Robin accepted)")
.mig053_comment_c <- function(target) sprintf(paste0("053: site-less label in Blaxland ACIRL reports 24006989-09, ",
  "24006989-10, 24006989-12, 2400-7127-03 (Sep 2020-Mar 2021) -> %s; the K arm stays, ACIRL site veto picks B"), target)
.mig053_comment_d <- function(target) sprintf(paste0("053: Katoomba Sep-2023 quarterly 2400-7287-08-01 (ALS ES2332504) ",
  "writes Katoomba bore %s as %s; same visit live on %s 2023-09-20"), target, sub("^K", "B", target), target)

.mig053_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig053_fail <- function(msg) cli::cli_abort(paste0(.mig053_name, ": ", msg), class = "sampletidy_error")
.mig053_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", x), "'", collapse = ","), ")")
.mig053_same_date <- function(x, y) {
  x <- as.Date(x); y <- as.Date(y)
  (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y)
}
.mig053_same_chr <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & x == y)
# Windows [s1, e1] and [s2, e2] (NA = unbounded) share a day.
.mig053_overlap <- function(s1, e1, s2, e2) {
  (is.na(e2) | is.na(s1) | s1 <= e2) & (is.na(e1) | is.na(s2) | s2 <= e1)
}
.mig053_uuid <- function(key, target, ds, de) {
  h <- digest::digest(paste(.mig053_marker_version, key, target, format(ds), format(de), sep = "|"),
                      algo = "sha1", serialize = FALSE)
  ch <- strsplit(substr(h, 1, 32), "")[[1]]
  ch[13] <- "5"
  ch[17] <- c("8", "9", "a", "b")[strtoi(ch[17], 16L) %% 4L + 1L]
  h <- paste(ch, collapse = "")
  paste(substr(h, 1, 8), substr(h, 9, 12), substr(h, 13, 16), substr(h, 17, 20), substr(h, 21, 32), sep = "-")
}

.mig053_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analysis", "sample", "project", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig053_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

.mig053_read_input <- function(input) {
  if (!file.exists(input)) .mig053_fail(sprintf("input %s not found (run from the repo root).", input))
  x <- utils::read.csv(input, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  need <- c("raw_spelling", "alias_key", "target_feature", "kind", "date_start", "date_end", "evidence")
  if (!identical(names(x), need)) .mig053_fail(sprintf("input columns are %s", paste(names(x), collapse = ",")))
  probs <- character(0)
  if (nrow(x) != .mig053_expected_n[["A"]])
    probs <- c(probs, sprintf("input has %d rows, expected %d", nrow(x), .mig053_expected_n[["A"]]))
  if (any(is.na(x$raw_spelling) | is.na(x$alias_key) | is.na(x$target_feature) | is.na(x$evidence)))
    probs <- c(probs, "input has an empty raw_spelling/alias_key/target_feature/evidence")
  if (any(!(x$kind %in% .mig053_kinds))) probs <- c(probs, "input has a kind other than descriptive/transcription_error")
  sp <- strsplit(x$raw_spelling, " | ", fixed = TRUE)
  x$name <- vapply(sp, `[[`, character(1), 1L)
  fold_ok <- mapply(function(s, k) all(.mig053_same_chr(.rc_feature_key(s), k)), sp, x$alias_key)
  if (!all(fold_ok)) probs <- c(probs, sprintf("spelling(s) not folding to their alias_key: %s",
                                               paste(x$raw_spelling[!fold_ok], collapse = "; ")))
  if (anyDuplicated(x$alias_key)) probs <- c(probs, "input has a duplicate alias_key")
  bad_d <- (!is.na(x$date_start) & !grepl("^\\d{4}-\\d{2}-\\d{2}$", x$date_start)) |
    (!is.na(x$date_end) & !grepl("^\\d{4}-\\d{2}-\\d{2}$", x$date_end))
  if (any(bad_d)) probs <- c(probs, "input has a non-ISO date")
  x$date_start <- as.Date(x$date_start); x$date_end <- as.Date(x$date_end)
  if (any(!is.na(x$date_start) & !is.na(x$date_end) & x$date_start > x$date_end, na.rm = TRUE))
    probs <- c(probs, "input has date_start > date_end")
  if (length(probs)) .mig053_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  x
}

# Parts E and F: one visit-bounded arm per row (date_start = date_end = day).
.mig053_read_input_e <- function(input, section = "E") {
  if (!file.exists(input)) .mig053_fail(sprintf("input %s not found (run from the repo root).", input))
  x <- utils::read.csv(input, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  need <- c("raw_spelling", "alias_key", "target_feature", "kind", "day", "wo", "n_equal", "n_overlap")
  if (!identical(names(x), need)) .mig053_fail(sprintf("%s input columns are %s", section, paste(names(x), collapse = ",")))
  probs <- character(0)
  if (nrow(x) != .mig053_expected_n[[section]])
    probs <- c(probs, sprintf("%s input has %d rows, expected %d", section, nrow(x), .mig053_expected_n[[section]]))
  if (any(is.na(as.matrix(x)))) probs <- c(probs, paste(section, "input has an empty cell"))
  if (any(!(x$kind %in% .mig053_kinds))) probs <- c(probs, paste(section, "input has a kind other than descriptive/transcription_error"))
  if (any(!.mig053_same_chr(.rc_feature_key(x$raw_spelling), x$alias_key)))
    probs <- c(probs, paste(section, "input has a spelling not folding to its alias_key"))
  if (any(!grepl("^\\d{4}-\\d{2}-\\d{2}$", x$day))) probs <- c(probs, paste(section, "input has a non-ISO day"))
  if (anyDuplicated(x[, c("alias_key", "day")])) probs <- c(probs, paste(section, "input has two rows for one key and day"))
  if (any(!grepl("^[0-9]+$", x$n_equal) | !grepl("^[0-9]+$", x$n_overlap)))
    probs <- c(probs, paste(section, "input has a non-integer n_equal/n_overlap"))
  if (length(probs)) .mig053_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  x$day <- as.Date(x$day)
  x
}

# The 281 rows to insert. A pure function of the input files and feature names,
# so verify can rebuild it after the migration.
.mig053_plan <- function(con, input) {
  x <- .mig053_read_input(input[["A"]])
  xe <- .mig053_read_input_e(input[["E"]], "E")
  xf <- .mig053_read_input_e(input[["F"]], "F")
  if (any(paste(xf$alias_key, xf$day) %in% paste(xe$alias_key, xe$day)))
    .mig053_fail("an F row repeats an E (key, day). Nothing written.")
  feat <- DBI::dbGetQuery(con, "SELECT uuid, name, site, date_start, date_end FROM feature")
  ll <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias WHERE uuid = ?", params = list(.mig053_ll_uuid))
  if (nrow(ll) != 1L) .mig053_fail(sprintf("alias %s is %d rows, expected 1. Nothing written.", .mig053_ll_uuid, nrow(ll)))
  mk <- function(section, name, target, kind, auto, confirmed_by, ds, de, comments) {
    data.frame(section = section, name = name, alias_key = .rc_feature_key(name), target = target, kind = kind,
               auto_assign = auto, confirmed_by = confirmed_by, date_start = as.Date(ds), date_end = as.Date(de),
               comments = comments, stringsAsFactors = FALSE)
  }
  k_targets <- sprintf("K.MW%02d", 1:4)
  plan <- rbind(
    mk("A", x$name, x$target_feature, x$kind, TRUE, NA_character_, x$date_start, x$date_end, paste0("053: ", x$evidence)),
    mk("B", ll$name, "B.L02", ll$kind, ll$auto_assign, ll$confirmed_by, .mig053_ll_resume, NA, .mig053_comment_b_copy),
    mk("B", ll$name, "K.L01", "descriptive", TRUE, .mig053_confirmed_by, .mig053_ll_k_start, .mig053_ll_k_end,
       .mig053_comment_b_k),
    mk("C", c("S3", "Bore 8"), c("B.S03", "B.MW08"), "descriptive", TRUE, NA_character_, .mig053_c_start,
       .mig053_c_end, .mig053_comment_c(c("B.S03", "B.MW08"))),
    mk("D", sprintf("B.MW%02d", 1:4), k_targets, "transcription_error", TRUE, NA_character_, .mig053_d_day,
       .mig053_d_day, .mig053_comment_d(k_targets)),
    mk("E", xe$raw_spelling, xe$target_feature, xe$kind, TRUE, NA_character_, xe$day, xe$day,
       sprintf("053 E: same-visit evidence %s %s: %s/%s equal", xe$wo, format(xe$day), xe$n_equal, xe$n_overlap)),
    mk("F", xf$raw_spelling, xf$target_feature, xf$kind, TRUE, NA_character_, xf$day, xf$day,
       sprintf("053 F: same-day value match %s %s: %s/%s equal to live", xf$wo, format(xf$day), xf$n_equal, xf$n_overlap)))
  if (any(plan$section == "A" & plan$alias_key != x$alias_key[match(plan$name, x$name)]))
    .mig053_fail("an A row's .rc_feature_key differs from the input's alias_key. Nothing written.")
  n_feat <- table(feat$name)
  bad_t <- unique(plan$target[!(plan$target %in% names(n_feat)) | n_feat[plan$target] != 1L])
  if (length(bad_t)) .mig053_fail(sprintf("target(s) not exactly one feature: %s. Nothing written.", paste(bad_t, collapse = ", ")))
  fi <- match(plan$target, feat$name)
  plan$uuid_feature <- feat$uuid[fi]
  plan$f_date_start <- .rc_as_date_bound(feat$date_start[fi])
  plan$f_date_end <- .rc_as_date_bound(feat$date_end[fi])
  plan$uuid <- mapply(.mig053_uuid, plan$alias_key, plan$target, plan$date_start, plan$date_end, USE.NAMES = FALSE)
  if (anyDuplicated(plan$uuid)) .mig053_fail("the plan holds a duplicate uuid.")
  got <- vapply(names(.mig053_expected_n), function(s) sum(plan$section == s), integer(1))
  if (!identical(got, .mig053_expected_n)) .mig053_fail("plan section counts differ from the expected 162/2/2/4/84/27.")
  rownames(plan) <- NULL
  plan
}

.mig053_rows <- function(plan) {
  tibble::tibble(
    uuid = plan$uuid, uuid_feature = plan$uuid_feature, name = plan$name, alias_key = plan$alias_key,
    kind = plan$kind, n_seen = 0L, auto_assign = plan$auto_assign,
    first_seen = as.POSIXct(rep(NA_real_, nrow(plan)), origin = "1970-01-01", tz = "UTC"),
    last_seen = as.POSIXct(rep(NA_real_, nrow(plan)), origin = "1970-01-01", tz = "UTC"),
    confirmed_by = plan$confirmed_by, comments = plan$comments,
    date_start = plan$date_start, date_end = plan$date_end)
}

.mig053_problems <- function(con, plan) {
  probs <- character(0)
  # B: the original arm, exactly.
  ll <- DBI::dbGetQuery(con, "SELECT fa.*, f.name AS fname FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
                              WHERE fa.uuid = ?", params = list(.mig053_ll_uuid))
  if (nrow(ll) != 1L || !identical(ll$name, "Lined leachate dam") || !identical(ll$alias_key, .mig053_ll_key) ||
      !identical(ll$fname, "B.L02") || !identical(ll$kind, "descriptive") || !isTRUE(ll$auto_assign) ||
      !is.na(ll$date_start) || !is.na(ll$date_end))
    probs <- c(probs, sprintf("alias %s is not 'Lined leachate dam' -> B.L02, descriptive, auto, undated", .mig053_ll_uuid))
  n_ll <- .mig053_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE alias_key = ? AND uuid <> ?",
                         .mig053_ll_key, .mig053_ll_uuid)
  if (n_ll != 0L) probs <- c(probs, sprintf("%d other alias row(s) carry key '%s'", n_ll, .mig053_ll_key))
  n_lls <- .mig053_scalar(con, "SELECT COUNT(*) FROM sample WHERE uuid_feature_alias = ?
    AND CAST(coalesce(date, datetime) + INTERVAL 11 HOUR AS DATE) > ?", .mig053_ll_uuid, .mig053_ll_end)
  if (n_lls != 0L) probs <- c(probs, sprintf("%d sample(s) on alias %s after %s would fall outside its new window",
                                             n_lls, .mig053_ll_uuid, .mig053_ll_end))
  # No planned uuid exists yet.
  n_u <- .mig053_scalar(con, sprintf("SELECT COUNT(*) FROM feature_alias WHERE uuid IN %s", .mig053_inlist(plan$uuid)))
  if (n_u != 0L) probs <- c(probs, sprintf("%d planned uuid(s) already exist", n_u))
  # Every target live for some day of its alias window; C/D targets over all of it.
  # "Live" as the resolver judges it: feature date_end only (date_start is not read).
  live_some <- .mig053_overlap(plan$date_start, plan$date_end, NA, plan$f_date_end)
  if (!all(live_some)) probs <- c(probs, sprintf("target ended before the alias window: %s",
                                                 paste(plan$name[!live_some], "->", plan$target[!live_some], collapse = "; ")))
  pre <- sum(plan$section == "E" & !is.na(plan$f_date_start) & plan$date_end < plan$f_date_start)
  if (pre != .mig053_expected_pre_start)
    probs <- c(probs, sprintf("%d E arm(s) before their feature's date_start, measured %d", pre, .mig053_expected_pre_start))
  pre_f <- sum(plan$section == "F" & !is.na(plan$f_date_start) & plan$date_end < plan$f_date_start)
  if (pre_f != .mig053_expected_pre_start_f)
    probs <- c(probs, sprintf("%d F arm(s) before their feature's date_start, measured %d", pre_f, .mig053_expected_pre_start_f))
  cd <- plan$section %in% c("C", "D")
  live_all <- (is.na(plan$f_date_start) | plan$f_date_start <= plan$date_start) &
    (is.na(plan$f_date_end) | plan$f_date_end >= plan$date_end)
  if (any(cd & !live_all)) probs <- c(probs, sprintf("C/D target not live over the whole window: %s",
                                                     paste(plan$target[cd & !live_all], collapse = ", ")))
  # Pre-existing rows sharing an inserted key.
  fa <- DBI::dbGetQuery(con, "SELECT fa.uuid, fa.name, fa.alias_key, fa.kind, fa.auto_assign, fa.uuid_feature,
      fa.date_start, fa.date_end, f.name AS fname FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature")
  ex <- fa[fa$alias_key %in% plan$alias_key & fa$uuid != .mig053_ll_uuid & !(fa$uuid %in% plan$uuid), , drop = FALSE]
  want <- .mig053_expected_existing
  got_ok <- nrow(ex) == length(want) && setequal(ex$alias_key, names(want)) &&
    all(.mig053_same_chr(ex$fname, unname(want[ex$alias_key])))
  pend <- ex[is.na(ex$uuid_feature), , drop = FALSE]
  if (!got_ok || nrow(pend) != 1L || isTRUE(pend$auto_assign) || !identical(pend$kind, "pending"))
    probs <- c(probs, sprintf("pre-existing rows on the inserted keys are not the expected 7: %s",
                              paste(sprintf("%s -> %s (%s)", ex$name, ex$fname, ex$kind), collapse = "; ")))
  # Collisions, judged on the state AFTER B's split.
  fa$date_start <- .rc_as_date_bound(fa$date_start); fa$date_end <- .rc_as_date_bound(fa$date_end)
  fa$date_end[fa$uuid == .mig053_ll_uuid] <- .mig053_ll_end
  # An arm is live while its alias window is AND its feature has not ended
  # (.rc_narrow_live_feature; feature date_start is not read by the resolver).
  fde <- DBI::dbGetQuery(con, "SELECT uuid, date_end FROM feature")
  fde$date_end <- .rc_as_date_bound(fde$date_end)
  arm_end <- function(de, uf) {
    e <- fde$date_end[match(uf, fde$uuid)]
    out <- de
    out[is.na(out) | (!is.na(e) & e < out)] <- e[is.na(out) | (!is.na(e) & e < out)]
    out
  }
  fa$date_end <- arm_end(fa$date_end, fa$uuid_feature)
  arms <- rbind(fa[, c("uuid", "alias_key", "auto_assign", "uuid_feature", "date_start", "date_end")],
                data.frame(uuid = plan$uuid, alias_key = plan$alias_key, auto_assign = plan$auto_assign,
                           uuid_feature = plan$uuid_feature, date_start = plan$date_start,
                           date_end = arm_end(plan$date_end, plan$uuid_feature),
                           stringsAsFactors = FALSE))
  arms <- arms[.rc_is_true_vec(arms$auto_assign) & !is.na(arms$uuid_feature), , drop = FALSE]
  fnames <- DBI::dbGetQuery(con, "SELECT uuid, name FROM feature")
  coll <- character(0)
  for (i in seq_len(nrow(plan))) {
    o <- arms[arms$alias_key == plan$alias_key[[i]] & arms$uuid != plan$uuid[[i]] &
                arms$uuid_feature != plan$uuid_feature[[i]], , drop = FALSE]
    o <- o[.mig053_overlap(plan$date_start[[i]], plan$date_end[[i]], o$date_start, o$date_end), , drop = FALSE]
    coll <- c(coll, sprintf("%s|%s", rep(plan$alias_key[[i]], nrow(o)), fnames$name[match(o$uuid_feature, fnames$uuid)]))
  }
  want_coll <- sprintf("%s|%s", names(.mig053_planned_collisions), unname(.mig053_planned_collisions))
  if (!setequal(coll, want_coll) || length(coll) != length(want_coll))
    probs <- c(probs, sprintf("key collisions are {%s}, planned {%s}", paste(sort(coll), collapse = ", "),
                              paste(sort(want_coll), collapse = ", ")))
  # D: the Katoomba visit is live on K.MW01..04; nothing on B.MW01..04 that day.
  dk <- DBI::dbGetQuery(con, sprintf("SELECT f.name, COUNT(*) AS n FROM sample s
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
      JOIN project p ON p.uuid = s.uuid_project
      WHERE f.name IN %s AND p.name = ? AND CAST(coalesce(s.date, s.datetime) + INTERVAL 11 HOUR AS DATE) = ?
      GROUP BY 1", .mig053_inlist(sprintf("K.MW%02d", 1:4))), params = list(.mig053_d_project, .mig053_d_day))
  if (nrow(dk) != 4L || any(dk$n != 1L))
    probs <- c(probs, sprintf("K.MW01-04 samples in %s on %s: %s (expected one each)", .mig053_d_project,
                              .mig053_d_day, paste(dk$name, dk$n, sep = "=", collapse = ", ")))
  nb <- .mig053_scalar(con, sprintf("SELECT COUNT(*) FROM sample s
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
      WHERE f.name IN %s AND CAST(coalesce(s.date, s.datetime) + INTERVAL 11 HOUR AS DATE) = ?",
      .mig053_inlist(sprintf("B.MW%02d", 1:4))), .mig053_d_day)
  if (nb != 0L) probs <- c(probs, sprintf("%d B.MW01-04 sample(s) exist on %s", nb, .mig053_d_day))
  probs
}

.mig053_check_preconditions <- function(con, input) {
  if (.mig053_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig053_requires) == 0L)
    .mig053_fail(sprintf("marker %d (052) is required first.", .mig053_requires))
  plan <- .mig053_plan(con, input)
  probs <- .mig053_problems(con, plan)
  if (length(probs)) .mig053_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  plan
}

.mig053_checksum <- function(con, plan) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid",
                                      .mig053_inlist(c(plan$uuid, .mig053_ll_uuid))))
  out$feature_alias_split <- q(sprintf("SELECT * EXCLUDE (date_end) FROM feature_alias WHERE uuid = '%s'", .mig053_ll_uuid))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig053_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig053_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

# Resolve `name` on `day` through the real candidate path; sorted alias uuids.
.mig053_resolve <- function(name, day, reg) sort(.rc_feature_candidates(name, as.Date(day), reg)$uuid_alias)

.mig053_done_problem <- function(con, input) {
  if (.mig053_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig053_marker_version) != 1L)
    return("marker 1053 missing")
  plan <- .mig053_plan(con, input)
  n <- nrow(plan)
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig053_actor))
  ins <- cl[cl$action == "insert", , drop = FALSE]
  upd <- cl[cl$action == "update", , drop = FALSE]
  if (nrow(cl) != n + 1L || nrow(ins) != n || any(ins$tbl != "feature_alias") || !setequal(ins$uuid_row, plan$uuid) ||
      anyDuplicated(ins$uuid_row) || nrow(upd) != 1L || upd$tbl != "feature_alias" || upd$field != "date_end" ||
      upd$uuid_row != .mig053_ll_uuid || !is.na(upd$old) || upd$new != .st_changelog_str(.mig053_ll_end))
    return(sprintf("053 change_log is %d row(s), not %d feature_alias inserts + 1 date_end update", nrow(cl), n))
  fa <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s", .mig053_inlist(plan$uuid)))
  if (nrow(fa) != n) return(sprintf("%d of the %d planned alias rows exist", nrow(fa), n))
  fa <- fa[match(plan$uuid, fa$uuid), , drop = FALSE]
  bad <- !.mig053_same_chr(fa$uuid_feature, plan$uuid_feature) | fa$name != plan$name | fa$alias_key != plan$alias_key |
    fa$alias_key != .rc_feature_key(fa$name) | fa$kind != plan$kind | fa$auto_assign != plan$auto_assign |
    !.mig053_same_chr(fa$confirmed_by, plan$confirmed_by) | !.mig053_same_chr(fa$comments, plan$comments) |
    !.mig053_same_date(fa$date_start, plan$date_start) | !.mig053_same_date(fa$date_end, plan$date_end) |
    fa$n_seen != 0L | !is.na(fa$first_seen) | !is.na(fa$last_seen)
  if (any(bad)) return(sprintf("%d 053 alias row(s) differ from the plan: %s", sum(bad), paste(plan$name[bad], collapse = ", ")))
  ll <- DBI::dbGetQuery(con, "SELECT fa.*, f.name AS fname FROM feature_alias fa LEFT JOIN feature f ON f.uuid = fa.uuid_feature
                              WHERE fa.uuid = ?", params = list(.mig053_ll_uuid))
  if (nrow(ll) != 1L || !identical(ll$fname, "B.L02") || !is.na(ll$date_start) ||
      !.mig053_same_date(ll$date_end, .mig053_ll_end))
    return(sprintf("alias %s is not -> B.L02 ending %s", .mig053_ll_uuid, .mig053_ll_end))
  # Through the real candidate path.
  reg <- .rc_load_registry(con)
  uid <- function(sec, target) plan$uuid[plan$section == sec & plan$target == target]
  for (i in which(plan$section == "A")) {
    lo <- c(plan$date_start[[i]], plan$f_date_start[[i]]); lo <- lo[!is.na(lo)]
    hi <- c(plan$date_end[[i]], plan$f_date_end[[i]]); hi <- hi[!is.na(hi)]
    d <- if (length(lo)) max(lo) else if (length(hi)) min(hi) else as.Date("2026-01-01")
    if (!identical(.mig053_resolve(plan$name[[i]], d, reg), plan$uuid[[i]]))
      return(sprintf("A: %s does not resolve to %s alone on %s", plan$name[[i]], plan$target[[i]], d))
  }
  b_copy <- uid("B", "B.L02"); b_k <- uid("B", "K.L01")
  for (ck in list(list("2020-07-31", .mig053_ll_uuid), list("2020-08-01", b_k), list("2020-08-31", b_k),
                  list("2020-09-01", b_copy), list("2026-01-01", b_copy)))
    if (!identical(.mig053_resolve("Lined leachate dam", ck[[1]], reg), ck[[2]]))
      return(sprintf("B: 'Lined leachate dam' on %s does not resolve to the one planned arm", ck[[1]]))
  fa_all <- reg$feature_alias
  old_arm <- function(key) fa_all$uuid[fa_all$alias_key == key & !(fa_all$uuid %in% plan$uuid) & !is.na(fa_all$uuid_feature)]
  for (i in which(plan$section %in% c("C", "D"))) {
    o <- old_arm(plan$alias_key[[i]])
    if (length(o) != 1L) return(sprintf("%s: %d pre-existing arm(s)", plan$name[[i]], length(o)))
    o_end <- .rc_as_date_bound(reg$feature$date_end[match(fa_all$uuid_feature[fa_all$uuid == o], reg$feature$uuid)])
    if (!is.na(o_end) && o_end < plan$date_start[[i]]) {
      if (plan$alias_key[[i]] %in% names(.mig053_planned_collisions)) return(sprintf("%s: planned collision gone", plan$name[[i]]))
      o <- character(0)   # retired feature: the old arm is not live
    } else if (!(plan$alias_key[[i]] %in% names(.mig053_planned_collisions))) {
      return(sprintf("%s: unplanned live pre-existing arm", plan$name[[i]]))
    }
    both <- sort(c(o, plan$uuid[[i]]))
    if (!identical(.mig053_resolve(plan$name[[i]], plan$date_start[[i]], reg), both) ||
        !identical(.mig053_resolve(plan$name[[i]], plan$date_end[[i]], reg), both) ||
        !identical(.mig053_resolve(plan$name[[i]], plan$date_start[[i]] - 1L, reg), o) ||
        !identical(.mig053_resolve(plan$name[[i]], plan$date_end[[i]] + 1L, reg), o))
      return(sprintf("%s: arms in/out of %s..%s are not (new + existing) / (existing)", plan$name[[i]],
                     plan$date_start[[i]], plan$date_end[[i]]))
  }
  # E and F: every arm resolves ALONE on its day (no planned co-arm exists for E or F).
  for (i in which(plan$section %in% c("E", "F"))) {
    if (!identical(.mig053_resolve(plan$name[[i]], plan$date_start[[i]], reg), plan$uuid[[i]]))
      return(sprintf("%s: %s does not resolve to %s alone on %s", plan$section[[i]], plan$name[[i]], plan$target[[i]],
                     plan$date_start[[i]]))
  }
  NULL
}

.mig053_verify <- function(con, input) {
  p <- .mig053_done_problem(con, input)
  if (!is.null(p)) cli::cli_abort(paste0("053 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig053_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig053_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig053_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig053_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig053_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("053: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig053_apply <- function(con, plan, input, recorded_at) {
  sums_before <- .mig053_checksum(con, plan)
  n <- nrow(plan)
  want <- .mig053_counts(con)
  want$feature_alias <- want$feature_alias + n
  want$change_log <- want$change_log + n + 1L
  want$schema_version <- want$schema_version + 1L
  rows <- .mig053_rows(plan)
  db_transaction(con, function(con) {
    db_update(con, "feature_alias", uuid = .mig053_ll_uuid, changes = list(date_end = .mig053_ll_end),
              actor = .mig053_actor, reason = .mig053_reason[["B"]])
    for (s in names(.mig053_expected_n)) {
      db_append(con, "feature_alias", rows[plan$section == s, , drop = FALSE], actor = .mig053_actor,
                reason = .mig053_reason[[s]])
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig053_marker_version, recorded_at))
    .mig053_verify(con, input)
    got <- .mig053_counts(con)
    if (!identical(got, want))
      .mig053_fail(sprintf("counts are not before + %d alias, + %d change_log, + 1 marker: %s", n, n + 1L,
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig053_checksum(con, plan))) .mig053_fail("something outside the planned rows moved.")
    NULL
  })
  invisible(NULL)
}

mig053_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL,
                       input = .mig053_input_default) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig053_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig053_verify(check_con, input), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("053 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  plan <- tryCatch(.mig053_check_preconditions(pre_con, input), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: %d aliases - A %d (descriptive %d, transcription_error %d), B %d, C %d, D %d, E %d, F %d; 1 update (%s date_end -> %s).",
       nrow(plan), sum(plan$section == "A"), sum(plan$section == "A" & plan$kind == "descriptive"),
       sum(plan$section == "A" & plan$kind == "transcription_error"), sum(plan$section == "B"),
       sum(plan$section == "C"), sum(plan$section == "D"), sum(plan$section == "E"), sum(plan$section == "F"),
       .mig053_ll_uuid, .mig053_ll_end)
  for (i in which(plan$section %in% c("B", "C", "D")))
    logf("  %s: '%s' -> %s, %s, %s..%s", plan$section[[i]], plan$name[[i]], plan$target[[i]], plan$kind[[i]],
         format(plan$date_start[[i]]), format(plan$date_end[[i]]))
  logf("Planned key collisions (two live auto arms in window; ACIRL site veto decides): %s",
       paste(names(.mig053_planned_collisions), "/", .mig053_planned_collisions, collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = plan)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig053_write_csv(DBI::dbGetQuery(bk_con, "SELECT * FROM feature_alias WHERE uuid = ?",
                                             params = list(.mig053_ll_uuid)),
                             file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig053_name))),
           finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig053_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    plan <- .mig053_check_preconditions(con, input)   # re-read under the write lock
    .mig053_apply(con, plan, input, recorded_at)
  }, db = db)

  out_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    ins <- DBI::dbGetQuery(out_con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s", .mig053_inlist(plan$uuid)))
    ins <- ins[match(plan$uuid, ins$uuid), , drop = FALSE]
    .mig053_write_csv(ins, file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig053_name)))
  }, finally = DBI::dbDisconnect(out_con, shutdown = TRUE))

  logf("%s migrated successfully (marker %d): %d aliases inserted, 1 updated.",
       .mig053_name, .mig053_marker_version, nrow(plan))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
