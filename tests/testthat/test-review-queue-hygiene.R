# PLAN-16 Phase 4 - source-scanning meta-tests for PLAN-16 hygiene criteria:
# R-16.6 (SQL-side JSON read of a payload value - the R-side regex half was
# RETIRED 2026-07-25, see its section below for why), R-16.7
# (`.rc_serialise_payload()` is gone), R-16.8 (every review-writing site
# routes through the structured constructor `.rq_row()`, no hand-built
# `paste0()`/`sprintf()` payload string survives).
#
# Scope: R-16.6, R-16.7, R-16.8, plus the CALL-SITE half of R-16.18 (added
# 2026-07-25 under Q1 - see its section at the foot of this file). R-16.9/
# R-16.10/R-16.11/R-16.14/R-16.17/R-16.19/R-16.20 and R-16.18's CONTENT/SHAPE
# half belong to test-review-queue-payload.R - do not duplicate them here.
# The dividing line is the assertion's subject, not its criterion number: a
# scan of `R/` for a forbidden construct lives here; an assertion about what a
# stored payload contains lives there. R-16.18 has one of each.
#
# 2026-07-25 (Phase-7b round-3 remediation, Robin's Rulings 1): the R-side
# regex-on-payload ban is DELETED (see its section below), R-16.6's SQL-side
# half is made CONCATENATION-AWARE (a split-`paste0()`-literal evasion, F4,
# is now caught), and R-16.8's routing scan is WIDENED to `R/commit.R` and
# made PER-SITE rather than per-function (F6/F5). `R/` no longer contains
# `.rc_serialise_payload()` or any of the historical thirteen hand-built
# payload sites this file was originally written RED against - every
# assertion below is checked against TODAY's code, not aspirationally.
#
# Fixtures: none - these are pure static source scans, no DB is touched and
# helper-db.R is not used (per the brief, do not edit it; nothing here needs
# it). No corpus fixtures either.
#
# THE SINGLE BIGGEST RISK for a meta-test that scans source is a scanner that
# silently matches nothing and "passes" vacuously. Every scan below is
# comment- and string-aware (either by construction, via `getParseData()`
# AST analysis that never descends into COMMENT/STR_CONST tokens in the
# first place, or explicitly, by blanking COMMENT/STR_CONST spans out of the
# source text before running a textual regex over what remains - see
# `.hy_scrub_lines()`) AND carries at least one POSITIVE CONTROL (a decoy
# proving the scanner would catch a genuine violation) plus, where the risk
# of a naive line-grep is highest, a NEGATIVE CONTROL (a decoy proving a
# mere comment/string mention of the forbidden pattern does NOT trip it).
#
# Two scanning strategies are used, deliberately:
#  - R-16.7's call-site scan operates on COMMENT/STR_CONST-SCRUBBED SOURCE
#    TEXT with a regex, per the brief's own suggested idiom - the forbidden
#    thing (a call to `.rc_serialise_payload()`) is itself R-level syntax, and
#    scrub-then-grep is the simplest robust way to check "is this pattern
#    present in real code" without hand-rolling a full call-graph analysis.
#  - R-16.6's SQL-side scan operates on the CONTENTS of STR_CONST tokens
#    (SQL lives inside R string literals) - the opposite polarity: comments
#    are excluded, but string literals are exactly the corpus, not something
#    to strip. It is CONCATENATION-AWARE (2026-07-25): a `paste0()` call's
#    direct STR_CONST arguments are also joined and scanned as one candidate
#    string, so a forbidden keyword/operator split across two literal
#    fragments of the same `paste0()` call cannot evade the per-literal scan
#    (F4, round-3 slice I).
#  - R-16.8's hand-builder scan uses `getParseData()` STRUCTURALLY (walking
#    the parse tree to find the actual right-hand side of an assignment or
#    named-call-argument literally targeting `payload`) rather than textual
#    co-occurrence, because a coarser scan false-positives on functions that
#    assign `payload = NA_character_` in one branch and use an unrelated
#    `paste0()` for a different field (`reason`) in another (verified against
#    `.rc_qc_filter()`, R/reconcile.R:131-146, during authoring) - this
#    approach is comment/string-aware BY CONSTRUCTION, since `parse()` never
#    puts comment or string-literal content into the expression tree at all.
#    R-16.8's routing-coverage scan (part 2) is likewise structural and, as
#    of 2026-07-25, PER PRODUCING SITE (an append-idiom RHS or a
#    `db_append("review_queue", ...)`'s enclosing block), not merely per
#    enclosing function - a function that routes ONE branch correctly while
#    hand-building another can no longer pass on the strength of the first
#    branch alone (F5, round-3 slice I).

# ---- local scanning helpers (this file only; do not touch helper-db.R) -----

#' Absolute path to the package root, resolved via the CURRENT TEST FILE's
#' own location (`testthat::test_path()`), not `getwd()` - `test_file()`/
#' `test_dir()` change the working directory to `tests/testthat` while a
#' test runs, so a bare `getwd()`-relative path would silently break under
#' the harness even though it might look right sourced interactively.
.hy_pkg_root <- function() {
  normalizePath(testthat::test_path("..", ".."), mustWork = TRUE)
}

.hy_r_files <- function() {
  sort(list.files(file.path(.hy_pkg_root(), "R"), pattern = "\\.R$", full.names = TRUE))
}

.hy_migration_files <- function() {
  dir <- file.path(.hy_pkg_root(), "dev", "migrations")
  if (!dir.exists(dir)) return(character(0))
  sort(list.files(dir, pattern = "\\.R$", full.names = TRUE))
}

#' A "source object": the file's lines plus its `getParseData()` frame, so
#' every scan below can run identically over a real file OR a synthetic
#' decoy snippet (`.hy_source_from_text()`) - the decoy exercises the exact
#' same scanning code as the real scan, never a re-implementation of it.
.hy_source_from_file <- function(path) {
  list(
    path = path,
    lines = readLines(path, warn = FALSE, encoding = "UTF-8"),
    pd = tryCatch(utils::getParseData(parse(path, keep.source = TRUE, encoding = "UTF-8")),
                  error = function(e) NULL)
  )
}

.hy_source_from_text <- function(text, path = "<synthetic>") {
  list(
    path = path,
    lines = strsplit(text, "\n", fixed = TRUE)[[1]],
    pd = tryCatch(utils::getParseData(parse(text = text, keep.source = TRUE)),
                  error = function(e) NULL)
  )
}

#' Blank out (replace with spaces, preserving line/column layout so line
#' numbers stay meaningful) the source span `[line1,col1]-[line2,col2]`
#' (1-based, inclusive, as returned by `getParseData()`) in a lines vector.
.hy_blank_span <- function(lines, line1, col1, line2, col2) {
  if (line1 == line2) {
    ln <- lines[line1]
    n <- nchar(ln)
    end <- min(col2, n)
    if (col1 <= end) substr(ln, col1, end) <- strrep(" ", end - col1 + 1L)
    lines[line1] <- ln
    return(lines)
  }
  ln1 <- lines[line1]
  n1 <- nchar(ln1)
  if (col1 <= n1) substr(ln1, col1, n1) <- strrep(" ", n1 - col1 + 1L)
  lines[line1] <- ln1
  if (line2 > line1 + 1L) {
    mid <- (line1 + 1L):(line2 - 1L)
    lines[mid] <- vapply(lines[mid], function(l) strrep(" ", nchar(l)), character(1))
  }
  ln2 <- lines[line2]
  end <- min(col2, nchar(ln2))
  if (end >= 1L) substr(ln2, 1L, end) <- strrep(" ", end)
  lines[line2] <- ln2
  lines
}

#' Comment- and string-literal-blanked copy of `src$lines`. Used for every
#' textual (regex-over-source) scan below so a cross-reference comment or a
#' string constant that happens to mention a forbidden pattern can never
#' produce a false positive.
.hy_scrub_lines <- function(src) {
  lines <- src$lines
  pd <- src$pd
  if (is.null(pd) || nrow(pd) == 0) return(lines)
  strip <- pd[pd$token %in% c("COMMENT", "STR_CONST"),
              c("line1", "col1", "line2", "col2")]
  if (nrow(strip) == 0) return(lines)
  for (i in seq_len(nrow(strip))) {
    lines <- .hy_blank_span(lines, strip$line1[i], strip$col1[i],
                             strip$line2[i], strip$col2[i])
  }
  lines
}

