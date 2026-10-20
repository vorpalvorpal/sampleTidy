# Duplicate check after a corpus import: compares an AFTER db with the BEFORE db
# (both opened read-only). Usage: Rscript dupcheck.R <after.duckdb> <before.duckdb> [out_dir]
# A NEW sample is a "likely duplicate" of another sample (in BEFORE, or another NEW
# one) at the same feature + Sydney day when, over the lab methods both carry (so a
# field reading never pairs with a lab result of the same analyte - A91 keeps those
# in separate samples), at least 2 values are equal (|diff| < 1e-9) AND at least half
# of the overlapping values are equal. Its equal analyses are the likely duplicate
# analyses. Two genuinely different samples of one point-day (e.g. ES2110707 vs
# ES2110710, 2021-03-23: 2 of 9 equal) share a value or two by coincidence; those
# coincidences are counted and listed, but do not fail the check. New samples at an existing point-day with disjoint analytes
# (e.g. an ACIRL field sample beside an ALS lab sample, A91) are reported, not failed.
a <- commandArgs(TRUE); stopifnot(length(a) >= 2)
out <- if (length(a) >= 3) a[[3]] else NULL
con <- DBI::dbConnect(duckdb::duckdb(), a[[1]], read_only = TRUE)
on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
invisible(DBI::dbExecute(con, sprintf("ATTACH '%s' AS p (READ_ONLY)", a[[2]])))
q <- function(s) DBI::dbGetQuery(con, s)
sd <- "cast(coalesce(s.date, s.datetime) + interval 11 hour as date)"
invisible(DBI::dbExecute(con, paste0("CREATE TEMP TABLE ns AS SELECT s.uuid, fa.uuid_feature f, ", sd, " d, s.organisation org, pr.name wo
  FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias LEFT JOIN project pr ON pr.uuid = s.uuid_project
  WHERE s.uuid NOT IN (SELECT uuid FROM p.sample)")))
invisible(DBI::dbExecute(con, paste0("CREATE TEMP TABLE oa AS SELECT s.uuid us, fa.uuid_feature f, ", sd, " d, lm.uuid_analyte an, a.uuid_lab lab, a.value
  FROM sample s JOIN feature_alias fa ON fa.uuid = s.uuid_feature_alias JOIN analysis a ON a.uuid_sample = s.uuid
  JOIN lab_method lm ON lm.uuid = a.uuid_lab WHERE fa.uuid_feature IS NOT NULL AND lm.uuid_analyte IS NOT NULL")))
invisible(DBI::dbExecute(con, "CREATE TEMP TABLE na AS SELECT ns.uuid, ns.f, ns.d, ns.wo, lm.uuid_analyte an, a.uuid_lab lab, a.value
  FROM ns JOIN analysis a ON a.uuid_sample = ns.uuid JOIN lab_method lm ON lm.uuid = a.uuid_lab
  WHERE ns.f IS NOT NULL AND lm.uuid_analyte IS NOT NULL"))
tot <- q("SELECT count(*) new_samples, count(*) FILTER (WHERE f IS NULL) new_pending,
  count(*) FILTER (WHERE f IS NOT NULL AND EXISTS (SELECT 1 FROM p.sample s JOIN p.feature_alias fa ON fa.uuid = s.uuid_feature_alias
     WHERE fa.uuid_feature = ns.f AND cast(coalesce(s.date, s.datetime) + interval 11 hour as date) = ns.d)) at_existing_point_day FROM ns")
invisible(DBI::dbExecute(con, "CREATE TEMP TABLE pr AS SELECT na.uuid, na.wo, oa.us,
  count(*) n_overlap, count(*) FILTER (WHERE abs(oa.value - na.value) < 1e-9) n_equal
  FROM na JOIN oa ON oa.f = na.f AND oa.d = na.d AND oa.lab = na.lab AND oa.us <> na.uuid GROUP BY ALL"))
dup <- q("SELECT wo, count(DISTINCT uuid) samples, sum(n_equal) analyses FROM (
  SELECT uuid, wo, max(n_equal) n_equal FROM pr WHERE n_equal >= 2 AND 2 * n_equal >= n_overlap GROUP BY ALL)
  GROUP BY 1 ORDER BY 3 DESC")
coinc <- q("SELECT pr.wo, pr.uuid, pr.us other, pr.n_equal, pr.n_overlap FROM pr WHERE n_equal >= 1
  AND NOT (n_equal >= 2 AND 2 * n_equal >= n_overlap) ORDER BY n_equal DESC")
same_an <- q("SELECT count(*) n FROM na WHERE EXISTS (SELECT 1 FROM oa WHERE oa.f = na.f AND oa.d = na.d AND oa.an = na.an AND oa.us <> na.uuid)")
ident <- q("SELECT count(*) n FROM (SELECT uuid_feature_alias, datetime, uuid_project FROM sample GROUP BY ALL HAVING count(*) > 1)")
ident0 <- q("SELECT count(*) n FROM (SELECT uuid_feature_alias, datetime, uuid_project FROM p.sample GROUP BY ALL HAVING count(*) > 1)")
removed <- q("SELECT (SELECT count(*) FROM p.sample WHERE uuid NOT IN (SELECT uuid FROM sample)) s, (SELECT count(*) FROM p.analysis WHERE uuid NOT IN (SELECT uuid FROM analysis)) a")
changed <- q("SELECT count(*) n FROM analysis a JOIN p.analysis b USING (uuid) WHERE a.value IS DISTINCT FROM b.value OR a.uuid_sample <> b.uuid_sample")
cat("new samples:", tot$new_samples, " pending (no feature):", tot$new_pending, " at an existing point-day:", tot$at_existing_point_day, "\n")
cat("new analyses with the same analyte at the same point-day (any value):", same_an$n, "\n")
cat("LIKELY DUPLICATES (same lab method, equal value, same point-day):", sum(dup$analyses), "analyses in", sum(dup$samples), "samples\n")
if (nrow(dup)) print(utils::head(dup, 30), row.names = FALSE)
cat("coincidental equal values (sample pairs with some equal values but mostly different; not duplicates):", nrow(coinc), "pairs,",
    sum(coinc$n_equal), "equal values\n")
if (nrow(coinc)) print(utils::head(coinc, 10), row.names = FALSE)
cat("identity-key duplicate groups (alias, datetime, project): before", ident0$n, "after", ident$n, " removed rows (sample/analysis):", removed$s, "/", removed$a,
    " existing analyses changed:", changed$n, "\n")
if (!is.null(out)) { dir.create(out, showWarnings = FALSE, recursive = TRUE)
  utils::write.csv(dup, file.path(out, "dupcheck_by_wo.csv"), row.names = FALSE)
  utils::write.csv(coinc, file.path(out, "dupcheck_coincidences.csv"), row.names = FALSE) }
invisible(sum(dup$analyses))
