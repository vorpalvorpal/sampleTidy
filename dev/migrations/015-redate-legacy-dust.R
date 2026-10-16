# Operator-run migration: repair the 2024 legacy dust dates, date the two
# undated July-2024 samples, move July's observation text onto them, and close
# the 2400-7399-08 dust review items that the mis-dating produced.
#
# Robin's ruling (2026-10-16), applied to the adapter at 7986ee3: for an ACIRL
# dust gauge, EXPOSURE date (gauge put out) is `sample.date_start` and
# COLLECTION date (gauge brought in) is `sample.date`. Robin chose to REPAIR the
# legacy dates rather than loosen sample matching, and authorised this
# migration for live (2026-10-16).
#
# HOW THE TARGETS WERE CHOSEN (scratchpad/2026-10-16-mig015/, map2.R + map3.R).
# All 102 legacy dust samples (B.D07 51, B.D08 51; no other dust gauge exists,
# Katoomba included) were paired with the gauge-blocks of the 58 dust workbooks,
# parsed by the CURRENT adapter so the new dates agree with it by construction.
# A pair needs the same gauge, identical dust-total and dust-combustible (and
# incombustible, or 013's `< total` re-mark), and an exposure month within two
# months of the legacy date. Result:
#   correct already 42 | re-date 9 | no source workbook 45 | A77 4 | NULL date 2
# The 5 re-dates of the 2021-22 era are B.D07's one-month shift and belong to
# 016 (drafted, NOT applied). This migration does four things in one
# transaction (plus the review closes, which go through resolve_review()):
#
# (1) RE-DATE 4 "+1 day" collections (reports 2400-7399-05-01 / 2400-7399-07):
#   B.D07 Apr-2024 exposure  collected 2024-05-02 -> 2024-05-01
#   B.D08 Apr-2024 exposure  collected 2024-05-02 -> 2024-05-01
#   B.D07 Jun-2024 exposure  collected 2024-07-02 -> 2024-07-01
#   B.D08 Jun-2024 exposure  collected 2024-07-02 -> 2024-07-01
#   `date_start` is already the exposure date on all 4 and is not touched.
#
# (2) DATE the 2 legacy samples that were loaded with every date NULL. Their
#   values are exactly report 2400-7399-08's July-2024 gauge-blocks:
#   96c5e696 B.D07 total 0.97 / comb 0.37 / incomb 0.60
#   e732697d B.D08 total 1.09 / comb 0.39 / incomb 0.70
#   -> date_start 2024-07-01, date 2024-08-01 (Sydney).
#   PROJECT: 2400-7399-08 is NOT attached. No legacy dust sample links to an
#   ACIRL report project: every one (all 102) links to an UNNAMED child of the
#   root project "Dust monitoring" (230bd429), one child per legacy load
#   period, whose date_start/date_end span the exposure->collection period
#   (naive midnight). The June samples link to fc3e626f (2024-06-01 ->
#   2024-07-02), not to 2400-7399-07. The two July samples already follow that
#   pattern - each has its own undated child (3cffcb25, cab41c46) - so the
#   sample link stays; uuid_project is in 009's ux_sample_identity index anyway
#   (see below). What 015 does write is those children's PERIOD, so they read
#   like their neighbours, and the two step-(1) children's date_end, which
#   carried the same +1-day collection:
#     3cffcb25, cab41c46   NULL/NULL -> 2024-07-01 / 2024-08-01
#     c2a363c1 (Apr-2024)  date_end 2024-05-02 -> 2024-05-01
#     fc3e626f (Jun-2024)  date_end 2024-07-02 -> 2024-07-01
#   `datetime`/`datetime_start` of the July samples stay NULL (index reason).
#
# (3) MOVE July's observation text. The 2026-08-09 live ingest of 2400-7399-08
#   (asset source_hash 49c82f1dd30f44affe55d94ba57b625d) inserted exactly two
#   analyses onto legacy dust samples, both `Appearance` (lab_method
#   "ANALYSIS OBSERVATIONS" AS3580.10.1) and both on the JUNE samples, because
#   the July samples had no date to match:
#     d900a5d2  B.D07  d0106b6d (June) -> 96c5e696 (July)
#     c286845d  B.D08  a4866584 (June) -> e732697d (July)
#   `analysis.uuid_sample` is re-pointed in place with db_update (one change_log
#   update row each, carrying that source_hash). The analysis FK permits it:
#   uuid_sample is not in a unique index, so DuckDB does not run it as
#   delete+insert (measured). June's own legacy rows are not touched (June has
#   no legacy Appearance row; the dust values stay).
#
# (4) CLOSE the 6 open `value_conflict/measurement` review items from that
#   ingest (July's incoming dust values against June's existing ones), via the
#   existing resolve_review() API, resolved_by 'R. Shannon'. resolve_review()
#   opens its own write connection, so it runs AFTER the data transaction; it
#   is idempotent (an already-closed row returns FALSE) and the re-run path
#   closes any that a crash left open. The B.S22 `Comments` case-only conflict
#   named in the brief is NOT in review_queue (no open row; the queue holds
#   only these 6 plus two unrelated items), so nothing is done for it.
#
# REPRESENTATION. Every legacy dust row stores Sydney midnight as its UTC
# instant (13:00/14:00 UTC the previous day); the pipeline writes naive
# midnight. `.ct_sydney_day_sql()` reads the right calendar day from BOTH, so
# either would match. Each row KEEPS the legacy representation: a new `date`/
# `date_start` is Sydney midnight of the day as a UTC instant, DST-aware. That
# keeps the gauge's legacy series uniform (95% of all samples use it), and
# changing the convention is a separate ruling (see 009's header).
#
# `datetime`, `datetime_start` AND `uuid_project` ARE NEVER WRITTEN. `datetime`
# and `uuid_project` are columns of migration 009's ux_sample_identity index,
# and DuckDB 1.4 runs an UPDATE of an indexed column as delete+insert, which
# the analysis -> sample foreign key refuses ("still referenced by a foreign
# key") - measured in the rehearsal. Incoming dust rows carry no time, so
# sample identity never consults datetime.
#
# BACKUP OF THE ROWS: the 6 sample, 4 project and 2 analysis rows are dumped to
# `015-redate-legacy-dust-BACKUP-{sample,project,analysis}.csv` beside
# this file, in addition to the verified whole-file backup in `snapshot_dir`.
# change_log rows are written by db_update (actor `015-redate-legacy-dust`).
#
# Marker 1015. Independent of 001-014. Idempotent: marker present ->
# re-verify, close any still-open review item, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/015-redate-legacy-dust.R", envir = env)
#   env$mig015_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig015_marker_version <- 1015L
.mig015_actor <- "015-redate-legacy-dust"
.mig015_lab_total <- "83282ca2-596d-43f5-ac3e-4d01412c167b"  # INSOLUBLE SOLIDS = dust-total
.mig015_lab_obs <- "fb774416-e0ef-4210-87e5-97ab8e045427"    # ANALYSIS OBSERVATIONS = Appearance
.mig015_hash_08 <- "49c82f1dd30f44affe55d94ba57b625d"        # 2400-7399-08 workbook asset
.mig015_expected_legacy_n <- 102L
.mig015_resolved_by <- "R. Shannon"
.mig015_resolution <- "already present: July 2024 exists as legacy samples 96c5e696/e732697d, dated by 015"

