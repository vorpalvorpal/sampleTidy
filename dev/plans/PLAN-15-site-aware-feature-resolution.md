# PLAN-15 — Site-aware feature (sampling-point) resolution

Status: PLANNED (2026-07-23). Post-mandate interactive work, agreed with the user.
Supersedes the reconcile feature-key behaviour probed in the input/ dry-run
(scratchpad/{analyze_review,investigate_names,investigate_alias_key,collision_test,
site_point_meta}.R; migrated dry-run DB /private/tmp/claude-501/qc-dryrun/).

## Problem (evidence-based)

Dry-run of all 265 input files against a migrated copy of the live registry, with
the datetime/mojibake/NCP/QC fixes in place, left **127 review items**, of which
**113 are `unknown_feature`**. These are NOT typos/new points — they are KNOWN
points that fail to resolve because of a **key-normalisation mismatch**:

- migration 001 (`.mig001_normalize = tolower(trimws(x))`) stores alias keys with
  punctuation preserved: `b.s01`, `b.mw02`, `k.e02` (1239/1989 = 62% contain a
  dot/space/hyphen).
- reconcile (`.rc_key = tolower(gsub("[^[:alnum:]]","",normalise_lab_text(x)))`)
  strips punctuation and looks up `bs01`/`bmw02`/`ke02` → matches ZERO dotted keys.

So reconcile cannot resolve ~62% of the alias registry; every such point is flagged
for review on every ingest, and no candidate suggestion is ever attached (0/127).

### Why "just strip in the migration" is WRONG (collision test)

Stripping fuses **genuinely-distinct points that share letters once punctuation is
removed**. On the real registry, stripping introduces 2 false merges:

- `B.S1` (→ B.S01 = "Downstream Cripple Creek", site B, 184 samples since 2002) and
  `BS1` (→ **BH.S01** = "Upstream", site BH, 7 samples 2020-25) both strip to `bs1`.
- `B.S3` (→ B.S03) and `BS3` (→ **BH.S03**) both strip to `bs3`.

`BS1`/`BS3` are curated `historical_code` aliases of the **BH** site (a different
water body), NOT data errors for `B.S01`/`B.S03`. Stripping — or "adding the dot"
(`BS1`→`B.S1`) — would mix two catchments' data. Only **preserving punctuation
exactly** keeps them apart, which is what migration 001 already does.

### The real model (user's reframe, confirmed)

The string is `(site, point)`; the dot is just a separator. The registry currently
holds **4 sites**: B (452 points), K (396), L (34), BH (12) — a measurement, NOT a
constant: the site set is read from `feature.site` at runtime and tests must not
hard-code it. Every feature name is `SITE.POINT` and `name` prefix == `site` for
894 of 894; no *registry* name has 2+ delimiters (an incoming raw may, and must then
go to review); `BH` must win longest-prefix over `B`.

## Design — a layered resolver (replaces the single strip-key lookup)

Resolution order for each incoming `feature_raw`, per row, within an event/WO:

### Layer 1 — exact curated alias (AUTHORITATIVE)
- Key = the migration's punctuation-PRESERVING normaliser (tolower + trim, keep
  punctuation) — NOT the stripping `.rc_key`.
- This is the immediate fix for the 62% failure AND keeps `BS1`≠`B.S1`.
- Ambiguous alias handling (makes suggestions work): when a key reaches >1 distinct
  feature (currently `auto_assign=FALSE`, e.g. `b.s01` → B.S01 AND B.TS41), DO NOT
  drop it silently. Emit ALL candidate features in the review payload
  (`subkind=ambiguous,candidates=...`) so the operator can pick. (Today these are
  filtered out before the candidate stage → blank "unknown" with no help.)

