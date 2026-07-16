# PLAN 11 — `feature_alias`: remembering mis-transcribed sampling points

**Owns:** `R/feature-alias.R` (new), `tests/testthat/test-feature-alias.R`
(new), `dev/migrations/001-cypher-to-feature-alias.R` (new). **Amends:**
`R/db-schema.R` (`ensure_schema`), `R/reconcile.R` (`.rc_key`,
`.rc_load_registry`, `.rc_feature_candidates`, `.rc_resolve_features`),
`R/mutate.R` (write API). **Depends on:** plans 01–10 landed and green.

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
| unique `(feature, alias)` pairs (case/punct-folded) | 370 |
| …of which are the feature's **own correct name** | 72 |
| **wrong-label pairs (the actual signal)** | **298** |
| entries per feature | median 6, mean 17.6, **max 149** |
| aliases mapping to more than one feature | 31 |

**Repeats are frequency, not bloat** (user, 2026-07-16 — this corrects an
earlier reading of this data). A label was appended to `cypher` **every time
it was seen**, so the repeat count is a usage count. Wrong-label distribution:
222 seen once, 38 seen 2–4×, 38 seen 5+, max 38 (`B.L01` ← `BDISCHARGE`).
Note the top counts overall are features logging their *own correct name*
(`B.S01` ← `B.S01`, 131×) — so the count means **"times this label was
seen"**, not "times it was wrong".

Wrong labels classified against the owning feature's name (298 pairs):

| class | n | share | example |
|---|---|---|---|
| code-shaped, explained by prefix-swap + number normalisation | 71 | 24% | `BH.MW02` ← `BH.B02`, `B2` (B=Bore → MW=monitoring well) |
| code-shaped, not explained by the prefix map | 43 | 14% | |
| word / descriptive phrase | 184 | 62% | `B.L01` ← `BDISCHARGE`; `BH.MW02` ← `Eastern downstream` |

**The concept is load-bearing and must be kept:** a large share are arbitrary
codes and words that no rule could derive. **The container is what is wrong.**

### Why not `feature.cypher` (the status quo)

1. Delimiter collides with the data: aliases are free text and most are
   words/phrases; one containing a comma silently becomes two aliases.
2. No uniqueness constraint and no count column — so "seen again" is recorded
   by *appending a duplicate row*, which is why one feature carries 149
   entries. The information is real; the encoding is not.
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

The variants are not synonyms for "mis-spelling": **`old` means a *different
physical feature*** — a borehole destroyed and re-dug alongside under a new
name; the two are distinct features whose records merge for some purposes.
`cypher` is "whatever someone wrote on a bottle".

## Decisions (user, 2026-07-16)

- **A new `feature_alias` table**, 1:many, not `feature_mask`, not `cypher`.
- **Import `long` mask names only.** Smallest blast radius; add others only on
  evidence that a real file needs them. Measured basis:
  - **`old` — must NOT be imported.** 363 of its 373 names **are another live
    feature's real name** (`B.G189`'s old name is `B.G005`; `B.G005` exists as
    its own feature). Importing it would turn 363 clean exact matches into
    ambiguous review items, and is semantically wrong: a file saying `B.G005`
    means the feature `B.G005`.
  - **`EPA`** — bare numbers (`'1'`, `'20'`); never a lab-supplied identifier.
  - **`gas_report`** — structured (`B.G020`), 0 clashes, 0 within-variant
    ambiguity, i.e. *safe*, but excluded for now under smallest-blast-radius.
  - **`long`** — 0 clashes with real names, but 343 ambiguous generic
    descriptors (`Upstream`); ambiguity there surfaces honestly as a review
    item, never as a wrong assignment.
- **Aggressive normalisation, and it is not "fuzzy".** Fold case and strip
  **all** non-alphanumerics, so `B.S01` / `B S01` / `BS01` / `b.s01` are one
  key. **Verified collision-free: all 894 feature names yield 894 distinct
  keys.** Deterministic, so it is safe to auto-assign on.
- **No fuzzy auto-assign.** Real codes differ by one character (`B.S01` vs
  `B.S04`; `B2` vs `B3`), so an unseen typo is genuinely ambiguous between
  real neighbours and edit-distance would confidently suggest the wrong one.
