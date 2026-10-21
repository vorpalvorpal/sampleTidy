# Test-time workbook builders for the ACIRL monthly-gas adapter (PLAN-17).
#
# Only DEFINES functions - no top-level calls - so it is safe to source before
# R/adapter-acirl-gas.R exists.
#
# Every workbook is built in a tempdir at test time (the test-dust-dating.R
# pattern). They are NOT written under fixtures/acirl/: build_e2e_input_dir()
# copies that directory wholesale into the e2e pipeline tests, and gas files
# there would change their counts.
#
# GEOMETRY - copied cell for cell from the real workbooks (read-only dumps of
# 2400-7127-05 May 2021, 2400-7399-08-01 Aug 2024, 2400-7453-07-01 Jul 2025,
# 2400-7453-03-01 Mar 2026, 2400-7538-05-01 Weekly and 2400-7454-12-01 Dec 2025
# Katoomba, 2026-10-16). VALUES, names and report numbers are synthetic.
#
#   Blaxland 2025+  sheets `Front Page`, `Gas Landfil #1`, `Gas Landfil #2`,
#                   `Gas Landfil #3`, `MAP`. Landfill header row 7, pairs
#                   (Location, `CH4 Reading % v/v`) at cols 1-8; `REPORT NO. :`
#                   r5 c3 (value c4). Titles r1-3 at c1 (#1) or c2 (#2/#3).
#                   Mar-2026: #1/#2 shifted ONE column right (cols 2-9, RN at
#                   r5 c4/c5, #2 titles at c3). Note rows `NS: ...`/`NR: ...`
#                   in col 1 below a blank row. A wholly blank row can sit
#                   INSIDE the grid (Mar-2026 #2 row 27: G301/G326/G351/G376
#                   absent, data resumes on row 28).
#   Weekly          as 2025, `Gas Landfil #3` holds G382-G384 then bare
#                   numbers `1`-`21` in the same Location column.
#   Blaxland 2024   `Gas Landfil #1/#2` header row 7 + `Gas Buildings `
#                   (TRAILING SPACE) header row 8, 3 cols (Location, Building
#                   Reference, CH4), Location filled down (blank below first).
#   Blaxland 2021   header row 11 on every sheet, RN at r8 c3/c4. Landfil #2
#                   has `Note` (r38 c1) / `G123 | Working Face` (r39) and an
#                   `Additional Gas Point Coordinates` table (r41-45) whose
#                   header row starts with `Location`. Front page title is
#                   `ALS / ANALYSIS AND TESTING REPORT`; site only in REPORT ON.
#                   REPORT NO cell `24007127 - 05 Amended`.
#   Katoomba        `Gas Landfil #1`, `Gas Landfil #2 ` (TRAILING SPACE): header
#                   row 6, pairs at cols 2-9, header text
#                   `CH4 Reading               % v/v` (run of spaces), RN r5
#                   c4/c5. `Gas Building 1/2/3`: header r7 cols 2-4, RN r5 c2/c3.
#                   `Biofliter and Bores` (sic): `North Corner` r7 c2, grid
#                   r8-9 c2-4; `Front of Buildings` r11 c3, grid r12-13 c2-4;
#                   `GAS MONITORING BORES` r15 c2; header r17 (Location,
#                   Reference, CH4) at c2-4; `Gas Bore | MP1..MP4` r18-21.
#                   Front page: title r12 c1 `BMCC Katoomba Recycling Facility
#                   Gas Sampling`; keys at c4, values at c6; SAMPLE DATE r25,
#                   optional note r26 c6 `Biofilter and Bores sampled 5/1/26`.

gas_serial <- function(d) as.numeric(as.Date(d) - as.Date("1899-12-30"))

gx_set <- function(wb, sheet, row, col, value) {
  if (is.null(value) || length(value) == 0 || (length(value) == 1 && is.na(value))) {
    return(invisible(NULL))
  }
  openxlsx::writeData(wb, sheet, x = value, startRow = row, startCol = col,
                      colNames = FALSE, rowNames = FALSE)
}