### Layer 2 — structural (site, point) parse (FALLBACK, un-aliased names only)
> **Superseded in detail by "Work B — PINNED SPEC" below.** Where this summary and
> that spec disagree, the spec wins. Corrections it makes: the site set comes from
> the `feature.site` COLUMN (not a name-prefix parse); a DIRECT (empty) boundary
> never auto-resolves; canonicalisation STRIPS leading zeros rather than zero-padding;
> and "un-aliased" means the key reaches ZERO alias rows.

- Known-site set: read `DISTINCT feature.site`, longest-match first (BH before B).
  Boundary = dot / space (a direct, separator-less run is suggestion-only).
- Point normalisation within the matched site: uppercase; drop leading zeros within
  each digit run (`S01`→`S1`) — applied ONLY to compare against existing
  (site, point) features.
- Auto-resolve ONLY on an exact, unique `(site, point)` feature hit. Zero hits or
  >1 → review (carry the structural parse as a suggested candidate). Never fabricate
  a point that doesn't exist in that site.

### Layer 3 — WO single-site disambiguation (the refinement)
- After layers 1-2, compute the set of sites of all RESOLVED rows in the event/WO.
- **iff exactly one site S** across all resolved rows: for each still-unresolved row
  (ambiguous site, or un-parseable), retry the point match ASSUMING site S.
  - Auto-resolve only when `(S, normalised point)` is an exact unique feature match;
    record a `change_log` provenance row (reason `wo_site_inferred`) so it is
    auditable and reversible. Else keep as review with S as the suggested site.
- GUARDS: never override a Layer-1 curated alias (curation wins). Skip entirely when
  the WO is multi-site or has zero resolved rows (the `iff` gate). Bounded downside:
  a genuinely mixed-site WO whose resolved rows happen to be single-site could
  mis-assign a stray row — rare under the gate, reversible via provenance.

## Cross-cutting
- Provenance + reversibility: every non-exact-curated resolution writes `change_log`
  with a reason (`wo_site_inferred` / `structural_parse`) and confidence.
- Review payloads carry candidates for EVERY unresolved/ambiguous row, so the
  suggestion mechanism (currently inert, 0/127) actually helps.
- Do NOT change the global `.rc_key` (shared by method keys + intra-event dedup).
  Introduce a dedicated feature-alias normaliser; leave method/dedup untouched.

## Work breakdown (one body of work, TDD; tests before impl per phase)

- **A. Layer-1 punctuation-preserving alias key + ambiguous-candidate surfacing.**
  **DONE 2026-07-23 (commit `1d9048d`).** `.rc_feature_key` added (NOT `.rc_key`);
  `.rc_feature_candidates` + `.rc_resolve_features` folded with it; `.rc_feature_suggestions`
  surfaces the all-`auto_assign=FALSE` ambiguous case. Fixture regenerated stripped→dotted.
  Dry-run: unknown_feature 113→43, 12 within-site candidates, zero cross-site merge; suite 2697/0/0.
  Files: R/reconcile.R (`.rc_key` callers for features → new `.rc_feature_key`;
  `.rc_feature_candidates` drop the strip; `.rc_feature_review` emit candidates for
  the auto_assign=FALSE ambiguous case). Tests: dotted keys resolve (B.S01, K.E02,
  BH.MW02A); BS1 stays distinct from B.S1 (NO false merge — the collision oracle);
  ambiguous b.s01 emits 2 candidates; method-key/intra-event-dedup behaviour
  UNCHANGED (blast-radius guard). Gate: dry-run `unknown_feature` collapses to the
  genuine residual.
- **B. Layer-2 structural (site, point) resolver.** Specified in full below.
- **C. Layer-3 WO single-site disambiguation.** Specified in full below.

---

## Work B — Layer-2 structural (site, point) resolver (PINNED SPEC)

Rewritten 2026-07-23 from the cold plan review; every rule below is pinned because a
test writer would otherwise have to guess it. Adjudication record:
`dev/tdd-run/p15-bc-plan-adjudication.md`.

