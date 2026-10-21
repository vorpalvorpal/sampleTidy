# Operator-run migration: Robin's rulings of 2026-10-21 on what 067 left provisional.
# Marker 1068. Requires 1067.
#
# ---- WHY -----------------------------------------------------------------------
# 067 registered K.L07 and B.L06 with lon/lat copied from a neighbour (marked
# PROVISIONAL in their comments), added a one-day arm 'B.S05 - Diversion pipe outlet'
# -> B.TS39 for 2023-06-14 but left the undated arm to B.S05 overlapping it, and left
# K.L07's only sample date-only. Robin supplied the locations and asked for the split.
#
# ---- WHAT (frozen in the INPUT CSVs beside this file; `item` = ruling number) ------
#   1  K.L07 "Transfer station leachate sump (greenwaste)": lon/lat 150.323059,
#      -33.698424 (Robin, from Nearmap), geom_wkt to match; a dated note appended to
#      feature.comments (the PROVISIONAL note is kept as history).
#   2  B.L06 "Discharge Point - Winmalee STP": lon/lat 150.6251954, -33.6768023, the
#      OpenStreetMap centroid of the Winmalee Sewage Treatment Plant (Sydney Water) -
#      approximate (Robin: "approx location is fine"); geom_wkt set (was NULL); note.
#      lon/lat are WGS84 decimal degrees and geom_wkt is "POINT (lon lat)" as for every
#      other feature; the table has no projected easting/northing columns. geom_wkt
#      carries the coordinates as supplied, as the B.TG* features' do.
#   3  Split the undated alias ba4ec628 'B.S05 - Diversion pipe outlet' -> B.S05 around
#      2023-06-14: ba4ec628 ends 2023-06-13; a new arm 5c765e89 (same feature, name,
#      key, kind, auto_assign) starts 2023-06-15. On 2023-06-14 the name now resolves
#      only to B.TS39 (067's one-day arm 66884077, whose comment gets a note). No sample
#      rides ba4ec628 (checked), so nothing is re-pointed.
#   4  K.L07 sample 81223d65 (ES2503947-001): datetime NULL -> 2025-02-11 04:00:00 UTC,
#      the ESdat Sampled_Date_Time "11 Feb 2025 15:00" in Sydney (AEDT, UTC+11), stored
#      naive UTC as 066 stored the Main Dam times. `date` (2025-02-11) is unchanged. Its
#      20 analyses are deleted and re-inserted unchanged so the indexed datetime can
#      change (029/066 pattern).
#
# Counts (plan): features 2 updates (8 fields); aliases 2 updates (3 fields), 1 insert;
# sample 1 update; analyses 20 deletes, 20 re-inserts. Net: feature_alias +1, nothing
# else changes in size.
#
# ---- LIVE HAS MOVED ON --------------------------------------------------------
# Every group (`gid`) is checked against the target DB first: every row it updates,
# deletes or re-inserts still byte-for-byte as frozen (sha1 of the row); the new alias
# uuid free; no ux_sample_identity collision; the sample holds only the planned
# analyses; the split alias still carries no sample. A failing group is SKIPPED whole
# and listed in 068-...-SKIPPED.csv.
#
# ---- COMMITS (duckdb 1.4: FK checks do not see deletes made earlier in the same
# transaction; a sample's indexed columns cannot change while analyses reference it:
# 029, 032, 065, 066, 067) -----------------------------------------------------------
#   A. feature updates; feature_alias updates and insert; analysis deletes  (commit)
#   B. sample datetime update                                               (commit)
#   C. analysis re-inserts; marker; verify; counts; checksums               (commit)
# A re-run after a failure resumes at the first unfinished commit (read from
# change_log against the plan recorded in the SKIPPED CSV); any other state refuses.
#
# Backups: verified whole-file snapshot, plus BACKUP CSVs of every analysis, sample,
# feature and feature_alias row the plan touches. Idempotent: marker present ->
# re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env(); sys.source("dev/migrations/068-coordinates-and-alias-split.R", envir = env)
#   env$mig068_run(db = <db>, snapshot_dir = <dir>, dry_run = TRUE)

.mig068_marker_version <- 1068L
.mig068_requires <- 1067L
.mig068_name <- "068-coordinates-and-alias-split"
.mig068_actor <- .mig068_name
.mig068_n <- list(feature = 2L, alias = 3L, sample = 1L, change = 20L, insert = 20L)
.mig068_reason <- "068 (Robin's rulings 2026-10-21: K.L07/B.L06 coordinates, B.S05 diversion-pipe alias split, K.L07 sample time)"