- **`n_seen` frequency column.** Ranks shortlists. **It must never break a
  tie**: the worst real case is `KBORE` → `K.MW08` **15×** vs `K.MW10A`
  **14×**. Frequency ranks; it does not decide.
- **Guesses are never auto-applied** (derived prefix-map or LLM). An LLM in
  the commit path would break idempotency — plan 10's load-bearing property
  (run twice, zero deltas); a non-deterministic matcher can commit different
  features on identical bytes. Suggestions populate review items only; review
  items are not core data, so idempotency survives.
- **Review UX — bulk confirmation, not per-feature clicking.** Two tiers:
  1. **"We have a best guess for these N"** — shown with the guess and its
     basis; the human acts **once**: "yes, all correct", or "all correct
     except this one, which is `foo`". No per-feature action required.
  2. **"No confident guess for these M"** — each with an optional ranked
     shortlist ("probably one of these").
  Nothing is assigned until the human confirms; confirmation is what writes a
  `feature_alias` row and closes the loop.

## R-11.1 Schema

`ensure_schema()` creates, idempotently:

```
feature_alias(
  uuid         VARCHAR PRIMARY KEY,
  uuid_feature VARCHAR NOT NULL,      -- -> feature.uuid
  alias        VARCHAR NOT NULL,      -- raw, as seen ('B..So3')
  alias_key    VARCHAR NOT NULL,      -- normalised match key (.rc_key)
  kind         VARCHAR,               -- historical_code | descriptive |
                                      --   transcription_error | self_name |
                                      --   mask_long | derived
  n_seen       INTEGER DEFAULT 1,     -- times this label has been seen
  auto_assign  BOOLEAN DEFAULT TRUE,  -- FALSE = suggest only, never resolve
  first_seen   TIMESTAMP,
  last_seen    TIMESTAMP,
  source_hash  VARCHAR,               -- provenance: the file it came from
  confirmed_by VARCHAR,               -- human who confirmed; NULL = unconfirmed
  comments     VARCHAR
)
```
Criteria: `UNIQUE(uuid_feature, alias_key)` enforced — "seen again" increments
`n_seen`, it never inserts a second row (the central lesson from `cypher`);
creating twice is a no-op; an existing DB without the table gains it;
`alias_key` is always `.rc_key(alias)` — the reconciler and the migration
share one spelling of "normalise", never two.

## R-11.2 Normalisation (`.rc_key`, amended)

`.rc_key()` currently does `tolower(str_squish(normalise_lab_text(x)))`,
which leaves punctuation, so `B.S01` and `B S01` do not match today. Amend it
to also strip all non-alphanumerics.

Criteria: `B.S01`, `B S01`, `BS01`, `b.s01`, `B..S01` share one key; **all 894
real feature names still produce 894 distinct keys** (a pinned regression
test against a fixture of the real name list — this is the property that makes
the fold safe, so it must fail loudly if a future name breaks it); NA/blank
still returns NA (the A44 guard); existing analyte/method matching that shares
`.rc_key` is re-verified (`normalise_lab_text` mojibake handling is unchanged).

## R-11.3 Matching

`.rc_feature_candidates(feature_raw, registry)` resolves against
`feature.name`, then `feature_alias` rows with `auto_assign = TRUE`. It **no
longer joins `feature_mask`** (its `long` content is imported by R-11.6; EPA
and `old` must never match).

Criteria:
- exactly one distinct `uuid_feature` → assign, whether via name or alias;
- an alias matching two features → two candidates → `ambiguous` (ambiguity is
  data, not a flag — no special case);
- `auto_assign = FALSE` rows never hit, but do produce suggestions (R-11.4);
- the A44 NA guard holds: NA/blank `feature_raw` → no candidates, never a
  phantom hit;
- EPA/`old` names match nothing (they are simply absent);
- a file naming a re-drilled well's *old* name (`B.G005`) resolves to the
  feature actually called `B.G005`, unambiguously (the R-11.6 regression).

## R-11.4 Review items: guesses and shortlists

Today the ambiguous payload carries `candidates=<uuid>|<uuid>` and the 0-hit
payload carries no suggestions — so neither review tier is producible.

Required message shape:

