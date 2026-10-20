#!/usr/bin/env Rscript
# =============================================================================
# processed-dedupe.R - find (and, on request, quarantine) duplicate and
# misplaced files in the archive tree `assets/processed/`
# =============================================================================
#
# The filing rule (R/archive.R archive_file()): every ingested source lives at
#   <archive_dir>/<asset uuid>/<original basename>
# with one asset row per content hash (xxHash128, rlang::hash_file()). Anything
# else under processed/ is either a duplicate of an asset's file, an orphan, or
# something Robin has to rule on. Files in unprocessed/ and input/ whose bytes
# are already an asset are duplicates too.
#
# Usage
#   Rscript dev/processed-dedupe.R [--db PATH] [--root ASSETS_DIR]
#                                  [--plan-out CSV] [--mirror DIR]
#                                  [--extra-assets DB2] [--extra-archive DIR]
#                                  [--known-hashes CSV] [--merged CSV]
#                                  [--date YYYYMMDD] [--post-import]
#       DRY RUN (the default). Opens the DB read-only, lists the tree with
#       find/stat only, writes the plan CSV and an undo CSV next to it
#       (<plan>-undo.csv), prints a summary. Changes nothing under --root.
#   Rscript dev/processed-dedupe.R --apply PLAN.csv [--db PATH] [--root DIR]
#       Executes ONLY the plan rows whose action starts with "quarantine-":
#       each is MOVED (file.rename, never copied, never deleted) to
#       <root>/_dedupe_quarantine/<YYYYMMDD>/<original relpath>. Appends every
#       outcome to <plan>-apply-log.csv. Safe to re-run: rows already moved
#       are skipped.
#   Rscript dev/processed-dedupe.R --undo UNDO.csv
#       Moves quarantined paths back (only rows whose quarantine copy exists
#       and whose original path is free). Also idempotent.
#   Rscript dev/processed-dedupe.R --post-import --db DB --root DIR --mirror SRC
#                                  [--merged CSV] --plan-out CSV
#       For the end of a corpus import (after its dupcheck has passed). Builds
#       the plan FRESH against the post-import DB and tree (exactly as the dry
#       run does), writes it, then applies only the import-dependent subset:
#       quarantine-duplicate rows under unprocessed/ or input/, the own files of
#       rows a --merged migration merged away (duplicates) or retired (orphans),
#       plus the uuid dirs those empty. That
#       subset is written as <plan>-post-import.csv (+ -undo.csv) and applied
#       with the same per-row re-checks as --apply. Everything else in the plan
#       is left for review. Never run it on a stale CSV: it has no CSV input.
#
# Options
#   --db PATH          the DuckDB holding `asset` (always opened read_only).
#                      Default: the live DB.
#   --root DIR         the `assets` directory (holding processed/, unprocessed/,
#                      input/). Default: dirname($SAMPLETIDY_ARCHIVE_DIR).
#                      Point it at a scratch tree to test.
#   --plan-out CSV     default ./processed-dedupe-plan-<date>.csv. Refused if
#                      it is inside --root (the dry run never writes there).
#   --mirror DIR       optional local copy of the tree, same relative paths
#                      (e.g. scratchpad/2026-10-19-corpus/src). A non-local
#                      file whose mirror copy has the same size is hashed from
#                      the mirror (hash_basis = "mirror").
#   --extra-assets DB2 simulation: asset rows of DB2 whose uuid is not in --db
#                      are treated as if they existed at processed/<uuid>/<file>
#                      (e.g. a rehearsal's after.duckdb -> the post-import
#                      plan). Never use this plan with --apply before the
#                      import has really run: apply re-checks that every
#                      canonical copy exists and is an asset of --db.
#   --extra-archive D  where the rehearsal archived those extra assets; only
#                      used to stat their sizes (fallback ingest_file.size).
#   --known-hashes CSV hashes computed earlier by reading OneDrive files
#                      (columns relpath, size, mtime, hash; mtime = epoch
#                      seconds). Used for a non-local file only while its size
#                      AND mtime still equal the recorded ones (hash_basis
#                      "read"). Lets a re-run reuse a one-off hydration.
#   --merged CSV[,CSV] asset rows a migration merges away, deletes or rules on
#                      (columns uuid, filename, hash, merged_into; optional
#                      action = merge | retire | keep, default merge when
#                      merged_into is set, else retire; optional migration,
#                      default 057). E.g. 057's and 061's -INPUT.csv, comma-
#                      separated. Before the migration is applied the listed
#                      rows are still assets and are reported "keep" (pending).
#                      Once a merge/retire row is gone, the file at
#                      processed/<uuid>/<filename> is a byte duplicate of the
#                      kept asset (merge; hash_basis "merged_asset": the deleted
#                      row's recorded hash, unless a local/mirror hash is
#                      available, which must then agree) or an orphan (retire).
#                      "keep" rows are legacy duplicate-hash rows a ruling keeps
#                      as separate rows: reported "keep", not "ask-robin".
#   --date YYYYMMDD    the quarantine folder date (default: today).
#   --post-import      see above.
#   --test-nonlocal RE test only: relpaths matching RE are treated as not local.
#
# Hashing: a file under --root is hashed ONLY if it is local (stat blocks > 0,
# or size 0). OneDrive Files-On-Demand placeholders have blocks = 0 and reading
# them downloads them, so they are never read: such a file is identified by
# its mirror copy, a --known-hashes record, the DB hash when it is an asset's
# own file, or name + size. `hash_basis` says which:
#   local      hashed from the file itself
#   mirror     hashed from the --mirror copy (same relpath, same size, same
#              mtime - the mirror is a cp -p copy of the tree)
#   read       a --known-hashes record (same size and mtime)
#   db_asset   asset.hash of the asset whose own file this is
#   merged_asset  asset.hash of the 057-merged row whose own file this was
#   extra_asset  asset.hash of a simulated (--extra-assets) asset
#   name_size  no hash; matched on basename + size only. NEVER enough to
#              quarantine a file as a duplicate (Robin, 2026-10-20).
#
# A duplicate is only quarantined once its canonical copy is verified: the
# canonical asset's own file exists in the tree with the same size, and, when
# that file is local (or has a mirror copy of the same size and mtime), its
# hash equals asset.hash.
#
# Plan actions
#   keep                          an asset's own file; _emails content that is
#                                 not a duplicate; unprocessed/ files not yet
#                                 ingested; Finder .DS_Store
#   quarantine-duplicate          a file outside its asset's <uuid>/<filename>
#                                 whose hash equals an asset's, and whose
#                                 canonical copy verifies
#   quarantine-orphan             a file in processed/ (outside _emails) that no
#                                 asset row references and that is not a
#                                 verified duplicate (Robin, 2026-10-20:
#                                 orphans are quarantined; reversible)
#   quarantine-orphan-empty-dir   a processed/<uuid>/ dir with no asset row that
#                                 is empty, or will be once its files move
#   ask-robin                     anything needing a ruling: legacy duplicate
#                                 asset rows not covered by --merged, _emails
#                                 byte duplicates, missing asset files
# =============================================================================