### B.1 Site registry
- Site set = `SELECT DISTINCT site FROM feature` where `site` is non-NULL and
  non-blank. **From the COLUMN, never from a `feature.name` prefix parse** — this
  supersedes the "derive from `feature.name` prefixes (B, K, L, BH) — maintained
  list" wording in the Layer-2 design note above, and the "exactly 4 sites" claim.
- Matching is case-insensitive, **longest `nchar` first** (so `BH` beats `B`).
- Tests MUST NOT hard-code the site count or the specific site letters; they read the
  set from the fixture DB. (Live today: B 452 / K 396 / L 34 / BH 12, and
  `name` prefix == `site` for 894 of 894 — but that is context, not a test constant.)

### B.2 Boundaries and parsing
- Input = `.rc_feature_key(feature_raw)` (the Layer-1 punctuation-preserving key).
- Boundary set = `.` and ` ` (space) **only**. `-` and `_` are NOT boundaries (60 and
  11 live alias keys respectively contain them inside a single token, e.g.
  `mid-swamp`, `b.b_mw11`).
- Split at the **FIRST** boundary only. A residual point part still containing `.` or
  ` ` is NOT parseable → review.
- **A DIRECT (empty) boundary NEVER auto-resolves.** `BS01` yields a review
  suggestion only. This is not a nicety: `bs1` → BH.S01 exists as an
  `auto_assign=TRUE` curated alias while no `bs01` alias exists, so a longest-match
  parse of `BS01` → B + S01 would auto-resolve to **the opposite catchment from
  `BS1`** — the exact cross-site merge this plan exists to prevent. Auto-resolve
  requires a dot or space boundary.
  *(This supersedes the original bullet's `BS01 → B.S01` criterion, which was
  self-contradictory against the collision oracle.)*

### B.3 Point canonicalisation
- Canonical point = **uppercase, then drop leading zeros within each maximal digit
  run**. NOT zero-padding: digit width is not uniform, so no fixed pad works —
  `B.G###` is 3-wide (380 points), `L.G##` 2-wide (25), and `K.G` has **both**
  (`K.G01`..`K.G025` 2-wide, `K.G026`+ 3-wide). Pad-to-2 makes `B.G001`..`B.G380`
  unreachable; pad-to-3 makes `K.G01` unreachable.
- Worked set the tests MUST pin: `S1`→`S1`, `S01`→`S1`, `S001`→`S1`, `MW02A`→`MW2A`,
  `TS41`→`TS41`, `E02`→`E2`, `centroid`→`CENTROID`.
- Registry side: a feature's point = `feature.name` minus its leading `site` and
  exactly one following separator (`feature` has **no `point` column**). A feature
  whose name prefix ≠ its `site` is EXCLUDED from the structural index.
- **Invariant test:** canonical `(site, point)` is injective over the whole feature
  table. Verified true today (894 distinct keys over 894 features, 0 collisions; K.G
  alone 360/360). A future `K.G001` alongside `K.G01` would break it, and the test
  must fail loudly if so.

### B.4 When Layer 2 runs (gating)
- Layer 2 runs **only when the key reaches ZERO `feature_alias` rows** — i.e. when
  `.rc_feature_suggestions()` returns no candidates. Any key reaching ≥1 alias row
  counts as ALIASED and is left to Layer 1 / review, regardless of `auto_assign`,
  regardless of whether the alias is dangling.
- This is load-bearing, not conservatism: `b.s01` reaches two `auto_assign=FALSE`
  rows (B.S01 + B.TS41). Layer 1 drops it, and a structural parse of `B.S01` IS a
  unique hit — so without this gate Layer 2 would silently auto-resolve exactly the
  curated ambiguity that §"Scope basis" parks pending a user ruling.
