# PLAN-20 phase 1, P20.4: completed_work(db, since). Spec:
# dev/plans/PLAN-20-phase1-spec.md section P20.4.
#
# Every test builds its projects with DISTINCTIVE uuids/names ("cwp-NNN" /
# "WON-NNN") inside a seed_db() database and asserts on those uuids only:
# the seed carries its own projects (p-0001 'XX1234567' has samples and no review
# item, so it is itself "complete"; p-0003 has no samples) and the tests must not
# depend on that.
#
# Ids are zero-padded so that no uuid is a substring of another project's id
# (rule (d) matches uuids as plain substrings).

# ---- builders --------------------------------------------------------------------------

cw_db <- function(env = parent.frame()) {
  seed_db(dir = withr::local_tempdir(.local_envir = env))
}

cw_exec <- function(con, sql, ...) DBI::dbExecute(con, sql, params = list(...))

# A project with ONE sample, ONE analysis, ONE asset, two ingest_file rows (one
# tied to the asset, one tied only by work_order) and three change_log rows (two
# that wrote data into the project, one on a table that does not count).
cw_project <- function(con, id, name = paste0("WON-", sub("^cwp-", "", id)), samples = 1L,
                       date_start = "2026-10-10 00:00:00", date_end = "2026-10-11 00:00:00",
                       uuid_parent = NA_character_, uuid_root = NA_character_,
                       type = "Work order", site = "B", extras = TRUE) {
  ds <- if (is.na(date_start)) "NULL" else sprintf("TIMESTAMP '%s'", date_start)
  de <- if (is.na(date_end)) "NULL" else sprintf("TIMESTAMP '%s'", date_end)
  DBI::dbExecute(con, sprintf(
    "INSERT INTO project (uuid, name, type, site, date_start, date_end, uuid_parent, uuid_root)
     VALUES (?, ?, ?, ?, %s, %s, ?, ?)", ds, de),
    params = list(id, name, type, site, uuid_parent, uuid_root))
  ids <- list(uuid = id, name = name, sample = NA_character_, analysis = NA_character_,
              asset = NA_character_)
  for (i in seq_len(samples)) {
    su <- paste0(id, "-s", i)
    DBI::dbExecute(con, sprintf(
      "INSERT INTO \"sample\" (uuid, uuid_feature_alias, uuid_project, date, datetime)
       VALUES (?, 'fa-0001', ?, TIMESTAMP '2026-10-10 00:00:00', TIMESTAMP '2026-10-10 0%d:00:00')", i),
      params = list(su, id))
  }
  if (samples >= 1L && extras) {
    ids$sample <- paste0(id, "-s1")
    ids$analysis <- paste0(id, "-a1")
    ids$asset <- paste0(id, "-as1")
    ids$h_asset <- paste0("h-", id, "-asset")
    ids$h_if_asset <- paste0("h-", id, "-ifa")
    ids$h_if_wo <- paste0("h-", id, "-ifw")
    ids$h_cl_s <- paste0("h-", id, "-cls")
    ids$h_cl_a <- paste0("h-", id, "-cla")
    ids$h_cl_wrong <- paste0("h-", id, "-clx")
    cw_exec(con, "INSERT INTO analysis (uuid, uuid_sample, uuid_lab, value, quantified)
                  VALUES (?, ?, 'lm-0001', 7.0, TRUE)", ids$analysis, ids$sample)
    cw_exec(con, "INSERT INTO asset (uuid, uuid_project, filename, hash, file_format, type)
                  VALUES (?, ?, ?, ?, 'csv', 'raw')",
            ids$asset, id, paste0(id, ".csv"), ids$h_asset)
    cw_exec(con, "INSERT INTO ingest_file (hash, filename, state, uuid_asset)
                  VALUES (?, 'f.csv', 'archived', ?)", ids$h_if_asset, ids$asset)
    cw_exec(con, "INSERT INTO ingest_file (hash, filename, state, work_order)
                  VALUES (?, 'g.csv', 'archived', ?)", ids$h_if_wo, name)
    cl <- function(n, tbl, row, hash) {
      cw_exec(con, "INSERT INTO change_log (uuid, \"at\", actor, action, tbl, uuid_row, source_hash)
                    VALUES (?, TIMESTAMP '2026-10-10 00:00:00', 'ingest_dir', 'insert', ?, ?, ?)",
              paste0(id, "-cl", n), tbl, row, hash)
    }
    cl(1, "sample", ids$sample, ids$h_cl_s)
    cl(2, "analysis", ids$analysis, ids$h_cl_a)
    # a hash logged against some OTHER table (here 'feature', pointing at this
    # sample's uuid) does not mean the file wrote data into the project
    cl(3, "feature", ids$sample, ids$h_cl_wrong)
  }
  ids
}

cw_item <- function(con, uuid, kind = "unknown_analyte", subkind = NA_character_,
                    work_order = NA_character_, source_hash = NA_character_,
                    payload = NA_character_, status = "open",
                    uuid_target = NA_character_, uuid_existing = NA_character_,
                    uuid_incoming = NA_character_, uuid_alias = NA_character_) {
  cw_exec(con, "INSERT INTO review_queue
                  (uuid, created_at, kind, subkind, work_order, source_hash, payload, status,
                   uuid_target, uuid_existing, uuid_incoming, uuid_alias)
                VALUES (?, TIMESTAMP '2026-10-10 00:00:00', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
          uuid, kind, subkind, work_order, source_hash, payload, status,
          uuid_target, uuid_existing, uuid_incoming, uuid_alias)
}

# Build one project per case, give it one review item built by `mk(ids)`
# (a list of cw_item() arguments), return list(db, results = id -> project uuid).
cw_cases <- function(cases, env = parent.frame()) {
  db <- cw_db(env)
  con <- seed_con(db)
  proj <- character(0)
  for (i in seq_along(cases)) {
    id <- sprintf("cwp-%03d", i)
    ids <- cw_project(con, id)
    proj[[names(cases)[[i]]]] <- id
    args <- cases[[i]](ids)
    do.call(cw_item, c(list(con = con, uuid = paste0("item-", id)), args))
  }
  # a control with nothing against it
  cw_project(con, "cwp-900")
  DBI::dbDisconnect(con, shutdown = TRUE)
  list(db = db, proj = proj)
}

cw_check <- function(x, blocked) {
  got <- completed_work(x$db)$uuid
  expect_true("cwp-900" %in% got, info = "control project")
  for (nm in names(x$proj)) {
    if (blocked) {
      expect_false(x$proj[[nm]] %in% got, info = paste("should block:", nm))
    } else {
      expect_true(x$proj[[nm]] %in% got, info = paste("should NOT block:", nm))
    }
  }
}

# ---- what blocks -----------------------------------------------------------------------

test_that("P20.4 rule (a): an open item whose work_order is the project's name blocks it", {
  x <- cw_cases(list(
    a_work_order = function(i) list(work_order = i$name)
  ))
  cw_check(x, blocked = TRUE)
})

test_that("P20.4 rule (b): any of uuid_target/existing/incoming/alias equal to the project, a sample, an analysis or an asset uuid blocks", {
  cases <- list()
  for (col in c("uuid_target", "uuid_existing", "uuid_incoming", "uuid_alias")) {
    for (what in c("uuid", "sample", "analysis", "asset")) {
      local({
        col <- col
        what <- what
        cases[[paste(col, "=", what)]] <<- function(i) stats::setNames(list(i[[what]]), col)
      })
    }
  }
  expect_length(cases, 16)
  cw_check(cw_cases(cases), blocked = TRUE)
})

test_that("P20.4 rule (c): source_hash equal to an asset hash, an ingest_file hash (by uuid_asset or by work_order) or a sample/analysis change_log source_hash blocks", {
  x <- cw_cases(list(
    asset_hash = function(i) list(source_hash = i$h_asset),
    ingest_file_via_asset = function(i) list(source_hash = i$h_if_asset),
    ingest_file_via_work_order = function(i) list(source_hash = i$h_if_wo),
    change_log_sample = function(i) list(source_hash = i$h_cl_s),
    change_log_analysis = function(i) list(source_hash = i$h_cl_a)
  ))
  cw_check(x, blocked = TRUE)
})

test_that("P20.4 rule (d): a payload holding the name as a JSON string, or the project/sample/asset uuid as a substring, blocks", {
  x <- cw_cases(list(
    payload_name = function(i) list(payload = sprintf('{"wo":"%s","n_rows":1}', i$name)),
    payload_name_in_array = function(i) list(payload = sprintf('["x","%s"]', i$name)),
    payload_project_uuid = function(i) list(payload = sprintf('{"u":"%s"}', i$uuid)),
    payload_sample_uuid = function(i) list(payload = sprintf('{"u":"%s"}', i$sample)),
    payload_asset_uuid = function(i) list(payload = sprintf('{"u":"%s"}', i$asset)),
    payload_uuid_unquoted = function(i) list(payload = sprintf("see %s here", i$uuid))
  ))
  cw_check(x, blocked = TRUE)
})

test_that("P20.4: items that do not reference the project do not block it", {
  x <- cw_cases(list(
    other_work_order = function(i) list(work_order = "SOMETHING-ELSE"),
    nothing_at_all = function(i) list(),
    # name only as a fragment of a longer / prefixed JSON string: not the string
    payload_longer_name = function(i) list(payload = sprintf('{"wo":"%s-extra"}', i$name)),
    payload_prefixed_name = function(i) list(payload = sprintf('{"wo":"x%s"}', i$name)),
    # a hash logged against a table other than sample/analysis
    change_log_wrong_table = function(i) list(source_hash = i$h_cl_wrong),
    unknown_hash = function(i) list(source_hash = "h-no-such-file"),
    unknown_uuid_columns = function(i) list(uuid_target = "nope-1", uuid_existing = "nope-2",
                                            uuid_incoming = "nope-3", uuid_alias = "nope-4")
  ))
  cw_check(x, blocked = FALSE)
})

test_that("P20.4: resolved (any non-open) items do not block, however they reference the project", {
  x <- cw_cases(list(
    resolved_work_order = function(i) list(work_order = i$name, status = "resolved"),
    closed_work_order = function(i) list(work_order = i$name, status = "closed"),
    resolved_uuid = function(i) list(uuid_target = i$sample, status = "resolved"),
    resolved_hash = function(i) list(source_hash = i$h_asset, status = "resolved"),
    resolved_payload = function(i) list(payload = sprintf('{"wo":"%s"}', i$name), status = "resolved")
  ))
  cw_check(x, blocked = FALSE)
})

test_that("P20.4: an item with a NULL status counts as open (COALESCE(status, 'open'))", {
  x <- cw_cases(list(
    null_status_work_order = function(i) list(work_order = i$name, status = NA_character_)
  ))
  cw_check(x, blocked = TRUE)
})

test_that("P20.4: self_precedence_note items (as kind or as subkind) are non-blocking notes and do not block", {
  x <- cw_cases(list(
    note_kind = function(i) list(kind = "self_precedence_note", work_order = i$name),
    note_kind_uuid = function(i) list(kind = "self_precedence_note", uuid_target = i$sample),
    note_subkind = function(i) list(kind = "unknown_analyte", subkind = "self_precedence_note",
                                    work_order = i$name),
    note_subkind_hash = function(i) list(kind = "other", subkind = "self_precedence_note",
                                         source_hash = i$h_asset)
  ))
  cw_check(x, blocked = FALSE)
})

test_that("P20.4: a different kind/subkind that merely resembles the note names still blocks", {
  x <- cw_cases(list(
    other_subkind = function(i) list(kind = "other", subkind = "foreign_work_order", work_order = i$name)
  ))
  cw_check(x, blocked = TRUE)
})

test_that("P20.4 rule (d): the name is matched as a plain substring, with no wildcards", {
  db <- cw_db()
  con <- seed_con(db)
  # '_' and '%' are LIKE wildcards: a LIKE-based matcher would let these through
  cw_project(con, "cwp-001", name = "WO_P%Q")
  cw_item(con, "i1", payload = '{"wo":"WOxPzzQ"}')       # would match WO_P%Q as a LIKE pattern
  cw_project(con, "cwp-002", name = "WO_P%Q-literal")
  cw_item(con, "i2", payload = '{"wo":"WO_P%Q-literal"}') # the literal string: blocks cwp-002
  cw_project(con, "cwp-003", name = "WO.A+B")
  cw_item(con, "i3", payload = '{"wo":"WOxAAB"}')        # would match as a regex
  DBI::dbDisconnect(con, shutdown = TRUE)
  got <- completed_work(db)$uuid
  expect_true("cwp-001" %in% got)
  expect_false("cwp-002" %in% got)
  expect_true("cwp-003" %in% got)
})

test_that("P20.4: NULL never matches NULL (a NULL work order / hash / name in the item or the project)", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", name = NA_character_)
  cw_exec(con, "INSERT INTO asset (uuid, uuid_project, filename, hash) VALUES ('cwp-001-nh', 'cwp-001', NULL, NULL)")
  cw_item(con, "i1")                                     # every reference column NULL
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_true("cwp-001" %in% completed_work(db)$uuid)
})

test_that("P20.4: references on a parent or child project do not block the project (direct references only)", {
  db <- cw_db()
  con <- seed_con(db)
  par <- cw_project(con, "cwp-001")
  kid <- cw_project(con, "cwp-002", uuid_parent = "cwp-001", uuid_root = "cwp-001")
  # an item against the PARENT blocks the parent only
  cw_item(con, "i1", work_order = par$name)
  # an item against the CHILD's sample blocks the child only
  par2 <- cw_project(con, "cwp-003")
  kid2 <- cw_project(con, "cwp-004", uuid_parent = "cwp-003", uuid_root = "cwp-003")
  cw_item(con, "i2", uuid_target = kid2$sample)
  # an item holding the parent's uuid does not reach the child either
  par3 <- cw_project(con, "cwp-005")
  kid3 <- cw_project(con, "cwp-006", uuid_parent = "cwp-005", uuid_root = "cwp-005")
  cw_item(con, "i3", uuid_target = par3$uuid)
  DBI::dbDisconnect(con, shutdown = TRUE)
  got <- completed_work(db)$uuid
  expect_false("cwp-001" %in% got)
  expect_true("cwp-002" %in% got)
  expect_true("cwp-003" %in% got)
  expect_false("cwp-004" %in% got)
  expect_false("cwp-005" %in% got)
  expect_true("cwp-006" %in% got)
})

test_that("P20.4: a project with no samples is never returned, whatever else it has", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", samples = 0L)
  cw_exec(con, "INSERT INTO asset (uuid, uuid_project, filename, hash) VALUES ('cwp-001-as1', 'cwp-001', 'x.csv', 'h-x')")
  cw_project(con, "cwp-002")                             # has samples: returned
  DBI::dbDisconnect(con, shutdown = TRUE)
  got <- completed_work(db)$uuid
  expect_false("cwp-001" %in% got)
  expect_true("cwp-002" %in% got)
  expect_false("p-0003" %in% got)                         # the seed's sample-less project
})

test_that("P20.4: a project with one blocking item among several stays blocked; resolving the last one frees it", {
  db <- cw_db()
  con <- seed_con(db)
  p <- cw_project(con, "cwp-001")
  cw_item(con, "i1", work_order = p$name, status = "resolved")
  cw_item(con, "i2", uuid_target = p$asset)
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_false("cwp-001" %in% completed_work(db)$uuid)
  con <- seed_con(db)
  DBI::dbExecute(con, "UPDATE review_queue SET status = 'resolved' WHERE uuid = 'i2'")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_true("cwp-001" %in% completed_work(db)$uuid)
})

# ---- result shape ----------------------------------------------------------------------

test_that("P20.4: the result is a tibble with the pinned columns, in order, with the pinned types", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001")
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  expect_s3_class(cw, "tbl_df")
  expect_identical(names(cw), c("uuid", "name", "type", "site", "date_start", "date_end",
                                "uuid_root", "root_name", "assets"))
  for (col in c("uuid", "name", "type", "site", "uuid_root", "root_name")) {
    expect_type(cw[[col]], "character")
  }
  expect_s3_class(cw$date_start, "POSIXct")
  expect_s3_class(cw$date_end, "POSIXct")
  expect_type(cw$assets, "list")
  row <- cw[cw$uuid == "cwp-001", ]
  expect_identical(row$name, "WON-001")
  expect_identical(row$type, "Work order")
  expect_identical(row$site, "B")
  expect_equal(as.numeric(row$date_start), as.numeric(as.POSIXct("2026-10-10 00:00:00", tz = "UTC")))
  expect_equal(as.numeric(row$date_end), as.numeric(as.POSIXct("2026-10-11 00:00:00", tz = "UTC")))
})

test_that("P20.4: uuid_root is COALESCE(uuid_root, uuid); root_name is the root project's name, NA when there is none", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", name = "WO-ROOT")                              # no uuid_root: its own root
  cw_project(con, "cwp-002", name = "WO-KID", uuid_parent = "cwp-001", uuid_root = "cwp-001")
  cw_project(con, "cwp-003", name = "WO-ORPHAN", uuid_root = "cwp-gone")   # root row absent
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  r1 <- cw[cw$uuid == "cwp-001", ]
  r2 <- cw[cw$uuid == "cwp-002", ]
  r3 <- cw[cw$uuid == "cwp-003", ]
  expect_identical(r1$uuid_root, "cwp-001")
  expect_identical(r1$root_name, "WO-ROOT")
  expect_identical(r2$uuid_root, "cwp-001")
  expect_identical(r2$root_name, "WO-ROOT")
  expect_identical(r3$uuid_root, "cwp-gone")
  expect_true(is.na(r3$root_name))
  expect_type(r3$root_name, "character")
})

test_that("P20.4: the seed's own sampled project is returned with its own root (sanity of the harness)", {
  cw <- completed_work(cw_db())
  r <- cw[cw$uuid == "p-0001", ]
  expect_identical(nrow(r), 1L)
  expect_identical(r$uuid_root, "p-0001")
  expect_identical(r$root_name, "XX1234567")
})

test_that("P20.4: ordered by date_start, then name, then uuid, NULLs last", {
  db <- cw_db()
  con <- seed_con(db)
  # inserted in scrambled order
  cw_project(con, "cwp-d", name = "A0", date_start = NA_character_, date_end = NA_character_)
  cw_project(con, "cwp-e2", name = "B-name", date_start = "2026-01-01 00:00:00")
  cw_project(con, "cwp-f", name = NA_character_, date_start = "2026-01-01 00:00:00")
  cw_project(con, "cwp-c", name = "Z", date_start = "2025-01-01 00:00:00")
  cw_project(con, "cwp-e1", name = "B-name", date_start = "2026-01-01 00:00:00")
  cw_project(con, "cwp-b", name = "A-name", date_start = "2026-01-01 00:00:00")
  DBI::dbDisconnect(con, shutdown = TRUE)
  got <- completed_work(db)$uuid
  mine <- got[got %in% c("cwp-b", "cwp-c", "cwp-d", "cwp-e1", "cwp-e2", "cwp-f")]
  expect_identical(mine, c("cwp-c", "cwp-b", "cwp-e1", "cwp-e2", "cwp-f", "cwp-d"))
})

# ---- assets column ---------------------------------------------------------------------

test_that("P20.4 assets: one row per asset of the project, with the pinned columns, path = <uuid>/<filename>", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001")
  cw_project(con, "cwp-002")                      # its asset must not leak into cwp-001
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  a <- cw$assets[[which(cw$uuid == "cwp-001")]]
  expect_s3_class(a, "tbl_df")
  expect_identical(names(a), c("uuid", "path", "filename", "hash", "file_format", "type"))
  expect_identical(nrow(a), 1L)
  for (col in names(a)) expect_type(a[[col]], "character")
  expect_identical(a$uuid, "cwp-001-as1")
  expect_identical(a$filename, "cwp-001.csv")
  expect_identical(a$path, "cwp-001-as1/cwp-001.csv")
  expect_identical(a$hash, "h-cwp-001-asset")
  expect_identical(a$file_format, "csv")
  expect_identical(a$type, "raw")
})

test_that("P20.4 assets: ordered by filename then uuid", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", extras = FALSE)
  for (r in list(c("as-c", "b.csv"), c("as-b", "a.csv"), c("as-a", "a.csv"), c("as-d", "c.csv"))) {
    cw_exec(con, "INSERT INTO asset (uuid, uuid_project, filename, hash) VALUES (?, 'cwp-001', ?, ?)",
            r[[1]], r[[2]], paste0("h-", r[[1]]))
  }
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  a <- cw$assets[[which(cw$uuid == "cwp-001")]]
  expect_identical(a$uuid, c("as-a", "as-b", "as-c", "as-d"))
  expect_identical(a$path, c("as-a/a.csv", "as-b/a.csv", "as-c/b.csv", "as-d/c.csv"))
})