.mig068_fail <- function(msg) cli::cli_abort(paste0(.mig068_name, ": ", msg), class = "sampletidy_error")
.mig068_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)[[1]][[1]])
.mig068_inlist <- function(x) if (!length(x)) "('')" else paste0("(", paste0("'", gsub("'", "''", unique(x)), "'", collapse = ","), ")")
.mig068_na <- function(x) { x <- as.character(x); x[!is.na(x) & !nzchar(x)] <- NA_character_; x }
.mig068_chr <- function(x) if (is.na(x) || !nzchar(x)) NA_character_ else x
.mig068_num <- function(x) if (is.na(x) || !nzchar(x)) NA_real_ else as.numeric(x)   # decimal or C99 hex ("%a")
.mig068_lgl <- function(x) if (is.na(x) || !nzchar(x)) NA else as.logical(x)
.mig068_date <- function(x) if (is.na(x) || !nzchar(x)) as.Date(NA) else as.Date(x)
.mig068_ts <- function(x) if (is.na(x) || !nzchar(x)) as.POSIXct(NA, tz = "UTC") else as.POSIXct(x, tz = "UTC")
.mig068_split <- function(s) if (is.na(s) || !nzchar(s)) character() else strsplit(s, ";", fixed = TRUE)[[1]]

# ---- inputs ------------------------------------------------------------------------

.mig068_read_inputs <- function(input_dir = "dev/migrations") {
  rd <- function(suffix) {
    p <- file.path(input_dir, sprintf("%s-INPUT-%s.csv", .mig068_name, suffix))
    if (!file.exists(p)) .mig068_fail(sprintf("input %s not found.", p))
    utils::read.csv(p, colClasses = "character", na.strings = "", encoding = "UTF-8")
  }
  x <- list(feature = rd("feature"), alias = rd("alias"), sample = rd("sample"),
            change = rd("analysis-change"), insert = rd("analysis-insert"))
  got <- vapply(x, nrow, 1L)
  if (!identical(unname(got), unname(unlist(.mig068_n[names(x)]))))
    .mig068_fail(sprintf("INPUT row counts are %s, not as planned.", paste(names(got), got, sep = "=", collapse = " ")))
  if (anyDuplicated(x$feature$uuid) || anyDuplicated(x$alias$uuid) || anyDuplicated(x$sample$uuid) ||
      anyDuplicated(x$change$uuid) || anyDuplicated(x$insert$uuid))
    .mig068_fail("an INPUT CSV repeats a key.")
  if (anyDuplicated(paste(x$insert$uuid_sample, x$insert$uuid_lab)))
    .mig068_fail("INPUT-analysis-insert repeats a (sample, lab_method) pair.")
  if (!all(x$feature$op == "update") || !all(x$alias$op %in% c("update", "insert")) || !all(x$sample$op == "update") ||
      !all(x$change$op == "delete") || !all(x$change$note %in% "reinsert") || !all(x$insert$origin == "reinsert"))
    .mig068_fail("an INPUT CSV has an unknown op/origin.")
  if (!setequal(x$insert$uuid, x$change$uuid)) .mig068_fail("re-inserts do not match the deletes.")
  if (!all(x$feature$set == "lon;lat;geom_wkt;comments") || !all(x$sample$set == "datetime"))
    .mig068_fail("a feature or sample update sets columns other than planned.")
  if (anyNA(unlist(lapply(x, function(d) d$gid)))) .mig068_fail("every INPUT row needs a gid.")
  x
}

# sha1 of each row as text (the frozen value in the INPUT CSVs comes from this same
# function, so a row that changed in any column no longer matches).
.mig068_row_sha <- function(con, tbl, ids) {
  out <- stats::setNames(rep(NA_character_, length(ids)), ids)
  if (!length(ids)) return(out)
  df <- DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s', tbl, .mig068_inlist(ids)))
  for (i in seq_len(nrow(df))) {
    cols <- names(df)
    v <- vapply(cols, function(f) { s <- .st_changelog_str(df[[f]][i]); if (is.na(s)) "<NA>" else s }, "")
    out[[df$uuid[[i]]]] <- digest::digest(paste(cols, v, sep = "=", collapse = "\u001f"), algo = "sha1", serialize = FALSE)
  }
  out
}

