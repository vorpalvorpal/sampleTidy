# PLAN-21 phase (b), item b3 (the generic half): dev/windows/install-task.ps1, which
# registers the Windows import trigger as a scheduled task.
#
#   install-task.ps1 [-Print] [-Uninstall] [-Launcher conhost|none] [-Name <n>] [-RenvironFile <f>]
#                    [-Script <p>] [-Interval <minutes>] [-TimeLimit <ISO 8601 duration>]
# (-Script, -Interval and -TimeLimit make it a generic installer other packages reuse for their own
# jobs; their defaults are the auto-import trigger, every 10 minutes, 4 hours.)
#
# The task XML is generated and checked here on any OS with pwsh; registration goes through
# schtasks.exe behind SAMPLETIDY_SCHTASKS, which these tests point at a bash stub that records
# its argv and copies the XML file it was given. Nothing real is registered. The decisions
# under test: the conhost --headless launcher is the default (a console window would flash
# every 10 minutes), the task runs only while the user is logged on, and it never fetches
# code (it runs the checkout it was installed from).

it_skip <- function() {
  skip_on_os("windows")   # the stub is a bash script; the laptop checks cover registration
  skip_if(Sys.which("pwsh") == "", "no pwsh")
  skip_if(Sys.which("bash") == "", "no bash")
  skip_if_not_installed("xml2")
}

it_ns <- "http://schemas.microsoft.com/windows/2004/02/mit/task"

#' A checkout copy under a path with a space (so quoting is tested), a stub schtasks, an
#' empty TMPDIR, and a report dir whose parent should become the task's WorkingDirectory.
it_sandbox <- function(env = parent.frame()) {
  it_skip()
  d <- normalizePath(withr::local_tempdir(.local_envir = env))
  co <- file.path(d, "my checkout")
  dir.create(file.path(co, "dev", "windows"), recursive = TRUE)
  src <- normalizePath(testthat::test_path("..", "..", "dev"), mustWork = TRUE)
  for (f in c("auto-import.ps1", "auto-import-gate.ps1")) file.copy(file.path(src, f), file.path(co, "dev", f))
  inst <- file.path(src, "windows", "install-task.ps1")
  if (file.exists(inst)) file.copy(inst, file.path(co, "dev", "windows", "install-task.ps1"))
  s <- list(dir = d, checkout = co, script = file.path(co, "dev", "windows", "install-task.ps1"),
            tmp = file.path(d, "tmp"), home = file.path(d, "home"), data = file.path(d, "data"),
            sch = file.path(d, "schtasks-stub.sh"), argv = file.path(d, "schtasks-argv.txt"),
            xml = file.path(d, "schtasks-xml-copy.xml"), seen = file.path(d, "schtasks-saw-file.txt"))
  for (p in c(s$tmp, s$home, file.path(s$data, "reports"))) dir.create(p, recursive = TRUE)
  writeLines(c("#!/bin/bash",
               sprintf('{ printf "%%s\\n" "$@"; echo "---"; } >> "%s"', s$argv),
               'prev=""; for a in "$@"; do',
               sprintf('  if [ "$prev" = "/xml" ]; then cp "$a" "%s"; [ -f "$a" ] && echo yes >> "%s"; fi', s$xml, s$seen),
               '  prev="$a"; done',
               'if [ -n "${STUB_SCH_RC:-}" ]; then echo "${STUB_SCH_MSG:-ERROR: stub failure}" >&2; exit "$STUB_SCH_RC"; fi',
               "exit 0"), s$sch)
  Sys.chmod(s$sch, "755")
  s
}