test_that("P20.4 assets: a NULL filename gives an NA path; NULL hash/format/type come through as NA", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", extras = FALSE)
  cw_exec(con, "INSERT INTO asset (uuid, uuid_project, filename, hash) VALUES ('as-n', 'cwp-001', NULL, NULL)")
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  a <- cw$assets[[which(cw$uuid == "cwp-001")]]
  expect_identical(nrow(a), 1L)
  expect_identical(a$uuid, "as-n")
  expect_true(is.na(a$path))
  expect_true(is.na(a$filename))
  expect_true(is.na(a$hash))
  expect_true(is.na(a$file_format))
  expect_true(is.na(a$type))
  expect_type(a$path, "character")
})

test_that("P20.4 assets: a project with no assets gets a 0-row tibble with the same six character columns", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001", extras = FALSE)
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  a <- cw$assets[[which(cw$uuid == "cwp-001")]]
  expect_s3_class(a, "tbl_df")
  expect_identical(nrow(a), 0L)
  expect_identical(names(a), c("uuid", "path", "filename", "hash", "file_format", "type"))
  for (col in names(a)) expect_type(a[[col]], "character")
})

# ---- since -----------------------------------------------------------------------------

cw_since_db <- function(env = parent.frame()) {
  db <- cw_db(env)
  con <- seed_con(db)
  cw_project(con, "cwp-end", date_start = "2026-01-01 00:00:00", date_end = "2026-10-11 00:00:00")
  cw_project(con, "cwp-start", date_start = "2026-10-05 00:00:00", date_end = NA_character_)
  cw_project(con, "cwp-none", date_start = NA_character_, date_end = NA_character_)
  cw_project(con, "cwp-old", date_start = "2026-01-01 00:00:00", date_end = "2026-09-01 00:00:00")
  DBI::dbDisconnect(con, shutdown = TRUE)
  db
}

