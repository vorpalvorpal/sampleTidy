# Monitoring-point roles. feature_role holds one row per monitoring point
# (uuid_feature): water_type and role are always set; a NULL source_cell or
# treatment means not applicable; lmf_end_member marks the point as a leachate
# end-member for the leachate mixing fraction, and end_member_note qualifies it
# (e.g. "very dilute"). feature_dubious holds features whose identity or
# position is doubted, with a short reason. Both tables are written by
# operator migration 093.
#
# Like migration 048's qc_feature side table, they hang off feature with no
# declared FOREIGN KEY (the orphan_feature_role_refs db_check enforces the
# link). The vocabularies are held here in package code, as the vocab_* checks
# do, and are NOT CHECK constraints: DuckDB cannot drop a constraint, so a
# constraint would freeze the vocabulary.

.st_water_types  <- c("groundwater", "surface", "leachate")
.st_point_roles  <- c("leachate", "containment", "receptor", "reference")
.st_source_cells <- c("A", "B", "A+B", "single cell", "transfer station", "street sweepings", "other")
.st_treatments   <- c("raw", "treated", "partly treated")

.feature_role_ddl <- list(
  feature_role = "
    CREATE TABLE feature_role (
      uuid_feature VARCHAR PRIMARY KEY, water_type VARCHAR NOT NULL, role VARCHAR NOT NULL,
      source_cell VARCHAR, treatment VARCHAR, lmf_end_member BOOLEAN NOT NULL DEFAULT FALSE,
      end_member_note VARCHAR, comments VARCHAR)",
  feature_dubious = "
    CREATE TABLE feature_dubious (
      uuid_feature VARCHAR PRIMARY KEY, reason VARCHAR NOT NULL, date_flagged DATE NOT NULL)"
)

#' Create the feature_role / feature_dubious tables that are missing
#' (migration 093). Tables already present are left alone.
#' @keywords internal
#' @noRd
.feature_role_create_schema <- function(con) {
  for (t in setdiff(names(.feature_role_ddl), DBI::dbListTables(con))) {
    DBI::dbExecute(con, .feature_role_ddl[[t]])
  }
  invisible(con)
}

# Does this DB carry both tables? (False before the operator migration.)
.feature_role_ready <- function(con) {
  all(names(.feature_role_ddl) %in% DBI::dbListTables(con))
}
