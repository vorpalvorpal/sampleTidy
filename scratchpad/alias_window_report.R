suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1, width=210)
SNAP <- "/private/tmp/claude-501/qc-dryrun/snapshots/monitoring_pre-002-registry-remediation_20260722T232748.090Z.duckdb"
con <- st_connect(SNAP, read_only = TRUE); q <- function(s) DBI::dbGetQuery(con, s)

# per-feature activity: registry window + REAL sample window (samples hang off the self-alias)
act <- q("SELECT f.uuid, f.name, f.site, f.date_start, f.date_end,
                 count(s.uuid) AS n_samp, min(s.date) AS first_samp, max(s.date) AS last_samp
          FROM feature f
          LEFT JOIN feature_alias fa ON fa.uuid_feature=f.uuid AND fa.kind='self'
          LEFT JOIN sample s ON s.uuid_feature_alias=fa.uuid
          GROUP BY 1,2,3,4,5")
A <- function(u, col) act[[col]][match(u, act$uuid)]

na <- q("SELECT a.uuid, a.alias_key, a.name AS raw_token, a.kind, a.auto_assign, a.n_seen,
                a.uuid_feature AS tgt
         FROM feature_alias a JOIN feature f ON f.uuid=a.uuid_feature
         WHERE lower(trim(a.alias_key)) <> lower(trim(f.name))")
fk <- data.frame(k=tolower(trimws(act$name)), uuid=act$uuid, stringsAsFactors=FALSE)
na$clash <- fk$uuid[match(na$alias_key, fk$k)]
na$clash[!is.na(na$clash) & na$clash==na$tgt] <- NA

fmt <- function(d) ifelse(is.na(d), "—", as.character(as.Date(d)))
mk <- function(df) data.frame(
  alias_key = df$alias_key, kind = df$kind, n_seen = df$n_seen,
  resolves_to = A(df$tgt,"name"),
  tgt_samples = A(df$tgt,"n_samp"),
  tgt_first = fmt(A(df$tgt,"first_samp")), tgt_last = fmt(A(df$tgt,"last_samp")),
  tgt_reg_start = fmt(A(df$tgt,"date_start")), tgt_reg_end = fmt(A(df$tgt,"date_end")),
  stringsAsFactors = FALSE)

cat("SOURCE:", SNAP, "\n")
cat("(post-001, pre-002, pre-dry-run-ingest. 894 features / 1989 aliases / 15113 samples.)\n")
cat("n_seen = times the token appeared in the curated cypher/feature_mask import — NOT data occurrences.\n")
cat("Samples never link to non-self aliases, so per-alias usage is unrecoverable; the *competing features'*\n")
cat("sample windows below are the evidence for setting alias date_start/date_end.\n")

cat(sprintf("\n\n########## A. COLLISION CLASS: alias key IS another feature's real name (%d) ##########\n",
            sum(!is.na(na$clash))))
cat("These are the ones that need date bounds. For each: the key, who it currently resolves to,\n")
cat("and the SAME-NAMED feature it is stealing the string from.\n\n")
a <- na[!is.na(na$clash),]; a <- a[order(a$alias_key),]
out <- mk(a)
out$SAMENAME_feature <- A(a$clash,"name")
out$same_samples <- A(a$clash,"n_samp")
out$same_first <- fmt(A(a$clash,"first_samp")); out$same_last <- fmt(A(a$clash,"last_samp"))
print(out, row.names=FALSE)

cat(sprintf("\n\n########## B. all other historical_code aliases (code-like keys, %d) ##########\n",
            sum(is.na(na$clash) & na$kind=="historical_code")))
b <- na[is.na(na$clash) & na$kind=="historical_code",]; b <- b[order(b$alias_key),]
print(mk(b), row.names=FALSE)

cat(sprintf("\n\n########## C. descriptive + mask_long (%d) — summary only ##########\n",
            sum(is.na(na$clash) & na$kind!="historical_code")))
cnt <- na[is.na(na$clash) & na$kind!="historical_code",]
print(as.data.frame(table(kind=cnt$kind)), row.names=FALSE)
saveRDS(list(all=na, activity=act), "scratchpad/alias_windows.rds")
DBI::dbDisconnect(con, shutdown=TRUE)