cw_mine <- function(x) x[x %in% c("cwp-end", "cwp-start", "cwp-none", "cwp-old")]

test_that("P20.4 since = NULL returns every complete project, including those with no dates", {
  db <- cw_since_db()
  expect_setequal(cw_mine(completed_work(db)$uuid), c("cwp-end", "cwp-start", "cwp-none", "cwp-old"))
  expect_setequal(cw_mine(completed_work(db, since = NULL)$uuid), c("cwp-end", "cwp-start", "cwp-none", "cwp-old"))
})

test_that("P20.4 since (Date): COALESCE(date_end, date_start) >= midnight UTC; both-NULL projects are excluded", {
  db <- cw_since_db()
  expect_setequal(cw_mine(completed_work(db, since = as.Date("2026-10-06"))$uuid), "cwp-end")
  expect_setequal(cw_mine(completed_work(db, since = as.Date("2026-10-05"))$uuid),
                  c("cwp-end", "cwp-start"))
  # inclusive at the boundary: date_end is exactly 2026-10-11 00:00:00
  expect_setequal(cw_mine(completed_work(db, since = as.Date("2026-10-11"))$uuid), "cwp-end")
  expect_length(cw_mine(completed_work(db, since = as.Date("2026-10-12"))$uuid), 0)
  expect_setequal(cw_mine(completed_work(db, since = as.Date("2020-01-01"))$uuid),
                  c("cwp-end", "cwp-start", "cwp-old"))
})

