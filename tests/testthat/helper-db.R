# Seed database helpers for the sampleTidy test suite.
#
# Defines seed_db() and seed_con() exactly per dev/plans/FIXTURES.md
# "Seed DB" section. This file only DEFINES functions - no top-level calls -
# so it can be sourced even before any production R/ functions exist.
#
# seed_db() creates a throwaway DuckDB file, runs the plan-01 ensure_schema()
# migrations (ops tables), creates the CONTRACT core tables (feature,
# feature_alias, feature_mask, analyte, lab_method, project, sample, analysis)
# and inserts exactly the rows pinned in FIXTURES.md. Helpers must not depend
# on the live monitoring.duckdb.
#
# Plan 11 (feature_alias indirection, A48-A55): `sample` no longer points at
# `feature` directly - it points at the alias it arrived under
# (`uuid_feature_alias`, NOT NULL), which nullably resolves to a `feature`.
# Every feature has a self-alias. `lab_method.uuid_analyte` and
# `feature_alias.uuid_feature` are both nullable (dangling = unresolved).
#
# REVISED 2026-07-22 (A63/A65/A67 - A51 is SUPERSEDED, read A63 instead):
# `analysis` gains NO units column of any kind. Units live on `lab_method`,
# which gains `units VARCHAR` (a FALLBACK for interpreting a value, never an
# assertion about a particular report, and never part of the method's
# identity) and `conversion_constant DOUBLE` (multiplied into a matched row's
# value when non-NA; NA means no conversion). `feature` gains
# `lon DOUBLE NOT NULL, lat DOUBLE NOT NULL` (live schema; the previous
# "virtual is TEST-ONLY drift" comment was wrong - the live table has it,
# A67). The seed also carries the R-11.19/A65 fixture: two `lab_method` rows
# differing only in name capitalisation, same organisation/method, one
# analyte.

