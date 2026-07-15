# Real (anonymized) lab fixtures

Committed real ALS lab files, **anonymized**, pinned as the primary test
fixtures for the adapters (Robin, 2026-07-15). This **supersedes A3's** "no real
lab data committed" for these files: the underlying monitoring data is required
to be public by the EPA, so committing it is allowed. Only **sampling-point
identifiers and place/person names** were changed; **all analytical data
(dates, analytes, values, units, methods, CAS, EQL, work-order IDs, QC codes)
is byte-for-byte the original**, and the original file encodings (legacy latin-1
for ESdat + XTAB, UTF-8 for ENMRG) are preserved exactly — anonymization was
done at the **byte level** on ASCII substrings only, so the raw `0xB0` (`°`) /
`0xB5` (`µ`) bytes the encoding tests depend on are untouched.

## Files

| fixture (in repo) | real source work order | format / notes |
|---|---|---|
| `esdat/SITEA Apirl 2024 - Rain Event.ESDAT_ES2617126_0.Chemistry2e.CSV` | ES2617126 | ESdat results, **latin-1** (72 non-ASCII bytes: `°`/`µ`/`±`), ~160 rows spanning many lab codes incl. `QC-MRG2/3/4` variants |
| `esdat/….ES2617126_0.Sample2e.CSV` | ES2617126 | ESdat samples; **all five QC types present** (LAB_D 20, LCS 18, NCP 18, MB 9, MS 6, Normal 1) |
| `esdat/….ES2617126_0.Header.XML` | ES2617126 | ESdat header (`Lab_Report_Number`, `Project_ID`, `Lab_Name`, …) |
| `crosstab/ES2600185_0_XTAB.csv` | ES2600185 | ALS XTAB crosstab, latin-1, single `Matrix:` section, `Unit`/`Limit of reporting` header spellings, a `----` not-computable cell |
| `crosstab/ES2600185_0_XTAB.XLS` | ES2600185 | **SpreadsheetML XML** twin of the `.csv` above (declares `ISO-8859-1`; `xml2` parses ~146 `Row` elements — `readxl` cannot read it). The real XTAB "`.XLS`" is XML, not binary BIFF (A37); anonymized as text with the same map. **SpreadsheetML parsing is parked post-MVP** — MVP asserts `match()=="no"` (graceful non-claim); the `.csv` twin carries the data. |
| `crosstab/ES2537534_0_ENMRG.CSV` | ES2537534 | ALS ENMRG crosstab, UTF-8, 7 samples, `Units`/`LOR` header spellings |

The ACIRL real fixture (a genuine **binary BIFF** `.xls`, `readxl`-readable —
sheets `Front Page / Sampling Sites 1–4 / Dust… / Water Methodology`) will be
added for plan 06 by reading it with `readxl`, anonymizing the cell grid, and
re-writing as `.xlsx` (binary BIFF can't be byte-anonymized because
variable-length place-name replacements shift OLE offsets). Source set curated
by Robin under `…/assets/input/sampleTidy example`.

## Anonymization map (applied identically across all files)

Sampling-point codes — length-preserving prefix remap, guarded so a token is
never partially matched:

| real | anonymized | | real | anonymized |
|---|---|---|---|---|
| `K.S03/07/09` | `P.S03/07/09` | | `B.MW02/08/09` | `Q.MW02/08/09` |
| `B.E01` | `Q.E01` | | `B.S01/03/05/06` | `Q.S01/03/05/06` |
| `B.39/L01/S39` | `Q.39/L01/S39` | | | |

Place / facility / person names:

| real | anonymized | rationale |
|---|---|---|
| `ACIRL Lithgow` (Site column) | `Site C` | place name |
| `BWMF` (facility abbrev., filenames + `Project_ID`) | `SITEA` | place name |
| `BLAXLAND` / `Blaxland` (project names) | `SITEA` / `SiteA` | place name |
| `Katoomba` (project name) | `SiteB` | place name |
| `Lithgow` (any standalone) | `RegionA` | place name |
| `Dian Dao` (`Lab_Signatory`) | `A. Analyst` | **PII** — anonymized beyond the stated "point + place" scope; no test asserts it |

**Kept as-is:** all lab work-order IDs (e.g. `ES2617126`, `ES2600185`), lab
sample/QC codes, `Lab_Name="ALSE-Sydney"` (lab-branch org identifier, asserted
by R-4.4), and every analytical value. Verified: source vs anonymized non-ASCII
byte counts match exactly, and no original point/place/person string survives in
any committed file.

Anonymizer: `/tmp/anon.pl` (byte-level; see git history / this doc for the map).
