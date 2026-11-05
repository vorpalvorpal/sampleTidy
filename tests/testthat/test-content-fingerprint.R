# Content fingerprints for OLE/CFB files (spec: sections 1-2).
#
# `content_fingerprint(path)` returns list(content_hash, content_hash_alg).
# The built-in `ole1` algorithm hashes the LOGICAL streams of a compound file
# (not the bytes), ignoring the parts a cloud file store rewrites: the root
# `MsoDataStore` storage and every `\005*` property-set stream. Fixtures are
# synthetic compound files built by `cfb_write()` (helper-cfb.R); the expected
# hash is computed by the independent oracle `ole1_expected()`.
#
# THE HELPER IS CHECKED FIRST (section 0): if the writer were wrong, every
# later test would be wrong in step with it.

# ---- fixtures -------------------------------------------------------------

cf_dir <- function(env = parent.frame()) withr::local_tempdir(.local_envir = env)

# A made-up legacy-Office-like stream set.
cf_base <- function() {
  list(
    "Workbook" = cfb_bytes(9000, 1),
    "\001CompObj" = cfb_bytes(113, 2),
    "\005SummaryInformation" = cfb_bytes(240, 3),
    "\005DocumentSummaryInformation" = cfb_bytes(180, 4),
    "_VBA_PROJECT_CUR/VBA/dir" = cfb_bytes(77, 5),
    "_VBA_PROJECT_CUR/VBA/Module1" = cfb_bytes(5200, 6),
    "Empty" = raw(0)
  )
}

cf_mso <- function(n = 3000, seed = 20) {
  list("MsoDataStore/Store1/Item" = cfb_bytes(n, seed),
       "MsoDataStore/Store1/Properties" = cfb_bytes(400, seed + 1))
}

cf_file <- function(dir, name, streams, ...) {
  path <- file.path(dir, name)
  cfb_write(path, streams, ...)
  path
}

cf_hash <- function(path) content_fingerprint(path)$content_hash

# Run with a wall-clock limit so a hang fails the test instead of the run.
cf_limited <- function(expr, secs = 30) {
  setTimeLimit(elapsed = secs, transient = TRUE)
  on.exit(setTimeLimit(elapsed = Inf, transient = FALSE), add = TRUE)
  expr
}

# ---- 0. the synthetic fixtures themselves ----------------------------------

test_that("cfb helper 0a: the writer's files re-parse to their logical streams (v3 and v4, every layout knob)", {
  st <- c(cf_base(), cf_mso(),
          list("S63" = cfb_bytes(63, 7), "S64" = cfb_bytes(64, 8), "S65" = cfb_bytes(65, 9),
               "S4095" = cfb_bytes(4095, 10), "S4096" = cfb_bytes(4096, 11),
               "S4097" = cfb_bytes(4097, 12), "A/B/C/Deep" = cfb_bytes(10, 13)))
  for (v in c(3L, 4L)) {
    for (knobs in list(list(), list(shuffle = TRUE), list(dir_shuffle = TRUE, dir_shape = "balanced"),
                       list(dir_shape = "left", extra_free = 5L, meta = TRUE, shuffle = TRUE),
                       list(junk_high_size = TRUE))) {
      bytes <- do.call(cfb_build, c(list(st, version = v), knobs))
      expect_identical(bytes[1:8], as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)))
      back <- cfb_parse_check(bytes)
      expect_setequal(names(back), names(st))
      for (n in names(st)) expect_identical(back[[n]], st[[n]], info = n)
    }
  }
})

test_that("cfb helper 0b: the writer is deterministic and the layout knobs change the bytes but not the content", {
  st <- cf_base()
  a <- cfb_build(st, seed = 3, shuffle = TRUE)
  expect_identical(a, cfb_build(st, seed = 3, shuffle = TRUE))
  expect_false(identical(a, cfb_build(st)))
  expect_false(identical(cfb_build(st, version = 3L), cfb_build(st, version = 4L)))
  expect_true(length(cfb_build(st, extra_free = 4L)) > length(cfb_build(st)))
})

