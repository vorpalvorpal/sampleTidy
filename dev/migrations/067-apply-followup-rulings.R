# Operator-run migration: apply Robin's rulings on the follow-up detail of the
# 2026-10-21 review-queue triage. Marker 1067. Requires 1066.
#
# ---- WHY -----------------------------------------------------------------------
# 066 applied the rulings Robin accepted outright and left 32 items open. For
# decisions 2, 5, 8, 11, 14, 15, 16, 17 and 22 he asked for more detail; the detail
# is in scratchpad/2026-10-21-review/followup/FINDINGS.md, and his answer (2026-10-21,
# late) was "Accept all recommendations. K.L06 should be still water." This
# migration applies them, plus two consequences of earlier rulings (23 and 12) that
# 066 left behind. Every value written was checked against the source files in
# scratchpad/2026-10-19-corpus/src/ (ALS ESdat/XTAB, ACIRL workbooks); per-item
# evidence in scratchpad/2026-10-21-review/followup/ and m067/.
#
# ---- WHAT (frozen in the INPUT CSVs beside this file; `item` = decision number) ---
#   2   close 6 (special sheet 2400-7222-12-02 re-reads of B.S01/B.S05, 14 Dec 2022):
#       keep live, no second sample; the special's B.S05 12:25 reading is noted in
#       the B.S05 sample comment.
#   5   13 Jun 2024 ACIRL 'B.LO2' column = B.L02 (all ~30 lab values equal ALS
#       ES2419948-008): delete 058's one-day arm 'B.LO2' -> B.E01 (6119d2fd) and end
#       95ce1c0a on 2024-06-13 so it meets its continuation ebc3f982; move the 3
#       ACIRL field rows (Temperature 11.8, pH 8.3, Comments) from B.E01 sample
#       d6591df3 to B.L02 sample ES2419948008, add field EC 1724 there (the row the
#       package's release path produces), delete the emptied d6591df3. Close 2.
#   8   'Leachate - Cell B' 12 Mar / 23 Apr 2020 = B.L04 (SO4/Cl/Na/K/NH3-N follow
#       B.L04): two one-day arms 'Leachate - Cell B' -> B.L04 like 053 E's; samples
#       153bc041, 431645ec re-pointed B.L03 -> those arms. Close 2.
#   11a ES2207741-002 'B.S05-Stormwater dam' (2 Mar 2022) = B.S06 (stormwater-dam
#       chemistry): one-day arm 'B.S05-Stormwater dam' -> B.S06; legacy alias
#       'B.S05-STORMWATER' (1f7f13dc, its only sighting this sample) re-pointed to
#       B.S06 and bounded to that day; sample f7d36be0 re-pointed B.S05 -> the new
#       arm. Close 1.
#   11b 'K.S1' (ES2112082-002) stays on K.S09. Close 1.
#   14  ES2320105-003 (14 Jun 2023 special, 'B.S05 - Diversion pipe outlet') is
#       B.TS39 (582698fe): delete the 32 copies the corpus import also committed
#       onto B.S05 sample 7217d9e4 (each equal to 582698fe's), move Ionic Balance
#       5.85 and SAR 9.89 (only on 7217d9e4) and the sample_lab_id row ES2320105-003
#       onto 582698fe, add a one-day arm 'B.S05 - Diversion pipe outlet' -> B.TS39.
#       (The undated arm to B.S05 is left alone: a re-ingest of that day now sees
#       two arms and goes to review rather than duplicating.)
#   15  alias K.E02 -> K.S06 (43513316) retired: auto_assign FALSE + comment.
#   16  register B.L06 "Discharge Point - Winmalee STP" (as B.L05: site B, leachate,
#       no flow; date_start 2021-03-27) and K.L07 "Transfer station leachate sump
#       (greenwaste)" (site K, leachate, flow still; date_start 2025-02-11), each with
#       its 'long' mask and self alias (K.L07 also a mask_long alias, as K.L06);
#       confirm the pending aliases 65f4accb / cdabad46 onto them. Their 6 + 1
#       samples (54 + 20 analyses, every value equal to the ESdat files) are already
#       committed on those aliases, so confirming them is the whole release. Close 3.
#       K.L06 flow groundwater -> still ("K.L06 should be still water").
#       LON/LAT OF B.L06 AND K.L07 ARE PROVISIONAL (copied from B.L01 / K.L06; the
#       real locations are not recorded) - see the feature comments.
#   17/22 14 Dec 2022 B.MW07/B.MW09: the field sheet hand-corrects its row labels and
#       live holds the whole samples on the wrong bores. Re-point 3676bc68 -> B.MW09
#       and 1ef8ef05 -> B.MW07 (time, field T/pH/EC, appearance, ALS chemistry all
#       move with them), exchange the two SWL rows (already right), add sample_lab_id
#       ES2245792-010 (client B.MW07) / -012 (client B.MW09), note it in the comments.
#       Close 5. B.S04/B.S05 that day follow the quarterly sheet and ACIRL 12-04:
#       S04 22.6 / 6.7 / 100, S05 21.6 / 5.6 / 111 (6 value updates). Close 6.
#   23+ two more ESdat Coliforms rows with Result 1 and Comments "~<2" (B.MW02,
#       ES2007102-010, ES2007245-010) stored as non-detects <2 CFU/100mL exactly as
#       066 stored decision 23's (value 0.02, quantified FALSE, rl_low 0.01 kept).
#   12+ B.E01 sample 67843ab8 (2024-09-11 00:35, legacy) holds the S1 field readings
#       (T 13.6, pH 7.1, 'Low flow', 'Slightly cloudy') that 066 placed on B.S01
#       sample b064e7fc via 'B.SO1 S1': all 4 are exact duplicates; deleted with the
#       sample.
#   kmw K.MW01-04 date_start 2021-09-08 -> 2020-08-11 (the earliest Sydney-local
#       sample date of each; 4/4/2/4 samples before 2021-09-08), with a note in
#       feature.comments that Robin is unsure the pre-Sep-2021 samples are the same
#       bores. No alias needed changing: the arms those samples ride are undated.
#
# Counts (plan): 26 items closed; features 2 inserts (+2 masks), 5 updates; aliases
# 7 inserts, 5 updates, 1 delete; samples 6 updates, 2 deletes; sample_lab_id 2
# inserts, 1 re-point; analyses 158 deletes (122 re-inserted unchanged or onto the
# swapped bore), 5 moves, 10 field updates, 1 new insert. Net: analysis -35, sample
# -2, feature +2, feature_mask +2, feature_alias +6, sample_lab_id +2.
#
# ---- LIVE HAS MOVED ON --------------------------------------------------------
# Every group (`gid`) is checked against the target DB first: its items still open
# with the same source_hash; every row it updates, moves, deletes or re-inserts still
# byte-for-byte as frozen (sha1 of the row); insert uuids/keys free; targets present;
# no (sample, lab_method) or ux_sample_identity collision; nothing outside the plan
# on a sample or alias it deletes or re-points. A failing group is SKIPPED whole (its
# items stay open) and listed in 067-...-SKIPPED.csv.
#
# ---- COMMITS (duckdb 1.4: FK checks do not see deletes made earlier in the same
# transaction; a sample's indexed columns cannot change while analyses reference it:
# 029, 032, 065, 066) ---------------------------------------------------------------
#   A. feature + feature_mask inserts, feature update; feature_alias updates and
#      inserts; analysis deletes (incl. those re-inserted in C), moves and value
#      updates                                                              (commit)
#   B. sample_lab_id re-point; sample updates (uuid_feature_alias, comments) and
#      deletes                                                              (commit)
#   C. feature_alias deletes; sample_lab_id inserts; analysis inserts and re-inserts;
#      close items; marker; verify; counts; checksums                       (commit)
# A re-run after a failure resumes at the first unfinished commit (read from
# change_log against the plan recorded in the SKIPPED CSV); any other state refuses.
#
# Backups: verified whole-file snapshot, plus BACKUP CSVs of every analysis, sample,
# sample_lab_id, feature, feature_alias and review_queue row the plan touches.
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/067-apply-followup-rulings.R", envir = env)
#   env$mig067_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig067_marker_version <- 1067L
.mig067_requires <- 1066L
.mig067_name <- "067-apply-followup-rulings"
.mig067_actor <- .mig067_name
.mig067_resolved_by <- .mig067_name
.mig067_n <- list(review = 26L, feature = 7L, alias = 13L, sample = 8L, sli = 3L, change = 173L, insert = 123L)
.mig067_reason <- "067 (Robin's rulings 2026-10-21 on the follow-up detail of the review-queue triage)"

