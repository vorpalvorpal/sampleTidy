# Content fingerprints: a stable identity for files a file store rewrites.
#
# `hash_file()` (R/hash.R) hashes the BYTES. A cloud file store (SharePoint,
# for one) rewrites legacy OLE/CFB Office files (.xls/.doc/.ppt) after they are
# archived: it adds or changes the root-level `MsoDataStore` storage and the
# directory timestamps, and leaves the data streams alone. The bytes (and
# sometimes the size) change; the content does not. A content fingerprint
# hashes only the parts the store does not own, so it survives the rewrite.
#
#   * `content_fingerprint(path)` dispatches on the file's MAGIC NUMBER, never
#     its extension, through a registry of fingerprinters: the built-in `ole1`
#     plus any in `st_config("content_fingerprinters")`. A file no entry
#     matches gets NA/NA (its byte hash is its identity).
#   * A fingerprinter that fails (a malformed container, a bad `fun`) gives
#     NA/NA and one warning - never an error, never a hang. A caller that
#     treats NA as "no content identity" then falls back to the byte hash.
#   * `ole1` is specified in docs/ and pinned by the tests: every stream of
#     the compound file, minus `MsoDataStore/*` and the `\005*` property sets,
#     sorted by path, hashed as path, NUL, 8-byte length, bytes.
#   * `.cfb_read_streams()` is a pure-R MS-CFB reader (no new dependency). It
#     reads the whole file in one go and gathers sectors with vectorised
#     indexing; only the sector CHAIN walks are loops. Every structural
#     inconsistency (out-of-range sector, chain cycle or overlong chain,
#     stream past the end of its chain, truncated file, directory cycle)
#     aborts `sampletidy_error`.

.cf_end <- 4294967294
.cf_nostream <- 4294967295
.cf_magic_ole <- as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))

