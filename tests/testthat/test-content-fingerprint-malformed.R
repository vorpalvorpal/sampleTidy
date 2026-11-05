# Hardening of the OLE reader against malformed or hostile compound files
# (spec addendum 2026-11-05 evening, R2-R7). Every bad file must give NA / NA
# with a warning from `content_fingerprint()` and a `sampletidy_error` from
# `.cfb_read_streams()`, never a wrong hash, a hang or a memory blow-up.
# Fixtures are synthetic: valid files from `cfb_build()` with a few bytes
# patched by the `cfb_*` patch helpers in helper-cfb.R.

mf_dir <- function(env = parent.frame()) withr::local_tempdir(.local_envir = env)

mf_limited <- function(expr, secs = 60) {
  setTimeLimit(elapsed = secs, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)
  expr
}

mf_write <- function(dir, name, bytes) {
  p <- file.path(dir, name)
  writeBin(bytes, p)
  p
}

# The file must be refused: NA / NA plus a warning naming it, and an abort
# from the reader itself.
expect_refused <- function(path, info = NULL) {
  res <- NULL
  expect_warning(res <- mf_limited(content_fingerprint(path)), basename(path), fixed = TRUE, info = info)
  expect_identical(res$content_hash, NA_character_, info = info)
  expect_identical(res$content_hash_alg, NA_character_, info = info)
  expect_error(mf_limited(sampleTidy:::.cfb_read_streams(path)), class = "sampletidy_error", info = info)
}

# A fixture whose directory, MiniFAT and mini stream chains are each at least
# 8 sectors (4096 bytes), so a regular stream can be pointed at any of them.
mf_overlap_streams <- function() {
  mini <- setNames(lapply(1:22, function(i) cfb_bytes(3000, i)), sprintf("M%02d", 1:22))
  empty <- setNames(rep(list(raw(0)), 12), sprintf("z%02d", 1:12))
  c(mini, empty, list(Big = cfb_bytes(5000, 99)))
}

# ---- control: the patch helpers leave a valid file valid -----------------------

test_that("malformed 0: the unpatched fixtures read back to the oracle hash (so a refusal below is the patch's doing)", {
  dir <- mf_dir()
  st <- mf_overlap_streams()
  b <- cfb_build(st, 3L)
  expect_gte(cfb_get_entry(b, 0)$size, 4096)                 # mini stream long enough
  p <- mf_write(dir, "ok.xls", b)
  expect_identical(content_fingerprint(p)$content_hash, ole1_expected(st))
  # entry lookup and a no-op patch round-trip
  i <- cfb_entry_index(b, "Big", 64L)
  b2 <- cfb_set_entry(b, i, start = cfb_get_entry(b, i)$start, size = cfb_get_entry(b, i)$size)
  expect_identical(b2, b)
})

# ---- R2. shared / overlapping chains --------------------------------------

test_that("R2a: two directory entries sharing one regular-sector chain are refused", {
  dir <- mf_dir()
  st <- list(A = cfb_bytes(5000, 1), B = cfb_bytes(5000, 2), Small = cfb_bytes(50, 3))
  b <- cfb_build(st, 3L)
  a <- cfb_get_entry(b, cfb_entry_index(b, "A"))
  b <- cfb_set_entry(b, cfb_entry_index(b, "B"), start = a$start, size = a$size)
  expect_refused(mf_write(dir, "shared_reg.xls", b))
})

test_that("R2b: two directory entries sharing one mini-sector chain are refused", {
  dir <- mf_dir()
  st <- list(A = cfb_bytes(300, 1), B = cfb_bytes(300, 2), Other = cfb_bytes(9000, 3))
  b <- cfb_build(st, 3L)
  a <- cfb_get_entry(b, cfb_entry_index(b, "A"))
  b <- cfb_set_entry(b, cfb_entry_index(b, "B"), start = a$start, size = a$size)
  expect_refused(mf_write(dir, "shared_mini.xls", b))
})

