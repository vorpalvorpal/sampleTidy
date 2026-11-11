# Shared by test-autoimport-config.R (the .sh reader) and test-autoimport-windows-parity.R (the
# .ps1 reader): R's own ${VAR} forms in a user environ file, with the value R gives each.
#
# R's documented rule (?Startup): in a `KEY=value` line, `${VAR}` is the value of VAR, `${VAR-dflt}`
# is VAR if it is SET (even to empty) else dflt, `${VAR:-dflt}` is VAR if it is set AND non-empty
# else dflt. The expectations below were observed by running Rscript against a temporary
# R_ENVIRON_USER, not copied from the documentation:
#   - an unset VAR with no default is empty; and a final empty value leaves the key unset;
#   - defaults may be single- or double-quoted, the quotes are removed, and they may hold spaces;
#   - a default may itself contain ${...} (nested); text around a ${...} is kept;
#   - ${...} is expanded even inside a quoted value ('${V-x}' is `x`: the quotes do not protect it);
#   - a bare $VAR and a leading ~ are NOT expanded;
#   - a later line sees what an earlier line of the same file set.
rf_var <- "SAMPLETIDY_TEST_VAR"
rf_key <- "SAMPLETIDY_NOTIFY_COMMAND"

# form, var (the value of VAR in the process environment: NA = unset), want (what R gives the key)
rf_forms <- list(
  list("${SAMPLETIDY_TEST_VAR}",                      "real", "real"),
  list("${SAMPLETIDY_TEST_VAR}",                      NA,     ""),
  list("${SAMPLETIDY_TEST_VAR-dflt}",                 "real", "real"),
  list("${SAMPLETIDY_TEST_VAR-dflt}",                 NA,     "dflt"),
  list("${SAMPLETIDY_TEST_VAR-dflt}",                 "",     ""),        # set but empty: `-` keeps the empty
  list("${SAMPLETIDY_TEST_VAR:-dflt}",                "",     "dflt"),    # `:-` replaces an empty one
  list("${SAMPLETIDY_TEST_VAR:-dflt}",                NA,     "dflt"),
  list("${SAMPLETIDY_TEST_VAR:-dflt}",                "real", "real"),
  list("${SAMPLETIDY_TEST_VAR-'/a b/c'}",             NA,     "/a b/c"),
  list("${SAMPLETIDY_TEST_VAR-\"/a b/c\"}",           NA,     "/a b/c"),
  list("${SAMPLETIDY_TEST_VAR:-'/a b/c'}",            NA,     "/a b/c"),
  list("${SAMPLETIDY_TEST_VAR-'/a b/c'}",             "real", "real"),
  list("'${SAMPLETIDY_TEST_VAR-x}'",                  NA,     "x"),       # quotes do not stop expansion
  list("\"${SAMPLETIDY_TEST_VAR-x}\"",                NA,     "x"),
  list("\"a ${SAMPLETIDY_TEST_VAR} b\"",              "real", "a real b"),
  list("pre${SAMPLETIDY_TEST_VAR}post",               "real", "prerealpost"),
  list("${SAMPLETIDY_TEST_VAR}${SAMPLETIDY_TEST_VAR}", "real", "realreal"),
  list("${SAMPLETIDY_TEST_VAR-a}b",                   NA,     "ab"),
  list("${SAMPLETIDY_TEST_VAR-/p/q}",                 NA,     "/p/q"),
  list("${SAMPLETIDY_TEST_VAR-}",                     NA,     ""),
  list("${SAMPLETIDY_TEST_VAR:-}",                    NA,     ""),
  list("${SAMPLETIDY_TEST_UNSET-${SAMPLETIDY_TEST_VAR}}", "real", "real"),  # nested default
  list("$SAMPLETIDY_TEST_VAR",                        "real", "$SAMPLETIDY_TEST_VAR"),  # bare $ is literal
  list("~/foo",                                       NA,     "~/foo")                  # ~ is literal
)

#' The process environment a form needs: VAR set, empty, or absent (`env` form, for processx).
rf_env <- function(var) if (is.na(var)) character() else setNames(var, rf_var)

#' What R itself gives `key` for these environ lines (oracle; needs Rscript).
rf_r_value <- function(lines, var = NA, key = rf_key) {
  f <- withr::local_tempfile(fileext = ".env")
  writeLines(lines, f)
  h <- withr::local_tempdir()
  r <- processx::run(as.character(Sys.which("Rscript")),
                     c("-e", sprintf('cat(Sys.getenv("%s", ""))', key)),
                     env = c(HOME = h, PATH = "/usr/bin:/bin", R_ENVIRON_USER = f, R_PROFILE_USER = file.path(h, "none"),
                             rf_env(var)),
                     error_on_status = FALSE, timeout = 60)
  r$stdout
}
