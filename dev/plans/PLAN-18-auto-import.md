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
- **After import.** Files the run archived (state `archived`) are removed from the
  folder (the package's `remove_ingested` behaviour); a folder left empty is removed.
  Files still `needs_review`, `quarantined` or `failed` stay where they are, so the
  folder stays visible as unfinished.
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

## 3. Wiring (not unit-tested; done after the package code)

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
  1.25 % v/v methane trigger at the gas grid (R2.3; stored L/L, ×100). Limits come from a
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