- **Existing dangling alias ⇒ never auto-resolve.** When a dangling `feature_alias`
  row exists for the row's `alias_key`, Layers 2 and 3 attach the structural hit as a
  SUGGESTION on that pending alias and stop. Otherwise idempotency breaks: today such
  a row is `feature_pending`, `.rc_resolve_existing_pending()` (reconcile.R:490-497)
  fills its alias, and re-ingest matches on `s.uuid_feature_alias`
  (`.rc_find_existing`, reconcile.R:724-731). Resolving it flips `feature_pending` to
  FALSE, which switches that lookup to `fa.uuid_feature` — which cannot see the
  already-committed sample, because that sample's alias has `uuid_feature IS NULL`.
  **The same measurement would commit twice.** Promotion stays with
  `confirm_feature_aliases()`, which already re-points and merges collisions.

### B.5 Liveness
- Before accepting a hit, Layer 2 applies an **unconditional** live-at-`sample_date`
  filter (`date_end` NA or `>= sample_date`). If the filter empties the set → review.
- Deliberately NOT a reuse of `.rc_narrow_live()`: that helper only narrows when
  `length(unique(cand$uuid_feature)) > 1` (reconcile.R:173-180), and a structural hit
  is unique by construction, so reusing it would be a no-op and would resolve to a
  defunct feature. Fixture `f-0006 T.S06` (`date_end 2020-06-30`) is the ready-made case.

### B.6 The alias side of a structural hit
A Layer-2 hit yields a `uuid_feature` but no `uuid_feature_alias`, and that gap is
not cosmetic — `sample.uuid_feature_alias` is `NOT NULL`, `.rc_batch_duplicate()`
gates on non-NA `uuid_feature_alias` (reconcile.R:930-933), and `.fa_find_collisions`
keys off the alias.
- **PINNED:** reconcile attaches the target feature's **self-alias** uuid, via a
  read-only lookup (honouring the A32 read-only contract). If the target has no
  self-alias, the row goes to REVIEW — it must never commit with a NA alias.
- Commit does **NOT** materialise a new `kind='structural'` alias. A structural
  resolution is a deterministic, re-derivable rule, not curation; registering it would
  accrete un-curated aliases and (at `auto_assign=FALSE`) churn ambiguity on the next
  ingest. Operators promote a variant via `confirm_feature_aliases()`.
- Consequence to assert: structurally-resolved rows ARE subject to the R-12.13/A-7
  within-batch duplicate guard (two identical `T S01` rows in one batch must not both
  commit).

### B.7 Acceptance criteria (each must be able to FAIL)
The original "unknown site → review" and "non-existent point in site → review, not
fabricated" are **vacuous** — every unresolved raw already emits `unknown_feature` and
creates nothing, so a no-op implementation passes both. Replace with:
- Every negative case is paired with the positive control `T S01 → T.S01` **in the
  same test**, so a disabled resolver fails.
- The review payload must carry a structural suggestion token
  (`subkind=structural,site=…,point=…`). `.rc_feature_review` emits only
  `subkind=ambiguous` today (reconcile.R:299-306), so this cannot pass on current code.
- `count(*) FROM feature` unchanged (nothing fabricated).
- `BS01` must NOT auto-resolve to `T.S01`-equivalent (the B.2 direct-boundary rule),
  asserted against the fixture collision oracle (F2).

---

## Work C — Layer-3 WO single-site disambiguation (PINNED SPEC)

### C.1 What "the event/WO" means
- The site set is computed over **the current event only**, never re-queried from the
  DB. `reconcile_event()` sees one event = all files of a work order *present in this
  batch* (`.st_group_events`, assemble.R:89-110), so a WO split across two runs would
  otherwise resolve the same raw differently per batching — and, via B.4/B.6, commit a
  second sample.
- Layer 3 is **SKIPPED entirely** when `event$orphan` is TRUE or `work_order` is NA
  (`.st_build_event`, assemble.R:238). An orphan event is a bag of unattributed files;
  its "single site" is meaningless.
- The provenance row records the site set used, so a differing later run is diagnosable.

