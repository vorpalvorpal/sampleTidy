# PLAN 09 — Mutation API, commit, archive, snapshot, `ingest_dir()`

**Owns:** `R/mutate.R`, `R/commit.R`, `R/archive.R`, `R/snapshot.R`,
`R/ingest.R` + test files. **Depends on:** 01, 07, 08.

## R-9.1 Mutation layer (`R/mutate.R`) — the only write door

`db_append(con, table, df, actor, reason, source_hash = NA)`,
`db_update(con, table, uuid, changes, actor, reason, source_hash = NA)`,
`db_delete(con, table, uuid, actor, reason)`. Each: validates `table` against
an allowlist (core + ops tables), validates columns exist, executes, and
writes `change_log` rows **in the same transaction** (action =
insert|update|delete; for updates one log row per changed field with old/new;
for inserts one row per record, field NA, new = row uuid). No transaction
open → the function opens one; caller-supplied open transaction → participate
(no nested BEGIN). Criteria:
- append of 2 rows → 2 change_log rows, same `at`, actor recorded;
- update changing 2 fields → 2 log rows with correct old/new;
- a failing update (bad column) rolls back the log too (count unchanged) —
  the atomicity test;
- direct-write bypass is lint-guarded: test greps `R/` sources (excluding
  `mutate.R`, `db-schema.R`) for `dbAppendTable|dbExecute\("INSERT|UPDATE|DELETE`
  and fails on hits.

Domain helpers: `add_feature()`, `add_analyte()`, `add_project(name, type =
"Work order", …)`, `correct_value(uuid_analysis, new_value, reason, actor)` —
thin wrappers over the generics with `uuid::UUIDgenerate()` for new uuids; no
prompts. Criterion each: row lands + change_log entry; `correct_value` logs
old value.

Reader: `review_queue(con, status = "open")` returns queue rows as a tibble
(payload column left as JSON text). Criterion: filters by status; zero-row
result has stable columns.

## R-9.2 `commit_event(event, resolved, con)` (`R/commit.R`)

Input: event + plan-08 output. Inside **one** `with_db_write` transaction:
1. project: look up `project` by `name = work_order`; absent → `add_project`
   (type `"Work order"`);
2. samples: for each distinct (uuid_feature, sample_date, sample_datetime,
   work_order) in `clean`: reuse an existing `sample` row matching at A11
   granularity (same feature + date; datetime equal when both non-NA) else
   `db_append` one (`organisation` = event org semantics: sampler org if
   known else org; `person` = sampler);
3. analyses: `db_append` rows (uuid, uuid_sample, uuid_lab, value =
   value_converted, value_chr, quantified, rl_low = rl_converted, comments)
   with `source_hash` passed to the mutation layer (A1 provenance);
   `supersedes` rows instead `db_update` the existing analysis (value,
   value_chr, quantified, rl_low) — change_log carries old/new + source_hash;
4. archive (R-9.3) **every file of the event** — kept, superseded renderings,
   and metadata contributors (A13); `already_present` rows: no new analysis,
   but a `change_log` action `provenance` row linking the existing analysis
   uuid to this source_hash;
5. review items: `db_append` to `review_queue`;
6. states: kept files `committed` then `archived`; review-bearing events
   still commit their clean rows (file state `needs_review` only when the
   event produced review items **and** zero clean rows — else `committed`
   with review items queued).

Criteria (fixture event with every disposition):
- row counts: new sample/analysis counts exactly match `clean`; re-running
  `commit_event` with the same input is blocked by state (test asserts a
  second call aborts on already-terminal files);
- mid-commit failure (inject: make step 5 fail via duplicate review uuid)
  leaves **zero** new rows anywhere (transaction atomicity — the
  throw-after-partial-write test);
- supersede: analysis updated in place, change_log has old/new, no duplicate
  analysis row;
- provenance chain: every committed analysis has a change_log insert row
  whose `source_hash` equals the hash of an archived asset of the event;
- superseded-rendering files (state `ignored`) also have asset rows + copies.

## R-9.3 Archive (`R/archive.R`)

`archive_file(con, path, hash, event)` (A1, A13): copy to
`file.path(st_config("archive_dir"), <new asset uuid>)` (no extension —
matches existing `processed/` convention, verified flat/extensionless;
original name preserved in `asset.filename`, extension in `file_format`);
`db_append` the `asset` row (`type = 'Chemical analysis'` — existing vocab,
A1; hash; uuid_project of the event's project); **source file untouched
here**. Skip-copy when an asset with the same hash exists (reuse its uuid).
Criteria: copy exists and byte-equals source; asset row fields correct;
same-hash second call creates no second copy/row; source still present;
asset visible to `ingest_file.uuid_asset` update.

## R-9.4 Snapshot (`R/snapshot.R`)

`snapshot_db(db = st_config("live_db"), dest_dir = st_config("snapshot_dir"))`:
inside `with_db_write`, `CHECKPOINT`, copy to
`dest_dir/monitoring_YYYY-MM-DD.duckdb.tmp`, atomic `file.rename` to final
name (DESIGN §9.1). Returns the path. `prune_snapshots(dest_dir, keep_days =
60)` deletes dated snapshots older than keep_days **except** each month's
last one (kept indefinitely). Criteria: snapshot opens read-only and
`SELECT count(*) FROM analysis` matches live; no `.tmp` left behind; prune on
a synthetic set of 90 dated filenames keeps exactly the ≤60-day dailies plus
each month's final snapshot; same-day re-snapshot overwrites (single file per
day).

## R-9.5 `ingest_dir()` (`R/ingest.R`) — orchestration

`ingest_dir(path, db = st_config("live_db"), dry_run = FALSE)`:
1. `ensure_schema`; 2. list files (`fs::dir_ls(type = "file")` —
**non-recursive**, MVP ignores subfolders); 3. `route_files`; 4. parse each
`claimed` file (`adapter$parse` under `tryCatch` → `failed` on error, others
proceed); 5. `assemble_events`; 6. per event: `reconcile_event` then (unless
`dry_run`) `commit_event`; 7. snapshot once if any commit happened; 8. return
+ `cli` print an `ingest_report`: files by terminal state, events committed,
rows new/already_present/superseded/skipped-by-reason, review items opened
(DESIGN §1 per-run summary).

Criteria:
- end-to-end on a temp dir holding the plan-04/05/06 fixture families +
  cruft (`.bak`, `.DS_Store`, a subdirectory containing a valid file):
  subdirectory content untouched (report never mentions it), cruft `ignored`,
  all three adapter families committed, report numbers reconcile exactly
  with DB row deltas;
- `dry_run = TRUE`: report produced, **zero** DB writes (row counts across
  all tables unchanged) and no snapshot;
- adapter crash on one file (fixture with a corrupted ESdat CSV) → that file
  `failed`, run completes, report lists it;
- second run over the same dir: all files skipped at routing (terminal
  states), zero new rows, zero new review items — idempotency at the
  orchestration level.

## R-9.6 The remove switch (A13)

Final `ingest_dir` step, only when `st_config("remove_ingested")` is TRUE and
the run reached the snapshot successfully: delete each source file whose hash
has a verified asset copy (asset row exists AND archive copy file exists).
Order is strict: commit → archive → snapshot → remove. Criteria:
- default (FALSE): all sources still present after a full run;
- TRUE: committed/superseded/metadata sources removed; quarantined, failed
  and cruft-`ignored` files remain;
- TRUE + injected snapshot failure: **nothing** removed;
- TRUE + missing archive copy (delete it before the remove step in the test):
  that source is kept and the report warns — never delete without a verified
  copy;
- a subsequent run over the emptied dir is a clean no-op.
