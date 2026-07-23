# dev/cutover/registry-changes.R
#
# PLAN-15 "Registry data changes pending the live cutover" (D.1, D.2, D.3) plus
# the two confirmed live-data defects (D.4a ES2520710 pH, D.4b ES2517594 date).
#
# NEVER invoked by package code. An operator runs it directly, AFTER
# `ensure_schema()` + migration 001 + migration 002 (+ 003 when it exists) have
# been applied to the LOCAL live DB:
#
#   devtools::load_all("/Users/rjs/dev/sampleTidy")
#   env <- new.env()
#   sys.source("dev/cutover/registry-changes.R", envir = env)
#   env$cutover_registry_changes(db = st_config("live_db"), dry_run = TRUE)   # preview
#   env$cutover_registry_changes(db = st_config("live_db"), dry_run = FALSE)  # apply
#
# ---- Rules this file obeys -------------------------------------------------
# * EVERY write goes through the plan-09 mutation layer (`db_append()`,
#   `db_update()`) or the plan-11 resolve API (`confirm_feature_aliases()`).
#   There is no raw `dbExecute()`/`dbAppendTable()`/`dbWriteTable()` write here.
#   Reads via `dbGetQuery()` are fine. Consequence: every row this file changes
#   is accompanied by a `change_log` row carrying `actor` and `reason`.
# * Every step is IDEMPOTENT and re-runnable: each one reads the current state
#   first and skips the work it has already done. Re-running the whole file on
#   an already-changed DB must add no rows and log no changes.
# * The authoritative SharePoint file is NEVER opened by this script. `db` is
#   the LOCAL live DB (DESIGN Sec9.1).
#
# ---- What is DELIBERATELY NOT here: migration 003's territory --------------
# PLAN-15 Work E pins `003-alias-date-bounds.R` as the owner of
#   (i)   `ALTER TABLE feature_alias ADD COLUMN date_start DATE / date_end DATE`
#   (ii)  the `auto_assign = TRUE` flip on exactly the 17 arms of E.5's 8 keys
#   (iii) the 9 curated `date_end` literals of E.5.
# Those are schema + curated-bounds DATA pinned to a numbered migration with its
# own backup/verify/marker discipline, and E.5 says an implementer "must use
# exactly these literals". Duplicating any of them here would mean two writers
# for one fact. This file therefore touches NONE of E.5's 8 alias keys
# (`b.s01`, `b.s04`, `b.s22`, `b.ts02`, `b.ts18`, `b.ts40`, `b.ts41`, `k.e02`)
# and adds no date bounds.
#
# The D.2 curation below IS this file's job, and does not overlap: its two keys
# (`trade waste dam`, `discharge point - lawson stp`) are disjoint from E.5's
# eight, neither exists in the post-001 registry at all (verified: migration 001
# derives alias rows from `feature.cypher` + `feature_mask` variant 'long', and
# neither string appears in either), and both are new-alias creation +
# confirmation rather than bound-setting. `discharge point - lawson stp` also
# depends on B.L05 (D.1), which only exists once this file has run.

# ---------------------------------------------------------------------------
# Constants (DATA - do not recompute, do not "improve")
# ---------------------------------------------------------------------------

.cx_actor <- "R. Shannon"

# --- D.1 -------------------------------------------------------------------
# Coordinates are WGS84 decimal degrees (EPSG:4326). DO NOT REPROJECT.
.cx_bl05 <- list(
  name   = "B.L05",
  site   = "B",
  lon    = 150.431198,
  lat    = -33.732518,
  matrix = "leachate",
  flow   = NA_character_,           # PLAN-15 D.1: not ruled, do not guess
  description = "Leachate tankered to Lawson STP"
)

# --- D.2 -------------------------------------------------------------------
# alias_key is `tolower(trimws(name))` - exactly `.mig001_normalize()`, which is
# what migration 001 writes into `feature_alias.alias_key` and what
# `.rc_feature_key()` reproduces at resolve time (PLAN-15 Work A).
.cx_aliases <- list(
  list(
    name         = "Trade Waste Dam",
    alias_key    = "trade waste dam",
    feature_name = "B.L01",
    kind         = "descriptive",
    comments     = "PLAN-15 D.2: the lab writes `B.L01 (Trade Waste Dam)` in the ES2515987 XTAB - documentary."
  ),
  list(
    name         = "Discharge Point - Lawson STP",
    alias_key    = "discharge point - lawson stp",
    feature_name = "B.L05",
    kind         = "descriptive",
    comments     = "PLAN-15 D.2: clears the remaining `descriptive` residual; B.L01 leachate tankered to Lawson STP and sampled at delivery."
  )
)