test_that("R2c: a stream whose chain runs into another stream's chain is refused", {
  dir <- mf_dir()
  st <- list(A = cfb_bytes(5000, 1), B = cfb_bytes(5000, 2))
  b <- cfb_build(st, 3L)
  a <- cfb_get_entry(b, cfb_entry_index(b, "A"))
  bb <- cfb_get_entry(b, cfb_entry_index(b, "B"))
  last_a <- utils::tail(cfb_fat_chain(b, a$start), 1)
  b <- cfb_wr32(b, cfb_fat_slot(b, last_a), bb$start)         # A's chain now enters B's
  expect_refused(mf_write(dir, "enters.xls", b))
})

test_that("R2d: a stream chain overlapping the directory, MiniFAT or mini stream chain is refused", {
  dir <- mf_dir()
  b <- cfb_build(mf_overlap_streams(), 3L)
  big <- cfb_entry_index(b, "Big", 64L)
  targets <- list(directory = cfb_rd32(b, 48), minifat = cfb_rd32(b, 60), mini_stream = cfb_get_entry(b, 0)$start)
  for (nm in names(targets)) {
    patched <- cfb_set_entry(b, big, start = targets[[nm]], size = 4096)
    expect_refused(mf_write(dir, sprintf("overlap_%s.xls", nm), patched), info = nm)
  }
})

test_that("R2e: hundreds of entries sharing one chain in a ~1 MB file fail fast, without large memory use", {
  skip_on_cran()
  dir <- mf_dir()
  n <- 400
  st <- c(list(Big = cfb_bytes(1e6, 1)), setNames(rep(list(raw(0)), n), sprintf("e%04d", seq_len(n))))
  b <- cfb_build(st, 3L, dir_shape = "balanced")
  big <- cfb_get_entry(b, cfb_entry_index(b, "Big", n + 2L))
  for (i in seq_len(n)) b <- cfb_set_entry(b, cfb_entry_index(b, sprintf("e%04d", i), n + 2L), start = big$start, size = big$size)
  p <- mf_write(dir, "crafted.xls", b)
  expect_lt(file.size(p), 1.2e6)

  invisible(gc(reset = TRUE))
  before <- gc()[2, 2]
  elapsed <- system.time(expect_refused(p))[["elapsed"]]
  peak <- gc()[2, ncol(gc())] - before                                # Mb of vector heap
  expect_lt(elapsed, 5)
  expect_lt(peak, 150)                                       # 400 copies of 1 MB would be 400 Mb
})

# ---- R3. DIFAT termination --------------------------------------------------

cf_hash_mf <- function(path) content_fingerprint(path)$content_hash
# DIFAT sector chain, from the header (valid files only).
cfb_difat_chain <- function(b) {
  out <- numeric(0); cur <- cfb_rd32(b, 68)
  for (k in seq_len(cfb_rd32(b, 72))) { out <- c(out, cur); cur <- cfb_rd32(b, 512 * (cur + 1) + 508) }
  out
}

mf_difat_streams <- function() list(Workbook = cfb_bytes(7.3e6, 1), Small = cfb_bytes(100, 2))

test_that("R3a: a >7 MB v3 file (DIFAT in use) reads and hashes to the oracle, whether the last DIFAT pointer is ENDOFCHAIN or FREESECT", {
  skip_on_cran()
  dir <- mf_dir()
  st <- mf_difat_streams()
  b <- cfb_build(st, 3L)
  expect_gt(cfb_rd32(b, 72), 0)                                # the header says DIFAT sectors exist
  expect_gt(cfb_rd32(b, 44), 109)
  want <- ole1_expected(st)
  expect_identical(cf_hash_mf(mf_write(dir, "end.xls", b)), want)

  last_difat <- utils::tail(cfb_difat_chain(b), 1)
  free <- cfb_wr32(b, 512 * (last_difat + 1) + 508, .cfb$FREE)
  expect_identical(cf_hash_mf(mf_write(dir, "free.xls", free)), want)
  expect_identical(names(sampleTidy:::.cfb_read_streams(file.path(dir, "free.xls"))) |> sort(), sort(names(st)))
})

test_that("R3b: a DIFAT pointer that is out of range, or revisits a sector, before the header count is reached is refused", {
  skip_on_cran()
  dir <- mf_dir()
  b <- cfb_build(mf_difat_streams(), 3L)
  d1 <- cfb_rd32(b, 68)
  b2 <- cfb_wr32(b, 72, 2)                                     # the header claims two DIFAT sectors
  loop <- cfb_wr32(b2, 512 * (d1 + 1) + 508, d1)               # ... but the first points at itself
  wild <- cfb_wr32(b2, 512 * (d1 + 1) + 508, length(b) / 512 + 1000)
  expect_refused(mf_write(dir, "difat_loop.xls", loop), info = "revisit")
  expect_refused(mf_write(dir, "difat_wild.xls", wild), info = "out of range")
})

