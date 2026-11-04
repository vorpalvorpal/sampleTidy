# Stage 1 of the layer move: three OPTIONAL columns on the limits table carry
# behaviour that used to be hard-coded (spec A4):
#
#   gas_grid         "TRUE"/"FALSE" (any case) or NA: the row's (site,
#                    feature_pattern) marks licence gas-grid points. Replaces
#                    `condition == "R2.3"`.
#   grid_only_level  case-insensitive regex: a guideline level whose
#                    `level_name` matches ANY non-NA value in the table applies
#                    only at gas-grid points of the result's site. Replaces
#                    the literal "solid waste".
#   detail_suffix    appended as "; <suffix>" to the licence_limit detail.
#                    Replaces the `^L2` storm-exemption text.
#
# `condition` stays display text. With the columns absent there is no special
# behaviour. Synthetic: site N, grid features N.G01 / N.G02, off-grid N.H01.

# fl_limits_plain() (no behaviour columns) plus optional ones (a vector per
# column, one value per row).
lb_limits <- function(rows, gas_grid = NULL, grid_only_level = NULL, detail_suffix = NULL) {
  d <- do.call(fl_limits_plain, rows)
  if (!is.null(gas_grid)) d$gas_grid <- gas_grid
  if (!is.null(grid_only_level)) d$grid_only_level <- grid_only_level
  if (!is.null(detail_suffix)) d$detail_suffix <- detail_suffix
  d
}

lb_grid_row <- function(site = "N", pattern = "^N\\.G", condition = "G-1") {
  list(site = site, feature_pattern = pattern, analyte = "CH4", max = "1.25", unit = "%v/v",
       factor = "100", condition = condition)
}

# Air samples at N.G01 (grid), N.H01 (not grid) and M.G01 (another site) with
# CH4 above both guideline levels.
lb_gas_db <- function(env = parent.frame()) {
  db <- fl_db(env = env)
  fl_with(db, function(con) {
    fl_analyte(con, "CH4", units = "L/L")
    fl_guideline(con, "CH4", "EPA", 2, "Grid-only trigger", 0.0005)
    fl_guideline(con, "CH4", "LEL", 3, "10% of lower explosive limit", 0.005)
    for (ft in c("N.G01", "N.H01", "M.G01")) {
      fl_sample(con, ft, "WO-G", "2026-09-28", org = "FIELDCO", matrix = "air",
                type = "Gas round", ts_col = "date", results = list(CH4 = 0.006))
    }
  })
  db
}

lb_gc <- function(db, limits) {
  fl_of(fl_run(db, sx_checks(streams = sx_evidence(), limits = limits)), "gas_criterion")
}

# ---- 21. grid_only_level ---------------------------------------------------------------

test_that("grid_only_level: a matching level is flagged at grid points of the site only; other levels at every point", {
  db <- lb_gas_db()
  lim <- lb_limits(list(lb_grid_row()), gas_grid = "TRUE", grid_only_level = "grid-only")
  gc <- lb_gc(db, lim)
  trig <- gc[grepl("Grid-only trigger", gc$threshold, fixed = TRUE), ]
  lel <- gc[grepl("lower explosive", gc$threshold, fixed = TRUE), ]
  expect_identical(trig$feature, "N.G01")                       # not N.H01, not M.G01
  expect_setequal(lel$feature, c("N.G01", "N.H01", "M.G01"))    # the other level: everywhere
  expect_equal(nrow(gc), 4)
})

test_that("grid_only_level: the regex is case-insensitive and any non-NA value in the table counts", {
  db <- lb_gas_db()
  lim <- lb_limits(list(lb_grid_row(), lb_grid_row(pattern = "^N\\.Z", condition = "G-2")),
                   gas_grid = c("true", "FALSE"),
                   grid_only_level = c(NA, "^GRID-ONLY"))
  gc <- lb_gc(db, lim)
  trig <- gc[grepl("Grid-only trigger", gc$threshold, fixed = TRUE), ]
  expect_identical(trig$feature, "N.G01")
})

test_that("gas_grid: FALSE or NA marks no grid point, so the grid-only level applies nowhere", {
  db <- lb_gas_db()
  for (g in list("FALSE", "false", NA_character_)) {
    lim <- lb_limits(list(lb_grid_row()), gas_grid = g, grid_only_level = "grid-only")
    gc <- lb_gc(db, lim)
    expect_false(any(grepl("Grid-only trigger", gc$threshold, fixed = TRUE)), info = format(g))
    expect_equal(nrow(gc), 3, info = format(g))
  }
})

