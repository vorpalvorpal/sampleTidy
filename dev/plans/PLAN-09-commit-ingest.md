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

---

**Added 2026-07-28 (Robin).** R-9.7 … R-9.11 below all descend from one
operational decision: PowerAutomate will drop the attachments of a single lab
email into their own folder under the input root, so a *folder* becomes the
durable record of "these files arrived together". R-9.5's non-recursive
listing stays exactly as pinned — none of these change `ingest_dir()`'s own
contract — and the R-9.5 criterion "subdirectory content untouched" remains
live and must keep passing.

## R-9.7 `ingest_inbox()` (`R/ingest.R`) — one batch per email folder

`ingest_inbox(root, db = st_config("live_db"), dry_run = FALSE,
reconsider = FALSE)`: list the
immediate subdirectories of `root` (never `root`'s own loose files — those are
`ingest_dir()`'s job and mixing the two would make the batch boundary
ambiguous) and call `ingest_dir()` once per subdirectory, in sorted order.
Returns a named list of per-folder `ingest_report`s plus a roll-up.

Per-folder rather than `recurse = TRUE` deliberately, for three reasons that
are each independently sufficient: it keeps one email's files as one batch, so
R-9.8's "exactly one work order in this folder" test means something; a folder
that throws does not take the rest of the inbox with it; and it gives R-9.9 a
well-defined thing to delete. Criteria:
- two folders each holding a different work order's files → two reports, both
  committed, and neither folder's files appear in the other's report;
- a folder whose ingest throws is reported as failed and the *other* folders
  still commit (contained, like every other per-item stage in this file);
- loose files sitting directly in `root` are not routed and are not deleted;
- `dry_run = TRUE` propagates to every folder: zero DB writes across all of
  them;
- an empty `root` returns an empty roll-up without error.

## R-9.8 Folder-sibling work-order inference for retained deliverables

`.ig_retain_siblings()` (B-15.F17) keys retention on `file_meta()`'s
`work_order_guess`, i.e. on parsing `ES#######` out of the filename. When that
returns NA the file is warned about and left quarantined forever — the
realised loss of 13 files recorded in PLAN-CHANGE-REQUESTS, because a
`2400-*` ACIRL work order **must not** be filename-parsed (see the ACIRL
work-order trap, `R/commit.R`) and never will be.

A folder gives a second, independent association that needs no filename
parsing: if the *other* files in this file's directory resolved to a work
order, this file belongs to it. Rule: when `work_order_guess` is NA, collect
the work orders of every routed file in the same directory that has one and
whose `project` row exists; infer **only when that set has exactly one
member**; otherwise fall back to today's warn-and-skip.

The exactly-one guard is not defensive padding — the real
`batch-2026-07-23` folder held **eight** work orders, and a majority-wins or
first-wins rule would have attached each COA to an arbitrary one of them.

**Correction, 2026-07-28 — the "13 ACIRL files" framing above and in the first
draft of this criterion was wrong on the facts.** PLAN-CHANGE-REQUESTS records
the 13 lost files as *"the COA / COC / QC / QCI PDFs and `XTAB.XLS` siblings of
work orders ES2600185, ES2610538, ES2612444, ES2614070 and ES2617126"* — all
**ALS**, all carrying an `ES#######` token, none ACIRL. They are recovered by
plain F.17 filename retention and have nothing to do with folder inference.
Read this criterion without that claim attached to it.

**Scope. This criterion was drafted with an ACIRL carve-out, and that
carve-out was OVERTURNED the same day — see R-9.12, which is the governing
rule for ACIRL.** The history is kept because the reasoning is instructive, but
nothing in it is binding:

1. ~~`test-ingest.R`'s "Phase-7b round-2 item 7" pins that a `2400-*`
   deliverable alongside ES2617126's files stays quarantined, so a folder rule
   attaching an ACIRL deliverable to an ALS work order would be a false
   merge.~~ **SUPERSEDED.** That test has been re-pointed at the *ambiguous*
   folder; its single-work-order case is now R-9.12's retain case.
2. ~~In production an ACIRL email's folder contains ACIRL files only, so the
   folder resolves to zero `ES#######` work orders and there is nothing to
   infer from.~~ **WRONG — corrected by Robin, 2026-07-28: "An ACIRL email will
   almost always contain the underlying ALS WO files as well."** Consistent with
   the adapter's own header (`R/adapter-acirl-field.R:5`: the workbook is "a
   transposed field-data block plus copies of ALS lab results which must be
   [dropped]"), i.e. ACIRL and ALS describe the *same sampling event* under two
   identifiers. So an ACIRL email's folder does generally resolve to exactly one
   `ES#######` work order.

**What actually keeps ACIRL out, measured rather than assumed.** The retention
SELECTION gate requires a `_(coa|coc|qc|qci|xtab)` token, and no real ACIRL file
carries one. Counted over the 1,227 files in `assets/unprocessed` on
2026-07-28:

