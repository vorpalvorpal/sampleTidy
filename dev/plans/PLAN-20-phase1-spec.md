# PLAN-20 phase 1 — behaviour spec (items 1, 2, 4, 5)

_Written 2026-10-20 as the TDD input for PLAN-20 phase 1. The test-writer works from this
file alone; the implementer makes the tests pass. Section numbers are referenced from test
names as `P20.<n>`._

Nothing here changes what today's deployment sees: with no hook registered, every file
`inbox_run()` wrote before is still written, byte for byte. New files are added beside them.

## P20.1 Structured outputs: `status.json` and `events.jsonl`

`inbox_run()` keeps its signature and its returned list unchanged.

1. **`status.json`.** Wherever `inbox_run()` used to write `<report_dir>/.import-status.json`
   (the status refresh: action `"status"`, a dry run, and the end of a full run), it now
   writes `<report_dir>/status.json` as well. **The two files are byte-identical.**
   `.import-status.json` is kept for one release so the existing notes setup keeps working.
2. **`events.jsonl`.** Wherever a full (non-dry) run used to append one JSON line to
   `<report_dir>/.imports.log`, it now appends the same line to `<report_dir>/events.jsonl`.
   Seeding: if `events.jsonl` does not exist but `.imports.log` does, the run first copies
   `.imports.log` to `events.jsonl`, then appends to both. After any run the two files are
   byte-identical. `.imports.log` is kept for one release.
3. **Readers.** Everything that reads the run log (the status note's problems and recent
   imports, the daily report) reads `events.jsonl` when it exists, else `.imports.log`.
   The flags `first_seen` carry-over reads `status.json` when it exists, else
   `.import-status.json`.
4. **`import_status()` called directly** behaves exactly as today (writes `Import status.md`
   and `.import-status.json`) and also writes `status.json` (identical to
   `.import-status.json`). It runs no hooks. **`import_report()` called directly** behaves
   exactly as today. Both stay exported; they move out of the package in phase 2.
5. Dry runs append nothing to either log (as today).

## P20.2 Hooks

New exported functions in `R/hooks.R`. Hooks are session state (a package-level
environment), not persisted.

- `register_hook(event, fn)`: `event` is one of `"after_run"`, `"after_status"`,
  `"work_complete"`; anything else aborts with class `sampletidy_error`. `fn` must be a
  function (else `sampletidy_error`). Hooks of one event run in registration order; the same
  function may be registered twice and then runs twice. Returns `fn` invisibly.
- `clear_hooks(event = NULL)`: `NULL` clears every event; a valid event name clears that event
  only; an invalid name aborts `sampletidy_error`. Returns `NULL` invisibly.
- `hooks(event = NULL)`: with `NULL`, a named list with exactly the three names
  `after_run`, `after_status`, `work_complete` (in that order), each a (possibly empty) unnamed
  list of the registered functions. With an event name, that event's list. Invalid name ->
  `sampletidy_error`.

### When each event fires inside `inbox_run()`

Each hook is called with ONE argument.

| event | fires | argument |
|---|---|---|
| `after_run` | after a full non-dry run (lock acquired, `ran = TRUE`), after the log line is appended | the same list `inbox_run()` returns |
| `work_complete` | after a full non-dry run in which at least one folder was handed to `ingest_dir()` and the backup did not fail, **only if at least one project became complete during this run** | a `completed_work()` tibble holding just those projects |
| `after_status` | every time `inbox_run()` refreshes status (action `"status"`, a dry run, and the end of a full run), after `status.json` is written | the status list (below) |

- Action `"none"` and a locked run fire nothing. A dry run fires only `after_status`.
- Order within a full run: append log -> `after_run` -> `work_complete` -> build status ->
  write `status.json` + `.import-status.json` -> `after_status`.
- "Became complete during this run" = in `completed_work(db)` after the folders were
  ingested but not in `completed_work(db)` taken just before the first folder was ingested
  (compared by project `uuid`). Both snapshots are taken only when at least one
  `work_complete` hook is registered. A project that becomes complete between runs (e.g. a
  review item resolved by hand) does not fire `work_complete`; a deployment reconciles those
  with `completed_work()` against `filed_assets()`.
- **The status list** passed to `after_status` is the R list whose JSON is `status.json`:
  names `updated`, `host`, `dry_run`, `review_items_open`, `folders_waiting`,
  `needs_review`, `non_blocking_notes`, `waiting`, `problems`, `recent_imports`, plus the
  flags elements when `checks` is given. `problems` is a list of strings.

