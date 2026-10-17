# Operating rules — sampleTidy (LIVE; these govern the system today)

**This is the document in force.** `CONTRACT.md` is the *build* contract: it froze
when the last plan closed on 2026-07-28 and is now history. Everything here was
decided after that, governs the running system, and is what a cold reader needs.

Numbering continues CONTRACT.md's A-log deliberately, so every existing citation
(`A79`, `A82`, commit messages, code comments) still resolves. A-numbers are
unique across both files; there is no A-number in both.

**A-numbers are decisions. They are NOT agent numbers.** Sub-agent working files
are lowercase (`scratchpad/a79_*.R` is *agent* 79, unrelated to *decision* A79).
Never write an agent number as `A<n>`.

## Index

- **A73** — A10 IS REVERSED (user, 2026-08-01): ACIRL dust sheets are parsed, not
- **A74** — WITHDRAWN by A79 on 2026-08-02 — do not implement. The gate was
- **A75** — Field-vs-ALS selection is by value, not position (user, 2026-08-01)
- **A76** — The ACIRL field set is maximal (user, 2026-08-01): Temperature, pH, EC,
- **A77** — Dust exposure dating is cross-checked, never assumed. `Dust Results.Month`
- **A78** — ACIRL point-code spelling variants are MISSPELLINGS, not old names
- **A79** — ACIRL data imports unconditionally; ALS supersedes transcriptions (user,
- **A80** — ACIRL data is filed against the ACIRL REPORT NUMBER; the ALS work order
- **A81** — Feature-alias rulings (user, 2026-08-02). `BORE 11` → `B.MW11`
- **A82** — The read-time preference is a `preference_rank` COLUMN, not a filter
- **A82 (amended)** — A82 AMENDED 2026-08-08 — the two analyte uuids ruling (4) creates are
- **A83** — Every ACIRL transcription label gets its own ACIRL `lab_method`,
- **A83 (amended)** — A83 AMENDED 2026-08-08 — the mapping is now 212 labels, not 208, and
- **A84** — A sample is identified by (feature, datetime), and where two samples
- **A84 (amended)** — A84 AMENDED by A91 (2026-10-17) — an ambiguous sample match is reviewed (`sample_ambiguous`), no longer refused; the data half stands
- **A85** — A bare number in a units column is never a unit — refused as
- **A86** — `SAR` is dimensionless (`units = '1'`), and the `%`-typed Aroclor
- **A88** — Adapters may WITHHOLD rows for review: `needs_review` / `review_kind` / `review_payload` on `results`; identical payloads fold into one item; `release_review()` commits them with the human's dates (design 2026-10-16).
- **A89** — An adapter may declare `zero_is_nondetect`; only then is its bare `0` a non-detect (2026-10-16).
- **A90** — Router verdicts store a registry fingerprint (R-3.8); a stale or NULL one is re-decided automatically (2026-10-17).
- **A91** — A sample is matched within its contractor STREAM (`gas` / `ACIRL` / `ALS` / …, read from the `lab_method`); an ambiguous match is reviewed (`sample_ambiguous`), not refused (Robin, 2026-10-17; amends A84's import half).

## The rules

- **A73** **A10 IS REVERSED (user, 2026-08-01): ACIRL dust sheets are parsed, not
  ignored.** Both `Dust Results` and `Dust Observations`. Dust has no ALS counterpart
  (every `lab_method` ever recorded against `B.D07`/`B.D08` is ACIRL, method
  AS3580.10.1), so dust was **exempt from the ALS-linkage gate (A74)** — which A79
  has since withdrawn entirely, making the exemption moot — 6 workbooks
  are dust-only and have no water sheet at all. Analytes already exist:
  `dust-total` ← `INSOLUBLE SOLID`, `dust-combustible` ← `*COMBUSTIBLE MATTER`,
  `dust-incombustible` ← `INCOMBUSTIBLE MATTER`, and `Appearance` ←
  `ANALYSIS OBSERVATIONS` for the observation text.
- **A74** ⚠️ **WITHDRAWN by A79 on 2026-08-02 — do not implement.** The gate was
  built (PLAN-09 R-9.13), measured, and then removed: `.ig_als_gate()`,
  `report$als_gated`, the `als_source_missing` retry path and the
  `parsed -> quarantined` transition are all gone. The distrust it encoded is real
  but now acts one stage later and one row at a time — an ACIRL *transcription* is
  superseded at reconcile when the ALS row arrives. The citation it introduced
  (`report$als_work_orders`, `report$n_water_sheets`) is KEPT and is now A80's
  filing input. The original ruling and its measurements follow, because they are
  why A79 went the way it did.

  **ACIRL water sheets require their ALS source (user, 2026-08-01).** Most of
  an ACIRL water sheet is ALS lab data copied by hand; we do not trust the transcription,
  and it drops reporting limits. Every water sheet declares an `ALS Sydney Report No.`
  (present in 640/640 real sheets). **If any cited `ES#######` work order is not held,
  the file is quarantined with reason `als_source_missing`, per file — not a run-level
  abort**, so the rest of the batch proceeds and the file re-processes naturally when the
  ALS report arrives (ACIRL routinely arrives first). A sheet may cite **two** work
  orders; **all** must be held. Measured cost: 74 of 640 sheets, 19 of 147 workbooks.
  **Enforced in `ingest_dir()` (PLAN-09), not in the adapter** — `parse()` sees one
  file and no database. The adapter only exposes `report$als_work_orders`.
  **Implementation notes added 2026-08-01** (PLAN-09 R-9.13, PLAN-06 R-6.5b), all
  measured rather than assumed:
  (a) the gate runs as its own pass **between parse and assemble** — after, because
  "held" includes an ALS sibling arriving in the same batch and parse order within a
  batch is arbitrary; before, because a gated file must contribute no rows, no events
  and no review items.
  (b) **"held" = a `project` row for the `ES#######`, OR that work order arriving in
  this same batch.** ACIRL and ALS routinely land in one PowerAutomate folder; without
  the same-batch arm the ordinary case would need two runs.
  (c) **Citing nothing is a gate failure, not an exemption.** The A73 dust exemption is
  keyed on `report$n_water_sheets == 0`, NOT on an empty citation. Measured: of the 8
  claimed workbooks citing nothing, 7 are dust-only but 1 (`2400-7483-01 May 2025
  Lawson Landfill.xls`, 30 rows) has eight water sheets whose ALS cell reads a bare
  `ES`. Reading "cites nothing" as "must be dust" would have imported it with no
  traceable source.
  (d) `als_source_missing` is **re-decided on every ordinary run**, with no
  `reconsider` flag — it is a fact about the world, not about the file or the adapter
  registry, and A74's "re-processes naturally when the ALS report arrives" is otherwise
  unreachable. Safe (a gated file committed nothing) and self-limiting.
  (e) Measured cost against the live DB's 423 held work orders: **17 of 154 workbooks,
  644 rows** — 16 citing an unheld order, 1 citing nothing. 13 distinct work orders
  missing, of which 11 are pre-2025 and out of scope, leaving `ES2503724` and
  `ES2522505`. This **supersedes the "19 of 147 workbooks" above**, which predates
  both the A76 allowlist widening (which changed which workbooks yield rows) and the
  R-6.5b extractor fix (which moved `2400-7223-12-01`, 57 rows, out of the gated set
  by finding the citation it had been shadowing).
- **A75** **Field-vs-ALS selection is by value, not position (user, 2026-08-01).**
  Position is unsafe — 74 of 190 real sheets interleave ALS-copied rows among the field
  rows. Per label row: (i) no value in any sample column → heading, drop silently;
  (ii) values equal the ALS values for the same feature+analyte → ALS copy, drop
  (`lab_data_dropped`); (iii) on the field allowlist and not matching ALS → import as a
  field reading; (iv) has values but neither allowlisted nor ALS-matched → **review
  queue**, never a silent import or a silent drop; (v) `----` means "not analysed".
  Rule (ii) **must exclude** ALS rows whose method is `EN67 - Client Supplied Data` (or
  any `field`-flagged method): there ALS is carrying the field reading itself, and
  treating it as a copy would discard genuine field data. Where both sides hold the same
  field reading, **exactly one row is written** — dedupe on
  feature + datetime + analyte + `method = 'field'`.
  **Enforced where the ALS data is visible — `assemble_events()` for same-batch
  siblings, `reconcile(con)` for already-committed ALS — not in the adapter.** The
  adapter must therefore *keep* ALS-looking rows, tagged `als_candidate`, rather
  than dropping them at parse: the old drop-at-adapter behaviour destroyed the very
  values this test needs to compare. Steps (i) heading-drop and (v) `----` are
  decidable per-file and stay in the adapter.
  **Implementation notes added 2026-08-02 (Robin's question: use the
  `lab_method -> analyte` map), all measured over 38,450 real candidate rows**
  (that row count DOUBLE COUNTS — 10 workbooks sit in both `unprocessed/` and
  `processed/`, so only 34,024 (file, source_ref) pairs are distinct, and 34,137
  is the `unprocessed/` figure a 6c ingest would see. Noted and RE-DERIVED
  2026-08-03, `scratchpad/m6a_a79_basis.R`: every figure below reproduces
  exactly on the 38,450 basis as quoted, and shifts only slightly on the
  deduplicated one — twins by analyte **76.1% → 75.1%**, and the
  `Total Suspended Solids` case **605 rows / 468 twins → 545 / 413**. The
  conclusions are unaffected; only the row counts are inflated):
  (a) **The comparison keys on the RESOLVED ANALYTE, not the label.** ACIRL and ALS
  name the same analyte differently — ACIRL writes `Total Suspended Solids`, ALS's
  method is `Suspended Solids (SS)`, canonical `TSS`. Resolving both sides through
  `lab_method.uuid_analyte` fixes it: those 605 rows go from **0 twins by label to
  468 by analyte**. Keyed on the label, all 605 would have read as "no ALS twin ->
  field estimate -> import", i.e. importing transcribed ALS values as field
  readings — exactly what A75 exists to prevent.
  (b) **The map is safe as a key.** Of 271 folded `lab_method` names, exactly **one**
  is ambiguous: `>C10 - C16 Fraction` -> `TRH-C11-C16` or `TRH-F2`, two ALS rows
  differing only by `method` (`EP080/071:` vs `EP071:`), which an ACIRL sheet cannot
  supply. Ambiguous keys must route to review, never guess — note the label key
  "found" those 123 twins only by coin-flipping between the two analytes.
  (c) Coverage: **97.0%** of candidate labels resolve; **76.1%** have an ALS twin.
  (d) **Both A75 arms need the database, so both belong in `reconcile(con)`.**
  `assemble_events()` has no connection and so cannot resolve an analyte at all. The
  same-batch case then needs no separate mechanism — it only needs the ALS event to
  reconcile *before* the ACIRL event, which is an event-ORDERING guarantee (ACIRL
  events are orphans, home work order `NA`, so ordering is not currently guaranteed).
  This supersedes A75's "assemble for same-batch siblings" split: not because the
  split is wrong, but because ordering makes one mechanism serve both.
  (e) **The residual review load is a FEATURE problem, not an analyte one.** Of the
  9,205 no-twin rows, **5,018 fail on the feature**: 36 of 104 ACIRL point codes match
  neither a `feature` nor a `feature_alias`. They fall in two groups — human names
  the R-6.7 alias mapping already recovers (`EFFLUENT`, `BORE 2`,
  `CRIPPLE CREEK INLET`), and letter-**O**-for-**zero** codes (`B.EO1`, `B.SO1`,
  `B.SO5`, `B.LO1`, `K.SO6`, plus unpadded `B.MW2`). **Not auto-mapped** — the alias
  domain rule is old != misspelling, no fuzzy — so these need Robin's ruling.
  Only **3,016** rows are genuinely "ALS did not measure that analyte at that point",
  plus **1,171** analyte registry gaps (`Total Hardness` 438, `Nitrite` 260, the
  EC-@-25 mojibake 150, `Nitrite + Nitrate` 60, ...).

  **Risks of the reconcile-only design, measured 2026-08-02 before building.** The
  design is sound but has two failure modes that must be built out from the start, not
  patched later:
  (i) **The twin test is an ABSENCE test, and absence is not evidence when the data may
  be incomplete.** 5,094 of the 9,205 no-twin rows sit on a feature that does not
  resolve — no twin could have been found there whatever the truth. Most go safely to
  review under rule (iv), but rule (iii) rows *import* on absence: **70 diff-required
  TSS rows would silently import an ALS copy as a field reading**, which is precisely
  the failure A75 exists to prevent, delivered by A75 itself. **Mitigation: a row may
  never take the absence branch unless its feature resolved. Unresolved feature →
  review, always.**
  (ii) **Order-dependence is a silent-corruption coupling.** Making correctness depend
  on ALS events reconciling before ACIRL ones is a hidden temporal dependency: a later
  reorder (parallelism, performance, refactor) flips verdicts silently and no test
  notices unless written for it. **Mitigation: do not rely on ordering — CHECK it.**
  The ACIRL branch asserts the cited work order has *visible analyses*, not merely a
  `project` row; project-but-no-analyses (the same-batch, not-yet-committed case) →
  review. Ordering then becomes an optimisation, not a correctness requirement.
  (iii) **`als_candidates` does not currently reach reconcile.** `.st_build_event()`
  builds a fresh `report` with five fields; `als_candidates`, `als_work_orders`,
  `feature_aliases` and `n_water_sheets` are all dropped at assemble. So the unit is
  *not* reconcile-local — assemble must be changed to carry them onto the event.
  (iv) The verdict becomes a function of **(file, database state)**, not of the file
  alone: the same workbook re-processed later can decide differently. Inherent to A75,
  but it means provenance must record *why* each row was dropped or imported, or the
  decision is unauditable afterwards.
  (v) **Sequencing.** Feature aliasing is now load-bearing for A75's correctness, so
  the alias work (A78 + the 9 descriptive codes) should land first — or (i) must gate
  it. A third outcome, *undecidable*, is also needed for the one ambiguous analyte
  (`>C10 - C16 Fraction`, 148 rows); rules (i)–(v) do not name it.
- **A76** **The ACIRL field set is maximal (user, 2026-08-01):** Temperature, pH, EC,
  Standing water level, DO, ORP, turbidity, flow, and **TSS** — TSS being a *field
  estimate* whenever it is not on the ALS results, and the one field analyte with a real
  ALS twin, so it separates on A75's value test rather than on name. Writes go to the
  existing `lab_method` convention `method = 'field'`, `organisation = 'ACIRL'` (already
  populated: pH 1026 rows, Temperature 965, EC 856, Standing water level 260; TSS/DO/ORP
  have the `lab_method` row but zero analyses). **`Turbidity` does not exist and is to be
  created** (NTU, type `quality`) with its ACIRL `field` lab_method. Observation labels
  are qualitative (`value_chr`): `General Comments/ Observations` and
  `Observations / Comments` → `Appearance` via lab_method `Comments`;
  `Flow Observation / Appearance` is **split** into `Stage` (flow) + `Appearance`
  (clarity). Historical rows that conflate the two are **left alone**. The 6
  `Standing water level` lab_method name variants (`Water Height`, `Water Depth`,
  `Standing Water Height`, …) are **preserved as received**, not consolidated.

  *Implementation notes added 2026-08-01 after measuring the corpus (see PLAN-06
  R-6.6); none of these change the ruling, they record what honouring it meant:*

  - The allowlist is built from **measured labels**, not from the analyte names
    above. `st_config("field_analytes")` matches a label exactly (squished,
    upper-cased); the sheets say `Electrical Conductivity`, never `EC`.
  - **TSS is not on the allowlist and must not be.** Its ACIRL label *is* the ALS
    analyte's name, so the name cannot separate them. It has its own key,
    `field_analytes_diff_required`; the adapter routes those rows to
    `report$als_candidates` with `diff_required = TRUE` and skip reason
    `diff_required`, and **only A75's value comparison may promote one to a field
    result**. This makes the A75-before-import ordering structural rather than a
    promise: 678 real rows currently sit behind it.
  - **turbidity, DO, ORP and flow occur zero times** in the 213-workbook corpus —
    DO/ORP are allowlisted anyway (they are registered ACIRL `field` methods), and
    `Turbidity` still needs creating, but neither will import anything today.
  - `Electrical Conductivity @ 25°C` is the ALS value transcribed into the
    sheet, never a field reading, and is deliberately excluded from the
    allowlist. ACIRL owned a `field` lab_method under the **mojibake** spelling
    of that label carrying **zero analyses**; it was **deleted from the live
    database on 2026-08-01** (`db_delete()`, `change_log` uuid_row `9f59b10a`,
    backup `monitoring_pre-ec25-fix_20260801T213736.duckdb`). The clean-named
    row is correct and untouched — org ALS, `EA010P: Conductivity by PC
    Titrator`, 1272 analyses. With the mojibake row gone, an ACIRL sheet
    carrying that label resolves to nothing under org ACIRL and lands in
    review, which is the correct loud failure mode.
  - The **`Flow Observation / Appearance` split applies to all three observation
    labels**, not just that one — the value text, not the label, carries the
    stage/appearance distinction. A third class ("could not locate", "no access",
    "decommissioned") describes no water at all and correctly yields neither
    analyte; its raw text is preserved on `sample.comments`, as is every
    observation's, split or not.
  - The three observation labels **never co-occur on a real sheet** (0 of 578
    measured), so the "one Stage + one Appearance per sample column" dedupe is
    defensive only.
- **A77** **Dust exposure dating is cross-checked, never assumed.** `Dust Results.Month`
  and `Dust Observations.EXPOSURE DATE` disagree in 8 of 64 real gauge-blocks; in 6 of
  those `Month` holds the *collection* date instead, but in `2400-7538-02` the
  Observations sheet is stale by two years while `Month` is right. **Neither sheet is
  authoritative** — parse both, and route every disagreement to review rather than
  auto-preferring one. (This is what turned an apparent 2025-06 duplicate plus an
  apparent 2025-05 gap into a single data-entry error.)

- **A78** **ACIRL point-code spelling variants are MISSPELLINGS, not old names
  (user, 2026-08-02).** The letter-O-for-zero codes and the padding/dot drift on ACIRL
  water sheets (`B.EO1`, `K.SO6`, `KS07`, `B.MW2`, …) are transcription errors, so they
  take `feature_alias.kind = 'transcription_error'` — **not** `historical_code`, which
  is reserved for a genuinely different former identifier. This resolves 1,375 of the
  5,018 rows that were failing the A75 twin test on the feature rather than the analyte.

  **No hand-written alias rows.** The existing machinery already covers this end to
  end: an unresolved `feature_raw` mints a `feature_alias` row with `kind = 'pending'`
  at commit (`.ct_materialise_feature_aliases()`), it surfaces as an `unknown_feature`
  review item, and an operator attaches it with
  `confirm_feature_aliases(..., kind = "transcription_error")`. Pre-creating the rows
  by hand would bypass that flow and skip the `date_start` bookkeeping the commit path
  does. This ruling is therefore the **answer sheet** for the confirmation step, not a
  migration.

  Verified determinate (each correction lands on exactly ONE feature *uuid* — several
  candidate spellings are already registered `historical_code` aliases of the same
  point, so name-uniqueness is the wrong test):

  | ACIRL code | → feature | rule | rows |
  |---|---|---|---|
  | `B.EO1` | `B.E01` | O→0 | 290 |
  | `KS07` | `K.S07` | insert dot | 309 |
  | `K.SO9` | `K.S09` | O→0 | 285 |
  | `K.SO6` | `K.S06` | O→0 | 188 |
  | `B.LO1` | `B.L01` | O→0 | 132 |
  | `B.SO5` | `B.S05` | O→0 | 76 |
  | `KS05` | `K.S05` | insert dot | 41 |
  | `K.SO7` | `K.S07` | O→0 | 28 |
  | `B.MW2` | `B.MW02` | zero-pad | 14 |
  | `KE01` | `K.E01` | insert dot | 12 |

  **`B.LO2` → `B.L02`; the registry was wrong (ruled 2026-08-02, then verified).**
  `B.LO02` had been registered as a `historical_code` alias of **`B.E01`**. That was a
  registry defect, not a historical fact, and three independent checks agree:
  * **matrix** — `B.E01` is *stormwater*; `B.L01`/`B.L02` are *leachate*. An `L` code
    cannot sensibly be a former name for a stormwater point, and the sibling
    `B.LO01` correctly points at `B.L01`.
  * **chemistry, decisive** — ACIRL writes `B.LO2` on two 2024 Blaxland quarterlies
    citing `ES2419948`/`ES2429912`. The ALS data for `B.L02` under those exact work
    orders matches the sheet **value for value** on three analytes: Ammonia 96.9/77.4,
    Alkalinity 454, TOC 40/139. `B.E01` has **eight** analyses across both work orders
    (Appearance, Temperature, pH) and was recorded `Dry` — no ammonia, alkalinity or
    TOC at all, so the block cannot be its data.
  * **volume** — the ACIRL `B.LO2` block is 66 rows per file, matching `B.L02`'s 41–44
    analyses per work order, not `B.E01`'s 4.

  Repointed via `confirm_feature_aliases()` to `B.L02` with
  `kind = 'transcription_error'`, `confirmed_by = 'R. Shannon'`. No `sample` rows were
  attached to that alias, so no committed data moved: `sample` 15149, `analysis` 97118
  and `feature_alias` 1994 all unchanged, three `change_log` update rows.
  Backup `monitoring_pre-blo02_20260802T073257.duckdb`.

  **Applied to the whole O-form family (2026-08-02).** `B.EO01` and `B.LO01` were
  re-kinded from `historical_code` to `transcription_error` (targets already correct
  and passed back unchanged, so `kind` was the only field to move). All three now read
  `B.EO01 → B.E01`, `B.LO01 → B.L01`, `B.LO02 → B.L02`, all `transcription_error`,
  `confirmed_by = 'R. Shannon'`; `sample` 15149, `analysis` 97118 and `feature_alias`
  1994 unchanged. Backup `monitoring_pre-okind_20260802T074215.duckdb`.

  **Not covered by this ruling:** the 25 remaining unmatched codes (3,587 rows) are not
  spelling variants at all — they are descriptive human names (`EFFLUENT`, `BORE 2`,
  `CRIPPLE CREEK INLET`, `LEACHATE DAM 1`, `MP # 1`…) plus a few odd forms
  (`B.SO1 S1`, `S1`, `S22`, `E1`, `BORE10A`, `BORE12`). Those take
  `kind = 'descriptive'`, and R-6.7's `report$feature_aliases` mapping (91 point→name
  pairs recovered from the sheets themselves) is the evidence for them.

  Measurement: `scratchpad/feature_misspell3.R` → `feature_misspell.rds`.

- **A79** **ACIRL data imports unconditionally; ALS supersedes transcriptions (user,
  2026-08-02).** Supersedes A75's drop/review scheme and **relaxes A74**.
  * **A74's whole-file quarantine is withdrawn.** A missing ALS source no longer holds
    back a workbook (17 files / 644 rows). ACIRL data is NATA-certified and is imported
    on its own; the ALS citation is still recorded, it just no longer gates.
  * **Two categories, already encoded in the data — no new column, no migration:**
    an ACIRL row on a `method = 'field'` lab_method is a **field measurement** (kept
    permanently, ranked ABOVE lab — the sample degasses before the lab sees it); every
    other ACIRL row is a **transcription** of an ALS-reported value (one measurement,
    two records) and is **provisional — deleted when the ALS equivalent commits**.
    `db_delete()` writes the old row to `change_log`, so a transcription discrepancy
    stays auditable without duplicate rows in `analysis`.
  * "Calculated" values are NOT a third category (user): SAR, Ionic Balance, the
    alkalinity speciation trio and calculated TDS are all reported BY ALS under ALS
    method codes (`EA006`, `EN055`, `ED037P`, `EA016`), so ACIRL copying them is an
    ordinary transcription.
  * **Matching keys on feature + datetime + resolved ANALYTE UUID, never the raw
    label** (ACIRL writes `Total Suspended Solids`, ALS `Suspended Solids (SS)`, both
    → `TSS`). Exactly one folded `lab_method` name is ambiguous
    (`>C10 - C16 Fraction` → `TRH-C11-C16` / `TRH-F2`); ambiguous keys go to review.
  * **Read-time ranking**, one ordering for both levels:
    `ORDER BY (lm.method = 'field') DESC, (lm.organisation = 'ALS') DESC`.
    `EN67 - Client Supplied Data` ranks as field. Only six analytes have both a field
    and a lab method — pH, EC, DO, TDS, TSS, Appearance — so it is a no-op elsewhere.
  * Note the **legacy system already implemented A75's policy**: zero existing
    (feature, date, analyte) triples carry both an ALS row and a non-field ACIRL row.
    So this is a deliberate change of policy, starting from a base with no duplicates.
  **Two corrections and one open question, from implementing R-8.9 (Claude,
  2026-08-02, all measured — flagged here for Robin).**

  1. **"Every other ACIRL row is a transcription" is wrong as written.** All
     four of ACIRL's non-field `lab_method` rows in the live registry are
     **dust** (`AS3580.10.1-2003` — 310 analyses). ALS does not run deposition
     gauges, so ACIRL dust is ACIRL's OWN lab measurement: a third category,
     never superseded. The discriminator used is the method code, and it is
     measured rather than invented — **zero** ACIRL lab_methods have a NULL
     `method` today and ACIRL water sheets carry no method codes at all, so the
     rule is a provable no-op on every row now in the database.
  2. **`EN67 - Client Supplied Data` must rank as field on BOTH sides.** A75
     already said it ranks as field for the read-time preference; it matters
     here too. EN67 is an *ALS* method (`pH`, one row) meaning the client
     supplied the number and ALS reported it back — our own field reading
     round-tripped. Treated as an ordinary ALS lab row it would delete a
     committed ACIRL pH transcription: a field reading superseding a field
     reading.
  3. **The TSS pair — MEASURED AND SETTLED as transcription; the remaining
     question is only what to do about the registry.** `Total Suspended Solids`
     is both the ACIRL sheet label and the ALS analyte name, so no name test
     separates a field estimate from a transcription. A75's value comparison
     was the mechanism and A79 removed it as a *runtime* rule — but nothing
     stopped running it **once**, off the saved corpus measurement, to settle
     the classification. Two independent lines of evidence, and they agree
     (`scratchpad/a79_tss_verdict2.R`):

     * **These values carry ALS's own reporting limit.** 284 of the 678 rows
       (41.9%) are written `<5`, and `<5` is the *only* `<` value that appears.
       ALS's TSS method (`EA025: Total Suspended Solids dried at 104 ± 2°C`)
       has `rl_low = 5`, and 345 of its recorded non-detects sit at exactly
       that limit. A field estimate cannot produce "<5 mg/L" — that is a
       laboratory reporting limit, and it is *ALS's*.
     * **Where the values can be compared they are identical.** 362 of the 678
       have an ALS TSS row at the same cited work order and feature;
       **355 (98.1%) match exactly**. And the 7 that do not are not
       independent measurements — they are *permutations of the ALS numbers*:
       `B.S01`/`B.S03` carry each other's values (`<5`/`68` against ALS's
       `68`/`5`), as do `B.MW08`/`B.MW11` (`30`/`118` against `118`/`30`), plus
       one single-digit misread (`6` for `8`). Even the mismatches prove
       copying.

     TSS is gravimetric — filter a known volume, dry at 104°C, weigh — so this
     is also what the method implies. And the registry already agrees: ACIRL's
     `Total Suspended Solids` and `Suspended Solids (SS)` **`field`** methods
     both carry **zero analyses**, so the legacy import never treated an ACIRL
     TSS row as a field measurement either.

     **Incidental, and worth keeping: this is the first measurement of ACIRL's
     transcription error rate — 7 of 362, ~1.9%** — and every one of them is
     the kind of error (a column offset) that a per-value audit trail catches
     and a whole-file gate never would.

     **RULED (Robin, 2026-08-02): option (a) — DONE.** The two unused ACIRL
     `field` TSS `lab_method` rows were deleted from the live database
     (`29cfea72…`, `c8b85ce2…`; `lab_method` 361 → 359, every other table
     unchanged, 0 orphans, backup
     `monitoring_pre-tss-field-methods_20260802T073901.duckdb`, verified by md5
     *and* row counts). Both carried **zero** analyses and were referenced by
     nothing. `Total Suspended Solids` can no longer resolve to a field method
     at all, so an incoming row mints a NULL-method dangling method and R-8.9
     supersedes it like any other transcription.

     The config key `field_analytes_diff_required` is renamed
     **`acirl_transcription_labels`** — its old name encoded A75's value
     comparison, which no longer exists and whose question is now answered.
     Behaviour is unchanged (the labels still take the ALS-candidate path); the
     name and the skip reason (`transcription_label`) now say why.

     This does foreclose A76's "field-estimated TSS" should ACIRL ever start
     doing it. That is deliberate and cheap to reverse: re-registering an ACIRL
     `field` TSS method restores the old behaviour, and the evidence would be a
     TSS value that is *not* `<5` and *not* equal to ALS's.

  **"Repair the database where ACIRL disagrees with ALS" — MEASURED, and there
  is nothing to repair (Claude, 2026-08-02, `scratchpad/repair00_measure.R`,
  `repair01_identical.R`).** Robin asked for this on the premise that ALS is
  right and ACIRL is wrong. The premise is correct *for transcriptions* — and
  the database contains none:

  * **Zero** ACIRL analyses sit on a NULL-method (transcription) `lab_method`.
    Every one of the 16,420 ACIRL analyses is either a `field` reading (16,110)
    or ACIRL's own dust lab work (310, `AS3580.10.1*`). Cross-checked two ways:
    by the triple-collision query (0 pairs) and by enumerating every ACIRL
    method that carries analyses at all.
  * The **898** (feature, date, analyte) triples carrying both an ACIRL row and
    an ALS lab row are all `field`-vs-lab — pH 517, EC 381 — and they are
    **genuinely different measurements**, exactly as A79 says: median absolute
    difference **0.52 pH units (7.8% relative)** and **22 µS/cm (8.1%)**.
    Overwriting them with the lab number would destroy 898 real field readings
    and do precisely what A79 exists to prevent.
  * Only **9** of the 898 have identical values (7 EC, 2 pH). They are
    coincidences, not copies: **every one matches on a single analyte of the
    two measured on that visit** — not one visit matches on both pH and EC,
    which is what a copy would look like. The matching EC values are whole
    numbers (775, 96, 230, 225, 82, 29, 212) and 984 of 1,026 ACIRL pH readings
    carry one decimal place, so chance agreement across 898 pairs is expected.

  So the repair was not made, because making one would have been the damage.
  The transcription errors that *do* exist (the TSS transpositions, ~1.9%) are
  in the ACIRL **workbooks**, which have never been ingested — no ACIRL file has
  ever reached this database. They will be caught at import by R-8.9, one value
  at a time, with the discrepancy preserved in `change_log`.

  **SEQUENCING, measured and load-bearing: the dangling-method confirmation
  pass must precede the transcription import, not follow it.** 215 of the 218
  transcription labels have no ACIRL `lab_method` at all today. Importing them
  first mints dangling methods, and a dangling method has no `uuid_analyte`, so
  R-8.9's twin test cannot fire for any of them — leaving ~38,000 provisional
  rows nothing can ever supersede. That is the silent-duplicate failure mode
  A79 inverts. This reorders steps 4 and 6 of the ACIRL plan.

