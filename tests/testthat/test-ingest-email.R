# R-22.E - the delivering email's identity (Robin's ruling 2026-10-25).
#
# Deliveries arrive as one folder per email, holding the attachments plus
# `_email.eml` (the whole message, often 10-25 MB because the attachments are
# inlined). The email is NOT attached as an asset. Its identity is recorded in
# `ingest_email`, and every `ingest_file` row routed from that folder names it
# through `ingest_file.message_id`, so "when did the lab send this, and in reply
# to what" is a query.
#
# Spec pinned here (test writer's choices are marked "pinned:"; the rest is the
# ruling as briefed):
#
# 1. Schema. `ingest_email` (message_id VARCHAR PRIMARY KEY, sent_at TIMESTAMP,
#    sender VARCHAR, sender_name VARCHAR, subject VARCHAR, in_reply_to VARCHAR,
#    folder VARCHAR, first_seen_at TIMESTAMP) and a nullable
#    `ingest_file.message_id VARCHAR`. Both arrive through the ops-schema ladder
#    (`.st_schema_migrations`, applied by `ensure_schema()`, which `seed_db()`
#    and `ingest_dir()` both run) - pinned: that is the only mechanism that
#    creates a table on a fresh DB AND on the live DB without an operator step.
#    The mutation layer accepts `db_append(con, "ingest_email", ...)` and logs
#    it in `change_log`.
#
# 2. `email_headers(path)` (internal). Reads ONLY the header block (up to the
#    first blank line). Returns NULL when there is no Message-ID (or no header
#    block at all), never an error. Otherwise a list with:
#      message_id   angle brackets stripped
#      sent_at      POSIXct in UTC, from Date (offset applied)
#      sender       the From address, lower-cased
#      sender_name  the From display name (quotes stripped, RFC 2047 decoded),
#                   NA_character_ for a bare address
#      subject      unfolded, RFC 2047 decoded (B and Q, any charset iconv
#                   knows; whitespace BETWEEN two encoded-words dropped per
#                   RFC 2047 s6.2); NA_character_ when absent
#      in_reply_to  brackets stripped; NA_character_ when absent
#    Header names are case-insensitive. LF and CRLF files give the same result.
#
# 3. `ingest_dir()` on a folder holding `_email.eml`:
#    * one `ingest_email` row (folder = basename of the ingested directory);
#      re-running, or a second folder carrying the same Message-ID, neither
#      duplicates nor errors. pinned: first sighting wins - first_seen_at and
#      folder are those of the first folder.
#    * every ingest_file row routed from the folder carries message_id,
#      whatever its terminal state (archived / retained_sibling / quarantined /
#      ignored), the eml's own row included.
#    * pinned: message_id is filled when NULL and never overwritten - a file
#      first delivered by email A and later re-sent by email B stays A's.
#    * `_email.eml` itself ends `ignored` / `delivery_email`, gets no asset
#      row, and is never deleted by remove_ingested - the inbox files it to
#      `_emails/`. A folder left holding only `_email.eml` is NOT spent (R-9.9
#      must not unlink it before the inbox can file it).
#    * pinned: a dry run writes no ingest_email row and sets no message_id
#      (a message_id without its email row is exactly what the dangling check
#      flags).
#    * no `_email.eml` -> exactly today's behaviour, message_id NULL.
#    * a malformed eml (no header block) is not fatal: one warning naming the
#      file, message_id NULL, the rest of the import unaffected.
#
# 4. db_checks: hourly error check `ingest_file_email_dangling` - an
#    ingest_file.message_id with no ingest_email row. Its failing case lives in
#    helper-db-checks.R's `dbc_violation_cases` (table-driven, with every other
#    check); the clean case is here.
#
# All fixture emails are synthetic: example.org addresses, made-up ids.

# ---- fixture builders (above every test: testthat runs top to bottom) --------

#' Write a synthetic .eml. `headers` are raw header lines, written as given
#' (a line starting with whitespace is a fold). `body` is appended after the
#' blank separator line. `eol` is the line ending used throughout.
ie_write_eml <- function(path, headers, body = c("Hello,", "", "Results attached."),
                         eol = "\r\n") {
  txt <- paste0(paste(c(headers, "", body), collapse = eol), eol)
  con <- file(path, "wb")
  on.exit(close(con), add = TRUE)
  writeBin(charToRaw(enc2utf8(txt)), con)
  invisible(path)
}

ie_b64 <- function(s) jsonlite::base64_enc(charToRaw(enc2utf8(s)))

#' A plausible multipart header block for a lab delivery.
ie_headers <- function(message_id = "<CAF-0001.7f3a@mail.example.org>",
                       subject = "EXTERNAL  Blaxland Quarterly Aug Report",
                       from = "ALS Reports <Reports@Example.org>",
                       date = "Thu, 23 Oct 2026 14:13:05 +1100",
                       in_reply_to = "<req-0001.ab12@example.org>",
                       extra = character(0)) {
  c(
    "Received: from mx.example.org by mail.example.org; Thu, 23 Oct 2026 03:13:07 +0000",
    paste0("From: ", from),
    "To: monitoring@example.org",
    paste0("Subject: ", subject),
    paste0("Date: ", date),
    if (!is.null(message_id)) paste0("Message-ID: ", message_id),
    if (!is.null(in_reply_to)) paste0("In-Reply-To: ", in_reply_to),
    "MIME-Version: 1.0",
    "Content-Type: multipart/mixed; boundary=\"=_b1\"",
    extra
  )
}

