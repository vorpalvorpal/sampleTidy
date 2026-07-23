# Cutover rehearsal report — 2026-07-23

Full end-to-end rehearsal of [`RUNBOOK.md`](RUNBOOK.md) **on copies only**.

**The authoritative database was never opened read-write and never modified.**

```
/Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb
  == (same device:inode 16777231:106169187) ==
/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb
  -rwx------ 1 rjs staff 51654656  28 May 07:25
```

Baseline measured read-only from that path:
**894 feature / 15,113 sample / 95,737 analysis / 360 lab_method / 247 analyte /
2,530 asset / 551 project / 390 analyte_mask / 2,767 feature_mask**, and
pre-migration-001 (no `feature_alias`, no `change_log`, no `ingest_*`, no
`review_queue`, no `schema_version`). This matches the brief's stated baseline
exactly.

## Rehearsal environment

| Role | Rehearsal stand-in |
|---|---|
| SharePoint `data/` | `/private/tmp/claude-501/cutover-rehearsal/sharepoint-sim/data/` |
| SharePoint `data/backups/` | `…/sharepoint-sim/data/backups/` |
| SharePoint `data/old/` | `…/sharepoint-sim/data/old/` |
| Local live DB | `/private/tmp/claude-501/cutover-rehearsal/live/monitoring.duckdb` |
| Migration backups | `…/live/migration-backups/` |
| Input dir | the **real** `…/assets/input` (read-only) |

Drivers: `/private/tmp/claude-501/cutover-rehearsal/rehearse{,2,3,3b,4,5,5b}.R`.
Logs: `…/cutover-rehearsal/logs/rehearse-part*.log`.
R 4.4.3, duckdb 1.4.1, macOS 25.5.0.

---

## Result summary

| Step | Result | Wall clock |
|---|---|---|
| 1. Preconditions | PASS | 0.07 s |
| 2. Dated archive + SHA-256 | PASS | 0.45 s |
| 3. Promote to local live + SHA-256 assert | PASS | 0.38 s |
| 4. `ensure_schema()` | PASS | 0.09 s |
| 5a. Migration 001 | PASS | 1.32 s |
| 5b. Migration 002 | PASS | 0.51 s |
| 5c. Migration 003 | **NOT RUN — does not exist** | — |
| 6. Registry changes (dry run + apply + idempotency re-run) | PASS after 1 fix | 5.47 s |
| 7. Verification battery (31 checks) | **31/31 PASS** | 0.11 s |
| 8. Snapshot round-trip (simulated SharePoint) | PASS | 0.81 s |
| 8a2. Same-day re-snapshot overwrite | PASS | 0.09 s |
| 8b. `prune_snapshots()` safety | PASS | 0.20 s |
| 9. Retire stale file to `old/` | PASS | 0.60 s |
| 8-real. Snapshot into the **real** SharePoint folder | **NOT EXECUTED** — see Deviation D3 | — |
| Extra. Re-ingest investigation (deliverable d) | **BLOCKING DEFECT FOUND** | ~40 s |

**Total for steps 1–9: 9.2 s.** Every file operation is an APFS clone
(`cp` of the 51.7 MB DB completes in ~0.07 s), so the real run's wall clock will
be dominated by operator verification, not by I/O.

---

## Step-by-step, with actual output

### 1. Preconditions

```
R version 4.4.3 (2025-02-28)
duckdb:  1.4.1
git status --porcelain:  M dev/plans/PLAN-15-…  ?? man/*.Rd  ?? scratchpad/
df -h /private/tmp:  228Gi total, 26Gi avail
authoritative DB size:  51654656 bytes
read-only open OK, feature rows = 894
```

### 2. Dated archive

```
copied: TRUE -> …/sharepoint-sim/data/archive/monitoring_pre-cutover_2026-07-23.duckdb
sha256 source : 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
sha256 archive: 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
SHA-256 MATCH
```

### 3. Promotion

```
copied: TRUE
sha256 sharepoint: 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
sha256 live      : 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
SHA-256 MATCH -> promotion verified
```

### 4. `ensure_schema()`

