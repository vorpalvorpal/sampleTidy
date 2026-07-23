# EDA — 477 suspect reporting-limit rows + 315 `quantified = NA` rows

**Database (read-only throughout):**
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`

**Scripts** (all in `/Users/rjs/dev/sampleTidy/scratchpad/`, run with `Rscript`, every
connection opened `read_only = TRUE` and closed via `on.exit(dbDisconnect(..., shutdown = TRUE))`):

| script | output |
|---|---|
| `eda01_sample.R` | inline — schema + baseline counts |
| `eda02_core.R` | `out02.txt` — analyte/method/ratio/date/site breakdowns |
| `eda03_units.R` | `out03.txt` — unit-ratio test (`base_sql.R` holds the shared CTE) |
| `eda04_prov.R` | `out04.txt` — `change_log` provenance, work-order mixing, assets |
| `eda05_taskb.R` | `out05.txt` — prior-fix forensics + `quantified IS NULL` |
| `eda07_final.R` | `out07.txt` — fix predicate, residuals, text classification |
| `eda06_source.R` | inline — resolves `st_config("archive_dir")` |

Baseline (`eda01_sample.R`): `analysis` = 97,118 rows; `quantified` TRUE 49,576 / FALSE 47,227 / NULL 315.

---

## HEADLINE — read this first

**Both of your framings are wrong, and in the same direction: neither population is a data
problem in `value`. Both are artefacts of a metadata/units bug that has already been
diagnosed once in this very database.**

1. **TASK A (477 rows) is 100% a `rl_low` unit bug, not a value anomaly.** `analysis.rl_low`
   on these rows holds the LOR **in µg/L** while `value` was correctly converted to **mg/L**.
   All 477 rows resolve cleanly under `rl_low / 1000`. **This is exactly the same defect as
   the "already done, not these" 3,190-row fix** — `change_log` records that fix verbatim
   (`reason = "rl_low left in ug/L while value was converted to mg/L; corrected by /1000
   (Robin, 2026-07-23)"`). The earlier fix used a predicate that could only ever catch a
   subset. These 477 are its residue, not a separate phenomenon.

2. **TASK A1 and A2 are the same phenomenon**, split only by whether the lab reported a
   `<`-value or a number. There is no second mechanism.

3. **TASK B (315 rows) are not chemistry at all.** Every one is a **qualitative text
   observation** — analyte `Appearance` (295) or `Stage` (20), method `field`/`AS3580.10.1`,
   `value IS NULL`, `value_chr` = `"Cloudy"` / `"Dry"` / `"Low flow Clear"` / `"No sample due
   to snakes and over grown grass"`. They are **not legacy spreadsheet-era imports**
   (2023-09-13 … 2025-08-01), and **`quantified = TRUE` would be semantically wrong for at
   least 73 of them** (see §B.5).

4. **Neither population is "legacy" in the sense you meant.** `change_log` is almost empty of
   real history (5,150 rows, all timestamped 2026-07-23) — absence of `change_log` provenance
   is true for 91,642 of the 97,118 `analysis` rows, so it discriminates nothing. Sampling
   dates: A1 runs 2025-05-24 → 2026-03-16, A2 runs 2020-03-12 → **2026-03-24** (four months ago).

---

# TASK A — the 477 rows

## A.0 Classification used

```sql
CASE WHEN quantified IS NULL          THEN 'B_NA'
     WHEN quantified=FALSE AND value < rl_low THEN 'A1'
     WHEN quantified=TRUE  AND value < rl_low THEN 'A2'
     WHEN quantified=FALSE AND value > rl_low THEN 'LEGIT_RAISED'
     WHEN quantified=FALSE AND value = rl_low THEN 'BDL_EQ'
     ELSE 'DET_OK' END
```
MEASURED (`out03.txt` "full class counts"): DET_OK 61,274 · BDL_EQ 34,942 · **A2 355** ·
B_NA 315 · **A1 122** · LEGIT_RAISED 110. Reproduces your counts exactly.

## A.1 The mechanism — MEASURED, then verified against the original lab report

### Measurement 1 — `analysis.rl_low` is exactly 1000× `lab_method.rl_low`

`out03.txt`, "rl_low / lab_method.rl_low ratio, by class":

