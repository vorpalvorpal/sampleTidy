# Rulings — self-arm precedence and the confirm mislabelling (Robin, 2026-07-23)

Context: migration 001 set `auto_assign = FALSE` on every arm of every multi-arm
alias key, **including the `self` arm**. Measured on the live registry
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only): 8 self arms were left FALSE; `confirm_feature_aliases()` fixed 2 of
them this morning; **6 features are still unreachable by their own name.**

| alias_key | feature | samples attached |
|---|---|---|
| `b.s22` | B.S22 | 58 |
| `b.s04` | B.S04 | 37 |
| `b.ts18` | B.TS18 | 6 |
| `b.ts40` | B.TS40 | 1 |
| `b.ts41` | B.TS41 | 1 |
| `b.ts02` | B.TS02 | 0 |

## R1 — a `self` arm is always `auto_assign = TRUE`

A feature is always reachable by its own name. Where a key reaches more than one
live candidate and exactly one is `kind = 'self'`, the self arm WINS and the row
resolves; it does not go to review.

This replaces the earlier proposal to exempt `b.s01`/`k.e02` from migration 003,
which treated the symptom. Date bounds remain the instrument for the *historical*
arms, subject to R4 below.

### R1a — self wins ONLY while the self arm is unbounded (Robin, 2026-07-24)

Self-precedence applies only where the `self` arm has **no `date_end`**. Once a
self arm is date-bounded — the feature was retired — it no longer automatically
claims its own name; the historical arms compete on equal terms and the row goes
to review as before.

Rationale: a retired feature should not hold its name forever. R1 exists so a
LIVE feature is always reachable by its own name, not so a dead one blocks its
successor.

Consequence for E.5 rule 2: the self arms of the rule-2 keys are NOT bounded, so
under R1/R1a `b.s22` now RESOLVES to B.S22 and notes the shadowed B.S06 arm,
rather than going to review every time. That is the behaviour R2 asks for
("still processed along the self auto-assigned arm ... just notes that it has
happened"), and it supersedes E.5's older instruction that no test may assert
`b.s22` resolves. Confirm before building if rule 2 was meant to keep BLOCKING.

## R2 — the override is NOTED, not silent (non-blocking)

When self-precedence overrides one or more live non-self arms, emit a
`review_queue` row recording that it happened. The sample still commits through
the self arm. This is an annotation, not a gate.

Architecturally available today: nothing in `R/` reads `review_queue` to block
anything (`commit.R:650` appends review rows independently of whether samples
commit), and `unknown_unit`, `value_conflict` and `batch_duplicate` already
annotate alongside data that lands. `review_queue_add()` (`db-schema.R:292`) is
the centralised writer.

Two changes in `R/reconcile.R`, both localised:
1. **Self-precedence** in candidate resolution. Note the clean-hit path at
   `:450-453` currently `next`s out BEFORE the candidate-collection code at
   `:455`, and `.rc_feature_candidates` filters to `auto_assign = TRUE` — so
   under R1 a key with a live historical arm would otherwise yield 2 candidates
   and go pending, which is the behaviour R1 exists to prevent.
2. Retain the shadowed candidates on that path and emit the note.

**This is the first NON-BLOCKING review kind emitted by the feature resolver.**
The payload grammar must distinguish note from blocker, or a queue reader will
treat a note as work. Folds into the single `subkind` precedence table pinned in
response to audit finding 7.

## R3 — merge the two duplicate arms

`b.s01 -> B.S01` and `k.e02 -> K.E02` each exist twice: once `kind = 'self'`
(`auto_assign` FALSE) and once `kind = 'transcription_error'` (TRUE, `confirmed_by`
`R. Shannon`). Both carry the identical `name` `"B.S01"` / `"K.E02"`, and both
have `alias_key = lower(feature.name)` — they are identity mappings, not
transcription errors. Merge each into its `self` arm and delete the duplicate.
These are the only two such duplicates in the registry.

## R4 — `confirm_feature_aliases()` mislabels; fix it

`R/feature-alias.R:135-137` rewrites `kind 'pending' -> 'transcription_error'`
unconditionally for every confirmed pending row, with no test of what the
relationship actually was. An identity mapping is definitionally not a
transcription error.

Required: detect identity (`alias_key == lower(feature.name)`) and flip the
existing `self` arm rather than minting a duplicate row; where it is a genuine
non-identity alias, label it honestly rather than assuming transcription error.
Urgent because more input files are arriving and every ambiguous key keeps
generating these.

## R5 (carried, from the same measurement) — E.5 rule 1 must set `date_start`

E.5's table sets `date_end` only, and the liveness rule is
`(date_start IS NULL OR date_start <= d) AND (date_end IS NULL OR date_end >= d)`,
so every bounded arm is live back to the beginning of time. B.TS41 has exactly
ONE sample (2026-01-21); the arm `b.s01 -> B.TS41` therefore shadows 24 years of
B.S01 history. Measured: 178 of 186 `b.s01` samples fall inside that bound;
with a point bound (`date_start = date_end = 2026-01-21`) it is **1**.

`k.e02 -> K.S06` is a separate case: K.E02 (31 samples, 2020-07-28 ->) and K.S06
(24 samples, 2020-08-11 ->) coexist for their entire lifespans and both end
2026-05-25, so NO `date_end` can separate them — post-003 that key would go to
review at every date and never resolve. It is a rule-2 case ("recurring, Robin
reviews every time"), not rule 1.

R5 is a consequence of R1/R2 rather than a separate ruling: under self-precedence
`b.s01` and `k.e02` resolve regardless, and the date bounds now only govern which
shadowed arms get NOTED. Recorded because the rule-1 defect would otherwise
misfire on the next single-sample target.
