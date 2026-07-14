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