# ---- front pages --------------------------------------------------------------

gx_front_blaxland <- function(wb, report_no, sample_date,
                              report_on = "July 2025 Gas Monitoring",
                              sampled_by = "J. Tester & A. Offsider") {
  s <- "Front Page"
  openxlsx::addWorksheet(wb, s)
  gx_set(wb, s, 1, 1, "ACIRL Pty Ltd")
  gx_set(wb, s, 2, 1, "ABN 00 000 000 000")
  gx_set(wb, s, 3, 1, "Unit 0, 1 Test street ")
  gx_set(wb, s, 4, 1, "Lithgow, NSW, 2790, Australia")
  gx_set(wb, s, 5, 1, "Tel: +61 2 0000000")
  gx_set(wb, s, 7, 1, "ALS COAL DIVISION")
  gx_set(wb, s, 8, 1, "BMCC BLAXLAND WASTE MANAGEMENT FACILITY")
  gx_set(wb, s, 9, 1, "MONTHLY GAS  REPORT")
  gx_set(wb, s, 11, 4, "REPORT TO:");   gx_set(wb, s, 11, 6, "Test Recipient")
  gx_set(wb, s, 12, 6, "1 Test Rd, Blaxland NSW 2774")
  gx_set(wb, s, 15, 4, "REPORT ON:");   gx_set(wb, s, 15, 6, "BMCC")
  gx_set(wb, s, 16, 6, "Blaxland WMF")
  gx_set(wb, s, 17, 6, report_on)
  gx_set(wb, s, 20, 4, "REPORT NO:");   gx_set(wb, s, 20, 6, report_no)
  gx_set(wb, s, 22, 4, "SAMPLED BY:");  gx_set(wb, s, 22, 6, sampled_by)
  gx_set(wb, s, 24, 4, "SAMPLE DATE:"); gx_set(wb, s, 24, 6, gas_serial(sample_date))
  gx_set(wb, s, 26, 4, "REPORTED BY:"); gx_set(wb, s, 26, 6, "A. Reporter")
  gx_set(wb, s, 28, 4, "DATE:");        gx_set(wb, s, 28, 6, gas_serial(sample_date) + 15.4392)
  gx_set(wb, s, 35, 5, "A. Signatory")
  gx_set(wb, s, 36, 4, "Environmental Project/Quality Officer- Lithgow NSW")
}

gx_front_blaxland_2021 <- function(wb, report_no, sample_date,
                                   sampled_by = "J. Tester and A. Offsider") {
  s <- "Front Page"
  openxlsx::addWorksheet(wb, s)
  gx_set(wb, s, 1, 1, "ALS")
  gx_set(wb, s, 2, 1, "ANALYSIS AND TESTING REPORT")
  gx_set(wb, s, 5, 4, "REPORT TO:");    gx_set(wb, s, 5, 6, "Test Recipient")
  gx_set(wb, s, 6, 6, "Second Recipient")
  gx_set(wb, s, 8, 4, "REPORT ON:");    gx_set(wb, s, 8, 6, "BMCC")
  gx_set(wb, s, 9, 6, "Blaxland WMF")
  gx_set(wb, s, 10, 6, "Monthly Gas Monitoring")
  gx_set(wb, s, 13, 4, "REPORT NO:");   gx_set(wb, s, 13, 6, report_no)
  gx_set(wb, s, 15, 4, "SAMPLED BY:");  gx_set(wb, s, 15, 6, sampled_by)
  gx_set(wb, s, 17, 4, "SAMPLE DATE:"); gx_set(wb, s, 17, 6, gas_serial(sample_date))
  gx_set(wb, s, 19, 4, "REPORTED BY:"); gx_set(wb, s, 19, 6, "A. Reporter")
  gx_set(wb, s, 34, 1, "Accredited for compliance with ISO/IEC 17025")
  gx_set(wb, s, 36, 1, "These reported results only relate to the items sampled and tested")
}

