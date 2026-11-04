# Launcher app for the launchd auto-import job (dev/launchd/helper/).
#
# Under launchd, macOS TCC refuses /bin/bash access to the OneDrive File Provider folder, so
# launchd runs a tiny signed app that SPAWNS dev/auto-import.sh as a child (posix_spawn + wait,
# never exec: after exec the process would be /bin/bash again and lose the access grant).
# These tests pin the launcher's contract, build.sh's bundle, and install.sh's argument handling.
# Everything runs in temp dirs with fake scripts: no ~/Applications, no ~/Library/LaunchAgents,
# no real launchctl, no database, no OneDrive.

# ---- helpers -------------------------------------------------------------------

lh_launchd_dir <- function() normalizePath(testthat::test_path("..", "..", "dev", "launchd"), mustWork = TRUE)

lh_skip <- function() {
  skip_on_os(c("windows", "linux", "solaris"))
  skip_if(Sys.which("xcrun") == "", "xcrun not available")
  skip_if(system2("xcrun", c("--find", "clang"), stdout = FALSE, stderr = FALSE) != 0, "xcrun clang not available")
}

lh_bash <- function(args, env = character(), wd = NULL, timeout = 60) {
  processx::run("/bin/bash", args, env = c("current", env), wd = wd, error_on_status = FALSE, timeout = timeout)
}

lh_build <- function(script, out) lh_bash(c(file.path(lh_launchd_dir(), "helper", "build.sh"), script, out))

# One app per file: the script path is compiled in, so tests rewrite the contents of a fixed
# script path instead of rebuilding. Built lazily so a missing build.sh is a test FAILURE.
lh <- new.env()
lh_app <- function() {
  if (is.null(lh$exe)) {
    lh$dir <- tempfile("lh-")
    dir.create(lh$dir)
    withr::defer(unlink(lh$dir, recursive = TRUE), testthat::teardown_env())
    lh$script <- file.path(lh$dir, "run.sh")
    writeLines("exit 0", lh$script)
    app <- file.path(lh$dir, "Test.app")
    res <- lh_build(lh$script, app)
    exe <- file.path(app, "Contents", "MacOS", "sampletidy-autoimport")
    if (res$status != 0L || !file.exists(exe)) {
      stop("launcher app was not built (build.sh status ", res$status, "): ", res$stderr, call. = FALSE)
    }
    lh$exe <- exe
  }
  lh$exe
}

lh_set_script <- function(...) {
  lh_app()
  writeLines(c(...), lh$script)
  invisible(lh$script)
}

lh_run <- function(args = character(), env = character(), wd = NULL) {
  processx::run(lh_app(), args, env = c("current", env), wd = wd, error_on_status = FALSE, timeout = 20)
}

lh_wait_for <- function(path, timeout = 10) {
  t0 <- Sys.time()
  while (!file.exists(path) && as.numeric(Sys.time() - t0, units = "secs") < timeout) Sys.sleep(0.05)
  file.exists(path)
}

# ---- launcher behaviour --------------------------------------------------------

test_that("the launcher exits with the script's exit status", {
  lh_skip()
  for (rc in c(0L, 3L, 7L)) {
    lh_set_script(sprintf("exit %d", rc))
    expect_equal(lh_run()$status, rc, info = paste("script exit", rc))
  }
})

test_that("the launcher ignores its own arguments and runs only the built script", {
  lh_skip()
  out <- withr::local_tempfile()
  lh_set_script(sprintf('echo "$#" > "%s"', out))
  res <- lh_run(c("/bin/echo", "other-script.sh", "--flag"))
  expect_equal(res$status, 0L)
  expect_equal(trimws(readLines(out)), "0")
})

test_that("the script inherits the environment and working directory", {
  lh_skip()
  out <- withr::local_tempfile()
  wd <- withr::local_tempdir()
  lh_set_script(sprintf('{ echo "$LH_TEST_VAR"; pwd -P; } > "%s"', out))
  res <- lh_run(env = c(LH_TEST_VAR = "inherited-value"), wd = wd)
  expect_equal(res$status, 0L)
  got <- readLines(out)
  expect_equal(got[1], "inherited-value")
  expect_equal(normalizePath(got[2]), normalizePath(wd))
})