#' Read an MS-CFB (compound file) into its streams
#'
#' Supports major versions 3 (512-byte sectors) and 4 (4096-byte sectors).
#' Returns every stream (type 2) as a named list of raw vectors; the name is
#' the "/"-joined path of the stream's storages below the root, then its own
#' name. Aborts `sampletidy_error` on a malformed file.
#' @keywords internal
#' @noRd
.cfb_read_streams <- function(path) {
  bad <- function(msg) {
    cli::cli_abort("Malformed compound file: {msg}.", class = "sampletidy_error")
  }
  size <- file.size(path)
  bytes <- readBin(path, "raw", n = size)
  n <- length(bytes)
  if (n < 512L || !identical(bytes[1:8], .cf_magic_ole)) {
    bad("not a compound file or truncated header")
  }
  u16 <- function(off) sum(as.numeric(bytes[off + 1:2]) * c(1, 256))
  # n unsigned 32-bit little-endian integers at byte offset `off` of `x`
  u32 <- function(x, off, k) {
    v <- as.numeric(readBin(x[off + seq_len(4L * k)], "integer", n = k, size = 4L,
                            endian = "little"))
    v[v < 0] <- v[v < 0] + 4294967296
    v
  }
  major <- u16(26)
  ss_shift <- u16(30)
  mss_shift <- u16(32)
  if (!(major %in% c(3, 4)) || u16(28) != 0xFFFE ||
      ss_shift != (if (major == 3) 9 else 12) || mss_shift != 6) {
    bad("unsupported version or sector size")
  }
  ss <- 2^ss_shift
  per <- ss / 4
  nsect <- floor(n / ss) - 1   # complete sectors after the header sector
  if (nsect < 1) {
    bad("no sectors")
  }
  hdr <- u32(bytes, 44, 8)    # nfat, dir start, (txn), cutoff, mf start, n mf, difat start, n difat
  nfat <- hdr[[1]]; dir_start <- hdr[[2]]; cutoff <- hdr[[4]]
  mf_start <- hdr[[5]]; n_mf <- hdr[[6]]; difat_start <- hdr[[7]]; n_difat <- hdr[[8]]
  if (nfat < 1 || nfat > nsect || n_mf > nsect || n_difat > nsect) {
    bad("sector counts out of range")
  }

  sector_bytes <- function(ids) {
    if (length(ids) == 0) {
      return(raw(0))
    }
    if (any(ids < 0 | ids >= nsect)) {
      bad("sector index out of range")
    }
    bytes[rep(ss * (ids + 1), each = ss) + seq_len(ss)]
  }
  # Follow a chain through `tbl` (FAT or MiniFAT) to its end marker.
  walk <- function(start, tbl, limit) {
    out <- numeric(0)
    cur <- start
    while (cur != .cf_end) {
      if (cur >= length(tbl) || cur >= limit || length(out) >= limit) {
        bad("sector chain out of range or cyclic")
      }
      out[[length(out) + 1L]] <- cur
      cur <- tbl[[cur + 1]]
    }
    out
  }

  # DIFAT: 109 header entries, then a chain of DIFAT sectors.
  fat_ids <- u32(bytes, 76, 109)
  d <- difat_start
  seen <- 0
  while (d != .cf_end && n_difat > 0) {
    seen <- seen + 1
    if (seen > n_difat || d >= nsect) {
      bad("DIFAT chain out of range or cyclic")
    }
    s <- sector_bytes(d)
    v <- u32(s, 0, per)
    fat_ids <- c(fat_ids, v[-per])
    d <- v[[per]]
  }
  fat_ids <- fat_ids[fat_ids < nsect]
  if (length(fat_ids) < nfat) {
    bad("FAT sectors missing")
  }
  fat_ids <- fat_ids[seq_len(nfat)]
  fat <- u32(sector_bytes(fat_ids), 0, nfat * per)

  # Directory.
  dir_chain <- walk(dir_start, fat, nsect)
  dirb <- sector_bytes(dir_chain)
  n_ent <- length(dirb) / 128
  if (n_ent < 1) {
    bad("empty directory")
  }
  ent <- matrix(dirb, nrow = 128)
  ent_u32 <- function(off) {
    v <- as.numeric(readBin(as.vector(ent[off + 1:4, ]), "integer", n = n_ent, size = 4L,
                            endian = "little"))
    v[v < 0] <- v[v < 0] + 4294967296
    v
  }
  e_type <- as.integer(ent[67, ])
  e_left <- ent_u32(68); e_right <- ent_u32(72); e_child <- ent_u32(76)
  e_start <- ent_u32(116)
  e_size <- ent_u32(120)
  if (major == 4) {
    e_size <- e_size + ent_u32(124) * 4294967296
  }
  if (e_type[[1]] != 5L) {
    bad("the first directory entry is not the root")
  }

  # Mini stream and MiniFAT.
  minifat <- numeric(0)
  if (n_mf > 0) {
    mf_chain <- walk(mf_start, fat, nsect)
    minifat <- u32(sector_bytes(mf_chain), 0, length(mf_chain) * per)
  }
  mini <- raw(0)
  if (e_size[[1]] > 0) {
    root_chain <- walk(e_start[[1]], fat, nsect)
    if (length(root_chain) * ss < e_size[[1]]) {
      bad("the mini stream extends past its sector chain")
    }
    mini <- sector_bytes(root_chain)[seq_len(e_size[[1]])]
  }
  nmini <- floor(length(mini) / 64)

  stream_bytes <- function(i) {
    len <- e_size[[i]]
    if (len == 0) {
      return(raw(0))
    }
    if (len < cutoff) {
      ch <- walk(e_start[[i]], minifat, nmini)
      if (length(ch) * 64 < len) {
        bad("a stream extends past its mini sector chain")
      }
      mini[rep(64 * ch, each = 64) + seq_len(64)][seq_len(len)]
    } else {
      ch <- walk(e_start[[i]], fat, nsect)
      if (length(ch) * ss < len) {
        bad("a stream extends past its sector chain")
      }
      sector_bytes(ch)[seq_len(len)]
    }
  }
  entry_name <- function(i) {
    nl <- as.numeric(ent[65, i]) + 256 * as.numeric(ent[66, i])
    if (nl < 2 || nl > 64 || nl %% 2 != 0) {
      bad("a directory entry has an invalid name length")
    }
    nm <- iconv(list(as.raw(ent[seq_len(nl - 2), i])), "UTF-16LE", "UTF-8")
    if (is.na(nm)) {
      bad("a directory entry name is not valid UTF-16")
    }
    nm
  }

  # Walk the tree: siblings (left/right) and children, each entry once.
  out <- list()
  visited <- logical(n_ent)
  stack <- list(list(id = e_child[[1]], prefix = ""))
  while (length(stack) > 0) {
    top <- stack[[length(stack)]]
    stack[[length(stack)]] <- NULL
    id <- top$id
    if (id == .cf_nostream) {
      next
    }
    if (id >= n_ent) {
      bad("a directory entry index is out of range")
    }
    if (visited[[id + 1]]) {
      bad("the directory tree is cyclic")
    }
    visited[[id + 1]] <- TRUE
    stack[[length(stack) + 1L]] <- list(id = e_left[[id + 1]], prefix = top$prefix)
    stack[[length(stack) + 1L]] <- list(id = e_right[[id + 1]], prefix = top$prefix)
    type <- e_type[[id + 1]]
    if (type != 1L && type != 2L) {
      next
    }
    nm <- entry_name(id + 1)
    p <- if (nzchar(top$prefix)) paste0(top$prefix, "/", nm) else nm
    if (type == 2L) {
      if (!is.null(out[[p]]) || p %in% names(out)) {
        bad("duplicate stream path")
      }
      out[p] <- list(stream_bytes(id + 1))
    } else {
      stack[[length(stack) + 1L]] <- list(id = e_child[[id + 1]], prefix = p)
    }
  }
  out
}

