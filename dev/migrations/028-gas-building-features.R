# Operator-run migration: register the ACIRL gas-building points so the gas
# adapter's building readings resolve (PLAN-17; proposal
# scratchpad/2026-10-17-gasbldg/PROPOSAL.md + proposal.csv, 115 rows).
#
# Authorised by Robin, 2026-10-17 (rulings 1-4). One transaction, marker 1028.
# Requires 1026 only. It is independent of 027 (dedupe legacy field readings),
# which is applied before it; nothing here reads or writes what 027 touches.
#
# (1) KATOOMBA: 95 NEW features K.G379-K.G473, in workbook sheet order:
#     `Gas Building 1` rows D8-D39 -> K.G379-410 (32), `Gas Building 2` D8-D43 ->
#     K.G411-446 (36), `Gas Building 3` D8-D34 -> K.G447-473 (27). The order and
#     the set are identical in all four Katoomba gas workbooks (2400-7454-06-01,
#     -09-01, -12-01, 2400-7593-03-01). Copied from migration 014's K.G367-378
#     biofilter grids: site K, matrix air, permanent TRUE, reference FALSE,
#     virtual FALSE, date_start/date_end NULL. UNLOCATED: lon/lat are NOT NULL,
#     so each is placed at the live `K.centroid` feature's coordinates (read at
#     run time), geom_wkt the same POINT; the comment says so and names the
#     ACIRL sheet ("Gas Building n"), location and reference it is.
#     Each gets the `self` alias add_feature() writes and ONE `descriptive`
#     alias whose text is exactly the adapter's site-qualified name
#     (R/adapter-acirl-gas.R: "<site>.<Location> - <Reference>"), e.g.
#     `K.Re-use Center - Toilets-Drain`.
#     REPEATED REFERENCES (ruling 4): ACIRL lists "Power point back wall" twice
#     under Re-use Center (Gas Building 2 D29, D35) and "Window wall 2" twice
#     under Meeting Room (Gas Building 3 D9, D13). The adapter names the second
#     occurrence "<name> #2" (a positional suffix), so those two pairs are told
#     apart by row order only. All 4 features' comments say so. NB the adapter
#     assigns the suffix only to rows that HAVE a value: if ACIRL leaves the
#     first occurrence blank, the second is emitted WITHOUT "#2" and lands on
#     the first's feature.
# (2) BLAXLAND: the 20 building names of the May-2021 (2400-7127-05) and
#     Aug-2024 (2400-7399-08-01) workbooks become `descriptive` aliases of the
#     existing B.G368-B.G384 (proposal.csv). The Toilets pairing is CONFIRMED by
#     Robin: Right Side -> B.G373 (Women's), Left Side -> B.G374 (Men's).
#     B.G379 ("Second office") has no earlier name and gets no alias.
# (3) date_start on B.G368-378 and B.G380-384 (16 features) moves from
#     2024-09-01 back to 2021-05-06 (DATE, like every feature.date_start), the
#     May-2021 reading day; their comment gains a sentence saying building
#     readings from May 2021 were reported by name. EXCEPT B.G384 ("Out side -
#     Reused shed"), which first appears in Aug 2024: it moves to 2024-08-07,
#     the Aug-2024 reading day, and its sentence says reported by name from
#     Aug 2024 (coordinator, 2026-10-17). B.G379 is untouched.
#
# ALIAS DATE BOUNDS: every new alias has date_start = date_end = NULL, i.e.
# unbounded (reconcile: `date_start IS NULL OR date_start <= sample_date`, same
# for date_end), so they resolve the 2021-05 and 2024-08 Blaxland readings and
# the 2025-06..2026-03 Katoomba readings. Feature date_start is not consulted
# by reconcile (only feature.date_end, NULL on all of these).
#
# None of the 210 alias keys and none of the 95 feature names exists before
# (asserted, together with the highest registered K.G being 378 and the 17
# B.G368-384 rows holding date_start 2024-09-01 and the one known comment).
# Inserts go through db_append() and updates through db_update() (actor
# "028-gas-building-features"), so change_log has one row per insert and one
# per changed field. Everything else is checksummed before and after.
#
# The alias texts were checked against what the adapter emits for the real
# workbooks (scratchpad/2026-10-17-mig028/adapter_check.R); that needs the
# workbooks, so it is a rehearsal step, not a runtime check.
#
# BACKUP OF THE ROWS: `028-gas-building-features-BACKUP-feature.csv` (the 16
# Blaxland features as they were) before writing; after commit, the inserted
# rows in `028-gas-building-features-INSERTED-{feature,feature_alias}.csv`;
# plus the verified whole-file backup in `snapshot_dir`.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/028-gas-building-features.R", envir = env)
#   env$mig028_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig028_marker_version <- 1028L
.mig028_requires <- 1026L
.mig028_name <- "028-gas-building-features"
.mig028_actor <- .mig028_name
.mig028_reason <- "028: gas-building points for the ACIRL gas adapter (Robin, 2026-10-17, rulings 1-4)"