test_that("cfb helper 0c: a file over ~7 MB in v3 needs DIFAT sectors, and still re-parses", {
  big <- list(Workbook = cfb_bytes(7.6e6, 1), Small = cfb_bytes(50, 2))
  bytes <- cfb_build(big, shuffle = TRUE)
  u32 <- function(off) sum(as.numeric(bytes[off + 1:4]) * 256^(0:3))
  expect_gt(u32(44), 109)        # FAT sectors
  expect_gte(u32(72), 1)         # DIFAT sectors
  back <- cfb_parse_check(bytes)
  expect_identical(back$Workbook, big$Workbook)
  expect_identical(back$Small, big$Small)
})

test_that("cfb helper 0d: the faults really are malformed, and the oracle follows spec section 2", {
  st <- cf_base()
  for (f in c("truncate", "truncate_header", "cycle", "bad_sector")) {
    expect_error(cfb_parse_check(cfb_build(st, fault = f)), info = f)
  }
  # Hand-computed: one root stream "ab" holding bytes 01 02.
  manual <- digest::digest(
    as.raw(c(0x61, 0x62, 0x00, 0x02, 0, 0, 0, 0, 0, 0, 0, 0x01, 0x02)),
    algo = "xxh3_128", serialize = FALSE)
  expect_identical(ole1_expected(list(ab = as.raw(1:2))), manual)
  # Exclusions and order independence.
  a <- ole1_expected(list(ab = as.raw(1:2), b = as.raw(3)))
  expect_identical(a, ole1_expected(list(b = as.raw(3), ab = as.raw(1:2))))
  expect_identical(a, ole1_expected(list(ab = as.raw(1:2), b = as.raw(3),
                                         "\005Summary" = as.raw(9), "msodatastore/x" = as.raw(8))))
  # If Python's olefile happens to be importable, cross-check; never required.
  py <- Sys.which("python3")
  if (nzchar(py) && identical(system2(py, c("-I", "-c", shQuote("import olefile")),
                                      stdout = FALSE, stderr = FALSE), 0L)) {
    path <- withr::local_tempfile(fileext = ".xls")
    cfb_write(path, cf_base())
    out <- system2(py, c("-I", "-c", shQuote(sprintf(
      "import olefile;o=olefile.OleFileIO(%s);print(len(o.listdir(streams=True)))", shQuote(path, "sh")))),
      stdout = TRUE)
    expect_identical(as.integer(out), length(cf_base()))
  }
})

# ---- 1. no fingerprinter matches ------------------------------------------

test_that("content_fingerprint 1: non-OLE inputs (csv, pdf-like, XML-format .xls, empty) give NA / NA without a warning", {
  dir <- cf_dir()
  files <- c(
    csv = st_test_write_file(dir, "a.csv", raw = charToRaw("a,b\n1,2\n")),
    pdf = st_test_write_file(dir, "b.pdf", raw = charToRaw("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n")),
    xml = st_test_write_file(dir, "c.xls", raw = charToRaw("<?xml version=\"1.0\"?>\n<Workbook></Workbook>\n")),
    empty = st_test_write_file(dir, "d.xls", raw = raw(0)),
    short = st_test_write_file(dir, "e.xls", raw = as.raw(c(0xD0, 0xCF, 0x11)))
  )
  for (nm in names(files)) {
    res <- expect_no_warning(content_fingerprint(files[[nm]]))
    expect_named(res, c("content_hash", "content_hash_alg"))
    expect_identical(res$content_hash, NA_character_, info = nm)
    expect_identical(res$content_hash_alg, NA_character_, info = nm)
  }
})

test_that("content_fingerprint 1b: dispatch is by magic, never by extension", {
  dir <- cf_dir()
  ole_named_csv <- cf_file(dir, "looks_like.csv", cf_base())
  res <- content_fingerprint(ole_named_csv)
  expect_identical(res$content_hash_alg, "ole1")
  expect_identical(res$content_hash, ole1_expected(cf_base()))
  txt_named_xls <- st_test_write_file(dir, "plain.xls", raw = charToRaw("just text"))
  expect_identical(content_fingerprint(txt_named_xls)$content_hash, NA_character_)
})

test_that("content_fingerprint 1c: a missing file aborts with sampletidy_error", {
  expect_error(content_fingerprint(file.path(cf_dir(), "nope.xls")), class = "sampletidy_error")
})

# ---- 2. the ole1 algorithm ------------------------------------------------

