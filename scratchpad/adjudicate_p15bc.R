suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1, width=200)
DB <- "/private/tmp/claude-501/qc-dryrun/snapshots/monitoring_pre-002-registry-remediation_20260722T232748.090Z.duckdb"
con <- st_connect(DB, read_only=TRUE); q <- function(s) DBI::dbGetQuery(con,s)
cat("ADJUDICATION SOURCE:", DB, "\n\n")

cat("### B1: does bs1/bs2/bs3 -> BH.*, auto_assign? does bs01 exist? do both B.S01 and BH.S01 exist?\n")
print(q("SELECT a.alias_key,a.kind,a.auto_assign,f.name FROM feature_alias a JOIN feature f ON f.uuid=a.uuid_feature
         WHERE a.alias_key IN ('bs1','bs2','bs3','bs01','bs02','bs03') ORDER BY 1"), row.names=FALSE)
print(q("SELECT name,site FROM feature WHERE name IN ('B.S01','BH.S01')"), row.names=FALSE)

cat("\n### B2: digit widths per site+stem (G series)\n")
print(q("SELECT site, regexp_extract(name,'^[A-Za-z]+\\.([A-Za-z]+)',1) AS stem,
                length(regexp_extract(name,'([0-9]+)',1)) AS w, count(*) n
         FROM feature WHERE regexp_extract(name,'([0-9]+)',1) <> ''
         AND regexp_extract(name,'^[A-Za-z]+\\.([A-Za-z]+)',1) IN ('G','TG')
         GROUP BY 1,2,3 ORDER BY 1,2,3"), row.names=FALSE)
cat("\n-- B2 collision test: is leading-zero-STRIP injective over (site, canonical point)?\n")
f <- q("SELECT name, site FROM feature")
pt <- sub("^[^.]*\\.", "", f$name)
canon <- toupper(gsub("(^|[^0-9])0+([0-9])", "\\1\\2", pt))
key <- paste(toupper(f$site), canon, sep=".")
cat(sprintf("   features=%d  distinct canonical (site,point)=%d  -> collisions=%d\n",
            nrow(f), length(unique(key)), nrow(f)-length(unique(key))))
d <- key[duplicated(key)]; if(length(d)) print(f[key %in% d,][order(key[key %in% d]),], row.names=FALSE)
cat("\n-- and is PAD-TO-2 injective? (reviewer says it breaks B.G###)\n")
pad2 <- toupper(gsub("([0-9]+)", "", pt)); # just count width spread instead
w <- nchar(regmatches(pt, regexpr("[0-9]+", pt)))
cat("   digit-run widths present overall:", paste(sort(unique(w)), collapse=","), "\n")

cat("\n### B3: site column values + does name prefix == site for all 894?\n")
print(q("SELECT site, count(*) FROM feature GROUP BY 1 ORDER BY 2 DESC"), row.names=FALSE)
pre <- sub("[.].*$","",f$name)
cat(sprintf("   name-prefix == site : %d of %d\n", sum(pre==f$site), nrow(f)))
cat(sprintf("   distinct sites: %s\n", paste(sort(unique(f$site)),collapse=", ")))
DBI::dbDisconnect(con, shutdown=TRUE)
