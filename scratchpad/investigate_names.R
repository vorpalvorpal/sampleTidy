suppressMessages(pkgload::load_all(".", quiet=TRUE)); options(warn=-1)
db <- "/private/tmp/claude-501/qc-dryrun/monitoring_dryrun.duckdb"
con <- st_connect(db, read_only=TRUE)

names35 <- c("B.E01","B.S01","B.MW02","B.MW08","B.S39","B.MW09","Trade Waste Dam","B.S06","B.S03","B.S05","B.L01",
 "K.E02","K.E01","K.S07","K.S09","B.39","B.L02","B.MW04","B.MW07","B.MW11","B.S10","B.E39","K.S03","K.S05","K.S06",
 "Discharge Point - Lawson STP","L.L02","BH.MW02A","BH.S02","BH.S01","BH.S03","L.MW06","L.MW07","L.MW08")

# feature registry
feat <- DBI::dbGetQuery(con, "SELECT uuid, name FROM feature")
cat(sprintf("feature registry: %d points\n", nrow(feat)))
cat("\n-- are the 35 unknown names present as feature.name? --\n")
present <- names35 %in% feat$name
print(data.frame(name=names35, in_feature=present))
cat(sprintf("\npresent: %d / absent: %d\n", sum(present), sum(!present)))

# feature_alias registry: what aliases exist, and do any match?
al <- DBI::dbGetQuery(con, "SELECT alias_key, uuid_feature, kind, n_seen FROM feature_alias")
cat(sprintf("\nfeature_alias rows: %d ; resolved(uuid_feature not null): %d ; pending: %d\n",
    nrow(al), sum(!is.na(al$uuid_feature)), sum(is.na(al$uuid_feature))))
# normalise the unknown names the same way reconcile keys them, and check alias_key hits
nk <- sampleTidy:::.st_normalise_key(names35)
cat("\n-- alias_key hits for the 35 (normalised) --\n")
hit <- nk %in% al$alias_key
print(data.frame(name=names35, norm=nk, alias_hit=hit))

# For B.39 vs B.S39 and the B.* family: what B-prefixed names DOES the registry hold?
cat("\n-- registry names starting B. (first 40) --\n")
bnames <- sort(feat$name[grepl("^B\\.", feat$name)])
print(utils::head(bnames, 40))
cat("\n-- registry names containing 'Lawson' or 'Trade' or 'Discharge' --\n")
print(feat$name[grepl("Lawson|Trade|Discharge", feat$name, ignore.case=TRUE)])
DBI::dbDisconnect(con, shutdown=TRUE)