suppressPackageStartupMessages({
  library(DBI)
  library(duckdb)
})

QDIR <- "_dedupe_quarantine"
UUID_RE <- "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
LIVE_DB <- file.path(path.expand("~"), "Library", "Application Support",
                     "org.R-project.R", "R", "sampleTidy", "monitoring.duckdb")
BYTE_BASES <- c("local", "mirror", "read", "db_asset", "merged_asset", "extra_asset")

# ---- arguments ---------------------------------------------------------------
parse_args <- function(a) {
  flags <- c("--db", "--root", "--plan-out", "--apply", "--undo", "--mirror",
             "--extra-assets", "--extra-archive", "--date", "--test-nonlocal",
             "--known-hashes", "--merged")
  out <- list()
  i <- 1
  while (i <= length(a)) {
    k <- a[[i]]
    if (k %in% c("-h", "--help")) { out$help <- TRUE; i <- i + 1; next }
    if (k == "--post-import") { out[["post-import"]] <- TRUE; i <- i + 1; next }
    if (grepl("^--[a-z-]+=", k)) {
      v <- sub("^--[a-z-]+=", "", k); k <- sub("=.*$", "", k)
    } else {
      if (i == length(a)) stop("missing value for ", k, call. = FALSE)
      v <- a[[i + 1]]; i <- i + 1
    }
    if (!k %in% flags) stop("unknown option ", k, call. = FALSE)
    out[[sub("^--", "", k)]] <- v
    i <- i + 1
  }
  out
}

default_root <- function() {
  ad <- Sys.getenv("SAMPLETIDY_ARCHIVE_DIR")
  if (nzchar(ad) && basename(ad) == "processed") return(dirname(ad))
  file.path(path.expand("~"), "Library", "CloudStorage",
            "OneDrive-BlueMountainsCityCouncil", "Sharepoint",
            "waste_data - Environmental monitoring", "assets")
}

norm <- function(p) normalizePath(p, mustWork = FALSE)
# absolute, symlink-resolved path, also for a path that does not exist yet
abs_path <- function(p) {
  p <- path.expand(p)
  if (!startsWith(p, "/")) p <- file.path(getwd(), p)
  d <- p; rest <- character()
  while (!file.exists(d) && d != dirname(d)) { rest <- c(basename(d), rest); d <- dirname(d) }
  do.call(file.path, as.list(c(normalizePath(d), rest)))
}
is_inside <- function(p, dir) {
  p <- abs_path(p); dir <- abs_path(dir)
  identical(p, dir) || startsWith(p, paste0(dir, "/"))
}

# ---- DB ----------------------------------------------------------------------
read_assets <- function(db) {
  if (!file.exists(db)) stop("DB not found: ", db, call. = FALSE)
  con <- dbConnect(duckdb(), db, read_only = TRUE)
  on.exit(dbDisconnect(con, shutdown = TRUE))
  a <- dbGetQuery(con, "SELECT uuid, filename, hash FROM asset")
  ifs <- if ("ingest_file" %in% dbListTables(con))
    dbGetQuery(con, "SELECT hash, max(size) AS size FROM ingest_file GROUP BY hash")
  else data.frame(hash = character(), size = numeric())
  list(asset = a, ingest_size = ifs)
}

# ---- tree listing (find + stat only: never reads file contents) -------------
list_tree <- function(root) {
  root <- norm(root)
  out <- suppressWarnings(system2(
    "find",
    c(shQuote(root), "-mindepth", "1",
      "-path", shQuote(file.path(root, QDIR)), "-prune", "-o",
      "-exec", "stat", "-f", shQuote("%b\t%z\t%m\t%HT\t%N"), "{}", "+"),
    stdout = TRUE))
  if (!is.null(attr(out, "status")) && attr(out, "status") != 0)
    stop("find/stat failed under ", root, call. = FALSE)
  if (!length(out))
    return(data.frame(relpath = character(), kind = character(),
                      size = numeric(), blocks = numeric(), mtime = numeric()))
  p <- strsplit(out, "\t", fixed = TRUE)
  ok <- lengths(p) >= 5
  if (any(!ok)) stop("unparseable stat line: ", out[!ok][1], call. = FALSE)
  path <- vapply(p, function(x) paste(x[-(1:4)], collapse = "\t"), "")
  type <- vapply(p, `[`, "", 4)
  data.frame(
    relpath = substring(path, nchar(root) + 2),
    kind = ifelse(type == "Directory", "dir",
                  ifelse(type == "Regular File", "file", "other")),
    size = as.numeric(vapply(p, `[`, "", 2)),
    blocks = as.numeric(vapply(p, `[`, "", 1)),
    mtime = as.numeric(vapply(p, `[`, "", 3)),
    stringsAsFactors = FALSE
  )
}