# `title` lets a test build a workbook whose content names NEITHER site.
gx_front_katoomba <- function(wb, report_no, sample_date, note = NULL,
                              title = "BMCC Katoomba Recycling Facility Gas Sampling",
                              address = "1 Test Rd, Katoomba NSW 2780",
                              sampled_by = "J. Tester & A. Offsider") {
  s <- "Front Page"
  openxlsx::addWorksheet(wb, s)
  gx_set(wb, s, 1, 1, "Page 1 of 8")
  gx_set(wb, s, 4, 1, "ACIRL Pty Ltd")
  gx_set(wb, s, 5, 1, "ABN 00 000 000 000")
  gx_set(wb, s, 6, 1, "Unit 0, 1 Test Street")
  gx_set(wb, s, 7, 1, "Lithgow, NSW, 2790, Australia")
  gx_set(wb, s, 8, 1, "Tel: +61 2 0000000")
  gx_set(wb, s, 11, 1, "ALS Coal Division")
  gx_set(wb, s, 12, 1, title)
  gx_set(wb, s, 15, 4, "REPORT TO:");   gx_set(wb, s, 15, 6, "Test Recipient")
  gx_set(wb, s, 16, 6, address)
  gx_set(wb, s, 19, 4, "REPORT ON:");   gx_set(wb, s, 19, 6, "December 2025 Monthly Gas Monitoring")
  gx_set(wb, s, 21, 4, "REPORT NO:");   gx_set(wb, s, 21, 6, report_no)
  gx_set(wb, s, 23, 4, "SAMPLED BY:");  gx_set(wb, s, 23, 6, sampled_by)
  gx_set(wb, s, 25, 4, "SAMPLE DATE:"); gx_set(wb, s, 25, 6, gas_serial(sample_date))
  gx_set(wb, s, 26, 6, note)
  gx_set(wb, s, 28, 4, "REPORTED BY:"); gx_set(wb, s, 28, 6, "A. Reporter")
  gx_set(wb, s, 30, 4, "DATE:");        gx_set(wb, s, 30, 6, gas_serial(sample_date) + 20)
  gx_set(wb, s, 32, 1, "These reported results only relate to the items sampled and tested")
}

# ---- data sheets ----------------------------------------------------------------

# `pairs`: list of up to 4 named lists (Location -> value). A value may be
# numeric, a text code, or NA (blank). `rows`: optional explicit sheet rows for
# each entry of a pair (to leave a blank row INSIDE the grid); default
# consecutive from header_row + 1. `notes`: list(list(row, col, text)).
gx_landfill_sheet <- function(wb, name, pairs, header_row = 7L, first_col = 1L,
                              title_col = 1L, rn_row = 5L, rn_col = 3L,
                              report_no, titles = c("ALS COAL DIVISION",
                                                    "BMCC BLAXLAND WASTE MANAGEMENT FACILITY",
                                                    "MONTHLY GAS  REPORT"),
                              title_rows = 1:3, ch4_header = "CH4 Reading % v/v",
                              rows = NULL, notes = list(), extra = list()) {
  openxlsx::addWorksheet(wb, name)
  title_col <- rep_len(title_col, length(titles))
  for (i in seq_along(titles)) gx_set(wb, name, title_rows[[i]], title_col[[i]], titles[[i]])
  gx_set(wb, name, rn_row, rn_col, "REPORT NO. :")
  gx_set(wb, name, rn_row, rn_col + 1L, report_no)
  for (k in 0:3) {
    gx_set(wb, name, header_row, first_col + 2L * k, "Location")
    gx_set(wb, name, header_row, first_col + 2L * k + 1L, ch4_header)
  }
  for (k in seq_along(pairs)) {
    p <- pairs[[k]]
    r <- if (is.null(rows)) header_row + seq_along(p) else rows[seq_along(p)]
    for (j in seq_along(p)) {
      gx_set(wb, name, r[[j]], first_col + 2L * (k - 1L), names(p)[[j]])
      gx_set(wb, name, r[[j]], first_col + 2L * (k - 1L) + 1L, p[[j]])
    }
  }
  for (n in notes) gx_set(wb, name, n[[1]], n[[2]], n[[3]])
  for (e in extra) gx_set(wb, name, e[[1]], e[[2]], e[[3]])
  invisible(NULL)
}