#' `n_bytes` of base64-looking body text in 76-character lines, as an inlined
#' attachment looks.
ie_big_body <- function(n_bytes) {
  line <- substr(strrep("QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo0NTY3ODkw", 3), 1, 76)
  c("--=_b1", "Content-Type: application/pdf; name=\"report.pdf\"",
    "Content-Transfer-Encoding: base64", "",
    rep(line, ceiling(n_bytes / 78)), "--=_b1--")
}

ie_hdr <- function(headers, ..., dir = withr::local_tempdir(.local_envir = parent.frame())) {
  p <- file.path(dir, "_email.eml")
  ie_write_eml(p, headers, ...)
  email_headers(p)
}

ie_utc <- function(x) format(x, "%Y-%m-%d %H:%M:%S", tz = "UTC")

# Seeded DB, archive and snapshot dirs; remove_ingested off unless asked.
ie_setup <- function(remove_ingested = FALSE, env = parent.frame()) {
  db_path <- seed_db(dir = withr::local_tempdir(.local_envir = env))
  con <- seed_con(db_path)
  ensure_test_asset_table(con)
  DBI::dbDisconnect(con, shutdown = TRUE)
  archive_dir <- withr::local_tempdir(.local_envir = env)
  snapshot_dir <- withr::local_tempdir(.local_envir = env)
  withr::local_options(list(
    "sampletidy.archive_dir" = archive_dir,
    "sampletidy.snapshot_dir" = snapshot_dir,
    "sampletidy.remove_ingested" = remove_ingested
  ), .local_envir = env)
  list(db = db_path, archive_dir = archive_dir, snapshot_dir = snapshot_dir)
}