| class | ratio | n |
|---|---|---|
| A1 | **1000.00** | 102 |
| A2 | **1000.00** | 338 |
| A2 | **100.00** | 4 |
| BDL_EQ | 1.00 | 32,346 |
| DET_OK | 1.00 | 35,008 |
| LEGIT_RAISED | 1.00 | 98 |

Every A1/A2 row that has a `lab_method.rl_low` to compare against is off by exactly 1000
(mg/L ↔ µg/L), or exactly 100 for the four `CFU/mL` rows (CFU/100 mL ↔ CFU/mL). Every
non-suspect class is at ratio 1.00. The remaining 37 A1/A2 rows (20 A1 + 13 A2) have
`lab_method.rl_low IS NULL` (pending-analyte methods, `out03.txt` "rows w/o lm_rl_low"), but
their stored `rl_low` values (1, 2, 20) are the µg/L LORs of the sibling methods.

### Measurement 2 — dividing `rl_low` by 1000 fixes 477/477 with zero exceptions

`out03.txt`, "A1 after /1000" and "A2 after /1000":

| class | rows where `value > rl_low/1000` | rows still `≤` | min multiple | max multiple |
|---|---|---|---|---|
| A1 | **122 / 122** | **0** | 2.4 | 20 |
| A2 | **355 / 355** | **0** | 1.1 | 880 |

Not one row remains anomalous. That is not what a genuine data problem looks like.

### Measurement 3 — the same method carries mg/L `rl_low` on its clean rows

`out03.txt`, "per method: rl_low values seen in analysis":

| method | mg/L `rl_low` (clean) n | µg/L `rl_low` (suspect) n |
|---|---|---|
| EP080: BTEXN | 1e-3 (676), 2e-3 (1747), 5e-3 (123) | 1 (38), 2 (62), 5 (6) |
| EP075(SIM)B: PAH | 5e-4 (672), 1e-3 (3375) | 0.5 (9), 1 (30) |
| EP080/071: TPH | 2e-2 (361), 5e-2 (944), 1e-1 (319) | 20 (61), 50 (38), 100 (16) |
| EP080/071: TRH NEPM | 2e-2 (493), 1e-1 (1397) | 20 (117), 100 (63) |
| EP075(SIM)A: Phenolics | 1e-3 (627), 2e-3 (124) | 1 (23), 2 (6) |
| MW006: Coliforms/E.coli | 1e-2 (100) | 1 (13) |

The suspect values are literally the µg/L numerals of the same LORs.

### Measurement 4 — the source lab file. This is the decisive evidence.

`archive_dir` = `/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets/processed`

**File A** — `c7056fed-997b-44e8-9177-ed40b49b6574/ES2515424_0_XTAB.csv` (work order ES2515424, 24/05/2025):

```
Analyte grouping/Analyte,CAS Number,Unit,Limit of reporting,,
EP080: BTEXN,,,,,
Benzene,71-43-2,µg/L,1,,<20
Toluene,108-88-3,µg/L,2,,<20
EP080/071: Total Petroleum Hydrocarbons,,,,,
C6 - C9 Fraction,,µg/L,20,,<400
```
DB (A1 rows): Benzene `value = 0.02`, `quantified = FALSE`, `rl_low = 1.0`.
→ 20 µg/L = 0.02 mg/L ✓ value converted; LOR 1 µg/L stored raw as `1.0` ✗ not converted.
The lab raised the limit 20× (dilution). `rl_low` should be `0.001`.

**File B** — `9aabe0e2-cbb5-4201-a194-75ed1581d5ca/ES2608464_1_XTAB.csv` (ES2608464, 16/03/2026):

```
EP075(SIM)A: Phenolic Compounds       LOR(µg/L)   B.MW04   B.L01   B.L02
Phenol                                1.0         10.3     14.3    22.9
2-Chlorophenol                        1.0         <1.0     <4.8    <4.8
3- & 4-Methylphenol                   2.0         64.8     454     766
EP075(SIM)B: PAH
Naphthalene                           1.0         <1.0     <4.8    <4.8
Benzo(a)pyrene                        0.5         0.7      <4.8    <4.8
Benzo(a)pyrene TEQ (zero)             0.5         0.7      <2.4    <2.4
EP080: BTEXN
Toluene                               2           <2       63      44
Sum of BTEX                           1           <1       63      44
```

