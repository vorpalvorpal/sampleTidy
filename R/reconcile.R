# Plan 08/11 - R/reconcile.R: the reconciler.
#
# `reconcile_event(event, con)` -> `list(clean, review, skipped, counts)`.
# Read-only against the DB (CONTRACT A32) - every access below is a
# `DBI::dbGetQuery()`; there are no raw table-write calls anywhere in this
# file. Deterministic rules only; no LLM (DESIGN Sec7).
#
# PLAN-11 turns the old FUNNEL into a CONVEYOR: a row whose feature or analyte
# cannot be resolved is no longer DROPPED into review - it STAYS in `active`
# carrying `feature_pending` / `analyte_pending`, is annotated, flows through
# the remaining stages and commits DANGLING (a pending alias / dangling
# lab_method is materialised at COMMIT, D8). Its review item becomes a
# worklist entry over committed data, not a commit gate. Only rows we do not
# trust at all (assembly's inline flags - R-11.14; a NA/blank feature_raw with
# no key to hang a pending alias on; a resolved row that fails units/value or
# datetime) are HELD.
#
# See dev/plans/PLAN-08-reconcile.md and PLAN-11-feature-alias.md.

# ---- registry loading (read-only snapshot of the small core tables) ------

#' Pull the small core registry tables into memory once per reconcile run
#' @keywords internal
#' @noRd
.rc_load_registry <- function(con) {
  list(
    feature = DBI::dbGetQuery(con, "SELECT * FROM feature"),
    feature_alias = DBI::dbGetQuery(con, "SELECT * FROM feature_alias"),
    feature_mask = DBI::dbGetQuery(con, "SELECT * FROM feature_mask"),
    analyte = DBI::dbGetQuery(con, "SELECT * FROM analyte"),
    lab_method = DBI::dbGetQuery(con, "SELECT * FROM lab_method"),
    project = DBI::dbGetQuery(con, "SELECT * FROM project")
  )
}

# ---- small shared helpers --------------------------------------------------

#' Fold a text key for exact (non-fuzzy) matching (B-11.3).
#'
#' Strips ALL non-alphanumerics (so `B.S01`, `B S01`, `BS01`, `b.s01` and
#' `B..S01` all share one key) and case-folds. A NA input, or one that folds to
#' the empty string (blank/punctuation-only), returns NA (A44 guard) so it
#' never collapses into a phantom length-1 candidate.
#' @keywords internal
#' @noRd
.rc_method_key <- function(x) {
  k <- tolower(gsub("[^[:alnum:]]", "", normalise_lab_text(x)))
  k[is.na(x) | k == ""] <- NA_character_
  k
}

#' Fold a *feature* (sampling-point) name to its registry alias key (PLAN-15 A).
#'
#' Unlike `.rc_method_key`, this PRESERVES internal punctuation - it reproduces exactly
#' the key that migration-001's `.mig001_normalize` (`tolower(trimws(x))`) writes
#' into `feature_alias.alias_key`. A feature name encodes `(site, point)` with a
#' separator (`B.S01`, `K.E02`); stripping the separator fuses genuinely distinct
#' cross-site codes (`BS1`->BH.S01 vs `B.S1`->B.S01), so reconcile must look
#' features up with the SAME punctuation-preserving normaliser the migration used.
#' A NA input, one that folds to the empty string, or one carrying NO
#' alphanumeric character at all returns NA (A44 guard). This is deliberately
#' NOT `.rc_method_key`, which stays the folded key for lab-method matching and
#' intra-event dedup.
#'
#' PLAN-15 F.1: the guard covers PUNCTUATION-ONLY input too. A `feature_raw` of
#' `"."` used to fold to the key `"."`, survive the A44 guard and make commit
#' materialise `feature_alias(alias_key = '.', kind = 'pending')` plus a sample
#' against it. `.rc_method_key` held these (it strips non-alphanumerics, so `"."`
#' folded to `""`); adopting tolower+trim silently dropped that property.
#'
#' PLAN-15 F.2: the trim is UNICODE-AWARE (`[\h\v]`, so NBSP / vertical tab /
#' form feed are stripped too) and the input first goes through
#' `normalise_lab_text()`, matching the hygiene `.rc_method_key` already had.
#' `trimws()` alone leaves a trailing NBSP in place, so `"T.S01 "` keyed
#' apart from `"t.s01"` and commit created a SECOND alias - and a second sample
#' for a point that already exists. Internal whitespace is NOT squished: the
#' migration's `.mig001_normalize` does not squish either, and the stored
#' `alias_key` is the contract.
#' @keywords internal
#' @noRd
.rc_feature_key <- function(x) {
  k <- trimws(tolower(normalise_lab_text(x)), whitespace = "[\\h\\v]")
  k[is.na(x) | is.na(k) | !grepl("[[:alnum:]]", k)] <- NA_character_
  k
}

#' NA-safe vectorised `isTRUE()`.
#' @keywords internal
#' @noRd
.rc_is_true_vec <- function(x) !is.na(x) & x

# ---- PLAN-15 E.1/E.2: DATE bounds, never routed through POSIXct ------------
#
# Every bound in this file (`feature_alias.date_start`/`date_end`,
# `feature.date_end`) is a DATE and every comparison happens at DATE
# granularity. `as.Date()` on a POSIXct is TIMEZONE-DEPENDENT - it is the
# silent-corruption bug already fixed once at the `.rq_row()` driver boundary
# (a local Australia/Sydney timestamp before 10:00 truncates to the PREVIOUS
# day in UTC) - so a POSIXct bound is REJECTED here rather than coerced, the
# same ruling (Robin, 2026-07-25) `.rq_row()` follows. Coercing would make
# this function silently PICK a day instead of storing the wrong one.

#' Coerce a stored bound column to class `Date` without ever going through
#' POSIXct (E.1/E.5). A DATE column already reads back as `Date` through the
#' duckdb driver, so this is the identity in practice; the character branch
#' covers an ISO string and the all-NA branch a typeless placeholder column.
#' @keywords internal
#' @noRd
.rc_as_date_bound <- function(x, what = "date bound") {
  if (is.null(x)) return(NULL)
  if (inherits(x, "Date")) return(x)
  if (all(is.na(x))) return(rep(as.Date(NA), length(x)))
  if (is.character(x)) {
    out <- as.Date(x, format = "%Y-%m-%d")
    # PLAN-7b item 6(a): a non-NA character input that does NOT parse as ISO
    # 'YYYY-MM-DD' (e.g. "2026/05/04") used to come back NA - i.e. UNBOUNDED,
    # i.e. ADMITTING the row - silently defeating a bound a curator set, while
    # the POSIXct branch two lines below aborts loudly on the same class of
    # mistake. Abort here too, rather than let a spelling error masquerade as
    # "no bound at all".
    bad <- !is.na(x) & is.na(out)
    if (any(bad)) {
      cli::cli_abort(
        "{what} contains a value that does not parse as an ISO 'YYYY-MM-DD'
         date: {.val {unique(x[bad])}}.",
        class = "sampletidy_error"
      )
    }
    return(out)
  }
  cli::cli_abort(
    "{what} must be class Date (or an ISO 'YYYY-MM-DD' string); got class
     {.cls {class(x)}}. Not auto-converted: as.Date() on a POSIXct is itself
     timezone-dependent - the exact silent-corruption bug PLAN-15 E.1's
     'DATE, not TIMESTAMP' rule exists to prevent.",
    class = "sampletidy_error"
  )
}

#' One alias bound column as a length-`n` `Date` vector.
#'
#' S-15.5: against a PRE-003 database `feature_alias` has NO `date_start` /
#' `date_end` columns at all (the registry load is `SELECT *`, so they are
#' ABSENT, not columns of NA). Absent means UNBOUNDED on that side and must
#' never error - it is exactly today's behaviour.
#' @keywords internal
#' @noRd
.rc_alias_bound <- function(fa, col, n) {
  x <- if (col %in% names(fa)) fa[[col]] else NULL
  if (is.null(x)) return(rep(as.Date(NA), n))
  .rc_as_date_bound(x, what = paste0("feature_alias$", col))
}

#' Is each `feature_alias` row LIVE at `sample_date` (E.2)?
#'
#' `(date_start IS NULL OR date_start <= sample_date) AND
#'  (date_end IS NULL OR date_end >= sample_date)`, both sides compared as
#' DATE, `date_end` INCLUSIVE. A contradictory bound (`date_start > date_end`)
#' satisfies neither half at any date, so the arm is never live - which is the
#' point of ANDing the two halves rather than testing one side at a time.
#'
#' E.6/R-15.21: a NA `sample_date` is NO BASIS TO NARROW, so every arm stays
#' live. This is handled EXPLICITLY, not left to the comparison: `NA >= x` is
#' NA and NA in a filter DROPS the row, i.e. the exact opposite of "unchanged
#' behaviour".
#' @return logical vector, one element per row of `fa`.
#' @keywords internal
#' @noRd
.rc_alias_live <- function(fa, sample_date) {
  n <- if (is.null(fa)) 0L else nrow(fa)
  if (n == 0) return(logical(0))
  if (length(sample_date) != 1) return(rep(TRUE, n))
  d <- .rc_as_date_bound(sample_date, what = "sample_date")
  if (is.na(d)) return(rep(TRUE, n))          # E.6: no narrowing at all
  ds <- .rc_alias_bound(fa, "date_start", n)
  de <- .rc_alias_bound(fa, "date_end", n)
  (is.na(ds) | ds <= d) & (is.na(de) | de >= d)
}

.rc_proto_skip <- function() {
  tibble::tibble(source_ref = character(0), reason = character(0),
                 payload = character(0), source_hash = character(0),
                 existing_uuid = character(0), kept_uuid_lab = character(0))
}
.rc_proto_review <- function() {
  tibble::tibble(source_ref = character(0), kind = character(0),
                 subkind = character(0), payload = character(0), n_rows = integer(0),
                 source_hash = character(0), uuid_existing = character(0),
                 uuid_alias = character(0), candidates = list())
}

# ---- R-11.14: fold assembly's inline review flags into reconcile -----------
#
# PLAN-16 (R-16.7): `.rc_serialise_payload()` - the unescaped `paste0()` k=v
# joiner - is DELETED, not repaired. Its one call site (STAGE-0, below) and
# every other reconcile review/skip producer now route through `.rq_row()`/
# `.rq_skip()` (R/db-schema.R) via the two thin wrappers immediately below.

#' Build one reconcile-shaped `review` tibble row from `.rq_row()`'s output
#' (PLAN-16 B-16.api/R-16.8), adding back the reconcile-only bookkeeping
#' columns (`source_ref`, `n_rows`) that `.rq_row()` itself does not carry.
#' `diagnostics` is the ONLY free-form carrier - serialised to JSON by
#' `.rq_row()`, never hand-glued k=v text (R-16.10/R-16.18).
#'
#' `source_ref` takes a character VECTOR: one element per source row folded
#' into this review item (grouped producers pass several, everything else
#' passes one). The `source_ref` COLUMN is the comma-joined rendering, kept
#' for backwards compatibility; `diagnostics$source_ref` gets the vector
#' itself, which is why the vector is the argument and the join is done here
#' rather than at the call sites. A ref containing a literal comma is
#' therefore still ambiguous in the column but exact in the diagnostics.
#'
#' Q2 (Robin, 2026-07-25): `source_ref` and `n_rows` are ALSO written into
#' `diagnostics`, under the same two key names retired migration 006 used to
#' write, so a row this package writes is not poorer than a migrated row was.
#' Two deliberate differences from the migration: `n_rows` stays the integer
#' it already is here (the migration could only recover the string it had
#' parsed out of k=v text), and these two keys are placed FIRST, ahead of the
#' caller's, so the serialised JSON key order is deterministic rather than
#' dependent on which producer happened to build the list.
#' @keywords internal
#' @noRd
.rc_review_row <- function(source_ref, kind, n_rows, source_hash, subkind = NA_character_,
                           work_order = NA_character_, uuid_existing = NA_character_,
                           uuid_alias = NA_character_, candidates = NULL, expired = NULL,
                           diagnostics = list()) {
  # A caller supplying either reserved key would otherwise produce a
  # duplicate name that `.rq_row()`'s assert_list(names = "unique") rejects
  # with a message pointing at the wrong function. Fail here, where the cause
  # is visible, instead of silently overwriting one of the two values.
  reserved <- intersect(c("source_ref", "n_rows"), names(diagnostics))
  if (length(reserved) > 0) {
    cli::cli_abort(
      paste0(
        ".rc_review_row(): {.arg diagnostics} must not supply {.val {reserved}} - ",
        "these keys are set from this function's own {.arg source_ref}/{.arg n_rows} arguments."
      ),
      class = "sampletidy_error"
    )
  }
  diagnostics <- c(list(source_ref = source_ref, n_rows = n_rows), diagnostics)

  rq <- .rq_row(
    kind = kind, subkind = subkind, work_order = work_order, source_hash = source_hash,
    uuid_existing = uuid_existing, uuid_alias = uuid_alias, candidates = candidates,
    expired = expired, diagnostics = diagnostics
  )
  row <- tibble::tibble(
    source_ref = paste(source_ref, collapse = ","), kind = kind,
    subkind = rq$review$subkind[[1]],
    payload = rq$review$payload[[1]], n_rows = n_rows, source_hash = source_hash,
    uuid_existing = rq$review$uuid_existing[[1]], uuid_alias = rq$review$uuid_alias[[1]]
  )
  # PLAN-16 round-3 FG-3/R-16.23: `.rq_row()` builds `review_queue_candidate`
  # child rows whenever `candidates=`/`expired=` is supplied, but until this
  # fix this function threw them away (`rq$candidates` never appeared
  # anywhere in the returned tibble) - no error, no warning. Carried through
  # instead, as a `candidates` list-column (one element per row, always a
  # tibble - 0 rows when neither argument was supplied, which is every one
  # of the 11 call sites in this file today, so this is latent, not a
  # behaviour change). `dplyr::bind_rows()` across a grouped producer's
  # several `.rc_review_row()` calls keeps each row's own child rows
  # distinct because they travel inside that row's own list element.
  #
  # PERSISTENCE IS NOW WIRED END TO END (updated 2026-07-26, PLAN-15
  # P15-review-payload). `.rq_row()` mints its OWN `uuid_row` and stamps every
  # child row's `uuid_review` with it, while `.ct_commit_review()`
  # (`R/commit.R`) mints a FRESH `review_queue.uuid` at insert time; PLAN-16
  # RULING-F therefore deferred routing reconcile's own candidates here,
  # because the child rows would have been inserted orphaned. `.ct_commit_review()`
  # now rewrites `uuid_review` to the parent row's ACTUAL inserted uuid (the
  # same pattern `.ct_rewrite_review_payloads()` uses for `uuid_alias`), so
  # the deferral has expired and Robin's 2026-07-26 ruling moves the producer:
  # `.rc_feature_review()` and `.rc_self_precedence_notes()` pass real
  # `candidates=`/`expired=` and set NO `diagnostics$candidates` key. Exactly
  # ONE carrier per row - `review_queue_candidates()` (`R/mutate.R`) aborts on
  # a row holding both. Its JSON READER arm stays: the live database holds 92
  # historical orphan rows whose candidates are JSON and PLAN-16 ruled
  # "preserve, do not convert".
  row$candidates <- list(rq$candidates)
  row
}