ie_query <- function(db, sql, ...) {
  con <- DBI::dbConnect(duckdb::duckdb(), db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  DBI::dbGetQuery(con, sql, params = if (length(list(...))) list(...) else NULL)
}

# ingest_file rows this test routed: seed_db()'s one pre-existing row
# ('legacy-hash-XX', no filename) predates every delivery and is left out.
ie_files <- function(db) {
  ie_query(db, "SELECT hash, filename, state, state_reason, message_id, uuid_asset FROM ingest_file
                WHERE hash <> 'legacy-hash-XX'")
}

ie_proj_a <- function() {
  list.files(testthat::test_path("fixtures", "esdat"), pattern = "XX1234567", full.names = TRUE)
}

#' A delivery folder `<parent>/<name>/` holding the XX1234567 esdat triple
#' (archived), its COA PDF (retained_sibling), random.csv (quarantined /
#' unclaimed), a .bak (ignored) and, unless `eml = FALSE`, `_email.eml`.
ie_delivery <- function(parent, name, eml = TRUE, headers = ie_headers(),
                        body = c("Hello,", "", "Results attached.")) {
  d <- file.path(parent, name)
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
  for (f in ie_proj_a()) stopifnot(file.copy(f, file.path(d, basename(f))))
  stopifnot(file.copy(testthat::test_path("fixtures", "esdat", "random.csv"),
                      file.path(d, "random.csv")))
  writeBin(charToRaw(paste(
    c("%PDF-1.4 fake Certificate of Analysis for work order XX1234567",
      sprintf("line %02d: filler so this is not a degenerate file", 1:20)),
    collapse = "\n")), file.path(d, "XX1234567_0_COA.pdf"))
  writeLines("stale backup, pre-dates sampleTidy", file.path(d, "old_export.bak"))
  if (isTRUE(eml)) ie_write_eml(file.path(d, "_email.eml"), headers, body = body)
  d
}

ie_ingest <- function(path, db, ...) {
  suppressMessages(ingest_dir(path, db = db, ...))
}

# The states the fixture folder must reach (R-9.5/R-15.36 behaviour today).
ie_expected_states <- c(
  "PROJ_A.ESDAT_XX1234567_0.Chemistry2e.CSV" = "archived",
  "PROJ_A.ESDAT_XX1234567_0.Header.XML" = "archived",
  "PROJ_A.ESDAT_XX1234567_0.Sample2e.CSV" = "archived",
  "XX1234567_0_COA.pdf" = "archived",
  "random.csv" = "quarantined",
  "old_export.bak" = "ignored"
)

# ---- 1. schema -------------------------------------------------------------------

test_that("R-22.E: ensure_schema() on a bare DB creates ingest_email with exactly the pinned columns and types, message_id its primary key", {
  dir <- withr::local_tempdir()
  con <- DBI::dbConnect(duckdb::duckdb(), file.path(dir, "fresh.duckdb"), read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)

  expect_true(DBI::dbExistsTable(con, "ingest_email"))
  cols <- DBI::dbGetQuery(con, "
    SELECT column_name, data_type FROM information_schema.columns
    WHERE table_name = 'ingest_email'")
  want <- c(message_id = "VARCHAR", sent_at = "TIMESTAMP", sender = "VARCHAR",
            sender_name = "VARCHAR", subject = "VARCHAR", in_reply_to = "VARCHAR",
            folder = "VARCHAR", first_seen_at = "TIMESTAMP")
  expect_setequal(cols$column_name, names(want))
  got <- stats::setNames(cols$data_type, cols$column_name)
  expect_identical(got[names(want)], want)

  pk <- DBI::dbGetQuery(con, "
    SELECT constraint_column_names FROM duckdb_constraints()
    WHERE table_name = 'ingest_email' AND constraint_type = 'PRIMARY KEY'")
  expect_equal(nrow(pk), 1L)
  expect_identical(unlist(pk$constraint_column_names), "message_id")
})

test_that("R-22.E: ensure_schema() gives ingest_file a nullable VARCHAR message_id column", {
  dir <- withr::local_tempdir()
  con <- DBI::dbConnect(duckdb::duckdb(), file.path(dir, "fresh.duckdb"), read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)

  col <- DBI::dbGetQuery(con, "
    SELECT data_type, is_nullable FROM information_schema.columns
    WHERE table_name = 'ingest_file' AND column_name = 'message_id'")
  expect_equal(nrow(col), 1L)
  expect_identical(col$data_type, "VARCHAR")
  expect_identical(col$is_nullable, "YES")
})

test_that("R-22.E: the new schema arrives as a new ladder entry - a DB already at the previous top version is upgraded in place, its ingest_file rows kept with message_id NULL", {
  ns <- asNamespace("sampleTidy")
  full <- get(".st_schema_migrations", envir = ns)
  withr::defer(assignInNamespace(".st_schema_migrations", full, ns = "sampleTidy"))
  # Everything up to version 8 (the ladder's top before R-22.E).
  old <- Filter(function(m) m$version <= 8L, full)
  expect_true(length(old) < length(full),
              info = "R-22.E must add at least one ladder entry above version 8")
  assignInNamespace(".st_schema_migrations", old, ns = "sampleTidy")

  dir <- withr::local_tempdir()
  con <- DBI::dbConnect(duckdb::duckdb(), file.path(dir, "old.duckdb"), read_only = FALSE)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  ensure_schema(con)
  expect_false(DBI::dbExistsTable(con, "ingest_email"))
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, state) VALUES (?, 'a.csv', 'archived')",
                 params = list(sprintf("%032x", 77L)))

  assignInNamespace(".st_schema_migrations", full, ns = "sampleTidy")
  ensure_schema(con)
  expect_true(DBI::dbExistsTable(con, "ingest_email"))
  r <- DBI::dbGetQuery(con, "SELECT filename, state, message_id FROM ingest_file")
  expect_equal(nrow(r), 1L)
  expect_identical(r$state, "archived")
  expect_true(is.na(r$message_id))
  # and a second call is a no-op
  v1 <- DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version
  ensure_schema(con)
  expect_identical(DBI::dbGetQuery(con, "SELECT version FROM schema_version ORDER BY version")$version, v1)
})

test_that("R-22.E: seed_db() databases carry ingest_email and ingest_file.message_id", {
  db <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_true(DBI::dbExistsTable(con, "ingest_email"))
  expect_true("message_id" %in% DBI::dbListFields(con, "ingest_file"))
})

test_that("R-22.E: the mutation layer accepts db_append() to ingest_email and logs an insert in change_log", {
  db <- seed_db(dir = withr::local_tempdir())
  con <- seed_con(db)
  withr::defer(DBI::dbDisconnect(con, shutdown = TRUE))
  before <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM change_log WHERE tbl = 'ingest_email'")$n

  row <- data.frame(
    message_id = "manual-0001@example.org",
    sent_at = as.POSIXct("2026-10-23 03:13:05", tz = "UTC"),
    sender = "reports@example.org", sender_name = "ALS Reports",
    subject = "Quarterly report", in_reply_to = NA_character_,
    folder = "input2026-10-23 1413 Quarterly report",
    first_seen_at = as.POSIXct("2026-10-25 00:00:00", tz = "UTC"),
    stringsAsFactors = FALSE
  )
  expect_no_error(db_append(con, "ingest_email", row, actor = "test", reason = "R-22.E"))

  got <- DBI::dbGetQuery(con, "SELECT * FROM ingest_email")
  expect_equal(nrow(got), 1L)
  expect_identical(got$message_id, "manual-0001@example.org")
  log <- DBI::dbGetQuery(con, "SELECT action, actor FROM change_log WHERE tbl = 'ingest_email'")
  expect_equal(nrow(log) - before, 1L)
  expect_identical(log$action[nrow(log)], "insert")
})

# ---- 2. email_headers() ------------------------------------------------------------

test_that("R-22.E: email_headers() parses plain headers - id without brackets, From name and lower-cased address, Date offset to UTC, In-Reply-To", {
  h <- ie_hdr(ie_headers())
  expect_type(h, "list")
  expect_true(all(c("message_id", "sent_at", "sender", "sender_name", "subject", "in_reply_to")
                  %in% names(h)), info = paste(names(h), collapse = ","))
  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_identical(h$sender, "reports@example.org")
  expect_identical(h$sender_name, "ALS Reports")
  expect_identical(h$subject, "EXTERNAL  Blaxland Quarterly Aug Report",
                   info = "internal whitespace is kept (folder names carry the double space)")
  expect_identical(h$in_reply_to, "req-0001.ab12@example.org")
  expect_s3_class(h$sent_at, "POSIXct")
  expect_identical(ie_utc(h$sent_at), "2026-10-23 03:13:05")
  expect_identical(attr(h$sent_at, "tzone"), "UTC")
})

test_that("R-22.E: email_headers() converts Date offsets to UTC - +1100, +1000, -0500, a trailing (AEDT) comment, no weekday", {
  cases <- list(
    c("Thu, 23 Oct 2026 14:13:05 +1100", "2026-10-23 03:13:05"),
    c("Mon, 1 Jun 2026 09:00:00 +1000", "2026-05-31 23:00:00"),
    c("Fri, 2 Jan 2026 22:30:00 -0500", "2026-01-03 03:30:00"),
    c("Thu, 23 Oct 2026 14:13:05 +1100 (AEDT)", "2026-10-23 03:13:05"),
    c("23 Oct 2026 14:13:05 +1100", "2026-10-23 03:13:05")
  )
  for (cs in cases) {
    h <- ie_hdr(ie_headers(date = cs[[1]]))
    expect_identical(ie_utc(h$sent_at), cs[[2]], info = cs[[1]])
  }
})

test_that("R-22.E: email_headers() unfolds a folded Subject (CRLF + whitespace continuation)", {
  hdrs <- ie_headers(subject = "EXTERNAL  Blaxland Quarterly")
  i <- grep("^Subject:", hdrs)
  hdrs <- append(hdrs, " Aug Report", after = i)
  h <- ie_hdr(hdrs)
  expect_identical(h$subject, "EXTERNAL  Blaxland Quarterly Aug Report")
  # the continuation line is not mistaken for a header of its own
  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
})

test_that("R-22.E: email_headers() decodes RFC 2047 B-encoded subjects, including two encoded-words folded across lines", {
  s <- "Résultats d’analyse – août ES2612345"
  h <- ie_hdr(ie_headers(subject = paste0("=?utf-8?B?", ie_b64(s), "?=")))
  expect_identical(h$subject, enc2utf8(s))

  # Outlook splits a long subject into several encoded-words on folded lines;
  # the whitespace between adjacent encoded-words is not part of the text.
  a <- "Blaxland Quarterly "
  b <- "Aug Report – 2026"
  hdrs <- ie_headers(subject = paste0("=?UTF-8?B?", ie_b64(a), "?="))
  hdrs <- append(hdrs, paste0(" =?UTF-8?B?", ie_b64(b), "?="), after = grep("^Subject:", hdrs))
  h2 <- ie_hdr(hdrs)
  expect_identical(h2$subject, enc2utf8(paste0(a, b)))
})

test_that("R-22.E: email_headers() decodes RFC 2047 Q-encoded subjects - underscores, =XX bytes, lower-case charset, iso-8859-1, mixed with plain text", {
  h <- ie_hdr(ie_headers(subject = "=?UTF-8?Q?Caf=C3=A9_report_=E2=80=93_ES2612345?="))
  expect_identical(h$subject, enc2utf8("Café report – ES2612345"))

  h2 <- ie_hdr(ie_headers(subject = "Re: =?utf-8?q?caf=C3=A9?= results"))
  expect_identical(h2$subject, enc2utf8("Re: café results"))

  h3 <- ie_hdr(ie_headers(subject = "=?iso-8859-1?Q?caf=E9_au_lait?="))
  expect_identical(h3$subject, enc2utf8("café au lait"))
})

test_that("R-22.E: email_headers() reads From as a bare address, as a quoted display name, and as an encoded display name", {
  h <- ie_hdr(ie_headers(from = "Lab.Results@Example.ORG"))
  expect_identical(h$sender, "lab.results@example.org")
  expect_true(is.na(h$sender_name))
  expect_type(h$sender_name, "character")

  h2 <- ie_hdr(ie_headers(from = "\"Smith, Jo\" <Jo.Smith@Example.org>"))
  expect_identical(h2$sender, "jo.smith@example.org")
  expect_identical(h2$sender_name, "Smith, Jo")

  h3 <- ie_hdr(ie_headers(from = "=?utf-8?Q?Ren=C3=A9e_Lab?= <renee@example.org>"))
  expect_identical(h3$sender, "renee@example.org")
  expect_identical(h3$sender_name, enc2utf8("Renée Lab"))

  h4 <- ie_hdr(ie_headers(from = "<bracketed@example.org>"))
  expect_identical(h4$sender, "bracketed@example.org")
  expect_true(is.na(h4$sender_name))
})

test_that("R-22.E: email_headers() takes Message-ID with or without brackets, folded onto the next line, and in any header-name case", {
  h <- ie_hdr(ie_headers(message_id = "bare-0002@example.org"))
  expect_identical(h$message_id, "bare-0002@example.org")

  # Outlook writes "Message-ID:" then the id on a folded continuation line.
  hdrs <- ie_headers(message_id = NULL)
  hdrs <- c(hdrs, "Message-ID:", "\t<folded-0003@example.org>")
  h2 <- ie_hdr(hdrs)
  expect_identical(h2$message_id, "folded-0003@example.org")

  hdrs3 <- sub("^Message-ID:", "Message-Id:", ie_headers(message_id = "<case-0004@example.org>"))
  hdrs3 <- sub("^Subject:", "SUBJECT:", hdrs3)
  h3 <- ie_hdr(hdrs3)
  expect_identical(h3$message_id, "case-0004@example.org")
  expect_identical(h3$subject, "EXTERNAL  Blaxland Quarterly Aug Report")
})

test_that("R-22.E: email_headers() gives NA in_reply_to when there is none, and NA subject when there is none", {
  h <- ie_hdr(ie_headers(in_reply_to = NULL))
  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_true(is.na(h$in_reply_to))
  expect_type(h$in_reply_to, "character")

  hdrs <- ie_headers()
  hdrs <- hdrs[!grepl("^Subject:", hdrs)]
  h2 <- ie_hdr(hdrs)
  expect_true(is.na(h2$subject))
})

test_that("R-22.E: email_headers() returns NULL, without error, when there is no Message-ID", {
  dir <- withr::local_tempdir()
  p <- file.path(dir, "_email.eml")
  ie_write_eml(p, ie_headers(message_id = NULL))
  expect_no_error(h <- email_headers(p))
  expect_null(h)
})

test_that("R-22.E: email_headers() stops at the first blank line - a Message-ID or Subject inside the body (a forwarded message) is never read", {
  inner <- c("--=_b1", "Content-Type: message/rfc822", "",
             "Message-ID: <inner-0005@example.org>", "Subject: the forwarded one",
             "From: someone.else@example.org", "", "inner body", "--=_b1--")
  h <- ie_hdr(ie_headers(), body = inner)
  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_identical(h$subject, "EXTERNAL  Blaxland Quarterly Aug Report")
  expect_identical(h$sender, "reports@example.org")

  # and an outer block with no Message-ID does not borrow the body's
  h2 <- ie_hdr(ie_headers(message_id = NULL), body = inner)
  expect_null(h2)
})

test_that("R-22.E: email_headers() gives identical results for LF and CRLF files", {
  hdrs <- ie_headers()
  hdrs <- append(hdrs, " continued", after = grep("^Subject:", hdrs))
  a <- ie_hdr(hdrs, eol = "\r\n")
  b <- ie_hdr(hdrs, eol = "\n")
  expect_identical(a$subject, "EXTERNAL  Blaxland Quarterly Aug Report continued")
  expect_identical(a, b)
  expect_false(any(grepl("\r", unlist(lapply(a, as.character)), fixed = TRUE)))
})

test_that("R-22.E: email_headers() is correct on an email with a multi-MB inlined attachment", {
  dir <- withr::local_tempdir()
  p <- file.path(dir, "_email.eml")
  ie_write_eml(p, ie_headers(), body = ie_big_body(4 * 1024^2))
  expect_gt(file.size(p), 4 * 1024^2)
  h <- email_headers(p)
  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_identical(ie_utc(h$sent_at), "2026-10-23 03:13:05")
})

test_that("R-22.E: email_headers() reads only the header block - a 1 GiB body costs neither time nor memory", {
  skip_on_cran()
  skip_on_os("windows") # the sparse file below would be 1 GiB of real disk on NTFS
  dir <- withr::local_tempdir()
  p <- file.path(dir, "_email.eml")
  ie_write_eml(p, ie_headers(), body = c("--=_b1", "Content-Type: application/pdf", ""))
  # Extend to 1 GiB without writing it: a sparse file, a few KB on disk.
  con <- file(p, "r+b")
  seek(con, 1024^3, rw = "write")
  writeBin(as.raw(0x0a), con)
  close(con)
  expect_gt(file.size(p), 1024^3)

  invisible(gc(reset = TRUE))
  vcells_before <- gc()["Vcells", 2]
  t <- system.time(h <- email_headers(p))[["elapsed"]]
  g <- gc()
  peak_mb <- g["Vcells", ncol(g)] - vcells_before # "max used (Mb)" since reset

  expect_identical(h$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_lt(t, 1)
  expect_lt(peak_mb, 64)
})

test_that("R-22.E: email_headers() returns NULL, without error, for a file with no header block (binary junk, blank first line, empty file)", {
  dir <- withr::local_tempdir()
  junk <- file.path(dir, "junk.eml")
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff, 0x10)), junk)
  expect_no_error(expect_null(email_headers(junk)))

  blank_first <- file.path(dir, "blank.eml")
  writeLines(c("", "Message-ID: <after-blank@example.org>", "Subject: x"), blank_first)
  expect_no_error(expect_null(email_headers(blank_first)))

  prose <- file.path(dir, "prose.eml")
  writeLines(c("this is not an email at all", "just some text"), prose)
  expect_no_error(expect_null(email_headers(prose)))

  empty <- file.path(dir, "empty.eml")
  file.create(empty)
  expect_no_error(expect_null(email_headers(empty)))
})

# ---- 3. ingest_dir() ---------------------------------------------------------------

test_that("R-22.E: ingest_dir() on a delivery folder writes one ingest_email row from _email.eml, its folder the folder's basename", {
  s <- ie_setup()
  parent <- withr::local_tempdir()
  name <- "input2026-10-23 1413 EXTERNAL  Blaxland Quarterly Aug Report"
  d <- ie_delivery(parent, name)
  t0 <- Sys.time()
  suppressWarnings(ie_ingest(d, s$db))

  em <- ie_query(s$db, "SELECT * FROM ingest_email")
  expect_equal(nrow(em), 1L)
  expect_identical(em$message_id, "CAF-0001.7f3a@mail.example.org")
  expect_identical(em$sender, "reports@example.org")
  expect_identical(em$sender_name, "ALS Reports")
  expect_identical(em$subject, "EXTERNAL  Blaxland Quarterly Aug Report")
  expect_identical(em$in_reply_to, "req-0001.ab12@example.org")
  expect_identical(em$folder, name)
  expect_identical(ie_utc(em$sent_at), "2026-10-23 03:13:05")
  expect_false(is.na(em$first_seen_at))
  expect_true(abs(as.numeric(difftime(em$first_seen_at, t0, units = "secs"))) < 120)
})

test_that("R-22.E: every ingest_file row routed from the folder carries the message_id - archived, retained_sibling, quarantined and ignored alike", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  suppressWarnings(ie_ingest(d, s$db))

  f <- ie_files(s$db)
  st <- stats::setNames(f$state, f$filename)
  # precondition: the fixture really does reach every terminal state
  expect_identical(st[names(ie_expected_states)], ie_expected_states)
  expect_identical(f$state_reason[f$filename == "XX1234567_0_COA.pdf"], "retained_sibling")
  expect_identical(f$state_reason[f$filename == "random.csv"], "unclaimed")

  mid <- stats::setNames(f$message_id, f$filename)
  for (fn in c(names(ie_expected_states), "_email.eml")) {
    expect_identical(unname(mid[fn]), "CAF-0001.7f3a@mail.example.org", info = fn)
  }
})

