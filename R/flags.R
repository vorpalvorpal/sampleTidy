# Auto-import phase 2: the deterministic checks behind the status note's Flags
# section (dev/plans/PLAN-18-auto-import.md section 4, contract in 4.5).
#
# Read-only on the DB: one read-only connection pulls the sample/result image
# into R (the live DB is ~20k samples, ~100k results), and every check works on
# that image. Each check runs in its own tryCatch - a failure becomes an entry
# of attr(result, "errors"), never a crash of the note. The package never reads
# dev/; the caller passes the schedule and licence tables.

.flags_checks <- c("overdue", "invoiced_not_received", "missing_point",
                   "missing_analytes", "licence_limit", "gas_criterion",
                   "site_history", "rl_change", "unit_change")

.flags_cols <- c("check", "site", "feature", "analyte", "date", "value", "unit",
                 "threshold", "detail", "key")

.flags_streams <- c("acirl_water", "acirl_gas", "acirl_dust", "als_lab")

.flags_meanings <- c(
  overdue = "a scheduled delivery has not arrived by its due date",
  invoiced_not_received = "sampling was invoiced but no matching delivery arrived",
  missing_point = "scheduled points have no sample in a recent round",
  missing_analytes = "required pollutants are missing from a recent round",
  licence_limit = "a result is outside an EPA licence limit",
  gas_criterion = "a gas or dust result is above an LEL or EPA criterion",
  site_history = "a result is far outside the point's own history",
  rl_change = "the reporting limit rose above its 2-year maximum",
  unit_change = "the reporting unit changed since the last result"
)

# ---- small helpers ------------------------------------------------------------

.flags_empty <- function() {
  data.frame(check = character(), site = character(), feature = character(),
             analyte = character(), date = character(), value = numeric(),
             unit = character(), threshold = character(), detail = character(),
             key = character(), stringsAsFactors = FALSE)
}

# One check's rows; `date` is a Date (formatted at the end, after sorting).
.flags_rows <- function(check, key, site, date, feature = NA, analyte = NA,
                        value = NA, unit = NA, threshold = NA, detail = NA) {
  n <- length(key)
  if (n == 0) return(NULL)
  ch <- function(x) rep_len(as.character(x), n)
  data.frame(check = rep(check, n), site = ch(site), feature = ch(feature),
             analyte = ch(analyte), date = rep_len(as.Date(date), n),
             value = rep_len(as.numeric(value), n), unit = ch(unit),
             threshold = ch(threshold), detail = ch(detail), key = ch(key),
             stringsAsFactors = FALSE)
}

.flags_fmt <- function(x) trimws(formatC(x, digits = 6, format = "fg"))

.flags_syd_date <- function(t) as.Date(format(t, "%Y-%m-%d", tz = .inbox_tz))

# Months as an integer index (year * 12 + month - 1), so month arithmetic is
# plain integer arithmetic.
.flags_ym <- function(d) {
  lt <- as.POSIXlt(d)
  (lt$year + 1900L) * 12L + lt$mon
}
.flags_ym_start <- function(i) as.Date(sprintf("%04d-%02d-01", i %/% 12L, i %% 12L + 1L))
.flags_ym_end <- function(i) .flags_ym_start(i + 1L) - 1
.flags_ym_label <- function(i) paste(month.abb[i %% 12L + 1L], i %/% 12L)

.flags_years_back <- function(d, n) {
  lt <- as.POSIXlt(d)
  lt$year <- lt$year - n
  as.Date(lt)
}

.flags_same_num <- function(a, b) abs(a - b) <= 1e-9 * pmax(abs(a), abs(b), 1e-12)

# Keep the first row of each key (callers order the rows first).
.flags_dedupe <- function(d) if (is.null(d)) d else d[!duplicated(d$key), , drop = FALSE]

# ---- check inputs -------------------------------------------------------------

# A CSV path or a data.frame -> data.frame of the named character columns,
# trimmed, with "" and NA both NA.
.flags_table <- function(x, what, cols) {
  if (is.data.frame(x)) {
    d <- x
  } else if (is.character(x) && length(x) == 1 && !is.na(x)) {
    if (!file.exists(x)) stop(what, " file not found: ", x, call. = FALSE)
    d <- utils::read.csv(x, colClasses = "character", na.strings = "",
                         strip.white = TRUE, check.names = FALSE)
  } else {
    stop(what, " must be a CSV path or a data.frame", call. = FALSE)
  }
  miss <- setdiff(cols, names(d))
  if (length(miss)) {
    stop(what, " lacks column(s): ", paste(miss, collapse = ", "), call. = FALSE)
  }
  out <- d[, cols, drop = FALSE]
  for (cl in cols) {
    v <- trimws(as.character(out[[cl]]))
    v[!is.na(v) & !nzchar(v)] <- NA
    out[[cl]] <- v
  }
  rownames(out) <- NULL
  out
}

.flags_iso_date <- function(x, what) {
  ok <- is.na(x) | grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", x)
  d <- as.Date(ifelse(ok, x, NA_character_), "%Y-%m-%d")
  if (any(!ok | (!is.na(x) & is.na(d)))) {
    stop(what, " is not a YYYY-MM-DD date: ",
         paste(unique(x[!ok | (!is.na(x) & is.na(d))]), collapse = ", "), call. = FALSE)
  }
  d
}

