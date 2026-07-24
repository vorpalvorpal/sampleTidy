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

.rc_proto_skip <- function() {
  tibble::tibble(source_ref = character(0), reason = character(0),
                 payload = character(0), source_hash = character(0))
}
.rc_proto_review <- function() {
  tibble::tibble(source_ref = character(0), kind = character(0),
                 payload = character(0), n_rows = integer(0),
                 source_hash = character(0))
}

# ---- R-11.14: fold assembly's inline review flags into reconcile -----------

#' Serialise an assemble-side `review_payload` list deterministically into the
#' review `payload` string column.
#' @keywords internal
#' @noRd
.rc_serialise_payload <- function(p) {
  if (is.null(p) || length(p) == 0) return(NA_character_)
  nms <- names(p)
  if (is.null(nms)) nms <- as.character(seq_along(p))
  parts <- vapply(seq_along(p), function(i) {
    v <- p[[i]]
    paste0(nms[[i]], "=", paste(as.character(v), collapse = "|"))
  }, character(1))
  paste(parts, collapse = ",")
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
#' Rules: NA key -> zero rows (A44); only `auto_assign` aliases enter the set;
#' a dangling alias (uuid_feature NA) is dropped (A44 registry-row guard); when
#' more than one DISTINCT feature survives, narrow by `date_end` ONLY - keep
#' features live at `sample_date` (NA date_end, or date_end >= sample_date).
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
  hit <- fa[!is.na(fa$alias_key) & fa$alias_key == key & .rc_is_true_vec(fa$auto_assign), , drop = FALSE]
  # A44 registry-row guard: an alias that resolves to no feature is not a
  # candidate (its natural-key lookup for pending rows is a separate path,
  # R-11.5a).
  hit <- hit[!is.na(hit$uuid_feature), , drop = FALSE]
  if (nrow(hit) == 0) return(empty)

  cand <- tibble::tibble(uuid_alias = hit$uuid, uuid_feature = hit$uuid_feature)

  cand <- .rc_narrow_live(cand, sample_date, registry)
  cand
}

#' Narrow a candidate tibble to features live at `sample_date` (date_end NA, or
#' date_end >= sample_date), but only when that leaves >=1 candidate and there is
#' a genuine ambiguity to break. Shared by the auto-hit and suggestion paths.
#' @keywords internal
#' @noRd
.rc_narrow_live <- function(cand, sample_date, registry) {
  if (length(unique(cand$uuid_feature)) > 1 && !is.na(sample_date)) {
    feat <- registry$feature
    de <- feat$date_end[match(cand$uuid_feature, feat$uuid)]
    live <- is.na(de) | as.Date(de) >= as.Date(sample_date)
    narrowed <- cand[live, , drop = FALSE]
    if (nrow(narrowed) >= 1) cand <- narrowed
  }
  cand
}