# --- D.3 -------------------------------------------------------------------
.cx_orphan_work_orders <- c(
  "ES2413933", "ES2417442", "ES2422258", "ES2515449", "ES2515450", "ES2515987",
  "ES2516159", "ES2517594", "ES2519217", "ES2520710", "ES2606533", "ES2606534",
  "ES2606550", "ES2607370", "ES2607372", "ES2608966"
)

# --- D.4a: ES2520710 pH ------------------------------------------------------
# Source of truth, verified 2026-07-23 against
#   "<input>/KATOOMBA E1 and E2 DISCHARGE.ESDAT_ES2520710_0.Chemistry2e.CSV":
#   ES2520710001,"pH_Lab"  ,"pH Value",6.40,"EA005P: pH by PC Titrator"
#   ES2520710001,"pH_Field","pH"      ,7.41,"EN67 - Client Supplied Data"
#   ES2520710002,"pH_Lab"  ,"pH Value",7.15,"EA005P: pH by PC Titrator"
#   ES2520710002,"pH_Field","pH"      ,6.67,"EN67 - Client Supplied Data"
# The DB stores ONLY 7.41 / 6.67, both under the EA005P method. Robin's ruling:
# KEEP BOTH, each labelled as its own method.
#
# `name`/`method`/`organisation` on the new lab_method row are exactly what the
# ESdat adapter emits for these rows (`analyte_raw = OriginalChemName`,
# `method_raw = Method_Name`, `org = "ALS"` - adapter-esdat.R:226-227,264), so a
# future re-ingest resolves to it by `.rc_resolve_one_analyte()`'s EXACT
# name+org+method arm instead of folding onto "EA005: pH".
.cx_en67 <- list(
  analyte_name = "pH",
  lm_name      = "pH",
  lm_method    = "EN67 - Client Supplied Data",
  lm_org       = "ALS",
  lm_rl_low    = 0.01,
  lm_units     = "pH Unit"
)
.cx_ea005p <- list(
  lm_name   = "pH Value",
  lm_method = "EA005P: pH by PC Titrator",
  lm_org    = "ALS"
)
# lab sample id -> (field pH now to be attributed to EN67, lab pH to be added)
.cx_es2520710_ph <- list(
  list(sample = "ES2520710001", field_ph = 7.41, lab_ph = 6.40),
  list(sample = "ES2520710002", field_ph = 6.67, lab_ph = 7.15)
)

# --- D.4b: ES2517594 date ----------------------------------------------------
# CONFIRMED 2026-07-23 from THREE independent sources, all agreeing on
# 29 May 2025 (Sydney-local):
#   1. "<input>/BWMF 2025 May rain event.ESDAT_ES2517594_0.Sample2e.CSV"
#        ES2517594001,29 May 2025 12:50,"B.E01"
#        ES2517594002,29 May 2025 13:10,"B.S01"
#   2. "<input>/ES2517594_0_XTAB.csv.bak" (the CSV rendering of
#      ES2517594_0_XTAB.XLS; the .XLS itself is not a readable BIFF file -
#      readxl/libxls: "Unable to open file"):
#        Sample Date:,,29/05/2025,29/05/2025
#   3. The DB's own `project` row for ES2517594: date_start = date_end =
#      2025-05-29. Only the two `sample` rows carry the wrong date.
# Corroboration that this is a DATE-only error: the stored `datetime` values
# (02:50 / 03:10 UTC = 12:50 / 13:10 AEST) already match the Sample2e times
# exactly. Only the calendar date moves.
#
# STORED-VALUE CONVENTION (PLAN-15 E.5, re-verified: all 15,113 non-NULL
# `sample.date` values are 13:00 (7,116) or 14:00 (7,995), tracking AEDT/AEST):
# the legacy registry stores Sydney midnight as a UTC-naive TIMESTAMP, so the
# local date 2025-05-29 (AEST, UTC+10) is stored as 2025-05-28 14:00. The
# corrected values below follow that convention exactly - the same convention
# ES2516159 (the same sampling day) already uses.
.cx_es2517594_date <- list(
  list(
    sample         = "ES2517594001",
    date           = "2025-05-28 14:00:00",   # local 2025-05-29
    date_start     = "2025-05-28 14:00:00",
    datetime       = "2025-05-29 02:50:00",   # 12:50 AEST
    datetime_start = "2025-05-29 02:50:00"
  ),
  list(
    sample         = "ES2517594002",
    date           = "2025-05-28 14:00:00",
    date_start     = "2025-05-28 14:00:00",
    datetime       = "2025-05-29 03:10:00",   # 13:10 AEST
    datetime_start = "2025-05-29 03:10:00"
  )
)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

.cx_log <- function(fmt, ...) cat(sprintf("[registry-changes] %s\n", sprintf(fmt, ...)))

