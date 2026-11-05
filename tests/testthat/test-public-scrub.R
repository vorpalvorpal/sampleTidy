# Stage 3 of the layer move: this package is public, so its shipped text (R/,
# the generated man/ pages, the README and the design note) names no deployment
# site, organisation, person or path, no real feature or QC code, and no
# development-tree path that has moved out of the repository. The fixtures and
# the tests are out of scope (see dev/DESIGN.md, "deployment knowledge").
#
# Skipped when the sources are absent (an installed package, R CMD check).

ps_root <- function() normalizePath(testthat::test_path("..", ".."), mustWork = FALSE)

ps_files <- function(...) {
  root <- ps_root()
  unlist(lapply(c(...), function(g) {
    if (grepl("[*]", g)) {
      d <- dirname(g)
      list.files(file.path(root, d), pattern = glob2rx(basename(g)), full.names = TRUE)
    } else if (file.exists(file.path(root, g))) file.path(root, g) else character(0)
  }), use.names = FALSE)
}

ps_skip <- function() {
  root <- ps_root()
  skip_if_not(dir.exists(file.path(root, "R")) && file.exists(file.path(root, "README.md")),
              "package sources not present")
}

#' Fail once per file:line that matches `pattern` (PCRE, optionally case-insensitive).
ps_scan <- function(files, pattern, ignore_case = FALSE, what = pattern) {
  hits <- character(0)
  for (f in files) {
    txt <- readLines(f, warn = FALSE, encoding = "UTF-8")
    i <- grep(pattern, txt, perl = TRUE, ignore.case = ignore_case, useBytes = TRUE)
    if (length(i)) hits <- c(hits, sprintf("%s:%d", basename(f), i))
  }
  if (length(hits)) {
    fail(sprintf("%d line(s) match %s, e.g. %s", length(hits), what,
                 paste(utils::head(hits, 8), collapse = ", ")))
  } else {
    succeed()
  }
  invisible(hits)
}

test_that("the shipped text names no deployment: sites, organisation, people, vault or cloud paths", {
  ps_skip()
  files <- ps_files("R/*.R", "man/*.Rd", "README.md", "dev/DESIGN.md")
  expect_gt(length(files), 50)
  # Place names are written with one bracketed character so this file does
  # not itself spell them out.
  deny <- paste0("bla[x]land|kat[o]omba|\\bbw[m]f\\b|\\bkw[m]f\\b|\\bbm[c]c\\b|blue mo[u]ntains|\\bcouncil\\b|",
                 "\\bla[w]son\\b|\\bwmf\\b|\\bblx\\b|\\brobin\\b|australia/sydney|cloudstorage|",
                 "\\bpkm\\b|import triage|obsidian|lith[g]ow|lith[o]gw")
  ps_scan(files, deny, ignore_case = TRUE, what = "the deployment deny-list")
})

test_that("R/ holds no real feature code or QC code", {
  ps_skip()
  files <- ps_files("R/*.R")
  expect_gt(length(files), 30)
  ps_scan(files, "\\b[BK]\\.J[A-Z0-9]", what = "a QC-code shape")
  ps_scan(files, "\\b(B|K|L|BH)\\.(MW|S|L|E|G|TS|D)[0-9]", what = "a real feature-code shape")
})

test_that("R/ and man/ point at no development-tree path that has left the repository", {
  ps_skip()
  files <- ps_files("R/*.R", "man/*.Rd")
  ps_scan(files, "dev/(plans|migrations|MIGRATIONS|HANDOVER|tdd-run)|scratchpad/",
          what = "a moved dev/ path")
})