.mig067_fail <- function(msg) cli::cli_abort(paste0(.mig067_name, ": ", msg), class = "sampletidy_error")
.mig067_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig067_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig067_na <- function(x) { x <- as.character(x); x[!is.na(x) & !nzchar(x)] <- NA_character_; x }
.mig067_chr <- function(x) if (is.na(x) || !nzchar(x)) NA_character_ else x
.mig067_num <- function(x) if (is.na(x) || !nzchar(x)) NA_real_ else as.numeric(x)   # decimal or C99 hex ("%a")
.mig067_lgl <- function(x) if (is.na(x) || !nzchar(x)) NA else as.logical(x)
.mig067_date <- function(x) if (is.na(x) || !nzchar(x)) as.Date(NA) else as.Date(x)
.mig067_split <- function(s) if (is.na(s) || !nzchar(s)) character() else strsplit(s, ";", fixed = TRUE)[[1]]

# ---- inputs ------------------------------------------------------------------------

.mig067_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-INPUT-%s.csv", .mig067_name, suffix))
    if (!file.exists(p)) .mig067_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  x <- list(review = rd("review"), feature = rd("feature"), alias = rd("alias"), sample = rd("sample"),
            sli = rd("sample_lab_id"), change = rd("analysis-change"), insert = rd("analysis-insert"))
  got <- vapply(x, nrow, 1L)
  if (!identical(unname(got), unname(unlist(.mig067_n[names(x)]))))
    .mig067_fail(sprintf("INPUT row counts are %s, not as planned.", paste(names(got), got, sep = "=", collapse = " ")))
  if (anyDuplicated(x$review$uuid) || anyDuplicated(x$feature$uuid) || anyDuplicated(x$alias$uuid) ||
      anyDuplicated(x$sample$uuid) || anyDuplicated(paste(x$sli$work_order, x$sli$lab_id)) ||
      anyDuplicated(paste(x$change$uuid, x$change$op, x$change$field)) || anyDuplicated(x$insert$uuid))
    .mig067_fail("an INPUT CSV repeats a key.")
  # one analysis is either deleted, or moved, or has fields updated - never two of these
  kinds <- tapply(x$change$op, x$change$uuid, function(o) length(unique(o)))
  if (any(kinds > 1L)) .mig067_fail("an analysis has more than one kind of change.")
  if (anyDuplicated(paste(x$insert$uuid_sample, x$insert$uuid_lab)))
    .mig067_fail("INPUT-analysis-insert repeats a (sample, lab_method) pair.")
  if (!all(x$feature$op %in% c("insert", "update")) || !all(x$alias$op %in% c("update", "insert", "delete")) ||
      !all(x$sample$op %in% c("update", "delete")) || !all(x$sli$op %in% c("insert", "update")) ||
      !all(x$change$op %in% c("delete", "move", "update")) || !all(x$insert$origin %in% c("new", "reinsert")))
    .mig067_fail("an INPUT CSV has an unknown op/origin.")
  if (!all(x$change$field[x$change$op == "update"] %in% c("value", "quantified")))
    .mig067_fail("an analysis update names a field other than value/quantified.")
  re <- x$insert$uuid[x$insert$origin == "reinsert"]
  if (!setequal(re, x$change$uuid[x$change$op == "delete" & x$change$note %in% "reinsert"]))
    .mig067_fail("re-inserts do not match the deletes marked reinsert.")
  if (anyNA(unlist(lapply(x, function(d) d$gid)))) .mig067_fail("every INPUT row needs a gid.")
  x
}

