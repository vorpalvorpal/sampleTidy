# Synthetic MS-CFB (compound file binary) fixtures for the content-fingerprint
# tests.
#
# `cfb_write()` builds a VALID compound file from a logical stream list, with
# knobs that change only the PHYSICAL layout (sector order, directory entry
# order and tree shape, extra free sectors, timestamps and CLSIDs), plus
# `fault` modes that make deliberately malformed files. `ole1_expected()` is an
# independent oracle for the `ole1` content hash of spec section 2. Neither
# shares code with the package; the package reader is tested AGAINST them.
# `cfb_parse_check()` is a deliberately tiny, separate parser used only to
# check the writer's own output (structural invariants), so a reader bug and a
# writer bug cannot hide each other.
#
# Everything here is synthetic: stream names and bytes are made up.

.cfb <- list(
  END = 4294967294, FREE = 4294967295, FATSECT = 4294967293, DIFSECT = 4294967292,
  magic = as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))
)

.cfb_u16 <- function(x) writeBin(as.integer(x), raw(), size = 2L, endian = "little")
.cfb_u32 <- function(x) {
  x <- as.numeric(x)
  x <- ifelse(x >= 2^31, x - 2^32, x)
  writeBin(as.integer(x), raw(), size = 4L, endian = "little")
}
.cfb_u64 <- function(x) {
  as.raw(vapply(0:7, function(i) floor(x / 256^i) %% 256, numeric(1)))
}

# Deterministic pseudo-random bytes (does not disturb the caller's RNG).
cfb_bytes <- function(n, seed = 1) {
  if (n == 0) return(raw(0))
  withr::with_seed(seed, as.raw(sample.int(256L, n, replace = TRUE) - 1L))
}

# ---- the writer -------------------------------------------------------------

#' Build a compound file as a raw vector.
#'
#' @param streams named list, path -> raw. "/" in a path nests it in storages.
#' @param version 3L (512-byte sectors) or 4L (4096-byte sectors).
#' @param shuffle place sectors (data, FAT, DIFAT, mini sectors) in a random
#'   non-contiguous order. Logical content is unchanged.
#' @param seed seed for every random choice (private RNG stream).
#' @param dir_shuffle permute directory entry indices and sibling order.
#' @param dir_shape "chain" (right-sibling chain, unbalanced), "balanced" or
#'   "left" (left-sibling chain).
#' @param extra_free number of free (unreferenced, zeroed) sectors to append.
#' @param meta fill CLSIDs, state bits and timestamps with random values.
#' @param empty_storages storage paths to create with no children.
#' @param junk_high_size v3 only: put junk in the high 32 bits of each
#'   directory entry's stream size (readers must ignore it).
#' @param fault NULL, or one of "truncate" (cut at 60 percent), "truncate_header"
#'   (100 bytes), "cycle" (a stream's FAT chain loops; needs a stream >= 4096
#'   bytes), "bad_sector" (a chain points past the end of the file).
cfb_build <- function(streams, version = 3L, shuffle = FALSE, seed = 1,
                      dir_shuffle = FALSE, dir_shape = c("chain", "balanced", "left"),
                      extra_free = 0L, meta = FALSE, empty_storages = character(),
                      junk_high_size = FALSE, fault = NULL) {
  dir_shape <- match.arg(dir_shape)
  stopifnot(version %in% c(3L, 4L), is.list(streams))
  if (length(streams) > 0) stopifnot(!is.null(names(streams)), !anyDuplicated(names(streams)))
  withr::with_seed(seed, .cfb_build(streams, version, shuffle, dir_shuffle, dir_shape,
                                    as.integer(extra_free), meta, empty_storages,
                                    junk_high_size, fault))
}

