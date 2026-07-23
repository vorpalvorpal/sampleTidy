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

The string is `(site, point)`; the dot is just a separator. The registry has exactly
**4 sites**: B (452 points), K (396), L (34), BH (12). Every feature name is
`SITE.POINT`; no name has 2+ delimiters; `BH` must win longest-prefix over `B`.

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
- Known-site set: derive from `feature.name` prefixes (B, K, L, BH) — maintained
  list, longest-match first (BH before B). Boundary = dot / space / direct.
- Point normalisation within the matched site: uppercase; zero-pad numeric runs
  (`S1`→`S01`) — applied ONLY to compare against existing (site, point) features.
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
- **B. Layer-2 structural (site, point) resolver.** New site-registry helper +
  parser. Tests: `B S01`/`BS01` → B.S01 (formatting variants absorbed WITHOUT an
  explicit alias); unknown site → review; non-existent point in site → review, not
  fabricated; BH beats B (longest match).
  **Site set comes from the `feature.site` COLUMN, not a name-prefix parse** — the
  column is authoritative and already populated (supersedes the "derive from
  `feature.name` prefixes" wording in Layer 2 above).
- **C. Layer-3 WO single-site disambiguation.** Tests: all-BH-resolved WO + novel
  irregular code → assumes BH (exact hit → resolve + provenance; no hit → suggest);
  MIXED-site WO → heuristic does NOT fire; curated BS1 inside an all-B WO still →
  BH.S01 (curation wins over WO context).

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

## Verification
- Re-run the input/ dry-run (scratchpad/input_dryrun2.R) after each phase; track the
  `unknown_feature` count down and confirm ZERO cross-site mis-merges (assert BS1/BS3
  still resolve to BH.*). Full `testthat` suite green throughout.

## OUT OF SCOPE (separate follow-ups, noted for the record)
- `unknown_analyte` ×14 = all "Sodium Adsorption Ratio" (computed ratio not in the
  analyte registry) — a registry-gap decision, not name resolution.
- `feature_raw = NA` × 3449 rows / 16 ESdat events — results with no point name after
  the Sample2e join (missing/unmatched sample metadata) — needs its own source trace.
