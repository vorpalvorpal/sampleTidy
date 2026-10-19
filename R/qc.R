# PLAN-19: field QC samples and ALS laboratory QC (phase 1).
#
# A field QC code (duplicate, blanks) is a feature of its own (R19-1), listed in
# `qc_feature` with its parent point. Pass/fail is never stored (R19-2): the
# checks below work it out on every refresh from the `.flags_load()` image.
#
# The code -> parent mapping is confidential (R19-3, R-19.10): it lives in the
# DB only. Nothing here names a real code.

.qc_types <- c("duplicate", "field_blank", "rinsate_blank", "transport_blank",
               "filter_blank", "source_blank")

# ---- small pure pieces -----------------------------------------------------------

#' QC features (R-19.4): one row per `qc_feature` row, with the code's name and
#' site and the parent's name. A DB with no `qc_feature` table (older than 048)
#' gives zero rows of the same shape.
#' @keywords internal
#' @noRd
.qc_features <- function(con) {
  empty <- data.frame(uuid_feature = character(), name = character(), site = character(),
                      qc_type = character(), uuid_parent = character(),
                      parent_name = character(), date_start = as.Date(character()),
                      date_end = as.Date(character()), stringsAsFactors = FALSE)
  if (!DBI::dbExistsTable(con, "qc_feature")) return(empty)
  q <- DBI::dbGetQuery(con, "
    SELECT q.uuid_feature, f.name, f.site, q.qc_type, q.uuid_parent, p.name AS parent_name,
           CAST(q.date_start AS DATE) AS date_start, CAST(q.date_end AS DATE) AS date_end
      FROM qc_feature q
      LEFT JOIN feature f ON f.uuid = q.uuid_feature
      LEFT JOIN feature p ON p.uuid = q.uuid_parent")
  if (nrow(q) == 0) return(empty)
  for (cl in c("uuid_feature", "name", "site", "qc_type", "uuid_parent", "parent_name")) {
    q[[cl]] <- as.character(q[[cl]])
  }
  q$date_start <- as.Date(q$date_start)
  q$date_end <- as.Date(q$date_end)
  q[, names(empty), drop = FALSE]
}

#' Normalise an ALS lab sample number to `<WO>-<nnn>` (R-19.6). The corpus
#' spells it `ES2626883001` (ENMRG/XTAB), `ES2609437-001` (QC.pdf) and
#' `ES2609442--001` (QCI). Anything else (an ACIRL synthetic id, a QC lot,
#' `----`, blank) is NA.
#' @keywords internal
#' @noRd
.qc_norm_lab_id <- function(x) {
  x <- trimws(as.character(x))
  re <- "^(E[A-Z][0-9]{7})-{0,2}([0-9]{3})$"
  ok <- !is.na(x) & grepl(re, x)
  out <- rep(NA_character_, length(x))
  out[ok] <- sub(re, "\\1-\\2", x[ok])
  out
}

#' The QC type named by an ALS `Client sample ID (Secondary)` label (R-19.14);
#' NA for anything else (an EPA point number, blank, an unknown label).
#' @keywords internal
#' @noRd
.qc_secondary_type <- function(x) {
  map <- c("field blank" = "field_blank", "trip blank" = "transport_blank",
           "transport blank" = "transport_blank", "rinsate blank" = "rinsate_blank",
           "equipment blank" = "rinsate_blank", "filter blank" = "filter_blank",
           "lab blank" = "source_blank", "duplicate" = "duplicate",
           "field duplicate" = "duplicate", "dup" = "duplicate")
  k <- tolower(gsub("\\s+", " ", trimws(as.character(x))))
  unname(map[k])
}

#' The method code of a lab method string: `EG020T: Total Metals` -> `EG020T`.
#' @keywords internal
#' @noRd
.qc_method_code <- function(method) {
  m <- trimws(sub(":.*$", "", as.character(method)))
  m[is.na(m)] <- ""
  m
}

.qc_type_label <- function(t) gsub("_", " ", t, fixed = TRUE)

# ---- check inputs (R-19.33, R-19.34) ----------------------------------------------

.qc_criteria_rules <- c("dup_rpd", "dup_absdiff", "dup_lor_multiple", "blank_detect",
                        "blank_factor", "carryover", "filtered_method_regex", "completeness")

#' `dev/qc_criteria.csv` (a path or a data.frame) -> the parameters the checks
#' use. An unknown rule or a missing required rule is an error.
#' @keywords internal
#' @noRd
.qc_criteria <- function(x) {
  d <- .flags_table(x, "qc criteria", c("rule", "qc_type", "analyte_class", "param", "value",
                                         "unit", "action", "source", "status"))
  bad <- is.na(d$rule) | !d$rule %in% .qc_criteria_rules
  if (any(bad)) {
    stop("qc criteria: unknown rule(s): ", paste(unique(d$rule[bad]), collapse = ", "),
         call. = FALSE)
  }
  pick <- function(rule, class = "any", num = TRUE) {
    v <- d$value[d$rule == rule & d$analyte_class %in% class]
    if (length(v) == 0 || is.na(v[[1]])) {
      stop(sprintf("qc criteria: missing required rule %s (%s)", rule, class), call. = FALSE)
    }
    if (!num) return(v[[1]])
    n <- suppressWarnings(as.numeric(v[[1]]))
    if (is.na(n)) stop(sprintf("qc criteria: %s (%s) is not a number", rule, class), call. = FALSE)
    n
  }
  re <- pick("filtered_method_regex", num = FALSE)
  ok <- tryCatch({ grepl(re, "", perl = TRUE); TRUE }, error = function(e) FALSE)
  if (!ok) stop("qc criteria: filtered_method_regex is not a valid regex", call. = FALSE)
  co <- d$value[d$rule == "carryover"]
  list(k = pick("dup_lor_multiple"), rpd_inorganic = pick("dup_rpd", "inorganic"),
       rpd_organic = pick("dup_rpd", "organic"), m = pick("dup_absdiff"),
       f = pick("blank_factor"),
       f_contaminant = if (any(d$rule == "blank_factor" & d$analyte_class %in% "lab_contaminant"))
         pick("blank_factor", "lab_contaminant") else pick("blank_factor"),
       filtered_re = re,
       carryover_min = if (length(co)) suppressWarnings(as.numeric(co[[1]])) else 2)
}

#' `dev/qc_requirements.csv` (a path or a data.frame) -> list of rows.
#' @keywords internal
#' @noRd
.qc_requirements <- function(x) {
  r <- .flags_table(x, "qc requirements", c("site", "months", "qc_type", "n_min", "from", "to",
                                             "source"))
  if (anyNA(r$site)) stop("qc requirements: a row has no site", call. = FALSE)
  bad <- is.na(r$qc_type) | !r$qc_type %in% .qc_types
  if (any(bad)) {
    stop("qc requirements: unknown qc_type(s): ", paste(unique(r$qc_type[bad]), collapse = ", "),
         call. = FALSE)
  }
  months <- lapply(r$months, function(m) {
    p <- if (is.na(m)) character(0) else trimws(strsplit(m, ";", fixed = TRUE)[[1]])
    p <- p[nzchar(p)]
    n <- suppressWarnings(as.integer(p))
    if (length(p) == 0 || !all(grepl("^[0-9]+$", p)) || any(n < 1 | n > 12)) {
      stop("qc requirements: months must be a ;-list of 1-12, not '", m, "'", call. = FALSE)
    }
    n
  })
  nm <- ifelse(is.na(r$n_min), "1", r$n_min)
  if (!all(grepl("^[0-9]+$", nm))) stop("qc requirements: n_min must be a whole number", call. = FALSE)
  from <- .flags_iso_date(r$from, "qc requirements from")
  if (anyNA(from)) stop("qc requirements: a row has no `from` date", call. = FALSE)
  to <- .flags_iso_date(r$to, "qc requirements to")
  lapply(seq_len(nrow(r)), function(i) {
    list(site = r$site[[i]], months = months[[i]], qc_type = r$qc_type[[i]],
         n_min = as.integer(nm[[i]]), from = from[[i]], to = to[[i]], source = r$source[[i]])
  })
}

# The earliest `from` of the site's requirement rows (of any row when the site
# has none); events before it are not assessed. -Inf-like when there are none.
.qc_from <- function(req, site) {
  f <- vapply(req, function(r) if (r$site == site) as.numeric(r$from) else NA_real_, numeric(1))
  if (all(is.na(f))) f <- vapply(req, function(r) as.numeric(r$from), numeric(1))
  if (length(f) == 0 || all(is.na(f))) return(as.Date("1900-01-01"))
  as.Date(min(f, na.rm = TRUE), origin = "1970-01-01")
}

# "<Mon YYYY> quarterly|annual": annual when the month is in a requirement row
# of the site that lists that month alone (e.g. the March transport blank).
.qc_round_label <- function(req, site, m) {
  mon <- m %% 12L + 1L
  annual <- any(vapply(req, function(r) r$site == site && length(r$months) == 1 &&
                         r$months == mon, logical(1)))
  paste(.flags_ym_label(m), if (annual) "annual" else "quarterly")
}

# The checks' common QC inputs, or NULL when `checks$qc` is NULL.
.qc_inputs <- function(checks, need_criteria = TRUE) {
  if (is.null(checks$qc)) return(NULL)
  q <- checks$qc
  if (!is.list(q)) stop("checks$qc must be list(criteria =, requirements =)", call. = FALSE)
  list(criteria = if (need_criteria) .qc_criteria(q$criteria) else NULL,
       requirements = .qc_requirements(q$requirements))
}

# ---- the image's QC view ------------------------------------------------------------

# Recent QC samples assessed by the checks: one row per sample with its
# qc_feature row live at the sample date (NA columns when none is live).
.qc_samples <- function(img, req) {
  s <- img$samples
  s <- s[s$qc %in% TRUE & s$new %in% TRUE & !is.na(s$date), , drop = FALSE]
  if (nrow(s) == 0) return(NULL)
  qf <- img$qc_features
  i <- match(s$feature_uuid, qf$uuid_feature)
  s$qc_type <- qf$qc_type[i]
  s$uuid_parent <- qf$uuid_parent[i]
  s$parent_name <- qf$parent_name[i]
  ds <- qf$date_start[i]
  de <- qf$date_end[i]
  s$qc_date_start <- ds
  s$qc_date_end <- de
  s$live <- !is.na(i) & (is.na(ds) | ds <= s$date) & (is.na(de) | de >= s$date)
  from <- vapply(s$site, function(x) as.numeric(.qc_from(req, x)), numeric(1))
  s <- s[as.numeric(s$date) >= from, , drop = FALSE]
  if (nrow(s) == 0) return(NULL)
  s[order(s$date, s$feature, s$sample, method = "radix"), , drop = FALSE]
}

# The parent point's samples for a QC sample (R19-12): in the same project
# first, else on the same Sydney date in any project. character(0) when none.
.qc_parent_samples <- function(img, q) {
  if (is.na(q$uuid_parent)) return(character(0))
  s <- img$samples
  p <- s[s$feature_uuid %in% q$uuid_parent, , drop = FALSE]
  same_wo <- p$sample[p$project_uuid %in% q$project_uuid]
  if (length(same_wo)) return(same_wo)
  p$sample[!is.na(p$date) & p$date == q$date]
}

# Lab results of a set of samples, one per (analyte, method code).
.qc_lab_results <- function(img, samples) {
  a <- img$results
  a <- a[a$sample %in% samples & a$kind %in% "lab", , drop = FALSE]
  a$mcode <- .qc_method_code(a$method)
  a <- a[order(a$sample, a$analysis, method = "radix"), , drop = FALSE]
  a[!duplicated(paste(a$uuid_analyte, a$mcode, sep = "\r")), , drop = FALSE]
}

.qc_needs_parent <- c("duplicate", "field_blank", "rinsate_blank")

# ---- R-19.24 qc_dup_rpd ------------------------------------------------------------

.flags_qc_dup_rpd <- function(img, checks, today) {
  inp <- .qc_inputs(checks)
  if (is.null(inp) || nrow(img$qc_features) == 0) return(NULL)
  cr <- inp$criteria
  req <- inp$requirements
  qs <- .qc_samples(img, req)
  if (is.null(qs)) return(NULL)
  qs <- qs[qs$live & qs$qc_type %in% "duplicate", , drop = FALSE]
  out <- list()
  qual <- list()
  for (j in seq_len(nrow(qs))) {
    q <- qs[j, , drop = FALSE]
    ps <- .qc_parent_samples(img, q)
    if (length(ps) == 0) next
    da <- .qc_lab_results(img, q$sample)
    pa <- .qc_lab_results(img, ps)
    x <- merge(da, pa, by = c("uuid_analyte", "mcode"), suffixes = c("_d", "_p"))
    if (nrow(x) == 0) next
    x <- x[order(x$analyte_d, x$mcode, method = "radix"), , drop = FALSE]
    nd_val <- function(v, q, rl) ifelse(q, v, ifelse(is.na(rl), v, rl))
    A <- nd_val(x$value_d, x$quantified_d, x$rl_low_d)
    B <- nd_val(x$value_p, x$quantified_p, x$rl_low_p)
    L <- pmax(x$rl_low_d, x$rl_low_p, na.rm = TRUE)
    L[is.na(L)] <- 0
    both_nd <- !x$quantified_d & !x$quantified_p
    organic <- x$atype_d %in% "organic"
    lim <- ifelse(organic, cr$rpd_organic, cr$rpd_inorganic)
    use_rpd <- !is.na(A) & !is.na(B) & A >= cr$k * L & B >= cr$k * L & (A + B) > 0
    rpd <- ifelse(use_rpd, abs(A - B) / ((A + B) / 2) * 100, NA_real_)
    diff <- abs(A - B)
    fail <- !both_nd & !is.na(A) & !is.na(B) &
      ifelse(use_rpd, rpd > lim + 1e-9, diff > cr$m * L + 1e-12)
    fail[is.na(fail)] <- FALSE
    if (!any(fail)) next
    txt <- ifelse(use_rpd,
                  sprintf("%s RPD %.0f%% (>%s%%)", x$analyte_d, rpd, .flags_fmt(lim)),
                  sprintf("%s |diff| %s > %s×LOR %s", x$analyte_d, .flags_fmt(signif(diff, 6)),
                          .flags_fmt(cr$m), .flags_fmt(L)))[fail]
    parent <- q$parent_name
    round <- .qc_round_label(req, q$site, q$ym)
    if (sum(fail) * 2 > nrow(x)) {
      action <- "ask_acirl"
      detail <- sprintf(paste0("%s (parent %s): duplicate does not resemble its parent: check the ",
                               "label with ACIRL before treating as a QC failure (%d of %d ",
                               "analytes fail: %s) — %s → ask ACIRL whether %s was sampled at %s"),
                        q$feature, parent, sum(fail), nrow(x), .flags_first_n(txt, 15), round,
                        q$feature, parent)
    } else {
      action <- "qualify"
      detail <- sprintf("duplicate %s: %s — %s → qualify these results at %s for the event",
                        q$feature, .flags_first_n(txt, 15), round, parent)
      # R-19.32: the parent's failing results are QC qualified.
      qual[[length(qual) + 1]] <- data.frame(
        feature = x$feature_p[fail], analyte = x$analyte_p[fail], date = x$date_p[fail],
        reason = sprintf("duplicate %s %s", q$feature, txt), stringsAsFactors = FALSE)
    }
    out[[length(out) + 1]] <- .flags_rows(
      "qc_dup_rpd", key = sprintf("qc_dup_rpd|%s|%s", q$feature, format(q$date)),
      site = q$site, date = q$date, feature = parent,
      threshold = sprintf("RPD %s%%/%s%% (>= %s×LOR), else |diff| %s×LOR",
                          .flags_fmt(cr$rpd_inorganic), .flags_fmt(cr$rpd_organic),
                          .flags_fmt(cr$k), .flags_fmt(cr$m)),
      detail = detail, action = action)
  }
  .qc_with_qualified(.flags_dedupe(do.call(rbind, out)), qual)
}

# ---- R-19.25 qc_blank_detect ------------------------------------------------------------

.qc_blank_types <- c("field_blank", "rinsate_blank", "transport_blank", "filter_blank",
                     "source_blank")

# Keys (feature|analyte|date) of this run's licence_limit and site_history flags.
.qc_prior_exceedances <- function(img) {
  pr <- img$prior
  k <- character(0)
  for (ck in c("licence_limit", "site_history")) {
    r <- pr[[ck]]
    if (is.null(r) || nrow(r) == 0) next
    k <- c(k, paste(r$feature, r$analyte, format(r$date), sep = "|"))
  }
  k
}

.flags_qc_blank_detect <- function(img, checks, today) {
  inp <- .qc_inputs(checks)
  if (is.null(inp) || nrow(img$qc_features) == 0) return(NULL)
  cr <- inp$criteria
  req <- inp$requirements
  qs <- .qc_samples(img, req)
  if (is.null(qs)) return(NULL)
  qs <- qs[qs$live & qs$qc_type %in% .qc_blank_types, , drop = FALSE]
  exceed <- .qc_prior_exceedances(img)
  a <- img$results
  a$mcode <- .qc_method_code(a$method)
  out <- list()
  quals <- list()
  for (j in seq_len(nrow(qs))) {
    q <- qs[j, , drop = FALSE]
    b <- .qc_lab_results(img, q$sample)
    det <- b[b$quantified & !is.na(b$value), , drop = FALSE]
    if (nrow(det) == 0) next
    det <- det[order(det$analyte, det$mcode, method = "radix"), , drop = FALSE]
    # Associated: non-QC lab results of the same round (project, site).
    assoc <- a[a$kind %in% "lab" & !(a$qc %in% TRUE) & a$project_uuid %in% q$project_uuid &
                 a$site %in% q$site, , drop = FALSE]
    if (q$qc_type == "filter_blank") {
      assoc <- assoc[grepl(cr$filtered_re, assoc$method, perl = TRUE), , drop = FALSE]
    }
    qual <- list()
    for (i in seq_len(nrow(det))) {
      f <- if (isTRUE(det$lab_contaminant[[i]])) cr$f_contaminant else cr$f
      hit <- assoc[assoc$uuid_analyte == det$uuid_analyte[[i]] & assoc$mcode == det$mcode[[i]] &
                     assoc$quantified & !is.na(assoc$value) &
                     assoc$value < f * det$value[[i]], , drop = FALSE]
      if (nrow(hit)) {
        qual[[length(qual) + 1]] <- hit
        # R-19.32: "field blank B.JFxx Ammonia as N 0.05 mg/L".
        quals[[length(quals) + 1]] <- data.frame(
          feature = hit$feature, analyte = hit$analyte, date = hit$date,
          reason = sprintf("%s %s %s %s%s", .qc_type_label(q$qc_type), q$feature, det$analyte[[i]],
                           .flags_fmt(det$value[[i]]),
                           if (is.na(det$units[[i]])) "" else paste0(" ", det$units[[i]])),
          stringsAsFactors = FALSE)
      }
    }
    qual <- if (length(qual)) do.call(rbind, qual) else NULL
    if (!is.null(qual)) qual <- qual[order(qual$feature, qual$analyte, method = "radix"), , drop = FALSE]
    nq <- if (is.null(qual)) 0L else nrow(qual)
    np <- if (is.null(qual)) 0L else length(unique(qual$feature))
    dets <- sprintf("%s %s (LOR %s)", det$analyte, .flags_fmt(det$value),
                    ifelse(is.na(det$rl_low), "?", .flags_fmt(det$rl_low)))
    qtxt <- if (nq) sprintf("%s %s %s", qual$feature, qual$analyte, .flags_fmt(qual$value)) else character(0)
    parent <- q$parent_name
    feature <- if (is.na(parent)) q$feature else parent
    round <- .qc_round_label(req, q$site, q$ym)
    detail <- sprintf("%s %s detected %s; qualifies %d result%s at %d point%s%s",
                      .qc_type_label(q$qc_type), q$feature, .flags_first_n(dets, 15),
                      nq, if (nq == 1) "" else "s", np, if (np == 1) "" else "s",
                      if (nq) paste0(": ", .flags_first_n(qtxt, 15)) else "")
    if (q$qc_type == "rinsate_blank" && !is.na(parent)) {
      detail <- sprintf(paste0("%s; decontamination failed for the apparatus used after %s; ",
                               "results sampled with it after %s are suspect"), detail, parent, parent)
    }
    rs <- if (nq) qual[paste(qual$feature, qual$analyte, format(qual$date), sep = "|") %in% exceed, ,
                       drop = FALSE] else NULL
    if (!is.null(rs) && nrow(rs)) {
      action <- "resample"
      tail <- sprintf("→ resample %s (a contaminated exceedance cannot be confirmed)",
                      paste(unique(sprintf("%s for %s", rs$feature, rs$analyte)), collapse = ", "))
    } else {
      action <- "qualify"
      tail <- "→ qualify these results for the event"
    }
    out[[length(out) + 1]] <- .flags_rows(
      "qc_blank_detect", key = sprintf("qc_blank_detect|%s|%s", q$feature, format(q$date)),
      site = q$site, date = q$date, feature = feature,
      threshold = sprintf("any detection; qualifies < %s× blank (%s× lab contaminant)",
                          .flags_fmt(cr$f), .flags_fmt(cr$f_contaminant)),
      detail = paste(detail, "—", round, tail), action = action)
  }
  .qc_with_qualified(.flags_dedupe(do.call(rbind, out)), quals)
}

# ---- R-19.27 qc_missing --------------------------------------------------------------

.qc_total_metals_re <- "^EG[0-9]{3}[A-Z]*T$"

.flags_qc_missing <- function(img, checks, today) {
  inp <- .qc_inputs(checks)
  if (is.null(inp) || !isTRUE(img$qc_tables)) return(NULL)
  cr <- inp$criteria
  req <- inp$requirements
  if (length(req) == 0) return(NULL)
  sched <- if (is.null(checks$schedule)) list() else .flags_schedule(checks$schedule)
  ss <- img$streams
  ws <- ss[ss$stream %in% .flags_water_streams & ss$new, , drop = FALSE]
  ws <- ws[!ws$sample %in% img$samples$sample[img$samples$qc %in% TRUE], , drop = FALSE]
  rounds <- unique(ws[, c("site", "ym")])
  if (nrow(rounds) == 0) return(NULL)
  rounds <- rounds[order(rounds$site, rounds$ym), , drop = FALSE]
  have_stream <- unique(paste(ss$site, ss$ym, ss$stream))
  # QC samples by site/month with their type (the row live at the sample date,
  # else any row of the code).
  s <- img$samples[img$samples$qc %in% TRUE & !is.na(img$samples$date), , drop = FALSE]
  qf <- img$qc_features
  s$qc_type <- qf$qc_type[match(s$feature_uuid, qf$uuid_feature)]
  a <- img$results
  a$mcode <- .qc_method_code(a$method)
  out <- list()
  for (k in seq_len(nrow(rounds))) {
    site <- rounds$site[[k]]
    m <- rounds$ym[[k]]
    mon <- m %% 12L + 1L
    rr <- Filter(function(r) r$site == site && mon %in% r$months && .flags_valid_in(r, m), req)
    if (length(rr) == 0) next
    # R19-10 (7): wait until every water stream the schedule expects has landed.
    exp_streams <- unique(unlist(lapply(sched, function(r) {
      if (r$site == site && r$stream %in% .flags_water_streams && mon %in% r$months &&
          .flags_valid_in(r, m)) r$stream
    })))
    if (length(exp_streams) && !all(paste(site, m, exp_streams) %in% have_stream)) next
    need <- tapply(vapply(rr, function(r) r$n_min, integer(1)),
                   vapply(rr, function(r) r$qc_type, ""), max)
    sm <- s[s$site %in% site & s$ym == m, , drop = FALSE]
    notes <- character(0)
    short <- character(0)
    for (t in intersect(.qc_types, names(need))) {
      st <- sm[sm$qc_type %in% t, , drop = FALSE]
      if (t == "rinsate_blank" && nrow(st)) {
        ok <- vapply(st$sample, function(x) {
          r <- a[a$sample == x, , drop = FALSE]
          filtered <- any(grepl(cr$filtered_re, r$method, perl = TRUE))
          suite <- any(grepl(.qc_total_metals_re, r$mcode)) || any(r$mcode == "EP005") ||
            any(grepl("Total Organic Carbon", r$analyte, ignore.case = TRUE))
          !filtered && suite
        }, logical(1))
        for (bad in unique(st$feature[!ok])) {
          notes <- c(notes, sprintf("rinsate blank %s filtered or wrong suite: not a decontamination test", bad))
        }
        st <- st[ok, , drop = FALSE]
      }
      if (nrow(st) < need[[t]]) short <- c(short, t)
    }
    if (length(short) == 0) next
    lbl <- .qc_type_label(short)
    miss <- ifelse(need[short] > 1, sprintf("fewer than %d %ss", need[short], lbl), paste("no", lbl))
    round <- .qc_round_label(req, site, m)
    detail <- sprintf("%s: %s%s (need %s) → chase ACIRL for the missing QC samples",
                      round, paste(miss, collapse = ", "),
                      if (length(notes)) paste0("; ", paste(notes, collapse = "; ")) else "",
                      paste(.qc_type_label(intersect(.qc_types, names(need))), collapse = ", "))
    out[[length(out) + 1]] <- .flags_rows(
      "qc_missing", key = sprintf("qc_missing|%s|%s", site, format(.flags_ym_start(m), "%Y-%m")),
      site = site, date = .flags_ym_start(m),
      threshold = sprintf("QC requirements, %s", .flags_ym_label(m)),
      detail = detail, action = "chase")
  }
  do.call(rbind, out)
}

# ---- R-19.28 qc_unresolved -------------------------------------------------------------

.flags_qc_unresolved <- function(img, checks, today) {
  inp <- .qc_inputs(checks, need_criteria = FALSE)
  if (is.null(inp) || nrow(img$qc_features) == 0) return(NULL)
  req <- inp$requirements
  qs <- .qc_samples(img, req)
  if (is.null(qs)) return(NULL)
  conflict_wo <- img$qc_label_conflict_wo
  out <- list()
  for (j in seq_len(nrow(qs))) {
    q <- qs[j, , drop = FALSE]
    why <- NULL
    if (!q$live) {
      why <- sprintf("QC code %s has no qc_feature pairing live on %s", q$feature, format(q$date))
    } else if (q$qc_type %in% .qc_needs_parent && !is.na(q$uuid_parent) &&
               length(.qc_parent_samples(img, q)) == 0) {
      why <- sprintf("%s %s: parent %s has no sample in work order %s or on %s",
                     .qc_type_label(q$qc_type), q$feature, q$parent_name, q$project, format(q$date))
    } else if (!is.na(q$project) && q$project %in% conflict_wo) {
      why <- sprintf("%s %s: a qc_label_conflict review item is open on work order %s",
                     .qc_type_label(q$qc_type), q$feature, q$project)
    }
    if (is.null(why)) next
    round <- .qc_round_label(req, q$site, q$ym)
    out[[length(out) + 1]] <- .flags_rows(
      "qc_unresolved", key = sprintf("qc_unresolved|%s|%s", q$feature, format(q$date)),
      site = q$site, date = q$date, feature = q$feature,
      detail = sprintf("%s — %s → ask ACIRL which point and QC type %s is", why, round, q$feature),
      action = "ask_acirl")
  }
  .flags_dedupe(do.call(rbind, out))
}

# ---- R-19.31 lab_qc_missing -------------------------------------------------------------

.flags_lab_qc_missing <- function(img, checks, today) {
  rep <- img$lab_qc_report
  if (is.null(rep)) return(NULL)
  ss <- img$streams
  ls <- ss[ss$stream %in% "als_lab" & ss$new & !is.na(ss$project), , drop = FALSE]
  if (nrow(ls) == 0) return(NULL)
  wos <- sort(unique(ls$project), method = "radix")
  out <- list()
  for (wo in wos) {
    r <- rep[rep$work_order %in% wo & rep$kind %in% "QCI", , drop = FALSE]
    if (any(r$status %in% "parsed")) next
    x <- ls[ls$project == wo, , drop = FALSE]
    detail <- if (nrow(r)) {
      msg <- r$message[!is.na(r$message)]
      sprintf("QCI received but %s: %s", if (any(r$status %in% "partial")) "only partly read" else "unreadable",
              if (length(msg)) msg[[1]] else "no message")
    } else if (wo %in% img$qci_asset_wo) {
      "QCI archived but not parsed yet: run lab_qc_backfill()"
    } else {
      paste0("no ALS QC Interpretive report (QCI) received: ask ACIRL/ALS for the QC report and ",
             "QA/QC compliance assessment")
    }
    out[[length(out) + 1]] <- .flags_rows(
      "lab_qc_missing", key = sprintf("lab_qc_missing|%s", wo),
      site = sort(unique(x$site), method = "radix")[[1]], date = max(x$date),
      threshold = "ALS QCI per work order",
      detail = sprintf("%s: %s → chase the ALS QCI for %s", wo, detail, wo), action = "chase")
  }
  do.call(rbind, out)
}

# ---- PLAN-19 phase 1b: ALS lab QC (R-19.29, R-19.30, R-19.32) ------------------------------

# Attach a check's QC qualification set (R-19.32): data.frame(feature,
# analyte, date, reason) of results the finding qualifies.
.qc_with_qualified <- function(res, qual) {
  if (is.null(res) || length(qual) == 0) return(res)
  q <- do.call(rbind, qual)
  if (!is.null(q) && nrow(q)) attr(res, "qc_qualify") <- q
  res
}

# R-19.32: after every check has run, append "; QC qualified: <reasons>" to a
# licence_limit, site_history or rl_change flag on a qualified result (a lab
# result: a licence flag on a field result is not qualified by lab QC).
.qc_apply_qualified <- function(rows) {
  q <- do.call(rbind, lapply(unname(rows), function(r) attr(r, "qc_qualify")))
  if (is.null(q) || nrow(q) == 0) return(rows)
  qk <- paste(q$feature, q$analyte, format(as.Date(q$date)), sep = "\r")
  for (ck in c("licence_limit", "site_history", "rl_change")) {
    r <- rows[[ck]]
    if (is.null(r) || nrow(r) == 0) next
    rk <- paste(r$feature, r$analyte, format(as.Date(r$date)), sep = "\r")
    lab <- if (ck == "licence_limit") !grepl("\\|field$", r$key) else rep(TRUE, nrow(r))
    for (i in which(lab & rk %in% qk)) {
      why <- unique(q$reason[qk == rk[[i]]])
      r$detail[[i]] <- paste0(r$detail[[i]], "; QC qualified: ", paste(why, collapse = ", "))
    }
    rows[[ck]] <- r
  }
  rows
}

# Work orders with a recent delivery (ruling R1): any of their samples is new.
.qc_recent_wo <- function(img) {
  s <- img$samples
  unique(s$project[s$new %in% TRUE & !is.na(s$project)])
}

# "<Mon YYYY> quarterly|annual" when the QC requirements are given, else the
# month alone (the lab-QC checks need only the DB, R-19.23).
.qc_round_or_month <- function(checks, site, m) {
  req <- tryCatch(.qc_inputs(checks, need_criteria = FALSE)$requirements, error = function(e) NULL)
  if (length(req)) .qc_round_label(req, site, m) else .flags_ym_label(m)
}

.qc_limits_text <- function(lo, hi) {
  if (!is.na(lo) && !is.na(hi)) return(sprintf("%s–%s%%", .flags_fmt(lo), .flags_fmt(hi)))
  if (!is.na(lo)) return(sprintf("≥ %s%%", .flags_fmt(lo)))
  if (!is.na(hi)) return(sprintf("≤ %s%%", .flags_fmt(hi)))
  "no limits"
}

# Lab results a lab-QC row applies to: same method code and analyte (by
# analyte name or lab-method name).
.qc_results_for <- function(a, method, analyte) {
  a[a$kind %in% "lab" & a$mcode == method &
      (a$analyte %in% analyte | a$method_name %in% analyte), , drop = FALSE]
}

.flags_lab_qc_outlier <- function(img, checks, today) {
  o <- img$lab_qc_outlier
  if (is.null(o) || nrow(o) == 0) return(NULL)
  wos <- .qc_recent_wo(img)
  o <- o[o$work_order %in% wos & o$kind %in% c("ms", "dup", "mb", "surrogate", "lcs"), , drop = FALSE]
  # Never flagged: another client's sample, and an MS ALS could not determine
  # (background >= 4x the spike: information only).
  anon <- !is.na(o$client_id) & tolower(trimws(o$client_id)) == "anonymous"
  nd <- o$kind == "ms" & !is.na(o$comment) & grepl("^MS recovery not determined", o$comment)
  o <- o[!anon & !nd, , drop = FALSE]
  if (nrow(o) == 0) return(NULL)
  a <- img$results
  a$mcode <- .qc_method_code(a$method)
  s <- img$samples
  ht <- img$lab_qc_outlier
  out <- list()
  qual <- list()
  for (i in seq_len(nrow(o))) {
    r <- o[i, , drop = FALSE]
    v <- r$value_pct
    outside <- !is.na(v) & ((!is.na(r$limit_low) & v < r$limit_low) |
                              (!is.na(r$limit_high) & v > r$limit_high))
    if (r$kind == "lcs") {
      # Batch level: every result of the work order under that method/analyte.
      if (!is.na(v) && !outside) next
      hit <- .qc_results_for(a[a$project %in% r$work_order, , drop = FALSE], r$method, r$analyte_raw)
    } else {
      if (!outside || is.na(r$uuid_sample) || !r$uuid_sample %in% s$sample) next
      hit <- .qc_results_for(a[a$sample %in% r$uuid_sample, , drop = FALSE], r$method, r$analyte_raw)
      if (nrow(hit) == 0) {
        ss <- s[s$sample %in% r$uuid_sample, , drop = FALSE]
        hit <- data.frame(feature = ss$feature, site = ss$site, date = ss$date, ym = ss$ym,
                          analyte = r$analyte_raw, stringsAsFactors = FALSE)
      }
    }
    if (nrow(hit) == 0) next
    hit <- hit[order(hit$feature, method = "radix"), , drop = FALSE]
    pts <- unique(hit$feature)
    lab <- toupper(r$kind)
    lim <- .qc_limits_text(r$limit_low, r$limit_high)
    val <- if (is.na(v)) "not determined" else paste0(.flags_fmt(v), "%")
    cmt <- if (is.na(r$comment)) "" else paste0(", ", tolower(substr(r$comment, 1, 1)),
                                               substr(r$comment, 2, nchar(r$comment)))
    site <- sort(unique(hit$site), method = "radix")[[1]]
    d <- max(hit$date)
    m <- .flags_ym(d)
    # The lab can re-run while the method's ALS due date (from this report's
    # holding-time rows) has not passed; otherwise the results are qualified.
    due <- ht$due_analysis[ht$work_order %in% r$work_order & ht$method %in% r$method]
    due <- suppressWarnings(max(as.Date(due), na.rm = TRUE))
    reanalyse <- is.finite(due) && due >= today
    tail <- if (reanalyse) {
      sprintf("→ ask ALS to re-run %s %s for %s", r$method, r$analyte_raw, paste(pts, collapse = ", "))
    } else {
      sprintf("→ qualify %s at %s for the event", r$analyte_raw, paste(pts, collapse = ", "))
    }
    ref <- if (!is.na(r$lab_id)) r$lab_id else if (!is.na(r$qc_lot)) r$qc_lot else "-"
    out[[length(out) + 1]] <- .flags_rows(
      "lab_qc_outlier",
      key = sprintf("lab_qc_outlier|%s|%s|%s|%s|%s", r$work_order, r$kind, r$method, r$analyte_raw, ref),
      site = site, date = d, feature = if (length(pts) == 1) pts else NA, analyte = r$analyte_raw,
      value = v, unit = "%", threshold = lim,
      detail = sprintf("ALS QCI %s: %s %s %s %s (%s)%s — affects %s — %s %s", r$work_order, r$method,
                       r$analyte_raw, lab, val, lim, cmt, paste(pts, collapse = ", "),
                       .qc_round_or_month(checks, site, m), tail),
      action = if (reanalyse) "reanalyse" else "qualify")
    qual[[length(qual) + 1]] <- data.frame(
      feature = hit$feature, analyte = hit$analyte, date = hit$date,
      reason = sprintf("ALS %s %s %s %s (%s)", lab, r$method, r$analyte_raw, val, lim),
      stringsAsFactors = FALSE)
  }
  .qc_with_qualified(.flags_dedupe(do.call(rbind, out)), qual)
}

# Licence-required pollutants per (feature): data.frame(feature, uuid_analyte,
# pollutant), from the requirements and points tables and the EPA masks.
.qc_licence_required <- function(img, checks) {
  if (is.null(checks$requirements) || is.null(checks$points)) return(NULL)
  req <- .flags_table(checks$requirements, "requirements", c("site", "epa_point", "pollutant"))
  pts <- .flags_table(checks$points, "points", c("site", "epa_point", "role"))
  pts <- pts[!pts$role %in% "weather", , drop = FALSE]
  req <- req[!is.na(req$pollutant) & paste(req$site, req$epa_point) %in% paste(pts$site, pts$epa_point), ,
             drop = FALSE]
  if (nrow(req) == 0) return(NULL)
  fmap <- DBI::dbGetQuery(img$con, "
    SELECT f.name AS feature, f.site AS site, trim(fm.name) AS epa_point
      FROM feature_mask fm JOIN feature f ON f.uuid = fm.uuid_feature
     WHERE fm.variant = 'EPA' AND fm.name IS NOT NULL AND trim(fm.name) <> ''")
  amap <- DBI::dbGetQuery(img$con, "
    SELECT uuid_analyte, trim(name) AS pollutant FROM analyte_mask
     WHERE variant = 'EPA' AND name IS NOT NULL AND trim(name) <> ''")
  x <- merge(fmap, req[, c("site", "epa_point", "pollutant")], by = c("site", "epa_point"))
  x <- merge(x, amap, by = "pollutant")
  unique(x[, c("feature", "uuid_analyte", "pollutant")])
}

.flags_holding_time <- function(img, checks, today) {
  o <- img$lab_qc_outlier
  if (is.null(o) || nrow(o) == 0) return(NULL)
  wos <- .qc_recent_wo(img)
  o <- o[o$kind %in% "holding_time" & o$work_order %in% wos, , drop = FALSE]
  if (nrow(o) == 0) return(NULL)
  s <- img$samples
  a <- img$results
  a$mcode <- .qc_method_code(a$method)
  i <- match(o$uuid_sample, s$sample)
  o$feature <- s$feature[i]
  o$site <- s$site[i]
  o$date <- s$date[i]
  # Lab pH (EA005*) at a sample with a field pH: the field pH wins (ruling
  # 2026-07-24), so its lab holding time does not matter.
  if (any(grepl("^EA005", o$method) & !is.na(i))) {
    ph_lab <- unique(a$uuid_analyte[a$kind %in% "lab" & grepl("^EA005", a$mcode)])
    fph <- unique(a$sample[a$kind %in% "field" &
                             (a$uuid_analyte %in% ph_lab | grepl("^pH\\b", a$analyte))])
    o <- o[!(grepl("^EA005", o$method) & o$uuid_sample %in% fph), , drop = FALSE]
  }
  if (nrow(o) == 0) return(NULL)
  lic <- .qc_licence_required(img, checks)
  out <- list()
  qual <- list()
  grp <- unique(o[, c("work_order", "method")])
  grp <- grp[order(grp$work_order, grp$method, method = "radix"), , drop = FALSE]
  for (g in seq_len(nrow(grp))) {
    wo <- grp$work_order[[g]]
    meth <- grp$method[[g]]
    x <- o[o$work_order == wo & o$method == meth, , drop = FALSE]
    linked <- x[!is.na(x$feature), , drop = FALSE]
    linked <- linked[order(linked$feature, method = "radix"), , drop = FALSE]
    raw <- unique(x$client_id[is.na(x$feature)])
    ws <- s[s$project %in% wo, , drop = FALSE]
    site <- if (nrow(linked)) linked$site[[1]] else if (nrow(ws)) sort(unique(ws$site), method = "radix")[[1]] else NA
    d <- if (nrow(linked)) max(linked$date) else if (nrow(ws)) max(ws$date, na.rm = TRUE) else NA
    if (is.na(site) || is.na(d)) next
    days <- unique(stats::na.omit(x$days_overdue))
    who <- c(unique(linked$feature), if (length(raw)) sprintf("\"%s\"", raw))
    if (length(days) <= 1) {
      late <- if (length(days)) sprintf("%d day%s late", days, if (days == 1) "" else "s") else "late"
      where <- paste(who, collapse = ", ")
    } else {
      late <- "late"
      dd <- x$days_overdue[match(c(unique(linked$feature), raw),
                                 ifelse(is.na(x$feature), x$client_id, x$feature))]
      where <- paste(sprintf("%s (%s day%s)", who, dd, ifelse(dd %in% 1, "", "s")), collapse = ", ")
    }
    # The results the breach touches: the linked samples' lab results under it.
    res <- a[a$kind %in% "lab" & a$mcode == meth & a$sample %in% linked$uuid_sample, , drop = FALSE]
    # resample: a licence-required pollutant at a linked licence point, with
    # no field result of the same analyte to stand in for it.
    rs <- character(0)
    if (!is.null(lic) && nrow(res)) {
      fld <- paste(a$sample, a$uuid_analyte)[a$kind %in% "field"]
      need <- res[paste(res$feature, res$uuid_analyte) %in% paste(lic$feature, lic$uuid_analyte) &
                    !paste(res$sample, res$uuid_analyte) %in% fld, , drop = FALSE]
      rs <- unique(sprintf("%s for %s", need$feature, need$analyte))
    }
    mname <- x$method_name[[1]]
    tail <- if (length(rs)) sprintf("→ resample %s", paste(rs, collapse = ", ")) else
      sprintf("→ qualify %s results at %s for the event", if (is.na(mname)) meth else mname,
              paste(who, collapse = ", "))
    out[[length(out) + 1]] <- .flags_rows(
      "holding_time", key = sprintf("holding_time|%s|%s", wo, meth), site = site, date = d,
      feature = if (length(who) == 1 && nrow(linked)) linked$feature[[1]] else NA,
      threshold = "ALS holding time",
      detail = sprintf("ALS QCI %s: %s %s analysed %s at %s — %s %s", wo, meth,
                       if (is.na(mname)) "" else mname, late, where,
                       .qc_round_or_month(checks, site, .flags_ym(d)), tail),
      action = if (length(rs)) "resample" else "qualify")
    if (nrow(res)) {
      dl <- x$days_overdue[match(res$sample, x$uuid_sample)]
      qual[[length(qual) + 1]] <- data.frame(
        feature = res$feature, analyte = res$analyte, date = res$date,
        reason = sprintf("holding time %s %s day%s late (ALS QCI %s)", meth, dl,
                         ifelse(dl %in% 1, "", "s"), wo), stringsAsFactors = FALSE)
    }
  }
  .qc_with_qualified(.flags_dedupe(do.call(rbind, out)), qual)
}

# The QC checks join the flag functions (R/flags.R defines the rest).
.flags_fns <- c(.flags_fns, list(
  qc_dup_rpd = .flags_qc_dup_rpd,
  qc_blank_detect = .flags_qc_blank_detect,
  qc_missing = .flags_qc_missing,
  qc_unresolved = .flags_qc_unresolved,
  lab_qc_outlier = .flags_lab_qc_outlier,
  holding_time = .flags_holding_time,
  lab_qc_missing = .flags_lab_qc_missing
))
