# PLAN-11 cold design review (Phase 3 sanity check, pre-test)

Reviewer: fresh-eyes, read-only. Verified against `R/reconcile.R`, `R/commit.R`,
`R/mutate.R`, `R/ir.R`, `R/assemble.R`, `R/db-schema.R`, `tests/testthat/helper-db.R`,
and (read-only) `/Users/rjs/Documents/dashboard/data/monitoring.duckdb`.

Note on the evidence DB: `st_config("live_db")`
(`~/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`) **does not
exist**. The only reachable copies are the dashboard's and
`/Users/rjs/Documents/leachatetools/test data/monitoring.duckdb`. All checks below are
against the dashboard copy; counts agree with the plan on feature/sample/analysis/lab_method,
so it is the same lineage.

---

## Verdict

The model (P) is sound and the plan is unusually well-argued. Its four headline claims about
existing code are **TRUE** (verified — see §A). But it has **six blocking defects**, and five
of them are the same defect wearing different hats: **the plan places the alias's identity at
commit (D8) while three consumers need that identity at reconcile.** Not ready to write tests
against until 1–6 are resolved.

---

## A. Claims about existing code — verification results

| plan claim | verdict | evidence |
|---|---|---|
| `.rc_find_existing`'s `lm.uuid_analyte = ?` is redundant because `a.uuid_lab = ?` pins the analyte (A53) | **TRUE** | `R/reconcile.R:428-440`: query joins `lab_method lm ON lm.uuid = a.uuid_lab`, so `a.uuid_lab = ?` functionally determines `lm.uuid_analyte`. Callers (`R/reconcile.R:527-530`) only ever pass rows with status `"hit"`, so `uuid_lab` is never NA today. A45's key is preserved. |
| `reconcile_event()` is a funnel that drops feature-unknown rows before `.rc_three_way` | **TRUE** | `R/reconcile.R:115-117` (`kept <- rows[hit_idx, ]`), `:632-660` (each stage reassigns `active <- x$kept`). |
| `analysis` has no units column | **TRUE** | live: `uuid, uuid_sample, uuid_lab, value, value_chr, quantified, rl_low, rl_high, purpose, comments`. |
| `lab_method.reported_as` is dead | **TRUE** | live: `count(*) = 365`, `count(reported_as) = 0`. |
| `sample.uuid_feature` NOT NULL; `lab_method.uuid_analyte` 0 dangling | **TRUE** | live: `sample.uuid_feature is_nullable = NO`; `count(uuid_analyte) = 365 / 365`. |
| `feature` NOT NULL on `name, site, lon, lat` | **TRUE** | live information_schema: all four `is_nullable = NO`. Supports "no provisional features". |
| D4: 6 views reference `sample.uuid_feature` | **TRUE** | views whose definition mentions `sample`: `v_feature_dates`, `v_measurement`, `v_measurement_{epa,gas_report,long,old}` = exactly 6. The other four `v_feature_*` match only on `feature_mask.uuid_feature`. |
| `.ct_commit_review()` currently writes `source_hash = NA` | **TRUE but misleading** | `R/commit.R:298` already reads a `source_hash` **column** off `review` if present. No commit.R change is needed — only a reconcile-side column. |
| `.rc_proto_review()` has no `source_hash` column | **TRUE** | `R/reconcile.R:38-40`. |

Minor evidence drift (not defects, but the plan's numbers should not be trusted verbatim by a
test author): plan says `lab_method = 360` (L114) then `365` (L128) — live is **365**; plan
says `245 analytes`/`14 views` — live is **247** / **60**; plan says all features are
`virtual = FALSE` — the live `feature` table **has no `virtual` column at all** (CONTRACT's
schema line also lists it wrongly). The conclusion "no provisional features" survives anyway
via NOT NULL `lon`/`lat`.

---

## B. Numbered delta list

