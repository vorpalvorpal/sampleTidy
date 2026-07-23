# Adjudication of the PLAN-15 cold plan audit (2026-07-23)

Every finding in `scratchpad/PLAN-AUDIT-2026-07-23.md` re-verified independently
against the code and the live registry
`/Users/rjs/Library/Application Support/org.R-project.R/R/sampleTidy/monitoring.duckdb`
(read-only). Auditor findings are hypotheses; the verdicts below are mine.

Scripts: `scratchpad/v_db.R`, `v_db2.R`, `v_dates.R`, `v_resolver.R`, `v_fixture.R`.

Frame check: live scale is **895 features / 1,994 aliases / 15,149 samples** — the
audit's framing fact (that Work E was measured against an 894/1,989/15,113
pre-cutover snapshot) is correct.

## ACCEPTED — 21 findings

| # | claim | how I confirmed it |
|---|---|---|
| 1 | E.5's 8 keys span **19** arms, not the 17 the plan pins; `b.s01` and `k.e02` are already `auto_assign = TRUE` | queried the plan's actual key set (`b.s01, b.ts02, b.ts41, b.s22, b.s04, k.e02, b.ts18, b.ts40`): 19 arms, 2 TRUE, both `kind='transcription_error'`, `confirmed_by='R. Shannon'`. Ran the real resolver: `B.S01` → n=1, `K.E02` → n=1. Both already auto-resolve. |
| 2 | "003 aborts if a feature lacks a `self` alias" cannot fail | 0 of 895 live features and 0 of 13 fixture features lack one |
| 3 | 003's criteria are unexecutable | none of `b.s01/b.ts18/k.e02/b.ts02` appear in `helper-db.R` **or** `helper-migration-db.R`; the latter has 11 `cypher` references, i.e. pre-001 |
| 4 | F.3 unbuilt and its oracle now contradicts shipped F.2 | `test-reconcile.R:851` still defines `mig_normalize` locally; `sys.source` appears 0 times in the file |
| 5 | F.10 as written blocks A12 supersede | `.rc_find_existing` (reconcile.R:1009) and `.rc_recorded_revision` (:1067) both exist and both depend on the precondition F.10 would block |
| 7 | `subkind` grammar collides | accepted **with a correction**: the code *does* already pin ambiguous > structural (reconcile.R:587–593). The unpinned part is F.6's `suggestion` and E.3's `expired_alias`, which add two more values with no total order. |
| 8 | F.9 is a prerequisite of Work B and of 003 | `add_feature()` appends to `feature` only — no self alias |
| 9 | the dry-run gate is unexecutable | `assets/` does not exist |
| 10 | F.11's blocking premise is stale | **2** of 15,149 samples have NULL `datetime`, not 35 of 36 |
| 11 | F.11 lists the wrong views | inspected every non-internal view's SQL: **only `v_feature_dates`** references a date token |
| 12 | F.12's fold-in rationale is false and it re-creates F.11's dependency | rationale cites "the six `date`-referencing views" (there is one); F.12(b) restores a projection "including `date`" |
| 13 | F.18's "the value remains unknown" is contradicted by CONTRACT A5 | text still live at PLAN-15:1146; also `change_log.source_hash` is **100% 64-char** over 1,412 rows while new writes are 32-char |
| 14 | F.16 contradicts itself | :874–875 pins `value == rl_low` as "a testable invariant"; :893 says the opposite. **232** live rows have `value > rl_low` |
| 15 | three documents still pin two-state `quantified` | `PLAN-08:57`; `COVERAGE-MAP:307` maps to a test name ending "quantified TRUE" while the real test is `R-8.4: … quantified NA` |
| 16 | the "pending the live cutover" section is stale | D.1 (B.L05 / site B / leachate) and D.2 (both `descriptive` aliases, `auto_assign` TRUE) applied; `schema_version` = 1,2,3,4,1001 — **no 1002**; `ingest_file` 10 archived / 19 quarantined |
| 17 | F.4's oracle admits the mutation it targets | against the shipped fixtures `TS1` → TH.S01, `TS01` → {} — "different features" is satisfied, and would also be satisfied by `TS01` → T.S01 |
| 19 | F.5 and F.7 carry no acceptance criteria | both 0; six other F items have "Acceptance (must be able to FAIL)". F.7 bullet 1 stands: the roxygen says the key is `.rc_key(feature_raw)`, the body uses `rows$alias_key[[i]]` |
| 20 | F.15 is not implementable | `review_queue` has no column linking an item to a `feature_alias`; nothing in `R/` writes `status` |
| 21 | `b.s22` stays unreachable | `.rc_feature_candidates("B.S22")` → n=0 today |
| 23 | line citations drift ~+270 | `auto_assign` filter 155→**171**; `"pending"` 258→**455**; `length(sugg)>1` 264→**461**; `.rc_feature_key` 67→**81**. `.rc_parse_dates` does not exist — the function is `.rc_resolve_datetime` (:900) |
| 24 | `.rc_alias_rows_exist` is already built | reconcile.R:280–285, date-blind and `auto_assign`-blind, exactly as E.3 specifies |

