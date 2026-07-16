# PLAN 11 — `feature_alias`: remembering mis-transcribed sampling points

**Owns:** `R/feature-alias.R` (new), `tests/testthat/test-feature-alias.R`
(new), `dev/migrations/001-cypher-to-feature-alias.R` (new). **Amends:**
`R/db-schema.R` (`ensure_schema`), `R/reconcile.R` (`.rc_load_registry`,
`.rc_feature_candidates`, `.rc_resolve_features`), `R/mutate.R` (write API).
**Depends on:** plans 01–10 landed and green.

## Why

Sampling-point codes are almost always transcribed incorrectly somewhere
between the bottle, the COC and the lab's report. That is *the* reason this
pipeline needs a human in the loop at all. The DB has carried an informal
memory of past mis-transcriptions in `feature.cypher` for years; this plan
replaces it with a real one and wires it into the reconciler.

### Evidence (measured against the live `monitoring.duckdb`, 2026-07-16)

`feature.cypher` is a comma-separated `VARCHAR` on 117 of 894 features:

| finding | number |
|---|---|
| raw comma-separated entries | 2062 |
| **unique `(feature, alias)` pairs** | **379** |
| duplicate re-appends (pure bloat) | **1692 (82%)** |
| entries identical to the feature's own current name | 79 |
| entries per feature | median 6, mean 17.6, **max 149** |
| aliases mapping to more than one feature | 31 |

Classified against the owning feature's name (379 unique pairs):

| class | n | share | example |
|---|---|---|---|
| arbitrary novel code — **no rule can derive it** | 147 | 39% | `BH.MW02` ← `B2` |
| identical to current name (punct/case only) | 79 | 21% | `BH.MW02` ← `BH.MW02` |
| within edit-distance 2 of name/code | 77 | 20% | `BH.MW02` ← `BH.B02` |
| descriptive human phrase | 76 | 20% | `BH.MW02` ← `Eastern downstream` |

**The concept is load-bearing and must be kept:** 39% are arbitrary codes no
rule or fuzzy match could ever recover. **The container is what is wrong.**

### Why not `feature.cypher` (the status quo)

1. Delimiter collides with the data: aliases are free text and 20% are
   descriptive phrases; one containing a comma silently becomes two aliases.
2. No uniqueness constraint → 82% duplicate bloat, max 149 entries/feature.
3. No provenance: cannot distinguish a confirmed historical code from
   something typed once, nor say when/where it was seen or who confirmed it.
   For a human-in-the-loop workflow that metadata *is* the product.
4. Ambiguity is unrepresentable and unenforceable.
5. Not indexable/joinable; must be parsed at every match.

### Why not `feature_mask`

`feature_mask(uuid_feature, variant, name)` is a **naming-system map with a
strict 1:1 contract**: all 2767 `(feature, variant)` pairs hold exactly one
name, and its four views (`v_feature_epa/old/long/gas_report`) are
`LEFT JOIN … AND variant='x'` + `COALESCE(fm.name, f.name)` — a 1:1
*substitution*. A 1:many variant would multiply feature rows in any such
view, and `.rc_feature_candidates()` currently joins `feature_mask` **without
filtering variant**, so 20+ alias rows per feature would pollute matching
immediately.

Also (user, 2026-07-16) the variants are not synonyms for "mis-spelling":
**`old` means a *different physical feature*** — a borehole that was
destroyed and re-dug alongside under a new name; the two are distinct
features whose records are merged for some purposes. `cypher` is "whatever
someone wrote on a bottle". They must not be conflated.

## Decisions (user, 2026-07-16)

- **A new `feature_alias` table**, 1:many, not `feature_mask`, not `cypher`.
- **Auto-import the non-EPA `feature_mask` names into it** (`long`, `old`,
  `gas_report` — some already appear in `cypher`). `feature_mask` keeps its
  1:1 rendering role for the views; `feature_alias` becomes the single
  **matching** source.
- **EPA is excluded from matching** — achieved by simply never importing it
  (its names are bare numbers: `'1'`, `'20'`; 749 of 767 EPA rows share a
  name with another feature). This needs no special case in the matcher.
- **Resolving a review item records the alias** (`confirmed_by`,
  `source_hash`), so the same junk auto-resolves next time. This is what
  makes the table grow deliberately rather than by blind append — which is
  how `cypher` reached 149 entries at 82% duplication.
- **Exact (normalised) matching only — no fuzzy auto-assign.** Real codes
  differ by one character (`B.S01` vs `B.S04`; `B2` vs `B3`), so an unseen
  typo is genuinely ambiguous between real neighbours and edit-distance would
  confidently suggest the wrong one.

## R-11.1 Schema

`ensure_schema()` creates, idempotently:

