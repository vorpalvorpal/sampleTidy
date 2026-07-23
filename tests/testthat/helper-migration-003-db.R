# PLAN-15 E (dev/migrations/003-alias-date-bounds.R) - the POST-001-but-
# PRE-003 seed for dev/migrations/003-alias-date-bounds.R's own tests
# (test-migration-003.R).
#
# Neither existing helper can host these tests (cold audit 2026-07-23,
# findings 2/3/18, restated in PLAN-15's E.6 box): `helper-migration-db.R` is
# PRE-001 (11 `cypher` references - it seeds the schema 001 REPLACES, so it
# has no `feature_alias` table to bound at all), and `helper-db.R` is
# POST-003 already (its `feature_alias` DDL carries `date_start`/`date_end`
# since commit 0864e74) and contains none of the curated collision keys.
#
# CRITICALLY, this seed's `feature_alias` table does NOT declare
# `date_start`/`date_end` - unlike helper-db.R's. Migration 003's own job is
# `ALTER TABLE feature_alias ADD COLUMN date_start DATE; ADD COLUMN date_end
# DATE` (E.1, S-15.9: plain ADD COLUMN only, never a table rebuild - `DROP
# TABLE feature_alias` is refused, FK parent of `sample`). Pre-adding the
# columns here would make that ALTER TABLE step fail against this fixture
# with "column already exists" the first time a real migration script runs
# it - exactly backwards for a seed whose entire purpose is to exercise that
# step.
#
# FIXTURE NAMES, NOT LIVE LITERALS. E.5's 9 curated rows are DATA pinned
# against the live registry (`b.s01`, `k.e02`, ...) and are meaningless
# against any test fixture. This seed instead carries 9 rows that MIRROR
# E.5's shape - one per rule category, same non-NULL date_end / date_start
# counts (7 and 3) - under FIXTURE keys/names (`T.SRC01`..`T.SRC09`,
# `T.TGT01`.. / `TH.TGT03`, `TH.TGT07`), so a migration exercising the same
# mechanism against this seed produces the same COUNTS the plan pins,
# without requiring the literal live strings. See test-migration-003.R's
# header for the target-file contract this implies (an internal
# `.mig003_apply_bounds(con, bounds)` taking an injectable bounds table,
# called by `mig003_run()` with the real E.5 literals in production and
# called directly by the test with this seed's own fixture-scoped table).
#
# Every count in test-migration-003.R is relative to THIS seed, never to the
# live registry (E.6 box (ii)) - "9 itemised rows", "7 non-NULL date_end",
# "3 non-NULL date_start" are PLAN-pinned rule-shape counts, not live-registry
# sizes, and are reproduced exactly by construction below. Every OTHER count
# (row totals, complements) is asserted in the test file as a computed
# complement, never a hard-coded total.
#
# Shape, by feature:
#  - T.SRC01..T.SRC09: the 9 curated keys' own eponymous ("self-named")
#    feature. Each carries a `self` alias (auto_assign FALSE pre-migration -
#    migration 001's ambiguity rule marks EVERY arm of a key that reaches >1
#    feature FALSE) plus the curated non-self arm pointing at its target.
#    SRC01 and SRC07 ALSO carry an already-CONFIRMED `transcription_error`
#    duplicate-of-self arm (auto_assign TRUE already, `confirmed_by` set) -
#    mirroring E.5's `b.s01`/`k.e02` "already-TRUE" pair (R1's own worked
#    example).
#  - T.TGT01/02/04/06/08/09, TH.TGT03/07, T.TGT05: the 9 curated targets.
#    Each carries only its OWN ordinary `self` alias (auto_assign TRUE
#    already - typical case, unrelated to any ambiguity), under a DIFFERENT
#    alias_key from its source row.
#  - T.PLAIN01: NOT one of the 9 curated keys. Its `self` arm starts
#    auto_assign FALSE pre-migration for R-15.10 - the dedicated "universal
#    flip reaches an uninvolved feature too" fixture; without it R-15.10 is
#    unfalsifiable (E.6 box (iii) - the withdrawn self-alias-abort criterion
#    is the same defect class: a check that cannot fail on any existing
#    seed proves nothing).
#  - T.CTRL01..T.CTRL03: ordinary already-TRUE self aliases untouched by
#    anything the migration does - the "otherwise unchanged" control rows
#    R-15.19's checksum assertion needs (without them there is nothing left
#    in the seed for that assertion to be about, since every other row is
#    either a curated arm or R-15.10's own target).
#
# Rule-category mapping of the 9 curated (SRCnn -> TGTnn) rows, mirroring
# E.5 exactly in shape:
#   SRC01->TGT01, SRC02->TGT02, SRC03->TGT03(TH): EXACT rule-1 (single-sample
#     one-off) - POINT bound, date_start = date_end (R5).
#   SRC04->TGT04, SRC05->TGT05: PROXY rule-1 (target's-last-sample proxy) -
#     date_end only, date_start stays NULL (R5, unruled for proxies).
#   SRC06->TGT06, SRC07->TGT07(TH): rule-2 (recurring) - stays NULL/NULL.
#   SRC08->TGT08: rule-3 non-overlapping (retires) - date_end only.
#   SRC09->TGT09: rule-3 OVERLAPPING - date_end only.
# 7 of the 9 get a non-NULL date_end (all but SRC06/SRC07); 3 of those (the
# EXACT rule-1 rows) additionally get a non-NULL date_start equal to it.