test_that("P20.4 since (POSIXct): compared as an instant against the UTC timestamps", {
  db <- cw_since_db()
  utc <- function(x) as.POSIXct(x, tz = "UTC")
  expect_setequal(cw_mine(completed_work(db, since = utc("2026-10-11 00:00:00"))$uuid), "cwp-end")
  expect_length(cw_mine(completed_work(db, since = utc("2026-10-11 00:00:01"))$uuid), 0)
  # 11:00 AEDT on 11 Oct 2026 is exactly 00:00 UTC
  syd <- function(x) as.POSIXct(x, tz = "Australia/Sydney")
  expect_setequal(cw_mine(completed_work(db, since = syd("2026-10-11 11:00:00"))$uuid), "cwp-end")
  expect_length(cw_mine(completed_work(db, since = syd("2026-10-11 11:00:01"))$uuid), 0)
})

test_that("P20.4 since: anything other than a length-1 Date or POSIXct aborts with class sampletidy_error", {
  db <- cw_since_db()
  expect_error(completed_work(db, since = "2026-10-06"), class = "sampletidy_error")
  expect_error(completed_work(db, since = 20261006), class = "sampletidy_error")
  expect_error(completed_work(db, since = TRUE), class = "sampletidy_error")
  expect_error(completed_work(db, since = list(as.Date("2026-10-06"))), class = "sampletidy_error")
  expect_error(completed_work(db, since = as.Date(c("2026-10-06", "2026-10-07"))), class = "sampletidy_error")
  expect_error(completed_work(db, since = as.Date(character(0))), class = "sampletidy_error")
})

