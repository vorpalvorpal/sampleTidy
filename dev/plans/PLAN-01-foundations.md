# PLAN 01 — Foundations: config, DB connection, ops schema, hashing

**Owns:** `R/config.R`, `R/db-connect.R`, `R/db-schema.R`, `R/hash.R`,
`tests/testthat/test-config.R`, `test-db-connect.R`, `test-db-schema.R`,
`test-hash.R`. **Depends on:** nothing. **Blocks:** everything.

All tests run against a throwaway DuckDB file created in `withr::local_tempdir()`
seeded by `ensure_schema()` plus a tiny synthetic core-schema loader
(`tests/testthat/helper-db.R`, owned here: creates empty core tables matching
the CONTRACT schema exactly, and inserts the minimal reference rows individual
tests need).

## R-1.1 `st_config()` — configuration

`st_config(key)` gets; `st_config(key, value)` sets (options-backed,
prefix `sampletidy.`). Defaults resolved in order: option → env var
`SAMPLETIDY_<KEY>` → built-in default.

Keys (pin exactly): `live_db` (default
`file.path(tools::R_user_dir("sampleTidy", "data"), "monitoring.duckdb")`),
`input_dir` (no default — abort if unset when needed), `archive_dir`,
`snapshot_dir`, `field_analytes` (default was
`c("pH", "Temperature", "Conductivity", "EC")` — **WIDENED 2026-08-01 per A76**;
see R/config.R and PLAN-06 R-6.6 for the measured list and why it changed),
`field_analytes_diff_required` (added 2026-08-01; A75/A76 — the labels that
share the ALS analyte's name and can only be selected by the value test),
`remove_ingested` (default
`FALSE`; A13), `corpus_dir` (default `Sys.getenv("SAMPLETIDY_CORPUS", "")`).

Correctness criteria:
- unset key with no default aborts with class `sampletidy_error` naming the key;
- set → get round-trips; env var wins over built-in default, option wins over env;
- `live_db` default is under `R_user_dir` — i.e. **never** inside a cloud-sync
  path; test asserts the default contains `R_user_dir("sampleTidy", "data")`.

## R-1.2 `hash_file()`

SHA-256 of file contents (A5). Criteria: known 3-byte fixture file hashes to
its precomputed digest; two files with identical bytes but different names/
mtimes hash equal; missing file aborts (`sampletidy_error`).

## R-1.3 `with_db_write()`

Signature per DESIGN §9.2 (copy the reference implementation; it is normative).
Criteria:
- returns `fn(con)`'s value; connection closed afterwards (a second RW connect
  succeeds immediately);
- while another process/connection holds RW, retries then aborts after
  `max_wait` with "busy" message (test with a second connection in the same
  process — duckdb enforces one RW per file across connections via a second
  `duckdb::duckdb()` driver instance);
- a *non-lock* connect error (e.g. path is a directory) aborts immediately,
  not after `max_wait` — assert elapsed < 2 s;
- `fn` throwing still closes the connection (on.exit).

## R-1.4 `st_connect(db, read_only)`

Thin wrapper returning a DBI connection; `read_only = TRUE` default.
Criteria: read-only connection cannot write (dbExecute of INSERT errors);
nonexistent file with `read_only = TRUE` aborts with path in message;
`read_only = FALSE` creates the file if absent.

## R-1.5 `ensure_schema(con)` — ops tables & migrations (A2, A7)

Idempotent migration runner: table `schema_version(version INTEGER,
applied_at TIMESTAMP)`; migrations are an internal ordered list of SQL
strings; each runs in a transaction and records its version. DDL (pin
exactly; all columns VARCHAR unless noted):

```sql
CREATE TABLE ingest_file (
  hash VARCHAR PRIMARY KEY, filename VARCHAR, path_first_seen VARCHAR,
  size BIGINT, first_seen_at TIMESTAMP, updated_at TIMESTAMP,
  state VARCHAR,           -- seen|claimed|parsed|assembled|reconciled|
                           -- needs_review|committed|archived|ignored|
                           -- quarantined|failed
  state_reason VARCHAR, adapter VARCHAR, tier VARCHAR,
  work_order VARCHAR, revision INTEGER, org VARCHAR, uuid_asset VARCHAR);
CREATE TABLE ingest_sighting (
  hash VARCHAR, path VARCHAR, seen_at TIMESTAMP);
CREATE TABLE review_queue (
  uuid VARCHAR PRIMARY KEY, created_at TIMESTAMP,
  kind VARCHAR,            -- unknown_feature|unknown_analyte|unknown_unit|
                           -- value_conflict|adapter_tie|parse_error|other
  work_order VARCHAR, source_hash VARCHAR, payload VARCHAR,  -- JSON
  status VARCHAR DEFAULT 'open',  -- open|resolved|dismissed
  resolution VARCHAR, resolved_by VARCHAR, resolved_at TIMESTAMP);
CREATE TABLE change_log (
  uuid VARCHAR PRIMARY KEY, at TIMESTAMP, actor VARCHAR, action VARCHAR,
  tbl VARCHAR, uuid_row VARCHAR, field VARCHAR,
  old VARCHAR, new VARCHAR, reason VARCHAR, source_hash VARCHAR);
```

(No core-table alterations — A1: provenance runs through
`change_log.source_hash`, not new columns.)

Criteria:
- fresh DB: `ensure_schema()` creates all five objects; `schema_version` holds
  every migration version;
- calling twice is a no-op (row counts and versions unchanged, no error);
- migrations never DROP/ALTER-narrow anything — test asserts core-table
  columns are unchanged by `ensure_schema()` on a seeded DB.

## R-1.6 State transitions

`ingest_file_upsert(con, hash, ...)` and
`ingest_file_set_state(con, hash, state, reason = NA)`. Legal transitions
(enforce; illegal → abort): `seen→{claimed,ignored,quarantined}`,
`claimed→{parsed,failed,quarantined}`,
`parsed→{assembled,ignored,failed}` (`ignored` = superseded rendering,
plan 07),
`assembled→{reconciled,failed}`, `reconciled→{needs_review,committed}`,
`needs_review→committed`, `committed→archived`. Any state →`failed`.
Terminal: `archived, ignored, quarantined, failed` (re-ingest of a changed
policy resets via explicit `reset = TRUE` only).

Criteria: legal path walks end to end; illegal jump (`seen→committed`) aborts
naming both states; upsert on existing hash updates `updated_at` and appends
an `ingest_sighting` row when the path differs from `path_first_seen`.
