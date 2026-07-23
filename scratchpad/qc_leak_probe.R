suppressMessages(pkgload::load_all(".", quiet=TRUE))
corpus <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets/input"
base <- "BWMF - E1 - April 2025 Rain Event.ESDAT_ES2509336_0"
chem <- file.path(corpus, paste0(base, ".Chemistry2e.CSV"))
samp <- file.path(corpus, paste0(base, ".Sample2e[4].CSV"))

reg <- sampleTidy:::adapter_registry()
parse_one <- function(path) {
  fm <- file_meta(path)
  out <- reg[["esdat"]]$parse(path, fm)
  list(ir = list(results = out$results, samples = out$samples),
       report = out$report, meta = fm)
}

parsed <- list()
for (p in c(chem, samp)) parsed[[hash_file(p)]] <- parse_one(p)

rh <- names(parsed)[1]
r <- parsed[[rh]]$ir$results
cat(sprintf("=== RAW chem results: %d ===\n", nrow(r)))
cat("raw sample_type:\n"); print(table(r$sample_type, useNA="ifany"))
isqc <- grepl("^QC-", r$lab_sample_id)
cat(sprintf("QC- coded rows (lab_sample_id): %d\n", sum(isqc, na.rm=TRUE)))
cat("work_order for QC- rows (raw):\n"); print(table(r$work_order[isqc], useNA="ifany"))

cat("\n=== assemble_events ===\n")
asm <- assemble_events(parsed)
ev <- asm$events[[1]]
fr <- ev$results
cat(sprintf("event results (post partition+join): %d\n", nrow(fr)))
cat("post-join sample_type:\n"); print(table(fr$sample_type, useNA="ifany"))
flagged <- fr$needs_review %in% TRUE
cat(sprintf("flagged needs_review: %d\n", sum(flagged)))
cat("review_kind of flagged:\n"); print(table(fr$review_kind[flagged], useNA="ifany"))
cat("sample_type of flagged rows (THE LEAK if QC types appear):\n")
print(table(fr$sample_type[flagged], useNA="ifany"))