#' Suggested candidate features for review (PLAN-15 A). Like
#' `.rc_feature_candidates` but WITHOUT the `auto_assign` filter, so an ambiguous
#' key - which migration-001 marks `auto_assign = FALSE` on every arm, e.g.
#' `b.s01` -> B.S01 AND B.TS41 - still yields its distinct candidate features.
#' These never auto-resolve; they populate the review payload so an operator can
#' pick. Dangling (uuid_feature NA) aliases are excluded; date narrowing applies.
#' @return character vector of DISTINCT candidate `uuid_feature` (possibly empty).
#' @keywords internal
#' @noRd
.rc_feature_suggestions <- function(feature_raw, sample_date, registry) {
  key <- .rc_feature_key(feature_raw)
  if (is.na(key)) return(character(0))
  fa <- registry$feature_alias
  hit <- fa[!is.na(fa$alias_key) & fa$alias_key == key & !is.na(fa$uuid_feature), , drop = FALSE]
  if (nrow(hit) == 0) return(character(0))
  cand <- tibble::tibble(uuid_alias = hit$uuid, uuid_feature = hit$uuid_feature)
  cand <- .rc_narrow_live(cand, sample_date, registry)
  unique(cand$uuid_feature)
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
    if (!is.na(de) && as.Date(de) < as.Date(sample_date)) return(NA_character_)
  }
  u
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

  # PLAN-15 B/C state, per row: the structural parse, the review-payload
  # suggestion token it yields, and the provenance reason a non-curated
  # resolution carries to COMMIT (reconcile itself writes nothing - A32).
  sites <- .rc_site_registry(registry)
  index <- .rc_structural_index(registry)
  parsed_site <- rep(NA_character_, n)   # the site Layer 2 RECOGNISED, if any
  struct <- rep(NA_character_, n)
  resolution <- rep(NA_character_, n)
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
      uuid_alias[[i]] <- cand$uuid_alias[[1]]
      status[[i]] <- "hit"
      next
    }

    status[[i]] <- "pending"             # unknown (0) or ambiguous (>1)
    pending[[i]] <- TRUE
    # PLAN-15 A: surface EVERY distinct candidate the key reaches (incl. the
    # all-`auto_assign=FALSE` ambiguous case the auto path drops) so review
    # carries a real suggestion instead of a blank unknown.
    sugg <- .rc_feature_suggestions(rows$feature_raw[[i]], row_dates[[i]], registry)
    if (length(sugg) > 1) cand_list[[i]] <- sugg

    # ---- Layer 2 (B): structural (site, point) --------------------------
    p <- .rc_parse_structural(alias_key[[i]], sites)
    if (is.null(p)) next
    parsed_site[[i]] <- p$site
    if (is.na(p$point)) next
    struct[[i]] <- paste0("site=", p$site, ",point=", p$point)
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
      struct[[i]] <- paste0("site=", l3, ",point=", point)
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

  review <- .rc_feature_review(rows, status, cand_list, struct, work_order)
  list(kept = kept, review = review)
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
#' NA/blank key groups into a single sentinel item - A44). `source_hash` is the
#' first of the group (seam S-4). Covers both committable-pending and held rows.
#' @keywords internal
#' @noRd
.rc_feature_review <- function(rows, status, cand_list, struct, work_order) {
  idx <- which(status %in% c("pending", "held"))
  if (length(idx) == 0) return(.rc_proto_review())

  grp_key <- rows$alias_key[idx]
  grp_key[is.na(grp_key)] <- "na"
  groups <- split(idx, grp_key)

  out <- list()
  for (g in groups) {
    refs <- rows$source_ref[g]
    fr <- rows$feature_raw[[g[[1]]]]
    cand <- cand_list[[g[[1]]]]
    st <- struct[g]
    st <- if (any(!is.na(st))) st[!is.na(st)][[1]] else NA_character_
    base <- paste0(
      paste(refs, collapse = ","), ",feature_raw=", fr,
      ",work_order=", work_order, ",n_rows=", length(g)
    )
    # Precedence: an ambiguity is the actionable fact and wins the `subkind`;
    # a structural parse (PLAN-15 B.7 - including the direct-boundary and
    # assumed-site cases, which suggest but never resolve) is the fallback.
    payload <- if (!is.null(cand)) {
      paste0(base, ",subkind=ambiguous,candidates=", paste(cand, collapse = "|"))
    } else if (!is.na(st)) {
      paste0(base, ",subkind=structural,", st)
    } else {
      base
    }
    out[[length(out) + 1]] <- tibble::tibble(
      source_ref = paste(refs, collapse = ","), kind = "unknown_feature",
      payload = payload, n_rows = length(g),
      source_hash = rows$source_hash[[g[[1]]]]
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

  for (i in which(!is.na(cas_suggest))) {
    out[[length(out) + 1]] <- tibble::tibble(
      source_ref = rows$source_ref[[i]], kind = "unknown_analyte",
      payload = paste0(
        rows$source_ref[[i]], ",subkind=known_analyte_no_method,analyte_raw=", rows$analyte_raw[[i]],
        ",org=", rows$org[[i]], ",cas_number=", rows$cas_number[[i]], ",suggested_analyte=", cas_suggest[[i]]
      ),
      n_rows = 1L, source_hash = rows$source_hash[[i]]
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
      out[[length(out) + 1]] <- tibble::tibble(
        source_ref = paste(refs, collapse = ","), kind = "unknown_analyte",
        payload = paste0(paste(refs, collapse = ","), ",analyte_raw=", ar, ",org=", org, ",n_rows=", length(g)),
        n_rows = length(g), source_hash = rows$source_hash[[g[[1]]]]
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
#' - feature-pending with `uuid_feature_alias == NA`: the `feature_alias` row
#'   whose `alias_key == .rc_method_key(feature_raw)` AND `uuid_feature IS NULL`.
#' - analyte-pending with `uuid_lab == NA`: the `lab_method` row with
#'   `uuid_analyte IS NULL` and matching `(organisation, key(name), key(method))`.
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
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], kind = "unknown_unit",
        payload = paste0(
          rows$source_ref[[i]], ",units_raw=", rows$units_raw[[i]], ",analyte=", analyte_row$name[[1]],
          ",value_raw=", rows$value_raw[[i]]
        ),
        n_rows = 1L, source_hash = rows$source_hash[[i]]
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
    review_list[[length(review_list) + 1]] <- tibble::tibble(
      source_ref = rows$source_ref[[i]], kind = "parse_error",
      payload = paste0(
        rows$source_ref[[i]], ",subkind=datetime,sample_datetime_raw=", rows$sample_datetime_raw[[i]]
      ),
      n_rows = 1L, source_hash = rows$source_hash[[i]]
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
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[li]], reason = "method_duplicate",
        payload = paste0("kept_uuid_lab=", kept_uuid_lab), source_hash = rows$source_hash[[li]]
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
      skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], reason = "already_present",
        payload = existing$analysis_uuid[[1]], source_hash = rows$source_hash[[i]]
      )
      next
    }

    recorded_rev <- .rc_recorded_revision(con, rows$work_order[[i]], own_hashes)
    incoming_rev <- rows$revision[[i]]

    if (!is.na(recorded_rev) && !is.na(incoming_rev) && incoming_rev > recorded_rev) {
      supersedes[[i]] <- existing$analysis_uuid[[1]]
    } else {
      keep[[i]] <- FALSE
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[i]], kind = "value_conflict",
        payload = paste0(
          rows$source_ref[[i]], ",existing_value=", exist_value, ",incoming_value=", inc_value,
          ",existing_uuid=", existing$analysis_uuid[[1]], ",existing_quantified=", exist_quant,
          ",incoming_quantified=", inc_quant, ",recorded_revision=", recorded_rev,
          ",incoming_revision=", incoming_rev
        ),
        n_rows = 1L, source_hash = rows$source_hash[[i]]
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
      review_list[[length(review_list) + 1]] <- tibble::tibble(
        source_ref = rows$source_ref[[li]], kind = "batch_duplicate",
        payload = paste0(rows$source_ref[[li]], ",kept_source_ref=", rows$source_ref[[winner]]),
        n_rows = 1L, source_hash = rows$source_hash[[li]]
      )
    }
  }

  review <- if (length(review_list) > 0) dplyr::bind_rows(review_list) else .rc_proto_review()
  list(kept = rows[keep, , drop = FALSE], review = review)
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

  review_cols <- c("source_ref", "kind", "payload", "source_hash")
  skip_cols <- c("source_ref", "reason", "payload", "source_hash")

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
    skipped_acc[[length(skipped_acc) + 1]] <<- df[, skip_cols]
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$reason, n = 1L, stringsAsFactors = FALSE)
  }
  add_review <- function(df) {
    if (nrow(df) == 0) return(invisible())
    count_acc[[length(count_acc) + 1]] <<- data.frame(key = df$kind, n = df$n_rows, stringsAsFactors = FALSE)
    review_acc[[length(review_acc) + 1]] <<- df[, review_cols]
  }

  active <- results

  # STAGE-0 (R-11.14): partition assembly's inline review flags out BEFORE QC.
  # These are "we don't trust this row" flags - held, never committed (distinct
  # from feature/analyte-pending rows which DO commit).
  if ("needs_review" %in% names(active)) {
    flagged <- .rc_is_true_vec(active$needs_review)
    if (any(flagged)) {
      fr <- active[flagged, , drop = FALSE]
      stage0 <- tibble::tibble(
        source_ref = fr$source_ref,
        kind = fr$review_kind,
        payload = vapply(seq_len(nrow(fr)), function(i) .rc_serialise_payload(fr$review_payload[[i]]), character(1)),
        n_rows = 1L,
        source_hash = fr$source_hash
      )
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