### C.2 Which rows Layer 3 may retry
- Only rows with **no recognised site**, or an ambiguous one.
- **Layer 3 NEVER applies to a row that yielded a recognised site prefix**, even if
  its point missed. Without this guard, `K.S01` (no such feature) inside an all-B WO
  gets re-sited to `B.S01` — a cross-site merge.
- Candidate point = the canonicalised raw with a leading *recognised* site token
  removed if present, else the whole canonicalised raw. A candidate still containing a
  separator is not retried.
- Layer 3 reuses Layer 2's canonical point **unchanged**, substituting only the site.
  It never re-parses the raw and never overrides a Layer-2 auto-resolve.

### C.3 The `iff` gate, operationally
- Resolved = `!is.na(uuid_feature)` after Layers 1-2 (reconcile.R:253-256).
- A resolved feature with NA or blank `site` makes the event **ineligible** (fail closed).
- Curation always wins: a Layer-1 curated alias is never overridden.

### C.4 Provenance
- Reconcile is read-only (reconcile.R:4-6, CONTRACT A32) and **cannot** write
  `change_log`. The resolution reason rides on the clean row; **COMMIT** writes the row
  at step 1b (commit.R:684), mirroring `.fa_merge_samples` (feature-alias.R:200-208):
  `action='provenance'`, `tbl='sample'`, `uuid_row=<sample uuid>`,
  `field='uuid_feature_alias'`, `old=NA`, `new=<alias uuid>`,
  `reason='wo_site_inferred: <raw> -> <feature.name> (sites={B})'`,
  `source_hash=<row hash>`. Same shape for `structural_parse`.
- **Confidence rides on the clean row's existing `confidence` field** (`R/ir.R:17,26`
  declares `confidence = "double"`). `change_log` has NO `confidence` column — do not
  invent one, and do not smuggle it into `reason`.

### C.5 Acceptance criteria (each must be able to FAIL)
The original "MIXED-site WO → heuristic does NOT fire" and "curated BS1 inside an
all-B WO still → BH.S01" are both **vacuous** on today's code, and the second is
self-defeating: `BS1`→BH.S01 makes that event's resolved-site set `{B, BH}`, i.e.
multi-site, so Layer 3 never fires and the test cannot distinguish "curation wins"
from "Layer 3 disabled". Replace with:
- **Positive control on the same fixture:** the identical unresolved raw resolves in
  the single-site event and stays in review in the mixed-site event, asserted across
  two events **in one test**.
- Pin explicitly whether one curated cross-site alias suppresses Layer 3 for the whole
  event. **Ruling: it does** — the site set is computed from resolved rows regardless
  of how they resolved, so a curated `BS1`→BH.S01 inside an otherwise-all-B WO makes
  the event multi-site and disables Layer 3. Fail closed.

---

## Fixture work (`tests/testthat/helper-db.R`) — prerequisite for B and C

- **F1 (BLOCKING).** helper-db.R:232-239 seeds all 7 features with `site='TestSite'`
  while naming them `T.S01…`, violating the live prefix==site invariant. With the site
  set read from the column (B.1) the set is `{"TestSite"}` and **no Work-B test can
  ever produce a structural hit** — every criterion passes vacuously down the review
  path. Fix: set `site` to the name prefix (`'T'`), and add a prefix-extending second
  site — `TH.S01`, `TH.MW02A` with `site='TH'` plus self-aliases — to give the B/BH
  longest-match case. (`test-mutate.R:36/113/234/358` use `'TestSite'` in their own
  inserts / `add_feature()` calls and are unaffected.)
- **F2.** Collision oracle mirroring `bs1`→BH.S01: alias
  `('TS1','ts1','historical_code', auto_assign TRUE)` → `TH.S01`, so B.2's rule
  (`TS01` must NOT auto-resolve to `T.S01`) is falsifiable.
- **F3.** Digit-width pair: `T.G001` (3-wide, mirrors `B.G###`) and `TH.G01` (2-wide,
  mirrors `K.G##`). A pad-to-2 impl fails `T G1 → T.G001`; pad-to-3 fails `TH G1 → TH.G01`.