# ---- the plan ---------------------------------------------------------------

# Katoomba: the adapter's names in sheet order (June 2025 = every Katoomba file).
.mig028_k_raw <- matrix(ncol = 2, byrow = TRUE, c(
  "K.Office - Window near desk", "Gas Building 1!D8",
  "K.Office - Power point under desk", "Gas Building 1!D9",
  "K.Office - Power point near desk", "Gas Building 1!D10",
  "K.Office - Air conditioner", "Gas Building 1!D11",
  "K.Office - Window 2 near air conditioner", "Gas Building 1!D12",
  "K.Office - Window 3", "Gas Building 1!D13",
  "K.Office - Power Point near printer", "Gas Building 1!D14",
  "K.Meal Room - Window (door hall)", "Gas Building 1!D15",
  "K.Meal Room - Power point below window (Right side)", "Gas Building 1!D16",
  "K.Meal Room - Power point below window (Left side)", "Gas Building 1!D17",
  "K.Meal Room - Air conditioner", "Gas Building 1!D18",
  "K.Meal Room - Power point (Air conditioner wall)", "Gas Building 1!D19",
  "K.Meal Room - Power point (Opposite window)", "Gas Building 1!D20",
  "K.Meal Room - Main Cupboard (2-Door)", "Gas Building 1!D21",
  "K.Meal Room - Power point (Sink)", "Gas Building 1!D22",
  "K.Toilet 1 - Shower/toilet", "Gas Building 1!D23",
  "K.Toilet 1 - Drain near lockers", "Gas Building 1!D24",
  "K.Toilet - Shower/toilet", "Gas Building 1!D25",
  "K.Toilet - Drain/lockers", "Gas Building 1!D26",
  "K.Training room - Air conditioner (door)", "Gas Building 1!D27",
  "K.Training room - Power point", "Gas Building 1!D28",
  "K.Training room - Window 1 (Right hand side)", "Gas Building 1!D29",
  "K.Training room - Power point (below window)", "Gas Building 1!D30",
  "K.Training room - Window 2 (Right hand side)", "Gas Building 1!D31",
  "K.Training room - Sink Cupboard", "Gas Building 1!D32",
  "K.Training room - Sink power point", "Gas Building 1!D33",
  "K.Training room - Toilet 1 (Right hand side)", "Gas Building 1!D34",
  "K.Training room - Toilet 2 (Left hand side)", "Gas Building 1!D35",
  "K.Training room - Cupboard near toilet", "Gas Building 1!D36",
  "K.Training room - Air conditioner (Left hand side)", "Gas Building 1!D37",
  "K.Training room - Window (left hand side)", "Gas Building 1!D38",
  "K.Training room - Power point under window", "Gas Building 1!D39",
  "K.Main Recycle area (Drop Off) - Power point near hose reel", "Gas Building 2!D8",
  "K.Main Recycle area (Drop Off) - Shower drain below stairs", "Gas Building 2!D9",
  "K.Main Recycle area (Drop Off) - Power point near exit door", "Gas Building 2!D10",
  "K.Main Recycle area (Drop Off) - Power point near exit door 2", "Gas Building 2!D11",
  "K.Main Recycle area (Drop Off) - Power point near exit door 3", "Gas Building 2!D12",
  "K.Main Recycle area (Drop Off) - Power point downstairs wall", "Gas Building 2!D13",
  "K.Main Recycle area (Drop Off) - Power point downstairs wall 2", "Gas Building 2!D14",
  "K.Demountable on dump site - Window 1 (Door side)", "Gas Building 2!D15",
  "K.Demountable on dump site - Power point end wall", "Gas Building 2!D16",
  "K.Demountable on dump site - Window 2 (Opposite door)", "Gas Building 2!D17",
  "K.Demountable on dump site - Window 3 (Opposite door)", "Gas Building 2!D18",
  "K.Demountable on dump site - Power point next to window 3", "Gas Building 2!D19",
  "K.Portable near skip bins - Window door side", "Gas Building 2!D20",
  "K.Portable near skip bins - Power point (end wall)", "Gas Building 2!D21",
  "K.Portable near skip bins - Air conditioner (end wall)", "Gas Building 2!D22",
  "K.Portable near skip bins - Power point Right hand side", "Gas Building 2!D23",
  "K.Portable near skip bins - Window Right hand side", "Gas Building 2!D24",
  "K.Re-use Center - Toilets-Drain", "Gas Building 2!D25",
  "K.Re-use Center - Office window", "Gas Building 2!D26",
  "K.Re-use Center - Air conditioner", "Gas Building 2!D27",
  "K.Re-use Center - Power point under desk", "Gas Building 2!D28",
  "K.Re-use Center - Power point back wall", "Gas Building 2!D29",
  "K.Re-use Center - Power point (right hand side wall)", "Gas Building 2!D30",
  "K.Re-use Center - Conference room window", "Gas Building 2!D31",
  "K.Re-use Center - Power point behind fridge", "Gas Building 2!D32",
  "K.Re-use Center - Kitchen sink cupboard", "Gas Building 2!D33",
  "K.Re-use Center - Power point near sink", "Gas Building 2!D34",
  "K.Re-use Center - Power point back wall #2", "Gas Building 2!D35",
  "K.Re-use Center - Power point (side wall entrance)", "Gas Building 2!D36",
  "K.Gatehouse Building - Cupboard wall 1", "Gas Building 2!D37",
  "K.Gatehouse Building - Radio power point wall 2", "Gas Building 2!D38",
  "K.Gatehouse Building - Air conditioner wall 3", "Gas Building 2!D39",
  "K.Gatehouse Building - Power point wall 3", "Gas Building 2!D40",
  "K.Gatehouse Building - Photocopier wall 4", "Gas Building 2!D41",
  "K.Gatehouse Building - Computer wall 5", "Gas Building 2!D42",
  "K.Gatehouse Building - Window wall 1", "Gas Building 2!D43",
  "K.Meeting Room - Door wall 1", "Gas Building 3!D8",
  "K.Meeting Room - Window wall 2", "Gas Building 3!D9",
  "K.Meeting Room - Power point wall 2", "Gas Building 3!D10",
  "K.Meeting Room - Cupboard wall 3", "Gas Building 3!D11",
  "K.Meeting Room - Power point wall 4", "Gas Building 3!D12",
  "K.Meeting Room - Window wall 2 #2", "Gas Building 3!D13",
  "K.Office 1 - Power point wall 4", "Gas Building 3!D14",
  "K.Hallway 1 - Power point wall 1", "Gas Building 3!D15",
  "K.Kitchen - Fridge power point wall 1", "Gas Building 3!D16",
  "K.Kitchen - Sink power point wall 2", "Gas Building 3!D17",
  "K.Kitchen - Sink cupboard wall 2", "Gas Building 3!D18",
  "K.Kitchen - Lockers wall 3", "Gas Building 3!D19",
  "K.Toilets - Men's Toilets", "Gas Building 3!D20",
  "K.Toilets - Ladies Toilets", "Gas Building 3!D21",
  "K.Toilets - Shower", "Gas Building 3!D22",
  "K.Toilets - Sink", "Gas Building 3!D23",
  "K.Hallway 2 - Power point", "Gas Building 3!D24",
  "K.Re-use Shed Storage - Power point (Right side wall)", "Gas Building 3!D25",
  "K.Re-use Shed Storage - Power point (Right side wall 2)", "Gas Building 3!D26",
  "K.Re-use Shed Storage - Power point (Back wall 1)", "Gas Building 3!D27",
  "K.Re-use Shed Storage - Power point (Back wall 2)", "Gas Building 3!D28",
  "K.Re-use Shed Storage - Power point (Back wall 3)", "Gas Building 3!D29",
  "K.Recycle Shed - Power point front wall", "Gas Building 3!D30",
  "K.Recycle Shed - Drain (front section)", "Gas Building 3!D31",
  "K.Recycle Shed - Power point (Back wall)", "Gas Building 3!D32",
  "K.Recycle Shed - Drain (back section)", "Gas Building 3!D33",
  "K.Recycle Shed - Power point (side wall)", "Gas Building 3!D34"))

