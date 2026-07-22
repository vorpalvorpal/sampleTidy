# Plan 03 - R-3.3 Adapter registry: register_adapter(), adapter_registry(),
# clear_adapters().

make_dummy_adapter <- function(id = "dummy", version = "1.0") {
  list(
    id = id,
    version = version,
    match = function(file_meta) "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  )
}

test_that("R-3.3: register/retrieve/clear round-trips through the registry", {
  clear_adapters()
  withr::defer(clear_adapters())

  a <- make_dummy_adapter("dummy_a", "1.0")
  register_adapter(a)

  reg <- adapter_registry()
  expect_true(is.list(reg))
  expect_true("dummy_a" %in% names(reg))
  expect_equal(reg[["dummy_a"]]$version, "1.0")

  clear_adapters()
  expect_length(adapter_registry(), 0)
})

test_that("R-3.3: registering a duplicate id overwrites with a cli_inform message", {
  clear_adapters()
  withr::defer(clear_adapters())

  register_adapter(make_dummy_adapter("dupe", "1.0"))
  expect_message(register_adapter(make_dummy_adapter("dupe", "2.0")))

  reg <- adapter_registry()
  expect_equal(reg[["dupe"]]$version, "2.0")
  expect_equal(length(reg), 1)
})

test_that("R-3.3: an adapter missing `parse` aborts naming the defect", {
  clear_adapters()
  withr::defer(clear_adapters())

  broken <- list(id = "broken1", version = "1.0", match = function(file_meta) "no")
  err <- tryCatch(register_adapter(broken), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "parse", fixed = TRUE)
  expect_length(adapter_registry(), 0)
})

test_that("R-3.3: an adapter whose `match` has the wrong formals aborts naming the defect", {
  clear_adapters()
  withr::defer(clear_adapters())

  broken <- list(
    id = "broken2", version = "1.0",
    match = function(file_meta, extra_unexpected_arg) "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  )
  err <- tryCatch(register_adapter(broken), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "match", fixed = TRUE)
  expect_length(adapter_registry(), 0)
})

test_that("R-3.3: an adapter missing `id` aborts naming the defect", {
  clear_adapters()
  withr::defer(clear_adapters())

  broken <- list(
    version = "1.0",
    match = function(file_meta) "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  )
  err <- tryCatch(register_adapter(broken), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "id", fixed = TRUE)
})

test_that("R-3.3: an adapter missing `version` aborts naming the defect", {
  clear_adapters()
  withr::defer(clear_adapters())

  broken <- list(
    id = "broken3",
    match = function(file_meta) "no",
    parse = function(path, file_meta) list(results = ir_results(), samples = ir_samples(), report = list())
  )
  err <- tryCatch(register_adapter(broken), error = function(e) e)
  expect_s3_class(err, "sampletidy_error")
  expect_match(conditionMessage(err), "version", fixed = TRUE)
})

test_that("R-3.3: adapter_registry() returns adapters as a named list keyed by id", {
  clear_adapters()
  withr::defer(clear_adapters())

  register_adapter(make_dummy_adapter("aaa", "1.0"))
  register_adapter(make_dummy_adapter("bbb", "1.0"))

  reg <- adapter_registry()
  expect_setequal(names(reg), c("aaa", "bbb"))
})

test_that("R-12.10: register_builtin_adapters() emits no Overwriting inform when a built-in re-registers itself", {
  clear_adapters()
  withr::defer(clear_adapters())

  # First call populates the registry with all four built-ins (as .onLoad()
  # / the start of ingest_dir() do). The second call is the defensive
  # re-registration A33 performs on every ingest_dir() run: same ids, freshly
  # constructed built-in adapter objects. That must be silent.
  register_builtin_adapters()
  expect_no_message(register_builtin_adapters(), message = "Overwriting")

  reg <- adapter_registry()
  expect_setequal(names(reg), c("esdat", "als_xtab", "als_enmrg", "acirl_field_xlsx"))
})

test_that("R-12.10: a third-party adapter registered over a built-in id still emits an Overwriting inform", {
  clear_adapters()
  withr::defer(clear_adapters())

  register_builtin_adapters()

  clobber <- make_dummy_adapter("esdat", "99.0")
  expect_message(register_adapter(clobber), "Overwriting")

  reg <- adapter_registry()
  expect_equal(reg[["esdat"]]$version, "99.0")
})
