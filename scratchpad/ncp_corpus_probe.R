suppressMessages(pkgload::load_all(".", quiet=TRUE))
corpus <- "/Users/rjs/Library/CloudStorage/OneDrive-BlueMountainsCityCouncil/Sharepoint/waste_data - Environmental monitoring/assets/input"
chem <- file.path(corpus, "BWMF - E1 - April 2025 Rain Event.ESDAT_ES2509336_0.Chemistry2e.CSV")
meta <- sampleTidy:::file_meta(chem)
out <- sampleTidy:::adapter_registry()[["esdat"]]$parse(chem, meta)
r <- out$results
cat(sprintf("total results: %d\n", nrow(r)))
cat("sample_type breakdown:\n"); print(table(r$sample_type, useNA="ifany"))
cat("\nwork_order breakdown (top):\n"); print(head(sort(table(r$work_order), decreasing=TRUE), 6))
home <- "ES2509336"
ncp <- r$sample_type == "NCP"
own <- !is.na(r$work_order) & r$work_order == home
foreign_nonNCP <- !own & !ncp
cat(sprintf("\nhome(own)=%d  NCP(drop)=%d  foreign-non-NCP(would-flag)=%d\n",
    sum(own), sum(ncp), sum(foreign_nonNCP)))
cat("foreign-non-NCP work_orders (should be ~0):\n")
print(table(r$work_order[foreign_nonNCP]))