#' Top-level statement spans (`line1`/`line2`), i.e. one row per file-level
#' `<name> <- function(...) { ... }` (or other top-level expression). Every
#' function in `R/` is defined this way in this package, so a top-level span
#' is exactly "one function's full body" for scoping a scan to "does THIS
#' function co-occur with THAT pattern" rather than "does this pattern occur
#' anywhere in the whole file" (the latter cannot distinguish two unrelated
#' hits in two different functions from one real co-occurring pair).
.hy_top_level_spans <- function(src) {
  pd <- src$pd
  if (is.null(pd) || nrow(pd) == 0) {
    return(data.frame(line1 = integer(0), line2 = integer(0), id = integer(0)))
  }
  top <- pd[pd$parent == 0, c("id", "line1", "line2")]
  top[order(top$line1), ]
}

#' Named top-level spans: `list(fn_name = c(line1=, line2=))` for every
#' top-level `<name> <- function(...) {...}` in the file. Used by R-16.8's
#' "does enclosing function X call `.rq_row()`" check, keyed by function
#' name (robust to line-number drift) rather than by line range.
.hy_named_top_level_spans <- function(src) {
  pd <- src$pd
  out <- list()
  if (is.null(pd) || nrow(pd) == 0) return(out)
  top <- pd[pd$parent == 0, c("id", "line1", "line2")]
  for (i in seq_len(nrow(top))) {
    tid <- top$id[i]
    kids <- pd[pd$parent == tid, ]
    if (nrow(kids) < 2) next
    kids <- kids[order(kids$line1, kids$col1), ]
    first <- kids[1, ]
    if (first$token != "expr") next
    symrow <- pd[pd$parent == first$id & pd$token == "SYMBOL", ]
    if (nrow(symrow) != 1) next
    out[[symrow$text[1]]] <- c(line1 = top$line1[i], line2 = top$line2[i])
  }
  out
}

# ==== R-16.6, part 1: R-side regex ban - RETIRED 2026-07-25 ================
#
# Robin's Ruling 1 (round-3 remediation, dev/tdd-run/run-state.md "ROUND-3
# RESULT + ROBIN'S RULINGS"): the R-side regex-on-payload ban
# (`.HY_REGEX_FNS <- c("sub", "gsub", "regmatches", "regexpr", "grepl")` plus
# the scanner block that used to sit here) is DELETED, not weakened. It
# existed to stop exactly ONE dead end: hand-parsing the legacy k=v payload
# grammar. That dead end is gone - migration 006 (the legacy k=v parser) was
# retired in commit bc3d146, no `review_queue.payload` row in that shape
# still exists, and every producer now emits JSON via `.rq_row()`/
# `.rq_skip()`. Guarding a retired grammar protects nothing.
#
# It was also unenforceable AS WRITTEN, independent of the grammar retiring:
# a five-name deny-list cannot express "do not parse this text". Phase-7b
# round-3 slice I evaded it three separate ways against a fully green suite -
# `gregexpr()`, `regexec()`, and a `strsplit()` + `startsWith()` hand-rolled
# parser using no banned symbol at all. A longer name list is not the fix:
# the property ("no ad-hoc text-parsing of a structured payload") has no
# finite enumeration of the R functions capable of it. Removing a control
# that reads as protection while providing none is the point - it is
# deliberately NOT replaced with a longer list.
#
# `.hy_payload_word_pat` below is NOT retired - R-16.6's SQL-side half (next
# section) still uses it; that half guards a different, still-live risk (the
# DuckDB JSON extension is not guaranteed to autoload).

.hy_payload_word_pat <- "(?<![[:alnum:]_])payload(?![[:alnum:]_])"

# ==== R-16.6, part 2: no SQL-side JSON read of a payload value =====================

.HY_SQL_JSON_PAT <- "(json_extract|json_valid|->>|->|\\bLIKE\\b|\\bSIMILAR\\s+TO\\b)"

#' A literal must first look like SQL before the JSON-operator/`payload`
#' co-occurrence check even considers it. Without this gate, `->` alone
#' trips on any STR_CONST containing an arrow AND the word "payload" -
#' including a plain human-readable message with no SQL in it at all, e.g.
#' `reason = "... payload -> typed columns"` (the retired legacy migration
#' once read exactly that; a prior worker "fixed" the trip
#' by rewording the prose to "payload to typed columns" instead of fixing
#' the scanner - the trap stayed armed for the next arrow). Chosen fix is
#' option (a) from the brief: require a real SQL keyword (word-boundary,
#' case-insensitive) to appear in the literal first. Rejected (b) (walk the
#' parse tree to a DB call) as more machinery than the false-positive needs;
#' rejected (c) (require the arrow adjacent to a quoted identifier/`$.`
#' path) as harder to state precisely than "is this actually SQL" and no
#' more robust against the real failure mode observed.
.HY_SQL_KEYWORD_PAT <- "\\b(SELECT|FROM|WHERE|INSERT|UPDATE|DELETE|CREATE|ALTER|JOIN|VALUES)\\b"

.hy_looks_like_sql <- function(lit) {
  grepl(.HY_SQL_KEYWORD_PAT, lit, perl = TRUE, ignore.case = TRUE)
}

.hy_string_literals <- function(src) {
  pd <- src$pd
  if (is.null(pd) || nrow(pd) == 0) return(character(0))
  pd$text[pd$token == "STR_CONST"]
}

#' CONCATENATION-AWARE (2026-07-25, F4 round-3 slice I): a per-literal-only
#' scan is evadable by splitting a forbidden keyword and the `payload`
#' reference across TWO SEPARATE string-literal arguments of one `paste0()`
#' call - e.g. `paste0("SELECT json_extract(", "payload", ", '$.tier') FROM
#' review_queue")` - because neither literal alone contains both the keyword
#' and the word. This walks `pd` STRUCTURALLY (never textually - a decoy
#' that merely mentions "paste0" in a comment/string cannot trip it) to find
#' every `paste0(...)` call, collects the DIRECT `STR_CONST` children of its
#' argument list in source order (skipping any non-literal argument - a
#' variable's runtime value is unknowable statically, so it is simply
#' omitted from the join rather than treated as a boundary), and joins them
#' with `""` (paste0's own separator) into ONE candidate string per call,
#' exactly as the call would render at runtime if every argument were a
#' literal. Requires >= 2 literal fragments per call (a single-literal
#' `paste0()` degenerates to a plain literal already covered by
#' `.hy_string_literals()` above). Only `paste0()` is handled - `paste()`'s
#' default `sep = " "` inserts a space this package's SQL-building code does
#' not use, and a grep across `R/` found no bare `paste()` call assembling
#' SQL text (verified 2026-07-25).
.hy_paste0_concat_literals <- function(pd) {
  out <- character(0)
  if (is.null(pd) || nrow(pd) == 0) return(out)
  calls <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == "paste0", ]
  if (nrow(calls) == 0) return(out)
  for (i in seq_len(nrow(calls))) {
    wrap <- pd[pd$id == calls$parent[i], ]
    if (nrow(wrap) == 0) next
    call_id <- wrap$parent[1]
    args <- pd[pd$parent == call_id & pd$token == "expr", ]
    args <- args[args$id != wrap$id[1], ]
    if (nrow(args) == 0) next
    args <- args[order(args$line1, args$col1), ]
    parts <- character(0)
    for (j in seq_len(nrow(args))) {
      kids <- pd[pd$parent == args$id[j], ]
      if (nrow(kids) == 1 && kids$token[1] == "STR_CONST") {
        val <- tryCatch(eval(parse(text = kids$text[1])), error = function(e) NA_character_)
        if (!is.na(val)) parts <- c(parts, val)
      }
    }
    if (length(parts) >= 2) out <- c(out, paste(parts, collapse = ""))
  }
  out
}

#' Flag every string literal - OR every `paste0()` call's joined literal
#' fragments (`.hy_paste0_concat_literals()`, concatenation-aware) - that
#' LOOKS LIKE SQL (`.hy_looks_like_sql()`; package SQL text lives inside R
#' string literals - the corpus here is deliberately the OPPOSITE of the
#' comment-scrub above: comments are excluded by only looking at STR_CONST
#' tokens, and string content is exactly what is inspected) AND contains
#' BOTH a forbidden SQL-JSON operator/keyword AND the word `payload`.
.hy_scan_sql_json_on_payload <- function(sources) {
  hits <- list()
  for (src in sources) {
    candidates <- c(.hy_string_literals(src), .hy_paste0_concat_literals(src$pd))
    for (lit in candidates) {
      if (.hy_looks_like_sql(lit) &&
          grepl(.HY_SQL_JSON_PAT, lit, perl = TRUE, ignore.case = TRUE) &&
          grepl(.hy_payload_word_pat, lit, perl = TRUE)) {
        hits[[length(hits) + 1]] <- list(path = src$path, text = lit)
      }
    }
  }
  hits
}