it_run <- function(s, args = character(), ...) {
  expect_true(file.exists(s$script), info = "dev/windows/install-task.ps1 exists")
  v <- c(HOME = s$home, TMPDIR = s$tmp, TEMP = s$tmp, TMP = s$tmp,
         PATH = paste(c("/usr/bin", "/bin", dirname(Sys.which("pwsh"))), collapse = ":"),
         POWERSHELL_TELEMETRY_OPTOUT = "1", DOTNET_CLI_TELEMETRY_OPTOUT = "1",
         LOCALAPPDATA = file.path(s$dir, "lad"),
         SAMPLETIDY_REPORT_DIR = file.path(s$data, "reports"),
         R_ENVIRON_USER = file.path(s$dir, "no-such.Renviron"),
         SAMPLETIDY_SCHTASKS = s$sch)
  over <- c(...)
  if (length(over)) v <- c(v[setdiff(names(v), names(over))], over)
  processx::run(as.character(Sys.which("pwsh")), c("-NoProfile", "-File", s$script, args),
                env = v[!is.na(v)], error_on_status = FALSE, timeout = 90)
}

it_info <- function(r) paste(r$stdout, r$stderr)

it_parse <- function(txt) {
  txt <- sub("^\\s*<\\?xml[^>]*\\?>", "", sub("^﻿", "", txt))
  x <- xml2::read_xml(txt)
  xml2::xml_ns_strip(x)
  x
}
it_print <- function(s, ...) {
  r <- it_run(s, c("-Print", ...))
  expect_identical(r$status, 0L, info = it_info(r))
  it_parse(r$stdout)
}
it_txt <- function(x, path) xml2::xml_text(xml2::xml_find_first(x, path))
it_norm <- function(x) gsub("\\\\", "/", x)

# ---- 17. the XML -----------------------------------------------------------------------------

test_that("-Print writes the task XML to stdout, creates nothing and does not call schtasks", {
  s <- it_sandbox()
  r <- it_run(s, "-Print")
  expect_identical(r$status, 0L, info = it_info(r))
  expect_match(r$stdout, "<Task\\b")
  expect_false(file.exists(s$argv))
  expect_length(list.files(s$tmp, all.files = TRUE, no.. = TRUE), 0L)
})

test_that("XML: the principal is this user, interactive token, least privilege", {
  s <- it_sandbox()
  x <- it_print(s)
  expect_identical(it_txt(x, "//Principals/Principal/LogonType"), "InteractiveToken")
  expect_identical(it_txt(x, "//Principals/Principal/RunLevel"), "LeastPrivilege")
})

test_that("XML: a time trigger repeating every 10 minutes indefinitely, and a logon trigger for this user", {
  s <- it_sandbox()
  x <- it_print(s)
  expect_length(xml2::xml_find_all(x, "//Triggers/*"), 2L)
  expect_identical(it_txt(x, "//Triggers/TimeTrigger/Repetition/Interval"), "PT10M")
  expect_length(xml2::xml_find_all(x, "//Triggers/TimeTrigger/Repetition/Duration"), 0L)   # no Duration = indefinitely
  expect_length(xml2::xml_find_all(x, "//Triggers/TimeTrigger/StartBoundary"), 1L)
  expect_length(xml2::xml_find_all(x, "//Triggers/LogonTrigger"), 1L)
  expect_true(grepl(Sys.info()[["user"]], it_txt(x, "//Triggers/LogonTrigger/UserId"), fixed = TRUE))
})

test_that("XML settings: IgnoreNew, start when available, battery-proof, priority 7, 4 h limit, hidden", {
  s <- it_sandbox()
  x <- it_print(s)
  st <- function(n) it_txt(x, paste0("//Settings/", n))
  expect_identical(st("MultipleInstancesPolicy"), "IgnoreNew")
  expect_identical(st("StartWhenAvailable"), "true")
  expect_identical(st("DisallowStartIfOnBatteries"), "false")
  expect_identical(st("StopIfGoingOnBatteries"), "false")
  expect_identical(st("Priority"), "7")
  expect_identical(st("ExecutionTimeLimit"), "PT4H")
  expect_identical(st("Hidden"), "true")
})