# ---- fingerprinters ---------------------------------------------------------

#' The `ole1` content hash of a compound file (see the header comment)
#' @keywords internal
#' @noRd
.cf_ole1 <- function(path) {
  streams <- .cfb_read_streams(path)
  paths <- enc2utf8(names(streams))
  parts <- strsplit(paths, "/", fixed = TRUE)
  first <- vapply(parts, function(p) p[[1]], character(1))
  last <- vapply(parts, function(p) p[[length(p)]], character(1))
  keep <- tolower(first) != "msodatastore" & substr(last, 1, 1) != "\005"
  idx <- which(keep)
  idx <- idx[order(paths[idx], method = "radix")]
  le64 <- function(x) as.raw(floor(x / 256^(0:7)) %% 256)
  pieces <- lapply(idx, function(i) {
    b <- streams[[i]]
    c(charToRaw(paths[[i]]), as.raw(0), le64(length(b)), b)
  })
  digest::digest(as.raw(unlist(pieces)), algo = "xxh3_128", serialize = FALSE)
}

.cf_builtin_fingerprinters <- function() {
  list(ole1 = list(magic = .cf_magic_ole, fun = .cf_ole1))
}

#' The validated fingerprinter registry: config entries, then built-ins
#' @keywords internal
#' @noRd
.cf_registry <- function() {
  cfg <- st_config("content_fingerprinters")
  builtin <- .cf_builtin_fingerprinters()
  if (is.null(cfg)) {
    return(builtin)
  }
  bad <- function(msg) {
    cli::cli_abort(
      c("Invalid {.code st_config(\"content_fingerprinters\")}.", x = msg,
        i = "Use {.code NULL} or a named list of {.code list(magic = <raw>, fun = <function>)}."),
      class = "sampletidy_error", .envir = parent.frame()
    )
  }
  if (!is.list(cfg) || is.data.frame(cfg)) {
    bad("It must be a list, not {.cls {class(cfg)}}.")
  }
  nms <- names(cfg)
  if (length(cfg) > 0 && (is.null(nms) || any(is.na(nms) | !nzchar(nms)) || anyDuplicated(nms))) {
    bad("Every entry must be named, once.")
  }
  for (nm in nms) {
    e <- cfg[[nm]]
    if (!is.list(e) || !is.raw(e$magic) || length(e$magic) == 0) {
      bad("Entry {.field {nm}} needs a non-empty raw {.field magic}.")
    }
    if (!is.function(e$fun)) {
      bad("Entry {.field {nm}} needs a function {.field fun}.")
    }
  }
  c(cfg, builtin[setdiff(names(builtin), nms)])
}

