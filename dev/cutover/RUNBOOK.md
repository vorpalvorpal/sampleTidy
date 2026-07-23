# sampleTidy production cutover runbook

Version 1.0 — written and rehearsed 2026-07-23.
Rehearsal evidence: [`REHEARSAL-REPORT.md`](REHEARSAL-REPORT.md).

---

## 0. What this does, in one paragraph

The authoritative database currently lives **inside** a OneDrive-synced folder.
DESIGN §9.1 says it must not: OneDrive does not respect DuckDB's file lock, and
will upload torn mid-write copies, spawn conflict files and dehydrate
placeholders. Cutover is therefore a **one-time PROMOTION** of that file into a
local, un-synced path, after which SharePoint is a **snapshot destination only**
— a one-way, checkpointed, atomically-renamed copy per session that changed the
DB. There is **no copy-back**. Nothing is re-ingested wholesale; existing rows
are kept; the cutover only ADDS rows (plus two itemised corrections).

### Paths (pinned)

| Role | Path |
|---|---|
| **Authoritative (pre-cutover)** | `/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb` |
| **Local live DB (post-cutover)** | `/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb` — the `st_config("live_db")` default, `tools::R_user_dir("sampleTidy","data")` |
| **Snapshot destination** | `.../waste_data - Environmental monitoring/data/backups` |
| **Retirement graveyard** | `.../waste_data - Environmental monitoring/data/old/` |
| **Dated pre-cutover archive** | `.../waste_data - Environmental monitoring/data/backups/archive/` (created at step 2) |
| **Input dir** | `.../waste_data - Environmental monitoring/assets/input` |

> **`/Users/rjs/OneDrive - Blue Mountains City Council` is a SYMLINK** to
> `/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil`. Both path
> strings resolve to the same device and inode (verified: `16777231:106169187`
> for `monitoring.duckdb`). They are **one file, not two copies** — this is not a
> fourth `monitoring.duckdb` in the sense of CONTRACT A67. **Pin the
> `CloudStorage` (real, non-symlink) form in configuration**; the `OneDrive - …`
> form is fine in prose and in a shell where `$HOME` expansion is convenient.

---

## 1. Preconditions — verify and announce

Run every check. Do not start if any fails.

```sh
SP="/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring"
ls -la "$SP/data/monitoring.duckdb"          # exists, ~51.7 MB
df -h "$SP" /                                 # >= 1 GB free on BOTH (3 x 51-61 MB copies land)
git -C /Users/rjs/dev/sampleTidy status --porcelain   # empty, or only files you intend to keep
```

```r
devtools::load_all("/Users/rjs/dev/sampleTidy")

# 1a. No other process is holding the DB. A read-only open does NOT prove this
#     (DuckDB permits many readers); a read-WRITE open on the file is the real
#     test, and it is the only step in this runbook that opens the SharePoint
#     file read-write — so DO NOT run it. Instead: quit every other R session,
#     close the dashboard, and confirm:
system("lsof '/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb'")
#     -> no output = nobody holds it.

# 1b. OneDrive has fully materialised the file (Files-On-Demand placeholders
#     read as 0 bytes on first touch — see HANDOVER's hydration note).
file.size("/Users/rjs/Library/CloudStorage/.../data/monitoring.duckdb")  # 51654656

# 1c. ALL THREE default-less config keys resolve. Each aborts with
#     class "sampletidy_error" when unset, and `snapshot_dir` aborts AFTER the
#     commit has already landed (R/ingest.R:409), which is the worst possible
#     time. `input_dir` and `archive_dir` are in the same class.
for (k in c("live_db", "snapshot_dir", "input_dir", "archive_dir")) {
  v <- tryCatch(st_config(k), error = function(e) paste("ABORT:", conditionMessage(e)))
  cat(sprintf("%-13s = %s\n", k, v))
}
stopifnot(dir.exists(st_config("snapshot_dir")), file.access(st_config("snapshot_dir"), 2) == 0)
```

`snapshot_dir` is set in `~/.Renviron` as
`SAMPLETIDY_SNAPSHOT_DIR=/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/backups`.
**This is a per-installation path, not a package default** — `R/config.R:13`
deliberately gives `input_dir`, `archive_dir` and `snapshot_dir` no entry in
`.st_config_defaults`. Do not "fix" this by editing `R/config.R`; verify it here
instead. See finding **F1** for what happens if you skip this check.

