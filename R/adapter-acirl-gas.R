# PLAN-17 - the `acirl_gas_xlsx` adapter: ACIRL "Monthly Gas Monitoring"
# workbooks (`2400-*... Gas Monitoring ... .xls`). One front page plus
# `Gas Landfil #n` / `Gas Building(s)` sheets (and at Katoomba a
# `Biofliter and Bores` sheet) holding CH4 readings in % v/v.
#
# Geometry is found by HEADER TEXT, never by position (the files come in three
# families whose header row is 6, 7 or 11 and whose first column is 1 or 2):
# each `CH4 Reading` header cell pairs with the `Location` cell to its left,
# with an optional `Reference` column between them.
#
# The site (`B.` / `K.`) comes from the workbook's own text, never the
# filename - probe numbers are not site-unique (PLAN-17).

#' Construct the `acirl_gas_xlsx` adapter
#' @return a list with elements `id`, `version`, `match`, `parse`.
#' @keywords internal
#' @noRd
acirl_gas_xlsx_adapter <- function() {
  version <- "1.0"
  list(
    id = "acirl_gas_xlsx",
    version = version,
    # A89: a bare `0` from the gas analyser is "below what it can see", not a
    # measurement of zero. Reconcile's value re-parse honours this per row, by
    # the row's adapter; no other adapter's zeros change.
    zero_is_nondetect = TRUE,
    match = function(file_meta) .st_gas_match(file_meta),
    parse = function(path, file_meta) .st_gas_parse(path, file_meta, version)
  )
}

# ---- helpers -----------------------------------------------------------------

.st_gas_is_data_sheet <- function(sheet_names) {
  grepl("^gas\\s+(landfil|building)", trimws(sheet_names), ignore.case = TRUE)
}

.st_gas_is_bio_sheet <- function(sheet_names) {
  grepl("bio.*bores|bores", trimws(sheet_names), ignore.case = TRUE)
}

.st_gas_read_grid <- function(path, sheet, n_max = Inf) {
  g <- tryCatch(
    suppressMessages(readxl::read_excel(
      path, sheet = sheet, col_names = FALSE, col_types = "text", n_max = n_max
    )),
    error = function(e) NULL
  )
  if (is.null(g) || nrow(g) == 0 || ncol(g) == 0) {
    return(matrix(NA_character_, 0, 0))
  }
  m <- as.matrix(g)
  dimnames(m) <- NULL
  m
}

.st_gas_col_letters <- function(n) {
  out <- character(0)
  while (n > 0) {
    r <- (n - 1) %% 26
    out <- c(LETTERS[r + 1], out)
    n <- (n - 1) %/% 26
  }
  paste(out, collapse = "")
}

.st_gas_clean <- function(x) {
  x <- gsub(" ", " ", x, fixed = TRUE)
  x <- stringr::str_squish(x)
  x[is.na(x) | !nzchar(x)] <- NA_character_
  x
}

# A header cell reading `CH4 Reading` followed by anything (`% v/v`, a run of
# spaces then `% v/v`).
.st_gas_ch4_hits <- function(mat) {
  if (length(mat) == 0) return(matrix(integer(0), 0, 2))
  hit <- matrix(grepl("^ch4\\s*reading", .st_gas_clean(mat), ignore.case = TRUE),
                nrow = nrow(mat))
  which(hit, arr.ind = TRUE)
}

# --- match() -------------------------------------------------------------------

.st_gas_match <- function(fm) {
  if (!isTRUE(fm$ext %in% c("xls", "xlsx"))) return("no")
  sn <- fm$sheet_names
  if (is.null(sn) || length(sn) == 0) return("no")
  if (!any(grepl("front", sn, ignore.case = TRUE))) return("no")
  for (s in sn[grepl("^gas\\s+landfil", trimws(sn), ignore.case = TRUE)]) {
    g <- .st_gas_read_grid(fm$path, s, n_max = 20)
    if (nrow(.st_gas_ch4_hits(g)) > 0) return("format")
  }
  "no"
}