| set | files | with a `_COA/_COC/_QC/_QCI/_XTAB` token |
|---|---|---|
| `2400-*` (ACIRL) | 272 (137 pdf, 135 xls/xlsx) | **0** |
| `ES#######` (ALS) | 873 | 287 |

Real ACIRL names are descriptive, not tokenised — `2400-7454-05 May 2025
Monthly Katoomba WMF.pdf`. So the ACIRL guard in `.ig_retain_siblings()` is
**inert against the real corpus**: nothing ACIRL reaches it, because the gate
excluded the file first. It is a belt on top of a brace, and its cost is that
it also blocks any future widening of the gate.

That left a separate, live exposure: 137 ACIRL PDFs were never retained at
all, and — because the same token gate also narrows the warning (commit-5,
round 3) — never *warned about* either. **Ruled by Robin the same day; see
R-9.12 below.**

So this rule covers the token-less name (a renamed attachment,
`Certificate.pdf`, `scan001.pdf`) in a folder that unambiguously belongs to one
work order, and R-9.12 extends the same machinery to ACIRL.

## R-9.12 ACIRL reports are retained and attached to the ALS work order

**Ruled by Robin, 2026-07-28: "Retain and attach to ALS WO."**

Grounded in the live DB rather than in an assumption about how the labs work.
Of 124 ACIRL-shaped `asset` rows, **104 are already attached to an
`ES#######` work-order project**, one report per work order:

```
2400-7286-01-04 18th January 2023 Special Wednesday Blaxland WMF.pdf -> ES2301817
2400-7286-01-03 11th January 2023 Special Wednesday Blaxland WMF.pdf -> ES2301026
2400-7286-02-02 February 2023 Special Wednesday Blaxland WMF.pdf     -> ES2306003
```

The legacy system already did exactly this. The package had stopped doing it,
silently.

Two things had to change together, and either alone is inert:

1. **The selection gate.** It required a `_(coa|coc|qc|qci|xtab)` token, and
   zero of the 272 real ACIRL files carry one. It now also admits the ACIRL
   `\d{4}-\d{4}` shape. That is still a *positive* shape, so ordinary cruft
   (`README.md`, `photo.jpg`, `notes.docx`) stays excluded and stays silent —
   the round-3 commit-5 fix is preserved and separately pinned.
2. **The ACIRL block in R-9.8's inference**, which would otherwise have refused
   every file the widened gate admitted. Removed.

**The ACIRL work-order trap is untouched.** We still never parse `2400-*` into
a work order; `file_meta()$work_order_guess` is still NA for it. The attachment
comes from the *folder*, which is a different and safer question, and it still
requires the folder to resolve to exactly one work order.

`asset.type` is `"Chemical analysis"` — the legacy majority (108 of 124; the
other 16 are `"QA"`, with no discernible rule separating them, so the majority
wins rather than a new invention).

Criteria:
- a real-shaped ACIRL report (`2400-7454-05 May 2025 Monthly Katoomba WMF.pdf`,
  carrying **no** deliverable token) in a folder belonging to one ALS work
  order is retained, attached to that work order, and typed
  `"Chemical analysis"`;
- the same report in a folder resolving to **two** work orders, or to none,
  stays quarantined and warns — and mints no project row;
- ordinary cruft is still neither retained nor warned about (the round-3
  regression guard: widening the gate must not re-open that noise);
- a `2400-*` name still yields no parsed work order (asserted as a
  precondition, so the trap cannot be quietly relaxed under cover of this
  change).

Criteria (ACIRL is **not** among them — see R-9.12):
- a deliverable whose filename carries no work order at all, in a folder whose
  other files all belong to one WO, is archived and attached to that WO;
- the same deliverable in a folder resolving to **two** work orders is NOT
  archived, stays quarantined, and warns;
- inference never fires when the filename *does* yield a work order — the
  filename wins, and a folder disagreeing with it does not override it;
- inference never *creates* a project row: a folder resolving to one WO that
  has no `project` row leaves the file quarantined (R-9.10's rule, applied
  here too);
- a `2400-*` ACIRL name is still never parsed for a work order — inference
  comes from the folder, provably, not from a relaxed regex.

## R-9.9 Empty-folder cleanup

Once `.ig_remove_verified()` has deleted the sources it verified, delete the
per-email folder if nothing but ignorable cruft remains in it.

**This belongs to `ingest_inbox()`, not `ingest_dir()`** — a design constraint,
not a detail. The folder to delete is the directory `ingest_dir()` was *called
on*, and a function must not delete its own root. The first implementation put
the sweep inside `ingest_dir()`, where the never-delete-the-root guard
(correctly) refused every folder it was handed and nothing was ever cleaned up;
the R-9.9 test caught it. `ingest_inbox()` is the only layer that sees the inbox
root and the folder as two different things.

Guards, all required:
- only directories strictly below the inbox root — never the root itself;
- "empty" means *no file that `ignore_rule()` would not ignore*, so a folder
  containing only `.DS_Store`/`.bak`/`.tmp` cruft counts as empty and that
  cruft is deleted with it. A literal `length(dir(f)) == 0` test never fires
  in practice: the real `batch-2026-07-23` folder is "empty" and still on disk
  precisely because Finder left a `.DS_Store` in it;
