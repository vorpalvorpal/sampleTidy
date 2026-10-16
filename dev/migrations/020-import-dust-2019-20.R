# Operator-run migration: import the 22 Jul-2019..Jul-2020 dust exposures from
# the Dust Results Database workbook that are not in the database (B.D07 and
# B.D08).
#
# Authorised by Robin, 2026-10-17: "The workbook has 22 rows for exposures
# Jul-2019 to Jul-2020 that are not in the DB. Import them as new samples and
# analyses on B.D07/B.D08. Match the existing legacy dust rows exactly ...
# Comment each row with 'imported 2026-10-17 from Dust Results Database
# workbook, migration 020'."
#
# ---- SOURCE ---------------------------------------------------------------
#
# "Blaxland WMF Dust Results Database.xlsx", sheet "Dust " (ACIRL reports
# 2400-6852 for exposures Jul..Dec-2019, 2400-6989 from Jan-2020; DG #1 = B.D07,
# DG #2 = B.D08). It prints exposure and collection dates (all on the 1st),
# Insoluble Solids / Combustible / Incombustible Matter in g/m2.month (2 dp for
# total, mixed for combustible, 1 dp for incombustible) and Observations.
# It has 26 rows for exposures Jul-2019..Jul-2020; Jan- and Feb-2020 (4 rows)
# are the year-out legacy samples re-dated by 018, leaving these 22. Exposures
# Aug-2020..Dec-2020 are the load-A legacy rows (017, 019).
#
# ---- HOW THE NEW ROWS MIRROR THE LEGACY ROWS --------------------------------
#
# The template is the 10 load-A samples loaded from THIS workbook (exposures
# Aug..Dec-2020), field by field:
#   sample.uuid_feature_alias  the gauges' self aliases (B.D07 75e593a3, B.D08 22b50a74)
#   sample.uuid_project        the ROOT "Dust monitoring" project 230bd429, as every
#                              2020-22 legacy dust sample. (The unnamed "Dust
#                              monitoring" CHILD projects carry only the 2022-08+
#                              rows, one per ACIRL xls report + asset; this workbook
#                              has no such project, so none is created.)
#   sample.date_start          exposure day, Sydney midnight held as the UTC instant
#   sample.date                collection day, same representation (015-019)
#   sample.datetime            collection day 11:00 Sydney as the UTC instant
#   sample.datetime_start      = datetime (as the legacy loader wrote it on every row)
#   sample.organisation/person NULL / NULL (as load A)
#   sample.purpose             NULL
#   sample.comments            "imported 2026-10-17 from Dust Results Database workbook, migration 020"
#   analysis.uuid_lab          INSOLUBLE SOLIDS 83282ca2 (dust-total), *COMBUSTIBLE MATTER
#                              734a6092 (dust-combustible), INCOMBUSTIBLE MATTER e6019d73
#                              (dust-incombustible); units are the methods' (NULL ->
#                              analyte units), as load A.
#   analysis.comments          the workbook's Observations text, verbatim (as load A)
#   analysis.value/quantified  the workbook figure, quantified TRUE, rl NULL.
# One `<`: B.D07 exposure Jul-2019 has combustible `<0.1`. It is stored as the
# house non-detect (012: value 0.1, quantified FALSE, rl_low 0.1) and, per
# Robin's 013 ruling, its incombustible (printed 0.6) as the upper bound
# `<dust-total` (value = rl_low = 0.64, quantified FALSE).
#
# NOT IMPORTED (the legacy rows carry none of them): the workbook's "Days
# Exposed" column, and its mass columns Insoluble Solids / Combustible /
# Incombustible Matter in mg (filled for exposure Aug-2019 and Sep..Dec-2020).
#
# COLLISIONS: none. The precondition refuses if any sample on B.D07/B.D08 (any
# alias) has a collection or exposure Sydney day equal to a new row's, or if a
# new row would clash on 009's ux_sample_identity (alias, datetime, project).
#
# UUIDs are fixed below so rehearsal and live write identical rows.
#
# BACKUP: the rows are new, so there is nothing to dump; the run writes the 22
# samples and 66 analyses it inserted to `020-import-dust-2019-20-INSERTED-
# {sample,analysis}.csv` beside this file, plus the verified whole-file backup
# in `snapshot_dir`. To undo: delete those analyses, then those samples.
#
# Marker 1020. Requires 1019. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/020-import-dust-2019-20.R", envir = env)
#   env$mig020_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig020_marker_version <- 1020L
.mig020_requires <- 1019L
.mig020_actor <- "020-import-dust-2019-20"
.mig020_expected_legacy_n <- 100L
.mig020_comment <- "imported 2026-10-17 from Dust Results Database workbook, migration 020"
.mig020_project <- "230bd429-7ba5-4f95-b688-d01d47367723"
.mig020_alias <- c(B.D07 = "75e593a3-134b-4097-8ad9-e1e65ddc8f17", B.D08 = "22b50a74-b596-4cac-97f7-534d881ec98d")
.mig020_lab <- c(`dust-total` = "83282ca2-596d-43f5-ac3e-4d01412c167b",
                 `dust-combustible` = "734a6092-0af8-4019-841d-86f529109d86",
                 `dust-incombustible` = "e6019d73-d6d8-4b64-806a-d4a647a1da9d")