**Rollback:** none needed — nothing has been written.

---

## 2. Back up the SharePoint file to a dated archive, and record SHA-256

```sh
SP="/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring"
STAMP=$(date +%Y-%m-%d)
mkdir -p "$SP/data/backups/archive"
cp "$SP/data/monitoring.duckdb" "$SP/data/backups/archive/monitoring_pre-cutover_$STAMP.duckdb"
shasum -a 256 "$SP/data/monitoring.duckdb" \
              "$SP/data/backups/archive/monitoring_pre-cutover_$STAMP.duckdb" \
  | tee "$SP/data/backups/archive/monitoring_pre-cutover_$STAMP.sha256"
```

**Assert the two digests are identical before continuing.** This archive is the
durable insurance for the whole cutover and is **not** superseded by step 9's
move — keep both.

**Rollback:** `rm` the archive copy. The source is untouched.

---

## 3. Promote: copy SharePoint → local live path, assert SHA-256 equal

```r
live <- st_config("live_db")   # ~/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb
dir.create(dirname(live), recursive = TRUE, showWarnings = FALSE)
stopifnot(!file.exists(live))  # refuse to overwrite an existing live DB
src <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb"
stopifnot(file.copy(src, live))
```
```sh
shasum -a 256 "<src>" "<live>"      # MUST match
```

The SharePoint file is opened **read-only or not at all** from here on. Nothing
in the remaining steps writes to `data/monitoring.duckdb`.

**Rollback:** `rm "<live>"`. Nothing else has changed.

---

## 4. `ensure_schema()` on the local live DB

Creates `ingest_file`, `ingest_sighting`, `review_queue`, `change_log` and
`schema_version`, and records versions 1–4.

```r
with_db_write(function(con) {
  ensure_schema(con)
  print(DBI::dbGetQuery(con, "SELECT version, applied_at FROM schema_version ORDER BY version"))
}, db = st_config("live_db"))
```

Expect exactly versions `1, 2, 3, 4`. **This step is a hard prerequisite for
everything after it**: every mutation-layer write inserts its `change_log` row
in the same transaction as the data write, so on a DB without `change_log`
*every* registry change fails — after the data write, inside the same
transaction, so it rolls back, but noisily and repeatedly.

**Rollback:** `rm "<live>"` and redo step 3. (`ensure_schema()` is additive and
idempotent, so there is rarely a reason to.)

---

## 5. Migrations, in order

Each migration takes its own verified pre-migration backup and prints a
`restore_command`. **Record those two lines from the console** — they are the
per-step rollback. Put migration backups in a LOCAL directory, not in
SharePoint: they are session insurance, and three 51–61 MB copies in a synced
folder is churn nobody wants.

```r
MIGBAK <- file.path(dirname(st_config("live_db")), "migration-backups")
dir.create(MIGBAK, showWarnings = FALSE)
```

### 5a. `001-alias-indirection.R`

```r
env <- new.env(parent = globalenv())
sys.source("dev/migrations/001-alias-indirection.R", envir = env)
env$mig001_run(db = st_config("live_db"), snapshot_dir = MIGBAK, dry_run = TRUE)   # preview
env$mig001_run(db = st_config("live_db"), snapshot_dir = MIGBAK)                   # apply
```

Expect: `894` self-aliases, `1989` alias rows total, `766` flagged
`auto_assign = FALSE`, `schema_version` gains `1001`, and the step-11 gate
prints "row counts and checksum unchanged".

**Rollback:** `cp <backup_path> <live>` using the printed `restore_command`.
Migration 001 is transactional (steps 3–10 in one transaction, verify inside it),
so a mid-run failure leaves the DB untouched — but restore anyway if in doubt.

### 5b. `002-registry-remediation.R`

```r
env <- new.env(parent = globalenv())
sys.source("dev/migrations/002-registry-remediation.R", envir = env)
env$mig002_run(db = st_config("live_db"), snapshot_dir = MIGBAK, dry_run = TRUE)
env$mig002_run(db = st_config("live_db"), snapshot_dir = MIGBAK, actor = "migration-002")
```

Expect: `carbophenothion$merged == TRUE` (analyte 247 → 246), and 16
`lab_method` rows given `reported_as`.