test_that("gas_grid: the marker is the column, not the condition text", {
  db <- lb_gas_db()
  # condition R2.3 but gas_grid FALSE: no grid point
  lim <- lb_limits(list(lb_grid_row(condition = "R2.3")), gas_grid = "FALSE",
                   grid_only_level = "grid-only")
  expect_false(any(grepl("Grid-only trigger", lb_gc(db, lim)$threshold, fixed = TRUE)))
  # a condition with no special text but gas_grid TRUE: a grid point
  lim2 <- lb_limits(list(lb_grid_row(condition = "anything")), gas_grid = "TRUE",
                    grid_only_level = "grid-only")
  expect_true(any(grepl("Grid-only trigger", lb_gc(db, lim2)$threshold, fixed = TRUE)))
})

# ---- 22. columns absent -----------------------------------------------------------------------

test_that("columns absent: the grid-only-named level is flagged everywhere (no grid points, no grid-only levels)", {
  db <- lb_gas_db()
  for (lim in list(lb_limits(list(lb_grid_row(condition = "R2.3"))), NULL)) {
    gc <- lb_gc(db, lim)
    trig <- gc[grepl("Grid-only trigger", gc$threshold, fixed = TRUE), ]
    expect_setequal(trig$feature, c("N.G01", "N.H01", "M.G01"))
    expect_equal(nrow(gc), 6)
  }
})

test_that("columns absent: no detail suffix, whatever the condition says", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO", results = list(`NH3-N` = 5))
  })
  lim <- lb_limits(list(list(site = "N", feature_pattern = "^N\\.W01$", analyte = "NH3-N",
                             max = "0.9", condition = "L2.4")))
  ll <- fl_of(fl_run(db, sx_checks(limits = lim)), "licence_limit")
  expect_equal(nrow(ll), 1)
  expect_no_match(ll$detail, "storm exemption", fixed = TRUE)
  expect_match(ll$detail, "WO-1$")
})

# ---- 23. detail_suffix --------------------------------------------------------------------------

test_that("detail_suffix: the detail ends with '; <suffix>' for rows that set it, and only those", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO", results = list(`NH3-N` = 5))
    fl_sample(con, "N.W02", "WO-1", "2026-09-10", org = "FIELDCO", results = list(`NH3-N` = 5))
  })
  lim <- lb_limits(list(
    list(site = "N", feature_pattern = "^N\\.W01$", analyte = "NH3-N", max = "0.9", condition = "L2.4"),
    list(site = "N", feature_pattern = "^N\\.W02$", analyte = "NH3-N", max = "0.9", condition = "L2.4")),
    detail_suffix = c("exemption (X9) not assessed", NA))
  ll <- fl_of(fl_run(db, sx_checks(limits = lim)), "licence_limit")
  a <- ll[ll$feature == "N.W01", ]
  b <- ll[ll$feature == "N.W02", ]
  expect_true(endsWith(a$detail, "WO-1; exemption (X9) not assessed"))
  expect_no_match(b$detail, "exemption", fixed = TRUE)
  expect_true(endsWith(b$detail, "WO-1"))
})

test_that("detail_suffix: an empty cell in a CSV is NA (no suffix); a set cell is appended", {
  db <- fl_db()
  fl_with(db, function(con) {
    fl_sample(con, "N.W01", "WO-1", "2026-09-10", org = "FIELDCO", results = list(`NH3-N` = 5))
  })
  p <- file.path(withr::local_tempdir(), "limits.csv")
  lim <- lb_limits(list(list(site = "N", feature_pattern = "^N\\.W01$", analyte = "NH3-N",
                             max = "0.9", condition = "L2.4")),
                   gas_grid = "", grid_only_level = "", detail_suffix = "see note 4")
  utils::write.csv(lim, p, row.names = FALSE)
  ll <- fl_of(fl_run(db, sx_checks(limits = p)), "licence_limit")
  expect_equal(nrow(ll), 1)
  expect_true(endsWith(ll$detail, "WO-1; see note 4"))
})

# ---- 24. validation ----------------------------------------------------------------------------------

test_that("gas_grid: a value other than TRUE/FALSE/NA is a licence_limit error that names gas_grid", {
  db <- lb_gas_db()
  lim <- lb_limits(list(lb_grid_row()), gas_grid = "maybe")
  f <- fl_run(db, sx_checks(streams = sx_evidence(), limits = lim))
  err <- attr(f, "errors")
  expect_true("licence_limit" %in% names(err))
  expect_match(err[["licence_limit"]], "gas_grid", fixed = TRUE)
  expect_match(err[["licence_limit"]], "^limits: ")
})
