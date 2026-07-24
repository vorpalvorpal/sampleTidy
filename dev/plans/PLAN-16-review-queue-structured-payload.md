# PLAN-16 — Structured `review_queue` payload

Status: PLANNED (2026-07-24). Authorised by Robin's **RULING 1** and **RULING 3** of
2026-07-24, taken while PLAN-15 was between Phase 5 and Phase 6. PLAN-15 Phase 6 is
suspended until this plan lands, because PLAN-15's own criteria assert against the payload
format this plan replaces.

Evidence base, all measured rather than assumed:
`dev/tdd-run/p16-live-db-evidence.md` (live DB, `read_only = TRUE`),
`dev/tdd-run/p16-payload-prod-inventory.md` (producer/consumer inventory),
`dev/tdd-run/p16-payload-test-inventory.md` (test-assertion inventory).

<!-- block: B-16.problem -->
## Problem (evidence-based)

`review_queue.payload` is a `VARCHAR` holding four mutually-incompatible formats, produced
by fourteen independent hand-rolled serialisers, and parsed back by regex in production.

**The format is ambiguous by construction.** The dominant shape is `k=v` pairs joined by
`,`, with `|` joining multi-values, preceded by an unkeyed positional list of `source_ref`
cell references. **Nothing is escaped anywhere.** So a value containing `,`, `|` or `=`
re-parses wrongly, silently.

That is not hypothetical. Four analytes in the live registry carry a comma in their name
(the PCB congeners, e.g. `2,2',3,3',4,4'-Hexachlorobiphenyl`), and `analyte_raw=` is written
into payloads by `R/reconcile.R:741` — `analyte_raw=Sodium Adsorption Ratio` sits in a live
payload today, proving the path is real. None of the four congeners has reached a payload
yet, so **nothing is corrupted; the window to fix this for free is open now and will close
the first time one of them is reviewed.**

**The ambiguity is two levels deep, not one.** `R/reconcile.R:467` and `:499` build
`"site=<s>,point=<p>"` — itself an unescaped `k=v` fragment — which `:593` then splices
whole into the outer payload as `,subkind=structural,site=B,point=S1`. There is no syntactic
way to tell the inner grammar from the outer.

**Production parses this back with regex.** `R/commit.R:602`:

```r
sub(".*existing_uuid=([^,}]+).*", "\\1", payload)
```

The `}` in that character class is a fossil of the column also holding JSON. And the
expression is load-bearing in a way that is easy to miss: on a payload with no
`existing_uuid=` at all the pattern does not match, so `sub()` returns the input
**unchanged** — which is exactly how the bare-uuid `already_present` payload
(`R/reconcile.R:1167`) "works". A correctness-critical behaviour rests on a regex
*failing to match*.

**The canonical serialiser is not canonical.** `.rc_serialise_payload()`
(`R/reconcile.R:108`) is called from exactly **one** of the fourteen content-producing
sites. The other thirteen rebuild the same convention by hand with `paste0()`, and do not
all agree.

<!-- block: B-16.formats -->
### The four formats actually present

| format | producer(s) | live rows |
|---|---|---|
| **(a)** `k=v` + `\|` multi-values + unkeyed `source_ref` prefix | 13 hand-built sites in `R/reconcile.R`, `R/feature-alias.R` + `.rc_serialise_payload()` | 4 |
| **(b)** hand-rolled JSON via `sprintf`, unescaped | `R/router.R:177` (`adapter_tie`, in-package); `scratchpad/f18_apply.R:86` (`asset_content_unverified`, **out of package**) | 92 |
| **(c)** a bare UUID, no structure at all | `R/reconcile.R:1167` (`already_present`) | 0 |
| **(d)** `NA` / prototype markers | 4 sites | — |

**92 of the 96 live rows were written by a scratchpad script, not by the package.** They
are uniform and valid (`{filename, state, uuid_asset}`, all 92 parse). They are
asset-integrity evidence about the archive and their content must be preserved.

**They are restructured like every other kind, not exempted** (Robin's ruling, 2026-07-24:
"they should match the rest — don't remove content, but change structure"). An earlier draft
of this plan left them as-is on the grounds that no package code reads them. That was wrong,
and the reasoning was wrong twice over: it confused *"the package does not read this"* with
*"this has no structure"*, and it would have left the column polymorphic after a refactor
whose entire purpose is to stop it being polymorphic. **One table, one schema.**

Measured (`scratchpad/p16_asset_rows.R`), these rows turn out to contain almost no
free-form content at all:

| payload key | what it actually is | tier |
|---|---|---|
| `state` | **a single constant across all 92 rows** — `"file present but bytes do not match the stored xxHash128"`. A one-member enum, not free text. | **`subkind = 'hash_mismatch'`** |
| `uuid_asset` | a real entity reference: **all 92 resolve to live `asset` rows** | **`uuid_existing`** column |
| `filename` | **identical to `asset.filename` on all 92** — a duplicate of joinable data | JSON remainder (see below) |

So the JSON remainder for this kind collapses to a single key. Two of the three fields were
never diagnostics; they were structure stored as text — which is the plan's thesis, found
again in the one place the earlier draft had exempted from it.

**`filename` is deliberately KEPT despite being derivable**, and this is a real exception to
RULING D's no-duplicates rule. The distinction is between duplicating a **live pointer** (bad
— two places to update, which is what `alias_uuid=` was) and snapshotting an **audit fact**
(good). These are integrity records asserting that a specific file's bytes did not match its
stored hash; if the asset is later renamed or re-pointed, the record must still say which
file it was about *at the time*. The duplication buys forensic fidelity, so it is deliberate
rather than accidental. Under Robin's "don't remove content", dropping it was not on offer
anyway.

<!-- block: B-16.constraints -->
## Hard constraints this design must honour