### 1. BLOCKING · false premise / missing input · R-11.4 (L149), R-11.5 (L308), Evidence L134
**The event carries no `site`.** `grep -rn site R/ir.R R/assemble.R R/file-meta.R` returns
**nothing**: `.st_ir_results_types` / `.st_ir_samples_types` (`R/ir.R:9-28`) have no site
column, and `reconcile_event()` calls `.rc_resolve_features(active, registry, event$work_order)`
(`R/reconcile.R:637`) — three args, no site. Narrowing step (3) ("if the file's site is known,
drop features not at that site") has **no input to read**, no fixture can reach it, and
supplying one means amending `R/ir.R` + every adapter — files owned by plans 03–06, an
undeclared ownership conflict. (`feature.site` exists live and is NOT NULL; that is the
*candidate's* site, not the file's.)
**Fix:** drop site-narrowing from R-11.4/R-11.5 to Open/deferred (date_end alone resolves 1 of
31; site resolves 3 more) — or file a plan-change request for an IR `site` field first.

### 2. BLOCKING · internal contradiction (D8 vs R-11.9) · R-11.9 L416-417
**A reconcile-emitted review item cannot carry the alias uuid.** R-11.9 requires "the payload
gains the **alias `uuid`** (so confirmation can target it)", but D8 + R-11.8 create the pending
alias **at commit**, after reconcile has already built its review tibble. At
`.rc_resolve_features()` time the alias does not exist. Same for R-11.9's "an `unknown_analyte`
item names the lab method" — the dangling `lab_method` is created by
`.ct_materialise_lab_methods()` at commit. The R-11.9 criterion "every item carries a resolvable
alias uuid" is unreachable as specified.
**Fix:** move payload enrichment to commit — have `.ct_materialise_*` return an alias/lab_method
uuid per row and rewrite `resolved$review` payloads before `.ct_commit_review()` — and say so.

### 3. BLOCKING · design hole (idempotency) · R-11.7 L355-358, criteria L363-364
**A dangling row can never dedup, so every re-ingest duplicates it.** `.rc_find_existing()` runs
inside reconcile (`R/reconcile.R:527`), where a pending row has `uuid_feature_alias = NA` (alias
not yet materialised) **and** `uuid_lab = NA` (lab_method not yet materialised). R-11.7's
"Pending: match on `s.uuid_feature_alias` directly" matches on NA; and dropping the
`lm.uuid_analyte` clause does not save the analyte side because `a.uuid_lab = ?` is *itself* NA
for an analyte-pending row — `= NULL` never matches. So R-11.7's criterion "a dangling
measurement re-ingested from a **different file** matches itself and is `already_present`" is
**unachievable**, and R-11.8's "re-ingesting the same bytes → already_present" only passes
because hash dedup catches it upstream (a false green). This directly threatens the Gates'
"plan-10 idempotency run twice in a row".
**Fix:** have reconcile *look up* (read-only) an existing pending alias by `alias_key IS NULL`-
feature and an existing dangling `lab_method` by `(organisation, .rc_key(name), method)`, set
`uuid_feature_alias`/`uuid_lab` from them when found (still `*_pending = TRUE` so R-11.8
find-or-create is a no-op), and match on those.

### 4. BLOCKING · undeclared amendment · plan header "Amends", R-11.5
**`.rc_method_preference()` is not in the Amends list and silently breaks.** `R/reconcile.R:588`
keys on `paste(rows$uuid_feature, sample_date, rows$uuid_analyte, sep = "||")`. After R-11.2
drops `uuid_feature` from `clean`, `rows$uuid_feature` is `NULL`; `paste()` treats NULL as
`character(0)` and recycles, yielding a key **without the feature component** — R-8.6 would
then dedup rows from *different features* against each other as `method_duplicate`. Rows with
`uuid_analyte = NA` (analyte-pending) also collapse into one bogus group.
**Fix:** add `.rc_method_preference` to Amends: re-key on `uuid_feature_alias`-resolved feature
(or the alias uuid when pending), and skip pending-analyte rows entirely.

### 5. BLOCKING · undeclared amendment · plan header "Amends", R-11.7
**`.rc_three_way()` is not in the Amends list** but is the caller that passes
`rows$uuid_feature[[i]]` / `rows$uuid_analyte[[i]]` into `.rc_find_existing()`
(`R/reconcile.R:527-530`). Amending only `.rc_find_existing` leaves the call site broken.
**Fix:** add `.rc_three_way` to Amends and pin its new argument list.

### 6. BLOCKING · undeclared CONTRACT conflict · R-11.8 L378-383 vs **A6**
A6 is pinned: *"Unknown feature/analyte/unit **never auto-adds registry rows** (old code
auto-added); always a `review_queue` item."* `.ct_materialise_lab_methods()` auto-inserts a
row into `lab_method` — an existing **registry** table (it is loaded by `.rc_load_registry()`,
`R/reconcile.R:16-24`) — for exactly the unknown-analyte case A6 names. This is the precise
behaviour A6 was written to forbid. A48–A53 do not cover it. (`feature_alias` is a new table
and is arguably outside A6; `lab_method` is not.)
**Fix:** add **A54** — A6 amended: unknown names may auto-create a *dangling* (`uuid_analyte
IS NULL`) `lab_method` and a `feature_alias`, never a `feature`/`analyte`/resolved
`lab_method`; the review item is still mandatory.

