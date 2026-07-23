suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
db <- "/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb"
con <- st_connect(db, read_only=TRUE)
al <- DBI::dbGetQuery(con, "SELECT alias_key, uuid_feature, kind, auto_assign, n_seen, name FROM feature_alias")

cat("=== alias_key format: sample of 20 ===\n"); print(utils::head(al$alias_key, 20))
cat("\ndoes any alias_key contain a dot/non-alnum? ", sum(grepl("[^[:alnum:]]", al$alias_key)), "of", nrow(al), "\n")

# reconcile's key for B.S01 vs stored
for (nm in c("B.S01","B.MW02","K.E02","B.39","B.S39")) {
  rk <- sampleTidy:::.rc_key(nm)
  stripped_hit <- al[!is.na(al$alias_key) & al$alias_key == rk, ]
  dotted <- sampleTidy:::.st_normalise_key(nm)
  dotted_hit <- al[!is.na(al$alias_key) & al$alias_key == dotted, ]
  cat(sprintf("\n%-8s .rc_key='%s' (%d rows)  .st_normalise_key='%s' (%d rows)\n",
      nm, rk, nrow(stripped_hit), dotted, nrow(dotted_hit)))
  h <- if(nrow(dotted_hit)) dotted_hit else stripped_hit
  if (nrow(h)) print(h[,c("alias_key","kind","auto_assign","uuid_feature")], row.names=FALSE)
}

cat("\n=== auto_assign distribution over ALL aliases ===\n")
print(table(al$auto_assign, useNA="ifany"))
cat("\n=== auto_assign among aliases whose key matches one of the 34 unknown names (.st_normalise_key) ===\n")
names34 <- c("B.E01","B.S01","B.MW02","B.MW08","B.S39","B.MW09","B.S06","B.S03","B.S05","B.L01",
 "K.E02","K.E01","K.S07","K.S09","B.39","B.L02","B.MW04","B.MW07","B.MW11","B.S10","B.E39","K.S03","K.S05","K.S06",
 "L.L02","BH.MW02A","BH.S02","BH.S01","BH.S03","L.MW06","L.MW07","L.MW08")
nk <- sampleTidy:::.st_normalise_key(names34)
sub <- al[al$alias_key %in% nk, ]
print(table(sub$auto_assign, useNA="ifany"))
DBI::dbDisconnect(con, shutdown=TRUE)