.cx_utc <- function(x) as.POSIXct(x, tz = "UTC")

.cx_one <- function(df, what) {
  if (nrow(df) != 1L) {
    cli::cli_abort(
      "Expected exactly 1 row for {what}, found {nrow(df)}.",
      class = "sampletidy_error"
    )
  }
  df
}

.cx_feature_uuid <- function(con, name) {
  .cx_one(
    DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(name)),
    paste0("feature '", name, "'")
  )$uuid[[1]]
}

# ---------------------------------------------------------------------------
# (a) D.1 - create feature B.L05
# ---------------------------------------------------------------------------

#' Create feature B.L05 if it does not already exist.
#'
#' Uses `add_feature()` (R/mutate.R), the documented human write door, which
#' resolves its own connection via `with_db_write(st_config("live_db"))` and
#' requires `lon`/`lat`. The caller must therefore have set
#' `st_config("live_db", db)` - `cutover_registry_changes()` does.
#'
#' Idempotency: returns the existing uuid untouched when a B.L05 row is already
#' present. Aborts if MORE than one exists (that is a defect, not a no-op).
cutover_add_bl05 <- function(db, actor = .cx_actor, dry_run = FALSE) {
  existing <- with_db_write(
    function(con) DBI::dbGetQuery(
      con, "SELECT uuid, name, site, lon, lat FROM feature WHERE name = ?",
      params = list(.cx_bl05$name)
    ),
    db = db
  )
  if (nrow(existing) > 1L) {
    cli::cli_abort(
      "{nrow(existing)} features already named {.val {.cx_bl05$name}} - refusing to proceed.",
      class = "sampletidy_error"
    )
  }
  if (nrow(existing) == 1L) {
    .cx_log("D.1 B.L05 already present (uuid %s) - skipped.", existing$uuid[[1]])
    return(invisible(list(action = "already_present", uuid = existing$uuid[[1]])))
  }
  if (isTRUE(dry_run)) {
    .cx_log("D.1 DRY RUN: would add_feature(name='%s', site='%s', lon=%.6f, lat=%.6f, matrix='%s').",
            .cx_bl05$name, .cx_bl05$site, .cx_bl05$lon, .cx_bl05$lat, .cx_bl05$matrix)
    return(invisible(list(action = "would_add", uuid = NA_character_)))
  }

  uuid <- add_feature(
    name   = .cx_bl05$name,
    site   = .cx_bl05$site,
    lon    = .cx_bl05$lon,
    lat    = .cx_bl05$lat,
    flow   = .cx_bl05$flow,
    matrix = .cx_bl05$matrix,
    actor  = actor,
    reason = paste0(
      "PLAN-15 D.1: new feature B.L05 '", .cx_bl05$description,
      "' - B.L01 leachate tankered to Lawson STP and sampled at delivery, a physically ",
      "distinct sampling location (evidence: ES2515987 carries `B.L01 (Trade Waste Dam)` ",
      "and `Dis Lawson` as two separate ALS samples). Coordinates are WGS84 decimal ",
      "degrees (EPSG:4326). Historical rows stay on B.L01 (Robin's ruling)."
    )
  )
  .cx_log("D.1 B.L05 created (uuid %s).", uuid)
  invisible(list(action = "added", uuid = uuid))
}