### 7. SHOULD-FIX · undeclared CONTRACT conflict · R-11.10/11.11/11.12 vs CONTRACT "Pinned public API"
`confirm_feature_aliases()`, `confirm_analyte_methods()`, `pending_features()`,
`pending_analytes()` are new **exported** functions. The pinned-API block does not list them,
and its `review_queue()` line explicitly says *"resolution API post-MVP"*.
**Fix:** add **A55** amending the pinned public-API block and the `review_queue()` note.

### 8. SHOULD-FIX · undeclared CONTRACT conflict · plan header vs "File layout (ownership partition)"
The partition table has **no plan-11 row**. A52 claims only `helper-db.R`. `R/feature-alias.R`,
`R/pending.R`, `dev/migrations/001-alias-indirection.R` are unowned; worse, `R/reconcile.R` is
owned by 08 and `R/commit.R`/`R/mutate.R` by 09, and plan 11 amends all three.
**Fix:** extend A52 to add a `| 11 |` row and state that plan 11's amendments to plans 08/09's
files are adjudicated cross-plan edits.

### 9. SHOULD-FIX · internal contradiction (D6 vs R-11.6) · L96-97 vs L342-343
D6: "a row that is feature/analyte-dangling AND hits a must-hold kind (`unknown_unit`, …) **is
held**". R-11.6 criterion: "a pending row is **not** skipped for an unconvertible unit". These
disagree for the analyte-pending × `unknown_unit` cell. (They agree for feature-pending: the
analyte is known, conversion is attempted, `.rc_resolve_units_values()` drops the row →
held — D6 falls out of the existing code for free.)
**Fix:** restate D6 as "**feature**-pending AND must-hold ⇒ held; an analyte-pending row never
evaluates units, so `unknown_unit` cannot fire for it".

### 10. SHOULD-FIX · internal contradiction / executability · R-11.6 L336-337 vs "Why" L21-24
**The `known_analyte_no_method` (CAS-hit) path is a subkind of `unknown_analyte` and is still
stranded.** `R/reconcile.R:196-201` gives it `status = "cas"`, which is **not** in `hit_idx`
(`:204`) — the row is dropped from `active` and only queued for review. R-11.6 says "the
`known_analyte_no_method` (CAS-hit) path is unchanged", i.e. it keeps stranding data — flatly
against the plan's headline that unknown analyte is one of the two common causes that now
commits. A test author cannot tell whether the CAS path should commit dangling.
**Fix:** state explicitly — "a CAS-hit row commits with `uuid_lab` materialised dangling
(`uuid_analyte` set from CAS)" **or** "CAS-hit remains held; that is a known carve-out, pinned
by a test" — and pick one.

