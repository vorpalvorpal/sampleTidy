# Operator-run migration: merge the 10 duplicate Blaxland water samples that the
# 2026-08-09 ingest of 2400-7399-08 created for the 2024-08-07 visit, and merge
# the two ACIRL "Standing water level" lab_methods that differ only in case.
#
# Authorised by Robin, 2026-10-17 (024 "Aug-24 water duplicates"), rulings 1-5:
#   1. re-point the 13 genuinely new analyses onto their legacy twins;
#   2. delete the 28 pure duplicates;
#   3. Appearance: the PIPELINE wins (A76 split vocabulary) - for the 5
#      conflicts re-point the pipeline Appearance onto the twin and delete the
#      legacy Appearance it replaces (backed up);
#   4. delete the 10 emptied pipeline samples, in a step committed separately
#      from the analysis deletes; keep the B.EO1 alias, the projects and the
#      asset rows;
#   5. merge lab_method 45a8fbd1 "Standing water level" (ACIRL, field) into
#      68484c79 "Standing Water Level" (ACIRL, field): re-point every analysis,
#      then delete 45a8fbd1.
#
# ---- WHAT THE DUPLICATES ARE (scratchpad/2026-10-17-dupwater/, cmp.R) ---------
#
# The ingest put 10 water samples at B.MW02, MW08, MW09, S01, S03, S05, S06,
# S10, S22 and E01 (the last on alias B.EO1) with `date` 2024-08-07 (naive
# midnight), NULL `datetime`, project ES2425916 (28a4c967). Each has exactly one
# legacy twin at the same feature on the same Sydney day in the same project
# (ES2425916001-007 and three uuid-keyed ones). NULL `datetime` is why sample
# identity did not find the twin at ingest. Their 46 analyses split:
#   delete_dup       28  same lab_method (SWL: 45a8fbd1 vs 68484c79, ruling 5)
#                        and identical value / value_chr / quantified / rl_low /
#                        rl_high / purpose / comments (re-proved below);
#   repoint_new      13  EC x9 (no legacy field EC on any twin), Stage x4
#                        (S01, S03, S05, S10 - no legacy Stage on those twins);
#   repoint_replace   5  Appearance B.S01/S03 "Low flow clear" -> "Clear",
#                        B.S05 "Mod Level Clear" -> "Clear", B.S22 "cloudy" ->
#                        "Cloudy", B.E01 "Slightly Cloudy" -> "Slightly cloudy".
#                        (The flow half of S01/S03/S05 arrives as their new
#                        Stage row.)
# No review_queue / review_queue_candidate / asset row references any of these
# samples or analyses (measured); their only other traces are change_log rows.
#
# ---- THE LAB_METHOD MERGE ------------------------------------------------------
#
# Analyte labels reach lab_methods ONLY through `lab_method.name`: reconcile's
# `.rc_resolve_one_analyte()` tries an exact (case-sensitive) name + org +
# method match, then the folded key (`.rc_method_key()`: alphanumerics,
# case-folded). There is no lab_method alias table, and A75/A79 key on the
# resolved `uuid_lab` / analyte, not on a label table. So once 45a8fbd1 is gone,
# the ACIRL label "Standing water level" folds to `standingwaterlevel` and
# resolves to 68484c79 (the only ACIRL lab_method left on that key). 45a8fbd1
# holds 6 analyses: the 3 pipeline duplicates (deleted, ruling 2) and 3
# 2023-10-10 legacy readings (B.MW02/MW08/MW09, ES2335099), re-pointed here;
# none of their samples already carries a 68484c79 analysis. Nothing else
# references a lab_method uuid (FKs: analysis.uuid_lab only).
#
# ---- THE FK STEPS (008's pattern) ---------------------------------------------
#
# duckdb's FK check does not see in-transaction deletes of the referencing
# rows, so a parent (sample / lab_method) cannot be deleted in the transaction
# that empties it. Two transactions, each committed:
#   A. every analysis write: 18 re-points of uuid_sample, 3 of uuid_lab
#      (delete + re-insert), 28 + 5 deletes;
#   B. the 10 sample deletes, the lab_method delete, the marker, verification.
# THE 45a8fbd1 ANALYSES (the 3 pipeline SWL duplicates and the 3 2023-10-10
# rows) are removed by ONE `DELETE FROM analysis WHERE uuid_lab = '45a8fbd1'`
# (count asserted = 6, one change_log delete row each written beside it, as
# 011 does for guideline), and the 3 2023-10-10 rows re-inserted with the same
# uuid and every other column identical but uuid_lab = 68484c79 (db_append, so
# change_log shows a delete + an insert for each, both reasons naming the
# uuid_lab change). Measured on copies of live (duckdb 1.4.1,
# scratchpad/2026-10-17-mig024/exp3.R, exp4.R): after per-row
# `DELETE ... WHERE uuid = ?` (in or out of a transaction) or a committed
# `UPDATE analysis SET uuid_lab`, the FK index on analysis.uuid_lab still
# holds the 45a8fbd1 key and `DELETE FROM lab_method` is refused ("still
# referenced by a foreign key"), even after FORCE CHECKPOINT and a reopen. The
# single set-based DELETE (with or without the re-insert) leaves it clean.
# The per-row uuid_sample re-points and deletes do not block the step-B sample
# deletes (measured), so they stay on db_update()/db_delete().
# RESUMABLE: if B fails after A committed, a re-run recognises the post-A state
# (every A write present, nothing of B done) and runs B only. Any other state
# is refused; restore from the printed backup.
#
# Every write goes through db_update()/db_delete()/db_append() (actor
# "024-merge-aug24-water-duplicates"), except the one set-based delete above,
# which writes the same change_log rows db_delete() would. Everything else is checksummed: every
# base table but change_log / schema_version whole, and analysis / sample /
# lab_method minus the planned rows.
#
# BACKUP OF THE ROWS: `024-merge-aug24-water-duplicates-BACKUP-{analysis,sample,
# lab_method}.csv` beside this file (every analysis written or deleted, the 10
# samples, 45a8fbd1, as they were), plus the verified whole-file backup in
# `snapshot_dir`.
#
# Marker 1024 (1023 is reserved for 023-registry-fingerprint). Independent of
# 023; requires 1022. Idempotent: marker present -> re-verify, no-op.
#
#   devtools::load_all(".")
#   env <- new.env()
#   sys.source("dev/migrations/024-merge-aug24-water-duplicates.R", envir = env)
#   env$mig024_run(db = st_config("live_db"),
#                  snapshot_dir = st_config("snapshot_dir"), dry_run = TRUE)