# sha1 of each row as text, keyed by `key` (the frozen value in the INPUT CSVs comes
# from this same function, so a row that changed in any column no longer matches).
.mig067_row_sha <- function(con, tbl, ids, key = "uuid") {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  kexpr <- if (identical(key, "sli")) "work_order || '|' || lab_id" else key
  df <- DBI::dbGetQuery(con, sprintf('SELECT *, %s AS "..key" FROM "%s" WHERE %s IN %s', kexpr, tbl, kexpr, .mig067_inlist(ids)))
  for (i in seq_len(nrow(df))) {
    cols <- setdiff(names(df), "..key")
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[df[["..key"]][[i]]]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  out
}
.mig067_sli_key <- function(d) paste(d$work_order, d$lab_id, sep = "|")

# ---- plan: which groups still hold on this DB ---------------------------------------

.mig067_gid_problems <- function(con, x) {
  P <- list()
  add <- function(g, msg) if (length(g)) P[[length(P) + 1L]] <<- data.frame(gid = g, problem = msg, stringsAsFactors = FALSE)
  chk_sha <- function(df, tbl, what, key = "uuid") {
    if (!nrow(df)) return(invisible())
    ids <- if (identical(key, "sli")) .mig067_sli_key(df) else df$uuid
    sha <- .mig067_row_sha(con, tbl, ids, key)
    bad <- is.na(sha[ids]) | sha[ids] != df$row_sha1
    add(df$gid[bad], sprintf("%s %s is not as frozen", what, ids[bad]))
  }
  free <- function(df, tbl, what) {
    if (!nrow(df)) return(invisible())
    taken <- DBI::dbGetQuery(con, sprintf('SELECT uuid FROM "%s" WHERE uuid IN %s', tbl, .mig067_inlist(df$uuid)))$uuid
    add(df$gid[df$uuid %in% taken], sprintf("%s uuid %s is already taken", what, df$uuid[df$uuid %in% taken]))
  }
  # review items
  rv <- x$review
  rq <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, source_hash FROM review_queue WHERE uuid IN %s", .mig067_inlist(rv$uuid)))
  m <- rq[match(rv$uuid, rq$uuid), , drop = FALSE]
  bad <- is.na(m$uuid) | m$status != "open" | !mapply(identical, .mig067_na(m$source_hash), .mig067_na(rv$source_hash))
  add(rv$gid[bad], sprintf("review item %s is no longer open (or its source_hash changed)", rv$uuid[bad]))

  # features: inserts free (uuid and name), updates as frozen
  ft <- x$feature
  fi <- ft[ft$op == "insert", , drop = FALSE]
  free(fi, "feature", "feature")
  nm <- DBI::dbGetQuery(con, sprintf("SELECT name FROM feature WHERE name IN %s", .mig067_inlist(fi$name)))$name
  add(fi$gid[fi$name %in% nm], sprintf("a feature named %s already exists", fi$name[fi$name %in% nm]))
  mk <- DBI::dbGetQuery(con, sprintf("SELECT uuid_feature FROM feature_mask WHERE uuid_feature IN %s", .mig067_inlist(fi$uuid)))$uuid_feature
  add(fi$gid[fi$uuid %in% mk], sprintf("feature %s already has a mask", fi$uuid[fi$uuid %in% mk]))
  chk_sha(ft[ft$op == "update", , drop = FALSE], "feature", "feature")

  # aliases: updates/deletes as frozen; inserts free with their feature present (or inserted)
  al <- x$alias
  chk_sha(al[al$op != "insert", , drop = FALSE], "feature_alias", "alias")
  ia <- al[al$op == "insert", , drop = FALSE]
  free(ia, "feature_alias", "alias")
  need_f <- al$uuid_feature[al$op != "delete" & !is.na(al$uuid_feature)]
  have_f <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature WHERE uuid IN %s", .mig067_inlist(need_f)))$uuid
  bad <- al$op != "delete" & !is.na(al$uuid_feature) & !(al$uuid_feature %in% c(have_f, fi$uuid))
  add(al$gid[bad], sprintf("alias %s target feature is gone", al$uuid[bad]))
  # a new alias_key that a live auto-assign arm at another feature already holds on its days
  for (i in seq_len(nrow(ia))) {
    n <- .mig067_scalar(con, "SELECT COUNT(*) FROM feature_alias WHERE alias_key = ? AND uuid_feature IS NOT NULL AND auto_assign
                              AND uuid_feature <> ? AND kind = 'self'", ia$alias_key[[i]], ia$uuid_feature[[i]])
    if (n > 0L) add(ia$gid[[i]], sprintf("new alias %s would shadow a self arm", ia$uuid[[i]]))
  }
  da <- al[al$op == "delete", , drop = FALSE]
  sc <- x$sample
  ons <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature_alias FROM sample WHERE uuid_feature_alias IN %s", .mig067_inlist(da$uuid)))
  leave <- sc$uuid[sc$op == "delete" | grepl("uuid_feature_alias", sc$set)]
  extra <- unique(ons$uuid_feature_alias[!(ons$uuid %in% leave)])
  add(da$gid[da$uuid %in% extra], sprintf("alias %s holds a sample outside the plan", da$uuid[da$uuid %in% extra]))

  # samples: as frozen; holding only planned analyses when deleted or re-pointed
  chk_sha(sc, "sample", "sample")
  ch <- x$change
  off <- ch$uuid[ch$op %in% c("delete", "move")]
  rw <- sc[sc$op == "delete" | grepl("uuid_feature_alias", sc$set), , drop = FALSE]
  on <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig067_inlist(rw$uuid)))
  extra <- unique(on$uuid_sample[!(on$uuid %in% off)])
  add(rw$gid[rw$uuid %in% extra], sprintf("sample %s holds an analysis outside the plan", rw$uuid[rw$uuid %in% extra]))
  ds <- sc$uuid[sc$op == "delete"]
  sl <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample FROM sample_lab_id WHERE uuid_sample IN %s", .mig067_inlist(ds)))$uuid_sample
  add(sc$gid[sc$uuid %in% sl], sprintf("sample %s to delete has a sample_lab_id row", sc$uuid[sc$uuid %in% sl]))
  rf <- DBI::dbGetQuery(con, sprintf("SELECT uuid_existing AS u FROM review_queue WHERE status = 'open' AND uuid_existing IN %s
                                      UNION ALL SELECT uuid_incoming FROM review_queue WHERE status = 'open' AND uuid_incoming IN %s",
                                     .mig067_inlist(ds), .mig067_inlist(ds)))$u
  add(sc$gid[sc$uuid %in% rf], sprintf("sample %s to delete is named by an open review item", sc$uuid[sc$uuid %in% rf]))
  # re-point targets present (or inserted); ux_sample_identity after the plan
  rp <- sc[grepl("uuid_feature_alias", sc$set), , drop = FALSE]
  have_al <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig067_inlist(rp$uuid_feature_alias)))$uuid
  bad <- !(rp$uuid_feature_alias %in% c(have_al, ia$uuid))
  add(rp$gid[bad], sprintf("sample %s alias target %s is gone", rp$uuid[bad], rp$uuid_feature_alias[bad]))
  for (i in seq_len(nrow(rp))) {
    n <- .mig067_scalar(con, sprintf("SELECT COUNT(*) FROM sample t JOIN sample s ON s.uuid = ? WHERE t.uuid_feature_alias = ?
                                      AND t.datetime IS NOT DISTINCT FROM s.datetime AND t.uuid_project IS NOT DISTINCT FROM s.uuid_project
                                      AND t.uuid <> s.uuid AND t.uuid NOT IN %s", .mig067_inlist(rp$uuid)),
                        rp$uuid[[i]], rp$uuid_feature_alias[[i]])
    if (n > 0L) add(rp$gid[[i]], sprintf("re-pointing sample %s would collide on ux_sample_identity", rp$uuid[[i]]))
  }

  # sample_lab_id: updates as frozen; inserts free with their sample present
  sli <- x$sli
  chk_sha(sli[sli$op == "update", , drop = FALSE], "sample_lab_id", "sample_lab_id", key = "sli")
  si <- sli[sli$op == "insert", , drop = FALSE]
  k <- .mig067_sli_key(si)
  tk <- DBI::dbGetQuery(con, sprintf("SELECT work_order || '|' || lab_id AS k FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s", .mig067_inlist(k)))$k
  add(si$gid[k %in% tk], sprintf("sample_lab_id %s is already taken", k[k %in% tk]))
  smp <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig067_inlist(sli$uuid_sample)))$uuid
  bad <- !(sli$uuid_sample %in% smp) | sli$uuid_sample %in% ds
  add(sli$gid[bad], sprintf("sample_lab_id target sample %s is gone", sli$uuid_sample[bad]))

  # analyses changed: as frozen; move targets present and free of that lab_method
  chk_sha(ch[!duplicated(ch$uuid), , drop = FALSE], "analysis", "analysis")
  up <- ch[ch$op == "update", , drop = FALSE]
  for (i in seq_len(nrow(up))) {
    cur <- DBI::dbGetQuery(con, sprintf('SELECT "%s" AS v FROM analysis WHERE uuid = ?', up$field[[i]]), params = list(up$uuid[[i]]))$v
    if (length(cur) != 1L || !identical(.mig067_na(.st_changelog_str(cur)), .mig067_na(up$old[[i]])))
      add(up$gid[[i]], sprintf("analysis %s %s is no longer %s", up$uuid[[i]], up$field[[i]], up$old[[i]]))
  }
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv)) {
    lab <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_lab FROM analysis WHERE uuid IN %s", .mig067_inlist(mv$uuid)))
    tg <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig067_inlist(mv$new_sample)))$uuid
    bad <- !(mv$new_sample %in% tg) | mv$new_sample %in% ds
    add(mv$gid[bad], sprintf("move target sample %s is gone", mv$new_sample[bad]))
    have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s", .mig067_inlist(mv$new_sample)))
    have <- have$k[!(have$uuid %in% off)]
    kk <- paste(mv$new_sample, lab$uuid_lab[match(mv$uuid, lab$uuid)], sep = "|")
    add(mv$gid[kk %in% have], sprintf("move target %s already holds that lab_method", mv$new_sample[kk %in% have]))
  }

  # inserts
  ins <- x$insert
  free(ins[ins$origin == "new", , drop = FALSE], "analysis", "analysis")
  smp <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig067_inlist(ins$uuid_sample)))$uuid
  bad <- !(ins$uuid_sample %in% smp) | ins$uuid_sample %in% ds
  add(ins$gid[bad], sprintf("insert target sample %s is gone", ins$uuid_sample[bad]))
  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig067_inlist(ins$uuid_lab)))$uuid
  add(ins$gid[!(ins$uuid_lab %in% lm)], sprintf("insert lab_method %s is gone", ins$uuid_lab[!(ins$uuid_lab %in% lm)]))
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s", .mig067_inlist(ins$uuid_sample)))
  have <- have$k[!(have$uuid %in% off)]
  bad <- paste(ins$uuid_sample, ins$uuid_lab, sep = "|") %in% have
  add(ins$gid[bad], sprintf("sample %s already holds an analysis of lab_method %s", ins$uuid_sample[bad], ins$uuid_lab[bad]))

  if (!length(P)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  P <- do.call(rbind, P)
  P[!duplicated(P), , drop = FALSE]
}