blocks_of <- function(path) {
  b <- suppressWarnings(system2("stat", c("-f", "%b", shQuote(path)), stdout = TRUE))
  as.numeric(b[1])
}
mtime_of <- function(path) {
  b <- suppressWarnings(system2("stat", c("-f", "%m", shQuote(path)), stdout = TRUE))
  as.numeric(b[1])
}
# bytes this run read from files under --root (local files only)
READ <- new.env(); READ$n <- 0; READ$bytes <- 0
hash_root_file <- function(path) {
  READ$n <- READ$n + 1; READ$bytes <- READ$bytes + file.info(path)$size
  rlang::hash_file(path)
}
is_local <- function(blocks, size) !is.na(blocks) & (blocks > 0 | size == 0)
# test hook: --test-nonlocal REGEX makes matching relpaths behave like OneDrive
# placeholders (never hashed), so the name+size path can be tested locally
TEST_NONLOCAL <- NULL
test_nonlocal <- function(rel) !is.null(TEST_NONLOCAL) && grepl(TEST_NONLOCAL, rel)

# ---- plan --------------------------------------------------------------------
make_plan <- function(o) {
  root <- norm(o$root)
  date <- o$date
  db <- read_assets(o$db)
  A <- db$asset
  A$src <- rep("db", nrow(A))
  if (!is.null(o[["extra-assets"]])) {
    x <- read_assets(o[["extra-assets"]])
    E <- x$asset[!x$asset$uuid %in% A$uuid, , drop = FALSE]
    E$src <- rep("extra", nrow(E))
    A <- rbind(A, E)
    extra_ingest_size <- x$ingest_size
  }
  A$filename[is.na(A$filename)] <- ""
  A$canonical <- file.path("processed", A$uuid, A$filename)
  A$key <- paste(A$uuid, A$filename, sep = "/")

  tr <- list_tree(root)
  F <- tr[tr$kind == "file", , drop = FALSE]
  D <- tr[tr$kind == "dir", , drop = FALSE]
  O <- tr[tr$kind == "other", , drop = FALSE]

  # asset sizes: own file in the tree; extra assets from --extra-archive or ingest_file
  A$size <- F$size[match(A$canonical, F$relpath)]
  if (any(A$src == "extra")) {
    ie <- A$src == "extra"
    if (!is.null(o[["extra-archive"]])) {
      p <- file.path(o[["extra-archive"]], A$uuid[ie], A$filename[ie])
      A$size[ie] <- file.info(p)$size
    }
    miss <- ie & is.na(A$size)
    A$size[miss] <- extra_ingest_size$size[match(A$hash[miss], extra_ingest_size$hash)]
  }
  dup_hash <- unique(A$hash[duplicated(A$hash) & !is.na(A$hash)])

  # mirror hashes (local copy; reading it never touches OneDrive). The mirror is
  # a cp -p copy, so a copy counts only while its size AND mtime equal the tree's.
  mirror <- o$mirror
  mirror_hash <- function(rel, size, mtime = NA) {
    if (is.null(mirror)) return(NA_character_)
    m <- file.path(mirror, rel)
    if (!file.exists(m) || is.na(size)) return(NA_character_)
    fi <- file.info(m)
    if (!identical(as.numeric(fi$size), as.numeric(size))) return(NA_character_)
    if (!is.na(mtime) && !identical(floor(as.numeric(fi$mtime)), floor(as.numeric(mtime)))) return(NA_character_)
    rlang::hash_file(m)
  }
  # --known-hashes: earlier reads of OneDrive files, valid while size + mtime hold
  known <- if (!is.null(o[["known-hashes"]])) read_csv_chr(o[["known-hashes"]]) else
    data.frame(relpath = character(), size = character(), mtime = character(), hash = character())
  known_hash <- function(rel, size, mtime) {
    k <- match(rel, known$relpath)
    if (is.na(k) || is.na(size) || is.na(mtime)) return(NA_character_)
    if (as.numeric(known$size[k]) != size || floor(as.numeric(known$mtime[k])) != floor(mtime)) return(NA_character_)
    known$hash[k]
  }
  # --merged: rows a migration merges away / retires / keeps (merge and retire
  # are only effective once the asset row is gone)
  merged <- read_merged(o$merged)
  merged_gone <- merged[merged$action != "keep" & !merged$uuid %in% A$uuid, , drop = FALSE]
  merged_gone_key <- paste(merged_gone$uuid, merged_gone$filename, sep = "/")

  # canonical verification, cached per asset row: "" = verified, else why not
  Fidx <- stats::setNames(seq_len(nrow(F)), F$relpath)
  canon_cache <- character()
  canon_problem <- function(j, sz) {
    if (!is.na(A$size[j]) && !is.na(sz) && A$size[j] != sz)
      return(sprintf("canonical %s is %s bytes, this file %s", A$canonical[j], A$size[j], sz))
    if (A$src[j] != "db") return(if (is.na(A$size[j])) "simulated canonical has no known size" else "")
    k <- Fidx[A$canonical[j]]
    if (is.na(k)) return(sprintf("canonical %s is missing from the tree", A$canonical[j]))
    key <- A$uuid[j]
    if (!is.na(canon_cache[key])) return(canon_cache[[key]])
    rel <- F$relpath[k]
    h <- if (is_local(F$blocks[k], F$size[k]) && !test_nonlocal(rel)) hash_root_file(file.path(root, rel)) else
      mirror_hash(rel, F$size[k], F$mtime[k])
    res <- if (!is.na(h) && !identical(h, A$hash[j]))
      sprintf("canonical %s bytes no longer match asset.hash (now %s)", A$canonical[j], h) else ""
    canon_cache[key] <<- res
    res
  }

  # F.18 backup (annotation only)
  f18_file <- file.path(script_dir(), "asset-rows-deleted-2026-07-23.csv")
  f18 <- if (file.exists(f18_file)) utils::read.csv(f18_file, colClasses = "character")$uuid else character()

  parts <- strsplit(F$relpath, "/", fixed = TRUE)
  top <- vapply(parts, `[`, "", 1)
  n <- lengths(parts)
  second <- vapply(parts, function(x) if (length(x) >= 2) x[2] else "", "")
  loc <- ifelse(top == "processed" & n == 2, "root",
         ifelse(top == "processed" & second == "_emails", "emails",
         ifelse(top == "processed" & n == 3 & grepl(UUID_RE, second), "uuid",
         ifelse(top == "processed", "other",
         ifelse(top %in% c("unprocessed", "input"), "staging", "outside")))))
  dir_uuid <- ifelse(loc == "uuid", second, "")
  base <- basename(F$relpath)
  own_key <- paste(dir_uuid, base, sep = "/")
  where_txt <- function(i) switch(loc[i],
    uuid = if (dir_uuid[i] %in% A$uuid) " (extra file in an asset dir)" else
      paste0(" (orphan dir", if (dir_uuid[i] %in% f18) ", row deleted by F.18" else "",
             if (own_key[i] %in% merged_gone_key) sprintf(", row %s by %s",
               ifelse(merged_gone$action[match(own_key[i], merged_gone_key)] == "merge", "merged away", "deleted"),
               merged_gone$migration[match(own_key[i], merged_gone_key)]) else "", ")"),
    root = " (loose root file)", staging = " (already ingested)", other = " (unexpected location)", "")
  orphan_txt <- function(i) paste0("not referenced by any asset row", where_txt(i))

  rows <- vector("list", nrow(F))
  for (i in seq_len(nrow(F))) {
    rel <- F$relpath[i]; sz <- F$size[i]; mt <- F$mtime[i]
    local <- is_local(F$blocks[i], sz) && !test_nonlocal(rel)
    r <- list(relpath = rel, kind = "file", size = sz, mtime = mt, local = local,
              hash = NA_character_, hash_basis = NA_character_,
              asset_uuid = NA_character_, canonical_path = NA_character_,
              action = NA_character_, reason = NA_character_)
    hash_now <- function() {
      if (local) return(c(hash_root_file(file.path(root, rel)), "local"))
      h <- mirror_hash(rel, sz, mt)
      if (!is.na(h)) return(c(h, "mirror"))
      h <- known_hash(rel, sz, mt)
      if (!is.na(h)) return(c(h, "read"))
      c(NA_character_, "name_size")
    }
    ai <- if (loc[i] == "uuid") match(own_key[i], A$key) else NA_integer_
    if (base[i] == ".DS_Store") {
      r$hash_basis <- "name_size"
      r$action <- "keep"; r$reason <- "Finder metadata"
    } else if (!is.na(ai)) {
      # an asset's own file
      r$asset_uuid <- A$uuid[ai]; r$canonical_path <- rel
      r$hash <- A$hash[ai]; r$hash_basis <- if (A$src[ai] == "db") "db_asset" else "extra_asset"
      note <- ""
      hb <- if (local) c(hash_root_file(file.path(root, rel)), "local") else
        c(mirror_hash(rel, sz, mt), "mirror")
      if (!is.na(hb[1]) && !identical(hb[1], A$hash[ai]))
        note <- sprintf("; NOTE bytes no longer match asset.hash (%s hash %s) - SharePoint rewrite?", hb[2], hb[1])
      mm <- match(A$uuid[ai], merged$uuid)
      if (!is.na(mm) && merged$action[mm] == "retire") {
        r$action <- "keep"
        r$reason <- sprintf("migration %s deletes this asset row - its file is quarantined only after %s is applied%s",
                            merged$migration[mm], merged$migration[mm], note)
      } else if (A$hash[ai] %in% dup_hash) {
        others <- setdiff(A$uuid[A$hash %in% A$hash[ai]], A$uuid[ai])
        if (!is.na(mm) && merged$action[mm] == "merge") {
          r$action <- "keep"
          r$reason <- sprintf("legacy duplicate asset row; migration %s merges it into %s - its file is quarantined only after %s is applied%s",
                              merged$migration[mm], merged$merged_into[mm], merged$migration[mm], note)
        } else if (!is.na(mm) && merged$action[mm] == "keep") {
          r$action <- "keep"
          r$reason <- sprintf("legacy duplicate asset rows share this hash (also %s); kept as separate rows by migration %s (ruling)%s",
                              paste(others, collapse = " "), merged$migration[mm], note)
        } else if (A$uuid[ai] %in% merged$merged_into[merged$action == "merge"]) {
          r$action <- "keep"
          r$reason <- sprintf("canonical of a 057 merge (absorbs %s)%s",
                              paste(merged$uuid[merged$action == "merge" & merged$merged_into %in% A$uuid[ai]], collapse = " "), note)
        } else {
          r$action <- "ask-robin"
          r$reason <- paste0("legacy duplicate asset rows share this hash (also ",
                             paste(others, collapse = " "),
                             "); not covered by --merged - needs a ruling", note)
        }
      } else {
        r$action <- "keep"; r$reason <- paste0("asset's own file", note)
      }
    } else {
      hb <- hash_now()
      mi <- if (loc[i] == "uuid") match(own_key[i], merged_gone_key) else NA_integer_
      mnote <- ""
      if (!is.na(mi)) {
        if (is.na(hb[1])) hb <- c(merged_gone$hash[mi], "merged_asset")
        else if (!identical(hb[1], merged_gone$hash[mi])) {
          mnote <- sprintf("; NOTE bytes (%s) differ from the merged row's hash %s", hb[2], merged_gone$hash[mi])
          mi <- NA_integer_
        }
      }
      r$hash <- hb[1]; r$hash_basis <- hb[2]
      if (!is.na(r$hash)) {
        m <- which(A$hash == r$hash)
        pref <- if (!is.na(mi) && !is.na(merged_gone$merged_into[mi])) A$uuid[m] != merged_gone$merged_into[mi] else rep(FALSE, length(m))
        # prefer the kept row of a 057 merge; never a row 057 will delete
        m <- m[order(pref, A$uuid[m] %in% merged$uuid, A$src[m] != "db", is.na(A$size[m]), A$uuid[m])]
        probs <- character(); ok <- NA_integer_
        for (j in m) {
          pj <- canon_problem(j, sz)
          if (!nzchar(pj)) { ok <- j; break }
          probs <- c(probs, pj)
        }
        how <- sprintf("byte duplicate (%s hash)", r$hash_basis)
        if (!is.na(ok)) {
          r$canonical_path <- A$canonical[ok]
          dup_of <- sprintf("%s of asset %s%s", how, A$uuid[ok],
                            if (length(m) > 1) sprintf(" (and %d more asset rows with that hash)", length(m) - 1) else "")
          if (loc[i] == "emails") {
            r$action <- "ask-robin"; r$reason <- paste0("_emails copy is a ", dup_of)
          } else if (loc[i] == "outside") {
            r$action <- "keep"; r$reason <- paste0("outside processed/unprocessed/input; ", dup_of)
          } else {
            r$action <- "quarantine-duplicate"; r$reason <- paste0(dup_of, where_txt(i), mnote)
          }
        } else if (length(m)) {
          why <- sprintf("%s of asset %s, but the canonical copy is not verified: %s", how,
                         A$uuid[m[1]], paste(probs, collapse = "; "))
          r$canonical_path <- A$canonical[m[1]]
          if (loc[i] %in% c("uuid", "root", "other")) {
            r$action <- "quarantine-orphan"; r$reason <- paste0(orphan_txt(i), "; ", why, mnote)
          } else { r$action <- "keep"; r$reason <- why }
        } else {
          r$action <- switch(loc[i], uuid = , root = , other = "quarantine-orphan", "keep")
          r$reason <- switch(loc[i],
            uuid = , root = , other = paste0(orphan_txt(i), "; content matches no asset (unique bytes, kept in quarantine)", mnote),
            emails = "_emails content, not a duplicate of any asset",
            staging = "not ingested yet (not an asset)",
            outside = "outside processed/unprocessed/input; not examined")
        }
      } else {
        m <- which(A$filename == base[i] & !is.na(A$size) & A$size == sz)
        ns <- if (length(m)) sprintf("name+size match %d asset(s) (%s), NOT hash-verified (not local, no mirror copy)",
                                     length(m), paste(A$uuid[m], collapse = " ")) else
          "unhashable (not local, no mirror copy) and no name+size match"
        r$action <- switch(loc[i], uuid = , root = , other = "quarantine-orphan", "keep")
        r$reason <- switch(loc[i],
          uuid = , root = , other = paste0(orphan_txt(i), "; ", ns),
          emails = "_emails content (not hashed)",
          staging = if (length(m)) paste0(ns, " - left in place") else "not ingested yet (not an asset; not hashed)",
          outside = "outside processed/unprocessed/input; not examined")
        if (length(m)) r$canonical_path <- A$canonical[m[1]]
      }
    }
    rows[[i]] <- r
  }
  cols <- c("relpath", "kind", "size", "mtime", "local", "hash", "hash_basis", "asset_uuid",
            "canonical_path", "action", "reason")
  P <- as.data.frame(setNames(lapply(cols, function(k) {
    v <- unlist(lapply(rows, `[[`, k), use.names = FALSE)
    if (is.null(v)) v <- if (k %in% c("size", "mtime")) numeric() else if (k == "local") logical() else character()
    if (k %in% c("hash", "hash_basis", "asset_uuid", "canonical_path")) v <- as.character(v)
    v
  }), cols), stringsAsFactors = FALSE)

  # non-regular entries (symlinks etc.)
  for (i in seq_len(nrow(O))) {
    P[nrow(P) + 1, ] <- list(O$relpath[i], "other", O$size[i], O$mtime[i], FALSE, NA, NA, NA, NA,
                             "ask-robin", "not a regular file or directory (symlink?)")
  }

  # asset rows whose own file is missing, and simulated (extra) asset files
  have <- A$canonical %in% F$relpath
  for (j in which(!have)) {
    if (A$src[j] == "db") {
      P[nrow(P) + 1, ] <- list(A$canonical[j], "file", NA, NA, FALSE, A$hash[j], "db_asset", A$uuid[j],
                               A$canonical[j], "ask-robin", "asset row's own file is MISSING from the tree")
    } else {
      act <- "keep"; why <- "simulated: archived by the import (--extra-assets)"
      if (A$hash[j] %in% dup_hash) {
        act <- "ask-robin"; why <- paste(why, "- shares its hash with another asset row")
      }
      P[nrow(P) + 1, ] <- list(A$canonical[j], "file", A$size[j], NA, FALSE, A$hash[j], "extra_asset",
                               A$uuid[j], A$canonical[j], act, why)
    }
  }
  # extra assets that re-archive an existing asset's file whose bytes changed
  if (any(A$src == "extra")) {
    ie <- which(P$hash_basis == "extra_asset" & P$action == "keep" & !P$relpath %in% F$relpath)
    srcmap <- extra_sources(A, mirror)
    for (k in ie) {
      u <- P$asset_uuid[k]; fn <- basename(P$relpath[k])
      s <- srcmap[[u]]
      hit <- s[grepl("^processed/", s)]
      hit_uuid <- vapply(strsplit(hit, "/", fixed = TRUE), function(x) if (length(x) == 3) x[2] else "", "")
      own <- paste(hit_uuid, basename(hit), sep = "/") %in% A$key[A$src == "db"]
      if (any(own)) {
        P$action[k] <- "ask-robin"
        P$reason[k] <- sprintf(paste0("simulated: the import re-archives %s, the own file of existing asset %s, ",
                                      "because its bytes no longer match asset.hash (SharePoint rewrite) - a ",
                                      "second asset for the same report; exclude it from the run"),
                               hit[own][1], hit_uuid[own][1])
      } else {
        same <- A$src == "db" & A$filename == fn & A$hash != P$hash[k]
        if (any(same)) {
          P$action[k] <- "ask-robin"
          P$reason[k] <- paste0(P$reason[k], "; same filename as existing asset(s) ",
                                paste(A$uuid[same], collapse = " "),
                                " but different bytes - possibly a second asset for the same report")
        }
      }
    }
  }

  # uuid dirs under processed/
  dparts <- strsplit(D$relpath, "/", fixed = TRUE)
  is_udir <- lengths(dparts) == 2 & vapply(dparts, `[`, "", 1) == "processed" &
    grepl(UUID_RE, vapply(dparts, function(x) if (length(x) >= 2) x[2] else "", ""))
  for (d in D$relpath[is_udir]) {
    u <- basename(d)
    inside <- P[P$kind == "file" & startsWith(P$relpath, paste0(d, "/")) & P$relpath %in% F$relpath, , drop = FALSE]
    inside_any <- tr$relpath[startsWith(tr$relpath, paste0(d, "/"))]
    if (u %in% A$uuid) next  # an asset dir: its own file has a row (or a MISSING row)
    if (!length(inside_any)) {
      P[nrow(P) + 1, ] <- list(d, "dir", NA, NA, NA, NA, NA, NA, NA, "quarantine-orphan-empty-dir",
                               paste0("empty uuid dir with no asset row",
                                      if (u %in% f18) " (row deleted by F.18)" else ""))
    } else if (nrow(inside) == length(inside_any) && all(startsWith(inside$action, "quarantine-"))) {
      P[nrow(P) + 1, ] <- list(d, "dir", NA, NA, NA, NA, NA, NA, NA, "quarantine-orphan-empty-dir",
                               sprintf("orphan uuid dir, empty once its %d file(s) are quarantined",
                                       nrow(inside)))
    }
  }
  P$quarantine_relpath <- ifelse(startsWith(P$action, "quarantine-"),
                                 file.path(QDIR, date, P$relpath), NA_character_)
  P[order(P$kind == "dir", P$relpath), , drop = FALSE]
}

