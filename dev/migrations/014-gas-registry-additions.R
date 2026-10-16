# Operator-run migration: registry additions for the ACIRL monthly gas adapter
# (dev/plans/PLAN-17-adapter-acirl-gas.md).
#
# Robin's authorisation (2026-10-16). Three groups, one transaction, marker 1014.
#
# (a) 21 Blaxland weekly temporary points B.TG385-B.TG405. ACIRL weekly point n is
#     B.TG(384+n). Hand-placed from ACIRL's "NEW SITES TO SAMPLE" map of 13 May 2026
#     (+/-5-10 m); coordinates GDA94 / MGA zone 56 in
#     scratchpad/locate/B_weekly_TG_proposal.csv were converted with
#     sf::st_transform(crs = 28356 -> 4326) and rounded to 6 dp (the `feature`
#     table stores lon/lat in degrees; featureSFC is GDA94 / MGA56). Copied from
#     B.TG179: site B, matrix air, permanent FALSE, reference FALSE, virtual FALSE.
#     Alias `B.Weekly <n>` (kind historical_code: ACIRL's own label for the same
#     point, not a misspelling and not a bare-number mask).
# (b) 12 Katoomba biofilter-area points K.G367-K.G378. Highest K.G in use anywhere
#     is 366 (workbooks: K.G365/K.G366 are real but unregistered, and are left to
#     the unknown_feature review flow); registry and featureSFC stop at K.G364.
#     First 6 = ACIRL grid "North Corner", next 6 = "Front of Buildings", each
#     R1C1, R1C2, R1C3, R2C1, R2C2, R2C3. UNLOCATED: lon/lat are NOT NULL, so each
#     is placed at the live `K.centroid` feature's coordinates (read at run time).
#     Alias `K.Biofilter North Corner R1C1` ... / `K.Front of Buildings R1C1` ...
#     (kind descriptive: a description of where the point is).
# (c) Aliases `B.G179`, `B.G180`, `B.G181` -> B.TG179/180/181 (kind historical_code:
#     ACIRL's code for Council's temporary points). The bare aliases `G179` ...
#     already exist as mask_long aliases of K.G179-181 (auto_assign TRUE), so a
#     bare alias to B.TG would be ambiguous; the adapter emits site-qualified
#     names from workbook content (PLAN-17), so the site-qualified alias is exact.
#
# Not created (per instruction): K.G365, K.G366, B.G201.
#
# Each new feature gets a `self` alias exactly as add_feature() writes it
# (confirmed_by NULL, auto_assign TRUE, n_seen 0). Idempotent: marker present ->
# re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/014-gas-registry-additions.R", envir = env)
#   env$mig014_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig014_marker_version <- 1014L
.mig014_actor <- "014-gas-registry-additions"
.mig014_reason <- "014: registry additions for the ACIRL monthly gas adapter (PLAN-17) (Robin, 2026-10-16)"

.mig014_default <- function(x, default) if (is.null(x)) default else x
.mig014_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])

# GDA94 / MGA56 -> degrees, 6 dp (see header).
.mig014_weekly_lon <- c(150.612354, 150.612539, 150.612575, 150.612766, 150.612897, 150.613063, 150.613205,
  150.613209, 150.613397, 150.613464, 150.613611, 150.613773, 150.613714, 150.613880, 150.614022,
  150.614003, 150.614163, 150.614278, 150.614327, 150.614484, 150.614807)
.mig014_weekly_lat <- c(-33.731267, -33.731561, -33.731150, -33.731424, -33.731108, -33.731347, -33.731564,
  -33.731133, -33.731411, -33.731042, -33.731271, -33.731510, -33.730951, -33.731212, -33.731426,
  -33.730903, -33.731157, -33.731328, -33.730907, -33.731164, -33.731021)

.mig014_cells <- c("R1C1", "R1C2", "R1C3", "R2C1", "R2C2", "R2C3")
.mig014_grids <- c("North Corner", "Front of Buildings")