```
  version          applied_at
1       1 2026-07-23 13:14:53
2       2 2026-07-23 13:14:53
3       3 2026-07-23 13:14:53
4       4 2026-07-23 13:14:53
tables: analysis, analyte, analyte_mask, asset, change_log, feature, feature_mask,
        guideline, ingest_file, ingest_sighting, lab_invoice, lab_method, project,
        review_queue, sample, schema_version
```

### 5a. Migration 001

```
Backup verified: …/live/migration-backups/monitoring_pre-001-alias-indirection_20260723T031453.579Z.duckdb
To restore if needed: cp '<that path>' '<live>'
Pre-migration counts:  feature=894 sample=15113 analysis=95737 lab_method=360
766 ambiguous alias rows flagged auto_assign = FALSE.
Post-migration counts: feature=894 sample=15113 analysis=95737 lab_method=360
Step-11 verify passed: row counts and checksum unchanged.
001-alias-indirection migrated successfully.
status: migrated   ambiguous: 766
```

`feature_alias` = **1,989** rows (894 `self` + 1,095 imported), matching the
post-001 reference snapshot at
`/private/tmp/claude-501/qc-dryrun/snapshots/monitoring_pre-002-registry-remediation_20260722T232748.090Z.duckdb`.

### 5b. Migration 002

```
Backup verified: …/live/migration-backups/monitoring_pre-002-registry-remediation_20260723T031454.873Z.duckdb
002-registry-remediation applied.
status: migrated
carbophenothion: merged = TRUE, survivor = <uuid>, deleted = <uuid>   (analyte 247 -> 246)
reported_as matched: 16
```

### 5c. Migration 003 — placeholder

`dev/migrations/003-alias-date-bounds.R` **does not exist**. The rehearsal
proceeded without it and ran `cutover_verify(require_003 = FALSE)`. Consequence
observed downstream: the 17 E.5 alias arms remain `auto_assign = FALSE`, so keys
like `b.s01` and `k.e02` still land in review — visible in the re-ingest probe as
`unknown_feature` items for `K.E02` and `B.S01`.

### 6. Registry changes

**Dry run** correctly wrote nothing and previewed every item. **Apply**:

```
D.1 B.L05 created (uuid b491abc7-e750-40fe-91ea-7153bddc4380).
D.1 self alias 'b.l05' -> B.L05 created and confirmed (08150cab-…).
D.2 'trade waste dam' -> B.L01 created and confirmed (alias 8663341c-…).
D.2 'discharge point - lawson stp' -> B.L05 created and confirmed (alias 06dff8e5-…).
D.3 ES2413933: registered BWMF Apirl 2024 - Rain Event.ESDAT_ES2413933_0.Chemistry2e.CSV
D.3 ES2417442 … ES2608966: registered   [16 of 16, one per work order]
D.4a EN67 lab_method: added (6d9635a1-12af-40ae-ba08-d1969faac490).
D.4a ES2520710001: pH 7.41 re-attributed to EN67 (analysis e9c956ff-…).
D.4a ES2520710001: EA005P pH 6.40 added.
D.4a ES2520710002: pH 6.67 re-attributed to EN67 (analysis d07e7e13-…).
D.4a ES2520710002: EA005P pH 7.15 added.
D.4b ES2517594001: date corrected to 2025-05-28 14:00:00 (local 2025-05-29).
D.4b ES2517594002: date corrected to 2025-05-28 14:00:00 (local 2025-05-29).
```

**Idempotency re-run** — every item reported as already done:

```
D.1 B.L05 already present (uuid b491abc7-…) - skipped.
D.1 self alias 'b.l05' -> B.L05 already present - skipped.
D.2 'trade waste dam' -> B.L01 already confirmed - skipped.
D.2 'discharge point - lawson stp' -> B.L05 already confirmed - skipped.
D.3 ES2413933 … ES2608966: asset already registered - skipped.   [16 of 16]
D.4a EN67 lab_method: already_present (6d9635a1-…).
D.4a ES2520710001: pH 7.41 already on EN67 - skipped.
D.4a ES2520710001: an EA005P analysis already present (04753f55-…, value 6.4) - skipped.
D.4a ES2520710002: pH 6.67 already on EN67 - skipped.
D.4a ES2520710002: an EA005P analysis already present (29fef088-…, value 7.15) - skipped.
D.4b ES2517594001/002: date corrected …          <- log line only; db_update() wrote nothing
```