.cfb_build <- function(streams, version, shuffle, dir_shuffle, dir_shape,
                       extra_free, meta, empty_storages, junk_high_size, fault) {
  C <- .cfb
  ss <- if (version == 3L) 512L else 4096L
  per <- ss %/% 4L
  paths <- names(streams)
  streams <- lapply(streams, as.raw)

  # -- directory entries ------------------------------------------------------
  parts_of <- function(p) strsplit(p, "/", fixed = TRUE)[[1]]
  storage_keys <- character(0)
  for (p in c(paths, if (length(empty_storages)) paste0(empty_storages, "/x"))) {
    pp <- parts_of(p)
    if (length(pp) > 1) {
      storage_keys <- c(storage_keys, vapply(seq_len(length(pp) - 1L),
        function(i) paste(pp[seq_len(i)], collapse = "/"), character(1)))
    }
  }
  storage_keys <- unique(storage_keys)
  keys <- c(storage_keys, paths)
  type <- c(rep(1L, length(storage_keys)), rep(2L, length(paths)))
  names(type) <- keys
  n_ent <- length(keys) + 1L
  ids <- seq_len(length(keys))
  if (dir_shuffle && length(ids) > 1) ids <- sample(ids)
  id_of <- stats::setNames(ids, keys)         # entry index of each key (root = 0)
  base_name <- vapply(keys, function(k) utils::tail(parts_of(k), 1), character(1))
  parent_of <- vapply(keys, function(k) {
    pp <- parts_of(k)
    if (length(pp) == 1) "" else paste(pp[-length(pp)], collapse = "/")
  }, character(1))
  for (nm in base_name) stopifnot(nchar(nm) <= 31L)

  left <- right <- child <- stats::setNames(rep(C$FREE, n_ent), as.character(0:(n_ent - 1L)))
  wire <- function(ks) {                      # returns the subtree root's entry index
    if (length(ks) == 0) return(C$FREE)
    if (dir_shuffle) ks <- sample(ks)
    i <- id_of[[ks[[1]]]]
    if (dir_shape == "chain") {
      for (j in seq_along(ks)[-1]) right[as.character(id_of[[ks[[j - 1]]]])] <<- id_of[[ks[[j]]]]
      return(id_of[[ks[[1]]]])
    }
    if (dir_shape == "left") {
      for (j in seq_along(ks)[-1]) left[as.character(id_of[[ks[[j - 1]]]])] <<- id_of[[ks[[j]]]]
      return(id_of[[ks[[1]]]])
    }
    rec <- function(k) {
      if (length(k) == 0) return(C$FREE)
      m <- (length(k) + 1L) %/% 2L
      me <- id_of[[k[[m]]]]
      left[as.character(me)] <<- rec(k[seq_len(m - 1L)])
      right[as.character(me)] <<- rec(k[-seq_len(m)])
      me
    }
    rec(ks)
  }
  child["0"] <- wire(keys[parent_of == ""])
  for (s in storage_keys) child[as.character(id_of[[s]])] <- wire(keys[parent_of == s])

  # -- sector accounting ------------------------------------------------------
  lens <- vapply(streams, length, numeric(1))
  is_mini <- lens > 0 & lens < 4096
  is_reg <- lens >= 4096
  mini_n <- ifelse(is_mini, ceiling(lens / 64), 0)
  n_mini <- sum(mini_n)
  mini_stream_len <- n_mini * 64
  n_ms <- ceiling(mini_stream_len / ss)                  # sectors holding the mini stream
  n_mf <- ceiling(n_mini / per)                          # MiniFAT sectors
  n_dir <- ceiling(n_ent / (ss %/% 128L))
  reg_n <- ifelse(is_reg, ceiling(lens / ss), 0)
  n_data <- n_dir + n_mf + n_ms + sum(reg_n)
  nfat <- 1L
  repeat {
    ndifat <- if (nfat > 109L) ceiling((nfat - 109L) / (per - 1L)) else 0L
    total <- n_data + extra_free + nfat + ndifat
    need <- ceiling(total / per)
    if (need <= nfat) break
    nfat <- as.integer(need)
  }
  slots <- if (shuffle) sample.int(total) - 1L else seq_len(total) - 1L
  take <- local({ pos <- 0L; function(k) { r <- slots[pos + seq_len(k)]; pos <<- pos + k; r } })
  dir_slots <- take(n_dir); mf_slots <- take(n_mf); ms_slots <- take(n_ms)
  reg_slots <- stats::setNames(lapply(reg_n, take), paths)
  fat_slots <- take(nfat); difat_slots <- take(ndifat)
  free_slots <- take(extra_free)

  mini_slots_all <- if (shuffle && n_mini > 1) sample.int(n_mini) - 1L else seq_len(n_mini) - 1L
  mpos <- 0L
  mini_slots <- stats::setNames(vector("list", length(paths)), paths)
  for (p in paths) {
    mini_slots[[p]] <- mini_slots_all[mpos + seq_len(mini_n[[p]])]
    mpos <- mpos + mini_n[[p]]
  }

  fat <- rep(C$FREE, nfat * per)
  minifat <- rep(C$FREE, max(n_mf, 0L) * per)
  chain <- function(v, tbl) {
    if (length(v) == 0) return(tbl)
    tbl[v + 1] <- c(v[-1], C$END)
    tbl
  }
  fat <- chain(dir_slots, fat); fat <- chain(mf_slots, fat); fat <- chain(ms_slots, fat)
  for (p in paths) fat <- chain(reg_slots[[p]], fat)
  fat[fat_slots + 1] <- C$FATSECT
  if (ndifat > 0) fat[difat_slots + 1] <- C$DIFSECT
  for (p in paths) minifat <- chain(mini_slots[[p]], minifat)

  # -- faults that live in the FAT --------------------------------------------
  if (identical(fault, "cycle") || identical(fault, "bad_sector")) {
    big <- Filter(length, reg_slots)
    if (length(big) == 0) stop("fault needs a stream of at least 4096 bytes")
    v <- big[[1]]
    fat[v[[length(v)]] + 1] <- if (fault == "cycle") v[[1]] else total + 1000
  }

  # -- sector payloads --------------------------------------------------------
  M <- matrix(raw(ss * total), nrow = ss)
  put <- function(sl, bytes) {
    if (length(sl) == 0) return(invisible())
    pad <- length(sl) * ss - length(bytes)
    M[, sl + 1] <<- matrix(c(bytes, raw(pad)), nrow = ss)
  }

  entry <- function(name, type, color, l, r, c, start, size, clsid, state, ctime, mtime) {
    nm <- if (nzchar(name)) iconv(name, "UTF-8", "UTF-16LE", toRaw = TRUE)[[1]] else raw(0)
    stopifnot(length(nm) <= 62)
    hi <- if (version == 3L && junk_high_size && type == 2L) 0xDEADBEEF else floor(size / 2^32)
    c(nm, raw(64 - length(nm)),
      .cfb_u16(if (nzchar(name)) length(nm) + 2L else 0L), as.raw(type), as.raw(color),
      .cfb_u32(c(l, r, c)), clsid, .cfb_u32(state), ctime, mtime,
      .cfb_u32(start), .cfb_u32(size %% 2^32), .cfb_u32(hi))
  }
  rnd <- function(n) if (meta) as.raw(sample.int(256L, n, replace = TRUE) - 1L) else raw(n)
  ent <- vector("list", n_ent)
  ent[[1]] <- entry("Root Entry", 5L, 1L, left[["0"]], right[["0"]], child[["0"]],
                    if (n_mini > 0) ms_slots[[1]] else C$END, mini_stream_len,
                    rnd(16), if (meta) sample.int(2^30, 1) else 0, rnd(8), rnd(8))
  for (k in keys) {
    i <- id_of[[k]]
    key <- as.character(i)
    if (type[[k]] == 2L) {
      L <- lens[[k]]
      start <- if (L == 0) C$END else if (is_mini[[k]]) mini_slots[[k]][[1]] else reg_slots[[k]][[1]]
    } else {
      L <- 0; start <- 0
    }
    ent[[i + 1]] <- entry(base_name[[k]], type[[k]], 1L, left[[key]], right[[key]], child[[key]],
                          start, L, rnd(16), if (meta) sample.int(2^30, 1) else 0, rnd(8), rnd(8))
  }
  blank <- c(raw(64), raw(2), as.raw(c(0, 0)), rep(as.raw(0xFF), 12), raw(128 - 64 - 2 - 2 - 12))
  stopifnot(length(blank) == 128)
  n_slots_dir <- n_dir * (ss %/% 128L)
  dir_bytes <- c(unlist(ent), rep(list(blank), n_slots_dir - n_ent) |> unlist())
  put(dir_slots, as.raw(dir_bytes))
  if (n_mf > 0) put(mf_slots, .cfb_u32(minifat))
  if (n_mini > 0) {
    mm <- matrix(raw(64 * n_mini), nrow = 64)
    for (p in paths[is_mini]) {
      b <- streams[[p]]
      mm[, mini_slots[[p]] + 1] <- matrix(c(b, raw(mini_n[[p]] * 64 - length(b))), nrow = 64)
    }
    put(ms_slots, as.vector(mm))
  }
  for (p in paths[is_reg]) put(reg_slots[[p]], streams[[p]])
  put(fat_slots, .cfb_u32(fat))
  if (ndifat > 0) {
    rest <- fat_slots[-seq_len(109)]
    for (d in seq_len(ndifat)) {
      chunk <- rest[(d - 1L) * (per - 1L) + seq_len(per - 1L)]
      chunk <- chunk[!is.na(chunk)]
      v <- c(chunk, rep(C$FREE, per - 1L - length(chunk)),
             if (d < ndifat) difat_slots[[d + 1L]] else C$END)
      put(difat_slots[[d]], .cfb_u32(v))
    }
  }

  header <- c(
    C$magic, raw(16), .cfb_u16(0x3E), .cfb_u16(version), .cfb_u16(0xFFFE),
    .cfb_u16(if (version == 3L) 9 else 12), .cfb_u16(6), raw(6),
    .cfb_u32(if (version == 3L) 0 else n_dir), .cfb_u32(nfat), .cfb_u32(dir_slots[[1]]),
    .cfb_u32(0), .cfb_u32(4096),
    .cfb_u32(if (n_mf > 0) mf_slots[[1]] else C$END), .cfb_u32(n_mf),
    .cfb_u32(if (ndifat > 0) difat_slots[[1]] else C$END), .cfb_u32(ndifat),
    .cfb_u32(c(fat_slots[seq_len(min(109L, nfat))], rep(C$FREE, max(0L, 109L - nfat))))
  )
  stopifnot(length(header) == 512L)
  out <- c(header, raw(ss - 512L), as.vector(M))
  if (identical(fault, "truncate")) out <- out[seq_len(floor(length(out) * 0.6))]
  if (identical(fault, "truncate_header")) out <- out[seq_len(100)]
  out
}