# ---- plan: which groups still hold on this DB ---------------------------------------

.mig068_gid_problems <- function(con, x) {
  P <- list()
  add <- function(g, msg) if (length(g)) P[[length(P) + 1L]] <<- data.frame(gid = g, problem = msg, stringsAsFactors = FALSE)
  chk_sha <- function(df, tbl, what) {
    if (!nrow(df)) return(invisible())
    sha <- .mig068_row_sha(con, tbl, df$uuid)
    bad <- is.na(sha[df$uuid]) | sha[df$uuid] != df$row_sha1
    add(df$gid[bad], sprintf("%s %s is not as frozen", what, df$uuid[bad]))
  }
  chk_sha(x$feature, "feature", "feature")
  al <- x$alias
  chk_sha(al[al$op == "update", , drop = FALSE], "feature_alias", "alias")
  ia <- al[al$op == "insert", , drop = FALSE]
  taken <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature_alias WHERE uuid IN %s", .mig068_inlist(ia$uuid)))$uuid
  add(ia$gid[ia$uuid %in% taken], sprintf("alias uuid %s is already taken", ia$uuid[ia$uuid %in% taken]))
  have_f <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM feature WHERE uuid IN %s", .mig068_inlist(ia$uuid_feature)))$uuid
  add(ia$gid[!(ia$uuid_feature %in% have_f)], sprintf("alias %s target feature is gone", ia$uuid[!(ia$uuid_feature %in% have_f)]))
  # a date-bounded arm that is split must still carry no sample (none to re-point)
  ends <- al$uuid[al$op == "update" & grepl("date_end", al$set)]
  on <- DBI::dbGetQuery(con, sprintf("SELECT DISTINCT uuid_feature_alias AS u FROM sample WHERE uuid_feature_alias IN %s", .mig068_inlist(ends)))$u
  add(al$gid[al$uuid %in% on], sprintf("alias %s now carries a sample", al$uuid[al$uuid %in% on]))

  sc <- x$sample
  chk_sha(sc, "sample", "sample")
  on <- DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig068_inlist(sc$uuid)))
  extra <- unique(on$uuid_sample[!(on$uuid %in% x$change$uuid)])
  add(sc$gid[sc$uuid %in% extra], sprintf("sample %s holds an analysis outside the plan", sc$uuid[sc$uuid %in% extra]))
  for (i in seq_len(nrow(sc))) {
    n <- .mig068_scalar(con, "SELECT COUNT(*) FROM sample t JOIN sample s ON s.uuid = ? WHERE t.uuid_feature_alias = s.uuid_feature_alias
                              AND t.datetime = ? AND t.uuid_project IS NOT DISTINCT FROM s.uuid_project AND t.uuid <> s.uuid",
                        sc$uuid[[i]], .mig068_ts(sc$datetime[[i]]))
    if (n > 0L) add(sc$gid[[i]], sprintf("giving sample %s its datetime would collide on ux_sample_identity", sc$uuid[[i]]))
  }
  ch <- x$change
  chk_sha(ch, "analysis", "analysis")
  ins <- x$insert
  lm <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM lab_method WHERE uuid IN %s", .mig068_inlist(ins$uuid_lab)))$uuid
  add(ins$gid[!(ins$uuid_lab %in% lm)], sprintf("insert lab_method %s is gone", ins$uuid_lab[!(ins$uuid_lab %in% lm)]))

  if (!length(P)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  P <- do.call(rbind, P)
  P[!duplicated(P), , drop = FALSE]
}

.mig068_restrict <- function(x, skipped) {
  sk <- unique(skipped$gid)
  for (n in names(x)) x[[n]] <- x[[n]][!(x[[n]]$gid %in% sk), , drop = FALSE]
  x$skipped <- skipped
  x
}

.mig068_skipped_rows <- function(skipped) {
  if (!nrow(skipped)) return(data.frame(gid = character(), problem = character(), stringsAsFactors = FALSE))
  stats::aggregate(problem ~ gid, data = skipped, FUN = function(p) paste(unique(p), collapse = "; "))
}

# ---- phases ----------------------------------------------------------------------