# `entries`: data.frame(loc, ref, val) - `loc` NA where the real sheet leaves
# the cell blank (fill-down). `val` is a list column so numbers and text mix.
gx_building_sheet <- function(wb, name, entries, header_row, first_col = 1L,
                              rn_row = 5L, report_no, ref_label = "Building Reference",
                              titles, title_rows = 1:3, title_col = 1L) {
  openxlsx::addWorksheet(wb, name)
  title_col <- rep_len(title_col, length(titles))
  for (i in seq_along(titles)) gx_set(wb, name, title_rows[[i]], title_col[[i]], titles[[i]])
  gx_set(wb, name, rn_row, first_col, "REPORT NO. :")
  gx_set(wb, name, rn_row, first_col + 1L, report_no)
  gx_set(wb, name, header_row, first_col, "Location")
  gx_set(wb, name, header_row, first_col + 1L, ref_label)
  gx_set(wb, name, header_row, first_col + 2L, "CH4 Reading % v/v")
  for (i in seq_len(nrow(entries))) {
    r <- header_row + i
    gx_set(wb, name, r, first_col, entries$loc[[i]])
    gx_set(wb, name, r, first_col + 1L, entries$ref[[i]])
    gx_set(wb, name, r, first_col + 2L, entries$val[[i]])
  }
  invisible(NULL)
}

gx_entries <- function(...) {
  x <- list(...)
  data.frame(
    loc = vapply(x, function(e) if (is.na(e[[1]])) NA_character_ else e[[1]], character(1)),
    ref = vapply(x, function(e) e[[2]], character(1)),
    val = I(lapply(x, function(e) e[[3]])),
    stringsAsFactors = FALSE
  )
}

gx_map_sheet <- function(wb) {
  openxlsx::addWorksheet(wb, "MAP")
  gx_set(wb, "MAP", 1, 1, "MAP")
}

gx_save <- function(wb, dir, filename) {
  path <- file.path(dir, filename)
  openxlsx::saveWorkbook(wb, path, overwrite = TRUE)
  path
}

# ---- family: Blaxland 2025+ (incl. Mar-2026 shift and the Weekly sheet) --------
#
# DEFAULT CONTENT (expectations in the tests are hard-coded against this):
#   #1  17 numeric + NS (G200), `does not exist` (G201), `No Access` (G224)
#       G199 = 0.0299999999999999 (binary noise -> 0.03)
#   #2  25 numeric (incl. B.G368 = 0, B.G372 = 0.01) + NS (G308), NR (G369),
#       `Not on the map` (G371); rows 8-12, BLANK row 13, rows 14-15
#   #3  G382-G384 (3 numeric)                           [monthly]
#       G382-G384 = NR, then points 1-21 (21 numeric)    [weekly]
gas_b2025_l1 <- function() list(
  list(G197 = 0.01, G198 = 0, G199 = 0.0299999999999999, G200 = "NS", G201 = "does not exist"),
  list(G222 = 0, G223 = 0.02, G224 = "No Access", G225 = 0, G226 = 0),
  list(G247 = 0, G248 = 0, G249 = 0, G250 = 0.17, G251 = 0),
  list(G272 = 0, G273 = 0, G274 = 0, G275 = 0, G276 = 0.04)
)
gas_b2025_l2 <- function() list(
  list(G282 = 0, G283 = 0.01, G284 = 0, G285 = 0, G286 = 0, G288 = 0.02, G289 = 0),
  list(G307 = 0, G308 = "NS", G309 = 0, G310 = 0, G311 = 0, G313 = 0, G314 = 0),
  list(G332 = 0, G333 = 0, G334 = 0, G335 = 0, G336 = 0, G338 = 0, G339 = 0),
  list(G368 = 0, G369 = "NR", G370 = 0, G371 = "Not on the map", G372 = 0.01, G374 = 0, G375 = 0)
)
gas_b2025_l2_rows <- c(8:12, 14:15)            # row 13 wholly blank (Mar-2026 shape)
gas_weekly_points <- function() {
  v <- as.list(rep(0, 21)); names(v) <- as.character(1:21)
  v[["1"]] <- 0.07; v[["2"]] <- 0.02; v[["11"]] <- 0.18; v[["15"]] <- 0.22
  v
}