# mirror relpaths holding each extra asset's bytes (local mirror only)
extra_sources <- function(A, mirror) {
  out <- list()
  if (is.null(mirror)) return(out)
  fs <- list.files(mirror, recursive = TRUE, all.files = TRUE)
  h <- vapply(file.path(mirror, fs), rlang::hash_file, "")
  e <- A[A$src == "extra", ]
  for (j in seq_len(nrow(e))) out[[e$uuid[j]]] <- fs[h == e$hash[j]]
  out
}

# --merged CSV[,CSV]: uuid, filename, hash, merged_into[, action][, migration]
read_merged <- function(paths) {
  out <- data.frame(uuid = character(), filename = character(), hash = character(),
                    merged_into = character(), action = character(), migration = character())
  if (is.null(paths)) return(out)
  for (f in strsplit(paths, ",", fixed = TRUE)[[1]]) {
    x <- read_csv_chr(f)
    if (!all(c("uuid", "filename", "hash", "merged_into") %in% names(x)))
      stop("--merged CSV needs columns uuid, filename, hash, merged_into: ", f, call. = FALSE)
    if (!"action" %in% names(x)) x$action <- ifelse(is.na(x$merged_into) | !nzchar(x$merged_into), "retire", "merge")
    if (!"migration" %in% names(x)) x$migration <- "057"
    x$action[is.na(x$action)] <- ifelse(is.na(x$merged_into[is.na(x$action)]), "retire", "merge")
    if (!all(x$action %in% c("merge", "retire", "keep")))
      stop("--merged action must be merge, retire or keep: ", f, call. = FALSE)
    out <- rbind(out, x[, names(out)])
  }
  out$filename[is.na(out$filename)] <- ""
  out
}

