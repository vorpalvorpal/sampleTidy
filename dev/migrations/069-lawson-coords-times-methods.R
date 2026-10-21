# Operator-run migration: Robin's rulings of 2026-10-22 on the B.L05 location, the
# ES2512129 sample times and five lab-method filings. Marker 1069. Requires 1068.
#
# ---- WHY -----------------------------------------------------------------------
# B.L05 (Lawson STP discharge point, PLAN-15 D.1) was the only feature with no
# geom_wkt. ES2512129's two samples lost their ESdat Sampled_Date_Time when assemble
# let the first (date-only XTAB) datetime win across the files of one order. Five
# analyses sit under the wrong lab_method: three ES2617126 cations that the source
# files report as dissolved (ED093F) are filed under ED093T (total); four EP131
# surrogate recoveries are filed under the EP068S/EP066S surrogates; and one SAR
# value reported under "ED093F: SAR and Hardness Calculations" is filed under EA006.
#
# ---- WHAT (frozen in the INPUT CSVs beside this file; `item` = ruling number) ------
#   1  B.L05: lon/lat 150.431200, -33.732518 (Robin, approximate), replacing the
#      150.431198, -33.732518 recorded at registration; geom_wkt "POINT (lon lat)"
#      with the coordinates as supplied (was NULL); a dated note in feature.comments
#      (was NULL). lat is unchanged, so the update sets lon, geom_wkt and comments
#      (db_update logs only fields that change); the verify checks lon and lat.
#   2  ES2512129-001 (K.E01, b6894f12) datetime NULL -> 2025-04-28 00:55:00 UTC and
#      ES2512129-002 (K.E02, 46f07a15) -> 2025-04-28 00:50:00 UTC: the ESdat Sample2e
#      times 28 Apr 2025 10:55 / 10:50 in Sydney (AEST, UTC+10), stored naive UTC as
#      066/068 did. Guard: old datetime NULL (the row sha covers it). `date` is
#      unchanged. Their 29 + 28 analyses are deleted and re-inserted unchanged so the
#      indexed datetime can change (029/066/068 pattern).
#   3  ES2617126-001 (B.E01, efab9c98) Ca/Na/K moved from ED093T "Total Major
#      Cations" to the existing ED093F "Dissolved Major Cations" methods: the ESdat
#      Chemistry2e rows say Total_or_Filtered=F, "Major Cations - Dissolved", "ED093F".
#   4  Two ALS lab_methods minted: "Dibromo-DDE" / "EP131S: OC Pesticide Surrogate"
#      and "Decachlorobiphenyl" / "EP131T: PCB Surrogate" (the exact ENMRG text of
#      ES2340624/ES2340626), on the surrogates' analytes, in the shape of the existing
#      ALS surrogate rows (EP068S/EP066S: api 'false', every other column NULL). The
#      two Dibromo-DDE analyses move from EP068S to EP131S, the two
#      Decachlorobiphenyl analyses from EP066S to EP131T.
#   5  One ALS lab_method minted: "Sodium Adsorption Ratio" / "ED093F: SAR and
#      Hardness Calculations" (the exact ENMRG text of ES2617789) on the SAR analyte,
#      copying the EA006 SAR method's other columns (all NULL). The ES2617789-013
#      (B.S22, 3c00d959) SAR analysis moves from EA006 to it.
#   Every move checks that the target sample holds no analysis under the target method.
#
# Counts (plan): feature 1 update (3 fields); lab_method 3 inserts; analyses 8 moved
# (uuid_lab); samples 2 updates; analyses 57 deletes, 57 re-inserts. Net: lab_method
# +3, nothing else changes in size.
#
# ---- LIVE HAS MOVED ON --------------------------------------------------------
# Every group (`gid`) is checked against the target DB first: every row it updates,
# moves, deletes or re-inserts still byte-for-byte as frozen (sha1 of the row); the
# new lab_method uuids free and no ALS method of the same name + method; the target
# sample of each move holds no analysis under the target method; no
# ux_sample_identity collision; each re-timed sample holds only the planned analyses.
# A failing group is SKIPPED whole and listed in 069-...-SKIPPED.csv.
#
# ---- COMMITS (duckdb 1.4: FK checks do not see deletes made earlier in the same
# transaction; a sample's indexed columns cannot change while analyses reference it:
# 029, 032, 065, 066, 067, 068) ---------------------------------------------------
#   A. feature update; lab_method inserts; analysis moves; analysis deletes (commit)
#   B. sample datetime updates                                               (commit)
#   C. analysis re-inserts; marker; verify; counts; checksums                (commit)
# A re-run after a failure resumes at the first unfinished commit (read from
# change_log against the plan recorded in the SKIPPED CSV); any other state refuses.
#
# Backups: verified whole-file snapshot, plus BACKUP CSVs of every analysis, sample,
# feature and lab_method row the plan touches (lab_method header-only: all new).
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/069-lawson-coords-times-methods.R", envir = env)
#   env$mig069_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig069_marker_version <- 1069L
.mig069_requires <- 1068L
.mig069_name <- "069-lawson-coords-times-methods"
.mig069_actor <- .mig069_name
.mig069_n <- list(feature = 1L, lab_method = 3L, move = 8L, sample = 2L, change = 57L, insert = 57L)
.mig069_reason <- "069 (Robin's rulings 2026-10-22: B.L05 coordinates, ES2512129 sample times, lab-method filings)"
.mig069_lm_cols <- c("uuid", "uuid_analyte", "name", "method", "organisation", "rl_low", "rl_high", "reported_as", "api",
                     "uuid_project", "uuid_feature", "comments", "units", "conversion_constant", "preference")