#' The skip tibble's own typed constructor (PLAN-16 B-16.skips). The skip
#' tibble (`skipped_list` -> `reconcile_event()`'s `skipped` return value)
#' never reaches `review_queue` - it stays in-memory and feeds `commit_event()`
#' directly - so it cannot route through `.rq_row()` (which returns a
#' `review_queue`-shaped row). It gets the SAME tier rule instead: an entity
#' reference (`existing_uuid`, `kept_uuid_lab`) is a real, typed argument/
#' column, never folded into free text; anything else is `diagnostics`,
#' serialised via `.rq_serialise_diagnostics()` (R/db-schema.R) - the ONE
#' shared policy point exactly like `.rq_row()` uses - no free-text `payload`
#' argument here either (R-16.18's rule, applied to the second carrier).
#' PURE - no DB access.
#' `already_present`'s `existing_uuid` is populated on EVERY call from that
#' producer (R-16.14): it is the column `.ct_skip_existing_uuid()`'s retired
#' regex fallback used to recover from a bare-uuid payload.
#' @param existing_uuid the already-committed `analysis.uuid` this skip
#'   refers to (`already_present`), or NA.
#' @param kept_uuid_lab the winning `lab_method.uuid` (`method_duplicate`),
#'   or NA.
#' @param diagnostics named list -> JSON `payload` (the remainder, if any).
#' @return `list(payload, existing_uuid, kept_uuid_lab)`.
#' @keywords internal
#' @noRd
.rq_skip <- function(existing_uuid = NA_character_, kept_uuid_lab = NA_character_,
                     diagnostics = list()) {
  payload <- .rq_serialise_diagnostics(diagnostics)
  list(payload = payload, existing_uuid = existing_uuid, kept_uuid_lab = kept_uuid_lab)
}

#' Build one reconcile-shaped `skipped` tibble row via `.rq_skip()` (PLAN-16
#' B-16.skips): the typed skip-tibble constructor, same tier rule as
#' `.rq_row()` - diagnostics -> JSON, entity references (`existing_uuid`,
#' `kept_uuid_lab`) -> real columns, never a k=v string or a bare uuid with no
#' structure (R-16.14).
#' @keywords internal
#' @noRd
.rc_skip_row <- function(source_ref, reason, source_hash, existing_uuid = NA_character_,
                         kept_uuid_lab = NA_character_, diagnostics = list()) {
  rq <- .rq_skip(existing_uuid = existing_uuid, kept_uuid_lab = kept_uuid_lab, diagnostics = diagnostics)
  tibble::tibble(
    source_ref = source_ref, reason = reason, payload = rq$payload, source_hash = source_hash,
    existing_uuid = rq$existing_uuid, kept_uuid_lab = rq$kept_uuid_lab
  )
}

# ---- R-8.1: QC filter -------------------------------------------------------

#' Split `results` into QC-filtered-out rows and survivors (R-8.1)
#'
#' Anything whose `sample_type` is not `Normal`/`unknown`/NA is a lab QC or
#' cross-reference row and is skipped (never committed): `LCS`, `MB`, `LAB_D`,
#' `MS`, and `NCP`. NCP = "Non-Client Parent" (ESdat spec) - another client's
#' field sample reported only as the parent leg of a batch-QC duplicate/spike;
#' assembly (R-7.4) normally drops NCP earlier, but this filter also excludes it
#' defensively should one reach here.
#' @keywords internal
#' @noRd
.rc_qc_filter <- function(results) {
  st <- results$sample_type
  is_ok <- is.na(st) | st %in% c("Normal", "unknown")
  qc_rows <- results[!is_ok, , drop = FALSE]
  skipped <- if (nrow(qc_rows) > 0) {
    tibble::tibble(
      source_ref = qc_rows$source_ref,
      reason = paste0("qc_", qc_rows$sample_type),
      payload = NA_character_,
      source_hash = qc_rows$source_hash
    )
  } else {
    .rc_proto_skip()
  }
  list(kept = results[is_ok, , drop = FALSE], skipped = skipped)
}

# ---- R-11.4: feature candidate resolution ----------------------------------

#' Candidate features for one `feature_raw` string (R-11.4): a single lookup
#' against `feature_alias` (every feature has a self-alias, so a direct name
#' match IS an alias hit). `feature_mask` is NO LONGER consulted (D9/PLAN-13).
#'
#' Rules: NA key -> zero rows (A44); the key's alias rows are first narrowed to
#' those LIVE at `sample_date` (PLAN-15 E.2, alias-side bounds); only
#' `auto_assign` aliases enter the set; a dangling alias (uuid_feature NA) is
#' dropped (A44 registry-row guard); finally the surviving features are
#' narrowed by the FEATURE's own `date_end`.
#'
#' The two date filters are SEPARATE and BOTH apply (E.2). The feature-side one
#' is UNCONDITIONAL here - deliberately not `.rc_narrow_live()`, which fires
#' only when >1 distinct feature survives: the alias-side filter can collapse
#' the set to a single arm and thereby DISABLE the feature-side narrowing,
#' resolving onto a decommissioned feature (reproducible on the shipped
#' `T.REUSED` fixture). Same ruling as B.5, same reason.
#'
#' @return `tibble(uuid_alias, uuid_feature)` of survivors.
#' @keywords internal
#' @noRd
.rc_feature_candidates <- function(feature_raw, sample_date, registry) {
  empty <- tibble::tibble(uuid_alias = character(0), uuid_feature = character(0))
  # PLAN-15 A: features fold with the punctuation-PRESERVING key (`.rc_feature_key`),
  # matching the migration-written `alias_key`. `.rc_method_key` (strip) would leave ~62%
  # of dotted keys unreachable AND fuse cross-site codes (BS1 vs B.S1).
  key <- .rc_feature_key(feature_raw)
  if (is.na(key)) return(empty)

  fa <- registry$feature_alias
  hit <- fa[!is.na(fa$alias_key) & fa$alias_key == key, , drop = FALSE]
  # E.2: live-at-sample_date, BEFORE the `auto_assign` filter and before any
  # candidate is counted. NULL/NULL (and, pre-003, an absent column) is
  # unbounded, so this is a no-op on every un-curated key.
  hit <- hit[.rc_alias_live(hit, sample_date), , drop = FALSE]
  hit <- hit[.rc_is_true_vec(hit$auto_assign), , drop = FALSE]
  # A44 registry-row guard: an alias that resolves to no feature is not a
  # candidate (its natural-key lookup for pending rows is a separate path,
  # R-11.5a).
  hit <- hit[!is.na(hit$uuid_feature), , drop = FALSE]
  if (nrow(hit) == 0) return(empty)

  cand <- tibble::tibble(uuid_alias = hit$uuid, uuid_feature = hit$uuid_feature)

  .rc_narrow_live_feature(cand, sample_date, registry)
}

#' Narrow a candidate tibble to features live at `sample_date`, UNCONDITIONALLY
#' (PLAN-15 B.5/E.2): every candidate whose FEATURE has expired is dropped, even
#' when that empties the set. A NA `sample_date` narrows nothing (E.6/R-15.21).
#' @keywords internal
#' @noRd
.rc_narrow_live_feature <- function(cand, sample_date, registry) {
  if (nrow(cand) == 0 || length(sample_date) != 1) return(cand)
  d <- .rc_as_date_bound(sample_date, what = "sample_date")
  if (is.na(d)) return(cand)
  feat <- registry$feature
  de <- .rc_as_date_bound(feat$date_end[match(cand$uuid_feature, feat$uuid)],
                          what = "feature$date_end")
  if (is.null(de)) return(cand)          # no date_end column at all = unbounded
  cand[is.na(de) | de >= d, , drop = FALSE]
}

#' Narrow a candidate tibble to features live at `sample_date` (date_end NA, or
#' date_end >= sample_date), but only when that leaves >=1 candidate and there is
#' a genuine ambiguity to break. Shared by the auto-hit and suggestion paths.
#' @keywords internal
#' @noRd
.rc_narrow_live <- function(cand, sample_date, registry) {
  if (length(unique(cand$uuid_feature)) > 1 && !is.na(sample_date)) {
    feat <- registry$feature
    # PLAN-7b item 6(b): `feat$date_end` routed through `.rc_as_date_bound()`
    # rather than calling `as.Date(de, tz = ...)` directly - the candidate
    # path (`.rc_structural_hit()`/`.rc_narrow_live_feature()`) already goes
    # through the shared coercer, which ABORTS on a POSIXct `date_end` bound
    # rather than silently coercing it (E.1); this suggestion path used to
    # coerce the exact bound the candidate path rejects. Also picks up the
    # "no date_end column at all = unbounded" NULL guard for free.
    # `sample_date` itself is NOT routed through `.rc_as_date_bound()` - H11
    # (test-review-queue-candidate.R) pins that a POSIXct `sample_date` is
    # handled here via explicit `tz=` pinning, not rejected; `.rc_as_date_bound()`
    # aborts on ANY POSIXct input, which would break that contract.
    de <- .rc_as_date_bound(feat$date_end[match(cand$uuid_feature, feat$uuid)],
                            what = "feature$date_end")
    if (!is.null(de)) {
      d <- as.Date(sample_date, tz = "Australia/Sydney")
      live <- is.na(de) | de >= d
      narrowed <- cand[live, , drop = FALSE]
      if (nrow(narrowed) >= 1) cand <- narrowed
    }
  }
  cand
}

#' Suggested candidate features for review (PLAN-15 A). Like
#' `.rc_feature_candidates` but WITHOUT the `auto_assign` filter, so an ambiguous
#' key - which migration-001 marks `auto_assign = FALSE` on every arm, e.g.
#' `b.s01` -> B.S01 AND B.TS41 - still yields its distinct candidate features.
#' These never auto-resolve; they populate the review payload so an operator can
#' pick. Dangling (uuid_feature NA) aliases are excluded; date narrowing applies
#' on BOTH sides - the alias-side bound (E.2, so an EXPIRED arm is not offered
#' as a live suggestion) and then the feature-side `.rc_narrow_live()`. The
#' feature side stays CONDITIONAL here, unlike `.rc_feature_candidates()`: a
#' suggestion is never auto-resolved, so the "resolve onto a defunct feature"
#' hazard B.5/E.2 rules on cannot arise, and emptying an operator's candidate
#' list is a loss, not a safety property.
#' @return character vector of DISTINCT candidate `uuid_feature` (possibly empty).
#' @keywords internal
#' @noRd
.rc_feature_suggestions <- function(feature_raw, sample_date, registry) {
  key <- .rc_feature_key(feature_raw)
  if (is.na(key)) return(character(0))
  fa <- registry$feature_alias
  hit <- fa[!is.na(fa$alias_key) & fa$alias_key == key & !is.na(fa$uuid_feature), , drop = FALSE]
  hit <- hit[.rc_alias_live(hit, sample_date), , drop = FALSE]
  if (nrow(hit) == 0) return(character(0))
  cand <- tibble::tibble(uuid_alias = hit$uuid, uuid_feature = hit$uuid_feature)
  cand <- .rc_narrow_live(cand, sample_date, registry)
  unique(cand$uuid_feature)
}

