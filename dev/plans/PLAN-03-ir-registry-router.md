# PLAN 03 — IR contract, adapter registry, file_meta, router

**Owns:** `R/ir.R`, `R/adapter-registry.R`, `R/file-meta.R`, `R/router.R`
+ test files. **Depends on:** 01, 02. **Blocks:** 04–07.

## R-3.1 IR constructors

`ir_results(...)` / `ir_samples(...)` build validated tibbles with **exactly**
the columns of DESIGN §4.1/§4.2 (names, types, order pinned there; `ir_results()`
with no args returns the zero-row prototype). `ir_validate(x, kind)` aborts
(class `sampletidy_ir_error`) on: missing/extra columns, wrong type, NA in
required fields (`source_hash`, `org`, `adapter`; for results also
`analyte_raw`, `value_raw`), `sample_type` not in
`c("Normal","LCS","MB","LAB_D","MS","NCP","unknown")`, `revision < 0`.
Criteria: prototype round-trips validation; each violation above has a test
asserting the error names the offending column.

## R-3.2 `file_meta(path)`

Returns list: `path`, `filename`, `ext` (lower-cased, no dot), `size`,
`hash` (R-1.2), `sheet_names` (xls/xlsx via `readxl::excel_sheets`, else
NULL), `peek` (first 2048 bytes decoded latin-1 — never errors on binary),
`work_order_guess` (first regex match `[A-Z]{2}\d{7}` in filename else NA),
`revision_guess` (from `_(\d+)[_.]` immediately after work order else NA).
Criteria: `"ES2600194_0_XTAB.csv"` → work_order `ES2600194`, revision 0;
`"1.ES2600185_0_XTAB.csv"` (junk prefix) → `ES2600185`;
`"BWMF x.ESDAT_ES2515460_0.Sample2e.CSV"` → `ES2515460`, rev 0;
`"2400-7539-05 May 2026 Monthly Katoomba WMF.xls"` → NA work order; a PDF
peek does not error; xls without readxl-readable sheets yields NULL + no error.

## R-3.3 Adapter registry

`register_adapter(a)` validates shape: `id` (chr), `version` (chr),
`match(file_meta) -> one of c("exact","format","fallback","no")`,
`parse(path, file_meta) -> list(results, samples, report)`. Registry is a
package-level environment; `adapter_registry()` returns adapters as a named
list; `clear_adapters()` empties it (tests). Registering a duplicate `id`
overwrites with a `cli_inform`. Criteria: malformed adapter (missing parse,
match with wrong formals) aborts naming the defect; register/overwrite/clear
round-trip.

## R-3.4 Ignore rules

`ignore_rule(file_meta)` — internal, evaluated before adapters. Returns a
reason string or NA. Pinned rules: extension in
`c("bak","tmp","ds_store")`; filename `.DS_Store`; **directories are never
passed in** (router works on files); filename matching `\[\d+\]` duplicate-
download markers is *not* ignored (content hash dedups those — rule must NOT
fire); zero-byte files → `"empty_file"`. Criteria: one test per rule, both
firing and non-firing cases (`ES2609437_0_Sample2e[94].CSV` must NOT be
ignored).

## R-3.5 `route_files(paths)`

For each path: build `file_meta`; apply ignore rules (→ state `ignored` with
reason); hash-check against `ingest_file` (already-terminal hash → record
sighting, skip; A13); else collect `match()` from every registered adapter
and pick by tier precedence `exact > format > fallback`:

- exactly one adapter at the winning tier → state `claimed` (store adapter id
  + tier);
- **two or more at the winning tier → state `quarantined`, reason
  `adapter_tie`, review_queue item `kind = "adapter_tie"`** listing both ids
  (DESIGN §5 — never pick a winner);
- all `no` → state `quarantined`, reason `unclaimed`.