```
feature_alias(
  uuid         VARCHAR PRIMARY KEY,
  uuid_feature VARCHAR NOT NULL,      -- -> feature.uuid
  alias        VARCHAR NOT NULL,      -- raw, as seen ('B..So3')
  alias_key    VARCHAR NOT NULL,      -- normalised match key (.rc_key)
  kind         VARCHAR,               -- historical_code | descriptive |
                                      --   transcription_error | mask_<variant>
  auto_assign  BOOLEAN DEFAULT TRUE,  -- FALSE = suggest only, never resolve
  first_seen   TIMESTAMP,
  last_seen    TIMESTAMP,
  source_hash  VARCHAR,               -- provenance: the file it came from
  confirmed_by VARCHAR,               -- the human who approved it
  comments     VARCHAR
)
```
Criteria: `UNIQUE(uuid_feature, alias_key)` enforced (dedup by construction —
the single most important lesson from `cypher`); creating twice is a no-op;
an existing DB without the table gains it; `alias_key` is always
`.rc_key(alias)` (shared normalisation with the reconciler — never a second
spelling of "normalise").

## R-11.2 Matching

`.rc_feature_candidates(feature_raw, registry)` resolves against, in order:
`feature.name`, then `feature_alias` rows with `auto_assign = TRUE`.
It **no longer joins `feature_mask`** (its non-EPA content is imported into
`feature_alias` by R-11.5; EPA must never match).

Criteria:
- exactly one distinct `uuid_feature` → assign (`status = "hit"`), whether the
  hit came from `feature.name` or an alias;
- an alias whose `alias_key` matches two features → **two candidates** →
  `ambiguous` (ambiguity is data, not a flag — no special case needed);
- `auto_assign = FALSE` rows never produce a hit but DO produce review
  suggestions (R-11.3);
- the existing A44 NA guard still holds: `NA`/blank `feature_raw` → no
  candidates, never a phantom hit;
- EPA mask names (`'1'`, `'20'`) match nothing.

## R-11.3 Review suggestions (the user-facing point)

An `unknown_feature` review item must name **features**, not UUIDs. Today the
ambiguous payload carries `candidates=<uuid>|<uuid>` and the 0-hit payload
carries no suggestions at all — so the wanted message is not producible.

Required message shape:

> Unknown feature 'B..So3' previously found for B.S04 and B.S03

Criteria:
- **ambiguous** (>1 candidate): payload lists the candidate **feature names**
  (sorted, deduped), alongside the uuids for machine use;
- **unknown** (0 auto-assign candidates): the payload lists any
  `auto_assign = FALSE` / ambiguous alias matches by feature name — i.e. every
  feature this string has *ever* been recorded against;
- a genuinely novel string yields a review item with **no** suggestions and
  says so (never a fabricated guess);
- grouping is unchanged: one review item per normalised `feature_raw`, never
  one per row (R-8.2), and the A44 NA sentinel still groups.

## R-11.4 Recording a resolution (closing the loop)

A public `resolve_feature_alias(review_item, uuid_feature, confirmed_by)`
writes a `feature_alias` row via the plan-09 mutation layer (never a raw
`dbExecute` — A32/A40), with `kind = "transcription_error"`, the review
item's `source_hash`, and a `change_log` entry.

Criteria: re-resolving the same alias to the same feature is idempotent
(updates `last_seen`, does not duplicate — the `UNIQUE` constraint holds);
resolving the same alias to a *different* feature is an error, not a silent
second row (that is a human contradiction and must surface); the next
`ingest_dir()` over the same file auto-assigns and opens no review item
(**the end-to-end proof of the whole plan**).

## R-11.5 Migration (one-off, `dev/migrations/`)

Imports into `feature_alias`, against a **backup copy first**:
- **`cypher`**: split on `,`, trim, drop empties, drop the 79 entries equal to
  the feature's own name, collapse the 1692 duplicates. Expect ~300 rows.
  `kind = "historical_code"`, or `"descriptive"` when the entry is a phrase
  (alpha-only, contains a space).
- **non-EPA `feature_mask`** (`long`, `old`, `gas_report`): one row each,
  `kind = "mask_<variant>"`. Overlaps with `cypher` collapse via the UNIQUE
  key rather than erroring.
- **EPA is not imported.**

Criteria: idempotent (re-running imports nothing new); the source `cypher`
column is left untouched by the migration itself (retiring it is a separate,
later step, once the alias table has proven itself); a dry-run mode reports
the counts it *would* insert; every ambiguous alias (31) is imported with
`auto_assign = FALSE` and reported, since those must never auto-resolve.

## Open / deferred

- **Retiring `feature.cypher`** (drop column vs demote to free-text note) —
  after the migration has run and been reviewed. `project.cypher` exists too
  and is out of scope here.
- **Site-completion (`S01` → `B.S01` when the site is known):** all 894
  feature names are `<site>.<code>` (sites B 452, K 396, L 34, BH 12), so the
  rule is structurally sound, but it applies to *incoming* `feature_raw`, not
  to stored aliases (zero cypher entries are bare codes), and it needs the
  event's site to be known. Deferred to its own plan.
- **Fuzzy suggestions for never-seen typos:** deliberately excluded (see
  Decisions). Revisit only as clearly-labelled review *suggestions*, never
  auto-assign.
