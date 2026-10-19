# PLAN-19 phase-1 ingest changes: R-19.14 (crosstab Secondary-ID captured as
# IR `secondary_id`; qc_hint on unknown_feature; qc_label_conflict), R-19.15
# (a field QC code commits as a normal sample on its own QC feature) and
# R-19.6 (`sample_lab_id` written at commit, crosstab/ESdat only).
#
# FIXTURE fixtures/qc/secondary/ES2537534_0_ENMRG.CSV is DERIVED from the
# anonymised real fixtures/crosstab/ES2537534_0_ENMRG.CSV (REAL-FIXTURES.md):
# only the two client-ID rows were edited, every ALS value is untouched.
# [invented: the plan's A.8 names ES2626883's ENMRG as the Secondary-ID
#  fixture; an edited copy of the committed one covers the same layout
#  without pulling another real file.] Columns, in order:
#   Primary   Q.MW02  Q.MW08  Bailer/Scoop  Q.S01  Q.JD42  Q.S05      Q.S06
#   Secondary 12      -       Field Blank   -      -       Duplicate  -
# Q.JD42 is an invented QC code (site Q, helper-qc.R); Q.S06 and Bailer/Scoop
# are deliberately unregistered.

sec_path <- test_path("fixtures", "qc", "secondary", "ES2537534_0_ENMRG.CSV")
real_enmrg <- test_path("fixtures", "crosstab", "ES2537534_0_ENMRG.CSV")
real_xtab <- test_path("fixtures", "crosstab", "ES2600185_0_XTAB.csv")
sec_wo <- "ES2537534"

enmrg <- function() sampleTidy:::adapter_registry()[["als_enmrg"]]
xtab <- function() sampleTidy:::adapter_registry()[["als_xtab"]]

qci_db_setup <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  ensure_test_asset_table(con)
  qc_create_tables(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  for (nm in c("Q.MW02", "Q.MW08", "Q.S05", "Q.X01")) fl_feature(con, nm)   # Q.S01 is seeded
  qc_add(con, "Q.JD42", "duplicate", parent = "Q.X01", date_start = "2025-01-01")
  db_path
}

qci_ingest <- function(db_path, files, env = parent.frame()) {
  input <- withr::local_tempdir(.local_envir = env)
  file.copy(files, input)
  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  invisible(input)
}

qci_query <- function(db_path, sql, params = NULL) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = params)
}

qci_items <- function(db_path, kind) {
  qci_query(db_path, "SELECT uuid, status, payload FROM review_queue WHERE kind = ?",
            params = list(kind))
}

qci_payloads <- function(items) lapply(items$payload, jsonlite::fromJSON, simplifyVector = TRUE)