.mig020_row <- function(uuid, gauge, dg, report, exposed, collected, total, comb, comb_lt, incomb, obs, a_total, a_comb, a_incomb) {
  data.frame(uuid = uuid, gauge = gauge, dg = dg, report = report, exposed = exposed, collected = collected,
             total = total, comb = comb, comb_lt = comb_lt, incomb = incomb, obs = obs,
             a_total = a_total, a_comb = a_comb, a_incomb = a_incomb, stringsAsFactors = FALSE)
}
# total / comb / incomb: the workbook cells. comb_lt: the cell reads `<comb`.
.mig020_def <- rbind(
  .mig020_row("d63709c8-67df-4349-bfe5-a9c4159bd5a7", "B.D07", "DG #1", "2400-6852", "2019-07-01", "2019-08-01", 0.64, 0.1, TRUE, 0.6, "Clear, insects, organic matter, fine brown dust, course black dust", "16bd6e7b-3843-4db3-8417-aa3e9a5e7f69", "cc0e3227-93f4-4dd1-b95a-56f7923c5018", "a33f8d98-8ff5-402e-a8c0-3a9936276184"),
  .mig020_row("1624f97e-13f3-4bca-a473-05cf8622cf54", "B.D08", "DG #2", "2400-6852", "2019-07-01", "2019-08-01", 2.35, 0.2, FALSE, 2.2, "Clear, insects, organic matter, fine brown dust, course brown/black dust", "cd441412-d0c0-4f2b-81c0-b6ca956ad42b", "3742a89e-57b1-4a71-9b7d-3a0d96f54d87", "18c6b164-e852-466f-b689-df174fd7b4da"),
  .mig020_row("ac0416a1-de03-4449-ba6e-fea5fe761baf", "B.D07", "DG #1", "2400-6852", "2019-08-01", "2019-09-01", 2, 0.6, FALSE, 1.4, "Clear, insects,organic matter, fine brown dust, coarse black dust.", "ca4a56a0-4f11-490f-a859-f0b02c35e942", "0fcb97ac-963a-4c38-b1b7-5e0b81a2dd1b", "b279bdb6-fc61-431f-8b25-0eb28da7806d"),
  .mig020_row("e5cdbb96-a350-4796-9a68-7261e2bc0163", "B.D08", "DG #2", "2400-6852", "2019-08-01", "2019-09-01", 2.7, 0.4, FALSE, 2.3, "Clear, insects,organic matter, fine brown dust, coarse black dust.", "5bd6015f-923d-4fcb-bdd5-f214bbabd6d4", "a68a78f8-b0f8-449c-a0c3-9f4e22b7111c", "6ed770f4-1060-453a-a05d-de2a5847fd7b"),
  .mig020_row("a7ef8dd3-e657-4cf3-bff8-227d5c825c98", "B.D07", "DG #1", "2400-6852", "2019-09-01", "2019-10-01", 1.08, 0.4, FALSE, 0.7, "Clear, insects,organic matter, fine brown dust, coarse black dust.", "35dd9a4b-4530-4263-a062-4ad17907735b", "5324c217-b7fa-44a1-b0e4-53e22c5be24b", "62b4f420-e993-436c-9b6f-1dc7dd556b3b"),
  .mig020_row("9f5505b6-5576-415b-8777-9b5c4564f02c", "B.D08", "DG #2", "2400-6852", "2019-09-01", "2019-10-01", 2.91, 0.5, FALSE, 2.4, "Clear, insects,organic matter, fine brown dust, coarse black dust.", "22b9a91b-39e6-440e-84aa-b4205b6ad9ee", "ced8a8e9-378e-45e8-a181-0f88ce42aca7", "9384a4ea-4eaf-4345-a7fe-4daec47d8097"),
  .mig020_row("18a1b10c-c8d8-4fb7-a310-889b490b1dee", "B.D07", "DG #1", "2400-6852", "2019-10-01", "2019-11-01", 2.63, 0.7, FALSE, 1.9, "Slightly cloudy, insects, organic matter, fine brown dust, coarse black dust.", "76dbbe0d-2895-4810-b150-3731c27c7864", "6a738bb9-4514-4fe2-a9f3-4d010b36d467", "adb5761a-33e6-4371-818f-2bb4cd59cfd0"),
  .mig020_row("10af47dc-ee78-460f-add7-a8cbf3d399e8", "B.D08", "DG #2", "2400-6852", "2019-10-01", "2019-11-01", 3.38, 0.5, FALSE, 2.9, "Clear, insects, organic matter, fine brown dust, coarse blak dust.", "baeda457-e994-47ba-9525-f7bc4330b6d8", "9e6ac0a5-bcff-48cb-8332-2b03c0100430", "93a34ed1-82be-49ba-bd5e-af7b9fe6b30d"),
  .mig020_row("71c95adb-fa8c-4d0e-a6c0-807bf8811aa7", "B.D07", "DG #1", "2400-6852", "2019-11-01", "2019-12-01", 4.5, 1.1, FALSE, 3.4, "Clear, insects, organic matter, fine brown dust, coarse black dust.", "4b7390f3-7231-410a-914e-4df4cfcce4cc", "06b627aa-6b9f-4140-bca6-4ca7af22b4b3", "9fdac52e-c28c-49d0-bd08-087139a5e421"),
  .mig020_row("6796e722-3deb-4d78-b5b8-4e286340c8fd", "B.D08", "DG #2", "2400-6852", "2019-11-01", "2019-12-01", 4.5, 0.8, FALSE, 3.7, "Clear, organic matter, fine brown dust, coarse black dust.", "b70e2a95-c7d4-42ba-b3ed-30cc9a898b6d", "524df4fd-7eba-46f7-aac5-776b50d509db", "444ef9fd-8220-4499-8511-22ab3b3b8a26"),
  .mig020_row("4ece1a55-ab45-4c5c-8a24-5c0faef5c584", "B.D07", "DG #1", "2400-6852", "2019-12-01", "2020-01-01", 2.6, 1, FALSE, 1.6, "Slightly cloudy, insects, organic matter, fine brown dust and coarse black dust", "97975e39-0f8f-4856-92cb-a91323ac85c5", "bb3bc745-0e6c-4d88-a205-d6d172fc461d", "febde212-01c5-4567-a73f-469d87b9dc1f"),
  .mig020_row("1dfc8d5c-3910-4525-a3a5-a045727f87e9", "B.D08", "DG #2", "2400-6852", "2019-12-01", "2020-01-01", 2.2, 0.4, FALSE, 1.8, "Slightly cloudy, insects, organic matter, fine brown dust and coarse black dust", "b5e82f3e-d4c6-41a8-97ef-2b6c803fb6b3", "46434206-6c40-468b-a9be-f124f52261be", "5ae60f38-06f6-4db8-a5ed-72d6261d6ce1"),
  .mig020_row("96e56f62-8ce4-4f0c-b81c-0f86bdb124dd", "B.D07", "DG #1", "2400-6989", "2020-03-01", "2020-04-01", 1.17, 0.4, FALSE, 0.8, "Slightly cloudy, insects, organic matter, fine brown dust & coarse black dust", "259f90e7-934a-4901-86b2-ba0374247bd0", "7eeeddef-9e0d-44f6-89c1-72c2f2977147", "d8f7babb-1b6c-45e2-bd59-724b684bec0a"),
  .mig020_row("9c309d22-c8a8-40fa-a610-4e781aabd941", "B.D08", "DG #2", "2400-6989", "2020-03-01", "2020-04-01", 3.01, 1, FALSE, 2, "Slightly cloudy, organic matter, fine brown dust & coarse bblack dust", "2263fb51-a185-425d-a0db-dc41b26416aa", "262f33f0-ca05-40d8-8e07-3715a77ab43a", "4aee5004-7952-46a9-a6ad-726ad3aa8190"),
  .mig020_row("f42d190b-9e2c-4aec-bd4f-81d52cc22afd", "B.D07", "DG #1", "2400-6989", "2020-04-01", "2020-05-01", 0.54, 0.1, FALSE, 0.4, "Clear, insects, organic matter, fine brown dust and coarse black dust.", "0be098bf-55b0-4e37-a78d-142664171fdc", "fb3aaea1-1c7f-4d77-84bd-3b76b8ef343b", "84429e73-7dfd-4426-9363-645becd65872"),
  .mig020_row("d08f8ff2-3503-4860-adc1-9552288faa5d", "B.D08", "DG #2", "2400-6989", "2020-04-01", "2020-05-01", 3.68, 0.9, FALSE, 2.8, "Slightly cloudy, insects, organic matter, fine brown dust and coarse brown/black dust.", "5213995e-18f1-4dbf-bc26-90fa298fdc3b", "8600d4f8-0454-40e0-abd2-927b9c527af1", "d9103ca4-ab28-486a-94c6-b15ad4c82d1e"),
  .mig020_row("af1636c4-6aaa-4a62-be9c-09a5b7660da8", "B.D07", "DG #1", "2400-6989", "2020-05-01", "2020-06-01", 1.81, 0.3, FALSE, 1.5, "Clear, insects, organic matter, fine brown dust and coarse black dust.", "3505e0cf-fdbb-4344-948e-e788691db7fa", "9e23d1ad-eb51-4b3e-99f5-bbf8ccb2bf40", "c47cde5d-6a05-4a6a-a4e0-6f936e477110"),
  .mig020_row("120c3598-68ac-479a-a056-bcc94b96e0b9", "B.D08", "DG #2", "2400-6989", "2020-05-01", "2020-06-01", 1.73, 0.3, FALSE, 1.4, "Clear, insects, organic matter, fine brown dust and coarse black dust.", "1316dd3a-a637-435b-b0d3-462d33182b81", "6c7534fd-f64e-45a0-9377-6fae8ef58e89", "a1a48ac6-6c03-4b96-b680-06a878d2fd50"),
  .mig020_row("5190ee2a-046d-4228-9e52-3ad8940b5070", "B.D07", "DG #1", "2400-6989", "2020-06-01", "2020-07-01", 0.84, 0.2, FALSE, 0.6, "Clear, insects, organic matter, fine brown dust and coarse black dust", "146eeabf-d954-4b22-a3d9-f6c5a093b7bc", "8de805ac-b79e-4580-bd45-16edc66a338b", "d19a247b-d649-4b33-9a19-ba61383c49f7"),
  .mig020_row("e36785d6-9692-4b40-be34-15d00acda7a3", "B.D08", "DG #2", "2400-6989", "2020-06-01", "2020-07-01", 1.26, 0.3, FALSE, 1, "Clear, insects, organic matter, fine brown dust and coarse black dust", "78f4b672-7fe4-4922-ade5-ec74b5f9b908", "1dc10bd6-9b8c-4ab0-9809-55aba63cf319", "9b1e9182-30a1-4787-bb77-055350502ebe"),
  .mig020_row("b457913f-565d-4804-8cd4-f37b08bd89c0", "B.D07", "DG #1", "2400-6989", "2020-07-01", "2020-08-01", 0.91, 0.3, FALSE, 0.6, "Clear, insects, organic matter, fine brown dust and coarse black dust", "3591c726-003d-42b0-a117-7c28fc4955a9", "e94a3fe3-8e06-45f7-8f90-ea043022fcbb", "57d514f9-aa2b-4949-962f-9a0593631968"),
  .mig020_row("cb5d81cb-b5e7-43f2-8bf4-c5bce5a0d8e9", "B.D08", "DG #2", "2400-6989", "2020-07-01", "2020-08-01", 3.19, 0.6, FALSE, 2.6, "Clear, insects, organic matter, fine brown dust and coarse black dust", "b9f403d5-11b4-4414-80dd-b17a38a5eed2", "87b4b7d6-82b0-4ba5-b51d-9d287ceb0c96", "74fd90e1-253a-498c-b3fe-62db2b15d7a0")
)

