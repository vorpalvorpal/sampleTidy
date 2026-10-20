# tests/testthat/test-processed-dedupe.R
#
# dev/processed-dedupe.R (operator tool, not package code): the 2026-10-20 rules.
#   * a duplicate is quarantined only on a byte hash, never on name + size;
#   * only once its canonical copy verifies (exists, same size, bytes = asset.hash
#     when they can be read);
#   * unreferenced files in processed/ are quarantined as orphans;
#   * --merged: a 057-merged row's own file is a duplicate only once the row is gone;
#   * --post-import builds the plan fresh and applies only the import-dependent subset.
# The script is run with Rscript on a scratch tree and a scratch DuckDB.

script <- normalizePath(testthat::test_path("..", "..", "dev", "processed-dedupe.R"), mustWork = FALSE)

pd_run <- function(args) {
  out <- suppressWarnings(system2(file.path(R.home("bin"), "Rscript"), c(shQuote(script), args),
                                  stdout = TRUE, stderr = TRUE))
  list(status = attr(out, "status") %||% 0L, out = out)
}
`%||%` <- function(a, b) if (is.null(a)) b else a

pd_fixture <- function(env = parent.frame()) {
  base <- withr::local_tempdir(.local_envir = env)
  root <- file.path(base, "assets"); dir.create(file.path(root, "processed"), recursive = TRUE)
  dir.create(file.path(root, "unprocessed")); dir.create(file.path(root, "input"))
  put <- function(rel, bytes) {
    p <- file.path(root, rel); dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
    writeBin(charToRaw(bytes), p); invisible(p)
  }
  u <- c(A = "aaaaaaaa-0000-4000-8000-000000000001", B = "bbbbbbbb-0000-4000-8000-000000000002",
         C = "cccccccc-0000-4000-8000-000000000003", K = "dddddddd-0000-4000-8000-000000000004",
         M = "eeeeeeee-0000-4000-8000-000000000005", O = "ffffffff-0000-4000-8000-000000000006",
         E = "abababab-0000-4000-8000-000000000007", D = "cdcdcdcd-0000-4000-8000-000000000008",
         Z = "efefefef-0000-4000-8000-000000000009")
  put(file.path("processed", u[["A"]], "a.pdf"), "bytes of report A")
  put(file.path("processed", u[["B"]], "b.pdf"), "bytes of report B")
  put(file.path("processed", u[["C"]], "c.xls"), "c REWRITTEN by sharepoint")   # asset.hash = original bytes
  put(file.path("processed", u[["K"]], "k.csv"), "same bytes K/M")
  put(file.path("processed", u[["M"]], "k[1].csv"), "same bytes K/M")
  put(file.path("processed", u[["O"]], "lost.pdf"), "orphan unique bytes")
  put(file.path("processed", u[["D"]], "a again.pdf"), "bytes of report A")      # orphan dir, bytes = A
  dir.create(file.path(root, "processed", u[["E"]]))                              # empty orphan dir
  put(file.path("processed", u[["Z"]], "z.pdf"), "")                               # a 0-byte asset file
  put("unprocessed/a.pdf", "bytes of report A")                                   # ingested -> duplicate
  put("unprocessed/b.pdf", "bytes of report B")                                   # made "non-local" below
  put("unprocessed/c.xls", "c original bytes")                                    # = asset C's hash
  put("unprocessed/new.csv", "never ingested")
  h <- function(s) { f <- tempfile(); writeBin(charToRaw(s), f); rlang::hash_file(f) }
  assets <- data.frame(
    uuid = u[c("A", "B", "C", "K", "M", "Z")],
    filename = c("a.pdf", "b.pdf", "c.xls", "k.csv", "k[1].csv", "z.pdf"),
    hash = c(h("bytes of report A"), h("bytes of report B"), h("c original bytes"),
             h("same bytes K/M"), h("same bytes K/M"), h("")), stringsAsFactors = FALSE)
  db <- file.path(base, "db.duckdb")
  con <- DBI::dbConnect(duckdb::duckdb(), db)
  DBI::dbWriteTable(con, "asset", assets)
  DBI::dbWriteTable(con, "ingest_file", data.frame(hash = character(), size = numeric()))
  DBI::dbDisconnect(con, shutdown = TRUE)
  merged <- file.path(base, "merged.csv")
  utils::write.csv(data.frame(uuid = u[["M"]], filename = "k[1].csv", hash = assets$hash[5],
                              merged_into = u[["K"]], merged_into_filename = "k.csv"),
                   merged, row.names = FALSE)
  ruled <- file.path(base, "ruled.csv")
  utils::write.csv(data.frame(uuid = u[c("K", "M", "Z")], filename = c("k.csv", "k[1].csv", "z.pdf"),
                              hash = assets$hash[4:6], merged_into = NA, action = c("keep", "keep", "retire"),
                              migration = "061"), ruled, row.names = FALSE, na = "")
  list(base = base, root = root, db = db, u = u, merged = merged, ruled = ruled, hash_b = assets$hash[2])
}