**Rollback — read this before running:** 002 is *deliberately*
**non-transactional** (duckdb 1.4.1 refuses to UPDATE `lab_method.uuid_analyte`
while `analysis` references it, forcing a detach/reattach loop where each
`db_update()` commits on its own). A crash between a detach and its reattach
leaves an `analysis` row permanently orphaned in a way a re-run **cannot see or
repair**. `.mig002_torn_guard()` will abort a torn re-run loudly. **The only
recovery is to RESTORE THE PRE-MIGRATION BACKUP and re-run** — never re-run over
a torn DB.

### 5c. `003-alias-date-bounds.R` — **PLACEHOLDER, NOT WRITTEN**

> ⛔ **THIS MIGRATION DOES NOT EXIST YET.** PLAN-15 Work E pins its full spec
> (E.1 schema, E.5 data). It must:
> 1. `ALTER TABLE feature_alias ADD COLUMN date_start DATE` and
>    `... ADD COLUMN date_end DATE` — plain `ADD COLUMN`, **never** a table
>    rebuild (`DROP TABLE feature_alias` is refused: it is the main key table of
>    `sample`).
> 2. Set `auto_assign = TRUE` on **exactly the 17 arms** of E.5's 8 keys
>    (`b.s01`, `b.s04`, `b.s22`, `b.ts02`, `b.ts18`, `b.ts40`, `b.ts41`,
>    `k.e02`) and nothing else. Verified 2026-07-23 on the post-001 registry:
>    all 17 are currently `FALSE`. Without this flip every E.5 bound is inert.
> 3. Apply the 9 curated `date_end` literals of E.5 verbatim, each asserting it
>    matched **exactly one** row identified by (`alias_key`, target
>    `feature.name`).
>
> **Do not invent it here.** If cutover happens before 003 exists: run steps
> 6–9 without it and run `cutover_verify(require_003 = FALSE)`. Apply 003 later
> as a normal migration, then re-run `cutover_verify(require_003 = TRUE)`.
>
> **Consequence of deferring:** the 17 ambiguous alias arms stay
> `auto_assign = FALSE`, so keys like `b.s01`, `k.e02`, `b.s04` keep landing in
> review on every ingest. That is the *safe* failure direction (review, never a
> wrong feature), but it is most of the residual review burden.

**Rollback:** as 5a/5b once written — take a backup first, restore from it.

---

## 6. Registry data changes

```r
env <- new.env(parent = globalenv())
sys.source("dev/cutover/registry-changes.R", envir = env)
INPUT <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets/input"

env$cutover_registry_changes(db = st_config("live_db"), input_dir = INPUT, dry_run = TRUE)   # preview
env$cutover_registry_changes(db = st_config("live_db"), input_dir = INPUT, dry_run = FALSE)  # apply
```

Applies, in dependency order:

| Item | What | Rows |
|---|---|---|
| D.1 | feature `B.L05` "Leachate tankered to Lawson STP", site B, lon `150.431198`, lat `-33.732518` (EPSG:4326 — **decimal degrees, do not reproject**), matrix `leachate`, flow NULL | `feature` +1 |
| D.1b | the `self` alias `b.l05` → B.L05, created and confirmed — see finding **F5** | `feature_alias` +1 |
| D.2 | aliases `trade waste dam` → B.L01 and `discharge point - lawson stp` → B.L05, created then confirmed | `feature_alias` +2 |
| D.3 | the 16 orphaned ESdat `Chemistry2e` files registered as retained `asset` rows against their work-order projects | `asset` +16 |
| D.4a | ES2520710 pH: the two stored values (7.41 / 6.67) re-attributed from `EA005P: pH by PC Titrator` to a new `EN67 - Client Supplied Data` method, and the true lab values (6.40 / 7.15) added under EA005P | `lab_method` +1, `analysis` +2 |
| D.4b | ES2517594001/002 sampling date corrected from 2025-09-08 (local 2025-09-09) to 2025-05-28 (local 2025-05-29) | 8 field updates |

Every write goes through `db_append()` / `db_update()` / `confirm_feature_aliases()`,
so every change lands in `change_log` with an actor and a reason. The script is
idempotent: a second run reports every item as already done and writes nothing
(rehearsed — zero additional `change_log` rows).

**What is NOT here, deliberately:** the `auto_assign` flips and the `date_end`
literals of PLAN-15 E.5. Those are migration 003's, pinned there as data an
implementer "must use exactly". Duplicating them would give one fact two
writers. The two D.2 keys are disjoint from E.5's eight, neither exists in the
post-001 registry, and D.2 sets no date bounds — so there is no overlap.