# (1) and (2): one row per sample whose dates are written. NA = not written /
# expected NULL. Days are Australia/Sydney calendar days. `total` is the
# dust-total value: an identity check that the uuid still holds the mapped
# gauge-block.
.mig015_targets <- data.frame(
  uuid = c("fbef07d2-e29d-483b-9935-ac159bbebf71", "b48f1f1c-2083-440e-ab20-e77434f10faa",
           "d0106b6d-6815-4091-8254-743e489e1b25", "a4866584-4c11-436a-8915-87f6fc81f98f",
           "96c5e696-ef9f-4973-9e31-f859118e3f70", "e732697d-1943-4c6c-a3f2-61683ccd5289"),
  step = c(1L, 1L, 1L, 1L, 2L, 2L),
  gauge = c("B.D07", "B.D08", "B.D07", "B.D08", "B.D07", "B.D08"),
  old_start = c("2024-04-01", "2024-04-01", "2024-06-01", "2024-06-01", NA, NA),
  new_start = c("2024-04-01", "2024-04-01", "2024-06-01", "2024-06-01", "2024-07-01", "2024-07-01"),
  old_date = c("2024-05-02", "2024-05-02", "2024-07-02", "2024-07-02", NA, NA),
  new_date = c("2024-05-01", "2024-05-01", "2024-07-01", "2024-07-01", "2024-08-01", "2024-08-01"),
  total = c(0.50, 1.27, 1.53, 0.57, 0.97, 1.09),
  source = c("2400-7399-05-01", "2400-7399-05-01", "2400-7399-07", "2400-7399-07", "2400-7399-08", "2400-7399-08"),
  stringsAsFactors = FALSE
)

