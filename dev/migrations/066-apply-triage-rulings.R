# Operator-run migration: apply Robin's ACCEPTED rulings on the 2026-10-21 review-queue
# triage (the "recommend" items 065 left open). Marker 1066. Requires 1065.
#
# ---- WHY -----------------------------------------------------------------------
# 065 closed the CLEAR verdicts of the 2026-10-21 triage and left 180 items open.
# Robin answered the decision list (scratchpad/2026-10-21-review/DECISIONS.md,
# "Robin's answers", 2026-10-21 evening): ACCEPTED as recommended 1, 3, 4, 6, 7, 9,
# 10, 12, 13, 18, 19, 23 and the three alias-window changes of 15. This migration
# applies them. Items 2, 5, 8, 11, 14, 16, 17, 22 (more detail requested), 20 (an
# email), 21 (a code change) and 15's K.E02->K.S06 arm are NOT touched. Per-item
# evidence: scratchpad/2026-10-21-review/<slice>/verdicts.csv + REPORT.md and
# scratchpad/2026-10-21-review/m066/.
#
# ---- WHAT (frozen in the INPUT CSVs beside this file; `item` = decision number) ---
#   1  close 44 (ES2316166/ES2317541/2400-7286-05-09 bore labels; MW02 EC 552, MW09
#      EC 1127): keep live, "the bore series decides". MW09 SWL 2.86/2.89 stays open.
#   3  close 1: B.E01 2022-12-14 keeps "No discharge".
#   4  Main Dam (B.L01) March 2021: insert the 7 ALS samples live lacks (ES2110225-002
#      11:00, -003 13:00; ES2110713-002 22-Mar 15:30; ES2110708-001 23-Mar 14:00;
#      ES2111090-001 24-Mar 12:00; ES2111595-001 28-Mar 09:00, -002 11:00) on the
#      'Main Dam - Blaxland' alias, in their work-order projects, with their
#      sample_lab_id rows and 9 analyses each (63), exactly as the package's own
#      resolve path produces them from the ESdat files (cross-checked against the
#      XTAB files: every value equal); give the 4 date-only samples of the same
#      orders (ES2110225-001, ES2110713-001, ES2110708-002, ES2111090-002) their
#      ESdat times. Close 59 (27 batch_duplicate, 32 value_conflict).
#   6  ES2111128 26 Mar 2021: keep legacy B.S06 224c0332; move Ionic Balance and the
#      sample_lab_id row ES2111128-003 onto it; delete the 24 identical analyses and
#      the duplicate B.S22 sample 7f2a79c7. Close 1.
#   7  insert 8 held-back analyses: ES2602084 SAR + ionic balance x3 by lab id (the
#      bottle mix-up), ES2332504 ionic balance on K.MW01 and on K.MW04 ('B.MW04').
#      Close 2.
#   9  ES2515987-005 'Dis Lawson': re-point sample ES2515987005 B.L01 -> B.L05. Close 1.
#   10 close 6 (Mar 2022 'B.TS18 - Northern Drain...' kept on B.S30).
#   12 pending aliases confirmed (kind, auto_assign, confirmed_by R. Shannon, bounded
#      to the visit day where the ruling is a one-visit arm), extra one-day arms
#      inserted where a pending alias holds samples of several visits (the samples
#      re-pointed to them), merges/deletes of duplicate samples. 'Leachate Water'
#      stays open. Close 24.
#   13 close 8 (keep as filed); note on the two empty 'Amended 01' report projects.
#   15 alias windows: B.S04->B.S01 (5eb4e373) end 2026-01-21; B.TS40->B.TS39
#      (c0b269d2) end 2024-04-07; B.S22->B.S06 (6ca0abf7) end 2021-04-14.
#   23 the 5 ESdat Coliforms rows with Result 1 and Comments "~<2"/"~<10" stored as
#      non-detects (value = the "<" limit in canonical CFU/mL, quantified FALSE, as
#      ES2013803-008's "<10" is stored); close the 2 items 065 kept open.
#   18 and 19: nothing to write (18: the "pH 28.1/19.4/31.8" are Phenol-d6 surrogate
#      recoveries, correctly stored; 19: SAR on QC blanks already stored as reported).
#
# ---- LIVE HAS MOVED ON --------------------------------------------------------
# The plan was frozen from a copy of live. Every group (`gid`) is checked against
# the target DB first: its items still open with the same source_hash; every row it
# updates, moves, deletes or re-inserts still byte-for-byte as frozen (sha1 of the
# row); insert uuids free; targets present; no (sample, lab_method) or
# ux_sample_identity collision; nothing outside the plan on a sample or alias it
# deletes or rewrites. A failing group is SKIPPED whole (its items stay open) and
# listed in 066-...-SKIPPED.csv. A group's checks also cover the groups it needs.
#
# ---- COMMITS (duckdb 1.4: FK checks do not see deletes made earlier in the same
# transaction; a sample's indexed columns - uuid_feature_alias, datetime - cannot
# change while analyses reference it: 029, 032, 065) ------------------------------
#   A. feature_alias updates and inserts; analysis deletes (incl. those re-inserted
#      in C) and moves                                                     (commit)
#   B. sample_lab_id re-point; sample updates (datetime, uuid_feature_alias) and
#      deletes                                                             (commit)
#   C. feature_alias deletes; sample + sample_lab_id inserts; analysis inserts and
#      re-inserts; project notes; close items; marker; verify; counts; checksums
# A re-run after a failure resumes at the first unfinished commit (read from
# change_log against the plan recorded in the SKIPPED CSV); any other state refuses.
#
# Backups: verified whole-file snapshot, plus BACKUP CSVs of every analysis, sample,
# sample_lab_id, feature_alias, project and review_queue row the plan touches.
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/066-apply-triage-rulings.R", envir = env)
#   env$mig066_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig066_marker_version <- 1066L
.mig066_requires <- 1065L
.mig066_name <- "066-apply-triage-rulings"
.mig066_actor <- .mig066_name
.mig066_resolved_by <- .mig066_name
.mig066_n <- list(review = 148L, alias = 26L, sample = 22L, change = 134L, insert = 172L, other = 4L)
.mig066_reason <- "066 (Robin's rulings 2026-10-21 on the review-queue triage)"