**Rollback:** restore the migration-002 backup (`cp <mig002 backup> <live>`) and
re-run 5b's *post*-state — or more simply, restore the step-2 archive and redo
steps 3–6. `registry-changes.R` writes no backup of its own; the migration
backups from step 5 bracket it.

---

## 7. Verification battery — **the gate**

```r
env <- new.env(parent = globalenv())
sys.source("dev/cutover/verify.R", envir = env)
res <- env$cutover_verify(db = st_config("live_db"), require_003 = FALSE)
stopifnot(attr(res, "ok"))
```

31 checks. Expected end state:

| table | expected | = baseline + delta |
|---|---|---|
| `feature` | 895 | 894 + B.L05 |
| `feature_alias` | 1,992 | 1,989 + 3 curated |
| `sample` | 15,113 | unchanged |
| `analysis` | 95,739 | 95,737 + 2 lab pH |
| `lab_method` | 361 | 360 + EN67 |
| `analyte` | 246 | 247 − merged Carbophenothion |
| `asset` | 2,546 | 2,530 + 16 |

**Do not proceed past this step on a FAIL.** Every check states the wrong
outcome it catches; the failing rows are printed with that string.

**Rollback:** restore the step-2 archive to `data/monitoring.duckdb` — it never
moved — and `rm` the local live DB. The old file is still exactly where every
existing tool expects it, so a failed cutover is a no-op for everything else.

---

## 8. Snapshot round-trip — establish the one-way flow

```r
env <- new.env(parent = globalenv())
sys.source("dev/cutover/verify.R", envir = env)
env$cutover_verify_snapshot(db = st_config("live_db"))   # dest_dir = st_config("snapshot_dir")
```

This takes a real `snapshot_db()` into the SharePoint-synced `data/backups/`,
then re-opens the landed file **read-only** and compares row counts to the live
DB. It catches: a `.tmp` → final `file.rename()` that silently fails across a
synced folder; a snapshot taken without `CHECKPOINT` (short file); a snapshot
the reader cannot open (torn write — the entire reason for this architecture);
and an unset `snapshot_dir`.

Naming is **date-only**: `monitoring_YYYY-MM-DD.duckdb`. A same-day second
session **overwrites** the first, by design — `change_log` carries row-level
provenance, so a lost intra-day intermediate costs nothing. Do not propose
timestamped names. `prune_snapshots(keep_days = 60)` keeps 60 days of dailies
plus the last snapshot of every calendar month forever; it matches only the
anchored pattern `^monitoring_\d{4}-\d{2}-\d{2}\.duckdb$`, non-recursively, so
the existing `qs_archive/` subdirectory and `.DS_Store` in `data/backups/` are
untouched (rehearsed).

**A snapshot MUST be written after every session that changes the DB.** This is
a hard requirement, not best-effort. `ingest_dir()` does it automatically when
anything committed; a manual mutation session does not, so call `snapshot_db()`
yourself.

**Rollback:** `rm` the snapshot file. It is a copy; nothing depends on it yet.

---

## 9. Retire the stale pre-cutover file — **last, only after step 7 passed**

```sh
SP="/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring"
STAMP=$(date +%Y-%m-%d)
shasum -a 256 "$SP/data/monitoring.duckdb"
mv "$SP/data/monitoring.duckdb" "$SP/data/old/monitoring_pre-sampletidy-cutover_$STAMP.duckdb"
shasum -a 256 "$SP/data/old/monitoring_pre-sampletidy-cutover_$STAMP.duckdb"   # same digest
ls -la "$SP/data" "$SP/data/old"
```

- **`data/old/` is the established graveyard** for superseded storage — it
  already holds the pre-DuckDB `.qs` generation (`analysisDF.qs`, `sampleDF.qs`,
  `featureSFC.qs`, … Aug/Sep 2024).
- **The name matters.** Bare `old/monitoring.duckdb` still reads as a plausible
  "current" file and would reinvent exactly the confusion CONTRACT A67 records
  (three copies with different schemas, once treated as interchangeable).
  `monitoring_pre-sampletidy-cutover_YYYY-MM-DD.duckdb` is self-evidently frozen
  and dated.
- **Sequencing is deliberate.** Until step 7 passes, `data/monitoring.duckdb` is
  the rollback target and must stay exactly where every tool expects it. If
  verification fails, the file has not moved and rollback is a no-op.
