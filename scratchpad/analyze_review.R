rv <- readRDS("/private/tmp/claude-501/qc-dryrun/review_all.rds")
xtr <- function(p, key){ m <- regmatches(p, regexpr(paste0(key,"=[^,]+"), p)); if(length(m)) sub(paste0(key,"="),"",m) else NA_character_ }

cat("=== TOTAL review items:", nrow(rv), "by kind ===\n"); print(table(rv$kind))
cat("\nany payload with candidates= (a suggestion)? ",
    sum(grepl("candidates=", rv$payload)), " of ", nrow(rv), "\n")

## unknown_feature
uf <- rv[rv$kind=="unknown_feature",]
feat <- vapply(uf$payload, xtr, character(1), key="feature_raw")
wo   <- vapply(uf$payload, xtr, character(1), key="work_order")
nrw  <- as.integer(vapply(uf$payload, xtr, character(1), key="n_rows"))
cand <- vapply(uf$payload, xtr, character(1), key="candidates")
det <- data.frame(feature_raw=feat, work_order=wo, n_rows=nrw, has_suggestion=!is.na(cand), stringsAsFactors=FALSE)
det <- det[order(-det$n_rows),]
cat(sprintf("\n=== unknown_feature: %d grouped items, %d distinct point names ===\n", nrow(uf), length(unique(feat))))
cat(sprintf("items WITH a suggestion: %d ; WITHOUT: %d\n", sum(det$has_suggestion), sum(!det$has_suggestion)))
cat("\n-- distinct point names (feature_raw), with #items and total rows --\n")
agg <- aggregate(cbind(items=1, rows=det$n_rows), by=list(feature_raw=det$feature_raw), FUN=sum)
agg <- agg[order(-agg$rows),]
print(agg, row.names=FALSE)
cat("\n-- point-name prefix (org) distribution --\n")
prefix <- sub("\\..*","", feat)
print(table(prefix))

## unknown_analyte
ua <- rv[rv$kind=="unknown_analyte",]
cat(sprintf("\n=== unknown_analyte: %d items ===\n", nrow(ua)))
ana <- vapply(ua$payload, xtr, character(1), key="analyte_raw")
if (all(is.na(ana))) { cat("(no analyte_raw key; raw payloads:)\n"); print(ua$payload) } else {
  print(sort(table(ana), decreasing=TRUE))
}