- **F4.** A point present in one site and absent in the other (keep `T.MW01`, do NOT
  add `TH.MW01`) for Layer-3's "assume S → no hit → suggest"; `TH.MW02A` supplies
  "assume S → exact hit → resolve".
- **F5.** A second work order / project (only `p-0001 'XX1234567'` exists,
  helper-db.R:355-356) plus two event fixtures — single-site and mixed-site — carrying
  the SAME unresolved raw, required for C.5's positive control.
- **F6.** A dangling alias whose key is structurally parseable
  (`('fa-00xx', NULL, 'T S09', 't s09', 'pending')`) with a committed sample, so B.4's
  idempotency rule is testable.
- **F7.** No new row needed for B.5: `f-0006 T.S06` (`date_end 2020-06-30`,
  helper-db.R:238) plus a 2025 raw `T S06` is the ready-made defunct-feature case.

### Scope basis for B and C (reassessed 2026-07-23, post-Work-A)

Work A's dry-run gate was re-measured and the 43 `unknown_feature` residual fully
decomposed (`scratchpad/{analyze_p15,residual_probe,residual_probe2}.R` against
`/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb`):

| Group | Grouped items | Disposition |
|---|---|---|
| `feature_raw = NA` (ESdat Sample2e join gap) | 16 | OUT OF SCOPE (below); largest by rows |
| Ambiguous, candidates now attached | 12 | Working as designed — operator pick |
| Descriptive names, no candidate | 15 | Only 2 distinct strings (below) |

**B and C target ZERO of this residual, and that is expected.** Work A absorbed the
entire un-aliased-code class; no `B S01`/`BS01`-style raw survives in this corpus, and
all 894 features are `SITE.POINT`-coded. The 15 descriptive items are 2 strings only
("Trade Waste Dam" ×6 WOs, "Discharge Point - Lawson STP" ×9 WOs) carrying no site
prefix and no point code — **unreachable by a structural parse or by WO site
inference**, and a curation gap rather than a code gap: the registry already models
this via `feature_alias.kind IN ('descriptive','mask_long')` (~40 rows registered,
e.g. "leachate seep in wall of trade waste dam"); these 2 strings are simply not
among them.

**B and C are therefore justified as CORRECTNESS work against formatting-variant and
site-ambiguity failure modes that HAVE surfaced in past ingestion groups** (user
direction, 2026-07-23), not as a review-queue reduction for the 265-file corpus. A
reviewer must NOT score them against residual-clearing; the acceptance gate is
behavioural (the per-layer tests above) plus the blast-radius guard that the dry-run
residual does not REGRESS (57 review items / 43 `unknown_feature` / zero cross-site
mis-merge).

**Parked, not in B/C scope:** the 12 ambiguous items are both `self` vs
`historical_code` collisions with lopsided evidence (`b.s01`: self→B.S01 n_seen=130
vs historical_code→B.TS41 n_seen=2; `k.e02`: self→K.E02 n_seen=20 vs
historical_code→K.S06 n_seen=1). A `self` > `historical_code` precedence rule would
clear both, but that is a curation-semantics decision (it cuts against the standing
"old ≠ misspelling" rule) and is deferred pending a user ruling.
- **D. Provenance/confidence + review-candidate plumbing** (folded into A-C).
- **E. Time-bounded aliases** (`feature_alias.date_start` / `date_end`) — specified below.

---

## Work E — time-bounded aliases (PINNED SPEC)

Added 2026-07-23 on Robin's direction. *(Labelled E, not D: a "Part D" already exists
above as the provenance/plumbing item folded into A-C. Robin's "part D" request refers
to this work; the letter is the only difference.)*

### E.0 Why
Some aliases are ongoing; others record a **particular historical anomaly** and must
apply only within the period that anomaly was live. Today an alias is unconditional,
so a one-off mislabelling from 2021 keeps hijacking a string forever. Evidence: 9
alias rows in the live registry have a key that IS another feature's real name (see
`scratchpad/alias_window_report.txt`); today every one of them is permanently
ambiguous.