**This kills your anchor example.** The `0.0048 vs rl_low 1` rows are the `<4.8 µg/L` cells at
B.L01/B.L02: ALS ran the leachate samples at a **4.8× raised detection limit**, and the DB
stored `value = 0.0048 mg/L` (correct) against `rl_low = 1` (µg/L, unconverted). The
"208.333× below its own LOR" is precisely `1 / 0.0048` — an arithmetic shadow of the unit
mismatch, nothing more. **These results are 4.8× ABOVE the method LOR, not 208× below it.**

Every other suspect value in this file checks out the same way: Toluene 63 µg/L → `value 0.063`,
`rl_low 2` (A2); Benzo(a)pyrene 0.7 µg/L → `value 0.0007`, `rl_low 0.5` (A2, a genuine
detection at 1.4× LOR); Phenol 4.9 µg/L at B.MW02 → `value 0.0049`, `rl_low 1` (A2).

### Conclusion on the ratios

The "non-decimal ratios (208.333, 50, 100, 250 …)" you observed are **`rl_low/value`, which is
a meaningless quantity** here because the two operands are in different units. The meaningful
quantity is `analysis.rl_low / lab_method.rl_low`, which is **1000 for 440/440 comparable rows
(or 100 for the 4 CFU rows)** — a single, clean, fully explanatory factor.

The physically meaningful derived quantity is the lab's dilution factor
`value / (rl_low/1000)`:

- **A1** (`out07.txt`): 2.4× (n=2), 4.0× (6), **4.8× (52)**, 5.0× (6), 9.6× (2), 10× (24), 20× (30).
  Seven discrete values, all plausible ALS dilution steps, and 4.8/9.6/2.4 are the leachate
  dilution series visible directly in ES2608464.
- **A2**: min 1.1, q25 4.5, median 8, q75 14, max 880 — a normal detection distribution.
  The eight tightest cases (`out07.txt`) sit at 1.1–1.4× LOR, e.g. B(a)P 0.0007 vs 0.0005,
  which the source file confirms as a real `0.7 µg/L` reading.

## A.2 Is A1 the same phenomenon as A2? — YES

Argued from the data:

| | A1 | A2 |
|---|---|---|
| `rl_low/lab_method.rl_low` | 1000 (102/102 comparable) | 1000 (338/342), 100 (4/342) |
| resolves under `/1000` | 122/122 | 355/355 |
| `value_chr` | NULL 122/122 | NULL 355/355 |
| `lab_method.api` | `false` (i.e. no API) 122/122 | `false` 355/355 |
| lab | ALS 122/122 | ALS 355/355 |
| methods | 5 organics suites | the same 5 + `EP080-UT/EP071-SD` + `MW006` |
| site | B (Blaxland) 122 | B 351, L 4 |

They share a single mechanism. The only difference is the source cell: A1 rows come from
`<x` cells (lab-raised limit → `quantified = FALSE`), A2 rows from bare numeric cells
(genuine detection → `quantified = TRUE`). Both were written by the same importer, which
converted `value` and did not convert `rl_low`. **Treating them as two anomaly classes is an
artefact of the diagnostic query, not of the data.**

## A.3 Why the 3,190-row fix missed these — MEASURED

`change_log` (`out04.txt`): `tbl='analysis', action='update', field='rl_low', n=3190`,
`actor='R. Shannon'`, reason as quoted in the headline.

`out07.txt`, "fixed rows: was old_rl == 1000*value exactly?":

| | n |
|---|---|
| fixed rows where `old_rl == 1000 × value` **exactly** | **3190 / 3190** |
| A1 rows where `rl_low == 1000 × value` exactly | **0 / 122** |
| A2 rows where `rl_low == 1000 × value` exactly | **0 / 355** |

INFERENCE (very high confidence): the fix's selection predicate was `rl_low = 1000 * value`
(or equivalently `value = rl_low/1000`). That predicate only matches a below-detection result
reported **at exactly the nominal method LOR**. It structurally cannot match:

- a BDL result at a **raised** limit (`<4.8` when LOR is 1) → **A1, 122 rows**
- a **genuine detection** (`63` when LOR is 2) → **A2, 355 rows**

Post-fix state confirms it: all 3,190 fixed rows now sit at `value == rl_low` (3,178 BDL_EQ,
12 DET_OK), i.e. the predicate was tautologically self-selecting.