#' Give B.L05 the `self` alias that migration 001 would have given it.
#'
#' FINDING (see RUNBOOK Sec F5): `add_feature()` inserts a `feature` row and
#' nothing else. Post-001, `sample.uuid_feature_alias` is the ONLY path from a
#' sample to a feature, and every pre-existing feature got a `kind = 'self'`
#' alias from `.mig001_compute_alias_rows()`. A feature added AFTER 001 has no
#' self alias, so `.rc_feature_candidates("B.L05", ...)` finds nothing and every
#' future B.L05 row lands in review as `unknown_feature` - forever. This step
#' closes that gap for B.L05 specifically; the general fix belongs in
#' `add_feature()` and is flagged for Robin, not patched here.
#'
#' The alias is created pending and then CONFIRMED through
#' `confirm_feature_aliases()`, so `auto_assign` is TRUE and `confirmed_by` is
#' set - the same end state migration 001's self rows have, plus a human.
cutover_add_bl05_self_alias <- function(db, actor = .cx_actor, dry_run = FALSE) {
  alias_key <- tolower(trimws(.cx_bl05$name))   # `.mig001_normalize()`

  state <- with_db_write(function(con) {
    f <- DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(.cx_bl05$name))
    a <- DBI::dbGetQuery(
      con, "SELECT uuid, uuid_feature, kind, confirmed_by FROM feature_alias WHERE alias_key = ?",
      params = list(alias_key)
    )
    list(feature = f, alias = a)
  }, db = db)

  if (nrow(state$feature) == 0) {
    if (isTRUE(dry_run)) {
      .cx_log("D.1 DRY RUN: would also create the `self` alias '%s' -> B.L05.", alias_key)
      return(invisible(list(action = "would_add", uuid_alias = NA_character_)))
    }
    cli::cli_abort("Feature {.val {.cx_bl05$name}} does not exist - cannot alias it.",
                   class = "sampletidy_error")
  }
  uuid_feature <- state$feature$uuid[[1]]

  hit <- state$alias[!is.na(state$alias$uuid_feature) &
                       state$alias$uuid_feature == uuid_feature, , drop = FALSE]
  if (nrow(hit) > 0 && !is.na(hit$confirmed_by[[1]])) {
    .cx_log("D.1 self alias '%s' -> B.L05 already present (%s) - skipped.", alias_key, hit$uuid[[1]])
    return(invisible(list(action = "already_present", uuid_alias = hit$uuid[[1]])))
  }
  if (isTRUE(dry_run)) {
    .cx_log("D.1 DRY RUN: would create+confirm the `self` alias '%s' -> B.L05.", alias_key)
    return(invisible(list(action = "would_add", uuid_alias = NA_character_)))
  }

  uuid_alias <- if (nrow(hit) > 0) hit$uuid[[1]] else {
    new_uuid <- uuid::UUIDgenerate()
    now <- Sys.time()
    row <- tibble::tibble(
      uuid = new_uuid, uuid_feature = NA_character_, name = .cx_bl05$name,
      alias_key = alias_key, kind = "self", n_seen = 0L, auto_assign = TRUE,
      first_seen = now, last_seen = now, confirmed_by = NA_character_,
      comments = "Self alias for B.L05. add_feature() does not create one; migration 001 created a `self` alias for every feature that existed when it ran."
    )
    with_db_write(
      function(con) db_append(
        con, "feature_alias", row, actor = actor,
        reason = "PLAN-15 D.1: self alias for the new feature B.L05 (post-001 features get none from add_feature())."
      ),
      db = db
    )
    new_uuid
  }
  confirm_feature_aliases(
    uuid_alias = uuid_alias, uuid_feature = uuid_feature,
    confirmed_by = actor, db = db
  )
  .cx_log("D.1 self alias '%s' -> B.L05 created and confirmed (%s).", alias_key, uuid_alias)
  invisible(list(action = "added", uuid_alias = uuid_alias))
}

# ---------------------------------------------------------------------------
# (b) D.2 - alias curation
# ---------------------------------------------------------------------------