> Unknown feature 'B..So3' previously found for B.S04 and B.S03

Criteria:
- review items name **features**, never bare UUIDs (uuids may ride alongside
  for machine use);
- **tier 1 (best guess)**: a single confident candidate from a *derived*
  source (prefix map / LLM / a `auto_assign=FALSE` alias with one owner),
  carrying its basis ("prefix map B→MW", "seen 15×", "LLM: matches long name
  'Eastern downstream'") so bulk confirmation is an informed act;
- **tier 2 (no confident guess)**: optional ranked shortlist, ranked by
  `n_seen` — explicitly a ranking, never a decision;
- a genuinely novel string yields an item with **no** suggestions, and says so
  (never a fabricated guess);
- grouping unchanged: one item per normalised `feature_raw`, never one per row
  (R-8.2); the A44 NA sentinel still groups.

## R-11.5 Confirmation (closing the loop)

A public bulk API — `confirm_feature_guesses(items, corrections, confirmed_by)`
— accepts a whole review batch, applies per-item corrections, and writes
`feature_alias` rows through the plan-09 mutation layer (never raw
`dbExecute` — A32/A40) with `change_log` provenance.

Criteria: confirming the same alias→feature twice is idempotent (increments
`n_seen`, never a duplicate row — the UNIQUE key holds); confirming the same
alias to a *different* feature is an error, not a silent second row (a human
contradiction must surface); an unconfirmed guess is **never** written as a
confirmed alias, and keeps being reported every run until confirmed (no guess
laundering); after confirmation the same input auto-assigns and opens no
review item — **the end-to-end proof of the plan**.

## R-11.6 Migration (one-off, `dev/migrations/`)

Against a **backup copy first**, into `feature_alias`:
- **`cypher`**: split on `,`, trim, drop empties, **count** duplicates into
  `n_seen` (do not discard them). ~370 rows: `kind = "historical_code"` for
  code-shaped, `"descriptive"` for phrases, `"self_name"` for the 72 equal to
  the feature's own name (kept: they carry the correct-usage denominator, and
  they are harmless since `feature.name` already matches).
- **`long` mask names**: one row each, `kind = "mask_long"`. Overlaps with
  `cypher` collapse via the UNIQUE key (incrementing `n_seen`), never error.
- **Not imported:** `old`, `gas_report`, `EPA`.

Criteria: idempotent (re-running inserts nothing new and double-counts
nothing); `feature.cypher` is left untouched (retiring it is a separate,
later step, once the alias table has proven itself); a dry-run mode reports
what it *would* insert; the 31 ambiguous aliases are imported with
`auto_assign = FALSE` and reported, since they must never auto-resolve.

## Open / deferred

- **Replaying held rows after a confirmation.** If a feature can't resolve,
  its rows go to review and are not committed. Once the human confirms the
  alias, *how do those rows land?* A re-run of `ingest_dir()` may no-op: the
  file's `ingest_file` state is already terminal and `route_files()` does not
  re-decide a routed hash (this is the same seam as the handover's `dry_run`
  ops-state note). Either confirmation replays the held rows, or a file needs
  an explicit re-open path. **Decide before R-11.5 is implemented** — the loop
  is not closed without it.
- **The derived prefix map** (`B→MW`, `BS→S`, `BORE→MW`, `MP→MW`): explains 71
  of 298 wrong labels (24%; 62% of the code-shaped ones). It is not purely
  prefixes (`BORE→MW` is word→abbreviation) and it must be collision-tested —
  a mapped code can land on a real, different feature (the `B.G005` trap).
  Suggestions only.
- **LLM suggestions from `long` names/descriptions** (`ellmer` is already in
  Suggests). Suggestion-side only, never the commit path (idempotency).
- **Site-completion (`S01` → `B.S01`)**: all 894 names are `<site>.<code>`
  (B 452, K 396, L 34, BH 12), so the rule is sound, but it applies to
  *incoming* `feature_raw`, needs the event's site, and does not disambiguate
  (site-scoping only drops ambiguous aliases 31→30). Zero cypher entries are
  bare codes. Own plan.
- **Retiring `feature.cypher`** (drop vs demote to free text) after the
  migration is reviewed. `project.cypher` also exists; out of scope.
