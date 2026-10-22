# Exemptions in two duplicate checks (Robin's rulings, 2026-10-22).
# Fixture: dbc_db() (helper-db-checks.R). Nothing here touches the live DB.
#
# 1. dup_sample_identity_null_datetime is stream-aware (A91 D3). A NULL-datetime
#    group of samples sharing (alias, date, project) is flagged only when two
#    of its samples SHARE a stream. Stream, as A91 and .ct_sample_match()
#    define it: 'gas' when the analyte's type is 'gas', else
#    lab_method.organisation. A sample's streams are those of its analyses.
#    Test writer's choice (recommended in the brief, mirroring A91's "a sample
#    with no analyses matches any stream"): a sample with NO analyses shares a
#    stream with every other sample, so a group containing one IS flagged.
#    The key still contains the alias uuid.
# 2. dup_asset_hash compares hashes within a project (migration 061: one report
#    filed under more than one project is not a duplicate). Same hash under
#    different projects passes; same hash under one project fails. Test
#    writer's choice: two same-hash assets that both have a NULL uuid_project
#    are in the same (no-)project and ARE flagged. The key still contains the
#    hash.

# ---- seeding helpers (local to this file) ----------------------------------------------

.ex_null_sample <- function(con, uuid) {
  dbc_new_sample(con, uuid, alias = "fa-0002", date = "2025-06-01", datetime = NA, project = "p-0001")
}

.ex_analysis <- function(con, uuid, sample, lab) {
  dbc_exec(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified, rl_low)
                 VALUES (?, ?, ?, 1.5, TRUE, NULL)", uuid, sample, lab)
}

# A gas analyte with an ACIRL lab_method: stream 'gas', NOT 'ACIRL', although
# its organisation is ACIRL - the discriminating case for "type wins".
.ex_gas_method <- function(con) {
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS)
                       VALUES ('a-gas', 'Methane', '%', 'gas', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method (uuid, uuid_analyte, name, method, organisation, rl_low, units)
                       VALUES ('lm-gas', 'a-gas', 'Methane', NULL, 'ACIRL', NULL, '%')")
}


.ex_expect_pass <- function(db, name) {
  res <- dbc_run(db)
  r <- dbc_row(res, name)
  expect_equal(nrow(r), 1L)
  expect_identical(r$status, "pass", info = dbc_bad(res))
  # nothing else broken by the seeding either
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
}

# ---- dup_sample_identity_null_datetime ----------------------------------------------

test_that("null-datetime identity: an ALS-only sample beside an ACIRL-only sample is NOT flagged (A91 D3)", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-als")
    .ex_null_sample(con, "s-acirl")
    .ex_analysis(con, "an-als1", "s-als", "lm-0001")    # pH Value, ALS
    .ex_analysis(con, "an-als2", "s-als", "lm-0003")    # EC, ALS
    .ex_analysis(con, "an-ac1", "s-acirl", "lm-0005")   # pH, ACIRL
    .ex_analysis(con, "an-ac2", "s-acirl", "lm-0007")   # Temperature, ACIRL
  })
  .ex_expect_pass(db, "dup_sample_identity_null_datetime")
})

test_that("null-datetime identity: two ALS-only samples (one stream) are still flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-a1")
    .ex_null_sample(con, "s-a2")
    .ex_analysis(con, "an-a1", "s-a1", "lm-0001")
    .ex_analysis(con, "an-a2", "s-a2", "lm-0003")
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

test_that("null-datetime identity: two ACIRL-only samples are still flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-c1")
    .ex_null_sample(con, "s-c2")
    .ex_analysis(con, "an-c1", "s-c1", "lm-0005")
    .ex_analysis(con, "an-c2", "s-c2", "lm-0006")
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

test_that("null-datetime identity: a sample with no analyses beside a stream's sample IS flagged (matches any stream)", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-full")
    .ex_null_sample(con, "s-empty")
    .ex_analysis(con, "an-f1", "s-full", "lm-0001")
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

test_that("null-datetime identity: a gas-only sample beside an ACIRL field sample is cross-stream, NOT flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_gas_method(con)
    .ex_null_sample(con, "s-gas")
    .ex_null_sample(con, "s-field")
    .ex_analysis(con, "an-g1", "s-gas", "lm-gas")       # Methane: type gas, org ACIRL
    .ex_analysis(con, "an-fd1", "s-field", "lm-0005")   # pH, ACIRL field
  })
  .ex_expect_pass(db, "dup_sample_identity_null_datetime")
})

test_that("null-datetime identity: two gas-only samples share the gas stream and are flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_gas_method(con)
    .ex_null_sample(con, "s-g1")
    .ex_null_sample(con, "s-g2")
    .ex_analysis(con, "an-g1", "s-g1", "lm-gas")
    .ex_analysis(con, "an-g2", "s-g2", "lm-gas")
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

test_that("null-datetime identity: a mixed ALS+ACIRL sample beside an ACIRL-only sample shares ACIRL and is flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-mix")
    .ex_null_sample(con, "s-ac")
    .ex_analysis(con, "an-m1", "s-mix", "lm-0001")   # ALS
    .ex_analysis(con, "an-m2", "s-mix", "lm-0006")   # ACIRL
    .ex_analysis(con, "an-m3", "s-ac", "lm-0007")    # ACIRL
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

test_that("null-datetime identity: ALS + ACIRL + a second ALS sample in one group is flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    .ex_null_sample(con, "s-x1")
    .ex_null_sample(con, "s-x2")
    .ex_null_sample(con, "s-x3")
    .ex_analysis(con, "an-x1", "s-x1", "lm-0001")    # ALS
    .ex_analysis(con, "an-x2", "s-x2", "lm-0005")    # ACIRL
    .ex_analysis(con, "an-x3", "s-x3", "lm-0003")    # ALS
  })
  dbc_expect_only(dbc_run(db), "dup_sample_identity_null_datetime", key = "fa-0002")
})

# ---- dup_asset_hash --------------------------------------------------------------------

test_that("asset hash: the same hash under two different projects is NOT flagged (061)", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'a.pdf', 'p-0003', ?)",
             dbc_hex(904), dbc_hex(904))
  })
  .ex_expect_pass(db, "dup_asset_hash")
})

test_that("asset hash: the same hash twice under one project is flagged, keyed by the hash", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'b.pdf', 'p-0001', ?)",
             dbc_hex(904), dbc_hex(904))
  })
  dbc_expect_only(dbc_run(db), "dup_asset_hash", key = dbc_hex(904))
})

test_that("asset hash: a hash under two projects, twice in one of them, is flagged once", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', 'p-0001', ?), ('as-x2', 'b.pdf', 'p-0001', ?),
                   ('as-x3', 'a.pdf', 'p-0003', ?)",
             dbc_hex(904), dbc_hex(904), dbc_hex(904))
  })
  dbc_expect_only(dbc_run(db), "dup_asset_hash", key = dbc_hex(904))
})

test_that("asset hash: two same-hash assets with no project are one (no-)project and are flagged", {
  db <- dbc_db()
  dbc_with(db, function(con) {
    dbc_exec(con, "INSERT INTO asset (uuid, name, uuid_project, hash) VALUES
                   ('as-x1', 'a.pdf', NULL, ?), ('as-x2', 'b.pdf', NULL, ?)",
             dbc_hex(904), dbc_hex(904))
  })
  dbc_expect_only(dbc_run(db), "dup_asset_hash", key = dbc_hex(904))
})
