# Plan 02 - R-2.2 unit engine: is_valid_unit(), are_compatible_units(),
# unify_value(). Numeric claims below were independently verified against
# the `units` package before being baked in ([MEASURE TWICE]):
#   1 mg/L -> µg/L is 1000; 2 mg/L -> µg/L is 2000; 5 µS/cm -> mS/cm is 0.005.

test_that("R-2.2: unify_value(1, 'mg/L', 'ug/L') == 1000", {
  expect_equal(unify_value(1, "mg/L", "ug/L"), 1000)
})

test_that("R-2.2: unify_value() vectorised over mixed unit groups preserves input order", {
  result <- unify_value(c(2, 5), c("mg/L", "uS/cm"), c("ug/L", "mS/cm"))
  expect_equal(result, c(2000, 0.005))
})

test_that("R-2.2: identical from/to units returns the input unchanged (no units round-trip)", {
  # exact pass-through (not merely "close"): a real round trip through
  # udunits could introduce floating point noise this guards against.
  expect_identical(unify_value(0.1, "mg/L", "mg/L"), 0.1)
  expect_identical(unify_value(c(1.23456789, 2), c("mS/cm", "mS/cm"), c("mS/cm", "mS/cm")), c(1.23456789, 2))
})

test_that("R-2.2: invalid unit aborts with the offending string in the message, class sampletidy_units_error", {
  err <- tryCatch(unify_value(1, "bogus_unit_xyz", "mg/L"), error = function(e) e)
  expect_s3_class(err, "sampletidy_units_error")
  expect_match(conditionMessage(err), "bogus_unit_xyz", fixed = TRUE)
})

test_that("R-2.2: are_compatible_units('mg/L', 'degC') is FALSE", {
  expect_false(are_compatible_units("mg/L", "degC"))
})

test_that("R-2.2: are_compatible_units('mg/L', 'g/m3') is TRUE", {
  expect_true(are_compatible_units("mg/L", "g/m3"))
})

test_that("R-2.2: is_valid_unit() accepts a known unit and rejects gibberish", {
  expect_true(is_valid_unit("mg/L"))
  expect_false(is_valid_unit("not_a_real_unit_at_all"))
})

test_that("R-2.2: NA semantics - both units NA leaves value unchanged", {
  expect_equal(unify_value(5, NA_character_, NA_character_), 5)
})

test_that("R-2.2: NA semantics - units_from NA leaves value unchanged", {
  expect_equal(unify_value(5, NA_character_, "mg/L"), 5)
})

test_that("R-2.2: NA semantics - units_to NA while units_from is set aborts", {
  err <- tryCatch(unify_value(5, "mg/L", NA_character_), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
})

test_that("R-2.2: pH / pH Unit / pH_Units are registered as valid dimensionless unitless aliases", {
  expect_true(is_valid_unit("pH"))
  expect_true(is_valid_unit("pH Unit"))
  expect_true(is_valid_unit("pH_Units"))
  expect_true(are_compatible_units("pH", "pH Unit"))
  expect_true(are_compatible_units("pH", "pH_Units"))
})

test_that("R-2.2: unify_value() converts between pH unitless aliases without changing the value", {
  expect_equal(unify_value(6.4, "pH Unit", "pH"), 6.4)
  expect_equal(unify_value(7.0, "pH_Units", "pH"), 7.0)
})

# ---- C5 S1: CFU spelling map (exact keys only) ----------------------------

test_that("C5-S1: unify_value() converts CFU/100mL to CFU/mL (6500 -> 65, 1 -> 0.01, 120000 -> 1200)", {
  expect_equal(unify_value(c(6500, 1, 120000), "CFU/100mL", "CFU/mL"), c(65, 0.01, 1200))
})

test_that("C5-S1: CFU/mL -> CFU/mL is the identity short-circuit (control)", {
  expect_identical(unify_value(590000, "CFU/mL", "CFU/mL"), 590000)
})

test_that("C5-S1: CFU/100mL is not convertible to mg/L (still sampletidy_units_error)", {
  expect_error(unify_value(5, "CFU/100mL", "mg/L"), class = "sampletidy_units_error")
})

test_that("C5-S1: unlisted spellings still raise sampletidy_units_error (exact-key map, no case folding)", {
  # non-vacuous: the listed spelling works in the same session
  expect_equal(unify_value(100, "CFU/100mL", "CFU/mL"), 1)
  expect_error(unify_value(5, "cfu/100ml", "CFU/mL"), class = "sampletidy_units_error")
  expect_error(unify_value(5, "MPN/100mL", "CFU/mL"), class = "sampletidy_units_error")
})

test_that("C5-S1: is_valid_unit() accepts the two CFU spellings but not unlisted ones", {
  expect_true(all(is_valid_unit(c("CFU/mL", "CFU/100mL"))))
  expect_false(any(is_valid_unit(c("cfu/100ml", "MPN/100mL"))))
})