# The dust-period projects whose dates are written (naive midnight, as stored).
.mig015_projects <- data.frame(
  uuid = c("3cffcb25-3247-4a95-8452-79911f0a9abf", "cab41c46-494f-4545-9154-b40615eeb285",
           "c2a363c1-2895-4f2f-86cc-ce20d8de91c2", "fc3e626f-0ff9-4060-b814-1ab34814dc9c"),
  sample = c("96c5e696-ef9f-4973-9e31-f859118e3f70", "e732697d-1943-4c6c-a3f2-61683ccd5289",
             "fbef07d2-e29d-483b-9935-ac159bbebf71", "d0106b6d-6815-4091-8254-743e489e1b25"),
  old_start = c(NA, NA, "2024-04-01", "2024-06-01"),
  new_start = c("2024-07-01", "2024-07-01", "2024-04-01", "2024-06-01"),
  old_end = c(NA, NA, "2024-05-02", "2024-07-02"),
  new_end = c("2024-08-01", "2024-08-01", "2024-05-01", "2024-07-01"),
  stringsAsFactors = FALSE
)
.mig015_naive <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "UTC")

# (3) the two observation analyses to re-point.
.mig015_moves <- data.frame(
  uuid = c("d900a5d2-18b7-40ca-af6d-f076474023c3", "c286845d-fed2-45cd-8dc2-8b3ac0cfacf4"),
  gauge = c("B.D07", "B.D08"),
  from = c("d0106b6d-6815-4091-8254-743e489e1b25", "a4866584-4c11-436a-8915-87f6fc81f98f"),
  to = c("96c5e696-ef9f-4973-9e31-f859118e3f70", "e732697d-1943-4c6c-a3f2-61683ccd5289"),
  value_chr = c("Clear,insects, organic matter , fine brown dusts, coarse brown dust.",
                "Clear,organic matter, fine brown dusts, coarse black dust."),
  stringsAsFactors = FALSE
)

# (4) the 6 review items: existing = June's analysis the July value hit.
.mig015_reviews <- data.frame(
  uuid = c("93714c81-b1cc-4a66-a642-b73a962b235a", "e556d535-5f39-4c0a-9635-4e5ec28d5699",
           "83efcc0d-c03f-449c-b56c-9604bead4221", "55fc1184-04d2-4faa-b91e-c6fec988889a",
           "4f71c750-91b7-4b6c-b717-394b34f307d1", "3207d80e-4bcc-4bcf-944a-21eef82872bc"),
  existing = c("b047d635-fdb7-4263-84bf-60a1b4cf8763", "1a30832d-ebaf-48cb-b246-2d191a59b89e",
               "8d442c4b-c186-4569-b842-cd80eddce854", "0ffacb67-108f-4547-a45a-a0d51960dfe1",
               "39f54414-8597-42fa-899c-c92b75d7e234", "59eafc32-b452-4f2f-8b3e-1c56ad0988f4"),
  july = c(rep("96c5e696-ef9f-4973-9e31-f859118e3f70", 3), rep("e732697d-1943-4c6c-a3f2-61683ccd5289", 3)),
  incoming = c(0.97, 0.37, 0.60, 1.09, 0.39, 0.70),
  stringsAsFactors = FALSE
)

