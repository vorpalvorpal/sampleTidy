# PLAN-15 — Site-aware feature (sampling-point) resolution

Status: PLANNED (2026-07-23). Post-mandate interactive work, agreed with the user.
Supersedes the reconcile feature-key behaviour probed in the input/ dry-run
(scratchpad/{analyze_review,investigate_names,investigate_alias_key,collision_test,
site_point_meta}.R; migrated dry-run DB /private/tmp/claude-501/qc-dryrun/).

<!-- block: B-15.problem -->
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

<!-- block: B-15.collision-test -->
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

<!-- block: B-15.real-model -->
### The real model (user's reframe, confirmed)

The string is `(site, point)`; the dot is just a separator. The registry currently
holds **4 sites**: B (452 points), K (396), L (34), BH (12) — a measurement, NOT a
constant: the site set is read from `feature.site` at runtime and tests must not
hard-code it. Every feature name is `SITE.POINT` and `name` prefix == `site` for
894 of 894; no *registry* name has 2+ delimiters (an incoming raw may, and must then
go to review); `BH` must win longest-prefix over `B`.

<!-- block: B-15.design -->
## Design — a layered resolver (replaces the single strip-key lookup)

Resolution order for each incoming `feature_raw`, per row, within an event/WO:

<!-- block: B-15.layer1 -->
### Layer 1 — exact curated alias (AUTHORITATIVE)
- Key = the migration's punctuation-PRESERVING normaliser (tolower + trim, keep
  punctuation) — NOT the stripping `.rc_key`.
- This is the immediate fix for the 62% failure AND keeps `BS1`≠`B.S1`.
- Ambiguous alias handling (makes suggestions work): when a key reaches >1 distinct
  feature all of which are `auto_assign=FALSE`, DO NOT drop it silently. Emit ALL
  candidate features in the review payload (`subkind=ambiguous,candidates=...`) so the
  operator can pick. (Today these are filtered out before the candidate stage → blank
  "unknown" with no help.)
  - ~~e.g. `b.s01` → B.S01 AND B.TS41~~ **STRUCK 2026-07-23 (cold audit, finding 1):
    this worked example is DEAD.** `b.s01`→B.S01 and `k.e02`→K.E02 were confirmed
    through `confirm_feature_aliases()` on 2026-07-23 (`kind='transcription_error'`,
    `confirmed_by='R. Shannon'`) and are now `auto_assign = TRUE`, so the real resolver
    returns exactly ONE candidate for each — neither is an ambiguous key any more. The
    rule above is unchanged; only the illustration was falsified. Do NOT re-cite
    `b.s01` or `k.e02` as ambiguity examples; read the live registry for a current one.

<!-- block: B-15.layer2 -->
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

<!-- block: B-15.layer3 -->
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

<!-- block: B-15.crosscutting -->
## Cross-cutting
- Provenance + reversibility: every non-exact-curated resolution writes `change_log`
  with a reason (`wo_site_inferred` / `structural_parse`) and confidence.
- Review payloads carry candidates for EVERY unresolved/ambiguous row, so the
  suggestion mechanism (currently inert, 0/127) actually helps.
- Do NOT change the global `.rc_key` (shared by method keys + intra-event dedup).
  Introduce a dedicated feature-alias normaliser; leave method/dedup untouched.

<!-- block: B-15.seam-table -->
## Seam table (producer → consumer, authored 2026-07-24)

Every producer→consumer boundary this plan crosses, with the fields that must survive
the handoff. A dropped field here is a contract violation prose will not catch; the
shapes below are the ones no criterion names, which is why they are enumerated rather
than left to "think of edge cases".

| id | producer → consumer | fields that must survive |
|---|---|---|
| S-15.1 | `.rc_resolve_features` → Layer-2 structural resolve | `alias_key` (from `.rc_feature_key`, punctuation-preserving), `feature_raw`, `sample_date`, the registry `feature` frame (`name`, `site`, `date_start`, `date_end`). Entry gate is `.rc_alias_rows_exist(key, registry)` **FALSE** — date-blind and `auto_assign`-blind (B.4, E.3) |
| S-15.2 | Layer-2 hit → clean row | `uuid_feature` **and** `uuid_feature_alias`, the latter being the target's `kind='self'` alias uuid found by read-only lookup. `sample.uuid_feature_alias` is NOT NULL and `.rc_batch_duplicate` gates on it, so a hit with no self alias must go to REVIEW, never commit with NA (B.6) |
| S-15.3 | Layers 1–2 → Layer-3 `.rc_wo_site` | the event's resolved-site set, computed from `!is.na(uuid_feature)` **after** layers 1–2 and **regardless of how each row resolved** — one curated cross-site alias makes the event multi-site and disables Layer 3 (C.5, fail closed) |
| S-15.4 | Layer-3 → commit | `confidence` on the existing clean-row field (`R/ir.R:17,26`); reconcile is read-only (A32) so the `change_log` provenance row is written at commit step 1b (`commit.R:684`) |
| S-15.5 | registry load (`reconcile.R:28`, `SELECT *`) → resolver | `date_start` / `date_end` **may be absent columns**, not columns of NA, against a pre-003 DB. The resolver treats absent as all-NULL (unbounded) and must not error (E.1) |
| S-15.6 | `.rc_feature_review` → `review_queue.payload` | `subkind` over the FULL value set `{ambiguous, structural, suggestion, expired_alias, self_precedence_note}` with a **total order** and an explicit **blocking / non-blocking** discriminator. `self_precedence_note` is the first non-blocking kind the feature resolver emits (E.7/R2); a queue reader that cannot tell a note from a blocker will treat a note as work |
| S-15.7 | `.ct_materialise_feature_aliases` → `feature_alias` | `date_start` = `min(sample_date)` over the whole `alias_key` group, **not** `rows_k[[1]]`. The existing-dangling branch (`commit.R:131-139`) updates only `n_seen`/`last_seen` and must NOT touch either bound (E.4) |
| S-15.8 | `add_feature()` → `feature` + `feature_alias` | the `kind='self'` alias in the SAME transaction, with its own `change_log` provenance row. Without it a post-001 feature is unreachable by its own name and 003 has nothing to flip (F.9) |
| S-15.9 | migration 003 → `feature_alias` | plain `ALTER TABLE … ADD COLUMN` only. `DROP TABLE feature_alias` is REFUSED — it is the FK parent of `sample` — so the TEMP-copy rebuild pattern is impossible, not merely unnecessary (E.1) |

### Degenerate shapes every seam above must survive

These are the *shapes*, not the values; each must appear in at least one test.

- **Empty event** — zero rows reach the resolver.
- **Single-row event** — the site set has one member; Layer 3's "single site" must not
  be satisfied vacuously by an event that resolved nothing.
- **Zero-resolved event** — every row unresolved, so the resolved-site set is EMPTY.
  Layer 3 must not fire on an empty set.
- **Mixed-site event** and its pair, the **single-site event carrying the identical
  unresolved raw** (C.5's positive control — both in one test).
- **Work order split across two batches** — `.st_group_events` sees one event per WO
  *present in this batch*, so the same raw must not resolve differently per batching (C.1).
- **`sample_date` is NA** — no narrowing, unchanged behaviour (E.6).
- **`feature_raw` is NA** — the ESdat Sample2e join gap, 16 grouped items live; must not
  reach a structural parse at all.
- **Pre-003 database** — `date_start`/`date_end` columns absent entirely (S-15.5).
- **Feature with no `self` alias** — S-15.2 sends it to review; 003 must not assume one.
- **Contradictory bound** — `date_start > date_end` on one arm; the liveness predicate
  must empty the set rather than resolve arbitrarily.
- **Point present in one site and absent in the other** — fixture F4, the "assume S → no
  hit → suggest" case against `TH.MW02A`'s "assume S → exact hit → resolve".
- **Direct (empty) boundary** — `BS01`, which must NEVER auto-resolve (B.2).

<!-- block: B-15.workbreakdown -->
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

<!-- block: B-15.workB -->
## Work B — Layer-2 structural (site, point) resolver (PINNED SPEC)

Rewritten 2026-07-23 from the cold plan review; every rule below is pinned because a
test writer would otherwise have to guess it. Adjudication record:
`dev/tdd-run/p15-bc-plan-adjudication.md`.

<!-- block: B-15.B1 -->
### B.1 Site registry
- Site set = `SELECT DISTINCT site FROM feature` where `site` is non-NULL and
  non-blank. **From the COLUMN, never from a `feature.name` prefix parse** — this
  supersedes the "derive from `feature.name` prefixes (B, K, L, BH) — maintained
  list" wording in the Layer-2 design note above, and the "exactly 4 sites" claim.
- Matching is case-insensitive, **longest `nchar` first** (so `BH` beats `B`).
- Tests MUST NOT hard-code the site count or the specific site letters; they read the
  set from the fixture DB. (Live today: B 452 / K 396 / L 34 / BH 12, and
  `name` prefix == `site` for 894 of 894 — but that is context, not a test constant.)

<!-- block: B-15.B2 -->
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

<!-- block: B-15.B3 -->
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

<!-- block: B-15.B4 -->
### B.4 When Layer 2 runs (gating)
- Layer 2 runs **only when the key reaches ZERO `feature_alias` rows**. Any key
  reaching ≥1 alias row counts as ALIASED and is left to Layer 1 / review, regardless
  of `auto_assign`, regardless of whether the alias is dangling.
- **The gate is `.rc_alias_rows_exist(key, registry)`** — TRUE if ANY `feature_alias`
  row carries that `alias_key`, ignoring `uuid_feature`, `auto_assign` and (per E.2)
  date bounds. An earlier draft operationalised it as "`.rc_feature_suggestions()`
  returns no candidates"; that is WRONG, because that function excludes dangling rows
  (`!is.na(fa$uuid_feature)`, reconcile.R:213) and so contradicts this bullet's own
  "regardless of whether the alias is dangling". See E.3.
- This is load-bearing, not conservatism: `b.s01` reaches two `auto_assign=FALSE`
  rows (B.S01 + B.TS41). Layer 1 drops it, and a structural parse of `B.S01` IS a
  unique hit — so without this gate Layer 2 would silently auto-resolve exactly the
  curated ambiguity that §"Scope basis" parks pending a user ruling.
- **Existing dangling alias ⇒ never auto-resolve.** When a dangling `feature_alias`
  row exists for the row's `alias_key`, Layers 2 and 3 attach the structural hit as a
  SUGGESTION on that pending alias and stop. Otherwise idempotency breaks: today such
  a row is `feature_pending`, `.rc_resolve_existing_pending()` (reconcile.R:764, body :779-786)
  fills its alias, and re-ingest matches on `s.uuid_feature_alias`
  (`.rc_find_existing`, reconcile.R:1009). Resolving it flips `feature_pending` to
  FALSE, which switches that lookup to `fa.uuid_feature` — which cannot see the
  already-committed sample, because that sample's alias has `uuid_feature IS NULL`.
  **The same measurement would commit twice.** Promotion stays with
  `confirm_feature_aliases()`, which already re-points and merges collisions.

<!-- block: B-15.B5 -->
### B.5 Liveness
- Before accepting a hit, Layer 2 applies an **unconditional** live-at-`sample_date`
  filter (`date_end` NA or `>= sample_date`). If the filter empties the set → review.
- Deliberately NOT a reuse of `.rc_narrow_live()`: that helper only narrows when
  `length(unique(cand$uuid_feature)) > 1` (reconcile.R:189-198), and a structural hit
  is unique by construction, so reusing it would be a no-op and would resolve to a
  defunct feature. Fixture `f-0006 T.S06` (`date_end 2020-06-30`) is the ready-made case.

<!-- block: B-15.B6 -->
### B.6 The alias side of a structural hit
A Layer-2 hit yields a `uuid_feature` but no `uuid_feature_alias`, and that gap is
not cosmetic — `sample.uuid_feature_alias` is `NOT NULL`, `.rc_batch_duplicate()`
gates on non-NA `uuid_feature_alias` (`.rc_batch_duplicate`, reconcile.R:1223, gate at :1229), and `.fa_find_collisions`
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

<!-- block: B-15.B7 -->
### B.7 Acceptance criteria (each must be able to FAIL)
The original "unknown site → review" and "non-existent point in site → review, not
fabricated" are **vacuous** — every unresolved raw already emits `unknown_feature` and
creates nothing, so a no-op implementation passes both. Replace with:

### R-15.1 Negative case paired with positive control T S01
- Every negative case is paired with the positive control `T S01 → T.S01` **in the
  same test**, so a disabled resolver fails.

### R-15.2 Review payload carries structural suggestion token
- The review payload must carry a structural suggestion token
  (`subkind=structural,site=…,point=…`). `.rc_feature_review` emits only
  `subkind=ambiguous` today (reconcile.R:590-596), so this cannot pass on current code.

### R-15.3 Feature table count unchanged, nothing fabricated
- `count(*) FROM feature` unchanged (nothing fabricated).

### R-15.4 BS01 direct boundary must not auto-resolve
- `BS01` must NOT auto-resolve to `T.S01`-equivalent (the B.2 direct-boundary rule),
  asserted against the fixture collision oracle (F2).

---

<!-- block: B-15.workC -->
## Work C — Layer-3 WO single-site disambiguation (PINNED SPEC)

<!-- block: B-15.C1 -->
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

<!-- block: B-15.C2 -->
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

<!-- block: B-15.C3 -->
### C.3 The `iff` gate, operationally
- Resolved = `!is.na(uuid_feature)` after Layers 1-2 (`.rc_wo_site`, reconcile.R:552,
  the `resolved <- uuid_feature[!is.na(uuid_feature)]` line at :554).
- A resolved feature with NA or blank `site` makes the event **ineligible** (fail closed).
- Curation always wins: a Layer-1 curated alias is never overridden.

<!-- block: B-15.C4 -->
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

<!-- block: B-15.C5 -->
### C.5 Acceptance criteria (each must be able to FAIL)
The original "MIXED-site WO → heuristic does NOT fire" and "curated BS1 inside an
all-B WO still → BH.S01" are both **vacuous** on today's code, and the second is
self-defeating: `BS1`→BH.S01 makes that event's resolved-site set `{B, BH}`, i.e.
multi-site, so Layer 3 never fires and the test cannot distinguish "curation wins"
from "Layer 3 disabled". Replace with:

### R-15.5 Positive control across single- and mixed-site events
- **Positive control on the same fixture:** the identical unresolved raw resolves in
  the single-site event and stays in review in the mixed-site event, asserted across
  two events **in one test**.

### R-15.6 Curated cross-site alias suppresses Layer 3
- Pin explicitly whether one curated cross-site alias suppresses Layer 3 for the whole
  event. **Ruling: it does** — the site set is computed from resolved rows regardless
  of how they resolved, so a curated `BS1`→BH.S01 inside an otherwise-all-B WO makes
  the event multi-site and disables Layer 3. Fail closed.

---

<!-- block: B-15.fixtures -->
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

<!-- block: B-15.scope -->
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

**~~Parked, not in B/C scope:~~ OVERTAKEN BY CURATION 2026-07-23 (cold audit,
finding 1).** ~~the 12 ambiguous items are both `self` vs `historical_code` collisions
with lopsided evidence (`b.s01`: self→B.S01 n_seen=130 vs historical_code→B.TS41
n_seen=2; `k.e02`: self→K.E02 n_seen=20 vs historical_code→K.S06 n_seen=1). A `self` >
`historical_code` precedence rule would clear both, but that is a curation-semantics
decision (it cuts against the standing "old ≠ misspelling" rule) and is deferred
pending a user ruling.~~

The deferral was resolved not by a precedence RULE but by two explicit curation acts:
`b.s01`→B.S01 and `k.e02`→K.E02 were confirmed through `confirm_feature_aliases()` on
2026-07-23 (`kind='transcription_error'`, `confirmed_by='R. Shannon'`) and carry
`auto_assign = TRUE`. Re-measured against the real resolver: each key now returns
exactly **1** candidate and auto-resolves. The general `self` > `historical_code`
precedence question is still unruled and still parked — it was simply not needed for
these two. **The "12 ambiguous items" figure is therefore a pre-2026-07-23 measurement
and must not be re-used as a current count**; the scope conclusion below (B and C
target zero of the residual) is unaffected either way.
- **D. Provenance/confidence + review-candidate plumbing** (folded into A-C).
- **E. Time-bounded aliases** (`feature_alias.date_start` / `date_end`) — specified below.

---

<!-- block: B-15.workE -->
## Work E — time-bounded aliases (PINNED SPEC)

Added 2026-07-23 on Robin's direction. *(Labelled E, not D: a "Part D" already exists
above as the provenance/plumbing item folded into A-C. Robin's "part D" request refers
to this work; the letter is the only difference.)*

<!-- block: B-15.E0 -->
### E.0 Why
Some aliases are ongoing; others record a **particular historical anomaly** and must
apply only within the period that anomaly was live. Today an alias is unconditional,
so a one-off mislabelling from 2021 keeps hijacking a string forever. Evidence: 9
alias rows in the live registry have a key that IS another feature's real name (see
`scratchpad/alias_window_report.txt`); today every one of them is permanently
ambiguous.

<!-- block: B-15.E1 -->
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

<!-- block: B-15.E2 -->
### E.2 Resolution semantics
- An alias is **live at `sample_date`** iff
  `(date_start IS NULL OR date_start <= sample_date)` AND
  `(date_end IS NULL OR date_end >= sample_date)`.
  Both sides compared as DATE. `date_end` is inclusive.
- Alias candidate lookup (`.rc_feature_candidates`, `.rc_feature_suggestions`) filters
  to live aliases before the `auto_assign` filter and before counting candidates.