pd_plan <- function(fx, extra = character(), name = "plan.csv") {
  out <- file.path(fx$base, name)
  r <- pd_run(c("--db", shQuote(fx$db), "--root", shQuote(fx$root), "--plan-out", shQuote(out),
                "--date", "20261020", "--test-nonlocal", shQuote("^unprocessed/b[.]pdf$"), extra))
  expect_equal(r$status, 0L, info = paste(r$out, collapse = "\n"))
  P <- utils::read.csv(out, colClasses = "character", na.strings = "")
  stats::setNames(P$action, P$relpath)
}

test_that("byte duplicates, orphans and empty dirs are planned; name+size alone never quarantines", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  a <- pd_plan(fx)
  u <- fx$u
  expect_equal(a[["unprocessed/a.pdf"]], "quarantine-duplicate")
  expect_equal(a[["unprocessed/b.pdf"]], "keep")                  # name+size only
  expect_equal(a[["unprocessed/c.xls"]], "keep")                  # canonical bytes no longer = asset.hash
  expect_equal(a[["unprocessed/new.csv"]], "keep")
  expect_equal(a[[file.path("processed", u[["O"]], "lost.pdf")]], "quarantine-orphan")
  expect_equal(a[[file.path("processed", u[["D"]], "a again.pdf")]], "quarantine-duplicate")
  expect_equal(a[[file.path("processed", u[["E"]])]], "quarantine-orphan-empty-dir")
  expect_equal(a[[file.path("processed", u[["O"]])]], "quarantine-orphan-empty-dir")
  expect_equal(a[[file.path("processed", u[["A"]], "a.pdf")]], "keep")
  # a legacy duplicate pair not covered by --merged needs a ruling
  expect_equal(a[[file.path("processed", u[["M"]], "k[1].csv")]], "ask-robin")
})

test_that("--known-hashes turns a name+size match into a byte duplicate while size and mtime hold", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  p <- file.path(fx$root, "unprocessed/b.pdf")
  kh <- file.path(fx$base, "known.csv")
  utils::write.csv(data.frame(relpath = "unprocessed/b.pdf", size = file.info(p)$size,
                              mtime = floor(as.numeric(file.info(p)$mtime)), hash = fx$hash_b),
                   kh, row.names = FALSE)
  expect_equal(pd_plan(fx, c("--known-hashes", shQuote(kh)))[["unprocessed/b.pdf"]], "quarantine-duplicate")
  Sys.setFileTime(p, Sys.time() - 86400)  # the file changed since it was read
  expect_equal(pd_plan(fx, c("--known-hashes", shQuote(kh)), "plan2.csv")[["unprocessed/b.pdf"]], "keep")
})

test_that("--merged: kept while the merged row exists; a duplicate once 057 deleted it", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  u <- fx$u; mf <- file.path("processed", u[["M"]], "k[1].csv")
  before <- pd_plan(fx, c("--merged", shQuote(fx$merged)))
  expect_equal(before[[mf]], "keep")
  expect_false(file.path("processed", u[["M"]]) %in% names(before))
  con <- DBI::dbConnect(duckdb::duckdb(), fx$db)
  DBI::dbExecute(con, "DELETE FROM asset WHERE uuid = ?", params = list(u[["M"]]))
  DBI::dbDisconnect(con, shutdown = TRUE)
  after <- pd_plan(fx, c("--merged", shQuote(fx$merged)), "plan2.csv")
  expect_equal(after[[mf]], "quarantine-duplicate")
  expect_equal(after[[file.path("processed", u[["M"]])]], "quarantine-orphan-empty-dir")
})

