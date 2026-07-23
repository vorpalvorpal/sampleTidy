# Robin's rulings, 2026-07-23, applied through the mutation layer.
# Usage: Rscript scratchpad/apply_robin_2026-07-23.R [apply]
suppressMessages(devtools::load_all("/Users/rjs/dev/sampleTidy", quiet = TRUE))
APPLY <- identical(commandArgs(trailingOnly = TRUE)[1], "apply")
ACTOR <- "R. Shannon"
DB <- st_config("live_db")
cat("db      :", DB, "\napply   :", APPLY, "\n\n")

say <- function(...) cat(if (APPLY) "[APPLY] " else "[DRY]   ", ..., "\n", sep = "")

## ---- 1. B.S01 and K.E02 -> their real features -----------------------------
ALIAS_B <- "5ff837f9-df60-4974-b9a5-a4a59fa24f38"; FEAT_B <- "ba5641b6-0cda-4093-8bbe-ddaec6e51517"
ALIAS_K <- "bfaf4406-6ee2-48e4-af92-f125d21e44cc"; FEAT_K <- "d9d85ff2-8bd9-4a27-a21c-b057eab62613"
say("confirm alias b.s01 (", ALIAS_B, ") -> feature B.S01")
say("confirm alias k.e02 (", ALIAS_K, ") -> feature K.E02")
if (APPLY) {
  print(confirm_feature_aliases(
    uuid_alias = c(ALIAS_B, ALIAS_K), uuid_feature = c(FEAT_B, FEAT_K),
    confirmed_by = ACTOR, db = DB))
}

## ---- 2. Sodium Adsorption Ratio -> the existing SAR analyte -----------------
LAB_SAR <- "c0e39944-2fc1-4485-8c46-3c069bd06bdb"   # ALS "EA006: Sodium Adsorption Ratio (SAR)"
AN_SAR  <- "295e1b9b-8d1f-4d44-9e9e-67e2322a0e96"   # analyte "SAR"
say("confirm lab_method SAR (", LAB_SAR, ") -> analyte SAR")
if (APPLY) {
  print(confirm_analyte_methods(uuid_lab = LAB_SAR, uuid_analyte = AN_SAR,
                                confirmed_by = ACTOR, db = DB))
}

## ---- 3. unknown time -> 10:00 Australia/Sydney ------------------------------
# Stored naive-UTC, so 10:00 Sydney is 00:00 UTC in AEST and 23:00 UTC the
# previous day in AEDT. Compute per row; never hard-code an offset.
with_db_write(function(con) {
  rows <- DBI::dbGetQuery(con,
    'SELECT uuid, CAST("date" AS DATE) AS d FROM "sample"
      WHERE datetime IS NULL AND "date" IS NOT NULL')
  if (!nrow(rows)) { say("no NULL-datetime rows with a date"); return(invisible()) }
  local_10 <- as.POSIXct(paste(rows$d, "10:00:00"), tz = "Australia/Sydney")
  naive_utc <- format(local_10, tz = "UTC", format = "%Y-%m-%d %H:%M:%S")
  say(nrow(rows), " sample(s) get datetime = 10:00 Sydney")
  print(utils::head(data.frame(uuid = rows$uuid, date = rows$d,
                               stored_naive_utc = naive_utc), 8))
  if (APPLY) {
    for (i in seq_len(nrow(rows))) {
      db_update(con, "sample", uuid = rows$uuid[i],
                changes = list(datetime = as.POSIXct(naive_utc[i], tz = "UTC")),
                actor = ACTOR,
                reason = "unknown sampling time set to 10:00 local (Robin, 2026-07-23)")
    }
    cat("  updated", nrow(rows), "rows\n")
  }
}, db = DB)

## ---- 4 & 5. EPA mask corrections --------------------------------------------
with_db_write(function(con) {
  say("analyte_mask EPA name for TSS -> 'Total Suspended Solids'")
  if (APPLY) {
    db_update(con, "analyte_mask",
              key = list(uuid_analyte = "2bc1e3bd-43fc-4b5d-a656-65cae9958968", variant = "EPA"),
              changes = list(name = "Total Suspended Solids"),
              actor = ACTOR, reason = "EPA mask name was NULL, excluding TSS from the EPA return (Robin, 2026-07-23)")
  }
  say("analyte_mask EPA units for Standing water level: 'mg/L' -> 'm'")
  if (APPLY) {
    db_update(con, "analyte_mask",
              key = list(uuid_analyte = "e4a4002c-ea26-4517-aca6-2706f609343d", variant = "EPA"),
              changes = list(units = "m"),
              actor = ACTOR, reason = "a water level was masked as a concentration (Robin, 2026-07-23)")
  }
}, db = DB)

## ---- verify + mandatory snapshot -------------------------------------------
if (APPLY) {
  with_db_write(function(con) {
    cat("\n=== after ===\n")
    cat("pending features :", nrow(pending_features(con)), "\n")
    cat("pending analytes :", nrow(pending_analytes(con)), "\n")
    cat("NULL datetime    :", DBI::dbGetQuery(con, 'SELECT count(*) n FROM "sample" WHERE datetime IS NULL')$n, "\n")
    print(DBI::dbGetQuery(con, "SELECT a.name AS analyte, am.name AS epa_name, am.units AS epa_units FROM analyte_mask am JOIN analyte a ON a.uuid=am.uuid_analyte WHERE am.variant='EPA' AND a.uuid IN ('2bc1e3bd-43fc-4b5d-a656-65cae9958968','e4a4002c-ea26-4517-aca6-2706f609343d')"))
    cat("change_log rows  :", DBI::dbGetQuery(con, "SELECT count(*) n FROM change_log")$n, "\n")
  }, db = DB)
  cat("\nsnapshot ->", snapshot_db(db = DB, dest_dir = st_config("snapshot_dir")), "\n")
}
cat("\nDONE\n")