### 11. SHOULD-FIX · fixture reachability · Fixtures L602 vs `tests/testthat/helper-db.R:15-24`
The test `feature` DDL is `(uuid, name, site, flow, matrix, geom_wkt, virtual)` — **no
`date_end`**. (Live `feature` *does* have `date_start DATE`/`date_end DATE` — verified.) The
fixture "a same-key pair where one feature is **defunct** at the fixture date (`date_end` set)"
and R-11.4's narrowing criterion are therefore **unreachable** unless the DDL gains the column,
which the plan never says.
**Fix:** Fixtures section: "add `date_start DATE, date_end DATE` to `helper-db.R`'s `feature`
DDL (they exist live; the test DDL is a subset)".

### 12. SHOULD-FIX · fixture reachability · R-11.5 criteria L325-327
The D6 pin ("feature-pending *and* fails units/value/datetime → held") needs a row that is
feature-unknown **and** carries an unconvertible unit. No fixture in the Fixtures section
supplies one. (Reachable, since `test-reconcile.R` builds result rows in-test — but say so.)
**Fix:** add "a feature-unknown + bad-unit row is constructed inline in `test-reconcile.R`".

### 13. SHOULD-FIX · executability (R-11.8 contract underspecified) · L373-384
A literal writer must guess at least five things:
(a) `.ct_materialise_feature_aliases()`'s find key — "find-or-create by `alias_key` with
`uuid_feature = NULL`" must be `uuid_feature IS NULL AND alias_key = ?`; `= NULL` is the
classic silent-never-matches bug and would create a new alias per file (breaking the
"two files reuse ONE pending alias" criterion);
(b) what `name` is set to (raw `feature_raw`? which row's, when a group shares a key?);
(c) `n_seen` increment granularity — R-11.1 says "a re-seen alias increments `n_seen`", R-11.8
says "per referencing **sample**", migration step 4 counts per **label sighting**, and step 3
seeds self-aliases at 0 while the Why says a self-alias's `n_seen` is the 131× correct-label
count. Four different units.
(d) whether `first_seen`/`last_seen` are the event's file date or `Sys.time()`;
(e) `.ct_materialise_lab_methods()` dedups by `(organisation, .rc_key(name), method)` — raw
`method` or `.rc_key(method)`? `.rc_lab_method_candidates()` (`R/reconcile.R:161`) uses
`.rc_key(cand$method)`; an inconsistent key here means the materialised row won't be found by
reconcile next run.
**Fix:** pin (a) `IS NULL`, (b) first row of the group's raw string, (c) one unit — recommend
"+1 per **sample** that newly points at the alias, and +1 per cypher sighting at migration" —
(d) `Sys.time()`, (e) `.rc_key(method)`.

### 14. SHOULD-FIX · executability (R-11.10 merge algorithm) · L446-452
Step 4 says "re-point the newly-resolved sample's analyses onto the pre-existing sample and
delete the emptied sample" but does not say: which of the two samples is "pre-existing" when
both were created by plan-11 commits (tie-break — earliest `sample.uuid` insert? earliest
`change_log."at"`?); what happens to the loser sample's `organisation`/`person`/`datetime` when
they differ from the winner's (silently discarded?); and whether the `value_conflict` case
("leave the existing row untouched and open a `value_conflict` review item") leaves the
duplicate analysis **on the deleted sample** — which would orphan it, since the sample is
deleted in the same step. That last one is a real bug in the algorithm as written.
**Fix:** pin "winner = the sample **not** reached through the confirmed alias; on
`value_conflict`, the duplicate analysis is re-pointed to the winner sample too (so nothing is
orphaned) and the conflict item names both analysis uuids; the emptied sample is deleted only
after every analysis has moved".

### 15. SHOULD-FIX · design · R-11.10 step 3 L445
`kind = "transcription_error"` is set **unconditionally** on confirmation. Confirming a
`descriptive` alias (`B.BORE`), a `mask_long` alias, or a `historical_code` would relabel it as
a transcription error — destroying the domain classification the migration worked to assign,
and the `old ≠ misspelling` distinction the memory calls out as load-bearing.
**Fix:** "confirmation sets `kind = "transcription_error"` **only** when the alias's current
kind is `"pending"`; otherwise `kind` is untouched".

### 16. SHOULD-FIX · risk not pinned · R-11.3 L268-269
The `.rc_key` fold is shared by `.rc_lab_method_candidates()` (`R/reconcile.R:159-166`) for
**analyte name and method** matching. The plan pins a 894-distinct-keys regression for feature
names but pins **nothing** for the analyte/method side, while explicitly calling it "the risk".
Stripping all punctuation could merge two real analytes or two real methods.
**Fix:** add the identical pinned regression — the 247 real `analyte.name` values yield 247
distinct keys, and the 365 real `(organisation, name, method)` triples stay distinct under the
new key — against a committed names-only fixture.

### 17. SHOULD-FIX · A44 regression risk · R-11.3 L256-260
The proposed `.rc_key` newly returns `NA` for `""`. Today `.rc_feature_candidates()`
(`R/reconcile.R:71-79`) survives a blank registry name only because of its trailing
`cand[!is.na(cand)]` guard: `registry$feature$uuid[.rc_key(names) == key]` with an NA on the
LHS indexes with NA and yields an NA element — the exact A44 phantom-candidate defect. The new
tibble-returning `.rc_feature_candidates()` must keep an equivalent guard.
**Fix:** R-11.4: "the returned tibble drops rows with `is.na(uuid_alias)`; the A44 NA-key guard
and the NA-registry-row guard are both retained — pinned by the existing A44 tests".

### 18. SHOULD-FIX · executability · R-11.9 L416-417
"The payload gains the alias `uuid` and `source_hash`" — but `source_hash` must be a review
**column** (`.ct_commit_review()`, `R/commit.R:298`, reads `review$source_hash`), while the
alias uuid goes in the payload **string**. The sentence conflates them, and grouping means one
review row can span several source_hashes.
**Fix:** "add a `source_hash` **column** to `.rc_proto_review()` (first source_hash of the
group); the alias uuid goes in the payload string as `alias_uuid=<uuid>`".

