# EPA licence 13089 (Katoomba WMF) vs generated monitoring return

**Reporting window:** 2025-05-27 to 2026-05-26 inclusive (Australia/Sydney)
**Licence:** `dev/13089_V5.pdf` — Blue Mountains City Council, Katoomba Waste Management
Facility, 49-89 & 70-78 Woodlands Road. Anniversary date 26-May. Licence Version Date
5 June 2026 (varied by notice POEO-1568, 05-06-2026; previously 1652283, 31-Oct-2025).
**Return under review:** `dev/epa_monitoring_data_K_2025-05-27_to_2026-05-26.xlsx`
(359 data rows, generated 2026-07-23 14:22 by `dev/epa-monitoring-report.R`).
**Database:** `st_config("live_db")`, opened read-only. No writes were made.

The licence **does** cover Katoomba and the comparison is meaningful. Condition **R1.5**
prescribes exactly the eight columns the template carries, so the return is the right
artefact. Note the deadline: `reporting period` + `due date` in the Dictionary =
"not later than 60 days after the end of each reporting period" → **25 July 2026**.

---

## 0. Read this first — three findings that change what the return is

### 0.1 Every EPA Point ID in the return is wrong against licence V5

Licence **P1.1** and **P1.2** name each monitoring point by its map label. The database's
`feature_mask` (variant `EPA`) uses a completely different numbering. They are not
reconcilable by inspection — they are two different schemes over the same 18 locations:

| Location (licence P1.1/P1.2 wording) | Licence V5 point | `feature` | `feature_mask.name` (used in the return) |
|---|---|---|---|
| "Landfill gas monitoring locations conducted in a grid pattern over the landfill footprint" | **1** | K.G01…K.G364 | `2` |
| "Monitoring location labelled 'E01'" | **2** | K.E01 | `1` |
| "Monitoring location labelled 'E02'" | **3** | K.E02 | `14` |
| "'S01A'" | **4** | K.S01A | `3` |
| "'S03'" | **5** | K.S03 | `4` |
| "'S05'" | **6** | K.S05 | `5` |
| "'S06'" | **7** | K.S06 | `13` |
| "'S07'" | **8** | K.S07 | `15` |
| "'S08'" | **9** | K.S08 | `16` |
| "'S09'" | **10** | K.S09 | `17` |
| "'MW01'" | **11** | K.MW01 | `1a` |
| "'MW03'" | **12** | K.MW03 | `3a` |
| "'MW05'" | **13** | K.MW05 | `12` |
| "'MW08'" | **14** | K.MW08 | `6` |
| "'MW10A'" | **15** | K.MW10A | `8` |
| "'MW11B'" | **16** | K.MW11B | `9` |
| "'MW12'" | **17** | K.MW12 | `10` |
| "'L01'" | **18** | K.L01 | `11` |
| *(not a licence point)* | — | K.MW02 | `2a` |
| *(not a licence point)* | — | K.MW04 | `4a` |

Consequences:

* All 359 rows carry the wrong `EPA Point ID`. Most damaging: the return files the
  **landfill-gas methane grid as point "2"**, which in licence V5 is the E01 *discharge to
  waters* point; and it files **E01 water quality as point "1"**, which in V5 is the *air*
  point. An EPA reviewer reading the return literally sees methane discharged to a
  waterway.
* **24 rows are filed under point "4a" (K.MW04)**, which is not an EPA point in licence V5
  at all. R1.5 asks for monitoring "undertaken as a result of a licence condition"; these
  rows have no licence point to belong to.
* Points 13, 17, 18 (MW05, MW12, L01) never appear in the return — see §3.

**This is almost certainly the pre-variation numbering.** The 5 June 2026 variation
(POEO-1568) post-dates the end of the reporting period (26 May 2026), and the `1a/2a/3a/4a`
suffixes in the mask look like an older licence's scheme. **I only have V5, so I cannot
verify that.** Robin needs to decide (or ask the EPA) whether the return for a period that
ended 26 May 2026 should use the numbering in force during the period or the current V5
numbering — and then renumber `feature_mask` accordingly. Either way, `feature_mask`
currently disagrees with the only licence text we hold.