# DDL for the CONTRACT core tables, named list keyed by table name.
.st_test_core_ddl <- list(
  feature = "
    CREATE TABLE feature (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      site VARCHAR,
      flow VARCHAR,
      matrix VARCHAR,
      geom_wkt VARCHAR,
      -- `virtual` IS part of the live shape (19 cols, 894 rows all FALSE;
      -- A67) - the earlier 'TEST-ONLY drift' claim was measured against the
      -- dashboard's DERIVED copy, not the authoritative DB. Marks a
      -- non-physical feature (e.g. WEM.data SILO-grid weather stations),
      -- which still carry real (grid-centre) lon/lat - not a placeholder
      -- mechanism.
      virtual BOOLEAN,
      -- date_start/date_end DO exist live (CONTRACT.md, corrected block) and
      -- were missing from the test DDL (plan-11 cold review C11). With
      -- site-narrowing deferred (D9), date_end is the ONLY narrowing rule
      -- left in R-11.4 - without this column that criterion is unreachable.
      date_start DATE,
      date_end DATE,
      -- lon/lat ARE DOUBLE NOT NULL live (R-11.17); the earlier omission is
      -- what let a broken add_feature() (missing lon/lat args) stay green.
      lon DOUBLE NOT NULL,
      lat DOUBLE NOT NULL
    )",
  feature_alias = "
    CREATE TABLE feature_alias (
      uuid VARCHAR PRIMARY KEY,
      uuid_feature VARCHAR,               -- NULLABLE: NULL = dangling
      name VARCHAR NOT NULL,              -- raw, as seen ('bs03alt')
      alias_key VARCHAR NOT NULL,         -- .mig001_normalize(name) = tolower(trimws);
                                           --   punctuation PRESERVED (PLAN-15); NOT unique
      kind VARCHAR,                       -- self | historical_code |
                                           --   descriptive | transcription_error |
                                           --   mask_long | pending
      n_seen INTEGER DEFAULT 0,
      auto_assign BOOLEAN DEFAULT TRUE,   -- FALSE = suggest only, never resolve
      first_seen TIMESTAMP,
      last_seen TIMESTAMP,
      confirmed_by VARCHAR,               -- NULL = unconfirmed guess
      comments VARCHAR,
      -- PLAN-15 E.1 (migration 003-alias-date-bounds.R, not yet written):
      -- DATE, not TIMESTAMP - feature.date_start/date_end are DATE and a
      -- TIMESTAMP column here would reintroduce the tz hazard E.5 documents.
      -- Both NULLABLE; NULL means unbounded on that side. Distinct from
      -- first_seen/last_seen (those record when ingest last OBSERVED the
      -- string; these record when the alias is VALID) - do not conflate.
      -- Production adds these via plain ALTER TABLE ADD COLUMN, never a
      -- table rebuild (DROP TABLE feature_alias is refused - FK parent of
      -- `sample`); the two DDL sites are 001:368-381 (pre-003 shape, left
      -- as-is - it defines the historical baseline a pre-003 DB fixture
      -- would need) and this file (must carry the post-003 shape so any
      -- Work-E test can run at all).
      date_start DATE,
      date_end DATE
    )
    -- No DB uniqueness on name/alias_key (R-11.1): the domain forbids it -
    -- the same string may legitimately map to different features at
    -- different times. Identity is the alias's own uuid.
  ",
  feature_mask = "
    CREATE TABLE feature_mask (
      uuid_feature VARCHAR,
      variant VARCHAR,
      name VARCHAR
    )",
  analyte = "
    CREATE TABLE analyte (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      units VARCHAR,
      conversion_constant DOUBLE,
      type VARCHAR,
      CAS VARCHAR
    )",
  lab_method = "
    CREATE TABLE lab_method (
      uuid VARCHAR PRIMARY KEY,
      -- uuid_analyte is nullable (R-11.2): NULL = dangling (unknown analyte).
      -- No NOT NULL was ever declared here, so no DDL change was needed for
      -- this - the test schema was already permissive; noted per the plan.
      uuid_analyte VARCHAR,
      name VARCHAR,
      method VARCHAR,
      organisation VARCHAR,
      rl_low DOUBLE,
      rl_high DOUBLE,
      reported_as VARCHAR,
      api VARCHAR,
      uuid_project VARCHAR,
      uuid_feature VARCHAR,
      comments VARCHAR,
      -- R-11.2/A63 (D7 reversed): units restored here, NOT on `analysis`.
      -- units is a FALLBACK for interpreting a value under this method - it
      -- does NOT assert any particular report used that unit - and is NEVER
      -- part of the method's identity (organisation, name, method); a units
      -- change must never spawn a second lab_method row.
      units VARCHAR,
      -- Multiplied into a matched row's reported value when non-NA; NA means
      -- no conversion. That product is what analysis.value stores.
      conversion_constant DOUBLE
    )",
  project = "
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
      value VARCHAR
    )",
  sample = "
    CREATE TABLE \"sample\" (
      uuid VARCHAR PRIMARY KEY,
      -- R-11.2/A48: uuid_feature is DROPPED. A sample points at the alias it
      -- arrived under, never at a feature directly; the alias resolves
      -- (nullably) to a feature. Every feature has a self-alias, so a
      -- correctly-labelled sample points at an alias too.
      uuid_feature_alias VARCHAR NOT NULL,
      uuid_project VARCHAR,
      date TIMESTAMP,
      date_start TIMESTAMP,
      datetime TIMESTAMP,
      datetime_start TIMESTAMP,
      organisation VARCHAR,
      person VARCHAR,
      purpose VARCHAR,
      comments VARCHAR
    )",
  analysis = "
    CREATE TABLE analysis (
      uuid VARCHAR PRIMARY KEY,
      uuid_sample VARCHAR,
      uuid_lab VARCHAR,
      value DOUBLE,
      value_chr VARCHAR,
      quantified BOOLEAN,
      rl_low DOUBLE,
      rl_high DOUBLE,
      -- R-11.2/A63 (A51 SUPERSEDED - `analysis` gets NO units column of any
      -- kind; units live on lab_method.units instead). `value` is canonical
      -- iff the row's lab_method.uuid_analyte is non-NULL; when dangling,
      -- value is in the METHOD's units (safe because a dangling analysis is
      -- invisible to every view - INNER JOIN through analyte).
      purpose VARCHAR,
      comments VARCHAR
    )",
  # No rows pinned by FIXTURES.md "Seed DB" for `asset` - empty table only,
  # provided so plan-09/10 tests (archive_file()/commit_event()'s archival
  # step) have a real table to write into. See PLAN-CHANGE-REQUESTS.md
  # [pipeline-tests] R-9.2/R-9.3.
  asset = "
    CREATE TABLE asset (
      uuid VARCHAR PRIMARY KEY,
      name VARCHAR,
      date TIMESTAMP,
      file_format VARCHAR,
      type VARCHAR,
      purpose VARCHAR,
      organisation VARCHAR,
      person VARCHAR,
      uuid_project VARCHAR,
      uuid_feature VARCHAR,
      filename VARCHAR,
      hash VARCHAR,
      comments VARCHAR
    )"
)