#' The EXPIRED (or not-yet-started) alias arms of one `feature_raw` (PLAN-15
#' E.3): the exact complement of `.rc_feature_suggestions()`'s alias-side
#' liveness filter, carrying each arm's own DATE bounds alongside its feature.
#'
#' "Expired" here means ALIAS-side: the arm's `date_start`/`date_end` do not
#' admit `sample_date`. It is deliberately NOT feature-side expiry - closing an
#' ALIAS is the deliberate curation act E.3 rules on, and an arm dropped only by
#' `.rc_narrow_live()` (feature `date_end`) is a live mapping onto a
#' decommissioned point, a different fact with a different remedy.
#'
#' Bounds are class `Date` by construction (`.rc_alias_bound()` -> S-15.5's
#' absent-column-is-unbounded rule): `.rq_row()` REJECTS a POSIXct bound rather
#' than coercing it, because `as.Date()` on a POSIXct is itself
#' timezone-dependent. A NA `sample_date` narrows nothing (E.6), so no arm is
#' expired and this returns zero rows.
#'
#' Dangling arms (`uuid_feature` NA) are excluded, matching
#' `.rc_feature_suggestions()` - `review_queue_candidate.uuid_feature` is NOT
#' NULL, so a dangling arm has nothing to name. They still hold the key with
#' Layer 1 via `.rc_alias_rows_exist()`, which is date- and dangling-blind.
#' @return `tibble(uuid_feature, date_start, date_end)`, 0+ rows.
#' @keywords internal
#' @noRd
.rc_feature_expired <- function(feature_raw, sample_date, registry) {
  empty <- tibble::tibble(uuid_feature = character(0),
                          date_start = as.Date(character(0)),
                          date_end = as.Date(character(0)))
  key <- .rc_feature_key(feature_raw)
  if (is.na(key)) return(empty)
  fa <- registry$feature_alias
  if (is.null(fa) || nrow(fa) == 0) return(empty)
  hit <- fa[!is.na(fa$alias_key) & fa$alias_key == key & !is.na(fa$uuid_feature), , drop = FALSE]
  if (nrow(hit) == 0) return(empty)
  hit <- hit[!.rc_alias_live(hit, sample_date), , drop = FALSE]
  if (nrow(hit) == 0) return(empty)
  tibble::tibble(
    uuid_feature = hit$uuid_feature,
    date_start = .rc_alias_bound(hit, "date_start", nrow(hit)),
    date_end = .rc_alias_bound(hit, "date_end", nrow(hit))
  )
}

# ---- PLAN-15 B/C: layered site-aware resolution ----------------------------
#
# Layer 1 (Work A, above) is the exact curated alias lookup and is
# AUTHORITATIVE. What follows is the FALLBACK for names Layer 1 cannot reach:
#
#  - Layer 2 (Work B): parse the raw as `(site, point)` and match it against
#    the feature table's own `(site, point)` decomposition. Runs ONLY for a key
#    that reaches ZERO `feature_alias` rows (B.4), only across a dot/space
#    boundary (B.2), and only onto a feature live at `sample_date` (B.5).
#  - Layer 3 (Work C): when every row this event resolved sits in ONE site S,
#    retry the still-unresolved, site-less rows assuming S (C.1-C.3).
#
# Both are deterministic re-derivable rules, never curation: a hit rides the
# target's existing SELF alias (B.6) and commit registers no new alias.

#' The site set (B.1): `DISTINCT feature.site`, longest `nchar` FIRST so a
#' prefix-extending site wins the match (live: `BH` before `B`).
#'
#' Read from the `site` COLUMN, NEVER from a `feature.name` prefix parse. The
#' two agree for 894 of 894 live features, which is exactly what makes a
#' prefix parse look correct while being wrong: a feature whose name prefix
#' disagrees with its site would be silently re-sited by one.
#' @return character vector of sites, possibly empty.
#' @keywords internal
#' @noRd
.rc_site_registry <- function(registry) {
  feat <- registry$feature
  if (is.null(feat) || nrow(feat) == 0 || !("site" %in% names(feat))) return(character(0))
  s <- feat$site
  s <- trimws(s[!is.na(s)])
  s <- unique(s[s != ""])
  if (length(s) == 0) return(character(0))
  s[order(-nchar(s), s)]
}

#' Canonical form of a POINT within its site (B.3): uppercase, then drop
#' leading zeros within each maximal digit run (`S01` -> `S1`, `MW02A` ->
#' `MW2A`).
#'
#' NOT zero-padding: digit width is not uniform across the registry - `B.G###`
#' is 3-wide, `L.G##` 2-wide, and `K.G` carries BOTH (`K.G01`..`K.G025` 2-wide,
#' `K.G026`+ 3-wide) - so no fixed pad width reaches every point. The
#' lookbehind keeps the rule to the START of a run: `MW102` must stay `MW102`,
#' not become `MW12`.
#' @keywords internal
#' @noRd
.rc_canonical_point <- function(x) {
  gsub("(?<![0-9])0+(?=[0-9])", "", toupper(x), perl = TRUE)
}

#' Does ANY `feature_alias` row carry this `alias_key` (B.4/E.3 gate)?
#'
#' Ignores `uuid_feature` (so a DANGLING alias counts), `auto_assign` (so a
#' curator's parked ambiguity counts) and any date bound. This is deliberately
#' NOT `.rc_feature_suggestions()`, which excludes dangling rows and so
#' contradicts the gate's own "regardless of whether the alias is dangling".
#' A key reaching an alias row is Layer 1's business - or a human's - and must
#' never fall through to a structural parse.
#' @keywords internal
#' @noRd
.rc_alias_rows_exist <- function(key, registry) {
  if (length(key) != 1 || is.na(key)) return(FALSE)
  fa <- registry$feature_alias
  if (is.null(fa) || nrow(fa) == 0) return(FALSE)
  any(!is.na(fa$alias_key) & fa$alias_key == key)
}

#' The registry side of the structural index (B.3): one `SITE|POINT` key per
#' feature whose `name` starts with its own `site` followed by exactly one
#' separator. A feature whose name prefix != its `site` is EXCLUDED - there is
#' no `feature.point` column, so its point cannot be derived without guessing
#' which of the two fields to believe.
#' @return `list(key, uuid_feature)`, parallel character vectors.
#' @keywords internal
#' @noRd
.rc_structural_index <- function(registry) {
  empty <- list(key = character(0), uuid_feature = character(0))
  feat <- registry$feature
  if (is.null(feat) || nrow(feat) == 0) return(empty)
  keep <- which(!is.na(feat$site) & trimws(feat$site) != "" & !is.na(feat$name))
  if (length(keep) == 0) return(empty)

  site <- feat$site[keep]
  name <- feat$name[keep]
  ns <- nchar(site)
  ok <- substr(name, 1L, ns) == site &
    nchar(name) > ns + 1L &
    substr(name, ns + 1L, ns + 1L) %in% c(".", " ")
  if (!any(ok)) return(empty)

  site <- site[ok]; name <- name[ok]; ns <- ns[ok]
  point <- substr(name, ns + 2L, nchar(name))
  list(
    key = paste(toupper(site), .rc_canonical_point(point), sep = "|"),
    uuid_feature = feat$uuid[keep][ok]
  )
}

#' Split one feature key into `(site, point)` (B.2).
#'
#' The site is the LONGEST recognised prefix. The character right after it
#' decides the boundary: `.`/` ` is a real boundary; anything else is a DIRECT
#' (empty) boundary, which is suggestion-only and NEVER auto-resolves - `bs1`
#' is a curated alias of BH.S01 while no `bs01` alias exists, so a
#' longest-match parse of `BS01` would auto-resolve into the OPPOSITE
#' catchment. A residual point still containing a separator is unparseable
#' (`point = NA`): we split at the FIRST boundary only and never re-split.
#' @return NULL when no site is recognised, else
#'   `list(site, point, boundary)`; `point` is NA when unparseable.
#' @keywords internal
#' @noRd
.rc_parse_structural <- function(key, sites) {
  if (length(key) != 1 || is.na(key) || length(sites) == 0) return(NULL)
  kl <- tolower(key)
  for (s in sites) {
    sl <- tolower(s)
    if (nchar(kl) <= nchar(sl) || substr(kl, 1L, nchar(sl)) != sl) next
    rest <- substr(key, nchar(sl) + 1L, nchar(key))
    boundary <- substr(rest, 1L, 1L) %in% c(".", " ")
    point <- if (boundary) substr(rest, 2L, nchar(rest)) else rest
    if (nchar(point) == 0 || grepl("[. ]", point)) {
      return(list(site = s, point = NA_character_, boundary = boundary))
    }
    return(list(site = s, point = .rc_canonical_point(point), boundary = boundary))
  }
  NULL
}

#' The unique feature at `(site, point)`, live at `sample_date` (B.3/B.5).
#'
#' The live filter is UNCONDITIONAL - deliberately not `.rc_narrow_live()`,
#' which only narrows when the candidate set spans >1 feature. A structural hit
#' is unique by construction, so reusing that helper would be a no-op and would
#' resolve onto a decommissioned feature.
#' @return `uuid_feature`, or NA when there is no unique live hit.
#' @keywords internal
#' @noRd
.rc_structural_hit <- function(site, point, index, sample_date, registry) {
  if (is.na(site) || is.na(point)) return(NA_character_)
  u <- unique(index$uuid_feature[index$key == paste(toupper(site), point, sep = "|")])
  if (length(u) != 1) return(NA_character_)
  if (!is.na(sample_date)) {
    feat <- registry$feature
    de <- feat$date_end[match(u, feat$uuid)]
    # PLAN-7b item 5: mirror `.rc_narrow_live_feature()`'s "no date_end column
    # at all = unbounded" guard. Without it, a registry whose `feature` table
    # lacks a `date_end` column entirely makes `de` NULL, `!is.na(de)`
    # `logical(0)`, and `logical(0) && ...` an ERROR - aborting the whole
    # reconcile - where the sibling function degrades gracefully instead.
    if (is.null(de)) return(u)
    # Round-3 H11: pin tz= explicitly, same reasoning as .rc_narrow_live()
    # just above - a no-op on the current Date-typed columns, but the guard
    # against a future POSIXct bound turning this into a silent NA.
    if (!is.na(de) && as.Date(de, tz = "Australia/Sydney") <
          as.Date(sample_date, tz = "Australia/Sydney")) {
      return(NA_character_)
    }
  }
  u
}

#' SELF-PRECEDENCE (PLAN-15 E.2/E.7, rulings R1/R2): when a key reaches SEVERAL
#' live candidate features and EXACTLY ONE of the surviving arms is the
#' `kind = 'self'` alias, that arm WINS and the row resolves through it.
#'
#' A feature is always reachable by its own name: R1 turns every `self` arm on
#' unconditionally, which is precisely what can push a key from one live arm to
#' several, so without R2 the repair would push rows into review instead. The
#' override is not silent - the caller emits a NON-BLOCKING note (E.7) naming
#' the shadowed features.
#'
#' Not applicable, deliberately, when the surviving arms contain ZERO self arms
#' (an ordinary ambiguity -> review, exactly as today) or MORE THAN ONE (two
#' features claiming one name by their own names is a registry defect, not
#' something to resolve arbitrarily).
#' @return NULL when self-precedence does not apply, else
#'   `list(uuid_alias, uuid_feature, shadowed)`.
#' @keywords internal
#' @noRd
.rc_self_precedence <- function(cand, registry) {
  if (length(unique(cand$uuid_feature)) < 2) return(NULL)
  fa <- registry$feature_alias
  if (is.null(fa) || nrow(fa) == 0 || !("kind" %in% names(fa))) return(NULL)
  kind <- fa$kind[match(cand$uuid_alias, fa$uuid)]
  is_self <- !is.na(kind) & kind == "self"
  if (sum(is_self) != 1L) return(NULL)
  i <- which(is_self)
  list(
    uuid_alias = cand$uuid_alias[[i]],
    uuid_feature = cand$uuid_feature[[i]],
    shadowed = setdiff(unique(cand$uuid_feature), cand$uuid_feature[[i]])
  )
}

#' The target feature's SELF alias (B.6). `sample.uuid_feature_alias` is NOT
#' NULL and the within-batch duplicate guard keys off it, so a structural hit
#' with no alias to ride must go to REVIEW rather than commit a NA alias.
#' Reconcile is read-only (A32): it never creates the alias itself, and commit
#' deliberately does not materialise a `kind = 'structural'` one either.
#' @keywords internal
#' @noRd
.rc_self_alias <- function(uuid_feature, registry) {
  fa <- registry$feature_alias
  if (is.null(fa) || nrow(fa) == 0 || is.na(uuid_feature)) return(NA_character_)
  hit <- fa[!is.na(fa$uuid_feature) & fa$uuid_feature == uuid_feature &
              !is.na(fa$kind) & fa$kind == "self", , drop = FALSE]
  if (nrow(hit) == 0) return(NA_character_)
  hit$uuid[[1]]
}

# ---- R-8.2/R-11.5: feature resolution (conveyor) ---------------------------

