# Ruling 2026-10-19 R8 (PLAN-18 sections 2a and 4.5): both notes start with
# their own YAML frontmatter holding a one-sentence plain-facts `summary:` list,
# the vault's convention. sampleTidy rewrites the whole note, so a summary
# someone else added is replaced, never kept stale or duplicated.
#
# Seam: the internal `.inbox_frontmatter(summary)` returns the frontmatter
# lines: "---", "summary:", "  - '<summary with ' doubled>'", "---".

fm_parse <- function(lines) {
  fm <- note_frontmatter(lines)
  expect_false(is.null(fm), label = "note has a leading --- frontmatter block")
  if (requireNamespace("yaml", quietly = TRUE)) {
    y <- yaml::yaml.load(paste(fm, collapse = "\n"))
    expect_identical(names(y), "summary")
    expect_type(y$summary, "character")
    expect_length(y$summary, 1)
    y$summary
  } else {
    expect_identical(fm[[1]], "summary:")
    expect_length(fm, 2)
    expect_match(fm[[2]], "^  - '.*'$")
    gsub("''", "'", sub("^  - '(.*)'$", "\\1", fm[[2]]))
  }
}

raw_note <- function(path) readLines(path, warn = FALSE, encoding = "UTF-8")

test_that(".inbox_frontmatter(): single-quoted YAML list item, inner quotes doubled, round-trips", {
  fm <- sampleTidy:::.inbox_frontmatter("Robin's note: 'quoted' # not a comment")
  expect_identical(fm, c("---", "summary:",
                         "  - 'Robin''s note: ''quoted'' # not a comment'", "---"))
  expect_identical(fm_parse(c(fm, "body")), "Robin's note: 'quoted' # not a comment")
})

test_that("import_status(): frontmatter first, then the unchanged header; summary states time, review items, flags, waiting", {
  s <- fl_status_setup()
  now <- fl_now()
  insert_review_items(s$db, data.frame(
    uuid = c("rq-1", "rq-2", "rq-3"), created_at = rep(now - 3600, 3),
    kind = "unknown_feature", subkind = NA_character_, work_order = "ES2222222",
    status = "open", stringsAsFactors = FALSE))
  make_inbox_folder(s$input_dir, "input2026-10-19 1255 arriving", inbox_proj_a_files(),
                    age_min = 1, now = now)
  fl_status(s, checks = fl_checks(schedule = fl_schedule(list(site = "K", months = "7;8"))),
            now = now)
  raw <- raw_note(status_note_path(s$report_dir))
  expect_identical(raw[[1]], "---")
  sm <- fm_parse(raw)
  expect_match(sm, "2026-10-19 13:00", fixed = TRUE)
  expect_match(sm, "\\b3 review item")
  expect_match(sm, "\\b2 flag")
  expect_match(sm, "overdue", fixed = TRUE)
  expect_match(sm, "\\b1 folder")
  body <- strip_frontmatter(raw)
  body <- body[nzchar(trimws(body))]
  expect_match(body[[1]], "^\\*Import status · updated 2026-10-19 13:00 · 3 review item\\(s\\) open, 1 folder\\(s\\) waiting\\*$")
})

test_that("import_status(): a frontmatter someone else added is replaced, not kept or duplicated", {
  s <- fl_status_setup()
  p <- status_note_path(s$report_dir)
  writeLines(c("---", "summary:", "  - 'stale summary written by the vault'", "---",
               "*Import status · old*"), p)
  fl_status(s, checks = NULL)
  fl_status(s, checks = NULL)
  raw <- raw_note(p)
  expect_identical(raw[[1]], "---")
  expect_equal(sum(raw == "---"), 2)
  expect_equal(sum(grepl("^summary:", raw)), 1)
  expect_false(any(grepl("stale summary", raw, fixed = TRUE)))
  expect_false(any(grepl("Import status · old", raw, fixed = TRUE)))
  sm <- fm_parse(raw)
  expect_match(sm, "\\b0 review item")
})

test_that("import_report(): the dated note carries frontmatter whose summary names what was imported today", {
  s <- inbox_setup()
  now <- Sys.time()
  make_inbox_folder(s$input_dir, "input2026-10-18 0900 PROJ_A", inbox_proj_a_files(), now = now)
  run_inbox(s, now = now)
  raw <- raw_note(inbox_report_path(s$report_dir, now))
  expect_identical(raw[[1]], "---")
  sm <- fm_parse(raw)
  expect_match(sm, "XX1234567", fixed = TRUE)
  expect_match(sm, "review item")
  body <- strip_frontmatter(raw)
  body <- body[nzchar(trimws(body))]
  expect_match(body[[1]], "^\\*Imports · ")
  # rewriting replaces the frontmatter rather than stacking another
  quiet_run(import_report(db = s$db, report_dir = s$report_dir, now = now))
  raw2 <- raw_note(inbox_report_path(s$report_dir, now))
  expect_equal(sum(raw2 == "---"), 2)
  expect_identical(raw2, raw)
})
