# Operator-run migration: correct legacy ACIRL field readings to their own
# ACIRL report ("the workbook wins", as 016 and 019 did for dust).
#
# Authorised 2026-10-17 by the main session under Robin's "the workbook wins"
# precedent (016, 019), on the investigation in
# scratchpad/2026-10-17-fieldconflict/ (PROPOSAL.md, corrections.csv). The EC
# enumeration and every cell citation below are from
# scratchpad/2026-10-17-mig029/ (enum_ec.R, match_ec.R, build_plan.R).
#
# ---- WHAT 029 DOES (live, marker 1028) -------------------------------------
#
# 1. 2022-09-07 B.S05, ES2232312 (sample be1b9b70): Temperature 14.1 -> 14.7.
#    Both reports print 14.7: 2400-7222-09-01 Surface Sites!r15c9 and its pdf,
#    and 2400-7222-09 (ES2232317) xls and pdf. Transcription error.
#
# 2. 2022-09-07 sample 2ad2d3c6 (ES2232312, stored on alias B.S06) is ALS
#    ES2232312003, labelled B.S22: its 4 ALS results (NH3-N 12.4, TOC 17, BOD 6,
#    COD 34) match the ESdat exactly, and 2400-7222-09-01 lists S22, not S06
#    (Surface Sites column 6). The day's real B.S06 is on ES2232317 (NH3-N 29,
#    TOC 59). The WHOLE sample is re-pointed to alias B.S22 (e24bdbc4, B.S22's
#    self alias, undated) and keeps every analysis (3 ACIRL field + 4 ALS). Its
#    field values stay as stored, except EC 651.4 -> 651 under item 4. A
#    sentence is appended to its comments. No other sample of feature B.S22 is
#    on that Sydney day, and (e24bdbc4, datetime, project) does not clash on
#    ux_sample_identity (both asserted).
#
# 3. 2023-09-13 ES2331527, samples 63400f6e (B.S01) and 316ea653 (B.S03): the
#    legacy author swapped the WHOLE samples because of TSS (his sample
#    comment). That is a lab correction and stays: the samples are NOT
#    re-pointed and their ALS results are not touched. But the site field
#    readings moved with them. Both reports (2400-7286-09 and -09-01, xls and
#    pdf) give S01 = 13.6 / 5.9 / 210 and S03 = 11 / 4.1 / 174, and the samples
#    hold the reverse. The Temperature, pH and EC values are swapped between
#    the two samples. Appearance and Stage are identical on both (Clear / Low
#    flow) and are left alone.
#
#    HOW: the 6 `value`s are swapped in place (6 db_update calls). The rows are
#    not moved between samples. Within each pair, every other column is
#    identical (quantified TRUE, rl_low / rl_high / purpose / comments NULL;
#    asserted), so a value swap and a row move give the same table except for
#    which uuid sits on which sample. The swap keeps each uuid's meaning as
#    "this sample's <analyte>": uuid_sample and uuid_lab, the two FK columns,
#    never change. It needs no delete and re-insert (a per-row UPDATE of
#    analysis.uuid_sample hits the duckdb 1.4.1 FK index quirk noted in 024 and
#    027). change_log gets a field-level old/new for each value. None of the 6
#    uuids has any earlier change_log history or a review_queue reference.
#
# 4. EC precision. 45 legacy ACIRL field EC values carry a fractional part
#    (31 in 2022, 14 in 2023; none in other years). Each was matched to its OWN
#    order's ACIRL report: the one report whose `als_work_orders` is the
#    sample's project, at the sample's point, read with
#    acirl_field_xlsx_adapter, which is what re-ingest compares against.
#      30 CHANGED to the report's value (one plan row each, with its cell):
#         29 a pure precision difference (|stored - printed| <= 0.5);
#          1 NOT a rounding: 2022-09-07 B.MW09 ES2232312 333.8 -> 339
#            (2400-7222-09-01 Groundwater Sites!r17c9 and its pdf both print 339).
#      11 KEPT: the stored value already equals its own report's cell
#         (2022-09-07 B.MW06/07/08/11 ES2232312 and B.S05 ES2232317; 2022-09-21
#         B.S03; 2022-10-26 B.E01/S01/S03/S05/S06).
#       4 EXCLUDED:
#         2022-08-31 B.S01 428.2, B.S03 242.2, B.S05 122.9 (ES2231240): the report,
#           2400-7222-08-06, exists only as a dehydrated pdf under
#           backup/2022-09-14/R/import/www/temp/; there is no xls. Not read.
#         2023-05-15 B.S05 140.6 (ES2316165): 2400-7286-05-08 Groundwater
#           Sites!r15c3 prints 1406, a slipped decimal. The ALS EA010P EC on
#           the same sample is 141, and B.S05 ran 133-160 that month.
#    Where the pdf was read (2400-7222-09, -09-01, 2400-7286-05-04, -05-06) it
#    agrees with the xls, except 2022-09-07 B.S03 ES2232317: the xls holds 94.7
#    and the pdf prints 95. 029 writes the xls value, 94.7, because that is what
#    re-ingest compares. The other reports' pdfs are dehydrated and were not
#    read.
#
# NOT TOUCHED, by ruling (the two reports disagree and each sample matches its
# own report): 2023-05-10 B.S05 T/pH, 2023-06-14 B.S01/B.S03, 2023-09-13 B.S05
# Appearance, 2024-04-22 K.S09. Both identical-copy days (2022-09-07 B.S03,
# 2023-05-10 B.S01) stay doubled. Their EC values do take item 4: 95 / 94.7 and
# 239 / 239.
#
# ---- THE FK STEPS (024's pattern, measured on copies of live) ----------------
#
# The sample UPDATE of uuid_feature_alias, an indexed and FK column, runs in
# duckdb as delete + insert. The analysis -> sample FK refuses it while
# analyses reference the sample, even when those analyses were deleted
# earlier in the same transaction (measured: scratchpad/2026-10-17-mig029/
# fkexp.R). So there are two commits, on two connections:
#   A. ONE set-based DELETE of the sample's 7 analyses (count asserted), with
#      the change_log rows db_delete() would write. COMMIT, then disconnect.
#   B. A fresh connection, in one transaction: db_update() the sample's alias
#      and comments; db_append() the 7 analyses back with the same uuids and
#      every column as they were (they are hard-coded below and asserted equal
#      to live first); every value db_update() (items 1, 3, 4); the marker;
#      verify; checksum.
# After B the FK still protects the re-pointed sample: a test DELETE of it is
# refused (measured).
# RESUMABLE: if B fails after A committed, a re-run recognises the post-A
# state (the 7 analyses and nothing else gone, 029's 7 delete change_log rows,
# no other 029 write) and runs B alone, re-inserting from the hard-coded rows.
# Any other state is refused; restore from the printed backup.
#
# Everything else is checksummed before A and after B: every base table except
# analysis / sample / change_log / schema_version whole; analysis minus the
# planned rows; the planned rows' non-value columns; sample minus 2ad2d3c6;
# 2ad2d3c6 minus alias and comments; change_log minus 029's rows; views;
# indexes.
#
# BACKUP OF THE ROWS: `029-legacy-field-corrections-BACKUP-{analysis,sample}.csv`
# beside this file (the 43 analyses written and the one sample, as they were),
# plus the verified whole-file backup in `snapshot_dir`.
#
# Marker 1029. Requires 1028. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/029-legacy-field-corrections.R", envir = env)
#   env$mig029_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig029_marker_version <- 1029L
.mig029_requires <- 1028L
.mig029_name <- "029-legacy-field-corrections"
.mig029_actor <- .mig029_name