test_that("the script is a child of the launcher (spawned, not exec'd)", {
  lh_skip()
  out <- withr::local_tempfile()
  lh_set_script(sprintf('echo "$PPID" > "%s"', out))
  p <- processx::process$new(lh_app(), env = c("current"), stdout = "|", stderr = "|")
  withr::defer(if (p$is_alive()) p$kill())
  p$wait(15000)
  expect_true(lh_wait_for(out))
  expect_equal(as.integer(readLines(out)), p$get_pid())
  expect_equal(p$get_exit_status(), 0L)
})

test_that("SIGTERM is forwarded to a script that traps it, and its status is returned", {
  lh_skip()
  ready <- withr::local_tempfile()
  marker <- withr::local_tempfile()
  lh_set_script(
    sprintf('trap \'echo got-term > "%s"; exit 5\' TERM', marker),
    sprintf('echo ready > "%s"', ready),
    "while :; do sleep 0.1; done"
  )
  p <- processx::process$new(lh_app(), stdout = "|", stderr = "|")
  withr::defer(if (p$is_alive()) p$kill())
  expect_true(lh_wait_for(ready), info = "script never started")
  p$signal(tools::SIGTERM)
  p$wait(10000)
  expect_false(p$is_alive(), info = "launcher did not exit after SIGTERM")
  expect_true(file.exists(marker), info = "SIGTERM did not reach the script")
  expect_equal(p$get_exit_status(), 5L)
})

test_that("a script killed by SIGTERM makes the launcher exit 128 + 15", {
  lh_skip()
  ready <- withr::local_tempfile()
  lh_set_script(sprintf('echo ready > "%s"', ready), "exec sleep 30")
  p <- processx::process$new(lh_app(), stdout = "|", stderr = "|")
  withr::defer(if (p$is_alive()) p$kill())
  expect_true(lh_wait_for(ready), info = "script never started")
  p$signal(tools::SIGTERM)
  p$wait(10000)
  expect_false(p$is_alive(), info = "launcher did not exit after SIGTERM")
  expect_equal(p$get_exit_status(), 143L)
})

# ---- build.sh ------------------------------------------------------------------

test_that("build.sh rejects a relative script path with exit 2", {
  lh_skip()
  d <- withr::local_tempdir()
  writeLines("exit 0", file.path(d, "s.sh"))
  res <- lh_bash(c(file.path(lh_launchd_dir(), "helper", "build.sh"), "s.sh", file.path(d, "Out.app")), wd = d)
  expect_equal(res$status, 2L)
  expect_match(res$stderr, "\\S")
  expect_false(dir.exists(file.path(d, "Out.app")))
})

test_that("build.sh rejects a script that does not exist with exit 2", {
  lh_skip()
  d <- withr::local_tempdir()
  res <- lh_build(file.path(d, "missing.sh"), file.path(d, "Out.app"))
  expect_equal(res$status, 2L)
  expect_match(res$stderr, "\\S")
  expect_false(dir.exists(file.path(d, "Out.app")))
})

test_that("build.sh rejects a script path containing a double quote or backslash with exit 2", {
  lh_skip()
  d <- withr::local_tempdir()
  for (bad in c('quo"te.sh', "back\\slash.sh")) {
    path <- file.path(d, bad)
    writeLines("exit 0", path)
    res <- lh_build(path, file.path(d, "Out.app"))
    expect_equal(res$status, 2L, info = bad)
    expect_false(dir.exists(file.path(d, "Out.app")), info = bad)
  }
})