# committed samples of the work order: feature name -> sample uuid
qci_samples <- function(db_path) {
  qci_query(db_path, "SELECT s.uuid, f.name AS feature
                        FROM \"sample\" s
                        JOIN project p ON p.uuid = s.uuid_project
                        JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                        JOIN feature f ON f.uuid = fa.uuid_feature
                       WHERE p.name = ?", params = list(sec_wo))
}

# ---- R-19.14 adapter ---------------------------------------------------------------

test_that("R-19.14: the crosstab adapter captures the Secondary-ID row per column into samples$secondary_id", {
  meta <- sampleTidy:::file_meta(sec_path)
  out <- enmrg()$parse(sec_path, meta)
  # [invented: `secondary_id` is a column of the SAMPLES IR (one per column)]
  expect_true("secondary_id" %in% names(out$samples))
  expect_type(out$samples$secondary_id, "character")
  got <- stats::setNames(out$samples$secondary_id, out$samples$feature_raw)
  expect_identical(unname(got[c("Q.MW02", "Q.MW08", "Bailer/Scoop", "Q.S01", "Q.JD42", "Q.S05", "Q.S06")]),
                   c("12", NA, "Field Blank", NA, NA, "Duplicate", NA))
  expect_silent(sampleTidy:::ir_validate(out$samples, kind = "samples"))
})

test_that("R-19.14: empty Secondary/2nd rows give NA in the real ENMRG and XTAB fixtures", {
  for (p in c(real_enmrg, real_xtab)) {
    meta <- sampleTidy:::file_meta(p)
    ad <- if (grepl("ENMRG", p)) enmrg() else xtab()
    out <- ad$parse(p, meta)
    expect_true("secondary_id" %in% names(out$samples), label = basename(p))
    expect_true(all(is.na(out$samples$secondary_id)), label = basename(p))
  }
})

# ---- R-19.14 uses, R-19.15 ------------------------------------------------------------

test_that("R-19.14 use 1: an unresolved primary with a QC-type secondary gets qc_hint in its unknown_feature payload", {
  db <- qci_db_setup()
  qci_ingest(db, sec_path)
  p <- qci_payloads(qci_items(db, "unknown_feature"))
  raw <- vapply(p, function(x) x$feature_raw, "")
  expect_true(all(c("Bailer/Scoop", "Q.S06") %in% raw))
  bs <- p[[which(raw == "Bailer/Scoop")]]
  expect_identical(bs$qc_hint, "field_blank")
  s6 <- p[[which(raw == "Q.S06")]]
  expect_true(is.null(s6$qc_hint) || is.na(s6$qc_hint))
})

test_that("R-19.14 use 2: a primary resolving to a NON-QC feature with a QC-type secondary raises a non-blocking qc_label_conflict", {
  db <- qci_db_setup()
  qci_ingest(db, sec_path)
  it <- qci_items(db, "qc_label_conflict")
  expect_equal(nrow(it), 1)
  expect_identical(it$status, "open")
  p <- qci_payloads(it)[[1]]
  expect_identical(p$feature_raw, "Q.S05")
  expect_identical(p$secondary_id, "Duplicate")
  f_uuid <- qci_query(db, "SELECT uuid FROM feature WHERE name = 'Q.S05'")$uuid
  others <- unlist(p[setdiff(names(p), c("feature_raw", "secondary_id"))], use.names = FALSE)
  expect_true(any(others %in% c("Q.S05", f_uuid)), label = "payload names the resolved feature")
  # non-blocking: Q.S05's rows are committed
  expect_true("Q.S05" %in% qci_samples(db)$feature)
  # a numeric secondary (an EPA point number) is never used: Q.MW02 commits, no conflict
  expect_true("Q.MW02" %in% qci_samples(db)$feature)
})

test_that("R-19.15: a field QC code commits as an ordinary sample on its own QC feature", {
  db <- qci_db_setup()
  qci_ingest(db, sec_path)
  s <- qci_samples(db)
  expect_equal(sum(s$feature == "Q.JD42"), 1)
  n <- qci_query(db, "SELECT count(*) AS n FROM analysis WHERE uuid_sample = ?",
                 params = list(s$uuid[s$feature == "Q.JD42"]))$n
  expect_gt(n, 0)
  # its column is not blocked as an unknown feature
  raw <- vapply(qci_payloads(qci_items(db, "unknown_feature")), function(x) x$feature_raw, "")
  expect_false("Q.JD42" %in% raw)
})

# ---- R-19.6 sample_lab_id ----------------------------------------------------------------

test_that("R-19.6: commit writes one sample_lab_id row per committed crosstab sample, lab_id normalised", {
  db <- qci_db_setup()
  qci_ingest(db, sec_path)
  s <- qci_samples(db)
  expect_setequal(s$feature, c("Q.MW02", "Q.MW08", "Q.S01", "Q.JD42", "Q.S05"))
  li <- qci_query(db, "SELECT * FROM sample_lab_id")
  # every committed sample counts, including those committed on a pending alias
  # (ruled 2026-10-19: qci_samples() sees only resolved ones)
  all_s <- qci_query(db, "SELECT s.uuid FROM \"sample\" s
                            JOIN project p ON p.uuid = s.uuid_project
                           WHERE p.name = ?", params = list(sec_wo))
  expect_equal(nrow(li), nrow(all_s))
  expect_true(all(li$work_order == sec_wo))
  expect_setequal(li$uuid_sample, all_s$uuid)
  by_client <- stats::setNames(li$lab_id, li$client_id)
  expect_identical(unname(by_client[c("Q.MW02", "Q.MW08", "Q.S01", "Q.JD42", "Q.S05")]),
                   sprintf("ES2537534-%03d", c(1L, 2L, 4L, 5L, 6L)))
  # the client_id is the IR's feature_raw, and the row points at that sample
  jd <- li[li$client_id == "Q.JD42", , drop = FALSE]
  expect_identical(jd$uuid_sample, s$uuid[s$feature == "Q.JD42"])
  expect_true(all(li$source_hash == hash_file(sec_path)))
})

test_that("R-19.6: ACIRL's synthetic <sheet>!c<col> ids are never written to sample_lab_id", {
  db_path <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  qc_create_tables(con)
  for (nm in c("B.G182", "B.G368", "B.G382")) fl_feature(con, nm, matrix = "air")
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS)
                       VALUES ('a-ch4', 'CH4', 'L/L', 1, 'gas', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant)
    VALUES ('lm-ch4', 'a-ch4', 'CH4 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(),
    "sampletidy.snapshot_dir" = withr::local_tempdir(),
    "sampletidy.remove_ingested" = FALSE))
  input <- withr::local_tempdir()
  build_gas_blaxland_2025(input, l1 = list(list(G182 = 0)), l2 = list(list(G368 = 0)),
                          l2_rows = 8, l3 = list(list(G382 = 0)))
  suppressMessages(suppressWarnings(ingest_dir(input, db = db_path)))
  n_s <- qci_query(db_path, "SELECT count(*) AS n FROM \"sample\" s
                               JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                               JOIN feature f ON f.uuid = fa.uuid_feature
                              WHERE f.name IN ('B.G182', 'B.G368', 'B.G382')")$n
  expect_gt(n_s, 0)                                            # reachability
  expect_equal(qci_query(db_path, "SELECT count(*) AS n FROM sample_lab_id")$n, 0)
})