### 0.2 The delivered xlsx is already stale against the live database

Re-running the report's own aggregation against the database as it stands now yields
**376 rows vs the xlsx's 359**. Since the xlsx was written:

* the `Total Suspended Solids` analyte mask was populated → **9 new rows**, previously
  dropped entirely;
* the `Standing water level` mask was corrected from `mg/L` to `m` → **6 new rows**, and
  the report's unit-mismatch guard (assumption J) now catches nothing at all;
* further ALS work orders were committed → counts rose at points `14`, `15`, `17`, `4`,
  `5`, `13` (e.g. mask point `15`/K.S07 Alkalinity 8 → 11).

**The return must be regenerated before submission.** Everything in §4 below assumes a
regeneration.

### 0.3 The methane unit is wrong for this licence

**M2.2, POINT 1:** "Methane | **percent by volume** | Quarterly | Special Method 1".
The mask converts `CH4` from `L/L` to **ppmv** with `conversion_constant = 1e6`, and the
return reports "parts per million by volume". R2.3 and M7.3 both express the action
threshold as "1% methane (v/v)". The return should be in `%v/v` (`conversion_constant =
100`), not ppmv. As filed, a 1% v/v reading appears as 10,000 and the EPA's own limit
comparison will not work.

---

## 1. Status summary

387 (point, pollutant) pairs are required by conditions M2.2/M2.3 for the 12 months.
Status against the **current database** (i.e. what a regenerated return would contain):

| Status | Pairs | |
|---|---:|---|
| Reported, collected count meets the required frequency | **74** | |
| Reported but **short** of the required frequency | **101** | includes point 1 methane — see note |
| **(i)** In the database but excluded by the report's masking | **10** | Chloride ×5, Nickel ×5 |
| **(ii)** Not in the database, but source files exist un-ingested | **0** | nothing found |
| **(iii)** Point not sampled at all in the window | **127** | MW05, MW12, L01, S08 |
| **(iii)** Point sampled, but the determinand was never run | **75** | |
| **Total required** | **387** | |

Against the **delivered xlsx** rather than the current database, category (i) is **23**:
the 10 above plus Total suspended solids ×8 and Standing Water Level ×5, which the xlsx
dropped because the masks were still NULL/wrong when it was generated.

Only **162 of the 387 required pairs** appear in the delivered xlsx, and **197 of its 359
rows are not a licence requirement at all** (metals suites at surface-water points,
TPH/pesticide congeners at K.S09, the whole of "4a"/K.MW04). Reporting extra data is not
itself a breach, but it obscures the return.

### Per licence point

| Lic. point | Location | Required pairs | Complete | Short | (i) masked out | (iii) not run | (iii) point not sampled |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | Gas grid (air) | 1 | 0 | 1 | 0 | 0 | 0 |
| 2 | K.E01 | 5 | 4 | 0 | 0 | 1 (BOD) | 0 |
| 3 | K.E02 | 5 | 4 | 0 | 0 | 1 (BOD) | 0 |
| 4 | K.S01A | 9 | 0 | 7 | 0 | 2 (DO, F.Col) | 0 |
| 5 | K.S03 | 9 | 2 | 5 | 0 | 2 (DO, F.Col) | 0 |
| 6 | K.S05 | 9 | 2 | 5 | 0 | 2 (DO, F.Col) | 0 |
| 7 | K.S06 | 9 | 0 | 6 | 0 | 3 (DO, F.Col, TOC) | 0 |
| 8 | K.S07 | 9 | 6 | 1 | 0 | 2 (DO, F.Col) | 0 |
| 9 | K.S08 | 9 | 0 | 0 | 0 | 0 | **9** |
| 10 | K.S09 | 9 | 6 | 1 | 0 | 2 (DO, F.Col) | 0 |
| 11 | K.MW01 | 39 | 10 | 15 | 2 | 12 | 0 |
| 12 | K.MW03 | 39 | 10 | 15 | 2 | 12 | 0 |
| 13 | K.MW05 | 39 | 0 | 0 | 0 | 0 | **39** |
| 14 | K.MW08 | 39 | 10 | 15 | 2 | 12 | 0 |
| 15 | K.MW10A | 39 | 10 | 15 | 2 | 12 | 0 |
| 16 | K.MW11B | 39 | 10 | 15 | 2 | 12 | 0 |
| 17 | K.MW12 | 39 | 0 | 0 | 0 | 0 | **39** |
| 18 | K.L01 | 40 | 0 | 0 | 0 | 0 | **40** |