# A skipped gid is dropped whole. No row appears under two gids (checked by the
# INPUT builder), so a skip never leaves another group half-planned.
.mig067_restrict <- function(x, skipped) {
  sk <- unique(skipped$gid)
  for (n in names(x)) x[[n]] <- x[[n]][!(x[[n]]$gid %in% sk), , drop = FALSE]
  x$skipped <- skipped
  x
}

.mig067_skipped_rows <- function(x_all, skipped) {
  if (!nrow(skipped)) return(data.frame(gid = character(), items = character(), problem = character(), stringsAsFactors = FALSE))
  agg <- stats::aggregate(problem ~ gid, data = skipped, FUN = function(p) paste(unique(p), collapse = "; "))
  agg$items <- vapply(agg$gid, function(g) paste(x_all$review$uuid[x_all$review$gid == g], collapse = " "), "")
  agg[, c("gid", "items", "problem")]
}

# ---- phases ----------------------------------------------------------------------

# Expected change_log rows per commit (tbl|action -> n). No tbl|action pair is
# written by two commits, so each commit's counts are separable.
.mig067_expected <- function(p) {
  ft <- p$feature; al <- p$alias; sc <- p$sample; ch <- p$change
  nset <- function(s) sum(vapply(s, function(z) length(.mig067_split(z)), 0L))
  A <- c("feature|insert" = sum(ft$op == "insert"),
         "feature_mask|insert" = sum(ft$op == "insert"),
         "feature|update" = nset(ft$set[ft$op == "update"]),
         "feature_alias|update" = nset(al$set[al$op == "update"]),
         "feature_alias|insert" = sum(al$op == "insert"),
         "analysis|delete" = sum(ch$op == "delete"),
         "analysis|update" = sum(ch$op %in% c("move", "update")))
  B <- c("sample_lab_id|update" = sum(p$sli$op == "update"),
         "sample|update" = nset(sc$set[sc$op == "update"]),
         "sample|delete" = sum(sc$op == "delete"))
  C <- c("feature_alias|delete" = sum(al$op == "delete"),
         "sample_lab_id|insert" = sum(p$sli$op == "insert"),
         "analysis|insert" = nrow(p$insert),
         "review_queue|update" = 4L * nrow(p$review))
  list(A = A, B = B, C = C)
}

