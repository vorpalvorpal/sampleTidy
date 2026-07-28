# PLAN 07 — Event assembly & source preference

**Owns:** `R/assemble.R`, `tests/testthat/test-assemble.R`. **Depends on:**
03–06 (uses their IR outputs as inputs; fixtures reuse theirs).

Input: the per-file parse outputs of one router batch —
`list(<hash> = list(ir = list(results, samples), report, meta))` for every
file in state `parsed`. Output: a list of **events** and per-file state
updates (`parsed → assembled`, or terminal states below).

## R-7.1 Grouping

Events key on `work_order` (DESIGN §6). Files whose IR yields
`work_order = NA` (e.g. ACIRL workbook with unparseable report no) form
single-file events keyed by their hash, flagged `orphan = TRUE`. Criteria:
three files sharing `XX1234567` form one event; a lone Sample2e forms its own
event; NA-work-order file forms an orphan event without error.

## R-7.2 Source preference (DESIGN §2.1)

Within an event, **per work order**, rank result-bearing sources:
`esdat (3) > als_enmrg (2) > als_xtab (1) > <anything else> (0)`; rank is a
property of the *adapter id*, looked up from a pinned internal table —
`acirl_field_xlsx` results are field data, not a lab rendering, and are
**always kept** (rank exempt). Only the top-ranked lab rendering's `results`
survive; every dropped file gets state `ignored`, reason
`superseded_by_better_source`, and its hash recorded in the event as
provenance (**not** deleted from `ingest_file`; it is still archived with
the event at commit — A13, plan 09). `samples` rows from **all**
sources merge (they're metadata, not duplicates). Criteria:
- event with ESdat Chemistry2e + XTAB: XTAB results dropped, its file
  `ignored/superseded_by_better_source`, ESdat results kept;
- event with only XTAB: XTAB kept;
- ACIRL field results survive alongside ESdat lab results in the same event;
- equal-rank duplicate renderings (two XTABs, same work order, different
  hashes): keep the higher `revision`; same revision → keep either, log a
  warning with both hashes (content-identical by construction).

## R-7.3 Sample-metadata join

Merge `samples` onto `results` by `lab_sample_id` (exact); rows without
`lab_sample_id` fall back to (`feature_raw` after squish/case-fold, date part
of `sample_datetime_raw`). Fills: `sample_datetime_raw` (only if result row's
is NA), `sampler`, `matrix_raw`, `parent_sample`, and **`sample_type`
(authoritative from Sample2e** — overrides the adapter's `"unknown"`).
Conflicting non-NA values (result row says X, sample row says Y):
sample-metadata wins for `sample_type`; for `sample_datetime_raw` a
disagreement in the *date part* marks the row `needs_review` payload
`kind = "value_conflict"`, subkind `sample_datetime_mismatch`. Criteria:
- ESdat fixture event: every result row gains its Sample2e datetime and
  sample_type; the `"unknown"`s are gone;
- fallback join (crosstab results + ACIRL samples, no lab_sample_id) matches
  on feature+date;
- an engineered datetime mismatch produces exactly one review payload and
  does not block the rest of the event.

**Added at PLAN-15 Phase 8b.** The rule above ("sample-metadata wins for
`sample_type`") settles a result row disagreeing with its sample row. It never
covered *two matched sample rows disagreeing with each other*, and that case
silently resolved by arrival order — deciding whether a row committed or was
dropped by the QC filter, since LAB_D rows are filtered and Normal rows are
not. Such a disagreement is now flagged for review (`value_conflict` /
`sample_type_mismatch`) under either row order, matching what the
`sample_datetime_raw` check two lines above it already did. Criterion:
- a `sample_type` disagreement among matched sample rows is flagged for review
  regardless of the order the rows arrive in.

## R-7.3a Event with results but neither sample metadata nor `feature_raw`

Declared retrospectively at PLAN-15 Phase-9 sign-off. The behaviour and its
test both predate this heading — `test-assemble.R` has covered it throughout
— but no plan declared the ID, so the criterion lint reported it as UNKNOWN
("declared by no plan") while the coverage lint could not credit it. Writing
it down is the whole fix; no behaviour changes.

An event carrying result rows but no sample-metadata source *and* no
`feature_raw` has no way to name its sampling point. It warns, naming the work
order so the operator can find the file, rather than failing silently or
aborting the batch. An event with either source of a point name does not warn.
Criteria:
- results with no sample metadata and no `feature_raw` warn, and the warning
  names the work order;
- an event with either source of a point name produces no such warning.

## R-7.4 Multi-work-order ESdat partitioning

An ESdat file whose results span several work orders (QC context; DESIGN
§2.2) contributes rows to **its filename-stem work order's event only**;
rows for other work orders with `sample_type = "NCP"` are counted in the
event report (`n_ncp_foreign`) and go no further; non-NCP rows for a
*different* work order (unexpected) → event-level warning + those rows to
review (`kind = "other"`, subkind `foreign_work_order`). This partition runs
on the RAW per-file parser output, before the R-7.3 sample-metadata join, so
the `sample_type = "NCP"` it keys on must already be present on that output.
For ESdat Chemistry2e (no `Sample_Type` column) that marker is now set at
parse time from the compound `<orig>001_<home>` SampleCode (PLAN-04 R-4.6),
so the NCP-drop path is genuinely reachable for real ESdat deliveries — before
R-4.6, every Chemistry2e row reached this partition as `"unknown"` and NCP
cross-references leaked into review as `foreign_work_order`. Criteria: plan-04
two-work-order fixture: event for `XX1234567` contains only its rows; the
NCP row is counted, absent from results, and not in review; an engineered
non-NCP foreign row lands in review. Seam-tested end-to-end (real ESdat parser
→ `assemble_events()`) in `test-assemble.R` so the parser/partition contract
can't silently drift.

## R-7.5 Event object (pinned shape)

```r
event <- list(
  work_order = chr, orphan = lgl,
  results = <ir_results + joined sample cols>,
  samples = <ir_samples merged/deduped>,
  files   = tibble(hash, filename, adapter, rank, kept = lgl),
  report  = list(n_results, n_by_sample_type, n_ncp_foreign,
                 skipped = tibble(hash, source_ref, reason), warnings = chr))
```

`assemble_events(parsed)` returns `list(events = …, states = tibble(hash,
state, reason))`. Criterion: shape validated by a helper
`expect_valid_event()` used by every test above; states tibble covers every
input hash exactly once.