1. **~~There is no SQL-side JSON on this deployment.~~ FALSE — corrected 2026-07-24 after the
   Phase-3 audit disproved it. Retained as a POLICY, not as a physical constraint.**

   The original claim was that DuckDB's `json` extension could not autoload or install.
   **It is installed and working**: `SELECT json_valid('{}')` returns `TRUE`, all 92 JSON
   payloads validate in SQL, and `duckdb_extensions()` reports
   `loaded = TRUE, installed = TRUE, install_mode = REPOSITORY`.

   **The cause of the error was my own probe.** The evidence script ran `INSTALL json`,
   which *succeeded* — it returned zero rows with a `dbFetch()`-on-a-LOAD warning, and I read
   the empty result as failure. The extension file's mtime (13:20:48) is that probe. So the
   first autoload attempt failed, my probe fixed it, and I then recorded the pre-probe state
   as permanent. (`read_only = TRUE` on the connection does not prevent this: `INSTALL`
   writes to the extension directory, not to the database.)

   **What survives is a deliberate policy — CONFIRMED by Robin, 2026-07-24.** The reason is no
   longer "SQL cannot do it" but "we choose not to depend on a **network-fetched** extension
   for correctness". The extension is `install_mode = REPOSITORY`, so a fresh or offline
   machine gets exactly the autoload failure I first hit — and the live DB cut over to local
   with Sharepoint as a snapshot destination, so a snapshot restored on another machine is a
   real path, not a hypothetical one. A production read that depended on `json_extract` would
   work here and silently break there. The policy costs nothing today (nothing wants to query
   the remainder, which is diagnostics by construction) and it reinforces the plan's own
   thesis: a queryable field hiding in a JSON blob is the same defect as structure hidden in
   `k=v` text.

   The policy has three parts, and the second and third matter as much as the first:

   1. **Production code and committed views never read from the JSON remainder** — not with
      `json_extract`, not with a `LIKE` on serialised JSON, not by any path. All JSON
      handling in package code and in tests is R-side via `jsonlite`, a dependency already
      present. This is what R-16.6 enforces.
   2. **If a diagnostic field ever needs to be queried, promote it to a column via a
      migration — do not reach for `json_extract`.** This is the escape hatch, named so a
      future implementer does not read part 1 as a dead end. It is also the *better* move
      regardless: a column is indexable and can carry an FK; a JSON path is neither. The
      remainder holding a field is the signal that nothing queries it yet, not a barrier to
      querying it later.
   3. **This does NOT forbid a human running `json_extract` interactively.** An analyst at a
      REPL, an ad-hoc investigation, a one-off script — all fine. The policy governs
      committed correctness paths (package code, migrations, stored views), not what a person
      types into a live session.

   Not doing now, recorded so the option is not rediscovered as new: **vendoring/bundling the
   extension** would remove the portability cliff and make part 1 safe to relax. It is real
   machinery bought for queryable JSON that nothing needs yet; revisit only if a concrete
   need appears.

   The design is independent of all this: R-16.6 enforces part 1, and the column/child-table
   split stands on its own (see B-16.design — reason 5 for the child table is void now that
   SQL JSON works, but reasons 1–4 carry the decision alone).
2. **There are two independent insert paths into `review_queue` and both must be covered.**
   `review_queue_add()` (`R/db-schema.R:292`) is called only by `R/router.R`. `R/commit.R`
   and `R/feature-alias.R` bypass it entirely, building a full tibble row and calling
   `db_append(con, "review_queue", row)`. A change that only touches `review_queue_add()`
   covers one row in ninety-six.
3. **Never hand-INSERT into the authoritative DB.** The data migration runs through the
   mutation layer, like every other registry change.
4. **`schema_version` is the ladder table** (`R/db-schema.R:86`), not `.st_schema_migrations`.
   Live DB is at auto-version **4**. PLAN-15 Phase 6 will add **5** (`uuid_target`). This
   plan takes **6**. Versions 1000+ are reserved for hand-run one-offs
   (`dev/migrations/001-alias-indirection.R` holds 1001); do not use that range.
5. **FK parenthood is costly here.** `feature_alias` is already unrebuildable because
   `sample` references it (`test-migration-003.R:222-227`). Making `feature` and
   `review_queue` FK parents adds the same constraint to both. Accepted deliberately — see
   B-16.risk.

<!-- block: B-16.design -->
## Design — the hybrid shape (Robin's RULING 3)

Three tiers, assigned by **how the field is used**, not by how it looks:

| tier | goes where | rule |
|---|---|---|
| single-valued and load-bearing | **real column on `review_queue`** | anything production reads back, or any view/`WHERE` needs |
| multi-valued uuid references | **child table `review_queue_candidate`** | one row per referenced feature, FK-enforced |
| free-form diagnostics | **JSON in `payload`** | never parsed by SQL, never read by production logic |

**No regex parse of a payload survives anywhere.** That is the acceptance bar, not an aspiration.

### Why child table rather than a JSON array

Ruled by Robin ("keep things structured rather than relying on regex"), with the final pick
delegated. Child table, because:

1. **These uuids get repointed by code PLAN-15 is about to write.** E.8's
   `merge_identity_aliases()` repoints loser → winner, and `.ct_rewrite_review_payloads()`
   (`R/commit.R:243`) already rewrites payloads in place to inject `alias_uuid=`. With a
   child table both are ordinary `UPDATE`s. With a JSON array both remain string surgery on
   serialised text — the very class just ruled against, relocated rather than removed.
2. **FK integrity is live in this schema, not theoretical** (constraint 5 above). A child
   table gets real enforcement; JSON gets none.
3. It is the faithful extension of Robin's own F.15 `uuid_target` precedent: a structured
   column beat parsing a key out of free text.
4. `expired=<uuid>@<start>..<end>` is a uuid **plus a date range**, so it needs columns
   regardless. A `kind` discriminator absorbs it instead of inventing a second mechanism.
5. ~~Constraint 1 forecloses the JSON-array option anyway: with no SQL JSON, a JSON array
   cannot be joined, filtered or FK-checked.~~ **VOID — constraint 1 was disproven
   (2026-07-24). The `json` extension works, so a JSON array *could* be queried.** Reasons
   1–4 are unaffected and still carry the decision on their own: repointing, FK enforcement,
   the F.15 precedent and the `expired=` date range are all independent of whether SQL can
   read JSON. Left visible rather than deleted, so a later reader does not rediscover this
   argument and mistake it for a live one.