#' Content fingerprint of a file
#'
#' A content fingerprint is a hash of a file's logical content that ignores
#' the parts a file store may rewrite, so it identifies the same content
#' across a storage rewrite where the byte hash ([hash_file()]) does not.
#' The fingerprinter is chosen by the file's leading bytes (its magic
#' number), never its extension.
#'
#' The built-in `ole1` fingerprinter handles OLE/CFB compound files (legacy
#' `.xls`, `.doc`, `.ppt`). It reads every stream of the container, drops the
#' root-level `MsoDataStore` storage (compared case-insensitively) and every
#' stream whose own name starts with U+0005 (property sets such as the summary
#' information), sorts the rest by the bytes of their UTF-8 path, and hashes
#' for each the path, a NUL byte, the stream length as 8 little-endian bytes
#' and the stream bytes with xxHash128 (`xxh3_128`). Sector layout, directory
#' order, timestamps and class ids do not matter.
#'
#' `st_config("content_fingerprinters")` extends the registry: `NULL` (the
#' default) adds nothing; otherwise a named list whose elements are
#' `list(magic = <raw>, fun = function(path))`, where `fun` returns one
#' string. The name is the algorithm tag. Entries are tried before the
#' built-ins in list order, and an entry named `ole1` replaces the built-in.
#' It cannot be set from an environment variable. An invalid value aborts
#' with a `sampletidy_error` when this function is called.
#'
#' @param path path to an existing file.
#' @return a list with `content_hash` (a string) and `content_hash_alg` (the
#'   fingerprinter's name, `"ole1"` for the built-in); both `NA_character_`
#'   when no fingerprinter matches the file's magic number, or when the
#'   matching one fails (a malformed container, say), which also warns,
#'   naming the file. A missing file aborts with a `sampletidy_error`.
#' @export
content_fingerprint <- function(path) {
  checkmate::assert_string(path)
  registry <- .cf_registry()
  na <- list(content_hash = NA_character_, content_hash_alg = NA_character_)
  if (!utils::file_test("-f", path)) {
    cli::cli_abort("File not found: {.path {path}}.", class = "sampletidy_error")
  }
  n <- max(vapply(registry, function(e) length(e$magic), integer(1)))
  head <- readBin(path, "raw", n = n)
  hit <- NULL
  for (nm in names(registry)) {
    m <- registry[[nm]]$magic
    if (length(head) >= length(m) && identical(head[seq_along(m)], m)) {
      hit <- nm
      break
    }
  }
  if (is.null(hit)) {
    return(na)
  }
  fn <- basename(path)
  res <- tryCatch(
    {
      h <- registry[[hit]]$fun(path)
      if (!is.character(h) || length(h) != 1 || is.na(h) || !nzchar(h)) {
        stop("the fingerprinter did not return one non-empty string")
      }
      h
    },
    error = function(e) {
      msg <- conditionMessage(e)
      cli::cli_warn(
        "content_fingerprint(): the {.val {hit}} fingerprint of {.file {fn}}
         failed, so it has no content hash: {msg}"
      )
      NA_character_
    }
  )
  if (is.na(res)) {
    return(na)
  }
  list(content_hash = res, content_hash_alg = hit)
}