### 19. NOTE · scope · R-11.13 L589-592 ("This section is separable")
**Honest assessment: separable as a *plan*, not as a *deployment*, and the plan overstates it.**
The package's own tests genuinely never run it (`helper-db.R` builds the DDL directly — true,
verified), so R-11.1–R-11.12 can be built and gated without it. But there are two real
couplings the claim glosses:
(a) **R-11.4 removes the `feature_mask` lookup** (`R/reconcile.R:76`) on the stated grounds that
"its `long` names are imported by R-11.13". Land R-11.1–11.12 without step 5 and every live
`mask_long` match **regresses to unknown**. That is a hard ordering dependency, not just a
shared schema.
(b) Without the migration the live DB has no `feature_alias` and no self-aliases, so
`.rc_feature_candidates()` returns zero rows for everything — 100% of live data commits
dangling.
**Fix:** keep it separable but restate: "separable from the *test suite*; a **hard
prerequisite** for the live DB — R-11.1–11.12 must not be run against `monitoring.duckdb`
until the migration has landed, and R-11.4's `feature_mask` removal is only safe after step 5".

### 20. NOTE · behaviour change not flagged · R-11.8 criterion L394-395
"the `ingest_file` state is terminal (`archived`) legitimately" is already satisfied by existing
code without change — `.ct_set_file_states()` (`R/commit.R:331`) computes
`needs_review_only <- n_review > 0 && n_clean == 0`, and commit-everything makes `n_clean > 0`.
Correct, and worth stating as "no change needed". **But** the corollary is unflagged: an event
whose rows are **all** feature-unknown flips from `needs_review` to `archived`. Existing
`test-commit.R` / plan-10 e2e tests asserting `needs_review` for such an event will go red —
that is the plan being right, not a defect, but the plan should name the affected assertions.
**Fix:** add to R-11.8: "a 100%-unknown-feature event now archives; the existing
`needs_review` assertions in test-commit.R/test-e2e-*.R are updated accordingly (A39-style
fixture delta, no assertion weakened)".