The two populations interleave inside the same work orders (`out05.txt`, "fixed rows: work
orders overlap"): ES2608464 has 621 fixed + 115 still-suspect; ES2506846 625 + 19;
ES2516681 48 + 12; ES2439045 240 + 4. Same file, same method, same day.

## A.4 Descriptive answers you asked for

**Analytes** (`out02.txt`) — spread, not concentrated:

- A1: 38 analytes. `Naphthalene` 8, then `Toluene`/`Xylene-total`/`TPH-C6-C9`/`Benzene`/
  `o-Xylene`/`Ethylbenzene`/`TRH-F1`/`BTEX`/`m-+p-Xylene`/`TRH-C6-C10` at 6 each, then 26
  PAH/phenolic analytes at exactly 2 each (the two leachate samples B.L01/B.L02 of ES2608464).
- A2: 24 analytes. `TPH-C6-C9` 55, `TRH-C6-C10` 55, `TRH-F1` 54, `Toluene` 26, `BTEX` 26,
  `TPH-C10-C36` 18, `TRH-F2+F3+F4` 17, `TRH-F3` 17, `TPH-C15-C28` 16, `TPH-C10-C14` 15, …
  tail includes `Escherichia coli` 2, `Faecal Coliforms` 2.

**Methods** — the driver is the *method*, and it is 7 ALS organics/micro suites; each one is a
suite that ALS reports in µg/L while the DB's canonical analyte units are mg/L:

| method | A1 | A2 |
|---|---|---|
| EP080: BTEXN | 48 | 58 |
| EP075(SIM)B: PAH | 36 | 3 |
| EP075(SIM)A: Phenolic Compounds | 20 | 9 |
| EP080/071: TRH – NEPM 2013 Fractions | 12 | 168 |
| EP080/071: Total Petroleum Hydrocarbons | 6 | 109 |
| EP080-UT / EP071-SD: TRH | – | 4 |
| MW006: Faecal Coliforms & E.coli by MF | – | 4 |

No single method dominates; what they have in common is a non-mg/L reporting unit.
`lab_method.api = 'false'` on 477/477.

**Dates** (`out07.txt`) — NOT one era:

- A1: 2025-05-24 → 2026-03-16 (7 work orders, 2 features). 2025-05 (33), 2026-02 (33), 2026-03 (56).
- A2: 2020-03-12 → 2026-03-24 (59 work orders, 10 features). 2020-03 (27), 2020-04 (9),
  2024-11 (4), 2024-12 (7), 2025-03 (19), 2025-05 (28), 2025-06 (12), 2025-09 (7), 2025-12 (7),
  2026-02 (20), 2026-03 (215).

**Sites / features / projects** — heavily concentrated:

- Site: B (Blaxland) 473/477; site L 4.
- Features: `B.L01` 313, `B.MW02` 69, `B.L02` 54, `B.MW04` 17, `B.L03` 7, `B.MW08` 5,
  `B.MW11` 4, `L.L01` 4, `B.MW09` 2, `B.S01` 2. **The two leachate points B.L01/B.L02 account
  for 367/477 (77%)** — expected, because leachate is the matrix that gets diluted and that
  actually contains detectable organics.
- Work orders: 65 distinct; ES2608464 115, ES2506846 19, ES2010160 18, ES2516681 12, then a
  long tail of 5–11.

## A.5 Residual rows the same bug still affects (BEYOND your 477)

`out07.txt`, "all classes, rl ratio >= 50" — **13 more rows** currently classified DET_OK
carry a CFU/100 mL `rl_low` against a CFU/mL `value` (ratio exactly 100):
`Faecal Coliforms` 5, `Escherichia coli` 4, `Coliforms` 4, method `MW006`/`MW007`,
2020-03-12 … 2020-04-23. Together with the 4 CFU rows already inside A2, that is a
**17-row CFU/100 mL population**. They do not trip the `value < rl_low` test only because
the counts happen to exceed 1.

Also visible at ratio ≥ 50 but **NOT** part of this bug (all `BDL_EQ`, i.e. `value == rl_low`,
so both fields agree and they are legitimate raised limits or legacy method changes):
PO4 ×200 (7 rows, 2003), P-total ×500 (7, 2003), Ba/Al ×100 (12, 2003–04), Mn ×50 (2, 2004),
NH3-N ×100 (2, 2017), Cr-6 ×100 (1, 2015). I would leave these alone.

## A.6 Hypotheses and what would kill them

**H-A (accepted, ~certain).** `analysis.rl_low` on all 477 rows (plus the 13 CFU rows) holds
the source file's LOR in its **native reporting unit** (µg/L or CFU/100 mL), unconverted,
while `value` was converted to the analyte's canonical unit. Origin: the pre-package importer
applied the unit conversion to the value column and not to the LOR column.

Supporting: ratio exactly 1000 (or 100) in 440/440 comparable rows; 477/477 resolve; the same
methods carry correctly-converted `rl_low` on 40,000+ other rows; two independent source files
reproduce the numbers cell-for-cell; `change_log` shows the identical defect was already found
and partially fixed with the identical `/1000` remedy.

Would kill it: any A1/A2 row whose source file shows a LOR that is genuinely above the
reported value in the same unit. I looked for one in two files covering 126 of the 477 rows
and found none.

**H-B (rejected).** "`value` is wrong / needs ×1000." Killed by File A: a BDL row cannot have a
reported limit (`<20 µg/L`) *below* its own method LOR (`1 µg/L`); under H-B benzene would be
`<0.02 µg/L`, an impossible 50× *below* the LOR. The source file states 20 µg/L directly.

**H-C (rejected).** "A1 and A2 are two different phenomena." Killed by §A.2: identical unit
ratio, identical resolution rate, identical methods, sites, lab, and `value_chr` profile;
they interleave within single work orders and single files.

**H-D (rejected).** "Both populations are legacy." Killed by sampling dates: A2 extends to
2026-03-24, A1 to 2026-03-16. `change_log` cannot support the claim either way — it holds
5,150 rows all stamped 2026-07-23 and covers only 4,575 of 97,118 `analysis` rows.

**Open question (cannot resolve read-only).** Which importer wrote these, and whether it is
still reachable. The current package converts `rl` correctly — `R/reconcile.R:851-871`
(`.rc_resolve_units_values`) passes `rows$rl` through `unify_value()` alongside `value_num`,
and `R/commit.R:517` writes `clean$rl_converted`. The adapters read the LOR from the file
(`R/adapter-crosstab.R:600` `rl_val`, `R/adapter-esdat.R:240` `as.numeric(df$EQL)`). So the
live pipeline is not the culprit; the rows predate it. To *confirm* that, re-ingest ES2608464
into a scratch copy of the DB and check that `rl_low` lands at 0.001/0.002/0.0005. Do not do
this against the live file.

**Explicitly NOT proposed:** setting `value = rl_low`. That would destroy 477 real reported
limits and 355 real detections. The only defensible remediation is on `rl_low`, and only
after the re-ingest check above.

---

# TASK B — the 315 `quantified = NA` rows

## B.1 Your framing does not survive contact with the data

The data owner's read — "almost certainly `quantified = TRUE`, i.e. real detections, an
artefact of a pre-`WEM.import` spreadsheet era" — is **wrong on the substance and wrong on the
era.** These are not chemical results at all.

MEASURED (`out05.txt`), all 315 rows, no exceptions:

| property | value | n |
|---|---|---|
| `value IS NULL` | TRUE | **315 / 315** |
| `value_chr IS NULL` | FALSE | **315 / 315** |
| `rl_low IS NULL` | TRUE | **315 / 315** |
| `rl_high IS NULL` | TRUE | **315 / 315** |
| `uuid_lab IS NULL` | FALSE | 315 / 315 |

And the converse holds exactly: **`value_chr IS NOT NULL` ⟺ `quantified IS NULL`** across the
whole `analysis` table (`out04.txt`, "value_chr null by class": B_NA is the only class with a
non-NULL `value_chr`, and it has 315/315). This is a perfect 1:1 correlation with **text-valued
results**, not with a date range.

There is no numeric content to be "quantified". `value` is NULL on every row.

## B.2 What they actually are

**Analytes** (`out05.txt`): `Appearance` 295 · `Stage` 20. Both are
`analyte.type = 'qualitative'` (`out07.txt`), `analyte.units IS NULL`.

**Methods**: `field` 311 · `AS3580.10.1` 4. `lab_method.name` = `Comments` /
`Flow observation` / `ANALYSIS OBSERVATIONS`, `organisation = 'ACIRL'`.

**`value_chr` contents** — 77 distinct strings, top of the list:
`Cloudy` 60 · `Clear` 45 · `Dry` 44 · `Low flow Clear` 17 · `Low flow clear` 16 ·
`Pooled Clear` 8 · `Mod level` 8 · `Pooled` 5 · `Low Flow Clear` 5 · `Mod level Clear` 5 ·
`Pooled Cloudy` 4 · `Low flow` 4 · `Non Discharge` 4 · …

These are field-sheet appearance/flow notes typed by samplers.

## B.3 Legacy? — confirmed no `change_log`, but that proves nothing

MEASURED: 0/315 have any `change_log` row (`out02.txt`). But so do 91,642 of 97,118 `analysis`
rows. The `change_log` table contains 5,150 rows, **every one timestamped 2026-07-23** (today),
from the cutover/PLAN-14/PLAN-15 work. **`change_log` cannot date anything that predates
today.** Any conclusion of the form "no change_log ⇒ legacy" is unsupported in this database.

## B.4 Is there a clean date cut-off? — NO, and the boundary is not a date boundary

MEASURED (`out05.txt`, `out07.txt`):

- Range 2023-09-13 → 2025-08-01, over 26 distinct sampling dates and 29 work orders.
- By month: 2023-09 (38), 10 (12), 11 (21), 12 (31), 2024-01 (5), 02 (28), 03 (38), 04 (14),
  05 (29), 06 (39), 07 (13), 08 (25), 09 (18), **2025-03 (2), 2025-08 (2)**.
- Nothing in 2026; nothing before 2023-09-13.
- By year: 2023 → 102, 2024 → 209, 2025 → 4.

The four 2025 stragglers (`out07.txt`) are the `AS3580.10.1` dust-gauge rows at B.D07/B.D08
(`"Clear, organic matter, fine brown dust, coarse black dust."`), 2025-03-01 and 2025-08-01 —
a different programme entirely, which is why they trail the main block.

Crucially, the `field` method itself runs continuously from 2002 to 2026 with 18,300+ rows
(`out07.txt`, "field-method rows outside B_NA over time") and only 2023–2024 produce NA. But
that is **not** an era effect: it is that `Appearance`/`Stage` observations were only ever
recorded as `analysis` rows in that window. **There are zero non-NA `Appearance` or `Stage`
rows anywhere in the table** (`out05.txt`, "same analyte, other rows"). So the population is
defined by *analyte*, not by *date*, and your "sharp boundary ⇒ import era" test does not apply.

## B.5 LOUD WARNING — a blanket `quantified = TRUE` would mislabel at least 73 rows

You asked me to say so loudly if a meaningful share are not really detections. **They are.**

`out07.txt`, text classification of all 315:

| category | n | examples |
|---|---|---|
| OBSERVATION (a real recorded observation) | 242 | `Cloudy`, `Clear`, `Low flow Clear`, `Mod level` |
| **DRY / NO-FLOW** | **50** | `Dry` (44), `Non Discharge` (4), `No flow` (2) |
| **NOT SAMPLED / feature absent** | **23** | `No sample due to snakes and over grown grass` (2), `Could not find due to long grass` (2), `Couldn't be found` (2), `Overgrown coulnt find` (2), `Decomissioned`, `Decomissoned`, `No longer exist`, `No Access`, `No Access snakes`, `Not located`, `Not there`, `No Sample`, `No Location`, `Cant locate`, `Couldnt find`, `Can not locate due to long grass`, `Not running, no sample`, `Samplers could not find site, will be sampled in April`, `Mod flow, Clear. Only field data collected, will be sampled in April` |

**73 of 315 (23%) are records of a non-event** — the point was dry, or the sampler could not
find/reach it, or it has been decommissioned. Marking those `quantified = TRUE` asserts that a
valid observation was quantified when in fact **no sample was taken**. Under the package's own
CONTRACT A4 (`R/values.R`, `skip_reason = "no_sample"`), the literal string `"NS"` is *skipped*
rather than committed; these 23 are the same event expressed in prose and so slipped past.
The 50 `Dry`/`Non Discharge` rows are a genuine and valuable observation of the feature, but
they are an observation *of the feature*, not a measurement *of a sample*.

Note also: the same 315 rows include an anti-pattern in the DB's own terms — a `Dry` reading
sits in `analysis` alongside sibling chemistry rows for the same `uuid_sample`, implying a
sample that both was and was not collected.

## B.6 Sibling control

`out05.txt`, all rows sharing a `uuid_sample` with a B_NA row: `quantified = TRUE` 4,520 ·
`FALSE` 3,333 · `NA` 315. Every non-NA sibling has `value_chr IS NULL` (i.e. numeric).
So within the same sample, the numeric analytes are quantified normally and only the text
analytes are NA. **This is the strongest internal evidence that the NA is driven by the
value being text, not by the sample's vintage.**

For the 73 no-sample/dry rows specifically, the presence of quantified chemistry siblings on
the same `uuid_sample` is itself a data-integrity question worth a separate look — it is
outside this brief and I have not investigated it.

## B.7 Any "<"-stripping, zeros, negatives, sentinels? — NO

MEASURED: `value IS NULL` on 315/315, so there is no numeric field in which a sentinel could
hide. No `value_chr` string begins with `<` or `>` (all 77 distinct strings listed in
`out05.txt` are prose). `rl_low`/`rl_high` are NULL on 315/315. There is no evidence of a
stripped `<` prefix or of a coded non-detect.

## B.8 Hypotheses

**H-1 (rejected): "pre-`WEM.import` spreadsheet era with no notion of quantification."**
Killed by the date range (2023-09 … 2025-08, i.e. inside the ALS work-order era — every one of
the 29 work orders is a real `ESxxxxxxx`), and by the fact that `field`-method rows from 2002
onward *do* carry TRUE/FALSE (18,300+ of them). The NA tracks the analyte, not the era.

**H-2 (accepted): the rows are qualitative text observations, and `quantified` is
undefined for them.** The current package would write `TRUE` here —
`R/values.R:61-62`, `quantified[is_plain_numeric | is_text] <- TRUE`, documented as
"a valid, recorded observation - just not a numeric one" — and `R/commit.R:509`
(`isTRUE(...)`) would then never produce NA, exactly as you observed. So these 315 rows
predate that convention, or were written by a path that bypassed `parse_value()`.

**What follows from H-2 (my recommendation, for the owner to rule on, not for me to apply):**
setting `quantified = TRUE` on all 315 would make the DB self-consistent with `values.R` and
is defensible for the 242 OBSERVATION rows and arguably the 50 DRY rows. It is **not**
defensible for the 23 NOT-SAMPLED rows, which should be reclassified or withdrawn from
`analysis`, not blessed as quantified observations. Doing all 315 in one stroke buys
consistency at the cost of asserting 23 things that are false. If the compliance return ever
counts "quantified observations" per feature per period, those 23 will inflate it.

**Would confirm/kill:** locate the ingest path that wrote them (all 29 work orders have ESdat
or XTAB assets in the archive) and check whether the source field sheet distinguishes a
"not sampled" row from an "observed" row by a column other than the free text. If it does,
the 23 can be separated mechanically rather than by regex.

---

## Things that surprised me / contradict the brief

1. **`rl_low` is not "the method LOR" on these rows and `value > rl_low` is not the only
   legitimate pattern.** The brief's premise — "`rl_low` holds the method LOR, `value` holds
   the result's own reported limit, so `value > rl_low` is legitimate and `value < rl_low` is
   suspect" — is right in intent, but on these 477 rows the two fields are in **different
   units**, so the comparison was never meaningful. The 110 `LEGIT_RAISED` rows are the ones
   where the comparison *is* meaningful (all at unit ratio 1.00).
2. **The 3,190-row fix is not "a different population."** It is the same defect, and the
   `change_log` reason string states the hypothesis I independently re-derived. These 477 are
   the part that fix could not reach.
3. **The 477 are not legacy.** 235 A2 rows and 89 A1 rows carry 2026 sampling dates, the most
   recent 2026-03-24.
4. **The 315 NA rows contain no chemistry.** Any remediation framed as "these are detections"
   would be operating on the wrong mental model.
5. **`change_log` is not a dating instrument in this DB.** All 5,150 rows are stamped
   2026-07-23. It records what *this week's* work did, not the history of the data.
6. **`lab_method.api` is the string `'false'`, not a lab/API name**, on every suspect row —
   worth knowing before writing any query that filters on it.
