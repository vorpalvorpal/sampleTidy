# Parked questions for Robin

Decisions I made autonomously to keep the build moving, where your domain
knowledge could override. None block the MVP; each notes what (if anything)
would change if you decide differently. Raised during Phase 4/5 of the TDD
build; full detail in `PLAN-CHANGE-REQUESTS.md`, decisions recorded in
`CONTRACT.md` A-log.

**Status (2026-07-15): all five resolved.** Robin pointed me at the real
corpus (`…/assets/input`, 261 files) to settle Q1/Q2. Inspecting it settled
those two **and surfaced two real defects** in already-"green" adapters
(plans 04 & 05 pass their synthetic tests but cannot parse the real files).
Those are logged as items 6–7 below and drive PLAN-04/PLAN-05 rework.

## 1. ACIRL/ALS crosstab column layout (R-5.1) — RESOLVED against real corpus
**Answer:** `Analyte grouping/Analyte` is a **single combined column** (col 0)
in **both** XTAB and ENMRG — not two columns. Analyte grouping is expressed as
method-group **rows** (e.g. `EA005P: pH by PC Titrator`), exactly the pattern
the parser's method-group logic already models. → Our synthetic ENMRG
two-column fixture was **wrong**.

Inspecting the real files also revealed the synthetic fixture mis-models the
layout in three further ways (so this is **not** the fixture-only change first
hoped for — see item 7):
- per-sample metadata labels (`Sample Type:`, `ALS Sample Number:`,
  `Sample date:`, `Client sample ID`, `Sample Site:`, `Purchase Order:`) sit at
  **col 3 (XTAB) / col 4 (ENMRG)**, packed **multiple-labels-per-row** (e.g.
  `Matrix:`+`Sample Type:` share row 0; `Workgroup:`+`ALS Sample Number:` share
  row 1), values under the sample columns (col 5+). The parser only inspects
  col 0, so it captures none of this on real files.
- header spellings differ: **XTAB** `Unit` / `Limit of reporting`; **ENMRG**
  `Units` / `LOR`. The parser's `^Unit$` / `^Limit of reporting$` miss ENMRG.
- recent real XTAB/ENMRG files have a **single** `Matrix:` section (multi-section
  is legacy/rare; keep parser support but the fixture needn't lead with it).

## 2. QC sample types LAB_D / MS (R-4.3) — RESOLVED against real corpus
**Answer:** all five QC types appear, abundantly. Real Sample2e `Sample_Type`
counts across the corpus: **LCS 989, LAB_D 989, NCP 936, MB 541, MS 229,
Normal 109** — the exports are QC-dominated, and LAB_D/MS are common (Robin was
right re MS). Adding `LAB_D` + `MS` rows to the Sample2e fixture to prove
verbatim pass-through. (The reconciler still filters everything ≠ `Normal` in
the MVP, so this is pass-through coverage only.)

## 3. Domain-helper connection handling (A16) — RESOLVED: keep the split
**Robin: "Keep the split."** `add_feature()`/`add_analyte()`/`add_project()`/
`correct_value()` self-resolve their connection from `st_config("live_db")`
(human-callable, no `con`); the generic `db_append/update/delete` take an
explicit `con`. **A16 stands unchanged.**

## 4. Assembly→review interface (A22) — RESOLVED: keep inline
**Robin: "Your call."** Keeping inline flags: assembly marks review-worthy rows
on `event$results` (`needs_review`/`review_kind`/`review_payload`); the
reconciler folds them into its single `review` output. **A22 stands unchanged.**

## 5. `Method_Type` (A15) — RESOLVED earlier, re-confirmed against real corpus
Real Chemistry2e header is 18 columns incl. `Method_Type` (verified against a
real file, `…ES2509336_0.Chemistry2e.CSV`). **A15 stands.**

---

## New defects surfaced while validating against the real corpus (2026-07-15)

These are not "parked decisions" — they are real bugs the real files exposed.
No decision needed on *whether* to fix (the MVP must ingest these files); logged
for the record and to drive plan rework.

## 6. ESdat adapter aborts on real Chemistry2e files — encoding (plan 04)
Real Chemistry2e CSVs carry **latin-1 bytes** (e.g. `0xB0` = `°` in
`Electrical Conductivity @ 25°C` — 17 rows in one sampled file). The adapter
reads as UTF-8, so `normalise_lab_text()`'s `gsub()` aborts with "input string
is invalid UTF-8". Reading with a **latin-1 locale** decodes cleanly (verified).
Fix: read ESdat CSVs with a latin-1 locale, as the XTAB dialect already does.
**Also reconciles A27:** a legacy-encoded file is *normal*, not corrupt — the
CORRUPT-fixture abort must key on genuine structural failure (invalid under
latin-1 too, or unreadable), not merely the presence of a non-UTF-8 byte.
→ PLAN-04 updated. Verified against real corpus in the plan-10 gate.

## 7. Crosstab parser cannot parse real ALS files — layout (plan 05)
Consequence of item 1's real-layout findings. The parser (a) inspects only col 0
for per-sample metadata, (b) locates the analyte column via `^Analyte$` (real
header is `Analyte grouping/Analyte`), and (c) hard-codes `Unit`/`Limit of
reporting` spellings. On real files it yields NA analyte names and no captured
sample type/date/feature. Requires a parser + fixture + test rework to the
documented real layout (single analyte column; regex-scan the whole row for
labels; read per-sample values at the sample columns; accept both header
spellings). → PLAN-05 updated. The synthetic fixtures will be regenerated to be
structurally faithful to the real files (still synthetic — A3, no real data
committed).