#' Resolve `feature_raw` for every row (R-11.5 conveyor). EVERY row is kept and
#' annotated; misses are not dropped.
#'
#' - hit (exactly one distinct feature): `uuid_feature`, `uuid_feature_alias`
#'   set, `feature_pending = FALSE`.
#' - unknown / ambiguous (key present): `feature_pending = TRUE`,
#'   `uuid_feature = NA`, `uuid_feature_alias = NA` (R-11.5a may later fill it),
#'   `alias_key` set. Row STAYS in `active` AND emits a review item.
#' - held (NA/blank feature_raw, no key): review only, dropped from `active`
#'   (there is no key to hang a pending alias on - A44).
#'
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_features <- function(rows, registry, work_order, orphan = FALSE) {
  n <- nrow(rows)
  if (n == 0) {
    rows$uuid_feature <- character(0)
    rows$uuid_feature_alias <- character(0)
    rows$feature_pending <- logical(0)
    rows$alias_key <- character(0)
    rows$feature_resolution <- character(0)
    return(list(kept = rows, review = .rc_proto_review()))
  }

  # Per-row date, parsed locally for date_end narrowing only (R-8.5 re-parses
  # canonically later; this read-only pass never mutates the row).
  parsed_dt <- parse_lab_datetime(rows$sample_datetime_raw, .rc_datetime_formats)
  row_dates <- as.Date(parsed_dt, tz = "Australia/Sydney")

  uuid_feature <- rep(NA_character_, n)
  uuid_alias <- rep(NA_character_, n)
  pending <- rep(FALSE, n)
  status <- rep(NA_character_, n)       # hit | pending | held
  # PLAN-15 A: the committed/grouping key is the punctuation-PRESERVING feature
  # key (matches the migration-written alias_key + `.rc_feature_candidates`); the
  # folded `.rc_method_key` stays for method keys + intra-event dedup only.
  alias_key <- .rc_feature_key(rows$feature_raw)
  cand_list <- vector("list", n)
  # PLAN-15 E.3, per row: the key's EXPIRED alias arms with their DATE bounds.
  # Parallel to `cand_list` (the LIVE ones) and read the same way in
  # `.rc_feature_review()` - the two are complements, never overlapping sets.
  exp_list <- vector("list", n)

  # PLAN-15 B/C state, per row: the structural parse, the review-payload
  # suggestion token it yields, and the provenance reason a non-curated
  # resolution carries to COMMIT (reconcile itself writes nothing - A32).
  sites <- .rc_site_registry(registry)
  index <- .rc_structural_index(registry)
  parsed_site <- rep(NA_character_, n)   # the site Layer 2 RECOGNISED, if any
  struct_site <- rep(NA_character_, n)
  struct_point <- rep(NA_character_, n)
  resolution <- rep(NA_character_, n)
  # E.7/R2: per row, the features a self arm SHADOWED (NULL = no override).
  shadowed <- vector("list", n)
  feat_name <- function(u) {
    nm <- registry$feature$name[match(u, registry$feature$uuid)]
    if (length(nm) == 0 || is.na(nm)) u else nm
  }

  for (i in seq_len(n)) {
    if (is.na(alias_key[[i]])) {          # NA/blank/punctuation-only -> held (A44/F.1)
      status[[i]] <- "held"
      pending[[i]] <- TRUE
      next
    }
    cand <- .rc_feature_candidates(rows$feature_raw[[i]], row_dates[[i]], registry)
    distinct_feat <- unique(cand$uuid_feature)
    if (length(distinct_feat) == 1) {
      uuid_feature[[i]] <- distinct_feat
      # PLAN-7b item 2 (kills M5): when several ARMS resolve to the SAME
      # feature (the live `b.s01`/`k.e02` shape - a `self` arm plus e.g. a
      # `transcription_error` arm on one feature), the arm written to
      # `sample.uuid_feature_alias` used to be `cand$uuid_alias[[1]]` -
      # whichever DuckDB happened to return first, an arbitrary physical-row-
      # order artefact. `.rc_self_precedence()` cannot help here (it requires
      # >=2 DISTINCT features). Prefer the `kind == 'self'` arm - R1's own
      # principle ("the self arm wins"), previously implemented only for the
      # different-feature case - falling back to the first arm only when NO
      # arm is `self` (a registry shape with none is a separate defect this
      # tie-break does not adjudicate).
      fa <- registry$feature_alias
      arm_kind <- fa$kind[match(cand$uuid_alias, fa$uuid)]
      arm_is_self <- !is.na(arm_kind) & arm_kind == "self"
      arm <- if (any(arm_is_self)) which(arm_is_self)[[1]] else 1L
      uuid_alias[[i]] <- cand$uuid_alias[[arm]]
      status[[i]] <- "hit"
      next
    }
    # E.2/E.7 (R1/R2): several live arms, exactly one of them the feature's own
    # `self` alias -> the self arm wins and the row RESOLVES, with a
    # non-blocking note. Only reachable at >1 distinct live feature, so it can
    # never turn an ordinary single-candidate hit into an annotated one.
    sp <- .rc_self_precedence(cand, registry)
    if (!is.null(sp)) {
      uuid_feature[[i]] <- sp$uuid_feature
      uuid_alias[[i]] <- sp$uuid_alias
      shadowed[[i]] <- sp$shadowed
      status[[i]] <- "hit"
      next
    }

    status[[i]] <- "pending"             # unknown (0) or ambiguous (>1)
    pending[[i]] <- TRUE
    # PLAN-15 A: surface EVERY distinct candidate the key reaches (incl. the
    # all-`auto_assign=FALSE` ambiguous case the auto path drops) so review
    # carries a real suggestion instead of a blank unknown.
    # PLAN-15 F.6, PINNED: the `length(sugg) > 1` gate that used to stand here
    # discarded a LONE candidate outright, which is the highest-confidence
    # signal the mechanism produces (5 live keys reach it via
    # `.rc_narrow_live()` collapsing an ambiguity to one surviving arm) and
    # the one case it threw away. Record the set at EVERY length; the count
    # is what `.rc_feature_review()`'s precedence table branches on, so the
    # count must survive to it rather than being pre-censored here.
    sugg <- .rc_feature_suggestions(rows$feature_raw[[i]], row_dates[[i]], registry)
    if (length(sugg) > 0) cand_list[[i]] <- sugg
    # E.3: the same key's expired arms, as CONTEXT. Collected on the pending
    # path only - a row that resolved has nothing to review.
    exp_i <- .rc_feature_expired(rows$feature_raw[[i]], row_dates[[i]], registry)
    if (nrow(exp_i) > 0) exp_list[[i]] <- exp_i

    # ---- Layer 2 (B): structural (site, point) --------------------------
    p <- .rc_parse_structural(alias_key[[i]], sites)
    if (is.null(p)) next
    parsed_site[[i]] <- p$site
    if (is.na(p$point)) next
    struct_site[[i]] <- p$site
    struct_point[[i]] <- p$point
    # B.4 gate: any alias row at all (live, expired or dangling) keeps this
    # key with Layer 1 / the operator. B.2: a direct boundary suggests only.
    if (!p$boundary || .rc_alias_rows_exist(alias_key[[i]], registry)) next
    hit <- .rc_structural_hit(p$site, p$point, index, row_dates[[i]], registry)
    if (is.na(hit)) next
    self <- .rc_self_alias(hit, registry)
    if (is.na(self)) next               # B.6: never commit with a NA alias
    uuid_feature[[i]] <- hit
    uuid_alias[[i]] <- self
    pending[[i]] <- FALSE
    status[[i]] <- "hit"
    resolution[[i]] <- paste0("structural_parse: ", rows$feature_raw[[i]],
                              " -> ", feat_name(hit))
  }

  # ---- Layer 3 (C): WO single-site disambiguation ------------------------
  l3 <- .rc_wo_site(uuid_feature, registry, work_order, orphan)
  if (!is.na(l3)) {
    for (i in which(status == "pending")) {
      if (is.na(alias_key[[i]])) next
      # C.2: a row that yielded a RECOGNISED site is never re-sited, even
      # when its point missed - that is the cross-site merge this guards.
      if (!is.na(parsed_site[[i]])) next
      # C.2: the "strip a leading recognised site token" clause is STRUCK -
      # Layer 3 only ever sees rows that recognised NO site - so the candidate
      # point is the whole canonicalised raw, and one still carrying a
      # separator is not retried.
      point <- .rc_canonical_point(alias_key[[i]])
      if (grepl("[. ]", point)) next
      # C.1: on a miss the row keeps S as its SUGGESTED site.
      struct_site[[i]] <- l3
      struct_point[[i]] <- point
      # B.4/C.3: curation (including a dangling pending alias) always wins -
      # suggest, never resolve.
      if (.rc_alias_rows_exist(alias_key[[i]], registry)) next
      hit <- .rc_structural_hit(l3, point, index, row_dates[[i]], registry)
      if (is.na(hit)) next
      self <- .rc_self_alias(hit, registry)
      if (is.na(self)) next
      uuid_feature[[i]] <- hit
      uuid_alias[[i]] <- self
      pending[[i]] <- FALSE
      status[[i]] <- "hit"
      resolution[[i]] <- paste0("wo_site_inferred: ", rows$feature_raw[[i]],
                                " -> ", feat_name(hit), " (sites={", l3, "})")
    }
  }

  rows$uuid_feature <- uuid_feature
  rows$uuid_feature_alias <- uuid_alias
  rows$feature_pending <- pending
  rows$alias_key <- alias_key
  # Rides to COMMIT, which writes the `change_log` provenance row (C.4).
  rows$feature_resolution <- resolution
  # C.4: confidence rides on the clean row's OWN field (change_log has no
  # confidence column). A re-derived resolution is never as good as curation.
  if ("confidence" %in% names(rows)) {
    for (i in which(!is.na(resolution))) {
      cap <- if (startsWith(resolution[[i]], "wo_site_inferred")) 0.8 else 0.9
      c0 <- rows$confidence[[i]]
      rows$confidence[[i]] <- if (is.na(c0)) cap else min(c0, cap)
    }
  }

  # kept = hits + committable-pending; held rows flow to review only.
  keep <- status %in% c("hit", "pending")
  kept <- rows[keep, , drop = FALSE]

  review <- dplyr::bind_rows(
    .rc_feature_review(rows, status, cand_list, exp_list, struct_site, struct_point, work_order),
    .rc_self_precedence_notes(rows, uuid_feature, shadowed, work_order)
  )
  list(kept = kept, review = review)
}

#' The E.7/R2 self-precedence NOTES: one per row a self arm resolved over at
#' least one shadowed feature.
#'
#' A note annotates a row that RESOLVED - it is not a blocker and not a
#' worklist item, which is why it is built here rather than inside
#' `.rc_feature_review()` (that producer only ever sees `pending`/`held` rows)
#' and why it is emitted PER ROW rather than grouped: the annotation belongs to
#' the row whose resolution it explains. `kind` stays `unknown_feature` -
#' inventing a new top-level kind would read as a new class of work to every
#' existing `review_queue` consumer (S-15.6).
#'
#' Carries `blocking = FALSE` and the shadowed features as CHILD ROWS, per the
#' one precedence table documented on `.rc_feature_review()` below - see there
#' for why the flag is not redundant with the `subkind` value and why the
#' shadowed set travels through `candidates=` rather than a diagnostics key.
#' @keywords internal
#' @noRd
.rc_self_precedence_notes <- function(rows, uuid_feature, shadowed, work_order) {
  idx <- which(!vapply(shadowed, is.null, logical(1)))
  if (length(idx) == 0) return(.rc_proto_review())

  # PLAN-7b item 1 (Robin's ruling, from E.7's own justification): group by
  # `(alias_key, resolved feature)`, exactly as `.rc_feature_review()` already
  # does. This file's rows are ANALYSIS-grain (one per analyte per sample), so
  # emitting one note PER ROW fans a single ambiguous sampling point with a
  # 30-analyte panel across 58 samples out to ~1,700 byte-identical notes per
  # ingest - exactly the review-queue flood E.7 exists to prevent (its own
  # stated purpose). `source_ref` becomes the group's VECTOR (`.rc_review_row()`
  # already accepts one for exactly this reason) and `n_rows` the group size.
  grp_key <- paste(rows$alias_key[idx], uuid_feature[idx], sep = "||")
  groups <- split(idx, grp_key)
  # Radix-pinned group order (matches `.rc_feature_review()`'s own fix,
  # item 7) so the emitted order does not shift with the R session's locale.
  groups <- groups[order(names(groups), method = "radix")]

  out <- lapply(groups, function(g) {
    # Canonical, presentation-independent WITHIN-group order (F.5-style).
    g <- g[order(rows$source_ref[g], method = "radix")]
    refs <- rows$source_ref[g]
    # The shadowed set is a property of the KEY, not the individual row - but
    # read as the union across the group (F.5's own rule) rather than the
    # first row's own value, so a caller extending this later never has to
    # re-derive the pattern.
    shadow_union <- unique(unlist(shadowed[g], use.names = FALSE))
    .rc_review_row(
      source_ref = refs, kind = "unknown_feature", n_rows = length(g),
      source_hash = rows$source_hash[[g[[1]]]], work_order = work_order,
      subkind = "self_precedence_note",
      # The shadowed arms ARE candidates a curator may later prefer, so they
      # take the same typed carrier every other candidate set now takes.
      candidates = shadow_union,
      diagnostics = list(
        feature_raw = rows$feature_raw[[g[[1]]]],
        resolved_feature = uuid_feature[[g[[1]]]],
        blocking = FALSE
      )
    )
  })
  dplyr::bind_rows(out)
}

