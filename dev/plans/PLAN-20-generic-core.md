# PLAN-20 — sampleTidy as a generic core

_Status: **PLANNED** 2026-10-20, nothing built. This is the public half of PLAN-20. The
deployment half (the Power Automate inbox, the Obsidian notes, the invoice-ledger check, the
licence tables and filing to a records system) lives in the deployment's own private repo,
which calls this package._

## 0. Rulings (Robin, 2026-10-20)

- **R20-1 sampleTidy is a generic core.** Nothing in `R/` is specific to one organisation,
  one person, or one inbox, notes, finance or records tool. Those integrate with it from
  outside, through the outputs and hooks below.
- **R20-3 "Fully imported" is a core concept.** A project's work is complete when all its
  samples are committed and no open review item references the project, its samples or its
  files. Flags (QC, limits) do not affect completeness.
- **Lab adapters stay in core** [proposed]. ALS ESdat, crosstab and ENMRG, the ALS QCI
  parser, and the ACIRL workbooks are lab formats, the same for any client, so they remain
  built-in adapters.

## 1. Changes

Each change is TDD: a separate test-writer and implementer.

1. **Structured outputs, not markdown.**
   - `inbox_run()` returns its result list as it does now.
   - It writes `status.json`, which is today's `.import-status.json`.
   - It appends one line per run to `events.jsonl`, which is today's `.imports.log`.
   - The markdown writers `import_status()` and `import_report()` leave the package. For one
     release, deprecated wrappers stay and call a registered renderer if there is one.
2. **Hooks.**
   - `register_hook(event, fn)`, with events `after_run`, `after_status` and
     `work_complete`.
   - Each hook runs in `tryCatch`. A failure is recorded in `status.json$problems` and never
     fails an import.
3. **A configurable inbox.**
   - Batch recognition becomes configuration: a folder-name pattern (default: any
     subfolder), a settle time (default: 0) and a leftover policy (default: leave in place).
   - The `input*` / 10-minute / `_emails/` behaviour becomes one deployment's settings.
4. **`completed_work(db, since = NULL)`.**
   - Returns one row per complete project: project, root project, site, dates and type.
   - Each row carries a list column of its assets: uuid, path relative to `archive_dir`,
     filename, hash, format and type.
5. **External filing records.**
   - A table `asset_filing(uuid_asset, system, external_id, external_uri, container,
     filed_at, title, comments)`.
   - `register_filing()` records a filing; `filed_assets(system)` lists them.
   - The core never interprets `system`.
6. **Constants become configuration.**
   - `st_config("timezone")`, default `"UTC"`.
   - Stream definitions become a table passed to `import_flags()`: stream, project type,
     feature pattern, matrix, and field-or-lab organisation.
   - Licence-condition behaviour becomes columns of the limits table.
   - Site display names are an optional table.
   - The gas adapter's site inference becomes a configurable site → keywords map, empty by
     default.
7. **`sampling_rounds()` leaves the package.** The `invoices` check already accepts a
   data.frame.
8. **`inst/extdata/sample-date-overrides.csv` leaves the package.** It holds one
   deployment's file hashes. The package ships an empty file with the same columns, and a
   deployment points `sampletidy.date_overrides_path` at its own.
9. **The EPA return leaves the package** (Robin, 2026-10-22). `dev/epa-monitoring-report.R`
   and its `v_*_epa` views belong to the deployment layer, which also holds what the licence
   specifies per point: which fraction (total or dissolved) each pollutant is reported as.
   The core keeps both fractions and only tags each lab method with its `fraction`.
   **Done 2026-10-22:** the script, template, licence tables and returns moved to the
   deployment repo's `epa/` folder (per-point `fraction` column, groundwater-dissolved default);
   `dev/auto-import.R` reads the tables from `SAMPLETIDY_AUTOIMPORT_LICENCE_DIR`. The `v_*_epa`
   views are still created by the migration chain.

## 2. Order

1. Items 1, 2, 4 and 5 (new `R/hooks.R`, `R/completed.R`, a migration). These do not depend
   on the deployment moving out.
2. Items 3 and 6–8, made together with the deployment repo, so the hourly job switches over
   in one step. The new layer's first run must reproduce the old `status.json` and notes on
   the same DB.
