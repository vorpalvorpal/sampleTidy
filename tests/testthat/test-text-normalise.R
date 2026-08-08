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
acirc      <- "Â" # A with circumflex      Â (U+00C2 - the leading byte C2 of
                   #                        a UTF-8 degree/micro sign, decoded
                   #                        on its own as latin-1)

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

# Entries added 2026-08-08 on Robin's ruling: the "UTF-8 read as latin-1" pair.
# A degree sign that was encoded CORRECTLY as UTF-8 occupies two bytes, C2 B0.
# Decode those two bytes as latin-1 and you get two characters - U+00C2
# (A-circumflex) followed by U+00B0 (degree) - the familiar "A-hat degree".
# The micro sign behaves identically: its UTF-8 bytes are C2 B5, which mangle
# to U+00C2 U+00B5.
#
# These are distinct from the `<c2><b0>` key in `verbatim_cases` above. That
# one is a seven-ASCII-character *escape spelling* printed by a tool that
# declined to decode the bytes at all; this one is a genuine two-character
# string that has already been decoded, wrongly. Both must be in the table.
new_utf8_as_latin1_cases <- tibble::tribble(
  ~input,                      ~expected,
  paste0(acirc, deg),          deg,
  paste0(acirc, micro),        micro
)

all_cases <- rbind(verbatim_cases, new_entry_cases, new_utf8_as_latin1_cases)

for (i in seq_len(nrow(all_cases))) {
  input <- all_cases$input[i]
  expected <- all_cases$expected[i]
  test_that(sprintf("R-2.1: mojibake table entry round-trips: %s", encodeString(input)), {
    expect_no_warning(result <- normalise_lab_text(input))
    expect_identical(result, expected)
  })
}

# --- The real ACIRL corpus string, and why it has to normalise -------------
#
# Measured 2026-08-08 against scratchpad/m6a_corpus_candidates.rds (the
# extracted ACIRL candidate rows): 150 rows across 10 distinct 2400-* workbooks
# carry the analyte label below - 97 of them in the `unprocessed` subdir, 53 in
# `processed`. It is the ONLY string in the whole corpus containing U+00C2:
# a sweep of feature_raw / analyte_raw / units_raw / value_raw over all 38,450
# candidate rows found U+00C2 in analyte_raw and nowhere else, always as this
# one label. The live registry is clean of it (a lab_method that had been
# minted under the corrupt name was deleted by hand - see the change_log row
# for uuid 9f59b10a), which is exactly why the repair belongs here in text
# normalisation and not in the registry.
#
# These strings are written as the real glyphs to match the file's convention,
# but the test below ALSO pins their codepoints, because for a mojibake test
# "which characters are actually in this string" is the whole claim.
acirl_corrupt_label <- "Electrical Conductivity @ 25Â°C"
acirl_clean_label   <- "Electrical Conductivity @ 25°C"

test_that("R-2.1: the real ACIRL label `Electrical Conductivity @ 25<C2><B0>C` (150 corpus rows) normalises to the clean label already in the registry", {
  # Guard the fixture itself first. If an editor or a git filter ever silently
  # re-encodes this file, the string under test could quietly become the clean
  # one and the test would pass while proving nothing. Pin the exact codepoints.
  expect_identical(
    utf8ToInt(substr(acirl_corrupt_label, nchar(acirl_corrupt_label) - 2, nchar(acirl_corrupt_label) - 2)),
    0x00C2L
  )
  expect_identical(nchar(acirl_corrupt_label), nchar(acirl_clean_label) + 1L)

  expect_no_warning(result <- normalise_lab_text(acirl_corrupt_label))
  expect_identical(result, acirl_clean_label)
})

test_that("R-2.1: the clean ACIRL label is untouched, so corrupt and clean rows collapse to ONE key", {
  # The point of the fix is not "the corrupt string changes" but "the corrupt
  # string becomes byte-identical to the clean one". 12 corpus rows already
  # carry the clean spelling (same units, uS/cm), and the registry's
  # lab_method `Electrical Conductivity @ 25<B0>C` (uuid 86e523f7, analyte EC)
  # is named with it. A repair that produced any third spelling would still
  # split the label into two registry entries - the exact defect being fixed.
  expect_no_warning(clean_out <- normalise_lab_text(acirl_clean_label))
  expect_identical(clean_out, acirl_clean_label)
  expect_identical(normalise_lab_text(acirl_corrupt_label), clean_out)

  # Idempotent: normalising the repaired output again is a no-op, so a row that
  # has been through the pipeline twice cannot drift.
  expect_identical(normalise_lab_text(normalise_lab_text(acirl_corrupt_label)), acirl_clean_label)
})