.mig066_fail <- function(msg) cli::cli_abort(paste0(.mig066_name, ": ", msg), class = "sampletidy_error")
.mig066_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig066_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig066_na <- function(x) { x <- as.character(x); x[!is.na(x) & !nzchar(x)] <- NA_character_; x }
.mig066_chr <- function(x) if (is.na(x) || !nzchar(x)) NA_character_ else x
.mig066_num <- function(x) if (is.na(x) || !nzchar(x)) NA_real_ else as.numeric(x)
.mig066_lgl <- function(x) if (is.na(x) || !nzchar(x)) NA else as.logical(x)
.mig066_ts <- function(x) if (is.na(x) || !nzchar(x)) as.POSIXct(NA, tz = "UTC") else as.POSIXct(x, tz = "UTC")
.mig066_date <- function(x) if (is.na(x) || !nzchar(x)) as.Date(NA) else as.Date(x)

# ---- inputs ------------------------------------------------------------------------

.mig066_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-INPUT-%s.csv", .mig066_name, suffix))
    if (!file.exists(p)) .mig066_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  x <- list(review = rd("review"), alias = rd("alias"), sample = rd("sample"), change = rd("analysis-change"),
            insert = rd("analysis-insert"), other = rd("other"))
  got <- vapply(x, nrow, 1L)
  if (!identical(unname(got), unname(unlist(.mig066_n[names(x)]))))
    .mig066_fail(sprintf("INPUT row counts are %s, not as planned.", paste(names(got), got, sep = "=", collapse = " ")))
  if (anyDuplicated(x$review$uuid) || anyDuplicated(x$alias$uuid) || anyDuplicated(x$sample$uuid) ||
      anyDuplicated(x$change$uuid) || anyDuplicated(x$insert$uuid))
    .mig066_fail("an INPUT CSV repeats a uuid.")
  if (anyDuplicated(paste(x$insert$uuid_sample, x$insert$uuid_lab)))
    .mig066_fail("INPUT-analysis-insert repeats a (sample, lab_method) pair.")
  if (!all(x$alias$op %in% c("update", "insert", "delete")) || !all(x$sample$op %in% c("insert", "update", "delete")) ||
      !all(x$change$op %in% c("delete", "move")) || !all(x$insert$origin %in% c("new", "reinsert")) ||
      !all(x$other$tbl %in% c("sample_lab_id", "project")))
    .mig066_fail("an INPUT CSV has an unknown op/origin/tbl.")
  re <- x$insert$uuid[x$insert$origin == "reinsert"]
  if (!setequal(re, x$change$uuid[x$change$op == "delete" & x$change$note == "reinsert"]))
    .mig066_fail("re-inserts do not match the deletes marked reinsert.")
  if (anyNA(c(x$review$gid, x$alias$gid, x$sample$gid, x$change$gid, x$insert$gid, x$other$gid)))
    .mig066_fail("every INPUT row needs a gid.")
  x
}