- **A80** **ACIRL data is filed against the ACIRL REPORT NUMBER; the ALS work order
  becomes a CHILD project of it (user, 2026-08-02).** The ACIRL report is the parent
  engagement; the ALS job is the lab work within it. `project` already supports this
  via `uuid_parent`/`uuid_root`.
  **The report number is not unique, and the hierarchy is what makes that safe.**
  Measured over 154 workbooks: 132 distinct `REPORT NO:` values, none missing. Of the
  16 numbers appearing on more than one file, **13 are one report re-saved or revised**
  (same sample date and same cited ALS work order — byte-difference alone is NOT a
  discriminator) and **3 are TRUE collisions** — different sampling events sharing a
  number. The clearest is `2400-7430-01`: May 2024 (`ES2417748`) and a year later
  (`ES2515829`).
  So samples must attach to the **child** (the ALS work order) wherever one is cited,
  and to the parent only when none is — a reused ACIRL number then yields one parent
  with two children and the events stay separate, instead of silently merging.
  Dust-only workbooks cite no ALS order and attach to the parent directly.
  The report number is read from the front-page `REPORT NO:` cell, **never from the
  filename** — the ACIRL filename trap is untouched.

  **A repeated report number is an ACIRL DATA-ENTRY ERROR and must be FLAGGED (user,
  2026-08-02)** — not quietly absorbed by the hierarchy. A report arriving with a
  number already used for a different sampling event goes **back to ACIRL to be
  reissued**. Review item: `duplicate_report_number`.

  **The discriminator is (sample date, cited ALS work order) — not repetition of the
  number, and not the content hash.** Of 16 numbers appearing on more than one file,
  **13 are one report re-saved or revised** and are NOT errors; flagging those would
  bury the real ones. Only a *different* sampling event under the same number is the
  defect. Under the A80 hierarchy the trigger is exact and cheap: this ACIRL parent
  already has a child ALS work order, and the incoming workbook cites a different one.

  **The data still imports.** Because samples attach to the CHILD (the ALS work order),
  a reused parent number cannot corrupt the data — the events stay separate either way.
  The flag exists so ACIRL fixes their process, not to withhold the results.

  **Prospective only (user, 2026-08-02): the historical three are NOT to be chased.**
  They are recorded below as evidence for the rule and to explain the collisions in the
  corpus, not as a work list. The flag fires on reports arriving from now on.

  The three already in the corpus, for reference only:

  | report no. | events it was used for | note |
  |---|---|---|
  | `2400-7222-12-05` | 2022-12-21 / `ES2246501` and 2022-12-28 / `ES2246801` | two consecutive "Special Wednesday" reports |
  | `2400-7286-01-03` | 2023-01-11 / `ES2301026` and 2023-01-18 / `ES2301817` | the second file is *named* `…-01-04` — the FILENAME is right and the front-page `REPORT NO:` cell is stale |
  | `2400-7430-01` | 2024-05-29 / `ES2417748` and 2025-05-27 / `ES2515829` | worst of the three: the second is the **May 2025** report carrying both the 2024 filename and the 2024 report number; only its sample date and ALS order are correct |

  **THE CAMPAIGN IS THE GRANDPARENT (user, 2026-08-02).** Measured before
  implementing, and it changed the shape: **116 of the 129 ALS work orders our
  ACIRL workbooks cite already have a `uuid_parent`**, and it is a *campaign* —
  `Monthly monitoring` (27), `2022 March pollution incidents` (27), `EPL quarterly`
  (24), `EPL annual` (12), `Melaleuca swamp groundwater contamination` (11),
  `Cutoff wall failure 2023` (7), `Post-closure monitoring` (7),
  `2021 stormwater dam contamination` (1). A row has one parent, so A80 taken
  literally would have **overwritten** the record of *why the sampling happened* —
  human-curated and not recoverable from anything else we hold.

  Robin's ruling: **insert the ACIRL report between them, do not displace.**

  ```
  Campaign  "EPL quarterly"            uuid_parent = NULL      (root)
    └── 2400-7400-06-01  ACIRL report  uuid_parent = campaign
          └── ES2420251  ALS work order uuid_parent = ACIRL report
  ```

  So the ALS work order's `uuid_parent` moves campaign → ACIRL report, and the
  ACIRL report takes the campaign as *its* parent. Nothing is lost; the campaign is
  one level further up. `uuid_root` stays the topmost ancestor for both. Where a
  cited work order has **no** existing parent (13 of 129), the ACIRL report simply
  becomes the root of that pair.

  This also matches a precedent already in the database that runs against the naive
  reading: **71 projects are already named with ACIRL report numbers**
  (`2400-7222-01`…), all typed `Monthly gas monitoring`, all **children** of a
  campaign of that name, carrying **12,478 samples**. Filing an ACIRL report as a
  project keyed on its report number is established practice here; what A80 adds is
  the level below it.

  **A report number colliding with an existing project MERGES into it (user,
  2026-08-02).** Six of the corpus's 132 report numbers already exist as those gas
  rows — `2400-7222-01`, `2400-7222-02`, `2400-7222-04`, `2400-7222-10`,
  `2400-7286-07`, `2400-7286-09`. The incoming water samples attach to the existing
  project row of that name rather than minting a parallel one or raising a flag:
  `.ct_ensure_project()`'s find-by-name behaviour is already correct and needs no
  namespacing. This does **not** weaken `duplicate_report_number`, which is keyed on
  (sample date, cited ALS work order) and fires prospectively on *newly arriving*
  reports — a pre-existing gas project of the same number is not a new sampling
  event under a reused number.

  **Three cases A80 did not cover, decided at implementation time (Claude,
  2026-08-02, from measurement — flagged here for Robin to overrule).** Built as
  PLAN-09 R-9.14; all three are loud rather than silent, and none destroys data.

  1. **A workbook citing TWO ALS orders** (measured: 5 workbooks, 347 of 6,208
     result rows) makes **both** children, but its samples attach to the
     **parent**. One event resolves to one `uuid_project` and the per-row ALS
     citation is not carried past the sheet, so they cannot be split between the
     two children. Attaching them all to one arbitrarily would assert a lab job
     we cannot evidence. *If this matters, the fix is in the adapter — carry the
     sheet's ALS order onto each row — not here.*
  2. **An ALS order cited by TWO DIFFERENT report numbers** (measured: 4 of 129,
     e.g. `ES2245792` by both `2400-7222-12-01` and `2400-7222-12-04`). A row has
     one parent, so the second report cannot also adopt it. The existing parent
     **stands** and a new `project_parent_conflict` review item is raised. First
     claim wins, and it is visible rather than silent.
  3. **Two cited orders under DIFFERENT campaigns** (measured: exactly one
     workbook, `2400-7286-03` — `EPL annual` and `2022 March pollution
     incidents`). There is no campaign to promote without asserting a membership
     we cannot justify, so the report becomes a **root**, neither order moves,
     and both are flagged. Same principle as the grandparent ruling itself:
     never overwrite a curated parent.

  A parent that is already set is **never overwritten** — that is what makes the
  merge safe, and what makes the whole thing order-independent when
  `archive_file()` mints the report row before any citation is known.