- This is a **rename within one filesystem** (both paths are on device
  `16777231`), so it is cheap — but it *is* inside a synced folder. OneDrive will
  re-sync the move; do not interleave it with anything else touching that
  directory, and let sync settle before declaring done.
- The step-2 dated archive is **separate insurance and is not satisfied by this
  move**. Keep both.

**Rollback:** `mv` it back to `$SP/data/monitoring.duckdb`. Nothing reads the new
name yet.

### 9a. Things that hard-code `.../data/monitoring.duckdb` and will break

Swept 2026-07-23 across `/Users/rjs/dev`, `/Users/rjs/Documents`,
`~/Library/LaunchAgents`, `~/.Rprofile`, `~/.Renviron`. After step 9 these break
**outright** (file not found) rather than silently reading a frozen copy — the
better failure mode, but fix them in the same session:

| Where | Line | Action |
|---|---|---|
| `scratchpad/input_dryrun2.R` | `live_db <- file.path(sharepoint, "data", "monitoring.duckdb")` | Repoint to `st_config("live_db")`. This is the PLAN-15 verification dry-run script and will be wanted immediately after cutover. |
| `dev/HANDOVER.md` | `SAMPLETIDY_CORPUS_DB="$ROOT/data/monitoring.duckdb"` in the corpus-gate command | Repoint; the corpus gates read a **copy** of the real DB, so point them at a copy of the new live DB. |
| `dev/plans/CONTRACT.md` (A67, §"Existing DB schema"), `PLAN-11`, `PLAN-13`, `PLAN-14`, `PLAN-15`, `dev/HANDOVER.md`, `CONTRACT-STAGE-OBLIGATIONS.md` | prose citations of the authoritative path | Editorial only — no code executes them, but A67's "quote the absolute path with any measurement" rule now needs the new path. |

**Nothing else references it.** No other repo under `/Users/rjs/dev`
(`dashboard`, `leachatetools`, `tidyWaste`, `tidyWasteCore`, `report_service`,
…), no file under `/Users/rjs/Documents`, no LaunchAgent, and neither
`~/.Rprofile` nor `~/.Renviron` names `monitoring.duckdb`. The retired WEM.input
tree (`.../66.02 WEM.input/R/new/bmcc/waste_dir.R`) references the *folder*
`waste_data - Environmental monitoring` under a different base
(`~/Blue Mountains City Council/`) and never names the DB.

---

## 10. ⛔ BEFORE THE FIRST REAL INGEST — read finding F2

The first real `ingest_dir()` over the whole input directory is **NOT SAFE
TODAY**. Rehearsed on a copy: `rows_already_present = 0` out of 6,725 rows
across 290 files / 90 events. Every legacy sample would be **duplicated**, not
matched. See **F2** below for the proof and the two independent causes. This
needs Robin's ruling before the first ingest, and is not something this runbook
may invent a fix for.

---

# Findings

## F1 — `st_config("snapshot_dir")`: measured behaviour (RESOLVED, keep the check)

**Measured, nothing set:**

```
> st_config("snapshot_dir")
Error: No value is set for config key "snapshot_dir" (checked option
"sampletidy.snapshot_dir" and env var "SAMPLETIDY_SNAPSHOT_DIR"), and it has no
built-in default.
  class: sampletidy_error/rlang_error/error/condition

> snapshot_db(db = <live>)
Error: <the identical abort>          # snapshot_db()'s dest_dir default evaluates st_config()
```

It **aborts**; it does not fall back and does not warn. This matters because
`R/ingest.R:409` calls `snapshot_db(db, dest_dir = st_config("snapshot_dir"))`
**unconditionally** whenever `committed_any && !dry_run`, i.e. the abort lands
*after* the ingest transaction has already committed. The run would report a
committed ingest and then die on the snapshot, leaving the live DB changed and
SharePoint stale — precisely the divergence the one-way flow exists to prevent.

**Status: resolved by configuration, not by code.** `~/.Renviron` now carries

```
SAMPLETIDY_SNAPSHOT_DIR=/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/backups
```

Verified in a fresh session: resolves, `dir.exists()` TRUE, writable TRUE.