test_that("R-22.E: _email.eml ends ignored with reason delivery_email - not quarantined/unclaimed - and gets no asset", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  rep <- suppressWarnings(ie_ingest(d, s$db))

  f <- ie_files(s$db)
  e <- f[f$filename == "_email.eml", , drop = FALSE]
  expect_equal(nrow(e), 1L)
  expect_identical(e$state, "ignored")
  expect_identical(e$state_reason, "delivery_email")
  expect_true(is.na(e$uuid_asset))
  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM asset WHERE hash = ?", e$hash)), 0L)
})

test_that("R-22.E: with remove_ingested on, _email.eml is never deleted - it stays for the inbox to file - while the archived sources are removed", {
  s <- ie_setup(remove_ingested = TRUE)
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  eml_md5 <- unname(tools::md5sum(file.path(d, "_email.eml")))
  rep <- suppressWarnings(ie_ingest(d, s$db))

  expect_true(length(rep$removed_files) > 0, info = "precondition: the run removed its archived sources")
  expect_false(any(basename(rep$removed_files) == "_email.eml"))
  expect_true(file.exists(file.path(d, "_email.eml")))
  expect_identical(unname(tools::md5sum(file.path(d, "_email.eml"))), eml_md5)
})

test_that("R-22.E: a folder left holding only _email.eml is not spent, so ingest_inbox() does not unlink it before the inbox can file it", {
  s <- ie_setup(remove_ingested = TRUE)
  root <- withr::local_tempdir()
  name <- "input2026-10-23 1413 delivery"
  d <- file.path(root, name)
  dir.create(d)
  for (f in ie_proj_a()) stopifnot(file.copy(f, file.path(d, basename(f))))
  ie_write_eml(file.path(d, "_email.eml"), ie_headers())

  res <- suppressWarnings(suppressMessages(ingest_inbox(root, db = s$db)))
  expect_true(dir.exists(d))
  expect_identical(list.files(d, all.files = TRUE, no.. = TRUE), "_email.eml")
  expect_false(sampleTidy:::.ig_folder_is_spent(d))
  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 1L)
})