# The full plan as a data frame: one row per new feature.
.mig014_features <- function(centroid_lon, centroid_lat) {
  wk <- data.frame(
    name = sprintf("B.TG%d", 384L + 1:21), site = "B", lon = .mig014_weekly_lon, lat = .mig014_weekly_lat,
    alias = sprintf("B.Weekly %d", 1:21), alias_kind = "historical_code",
    comments = paste0("Weekly temporary point ", 1:21, " (ACIRL 'B.Weekly ", 1:21, "'). Hand-placed from ACIRL's ",
                      "\"NEW SITES TO SAMPLE\" map of 13 May 2026, accurate to +/-5-10 m. Sampled weekly in May ",
                      "2026 at Rob Morrison's request over odour complaints."),
    stringsAsFactors = FALSE)
  kg <- data.frame(
    name = sprintf("K.G%d", 366L + 1:12), site = "K", lon = centroid_lon, lat = centroid_lat,
    alias = paste0("K.", ifelse(rep(1:2, each = 6) == 1, "Biofilter ", ""), rep(.mig014_grids, each = 6),
                   " ", rep(.mig014_cells, 2)),
    alias_kind = "descriptive",
    comments = paste0("UNLOCATED - placed at the K site centroid as a placeholder; ACIRL 'Biofilter and Bores' sheet, grid ",
                      rep(.mig014_grids, each = 6), " ", rep(.mig014_cells, 2),
                      "; true position to be confirmed (Jane Manners walked it with ACIRL 16 Sep 2024)"),
    stringsAsFactors = FALSE)
  # The task's raw names: "K.Biofilter North Corner R1C1" and "K.Front of Buildings R1C1".
  kg$alias <- paste0("K.", ifelse(rep(1:2, each = 6) == 1, "Biofilter ", ""), rep(.mig014_grids, each = 6),
                     " ", rep(.mig014_cells, 2))
  rbind(wk, kg)
}

.mig014_extra_aliases <- data.frame(
  alias = c("B.G179", "B.G180", "B.G181"), target = c("B.TG179", "B.TG180", "B.TG181"),
  stringsAsFactors = FALSE)

.mig014_counts <- function(con) {
  list(
    feature = .mig014_scalar(con, "SELECT COUNT(*) FROM feature"),
    feature_alias = .mig014_scalar(con, "SELECT COUNT(*) FROM feature_alias"),
    analysis = .mig014_scalar(con, "SELECT COUNT(*) FROM analysis"),
    sample = .mig014_scalar(con, "SELECT COUNT(*) FROM \"sample\"")
  )
}

.mig014_centroid <- function(con) {
  k <- DBI::dbGetQuery(con, "SELECT lon, lat FROM feature WHERE name = 'K.centroid' AND site = 'K'")
  if (nrow(k) != 1L) cli::cli_abort("014-gas-registry-additions: K.centroid is not exactly one feature.", class = "sampletidy_error")
  k
}

.mig014_check_preconditions <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("014-gas-registry-additions: ", msg), class = "sampletidy_error")
  k <- .mig014_centroid(con)
  plan <- .mig014_features(k$lon[[1]], k$lat[[1]])
  keys <- vapply(c(plan$name, plan$alias, .mig014_extra_aliases$alias), .rc_feature_key, "", USE.NAMES = FALSE)
  if (anyNA(keys) || anyDuplicated(keys)) fail("the planned names/aliases do not normalise to 36+33 distinct keys.")
  taken <- DBI::dbGetQuery(con, sprintf("SELECT alias_key FROM feature_alias WHERE alias_key IN (%s)",
                                        paste(sprintf("'%s'", keys), collapse = ", ")))
  if (nrow(taken) > 0) fail(sprintf("alias key(s) already exist: %s.", paste(taken$alias_key, collapse = ", ")))
  nm <- DBI::dbGetQuery(con, sprintf("SELECT name FROM feature WHERE name IN (%s)",
                                     paste(sprintf("'%s'", plan$name), collapse = ", ")))
  if (nrow(nm) > 0) fail(sprintf("feature(s) already exist: %s.", paste(nm$name, collapse = ", ")))
  mx <- .mig014_scalar(con, "SELECT COALESCE(MAX(CAST(regexp_extract(name, '^K\\.G([0-9]+)$', 1) AS INTEGER)), 0)
                              FROM feature WHERE regexp_matches(name, '^K\\.G[0-9]+$')")
  if (mx >= 367L) fail(sprintf("K.G%d is registered; the plan assumed 364 was the highest.", mx))
  tg <- DBI::dbGetQuery(con, sprintf("SELECT name FROM feature WHERE name IN (%s) AND site = 'B' AND matrix = 'air'",
                                     paste(sprintf("'%s'", .mig014_extra_aliases$target), collapse = ", ")))
  if (nrow(tg) != 3L) fail("B.TG179/180/181 are not all present as B/air features.")
  tmpl <- DBI::dbGetQuery(con, "SELECT matrix, permanent, reference, virtual FROM feature WHERE name = 'B.TG179'")
  if (!identical(tmpl$matrix[[1]], "air") || !isFALSE(tmpl$permanent[[1]])) fail("B.TG179 is not the expected template (air, permanent FALSE).")
  invisible(plan)
}