test_that("ole1 2a: an OLE file gets alg 'ole1' and the oracle's hash, v3 and v4, 32 lower-case hex", {
  dir <- cf_dir()
  for (v in c(3L, 4L)) {
    p <- cf_file(dir, sprintf("v%d.xls", v), cf_base(), version = v)
    res <- content_fingerprint(p)
    expect_identical(res$content_hash_alg, "ole1")
    expect_match(res$content_hash, "^[0-9a-f]{32}$")
    expect_identical(res$content_hash, ole1_expected(cf_base()), info = v)
  }
})

test_that("ole1 2b: .cfb_read_streams() returns EVERY stream (excluded ones too), nested paths, empty streams and size boundaries intact", {
  dir <- cf_dir()
  st <- c(cf_base(), cf_mso(),
          list("S1" = cfb_bytes(1, 1), "S63" = cfb_bytes(63, 7), "S64" = cfb_bytes(64, 8),
               "S65" = cfb_bytes(65, 9), "S4095" = cfb_bytes(4095, 10),
               "S4096" = cfb_bytes(4096, 11), "S4097" = cfb_bytes(4097, 12),
               "Store/Sub/Leaf" = cfb_bytes(5000, 13), "Store/Sub/Tiny" = cfb_bytes(3, 14)))
  for (v in c(3L, 4L)) {
    for (sh in c(FALSE, TRUE)) {
      p <- cf_file(dir, "rt.xls", st, version = v, shuffle = sh, dir_shuffle = sh,
                   dir_shape = if (sh) "balanced" else "chain", meta = sh)
      back <- sampleTidy:::.cfb_read_streams(p)
      expect_type(back, "list")
      expect_setequal(names(back), names(st))
      for (n in names(st)) {
        expect_identical(back[[n]], st[[n]], info = sprintf("v%d shuffle=%s %s", v, sh, n))
      }
    }
  }
})

test_that("ole1 2c: a v3 file over 7 MB (DIFAT sectors) reads back and hashes to the oracle", {
  dir <- cf_dir()
  st <- list(Workbook = cfb_bytes(7.6e6, 1), Small = cfb_bytes(100, 2),
             "\005SummaryInformation" = cfb_bytes(100, 3))
  p <- cf_file(dir, "big.xls", st, shuffle = TRUE)
  back <- sampleTidy:::.cfb_read_streams(p)
  expect_identical(back$Workbook, st$Workbook)
  expect_identical(back$Small, st$Small)
  expect_identical(cf_hash(p), ole1_expected(st))
})

test_that("ole1 2d: v3 ignores junk in the high 32 bits of a directory entry's stream size", {
  dir <- cf_dir()
  p <- cf_file(dir, "junk.xls", cf_base(), junk_high_size = TRUE)
  expect_identical(cf_hash(p), ole1_expected(cf_base()))
})

test_that("ole1 2e: MsoDataStore ADDED - the file grows and its byte hash changes, the content hash does not", {
  dir <- cf_dir()
  before <- cf_file(dir, "before.xls", cf_base())
  after <- cf_file(dir, "after.xls", c(cf_base(), cf_mso()))
  expect_gt(file.size(after), file.size(before))
  expect_false(identical(hash_file(before), hash_file(after)))
  expect_identical(cf_hash(before), cf_hash(after))
  expect_identical(cf_hash(after), ole1_expected(cf_base()))
})

test_that("ole1 2f: MsoDataStore CHANGED at the same size - bytes differ, content hash equal", {
  dir <- cf_dir()
  a <- cf_file(dir, "a.xls", c(cf_base(), cf_mso(3000, 20)))
  b <- cf_file(dir, "b.xls", c(cf_base(), cf_mso(3000, 99)))
  expect_equal(file.size(a), file.size(b))
  expect_false(identical(hash_file(a), hash_file(b)))
  expect_identical(cf_hash(a), cf_hash(b))
})

test_that("ole1 2g: property-set streams changed, added or removed do not change the hash", {
  dir <- cf_dir()
  base <- cf_base()
  h <- cf_hash(cf_file(dir, "base.xls", base))
  changed <- base
  changed[["\005SummaryInformation"]] <- cfb_bytes(240, 77)
  changed[["\005DocumentSummaryInformation"]] <- cfb_bytes(999, 78)
  expect_identical(cf_hash(cf_file(dir, "changed.xls", changed)), h)
  added <- c(base, list("\005Extra" = cfb_bytes(10, 5), "\005" = cfb_bytes(10, 6)))
  expect_identical(cf_hash(cf_file(dir, "added.xls", added)), h)
  removed <- base[setdiff(names(base), c("\005SummaryInformation", "\005DocumentSummaryInformation"))]
  expect_identical(cf_hash(cf_file(dir, "removed.xls", removed)), h)
})