test_that("R-22.E: inbox_run() files _email.eml to _emails/<folder>/ and records the email under that folder name", {
  s <- inbox_setup()
  now <- Sys.time()
  name <- "input2026-10-23 1413 EXTERNAL  Blaxland Quarterly Aug Report"
  tmp <- withr::local_tempdir()
  eml <- file.path(tmp, "_email.eml")
  ie_write_eml(eml, ie_headers())
  d <- make_inbox_folder(s$input_dir, name, c(inbox_proj_a_files(), eml), now = now)

  run_inbox(s, now = now)

  dest <- file.path(s$archive_dir, "_emails", name)
  expect_true(file.exists(file.path(dest, "_email.eml")))
  expect_false(dir.exists(d))
  em <- ie_query(s$db, "SELECT message_id, folder FROM ingest_email")
  expect_equal(nrow(em), 1L)
  expect_identical(em$folder, name)
  f <- ie_files(s$db)
  expect_identical(f$state[f$filename == "_email.eml"], "ignored")
})

test_that("R-22.E: re-running ingest_dir() over the same folder neither duplicates the ingest_email row nor errors, and first_seen_at is unchanged", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  suppressWarnings(ie_ingest(d, s$db))
  first <- ie_query(s$db, "SELECT * FROM ingest_email")
  n_log <- ie_query(s$db, "SELECT count(*) AS n FROM change_log WHERE tbl = 'ingest_email'")$n

  expect_no_error(suppressWarnings(ie_ingest(d, s$db)))
  again <- ie_query(s$db, "SELECT * FROM ingest_email")
  expect_equal(nrow(again), 1L)
  expect_identical(again$first_seen_at, first$first_seen_at)
  expect_identical(again$folder, first$folder)
  expect_identical(ie_query(s$db, "SELECT count(*) AS n FROM change_log WHERE tbl = 'ingest_email'")$n, n_log)
  f <- ie_files(s$db)
  expect_true(all(f$message_id == "CAF-0001.7f3a@mail.example.org"))
})