test_that("--post-import applies only the import-dependent subset, and --undo restores it", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  u <- fx$u
  con <- DBI::dbConnect(duckdb::duckdb(), fx$db)
  DBI::dbExecute(con, "DELETE FROM asset WHERE uuid = ?", params = list(u[["M"]]))
  DBI::dbDisconnect(con, shutdown = TRUE)
  out <- file.path(fx$base, "post.csv")
  r <- pd_run(c("--post-import", "--db", shQuote(fx$db), "--root", shQuote(fx$root), "--plan-out", shQuote(out),
                "--date", "20261020", "--merged", shQuote(fx$merged)))
  expect_equal(r$status, 0L, info = paste(r$out, collapse = "\n"))
  q <- file.path(fx$root, "_dedupe_quarantine", "20261020")
  expect_false(file.exists(file.path(fx$root, "unprocessed/a.pdf")))
  expect_true(file.exists(file.path(q, "unprocessed/a.pdf")))
  expect_true(file.exists(file.path(q, "processed", u[["M"]], "k[1].csv")))
  expect_false(dir.exists(file.path(fx$root, "processed", u[["M"]])))
  # not import-dependent: planned, but left for review
  expect_true(file.exists(file.path(fx$root, "processed", u[["O"]], "lost.pdf")))
  expect_true(dir.exists(file.path(fx$root, "processed", u[["E"]])))
  expect_true(file.exists(file.path(fx$root, "processed", u[["D"]], "a again.pdf")))
  expect_true(file.exists(file.path(fx$root, "processed", u[["K"]], "k.csv")))
  r <- pd_run(c("--root", shQuote(fx$root), "--undo", shQuote(sub("[.]csv$", "-post-import-undo.csv", out))))
  expect_equal(r$status, 0L, info = paste(r$out, collapse = "\n"))
  expect_true(file.exists(file.path(fx$root, "unprocessed/a.pdf")))
  expect_true(file.exists(file.path(fx$root, "processed", u[["M"]], "k[1].csv")))
})

test_that("--apply refuses a name+size duplicate row and a canonical whose size differs", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  out <- file.path(fx$base, "plan.csv")
  pd_plan(fx)
  P <- utils::read.csv(out, colClasses = "character", na.strings = "")
  i <- which(P$relpath == "unprocessed/b.pdf")
  P$action[i] <- "quarantine-duplicate"; P$quarantine_relpath[i] <- "_dedupe_quarantine/20261020/unprocessed/b.pdf"
  P$canonical_path[i] <- file.path("processed", fx$u[["B"]], "b.pdf")
  P <- P[i, , drop = FALSE]
  utils::write.csv(P, out, row.names = FALSE, na = "")
  r <- pd_run(c("--db", shQuote(fx$db), "--root", shQuote(fx$root), "--apply", shQuote(out)))
  expect_equal(r$status, 2L)
  expect_true(any(grepl("not hash-verified", r$out)))
  expect_true(file.exists(file.path(fx$root, "unprocessed/b.pdf")))
})

test_that("--merged action keep / retire (061-style): ruled rows are kept; a retired row's file is an orphan once gone", {
  skip_if_not(file.exists(script), "dev/processed-dedupe.R not available")
  fx <- pd_fixture()
  u <- fx$u; zf <- file.path("processed", u[["Z"]], "z.pdf")
  before <- pd_plan(fx, c("--merged", shQuote(fx$ruled)))
  expect_equal(before[[file.path("processed", u[["M"]], "k[1].csv")]], "keep")
  expect_equal(before[[file.path("processed", u[["K"]], "k.csv")]], "keep")
  expect_equal(before[[zf]], "keep")
  con <- DBI::dbConnect(duckdb::duckdb(), fx$db)
  DBI::dbExecute(con, "DELETE FROM asset WHERE uuid = ?", params = list(u[["Z"]]))
  DBI::dbDisconnect(con, shutdown = TRUE)
  out <- file.path(fx$base, "post.csv")
  r <- pd_run(c("--post-import", "--db", shQuote(fx$db), "--root", shQuote(fx$root), "--plan-out", shQuote(out),
                "--date", "20261020", "--merged", shQuote(paste(fx$merged, fx$ruled, sep = ","))))
  expect_equal(r$status, 0L, info = paste(r$out, collapse = "\n"))
  q <- file.path(fx$root, "_dedupe_quarantine", "20261020")
  expect_true(file.exists(file.path(q, zf)))
  expect_false(dir.exists(file.path(fx$root, "processed", u[["Z"]])))
  # M is "keep" by the ruling CSV but still an asset here: untouched
  expect_true(file.exists(file.path(fx$root, "processed", u[["M"]], "k[1].csv")))
  expect_true(file.exists(file.path(fx$root, "processed", u[["O"]], "lost.pdf")))
})
