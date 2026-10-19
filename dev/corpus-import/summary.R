# Corpus import summary. Usage: Rscript dev/corpus-import/summary.R <after_db> <before_db> <run_root>
# Both DBs are opened read-only.
options(width=220, max.print=5000)
a <- commandArgs(TRUE); W <- a[3]
con <- DBI::dbConnect(duckdb::duckdb(), a[1], read_only=TRUE)
DBI::dbExecute(con, sprintf("ATTACH '%s' AS p (READ_ONLY)", a[2]))
q <- function(s) DBI::dbGetQuery(con, s)
pf <- read.csv(file.path(W, "out/run/per_file.csv"), stringsAsFactors=FALSE)
pb <- read.csv(file.path(W, "out/run/per_batch.csv"), stringsAsFactors=FALSE)
cat("batches:", nrow(pb), " batch errors:", sum(!is.na(pb$error)), " events_failed:", sum(pb$events_failed, na.rm=TRUE), "\n")
cat("files:", nrow(pf), " unique hashes:", length(unique(pf$hash)), "\n")
f <- q("select hash, state, state_reason from ingest_file")
pf$state <- f$state[match(pf$hash, f$hash)]
pf$was_before <- pf$hash %in% q("select hash from p.ingest_file")$hash
cat("\n== files by state (new to DB / already in DB before)\n"); print(table(pf$state, ifelse(pf$was_before,"before","new"), useNA="ifany"))
cat("\n== failed files\n"); print(pf[pf$state %in% "failed", c("batch","file")], row.names=FALSE)
cat("\n== table deltas\n")
for (t in c("sample","analysis","project","feature","feature_alias","asset","ingest_file","review_queue","change_log"))
  cat(sprintf("%-14s %8d -> %8d  (+%d)\n", t, q(sprintf('select count(*) n from p."%s"',t))$n, q(sprintf('select count(*) n from "%s"',t))$n,
      q(sprintf('select count(*) n from "%s"',t))$n - q(sprintf('select count(*) n from p."%s"',t))$n))
cat("removed sample rows:", q("select count(*) n from p.sample where uuid not in (select uuid from sample)")$n,
    " removed analysis rows:", q("select count(*) n from p.analysis where uuid not in (select uuid from analysis)")$n, "\n")
cat("\n== NEW review items by kind/subkind/status\n")
rq <- q("select * from review_queue where uuid not in (select uuid from p.review_queue)")
print(as.data.frame(table(kind=rq$kind, subkind=ifelse(is.na(rq$subkind),"-",rq$subkind), status=rq$status)) |> subset(Freq>0), row.names=FALSE)
uf <- rq[rq$kind=="unknown_feature",]
if (nrow(uf)) { fr <- vapply(uf$payload, function(p) tryCatch({x<-jsonlite::fromJSON(p); as.character(x$feature_raw %||% x$raw %||% x$name %||% NA)}, error=function(e) NA_character_), ""); uf$fr<-fr; k<-uf[!is.na(uf$subkind),]; print(table(k$fr, k$subkind)); cat("unknown_feature subkind NA:", sum(is.na(uf$subkind)), "distinct raw:", length(unique(uf$fr[is.na(uf$subkind)])), "
") }
cat("\n== duplicate_report_number items\n")
dr <- rq[rq$kind=="duplicate_report_number",]
if (nrow(dr)) { ins <- q("select source_hash, count(*) n from change_log where uuid not in (select uuid from p.change_log) and tbl='analysis' and action='insert' group by 1")
  dr$file <- pf$file[match(dr$source_hash, pf$hash)]; dr$fstate <- f$state[match(dr$source_hash, f$hash)]
  dr$analyses_inserted_by_file <- ins$n[match(dr$source_hash, ins$source_hash)]
  print(dr[, c("work_order","subkind","file","fstate","analyses_inserted_by_file","status")], row.names=FALSE) } else cat("none\n")
cat("\n== other (non-unknown_feature) new items, detail\n")
o <- rq[rq$kind!="unknown_feature",]; o$file <- pf$file[match(o$source_hash, pf$hash)]
if (nrow(o)) print(cbind(o[, c("kind","subkind","work_order","file","status")], payload=substr(o$payload,1,200)), row.names=FALSE)