- **`auto_assign` must be re-settled by migration 003, or E.5 changes nothing.**
  Migration 001 sets `auto_assign = FALSE` on *every* arm of any multi-arm key —
  including the `self` arm. ~~Verified in the live registry: all 17 arms across E.5's 8
  keys are FALSE~~ **CORRECTED 2026-07-23 (cold audit, finding 1): E.5's 8 keys span
  19 arms, not 17, and 2 of them are already `auto_assign = TRUE`** — see E.5's
  itemised flip list, which is the authoritative statement. The pattern is otherwise
  systemic (766 multi-arm rows all FALSE, 1226 single-arm rows all TRUE).
  `.rc_feature_candidates` filters on `auto_assign` (reconcile.R:171) *before* anything
  else, so a date bound alone still yields zero candidates and the row still goes
  pending — E.5 would be inert for the keys whose every arm is still FALSE.
  ~~PINNED: **003 flips `auto_assign` to TRUE on exactly the 17 still-FALSE arms listed
  in E.5, and nothing else.**~~ **RESTATED under R1 (Robin, 2026-07-23) — see
  `dev/plans/RULINGS-2026-07-23-alias-self-precedence.md`.** The pin above is not
  wrong, it is *incomplete*: it treats the self arms as part of E.5's curated list,
  and they are not. There are now **two separate flip rules**, and 003 applies both:
  1. **UNIVERSAL — R1: 003 sets `auto_assign = TRUE` on the `self` arm of EVERY key,
     unconditionally.** Not only the 8 keys of E.5, not conditional on how many arms
     the key has, not conditional on a date bound. **A feature is always reachable by
     its own name.** Migration 001's blanket-FALSE broke that: measured on
     `/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
     (read-only, 2026-07-23) it left **8 self arms `auto_assign = FALSE`**;
     `confirm_feature_aliases()` repaired 2 of them by hand that morning, and
     **6 features are still unreachable by their own name today** — `b.s22`→B.S22 (58
     samples), `b.s04`→B.S04 (37), `b.ts18`→B.TS18 (6), `b.ts40`→B.TS40 (1),
     `b.ts41`→B.TS41 (1), `b.ts02`→B.TS02 (0). That is a live defect, not a
     hypothetical.
  2. **CURATED — E.5's historical arms.** The non-`self` arms of the 8 keys, flipped
     exactly as E.5's itemised list says and **nothing else**. Still not a global
     recompute: the other multi-arm FALSE rows (676 `mask_long`, 66 `descriptive` at
     the time of the original measurement) are un-ruled ambiguities that must stay
     parked.

  The two rules are disjoint by construction (rule 1 touches only `kind = 'self'`,
  rule 2 only non-self arms), so neither post-condition may be asserted as a bare
  count of rows updated. Assert rule 1 as the invariant **"zero `feature_alias` rows
  with `kind = 'self'` and `auto_assign` not TRUE"**, and rule 2 as E.5's end state
  over its named arms.
- With those arms flipped (~~17~~ **19 arms TRUE in total across E.5's 8 keys, counting
  the 2 already flipped — plus, under R1, every other `self` arm in the table**),
  ambiguity becomes **date-dependent and is decided by the
  count of LIVE candidates**, which is what the existing caller already does
  (`status <- "pending"` on 0 or >1, reconcile.R:455) — **except where R2's
  self-precedence applies.** Under R1 a key can now reach ≥2 live arms *because* its
  self arm is on; where exactly one of those live candidates is `kind = 'self'`, the
  self arm WINS, the row resolves through it, and a non-blocking note is emitted
  (**E.7**). Otherwise: inside a bound the key still reaches ≥2 live arms → review,
  exactly as today; outside it reaches 1 → resolves.
  `auto_assign = FALSE` retains its other meaning, a per-row curator veto — on any
  arm except a `self` arm, which R1 removes from the curator's reach.
- This is a filter on the ALIAS, and is separate from the existing `.rc_narrow_live()`
  filter on the FEATURE's `date_end`. **The feature-side liveness must then be applied
  UNCONDITIONALLY**, not via `.rc_narrow_live()`, which only fires when
  `length(unique(cand$uuid_feature)) > 1` (reconcile.R:190). Otherwise the alias-side
  filter can collapse the candidate set to one and thereby *disable* the feature-side
  narrowing, resolving to a defunct feature — reproducible on the shipped `T.REUSED`
  fixture. Same ruling as B.5, same reason.
- **Pending/dangling natural-key lookups are EXEMPT from the date filter.** The
  R-11.5a lookup (`.rc_resolve_existing_pending`, reconcile.R:764, body :779-786) and
  `.ct_materialise_feature_aliases`'s find-or-create
  (`WHERE alias_key = ? AND uuid_feature IS NULL`, commit.R:128)
  must ignore bounds entirely. If a bound hides an existing dangling alias, commit
  creates a *second* one for the same key, `.rc_find_existing` (reconcile.R:1009)
  stops matching the committed sample, and **the same measurement commits twice** —
  the exact hazard B.4 exists to prevent.
- When `sample_date` is NA, the date filter is skipped (no basis to narrow) and the
  row is treated exactly as today.

<!-- block: B-15.E3 -->
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
  (**895/895** live features as of the 2026-07-23 cutover; 0 lack one), but no package
  code ever creates a self alias — only migration 001:383-395
  does, and the sole package reference is a read (commit.R:304). A feature added later
  via `add_feature()` has none (`R/mutate.R:452-475` appends to `feature` and nothing
  else). Migration 003 asserts it and aborts if violated. **See F.9: because the
  precondition holds today and nothing maintains it, F.9 must land BEFORE 003.**
- Robin will notice and initiate any review of a recurring closed-off mislabelling
  manually; the system is NOT required to detect or alert on that. This ruling is
  about not auto-resolving, not about raising an alarm.
- So B.4's gate reads in full: Layer 2 runs only when the key reaches **no
  `feature_alias` row at all**, live, expired, or dangling.
- **The gate needs its own predicate — `.rc_feature_suggestions()` cannot serve.**
  B.4 currently operationalises the gate as "`.rc_feature_suggestions()` returns no
  candidates", but that function excludes dangling rows (`!is.na(fa$uuid_feature)`,
  reconcile.R:213), so it already contradicts B.4's own "regardless of whether the
  alias is dangling" — a pre-existing defect in B.4, independent of E. Under E.2 it
  would also drop expired rows, making an expired-only key read as "no alias rows" and
  fall through to Layer 2, precisely what this section forbids. ~~PINNED: introduce
  `.rc_alias_rows_exist(key, registry)`~~ **ALREADY SATISFIED — verified 2026-07-23
  (cold audit, finding 24).** `.rc_alias_rows_exist(key, registry)` exists at
  **`R/reconcile.R:280-285`**, is date-blind and `auto_assign`-blind, ignores
  `uuid_feature`, and returns TRUE if ANY `feature_alias` row carries that
  `alias_key` — exactly what this bullet specifies. B.4's gate and E.3's gate both use
  it; B.4 is already amended accordingly. **Consequence for E.6: the E.3 acceptance
  criterion can no longer fail on the predicate.** The only part of it that can still
  fail on today's code is the `subkind=expired_alias` payload token, which
  `.rc_feature_review` does not emit (it emits `ambiguous` and `structural` only,
  reconcile.R:590-596). Any E.3 criterion that does not assert that token is vacuous.
- **Review payload grammar.** `subkind=expired_alias,expired=<uuid_feature>@<start>..<end>`
  (pipe-separated for several). Two fixes to the current code are required: the payload
  emits a `subkind` only when `length(sugg) > 1` (reconcile.R:461, emit at :590-596), so
  a *single* expired candidate yields a bare payload today — expired candidates must emit
  even when there is exactly one; and `.rc_feature_suggestions` returns only distinct
  `uuid_feature` (reconcile.R:217), so the bounds must be carried alongside.
  **Precedence, pinned:** if a key has ≥2 live candidates *and* ≥1 expired one, the
  payload is `subkind=ambiguous` with the expired ones listed in an `expired=` clause.
  Ambiguity is the actionable fact; expiry is context.

<!-- block: B-15.E4 -->
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

<!-- block: B-15.E5 -->
### E.5 The curated bounds (data, applied by migration 003)

> **ADJUDICATED 2026-07-24 — E.5 AND E.6 CONTRADICTED EACH OTHER, AND THE FIX IS A
> STRUCTURAL ONE. Read this before writing `003-alias-date-bounds.R`.**
>
> E.5 itemises the bounds against LIVE alias keys (`b.s01`, `k.e02`, …) while E.6
> mandates that every 003 test run on a FIXTURE-named seed (`T.*`/`TH.*`). Those cannot
> both hold: a migration that hardcodes the live keys is a NO-OP on any fixture, so a
> test against it would pass while asserting nothing about the bounds logic. A Phase-4
> writer hit this head-on; it is a Phase-2 defect of mine, not a writer's confusion.
>
> **PINNED: split 003 into an entry point and an injectable applier.**
> * `mig003_run(db, snapshot_dir, dry_run = FALSE, .now = NULL)` — the production entry
>   point, signature identical to `mig001_run` (`001:280`). It owns the table-wide R1
>   self-arm flip and calls the applier with the REAL E.5 bounds table.
> * `.mig003_apply_bounds(con, bounds)` — takes the bounds as an ARGUMENT. Tests call it
>   directly with a fixture-scoped table, which is what makes the bounds logic testable
>   at all.
>
> **This leaves one real gap, and it must be closed separately: the live bounds TABLE
> itself is then never exercised by any test.** Injection tests the mechanism, not the
> nine curated rows. Close it by asserting the table AS DATA — a test over the constant
> that `mig003_run` passes, with no database involved, checking every invariant that can
> be checked without the live registry:
> * exactly the curated rows E.5 lists, no more;
> * every `alias_key` equals `tolower()` of itself (a mixed-case key silently matches
>   nothing);
> * every rule-1 (one-off) row has `date_start == date_end` — R5's whole point, since a
>   `date_end`-only bound is live back to the beginning of time and B.TS41's single
>   sample would otherwise shadow 24 years of B.S01;
> * no row has `date_start > date_end`;
> * the two corrected proxy dates are present and are **2026-05-25** (`k.e02`→K.S06) and
>   **2026-05-04** (`b.s04`→B.S01) — NOT the plan's original literals and NOT the cold
>   audit's day-late replacements.
>
> Without that second test the injection split converts an untestable migration into a
> tested mechanism carrying untested data, which is a quieter failure than the one it
> replaces.

> **RESTATED 2026-07-23 UNDER R1/R5 — read
> `dev/plans/RULINGS-2026-07-23-alias-self-precedence.md` before implementing this
> section.** Two things changed. **(a) The date bounds no longer decide whether
> `b.s01` and `k.e02` resolve.** R1's self-precedence does that, at every date,
> unconditionally. What the bounds now govern is narrower and entirely different:
> **which shadowed arms get NOTED** in the non-blocking `review_queue` row of E.7. A
> bound that is one day out no longer mis-routes a sample; it mis-annotates a note.
> **(b) Rule 1 must set `date_start` as well as `date_end` (R5)**, and `k.e02`→K.S06
> moves from rule 1 to rule 2. Both are worked through below.

Robin's rulings on the 9 collision-class rows. **Rule 1** = one-off mislabelling
(`n_seen == 1` or the target has exactly 1 sample) → close it **to a POINT at** the
sample date. **Rule 2** = a recurring issue Robin wants to review every time → leave
open. **Rule 3** = the same-named point is decommissioned → close at the last sample
date.

ALL NINE ARE SETTLED (Robin, 2026-07-23). `date_end` is inclusive. ~~`date_start` stays
NULL on every row.~~ **CORRECTED under R5 (see the R5 box below): rule-1 rows set
`date_start = date_end`. Rule-2 and rule-3 rows keep `date_start` NULL.** These are
DATA, not derivable — an implementer must use exactly these literals and must not
recompute them.

**R5 — a rule-1 arm gets a POINT bound, not an open-ended-back one.** The liveness rule
of E.2 is `(date_start IS NULL OR date_start <= d) AND (date_end IS NULL OR date_end >= d)`,
so an arm with `date_end` only is **live back to the beginning of time**. Rule 1 exists
for a mislabelling that happened *once*; leaving `date_start` NULL lets that one day
shadow decades. Measured on
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only, 2026-07-23) on the worst case — B.TS41 has exactly ONE sample (2026-01-21),
so the arm `b.s01`→B.TS41 would otherwise shadow 24 years of B.S01 history:

| bound on `b.s01`→B.TS41 | `b.s01` samples falling inside it |
|---|---:|
| `date_end = 2026-01-21`, `date_start` NULL (as first pinned) | **178 of 186** |
| `date_start = date_end = 2026-01-21` (R5, point bound) | **1** |

Under R1 this no longer decides resolution — but it decides whether 177 samples each
carry a spurious "self-precedence overrode B.TS41" note. **PINNED: every rule-1 row
sets `date_start = date_end`.**

**The literals below are SYDNEY-LOCAL calendar dates, corrected +1 day from the first
draft.** `sample.date` in the legacy registry stores Sydney midnight as a UTC-naive
TIMESTAMP: every non-NULL value is 13:00 (7116 rows) or 14:00 (7995 rows), and the
split tracks DST exactly (13:00 Oct–Mar = AEDT/UTC+11, 14:00 Apr–Sep = AEST/UTC+10,
with April splitting 6/1064 across the changeover). So the stored *date part* is one
day BEFORE the true local sampling date, and the first draft — derived with
`as.Date(<POSIXct>, tz = "UTC")` in `scratchpad/alias_window_report.R:23` — took that
UTC date part. Reconcile compares against `as.Date(parsed_dt, tz = "Australia/Sydney")`
(reconcile.R:415), i.e. the local date, so every uncorrected literal would have
excluded the very sample it was derived from. Robin's rulings are unchanged; only the
arithmetic is fixed. (Note `commit.R:369` writes NEW samples as local-date-at-00:00-UTC
— a different convention from the legacy rows. Out of scope here, but recorded.)

| alias_key | resolves_to | rule | `date_start` (local) | `date_end` (local) | stored | basis |
|---|---|---|---|---|---|---|
| `b.s01` | B.TS41 | 1 | **2026-01-21** (point, R5) | **2026-01-21** | 2026-01-20 13:00 | exact — target's only sample |
| `b.ts02` | B.TS27 | 1 | **2021-11-12** (point, R5) | **2021-11-12** | 2021-11-11 13:00 | exact — target's only sample |
| `b.ts41` | B.TMW15 | 1 | **2024-04-08** (point, R5) | **2024-04-08** | 2024-04-07 14:00 | exact — target's only sample |
| `b.s22` | B.S06 | 2 | NULL | **NULL** (stays open) | — | recurring; Robin reviews every time |
| `b.s04` | B.S01 | 1 | NULL — see "the 2 proxies" below | ~~2026-03-16~~ **2026-05-04** | see note below | proxy — target's last sample |
| `b.s22` | B.TS18 | 1 | NULL — see "the 2 proxies" below | **2021-11-12** | 2021-11-11 13:00 | proxy — target's last sample |
| `k.e02` | K.S06 | ~~1~~ **2** | NULL | ~~2025-09-04~~ ~~**2026-05-25**~~ **NULL** (stays open) | — | **RECLASSIFIED, R5 — see below** |
| `b.ts18` | B.S30 | 3 | NULL | **2021-11-12** | 2021-11-11 13:00 | earlier of the two (B.TS18's last) |
| `b.ts40` | B.TS39 | 3 | NULL | **2024-04-08** | 2024-04-07 14:00 | earlier of the two (B.TS40's last) |

**`k.e02`→K.S06 IS RECLASSIFIED FROM RULE 1 TO RULE 2 (R5, Robin, 2026-07-23).** Not a
correction to the literal — a correction to the *rule*. No `date_end` can separate these
two arms, because **K.E02 (31 samples, from 2020-07-28) and K.S06 (24 samples, from
2020-08-11) coexist for their entire lifespans and both end 2026-05-25.** Any bound
placed on the K.S06 arm is therefore inside K.E02's range too, so **post-003 that key
would go to review at every date and never resolve.** It is a rule-2 case —
*recurring, Robin reviews every time* — and the arm stays open. **Consequence for E.6:
the itemised UPDATE list now produces SEVEN non-NULL `date_end` values over the 9 rows,
not eight** (`b.s22`→B.S06 and `k.e02`→K.S06 both stay NULL); the E.6 criterion is
struck and restated accordingly. Note this does NOT leave `k.e02` unresolvable: under
R1 the `k.e02` self arm wins at every date and the K.S06 arm rides along as an E.7 note.

**TWO PROXY LITERALS CORRECTED 2026-07-23 (cold audit, finding 6 as adjudicated).**
`b.s04`→B.S01 and `k.e02`→K.S06 were pinned against the WRONG target samples and are
restated above as **2026-05-04** and **2026-05-25** respectively. Re-measured every
representation side by side (raw `date`, raw `datetime`, `CAST(date AS DATE)`, and both
Sydney-local conversions — all agree). **The cold auditor proposed 2026-05-05 and
2026-05-26; those are ONE DAY LATE and were disproved on re-verification.** They are
the same day-early/day-late landmine this section documents, arrived at from the other
side: `sample.date` stores Sydney midnight as a UTC-naive TIMESTAMP, so a naive cast
reads a day off in whichever direction the caster guessed. **Use only 2026-05-04 and
2026-05-25. Do not re-derive them, and do not accept the auditor's numbers.**
**SUPERSEDED IN PART, R5 (2026-07-23): the `k.e02`→K.S06 half is now MOOT** — that arm
is rule 2 and stays open, so no `date_end` is written for it and ~~2026-05-25~~ is not
transcribed anywhere. The correction is retained above as the audit record of why the
literal was never used, and 2026-05-25 survives as the *measurement* that proves K.E02
and K.S06 end on the same day, which is the reason for the reclassification.
**`b.s04`→B.S01 is unaffected: still rule 1, still 2026-05-04.**

**THE LITERALS IN THIS TABLE ARE FROZEN AS OF 2026-07-23 AND ARE NOT RE-DERIVED
LATER.** They are DATA, adjudicated once against the registry as it stood on that date.
An implementer transcribes them; a later run of any derivation script does NOT get to
overwrite them, and a divergence between the script and this table is a finding to
adjudicate, not a value to update. (The `stored` column is deliberately left blank for
the two corrected rows rather than back-computed: it was a measurement, and a
re-derivation would be a guess.)

**Row identity for the UPDATEs.** Alias uuids are generated per-DB by migration 001, so
the plan cannot cite them, and a key-only `WHERE alias_key = 'b.s22'` would hit **three**
rows (self→B.S22, →B.S06, →B.TS18). ~~PINNED: identity is the pair
**(`alias_key`, target `feature.name`)**, and each of the 9 items must assert it matched
**exactly one** row~~ — **BROKEN, found 2026-07-23 (cold audit, finding 1). The
`date_end` UPDATEs may still key on the pair, but the `auto_assign` FLIP MUST NOT**:
the pair `(alias_key, target feature.name)` matches **TWO** rows for `(b.s01, B.S01)`
and **TWO** for `(k.e02, K.E02)`, because each of those keys now carries both a `self`
arm and a confirmed `transcription_error` arm pointing at the SAME feature. An
"exactly one row" assertion keyed on the pair aborts the migration on those two items.
The flip must be keyed on something that distinguishes the arms — the pair plus
`kind`, or a `WHERE auto_assign IS NOT TRUE` restriction (see the flip list below,
which excludes them outright). Each of the 9 `date_end` items must still assert it
matched exactly one row, aborting the migration otherwise.
**AMENDED 2026-07-23 (R1/R3).** Two changes. (a) **R3 removes the collision at
source**: the duplicate `(b.s01, B.S01)` and `(k.e02, K.E02)` arms are merged into their
`self` arms and deleted (**E.8**), so after E.8 the pair `(alias_key, target
feature.name)` matches exactly one row again — but E.8 must land BEFORE 003 for that to
be true, and 003 must not *depend* on it: keep the `kind`-qualified key regardless, so
003 is correct whether or not a future duplicate exists. (b) **R1's universal self flip
is not keyed on the pair at all** — it is keyed on `kind = 'self'` across the whole
table, matches **all 895 self arms** rather than 1, and must not carry an "exactly one
row" assertion. Measured on
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only, 2026-07-23): 895 `self` rows, **887 already TRUE, 8 FALSE**, over 895
features. Only E.5's curated non-self arms use the pair.

**The `auto_assign` flip (E.2), itemised. RESTATED 2026-07-23 (cold audit, finding 1):
the 8 keys span 19 arms, not 17, and 2 of those arms are ALREADY `auto_assign = TRUE`.**

~~003 sets `auto_assign = TRUE` on exactly these 17 rows and no others — the full arm
set of the 8 keys above, self arms included: `b.s01`→{B.S01, B.TS41}; `b.s04`→{B.S01,
B.S04}; `b.s22`→{B.S06, B.S22, B.TS18}; `b.ts02`→{B.TS02, B.TS27}; `b.ts18`→{B.S30,
B.TS18}; `b.ts40`→{B.TS39, B.TS40}; `b.ts41`→{B.TMW15, B.TS41}; `k.e02`→{K.E02,
K.S06}.~~

The full arm set of the 8 keys is **19 arms**. Two of them —

| already TRUE | kind | confirmed_by | when |
|---|---|---|---|
| `b.s01` → B.S01 | `transcription_error` | `R. Shannon` | 2026-07-23, via `confirm_feature_aliases()` |
| `k.e02` → K.E02 | `transcription_error` | `R. Shannon` | 2026-07-23, via `confirm_feature_aliases()` |

— were confirmed by hand at the cutover and **already auto-resolve**: run against the
real resolver, `b.s01` returns exactly 1 candidate and `k.e02` returns exactly 1.

- **The UPDATE set is the remaining 17 arms.** Excluded from the UPDATE, included in
  the post-condition. Restated in full:
  `b.s01`→{~~B.S01 (already TRUE)~~, B.TS41}; `b.s04`→{B.S01, B.S04};
  `b.s22`→{B.S06, B.S22, B.TS18}; `b.ts02`→{B.TS02, B.TS27}; `b.ts18`→{B.S30, B.TS18};
  `b.ts40`→{B.TS39, B.TS40}; `b.ts41`→{B.TMW15, B.TS41};
  `k.e02`→{~~K.E02 (already TRUE)~~, K.S06}.
  **RE-FRAMED under R1 (2026-07-23):** the arm list itself is unchanged, but the `self`
  members of it (`B.S01`, `B.S04`, `B.S22`, `B.TS02`, `B.TS18`, `B.TS40`, `B.TS41`,
  `K.E02`) are no longer flipped *because E.5 says so* — they are flipped by R1's
  universal rule, which reaches them and 887 other self arms alike. E.5's own UPDATE
  set is now **only the non-self arms**: `b.s01`→{B.TS41}; `b.s04`→{B.S01};
  `b.s22`→{B.S06, B.TS18}; `b.ts02`→{B.TS27}; `b.ts18`→{B.S30}; `b.ts40`→{B.TS39};
  `b.ts41`→{B.TMW15}; `k.e02`→{K.S06}. The end state over the 19 arms is identical;
  what changed is which rule owns which arm, and therefore what a failing assertion
  would be telling you.
- **Post-condition (assert this, not the UPDATE count): all 19 arms are
  `auto_assign = TRUE` and nothing else changed.** An assertion written as "17 rows
  updated" is satisfied by a migration that also silently un-flips the two.
  **Add R1's post-condition alongside it, as a separate assertion:** zero
  `feature_alias` rows with `kind = 'self'` and `auto_assign` not TRUE, table-wide.
  The 19-arm assertion does not imply it and cannot substitute for it.
- ~~**⚠ OPEN — RULING NEEDED FROM ROBIN. Migration 003 as previously specified would
  REGRESS these two.**~~ **ANSWERED 2026-07-23 by R1 — see
  `dev/plans/RULINGS-2026-07-23-alias-self-precedence.md`.** The question was whether
  `b.s01`/`k.e02` may regress to review for dates inside their bounds, given that a
  human had confirmed them; the three options on the table were (i) accept the
  regression, (ii) let `confirmed_by` win, (iii) give the confirmed arms a
  `date_start`. **Robin ruled none of them.** All three treat the symptom — a
  hand-confirmed *duplicate* arm — as though it were the mechanism. The mechanism is
  R1: the `self` arm always wins, so `b.s01` and `k.e02` resolve at every date,
  including dates inside the bound, and the shadowed arm becomes an E.7 note rather
  than a blocker. R3 (**E.8**) then deletes the two duplicate arms outright and R4
  (**F.19**) stops `confirm_feature_aliases()` minting more of them. **003 is no
  longer blocked on a ruling.** The test obligation stands unchanged and is now
  answerable: pin the behaviour of `b.s01` and `k.e02` at a date INSIDE the bound —
  it must RESOLVE to B.S01 / K.E02 and emit exactly one non-blocking note.

**On the rule-2 row — `b.s22` is DELIBERATELY never auto-resolved. Do not "fix" it.**
Confirmed 2026-07-23 (cold audit, finding 21): `.rc_feature_candidates("B.S22")`
returns **0** candidates today (all three arms are `auto_assign = FALSE`), and it stays
in review at **every** date post-003 too — the flip makes all three arms TRUE, the
`b.s22`→B.TS18 arm closes at 2021-11-12, and from any later date the key still reaches
TWO live arms (self→B.S22 and the deliberately-unbounded →B.S06), so the live-candidate
count is >1 and the row goes pending. **That is Rule 2 working exactly as ruled** —
Robin wants to see this key every time. ~~A later reader who finds `b.s22` "still not
resolving" after 003 has found the requirement, not a bug; no test may assert that it
resolves, and any test touching it must assert that it does NOT.~~

> **⚠ RULE 2's MECHANISM CHANGES UNDER R1 — the requirement does not.** Post-R1 the
> `b.s22` self arm is `auto_assign = TRUE`, so from any post-2021-11-12 date the key
> reaches two live candidates of which **exactly one is `kind = 'self'`** — and R1 says
> the self arm wins. So `b.s22` **resolves to B.S22 and commits**, carrying an E.7 note
> naming the shadowed →B.S06 arm. It no longer goes pending. Robin still sees the key
> every time, through the note instead of through a blocked row. The same reasoning now
> covers `k.e02`, reclassified to rule 2 above.
> **Restated test obligation:** a test touching `b.s22` must assert (a) it RESOLVES to
> B.S22, and (b) it emits an E.7 note naming B.S06. ~~Asserting that it does not
> resolve~~ is now the wrong assertion and would pin the pre-R1 behaviour.
> **Flagged, not decided:** if Robin wants rule 2 to keep BLOCKING rather than
> annotating, that is a further ruling and a per-arm veto flag would be needed — R1 as
> written admits no exception. Recorded here so the change is visible rather than
> discovered.

**On the ~~3~~ 2 proxies.** *(`k.e02`→K.S06 is no longer one of them — it is rule 2
under R5.)* Per-alias usage is unrecoverable — migration 001 repoints every
sample to its *self* alias and the raw string was never retained on `sample` — so for
`n_seen == 1` against a many-sampled target we know the mislabelling happened once but
not *when*. Robin's ruling: use the target's last sample date. This is deliberately
conservative (the alias stays live across the target's whole history) and can be
tightened later if a specific incident date surfaces.

**R5 and the 2 proxies — NOT RULED, do not guess.** R5 pins the point bound for the
rule-1 rows whose target has exactly ONE sample (`b.s01`→B.TS41, `b.ts02`→B.TS27,
`b.ts41`→B.TMW15) — those are the case it was measured on. It supplies no `date_start`
literal for the two *proxy* rule-1 rows, and the paragraph above is the reason: their
whole point is that the incident date is unknown and the arm stays live across the
target's history, which a point bound would contradict. **`date_start` therefore stays
NULL on `b.s04`→B.S01 and `b.s22`→B.TS18 until Robin rules otherwise.** Under R1
nothing turns on it except how many E.7 notes those two keys generate; that is the
right size of consequence for an unruled value, and it is why this is flagged rather
than filled in.

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

<!-- block: B-15.E6 -->
### E.6 Acceptance criteria (each must be able to FAIL)
**Ordering: E depends on B.** The E.3 criterion is vacuous until Layer 2 exists, so
Work E lands after Work B, and the E.3 test carries a positive control (below).

> **THE 003 CRITERIA BELOW ARE UNEXECUTABLE AS WRITTEN — cold audit 2026-07-23,
> findings 2, 3 and 18. Read this box before writing a single 003 test.**
>
> **(i) There is no seed they can run on.** The 003 criteria are stated against a
> "pre-003 seed" that does not exist. `tests/testthat/helper-migration-db.R` is
> **pre-001** — it carries **11** `cypher` references, i.e. it seeds the schema
> migration 001 replaces, so it has no `feature_alias` table to bound at all. And
> `tests/testthat/helper-db.R` contains **none** of `b.s01`, `b.ts02`, `b.ts18` or
> `k.e02` — the curated keys every 003 criterion names. Neither helper can host these
> tests.
> **PINNED: 003's tests require an explicitly named, post-001 migration seed** — call
> it `helper-migration-003-db.R` and name it in the plan rather than leaving the test
> writer to pick — which carries the 9 curated rows of E.5 **under FIXTURE names**
> (`T.*`/`TH.*`, mirroring the live shapes: a rule-1 one-off, a rule-2 recurring, a
> rule-3 non-overlapping rename, a rule-3 OVERLAPPING rename, and the two
> already-confirmed `transcription_error` arms), plus a self alias per feature.
>
> **(ii) Every count must be restated relative to that seed, never to the live
> registry.** The live alias count is **1,994** today, so the "all other 1980 aliases"
> figure below is both wrong and structurally unreachable in a fixture — a fixture with
> 1,980 aliases is not a fixture. Criteria must read "all OTHER aliases in the seed are
> NULL/NULL", asserted as a count of the complement, not a hard-coded total. The same
> goes for 1985, 894, 895 and every other live-registry number: they are context for
> the implementer, never test constants. (This is the same rule B.1 already pins for
> the site set.)
>
> **(iii) The `self`-alias abort criterion CANNOT FAIL on any existing seed.** See its
> own bullet below.

### R-15.7 Expired date_end alias does not resolve later row
- An alias with `date_end` in the past does NOT resolve a later-dated row — paired in
  the same test with the identical row dated *before* the bound, which DOES resolve.
  (Without the pair, a resolver that is simply broken passes.)

### R-15.8 date_start bound blocks rows before start date
- Ditto `date_start`: a row dated before the start does not resolve; one after does.

### R-15.9 Bounded two-arm key resolves outside the bound
- **E.2 `auto_assign`:** a bounded two-arm key resolves to its surviving arm outside
  the bound. Concretely, post-003 `b.ts18` at a 2026 date resolves to B.TS18. Without
  the 17-row flip this fails — which is the point; it is the only criterion that
  catches E.5 being inert. ~~**Add the paired criterion for the two already-TRUE arms**
  (E.5's open ruling): assert the behaviour of `b.s01` and `k.e02` at a date INSIDE
  their bounds, whichever way Robin rules~~ **RESTATED under R1 (2026-07-23): assert
  that `b.s01` and `k.e02` at a date INSIDE their historical arm's bound RESOLVE to
  B.S01 / K.E02 and emit exactly one E.7 note each** — this is the only criterion that
  catches 003 regressing a human confirmation.

### R-15.10 Universal self-alias flip resolves own name
- **E.2 R1, universal self flip (NEW, must be able to FAIL):** a seed feature whose
  `self` arm is `auto_assign = FALSE` and which is NOT one of E.5's 8 keys resolves by
  its own canonical name after 003. Without R1's table-wide rule this fails, and a
  migration that flips only E.5's arms fails it — which is the point. Pair it with the
  table-wide post-condition (zero `self` arms not TRUE), because the post-condition
  alone is satisfied by a seed that never had a FALSE self arm to begin with.

### R-15.11 Feature-side liveness excludes defunct feature
- **E.2 feature-side liveness:** a key with one live alias arm pointing at a *defunct*
  feature goes to review, not to the defunct feature. Build it on the `T.REUSED`
  fixture (fa-0007→f-0006, `date_end 2020-06-30`; fa-0008→f-0007 live) by bounding the
  fa-0008 arm and dating the row 2025 — today that silently resolves to f-0006.

### R-15.12 Pending alias exempt from date bounds, no double-commit
- **E.2 pending exemption:** a dangling alias whose bounds would exclude the row is
  still found by the natural-key lookup, and re-ingesting the same measurement commits
  it ONCE. Assert the `analysis` row count, not just the absence of an error.

### R-15.13 NULL date bounds regression guard
- **REGRESSION GUARD, not an acceptance criterion:** NULL/NULL alias behaves exactly as
  today. Name the cases: `T.AMBIG2` ambiguity, `T.REUSED` narrowing, the `bs03alt` hit,
  plus a direct assertion that a NULL/NULL alias resolves at dates far either side of
  any bound.

### R-15.14 Pre-003 database regression guard
- **REGRESSION GUARD, not an acceptance criterion — E.1 pre-003 DB:** the resolver run
  against a seed WITHOUT the two columns behaves exactly as today and does not error.
- *(Relabelled 2026-07-23, cold audit finding 18. Both of the above assert that
  nothing CHANGED, so a completely unimplemented Work E passes both. They are
  blast-radius guards and are necessary, but they must not be counted toward "each
  criterion must be able to fail" — no acceptance gate may rest on them, and a
  reviewer scoring E must not treat them as evidence that E works.)*

### R-15.15 Expired-only alias goes to review, not structural
- E.3: a key whose only alias is expired lands in review with `subkind=expired_alias`
  and does NOT get structurally resolved — asserted against a raw that WOULD parse
  structurally. **Paired positive control in the same test:** an identical raw with NO
  alias row at all DOES structurally resolve, so the test fails if Layer 2 is simply
  disabled rather than correctly gated.

### R-15.16 Expired-alias payload emission at count boundaries
- E.3 payload: a key with exactly ONE expired candidate still emits
  `subkind=expired_alias` (guards the `length(sugg) > 1` gate); a key with 2 live + 1
  expired emits `subkind=ambiguous` with an `expired=` clause.

### R-15.17 New pending alias date_start is min sample_date
- A newly-created pending alias has `date_start` = `min(sample_date)` over its group —
  asserted with the group presented in BOTH file orders, yielding the same value — and
  `date_end` NULL. Re-ingesting does not change it.

### R-15.18 confirm_feature_aliases sets, clears, leaves bounds
- `confirm_feature_aliases()`: set both bounds, clear a bound, and leave a bound
  untouched are three distinguishable outcomes; a bounds-only call needs no
  `uuid_feature`.

### R-15.19 Migration 003 produces correct date bounds and flips
- Migration 003 on **the named post-001 003 seed** (box (i) above — NOT the live
  registry, NOT `helper-migration-db.R`) produces ~~**8 non-NULL `date_end` values over
  the 9 itemised rows** (`b.s22`→B.S06 stays NULL)~~ **SEVEN non-NULL `date_end` values
  over the 9 itemised rows — corrected 2026-07-23 under R5, which reclassifies
  `k.e02`→K.S06 to rule 2; `b.s22`→B.S06 and `k.e02`→K.S06 both stay NULL — plus THREE
  non-NULL `date_start` values, one per exact rule-1 row, each equal to its own
  `date_end` (R5's point bound). A criterion that checks `date_end` only passes against
  a migration that never writes a `date_start` at all** and leaves **every OTHER alias row
  in the seed** NULL/NULL — asserted as a count of the complement, ~~all other 1980
  aliases~~ **never as a hard-coded total** (finding 3: the live count is 1,994 today,
  so 1980 is wrong AND unreachable in a fixture; a seed carrying ~1,985 aliases would
  not be a fixture). Each `date_end` UPDATE matched exactly one row. **`auto_assign` is
  TRUE on all 19 arms afterwards**, of which 17 were changed by the migration and 2
  were already TRUE (E.5) — assert the end state over the 19, not the count of rows
  updated — and unchanged everywhere else. Row counts and checksums otherwise unchanged
  — **with a checksum that covers `feature_alias`** over
  `(uuid, alias_key, uuid_feature, kind, auto_assign, n_seen)`. `mig001_counts_checksum()`
  covers feature/sample/analysis/lab_method only (001:57-84) and would not notice 003
  damaging the one table it modifies.

<!-- R-15.20 is DELIBERATELY UNASSIGNED. The criterion below is withdrawn (struck
     through) and must not be declared: it cannot fail on any existing seed — 0 of 895
     live features and 0 of 13 fixture features lack a self alias — so declaring it
     would be a permanent coverage failure against a test that proves nothing. The
     numbering gap is intentional; do not renumber to close it. -->
- ~~Migration 003 aborts if any feature lacks a `self` alias (E.3 precondition).~~
  **THIS CRITERION CANNOT FAIL AS WRITTEN — cold audit 2026-07-23, finding 2.**
  Measured: **0 of 895** live features and **0 of 13** fixture features lack a `self`
  alias. So on every database and every seed that exists, the precondition already
  holds, the abort never fires, and a migration with the check entirely absent passes
  this criterion. It tests nothing.
  **RESTATED: the criterion requires a purpose-built seed with exactly one `self` alias
  DELETED, and asserts BOTH halves in the same test** — (a) 003 ABORTS on the damaged
  seed, naming the offending feature, and leaves the DB unchanged (assert the row
  counts and the checksum, not just the error class); and (b) 003 RUNS TO COMPLETION on
  the healthy seed. Without (b) a migration that always aborts passes; without (a) a
  migration that never checks passes. See also F.9, which is why the precondition is
  not an invariant.

### R-15.21 sample_date NA yields unchanged behavior
- `sample_date` NA → no narrowing, unchanged behaviour. Pin this as a **unit test on
  `.rc_feature_candidates(feature_raw, NA, registry)`**: ~~`.rc_parse_dates`
  (reconcile.R:615-640)~~ **there is NO `.rc_parse_dates` — corrected 2026-07-23 (cold
  audit, finding 23). The datetime pass is `.rc_resolve_datetime` (reconcile.R:900)**,
  which drops unparseable rows before commit, so an end-to-end test of this criterion
  passes regardless of the implementation.

<!-- block: B-15.E7 -->
### E.7 Self-precedence, and the note that records it (R2 — Robin, 2026-07-23)

> **PINNED 2026-07-24 — where the `self_precedence_note` discriminator LIVES.** A
> Phase-4 writer found this unpinned here and in the rulings document, and asserted on
> the payload string rather than inventing a new review `kind`. That reading is correct
> and is now the rule:
>
> * `kind` stays `unknown_feature` — the existing top-level review kinds are not
>   extended. A new `kind` would be seen by every existing `review_queue` consumer as a
>   new class of work.
> * The discriminator is `subkind=self_precedence_note` **in the payload**, alongside
>   the shadowed candidates, matching the `subkind=` convention `.rc_feature_review`
>   already emits (`ambiguous`, `structural`).
> * **AND the payload carries an explicit blocking flag** — a boolean, not an implied
>   property of the subkind value. This is the FIRST non-blocking review row the feature
>   resolver has ever emitted, and if "is this a note?" can only be answered by knowing
>   which subkinds happen to be notes, every reader has to hardcode that set and the
>   next subkind added silently reads as work. The flag is what makes the note safe;
>   the subkind is only what names it.
>
> Both belong to the single `subkind` precedence table owned by the `P15-review-payload`
> unit — do not start a second one.

Source: `dev/plans/RULINGS-2026-07-23-alias-self-precedence.md`, R2. R1 makes every
`self` arm `auto_assign = TRUE`; **E.7 is what stops that turning into a review-queue
flood**, and it is a prerequisite of R1 being safe, not a nicety on top of it.

**The rule.** In candidate resolution, where a key reaches **more than one live
candidate and exactly one of them is `kind = 'self'`, the self arm WINS**: the row
resolves through it and the sample commits. The shadowed candidates are not discarded —
they are recorded on a `review_queue` row that is **explicitly NON-BLOCKING**.

**Why the code cannot be left alone.** Two localised changes in `R/reconcile.R`, and the
first one is not optional:
1. **Self-precedence in `.rc_feature_candidates`** (`R/reconcile.R:162-182`), which
   filters to `auto_assign = TRUE` at **`:171`** before anything else. Under R1 a key
   with a live historical arm now passes **two** rows through that filter, so
   `length(distinct_feat) == 1` at **`:448`** is FALSE and the row falls through to
   `status[[i]] <- "pending"` at **`:455`** — i.e. it goes to review, which is the exact
   behaviour R1 exists to prevent. R1 without E.7 is a regression, not an improvement.
2. **Retain the shadowed candidates and emit the note.** The clean-hit path
   (**`R/reconcile.R:448-453`**) `next`s out at **`:452`**, *before* the pending
   assignment at `:455` and before the candidate-collection code at **`:460-461`**
   (`sugg <- .rc_feature_suggestions(...)`; `if (length(sugg) > 1) cand_list[[i]] <- sugg`).
   So the one path that will now carry a self-precedence win is precisely the path that
   currently collects nothing. The shadowed candidates must be captured on that path
   and carried into the review payload.
   *(Citation corrected on verification 2026-07-23: the rulings document cites
   `:450-453` and `:455`; the `if` opens at `:448`, the `next` is at `:452`, and the
   candidate collection is at `:460-461`, not `:455`. The argument is unaffected.)*

**FIRST NON-BLOCKING REVIEW KIND EMITTED BY THE FEATURE RESOLVER.** Everything the
resolver queues today is a row that did NOT commit. This one commits. **The payload
grammar must therefore distinguish a note from a blocker**, or a queue reader will work
a note as though it were a task. **Fold this into the SINGLE `subkind` precedence table
already pinned in the Work F header (audit finding 7) — do not invent a second
vocabulary and do not add a parallel table.** That table currently orders `ambiguous` >
`expired_alias` > `suggestion` > `structural`; the note takes its place in it — at
precedence **0, above `ambiguous`**, because the two describe the same input shape and
`ambiguous` would otherwise swallow every self-precedence case — and the note/blocker
distinction must be a payload token a reader can branch on, not an inference from the
`subkind` name. *(The spelling `self_precedence` is this plan's proposal, not Robin's
ruling; R2 pins that the note exists and must be distinguishable, not what it is
called. Rename freely, in one place, before implementation.)*

**Architecturally available today — verified, not assumed.** Nothing in `R/` reads
`review_queue` to gate anything: `commit.R:632-652` appends every review row
independently of whether samples commit (`db_append(con, "review_queue", ...)` at
**`commit.R:650`**), the only reader is `review_queue()` (**`R/mutate.R:583`**), a
plain SELECT, and the centralised writer is `review_queue_add()`
(**`R/db-schema.R:292`**). Precedent for annotate-alongside-committed-data already
exists in three kinds: **`unknown_unit`** (`reconcile.R:861`), **`value_conflict`**
(`reconcile.R:1180`, `assemble.R:179`) and **`batch_duplicate`** (`reconcile.R:1243`).
E.7 is a new *kind*, not a new *architecture*.

Acceptance (must be able to FAIL): a key whose `self` arm and one live historical arm
are BOTH `auto_assign = TRUE`, reconciled at a date inside the historical arm's bound,
must (a) resolve to the self feature, (b) produce a committed `sample`/`analysis` row —
assert the row counts, not merely the absence of a review item — and (c) produce exactly
one `review_queue` row naming the shadowed feature and carrying the non-blocking token.
**All three halves in one test.** Without (b) an implementation that queues and blocks
passes; without (c) an implementation that silently drops the shadowed arm passes — and
silent dropping is the failure mode R2 exists to prevent. **Paired negative control in
the same test:** a key reaching two live NON-self arms still goes to review and does NOT
commit, so the test fails if self-precedence was implemented as "always take the first
candidate".

<!-- block: B-15.E8 -->
### E.8 Merge the two duplicate identity arms (R3 — Robin, 2026-07-23)
Source: `dev/plans/RULINGS-2026-07-23-alias-self-precedence.md`, R3.

`b.s01` → B.S01 and `k.e02` → K.E02 each exist **twice** in the registry: once
`kind = 'self'` with `auto_assign` FALSE, and once `kind = 'transcription_error'` with
`auto_assign` TRUE and `confirmed_by = 'R. Shannon'` (both written 2026-07-23 at the
cutover by `confirm_feature_aliases()`). **Both duplicates carry the identical `name` as
their self arm** — `"B.S01"` and `"K.E02"` — and **both have
`alias_key = lower(feature.name)`**. They are identity mappings, not transcription
errors: the string is the feature's own name, spelled correctly.

**These are the only two such duplicates in the registry.** Measured on
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only, 2026-07-23): `feature_alias` holds exactly **2** rows with
`kind = 'transcription_error'`, and they are these two.

**Required: merge each into its `self` arm and DELETE the duplicate** — carry the
`confirmed_by` and `auto_assign = TRUE` onto the surviving `self` row, then remove the
`transcription_error` row, with `change_log` provenance on both operations. Any
`sample.uuid_feature_alias` reference to the deleted row must be repointed to the
surviving self arm in the same transaction; do not delete a row anything still points
at.

**Sequencing: E.8 lands before migration 003, and F.19 before E.8** — F.19 first,
because until `confirm_feature_aliases()` is fixed the next confirmation mints a third
duplicate and E.8 has to be run again. E.8 also removes the `(alias_key, target
feature.name)` two-row collision documented in E.5's "Row identity for the UPDATEs";
003 must nonetheless keep its `kind`-qualified key rather than relying on E.8 having
run.

Acceptance (must be able to FAIL): after E.8, `feature_alias` holds exactly ONE row for
each of `(b.s01, B.S01)` and `(k.e02, K.E02)`, that row has `kind = 'self'`,
`auto_assign = TRUE` and the preserved `confirmed_by`; the sample count attached to each
feature is UNCHANGED across the merge (assert it before and after — a merge that orphans
samples otherwise passes); and reconciling the raw `"B.S01"` still resolves to B.S01.

<!-- block: B-15.workF -->
## Work F — Work A remediation (from the Phase-5 cold audit, 2026-07-23)

**SEQUENCING (Robin, 2026-07-23): F.1, F.2 and F.3 are FOLDED INTO THE B/C
IMPLEMENTATION PASS**, not queued behind it. They live in the same function
(`.rc_feature_key`) that Work B builds on, and until F.3 lands the key has no
real test guarding it at all.

**F.9, F.10 and F.11 were added 2026-07-23 and are all APPROVED by Robin.** F.10
(work-order re-ingest guard) and F.11 (drop `sample.date`) both touch `R/reconcile.R`
and `R/commit.R`, which the Work B/C implementation pass is editing — so they are
QUEUED behind it to avoid a write conflict, not deferred on merit.

**UNSTATED ORDERINGS, now pinned (cold audit 2026-07-23, findings 5, 7, 8, 12, 20).**
These are hard dependencies, not preferences; each one, if violated, produces a build
that cannot be made correct without rework:

| ordering | why |
|---|---|
| **F.9 → migration 003** | 003 asserts every feature has a `self` alias and aborts otherwise (E.3/E.6). `add_feature()` (`R/mutate.R:452-475`) appends to `feature` and NOTHING else, so a single `add_feature()` call between now and 003 makes 003 **unrunnable**. See F.9. |
| **F.5 → F.6 → E.3, in ONE pass** | all three change `.rc_feature_review`'s payload, and E.3/F.6 each add a `subkind` value. Done separately they collide; done together they need one precedence table (below). |
| **F.11 → F.12** | F.12(b) restores a projection *including* `date` — the very dependency F.11 exists to remove. Landing F.12 first re-creates F.11's own blocker. See F.12. |
| **F.10's supersede exemption → F.10** | F.10 as written blocks the A12 revision-supersede and `already_present` paths. The exemptions must be pinned BEFORE the guard is built, or the guard ships breaking them. See F.10. |
| ~~**F.15's linkage decision → F.15**~~ **SETTLED 2026-07-24** | Was: `review_queue` has no column linking an item to the alias it raised. **Robin ruled option (a): a `uuid_target` column** — design pinned in F.15 (D1–D6), acceptance is R-15.38…R-15.43. F.15 is unblocked. |
| **F.15's migration 5 → F.15's close path** | The `uuid_target` column must exist before anything reads or writes it. It is an `.st_schema_migrations` DDL entry (auto-applied by `ensure_schema()`), **not** a `dev/migrations/00N-*.R` script — those are one-off data remediations; this is plain schema. See F.15 D1. |
| **F.19 → E.8 → migration 003** | *(added 2026-07-23, R3/R4.)* Until `confirm_feature_aliases()` stops minting duplicate identity arms (F.19), E.8's cleanup is not durable — the next confirmation re-creates the problem. E.8 in turn removes the two-row `(alias_key, target feature.name)` collision 003's UPDATE keying has to work around. See F.19, E.8. |
| **E.7 → R1's flip (migration 003)** | *(added 2026-07-23, R1/R2.)* R1 turns every `self` arm on, which makes keys with a live historical arm reach TWO candidates. Without E.7's self-precedence they go PENDING (`reconcile.R:455`) — R1 landed without E.7 is a review-queue regression, not a fix. See E.7. |
| **F.19 and E.8 → the NEXT INGEST of the incoming files** | *(added 2026-07-23, Robin.)* Not a build dependency — a **calendar** one. More input files are arriving. Every ambiguous key in them generates a pending alias, and every confirmation of one writes another mislabelled (and possibly duplicate) row. Ingesting first means cleaning up more later. |
| **F.10 and F.17 → the backfill items** | *(promoted 2026-07-23, Robin — same reason.)* F.10 (work-order re-ingest guard) and F.17 (each file archived against its work order) are **promoted AHEAD of the backfill items** they were previously queued behind. Both protect the incoming files: F.10 stops a re-download double-committing, F.17 stops a deliverable being lost unarchived — and F.17's own entry records that this loss is **realised, not hypothetical** (13 files). Backfill can wait; arriving files cannot. |

**ONE `subkind` PRECEDENCE TABLE, covering all four values.** F.6 adds `suggestion`
and E.3 adds `expired_alias` to a vocabulary that already holds `ambiguous` and
`structural`, and nothing orders the four. **The code ALREADY pins `ambiguous` >
`structural` (`R/reconcile.R:587-593`) — EXTEND that order, do not invent a new one:**

**EXTENDED 2026-07-23 to FIVE values (R2).** E.7's self-precedence note folds in here,
as R2 requires — there is no second table and no second vocabulary. It also forces a
column the table did not previously need: **whether the row COMMITTED.** Every subkind
below it belongs to a row that did not; E.7's belongs to a row that did.

| precedence | `subkind` | row committed? | emitted when |
|---|---|---|---|
| 0 (highest) | `self_precedence` | **YES — NOTE, non-blocking** | ≥2 live candidates of which **exactly one** is `kind = 'self'` (R1/R2, E.7). The self arm resolves the row; the shadowed live candidates ride along in a `shadowed=` clause. This case is carved OUT of `ambiguous` below — it is checked first, or `ambiguous` swallows it. |
| 1 | `ambiguous` | no | ~~≥2 live candidates~~ **≥2 live candidates, NOT uniquely resolved by precedence 0** (restated 2026-07-23). Already implemented. Expired candidates, if any, ride along in an `expired=` clause (E.3) rather than winning. |
| 2 | `expired_alias` | no | 0 live candidates and ≥1 expired/not-yet-started one (E.3). Must emit at count 1. |
| 3 | `suggestion` | no | exactly 1 live candidate, `auto_assign = FALSE` (F.6). Must emit at count 1. |
| 4 (lowest) | `structural` | no | no alias row at all, and Layer 2 produced a parse (B.7). Already implemented as the fallback. |

Rationale for 2 above 3: an expired alias is a curation act the operator needs to see;
a lone unconfirmed suggestion is weaker information. A row can satisfy at most one of
2 and 3 by construction (a candidate is either live or not), so the ordering between
them only ever matters if a future change makes them co-occur — pin it now anyway.
One test per branch, and one test asserting the precedence at each adjacent pair.

**Rationale for 0 at the top, and the reader contract.** `self_precedence` and
`ambiguous` describe the same *shape* of input — several live candidates — and differ
only in whether one of them is the feature's own name. If `ambiguous` is evaluated
first it wins every time and R1 never takes effect, so the ordering is load-bearing
rather than cosmetic. **A queue reader must branch on the committed column, not on the
subkind name**: `self_precedence` is the only value that does not denote outstanding
work, and a reader that treats "has a `review_queue` row" as "needs attention" will
mis-handle it. Pin the token explicitly in the payload; do not leave it to be inferred
from the subkind string. Add one test asserting the 0-vs-1 precedence at the adjacent
pair, like every other pair in this table.

**F.4–F.8 ARE DEFERRED TO POST-CUTOVER (Robin, 2026-07-23).** They are NOT
abandoned — they are follow-up work, to be picked up once the migrated DB is in
service. The deferral is safe on measured evidence, not optimism: F.6's exposure
is 5 alias keys (`g182`, `g183`, `g184`, `g185`, `upstream`), it affects **zero**
current dry-run residual items, and nothing in `R/` parses `subkind` today — so it
is latent correctness, not review-queue reduction. F.4/F.5/F.7 are test-quality and
documentation defects that cannot corrupt data. F.8 is not currently triggerable.

**PHASE 8 (fresh-eyes behavioural review) IS ALSO DEFERRED TO POST-CUTOVER
(Robin, 2026-07-23)**, to get the DB into service sooner, with any resulting mess
cleaned up afterwards. The decision was made with the risk stated and accepted.
The compensating controls, which are therefore NON-NEGOTIABLE:
  1. ~~the dry-run gate must not regress (57 review items / 43 `unknown_feature` /
     zero cross-site mis-merge);~~
     **⛔ UNEXECUTABLE AS WRITTEN — cold audit 2026-07-23, finding 9. NOT deleted:
     a compensating control declared NON-NEGOTIABLE may not be quietly dropped.**
     The gate cannot be run: `assets/` **no longer exists**, so the 265-file input
     corpus it measures is gone, and its three target numbers (57 / 43 / zero) are
     stale — they were measured pre-cutover, against a registry that has since gained
     features, aliases and the two `transcription_error` confirmations of E.5, every
     one of which moves the residual.
     **Required before this control can be relied on again, and Robin must choose:**
     either (a) **re-baseline it against the archived corpus** — record the corpus
     path in this plan alongside the newly measured review-item / `unknown_feature`
     counts and the date they were taken, so the gate is reproducible by someone who
     was not here; or (b) **strike it and name the control that replaces it** —
     explicitly, as a numbered entry in this list, not by implication. Until one of
     those happens, the Phase-8 deferral rests on **three** compensating controls, not
     four, and that reduced posture is the state of record.
     *(The "zero cross-site mis-merge" half is the load-bearing one and is the
     cheapest to re-baseline: it is a property, not a count, and it does not depend on
     the corpus size.)*
     **RULED 2026-07-23 (Robin): (a) RE-BASELINE — not (b) strike.** The reason is that
     **new input files are arriving**, so a dry-run gate is about to have live work to
     do; striking a control at the moment it becomes useful is the wrong trade. The
     control is therefore RESTORED to the list, and the Phase-8 deferral rests on four
     controls again **once the re-baseline numbers are recorded here** — until then it
     is still three, and this entry is the outstanding work item.
     **Two STANDING CAUTIONS, which apply to every dry run from now on and are part of
     the control, not advice about it:**
     - **A dry run has SIDE EFFECTS and poisons the following real run.** It is not
       read-only. **It runs on a COPY of the database, never on the live one** —
       `/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
       is not a valid dry-run target. Copy, run, read the residual off the copy,
       discard the copy.
     - **No work order already in the DB is ever re-ingested.** This is the F.10 policy
       and it binds the re-baseline too: the baseline is measured over the files whose
       work orders are NOT yet present, not over the whole archived corpus. A baseline
       taken by replaying loaded work orders measures the guard, not the resolver.
  2. the pre-cutover backup with recorded SHA-256;
  3. the cutover verification battery, every check of which must be able to fail;
  4. `change_log` provenance on every registry change, so corrections are
     reversible.