test_that("R-22.E: ingest_dir() writes the ingest_email row through the mutation layer (one change_log insert)", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  suppressWarnings(ie_ingest(d, s$db))
  log <- ie_query(s$db, "SELECT action, actor, reason FROM change_log WHERE tbl = 'ingest_email'")
  expect_equal(nrow(log), 1L)
  expect_identical(log$action, "insert")
  expect_false(is.na(log$actor))
  expect_false(is.na(log$reason))
})

test_that("R-22.E: a second folder carrying the same Message-ID adds no row and no error; first sighting wins, the second folder's files still get the id", {
  s <- ie_setup()
  parent <- withr::local_tempdir()
  d1 <- ie_delivery(parent, "input2026-10-23 1413 first")
  suppressWarnings(ie_ingest(d1, s$db))
  first <- ie_query(s$db, "SELECT * FROM ingest_email")

  # The same email saved again (re-forwarded to the inbox): same id, different
  # bytes, and one new attachment.
  d2 <- file.path(parent, "input2026-10-24 0900 second")
  dir.create(d2)
  ie_write_eml(file.path(d2, "_email.eml"),
               ie_headers(extra = "X-Saved-By: power-automate-retry"))
  writeLines(c("note,value", "resent,1"), file.path(d2, "resend-note.csv"))
  expect_no_error(suppressWarnings(ie_ingest(d2, s$db)))

  em <- ie_query(s$db, "SELECT * FROM ingest_email")
  expect_equal(nrow(em), 1L)
  expect_identical(em$folder, "input2026-10-23 1413 first")
  expect_identical(em$first_seen_at, first$first_seen_at)

  f <- ie_files(s$db)
  expect_equal(sum(f$filename == "_email.eml"), 2L) # two different eml byte streams
  expect_true(all(f$message_id[f$filename %in% c("_email.eml", "resend-note.csv")] ==
                    "CAF-0001.7f3a@mail.example.org"))
})