Idempotency verified at the `change_log` level, not just from the log lines —
grouping by `(tbl, action, uuid_row, field)` after apply **and** re-run shows
exactly two duplicate groups, both of them migration-002's intentional
FK detach/reattach pairs:

```
       tbl action                             uuid_row    field n
1 analysis update ed2fdb61-9533-446a-bb02-8f08a253bf06 uuid_lab 2   <- mig002 detach+reattach
2 analysis update 87651215-bb2b-46c0-869e-89a5e734e0de uuid_lab 2   <- mig002 detach+reattach
```

The re-run added **zero** `change_log` rows. (The D.4b line is cosmetically
misleading — `db_update()` skips a field whose value is unchanged, so no write
and no log row occurs; the message is printed unconditionally. Minor, noted.)

The two corrections in the log, with their old values preserved:

```
   tbl        uuid_row     field   old                  new                  actor
sample  ES2517594001      date     2025-09-08 14:00:00  2025-05-28 14:00:00  R. Shannon
sample  ES2517594001 date_start    2025-09-08 14:00:00  2025-05-28 14:00:00  R. Shannon
sample  ES2517594001  datetime     2025-09-09 02:50:00  2025-05-29 02:50:00  R. Shannon
sample  ES2517594001 datetime_start 2025-09-09 02:50:00 2025-05-29 02:50:00  R. Shannon
analysis e9c956ff-…    uuid_lab    1ab64e6f (EA005P)    6d9635a1 (EN67)      R. Shannon
analysis d07e7e13-…    uuid_lab    1ab64e6f (EA005P)    6d9635a1 (EN67)      R. Shannon
```

### 7. Verification battery — 31/31 PASS

```
cutover_verify(): /private/tmp/claude-501/cutover-rehearsal/live/monitoring.duckdb

[PASS] V01.feature       feature row count == 895        -- observed 895, expected 895
[PASS] V01.feature_alias feature_alias row count == 1992 -- observed 1992, expected 1992
[PASS] V01.sample        sample row count == 15113       -- observed 15113, expected 15113
[PASS] V01.analysis      analysis row count == 95739     -- observed 95739, expected 95739
[PASS] V01.lab_method    lab_method row count == 361     -- observed 361, expected 361
[PASS] V01.analyte       analyte row count == 246        -- observed 246, expected 246
[PASS] V01.asset         asset row count == 2546         -- observed 2546, expected 2546
[PASS] V02  exactly one `self` feature_alias per feature -- self aliases 895, features 895
[PASS] V03  every sample joins to a feature through its alias -- 15113 of 15113
[PASS] V04  every analysis joins to a sample AND a lab_method -- 95739 of 95739
[PASS] V05a schema_version contains the 4 ops migrations + the 001 marker (1001)
                                                          -- versions present: 1, 2, 3, 4, 1001
[PASS] V05b schema_version has no duplicate version rows  -- 5 rows, 5 distinct
[PASS] V06  all ops tables + feature_alias exist          -- missing:
[PASS] V07  lab_method has `units` and `conversion_constant`
[PASS] V08a exactly one Carbophenothion analyte remains   -- observed 1
[PASS] V08b lab_method.reported_as is backfilled (> 0)    -- 16 rows have reported_as
[PASS] V09a B.L05 present exactly once                    -- 1 row(s)
[PASS] V09b B.L05 site == 'B' and coordinates are WGS84 decimal degrees
                       -- site=B lon=150.431198 lat=-33.732518 matrix=leachate
[PASS] V10  the 3 curated aliases resolve to the right feature, confirmed, auto_assign = TRUE
      -- b.l05->B.L05(auto=TRUE,by=R. Shannon); discharge point - lawson stp->B.L05(…);
         trade waste dam->B.L01(…)
[PASS] V11a all 16 orphaned Chemistry2e files registered, one per work order
                                              -- 16 asset row(s), 16 distinct work orders
[PASS] V11b every registered asset carries a 64-hex SHA-256 hash -- hash lengths: 64
[PASS] V12  ES2520710001/002 each carry BOTH pH values, each under its own method
      -- ES2520710001 EA005P=6.4; ES2520710001 EN67=7.41;
         ES2520710002 EA005P=7.15; ES2520710002 EN67=6.67
[PASS] V13a ES2517594001/002 dated 2025-05-28 (stored) = 2025-05-29 local
      -- ES2517594001 date=2025-05-28 datetime=2025-05-29 02:50:00;
         ES2517594002 date=2025-05-28 datetime=2025-05-29 03:10:00
[PASS] V13b ES2517594 now shares its sampling day with ES2516159 -- 5 of 5 rows on 2025-05-28
[PASS] V14a change_log is non-empty                       -- 64 rows
[PASS] V14b change_log has an insert row for B.L05        -- 1 row(s)
[PASS] V14c change_log has an insert row for each of the 16 assets -- 16 of 16
[PASS] V14d change_log records the ES2517594 date correction -- 4 date/datetime update rows
[PASS] V14e change_log records the ES2520710 pH re-attribution -- 2 uuid_lab update rows
[PASS] V14f every change_log row has both an actor and a reason -- 0 rows missing
[PASS] V15  seven known pre-existing features survived the promotion -- 7 of 7

31 checks, 31 passed, 0 FAILED -> OK
```