.mig069_fail <- function(msg) cli::cli_abort(paste0(.mig069_name, ": ", msg), class = "sampletidy_error")
.mig069_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig069_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig069_na <- function(x) { x <- as.character(x); x[!is.na(x) & !nzchar(x)] <- NA_character_; x }
.mig069_chr <- function(x) if (is.na(x) || !nzchar(x)) NA_character_ else x
.mig069_num <- function(x) if (is.na(x) || !nzchar(x)) NA_real_ else as.numeric(x)   # decimal or C99 hex ("%a")
.mig069_int <- function(x) if (is.na(x) || !nzchar(x)) NA_integer_ else as.integer(x)
.mig069_lgl <- function(x) if (is.na(x) || !nzchar(x)) NA else as.logical(x)
.mig069_ts <- function(x) if (is.na(x) || !nzchar(x)) as.POSIXct(NA, tz = "UTC") else as.POSIXct(x, tz = "UTC")
.mig069_split <- function(s) if (is.na(s) || !nzchar(s)) character() else strsplit(s, ";", fixed = TRUE)[[1]]

# ---- inputs ------------------------------------------------------------------------

.mig069_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-INPUT-%s.csv", .mig069_name, suffix))
    if (!file.exists(p)) .mig069_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  x <- list(feature = rd("feature"), lab_method = rd("lab_method"), move = rd("analysis-move"), sample = rd("sample"),
            change = rd("analysis-change"), insert = rd("analysis-insert"))
  got <- vapply(x, nrow, 1L)
  if (!identical(unname(got), unname(unlist(.mig069_n[names(x)]))))
    .mig069_fail(sprintf("INPUT row counts are %s, not as planned.", paste(names(got), got, sep = "=", collapse = " ")))
  if (any(vapply(x, function(d) anyDuplicated(d$uuid) > 0L, TRUE))) .mig069_fail("an INPUT CSV repeats a key.")
  if (anyDuplicated(paste(x$insert$uuid_sample, x$insert$uuid_lab)))
    .mig069_fail("INPUT-analysis-insert repeats a (sample, lab_method) pair.")
  if (anyDuplicated(paste(x$move$uuid_sample, x$move$new_lab)))
    .mig069_fail("INPUT-analysis-move moves two analyses of one sample to one lab_method.")
  if (length(intersect(x$move$uuid, x$change$uuid))) .mig069_fail("an analysis is both moved and re-inserted.")
  if (!all(x$feature$op == "update") || !all(x$lab_method$op == "insert") || !all(x$move$op == "move") ||
      !all(x$sample$op == "update") || !all(x$change$op == "delete") || !all(x$change$note %in% "reinsert") ||
      !all(x$insert$origin == "reinsert"))
    .mig069_fail("an INPUT CSV has an unknown op/origin.")
  if (!setequal(x$insert$uuid, x$change$uuid)) .mig069_fail("re-inserts do not match the deletes.")
  if (!all(x$insert$uuid_sample %in% x$sample$uuid)) .mig069_fail("a re-insert is not on a re-timed sample.")
  if (!all(x$feature$set == "lon;geom_wkt;comments") || !all(x$sample$set == "datetime"))
    .mig069_fail("a feature or sample update sets columns other than planned.")
  if (!all(x$lab_method$organisation == "ALS")) .mig069_fail("a minted lab_method is not ALS.")
  if (any(x$move$old_lab == x$move$new_lab)) .mig069_fail("a move does not change the lab_method.")
  # a move onto a minted method must sit in that method's group (so they skip together)
  mm <- match(x$move$new_lab, x$lab_method$uuid)
  if (any(!is.na(mm) & x$lab_method$gid[mm] != x$move$gid)) .mig069_fail("a move onto a minted lab_method is outside its group.")
  if (anyNA(unlist(lapply(x, function(d) d$gid)))) .mig069_fail("every INPUT row needs a gid.")
  x
}

