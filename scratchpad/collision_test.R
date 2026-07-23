suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
db <- "/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb"
con <- st_connect(db, read_only=TRUE)
al <- DBI::dbGetQuery(con, "SELECT alias_key, uuid_feature, kind, name FROM feature_alias")
al <- al[!is.na(al$uuid_feature) & !is.na(al$name), ]

# the two candidate normalisers
dot_key   <- sampleTidy:::.st_normalise_key(al$name)     # keeps dots  (what migration stores now)
strip_key <- sampleTidy:::.rc_key(al$name)               # strips all non-alnum (reconcile lookup)

# helper: for a given key vector, how many DISTINCT features does each key reach?
ambiguity <- function(key, feat) {
  ok <- !is.na(key)
  tab <- tapply(feat[ok], key[ok], function(x) length(unique(x)))
  tab[tab > 1]
}
dot_amb   <- ambiguity(dot_key,   al$uuid_feature)
strip_amb <- ambiguity(strip_key, al$uuid_feature)

cat(sprintf("aliases (resolved, named): %d\n", nrow(al)))
cat(sprintf("distinct features: %d\n\n", length(unique(al$uuid_feature))))
cat(sprintf("DOT-preserving keys  : %d distinct keys, %d keys reach >1 feature (ambiguous)\n",
            length(unique(dot_key[!is.na(dot_key)])), length(dot_amb)))
cat(sprintf("STRIP keys           : %d distinct keys, %d keys reach >1 feature (ambiguous)\n\n",
            length(unique(strip_key[!is.na(strip_key)])), length(strip_amb)))

# THE decisive question: merges that STRIPPING introduces which dotting does NOT.
# i.e. a strip_key that reaches >1 feature, where those features are split into
# >1 distinct dot_key (so dotting kept them apart but stripping fused them).
new_merges <- 0L; examples <- list()
for (k in names(strip_amb)) {
  idx <- which(strip_key == k)
  feats <- unique(al$uuid_feature[idx])
  dks   <- unique(dot_key[idx])
  # did dotting separate these features that stripping merged?
  # merge is NEW if the set of features under this strip_key is NOT already
  # unified under a single dot_key
  dfeat_by_dk <- tapply(al$uuid_feature[idx], dot_key[idx], function(x) unique(x))
  # if every dot_key here already reaches all the same features, dotting didn't help
  # count NEW merge if there are >=2 dot_keys each pointing to a DIFFERENT single feature
  singles <- Filter(function(v) length(v) == 1, dfeat_by_dk)
  if (length(singles) >= 2 && length(unique(unlist(singles))) >= 2) {
    new_merges <- new_merges + 1L
    if (length(examples) < 12) examples[[length(examples)+1]] <-
      data.frame(strip_key=k, dot_key=names(dfeat_by_dk), name=tapply(al$name[idx], dot_key[idx], function(x) x[1]),
                 feature=vapply(dfeat_by_dk, function(v) paste(substr(v,1,8),collapse="|"), character(1)),
                 stringsAsFactors=FALSE)
  }
}
cat(sprintf(">>> FALSE MERGES introduced by stripping (distinct points fused that dotting kept apart): %d\n\n", new_merges))
if (length(examples)) { cat("examples:\n"); print(do.call(rbind, examples), row.names=FALSE) } else cat("(none)\n")

# also: does stripping give any EXTRA coverage vs dotting for punctuation variants?
cat(sprintf("\nkeys where dot!=strip (i.e. name had punctuation): %d of %d aliases\n",
            sum(dot_key != strip_key, na.rm=TRUE), nrow(al)))
DBI::dbDisconnect(con, shutdown=TRUE)