.mig015_default <- function(x, default) if (is.null(x)) default else x
.mig015_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig015_sydney_midnight <- function(day) as.POSIXct(paste(day, "00:00:00"), tz = "Australia/Sydney")
.mig015_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig015_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig015_fail <- function(msg) cli::cli_abort(paste0("015-redate-legacy-dust: ", msg), class = "sampletidy_error")

.mig015_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, s.uuid_feature_alias, s.uuid_project,
           s.date, s.date_start, s.datetime, s.datetime_start,
           %s AS sd, %s AS sds,
           (SELECT a.value FROM analysis a WHERE a.uuid_sample = s.uuid AND a.uuid_lab = ?) AS total
    FROM \"sample\" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid IN (%s) ORDER BY s.uuid",
    .mig015_syd("s.date"), .mig015_syd("s.date_start"),
    .mig015_ids_sql(.mig015_targets$uuid)), params = list(.mig015_lab_total))
}

.mig015_move_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid, uuid_sample, uuid_lab, value, value_chr FROM analysis WHERE uuid IN (%s) ORDER BY uuid",
                               .mig015_ids_sql(.mig015_moves$uuid)))
}

.mig015_project_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT p.uuid, CAST(CAST(p.date_start AS DATE) AS VARCHAR) AS ds, CAST(CAST(p.date_end AS DATE) AS VARCHAR) AS de,
                                p.date_start, p.date_end, p.uuid_parent,
                                (SELECT COUNT(*) FROM \"sample\" s WHERE s.uuid_project = p.uuid) AS n_sample,
                                (SELECT MIN(s.uuid) FROM \"sample\" s WHERE s.uuid_project = p.uuid) AS a_sample
                                FROM project p WHERE p.uuid IN (%s) ORDER BY p.uuid", .mig015_ids_sql(.mig015_projects$uuid)))
}

.mig015_review_rows <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT uuid, kind, subkind, source_hash, status, resolution, resolved_by, uuid_existing, payload
                                FROM review_queue WHERE uuid IN (%s) ORDER BY uuid", .mig015_ids_sql(.mig015_reviews$uuid)))
}

