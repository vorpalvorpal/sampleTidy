suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1, width=200)
con <- st_connect("/private/tmp/claude-501/qc-dryrun/snapshots/monitoring_pre-002-registry-remediation_20260722T232748.090Z.duckdb", read_only=TRUE)
q <- function(s) DBI::dbGetQuery(con,s)
cat("### B10: separators in alias keys / lowercase-ish feature names / multi-word keys\n")
a <- q("SELECT alias_key FROM feature_alias")
cat(sprintf("  alias keys containing '-': %d ; '_': %d ; whitespace (multi-word): %d of %d\n",
  sum(grepl("-",a$alias_key)), sum(grepl("_",a$alias_key)),
  sum(grepl("\\s",a$alias_key)), nrow(a)))
print(head(a$alias_key[grepl("-|_", a$alias_key)], 8))
f <- q("SELECT name FROM feature")
cat(sprintf("  feature names with a non-uppercase point part: %d\n",
  sum(grepl("[a-z]", sub("^[^.]*\\.","",f$name)))))
print(head(f$name[grepl("[a-z]", sub("^[^.]*\\.","",f$name))], 8))
cat("\n### B2 follow-up: do K.G 2-wide and 3-wide ever collide after zero-strip?\n")
kg <- q("SELECT name FROM feature WHERE site='K' AND name LIKE 'K.G%' ORDER BY name")
n <- sub("^K\\.G","",kg$name); stripped <- sub("^0+","",n)
cat(sprintf("  K.G features=%d distinct stripped=%d -> collisions=%d\n",
  nrow(kg), length(unique(stripped)), nrow(kg)-length(unique(stripped))))
cat("  2-wide examples:", paste(head(kg$name[nchar(n)==2],5),collapse=", "), "\n")
cat("  3-wide examples:", paste(head(kg$name[nchar(n)==3],5),collapse=", "), "\n")
DBI::dbDisconnect(con, shutdown=TRUE)