### Default renderers (today's markdown)

- When **no** `after_status` hook is registered, the default renderer runs in its place: it
  writes `<report_dir>/Import status.md` exactly as today (byte-identical to what the same
  inputs produced before this change).
- When **no** `after_run` hook is registered, the default renderer runs in its place: if the
  day has news it writes the daily `<YYYY-MM-DD>-imports.md` via the same logic as
  `import_report()`, exactly as today.
- When a hook **is** registered for an event, the default renderer for that event does not
  run (the registered hook replaces it). So registering an `after_status` hook means
  `Import status.md` is no longer written by `inbox_run()`; `status.json` and
  `.import-status.json` always are.
- `work_complete` has no default.

### Failures

- Every hook call (default renderers included) runs inside `tryCatch`. An error in a hook
  **never** fails `inbox_run()`, never stops later hooks of the same or other events, and
  never changes the returned list.
- A failure is recorded as one problem string, exactly
  `sprintf("hook %s[%s] failed: %s", event, id, conditionMessage(e))`, where `id` is the
  hook's 1-based position among that event's registered hooks, or `default` for a default
  renderer.
- Failures of `after_run` and `work_complete` hooks (and of the `completed_work()` snapshots
  taken for `work_complete`, recorded as `hook work_complete[snapshot] failed: <msg>`) are
  appended to the status list's `problems` of the same run, after the log-derived problems,
  so they appear in `status.json`, `.import-status.json` and the `## Problems` section of
  `Import status.md`.
- Failures of `after_status` hooks are appended to `problems` and `status.json` /
  `.import-status.json` are rewritten with them (the failed hook itself saw the status
  without its own failure).
- Problems from hooks are not written to the run log.

## P20.4 `completed_work(db = st_config("live_db"), since = NULL)`

New exported function in `R/completed.R`. Read-only. `db` is a path to a DuckDB file
(opened read-only) or an open `DBIConnection` (used as is, not closed).

**A project is complete** when

1. it has at least one `sample` row (`sample.uuid_project = project.uuid`), and
2. no **blocking open** review item references it.

A review item is **open** when `COALESCE(status, 'open') = 'open'`. It is **blocking**
unless its `kind` or its `subkind` is `'self_precedence_note'` (those are non-blocking
notes). Flags (QC, limits) play no part.

An open review item **references** project P when any of these holds:

- (a) `review_queue.work_order = P.name`;
- (b) any of `uuid_target`, `uuid_existing`, `uuid_incoming`, `uuid_alias` equals P's
  `uuid`, the uuid of one of P's samples, the uuid of an `analysis` row of one of P's
  samples, or the uuid of one of P's assets (`asset.uuid_project = P.uuid`);
- (c) `source_hash` equals the `hash` of one of P's assets; or equals the `hash` of an
  `ingest_file` row whose `uuid_asset` is one of P's assets or whose `work_order = P.name`;
  or equals the `source_hash` of a `change_log` row with `tbl` in (`'sample'`,
  `'analysis'`) whose `uuid_row` is one of P's samples or an analysis of one of P's samples
  (i.e. the file wrote data into P);
- (d) `payload` contains P's `name` as a JSON string (the substring `"` + name + `"`,
  plain substring match, no wildcards), or contains P's `uuid`, or the uuid of one of P's
  samples or assets, as a substring.

References are direct only: an item that references a parent or child project does not
block P.

**Result**: a tibble, one row per complete project, ordered by `date_start`, then `name`,
then `uuid` (NULLs last). Columns, in this order:

| column | type | from |
|---|---|---|
| `uuid` | chr | `project.uuid` |
| `name` | chr | `project.name` |
| `type` | chr | `project.type` |
| `site` | chr | `project.site` |
| `date_start` | POSIXct | `project.date_start` |
| `date_end` | POSIXct | `project.date_end` |
| `uuid_root` | chr | `COALESCE(project.uuid_root, project.uuid)` |
| `root_name` | chr | the `name` of the project whose uuid is `uuid_root` (NA if none) |
| `assets` | list | per row, a tibble of P's assets (below) |

Each `assets` element is a tibble with columns `uuid`, `path`, `filename`, `hash`,
`file_format`, `type` (all chr), one row per `asset` with `uuid_project = P.uuid`, ordered by
`filename` then `uuid`; a 0-row tibble with those columns when P has none. `path` is the
asset's location relative to `st_config("archive_dir")`, the directory-per-asset layout of
`archive_file()`: `paste0(uuid, "/", filename)`, or NA when `filename` is NA.