build_gas_blaxland_2025 <- function(dir, report_no = "2400-9901-07-01",
                                    sample_date = "2025-07-22",
                                    filename = paste0(report_no, " July 2025 Monthly Gas Monitoring Blaxland WMF.xlsx"),
                                    shift = 0L, weekly = FALSE,
                                    l1 = gas_b2025_l1(), l2 = gas_b2025_l2(),
                                    l2_rows = gas_b2025_l2_rows, l3 = NULL,
                                    front_report_no = report_no) {
  wb <- openxlsx::createWorkbook()
  gx_front_blaxland(wb, front_report_no, sample_date)
  gx_landfill_sheet(wb, "Gas Landfil #1", l1, first_col = 1L + shift, title_col = 1L + shift,
                    rn_col = 3L + shift, report_no = report_no,
                    notes = list(list(14, 1, "NS: Unable to sample due to safety concerns")))
  gx_landfill_sheet(wb, "Gas Landfil #2", l2, first_col = 1L + shift, title_col = 2L + shift,
                    rn_col = 3L + shift, report_no = report_no, rows = l2_rows,
                    notes = list(list(17, 1, "NS: Unable to sample due to safety concerns"),
                                 list(18, 1, "NR: Not requested")))
  if (is.null(l3)) {
    l3 <- if (isTRUE(weekly)) {
      list(c(list(G382 = "NR", G383 = "NR", G384 = "NR"), gas_weekly_points()))
    } else {
      list(list(G382 = 0, G383 = 0.01, G384 = 0))
    }
  }
  l3_notes <- if (isTRUE(weekly)) {
    list(list(33, 1, "NS: Unable to sample due to very long grass"),
         list(34, 1, "NR: Not requested"))
  } else {
    list()
  }
  gx_landfill_sheet(wb, "Gas Landfil #3", l3, title_col = 2L, report_no = report_no,
                    notes = l3_notes)
  gx_map_sheet(wb)
  gx_save(wb, dir, filename)
}

# ---- family: Blaxland 2024 (landfill + `Gas Buildings `) ----------------------
#
#   #1  12 numeric; #2  11 numeric + `Not on the map` (G368)
#   Gas Buildings  8 numeric; `Storage Shed re used / Right Wall` repeats -> #2
build_gas_blaxland_2024 <- function(dir, report_no = "2400-9902-08-01",
                                    sample_date = "2024-08-07",
                                    filename = paste0(report_no, " August 2024 Monthly Gas Monitoring Blaxland WMF.xlsx")) {
  wb <- openxlsx::createWorkbook()
  gx_front_blaxland(wb, report_no, sample_date, report_on = "August 2024 Gas Monitoring")
  gx_landfill_sheet(wb, "Gas Landfil #1", list(
    list(G182 = 0.01, G183 = 0, G184 = 0),
    list(G207 = 0, G208 = 0, G209 = 0.02),
    list(G232 = 0, G233 = 0, G234 = 0),
    list(G257 = 0, G258 = 0, G259 = 0)
  ), report_no = report_no)
  gx_landfill_sheet(wb, "Gas Landfil #2", list(
    list(G282 = 0, G283 = 0, G284 = 0.05),
    list(G307 = 0, G308 = 0, G309 = 0),
    list(G332 = 0, G333 = 0, G334 = 0),
    list(G357 = 0, G358 = 0, G368 = "Not on the map")
  ), title_col = 2L, report_no = report_no)
  gx_building_sheet(wb, "Gas Buildings ", gx_entries(
    list("Toilets", "Right Side", 0),
    list(NA, "Left Side", 0),
    list("Weigh Bridge Building", "Meal Room", 0),
    list(NA, "Toilet", 0),
    list("Storage Shed re used", "Right Wall", 0),
    list(NA, "Back Wall", 0.01),
    list(NA, "Right Wall", 0),
    list("Out side", "Reused shed", 0.0299999999999999)
  ), header_row = 8L, report_no = report_no,
  titles = c("ALS COAL DIVISION", "BMCC BLAXLAND WASTE MANAGEMENT FACILITY", "MONTHLY GAS  REPORT"))
  gx_map_sheet(wb)
  gx_save(wb, dir, filename)
}

