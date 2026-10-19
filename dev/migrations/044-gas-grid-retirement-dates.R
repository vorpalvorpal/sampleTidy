# Operator-run migration: move the retirement date (feature.date_end) of the OLD
# Blaxland and Katoomba gas grids to the day before their successor grid was
# first sampled, and move every alias bound to the old window with it.
# Marker 1044. Requires 1043.
#
# Authority: Robin, 2026-10-19: the registry's date_end for the old gas grids is
# WRONG. The old grids were still being read after the registered end.
#
# ---- EVIDENCE (measured on live at 1043, 2026-10-19) --------------------------
# Registry: B.G001-B.G178 date_end 2023-02-08; K.G026-K.G185 date_end 2023-03-08.
# Live holds legacy samples on EVERY ONE of those 338 points after that end
# (Sydney dates): Blaxland monthly rounds 2023-02-16 .. 2024-01-22 (178 points x
# 12 rounds), Katoomba 2023-05-11 .. 2023-12-19 (160 points x 5 rounds). The 32
# corpus gas workbooks (11 Blaxland 2023-04..2024-01, 6 Katoomba 2023-05..2023-12
# of them) report the same points again. The successor grids - identified, not
# typed in, as the gas grid features whose feature_mask `old` name is an old-grid
# feature of the same site (B.G182-B.G367, 185; K.G186-K.G364, 179) - have NO
# sample before 2024-02-19 (B) / 2024-03-04 (K): one grid replaced the other
# between two monthly rounds, with no overlap.
#
# ---- WHAT ----------------------------------------------------------------------
# Per site S in {B, K}, all DERIVED from the data:
#   first(S)  = the earliest Sydney sample date on any successor feature of S;
#   new_end(S) = first(S) - 1 day                        (B 2024-02-18, K 2024-03-03)
#   old-grid candidates = gas grid features `S.G<digits>` (name prefix = site)
#     with a non-NULL date_end < new_end(S);
#   a candidate is EXTENDED only when it has its OWN evidence: >= 1 live sample
#     dated after its current date_end. Then date_end := new_end(S).
# Candidates with no such sample are NOT touched and are reported: on live
# that is K.G01-K.G24 (21 points, date_end 2022-01-01) - no sample on them at
# all, and no corpus workbook names a K grid number below 26 - so the K.G0x
# windows, and 041's K.G1-K.G9 aliases bound to them, stay as they are.
# Every feature_alias row on an extended feature whose date_end is non-NULL
# (on live: only 041's unpadded-spelling aliases, B 108 + K 74) gets the same
# new date_end; its date_start is untouched. Self, mask_long and other aliases
# on these features carry NULL bounds and are not touched (they were narrowed
# only by the feature's own date_end, which moves).
# Successor features, feature.date_start (B successors say 2023-02-09, K
# 2022-03-09 - also not when they were first read; NOT changed, the resolver
# never reads a feature date_start) and every sample are untouched.
#
# ---- PRECONDITIONS (any failure aborts; nothing is written) ---------------------
#   * marker 1043 present;
#   * the plan is exactly the measured one (.mig044_expected): per site the
#     number of extended features and aliases, their uniform old date_end, and
#     new_end - so a changed registry means "re-measure", not a silent rewrite;
#   * no extended feature has a sample after new_end (the old grid never
#     out-lived its successor's first round);
#   * every bounded alias on an extended feature ends exactly on the feature's
#     old date_end (an alias with some other bound is a different curation act);
#   * NO OVERLAP: on the simulated post-migration registry, no alias_key that
#     reaches an extended feature reaches two DISTINCT features through
#     auto_assign arms live on the same date anywhere in the extension window
#     (old end, new end] - the resolver's own liveness rule, alias bounds AND
#     feature date_end (.rc_alias_live / .rc_narrow_live_feature);
#   * the structural (site, point) key of each extended feature (`B|G1` for
#     B.G001) belongs to no other feature, so a structural parse of "B.G1" can
#     never meet a successor point.
#
# Writes, in one transaction: db_update of feature.date_end (one change_log
# update row each, actor "044-gas-grid-retirement-dates") and of
# feature_alias.date_end (likewise), and the marker; every other table, row and
# column is checksummed before and after. Backups: verified whole-file snapshot
# in snapshot_dir, plus `044-gas-grid-retirement-dates-BACKUP-{feature,feature_alias}.csv`
# (the touched rows, before). The run also REPORTS (writes nothing about them)
# how many live samples dated inside the extension window sit on a pending
# (feature-less) alias whose name would now resolve - 0 on live at 1043.
#
# Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/044-gas-grid-retirement-dates.R", envir = env)
#   env$mig044_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig044_marker_version <- 1044L
.mig044_requires <- 1043L
.mig044_name <- "044-gas-grid-retirement-dates"
.mig044_actor <- .mig044_name
.mig044_sites <- c("B", "K")
.mig044_expected <- list(
  B = list(n_feature = 178L, n_alias = 108L, old_end = as.Date("2023-02-08"), new_end = as.Date("2024-02-18")),
  K = list(n_feature = 160L, n_alias = 74L, old_end = as.Date("2023-03-08"), new_end = as.Date("2024-03-03")))