**This is not a defect in `R/config.R`.** `R/config.R:13` documents
`input_dir`, `archive_dir` and `snapshot_dir` as deliberately default-less —
machine-local paths that must be set per installation. **Do not add a default.**
The correct control is step 1's assertion that all three resolve *before*
anything writes. Note that as of 2026-07-23 `input_dir` and `archive_dir` still
abort; `archive_dir` is only reached when `remove_ingested` is TRUE (default
FALSE) or `archive_file()` is called, and `input_dir` only when a caller relies
on the default — so neither is blocking today, but both belong in the pre-flight.

## F2 — ⛔ BLOCKING: re-ingesting the existing corpus DUPLICATES it. Robin's ruling required.

**Measured** (full input directory, dry run, against a copy of the fully
migrated + registry-changed live DB):

```
290 file(s) routed, 90 event(s), 43 review item(s) opened
rows_new             = 3772
rows_already_present = 0        <-- ZERO
rows_superseded      = 0
rows_skipped         = 2953     (NCP / QC drops, not idempotency skips)
elapsed              = 25.8 s
```

Not one row of 6,725 was recognised as already in the database. A real run
would commit all 3,772 as new, creating duplicate `sample` rows and duplicate
`analysis` rows alongside the legacy ones. Confirmed on a real (non-dry) run of
three work orders: `sample` +5, `analysis` +159, `already_present` 0, with e.g.
a second `B.E01` sample dated 2025-05-29 sitting beside the (correct)
2025-05-28 legacy row carrying the *same* `datetime`.

**Two independent causes, both isolated by controlled experiment:**

1. **Date convention off-by-one.** Every legacy `sample.date` stores Sydney
   midnight as a UTC-naive TIMESTAMP — all 15,113 non-NULL values are `13:00`
   (7,116, AEDT) or `14:00` (7,995, AEST). Its DATE part is therefore one day
   *earlier* than the local sampling date. Both `.rc_find_existing()`
   (reconcile.R:742) and `.ct_find_or_create_sample()` (commit.R:331/339) match
   on `CAST(sample.date AS DATE) = <incoming Sydney-local date>`, which can
   never be true for a legacy row. `commit.R:369` writes NEW samples as
   local-date-at-00:00-UTC — a *different* convention, so sampleTidy's own rows
   are self-consistent and the legacy rows are permanently unmatchable.
2. **Datetime "provably distinct" (A62).** Legacy `sample.datetime` is often
   local midnight rather than the real sampling time (e.g. ES2520710001 stores
   `2025-07-07 00:00`, the ESdat Sample2e says `07 Jul 2025 16:35` = `06:35`
   UTC). With non-NA datetimes on both sides and no equality, A62 declares a
   *new sampling event* and creates a second `sample` row even when the dates
   agree.

**Experimental proof** (`ES2520710`, three identical copies of the post-cutover DB):

| Case | `rows_new` | `rows_already_present` | `sample` delta |
|---|---|---|---|
| unchanged legacy rows | 57 | **0** | +2 |
| `date` restated to local-date-at-00:00-UTC only | 57 | **0** | +2 |
| `date` **and** `datetime` aligned to the source file | 30 | **27** | **+1** |

Fixing *both* restores idempotency; fixing either alone changes nothing. (27 is
the same `already_present` figure `dev/HANDOVER.md` records from the corpus
gate, which runs against a self-consistent copy.)

**What this runbook does NOT do:** invent the fix. The options, for Robin:

- **(a)** A new migration that restates every legacy `sample.date` as the local
  calendar date at `00:00` UTC (+1 day for all 15,113 rows) **and** decides what
  to do about `datetime` — either restate it from the source files where they
  exist, or NULL it where it is a placeholder midnight (a NA on either side makes
  A62 fall back to date-granularity reuse, which is exactly the desired
  behaviour). This is the option that makes re-ingest idempotent.
- **(b)** Do not ingest anything already in the DB. Restrict the first real run
  to work orders with no `project` row, and accept that the historical corpus is
  never re-processed.
- **(c)** Accept the duplication and de-duplicate afterwards. Not recommended:
  `analysis` has no natural key to de-duplicate on once committed.

Until this is ruled, **step 10 stands: do not run `ingest_dir()` over the input
directory.** The cutover itself (steps 1–9) is unaffected and safe — it adds no
rows by ingest.

### RULING (Robin, 2026-07-23): `sample.datetime` is NOT to be touched

> *"It is mostly no time recorded with a few real 10am ones mixed in. Just leave
> them as they are at 10am."*