#' The single site every RESOLVED row of this event sits in (C.1/C.3), or NA
#' when Layer 3 must not fire.
#'
#' Fails closed: skipped for an orphan event or a NA work order (an orphan is a
#' bag of unattributed files, so its "single site" is meaningless), when no row
#' resolved at all, when the resolved rows span >1 site, and when ANY resolved
#' feature has a NA/blank site. "Resolved" means `uuid_feature` is set after
#' Layers 1-2 - never a merely PARSED site, and never re-queried from the DB
#' for this work order (a WO split across two runs would otherwise resolve the
#' same raw differently per batching, and commit it twice).
#' @keywords internal
#' @noRd
.rc_wo_site <- function(uuid_feature, registry, work_order, orphan) {
  if (isTRUE(orphan) || length(work_order) != 1 || is.na(work_order)) return(NA_character_)
  resolved <- uuid_feature[!is.na(uuid_feature)]
  if (length(resolved) == 0) return(NA_character_)
  s <- registry$feature$site[match(resolved, registry$feature$uuid)]
  if (any(is.na(s)) || any(trimws(s) == "")) return(NA_character_)
  s <- unique(trimws(s))
  if (length(s) != 1) return(NA_character_)
  s
}

#' Grouped `unknown_feature` review items (one per normalised feature_raw; the
#' NA/blank key groups into a single item - A44). `source_hash` is the
#' first of the group (seam S-4). Covers both committable-pending and held rows.
#'
#' The genuinely-NA/blank rows are NEVER folded into `split()` alongside the
#' real keys via a string sentinel: an earlier version stuffed the literal
#' string `"na"` into `grp_key` for NA rows, which collided with any row
#' whose OWN `.rc_feature_key()` output IS `"na"` (feature codes `"NA"`,
#' `"na"`, `"Na"` all fold there) - `split()` then merged a genuinely-missing
#' row with a literal-"NA"-coded row into one blank review item, hiding the
#' literal code from the operator. There is no string that is provably safe
#' to use as a sentinel here: `.rc_feature_key()` trims only Unicode
#' whitespace (`[\h\v]`), so a control byte like `\x01` is NOT stripped and
#' would survive if `feature_raw` itself ever carried one (pathological, but
#' not guardable against by construction). Instead the NA-key rows are kept
#' out of the string-keyed `split()` entirely and appended as their own
#' group by row-index, so no sentinel string - safe or not - is needed.
#'
#' # THE `subkind` PRECEDENCE TABLE (S-15.6) - THE ONLY ONE IN THIS PACKAGE
#'
#' This is the single total order over the whole `unknown_feature` subkind
#' vocabulary, folding PLAN-15 F.5, F.6, E.3 and E.7 into ONE pass. Do not
#' start a second table anywhere: `.rc_self_precedence_notes()` above owns
#' precedence 0 only because a note annotates a row that RESOLVED and this
#' producer only ever sees `pending`/`held` rows - it is the same table.
#'
#' | # | subkind                | fires when                                   | blocking |
#' |---|------------------------|----------------------------------------------|----------|
#' | 0 | `self_precedence_note` | a live `self` arm won over >=1 shadowed arm  | FALSE    |
#' | 1 | `ambiguous`            | >=2 LIVE candidate features                  | TRUE     |
#' | 2 | `expired_alias`        | ZERO live arms and >=1 EXPIRED arm (E.3)     | TRUE     |
#' | 3 | `suggestion`           | EXACTLY ONE live candidate feature (F.6)     | TRUE     |
#' | 4 | `structural`           | no candidates at all, but a `(site, point)`  | TRUE     |
#' | 5 | `NA`                   | nothing to say                               | TRUE     |
#'
#' Three things the table pins that prose kept getting wrong:
#'
#' * **"LIVE ARM" IS DATE-BOUNDS-ADMITS, `auto_assign`-BLIND.** It is the
#'   `.rc_feature_suggestions()` count, NOT `.rc_feature_candidates()`'s
#'   `auto_assign = TRUE`-filtered one. A key with one live `auto_assign=FALSE`
#'   arm plus one expired arm has ONE live arm (-> `suggestion`) and ZERO
#'   filtered candidates at the same time; both are true, and keying the table
#'   off the filtered count would collapse it onto `expired_alias`. Ranks 1-3
#'   are therefore mutually exclusive by construction (a count is one number),
#'   which is what makes this a total order rather than a pile of overlapping
#'   rules - the ordering shown is what a reader needs, not a runtime tiebreak.
#' * **EXPIRY IS CONTEXT, NEVER THE SUBKIND, WHENEVER ANY LIVE ARM EXISTS.**
#'   `expired_alias` fires at ZERO live arms only. The expired arms themselves
#'   ride along at EVERY rank, so an `ambiguous` or `suggestion` row still
#'   names them (E.3's "ambiguity is the actionable fact; expiry is context").
#' * **`blocking` IS AN EXPLICIT BOOLEAN ON EVERY ROW *THIS TABLE* EMITS, not
#'   an inference from the subkind** (E.7/R2). Emitting it only on the note
#'   would leave "absent means blocking" as the rule for the OTHER five
#'   ranks, i.e. the same hardcoded special-case the flag exists to abolish
#'   within THIS vocabulary - so every `unknown_feature` row this file queues
#'   carries it, and a reader branches on one field at any rank here,
#'   including ranks added later.
#'
#'   PLAN-7b round 3 (2026-07-26), Robin's reversal: `blocking` is
#'   DELIBERATELY NOT universal across every OTHER `kind` this file queues
#'   (`unknown_analyte`, `unknown_unit`, `parse_error`, `value_conflict`,
#'   `batch_duplicate`, plus STAGE-0's fold-in). A first attempt at Phase-7b
#'   added it there too, on the reading that "every row this file queues
#'   carries it" should hold package-wide - but `value_conflict`'s
#'   `.rc_three_way()` producer shares its diagnostics vocabulary with
#'   `.fa_merge_samples()`'s `alias_merge` producer (R/feature-alias.R), and
#'   `tests/testthat/test-review-queue-payload.R`'s R-16.19/R-16.20 pins
#'   their diagnostics KEY SETS equal on the shared subset (an explicit,
#'   individually-justified `extras_permitted` list is the only exemption).
#'   Adding `blocking` to one side and not the other breaks that parity -
#'   making it universal is therefore a real design change (touching a
#'   sibling producer in a different file to preserve the invariant), not a
#'   local diagnostics addition, and belongs to its own criterion rather than
#'   this remediation.
#'
#' # CARRIERS: ONE PER ROW, NEVER BOTH
#'
#' Candidates and expired arms are TYPED CHILD ROWS (`.rc_review_row(candidates=,
#' expired=)` -> `review_queue_candidate`), not a `diagnostics$candidates` JSON
#' key. Robin's ruling, 2026-07-26, closing R-16.23's remaining half: PLAN-16's
#' RULING-F deferred this only because `.ct_commit_review()` could not then
#' rewrite a child row's `uuid_review` to the parent's actual inserted uuid; it
#' now does (`R/commit.R`), so the deferral has expired. `review_queue_candidates()`
#' (`R/mutate.R`) ABORTS on a row carrying both carriers, so a row must not be
#' half-migrated - which is why NO branch below sets `diagnostics$candidates`.
#' The JSON READER arm stays regardless: 92 historical orphan rows in the live
#' database hold JSON candidates and PLAN-16 ruled "preserve, do not convert".
#' Only the PRODUCER moved.
#'
#' # ORDER-INDEPENDENCE (F.5)
#'
#' Every group-level value is read across the WHOLE group, never off whichever
#' row happened to sort first: `cand` is the UNION of `cand_list[g]` (the
#' defect F.5 names - `cand_list[[g[[1]]]]` emitted BOTH candidates old-first
#' and NONE new-first), `expired` the union of `exp_list[g]`, `struct_site` the
#' first non-NA across the group. The group itself is then put in a canonical
#' order by `source_ref` before `feature_raw` / `source_hash` / the `source_ref`
#' vector are read off it, so the emitted payload is BYTE-IDENTICAL however the
#' event presented its rows. Fixing `cand` alone would have left two different
#' meanings of "the group's value" inside one payload, which is the actual
#' finding; `source_ref` is order-dependent for exactly the same reason and is
#' fixed the same way. `method = "radix"` pins C-locale collation, so the
#' canonical order does not shift with the R session's locale.
#' @keywords internal
#' @noRd
.rc_feature_review <- function(rows, status, cand_list, exp_list, struct_site,
                               struct_point, work_order) {
  idx <- which(status %in% c("pending", "held"))
  if (length(idx) == 0) return(.rc_proto_review())

  grp_key <- rows$alias_key[idx]
  na_grp <- idx[is.na(grp_key)]
  real_idx <- idx[!is.na(grp_key)]
  groups <- split(real_idx, grp_key[!is.na(grp_key)])
  # PLAN-7b item 7: `split()` orders groups by `factor()`'s LOCALE collation
  # (via `sort(unique(f))`), not the radix (C-locale byte order) this
  # function's own header claims - only the WITHIN-group order below was
  # actually radix-pinned. Pin the GROUP order too, immediately after the
  # split and before the NA group (which has no name to sort by) is appended.
  groups <- groups[order(names(groups), method = "radix")]
  if (length(na_grp)) groups <- c(groups, list(na_grp))

  out <- list()
  for (g in groups) {
    # F.5: canonical, presentation-independent group order (see header).
    g <- g[order(rows$source_ref[g], method = "radix")]
    refs <- rows$source_ref[g]
    fr <- rows$feature_raw[[g[[1]]]]
    # F.5: the UNION over the whole group, matching what `struct` below has
    # always done - not `cand_list[[g[[1]]]]`, the first row's own set.
    cand <- unique(unlist(cand_list[g], use.names = FALSE))
    expired <- dplyr::bind_rows(exp_list[g])
    # STEP 1 (R-16.11): select the group's precedence INDEX once, then read
    # both parallel vectors at it - site and point can never come from
    # different rows of the group (the mis-JOIN R-16.12 warns against).
    gi <- g[!is.na(struct_site[g])]
    st_site  <- if (length(gi)) struct_site[[gi[[1]]]]  else NA_character_
    st_point <- if (length(gi)) struct_point[[gi[[1]]]] else NA_character_
    # The precedence table, in one expression. See the header block above for
    # the full table and the three rules it pins.
    n_live <- length(cand)
    subkind <- if (n_live >= 2) {
      "ambiguous"
    } else if (n_live == 1) {
      "suggestion"
    } else if (nrow(expired) > 0) {
      "expired_alias"
    } else if (!is.na(st_site)) {
      "structural"
    } else {
      NA_character_
    }
    # PLAN-16 R-16.8/R-16.17: no k=v payload string; feature_raw/site/point are
    # typed diagnostics keys, n_rows/subkind are real columns, and candidates/
    # expired are real child rows.
    diagnostics <- list(feature_raw = fr, blocking = TRUE)
    if (identical(subkind, "structural")) {
      diagnostics$site <- st_site
      diagnostics$point <- st_point
    }
    out[[length(out) + 1]] <- .rc_review_row(
      source_ref = refs, kind = "unknown_feature",
      n_rows = length(g), source_hash = rows$source_hash[[g[[1]]]],
      work_order = work_order, subkind = subkind,
      candidates = if (n_live > 0) as.character(cand) else NULL,
      expired = if (nrow(expired) > 0) expired else NULL,
      diagnostics = diagnostics
    )
  }
  dplyr::bind_rows(out)
}

# ---- R-8.3/R-11.6/R-11.19: analyte / method resolution ---------------------

#' Candidate lab_method rows for `(analyte_raw, org, method_raw)` under the
#' FOLDED key (R-8.3 step a); method disambiguates only when name+org is not
#' already unique.
#' @keywords internal
#' @noRd
.rc_lab_method_candidates <- function(analyte_raw, org, method_raw, registry) {
  lm <- registry$lab_method
  key <- .rc_method_key(analyte_raw)
  cand <- lm[.rc_method_key(lm$name) == key & !is.na(lm$organisation) & lm$organisation == org, , drop = FALSE]
  if (nrow(cand) > 1 && !is.na(method_raw)) {
    mkey <- .rc_method_key(method_raw)
    narrowed <- cand[!is.na(cand$method) & .rc_method_key(cand$method) == mkey, , drop = FALSE]
    if (nrow(narrowed) >= 1) cand <- narrowed
  }
  cand
}

#' Resolve one row's analyte/method (R-11.19 order): (1) EXACT raw-name +
#' organisation + method match wins; (2) else the folded match - if every
#' survivor resolves to ONE analyte it is a HIT (deterministic uuid_lab pick),
#' else ambiguous; (3) no candidates -> miss. A matched method whose
#' `uuid_analyte` is NULL is a "dangling_method" (we know the method, not the
#' analyte).
#' @return `list(status, uuid_lab, uuid_analyte)`.
#' @keywords internal
#' @noRd
.rc_resolve_one_analyte <- function(analyte_raw, org, method_raw, registry) {
  na_res <- function(status) list(status = status, uuid_lab = NA_character_, uuid_analyte = NA_character_)
  if (is.na(analyte_raw) || is.na(org)) return(na_res("miss"))

  lm <- registry$lab_method
  # (1) exact raw-name (case-sensitive) + organisation + method.
  name_eq <- !is.na(lm$name) & lm$name == analyte_raw
  org_eq <- !is.na(lm$organisation) & lm$organisation == org
  meth_eq <- (is.na(lm$method) & is.na(method_raw)) |
    (!is.na(lm$method) & !is.na(method_raw) & lm$method == method_raw)
  exact <- lm[name_eq & org_eq & meth_eq, , drop = FALSE]
  if (nrow(exact) >= 1) {
    exact <- exact[order(exact$uuid), , drop = FALSE]
    return(list(
      status = if (is.na(exact$uuid_analyte[[1]])) "dangling_method" else "resolved",
      uuid_lab = exact$uuid[[1]], uuid_analyte = exact$uuid_analyte[[1]]
    ))
  }

  # (2) folded candidates.
  cand <- .rc_lab_method_candidates(analyte_raw, org, method_raw, registry)
  if (nrow(cand) >= 1) {
    distinct_an <- unique(cand$uuid_analyte)
    if (length(distinct_an) == 1) {
      cand <- cand[order(cand$uuid), , drop = FALSE]
      return(list(
        status = if (is.na(distinct_an[[1]])) "dangling_method" else "resolved",
        uuid_lab = cand$uuid[[1]], uuid_analyte = distinct_an[[1]]
      ))
    }
    return(na_res("ambiguous"))   # survivors span >1 distinct analyte
  }
  na_res("miss")
}