# ---- family: Blaxland 2021 (header row 11, notes, coordinates table) ----------
#
#   #1  12 numeric (G1 = 0, G3 = 0.17); #2  24 numeric (G176-G181 in pair 4)
#   then Note / `G103 | Working Face` / the coordinates table -> nothing.
#   Gas Buildings  4 numeric.
build_gas_blaxland_2021 <- function(dir, report_no = "24009902 - 05 Amended",
                                    sample_date = "2021-05-06",
                                    filename = "2400-9902-05 May 2021 Monthly Gas Monitoring Blaxland WMF.xlsx") {
  wb <- openxlsx::createWorkbook()
  gx_front_blaxland_2021(wb, report_no, sample_date)
  t21 <- c("ALS", "ANALYSIS AND TESTING REPORT", "BMCC", "BLAXLAND WMF MONTHLY GAS MONITORING")
  gx_landfill_sheet(wb, "Gas Landfil #1", list(
    list(G1 = 0, G2 = 0, G3 = 0.17),
    list(G26 = 0, G27 = 0, G28 = 0),
    list(G51 = 0, G52 = 0, G53 = 0),
    list(G76 = 0, G77 = 0, G78 = 0)
  ), header_row = 11L, rn_row = 8L, rn_col = 3L, report_no = report_no,
  titles = t21, title_rows = c(1, 2, 5, 6), title_col = c(2L, 2L, 3L, 2L))
  coord <- list(
    list(22, 1, "Additional Gas Point Coordinates"),
    list(23, 1, "Location"), list(23, 2, "Latitude"), list(23, 3, "Longitude"),
    list(23, 4, "UTM Easting"), list(23, 5, "UTM Northing"), list(23, 6, "UTM Zone")
  )
  for (i in 1:3) {
    r <- 23 + i
    coord <- c(coord, list(
      list(r, 1, paste0("G", 178 + i)), list(r, 2, -33.7 - i / 1000),
      list(r, 3, 150.6 + i / 1000), list(r, 4, 278900 + i), list(r, 5, 6265000 + i),
      list(r, 6, "56H")
    ))
  }
  gx_landfill_sheet(wb, "Gas Landfil #2", list(
    list(G101 = 0, G102 = 0, G103 = 0, G104 = 0, G105 = 0, G106 = 0),
    list(G126 = 0, G127 = 0, G128 = 0, G129 = 0, G130 = 0, G131 = 0),
    list(G151 = 0, G152 = 0, G153 = 0, G154 = 0, G155 = 0, G156 = 0),
    list(G176 = 0, G177 = 0, G178 = 0, G179 = 0, G180 = 0.01, G181 = 0.01)
  ), header_row = 11L, rn_row = 8L, rn_col = 3L, report_no = report_no,
  titles = t21, title_rows = c(1, 2, 5, 6), title_col = c(2L, 2L, 3L, 2L),
  notes = list(list(19, 1, "Note"), list(20, 1, "G103"), list(20, 2, "Working Face")),
  extra = coord)
  gx_building_sheet(wb, "Gas Buildings ", gx_entries(
    list("Toilets", "Right Side", 0),
    list(NA, "Left Side", 0),
    list("Lunch Room", "Centre", 0),
    list("Main Office", "Centre", 0)
  ), header_row = 11L, rn_row = 8L, report_no = report_no,
  titles = t21, title_rows = c(1, 2, 5, 6))
  gx_map_sheet(wb)
  gx_save(wb, dir, filename)
}