test_that("ole1 2h: a kept byte changed, a stream renamed, a stream moved to another storage, a stream removed or added all change the hash", {
  dir <- cf_dir()
  base <- cf_base()
  h <- cf_hash(cf_file(dir, "base.xls", base))

  flipped <- base
  flipped$Workbook[4000] <- as.raw(bitwXor(as.integer(flipped$Workbook[4000]), 1L))
  h_flip <- cf_hash(cf_file(dir, "flip.xls", flipped))
  expect_false(identical(h_flip, h))

  renamed <- base
  names(renamed)[names(renamed) == "Workbook"] <- "Book"
  h_ren <- cf_hash(cf_file(dir, "ren.xls", renamed))

  moved <- base
  names(moved)[names(moved) == "Workbook"] <- "Other/Workbook"
  h_mov <- cf_hash(cf_file(dir, "mov.xls", moved))

  removed <- base[names(base) != "\001CompObj"]
  h_rem <- cf_hash(cf_file(dir, "rem.xls", removed))

  added <- c(base, list("NewStream" = raw(0)))
  h_add <- cf_hash(cf_file(dir, "add.xls", added))

  emptied <- base
  emptied$Empty <- as.raw(0)         # an empty stream becomes a one-byte stream
  h_emp <- cf_hash(cf_file(dir, "emp.xls", emptied))

  all_h <- c(h, h_flip, h_ren, h_mov, h_rem, h_add, h_emp)
  expect_false(anyDuplicated(all_h) > 0)
  expect_identical(h_ren, ole1_expected(renamed))
  expect_identical(h_mov, ole1_expected(moved))
  expect_identical(h_add, ole1_expected(added))
})

test_that("ole1 2i: the same logical streams give the same hash whatever the physical layout", {
  dir <- cf_dir()
  st <- c(cf_base(), list("S4095" = cfb_bytes(4095, 10), "S4096" = cfb_bytes(4096, 11),
                          "S4097" = cfb_bytes(4097, 12)))
  want <- ole1_expected(st)
  layouts <- list(
    list(), list(version = 4L), list(shuffle = TRUE, seed = 5), list(shuffle = TRUE, seed = 6, version = 4L),
    list(dir_shuffle = TRUE, dir_shape = "balanced", seed = 7), list(dir_shape = "left"),
    list(extra_free = 9L), list(meta = TRUE, seed = 8),
    list(shuffle = TRUE, dir_shuffle = TRUE, extra_free = 4L, meta = TRUE, seed = 9)
  )
  for (i in seq_along(layouts)) {
    p <- do.call(cf_file, c(list(dir, sprintf("l%d.xls", i), st), layouts[[i]]))
    expect_identical(cf_hash(p), want, info = paste(names(layouts[[i]]), collapse = ","))
  }
  # ... and the permuted stream ORDER in the list does not matter either.
  p <- cf_file(dir, "rev.xls", rev(st))
  expect_identical(cf_hash(p), want)
})

test_that("ole1 2j: 'MsoDataStore' matches case-insensitively and only as the FIRST path component", {
  dir <- cf_dir()
  base <- cf_base()
  h <- ole1_expected(base)
  for (nm in c("msodatastore", "MSODATASTORE", "MsoDataStore")) {
    st <- c(base, setNames(list(cfb_bytes(500, 1), cfb_bytes(50, 2)), c(paste0(nm, "/a"), paste0(nm, "/b/c"))))
    expect_identical(cf_hash(cf_file(dir, "x.xls", st)), h, info = nm)
  }
  # Deeper in the tree, or a different name, it is an ordinary stream.
  nested <- c(base, list("Sub/MsoDataStore/a" = cfb_bytes(50, 3)))
  expect_identical(cf_hash(cf_file(dir, "n.xls", nested)), ole1_expected(nested))
  expect_false(identical(ole1_expected(nested), h))
  near <- c(base, list("MsoDataStore2/a" = cfb_bytes(50, 4)))
  expect_identical(cf_hash(cf_file(dir, "near.xls", near)), ole1_expected(near))
  expect_false(identical(ole1_expected(near), h))
})

