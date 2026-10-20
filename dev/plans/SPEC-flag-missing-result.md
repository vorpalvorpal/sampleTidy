# Flag check `missing_result` (amends PLAN-18 §4.5 and PLAN-19 §6)

Robin, 2026-10-20: a field sheet sometimes has "_" (or "-") where a value should
be. For example ES2528155, 2025-09-09, B.L02 "Standing water level" is stored as
`analysis.value` NULL, `value_chr` "_". The import keeps the row, because it is
evidence. But nobody notices that the result is missing. "A missing result should be
flagged so that we can raise it with ACIRL."

## Rule (revised by Robin, 2026-10-20)

A result is **missing** when a number is expected but there is no number:

- `analysis.value IS NULL`, and
- the result's unit `COALESCE(lab_method.units, analyte.units)` (the image's `units`
  column, the same unit rule `unit_change` uses) is non-NULL and not empty/whitespace.

What `value_chr` says does not matter: "_", "-", "n/a", blank, NULL, "see comments" or
anything else. The analyte "expects a number" when it has units. Unit "1" (SAR) and
"pH" count as units. An analyte with no units (Appearance, Stage, colour or odour text)
is a text result, and it is never flagged. An empty-string `lab_method.units` counts as
no unit on the lab method, so the analyte's unit applies.

Live measurement (read-only copy, 2026-10-20):

- Of the 724 results with `value` NULL, 715 have no unit (Stage 314, Appearance 401, all
  with text). 9 have a unit: all are Standing water level (m) with `value_chr` "_".
- No unit-bearing result stores "<x" or ">x" with a NULL value.
- No analyte without a unit carries a numeric value.

So the rule needs no exceptions on the current data.

## Scope / window

The check uses the **recent-delivery window (ruling R1)**, the same one `site_history`,
`rl_change` and `unit_change` use: the image's `new` column. A recent delivery is a work
order with a pipeline `change_log` insert (with a source hash, by a non-migration actor)
in the last 90 days. Of that work order, only samples dated in the last 180 days are
assessed. Legacy history is never flagged.

QC samples are included. A blank result on a field duplicate is still a result to
chase, so the check is **not** in `.flags_qc_blind`.

## Output

There is one flag row per (work order `project`, feature, Sydney sample date, sample
`organisation`). Every missing analyte for that group is listed in the row. The rows of
the group are usually one sample. A field sheet and its lab sample from the same visit
and the same supplier collapse into one row.

- `check` = `missing_result`; `site`, `feature`; `date` = the Sydney sample date.
- `analyte` = the missing analytes' names, sorted and unique, joined by `", "`.
- `value` = NA; `unit` = NA.
- `threshold` = `"<n> blank result"` or `"<n> blank results"` (n = the number of
  missing results).
- `detail` = `<analyte> "<value_chr>"` per missing result (the text on the report, or
  `(blank)` when `value_chr` is NULL or empty), joined by `"; "`, then `"; <project>"`,
  then the action clause `" → ask ACIRL for the value or why it wasn't measured"`. For
  `ask_lab` the clause is `" → ask the lab for the value or why it wasn't measured"`.
- `key` = `missing_result|<project>|<feature>|<YYYY-MM-DD>|<organisation>`. NA parts are
  written as `NA`. The key is stable across runs, so `first_seen` carries over.
- `action` = `ask_acirl` when the sample `organisation` is `ACIRL`, ignoring case.
  Otherwise it is **`ask_lab`**, a new action meaning "ask the lab or supplier".
- `source` = NA.

Sort order is the usual `import_flags()` order. `missing_result` comes right after
`unit_change` in `.flags_checks`.

## Registration

- `.flags_checks` gets `"missing_result"` after `"unit_change"`.
- `.flags_fns` gets `missing_result = .flags_missing_result`.
- `.flags_meanings` gets `missing_result = "a result is blank on the report (\"_\" or
  similar) — ask the supplier for the value or why it wasn't measured"`.
- The `action` vocabulary becomes `resample`, `reanalyse`, `ask_acirl`, `ask_lab`,
  `chase`, `qualify`. It is documented in `?import_flags` and in CONTRACT.
- The `.flags_load()` image gains `value_chr` (on results) and the sample's
  `organisation`. These are additive columns.
- The status note's Flags section and `.import-status.json` show the flag like any
  other: the `**missing_result** — <meaning>` header, and a JSON row with `first_seen`.