test_that("R-22.E: a file already linked to one email keeps that message_id when a later email re-delivers the same bytes", {
  s <- ie_setup()
  parent <- withr::local_tempdir()
  d1 <- ie_delivery(parent, "input2026-10-23 1413 first")
  suppressWarnings(ie_ingest(d1, s$db))

  d2 <- file.path(parent, "input2026-10-24 0900 resend")
  dir.create(d2)
  stopifnot(file.copy(testthat::test_path("fixtures", "esdat", "random.csv"), file.path(d2, "random.csv")))
  ie_write_eml(file.path(d2, "_email.eml"),
               ie_headers(message_id = "<CAF-0002.resend@mail.example.org>",
                          subject = "FW: resend"))
  suppressWarnings(ie_ingest(d2, s$db))

  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 2L)
  f <- ie_files(s$db)
  expect_identical(f$message_id[f$filename == "random.csv"], "CAF-0001.7f3a@mail.example.org")
})

test_that("R-22.E: a file first routed with no email gets its message_id filled when it later arrives in an email folder", {
  s <- ie_setup()
  parent <- withr::local_tempdir()
  d1 <- ie_delivery(parent, "loose", eml = FALSE)
  suppressWarnings(ie_ingest(d1, s$db))
  f1 <- ie_files(s$db)
  expect_true(all(is.na(f1$message_id)))

  d2 <- file.path(parent, "input2026-10-24 0900 with email")
  dir.create(d2)
  stopifnot(file.copy(testthat::test_path("fixtures", "esdat", "random.csv"), file.path(d2, "random.csv")))
  ie_write_eml(file.path(d2, "_email.eml"), ie_headers())
  suppressWarnings(ie_ingest(d2, s$db))

  f2 <- ie_files(s$db)
  expect_identical(f2$message_id[f2$filename == "random.csv"], "CAF-0001.7f3a@mail.example.org")
})

test_that("R-22.E: a folder with no _email.eml behaves as before - same terminal states, no ingest_email row, message_id NULL throughout", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 no email", eml = FALSE)
  suppressWarnings(ie_ingest(d, s$db))

  f <- ie_files(s$db)
  st <- stats::setNames(f$state, f$filename)
  expect_identical(st[names(ie_expected_states)], ie_expected_states)
  expect_true(all(is.na(f$message_id)))
  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 0L)
})