#' Create-and-confirm the two D.2 aliases.
#'
#' Neither key exists post-001, so each item is a two-move operation:
#'   1. `db_append()` a `feature_alias` row with `uuid_feature = NA` (a pending
#'      alias - exactly the shape ingest itself creates for an unresolved
#'      string), then
#'   2. `confirm_feature_aliases()` (R/feature-alias.R) to set `uuid_feature`,
#'      `confirmed_by` and `auto_assign = TRUE`.
#' Step 2 is what makes the alias usable: `.rc_feature_candidates()` filters on
#' `auto_assign` before anything else, so an unconfirmed row would be inert.
#'
#' Idempotency: if the (alias_key, uuid_feature) pair is already confirmed to the
#' intended feature, both moves are skipped. `confirm_feature_aliases()` itself
#' aborts rather than silently re-pointing an alias already confirmed elsewhere.
cutover_curate_aliases <- function(db, actor = .cx_actor, dry_run = FALSE) {
  out <- list()
  for (item in .cx_aliases) {
    target <- with_db_write(
      function(con) DBI::dbGetQuery(
        con, "SELECT uuid FROM feature WHERE name = ?", params = list(item$feature_name)
      ),
      db = db
    )
    if (nrow(target) == 0L && isTRUE(dry_run)) {
      # Expected on a dry run: `discharge point - lawson stp` targets B.L05,
      # which D.1 has not created because a dry run writes nothing.
      .cx_log("D.2 DRY RUN: would create+confirm alias '%s' -> %s (target feature not yet created).",
              item$alias_key, item$feature_name)
      out[[item$alias_key]] <- list(action = "would_create_and_confirm", uuid_alias = NA_character_)
      next
    }
    target_uuid <- .cx_one(target, paste0("feature '", item$feature_name, "'"))$uuid[[1]]

    current <- with_db_write(
      function(con) DBI::dbGetQuery(
        con,
        "SELECT uuid, uuid_feature, kind, auto_assign, confirmed_by
           FROM feature_alias WHERE alias_key = ?",
        params = list(item$alias_key)
      ),
      db = db
    )

    already <- current[!is.na(current$uuid_feature) & current$uuid_feature == target_uuid, , drop = FALSE]
    if (nrow(already) > 0 && !is.na(already$confirmed_by[[1]])) {
      .cx_log("D.2 '%s' -> %s already confirmed (alias %s) - skipped.",
              item$alias_key, item$feature_name, already$uuid[[1]])
      out[[item$alias_key]] <- list(action = "already_confirmed", uuid_alias = already$uuid[[1]])
      next
    }

    if (isTRUE(dry_run)) {
      .cx_log("D.2 DRY RUN: would create+confirm alias '%s' (kind=%s) -> %s.",
              item$alias_key, item$kind, item$feature_name)
      out[[item$alias_key]] <- list(action = "would_create_and_confirm", uuid_alias = NA_character_)
      next
    }

    uuid_alias <- if (nrow(already) > 0) {
      already$uuid[[1]]
    } else {
      # A row for this key may exist against a DIFFERENT feature (a genuine
      # multi-arm key). That is fine - we add our arm; ambiguity is then decided
      # by the resolver, not by us.
      new_uuid <- uuid::UUIDgenerate()
      now <- Sys.time()
      row <- tibble::tibble(
        uuid = new_uuid, uuid_feature = NA_character_, name = item$name,
        alias_key = item$alias_key, kind = item$kind, n_seen = 0L,
        auto_assign = TRUE, first_seen = now, last_seen = now,
        confirmed_by = NA_character_, comments = item$comments
      )
      with_db_write(
        function(con) db_append(
          con, "feature_alias", row, actor = actor,
          reason = paste0("PLAN-15 D.2: create curated alias '", item$alias_key, "'.")
        ),
        db = db
      )
      new_uuid
    }

    confirm_feature_aliases(
      uuid_alias = uuid_alias, uuid_feature = target_uuid,
      confirmed_by = actor, db = db
    )
    .cx_log("D.2 '%s' -> %s created and confirmed (alias %s).",
            item$alias_key, item$feature_name, uuid_alias)
    out[[item$alias_key]] <- list(action = "created_and_confirmed", uuid_alias = uuid_alias)
  }
  invisible(out)
}

# ---------------------------------------------------------------------------
# (c) D.3 - register the 16 orphaned Chemistry2e files as retained assets
# ---------------------------------------------------------------------------

#' Locate the canonical (non-bracket-suffixed) Chemistry2e file for a work order.
#'
#' macOS bracket-suffixed the 2026-07-23 re-download collisions
#' (`...Chemistry2e[94].CSV`). Those suffixed copies are byte-identical
#' duplicates of the originals (SHA-256 verified for all three affected work
#' orders), so the unsuffixed original is registered and the duplicate ignored.
.cx_find_chemistry2e <- function(input_dir, wo) {
  files <- list.files(input_dir, full.names = TRUE)
  hit <- grep(paste0(wo, "_0\\.Chemistry2e\\.CSV$"), files, value = TRUE)
  if (length(hit) != 1L) {
    cli::cli_abort(
      "Expected exactly 1 unsuffixed Chemistry2e file for {wo} in {.path {input_dir}}, found {length(hit)}.",
      class = "sampletidy_error"
    )
  }
  hit
}

