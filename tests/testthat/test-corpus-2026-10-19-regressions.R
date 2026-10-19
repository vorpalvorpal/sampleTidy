# Regressions from the 2026-10-19 corpus rehearsal
# (scratchpad/2026-10-19-corpus/; diagnosis in dev/plans/PLAN-15 B.4 and
# PLAN-09 R-9.14, both marked "2026-10-19 corpus finding").
#
# C  Non-idempotent re-ingest across the pending/resolved boundary. A raw
#    point label (`B.G1`) first resolved by the Layer-2 structural parse onto a
#    live feature (`B.G001`). A LATER workbook, dated after that feature's
#    `date_end`, failed B.5 liveness and so minted a pending alias for the same
#    key (`b.g1`). From then on the B.4 gate (`.rc_alias_rows_exist()`) keeps
#    the key away from Layer 2 for EVERY date, so re-ingesting the first
#    workbook made the row feature-pending; `.rc_find_existing()` then looked
#    only on the pending alias's samples, found nothing, and the same
#    measurement committed a second time (99 B.G* rows of
#    `2400-7127-05 May 2021 Monthly Gas Monitoring Blaxland WMF.XLS`).
#    Gas has no work-order re-ingest guard, so this row-level lookup is the
#    only thing standing between a re-issued gas workbook and duplicates.
#
# D  `.ct_ensure_report_project()` fills in the parent of an EXISTING ACIRL
#    report row through `db_update()`. When that report row is already the
#    parent of another project row (2400-7399-04 -> ES2610538), duckdb 1.4.1
#    runs the UPDATE as delete+insert and the project self-FK refuses it:
#    "Violates foreign key constraint because key uuid_parent: ... is still
#    referenced". The whole event rolls back (5 workbooks failed). The test
#    schema (helper-db.R) carries no project self-FK, which is why no existing
#    test saw it; `fk_project_table()` below rebuilds `project` with the live
#    constraint.
#
# Synthetic fixtures on seed_db(); driven through the real reconcile_event()
# and commit_event(). Nothing touches a live database.

# ---- local helpers (verbatim shapes from test-commit.R) -----------------------

rg_setup <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(
    list("sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env)),
    .local_envir = env
  )
  list(con = con, src = withr::local_tempdir(.local_envir = env))
}

# A reconciled source file of its own (distinct bytes, distinct hash).
rg_file <- function(s, filename, work_order) {
  path <- file.path(s$src, filename)
  writeLines(paste("SampleCode,ChemCode", filename), path)
  hash <- hash_file(path)
  DBI::dbExecute(s$con, "INSERT INTO ingest_file
    (hash, filename, path_first_seen, state, work_order, revision)
    VALUES (?, ?, ?, 'reconciled', ?, 0)",
    params = list(hash, basename(path), path, work_order))
  list(hash = hash, files = tibble::tibble(hash = hash, filename = basename(path),
                                           adapter = "esdat/1", rank = 3L, kept = TRUE))
}

rg_row <- function(...) {
  defaults <- list(
    source_hash = "hash-1", source_ref = "row1", work_order = "XX1234567",
    revision = 0L, org = "ALS", adapter = "esdat/1",
    lab_sample_id = "XX1234567001", sample_type = "Normal",
    feature_raw = "T.S01", analyte_raw = "Fluoride",
    cas_number = "16984-48-8", method_raw = "EK040P: Fluoride by PC Titrator",
    total_or_filtered = "T", units_raw = "mg/L", value_raw = "0.4",
    value_num = 0.4, value_chr = NA_character_, below_detection = FALSE,
    rl = 0.1, lab_qualifier = NA_character_, analysed_date = as.Date("2025-05-26"),
    comments = NA_character_, confidence = 1,
    sample_datetime_raw = "24 May 2025 11:45", sampler = NA_character_,
    matrix_raw = "WATER", parent_sample = NA_character_
  )
  tibble::as_tibble(utils::modifyList(defaults, list(...)))
}

rg_reconcile_event <- function(results, work_order) {
  list(
    work_order = work_order, orphan = FALSE, results = results,
    samples = tibble::tibble(),
    files = tibble::tibble(hash = character(), filename = character(),
                           adapter = character(), rank = integer(), kept = logical()),
    report = list(n_results = nrow(results), n_by_sample_type = list(),
                  n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                           reason = character()),
                  warnings = character())
  )
}