Rationale: code defects found later are cheap because fixing them does not cost
the database; wrong ROWS mixed into the 15,113 retained ones are not. The controls
above guard the rows, which is the risk Phase 8 was not the only thing protecting.

Work A shipped without a TDD audit. The audit confirmed its central claim empirically —
`.rc_feature_key` reproduces `.mig001_normalize` on **1989/1989** stored `alias_key`s,
and every mixed-key mutation was killed by existing tests — but found that adopting
`tolower(trimws())` silently dropped two hygiene properties `.rc_key` had. **Two
mutations survived the entire suite**, which is the six-times-repeated failure mode.

<!-- block: B-15.F1 -->
### F.1 Punctuation-only raw is no longer held (BLOCKING — data corruption)
`.rc_feature_key` guards `is.na(x) | k == ""` (reconcile.R:83) but not "no alphanumeric
character". `feature_raw = "."` or `"-"` therefore yields key `"."`, survives the A44
guard, and `commit_event()` materialises `feature_alias(alias_key = '.', kind =
'pending')` plus a sample against it. Under `.rc_key` these were held. Reproduced.
**Fix:** extend the guard to `!grepl("[[:alnum:]]", k)` → NA. **Test:** a `"."` raw is
held, and NO alias/sample row is written — assert the row counts, not just the status.