.st_mig003_feature_ddl <- "
  CREATE TABLE feature (
    uuid VARCHAR PRIMARY KEY,
    name VARCHAR,
    site VARCHAR,
    date_end DATE,
    lon DOUBLE NOT NULL,
    lat DOUBLE NOT NULL
  )"

# Migration-001's post-001 `feature_alias` shape EXACTLY (001:368-381) -
# deliberately WITHOUT `date_start`/`date_end`. Migration 003 adds them.
.st_mig003_feature_alias_ddl <- "
  CREATE TABLE feature_alias (
    uuid VARCHAR PRIMARY KEY,
    uuid_feature VARCHAR,
    name VARCHAR NOT NULL,
    alias_key VARCHAR NOT NULL,
    kind VARCHAR,
    n_seen INTEGER DEFAULT 0,
    auto_assign BOOLEAN DEFAULT TRUE,
    first_seen TIMESTAMP,
    last_seen TIMESTAMP,
    confirmed_by VARCHAR,
    comments VARCHAR
  )"

# Empty-but-present tables: `.rc_load_registry()` (R/reconcile.R) does
# `SELECT * FROM <table>` unconditionally for all six of feature,
# feature_alias, feature_mask, analyte, lab_method, project - R-15.10's test
# is a real seam test through that function, so all six must EXIST (zero
# rows is fine; none of this unit's assertions touch them).
.st_mig003_empty_ddl <- list(
  feature_mask = "CREATE TABLE feature_mask (uuid_feature VARCHAR, variant VARCHAR, name VARCHAR)",
  analyte = "CREATE TABLE analyte (uuid VARCHAR PRIMARY KEY, name VARCHAR, units VARCHAR,
    conversion_constant DOUBLE, type VARCHAR, CAS VARCHAR)",
  lab_method = "CREATE TABLE lab_method (uuid VARCHAR PRIMARY KEY, uuid_analyte VARCHAR,
    name VARCHAR, method VARCHAR, organisation VARCHAR, rl_low DOUBLE, rl_high DOUBLE,
    reported_as VARCHAR, api VARCHAR, uuid_project VARCHAR, uuid_feature VARCHAR,
    comments VARCHAR, units VARCHAR, conversion_constant DOUBLE)",
  project = "CREATE TABLE project (uuid VARCHAR PRIMARY KEY, uuid_parent VARCHAR,
    uuid_root VARCHAR, name VARCHAR, type VARCHAR)"
)