# sha1 of each row as text, keyed by `key` (the frozen value in the INPUT CSVs comes
# from this same function, so a row that changed in any column no longer matches).
.mig066_row_sha <- function(con, tbl, ids, key = "uuid") {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE %s IN %s', tbl, key, .mig066_inlist(ids)))
  for (i in seq_len(nrow(df))) {
    v <- vapply(names(df), function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[df[[key]][[i]]]] <- digest::digest(paste(names(df), v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  out
}
# sample_lab_id has a composite key: rows are addressed as "work_order|lab_id"
.mig066_sli_sha <- function(con, keys) {
  out <- stats::setNames(rep(NA_character_, length(keys)), keys)
  if (!length(keys)) return(out)
  df <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s", .mig066_inlist(keys)))
  for (i in seq_len(nrow(df))) {
    v <- vapply(names(df), function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[paste(df$work_order[[i]], df$lab_id[[i]], sep = "|")]] <-
      digest::digest(paste(names(df), v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  out
}

# ---- plan: which groups still hold on this DB ---------------------------------------

.mig066_gid_problems <- function(con, x) {
  P <- list()
  add <- function(g, msg) if (length(g)) P[[length(P) + 1L]] <<- data.frame(gid = g, problem = msg, stringsAsFactors = FALSE)
  chk_sha <- function(df, tbl, what) {
    if (!nrow(df)) return(invisible())
    sha <- .mig066_row_sha(con, tbl, df$uuid)
    bad <- is.na(sha[df$uuid]) | sha[df$uuid] != df$row_sha1
    add(df$gid[bad], sprintf("%s %s is not as frozen", what, df$uuid[bad]))
  }
  # review items
  rv <- x$review
  rq <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, source_hash FROM review_queue WHERE uuid IN %s", .mig066_inlist(rv$uuid)))
  m <- rq[match(rv$uuid, rq$uuid), , drop = FALSE]
  bad <- is.na(m$uuid) | m$status != "open" | !mapply(identical, .mig066_na(m$source_hash), .mig066_na(rv$source_hash))
  add(rv$gid[bad], sprintf("review item %s is no longer open (or its source_hash changed)", rv$uuid[bad]))

  # aliases: updates/deletes as frozen; inserts free with their feature present
  al <- x$alias
  chk_sha(al[al$op != "insert", , drop = FALSE], "feature_alias", "alias")
  ins_a <- al[al$op == "insert", , drop = FALSE]
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig066_inlist(ins_a$uuid)))$uuid
  add(ins_a$gid[ins_a$uuid %in% taken], sprintf("alias uuid %s is already taken", ins_a$uuid[ins_a$uuid %in% taken]))
  need_f <- al$uuid_feature[al$op != "delete" & !is.na(al$uuid_feature)]
  have_f <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature WHERE uuid IN %s", .mig066_inlist(need_f)))$uuid
  bad <- al$op != "delete" & !is.na(al$uuid_feature) & !(al$uuid_feature %in% have_f)
  add(al$gid[bad], sprintf("alias %s target feature is gone", al$uuid[bad]))
  del_a <- al[al$op == "delete", , drop = FALSE]
  sc <- x$sample
  ons <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_feature_alias FROM sample WHERE uuid_feature_alias IN %s", .mig066_inlist(del_a$uuid)))
  leave <- sc$uuid[sc$op == "delete" | (sc$op == "update" & !is.na(sc$uuid_feature_alias))]
  extra <- unique(ons$uuid_feature_alias[!(ons$uuid %in% leave)])
  add(del_a$gid[del_a$uuid %in% extra], sprintf("alias %s holds a sample outside the plan", del_a$uuid[del_a$uuid %in% extra]))

  # samples
  chk_sha(sc[sc$op != "insert", , drop = FALSE], "sample", "sample")
  ch <- x$change
  planned_off <- ch$uuid   # every analysis the plan deletes or moves
  rw <- sc[sc$op != "insert", , drop = FALSE]
  on <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig066_inlist(rw$uuid)))
  extra <- unique(on$uuid_sample[!(on$uuid %in% planned_off)])
  add(rw$gid[rw$uuid %in% extra], sprintf("sample %s holds an analysis outside the plan", rw$uuid[rw$uuid %in% extra]))
  ds <- sc$uuid[sc$op == "delete"]
  sl <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample, work_order || '|' || lab_id AS k FROM sample_lab_id WHERE uuid_sample IN %s", .mig066_inlist(ds)))
  moved_sli <- x$other$key[x$other$tbl == "sample_lab_id"]
  bad <- sl$uuid_sample[!(sl$k %in% moved_sli)]
  add(sc$gid[sc$uuid %in% bad], sprintf("sample %s to delete has a sample_lab_id row outside the plan", sc$uuid[sc$uuid %in% bad]))
  ins_s <- sc[sc$op == "insert", , drop = FALSE]
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig066_inlist(ins_s$uuid)))$uuid
  add(ins_s$gid[ins_s$uuid %in% taken], sprintf("sample uuid %s is already taken", ins_s$uuid[ins_s$uuid %in% taken]))
  pr <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM project WHERE uuid IN %s", .mig066_inlist(ins_s$uuid_project)))$uuid
  add(ins_s$gid[!(ins_s$uuid_project %in% pr)], sprintf("project %s of a new sample is gone", ins_s$uuid_project[!(ins_s$uuid_project %in% pr)]))
  k <- paste(ins_s$lab_work_order, ins_s$lab_id, sep = "|")
  tk <- DBI::dbGetQuery(con, sprintf("SELECT work_order || '|' || lab_id AS k FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s", .mig066_inlist(k)))$k
  add(ins_s$gid[k %in% tk], sprintf("sample_lab_id %s is already taken", k[k %in% tk]))
  # alias targets of new / re-pointed samples: present now, or inserted by the plan
  tgt <- sc[sc$op != "delete" & !is.na(sc$uuid_feature_alias), , drop = FALSE]
  have_al <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig066_inlist(tgt$uuid_feature_alias)))$uuid
  bad <- !(tgt$uuid_feature_alias %in% c(have_al, ins_a$uuid))
  add(tgt$gid[bad], sprintf("sample %s alias target %s is gone", tgt$uuid[bad], tgt$uuid_feature_alias[bad]))
  # ux_sample_identity (alias, datetime, project) after the plan, for every sample
  # inserted or with an indexed column rewritten
  idx <- sc[sc$op == "insert" | (sc$op == "update" & !is.na(sc$set)), , drop = FALSE]
  for (i in seq_len(nrow(idx))) {
    cur <- DBI::dbGetQuery(con, "SELECT uuid_feature_alias, datetime, uuid_project FROM sample WHERE uuid = ?", params = list(idx$uuid[[i]]))
    if (idx$op[[i]] == "update" && nrow(cur) != 1L) next   # reported by the sha check
    fs <- if (is.na(idx$set[[i]])) character() else strsplit(idx$set[[i]], ";", fixed = TRUE)[[1]]
    a <- if (idx$op[[i]] == "insert" || "uuid_feature_alias" %in% fs) idx$uuid_feature_alias[[i]] else cur$uuid_feature_alias[[1]]
    proj <- if (idx$op[[i]] == "insert") idx$uuid_project[[i]] else cur$uuid_project[[1]]
    dt <- if (idx$op[[i]] == "insert" || "datetime" %in% fs) .mig066_ts(idx$datetime[[i]]) else cur$datetime[[1]]
    if (is.na(dt)) next
    n <- .mig066_scalar(con, sprintf("SELECT COUNT(*) FROM sample WHERE uuid_feature_alias = ? AND datetime = ? AND uuid_project IS NOT DISTINCT FROM ? AND uuid <> ? AND uuid NOT IN %s",
                                     .mig066_inlist(sc$uuid[sc$op == "delete"])), a, dt, proj, idx$uuid[[i]])
    clash <- idx$uuid != idx$uuid[[i]] & idx$op == "insert" & idx$uuid_feature_alias == a & idx$uuid_project == proj &
      !is.na(idx$datetime) & idx$datetime == .st_changelog_str(dt)
    if (n > 0L || any(clash, na.rm = TRUE)) add(idx$gid[[i]], sprintf("sample %s would collide on ux_sample_identity", idx$uuid[[i]]))
  }

  # analyses changed: as frozen; move targets present and free of that lab_method
  chk_sha(ch, "analysis", "analysis")
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv)) {
    lab <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_lab FROM analysis WHERE uuid IN %s", .mig066_inlist(mv$uuid)))
    tg <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig066_inlist(mv$new_sample)))$uuid
    add(mv$gid[!(mv$new_sample %in% tg)], sprintf("move target sample %s is gone", mv$new_sample[!(mv$new_sample %in% tg)]))
    have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s", .mig066_inlist(mv$new_sample)))
    have <- have$k[!(have$uuid %in% ch$uuid)]
    kk <- paste(mv$new_sample, lab$uuid_lab[match(mv$uuid, lab$uuid)], sep = "|")
    add(mv$gid[kk %in% have], sprintf("move target %s already holds that lab_method", mv$new_sample[kk %in% have]))
  }

  # inserts
  ins <- x$insert
  new <- ins[ins$origin == "new", , drop = FALSE]
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM analysis WHERE uuid IN %s", .mig066_inlist(new$uuid)))$uuid
  add(new$gid[new$uuid %in% taken], sprintf("insert uuid %s is already taken", new$uuid[new$uuid %in% taken]))
  smp <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s", .mig066_inlist(ins$uuid_sample)))$uuid
  bad <- !(ins$uuid_sample %in% c(smp, ins_s$uuid)) | ins$uuid_sample %in% ds
  add(ins$gid[bad], sprintf("insert target sample %s is gone", ins$uuid_sample[bad]))
  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig066_inlist(ins$uuid_lab)))$uuid
  add(ins$gid[!(ins$uuid_lab %in% lm)], sprintf("insert lab_method %s is gone", ins$uuid_lab[!(ins$uuid_lab %in% lm)]))
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s", .mig066_inlist(ins$uuid_sample)))
  have <- have$k[!(have$uuid %in% ch$uuid)]
  bad <- paste(ins$uuid_sample, ins$uuid_lab, sep = "|") %in% have
  add(ins$gid[bad], sprintf("sample %s already holds an analysis of lab_method %s", ins$uuid_sample[bad], ins$uuid_lab[bad]))

  # other: sample_lab_id / project rows as frozen
  ot <- x$other
  sli <- ot[ot$tbl == "sample_lab_id", , drop = FALSE]
  sha <- .mig066_sli_sha(con, sli$key)
  bad <- is.na(sha[sli$key]) | sha[sli$key] != sli$row_sha1
  add(sli$gid[bad], sprintf("sample_lab_id %s is not as frozen", sli$key[bad]))
  pj <- ot[ot$tbl == "project", , drop = FALSE]
  sha <- .mig066_row_sha(con, "project", pj$key)
  bad <- is.na(sha[pj$key]) | sha[pj$key] != pj$row_sha1
  add(pj$gid[bad], sprintf("project %s is not as frozen", pj$key[bad]))

  if (!length(P)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  P <- do.call(rbind, P)
  P[!duplicated(P), , drop = FALSE]
}