The 2,046 rows storing `00:00` are UTC-naive, i.e. **10:00 Sydney** — which is
how Robin reads them, and which corroborates the UTC-naive convention
independently. They are mostly placeholders, a few are genuine 10 a.m.
samplings, and the two are not separable from the data. **Do not restate, and
do not NULL, any `sample.datetime` value.**

**Consequence, and it is the important part:** option (a) is thereby dead as a
route to idempotency. Cause 2 (A62 datetime distinctness) is exactly the half
this ruling forbids fixing, and the rehearsal measured that fixing `date` alone
changes nothing — `already_present` stays at 0. A date-only migration 003 is
still worth doing eventually so `CAST(date AS DATE)` stops reading a day early
in ad-hoc queries, but it is **not** on the cutover path and it does **not**
make re-ingest safe.

**Therefore the standing policy is (b), permanently, enforced mechanically:** a
work order already represented in the DB is never re-ingested. Measured
2026-07-23 against a copy: of the 104 work orders of record in `assets/input`,
**96 already have `sample` rows and 8 do not**, and **no work order is
partially loaded** — every one is either wholly present or wholly absent, so
skipping the 96 loses nothing. The 8 are `ES2600185`, `ES2610538`, `ES2612444`,
`ES2614070`, `ES2614957`, `ES2616162`, `ES2616703`, `ES2617126`.

Because `ingest_dir()` takes a directory and has no allowlist, the first real
run stages those 8 work orders' files into their own directory and ingests only
that. A physically separate directory is a stronger control than a flag: it
cannot accidentally widen.

