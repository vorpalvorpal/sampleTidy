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
asset-integrity evidence about the archive and must be preserved exactly; no package code
produces or reads them, so nothing needs promoting to columns.

<!-- block: B-16.constraints -->
## Hard constraints this design must honour

1. **There is no SQL-side JSON on this deployment.** DuckDB's `json` extension is not
   vendored and cannot autoload (`SELECT json_valid('{}')` → autoload error; `INSTALL json`
   cannot fetch). JSON in `payload` is therefore **opaque text to SQL** — storable,
   selectable and comparable only as a whole string. **Nothing queryable may live in JSON.**
   All JSON handling is R-side via `jsonlite`. Any test asserting JSON structure asserts it
   in R, never in SQL. This constraint independently produces Robin's RULING 3 shape.
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
5. Constraint 1 forecloses the JSON-array option anyway: with no SQL JSON, a JSON array
   cannot be joined, filtered or FK-checked.

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
  uuid_feature  VARCHAR NOT NULL REFERENCES feature(uuid),
  kind          VARCHAR NOT NULL,   -- 'candidate' | 'expired'
  date_start    DATE,
  date_end      DATE,
  rank          INTEGER NOT NULL
);
```

Notes that are decisions, not description:

- **`uuid_existing` / `uuid_alias`, not `existing_uuid` / `alias_uuid`.** The table's
  existing convention is `uuid`-prefixed (`uuid_target`, `uuid_asset`, `uuid_row`). The
  payload keys used the opposite order; the columns follow the table, not the payload.
- **No FK on `uuid_existing` / `uuid_alias`.** They point at different tables depending on
  `kind` (an analysis uuid for `value_conflict`, a feature_alias uuid for the commit
  rewrite). A polymorphic reference cannot carry an FK. Stated here so a reviewer does not
  read the omission as an oversight.
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

**Four rows.** Not ninety-six — that number conflated the two formats.

- **1 `unknown_analyte` + 3 `unknown_feature`** rows in format (a) are parsed once, by a
  migration-local parser, into the new columns and child rows. All 4 candidate uuids
  referenced resolve to live `feature` rows, so the FK is satisfiable with **no
  dangling-reference cleanup step**. Max fan-out is 2.
- **92 `asset_content_unverified` rows in format (b) are left exactly as they are.** They
  are already valid JSON and already in the tier this design assigns them to. The migration
  must not rewrite them — and a criterion must pin that, because "no package code reads
  them" must never decay into "safe to discard".
- Format (c) and (d) have zero live rows; they are code paths, not data.

The migration is **one-way and lossy by design** (the unkeyed `source_ref` prefix becomes a
JSON array). Because it is lossy, it takes a snapshot first, per the standing rule that a
snapshot must follow every DB-changing session — here, also precede it.

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

### R-16.1 Schema version 6 applies on top of an unapplied 5
- opening a DB at auto-version 4 applies 5 then 6 in order and records both in
  `schema_version`; opening an already-migrated DB applies neither and changes no row.
  (The live DB is at 4 with 5 unapplied, so this is the real upgrade path, not a synthetic one.)

### R-16.2 review_queue carries subkind, uuid_existing, uuid_alias as real columns
- all three exist with type `VARCHAR` and are nullable; none is a computed or generated column.

### R-16.3 review_queue_candidate exists with enforced foreign keys
- `uuid_review` references `review_queue(uuid)` and `uuid_feature` references
  `feature(uuid)`, and **both are enforced**: inserting a child row whose parent uuid does
  not exist must raise, for each of the two FKs independently. A test that only checks the
  constraint is *declared* does not satisfy this.

### R-16.4 Candidate order is preserved through a write/read round-trip
- writing candidates `c(A, B)` and reading them back yields `A, B` in that order via `rank`,
  and writing `c(B, A)` yields `B, A`. A test asserting only the SET of candidates does not
  satisfy this — order is the thing at risk.

### R-16.5 The expired kind carries its date range
- a row with `kind = 'expired'` round-trips `date_start` and `date_end` as `DATE`; a row with
  `kind = 'candidate'` carries `NA` for both. Both halves required.

### R-16.6 No production code parses a payload with a regex
- no occurrence of `sub(`, `gsub(`, `regmatches(`, `regexpr(`, `grepl(` applied to a
  `payload` value anywhere in `R/`. This is a source-scanning assertion and must therefore be
  comment- and string-aware, and must carry its own decoy. **Deliberate exception, named
  here so the test can whitelist it rather than a reader "fixing" it later**: the migration's
  one-way parser for the 4 legacy rows (B-16.migration) necessarily parses the old format;
  it lives in the migration, not in `R/`, and the criterion is scoped to `R/`.

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

### R-16.12 The 92 asset_content_unverified rows survive the migration byte-identically
- before/after the migration, all 92 rows still parse as JSON and still carry exactly
  `{filename, state, uuid_asset}`, and their `payload` strings are unchanged. Pin the count
  as 92 **and** the key set — a count alone is satisfied by 92 wrong rows.

### R-16.13 The 4 legacy k=v rows migrate to columns and child rows with no loss
- after migration: `subkind`, `work_order`, and the `source_ref` list survive; the 3 rows
  carrying `candidates=` yield 4 distinct `review_queue_candidate` rows total, all with
  `uuid_feature` resolving to a live `feature`; and no legacy `payload` still contains `=`
  outside JSON.

### R-16.14 already_present resolves without the regex fallback
- an `already_present` skip populates `uuid_existing` directly, and
  `.ct_skip_existing_uuid`'s replacement returns the same uuid the regex returned for the
  same input. **Both halves required**: this is the one place where deleting a regex can
  silently change behaviour, because the old code depended on the pattern *failing to match*.

### R-16.15 The commit-time alias rewrite is idempotent
- applying the alias-uuid rewrite twice leaves `uuid_alias` equal to the value one
  application produces. The old string-append path was not idempotent; an `UPDATE` is, and
  that difference must be pinned rather than assumed.

### R-16.16 review_queue()'s documented contract matches reality
- `R/mutate.R:577` no longer describes the payload as "JSON text" without qualification.
  Doc-only, gated by inspection at sign-off rather than by a source-scanning meta-test —
  per RULING 2, that instrument is retired.