# The two repeated references (ruling 4): first and "#2" occurrence.
.mig028_repeats <- data.frame(
  first = c("K.Re-use Center - Power point back wall", "K.Meeting Room - Window wall 2"),
  second = c("K.Re-use Center - Power point back wall #2", "K.Meeting Room - Window wall 2 #2"),
  stringsAsFactors = FALSE)

.mig028_k_plan <- function(centroid_lon, centroid_lat) {
  alias <- .mig028_k_raw[, 1]
  ref <- .mig028_k_raw[, 2]
  sheet <- sub("!.*$", "", ref)
  cell <- sub("^.*!", "", ref)
  body <- sub("^K\\.", "", alias)
  loc <- sub(" - .*$", "", body)
  reference <- sub(" #2$", "", sub("^.*? - ", "", body, perl = TRUE))
  name <- sprintf("K.G%d", 378L + seq_along(alias))
  comments <- paste0("UNLOCATED - placed at the K site centroid as a placeholder; building methane point (not an EPA grid point) ",
                     "in ACIRL '", sheet, "' sheet, location '", loc, "', reference '", reference, "' (", cell,
                     "); true position to be confirmed")
  for (i in seq_len(nrow(.mig028_repeats))) {
    a <- match(.mig028_repeats$first[[i]], alias); b <- match(.mig028_repeats$second[[i]], alias)
    pair <- sprintf("ACIRL lists reference '%s' twice under '%s' in '%s' (%s = %s, %s = %s)",
                    reference[[a]], loc[[a]], sheet[[a]], cell[[a]], name[[a]], cell[[b]], name[[b]])
    tail <- "; the two are told apart by row order only (the adapter adds the positional suffix '#2' to the second), so if ACIRL reorders those rows, or leaves the first blank, readings land on the wrong one of the pair"
    comments[[a]] <- paste0(comments[[a]], "; ", pair, ": this is the FIRST", tail)
    comments[[b]] <- paste0(comments[[b]], "; ", pair, ": this is the SECOND ('#2')", tail)
  }
  data.frame(name = name, alias = alias, sheet = sheet, cell = cell, lon = centroid_lon, lat = centroid_lat,
             comments = comments, stringsAsFactors = FALSE)
}