.mig067_logged <- function(con) {
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig067_actor))
  stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
}

# "A" nothing done; "B" commit A done; "C" A and B done. NULL = inconsistent.
.mig067_phase <- function(con, p) {
  L <- .mig067_logged(con)
  if (!length(L)) return("A")
  E <- .mig067_expected(p)
  got <- function(keys) { v <- L[keys]; v[is.na(v)] <- 0L; stats::setNames(as.integer(v), keys) }
  same <- function(e) identical(got(names(e)), stats::setNames(as.integer(e), names(e)))
  zero <- function(e) all(got(names(e)) == 0L)
  known <- unique(c(names(E$A), names(E$B), names(E$C)))
  if (any(!(names(L) %in% known))) return(NULL)
  if (same(E$A) && zero(E$B) && zero(E$C)) return("B")
  if (same(E$A) && same(E$B) && zero(E$C)) return("C")
  NULL
}

# ---- apply -----------------------------------------------------------------------

.mig067_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_mask", "feature_alias", "sample_lab_id", "lab_method", "project",
            "asset", "ingest_file", "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig067_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig067_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

.mig067_checksum <- function(con, p) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "sample_lab_id", "feature", "feature_mask", "feature_alias", "review_queue",
               "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig067_inlist(c(p$change$uuid, p$insert$uuid))))
  out$sample_rest <- q(sprintf("SELECT * FROM sample WHERE uuid NOT IN %s ORDER BY uuid", .mig067_inlist(p$sample$uuid)))
  out$sli_rest <- q(sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id NOT IN %s ORDER BY ALL", .mig067_inlist(.mig067_sli_key(p$sli))))
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", .mig067_inlist(p$feature$uuid)))
  out$mask_rest <- q(sprintf("SELECT * FROM feature_mask WHERE uuid_feature NOT IN %s ORDER BY ALL", .mig067_inlist(p$feature$uuid[p$feature$op == "insert"])))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", .mig067_inlist(p$alias$uuid)))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig067_inlist(p$review$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig067_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig067_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig067_why <- function(p, gid, what) {
  it <- unique(unlist(lapply(p[c("review", "feature", "alias", "sample", "sli", "change", "insert")], function(d) d$item[d$gid == gid])))
  it <- it[!is.na(it)]
  sprintf("%s [decision %s; group %s]: %s", .mig067_reason, paste(it, collapse = "+"), gid, what)
}

.mig067_delete_logged <- function(con, table, ids, reasons) {
  if (!length(ids)) return(invisible(0L))
  n <- DBI::dbExecute(con, sprintf('DELETE FROM "%s" WHERE uuid IN %s', table, .mig067_inlist(ids)))
  if (n != length(ids)) .mig067_fail(sprintf("set-based delete on %s removed %d rows, not %d.", table, n, length(ids)))
  at <- Sys.time()
  for (i in seq_along(ids))
    .st_write_change_log(con, at = at, actor = .mig067_actor, action = "delete", tbl = table,
                         uuid_row = ids[[i]], field = NA_character_, old = ids[[i]], new = NA_character_,
                         reason = reasons[[i]], source_hash = NA_character_)
  invisible(n)
}

.mig067_value <- function(f, v) {
  switch(f, auto_assign = , quantified = , permanent = , reference = , virtual = .mig067_lgl(v),
         date_start = , date_end = .mig067_date(v), n_seen = as.integer(v),
         lon = , lat = , value = .mig067_num(v), .mig067_chr(v))
}