#' Register each of the 16 orphaned Chemistry2e files as an `asset` row.
#'
#' PLAN-15 D.3 (Robin, 2026-07-23): do not delete these; retain the source
#' document as a saved asset against its work order's project.
#'
#' Idempotency: keyed on `(uuid_project, filename)`. A second run finds the row
#' and skips it.
#'
#' `hash` is SHA-256 via the package's own `hash_file()` (R-1.2). NOTE that the
#' 2,407 pre-existing `asset.hash` values are 32-hex, i.e. MD5, written by the
#' retired WEM.data loader - so `asset.hash` is now mixed-algorithm. Flagged in
#' the runbook; not silently "fixed" here.
#'
#' `date` is the file's mtime - a real, verifiable property of the retained
#' document (when the lab's file landed), never a guessed sampling date.
cutover_register_orphan_assets <- function(db, input_dir, actor = .cx_actor, dry_run = FALSE) {
  results <- list()
  for (wo in .cx_orphan_work_orders) {
    path <- .cx_find_chemistry2e(input_dir, wo)
    fname <- basename(path)
    fhash <- hash_file(path)
    fdate <- as.POSIXct(file.mtime(path))

    proj <- with_db_write(
      function(con) DBI::dbGetQuery(
        con, "SELECT uuid FROM project WHERE name = ? AND type = 'Work order'",
        params = list(wo)
      ),
      db = db
    )
    .cx_one(proj, paste0("project (Work order) '", wo, "'"))
    uuid_project <- proj$uuid[[1]]

    existing <- with_db_write(
      function(con) DBI::dbGetQuery(
        con, "SELECT uuid FROM asset WHERE uuid_project = ? AND filename = ?",
        params = list(uuid_project, fname)
      ),
      db = db
    )
    if (nrow(existing) > 0) {
      .cx_log("D.3 %s: asset already registered (%s) - skipped.", wo, existing$uuid[[1]])
      results[[wo]] <- list(action = "already_present", uuid = existing$uuid[[1]])
      next
    }
    if (isTRUE(dry_run)) {
      .cx_log("D.3 DRY RUN: would register %s for %s (sha256 %s...).", fname, wo, substr(fhash, 1, 12))
      results[[wo]] <- list(action = "would_register", uuid = NA_character_)
      next
    }

    new_uuid <- uuid::UUIDgenerate()
    row <- tibble::tibble(
      uuid = new_uuid,
      name = "ESdat Chemistry2e",
      date = fdate,
      file_format = "csv",
      type = "Chemical analysis",
      purpose = NA_character_,
      organisation = "ALS",
      person = NA_character_,
      uuid_project = uuid_project,
      uuid_feature = NA_character_,
      filename = fname,
      hash = fhash,
      comments = paste0(
        "PLAN-15 D.3: retained orphaned ESdat Chemistry2e for work order ", wo,
        " (no companion Sample2e in the corpus at the 2026-07-23 survey, so every ",
        "row carried feature_raw = NA and was held at reconcile). Robin's ruling: ",
        "retain the source document, do not delete. hash is SHA-256 (hash_file())."
      )
    )
    with_db_write(
      function(con) db_append(
        con, "asset", row, actor = actor,
        reason = paste0("PLAN-15 D.3: register orphaned Chemistry2e for ", wo, " as a retained asset."),
        source_hash = fhash
      ),
      db = db
    )
    .cx_log("D.3 %s: registered %s (uuid %s).", wo, fname, new_uuid)
    results[[wo]] <- list(action = "registered", uuid = new_uuid)
  }
  invisible(results)
}

# ---------------------------------------------------------------------------
# (d.1) ES2520710 - keep BOTH pH values, each under its own method
# ---------------------------------------------------------------------------

#' Ensure the `EN67 - Client Supplied Data` pH lab_method exists; return its uuid.
.cx_ensure_en67_method <- function(con, actor, dry_run) {
  found <- DBI::dbGetQuery(
    con,
    "SELECT uuid FROM lab_method WHERE name = ? AND method = ? AND organisation = ?",
    params = list(.cx_en67$lm_name, .cx_en67$lm_method, .cx_en67$lm_org)
  )
  if (nrow(found) == 1L) return(list(action = "already_present", uuid = found$uuid[[1]]))
  if (nrow(found) > 1L) {
    cli::cli_abort(
      "{nrow(found)} lab_method rows already match ({.cx_en67$lm_name}, {.cx_en67$lm_method}, {.cx_en67$lm_org}).",
      class = "sampletidy_error"
    )
  }
  analyte <- .cx_one(
    DBI::dbGetQuery(con, "SELECT uuid, units FROM analyte WHERE name = ?",
                    params = list(.cx_en67$analyte_name)),
    paste0("analyte '", .cx_en67$analyte_name, "'")
  )
  if (isTRUE(dry_run)) return(list(action = "would_add", uuid = NA_character_))

  new_uuid <- uuid::UUIDgenerate()
  row <- tibble::tibble(
    uuid = new_uuid, uuid_analyte = analyte$uuid[[1]],
    name = .cx_en67$lm_name, method = .cx_en67$lm_method,
    organisation = .cx_en67$lm_org, rl_low = .cx_en67$lm_rl_low,
    rl_high = NA_real_, reported_as = NA_character_, api = NA_character_,
    uuid_project = NA_character_, uuid_feature = NA_character_,
    comments = paste0(
      "Client-supplied field pH transcribed into the ALS ESdat report. Distinct ",
      "method from `EA005P: pH by PC Titrator` (lab titrator) and from `EA005: pH`. ",
      "Created at cutover so a re-ingest resolves the ESdat `pH_Field` rows on the ",
      "EXACT name+organisation+method arm instead of folding them onto EA005: pH."
    ),
    units = .cx_en67$lm_units, conversion_constant = NA_real_
  )
  db_append(
    con, "lab_method", row, actor = actor,
    reason = "Cutover D.4a: create the `EN67 - Client Supplied Data` pH method (Robin's KEEP-BOTH ruling)."
  )
  list(action = "added", uuid = new_uuid)
}