test_that("ole1 2k: a \\005 stream nested inside a storage is excluded; \\001CompObj and a mid-name \\005 are kept", {
  dir <- cf_dir()
  base <- cf_base()
  h <- ole1_expected(base)
  nested005 <- c(base, list("Sub/\005Props" = cfb_bytes(60, 1), "Sub/Deeper/\005More" = cfb_bytes(60, 2)))
  expect_identical(cf_hash(cf_file(dir, "n5.xls", nested005)), h)
  # \001CompObj is kept: removing it changes the hash.
  expect_false(identical(cf_hash(cf_file(dir, "nc.xls", base[names(base) != "\001CompObj"])), h))
  # \005 not at the start of the name does not exclude.
  mid <- c(base, list("Pro\005ps" = cfb_bytes(60, 3)))
  expect_identical(cf_hash(cf_file(dir, "mid.xls", mid)), ole1_expected(mid))
  expect_false(identical(ole1_expected(mid), h))
})

test_that("ole1 2l: an empty storage is invisible; non-ASCII stream names hash as UTF-8", {
  dir <- cf_dir()
  base <- cf_base()
  p <- cf_file(dir, "es.xls", base, empty_storages = c("Hollow", "Hollow/Inner"))
  expect_identical(cf_hash(p), ole1_expected(base))
  uni <- c(base, setNames(list(cfb_bytes(30, 1)), "Café/über"))
  expect_identical(cf_hash(cf_file(dir, "uni.xls", uni)), ole1_expected(uni))
})

# ---- 3. malformed files ---------------------------------------------------

test_that("ole1 3: a malformed container (truncated, cyclic chain, wild sector) gives NA / NA with a warning naming the file, and never hangs", {
  dir <- cf_dir()
  st <- list(Workbook = cfb_bytes(20000, 1), Small = cfb_bytes(50, 2))
  for (fault in c("truncate", "truncate_header", "cycle", "bad_sector")) {
    p <- cf_file(dir, sprintf("bad_%s.xls", fault), st, fault = fault)
    res <- NULL
    expect_warning(res <- cf_limited(content_fingerprint(p)), sprintf("bad_%s", fault), info = fault)
    expect_identical(res$content_hash, NA_character_, info = fault)
    expect_identical(res$content_hash_alg, NA_character_, info = fault)
    expect_error(cf_limited(sampleTidy:::.cfb_read_streams(p)), class = "sampletidy_error", info = fault)
  }
  # Just the magic and nothing else.
  p <- st_test_write_file(dir, "magic_only.xls", raw = as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1)))
  expect_warning(res <- content_fingerprint(p), "magic_only")
  expect_identical(res$content_hash, NA_character_)
})

# ---- 4. the fingerprinter registry ----------------------------------------

cf_pdf_fp <- function(value = "cafe0123") {
  list(pdfx = list(magic = charToRaw("%PDF"), fun = function(path) value))
}

test_that("registry 4a: the default config is NULL and the key is list-valued (env-var form refused)", {
  withr::local_options(list("sampletidy.content_fingerprinters" = NULL))
  expect_null(st_config("content_fingerprinters"))
  expect_true("content_fingerprinters" %in% sampleTidy:::.st_config_list_keys)
  withr::with_envvar(c(SAMPLETIDY_CONTENT_FINGERPRINTERS = "pdfx"), {
    expect_error(st_config("content_fingerprinters"), class = "sampletidy_error")
  })
})