#### Proof the battery can actually FAIL

The **first** rehearsal attempt aborted mid-way through step 6 (see Deviation
D1), so the battery ran against a DB that had been migrated but had received no
registry changes. It failed loudly and specifically — this is the real,
unedited output of that run:

```
31 checks, 14 passed, 17 FAILED -> NOT OK

[FAIL] V01.feature       feature row count == 895        -- observed 894, expected 895
[FAIL] V01.feature_alias feature_alias row count == 1992 -- observed 1989, expected 1992
[FAIL] V01.analysis      analysis row count == 95739     -- observed 95737, expected 95739
[FAIL] V01.lab_method    lab_method row count == 361     -- observed 360, expected 361
[FAIL] V01.asset         asset row count == 2546         -- observed 2530, expected 2546
[FAIL] V09a B.L05 present exactly once                   -- 0 row(s)
[FAIL] V09b B.L05 site == 'B' and coordinates are WGS84  -- absent
[FAIL] V10  the 3 curated aliases …                      -- none found
[FAIL] V11a all 16 orphaned Chemistry2e files registered -- 0 asset row(s), 0 work orders
[FAIL] V11b every registered asset carries a 64-hex hash -- hash lengths:
[FAIL] V12  ES2520710001/002 each carry BOTH pH values   -- ES2520710001 EA005P=7.41;
                                                            ES2520710002 EA005P=6.67
[FAIL] V13a ES2517594001/002 dated 2025-05-28            -- ES2517594001 date=2025-09-08
                                                            datetime=2025-09-09 02:50:00
[FAIL] V13b ES2517594 shares its day with ES2516159      -- 3 of 5 rows on 2025-05-28
[FAIL] V14b change_log has an insert row for B.L05       -- 0 row(s)
[FAIL] V14c change_log insert row per asset              -- 0 of 16
[FAIL] V14d change_log records the ES2517594 date fix    -- 0 date/datetime update rows
[FAIL] V14e change_log records the ES2520710 pH fix      -- 0 uuid_lab update rows
```

Note V12 and V13a: they printed **the actual defects** (`EA005P=7.41` — the
mislabelled client pH; `date=2025-09-08` — the impossible date). Those two checks
demonstrably detect the exact wrong outcomes they were written for, against a
real database.

The 14 that passed in that run are the ones that *should* have (row counts for
`sample`/`analyte`, the join integrity checks, the schema/migration markers,
`V15`) — the battery is not uniformly wired to one condition.