# Expected change_log rows per commit (tbl|action -> n). No tbl|action pair is
# written by two commits, so each commit's counts are separable.
.mig068_expected <- function(p) {
  nset <- function(s) sum(vapply(s, function(z) length(.mig068_split(z)), 0L))
  al <- p$alias
  A <- c("feature|update" = nset(p$feature$set),
         "feature_alias|update" = nset(al$set[al$op == "update"]),
         "feature_alias|insert" = sum(al$op == "insert"),
         "analysis|delete" = nrow(p$change))
  B <- c("sample|update" = nset(p$sample$set))
  C <- c("analysis|insert" = nrow(p$insert))
  list(A = A, B = B, C = C)
}

.mig068_logged <- function(con) {
  L <- DBI::dbGetQuery(con, "SELECT tbl, action, count(*) AS n FROM change_log WHERE actor = ? GROUP BY ALL",
                       params = list(.mig068_actor))
  stats::setNames(as.integer(L$n), paste(L$tbl, L$action, sep = "|"))
}

# "A" nothing done; "B" commit A done; "C" A and B done. NULL = inconsistent.
.mig068_phase <- function(con, p) {
  L <- .mig068_logged(con)
  if (!length(L)) return("A")
  E <- .mig068_expected(p)
  got <- function(keys) { v <- L[keys]; v[is.na(v)] <- 0L; stats::setNames(as.integer(v), keys) }
  same <- function(e) identical(got(names(e)), stats::setNames(as.integer(e), names(e)))
  zero <- function(e) all(got(names(e)) == 0L)
  if (any(!(names(L) %in% unique(c(names(E$A), names(E$B), names(E$C)))))) return(NULL)
  if (same(E$A) && zero(E$B) && zero(E$C)) return("B")
  if (same(E$A) && same(E$B) && zero(E$C)) return("C")
  NULL
}

# ---- apply -----------------------------------------------------------------------

.mig068_counts <- function(con) {
  tabs <- c("analysis", "sample", "feature", "feature_mask", "feature_alias", "sample_lab_id", "lab_method", "project",
            "asset", "ingest_file", "review_queue", "change_log", "schema_version")
  out <- stats::setNames(lapply(tabs, function(t) .mig068_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
  out$review_open <- .mig068_scalar(con, "SELECT COUNT(*) FROM review_queue WHERE status = 'open'")
  out
}

.mig068_checksum <- function(con, p) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("analysis", "sample", "feature", "feature_alias", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig068_inlist(p$change$uuid)))
  out$sample_rest <- q(sprintf("SELECT * FROM sample WHERE uuid NOT IN %s ORDER BY uuid", .mig068_inlist(p$sample$uuid)))
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", .mig068_inlist(p$feature$uuid)))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", .mig068_inlist(p$alias$uuid)))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY uuid", .mig068_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig068_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig068_why <- function(df, i) sprintf("%s [ruling %s; group %s]: %s", .mig068_reason, df$item[[i]], df$gid[[i]], df$reason[[i]])

.mig068_value <- function(f, v) {
  switch(f, auto_assign = .mig068_lgl(v), date_start = , date_end = .mig068_date(v),
         lon = , lat = .mig068_num(v), datetime = .mig068_ts(v), .mig068_chr(v))
}