test_that("registry 4b: a configured fingerprinter is used for its magic, named as the algorithm, and receives the path; built-ins still work", {
  dir <- cf_dir()
  seen <- new.env()
  withr::local_options(list("sampletidy.content_fingerprinters" = list(
    pdfx = list(magic = charToRaw("%PDF"), fun = function(path) { seen$path <- path; "cafe0123" }))))
  pdf <- st_test_write_file(dir, "r.pdf", raw = charToRaw("%PDF-1.7 synthetic"))
  res <- content_fingerprint(pdf)
  expect_identical(res$content_hash, "cafe0123")
  expect_identical(res$content_hash_alg, "pdfx")
  expect_identical(normalizePath(seen$path), normalizePath(pdf))
  # unrelated bytes: still no match
  csv <- st_test_write_file(dir, "r.csv", raw = charToRaw("a,b\n1,2\n"))
  expect_identical(content_fingerprint(csv)$content_hash, NA_character_)
  # the built-in is still there alongside
  ole <- cf_file(dir, "o.xls", cf_base())
  expect_identical(content_fingerprint(ole)$content_hash_alg, "ole1")
  expect_identical(content_fingerprint(ole)$content_hash, ole1_expected(cf_base()))
})

test_that("registry 4c: a file shorter than the magic does not match", {
  dir <- cf_dir()
  withr::local_options(list("sampletidy.content_fingerprinters" = cf_pdf_fp()))
  short <- st_test_write_file(dir, "s.pdf", raw = charToRaw("%PD"))
  expect_identical(content_fingerprint(short)$content_hash, NA_character_)
})

test_that("registry 4d: a config entry named like a built-in replaces it; config entries are tried first, in list order", {
  dir <- cf_dir()
  ole <- cf_file(dir, "o.xls", cf_base())
  ole_magic <- as.raw(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))

  withr::local_options(list("sampletidy.content_fingerprinters" = list(
    ole1 = list(magic = ole_magic, fun = function(path) "00ff00ff"))))
  res <- content_fingerprint(ole)
  expect_identical(res$content_hash, "00ff00ff")
  expect_identical(res$content_hash_alg, "ole1")

  # A differently named entry with a matching magic wins over the built-in ...
  withr::local_options(list("sampletidy.content_fingerprinters" = list(
    mine = list(magic = ole_magic[1:4], fun = function(path) "11"),
    other = list(magic = ole_magic[1:2], fun = function(path) "22"))))
  res <- content_fingerprint(ole)
  expect_identical(res$content_hash_alg, "mine")      # ... and the first listed wins
  expect_identical(res$content_hash, "11")
})

test_that("registry 4e: an invalid config aborts with sampletidy_error when content_fingerprinters is used", {
  dir <- cf_dir()
  f <- st_test_write_file(dir, "a.csv", raw = charToRaw("a,b\n"))
  good_fun <- function(path) "ab"
  bad <- list(
    "not a list"       = "pdfx",
    "unnamed"          = list(list(magic = charToRaw("%PDF"), fun = good_fun)),
    "duplicate names"  = list(a = list(magic = charToRaw("%PDF"), fun = good_fun),
                              a = list(magic = charToRaw("%PS"), fun = good_fun)),
    "element not list" = list(a = "x"),
    "missing magic"    = list(a = list(fun = good_fun)),
    "empty magic"      = list(a = list(magic = raw(0), fun = good_fun)),
    "character magic"  = list(a = list(magic = "%PDF", fun = good_fun)),
    "missing fun"      = list(a = list(magic = charToRaw("%PDF"))),
    "fun not function" = list(a = list(magic = charToRaw("%PDF"), fun = "f"))
  )
  for (nm in names(bad)) {
    withr::with_options(list("sampletidy.content_fingerprinters" = bad[[nm]]), {
      expect_error(content_fingerprint(f), class = "sampletidy_error", info = nm)
    })
  }
})

test_that("registry 4f: a fun that errors or returns anything but one non-NA string gives NA / NA and a warning naming the file", {
  dir <- cf_dir()
  pdf <- st_test_write_file(dir, "named_here.pdf", raw = charToRaw("%PDF-1.4 synthetic"))
  funs <- list(
    errors = function(path) stop("boom"),
    na = function(path) NA_character_,
    two = function(path) c("a", "b"),
    number = function(path) 42,
    null = function(path) NULL,
    empty = function(path) character(0)
  )
  for (nm in names(funs)) {
    withr::with_options(list("sampletidy.content_fingerprinters" = list(
      pdfx = list(magic = charToRaw("%PDF"), fun = funs[[nm]]))), {
      res <- NULL
      expect_warning(res <- content_fingerprint(pdf), "named_here", info = nm)
      expect_identical(res$content_hash, NA_character_, info = nm)
      expect_identical(res$content_hash_alg, NA_character_, info = nm)
    })
  }
})