# sha1 of each row as text (the frozen value in the INPUT CSVs comes from this same
# function, so a row that changed in any column no longer matches).
.mig069_df_sha <- function(df) {
  out <- character(nrow(df))
  cols <- names(df)
  for (i in seq_len(nrow(df))) {
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[i]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  stats::setNames(out, df$uuid)
}

.mig069_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s', tbl, .mig069_inlist(ids)))
  s <- .mig069_df_sha(df)
  out[names(s)] <- s
  out
}

# ---- plan: which groups still hold on this DB ---------------------------------------

.mig069_gid_problems <- function(con, x) {
  P <- list()
  add <- function(g, msg) if (length(g)) P[[length(P) + 1L]] <<- data.frame(gid = g, problem = msg, stringsAsFactors = FALSE)
  chk_sha <- function(df, tbl, what) {
    if (!nrow(df)) return(invisible())
    sha <- .mig069_row_sha(con, tbl, df$uuid)
    bad <- is.na(sha[df$uuid]) | sha[df$uuid] != df$row_sha1
    add(df$gid[bad], sprintf("%s %s is not as frozen", what, df$uuid[bad]))
  }
  chk_sha(x$feature, "feature", "feature")

  lm <- x$lab_method
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig069_inlist(lm$uuid)))$uuid
  add(lm$gid[lm$uuid %in% taken], sprintf("lab_method uuid %s is already taken", lm$uuid[lm$uuid %in% taken]))
  for (i in seq_len(nrow(lm))) {
    n <- .mig069_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE organisation = ? AND lower(trim(name)) = lower(trim(?))
                              AND lower(trim(method)) = lower(trim(?))", lm$organisation[[i]], lm$name[[i]], lm$method[[i]])
    if (n > 0L) add(lm$gid[[i]], sprintf("an ALS lab_method '%s' / '%s' already exists", lm$name[[i]], lm$method[[i]]))
  }
  an <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM analyte WHERE uuid IN %s", .mig069_inlist(lm$uuid_analyte)))$uuid
  add(lm$gid[!(lm$uuid_analyte %in% an)], sprintf("lab_method %s analyte is gone", lm$uuid[!(lm$uuid_analyte %in% an)]))

  mv <- x$move
  chk_sha(mv, "analysis", "moved analysis")
  have_lab <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig069_inlist(mv$new_lab)))$uuid
  gone <- !(mv$new_lab %in% c(have_lab, lm$uuid))
  add(mv$gid[gone], sprintf("move target lab_method %s is gone", mv$new_lab[gone]))
  have <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample || '|' || uuid_lab AS k FROM analysis WHERE uuid_sample IN %s",
                                       .mig069_inlist(mv$uuid_sample)))$k
  bad <- paste(mv$uuid_sample, mv$new_lab, sep = "|") %in% have
  add(mv$gid[bad], sprintf("sample %s already holds an analysis of lab_method %s", mv$uuid_sample[bad], mv$new_lab[bad]))

  sc <- x$sample
  chk_sha(sc, "sample", "sample")
  nn <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM sample WHERE uuid IN %s AND datetime IS NULL", .mig069_inlist(sc$uuid)))$uuid
  add(sc$gid[!(sc$uuid %in% nn)], sprintf("sample %s datetime is no longer NULL", sc$uuid[!(sc$uuid %in% nn)]))
  on <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig069_inlist(sc$uuid)))
  extra <- unique(on$uuid_sample[!(on$uuid %in% x$change$uuid)])
  add(sc$gid[sc$uuid %in% extra], sprintf("sample %s holds an analysis outside the plan", sc$uuid[sc$uuid %in% extra]))
  for (i in seq_len(nrow(sc))) {
    n <- .mig069_scalar(con, "SELECT COUNT(*) FROM sample t JOIN sample s ON s.uuid = ? WHERE t.uuid_feature_alias = s.uuid_feature_alias
                              AND t.datetime = ? AND t.uuid_project IS NOT DISTINCT FROM s.uuid_project AND t.uuid <> s.uuid",
                        sc$uuid[[i]], .mig069_ts(sc$datetime[[i]]))
    if (n > 0L) add(sc$gid[[i]], sprintf("giving sample %s its datetime would collide on ux_sample_identity", sc$uuid[[i]]))
  }
  ch <- x$change
  chk_sha(ch, "analysis", "analysis")
  ins <- x$insert
  il <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig069_inlist(ins$uuid_lab)))$uuid
  add(ins$gid[!(ins$uuid_lab %in% il)], sprintf("insert lab_method %s is gone", ins$uuid_lab[!(ins$uuid_lab %in% il)]))

  if (!length(P)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  P <- do.call(rbind, P)
  P[!duplicated(P), , drop = FALSE]
}