test_that("build.sh builds a signed bundle with the documented Info.plist", {
  lh_skip()
  d <- withr::local_tempdir()
  script <- file.path(d, "s.sh")
  writeLines("exit 0", script)
  app <- file.path(d, "Bundle.app")
  res <- lh_build(script, app)
  expect_equal(res$status, 0L, info = res$stderr)
  expect_equal(normalizePath(trimws(res$stdout)), normalizePath(app))

  exe <- file.path(app, "Contents", "MacOS", "sampletidy-autoimport")
  expect_true(file.exists(exe))
  expect_true(file.access(exe, 1) == 0)
  info <- file.path(app, "Contents", "Info.plist")
  expect_true(file.exists(info))
  expect_equal(processx::run("plutil", c("-lint", "-s", info), error_on_status = FALSE)$status, 0L)

  pb <- function(key) trimws(processx::run("/usr/libexec/PlistBuddy", c("-c", paste0("Print :", key), info), error_on_status = FALSE)$stdout)
  expect_equal(pb("CFBundleIdentifier"), "net.robinshannon.sampletidy-autoimport")
  expect_equal(pb("CFBundleName"), "sampleTidy auto-import")
  expect_equal(pb("CFBundleDisplayName"), "sampleTidy auto-import")
  expect_equal(pb("CFBundleExecutable"), "sampletidy-autoimport")
  expect_equal(pb("CFBundlePackageType"), "APPL")
  expect_equal(pb("CFBundleVersion"), "1")
  expect_equal(pb("LSUIElement"), "true")

  v <- processx::run("codesign", c("--verify", "--strict", app), error_on_status = FALSE)
  expect_equal(v$status, 0L, info = v$stderr)
  dv <- processx::run("codesign", c("-dv", app), error_on_status = FALSE)
  expect_match(paste(dv$stdout, dv$stderr), "Identifier=net\\.robinshannon\\.sampletidy-autoimport")
})

test_that("rebuilding over an existing app removes stale files", {
  lh_skip()
  d <- withr::local_tempdir()
  script <- file.path(d, "s.sh")
  writeLines("exit 0", script)
  app <- file.path(d, "Bundle.app")
  expect_equal(lh_build(script, app)$status, 0L)
  stray <- file.path(app, "Contents", "stray.txt")
  dir.create(dirname(stray), recursive = TRUE, showWarnings = FALSE)
  writeLines("stale", stray)
  res <- lh_build(script, app)
  expect_equal(res$status, 0L, info = res$stderr)
  expect_false(file.exists(stray))
  expect_equal(processx::run("codesign", c("--verify", "--strict", app), error_on_status = FALSE)$status, 0L)
})

# ---- install.sh and the plist template -----------------------------------------

test_that("the plist template runs the helper, not /bin/bash", {
  tmpl <- readLines(file.path(lh_launchd_dir(), "net.robinshannon.sampletidy-autoimport.plist"), warn = FALSE)
  txt <- paste(tmpl, collapse = "\n")
  m <- regmatches(txt, regexpr("<key>ProgramArguments</key>\\s*<array>.*?</array>", txt))
  expect_length(m, 1L)
  expect_match(m, "<string>@HELPER@</string>", fixed = TRUE)
  expect_no_match(m, "/bin/bash", fixed = TRUE)
  expect_equal(lengths(regmatches(m, gregexpr("<string>", m))), 1L)
})

test_that("install.sh rejects unknown arguments with exit 2 and never calls launchctl", {
  lh_skip()
  d <- withr::local_tempdir()
  stubs <- file.path(d, "bin"); dir.create(stubs)
  calls <- file.path(d, "launchctl-calls.txt")
  writeLines(c("#!/bin/bash", sprintf('echo "$*" >> "%s"', calls)), file.path(stubs, "launchctl"))
  Sys.chmod(file.path(stubs, "launchctl"), "755")
  home <- file.path(d, "home"); dir.create(home)
  env <- c(HOME = home, PATH = paste(stubs, Sys.getenv("PATH"), sep = ":"),
           SAMPLETIDY_HELPER_APP = file.path(d, "Helper.app"))
  install <- file.path(lh_launchd_dir(), "install.sh")
  for (args in list("bogus", c("uninstall", "extra"), c("--rebuild-helper", "extra"), "--nope")) {
    res <- lh_bash(c(install, args), env = env)
    label <- paste(args, collapse = " ")
    expect_equal(res$status, 2L, info = label)
    expect_match(res$stderr, "usage", ignore.case = TRUE, info = label)
  }
  expect_false(file.exists(calls), info = "launchctl must not be called for a bad argument")
  expect_false(dir.exists(file.path(d, "Helper.app")))
})