script_dir <- function() {
  a <- commandArgs(trailingOnly = FALSE)
  f <- sub("^--file=", "", a[grepl("^--file=", a)])
  f <- gsub("~+~", " ", f, fixed = TRUE)
  if (length(f)) dirname(norm(f[1])) else getwd()
}

write_plan <- function(P, root, plan_out) {
  utils::write.csv(P, plan_out, row.names = FALSE, na = "")
  q <- P[startsWith(P$action, "quarantine-"), , drop = FALSE]
  undo <- data.frame(from = file.path(norm(root), q$quarantine_relpath),
                     to = file.path(norm(root), q$relpath), kind = q$kind)
  undo_out <- sub("(\\.csv)?$", "-undo.csv", plan_out)
  utils::write.csv(undo, undo_out, row.names = FALSE)
  undo_out
}

summarise_plan <- function(P) {
  loc <- ifelse(P$kind == "dir", "uuid dir",
         ifelse(startsWith(P$relpath, "processed/_emails/"), "processed/_emails",
         ifelse(startsWith(P$relpath, "processed/"), "processed",
         ifelse(startsWith(P$relpath, "unprocessed/") | startsWith(P$relpath, "input/"),
                "unprocessed+input", "other"))))
  cat("\nPlan rows by action x location:\n")
  print(addmargins(table(action = P$action, where = loc)))
  q <- P[P$action == "quarantine-duplicate", ]
  if (nrow(q)) { cat("\nquarantine-duplicate by hash_basis:\n"); print(table(q$hash_basis)) }
  cat(sprintf("\nfiles read under the root (local only): %d, %.1f MB\n", READ$n, READ$bytes / 1e6))
}