<!-- block: B-16.ddl -->
## DDL — schema version 6

```sql
-- 6a. new columns on review_queue
ALTER TABLE review_queue ADD COLUMN subkind       VARCHAR;
ALTER TABLE review_queue ADD COLUMN uuid_existing VARCHAR;
ALTER TABLE review_queue ADD COLUMN uuid_alias    VARCHAR;

-- 6b. the child table
CREATE TABLE IF NOT EXISTS review_queue_candidate (
  uuid          VARCHAR NOT NULL PRIMARY KEY,
  uuid_review   VARCHAR NOT NULL REFERENCES review_queue(uuid),
  uuid_feature  VARCHAR NOT NULL,   -- resolution verified by the migration, NOT an FK: see R-16.3
  kind          VARCHAR NOT NULL,   -- 'candidate' | 'expired'
  date_start    DATE,
  date_end      DATE,
  rank          INTEGER NOT NULL
);
```

> **`uuid_feature` carries no DB-level FK** (pinned default, *** ROBIN TO CONFIRM ***). An
> inline `REFERENCES feature(uuid)` is not constructible as an auto-migration — DuckDB rejects
> a `REFERENCES` to a table absent at `CREATE TABLE` time and has no `ALTER TABLE ADD FOREIGN
> KEY`, and `feature` (a corpus table) is never present when `ensure_schema()` runs v6 on a
> bare DB. Full rationale + the three reproduced facts are under **R-16.3**.

Notes that are decisions, not description:

- **`uuid_existing` / `uuid_alias`, not `existing_uuid` / `alias_uuid`.** The table's
  existing convention is `uuid`-prefixed (`uuid_target`, `uuid_asset`, `uuid_row`). The
  payload keys used the opposite order; the columns follow the table, not the payload.
- **No FK on `uuid_existing` / `uuid_alias`.** They are polymorphic — the referent's table
  depends on `kind`, and a polymorphic reference cannot carry an FK. Stated here so a
  reviewer does not read the omission as an oversight. The full referent map, which an
  implementer would otherwise have to reconstruct:

  | `kind` | `uuid_existing` points at | `uuid_alias` |
  |---|---|---|
  | `value_conflict` (`subkind='measurement'`) | `analysis(uuid)` | — |
  | `value_conflict` (`subkind='alias_merge'`) | `analysis(uuid)` | — |
  | `already_present` | `analysis(uuid)` | — |
  | `asset_content_unverified` | **`asset(uuid)`** | — |
  | `unknown_feature` / `unknown_analyte` | — | `feature_alias(uuid)`, set by the commit-time rewrite |

  **Because there is no FK, the migration must verify resolution itself** — R-16.12 and
  R-16.13 both require every reference to resolve, since the database will not check it.
  That is the price of polymorphism, paid explicitly rather than discovered later.
- **`kind` is a plain `VARCHAR`, not a `CHECK`.** DuckDB `CHECK` constraints survive this
  schema's rebuild patterns poorly, and the enum is pinned by criterion instead. If a later
  migration makes `CHECK` safe here, add it then.
- **`rank` is `NOT NULL`.** Candidate order is meaningful (it is suggestion order) and an
  unordered child table would silently lose it — the exact "a count is satisfied by the
  right number of wrong rows" failure PLAN-15's audit kept finding.
- **`date_start` / `date_end` are `DATE`, nullable.** Populated only for `kind='expired'`.
- Both new-column and new-table DDL are `IF NOT EXISTS`/idempotent-safe, because version 6
  will apply immediately after an as-yet-unapplied version 5 on the live DB.

<!-- block: B-16.api -->
## The write API — replacing fourteen hand-builders

The defect is not the serialiser; it is that **thirteen of fourteen sites do not use one**.
So the deliverable is a single structured constructor that every site calls, and the removal
of `paste0()` payload assembly from `R/reconcile.R`, `R/feature-alias.R` and `R/router.R`.

```r
.rq_row(kind, subkind = NA, work_order = NA, source_hash = NA,
        uuid_existing = NA, uuid_alias = NA,
        candidates = NULL,     # character() of feature uuids, order = rank
        expired    = NULL,     # tibble(uuid_feature, date_start, date_end)
        diagnostics = list())  # -> JSON payload, jsonlite::toJSON(auto_unbox = TRUE)
```

It returns the `review_queue` row **and** the `review_queue_candidate` rows, so a caller
cannot write one without the other. Both insert paths (constraint 2) route through it.

`.rc_serialise_payload()` is **deleted**, not repaired. `diagnostics` is serialised with
`jsonlite`, which escapes — that is what kills the comma hazard and the nesting bug by
construction, rather than by adding an escaping rule that thirteen hand-builders would each
have to remember.

**The two call-site signatures the Phase-4 tests pin, so Phase 6 matches the tests rather
than the tests being rewritten to a surprise shape** (each was a best-faith reading under
NO-SILENT-DEVIATION; recorded here so the reading is the contract):

- `review_queue_add()` gains `subkind`, `uuid_existing`, `uuid_alias` (mirroring the new
  column names 1:1) and `candidates` (a `character()` of feature uuids in rank order), and
  writes the `review_queue_candidate` child rows itself — i.e. it routes through `.rq_row()`
  rather than re-implementing it. R-16.9 asserts this path is byte-identical to the raw
  `db_append()` path.