### E.1 Schema (migration `003-alias-date-bounds.R`)
- `feature_alias` gains `date_start TIMESTAMP` and `date_end TIMESTAMP`, both
  NULLABLE, mirroring the shape `feature` already uses.
- NULL means unbounded on that side. `date_start IS NULL AND date_end IS NULL` is the
  default and preserves exactly today's behaviour.
- Backfill: all existing rows get NULL/NULL, then the curated bounds in E.5 are
  applied as an explicit, itemised UPDATE list (auditable, each with a `change_log`
  provenance row).
- These are **distinct from the existing `first_seen` / `last_seen` columns**, which
  record when ingest last *observed* the string. `date_start`/`date_end` record when
  the alias is *valid*. Do not conflate them; do not derive one from the other.
- Migration 003 must follow the TEMP-copy rebuild pattern established in 001 — a
  `CREATE … REFERENCES; DROP; ALTER RENAME` sequence corrupts duckdb 1.4.1's
  FK-catalog metadata (reproduced and fixed during PLAN-14; see run-state).

### E.2 Resolution semantics
- An alias is **live at `sample_date`** iff
  `(date_start IS NULL OR date_start <= sample_date)` AND
  `(date_end IS NULL OR date_end >= sample_date)`.
- Alias candidate lookup (`.rc_feature_candidates`, `.rc_feature_suggestions`) filters
  to live aliases before the `auto_assign` filter and before counting candidates.
- This is a filter on the ALIAS, and is separate from and additional to the existing
  `.rc_narrow_live()` filter on the FEATURE's `date_end`. Both apply.
- When `sample_date` is NA, the date filter is skipped (no basis to narrow) and the
  row is treated exactly as today.

### E.3 Interaction with Work B — REQUIRED, do not skip
B.4 gates Layer 2 on "the key reaches ZERO `feature_alias` rows". Under E that
sentence is ambiguous, and the two readings differ materially. **PINNED: a key that
reaches ≥1 alias row which is EXPIRED (or not yet started) at `sample_date`, and no
live one, goes to REVIEW — it does NOT fall through to Layer 2.**
- Rationale: closing an alias is a deliberate curation act. Letting the string then
  fall through to a structural parse would auto-resolve, by a *different* mechanism,
  a mapping a human had just switched off — the bound would be silently defeated
  rather than enforced. Fail closed.
- NOTE this is a rare path, not the common one. A key that is also a feature's own
  name always retains its (unbounded) `self` alias, so closing the *other* alias
  leaves exactly one live candidate and the row resolves cleanly — that is the whole
  point of E.5. The expired-only case arises only for a key with no self alias.
- Robin will notice and initiate any review of a recurring closed-off mislabelling
  manually; the system is NOT required to detect or alert on that. This ruling is
  about not auto-resolving, not about raising an alarm.
- So B.4's gate reads in full: Layer 2 runs only when the key reaches **no
  `feature_alias` row at all**, live, expired, or dangling.
- Review payload for the expired case carries `subkind=expired_alias` plus the expired
  candidates and their bounds — an operator-facing annotation explaining why the row
  was withheld, not a notification mechanism.

### E.4 New-alias creation
- Every newly-created alias (the pending/dangling alias `commit` materialises in
  `.ct_materialise_feature_aliases`) sets `date_start` = the sample date of the row
  that created it; `date_end` stays NULL.
- Rationale: a newly-sighted variant is valid from when it was first seen, not
  retroactively. This must not disturb the R-11.8 pending-alias behaviour otherwise.
- `confirm_feature_aliases()` must be able to set and clear both bounds.

### E.5 The curated bounds (data, applied by migration 003)
Robin's rulings on the 9 collision-class rows. **Rule 1** = one-off mislabelling
(`n_seen == 1` or the target has exactly 1 sample) → close it at the sample date.
**Rule 2** = a recurring issue Robin wants to review every time → leave open.
**Rule 3** = the same-named point is decommissioned → close at the last sample date.