**Checks whose failure mode I could not demonstrate in this rehearsal**, stated
honestly rather than glossed:

- `V03` / `V04` (join integrity) and `V02` (self-alias-per-feature) never failed,
  because migration 001 behaved correctly. They *can* fail — V02 would fail today
  if `cutover_add_bl05_self_alias()` were removed (B.L05 would be a feature with
  no self alias: 894 self vs 895 features) — but I did not run that negative
  case, so their sensitivity is argued, not measured.
- `V05c` (migration-003 marker) has never executed at all, since 003 does not
  exist. It is `require_003 = FALSE`-gated and untested.
- `V08b` asserts `> 0` rather than an exact number. It catches "the backfill never
  ran" but would not catch "the backfill ran on the wrong rows". The exact count
  is 16 today; I left it as `> 0` because PLAN-14 pins the *rule*, not the count,
  and a future lab_method insert legitimately changes it. **Stated as a
  limitation, not shipped as a strong check.**

### 8. Snapshot round-trip (simulated SharePoint)

```
snapshot_db() -> …/sharepoint-sim/data/backups/monitoring_2026-07-23.duckdb (0.1s, 61,353,984 bytes)
# A tibble: 8 × 4
  table          live snapshot ok
1 feature         895      895 TRUE
2 feature_alias  1992     1992 TRUE
3 sample        15113    15113 TRUE
4 analysis      95739    95739 TRUE
5 lab_method      361      361 TRUE
6 analyte         246      246 TRUE
7 asset          2546     2546 TRUE
8 change_log       64       64 TRUE
snapshot round-trip OK
sha256 live    : 73cd0087b0984744b38ff3a1d03d313764b01b46a88041ec5047888d660a124a
sha256 snapshot: 73cd0087b0984744b38ff3a1d03d313764b01b46a88041ec5047888d660a124a
```

Byte-identical after `CHECKPOINT`, no `.tmp` residue, re-openable read-only.

**Same-day re-snapshot** (date-only naming is confirmed, not a bug):

```
snapshot files before: 1   after: 1
path: …/backups/monitoring_2026-07-23.duckdb
CONFIRMED: a same-day second snapshot overwrites in place, no proliferation.
```

**`prune_snapshots()` safety**, reproducing the real `data/backups/`
neighbours (`qs_archive/`, `.DS_Store`) plus three aged dated snapshots:

```
before prune:
[1] ".DS_Store"  "monitoring_2026-01-05.duckdb"  "monitoring_2026-01-19.duckdb"
    "monitoring_2026-02-11.duckdb"  "monitoring_2026-07-23.duckdb"  "qs_archive"
after prune (keep_days = 60):
[1] ".DS_Store"  "monitoring_2026-01-19.duckdb"  "monitoring_2026-02-11.duckdb"
    "monitoring_2026-07-23.duckdb"  "qs_archive"
qs_archive intact: TRUE   contents: analysisDF.qs
.DS_Store intact: TRUE
```

Correct on all three counts: the aged `2026-01-05` was pruned; the last snapshot
of each aged month (`2026-01-19`, `2026-02-11`) survived; and neither
`qs_archive/` nor `.DS_Store` was touched.

**Real-folder configuration verified read-only** (see Deviation D3 for why the
write was not performed):

```
st_config("snapshot_dir") = /Users/rjs/Library/CloudStorage/OneDrive-BlueMountains
                            CityCouncil/Sharepoint/waste_data - Environmental
                            monitoring/data/backups
dir.exists:  TRUE
writable:    TRUE
contents:    .DS_Store | qs_archive
free space:  24Gi avail on /dev/disk3s1
```

### 9. Retiring the stale pre-cutover file

```
renamed: TRUE -> …/sharepoint-sim/data/old/monitoring_pre-sampletidy-cutover_2026-07-23.duckdb
sha256 before: 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
sha256 after : 9902effecc2b39dc37cd8c796fbac3df5850663b6ebb940a9719dd3c6ea7867d
data/ now contains: archive  backups  old  snapshots
old/  now contains: monitoring_pre-sampletidy-cutover_2026-07-23.duckdb
data/monitoring.duckdb still exists? FALSE
```