#' Create a throwaway seed DuckDB for tests (FIXTURES.md "Seed DB")
#'
#' Creates a DuckDB file in `dir`, runs `ensure_schema()` (the plan-01 ops
#' migrations), creates the CONTRACT core tables, and inserts exactly the
#' rows pinned in dev/plans/FIXTURES.md. Returns the (closed) db path.
#'
#' @param dir directory to hold the DB file (defaults to a fresh withr temp
#'   dir scoped to the calling test)
#' @return path to the seeded DuckDB file
seed_db <- function(dir = NULL) {
  # NB: a bare `withr::local_tempdir()` used as a *default argument* would bind
  # its deferred cleanup to seed_db()'s own frame (default-arg promises evaluate
  # in the function's frame), deleting the tempdir the instant seed_db() returns
  # and handing the caller a dead path. Register the cleanup on the *caller's*
  # frame instead so the DB lives for the whole calling test.
  if (is.null(dir)) dir <- withr::local_tempdir(.local_envir = parent.frame())
  path <- file.path(dir, "seed.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  # Plan-01 ops migrations (ingest_file, ingest_sighting, review_queue,
  # change_log, schema_version).
  ensure_schema(con)

  # CONTRACT core tables (not part of ensure_schema() - those mirror the
  # pre-existing live monitoring.duckdb business schema). feature_alias is
  # NOT in ensure_schema() either (A50: ops-tables-only); it is declared here
  # for tests and created live by the plan-11 migration.
  for (ddl in .st_test_core_ddl) DBI::dbExecute(con, ddl)

  # feature. f-0001..f-0003 are the original three (unchanged uuids/names).
  # f-0004..f-0007 are added for the plan-11 alias-narrowing fixtures below:
  #  - f-0004/f-0005: the ambiguous-key pair (never narrows - both live).
  #  - f-0006/f-0007: the reused-key pair where f-0006 is defunct
  #    (date_end 2020-06-30, long before any fixture sample date) and
  #    f-0007 is still live - the date_end narrowing auto-resolve case.
  # PLAN-15 F1 (BLOCKING): `site` is now the NAME PREFIX ('T'), not the old
  # 'TestSite' literal - the live invariant is name-prefix == site for every
  # feature (PLAN-15 B.1/B.3), and Work B reads the site SET from this COLUMN.
  # Leaving it as 'TestSite' would make the fixture's site set {"TestSite"}
  # and no Work-B structural test could ever produce a real hit.
  # f-0008/f-0009 add a prefix-EXTENDING second site 'TH' (so longest-match
  # must beat 'T' - mirrors the live BH-before-B case). f-0010/f-0011 are the
  # F3 digit-width pair (T.G### 3-wide vs TH.G## 2-wide). f-0012 is the F6
  # structural target for the dangling-alias/idempotency fixture below.
  # PLAN-15 F8 (audit delta 4): f-0013 'Q.S01' with site 'Z' is the ONLY row
  # where the name prefix DISAGREES with the `site` column. Without it every
  # B.1 assertion is unfalsifiable: an implementation that derives the site
  # set from a `feature.name` prefix parse instead of the COLUMN produces the
  # identical set on a fixture where the two always agree. With this row the
  # column-read set contains 'Z' and never 'Q', and B.3's "a feature whose
  # name prefix != its site is EXCLUDED from the structural index" becomes a
  # live rule rather than an empty branch. It carries a self-alias like every
  # other feature, so a prefix-parsing implementation WOULD auto-resolve the
  # raw 'Q S01' - which is exactly what the B.1 test now forbids.
  DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat) VALUES
    ('f-0001', 'T.S01', 'T', 'surface', 'water', NULL, 150.0001, -33.0001),
    ('f-0002', 'T.S02', 'T', 'surface', 'water', NULL, 150.0002, -33.0002),
    ('f-0003', 'T.MW01', 'T', NULL, 'groundwater', NULL, 150.0003, -33.0003),
    ('f-0004', 'T.S04', 'T', 'surface', 'water', NULL, 150.0004, -33.0004),
    ('f-0005', 'T.S05', 'T', 'surface', 'water', NULL, 150.0005, -33.0005),
    ('f-0006', 'T.S06', 'T', 'surface', 'water', DATE '2020-06-30', 150.0006, -33.0006),
    ('f-0007', 'T.S07', 'T', 'surface', 'water', NULL, 150.0007, -33.0007),
    ('f-0008', 'TH.S01', 'TH', 'surface', 'water', NULL, 150.1008, -33.1008),
    ('f-0009', 'TH.MW02A', 'TH', NULL, 'groundwater', NULL, 150.1009, -33.1009),
    ('f-0010', 'T.G001', 'T', 'surface', 'water', NULL, 150.1010, -33.1010),
    ('f-0011', 'TH.G01', 'TH', 'surface', 'water', NULL, 150.1011, -33.1011),
    ('f-0012', 'T.S08', 'T', 'surface', 'water', NULL, 150.1012, -33.1012),
    ('f-0013', 'Q.S01', 'Z', 'surface', 'water', NULL, 150.1013, -33.1013)")

  # feature_alias. Every feature gets a self-alias (fa-0001..fa-0003,
  # fa-0011..fa-0014; kind = 'self'), uniform with no special case for
  # "arrived correctly labelled". Plus the plan-11 Fixtures-section fixtures:
  #  - fa-0004 'bs03alt' -> f-0003: a resolved alt-label alias for the
  #    "two different incoming labels for one feature share one sample" test
  #    (R-11.7) - a HIT alongside f-0003's self-alias, not an ambiguity.
  #  - fa-0005/fa-0006 'T.AMBIG2' -> f-0004 AND f-0005: the ambiguous-key
  #    fixture (R-11.4/R-11.10) - both features are live at every fixture
  #    date, so this key never narrows to one.
  #  - fa-0007/fa-0008 'T.REUSED' -> f-0006 (defunct) AND f-0007 (live): the
  #    same-key-one-defunct fixture - narrows to f-0007 at any date after
  #    2020-06-30.
  #  - fa-0009 'T.BORE' -> f-0003, auto_assign FALSE: a non-identifying
  #    descriptive alias that must never enter the candidate set - a
  #    suggestion source only.
  #  - fa-0010 'T.S09', uuid_feature NULL, kind 'pending': an EXISTING
  #    dangling alias a second event re-encounters (R-11.5a natural-key
  #    lookup) - paired with sample s-0003/analysis an-0003 below.
  DBI::dbExecute(con, "INSERT INTO feature_alias
    (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign,
     first_seen, last_seen, confirmed_by) VALUES
    ('fa-0001', 'f-0001', 'T.S01', 't.s01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0002', 'f-0002', 'T.S02', 't.s02', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0003', 'f-0003', 'T.MW01', 't.mw01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0004', 'f-0003', 'bs03alt', 'bs03alt', 'transcription_error', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    ('fa-0005', 'f-0004', 'T.AMBIG2', 't.ambig2', 'descriptive', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    ('fa-0006', 'f-0005', 'T.AMBIG2', 't.ambig2', 'descriptive', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    ('fa-0007', 'f-0006', 'T.REUSED', 't.reused', 'historical_code', 0, TRUE,
     TIMESTAMP '2018-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL),
    ('fa-0008', 'f-0007', 'T.REUSED', 't.reused', 'historical_code', 0, TRUE,
     TIMESTAMP '2024-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    ('fa-0009', 'f-0003', 'T.BORE', 't.bore', 'descriptive', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0010', NULL, 'T.S09', 't.s09', 'pending', 0, FALSE,
     TIMESTAMP '2025-05-10 08:00:00', TIMESTAMP '2025-05-10 08:00:00', NULL),
    ('fa-0011', 'f-0004', 'T.S04', 't.s04', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0012', 'f-0005', 'T.S05', 't.s05', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0013', 'f-0006', 'T.S06', 't.s06', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0014', 'f-0007', 'T.S07', 't.s07', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    -- fa-0015/fa-0016: a REALISTIC ambiguous key (both auto_assign FALSE, as
    -- migration-001 marks any key reaching >1 feature). 'T.DUAL' -> f-0004 AND
    -- f-0005. PLAN-15 A: reconcile must SURFACE both as review candidates (not
    -- silently drop to a plain unknown), even though neither auto-resolves.
    ('fa-0015', 'f-0004', 'T.DUAL', 't.dual', 'descriptive', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    ('fa-0016', 'f-0005', 'T.DUAL', 't.dual', 'descriptive', 0, FALSE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-05-01 00:00:00', NULL),
    -- PLAN-15 F1: self-aliases for the new TH-site / digit-width / F6-target
    -- features above, uniform with every other feature (no special case).
    ('fa-0017', 'f-0008', 'TH.S01', 'th.s01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0018', 'f-0009', 'TH.MW02A', 'th.mw02a', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0019', 'f-0010', 'T.G001', 't.g001', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0020', 'f-0011', 'TH.G01', 'th.g01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    ('fa-0021', 'f-0012', 'T.S08', 't.s08', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    -- PLAN-15 F2: collision oracle mirroring bs1 -> BH.S01 - a curated,
    -- auto_assign=TRUE historical_code alias for a DIRECT (unboundaried)
    -- code, pointing at the OTHER site. Makes B.2's direct-boundary rule
    -- (TS01 must NOT auto-resolve to T.S01) falsifiable: a naive
    -- longest-match parse of 'TS01' would land on the OPPOSITE catchment
    -- from where 'TS1' is actually curated.
    ('fa-0022', 'f-0008', 'TS1', 'ts1', 'historical_code', 0, TRUE,
     TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL),
    -- PLAN-15 F6: a DANGLING alias whose key ('t s08') is structurally
    -- parseable (site T, point S08 -> T.S08 = f-0012 above) but already
    -- reaches an existing feature_alias row - B.4's gate must stop Layer
    -- 2/3 from resolving it. s-0005/an-0005 below is the pre-committed
    -- measurement under this alias, making the would-be double-commit
    -- idempotency failure demonstrable if the gate is skipped.
    ('fa-0023', NULL, 'T S08', 't s08', 'pending', 0, FALSE,
     TIMESTAMP '2025-05-10 08:00:00', TIMESTAMP '2025-05-10 08:00:00', NULL),
    -- PLAN-15 F8: the self-alias of f-0013 'Q.S01' (site 'Z'). Present so the
    -- prefix != site feature is uniform with every other feature AND so a
    -- name-prefix-derived site set would actually RESOLVE the raw 'Q S01'
    -- (structural hit + self-alias available). Without this row that wrong
    -- implementation would fall to review via B.6's no-self-alias rule and
    -- the B.1 test could not tell it apart from a correct one.
    ('fa-0024', 'f-0013', 'Q.S01', 'q.s01', 'self', 0, TRUE,
     TIMESTAMP '2025-01-01 00:00:00', TIMESTAMP '2025-01-01 00:00:00', NULL)")

  # feature_mask (f-0001/long is an alias; f-0002/epa and f-0003/long both
  # resolve the string "AMBIG" - the deliberate ambiguity fixture). Untouched
  # by plan 11: R-11.4 stops joining feature_mask for candidate matching, but
  # the table and these rows stay for other plans' pre-existing tests.
  DBI::dbExecute(con, "INSERT INTO feature_mask (uuid_feature, variant, name) VALUES
    ('f-0001', 'long', 'Test Surface 01'),
    ('f-0002', 'epa', 'AMBIG'),
    ('f-0003', 'long', 'AMBIG')")

  # REVISED 2026-07-24 (PLAN-15 E.1): `feature_alias` gains `date_start DATE`
  # and `date_end DATE` (both NULLABLE, unbounded on NULL) in the CREATE
  # TABLE above. No INSERT below lists these columns explicitly, so every
  # existing fixture row reads back NULL/NULL on both - unbounded, i.e.
  # exactly today's behaviour, per E.1's "NULL/NULL is the default and
  # preserves exactly today's behaviour" pin. Additive only; nothing below
  # was reordered or rewritten to accommodate it.

  # analyte (canonical units deliberately differ from reported units, to
  # force conversion in reconciliation tests)
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, type, CAS) VALUES
    ('a-0001', 'pH', 'pH', 'field', NULL),
    ('a-0002', 'Fluoride', 'µg/L', 'anion', '16984-48-8'),
    ('a-0003', 'Electrical Conductivity', 'mS/cm', 'field', NULL),
    ('a-0004', 'Temperature', '°C', 'field', NULL),
    ('a-0005', 'Standing Water Level', 'm', 'field', NULL)")

  # lab_method (analyte_raw + organisation -> uuid_lab -> uuid_analyte).
  # lm-0002/lm-0004 are the duplicate-method pair (R-8.6): same analyte, ALS;
  # lm-0002 has the lower rl_low (0.1) so it wins.
  # lm-0008/lm-0009 are new, dangling (uuid_analyte NULL), plan-11 fixtures:
  #  - lm-0008: paired with sample s-0002/analysis an-0002 (units 'µS/cm' on
  #    THIS row, value 965 unconverted) for the R-11.11 confirm-and-convert
  #    test - reuses the pinned 965 -> 0.965 mS/cm conversion already in
  #    FIXTURES.md's "Unit conversions" section.
  #  - lm-0009: an EXISTING dangling method a second event re-encounters
  #    (R-11.5a natural-key lookup) - paired with sample s-0004/analysis
  #    an-0004 below.
  # lm-0010/lm-0011 are the R-11.19/A65 fixture: two genuinely distinct
  # methods differing ONLY in name capitalisation, same organisation (ACIRL),
  # same method (field), both resolving to the SAME analyte (a-0005, length,
  # units 'm') - mirroring the live 'Standing Water Level' / 'Standing water level' pair
  # that currently strands every such ACIRL reading as unknown_analyte. An
  # incoming 'Standing Water Level' must resolve to lm-0010 (exact raw-name
  # match) and 'Standing water level' to lm-0011.
  # lm-0012 is the conversion-constant fixture (A63): conversion_constant
  # 2.0, so an incoming value of 3 commits as analysis.value = 6. Every other
  # seeded method has NA conversion_constant (no conversion - today's
  # baseline behaviour).
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-0001', 'a-0001', 'pH Value', 'EA005P: pH by PC Titrator', 'ALS', 0.01, 'pH', NULL),
    ('lm-0002', 'a-0002', 'Fluoride', 'EK040P: Fluoride by PC Titrator', 'ALS', 0.1, 'mg/L', NULL),
    ('lm-0003', 'a-0003', 'Electrical Conductivity @ 25°C', 'EA010P: Conductivity by PC Titrator', 'ALS', 1, 'µS/cm', NULL),
    ('lm-0004', 'a-0002', 'Fluoride', 'EK040T: Fluoride by alt method', 'ALS', 0.5, 'mg/L', NULL),
    ('lm-0005', 'a-0001', 'pH', NULL, 'ACIRL', NULL, 'pH', NULL),
    ('lm-0006', 'a-0003', 'EC', NULL, 'ACIRL', NULL, 'mS/cm', NULL),
    ('lm-0007', 'a-0004', 'Temperature', NULL, 'ACIRL', NULL, 'deg C', NULL),
    ('lm-0008', NULL, 'EC New Method', 'EA010Z: Conductivity by new method', 'ALS', 1, 'µS/cm', NULL),
    ('lm-0009', NULL, 'Sulphate', 'EA045: Sulphate by IC', 'ALS', 0.5, 'mg/L', NULL),
    ('lm-0010', 'a-0005', 'Standing Water Level', 'field', 'ACIRL', NULL, 'm', NULL),
    ('lm-0011', 'a-0005', 'Standing water level', 'field', 'ACIRL', NULL, 'm', NULL),
    ('lm-0012', 'a-0002', 'Fluoride as F', 'EK040P: Fluoride by PC Titrator', 'ALS', 0.1, 'mg/L', 2.0)")

  # project. p-0003 is the PLAN-15 F5 second work order/project, used by
  # Work C tests that need a WO distinct from p-0001's own committed history
  # (a WO "split across two runs" fixture). NB: p-0002 is deliberately NOT
  # seeded here - test-reconcile.R's own R-8.7 "no recorded revision" test
  # inserts a test-local 'p-0002'/'CD2222222' row itself.
  DBI::dbExecute(con, "INSERT INTO project (uuid, name, type) VALUES
    ('p-0001', 'XX1234567', 'Work order'),
    ('p-0003', 'YY9876543', 'Work order')")

  # Pre-existing sample + analysis: the "old pipeline already committed this"
  # rows for three-way reconciliation tests. s-0001 / an-0001 is the
  # converted form of "Fluoride <0.1 mg/L" (0.1 mg/L -> 100 µg/L). s-0001 now
  # points at fa-0001 (f-0001's self-alias) rather than at f-0001 directly
  # (R-11.2 drops sample.uuid_feature).
  #
  # s-0002/an-0002: dangling-analyte fixture for R-11.11 (lm-0008, whose
  # `lab_method.units` is 'µS/cm', unconverted value 965). NB the units are on
  # the METHOD, not on `analysis` - A63 reversed A51 and `analysis.units_raw`
  # no longer exists. `units_raw` survives only as an IR-internal field (seam
  # S-5), which is a different thing with the same name.
  # s-0003/an-0003: the sample a second event re-encounters via fa-0010's
  # natural key (R-11.5a, feature-pending path) - an-0003 uses an already-
  # resolved lab_method (pH) since only the feature side is dangling here.
  # s-0004/an-0004: the sample a second event re-encounters via lm-0009's
  # natural key (R-11.5a, analyte-pending path) - the feature side is
  # already resolved (fa-0001) since only the analyte side is dangling here.
  # DATETIME is stored as the UTC INSTANT of the FIXTURES.md-documented
  # Australia/Sydney wall-clock sampling time (AEST = UTC+10 in May, no DST),
  # i.e. wall-clock minus 10h. This is NOT a wall-clock literal: duckdb reads a
  # TIMESTAMP literal back as naive/UTC, and production commit
  # (.ct_find_or_create_sample -> R/commit.R) stores the Sydney-parsed POSIXct,
  # which duckdb persists as that same UTC instant. Seeding the wall-clock
  # literal instead (e.g. '...11:45') would make a re-ingest of the SAME
  # sampling fail to epoch-match (10h off) and be wrongly treated as a new
  # sampling under the R-11.18/A62 datetime-identity predicate. So: s-0001
  # 11:45 Sydney -> 01:45 UTC; s-0002 09:30 -> prev-day 23:30; s-0003 08:00 ->
  # prev-day 22:00; s-0004 08:15 -> prev-day 22:15. The DATE column stays the
  # naive midnight-UTC calendar day (matched separately via CAST(date AS DATE)),
  # exactly as commit writes it - do NOT shift the date. Do NOT 'correct' these
  # datetimes back to the wall-clock literal.
  DBI::dbExecute(con, "INSERT INTO \"sample\"
    (uuid, uuid_feature_alias, uuid_project, date, datetime, organisation) VALUES
    ('s-0001', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-24 00:00:00',
     TIMESTAMP '2025-05-24 01:45:00', 'ALS'),
    ('s-0002', 'fa-0003', 'p-0001', TIMESTAMP '2025-05-25 00:00:00',
     TIMESTAMP '2025-05-24 23:30:00', 'ALS'),
    ('s-0003', 'fa-0010', 'p-0001', TIMESTAMP '2025-05-10 00:00:00',
     TIMESTAMP '2025-05-09 22:00:00', 'ALS'),
    ('s-0004', 'fa-0001', 'p-0001', TIMESTAMP '2025-05-12 00:00:00',
     TIMESTAMP '2025-05-11 22:15:00', 'ALS'),
    -- PLAN-15 F6: the pre-committed measurement under the dangling alias
    -- fa-0023 ('T S08') - 15 May 2025 09:15 Sydney -> 14 May 2025 23:15 UTC
    -- (same AEST-minus-10h convention as s-0001..s-0004 above).
    ('s-0005', 'fa-0023', 'p-0001', TIMESTAMP '2025-05-15 00:00:00',
     TIMESTAMP '2025-05-14 23:15:00', 'ALS')")

  # No units column on `analysis` (D7 reversed / A63) - each row's units are
  # those of its uuid_lab (an-0002 -> lm-0008 'µS/cm', an-0003 -> lm-0001
  # 'pH', an-0004 -> lm-0009 'mg/L'; not stored here).
  DBI::dbExecute(con, "INSERT INTO analysis
    (uuid, uuid_sample, uuid_lab, value, quantified, rl_low) VALUES
    ('an-0001', 's-0001', 'lm-0002', 100, FALSE, 100),
    ('an-0002', 's-0002', 'lm-0008', 965, TRUE, 1),
    ('an-0003', 's-0003', 'lm-0001', 7.10, TRUE, 0.01),
    ('an-0004', 's-0004', 'lm-0009', 12, TRUE, 0.5),
    -- PLAN-15 F6: pH 7.05 at s-0005/fa-0023 (lm-0001 'pH Value', ALS) -
    -- the idempotency oracle a re-ingested identical 'T S08' row must match.
    ('an-0005', 's-0005', 'lm-0001', 7.05, TRUE, 0.01)")

  # ingest_file seed row for the supersede test.
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, work_order, revision, state) VALUES
    ('legacy-hash-XX', 'XX1234567', 0, 'archived')")

  path
}

#' Open a read-write connection to a seeded DuckDB
#'
#' @param path path returned by `seed_db()`
#' @return an open DBI connection (caller must disconnect)
seed_con <- function(path) {
  DBI::dbConnect(duckdb::duckdb(), path, read_only = FALSE)
}