test_that("R-2.1: the micro-sign form `<C2><B5>S/cm` normalises, in units position", {
  # ZERO corpus rows carry this today - every `units_raw` in all 38,450
  # candidate rows already holds a clean U+00B5 (10,085 cells). It is in the
  # table because it is the identical corruption (UTF-8 bytes decoded one at a
  # time) of the identical two-byte pattern from the identical producer, and
  # units is where a micro sign lives. Tested through a realistic units string
  # rather than the bare character so the entry is pinned in the shape it would
  # actually arrive in: the corpus units value is `uS/cm`.
  expect_no_warning(result <- normalise_lab_text(paste0(acirc, micro, "S/cm")))
  expect_identical(result, paste0(micro, "S/cm"))
  # And the clean units string is left alone.
  expect_identical(normalise_lab_text(paste0(micro, "S/cm")), paste0(micro, "S/cm"))
})

test_that("R-2.1: a bare A-circumflex with no degree/micro after it is NOT touched", {
  # The repair keys are two-character sequences, deliberately. U+00C2 is a
  # legitimate letter (Welsh, French, Portuguese) and stripping or rewriting it
  # on its own would corrupt real text. Only the pairs are mojibake.
  expect_no_warning(result <- normalise_lab_text(paste0(acirc, "ngstrom")))
  expect_identical(result, paste0(acirc, "ngstrom"))
})

test_that("R-2.1: vectorised over the real corpus mix - corrupt, clean, and unrelated rows", {
  # The corpus does not arrive one string at a time; the corrupt and clean
  # spellings coexist within the same extraction (97 vs 12 unprocessed rows).
  # Confirm element-wise behaviour with NA present, since candidate rows carry
  # NA analyte labels.
  x <- c(acirl_corrupt_label, acirl_clean_label, NA, "Conductivity by PC Titrator", paste0(acirc, micro, "S/cm"))
  expect_no_warning(result <- normalise_lab_text(x))
  expect_identical(
    result,
    c(acirl_clean_label, acirl_clean_label, NA, "Conductivity by PC Titrator", paste0(micro, "S/cm"))
  )
})

test_that("R-2.1: table keys are matched LITERALLY (fixed = TRUE), not as regexes", {
  # Found by mutation testing (2026-08-08): flipping `fixed = TRUE` to
  # `fixed = FALSE` in normalise_lab_text() left the whole suite green, because
  # no key in either table currently contains a regex metacharacter. That makes
  # it an equivalent mutant TODAY and a live landmine TOMORROW - the very names
  # this table exists to repair are full of metacharacters. The registry
  # already holds `Heterotrophic Plate Count (22<B0>C)` and
  # `EA025: Total Suspended Solids dried at 104 <B1> 2<B0>C`; the moment
  # someone adds a mojibake key with parentheses or a `+`, regex mode would
  # match something else entirely (or, with an unbalanced bracket, error out)
  # and the failure would look like a data problem, not a code problem.
  #
  # So pin the semantics directly: swap in a table whose key IS a capture
  # group. Under `fixed = TRUE` the key matches only the literal 3 characters
  # `(x)`. Under `fixed = FALSE` it would instead match a bare `x` anywhere and
  # leave the literal parentheses in place - the two are trivially separable.
  local_mocked_bindings(
    .lab_text_real_char_fixes = c("(x)" = "OK"),
    .package = "sampleTidy"
  )
  expect_identical(normalise_lab_text("a(x)b"), "aOKb") # literal key matched
  expect_identical(normalise_lab_text("axb"), "axb") # regex-only match must NOT fire
})

test_that("R-2.1: source table stays ASCII-only, as R CMD check requires", {
  # The whole file is written with \\u escapes on purpose: a table whose job is
  # repairing encoding damage must not itself depend on how its own bytes are
  # decoded, and R CMD check's "code files for non-ASCII characters" would flag
  # literals. Easy to regress when adding an entry by pasting a glyph - which
  # is exactly what a hand-edit of the two new U+00C2 entries invites.
  src_path <- test_path("..", "..", "R", "text-normalise.R")
  skip_if_not(file.exists(src_path), "R/ sources absent (installed-package run)")
  # Byte-level, so no regex escaping can weaken the check: any byte above 0x7F
  # is a non-ASCII literal that should have been written as an escape.
  bytes <- readBin(src_path, "raw", n = file.size(src_path))
  expect_identical(bytes[bytes > as.raw(127)], raw(0))
})

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