.mig014_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("014-gas-registry-additions verify failed: ", msg), class = "sampletidy_error")
  k <- .mig014_centroid(con)
  plan <- .mig014_features(k$lon[[1]], k$lat[[1]])
  f <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN (%s)", paste(sprintf("'%s'", plan$name), collapse = ", ")))
  if (nrow(f) != 33L) fail(sprintf("%d of 33 features present.", nrow(f)))
  f <- f[match(plan$name, f$name), ]
  if (any(f$site != plan$site) || any(f$matrix != "air") || any(f$virtual) || any(f$reference)) fail("site/matrix/virtual/reference wrong.")
  if (any(f$permanent[f$site == "B"]) || !all(f$permanent[f$site == "K"])) fail("permanent flags wrong.")
  if (any(abs(f$lon - plan$lon) > 1e-9) || any(abs(f$lat - plan$lat) > 1e-9)) fail("coordinates differ from the plan.")
  if (!identical(f$comments, plan$comments)) fail("comments differ from the plan.")
  al <- DBI::dbGetQuery(con, "SELECT a.name, a.kind, a.auto_assign, f.name AS fn FROM feature_alias a JOIN feature f ON f.uuid = a.uuid_feature")
  want <- rbind(
    data.frame(name = plan$name, kind = "self", fn = plan$name),
    data.frame(name = plan$alias, kind = plan$alias_kind, fn = plan$name),
    data.frame(name = .mig014_extra_aliases$alias, kind = "historical_code", fn = .mig014_extra_aliases$target))
  got <- merge(want, al, by = c("name", "kind", "fn"))
  if (nrow(got) != nrow(want) || !all(got$auto_assign)) fail(sprintf("%d of %d aliases present with the right kind/target/auto_assign.", nrow(got), nrow(want)))
  invisible(TRUE)
}

mig014_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig014_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-014-gas-registry-additions_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig014_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig014_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

mig014_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig014_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig014_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("014 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  plan <- tryCatch(.mig014_check_preconditions(pre_con), finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("To add: %d features (%d B.TG, %d K.G at the K.centroid), %d feature_alias rows.",
       nrow(plan), sum(plan$site == "B"), sum(plan$site == "K"), nrow(plan) * 2L + nrow(.mig014_extra_aliases))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  backup_path <- mig014_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig014_default(.now, Sys.time())

  with_db_write(function(con) {
    before <- .mig014_counts(con)
    db_transaction(con, function(con) {
      now <- Sys.time()
      uu <- stats::setNames(character(), character())
      mk_alias <- function(uuid_feature, name, kind, comments = NA_character_) {
        tibble::tibble(uuid = uuid::UUIDgenerate(), uuid_feature = uuid_feature, name = name,
                       alias_key = .rc_feature_key(name), kind = kind, n_seen = 0L, auto_assign = TRUE,
                       first_seen = now, last_seen = now, confirmed_by = NA_character_, comments = comments)
      }
      for (r in seq_len(nrow(plan))) {
        u <- uuid::UUIDgenerate()
        uu[[plan$name[[r]]]] <- u
        is_b <- plan$site[[r]] == "B"
        feat <- tibble::tibble(
          uuid = u, name = plan$name[[r]], site = plan$site[[r]], matrix = "air",
          permanent = !is_b, reference = FALSE, lon = plan$lon[[r]], lat = plan$lat[[r]],
          geom_wkt = sprintf("POINT (%s %s)", format(plan$lon[[r]], digits = 15), format(plan$lat[[r]], digits = 15)),
          comments = plan$comments[[r]], virtual = FALSE)
        db_append(con, "feature", feat, actor = .mig014_actor, reason = .mig014_reason)
        db_append(con, "feature_alias",
                  mk_alias(u, plan$name[[r]], "self", "Self alias created by add_feature() (PLAN-15 F.9/S-15.8)."),
                  actor = .mig014_actor, reason = .mig014_reason)
        db_append(con, "feature_alias", mk_alias(u, plan$alias[[r]], plan$alias_kind[[r]]),
                  actor = .mig014_actor, reason = .mig014_reason)
      }
      for (r in seq_len(nrow(.mig014_extra_aliases))) {
        tgt <- DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(.mig014_extra_aliases$target[[r]]))$uuid
        db_append(con, "feature_alias",
                  mk_alias(tgt, .mig014_extra_aliases$alias[[r]], "historical_code",
                           "ACIRL's code for Council's temporary points B.TG179-181; not a misspelling."),
                  actor = .mig014_actor, reason = .mig014_reason)
      }
      DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                     params = list(.mig014_marker_version, recorded_at))
      .mig014_verify(con)
      after <- .mig014_counts(con)
      if (after$feature != before$feature + 33L ||
          after$feature_alias != before$feature_alias + 33L * 2L + 3L ||
          after$analysis != before$analysis || after$sample != before$sample) {
        cli::cli_abort("014 verify failed: table counts are not before plus exactly the planned rows.",
                       class = "sampletidy_error")
      }
      NULL
    })
    invisible(TRUE)
  }, db = db)

  logf("014-gas-registry-additions migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