Move is content-preserving and leaves no `monitoring.duckdb` in `data/`.

---

## Deliverable (d): what re-ingestion actually does — **BLOCKING**

Three probes, all on throwaway copies of the fully migrated + registry-changed
live DB.

### Probe 1 — the three re-downloaded work orders, clean real ingest

30 staged files (`ES2520710`, `ES2517594`, `ES2608966`, including the
bracket-suffixed duplicates).

```
30 file(s) routed, 3 event(s) (3 committed), 3 review item(s) opened
rows_new = 159   rows_already_present = 0   rows_superseded = 0   rows_skipped = 343
elapsed  = 2.7 s
files_by_state:  archived 12, ignored 1, quarantined 17

DELTAS:  feature 0 | feature_alias +2 | sample +5 | analysis +159 | lab_method +1
         analyte 0 | asset +6 | change_log +176 | review_queue +3 | ingest_file +26
```

ES2520710 after the re-ingest — the correction survived, and a **phantom
duplicate sample** appeared next to it:

```
uuid                                  feature  date        datetime
ES2520710001                          K.E01    2025-07-06  2025-07-07 00:00:00   <- legacy
c204e641-37dd-4b42-887d-9043ba2c9bda  K.E01    2025-07-07  2025-07-07 06:35:00   <- NEW duplicate
ES2520710002                          K.E02    2025-07-06  2025-07-07 00:00:00   <- legacy

pH analyses:
ES2520710001  2025-07-06  6.40  pH Value  EA005P: pH by PC Titrator     <- our correction
ES2520710001  2025-07-06  7.41  pH        EN67 - Client Supplied Data   <- our correction
ES2520710002  2025-07-06  7.15  pH Value  EA005P: pH by PC Titrator     <- our correction
ES2520710002  2025-07-06  6.67  pH        EN67 - Client Supplied Data   <- our correction
c204e641-…    2025-07-07  7.41  pH        EN67 - Client Supplied Data   <- duplicate on the phantom
```

ES2517594 likewise gained a duplicate `B.E01` sample dated **2025-05-29**
carrying the *same* `datetime 2025-05-29 02:50:00` as the (corrected) legacy row
dated 2025-05-28 — one calendar day apart, identical instant.

> **Answer to the brief's question:** re-ingestion alone does **not** produce the
> correct end state, and it is **not safe**. It neither touches the mislabelled
> EA005P row nor recognises anything as already present; it appends a whole
> parallel copy of the work order on an adjacent date. The supplementary
> correction (`registry-changes.R` D.4a / D.4b) is **required**, and those three
> work orders must **not** simply be re-ingested. Robin's KEEP-BOTH end state —
> exactly two correctly-labelled pH values per sample, no duplicates — is
> reached by the correction alone, and is broken by re-ingestion.

### Probe 2 — the full input directory (the proposed first-run scope)

```
input files: 295          290 file(s) routed, 90 event(s), 43 review item(s) opened
rows_new             = 3772
rows_already_present = 0          <-- ZERO, out of 6,725 rows
rows_superseded      = 0
rows_skipped         = 2953       (NCP / QC drops, not idempotency skips)
files_by_state:  ignored 24, quarantined 120, reconciled 146
FULL-DIR DRY RUN elapsed: 25.8 s
row counts after the dry run: unchanged (895 / 1992 / 15113 / 95739 / 361 / 246 / 2546 / 64)
```

The 43 review items match the figure the PLAN-15 dry-run gate has been reporting,
so the *review* prediction holds. The *idempotency* prediction does not:
**nothing at all is recognised as already present.** A real run at this scope
commits 3,772 duplicate analysis rows and ~90 events of duplicate samples.

### Probe 3 — controlled experiment isolating the cause

Three identical copies of the post-cutover DB, one work order (`ES2520710`),
real ingest each time:

