suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
con <- st_connect("/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb", read_only=TRUE)
feat <- DBI::dbGetQuery(con, "SELECT uuid, name, date_start, date_end FROM feature")

## 1. Enumerate distinct SITE codes (token before first dot/space) across the registry
site_of <- function(nm) {
  m <- regmatches(nm, regexpr("^[A-Za-z]+", nm)); if(length(m)) m else NA
}
# for dotted names, site = part before dot; for spaced, before space
site_tok <- sub("[.[:space:]].*$", "", feat$name)
cat("=== distinct site tokens (before first dot/space), count of features ===\n")
st <- sort(table(site_tok), decreasing=TRUE)
print(st[st>=3])
cat(sprintf("\ntotal distinct site tokens: %d\n", length(st)))
cat("is 'BS' ever a site token? ", "BS" %in% names(st), " | is 'B'? ", "B" %in% names(st), "\n")
cat("features whose name has NO dot/space (site==whole name):\n")
nodelim <- feat$name[!grepl("[.[:space:]]", feat$name)]
print(utils::head(sort(nodelim), 40))
cat(sprintf("(%d features have no delimiter)\n", length(nodelim)))

## 2. Metadata for the collision families
samples_for <- function(fuuid) {
  DBI::dbGetQuery(con, "
    SELECT s.date, s.organisation, s.uuid_project, s.comments
    FROM sample s JOIN feature_alias fa ON s.uuid_feature_alias = fa.uuid
    WHERE fa.uuid_feature = ?", params=list(fuuid))
}
show <- function(nm) {
  fu <- feat$uuid[feat$name == nm]
  if (length(fu)==0) { cat(sprintf("\n[%s] NOT a feature.name\n", nm)); return(invisible()) }
  for (u in fu) {
    s <- samples_for(u)
    al <- DBI::dbGetQuery(con, "SELECT alias_key, kind, name FROM feature_alias WHERE uuid_feature = ?", params=list(u))
    cat(sprintf("\n[%s] uuid=%s  n_samples=%d  date_range=%s..%s  orgs={%s}\n",
        nm, substr(u,1,8), nrow(s),
        if(nrow(s)) as.character(min(s$date,na.rm=TRUE)) else "-",
        if(nrow(s)) as.character(max(s$date,na.rm=TRUE)) else "-",
        paste(unique(stats::na.omit(s$organisation)), collapse=";")))
    cat("   aliases: "); cat(paste(sprintf("%s(%s)", al$name, al$kind), collapse=", "), "\n")
    if (nrow(s)) { cat("   sample dates: "); cat(paste(utils::head(sort(as.character(s$date)),8), collapse=", "), "\n") }
  }
}
cat("\n\n=========== COLLISION FAMILY 1: B.S01 / B.S1 / BS1 ===========")
for (nm in c("B.S01","B.S1","BS1")) show(nm)
cat("\n\n=========== COLLISION FAMILY 2: B.S03 / B.S3 / BS3 ===========")
for (nm in c("B.S03","B.S3","BS3")) show(nm)

## 3. which uuid do the aliases B.S1/BS1/B.S3/BS3 resolve to?
cat("\n\n=== alias token -> uuid_feature -> that feature's canonical name ===\n")
for (tok in c("B.S1","BS1","B.S01","B.S3","BS3","B.S03")) {
  a <- DBI::dbGetQuery(con, "SELECT uuid_feature, kind FROM feature_alias WHERE name = ?", params=list(tok))
  if (nrow(a)==0) { cat(sprintf("%-6s -> (no alias)\n", tok)); next }
  for (j in seq_len(nrow(a))) {
    cn <- feat$name[feat$uuid == a$uuid_feature[j]]
    cat(sprintf("%-6s (%s) -> %s = %s\n", tok, a$kind[j], substr(a$uuid_feature[j],1,8), if(length(cn)) cn else "?"))
  }
}
DBI::dbDisconnect(con, shutdown=TRUE)
