suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1, width=200)
DB <- "/private/tmp/claude-501/qc-dryrun/snapshots/monitoring_pre-002-registry-remediation_20260722T232748.090Z.duckdb"
cat("SOURCE DB:", DB, "\n(migrated through 001-alias-indirection; taken BEFORE 002 and BEFORE the 265-file dry-run ingest,\n so usage counts + dates are HISTORICAL data only.)\n\n")
con <- st_connect(DB, read_only = TRUE)
q <- function(s) DBI::dbGetQuery(con, s)

cat("=== sanity: totals ===\n")
print(q("SELECT (SELECT count(*) FROM feature) AS features,
                (SELECT count(*) FROM feature_alias) AS aliases,
                (SELECT count(*) FROM sample) AS samples"), row.names=FALSE)

# An alias 'points at something other than the actual feature' when its own key does not
# equal the normalised name of the feature it resolves to.
res <- q("
WITH fa AS (
  SELECT a.uuid, a.alias_key, a.name AS alias_name, a.kind, a.auto_assign, a.n_seen,
         f.uuid AS f_uuid, f.name AS resolves_to, f.site AS target_site
  FROM feature_alias a JOIN feature f ON f.uuid = a.uuid_feature
  WHERE lower(trim(a.alias_key)) <> lower(trim(f.name))
),
use AS (
  SELECT s.uuid_feature_alias AS ua, count(*) AS n_used,
         min(s.date) AS first_used, max(s.date) AS last_used
  FROM sample s GROUP BY 1
),
-- does the alias key ALSO look exactly like some OTHER real feature's name?
clash AS (
  SELECT lower(trim(name)) AS k, uuid, name FROM feature
)
SELECT fa.alias_key, fa.kind, fa.resolves_to, fa.target_site,
       fa.auto_assign, fa.n_seen,
       COALESCE(u.n_used,0) AS n_used, u.first_used, u.last_used,
       c.name AS key_is_also_feature
FROM fa
LEFT JOIN use   u ON u.ua = fa.uuid
LEFT JOIN clash c ON c.k = fa.alias_key AND c.uuid <> fa.f_uuid
ORDER BY (c.name IS NOT NULL) DESC, COALESCE(u.n_used,0) DESC, fa.alias_key")

cat(sprintf("\n=== %d aliases whose key differs from the feature they resolve to ===\n", nrow(res)))
cat(sprintf("    of which USED by >=1 sample: %d ; never used: %d\n",
            sum(res$n_used>0), sum(res$n_used==0)))
cat(sprintf("    of which the key is ALSO the exact name of a DIFFERENT feature (collision class): %d\n\n",
            sum(!is.na(res$key_is_also_feature))))

cat("### A. COLLISION CLASS — alias key is itself another feature's real name (highest risk)\n")
a <- res[!is.na(res$key_is_also_feature),]
print(a, row.names=FALSE)

cat("\n### B. USED aliases (n_used > 0), non-colliding\n")
b <- res[is.na(res$key_is_also_feature) & res$n_used>0,]
print(b[,setdiff(names(b),"key_is_also_feature")], row.names=FALSE)

cat("\n### C. UNUSED aliases (n_used == 0), non-colliding — summary by kind\n")
cc <- res[is.na(res$key_is_also_feature) & res$n_used==0,]
print(as.data.frame(table(kind=cc$kind)), row.names=FALSE)
saveRDS(res, "scratchpad/alias_usage.rds")
cat(sprintf("\n(full table saved to scratchpad/alias_usage.rds — %d rows)\n", nrow(res)))
DBI::dbDisconnect(con, shutdown=TRUE)