# Blaxland: proposal.csv's 20 rows (alias text -> existing feature), with the basis.
.mig028_b_alias <- data.frame(matrix(ncol = 3, byrow = TRUE, c(
  "B.Weigh Bridge Building - Meal Room", "B.G368", "featureSFC 'Gatehouse - Meal Room'; the gatehouse is the weighbridge building",
  "B.Weigh Bridge Building - Toilet", "B.G369", "featureSFC 'Gatehouse - Toilet'",
  "B.Weigh Bridge Building - Toilet Drain", "B.G370", "featureSFC 'Gatehouse - Toilet Drain'",
  "B.Weigh Bridge Building - South Wall", "B.G371", "featureSFC 'Gatehouse - South Wall'",
  "B.Weigh Bridge Building - North Wall", "B.G372", "featureSFC 'Gatehouse - North Wall'",
  "B.Toilets - Right Side", "B.G373", "featureSFC 'Demountables - Women's toilet'; Right Side = Women's confirmed by Robin 2026-10-17",
  "B.Toilets - Left Side", "B.G374", "featureSFC 'Demountables - Men's toilet'; Left Side = Men's confirmed by Robin 2026-10-17",
  "B.Lunch Room - Centre", "B.G375", "featureSFC 'Demountables - Lunch room'",
  "B.Main Office - Centre", "B.G376", "featureSFC 'Demountables - Main office'",
  "B.Change rooms - Centre", "B.G377", "featureSFC 'Demountables - Change room'",
  "B.Manager's Office - Centre", "B.G378", "featureSFC 'Demountables - Manager's office'",
  "B.Storage Shed - Right Wall", "B.G380", "May-2021 name; Aug-2024 'Storage Shed re used' is the same shed re-purposed, same 4 references in the same order",
  "B.Storage Shed re used - Right Wall", "B.G380", "featureSFC 'Reuse shed - Right Wall'",
  "B.Storage Shed - Back Wall", "B.G381", "May-2021 name; as B.Storage Shed - Right Wall",
  "B.Storage Shed re used - Back Wall", "B.G381", "featureSFC 'Reuse shed - Back Wall'",
  "B.Storage Shed - Left Wall", "B.G382", "May-2021 name; as B.Storage Shed - Right Wall",
  "B.Storage Shed re used - Left Wall", "B.G382", "featureSFC 'Reuse shed - Left Wall'",
  "B.Storage Shed - Centre", "B.G383", "May-2021 name; as B.Storage Shed - Right Wall",
  "B.Storage Shed re used - Centre", "B.G383", "featureSFC 'Reuse shed - Centre'",
  "B.Out side - Reused shed", "B.G384", "featureSFC 'Reuse shed - Outside'")), stringsAsFactors = FALSE)