#' Write a compound file. Returns `path` invisibly. See `cfb_build()`.
cfb_write <- function(path, streams, ...) {
  writeBin(cfb_build(streams, ...), path)
  invisible(path)
}

# ---- the independent oracle (spec section 2) -------------------------------

#' The `ole1` content hash computed straight from the LOGICAL stream list.
ole1_expected <- function(streams) {
  paths <- names(streams)
  if (is.null(paths)) paths <- character(0)
  first <- vapply(strsplit(paths, "/", fixed = TRUE), function(p) p[[1]], character(1))
  last <- vapply(strsplit(paths, "/", fixed = TRUE), function(p) p[[length(p)]], character(1))
  keep <- tolower(first) != "msodatastore" & substr(last, 1, 1) != "\005"
  paths <- paths[keep]
  paths <- paths[order(paths, method = "radix")]
  parts <- lapply(paths, function(p) {
    b <- as.raw(streams[[p]])
    c(charToRaw(enc2utf8(p)), as.raw(0), .cfb_u64(length(b)), b)
  })
  digest::digest(as.raw(unlist(parts)), algo = "xxh3_128", serialize = FALSE)
}

# ---- a tiny independent parser, to check the writer ------------------------

#' Re-parse a built compound file and return its streams (named list of raw)
#' after asserting structural invariants. Test-side only.
cfb_parse_check <- function(bytes) {
  u32 <- function(off) sum(as.numeric(bytes[off + 1:4]) * 256^(0:3))
  stopifnot(identical(bytes[1:8], .cfb$magic))
  major <- sum(as.numeric(bytes[27:28]) * 256^(0:1))
  ss <- if (major == 3) 512 else 4096
  per <- ss / 4
  nfat <- u32(44); dir0 <- u32(48); mf0 <- u32(60); nmf <- u32(64)
  difat0 <- u32(68); ndifat <- u32(72)
  sector <- function(i) bytes[ss + i * ss + seq_len(ss)]
  stopifnot(length(bytes) %% ss == 0)
  fat_ids <- vapply(0:108, function(i) u32(76 + 4 * i), numeric(1))
  d <- difat0
  while (ndifat > 0 && d < .cfb$FATSECT) {
    s <- sector(d)
    v <- vapply(0:(per - 1), function(i) sum(as.numeric(s[4 * i + 1:4]) * 256^(0:3)), numeric(1))
    fat_ids <- c(fat_ids, v[-per]); d <- v[[per]]
  }
  fat_ids <- fat_ids[fat_ids < .cfb$DIFSECT]
  stopifnot(length(fat_ids) == nfat)
  rd32 <- function(raw_) vapply(seq_len(length(raw_) / 4) - 1, function(i)
    sum(as.numeric(raw_[4 * i + 1:4]) * 256^(0:3)), numeric(1))
  fat <- unlist(lapply(fat_ids, function(i) rd32(sector(i))))
  walk <- function(start, tbl) {
    out <- numeric(0); cur <- start
    while (cur < .cfb$DIFSECT) {
      stopifnot(!(cur %in% out), length(out) <= length(tbl))
      out <- c(out, cur); cur <- tbl[[cur + 1]]
    }
    stopifnot(cur == .cfb$END)
    out
  }
  read_chain <- function(start, tbl) {
    ch <- walk(start, tbl)
    do.call(c, lapply(ch, sector))
  }
  dirb <- read_chain(dir0, fat)
  n_ent <- length(dirb) / 128
  ent <- lapply(seq_len(n_ent) - 1, function(i) {
    e <- dirb[i * 128 + seq_len(128)]
    nl <- sum(as.numeric(e[65:66]) * c(1, 256))
    list(name = if (nl > 2) iconv(list(e[seq_len(nl - 2)]), "UTF-16LE", "UTF-8") else "",
         type = as.integer(e[67]), l = u32d(e, 69), r = u32d(e, 73), c = u32d(e, 77),
         start = u32d(e, 117), size = u32d(e, 121))
  })
  root <- ent[[1]]
  mini_stream <- if (root$size > 0) read_chain(root$start, fat)[seq_len(root$size)] else raw(0)
  minifat <- if (nmf > 0) rd32(read_chain(mf0, fat)) else numeric(0)
  data_of <- function(e) {
    if (e$size == 0) return(raw(0))
    if (e$size < 4096) {
      ch <- walk(e$start, minifat)
      do.call(c, lapply(ch, function(i) mini_stream[i * 64 + 1:64]))[seq_len(e$size)]
    } else read_chain(e$start, fat)[seq_len(e$size)]
  }
  out <- list()
  visit <- function(i, prefix) {
    if (i >= .cfb$FREE) return(invisible())
    e <- ent[[i + 1]]
    visit(e$l, prefix); visit(e$r, prefix)
    path <- if (nzchar(prefix)) paste0(prefix, "/", e$name) else e$name
    if (e$type == 2L) out[[path]] <<- data_of(e)
    if (e$type == 1L) visit(e$c, path)
  }
  visit(root$c, "")
  out
}
u32d <- function(e, off) sum(as.numeric(e[off + 0:3]) * 256^(0:3))
