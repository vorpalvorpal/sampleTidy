# PLAN 08 — Reconciler

**Owns:** `R/reconcile.R`, `tests/testthat/test-reconcile.R`. **Depends on:**
01, 02, 07. Tests use the plan-01 `helper-db.R` throwaway DB seeded with a
small synthetic registry: 3 features (+1 mask alias), 3 analytes with units,
4 lab_method rows (one duplicate-method pair for R-8.6), 1 project, plus a
handful of pre-existing sample/analysis rows for the three-way tests.

`reconcile_event(event, con)` → `list(clean = tibble, review = tibble,
skipped = tibble, counts = named int)`. Read-only against the DB —
**no writes here** (commit is plan 09). Deterministic rules only; no LLM in
the MVP path (DESIGN §7).

## R-8.1 QC filter (first, cheap)

Rows with `sample_type != "Normal"` → `skipped`, reason `qc_<type>`, counted
per type. `NCP` never reaches here (plan 07) — assert defensively anyway.
Criteria: LCS/MB rows in a fixture event are skipped with reasons
`qc_LCS`/`qc_MB`; counts match; `"unknown"` sample_type rows are **not**
skipped (they're presumed monitoring data — crosstabs without Sample2e).

## R-8.2 Feature resolution

`feature_raw` → squish → match against `feature.name` then
`feature_mask.name` (any variant), case-insensitive exact. One hit →
`uuid_feature`. Zero hits → review `kind = "unknown_feature"` (payload:
feature_raw, work_order, n_rows affected). Multiple hits → review
`kind = "unknown_feature"`, subkind `ambiguous`, listing candidate uuids.
Criteria: direct name resolves; mask alias resolves to the masked feature's
uuid; the typo fixture (`T.S0l` for `T.S01`) queues one review item covering
all its rows (grouped — not one item per row); ambiguity (two features, same
mask name in fixture) queues with both uuids; **no fuzzy matching** — a
Levenshtein-1 miss stays unknown (deterministic-only rule).

## R-8.3 Analyte / method resolution

Normalise `analyte_raw` via `normalise_lab_text()` + squish. Lookup order:
1. `lab_method` on (name = analyte_raw, organisation = org) — and method,
   when `method_raw` present, as a filter if it disambiguates;
2. else `analyte.CAS` on `cas_number`;
3. else review `kind = "unknown_analyte"` (payload incl. any near-miss
   lab_method rows for the same org, as *information*, not auto-resolution).
Result: `uuid_lab` + `uuid_analyte` (from `lab_method.uuid_analyte`; CAS path
uses/queues a missing lab_method as unknown_analyte with subkind
`known_analyte_no_method` — still review, A6). Criteria: org-scoped name hit
resolves; same name under the *other* org does not cross-resolve; CAS
fallback finds the analyte but still queues (subkind above); full miss queues
grouped by (analyte_raw, org).

## R-8.4 Units & value

Resolved rows: convert `value_num`, `rl` from `units_raw` to `analyte.units`
via `unify_value()` (after `normalise_lab_text()` on both). Invalid/
incompatible units → review `kind = "unknown_unit"` (payload: units_raw,
analyte, example values). `parse_value` skip_reasons (`no_sample`,
`not_computable`, `empty`) → `skipped` with that reason. Text-only results
(`value_chr`) pass through unconverted with `quantified = TRUE`, units
ignored. Criteria: mg/L→µg/L row multiplies value and rl by 1000; `pH`
dimensionless passes; `"banana/L"` queues unknown_unit; an `NS` row lands in
skipped not review; BDL row keeps `quantified = FALSE` with converted rl.

## R-8.5 Sample datetime

Parse `sample_datetime_raw` (plan-02 formats; try `esdat` then `crosstab`).
Unparseable → review `kind = "parse_error"`, subkind `datetime`. Result per
row: `sample_date` (Date) + `sample_datetime` (POSIXct or NA per
`has_clock_time`; A11). Criterion: ESdat row yields both; crosstab/ACIRL row
yields date only; garbage queues.

## R-8.6 Method preference (DESIGN §7)

Within (feature, sample_date, analyte) in the incoming clean set, multiple
rows from different `uuid_lab`: keep lowest `lab_method.rl_low` (NA rl_low
loses to any number); tie → keep higher `value_num`; the dropped row →
`skipped`, reason `method_duplicate`, payload noting the kept uuid_lab.
Criterion: fixture duplicate-method pair keeps the lower-RL row; tie case
keeps higher value; skipped row references the winner.

## R-8.7 Three-way outcome vs DB (DESIGN §7; A11, A12, A14)

For each surviving row, look up existing analyses via sample
(`uuid_feature` + date-granularity match on `sample.date`, then `datetime`
when both non-NA) joined to analysis on `uuid_lab`→`uuid_analyte`:

- no existing row → **clean/new**;
- existing row, value equal per A14 → **skipped**, reason `already_present`,
  payload = existing `analysis.uuid` (provenance link recorded at commit);
- existing row, different value → **conflict**: if incoming `revision` >
  the **recorded revision** (A12) — max over (i) `ingest_file.revision` of
  files of the same work_order in state `committed`/`archived`, *excluding
  the current event's own files*, and (ii) `revision_guess` (plan-03 regex)
  applied to `asset.filename` for assets of the work order's project (legacy
  coverage; criterion: `XX1234567_1_COA.pdf` → 1, `XX1234567_COC_1.pdf` →
  NA) — NA when neither exists → clean with
  `supersedes = <analysis uuid>` (commit updates + change_logs it); else
  review `kind = "value_conflict"` (payload: both values, uuids, revisions).

Criteria: fresh row is new; identical re-ingest row is `already_present`
(the plan-10 idempotency backbone); value differing at 1e-12 relative is
already_present (tolerance), at 1e-3 is conflict; conflict with recorded
revision 0 and incoming revision 1 becomes a supersede row; conflict with no
recorded revision queues; equal values but different `quantified` → conflict.

## R-8.8 Output contract

`clean` = input IR columns + `uuid_feature, uuid_lab, uuid_analyte,
value_converted, rl_converted, sample_date, sample_datetime, supersedes`.
Review/skipped rows never appear in `clean` (disjoint, union = input rows
after QC filter). `counts` covers every disposition. Criterion: disjointness
+ completeness asserted on a mixed fixture event (every R-8.x case present at
once); reconcile is pure — DB row counts unchanged after run.