## REJECTED / CORRECTED — 3

**#6 — the finding stands, the auditor's replacement dates are wrong by one day.**
E.5's two proxy literals *are* stale. But the corrected values are **not** the
auditor's 2026-05-26 / 2026-05-05. Measured every representation side by side
(`v_dates.R`) — raw `date`, raw `datetime`, `CAST(date AS DATE)`, and both
Sydney-local conversions all agree:

| item | plan pins | auditor says | **actual** |
|---|---|---|---|
| `k.e02` → K.S06 | 2025-09-04 | 2026-05-26 | **2026-05-25** |
| `b.s04` → B.S01 | 2026-03-16 | 2026-05-05 | **2026-05-04** |

Writing the auditor's numbers into the plan would have planted the day-early
landmine this project has already been bitten by. Use 2026-05-25 / 2026-05-04.

**#4's supporting claim is wrong — and the finding is stronger than the auditor thought.**
The audit says F.3's three named discriminating inputs (`"B.  S01"`, `" B.S01"`,
`"B.S01\t"`) "all still agree, so they do not discriminate either." Hexdumped, the
second one is not a leading space: it is `c2 a0`, **U+00A0 NBSP**. Measured against
the real functions, the two diverge on it — `.rc_feature_key("T.S01"+NBSP)` →
`"t.s01"`, `.mig001_normalize(...)` → `"t.s01 "`. So the plan's own listed
input IS discriminating, and it is exactly the input F.2 was written to handle.
F.3's prescribed parity test therefore fails on the plan's own example. The
finding stands; its stated reason does not.

**#14's BDL total is wrong.** 47,227 is the count of *all* `quantified = FALSE`
rows. The set where the comparison is even defined — `value` and `rl_low` both
non-null — is **35,174**. The 232 / 0 figures are correct and the finding stands.

**#22 — rejected on both halves.** (a) A10 routes ACIRL dust sheets to state
`ignored`, not `quarantined`, so F.17's "zero `quarantined` files for that event"
does not collide with A10. (b) F.18's dual-layout rule governs *reading legacy*
assets; F.17 is new-ingest code, which only ever writes
`<archive_dir>/<uuid>/<filename>`. Neither half survives.

## Sound sections — spot-checked, no action

895 features / 895 distinct names (B.3 injectivity holds); the collision oracle
is intact on live data (`BS1` → BH.S01, `B.S1` → B.S01, `BS01` → no resolve);
fixtures seed a self alias for all 13 features.

## Sequencing consequences accepted

`F.9 → 003` · `F.5 → F.6 → E.3` in one pass with one precedence table ·
`F.11 → F.12` · F.10's supersede exemption before F.10 · F.15's schema decision
before F.15.