# The re-pointed sample (item 2).
.mig029_sample <- "2ad2d3c6-3770-4b32-8994-92d7e8175d37"
.mig029_alias_from <- "20969dd8-5001-40f6-83d7-56ecb76aacf7"  # B.S06 self alias
.mig029_alias_to <- "e24bdbc4-7436-419d-a91f-892eb900d8e9"    # B.S22 self alias
.mig029_feature_to <- "a640437a-5e7a-4691-83fe-7358b0d7e8b3"  # B.S22
.mig029_project <- "3dda2c66-e73e-431a-b9d3-c6c4e85b0f37"     # ES2232312
.mig029_comment_from <- "Low flow. Cloudy."
.mig029_comment_to <- paste(
  "Low flow. Cloudy.",
  "[029, 2026-10-17: re-pointed from B.S06 to B.S22. This sample is ALS ES2232312003, labelled B.S22 on the ALS",
  "ESdat; its NH3-N 12.4, TOC 17, BOD 6 and COD 34 match it, and ACIRL 2400-7222-09-01 lists S22, not S06.",
  "The legacy load filed it as B.S06. That day's B.S06 sample is on ES2232317.]")

# Its 7 analyses exactly as they are at marker 1028 (asserted equal to live,
# and re-inserted from here in step B).
.mig029_moved <- data.frame(
  uuid = c("1566c4df-dbdd-4eed-85ec-2157be44d6cc", "900c64bc-3f0a-4645-b54d-3632f264bc0a", "b310a9ef-da56-4ea5-91ab-43ebe9bd0959",
           "b98ff5f1-21f3-4b20-b3b6-98d19bb273ed", "c0846257-fd76-4580-9660-73471479e53e", "c276c768-b33c-4f3f-b0c0-3e0ef2dd3fd8",
           "d1752d6c-6c9e-47e0-9085-2545ba9619f3"),
  uuid_sample = "2ad2d3c6-3770-4b32-8994-92d7e8175d37",
  uuid_lab = c("d99b91ab-6eca-483e-be29-16233b3e1533", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "94083b45-9e8c-486a-8a51-515be3e17434",
               "c00249fb-c7c1-470c-9352-cd3e7bf011a2", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "b9ae6f22-1f6f-4b9b-8e7c-efe86089567c",
               "d5e56ba0-c5b3-4e58-8a39-cf83d2b15e9d"),
  value = c(7.95, 17.8, 6, 34, 651.4, 17, 12.4),
  value_chr = NA_character_,
  quantified = TRUE,
  rl_low = c(0, 0, 2, 10, 0, 1, 0.01),
  rl_high = NA_real_,
  purpose = NA_character_,
  comments = NA_character_,
  stringsAsFactors = FALSE)

.mig029_row <- function(item, uuid, uuid_sample, uuid_lab, feat, day, proj, analyte, old, new, report, cell, pdf) {
  data.frame(item = item, uuid = uuid, uuid_sample = uuid_sample, uuid_lab = uuid_lab, feat = feat, day = day,
             proj = proj, analyte = analyte, old = old, new = new, report = report, cell = cell, pdf = pdf,
             stringsAsFactors = FALSE)
}