# --- parse() ---------------------------------------------------------------------

.st_gas_parse <- function(path, fm, version) {
  tryCatch(
    .st_gas_parse_impl(path, fm, version),
    error = function(e) {
      if (inherits(e, "sampletidy_parse_error")) stop(e)
      cli::cli_abort(
        "Failed to parse {.path {path}} as an ACIRL gas workbook: {conditionMessage(e)}",
        class = "sampletidy_parse_error", parent = e
      )
    }
  )
}

.st_gas_normalise_report_no <- function(x) {
  if (is.na(x)) return(list(report_no = NA_character_, amended = FALSE))
  amended <- grepl("amended", x, ignore.case = TRUE)
  y <- stringr::str_squish(gsub("amended", "", x, ignore.case = TRUE))
  y <- gsub("\\s*-\\s*", "-", y)
  list(report_no = y, amended = amended)
}

.st_gas_serial_to_date <- function(x) {
  if (is.na(x)) return(as.Date(NA))
  n <- suppressWarnings(as.numeric(x))
  if (!is.na(n)) return(as.Date(n, origin = "1899-12-30"))
  d <- suppressWarnings(as.Date(x, format = "%d/%m/%Y"))
  if (is.na(d)) d <- suppressWarnings(as.Date(x))
  d
}

.st_gas_text_reason <- function(v) {
  k <- tolower(stringr::str_squish(v))
  if (k == "ns") return("no_sample")
  if (k == "nr") return("not_requested")
  if (k == "no access") return("no_access")
  if (k == "does not exist") return("point_absent")
  if (k == "not on the map") return("not_on_map")
  "unrecognised_text"
}

# All data blocks on one sheet. Returns a list of raw readings:
# list(row, col, feature, raw, bio).
.st_gas_sheet_readings <- function(mat, sheet, site, is_bio) {
  n_row <- nrow(mat); n_col <- ncol(mat)
  if (n_row == 0) return(list())
  cl <- matrix(.st_gas_clean(mat), nrow = n_row)
  cell <- function(r, c) if (r < 1 || r > n_row || c < 1 || c > n_col) NA_character_ else cl[r, c]

  term_re <- "^(note\\b|ns\\s*:|nr\\s*:|xx\\s*:|additional gas point|gas monitoring bores)"
  is_term_row <- vapply(seq_len(n_row), function(r) {
    v <- cl[r, ]
    v <- v[!is.na(v)]
    length(v) > 0 && any(grepl(term_re, v, ignore.case = TRUE) | tolower(v) == "location")
  }, logical(1))

  hits <- .st_gas_ch4_hits(mat)
  out <- list()
  seen <- character(0)
  for (k in seq_len(nrow(hits))) {
    H <- hits[k, 1]; cc <- hits[k, 2]
    lc <- NA_integer_; rc <- NA_integer_
    if (identical(tolower(cell(H, cc - 1L)), "location")) {
      lc <- cc - 1L
    } else if (identical(tolower(cell(H, cc - 2L)), "location") && !is.na(cell(H, cc - 1L))) {
      lc <- cc - 2L; rc <- cc - 1L
    } else {
      next
    }
    later <- which(is_term_row & seq_len(n_row) > H)
    E <- if (length(later)) min(later) - 1L else n_row
    building <- !is.na(rc)
    cur_loc <- NA_character_
    for (r in seq_len(max(E - H, 0L)) + H) {
      loc <- cell(r, lc); ref <- if (building) cell(r, rc) else NA_character_
      val <- cell(r, cc)
      if (building) {
        if (!is.na(loc)) cur_loc <- loc else loc <- cur_loc
        if (is.na(ref)) next
      } else if (is.na(loc)) {
        next
      }
      # A blank cell still takes its place in a repeated Reference's #n count.
      feature <- if (building) {
        if (grepl("^gas bore$", tolower(loc)) && grepl("^mp\\s*[0-9]+$", tolower(ref))) {
          paste0(site, ".MP_", sub("^mp\\s*", "", tolower(ref)))
        } else {
          nm <- paste0(site, ".", loc, " - ", ref)
          if (nm %in% seen) {
            i <- 2L
            while (paste(nm, paste0("#", i)) %in% seen) i <- i + 1L
            nm <- paste(nm, paste0("#", i))
          }
          nm
        }
      } else if (grepl("^g[0-9]+$", tolower(loc))) {
        paste0(site, ".", toupper(loc))
      } else if (grepl("^[0-9]+$", loc)) {
        paste0(site, ".Weekly ", loc)
      } else {
        paste0(site, ".", loc)
      }
      seen <- c(seen, feature)
      if (is.na(val)) next
      out[[length(out) + 1L]] <- list(
        row = r, col = cc, feature = feature, raw = val, bio = is_bio
      )
    }
  }
  out
}