# ---- db argument -----------------------------------------------------------------------

test_that("P20.4: accepts a path (opened read-only: the file is not modified)", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001")
  DBI::dbDisconnect(con, shutdown = TRUE)
  before <- file_md5(db)
  cw <- completed_work(db)
  expect_true("cwp-001" %in% cw$uuid)
  expect_identical(file_md5(db), before)
  # the path left no open handle behind: a read-write open still works
  con2 <- seed_con(db)
  expect_true(DBI::dbIsValid(con2))
  DBI::dbDisconnect(con2, shutdown = TRUE)
})

test_that("P20.4: accepts an open connection, uses it as is, and leaves it open", {
  db <- cw_db()
  con <- seed_con(db)
  withr::defer(try(DBI::dbDisconnect(con, shutdown = TRUE), silent = TRUE))
  cw_project(con, "cwp-001")
  cw <- completed_work(con)
  expect_true("cwp-001" %in% cw$uuid)
  expect_true(DBI::dbIsValid(con))
  expect_identical(DBI::dbGetQuery(con, "SELECT count(*) AS n FROM project WHERE uuid = 'cwp-001'")$n, 1)
  # sees uncommitted-to-file state of the same connection, and is repeatable
  cw_project(con, "cwp-002")
  expect_true("cwp-002" %in% completed_work(con)$uuid)
  expect_true(DBI::dbIsValid(con))
})

