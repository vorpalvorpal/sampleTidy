suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
files <- list.files("tests/testthat", pattern="^test-.*\\.R$", full.names=TRUE)
tot <- list(p=0,f=0,e=0); bad <- list()
for (f in files) {
  r <- tryCatch(as.data.frame(testthat::test_file(f, reporter="silent")),
                error=function(e) NULL)
  if (is.null(r)) { bad[[length(bad)+1]] <- data.frame(file=basename(f), test="<file error>", failed=NA, error=NA); next }
  tot$p <- tot$p + sum(r$passed); tot$f <- tot$f + sum(r$failed); tot$e <- tot$e + sum(r$error)
  b <- r[r$failed>0 | r$error>0, c("test","failed","error")]
  if (nrow(b)) { b$file <- basename(f); bad[[length(bad)+1]] <- b }
}
cat(sprintf("\n=== FULL SUITE: passed=%d failed=%d error=%d ===\n", tot$p, tot$f, tot$e))
if (length(bad)) print(do.call(rbind, bad), row.names=FALSE) else cat("ALL GREEN\n")
