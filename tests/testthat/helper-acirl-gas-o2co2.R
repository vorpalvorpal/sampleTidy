# Test-time workbook builders for the O2 / CO2 columns of the ACIRL gas
# adapter. Only DEFINES functions (no top-level calls). Reuses gx_* from
# helper-acirl-gas.R; all site, feature and report names are synthetic.
#
# GEOMETRY: a landfill block is Location | CH4 | <extra columns>, repeated to
# the right (block width = 2 + number of extra columns); a building block is
# Location | Reference | CH4 | <extra columns>. `extra` is an ordered named
# character vector: names are the row fields (o2, co2, bal, note), values are
# the printed header texts. Header row 7 (landfill) and 8 (buildings) as in
# the Northvale 2025 / 2024 workbooks.

gxo_extra_default <- function() c(o2 = "O2 Reading % v/v", co2 = "CO2 Reading % v/v")

# One data row. NA = blank cell. `loc` and `ref` are the printed names.
gxo_row <- function(loc = NA_character_, ref = NA_character_, ch4 = NA, o2 = NA,
                    co2 = NA, bal = NA, note = NA) {
  list(loc = loc, ref = ref, ch4 = ch4, o2 = o2, co2 = co2, bal = bal, note = note)
}

# A landfill row keyed by point name (G197 ...).
gxo_pt <- function(loc, ch4 = NA, o2 = NA, co2 = NA, bal = NA, note = NA) {
  gxo_row(loc = loc, ch4 = ch4, o2 = o2, co2 = co2, bal = bal, note = note)
}

gxo_landfill_sheet <- function(wb, name, blocks, extra = gxo_extra_default(),
                               header_row = 7L, first_col = 1L, report_no,
                               ch4_header = "CH4 Reading % v/v") {
  openxlsx::addWorksheet(wb, name)
  gx_set(wb, name, 1, 1, "ALS COAL DIVISION")
  gx_set(wb, name, 2, 1, "EXORG NORTHVALE WASTE MANAGEMENT FACILITY")
  gx_set(wb, name, 3, 1, "MONTHLY GAS  REPORT")
  gx_set(wb, name, 5, 3, "REPORT NO. :")
  gx_set(wb, name, 5, 4, report_no)
  width <- 2L + length(extra)
  for (k in seq_along(blocks)) {
    c0 <- first_col + width * (k - 1L)
    gx_set(wb, name, header_row, c0, "Location")
    gx_set(wb, name, header_row, c0 + 1L, ch4_header)
    for (j in seq_along(extra)) gx_set(wb, name, header_row, c0 + 1L + j, extra[[j]])
    rows <- blocks[[k]]
    for (i in seq_along(rows)) {
      r <- header_row + i
      gx_set(wb, name, r, c0, rows[[i]]$loc)
      gx_set(wb, name, r, c0 + 1L, rows[[i]]$ch4)
      for (j in seq_along(extra)) gx_set(wb, name, r, c0 + 1L + j, rows[[i]][[names(extra)[[j]]]])
    }
  }
  invisible(NULL)
}

gxo_building_sheet <- function(wb, name, rows, extra = gxo_extra_default(),
                               header_row = 8L, first_col = 1L, report_no) {
  openxlsx::addWorksheet(wb, name)
  gx_set(wb, name, 1, 1, "ALS COAL DIVISION")
  gx_set(wb, name, 2, 1, "EXORG NORTHVALE WASTE MANAGEMENT FACILITY")
  gx_set(wb, name, 3, 1, "MONTHLY GAS  REPORT")
  gx_set(wb, name, 5, first_col, "REPORT NO. :")
  gx_set(wb, name, 5, first_col + 1L, report_no)
  gx_set(wb, name, header_row, first_col, "Location")
  gx_set(wb, name, header_row, first_col + 1L, "Building Reference")
  gx_set(wb, name, header_row, first_col + 2L, "CH4 Reading % v/v")
  for (j in seq_along(extra)) gx_set(wb, name, header_row, first_col + 2L + j, extra[[j]])
  for (i in seq_along(rows)) {
    r <- header_row + i
    gx_set(wb, name, r, first_col, rows[[i]]$loc)
    gx_set(wb, name, r, first_col + 1L, rows[[i]]$ref)
    gx_set(wb, name, r, first_col + 2L, rows[[i]]$ch4)
    for (j in seq_along(extra)) gx_set(wb, name, r, first_col + 2L + j, rows[[i]][[names(extra)[[j]]]])
  }
  invisible(NULL)
}

# DEFAULT landfill content (expectations in the tests are hard-coded):
#   block 1 (cols A-D, rows 8-10)  G197 0.01 | 20.9 | 0.5
#                                  G198 0    | 0    | 0
#                                  G199 0.03 | 19.5 | 1.25
#   block 2 (cols E-H, row 8)      G222 0    | 21   | 0.04
gxo_l1_default <- function() list(
  list(gxo_pt("G197", 0.01, 20.9, 0.5),
       gxo_pt("G198", 0, 0, 0),
       gxo_pt("G199", 0.03, 19.5, 1.25)),
  list(gxo_pt("G222", 0, 21, 0.04))
)