.mig044_reason <- function(site, old_end, new_end) {
  sprintf("044 (Robin, 2026-10-19: old gas grid retirement dates are wrong): %s old grid sampled after %s; date_end -> %s, the day before the successor grid's first sample",
          site, format(old_end), format(new_end))
}

.mig044_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig044_fail <- function(msg) cli::cli_abort(paste0(.mig044_name, ": ", msg), class = "sampletidy_error")
.mig044_inlist <- function(x) paste0("(", paste0("'", x, "'", collapse = ","), ")")
.mig044_syd <- function(x) as.Date(x, tz = "Australia/Sydney")

.mig044_counts <- function(con) {
  tabs <- c("feature", "feature_alias", "feature_mask", "analysis", "sample", "project", "review_queue",
            "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig044_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Gas grid features of B and K: name `<site>.G<digits>`, prefix = own site.
.mig044_grid <- function(con) {
  f <- DBI::dbGetQuery(con, "SELECT uuid, name, site, date_start, date_end FROM feature WHERE site IN ('B', 'K')")
  m <- regmatches(f$name, regexec("^([A-Z]+)\\.G([0-9]+)$", f$name))
  ok <- lengths(m) == 3L
  f <- f[ok, , drop = FALSE]
  f$prefix <- vapply(m[ok], `[[`, character(1), 2L)
  f <- f[f$prefix == f$site, , drop = FALSE]
  f$date_start <- as.Date(f$date_start); f$date_end <- as.Date(f$date_end)
  f
}

# Sydney sample dates per feature (through every alias kind).
.mig044_samples <- function(con, uuids) {
  if (!length(uuids)) return(data.frame(uuid_feature = character(0), d = as.Date(character(0))))
  s <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid_feature, s.date FROM sample s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias WHERE fa.uuid_feature IN %s", .mig044_inlist(uuids)))
  data.frame(uuid_feature = s$uuid_feature, d = .mig044_syd(s$date), stringsAsFactors = FALSE)
}

# Successor features of one site: gas grid features whose feature_mask `old`
# name is a gas grid feature of the same site.
.mig044_successors <- function(con, grid, site) {
  fm <- DBI::dbGetQuery(con, "SELECT uuid_feature, name FROM feature_mask WHERE variant = 'old' AND name IS NOT NULL")
  g <- grid[grid$site == site, , drop = FALSE]
  fm <- fm[fm$uuid_feature %in% g$uuid & fm$name %in% g$name, , drop = FALSE]
  unique(fm$uuid_feature)
}

# Per site: successor first date, new_end, old-grid candidates with evidence.
.mig044_measure <- function(con) {
  grid <- .mig044_grid(con)
  out <- list()
  for (s in .mig044_sites) {
    succ <- .mig044_successors(con, grid, s)
    ss <- .mig044_samples(con, succ)
    if (!nrow(ss)) .mig044_fail(sprintf("site %s: the successor grid has no samples - nothing to derive the end from.", s))
    first <- min(ss$d)
    new_end <- first - 1L
    cand <- grid[grid$site == s & !is.na(grid$date_end) & grid$date_end < new_end & !(grid$uuid %in% succ), , drop = FALSE]
    cs <- .mig044_samples(con, cand$uuid)
    cs$de <- cand$date_end[match(cs$uuid_feature, cand$uuid)]
    after <- cs[cs$d > cs$de, , drop = FALSE]
    cand$n_after <- as.integer(table(factor(after$uuid_feature, levels = cand$uuid)))
    cand$last_sample <- as.Date(vapply(cand$uuid, function(u) {
      x <- cs$d[cs$uuid_feature == u]; if (length(x)) as.numeric(max(x)) else NA_real_ }, numeric(1)), origin = "1970-01-01")
    out[[s]] <- list(site = s, successors = grid[grid$uuid %in% succ, , drop = FALSE], first = first, new_end = new_end,
                     extend = cand[cand$n_after > 0L, , drop = FALSE], untouched = cand[cand$n_after == 0L, , drop = FALSE])
  }
  out
}

# Effective live interval of each alias arm per the resolver: alias bounds,
# then the feature's date_end (feature date_start is never read).
.mig044_live_overlaps <- function(fa, feat, keys, win_lo, win_hi) {
  fa <- fa[!is.na(fa$alias_key) & fa$alias_key %in% keys & !is.na(fa$uuid_feature) & .mig044_true(fa$auto_assign), , drop = FALSE]
  if (!nrow(fa)) return(data.frame(key = character(0), f1 = character(0), f2 = character(0), lo = character(0), hi = character(0)))
  lo <- as.Date(fa$date_start); lo[is.na(lo)] <- as.Date("1900-01-01")
  hi <- as.Date(fa$date_end); hi[is.na(hi)] <- as.Date("2999-12-31")
  fde <- as.Date(feat$date_end[match(fa$uuid_feature, feat$uuid)]); fde[is.na(fde)] <- as.Date("2999-12-31")
  hi <- pmin(hi, fde)
  lo <- pmax(lo, win_lo); hi <- pmin(hi, win_hi)
  bad <- list()
  for (k in unique(fa$alias_key)) {
    i <- which(fa$alias_key == k & lo <= hi)
    if (length(i) < 2) next
    for (a in seq_along(i)) for (b in seq_along(i)) {
      if (b <= a) next
      x <- i[[a]]; y <- i[[b]]
      if (fa$uuid_feature[[x]] == fa$uuid_feature[[y]]) next
      ol <- max(lo[[x]], lo[[y]]); oh <- min(hi[[x]], hi[[y]])
      if (ol <= oh) bad[[length(bad) + 1L]] <- data.frame(key = k, f1 = fa$uuid_feature[[x]], f2 = fa$uuid_feature[[y]],
                                                         lo = format(ol), hi = format(oh), stringsAsFactors = FALSE)
    }
  }
  if (length(bad)) do.call(rbind, bad) else
    data.frame(key = character(0), f1 = character(0), f2 = character(0), lo = character(0), hi = character(0))
}
.mig044_true <- function(x) !is.na(x) & as.logical(x)

.mig044_plan <- function(con) {
  m <- .mig044_measure(con)
  feat <- DBI::dbGetQuery(con, "SELECT * FROM feature")
  fa <- DBI::dbGetQuery(con, "SELECT * FROM feature_alias")
  pf <- list(); pa <- list()
  for (s in .mig044_sites) {
    e <- m[[s]]$extend
    if (nrow(e)) pf[[s]] <- data.frame(uuid = e$uuid, name = e$name, site = s, old_end = e$date_end,
                                       new_end = m[[s]]$new_end, n_after = e$n_after, last_sample = e$last_sample,
                                       stringsAsFactors = FALSE)
  }
  pf <- do.call(rbind, pf)
  a <- fa[fa$uuid_feature %in% pf$uuid & !is.na(fa$date_end), , drop = FALSE]
  i <- match(a$uuid_feature, pf$uuid)
  pa <- data.frame(uuid = a$uuid, name = a$name, alias_key = a$alias_key, kind = a$kind, target = pf$name[i],
                   site = pf$site[i], date_start = as.Date(a$date_start), old_end = as.Date(a$date_end),
                   f_old_end = pf$old_end[i], new_end = pf$new_end[i], stringsAsFactors = FALSE)
  list(measure = m, feature = pf, alias = pa, feat = feat, fa = fa)
}

.mig044_problems <- function(con, p) {
  probs <- character(0)
  for (s in .mig044_sites) {
    x <- .mig044_expected[[s]]; m <- p$measure[[s]]
    fs <- p$feature[p$feature$site == s, , drop = FALSE]; as <- p$alias[p$alias$site == s, , drop = FALSE]
    if (m$new_end != x$new_end) probs <- c(probs, sprintf("%s new_end is %s, measured %s", s, m$new_end, x$new_end))
    if (nrow(fs) != x$n_feature) probs <- c(probs, sprintf("%s plan extends %d features, measured %d", s, nrow(fs), x$n_feature))
    if (nrow(as) != x$n_alias) probs <- c(probs, sprintf("%s plan moves %d aliases, measured %d", s, nrow(as), x$n_alias))
    if (nrow(fs) && any(fs$old_end != x$old_end)) probs <- c(probs, sprintf("%s: an extended feature's date_end is not %s", s, x$old_end))
    late <- fs[!is.na(fs$last_sample) & fs$last_sample > m$new_end, , drop = FALSE]
    if (nrow(late)) probs <- c(probs, sprintf("%s: %d old-grid feature(s) sampled after new_end %s (e.g. %s on %s)",
                                              s, nrow(late), m$new_end, late$name[[1]], late$last_sample[[1]]))
  }
  off <- p$alias[p$alias$old_end != p$alias$f_old_end, , drop = FALSE]
  if (nrow(off)) probs <- c(probs, sprintf("%d bounded alias(es) on extended features do not end on the feature's date_end: %s",
                                           nrow(off), paste(off$name, collapse = ", ")))
  # Overlap check on the simulated post-migration registry.
  feat2 <- p$feat; fa2 <- p$fa
  feat2$date_end <- as.Date(feat2$date_end); fa2$date_end <- as.Date(fa2$date_end)
  feat2$date_end[match(p$feature$uuid, feat2$uuid)] <- p$feature$new_end
  fa2$date_end[match(p$alias$uuid, fa2$uuid)] <- p$alias$new_end
  keys <- unique(fa2$alias_key[fa2$uuid_feature %in% p$feature$uuid & !is.na(fa2$alias_key)])
  for (s in .mig044_sites) {
    x <- .mig044_expected[[s]]
    ov <- .mig044_live_overlaps(fa2, feat2, keys, x$old_end + 1L, p$measure[[s]]$new_end)
    if (nrow(ov)) probs <- c(probs, sprintf("OVERLAP in the %s window: %s", s,
      paste(sprintf("%s -> %s & %s (%s..%s)", ov$key, feat2$name[match(ov$f1, feat2$uuid)],
                    feat2$name[match(ov$f2, feat2$uuid)], ov$lo, ov$hi), collapse = "; ")))
  }
  # Structural (site, point) key of each extended feature is its alone.
  idx <- .rc_structural_index(list(feature = feat2))
  for (u in p$feature$uuid) {
    k <- idx$key[idx$uuid_feature == u]
    other <- setdiff(idx$uuid_feature[idx$key %in% k], u)
    if (length(other)) probs <- c(probs, sprintf("structural key %s of %s is shared with %s", paste(k, collapse = ","),
                                                 feat2$name[feat2$uuid == u], paste(feat2$name[match(other, feat2$uuid)], collapse = ",")))
  }
  probs
}

.mig044_check_preconditions <- function(con) {
  if (.mig044_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig044_requires) == 0L)
    .mig044_fail(sprintf("marker %d (043) is required first.", .mig044_requires))
  p <- .mig044_plan(con)
  probs <- .mig044_problems(con, p)
  if (length(probs)) .mig044_fail(sprintf("%s. Nothing written.", paste(probs, collapse = " | ")))
  p
}

# Live samples inside an extension window on a PENDING alias whose name would
# resolve after the migration (report only).
.mig044_pending_report <- function(con, p) {
  s <- DBI::dbGetQuery(con, "SELECT s.uuid, s.date, fa.name FROM sample s JOIN feature_alias fa
    ON fa.uuid = s.uuid_feature_alias WHERE fa.uuid_feature IS NULL")
  s$d <- .mig044_syd(s$date)
  reg <- list(feature = p$feat, feature_alias = p$fa)
  reg$feature$date_end <- as.Date(reg$feature$date_end); reg$feature_alias$date_end <- as.Date(reg$feature_alias$date_end)
  reg$feature$date_end[match(p$feature$uuid, reg$feature$uuid)] <- p$feature$new_end
  reg$feature_alias$date_end[match(p$alias$uuid, reg$feature_alias$uuid)] <- p$alias$new_end
  lo <- min(vapply(.mig044_sites, function(x) as.numeric(.mig044_expected[[x]]$old_end + 1L), numeric(1)))
  hi <- max(vapply(.mig044_sites, function(x) as.numeric(p$measure[[x]]$new_end), numeric(1)))
  w <- s[as.numeric(s$d) >= lo & as.numeric(s$d) <= hi, , drop = FALSE]
  n_res <- 0L
  for (i in seq_len(nrow(w))) {
    c1 <- .rc_feature_candidates(w$name[[i]], w$d[[i]], reg)
    if (nrow(c1) && any(c1$uuid_feature %in% p$feature$uuid)) n_res <- n_res + 1L
  }
  list(n_pending_total = nrow(s), n_in_window = nrow(w), n_would_resolve = n_res)
}

.mig044_checksum <- function(con, fu, au) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  touched <- c("feature", "feature_alias", "change_log", "schema_version")
  out <- lapply(setdiff(tabs, touched), function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- setdiff(tabs, touched)
  f <- .mig044_inlist(fu); a <- .mig044_inlist(au)
  out$feature_rest <- q(sprintf("SELECT * FROM feature WHERE uuid NOT IN %s ORDER BY uuid", f))
  out$feature_fixed <- q(sprintf("SELECT * EXCLUDE (date_end) FROM feature WHERE uuid IN %s ORDER BY uuid", f))
  out$alias_rest <- q(sprintf("SELECT * FROM feature_alias WHERE uuid NOT IN %s ORDER BY uuid", a))
  out$alias_fixed <- q(sprintf("SELECT * EXCLUDE (date_end) FROM feature_alias WHERE uuid IN %s ORDER BY uuid", a))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig044_actor))
  out$schema_version_rest <- q(sprintf("SELECT * FROM schema_version WHERE version <> %d ORDER BY ALL", .mig044_marker_version))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig044_done_problem <- function(con) {
  if (.mig044_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig044_marker_version) != 1L)
    return("marker 1044 missing")
  cl <- DBI::dbGetQuery(con, "SELECT tbl, action, field, uuid_row, old, new FROM change_log WHERE actor = ?",
                        params = list(.mig044_actor))
  nf <- sum(vapply(.mig044_expected, `[[`, integer(1), "n_feature"))
  na <- sum(vapply(.mig044_expected, `[[`, integer(1), "n_alias"))
  if (nrow(cl) != nf + na || any(cl$action != "update") || any(cl$field != "date_end") || anyDuplicated(cl$uuid_row) ||
      sum(cl$tbl == "feature") != nf || sum(cl$tbl == "feature_alias") != na)
    return(sprintf("044 change_log is %d row(s), expected %d feature + %d feature_alias date_end updates", nrow(cl), nf, na))
  feat <- DBI::dbGetQuery(con, sprintf("SELECT uuid, name, site, date_end FROM feature WHERE uuid IN %s",
                                       .mig044_inlist(cl$uuid_row[cl$tbl == "feature"])))
  fa <- DBI::dbGetQuery(con, sprintf("SELECT fa.uuid, fa.name, fa.date_end, f.site, f.name AS target, f.date_end AS f_date_end
    FROM feature_alias fa JOIN feature f ON f.uuid = fa.uuid_feature WHERE fa.uuid IN %s",
    .mig044_inlist(cl$uuid_row[cl$tbl == "feature_alias"])))
  if (nrow(feat) != nf || nrow(fa) != na) return("a logged 044 row no longer exists")
  for (s in .mig044_sites) {
    x <- .mig044_expected[[s]]
    fs <- feat[feat$site == s, , drop = FALSE]; as <- fa[fa$site == s, , drop = FALSE]
    if (nrow(fs) != x$n_feature || nrow(as) != x$n_alias) return(sprintf("%s: wrong number of 044 rows", s))
    if (any(as.Date(fs$date_end) != x$new_end) || any(as.Date(as$date_end) != x$new_end))
      return(sprintf("%s: a 044 row's date_end is not %s", s, x$new_end))
    clf <- cl[cl$uuid_row %in% c(fs$uuid, as$uuid), , drop = FALSE]
    if (any(clf$old != format(x$old_end)) || any(clf$new != format(x$new_end)))
      return(sprintf("%s: a 044 change_log row is not %s -> %s", s, x$old_end, x$new_end))
  }
  # The successor's first sample still sits the day after new_end.
  m <- .mig044_measure(con)
  for (s in .mig044_sites) if (m[[s]]$new_end != .mig044_expected[[s]]$new_end)
    return(sprintf("%s successor first sample moved: new_end now derives to %s", s, m[[s]]$new_end))
  # K.G0x and every other old-grid candidate stayed as they were.
  if (nrow(m$B$extend) || nrow(m$K$extend)) return("old-grid features with post-end samples remain")
  # Resolution through the real candidate path: each moved feature by its own
  # name and each moved alias, live on new_end and NOT on the day after.
  reg <- .rc_load_registry(con)
  probe <- rbind(data.frame(raw = feat$name, target = feat$uuid, site = feat$site, stringsAsFactors = FALSE),
                 data.frame(raw = fa$name, target = feat$uuid[match(fa$target, feat$name)], site = fa$site, stringsAsFactors = FALSE))
  for (i in seq_len(nrow(probe))) {
    ne <- .mig044_expected[[probe$site[[i]]]]$new_end
    c1 <- .rc_feature_candidates(probe$raw[[i]], ne, reg)
    if (nrow(c1) != 1L || c1$uuid_feature != probe$target[[i]])
      return(sprintf("%s does not resolve uniquely to its feature on %s", probe$raw[[i]], ne))
    if (nrow(.rc_feature_candidates(probe$raw[[i]], ne + 1L, reg)))
      return(sprintf("%s still resolves on %s, the day after the new end", probe$raw[[i]], ne + 1L))
  }
  # The named spot checks.
  g001 <- feat$uuid[feat$name == "B.G001"]
  for (raw in c("B.G001", "B.G1", "B.G01")) {
    c1 <- .rc_feature_candidates(raw, as.Date("2024-01-22"), reg)
    if (nrow(c1) != 1L || c1$uuid_feature != g001) return(sprintf("%s does not resolve to B.G001 on 2024-01-22", raw))
    if (nrow(.rc_feature_candidates(raw, as.Date("2024-02-19"), reg))) return(sprintf("%s resolves on 2024-02-19", raw))
  }
  k026 <- feat$uuid[feat$name == "K.G026"]
  for (raw in c("K.G026", "K.G26")) {
    c1 <- .rc_feature_candidates(raw, as.Date("2023-12-19"), reg)
    if (nrow(c1) != 1L || c1$uuid_feature != k026) return(sprintf("%s does not resolve to K.G026 on 2023-12-19", raw))
    if (nrow(.rc_feature_candidates(raw, as.Date("2024-03-04"), reg))) return(sprintf("%s resolves on 2024-03-04", raw))
  }
  # No key reaches two live auto arms of distinct features in either window.
  ff <- reg$feature; ffa <- reg$feature_alias
  keys <- unique(ffa$alias_key[ffa$uuid_feature %in% feat$uuid & !is.na(ffa$alias_key)])
  for (s in .mig044_sites) {
    x <- .mig044_expected[[s]]
    ov <- .mig044_live_overlaps(ffa, ff, keys, x$old_end + 1L, x$new_end)
    if (nrow(ov)) return(sprintf("%d overlapping live alias pair(s) in the %s window", nrow(ov), s))
  }
  NULL
}

