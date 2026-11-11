# sampleTidy (development version)

* The Windows import trigger (`dev/auto-import.ps1`) now matches the Mac one
  (`dev/auto-import.sh`): run-health record, retry after a failed or crashed run,
  notify and flush commands, a stale-success notice, listing failures exit 3,
  an empty input listing never skips, a re-check after the run, the pause
  file must be a regular file, and `--print-config` prints eight lines. It reads
  R's `.Renviron` (`-RenvironFile` names another) and runs `main` from a
  detached worktree (`%LOCALAPPDATA%\\sampleTidy-run`) instead of its own
  working tree. `dev/windows/install-task.ps1` registers it as a scheduled task
  (`-Print`, `-Uninstall`, `-Launcher conhost|none`, `-Name`, `-RenvironFile`).
  The import notice for an unreadable input folder no longer
  mentions launchd.
* The inbox lock's liveness check no longer uses `tools::pskill()`, which on
  Windows terminates the process it was meant to test: `.st_pid_alive()` uses
  the new `ps` dependency instead.

* A writer check for running one importer across machines (all off unless
  configured):
  - `db_meta` (ops-schema 11) is a key/value table for facts about the
    database itself, read and written with `db_meta_get()`, `db_meta_set()`
    and `db_meta_read()`. The core knows `writer_generation` and
    `writer_label` but never writes them.
  - `st_config("writer_check")` (default `NULL`) is a function `inbox_run()`
    calls first, as `fn(db)`. Only `TRUE` allows the run; anything else, or an
    error, refuses it before the database is touched. A refusal is one
    `events.jsonl` line and, when `status.json` exists, a `writer_check` field
    and a first problem in it; it never appears in later statuses or day
    digests. `st_capabilities()` lists `"writer_check"`.
  - `snapshot_db()` names the snapshot `monitoring_YYYY-MM-DD_g<N>.duckdb`
    when `db_meta.writer_generation` is `N`, and writes a
    `<name>.manifest.json` beside it, last. `read_snapshot_manifest()`,
    `verify_snapshot()` and `list_snapshots()` read the manifests.
    `prune_snapshots()` recognises both names, keeps the highest generation of
    each date and deletes a pruned snapshot's manifest with it.
  - The auto-import triggers also hash the folder in `SAMPLETIDY_GATE_WATCH`,
    so a change there alone starts R. `--print-config` prints `WATCH=` last.
  - `replay_archive()` is for a deployment that moves its importer to
    another machine from a snapshot: it lists the archived files the
    database does not know (by asset uuid, byte hash and content hash; only
    UUID-named archive folders, known ones skipped unread) and, with
    `dry_run = FALSE`, copies them into a batch of the input folder
    (`replay-g<N>` by default). The import then takes them under their
    original asset uuids, with no new archive folders. It refuses a batch
    name the configured `inbox_batches` pattern would not see.

* The macOS auto-import trigger (`dev/auto-import.sh`) can send its
  notifications through a command set in `SAMPLETIDY_NOTIFY_COMMAND`
  (called as `<cmd> <title> <message>`), and runs `SAMPLETIDY_NOTIFY_FLUSH`
  once per run (e.g. to resend notifications queued while offline). Both are
  read from the process environment, then R's environ file; `--print-config`
  shows them. Without a command it still shows a desktop notification.

* `ingest_dir()` now calls `prune_snapshots()` after each snapshot it takes, so
  snapshots no longer accumulate: every snapshot from the last `keep_days`
  (default 7) days is kept, then the newest per ISO week for the next
  `keep_weeks` (default 8) weeks, then the newest of each older calendar month. A pruning failure is a warning
  and never fails the ingest or stops the removal step.

* Initial greenfield skeleton. Architecture and design recorded in the
  pinned design issue (#1). Supersedes the legacy `WEM.data` repository.

* `content_fingerprint()` gives OLE/CFB Office files (`.xls`, `.doc`, `.ppt`)
  a content hash that ignores what a cloud file store rewrites after upload
  (the `MsoDataStore` storage, property sets, timestamps). `archive_file()`
  dedupes on it, `archive_settle()` accepts a storage rewrite of any size when
  the content is unchanged, and the inbox removal step accepts a source whose
  content matches the archived copy. All of it needs the new
  `asset.content_hash` and `asset.content_hash_alg` columns and is skipped
  without them. `st_config("content_fingerprinters")` adds fingerprinters.

* When the `checks` function of `inbox_run()` / `import_status()` fails, the
  status now keeps the previous status's flags (so `first_seen` survives the
  outage) and marks them with `flags_carried_forward` and `flags_checked_at`;
  the "checks" flag error says the flags are from the last successful check.