# ---- family: Katoomba ------------------------------------------------------------
#
#   #1  11 numeric + `NS ` (G263, trailing space); #2  12 numeric (incl. G365/366,
#       which are ACIRL TEMPLATE SLOTS - no such probe at Katoomba; migrations
#       032/034: the adapter skips them, so they yield no result)
#   Building 1: 4 (`Air conditioner` in two DIFFERENT buildings - no suffix)
#   Building 2: 5 (`Main Recycle area   ...(Drop Off)` whitespace run;
#                  `Re-use Center / Power point back wall` repeats -> #2)
#   Building 3: 4 (`Meeting Room / Window wall 2` repeats -> #2)
#   Biofilter grids 12 (North Corner R1C2 = 0.01, R2C3 = 0.02;
#                      Front of Buildings R2C1 = 0.03) + bores MP1-MP4 (MP3 = 0.01)
gas_k_ch4_header <- "CH4 Reading               % v/v"
gas_k_l1 <- function() list(
  list(G186 = 0, G187 = 0.01, G188 = 0),
  list(G211 = 0, G212 = 0, G213 = 0),
  list(G236 = 0, G237 = 0, G238 = 0),
  list(G261 = 0, G262 = 0, G263 = "NS ")
)
gas_k_l2 <- function() list(
  list(G287 = 0, G288 = 0, G289 = 0),
  list(G312 = 0, G313 = 0, G314 = 0),
  list(G337 = 0, G338 = 0, G339 = 0),
  list(G362 = 0, G365 = 0, G366 = 0)
)
gas_k_titles <- c("ALS Coal Division", "BMCC Katoomba Recycling Facility Gas Sampling")

build_gas_katoomba <- function(dir, report_no = "2400-9903-12-01",
                               sample_date = "2025-12-10",
                               filename = paste0(report_no, " December 2025 Gas Monitoring Katoomba WMF.xlsx"),
                               note = NULL, grid_labels = TRUE,
                               front_title = "BMCC Katoomba Recycling Facility Gas Sampling",
                               front_address = "1 Test Rd, Katoomba NSW 2780",
                               sheet_titles = gas_k_titles,
                               l1 = gas_k_l1(), l2 = gas_k_l2()) {
  wb <- openxlsx::createWorkbook()
  gx_front_katoomba(wb, report_no, sample_date, note = note, title = front_title,
                    address = front_address)
  kl <- function(name, pairs) {
    gx_landfill_sheet(wb, name, pairs, header_row = 6L, first_col = 2L, title_col = c(1L, 1L, 2L),
                      rn_row = 5L, rn_col = 4L, report_no = report_no,
                      titles = c(sheet_titles, "MONTHLY GAS MONITORING"),
                      title_rows = c(1, 2, 4), ch4_header = gas_k_ch4_header)
  }
  kl("Gas Landfil #1", l1)
  kl("Gas Landfil #2 ", l2)
  kb <- function(name, entries) {
    gx_building_sheet(wb, name, entries, header_row = 7L, first_col = 2L, rn_row = 5L,
                      report_no = report_no, titles = c(sheet_titles, "MONTHLY GAS MONITORING"),
                      title_rows = c(1, 2, 4), title_col = c(1L, 1L, 2L))
  }
  kb("Gas Building 1", gx_entries(
    list("Office", "Window near desk", 0),
    list(NA, "Air conditioner", 0),
    list("Meal Room", "Air conditioner", 0),
    list(NA, "Power point (Sink)", 0)
  ))
  kb("Gas Building 2", gx_entries(
    list("Main Recycle area                  (Drop Off)", "Power point near hose reel", 0.01),
    list(NA, "Shower drain below stairs", 0.01),
    list("Re-use Center", "Power point back wall", 0),
    list(NA, "Office window", 0),
    list(NA, "Power point back wall", 0)
  ))
  kb("Gas Building 3", gx_entries(
    list("Meeting Room", "Door wall 1", 0),
    list(NA, "Window wall 2", 0),
    list(NA, "Window wall 2", 0),
    list("Kitchen", "Sink", 0)
  ))
  s <- "Biofliter and Bores"
  openxlsx::addWorksheet(wb, s)
  gx_set(wb, s, 1, 1, sheet_titles[[1]]); gx_set(wb, s, 2, 1, sheet_titles[[2]])
  gx_set(wb, s, 4, 2, "MONTHLY GAS MONITORING")
  gx_set(wb, s, 5, 2, "REPORT NO. :"); gx_set(wb, s, 5, 3, report_no)
  if (isTRUE(grid_labels)) gx_set(wb, s, 7, 2, "North Corner")
  north <- list(c(0, 0.01, 0), c(0, 0, 0.02))
  for (i in 1:2) for (j in 1:3) gx_set(wb, s, 7 + i, 1 + j, north[[i]][[j]])
  if (isTRUE(grid_labels)) gx_set(wb, s, 11, 3, "Front of Buildings")
  front <- list(c(0, 0, 0), c(0.03, 0, 0))
  for (i in 1:2) for (j in 1:3) gx_set(wb, s, 11 + i, 1 + j, front[[i]][[j]])
  gx_set(wb, s, 15, 2, "GAS MONITORING BORES")
  gx_set(wb, s, 17, 2, "Location"); gx_set(wb, s, 17, 3, "Reference")
  gx_set(wb, s, 17, 4, "CH4 Reading % v/v")
  bores <- c(MP1 = 0, MP2 = 0, MP3 = 0.01, MP4 = 0)
  for (i in seq_along(bores)) {
    gx_set(wb, s, 17 + i, 2, "Gas Bore")
    gx_set(wb, s, 17 + i, 3, names(bores)[[i]])
    gx_set(wb, s, 17 + i, 4, bores[[i]])
  }
  gx_map_sheet(wb)
  gx_save(wb, dir, filename)
}