.mig020_default <- function(x, default) if (is.null(x)) default else x
.mig020_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig020_sydney <- function(day, time = "00:00:00") as.POSIXct(paste(day, time), tz = "Australia/Sydney")
.mig020_ids_sql <- function(ids) paste(sprintf("'%s'", ids), collapse = ", ")
.mig020_syd <- function(col) sprintf("CAST(CAST(timezone('Australia/Sydney', timezone('UTC', %s)) AS DATE) AS VARCHAR)", col)
.mig020_fail <- function(msg) cli::cli_abort(paste0("020-import-dust-2019-20: ", msg), class = "sampletidy_error")

# The 22 sample rows exactly as inserted.
.mig020_samples <- function() {
  d <- .mig020_def
  data.frame(
    uuid = d$uuid,
    uuid_feature_alias = unname(.mig020_alias[d$gauge]),
    uuid_project = .mig020_project,
    date = .mig020_sydney(d$collected),
    date_start = .mig020_sydney(d$exposed),
    datetime = .mig020_sydney(d$collected, "11:00:00"),
    datetime_start = .mig020_sydney(d$collected, "11:00:00"),
    organisation = NA_character_, person = NA_character_, purpose = NA_character_,
    comments = .mig020_comment,
    stringsAsFactors = FALSE
  )
}