# expected_schedule -> a list of rows (site, stream, months, features,
# due_days, from, to, source). Malformed -> an error (of the calling check).
.flags_schedule <- function(x) {
  s <- .flags_table(x, "schedule", c("site", "stream", "months", "features",
                                     "due_days", "from", "to", "source"))
  if (anyNA(s$site)) stop("schedule: a row has no site", call. = FALSE)
  bad <- is.na(s$stream) | !s$stream %in% .flags_streams
  if (any(bad)) {
    stop("schedule: unknown stream(s): ", paste(unique(s$stream[bad]), collapse = ", "),
         call. = FALSE)
  }
  months <- lapply(s$months, function(m) {
    if (!is.na(m) && tolower(m) == "all") return(1:12)
    p <- if (is.na(m)) character(0) else trimws(strsplit(m, ";", fixed = TRUE)[[1]])
    p <- p[nzchar(p)]
    n <- suppressWarnings(as.integer(p))
    if (length(p) == 0 || !all(grepl("^[0-9]+$", p)) || any(n < 1 | n > 12)) {
      stop("schedule: months must be 'all' or a ;-list of 1-12, not '", m, "'",
           call. = FALSE)
    }
    n
  })
  dd <- ifelse(is.na(s$due_days), "30", s$due_days)
  if (!all(grepl("^[0-9]+$", dd))) {
    stop("schedule: due_days must be a whole number of days", call. = FALSE)
  }
  from <- .flags_iso_date(s$from, "schedule from")
  if (anyNA(from)) stop("schedule: a row has no `from` date", call. = FALSE)
  to <- .flags_iso_date(s$to, "schedule to")
  lapply(seq_len(nrow(s)), function(i) {
    f <- if (is.na(s$features[[i]])) character(0) else
      trimws(strsplit(s$features[[i]], ";", fixed = TRUE)[[1]])
    list(site = s$site[[i]], stream = s$stream[[i]], months = months[[i]],
         features = f[nzchar(f)], due_days = as.integer(dd[[i]]),
         from = from[[i]], to = to[[i]], source = s$source[[i]])
  })
}

# A schedule row is valid in month index m when it overlaps the month.
.flags_valid_in <- function(r, m) {
  r$from <= .flags_ym_end(m) && (is.na(r$to) || r$to >= .flags_ym_start(m))
}

# ---- the DB image ----------------------------------------------------------------

# Migration actors in change_log (ruling R1): never a delivery.
.flags_migration_actor <- "^[0-9]{3}-|migration-"