| Case | `rows_new` | `rows_already_present` | `sample` delta |
|---|---|---|---|
| A. legacy rows untouched | 57 | **0** | +2 |
| B. `sample.date` restated to local-date-at-00:00 UTC | 57 | **0** | +2 |
| C. `date` **and** `datetime` aligned to the source file | 30 | **27** | **+1** |

Two independent causes, both necessary:

1. **Date off-by-one.** All 15,113 non-NULL legacy `sample.date` values are
   `13:00` (7,116) or `14:00` (7,995) — Sydney midnight stored as a UTC-naive
   TIMESTAMP — so `CAST(date AS DATE)` is one day earlier than the local sampling
   date. `.rc_find_existing()` (reconcile.R:742) and
   `.ct_find_or_create_sample()` (commit.R:331/339) both key on equality with the
   local date, which can never hold. `commit.R:369` writes NEW samples as
   local-date-at-00:00-UTC — a different convention.
2. **A62 "provably distinct" datetimes.** Legacy `sample.datetime` is frequently
   local midnight rather than the real time (ES2520710001 stores
   `2025-07-07 00:00`, the Sample2e says `16:35` local = `06:35` UTC). With
   non-NA datetimes on both sides and no equality, A62 correctly declares a new
   sampling event — and creates a second `sample` row even when the dates match
   (case B).

Case C's `already_present = 27` is exactly the figure `dev/HANDOVER.md` records
from the corpus gate, which runs against a self-consistent copy — corroborating
that the mechanism is the legacy convention, not a resolver bug.

**This needs Robin's ruling before the first real ingest.** Options are laid out
in RUNBOOK finding F2. I have not invented a fix.

### Supporting facts established for (d)

- **`.st_file_meta` does not exist.** The real function is `file_meta()`
  (`R/file-meta.R:29`, internal, no dot prefix). `exists(".st_file_meta")` is
  `FALSE`. The orchestrator's failed probe was a wrong name, not a defect.
- **Bracket suffixes do not disturb metadata.** `file_meta()` on all 30 staged
  files returned the correct `work_order_guess`/`revision_guess` for both plain
  and `[nn]`-suffixed names (`…Chemistry2e.CSV` and `…Chemistry2e[94].CSV` both
  → `ES2520710`, rev `0`; `ES2608966_COC.pdf` and `ES2608966_COC[87].pdf` both →
  `ES2608966`, rev `NA`).
- **`.st_esdat_parse()` dispatches on CSV header content, not filename** —
  confirmed: both members of each bracketed pair routed to adapter `esdat` and
  reached `archived`.
- **Every bracketed copy is byte-identical to its original** (SHA-256, 4 pairs
  checked). The re-download's real contribution is the `Sample2e.CSV` and
  `Header.XML` the original sets lacked. Content-hash dedup collapsed each pair
  to one `ingest_file` row (30 files → 26 rows).

---

## Deviations from the written runbook

**D1 — step 6 aborted on the first attempt (fixed, re-rehearsed clean).**
`cutover_curate_aliases()` resolved its target feature unconditionally, so the
**dry run** aborted on `discharge point - lawson stp` → B.L05: a dry run creates
nothing, so B.L05 did not exist. Error:
`Expected exactly 1 row for feature 'B.L05', found 0.` Fixed by making a missing
target a reported no-op *during a dry run only* (a missing target in a real run
still aborts). The whole rehearsal was then re-run from step 1 on a fresh copy;
all output above is from that clean run. **Silver lining:** the aborted run is
what produced the 17-failure evidence that the verification battery works.

**D2 — `cutover_add_bl05_self_alias()` is not in the original brief.** Added
during the rehearsal after discovering that `add_feature()` creates no `self`
alias, which post-001 leaves the new feature unreachable by its own name
(RUNBOOK F5). Without it, `feature_alias` would be 1,991 and `V02` would fail
(894 self vs 895 features). The general fix belongs in `add_feature()` and is
flagged, not patched.