# The 66 analysis rows exactly as inserted (3 per sample).
.mig020_analyses <- function() {
  d <- .mig020_def
  one <- function(uuid, analyte, value, quantified, rl_low) {
    data.frame(uuid = uuid, uuid_sample = d$uuid, uuid_lab = unname(.mig020_lab[[analyte]]),
               value = value, value_chr = NA_character_, quantified = quantified, rl_low = rl_low,
               rl_high = NA_real_, purpose = NA_character_, comments = d$obs, stringsAsFactors = FALSE)
  }
  out <- rbind(
    one(d$a_total, "dust-total", d$total, TRUE, NA_real_),
    # 012: a `<x` combustible is value x, quantified FALSE, rl_low x.
    one(d$a_comb, "dust-combustible", d$comb, !d$comb_lt, ifelse(d$comb_lt, d$comb, NA_real_)),
    # 013: where combustible is `<`, incombustible is the upper bound `<dust-total`.
    one(d$a_incomb, "dust-incombustible", ifelse(d$comb_lt, d$total, d$incomb), !d$comb_lt, ifelse(d$comb_lt, d$total, NA_real_))
  )
  out[order(match(out$uuid_sample, d$uuid)), ]
}

.mig020_legacy_dust_n <- function(con) {
  .mig020_scalar(con, "
    SELECT COUNT(DISTINCT a.uuid_sample) FROM analysis a
    JOIN lab_method lm ON lm.uuid = a.uuid_lab JOIN analyte an ON an.uuid = lm.uuid_analyte
    WHERE an.name LIKE 'dust-%'")
}

.mig020_counts <- function(con) {
  list(
    analysis = .mig020_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig020_scalar(con, "SELECT COUNT(*) FROM \"sample\""),
    feature_alias = .mig020_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    project = .mig020_scalar(con, "SELECT COUNT(*) FROM project")
  )
}

# Everything already in the DB, which the transaction must not touch.
.mig020_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  ids <- .mig020_ids_sql(.mig020_def$uuid)
  list(
    sample = q(sprintf("SELECT * FROM \"sample\" WHERE uuid NOT IN (%s) ORDER BY uuid", ids)),
    analysis = q(sprintf("SELECT * FROM analysis WHERE uuid_sample NOT IN (%s) ORDER BY uuid", ids)),
    project = q("SELECT * FROM project ORDER BY uuid"),
    feature_alias = q("SELECT * FROM feature_alias ORDER BY uuid"),
    lab_method = q("SELECT * FROM lab_method ORDER BY uuid")
  )
}