#' Resolve analyte/method for every row (R-11.6 conveyor). EVERY row is kept.
#' A resolved analyte -> `analyte_pending = FALSE`. A dangling method, an
#' ambiguous fold, a CAS-only hit, or a full miss all -> `analyte_pending =
#' TRUE`, `uuid_analyte = NA` and commit dangling (a dangling lab_method is
#' materialised at COMMIT - A54). A CAS hit carries the matched analyte on its
#' review item AS A SUGGESTION, never as a link (A66).
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_analytes <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) {
    rows$uuid_lab <- character(0)
    rows$uuid_analyte <- character(0)
    rows$analyte_pending <- logical(0)
    return(list(kept = rows, review = .rc_proto_review()))
  }

  uuid_lab <- rep(NA_character_, n)
  uuid_analyte <- rep(NA_character_, n)
  cas_suggest <- rep(NA_character_, n)

  for (i in seq_len(n)) {
    res <- .rc_resolve_one_analyte(rows$analyte_raw[[i]], rows$org[[i]], rows$method_raw[[i]], registry)
    uuid_lab[[i]] <- res$uuid_lab
    uuid_analyte[[i]] <- res$uuid_analyte
    # CAS suggestion only when no lab_method matched at all (miss/ambiguous):
    # the matched analyte is a suggestion, not a link (A66).
    if (is.na(uuid_lab[[i]]) && is.na(uuid_analyte[[i]]) && !is.na(rows$cas_number[[i]])) {
      a <- registry$analyte[!is.na(registry$analyte$CAS) & registry$analyte$CAS == rows$cas_number[[i]], , drop = FALSE]
      if (nrow(a) >= 1) cas_suggest[[i]] <- a$uuid[[1]]
    }
  }

  rows$uuid_lab <- uuid_lab
  rows$uuid_analyte <- uuid_analyte
  rows$analyte_pending <- is.na(uuid_analyte)

  review <- .rc_analyte_review(rows, cas_suggest)
  list(kept = rows, review = review)
}

#' Review items for pending analytes with NO resolved method (uuid_lab NA): a
#' CAS-suggested row gets its own `known_analyte_no_method` item naming the
#' suggested analyte; the rest group by `(key(analyte_raw), org)`. A dangling
#' METHOD hit (method known, analyte NULL) is not re-flagged here.
#' @keywords internal
#' @noRd
.rc_analyte_review <- function(rows, cas_suggest) {
  out <- list()

  # PLAN-16 R-16.18 RULING: `suggested_analyte` is an analyte uuid, but it is
  # NOT a typed column - `uuid_existing` means "the existing entity this row
  # duplicates" (wrong sense here: A66 says the CAS match is a SUGGESTION,
  # not a link), and `review_queue_candidate.uuid_feature` is FK'd to
  # `feature`, not `analyte`. It stays a diagnostics key (no "=" in a bare
  # uuid, so R-16.11's leaf-value check still passes).
  for (i in which(!is.na(cas_suggest))) {
    out[[length(out) + 1]] <- .rc_review_row(
      source_ref = rows$source_ref[[i]], kind = "unknown_analyte", n_rows = 1L,
      source_hash = rows$source_hash[[i]], subkind = "known_analyte_no_method",
      diagnostics = list(analyte_raw = rows$analyte_raw[[i]], org = rows$org[[i]],
                         cas_number = rows$cas_number[[i]],
                         suggested_analyte = cas_suggest[[i]])
    )
  }

  miss_idx <- which(is.na(rows$uuid_lab) & is.na(cas_suggest))
  if (length(miss_idx) > 0) {
    key <- paste(.rc_method_key(rows$analyte_raw[miss_idx]), rows$org[miss_idx], sep = "||")
    groups <- split(miss_idx, key)
    for (g in groups) {
      refs <- rows$source_ref[g]
      ar <- rows$analyte_raw[[g[[1]]]]
      org <- rows$org[[g[[1]]]]
      # subkind deliberately NA - no new vocabulary invented here.
      out[[length(out) + 1]] <- .rc_review_row(
        source_ref = refs, kind = "unknown_analyte",
        n_rows = length(g), source_hash = rows$source_hash[[g[[1]]]],
        subkind = NA_character_,
        diagnostics = list(analyte_raw = ar, org = org)
      )
    }
  }

  if (length(out) > 0) dplyr::bind_rows(out) else .rc_proto_review()
}

# ---- R-11.5a: reconcile-side lookup of EXISTING pending registry rows ------

#' Resolve pending rows against EXISTING dangling registry entries by their
#' NATURAL key (R-11.5a). A SELECT only (A32/D8): it fills the surrogate so a
#' re-ingested dangling measurement can dedup, but never writes and keeps
#' `*_pending = TRUE` (identity now known, still unresolved). The key MUST be
#' identical to the one COMMIT creates under, or nothing ever dedups.
#'
#' The two branches use DIFFERENT normalisers, deliberately (PLAN-15 F.7):
#'
#' - feature-pending with `uuid_feature_alias == NA`: the `feature_alias` row
#'   whose `alias_key` equals this row's own `alias_key` AND `uuid_feature IS
#'   NULL`. That key is the punctuation-PRESERVING `.rc_feature_key`, computed
#'   once upstream at the head of `.rc_resolve_features` and carried on the row
#'   - NOT the punctuation-stripping `.rc_method_key`. This matters: migration
#'   001 wrote alias keys with punctuation intact (`b.s01`, `k.e02`), so the
#'   stripped form (`bs01`, `ke02`) matches ZERO dotted aliases. Looking these
#'   up with the wrong normaliser is precisely the defect PLAN-15 exists to fix.
#' - analyte-pending with `uuid_lab == NA`: the `lab_method` row with
#'   `uuid_analyte IS NULL` and matching `(organisation, .rc_method_key(name),
#'   .rc_method_key(method))`. Lab methods DO use the stripping normaliser -
#'   this branch is correct as it stands and must not be "fixed" to match the
#'   one above.
#' @keywords internal
#' @noRd
.rc_resolve_existing_pending <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) return(rows)

  fa <- registry$feature_alias
  fa_pending <- fa[is.na(fa$uuid_feature), , drop = FALSE]

  lm <- registry$lab_method
  lm_dangling <- lm[is.na(lm$uuid_analyte), , drop = FALSE]
  lm_natural <- if (nrow(lm_dangling) > 0) {
    paste(lm_dangling$organisation, .rc_method_key(lm_dangling$name), .rc_method_key(lm_dangling$method), sep = "||")
  } else {
    character(0)
  }

  for (i in seq_len(n)) {
    if (isTRUE(rows$feature_pending[[i]]) && is.na(rows$uuid_feature_alias[[i]])) {
      k <- rows$alias_key[[i]]
      if (!is.na(k) && nrow(fa_pending) > 0) {
        m <- which(!is.na(fa_pending$alias_key) & fa_pending$alias_key == k)
        if (length(m) >= 1) rows$uuid_feature_alias[[i]] <- fa_pending$uuid[[m[[1]]]]
      }
    }
    if (isTRUE(rows$analyte_pending[[i]]) && is.na(rows$uuid_lab[[i]]) && nrow(lm_dangling) > 0) {
      nk <- paste(rows$org[[i]], .rc_method_key(rows$analyte_raw[[i]]), .rc_method_key(rows$method_raw[[i]]), sep = "||")
      m <- which(lm_natural == nk)
      if (length(m) >= 1) rows$uuid_lab[[i]] <- lm_dangling$uuid[[m[[1]]]]
    }
  }
  rows
}

# ---- R-8.4/R-11.6: units & value -------------------------------------------

#' Convert `value_num`/`rl` to the resolved analyte's canonical units, route
#' `parse_value` skips / unit errors out (R-8.4). ANALYTE-PENDING rows are NOT
#' converted (no analyte -> no canonical units): the value passes through
#' unconverted and `units_raw` is left set (S-5); an unconvertible unit is NOT
#' an error for them.
#' @return `list(kept, skipped, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_units_values <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) {
    return(list(kept = rows, skipped = .rc_proto_skip(), review = .rc_proto_review()))
  }

  parsed <- parse_value(rows$value_raw)

  keep <- rep(TRUE, n)
  value_converted <- rep(NA_real_, n)
  rl_converted <- rep(NA_real_, n)
  rl_high <- rep(NA_real_, n)

  skipped_list <- list()
  review_list <- list()

  for (i in seq_len(n)) {
    if (!is.na(parsed$skip_reason[[i]])) {
      keep[[i]] <- FALSE
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], reason = parsed$skip_reason[[i]],
        payload = NA_character_, source_hash = rows$source_hash[[i]]
      )
      next
    }

    is_text <- !is.na(rows$value_chr[[i]])
    if (is_text) {
      next
    }

    if (isTRUE(rows$analyte_pending[[i]])) {
      # No analyte -> no canonical units. Pass the value/quantified/rl_high
      # through unconverted (R-11.16: provenance, like value); units_raw
      # stays and lands on lab_method.units at commit (D7/A63).
      value_converted[[i]] <- rows$value_num[[i]]
      rl_converted[[i]] <- rows$rl[[i]]
      rl_high[[i]] <- parsed$rl_high[[i]]
      next
    }

    analyte_row <- registry$analyte[registry$analyte$uuid == rows$uuid_analyte[[i]], , drop = FALSE]
    units_to <- normalise_lab_text(analyte_row$units[[1]])
    units_from <- normalise_lab_text(rows$units_raw[[i]])

    conv <- tryCatch(
      unify_value(
        c(rows$value_num[[i]], rows$rl[[i]], parsed$rl_high[[i]]),
        rep(units_from, 3), rep(units_to, 3)
      ),
      sampletidy_units_error = function(e) e
    )
    if (inherits(conv, "condition")) {
      keep[[i]] <- FALSE
      # PLAN-16 R-16.17: units_raw/analyte/value_raw are separate retrievable
      # diagnostics, not glued k=v text.
      review_list[[length(review_list) + 1]] <- .rc_review_row(
        source_ref = rows$source_ref[[i]], kind = "unknown_unit", n_rows = 1L,
        source_hash = rows$source_hash[[i]],
        diagnostics = list(units_raw = rows$units_raw[[i]], analyte = analyte_row$name[[1]],
                           value_raw = rows$value_raw[[i]])
      )
      next
    }
    value_converted[[i]] <- conv[[1]]
    rl_converted[[i]] <- conv[[2]]
    rl_high[[i]] <- conv[[3]]
  }

  kept <- rows[keep, , drop = FALSE]
  kept$value_converted <- value_converted[keep]
  kept$rl_converted <- rl_converted[keep]
  kept$quantified <- parsed$quantified[keep]
  kept$rl_high <- rl_high[keep]

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()
  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, skipped = skipped, review = review)
}

# ---- R-8.5: sample datetime -------------------------------------------------

# Union of the ESdat (long + short `%d-%b-%y`) and crosstab dialects seen in
# `sample_datetime_raw`. Keep in sync with `.st_join_datetime_formats`
# (assemble.R) and the `esdat` preset (dates.R).
.rc_datetime_formats <- c("%d %b %Y %H:%M", "%d %b %Y",
                          "%d-%b-%y %H:%M", "%d-%b-%y", "%d/%m/%Y")

#' Parse `sample_datetime_raw` into `sample_date`/`sample_datetime` (R-8.5,
#' A11). Unparseable strings queue a `parse_error` review item (held).
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_resolve_datetime <- function(rows) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, review = .rc_proto_review()))

  parsed_dt <- parse_lab_datetime(rows$sample_datetime_raw, .rc_datetime_formats)
  has_time <- has_clock_time(rows$sample_datetime_raw)

  keep <- !is.na(parsed_dt)

  sample_date <- as.Date(rep(NA, n))
  sample_date[keep] <- as.Date(parsed_dt[keep], tz = "Australia/Sydney")

  sample_datetime <- as.POSIXct(rep(NA_real_, n), origin = "1970-01-01", tz = "Australia/Sydney")
  set_dt <- keep & .rc_is_true_vec(has_time)
  sample_datetime[set_dt] <- parsed_dt[set_dt]

  review_list <- list()
  for (i in which(!keep)) {
    # PLAN-16 R-16.17: subkind='datetime' is a real column; sample_datetime_raw
    # is a separate retrievable diagnostic.
    review_list[[length(review_list) + 1]] <- .rc_review_row(
      source_ref = rows$source_ref[[i]], kind = "parse_error", n_rows = 1L,
      source_hash = rows$source_hash[[i]], subkind = "datetime",
      diagnostics = list(sample_datetime_raw = rows$sample_datetime_raw[[i]])
    )
  }

  kept <- rows[keep, , drop = FALSE]
  kept$sample_date <- sample_date[keep]
  kept$sample_datetime <- sample_datetime[keep]

  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, review = review)
}