test_that("R-16.6: no SQL-side JSON read (json_extract/json_valid/->/->>/LIKE/SIMILAR TO) touches a payload value in package SQL, migrations, or stored view definitions (comment-aware; scoped correctly today, decoy proves it would catch a real one)", {
  real_sources <- c(
    lapply(.hy_r_files(), .hy_source_from_file),
    lapply(.hy_migration_files(), .hy_source_from_file)
  )

  # POSITIVE CONTROL (decoy): a genuine SQL-side JSON read of payload - the
  # exact shape B-16.constraints #1 forbids.
  decoy_violation <- .hy_source_from_text(paste(
    "f <- function(con) {",
    "  DBI::dbGetQuery(con, \"SELECT json_extract(payload, '$.tier') FROM review_queue\")",
    "}", sep = "\n"
  ))
  expect_true(
    length(.hy_scan_sql_json_on_payload(list(decoy_violation))) >= 1,
    info = "positive control failed: a synthetic json_extract(payload, ...) SQL string was not flagged"
  )

  # POSITIVE CONTROL (decoy): the bare `->` JSON operator (not json_extract)
  # inside genuine SQL - the exact literal from the brief - must still be
  # caught once it is wrapped in real SQL, proving the SQL-keyword gate
  # narrows false positives without blinding the scanner to true ones.
  decoy_arrow_violation <- .hy_source_from_text(paste(
    "f <- function(con) {",
    "  DBI::dbGetQuery(con, \"SELECT * FROM review_queue WHERE payload -> '$.site' = 'X'\")",
    "}", sep = "\n"
  ))
  expect_true(
    length(.hy_scan_sql_json_on_payload(list(decoy_arrow_violation))) >= 1,
    info = "positive control failed: a genuine SQL string using the bare -> JSON operator on payload was not flagged"
  )

  # POSITIVE CONTROL (decoy), F4 (round-3 slice I): THE EXACT EVASION this
  # block was widened to catch - `json_extract` and the `payload` reference
  # split across TWO SEPARATE `paste0()` string-literal arguments, so
  # neither literal alone contains both. A per-literal-only scan (the
  # pre-fix version of `.hy_scan_sql_json_on_payload()`) finds zero hits
  # here; the concatenation-aware version must find at least one.
  decoy_split_literal <- .hy_source_from_text(paste(
    "f <- function(con) {",
    "  sql <- paste0(\"SELECT json_extract(\", \"payload\", \", '$.tier') FROM review_queue\")",
    "  DBI::dbGetQuery(con, sql)",
    "}", sep = "\n"
  ))
  expect_true(
    length(.hy_scan_sql_json_on_payload(list(decoy_split_literal))) >= 1,
    info = "positive control failed (F4): json_extract and payload split across two paste0() literal fragments was not flagged - the scan is not concatenation-aware"
  )

  # NEGATIVE CONTROL: a paste0() call whose literal fragments, joined, do NOT
  # co-occur with both the keyword and `payload` must not be flagged - the
  # concatenation path still requires the same SQL-keyword gate and
  # keyword+payload co-occurrence as the per-literal path, not a blanket
  # "any paste0() is suspicious" rule.
  decoy_split_literal_unrelated <- .hy_source_from_text(paste(
    "f <- function(con) {",
    "  sql <- paste0(\"SELECT \", \"uuid, kind FROM review_queue\")",
    "  DBI::dbGetQuery(con, sql)",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_sql_json_on_payload(list(decoy_split_literal_unrelated)), 0)

  # NEGATIVE CONTROLS: a comment mentioning the pattern must not trip the
  # scanner, and a plain SELECT of the payload COLUMN (no JSON operator -
  # exactly R/mutate.R's sanctioned review_queue() reader) must not either.
  decoy_comment_only <- .hy_source_from_text(paste(
    "f <- function(con) {",
    "  # do not write json_extract(payload, '$.tier') here",
    "  DBI::dbGetQuery(con, \"SELECT uuid, payload FROM review_queue WHERE status = ?\")",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_sql_json_on_payload(list(decoy_comment_only)), 0)

  # NEGATIVE CONTROL (the defect this block fixes): a HUMAN-READABLE prose
  # string containing an arrow and the word "payload" but no SQL at all must
  # NOT be flagged - this is not SQL, so R-16.6 does not apply to it. The
  # literal below is the real `reason = ...` message the retired legacy
  # migration carried (dev/migrations/006, deleted 2026-07-25 once its rows
  # were resolved), restored to its original "->" wording. It is kept
  # verbatim BECAUSE it is a real-world example of the false-positive class,
  # not because the file still exists.
  decoy_prose_arrow <- .hy_source_from_text(paste(
    "f <- function() {",
    "  reason <- \"PLAN-16 B-16.migration: asset_content_unverified payload -> typed columns\"",
    "  reason",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_sql_json_on_payload(list(decoy_prose_arrow)), 0)

  real_hits <- .hy_scan_sql_json_on_payload(real_sources)
  info <- sprintf(
    "R-16.6 SQL-side JSON-on-payload violations present: %s",
    paste(vapply(real_hits, function(h) h$path, character(1)), collapse = "; ")
  )
  expect_true(length(real_hits) == 0, info = info)
})

# ==== R-16.7: .rc_serialise_payload is gone =================================

test_that("R-16.7: .rc_serialise_payload is absent from the sampleTidy package namespace (deleted, not repaired - B-16.api)", {
  ns <- asNamespace("sampleTidy")
  expect_false(
    exists(".rc_serialise_payload", envir = ns, inherits = FALSE),
    info = ".rc_serialise_payload must not exist in the package namespace"
  )
})

.hy_call_pattern <- function(fn_name) {
  paste0("(?<![[:alnum:]._])", gsub(".", "\\.", fn_name, fixed = TRUE), "\\s*\\(")
}

.hy_scan_call_sites <- function(sources, fn_name) {
  pat <- .hy_call_pattern(fn_name)
  hits <- list()
  for (src in sources) {
    scrubbed <- .hy_scrub_lines(src)
    for (ln in seq_along(scrubbed)) {
      if (grepl(pat, scrubbed[ln], perl = TRUE)) {
        hits[[length(hits) + 1]] <- list(path = src$path, line = ln)
      }
    }
  }
  hits
}

test_that("R-16.7: no call site to .rc_serialise_payload remains anywhere in R/ (comment/string-aware, with decoy; does not flag the function's own `<- function(...)` definition line)", {
  real_sources <- lapply(.hy_r_files(), .hy_source_from_file)

  # POSITIVE CONTROL (decoy).
  decoy_violation <- .hy_source_from_text(paste(
    "f <- function(p) {",
    "  .rc_serialise_payload(p)",
    "}", sep = "\n"
  ))
  expect_true(
    length(.hy_scan_call_sites(list(decoy_violation), ".rc_serialise_payload")) >= 1,
    info = "positive control failed: a synthetic .rc_serialise_payload(p) call site was not flagged"
  )

  # NEGATIVE CONTROLS: a comment/string mention must not trip the scanner,
  # and the function's own DEFINITION (`.rc_serialise_payload <- function(p)
  # {...}`, no immediately-following `(`) must not be mistaken for a call.
  decoy_comment_only <- .hy_source_from_text(paste(
    "f <- function(p) {",
    "  # .rc_serialise_payload(p) used to live here",
    "  msg <- \"a string mentioning .rc_serialise_payload(p) too\"",
    "  p",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_call_sites(list(decoy_comment_only), ".rc_serialise_payload"), 0)

  decoy_definition_only <- .hy_source_from_text(
    ".rc_serialise_payload <- function(p) {\n  p\n}\n"
  )
  expect_length(.hy_scan_call_sites(list(decoy_definition_only), ".rc_serialise_payload"), 0)

  real_hits <- .hy_scan_call_sites(real_sources, ".rc_serialise_payload")
  info <- sprintf(
    "call site(s) to .rc_serialise_payload() remain: %s",
    paste(vapply(real_hits, function(h) sprintf("%s:%d", basename(h$path), h$line), character(1)),
          collapse = "; ")
  )
  expect_true(length(real_hits) == 0, info = info)
})

# ==== R-16.8, part 1: no hand-built (paste0()/sprintf()) payload string ===========

#' Structural (AST) scan: find every place `payload` is the TARGET of an
#' assignment (`payload <- expr` / `payload = expr`) OR a named call
#' argument (`payload = expr` inside e.g. `tibble(...)`), and return the
#' source span of `expr` (the right-hand side / argument value) for each.
#' Comment/string-aware BY CONSTRUCTION: `parse()` never puts a comment or a
#' string literal's contents into the expression tree, so neither can ever
#' be mistaken for a real `payload` symbol or a real `paste0()` call.
.hy_payload_rhs_spans <- function(pd) {
  spans <- list()
  if (is.null(pd) || nrow(pd) == 0) return(spans)

  # Form 1: `payload <- expr` / `payload = expr` (statement-level assign).
  sym <- pd[pd$token == "SYMBOL" & pd$text == "payload", ]
  if (nrow(sym) > 0) {
    for (i in seq_len(nrow(sym))) {
      wrap_row <- pd[pd$id == sym$parent[i], ]
      if (nrow(wrap_row) == 0) next
      assign_parent_id <- wrap_row$parent[1]
      sibs <- pd[pd$parent == assign_parent_id, ]
      assign_op <- sibs[sibs$token %in% c("LEFT_ASSIGN", "EQ_ASSIGN"), ]
      if (nrow(assign_op) == 0) next
      rhs <- sibs[sibs$id != wrap_row$id[1] & !(sibs$token %in% c("LEFT_ASSIGN", "EQ_ASSIGN")), ]
      if (nrow(rhs) == 0) next
      spans[[length(spans) + 1]] <- rhs[1, c("line1", "col1", "line2", "col2")]
    }
  }

  # Form 2: `payload = expr` as a named call argument (e.g. inside a
  # tibble()/list() call) - uses SYMBOL_SUB/EQ_SUB, a DIFFERENT token pair
  # from a real assignment, which is exactly what lets this scan tell
  # `payload = payload` (passing an already-tainted local var through,
  # itself harmless here) apart from `payload = paste0(...)` (a genuine
  # hand-built site).
  ssub <- pd[pd$token == "SYMBOL_SUB" & pd$text == "payload", ]
  if (nrow(ssub) > 0) {
    for (i in seq_len(nrow(ssub))) {
      sibs <- pd[pd$parent == ssub$parent[i], ]
      sibs <- sibs[order(sibs$line1, sibs$col1), ]
      idx <- which(sibs$id == ssub$id[i])
      if (length(idx) == 0 || idx >= nrow(sibs)) next
      rest <- sibs[(idx + 1):nrow(sibs), ]
      rest <- rest[rest$token == "expr", ]
      if (nrow(rest) == 0) next
      spans[[length(spans) + 1]] <- rest[1, c("line1", "col1", "line2", "col2")]
    }
  }

  spans
}

.hy_span_contains_call <- function(pd, span, fn_name) {
  calls <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == fn_name, ]
  if (nrow(calls) == 0) return(FALSE)
  in_span <- (calls$line1 > span$line1 | (calls$line1 == span$line1 & calls$col1 >= span$col1)) &
    (calls$line2 < span$line2 | (calls$line2 == span$line2 & calls$col2 <= span$col2))
  any(in_span)
}

.hy_scan_payload_hand_builders <- function(sources, fn_names = c("paste0", "sprintf")) {
  hits <- list()
  for (src in sources) {
    pd <- src$pd
    if (is.null(pd) || nrow(pd) == 0) next
    for (span in .hy_payload_rhs_spans(pd)) {
      for (fn in fn_names) {
        if (.hy_span_contains_call(pd, span, fn)) {
          hits[[length(hits) + 1]] <- list(path = src$path, line1 = span$line1, line2 = span$line2, fn = fn)
          break
        }
      }
    }
  }
  hits
}

test_that("R-16.8: no hand-built paste0()/sprintf() payload string survives in R/reconcile.R, R/feature-alias.R or R/router.R (AST-based: flags an assignment or a named-argument literally targeting `payload` whose value calls paste0()/sprintf())", {
  paths <- file.path(.hy_pkg_root(), "R", c("reconcile.R", "feature-alias.R", "router.R"))
  real_sources <- lapply(paths, .hy_source_from_file)

  # POSITIVE CONTROLS (decoys): both real write-shapes must be caught.
  decoy_assign <- .hy_source_from_text("f <- function(x) {\n  payload <- paste0('k=', x)\n  payload\n}\n")
  decoy_named_arg <- .hy_source_from_text("f <- function(x) {\n  tibble::tibble(payload = paste0('k=', x))\n}\n")
  decoy_sprintf <- .hy_source_from_text("f <- function(x) {\n  payload <- sprintf('{\"k\":\"%s\"}', x)\n  payload\n}\n")
  expect_true(length(.hy_scan_payload_hand_builders(list(decoy_assign))) >= 1,
              info = "positive control failed: `payload <- paste0(...)` was not flagged")
  expect_true(length(.hy_scan_payload_hand_builders(list(decoy_named_arg))) >= 1,
              info = "positive control failed: `payload = paste0(...)` (named tibble() arg) was not flagged")
  expect_true(length(.hy_scan_payload_hand_builders(list(decoy_sprintf))) >= 1,
              info = "positive control failed: `payload <- sprintf(...)` was not flagged (router.R's real shape)")

  # NEGATIVE CONTROLS: the future structured constructor, a `payload = NA`
  # prototype (a real, permitted §1f site), a comment, and a string literal
  # must all pass clean.
  decoy_future <- .hy_source_from_text("f <- function(x) {\n  .rq_row(kind = 'x', diagnostics = list(v = x))\n}\n")
  decoy_na <- .hy_source_from_text("f <- function() {\n  tibble::tibble(payload = NA_character_)\n}\n")
  decoy_comment <- .hy_source_from_text("f <- function(x) {\n  # payload <- paste0('k=', x) is forbidden now\n  .rq_row(kind = 'x')\n}\n")
  decoy_string <- .hy_source_from_text("f <- function(x) {\n  msg <- \"payload <- paste0('k=', x) mentioned in a string\"\n  .rq_row(kind = 'x')\n}\n")
  expect_length(.hy_scan_payload_hand_builders(list(decoy_future)), 0)
  expect_length(.hy_scan_payload_hand_builders(list(decoy_na)), 0)
  expect_length(.hy_scan_payload_hand_builders(list(decoy_comment)), 0)
  expect_length(.hy_scan_payload_hand_builders(list(decoy_string)), 0)

  real_hits <- .hy_scan_payload_hand_builders(real_sources)
  info <- sprintf(
    "hand-built paste0()/sprintf() payload assembly still present (%d sites): %s",
    length(real_hits),
    paste(vapply(real_hits, function(h) sprintf("%s:%d-%d (%s)", basename(h$path), h$line1, h$line2, h$fn), character(1)),
          collapse = "; ")
  )
  expect_true(length(real_hits) == 0, info = info)
})

# ==== R-16.8, part 2: all 14 content-producing sites route (transitively) ==
# ==== through the structured constructor `.rq_row()` ======================

#' The CLOSED, ENUMERATED set of symbols that count as "routes through the
#' structured constructor" for R-16.8's coverage check. `.rq_row()` is the
#' constructor itself; the other four are its sanctioned thin wrappers - each
#' already adjudicated by the plan, never a loose name pattern (a genuinely
#' new hand-builder, e.g. one calling paste0()/sprintf() directly, has no
#' entry here and must still fail):
#'   - `.rq_row`           - the structured constructor itself.
#'   - `.rc_review_row`    - R/reconcile.R adapter: adds reconcile's own
#'     bookkeeping columns (`source_ref`, `n_rows`) that `.rq_row()` does not
#'     carry, then calls `.rq_row()` (B-16.api).
#'   - `.rc_skip_row`      - R/reconcile.R SKIP-tibble carrier. Per B-16.skips
#'     the skip tibble is a different shape from a review_queue row and
#'     cannot route through `.rq_row()` at all; `.rc_skip_row()` is its
#'     sanctioned typed constructor, calling `.rq_skip()`.
#'   - `.rq_skip`          - the skip tibble's typed constructor proper (see
#'     `.rc_skip_row` above), applying the same entity-ref/JSON tiering rule
#'     as `.rq_row()` (B-16.skips).
#'   - `review_queue_add`  - R/db-schema.R public API, which B-16.api
#'     explicitly describes as routing "through `.rq_row()` rather than
#'     re-implementing it".
.HY_SANCTIONED_ROW_CONSTRUCTORS <- c(
  ".rq_row", ".rc_review_row", ".rc_skip_row", ".rq_skip", "review_queue_add"
)

#' Mapping: p16-payload-prod-inventory.md section 1b's 14 numbered sites,
#' collapsed to their 11 distinct enclosing functions (several sites share
#' one function's branches - e.g. site 1's three shapes are all inside
#' .rc_feature_review()), PLUS `R/commit.R::.ct_commit_review` (2026-07-25,
#' round-3 remediation, Robin's Ruling 1/F6): `.ct_commit_review()` is the
#' write call for EVERY reconcile-sourced review row (95 of 96 real rows,
#' per the round-3 audit) and sat entirely outside this scan's 3-file list -
#' a mutant that deleted its `.rq_row()` call left a fully green suite.
#' Shared by both part 2 (this block) and part 2b (per-site, below) so the
#' two checks cannot silently drift apart on which functions are in scope.
.HY_R168_TARGETS <- list(
  "R/reconcile.R" = c(
    ".rc_feature_review",        # site 1  (3 shapes: ambiguous / structural / bare)
    ".rc_analyte_review",        # sites 2, 3
    ".rc_resolve_units_values",  # site 4
    ".rc_resolve_datetime",      # site 5
    ".rc_method_preference",     # site 6
    ".rc_three_way",             # sites 7, 8
    ".rc_batch_duplicate",       # site 9
    "reconcile_event"            # site 10 (STAGE-0 serialisation call site)
  ),
  "R/feature-alias.R" = c(
    ".fa_merge_samples",         # site 11
    ".am_confirm_one_method"     # sites 12, 13
  ),
  "R/router.R" = c(
    ".st_route_one_file"         # site 14
  ),
  "R/commit.R" = c(
    ".ct_commit_review"          # site 15 (2026-07-25 widening - the 95/96-row writer, F6)
  )
)

test_that("R-16.8: each of the 15 content-producing review-writing sites (12 enclosing functions per dev/tdd-run/p16-payload-prod-inventory.md section 1b, WIDENED 2026-07-25 to include R/commit.R::.ct_commit_review) routes - directly or via a sanctioned wrapper - through the structured constructor .rq_row()", {
  targets <- .HY_R168_TARGETS
  stopifnot(sum(lengths(targets)) == 12L)

  # Build the detector from the closed sanctioned-constructor set above -
  # escaping the literal `.` each name starts with (these names contain only
  # word characters and a leading dot, so a fixed-string dot-escape is
  # sufficient; no other regex metacharacters can occur).
  .esc_name <- function(nm) gsub(".", "\\.", nm, fixed = TRUE)
  rqrow_pat <- paste0(
    "(?<![[:alnum:]._])(",
    paste(vapply(.HY_SANCTIONED_ROW_CONSTRUCTORS, .esc_name, character(1)), collapse = "|"),
    ")\\s*\\("
  )

  # POSITIVE CONTROL (decoy): prove the detector catches a genuine `.rq_row(`
  # call before trusting its silence against the 11 real functions below.
  decoy <- .hy_source_from_text("f <- function() {\n  .rq_row(kind = 'x')\n}\n")
  decoy_span <- .hy_named_top_level_spans(decoy)[["f"]]
  decoy_chunk <- paste(.hy_scrub_lines(decoy)[decoy_span["line1"]:decoy_span["line2"]], collapse = "\n")
  expect_true(grepl(rqrow_pat, decoy_chunk, perl = TRUE),
              info = "positive control failed: a genuine .rq_row(...) call was not detected")

  # NEGATIVE CONTROL: a comment mentioning `.rq_row(` must not count as a
  # real call.
  decoy_comment <- .hy_source_from_text("f <- function() {\n  # should call .rq_row(kind = 'x') here\n  NULL\n}\n")
  decoy_comment_span <- .hy_named_top_level_spans(decoy_comment)[["f"]]
  decoy_comment_chunk <- paste(.hy_scrub_lines(decoy_comment)[decoy_comment_span["line1"]:decoy_comment_span["line2"]], collapse = "\n")
  expect_false(grepl(rqrow_pat, decoy_comment_chunk, perl = TRUE),
               info = "negative control failed: a comment-only mention of .rq_row( was treated as a real call")

  # THIRD CONTROL: a decoy hand-builder that calls NONE of the sanctioned
  # constructors (it hand-assembles its payload with paste0()) must still be
  # treated as NOT routed - guards against a matcher bug that is always true
  # (which would make the whole criterion pass vacuously).
  decoy_unrouted <- .hy_source_from_text("f <- function(x) {\n  payload <- paste0('k=', x)\n  payload\n}\n")
  decoy_unrouted_span <- .hy_named_top_level_spans(decoy_unrouted)[["f"]]
  decoy_unrouted_chunk <- paste(.hy_scrub_lines(decoy_unrouted)[decoy_unrouted_span["line1"]:decoy_unrouted_span["line2"]], collapse = "\n")
  expect_false(grepl(rqrow_pat, decoy_unrouted_chunk, perl = TRUE),
               info = "third control failed: a non-routing decoy (paste0()-only hand-builder, no sanctioned constructor) was incorrectly treated as routed")

  missing <- character(0)
  for (relpath in names(targets)) {
    src <- .hy_source_from_file(file.path(.hy_pkg_root(), relpath))
    scrubbed <- .hy_scrub_lines(src)
    spans <- .hy_named_top_level_spans(src)
    for (fn in targets[[relpath]]) {
      span <- spans[[fn]]
      if (is.null(span)) {
        missing <- c(missing, sprintf("%s::%s (function not found)", relpath, fn))
        next
      }
      l2 <- min(span["line2"], length(scrubbed))
      chunk <- paste(scrubbed[span["line1"]:l2], collapse = "\n")
      if (!grepl(rqrow_pat, chunk, perl = TRUE)) {
        missing <- c(missing, sprintf("%s::%s", relpath, fn))
      }
    }
  }

  info <- sprintf("sites not yet routed through .rq_row(): %s", paste(missing, collapse = "; "))
  expect_true(length(missing) == 0, info = info)
})

# ==== R-16.8, part 2b: PER SITE, not per function (2026-07-25) ============
#
# Gap closed here (Robin's Ruling 1/F5, round-3 slice I): part 2 above checks
# "does this ENTIRE function's body contain a sanctioned-constructor call
# ANYWHERE" - true the moment ANY one branch routes correctly, even if a
# DIFFERENT branch in the SAME function hand-builds its own row instead.
# Slice I's mutant F5 hand-rolled a `sprintf()` payload inside one branch of
# a multi-branch producer while leaving another branch's real
# `.rc_review_row()` call intact; part 2's function-level scan stayed green
# because SOME call was still present in the chunk it inspected.
#
# This block scans at the SITE granularity real producers actually use in
# this codebase, both idioms verified against current source 2026-07-25:
#  - the list-append idiom `IDENT[[length(IDENT) + 1]] <- EXPR` (every
#    reconcile.R producer: `out`/`review_list`/`skipped_list`) - the check
#    target is EXPR's OWN span, reusing `.hy_span_contains_call()` (R-16.8
#    part 1's helper) rather than the whole enclosing function.
#  - `db_append(<con>, "review_queue", <row>, ...)` (feature-alias.R,
#    commit.R - the row is built by a `.rq_row()` call in a PRECEDING
#    statement of the SAME block, not inline) - the check target is that
#    call's nearest enclosing `{ ... }` block, found structurally by walking
#    `pd$parent` until an ancestor's own children include a `'{'` token.
# A site is a VIOLATION only if a hand-builder (`paste0()`/`sprintf()`) is
# present in its span/block AND no sanctioned constructor is - this
# correctly leaves alone the real §1f pure-NA/prototype sites (e.g.
# `R/reconcile.R`'s `.rc_resolve_units_values()` `skip_reason` branch,
# `skipped_list[[...]] <- tibble::tibble(payload = NA_character_, ...)`,
# verified during authoring): nothing is hand-built there, so nothing to
# flag - REQUIRING a sanctioned call unconditionally at every append-idiom
# occurrence would false-positive on that real, legitimate site.
# `R/router.R::.st_route_one_file` contributes zero sites to this scan (its
# one producer calls `review_queue_add()` directly, matching neither idiom
# shape) - already covered adequately by part 2 above, since it has exactly
# one call, so a second, undetectable hand-built branch is not a risk there.

#' Structural (AST) scan: find every `IDENT[[length(IDENT) + 1]] <- EXPR`ish
#' assignment (detected loosely as "an `LBB` (`[[`)-indexed assignment
#' target"; this exact idiom is the only `[[...]] <-` shape used by any
#' target function, verified 2026-07-25) and return EXPR's span.
.hy_double_bracket_assign_rhs_spans <- function(pd) {
  spans <- list()
  if (is.null(pd) || nrow(pd) == 0) return(spans)
  lbb <- pd[pd$token == "LBB", ]
  if (nrow(lbb) == 0) return(spans)
  for (i in seq_len(nrow(lbb))) {
    outer <- pd[pd$id == lbb$parent[i], ]
    if (nrow(outer) == 0) next
    assign_parent_id <- outer$parent[1]
    sibs <- pd[pd$parent == assign_parent_id, ]
    assign_op <- sibs[sibs$token %in% c("LEFT_ASSIGN", "EQ_ASSIGN"), ]
    if (nrow(assign_op) == 0) next
    rhs <- sibs[sibs$id != outer$id[1] & !(sibs$token %in% c("LEFT_ASSIGN", "EQ_ASSIGN")), ]
    if (nrow(rhs) == 0) next
    spans[[length(spans) + 1]] <- rhs[1, c("line1", "col1", "line2", "col2")]
  }
  spans
}

#' Walk `pd$parent` upward from `start_id` to the nearest ancestor `{ ... }`
#' block (the first ancestor whose OWN children include a `'{'` token) and
#' return that block's full span.
.hy_enclosing_block_span <- function(pd, start_id) {
  cur <- start_id
  repeat {
    row <- pd[pd$id == cur, ]
    if (nrow(row) == 0) return(NULL)
    parent_id <- row$parent[1]
    if (is.null(parent_id) || length(parent_id) == 0 || parent_id == 0) return(NULL)
    sibs <- pd[pd$parent == parent_id, ]
    if (any(sibs$token == "'{'")) {
      return(pd[pd$id == parent_id, c("line1", "col1", "line2", "col2")][1, ])
    }
    cur <- parent_id
  }
}

#' Structural (AST) scan: find every `db_append(...)` call carrying a literal
#' `"review_queue"` argument, and return its nearest enclosing block's span
#' (`.hy_enclosing_block_span()`).
.hy_db_append_review_queue_block_spans <- function(pd) {
  spans <- list()
  if (is.null(pd) || nrow(pd) == 0) return(spans)
  calls <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == "db_append", ]
  if (nrow(calls) == 0) return(spans)
  for (i in seq_len(nrow(calls))) {
    wrap <- pd[pd$id == calls$parent[i], ]
    if (nrow(wrap) == 0) next
    call_id <- wrap$parent[1]
    # Each call argument is itself wrapped in an `expr` node (an STR_CONST is
    # never a direct child of the call - it is the sole child of one of the
    # call's `expr` argument wrappers), so the literal must be found one
    # level down from `call_id`, not directly under it.
    arg_exprs <- pd[pd$parent == call_id & pd$token == "expr", ]
    found <- FALSE
    for (a in seq_len(nrow(arg_exprs))) {
      kids <- pd[pd$parent == arg_exprs$id[a], ]
      if (nrow(kids) == 1 && kids$token[1] == "STR_CONST" && kids$text[1] == '"review_queue"') {
        found <- TRUE
        break
      }
    }
    if (!found) next
    blk <- .hy_enclosing_block_span(pd, calls$id[i])
    if (!is.null(blk)) spans[[length(spans) + 1]] <- blk
  }
  spans
}

#' Producing-site spans (append-idiom RHS + db_append("review_queue",...)
#' blocks) that fall within `[l1, l2]` (a target function's own span).
.hy_producing_site_spans_in <- function(pd, l1, l2) {
  all_spans <- c(.hy_double_bracket_assign_rhs_spans(pd), .hy_db_append_review_queue_block_spans(pd))
  Filter(function(sp) sp$line1 >= l1 && sp$line2 <= l2, all_spans)
}

#' A producing site is a VIOLATION iff a hand-builder call is present in its
#' span AND no sanctioned-constructor call is (see block comment above).
#' `fn_filter`, if supplied, is a `relpath -> function names` list (like
#' `.HY_R168_TARGETS`) restricting the scan to those named functions only -
#' when `NULL` (the synthetic-decoy path, where every source is one small
#' snippet keyed `"<synthetic>"` with no known name in advance), every named
#' top-level function in the source is scanned instead.
.hy_scan_unrouted_producing_sites <- function(sources_by_relpath, fn_filter = NULL) {
  hits <- list()
  for (relpath in names(sources_by_relpath)) {
    src <- sources_by_relpath[[relpath]]
    pd <- src$pd
    spans <- .hy_named_top_level_spans(src)
    fn_names <- if (is.null(fn_filter)) names(spans) else intersect(names(spans), fn_filter[[relpath]])
    for (fn in fn_names) {
      span <- spans[[fn]]
      for (site in .hy_producing_site_spans_in(pd, span["line1"], span["line2"])) {
        has_handbuilder <- .hy_span_contains_call(pd, site, "paste0") || .hy_span_contains_call(pd, site, "sprintf")
        if (!has_handbuilder) next
        has_sanctioned <- any(vapply(
          .HY_SANCTIONED_ROW_CONSTRUCTORS, function(nm) .hy_span_contains_call(pd, site, nm), logical(1)
        ))
        if (!has_sanctioned) {
          hits[[length(hits) + 1]] <- list(path = relpath, fn = fn, line1 = site$line1, line2 = site$line2)
        }
      }
    }
  }
  hits
}

test_that("R-16.8 part 2b: no INDIVIDUAL producing site (a list-append RHS or a db_append(\"review_queue\", ...) block) inside a R-16.8 target function hand-builds a paste0()/sprintf() payload while routing is checked only at the WHOLE-FUNCTION level elsewhere - closes the gap where part 2 above would stay green if only ONE of several sites in the same function still called a sanctioned constructor", {
  targets <- .HY_R168_TARGETS
  target_sources <- stats::setNames(
    lapply(names(targets), function(rp) .hy_source_from_file(file.path(.hy_pkg_root(), rp))),
    names(targets)
  )

  # POSITIVE CONTROL (decoy): THE EXACT REGRESSION THIS BLOCK EXISTS TO CATCH
  # (F5's shape) - a function with TWO append-idiom sites, one correctly
  # routed and one hand-built with sprintf(). Part 2's whole-function check
  # (reproduced inline here) would PASS this decoy (`.rc_review_row(` is
  # present somewhere in the body); the per-site scan must FAIL it.
  decoy_f5 <- .hy_source_from_text(paste(
    "f <- function(x) {",
    "  out <- list()",
    "  out[[length(out) + 1]] <- .rc_review_row(kind = 'x')",
    "  if (x) {",
    "    out[[length(out) + 1]] <- tibble::tibble(payload = sprintf('site=%s', x))",
    "  }",
    "  out",
    "}", sep = "\n"
  ))
  decoy_f5_hits <- .hy_scan_unrouted_producing_sites(list("<synthetic>" = decoy_f5))
  expect_true(
    length(decoy_f5_hits) >= 1,
    info = "positive control failed (F5 shape): a hand-built sprintf() append alongside a correctly-routed one in the SAME function was not flagged"
  )
  whole_fn_chunk <- paste(.hy_scrub_lines(decoy_f5), collapse = "\n")
  expect_true(
    grepl("(?<![[:alnum:]._])\\.rc_review_row\\s*\\(", whole_fn_chunk, perl = TRUE),
    info = "sanity check failed: the F5 decoy should still contain a real .rc_review_row( call (proving part 2's whole-function check would have passed it)"
  )

  # POSITIVE CONTROL (decoy): the db_append("review_queue", ...) idiom's own
  # F5-shaped regression - one branch routes through .rq_row(), the sibling
  # branch hand-builds with paste0() and calls db_append() directly.
  decoy_f5_dbappend <- .hy_source_from_text(paste(
    "f <- function(con, x) {",
    "  if (x) {",
    "    review_row <- .rq_row(kind = 'x')$review",
    "    db_append(con, \"review_queue\", review_row)",
    "  } else {",
    "    review_row <- tibble::tibble(payload = paste0('k=', x))",
    "    db_append(con, \"review_queue\", review_row)",
    "  }",
    "}", sep = "\n"
  ))
  expect_true(
    length(.hy_scan_unrouted_producing_sites(list("<synthetic>" = decoy_f5_dbappend))) >= 1,
    info = "positive control failed: a db_append(\"review_queue\", ...) block hand-building via paste0() (sibling to a correctly-routed branch) was not flagged"
  )

  # NEGATIVE CONTROL: the real §1f pure-NA/prototype shape (no hand-builder
  # present at all) must not be flagged - only a HAND-BUILT site is a
  # violation, not merely an unrouted one (the criterion targets bypasses of
  # the structured route, not "no content at all").
  decoy_na_prototype <- .hy_source_from_text(paste(
    "f <- function(x) {",
    "  skipped_list <- list()",
    "  skipped_list[[length(skipped_list) + 1]] <- tibble::tibble(payload = NA_character_)",
    "  skipped_list",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_unrouted_producing_sites(list("<synthetic>" = decoy_na_prototype)), 0)

  # NEGATIVE CONTROL: a fully-routed function (both sites call sanctioned
  # constructors, no hand-builder anywhere) must not be flagged.
  decoy_clean <- .hy_source_from_text(paste(
    "f <- function(x) {",
    "  out <- list()",
    "  out[[length(out) + 1]] <- .rc_review_row(kind = 'x')",
    "  out[[length(out) + 1]] <- .rc_skip_row(kind = 'y')",
    "  out",
    "}", sep = "\n"
  ))
  expect_length(.hy_scan_unrouted_producing_sites(list("<synthetic>" = decoy_clean)), 0)

  # THE REAL SCAN, over the widened target function set (part 2's list,
  # including R/commit.R::.ct_commit_review) - fn_filter restricts each file
  # to exactly its listed target function(s), never the whole file.
  real_hits <- .hy_scan_unrouted_producing_sites(target_sources, fn_filter = targets)
  info <- sprintf(
    "producing site(s) hand-build a paste0()/sprintf() payload without routing through a sanctioned constructor: %s",
    paste(vapply(real_hits, function(h) sprintf("%s:%d-%d (%s)", h$path, h$line1, h$line2, h$fn), character(1)),
          collapse = "; ")
  )
  expect_true(length(real_hits) == 0, info = info)
})

# ==== R-16.8, part 3: the sanctioned WRAPPERS THEMSELVES must still reach ==
# ==== .rq_row() (or, for the skip-tibble carrier, .rq_skip()) =============
#
# Gap closed here: part 2 above only checks that the 11 content-producing
# FUNCTIONS call a member of the sanctioned set - it never checks that the
# sanctioned wrappers' OWN bodies still route onward. If `.rc_review_row()`
# were later edited to hand-build a payload string instead of calling
# `.rq_row()`, all 9 wrapper-routed sites would still pass part 2 above
# (they call `.rc_review_row()`, which is still in the sanctioned set) while
# the actual payload assembly silently regressed. This block walks one hop
# further: does each sanctioned wrapper (other than the two TERMINALS,
# below) itself call `.rq_row()` directly, or another sanctioned wrapper
# that transitively does?

#' TERMINAL sanctioned constructors for this transitivity check: `.rq_row()`
#' (review_queue carrier) and, by the EXPLICIT B-16.skips exception, also
#' `.rq_skip()` (skip-tibble carrier). `.rq_skip()` is not a violation for
#' failing to reach `.rq_row()` - the skip tibble never becomes a
#' `review_queue` row (it stays in-memory, feeding `commit_event()`
#' directly) and per the sanctioned-set comment above (`.rc_skip_row`'s
#' entry) is structurally incapable of routing through `.rq_row()` at all.
#' `.rc_skip_row()` in turn calls `.rq_skip()`, not `.rq_row()` - the same
#' carrier, the same exception - so this check treats "reaches `.rq_skip()`"
#' as an equally valid destination, not a silent special case: it is a
#' second, explicitly named TERMINAL, exactly like `.rq_row()`.
#' Verified against current source (2026-07-25), not assumed: `.rq_skip()`
#' (R/reconcile.R) calls `.rq_serialise_diagnostics()` directly - the SAME
#' shared serialisation helper `.rq_row()` (R/db-schema.R) uses - but does
#' NOT call `.rq_row()` itself. The sanity check inside the test below
#' re-verifies this fact every run so the exception cannot go stale if a
#' future refactor changes it.
.HY_ROUTING_TERMINALS <- c(".rq_row", ".rq_skip")

#' `name -> character vector of sanctioned names it calls`, built by
#' scanning each sanctioned constructor's own named top-level span (as
#' found in `sources`) for a call to any OTHER member of
#' `.HY_SANCTIONED_ROW_CONSTRUCTORS`, using the same comment/string-scrubbed
#' per-name detector (`.hy_call_pattern()`, R-16.7's helper) already used
#' elsewhere in this file - never a loose name pattern.
.hy_sanctioned_call_graph <- function(sources) {
  edges <- stats::setNames(vector("list", length(.HY_SANCTIONED_ROW_CONSTRUCTORS)),
                            .HY_SANCTIONED_ROW_CONSTRUCTORS)
  for (nm in names(edges)) edges[[nm]] <- character(0)
  for (src in sources) {
    scrubbed <- .hy_scrub_lines(src)
    spans <- .hy_named_top_level_spans(src)
    for (nm in .HY_SANCTIONED_ROW_CONSTRUCTORS) {
      span <- spans[[nm]]
      if (is.null(span)) next
      l2 <- min(span["line2"], length(scrubbed))
      chunk <- paste(scrubbed[span["line1"]:l2], collapse = "\n")
      called <- Filter(
        function(other) other != nm && grepl(.hy_call_pattern(other), chunk, perl = TRUE),
        .HY_SANCTIONED_ROW_CONSTRUCTORS
      )
      edges[[nm]] <- unique(c(edges[[nm]], called))
    }
  }
  edges
}

#' TRUE if `start` reaches any name in `terminals` by following `edges`
#' (breadth-first, cycle-safe via `visited`) - `start` itself counts if it
#' IS a terminal.
.hy_reaches <- function(start, edges, terminals) {
  if (start %in% terminals) return(TRUE)
  visited <- character(0)
  queue <- edges[[start]]
  while (length(queue) > 0) {
    nm <- queue[1]
    queue <- queue[-1]
    if (nm %in% terminals) return(TRUE)
    if (nm %in% visited) next
    visited <- c(visited, nm)
    queue <- c(queue, edges[[nm]])
  }
  FALSE
}

test_that("R-16.8: each sanctioned wrapper other than .rq_row() (and .rq_skip(), its B-16.skips-exempt skip-tibble counterpart) transitively reaches .rq_row() or .rq_skip() by calling another sanctioned constructor - closes the gap where part 2 above checks only the 11 content-producing FUNCTIONS, never the wrappers' own bodies", {
  real_sources <- lapply(.hy_r_files(), .hy_source_from_file)
  real_edges <- .hy_sanctioned_call_graph(real_sources)

  # Sanity check on the exception itself (comment on .HY_ROUTING_TERMINALS):
  # re-verify, every run, that .rq_skip() still does NOT call .rq_row() -
  # if a future refactor makes it do so, the exception becomes unnecessary
  # (though harmless) and this would be the signal to notice that drift.
  expect_false(
    ".rq_row" %in% real_edges[[".rq_skip"]],
    info = paste(
      ".rq_skip() now calls .rq_row() directly - the B-16.skips terminal",
      "exception recorded on .HY_ROUTING_TERMINALS is stale; update the",
      "comment (the exception may no longer be needed) rather than leaving",
      "it as unexplained dead documentation"
    )
  )

  # POSITIVE CONTROL (decoy): a synthetic 2-hop chain through ANOTHER
  # sanctioned wrapper (.rc_review_row -> review_queue_add -> .rq_row) proves
  # the walker follows routing more than one level deep, not merely a direct
  # call - guards against a check that only re-derives part 2 above.
  decoy_transitive <- .hy_source_from_text(paste(
    ".rc_review_row <- function() { review_queue_add() }",
    "review_queue_add <- function() { .rq_row() }",
    ".rq_row <- function() { NULL }",
    sep = "\n"
  ))
  edges_t <- .hy_sanctioned_call_graph(list(decoy_transitive))
  expect_true(
    .hy_reaches(".rc_review_row", edges_t, .HY_ROUTING_TERMINALS),
    info = "positive control failed: a 2-hop chain through another sanctioned wrapper was not detected as routed"
  )

  # POSITIVE CONTROL (decoy): THE EXACT REGRESSION THIS BLOCK EXISTS TO
  # CATCH - a wrapper edited to hand-build its payload, calling NO sanctioned
  # constructor at all - must be flagged as NOT reaching a terminal.
  decoy_regressed <- .hy_source_from_text(
    ".rc_review_row <- function(x) {\n  payload <- paste0('k=', x)\n  payload\n}\n"
  )
  edges_r <- .hy_sanctioned_call_graph(list(decoy_regressed))
  expect_false(
    .hy_reaches(".rc_review_row", edges_r, .HY_ROUTING_TERMINALS),
    info = "positive control failed: a hand-building regression of .rc_review_row() (no sanctioned call at all) was not flagged as unrouted"
  )

  # NEGATIVE CONTROL (exception encoding): a wrapper that reaches ONLY
  # .rq_skip() (never .rq_row()) - .rc_skip_row()'s real shape - must still
  # count as routed, because .rq_skip() is the sanctioned SKIP-tibble
  # terminal (B-16.skips), not a violation.
  decoy_via_skip <- .hy_source_from_text(
    ".rc_skip_row <- function() { .rq_skip() }\n"
  )
  edges_s <- .hy_sanctioned_call_graph(list(decoy_via_skip))
  expect_true(
    .hy_reaches(".rc_skip_row", edges_s, .HY_ROUTING_TERMINALS),
    info = "negative control failed: a wrapper reaching only .rq_skip() (the sanctioned skip-tibble terminal) was incorrectly treated as unrouted"
  )

  # THE REAL CHECK: every sanctioned wrapper except the two TERMINALS
  # themselves must transitively reach a terminal in the real source tree.
  to_check <- setdiff(.HY_SANCTIONED_ROW_CONSTRUCTORS, .HY_ROUTING_TERMINALS)
  unrouted <- Filter(function(nm) !.hy_reaches(nm, real_edges, .HY_ROUTING_TERMINALS), to_check)
  info <- sprintf(
    "sanctioned wrapper(s) no longer transitively reach .rq_row()/.rq_skip(): %s",
    paste(unrouted, collapse = "; ")
  )
  expect_true(length(unrouted) == 0, info = info)
})

# ==== R-16.18: no PRODUCTION call site supplies a free-text `payload=` ======
#
# Q1 (Robin, 2026-07-25). R-16.18's clause is "no production path allows a
# free-text payload to be supplied". The ruling was to KEEP
# `review_queue_add()`'s `payload=` argument - tests legitimately drive it, to
# prove the constructor's output is what a caller would otherwise hand-build -
# and to ENFORCE the clause by scanning instead. Keeping the argument and
# asserting nothing production-side uses it is strictly stronger than deleting
# it: deletion moves the hazard (a caller reintroduces a local `paste0()` and
# writes it via db_append()), whereas the scan fails on the reintroduction.
#
# This is the ONE part of R-16.18 that lives in this file rather than in
# test-review-queue-payload.R (see the header note): it is a call-site scan of
# `R/`, structurally identical to R-16.7's and R-16.8's, not an assertion about
# a payload's CONTENT or SHAPE. The content/shape half stays where it was.

#' AST scan: does any call to `fn_name` pass a named argument `arg_name`?
#'
#' Parent-scoped by construction, which is the whole point: the `SYMBOL_SUB`
#' must be a DIRECT child of the call expression, so a nested
#' `review_queue_add(diagnostics = list(payload = x))` - where the
#' `payload =` belongs to `list()` - is correctly not a hit. Handles
#' `fn(...)` and `pkg::fn(...)` identically, because in both the
#' `SYMBOL_FUNCTION_CALL`'s parent is the callee-position expr whose own
#' parent is the call expr.
.hy_scan_named_arg_at_call <- function(sources, fn_name, arg_name) {
  hits <- list()
  for (src in sources) {
    pd <- src$pd
    if (is.null(pd) || nrow(pd) == 0) next
    fcall <- pd[pd$token == "SYMBOL_FUNCTION_CALL" & pd$text == fn_name, ]
    for (i in seq_len(nrow(fcall))) {
      wrap <- pd[pd$id == fcall$parent[i], ]
      if (nrow(wrap) == 0) next
      args <- pd[pd$parent == wrap$parent[1] & pd$token == "SYMBOL_SUB" & pd$text == arg_name, ]
      if (nrow(args) == 0) next
      hits[[length(hits) + 1]] <- list(path = src$path, line1 = args$line1[1])
    }
  }
  hits
}

#' The indirect-call escape hatch. An AST scan keyed on
#' `SYMBOL_FUNCTION_CALL` cannot see `do.call("review_queue_add", ...)` or
#' `get("review_queue_add")(...)`, so the function's own name appearing as a
#' STRING LITERAL in `R/` is treated as a finding in its own right: today
#' there are none, and if one is ever added it must be a conscious decision
#' rather than a silent bypass of the scan above.
.hy_scan_name_as_string <- function(sources, fn_name) {
  hits <- list()
  quoted <- c(paste0("\"", fn_name, "\""), paste0("'", fn_name, "'"))
  for (src in sources) {
    pd <- src$pd
    if (is.null(pd) || nrow(pd) == 0) next
    lits <- pd[pd$token == "STR_CONST" & pd$text %in% quoted, ]
    for (i in seq_len(nrow(lits))) {
      hits[[length(hits) + 1]] <- list(path = src$path, line1 = lits$line1[i])
    }
  }
  hits
}

test_that("R-16.18: no file under R/ passes a free-text `payload=` to review_queue_add() - the argument is retained for tests but no production path supplies one (AST, parent-scoped, plus an indirect-call check)", {
  real_sources <- lapply(.hy_r_files(), .hy_source_from_file)

  # POSITIVE CONTROLS: both call spellings of the real violation.
  decoy_plain <- .hy_source_from_text(
    "f <- function(con, x) {\n  review_queue_add(con, kind = 'unknown_feature', payload = paste0('k=', x))\n}\n"
  )
  decoy_ns <- .hy_source_from_text(
    "f <- function(con, x) {\n  sampleTidy::review_queue_add(con, payload = x)\n}\n"
  )
  expect_true(
    length(.hy_scan_named_arg_at_call(list(decoy_plain), "review_queue_add", "payload")) >= 1,
    info = "positive control failed: `review_queue_add(..., payload = paste0(...))` was not flagged - the scan matches nothing"
  )
  expect_true(
    length(.hy_scan_named_arg_at_call(list(decoy_ns), "review_queue_add", "payload")) >= 1,
    info = "positive control failed: the `pkg::review_queue_add(payload = )` spelling was not flagged"
  )

  # NEGATIVE CONTROLS. The nested one is the load-bearing case: `payload` as a
  # key INSIDE a diagnostics list is the sanctioned structured route, and a
  # scan that flagged it would be unusable.
  decoy_nested <- .hy_source_from_text(
    "f <- function(con, x) {\n  review_queue_add(con, kind = 'k', diagnostics = list(payload = x))\n}\n"
  )
  decoy_other_fn <- .hy_source_from_text(
    "f <- function(x) {\n  some_other_writer(payload = x)\n}\n"
  )
  decoy_clean <- .hy_source_from_text(
    "f <- function(con, x) {\n  review_queue_add(con, kind = 'k', diagnostics = list(v = x))\n}\n"
  )
  decoy_text <- .hy_source_from_text(
    "f <- function(con) {\n  # review_queue_add(con, payload = 'k=v') is forbidden\n  msg <- \"review_queue_add(payload = 'k=v')\"\n  review_queue_add(con, kind = 'k')\n}\n"
  )
  expect_length(.hy_scan_named_arg_at_call(list(decoy_nested), "review_queue_add", "payload"), 0)
  expect_length(.hy_scan_named_arg_at_call(list(decoy_other_fn), "review_queue_add", "payload"), 0)
  expect_length(.hy_scan_named_arg_at_call(list(decoy_clean), "review_queue_add", "payload"), 0)
  expect_length(.hy_scan_named_arg_at_call(list(decoy_text), "review_queue_add", "payload"), 0)

  # THE REAL CHECK.
  real_hits <- .hy_scan_named_arg_at_call(real_sources, "review_queue_add", "payload")
  expect_true(
    length(real_hits) == 0,
    info = sprintf(
      "production code supplies a free-text payload= to review_queue_add() (%d site(s)): %s",
      length(real_hits),
      paste(vapply(real_hits, function(h) sprintf("%s:%d", basename(h$path), h$line1), character(1)),
            collapse = "; ")
    )
  )

  # And the indirect route stays closed.
  string_ctl <- .hy_source_from_text("f <- function(con, x) {\n  do.call(\"review_queue_add\", list(con, payload = x))\n}\n")
  expect_true(
    length(.hy_scan_name_as_string(list(string_ctl), "review_queue_add")) >= 1,
    info = "positive control failed: `do.call(\"review_queue_add\", ...)` was not flagged by the indirect-call check"
  )
  indirect <- .hy_scan_name_as_string(real_sources, "review_queue_add")
  expect_true(
    length(indirect) == 0,
    info = sprintf(
      "\"review_queue_add\" appears as a string literal in R/ (%s) - an indirect call would bypass the AST scan above; justify it or remove it",
      paste(vapply(indirect, function(h) sprintf("%s:%d", basename(h$path), h$line1), character(1)),
            collapse = "; ")
    )
  )
})
