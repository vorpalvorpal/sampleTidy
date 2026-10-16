# PLAN-17 — ACIRL monthly gas adapter

_Status: **LIVE** — planned 2026-10-16, nothing built. Rulings below are Robin's
(2026-10-16) unless marked open._

## Measured (2026-10-16, read-only; scripts in the session scratchpad `gas/`, `gas2/`)

- **16 `.xls`** "… Monthly Gas Monitoring …" under `assets/unprocessed`, plus 40 in
  `processed/` and 3 in `input2026-*`. No existing adapter claims any (all `no`).
- **Three geometry families.** Blaxland ≤2024 (2 files): `Gas Landfil #1/#2` +
  `Gas Buildings ` (trailing space; 3 cols, Location filled down; header row 11 in
  2021, 7 in 2024). Blaxland 2025+ (10 incl. 2 Weekly): `Gas Landfil #1–#3`, no
  buildings sheet, header row 7, Mar-2026 `#1/#2` shifted one column right; Weekly
  `#3` adds bare-number points `1`–`21`. Katoomba (4): `Gas Landfil #1/#2 ` (header
  row 6, one column in), `Gas Building 1/2/3` (4 cols, filled down),
  `Biofliter and Bores` (two unlabelled 2×3 grids + `Gas Bore MP1–MP4`).
- **CH4 only.** Values 0–0.44 % v/v, all exactly 2 dp to within 1e-9 (long tails are
  binary noise). No `<`, no blanks. Text: NS 262, NR 31, No Access 24,
  "does/Does not exist" 10, "Not on the map" 2.
- Front Page: `REPORT NO:`, `SAMPLED BY:`, `SAMPLE DATE:` (serial). Every sheet's
  `REPORT NO. :` agrees with the front page in all 16. Katoomba Dec-2025 notes
  "Biofilter and Bores sampled 5/1/26".
- **Probe numbers are not site-unique** (G186–G366 at both) → emit `B.`/`K.` from
  content, never the filename.
- **Legacy:** features `B.G###`/`K.G###`; CH4 in L/L via lab_method
  `CH4 Reading % v/v` (stored = % ÷ 100); zeros stored `value 0, quantified FALSE`;
  date-only with a synthetic +1 min per probe. For the 3 loaded months legacy =
  round(xls, 2)/100 on 565/565 rows. Legacy silently dropped all text values,
  B.G201, K.G365/366, all Katoomba buildings/bores, Blaxland buildings pre-Sep-2024.
- **Loaded:** 2400-7399-08-01, 2400-7453-07-01, 2400-7454-09-01. **New:** 13 others,
  ~2,600 readings.
- **Report numbers are unreliable:** 2400-7453-03-01 reused a year apart;
  2400-7538-05-01 on both a Monthly (05-04) and a Weekly (05-13); "24007127 - 05
  Amended"; 3 of 16 lack `-01`.
- **`.ct_reingest_guard()` does not fire for gas** (needs `type='Work order'` + prior
  asset rows). Re-imported months must come back `already_present` by design.
- `%` is a valid unit (→ L/L); `% v/v` is not.
- PDFs: 14 have an xls twin, 13 are text-layer PDF-only, 16 are photographed field
  sheets. **No PDF adapter now**; ask ACIRL for the Jan-2026 xls.

## Rulings

1. **Zero = non-detect**, matching legacy: `value 0, quantified FALSE`. The method
   detection limit is set to the lowest non-zero CH4 reading for now (migration,
   2026-10-16). Ask ACIRL for the analyser model and its CH4 LOD.
2. **Round to 2 dp in the adapter**; more precision than that → review.
3. **B.G368–G384 are building points** — map to the existing building features
   whatever sheet they appear on. Evidence: featureSFC places all 17 at the
   Gatehouse / Demountables / Reuse shed, south of the probe grid; its comment says
   building readings were given IDs from Sep 2024; the Aug-2024 "G368" on a landfill
   sheet was an empty template slot ("Not on the map").
