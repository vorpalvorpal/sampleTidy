# Plan 02 - R-2.1 normalise_lab_text(): port of
# WEM.data/R/new/data/normalise_lab_text.R with its `.lab_text_mojibake_fixes`
# table verbatim, plus entries for the MacRoman degree byte and the classic
# cp1252 pairs from old unify_value(). See dev/plans/PLAN-02-primitives.md.

# Unicode literals below are the real UTF-8 glyphs (package Encoding: UTF-8),
# named so intent is unambiguous at each call site.
deg        <- "°" # degree sign            °
pm         <- "±" # plus-minus             ±
sup2       <- "²" # superscript two        ²
micro      <- "µ" # micro sign             µ
emdash     <- "—" # em dash                —
supminus   <- "⁻" # superscript minus      ⁻
invexcl    <- "¡" # inverted exclamation    ¡ (MacRoman ° via latin-1)
fffd       <- "�" # replacement character   U+FFFD

# The `.lab_text_mojibake_fixes` table, ported verbatim (CONTRACT: "with its
# `.lab_text_mojibake_fixes` table verbatim").
verbatim_cases <- tibble::tribble(
  ~input,          ~expected,
  "<c2><b0>",      deg,
  "<c2><b1>",      pm,
  "<c2><b2>",      sup2,
  "<c2><b5>",      micro,
  "<c2><a1>",      deg,
  "<e2><80><94>",  emdash,
  "<e2><81><bb>",  supminus
)

# New entries pinned by PLAN-02: the MacRoman degree byte (`\xA1` read as
# latin-1 -> `¡`; `25¡C` -> `25°C`) and the classic cp1252 pairs from the old
# `unify_value()`.
new_entry_cases <- tibble::tribble(
  ~input,                     ~expected,
  paste0("25", invexcl, "C"), paste0("25", deg, "C"),
  paste0(fffd, "S/cm"),       paste0(micro, "S/cm"),
  paste0(fffd, "g/L"),        paste0(micro, "g/L"),
  paste0(fffd, "C"),          paste0(deg, "C")
)

all_cases <- rbind(verbatim_cases, new_entry_cases)

for (i in seq_len(nrow(all_cases))) {
  input <- all_cases$input[i]
  expected <- all_cases$expected[i]
  test_that(sprintf("R-2.1: mojibake table entry round-trips: %s", encodeString(input)), {
    expect_no_warning(result <- normalise_lab_text(input))
    expect_identical(result, expected)
  })
}

test_that("R-2.1: text containing an unmatched U+FFFD warns (class sampletidy_warning) and is returned unchanged", {
  x <- paste0("foo", fffd, "bar") # not one of the known "<U+FFFD>{S/cm,g/L,C}" patterns
  result <- NULL
  expect_warning(result <- normalise_lab_text(x), class = "sampletidy_warning")
  expect_identical(result, x)
})

test_that("R-2.1: NULL input is returned as-is", {
  expect_null(normalise_lab_text(NULL))
})

test_that("R-2.1: empty character input is returned as-is", {
  expect_identical(normalise_lab_text(character(0)), character(0))
})

test_that("R-2.1: NA elements stay NA, no warning, alongside real substitutions", {
  x <- c("abc", NA, "<c2><b0>")
  result <- NULL
  expect_no_warning(result <- normalise_lab_text(x))
  expect_identical(result, c("abc", NA, deg))
})