Returns tibble `(path, hash, filename, state, adapter, tier, reason)` and
persists to `ingest_file` via plan-01 helpers. Criteria:
- one-exact-one-format file claims the exact adapter;
- registered tie at `exact` quarantines with both ids in the queue payload;
- unclaimed file quarantines as `unclaimed`;
- re-routing the same path is a no-op (state unchanged, one new sighting);
- a *different* path with an identical file (same hash) records a sighting
  and does not re-claim;
- `match()` throwing inside an adapter marks only that file `failed` with the
  error message in `state_reason` and continues with remaining files.

## R-3.6 Router cross-match harness (used by plan 10)

`router_matrix(paths)` returns tibble `(path, adapter, tier)` for every
registered adapter × path (no state changes). Criterion: over the plan-04/05/06
fixture set, every fixture is claimed by **exactly one** adapter at its
winning tier — this test lives in plan 10 but the harness lands here and has
a smoke test with two dummy adapters.

## R-3.7 `reconsider` — registry verdicts are not durable facts about a file

**Added 2026-07-28 (Robin).** `route_files()` short-circuits on
`already_routed <- nrow(existing) > 0 && !identical(existing$state[[1]], "seen")`,
and `unclaimed`, `adapter_tie` and router-`failed` are all terminal under
R-1.6. Together those make an adapter-registry verdict permanent.

But those three are not statements about the file. `ignored` (a `.bak`, a
zero-byte file) and `archived` are durable facts about the file itself;
`unclaimed`/`adapter_tie`/`failed` are statements about **the adapter registry
as it stood at the moment of the call**. The file did not change; our code did,
or will. Concretely, and already realised: `R/adapter-crosstab.R:104` records
that real ALS `.XLS` is SpreadsheetML, which `readxl` cannot open, so the peek
returns NULL and `match()` returns `"no"` — "SpreadsheetML parsing is parked
post-MVP". Eight `XTAB.XLS` files sit `unclaimed` in the live DB behind exactly
that. Unpark it and re-run, and nothing happens: they short-circuit at
`already_routed` and the new adapter is never consulted.

`route_files(paths, con, dry_run = FALSE, reconsider = FALSE)`. When
`reconsider` is TRUE, a stored state in the **registry-verdict set**
(`quarantined` with reason `unclaimed` or `adapter_tie`, or `failed`) is
treated as not-already-routed: the row is reset to `seen`
(`ingest_file_set_state(..., reset = TRUE)`) and re-decided from scratch.
`ignored` and `archived` are never reconsidered at any setting — those are
file facts. `claimed` and the mid-pipeline states are untouched: they are not
verdicts and resetting one would re-run work already done.

Deliberately **not** an R-1.6 change. The transition graph and its terminal set
stay exactly as pinned; `reset = TRUE` is the existing, explicit override and
this is precisely the case it exists for. `reconsider` defaults FALSE, so no
existing caller changes behaviour.

Under `dry_run` the reset is skipped along with every other write, matching
T1.2: a preview must not mutate `ingest_file`, and re-deciding without
persisting would report a verdict the DB does not hold.

Criteria:
- an `unclaimed` file, then an adapter registered that claims it, then
  `reconsider = TRUE` → `claimed` with that adapter (and the same call with
  `reconsider = FALSE` leaves it `unclaimed` — the control that proves the
  test can produce both outcomes);
- an `adapter_tie` file under `reconsider = TRUE` with the tie resolved →
  `claimed`; with the tie still live → `quarantined`/`adapter_tie` again and
  **exactly one** review_queue item in total, not a second one per pass;
- a router-`failed` file whose adapter's `match()` no longer throws →
  `claimed`;
- an `ignored` file (`.bak`, zero-byte) is NOT reconsidered even under
  `reconsider = TRUE` — still `ignored`, and `ignore_rule()` is what decides
  that, not the registry;
- an `archived` file is NOT reconsidered — the strongest guard, since
  re-deciding one could re-commit data already in the DB;
- `reconsider = TRUE, dry_run = TRUE` writes nothing: the stored state is
  still the old verdict afterwards;
- a file still unclaimed after reconsideration is left `quarantined`/
  `unclaimed`, not `seen` — a reset that fails to re-decide must not strand
  the row in a non-terminal state.