**D3 — the real-SharePoint snapshot write was NOT executed.** The runbook's
step 8 requires a snapshot into the actual OneDrive-synced `data/backups/`, and
the coordinator asked for it explicitly. **The permission layer denied writing
into the SharePoint tree**, and I did not work around it: writing a 61 MB
rehearsal-content file into a live synced production folder is exactly the kind
of side effect that should require the operator's own consent. What I could
verify without writing: the destination resolves from `st_config()`, exists, is
writable, has 24 GiB free, and contains only `.DS_Store` and `qs_archive/`. The
full round-trip (checkpoint → `.tmp` → atomic rename → re-open read-only →
row-count compare → prune) was exercised end-to-end against a simulated folder
on the same filesystem and OS.
**Residual risk:** OneDrive's own behaviour on the `file.rename()` — placeholder
dehydration, or sync-in-progress locking the destination — is the one thing a
simulated folder cannot reproduce, and it is precisely the behaviour that
motivated DESIGN §9.1. **The operator must run `cutover_verify_snapshot()`
against the real folder as step 8 and confirm it before declaring cutover
complete.** Expected output is the 8-row `live == snapshot` tibble shown above
plus `snapshot round-trip OK`.

**D4 — migration 003 was not rehearsed** because it does not exist. Step 5c ran
as an explicit placeholder and `cutover_verify()` ran with `require_003 = FALSE`.
`V05c` has therefore never executed.

**D5 — the rehearsal used a simulated SharePoint tree** for steps 2, 8 and 9.
Only the paths differ; the operations (`cp`, `shasum`, `snapshot_db()`,
`prune_snapshots()`, `file.rename()`) are identical, and steps 2/9 are the same
kind of same-filesystem `cp`/`mv` in both.

**D6 — `ingest_dir(dry_run = TRUE)` is not side-effect free** (RUNBOOK F3).
Discovered mid-rehearsal: a dry run wrote 26 `ingest_file` rows and advanced them
to terminal states, after which an immediately following **real** run reported
`0 events, 0 committed, 0 rows` — it did nothing. Every subsequent ingest probe
was therefore run against a **fresh copy**. This is a real trap for the operator
and is now a runbook rule.

---

## Final state of the rehearsal live DB

```
feature       895      (894 + B.L05)
feature_alias 1992     (1989 + b.l05 self + trade waste dam + discharge point - lawson stp)
sample        15113    (unchanged; ES2517594001/002 re-dated in place)
analysis      95739    (95737 + the two EA005P lab pH values)
lab_method    361      (360 + EN67 - Client Supplied Data)
analyte       246      (247 - the merged duplicate Carbophenothion)
asset         2546     (2530 + 16 retained Chemistry2e files)
change_log    64
review_queue  0
schema_version 1, 2, 3, 4, 1001
```

All quoted against copies of
`/Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb`,
which was read but never written.

---

## Items requiring Robin's ruling

1. **⛔ F2 — the legacy `sample.date`/`datetime` convention makes re-ingest
   non-idempotent.** Blocks the first real `ingest_dir()` over the input
   directory. Three options in RUNBOOK F2; option (a), a date/datetime
   restatement migration, is the only one that restores idempotency.
2. **F5 — `add_feature()` should materialise a `self` `feature_alias`.** Patched
   for B.L05 only; any future `add_feature()` call reintroduces the gap silently.
3. **F7 — `asset.hash` is now mixed MD5 (2,407 legacy rows) and SHA-256 (16 new).**
   Backfilling means re-reading 2,407 archived files.
4. **F9 — `ingest_file.work_order` / `.revision` / `.uuid_asset` are never
   populated**, which weakens `.rc_recorded_revision()`'s supersede detection.
5. **`input_dir` and `archive_dir` still abort** when read from `st_config()`.
   Neither is on the default cutover path, but both belong in `~/.Renviron`
   alongside `SAMPLETIDY_SNAPSHOT_DIR`.
6. **Migration 003 does not exist.** Deferring it is safe (review, never a wrong
   feature) but leaves the 17 E.5 alias arms parked and most of the review burden
   in place.
7. **Incidental, unrelated to cutover:** `~/.Renviron` stores an
   `ANTHROPIC_API_KEY` and three other API keys in plaintext. Noticed while
   verifying `SAMPLETIDY_SNAPSHOT_DIR`; flagged, not touched.
