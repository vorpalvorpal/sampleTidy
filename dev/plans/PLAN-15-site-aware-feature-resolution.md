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
- Layer 2 runs **only when the key reaches ZERO `feature_alias` rows**. Any key
  reaching ≥1 alias row counts as ALIASED and is left to Layer 1 / review, regardless
  of `auto_assign`, regardless of whether the alias is dangling.
- **The gate is `.rc_alias_rows_exist(key, registry)`** — TRUE if ANY `feature_alias`
  row carries that `alias_key`, ignoring `uuid_feature`, `auto_assign` and (per E.2)
  date bounds. An earlier draft operationalised it as "`.rc_feature_suggestions()`
  returns no candidates"; that is WRONG, because that function excludes dangling rows
  (`!is.na(fa$uuid_feature)`, reconcile.R:197) and so contradicts this bullet's own
  "regardless of whether the alias is dangling". See E.3.
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
- `feature_alias` gains `date_start DATE` and `date_end DATE`, both NULLABLE.
  **DATE, not TIMESTAMP** — `feature.date_start`/`date_end` are DATE (verified,
  `DESCRIBE feature`), and a TIMESTAMP column would reintroduce the tz hazard E.5
  documents. All bound comparisons happen at DATE granularity; never convert a bound
  through POSIXct.
- NULL means unbounded on that side. `date_start IS NULL AND date_end IS NULL` is the
  default and preserves exactly today's behaviour.
- Backfill: all existing rows get NULL/NULL, then the curated bounds in E.5 are
  applied as an explicit, itemised UPDATE list (auditable, each with a `change_log`
  provenance row).
- These are **distinct from the existing `first_seen` / `last_seen` columns**, which
  record when ingest last *observed* the string. `date_start`/`date_end` record when
  the alias is *valid*. Do not conflate them; do not derive one from the other.
- **Use plain `ALTER TABLE feature_alias ADD COLUMN` — do NOT rebuild the table.**
  Reproduced on a copy of the post-001 registry (duckdb v1.4.1): `DROP TABLE
  feature_alias` is REFUSED (`Catalog Error: Could not drop the table because this
  table is main key table of the table "sample"`), so the TEMP-copy rebuild pattern is
  not merely unnecessary here, it is impossible without cascading into `sample` and
  `analysis`. Both `ADD COLUMN`s succeed on the same file, survive reconnect, read
  back NULL on all 1989 rows, and leave the `sample → feature_alias` FK intact
  (15113-row join verified). 001 itself uses plain `ADD COLUMN` for additive columns
  (001:480-481); the FK-catalog defect it documents (001:409-423) is specific to
  `CREATE … REFERENCES; DROP; ALTER RENAME`, which 003 must not do.
- **Fixture DDL.** `feature_alias` DDL exists in exactly two places: 001:368-381 and
  `tests/testthat/helper-db.R:59-79`. The helper must gain both columns in the same
  change, or no E test can run at all.
- **Pre-003 databases.** The registry load is `SELECT * FROM feature_alias`
  (reconcile.R:28), so against an un-migrated DB `fa$date_start` is `NULL`, not a
  column of NAs. PINNED: the resolver treats absent columns as all-NULL (unbounded),
  i.e. exactly today's behaviour — it must not error. A criterion covers this.

### E.2 Resolution semantics
- An alias is **live at `sample_date`** iff
  `(date_start IS NULL OR date_start <= sample_date)` AND
  `(date_end IS NULL OR date_end >= sample_date)`.
  Both sides compared as DATE. `date_end` is inclusive.
- Alias candidate lookup (`.rc_feature_candidates`, `.rc_feature_suggestions`) filters
  to live aliases before the `auto_assign` filter and before counting candidates.
- **`auto_assign` must be re-settled by migration 003, or E.5 changes nothing.**
  Migration 001 sets `auto_assign = FALSE` on *every* arm of any multi-arm key —
  including the `self` arm. Verified in the live registry: all 17 arms across E.5's 8
  keys are FALSE, and the pattern is systemic (766 multi-arm rows all FALSE, 1226
  single-arm rows all TRUE). `.rc_feature_candidates` filters on `auto_assign`
  (reconcile.R:155) *before* anything else, so a date bound alone still yields zero
  candidates and the row still goes pending — E.5 would be inert for 7 of its 8 keys.
  PINNED: **003 flips `auto_assign` to TRUE on exactly the 17 arms listed in E.5, and
  nothing else.** Not a global recompute — the other 749 multi-arm FALSE rows (676
  `mask_long`, 66 `descriptive`) are un-ruled ambiguities that must stay parked.