# ---- expected feature names, hard-coded from the DEFAULT content above ----------

gas_expected_b2025_monthly <- function() {
  c(paste0("B.G", c(197, 198, 199, 222, 223, 225, 226, 247:251, 272:276)),
    paste0("B.G", c(282:286, 288, 289, 307, 309:311, 313, 314, 332:336, 338, 339,
                    368, 370, 372, 374, 375)),
    paste0("B.G", 382:384))
}

gas_expected_katoomba <- function() {
  c(paste0("K.G", c(186:188, 211:213, 236:238, 261, 262)),
    paste0("K.G", c(287:289, 312:314, 337:339, 362)),   # G365/G366: template slots, skipped
    "K.Office - Window near desk", "K.Office - Air conditioner",
    "K.Meal Room - Air conditioner", "K.Meal Room - Power point (Sink)",
    "K.Main Recycle area (Drop Off) - Power point near hose reel",
    "K.Main Recycle area (Drop Off) - Shower drain below stairs",
    "K.Re-use Center - Power point back wall", "K.Re-use Center - Office window",
    "K.Re-use Center - Power point back wall #2",
    "K.Meeting Room - Door wall 1", "K.Meeting Room - Window wall 2",
    "K.Meeting Room - Window wall 2 #2", "K.Kitchen - Sink",
    as.vector(outer(c("K.Biofilter North Corner", "K.Front of Buildings"),
                    paste0("R", rep(1:2, each = 3), "C", rep(1:3, 2)), paste)),
    paste0("K.MP_", 1:4))
}

# ---- adapter accessors ------------------------------------------------------------

# Aborts with a clear message when the adapter is missing, so every test that
# needs it fails on THAT, not on "attempt to apply non-function".
gas_adapter <- function() {
  sampleTidy:::register_builtin_adapters()
  ad <- sampleTidy:::adapter_registry()[["acirl_gas_xlsx"]]
  if (is.null(ad)) {
    stop("acirl_gas_xlsx adapter is not registered (R/adapter-acirl-gas.R not built yet)",
         call. = FALSE)
  }
  ad
}

gas_parse <- function(path) gas_adapter()$parse(path, sampleTidy:::file_meta(path))

gas_value_of <- function(out, feature) {
  out$results$value_num[out$results$feature_raw == feature]
}