<!-- block: B-15.F2 -->
### F.2 Non-ASCII whitespace survives the trim (BLOCKING — duplicate samples)
`trimws()` does not strip NBSP (` `), `\v` or `\f`. `.rc_feature_key("T.S01 ")`
= `"t.s01 "`, which does not match `t.s01`, so commit creates a second alias **and a
second sample for a point that already exists**. A plain ASCII trailing space resolves
fine, so the failure is spelling-dependent and silent. Zero incidence in the 265-file
dry run (all 43 residual raws are clean ASCII) — latent, not active. **Fix:** Unicode-aware
trim plus `normalise_lab_text()`, matching what `.rc_key` already did. **Test:** the NBSP
variant resolves to the SAME feature as the clean string, with no new alias row.

<!-- block: B-15.F3 -->
### F.3 The migration-parity oracle is a tautology (BLOCKING — false-green gate)
`test-reconcile.R:851` re-declares `mig_normalize <- function(x) tolower(trimws(x))`
locally and compares `.rc_feature_key` against it — so it asserts a function equals its
own copy. Proof: mutating `.rc_feature_key` to `tolower(str_squish(x))`, a genuine
divergence from the migration, **survives the whole suite**. ~~**Fix:** `sys.source` the
real `.mig001_normalize` from `dev/migrations/001-alias-indirection.R` (the pattern
already exists at `test-migration-001.R:42`) and add discriminating inputs: `"B.  S01"`,
`" B.S01"`, `"B.S01\t"`.~~