.mig044_verify <- function(con) {
  p <- .mig044_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("044 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig044_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- if (is.null(.now)) Sys.time() else .now
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig044_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig044_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig044_counts(verify_con)))
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  dest
}

.mig044_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], c("POSIXct", "Date"))) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, as.character(out$uuid)))
    cli::cli_abort("044: CSV {basename(path)} did not round-trip.", class = "sampletidy_error")
}

.mig044_apply <- function(con, p, recorded_at) {
  fu <- p$feature$uuid; au <- p$alias$uuid
  sums_before <- .mig044_checksum(con, fu, au)
  want <- .mig044_counts(con)
  want$change_log <- want$change_log + length(fu) + length(au)
  want$schema_version <- want$schema_version + 1L
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(p$feature))) {
      r <- p$feature[i, ]
      db_update(con, "feature", uuid = r$uuid, changes = list(date_end = as.Date(r$new_end)),
                actor = .mig044_actor, reason = .mig044_reason(r$site, r$old_end, r$new_end))
    }
    for (i in seq_len(nrow(p$alias))) {
      r <- p$alias[i, ]
      db_update(con, "feature_alias", uuid = r$uuid, changes = list(date_end = as.Date(r$new_end)),
                actor = .mig044_actor, reason = paste0(.mig044_reason(r$site, r$old_end, r$new_end),
                                                       sprintf("; alias %s -> %s follows its feature", r$name, r$target)))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig044_marker_version, recorded_at))
    .mig044_verify(con)
    got <- .mig044_counts(con)
    if (!identical(got, want))
      .mig044_fail(sprintf("counts are not before + %d change_log, + 1 marker: %s", length(fu) + length(au),
                           paste(names(got), unlist(got), unlist(want), sep = ":", collapse = ", ")))
    if (!identical(sums_before, .mig044_checksum(con, fu, au))) .mig044_fail("something outside the planned rows/column moved.")
    NULL
  })
  invisible(NULL)
}