# B.D07/B.D08 samples (any alias) with their Sydney days.
.mig020_gauge_samples <- function(con) {
  DBI::dbGetQuery(con, sprintf("
    SELECT s.uuid, f.name AS gauge, %s AS sd, %s AS sds, s.uuid_feature_alias, s.datetime, s.uuid_project
    FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE f.name IN ('B.D07', 'B.D08')", .mig020_syd("s.date"), .mig020_syd("s.date_start")))
}

.mig020_check_preconditions <- function(con) {
  fail <- .mig020_fail
  if (.mig020_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig020_requires) == 0L) {
    fail(sprintf("marker %d (019) is required first.", .mig020_requires))
  }
  n_leg <- .mig020_legacy_dust_n(con)
  if (n_leg != .mig020_expected_legacy_n) fail(sprintf("%d samples carry a dust analysis, expected %d.", n_leg, .mig020_expected_legacy_n))
  d <- .mig020_def
  if (nrow(d) != 22L || anyDuplicated(d[, c("gauge", "exposed")]) > 0) fail("the row definitions are not 22 distinct gauge-months.")
  all_ids <- c(d$uuid, d$a_total, d$a_comb, d$a_incomb)
  if (anyDuplicated(all_ids) > 0) fail("duplicate uuids in the definitions.")
  if (.mig020_scalar(con, sprintf("SELECT COUNT(*) FROM \"sample\" WHERE uuid IN (%s)", .mig020_ids_sql(all_ids))) +
      .mig020_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid IN (%s)", .mig020_ids_sql(all_ids))) > 0) {
    fail("a planned uuid already exists.")
  }
  # The template rows: the root project, the two self aliases and the three methods exist as described.
  p <- DBI::dbGetQuery(con, "SELECT name, uuid_parent FROM project WHERE uuid = ?", params = list(.mig020_project))
  if (nrow(p) != 1L || !identical(p$name, "Dust monitoring") || !is.na(p$uuid_parent)) fail("the root Dust monitoring project is not as expected.")
  fa <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, f.name, fa.kind FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature
                                       WHERE fa.uuid IN (%s)", .mig020_ids_sql(.mig020_alias)))
  if (nrow(fa) != 2L || !all(fa$kind == "self") || !setequal(fa$name[match(.mig020_alias, fa$uuid)], names(.mig020_alias)) ||
      !identical(fa$name[match(.mig020_alias, fa$uuid)], names(.mig020_alias))) fail("the gauge self aliases are not as expected.")
  lm <- DBI::dbGetQuery(con, sprintf("SELECT lm.uuid, an.name FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte
                                       WHERE lm.uuid IN (%s)", .mig020_ids_sql(.mig020_lab)))
  if (nrow(lm) != 3L || !identical(lm$name[match(.mig020_lab, lm$uuid)], names(.mig020_lab))) fail("the dust lab methods are not as expected.")
  # Collisions: same gauge and same Sydney collection or exposure day, or the identity index.
  g <- .mig020_gauge_samples(con)
  hit <- c()
  for (r in seq_len(nrow(d))) {
    x <- d[r, ]
    h <- g[g$gauge == x$gauge & (g$sd %in% x$collected | g$sds %in% x$exposed), ]
    if (nrow(h) > 0) hit <- c(hit, sprintf("%s %s/%s held by %s", x$gauge, x$exposed, x$collected, paste(substr(h$uuid, 1, 8), collapse = ",")))
  }
  s <- .mig020_samples()
  ux <- DBI::dbGetQuery(con, sprintf("SELECT uuid FROM \"sample\" WHERE uuid_project = '%s' AND uuid_feature_alias IN (%s) AND datetime IN (%s)",
                                     .mig020_project, .mig020_ids_sql(.mig020_alias),
                                     paste(sprintf("TIMESTAMP '%s'", format(s$datetime, "%Y-%m-%d %H:%M:%S", tz = "UTC")), collapse = ", ")))
  if (nrow(ux) > 0) hit <- c(hit, paste("ux_sample_identity:", paste(ux$uuid, collapse = ",")))
  if (length(hit) > 0) fail(paste("collisions:", paste(hit, collapse = "; ")))
  invisible(TRUE)
}

.mig020_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("020 verify failed: ", msg), class = "sampletidy_error")
  ids <- .mig020_ids_sql(.mig020_def$uuid)
  got_s <- DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s)", ids))
  want_s <- .mig020_samples()
  if (nrow(got_s) != nrow(want_s)) fail(sprintf("%d of %d samples present.", nrow(got_s), nrow(want_s)))
  got_s <- got_s[match(want_s$uuid, got_s$uuid), names(want_s)]
  for (f in names(want_s)) {
    a <- got_s[[f]]; b <- want_s[[f]]
    same <- if (inherits(b, "POSIXct")) isTRUE(all(as.numeric(a) == as.numeric(b))) else identical(as.character(a), as.character(b))
    if (!same) fail(sprintf("sample.%s differs from the definition.", f))
  }
  got_a <- DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN (%s)", ids))
  want_a <- .mig020_analyses()
  if (nrow(got_a) != nrow(want_a)) fail(sprintf("%d of %d analyses present.", nrow(got_a), nrow(want_a)))
  got_a <- got_a[match(want_a$uuid, got_a$uuid), names(want_a)]
  for (f in names(want_a)) {
    a <- got_a[[f]]; b <- want_a[[f]]
    same <- if (is.numeric(b)) isTRUE(all((is.na(a) & is.na(b)) | abs(a - b) < 1e-9, na.rm = FALSE)) else identical(as.character(a), as.character(b))
    if (!same) fail(sprintf("analysis.%s differs from the definition.", f))
  }
  g <- .mig020_gauge_samples(con)
  if (anyDuplicated(g[!is.na(g$sd), c("gauge", "sd")]) > 0 || anyDuplicated(g[!is.na(g$sds), c("gauge", "sds")]) > 0) {
    fail("two samples share a gauge and a Sydney day.")
  }
  n_leg <- .mig020_legacy_dust_n(con)
  if (n_leg != .mig020_expected_legacy_n + nrow(.mig020_def)) fail(sprintf("%d dust samples.", n_leg))
  invisible(TRUE)
}