.mig067_apply <- function(con, p, phase, recorded_at, logf) {
  sums_before <- .mig067_checksum(con, p)
  want <- .mig067_counts(con)
  ft <- p$feature; al <- p$alias; sc <- p$sample; ch <- p$change; sli <- p$sli
  why <- function(df, i) .mig067_why(p, df$gid[[i]], df$reason[[i]])
  if (phase == "A") {
    want$analysis <- want$analysis - sum(ch$op == "delete")
    want$feature <- want$feature + sum(ft$op == "insert")
    want$feature_mask <- want$feature_mask + sum(ft$op == "insert")
    want$feature_alias <- want$feature_alias + sum(al$op == "insert")
  }
  if (phase %in% c("A", "B")) want$sample <- want$sample - sum(sc$op == "delete")
  want$feature_alias <- want$feature_alias - sum(al$op == "delete")
  want$sample_lab_id <- want$sample_lab_id + sum(sli$op == "insert")
  want$analysis <- want$analysis + nrow(p$insert)
  want$review_open <- want$review_open - nrow(p$review)
  want$schema_version <- want$schema_version + 1L
  E <- .mig067_expected(p)
  want$change_log <- want$change_log + sum(unlist(E)) - .mig067_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig067_actor)

  if (phase == "A") {
    db_transaction(con, function(con) {
      fi <- ft[ft$op == "insert", , drop = FALSE]
      for (i in seq_len(nrow(fi))) {
        row <- tibble::tibble(uuid = fi$uuid[[i]], name = fi$name[[i]], site = fi$site[[i]], flow = .mig067_chr(fi$flow[[i]]),
                              matrix = .mig067_chr(fi$matrix[[i]]), permanent = .mig067_lgl(fi$permanent[[i]]),
                              reference = .mig067_lgl(fi$reference[[i]]), date_start = .mig067_date(fi$date_start[[i]]),
                              lon = .mig067_num(fi$lon[[i]]), lat = .mig067_num(fi$lat[[i]]),
                              geom_wkt = .mig067_chr(fi$geom_wkt[[i]]), comments = .mig067_chr(fi$comments[[i]]),
                              virtual = .mig067_lgl(fi$virtual[[i]]))
        db_append(con, "feature", row, actor = .mig067_actor, reason = why(fi, i))
        db_append(con, "feature_mask", tibble::tibble(uuid_feature = fi$uuid[[i]], variant = "long", name = fi$mask_long[[i]]),
                  actor = .mig067_actor, reason = why(fi, i))
      }
      fu <- ft[ft$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(fu))) {
        fs <- .mig067_split(fu$set[[i]])
        db_update(con, "feature", uuid = fu$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) .mig067_value(f, fu[[f]][[i]])), fs),
                  actor = .mig067_actor, reason = why(fu, i))
      }
      up <- al[al$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(up))) {
        fs <- .mig067_split(up$set[[i]])
        db_update(con, "feature_alias", uuid = up$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) .mig067_value(f, up[[f]][[i]])), fs),
                  actor = .mig067_actor, reason = why(up, i))
      }
      ia <- al[al$op == "insert", , drop = FALSE]
      for (i in seq_len(nrow(ia))) {
        row <- tibble::tibble(uuid = ia$uuid[[i]], uuid_feature = ia$uuid_feature[[i]], name = ia$name[[i]],
                              alias_key = ia$alias_key[[i]], kind = ia$kind[[i]], n_seen = 0L,
                              auto_assign = .mig067_lgl(ia$auto_assign[[i]]), first_seen = recorded_at, last_seen = recorded_at,
                              confirmed_by = .mig067_chr(ia$confirmed_by[[i]]), comments = .mig067_chr(ia$comments[[i]]),
                              date_start = .mig067_date(ia$date_start[[i]]), date_end = .mig067_date(ia$date_end[[i]]))
        db_append(con, "feature_alias", row, actor = .mig067_actor, reason = why(ia, i))
      }
      del <- ch[ch$op == "delete", , drop = FALSE]
      .mig067_delete_logged(con, "analysis", del$uuid, vapply(seq_len(nrow(del)), function(i) why(del, i), ""))
      mv <- ch[ch$op == "move", , drop = FALSE]
      for (i in seq_len(nrow(mv)))
        db_update(con, "analysis", uuid = mv$uuid[[i]], changes = list(uuid_sample = mv$new_sample[[i]]),
                  actor = .mig067_actor, reason = why(mv, i))
      uv <- ch[ch$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(uv)))
        db_update(con, "analysis", uuid = uv$uuid[[i]], changes = stats::setNames(list(.mig067_value(uv$field[[i]], uv$new[[i]])), uv$field[[i]]),
                  actor = .mig067_actor, reason = why(uv, i), source_hash = .mig067_chr(uv$source_hash[[i]]))
      NULL
    })
    logf("A: %d features (+ masks) inserted, %d updated; %d alias updates, %d alias inserts; %d analyses deleted (%d to re-insert), %d moved, %d value/quantified updates (committed).",
         sum(ft$op == "insert"), sum(ft$op == "update"), sum(al$op == "update"), sum(al$op == "insert"), sum(ch$op == "delete"),
         sum(ch$note %in% "reinsert"), sum(ch$op == "move"), sum(ch$op == "update"))
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) {
      su <- sli[sli$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(su)))
        db_update(con, "sample_lab_id", key = list(work_order = su$work_order[[i]], lab_id = su$lab_id[[i]]),
                  changes = list(uuid_sample = su$uuid_sample[[i]]), actor = .mig067_actor, reason = why(su, i))
      sp <- sc[sc$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(sp))) {
        fs <- .mig067_split(sp$set[[i]])
        db_update(con, "sample", uuid = sp$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) sp[[f]][[i]]), fs),
                  actor = .mig067_actor, reason = why(sp, i))
      }
      sd <- sc[sc$op == "delete", , drop = FALSE]
      .mig067_delete_logged(con, "sample", sd$uuid, vapply(seq_len(nrow(sd)), function(i) why(sd, i), ""))
      NULL
    })
    logf("B: %d sample_lab_id re-points, %d sample updates, %d samples deleted (committed).",
         sum(sli$op == "update"), sum(sc$op == "update"), sum(sc$op == "delete"))
    phase <- "C"
  }
  db_transaction(con, function(con) {
    da <- al[al$op == "delete", , drop = FALSE]
    .mig067_delete_logged(con, "feature_alias", da$uuid, vapply(seq_len(nrow(da)), function(i) why(da, i), ""))
    si <- sli[sli$op == "insert", , drop = FALSE]
    for (i in seq_len(nrow(si)))
      db_append(con, "sample_lab_id",
                tibble::tibble(uuid_sample = si$uuid_sample[[i]], work_order = si$work_order[[i]], lab_id = si$lab_id[[i]],
                               client_id = .mig067_chr(si$client_id[[i]]), source_hash = .mig067_chr(si$source_hash[[i]])),
                actor = .mig067_actor, reason = why(si, i), source_hash = .mig067_chr(si$source_hash[[i]]))
    ins <- p$insert
    for (i in seq_len(nrow(ins))) {
      row <- tibble::tibble(uuid = ins$uuid[[i]], uuid_sample = ins$uuid_sample[[i]], uuid_lab = ins$uuid_lab[[i]],
                            value = .mig067_num(ins$value[[i]]), value_chr = .mig067_chr(ins$value_chr[[i]]),
                            quantified = .mig067_lgl(ins$quantified[[i]]), rl_low = .mig067_num(ins$rl_low[[i]]),
                            rl_high = .mig067_num(ins$rl_high[[i]]), purpose = .mig067_chr(ins$purpose[[i]]),
                            comments = .mig067_chr(ins$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig067_actor, reason = why(ins, i), source_hash = .mig067_chr(ins$source_hash[[i]]))
    }
    at <- Sys.time()
    rv <- p$review
    for (i in seq_len(nrow(rv)))
      db_update(con, "review_queue", uuid = rv$uuid[[i]],
                changes = list(status = "resolved", resolution = rv$resolution[[i]], resolved_by = .mig067_resolved_by, resolved_at = at),
                actor = .mig067_actor, reason = .mig067_why(p, rv$gid[[i]], sprintf("close review item %s", rv$uuid[[i]])))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig067_marker_version, recorded_at))
    .mig067_verify(con, p)
    got <- .mig067_counts(con)
    if (!identical(got, want))
      .mig067_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig067_checksum(con, p))) .mig067_fail("something outside the planned rows moved.")
    NULL
  })
  logf("C: %d aliases deleted, %d sample_lab_id rows inserted, %d analyses inserted (%d re-inserts), %d items closed, marker %d (committed).",
       sum(al$op == "delete"), sum(sli$op == "insert"), nrow(p$insert), sum(p$insert$origin == "reinsert"), nrow(p$review),
       .mig067_marker_version)
  invisible(TRUE)
}

