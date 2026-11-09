# sampleTidy (development version)

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