**Open, and proposed as the permanent guard (needs Robin's go-ahead):** a
work-order-level check that refuses to commit — routing to review instead — any
file whose work order already has `sample` rows. Without it, the rule above is
enforced by operator discipline alone, and the re-download episode is precisely
the case where discipline fails silently.

## F3 — a dry run is NOT side-effect free, and it poisons the real run

`ingest_dir(dry_run = TRUE)` writes `ingest_file` rows and advances their state
(`reconciled` / `quarantined` / `ignored`) even though it commits no data.
**Measured:** after a dry run left 26 `ingest_file` rows, an immediately
following **real** run on the same DB reported `0 events, 0 committed, 0 rows` —
it did nothing at all, because the files were no longer in a claimable state.

**Runbook rule:** dry-run on a **copy**, always. Never dry-run the live DB and
then "apply". This is why step 6 and every migration expose a `dry_run` that
writes nothing at all, while `ingest_dir()`'s does not.

## F4 — the 001 checksum does not cover `feature_alias`

`mig001_counts_checksum()` counts and checksums `feature`, `sample`, `analysis`
and `lab_method` only. `feature_alias` — the table 001 *creates*, and the sole
path from a `sample` to its `feature` — is in neither. 001's own step-11 gate
would therefore pass with a truncated or duplicated alias table. `verify.R`
compensates with three checks: `V01.feature_alias` (exact count),
`V02` (exactly one `self` alias per feature) and `V03` (every sample reaches a
feature through its alias). Not patched in 001 — that file is pinned and already
applied in rehearsal; the compensating control is the right level.

## F5 — `add_feature()` leaves a post-001 feature unreachable by its own name

`add_feature()` inserts a `feature` row and nothing else. Post-001,
`sample.uuid_feature_alias` is the only path to a feature, and migration 001
gave every then-existing feature a `kind = 'self'` alias. A feature created
*after* 001 has none, so `.rc_feature_candidates()` finds zero candidates for its
own name and every future row for it lands in review as `unknown_feature` —
forever, silently. `registry-changes.R` closes this for B.L05 specifically
(`cutover_add_bl05_self_alias()`), and `verify.R` V02 asserts the general
invariant (`self` aliases == features). **The general fix belongs in
`add_feature()`** and is flagged for Robin; this runbook does not edit `R/`.

## F6 — `.st_file_meta` does not exist; the real function is `file_meta()`

An earlier probe using the guessed name `.st_file_meta` failed for **all** files,
bracket-suffixed or not. That was the guess, not a defect: `R/file-meta.R:29`
defines `file_meta(path)` (internal, `@noRd`, **no dot prefix**).
`exists(".st_file_meta")` is `FALSE`; `exists("file_meta")` is `TRUE`.

**Bracket suffixes are harmless**, verified on all 30 staged files:

| file | `work_order_guess` | `revision_guess` |
|---|---|---|
| `KATOOMBA … ESDAT_ES2520710_0.Chemistry2e.CSV` | `ES2520710` | `0` |
| `KATOOMBA … ESDAT_ES2520710_0.Chemistry2e[94].CSV` | `ES2520710` | `0` |
| `ES2608966_COC.pdf` | `ES2608966` | `NA` |
| `ES2608966_COC[87].pdf` | `ES2608966` | `NA` |

macOS appends `[nn]` *before* the extension, after the `_<rev>_` anchor, so
neither `.st_work_order_re` (`[A-Z]{2}\d{7}`) nor `.st_revision_re`
(`^_(\d+)[_.]`, anchored immediately after the work order) is disturbed.
`.st_esdat_parse()` dispatches on **CSV header content**, not filename —
confirmed: both the plain and the bracketed Chemistry2e routed to adapter
`esdat` and reached state `archived`.

**And the bracketed copies are byte-identical duplicates** (SHA-256 verified):

```
109d43a74180245fd34017d7f7060be7ddec82c2c2f7891dec68cadc5177436c  …ES2520710_0.Chemistry2e.CSV
109d43a74180245fd34017d7f7060be7ddec82c2c2f7891dec68cadc5177436c  …ES2520710_0.Chemistry2e[94].CSV
ecd5d92aefdb69bbd566f70c933725d7271ab145dbae3b427d899ab09e1a7d44  …ES2517594_0.Chemistry2e.CSV
ecd5d92aefdb69bbd566f70c933725d7271ab145dbae3b427d899ab09e1a7d44  …ES2517594_0.Chemistry2e[56].CSV
18537a9e90e7489c9bc6fe198ab97349d1b56f1235504962b580fe20a317eb8f  …ES2608966_0.Chemistry2e.CSV
18537a9e90e7489c9bc6fe198ab97349d1b56f1235504962b580fe20a317eb8f  …ES2608966_0.Chemistry2e[81].CSV
2e5b0a7bd8e646f96c62b4b1bc9c7ccf5483569173200379bcbab779f8ebb326  ES2608966_COC.pdf
2e5b0a7bd8e646f96c62b4b1bc9c7ccf5483569173200379bcbab779f8ebb326  ES2608966_COC[87].pdf
```

The re-download's real contribution is the **`Sample2e.CSV` and `Header.XML` the
original sets lacked** — that is what un-orphans these three Chemistry2e files.
Content-hash dedup (A20/A46) collapses each pair to one `ingest_file` row, so the
duplicates cost nothing. **Do not delete them** — but note the DB will record
whichever member of the pair the router saw first, which in rehearsal was the
bracketed one.

## F7 — `asset.hash` becomes mixed-algorithm

All 2,407 non-NULL pre-existing `asset.hash` values are 32 hex characters, i.e.
**MD5**, written by the retired WEM.data loader (123 rows are NULL). The
package's `hash_file()` is **SHA-256**, so the 16 rows D.3 adds are 64 hex
characters. `verify.R` V11b asserts the new rows are 64-hex. Not "fixed" here:
back-filling 2,407 SHA-256 digests means re-reading 2,407 archived files and is a
separate decision. Flagged for Robin.

## F8 — `ES2517594_0_XTAB.XLS` is not a readable BIFF file

`readxl::excel_sheets()` fails with libxls "Unable to open file", and the router
quarantines it. The date confirmation for D.4b therefore came from
`ES2517594_0_XTAB.csv.bak` (a CSV rendering, `Sample Date:,,29/05/2025`), the
ESdat `Sample2e.CSV` (`29 May 2025 12:50` / `13:10`), and the DB's own `project`
row (`date_start = date_end = 2025-05-29`) — three independent sources, all
agreeing. Informational; the XLS is retained as an asset either way.

## F9 — `ingest_file.work_order` and `.revision` are never populated

Every `ingest_file` row after a full real ingest has `work_order = NA` and
`revision = NA`, including rows that reached `archived`, even though
`file_meta()` extracts both correctly (F6). `uuid_asset` is also NA on all rows.
Consequence: `.rc_recorded_revision()` (reconcile.R) derives the recorded
revision from `ingest_file.work_order` — with that column always NULL it falls
back to the `asset`-filename scan alone, which weakens supersede detection for
re-issued reports. Informational, not blocking for cutover; flagged for Robin.