---

## 2. A. What the licence requires

All requirements are in **condition M2**, introduced by **M2.1**: *"For each
monitoring/discharge point or utilisation area specified below (by a point number), the
licensee must monitor (by sampling and obtaining results by analysis) the concentration of
each pollutant specified in Column 1. The licensee must use the sampling method, units of
measure, and sample at the frequency, specified opposite in the other columns."*

Frequency wording is quoted verbatim. Implied counts for a 12-month reporting period:
**Quarterly → 4**, **Yearly → 1**.

### M2.2 Air Monitoring Requirements — POINT 1

| Pollutant | UOM | Frequency (verbatim) | Method | Implied n |
|---|---|---|---|---|
| Methane | percent by volume | "Quarterly" | Special Method 1 | 4 |

**M2.4(b):** *"'Special Method 1' means in accordance with Benchmark Technique 17 of the
EPA's 'Environmental Guidelines: Solid Waste Landfills' 2016."*

⚠ **Conditional escalation.** **R2.3:** *"the licensee must notify the EPA within 24 hours
if landfill gas monitoring at Point 1 detects more than 1% methane (v/v), and increase the
frequency of monitoring to daily, until the EPA determines otherwise."* A flat "4" is the
baseline only; if any reading exceeded 1% v/v the required count is higher and cannot be
derived from the licence alone.

⚠ **Aggregation.** Point 1 pools the whole grid (360 features carry the mask, 178 are
active). "Quarterly" plainly means four monitoring *events*; the return's "No. of samples
collected and analysed" counts individual location-samples. Decide which and state it —
178 is not comparable to 4.

### M2.3 — POINT 11,12,13,14,15,16,17 (groundwater MW01, MW03, MW05, MW08, MW10A, MW11B, MW12)

All "Quarterly", "Grab sample", milligrams per litre → **4 each**:
Alkalinity (as calcium carbonate), Calcium, Chloride, Fluoride, Magnesium, Nitrate,
Nitrite, Phosphorus, Sodium, Sulfate.

### M2.3 — POINT 11,12,13,14,15,16,17,18 (groundwater + leachate L01)

All "Yearly", "Grab sample", milligrams per litre → **1 each**:
Aluminium, Arsenic, Barium, Benzene, Cadmium, Chromium (hexavalent), Chromium (total),
Cobalt, Copper, Ethyl benzene, Lead, Manganese, Mercury, Nickel, Organochlorine pesticides,
Organophosphate pesticides, Polycyclic aromatic hydrocarbons, Toluene, Total petroleum
hydrocarbons, Total Phenolics, Xylene, Zinc.

Plus, in the same table but with a different frequency:

| Pollutant | UOM | Frequency | Method | Implied n |
|---|---|---|---|---|
| Standing Water Level | metres | "Quarterly" | In situ | 4 |

### M2.3 — POINT 11,12,13,14,15,16,17,4,5,6,7,8,9,10 (groundwater + all surface water)

| Pollutant | UOM | Frequency | Method | Implied n |
|---|---|---|---|---|
| Conductivity | microsiemens per centimetre | "Quarterly" | Probe | 4 |
| pH | pH | "Quarterly" | Probe | 4 |

And the grab-sample table over the same points, all "Quarterly", mg/L → **4 each**:
Nitrogen (ammonia), Potassium, Total dissolved solids, Total organic carbon.

### M2.3 — POINT 18 (leachate L01)

All "Yearly", "Grab sample" → **1 each**: Alkalinity (as calcium carbonate), BOD, Calcium,
Chloride, Fluoride, Magnesium, Nitrate, Nitrite, Nitrogen (ammonia), Phosphate,
**Phosphorus (total) — "milligrams per gram"**, Potassium, Sodium, Sulfate, Total dissolved
solids, Total organic carbon, Total suspended solids.