# ---- R-8.6/R-11.5b: method preference --------------------------------------

#' Within `(feature, sample_date, uuid_analyte)`, when surviving rows come from
#' different `uuid_lab`, keep the lowest `lab_method.rl_low` (NA loses to any
#' number); tie -> keep the higher `value_num` (R-8.6). This picks a winning
#' LAB, not a winning ROW: every row sharing the winning `uuid_lab` survives
#' (R-8.6 dedups ACROSS methods only). Same-lab duplicates are deliberately
#' left for the R-12.13 within-batch guard, which runs after this stage
#' (PLAN-12 "Ordering vs PLAN-11" - R-8.6 first, R-12.13 catches what's left).
#'
#' R-11.5b re-keys on the RESOLVED feature where known, else the ALIAS uuid
#' where pending (paste() would otherwise silently recycle a dropped
#' uuid_feature to "" and dedup DIFFERENT features against each other).
#' Analyte-pending rows (uuid_analyte NA) and rows with no feature key at all
#' (a genuine first-sighting NA alias) are EXCLUDED from the dedup entirely.
#' @return `list(kept, skipped)`.
#' @keywords internal
#' @noRd
.rc_method_preference <- function(rows, registry) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, skipped = .rc_proto_skip()))

  feat_key <- ifelse(!is.na(rows$uuid_feature), rows$uuid_feature, rows$uuid_feature_alias)
  key <- paste(feat_key, as.character(rows$sample_date), rows$uuid_analyte, sep = "||")
  eligible <- !is.na(feat_key) & !is.na(rows$uuid_analyte)
  rl_low <- registry$lab_method$rl_low[match(rows$uuid_lab, registry$lab_method$uuid)]

  keep <- rep(TRUE, n)
  skipped_list <- list()

  for (k in unique(key[eligible])) {
    idx <- which(eligible & key == k)
    if (length(idx) <= 1) next
    labs <- unique(rows$uuid_lab[idx])
    if (length(labs) <= 1) next

    ord <- order(is.na(rl_low[idx]), rl_low[idx], -rows$value_num[idx])
    winner <- idx[ord[[1]]]
    kept_uuid_lab <- rows$uuid_lab[[winner]]
    # Only rows from a LOSING lab are eliminated here; rows sharing the
    # winning lab (same-method duplicates) are left in `kept` for R-12.13.
    losers <- idx[rows$uuid_lab[idx] != kept_uuid_lab]
    if (length(losers) == 0) next
    keep[losers] <- FALSE

    for (li in losers) {
      # PLAN-16 R-16.17/B-16.skips: kept_uuid_lab is a real column on the SKIP
      # tibble, via .rq_skip() - never a k=v payload string.
      skipped_list[[length(skipped_list) + 1]] <- .rc_skip_row(
        source_ref = rows$source_ref[[li]], reason = "method_duplicate",
        source_hash = rows$source_hash[[li]], kept_uuid_lab = kept_uuid_lab
      )
    }
  }

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()

  list(kept = rows[keep, , drop = FALSE], skipped = skipped)
}

# ---- R-8.7/R-11.7: three-way outcome vs DB ---------------------------------

#' Find an existing `analysis` row matching this measurement (R-11.7; A11/A45).
#'
#' The feature side joins THROUGH the alias: a resolved row matches any sample
#' whose alias resolves to the same `uuid_feature` (two labels for one feature
#' share a sample); a feature-pending row matches on `s.uuid_feature_alias`
#' directly (meaningful once R-11.5a resolved it from the natural key). The
#' analyte side drops the `lm.uuid_analyte` clause - `a.uuid_lab` already pins
#' the method, which determines the analyte (A45's key preserved). A still-NA
#' pending key (or a first-sighting dangling method with no `uuid_lab`) finds
#' nothing.
#' @return a one-row data frame, or `NULL` if no candidate.
#' @keywords internal
#' @noRd
.rc_find_existing <- function(con, resolved_feature, uuid_feature_alias, feature_pending,
                              sample_date, sample_datetime, uuid_lab) {
  if (is.na(uuid_lab)) return(NULL)   # first-sighting dangling method: nothing committed yet

  if (isTRUE(feature_pending)) {
    if (is.na(uuid_feature_alias)) return(NULL)   # genuine first sighting
    feat_clause <- "s.uuid_feature_alias = ?"
    feat_param <- uuid_feature_alias
  } else {
    if (is.na(resolved_feature)) return(NULL)
    feat_clause <- "fa.uuid_feature = ?"
    feat_param <- resolved_feature
  }

  cand <- DBI::dbGetQuery(
    con,
    paste0(
      'SELECT a.uuid AS analysis_uuid, a.value, a.value_chr, a.quantified, a.rl_low, a.rl_high, a.uuid_lab,
              s.datetime AS s_datetime
       FROM "sample" s
       JOIN analysis a ON a.uuid_sample = s.uuid
       JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
       WHERE ', feat_clause, ' AND CAST(s.date AS DATE) = ? AND a.uuid_lab = ?'
    ),
    params = list(feat_param, as.character(sample_date), uuid_lab)
  )
  if (nrow(cand) == 0) return(NULL)

  # Mirror .ct_find_or_create_sample's R-11.18/A62 predicate so the reconcile
  # second-read pass and the commit path agree on identity: an incoming
  # measurement is a NEW sampling event - no existing row to match - only when
  # distinctness is PROVABLE (incoming datetime non-NA AND every candidate
  # datetime non-NA AND none equal). Otherwise reuse (incoming NA, any candidate
  # NA, or an equal datetime -> uncertain identity, never fabricate a
  # duplicate). Without this a genuinely new second sampling at the same
  # feature+date+lab was returned as cand[1,] and skipped as already_present -
  # and, because the old datetime narrowing was gated on nrow(cand) > 1, a
  # lone distinct-datetime candidate was matched without any datetime check.
  # Compare instants as epoch seconds so a tz-tagged incoming POSIXct and the
  # driver's UTC-returned candidate never raise a spurious "inconsistent tzone"
  # warning; equality of instants is tz-independent.
  inc_dt <- as.numeric(sample_datetime)
  cand_dt <- as.numeric(cand$s_datetime)
  create_new <- !is.na(inc_dt) &&
    all(!is.na(cand_dt)) &&
    !any(cand_dt == inc_dt)
  if (create_new) return(NULL)

  if (!is.na(inc_dt)) {
    match_dt <- !is.na(cand_dt) & (cand_dt == inc_dt)
    if (any(match_dt)) cand <- cand[match_dt, , drop = FALSE]
  }
  cand[1, , drop = FALSE]
}

#' Recorded revision (A12): see PLAN-08. Unchanged by PLAN-11.
#' @keywords internal
#' @noRd
.rc_recorded_revision <- function(con, work_order, own_hashes) {
  if (is.na(work_order)) return(NA_integer_)

  ifq <- DBI::dbGetQuery(
    con, "SELECT hash, revision, state FROM ingest_file WHERE work_order = ?",
    params = list(work_order)
  )
  if (nrow(ifq) > 0) {
    ifq <- ifq[ifq$state %in% c("committed", "archived") & !(ifq$hash %in% own_hashes), , drop = FALSE]
  }
  rev_a <- ifq$revision[!is.na(ifq$revision)]

  proj <- DBI::dbGetQuery(
    con, "SELECT uuid FROM project WHERE name = ? AND type = 'Work order'",
    params = list(work_order)
  )
  rev_b <- integer(0)
  if (nrow(proj) > 0) {
    assets <- DBI::dbGetQuery(con, "SELECT filename FROM asset WHERE uuid_project = ?", params = list(proj$uuid[[1]]))
    if (nrow(assets) > 0) {
      guesses <- vapply(assets$filename, function(fn) {
        g <- .st_guess_work_order_revision(fn)
        if (is.na(g$revision_guess)) NA_integer_ else as.integer(g$revision_guess)
      }, integer(1))
      rev_b <- guesses[!is.na(guesses)]
    }
  }

  all_rev <- c(rev_a, rev_b)
  if (length(all_rev) == 0) return(NA_integer_)
  as.integer(max(all_rev))
}

#' A14 value equality: numeric within `abs(a-b) <= 1e-9*max(1,|a|,|b|)`, plus
#' equal `quantified`; text values compared by identity.
#' @keywords internal
#' @noRd
.rc_values_equal <- function(inc_value, inc_chr, inc_quant, exist_value, exist_chr, exist_quant) {
  # `quantified` is a TRI-state. NA is not "unknown detection state" - since
  # 2026-07-23 it means "this result is not a measurement at all", i.e. the row
  # is text-valued, and it is exactly as determinate as TRUE or FALSE. Treating
  # NA as unmatchable (the old `is.na(...) -> FALSE`) means two identical text
  # results never compare equal, so a re-ingested qualitative observation is
  # never recognised as already_present and COMMITS A SECOND TIME.
  # An NA/non-NA mismatch is still a genuine difference.
  if (is.na(inc_quant) != is.na(exist_quant)) return(FALSE)
  if (!is.na(inc_quant) && !identical(inc_quant, exist_quant)) return(FALSE)
  if (!is.na(inc_value) && !is.na(exist_value)) {
    return(abs(inc_value - exist_value) <= 1e-9 * max(1, abs(inc_value), abs(exist_value)))
  }
  if (is.na(inc_value) && is.na(exist_value)) {
    return(identical(inc_chr, exist_chr))
  }
  FALSE
}

#' Three-way outcome vs the DB for every surviving row (R-8.7/R-11.7). An
#' `already_present` skip carries the incoming row's own `source_hash` (A1/S-4).
#' @return `list(kept, skipped, review)`. `kept` gains a `supersedes` column.
#' @keywords internal
#' @noRd
.rc_three_way <- function(rows, con, event, registry) {
  n <- nrow(rows)
  if (n == 0) {
    rows$supersedes <- character(0)
    return(list(kept = rows, skipped = .rc_proto_skip(), review = .rc_proto_review()))
  }

  own_hashes <- unique(c(event$results$source_hash, event$files$hash))
  own_hashes <- own_hashes[!is.na(own_hashes)]

  keep <- rep(TRUE, n)
  supersedes <- rep(NA_character_, n)
  skipped_list <- list()
  review_list <- list()

  for (i in seq_len(n)) {
    existing <- .rc_find_existing(
      con, rows$uuid_feature[[i]], rows$uuid_feature_alias[[i]], rows$feature_pending[[i]],
      rows$sample_date[[i]], rows$sample_datetime[[i]], rows$uuid_lab[[i]]
    )
    if (is.null(existing)) next

    inc_value <- rows$value_converted[[i]]
    # A63/D7: the stored analysis.value is post-conversion_constant (applied at
    # commit); make the incoming value canonical too before the R-8.7/A14
    # idempotency comparison, matching the seam-table contract (PLAN-11 B-11-seam-table).
    cc <- registry$lab_method$conversion_constant[
      match(rows$uuid_lab[[i]], registry$lab_method$uuid)]
    if (!is.na(cc) && !is.na(inc_value)) inc_value <- inc_value * cc
    inc_chr <- rows$value_chr[[i]]
    inc_quant <- rows$quantified[[i]]
    exist_value <- existing$value[[1]]
    exist_chr <- existing$value_chr[[1]]
    exist_quant <- existing$quantified[[1]]

    if (.rc_values_equal(inc_value, inc_chr, inc_quant, exist_value, exist_chr, exist_quant)) {
      keep[[i]] <- FALSE
      # PLAN-16 R-16.14: existing_uuid is a real, ALWAYS-populated column on
      # the SKIP tibble via .rq_skip() - the bare-uuid-with-no-structure
      # shape (format c) is retired; this is the column
      # .ct_skip_existing_uuid()'s retired regex fallback used to recover.
      skipped_list[[length(skipped_list) + 1]] <- .rc_skip_row(
        source_ref = rows$source_ref[[i]], reason = "already_present",
        source_hash = rows$source_hash[[i]], existing_uuid = existing$analysis_uuid[[1]],
        diagnostics = list(value_existing = exist_value, value_incoming = inc_value,
                           value_chr_existing = exist_chr, value_chr_incoming = inc_chr,
                           quantified_existing = exist_quant, quantified_incoming = inc_quant)
      )
      next
    }

    recorded_rev <- .rc_recorded_revision(con, rows$work_order[[i]], own_hashes)
    incoming_rev <- rows$revision[[i]]

    if (!is.na(recorded_rev) && !is.na(incoming_rev) && incoming_rev > recorded_rev) {
      supersedes[[i]] <- existing$analysis_uuid[[1]]
    } else {
      keep[[i]] <- FALSE
      # PLAN-16 R-16.19/R-16.20: subkind='measurement' (discriminated by
      # subkind, not a second grammar); uuid_existing is a real column, never
      # a diagnostics key. Vocabulary is <thing>_<role> (role in
      # {existing,incoming}), shared with .fa_merge_samples' subkind=
      # 'alias_merge' on value_existing/value_incoming/value_chr_existing/
      # value_chr_incoming (round-2 FD4: the text side of a tri-state
      # measurement is carried too, or a text-vs-text conflict is
      # unadjudicable - two nulls); quantified_*/revision_* are the
      # reconcile-only permitted extras. uuid_incoming is deliberately
      # ABSENT (not NA) - the incoming value is not yet a row and has no
      # uuid to name.
      review_list[[length(review_list) + 1]] <- .rc_review_row(
        source_ref = rows$source_ref[[i]], kind = "value_conflict", n_rows = 1L,
        source_hash = rows$source_hash[[i]], subkind = "measurement",
        uuid_existing = existing$analysis_uuid[[1]],
        diagnostics = list(
          value_existing = exist_value, value_incoming = inc_value,
          value_chr_existing = exist_chr, value_chr_incoming = inc_chr,
          quantified_existing = exist_quant, quantified_incoming = inc_quant,
          revision_existing = recorded_rev, revision_incoming = incoming_rev
        )
      )
    }
  }

  kept <- rows[keep, , drop = FALSE]
  kept$supersedes <- supersedes[keep]

  skipped <- if (length(skipped_list) > 0) dplyr::bind_rows(skipped_list) else .rc_proto_skip()
  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()

  list(kept = kept, skipped = skipped, review = review)
}