### 21. NOTE · fixture naming · R-11.4 criteria L294-297, R-11.9 L406
Criteria are written with **real** feature names (`B.G005`, `B.S03`, `B.S04`, `B..So3`) while
the Fixtures section is synthetic (`f-0003`, `bs03alt`, `T.S01`). A literal writer will not know
whether `B.G005` is load-bearing or illustrative — and A3 forbids real data (the names-only
R-11.3 fixture is the sanctioned exception).
**Fix:** add one line — "real names in criteria are illustrative; encode them with the synthetic
fixture equivalents. Only R-11.3's names-only list uses real strings (A3 exception)".

### 22. NOTE · design, will meet real data · R-11.1 L211-215
"Duplicate prevention is by **upsert in code**" with **no DB uniqueness** and no transaction
note. Two concurrent `ingest_dir()` processes (A8 says MVP is single-process, so this is
low-risk today) or two events in one run could both miss and both insert a pending alias for
the same key. The commit path is inside `db_transaction()` (A40), which mitigates within a run.
Worth one sentence rather than a fix.
**Fix:** "the find-or-create runs inside `commit_event()`'s existing `db_transaction()`; A8
(single-process) is what makes the code-side upsert sufficient".

### 23. NOTE · plan is sound here — stated plainly
Genuinely good, do not re-litigate: (P)-over-(D) and the D3/D4 correction (both verified false-
claims, correctly retracted); the auto-hide argument (verified — all 6 sample-touching views
INNER JOIN through `feature`); D7's `units_raw` forcing argument (verified: `analysis` has no
units column, `units_raw` is in the IR at `R/ir.R:14` and is dropped at `.ct_commit_analyses()`,
`R/commit.R:192-196`); A53's redundancy argument (verified — see §A); the A39/A45 pitfall notes
for test authors (accurate and well-placed); R-11.13's step-1 backup-before-write with the
explicit `snapshot_db()` date-key trap (a genuinely good catch, and the "rehearse ≠ backup"
distinction is right); and the R-11.10 ambiguity nuance (correct, non-obvious, and correctly
identified as the thing a test author will get wrong).

---

## C. Plan-change requests

- **PCR-1 (blocks item 1):** IR has no `site` field. Either drop site-narrowing from plan 11
  (recommended — it buys 3 of 31 ambiguous keys) or open a plan-03/04/05/06 change request to
  add `site` to `.st_ir_results_types`/`.st_ir_samples_types` and to every adapter's header
  parse (ALS crosstab has `Sample Site:` per A34; ESdat and ACIRL have no obvious source).
  Evidence: `grep -rn site R/ir.R R/assemble.R R/file-meta.R` → no matches;
  `R/reconcile.R:637` passes three args.
- **PCR-2 (item 6):** A6 needs amending (A54) before any test can assert that an unknown
  analyte creates a `lab_method` row. Evidence: CONTRACT A6 vs plan L378-383;
  `R/reconcile.R:16-24` proves `lab_method` is a registry table.
- **PCR-3 (item 7/8):** CONTRACT's pinned public-API block and file-ownership partition need
  plan-11 rows (A55). Evidence: CONTRACT L26-40 (`review_queue()` "resolution API post-MVP")
  and L8-22 (no plan-11 row).

---

## [MERI]

Budget: ~55% reading (plan 660 lines + CONTRACT 447 + targeted `sed`/`grep` over
reconcile/commit/mutate/ir/helper-db rather than full reads — the four files total 1733 lines
and I read ~600 of them); ~20% five read-only `Rscript` probes against the dashboard's
`monitoring.duckdb` to verify the Evidence block; ~25% writing this.

Avoidable cost, two items: (1) the plan says "measured against the live `monitoring.duckdb`"
but `st_config("live_db")` **does not exist on this machine** — I spent one `find` plus two
probes discovering which of three candidate DBs was meant, and I still cannot fully confirm it
(the dashboard copy reports 60 views / 247 analytes where the plan says 14 / 245). A one-line
absolute path in the plan's Evidence header would have removed that. (2) The task message
listed four claims to verify but not their line numbers; locating `.rc_find_existing`'s clause
and `.rc_resolve_features`'s signature cost two extra greps. Both minor. No re-reads paid.
