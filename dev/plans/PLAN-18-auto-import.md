# Auto-import and the daily import note (spec, 2026-10-18)

Robin's pipeline: email → Power Automate ("File ACIRL emails to OneDrive", "File ALS
emails to OneDrive") → SharePoint `waste_data/Environmental monitoring/assets/input<YYYY-MM-DD HHMM> <subject>/`
(synced to the Mac) → **sampleTidy auto-import, hourly while the Mac is awake** →
**a daily note in Robin's Obsidian vault** listing what was imported and what needs review.

Robin's rulings (2026-10-18): note folder is a new JD `00.09 Import triage`
(beside `00.07 Email triage` and `00.08 Invoice triage`); runs hourly while awake;
plain facts only, no model calls.

## 0. The trigger rule (Robin, 2026-10-18): act **iff** a new report has landed

The hourly check must do **nothing at all** — no backup, no DB connection, no import, no
rewrite of the daily note, no log line — unless something in `input_dir` has changed
since the last check, or the last check left a folder still arriving (unsettled).

- `inbox_signature(input_dir)` returns a string built only from *metadata* (`stat`, never
  file contents — reading a Files-On-Demand file downloads it): every entry under
  `input_dir` to depth 2, as relative path + size + mtime, sorted, hashed.
- State file `<report_dir>/.imports.state` (JSON): `signature`, `pending` (TRUE if the last
  run left an unsettled folder), `checked_at`.
- `inbox_check(input_dir, report_dir, now)` returns TRUE ("run") iff there is no state
  file, the signature differs, or `pending` is TRUE; otherwise FALSE and **writes
  nothing** (not even `checked_at`).
- `inbox_run()` calls `inbox_check()` first and returns immediately (invisibly, with
  `ran = FALSE`) when it says FALSE. When it runs, it writes the state at the end with
  the signature of `input_dir` *after* its own file removals, so its own clean-up does
  not trigger the next check.
- The launchd job still fires hourly, but `dev/auto-import.sh` performs the same
  metadata-only check in shell (stat, no R start-up) and only launches Rscript when it
  differs or `pending` is set; R re-checks with `inbox_check()` so the rule holds even if
  the shell gate is wrong.
- **Second trigger: the database changed.** Review items can be resolved outside an
  import (a migration, `release_review()`), so the check also records the live DB file's
  size + mtime (stat only). If those differ from the state file, `inbox_check()` returns
  `"status"`: refresh the standing status note (below) read-only, no import, no backup.
  So `inbox_check()` returns one of `"none"`, `"status"`, `"run"`.
- **Third trigger: a new Sydney day (ruling 2026-10-19 R14).** Flags change with the date
  alone (a round becomes overdue on its due date), so a quiet day must still refresh the
  note. `inbox_check()` also returns `"status"` when the Australia/Sydney calendar day of
  the state's `checked_at` (ISO-8601 UTC, `%Y-%m-%dT%H:%M:%SZ`, already written by every
  run and every status refresh as the `now` of that call) differs from the Sydney day of
  `now`; a missing or unparseable `checked_at` also gives `"status"`. Precedence is
  unchanged: the `"run"` reasons (no state, signature changed, `pending`) are checked
  first, then the DB stat and the day, either giving `"status"`. Because the status refresh
  rewrites the state with the new `checked_at`, there is at most one day-triggered refresh
  per Sydney day, and it never imports, backs up or logs. `inbox_check()` still writes
  nothing. (In AEDT, Sydney midnight is 13:00 UTC: 12:30 UTC and 13:30 UTC on 19 Oct fall
  on Sydney days 19 and 20.)

## 1. `inbox_run()` (package function, R/inbox.R)

`inbox_run(input_dir = st_config("input_dir"), db = st_config("live_db"), backup_dir, report_dir, now = Sys.time(), settle_minutes = 10, keep_backups = 10, dry_run = FALSE)`

- **Candidates.** Each immediate subdirectory of `input_dir` whose name starts with
  `input` (one per email, as the flow writes them). Loose files directly in `input_dir`
  and other subdirectories are ignored (left for a human). The bare `input` folder
  itself, if present as a subdirectory, is not a candidate.
- **Settled gate.** A folder is processed only when it is *settled*: it contains at
  least one file, and no file in it was modified within `settle_minutes` of `now`
  (the flow writes attachments one by one and OneDrive syncs them in no fixed order).
  An unsettled folder is reported as "arriving" and left for the next run.