# ---- R-12.13: within-batch duplicate guard before commit -------------------

#' Guard against two identical-key rows from the SAME method committing as
#' two analyses on one sample (R-12.13/A-7). R-8.6 dedups ACROSS methods by
#' consulting sibling rows in this batch; R-8.7/R-11.7's three-way outcome
#' only consults the DB, so two rows sharing `(uuid_feature_alias,
#' sample_date, uuid_analyte, uuid_lab)` in one batch each independently look
#' "new" and would both commit. This runs on the POST-three-way `clean` set
#' and catches exactly that remaining same-method case.
#'
#' Rows with ANY NA key component (an unresolved alias/analyte/lab - A44) are
#' NEVER matched, to each other or to anything else: `duplicated()`-style
#' NA-coalescing would spuriously pair two genuinely distinct pending rows
#' (e.g. two first-sightings of the same never-seen feature code). The first
#' row (batch order) of each exact-duplicate group is kept; the rest are
#' routed to REVIEW, never collapsed/skipped (PINNED, Phase-3 D13: A54 - the
#' pipeline records the question, never invents the answer by silently
#' picking one of two uncompared rows a human has not seen).
#'
#' @return `list(kept, review)`.
#' @keywords internal
#' @noRd
.rc_batch_duplicate <- function(rows) {
  n <- nrow(rows)
  if (n == 0) return(list(kept = rows, review = .rc_proto_review()))

  key <- paste(rows$uuid_feature_alias, as.character(rows$sample_date),
               rows$uuid_analyte, rows$uuid_lab, sep = "||")
  eligible <- !is.na(rows$uuid_feature_alias) & !is.na(rows$sample_date) &
    !is.na(rows$uuid_analyte) & !is.na(rows$uuid_lab)

  keep <- rep(TRUE, n)
  review_list <- list()

  for (k in unique(key[eligible])) {
    idx <- which(eligible & key == k)
    if (length(idx) <= 1) next
    winner <- idx[[1]]
    losers <- idx[-1]
    keep[losers] <- FALSE
    for (li in losers) {
      # PLAN-16 R-16.17: kept_source_ref is a separate retrievable diagnostic,
      # not glued to the loser's own source_ref.
      review_list[[length(review_list) + 1]] <- .rc_review_row(
        source_ref = rows$source_ref[[li]], kind = "batch_duplicate", n_rows = 1L,
        source_hash = rows$source_hash[[li]],
        diagnostics = list(kept_source_ref = rows$source_ref[[winner]])
      )
    }
  }

  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()
  list(kept = rows[keep, , drop = FALSE], review = review)
}

#' Backfill columns missing from a reconcile-producer's `review`/`skipped`
#' tibble before `reconcile_event()` selects a uniform column set across every
#' producer (R-16.8/B-16.skips). A producer not yet routed through
#' `.rq_row()`/`.rq_skip()` lacks the new typed columns entirely; add them
#' rather than erroring on selection.
#'
#' Type-aware for `candidates` (PLAN-16 round-3 FG-3/R-16.23): that column is
#' a LIST-column (one `review_queue_candidate` child tibble per row, or an
#' empty tibble), not character. Backfilling it as `NA_character_` like every
#' other column would leave a `<list>`/`<character>` mismatch that
#' `dplyr::bind_rows()` across producers hard-errors on ("Can't combine
#' <list> and <character>"). A missing `candidates` column is backfilled as a
#' list of `NULL`, one element per row, so `bind_rows()` combines cleanly and
#' `.ct_commit_review()`'s downstream `is.data.frame(cand_i)` check (R/commit.R)
#' still behaves - `is.data.frame(NULL)` is FALSE, so a row backfilled this
#' way is correctly treated as "no candidate child rows", the same outcome an
#' explicit empty-tibble element already produces.
#'
#' As of this fix, EVERY `reconcile_event()` producer that reaches
#' `add_review()` already sets `candidates` itself (every non-empty `review`
#' tibble is either `.rc_proto_review()` or a `dplyr::bind_rows()` of one or
#' more `.rc_review_row()` rows, and both already carry the column) - so the
#' `candidates` branch below is LATENT under every caller today, not
#' currently reachable. Fixed anyway: the column is structurally declared in
#' `review_cols` (PLAN-16), so a future producer omitting it is one edit away
#' and this is the cheap, correct backfill for that day.
#' @keywords internal
#' @noRd
.rc_fill_missing_cols <- function(df, cols) {
  for (col in setdiff(cols, names(df))) {
    df[[col]] <- if (identical(col, "candidates")) {
      vector("list", nrow(df))
    } else {
      NA_character_
    }
  }
  df
}

# ---- top-level entry point --------------------------------------------------

#' Reconcile one assembled event against the registry/analysis DB.
#'
#' Read-only: every DB access is a `DBI::dbGetQuery()` (CONTRACT A32). Applies,
#' in order: fold assembly's inline review flags (R-11.14, STAGE-0), QC filter
#' (R-8.1), feature resolution (R-11.5 conveyor), analyte/method resolution
#' (R-11.6 conveyor), existing-pending natural-key lookup (R-11.5a), units &
#' value (R-8.4/R-11.6), sample datetime (R-8.5), method preference (R-8.6/
#' R-11.5b), and the three-way outcome vs the DB (R-8.7/R-11.7). A
#' feature/analyte-pending row commits DANGLING to `clean` AND carries a review
#' worklist item.
#'
#' @param event a plan-07 event object (`work_order`, `results`, `files`, ...).
#' @param con an open read-write (but here, read-only-used) DBI connection.
#' @return `list(clean, review, skipped, counts)`.
#' @keywords internal
#' @noRd
reconcile_event <- function(event, con) {
  results <- event$results

  # PLAN-16: widened to carry the typed columns .rq_row()/.rq_skip() emit
  # (R-16.8/B-16.skips). Not every producer populates every typed column
  # (e.g. a producer with no candidate features leaves uuid_alias NA) -
  # `.rc_fill_missing_cols()` below backfills the rest so every producer's
  # tibble can be bound/selected uniformly regardless of which columns it set.
  # `candidates` (round-3 FG-3/R-16.23) is a list-column every `.rc_review_row()`
  # call now sets (see its own comment) - included here so reconcile_event()'s
  # caller can see a producer's review_queue_candidate child rows rather than
  # having them silently dropped a second time at this selection step.
  review_cols <- c("source_ref", "kind", "subkind", "payload", "source_hash",
                    "uuid_existing", "uuid_alias", "candidates")
  skip_cols <- c("source_ref", "reason", "payload", "source_hash",
                  "existing_uuid", "kept_uuid_lab")

  if (nrow(results) == 0) {
    return(list(clean = results, review = .rc_proto_review()[, review_cols],
                skipped = .rc_proto_skip()[, skip_cols], counts = c(clean = 0L)))
  }

  registry <- .rc_load_registry(con)

  skipped_acc <- list()
  review_acc <- list()
  count_acc <- list()

  add_skip <- function(df) {
    if (nrow(df) == 0) return(invisible())
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$reason, n = 1L, stringsAsFactors = FALSE)
    df <- .rc_fill_missing_cols(df, skip_cols)
    skipped_acc[[length(skipped_acc) + 1]] <<- df[, skip_cols]
  }
  add_review <- function(df) {
    if (nrow(df) == 0) return(invisible())
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$kind, n = df$n_rows, stringsAsFactors = FALSE)
    df <- .rc_fill_missing_cols(df, review_cols)
    review_acc[[length(review_acc) + 1]] <<- df[, review_cols]
  }

  active <- results

  # STAGE-0 (R-11.14): partition assembly's inline review flags out BEFORE QC.
  # These are "we don't trust this row" flags - held, never committed (distinct
  # from feature/analyte-pending rows which DO commit). PLAN-16 R-16.7/R-16.10:
  # routes through .rq_row() (JSON diagnostics) instead of the now-deleted
  # .rc_serialise_payload() - the payload round-trips byte-identical because
  # jsonlite escapes by construction.
  #
  # PLAN-16 FF4 (Phase 7b round 2): assembly's `review_payload` list carries
  # `kind`/`subkind` keys of its OWN (R/assemble.R:181-184/363-366) - those are
  # NOT free-form diagnostics, they duplicate what this function already knows
  # from `fr$review_kind[[i]]` and must become. Passing the list through whole
  # left `review_queue.subkind` NULL while the JSON remainder disagreed with
  # the typed `kind` column it sat beside. Hoist `subkind` into the typed
  # argument and drop both keys from the serialised remainder before they ever
  # reach `.rc_review_row()`.
  #
  # PLAN-16 FF5: the `foreign_work_order` subkind's payload also carries
  # `work_order` (the FOREIGN work order named inside the file) under the same
  # key name `commit_event()` uses for `review_queue.work_order` (the HOME
  # work order the event was ingested under - `R/commit.R` always takes it
  # from `event$work_order`, never from this diagnostics list; verified this
  # IS two different facts sharing one name, not one fact duplicated). Rename
  # the diagnostics key so a reader does not have to already know which is
  # which. `home_work_order` is dropped here (not renamed): it is the exact
  # same value `event$work_order` supplies as the typed column at commit, so
  # keeping it under any name would just be a second copy of that column.
  if ("needs_review" %in% names(active)) {
    flagged <- .rc_is_true_vec(active$needs_review)
    if (any(flagged)) {
      fr <- active[flagged, , drop = FALSE]
      stage0_rows <- lapply(seq_len(nrow(fr)), function(i) {
        diag <- fr$review_payload[[i]]
        if (is.null(diag)) diag <- list()
        subkind <- diag$subkind
        if (is.null(subkind)) subkind <- NA_character_
        diag <- diag[setdiff(names(diag), c("kind", "subkind", "home_work_order"))]
        if ("work_order" %in% names(diag)) {
          names(diag)[names(diag) == "work_order"] <- "foreign_work_order"
        }
        .rc_review_row(
          source_ref = fr$source_ref[[i]], kind = fr$review_kind[[i]], n_rows = 1L,
          source_hash = fr$source_hash[[i]], subkind = subkind, diagnostics = diag
        )
      })
      stage0 <- dplyr::bind_rows(stage0_rows)
      add_review(stage0)
      active <- active[!flagged, , drop = FALSE]
    }
  }

  # R-8.1
  qc <- .rc_qc_filter(active)
  add_skip(qc$skipped)
  active <- qc$kept

  # R-11.5 (feature conveyor)
  feat <- .rc_resolve_features(active, registry, event$work_order, isTRUE(event$orphan))
  add_review(feat$review)
  active <- feat$kept

  # R-11.6 (analyte conveyor)
  an <- .rc_resolve_analytes(active, registry)
  add_review(an$review)
  active <- an$kept

  # R-11.5a (fill surrogates from EXISTING dangling registry rows by natural key)
  active <- .rc_resolve_existing_pending(active, registry)

  # R-8.4 / R-11.6 (units & value; pending rows pass through unconverted)
  uv <- .rc_resolve_units_values(active, registry)
  add_skip(uv$skipped)
  add_review(uv$review)
  active <- uv$kept

  # R-8.5
  dt <- .rc_resolve_datetime(active)
  add_review(dt$review)
  active <- dt$kept

  # R-8.6 / R-11.5b
  mp <- .rc_method_preference(active, registry)
  add_skip(mp$skipped)
  active <- mp$kept

  # R-8.7 / R-11.7
  tw <- .rc_three_way(active, con, event, registry)
  add_skip(tw$skipped)
  add_review(tw$review)
  clean <- tw$kept

  # R-12.13: within-batch duplicate guard (post three-way, catches
  # same-method dupes the DB-only three-way cannot see).
  bd <- .rc_batch_duplicate(clean)
  add_review(bd$review)
  clean <- bd$kept

  skipped <- if (length(skipped_acc) > 0) dplyr::bind_rows(skipped_acc) else .rc_proto_skip()[, skip_cols]
  review <- if (length(review_acc) > 0) dplyr::bind_rows(review_acc) else .rc_proto_review()[, review_cols]

  count_df <- if (length(count_acc) > 0) dplyr::bind_rows(count_acc) else data.frame(key = character(0), n = integer(0))
  counts <- c(clean = as.integer(nrow(clean)))
  if (nrow(count_df) > 0) {
    tbl <- tapply(count_df$n, count_df$key, sum)
    counts <- c(stats::setNames(as.integer(tbl), names(tbl)), counts)
  }

  list(clean = clean, review = review, skipped = skipped, counts = counts)
}