⚠ The UOM for Phosphorus (total) at Point 18 is "milligrams per gram" while every other
point uses mg/L. Almost certainly an EPA typo, but the return must state a UOM — flag it
rather than silently filing mg/L.

### M2.3 — POINT 2,3 (discharge to waters E01, E02) — **CONDITIONAL, NOT ANNUAL**

| Pollutant | UOM | Frequency | Method |
|---|---|---|---|
| BOD | milligrams per litre | "Special Frequency 1" | Grab sample |
| Conductivity | microsiemens per centimetre | "Special Frequency 1" | Probe |
| Nitrogen (ammonia) | milligrams per litre | "Special Frequency 1" | Grab sample |
| pH | pH | "Special Frequency 1" | Probe |
| Total suspended solids | milligrams per litre | "Special Frequency 1" | Grab sample |

**M2.4(a):** *"'Special Frequency 1' means within the first 24 hours of discharge."*

⚠ **Do not put a number in "No. of samples required" for points 2 and 3.** The requirement
is one sample set per *discharge event*, not per quarter or per year. The correct entry is
the number of discharge events that occurred in the period — which the database does not
record. Filing "4" or "1" here would be a false statement. Related: **L2.5** permits TSS
exceedance at Points 2 and 3 only where discharge results solely from a >1-in-10-year
24-hour rainfall event, so the rainfall record (M4.1 weather station) is needed to
substantiate any exceedance.

### Not a numbered EPA point (do not put in this return)

**M7.1:** *"Gas accumulation monitoring for methane gas must be undertaken on a quarterly
basis within all buildings and structures located on the premises."* Quarterly, but it has
no EPA point ID, so it belongs in the Statement of Compliance, not the R1.5 data summary.
There is no corresponding feature in the database — worth confirming separately that it is
being done.

---

## 3. B & C. What is in the return, and why the gaps

### 3.1 Category (i) — in the database, excluded by masking. **FIXABLE NOW.**

See §4 for the work list. Ten required pairs, all at points 11, 12, 14, 15, 16
(MW01, MW03, MW08, MW10A, MW11B):

| Licence pollutant | DB analyte | Measured at (window) | Why dropped |
|---|---|---|---|
| Chloride (Quarterly, pts 11-17; Yearly, pt 18) | `Cl` | **15 features**, 2-3 samples each | `analyte_mask.name IS NULL` |
| Nickel (Yearly, pts 11-18) | `Ni` | **12 features**, 1-3 samples each | **no `analyte_mask` row for variant `EPA` at all** |

Chloride is the worse of the two: it is measured at every single Katoomba water feature in
the window and is thrown away everywhere.

Against the **delivered xlsx** (but not against the current DB), add:

| Licence pollutant | DB analyte | Pairs recoverable | Status |
|---|---|---|---|
| Total suspended solids | `TSS` | 8 | mask now populated — **regenerate** |
| Standing Water Level | `Standing water level` | 5 | mask units corrected `mg/L`→`m` — **regenerate** |

### 3.2 Category (ii) — not in the database because it was never ingested

**Count: 0.** I could not attribute a single missing required pair to an un-ingested file.

Evidence. `st_config("input_dir")` holds 296 files (134 tabular) plus 17 in
`batch-2026-07-23`. I scanned every CSV/XLS in `input/`, `input/batch-2026-07-23`,
`input/temp` and `processed/` for Katoomba point codes. The **only** Katoomba codes that
appear anywhere are `E01, E02, S03, S05, S06, S07, S09, S10`. There is **no MW\*, no L01,
no S08 and no gas-grid data in the input directory at all** — ingested or not.

Un-ingested Katoomba work orders in or near the window (`ingest_file.state` is
`quarantined / unclaimed` or absent):

| Work order | Points | Dates | Already in DB? |
|---|---|---|---|
| ES2509335 | E01, E02 | Mar–Apr 2025 | pre-window |
| ES2520710 | E01, E02 | Jul 2025 | yes — E01/E02 2025-07-07 present |
| ES2523866 | E01, E02 | Jul–Aug 2025 | yes — E01/E02 2025-08-04 present |
| ES2601671 | E01, E02 | Dec 2025 – Jan 2026 | yes — E01/E02 2026-01-19 present |

