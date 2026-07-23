# Probe: does the macOS bracket suffix break work-order/revision parsing?
suppressMessages(devtools::load_all("/Users/rjs/dev/sampleTidy", quiet = TRUE))

d <- file.path(
  "/Users/rjs/OneDrive - Blue Mountains City Council",
  "Sharepoint/waste_data - Environmental monitoring/assets/input"
)
p <- list.files(d, full.names = TRUE)
p <- p[grepl("ES2520710|ES2517594|ES2608966", basename(p)) &
       grepl("[.](CSV|XML)$", basename(p), ignore.case = TRUE)]

for (f in p) {
  m <- try(file_meta(f), silent = TRUE)
  if (inherits(m, "try-error")) {
    cat(sprintf("%-60s FAILED: %s\n", substr(basename(f), 1, 60),
                sub("\n.*", "", conditionMessage(attr(m, "condition")))))
  } else {
    cat(sprintf("%-60s wo=%-11s rev=%-3s adapter=%s\n",
                substr(basename(f), 1, 60),
                m$work_order, m$revision, m$adapter))
  }
}
