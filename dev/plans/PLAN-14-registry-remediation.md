# PLAN 14 — live-DB registry data remediation (operator-run, one-off)

**Owns:** `dev/migrations/002-registry-remediation.R` (new),
`tests/testthat/test-migration-002.R` (new).
**Amends:** nothing in `R/`.
**Depends on:** **PLAN-13** — R-14.2 writes `lab_method.reported_as`,
`units` and `conversion_constant`, and the last two do not exist until plan 13
restores them (A63).

This is a **data** plan, distinct from plan 13's **schema** plan (A69). Every
item below fixes bad or missing data in the live registry that predates
sampleTidy. Nothing here has been applied.

<!-- block: B-14-which-database-and-the -->
## Which database, and the non-negotiable gate

The authoritative copy only (A67 — quote the absolute path in every log line):

```
/Users/rjs/OneDrive - Blue Mountains City Council/Sharepoint/
  waste_data - Environmental monitoring/data/monitoring.duckdb
```

**Same gate as plan 13, and it is a precondition on every requirement here:**
verified backup before any write (timestamped, migration-specific name — *not*
`snapshot_db()`, which is date-keyed and would overwrite itself on a same-day
second run); rehearsed on a copy first; abort writing nothing if the backup or
its verification fails.

**Every write goes through the plan-09 mutation layer** (`db_update()`,
`db_delete()`, `correct_value()`), never raw SQL, so each lands a `change_log`
row with an actor and a reason. This is real environmental compliance data; the
audit trail is the point, not a nicety.

**And it is now enforced, not merely asserted (Phase-3 D4).** The R-9.1
direct-write lint scopes to `R/`, and PLAN-13's gate explicitly exempts
`dev/migrations/` — so this rule had *no* mechanism behind it. It gets one here:
a test greps `dev/migrations/002-registry-remediation.R` for `dbExecute`,
`dbSendStatement`, `dbAppendTable` and `dbWriteTable` and **fails on any hit**.
The rule binds **002 only** — migration **001** rebuilds tables and is
necessarily raw DDL, which is exactly why A50 makes it operator-run and
lint-exempt. 002 only edits rows, so it has no excuse.

Criterion: the grep-based lint over `002-*.R` returns no raw write call.

<!-- block: B-14.1 -->
## R-14.1 Merge the duplicate `Carbophenothion` analyte rows

The live `analyte` table holds **two** rows named `Carbophenothion`, identical in
every field — same units `mg/L`, same CAS `786-19-6`, same
`conversion_constant = 1`:

| uuid | lab_methods | analyses |
|---|---|---|
| `31b21bfa-9344-43f8-811e-b1628fed2232` | 1 | **221** |
| `d0dc5ac3-d3e5-4bd8-ad30-4724c1377415` | 1 | **2** |

Both also carry `analyte_mask` rows (`long` on both; `EPA` with a NULL name on
`d0dc5ac3…`). Because the names are byte-identical they collide under **any**
key function — this is a duplicate row, not a normalisation artefact, and it is
one of the two collisions R-11.3 records as known-and-accepted until fixed here.

**Procedure** (user-confirmed): keep `31b21bfa…`; repoint `d0dc5ac3…`'s
`lab_method` row and its `analyte_mask` rows to the survivor; then delete
`d0dc5ac3…`. **No `analysis` row is touched** — analyses reach the analyte
*through* `lab_method`, so repointing the method carries its 2 analyses with it.

**Mask-collision dedup (Phase-8a clarification, 2026-07-22).** Because the
survivor already carries a `long` mask of its own (see the `long`-on-both note
above), a *blind* repoint of the doomed's `long` mask would leave the survivor
with **two** `long` rows — a silent duplicate that violates the no-duplication
criterion below and, post-plan-8, would trip the `db_update`/`db_delete`
"key must resolve to exactly one row" guard on any later mask mutation. So the
repoint is per-variant conditional: for a variant the **survivor already has**,
`db_delete` the doomed's colliding mask (the survivor's own row wins — the two
analytes are byte-identical duplicates, so the masks are too); for a variant the
survivor **lacks** (here `EPA`), `db_update`-repoint it as before. Net result:
the survivor ends with exactly one row per variant, no `analyte_mask` row
references the deleted uuid, and `change_log` records each delete/repoint.

**Idempotency depends on a PLAN-12 ruling (Phase-3 D2 — CONTRACT A72).**
R-12.6 is now pinned: `db_delete()` on a nonexistent uuid **aborts
`sampletidy_error`**. So a naive second run of this step would abort rather than
no-op, and the idempotency criterion below would be unsatisfiable. **This
requirement therefore carries an explicit existence pre-check**: read the analyte
row first and skip the whole merge (repoints included) when `d0dc5ac3…` is
already gone. The pre-check is the mechanism, not an optimisation — say so in the
script, because a later reader will otherwise "simplify" it away.