With no complete project the result is a 0-row tibble with the same columns (`assets` an
empty list).

`since`: `NULL` (default) returns every complete project. Otherwise a `Date` or `POSIXct`
of length 1 (a `Date` is taken as midnight UTC); only projects with
`COALESCE(date_end, date_start) >= since` are returned (projects with both NULL are
excluded). Anything else aborts `sampletidy_error`.

## P20.5 External filing records

### Table

`asset_filing`, created by `ensure_schema()` as ops-schema **version 10** (renumbered from 9 on the 2026-10-25 rebase: v9 is R-22.E `ingest_email`) (so every fresh DB
has it) and on the live DB by operator migration `dev/migrations/060-asset-filing.R`:

```sql
CREATE TABLE IF NOT EXISTS asset_filing (
  uuid_asset   VARCHAR NOT NULL,
  system       VARCHAR NOT NULL,
  external_id  VARCHAR NOT NULL,
  external_uri VARCHAR,
  container    VARCHAR,
  filed_at     TIMESTAMP NOT NULL,
  title        VARCHAR,
  comments     VARCHAR,
  PRIMARY KEY (uuid_asset, system)
)
```

No declared FOREIGN KEY (ensure_schema runs on a bare DB with no `asset` table, and a
declared FK would block later asset deletes); `register_filing()` checks the asset exists.
The core never interprets `system`: any non-empty string is accepted and stored verbatim.

### `register_filing(db = st_config("live_db"), uuid_asset, system, external_id, external_uri = NA_character_, container = NA_character_, filed_at = NULL, title = NA_character_, comments = NA_character_)`

Exported. `db` is a path (opened read-write via `with_db_write()`) or an open read-write
`DBIConnection`.

- `uuid_asset`, `system`, `external_id`: non-empty strings, else `sampletidy_error`.
  `external_uri`, `container`, `title`, `comments`: a string or NA. `filed_at`: `NULL` or a
  length-1 POSIXct.
- Unknown `uuid_asset` (no `asset` row) -> `sampletidy_error`, nothing written.
- Missing `asset_filing` table -> `sampletidy_error` naming migration 060, nothing written.
- No row for `(uuid_asset, system)` -> insert; `filed_at` = the given value or `Sys.time()`.
  Returns `"inserted"` invisibly.
- Row exists -> update only the fields whose supplied value differs (`filed_at = NULL`
  keeps the stored `filed_at`). Returns `"updated"` invisibly, or `"unchanged"` when nothing
  differs (and then writes nothing). Re-registering the same filing is therefore a no-op.
- Writes go through the mutation layer: each insert/update writes `change_log` rows with
  `tbl = 'asset_filing'`, `actor = 'register_filing'`.

### `filed_assets(db = st_config("live_db"), system = NULL)`

Exported, read-only; `db` a path or an open connection. Returns a tibble with exactly the
`asset_filing` columns in table order, ordered by `system`, `filed_at`, `uuid_asset`.
`system = NULL` returns every row; a character vector keeps rows whose `system` is in it. If
the table does not exist, returns a 0-row tibble with those columns.

## P20.M Migration 060 (`dev/migrations/060-asset-filing.R`)

Operator migration in the pattern of `048-qc-schema.R`: functions prefixed `mig060_`,
marker **1060**, requires marker **1052**. `env$mig060_run(db, snapshot_dir, dry_run = FALSE,
.now = NULL)` returns a list with `status` in `"dry_run"`, `"migrated"`,
`"already_migrated"`.

- Preconditions (abort `sampletidy_error`, nothing written): marker 1052 present; an `asset`
  table exists; if `asset_filing` already exists (`ensure_schema()` v10 got there first) it
  must have exactly the columns above and 0 rows.
- Dry run: checks preconditions, writes nothing, no backup.
- Migrate: verified whole-file backup to `snapshot_dir`; then in one transaction create the
  table (`IF NOT EXISTS`), insert `schema_version` 10 if absent and 1060; verify; every other
  table's row count unchanged.
- Re-run with marker present: re-verify, `"already_migrated"`, nothing written.
- `dev/migrations/apply-060-asset-filing.R` mirrors `apply-048-qc-schema.R`
  (`SAMPLETIDY_MIG060_DB`, `SAMPLETIDY_MIG060_SNAPSHOT_DIR`).

## Public API

New exports: `register_hook`, `clear_hooks`, `hooks`, `completed_work`, `register_filing`,
`filed_assets`. The R-10.6 export pin in `tests/testthat/test-e2e-pipeline.R` and the
CONTRACT public-API list gain them.