# `l1`/`bld`: NULL = none. `extra` applies to both. The workbook always has a
# `Gas Landfil #1` (detection needs a CH4 header there).
build_gas_o2co2 <- function(dir, report_no = "2400-9911-07-01", sample_date = "2025-07-22",
                            filename = paste0(report_no, " July 2025 Monthly Gas Monitoring Northvale WMF.xlsx"),
                            l1 = gxo_l1_default(), bld = NULL, extra = gxo_extra_default(),
                            l1_extra = extra, bld_extra = extra,
                            ch4_header = "CH4 Reading % v/v") {
  wb <- openxlsx::createWorkbook()
  gx_front_northvale(wb, report_no, sample_date)
  gxo_landfill_sheet(wb, "Gas Landfil #1", if (is.null(l1)) list() else l1,
                     extra = l1_extra, report_no = report_no, ch4_header = ch4_header)
  if (!is.null(bld)) gxo_building_sheet(wb, "Gas Buildings ", bld, extra = bld_extra,
                                        report_no = report_no)
  gx_map_sheet(wb)
  gx_save(wb, dir, filename)
}

# ---- end-to-end seed ---------------------------------------------------------------

gxo_sample_date <- "2025-07-22"

# Landfill-only workbook for the pipeline: one row per feature.
#   G182  CH4 0    O2 20.9  CO2 0
#   G183  CH4 0.03 O2 0     CO2 1.5
gxo_e2e_workbook <- function(dir, report_no = "2400-9911-07-01") {
  build_gas_o2co2(dir, report_no = report_no, sample_date = gxo_sample_date,
                  l1 = list(list(gxo_pt("G182", 0, 20.9, 0), gxo_pt("G183", 0.03, 0, 1.5))))
}

gxo_features <- c(`f-g182` = "N.G182", `f-g183` = "N.G183")

# Seed DB with features, a CH4 analyte/method as the existing gas e2e seeds,
# and the O2 / CO2 analytes and ACIRL field lab_methods as bmcc migration 105
# created them (units L/L, type gas; rl_low 0.001 and 1e-4 L/L).
gxo_db_setup <- function(env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  withr::local_options(list(
    "sampletidy.archive_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.snapshot_dir" = withr::local_tempdir(.local_envir = env),
    "sampletidy.remove_ingested" = FALSE
  ), .local_envir = env)
  i <- 0
  for (u in names(gxo_features)) {
    i <- i + 1
    nm <- gxo_features[[u]]
    DBI::dbExecute(con, "INSERT INTO feature (uuid, name, site, flow, matrix, date_end, lon, lat)
                         VALUES (?, ?, 'B', NULL, 'air', NULL, ?, ?)",
                   params = list(u, nm, 150.6 + i / 1000, -33.7 - i / 1000))
    DBI::dbExecute(con, "INSERT INTO feature_alias
      (uuid, uuid_feature, name, alias_key, kind, n_seen, auto_assign, first_seen, last_seen, confirmed_by)
      VALUES (?, ?, ?, ?, 'self', 0, TRUE, TIMESTAMP '2020-01-01 00:00:00', TIMESTAMP '2020-01-01 00:00:00', NULL)",
      params = list(paste0("fa-", sub("^f-", "", u)), u, nm, tolower(nm)))
  }
  DBI::dbExecute(con, "INSERT INTO analyte (uuid, name, units, conversion_constant, type, CAS) VALUES
    ('a-ch4', 'CH4', 'L/L', 1, 'gas', NULL),
    ('a-o2',  'O2',  'L/L', 1, 'gas', NULL),
    ('a-co2', 'CO2', 'L/L', 1, 'gas', NULL)")
  DBI::dbExecute(con, "INSERT INTO lab_method
    (uuid, uuid_analyte, name, method, organisation, rl_low, units, conversion_constant) VALUES
    ('lm-ch4', 'a-ch4', 'CH4 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL),
    ('lm-o2',  'a-o2',  'O2 Reading % v/v',  'field', 'ACIRL', 0.001, NULL, NULL),
    ('lm-co2', 'a-co2', 'CO2 Reading % v/v', 'field', 'ACIRL', 1e-4, NULL, NULL)")
  DBI::dbExecute(con, "INSERT INTO project (uuid, uuid_parent, uuid_root, name, type)
                       VALUES ('p-gascamp', NULL, 'p-gascamp', 'Monthly gas monitoring', NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db_path
}

gxo_ingest <- function(db_path, env = parent.frame()) {
  gas_adapter()
  input <- withr::local_tempdir(.local_envir = env)
  gxo_e2e_workbook(input)
  ingest_dir(input, db = db_path)
}

gxo_ro <- function(db_path, env = parent.frame()) {
  con <- DBI::dbConnect(duckdb::duckdb(), db_path, read_only = TRUE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE), envir = env)
  con
}

# Every analysis at one feature: one row per analysis, with its lab_method uuid
# and its sample uuid.
gxo_analyses_at <- function(con, uuid_feature) {
  DBI::dbGetQuery(con, "SELECT a.uuid_lab, a.value, a.quantified, a.rl_low,
                               s.uuid AS uuid_sample, s.date, s.datetime
                          FROM analysis a
                          JOIN \"sample\" s ON s.uuid = a.uuid_sample
                          JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
                         WHERE fa.uuid_feature = ?
                         ORDER BY a.uuid_lab", params = list(uuid_feature))
}
