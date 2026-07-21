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
`lab_method` row and both its `analyte_mask` rows to the survivor; then delete
`d0dc5ac3…`. **No `analysis` row is touched** — analyses reach the analyte
*through* `lab_method`, so repointing the method carries its 2 analyses with it.

Criteria: exactly one `Carbophenothion` row remains, and it is `31b21bfa…`;
223 analyses (221 + 2) resolve to it; no `analyte_mask` row references the
deleted uuid; no `lab_method` row references it; a `v_measurement`-equivalent
join returns the same **row count** before and after (a merge must not hide or
reveal a measurement); the step is idempotent; `change_log` records the delete
and both repoints. After this lands, R-11.3's live property check drops
`Carbophenothion` from its allowlist and the analyte key count becomes 246 of
**246**.

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
expressed **as nitrogen**. Converting an as-NH3 reading onto that basis means
multiplying by the mass ratio N/NH3 = 14.007 / 17.031 = **0.8225**.
**It is NOT 1.216**, which is the N→NH3 direction and would compound the error
rather than remove it. The four `… as CaCO3` methods already agree with their
analytes' bases, so their constant stays 1/NA.

Criteria: every `lab_method` whose `name` matches `(?i) as (\w+)$` has
`reported_as` set to that captured token; a method whose basis equals its
analyte's basis has `conversion_constant` NA or 1; `Ammonia as NH3` has
`reported_as = 'NH3'` and `conversion_constant = 0.8225`; the step is
idempotent; **no `analysis.value` is altered by this requirement** (the constant
governs *future* ingests — historical values are R-14.3's problem, and R-14.3 is
open).

## R-14.3 ⚠️ OPEN — the 12 historical `Ammonia as NH3` analyses

**Do not implement. This requirement is blocked pending provenance from the
user, and must not be resolved by inference.**

Twelve `analysis` rows point at the `Ammonia as NH3` method and are stored
against the nitrogen-basis analyte `NH3-N` with no basis conversion ever having
been applied. On its face they are ~22% high and want × 0.8225.

**But they do not look like transcribed lab readings**, and if they are already
N-basis then any multiplication corrupts good data:

- seven significant figures — `2.163025`, `41.204384` — where the genuine ALS
  values on the *same samples* are clean 2–3 sig figs (`EC 280`,
  `Nitrate as N 4.16`, `Nitrite as N 0.08`, `SS 52`);
- `value_chr` is NULL on all 12, so no raw string was ever preserved;
- a daily cadence at exactly two features (B.E01, B.TS39) over six consecutive
  days, 7–12 May 2024 — six lab jobs would not look like that;
- the same samples also carry a `Computed: Leachate Mixing Fraction` row, and
  the dashboard repo has an `add_leachate_mixing_fraction.R`.

They appear **derived**. Resolving this needs the source of that 7–12 May
series, not more querying of the DB.

**Unblocking question for the user:** what produced the 7–12 May 2024 series at
B.E01/B.TS39? If a source report exists, comparing one value settles it in a
single look.

Only once answered: either (a) they are raw as-NH3 readings → `correct_value()`
each by × 0.8225 with a reason naming this plan, or (b) they are already
N-basis / derived → leave every value untouched and fix only the *labelling*
(which method they point at), or (c) they are neither and the rows need their
own decision.

Criteria: **none pinned** — this requirement is not specified until the question
above is answered. A test asserting current behaviour would pin a value we do
not yet know to be right.

## Gates

- `testthat::test_file("tests/testthat/test-migration-002.R")` green for
  R-14.1 and R-14.2. R-14.3 contributes no test while it is open.
- Rehearsed on a copy; printed counts reviewed by the operator before the real
  run.
- A `v_measurement`-equivalent row count identical before and after the whole
  script — this plan changes registry *identity* and *metadata*, and (while
  R-14.3 is open) must not change a single measurement value.
- Every write appears in `change_log` with an actor and a reason.
