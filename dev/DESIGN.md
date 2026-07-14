# sampleTidy — architecture & ingestion pipeline (design v2)

**Status:** design agreed, pre-implementation. Supersedes
[issue #1](https://github.com/vorpalvorpal/sampleTidy/issues/1), incorporating
decisions from the empirical review of the live `input/` corpus (July 2026).
Decisions are settled unless marked _Open_.

---

## 1. Purpose, audiences & scope

Turn the heterogeneous stream of environmental-monitoring results a programme
receives into clean, reconciled rows in a DuckDB-backed database, with every
value linked back to its archived original file.

**Two audiences.** (1) The BMCC waste-monitoring workflow; (2) users of the
`tidyWaste` ecosystem, of which this package is a central part. The rule that
enforces the split: **no site-specific strings in package code.** Site names,
org registries, folder paths, field-analyte lists and adapter thresholds live
in the database (features/analytes/masks) or in user configuration — never in
`R/`. The package ships the framework and the broadly-useful adapters; anything
site-specific arrives through `register_adapter()` and config.

**In scope:** intake → parse → assemble → reconcile → review → commit →
archive; the canonical read API (`data_df`-style access, kept in this package);
a post-commit hook seam for monitoring/alerting.

**Out of scope (separate packages / later):** the gas-monitoring email report;
plotting (`data_plot`); the XLSX summary (`data_xl`); Nearmap / eagle.io
weather integrations; leachate indices (live in `leachatetools`, hooked in via
the post-commit seam).

**MVP definition** (everything else in this doc is designed but deferred):

- Ingest the flat `input/` directory (subfolders ignored) into the **existing**
  `monitoring.duckdb`. Entry point is `ingest_dir(path, db)` — a plain function
  anyone can point at a folder of lab files; transport (§12) is just one way of
  filling the folder.
- Adapters: `esdat`, `als_enmrg`, `als_xtab`, and `acirl_field_xlsx` (+ ignore
  rules) — the ACIRL workbook is in the MVP because its field data exists
  nowhere else. LLM adapters (scanned ACIRL reports, generic PDF) follow after
  the structured path works end to end; until then field measurements carry
  the workbook's date-level sampling datetime (front-page sheet), with
  clock-time enrichment from the scanned PDF as a post-MVP step.
- QC data excluded via `sample_type == "Normal"` filter, but counted and
  logged (§7, §13).
- Leftover files from old WEM.data runs (orphan Sample2e/Header files,
  work orders with only COA/COC PDFs) are marked `ignored`, not processed.
- Per-run summary report (files seen / parsed / committed / quarantined /
  ignored). Full pipeline-health monitoring deferred (§14).

---

## 2. Source landscape (empirical)

What is actually in the intake stream, from inspection of ~260 live files:

| family | files | contents | fate |
|---|---|---|---|
| ALS ESdat EDD (`*.Chemistry2e.CSV`, `*.Sample2e.CSV`, `*.Header.XML`) | ~130 | results + typed sample metadata + report metadata; EScIS schema 1.0.1 | **primary** |
| ALS ENMRG (`*_ENMRG.CSV`) | ~15 | crosstab incl. untyped QC-lot columns | fallback 1 |
| ALS XTAB (`*_XTAB.csv/.XLS`) | ~40 | crosstab, regular samples only, legacy encoding | fallback 2 |
| ALS COA/COC/QC PDFs | ~90 | rendered report / chain of custody / QC report | archive only when a structured sibling exists |
| ACIRL monthly workbook (`2400-*.xls`) | ~10 | human-edited; ALS lab data (**ignore**) + ACIRL field data (**keep**) | field-data adapter |
| ACIRL monthly report (`2400-*.pdf`, older scans) | ~15 | scanned; sampler identity, field-sampling times | LLM adapter |
| cruft (`.bak`, `[N]` duplicate downloads, `.DS_Store`, subfolders) | — | old-pipeline residue | ignore rules |

### 2.1 Format-equivalence findings (measured, not assumed)

For the same work order, ESdat/XTAB/ENMRG regular-sample results are
**content-identical** — zero missing values in either direction and zero value
disagreements across every compared cell. The differences are at the margins:

- **ESdat is the superset.** It alone carries `Lab_Qualifier`, CAS numbers,
  `Extraction_Date`/`Analysed_Date`, `Total_or_Filtered`, `UCL`/`LCL`, and —
  critically — `Sampled_Date_Time` with genuine clock times (verified across
  49 files: all monitoring rows timed, none defaulted). XTAB/ENMRG carry date
  only.
- **`Sampled_Date_Time` is the field collection time — the canonical sample
  datetime** — not a lab timestamp (verified: it varies per sample within a
  round, precedes lab receipt by days, and repeat visits to the same feature
  carry distinct times). ALS transcribes it from the CoC, so its provenance is
  the sampler's handwriting; it may in principle be absent, in which case the
  reconciler falls back to ACIRL paperwork or review. The lab-side
  `Extraction_Date`/`Analysed_Date` on Chemistry2e are analysis metadata only
  (`analysed_date` in the IR) and never populate the sample datetime.
- **ESdat types its QC.** The Chemistry2e/Sample2e pair includes the whole lab
  QC lot with `Sample_Type` codes (`LCS`, `MB`, `LAB_D`, `MS`, `NCP`) and
  `Parent_Sample` linkage. ENMRG includes QC as anonymous extra columns; XTAB
  drops QC entirely.
- **Encodings differ.** ESdat/ENMRG are UTF-8; XTAB is legacy-encoded
  (`°` as a MacRoman byte). The `normalise_lab_text()` mojibake table is ported
  for the XTAB path and for reconciliation generally.

**Source preference (settled): `ESdat > ENMRG > XTAB > COA PDF`.** Within an
event, only the best available rendering is parsed; the rest are archived
unparsed. A PDF reaches the LLM adapter only when no structured sibling exists.

### 2.2 ESdat quirks the adapter must handle

- **One export ≠ one work order.** A project-level Chemistry2e can contain rows
  for a dozen other work orders (QC context, `NCP` rows). The adapter
  partitions by `Lab_Report_Number` and `Sample_Type`; it never assumes
  file = project.
- **Partial deliveries.** Sample2e or Header.XML may arrive without
  Chemistry2e. MVP: such orphans (all currently old-pipeline leftovers) are
  `ignored`. _Open (post-MVP):_ an `awaiting_results` state for genuinely
  incomplete deliveries.

### 2.3 ACIRL flow

The ACIRL monthly workbook duplicates ALS lab results alongside
ACIRL-collected field data. The lab data is **dropped at the adapter level**
(not left for reconciliation to dedup — the sheet is human-edited, so its lab
values may differ subtly from ALS's authoritative values and would generate
conflict noise). The field-data adapter emits only field-collected analytes,
driven by a configured field-analyte list, not a hardcoded one. Sampling times
for field measurements come from the ACIRL scanned report (LLM adapter);
sampling times for lab samples come from ESdat `Sampled_Date_Time`.

---

## 3. Architecture overview

```
                                      ┌────────── SPECIFIC (pluggable) ─────────┐  ┌───────────────── GENERIC (written once) ─────────────────┐
 [transport: §12] ─▶ watched local dir ─▶ Router ─▶ Adapter ─▶ IR (results +  ─▶ Assemble ─▶ Reconcile ─▶ Gate ─▶ Commit ─▶ Archive ─▶ post-commit
                      (poll + hash)       tiered     parse       samples)         by work     vs DB:      clean │  DuckDB     link in     hook (alerts,
                                          claim                                   order,      new /            │  (txn +      DB          leachate checks)
                                                                                  source      already-present /│  change_log)
                                                                                  preference  conflict         ▼
                                                                                                          Review queue ─▶ resolve API (human / LLM proposals)
```

Everything left of the IR is format-specific and small; everything right of it
is generic and shared. The MVP replaces the transport stage with "Robin points
`ingest_dir()` at the folder".

---

## 4. Intermediate representation (IR)

**The IR is two tables, not one** — lab deliverables themselves split results
from sample metadata (ESdat Chemistry2e vs Sample2e), and metadata-only sources
(CoC PDFs, ACIRL front pages, email sidecars) need a home that isn't fake
observation rows. Adapters emit `list(results = <tibble>, samples = <tibble>)`;
either may be empty.

### 4.1 `results` (one row per reported result)

| field | type | meaning |
|---|---|---|
| `source_hash` | chr | content hash of the original file — idempotency key |
| `source_ref` | chr | cell/row coordinate within the source (`Sheet1!B14`) |
| `work_order` | chr | lab report number (`ES2515460`) — **primary grouping key** |
| `revision` | int | lab report revision (`_0`, `_1`, …) — supersede trigger |
| `org` | chr | source organisation (`ALS`, `ACIRL`, `internal`, …) |
| `adapter` | chr | adapter id + version that produced the row |
| `lab_sample_id` | chr | lab's sample code (`ES2515460001`) |
| `sample_type` | chr | verbatim lab type (`Normal`, `LCS`, `MB`, `LAB_D`, `MS`, `NCP`); adapters default `"Normal"` when the source has no concept of it |
| `feature_raw` | chr | sampling point as written (`Field_ID` / client sample ID) |
| `analyte_raw` | chr | analyte name as written |
| `cas_number` | chr | CAS where the source provides it |
| `method_raw` | chr | lab method as written |
| `total_or_filtered` | chr | `T`/`F` where provided (dissolved vs total) |
| `units_raw` | chr | units as written |
| `value_raw` | chr | verbatim value (`<0.01`, `ND`, `2.3`, …) |
| `value_num` | dbl | parsed numeric (NA if non-numeric) |
| `value_chr` | chr | text value (comments / observations) |
| `below_detection` | lgl | parsed below-detection flag |
| `rl` | dbl | reporting / detection limit (EQL) |
| `lab_qualifier` | chr | lab qualifier flags, verbatim |
| `analysed_date` | date | analysis date where provided |
| `comments` | chr | row-level comments |
| `confidence` | dbl | parser confidence (1 for structured; agreement score for LLM, §8) |

### 4.2 `samples` (one row per sample or sampling event)

| field | type | meaning |
|---|---|---|
| `source_hash`, `source_ref`, `work_order`, `org`, `adapter` | | as above |
| `lab_sample_id` | chr | joins to `results` |
| `feature_raw` | chr | sampling point as written |
| `sample_datetime_raw` | chr | sampling date/time as written |
| `sample_type` | chr | as above |
| `parent_sample` | chr | lab's parent-sample linkage (duplicates/spikes) |
| `matrix_raw` | chr | matrix as written (`WATER`, …) |
| `sampler` | chr | who sampled (CoC / front page / email body) |
| `comments` | chr | sample-level comments |
| `confidence` | dbl | as above |

Email-transport fields (`message_id`, `received_at`) attach at the event
level when the sidecar exists (§12); they are not IR columns the MVP requires.

Raw fields are preserved verbatim in all cases; parsing raw → canonical is the
reconciler's job, and the canonical timezone is **Australia/Sydney**. Crosstab
date columns are hard-asserted d/m/y.

---

## 5. Adapters & the router

```r
adapter <- list(
  id    = "esdat",                    # + version
  match = function(file_meta) c("exact", "format", "fallback", "no")[i],
  parse = function(path, file_meta) list(results = <tibble>,
                                         samples = <tibble>,
                                         report  = <parse_report>)
)
register_adapter(adapter)
```

- **`match` returns a discrete tier, not a 0–1 score.** Continuous scores
  written by independent authors aren't comparable and misroute silently.
  Tiers: `exact` (fingerprint match — e.g. ESdat XML namespace, ENMRG
  `Workgroup:` header), `format` (file family matches), `fallback` (the
  generic LLM adapter's constant claim), `no`.
- **Ambiguity fails loud:** two adapters claiming the same tier for one file →
  quarantine, never "pick the best". Router logs every claim.
- `file_meta` carries `path`, `ext`, `filename`, `sheet_names`, a peek of first
  cells, and (post-MVP) `org_guess` from the sidecar.
- **Ignore rules** are first-class: `.bak`, `[N]` duplicate-download names,
  `.DS_Store`, subdirectories, and configured leftovers route to the `ignored`
  state — recorded, listable, never silent.
- Planned adapters: `esdat`, `als_enmrg`, `als_xtab`, `acirl_field_xlsx`
  (MVP); `acirl_report_pdf` (LLM), `generic_llm` (post-MVP).
  Site-specific adapters register from user config, not from the package.

**Router test (required):** every registered `match` runs over the entire
golden corpus (§15); every fixture must be claimed by exactly one adapter at
its winning tier.

---

## 6. Event assembly

Between parse and reconcile, IR rows are grouped into **events keyed by
`work_order`** (lab report number — present in ESdat content, crosstab headers,
and COA/COC filenames alike). Within an event:

1. **Source preference** (§2.1) selects which rendering's `results` survive;
   lesser renderings are recorded as `superseded_by_better_source` and
   archived.
2. `samples` rows from all sources merge onto `results` by `lab_sample_id`
   (falling back to `feature_raw` + date), filling `sample_datetime`,
   `sampler`, `matrix`, `parent_sample`.
3. Multi-file context that arrives later (a CoC PDF for an already-parsed work
   order) attaches to the same event by `work_order`.

When email transport exists (§12), `message_id` becomes a secondary grouping
key; the work order remains primary because it works with or without email
context.

---

## 7. Reconciliation

The generic reconciler resolves assembled IR rows against the DB:
`feature_raw → uuid_feature` (masks/aliases); `(analyte_raw, cas_number,
method_raw, total_or_filtered, org) → uuid_lab → uuid_analyte`;
`units_raw →` canonical conversion via the ported unit engine
(`unify_value()`, `are_compatible_units()`, rebuilt without interactive
prompts); value/BDL parsing (`cleanBDLvalues()`); mojibake normalisation
(`normalise_lab_text()`).

- **Deterministic rules first.** Known mojibake, registered unit aliases and
  name masks auto-resolve with no LLM involvement.
- **Three-way outcome per row (not two):**
  - **new** → stage for commit;
  - **already-present** — same feature, datetime, analyte and value after
    normalisation → record provenance link, skip. This is an expected outcome,
    not an anomaly: the first MVP run re-encounters data old WEM.data already
    committed (e.g. live ESdat files whose XTAB sibling was ingested and
    `.bak`-ed), and it is what makes re-running over the same folder always
    safe;
  - **conflict** — same key, different value → supersede logic if the incoming
    `revision` is higher (new data over-rules old; the replaced value is
    recorded in `change_log`), otherwise review queue.
- **QC filter (MVP):** only `sample_type == "Normal"` rows proceed; everything
  else is counted per type and logged, keeping the QC seam (§13) visible.
  `NCP` rows (other work orders' batch context) are always excluded.
- **Method preference** (same analyte, multiple methods: keep lower RL; tie →
  higher value) is a reconciler policy, stated here once — never
  re-implemented inside adapters.
- **Ambiguity fails loud into quarantine — never a silent drop or downgrade.**
  Contamination is the null hypothesis; auto-resolution that hides an
  exceedance is the failure mode this design exists to prevent.

---

## 8. LLM usage

**Discipline — non-negotiable:**

- **LLMs never write to the DB.** They produce *proposals* (value + rationale)
  into the review queue, or IR rows that must pass the gates below.
- **Provider-agnostic by construction.** The package defines one narrow
  internal contract — `llm_extract(file_or_text, schema, prompt) → typed
  tibble` — with pluggable backends:
  - `backend_claude_code()` — shells out to Claude Code headless
    (`claude -p --output-format json`) via processx; runs on a Claude Pro/Max
    subscription (no API key) and reads PDFs/scans natively;
  - `backend_ellmer(chat)` — any ellmer provider: Ollama local models, or
    API-key providers later. ellmer sits in `Suggests`. Local backends get
    text via pdftools/tesseract first.
  - MS Copilot has no sanctioned completion API — parked.
- **Parse-stage gate:** LLM-parsed rows never auto-commit on one extraction.
  Two independent extractions (two backends, or one backend twice) must agree
  on the numeric fields (value, unit, RL, date); agreement **is** the
  confidence score. Disagreements go to the review queue. Self-reported model
  confidence gates nothing.
- Source preference (§2.1) keeps LLM volume low: only documents with no
  structured sibling ever reach it.

### 8.1 The resolve API (one core, two modes)

The review queue is worked through an **exported R function** (queue in,
decisions out via the mutation API) — the Claude Code skill is a thin client
of it, not the implementation, so the workflow never depends on one provider.

- **Headless:** auto-applies only high-confidence deterministic proposals;
  everything else stays queued.
- **Interactive:** walks the operator through hard cases with full DB context,
  then commits. Replaces the old `readline2` prompts and the Shiny editor.

---

## 9. Storage & writer model

Keep the existing DuckDB **schema** as-is; additions are fine, breaking
changes need strong cause. Port schema names natively (snake_case) — the
`.schema_to_legacy_names()` dot-notation shim is WEM.data compatibility, and
dies with WEM.data.

### 9.1 Locations — the live DB is never inside a synced folder

OneDrive does not respect DuckDB's file lock: it uploads torn mid-write
copies, spawns conflict files, and can dehydrate placeholders (a file read
during this review blocked for minutes on materialisation). Therefore:

- **Live DB:** local, un-synced, configurable path (default under
  `~/Library/Application Support/sampleTidy/` or `rappdirs`-equivalent).
- **Snapshots:** checkpointed, closed copies written *into* the
  SharePoint-synced folder — taken under the write lock after `CHECKPOINT`,
  landed via atomic rename so a reader mid-refresh keeps a consistent file.
  Taken only on days the DB changed; pruned by age (e.g. keep dailies 60 days,
  monthlies indefinitely — _Open:_ exact retention).
- **Analysis/reports read the snapshot**, never the live file, so long-lived
  readers can't block the writer and never see partial state.

### 9.2 Concurrency — DuckDB is the lock

DuckDB takes an exclusive OS-level lock on RW open; released by disconnect
(guaranteed via `on.exit`) and by the kernel on crash. No homemade lockfiles.

```r
with_db_write <- function(fn, db = live_db_path(), max_wait = 60, every = 2) {
  waited <- 0; last_err <- NULL
  repeat {
    con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), db, read_only = FALSE),
                    error = function(e) { last_err <<- e; NULL })
    if (!is.null(con)) break
    if (!grepl("lock", conditionMessage(last_err), ignore.case = TRUE))
      stop(last_err)                       # corrupt file / bad path ≠ "busy"
    if (waited >= max_wait)
      cli::cli_abort("DB busy after {max_wait}s: {conditionMessage(last_err)}")
    Sys.sleep(every); waited <- waited + every
  }
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  fn(con)
}
```

### 9.3 Mutation API and the change log

One set of write functions used by pipeline and humans alike —
`correct_value()`, `add_feature()`, `add_analyte()` (no interactive prompts),
generic `db_append`/`db_update`/`db_delete`. **This is the only write door**;
human edits go through it, never raw SQL.

An append-only **`change_log` table lives in the same DuckDB file and is
written in the same transaction** as the mutation it records (who/when/table/
uuid/old/new/reason) — log and change commit or roll back together. Supersedes
from re-issued reports (§7) land here, answering "what did the lab originally
say" without value-versioning. Rows are tiny; never pruned. Snapshots carry it
automatically. There is no other audit machinery — the archived original file
plus the change log is the provenance story.

---

## 10. Ingestion state machine

State is persisted **per file**, with an event-level rollup by `work_order`:

`seen → claimed → parsed → assembled → reconciled → {clean | needs_review} →
committed → archived`, with terminal states `ignored` (cruft, leftovers,
lesser renderings), `quarantined` (ambiguity, adapter tie, unparseable), and
`failed` (crash/IO). A `processed_files` table keyed by **content hash** gives
file-level idempotency (re-syncs, duplicate downloads, the same attachment in
two emails). A duplicate hash is *logged as an association* with the earlier
sighting, not silently skipped. Persisting state makes crashes recoverable and
"what's pending?" answerable.

---

## 11. The watcher (post-MVP; MVP is manual/launchd `ingest_dir()`)

- **Poll, don't trust push:** periodic hash-diff of the directory against
  `processed_files` is the primary path; FSEvents is a latency bonus.
- OneDrive Files-On-Demand: pin the incoming folder *Always keep on this
  device*; verify materialisation before reading (observed failure mode: reads
  block for minutes on placeholder download).
- Stability check (size/mtime unchanged for N s) before ingest.
- Runs as a launchd LaunchAgent on the Mac.

---

## 12. Transport (post-MVP; design settled)

MS Graph API is blocked by org policy. Resolution, entirely via sanctioned
Microsoft tooling: `Outlook rule → Power Automate (save attachments) →
SharePoint folder → OneDrive sync → watched local dir`. The SharePoint folder
is a durable queue; the pipeline holds no credentials.

Power Automate setup requirements:

- **Metadata sidecar per email** — JSON with Internet-Message-Id, From,
  Subject, Received time, plain-text body (sampling context lives in bodies),
  **and a manifest of attachment names** — written *last*, so sidecar-complete
  + all-manifest-files-stable is the ingest gate (OneDrive sync order is not
  guaranteed).
- **One subfolder per email** (`Incoming/<date>__<msgid>/`); event idempotency
  keys on Internet-Message-Id, not folder name (PA double-fires get renamed
  folders).

---

## 13. QC seam (deferred; design sketch)

QC attaches to the **work order (project)**, not to features — LCS/MB/MS are
properties of the lab batch. Future shape: one additive `qc_analysis` table
keyed by `uuid_project` + `qc_type` + analyte, with value, recovery %,
`UCL`/`LCL`, and `parent_lab_sample_id` (fed directly by ESdat's
`Parent_Sample`). No fictitious features; existing tables untouched. Because
the ESdat adapter already parses QC rows (then filters them), enabling QC
later is a reconciler + schema change only — no parser work. Field QC (trip
blanks, field duplicates) is a separate later problem; those arrive as
`Normal` samples.

---

## 14. Pipeline health & alerting (deferred, not forgotten)

The transport chain has six silent-failure hops; "no new results" must be
distinguishable from "the flow broke in April". Post-MVP:

- reconciliation count: emails matched by the Outlook rule vs
  `processed_files` rows;
- alarm when `input/` holds unprocessed files older than N days;
- weekly heartbeat digest (received / processed / quarantined counts, oldest
  queue item);
- post-commit hook passes newly committed values to checks (`leachatetools`
  indices later). _Open:_ alert channels — likely macOS notification + review
  dashboard, high-priority push for genuine exceedances.

MVP keeps the seam warm with the per-run summary report.

---

## 15. Testing

- **Golden corpus of real historical files:** input → expected IR, per
  adapter. The 1,598 UUID-named files in `processed/` plus the current DB are
  a ready-made oracle: re-parse archived files with new adapters and compare
  against what the old pipeline committed.
- **Router cross-match matrix** (§5): every fixture claimed by exactly one
  adapter.
- **Encoding fixtures:** XTAB mojibake cases; d/m/y date assertions.
- **Idempotency:** ingesting the same corpus twice changes nothing
  (already-present path, §7).
- testthat 3e throughout.

---

## 16. Build order

1. **Contracts first:** IR schema (both tables), adapter registry +
   tiered `match`, state-machine / `processed_files` / review-queue /
   `change_log` tables.
2. Port salvaged primitives: DuckDB schema, `vector_from_key()` /
   `str_which_df()`, unit engine, `normalise_lab_text()` + mojibake table,
   `cleanBDLvalues()`, mask/variant system, `backup_db()`.
3. `esdat` adapter + golden fixtures → router → assembly → reconciler
   (three-way) → gate/commit → `ingest_dir()` end to end.
4. `als_enmrg`, `als_xtab`, `acirl_field_xlsx` adapters; ignore rules; first
   full run over `input/`.
5. Post-MVP, roughly in order: LLM backends + ACIRL report adapter (clock-time
   enrichment for field measurements), review/resolve interactive mode,
   watcher + transport, pipeline health, QC.

## Open questions

- [ ] Exact snapshot retention policy (§9.1).
- [ ] Alert channels (§14).
- [ ] `awaiting_results` state for incomplete deliveries (§2.2) — post-MVP.
- [ ] Whether historical backlog gaps (structured-file-less work orders that
      *do* need ingesting, if any emerge) are filled by ALS Webtrieve EDD
      re-export rather than PDF parsing.
- [ ] Clock-time enrichment mechanics (post-MVP): adding a time to a
      date-only field sample changes the sample's datetime, which is part of
      the (feature, datetime, analyte) key used for already-present/supersede
      matching — enrichment must match on date-granularity and update via the
      mutation API without creating a "new" sample.
