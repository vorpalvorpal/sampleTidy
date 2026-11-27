# PLAN-23 3.2 / 10 (R-23.7): between the sampleTidy merge and migration 117,
# end_feature() and the mask, link and label functions refuse with the
# "migration 117" message (the pre-117 guard, `.st_has_feature_register()`),
# never a raw SQL error, and write nothing.
# Fixture: local_pre117_db() (helper-feature-register.R): the 19-column
# feature, the undated 3-column feature_mask, no feature_geometry, no
# feature_predecessor / feature_flow.

pre117_new_calls <- list(
  end_feature = function(path, con) end_feature(
    uuid = "f-0013", date_end = "2026-01-01", actor = "tester", reason = "x", db = path),
  set_feature_mask = function(path, con) set_feature_mask(
    uuid = "f-0004", variant = "long", name = "Fourth creek", date_start = "2026-01-01",
    actor = "tester", reason = "x", db = path),
  add_feature_predecessor = function(path, con) add_feature_predecessor(
    uuid = "f-0004", uuid_predecessor = "f-0003", date_break = "2026-01-01", source = "doc",
    actor = "tester", reason = "x", db = path),
  add_feature_flow = function(path, con) add_feature_flow(
    uuid_from = "f-0004", uuid_to = "f-0005", drive = "gravity", source = "doc",
    actor = "tester", reason = "x", db = path),
  end_feature_flow = function(path, con) end_feature_flow(
    uuid = "ff-0001", date_end = "2026-01-01", actor = "tester", reason = "x", db = path),
  feature_labels = function(path, con) feature_labels(con, date = as.Date("2026-01-01"))
)

for (nm in names(pre117_new_calls)) local({
  nm <- nm
  test_that(sprintf("R-23.7: on a pre-117 database %s() aborts with the 'migration 117' message and writes nothing", nm), {
    old <- local_pre117_db()
    withr::local_options(list("sampletidy.live_db" = old))
    con <- DBI::dbConnect(duckdb::duckdb(), old, read_only = FALSE)
    withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
    snap <- function() list(
      feature = DBI::dbGetQuery(con, "SELECT * FROM feature ORDER BY uuid"),
      alias = DBI::dbGetQuery(con, "SELECT * FROM feature_alias ORDER BY uuid"),
      mask = DBI::dbGetQuery(con, "SELECT * FROM feature_mask ORDER BY uuid_feature, variant"),
      log = DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log")$n
    )
    before <- snap()
    e <- t23_expect_refused(pre117_new_calls[[nm]](old, con), "migration 117")
    if (!is.null(e)) {
      expect_false(grepl("Binder Error|Catalog Error|does not exist", conditionMessage(e)), info = conditionMessage(e))
    }
    expect_identical(snap(), before)
    expect_false(DBI::dbExistsTable(con, "feature_predecessor"))   # nothing was created either
    expect_false(DBI::dbExistsTable(con, "feature_flow"))
  })
})
