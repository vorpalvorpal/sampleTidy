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
- **C. Layer-3 WO single-site disambiguation.** Tests: all-BH-resolved WO + novel
  irregular code → assumes BH (exact hit → resolve + provenance; no hit → suggest);
  MIXED-site WO → heuristic does NOT fire; curated BS1 inside an all-B WO still →
  BH.S01 (curation wins over WO context).
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