So the backlog is real but it is duplicate coverage of points already reported. Ingesting
it will not close any licence gap. The eight work orders committed post-cutover are
ES2600185, ES2610538, ES2612444, ES2614070, ES2614957, ES2616162, ES2616703, ES2617126.

Caveat worth stating: the pre-2026 groundwater data in the database (MW01/MW03/MW04/MW08/
MW10A/MW11B on 2025-06-12, 2025-09-04, 2025-12-10) did **not** come from this input
directory — it came in with the legacy migration. So "absent from `input_dir`" is not by
itself proof that a groundwater round was never run; it is proof that no *file we hold*
would supply it. The stronger evidence for §3.3 is that the legacy record itself stops.

### 3.3 Category (iii) — genuine compliance gaps

**(a) Four EPA points were not sampled at all in the reporting period — 127 required pairs.**

| Lic. point | Feature | Last sample ever | Required pairs missed |
|---|---|---|---|
| 9 | K.S08 | **2025-03-12** (11 weeks before the window opened) | 9 |
| 13 | K.MW05 | **2024-06-19** (~2 years) | 39 |
| 17 | K.MW12 | **2024-06-19** (~2 years) | 39 |
| 18 | K.L01 | **2025-03-12** | 40 |

K.L01 is the **only** leachate point in the licence, and Point 18 carries a 40-pollutant
annual suite. It has not been sampled since March 2025. Note that K.L04 *was* sampled three
times in the window (2025-06-12, 2025-09-04, 2025-12-10) but has no EPA mask and is not a
licence point — if L04 has in practice replaced L01 as the leachate sampling location, that
is a licence-variation matter, not a data-mapping one, and it must not simply be relabelled.

K.MW05 and K.MW12 both stopped on the same date (2024-06-19) — this looks like two bores
dropped from the program together.

**(b) 75 pairs where the point was sampled but the determinand was never run.**

| Licence pollutant | DB analyte | Missing at | Notes |
|---|---|---|---|
| Dissolved Oxygen (Quarterly, pts 4-10) | `DO` | all 6 sampled surface points | analyte exists in DB, **zero results anywhere**; also has no EPA mask row |
| Faecal Coliforms (Quarterly, pts 4-10) | `Faecal Coliforms` | all 6 sampled surface points | same; **and stored units are `CFU/mL` vs the licence's "colony forming units per 100 millilitres"** |
| Aluminium (Yearly, pts 11-18) | `Al` | all 5 sampled bores | masked correctly, never analysed |
| Chromium (hexavalent) (Yearly) | `Cr-6` | all 5 sampled bores | masked correctly, never analysed |
| Total Phenolics (Yearly) | `Phenols-total` | all 5 sampled bores | masked correctly, never analysed |
| Benzene / Ethyl benzene / Toluene / Xylene (Yearly) | `Benzene`, `Ethylbenzene`, `Toluene`, `Xylene-total` | all 5 sampled bores | **run at K.S09 only** — see below |
| Polycyclic aromatic hydrocarbons (Yearly) | `PAHs-total` | all 5 sampled bores | run at K.S09 only |
| Total petroleum hydrocarbons (Yearly) | `TPH-*` | all 5 sampled bores | run at K.S09 only |
| Organochlorine pesticides (Yearly) | `Organochlorine Pesticides` | all 5 sampled bores | run at K.S09 only, and as congeners not a total |
| Organophosphate pesticides (Yearly) | `Organophosphorous Pesticides` | all 5 sampled bores | as above |
| Phosphorus (Quarterly, pts 11-17) | `P-total` | all 5 sampled bores | run at E01, E02, S05, S06, S07, S09 instead |
| BOD (Special Freq. 1, pts 2 & 3) | `BOD` | K.E01, K.E02 | conditional — see below |
| Total organic carbon (Quarterly, pt 7) | `TOC` | K.S06 | |