- never delete a folder holding a file that was kept back (quarantined,
  failed, or removal-refused for a missing/mismatched archive copy) — those
  are the files a human still has to look at;
- never delete a folder holding a **subdirectory**. Ingest is non-recursive
  (R-9.5), so nothing in there was ever routed and we know nothing about its
  contents; deleting it would breach R-9.5's "subdirectory content untouched"
  by unlinking data the pipeline never even looked at;
- never delete a folder holding a **zero-byte** file. `ignore_rule()` calls one
  `empty_file`, but that is a property of the file *right now*, not a permanent
  one like `.bak`/`.tmp`/`.DS_Store`: on a OneDrive/PowerAutomate inbox a
  0-byte file is routinely an attachment still mid-delivery. Treating it as
  ignorable meant attachment 1 committing and being removed (so the run *had*
  removed files, so the folder read as spent) while attachment 2 was destroyed
  before it was ever routed — the only copy of a lab deliverable, deleted
  unseen. An undeleted folder costs nothing; the next run tidies it once the
  bytes land;
- only when `remove_ingested` is TRUE. For a folder holding **real** files this
  is strictly downstream of R-9.6's existing gate, because those files are only
  removed once the run reached a verified snapshot. A **cruft-only** folder is
  the deliberate exception: nothing was committed and nothing retained, so
  there is no snapshot and no `removed_files` — and R-9.6's gate governs
  deleting files the DB now holds copies of, of which there are none here.
  Pinned by the AUDIT-5 test, which asserts `snapshot_path` is NA on exactly
  that path, so this exception cannot quietly widen.
Criteria: folder emptied by a clean run is gone; folder holding a `.DS_Store`
alongside removed sources is gone and the `.DS_Store` with it; a folder holding
**only** cruft is gone even though this run removed nothing from it (otherwise
`batch-2026-07-23`, the folder this whole feature was written for, can never be
cleaned); folder holding one quarantined file survives; folder holding a
subdirectory survives, with the subdirectory's contents intact; folder holding
a zero-byte file survives, with that file intact; the ingest root itself always
survives, empty or not.

## R-9.10 Retention alone justifies a snapshot

`.ig_remove_verified()` runs only when the run reached a snapshot, and a
snapshot happens only when `outcome$committed_any`. A run that commits nothing
but *does* retain a sibling — the COA that arrives in its own email a day
after the data, which Robin ruled on 2026-07-28 must attach to the existing
work order — therefore archives the file and then never removes the source, so
the folder never empties and R-9.9 never fires.

Retention is a core-table write (`asset` row + `ingest_file` transition), so it
earns a snapshot on exactly the same reasoning commits do. Snapshot when the
run committed anything **or** retained anything. The strict
commit → archive → snapshot → remove order of R-9.6 is unchanged; this only
widens what counts as "something happened". Criteria:
- a run whose only work is retaining one COA produces a snapshot and, under
  `remove_ingested = TRUE`, removes that COA's source;
- a run that neither commits nor retains still produces **no** snapshot and
  removes nothing;
- the R-9.6 criterion "TRUE + injected snapshot failure → nothing removed"
  still holds on the retain-only path.

**Ruled by Robin, 2026-07-28 — retention across runs.** A deliverable whose
work order committed in an *earlier* run attaches to that existing work order.
It must **never** create a project row: a work order we have never seen data
for is a guess, and `.ig_retain_siblings()`'s find-only
`SELECT uuid FROM project WHERE name = ?` is therefore correct as written and
must not be widened to `.ct_ensure_project()`'s find-or-create. The behaviour
already satisfies this ruling (the `project` table is persistent — 559 rows in
the live DB); what was wrong was only the roxygen at `R/ingest.R:310` and the
inline comment at `:707`, both of which claimed the work order had to have
committed "in THIS run". Criterion lives with R-15.36, which owns F.17.

## R-9.11 `quarantine_report()` (`R/ingest.R`)

Read-only, no writes, no connection left open: return one row per `ingest_file`
in a non-`archived` terminal state (`quarantined`, `failed`) with
`hash, filename, path_first_seen, state, state_reason, work_order_guess,
first_seen_at`, newest first. Nothing today surfaces these rows at all, which
is why 19 of them sat unnoticed in the live DB from 2026-07-23 until they were
found by hand.

`work_order_guess` is derived from the stored `filename`, not by re-reading the
file — the file is routinely gone by the time anyone runs the report, and a
report that errors on a missing file is a report nobody runs. Criteria:
- a DB with two quarantined rows and one archived row returns exactly the two;
- a clean DB returns a zero-row tibble with the full column set, not `NULL`
  and not a zero-column frame;
- the returned `work_order_guess` is populated for an `ES#######` filename and
  NA for a `2400-*` one (never guessed — the ACIRL trap);
- runs against a DB whose quarantined files no longer exist on disk;
- opens read-only and writes nothing (row counts across all tables unchanged).