- With those 17 flipped, ambiguity becomes **date-dependent and is decided by the
  count of LIVE candidates**, which is what the existing caller already does
  (`status <- "pending"` on 0 or >1, reconcile.R:258). Inside a bound the key still
  reaches ≥2 live arms → review, exactly as today; outside it reaches 1 → resolves.
  `auto_assign = FALSE` retains its other meaning, a per-row curator veto.
- This is a filter on the ALIAS, and is separate from the existing `.rc_narrow_live()`
  filter on the FEATURE's `date_end`. **The feature-side liveness must then be applied
  UNCONDITIONALLY**, not via `.rc_narrow_live()`, which only fires when
  `length(unique(cand$uuid_feature)) > 1` (reconcile.R:174). Otherwise the alias-side
  filter can collapse the candidate set to one and thereby *disable* the feature-side
  narrowing, resolving to a defunct feature — reproducible on the shipped `T.REUSED`
  fixture. Same ruling as B.5, same reason.
- **Pending/dangling natural-key lookups are EXEMPT from the date filter.** The
  R-11.5a lookup (reconcile.R:490-497) and `.ct_materialise_feature_aliases`'s
  find-or-create (`WHERE alias_key = ? AND uuid_feature IS NULL`, commit.R:126-130)
  must ignore bounds entirely. If a bound hides an existing dangling alias, commit
  creates a *second* one for the same key, `.rc_find_existing` (reconcile.R:724-731)
  stops matching the committed sample, and **the same measurement commits twice** —
  the exact hazard B.4 exists to prevent.
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
- NOTE this is a rare path, not the common one — but the reason originally given here
  was wrong and is corrected: a key that is also a feature's own name does retain its
  unbounded `self` alias (894/894 features have one), but that arm is *also*
  `auto_assign = FALSE` under 001, so it does not resolve anything on its own. It is
  the E.2 `auto_assign` flip that makes the surviving arm resolve. The expired-only
  case arises for a key with no self alias, or one whose every arm is bounded.
- **`self`-alias universality is a checked precondition, not an invariant.** True today
  (894/894), but no package code ever creates a self alias — only migration 001:383-395
  does, and the sole package reference is a read (commit.R:304). A feature added later
  via `add_feature()` has none. Migration 003 asserts it and aborts if violated.
- Robin will notice and initiate any review of a recurring closed-off mislabelling
  manually; the system is NOT required to detect or alert on that. This ruling is
  about not auto-resolving, not about raising an alarm.
- So B.4's gate reads in full: Layer 2 runs only when the key reaches **no
  `feature_alias` row at all**, live, expired, or dangling.
- **The gate needs its own predicate — `.rc_feature_suggestions()` cannot serve.**
  B.4 currently operationalises the gate as "`.rc_feature_suggestions()` returns no
  candidates", but that function excludes dangling rows (`!is.na(fa$uuid_feature)`,
  reconcile.R:197), so it already contradicts B.4's own "regardless of whether the
  alias is dangling" — a pre-existing defect in B.4, independent of E. Under E.2 it
  would also drop expired rows, making an expired-only key read as "no alias rows" and
  fall through to Layer 2, precisely what this section forbids. PINNED: introduce
  `.rc_alias_rows_exist(key, registry)` = TRUE if ANY `feature_alias` row carries that
  `alias_key`, ignoring `uuid_feature`, `auto_assign` and dates. B.4's gate and E.3's
  gate both use it. Amend B.4 accordingly.
- **Review payload grammar.** `subkind=expired_alias,expired=<uuid_feature>@<start>..<end>`
  (pipe-separated for several). Two fixes to the current code are required: the payload
  emits a `subkind` only when `length(sugg) > 1` (reconcile.R:264, 303-306), so a
  *single* expired candidate yields a bare payload today — expired candidates must emit
  even when there is exactly one; and `.rc_feature_suggestions` returns only distinct
  `uuid_feature` (reconcile.R:201), so the bounds must be carried alongside.
  **Precedence, pinned:** if a key has ≥2 live candidates *and* ≥1 expired one, the
  payload is `subkind=ambiguous` with the expired ones listed in an `expired=` clause.
  Ambiguity is the actionable fact; expiry is context.