Criteria: exactly one `Carbophenothion` row remains, and it is `31b21bfa…`;
223 analyses (221 + 2) resolve to it; no `analyte_mask` row references the
deleted uuid; no `lab_method` row references it; a `v_measurement`-equivalent
join returns the same **row count** before and after (a merge must not hide or
reveal a measurement); the step is idempotent; `change_log` records the delete
and both repoints. After this lands, R-11.3's live property check drops
`Carbophenothion` from its allowlist and the analyte key count becomes 246 of
**246**.

<!-- block: B-14.2 -->
## R-14.2 Backfill `reported_as` and `conversion_constant` (A64/A63)

`lab_method.reported_as` records the **basis** a result is reported on. It is
NULL in all 360 rows — a data gap, not a dead column (A64). The basis currently
lives in the `lab_method.name` string instead, following ALS's own naming:

| lm name | method | reported_as should be |
|---|---|---|
| `Ammonia as N` | EK055G: Ammonia as N by Discrete Analyser | `N` |
| `Ammonia as NH3` | EK055G: Ammonia as N by Discrete Analyser | `NH3` |
| `Total Alkalinity as CaCO3` | ED037P: Alkalinity by PC Titrator | `CaCO3` |
| `Bicarbonate Alkalinity as CaCO3` | ED037P | `CaCO3` |
| `Carbonate Alkalinity as CaCO3` | ED037P | `CaCO3` |
| `Hydroxide Alkalinity as CaCO3` | ED037P | `CaCO3` |
| `Total Hardness as CaCO3` | EA065: Total Hardness as CaCO3 | `CaCO3` |

`conversion_constant` is set where the method's basis differs from its analyte's
basis, and is what `.ct_commit_analyses()` multiplies by on ingest (A63).

**The `Ammonia as NH3` case, stated precisely.** Its analyte is `NH3-N` — ammonia
expressed **as nitrogen** — so an as-NH3 reading is put on that basis by
multiplying by the mass ratio N/NH3. **The constant is `0.8224428`**, recovered
empirically from the 12 existing analyses (R-14.3), which the old pipeline had
already converted with it. (Theoretical 14.007/17.031 = 0.8224414; the two agree
to 1.4e-06. Use the **recovered** value — it is what reproduces the stored data
exactly.) It is **NOT 1.216**, which is the N→NH3 direction.

The four `… Alkalinity as CaCO3` methods and `Total Hardness as CaCO3` already
agree with their analytes' bases, so their constant stays NA.

⚠️ **This requirement writes `lab_method` only. It must NOT re-apply the
constant to the 12 existing analyses** — they are already converted (R-14.3).
The constant is recorded for two purposes at once: documentation of what was
already done, and so that A63's ingest-time multiplication converts *future*
as-NH3 rows the same way. Those two uses being consistent is the check that the
value is right: re-ingesting `ES2415638_0_XTAB.csv` after this backfill must
produce `2.14 × 0.8224428 = 1.76002759`, match the stored row, and report
`already_present` — not a second analysis, and not a `value_conflict`.

**Two things the regex does not decide, pinned here (Phase-3 D6 — it is an
unbounded pattern over 360 live rows with only 7 enumerated, and a worker would
otherwise have to invent both answers while writing live compliance metadata):**
1. **The unmatched set is reported, not ignored.** Every `lab_method` whose name
   does *not* match is listed in the run report with its name and method.
   `reported_as` stays NULL for them — a name that does not state a basis is not
   evidence of a basis.
2. **A matched row whose basis differs from its analyte's, and which is NOT one
   of the seven enumerated above, is REPORTED AND LEFT ALONE — no
   `conversion_constant` is invented.** Only `Ammonia as NH3` has a constant
   established by evidence (R-14.3). Guessing a constant for an eighth row would
   silently rescale real measurements, which is precisely the failure R-14.3
   documents having twice avoided.

Criteria: every `lab_method` whose `name` matches `(?i) as (\w+)$` has
`reported_as` set to that captured token; **a non-matching name leaves
`reported_as` NULL and appears in the reported unmatched set; a matched row with
a basis mismatch outside the enumerated seven gets NO constant and is reported**; a method whose basis equals its
analyte's basis has `conversion_constant` NA; `Ammonia as NH3` has
`reported_as = 'NH3'` and `conversion_constant = 0.8224428`; the step is
idempotent; **no `analysis.value` is altered, pinned by a row-count and
value-checksum comparison over `analysis` before and after**; and the re-ingest
idempotency check above passes — that is this requirement's real gate, because
it proves the constant, its direction, and the existing data all agree.