names(.mig028_b_alias) <- c("alias", "target", "basis")
.mig028_b_alias$comments <- paste0("028 (Robin, 2026-10-17): ACIRL 'Gas Buildings' name used before Oct 2024 (May-2021 2400-7127-05 ",
                                   "and/or Aug-2024 2400-7399-08-01); ", .mig028_b_alias$basis)

# Blaxland date_start + comment (ruling 3).
.mig028_b_all <- sprintf("B.G%d", 368:384)
.mig028_b_redate <- setdiff(.mig028_b_all, "B.G379")
.mig028_b_old_date <- as.Date("2024-09-01")
# B.G384 ("Out side - Reused shed") first appears in Aug 2024, so it takes the
# Aug-2024 reading day; the other 15 take the May-2021 reading day.
.mig028_b_new_date_of <- function(nm) as.Date(ifelse(nm == "B.G384", "2024-08-07", "2021-05-06"))
.mig028_b_old_comment <- paste0("These points are methane levels in buildings. They are not required by the EPA. In older ACIRL reports ",
                                "they were just recorded by name and weren't imported into the monitoring database, however starting in ",
                                "September 2024, they were given an ID and began being imported.")
.mig028_b_new_comment_of <- function(nm) {
  ifelse(nm == "B.G384",
         paste0(.mig028_b_old_comment, " Building readings from August 2024 (2400-7399-08-01) were reported by name ",
                "('Out side - Reused shed'); migration 028 made that name a descriptive alias of this point and moved ",
                "date_start back from 2024-09-01 to 2024-08-07 (Robin, 2026-10-17)."),
         paste0(.mig028_b_old_comment, " Building readings from May 2021 (2400-7127-05) and August 2024 ",
                "(2400-7399-08-01) were reported by name (e.g. 'Weigh Bridge Building - Meal Room'); migration 028 ",
                "made those names descriptive aliases of this point and moved date_start back from 2024-09-01 ",
                "to 2021-05-06 (Robin, 2026-10-17)."))
}

# ---- helpers ----------------------------------------------------------------

.mig028_default <- function(x, default) if (is.null(x)) default else x
.mig028_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig028_fail <- function(msg) cli::cli_abort(paste0(.mig028_name, ": ", msg), class = "sampletidy_error")
.mig028_inlist <- function(ids) paste0("(", paste(DBI::dbQuoteString(DBI::ANSI(), ids), collapse = ", "), ")")

.mig028_centroid <- function(con) {
  k <- DBI::dbGetQuery(con, "SELECT lon, lat FROM feature WHERE name = 'K.centroid' AND site = 'K'")
  if (nrow(k) != 1L) .mig028_fail("K.centroid is not exactly one feature.")
  k
}
.mig028_plan <- function(con) {
  k <- .mig028_centroid(con)
  .mig028_k_plan(k$lon[[1]], k$lat[[1]])
}

# Every alias key 028 creates: 95 self + 95 Katoomba descriptive + 20 Blaxland.
.mig028_new_keys <- function(kp) {
  vapply(c(kp$name, kp$alias, .mig028_b_alias$alias), .rc_feature_key, "", USE.NAMES = FALSE)
}

.mig028_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "analysis", "sample", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig028_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 028 must not touch.
.mig028_checksum <- function(con, kp) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("feature", "feature_alias", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE name NOT IN %s ORDER BY uuid",
                                .mig028_inlist(c(kp$name, .mig028_b_redate))))
  out$feature_redated_fixed <- q(sprintf("SELECT * EXCLUDE (date_start, comments) FROM feature WHERE name IN %s ORDER BY uuid",
                                         .mig028_inlist(.mig028_b_redate)))
  out$feature_alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE alias_key NOT IN %s ORDER BY uuid",
                                      .mig028_inlist(.mig028_new_keys(kp))))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig028_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig028_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig028_blaxland <- function(con) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN %s ORDER BY name", .mig028_inlist(.mig028_b_all)))
}