- `.ct_rewrite_review_payloads(con, review, clean)` gains `con` as its first argument (every
  other `.ct_*` DB writer in `R/commit.R` already takes it), and `review` carries the
  `review_queue` row's own `uuid` — the key for its `UPDATE review_queue SET uuid_alias = ?
  WHERE uuid = ?`. If Phase 6 lands a different call shape it needs a delta to
  `test-review-queue-commit.R`, not a silent production rewrite to match a guess.

<!-- block: B-16.skips -->
## The skip tibble is a second carrier, and it needs the same treatment

**Added after the Phase-3 audit, which found a real hole.** Two of the fourteen producers —
`already_present` (`R/reconcile.R:1167`) and `method_duplicate` (`R/reconcile.R:984`) — do
**not** write to `review_queue` at all. They append to `skipped_list`, which becomes the
in-memory `skipped` tibble that `reconcile_event()` returns and `commit_event()` consumes.
It has its own `payload` column and it never reaches the database.

`.rq_row()` as specified in B-16.api cannot cover them, so as written this plan would have
deleted the review-side regex and left an identical one alive on the skip path — and R-16.6
would still have passed, because it scopes to `payload` values on `review_queue`.

The regex in question is the one at `R/commit.R:602`, and it reads the **skip tibble**:

```r
.ct_skip_existing_uuid <- function(skipped, i) {
  if ("existing_uuid" %in% names(skipped)) { ... }        # <- the column path already exists
  payload <- if ("payload" %in% names(skipped)) skipped$payload[[i]] else NA_character_
  sub(".*existing_uuid=([^,}]+).*", "\\1", payload)       # <- the fallback
}
```

Its own roxygen (`R/commit.R:583-588`) documents the pass-through trick explicitly, so this
is deliberate, not accidental — which is why it must be retired deliberately too.

**The fix is small, because the typed path already exists.** `.ct_skip_existing_uuid()`
already *prefers* an `existing_uuid` column and only falls back to the regex when the column
is absent. Today the column is present in the plan-09 unit-test shape and absent in the real
`reconcile_event()` shape. So:

- the skip tibble gains the same treatment as the review row: a **typed constructor**
  (`.rq_skip()`), and `existing_uuid` **always populated** for `already_present`;
- the regex fallback in `.ct_skip_existing_uuid()` is deleted, leaving only the column read;
- the skip tibble's own `payload` follows the same tier rule — diagnostics as JSON, entity
  references as columns. `method_duplicate`'s `kept_uuid_lab` becomes a column.
- **R-16.6's scope widens to both carriers.** A criterion that only forbids regex on
  `review_queue` payloads is satisfied by moving the regex to the skip path, which is
  precisely the failure this section exists to prevent.

<!-- block: B-16.read -->
## The read side — deleting both regex parsers

- `R/commit.R:602` `.ct_skip_existing_uuid` becomes a column read. **Its fallback behaviour
  must be preserved explicitly**: today a payload with no `existing_uuid=` returns the whole
  payload unchanged, which is how bare-uuid `already_present` rows resolve. In the new
  schema `already_present` writes its uuid into `uuid_existing` directly, so the fallback
  becomes unnecessary — but the equivalence must be *tested*, not assumed, because it is
  the one place where deleting a regex could silently change behaviour.
- `R/commit.R:243` `.ct_rewrite_review_payloads` becomes `UPDATE review_queue SET uuid_alias
  = ? WHERE uuid = ?`. Its append-vs-replace branch (`grepl("alias_uuid=", pl)`) disappears:
  an `UPDATE` is idempotent where string-append was not.
- `R/mutate.R:583` `review_queue()` selects `payload` but never parses it — it gains the new
  columns and needs no parsing logic. **Its docstring at `R/mutate.R:577` claims the payload
  is "JSON text", which is false today and must be corrected** (previously booked as backlog
  item 3; this plan closes it).

<!-- block: B-16.migration -->
## Data migration

**All ninety-six rows migrate.** An earlier draft of this plan said "four rows, not
ninety-six" — the *fact* behind that (only 4 rows are in the `k=v` format) is correct and
still stated in B-16.formats, but the *inference* was wrong: uniformity of the table is the
requirement, not minimality of the migration.

- **1 `unknown_analyte` + 3 `unknown_feature`** rows in format (a) are parsed once, by a
  migration-local parser, into the new columns and child rows. All 4 candidate uuids
  referenced resolve to live `feature` rows, so the FK is satisfiable with **no
  dangling-reference cleanup step**. Max fan-out is 2.
- **92 `asset_content_unverified` rows in format (b) are converted**, per B-16.formats:
  `state` → `subkind = 'hash_mismatch'`, `uuid_asset` → `uuid_existing`, `filename` → the
  JSON remainder. No content is lost and no row is dropped. This half of the migration is
  the easier one — the source is uniform, valid JSON with one key set across all 92 rows,
  and every `uuid_asset` resolves — but it is also the half where a silent failure is
  hardest to notice, because nothing in the package reads these rows to complain. R-16.12
  therefore pins the count, the key set, and the resolution of every reference.
- Format (c) and (d) have zero live rows; they are code paths, not data.
- `adapter_tie` (format (b), in-package, 0 live rows) keeps a JSON remainder — `tier` and
  `adapters` are genuinely free-form diagnostics and neither is a uuid — but it is
  serialised by `jsonlite` through the same constructor as everything else, not by
  `sprintf`. "Matching the rest" means the same tier rule applied, not the same tier chosen.

The migration is **one-way and lossy by design** (the unkeyed `source_ref` prefix becomes a
JSON array). Because it is lossy, it takes a snapshot first, per the standing rule that a
snapshot must follow every DB-changing session — here, also precede it.

**Two mechanisms, split by whether the step is lossy** (pinned after the Phase-4 test audit,
because the two test units each depend on a different half and the split was implicit):

- The **DDL** (6a columns + 6b child table) is an **auto** migration — version 6 in
  `.st_schema_migrations`, applied by `ensure_schema()` on open. It is idempotent
  (`IF NOT EXISTS`) and non-lossy, so applying it automatically is safe. This is what R-16.1
  and P16-T-schema exercise.
- The **96-row data conversion** is a **hand-run** remediation script,
  `dev/migrations/006-review-queue-payload.R`, on the `dev/migrations/00N-*.R` precedent of
  001/002 (recorded with a `1000+` marker version, not a ladder number). It is run
  deliberately by an operator with a snapshot taken first, *because it is lossy* — an
  on-open auto-migration cannot honour the snapshot-first rule, and a silent lossy conversion
  is exactly what that rule exists to prevent. This is what R-16.12 and R-16.13 exercise.

  Consequence to state plainly: between the v6 DDL applying and the operator running 006, the
  live DB carries the new columns with the legacy `payload` still un-promoted — a transient
  polymorphic state the snapshot-guarded remediation then resolves. **Robin's call to
  confirm** (this is the one design point Phase 4 could not read off the plan unambiguously):
  the alternative is a single all-in-one auto v6 that converts on open, which would orphan the
  006 script and the P16-T-migration test. The hand-run split is chosen because it matches the
  established snapshot-first / DB-changing-session discipline; if Robin prefers all-in-one,
  P16-T-migration is redirected to drive the conversion through `ensure_schema()` instead.

<!-- block: B-16.risk -->
## Risks accepted, stated plainly

1. **`feature` and `review_queue` become FK parents**, so both become harder to rebuild in
   any future migration — the same bind `feature_alias` is already in. Accepted: the whole
   point is enforcement. **Verify before implementing that no existing migration rebuilds
   either table.**
2. **PLAN-15's test suite asserts against the old format in many places.** Those assertions
   were certified over six audit rounds and rewriting them re-opens that gate. Robin has
   explicitly accepted re-entering PLAN-15's Phase 5 afterwards. The translation is mostly
   mechanical (`grepl("subkind=ambiguous", payload)` → a column equality), but **absence
   assertions are not**: `expect_false(grepl("subkind=..."))` means "this key is not in the
   string", whereas the column analogue is `is.na(subkind)` — a *different claim*, and each
   one needs deciding rather than translating.
3. **Two plans now both touch `R/commit.R` and `R/feature-alias.R`.** PLAN-15 Phase 6 is
   suspended rather than run in parallel; do not resume it until this lands.

<!-- block: B-16.outofscope -->
## Explicitly out of scope

- **`change_log.reason`.** Semi-structured provenance text, but it is never machine-parsed
  back. The defect here is *a value re-parsed through an ambiguous grammar*; a free-text
  audit note read only by humans is not that. Not a defect, not booked.
- **Migrating `scratchpad/f18_apply.R` into the package.** The governance question it raises
  — that 92 of 96 authoritative rows were written by a script outside the package — is real
  and is recorded, but fixing it is not this plan's remit. What this plan owes it is that
  **tests are written against the DB's real contents, not only against what package code can
  produce.**
- Any change to `review_queue.status` / `resolution` / `resolved_*`, which PLAN-15's F.15
  `review_queue_close()` work already owns.

<!-- block: B-16.criteria -->
## Acceptance criteria

Every criterion below must be able to FAIL against the code as it stands today. Criteria
that merely restate the DDL are marked as such and are deliberately thin — they exist to
pin a shape, and the behavioural criteria are where the gate really is.

### R-16.1 Schema version 6 applies regardless of whether version 5 exists yet
- **Rewritten after the Phase-3 audit.** The original wording required 5 to apply before 6,
  which RULING E makes unsatisfiable: version 5 is PLAN-15 Phase-6 work, and RULING E
  suspends PLAN-15 Phase 6 until PLAN-16 lands. When PLAN-16 ships, **version 5 will not
  exist in the code at all** and the ladder will read 1,2,3,4,6.
- That gap is safe, and this criterion pins why rather than assuming it: `ensure_schema()`
  (`R/db-schema.R:84-105`) iterates the `.st_schema_migrations` **list** and skips any
  version already in `schema_version`. It makes no contiguity assumption and no range scan.
- Assert all three: (a) on a DB at version 4 with **no 5 defined**, 6 applies and records;
  (b) on a DB where 6 is already applied and 5 is **later added** to the list, 5 applies on
  its own and 6 is not re-applied; (c) re-opening an already-migrated DB applies nothing and
  changes no row.
- Arm (b) is the one that matters and the one a naive test omits — it is the actual sequence
  these two plans will produce, and it exercises the migrations arriving **out of version
  order**. The two are independent (5 adds `uuid_target`, 6 adds three different columns plus
  a table), so order genuinely does not matter — but that must be demonstrated, not asserted.

### R-16.2 review_queue carries subkind, uuid_existing, uuid_alias as real columns
- all three exist with type `VARCHAR` and are nullable; none is a computed or generated column.

### R-16.3 review_queue_candidate exists with enforced foreign keys
- `uuid_review` references `review_queue(uuid)` and **is enforced**: inserting a child row
  whose `uuid_review` parent does not exist must raise. A test that only checks the constraint
  is *declared* does not satisfy this.
- `uuid_feature` is `NOT NULL` and its resolution to a live `feature(uuid)` is verified by the
  **migration itself** (R-16.12/R-16.13), NOT by a DB-level foreign key.

  **DEVIATION from B-16.ddl, surfaced at Phase-6 implementation (P16-db-schema), pinned as the
  default pending Robin's confirmation.** *** ROBIN TO CONFIRM *** The original DDL pinned
  `uuid_feature ... REFERENCES feature(uuid)`. That FK is **not constructible** as an
  auto-migration, for three independently reproduced reasons ([MEASURE TWICE],
  scratchpad/p16u1_fk_probe.R):
  1. DuckDB rejects a `REFERENCES` to a table absent at `CREATE TABLE` time with a hard
     Catalog Error (it is not a deferred constraint).
  2. DuckDB has **no** `ALTER TABLE ADD FOREIGN KEY`, so the FK cannot be added later.
  3. `feature` is a corpus/CONTRACT table, never created by `ensure_schema()`
     (ops-tables-only invariant), yet `ensure_schema()` must succeed on a bare DB (R-1.5,
     R-16.1 arm (a)), where `feature` is absent — as is every fixture path (`seed_db()` runs
     `ensure_schema()` before creating `feature`).

  The only alternative that keeps a DB-level FK is to create `feature` inside the ops-schema
  ladder, which violates the standing ops-tables-only invariant. **Chosen default:**
  `uuid_feature` carries NO FK (like the polymorphic `uuid_existing`/`uuid_alias`); the
  `uuid_review` FK is retained; referential integrity for `uuid_feature` is enforced by the
  migration's own resolution check (R-16.12/R-16.13) plus `NOT NULL`, plus every production
  writer routing real feature uuids through `.rq_row()`. This mirrors the plan's existing
  "polymorphic refs carry no FK — the migration verifies resolution itself" pattern (B-16.ddl).
  If Robin prefers the DB-enforced FK, the resolution is to add an empty `feature` table to the
  ops-schema ladder before v6 (reverting the invariant) — a change isolated to `R/db-schema.R`
  (the DDL line) and this criterion's test; NO producer unit (U2–U6) depends on the outcome.

### R-16.4 Candidate order is preserved through a write/read round-trip
- writing candidates `c(A, B)` and reading them back yields `A, B` in that order via `rank`,
  and writing `c(B, A)` yields `B, A`. A test asserting only the SET of candidates does not
  satisfy this — order is the thing at risk.

### R-16.5 The expired kind carries its date range
- a row with `kind = 'expired'` round-trips `date_start` and `date_end` as `DATE`; a row with
  `kind = 'candidate'` carries `NA` for both. Both halves required.

### R-16.6 No production code reads a payload by regex OR by SQL JSON — on EITHER carrier
- no occurrence of `sub(`, `gsub(`, `regmatches(`, `regexpr(`, `grepl(` applied to a
  `payload` value anywhere in `R/`, covering **both** the `review_queue` payload and the
  **skip tibble's** `payload` (B-16.skips). A criterion scoped to only the first is satisfied
  by relocating the regex to the second.
- **And no SQL-side read of the JSON remainder** (constraint 1, part 1): no `json_extract`,
  `json_valid`, `->`, `->>`, or `LIKE`/`SIMILAR TO` against a `payload` value in any SQL that
  package code or a migration issues, and no such reference in a stored view's definition. A
  criterion that forbids only the R-side regex is satisfied by moving the parse into SQL,
  which is the exact portability cliff the policy exists to prevent.
- This is a source-scanning assertion and must therefore be comment- and string-aware, and
  must carry its own decoy. **Two deliberate exceptions, named here so the test whitelists
  them rather than a reader "fixing" them later**: (a) the migration's one-way parser for the
  4 legacy rows (B-16.migration) necessarily parses the old format — it lives in the
  migration, not in `R/`; (b) `jsonlite` calls in `R/` are the *sanctioned* JSON path
  (constraint 1, part 1) and are not violations. The criterion forbids SQL JSON and regex,
  not R-side `jsonlite`.

### R-16.7 .rc_serialise_payload is gone
- the symbol does not exist in the package namespace, and no call site remains.

### R-16.8 Every review-writing site routes through the structured constructor
- no `paste0()`-assembled payload string survives in `R/reconcile.R`, `R/feature-alias.R` or
  `R/router.R`; each of the 14 content-producing sites in
  `dev/tdd-run/p16-payload-prod-inventory.md` §1b is covered.

### R-16.9 Both insert paths write the same shape
- a row inserted via `review_queue_add()` and a row inserted via the
  `db_append(con, "review_queue", …)` tibble path produce identical column population for
  identical inputs, including their child rows. This is the criterion that catches
  constraint 2 being half-honoured.

### R-16.10 A value containing a comma, a pipe or an equals sign round-trips intact
- write a review for an analyte named `2,2',3,3',4,4'-Hexachlorobiphenyl` (a real name from
  the live registry) plus a synthetic value containing `|` and `=`, read it back, and get the
  input byte-for-byte. **This is the criterion the whole plan exists for**; it fails against
  today's code.

### R-16.11 Nested structural fragments no longer exist
- a `structural` review exposes site and point as separate retrievable values, and no stored
  value contains an embedded `k=v` fragment.

### R-16.12 The 92 asset_content_unverified rows are CONVERTED with no information loss
- after the migration all 92 rows carry `subkind = 'hash_mismatch'`, a `uuid_existing` that
  resolves to a live `asset` row, and a JSON remainder whose `filename` equals the value the
  pre-migration payload carried. Row count is still exactly 92 and no row has a payload key
  that survived un-promoted.
- **Assert per-row, not in aggregate.** A count plus a spot-check is satisfied by 92 rows
  where the uuid and the filename have been paired up wrongly — the failure mode that
  matters here is a mis-JOIN during migration, which preserves every value and every count
  while destroying the association between them. Compare the pre- and post-migration
  `(uuid_review → uuid_asset, filename)` mapping row by row.
- This criterion is load-bearing precisely because **nothing in the package reads these rows**,
  so no other test and no user would ever notice them being silently mangled.

### R-16.13 The 4 legacy k=v rows migrate to columns and child rows with no loss
- after migration: `subkind`, `work_order`, and the `source_ref` list survive; the 3 rows
  carrying `candidates=` yield 4 distinct `review_queue_candidate` rows total, all with
  `uuid_feature` resolving to a live `feature`; and no legacy `payload` still contains `=`
  outside JSON.

### R-16.14 already_present resolves without the regex fallback
- **Scoped correctly after the Phase-3 audit:** `already_present` is a **skip-tibble**
  producer, not a `review_queue` writer (B-16.skips). The column it must populate is the skip
  tibble's `existing_uuid`, not `review_queue.uuid_existing`.
- an `already_present` skip populates `existing_uuid` on every path — including the real
  `reconcile_event()` shape, where it is absent today — and `.ct_skip_existing_uuid()`
  retains no regex fallback.
- **Both halves required**, and the second is the load-bearing one: the replacement must
  return the same uuid the regex returned **for the same input**, because the old code
  depended on the pattern *failing to match* (a bare-uuid payload has no `existing_uuid=`, so
  `sub()` returned it unchanged). Deleting a regex whose contract is "does not match" is the
  one place in this plan where a deletion can silently change behaviour.

### R-16.15 The commit-time alias rewrite is idempotent
- applying the alias-uuid rewrite twice leaves `uuid_alias` equal to the value one
  application produces. The old string-append path was not idempotent; an `UPDATE` is, and
  that difference must be pinned rather than assumed.

### R-16.16 review_queue()'s documented contract matches reality
- `R/mutate.R:577` no longer describes the payload as "JSON text" without qualification.
  Doc-only, gated by inspection at sign-off rather than by a source-scanning meta-test —
  per RULING 2, that instrument is retired.

<!-- block: B-16.testmigration -->
## Migrating the test suite

Measured, not estimated (`dev/tdd-run/p16-payload-test-inventory.md`): **109 raw `payload`
lines across 8 files, of which 77 are real assertions, 15 are hand-built fixtures and 17 are
comments.** The earlier "~93 references across 3 files" was both an overcount of assertions
and an undercount of files.

| file | assertions | fixtures |
|---|---:|---:|
| `test-reconcile.R` | 65 | 0 |
| `test-feature-alias.R` | 5 | 0 |
| `test-commit.R` | 2 | 2 |
| `test-assemble.R` | 2 | 0 |
| `test-router.R` | 2 | 0 |
| `test-mutate.R` | 1 | 0 |
| `test-pending.R` | 0 | 5 |
| `test-review-queue-close.R` | 0 | 8 |

Two pieces of good news fall out of that table. `test-assemble.R`'s two assertions already
read the **pre-serialisation list** (`review_payload[[1]]$subkind`) — they are structurally
already what this schema wants, and need no change. `test-router.R`'s two are substring
checks on genuine JSON and survive as-is.

### RULING A — absence assertions translate to the POSITIVE form, not to `is.na()`

15 assertions are `expect_false(grepl("subkind=X", payload))`. Translating each to
`is.na(subkind)` would be a **stronger and different claim** than most of them make: they are
mostly discriminating between two known alternatives (e.g. `suggestion` vs `ambiguous`), not
asserting the field is unset.

The rule, in order of precedence:

1. Where a test asserts presence of one value **and** absence of another **on the same
   field**, the pair collapses to a single `expect_identical(row$subkind, "<the one>")`. That
   is strictly stronger than both halves together and it removes an assertion rather than
   translating it. **Prefer this; it is the common case.**
2. Where a test asserts absence of a specific value with no paired presence, it becomes
   `expect_false(identical(row$subkind, "X"))` — same claim, typed.
3. Where a test asserts no clause exists at all (`expect_false(grepl("subkind=", payload))`,
   `test-reconcile.R:3156`), it becomes `expect_true(is.na(row$subkind))`.
4. **Assertions that exist only to test the serialiser are DELETED, not translated.** In a
   column world there is no serialiser to test, and translating one manufactures a vacuous
   test. `test-reconcile.R:3156` is the flagged instance: it asserts the serialiser omits the
   clause rather than emitting `subkind=NA`. Check it against rule 3 first — if the
   behavioural claim survives, keep the behavioural half only.

Rule 1 means the suite should get SMALLER here, and a growing assertion count in this area is
a signal that something is being translated mechanically rather than understood.

### RULING B — the two `value_conflict` grammars stay one `kind`, discriminated by `subkind`

Confirmed in the source: `R/reconcile.R:1181-1186` emits
`existing_value/incoming_value/existing_uuid/existing_quantified/incoming_quantified/recorded_revision/incoming_revision`,
while `R/feature-alias.R:242-248` emits `uuid_existing/uuid_new/value_existing/value_new` —
**different key names for overlapping concepts, under one `kind`.** Note `existing_value` vs
`value_existing`: the same concept, spelled two ways.

Do **not** split them into two `kind`s. `kind` is a user-visible value that existing queries
and the review workflow already key on, and changing it is a behaviour change outside this
plan's remit. Discriminating them is precisely what `subkind` is for, and this plan is
introducing `subkind` as a real column anyway:

- `kind = 'value_conflict', subkind = 'measurement'` — the `R/reconcile.R` producer.
- `kind = 'value_conflict', subkind = 'alias_merge'` — the `R/feature-alias.R` producer.

Both map their existing-uuid onto the single `uuid_existing` column.

**They also share one vocabulary** (Robin's ruling, 2026-07-24: *"should we fix this so they
use the same vocab?"*). An earlier draft of this ruling claimed the naming collision became
"moot" once the values moved to JSON. That was wrong — JSON keys are still keys, so
`{"existing_value": …}` vs `{"value_existing": …}` would have carried the collision straight
through the refactor untouched. Fixing storage is not fixing vocabulary.

Verified in the source before unifying, because forcing shared terms onto genuinely different
relationships would be worse than leaving them apart. They are the same relationship: **an
incumbent and an arrival in conflict over the same `(sample, lab_method)` slot.** In
`.rc_three_way` the arrival comes from the file being ingested; in `.fa_merge_samples`
(`R/feature-alias.R:215-250`) it arrives by being re-pointed onto the winner sample during an
alias merge. That difference is *how the arrival got there* — which is precisely what
`subkind` now records, so the field names must not encode it a second time.

The scheme is `<thing>_<role>`, `role ∈ {existing, incoming}` — noun-first, matching the
`uuid_existing` / `uuid_alias` column convention this plan already adopts, and sorting keys
by concept rather than by role.

| concept | `reconcile.R` today | `feature-alias.R` today | unified |
|---|---|---|---|
| incumbent analysis uuid | `existing_uuid` | `uuid_existing` | **column `uuid_existing`** |
| arriving analysis uuid | *(none — see below)* | `uuid_new` | `uuid_incoming` (JSON) |
| incumbent value | `existing_value` | `value_existing` | `value_existing` |
| arriving value | `incoming_value` | `value_new` | `value_incoming` |
| incumbent quantified flag | `existing_quantified` | — | `quantified_existing` |
| arriving quantified flag | `incoming_quantified` | — | `quantified_incoming` |
| revision on record | `recorded_revision` | — | `revision_existing` |
| arriving revision | `incoming_revision` | — | `revision_incoming` |

Two decisions inside that table worth stating rather than burying:

- **`incoming`, not `new`.** "New" is ambiguous (new to the database? newly created?);
  "incoming" names the direction of data flow, which is the actual concept, and it is already
  the vocabulary of the larger producer.
- **`recorded_revision` → `revision_existing` is a rename beyond the strict collision.**
  It is not one of the clashing pairs, but leaving it as the one field outside the scheme
  would make the vocabulary half-unified, which is worse than either alternative. Note its
  source is `.rc_recorded_revision()`, whose name does not change.

**The asymmetry is real and is preserved, not papered over:** `uuid_incoming` is **absent for
`subkind='measurement'`**, because at conflict time the incoming value is not yet a row and
has no uuid. A unified vocabulary must not imply a field exists where it cannot.

### RULING C — do NOT backfill coverage on the old format

Five producers have **zero** assertions on their payload content today — `unknown_unit`,
`parse_error`, `already_present`, `method_duplicate`, `batch_duplicate` (every test checks
only `kind`/`reason`). That is roughly half of `R/reconcile.R`'s distinct producers.

Backfilling tests against the old string format would mean writing tests for a format this
plan deletes, then deleting them — pure waste. Design their new shape directly from the
production code's intent, and pin it with new criteria (R-16.17). **The absence of an old
test is not permission to land these five untested.**

### RULING D — no human-readable duplicate survives in the payload

`R/commit.R:.ct_rewrite_review_payloads()` currently regex-rewrites `alias_uuid=` into the
payload string *in parallel with* PLAN-15's typed `uuid_target` column — the same value in
two places, one typed and one parsed. That duplication is the defect pattern this plan
exists to remove, so after PLAN-16 lands `uuid_alias` is the **only** representation and the
`alias_uuid=` clause is not re-emitted into the JSON remainder for human convenience.
If reviewers need it rendered, that is a presentation concern for the reader function, not a
storage concern.

### RULING E — sequencing: PLAN-16's schema lands BEFORE PLAN-15's Phase 6

**35 of `test-reconcile.R`'s 65 assertions are currently RED** — they describe
`subkind=suggestion`, `subkind=expired_alias`, `subkind=self_precedence_note`, `expired=`
and `blocking=`, none of which exist anywhere in `R/` (grep-confirmed). They are PLAN-15
Phase-6 behaviour, written in the payload grammar PLAN-16 deletes.

That creates a real hazard and a false one. The false one first: rewriting a RED test into
the new schema, where it stays RED, is **not** a lost signal — those 35 were never going to
be green before PLAN-15 Phase 6 regardless. Normal TDD.

The real hazard is the other 30, which are **green today**. Rewriting a green assertion is a
green→green change, and a mistranslation there is invisible unless it is measured. So:

1. PLAN-16's DDL, constructor and data migration land first.
2. The test migration runs in two clearly separated passes, and **the green ones go first**:
   the ~30 currently-green assertions are rewritten and must be **green again immediately**,
   per-file counts accounted to the unit. Any change in the green count is a mistranslation
   until proven otherwise.
3. Only then are the 35 RED assertions rewritten. They stay red. Their correctness is
   established by **review against the criterion they encode**, not by execution — state
   this plainly rather than implying the suite verifies them.
4. PLAN-15 Phase 6 then implements directly against the new schema, and those 35 go green
   there. It never implements against the format being deleted.

This ordering is why PLAN-15 Phase 6 is suspended rather than raced.

### The fixture hazard

**15 sites build payload strings by hand**, and 4 of them (`test-commit.R:680`,
`test-review-queue-close.R:186-187`, `:317`, `:372`) mimic the real `.rc_feature_review()`
grammar closely enough that, if the new writer accepts a pass-through string argument, they
would **keep exercising the old regex path while looking like they had been migrated.** This
is the "fixture supplies what production must supply" class that PLAN-15's audit named twice.
The mitigation is structural, not vigilance: the new constructor takes no free-text payload
argument at all (B-16.api), so a hand-built string cannot be injected. R-16.18 pins that.

<!-- block: B-16.criteria2 -->
## Acceptance criteria (continued)

### R-16.17 The five previously-uncovered producers have their shape pinned
- `unknown_unit`, `parse_error` and `batch_duplicate` (review-queue producers) plus
  `already_present` and `method_duplicate` (**skip-tibble** producers — see B-16.skips) each
  get at least one assertion on their structured content, not merely on `kind` or `reason`.
- The split matters: a test that looks for the last two in `review_queue` will find nothing
  and can be "fixed" into vacuity. Assert them on the tibble `reconcile_event()` returns.
- These have no old-format coverage to translate, so they are new work — which is why they
  are named individually here rather than left to a general sweep.

### R-16.18 The constructor accepts no free-text payload
- the structured constructor has no argument that takes a pre-serialised payload string, and
  no production path allows one to be supplied. This is what makes the 15 hand-built test
  fixtures fail loudly rather than silently keep passing.

### R-16.19 value_conflict is discriminated by subkind, not by two grammars
- both producers write `kind = 'value_conflict'`; the `R/reconcile.R` producer writes
  `subkind = 'measurement'` and the `R/feature-alias.R` producer writes
  `subkind = 'alias_merge'`; both populate `uuid_existing`. Assert both producers in one
  test so the pair cannot drift apart again.

### R-16.20 The two value_conflict producers share one vocabulary
- for the fields the two producers have in common, the key names are **identical**:
  `value_existing` and `value_incoming` appear in both, and neither `existing_value`,
  `incoming_value`, `value_new` nor `uuid_new` appears anywhere.
- assert this by **comparing the two producers' key sets to each other** — not by checking
  each against a hard-coded list. A test that pins each producer separately passes happily
  while they drift apart, which is the failure this criterion exists to prevent. The shared
  subset must match exactly; the reconcile-only extras (`quantified_*`, `revision_*`) are
  the permitted difference.
- **`uuid_incoming` must be absent, not `NA`, for `subkind='measurement'`** — the incoming
  value is not yet a row and has no uuid, and a unified vocabulary must not imply a field
  exists where it cannot.

### R-16.21 The alias uuid is stored once
- after a commit-time alias rewrite, `uuid_alias` holds the uuid and the JSON remainder
  contains no `alias_uuid` key. A test asserting only that `uuid_alias` is correct does not
  satisfy this — the point is the absence of the duplicate.