# A group that fails takes with it every group that depends on it (here: none share
# rows; kept for safety - a gid's rows never appear under another gid).
.mig066_restrict <- function(x, skipped) {
  sk <- unique(skipped$gid)
  for (n in names(x)) x[[n]] <- x[[n]][!(x[[n]]$gid %in% sk), , drop = FALSE]
  x$skipped <- skipped
  x
}

.mig066_skipped_rows <- function(x_all, skipped) {
  if (!nrow(skipped)) return(data.frame(gid = character(), items = character(), problem = character(), stringsAsFactors = FALSE))
  agg <- stats::aggregate(problem ~ gid, data = skipped, FUN = function(p) paste(unique(p), collapse = "; "))
  agg$items <- vapply(agg$gid, function(g) paste(x_all$review$uuid[x_all$review$gid == g], collapse = " "), "")
  agg[, c("gid", "items", "problem")]
}

# ---- phases ----------------------------------------------------------------------

# Expected change_log rows per commit (tbl|action -> n).
.mig066_expected <- function(p) {
  al <- p$alias; sc <- p$sample; ch <- p$change
  nset <- function(s) if (is.na(s) || !nzchar(s)) 0L else length(strsplit(s, ";", fixed = TRUE)[[1]])
  A <- c("feature_alias|update" = sum(vapply(al$set[al$op == "update"], nset, 0L)),
         "feature_alias|insert" = sum(al$op == "insert"),
         "analysis|delete" = sum(ch$op == "delete"),
         "analysis|update" = sum(ch$op == "move"))
  B <- c("sample_lab_id|update" = sum(p$other$tbl == "sample_lab_id"),
         "sample|update" = sum(vapply(sc$set[sc$op == "update"], nset, 0L)),
         "sample|delete" = sum(sc$op == "delete"))
  C <- c("feature_alias|delete" = sum(al$op == "delete"),
         "sample|insert" = sum(sc$op == "insert"),
         "sample_lab_id|insert" = sum(sc$op == "insert"),
         "analysis|insert" = nrow(p$insert),
         "project|update" = sum(p$other$tbl == "project"),
         "review_queue|update" = 4L * nrow(p$review))
  list(A = A, B = B, C = C)
}

.mig066_logged <- function(con) {
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig066_actor))
  stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
}