test_that("P20.4: completed_work() is read-only (no change_log rows, no table counts moved)", {
  db <- cw_db()
  con <- seed_con(db)
  cw_project(con, "cwp-001")
  n0 <- vapply(c("project", "sample", "asset", "review_queue", "change_log"), function(t) {
    DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM \"%s\"", t))$n
  }, numeric(1))
  completed_work(con)
  n1 <- vapply(names(n0), function(t) {
    DBI::dbGetQuery(con, sprintf("SELECT count(*) AS n FROM \"%s\"", t))$n
  }, numeric(1))
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_identical(n1, n0)
})

# ---- empty result ----------------------------------------------------------------------

test_that("P20.4: with no complete project the result is a 0-row tibble with the same columns and types", {
  db <- cw_db()
  con <- seed_con(db)
  DBI::dbExecute(con, "DELETE FROM analysis")
  DBI::dbExecute(con, "DELETE FROM \"sample\"")
  DBI::dbDisconnect(con, shutdown = TRUE)
  cw <- completed_work(db)
  expect_s3_class(cw, "tbl_df")
  expect_identical(nrow(cw), 0L)
  expect_identical(names(cw), c("uuid", "name", "type", "site", "date_start", "date_end",
                                "uuid_root", "root_name", "assets"))
  for (col in c("uuid", "name", "type", "site", "uuid_root", "root_name")) {
    expect_type(cw[[col]], "character")
  }
  expect_s3_class(cw$date_start, "POSIXct")
  expect_s3_class(cw$date_end, "POSIXct")
  expect_type(cw$assets, "list")
  expect_length(cw$assets, 0)
})

test_that("P20.4: a since filter that removes everything also yields the 0-row shape", {
  db <- cw_since_db()
  cw <- completed_work(db, since = as.Date("2099-01-01"))
  expect_identical(nrow(cw), 0L)
  expect_identical(names(cw), c("uuid", "name", "type", "site", "date_start", "date_end",
                                "uuid_root", "root_name", "assets"))
  expect_s3_class(cw$date_start, "POSIXct")
  expect_type(cw$assets, "list")
})