test_that("XML action: one Exec, the default conhost launcher running pwsh on this checkout's auto-import.ps1", {
  s <- it_sandbox()
  x <- it_print(s)
  expect_length(xml2::xml_find_all(x, "//Actions/Exec"), 1L)
  expect_identical(it_txt(x, "//Actions/Exec/Command"), "conhost.exe")
  a <- it_txt(x, "//Actions/Exec/Arguments")
  expect_match(a, "^--headless\\s")
  m <- regmatches(a, regexec('^--headless\\s+"?([^"]*?pwsh(?:\\.exe)?)"?\\s+(.*)$', a, perl = TRUE))[[1]]
  expect_length(m, 3L)
  expect_match(m[2], "^(/|[A-Za-z]:[\\\\/])")                       # an absolute pwsh path
  expect_match(m[3], "^-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ")
  # the checkout's path has a space in it: it must be quoted
  expect_true(grepl(sprintf('-File "%s"', it_norm(file.path(s$checkout, "dev", "auto-import.ps1"))), it_norm(m[3]), fixed = TRUE), info = a)
})

test_that("XML: WorkingDirectory is the report dir's parent, absolute", {
  s <- it_sandbox()
  x <- it_print(s)
  wd <- it_txt(x, "//Actions/Exec/WorkingDirectory")
  expect_identical(it_norm(wd), it_norm(s$data))
})

test_that("XML: the task is named \\sampleTidy-autoimport; -Name changes it", {
  s <- it_sandbox()
  x <- it_print(s)
  expect_match(it_txt(x, "//RegistrationInfo/URI"), "^\\\\?sampleTidy-autoimport$")
  x2 <- it_print(s, "-Name", "sampleTidy-autoimport-sandbox")
  expect_match(it_txt(x2, "//RegistrationInfo/URI"), "^\\\\?sampleTidy-autoimport-sandbox$")
})

test_that("XML: -RenvironFile adds `-RenvironFile <f>` to the action; by default it is absent", {
  s <- it_sandbox()
  expect_false(grepl("RenvironFile", it_txt(it_print(s), "//Actions/Exec/Arguments"), fixed = TRUE))
  f <- file.path(s$dir, "scratch dir", ".Renviron")
  a <- it_txt(it_print(s, "-RenvironFile", f), "//Actions/Exec/Arguments")
  expect_true(grepl("auto-import.ps1\"? -RenvironFile \"?", it_norm(a)), info = a)
  expect_true(grepl(it_norm(f), it_norm(a), fixed = TRUE), info = a)
})

# ---- 19. launchers ------------------------------------------------------------------------------

test_that("-Launcher none runs pwsh directly, with no conhost", {
  s <- it_sandbox()
  x <- it_print(s, "-Launcher", "none")
  expect_match(it_txt(x, "//Actions/Exec/Command"), "pwsh(\\.exe)?\"?$")
  expect_match(it_txt(x, "//Actions/Exec/Command"), "^\"?(/|[A-Za-z]:[\\\\/])")
  a <- it_txt(x, "//Actions/Exec/Arguments")
  expect_match(a, "^-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ")
  expect_false(grepl("conhost|--headless", a))
})

test_that("-Launcher conhost is the default and an unknown launcher is refused", {
  s <- it_sandbox()
  expect_identical(it_txt(it_print(s, "-Launcher", "conhost"), "//Actions/Exec/Command"), "conhost.exe")
  r <- it_run(s, c("-Print", "-Launcher", "wscript-or-whatever"))
  expect_false(identical(r$status, 0L))
})

# ---- 18. registering ---------------------------------------------------------------------------

it_argv <- function(s) {
  l <- if (file.exists(s$argv)) readLines(s$argv, warn = FALSE) else character()
  l[l != "---"]
}