# ---- verify ----------------------------------------------------------------------

.mig067_done_problem <- function(con, p) {
  if (.mig067_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig067_marker_version) != 1L)
    return("marker 1067 missing")
  eqn <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & abs(x - y) <= 1e-9 * pmax(1, abs(y)))
  eqc <- function(x, y) mapply(identical, .mig067_na(x), .mig067_na(y))
  num <- function(v) vapply(v, .mig067_num, 0)
  # analyses inserted / re-inserted exactly as planned
  ins <- p$insert
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig067_inlist(c(ins$uuid, p$change$uuid))))
  a <- A[match(ins$uuid, A$uuid), , drop = FALSE]
  if (anyNA(a$uuid)) return(sprintf("%d planned analysis inserts are missing", sum(is.na(a$uuid))))
  ok <- a$uuid_sample == ins$uuid_sample & a$uuid_lab == ins$uuid_lab &
    eqn(a$value, num(ins$value)) & eqn(a$rl_low, num(ins$rl_low)) & eqn(a$rl_high, num(ins$rl_high)) &
    eqc(a$value_chr, ins$value_chr) & eqc(as.character(a$quantified), toupper(ins$quantified)) &
    eqc(a$comments, ins$comments) & eqc(a$purpose, ins$purpose)
  if (!all(ok)) return(sprintf("analysis insert %s is not as planned", ins$uuid[!ok][[1]]))
  ch <- p$change
  if (any(ch$uuid[ch$op == "delete" & !(ch$note %in% "reinsert")] %in% A$uuid)) return("a deleted analysis is still present")
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv) && !all(A$uuid_sample[match(mv$uuid, A$uuid)] == mv$new_sample)) return("a moved analysis is not on its target")
  uv <- ch[ch$op == "update", , drop = FALSE]
  for (i in seq_len(nrow(uv))) {
    cur <- A[A$uuid == uv$uuid[[i]], uv$field[[i]]]
    if (length(cur) != 1L || !identical(.mig067_na(.st_changelog_str(cur)), .mig067_na(uv$new[[i]])))
      return(sprintf("analysis %s %s is not %s", uv$uuid[[i]], uv$field[[i]], uv$new[[i]]))
  }
  # features and masks
  ft <- p$feature
  Fe <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE uuid IN %s", .mig067_inlist(ft$uuid)))
  for (i in seq_len(nrow(ft))) {
    r <- Fe[Fe$uuid == ft$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("feature %s is missing", ft$uuid[[i]]))
    fs <- if (ft$op[[i]] == "insert") c("name", "site", "flow", "matrix", "date_start", "geom_wkt", "comments") else .mig067_split(ft$set[[i]])
    for (f in fs) if (!identical(.mig067_na(.st_changelog_str(r[[f]])), .mig067_na(ft[[f]][[i]])))
      return(sprintf("feature %s %s is not %s", ft$uuid[[i]], f, ft[[f]][[i]]))
    if (ft$op[[i]] == "insert") {
      if (!eqn(r$lon, .mig067_num(ft$lon[[i]])) || !eqn(r$lat, .mig067_num(ft$lat[[i]]))) return(sprintf("feature %s lon/lat not as planned", ft$uuid[[i]]))
      m <- DBI::dbGetQuery(con, "SELECT variant, name FROM feature_mask WHERE uuid_feature = ?", params = list(ft$uuid[[i]]))
      if (nrow(m) != 1L || m$variant != "long" || m$name != ft$mask_long[[i]]) return(sprintf("feature %s mask not as planned", ft$uuid[[i]]))
    }
  }
  # samples
  sc <- p$sample
  S <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample WHERE uuid IN %s", .mig067_inlist(sc$uuid)))
  if (any(sc$uuid[sc$op == "delete"] %in% S$uuid)) return("a deleted sample is still present")
  for (i in which(sc$op == "update")) {
    s <- S[S$uuid == sc$uuid[[i]], , drop = FALSE]
    if (nrow(s) != 1L) return(sprintf("sample %s is missing", sc$uuid[[i]]))
    for (f in .mig067_split(sc$set[[i]])) if (!identical(.mig067_na(s[[f]]), .mig067_na(sc[[f]][[i]])))
      return(sprintf("sample %s %s is not as planned", sc$uuid[[i]], f))
  }
  # sample_lab_id
  sli <- p$sli
  L <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s", .mig067_inlist(.mig067_sli_key(sli))))
  l <- L[match(.mig067_sli_key(sli), .mig067_sli_key(L)), , drop = FALSE]
  if (anyNA(l$lab_id) || any(l$uuid_sample != sli$uuid_sample)) return("a sample_lab_id row is not as planned")
  si <- sli$op == "insert"
  if (any(!eqc(l$client_id[si], sli$client_id[si])) || any(!eqc(l$source_hash[si], sli$source_hash[si]))) return("a new sample_lab_id row is not as planned")
  # aliases
  al <- p$alias
  FA <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s", .mig067_inlist(al$uuid)))
  if (any(al$uuid[al$op == "delete"] %in% FA$uuid)) return("a deleted alias is still present")
  for (i in which(al$op != "delete")) {
    r <- FA[FA$uuid == al$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("alias %s is missing", al$uuid[[i]]))
    fs <- if (al$op[[i]] == "insert") c("uuid_feature", "name", "alias_key", "kind", "auto_assign", "confirmed_by", "comments", "date_start", "date_end")
          else .mig067_split(al$set[[i]])
    for (f in fs) if (!identical(toupper(.mig067_na(.st_changelog_str(r[[f]]))), toupper(.mig067_na(al[[f]][[i]]))))
      return(sprintf("alias %s %s is not %s", al$uuid[[i]], f, al[[f]][[i]]))
  }
  # review items
  rv <- p$review
  R <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolution, resolved_by FROM review_queue WHERE uuid IN %s", .mig067_inlist(rv$uuid)))
  r <- R[match(rv$uuid, R$uuid), , drop = FALSE]
  if (anyNA(r$uuid) || any(r$status != "resolved") || any(r$resolution != rv$resolution) || any(r$resolved_by != .mig067_resolved_by))
    return("a planned review item is not resolved with its planned resolution")
  # change_log
  E <- unlist(unname(.mig067_expected(p)))
  E <- E[E > 0L]
  L <- .mig067_logged(con)
  if (!setequal(names(L), names(E)) || !identical(as.integer(L[names(E)]), as.integer(E)))
    return(sprintf("067 change_log rows are %s, expected %s", paste(names(L), L, sep = "=", collapse = " "),
                   paste(names(E), E, sep = "=", collapse = " ")))
  NULL
}