.mig069_restrict <- function(x, skipped) {
  sk <- unique(skipped$gid)
  for (n in names(x)) x[[n]] <- x[[n]][!(x[[n]]$gid %in% sk), , drop = FALSE]
  x$skipped <- skipped
  x
}

.mig069_skipped_rows <- function(skipped) {
  if (!nrow(skipped)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  stats::aggregate(problem ~ gid, data = skipped, FUN = function(p) paste(unique(p), collapse = "; "))
}

# ---- phases ----------------------------------------------------------------------

# Expected change_log rows per commit (tbl|action -> n). No tbl|action pair is
# written by two commits, so each commit's counts are separable.
.mig069_expected <- function(p) {
  nset <- function(s) sum(vapply(s, function(z) length(.mig069_split(z)), 0L))
  A <- c("feature|update" = nset(p$feature$set),
         "lab_method|insert" = nrow(p$lab_method),
         "analysis|update" = nrow(p$move),
         "analysis|delete" = nrow(p$change))
  B <- c("sample|update" = nset(p$sample$set))
  C <- c("analysis|insert" = nrow(p$insert))
  list(A = A, B = B, C = C)
}

.mig069_logged <- function(con) {
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig069_actor))
  stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
}

# "A" nothing done; "B" commit A done; "C" A and B done. NULL = inconsistent.
.mig069_phase <- function(con, p) {
  L <- .mig069_logged(con)
  if (!length(L)) return("A")
  E <- .mig069_expected(p)
  got <- function(keys) { v <- L[keys]; v[is.na(v)] <- 0L; stats::setNames(as.integer(v), keys) }
  same <- function(e) identical(got(names(e)), stats::setNames(as.integer(e), names(e)))
  zero <- function(e) all(got(names(e)) == 0L)
  if (any(!(names(L) %in% unique(c(names(E$A), names(E$B), names(E$C)))))) return(NULL)
  if (same(E$A) && zero(E$B) && zero(E$C)) return("B")
  if (same(E$A) && same(E$B) && zero(E$C)) return("C")
  NULL
}

# ---- apply -----------------------------------------------------------------------

.mig069_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_mask", "feature_alias", "sample_lab_id", "lab_method", "analyte", "project",
            "asset", "ingest_file", "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig069_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig069_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

