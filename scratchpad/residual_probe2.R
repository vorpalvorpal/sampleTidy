suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
scratch <- "/private/tmp/claude-501/qc-dryrun"
con <- st_connect(file.path(scratch,"monitoring_dryrun.duckdb"), read_only=TRUE)
q <- function(s) DBI::dbGetQuery(con, s)
wos <- c('ES2515424','ES2515446','ES2606531','ES2607374','ES2607380','ES2608958',
         'ES2515447','ES2606532','ES2609437','ES2607215','ES2607388','ES2607398',
         'ES2608959','ES2608962','ES2608965')
cat("=== resolved features present in each descriptive-residual WO ===\n")
r <- q(sprintf("SELECT s.work_order, f.name, count(*) n FROM sample s
        JOIN feature_alias fa ON fa.uuid=s.uuid_feature_alias
        JOIN feature f ON f.uuid=fa.uuid_feature
        WHERE s.work_order IN (%s) GROUP BY 1,2 ORDER BY 1,2",
        paste0("'",wos,"'",collapse=",")))
for (w in unique(r$work_order)) {
  sub <- r[r$work_order==w,]
  sites <- unique(sub("[.].*$","",sub$name))
  cat(sprintf("%s: sites=%s | %s\n", w, paste(sites,collapse="/"),
      paste(sprintf("%s(%d)",sub$name,sub$n), collapse=", ")))
}
cat("\n=== descriptive aliases already registered for those WOs' sites (sample) ===\n")
print(q("SELECT fa.alias_key, f.name AS resolves_to, fa.kind FROM feature_alias fa
         JOIN feature f ON f.uuid=fa.uuid_feature
         WHERE fa.kind IN ('descriptive','mask_long') AND (lower(fa.alias_key) LIKE '%trade%' OR lower(fa.alias_key) LIKE '%lawson%' OR lower(fa.alias_key) LIKE '%discharge%')
         ORDER BY fa.alias_key"), row.names=FALSE)
cat("\n=== alias kind distribution ===\n")
print(q("SELECT kind, count(*) n, sum(CASE WHEN auto_assign THEN 0 ELSE 1 END) n_ambiguous FROM feature_alias GROUP BY kind ORDER BY n DESC"), row.names=FALSE)
DBI::dbDisconnect(con, shutdown=TRUE)