rg_commit_event <- function(files, work_order) {
  list(
    work_order = work_order, orphan = FALSE,
    results = tibble::tibble(), samples = tibble::tibble(),
    files = files,
    report = list(n_results = 0L, n_by_sample_type = list(), n_ncp_foreign = 0L,
                  skipped = tibble::tibble(hash = character(), source_ref = character(),
                                           reason = character()),
                  warnings = character())
  )
}

# One file -> reconcile -> commit, under its own (first-time) work order, so
# the F.10 work-order guard never fires and only row-level identity decides.
rg_ingest <- function(s, filename, work_order, rows) {
  f <- rg_file(s, filename, work_order)
  rows$source_hash <- f$hash
  rows$work_order <- work_order
  resolved <- reconcile_event(rg_reconcile_event(rows, work_order), s$con)
  commit_event(rg_commit_event(f$files, work_order), resolved, s$con)
  resolved
}

rg_count <- function(con, table) {
  DBI::dbGetQuery(con, sprintf('SELECT count(*) AS n FROM "%s"', table))$n
}

# ---- C: re-ingest across the pending/resolved boundary ------------------------

test_that("2026-10-19 C: a structurally-resolved row re-ingested after a pending alias was minted for the same key adds no sample and no analysis", {
  s <- rg_setup()
  con <- s$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  # f-0006 T.S06 (helper-db.R) is live until 2020-06-30 - the B.G001 shape
  # (live until 2023-02-08). `T S6` reaches no alias row, so Layer 2 parses it.

  # 1. The original workbook: dated while T.S06 is live -> structural hit.
  first <- rg_ingest(s, "XX1000001.csv", "XX1000001", rg_row(
    source_ref = "r1", feature_raw = "T S6", lab_sample_id = "XX1000001001",
    sample_datetime_raw = "01 May 2019 09:00"
  ))
  r1 <- first$clean[first$clean$source_ref == "r1", ]
  expect_equal(nrow(r1), 1)
  expect_false(r1$feature_pending)                 # positive control: Layer 2 ran
  expect_identical(r1$uuid_feature, "f-0006")

  # 2. A later workbook, dated after T.S06's date_end: B.5 empties the hit, the
  #    row goes pending and commit mints the dangling alias `t s6`.
  rg_ingest(s, "XX1000002.csv", "XX1000002", rg_row(
    source_ref = "r1", feature_raw = "T S6", lab_sample_id = "XX1000002001",
    sample_datetime_raw = "01 Jun 2025 09:00"
  ))
  pend <- DBI::dbGetQuery(con, "SELECT uuid FROM feature_alias
                                 WHERE alias_key = 't s6' AND uuid_feature IS NULL")
  expect_equal(nrow(pend), 1)                      # the precondition the bug needs

  n_sample <- rg_count(con, "sample")
  n_analysis <- rg_count(con, "analysis")

  # 3. The first workbook again, in different bytes (a re-save / re-issue), plus
  #    one genuinely new reading on the pending key so the fix cannot simply
  #    stop committing pending rows.
  third <- rg_ingest(s, "XX1000003.csv", "XX1000003", dplyr::bind_rows(
    rg_row(source_ref = "r1", feature_raw = "T S6", lab_sample_id = "XX1000003001",
           sample_datetime_raw = "01 May 2019 09:00"),
    rg_row(source_ref = "r2", feature_raw = "T S6", lab_sample_id = "XX1000003002",
           sample_datetime_raw = "15 Jul 2025 09:00")
  ))

  # The 2019 measurement is already in the DB, on T.S06's self-alias sample.
  dup <- third$skipped[third$skipped$source_ref == "r1", ]
  expect_equal(nrow(dup), 1)
  expect_identical(dup$reason, "already_present")
  expect_false("r1" %in% third$clean$source_ref)

  # Exactly one new sample and one new analysis: r2's, never r1's twin.
  expect_equal(rg_count(con, "sample"), n_sample + 1)
  expect_equal(rg_count(con, "analysis"), n_analysis + 1)
  on_t_s06 <- DBI::dbGetQuery(con, "
    SELECT count(*) AS n FROM analysis a
      JOIN \"sample\" s ON s.uuid = a.uuid_sample
     WHERE CAST(s.date AS DATE) = DATE '2019-05-01'")$n
  expect_equal(on_t_s06, 1)

  # B.4 still holds for NEW data: r2 stays on the pending alias, unresolved.
  r2 <- third$clean[third$clean$source_ref == "r2", ]
  expect_equal(nrow(r2), 1)
  expect_true(r2$feature_pending)
})

# ---- D: report-parent fill on a referenced project row ------------------------

# Rebuild `project` with the live self-FK and indexes (live DDL, plus the
# FOREIGN KEY duckdb_constraints() reports: project.uuid_parent ->
# project.uuid; indexes idx_project_uuid_parent / idx_project_uuid_root).
fk_project_table <- function(con) {
  rows <- DBI::dbGetQuery(con, "SELECT * FROM project")
  DBI::dbExecute(con, "DROP TABLE project")
  DBI::dbExecute(con, "
    CREATE TABLE project (
      uuid VARCHAR PRIMARY KEY,
      uuid_parent VARCHAR,
      uuid_root VARCHAR,
      uuid_project VARCHAR,
      name VARCHAR,
      type VARCHAR,
      purpose VARCHAR,
      date_start TIMESTAMP,
      date_end TIMESTAMP,
      regulated_by VARCHAR,
      cypher VARCHAR,
      site VARCHAR,
      value VARCHAR,
      FOREIGN KEY (uuid_parent) REFERENCES project(uuid)
    )")
  DBI::dbExecute(con, "CREATE INDEX idx_project_uuid_parent ON project(uuid_parent)")
  DBI::dbExecute(con, "CREATE INDEX idx_project_uuid_root ON project(uuid_root)")
  stopifnot(all(is.na(rows$uuid_parent)))   # seed rows are roots: no order needed
  if (nrow(rows) > 0) DBI::dbAppendTable(con, "project", rows[, intersect(names(rows),
    DBI::dbListFields(con, "project")), drop = FALSE])
  invisible(NULL)
}

fk_seed_project <- function(con, name, type = "Work order",
                            parent = NA_character_, root = NA_character_) {
  u <- uuid::UUIDgenerate()
  DBI::dbExecute(con,
    "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type) VALUES (?, ?, ?, ?, ?)",
    params = list(u, parent, if (is.na(root)) u else root, name, type))
  u
}

fk_project <- function(con, name) {
  DBI::dbGetQuery(con, "SELECT uuid, uuid_parent, uuid_root FROM project WHERE name = ?",
                  params = list(name))
}

# An ACIRL field event as assembly builds one (the a80_event() shape,
# test-commit.R): no home work order, a report number, cited ALS orders.
fk_event <- function(s, report_no, cited) {
  path <- file.path(s$src, sprintf("%s April 2024 Monthly Blaxland WMF.xls", report_no))
  writeLines(sprintf("acirl workbook %s", report_no), path)
  hash <- hash_file(path)
  DBI::dbExecute(s$con,
    "INSERT INTO ingest_file (hash, filename, path_first_seen, state, work_order, revision)
     VALUES (?, ?, ?, 'reconciled', NULL, 0)",
    params = list(hash, basename(path), path))
  list(
    hash = hash,
    event = list(
      work_order = NA_character_, orphan = TRUE,
      results = tibble::tibble(), samples = tibble::tibble(),
      files = tibble::tibble(hash = hash, kept = TRUE),
      report = list(sources = stats::setNames(list(list(
        hash = hash, filename = basename(path), report_no = report_no,
        als_work_orders = cited, feature_aliases = list(), als_candidates = list()
      )), hash))
    )
  )
}

fk_clean <- function(hash, report_no) {
  tibble::tibble(
    source_hash = hash, source_ref = "r1", work_order = report_no, revision = 0L,
    org = "ACIRL", adapter = "acirl_field_xlsx/1", lab_sample_id = NA_character_,
    sample_type = "Normal", feature_raw = "T.S01", analyte_raw = "pH Value",
    cas_number = NA_character_, method_raw = "EA005P: pH by PC Titrator",
    total_or_filtered = "T", units_raw = "pH Unit", value_raw = "6.50", value_num = 6.50,
    value_chr = NA_character_, below_detection = FALSE, rl = NA_real_,
    lab_qualifier = NA_character_, analysed_date = as.Date("2024-04-10"),
    comments = NA_character_, confidence = 1, sample_datetime_raw = "10 Apr 2024",
    sampler = NA_character_, matrix_raw = "WATER", parent_sample = NA_character_,
    uuid_feature = "f-0001", uuid_lab = "lm-0001", uuid_analyte = "a-0001",
    value_converted = 6.50, rl_converted = NA_real_,
    sample_date = as.Date("2024-04-10"), sample_datetime = as.POSIXct(NA),
    supersedes = NA_character_
  )
}

test_that("2026-10-19 D: the fixture reproduces the duckdb 1.4.1 quirk - an UPDATE of a project row that another project row references is refused", {
  # Pins the PREMISE of the next test, so it cannot pass vacuously on a schema
  # that lost the FK. If a future duckdb lifts the limitation this fails and
  # says so; the next test's decided behaviour still stands on its own.
  s <- rg_setup()
  con <- s$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  fk_project_table(con)
  camp <- fk_seed_project(con, "Monthly monitoring", type = NA_character_)
  rep <- fk_seed_project(con, "2400-7399-04", type = "ACIRL report")
  fk_seed_project(con, "ES2610538", parent = rep, root = rep)
  expect_error(
    DBI::dbExecute(con, "UPDATE project SET uuid_parent = ?, uuid_root = ? WHERE uuid = ?",
                   params = list(camp, camp, rep)),
    "foreign key"
  )
})

test_that("2026-10-19 D: a report row that is already some project's parent is never UPDATEd by commit; the event commits and the cited order keeps its campaign, flagged", {
  s <- rg_setup()
  con <- s$con
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  fk_project_table(con)

  # The live shape (pristine copy, 2026-10-19): report 2400-7399-04 is a ROOT
  # with child ES2610538 (filed 2026-10-17 from `2400-7399-04 Monthly Blaxland
  # WMF .xls`). The April-2024 workbook carrying the same report number cites
  # an order that sits under the campaign `Monthly monitoring`, so
  # `.ct_ensure_report_project()` derives a grandparent and tries to fill the
  # report's empty parent.
  camp <- fk_seed_project(con, "Monthly monitoring", type = NA_character_)
  rep <- fk_seed_project(con, "2400-7399-04", type = "ACIRL report")
  kid <- fk_seed_project(con, "ES2610538", parent = rep, root = rep)
  wo <- fk_seed_project(con, "ES2412736", parent = camp, root = camp)

  ev <- fk_event(s, "2400-7399-04", cited = "ES2412736")
  n_analysis <- rg_count(con, "analysis")
  res <- tryCatch(
    commit_event(ev$event, list(clean = fk_clean(ev$hash, "2400-7399-04"),
                                review = tibble::tibble(), skipped = tibble::tibble(),
                                counts = c(new = 1L)), con),
    error = function(e) e
  )
  expect_false(inherits(res, "error"),
               label = if (inherits(res, "error")) conditionMessage(res) else "commit_event()")

  # The data lands.
  expect_equal(rg_count(con, "analysis"), n_analysis + 1)
  st <- DBI::dbGetQuery(con, "SELECT state FROM ingest_file WHERE hash = ?",
                        params = list(ev$hash))$state
  expect_true(st %in% c("archived", "needs_review"))

  # The referenced report row is untouched: still a root, no update logged.
  r <- fk_project(con, "2400-7399-04")
  expect_identical(r$uuid[[1]], rep)
  expect_true(is.na(r$uuid_parent[[1]]))
  expect_identical(r$uuid_root[[1]], rep)
  upd <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log
                                WHERE tbl = 'project' AND action = 'update' AND uuid_row = ?",
                         params = list(rep))$n
  expect_equal(upd, 0)
  k <- fk_project(con, "ES2610538")
  expect_identical(k$uuid[[1]], kid)
  expect_identical(k$uuid_parent[[1]], rep)

  # The cited order's existing parent stands (A80's "existing parent stands,
  # anomaly made loud"), and its samples still attach to it.
  expect_identical(fk_project(con, "ES2412736")$uuid_parent[[1]], camp)
  rq <- DBI::dbGetQuery(con, "SELECT kind, uuid_target, status FROM review_queue
                               WHERE kind = 'project_parent_conflict'")
  expect_equal(nrow(rq), 1)
  expect_identical(rq$uuid_target, wo)
  new_proj <- DBI::dbGetQuery(con, "
    SELECT DISTINCT s.uuid_project FROM \"sample\" s
      JOIN analysis a ON a.uuid_sample = s.uuid
     WHERE CAST(s.date AS DATE) = DATE '2024-04-10'")$uuid_project
  expect_identical(new_proj, wo)
})