.mig069_checksum <- function(con, p) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "feature", "lab_method", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig069_inlist(c(p$change$uuid, p$move$uuid))))
  out$sample_rest <- q(sprintf("SELECT * FROM sample WHERE uuid NOT IN %s ORDER BY uuid", .mig069_inlist(p$sample$uuid)))
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", .mig069_inlist(p$feature$uuid)))
  out$lab_method_rest <- q(sprintf("SELECT * FROM lab_method WHERE uuid NOT IN %s ORDER BY uuid", .mig069_inlist(p$lab_method$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig069_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig069_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig069_why <- function(df, i) sprintf("%s [ruling %s; group %s]: %s", .mig069_reason, df$item[[i]], df$gid[[i]], df$reason[[i]])

.mig069_value <- function(f, v) {
  switch(f, lon = , lat = .mig069_num(v), datetime = .mig069_ts(v), .mig069_chr(v))
}

.mig069_lm_rows <- function(lm) {
  v <- function(x, f, t) unname(vapply(x, f, t))
  tibble::tibble(uuid = lm$uuid, uuid_analyte = lm$uuid_analyte, name = lm$name, method = lm$method,
                 organisation = lm$organisation, rl_low = v(lm$rl_low, .mig069_num, 0),
                 rl_high = v(lm$rl_high, .mig069_num, 0), reported_as = v(lm$reported_as, .mig069_chr, ""),
                 api = v(lm$api, .mig069_chr, ""), uuid_project = v(lm$uuid_project, .mig069_chr, ""),
                 uuid_feature = v(lm$uuid_feature, .mig069_chr, ""), comments = v(lm$comments, .mig069_chr, ""),
                 units = v(lm$units, .mig069_chr, ""), conversion_constant = v(lm$conversion_constant, .mig069_num, 0),
                 preference = v(lm$preference, .mig069_int, 0L))
}

.mig069_apply <- function(con, p, phase, recorded_at, logf) {
  sums_before <- .mig069_checksum(con, p)
  want <- .mig069_counts(con)
  ft <- p$feature; lm <- p$lab_method; mv <- p$move; sc <- p$sample; ch <- p$change
  if (phase == "A") {
    want$analysis <- want$analysis - nrow(ch)
    want$lab_method <- want$lab_method + nrow(lm)
  }
  want$analysis <- want$analysis + nrow(p$insert)
  want$schema_version <- want$schema_version + 1L
  E <- .mig069_expected(p)
  want$change_log <- want$change_log + sum(unlist(E)) - .mig069_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig069_actor)

  if (phase == "A") {
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(ft))) {
        fs <- .mig069_split(ft$set[[i]])
        db_update(con, "feature", uuid = ft$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) .mig069_value(f, ft[[f]][[i]])), fs),
                  actor = .mig069_actor, reason = .mig069_why(ft, i))
      }
      rows <- .mig069_lm_rows(lm)
      for (i in seq_len(nrow(lm)))
        db_append(con, "lab_method", rows[i, , drop = FALSE], actor = .mig069_actor, reason = .mig069_why(lm, i))
      for (i in seq_len(nrow(mv)))
        db_update(con, "analysis", uuid = mv$uuid[[i]], changes = list(uuid_lab = mv$new_lab[[i]]),
                  actor = .mig069_actor, reason = .mig069_why(mv, i))
      if (nrow(ch)) {
        n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig069_inlist(ch$uuid)))
        if (n != nrow(ch)) .mig069_fail(sprintf("set-based delete on analysis removed %d rows, not %d.", n, nrow(ch)))
        at <- Sys.time()
        for (i in seq_len(nrow(ch)))
          .st_write_change_log(con, at = at, actor = .mig069_actor, action = "delete", tbl = "analysis",
                               uuid_row = ch$uuid[[i]], field = NA_character_, old = ch$uuid[[i]], new = NA_character_,
                               reason = .mig069_why(ch, i), source_hash = NA_character_)
      }
      NULL
    })
    logf("A: %d feature updates; %d lab_methods minted; %d analyses moved; %d analyses deleted to re-insert (committed).",
         nrow(ft), nrow(lm), nrow(mv), nrow(ch))
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(sc)))
        db_update(con, "sample", uuid = sc$uuid[[i]], changes = list(datetime = .mig069_ts(sc$datetime[[i]])),
                  actor = .mig069_actor, reason = .mig069_why(sc, i))
      NULL
    })
    logf("B: %d sample datetime updates (committed).", nrow(sc))
    phase <- "C"
  }
  db_transaction(con, function(con) {
    ins <- p$insert
    for (i in seq_len(nrow(ins))) {
      row <- tibble::tibble(uuid = ins$uuid[[i]], uuid_sample = ins$uuid_sample[[i]], uuid_lab = ins$uuid_lab[[i]],
                            value = .mig069_num(ins$value[[i]]), value_chr = .mig069_chr(ins$value_chr[[i]]),
                            quantified = .mig069_lgl(ins$quantified[[i]]), rl_low = .mig069_num(ins$rl_low[[i]]),
                            rl_high = .mig069_num(ins$rl_high[[i]]), purpose = .mig069_chr(ins$purpose[[i]]),
                            comments = .mig069_chr(ins$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig069_actor, reason = .mig069_why(ins, i))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig069_marker_version, recorded_at))
    .mig069_verify(con, p)
    got <- .mig069_counts(con)
    if (!identical(got, want))
      .mig069_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig069_checksum(con, p))) .mig069_fail("something outside the planned rows moved.")
    NULL
  })
  logf("C: %d analyses re-inserted, marker %d (committed).", nrow(p$insert), .mig069_marker_version)
  invisible(TRUE)
}