.mig067_verify <- function(con, p) {
  pr <- .mig067_done_problem(con, p)
  if (!is.null(pr)) cli::cli_abort(paste0("067 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backups, files ----------------------------------------------------------------

mig067_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig067_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig067_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig067_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig067_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("067: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig067_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig067_name, what))

.mig067_write_backups <- function(con, p, csv_dir) {
  g <- function(tbl, ids, key = "uuid") DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE %s IN %s ORDER BY %s', tbl, key, .mig067_inlist(ids), key))
  .mig067_write_csv(g("analysis", p$change$uuid), .mig067_csv(csv_dir, "BACKUP-analysis"), "uuid")
  .mig067_write_csv(g("sample", p$sample$uuid), .mig067_csv(csv_dir, "BACKUP-sample"), "uuid")
  sli <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s OR uuid_sample IN %s ORDER BY work_order, lab_id",
                                      .mig067_inlist(.mig067_sli_key(p$sli)), .mig067_inlist(p$sample$uuid)))
  .mig067_write_csv(sli, .mig067_csv(csv_dir, "BACKUP-sample_lab_id"), "lab_id")
  .mig067_write_csv(g("feature", p$feature$uuid[p$feature$op == "update"]), .mig067_csv(csv_dir, "BACKUP-feature"), "uuid")
  .mig067_write_csv(g("feature_alias", c(p$alias$uuid[p$alias$op != "insert"], p$sample$uuid_feature_alias[grepl("uuid_feature_alias", p$sample$set)])),
                    .mig067_csv(csv_dir, "BACKUP-feature_alias"), "uuid")
  .mig067_write_csv(g("review_queue", p$review$uuid), .mig067_csv(csv_dir, "BACKUP-review_queue"), "uuid")
}

.mig067_read_skipped <- function(csv_dir) {
  f <- .mig067_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  s <- utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
  data.frame(gid = s$gid, problem = s$problem, stringsAsFactors = FALSE)
}

# ---- run -------------------------------------------------------------------------

mig067_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x_all <- .mig067_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig067_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig067_read_skipped(csv_dir)
    if (is.null(sk)) .mig067_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig067_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig067_verify(check_con, .mig067_restrict(x_all, sk)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("067 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    for (m in .mig067_requires)
      if (.mig067_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
        .mig067_fail(sprintf("marker %d is required first.", m))
    started <- .mig067_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig067_actor) > 0L
    if (!started) {
      sk <- .mig067_gid_problems(pre_con, x_all)
    } else {
      sk <- .mig067_read_skipped(csv_dir)
      if (is.null(sk)) .mig067_fail("a previous attempt wrote change_log rows but its SKIPPED CSV is missing; refusing.")
    }
    p <- .mig067_restrict(x_all, sk)
    ph <- .mig067_phase(pre_con, p)
    if (is.null(ph)) .mig067_fail("the database is part-way through 067 in a state no phase explains; refusing.")
    list(p = p, phase = ph, started = started)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- pre$p
  n_sk <- length(unique(p$skipped$gid))
  all_gids <- unique(unlist(lapply(x_all, function(d) d$gid)))
  logf("Plan (step %s): %d groups, %d skipped (%d items left open by a skip). Close %d items; features: %d inserts, %d updates; aliases: %d updates, %d inserts, %d deletes; samples: %d updates, %d deletes; sample_lab_id: %d inserts, %d updates; analyses: %d inserts (%d re-inserts), %d moves, %d deletes, %d field updates.",
       pre$phase, length(all_gids), n_sk, sum(x_all$review$gid %in% p$skipped$gid), nrow(p$review),
       sum(p$feature$op == "insert"), sum(p$feature$op == "update"),
       sum(p$alias$op == "update"), sum(p$alias$op == "insert"), sum(p$alias$op == "delete"),
       sum(p$sample$op == "update"), sum(p$sample$op == "delete"), sum(p$sli$op == "insert"), sum(p$sli$op == "update"),
       nrow(p$insert), sum(p$insert$origin == "reinsert"), sum(p$change$op == "move"), sum(p$change$op == "delete"),
       sum(p$change$op == "update"))
  if (n_sk) for (i in seq_len(nrow(p$skipped))) logf("SKIP %s: %s", p$skipped$gid[[i]], p$skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: no backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p)))
  }

  if (!pre$started) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig067_write_backups(bk_con, p, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    .mig067_write_csv(.mig067_skipped_rows(x_all, p$skipped), .mig067_csv(csv_dir, "SKIPPED"), "gid")
    logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups and SKIPPED plan from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig067_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    if (!pre$started) {
      sk2 <- .mig067_gid_problems(con, x_all)
      if (!setequal(unique(sk2$gid), unique(p$skipped$gid)))
        .mig067_fail("the database changed between the plan and the write lock; re-run.")
    }
    ph <- .mig067_phase(con, p)
    if (!identical(ph, pre$phase)) .mig067_fail("the phase changed between the plan and the write lock; re-run.")
    .mig067_apply(con, p, ph, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig067_name, .mig067_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, skipped = p$skipped))
}