> **PROVISIONAL ORACLE (Phase-3 D5) — re-check in Phase 6 against real output.**
> That re-ingest gate names `ES2415638_0_XTAB.csv`, a **real corpus file**, and A3
> forbids committing real lab data as a fixture, so it cannot be an in-repo test.
> Pin it exactly like the R-10.5 corpus gates: a
> `skip_if(Sys.getenv("SAMPLETIDY_CORPUS") == "")`-guarded test that reads the file
> from the corpus and asserts `2.14 x 0.8224428 = 1.76002759`, `already_present`,
> no second analysis and no `value_conflict`. **A worker must not "solve" this by
> synthesising a fixture carrying the same numbers** — that asserts the arithmetic
> against itself and proves nothing about the live data, which is the entire point.
> The in-repo half of R-14.2 is the `analysis` row-count-and-checksum invariance,
> which IS testable without the corpus and is what actually guards against
> double-conversion.

<!-- block: B-14.3 -->
## R-14.3 ✅ CLOSED — the 12 `Ammonia as NH3` analyses are already correct

**No action. Do not touch these values.** Resolved 2026-07-22 by reading the
archived source, exactly as it should have been: the DB names the asset uuids,
and the assets are on disk.

Provenance, end to end: the 12 analyses belong to samples `ES2415638004`–`015`
(ALS lab sample ids), project `ES2415638` (`BWMF Apirl 2024 - Rain Event`),
whose `Chemical analysis` asset is
`assets/processed/08f1555c-18be-4167-a051-ba4f9fedea09/ES2415638_0_XTAB.csv`.

The report carries **both** bases, on different samples in one file:

```
EK055G: Ammonia as N by Discrete Analyser
Ammonia as N   ,7664-41-7,mg/L,0.01,, 0.40, 1.00, 36.6, ----, ----, ...
Ammonia as NH3 ,         ,mg/L,0.01,, ----, ----, ----, 2.14, 49.2, ...
```

Every stored value is the reported as-NH3 figure **× 0.8224428** — the NH3→N
mass ratio — with a maximum deviation of **1.4e-06** across all 12:

| lab id | reported (as NH3) | stored | ratio |
|---|---|---|---|
| ES2415638004 | 2.14 | 1.76002759 | 0.8224428 |
| ES2415638011 | 50.00 | 41.12214000 | 0.8224428 |
| ES2415638009 | 50.10 | 41.20438428 | 0.8224428 |
| *(all 12)* | | | **0.8224428** |

**The old pipeline already applied the basis conversion; it simply never
recorded the constant.** The seven significant figures that made these look
"derived" are the *signature of that multiplication*, not of a computed series.
All 12 sample dates also match the source exactly when read in
`Australia/Sydney` (the stored instants are UTC, per the known convention —
reading them with `CAST(date AS DATE)` shows the UTC calendar day and is what
made them look a day early).

**Both previously-proposed fixes would have corrupted good data:** × 1.216 would
have put them ~21.6% high; × 0.8225 would have double-converted them ~18% low.
The value of stopping to ask was the whole of it.

Criteria: **none — this requirement is closed with no write.** R-14.2 records
the constant that was used; a regression there proves a re-ingest of
`ES2415638_0_XTAB.csv` reproduces these exact stored values (see below).

<!-- block: B-14-fixtures -->
## Fixtures (Phase-3 D3)

Uses **`seed_pre_migration_db()`** from `tests/testthat/helper-migration-db.R`,
owned by PLAN-13 — plus this plan's own additions to it. R-14.1 is untestable
without **`analyte_mask`**, which no existing test DDL declares at all; the
helper adds it for exactly this reason.

The R-14.1 fixture needs, in that helper: two `analyte` rows with a
**byte-identical** name (the `Carbophenothion` shape), the survivor carrying many
analyses through its `lab_method` and the doomed row carrying few; one
`lab_method` per analyte; and **two `analyte_mask` rows on the doomed uuid**, one
of them with a NULL name (the live shape). Run this plan against the migrated
output of PLAN-13's script, not against a hand-built post-migration DDL — the
dependency is real and testing around it would hide a step-9 FK mistake.

<!-- block: B-14-gates -->
## Gates

- `testthat::test_file("tests/testthat/test-migration-002.R")` green for
  R-14.1 and R-14.2. R-14.3 contributes no test while it is open.
- Rehearsed on a copy; printed counts reviewed by the operator before the real
  run.
- A `v_measurement`-equivalent row count identical before and after the whole
  script — this plan changes registry *identity* and *metadata*, and (while
  R-14.3 is open) must not change a single measurement value.
- Every write appears in `change_log` with an actor and a reason.
- **Every log line the script emits quotes the absolute DB path** (Phase-3 D14).
  Given A67 — three `monitoring.duckdb` copies with genuinely different schemas —
  this is what stops a rehearsal against the wrong copy from passing unnoticed.
- The raw-write lint over `002-*.R` (R-14.2) is clean.