# ---- verify ----------------------------------------------------------------------

.mig069_done_problem <- function(con, p) {
  if (.mig069_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig069_marker_version) != 1L)
    return("marker 1069 missing")
  eqn <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & abs(x - y) <= 1e-9 * pmax(1, abs(y)))
  eqc <- function(x, y) mapply(identical, .mig069_na(x), .mig069_na(y))
  num <- function(v) vapply(v, .mig069_num, 0)
  # analyses re-inserted exactly as frozen
  ins <- p$insert
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig069_inlist(ins$uuid)))
  a <- A[match(ins$uuid, A$uuid), , drop = FALSE]
  if (anyNA(a$uuid)) return(sprintf("%d planned analysis re-inserts are missing", sum(is.na(a$uuid))))
  ok <- a$uuid_sample == ins$uuid_sample & a$uuid_lab == ins$uuid_lab &
    eqn(a$value, num(ins$value)) & eqn(a$rl_low, num(ins$rl_low)) & eqn(a$rl_high, num(ins$rl_high)) &
    eqc(a$value_chr, ins$value_chr) & eqc(as.character(a$quantified), toupper(ins$quantified)) &
    eqc(a$comments, ins$comments) & eqc(a$purpose, ins$purpose)
  if (!all(ok)) return(sprintf("analysis re-insert %s is not as planned", ins$uuid[!ok][[1]]))
  if (nrow(ins) && !identical(sort(.mig069_row_sha(con, "analysis", ins$uuid)[ins$uuid]),
                              sort(stats::setNames(p$change$row_sha1, p$change$uuid)[ins$uuid])))
    return("a re-inserted analysis differs from the row deleted")
  # moved analyses: the frozen row with only uuid_lab changed
  mv <- p$move
  if (nrow(mv)) {
    M <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_lab FROM analysis WHERE uuid IN %s", .mig069_inlist(mv$uuid)))
    if (!identical(M$uuid_lab[match(mv$uuid, M$uuid)], mv$new_lab)) return("a moved analysis is not on its new lab_method")
    if (!identical(unname(.mig069_row_sha(con, "analysis", mv$uuid)[mv$uuid]), mv$row_sha1_after))
      return("a moved analysis changed in more than uuid_lab")
  }
  # minted lab_methods
  lm <- p$lab_method
  if (nrow(lm)) {
    L <- DBI::dbGetQuery(con, sprintf("SELECT * FROM lab_method WHERE uuid IN %s", .mig069_inlist(lm$uuid)))
    w <- .mig069_lm_rows(lm)
    L <- L[match(w$uuid, L$uuid), , drop = FALSE]
    if (anyNA(L$uuid)) return("a minted lab_method is missing")
    for (f in .mig069_lm_cols) {
      same <- if (is.numeric(w[[f]])) eqn(as.numeric(L[[f]]), as.numeric(w[[f]])) else eqc(L[[f]], w[[f]])
      if (!all(same)) return(sprintf("a minted lab_method differs in %s", f))
    }
  }
  # features
  ft <- p$feature
  Fe <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE uuid IN %s", .mig069_inlist(ft$uuid)))
  for (i in seq_len(nrow(ft))) {
    r <- Fe[Fe$uuid == ft$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("feature %s is missing", ft$uuid[[i]]))
    if (!eqn(r$lon, .mig069_num(ft$lon[[i]])) || !eqn(r$lat, .mig069_num(ft$lat[[i]]))) return(sprintf("feature %s lon/lat not as planned", ft$uuid[[i]]))
    for (f in c("geom_wkt", "comments")) if (!identical(.mig069_na(r[[f]]), .mig069_na(ft[[f]][[i]])))
      return(sprintf("feature %s %s is not as planned", ft$uuid[[i]], f))
  }
  # samples
  sc <- p$sample
  S <- DBI::dbGetQuery(con, sprintf("SELECT uuid, datetime FROM sample WHERE uuid IN %s", .mig069_inlist(sc$uuid)))
  for (i in seq_len(nrow(sc))) {
    s <- S[S$uuid == sc$uuid[[i]], , drop = FALSE]
    if (nrow(s) != 1L || !identical(.st_changelog_str(s$datetime), .st_changelog_str(.mig069_ts(sc$datetime[[i]]))))
      return(sprintf("sample %s datetime is not %s", sc$uuid[[i]], sc$datetime[[i]]))
  }
  # change_log
  E <- unlist(unname(.mig069_expected(p)))
  E <- E[E > 0L]
  L <- .mig069_logged(con)
  if (!setequal(names(L), names(E)) || !identical(as.integer(L[names(E)]), as.integer(E)))
    return(sprintf("069 change_log rows are %s, expected %s", paste(names(L), L, sep = "=", collapse = " "),
                   paste(names(E), E, sep = "=", collapse = " ")))
  NULL
}