mig044_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig044_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig044_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("044 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  res <- tryCatch({
    p <- .mig044_check_preconditions(pre_con)
    list(p = p, pend = .mig044_pending_report(pre_con, p))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  p <- res$p
  for (s in .mig044_sites) {
    m <- p$measure[[s]]; fs <- p$feature[p$feature$site == s, , drop = FALSE]
    logf("%s: successor grid %d features (%s..%s), first sampled %s -> new_end %s.", s, nrow(m$successors),
         min(m$successors$name), max(m$successors$name), m$first, m$new_end)
    logf("%s: extend %d features (%s..%s) %s -> %s; post-end samples %d..%d per feature, last %s; %d aliases follow.",
         s, nrow(fs), min(fs$name), max(fs$name), fs$old_end[[1]], m$new_end, min(fs$n_after), max(fs$n_after),
         max(fs$last_sample), sum(p$alias$site == s))
    if (nrow(m$untouched))
      logf("%s: NOT extended (no sample after their date_end): %d features %s..%s, date_end %s.", s, nrow(m$untouched),
           min(m$untouched$name), max(m$untouched$name), paste(unique(format(m$untouched$date_end)), collapse = ","))
  }
  logf("No overlap, no structural collision. Pending samples: %d total, %d inside the windows, %d would now resolve (report only).",
       res$pend$n_pending_total, res$pend$n_in_window, res$pend$n_would_resolve)
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_, restore_command = NA_character_,
                          recorded_at = NA, plan = p[c("feature", "alias")], pending = res$pend)))
  }

  bk_con <- st_connect(db, read_only = TRUE)
  tryCatch({
    .mig044_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM feature WHERE uuid IN %s ORDER BY name",
                                                      .mig044_inlist(p$feature$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-feature.csv", .mig044_name)))
    .mig044_write_csv(DBI::dbGetQuery(bk_con, sprintf("SELECT * FROM feature_alias WHERE uuid IN %s ORDER BY name",
                                                      .mig044_inlist(p$alias$uuid))),
                      file.path(csv_dir, sprintf("%s-BACKUP-feature_alias.csv", .mig044_name)))
  }, finally = DBI::dbDisconnect(bk_con, shutdown = TRUE))
  logf("Row backups written to %s", csv_dir)
  backup_path <- mig044_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- if (is.null(.now)) Sys.time() else .now

  with_db_write(function(con) {
    p <- .mig044_check_preconditions(con)   # re-read under the write lock
    .mig044_apply(con, p, recorded_at)
  }, db = db)

  logf("%s migrated successfully (marker %d): %d features, %d aliases.", .mig044_name, .mig044_marker_version,
       nrow(p$feature), nrow(p$alias))
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