- **A81** **Feature-alias rulings (user, 2026-08-02).** `BORE 11` → `B.MW11`.
  `CRIPPLE CREEK INLET` → **`B.S04`**, confirmed against the registry rather than
  assumed: `B.S04` already carries the aliases `B.CRIPPLE` and `Diversion pipe inlet`,
  while `B.S12` carries `B.SPURWOOD` and `Upstream Spurwood Creek` — a different
  watercourse. It pairs with `CRIPPLE CREEK OUTLET` → `B.S05`.
  The ~212 dangling ACIRL `lab_method` confirmations are to be done as **one batch
  pass**, not spread across ingests.

- **A82** **The read-time preference is a `preference_rank` COLUMN, not a filter
  and not an `ORDER BY`** (`dev/migrations/005-preference-rank.R`, 2026-08-02).
  A75/A79 settled the *rule* — field beats lab; among lab, ALS beats ACIRL — but
  not the mechanism. Three implementation-time decisions, each forced by
  measurement rather than argued:

  1. **Every row is kept; `preference_rank = 1` marks the canonical one.** The
     alternative (dedupe in the view) would drop 972 of `v_measurement`'s 97,118
     rows. `v_measurement*` has **no in-repo consumer** —
     `dev/epa-monitoring-report.R` builds its own base query and says so at its
     assumption C — so every consumer is external and invisible to us; a column
     is additive for all of them, a row drop silently changes an answer some
     spreadsheet already produces. Both rows are also real data: the out-ranked
     lab pH is not wrong, it is a lab pH. Keeping cardinality identical is
     additionally what lets the verify gate assert "the window function changed
     no view's row count" as a hard failure. Consumers opt in with
     `WHERE preference_rank = 1`.
  2. **The partition is keyed on the SYDNEY CALENDAR DATE, not `datetime`.** The
     design as recorded said "per (feature, datetime, analyte)". Measured
     (`scratchpad/m005_partition_probe.R`): that key finds only **916** of the
     **931** contested partitions, because **54** of them have the field row and
     the lab row at different datetimes on the same day — the observed shape is
     a field reading at 00:00 and its lab twin at 00:01, one visit written by
     two clocks. Keyed on `datetime` those become partitions of one and the
     ranking silently does nothing for exactly the rows a human most expects it
     to. The date expression is 004's `.mig004_sydney_date_expr`, reused from
     one constant so the partition and the projected `date` cannot drift.
  3. **`a.uuid` is a required third ordering key.** **74** live partitions hold
     TWO field rows, which `is_field`/`is_als` cannot separate, so without it
     `preference_rank` is whatever the scan order was — a consumer could get a
     different "canonical" pH on two runs of the same query, which is worse than
     the ambiguity this migration removes. Arbitrary, but the same arbitrary
     answer every time.

  **Two corrections made 2026-08-02 (overnight), after measuring the RANKED
  OUTPUT on a copy of the live database rather than reasoning about the SQL —
  both landed before 005 was ever applied:**
  - **`preference_rank > 1` returns 2,471, not 972**, and conflating the two is
    the easiest mistake to make about this migration. 972 is the FIELD-VS-LAB
    figure; the rank counts every partition holding more than one row, whatever
    the reason. It decomposes exactly (`scratchpad/m6a_972.R`): field-vs-lab 931
    partitions → 972 out-ranked; **two or more LAB rows 706 partitions → 1,460**;
    two or more FIELD rows 39 → 39. The 1,460 were never counted because the
    design question was only ever about field-vs-lab, and **494 of those 706
    partitions hold DIFFERENT values**. `WHERE preference_rank = 1` returns
    94,647 of 97,118, not 96,146.
  - **`s.uuid` was added as the third ordering key, before `a.uuid`.** With the
    analysis uuid as the only tiebreak, each analyte chose its canonical row
    independently, and the analysis uuid bears no relation to the sample — so on
    a feature/date holding two samples, `preference_rank = 1` could select a
    DIFFERENT sample per analyte. **62 live feature/date groups did**
    (`scratchpad/m6a_frankenstein.R`). The dust triple at B.D07 on 2021-08-01 is
    the proof: canonical combustible came from one gauge, incombustible and
    total from the other, so the rank-1 rows read 0.6 + 2.2 against a total of
    4.2. With the sample key they read 0.6 + 0.7 = 1.3 and the triple sums. The
    residual 40 groups are structural — their two samples carry different
    analyte sets, so no ordering can put every analyte on one sample. Pinned by
    fixture P7, which is verified against a mutation applied to the SQL **and**
    its R oracle together (the only case the independent oracle cannot catch —
    the `.RC_FIELD_METHODS` lesson).

  Two corrections to earlier records, both measured:
  - **931, not 898.** The 898 figure was ACIRL-field-vs-ALS-lab joined on the raw
    `sample.date`; 931 is field-vs-lab regardless of organisation, keyed on the
    Sydney date the views actually report — the population the views see. pH 560
    field / 541 lab, EC 406 / 396, nothing else.
  - **`.mig004_base_n()` over-constrained the four mask views**, requiring a
    resolvable `lab_method` they never joined. It has never fired (zero such rows
    live) — a gate correct only because its failing case is empty. `005`'s oracle
    models each view's real join semantics instead; the mask views' new
    `lab_method` join is a **LEFT** join for the same reason, so cardinality
    preservation is structural rather than lucky.

  `EN67 - Client Supplied Data` ranks as field, read from `.RC_FIELD_METHODS`
  (`R/reconcile.R`) rather than copied — the views and R-8.9's supersession test
  must never disagree about what a field reading is. Mutation-confirmed: a
  mutation to that list changes the view AND the migration's own rank oracle
  together, so only the fixture tests catch it.