.mig069_verify <- function(con, p) {
  pr <- .mig069_done_problem(con, p)
  if (!is.null(pr)) cli::cli_abort(paste0("069 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backups, files ----------------------------------------------------------------

mig069_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig069_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig069_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig069_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig069_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("069: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig069_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig069_name, what))

.mig069_write_backups <- function(con, p, csv_dir) {
  g <- function(tbl, ids) DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s ORDER BY uuid', tbl, .mig069_inlist(ids)))
  .mig069_write_csv(g("analysis", c(p$change$uuid, p$move$uuid)), .mig069_csv(csv_dir, "BACKUP-analysis"), "uuid")
  .mig069_write_csv(g("sample", p$sample$uuid), .mig069_csv(csv_dir, "BACKUP-sample"), "uuid")
  .mig069_write_csv(g("feature", p$feature$uuid), .mig069_csv(csv_dir, "BACKUP-feature"), "uuid")
  .mig069_write_csv(g("lab_method", p$lab_method$uuid), .mig069_csv(csv_dir, "BACKUP-lab_method"), "uuid")   # header-only: all new
}

.mig069_read_skipped <- function(csv_dir) {
  f <- .mig069_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  s <- utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
  data.frame(gid = s$gid, problem = s$problem, stringsAsFactors = FALSE)
}

# ---- run -------------------------------------------------------------------------

mig069_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x_all <- .mig069_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig069_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig069_read_skipped(csv_dir)
    if (is.null(sk)) .mig069_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig069_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig069_verify(check_con, .mig069_restrict(x_all, sk)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("069 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    for (m in .mig069_requires)
      if (.mig069_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
        .mig069_fail(sprintf("marker %d is required first.", m))
    started <- .mig069_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig069_actor) > 0L
    if (!started) {
      sk <- .mig069_gid_problems(pre_con, x_all)
    } else {
      sk <- .mig069_read_skipped(csv_dir)
      if (is.null(sk)) .mig069_fail("a previous attempt wrote change_log rows but its SKIPPED CSV is missing; refusing.")
    }
    p <- .mig069_restrict(x_all, sk)
    ph <- .mig069_phase(pre_con, p)
    if (is.null(ph)) .mig069_fail("the database is part-way through 069 in a state no phase explains; refusing.")
    list(p = p, phase = ph, started = started)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- pre$p
  n_sk <- length(unique(p$skipped$gid))
  all_gids <- unique(unlist(lapply(x_all, function(d) d$gid)))
  logf("Plan (step %s): %d groups, %d skipped. Features: %d updates; lab_methods: %d minted; analyses: %d moved; samples: %d datetime updates; analyses: %d deleted and re-inserted.",
       pre$phase, length(all_gids), n_sk, nrow(p$feature), nrow(p$lab_method), nrow(p$move), nrow(p$sample), nrow(p$insert))
  if (n_sk) for (i in seq_len(nrow(p$skipped))) logf("SKIP %s: %s", p$skipped$gid[[i]], p$skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: no backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p)))
  }

  if (!pre$started) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig069_write_backups(bk_con, p, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    .mig069_write_csv(.mig069_skipped_rows(p$skipped), .mig069_csv(csv_dir, "SKIPPED"), "gid")
    logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups and SKIPPED plan from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig069_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    if (!pre$started) {
      sk2 <- .mig069_gid_problems(con, x_all)
      if (!setequal(unique(sk2$gid), unique(p$skipped$gid)))
        .mig069_fail("the database changed between the plan and the write lock; re-run.")
    }
    ph <- .mig069_phase(con, p)
    if (!identical(ph, pre$phase)) .mig069_fail("the phase changed between the plan and the write lock; re-run.")
    .mig069_apply(con, p, ph, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig069_name, .mig069_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, skipped = p$skipped))
}