#' Create a throwaway, POST-001/PRE-003 seed DuckDB for
#' dev/migrations/003-alias-date-bounds.R's own tests.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the calling test - see language-footguns.md's R section;
#'   the caller's frame is threaded through explicitly so cleanup does not
#'   fire before the calling test body runs).
#' @return path to the seeded, closed DuckDB file.
seed_migration_003_db <- function(dir = NULL) {
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "migration-003-seed.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  DBI::dbExecute(con, .st_mig003_feature_ddl)
  DBI::dbExecute(con, .st_mig003_feature_alias_ddl)
  for (ddl in .st_mig003_empty_ddl) DBI::dbExecute(con, ddl)

  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, lon, lat) VALUES
    ('mf-src01', 'T.SRC01', 'T', 150.3001, -33.3001),
    ('mf-src02', 'T.SRC02', 'T', 150.3002, -33.3002),
    ('mf-src03', 'T.SRC03', 'T', 150.3003, -33.3003),
    ('mf-src04', 'T.SRC04', 'T', 150.3004, -33.3004),
    ('mf-src05', 'T.SRC05', 'T', 150.3005, -33.3005),
    ('mf-src06', 'T.SRC06', 'T', 150.3006, -33.3006),
    ('mf-src07', 'T.SRC07', 'T', 150.3007, -33.3007),
    ('mf-src08', 'T.SRC08', 'T', 150.3008, -33.3008),
    ('mf-src09', 'T.SRC09', 'T', 150.3009, -33.3009),
    ('mf-tgt01', 'T.TGT01', 'T', 150.3011, -33.3011),
    ('mf-tgt02', 'T.TGT02', 'T', 150.3012, -33.3012),
    ('mf-tgt03', 'TH.TGT03', 'TH', 150.3013, -33.3013),
    ('mf-tgt04', 'T.TGT04', 'T', 150.3014, -33.3014),
    ('mf-tgt05', 'T.TGT05', 'T', 150.3015, -33.3015),
    ('mf-tgt06', 'T.TGT06', 'T', 150.3016, -33.3016),
    ('mf-tgt07', 'TH.TGT07', 'TH', 150.3017, -33.3017),
    ('mf-tgt08', 'T.TGT08', 'T', 150.3018, -33.3018),
    ('mf-tgt09', 'T.TGT09', 'T', 150.3019, -33.3019),
    ('mf-plain01', 'T.PLAIN01', 'T', 150.3021, -33.3021),
    ('mf-ctrl01', 'T.CTRL01', 'T', 150.3031, -33.3031),
    ('mf-ctrl02', 'T.CTRL02', 'T', 150.3032, -33.3032),
    ('mf-ctrl03', 'T.CTRL03', 'T', 150.3033, -33.3033)")

  # Self aliases: SRC*/PLAIN01 start auto_assign FALSE (migration-001's
  # ambiguity rule / the R-15.10 fixture); TGT*/CTRL* start already TRUE
  # (the typical, unambiguous case - 887 of 895 live self arms today).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen) VALUES
    ('ma-src01-self', 'mf-src01', 'T.SRC01', 't.src01', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src02-self', 'mf-src02', 'T.SRC02', 't.src02', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src03-self', 'mf-src03', 'T.SRC03', 't.src03', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src04-self', 'mf-src04', 'T.SRC04', 't.src04', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src05-self', 'mf-src05', 'T.SRC05', 't.src05', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src06-self', 'mf-src06', 'T.SRC06', 't.src06', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src07-self', 'mf-src07', 'T.SRC07', 't.src07', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src08-self', 'mf-src08', 'T.SRC08', 't.src08', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src09-self', 'mf-src09', 'T.SRC09', 't.src09', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt01-self', 'mf-tgt01', 'T.TGT01', 't.tgt01', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt02-self', 'mf-tgt02', 'T.TGT02', 't.tgt02', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt03-self', 'mf-tgt03', 'TH.TGT03', 'th.tgt03', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt04-self', 'mf-tgt04', 'T.TGT04', 't.tgt04', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt05-self', 'mf-tgt05', 'T.TGT05', 't.tgt05', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt06-self', 'mf-tgt06', 'T.TGT06', 't.tgt06', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt07-self', 'mf-tgt07', 'TH.TGT07', 'th.tgt07', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt08-self', 'mf-tgt08', 'T.TGT08', 't.tgt08', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-tgt09-self', 'mf-tgt09', 'T.TGT09', 't.tgt09', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-plain01-self', 'mf-plain01', 'T.PLAIN01', 't.plain01', 'self', 4, FALSE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-ctrl01-self', 'mf-ctrl01', 'T.CTRL01', 't.ctrl01', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-ctrl02-self', 'mf-ctrl02', 'T.CTRL02', 't.ctrl02', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-ctrl03-self', 'mf-ctrl03', 'T.CTRL03', 't.ctrl03', 'self', 4, TRUE, TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00')")

  # The 9 curated non-self arms - one per SRCnn->TGTnn pair, auto_assign
  # FALSE pre-migration (ambiguous key: SRCnn's alias_key now reaches 2
  # features). `kind` varies (historical_code/descriptive) to mirror E.5's
  # own mix; not itself asserted on.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen) VALUES
    ('ma-src01-cur', 'mf-tgt01', 'T.SRC01', 't.src01', 'historical_code', 1, FALSE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2024-03-10 00:00:00'),
    ('ma-src02-cur', 'mf-tgt02', 'T.SRC02', 't.src02', 'historical_code', 1, FALSE, TIMESTAMP '2019-01-01 00:00:00', TIMESTAMP '2021-06-15 00:00:00'),
    ('ma-src03-cur', 'mf-tgt03', 'T.SRC03', 't.src03', 'historical_code', 1, FALSE, TIMESTAMP '2022-01-01 00:00:00', TIMESTAMP '2023-09-01 00:00:00'),
    ('ma-src04-cur', 'mf-tgt04', 'T.SRC04', 't.src04', 'descriptive', 3, FALSE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2024-11-20 00:00:00'),
    ('ma-src05-cur', 'mf-tgt05', 'T.SRC05', 't.src05', 'descriptive', 2, FALSE, TIMESTAMP '2019-01-01 00:00:00', TIMESTAMP '2021-06-15 00:00:00'),
    ('ma-src06-cur', 'mf-tgt06', 'T.SRC06', 't.src06', 'descriptive', 5, FALSE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src07-cur', 'mf-tgt07', 'T.SRC07', 't.src07', 'descriptive', 4, FALSE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00'),
    ('ma-src08-cur', 'mf-tgt08', 'T.SRC08', 't.src08', 'historical_code', 2, FALSE, TIMESTAMP '2019-01-01 00:00:00', TIMESTAMP '2021-06-15 00:00:00'),
    ('ma-src09-cur', 'mf-tgt09', 'T.SRC09', 't.src09', 'historical_code', 2, FALSE, TIMESTAMP '2022-01-01 00:00:00', TIMESTAMP '2023-09-01 00:00:00')")

  # The two already-CONFIRMED transcription_error duplicate-of-self arms
  # (mirrors E.5's b.s01->B.S01 / k.e02->K.E02 pair - R1's own worked
  # example of an arm that already auto-resolves and must not regress).
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by) VALUES
    ('ma-src01-dup', 'mf-src01', 'T.SRC01', 't.src01', 'transcription_error', 1, TRUE, TIMESTAMP '2026-07-23 00:00:00', TIMESTAMP '2026-07-23 00:00:00', 'R. Shannon'),
    ('ma-src07-dup', 'mf-src07', 'T.SRC07', 't.src07', 'transcription_error', 1, TRUE, TIMESTAMP '2026-07-23 00:00:00', TIMESTAMP '2026-07-23 00:00:00', 'R. Shannon')")

  path
}

#' Open a read-write connection to a `seed_migration_003_db()` file.
#'
#' @param path path returned by `seed_migration_003_db()`.
#' @return an open DBI connection (caller must disconnect).
migration_003_con <- function(path) {
  DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
}