# The two 2 x 3 biofilter grids above the bores table.
.st_gas_bio_grids <- function(mat, site) {
  n_row <- nrow(mat); n_col <- ncol(mat)
  if (n_row == 0) return(list())
  cl <- matrix(.st_gas_clean(mat), nrow = n_row)
  rn <- which(apply(cl, 1, function(v) any(grepl("^report no", v, ignore.case = TRUE), na.rm = TRUE)))
  start <- if (length(rn)) min(rn) + 1L else 1L
  stop_at <- which(apply(cl, 1, function(v) any(grepl("^gas monitoring bores|^location$", v, ignore.case = TRUE), na.rm = TRUE)))
  stop_at <- stop_at[stop_at >= start]
  end <- if (length(stop_at)) min(stop_at) - 1L else n_row
  if (end < start) return(list())

  is_num <- function(v) !is.na(v) & !is.na(suppressWarnings(as.numeric(v)))
  is_cell_value <- function(v) {
    is_num(v) | (!is.na(v) & tolower(v) %in% c("ns", "nr", "no access", "does not exist", "not on the map"))
  }
  rows <- start:end
  kind <- vapply(rows, function(r) {
    v <- cl[r, ]
    if (any(is_cell_value(v))) "data" else if (any(!is.na(v))) "label" else "blank"
  }, character(1))

  grids <- list(); label <- NA_character_; cur <- integer(0)
  flush <- function() {
    if (length(cur)) {
      grids[[length(grids) + 1L]] <<- list(rows = cur, label = label)
      label <<- NA_character_; cur <<- integer(0)
    }
  }
  for (i in seq_along(rows)) {
    if (kind[[i]] == "data") {
      cur <- c(cur, rows[[i]])
    } else {
      flush()
      if (kind[[i]] == "label") {
        v <- cl[rows[[i]], ]
        label <- v[!is.na(v)][[1]]
      }
    }
  }
  flush()
  if (!length(grids)) return(list())

  defaults <- c("North Corner", "Front of Buildings")
  all_cols <- unlist(lapply(grids, function(g) {
    which(apply(cl[g$rows, , drop = FALSE], 2, function(v) any(is_cell_value(v))))
  }))
  base_col <- min(all_cols)
  out <- list()
  for (gi in seq_along(grids)) {
    g <- grids[[gi]]
    lab <- if (!is.na(g$label)) g$label else if (gi <= length(defaults)) defaults[[gi]] else paste("Grid", gi)
    full <- if (tolower(lab) == "north corner") "Biofilter North Corner" else lab
    for (ri in seq_along(g$rows)) {
      for (cc in seq_len(n_col)) {
        v <- cl[g$rows[[ri]], cc]
        if (!is_cell_value(v)) next
        out[[length(out) + 1L]] <- list(
          row = g$rows[[ri]], col = cc,
          feature = sprintf("%s.%s R%dC%d", site, full, ri, cc - base_col + 1L),
          raw = v, bio = TRUE
        )
      }
    }
  }
  out
}