# The 17 B.G368-384 rows; `done` selects which state their dates/comments must be in.
.mig028_blaxland_problem <- function(con, done) {
  b <- .mig028_blaxland(con)
  if (nrow(b) != 17L || !identical(b$name, .mig028_b_all)) return("B.G368-384 are not exactly 17 features")
  if (any(b$site != "B") || any(b$matrix != "air") || any(b$virtual) || any(!is.na(b$date_end))) return("B.G368-384 are not all B/air, non-virtual, date_end NULL")
  r <- b$name %in% .mig028_b_redate
  want_date <- if (done) .mig028_b_new_date_of(b$name[r]) else rep(.mig028_b_old_date, sum(r))
  want_comm <- if (done) .mig028_b_new_comment_of(b$name[r]) else rep(.mig028_b_old_comment, sum(r))
  if (!isTRUE(all(as.Date(b$date_start[r]) == want_date))) return(sprintf("B.G368-378/380-384 date_start is not %s", if (done) "2021-05-06 (B.G384: 2024-08-07)" else "2024-09-01"))
  if (!isTRUE(all(b$comments[r] == want_comm))) return("B.G368-378/380-384 comments are not the expected text")
  if (!isTRUE(as.Date(b$date_start[!r]) == .mig028_b_old_date) || !identical(b$comments[!r], .mig028_b_old_comment)) return("B.G379 is not as it was (2024-09-01, original comment)")
  NULL
}

.mig028_template_problem <- function(con) {
  t <- DBI::dbGetQuery(con, "SELECT matrix, permanent, reference, virtual, date_start, date_end FROM feature WHERE name = 'K.G367'")
  if (nrow(t) != 1L || !identical(t$matrix, "air") || !isTRUE(t$permanent) || !isFALSE(t$reference) || !isFALSE(t$virtual) ||
      !is.na(t$date_start) || !is.na(t$date_end)) return("K.G367 (014's template) is not air / permanent / not reference / not virtual / undated")
  NULL
}