- **Nothing to do → no write.** If no settled folder holds a file that is new to the
  DB (hash not in `ingest_file`, or in a router-reconsiderable state per A90), the run
  opens no write connection and takes no backup. (It only gets this far when section
  0's check said something changed; it then rewrites the report and the state.)
- **Backup first.** Before the first write of a run: copy the live DB to
  `backup_dir/monitoring_pre-auto-import_<UTC stamp>.duckdb`, verify by SHA-256 equality,
  and abort the run (report it as an error) if verification fails. Keep only the newest
  `keep_backups` files matching `monitoring_pre-auto-import_*.duckdb`; never touch other
  backups.
- **Import.** One `ingest_dir()` call per settled folder, oldest folder name first
  (the name starts with the arrival time), exactly as the manual runs did
  (scratchpad/2026-10-17-pending/run.R). A failure in one folder is contained: it is
  recorded and the next folder still runs.
- **After import.** Files the run archived are removed from the folder (a file with an
  asset row is removed even if its state is `needs_review`, because it is already
  archived). Then **filing** runs over every settled candidate folder (not only those
  imported this run, so pre-existing folders clear too): if no DATA file in the folder
  is unfinished (needs_review, with or without an asset, failed, quarantined), every remaining
  file is MOVED to `<archive_dir>/_emails/<folder basename>/` (`" (2)"`, `" (3)"` on a
  name collision; never overwrite, never delete) and the empty folder removed. DATA =
  csv, tsv, txt, json, xml, xls, xlsx, xlsm, xlsb, zip, or anything an adapter claims;
  everything else (.eml, images, pdf, doc/docx, msg, html, ...) is a leftover. A folder
  with an unfinished data file moves nothing and stays under Waiting, listing the
  unfinished data files and "<n> other file(s) ... filed with it". Filing is recorded in
  the log (`files_filed`) and in a **Filed** section of the dated note, which is written
  on a filing-only day too. Accepted risk (2026-10-19): an ALS COA arriving in an email
  *before* its data is filed under `_emails`, not attached to its work order.
  A `needs_review` data file holds its folder back even when archived (R-22.N, Robin
  2026-10-25); resolving the file's last open review item settles it to `archived`, so
  the folder files on a later run.
- **Lock.** Only one `inbox_run()` at a time: a lock file in the DB's directory with the
  PID and start time; a lock older than 2 hours or whose PID is dead is stale and taken
  over (and that is reported). A second concurrent run exits immediately, writing nothing.
- **Run log.** Append one JSON line per run to `<report_dir>/.imports.log`:
  start/end time, folders seen/settled/processed, per-folder outcome (events committed,
  rows new/already/superseded, review items opened, failures, files left), backup path,
  errors.
- **Return** a list with the same content (for tests).
- `dry_run = TRUE`: no backup, no DB write, no file removal; the report is written with
  a "DRY RUN" banner.

## 2a. The standing status note (Robin, 2026-10-18)

Open review items must stay visible every day until resolved, whether or not a report
landed. They live in the database (`review_queue`); `import_status()` exports them to one
**standing note**, `<report_dir>/Import status.md`, rewritten whenever `inbox_check()`
says `"status"` or `"run"` (never otherwise). It holds, in order: a header line
`*Import status · updated YYYY-MM-DD HH:MM · <m> review item(s) open, <w> folder(s) waiting*`;
**Needs review** (as described in 2 below, with **new** = opened in the last 24 h);
**Waiting**; **Problems** from the most recent run (omitted if none); **Recent imports**
(the last 14 days, one line per work order, newest first, each linking its dated note);
and a footer. It is also written as `<report_dir>/.import-status.json` with the same
content as data. The daily-note template embeds `![[Import status]]`, so every day shows
the current list.

**Frontmatter (ruling 2026-10-19 R8).** The vault convention is a YAML frontmatter
`summary:` list on notes; something in the vault added one to `Import status.md`, which the
hourly rewrite would wipe or leave stale. So `import_status()` and `import_report()` each
write their own leading frontmatter, before the existing first line:

```
---
summary:
  - '<one plain-facts sentence>'
---
```

Deterministic (no model); a single-quoted YAML scalar with every `'` doubled; built by the
internal seam `.inbox_frontmatter(summary)` (returns those four lines). The status note's
sentence gives the updated time (`YYYY-MM-DD HH:MM` Sydney), `<n> review item(s) open`,
`<n> flag(s)` with the top 3 checks by count, `<w> folder(s) waiting`, and what was
imported today if anything; the dated note's sentence gives the review items open and the
work orders imported that day. The whole file is rewritten, so a frontmatter written by
anything else is replaced, never duplicated. The header line stays the first line *after*
the frontmatter (tests read notes through `strip_frontmatter()` in `helper-inbox.R`).

The dated `<YYYY-MM-DD>-imports.md` (section 2) is the day's history: it is written only on
a day something was imported or a run had a problem, and holds **Imported today** and that
day's **Problems** only (Needs review and Waiting move to the status note).

## 2. `import_report()` (package function, R/inbox.R)

Writes/overwrites `<report_dir>/<YYYY-MM-DD>-imports.md` for the local (Australia/Sydney)
date of `now`. Rewritten every run, so it always shows the current state. Read-only on
the DB (snapshot/read-only connection). Plain markdown, Obsidian-friendly, no
frontmatter needed (it is embedded with `![[YYYY-MM-DD-imports]]`, like
`YYYY-MM-DD-invoices`). Content, in this order:

1. A one-line italic header: `*Imports · HH:MM · <n> folder(s) imported today, <m> review item(s) open*`
   (local time of the last run).
2. **Imported today** — every work order / report committed today (Sydney day), grouped
   by site (Blaxland / Katoomba / other, from the features' site), one line each:
   project name, kind (ALS lab / ACIRL water / ACIRL gas / dust), sampling date range,
   samples and analyses added, and the source email folder name. "Nothing imported
   today." if none.
3. **Needs review** — open review_queue items, grouped by kind then work order, with a
   count and the oldest date; for each group one short plain-language line of what it
   means (a fixed lookup table per kind/subkind, e.g. `date_conflict/a77` → "dust block
   dates disagree; held until released", `work_order_reingest/blocked` → "lab file for a
   work order already in the database; held", `unknown_feature` → "sampling point not
   recognised"). Items opened today are marked **new**. Non-blocking notes
   (`self_precedence_note`) are listed last and collapsed into one count line.
4. **Waiting** — folders still in `input_dir`: arriving (unsettled), left with
   unfinished files (name the files and their state), and any loose files.
5. **Problems** — errors from today's runs (backup failure, folder failure with its
   message, stale lock taken over). Omitted when there are none.
6. A footer line: `*Last run HH:MM; next within the hour. Log: .imports.log*`.

Paths to source folders are given as `file:///` links (as the invoices note does).

**2026-10-19 bug.** The live dated note said "no sample dates" for deliveries whose samples
carry only `sample.date` (`datetime` NULL; e.g. ES2626883, and every ACIRL field, gas and
dust row). The sampling date range of an import line uses `COALESCE(s.datetime, s.date)`,
the same rule as `LOCAL_DATE` in `dev/epa-monitoring-report.R` and §4.5's sample date.
Pinned by `tests/testthat/test-inbox-sample-dates.R` (date-only and datetime samples).

## 3. Wiring (not unit-tested; done after the package code)

**Runs committed code only (2026-10-19).** `dev/auto-import.sh` runs `dev/auto-import.R` from a
detached worktree at `~/.local/share/sampleTidy-run`, moved to `main`'s commit on
every run, never from the working tree: a development session's uncommitted edits must not reach
the live DB. Uncommitted work is invisible to the hourly run until it is committed to `main`.


- `dev/auto-import.R`: loads the package, calls `inbox_run()` with the live config and
  `report_dir = ~/pkm/0 Misc/00 Misc/00.09 Import triage`.
- A launchd LaunchAgent `~/Library/LaunchAgents/com.rjs.sampletidy.autoimport.plist`
  running it every 3600 s (`StartInterval`), logs to `~/Library/Logs/sampletidy-autoimport.log`.
- Vault: create the `00.09 Import triage` folder note (copy 00.08's structure), and add
  `> [!todo|imports]- **Imports**` + `> ![[<date>-imports]]` after the Invoices callout in
  `_system/Obsidian templates/Daily template.md`.

## 4. Phase 2: checks in the status note (Robin, 2026-10-19)

Built after phase 1 (sections 0-3) lands. All checks are deterministic R, read-only on
the DB, computed whenever the status note is refreshed. Each produces flag records
(`check`, `site`, `feature`, `analyte`, `date`, `value`, `unit`, `threshold`/`expected`,
`detail`, `first_seen`) written into `.import-status.json` and shown in the status note
under **Flags**, grouped by check, newest first. A flag stays listed while its condition
holds; acknowledged flags are out of scope for now (later: an ack list Robin edits).

**4.1 Overdue deliveries** (Robin: "1 & 3").
- `dev/expected_schedule.csv` (hand-built, reviewed by Robin): `site, stream`
  (acirl_water_monthly / acirl_water_quarterly / acirl_water_annual / acirl_gas /
  acirl_dust / als_lab), `months` (which months it is due), `features` (expected points,
  from the licence requirements and ACIRL's revised schedule from Aug 2026),
  `due_days` (default 30 days after the sampling month ends), `from`/`to` validity dates.
- Flag **overdue** when a due month has no delivery of that stream by `due_days`.
- **Invoice evidence:** also flag **invoiced, not received** when an ACIRL invoice lists
  sampling for a site/date (from the invoice-triage data; locate its store and read it
  read-only) and no matching delivery exists after `due_days`. E.g. the 19 Aug 2026 round.

**4.2 Incomplete deliveries.** For each delivery imported in the last 90 days, compare
its (feature, analyte) set with what that round should contain: the licence requirements
due in that month (monthly always; quarterly in the quarter's round; yearly in the annual
round) for that site, plus the schedule's `features`. Flag **missing point** (a feature
with no sample at all, e.g. B.S22 Dec 2025) and **missing analytes** (a sampled feature
lacking required analytes, listed). Field-only or lab-only gaps are shown as such.

**4.3 Exceedances** (Robin: licence limits, site history, gas LEL/EPA).
- **Licence limits:** L2 at the discharge points B.E01, K.E01, K.E02 (pH 6.5-8.5 with the
  field pH winning where both exist, NH3-N 0.9 mg/L, TSS 50 mg/L, 100 percentile), and the
  methane triggers (stored L/L, ×100): R2.3 at the gas grid, 1.25 % v/v at Blaxland
  (Point 10) and 1 % v/v at Katoomba (Point 1), plus Katoomba M7.3, 1 % v/v in any
  building or structure (K.G367-K.G473). Limits come from a
  data table (not code): `dev/epa_licence_limits.csv`. The storm exemption (L2.5) is not
  assessed automatically; the flag says so.
- **Gas LEL / EPA criteria:** the `guideline` rows LEL 10 %/50 %, EPA impact assessment
  criteria and solid waste guidelines trigger value, applied to the analyte they are
  keyed to, at gas and building points.
- **Site history:** for each (feature, analyte) with at least 8 prior quantified results,
  flag a new result outside the prior min-max *and* with |robust z| > 4 (median/MAD of the
  prior 5 years); below-detection results are never flagged as low outliers. Also flag a
  change in reporting limit or unit for that pair.

**4.4 Model summary:** deferred. Robin will decide after seeing the deterministic flags.

## 5. Host, trigger, and licence/schedule updates (Robin, 2026-10-19)

**One writer, the Mac, for now (Robin: "we will revisit this later").** Imports and
migrations run only on the machine holding `st_config("live_db")`. Every other machine
is a reader: OneDrive snapshots (read-only) for data, the vault (synced) for notes.
Rejected for now: treating the OneDrive copy as the true DB with download/edit/re-upload
on any machine (lost updates, no atomic lock across sync clients, half-synced 200 MB
file). Possible later: explicit check-out/check-in with a generation counter.

**Trigger: Obsidian, not cron/launchd/Task Scheduler.** One Shell commands plugin entry
(`obsidian-shellcommands`, already installed) with macOS and Windows variants, run on
Obsidian start-up and every 3600 s. It calls `dev/auto-import.sh` (macOS) /
`dev/auto-import.cmd` (Windows), which exit at once unless this machine holds the live
DB; then the section 0 metadata check; then Rscript. The Imports callout computes the
status note's age at render time and shows "updated N days ago on <host>" when stale.

*Superseded on the Mac, 2026-10-25 (Robin):* imports stopped from 22 to 25 Oct while
Obsidian was closed. The Mac trigger is now a launchd agent
(`dev/launchd/net.robinshannon.sampletidy-autoimport.plist`, installed by
`dev/launchd/install.sh`; `install.sh uninstall` removes it). `WatchPaths` on the input
directory fires when a delivery folder appears, and `StartInterval` 600 re-checks until the
folder settles. The plist sets a UTF-8 locale, since launchd starts jobs in the C locale and
R then cannot parse the package's `°C`/`µg/L` source. The Obsidian entry was at first left in place:
the R lock and the metadata gate make a second trigger a no-op. *Removed 2026-10-25 (Robin):* the
Obsidian entry's events are disabled, so launchd is the only trigger (launchd never overlaps
two instances of one job).

**Licence and schedule changes: notes + monthly headless Claude Code, not a flow.**
- Folder notes (`51.12 License variation - 10039`, the Katoomba licence folder,
  `61.02 Monitoring Blaxland`, `62.03 Monitoring Katoomba`) carry a "What sampleTidy
  uses" block: licence version + date, requirements CSV checksum, schedule source and
  review date, last verified.
- A Claude memory note points at those blocks.
- Monthly (Obsidian start-up if the last check is > 30 days old, Mac only):
  `claude -p` with a fixed prompt searches the vault for evidence of change since the
  last check (diary, email-triage notes, licence/monitoring folders: new licence version,
  variation notice, POEO number, EPA audit outcome, ACIRL schedule change), compares with
  the recorded versions, writes `00.09 Import triage/Licence & schedule check.md`, and a
  one-line flag into the status note. It never edits the requirements or schedule
  tables; a real change goes through the reviewed blind re-transcription.
- Drift detection (delivered-but-unscheduled / scheduled-but-missing points) stays as
  the backstop.

### 4.5 Contract (phase 2)

Pinned by `tests/testthat/test-inbox-flags.R` (helpers in `helper-flags.R`) and, for R8,
`test-inbox-frontmatter.R`. Items marked **[invented]** were not decided by Robin; the
test-writer chose them (2026-10-19) and they are open to his ruling. Items marked
**ruling 2026-10-19 R<n>** come from the main agent's rulings after the first read-only
live smoke gave ~1,000 mostly false flags (`scratchpad/2026-10-19-phase2-impl/RULINGS-1.md`);
they supersede what they replace.

**API.**

- New export `import_flags(db = st_config("live_db"), now = Sys.time(), checks)` →
  `data.frame`, one row per flag, columns exactly `check, site, feature, analyte, date,
  value, unit, threshold, detail, key, source` (all character except `value`, numeric;
  `NA` where a column does not apply, e.g. `feature`/`analyte`/`value` of an overdue flag).
  `source` (**ruling 2026-10-19 R12**) is the schedule row's `source` for overdue flags,
  `NA` otherwise; it is written to each JSON flag object but never shown in the note line. Rows are
  ordered by `check` in the order of the list below, then `date` descending. Read-only:
  opens the DB `read_only = TRUE`, never writes it.
- `check` ∈ `overdue, invoiced_not_received, missing_point, missing_analytes,
  licence_limit, gas_criterion, site_history, rl_change, unit_change`.
- `site` is `feature.site` (or the schedule/invoice site): `"B"`, `"K"`, ...; `date` is
  `YYYY-MM-DD`; `key` is a stable id built only from the flag's identity (never from
  `now`, the value, or row order), unique within one result, so `first_seen` survives
  re-runs.
- **Per-check errors are contained [invented].** Each check runs inside its own
  `tryCatch`; a failing check contributes no rows and its message is returned in
  `attr(result, "errors")`, a named character vector (`names` = check name;
  `character(0)` when none). `import_flags()` itself errors only on bad arguments.
- `checks = list(schedule =, limits =, requirements =, points =, invoices =)`. The first
  four are each a CSV path or a `data.frame`; `invoices` is `data.frame(site, stream,
  sampled_on (Date), ref)` or `NULL`. A `NULL` element silently disables the checks that
  need it (no rows, no error); a path that does not exist or a malformed table is an
  error **of each check that needs it** (schedule → overdue, invoiced_not_received,
  missing_point; requirements + points → missing_analytes; limits → licence_limit). The
  DB-only checks (gas_criterion, site_history, rl_change, unit_change) always run. CSVs
  are read with every column as character; an empty string and `NA` both mean "missing".
  The package never reads `dev/`; `dev/auto-import.R` passes the `dev/` paths.
- `import_status(..., checks = NULL)` and `inbox_run(..., checks = NULL)` (passed to every
  `import_status()` call it makes). `checks = NULL` → the note and JSON are exactly as in
  phase 1 (no Flags heading, no `flags` key). Non-NULL → a `## Flags` section placed after
  `## Needs review` and before `## Waiting`: first one line per failed check,
  `- check <name> failed: <message>`; then the flags grouped by check (fixed order above),
  each group headed `**<check>** — <plain meaning>` with one `- ` line per flag, newest
  `date` first, the line carrying the date, site, feature/analyte, value + unit,
  threshold and detail where present; `No flags.` when there are no flags. **Ruling
  2026-10-19 R6:** at most 15 flag lines per check (the newest), then one line
  `+N more — see .import-status.json`; the JSON keeps every flag. The JSON gains
  `flags` (array of objects: the ten columns plus `first_seen`) and `flag_errors` (array
  of `{check, message}`). `first_seen` is ISO-8601 UTC (`%Y-%m-%dT%H:%M:%SZ`, as in the run
  log): carried over by `key` from the previous `.import-status.json` (read before it is
  overwritten; missing/corrupt → none), else `now`. A flag no longer computed is dropped.
  The header line is unchanged.

**CSV formats** (another agent builds the real files).

- `expected_schedule.csv`: `site,stream,months,features,due_days,from,to,source`.
  `stream` ∈ `acirl_water, acirl_gas, acirl_dust, als_lab` (anything else is an error of
  the schedule checks); `months` = `all` or a `;` list of 1-12 (whitespace tolerated;
  anything else is an error); `features` = `;` list of feature names, may be empty;
  `due_days` int; `from`/`to` `YYYY-MM-DD`, empty `to` = open-ended.
- `epa_licence_limits.csv`: `site,feature_pattern,analyte,min,max,unit,factor,condition,note`.
  `feature_pattern` is an R regex matched against `feature.name` (of features whose
  `feature.site == site`); `analyte` is `analyte.name`; `min`/`max` may be empty; `factor`
  multiplies the stored value into `unit` (empty = 1; methane L/L → % is 100).
- `epa_licence_requirements.csv` / `epa_licence_points.csv`: the existing files, read as
  `dev/epa-monitoring-report.R` reads them.

**Common definitions.**

- **Sample date** = the Australia/Sydney calendar day of `COALESCE(sample.datetime,
  sample.date)` read as a UTC instant — the `LOCAL_DATE` rule of
  `dev/epa-monitoring-report.R` and migration 022 (gas and dust carry only `date`).
  "Today" = the Sydney date of `now`.
- **Stream of a sample [invented, revised by ruling 2026-10-19 R2].** `acirl_dust` if
  `project.type = 'Dust monitoring'` or the feature name matches `\.D[0-9]` (dust gauges
  sit inside ALS `ES#######` work orders); else `acirl_gas` if `project.type = 'Monthly gas
  monitoring'` (the `2400-####-##` projects, including their gas readings at wells) or
  `feature.matrix = 'air'`; else the sample belongs to **every stream its results
  evidence, decided per result from the lab method, not from `sample.organisation`**
  (R2; live ES2604522 has `sample.organisation = 'ACIRL'` but mostly ALS lab results): a
  field result (below) evidences `acirl_water`, a lab result `als_lab`. A sample with
  neither (e.g. `Internal` methods) has no stream. One ES work order with ALS lab results
  and ACIRL field readings therefore counts for both `als_lab` and `acirl_water`.
- **Field vs lab result (ruling 2026-10-19 R2).** Per result: *field* when
  `lab_method.organisation` is `ACIRL` or `lab_method.method` contains `Client Supplied`
  (ALS's `EN67 - Client Supplied Data` field-probe rows); *lab* otherwise when
  `lab_method.organisation` is `ALS`; neither otherwise. `sample.organisation` plays no
  part. The field-pH-wins rule uses this classification.
- **Recent delivery (ruling 2026-10-19 R1, replaces the change_log-90-day rule).** A work
  order's samples are assessed only if BOTH (a) it was imported **by the pipeline** within
  the last 90 days: some `change_log` row with `action = 'insert'`, (`tbl = 'sample'`,
  `uuid_row` = one of its samples) or (`tbl = 'analysis'`, `uuid_row` = an analysis of one
  of its samples), a **non-NULL `source_hash`**, an `actor` that is not a migration
  (migration actors match `^[0-9]{3}-` or `migration-`), and `at >= now - 90 days` (`at` a
  UTC instant); AND (b) the sample's date is within the last 180 days of today
  (applied per sample). Backfills of old data (legacy gas, the coming corpus run) and
  migrations never count. Every per-result check (licence_limit, gas_criterion,
  site_history, rl_change, unit_change) and missing_point/missing_analytes assess only
  these samples ("new results").
- **Feature/analyte mapping for 4.2** exactly as `dev/epa-monitoring-report.R`: EPA point
  → features via `feature_mask` (`variant = 'EPA'`, `name = epa_point`, same site);
  pollutant → analytes via `analyte_mask` (`variant = 'EPA'`, `name = pollutant`).
  Points whose role (points CSV) is `weather` and `Special Frequency 1` rows (discharge,
  per event) are never required.
- Non-detects (`analysis.quantified = FALSE`) are never flagged by licence_limit,
  gas_criterion or site_history **[invented: the stored value is the RL, so it can show
  neither a breach nor an outlier, high or low]**; a raised RL is rl_change's job.

**4.1.**

- `overdue`: for each schedule row and each month M from 12 months before today's month
  to the month before it (12 months), where M is in `months`, the row is valid in M
  (`from <= last day of M` and (`to` empty or `to >= first day of M`) — overlap
  **[invented]**) and the due date `last day of M + due_days` is **before** today (a due
  date of today is not yet overdue): flag when no sample of that stream at that site has
  a sample date in M. `date` = first day of M; `threshold` = `expected <Mon YYYY> by
  <due date>` (C-locale month abbreviation). **Ruling 2026-10-19 R12:** `detail` is exactly
  `no <stream> sample dated in <Mon YYYY>`; `source` goes to its own column/JSON field; an
  overdue flag is **suppressed** when an `invoiced_not_received` flag exists for the same
  site, stream and month (of `sampled_on`) — the invoice flag is the more specific
  statement of the same gap. key `overdue|site|stream|YYYY-MM`.
- `invoiced_not_received`: per invoice row, `due_days` from the first schedule row of that
  site and stream valid on `sampled_on` (default 30); flag when `sampled_on + due_days` is
  before today and no sample of that stream at that site has a sample date within ±3 days
  of `sampled_on` (inclusive). `date` = `sampled_on`; `threshold` = `expected by <date>`;
  `detail` carries `ref` and the stream. key `invoiced_not_received|site|stream|date|ref`.

**4.2 [invented: round-based, to avoid false flags when one round arrives in two work
orders].**

- A recent delivery's **rounds** are the (site, Sydney month) pairs of its samples.
- `missing_point` (aggregated by **ruling 2026-10-19 R3**): for each round and each stream
  of the delivery's samples, the expected features are the union of `features` of that
  stream's schedule rows for the site, valid in the month, with the month in `months`. A
  feature is sampled when it has any sample (any stream, any project) at that site in that
  month — **for `acirl_gas`, in that month or the month either side** (gas rounds split
  across adjacent months). **One flag per (site, round month, stream):** `feature = NA`;
  `detail` contains `k of n expected points not sampled: <first 10 names, sorted, ", "-joined>`
  then `, +m more` when more than 10, and names the stream and the work order(s); `date` =
  the earliest assessed sample date of the round's recent deliveries.
  key `missing_point|site|YYYY-MM|stream`.
- `missing_analytes`: for each feature sampled in a recent delivery that maps to a
  licence point, with d = its latest sample date in the delivery: the required pollutants
  are its requirements rows with frequency Monthly, Quarterly or Yearly; a pollutant is
  present when any result of a mapped analyte exists at that feature (any project, field
  or lab) dated within: Monthly — the calendar month of d; Quarterly — `[d - 120 days,
  end of d's month]`; Yearly — `[d - 395 days, end of d's month]` **[invented: rolling
  windows, since neither table says which month is "the quarter's round"]**.
  **One flag per (site, round month) (ruling 2026-10-19 R4):** `feature = NA`; `detail`
  lists each missing pollutant with its features, `<pollutant>: <feature>, <feature>`,
  entries joined by `; `, e.g. `Total Phenolics: B.S01, B.S03; pH: B.E01`; a feature that
  had only field (only lab) results while the site-month had both kinds is written
  `B.S02 (field only)` / `B.S02 (lab only)` **[invented label]**; at most 15 pollutants,
  then `+m more`. key `missing_analytes|site|YYYY-MM` (stable while the list changes).
  **Mapping exactly as `dev/epa-monitoring-report.R` (R4):** requirements are matched by
  their `pollutant` column — group line items (`group_item` OCP/OPP/TPH) are already
  expanded into one row per congener/fraction, so the congener name is matched to
  `analyte_mask.name` and the group's `licence_pollutant` name is never used; a (point,
  pollutant) listed under two conditions is one requirement; mask rows with a NULL or blank
  name map nothing. Calibration (not a unit test): Blaxland 2025-08-22..2026-08-21, the
  (point, pollutant) pairs with zero results must reconcile with the report script's unmet
  requirements (583 of 593 required counts met).
  **Group collapse (ruling 2026-10-19 R11):** when every member of a licence group (rows
  sharing a `group_item` at a point, mapped as above) is missing and the members' feature
  sets are identical, the group is rendered once as `<licence_pollutant> (<n> analytes):
  <features>` (e.g. `Organochlorine pesticides (3 analytes): B.MW01`) and the member names
  are not listed; otherwise (any member present, or differing feature sets) the members
  are listed individually as before. A collapsed group counts as one entry toward the
  15-entry cap.
  **Water evidence only (ruling 2026-10-19 R10):** for `acirl_water`/`als_lab` rounds,
  missing_point and missing_analytes consider only results whose stream is `acirl_water`
  or `als_lab`. A gas- or dust-round reading at a water point (live: 2400-7539-06-02 gas
  readings at Katoomba wells) neither makes the point sampled nor counts as a field result;
  `(field only)` / `(lab only)` are computed from water-stream results only.

**4.3.**

- `licence_limit`: each limits row against the new results at matching features and
  analyte: `v = value × factor`; flag when `v < min` or `v > max` (strict — exactly at a
  limit is compliant, e.g. TSS 50.00 at 50). Where a (feature, sample date) has both a
  field and a lab result of that analyte, only the field results are assessed (Robin's
  pH ruling, 2026-07-24). `value` = v, `unit` = the limit's unit; `threshold` = `> max
  unit`, `< min unit`, or `outside min-max unit` when both are set; `detail` gives the
  condition and, for `L2*` conditions, says the storm exemption (L2.5) was not assessed.
  key `licence_limit|feature|analyte|date|field-or-lab`.
- `gas_criterion` **[invented matching]**: `guideline` rows whose `guideline` is `LEL` or
  `EPA` (the 10 %/50 % LEL, EPA impact assessment criteria and solid waste guidelines
  trigger value rows), applied to new results of the row's `uuid_analyte` at features with
  `matrix = 'air'` or in samples of stream `acirl_gas`, comparing the stored value
  directly (guideline values are stored in the analyte's canonical units). Flag when
  `value > guideline.value`; one flag per result per guideline family (`LEL`, `EPA`), at
  the highest level exceeded; `threshold` = `> value units (level_name)`. Other families
  (`dgv`, `ACGIH`, ...) are not used. key `gas_criterion|feature|analyte|date|family`.
  **Ruling 2026-10-19 R9:** the EPA `solid waste guidelines trigger value` row (CH4 500
  ppm = 0.0005 L/L) is a surface-gas criterion, applied only at the site's surface gas grid
  points = features of that site matching the `feature_pattern` of a limits row with
  `condition = 'R2.3'` (B.G grid, K.G01-364). Not at wells, building points or other
  features; with no limits table it applies nowhere. LEL rows and the other EPA rows (dust
  impact assessment criteria) keep the scope above.
- `site_history`: for each new quantified result, the priors are the quantified results of
  the same (feature, analyte) with a sample date in `[d - 5 years, d)`. With at least 8
  priors, flag when the value is outside `[min, max]` of the priors **and** `|z| > 4`,
  `z = (value - median) / (1.4826 × MAD)`. **MAD = 0 [invented]:** flag whenever the value
  is outside the prior range (z taken as infinite); `detail` says `prior results have no spread (MAD 0)`
  (**ruling 2026-10-19 R13**; never "all equal" — the priors may still have a range).
  `threshold` = `prior range min-max (n=N)`. key `site_history|feature|analyte|date`.
- `rl_change` (**ruling 2026-10-19 R5**): flags only a RAISED reporting limit — the new
  `analysis.rl_low` is greater than the maximum non-NA `rl_low` of that (feature, analyte)
  over sample dates in `[d - 2 years, d)`; a lower or equal RL, or no prior RL, is not
  flagged; `detail` gives the prior maximum and the new RL. `unit_change` (unchanged): for
  each new result, the most recent prior result of the pair is the set of results on the
  latest sample date before d; unit = `COALESCE(lab_method.units, analyte.units)`; flag when it equals
  none of the prior results' units (both non-NA); `detail` gives old and new. keys
  `rl_change|feature|analyte|date`, `unit_change|feature|analyte|date`.

- **Ruling 2026-10-19 R7:** unchanged — gas_criterion including the solid waste guidelines
  500 ppm trigger (with R1 it covers recent rounds only), the overdue rules, `first_seen`
  carry-over.
- **Ruling 2026-10-19 R8:** both notes carry their own `summary:` frontmatter; see 2a.

### 4.6 Contract (sampling rounds from the contractor work ledger)

*Superseded the PDF parser, 2026-10-19: one parser, in t1.* sampleTidy no longer reads
ACIRL invoice PDFs (`acirl_invoices()` / `acirl_invoice_text_parse()` and `pdftools` are
gone). The t1 tool writes `contractor-work.json` (spec:
`invoice-automation/docs/contractor-work-ledger.md`) and sampleTidy reads it. Feeds
`checks$invoices` (4.5) for `invoiced_not_received`. Pinned by
`tests/testthat/test-sampling-rounds.R`, fixtures `tests/testthat/fixtures/contractor_work/`.

**API.** New export `sampling_rounds(ledger)`; `ledger` is the path to `contractor-work.json`.
Returns `data.frame(site, stream, sampled_on, ref, section, note)`: `sampled_on` is `Date`,
the rest character, `note` `NA` when the ledger's is null.

- Only items with `kind == "sampling_round"`; other kinds are ignored silently (this is what
  lets other suppliers' works be added to the ledger later).
- `site`: t1 name mapped to sampleTidy code, `Blaxland` -> `B`, `Katoomba` -> `K`. Any other
  site name is dropped, no error (design left open).
- `stream` = the item's `activity`; only `acirl_water, acirl_gas, acirl_dust, als_lab` kept.
- `ref` = the invoice key; `sampled_on` = `date`; `section`, `note` as in the ledger.
  A date that disagrees with the invoice period arrives as printed with a `note`.
- Entries with `items: []` contribute nothing.
- Missing file -> zero-row frame with the right columns and types (the ledger may not exist
  on a machine). Corrupt JSON -> `sampletidy_parse_error` naming the path (callers in
  `dev/auto-import.R` catch it). `version` other than 1 -> error.
- Read-only. `jsonlite` is already in `Imports`.

`dev/auto-import.R` passes `sampling_rounds(<OneDrive ledger dir>/contractor-work.json)[,
c("site", "stream", "sampled_on", "ref")]` as `checks$invoices` (wiring, not unit-tested).