### E.4 New-alias creation
- Every newly-created alias (the pending/dangling alias `commit` materialises in
  `.ct_materialise_feature_aliases`) sets `date_start` = **`min(sample_date)` over the
  group of rows sharing that `alias_key`**; `date_end` stays NULL. NOT `rows_k[[1]]`,
  which is first-in-file-order (commit.R:115-118): two files of one event in a
  different order would otherwise yield a different, permanent `date_start`.
- **The existing-dangling branch (commit.R:131-139) must NOT touch `date_start`.** It
  updates only `n_seen`/`last_seen` today; re-ingest must not mutate an existing bound.
- Rationale: a newly-sighted variant is valid from when it was first seen, not
  retroactively. This must not disturb the R-11.8 pending-alias behaviour otherwise.
- **Consequence, acknowledged: backfill of data older than `date_start` goes to
  review** and has no automatic escape (E.3 forbids falling through to Layer 2). This
  is accepted — an operator clears it by widening the bound via
  `confirm_feature_aliases()`. Flagged because it is a genuine new failure mode, not a
  theoretical one: any historical re-load hits it.
- `confirm_feature_aliases()` must be able to set and clear both bounds. Its current
  signature is `(uuid_alias, uuid_feature, confirmed_by, override, db)` with
  `uuid_feature` mandatory and NA explicitly rejected (feature-alias.R:37-38, 82-87),
  so there is today no way to set a bound without re-confirming a target, and NA is
  already taken as "reject" — it cannot double as "clear". PINNED: add `date_start` /
  `date_end` arguments with an explicit clear sentinel distinct from "leave alone",
  and allow a bounds-only call in which `uuid_feature` is omitted. A criterion covers
  set, clear, and leave-alone.

### E.5 The curated bounds (data, applied by migration 003)
Robin's rulings on the 9 collision-class rows. **Rule 1** = one-off mislabelling
(`n_seen == 1` or the target has exactly 1 sample) → close it at the sample date.
**Rule 2** = a recurring issue Robin wants to review every time → leave open.
**Rule 3** = the same-named point is decommissioned → close at the last sample date.

ALL NINE ARE SETTLED (Robin, 2026-07-23). `date_end` is inclusive; `date_start` stays
NULL on every row. These are DATA, not derivable — an implementer must use exactly
these literals and must not recompute them.

**The literals below are SYDNEY-LOCAL calendar dates, corrected +1 day from the first
draft.** `sample.date` in the legacy registry stores Sydney midnight as a UTC-naive
TIMESTAMP: every non-NULL value is 13:00 (7116 rows) or 14:00 (7995 rows), and the
split tracks DST exactly (13:00 Oct–Mar = AEDT/UTC+11, 14:00 Apr–Sep = AEST/UTC+10,
with April splitting 6/1064 across the changeover). So the stored *date part* is one
day BEFORE the true local sampling date, and the first draft — derived with
`as.Date(<POSIXct>, tz = "UTC")` in `scratchpad/alias_window_report.R:23` — took that
UTC date part. Reconcile compares against `as.Date(parsed_dt, tz = "Australia/Sydney")`
(reconcile.R:233), i.e. the local date, so every uncorrected literal would have
excluded the very sample it was derived from. Robin's rulings are unchanged; only the
arithmetic is fixed. (Note `commit.R:369` writes NEW samples as local-date-at-00:00-UTC
— a different convention from the legacy rows. Out of scope here, but recorded.)

