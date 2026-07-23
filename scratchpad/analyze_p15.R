suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
scratch <- "/private/tmp/claude-501/qc-dryrun"
rv <- readRDS(file.path(scratch, "review_all.rds"))
xtr <- function(p,k){ m<-regmatches(p,regexpr(paste0(k,"=[^,]+"),p)); if(length(m)) sub(paste0(k,"="),"",m) else NA_character_ }
uf <- rv[rv$kind=="unknown_feature",]
feat <- vapply(uf$payload,xtr,character(1),"feature_raw")
wo   <- vapply(uf$payload,xtr,character(1),"work_order")
cand <- vapply(uf$payload,xtr,character(1),"candidates")
nrw  <- suppressWarnings(as.integer(vapply(uf$payload,xtr,character(1),"n_rows")))
det <- data.frame(feature_raw=feat, wo=wo, n_rows=nrw, candidates=cand, stringsAsFactors=FALSE)
det <- det[order(-ifelse(is.na(det$n_rows),0,det$n_rows)),]
cat(sprintf("unknown_feature grouped items: %d ; WITH candidate: %d ; without: %d\n",
            nrow(det), sum(!is.na(cand)), sum(is.na(cand))))
cat("\n=== all unknown_feature point names (feature_raw | n_rows | candidates) ===\n")
print(det, row.names=FALSE)

# Cross-site mis-merge guard: map each candidate uuid -> feature.name, and flag any
# BS1/BS3-type raw whose candidate resolves to a B.* (should be BH.*) or vice versa.
con <- st_connect(file.path(scratch,"monitoring_dryrun.duckdb"), read_only=TRUE)
fmap <- DBI::dbGetQuery(con,"SELECT uuid,name FROM feature")
site_of <- function(nm) sub("[.[:space:]].*$","",nm)
cat("\n=== candidate uuid -> feature.name (for the ambiguous items) ===\n")
for (i in which(!is.na(cand))) {
  us <- strsplit(cand[i],"|",fixed=TRUE)[[1]]
  nms <- fmap$name[match(us, fmap$uuid)]
  cat(sprintf("  %-14s -> %s  [sites: %s]\n", feat[i], paste(nms,collapse=", "),
              paste(unique(site_of(nms)),collapse="/")))
}
# Did any BS1/BS3-ish raw resolve/suggest a B.* feature (the false-merge we must avoid)?
susp <- det[grepl("^BS[0-9]", det$feature_raw, ignore.case=TRUE),]
cat("\n=== BS#-type raws (collision family) and their candidates ===\n")
if(nrow(susp)) print(susp, row.names=FALSE) else cat("(none present in residual)\n")
DBI::dbDisconnect(con, shutdown=TRUE)