#' Re-attribute the stored ES2520710 field pH values to EN67 and add the missing
#' EA005P lab pH values.
#'
#' Idempotency: the re-attribution is a `db_update()` of `analysis.uuid_lab`
#' (a no-op the second time - `db_update()` skips a field whose new value equals
#' its current value); the addition is guarded by a lookup for an existing
#' analysis on that sample under the EA005P method.
cutover_fix_es2520710_ph <- function(db, actor = .cx_actor, dry_run = FALSE) {
  with_db_write(function(con) {
    en67 <- .cx_ensure_en67_method(con, actor = actor, dry_run = dry_run)
    .cx_log("D.4a EN67 lab_method: %s (%s).", en67$action, en67$uuid)

    ea005p <- .cx_one(
      DBI::dbGetQuery(
        con, "SELECT uuid FROM lab_method WHERE name = ? AND method = ? AND organisation = ?",
        params = list(.cx_ea005p$lm_name, .cx_ea005p$lm_method, .cx_ea005p$lm_org)
      ),
      "the EA005P `pH Value` lab_method"
    )$uuid[[1]]

    for (it in .cx_es2520710_ph) {
      # The `sample` row is keyed by its ALS lab sample id, which the legacy
      # loader used verbatim as `sample.uuid`.
      s <- .cx_one(
        DBI::dbGetQuery(con, 'SELECT uuid FROM "sample" WHERE uuid = ?', params = list(it$sample)),
        paste0("sample '", it$sample, "'")
      )$uuid[[1]]

      # --- 1. re-attribute the stored field value to EN67 ---
      stored <- DBI::dbGetQuery(
        con,
        "SELECT uuid, value, uuid_lab FROM analysis WHERE uuid_sample = ? AND uuid_lab IN (?, ?)",
        params = list(s, ea005p, if (is.na(en67$uuid)) "" else en67$uuid)
      )
      field_row <- stored[!is.na(stored$value) &
                            abs(stored$value - it$field_ph) < 1e-9, , drop = FALSE]
      if (nrow(field_row) != 1L) {
        cli::cli_abort(
          "Expected exactly 1 stored pH analysis of {it$field_ph} on sample {it$sample}, found {nrow(field_row)}.",
          class = "sampletidy_error"
        )
      }
      if (isTRUE(dry_run)) {
        .cx_log("D.4a DRY RUN: %s: would re-attribute pH %.2f (analysis %s) to EN67, and add EA005P pH %.2f.",
                it$sample, it$field_ph, field_row$uuid[[1]], it$lab_ph)
        next
      }
      if (!identical(field_row$uuid_lab[[1]], en67$uuid)) {
        db_update(
          con, "analysis", field_row$uuid[[1]],
          changes = list(uuid_lab = en67$uuid), actor = actor,
          reason = paste0(
            "Cutover D.4a: sample ", it$sample, " carries TWO pH values in the source ",
            "Chemistry2e - lab titrator (EA005P) and client-supplied field pH (EN67). ",
            "The stored value ", it$field_ph, " is the FIELD value and was mislabelled ",
            "under EA005P; re-attributed to `EN67 - Client Supplied Data`. ",
            "Robin's ruling 2026-07-23: keep both, each labelled as its own method."
          )
        )
        .cx_log("D.4a %s: pH %.2f re-attributed to EN67 (analysis %s).", it$sample, it$field_ph, field_row$uuid[[1]])
      } else {
        .cx_log("D.4a %s: pH %.2f already on EN67 - skipped.", it$sample, it$field_ph)
      }

      # --- 2. add the missing EA005P lab value ---
      present <- DBI::dbGetQuery(
        con, "SELECT uuid, value FROM analysis WHERE uuid_sample = ? AND uuid_lab = ?",
        params = list(s, ea005p)
      )
      if (nrow(present) > 0) {
        .cx_log("D.4a %s: an EA005P analysis already present (%s, value %s) - skipped.",
                it$sample, present$uuid[[1]], present$value[[1]])
        next
      }
      row <- tibble::tibble(
        uuid = uuid::UUIDgenerate(), uuid_sample = s, uuid_lab = ea005p,
        value = it$lab_ph, value_chr = NA_character_, quantified = TRUE,
        rl_low = 0.01, rl_high = NA_real_, purpose = NA_character_,
        comments = "Lab titrator pH (EA005P), present in the source Chemistry2e but never loaded."
      )
      db_append(
        con, "analysis", row, actor = actor,
        reason = paste0(
          "Cutover D.4a: add the EA005P lab-titrator pH ", it$lab_ph, " for sample ",
          it$sample, ", present in the source Chemistry2e but absent from the DB. ",
          "Robin's ruling 2026-07-23: keep both pH values, each labelled as its own method."
        )
      )
      .cx_log("D.4a %s: EA005P pH %.2f added.", it$sample, it$lab_ph)
    }
  }, db = db)
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# (d.2) ES2517594 - correct the impossible sampling date
# ---------------------------------------------------------------------------

#' Correct `sample.date` / `date_start` / `datetime` / `datetime_start` on
#' ES2517594001 and ES2517594002.
#'
#' Idempotency: `db_update()` skips a field whose new value already equals the
#' stored one, so a second run writes nothing and logs nothing.
cutover_fix_es2517594_date <- function(db, actor = .cx_actor, dry_run = FALSE) {
  with_db_write(function(con) {
    for (it in .cx_es2517594_date) {
      cur <- .cx_one(
        DBI::dbGetQuery(
          con, 'SELECT uuid, date, date_start, datetime, datetime_start FROM "sample" WHERE uuid = ?',
          params = list(it$sample)
        ),
        paste0("sample '", it$sample, "'")
      )
      changes <- list(
        date           = .cx_utc(it$date),
        date_start     = .cx_utc(it$date_start),
        datetime       = .cx_utc(it$datetime),
        datetime_start = .cx_utc(it$datetime_start)
      )
      if (isTRUE(dry_run)) {
        .cx_log("D.4b DRY RUN: %s: date %s -> %s, datetime %s -> %s.",
                it$sample, format(cur$date[[1]]), it$date,
                format(cur$datetime[[1]]), it$datetime)
        next
      }
      db_update(
        con, "sample", it$sample, changes = changes, actor = actor,
        reason = paste0(
          "Cutover D.4b: ES2517594 sampling date corrected to 2025-05-29 (Sydney-local). ",
          "The stored 2025-09-08 14:00 (local 2025-09-09) is three months AFTER the lab ",
          "analysed the samples (2025-06-12..2025-06-18), which is impossible. Confirmed ",
          "from the ESdat Sample2e (`29 May 2025 12:50` / `13:10`), from ES2517594_0_XTAB ",
          "(`Sample Date: 29/05/2025`), and from this DB's own project row for ES2517594 ",
          "(date_start = date_end = 2025-05-29). Stored using the legacy convention: ",
          "Sydney midnight as a UTC-naive TIMESTAMP, i.e. 2025-05-28 14:00 AEST-midnight."
        )
      )
      .cx_log("D.4b %s: date corrected to %s (local 2025-05-29).", it$sample, it$date)
    }
  }, db = db)
  invisible(NULL)
}

# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------

#' Apply every cutover registry change, in dependency order.
#'
#' @param db path to the LOCAL live DuckDB file (never the SharePoint file).
#' @param input_dir directory holding the ESdat source files (for D.3 hashes).
#' @param actor recorded on every `change_log` row.
#' @param dry_run if TRUE, report what would happen and write nothing.
#' @return invisible list of per-step results.
cutover_registry_changes <- function(db,
                                     input_dir = st_config("input_dir"),
                                     actor = .cx_actor,
                                     dry_run = FALSE) {
  checkmate::assert_string(db)
  checkmate::assert_string(input_dir)
  checkmate::assert_string(actor)
  checkmate::assert_flag(dry_run)

  # add_feature() resolves its own connection via st_config("live_db") (A16).
  old <- getOption("sampletidy.live_db")
  st_config("live_db", db)
  on.exit(options(sampletidy.live_db = old), add = TRUE)

  # Pre-flight: the mutation layer writes `change_log` in the same transaction
  # as every change, so a DB without it fails halfway. Fail before writing.
  have <- with_db_write(
    function(con) DBI::dbListTables(con), db = db
  )
  missing <- setdiff(c("change_log", "feature_alias", "schema_version"), have)
  if (length(missing) > 0) {
    cli::cli_abort(
      "{.path {db}} is missing {missing} - run ensure_schema() and migration 001 first.",
      class = "sampletidy_error"
    )
  }

  .cx_log("db = %s (dry_run = %s)", db, dry_run)
  res <- list()
  res$bl05     <- cutover_add_bl05(db, actor = actor, dry_run = dry_run)
  res$bl05_self <- cutover_add_bl05_self_alias(db, actor = actor, dry_run = dry_run)
  res$aliases  <- cutover_curate_aliases(db, actor = actor, dry_run = dry_run)
  res$assets   <- cutover_register_orphan_assets(db, input_dir = input_dir, actor = actor, dry_run = dry_run)
  res$es2520710 <- cutover_fix_es2520710_ph(db, actor = actor, dry_run = dry_run)
  res$es2517594 <- cutover_fix_es2517594_date(db, actor = actor, dry_run = dry_run)
  .cx_log("done.")
  invisible(res)
}