mig020_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig020_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-020-import-dust-2019-20_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig020_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig020_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig020_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("020: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

mig020_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig020_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig020_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("020 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  tryCatch(.mig020_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  d <- .mig020_def
  for (r in seq_len(nrow(d))) {
    logf("insert %s %s (%s %s) exposed %s collected %s: %s / %s%s / %s", d$uuid[[r]], d$gauge[[r]], d$dg[[r]], d$report[[r]],
         d$exposed[[r]], d$collected[[r]], format(d$total[[r]]), ifelse(d$comb_lt[[r]], "<", ""), format(d$comb[[r]]),
         ifelse(d$comb_lt[[r]], paste0("<", format(d$total[[r]]), " (013; printed ", format(d$incomb[[r]]), ")"), format(d$incomb[[r]])))
  }
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig020_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig020_default(.now, Sys.time())

  with_db_write(function(con) {
    counts_before <- .mig020_counts(con)
    sums_before <- .mig020_checksum(con)
    db_transaction(con, function(con) {
      db_append(con, "sample", .mig020_samples(), actor = .mig020_actor,
                reason = "020: Jul-2019..Jul-2020 dust exposures (B.D07 = DG #1, B.D08 = DG #2) absent from the DB, imported from the Dust Results Database workbook (2400-6852 / 2400-6989) mirroring the load-A legacy rows (Robin, 2026-10-17)")
      db_append(con, "analysis", .mig020_analyses(), actor = .mig020_actor,
                reason = "020: dust results for the imported Jul-2019..Jul-2020 samples, per the Dust Results Database workbook (Robin, 2026-10-17); a `<0.1` combustible is a 012 non-detect and its incombustible the 013 `<dust-total` bound")
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig020_marker_version, recorded_at))
      .mig020_verify(con)
      expect <- counts_before; expect$sample <- expect$sample + 22L; expect$analysis <- expect$analysis + 66L
      if (!identical(expect, .mig020_counts(con)) || !identical(sums_before, .mig020_checksum(con))) {
        cli::cli_abort("020 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  with_db_write(function(con) {
    ids <- .mig020_ids_sql(.mig020_def$uuid)
    .mig020_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM \"sample\" WHERE uuid IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "020-import-dust-2019-20-INSERTED-sample.csv"))
    .mig020_write_csv(DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid_sample IN (%s) ORDER BY uuid", ids)),
                      file.path(csv_dir, "020-import-dust-2019-20-INSERTED-analysis.csv"))
  }, db = db)
  logf("Inserted rows written to %s", csv_dir)

  logf("020-import-dust-2019-20 migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