.mig068_apply <- function(con, p, phase, recorded_at, logf) {
  sums_before <- .mig068_checksum(con, p)
  want <- .mig068_counts(con)
  ft <- p$feature; al <- p$alias; sc <- p$sample; ch <- p$change
  if (phase == "A") {
    want$analysis <- want$analysis - nrow(ch)
    want$feature_alias <- want$feature_alias + sum(al$op == "insert")
  }
  want$analysis <- want$analysis + nrow(p$insert)
  want$schema_version <- want$schema_version + 1L
  E <- .mig068_expected(p)
  want$change_log <- want$change_log + sum(unlist(E)) - .mig068_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig068_actor)

  if (phase == "A") {
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(ft))) {
        fs <- .mig068_split(ft$set[[i]])
        db_update(con, "feature", uuid = ft$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) .mig068_value(f, ft[[f]][[i]])), fs),
                  actor = .mig068_actor, reason = .mig068_why(ft, i))
      }
      up <- al[al$op == "update", , drop = FALSE]
      for (i in seq_len(nrow(up))) {
        fs <- .mig068_split(up$set[[i]])
        db_update(con, "feature_alias", uuid = up$uuid[[i]], changes = stats::setNames(lapply(fs, function(f) .mig068_value(f, up[[f]][[i]])), fs),
                  actor = .mig068_actor, reason = .mig068_why(up, i))
      }
      ia <- al[al$op == "insert", , drop = FALSE]
      for (i in seq_len(nrow(ia))) {
        # a continuation arm: n_seen 0 and no first/last_seen, as 058's ebc3f982
        row <- tibble::tibble(uuid = ia$uuid[[i]], uuid_feature = ia$uuid_feature[[i]], name = ia$name[[i]],
                              alias_key = ia$alias_key[[i]], kind = ia$kind[[i]], n_seen = 0L,
                              auto_assign = .mig068_lgl(ia$auto_assign[[i]]), first_seen = as.POSIXct(NA), last_seen = as.POSIXct(NA),
                              confirmed_by = .mig068_chr(ia$confirmed_by[[i]]), comments = .mig068_chr(ia$comments[[i]]),
                              date_start = .mig068_date(ia$date_start[[i]]), date_end = .mig068_date(ia$date_end[[i]]))
        db_append(con, "feature_alias", row, actor = .mig068_actor, reason = .mig068_why(ia, i))
      }
      if (nrow(ch)) {
        n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig068_inlist(ch$uuid)))
        if (n != nrow(ch)) .mig068_fail(sprintf("set-based delete on analysis removed %d rows, not %d.", n, nrow(ch)))
        at <- Sys.time()
        for (i in seq_len(nrow(ch)))
          .st_write_change_log(con, at = at, actor = .mig068_actor, action = "delete", tbl = "analysis",
                               uuid_row = ch$uuid[[i]], field = NA_character_, old = ch$uuid[[i]], new = NA_character_,
                               reason = .mig068_why(ch, i), source_hash = NA_character_)
      }
      NULL
    })
    logf("A: %d feature updates; %d alias updates, %d alias inserts; %d analyses deleted to re-insert (committed).",
         nrow(ft), sum(al$op == "update"), sum(al$op == "insert"), nrow(ch))
    phase <- "B"
  }
  if (phase == "B") {
    db_transaction(con, function(con) {
      for (i in seq_len(nrow(sc)))
        db_update(con, "sample", uuid = sc$uuid[[i]], changes = list(datetime = .mig068_ts(sc$datetime[[i]])),
                  actor = .mig068_actor, reason = .mig068_why(sc, i))
      NULL
    })
    logf("B: %d sample datetime updates (committed).", nrow(sc))
    phase <- "C"
  }
  db_transaction(con, function(con) {
    ins <- p$insert
    for (i in seq_len(nrow(ins))) {
      row <- tibble::tibble(uuid = ins$uuid[[i]], uuid_sample = ins$uuid_sample[[i]], uuid_lab = ins$uuid_lab[[i]],
                            value = .mig068_num(ins$value[[i]]), value_chr = .mig068_chr(ins$value_chr[[i]]),
                            quantified = .mig068_lgl(ins$quantified[[i]]), rl_low = .mig068_num(ins$rl_low[[i]]),
                            rl_high = .mig068_num(ins$rl_high[[i]]), purpose = .mig068_chr(ins$purpose[[i]]),
                            comments = .mig068_chr(ins$comments[[i]]))
      db_append(con, "analysis", row, actor = .mig068_actor, reason = .mig068_why(ins, i))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig068_marker_version, recorded_at))
    .mig068_verify(con, p)
    got <- .mig068_counts(con)
    if (!identical(got, want))
      .mig068_fail(sprintf("counts are not as planned: %s", paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig068_checksum(con, p))) .mig068_fail("something outside the planned rows moved.")
    NULL
  })
  logf("C: %d analyses re-inserted, marker %d (committed).", nrow(p$insert), .mig068_marker_version)
  invisible(TRUE)
}

# ---- verify ----------------------------------------------------------------------