# ---- apply -------------------------------------------------------------------
read_csv_chr <- function(f) utils::read.csv(f, colClasses = "character", na.strings = "",
                                            check.names = FALSE)

safe_rel <- function(rel) {
  !is.na(rel) && nzchar(rel) && !startsWith(rel, "/") &&
    !any(strsplit(rel, "/", fixed = TRUE)[[1]] %in% c("..", ".")) &&
    grepl("^(processed|unprocessed|input)/", rel)
}

do_apply <- function(o) {
  root <- norm(o$root)
  P <- read_csv_chr(o$apply)
  need <- c("relpath", "kind", "size", "hash", "hash_basis", "local", "canonical_path",
            "action", "quarantine_relpath")
  if (!all(need %in% names(P))) stop("not a processed-dedupe plan: ", o$apply, call. = FALSE)
  A <- read_assets(o$db)$asset
  A$filename[is.na(A$filename)] <- ""
  akey <- paste(A$uuid, A$filename, sep = "/")
  has_mtime <- "mtime" %in% names(P)
  Q <- P[startsWith(P$action, "quarantine-"), , drop = FALSE]
  Q <- Q[order(Q$kind == "dir"), , drop = FALSE]  # files before dirs
  log_out <- sub("(\\.csv)?$", "-apply-log.csv", o$apply)
  res <- data.frame(at = character(), relpath = character(), kind = character(),
                    action = character(), status = character(), detail = character())
  logrow <- function(q, status, detail = "") {
    res[nrow(res) + 1, ] <<- list(format(Sys.time(), "%Y-%m-%d %H:%M:%S"), q$relpath, q$kind,
                                  q$action, status, detail)
    cat(sprintf("%-8s %s  %s\n", status, q$relpath, detail))
  }
  for (i in seq_len(nrow(Q))) {
    q <- Q[i, ]
    if (!safe_rel(q$relpath) || !safe_rel(sub(paste0("^", QDIR, "/[0-9]{8}/"), "", q$quarantine_relpath %||% "")) ||
        !startsWith(q$quarantine_relpath %||% "", paste0(QDIR, "/"))) {
      logrow(q, "REFUSED", "relpath or quarantine path outside the allowed tree"); next
    }
    src <- file.path(root, q$relpath); dst <- file.path(root, q$quarantine_relpath)
    parts <- strsplit(q$relpath, "/", fixed = TRUE)[[1]]
    u <- if (length(parts) >= 2 && parts[1] == "processed") parts[2] else ""
    if (q$kind == "file") {
      if (!file.exists(src)) {
        if (file.exists(dst)) logrow(q, "skipped", "already moved") else logrow(q, "REFUSED", "source missing")
        next
      }
      if (dir.exists(src)) { logrow(q, "REFUSED", "source is now a directory"); next }
      if (file.exists(dst)) { logrow(q, "REFUSED", "quarantine destination already exists"); next }
      sz <- file.info(src)$size
      if (is.na(q$size) || !identical(as.numeric(q$size), as.numeric(sz))) {
        logrow(q, "REFUSED", sprintf("size changed (plan %s, now %s)", q$size, sz)); next
      }
      if (has_mtime && !is.na(q$mtime) && !identical(floor(as.numeric(q$mtime)), floor(mtime_of(src)))) {
        logrow(q, "REFUSED", sprintf("mtime changed (plan %s, now %s)", q$mtime, mtime_of(src))); next
      }
      if (length(parts) == 3 && paste(u, parts[3], sep = "/") %in% akey) {
        logrow(q, "REFUSED", "the DB has an asset row pointing at this path"); next
      }
      if (!is.na(q$hash) && q$hash_basis %in% BYTE_BASES && is_local(blocks_of(src), sz) &&
          !test_nonlocal(q$relpath)) {
        h <- rlang::hash_file(src)
        if (!identical(h, q$hash)) { logrow(q, "REFUSED", sprintf("hash changed (now %s)", h)); next }
      }
      if (q$action == "quarantine-duplicate") {
        cp <- q$canonical_path
        cparts <- strsplit(cp %||% "", "/", fixed = TRUE)[[1]]
        ck <- if (length(cparts) == 3) paste(cparts[2], cparts[3], sep = "/") else ""
        if (is.na(cp) || !ck %in% akey) {
          logrow(q, "REFUSED", "canonical copy is not an asset of this DB"); next
        }
        if (!file.exists(file.path(root, cp))) {
          logrow(q, "REFUSED", "canonical copy missing from the tree"); next
        }
        if (identical(norm(file.path(root, cp)), norm(src))) {
          logrow(q, "REFUSED", "source is its own canonical copy"); next
        }
        if (q$hash_basis == "name_size" || is.na(q$hash)) {
          logrow(q, "REFUSED", "not hash-verified (name+size only)"); next
        }
        if (!identical(as.numeric(file.info(file.path(root, cp))$size), as.numeric(sz))) {
          logrow(q, "REFUSED", "canonical copy size differs"); next
        }
        ah <- A$hash[match(ck, akey)]
        if (!identical(ah, q$hash)) {
          logrow(q, "REFUSED", sprintf("canonical asset hash %s differs from the plan's %s", ah, q$hash)); next
        }
        cpath <- file.path(root, cp)
        if (is_local(blocks_of(cpath), file.info(cpath)$size) && !test_nonlocal(cp)) {
          ch <- hash_root_file(cpath)
          if (!identical(ch, ah)) { logrow(q, "REFUSED", sprintf("canonical copy bytes changed (now %s)", ch)); next }
        }
      }
      dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
      if (isTRUE(file.rename(src, dst))) logrow(q, "moved", q$quarantine_relpath)
      else logrow(q, "FAILED", "file.rename failed")
    } else if (q$kind == "dir") {
      if (!dir.exists(src)) {
        if (dir.exists(dst)) logrow(q, "skipped", "already moved") else logrow(q, "REFUSED", "source missing")
        next
      }
      if (u %in% A$uuid) { logrow(q, "REFUSED", "the DB has an asset row for this uuid dir"); next }
      if (length(list.files(src, all.files = TRUE, no.. = TRUE))) {
        logrow(q, "REFUSED", "directory is not empty"); next
      }
      if (dir.exists(dst)) {
        # its files were quarantined into dst already: drop the now-empty source dir
        if (isTRUE(file.remove(src))) logrow(q, "moved", paste(q$quarantine_relpath, "(merged)"))
        else logrow(q, "FAILED", "could not remove empty dir")
      } else {
        dir.create(dirname(dst), recursive = TRUE, showWarnings = FALSE)
        if (isTRUE(file.rename(src, dst))) logrow(q, "moved", q$quarantine_relpath)
        else logrow(q, "FAILED", "rename failed")
      }
    } else {
      logrow(q, "REFUSED", "unknown kind")
    }
  }
  utils::write.table(res, log_out, sep = ",", row.names = FALSE, na = "", qmethod = "double",
                     append = file.exists(log_out), col.names = !file.exists(log_out))
  cat(sprintf("\napply: %s\nlog: %s\n", paste(names(table(res$status)), table(res$status),
                                              sep = "=", collapse = " "), log_out))
  if (any(res$status %in% c("REFUSED", "FAILED"))) quit(status = 2)
  invisible(res)
}

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