- **A82 AMENDED 2026-08-08** — the two analyte uuids ruling (4) creates are
  **PINNED literals**, and that is the one place a literal uuid belongs in a
  migration. The no-uuids rule is about LOOKUPS: a uuid used to find an existing
  row is unreviewable and can silently select the wrong one. These find nothing
  — they are the value a new row is created WITH, and pinning them is what lets
  006's mapping name those analytes before either migration runs, so the whole
  005 → 007 → 006 sequence is reviewable in advance and reproducible on a
  restored backup. 007 refuses if either uuid is already taken, and a test
  cross-pins them against 006's CSV so the pair cannot drift.

- **A83** **Every ACIRL transcription label gets its own ACIRL `lab_method`,
  minted BEFORE the import, with `method = NULL` and `units = NULL`**
  (`dev/migrations/006-acirl-transcription-methods.R`, 2026-08-02). A79 settled
  that a transcription is superseded by its ALS twin; A83 is what makes that
  reachable.

  **Why it must precede the import.** Analyte resolution is **per organisation** —
  `.rc_resolve_one_analyte()` filters on `organisation == org` in both its exact
  and its folded branch, so an ALS `Calcium` method does not resolve an ACIRL
  `Calcium` row (verified empirically, `scratchpad/m6a_verify_acirl.R`, not read
  off the source). Of the **215** distinct transcription labels the adapter
  emits, exactly **one** has an ACIRL method today. Importing first would mint
  214 dangling methods; a dangling method has no `uuid_analyte`; and A79's twin
  test keys on the resolved analyte uuid — so all **34,137** candidate rows in
  `unprocessed/` would commit as permanent silent duplicates.

  1. **`method = NULL` is the transcription marker, not an omission.**
     `.rc_lab_kind()` returns `acirl_transcription` iff an ACIRL method's
     `method` is NULL; any code makes it `acirl_own_lab` (ACIRL's dust work) and
     exempt from supersession forever. The water sheets carry no method codes —
     `als_candidates` has no `method_raw` column at all — so NULL is also what
     the import itself would have written.
  2. **`units = NULL`, against the first instinct, because measurement said so.**
     `lab_method.units` is INERT for value conversion: `.rc_resolve_units_values()`
     converts from the incoming ROW's `units_raw` to the ANALYTE's units and never
     reads the method's. Its only other use is the units-drift sighting, which
     fires only for DANGLING methods. **358 of the 359 live `lab_method` rows
     carry NULL units**, including all 19 existing ACIRL ones. Recording the
     corpus units would have invented a convention the database does not have,
     for a column nothing reads.
  3. **The mapping is reviewable DATA, not code** — a CSV carrying `label`,
     `analyte`, `uuid_analyte`. The `analyte` NAME is redundant with the uuid
     **deliberately**: it is what a human reviews, and checking the two against
     each other is the only way to catch a hand-edited row whose name and uuid
     drifted apart, which would link a label nobody reviewed.
  4. **The SUCCESS gate asks the PRODUCTION resolver, not the rows it inserted.**
     "Did the INSERT store what I passed it" is not the property that matters;
     "will the import now resolve this label to this analyte, and classify it as
     a transcription" is. `.rc_resolve_one_analyte()` + `.rc_lab_kind()` share no
     mechanism with the INSERT, so the two cannot be wrong together.

  Three findings recorded because they cost real measurement:
  - **A shared folded key is only a defect when the analytes DISAGREE.** The
    obvious gate — refuse any two labels folding to one `.rc_method_key()` — is
    too strict: `.rc_resolve_one_analyte()` returns `ambiguous` only when the
    folded survivors span more than one analyte. The live corpus has exactly one
    such pair (`Azinphos Methyl` / `Azinphos-methyl`, one analyte), and the
    strict gate would have dropped a real label for a danger that is not there.
  - **A "this label already resolves" gate is UNREACHABLE** and was deleted
    rather than shipped. Resolving under ACIRL requires an ACIRL method whose
    folded key equals the label's — which the collision gate already refuses.
    "Already resolved" is a strict subset of "already collides".
  - **`Total Dissolved Solids` is the third unused ACIRL `field` method whose
    name is really a transcription label** (0 analyses, not on the A76
    allowlist, 382 corpus rows), after the mojibake EC (deleted 2026-08-01) and
    the two TSS (deleted 2026-08-02). Its 382 rows would import as FIELD
    readings: never superseded, and ranked ABOVE the real ALS value by 005. A
    sweep of every ACIRL `field` method (`scratchpad/m6a_field_sweep.R`) shows
    it is the **only** one left — the family is closed. Awaiting Robin's ruling;
    not applied.

- **A83 AMENDED 2026-08-08** — the mapping is now **212 labels, not 208**, and
  it **DEPENDS ON 007** (1007 marker checked). Robin's rulings freed four of the
  seven excluded labels: `Total Dissolved Solids` (007 deletes the ACIRL `field`
  method blocking it), `>C10 - C16 Fraction` (007 repoints its ALS twin off
  TRH-F2), and `Decachlorobiphenyl` / `Volume Purged` (analytes 007 creates).
  Three remain excluded and each now has a ruling rather than a question: the
  two stale-template Fe labels drop at the ADAPTER, and the mojibake EC label is
  fixed in `normalise_lab_text()` — omitting either from the mapping does not
  stop it importing.

  The mapping gained a **`conversion_constant` column**, and it is the only
  column here that changes a committed value. `.ct_method_conversion()`
  (R/commit.R:1540) reads the constant off the MATCHED method at commit and
  multiplies `value`/`rl_low`/`rl_high`, so a transcription minted without the
  constant its ALS twin carries commits the lab's raw number as if it were
  already in the analyte's basis. Swept over all 215 labels
  (`scratchpad/m6b_cc_sweep.R`): exactly ONE needs it — `Nitrite as NO2`, 7
  rows, which would otherwise land **3.28× high** in `NO2-N`. A `reported_as`
  column rides along as documentation, because that column is what made the gap
  findable at all.

  A `preference` column was considered and **deliberately not added**. Measured
  over the 34,137-row corpus: the labels that would contest one analyte
  (`Total Dissolved Solids` vs `(Calc.)`; `Nitrite as N` vs `as NO2` vs
  `Nitrite`) **never co-occur on one sample — zero times**. An unreachable
  ordering key is decoration.

- **A84** **A sample is identified by (feature, datetime), and where two samples
  share that key the pipeline REFUSES rather than choosing**
  (`.ct_existing_sample_uuid()`, R/commit.R; `dev/migrations/008-duplicate-samples.R`,
  2026-08-08). Robin's ruling: "there should never be two samples at the same
  feature at the same datetime ... fix the existing data and quarantine any
  incoming data where this is true."

  **The import half.** `.ct_existing_sample_uuid()` used to end `cand$uuid[[1]]`
  — pick the first survivor. PLAN-7b's D6 `ORDER BY uuid` made that pick
  *stable*, which is worth having, but stable is not right: every row of the
  batch then attaches to whichever of several real samples sorted first.
  Measured (`scratchpad/r008_postfix.R`): re-ingesting one date-only B.L01 XTAB
  would have collapsed **13 separate ALS work orders** onto one sample, 179
  conflicting analyses landing on top of each other. It now aborts
  `sampletidy_error`, naming the candidates. `commit_event()` runs inside a
  transaction, so refusing IS the quarantine. Only the already-guessing path
  changes: one candidate still reuses, and a separating datetime still narrows.

  **The data half is TWO unrelated errors**, and one fix applied to both would
  destroy real data:
  - Five samples at site L, 2024-11-28: a second load of the same field
    readings under a different `person`. Every one of their 13 analyses is an
    exact (method, value) twin on the survivor, re-proved at run time.
    Deleted.
  - Forty-six at B.L01, Feb–Mar 2026: **not duplicates.** Different physical
    samples (pH 7.95–8.20, BOD 192–583), each its own work order. The error is
    the FEATURE — the lab's `Client sample ID` splits the 103 B.L01 samples 27
    `Discharge Point - Lawson STP` / 27 `Trade Waste Dam` / 1 `T/W Pump` / 48
    with no XTAB. Both named aliases are confirmed by hand, and the Lawson one
    points at **B.L05, which held zero samples**. The 27 are reassigned.

  **THE INVARIANT CANNOT BE ENFORCED IN THE DATABASE, and that is a measurement
  not an opinion.** After both fixes, 14 groups holding **44** samples still
  share a (feature, datetime) — and in every group every sample comes from a
  DISTINCT work order (44 samples, 44 work orders, no exceptions). They are real
  separate field samples taken at one discharge point on one day, all stamped
  00:00 because the XTAB format carries no time field, and their true times
  exist nowhere: `datetime_start` identical, no `change_log` rows, and 1 of 47
  work orders with a timed chain-of-custody. A `UNIQUE (feature, datetime)`
  index would require inventing 44 clock times. `sample` also has no
  `uuid_feature` and no work-order column, so even the weaker alias-level index
  is not the stated invariant. Enforcement therefore lives in code.

  **Two things the rehearsal caught that reading could not.** duckdb refuses to
  DELETE *or* UPDATE a `sample` while any `analysis` references it — the same
  F.14 limitation A82's migration hit on `lab_method`, and on a column that is
  not part of any key — so both rulings run as separately-committed pre-passes.
  And moving samples to B.L05 silently dropped **522 measurements out of
  `v_measurement_epa` and `v_measurement_long`**, because both views INNER JOIN
  `feature_mask` and B.L05 has no mask rows while B.L01 carries EPA `21`. The
  migration now refuses until the destination is as visible as the source —
  whether the Lawson STP tanker discharge belongs in the EPA return at all is a
  ruling, not a migration's decision.
- **A84 AMENDED 2026-10-17 by A91** — the IMPORT half no longer refuses.
  Two or more indistinguishable candidates now withhold the incoming rows as
  `sample_ambiguous` (candidates listed) and the rest of the file commits, for
  EVERY adapter, ALS included (Robin, D2). Candidates are only the samples of
  the row's own stream (A91). `.ct_existing_sample_uuid()` keeps its abort, but
  only as an invariant check that reconcile makes unreachable. The DATA half
  above (008's two fixes, and the invariant living in code) is unchanged.

- **A85** **A bare number in a units column is never a unit** — refused as
  `units_implausible / units_numeric` (`R/reconcile.R`, 2026-08-08). udunits
  disagrees, and that is the danger: it reads a bare number as a DIMENSIONLESS
  SCALE FACTOR, so `1.89` is a valid unit meaning "× 1.89". Measured: 17
  `Sodium Adsorption Ratio` corpus rows carry `units_raw = 1.89` while their
  values are 1.84 / 2.18 / 2.03 — a value that landed in the units cell. Against
  the registry as it stood (`SAR` units `mg/L`) they ERROR and get reviewed;
  the moment SAR is corrected to the dimensionless `1` (A86) they would have
  CONVERTED, silently multiplied by 1.89, and A85's *value* arm could not see it
  because 1.84 × 1.89 = 3.48 is an ordinary SAR number. **Fixing one defect
  would have created a worse one.** `1` itself is exempt — it is the genuine
  dimensionless unit, and `NTMI` already uses it. The corpus's whole units
  vocabulary is 13 strings and exactly one is numeric.

  The value arm also tests **the number that will be STORED, which for a
  non-detect is the reporting limit**. `parse_value()` leaves `value_num` NA on
  a `<20` and puts 20 in `rl`, so testing `value` alone skipped every
  non-detect — and of the six `C6 - C10 Fraction` rows the arm exists for (the
  `mg/L` → `mg/L` case no units library can see), **five are non-detects**. That
  comparison is apples-to-apples: of 47,227 live non-detects, 34,942 carry
  `value == rl_low` exactly.

- **A86** **`SAR` is dimensionless (`units = '1'`), and the `%`-typed Aroclor
  rows are surrogate recoveries that never import** (2026-08-08 rulings).

  SAR is a ratio and carries no units; the registry had `mg/L` with **253
  committed analyses** under that label whose NUMBERS are right (0.1–152 are
  ordinary SAR values). 007 ruling (6) relabels and re-values nothing. `1`
  rather than NULL because the database already has the convention (`NTMI`).
  It is also the entire real-world load of A85's `units_missing` arm — 485 of
  48,752 crosstab rows, all SAR — which goes quiet once the registry is right.
  **It could only ship alongside A85's bare-number guard**; see A85.

  The Aroclor exclusion is keyed on **(label-family AND units)**, not on either
  alone, and measurement is why. Label-only — the shape the Fe and
  site-metadata exclusions use — would delete the 7 real `<0.10 µg/L` PCB
  measurements, because the same three labels sit on both sides of the split.
  Units-only (`any % row`) would delete **247 legitimate `Ionic Balance` rows**
  plus 1,133 rows nobody has ruled on. Workbook geometry confirms the reading:
  a valueless `PAH Surrogates` heading followed by three `%` rows in one file,
  a `Polychlorinated Biphenyls` heading followed by seven `µg/L` rows in
  another.

  **Of the 1,395 `%` rows, only these 15 are miscategorised.** The other 12
  labels (1,353 rows) already resolve to QC analytes registered in `%` and
  import correctly — the alarm about them was unfounded, checked label by
  label.

- **OPEN, NOT ACTED ON: four Aroclor labels resolve to single PCB CONGENERS.**
  ALS `Aroclor 1016` → `3,3',5-Trichlorobiphenyl`, `1248` →
  `3,3',5,5'-Tetrachlorobiphenyl`, `1254` → `2,2',3,3',4-Pentachlorobiphenyl`,
  `1260` → `2,2',3,3',4,4'-Hexachlorobiphenyl` — with those congeners' CAS
  numbers. An Aroclor is a commercial PCB *mixture*; a congener is one
  compound. `1221`/`1232` map to correctly-named Aroclor analytes, and `1242` →
  `Chlorodiphenyl` carries Aroclor 1242's own CAS, so it is a naming oddity
  rather than a wrong link. The 006 mapping inherited these links faithfully
  from the registry (`basis = lab_method(ALS)`), so this is a REGISTRY defect
  of the same shape as A82's `>C10 - C16 Fraction` repoint. Needs a ruling.


- **A88** **An adapter may withhold rows it does not trust; the human releases
  them with a date** (design 2026-10-16; first user: A77's `date_conflict`).

  *Signal.* An adapter sets `needs_review` / `review_kind` / `review_payload`
  (A22's names) on rows of its `results`. Assembly MERGES its own
  `foreign_work_order` flag into those columns instead of overwriting them: a
  row an adapter already flagged keeps the adapter's kind and payload.
  Reconcile's STAGE-0 removes flagged rows from `active` before QC, so they
  never commit.

  *Fold.* Flagged rows of one file with the same `(source_hash, review_kind,
  payload)` become ONE review item, `n_rows = k`. The adapter chooses the
  grouping by giving rows an identical payload (one A77 gauge-block; every row
  of a gas file whose filename and REPORT NO disagree). The fold is global;
  it changes no existing outcome because assembly's per-row flags carry the
  row's own work order or conflict facts, so their payloads differ.

  *Payload carries the rows.* For adapter-raised kinds (not `value_conflict`
  / `other`) STAGE-0 writes the withheld rows whole into `payload$rows`, and
  the item's `work_order` is the rows' own. Release therefore needs neither the
  archived file nor a re-parse.

  *A77.* `review_kind = "date_conflict"`, subkind `a77`, one item per
  gauge-block; payload names gauge, file, `month_raw`, `month_date`,
  `exposure_date`, `collection_date` and the `withheld` analyses. The three
  dust analytes AND the block's ANALYSIS OBSERVATIONS row are withheld.

  *Informational signals.* A row may carry `review_withhold = FALSE` (default
  TRUE with `needs_review`): the item is raised and folded as above, but the
  row stays in the pipeline and COMMITS. The payload then carries
  `informational: true` instead of `rows`. The gas filename/REPORT NO mismatch
  uses this; a >2 dp gas reading is withheld and wins on its own row.

  *Dedupe.* `.ct_commit_review()` opens no second OPEN item with the same
  `(kind, source_hash, payload)` for items carrying `payload$rows` (the shape
  `adapter_tie` and `work_order_reingest` follow).

  *Release.* `release_review(uuid, overrides = list(date_start, date),
  resolved_by, db)` (exported) applies the overrides to the withheld rows'
  sample dates, runs them through `reconcile_event()` and the ordinary commit
  steps, and resolves the item, in one transaction. Idempotent: an
  already-resolved item releases nothing.

- **A89** **Only an adapter that declares `zero_is_nondetect = TRUE` has a bare
  `0` read as a non-detect** (2026-10-16). The ACIRL gas analyser reports `0`
  for "below what I can see" (PLAN-17 ruling 1). `parse_value("0")` stays
  `quantified = TRUE` for everyone (R-2.3). The gas adapter sets the field in
  its registry entry; `.rc_resolve_units_values()` looks up each row's adapter
  and sets `quantified = FALSE` for an exact `"0"` value only there, so a
  re-ingested month compares equal to the legacy load (`already_present`).

- **A90** **Registry verdicts store a REGISTRY FINGERPRINT, and a stale one is
  re-decided without `reconsider`** (Robin, 2026-10-17; R-3.8). `ingest_file.registry_fingerprint`
  holds a hash of the registered adapters' ids and versions (`registry_fingerprint()`,
  sorted by id, so registration order is irrelevant; function bodies are not hashed -
  an adapter author signals a behaviour change by bumping `version`). It is written
  with each router verdict: `quarantined`/`unclaimed`, `quarantined`/`adapter_tie`,
  and router-written `failed` (no adapter recorded). On a later route, such a row whose
  stored fingerprint differs from the current one, or is NULL (legacy), is re-decided
  exactly as `reconsider = TRUE` would. A fingerprint change NEVER re-decides
  `archived`, `ignored` or parse-/commit-written `failed` rows. `reconsider = TRUE`
  keeps its R-3.7 behaviour: it forces registry verdicts AND any `failed`, never
  `archived`/`ignored`. A dry run persists neither the verdict nor the new
  fingerprint (F12). An automatic re-decision of a still-tied file opens no second
  `adapter_tie` review item (the R-3.7 dedupe). Ops-schema version 8; migration 023
  (marker 1023) adds the column to the live DB with no backfill.

- **A91** **A sample is matched within its contractor STREAM; an ambiguous match
  is reviewed, not refused** (Robin, 2026-10-17; amends A84's import half;
  design `scratchpad/2026-10-17-acirlmatch/DESIGN.md`, R2).
  Every analysis belongs to one stream, read from its `lab_method`: `gas` when
  the analyte's `type` is `gas`, otherwise the lab_method's `organisation`
  (`ACIRL` — field, transcription and dust — `ALS`, `legacy`, `Internal`, …).
  An incoming row may reuse only a sample at the same feature and Sydney day
  that already holds an analysis of the **same** stream (a sample with no
  analyses matches any stream); A62's datetime predicate then decides among
  those as before. None → a new sample; one → reuse; more than one → the rows
  are withheld (`sample_ambiguous`, candidates listed) and the rest of the
  file commits; `release_review(overrides = list(sample = ...))` places them.
  A new sample that would share a non-NA datetime with another stream's sample
  at that feature is also withheld (`cross_stream_instant`).
  **Why:** `sample.organisation` is the sampler and the project is not the
  contractor (A80 files ACIRL field samples under the ALS order), so only
  the lab_method attributes a reading. Legacy holds ACIRL field readings both
  merged into ALS samples (971) and as separate samples (130); keying on
  "holds a reading of my stream" reuses both shapes, so re-ingesting a legacy
  field sheet duplicates no visit. Gas is its own stream because a gas sample's
  project is the gas campaign and a sample's project is its first writer and
  cannot be updated (A84/F.14): sharing a sample with field readings would make
  the result depend on arrival order. Measured: R0 aborted at 66 feature-days;
  under A91 15 reuse, 28 create, 23 (legacy one-visit-two-samples) review.

  *Rulings (Robin, 2026-10-17).* **D1** gas readings get their own samples
  (stream `gas`) and never share the ACIRL field sample. **D2** review instead
  of abort applies to every adapter, ALS included (the A84 amendment above).
  **D3** on a day holding only an ALS sample, an incoming ACIRL field row
  creates a separate ACIRL sample; it does not merge into the ALS one.

  *Unchanged:* `already_present`, `value_conflict`, supersedes, A79
  transcription supersession (all lab- or analyte-keyed across every sample of
  the feature-day), dust `date_start` handling, and `ux_sample_identity`.