# ---- R4. the header's FAT sector list ---------------------------------------

test_that("R4: an invalid entry among the first nfat header DIFAT entries is refused, never filtered out and shifted", {
  dir <- mf_dir()
  st <- list(Workbook = cfb_bytes(100000, 1), Small = cfb_bytes(100, 2))
  b <- cfb_build(st, 3L)
  expect_gte(cfb_rd32(b, 44), 2)                                # at least two FAT sectors
  good0 <- cfb_rd32(b, 76); good1 <- cfb_rd32(b, 80)
  expect_identical(content_fingerprint(mf_write(dir, "ok.xls", b))$content_hash, ole1_expected(st))
  total <- length(b) / 512
  cases <- list(
    second_free   = cfb_wr32(b, 80, .cfb$FREE),
    second_wild   = cfb_wr32(b, 80, total + 500),
    second_fatsect = cfb_wr32(b, 80, .cfb$FATSECT),
    first_free_shifts = cfb_wr32(cfb_wr32(b, 76, .cfb$FREE), 80, good0),   # [FREE, good0]: a filter would make it [good0]
    first_wild    = cfb_wr32(b, 76, total + 500)
  )
  for (nm in names(cases)) expect_refused(mf_write(dir, paste0(nm, ".xls"), cases[[nm]]), info = nm)
  expect_true(good1 != good0)
})

# ---- R5. empty directory entry names --------------------------------------

test_that("R5: a stream or storage directory entry with an empty name is refused", {
  dir <- mf_dir()
  st <- list(A = cfb_bytes(10, 1), B = cfb_bytes(10, 2), "S/C" = cfb_bytes(10, 3))
  b <- cfb_build(st, 3L)
  for (target in c("B", "S")) {                                  # a stream, and a storage
    i <- cfb_entry_index(b, target, 8L)
    o <- cfb_dir_off(b, i)
    zero_len <- b; zero_len[o + 65:66] <- as.raw(c(0, 0)); zero_len[o + 1:64] <- raw(64)
    terminator_only <- b; terminator_only[o + 65:66] <- as.raw(c(2, 0)); terminator_only[o + 1:64] <- raw(64)
    expect_refused(mf_write(dir, sprintf("empty_len0_%s.xls", target), zero_len), info = paste(target, "length 0"))
    expect_refused(mf_write(dir, sprintf("empty_len2_%s.xls", target), terminator_only), info = paste(target, "length 2"))
  }
})

# ---- R6. mini-stream cutoff -----------------------------------------------

test_that("R6: a mini-stream cutoff other than 4096 is refused", {
  dir <- mf_dir()
  st <- list(Workbook = cfb_bytes(9000, 1), Small = cfb_bytes(1000, 2))
  b <- cfb_build(st, 3L)
  expect_identical(cfb_rd32(b, 56), 4096)
  for (cut in c(512, 1000, 8192, 0)) {
    expect_refused(mf_write(dir, sprintf("cut%d.xls", cut), cfb_wr32(b, 56, cut)), info = as.character(cut))
  }
})

# ---- R7. memory -----------------------------------------------------------

test_that("R7: reading a valid ~7 MB file needs only a small multiple of its size in extra memory", {
  skip_on_cran()
  dir <- mf_dir()
  b <- cfb_build(list(Workbook = cfb_bytes(7e6, 1), Small = cfb_bytes(100, 2)), 3L)
  p <- mf_write(dir, "big.xls", b)
  size_mb <- file.size(p) / 1024^2
  rm(b)
  invisible(gc(reset = TRUE))
  before <- gc()[2, 2]                                           # Mb of vector heap in use
  streams <- sampleTidy:::.cfb_read_streams(p)
  peak <- gc()[2, ncol(gc())] - before                                    # peak Mb since the reset
  expect_length(streams, 2L)
  expect_lt(peak, 15 * size_mb)
})