# "A" nothing done; "B" commit A done; "C" A and B done. NULL = inconsistent.
.mig066_phase <- function(con, p) {
  L <- .mig066_logged(con)
  if (!length(L)) return("A")
  E <- .mig066_expected(p)
  got <- function(keys) { v <- L[keys]; v[is.na(v)] <- 0L; stats::setNames(as.integer(v), keys) }
  same <- function(e) identical(got(names(e)), stats::setNames(as.integer(e), names(e)))
  zero <- function(e) all(got(names(e)) == 0L)
  # tbl|action pairs shared between commits (sample|update only in B; analysis|update
  # only in A) - none, so each commit's counts are separable.
  known <- unique(c(names(E$A), names(E$B), names(E$C)))
  if (any(!(names(L) %in% known))) return(NULL)
  if (same(E$A) && zero(E$B) && zero(E$C)) return("B")
  if (same(E$A) && same(E$B) && zero(E$C)) return("C")
  NULL
}

# ---- apply -----------------------------------------------------------------------

.mig066_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature_alias", "sample_lab_id", "lab_method", "project", "asset", "ingest_file",
            "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig066_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig066_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

.mig066_checksum <- function(con, p) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "sample_lab_id", "feature_alias", "project", "review_queue", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig066_inlist(c(p$change$uuid, p$insert$uuid))))
  out$sample_rest <- q(sprintf("SELECT * FROM sample WHERE uuid NOT IN %s ORDER BY uuid", .mig066_inlist(p$sample$uuid)))
  sk <- c(p$other$key[p$other$tbl == "sample_lab_id"], paste(p$sample$lab_work_order, p$sample$lab_id, sep = "|")[p$sample$op == "insert"])
  out$sli_rest <- q(sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id NOT IN %s ORDER BY ALL", .mig066_inlist(sk)))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", .mig066_inlist(p$alias$uuid)))
  out$project_rest <- q(sprintf("SELECT * FROM project WHERE uuid NOT IN %s ORDER BY uuid", .mig066_inlist(p$other$key[p$other$tbl == "project"])))
  out$review_rest <- q(sprintf("SELECT * FROM review_queue WHERE uuid NOT IN %s ORDER BY uuid", .mig066_inlist(p$review$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig066_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig066_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig066_why <- function(p, gid, what) {
  it <- unique(c(p$review$item[p$review$gid == gid], p$alias$item[p$alias$gid == gid], p$sample$item[p$sample$gid == gid]))
  it <- it[!is.na(it)]
  sprintf("%s [decision %s; group %s]: %s", .mig066_reason, paste(it, collapse = "+"), gid, what)
}

.mig066_delete_logged <- function(con, table, ids, reasons) {
  if (!length(ids)) return(invisible(0L))
  n <- DBI::dbExecute(con, sprintf('DELETE FROM "%s" WHERE uuid IN %s', table, .mig066_inlist(ids)))
  if (n != length(ids)) .mig066_fail(sprintf("set-based delete on %s removed %d rows, not %d.", table, n, length(ids)))
  at <- Sys.time()
  for (i in seq_along(ids))
    .st_write_change_log(con, at = at, actor = .mig066_actor, action = "delete", tbl = table,
                         uuid_row = ids[[i]], field = NA_character_, old = ids[[i]], new = NA_character_,
                         reason = reasons[[i]], source_hash = NA_character_)
  invisible(n)
}

.mig066_alias_value <- function(f, v) {
  switch(f, auto_assign = .mig066_lgl(v), date_start = , date_end = .mig066_date(v), n_seen = as.integer(v), .mig066_chr(v))
}

.mig066_apply <- function(con, p, phase, recorded_at, logf) {
  sums_before <- .mig066_checksum(con, p)
  want <- .mig066_counts(con)
  al <- p$alias; sc <- p$sample; ch <- p$change; ot <- p$other
  why <- function(df, i) .mig066_why(p, df$gid[[i]], df$reason[[i]])
  if (phase == "A") {
    want$analysis <- want$analysis - sum(ch$op == "delete")
    want$feature_alias <- want$feature_alias + sum(al$op == "insert")
  }
  if (phase %in% c("A", "B")) want$sample <- want$sample - sum(sc$op == "delete")
  want$feature_alias <- want$feature_alias - sum(al$op == "delete")
  want$sample <- want$sample + sum(sc$op == "insert")
  want$sample_lab_id <- want$sample_lab_id + sum(sc$op == "insert")
  want$analysis <- want$analysis + nrow(p$insert)
  want$review_open <- want$review_open - nrow(p$review)
  want$schema_version <- want$schema_version + 1L
  E <- .mig066_expected(p)
  want$change_log <- want$change_log + sum(unlist(E)) - .mig066_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig066_actor)

  if (phase == "A") {
    db_transaction(con, function(con) {
      up <- al[al$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(up))) {
        fs <- strsplit(up$set[[i]], ";", fixed = TRUE)[[1]]
        db_update(con, "feature_alias", uuid = up$uuid[[i]],
                  changes = stats::setNames(lapply(fs, function(f) .mig066_alias_value(f, up[[f]][[i]])), fs),
                  actor = .mig066_actor, reason = why(up, i))
      }
      ia <- al[al$op == "insert", , drop = FALSE]
      for (i in seq_len(nrow(ia))) {
        row <- tibble::tibble(uuid = ia$uuid[[i]], uuid_feature = ia$uuid_feature[[i]], name = ia$name[[i]],
                              alias_key = ia$alias_key[[i]], kind = ia$kind[[i]], n_seen = 0L,
                              auto_assign = .mig066_lgl(ia$auto_assign[[i]]), first_seen = as.POSIXct(NA),
                              last_seen = as.POSIXct(NA), confirmed_by = .mig066_chr(ia$confirmed_by[[i]]),
                              comments = .mig066_chr(ia$comments[[i]]), date_start = .mig066_date(ia$date_start[[i]]),
                              date_end = .mig066_date(ia$date_end[[i]]))
        db_append(con, "feature_alias", row, actor = .mig066_actor, reason = why(ia, i))
      }
      del <- ch[ch$op == "delete", , drop = FALSE]
      .mig066_delete_logged(con, "analysis", del$uuid, vapply(seq_len(nrow(del)), function(i) why(del, i), ""))
      mv <- ch[ch$op == "move", , drop = FALSE]
      for (i in seq_len(nrow(mv)))
        db_update(con, "analysis", uuid = mv$uuid[[i]], changes = list(uuid_sample = mv$new_sample[[i]]),
                  actor = .mig066_actor, reason = why(mv, i))
      NULL
    })
    logf("A: %d alias updates, %d alias inserts, %d analyses deleted (%d to re-insert), %d moved (committed).",
         sum(al$op == "update"), sum(al$op == "insert"), sum(ch$op == "delete"), sum(ch$note == "reinsert", na.rm = TRUE),
         sum(ch$op == "move"))
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) {
      sli <- ot[ot$tbl == "sample_lab_id", , drop = FALSE]
      for (i in seq_len(nrow(sli))) {
        kk <- strsplit(sli$key[[i]], "|", fixed = TRUE)[[1]]
        db_update(con, "sample_lab_id", key = list(work_order = kk[[1]], lab_id = kk[[2]]),
                  changes = stats::setNames(list(sli$new[[i]]), sli$field[[i]]), actor = .mig066_actor, reason = why(sli, i))
      }
      su <- sc[sc$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(su))) {
        fs <- strsplit(su$set[[i]], ";", fixed = TRUE)[[1]]
        chg <- lapply(fs, function(f) if (f == "datetime") .mig066_ts(su$datetime[[i]]) else su[[f]][[i]])
        db_update(con, "sample", uuid = su$uuid[[i]], changes = stats::setNames(chg, fs), actor = .mig066_actor, reason = why(su, i))
      }
      sd <- sc[sc$op == "delete", , drop = FALSE]
      .mig066_delete_logged(con, "sample", sd$uuid, vapply(seq_len(nrow(sd)), function(i) why(sd, i), ""))
      NULL
    })
    logf("B: %d sample_lab_id re-points, %d sample updates, %d samples deleted (committed).",
         sum(ot$tbl == "sample_lab_id"), sum(sc$op == "update"), sum(sc$op == "delete"))
    phase <- "C"
  }
  db_transaction(con, function(con) {
    da <- al[al$op == "delete", , drop = FALSE]
    .mig066_delete_logged(con, "feature_alias", da$uuid, vapply(seq_len(nrow(da)), function(i) why(da, i), ""))
    si <- sc[sc$op == "insert", , drop = FALSE]
    for (i in seq_len(nrow(si))) {
      row <- tibble::tibble(uuid = si$uuid[[i]], uuid_feature_alias = si$uuid_feature_alias[[i]], uuid_project = si$uuid_project[[i]],
                            date = .mig066_ts(si$date[[i]]), date_start = as.POSIXct(NA), datetime = .mig066_ts(si$datetime[[i]]),
                            datetime_start = as.POSIXct(NA), organisation = .mig066_chr(si$organisation[[i]]),
                            person = NA_character_, purpose = NA_character_, comments = NA_character_)
      db_append(con, "sample", row, actor = .mig066_actor, reason = why(si, i), source_hash = .mig066_chr(si$lab_source_hash[[i]]))
      db_append(con, "sample_lab_id",
                tibble::tibble(uuid_sample = si$uuid[[i]], work_order = si$lab_work_order[[i]], lab_id = si$lab_id[[i]],
                               client_id = .mig066_chr(si$client_id[[i]]), source_hash = .mig066_chr(si$lab_source_hash[[i]])),
                actor = .mig066_actor, reason = why(si, i), source_hash = .mig066_chr(si$lab_source_hash[[i]]))
    }
    ins <- p$insert
    for (i in seq_len(nrow(ins))) {
      row <- tibble::tibble(uuid = ins$uuid[[i]], uuid_sample = ins$uuid_sample[[i]], uuid_lab = ins$uuid_lab[[i]],
                            value = .mig066_num(ins$value[[i]]), value_chr = .mig066_chr(ins$value_chr[[i]]),
                            quantified = .mig066_lgl(ins$quantified[[i]]), rl_low = .mig066_num(ins$rl_low[[i]]),
                            rl_high = .mig066_num(ins$rl_high[[i]]), purpose = .mig066_chr(ins$purpose[[i]]),
                            comments = .mig066_chr(ins$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig066_actor, reason = why(ins, i), source_hash = .mig066_chr(ins$source_hash[[i]]))
    }
    pj <- ot[ot$tbl == "project", , drop = FALSE]
    for (i in seq_len(nrow(pj)))
      db_update(con, "project", uuid = pj$key[[i]], changes = stats::setNames(list(pj$new[[i]]), pj$field[[i]]),
                actor = .mig066_actor, reason = why(pj, i))
    at <- Sys.time()
    rv <- p$review
    for (i in seq_len(nrow(rv)))
      db_update(con, "review_queue", uuid = rv$uuid[[i]],
                changes = list(status = "resolved", resolution = rv$resolution[[i]], resolved_by = .mig066_resolved_by, resolved_at = at),
                actor = .mig066_actor, reason = .mig066_why(p, rv$gid[[i]], sprintf("close review item %s", rv$uuid[[i]])))
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig066_marker_version, recorded_at))
    .mig066_verify(con, p)
    got <- .mig066_counts(con)
    if (!identical(got, want))
      .mig066_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig066_checksum(con, p))) .mig066_fail("something outside the planned rows moved.")
    NULL
  })
  logf("C: %d aliases deleted, %d samples + lab ids inserted, %d analyses inserted (%d re-inserts), %d project notes, %d items closed, marker %d (committed).",
       sum(al$op == "delete"), sum(sc$op == "insert"), nrow(p$insert), sum(p$insert$origin == "reinsert"),
       sum(ot$tbl == "project"), nrow(p$review), .mig066_marker_version)
  invisible(TRUE)
}

