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

**File *names* are not faithful; file *contents* are.** The real ESdat files
are named like `BWMF Apirl 2024 - Rain Event.ESDAT_ES2617126_0.Chemistry2e.CSV`
— a descriptive prefix with **spaces**, then the machine suffix. Two things
force a rename here (A47): `R CMD check`'s "portable file names" gate rejects
**any** space in a packaged file name, and it caps tarball paths at 100 bytes,
which the full real prefix exceeded. So fixtures use a short underscored
prefix. The machine part — `.ESDAT_<work order>_<revision>.<part>.CSV`, which
is what `match()` actually keys on — is untouched. The space-in-name shape is
still covered: `test-adapter-esdat.R` copies this fixture to a spaced,
real-shaped name in a temp dir at run time and asserts it matches and parses.

| fixture (in repo) | real source work order | format / notes |
|---|---|---|
| `esdat/SITEA_Rain.ESDAT_ES2617126_0.Chemistry2e.CSV` | ES2617126 | ESdat results, **latin-1** (72 non-ASCII bytes: `°`/`µ`/`±`), ~160 rows spanning many lab codes incl. `QC-MRG2/3/4` variants |
| `esdat/….ES2617126_0.Sample2e.CSV` | ES2617126 | ESdat samples; **all five QC types present** (LAB_D 20, LCS 18, NCP 18, MB 9, MS 6, Normal 1) |
| `esdat/….ES2617126_0.Header.XML` | ES2617126 | ESdat header (`Lab_Report_Number`, `Project_ID`, `Lab_Name`, …) |
| `crosstab/ES2600185_0_XTAB.csv` | ES2600185 | ALS XTAB crosstab, latin-1, single `Matrix:` section, `Unit`/`Limit of reporting` header spellings, a `----` not-computable cell |
| `crosstab/ES2600185_0_XTAB.XLS` | ES2600185 | **SpreadsheetML XML** twin of the `.csv` above (declares `ISO-8859-1`; `xml2` parses ~146 `Row` elements — `readxl` cannot read it). The real XTAB "`.XLS`" is XML, not binary BIFF (A37); anonymized as text with the same map. **SpreadsheetML parsing is parked post-MVP** — MVP asserts `match()=="no"` (graceful non-claim); the `.csv` twin carries the data. |
| `crosstab/ES2537534_0_ENMRG.CSV` | ES2537534 | ALS ENMRG crosstab, UTF-8, 7 samples, `Units`/`LOR` header spellings |
| `corpus-2026-10-19/latin1/ES2422258_0_XTAB.csv` | ES2422258 | ALS XTAB crosstab, **genuinely latin-1** (`b0 b5 b1 b0`: `°`/`µ`/`±`), 1 sample, 24 results. 2026-10-19 corpus finding (PLAN-05 R-5.4a): 103 such files failed with "invalid UTF-8". Anonymized with the map below (`B.E01`→`Q.E01`, `BWMF`→`SITEA`) |
| `corpus-2026-10-19/utf8-twin/ES2422258_0_XTAB.csv` | ES2422258 | the archived **UTF-8** copy of the same report (`c2b0 c2b5 c2b1 c2b0`); `iconv -f latin1` of the latin-1 file equals it byte-for-byte bar a trailing newline. Same anonymization |
| `corpus-2026-10-19/2400-9999-16_SerialZeroDate_WMF.xlsx` | 24007226-09-01 / ES2233700 | the real `Front Page` + `Groundwater Sites` sheets of `2400-7223-09-1 September 2022 Quarterly Katoomba WMF.xls`, re-written cell-by-cell as .xlsx by `corpus-2026-10-19/generate-serial-zero.R` (BIFF cannot be byte-anonymized). Its `Date of Sample` K11 is serial **0** (PLAN-06 R-6.3c). Text-only anonymization: Katoomba→SiteB, Lithgow→RegionA, person names, `BORE`→`WELL`, `MP #`→`PZ #` |

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

## ALS QCI text extracts (PLAN-19 phase 1b, `qci/`)

The QCI parser's input is the text of the PDF, not the PDF (R-19.18), so the
fixtures are **`pdftotext -layout` extracts** (poppler 25.09) of real QCIs,
which equal `pdftools::pdf_text()` pages joined with `"\f"` line for line
(measured on ES2609470, ES2011067, ES2028911; pdftotext only adds a final
`\f`). A line starting with `\f` begins a new page. The real PDFs are **not**
committed: a PDF cannot be anonymised byte-for-byte.

Anonymisation is **length-preserving** (every line keeps its length, so the
column x-positions the parser reads are untouched); ALS data, lab sample IDs,
methods, values and dates are unchanged. Script:
`qci/anon-qci.pl` (stdin to stdout), rules:

| real | anonymised | | real | anonymised |
|---|---|---|---|---|
| `Contact` / `Sampler` value (person) | `A. Contact` / `A. Sampler`, space-padded | | `Lawson` | `Hamlet` |
| `BLUE MOUNTAINS` | `EXAMPLE CLIENT` | | `Attunga` / `attunga` | `Ridgely` / `ridgely` |
| `Blackheath` | `Brookfield` | | `Katooma` (sic) | `Kingswy` |
| `BWMF` | `SITA` | | `BH.S0n` | `QH.S0n` |
| `K. Effluent` | `P. Effluent` | | | |

| fixture | source (assets/…) | layout covered |
|---|---|---|
| `qci/ES2609470_0_QCI.txt` | processed/257634a2…/ES2609470_0_QCI.pdf | MS "not determined" on Anonymous, `--` lab IDs, pH + BOD holding-time breaches, a frequency outlier, long surrogate phrasing |
| `qci/ES2027611_0_QCI.txt` | unprocessed/ES2027611_0_QCI.pdf | LCS low recovery, `QC-MRG2-…` lot on the method line, `----` on the next, wrapped analyte, short surrogate phrasing |
| `qci/ES2011067_0_QCI.txt` | unprocessed/ES2011067_0_QCI.pdf | two LCS rows (EC low, TKN high, wrapped comment), an MS row |
| `qci/ES2028911_0_QCI.txt` | unprocessed/ES2028911_0_QCI.pdf | holding-time client-ID lists, two per line over 4 lines, 3 methods; frequency rows with no method-code column |
| `qci/ES2028716_0_QCI.txt` | unprocessed/ES2028716_0_QCI.pdf | own-sample MS rows, lab ID alone on its own line |
| `qci/ES2519223_0_QCI.txt` | processed/799577f2…/ES2519223_0_QCI.pdf | 5 numeric MS failures, ED/EN lab IDs, a lab ID glued to the method name |
| `qci/ES2314145_0_QCI.txt` | processed/c7ec933f…/ES2314145_0_QCI.pdf | frequency outliers only |
| `qci/ES2014537_0_QCI.txt` | unprocessed/ES2014537_0_QCI.pdf | fully clean |
| `qci/ES2607384_0_QCI.pdf` | processed/b7ab659f…/ES2607384_0_QCI.pdf | the real 0-byte archived copy (`unreadable`) |
| `qci/ES2602084_0_QC.pdf` | **synthetic** stand-in for processed/ed2c1409…/ES2602084_0_QC.pdf | a PDF header with no xref/trailer: poppler fails as on the real (736 KB, not anonymisable) file |