# Samples and results with everything the checks need, dated by the Sydney
# calendar day of COALESCE(datetime, date) (the LOCAL_DATE rule).
.flags_load <- function(con, now) {
  s <- DBI::dbGetQuery(con, "
    SELECT s.uuid AS sample, s.uuid_project AS project_uuid, p.name AS project,
           p.type AS ptype, f.name AS feature, f.site AS site, f.matrix AS matrix,
           COALESCE(s.datetime, s.date) AS ts
      FROM \"sample\" s
      LEFT JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
      LEFT JOIN feature f ON f.uuid = fa.uuid_feature
      LEFT JOIN project p ON p.uuid = s.uuid_project")
  a <- DBI::dbGetQuery(con, "
    SELECT a.uuid AS analysis, a.uuid_sample AS sample, lm.uuid_analyte AS uuid_analyte,
           an.name AS analyte, a.value AS value, a.quantified AS quantified,
           a.rl_low AS rl_low, lm.organisation AS lorg, lm.method AS method,
           COALESCE(lm.units, an.units) AS units, an.units AS analyte_units
      FROM analysis a
      JOIN lab_method lm ON lm.uuid = a.uuid_lab
      JOIN analyte an ON an.uuid = lm.uuid_analyte")
  cl <- if (DBI::dbExistsTable(con, "change_log")) DBI::dbGetQuery(con, "
    SELECT tbl, uuid_row, \"at\" AS at, actor, source_hash FROM change_log
     WHERE action = 'insert' AND tbl IN ('sample', 'analysis')") else
    data.frame(tbl = character(), uuid_row = character(), at = numeric(),
               actor = character(), source_hash = character())

  today <- .flags_syd_date(now)
  s$date <- .flags_syd_date(s$ts)
  s$ym <- .flags_ym(s$date)

  # Field vs lab per result, from the lab method alone (ruling R2).
  lorg <- toupper(a$lorg)
  a$field <- lorg %in% "ACIRL" | grepl("Client Supplied", a$method, fixed = TRUE)
  a$kind <- ifelse(a$field, "field", ifelse(lorg %in% "ALS", "lab", NA_character_))

  # Streams: dust and gas by project/feature; otherwise every stream the
  # sample's results evidence (field -> acirl_water, lab -> als_lab). Kept as a
  # long (sample, stream) table, since one sample may count for both.
  dust <- s$ptype %in% "Dust monitoring" | grepl("\\.D[0-9]", s$feature)
  gas <- !dust & (s$ptype %in% "Monthly gas monitoring" | s$matrix %in% "air")
  s$gas <- gas
  ev <- unique(data.frame(sample = a$sample, stream = ifelse(a$kind %in% "field", "acirl_water",
                            ifelse(a$kind %in% "lab", "als_lab", NA_character_)),
                          stringsAsFactors = FALSE))
  ev <- ev[!is.na(ev$stream) & !ev$sample %in% s$sample[dust | gas], , drop = FALSE]
  ss <- rbind(data.frame(sample = s$sample[dust], stream = rep("acirl_dust", sum(dust)),
                         stringsAsFactors = FALSE),
              data.frame(sample = s$sample[gas], stream = rep("acirl_gas", sum(gas)),
                         stringsAsFactors = FALSE),
              ev)

  # Recent delivery (ruling R1): a work order with a pipeline insert (source
  # hash, not a migration actor) in the last 90 days; of it, only samples dated
  # in the last 180 days are assessed ("new").
  cl <- cl[as.numeric(cl$at) >= as.numeric(now) - 90 * 86400 & !is.na(cl$source_hash) &
             !grepl(.flags_migration_actor, cl$actor), , drop = FALSE]
  recent_s <- unique(c(cl$uuid_row[cl$tbl == "sample"],
                       a$sample[a$analysis %in% cl$uuid_row[cl$tbl == "analysis"]]))
  recent_p <- unique(stats::na.omit(s$project_uuid[s$sample %in% recent_s]))
  s$new <- !is.na(s$project_uuid) & s$project_uuid %in% recent_p &
    !is.na(s$date) & s$date >= today - 180

  i <- match(ss$sample, s$sample)
  for (cl_name in c("feature", "site", "date", "ym", "new", "project", "project_uuid")) {
    ss[[cl_name]] <- s[[cl_name]][i]
  }
  ss <- ss[!is.na(ss$site) & !is.na(ss$date), , drop = FALSE]

  i <- match(a$sample, s$sample)
  for (cl_name in c("feature", "site", "matrix", "date", "ym", "gas", "new", "project",
                    "project_uuid")) {
    a[[cl_name]] <- s[[cl_name]][i]
  }
  a$quantified <- a$quantified %in% TRUE
  a <- a[!is.na(a$feature) & !is.na(a$date), , drop = FALSE]
  list(con = con, samples = s, streams = ss, results = a)
}

# ---- 4.1 overdue / invoiced, not received -----------------------------------------

.flags_overdue <- function(img, checks, today) {
  if (is.null(checks$schedule)) return(NULL)
  rows <- .flags_schedule(checks$schedule)
  ss <- img$streams
  have <- unique(paste(ss$site, ss$stream, ss$ym))
  ti <- .flags_ym(today)
  out <- list()
  for (r in rows) {
    for (m in (ti - 12L):(ti - 1L)) {
      if (!(m %% 12L + 1L) %in% r$months || !.flags_valid_in(r, m)) next
      due <- .flags_ym_end(m) + r$due_days
      if (!(due < today) || paste(r$site, r$stream, m) %in% have) next
      out[[length(out) + 1]] <- .flags_rows(
        "overdue", key = sprintf("overdue|%s|%s|%s", r$site, r$stream,
                                 format(.flags_ym_start(m), "%Y-%m")),
        site = r$site, date = .flags_ym_start(m),
        threshold = sprintf("expected %s by %s", .flags_ym_label(m), format(due)),
        detail = sprintf("no %s sample dated in %s%s", r$stream, .flags_ym_label(m),
                         if (is.na(r$source)) "" else paste0(" (schedule: ", r$source, ")")))
    }
  }
  .flags_dedupe(do.call(rbind, out))
}

.flags_invoiced <- function(img, checks, today) {
  inv <- checks$invoices
  if (is.null(inv) || is.null(checks$schedule)) return(NULL)
  if (!is.data.frame(inv) || !all(c("site", "stream", "sampled_on", "ref") %in% names(inv))) {
    stop("invoices must be a data.frame(site, stream, sampled_on, ref)", call. = FALSE)
  }
  rows <- .flags_schedule(checks$schedule)
  ss <- img$streams
  d_all <- as.Date(inv$sampled_on)
  out <- list()
  for (i in seq_len(nrow(inv))) {
    site <- as.character(inv$site[[i]])
    stream <- as.character(inv$stream[[i]])
    d <- d_all[[i]]
    if (is.na(d)) next
    dd <- 30L
    for (r in rows) {
      if (r$site == site && r$stream == stream && r$from <= d && (is.na(r$to) || r$to >= d)) {
        dd <- r$due_days
        break
      }
    }
    due <- d + dd
    if (!(due < today)) next
    near <- ss$site %in% site & ss$stream %in% stream & abs(as.numeric(ss$date - d)) <= 3
    if (any(near)) next
    ref <- as.character(inv$ref[[i]])
    out[[length(out) + 1]] <- .flags_rows(
      "invoiced_not_received",
      key = sprintf("invoiced_not_received|%s|%s|%s|%s", site, stream, format(d), ref),
      site = site, date = d, threshold = sprintf("expected by %s", format(due)),
      detail = sprintf("invoice %s lists %s sampling; no %s sample within 3 days",
                       ref, stream, stream))
  }
  .flags_dedupe(do.call(rbind, out))
}

# ---- 4.2 incomplete deliveries -------------------------------------------------------

# "a, b, c, +m more" after the first n.
.flags_first_n <- function(x, n) {
  if (length(x) <= n) return(paste(x, collapse = ", "))
  paste0(paste(x[seq_len(n)], collapse = ", "), ", +", length(x) - n, " more")
}

.flags_missing_point <- function(img, checks, today) {
  if (is.null(checks$schedule)) return(NULL)
  rows <- .flags_schedule(checks$schedule)
  s <- img$samples[!is.na(img$samples$site) & !is.na(img$samples$date), , drop = FALSE]
  sampled <- unique(paste(s$site, s$ym, s$feature))
  ns <- img$streams[img$streams$new, , drop = FALSE]
  # One flag per (site, round month, stream) of the recent deliveries' samples.
  rounds <- unique(ns[, c("site", "ym", "stream")])
  out <- list()
  for (k in seq_len(nrow(rounds))) {
    site <- rounds$site[[k]]
    m <- rounds$ym[[k]]
    stream <- rounds$stream[[k]]
    exp <- unique(unlist(lapply(rows, function(r) {
      if (r$site == site && r$stream == stream && (m %% 12L + 1L) %in% r$months &&
          .flags_valid_in(r, m)) r$features
    })))
    if (length(exp) == 0) next
    exp <- sort(exp, method = "radix")
    # Gas rounds straddle month ends: a neighbouring month's sample counts.
    months <- if (stream == "acirl_gas") (m - 1L):(m + 1L) else m
    hit <- Reduce(`|`, lapply(months, function(mm) paste(site, mm, exp) %in% sampled))
    miss <- exp[!hit]
    if (length(miss) == 0) next
    rs <- ns[ns$site == site & ns$ym == m & ns$stream == stream, , drop = FALSE]
    out[[length(out) + 1]] <- .flags_rows(
      "missing_point",
      key = sprintf("missing_point|%s|%s|%s", site, format(.flags_ym_start(m), "%Y-%m"), stream),
      site = site, date = min(rs$date),
      threshold = sprintf("%s schedule, %s", stream, .flags_ym_label(m)),
      detail = sprintf("%s: %d of %d expected points not sampled: %s; work order(s) %s",
                       stream, length(miss), length(exp), .flags_first_n(miss, 10),
                       paste(sort(unique(rs$project)), collapse = ", ")))
  }
  do.call(rbind, out)
}

.flags_missing_analytes <- function(img, checks, today) {
  if (is.null(checks$requirements) || is.null(checks$points)) return(NULL)
  req <- .flags_table(checks$requirements, "requirements",
                      c("site", "epa_point", "pollutant", "frequency"))
  pts <- .flags_table(checks$points, "points", c("site", "epa_point", "role"))
  weather <- paste(pts$site, pts$epa_point)[pts$role %in% "weather"]
  # Matched by `pollutant` (group line items are already expanded into one row
  # per congener, as dev/epa-monitoring-report.R reads them); a (point,
  # pollutant) under two conditions is one requirement.
  req <- req[req$frequency %in% c("Monthly", "Quarterly", "Yearly") &
               !paste(req$site, req$epa_point) %in% weather &
               !is.na(req$pollutant), , drop = FALSE]
  if (nrow(req) == 0) return(NULL)

  # EPA point -> features, pollutant -> analytes (as dev/epa-monitoring-report.R).
  fmap <- DBI::dbGetQuery(img$con, "
    SELECT f.name AS feature, f.site AS site, trim(fm.name) AS epa_point
      FROM feature_mask fm JOIN feature f ON f.uuid = fm.uuid_feature
     WHERE fm.variant = 'EPA' AND fm.name IS NOT NULL AND trim(fm.name) <> ''")
  amap <- DBI::dbGetQuery(img$con, "
    SELECT uuid_analyte, trim(name) AS pollutant FROM analyte_mask
     WHERE variant = 'EPA' AND name IS NOT NULL AND trim(name) <> ''")

  a <- img$results
  ns <- img$samples[img$samples$new & img$samples$feature %in% fmap$feature, , drop = FALSE]
  if (nrow(ns) == 0) return(NULL)
  # d = the feature's latest sample date in a delivery; one assessment per
  # (feature, month of d), at the latest such d.
  ns <- ns[order(-as.numeric(ns$date)), , drop = FALSE]
  cand <- ns[!duplicated(paste(ns$feature, ns$project_uuid)), , drop = FALSE]
  cand <- cand[!duplicated(paste(cand$feature, cand$ym)), , drop = FALSE]

  # Per (site, month): pollutant -> labelled features; the latest d; work orders.
  acc <- list()
  for (k in seq_len(nrow(cand))) {
    f <- cand$feature[[k]]
    site <- cand$site[[k]]
    d <- cand$date[[k]]
    m <- cand$ym[[k]]
    points <- fmap$epa_point[fmap$feature == f & fmap$site %in% site]
    r <- req[req$site %in% site & req$epa_point %in% points, , drop = FALSE]
    if (nrow(r) == 0) next
    r <- r[!duplicated(paste(r$pollutant, r$frequency)), , drop = FALSE]
    af <- a[a$feature == f, , drop = FALSE]
    eom <- .flags_ym_end(m)
    present <- vapply(seq_len(nrow(r)), function(j) {
      lo <- switch(r$frequency[[j]], Monthly = .flags_ym_start(m),
                   Quarterly = d - 120, Yearly = d - 395)
      any(af$uuid_analyte %in% amap$uuid_analyte[amap$pollutant == r$pollutant[[j]]] &
            af$date >= lo & af$date <= eom)
    }, logical(1))
    # A pollutant listed at two frequencies is present if any window holds it.
    ok <- tapply(present, r$pollutant, any)
    miss <- names(ok)[!ok]
    if (length(miss) == 0) next
    kinds_site <- unique(stats::na.omit(a$kind[a$site %in% site & a$ym == m]))
    kinds_f <- unique(stats::na.omit(af$kind[af$ym == m]))
    label <- if (length(kinds_site) == 2 && length(kinds_f) == 1) {
      paste0(f, " (", kinds_f, " only)")
    } else f
    key <- sprintf("missing_analytes|%s|%s", site, format(.flags_ym_start(m), "%Y-%m"))
    x <- acc[[key]]
    if (is.null(x)) x <- list(site = site, m = m, date = d, by = list(), wos = character(0))
    x$date <- max(x$date, d)
    x$wos <- union(x$wos, ns$project[ns$feature == f & ns$ym == m])
    for (p in miss) x$by[[p]] <- c(x$by[[p]], label)
    acc[[key]] <- x
  }
  if (length(acc) == 0) return(NULL)
  do.call(rbind, lapply(names(acc), function(key) {
    x <- acc[[key]]
    pols <- sort(names(x$by), method = "radix")
    ent <- vapply(pols, function(p) {
      paste0(p, ": ", paste(sort(unique(x$by[[p]]), method = "radix"), collapse = ", "))
    }, character(1))
    shown <- if (length(ent) > 15) c(ent[1:15], sprintf("+%d more", length(ent) - 15)) else ent
    .flags_rows("missing_analytes", key = key, site = x$site, date = x$date,
                threshold = sprintf("licence requirements, %s", .flags_ym_label(x$m)),
                detail = sprintf("%s (work order(s) %s)", paste(shown, collapse = "; "),
                                 paste(sort(x$wos), collapse = ", ")))
  }))
}

# ---- 4.3 exceedances ----------------------------------------------------------------

.flags_new_quantified <- function(img) {
  a <- img$results
  a[a$new & a$quantified & !is.na(a$value), , drop = FALSE]
}

.flags_licence_limit <- function(img, checks, today) {
  if (is.null(checks$limits)) return(NULL)
  lim <- .flags_table(checks$limits, "limits", c("site", "feature_pattern", "analyte", "min",
                                                 "max", "unit", "factor", "condition", "note"))
  num <- function(x, what) {
    v <- suppressWarnings(as.numeric(x))
    if (any(!is.na(x) & is.na(v))) stop("limits: ", what, " is not a number", call. = FALSE)
    v
  }
  mn <- num(lim$min, "min")
  mx <- num(lim$max, "max")
  fac <- num(lim$factor, "factor")
  fac[is.na(fac)] <- 1
  if (any(is.na(mn) & is.na(mx))) stop("limits: a row has neither min nor max", call. = FALSE)
  if (anyNA(lim$site) || anyNA(lim$feature_pattern) || anyNA(lim$analyte)) {
    stop("limits: site, feature_pattern and analyte are required", call. = FALSE)
  }
  a <- .flags_new_quantified(img)
  out <- list()
  for (i in seq_len(nrow(lim))) {
    x <- a[a$site %in% lim$site[[i]] & a$analyte %in% lim$analyte[[i]] &
             grepl(lim$feature_pattern[[i]], a$feature), , drop = FALSE]
    if (nrow(x) == 0) next
    # Field wins where a (feature, day) has both a field and a lab result.
    g <- paste(x$feature, x$date)
    x <- x[x$field | !g %in% g[x$field], , drop = FALSE]
    v <- signif(x$value * fac[[i]], 12)
    lo <- !is.na(mn[[i]]) & v < mn[[i]]
    hi <- !is.na(mx[[i]]) & v > mx[[i]]
    b <- lo | hi
    if (!any(b)) next
    x <- x[b, , drop = FALSE]
    v <- v[b]
    excess <- ifelse(v > .flags_or_inf(mx[[i]]), v - mx[[i]], mn[[i]] - v)
    o <- order(-excess)
    x <- x[o, , drop = FALSE]
    v <- v[o]
    u <- lim$unit[[i]]
    thr <- if (!is.na(mn[[i]]) && !is.na(mx[[i]])) {
      sprintf("outside %s-%s %s", lim$min[[i]], lim$max[[i]], u)
    } else if (!is.na(mx[[i]])) sprintf("> %s %s", lim$max[[i]], u) else
      sprintf("< %s %s", lim$min[[i]], u)
    cond <- lim$condition[[i]]
    kind <- ifelse(x$field, "field", "lab")
    out[[length(out) + 1]] <- .flags_rows(
      "licence_limit",
      key = sprintf("licence_limit|%s|%s|%s|%s", x$feature, x$analyte, format(x$date), kind),
      site = x$site, date = x$date, feature = x$feature, analyte = x$analyte, value = v,
      unit = u, threshold = thr,
      detail = paste0(if (is.na(cond)) "licence limit" else cond, "; ", kind, " result, ",
                      x$project,
                      if (!is.na(cond) && grepl("^L2", cond)) "; storm exemption (L2.5) not assessed" else ""))
  }
  .flags_dedupe(do.call(rbind, out))
}

.flags_or_inf <- function(x) if (is.na(x)) Inf else x

.flags_gas_criterion <- function(img, checks, today) {
  gl <- DBI::dbGetQuery(img$con, "
    SELECT uuid_analyte, guideline AS family, level, level_name, value AS gv
      FROM guideline WHERE guideline IN ('LEL', 'EPA') AND value IS NOT NULL")
  a <- .flags_new_quantified(img)
  a <- a[a$matrix %in% "air" | a$gas, , drop = FALSE]
  if (nrow(gl) == 0 || nrow(a) == 0) return(NULL)
  x <- merge(a, gl, by = "uuid_analyte")
  x <- x[x$value > x$gv, , drop = FALSE]
  if (nrow(x) == 0) return(NULL)
  # Highest level exceeded per result and family, then the highest result per key.
  x <- x[order(x$analysis, x$family, -x$level, -x$gv), , drop = FALSE]
  x <- x[!duplicated(paste(x$analysis, x$family)), , drop = FALSE]
  x <- x[order(-x$value), , drop = FALSE]
  .flags_dedupe(.flags_rows(
    "gas_criterion",
    key = sprintf("gas_criterion|%s|%s|%s|%s", x$feature, x$analyte, format(x$date), x$family),
    site = x$site, date = x$date, feature = x$feature, analyte = x$analyte, value = x$value,
    unit = x$analyte_units,
    threshold = sprintf("> %s %s (%s)", .flags_fmt(x$gv), ifelse(is.na(x$analyte_units), "", x$analyte_units),
                        x$level_name),
    detail = sprintf("%s guideline; %s", x$family, x$project)))
}

.flags_site_history <- function(img, checks, today) {
  a <- img$results
  q <- a[a$quantified & !is.na(a$value), , drop = FALSE]
  nw <- q[q$new, , drop = FALSE]
  if (nrow(nw) == 0) return(NULL)
  pair <- paste(q$feature, q$uuid_analyte, sep = "\r")
  by_pair <- split(seq_len(nrow(q)), pair)
  npair <- paste(nw$feature, nw$uuid_analyte, sep = "\r")
  lo5 <- .flags_years_back(nw$date, 5)
  res <- lapply(seq_len(nrow(nw)), function(i) {
    idx <- by_pair[[npair[[i]]]]
    pd <- q$date[idx]
    pv <- q$value[idx][pd >= lo5[[i]] & pd < nw$date[[i]]]
    n <- length(pv)
    if (n < 8) return(NULL)
    v <- nw$value[[i]]
    rng <- range(pv)
    if (v >= rng[[1]] && v <= rng[[2]]) return(NULL)
    med <- stats::median(pv)
    s <- stats::mad(pv)
    z <- if (s == 0) Inf * sign(v - med) else (v - med) / s
    if (abs(z) <= 4) return(NULL)
    data.frame(i = i, n = n, lo = rng[[1]], hi = rng[[2]], med = med, z = z, mad0 = s == 0)
  })
  h <- do.call(rbind, res)
  if (is.null(h)) return(NULL)
  h <- h[order(-abs(h$z)), , drop = FALSE]
  x <- nw[h$i, , drop = FALSE]
  .flags_dedupe(.flags_rows(
    "site_history",
    key = sprintf("site_history|%s|%s|%s", x$feature, x$analyte, format(x$date)),
    site = x$site, date = x$date, feature = x$feature, analyte = x$analyte, value = x$value,
    unit = x$units,
    threshold = sprintf("prior range %s-%s (n=%d)", .flags_fmt(h$lo), .flags_fmt(h$hi), h$n),
    detail = ifelse(h$mad0, sprintf("the %d priors (5 years) are all equal; %s", h$n, x$project),
                    sprintf("robust z %+.1f (median %s, 5-year priors); %s", h$z,
                            .flags_fmt(h$med), x$project))))
}

# The (feature, analyte) history of each new result: index vectors into
# img$results, split by pair.
.flags_pairs <- function(a, nw) {
  by_pair <- split(seq_len(nrow(a)), paste(a$feature, a$uuid_analyte, sep = "\r"))
  unname(by_pair[paste(nw$feature, nw$uuid_analyte, sep = "\r")])
}

# rl_change (ruling R5): only a RAISED reporting limit - the new RL above the
# pair's highest RL over the prior 2 years.
.flags_rl_change <- function(img, checks, today) {
  a <- img$results
  nw <- a[a$new & !is.na(a$rl_low), , drop = FALSE]
  if (nrow(nw) == 0) return(NULL)
  idx_of <- .flags_pairs(a, nw)
  lo2 <- .flags_years_back(nw$date, 2)
  res <- lapply(seq_len(nrow(nw)), function(i) {
    idx <- idx_of[[i]]
    idx <- idx[a$date[idx] >= lo2[[i]] & a$date[idx] < nw$date[[i]] & !is.na(a$rl_low[idx])]
    if (length(idx) == 0) return(NULL)
    mx <- max(a$rl_low[idx])
    new <- nw$rl_low[[i]]
    if (!(new > mx) || .flags_same_num(new, mx)) return(NULL)
    data.frame(i = i, mx = mx, ratio = new / mx)
  })
  h <- do.call(rbind, res)
  if (is.null(h)) return(NULL)
  h <- h[order(-h$ratio), , drop = FALSE]
  x <- nw[h$i, , drop = FALSE]
  .flags_dedupe(.flags_rows(
    "rl_change", key = sprintf("rl_change|%s|%s|%s", x$feature, x$analyte, format(x$date)),
    site = x$site, date = x$date, feature = x$feature, analyte = x$analyte,
    value = x$rl_low, unit = x$units,
    threshold = sprintf("> 2-year max RL %s", .flags_fmt(h$mx)),
    detail = sprintf("RL raised %s -> %s; %s", .flags_fmt(h$mx), .flags_fmt(x$rl_low),
                     x$project)))
}

# unit_change: the new result's unit against the results on the latest sample
# date before it, for the same (feature, analyte).
.flags_unit_change <- function(img, checks, today) {
  a <- img$results
  nw <- a[a$new & !is.na(a$units), , drop = FALSE]
  if (nrow(nw) == 0) return(NULL)
  idx_of <- .flags_pairs(a, nw)
  res <- lapply(seq_len(nrow(nw)), function(i) {
    idx <- idx_of[[i]]
    idx <- idx[a$date[idx] < nw$date[[i]]]
    if (length(idx) == 0) return(NULL)
    last <- max(a$date[idx])
    prev <- a$units[idx[a$date[idx] == last]]
    prev <- unique(prev[!is.na(prev)])
    if (length(prev) == 0 || nw$units[[i]] %in% prev) return(NULL)
    data.frame(i = i, old = paste(sort(prev), collapse = "/"), last = format(last),
               stringsAsFactors = FALSE)
  })
  h <- do.call(rbind, res)
  if (is.null(h)) return(NULL)
  x <- nw[h$i, , drop = FALSE]
  .flags_dedupe(.flags_rows(
    "unit_change", key = sprintf("unit_change|%s|%s|%s", x$feature, x$analyte, format(x$date)),
    site = x$site, date = x$date, feature = x$feature, analyte = x$analyte, unit = x$units,
    threshold = sprintf("last unit %s", h$old),
    detail = sprintf("unit %s -> %s (last result %s); %s", h$old, x$units, h$last, x$project)))
}

.flags_fns <- list(
  overdue = .flags_overdue,
  invoiced_not_received = .flags_invoiced,
  missing_point = .flags_missing_point,
  missing_analytes = .flags_missing_analytes,
  licence_limit = .flags_licence_limit,
  gas_criterion = .flags_gas_criterion,
  site_history = .flags_site_history,
  rl_change = .flags_rl_change,
  unit_change = .flags_unit_change
)

#' Deterministic checks behind the status note's Flags section
#'
#' Overdue and invoiced-but-missing deliveries, incomplete recent deliveries,
#' licence-limit and gas-criterion exceedances, site-history outliers and
#' reporting-limit / unit changes (PLAN-18 section 4). Read-only: the database
#' is opened `read_only = TRUE` and never written.
#'
#' Each check runs on its own: one that fails contributes no rows, and its
#' message is in `attr(result, "errors")` (a named character vector,
#' `character(0)` when none). A `NULL` element of `checks` silently disables
#' the checks that need it.
#'
#' @param db the database file.
#' @param now current time; "today" is its Australia/Sydney date, and recent
#'   deliveries are those with a `change_log` insert in the 90 days before it.
#' @param checks `list(schedule, limits, requirements, points, invoices)`. The
#'   first four are each a CSV path or a data.frame (`expected_schedule.csv`,
#'   `epa_licence_limits.csv`, `epa_licence_requirements.csv`,
#'   `epa_licence_points.csv`); `invoices` is `data.frame(site, stream,
#'   sampled_on, ref)` or `NULL`.
#' @return a data.frame, one row per flag, columns `check, site, feature,
#'   analyte, date, value, unit, threshold, detail, key`, ordered by check then
#'   date (newest first).
#' @export
import_flags <- function(db = st_config("live_db"), now = Sys.time(), checks) {
  checkmate::assert_string(db)
  checkmate::assert_posixct(now, len = 1, any.missing = FALSE)
  checkmate::assert_list(checks, names = "unique")
  bad <- setdiff(names(checks), c("schedule", "limits", "requirements", "points", "invoices"))
  if (length(bad)) stop("Unknown element(s) of `checks`: ", paste(bad, collapse = ", "))
  if (!file.exists(db)) stop("Database not found: ", db)
  con <- .inbox_read_con(db)
  if (is.null(con)) stop("Cannot open the database read-only: ", db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  today <- .flags_syd_date(now)
  errors <- character(0)
  rows <- list()
  img <- tryCatch(.flags_load(con, now), error = function(e) e)
  for (ck in .flags_checks) {
    r <- if (inherits(img, "error")) img else
      tryCatch(.flags_fns[[ck]](img, checks, today), error = function(e) e)
    if (inherits(r, "error")) {
      errors[[ck]] <- conditionMessage(r)
    } else if (!is.null(r) && nrow(r) > 0) {
      rows[[ck]] <- r
    }
  }
  out <- if (length(rows)) do.call(rbind, unname(rows)) else NULL
  if (is.null(out)) {
    out <- .flags_empty()
  } else {
    out <- out[order(match(out$check, .flags_checks), -as.numeric(out$date), out$key,
                     method = "radix"), , drop = FALSE]
    out$date <- format(out$date, "%Y-%m-%d")
    rownames(out) <- NULL
  }
  attr(out, "errors") <- errors
  out
}

# ---- the status note's Flags section ---------------------------------------------

.flags_prev_seen <- function(report_dir) {
  p <- file.path(report_dir, ".import-status.json")
  js <- tryCatch(jsonlite::fromJSON(p, simplifyVector = FALSE), error = function(e) NULL)
  fl <- if (is.list(js)) js$flags else NULL
  if (!is.list(fl) || length(fl) == 0) return(character(0))
  k <- vapply(fl, function(x) if (is.character(x$key) && length(x$key) == 1) x$key else NA_character_, "")
  s <- vapply(fl, function(x) if (is.character(x$first_seen) && length(x$first_seen) == 1) x$first_seen else NA_character_, "")
  ok <- !is.na(k) & !is.na(s)
  stats::setNames(s[ok], k[ok])
}

# Flags + first_seen for the note: list(flags = data.frame with first_seen,
# errors = named character).
.flags_for_status <- function(db, now, checks, report_dir) {
  prev <- .flags_prev_seen(report_dir)
  fl <- tryCatch(import_flags(db = db, now = now, checks = checks), error = function(e) e)
  if (inherits(fl, "error")) {
    errs <- c(import_flags = conditionMessage(fl))
    fl <- .flags_empty()
  } else {
    errs <- attr(fl, "errors")
  }
  fl$first_seen <- if (nrow(fl)) ifelse(fl$key %in% names(prev), unname(prev[fl$key]),
                                        .inbox_fmt_utc(now)) else character(0)
  list(flags = fl, errors = errs)
}

.flags_note_lines <- function(fs) {
  fl <- fs$flags
  errs <- fs$errors
  out <- c("## Flags", "")
  if (length(errs)) {
    msg <- gsub("\\s*\n\\s*", " ", unname(errs))
    out <- c(out, sprintf("- check %s failed: %s", names(errs), msg), "")
  }
  if (nrow(fl) == 0) return(c(out, "No flags.", ""))
  for (ck in intersect(.flags_checks, fl$check)) {
    g <- fl[fl$check == ck, , drop = FALSE]
    out <- c(out, sprintf("**%s** — %s", ck, .flags_meanings[[ck]]))
    # Ruling R6: the newest 15 per check; the JSON keeps every flag.
    for (i in seq_len(min(nrow(g), 15L))) {
      site <- g$site[[i]]
      site <- if (site %in% c("B", "K")) .inbox_site_label(site) else site
      what <- paste(stats::na.omit(c(g$feature[[i]], g$analyte[[i]])), collapse = " ")
      val <- if (is.na(g$value[[i]])) NA else
        trimws(paste(.flags_fmt(g$value[[i]]), if (is.na(g$unit[[i]])) "" else g$unit[[i]]))
      parts <- c(g$date[[i]], site, what, val, g$threshold[[i]], g$detail[[i]])
      parts <- parts[!is.na(parts) & nzchar(parts)]
      out <- c(out, paste0("- ", paste(parts, collapse = " · ")))
    }
    if (nrow(g) > 15) out <- c(out, sprintf("- +%d more — see .import-status.json", nrow(g) - 15))
    out <- c(out, "")
  }
  out
}

# "<n> flag(s) (overdue 12, gas_criterion 5, site_history 3)" for the
# frontmatter summary: the top 3 checks by count.
.flags_summary <- function(fs) {
  n <- nrow(fs$flags)
  out <- sprintf("%d flag(s)", n)
  if (n > 0) {
    tb <- table(factor(fs$flags$check, levels = .flags_checks))
    tb <- tb[tb > 0]
    tb <- tb[order(-tb, match(names(tb), .flags_checks))][seq_len(min(3, length(tb)))]
    out <- paste0(out, " (", paste(names(tb), tb, collapse = ", "), ")")
  }
  if (length(fs$errors)) out <- paste0(out, sprintf(", %d check(s) failed", length(fs$errors)))
  out
}

.flags_json <- function(fs) {
  fl <- fs$flags
  cols <- c(.flags_cols, "first_seen")
  list(
    flags = lapply(seq_len(nrow(fl)), function(i) {
      stats::setNames(lapply(cols, function(cl) fl[[cl]][[i]]), cols)
    }),
    flag_errors = lapply(names(fs$errors), function(k) {
      list(check = k, message = unname(fs$errors[[k]]))
    })
  )
}