# ---- verify ----------------------------------------------------------------------

.mig066_done_problem <- function(con, p) {
  if (.mig066_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig066_marker_version) != 1L)
    return("marker 1066 missing")
  eqn <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & abs(x - y) <= 1e-9 * pmax(1, abs(y)))
  eqc <- function(x, y) mapply(identical, .mig066_na(x), .mig066_na(y))
  # analyses inserted / re-inserted exactly as planned
  ins <- p$insert
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig066_inlist(c(ins$uuid, p$change$uuid))))
  a <- A[match(ins$uuid, A$uuid), , drop = FALSE]
  if (anyNA(a$uuid)) return(sprintf("%d planned analysis inserts are missing", sum(is.na(a$uuid))))
  ok <- a$uuid_sample == ins$uuid_sample & a$uuid_lab == ins$uuid_lab &
    eqn(a$value, as.numeric(.mig066_na(ins$value))) & eqn(a$rl_low, as.numeric(.mig066_na(ins$rl_low))) &
    eqn(a$rl_high, as.numeric(.mig066_na(ins$rl_high))) & eqc(a$value_chr, ins$value_chr) &
    eqc(as.character(a$quantified), toupper(ins$quantified)) & eqc(a$comments, ins$comments) & eqc(a$purpose, ins$purpose)
  if (!all(ok)) return(sprintf("analysis insert %s is not as planned", ins$uuid[!ok][[1]]))
  ch <- p$change
  if (any(ch$uuid[ch$op == "delete" & ch$note != "reinsert"] %in% A$uuid)) return("a deleted analysis is still present")
  mv <- ch[ch$op == "move", , drop = FALSE]
  if (nrow(mv) && !all(A$uuid_sample[match(mv$uuid, A$uuid)] == mv$new_sample)) return("a moved analysis is not on its target")
  # samples
  sc <- p$sample
  S <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample WHERE uuid IN %s", .mig066_inlist(sc$uuid)))
  if (any(sc$uuid[sc$op == "delete"] %in% S$uuid)) return("a deleted sample is still present")
  for (i in which(sc$op != "delete")) {
    s <- S[S$uuid == sc$uuid[[i]], , drop = FALSE]
    if (nrow(s) != 1L) return(sprintf("sample %s is missing", sc$uuid[[i]]))
    if (!is.na(sc$uuid_feature_alias[[i]]) && !identical(s$uuid_feature_alias[[1]], sc$uuid_feature_alias[[i]]))
      return(sprintf("sample %s is not on alias %s", sc$uuid[[i]], sc$uuid_feature_alias[[i]]))
    if (!is.na(sc$datetime[[i]]) && !identical(.st_changelog_str(s$datetime), sc$datetime[[i]]))
      return(sprintf("sample %s datetime is not %s", sc$uuid[[i]], sc$datetime[[i]]))
    if (sc$op[[i]] == "insert" && (!identical(.st_changelog_str(s$date), sc$date[[i]]) || !identical(s$uuid_project, sc$uuid_project[[i]])))
      return(sprintf("new sample %s is not as planned", sc$uuid[[i]]))
  }
  si <- sc[sc$op == "insert", , drop = FALSE]
  if (nrow(si)) {
    L <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample_lab_id WHERE uuid_sample IN %s", .mig066_inlist(si$uuid)))
    l <- L[match(si$uuid, L$uuid_sample), , drop = FALSE]
    if (anyNA(l$uuid_sample) || any(l$work_order != si$lab_work_order) || any(l$lab_id != si$lab_id)) return("a new sample_lab_id row is not as planned")
  }
  ot <- p$other
  for (i in which(ot$tbl == "sample_lab_id")) {
    kk <- strsplit(ot$key[[i]], "|", fixed = TRUE)[[1]]
    v <- DBI::dbGetQuery(con, sprintf('SELECT "%s" AS v FROM sample_lab_id WHERE work_order = ? AND lab_id = ?', ot$field[[i]]), params = as.list(kk))$v
    if (!identical(v, ot$new[[i]])) return(sprintf("sample_lab_id %s is not re-pointed", ot$key[[i]]))
  }
  for (i in which(ot$tbl == "project")) {
    v <- DBI::dbGetQuery(con, sprintf('SELECT "%s" AS v FROM project WHERE uuid = ?', ot$field[[i]]), params = list(ot$key[[i]]))$v
    if (!identical(v, ot$new[[i]])) return(sprintf("project %s %s is not as planned", ot$key[[i]], ot$field[[i]]))
  }
  # aliases
  al <- p$alias
  FA <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s", .mig066_inlist(al$uuid)))
  if (any(al$uuid[al$op == "delete"] %in% FA$uuid)) return("a deleted alias is still present")
  for (i in which(al$op != "delete")) {
    r <- FA[FA$uuid == al$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("alias %s is missing", al$uuid[[i]]))
    fs <- if (al$op[[i]] == "insert") c("uuid_feature", "alias_key", "kind", "auto_assign", "confirmed_by", "date_start", "date_end")
          else strsplit(al$set[[i]], ";", fixed = TRUE)[[1]]
    for (f in fs) if (!identical(.mig066_na(.st_changelog_str(r[[f]])), .mig066_na(al[[f]][[i]])) &&
                      !identical(toupper(.mig066_na(.st_changelog_str(r[[f]]))), toupper(.mig066_na(al[[f]][[i]]))))
      return(sprintf("alias %s %s is not %s", al$uuid[[i]], f, al[[f]][[i]]))
  }
  # review items
  rv <- p$review
  R <- DBI::dbGetQuery(con, sprintf("SELECT uuid, status, resolution, resolved_by FROM review_queue WHERE uuid IN %s", .mig066_inlist(rv$uuid)))
  r <- R[match(rv$uuid, R$uuid), , drop = FALSE]
  if (anyNA(r$uuid) || any(r$status != "resolved") || any(r$resolution != rv$resolution) || any(r$resolved_by != .mig066_resolved_by))
    return("a planned review item is not resolved with its planned resolution")
  # change_log
  E <- unlist(unname(.mig066_expected(p)))
  E <- E[E > 0L]
  L <- .mig066_logged(con)
  if (!setequal(names(L), names(E)) || !identical(as.integer(L[names(E)]), as.integer(E)))
    return(sprintf("066 change_log rows are %s, expected %s", paste(names(L), L, sep = "=", collapse = " "),
                   paste(names(E), E, sep = "=", collapse = " ")))
  NULL
}

