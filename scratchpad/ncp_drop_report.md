# Drop NCP cross-references — implementation report

## What the fix does
The ESdat Chemistry2e parser now marks NCP cross-reference results (compound
`<origWO>001_<homeWO>` SampleCodes) as `sample_type = "NCP"` at parse time, so
the R-7.4 multi-work-order partition (which runs on raw parser output, before
the sample-metadata join) counts them in `n_ncp_foreign` and drops them before
commit instead of leaking them as `foreign_work_order` review items.

## Files changed
- `R/adapter-esdat.R:198-215` — added NCP compound-SampleCode detection in
  `.st_esdat_parse_chemistry()`; `sample_type` is now `"NCP"` for compound
  codes, `"unknown"` otherwise. `work_order` unchanged (still the originating
  foreign WO via `.st_esdat_work_order_re`).
- `R/adapter-esdat.R` `ir_results(... sample_type = sample_type ...)` — was
  hard-coded `"unknown"`.

### Detection regex
`^[A-Z]{2}\d{7}\d*_[A-Z]{2}\d{7}$` — built as
`paste0(.st_esdat_work_order_re, "\\d*_[A-Z]{2}\\d{7}$")`, reusing the pinned
`.st_esdat_work_order_re` (`^[A-Z]{2}\d{7}`) so the WO shape stays consistent.
Verified against the real ES2617126 fixture: matches the ES/ME-prefixed
compound NCP codes (e.g. `ES2617015001_ES2617126`), does NOT match the home
`ES2617126001` (Normal) nor the `QC-...`-prefixed compound codes (out of scope,
left flagged as before — no over-broadening).

## Fixtures changed / why
- `tests/testthat/fixtures/esdat/generate.R` + regenerated
  `PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV` — added ONE compound NCP row
  `ZZ9999999001_XX1234567` (11 data rows now). The pre-existing plain
  `YY0000001` row is kept as the GENUINE foreign row (no `_<home>` suffix) that
  must still be flagged. Only this fixture + generate.R changed; all other
  esdat fixtures are byte-identical after regeneration.

## Tests changed / added
- `test-adapter-esdat.R` — row-count assertion 10→11; NEW test **R-4.6**:
  compound code parses `sample_type = "NCP"` with `work_order = "ZZ9999999"`;
  plain home (`XX1234567001`) and plain foreign (`YY0000001`) stay `"unknown"`;
  `ir_validate()` passes.
- `test-assemble.R` — NEW seam test (real ESdat parser → `assemble_events()`):
  compound NCP row counted in `n_ncp_foreign` (=1), absent from results, not in
  any `review_payload`; the plain `YY0000001` foreign row IS kept and flagged
  `foreign_work_order`. (Existing R-7.4 tests build events directly with
  explicit `sample_type` and were unaffected, as predicted.)

## Plans / docs updated
- `PLAN-04-adapter-esdat.md` — new **R-4.6** section (compound-SampleCode NCP
  detection) + criteria; fixture description updated.
- `PLAN-07-assembly.md` — R-7.4 now notes the NCP-drop path is genuinely
  reachable for Chemistry2e (parser sets the marker before the partition) and
  is seam-tested.
- `FIXTURES.md`, `COVERAGE-MAP.md`, `fixtures/esdat/README.md` — new row +
  R-4.6/seam test entries; Chemistry2e "10 rows" → "11 rows (NCP dropped → 10
  to event)".

## Full-suite totals
- Before: **P=2624 F=0 E=0**
- After:  **P=2654 F=0 E=0**  (+30 passes; no failures/errors)

## Falsification
Reverted ONLY the parser marker (`sample_type = sample_type` → `"unknown"`),
kept fixtures/tests:
- `test-adapter-esdat.R` → **R-4.6 RED** (P=87 F=1).
- `test-assemble.R` → **3 RED** (seam test: n_ncp_foreign becomes 0, ZZ leaks
  into results as a flagged foreign row).
Restored the marker → both files GREEN again (esdat P=88, assemble P=315).
Confirms the new tests actually pin the fix.