.mig024_marker_version <- 1024L
.mig024_requires <- 1022L
.mig024_actor <- "024-merge-aug24-water-duplicates"
.mig024_lm_from <- "45a8fbd1-52b3-4938-b3fa-0f34e7b7ae23"  # ACIRL "Standing water level"
.mig024_lm_to <- "68484c79-cb5f-46a4-bb30-ecc64bea163e"    # ACIRL "Standing Water Level"
.mig024_lm_appearance <- "6d11d0c5-9da8-4909-a69a-31ceab12aa50"  # ACIRL "Comments" = Appearance
.mig024_project <- "28a4c967-c3d1-471d-a19e-ad253fb5ca9e"  # ES2425916
# The 3 other analyses on 45a8fbd1 (2023-10-10, ES2335099): uuid_lab re-pointed.
.mig024_swl_other <- data.frame(
  uuid = c("ec7a0c20-e0ce-4fe1-9294-09b4c188fd46", "ba9dbbd3-1e13-4401-977f-faf6c4867fd8",
           "a3ba0dc8-d7f3-4d8b-a66b-7bab5df21a0c"),
  feat = c("B.MW02", "B.MW08", "B.MW09"),
  value = c(4.60, 2.85, 3.01),
  stringsAsFactors = FALSE)

# One row per pipeline analysis. uuid_legacy = the legacy twin analysis it
# duplicates (delete_dup) or replaces (repoint_replace); NA for repoint_new.
.mig024_plan <- data.frame(
  feat = c("B.E01", "B.E01", "B.E01", "B.E01", "B.E01", "B.MW02", "B.MW02", "B.MW02", "B.MW02", "B.MW02", "B.MW08", "B.MW08", "B.MW08", "B.MW08", "B.MW08", "B.MW09", "B.MW09", "B.MW09", "B.MW09", "B.MW09", "B.S01", "B.S01", "B.S01", "B.S01", "B.S01", "B.S03", "B.S03", "B.S03", "B.S03", "B.S03", "B.S05", "B.S05", "B.S05", "B.S05", "B.S05", "B.S06", "B.S06", "B.S06", "B.S06", "B.S06", "B.S10", "B.S22", "B.S22", "B.S22", "B.S22", "B.S22"),
  analyte = c("Appearance", "EC", "pH", "Stage", "Temperature", "Appearance", "EC", "pH", "Standing water level", "Temperature", "Appearance", "EC", "pH", "Standing water level", "Temperature", "Appearance", "EC", "pH", "Standing water level", "Temperature", "Appearance", "EC", "pH", "Stage", "Temperature", "Appearance", "EC", "pH", "Stage", "Temperature", "Appearance", "EC", "pH", "Stage", "Temperature", "Appearance", "EC", "pH", "Stage", "Temperature", "Stage", "Appearance", "EC", "pH", "Stage", "Temperature"),
  action = c("repoint_replace", "repoint_new", "delete_dup", "delete_dup", "delete_dup", "delete_dup", "repoint_new", "delete_dup", "delete_dup", "delete_dup", "delete_dup", "repoint_new", "delete_dup", "delete_dup", "delete_dup", "delete_dup", "repoint_new", "delete_dup", "delete_dup", "delete_dup", "repoint_replace", "repoint_new", "delete_dup", "repoint_new", "delete_dup", "repoint_replace", "repoint_new", "delete_dup", "repoint_new", "delete_dup", "repoint_replace", "repoint_new", "delete_dup", "repoint_new", "delete_dup", "delete_dup", "repoint_new", "delete_dup", "delete_dup", "delete_dup", "repoint_new", "repoint_replace", "repoint_new", "delete_dup", "delete_dup", "delete_dup"),
  uuid = c("31a7acff-98f8-46fc-996c-8e78a75b6aa0", "ea57a94f-7b1a-4331-b97e-2e27b31f9dda", "a07f8ef0-1bcd-4dc4-b9b0-189cce7c2302", "c3c4f828-a5c0-4a62-8a4d-80a68fc0c903", "1740e293-9b9c-46ba-ae32-f9229208e21f", "0e45f45a-fee3-425d-8581-78582ecdaef5", "a39073c1-5624-4885-8900-fa6cc4f50cfd", "8485036c-fe58-4cb3-bd7f-410dbd380ea1", "93c3d27f-43ea-4459-8282-18296432f614", "fd62b595-e786-4088-9d6e-9f2041582d5a", "5ce37c5d-d029-4662-b086-51f90f66fd56", "ce473a49-6218-4373-aab7-68fec6e75bd6", "69c3985e-43ae-44e2-907a-e37bfe6b9d05", "f7ef3a4e-1223-4b53-93c1-7397e60013d8", "fded0a2b-3aaa-421b-86df-68f81d6c4936", "c0f9f409-7bdb-4dcf-a9c8-d36e487e3fb7", "3a929c57-6d88-42d0-b82f-ad26fce9da3d", "7345f98b-0833-40af-b239-2e644f0d36d5", "840f5529-e6c4-4f91-bef0-eec164ece0c0", "4e92467e-75e8-4ff6-a746-2b40ea9989d9", "58ee4f8b-f6b5-4fe7-b63f-7c6c345a7c3f", "db80e532-e0db-45ed-8135-d971a0ff2309", "10a3311a-e98c-495b-b5a8-77eac6c9ccaf", "f694705f-7693-4401-86af-98fc4571eb54", "5e713abb-9666-4d50-ae76-7df991f9b648", "831d84ab-b781-4344-8228-a3fbf5819a8f", "d5919a15-2711-4d2a-a6cd-c7266766825e", "c1aecf33-a857-41a4-9bd7-c70cb0efea23", "a28bcbd8-f536-436b-89b5-a4523ac70e63", "bcf18d1a-d15d-4441-9882-7787202c53c9", "7dde0eaf-f9a4-411e-a870-e4d74cc7039a", "20fe8abe-1818-4048-87ff-ccef1caf7419", "35cb0500-03e7-40ce-9412-62c4ee7c04b8", "8cee2e0e-46be-44fb-b7f9-4b37318e9293", "c8c81ede-ed5e-4838-9732-7cda6a6854bd", "cd7fbcff-0c7a-4c2f-8136-d8191a1271fa", "a4e6a12e-1139-4758-94ce-3923219abce1", "d3454812-e4fe-4a9f-85a7-543001a1f0a8", "03f135f3-c861-47b1-9ea6-9bbdcf1884fc", "035ad401-9ad2-4a02-897d-a35fcaf799ee", "68e98fec-69d5-4ad3-bdd5-58e34000843f", "9e2abdd8-89d5-405f-96a2-27b21ba8c3c6", "94d68bb2-82ee-498c-840e-dd9d3183f94e", "b7f7b89c-8a24-484e-9faa-b82d4cb3caf9", "5b1d13fe-7367-4698-a484-3c826a5a7a7b", "0088a972-2342-4711-a72d-108468705cd4"),
  uuid_pipeline_sample = c("3760c0be-a855-405d-9499-79f2c78d0d03", "3760c0be-a855-405d-9499-79f2c78d0d03", "3760c0be-a855-405d-9499-79f2c78d0d03", "3760c0be-a855-405d-9499-79f2c78d0d03", "3760c0be-a855-405d-9499-79f2c78d0d03", "24a60738-11b0-4964-8de7-bbabf8099bc6", "24a60738-11b0-4964-8de7-bbabf8099bc6", "24a60738-11b0-4964-8de7-bbabf8099bc6", "24a60738-11b0-4964-8de7-bbabf8099bc6", "24a60738-11b0-4964-8de7-bbabf8099bc6", "c08b10e4-f2f0-488c-9153-be256e50c78a", "c08b10e4-f2f0-488c-9153-be256e50c78a", "c08b10e4-f2f0-488c-9153-be256e50c78a", "c08b10e4-f2f0-488c-9153-be256e50c78a", "c08b10e4-f2f0-488c-9153-be256e50c78a", "e231be9f-0f19-49f8-89b8-c50b419187b1", "e231be9f-0f19-49f8-89b8-c50b419187b1", "e231be9f-0f19-49f8-89b8-c50b419187b1", "e231be9f-0f19-49f8-89b8-c50b419187b1", "e231be9f-0f19-49f8-89b8-c50b419187b1", "4595bf46-4979-4900-a8c2-dfa8a553a8e2", "4595bf46-4979-4900-a8c2-dfa8a553a8e2", "4595bf46-4979-4900-a8c2-dfa8a553a8e2", "4595bf46-4979-4900-a8c2-dfa8a553a8e2", "4595bf46-4979-4900-a8c2-dfa8a553a8e2", "1c086e2b-bebd-4506-bf42-5ca5f9fe4686", "1c086e2b-bebd-4506-bf42-5ca5f9fe4686", "1c086e2b-bebd-4506-bf42-5ca5f9fe4686", "1c086e2b-bebd-4506-bf42-5ca5f9fe4686", "1c086e2b-bebd-4506-bf42-5ca5f9fe4686", "8688a989-04f2-43e2-b2cc-1696940c6516", "8688a989-04f2-43e2-b2cc-1696940c6516", "8688a989-04f2-43e2-b2cc-1696940c6516", "8688a989-04f2-43e2-b2cc-1696940c6516", "8688a989-04f2-43e2-b2cc-1696940c6516", "ccfb087d-808f-4b22-b520-0a328306511b", "ccfb087d-808f-4b22-b520-0a328306511b", "ccfb087d-808f-4b22-b520-0a328306511b", "ccfb087d-808f-4b22-b520-0a328306511b", "ccfb087d-808f-4b22-b520-0a328306511b", "6f17ec55-dcc0-4c3b-bff1-6480366e244f", "48af0d99-879a-4c63-875d-ec140fbadf73", "48af0d99-879a-4c63-875d-ec140fbadf73", "48af0d99-879a-4c63-875d-ec140fbadf73", "48af0d99-879a-4c63-875d-ec140fbadf73", "48af0d99-879a-4c63-875d-ec140fbadf73"),
  uuid_twin = c("29aa844f-d89a-480b-baa6-e1793baa7878", "29aa844f-d89a-480b-baa6-e1793baa7878", "29aa844f-d89a-480b-baa6-e1793baa7878", "29aa844f-d89a-480b-baa6-e1793baa7878", "29aa844f-d89a-480b-baa6-e1793baa7878", "ES2425916001", "ES2425916001", "ES2425916001", "ES2425916001", "ES2425916001", "ES2425916002", "ES2425916002", "ES2425916002", "ES2425916002", "ES2425916002", "ES2425916003", "ES2425916003", "ES2425916003", "ES2425916003", "ES2425916003", "ES2425916004", "ES2425916004", "ES2425916004", "ES2425916004", "ES2425916004", "ES2425916005", "ES2425916005", "ES2425916005", "ES2425916005", "ES2425916005", "ES2425916006", "ES2425916006", "ES2425916006", "ES2425916006", "ES2425916006", "ES2425916007", "ES2425916007", "ES2425916007", "ES2425916007", "ES2425916007", "a1888b09-d660-49b2-a68a-6dba12e62073", "9291cb81-6499-4efd-a5ee-711547d001bd", "9291cb81-6499-4efd-a5ee-711547d001bd", "9291cb81-6499-4efd-a5ee-711547d001bd", "9291cb81-6499-4efd-a5ee-711547d001bd", "9291cb81-6499-4efd-a5ee-711547d001bd"),
  uuid_lab = c("6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45a8fbd1-52b3-4938-b3fa-0f34e7b7ae23", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45a8fbd1-52b3-4938-b3fa-0f34e7b7ae23", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45a8fbd1-52b3-4938-b3fa-0f34e7b7ae23", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3", "45c91544-e2f7-4782-b896-8e01c45d3959", "6d11d0c5-9da8-4909-a69a-31ceab12aa50", "eaf02028-6d7a-47e4-a3ab-d5a26120585c", "d99b91ab-6eca-483e-be29-16233b3e1533", "45c91544-e2f7-4782-b896-8e01c45d3959", "5f77a675-a895-46b5-a800-ea7c11fea3d3"),
  uuid_legacy = c("6dcbfec4-9087-4b10-b9d5-066f1c7177d6", NA, "19d0cd4e-2f5f-4899-b007-3b5b3a4cbe41", "d6f77870-c329-4d82-95c6-caba27284bf0", "9a2caa22-dbb6-40af-95cf-86a947209f36", "d51b0e88-e646-474a-a324-91931cbf0e0f", NA, "1c649edc-46e0-4c6a-8865-1a66bb7fbebb", "8b70a7ab-e944-4364-afa6-951bd1ee6f5a", "7701d0f3-0fb2-478d-be4a-4ad2c679bb9f", "4542da9c-78a4-4304-a0c0-39aa8d24e723", NA, "14d0637a-21ba-4d10-a4e4-a5e5d5e3613c", "3ad94d60-f2f9-406a-82b8-0ae95660173b", "cc4d9545-0189-4d52-8015-c1f3b16638f7", "3567054b-c29d-4b57-908d-a4b659158068", NA, "aeb45677-b770-4077-b4ba-3aabe68e7af3", "b776ecd6-638c-41da-8470-48a248323bf9", "3aa04270-f83b-4085-a019-34a89e21e64f", "6fe79760-46b5-4fe7-b7a0-7aef91211318", NA, "ab7e20f3-574c-4632-9cae-acf7a7b26fad", NA, "8a25f185-b217-4e7c-81ac-7a5d81c2115f", "e4a19a1c-e917-489d-b49e-58b17e7da1e8", NA, "a1ae26fe-6773-4383-ae96-297409887d91", NA, "0129512c-53d8-4f13-95cc-584235ba3f34", "f686e12b-27da-4471-bcdc-c345a03929d8", NA, "8b5e5b64-2518-44cf-b880-57c349ec87e5", NA, "722047a9-6eb0-4b17-89f6-dcbe2e4f7763", "471f2184-fdfc-4eca-8b1b-e0140933a93f", NA, "7b3c1e1a-e052-44df-ad96-2124c297b076", "a264892f-b24e-4eed-9e50-14b4c15ea223", "2a834293-7929-4c75-bddc-8aa9dbb82d30", NA, "25b197dd-4310-46d8-a2bd-f216882cd27e", NA, "e700cf95-6fdb-451d-843f-99698733b16f", "ec49952a-046f-404e-92cc-2bedfd651c0a", "b7e4daa2-e0f6-4239-9a6c-0e60375a6240"),
  value = c(NA,  324.00,    7.00, NA,    8.60, NA, 1461.00,    5.80,    4.47,   17.50, NA,  733.00,    5.90,    3.04,   14.80, NA,  265.00,    6.60,    2.90,   15.00, NA,  182.00,    6.80, NA,   11.10, NA,  130.00,    5.50, NA,    8.80, NA,  144.00,    7.10, NA,   10.40, NA,  288.00,    6.80, NA,   11.20, NA, NA,  278.00,    7.00, NA,   11.10),
  value_chr = c("Slightly cloudy", NA, NA, "Pooled", NA, "Cloudy", NA, NA, NA, NA, "Cloudy", NA, NA, NA, NA, "Cloudy", NA, NA, NA, NA, "Clear", NA, NA, "Low flow", NA, "Clear", NA, NA, "Low flow", NA, "Clear", NA, NA, "Mod level", NA, "Cloudy", NA, NA, "Mod level", NA, "Dry", "Cloudy", NA, NA, "Mod level", NA),
  legacy_value_chr = c("Slightly Cloudy", NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, "Low flow clear", NA, NA, NA, NA, "Low flow clear", NA, NA, NA, NA, "Mod Level Clear", NA, NA, NA, NA, NA, NA, NA, NA, NA, NA, "cloudy", NA, NA, NA, NA),
  stringsAsFactors = FALSE)

.mig024_default <- function(x, default) if (is.null(x)) default else x
.mig024_scalar <- function(con, sql, ...) as.integer(DBI::dbGetQuery(con, sql, params = list(...))[[1]][[1]])
.mig024_fail <- function(msg) cli::cli_abort(paste0("024-merge-aug24-water-duplicates: ", msg), class = "sampletidy_error")
.mig024_in <- function(con, sql, ids = NULL) DBI::dbGetQuery(con, sql)
.mig024_inlist <- function(ids) paste0("(", paste(sprintf("'%s'", ids), collapse = ", "), ")")

.mig024_psamples <- function() unique(.mig024_plan$uuid_pipeline_sample)
.mig024_twins <- function() unique(.mig024_plan$uuid_twin)
.mig024_replaced <- function() .mig024_plan$uuid_legacy[.mig024_plan$action == "repoint_replace"]
.mig024_dups <- function() .mig024_plan$uuid[.mig024_plan$action == "delete_dup"]
.mig024_moved <- function() .mig024_plan$uuid[.mig024_plan$action != "delete_dup"]
# Every analysis row 024 writes or deletes.
.mig024_touched <- function() unique(c(.mig024_plan$uuid, .mig024_replaced(), .mig024_swl_other$uuid))

.mig024_analyses <- function(con, ids) {
  DBI::dbGetQuery(con, sprintf("SELECT * FROM analysis WHERE uuid IN %s ORDER BY uuid", .mig024_inlist(ids)))
}

.mig024_counts <- function(con) {
  tabs <- c("analysis", "sample", "lab_method", "project", "feature_alias", "asset", "change_log")
  stats::setNames(lapply(tabs, function(t) .mig024_scalar(con, sprintf('SELECT COUNT(*) FROM "%s"', t))), tabs)
}

# Everything 024 must not touch.
.mig024_checksum <- function(con) {
  q <- function(sql) digest::digest(DBI::dbGetQuery(con, sql), algo = "sha1")
  tabs <- DBI::dbGetQuery(con, "SELECT table_name FROM information_schema.tables
    WHERE table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name")$table_name
  whole <- setdiff(tabs, c("analysis", "sample", "lab_method", "change_log", "schema_version"))
  out <- lapply(whole, function(t) q(sprintf('SELECT * FROM "%s" ORDER BY ALL', t)))
  names(out) <- whole
  out$analysis_rest <- q(sprintf("SELECT * FROM analysis WHERE uuid NOT IN %s ORDER BY uuid", .mig024_inlist(.mig024_touched())))
  out$sample_rest <- q(sprintf('SELECT * FROM "sample" WHERE uuid NOT IN %s ORDER BY uuid', .mig024_inlist(.mig024_psamples())))
  out$lab_method_rest <- q(sprintf("SELECT * FROM lab_method WHERE uuid <> '%s' ORDER BY uuid", .mig024_lm_from))
  out$views <- q("SELECT view_name, sql FROM duckdb_views() WHERE NOT internal ORDER BY view_name")
  out
}

.mig024_same <- function(a, b) {
  (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && identical(a, b))
}
.mig024_same_num <- function(a, b) {
  (is.na(a) && is.na(b)) || (!is.na(a) && !is.na(b) && abs(a - b) < 1e-9)
}

# The pre-024 state, proved row by row. Returns NULL if it holds, else the
# first reason it does not.
.mig024_initial_problem <- function(con) {
  P <- .mig024_plan
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid = ?", .mig024_lm_from) != 1L) return("lab_method 45a8fbd1 is missing")
  lm <- DBI::dbGetQuery(con, "SELECT uuid, name, method, organisation, uuid_analyte FROM lab_method WHERE uuid IN (?, ?) ORDER BY name",
                        params = list(.mig024_lm_from, .mig024_lm_to))
  if (nrow(lm) != 2L || !setequal(lm$name, c("Standing water level", "Standing Water Level")) ||
      !all(lm$method == "field") || !all(lm$organisation == "ACIRL") || length(unique(lm$uuid_analyte)) != 1L) {
    return("the two Standing water level lab_methods are not the expected ACIRL field pair on one analyte")
  }
  s <- .mig024_in(con, sprintf('SELECT s.*, f.name AS feat FROM "sample" s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias
    JOIN feature f ON f.uuid = fa.uuid_feature WHERE s.uuid IN %s', .mig024_inlist(c(.mig024_psamples(), .mig024_twins()))), NULL)
  if (nrow(s) != 20L) return(sprintf("%d of the 20 pipeline/twin samples exist", nrow(s)))
  pairs <- unique(P[, c("feat", "uuid_pipeline_sample", "uuid_twin")])
  for (i in seq_len(nrow(pairs))) {
    p <- s[s$uuid == pairs$uuid_pipeline_sample[[i]], ]; l <- s[s$uuid == pairs$uuid_twin[[i]], ]
    if (p$feat != pairs$feat[[i]] || l$feat != pairs$feat[[i]]) return(sprintf("%s: pair is not at that feature", pairs$feat[[i]]))
    if (!is.na(p$datetime) || p$uuid_project != .mig024_project || l$uuid_project != .mig024_project) return(sprintf("%s: pipeline sample is not the NULL-datetime ES2425916 row", pairs$feat[[i]]))
    syd <- function(x) format(x, tz = "Australia/Sydney", "%Y-%m-%d")
    if (format(p$date, tz = "UTC", "%Y-%m-%d") != "2024-08-07" || syd(l$datetime) != "2024-08-07") return(sprintf("%s: pair is not on 2024-08-07", pairs$feat[[i]]))
  }
  # Each pipeline sample holds exactly its planned analyses.
  kids <- .mig024_in(con, sprintf("SELECT uuid, uuid_sample FROM analysis WHERE uuid_sample IN %s", .mig024_inlist(.mig024_psamples())), NULL)
  if (!setequal(kids$uuid, P$uuid) || nrow(kids) != nrow(P)) return(sprintf("pipeline samples hold %d analyses, not the planned %d", nrow(kids), nrow(P)))
  A <- .mig024_analyses(con, P$uuid)
  L <- .mig024_analyses(con, stats::na.omit(P$uuid_legacy))
  T <- .mig024_in(con, sprintf("SELECT a.uuid, a.uuid_sample, a.uuid_lab, lm.uuid_analyte, lm.method FROM analysis a JOIN lab_method lm ON lm.uuid = a.uuid_lab
    WHERE a.uuid_sample IN %s", .mig024_inlist(.mig024_twins())), NULL)
  an <- DBI::dbGetQuery(con, "SELECT uuid, uuid_analyte FROM lab_method")
  for (i in seq_len(nrow(P))) {
    r <- P[i, ]; a <- A[A$uuid == r$uuid, ]
    tag <- sprintf("%s %s %s", r$feat, r$analyte, substr(r$uuid, 1, 8))
    if (nrow(a) != 1L || a$uuid_sample != r$uuid_pipeline_sample || a$uuid_lab != r$uuid_lab) return(paste(tag, "is not where planned"))
    if (!.mig024_same_num(a$value, r$value) || !.mig024_same(a$value_chr, r$value_chr)) return(paste(tag, "value changed"))
    want_lab <- if (r$uuid_lab == .mig024_lm_from) .mig024_lm_to else r$uuid_lab
    if (r$action == "repoint_new") {
      # A FIELD reading of the same analyte on the twin would make this a
      # conflict, not new. ALS lab rows (e.g. EC @ 25C) are a different
      # measurement (A79) and stay alongside.
      if (any(T$uuid_sample == r$uuid_twin & T$uuid_analyte == an$uuid_analyte[an$uuid == r$uuid_lab] &
              !is.na(T$method) & T$method == "field")) return(paste(tag, "twin already has a field reading of that analyte"))
    } else {
      l <- L[L$uuid == r$uuid_legacy, ]
      if (nrow(l) != 1L || l$uuid_sample != r$uuid_twin || l$uuid_lab != want_lab) return(paste(tag, "legacy twin analysis not where planned"))
      if (sum(T$uuid_sample == r$uuid_twin & T$uuid_lab == want_lab) != 1L) return(paste(tag, "twin has more than one analysis on that lab_method"))
      if (r$action == "delete_dup") {
        for (f in c("value", "value_chr", "quantified", "rl_low", "rl_high", "purpose", "comments")) {
          ok <- if (is.numeric(a[[f]])) .mig024_same_num(a[[f]], l[[f]]) else .mig024_same(a[[f]], l[[f]])
          if (!ok) return(sprintf("%s is not a pure duplicate (%s differs)", tag, f))
        }
      } else if (!.mig024_same(l$value_chr, r$legacy_value_chr)) {
        return(paste(tag, "legacy Appearance text changed"))
      }
    }
  }
  O <- .mig024_analyses(con, .mig024_swl_other$uuid)
  if (nrow(O) != 3L || any(O$uuid_lab != .mig024_lm_from)) return("the 3 2023-10-10 SWL analyses are not on 45a8fbd1")
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ?", .mig024_lm_from) != 6L) return("45a8fbd1 does not hold exactly the 6 planned analyses")
  if (.mig024_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_lab = '%s' AND uuid_sample IN (SELECT uuid_sample FROM analysis WHERE uuid IN %s)",
                                  .mig024_lm_to, .mig024_inlist(.mig024_swl_other$uuid))) != 0L) return("a 2023-10-10 SWL sample already has a 68484c79 analysis")
  NULL
}

# The analysis half of the final state (true after step A, and after B).
.mig024_analyses_done_problem <- function(con) {
  P <- .mig024_plan
  gone <- c(.mig024_dups(), .mig024_replaced())
  if (nrow(.mig024_analyses(con, gone)) != 0L) return("a duplicate / replaced analysis still exists")
  M <- .mig024_analyses(con, .mig024_moved())
  if (nrow(M) != length(.mig024_moved())) return("a moved analysis is missing")
  for (i in which(P$action != "delete_dup")) {
    m <- M[M$uuid == P$uuid[[i]], ]
    if (m$uuid_sample != P$uuid_twin[[i]] || m$uuid_lab != P$uuid_lab[[i]] ||
        !.mig024_same_num(m$value, P$value[[i]]) || !.mig024_same(m$value_chr, P$value_chr[[i]])) {
      return(sprintf("%s %s not on its twin", P$feat[[i]], P$analyte[[i]]))
    }
  }
  O <- .mig024_analyses(con, .mig024_swl_other$uuid)
  if (nrow(O) != 3L || any(O$uuid_lab != .mig024_lm_to) || any(abs(O$value[order(O$uuid)] - .mig024_swl_other$value[order(.mig024_swl_other$uuid)]) > 1e-9)) return("2023-10-10 SWL analyses not on 68484c79")
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM analysis WHERE uuid_lab = ?", .mig024_lm_from) != 0L) return("45a8fbd1 still holds analyses")
  if (.mig024_scalar(con, sprintf("SELECT COUNT(*) FROM analysis WHERE uuid_sample IN %s", .mig024_inlist(.mig024_psamples()))) != 0L) return("a pipeline sample still holds analyses")
  # No twin carries two analyses on one lab_method.
  if (.mig024_scalar(con, sprintf("SELECT COUNT(*) FROM (SELECT 1 FROM analysis WHERE uuid_sample IN %s GROUP BY uuid_sample, uuid_lab HAVING COUNT(*) > 1)",
                                  .mig024_inlist(.mig024_twins()))) != 0L) return("a twin holds two analyses on one lab_method")
  NULL
}

.mig024_verify <- function(con) {
  fail <- function(msg) cli::cli_abort(paste0("024 verify failed: ", msg), class = "sampletidy_error")
  p <- .mig024_analyses_done_problem(con)
  if (!is.null(p)) fail(p)
  if (.mig024_scalar(con, sprintf('SELECT COUNT(*) FROM "sample" WHERE uuid IN %s', .mig024_inlist(.mig024_psamples()))) != 0L) fail("a pipeline sample still exists")
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid = ?", .mig024_lm_from) != 0L) fail("lab_method 45a8fbd1 still exists")
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid = ?", .mig024_lm_to) != 1L) fail("lab_method 68484c79 is missing")
  # The ACIRL label now folds to exactly one lab_method.
  lm <- DBI::dbGetQuery(con, "SELECT uuid, name FROM lab_method WHERE organisation = 'ACIRL'")
  k <- tolower(gsub("[^[:alnum:]]", "", lm$name))
  if (!identical(lm$uuid[!is.na(k) & k == "standingwaterlevel"], .mig024_lm_to)) fail("ACIRL standingwaterlevel does not fold to 68484c79 alone")
  # Appearance on the 5 replaced twins is the pipeline value.
  P <- .mig024_plan[.mig024_plan$action == "repoint_replace", ]
  ap <- DBI::dbGetQuery(con, sprintf("SELECT uuid_sample, value_chr FROM analysis WHERE uuid_lab = '%s' AND uuid_sample IN %s",
                                     .mig024_lm_appearance, .mig024_inlist(P$uuid_twin)))
  if (nrow(ap) != 5L || !identical(ap$value_chr[match(P$uuid_twin, ap$uuid_sample)], P$value_chr)) fail("Appearance on the 5 twins is not the pipeline value")
  invisible(TRUE)
}

mig024_backup <- function(db, snapshot_dir, .now = NULL) {
  now <- .mig024_default(.now, Sys.time())
  ts <- format(now, "%Y%m%dT%H%M%OS3", tz = "UTC")
  dest <- file.path(snapshot_dir, sprintf("monitoring_pre-024-merge-aug24-water-duplicates_%sZ.duckdb", ts))
  live_counts <- with_db_write(function(con) {
    DBI::dbExecute(con, "CHECKPOINT")
    counts <- .mig024_counts(con)
    ok <- tryCatch(suppressWarnings(file.copy(db, dest, overwrite = FALSE)), error = function(e) FALSE)
    if (!isTRUE(ok)) cli::cli_abort("{db}: failed to write backup copy to {dest}.", class = "sampletidy_error")
    counts
  }, db = db)
  verify_con <- tryCatch(DBI::dbConnect(duckdb::duckdb(), dest, read_only = TRUE), error = function(e) NULL)
  if (is.null(verify_con)) cli::cli_abort("{db}: backup verification failed - cannot open {dest}.", class = "sampletidy_error")
  on.exit(DBI::dbDisconnect(verify_con, shutdown = TRUE), add = TRUE)
  if (!identical(live_counts, .mig024_counts(verify_con))) {
    cli::cli_abort("{db}: backup verification failed - counts differ from {dest}.", class = "sampletidy_error")
  }
  dest
}

.mig024_write_csv <- function(df, path) {
  out <- df
  for (f in names(out)) if (inherits(out[[f]], "POSIXct")) out[[f]] <- .st_changelog_str(out[[f]])
  utils::write.csv(out, path, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  back <- utils::read.csv(path, stringsAsFactors = FALSE, na.strings = "", encoding = "UTF-8")
  if (nrow(back) != nrow(df) || !identical(back$uuid, out$uuid)) {
    cli::cli_abort("024: CSV backup {basename(path)} did not round-trip.", class = "sampletidy_error")
  }
}

.mig024_state <- function(con) {
  if (is.null(.mig024_initial_problem(con))) return("initial")
  if (is.null(.mig024_analyses_done_problem(con)) &&
      .mig024_scalar(con, sprintf('SELECT COUNT(*) FROM "sample" WHERE uuid IN %s', .mig024_inlist(.mig024_psamples()))) == 10L &&
      .mig024_scalar(con, "SELECT COUNT(*) FROM lab_method WHERE uuid = ?", .mig024_lm_from) == 1L) return("analyses_done")
  .mig024_fail(sprintf("the database is in neither the pre-024 state (%s) nor the post-step-A state. Restore from the backup.",
                       .mig024_initial_problem(con)))
}

.mig024_check_preconditions <- function(con) {
  if (.mig024_scalar(con, "SELECT COUNT(*) FROM schema_version WHERE version = ?", .mig024_requires) == 0L) {
    .mig024_fail(sprintf("marker %d (022) is required first.", .mig024_requires))
  }
  .mig024_state(con)
}

# Step A: every analysis write, one transaction.
.mig024_step_a <- function(con) {
  P <- .mig024_plan
  why <- "024 ruling 5: lab_method 45a8fbd1 'Standing water level' merged into 68484c79 'Standing Water Level' (ACIRL field, case-only split)"
  db_transaction(con, function(con) {
    # (i) The 6 analyses on 45a8fbd1, in ONE statement - see "THE 45a8fbd1
    # ANALYSES" in the header for why not db_delete()/db_update() per row.
    six <- DBI::dbGetQuery(con, "SELECT * FROM analysis WHERE uuid_lab = ? ORDER BY uuid", params = list(.mig024_lm_from))
    swl_dup <- P[P$uuid_lab == .mig024_lm_from, ]
    if (!setequal(six$uuid, c(swl_dup$uuid, .mig024_swl_other$uuid)) || nrow(six) != 6L) {
      cli::cli_abort("024: 45a8fbd1 does not hold exactly the 6 planned analyses.", class = "sampletidy_error")
    }
    n <- DBI::dbExecute(con, "DELETE FROM analysis WHERE uuid_lab = ?", params = list(.mig024_lm_from))
    if (n != 6L) cli::cli_abort("024: bulk delete on 45a8fbd1 removed {n} rows, not 6.", class = "sampletidy_error")
    at <- Sys.time()
    for (u in six$uuid) {
      d <- swl_dup[swl_dup$uuid == u, ]
      reason <- if (nrow(d)) {
        sprintf("024 ruling 2: pure duplicate %s Standing water level from the 2026-08-09 ingest of 2400-7399-08 (pipeline sample %s); identical twin %s on legacy sample %s (68484c79) survives",
                d$feat, d$uuid_pipeline_sample, d$uuid_legacy, d$uuid_twin)
      } else {
        paste0(why, "; row re-inserted unchanged except uuid_lab 45a8fbd1 -> 68484c79 (delete half)")
      }
      .st_write_change_log(con, at = at, actor = .mig024_actor, action = "delete", tbl = "analysis",
                           uuid_row = u, field = NA_character_, old = u, new = NA_character_,
                           reason = reason, source_hash = NA_character_)
    }
    keep <- six[six$uuid %in% .mig024_swl_other$uuid, , drop = FALSE]
    keep$uuid_lab <- .mig024_lm_to
    db_append(con, "analysis", keep, actor = .mig024_actor,
              reason = paste0(why, "; same uuid, every column as before except uuid_lab 45a8fbd1 -> 68484c79 (insert half)"))

    # (ii) Everything else, row by row.
    for (i in which(P$uuid_lab != .mig024_lm_from)) {
      r <- P[i, ]
      if (r$action == "delete_dup") {
        db_delete(con, "analysis", uuid = r$uuid, actor = .mig024_actor,
                  reason = sprintf("024 ruling 2: pure duplicate %s %s from the 2026-08-09 ingest of 2400-7399-08 (pipeline sample %s); identical twin %s on legacy sample %s survives",
                                   r$feat, r$analyte, r$uuid_pipeline_sample, r$uuid_legacy, r$uuid_twin))
      } else if (r$action == "repoint_new") {
        db_update(con, "analysis", uuid = r$uuid, changes = list(uuid_sample = r$uuid_twin), actor = .mig024_actor,
                  reason = sprintf("024 ruling 1: new %s %s reading moved from duplicate pipeline sample %s onto its legacy twin %s (2024-08-07)",
                                   r$feat, r$analyte, r$uuid_pipeline_sample, r$uuid_twin))
      } else {
        db_delete(con, "analysis", uuid = r$uuid_legacy, actor = .mig024_actor,
                  reason = sprintf("024 ruling 3: legacy %s Appearance '%s' replaced by the pipeline's A76-split value '%s' (analysis %s)",
                                   r$feat, r$legacy_value_chr, r$value_chr, r$uuid))
        db_update(con, "analysis", uuid = r$uuid, changes = list(uuid_sample = r$uuid_twin), actor = .mig024_actor,
                  reason = sprintf("024 ruling 3: pipeline %s Appearance '%s' wins over legacy '%s'; moved from duplicate pipeline sample %s onto legacy twin %s",
                                   r$feat, r$value_chr, r$legacy_value_chr, r$uuid_pipeline_sample, r$uuid_twin))
      }
    }
    p <- .mig024_analyses_done_problem(con)
    if (!is.null(p)) cli::cli_abort(paste0("024 step A verify failed: ", p), class = "sampletidy_error")
    NULL
  })
}

# Step B: the parents, the marker, verification.
.mig024_step_b <- function(con, recorded_at, sums_before) {
  pairs <- unique(.mig024_plan[, c("feat", "uuid_pipeline_sample", "uuid_twin")])
  db_transaction(con, function(con) {
    for (i in seq_len(nrow(pairs))) {
      db_delete(con, "sample", uuid = pairs$uuid_pipeline_sample[[i]], actor = .mig024_actor,
                reason = sprintf("024 ruling 4: duplicate %s 2024-08-07 sample from the 2026-08-09 ingest of 2400-7399-08 (NULL datetime), emptied by 024; legacy twin %s survives",
                                 pairs$feat[[i]], pairs$uuid_twin[[i]]))
    }
    db_delete(con, "lab_method", uuid = .mig024_lm_from, actor = .mig024_actor,
              reason = "024 ruling 5: ACIRL 'Standing water level' merged into 68484c79 'Standing Water Level'; every analysis re-pointed, the label now folds to 68484c79")
    DBI::dbExecute(con, "INSERT INTO schema_version (version, applied_at) VALUES (?, ?)",
                   params = list(.mig024_marker_version, recorded_at))
    .mig024_verify(con)
    if (!identical(sums_before, .mig024_checksum(con))) {
      cli::cli_abort("024 verify failed: something outside the planned rows moved.", class = "sampletidy_error")
    }
    NULL
  })
}

mig024_run <- function(db, snapshot_dir, dry_run = FALSE, .now = NULL, csv_dir = NULL) {
  logf <- function(fmt, ...) cat(sprintf("[%s] %s\n", db, sprintf(fmt, ...)))
  if (is.null(csv_dir)) csv_dir <- if (dir.exists("dev/migrations")) "dev/migrations" else snapshot_dir

  marker_con <- st_connect(db, read_only = TRUE)
  mine <- tryCatch(
    DBI::dbGetQuery(marker_con, "SELECT version, applied_at FROM schema_version WHERE version = ?",
                    params = list(.mig024_marker_version)),
    finally = DBI::dbDisconnect(marker_con, shutdown = TRUE))
  if (nrow(mine) > 0) {
    check_con <- st_connect(db, read_only = TRUE)
    tryCatch(.mig024_verify(check_con), finally = DBI::dbDisconnect(check_con, shutdown = TRUE))
    logf("024 already applied at %s; re-verified; nothing to do.", format(mine$applied_at[[1]]))
    return(invisible(list(status = "already_migrated", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = mine$applied_at[[1]])))
  }

  pre_con <- st_connect(db, read_only = TRUE)
  pre <- tryCatch({
    st <- .mig024_check_preconditions(pre_con)
    list(state = st,
         analysis = .mig024_analyses(pre_con, .mig024_touched()),
         sample = .mig024_in(pre_con, sprintf('SELECT * FROM "sample" WHERE uuid IN %s ORDER BY uuid', .mig024_inlist(.mig024_psamples())), NULL),
         lab_method = DBI::dbGetQuery(pre_con, "SELECT * FROM lab_method WHERE uuid = ?", params = list(.mig024_lm_from)))
  }, finally = DBI::dbDisconnect(pre_con, shutdown = TRUE))
  tab <- table(.mig024_plan$action)
  logf("State: %s. Plan: %s; %d 2023-10-10 SWL analyses re-labelled; 10 samples and lab_method 45a8fbd1 deleted.",
       pre$state, paste(sprintf("%s %d", names(tab), tab), collapse = ", "), nrow(.mig024_swl_other))
  if (isTRUE(dry_run)) {
    logf("DRY RUN: every precondition passed. No backup taken, nothing written.")
    return(invisible(list(status = "dry_run", backup_path = NA_character_,
                          restore_command = NA_character_, recorded_at = NA)))
  }

  if (pre$state == "initial") {
    .mig024_write_csv(pre$analysis, file.path(csv_dir, "024-merge-aug24-water-duplicates-BACKUP-analysis.csv"))
    .mig024_write_csv(pre$sample, file.path(csv_dir, "024-merge-aug24-water-duplicates-BACKUP-sample.csv"))
    .mig024_write_csv(pre$lab_method, file.path(csv_dir, "024-merge-aug24-water-duplicates-BACKUP-lab_method.csv"))
    logf("Row backups written to %s", csv_dir)
  } else {
    logf("Resuming after step A: the row backups from the first run are kept as they are.")
  }
  backup_path <- mig024_backup(db = db, snapshot_dir = snapshot_dir, .now = .now)
  restore_command <- sprintf("cp %s %s", shQuote(backup_path), shQuote(db))
  logf("Backup verified: %s", backup_path)
  logf("To restore if needed: %s", restore_command)
  recorded_at <- .mig024_default(.now, Sys.time())

  with_db_write(function(con) {
    st <- .mig024_check_preconditions(con)   # re-read under the write lock
    if (st != pre$state) cli::cli_abort("024: the state changed since the dry check.", class = "sampletidy_error")
    sums_before <- .mig024_checksum(con)
    if (st == "initial") {
      .mig024_step_a(con)
      logf("Step A committed: %d analyses re-pointed, %d deleted.",
           length(.mig024_moved()) + nrow(.mig024_swl_other), length(.mig024_dups()) + length(.mig024_replaced()))
    }
    .mig024_step_b(con, recorded_at, sums_before)
    logf("Step B committed: 10 samples and lab_method 45a8fbd1 deleted; marker %d.", .mig024_marker_version)
  }, db = db)

  logf("024-merge-aug24-water-duplicates migrated successfully.")
  invisible(list(status = "migrated", backup_path = backup_path,
                 restore_command = restore_command, recorded_at = recorded_at))
}
