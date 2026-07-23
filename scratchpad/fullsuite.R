suppressMessages(pkgload::load_all(".", quiet=TRUE))
files <- list.files("tests/testthat", pattern="^test-.*\\.R$", full.names=TRUE)
P<-0;F<-0;E<-0;bad<-c()
for (f in files) {
  r <- tryCatch(as.data.frame(testthat::test_file(f, reporter="silent")), error=function(e)NULL)
  if(is.null(r))next
  P<-P+sum(r$passed);F<-F+sum(r$failed);E<-E+sum(r$error)
  if(sum(r$failed)+sum(r$error)>0) bad<-c(bad, paste0(basename(f)," F=",sum(r$failed)," E=",sum(r$error)))
}
writeLines(paste0("RESULT|",P,"|",F,"|",E,"|",paste(bad,collapse=",")), "scratchpad/fullsuite_out.txt")
