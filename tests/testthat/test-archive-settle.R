# Settling archive files that the file store rewrites after archiving.
#
# WIP skeleton: header and seams being written; tests follow.
#
# Seams (specified here; none existed):
#   * `.st_now()` (R/, returns Sys.time()) - the clock for the settle pass and
#     the inbox-source hold. ingest_dir() tests mock it with
#     local_mocked_bindings().
#   * `archive_settle(db = st_config("live_db"), now = .st_now())` - db is a
#     path or an open read-write DBIConnection; returns invisibly a tibble
#     (uuid, old_hash, new_hash), one row per settled asset.