**⛔ STILL UNBUILT, AND THE PRESCRIBED FIX NO LONGER WORKS — cold audit 2026-07-23,
finding 4. Two separate corrections:**

**(a) The "FOLDED INTO THE B/C IMPLEMENTATION PASS" claim at the head of Work F is
FALSE for F.3.** Verified: `tests/testthat/test-reconcile.R:851` **still** declares
`mig_normalize <- function(x) tolower(trimws(x))` locally, and `sys.source` appears
**0** times in that file. The tautology stands exactly as described. F.1 and F.2 did
ship; F.3 did not, and the sequencing note must not be read as evidence that it did.

**(b) The prescribed fix would now FAIL — because F.2 shipped.** F.2 deliberately
diverged `.rc_feature_key` from `.mig001_normalize`: it trims Unicode whitespace
(`trimws(..., whitespace = "[\\h\\v]")`) and routes the input through
`normalise_lab_text()` first (`R/reconcile.R:81-85`), neither of which
`tolower(trimws(x))` does. So a blanket "these two functions are equal" assertion now
fails on **exactly the input F.2 exists to handle**. This is not hypothetical: the
second discriminating input listed above is not a plain leading space — it is a
**leading NBSP** (`U+00A0`, bytes `c2 a0`, verified in this file's own source). The
prescribed oracle and the shipped fix are in direct contradiction on the very example
the plan chose, and whoever writes the test first will be tempted to "fix" it by
reverting F.2.

**RESPECIFIED. F.3 is two assertions, not one:**

### R-15.22 Alias-key parity over the stored domain
1. **Parity over the stored `alias_key` domain.** Assert `.rc_feature_key(k) == k` for
   **every** `alias_key` actually stored in `feature_alias` — i.e. against real
   `.mig001_normalize` output read from the DB, not against a locally re-declared copy.
   That is the property that actually matters (a key reconcile computes must find the
   row migration 001 wrote), and it is not a tautology: nothing in the test
   re-implements the normaliser. Still `sys.source` the real `.mig001_normalize` from
   `dev/migrations/001-alias-indirection.R` (the pattern already exists at
   `test-migration-001.R:42`), and keep the ASCII discriminating inputs `"B.  S01"` and
   `"B.S01\t"`, on which the two functions do agree.

### R-15.23 Explicit NBSP divergence assertion
2. **An EXPLICIT divergence assertion for the Unicode-trim direction.** Assert that the
   two functions **differ** on the NBSP-prefixed/suffixed input, and that
   `.rc_feature_key` is the one that folds it to the clean key. Written as an
   expectation of *difference*, F.2's divergence is documented and locked rather than
   left as a trap: a later revert of F.2 then fails this test loudly.
   **Do NOT write F.3 as unconditional equality over arbitrary inputs** — that
   assertion is false by design as of F.2.

<!-- block: B-15.F4 -->
### F.4 The collision oracle is a tautology (SHOULD-FIX — false-green gate)
`test-reconcile.R:856-862` asserts only that `.rc_feature_key(c("BS1","B.S1"))` has two
distinct values — a restatement of the function definition. The real hazard is at
RESOLUTION level: `bs1` is a curated `auto_assign=TRUE` alias for BH.S01 and no `bs01`
alias exists, so a naive longest-match on `BS01` lands in the opposite catchment.
**Fix:** this is fixture F2, which Work B's suite now adds (`TS1`→`TH.S01`); ~~assert
`.rc_feature_candidates` returns *different features* for the two strings.~~

**⛔ THE REPLACEMENT ORACLE IS ALSO SATISFIABLE BY THE HAZARD IT TARGETS — cold audit
2026-07-23, finding 17.** Measured against the shipped fixtures: `TS1` →
**TH.S01**, and `TS01` → **{}** (zero candidates). "Returns different features for the
two strings" is therefore already true — but it would be *equally* true of the broken
implementation this test exists to catch, in which `TS01` longest-matches to **T.S01**:
`TH.S01` ≠ `T.S01`, so a cross-site mis-merge passes the oracle. It is a weaker
tautology than the one it replaces, not a fix.

**RESTATED as two separate, positively-specified assertions — both required, in the
same test:**

### R-15.24 TS1 resolves positively to the TH feature
1. `.rc_feature_candidates("TS1", …)` resolves to **the TH feature** (`TH.S01`) — the
   positive control, which fails if the curated alias path is broken or the fixture is
   missing;

### R-15.25 TS01 returns zero candidates
2. `.rc_feature_candidates("TS01", …)` returns **ZERO candidates** — asserted as an
   empty result, and **never as "not equal to TS1's answer"**. This is the assertion
   that kills the longest-match mutation: `TS01` must not reach `T.S01`, must not reach
   `TH.S01`, must not reach anything.

Assert the identity of each result. Any oracle phrased as a *comparison between* the
two results is admissible only as an extra, never as the criterion.

<!-- block: B-15.F5 -->
### F.5 Review payload is order-dependent (SHOULD-FIX)
`.rc_feature_review` reads `cand <- cand_list[[g[[1]]]]` (**reconcile.R:580**) — the
first row of the group. Two rows sharing a key with different sample dates give
`candidates=f-0006|f-0007` old-first, and **no candidates at all** new-first.
Reproduced. **Fix:** take the union of `cand_list[g]`.

**The defect stated concretely (cold audit 2026-07-23, finding 19).** The two halves of
one payload use **different group semantics**, which is why this is a defect and not a
style point:

| line | reads | semantics |
|---|---|---|
| `reconcile.R:580` | `cand <- cand_list[[g[[1]]]]` | the **FIRST ROW** of the group — whatever that row happened to hold |
| `reconcile.R:582` | `st <- struct[g]; st <- st[!is.na(st)][[1]]` | the first **NON-NA** value **across the whole group** |

So the structural half already scans the group and the candidate half does not. Any fix
must make both halves agree on what "the group's value" means — the union for `cand`,
matching `struct`'s existing across-the-group behaviour — rather than fixing `cand`
alone and leaving two conventions in one function.

### R-15.26 Review payload order-independence for candidates
**Acceptance (must be able to FAIL):** build one group of two rows sharing an
`alias_key` with different sample dates, where only the LATER row's date narrows the
candidate set to empty. Assert the emitted payload carries **both** candidates, and
assert it is **byte-identical** with the two rows presented in each order. Against
today's code the new-first ordering emits no `candidates=` clause at all, so the test
fails before the fix — which is the point. A test that presents the rows in only one
order passes against the current implementation and tests nothing.

<!-- block: B-15.F6 -->
### F.6 Single-candidate suggestions are discarded — RULING REQUIRED, now made
`if (length(sugg) > 1)` (reconcile.R:461) drops a lone `auto_assign=FALSE` candidate, so
fixture `T.BORE` yields suggestion `f-0003` but an empty payload — the "suggestion
mechanism inert" failure the Cross-cutting section exists to fix. Mutating `>1` to `>=1`
**survives the entire suite**. **PINNED:** emit the single candidate as
`subkind=suggestion` (distinct from `subkind=ambiguous`, which requires ≥2 — one
candidate is not an ambiguity). This composes with E.3's `subkind=expired_alias`, which

### R-15.27 Single-candidate suggestion emits subkind=suggestion
likewise must emit at count 1. One test per branch: 0 → bare, 1 → `suggestion`,
≥2 → `ambiguous`.

**Measured exposure** (post-001 snapshot). The single-suggestion case arises almost
entirely through `.rc_narrow_live` collapsing an ambiguous key to one LIVE candidate:
**5 keys today** — `g182`, `g183`, `g184`, `g185`, `upstream` — each reach 2 distinct
features of which one is defunct, so at any date past that feature's `date_end` the
suggestion set is exactly 1 and is currently thrown away. That is the highest-confidence
case the mechanism produces, and it is the one case it drops. The other shape (>1 alias
row all pointing at ONE feature) has **0 instances** — that path is empty today.
After 003's 17-row flip, ~338 multi-target keys remain `auto_assign = FALSE` and parked;
for all of them the suggestion payload is the operator's only signal.
**No current dry-run residual item is affected** — the 43 `unknown_feature` items are 16
`feature_raw=NA` + 12 ambiguous-with-candidates + 15 descriptive-with-no-alias, none of
which is a single-suggestion case. This is a latent-correctness fix, not a residual fix.
`subkind` is write-only — nothing in `R/` parses it — so extending the vocabulary is free.

<!-- block: B-15.F7 -->
### F.7 Documentation drift (MINOR, but a trap for the Work B implementer)
- **STILL LIVE (re-verified 2026-07-23, cold audit finding 19).** The
  `.rc_resolve_existing_pending` roxygen at **reconcile.R:759** says the pending lookup
  is "the `feature_alias` row whose `alias_key == .rc_key(feature_raw)`"; the body at
  **reconcile.R:781** reads `k <- rows$alias_key[[i]]` (= `.rc_feature_key`). Since
  `.rc_key` strips punctuation and `.rc_feature_key` preserves it, the comment names a
  key that would match **zero** dotted aliases — it describes the exact bug PLAN-15
  exists to fix, as the documentation of the code that fixes it. This is the exact
  comment a B.4 implementer reads. Fix the roxygen, not the body.
- ~~reconcile.R:60 roxygen claims the guard covers "blank/whitespace-only" — true only
  for ASCII whitespace, and silent on punctuation-only (F.1).~~ **DONE — verified
  2026-07-23.** `R/reconcile.R:60-78` now states the guard returns NA for NA input, for
  input folding to empty, and for input "carrying NO alphanumeric character at all"
  (F.1), and documents the Unicode-aware trim (F.2) explicitly. No further action.
- **Three** feature keys now coexist: `.rc_feature_key` (alias/grouping),
  `.rc_key` (lab-method + analyte), and `.st_normalise_key` = `tolower(str_squish())`
  (assemble.R:74, joining samples↔results). Assemble therefore treats `"T  S01"` and
  `"T S01"` as one sample while reconcile keys them apart. Not necessarily wrong;
  undocumented and untested. Add a comment naming all three and their scopes.

**Acceptance (must be able to FAIL).** Added 2026-07-23 (cold audit, finding 19): F.7
carried no acceptance line while six other F items did, so there was nothing to stop it
being marked done on inspection. A documentation defect still needs a falsifiable gate:

### R-15.28 Roxygen no longer cites stripping .rc_key
- assert the `.rc_resolve_existing_pending` roxygen contains **no** occurrence of
  `.rc_key(feature_raw)` and **does** name `.rc_feature_key` / `alias_key` — a
  grep-style assertion over the source file, which fails against today's source;

### R-15.29 Three-key comment names all three normalisers
- assert the three-key comment exists and names all three of `.rc_feature_key`,
  `.rc_key` and `.st_normalise_key`. A test that merely checks *a* comment is present
  passes against a comment naming two of them.
Both are cheap and both fail on current source, which is the bar.

<!-- block: B-15.F8 -->
### F.8 Pre-Work-A pending aliases have no upgrade path (NOTE — not currently triggerable)
A DB committed under the old key holds `alias_key = 'bs01'` where reconcile now computes
`'b.s01'`; the lookup misses, a new alias is created, and `.rc_find_existing` then
double-commits. **Verified not reachable today: both the post-001 snapshot and the
dry-run DB hold ZERO dangling aliases.** Record the precondition — "no pending aliases
exist" — and re-check it before any live commit, or write a migration.

<!-- block: B-15.F9 -->
### F.9 `add_feature()` leaves a post-001 feature unreachable by its own name (SHOULD-FIX)
**⚠ SEQUENCING, pinned 2026-07-23 (cold audit, finding 8): F.9 MUST LAND BEFORE
MIGRATION 003.** Not a preference — a hard dependency, and it is also more than the
"follow-up" the next line calls it. `add_feature()` (`R/mutate.R:452-475`) appends to
`feature` and nothing else, so **any `add_feature()` call between now and 003 makes 003
UNRUNNABLE**: 003 asserts every feature has a `self` alias and aborts otherwise
(E.3/E.6), and the new feature has none. The precondition holds today only because
nobody has called it since the cutover; nothing enforces that, and D.1 shows features
do get added by hand.
Second, quieter consequence: **`.rc_self_alias()` (`R/reconcile.R:376`) returns NA for
such a feature**, and B.6 pins that a Layer-2 structural hit whose target has no
self-alias goes to REVIEW rather than committing with a NA alias. So a feature added
via `add_feature()` is **silently inert to Work B Layer 2** as well — it can never be
structurally resolved, and the failure presents as "the resolver didn't fire" with no
error anywhere. F.9 is a prerequisite of Work B's correctness, not only of 003's
runnability.

**Robin, 2026-07-23: build this as a follow-up.** `add_feature()` inserts a `feature`
row and nothing else. Post-migration-001, `sample.uuid_feature_alias` is the ONLY path
from a sample to a feature, and 001 gave every then-existing feature a `kind = 'self'`
alias. A feature created *after* 001 has none — so `.rc_feature_candidates()` finds
zero candidates for the feature's own canonical name, and every future row for it lands
in review as `unknown_feature`, **forever and silently**. The failure is invisible at
creation time: `add_feature()` returns success and the row is really there.

Fix: `add_feature()` must create the `self` alias in the same transaction as the
`feature` row, with `change_log` provenance for both. The invariant to assert is
`count(feature_alias WHERE kind='self') == count(feature)`.

Interim controls already in place, do not mistake them for the fix: `registry-changes.R`
carries `cutover_add_bl05_self_alias()`, which closes this for B.L05 **only**, and
`dev/cutover/verify.R` V02 asserts the general invariant at cutover time — which
detects a recurrence but does not prevent one.

### R-15.30 add_feature() creates self-alias, resolves by name
Acceptance (must be able to FAIL): create a feature via `add_feature()`, then reconcile
a row carrying exactly that feature's canonical name, and assert it RESOLVES rather than
queueing as `unknown_feature`. A test that only counts `feature_alias` rows passes
against a wrong implementation that writes an alias of the wrong `kind`.

<!-- block: B-15.F10 -->
### F.10 Work-order-level re-ingest guard (APPROVED — Robin, 2026-07-23)
**Why this exists:** the legacy corpus cannot be matched by the reuse path (see the
cutover runbook F2 — `already_present` is 0 of 6,725 rows), and Robin's ruling that
`sample.datetime` must not be touched forecloses the migration that would have restored
idempotency. So "never re-ingest a work order that is already in the DB" is a standing
policy, and policy enforced by operator discipline is exactly what failed when correct,
well-intentioned re-downloads were staged into `assets/input`.

Build: before commit, a file whose work order already has `sample` rows is **routed to
review, not committed**. It must be a positive check against the DB, not a filename or
`ingest_file` check — the re-download case had new filenames for already-present data.

**⛔ AS WRITTEN, THIS BLOCKS TWO PATHS THAT MUST KEEP WORKING — cold audit 2026-07-23,
finding 5.** "A work order that already has `sample` rows" is the *precondition* of the
A12 revision-supersede path and of the `already_present` reuse path, so a guard that
routes on that precondition alone forecloses both. Both are real, shipped code:

| path | function | what it needs |
|---|---|---|
| reuse / `already_present` | `.rc_find_existing` (**reconcile.R:1009**) | matches an incoming row against a sample ALREADY in the DB — it exists only for work orders that are already loaded |
| A12 revision supersede | `.rc_recorded_revision` (**reconcile.R:1067**) | reads the revision already recorded for this work order, in order to accept a HIGHER one |

**PINNED EXEMPTIONS — decide these BEFORE building the guard, not after** (see the
sequencing table at the head of Work F):
1. **A higher-revision file for an already-loaded work order is EXEMPT** and proceeds
   to the normal A12 supersede path. This is the case F.10 must not catch: a corrected
   lab re-issue is the legitimate reason to re-ingest a loaded WO.
2. **Rows that resolve to `already_present` are EXEMPT** — they are the idempotency
   mechanism, and blocking them converts a harmless no-op re-ingest into a review item.
3. What F.10 actually blocks is narrower than its title: **a same-or-lower-revision
   file, under a different name, carrying rows that do NOT match existing samples** —
   which is precisely the re-download case that motivated it.

### R-15.31 Higher-revision file for loaded WO commits
**Paired acceptance criterion (must be able to FAIL), in addition to the one below:**
ingest a work order, then ingest a **higher-revision** file for that same work order,
and assert it **COMMITS** (the supersede runs; assert the superseded rows' end state,
not merely the absence of a review item). A test that only asserts the blocking half
passes against an implementation that blocks everything — which is the failure mode
this exemption list exists to prevent.

Measured 2026-07-23 (copy of the authoritative DB): of the 104 work orders of record in
`assets/input`, **96 already have `sample` rows, 8 do not, and NONE is partially
loaded** — every work order is wholly present or wholly absent. That last fact is what
makes a work-order-granularity guard correct rather than too coarse; **re-verify it
before relying on it**, because a partially-loaded work order would be silently blocked
by this guard.

### R-15.32 Re-download of loaded WO blocked, routed to review
Acceptance (must be able to FAIL): ingest a work order, then ingest a *differently named
file* carrying the same work order, and assert zero new `sample`/`analysis` rows plus a
review item. A test that re-ingests the identical path may pass via hash dedup instead
and would not exercise the guard at all.

<!-- block: B-15.F11 -->
### F.11 Drop `sample.date` (APPROVED — Robin, 2026-07-23; `date_start` NOT approved)
Robin: *"The date columns probably shouldn't exist at all. They were always just copies
of datetime with the time removed."*

**Premise verified for `date`, 2026-07-23.** Reading both columns as UTC-naive and
taking the Sydney calendar date, `date` and `datetime` agree on **15,107 of 15,111**
rows. The 4 exceptions are data errors, not semantics — two are exactly one month apart
(`2022-10-18` vs `2022-11-18`; `2022-10-11` vs `2022-11-11`, i.e. a month typo) and two
are one day apart. Resolve those 4 explicitly rather than letting the drop silently pick
a winner.

~~**⛔ BLOCKING, found during the 2026-07-23 cutover ingest: the premise DOES NOT
HOLD for newly ingested rows.** Of the 36 samples committed by the first real
ingest, **35 have `datetime` NULL and `date` populated**. Only the single ESdat
row carries a `datetime`.~~ **STRUCK 2026-07-23 (cold audit, finding 10): the blocker
is STALE and its headline number is no longer the live state.** Re-measured against the
live registry: **2 of 15,149** samples have a NULL `datetime`. The "35 of 36" figure
described one ingest batch at one moment, before the 10:00 substitution recorded in
F.13 was applied to those very rows — quoting it as the state of the database
overstates the exposure by three orders of magnitude, and a blocker phrased that way
invites the wrong fix.

The *reasoning* underneath it survives and is unchanged: the ALS `ENMRG` and `XTAB`
sources are **date-only** — their header literally reads `Sample date:,01/04/2026` with
no time — so the adapter has no time to store. `date` is therefore not automatically
redundant going forward, and the column stopped being a pure copy of `datetime` the
moment a date-only adapter was added.

~~**F.11 therefore cannot proceed as written.** The options, needing a ruling:
(a) keep `date` and fix its convention instead (one migration, no code change);
(b) have date-only adapters write `datetime` at local midnight …; or (c) add an
explicit `time_known` flag and drop `date`. Do not start F.11 until this is settled.~~

**REPLACED: F.11 is BLOCKED ON F.13 — option (c) was chosen.** The ruling was made,
and F.13 records it: date-only sources get the 10:00 substitution (applied, 35 rows)
plus an explicit `time_known` boolean, after which `sample.date` carries no information
`datetime` + the flag does not. **F.11 has no open ruling of its own; it has a
dependency.** Do not re-open the (a)/(b)/(c) choice, and do not start F.11 before F.13
lands. F.13's own closing paragraph already states this from the other side.

**Premise NOT verified for `date_start`. Do not drop it in the same pass.**
`date_start` vs `datetime_start` **disagree on 223 of 15,066** rows, and 45 rows have a
NULL `date_start` with a non-NULL `datetime_start`. Something other than
time-truncation is going on; it needs its own investigation first.

**"Nothing relies on them" is not correct** — this is the part that makes it real work,
and it must not be done as a bare `ALTER TABLE ... DROP COLUMN`:

| Consumer | What it does with `sample.date` |
|---|---|
| `R/reconcile.R:1031` | `.rc_find_existing()` reuse match — `CAST(s.date AS DATE) = ?` |
| `R/commit.R:331,339` | `.ct_find_or_create_sample()` reuse match — both branches |
| `R/feature-alias.R:116,125,159` | `(feature, date)` collision detection and the D5 merge rule |
| `R/assemble.R:151` | the A45 identity key `(feature, date, analyte, method)` |
| ~~6 DB views~~ **ONE DB view** | ~~`v_feature_dates`, `v_measurement`, `v_measurement_epa`, `v_measurement_gas_report`, `v_measurement_long`, `v_measurement_old`~~ → **`v_feature_dates` only** |

**View count CORRECTED 2026-07-23 (cold audit, finding 11).** Every non-internal view's
SQL was inspected: **only `v_feature_dates` references a date token at all.** The
`v_measurement_*` and `v_analyte_*` views do **not** — which is not a surprise once
F.12(b) is read alongside it: 001's rebuild GUTTED those projections down to five
columns, and `date` was one of the casualties. So the five extra views in the old list
were listed on their PRE-001 shape.
**F.11 rebuilds ONE view, not six.** That materially shrinks F.11 — and it is also a
trap, because it means the `v_measurement_*` views will re-acquire a `date` dependency
the moment F.12(b) restores their projections. See F.12: F.11 must land FIRST.

Each R-side consumer must first be switched to the Sydney calendar date **derived from
`datetime`**, and `v_feature_dates` rebuilt, before the column is dropped. Note DuckDB
will generally refuse to drop a column a view depends on, so a bare drop fails loudly
rather than silently — but the R-side consumers have no such protection and would
simply error at runtime.

**Worth doing for its own sake:** this removes the day-early landmine permanently.
`CAST(date AS DATE)` is one day earlier than the true local date for **every** legacy
row (all 15,111 non-NULL values are 13:00 or 14:00), which has already produced an
off-by-one in curated date literals once. It also eliminates cause 1 of runbook F2 —
though **not** cause 2, so it does not remove the need for F.10.

### R-15.33 Reuse-match on legacy-convention date matches
Acceptance (must be able to FAIL): a reuse-match test seeded with a legacy-convention
row (`date` at 14:00, `datetime` at the real instant) that asserts an incoming row for
the same local date MATCHES. Against today's code that test fails, which is the point —
if it passes before the change, it is not testing the right thing.

<!-- block: B-15.F16 -->
### F.16 Reporting-limit residue after the 2026-07-23 `rl_low` correction (RESOLVED 2026-07-23)
**The convention (Robin, 2026-07-23):** *"Where a value is BDL its value is set
as the reporting limit and then quantified is set to FALSE."* ~~So for every
`quantified = FALSE` row, `value == rl_low` must hold. That is now a testable
invariant and should become an assertion, not folklore.~~

**⛔ SELF-CONTRADICTION, RESTATED 2026-07-23 (cold audit, finding 14).** As written,
this section pinned `value == rl_low` as "a testable invariant" here and then, ~20 lines
below, ruled that *"`value <> rl_low` on a BDL row is therefore NOT automatically an
error — it is the signature of a raised reporting limit."* Both cannot be assertions.
Anyone implementing the first one breaks on live data; anyone reading only the second
concludes there is no invariant at all.

**THE INVARIANT, RESTATED — this is the version to assert:**

> **`quantified = FALSE` ⇒ `value >= rl_low`.**

`value` is the *effective* reporting limit for that result; `rl_low` is the method's
*nominal* LOR (established by source tracing, below). A lab may RAISE a limit for one
sample — dilution, matrix interference — so `value > rl_low` is legitimate. A lab
cannot report a non-detect BELOW its own method LOR, so `value < rl_low` is the
violation, and that is the only direction the assertion may fail in.

**Measured on the live registry, 2026-07-23 (post-correction).** The comparison is only
defined where **both** `value` and `rl_low` are non-null: that set is **35,174** rows.
Of those, **232 have `value > rl_low`** (legitimate raised limits) and **0 are below**.
The invariant holds on live data with zero exceptions.
**Do NOT use 47,227 as the denominator** — that is the count of *all* `quantified =
FALSE` rows, most of which have a NULL on one side and for which the comparison is
undefined. An assertion written over 47,227 rows is testing NULL-handling, not the
convention.

**Fixed 2026-07-23:** 3,190 rows carried `rl_low` exactly 1000× `value` — the RL
left in µg/L while the value was converted to mg/L. All 3,190 were legacy (none
written by sampleTidy), all on `mg/L` analytes, and all on organics whose
canonical ALS reporting limits confirm the reading (benzene 0.001 mg/L = 1 µg/L,
xylene 0.002 = 2, TPH-C6-C9 0.020 = 20, TRH-C11-C16 0.100 = 100). Corrected by
`/1000` through `db_update()`, each with `change_log` provenance.

**What `rl_low` actually holds — established by source tracing, 2026-07-23.**
It is the **method LOR**, not the per-result reporting limit. The ALS ENMRG
layout has a literal `LOR` column (column 4 of the analyte block) carrying the
method's nominal limit, while each sample's own cell carries that result's
reported limit (`"<0.10"`). When a lab raises the limit for one sample —
dilution, matrix interference — the two legitimately differ.

So under Robin's convention (BDL ⇒ `value` = the reporting limit), **`value` is
the effective limit for that result and `rl_low` is the method's nominal one.**
`value <> rl_low` on a BDL row is therefore NOT automatically an error — it is
the signature of a raised reporting limit. That reclassifies the residue:

> **⚠ THE TABLE AND DIAGNOSIS THAT FOLLOW, DOWN TO THE "RESOLVED" HEADING, ARE
> SUPERSEDED.** Marked explicitly 2026-07-23 (cold audit, finding 14) rather than left
> inline: the "Suspect / needs per-analyte source tracing" verdict below was
> investigated, disproved and ACTED ON — all 477 rows are fixed. It is retained only as
> the audit trail of a wrong diagnosis. **Nobody may plan work from it.** The live
> figures are the 35,174 / 232 / 0 stated at the top of F.16.

| Symptom | Rows | Origin | Verdict (SUPERSEDED) |
|---|---|---|---|
| BDL, `value > rl_low` — raised reporting limit | 110 | 109 legacy, 1 ours | **Legitimate. Not a defect.** (this row still stands) |
| ~~BDL, `value < rl_low` — reported below the method's own LOR~~ | ~~122~~ | ~~all legacy~~ | ~~**Suspect.**~~ → **A1**, FIXED — see below |
| ~~`quantified = TRUE` but `rl_low > value`~~ | ~~355~~ | ~~all legacy~~ | ~~**Suspect.**~~ → **A2**, FIXED — see below |

**The `A1` / `A2` labels, defined here** (they were previously used below without ever
being introduced in this document, and were resolvable only by opening
`dev/EDA-rl-quantified-2026-07-23.md`):
- **A1** = the 122 BDL rows with `value < rl_low` — non-detects whose source cell was
  an `<x` string.
- **A2** = the 355 `quantified = TRUE` rows with `rl_low > value` — real detections
  whose source cell was a bare number.
- **A1 + A2 = the 477 rows**, and they are ONE bug, split only by the shape of the
  source cell (see the RESOLVED block below).

**The one row that is ours is CORRECT and needs no fix.** Traced in full:
analysis `9b2a834c…`, Fe(III) on B.MW02, work order ES2610538, source
`ES2610538_0_ENMRG.CSV` (sha256 `d836009f…`, the same hash recorded on the
`change_log` row). Line 52 of that file reads

```
"Ferric Iron",,mg/L,0.05,,"<0.10","<0.05","<0.05",----,----,----,----
```

LOR `0.05`; B.MW02 is the first sample column and its result is `<0.10` — the
only raised limit in the entire file. We stored `value = 0.10`, `rl_low = 0.05`,
`quantified = FALSE`, which is faithful to both quantities. **The ingestion is
right; the earlier "adapter took them from different columns" suspicion was
wrong — it takes them from different columns because they ARE different
quantities.**

~~The 122 + 355 suspect rows are a different shape: e.g. every `EP075(SIM)A:
Phenolic Compounds` result at `value` 0.0048 against an `rl_low` of 1 — a
reported result 208× *below* its own stated LOR. Ratios are non-decimal
(208.333, 50, 100, 250…), so no single conversion explains them; they need
per-analyte source tracing against the original lab reports.~~ **← END OF THE
SUPERSEDED SECTION. Every clause struck above was disproved; see immediately below.**
(The one instruction that survives: do **not** "fix" such rows by forcing
`value = rl_low` — that would fabricate reporting limits, and it remains true.)

**RESOLVED 2026-07-23 — the diagnosis above was WRONG and the 477 rows are fixed.**
A sub-agent EDA (`dev/EDA-rl-quantified-2026-07-23.md`), independently verified,
established that all 477 are **one bug**: `rl_low` held the method LOR in
**µg/L** while `value` was correctly converted to **mg/L**.

* `analysis.rl_low / lab_method.rl_low` = **exactly 1000** on 440 rows and
  **100** on 4 CFU rows. The non-suspect population sits at **1.00** (67,452 rows).
* The "208× below its own LOR" anchor example **collapses**: those are ALS's
  `<4.8 µg/L` cells on leachate, i.e. a 4.8× *raised* limit. 208.333 is just
  `1/0.0048`, an artefact of comparing µg/L to mg/L. The "non-decimal ratios that
  no conversion explains" were never real.
* A1 and A2 are the same phenomenon, split only by whether the source cell was
  `<x` or a bare number.
* **Why the 3,190-row fix missed them:** its predicate required
  `old_rl == 1000 * value` exactly, which only ever matches a non-detect reported
  AT the nominal LOR. It structurally cannot catch a raised limit (A1) or a real
  detection (A2). A worked lesson in a gate that looks total and is not.

Applied through `db_update()` (477 change_log rows): `rl_low = lab_method.rl_low`
where a reference existed — the divisor is **100, not 1000, for the CFU rows**, so
a blanket `/1000` would have been wrong — and `/1000` for the 33 rows with no
`lab_method` reference, all mg/L phenols/TRH carrying `rl_low = 1`. Zero
contradictory rows remain.

**Correction to the sub-agent's report:** it called these "not legacy" from sample
dates running to 2026-03. Sample date is not write time. **0 of 477 have
`change_log` provenance**, so none were written by sampleTidy; the legacy system
was ingesting until the cutover. This is legacy repair, not an active adapter bug.

**Still open (deliberately not widened):** 28 further rows carry the same
ratio-100/1000 signature but are not internally contradictory (`value > rl_low`
already holds), so they were left alone rather than swept in. They are very
probably the same bug and worth a ruling.

**Also confirmed 2026-07-23:** `rl_high` is NULL for **all 97,118** rows, so
nothing reads it and R-11.16/F4's write path has never been exercised against
real data.

**Related `quantified` note — RESOLVED 2026-07-23, see PLAN-CHANGE-REQUESTS.md.**
Ruled by Robin: `quantified` is NA for every text result, because a qualitative
observation is not a measurement. The live data was already correct (all 315 NA;
**zero** rows with `value_chr` set and `quantified` non-NULL) — only the write
path was wrong, in `R/values.R` (text → TRUE) and `R/commit.R` (`isTRUE()`
collapsing NA → FALSE). Fixing it exposed a genuine defect in
`.rc_values_equal()`, which treated NA as unmatchable and so would have
**re-committed** any re-ingested qualitative observation. 23 of the 315 rows
record that no sample was taken, which is why TRUE was the dangerous option.

<!-- block: B-15.F13 -->
### F.13 `time_known` flag on `sample` (FILED FOR LATER — Robin, 2026-07-23)
Robin: *"Where time is unknown set it to 10am (since that is a best guess). Your
no time col is a good idea, file that for later."*

The 10:00 substitution is now applied (35 rows, 2026-07-23) and is the standing
rule for date-only sources, but it is **lossy**: a genuine 10 a.m. sampling is
now indistinguishable from "no time recorded". That is exactly the ambiguity
that made the 2,046 legacy `00:00` rows unresolvable and killed the F.11
migration route. Adding an explicit boolean stops it recurring:

- `ALTER TABLE sample ADD COLUMN time_known BOOLEAN` (plain ADD COLUMN).
- Adapters set it TRUE when the source carried a clock time, FALSE when the
  substitution fired. Backfill: FALSE for the 35 rows carrying the 10:00
  substitution (identifiable from `change_log` — reason "unknown sampling time
  set to 10:00 local"), TRUE elsewhere where `datetime` is non-NULL.
- Once it exists, A62's "provably distinct" test should consult it: two rows
  both `time_known = FALSE` are NOT provably distinct however their clocks read.

This also unblocks F.11 — with `time_known` recorded, `sample.date` carries no
information `datetime` + the flag does not, and can finally be dropped.

<!-- block: B-15.F14 -->
### F.14 `confirm_analyte_methods()` fails on any method that has analyses (DEFECT)
Found 2026-07-23 confirming the ALS SAR method (12 analyses): it aborts with
`Constraint Error: ... still referenced by a foreign key in a different table`.
`lab_method` is both an FK child of `analyte` and an FK parent of `analysis`, and
duckdb 1.4.1 refuses to UPDATE a chained-FK table's own outgoing-FK column while
anything downstream references it — the identical limitation migration 002
documents at `.mig002_detach_reason`.

So the function works **only for a zero-referenced dangling method**, which is
the rare case; the normal case — a method that arrived with data — always fails.
The transaction rolls back cleanly, so it is loud, not silent.

The SAR confirmation was completed by hand using 002's detach → repoint →
reattach loop through `db_update()`, tagged with 002's exact reason suffixes so
`.mig002_torn_guard()` can still detect a torn run. Verified after: 12 of 12
analyses reattached, zero orphans.

### R-15.34 confirm_analyte_methods succeeds with dependent analyses
Fix: fold that loop into `confirm_analyte_methods()` itself. Acceptance (must be
able to FAIL): confirm a method **with** dependent analyses and assert both that
`lab_method.uuid_analyte` moved AND that every dependent analysis still points
at the same `lab_method`. A test using a zero-referenced method passes against
today's broken code.

**ADJUDICATED 2026-07-24 — the fix CANNOT honour this file's one-transaction
contract, and that is a deliberate, guarded exception.** `R/feature-alias.R:13-14`
documents that both `confirm_*` functions "open exactly one mutation-layer
transaction per call ... an error on item N rolls back items 1..N-1 too". A Phase-4
writer reproduced (twice, on a purpose-built FK-constrained DuckDB) that the chained-FK
constraint fires **even inside a single transaction**, so the detach → repoint →
reattach steps must be separately committed statements. That is corroborated by
precedent rather than taken on report: migration 002 already does exactly this
non-transactionally, and `.mig002_torn_guard()` (`002:119`) exists *because* the
pattern cannot be atomic.

RULING: the has-dependents path adopts 002's loop verbatim, tagged with 002's reason
suffixes, and gains a torn-state guard modelled on `.mig002_torn_guard()` so a run
interrupted mid-repoint ABORTS LOUDLY on re-entry instead of silently "succeeding".
The one-transaction contract in `feature-alias.R` gains an explicit documented
exception for this path only. The alternative — leaving `confirm_analyte_methods()`
broken for every method that has analyses — is the status quo defect this item exists
to remove, and the guard is what preserves the safety the contract was protecting.

**FIXTURE GAP, recorded for the implementer:** `tests/testthat/helper-db.R` declares
**zero** `REFERENCES` clauses — the shared test DDL has no foreign keys at all
(verified: `grep -c REFERENCES` is 0). A test for this item built on the shared
fixture therefore FALSE-GREENS, because the constraint that defines the defect does
not exist there. The Phase-4 test carries its own local FK-constrained database for
this reason. Do not "simplify" it back onto the shared fixture.

The wider gap — that the shared fixture cannot catch ANY foreign-key defect — is a
real test-suite fidelity limit, not specific to this item. It is out of scope here and
is recorded in run-state for Phase 5 rather than fixed under a single unit.

<!-- block: B-15.F15 -->
### F.15 `review_queue` items have no close path (DEFECT — found 2026-07-23)
After `confirm_feature_aliases()` and `confirm_analyte_methods()` resolved every
pending alias and method (`pending_features()` 0, `pending_analytes()` 0), the
four `review_queue` rows that raised them **stayed `status = 'open'`**. `R/mutate.R:583`
exposes `review_queue(con, status)` as a READER only; nothing anywhere writes
`status`. So the queue accumulates permanently-open items for work that is done,
and its open count stops meaning anything — a monitoring signal that only ever
grows is not a signal.

Fix: close (or supersede) the originating review item when the confirmation that
resolves it succeeds, in the same transaction. Acceptance (must be able to FAIL):
open an item, confirm its alias, assert the item is no longer `open` **and** that
an unrelated open item is untouched.

> **RULING — Robin, 2026-07-24: option (a), a `uuid_target` column. F.15 IS UNBLOCKED.**
> The full design is pinned in "THE PINNED DESIGN" below, and F.15's acceptance is now
> writable as R-15.38 … R-15.43. The ⛔ block that follows is kept as the *record of why*
> the ruling was needed — it is history, not a live blocker.
>
> One correction to the ⛔ text below, found while pinning the design: it says the alias
> uuid "does not yet exist" when the review item is written. True at *reconcile* time, but
> **commit already resolves it** — `.ct_rewrite_review_payloads()` (`R/commit.R:243`,
> called at `R/commit.R:737`) builds `amap`, a `source_ref` → freshly-created
> `feature_alias.uuid` map, and appends an `,alias_uuid=<uuid>` token to the payload
> *before* `.ct_commit_review()` inserts the row (`R/commit.R:749`). So the linkage is
> already computed at exactly the right moment; option (a) moves it out of free text and
> into a column. That is why (a) is cheap and why (b) was never really "no migration" —
> the payload grammar is **already** load-bearing here.

**⛔ NOT IMPLEMENTABLE AS SPECIFIED — cold audit 2026-07-23, finding 20. A PREREQUISITE
DECISION IS MISSING.** *(Superseded by the ruling above; retained as rationale.)*
"Close **the originating** review item" presumes the code can
identify which item a given `feature_alias` raised. It cannot: **`review_queue` has no
column linking an item to the `feature_alias` it raised**, and — this is the part that
makes it a schema problem rather than a query problem — **it cannot acquire one at
insert time either.** Reconcile is read-only (CONTRACT A32) and the review item is
emitted *before* commit materialises the dangling alias, so at the moment the item is
written the alias uuid does not yet exist. The only thing the item carries is the
free-text `payload`.

**PIN THE LINKAGE DECISION BEFORE BUILDING F.15** (sequencing table, head of Work F).
The options, needing a ruling:
- **(a) add a `uuid_target` (or `alias_key`) column to `review_queue`** and have commit
  back-fill it when it materialises the alias — the clean answer, and it makes the
  linkage explicit and queryable, at the cost of a schema migration and a write on a
  path that currently does not touch `review_queue`;
- **(b) pin a JOIN key instead** — `(kind, work_order, alias_key-parsed-from-payload)`
  — no migration, but it makes the payload's grammar load-bearing, which today it is
  not (`subkind` is write-only; nothing in `R/` parses a payload). Choosing (b) means
  the payload format becomes a contract and needs its own tests.

Note the second half of the same defect is independent of the linkage and is real
either way: **nothing anywhere writes `review_queue.status`** — `R/mutate.R:583` exposes
`review_queue(con, status)` as a READER only. A writer has to be built regardless of
which option is chosen.

#### THE PINNED DESIGN (ruling (a), 2026-07-24)

**D1 — the column.** A new `.st_schema_migrations` entry, `version = 5L`, whose entire
DDL is `ALTER TABLE review_queue ADD COLUMN IF NOT EXISTS uuid_target VARCHAR`.
**Do NOT retro-edit the `version = 3L` CREATE TABLE** (`R/db-schema.R:41`): a database
already at version ≥ 3 never re-runs it, so editing it makes fresh and existing
databases diverge. Nullable, no FK — `review_queue` is an ops table, and a FK here would
make it block deletes on the registry it only observes.

`uuid_target` is **generic**: `kind` is what says which table it points at. The mapping,
which is part of this contract:

| `kind` | `uuid_target` points at |
|---|---|
| `unknown_feature` (and any pending-alias kind) | `feature_alias.uuid` |
| `value_conflict` | the losing `analysis.uuid` |
| `units_drift` | `lab_method.uuid` |
| `unknown_unit` | `analysis.uuid` |
| anything else / not yet linked | `NULL` |

Only the first row is **built** under F.15. The other three are the pinned meaning for
when those call sites are back-filled; back-filling them is explicitly **out of scope**
here, and leaving them `NULL` is correct, not a defect.

**D2 — the write path (commit).** `.ct_rewrite_review_payloads()` already computes
`amap`. Extend it to set a `uuid_target` column on the returned `review` tibble from the
same map, and have `.ct_commit_review()` (`R/commit.R:638`) carry that column into the
INSERT. **Keep writing the `,alias_uuid=` payload token** — it is the only linkage
pre-migration rows will ever have, and dropping it would strand them.

**D3 — the centralised writer.** `review_queue_add()` (`R/db-schema.R:292`) gains an
optional `uuid_target = NA_character_` parameter, so the one sanctioned INSERT path can
express the linkage. Its existing callers pass nothing and keep working.

**D4 — the close path.** A new writer in `R/db-schema.R`, symmetric with
`review_queue_add()` and for the same reason (so `review_queue` UPDATEs never scatter as
raw SQL):

```r
review_queue_close(con, uuid_target, resolution, resolved_by)
#   UPDATE review_queue
#      SET status = 'resolved', resolution = ?, resolved_by = ?, resolved_at = ?
#    WHERE uuid_target = ? AND status = 'open'
#   returns the number of rows closed, invisibly
```

The terminal status is pinned as **`'resolved'`** — nothing writes `status` today so
there is no precedent to honour, and `'resolved'` is the value the existing
`resolution` / `resolved_by` / `resolved_at` columns were named for.

**D5 — the call site.** `.fa_confirm_one_alias()` (`R/feature-alias.R:77`), immediately
after its `db_update(con, "feature_alias", uuid_alias, ...)` (`R/feature-alias.R:138`)
succeeds and inside the same transaction, calls
`review_queue_close(con, uuid_target = uuid_alias, resolution = "confirmed", resolved_by = confirmed_by)`.

**D6 — the NULL trap.** A `NULL`/`NA` target must close **nothing**. SQL makes
`WHERE uuid_target = NULL` never true, so the danger is entirely on the R side: a target
of `NA_character_` interpolated as the literal string `"NA"` would match nothing today
but would match a row the moment anything ever wrote `"NA"`. `review_queue_close()` must
return early on a missing/`NA` target rather than rely on SQL's NULL semantics to save it.

**Acceptance (each must be able to FAIL):**

### R-15.38
- `ensure_schema()` on a pre-version-5 database adds `uuid_target` to `review_queue`;
  rows that existed before read `NA`; a second `ensure_schema()` is a no-op (version 5
  is recorded once in `schema_version`, and the ALTER is not re-attempted).

### R-15.39
- Committing an event with a pending feature writes a `review_queue` row whose
  `uuid_target` **equals the `feature_alias.uuid` created by that same commit** — not
  merely non-`NA`. A review row that is not a pending-feature row has `uuid_target` `NA`.

### R-15.40
- `review_queue_close()` closes exactly the matching open rows: `status` becomes
  `'resolved'` and `resolution` / `resolved_by` / `resolved_at` are populated; **an
  unrelated open item with a different `uuid_target` is untouched**; and a second
  identical call closes **zero** rows (idempotent, because the first left none `open`).

### R-15.41
- `review_queue_close()` with a `NA`/missing target, or a target matching no row, closes
  **zero** rows and does not error. A row with `uuid_target IS NULL` is never closed by
  any call. (D6.)

### R-15.42
- End-to-end, the original F.15 acceptance: open an item, confirm its alias via
  `confirm_feature_aliases()`, assert the item is no longer `open` **and** that an
  unrelated open item is untouched.

### R-15.43
- A confirmation that **aborts** leaves the review item `open` — the close is inside the
  confirmation's transaction, so there is no state where the alias is unconfirmed but its
  review item is closed.

<!-- block: B-15.F12 -->
### F.12 Migration 001 broke the reporting views (DEFECT — found 2026-07-23)
Two separate problems, both introduced by 001's view rebuild and both invisible
until something tried to *read* the views.

**(a) `v_measurement_epa` returns ZERO rows.** 001 rebuilt it filtering
`fm.variant = 'epa'` — lowercase — while `feature_mask.variant` stores `'EPA'`.
Measured on the post-001 rehearsal DB: `v_measurement` 95,739 rows,
`v_measurement_epa` **0**. It does not error; it silently returns nothing, which
is the worst available failure mode for a regulatory report. Check the other
masked variants (`_old`, `_long`, `_gas_report`) for the same case mismatch.

**(b) The rebuilt views are GUTTED.** Pre-001 `v_measurement` had 21 columns
including `date`, `datetime`, `analyte_name`, `analyte_units`, `site`,
`feature_flow`, `lon`/`lat` and the RL columns. Post-001 it has **five**:
`uuid_analysis, uuid_sample, uuid_feature, feature_name, value`. The rebuild
preserved the join topology (correctly rerouting through `feature_alias`) but
dropped most of the projection. Any consumer that selected a dropped column now
errors, and any consumer that only counted rows sees nothing wrong.

001 is pinned and already applied — do **not** edit it. This is a follow-up
migration that restores the projections and fixes the variant case. ~~Fold it into
the F.11 work, since F.11 has to rebuild the six `date`-referencing views anyway.~~

**⛔ FOLD-IN RATIONALE IS FALSE, AND THE ORDER IS THE OPPOSITE — cold audit 2026-07-23,
finding 12.** Two things are wrong with that sentence:
1. **There are not six `date`-referencing views; there is ONE** (`v_feature_dates` —
   see F.11's corrected consumer table). F.11 does not "have to rebuild them anyway",
   so the stated reason to fold F.12 into F.11 does not exist.
2. **F.12(b) actively re-creates the dependency F.11 exists to remove.** The projection
   it restores explicitly includes `date` (the pre-001 `v_measurement` had 21 columns
   "including `date`, `datetime`, …"). Restoring it puts `sample.date` back into five
   more views — after which DuckDB will refuse to drop the column, and F.11 has to
   rebuild all five all over again.

**PINNED: F.12 lands AFTER F.11**, so that F.12's restored projections are written
against the post-F.11 world from the start. **OR**, if F.12 must go first for reporting
reasons, then pin instead that **F.12's restored projection derives its date from
`datetime`** (the Sydney calendar date, per F.11's rule) and never selects
`sample.date` — in which case the two are independent again. Choose one explicitly;
what must not happen is F.12 restoring a raw `sample.date` projection and F.11
discovering it afterwards. Recorded in the sequencing table at the head of Work F.

**CHOSEN 2026-07-24 (orchestrator ruling, recorded because the plan left it open):
the DECOUPLED option.** F.12's restored projections derive the date from `datetime`
and never select `sample.date`. F.12 therefore does NOT wait on F.11 — which is
blocked on F.13, filed for later by Robin, and out of this track. A broken reporting
view should not be held hostage to a deferred schema change. Built as
`dev/migrations/004-view-repair.R` (manifest units `P15-T-mig-views` / `P15-mig-views`);
**do not edit 001**.

Correction to this section's own rationale, carried from the Phase-3 adjudication:
it cites "the six `date`-referencing views". There is **ONE**. Every non-internal
view's SQL was inspected and only `v_feature_dates` references a date token. Build
against that measurement, not the sentence.

### R-15.35 v_measurement_epa returns nonzero, correct rows
Acceptance (must be able to FAIL): assert `v_measurement_epa` returns a row count
**> 0** *and* equal to an independently computed base-table query for the same
filter — a bare `>= 0` assertion is exactly the gate that let this through.

<!-- block: B-15.F17 -->
### F.17 Retain the non-tabular lab deliverables (APPROVED — Robin, 2026-07-23)
Every PDF and `.XLS` sibling of an ingested work order is currently
`quarantined` with reason `unclaimed`, gets **no `asset` row**, and is therefore
never copied into the archive. Measured after the cutover ingest: 10 files
`archived`, **19 `quarantined`** — the COA, COC, QC and QCI PDFs of all eight
work orders, plus each `XTAB.XLS`.

That was harmless while `remove_ingested` was FALSE, because nothing was ever
deleted. **It is now load-bearing:** the default is TRUE as of 2026-07-23, so
ingested sources are deleted from the input directory. Quarantined files are
correctly left alone by `.ig_remove_verified()` (no `asset` row → skipped), so
nothing is lost today — but the input directory will accumulate every PDF
forever while the data files disappear from beside them, which is exactly the
state that invites a manual "clean up the leftovers" sweep that deletes the only
copy of a certificate of analysis.

**Requirement, restated by Robin 2026-07-23: "Each file related to a WO should
be saved along with it."** Two obligations, and the second is the one easy to
miss — retention alone is not enough:

1. the bytes are retained (archived, hash-verified, source then removable);
2. the retained file is **discoverably attached to its work order**, so that
   "show me everything for WO ES2610538" returns the CSV *and* the COA, COC, QC
   and QCI PDFs and the XTAB.XLS. An `asset` row that records bytes without
   resolving to the work order satisfies (1) and fails the requirement.

That makes the work-order linkage a first-class part of the spec, not a
side-effect of registration — check how `asset` currently reaches an event
before designing this, and if the association is only via the parsed data, a
retain-only file will have nothing to hang off.

Scope otherwise to be fleshed out at implementation; the shape is roughly:

* register the non-tabular siblings of a committed event as `asset` rows with
  an appropriate `type` (they are evidence, not `"Chemical analysis"` data) and
  archive the bytes, so `.ig_remove_verified()` will then clean them up too;
* decide whether that happens through the router (a new low-tier "retain-only"
  adapter that claims them) or as a post-commit sweep over the event's sibling
  files — the router path keeps one code path for "what happened to this file",
  which is probably worth the extra plumbing;
* `ingest_file` needs a terminal state that means "kept deliberately, not
  parsed"; `quarantined` currently conflates "we could not read this" with
  "we do not parse this kind of file".

### R-15.36 Non-tabular deliverables retained and WO-linked
Acceptance (must be able to FAIL): ingest a work order whose directory contains
a COA PDF; assert the PDF has an `asset` row AND a byte-identical archive copy
AND **that the row is reachable from the work order** AND that a subsequent
`remove_ingested` pass deletes the source. Assert the run reports **zero**
`quarantined` files for that event — a test that merely counts `asset` rows
would pass while the PDF still sat unclaimed, and one that stops at the archive
copy would pass while the file was retained but unattached.

<!-- block: B-15.F18 -->
### F.18 Legacy `asset` rows with no retained bytes (RESOLVED 2026-07-23)
**1,272 of 2,556 `asset` rows have no archive copy on disk**, and a sample of 40
of their filenames could not be found anywhere under the `assets/` tree. These
are legacy rows migrated in with the pre-package data; the 1,258 legacy rows
that *do* have copies show the old system used the same
`<archive_dir>/<uuid>/<filename>` layout, so the missing ones are genuinely
absent rather than stored elsewhere.

Nothing is at risk of deletion because of this — `.ig_remove_verified()` only
ever considers files routed in the current run — but the `asset` table currently
overstates what is actually retained by roughly half, and anything that trusts
it as an evidence index is wrong.

**16 rows were repaired 2026-07-23** — bytes recovered from `input_dir` by hash,
copied into the archive, re-hashed to confirm. Those were the D.3 rows that
registered a hash without copying the bytes.

**Partial recovery looks possible for the rest.** Widening the search from
`assets/` to the whole SharePoint tree (15,175 files) matched **254 of the 1,272
missing filenames**, all under old `backup/2021-10-*/R/import/www/temp`
directories. Matching there is by *filename*, not hash, so each candidate must be
hash-checked before it is trusted — a same-named file from the old import staging
area is not necessarily the same bytes. Also relevant to F.17: **744 of the 1,272
are PDFs**, the very class F.17 is about, which suggests the old system never
retained them reliably either.

**RESOLVED 2026-07-23. The recovery-by-hash plan above could not be executed,
and the reason is the durable finding: `asset.hash` is NOT a content digest for
legacy rows.**

* 2,407 legacy rows store a **32-char** hash; only the **26** rows sampleTidy
  wrote itself store SHA-256. ~~`hash_file()` computes SHA-256~~ — **FALSE, struck
  2026-07-23 (cold audit, finding 13): CONTRACT A5 rules `hash_file()` is
  `rlang::hash_file()` = xxHash128, 32-char, and `R/hash.R:29-37` implements exactly
  that.** The first recovery pass compared a SHA-256 digest it computed itself against
  stored xxHash128 values and returned "0 of 1,272 recoverable" — an artefact of a test
  that could not pass. *(The "26 rows store SHA-256" claim in this same bullet is
  inconsistent with A5 and was not re-measured; treat it as unverified rather than as
  fact.)*
* MD5 does not explain them either: **0 of 120** non-empty archive copies
  reproduce their stored 32-char hash. The archive is healthy (3 zero-byte files
  of 1,284), so this is the hash column, not the bytes.
* ~~What the value actually is remains **unknown**.~~ **STRUCK 2026-07-23 (cold audit,
  finding 13): FALSE, and it inverts the actual outcome.** The 32-char value IS
  explained, and by this project's own pinned contract: **CONTRACT A5 rules that
  `hash_file()` is `rlang::hash_file()` = xxHash128, a 32-character lower-case hex
  digest**, and `R/hash.R` implements exactly that (`R/hash.R:29-37`; the roxygen at
  `:10-13` records that the legacy Shiny app wrote `rlang::hash_file()` into
  `asset.hash`, which is why 2,407 legacy rows carry it). So the legacy hashes are
  xxHash128, not "an unknown algorithm" — and **the hash-verified recovery this section
  said was impossible was in fact possible**: what failed was the first pass, which
  compared them against SHA-256 and then against MD5. The bullet above records a
  dead end that had already been resolved. 151 of 156 duplicate-hash groups sharing a
  work order was a red herring, and the failed converse (**0 of 356** multi-file work
  orders with all rows on one hash) is exactly what xxHash128-of-content predicts —
  different files have different content, so they have different hashes.
* **NEWLY DISCOVERED, and unresolved: `change_log.source_hash` is a MIXED-ALGORITHM
  COLUMN that nobody migrated.** Measured 2026-07-23: it is **100% 64-char over 1,412
  rows**, i.e. SHA-256 throughout, while **new writes are 32-char** xxHash128 per
  CONTRACT A5. So the column already holds two incompatible digest families and will
  hold both side by side from the next write onward. Any code that joins, dedups or
  verifies on `source_hash` is silently comparing across algorithms and can only ever
  return "no match" for a cross-era pair — the identical failure mode that produced the
  bogus "0 of 1,272 recoverable" result above, in a different column. **Needs a ruling
  and probably a migration; it is NOT resolved by this section.** Recorded here because
  this is where the evidence surfaced, not because F.18 owns the fix.
* **Lesson, now 9×: always run a POSITIVE CONTROL before trusting a negative
  result.** Verifying 60 rows that *do* have copies is what exposed both wrong
  algorithms. Without it, 1,272 rows would have been deleted on the strength of a
  check that was structurally incapable of passing.

**What was done.** 1,272 rows with no file were deleted (`db_delete`, all logged,
backed up to `dev/asset-rows-deleted-2026-07-23.csv`), then **180 were restored**:
153 whose file was found elsewhere in the SharePoint tree and matched by FILENAME
ONLY (Robin authorised name-only matching), and **27 that had their bytes all
along under the OLD FLAT layout** `<archive_dir>/<uuid>` — the deletion test only
looked for the nested `<archive_dir>/<uuid>/<filename>`. Those 27 are the
extensionless-file shape already recorded in PLAN-CHANGE-REQUESTS.md (33
extensionless files vs 1,565 directories) and routed to R-12.17; **any future
code that asks "is this asset retained?" must check BOTH layouts.** Their files
were migrated to the nested layout, md5-verified unchanged.

**8 rows were deliberately NOT restored**: their same-named candidates differ in
content (e.g. `ES2602084_COC.pdf` at 549,541 vs 550,073 bytes), and picking one
would put arbitrary bytes behind an evidence record. Listed in the backup CSV.

Final state: **1,464 asset rows, every one with its file, none flat.** The 1,092
rows whose bytes exist nowhere are gone from the registry rather than silently
overstating what is retained.

~~Superseded decision list: attempt the 254-row hash-verified
recovery, and mark the remainder (and any candidate that fails its hash check) as
`bytes_not_retained` so the registry stops claiming a copy exists.~~

**STRUCK 2026-07-23 (cold audit, finding 13).** This paragraph was left dangling under
a heading that reads **RESOLVED**, in the imperative, with no marker separating it from
live instruction — so it read as outstanding work. It is not: the section above records
what was actually done (1,272 deleted, 180 restored, 8 deliberately not restored, final
state 1,464 rows). There is no `bytes_not_retained` state to implement and no 254-row
recovery to attempt. **Nothing in F.18 is outstanding except the
`change_log.source_hash` mixed-algorithm finding recorded above.**

<!-- block: B-15.F19 -->
### F.19 `confirm_feature_aliases()` mislabels every confirmation as a transcription error (DEFECT — R4, Robin, 2026-07-23)
**⚠ URGENT. Not "urgent" as emphasis — urgent because the defect is actively producing
bad rows.** More input files are arriving, every ambiguous key they carry generates a
pending alias, and every pending alias Robin confirms is written out with a false
relationship label and, where the key is an identity mapping, as a **duplicate row**.
E.8 cleans up the two that exist; F.19 is what stops there being a third. Source:
`dev/plans/RULINGS-2026-07-23-alias-self-precedence.md`, R4.

**The defect.** `R/feature-alias.R:134-137`:

```r
changes <- list(uuid_feature = uuid_feature, confirmed_by = confirmed_by, auto_assign = TRUE)
if (identical(alias$kind[[1]], "pending")) {
  changes$kind <- "transcription_error"
}
```

The rewrite `kind 'pending' -> 'transcription_error'` is **unconditional** for every
confirmed pending row, with no test of what the relationship actually was. There is only
one branch, and it guesses. **An identity mapping is definitionally not a transcription
error** — the string is the feature's own name, spelled correctly. That is how the two
duplicate arms of E.8 came to exist and to be labelled `transcription_error` with
`confirmed_by = 'R. Shannon'` against a `name` identical to the target's.

**Required, both halves:**
1. **Detect identity — `alias_key == lower(feature.name)` — and flip the EXISTING
   `self` arm rather than minting a duplicate row.** Under R1 that arm is already
   `auto_assign = TRUE`, so in the common case the correct action is a no-op plus a
   `confirmed_by`, not an INSERT. (This is also why F.19 must precede E.8: with F.19 in
   place, the E.8 cleanup is a one-time backfill rather than a recurring chore.)
2. **Where it is a genuine NON-identity alias, label it honestly** rather than assuming
   `transcription_error`. The caller knows what they are confirming; the function must
   not invent a relationship it was never told. `historical_code`, `mask_long` and
   `descriptive` all already exist in the vocabulary and are all more common in the
   registry than `transcription_error` is.

### R-15.37 confirm_feature_aliases avoids duplicate identity arm
Acceptance (must be able to FAIL): confirm a pending alias whose key IS the target
feature's lower-cased name and assert that (a) NO new `feature_alias` row is created —
assert the table row count, not the resolution outcome — and (b) the existing `self` arm
carries the `confirmed_by`; then, in the same test, confirm a pending alias whose key is
NOT the target's name and assert it is NOT labelled `transcription_error` by default.
Without the second half an implementation that hard-codes `kind = 'self'` for everything
passes; without the first half the duplicate-minting behaviour survives untouched.

<!-- block: B-15.registry-data -->
## Registry data changes ~~pending~~ **APPLIED at the live cutover (2026-07-23) — RECORD, not a work list**

**RETITLED 2026-07-23 (cold audit, finding 16). This section is a RECORD of changes
already made. Nothing in D.1, D.2 or D.3 is outstanding.** It read as pending work — the
old heading said "pending the live cutover" and the body is written in the imperative —
long after the cutover happened. Verified applied:

| item | verified state |
|---|---|
| **D.1** new feature B.L05 | applied — present with `site` = B, matrix `leachate` |
| **D.2** the two `descriptive` aliases | applied — both present, both `auto_assign = TRUE` |
| **D.3** the 16 Chemistry2e files | applied — retained as assets, not deleted |

Everything below is preserved verbatim as the audit trail of *what* was applied and
*why*, including the reasoning and the rulings. Read it as history. The imperative mood
throughout ("apply", "do NOT write a migration", "register it in the `asset` table") is
an artefact of when it was written — those instructions have been carried out.
**Exception: D.4 is NOT part of this record.** D.4 describes two live-data defects and
their rulings; it was never claimed as applied and is still open work.

**Incidental, found during the same verification and NOT yet resolved:
`schema_version` holds 1, 2, 3, 4, 1001 — with NO 1002.** So **migration 002 is not
recorded as applied to the live DB**, and migration 003 would land as only the *second*
recorded migration in the 1000-series, across a gap. Either 002 ran without recording
itself, or it did not run at all; the plan does not say which, and 003 must not be
written assuming 002's schema is present. Establish which before building 003 — this is
a prerequisite of Work E, not a note.

**The authoritative DB is not yet on the package schema.** `/Users/rjs/OneDrive - Blue
Mountains City Council/Sharepoint/waste_data - Environmental monitoring/data/monitoring.duckdb`
has `analysis, analyte, analyte_mask, asset, feature, feature_mask, guideline,
lab_invoice, lab_method, project, sample` and **lacks `change_log`, `feature_alias`,
`ingest_file`, `review_queue`**. So `add_feature()` and every other mutation-layer call
would fail against it *today* (they write `change_log`). Registry changes are therefore
recorded here as pinned data and applied at cutover through the mutation layer, with
provenance — never hand-INSERTed into the authoritative file.

**Not a defect (corrected 2026-07-23):** `st_config("live_db")` resolving to a local
path under `tools::R_user_dir()` rather than the SharePoint file is **correct by
design** — see `dev/DESIGN.md` §9.1. OneDrive does not respect DuckDB's file lock, so
the live DB is permanently local and un-synced and SharePoint receives one-way
checkpointed snapshots. **Nothing is ever copied back.** Cutover is a one-time
*promotion* of the SharePoint file into the local path; afterwards the old file is
moved to `data/old/` under a dated, self-evidently frozen name. Likewise the missing
ops tables are not unbuilt work: `ensure_schema()` creates all four idempotently.
Snapshot destination (Robin, 2026-07-23): `…/Sharepoint/waste_data - Environmental
monitoring/data/backups`, date-only names, same-day overwrite accepted.

<!-- block: B-15.D1 -->
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

<!-- block: B-15.D2 -->
### D.2 Alias curation, applied after migration 001 creates `feature_alias`
| alias_key | → feature | kind | note |
|---|---|---|---|
| `trade waste dam` | B.L01 | `descriptive` | lab writes `B.L01 (Trade Waste Dam)` in the ES2515987 XTAB — documentary |
| `discharge point - lawson stp` | **B.L05** | `descriptive` | clears the other descriptive residual |

Together these clear all 15 `descriptive` residual items (6 work orders + 9 work orders).
`Dis Lawson` and `T/W Pump` also appear in the corpus and are UNRULED — do not alias them
on a guess.

<!-- block: B-15.D3 -->
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

<!-- block: B-15.D4 -->
### D.4 Two live-data defects surfaced by the D.3 verification (Robin, 2026-07-23)

Both independently confirmed by the orchestrator against the authoritative DB. Not
resolver bugs — pre-existing damage from the old WEM.input loader, found only because
the 16 files were checked rather than deleted. **This is the concrete payoff of D.3's
retain-don't-delete ruling: deleting the files would have destroyed the only evidence.**

**(a) ES2520710 — one pH lost, one mislabelled.** The source Chemistry2e carries TWO pH
values per sample: lab titrator (`EA005P: pH by PC Titrator`) and client-supplied field
pH (`EN67 - Client Supplied Data`). The DB kept only the FIELD value and labelled it with
the LAB method.

| sample | file: EA005P (lab) | file: EN67 (field) | DB stores, under EA005P |
|---|---|---|---|
| ES2520710001 | **6.40** | 7.41 | 7.41 |
| ES2520710002 | **7.15** | 6.67 | 6.67 |

**RULING — correct in place.** Re-attribute the two existing rows to EN67, then add the
EA005P lab values. End state: two correctly-labelled pH values per sample, NO duplicates.
Delete-and-re-ingest was explicitly rejected; "keep all existing rows" stands.
**Trap:** naive re-ingestion alone would yield FOUR pH rows per sample, not two. The
supplementary correction is mandatory — establish the observed three-way behaviour on a
copy first (the incoming EA005P value 6.40 differs from the stored EA005P value 7.41, so
this may present as a conflict, a supersede, or a new row).

**(b) ES2517594 — impossible sampling date.** Stored as 2025-09-08 14:00 (local
2025-09-09), but the lab analysed the samples 2025-06-12..2025-06-18 — analysis three
months *before* sampling. True date believed to be **2025-05-29** (same day as ES2516159;
the work-order sequence puts it there: ES2517034 = 4 Jun, ES2517702 = 11 Jun). MUST be
confirmed from `ES2517594_0_XTAB.XLS` before any correction is written — do not guess.

**Re-downloads (Robin, 2026-07-23):** complete file sets for ES2520710, ES2517594 and
ES2608966 are now in `…/assets/input/`, including the `Sample2e.CSV` the originals
lacked — which is what makes feature resolution and true dates recoverable. Verified:
macOS bracket-suffixed the collisions (`…Chemistry2e[94].CSV`) but this is HARMLESS —
`.st_esdat_parse()` dispatches on CSV *header content*, not filename, and
`file_meta()` returns identical `work_order_guess`/`revision_guess` for bracketed and
clean names. The old and new Chemistry2e files are **byte-identical** (same SHA, same
size, all three work orders), so hash dedup absorbs the duplicates and there is no
revision conflict. The chemistry was never the problem — both pH values were always in
the file; the old loader dropped one.

<!-- block: B-15.verification -->
## Verification
- Re-run the input/ dry-run (scratchpad/input_dryrun2.R) after each phase; track the
  `unknown_feature` count down and confirm ZERO cross-site mis-merges (assert BS1/BS3
  still resolve to BH.*). Full `testthat` suite green throughout.

<!-- block: B-15.out-of-scope -->
## OUT OF SCOPE (separate follow-ups, noted for the record)
- `unknown_analyte` ×14 = all "Sodium Adsorption Ratio" (computed ratio not in the
  analyte registry) — a registry-gap decision, not name resolution.
- `feature_raw = NA` × 3449 rows / 16 ESdat events — results with no point name after
  the Sample2e join (missing/unmatched sample metadata) — needs its own source trace.