⚠ **The annual organics suite went to the wrong location.** BTEX, PAH, TPH and the
pesticide congeners were analysed **only at K.S09** (3 samples). Under licence V5, K.S09 is
point **10**, a *surface water* point where none of that is required. The licence requires
that suite **Yearly at points 11–18** — every groundwater bore and the leachate dam — where
it was not run at all. If the sampling program was written against the old point numbering
(§0.1), this is exactly the kind of error a renumbering would cause, and it is worth
checking whether the field program is targeting locations by number rather than by label.

⚠ **BOD at points 2 and 3 is only conditionally missing.** BOD is required "within the
first 24 hours of discharge". Conductivity, ammonia, pH and TSS were all measured at E01
(4-5 samples) and E02 (5-6 samples) in the window, which implies discharge events occurred
and were sampled — but BOD was not in the suite. If those were discharge-event samples,
this is a real M2.3 breach at both points. If they were routine (non-discharge) samples,
nothing was required at all. The database does not record whether a sample was taken during
discharge; `sample.purpose` is NULL for every Katoomba sample in the window. **Robin needs
to answer this from field records.** It also determines what goes in "No. of samples
required" for points 2 and 3.

### 3.4 The 101 "short" pairs — frequency shortfall

The dominant cause is a **missing fourth quarterly round**. Katoomba's comprehensive rounds
in the window were **2025-06-12, 2025-09-04, 2025-12-10** — three, not four. There is no
March/April 2026 groundwater round in the database or in any file. Consequences:

* every quarterly groundwater determinand at points 11, 14, 15, 16 reads **3 of 4**;
* point 12 (K.MW03) reads **2 of 4** — it was also missed on 2025-12-10;
* point 4 (K.S01A) reads **3 of 4** across the board;
* **Standing Water Level reads 1 of 4** at every sampled bore (required quarterly, in situ)
  — the worst frequency shortfall in the return;
* point 7 (K.S06) reads **1 of 4** for conductivity, potassium and TDS;
* TOC reads **1 of 4** at points 8, 10, 11 and 12.

Points 8 (K.S07) and 10 (K.S09) over-deliver on the monthly parameters (10–12 samples)
because the surface-water program runs monthly, while their quarterly TOC is 1 of 4.

**Point 1 (methane).** The DB holds exactly **one** gas round in the window (2025-09-04,
178 grid locations). The historical cadence — 2024-03-04, 2024-06-19, 2024-09-19,
2024-12-11, 2025-03-12 — is quarterly and stops dead after 2025-09-04. So **1 of 4
quarterly monitoring events**. No gas file exists in the input directory, so I cannot tell
whether the Dec-2025 and Mar-2026 rounds were run and not captured (ii) or not run (iii).
**This is the one gap where the (ii)/(iii) split is genuinely unresolved** — resolve it
from the field-meter records, not from sampleTidy.

---

## 4. FIXABLE NOW — the concrete work list

### 4.1 `analyte_mask` changes (variant `EPA`)

| # | Action | Table row | Field | Value | Effect |
|---|---|---|---|---|---|
| 1 | **UPDATE** | `analyte_mask` where `uuid_analyte = '0e57dd1b-a8cc-401b-a699-683f9a7fd37c'` (`Cl`) and `variant = 'EPA'` | `name` | `Chloride` | +5 required pairs (pts 11,12,14,15,16); also unlocks Cl at 10 non-required features |
| 2 | **INSERT** | `analyte_mask` for `uuid_analyte = '1aad427d-c885-4748-8e7d-ca3dff2b3296'` (`Ni`) | `variant`/`name`/`units`/`conversion_constant` | `EPA` / `Nickel` / `mg/L` / `1` | +5 required pairs (pts 11,12,14,15,16) |
| 3 | **UPDATE** | `analyte_mask` where analyte = `CH4`, `variant = 'EPA'` | `units` | `%v/v` | licence M2.2 UOM is "percent by volume", not ppmv |
| 4 | **UPDATE** | same row | `conversion_constant` | `100` (was `1e6`) | `L/L` → `%v/v`; makes the R2.3 / M7.3 1% v/v threshold readable |

`Cl` and `Ni` already carry `units = 'mg/L'` and `conversion_constant = 1`, matching the
licence's "milligrams per litre", so no unit work is needed for those two.

### 4.2 Already fixed in the DB — just regenerate

