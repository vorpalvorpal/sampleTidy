suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
con <- st_connect("/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb", read_only=TRUE)
q <- function(s) DBI::dbGetQuery(con, s)
cat("=== features whose name looks descriptive (non SITE.POINT) ===\n")
f <- q("SELECT uuid,name FROM feature")
desc <- f[!grepl("^(B|BH|K|L)[.]", f$name), ]
cat(sprintf("%d of %d features are NOT SITE.POINT-coded\n", nrow(desc), nrow(f)))
print(head(desc[order(desc$name),"name",drop=FALSE], 40), row.names=FALSE)
cat("\n=== any feature/alias mentioning Lawson / Trade / Waste / Discharge / Dam ===\n")
print(q("SELECT uuid,name FROM feature WHERE lower(name) LIKE '%lawson%' OR lower(name) LIKE '%trade%' OR lower(name) LIKE '%waste%' OR lower(name) LIKE '%discharge%' OR lower(name) LIKE '%dam%'"), row.names=FALSE)
print(q("SELECT alias_key,kind,uuid_feature,auto_assign,n_seen FROM feature_alias WHERE lower(alias_key) LIKE '%lawson%' OR lower(alias_key) LIKE '%trade%' OR lower(alias_key) LIKE '%waste%' OR lower(alias_key) LIKE '%discharge%' OR lower(alias_key) LIKE '%dam%'"), row.names=FALSE)
cat("\n=== the two ambiguous alias keys, full detail ===\n")
print(q("SELECT fa.alias_key, fa.kind, fa.auto_assign, fa.n_seen, f.name AS feature_name, f.uuid
         FROM feature_alias fa LEFT JOIN feature f ON f.uuid=fa.uuid_feature
         WHERE fa.alias_key IN ('b.s01','k.e02') ORDER BY fa.alias_key, f.name"), row.names=FALSE)
cat("\n=== sample counts for the 4 contested features ===\n")
print(q("SELECT f.name, count(s.uuid) AS n_samples, min(s.sampled_at) AS first, max(s.sampled_at) AS last
         FROM feature f LEFT JOIN feature_alias fa ON fa.uuid_feature=f.uuid
         LEFT JOIN sample s ON s.uuid_feature_alias=fa.uuid
         WHERE f.name IN ('B.S01','B.TS41','K.E02','K.S06') GROUP BY f.name ORDER BY f.name"), row.names=FALSE)
cat("\n=== how many total alias keys remain auto_assign=FALSE (ambiguous) ===\n")
print(q("SELECT auto_assign, count(*) FROM feature_alias GROUP BY auto_assign"), row.names=FALSE)
DBI::dbDisconnect(con, shutdown=TRUE)