# One row per value update. feat / day / proj are the sample's as stored at
# 1028 (2ad2d3c6 is still B.S06 there). report = the sample's own ACIRL report
# (the one citing its ALS order), cell = the adapter's source_ref in its xls,
# pdf = what that report's pdf prints, where it was read.
.mig029_plan <- rbind(
  .mig029_row("1-temperature", "31dd932b-4459-4eff-9dcb-f64480794ec3", "be1b9b70-c7a3-4c09-91d0-707449fb1573", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S05", "2022-09-07", "ES2232312", "Temperature", 14.1, 14.7, "2400-7222-09-01", "Surface Sites!r15c9", "14.7"),
  .mig029_row("3-swap", "25b12d61-d325-42b4-b560-144ff91c18c8", "63400f6e-9f42-42ae-9ddb-d7be4541d763", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S01", "2023-09-13", "ES2331527", "Temperature", 11, 13.6, "2400-7286-09", "Surface Sites!r13c5", "13.6"),
  .mig029_row("3-swap", "23c9262e-62e5-4757-b77e-0a77da4c329c", "63400f6e-9f42-42ae-9ddb-d7be4541d763", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S01", "2023-09-13", "ES2331527", "pH", 4.1, 5.9, "2400-7286-09", "Surface Sites!r14c5", "5.9"),
  .mig029_row("3-swap", "8e224dfb-bb79-404e-af85-a3d6150c9bb3", "63400f6e-9f42-42ae-9ddb-d7be4541d763", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2023-09-13", "ES2331527", "EC", 174, 210, "2400-7286-09", "Surface Sites!r15c5", "210"),
  .mig029_row("3-swap", "97277d9e-185c-4641-88f1-3b9fa204173d", "316ea653-80b9-42c5-890f-c1098bb247af", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "B.S03", "2023-09-13", "ES2331527", "Temperature", 13.6, 11, "2400-7286-09", "Surface Sites!r13c6", "11"),
  .mig029_row("3-swap", "11fc73b6-858c-42e4-a1dc-8a5bde01ee1b", "316ea653-80b9-42c5-890f-c1098bb247af", "d99b91ab-6eca-483e-be29-16233b3e1533", "B.S03", "2023-09-13", "ES2331527", "pH", 5.9, 4.1, "2400-7286-09", "Surface Sites!r14c6", "4.1"),
  .mig029_row("3-swap", "a0bf9f32-f168-4ea9-b758-60b23232e771", "316ea653-80b9-42c5-890f-c1098bb247af", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2023-09-13", "ES2331527", "EC", 210, 174, "2400-7286-09", "Surface Sites!r15c6", "174"),
  .mig029_row("4-ec-transcription", "080f18e9-b1a2-4a32-9aa0-afea94a07930", "5dbc9c19-8fd7-446d-9989-1fe941f2d7f2", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW09", "2022-09-07", "ES2232312", "EC", 333.8, 339, "2400-7222-09-01", "Groundwater Sites!r17c9", "339"),
  .mig029_row("4-ec-precision", "6ad0d764-4927-471c-a866-771c2a4cbad1", "458e9284-52a5-497d-9d50-a26afc89a79f", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2022-09-07", "ES2232312", "EC", 94.74, 95, "2400-7222-09-01", "Surface Sites!r17c5", "95"),
  .mig029_row("4-ec-precision", "ea3862cd-7de8-4e9f-96c0-8872b1a85cf9", "92934a27-7905-4c2d-b4f3-c8f97d4eb567", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2022-09-07", "ES2232317", "EC", 94.74, 94.7, "2400-7222-09", "Groundwater Sites!r18c4", "95"),
  .mig029_row("4-ec-precision", "34a64f43-70aa-4845-9162-cacc4922351a", "a67e438b-0e5f-4e1f-ad18-4722e77f09bb", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S04", "2022-09-07", "ES2232312", "EC", 104.1, 104, "2400-7222-09-01", "Surface Sites!r17c8", "104"),
  .mig029_row("4-ec-precision", "6d6e7b0a-a3a6-474e-b46f-c59185158341", "be1b9b70-c7a3-4c09-91d0-707449fb1573", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2022-09-07", "ES2232312", "EC", 123.5, 123, "2400-7222-09-01", "Surface Sites!r17c9", "123"),
  .mig029_row("4-ec-precision", "c0846257-fd76-4580-9660-73471479e53e", "2ad2d3c6-3770-4b32-8994-92d7e8175d37", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S06", "2022-09-07", "ES2232312", "EC", 651.4, 651, "2400-7222-09-01", "Surface Sites!r17c6", "651"),
  .mig029_row("4-ec-precision", "290777d0-d430-4444-933a-bdc22f26a530", "430c723e-5ea5-4c17-9c44-9fff6415f7f1", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW08", "2022-11-02", "ES2239614", "EC", 599.9, 600, "2400-7222-11", "Groundwater Sites!r17c5", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "28df10c3-59ba-4aae-8c3e-a459430b6fba", "4cb175b2-910c-4e0f-a1c6-0cf21d9f2cbb", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW09", "2022-11-02", "ES2239614", "EC", 426.5, 427, "2400-7222-11", "Groundwater Sites!r17c6", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "c0511910-c737-47a3-904f-6c19ffce2f9f", "d423e5c9-74d6-4680-ad57-68aed7b0650f", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW11", "2022-11-02", "ES2239614", "EC", 82.2, 82, "2400-7222-11", "Groundwater Sites!r17c8", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "0b7fac24-beb9-413c-948f-942c7b2c5769", "ec8ea49b-52e8-4563-a09d-d4b2c46e08e3", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2022-11-02", "ES2239613", "EC", 149.7, 150, "2400-7222-11-01", "Groundwater Sites!r18c10", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "e53ab907-631a-445c-b08f-539b0430f492", "30ef7204-d8ac-444e-b6c4-081c764de6a9", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2022-11-02", "ES2239613", "EC", 91.27, 91, "2400-7222-11-01", "Groundwater Sites!r18c4", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "e78d68f4-5084-48cd-860b-f52ac576b5c5", "192e46a0-64d6-4467-a40f-c552e9feea77", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2022-11-02", "ES2239613", "EC", 100.7, 101, "2400-7222-11-01", "Groundwater Sites!r18c9", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "0f54a33a-3524-427c-94f3-65d9daaf2888", "9e62883a-dceb-4860-b95d-7bfce0cd1998", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S06", "2022-11-02", "ES2239613", "EC", 398.6, 399, "2400-7222-11-01", "Groundwater Sites!r18c7", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "196768ee-1c4e-4a69-bc68-669d9af0c143", "0b7d9bee-8c2e-4d6d-a846-744ea536d5d1", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2022-11-09", "ES2240713", "EC", 141.9, 142, "2400-7222-11-02", "Groundwater Sites!r18c10", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "62f63d95-0e92-45e2-8d4f-9a3a32522320", "ea89d1de-120c-4c82-aa46-1b28dc404b41", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2022-11-09", "ES2240713", "EC", 88.19, 88, "2400-7222-11-02", "Groundwater Sites!r18c4", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "8df38d3c-8c35-4816-8b96-b606cd592da4", "39dbc1c8-35a9-42d5-a36a-471460030947", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2022-11-09", "ES2240713", "EC", 102.6, 103, "2400-7222-11-02", "Groundwater Sites!r18c9", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "9cfef535-cd88-4d4a-a440-d690309a4300", "5008eb6e-e9a3-44b4-afb7-9a75ea348006", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S06", "2022-11-09", "ES2240713", "EC", 769.6, 770, "2400-7222-11-02", "Groundwater Sites!r18c7", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "ed15569d-ce06-41d7-bea6-c0089252c9ec", "2cee7369-a568-4442-8051-0d2be079fd50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2023-01-04", "ES2300237", "EC", 117.3, 117, "2400-7286-01-01", "Groundwater Sites!r15c4", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "72faad31-85f4-4c82-836a-aa68005e2636", "bbac044d-8c99-4b7e-9d1a-95e67d75b0bc", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2023-05-08", "ES2315342", "EC", 303.4, 303, "2400-7286-05-03", "Groundwater Sites!r15c5", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "63e178b7-a7f1-4185-a9f1-5e51db874261", "c0eaee7a-7e5e-442c-95ba-ab64487f2aef", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2023-05-08", "ES2315342", "EC", 157.3, 157, "2400-7286-05-03", "Groundwater Sites!r15c3", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "b4579668-4dac-431e-881f-34b53eeecb37", "963eb760-b929-431e-9f82-066d732292b3", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.E01", "2023-05-10", "ES2315749", "EC", 496.7, 497, "2400-7286-05-06", "Groundwater Sites!r15c7", "497"),
  .mig029_row("4-ec-precision", "96d58834-3fe5-48ea-bfcf-07f68a504818", "8d9ef8a9-ff90-416b-a038-965ad42e8854", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2023-05-10", "ES2315749", "EC", 239.4, 239, "2400-7286-05-06", "Groundwater Sites!r15c9", "239"),
  .mig029_row("4-ec-precision", "9fd1bb33-451d-42fe-b548-5e2db1a7b630", "236a8783-dcb9-4b89-a904-13538e78ed8a", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S01", "2023-05-10", "ES2315766", "EC", 239.4, 239, "2400-7286-05-04", "Groundwater Sites!r15c5", "239"),
  .mig029_row("4-ec-precision", "92f35fad-2da2-4984-9a05-05282bfe62ea", "bbbf4b75-6f8e-401b-bfd6-73ebc9a5cc78", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S03", "2023-05-10", "ES2315749", "EC", 127.3, 127, "2400-7286-05-06", "Groundwater Sites!r15c3", "127"),
  .mig029_row("4-ec-precision", "47de0fae-6048-4892-a098-fd8f15204a59", "5e8a00a6-9590-4e34-811f-a6909c8156e8", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2023-05-10", "ES2315749", "EC", 142.5, 142, "2400-7286-05-06", "Groundwater Sites!r15c8", "142"),
  .mig029_row("4-ec-precision", "4f6a14a8-e725-4c1b-abfb-e1eff90dc06d", "217b1b01-f55b-44a8-88b7-46a1245f75f0", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2023-05-10", "ES2315766", "EC", 142.8, 143, "2400-7286-05-04", "Groundwater Sites!r15c3", "143"),
  .mig029_row("4-ec-precision", "6221cde6-b87f-4819-8761-aee265acdb20", "a4e284aa-d7f6-4c13-ad56-b36a56511f1e", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S06", "2023-05-10", "ES2315749", "EC", 466.5, 466, "2400-7286-05-06", "Groundwater Sites!r15c6", "466"),
  .mig029_row("4-ec-precision", "33c27ee6-19c6-48c0-8736-556c9b97703f", "8161e5d8-61db-45a1-91a1-ef88c0f08feb", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW09", "2023-05-31", "ES2318335", "EC", 617.2, 617, "2400-7286-05-14", "Groundwater Sites!r14c6", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "c55e0d31-df3b-438c-81bf-96a628961658", "7e40a6cd-ed3e-45bd-ac66-de91fe729a3b", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.MW11", "2023-05-31", "ES2318335", "EC", 72.34, 72, "2400-7286-05-14", "Groundwater Sites!r14c8", "pdf not read (dehydrated)"),
  .mig029_row("4-ec-precision", "d21688d0-8844-4325-9c66-ff0f26c70a9e", "b8961a1f-32ac-42dc-bdd2-e8177fabc65b", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "B.S05", "2023-05-31", "ES2318336", "EC", 141.3, 141, "2400-7286-05-13", "Groundwater Sites!r15c3", "pdf not read (dehydrated)")
)
.mig029_n_plan <- 37L

.mig029_item_text <- c(
  "1-temperature" = "transcription error: both reports (2400-7222-09-01 and 2400-7222-09, xls and pdf) print 14.7",
  "3-swap" = "the legacy S01/S03 whole-sample swap (a lab correction, kept) carried the site field readings to the other point; both reports (2400-7286-09, -09-01) put this value on this point; swapped with its twin on the other ES2331527 sample",
  "4-ec-precision" = "stored with more digits than its own ACIRL report prints; the workbook wins",
  "4-ec-transcription" = "stored value is not a rounding of its own ACIRL report's value (xls and pdf agree); the workbook wins")

.mig029_lms <- data.frame(
  uuid = c("eaf02028-6d7a-47e4-a3ab-d5a26120585c", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "d99b91ab-6eca-483e-be29-16233b3e1533"),
  name = c("Electrical Conductivity", "Temperature", "pH"),
  analyte = c("EC", "Temperature", "pH"),
  stringsAsFactors = FALSE)

# The six item-3 rows as swap pairs (B.S01 row, B.S03 row).
.mig029_swap_pairs <- data.frame(
  s01 = c("25b12d61-d325-42b4-b560-144ff91c18c8", "23c9262e-62e5-4757-b77e-0a77da4c329c", "8e224dfb-bb79-404e-af85-a3d6150c9bb3"),
  s03 = c("97277d9e-185c-4641-88f1-3b9fa204173d", "11fc73b6-858c-42e4-a1dc-8a5bde01ee1b", "a0bf9f32-f168-4ea9-b758-60b23232e771"),
  stringsAsFactors = FALSE)

.mig029_default <- function(x, default) if (is.null(x)) default else x
.mig029_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig029_fail <- function(msg) cli::cli_abort(paste0(.mig029_name, ": ", msg), class = "sampletidy_error")
.mig029_inlist <- function(ids) paste0("(", paste(sprintf("'%s'", ids), collapse = ", "), ")")
.mig029_same <- function(a, b) (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))
.mig029_num_eq <- function(a, b) !is.na(a) && !is.na(b) && abs(a - b) < 1e-9
.mig029_syd_day <- function(x) format(x, tz = "Australia/Sydney", "%Y-%m-%d")

.mig029_touched <- function() unique(c(.mig029_plan$uuid, .mig029_moved$uuid))
.mig029_plan_static <- function() setdiff(.mig029_plan$uuid, .mig029_moved$uuid)   # rows step A does not touch

.mig029_analyses <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig029_inlist(ids)))
}
.mig029_sample_row <- function(con) {
  DBI::dbGetQuery(con, 'SELECT s.*, fa.uuid_feature AS uuid_feature, f.name AS feat FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    WHERE s.uuid = ?', params = list(.mig029_sample))
}
.mig029_samples <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf('SELECT s.uuid, s.date, f.name AS feat, p.name AS proj FROM "sample" s
    JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN feature f ON f.uuid = fa.uuid_feature
    LEFT JOIN project p ON p.uuid = s.uuid_project WHERE s.uuid IN %s ORDER BY s.uuid', .mig029_inlist(ids)))
}

.mig029_counts <- function(con) {
  tabs <- c("analysis", "sample", "lab_method", "feature_alias", "change_log", "schema_version")
  stats::setNames(lapply(tabs, function(t) .mig029_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 029 must not touch. Valid in the pre-029, post-A and post-029
# states alike (step A only removes rows excluded here).
.mig029_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "sample", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig029_inlist(.mig029_touched())))
  out$analysis_plan_other_cols <- q(sprintf("SELECT uuid, uuid_sample, uuid_lab, value_chr, quantified, rl_low, rl_high, purpose, comments
    FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig029_inlist(.mig029_plan_static())))
  out$sample_rest <- q(sprintf("SELECT * FROM \"sample\" WHERE uuid <> '%s' ORDER BY uuid", .mig029_sample))
  out$sample_target_rest <- q(sprintf("SELECT uuid, uuid_project, date, date_start, datetime, datetime_start, organisation, person, purpose
    FROM \"sample\" WHERE uuid = '%s'", .mig029_sample))
  out$change_log_rest <- q(sprintf("SELECT * FROM change_log WHERE actor <> '%s' ORDER BY ALL", .mig029_actor))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out$indexes <- q("SELECT index_name, sql FROM duckdb_indexes() ORDER BY index_name")
  out
}

.mig029_lab_problem <- function(con) {
  lm <- DBI::dbGetQuery(con, sprintf("SELECT lm.uuid, lm.name, lm.organisation, lm.method, an.name AS analyte, an.type
    FROM lab_method lm JOIN analyte an ON an.uuid = lm.uuid_analyte WHERE lm.uuid IN %s", .mig029_inlist(.mig029_lms$uuid)))
  for (i in seq_len(nrow(.mig029_lms))) {
    w <- .mig029_lms[i, ]; r <- lm[lm$uuid == w$uuid, ]
    if (nrow(r) != 1L || !.mig029_same(r$name, w$name) || !.mig029_same(r$organisation, "ACIRL") || !.mig029_same(r$method, "field") ||
        !.mig029_same(r$analyte, w$analyte) || .mig029_same(r$type, "gas")) {
      return(sprintf("lab_method %s is not ACIRL field '%s' -> %s", substr(w$uuid, 1, 8), w$name, w$analyte))
    }
  }
  for (i in seq_len(nrow(.mig029_plan))) {
    r <- .mig029_plan[i, ]
    if (.mig029_lms$analyte[.mig029_lms$uuid == r$uuid_lab] != r$analyte) return(sprintf("plan row %s: lab_method is not %s", substr(r$uuid, 1, 8), r$analyte))
  }
  NULL
}

.mig029_plan_problem <- function() {
  P <- .mig029_plan
  if (nrow(P) != .mig029_n_plan || anyDuplicated(P$uuid)) return("the plan is malformed")
  if (any(abs(P$old - P$new) < 1e-9)) return("a plan row does not change its value")
  if (!all(P$item %in% names(.mig029_item_text))) return("a plan row has an unknown item")
  e <- P[P$item == "4-ec-precision", ]
  if (any(abs(e$old - e$new) > 0.5 + 1e-9)) return("a precision row moves its value by more than 0.5")
  sw <- P[P$item == "3-swap", ]
  for (i in seq_len(nrow(.mig029_swap_pairs))) {
    a <- sw[sw$uuid == .mig029_swap_pairs$s01[i], ]; b <- sw[sw$uuid == .mig029_swap_pairs$s03[i], ]
    if (nrow(a) != 1L || nrow(b) != 1L || a$analyte != b$analyte || a$old != b$new || a$new != b$old) return("the item-3 swap pairs are malformed")
  }
  if (sum(.mig029_plan$uuid %in% .mig029_moved$uuid) != 1L) return("exactly one plan row (EC) should be on the re-pointed sample")
  NULL
}

# The planned samples sit at the feature / Sydney day / order the plan says
# (2ad2d3c6 is checked separately: its feature changes).
.mig029_sample_problem <- function(con) {
  ids <- setdiff(unique(.mig029_plan$uuid_sample), .mig029_sample)
  S <- .mig029_samples(con, ids)
  if (nrow(S) != length(ids)) return("a planned sample is missing")
  for (u in ids) {
    s <- S[S$uuid == u, ]; r <- .mig029_plan[.mig029_plan$uuid_sample == u, ][1, ]
    if (s$feat != r$feat || .mig029_syd_day(s$date) != r$day || !.mig029_same(s$proj, r$proj)) {
      return(sprintf("sample %s is not at %s %s %s", substr(u, 1, 8), r$feat, r$day, r$proj))
    }
  }
  NULL
}

# The re-point target: B.S22's self alias, undated; no other B.S22 sample that
# Sydney day; no ux_sample_identity clash.
.mig029_target_problem <- function(con) {
  fa <- DBI::dbGetQuery(con, "SELECT uuid_feature, name, kind, date_start, date_end FROM feature_alias WHERE uuid = ?", params = list(.mig029_alias_to))
  if (nrow(fa) != 1L || fa$uuid_feature != .mig029_feature_to || fa$name != "B.S22" || fa$kind != "self" ||
      !is.na(fa$date_start) || !is.na(fa$date_end)) return("alias e24bdbc4 is not B.S22's undated self alias")
  day_sql <- .ct_sydney_day_sql("s.date")
  others <- DBI::dbGetQuery(con, sprintf("SELECT s.uuid FROM \"sample\" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    WHERE fa.uuid_feature = ? AND %s = DATE '2022-09-07' AND s.uuid <> ?", day_sql), params = list(.mig029_feature_to, .mig029_sample))
  if (nrow(others) > 0L) return(sprintf("another B.S22 sample exists on 2022-09-07 (%s)", paste(substr(others$uuid, 1, 8), collapse = ", ")))
  clash <- .mig029_scalar(con, "SELECT COUNT(*) FROM \"sample\" s, (SELECT datetime, uuid_project FROM \"sample\" WHERE uuid = ?) t
    WHERE s.uuid <> ? AND s.uuid_feature_alias = ? AND s.datetime = t.datetime AND s.uuid_project = t.uuid_project",
    .mig029_sample, .mig029_sample, .mig029_alias_to)
  if (clash > 0L) return("re-pointing would clash on ux_sample_identity")
  if (.mig029_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = 'ux_sample_identity'") != 1L) return("ux_sample_identity is missing")
  NULL
}

.mig029_target_sample_problem <- function(con, alias, comments) {
  s <- .mig029_sample_row(con)
  if (nrow(s) != 1L) return("sample 2ad2d3c6 is missing")
  if (s$uuid_feature_alias != alias) return(sprintf("sample 2ad2d3c6 is on alias %s, not %s", substr(s$uuid_feature_alias, 1, 8), substr(alias, 1, 8)))
  if (!.mig029_same(s$comments, comments)) return("sample 2ad2d3c6 comments are not as expected")
  if (!.mig029_same(s$uuid_project, .mig029_project) || .mig029_syd_day(s$date) != "2022-09-07" ||
      format(s$datetime, tz = "UTC", "%Y-%m-%d %H:%M:%S") != "2022-09-07 01:51:00") return("sample 2ad2d3c6 is not ES2232312 2022-09-07 01:51 UTC")
  NULL
}

# The moved analyses equal the hard-coded rows (value of the EC row: `ec`).
.mig029_moved_problem <- function(con, ec) {
  A <- .mig029_analyses(con, .mig029_moved$uuid)
  if (nrow(A) != nrow(.mig029_moved)) return(sprintf("%d of the %d analyses of sample 2ad2d3c6 exist", nrow(A), nrow(.mig029_moved)))
  if (.mig029_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_sample = ?", .mig029_sample) != nrow(.mig029_moved)) {
    return("sample 2ad2d3c6 holds analyses outside the hard-coded 7")
  }
  W <- .mig029_moved; W$value[W$uuid == "c0846257-fd76-4580-9660-73471479e53e"] <- ec
  for (i in seq_len(nrow(W))) {
    w <- W[i, ]; a <- A[A$uuid == w$uuid, ]
    if (a$uuid_sample != w$uuid_sample || a$uuid_lab != w$uuid_lab) return(sprintf("analysis %s is not on its sample / lab_method", substr(w$uuid, 1, 8)))
    if (!.mig029_num_eq(a$value, w$value)) return(sprintf("analysis %s value %s, expected %s", substr(w$uuid, 1, 8), a$value, w$value))
    if (!.mig029_same(a$value_chr, w$value_chr) || !.mig029_same(a$quantified, w$quantified) || !.mig029_num_eq(a$rl_low, w$rl_low) ||
        !.mig029_same(a$rl_high, w$rl_high) || !.mig029_same(a$purpose, w$purpose) || !.mig029_same(a$comments, w$comments)) {
      return(sprintf("analysis %s differs from its hard-coded row", substr(w$uuid, 1, 8)))
    }
  }
  NULL
}

# Plan rows (other than the one on 2ad2d3c6) hold `which` ("old" / "new").
.mig029_values_problem <- function(con, which) {
  ids <- .mig029_plan_static()
  A <- .mig029_analyses(con, ids)
  if (nrow(A) != length(ids)) return(sprintf("%d of the %d planned analyses exist", nrow(A), length(ids)))
  for (u in ids) {
    r <- .mig029_plan[.mig029_plan$uuid == u, ]; a <- A[A$uuid == u, ]
    tag <- sprintf("%s %s %s %s %s", r$feat, r$day, r$proj, r$analyte, substr(u, 1, 8))
    if (a$uuid_sample != r$uuid_sample || a$uuid_lab != r$uuid_lab) return(paste(tag, "is not on its sample / lab_method"))
    if (!.mig029_num_eq(a$value, r[[which]])) return(sprintf("%s holds %s, not the %s value %s", tag, a$value, which, r[[which]]))
    if (!is.na(a$value_chr) || !isTRUE(a$quantified)) return(paste(tag, "is not a quantified numeric reading"))
  }
  NULL
}

.mig029_swap_cols_problem <- function(con) {
  A <- .mig029_analyses(con, c(.mig029_swap_pairs$s01, .mig029_swap_pairs$s03))
  for (i in seq_len(nrow(.mig029_swap_pairs))) {
    a <- A[A$uuid == .mig029_swap_pairs$s01[i], ]; b <- A[A$uuid == .mig029_swap_pairs$s03[i], ]
    if (a$uuid_lab != b$uuid_lab) return("an item-3 pair is not on the same lab_method")
    for (f in c("value_chr", "quantified", "rl_low", "rl_high", "purpose", "comments")) {
      if (!.mig029_same(a[[f]], b[[f]])) return(sprintf("item-3 pair %s / %s differs in %s", substr(a$uuid, 1, 8), substr(b$uuid, 1, 8), f))
    }
  }
  NULL
}

.mig029_n_log <- function(con, action = NULL, tbl = NULL) {
  w <- sprintf("actor = '%s'", .mig029_actor)
  if (!is.null(action)) w <- paste0(w, sprintf(" AND action = '%s'", action))
  if (!is.null(tbl)) w <- paste0(w, sprintf(" AND tbl = '%s'", tbl))
  .mig029_scalar(con, sprintf("SELECT COUNT(*) FROM change_log WHERE %s", w))
}

.mig029_initial_problem <- function(con) {
  p <- .mig029_plan_problem(); if (!is.null(p)) return(p)
  p <- .mig029_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_sample_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_target_sample_problem(con, .mig029_alias_from, .mig029_comment_from); if (!is.null(p)) return(p)
  p <- .mig029_target_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_moved_problem(con, ec = 651.4); if (!is.null(p)) return(p)
  p <- .mig029_values_problem(con, "old"); if (!is.null(p)) return(p)
  p <- .mig029_swap_cols_problem(con); if (!is.null(p)) return(p)
  if (.mig029_n_log(con) != 0L) return("029 change_log rows already exist")
  NULL
}

# Step A committed, B not: the 7 analyses (and nothing else) gone.
.mig029_post_a_problem <- function(con) {
  p <- .mig029_plan_problem(); if (!is.null(p)) return(p)
  p <- .mig029_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_sample_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_target_sample_problem(con, .mig029_alias_from, .mig029_comment_from); if (!is.null(p)) return(p)
  p <- .mig029_target_problem(con); if (!is.null(p)) return(p)
  if (nrow(.mig029_analyses(con, .mig029_moved$uuid)) != 0L) return("not post-A: the moved analyses exist")
  if (.mig029_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_sample = ?", .mig029_sample) != 0L) return("not post-A: sample 2ad2d3c6 holds analyses")
  p <- .mig029_values_problem(con, "old"); if (!is.null(p)) return(p)
  gone <- DBI::dbGetQuery(con, sprintf("SELECT uuid_row FROM change_log WHERE actor = '%s' AND action = 'delete' AND tbl = 'analysis'", .mig029_actor))$uuid_row
  if (!setequal(gone, .mig029_moved$uuid) || length(gone) != nrow(.mig029_moved)) return("not post-A: 029's delete change_log rows are not exactly the 7")
  if (.mig029_n_log(con) != nrow(.mig029_moved)) return("not post-A: 029 has written more than step A")
  NULL
}

.mig029_done_problem <- function(con) {
  p <- .mig029_plan_problem(); if (!is.null(p)) return(p)
  p <- .mig029_lab_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_sample_problem(con); if (!is.null(p)) return(p)
  p <- .mig029_target_sample_problem(con, .mig029_alias_to, .mig029_comment_to); if (!is.null(p)) return(p)
  s <- .mig029_sample_row(con)
  if (s$feat != "B.S22") return("sample 2ad2d3c6 is not on feature B.S22")
  if (.mig029_scalar(con, "SELECT COUNT(*) FROM duckdb_indexes() WHERE index_name = 'ux_sample_identity'") != 1L) return("ux_sample_identity is missing")
  p <- .mig029_moved_problem(con, ec = 651); if (!is.null(p)) return(p)
  p <- .mig029_values_problem(con, "new"); if (!is.null(p)) return(p)
  p <- .mig029_swap_cols_problem(con); if (!is.null(p)) return(p)
  n7 <- nrow(.mig029_moved)
  if (.mig029_n_log(con, "delete", "analysis") != n7) return("029 delete change_log rows are not 7")
  if (.mig029_n_log(con, "insert", "analysis") != n7) return("029 insert change_log rows are not 7")
  if (.mig029_n_log(con, "update", "analysis") != .mig029_n_plan) return(sprintf("029 analysis update change_log rows are not %d", .mig029_n_plan))
  if (.mig029_n_log(con, "update", "sample") != 2L) return("029 sample update change_log rows are not 2")
  if (.mig029_n_log(con) != 2L * n7 + .mig029_n_plan + 2L) return("029 wrote unexpected change_log rows")
  NULL
}

.mig029_verify <- function(con) {
  p <- .mig029_done_problem(con)
  if (!is.null(p)) cli::cli_abort(paste0("029 verify failed: ", p), class = "sampletidy_error")
  invisible(TRUE)
}

mig029_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig029_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-%s_%sZ.duckdb", .mig029_name, ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig029_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig029_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig029_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8", colClasses = "character")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid) || !identical(back$comments, as.character(out$comments))) {
    cli::cli_abort("029: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig029_check_preconditions <- function(con) {
  if (.mig029_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig029_requires) == 0L) {
    .mig029_fail(sprintf("marker %d (028) is required first.", .mig029_requires))
  }
  p <- .mig029_initial_problem(con)
  if (is.null(p)) return("pre")
  q <- .mig029_post_a_problem(con)
  if (is.null(q)) return("post_a")
  .mig029_fail(sprintf("the database is neither pre-029 (%s) nor post-step-A (%s). Nothing written; restore from the backup if a step failed.", p, q))
}

.mig029_reason <- function(r) {
  sprintf("029: %s %s %s ACIRL field %s %s -> %s per its own ACIRL report %s %s (pdf: %s) - %s",
          r$feat, r$day, r$proj, r$analyte, format(r$old, digits = 15), format(r$new, digits = 15),
          r$report, r$cell, r$pdf, .mig029_item_text[[r$item]])
}

# Step A: one set-based delete of the re-pointed sample's 7 analyses.
.mig029_step_a <- function(con) {
  db_transaction(con, function(con) {
    ids <- .mig029_moved$uuid
    n <- DBI::dbExecute(con, sprintf("DELETE FROM analysis WHERE uuid IN %s", .mig029_inlist(ids)))
    if (n != length(ids)) cli::cli_abort("029: set-based delete removed {n} rows, not {length(ids)}.", class = "sampletidy_error")
    at <- Sys.time()
    for (u in ids) {
      .st_write_change_log(con, at = at, actor = .mig029_actor, action = "delete", tbl = "analysis",
                           uuid_row = u, field = NA_character_, old = u, new = NA_character_,
                           reason = sprintf("029 step A: analysis of sample %s removed so the sample can be re-pointed B.S06 -> B.S22 (duckdb FK limitation); re-inserted unchanged with the same uuid in step B", .mig029_sample),
                           source_hash = NA_character_)
    }
    NULL
  })
}

# Step B: re-point, re-insert, value updates, marker, verify, checksum.
.mig029_step_b <- function(con, recorded_at, sums_before) {
  db_transaction(con, function(con) {
    db_update(con, "sample", uuid = .mig029_sample,
              changes = list(uuid_feature_alias = .mig029_alias_to, comments = .mig029_comment_to),
              actor = .mig029_actor,
              reason = "029: sample is ALS ES2232312003, labelled B.S22 (ESdat; ACIRL 2400-7222-09-01 lists S22, not S06); re-pointed from B.S06 alias 20969dd8 to B.S22 alias e24bdbc4 with all its analyses")
    db_append(con, "analysis", .mig029_moved, actor = .mig029_actor,
              reason = sprintf("029 step B: re-inserted unchanged (same uuid, every column as at marker 1028) on sample %s, now on alias B.S22", .mig029_sample))
    for (i in seq_len(nrow(.mig029_plan))) {
      r <- .mig029_plan[i, ]
      db_update(con, "analysis", uuid = r$uuid, changes = list(value = r$new), actor = .mig029_actor, reason = .mig029_reason(r))
    }
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig029_marker_version, recorded_at))
    .mig029_verify(con)
    if (!identical(sums_before, .mig029_checksum(con))) {
      cli::cli_abort("029 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig029_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig029_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig029_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("029 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    state <- .mig029_check_preconditions(pre_con)
    list(state = state,
         analysis = .mig029_analyses(pre_con, .mig029_touched()),
         sample = DBI::dbGetQuery(pre_con, 'SELECT * FROM "sample" WHERE uuid = ?', params = list(.mig029_sample)))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  tab <- table(.mig029_plan$item)
  logf("Plan (%s): re-point sample 2ad2d3c6 B.S06 -> B.S22 with its 7 analyses; %d value updates (%s).",
       pre$state, nrow(.mig029_plan), paste(names(tab), tab, sep = " x", collapse = ", "))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed (state %s). No backup taken, nothing written.", pre$state)
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  if (pre$state == "pre") {
    .mig029_write_csv(pre$analysis, file.path(csv_dir, sprintf("%s-BACKUP-analysis.csv", .mig029_name)))
    .mig029_write_csv(pre$sample, file.path(csv_dir, sprintf("%s-BACKUP-sample.csv", .mig029_name)))
    logf("Row backups written to %s", csv_dir)
  } else {
    logf("Resuming after step A; the row backups from the first run are kept.")
  }
  backup_path <- mig029_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig029_default(.now, Sys.time())

  sums_before <- with_db_write(function(con) {
    state <- .mig029_check_preconditions(con)   # re-read under the write lock
    if (state != pre$state) .mig029_fail("the database changed state between the read and the write lock.")
    sums <- .mig029_checksum(con)
    if (state == "pre") .mig029_step_a(con)
    sums
  }, db = db)
  if (pre$state == "pre") logf("Step A committed: %d analyses of sample 2ad2d3c6 removed (re-inserted in step B).", nrow(.mig029_moved))

  # Fresh connection: the sample UPDATE is refused on the connection that ran
  # the delete inside a transaction (024's FK limitation).
  with_db_write(function(con) {
    if (.mig029_check_preconditions(con) != "post_a") .mig029_fail("step B expects the post-step-A state.")
    .mig029_step_b(con, recorded_at, sums_before)
  }, db = db)

  logf("Committed: sample 2ad2d3c6 re-pointed to B.S22 (7 analyses re-inserted); %d values corrected; marker %d.",
       nrow(.mig029_plan), .mig029_marker_version)
  logf("%s migrated successfully.", .mig029_name)
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