4. **G179–G181 → B.TG179–181** (alias; ACIRL's name for Council's temporary points —
   not a misspelling). Coordinates in the May-2021 workbook match within 1 m.
5. **Import everything:** Katoomba bores MP1–4 (existing `MP_n` aliases → K.MW01–04),
   building readings, **biofilter grids** and **weekly points 1–21**. Names and
   locations for the last two are being researched (emails, featureSFC); Robin
   suggests `TG` names for the weekly points (likely the new cell) and a correctly
   sized 2×3 grid around the existing biofilter feature.
6. Reused report numbers: import and flag; ask ACIRL to reissue 2400-7453-03-01 (2026).
7. "24007127 - 05 Amended" → file as `24007127-05`, "Amended" in comments.
8. K.G365, K.G366, B.G201 → new features, via `unknown_feature` review (never guessed).

## Design

- **match:** new adapter `acirl_gas_xlsx`, tier `format`: xls/xlsx with a `/front/i`
  sheet and a `^Gas Landfil` sheet containing a `CH4 Reading` header cell.
- **parse:** front page via `.st_acirl_parse_front_page`; site from title / `REPORT
  ON` text; `work_order` = in-sheet REPORT NO (whitespace-normalised), filename token
  kept in `report$` and a mismatch → review. Blocks found by header text: each
  `Location` column pairs with the next `CH4 Reading` column, optional `Reference`
  between; fill Location down; stop at blank or note rows.
- **Features:** site-qualified `B.G182`, `B.G1` (resolver → B.G001). Buildings
  `{site}.{Location} - {Reference}`; repeated references within one building get `#2`
  (else A84 refuses them).
- **Values:** analyte_raw `CH4 Reading % v/v`, units_raw `%`, value_raw rounded to
  2 dp. Date-only from the serial; the biofilter/bores note overrides the date for
  those rows. Text values → `report$skipped` with reasons `no_sample`,
  `not_requested`, `no_access`, `point_absent`, `not_on_map`; no sample created.
- **Zero semantics** need a narrow parse rule: reconcile re-parses `value_raw` and
  ignores `below_detection`.
- **Filing (A80):** report-number project under campaign `Monthly gas monitoring`,
  type `Monthly gas monitoring` (needs `report$campaign` and a type used only when
  `.ct_ensure_report_project` creates). Gas `duplicate_report_number` fires when the
  existing project holds samples on a different date.

## Tests first

1. `match()` = `format` on each family fixture; every other adapter `no`; gas `no` on
   water/dust fixtures.
2. Header-text block location across column offsets 0/1, header rows 6/7/11, a `#3`
   block of 3 rows.
3. Note rows and the 2021 coordinates table yield nothing.
4. Location fill-down; duplicate references get `#2`.
5. Site from content not filename; `B.G1`, `K.G186`; B/K never cross.
6. REPORT NO from the cell; filename mismatch recorded.
7. `0.0299999999999999` → `0.03`; >2 dp → review.
8. Each text code skipped with its reason, no sample.
9. Zero → `quantified FALSE` per ruling 1.
10. Date from serial; biofilter/bores override; datetime NA.
11. `%` → stored 0.0003 end to end.
12. Filing under `Monthly gas monitoring`; merge into existing project;
    `duplicate_report_number` on a different date.
13. Re-ingesting a loaded month writes nothing new (all `already_present`).
14. G368–384 land on the building features; G179–181 on B.TG179–181.
15. Gated corpus test on the 16 real files: per-file counts match the census.

## Build order

1. Settle names/locations for weekly points and biofilter grids (in progress).
2. Synthetic fixtures per family + weekly, from the measured geometry.
3. Failing tests (separate test-writer agent).
4. Implementation (separate implementer agent): match → block finder → front page /
   site / report no → row emitter → register in `zzz.R` → zero semantics in
   `values.R`/`reconcile.R` → filing in `commit.R`.
5. Registry additions (aliases, new features) via the normal confirm flow or a
   migration.
6. Dry run on a DB copy: 565 loaded rows `already_present`; count review items.
7. Real run on Robin's go-ahead.
