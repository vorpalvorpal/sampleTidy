suppressMessages(pkgload::load_all(".", quiet=TRUE))
corpus <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets/input"
chem <- file.path(corpus, "BWMF - E1 - April 2025 Rain Event.ESDAT_ES2509336_0.Chemistry2e.CSV")
meta <- sampleTidy:::file_meta(chem)
out <- sampleTidy:::adapter_registry()[["esdat"]]$parse(chem, meta)
r <- out$results
na_wo <- is.na(r$work_order)
cat(sprintf("rows with NA work_order: %d\n", sum(na_wo)))
cat("their distinct SampleCodes (lab_sample_id):\n")
print(table(r$lab_sample_id[na_wo]))