| alias_key | resolves_to | rule | `date_end` | status |
|---|---|---|---|---|
| `b.s01` | B.TS41 | 1 | 2026-01-20 | SETTLED (target has 1 sample) |
| `b.ts02` | B.TS27 | 1 | 2021-11-11 | SETTLED (target has 1 sample) |
| `b.ts41` | B.TMW15 | 1 | 2024-04-07 | SETTLED (target has 1 sample) |
| `b.s22` | B.S06 | 2 | NULL (stays open) | SETTLED |
| `b.s04` | B.S01 | 1 | ⚠ OPEN | target has 184 samples 2002-11-30→2026-03-15; "the sample date" undetermined |
| `b.s22` | B.TS18 | 1 | ⚠ OPEN | target has 6 samples 2020-05-18→2021-11-11 |
| `k.e02` | K.S06 | 1 | ⚠ OPEN | target has 23 samples 2020-08-10→2025-09-03 |
| `b.ts18` | B.S30 | 3 | ⚠ OPEN | whose last sample? B.TS18 ended 2021-11-11; B.S30 ran 2022-03-01→2023-09-12 |
| `b.ts40` | B.TS39 | 3 | ⚠ OPEN | whose last sample? B.TS40 ended 2024-04-07; B.TS39 ran 2022-09-26→2025-05-28 |

**Why 5 are OPEN.** Per-alias usage is unrecoverable: migration 001 repoints every
sample to its *self* alias, and the raw feature string was never retained on `sample`.
So for `n_seen == 1` against a many-sampled target we know the mislabelling happened
once but not *when*. And for rule 3 the two candidate dates belong to different
features. Note `b.ts18`/`b.ts40` look like **renames** rather than mislabellings —
B.TS18's samples stop 2021-11-11 and B.S30's start 2022-03-01, with no overlap — in
which case they need a `date_start` on the alias, not a `date_end`, or the alias can
never match a single target sample.

**These 5 values are the ONLY thing blocked.** E.1-E.4 are date-agnostic and are built
now; migration 003 ships with the 4 settled rows and gains the rest once Robin rules.
An implementer must NOT invent values for the open rows.

### E.6 Acceptance criteria (each must be able to FAIL)
- An alias with `date_end` in the past does NOT resolve a later-dated row — paired in
  the same test with the identical row dated *before* the bound, which DOES resolve.
  (Without the pair, a resolver that is simply broken passes.)
- Ditto `date_start`: a row dated before the start does not resolve; one after does.
- NULL/NULL alias behaves exactly as today (regression guard over the existing suite).
- E.3: a key whose only alias is expired lands in review with `subkind=expired_alias`
  and does NOT get structurally resolved — asserted against a raw that WOULD parse
  structurally, so the test fails if the fall-through is left in.
- A newly-created pending alias has `date_start` = the creating row's sample date and
  `date_end` NULL.
- Migration 003 on a pre-003 seed produces the 4 settled bounds and leaves every other
  alias NULL/NULL; row counts and checksums otherwise unchanged.
- `sample_date` NA → no narrowing, unchanged behaviour.

## Verification
- Re-run the input/ dry-run (scratchpad/input_dryrun2.R) after each phase; track the
  `unknown_feature` count down and confirm ZERO cross-site mis-merges (assert BS1/BS3
  still resolve to BH.*). Full `testthat` suite green throughout.

## OUT OF SCOPE (separate follow-ups, noted for the record)
- `unknown_analyte` ×14 = all "Sodium Adsorption Ratio" (computed ratio not in the
  analyte registry) — a registry-gap decision, not name resolution.
- `feature_raw = NA` × 3449 rows / 16 ESdat events — results with no point name after
  the Sample2e join (missing/unmatched sample metadata) — needs its own source trace.