.st_gas_parse_impl <- function(path, fm, version) {
  sheet_names <- fm$sheet_names
  if (is.null(sheet_names)) sheet_names <- readxl::excel_sheets(path)
  adapter_tag <- paste0("acirl_gas_xlsx/", version)
  warnings_vec <- character(0)

  # --- front page ---------------------------------------------------------------
  front_idx <- which(grepl("front", sheet_names, ignore.case = TRUE))
  front_grid <- if (length(front_idx)) {
    suppressMessages(readxl::read_excel(path, sheet = sheet_names[[front_idx[[1]]]],
                                        col_names = FALSE, col_types = "text"))
  } else {
    tibble::tibble()
  }
  fp <- .st_acirl_parse_front_page(front_grid)
  header <- fp$header
  warnings_vec <- c(warnings_vec, fp$warnings)
  front_mat <- if (length(front_idx)) {
    m <- as.matrix(front_grid); dimnames(m) <- NULL; m
  } else {
    matrix(NA_character_, 0, 0)
  }

  data_sheets <- sheet_names[.st_gas_is_data_sheet(sheet_names)]
  bio_sheets <- sheet_names[.st_gas_is_bio_sheet(sheet_names) & !(sheet_names %in% data_sheets)]
  mats <- stats::setNames(
    lapply(c(data_sheets, bio_sheets), function(s) .st_gas_read_grid(path, s)),
    c(data_sheets, bio_sheets)
  )

  # --- report number: the cell, never the filename ---------------------------------
  rn_cell <- header$report_no
  if (is.na(rn_cell)) {
    for (m in mats) {
      if (length(m) == 0) next
      cl <- matrix(.st_gas_clean(m), nrow = nrow(m))
      h <- which(grepl("^report no", cl, ignore.case = TRUE), arr.ind = TRUE)
      if (nrow(h) > 0 && h[1, 2] < ncol(m)) {
        for (j in (h[1, 2] + 1L):ncol(m)) {
          if (!is.na(cl[h[1, 1], j])) { rn_cell <- cl[h[1, 1], j]; break }
        }
      }
      if (!is.na(rn_cell)) break
    }
  }
  nr <- .st_gas_normalise_report_no(rn_cell)
  header$report_no <- nr$report_no

  tok <- stringr::str_extract(fm$filename, "^[0-9]{4}-[0-9]{4}-[0-9]{2}(-[0-9]{2})?")
  filename_report_no <- if (is.na(tok)) NA_character_ else tok
  review_signals <- list()
  if (!is.na(filename_report_no) && !is.na(nr$report_no) &&
      !identical(gsub("[^0-9]", "", filename_report_no), gsub("[^0-9]", "", nr$report_no))) {
    warnings_vec <- c(warnings_vec, sprintf(
      "%s: filename report number %s disagrees with the REPORT NO cell %s; filed under the cell.",
      fm$filename, filename_report_no, nr$report_no))
    review_signals[[length(review_signals) + 1L]] <- list(
      kind = "report_no_mismatch",
      payload = list(filename_report_no = filename_report_no, report_no = nr$report_no,
                     filename = fm$filename),
      work_order = nr$report_no
    )
  }

  # --- site, from content --------------------------------------------------------------
  site_text <- c(as.vector(front_mat))
  for (s in data_sheets[grepl("^gas\\s+landfil", trimws(data_sheets), ignore.case = TRUE)]) {
    m <- mats[[s]]
    if (length(m)) site_text <- c(site_text, as.vector(m[seq_len(min(6, nrow(m))), , drop = FALSE]))
  }
  site_text <- site_text[!is.na(site_text)]
  nb <- sum(grepl("blaxland", site_text, ignore.case = TRUE))
  nk <- sum(grepl("katoomba", site_text, ignore.case = TRUE))
  if (nb == nk) {
    cli::cli_abort(
      "{.path {path}}: cannot tell the site (Blaxland or Katoomba) from the workbook's own text.",
      class = "sampletidy_parse_error"
    )
  }
  site <- if (nb > nk) "B" else "K"

  # --- dates --------------------------------------------------------------------------------
  sample_date <- .st_gas_serial_to_date(header$sample_date)
  fmt_date <- function(d) if (is.na(d)) NA_character_ else format(d, "%d/%m/%Y")
  header$sample_date <- fmt_date(sample_date)
  bio_date <- as.Date(NA)
  fl <- as.vector(front_mat); fl <- fl[!is.na(fl)]
  note <- fl[grepl("biofilter.*bores.*sampled", fl, ignore.case = TRUE)]
  if (length(note)) {
    mm <- stringr::str_match(note[[1]], "(\\d{1,2})/(\\d{1,2})/(\\d{2,4})")
    if (!is.na(mm[1, 1])) {
      yr <- as.integer(mm[1, 4]); if (yr < 100) yr <- yr + 2000L
      bio_date <- suppressWarnings(as.Date(sprintf("%04d-%02d-%02d", yr, as.integer(mm[1, 3]),
                                                   as.integer(mm[1, 2]))))
    }
  }

  # --- readings ----------------------------------------------------------------------------------
  readings <- list()
  for (s in data_sheets) {
    rs <- .st_gas_sheet_readings(mats[[s]], s, site, is_bio = FALSE)
    for (r in rs) { r$sheet <- s; readings[[length(readings) + 1L]] <- r }
  }
  for (s in bio_sheets) {
    rs <- c(.st_gas_bio_grids(mats[[s]], site),
            .st_gas_sheet_readings(mats[[s]], s, site, is_bio = TRUE))
    for (r in rs) { r$sheet <- s; r$bio <- TRUE; readings[[length(readings) + 1L]] <- r }
  }

  # Cross-sheet uniqueness for building names (A84 refuses repeats).
  feats <- vapply(readings, function(r) r$feature, character(1))

  res_rows <- list(); smp_rows <- list(); skipped <- list()
  flag_kind <- character(0); flag_payload <- list()
  comments <- if (nr$amended) "Amended" else NA_character_
  for (i in seq_along(readings)) {
    r <- readings[[i]]
    ref <- sprintf("%s!%s%d", trimws(r$sheet), .st_gas_col_letters(r$col), r$row)
    num <- suppressWarnings(as.numeric(r$raw))
    if (is.na(num)) {
      reason <- .st_gas_text_reason(r$raw)
      skipped[[length(skipped) + 1L]] <- tibble::tibble(source_ref = ref, reason = reason)
      if (reason == "unrecognised_text") {
        warnings_vec <- c(warnings_vec, sprintf("%s: unrecognised CH4 cell text %s at %s; skipped.",
                                                fm$filename, dQuote(r$raw, FALSE), ref))
      }
      next
    }
    two_dp <- abs(num - round(num, 2)) < 1e-9
    flagged <- !two_dp
    value_raw <- if (two_dp) {
      format(round(num, 2), scientific = FALSE, trim = TRUE)
    } else {
      format(signif(num, 12), scientific = FALSE, trim = TRUE)
    }
    value_num <- as.numeric(value_raw)
    d <- if (isTRUE(r$bio) && !is.na(bio_date)) bio_date else sample_date
    res_rows[[length(res_rows) + 1L]] <- tibble::tibble(
      source_hash = fm$hash, source_ref = ref, work_order = header$report_no,
      revision = 0L, org = "ACIRL", adapter = adapter_tag,
      lab_sample_id = r$feature, sample_type = "Normal", feature_raw = r$feature,
      analyte_raw = "CH4 Reading % v/v", cas_number = NA_character_,
      method_raw = NA_character_, total_or_filtered = NA_character_,
      units_raw = "%", value_raw = value_raw, value_num = value_num,
      value_chr = NA_character_, below_detection = isTRUE(value_num == 0),
      rl = NA_real_, lab_qualifier = NA_character_,
      analysed_date = as.Date(NA_character_), comments = comments, confidence = 1
    )
    smp_rows[[length(smp_rows) + 1L]] <- tibble::tibble(
      source_hash = fm$hash, source_ref = ref, work_order = header$report_no,
      org = "ACIRL", adapter = adapter_tag, lab_sample_id = r$feature,
      feature_raw = r$feature, sample_datetime_raw = fmt_date(d),
      sample_date_start_raw = NA_character_, sample_type = "Normal",
      parent_sample = NA_character_, matrix_raw = "Gas", sampler = header$sampled_by,
      comments = comments, confidence = 1
    )
    flag_kind <- c(flag_kind, if (flagged) "precision_exceeded" else NA_character_)
    flag_payload <- c(flag_payload, list(if (flagged) {
      list(kind = "precision_exceeded", feature_raw = r$feature, value_raw = value_raw,
           source_ref = ref, reason = "reading has more than 2 decimal places; withheld, not rounded")
    } else {
      NULL
    }))
  }

  results <- if (length(res_rows) == 0) ir_results() else do.call(ir_results, as.list(dplyr::bind_rows(res_rows)))
  samples <- if (length(smp_rows) == 0) ir_samples() else do.call(ir_samples, as.list(dplyr::bind_rows(smp_rows)))
  # Adapter-raised review flags (CONTRACT A22): only attached when something is
  # flagged, so an ordinary file keeps the pinned IR shape exactly.
  # The filename/REPORT NO mismatch is INFORMATIONAL (A88 `review_withhold =
  # FALSE`): every row commits under the cell's number AND one folded review
  # item is opened. A >2 dp reading is WITHHELD, and wins on its own row.
  mismatch <- length(review_signals) > 0 && nrow(results) > 0
  if (any(!is.na(flag_kind)) || mismatch) {
    n_res <- nrow(results)
    nr_kind <- rep(NA_character_, n_res)
    nr_payload <- vector("list", n_res)
    nr_withhold <- rep(TRUE, n_res)
    if (mismatch) {
      sig <- review_signals[[1]]
      nr_kind[] <- sig$kind
      nr_payload[] <- list(sig$payload)
      nr_withhold[] <- FALSE
    }
    withheld <- !is.na(flag_kind)
    nr_kind[withheld] <- flag_kind[withheld]
    for (j in which(withheld)) nr_payload[[j]] <- flag_payload[[j]]
    nr_withhold[withheld] <- TRUE
    results$needs_review <- !is.na(nr_kind)
    results$review_kind <- nr_kind
    results$review_payload <- nr_payload
    results$review_withhold <- nr_withhold
  }

  skipped_df <- if (length(skipped) == 0) {
    tibble::tibble(source_ref = character(0), reason = character(0))
  } else {
    dplyr::bind_rows(skipped)
  }

  list(
    results = results,
    samples = samples,
    report = list(
      n_rows = nrow(results) + nrow(samples),
      n_by_sample_type = table(results$sample_type),
      skipped = skipped_df,
      header = header,
      warnings = warnings_vec,
      campaign = "Monthly gas monitoring",
      site = site,
      filename_report_no = filename_report_no,
      review_signals = review_signals,
      als_work_orders = character(0),
      n_water_sheets = 0L,
      als_candidates = tibble::tibble(
        source_ref = character(0), feature_raw = character(0),
        analyte_raw = character(0), units_raw = character(0),
        value_raw = character(0), transcription_label = logical(0)
      ),
      feature_aliases = tibble::tibble(
        source_ref = character(0), feature_raw = character(0),
        label = character(0), alias = character(0)
      )
    )
  )
}