test_that("R-22.E: an _email.eml with no Message-ID writes no row and no error; the files keep message_id NULL and the eml is still a delivery_email", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 no id",
                   headers = ie_headers(message_id = NULL))
  expect_no_error(suppressWarnings(ie_ingest(d, s$db)))

  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 0L)
  f <- ie_files(s$db)
  expect_true(all(is.na(f$message_id)))
  st <- stats::setNames(f$state, f$filename)
  expect_identical(st[names(ie_expected_states)], ie_expected_states)
  expect_identical(f$state_reason[f$filename == "_email.eml"], "delivery_email")
})

test_that("R-22.E: a malformed _email.eml (no header block) is not fatal - one warning naming it, message_id NULL, the rest of the import unaffected", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 malformed", eml = FALSE)
  writeBin(as.raw(c(0x00, 0xff, 0x10, 0x0a, 0x0a, 0x41, 0x42)), file.path(d, "_email.eml"))

  warns <- character(0)
  rep <- withCallingHandlers(
    ie_ingest(d, s$db),
    warning = function(w) {
      warns <<- c(warns, conditionMessage(w))
      invokeRestart("muffleWarning")
    }
  )
  expect_false(isTRUE(rep$failed))
  expect_equal(sum(grepl("_email.eml", warns, fixed = TRUE)), 1L,
               info = paste(warns, collapse = " || "))

  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 0L)
  f <- ie_files(s$db)
  expect_true(all(is.na(f$message_id)))
  st <- stats::setNames(f$state, f$filename)
  expect_identical(st[names(ie_expected_states)], ie_expected_states)
  expect_identical(st[["_email.eml"]], "ignored")
  expect_identical(f$state_reason[f$filename == "_email.eml"], "delivery_email")
})

test_that("R-22.E: a dry run writes no ingest_email row and sets no message_id; a following real run records both", {
  s <- ie_setup()
  d <- ie_delivery(withr::local_tempdir(), "input2026-10-23 1413 delivery")
  suppressWarnings(ie_ingest(d, s$db, dry_run = TRUE))
  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 0L)
  expect_true(all(is.na(ie_files(s$db)$message_id)))

  suppressWarnings(ie_ingest(d, s$db))
  expect_equal(nrow(ie_query(s$db, "SELECT 1 FROM ingest_email")), 1L)
  f <- ie_files(s$db)
  expect_true(all(f$message_id == "CAF-0001.7f3a@mail.example.org"))
})

test_that("R-22.E: an _email.eml already stored quarantined/unclaimed (before R-22.E) is re-decided as delivery_email under reconsider = TRUE", {
  s <- ie_setup()
  d <- file.path(withr::local_tempdir(), "input2026-10-20 0900 old")
  dir.create(d, recursive = TRUE)
  p <- file.path(d, "_email.eml")
  ie_write_eml(p, ie_headers())
  h <- hash_file(p)
  con <- seed_con(s$db)
  DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, path_first_seen, state, state_reason)
                       VALUES (?, '_email.eml', ?, 'quarantined', 'unclaimed')", params = list(h, p))
  DBI::dbDisconnect(con, shutdown = TRUE)

  suppressWarnings(ie_ingest(d, s$db, reconsider = TRUE))
  f <- ie_files(s$db)
  expect_identical(f$state[f$hash == h], "ignored")
  expect_identical(f$state_reason[f$hash == h], "delivery_email")
  expect_identical(f$message_id[f$hash == h], "CAF-0001.7f3a@mail.example.org")
})

# ---- 4. db_checks ------------------------------------------------------------------
# The failing case is table-driven in helper-db-checks.R (dbc_violation_cases).

test_that("R-22.E: ingest_file_email_dangling is an hourly error check", {
  core <- db_checks_core()
  r <- core[core$name == "ingest_file_email_dangling", , drop = FALSE]
  expect_equal(nrow(r), 1L)
  expect_identical(r$tier, "hourly")
  expect_identical(r$severity, "error")
})

test_that("R-22.E: ingest_file_email_dangling passes when every message_id resolves, and when message_id is NULL", {
  db <- dbc_db()
  res <- dbc_with(db, function(con) {
    DBI::dbExecute(con, "INSERT INTO ingest_email (message_id, sent_at, sender, sender_name, subject,
                                                   in_reply_to, folder, first_seen_at)
                         VALUES ('clean-0001@example.org', TIMESTAMP '2026-10-23 03:13:05',
                                 'reports@example.org', 'ALS Reports', 'Quarterly',
                                 NULL, 'input2026-10-23 1413 Quarterly', TIMESTAMP '2026-10-25 00:00:00')")
    DBI::dbExecute(con, "INSERT INTO ingest_file (hash, filename, state, state_reason, message_id)
                         VALUES (?, '_email.eml', 'ignored', 'delivery_email', 'clean-0001@example.org')",
                   params = list(dbc_hex(912)))
    expect_gt(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM ingest_file WHERE message_id IS NULL")$n, 0)
    db_checks(con, tier = "hourly")
  })
  r <- dbc_row(res, "ingest_file_email_dangling")
  expect_equal(nrow(r), 1L)
  expect_identical(r$status, "pass")
  expect_true(all(res$status == "pass"), info = dbc_bad(res))
})