test_that("install: schtasks /create /xml <file> /tn sampleTidy-autoimport /f, the XML is the -Print XML, the file is removed", {
  s <- it_sandbox()
  r <- it_run(s)
  expect_identical(r$status, 0L, info = it_info(r))
  a <- it_argv(s)
  expect_identical(a[1:2], c("/create", "/xml"))
  expect_identical(a[4:6], c("/tn", "sampleTidy-autoimport", "/f"))
  expect_length(a, 6L)
  expect_true(file.exists(s$seen), info = "the XML file existed when schtasks ran")
  expect_false(file.exists(a[3]))                                     # deleted afterwards
  expect_length(list.files(s$tmp, all.files = TRUE, no.. = TRUE), 0L)
  x <- it_parse(paste(readLines(s$xml, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
  p <- it_print(s)
  expect_identical(as.character(xml2::xml_find_all(x, "//Actions")), as.character(xml2::xml_find_all(p, "//Actions")))
})

test_that("install: the XML file's declared encoding matches its bytes (schtasks rejects a mismatch)", {
  s <- it_sandbox()
  expect_identical(it_run(s)$status, 0L)
  b <- readBin(s$xml, "raw", 400)
  if (identical(b[1:2], as.raw(c(0xff, 0xfe)))) {
    head <- iconv(list(b[-(1:2)]), "UTF-16LE", "UTF-8")
    expect_match(head, "encoding=\"UTF-16\"", ignore.case = TRUE)
  } else {
    expect_false(grepl("encoding=\"UTF-16\"", rawToChar(b), ignore.case = TRUE))   # UTF-8 bytes declared UTF-16
  }
})

test_that("install: -Name sets the /tn; -Uninstall is schtasks /delete /tn <name> /f and registers nothing", {
  s <- it_sandbox()
  expect_identical(it_run(s, c("-Name", "my-task"))$status, 0L)
  expect_identical(it_argv(s)[4:5], c("/tn", "my-task"))
  unlink(s$argv)
  r <- it_run(s, "-Uninstall")
  expect_identical(r$status, 0L, info = it_info(r))
  expect_identical(it_argv(s), c("/delete", "/tn", "sampleTidy-autoimport", "/f"))
  unlink(s$argv)
  expect_identical(it_run(s, c("-Uninstall", "-Name", "my-task"))$status, 0L)
  expect_identical(it_argv(s), c("/delete", "/tn", "my-task", "/f"))
})

test_that("install: a non-zero schtasks exit makes the script exit non-zero with schtasks' message, and still removes the XML file", {
  s <- it_sandbox()
  r <- it_run(s, STUB_SCH_RC = "5", STUB_SCH_MSG = "ERROR: Access is denied (stub)")
  expect_false(identical(r$status, 0L))
  expect_match(it_info(r), "Access is denied (stub)", fixed = TRUE)
  expect_false(file.exists(it_argv(s)[3]))
  unlink(s$argv)
  r <- it_run(s, "-Uninstall", STUB_SCH_RC = "1", STUB_SCH_MSG = "ERROR: The system cannot find the file (stub)")
  expect_false(identical(r$status, 0L))
  expect_match(it_info(r), "cannot find the file (stub)", fixed = TRUE)
})

test_that("install -Print never calls schtasks even with a failing stub", {
  s <- it_sandbox()
  r <- it_run(s, "-Print", STUB_SCH_RC = "9")
  expect_identical(r$status, 0L, info = it_info(r))
  expect_false(file.exists(s$argv))
})

test_that("the installer and the XML name no person, host or path of a deployment", {
  s <- it_sandbox()
  src <- normalizePath(testthat::test_path("..", "..", "dev", "windows", "install-task.ps1"), mustWork = FALSE)
  expect_true(file.exists(src))
  if (file.exists(src)) {
    txt <- paste(readLines(src, warn = FALSE), collapse = "\n")
    expect_false(grepl("/Users/|~/pkm|~/dev/|OneDrive|SharePoint|bmcc", txt, ignore.case = TRUE))
  }
})

# ---- 20. the generic installer: -Script, -Interval, -TimeLimit ----------------------------------------
# A downstream package registers its own job as
#   install-task.ps1 -Name <n> -Script <p> -Interval <m> -TimeLimit <d> -RenvironFile <f>
# -TimeLimit is an ISO 8601 duration, as the task XML spells it (PT30M, PT2H, PT1H30M, P1D).

#' A job script under a path with a space; returns its path.
it_job <- function(s, name = "nightly job.ps1") {
  d <- file.path(s$dir, "jobs dir")
  dir.create(d, showWarnings = FALSE)
  p <- file.path(d, name)
  writeLines("# a job", p)
  p
}

test_that("-Script: the action runs that script, quoted, through the default launcher; the default is unchanged", {
  s <- it_sandbox()
  j <- it_job(s)
  x <- it_print(s, "-Script", j)
  expect_identical(it_txt(x, "//Actions/Exec/Command"), "conhost.exe")
  a <- it_txt(x, "//Actions/Exec/Arguments")
  expect_match(a, "^--headless\\s")
  expect_match(a, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File ")
  expect_true(grepl(sprintf('-File "%s"', it_norm(j)), it_norm(a), fixed = TRUE), info = a)
  expect_false(grepl("auto-import", a, fixed = TRUE))
  # omitted: the checkout's trigger, as before
  expect_true(grepl(sprintf('-File "%s"', it_norm(file.path(s$checkout, "dev", "auto-import.ps1"))),
                    it_norm(it_txt(it_print(s), "//Actions/Exec/Arguments")), fixed = TRUE))
})

test_that("-Script goes through -Launcher none too, and -RenvironFile follows it", {
  s <- it_sandbox()
  j <- it_job(s)
  f <- file.path(s$dir, "scratch dir", ".Renviron")
  x <- it_print(s, "-Script", j, "-Launcher", "none", "-RenvironFile", f)
  expect_match(it_txt(x, "//Actions/Exec/Command"), "pwsh(\\.exe)?\"?$")
  a <- it_norm(it_txt(x, "//Actions/Exec/Arguments"))
  expect_true(grepl(sprintf('-File "%s" -RenvironFile "%s"', it_norm(j), it_norm(f)), a, fixed = TRUE), info = a)
  expect_false(grepl("conhost|--headless", a))
})

test_that("-Script: a missing file is refused, non-zero, naming the path, and schtasks is never called", {
  s <- it_sandbox()
  nope <- file.path(s$dir, "jobs dir", "no-such-job.ps1")
  for (args in list(c("-Print", "-Script", nope), c("-Script", nope))) {
    r <- it_run(s, args)
    expect_false(identical(r$status, 0L), info = paste(args, collapse = " "))
    expect_true(grepl(it_norm(nope), it_norm(it_info(r)), fixed = TRUE), info = it_info(r))
    expect_false(file.exists(s$argv))
  }
  # a folder is not a script
  r <- it_run(s, c("-Print", "-Script", s$dir))
  expect_false(identical(r$status, 0L))
})

test_that("-Interval: the time trigger repeats every N minutes; the default stays 10", {
  s <- it_sandbox()
  iv <- function(...) it_txt(it_print(s, ...), "//Triggers/TimeTrigger/Repetition/Interval")
  expect_identical(iv("-Interval", "15"), "PT15M")
  expect_identical(iv("-Interval", "1"), "PT1M")
  expect_match(iv("-Interval", "90"), "^PT(90M|1H30M)$")
  expect_identical(iv(), "PT10M")
  x <- it_print(s, "-Interval", "15")
  expect_length(xml2::xml_find_all(x, "//Triggers/*"), 2L)                 # the logon trigger is still there
  expect_length(xml2::xml_find_all(x, "//Triggers/TimeTrigger/Repetition/Duration"), 0L)
})

test_that("-Interval: zero, negative and non-numeric values are refused, non-zero, and register nothing", {
  s <- it_sandbox()
  for (bad in c("0", "-5", "abc", "")) {
    r <- it_run(s, c("-Print", "-Interval", bad))
    expect_false(identical(r$status, 0L), info = paste0("-Interval '", bad, "'"))
    r <- it_run(s, c("-Interval", bad))
    expect_false(identical(r$status, 0L), info = paste0("-Interval '", bad, "'"))
  }
  expect_false(file.exists(s$argv))
})

test_that("-TimeLimit: the task's ExecutionTimeLimit is the given ISO 8601 duration; the default stays PT4H", {
  s <- it_sandbox()
  tl <- function(...) it_txt(it_print(s, ...), "//Settings/ExecutionTimeLimit")
  expect_identical(tl("-TimeLimit", "PT30M"), "PT30M")
  expect_identical(tl("-TimeLimit", "PT2H"), "PT2H")
  expect_identical(tl("-TimeLimit", "PT1H30M"), "PT1H30M")
  expect_identical(tl("-TimeLimit", "P1D"), "P1D")
  expect_identical(tl(), "PT4H")
})

test_that("-TimeLimit: a malformed duration is refused, non-zero, and registers nothing", {
  s <- it_sandbox()
  for (bad in c("4 hours", "banana", "PT", "P", "4H", "-PT1H", "PT1X", "")) {
    r <- it_run(s, c("-Print", "-TimeLimit", bad))
    expect_false(identical(r$status, 0L), info = paste0("-TimeLimit '", bad, "'"))
    r <- it_run(s, c("-TimeLimit", bad))
    expect_false(identical(r$status, 0L), info = paste0("-TimeLimit '", bad, "'"))
  }
  expect_false(file.exists(s$argv))
})

test_that("the downstream call shape: -Name -Script -Interval -TimeLimit -RenvironFile registers one task with all of them", {
  s <- it_sandbox()
  j <- it_job(s)
  f <- file.path(s$dir, "other env", ".Renviron")
  r <- it_run(s, c("-Name", "pkg-nightly", "-Script", j, "-Interval", "30", "-TimeLimit", "PT1H", "-RenvironFile", f))
  expect_identical(r$status, 0L, info = it_info(r))
  a <- it_argv(s)
  expect_identical(a[1:2], c("/create", "/xml"))
  expect_identical(a[4:6], c("/tn", "pkg-nightly", "/f"))
  expect_length(a, 6L)
  x <- it_parse(paste(readLines(s$xml, warn = FALSE, encoding = "UTF-8"), collapse = "\n"))
  expect_match(it_txt(x, "//RegistrationInfo/URI"), "^\\\\?pkg-nightly$")
  expect_identical(it_txt(x, "//Triggers/TimeTrigger/Repetition/Interval"), "PT30M")
  expect_identical(it_txt(x, "//Settings/ExecutionTimeLimit"), "PT1H")
  ar <- it_norm(it_txt(x, "//Actions/Exec/Arguments"))
  expect_true(grepl(sprintf('-File "%s" -RenvironFile "%s"', it_norm(j), it_norm(f)), ar, fixed = TRUE), info = ar)
  # the same XML as -Print gives for the same call (the file is what schtasks was handed)
  p <- it_print(s, "-Name", "pkg-nightly", "-Script", j, "-Interval", "30", "-TimeLimit", "PT1H", "-RenvironFile", f)
  expect_identical(as.character(xml2::xml_find_all(x, "//Actions")), as.character(xml2::xml_find_all(p, "//Actions")))
})

test_that("a custom -Script's task is not described as the sampleTidy auto-import trigger", {
  s <- it_sandbox()
  x <- it_print(s, "-Script", it_job(s))
  expect_false(grepl("auto-import", it_txt(x, "//RegistrationInfo/Description"), ignore.case = TRUE))
  expect_match(it_txt(it_print(s), "//RegistrationInfo/Description"), "auto-import")   # the default keeps its text
})