.mig068_done_problem <- function(con, p) {
  if (.mig068_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig068_marker_version) != 1L)
    return("marker 1068 missing")
  eqn <- function(x, y) (is.na(x) & is.na(y)) | (!is.na(x) & !is.na(y) & abs(x - y) <= 1e-9 * pmax(1, abs(y)))
  eqc <- function(x, y) mapply(identical, .mig068_na(x), .mig068_na(y))
  num <- function(v) vapply(v, .mig068_num, 0)
  # analyses re-inserted exactly as frozen
  ins <- p$insert
  A <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s", .mig068_inlist(ins$uuid)))
  a <- A[match(ins$uuid, A$uuid), , drop = FALSE]
  if (anyNA(a$uuid)) return(sprintf("%d planned analysis re-inserts are missing", sum(is.na(a$uuid))))
  ok <- a$uuid_sample == ins$uuid_sample & a$uuid_lab == ins$uuid_lab &
    eqn(a$value, num(ins$value)) & eqn(a$rl_low, num(ins$rl_low)) & eqn(a$rl_high, num(ins$rl_high)) &
    eqc(a$value_chr, ins$value_chr) & eqc(as.character(a$quantified), toupper(ins$quantified)) &
    eqc(a$comments, ins$comments) & eqc(a$purpose, ins$purpose)
  if (!all(ok)) return(sprintf("analysis re-insert %s is not as planned", ins$uuid[!ok][[1]]))
  if (nrow(ins) && !identical(sort(.mig068_row_sha(con, "analysis", ins$uuid)[ins$uuid]),
                              sort(stats::setNames(p$change$row_sha1, p$change$uuid)[ins$uuid])))
    return("a re-inserted analysis differs from the row deleted")
  # features
  ft <- p$feature
  Fe <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE uuid IN %s", .mig068_inlist(ft$uuid)))
  for (i in seq_len(nrow(ft))) {
    r <- Fe[Fe$uuid == ft$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("feature %s is missing", ft$uuid[[i]]))
    if (!eqn(r$lon, .mig068_num(ft$lon[[i]])) || !eqn(r$lat, .mig068_num(ft$lat[[i]]))) return(sprintf("feature %s lon/lat not as planned", ft$uuid[[i]]))
    for (f in c("geom_wkt", "comments")) if (!identical(.mig068_na(r[[f]]), .mig068_na(ft[[f]][[i]])))
      return(sprintf("feature %s %s is not as planned", ft$uuid[[i]], f))
  }
  # sample
  sc <- p$sample
  S <- DBI::dbGetQuery(con, sprintf("SELECT uuid, datetime FROM sample WHERE uuid IN %s", .mig068_inlist(sc$uuid)))
  for (i in seq_len(nrow(sc))) {
    s <- S[S$uuid == sc$uuid[[i]], , drop = FALSE]
    if (nrow(s) != 1L || !identical(.st_changelog_str(s$datetime), .st_changelog_str(.mig068_ts(sc$datetime[[i]]))))
      return(sprintf("sample %s datetime is not %s", sc$uuid[[i]], sc$datetime[[i]]))
  }
  # aliases
  al <- p$alias
  FA <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s", .mig068_inlist(al$uuid)))
  for (i in seq_len(nrow(al))) {
    r <- FA[FA$uuid == al$uuid[[i]], , drop = FALSE]
    if (nrow(r) != 1L) return(sprintf("alias %s is missing", al$uuid[[i]]))
    fs <- if (al$op[[i]] == "insert") c("uuid_feature", "name", "alias_key", "kind", "auto_assign", "confirmed_by", "comments", "date_start", "date_end")
          else .mig068_split(al$set[[i]])
    for (f in fs) if (!identical(toupper(.mig068_na(.st_changelog_str(r[[f]]))), toupper(.mig068_na(al[[f]][[i]]))))
      return(sprintf("alias %s %s is not %s", al$uuid[[i]], f, al[[f]][[i]]))
  }
  # change_log
  E <- unlist(unname(.mig068_expected(p)))
  E <- E[E > 0L]
  L <- .mig068_logged(con)
  if (!setequal(names(L), names(E)) || !identical(as.integer(L[names(E)]), as.integer(E)))
    return(sprintf("068 change_log rows are %s, expected %s", paste(names(L), L, sep = "=", collapse = " "),
                   paste(names(E), E, sep = "=", collapse = " ")))
  NULL
}

.mig068_verify <- function(con, p) {
  pr <- .mig068_done_problem(con, p)
  if (!is.null(pr)) cli::cli_abort(paste0("068 verify failed: ", pr), class = "sampletidy_error")
  invisible(TRUE)
}

# ---- backups, files ----------------------------------------------------------------