.mig015_legacy_dust_n <- function(con) {
  .mig015_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig015_counts <- function(con) {
  list(
    analysis = .mig015_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig015_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig015_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig015_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Everything the data transaction must not touch, byte for byte.
.mig015_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  ids <- .mig015_ids_sql(.mig015_targets$uuid)
  mv <- .mig015_ids_sql(.mig015_moves$uuid)
  list(
    sample_other = q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", ids)),
    sample_target_rest = q(sprintf("SELECT uuid, uuid_feature_alias, uuid_project, datetime, datetime_start,
                                    organisation, person, purpose, comments
                                    FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
    analysis_other = q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN (%s) ORDER BY uuid", mv)),
    analysis_moved_rest = q(sprintf("SELECT uuid, uuid_lab, value, value_chr, quantified, rl_low, rl_high, purpose, comments
                                     FROM analysis WHERE uuid IN (%s) ORDER BY uuid", mv)),
    project_other = q(sprintf("SELECT * FROM project WHERE uuid NOT IN (%s) ORDER BY uuid", .mig015_ids_sql(.mig015_projects$uuid))),
    project_rest = q(sprintf("SELECT uuid, uuid_parent, uuid_root, uuid_project, name, type, purpose, regulated_by, cypher, site, value, comments
                              FROM project WHERE uuid IN (%s) ORDER BY uuid", .mig015_ids_sql(.mig015_projects$uuid))),
    review_queue = q("SELECT * FROM review_queue ORDER BY uuid")
  )
}

# Other samples on the target's feature on its NEW Sydney collection day (must be none).
.mig015_collisions <- function(con, rows) {
  out <- character()
  for (r in seq_len(nrow(rows))) {
    tg <- .mig015_targets[.mig015_targets$uuid == rows$uuid[[r]], ]
    n_day <- .mig015_scalar(con, sprintf("
      SELECT COUNT(*) FROM \"sample\" s
      JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      WHERE fa.uuid_feature = (SELECT fa2.uuid_feature FROM feature_alias fa2 WHERE fa2.uuid = ?)
        AND s.uuid <> ? AND %s = ?", .mig015_syd("s.date")),
      rows$uuid_feature_alias[[r]], rows$uuid[[r]], tg$new_date)
    if (n_day > 0) out <- c(out, sprintf("%s: %d other sample(s) on %s at %s", tg$gauge, n_day, tg$new_date, rows$uuid[[r]]))
  }
  out
}

.mig015_check_preconditions <- function(con) {
  fail <- .mig015_fail
  n_leg <- .mig015_legacy_dust_n(con)
  if (n_leg != .mig015_expected_legacy_n) {
    fail(sprintf("%d samples carry a dust analysis, expected %d - the dust set has changed since the mapping was measured.",
                 n_leg, .mig015_expected_legacy_n))
  }
  rows <- .mig015_rows(con)
  if (nrow(rows) != nrow(.mig015_targets)) fail(sprintf("%d of %d target samples found.", nrow(rows), nrow(.mig015_targets)))
  for (r in seq_len(nrow(rows))) {
    tg <- .mig015_targets[.mig015_targets$uuid == rows$uuid[[r]], ]
    if (!identical(rows$gauge[[r]], tg$gauge)) fail(sprintf("%s is on %s, expected %s.", tg$uuid, rows$gauge[[r]], tg$gauge))
    if (is.na(rows$total[[r]]) || abs(rows$total[[r]] - tg$total) > 1e-9) {
      fail(sprintf("%s dust-total is %s, expected %s - not the mapped gauge-block.", tg$uuid, format(rows$total[[r]]), format(tg$total)))
    }
    if (!identical(rows$sd[[r]], tg$old_date)) fail(sprintf("%s date is %s (Sydney), expected %s.", tg$uuid, rows$sd[[r]], tg$old_date))
    if (!identical(rows$sds[[r]], tg$old_start)) fail(sprintf("%s date_start is %s (Sydney), expected %s.", tg$uuid, rows$sds[[r]], tg$old_start))
    if (tg$step == 1L) {
      # The representation being preserved: Sydney midnight held as its UTC instant.
      if (as.numeric(rows$date[[r]]) != as.numeric(.mig015_sydney_midnight(tg$old_date))) {
        fail(sprintf("%s date %s is not Sydney midnight as a UTC instant (legacy representation).",
                     tg$uuid, format(rows$date[[r]], tz = "UTC")))
      }
    } else {
      if (!is.na(rows$datetime[[r]]) || !is.na(rows$datetime_start[[r]])) {
        fail(sprintf("%s was expected fully undated.", tg$uuid))
      }
    }
  }
  coll <- .mig015_collisions(con, rows)
  if (length(coll) > 0) fail(paste("re-dating would collide:", paste(coll, collapse = "; ")))
  pr <- .mig015_project_rows(con)
  if (nrow(pr) != nrow(.mig015_projects)) fail(sprintf("%d of %d dust-period projects found.", nrow(pr), nrow(.mig015_projects)))
  for (i in seq_len(nrow(.mig015_projects))) {
    e <- .mig015_projects[i, ]; row <- pr[pr$uuid == e$uuid, ]
    if (!identical(row$ds, e$old_start) || !identical(row$de, e$old_end) || row$uuid_parent != "230bd429-7ba5-4f95-b688-d01d47367723" ||
        (!is.na(e$old_end) && as.numeric(row$date_end) != as.numeric(.mig015_naive(e$old_end)))) {
      fail(sprintf("project %s period is %s..%s, expected %s..%s under 'Dust monitoring'.", e$uuid, row$ds, row$de, e$old_start, e$old_end))
    }
    links <- DBI::dbGetQuery(con, "SELECT uuid FROM \"sample\" WHERE uuid_project = ?", params = list(e$uuid))$uuid
    if (!(e$sample %in% links)) fail(sprintf("sample %s no longer links to project %s.", e$sample, e$uuid))
  }

  # (3) provenance: the 08 ingest put exactly these two analyses on dust samples.
  prov <- DBI::dbGetQuery(con, "
    SELECT c.uuid_row FROM change_log c
    JOIN analysis a ON a.uuid = c.uuid_row
    JOIN \"sample\" s ON s.uuid = a.uuid_sample
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE c.source_hash = ? AND c.tbl = 'analysis' AND c.action = 'insert' AND f.name IN ('B.D07', 'B.D08')
    ORDER BY 1", params = list(.mig015_hash_08))$uuid_row
  if (!identical(sort(prov), sort(.mig015_moves$uuid))) {
    fail(sprintf("2400-7399-08 inserted %s onto dust samples, expected exactly the 2 Appearance rows.", paste(prov, collapse = ", ")))
  }
  mv <- .mig015_move_rows(con)
  for (i in seq_len(nrow(.mig015_moves))) {
    m <- .mig015_moves[i, ]; row <- mv[mv$uuid == m$uuid, ]
    if (nrow(row) != 1L || row$uuid_sample != m$from || row$uuid_lab != .mig015_lab_obs || !identical(row$value_chr, m$value_chr)) {
      fail(sprintf("analysis %s is not the expected %s Appearance row on %s.", m$uuid, m$gauge, m$from))
    }
  }
  n_obs_july <- .mig015_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_lab = ? AND uuid_sample IN (%s)",
                                           .mig015_ids_sql(.mig015_moves$to)), .mig015_lab_obs)
  if (n_obs_july != 0L) fail(sprintf("the July samples already carry %d Appearance row(s).", n_obs_july))

  .mig015_check_reviews(con, allow_resolved = FALSE)
  invisible(rows)
}

# Each of the 6 is the expected July-vs-June value_conflict, and July's sample
# holds exactly the incoming value. Open, or (allow_resolved) closed by us.
.mig015_check_reviews <- function(con, allow_resolved) {
  fail <- .mig015_fail
  rv <- .mig015_review_rows(con)
  if (nrow(rv) != nrow(.mig015_reviews)) fail(sprintf("%d of %d review items found.", nrow(rv), nrow(.mig015_reviews)))
  for (i in seq_len(nrow(.mig015_reviews))) {
    e <- .mig015_reviews[i, ]; row <- rv[rv$uuid == e$uuid, ]
    if (row$kind != "value_conflict" || row$subkind != "measurement" || row$source_hash != .mig015_hash_08 ||
        row$uuid_existing != e$existing) {
      fail(sprintf("review %s is not the expected 2400-7399-08 value_conflict on %s.", e$uuid, e$existing))
    }
    inc <- jsonlite::fromJSON(row$payload)$value_incoming
    lab <- DBI::dbGetQuery(con, "SELECT uuid_lab FROM analysis WHERE uuid = ?", params = list(e$existing))$uuid_lab
    july <- DBI::dbGetQuery(con, "SELECT value FROM analysis WHERE uuid_sample = ? AND uuid_lab = ?", params = list(e$july, lab))$value
    if (length(july) != 1L || abs(inc - e$incoming) > 1e-9 || abs(july - e$incoming) > 1e-9) {
      fail(sprintf("review %s incoming %s does not equal the July sample's value.", e$uuid, format(inc)))
    }
    ok <- identical(row$status, "open") ||
      (allow_resolved && identical(row$status, "resolved") && identical(row$resolution, .mig015_resolution))
    if (!ok) fail(sprintf("review %s is %s (%s), expected open.", e$uuid, row$status, .mig015_default(row$resolution, "")))
  }
  invisible(rv)
}

.mig015_close_reviews <- function(db) {
  con <- st_connect(db, read_only = TRUE)
  rv <- tryCatch(.mig015_check_reviews(con, allow_resolved = TRUE), finally = DBI::dbDisconnect(con, shutdown = TRUE))
  n <- 0L
  for (u in rv$uuid[rv$status == "open"]) {
    if (isTRUE(resolve_review(u, .mig015_resolution, .mig015_resolved_by, db = db))) n <- n + 1L
  }
  n
}

.mig015_verify <- function(con, reviews = TRUE) {
  fail <- function(msg) cli::cli_abort(paste0("015-redate-legacy-dust verify failed: ", msg), class = "sampletidy_error")
  rows <- .mig015_rows(con)
  if (nrow(rows) != nrow(.mig015_targets)) fail(sprintf("%d of %d target samples found.", nrow(rows), nrow(.mig015_targets)))
  for (r in seq_len(nrow(rows))) {
    tg <- .mig015_targets[.mig015_targets$uuid == rows$uuid[[r]], ]
    if (!identical(rows$sd[[r]], tg$new_date)) fail(sprintf("%s date is %s (Sydney), expected %s.", tg$uuid, rows$sd[[r]], tg$new_date))
    if (!identical(rows$sds[[r]], tg$new_start)) fail(sprintf("%s date_start is %s, expected %s.", tg$uuid, rows$sds[[r]], tg$new_start))
    if (as.numeric(rows$date[[r]]) != as.numeric(.mig015_sydney_midnight(tg$new_date)) ||
        as.numeric(rows$date_start[[r]]) != as.numeric(.mig015_sydney_midnight(tg$new_start))) {
      fail(sprintf("%s lost the legacy representation.", tg$uuid))
    }
  }
  pr <- .mig015_project_rows(con)
  for (i in seq_len(nrow(.mig015_projects))) {
    e <- .mig015_projects[i, ]; row <- pr[pr$uuid == e$uuid, ]
    if (nrow(row) != 1L || !identical(row$ds, e$new_start) || !identical(row$de, e$new_end)) fail(sprintf("project %s period wrong.", e$uuid))
  }
  mv <- .mig015_move_rows(con)
  for (i in seq_len(nrow(.mig015_moves))) {
    if (mv$uuid_sample[mv$uuid == .mig015_moves$uuid[[i]]] != .mig015_moves$to[[i]]) fail(sprintf("%s not on its July sample.", .mig015_moves$uuid[[i]]))
  }
  n_leg <- .mig015_legacy_dust_n(con)
  if (n_leg != .mig015_expected_legacy_n) fail(sprintf("%d dust samples, expected %d.", n_leg, .mig015_expected_legacy_n))
  if (reviews) {
    rv <- .mig015_review_rows(con)
    if (!all(rv$status == "resolved") || !all(rv$resolution == .mig015_resolution) || nrow(rv) != nrow(.mig015_reviews)) {
      fail("not all 6 review items are resolved with 015's resolution.")
    }
  }
  invisible(TRUE)
}

mig015_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig015_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-015-redate-legacy-dust_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig015_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig015_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig015_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("015: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig015_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig015_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig015_verify(check_con, reviews = FALSE), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    n_closed <- .mig015_close_reviews(db)
    if (n_closed > 0) logf("closed %d review item(s) a previous run left open.", n_closed)
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig015_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("015 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  rows <- tryCatch(.mig015_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  for (r in seq_len(nrow(rows))) {
    tg <- .mig015_targets[.mig015_targets$uuid == rows$uuid[[r]], ]
    logf("(%d) sample %s %s (%s): start %s -> %s, date %s -> %s (Sydney)", tg$step, tg$uuid, tg$gauge, tg$source,
         ifelse(is.na(tg$old_start), "NULL", tg$old_start), tg$new_start, ifelse(is.na(tg$old_date), "NULL", tg$old_date), tg$new_date)
  }
  for (i in seq_len(nrow(.mig015_moves))) {
    logf("(3) analysis %s %s Appearance: sample %s -> %s", .mig015_moves$uuid[[i]], .mig015_moves$gauge[[i]],
         .mig015_moves$from[[i]], .mig015_moves$to[[i]])
  }
  for (i in seq_len(nrow(.mig015_projects))) {
    e <- .mig015_projects[i, ]
    logf("(1/2) project %s: period %s..%s -> %s..%s", e$uuid, ifelse(is.na(e$old_start), "NULL", e$old_start),
         ifelse(is.na(e$old_end), "NULL", e$old_end), e$new_start, e$new_end)
  }
  logf("(4) %d review items to close: %s", nrow(.mig015_reviews), paste(substr(.mig015_reviews$uuid, 1, 8), collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  # Row backups (CSV), taken while the rows still hold their old values.
  with_db_write(function(con) {
    .mig015_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid",
                                                   .mig015_ids_sql(.mig015_targets$uuid))),
                      file.path(csv_dir, "015-redate-legacy-dust-BACKUP-sample.csv"))
    .mig015_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM project WHERE uuid IN (%s) ORDER BY uuid",
                                                   .mig015_ids_sql(.mig015_projects$uuid))),
                      file.path(csv_dir, "015-redate-legacy-dust-BACKUP-project.csv"))
    .mig015_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN (%s) ORDER BY uuid",
                                                   .mig015_ids_sql(.mig015_moves$uuid))),
                      file.path(csv_dir, "015-redate-legacy-dust-BACKUP-analysis.csv"))
  }, db = db)
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig015_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig015_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig015_counts(con)
    sums_before <- .mig015_checksum(con)
    db_transaction(con, function(con) {
      for (r in seq_len(nrow(.mig015_targets))) {
        tg <- .mig015_targets[r, ]
        if (tg$step == 1L) {
          changes <- list(date = .mig015_sydney_midnight(tg$new_date))
          reason <- sprintf("015: dust %s exposed %s, collected %s per %s; legacy load had collection %s (+1 day). Exposure = date_start, collection = date (Robin, 2026-10-16)",
                            tg$gauge, tg$new_start, tg$new_date, tg$source, tg$old_date)
        } else {
          changes <- list(date_start = .mig015_sydney_midnight(tg$new_start), date = .mig015_sydney_midnight(tg$new_date))
          reason <- sprintf("015: undated legacy dust %s is %s's July-2024 gauge-block (values identical); exposed %s, collected %s (Robin, 2026-10-16)",
                            tg$gauge, tg$source, tg$new_start, tg$new_date)
        }
        db_update(con, "sample", uuid = tg$uuid, changes = changes, actor = .mig015_actor, reason = reason)
      }
      for (i in seq_len(nrow(.mig015_projects))) {
        e <- .mig015_projects[i, ]
        db_update(con, "project", uuid = e$uuid,
                  changes = list(date_start = .mig015_naive(e$new_start), date_end = .mig015_naive(e$new_end)),
                  actor = .mig015_actor,
                  reason = sprintf("015: dust-period project of sample %s spans exposure %s to collection %s (follows the sample re-date)",
                                   e$sample, e$new_start, e$new_end))
      }
      for (i in seq_len(nrow(.mig015_moves))) {
        m <- .mig015_moves[i, ]
        db_update(con, "analysis", uuid = m$uuid, changes = list(uuid_sample = m$to), actor = .mig015_actor,
                  source_hash = .mig015_hash_08,
                  reason = sprintf("015: 2400-7399-08's July-2024 %s observation was attached to the June sample %s because July's legacy sample was undated; moved to %s",
                                   m$gauge, m$from, m$to))
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig015_marker_version, recorded_at))
      .mig015_verify(con, reviews = FALSE)
      if (!identical(counts_before, .mig015_counts(con)) || !identical(sums_before, .mig015_checksum(con))) {
        cli::cli_abort("015 verify failed: something outside the 6 samples' dates, the 4 projects' periods and the 2 analyses' uuid_sample moved.",
                       class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  n_closed <- .mig015_close_reviews(db)
  logf("(4) closed %d review item(s) via resolve_review().", n_closed)
  check_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig015_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))

  logf("015-redate-legacy-dust migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