| # | Action |
|---|---|
| 5 | `TSS` → `Total Suspended Solids` mask **is now populated**; the xlsx predates it. Regenerating adds 9 rows, 8 of them licence-required. |
| 6 | `Standing water level` mask units **are now `m`**; the report's unit-mismatch guard now excludes nothing. Regenerating adds 6 rows, 5 of them licence-required. |
| 7 | Six work orders committed after the xlsx was written raise counts at mask points `4`, `5`, `13`, `14`, `15`, `17`. |

### 4.3 Mask rows to add for completeness (will not add rows to *this* return — no data)

| # | Analyte | uuid | `name` | `units` | `conversion_constant` |
|---|---|---|---|---|---|
| 8 | `DO` | `b681edf5-f6b5-4214-a3a6-ecc9d7530418` | `Dissolved Oxygen` | `mg/L` | `1` |
| 9 | `Faecal Coliforms` | `279a3d10-489f-4786-b1af-aca55d4e67dc` | `Faecal Coliforms` | `CFU/100mL` | **`100`** (stored `CFU/mL`) |
| 10 | `PO4` | `df2a776f-e0c4-4a1f-b415-f90cfb7d15ec` | `Phosphate` | `mg/L` | `1` |
| 11 | `Organochlorine Pesticides` | — | `Organochlorine pesticides` | `mg/L` | `1` |
| 12 | `Organophosphorous Pesticides` | — | `Organophosphate pesticides` | `mg/L` | `1` |

Item 9's `conversion_constant = 100` matters: the licence UOM is "colony forming units per
100 millilitres" and the database stores `CFU/mL`. Left at 1 the numbers would be 100×
too low.

### 4.4 Not a mask fix — needs a decision

| # | Item | Decision needed |
|---|---|---|
| 13 | **EPA Point ID scheme (§0.1)** | Renumber all 18 `feature_mask` rows to licence V5, or confirm with the EPA that the pre-variation numbering applies to a period ending 26 May 2026. Nothing else in the return is safe until this is settled. |
| 14 | **"4a" / K.MW04, and "2a" / K.MW02** | Not EPA points in V5. Either drop the 24 "4a" rows from the return or establish which licence point (if any) they belong to. |
| 15 | **Points 2 and 3 "No. of samples required"** | Leave blank or enter the number of discharge events. Do not enter 1 or 4. |
| 16 | **Point 1 sample counting** | 178 location-samples in 1 event, against "Quarterly". State whether the count is events or location-samples. |
| 17 | **Point 18 Phosphorus (total) UOM** | Licence says "milligrams per gram"; DB says mg/L. Moot this year (no L01 data) but will bite next year. |
| 18 | **Pollutant name alignment** | The licence names one line item where the DB masks several: "Total petroleum hydrocarbons" → 5 TPH + 7 TRH fraction rows; "Organochlorine pesticides" / "Organophosphate pesticides" → ~20 congener rows. The EPA portal expects the licence's names. Also: licence "Nitrogen (ammonia)" vs mask "Ammonia (as N)"; "Nitrate"/"Nitrite" vs "Nitrate (as N)"/"Nitrite (as N)"; "Phosphorus" vs "Phosphorus (total)"; "Standing Water Level" vs "Standing water level". |
| 19 | **Non-detect handling (script assumption K)** | Still unruled, and ~47% of in-scope results are non-detects. It changes every Lowest/Mean value filed. |

---

## 5. Method notes

* Queried base tables, not `v_measurement_epa` (broken: filters `variant = 'epa'` against
  data stored `'EPA'`, returns 0 rows).
* Join path `sample → feature_alias → feature`; `analysis → lab_method → analyte`.
* `sample.datetime AT TIME ZONE 'UTC' AT TIME ZONE 'Australia/Sydney'` with `icu`
  explicitly `INSTALL`ed and `LOAD`ed; `sample.date` not used.
* "Collected" = `COUNT(DISTINCT sample.uuid)` per (feature, analyte), matching the report's
  column 5 definition.
* Connection opened `read_only = TRUE` throughout. **No writes were made to the database.**
* Mask census: 142 `analyte_mask` rows for variant `EPA`, **68** with a NULL `name`
  (the count was 69 before TSS was fixed).