mig068_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig068_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig068_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig068_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig068_write_csv <- function(df, path, key) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || (nrow(df) && !identical(back[[key]], as.character(out[[key]]))))
    cli::cli_abort("068: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig068_csv <- function(csv_dir, what) file.path(csv_dir, sprintf("%s-%s.csv", .mig068_name, what))

.mig068_write_backups <- function(con, p, csv_dir) {
  g <- function(tbl, ids) DBI::dbGetQuery(con, sprintf('SELECT * FROM "%s" WHERE uuid IN %s ORDER BY uuid', tbl, .mig068_inlist(ids)))
  .mig068_write_csv(g("analysis", p$change$uuid), .mig068_csv(csv_dir, "BACKUP-analysis"), "uuid")
  .mig068_write_csv(g("sample", p$sample$uuid), .mig068_csv(csv_dir, "BACKUP-sample"), "uuid")
  .mig068_write_csv(g("feature", p$feature$uuid), .mig068_csv(csv_dir, "BACKUP-feature"), "uuid")
  .mig068_write_csv(g("feature_alias", p$alias$uuid[p$alias$op != "insert"]), .mig068_csv(csv_dir, "BACKUP-feature_alias"), "uuid")
}

.mig068_read_skipped <- function(csv_dir) {
  f <- .mig068_csv(csv_dir, "SKIPPED")
  if (!file.exists(f)) return(NULL)
  s <- utils::read.csv(f, colClasses = "character", na.strings = "", encoding = "UTF-8")
  data.frame(gid = s$gid, problem = s$problem, stringsAsFactors = FALSE)
}

# ---- run -------------------------------------------------------------------------

mig068_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL, input_dir = "dev/migrations") {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir
  x_all <- .mig068_read_inputs(input_dir)

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                                   params = list(.mig068_marker_version)),
                   finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    sk <- .mig068_read_skipped(csv_dir)
    if (is.null(sk)) .mig068_fail(sprintf("marker present but %s is missing: cannot re-verify.", .mig068_csv(csv_dir, "SKIPPED")))
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig068_verify(check_con, .mig068_restrict(x_all, sk)), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("068 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    for (m in .mig068_requires)
      if (.mig068_scalar(pre_con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", m) == 0L)
        .mig068_fail(sprintf("marker %d is required first.", m))
    started <- .mig068_scalar(pre_con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig068_actor) > 0L
    if (!started) {
      sk <- .mig068_gid_problems(pre_con, x_all)
    } else {
      sk <- .mig068_read_skipped(csv_dir)
      if (is.null(sk)) .mig068_fail("a previous attempt wrote change_log rows but its SKIPPED CSV is missing; refusing.")
    }
    p <- .mig068_restrict(x_all, sk)
    ph <- .mig068_phase(pre_con, p)
    if (is.null(ph)) .mig068_fail("the database is part-way through 068 in a state no phase explains; refusing.")
    list(p = p, phase = ph, started = started)
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- pre$p
  n_sk <- length(unique(p$skipped$gid))
  all_gids <- unique(unlist(lapply(x_all, function(d) d$gid)))
  logf("Plan (step %s): %d groups, %d skipped. Features: %d updates; aliases: %d updates, %d inserts; samples: %d datetime updates; analyses: %d deleted and re-inserted.",
       pre$phase, length(all_gids), n_sk, nrow(p$feature), sum(p$alias$op == "update"), sum(p$alias$op == "insert"),
       nrow(p$sample), nrow(p$insert))
  if (n_sk) for (i in seq_len(nrow(p$skipped))) logf("SKIP %s: %s", p$skipped$gid[[i]], p$skipped$problem[[i]])
  if (isTRUE(dry_run)) {
    logf("DRY RUN: no backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p)))
  }

  if (!pre$started) {
    bk_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig068_write_backups(bk_con, p, csv_dir), finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
    .mig068_write_csv(.mig068_skipped_rows(p$skipped), .mig068_csv(csv_dir, "SKIPPED"), "gid")
    logf("Row backups and the SKIPPED plan written to %s", csv_dir)
  } else {
    logf("Resuming at step %s: the row backups and SKIPPED plan from the first attempt are kept.", pre$phase)
  }
  backup_path <- mig068_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    if (!pre$started) {
      sk2 <- .mig068_gid_problems(con, x_all)
      if (!setequal(unique(sk2$gid), unique(p$skipped$gid)))
        .mig068_fail("the database changed between the plan and the write lock; re-run.")
    }
    ph <- .mig068_phase(con, p)
    if (!identical(ph, pre$phase)) .mig068_fail("the phase changed between the plan and the write lock; re-run.")
    .mig068_apply(con, p, ph, recorded_at, logf)
  }, db = db)

  logf("%s migrated successfully (marker %d).", .mig068_name, .mig068_marker_version)
  invisible(list(status = "migrated", backup_path = backup_path, restore_command = restore_command,
                 recorded_at = recorded_at, skipped = p$skipped))
}