.mig028_initial_problem <- function(con, kp) {
  keys <- .mig028_new_keys(kp)
  if (anyNA(keys) || anyDuplicated(keys) || length(keys) != 210L) return("the planned names/aliases do not normalise to 210 distinct keys")
  taken <- DBI::dbGetQuery(con, sprintf("SELECT alias_key FROM feature_alias WHERE alias_key IN %s", .mig028_inlist(keys)))
  if (nrow(taken) > 0) return(sprintf("alias key(s) already exist: %s", paste(taken$alias_key, collapse = ", ")))
  nm <- DBI::dbGetQuery(con, sprintf("SELECT name FROM feature WHERE lower(name) IN %s", .mig028_inlist(tolower(kp$name))))
  if (nrow(nm) > 0) return(sprintf("feature(s) already exist: %s", paste(nm$name, collapse = ", ")))
  mx <- .mig028_scalar(con, "SELECT COALESCE(MAX(CAST(regexp_extract(name, '^K\\.G([0-9]+)$', 1) AS INTEGER)), 0)
                              FROM feature WHERE regexp_matches(name, '^K\\.G[0-9]+$')")
  if (mx != 378L) return(sprintf("the highest registered K.G is %d, not 378", mx))
  for (p in list(.mig028_template_problem(con), .mig028_blaxland_problem(con, FALSE))) if (!is.null(p)) return(p)
  NULL
}

.mig028_done_problem <- function(con, kp) {
  f <- DBI::dbGetQuery(con, sprintf("SELECT * FROM feature WHERE name IN %s", .mig028_inlist(kp$name)))
  if (nrow(f) != 95L) return(sprintf("%d of 95 Katoomba features present", nrow(f)))
  f <- f[match(kp$name, f$name), ]
  if (any(f$site != "K") || any(f$matrix != "air") || !all(f$permanent) || any(f$reference) || any(f$virtual)) return("Katoomba site/matrix/permanent/reference/virtual wrong")
  if (any(!is.na(f$date_start)) || any(!is.na(f$date_end))) return("Katoomba features are not undated")
  if (any(abs(f$lon - kp$lon) > 1e-9) || any(abs(f$lat - kp$lat) > 1e-9)) return("Katoomba coordinates are not the K.centroid")
  wkt <- sprintf("POINT (%s %s)", format(kp$lon, digits = 15), format(kp$lat, digits = 15))
  if (!identical(f$geom_wkt, wkt)) return("Katoomba geom_wkt is not the K.centroid point")
  if (!identical(f$comments, kp$comments)) return("Katoomba comments differ from the plan")
  al <- DBI::dbGetQuery(con, sprintf("SELECT a.name, a.alias_key, a.kind, a.auto_assign, a.date_start, a.date_end, a.confirmed_by,
      a.n_seen, a.comments, f.name AS fn FROM feature_alias a JOIN feature f ON f.uuid = a.uuid_feature WHERE a.alias_key IN %s",
      .mig028_inlist(.mig028_new_keys(kp))))
  want <- rbind(
    data.frame(name = kp$name, kind = "self", fn = kp$name, comments = "Self alias created by add_feature() (PLAN-15 F.9/S-15.8)."),
    data.frame(name = kp$alias, kind = "descriptive", fn = kp$name, comments = NA_character_),
    data.frame(name = .mig028_b_alias$alias, kind = "descriptive", fn = .mig028_b_alias$target, comments = .mig028_b_alias$comments))
  if (nrow(al) != nrow(want)) return(sprintf("%d of %d new alias keys present", nrow(al), nrow(want)))
  al <- al[match(want$name, al$name), ]
  if (anyNA(al$name) || !identical(al$kind, want$kind) || !identical(al$fn, want$fn) || !identical(al$comments, want$comments))
    return("new aliases' text/kind/target/comments differ from the plan")
  if (!identical(al$alias_key, .mig028_new_keys(kp))) return("new aliases' alias_key is not .rc_feature_key(name)")
  if (!all(al$auto_assign) || any(!is.na(al$date_start)) || any(!is.na(al$date_end)) || any(!is.na(al$confirmed_by)))
    return("new aliases are not auto_assign TRUE, unbounded and unconfirmed")
  .mig028_blaxland_problem(con, TRUE)
}

.mig028_verify <- function(con) {
  p <- .mig028_done_problem(con, .mig028_plan(con))
  if (!is.null(p)) cli::cli_abort(paste0("028 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

.mig028_check_preconditions <- function(con) {
  if (.mig028_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig028_requires) == 0L) {
    .mig028_fail(sprintf("marker %d (026) is required first.", .mig028_requires))
  }
  kp <- .mig028_plan(con)
  p <- .mig028_initial_problem(con, kp)
  if (!is.null(p)) .mig028_fail(sprintf("the database is not in the pre-028 state (%s). Nothing written.", p))
  invisible(kp)
}

mig028_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig028_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig028_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig028_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig028_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig028_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back$name, as.character(out$name)) ||
      !identical(back$comments, as.character(out$comments))) {
    cli::cli_abort("028: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig028_write <- function(con, kp, recorded_at, sums_before) {
  db_transaction(con, function(con) {
    before <- .mig028_counts(con)
    now <- Sys.time()
    mk_alias <- function(uuid_feature, name, kind, comments = NA_character_) {
      tibble::tibble(uuid = uuid::UUIDgenerate(), uuid_feature = uuid_feature, name = name,
                     alias_key = .rc_feature_key(name), kind = kind, n_seen = 0L, auto_assign = TRUE,
                     first_seen = now, last_seen = now, confirmed_by = NA_character_, comments = comments)
    }
    # (1) Katoomba: feature + self alias + descriptive alias, as 014.
    for (r in seq_len(nrow(kp))) {
      u <- uuid::UUIDgenerate()
      feat <- tibble::tibble(
        uuid = u, name = kp$name[[r]], site = "K", matrix = "air",
        permanent = TRUE, reference = FALSE, lon = kp$lon[[r]], lat = kp$lat[[r]],
        geom_wkt = sprintf("POINT (%s %s)", format(kp$lon[[r]], digits = 15), format(kp$lat[[r]], digits = 15)),
        comments = kp$comments[[r]], virtual = FALSE)
      db_append(con, "feature", feat, actor = .mig028_actor, reason = .mig028_reason)
      db_append(con, "feature_alias",
                mk_alias(u, kp$name[[r]], "self", "Self alias created by add_feature() (PLAN-15 F.9/S-15.8)."),
                actor = .mig028_actor, reason = .mig028_reason)
      db_append(con, "feature_alias", mk_alias(u, kp$alias[[r]], "descriptive"),
                actor = .mig028_actor, reason = sprintf("%s: adapter name of %s %s", .mig028_reason, kp$sheet[[r]], kp$cell[[r]]))
    }
    # (2) Blaxland names -> existing features.
    for (r in seq_len(nrow(.mig028_b_alias))) {
      tgt <- DBI::dbGetQuery(con, "SELECT uuid FROM feature WHERE name = ?", params = list(.mig028_b_alias$target[[r]]))$uuid
      if (length(tgt) != 1L) cli::cli_abort("028: {.mig028_b_alias$target[[r]]} is not exactly one feature.", class = "sampletidy_error")
      db_append(con, "feature_alias", mk_alias(tgt, .mig028_b_alias$alias[[r]], "descriptive", .mig028_b_alias$comments[[r]]),
                actor = .mig028_actor, reason = .mig028_reason)
    }
    # (3) Blaxland date_start + comment.
    b <- .mig028_blaxland(con)
    for (nm in .mig028_b_redate) {
      db_update(con, "feature", uuid = b$uuid[b$name == nm],
                changes = list(date_start = .mig028_b_new_date_of(nm), comments = .mig028_b_new_comment_of(nm)),
                actor = .mig028_actor,
                reason = sprintf("028 (ruling 3, Robin 2026-10-17): %s building readings from %s were reported by name and now resolve by alias; date_start 2024-09-01 -> %s",
                                 nm, if (nm == "B.G384") "Aug 2024" else "May 2021", format(.mig028_b_new_date_of(nm))))
    }

    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig028_marker_version, recorded_at))
    p <- .mig028_done_problem(con, kp)
    if (!is.null(p)) cli::cli_abort(paste0("028 verify failed: ", p), class = "sampletidy_error")
    after <- .mig028_counts(con)
    n_cl <- .mig028_scalar(con, "SELECT COUNT(*) FROM change_log WHERE actor = ?", .mig028_actor)
    if (after$feature != before$feature + 95L || after$feature_alias != before$feature_alias + 210L ||
        after$analysis != before$analysis || after$sample != before$sample ||
        after$schema_version != before$schema_version + 1L ||
        n_cl != 95L + 210L + 2L * length(.mig028_b_redate) || after$change_log != before$change_log + n_cl) {
      cli::cli_abort("028 verify failed: table counts are not before plus exactly the planned rows.", class = "sampletidy_error")
    }
    if (!identical(sums_before, .mig028_checksum(con, kp))) {
      cli::cli_abort("028 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig028_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig028_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig028_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("028 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    kp <- .mig028_check_preconditions(pre_con)
    list(kp = kp, feature = DBI::dbGetQuery(pre_con, sprintf("SELECT * FROM feature WHERE name IN %s ORDER BY name",
                                                             .mig028_inlist(.mig028_b_redate))))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  logf("Plan: %d Katoomba features K.G379-K.G473 at the K.centroid (+%d self, +%d descriptive aliases); %d Blaxland descriptive aliases onto B.G368-384; %d Blaxland date_start 2024-09-01 -> 2021-05-06 (B.G384: 2024-08-07) (+ comment).",
       nrow(pre$kp), nrow(pre$kp), nrow(pre$kp), nrow(.mig028_b_alias), length(.mig028_b_redate))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  .mig028_write_csv(pre$feature, file.path(csv_dir, sprintf("%s-BACKUP-feature.csv", .mig028_name)))
  logf("Row backup written to %s", csv_dir)
  backup_path <- mig028_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig028_default(.now, Sys.time())

  with_db_write(function(con) {
    kp <- .mig028_check_preconditions(con)   # re-read under the write lock
    sums_before <- .mig028_checksum(con, kp)
    .mig028_write(con, kp, recorded_at, sums_before)
  }, db = db)

  ins_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    kp <- .mig028_plan(ins_con)
    .mig028_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM feature WHERE name IN %s ORDER BY name", .mig028_inlist(kp$name))),
                      file.path(csv_dir, sprintf("%s-INSERTED-feature.csv", .mig028_name)))
    .mig028_write_csv(DBI::dbGetQuery(ins_con, sprintf("SELECT * FROM feature_alias WHERE alias_key IN %s ORDER BY name",
                                                       .mig028_inlist(.mig028_new_keys(kp)))),
                      file.path(csv_dir, sprintf("%s-INSERTED-feature_alias.csv", .mig028_name)))
  }, finally = DBI::dbDisconnect(ins_con, shutdown = TRUE))

  logf("Committed: 95 features, 210 feature_alias rows, 16 Blaxland features re-dated; marker %d.", .mig028_marker_version)
  logf("%s migrated successfully.", .mig028_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