.mig066_verify <- function(con, p) {
  pr <- .mig066_done_problem(con, p)
  if (!is.null(pr)) cli::cli_abort(paste0("066 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backups, files ----------------------------------------------------------------

mig066_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig066_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig066_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig066_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig066_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("066: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig066_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig066_name, what))

.mig066_write_backups <- function(con, p, csv_dir) {
  g <- function(tbl, ids, key = "uuid") DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE %s IN %s ORDER BY %s', tbl, key, .mig066_inlist(ids), key))
  .mig066_write_csv(g("analysis", p$change$uuid), .mig066_csv(csv_dir, "BACKUP-analysis"), "uuid")
  .mig066_write_csv(g("sample", p$sample$uuid[p$sample$op != "insert"]), .mig066_csv(csv_dir, "BACKUP-sample"), "uuid")
  sli <- DBI::dbGetQuery(con, sprintf("SELECT * FROM sample_lab_id WHERE work_order || '|' || lab_id IN %s OR uuid_sample IN %s ORDER BY work_order, lab_id",
                                      .mig066_inlist(p$other$key[p$other$tbl == "sample_lab_id"]),
                                      .mig066_inlist(p$sample$uuid[p$sample$op != "insert"])))
  .mig066_write_csv(sli, .mig066_csv(csv_dir, "BACKUP-sample_lab_id"), "lab_id")
  .mig066_write_csv(g("feature_alias", c(p$alias$uuid[p$alias$op != "insert"], p$sample$uuid_feature_alias[p$sample$op == "update" & !is.na(p$sample$uuid_feature_alias)])),
                    .mig066_csv(csv_dir, "BACKUP-feature_alias"), "uuid")
  .mig066_write_csv(g("project", p$other$key[p$other$tbl == "project"]), .mig066_csv(csv_dir, "BACKUP-project"), "uuid")
  .mig066_write_csv(g("review_queue", p$review$uuid), .mig066_csv(csv_dir, "BACKUP-review_queue"), "uuid")
}

.mig066_read_skipped <- function(csv_dir) {
  f <- .mig066_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  s <- utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
  data.frame(gid = s$gid, problem = s$problem, stringsAsFactors = FALSE)
}

# ---- run -------------------------------------------------------------------------

mig066_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x_all <- .mig066_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig066_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig066_read_skipped(csv_dir)
    if (is.null(sk)) .mig066_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig066_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig066_verify(check_con, .mig066_restrict(x_all, sk)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("066 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    for (m in .mig066_requires)
      if (.mig066_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
        .mig066_fail(sprintf("marker %d is required first.", m))
    started <- .mig066_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig066_actor) > 0L
    if (!started) {
      sk <- .mig066_gid_problems(pre_con, x_all)
    } else {
      sk <- .mig066_read_skipped(csv_dir)
      if (is.null(sk)) .mig066_fail("a previous attempt wrote change_log rows but its SKIPPED CSV is missing; refusing.")
    }
    p <- .mig066_restrict(x_all, sk)
    ph <- .mig066_phase(pre_con, p)
    if (is.null(ph)) .mig066_fail("the database is part-way through 066 in a state no phase explains; refusing.")
    list(p = p, phase = ph, started = started)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- pre$p
  n_sk <- length(unique(p$skipped$gid))
  logf("Plan (step %s): %d groups, %d skipped (%d items left open by a skip). Close %d items; aliases: %d updates, %d inserts, %d deletes; samples: %d inserts, %d updates, %d deletes; analyses: %d inserts (%d re-inserts), %d moves, %d deletes; %d other updates.",
       pre$phase, length(unique(c(x_all$review$gid, x_all$alias$gid))), n_sk, sum(x_all$review$gid %in% p$skipped$gid),
       nrow(p$review), sum(p$alias$op == "update"), sum(p$alias$op == "insert"), sum(p$alias$op == "delete"),
       sum(p$sample$op == "insert"), sum(p$sample$op == "update"), sum(p$sample$op == "delete"),
       nrow(p$insert), sum(p$insert$origin == "reinsert"), sum(p$change$op == "move"), sum(p$change$op == "delete"), nrow(p$other))
  if (n_sk) for (i in seq_len(nrow(p$skipped))) logf("SKIP %s: %s", p$skipped$gid[[i]], p$skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: no backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p)))
  }

  if (!pre$started) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig066_write_backups(bk_con, p, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    .mig066_write_csv(.mig066_skipped_rows(x_all, p$skipped), .mig066_csv(csv_dir, "SKIPPED"), "gid")
    logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups and SKIPPED plan from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig066_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    if (!pre$started) {
      sk2 <- .mig066_gid_problems(con, x_all)
      if (!setequal(unique(sk2$gid), unique(p$skipped$gid)))
        .mig066_fail("the database changed between the plan and the write lock; re-run.")
    }
    ph <- .mig066_phase(con, p)
    if (!identical(ph, pre$phase)) .mig066_fail("the phase changed between the plan and the write lock; re-run.")
    .mig066_apply(con, p, ph, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig066_name, .mig066_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, skipped = p$skipped))
}