do_undo <- function(o) {
  U <- read_csv_chr(o$undo)
  U <- U[order(U$kind != "dir"), , drop = FALSE]  # recreate dirs first
  st <- character()
  for (i in seq_len(nrow(U))) {
    f <- U$from[i]; t <- U$to[i]
    if (U$kind[i] == "dir") {
      if (dir.exists(t)) { st <- c(st, "skipped"); next }
      if (dir.exists(f) && !length(list.files(f, all.files = TRUE, no.. = TRUE))) {
        ok <- file.rename(f, t)
      } else {
        ok <- dir.create(t, recursive = TRUE)
      }
      st <- c(st, if (isTRUE(ok)) "restored" else "FAILED")
    } else {
      if (!file.exists(f) || file.exists(t)) { st <- c(st, "skipped"); next }
      dir.create(dirname(t), recursive = TRUE, showWarnings = FALSE)
      st <- c(st, if (isTRUE(file.rename(f, t))) "restored" else "FAILED")
    }
    cat(sprintf("%-8s %s\n", st[length(st)], t))
  }
  cat("\nundo:", paste(names(table(st)), table(st), sep = "=", collapse = " "), "\n")
}

# ---- main --------------------------------------------------------------------
main <- function() {
  o <- parse_args(commandArgs(trailingOnly = TRUE))
  if (isTRUE(o$help)) {
    l <- readLines(file.path(script_dir(), "processed-dedupe.R"))
    cat(sub("^# ?", "", l[2:grep("^# ={10}", l)[2]]), sep = "\n"); return(invisible())
  }
  o$db <- o$db %||% LIVE_DB
  if (!is.null(o[["test-nonlocal"]])) TEST_NONLOCAL <<- o[["test-nonlocal"]]
  o$root <- o$root %||% default_root()
  o$date <- o$date %||% format(Sys.Date(), "%Y%m%d")
  if (!grepl("^[0-9]{8}$", o$date)) stop("--date must be YYYYMMDD", call. = FALSE)
  if (!dir.exists(o$root)) stop("root not found: ", o$root, call. = FALSE)
  if (!is.null(o$undo)) return(do_undo(o))
  if (!is.null(o$apply)) {
    if (isTRUE(o[["post-import"]])) stop("--post-import builds its own plan; do not pass --apply", call. = FALSE)
    if (!is.null(o[["extra-assets"]])) stop("--extra-assets is a simulation; it cannot be applied", call. = FALSE)
    return(do_apply(o))
  }
  if (isTRUE(o[["post-import"]]) && !is.null(o[["extra-assets"]]))
    stop("--extra-assets is a simulation; it cannot be combined with --post-import", call. = FALSE)
  o[["plan-out"]] <- o[["plan-out"]] %||% file.path(getwd(), sprintf("processed-dedupe-plan-%s.csv", o$date))
  if (is_inside(o[["plan-out"]], o$root))
    stop("--plan-out must not be inside --root (the dry run never writes there)", call. = FALSE)
  cat("DRY RUN - nothing under the root is changed\n")
  cat(sprintf("db    %s (read-only)\nroot  %s\n", o$db, norm(o$root)))
  if (!is.null(o[["extra-assets"]])) cat(sprintf("extra %s (simulated assets)\n", o[["extra-assets"]]))
  P <- make_plan(o)
  undo_out <- write_plan(P, o$root, o[["plan-out"]])
  summarise_plan(P)
  cat(sprintf("\nplan: %s\nundo: %s\n", o[["plan-out"]], undo_out))
  if (isTRUE(o[["post-import"]])) {
    S <- post_import_subset(P, o)
    sub_out <- sub("(\\.csv)?$", "-post-import.csv", o[["plan-out"]])
    sub_undo <- write_plan(S, o$root, sub_out)
    cat(sprintf("\nPOST-IMPORT: applying %d import-dependent row(s) (%d file(s), %d dir(s)); the rest of the plan is NOT applied\nsubset: %s\nundo:   %s\n",
                nrow(S), sum(S$kind == "file"), sum(S$kind == "dir"), sub_out, sub_undo))
    o$apply <- sub_out
    return(do_apply(o))
  }
}

# The import-dependent part of a fresh plan: duplicates under unprocessed/ or
# input/ (their bytes became assets in the import), the own files of rows 057
# merged away, and the uuid dirs those moves empty.
post_import_subset <- function(P, o) {
  M <- read_merged(o$merged)
  merged_uuid <- M$uuid[M$action != "keep"]
  retired_uuid <- M$uuid[M$action == "retire"]
  rp <- strsplit(P$relpath, "/", fixed = TRUE)
  udir <- vapply(rp, function(x) if (length(x) >= 2 && x[1] == "processed") x[2] else "", "")
  f <- P$kind == "file" & ((P$action == "quarantine-duplicate" &
    (startsWith(P$relpath, "unprocessed/") | startsWith(P$relpath, "input/") | udir %in% merged_uuid)) |
    (P$action == "quarantine-orphan" & udir %in% retired_uuid))
  d <- P$kind == "dir" & P$action == "quarantine-orphan-empty-dir" & udir %in% merged_uuid
  for (k in which(d)) {
    inside <- P$kind == "file" & startsWith(P$relpath, paste0(P$relpath[k], "/"))
    if (!all(f[inside])) d[k] <- FALSE
  }
  P[f | d, , drop = FALSE]
}

if (sys.nframe() == 0L) main()