| alias_key | resolves_to | rule | `date_end` (local) | stored | basis |
|---|---|---|---|---|---|
| `b.s01` | B.TS41 | 1 | **2026-01-21** | 2026-01-20 13:00 | exact — target's only sample |
| `b.ts02` | B.TS27 | 1 | **2021-11-12** | 2021-11-11 13:00 | exact — target's only sample |
| `b.ts41` | B.TMW15 | 1 | **2024-04-08** | 2024-04-07 14:00 | exact — target's only sample |
| `b.s22` | B.S06 | 2 | **NULL** (stays open) | — | recurring; Robin reviews every time |
| `b.s04` | B.S01 | 1 | **2026-03-16** | 2026-03-15 13:00 | proxy — target's last sample |
| `b.s22` | B.TS18 | 1 | **2021-11-12** | 2021-11-11 13:00 | proxy — target's last sample |
| `k.e02` | K.S06 | 1 | **2025-09-04** | 2025-09-03 14:00 | proxy — target's last sample |
| `b.ts18` | B.S30 | 3 | **2021-11-12** | 2021-11-11 13:00 | earlier of the two (B.TS18's last) |
| `b.ts40` | B.TS39 | 3 | **2024-04-08** | 2024-04-07 14:00 | earlier of the two (B.TS40's last) |

**Row identity for the UPDATEs.** Alias uuids are generated per-DB by migration 001, so
the plan cannot cite them, and a key-only `WHERE alias_key = 'b.s22'` would hit **three**
rows (self→B.S22, →B.S06, →B.TS18). PINNED: identity is the pair
**(`alias_key`, target `feature.name`)**, and each of the 9 items must assert it matched
**exactly one** row, aborting the migration otherwise.

**The `auto_assign` flip (E.2), itemised.** 003 sets `auto_assign = TRUE` on exactly
these 17 rows and no others — the full arm set of the 8 keys above, self arms included:
`b.s01`→{B.S01, B.TS41}; `b.s04`→{B.S01, B.S04}; `b.s22`→{B.S06, B.S22, B.TS18};
`b.ts02`→{B.TS02, B.TS27}; `b.ts18`→{B.S30, B.TS18}; `b.ts40`→{B.TS39, B.TS40};
`b.ts41`→{B.TMW15, B.TS41}; `k.e02`→{K.E02, K.S06}.

**On the 3 proxies.** Per-alias usage is unrecoverable — migration 001 repoints every
sample to its *self* alias and the raw string was never retained on `sample` — so for
`n_seen == 1` against a many-sampled target we know the mislabelling happened once but
not *when*. Robin's ruling: use the target's last sample date. This is deliberately
conservative (the alias stays live across the target's whole history) and can be
tightened later if a specific incident date surfaces.

**On the 2 rule-3 rows.** Both were flagged as looking like **renames** rather than
mislabellings, and Robin ruled: use the earlier date. The two do NOT behave alike, and
an earlier draft of this paragraph claimed they did — corrected here:
- `b.ts18`→B.S30 **does go inert**. B.TS18's samples stop 2021-11-12 and B.S30's start
  2022-03-02 (local), no overlap, so the bound predates every B.S30 sample and the arm
  can never match one. From any real date the key reaches one live arm, self→B.TS18,
  and resolves there. The alias is effectively retired. A test must assert exactly
  that, not the (impossible) target match.
- `b.ts40`→B.TS39 **does not**. B.TS39's samples run 2022-09-27..2025-05-29 (local), so
  the 2024-04-08 bound sits *inside* that range — the two points overlap, unlike the
  B.TS18/B.S30 pair. The arm therefore stays live for B.TS39 samples up to 2024-04-08:
  the key remains ambiguous (2 live arms → review) on or before that date, and resolves
  to B.TS40 after it.
  **RE-CONFIRMED on the corrected facts (Robin, 2026-07-23): keep 2024-04-08.** Robin's
  ruling: the exact date is not settled and is not worth settling now — *the requirement
  is that the alias is marked finished*. So the literal is DEFERRED-PROVISIONAL: it is
  correct for the retirement requirement (no `b.ts40` sample after 2024-04-08 will ever
  reach B.TS39 again) and merely unverified for backfill before it. An implementer still
  uses exactly this literal. **The test asserts retirement — `b.ts40` at a post-bound
  date resolves to B.TS40 — and must NOT encode the pre-bound ambiguity as a
  requirement**, since that half of the behaviour may yet be re-cut. If a specific
  B.TS40→B.TS39 changeover date later surfaces, only this literal changes; no test or
  code should need to move with it.

### E.6 Acceptance criteria (each must be able to FAIL)
**Ordering: E depends on B.** The E.3 criterion is vacuous until Layer 2 exists, so
Work E lands after Work B, and the E.3 test carries a positive control (below).

- An alias with `date_end` in the past does NOT resolve a later-dated row — paired in
  the same test with the identical row dated *before* the bound, which DOES resolve.
  (Without the pair, a resolver that is simply broken passes.)
- Ditto `date_start`: a row dated before the start does not resolve; one after does.
- **E.2 `auto_assign`:** a bounded two-arm key resolves to its surviving arm outside
  the bound. Concretely, post-003 `b.ts18` at a 2026 date resolves to B.TS18. Without
  the 17-row flip this fails — which is the point; it is the only criterion that
  catches E.5 being inert.
- **E.2 feature-side liveness:** a key with one live alias arm pointing at a *defunct*
  feature goes to review, not to the defunct feature. Build it on the `T.REUSED`
  fixture (fa-0007→f-0006, `date_end 2020-06-30`; fa-0008→f-0007 live) by bounding the
  fa-0008 arm and dating the row 2025 — today that silently resolves to f-0006.
- **E.2 pending exemption:** a dangling alias whose bounds would exclude the row is
  still found by the natural-key lookup, and re-ingesting the same measurement commits
  it ONCE. Assert the `analysis` row count, not just the absence of an error.
- NULL/NULL alias behaves exactly as today. Not "the suite still passes" — name the
  cases: `T.AMBIG2` ambiguity, `T.REUSED` narrowing, the `bs03alt` hit, plus a direct
  assertion that a NULL/NULL alias resolves at dates far either side of any bound.
- **E.1 pre-003 DB:** the resolver run against a seed WITHOUT the two columns behaves
  exactly as today and does not error.
- E.3: a key whose only alias is expired lands in review with `subkind=expired_alias`
  and does NOT get structurally resolved — asserted against a raw that WOULD parse
  structurally. **Paired positive control in the same test:** an identical raw with NO
  alias row at all DOES structurally resolve, so the test fails if Layer 2 is simply
  disabled rather than correctly gated.
- E.3 payload: a key with exactly ONE expired candidate still emits
  `subkind=expired_alias` (guards the `length(sugg) > 1` gate); a key with 2 live + 1
  expired emits `subkind=ambiguous` with an `expired=` clause.
- A newly-created pending alias has `date_start` = `min(sample_date)` over its group —
  asserted with the group presented in BOTH file orders, yielding the same value — and
  `date_end` NULL. Re-ingesting does not change it.
- `confirm_feature_aliases()`: set both bounds, clear a bound, and leave a bound
  untouched are three distinguishable outcomes; a bounds-only call needs no
  `uuid_feature`.
- Migration 003 on a pre-003 seed produces **8 non-NULL `date_end` values over the 9
  itemised rows** (`b.s22`→B.S06 stays NULL) and leaves all other 1980 aliases
  NULL/NULL; each UPDATE matched exactly one row; `auto_assign` is TRUE on exactly the
  17 listed arms and unchanged elsewhere. Row counts and checksums otherwise unchanged
  — **with a checksum that covers `feature_alias`** over
  `(uuid, alias_key, uuid_feature, kind, auto_assign, n_seen)`. `mig001_counts_checksum()`
  covers feature/sample/analysis/lab_method only (001:57-84) and would not notice 003
  damaging the one table it modifies.
- Migration 003 aborts if any feature lacks a `self` alias (E.3 precondition).
- `sample_date` NA → no narrowing, unchanged behaviour. Pin this as a **unit test on
  `.rc_feature_candidates(feature_raw, NA, registry)`**: `.rc_parse_dates`
  (reconcile.R:615-640) drops unparseable rows before commit, so an end-to-end test of
  this criterion passes regardless of the implementation.

## Work F — Work A remediation (from the Phase-5 cold audit, 2026-07-23)

Work A shipped without a TDD audit. The audit confirmed its central claim empirically —
`.rc_feature_key` reproduces `.mig001_normalize` on **1989/1989** stored `alias_key`s,
and every mixed-key mutation was killed by existing tests — but found that adopting
`tolower(trimws())` silently dropped two hygiene properties `.rc_key` had. **Two
mutations survived the entire suite**, which is the six-times-repeated failure mode.

### F.1 Punctuation-only raw is no longer held (BLOCKING — data corruption)
`.rc_feature_key` guards `is.na(x) | k == ""` (reconcile.R:67) but not "no alphanumeric
character". `feature_raw = "."` or `"-"` therefore yields key `"."`, survives the A44
guard, and `commit_event()` materialises `feature_alias(alias_key = '.', kind =
'pending')` plus a sample against it. Under `.rc_key` these were held. Reproduced.
**Fix:** extend the guard to `!grepl("[[:alnum:]]", k)` → NA. **Test:** a `"."` raw is
held, and NO alias/sample row is written — assert the row counts, not just the status.

### F.2 Non-ASCII whitespace survives the trim (BLOCKING — duplicate samples)
`trimws()` does not strip NBSP (` `), `\v` or `\f`. `.rc_feature_key("T.S01 ")`
= `"t.s01 "`, which does not match `t.s01`, so commit creates a second alias **and a
second sample for a point that already exists**. A plain ASCII trailing space resolves
fine, so the failure is spelling-dependent and silent. Zero incidence in the 265-file
dry run (all 43 residual raws are clean ASCII) — latent, not active. **Fix:** Unicode-aware
trim plus `normalise_lab_text()`, matching what `.rc_key` already did. **Test:** the NBSP
variant resolves to the SAME feature as the clean string, with no new alias row.

### F.3 The migration-parity oracle is a tautology (BLOCKING — false-green gate)
`test-reconcile.R:848` re-declares `mig_normalize <- function(x) tolower(trimws(x))`
locally and compares `.rc_feature_key` against it — so it asserts a function equals its
own copy. Proof: mutating `.rc_feature_key` to `tolower(str_squish(x))`, a genuine
divergence from the migration, **survives the whole suite**. **Fix:** `sys.source` the
real `.mig001_normalize` from `dev/migrations/001-alias-indirection.R` (the pattern
already exists at `test-migration-001.R:42`) and add discriminating inputs: `"B.  S01"`,
`" B.S01"`, `"B.S01\t"`.

### F.4 The collision oracle is a tautology (SHOULD-FIX — false-green gate)
`test-reconcile.R:853-860` asserts only that `.rc_feature_key(c("BS1","B.S1"))` has two
distinct values — a restatement of the function definition. The real hazard is at
RESOLUTION level: `bs1` is a curated `auto_assign=TRUE` alias for BH.S01 and no `bs01`
alias exists, so a naive longest-match on `BS01` lands in the opposite catchment.
**Fix:** this is fixture F2, which Work B's suite now adds (`TS1`→`TH.S01`); assert
`.rc_feature_candidates` returns *different features* for the two strings.

### F.5 Review payload is order-dependent (SHOULD-FIX)
`.rc_feature_review` reads `cand_list[[g[[1]]]]` (reconcile.R:298) — the first row of the
group. Two rows sharing a key with different sample dates give `candidates=f-0006|f-0007`
old-first, and **no candidates at all** new-first. Reproduced. **Fix:** take the union of
`cand_list[g]`.

### F.6 Single-candidate suggestions are discarded — RULING REQUIRED, now made
`if (length(sugg) > 1)` (reconcile.R:264) drops a lone `auto_assign=FALSE` candidate, so
fixture `T.BORE` yields suggestion `f-0003` but an empty payload — the "suggestion
mechanism inert" failure the Cross-cutting section exists to fix. Mutating `>1` to `>=1`
**survives the entire suite**. **PINNED:** emit the single candidate as
`subkind=suggestion` (distinct from `subkind=ambiguous`, which requires ≥2 — one
candidate is not an ambiguity). This composes with E.3's `subkind=expired_alias`, which
likewise must emit at count 1. One test per branch: 0 → bare, 1 → `suggestion`,
≥2 → `ambiguous`.

### F.7 Documentation drift (MINOR, but a trap for the Work B implementer)
- reconcile.R:470 says the pending lookup keys on `.rc_key(feature_raw)`; it keys on
  `rows$alias_key` (= `.rc_feature_key`). This is the exact comment a B.4 implementer
  reads.
- reconcile.R:60 roxygen claims the guard covers "blank/whitespace-only" — true only for
  ASCII whitespace, and silent on punctuation-only (F.1).
- **Three** feature keys now coexist: `.rc_feature_key` (alias/grouping),
  `.rc_key` (lab-method + analyte), and `.st_normalise_key` = `tolower(str_squish())`
  (assemble.R:74, joining samples↔results). Assemble therefore treats `"T  S01"` and
  `"T S01"` as one sample while reconcile keys them apart. Not necessarily wrong;
  undocumented and untested. Add a comment naming all three and their scopes.

### F.8 Pre-Work-A pending aliases have no upgrade path (NOTE — not currently triggerable)
A DB committed under the old key holds `alias_key = 'bs01'` where reconcile now computes
`'b.s01'`; the lookup misses, a new alias is created, and `.rc_find_existing` then
double-commits. **Verified not reachable today: both the post-001 snapshot and the
dry-run DB hold ZERO dangling aliases.** Record the precondition — "no pending aliases
exist" — and re-check it before any live commit, or write a migration.

## Registry data changes pending the live cutover

**The authoritative DB is not yet on the package schema.** `/Users/rjs/OneDrive - Blue
Mountains City Council/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb`
has `analysis, analyte, analyte_mask, asset, feature, feature_mask, guideline,
lab_invoice, lab_method, project, sample` and **lacks `change_log`, `feature_alias`,
`ingest_file`, `review_queue`**. So `add_feature()` and every other mutation-layer call
would fail against it (they write `change_log`), and `st_config("live_db")` currently
points at a *different* copy under `~/Library/Application Support/`. Registry changes are
therefore recorded here as pinned data and applied at cutover through the mutation layer,
with provenance — never hand-INSERTed into the authoritative file.

### D.1 New feature B.L05 (Robin, 2026-07-23)
| field | value |
|---|---|
| `name` | `B.L05` |
| `site` | `B` (name prefix must equal site — 894/894 invariant Work B depends on) |
| description | `Leachate tankered to Lawson STP` |
| `lon` | `150.431198` |
| `lat` | `-33.732518` |
| `matrix` | `leachate` |
| `flow` | NULL — not ruled, do not guess |

Coordinates are **WGS84 decimal degrees (EPSG:4326)**, not Web Mercator: Nearmap's
browser reports lat/lon in degrees, Web Mercator is metres in the millions. They are in
the same frame as every existing row (B.L01 = 150.6163/-33.73305) and land beside
`L.centroid` (150.4310/-33.73420), which is the expected Lawson position. Recorded
explicitly because misreading the CRS later would move the point ~thousands of km.

**Why it exists:** `Discharge Point - Lawson STP` is B.L01 leachate tankered to Lawson
STP and sampled at delivery — the same water, a physically distinct sampling location.
Evidence it is NOT B.L01: work order ES2515987 contains `B.L01 (Trade Waste Dam)` and
`Dis Lawson` as two separate samples with two separate ALS sample numbers.

**Historical rows stay on B.L01** (Robin's ruling). B.L05 applies to new data only. Do
NOT write a migration to repoint history.

### D.2 Alias curation, applied after migration 001 creates `feature_alias`
| alias_key | → feature | kind | note |
|---|---|---|---|
| `trade waste dam` | B.L01 | `descriptive` | lab writes `B.L01 (Trade Waste Dam)` in the ES2515987 XTAB — documentary |
| `discharge point - lawson stp` | **B.L05** | `descriptive` | clears the other descriptive residual |

Together these clear all 15 `descriptive` residual items (6 work orders + 9 work orders).
`Dis Lawson` and `T/W Pump` also appear in the corpus and are UNRULED — do not alias them
on a guess.

### D.3 The 16 orphaned Chemistry2e files — RETAIN as assets, do NOT delete (Robin, 2026-07-23)
16 ESdat `Chemistry2e` files have no companion `Sample2e` anywhere in the corpus, so
every one of their 3449 rows carries `feature_raw = NA` and is held at reconcile. They
are leftovers of the older WEM.input system, which left behind files it could not parse.

**Robin's ruling: do not delete them.** Work out each file's work order and register it
in the `asset` table, so the source document is retained as a saved asset rather than
discarded. Queued for the real DB migration — not part of the PLAN-15 code work.

Work orders: ES2413933, ES2417442, ES2422258, ES2515449, ES2515450, ES2515987, ES2516159,
ES2517594, ES2519217, ES2520710, ES2606533, ES2606534, ES2606550, ES2607370, ES2607372,
ES2608966.

PRECONDITION, being verified before anything is retired: that the underlying analytical
results are already present in the authoritative DB by another route. This could NOT be
checked the obvious way — the legacy schema has no `ingest_file` and `sample` carries no
work order — so it is being established by matching date + analyte + value. Expect only
the ~1264 field-sample rows to match; the other 2185 are lab batch QC (`QC-*` SampleCodes)
which is never committed as a sample. **Do not treat a ~63% non-match as data loss.**

## Verification
- Re-run the input/ dry-run (scratchpad/input_dryrun2.R) after each phase; track the
  `unknown_feature` count down and confirm ZERO cross-site mis-merges (assert BS1/BS3
  still resolve to BH.*). Full `testthat` suite green throughout.

## OUT OF SCOPE (separate follow-ups, noted for the record)
- `unknown_analyte` ×14 = all "Sodium Adsorption Ratio" (computed ratio not in the
  analyte registry) — a registry-gap decision, not name resolution.
- `feature_raw = NA` × 3449 rows / 16 ESdat events — results with no point name after
  the Sample2e join (missing/unmatched sample metadata) — needs its own source trace.
