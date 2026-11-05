# Deterministic generator for the SITEA_Rain ESdat trio:
#   SITEA_Rain.ESDAT_ES2664217_0.{Chemistry2e.CSV,Sample2e.CSV,Header.XML}
#
# A SYNTHETIC delivery modelled on the shape of a real ALS ESdat export
# (a rain-event job batched with other clients' samples). Every id, value and
# limit below is invented; only the format is lab-shaped. Re-run with:
#   Rscript tests/testthat/fixtures/esdat/generate-sitea-rain.R
#
# Format quirks the tests rely on, all reproduced here:
# - Chemistry2e is LATIN-1 (raw 0xB0 / 0xB5 / 0xB1 bytes for degree / micro /
#   plus-minus; 72 such bytes), no BOM; Sample2e and Header.XML are ASCII.
# - CRLF line endings, and NO line terminator after the last row of either CSV;
#   Header.XML is a single line with no newline at all.
# - Sample2e: rows with a Parent_Sample carry one extra trailing comma (16
#   fields under a 15-field header), as the real export does.
# - Sample types: Normal 1, LAB_D 20, LCS 18, NCP 18, MB 9, MS 6.
# - Lab sample ids: `<wo>001` for the client sample, `QC-<lot>-<nnn>` and the
#   merged-batch `QC-MRG2/3/4-<lot><nnn>` shapes for lab QC, and
#   `<other wo><nnn>_<wo>` compound codes for other clients' batch samples
#   (NCP), including one `ME`-prefixed work order.
# - One MS row reports `-999` with unit `-` and comment `"ND"` (not determined).
# - LCS/MS rows report % recovery with UCL/LCL limits; MB rows are `<EQL`.

this_file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
here <- if (length(this_file_arg) == 1) {
  dirname(normalizePath(sub("^--file=", "", this_file_arg)))
} else {
  "tests/testthat/fixtures/esdat"
}

set.seed(20261105)
WO       <- "ES2664217"
STEM     <- paste0("SITEA_Rain.ESDAT_", WO, "_0")
LAB      <- "ALSE-Sydney"
PROJECT  <- "SITEA Rain Event - Example"
COC      <- "SITEA-COC-001"
REPORTED <- "2026-06-04"

DEG <- "°"; MICRO <- "µ"; PM <- "±"
uScm <- paste0(MICRO, "S/cm")
ec_name <- paste0("Electrical Conductivity @ 25", DEG, "C")
tss_method <- paste0("EA025H - EA025: Total Suspended Solids dried at 104 ", PM, " 2", DEG, "C")

# ---- analyte catalogue (ALS method vocabulary; synthetic value ranges) ------
# key, ChemCode, OriginalChemName, unit, T/F, Method_Type, Method_Name, EQL,
# decimals, lo, hi (range for invented values)
A <- function(key, code, name, unit, tf, mtype, mname, eql, dp, lo, hi)
  data.frame(key = key, code = code, name = name, unit = unit, tf = tf,
             mtype = mtype, mname = mname, eql = eql, dp = dp, lo = lo, hi = hi)
alk_t <- "Alkalinity by Auto Titrator"; alk_m <- "ED037-P - ED037P: Alkalinity by PC Titrator"
cat_t <- "Major Cations - Dissolved";  cat_m <- "ED093F - ED093F: Dissolved Major Cations"
nox_t <- "Nitrite and Nitrate as N (NOx) by Discrete Analyse"
nox_m <- "EK059G - EK059G:  Nitrite plus Nitrate as N (NOx)  by Discrete Analyse"
so4_t <- "Sulfate (Turbidimetric) as SO4 2- by Discrete Anal"
so4_m <- "ED041G - ED041G: Sulfate (Turbidimetric) as SO4 2- by DA"
ion_t <- "Ionic Balance by PCT DA and Turbi SO4 DA"; ion_m <- "EN055 - PG - EN055: Ionic Balance"
cat_ <- rbind(
  A("pH",   "pH_Lab", "pH Value", "pH Unit", "T", "pH by Auto Titrator", "EA005-P - EA005P: pH by PC Titrator", "0.01", 2, 6.2, 8.2),
  A("OH",   "ALK_HYDROXIDE_CaCO3", "Hydroxide Alkalinity as CaCO3", "mg/L", "T", alk_t, alk_m, "1", 0, 1, 2),
  A("CO3",  "ALK_CARBONATE_CaCO3", "Carbonate Alkalinity as CaCO3", "mg/L", "T", alk_t, alk_m, "1", 0, 1, 2),
  A("HCO3", "ALK_BICARB_CaCO3", "Bicarbonate Alkalinity as CaCO3", "mg/L", "T", alk_t, alk_m, "1", 0, 20, 120),
  A("ALK",  "ALK_CACO3", "Total Alkalinity as CaCO3", "mg/L", "T", alk_t, alk_m, "1", 0, 20, 120),
  A("TDS",  "TDS_Calc", "Total Dissolved Solids (Calc.)", "mg/L", "T", "Calculated TDS (from Electrical Conductivity)", "EA016 - EA016: Calculated TDS (from Electrical Conductivity)", "1", 0, 80, 1600),
  A("EC",   "EC_Lab", ec_name, uScm, "T", "Conductivity by Auto Titrator", "EA010-P - EA010P: Conductivity by PC Titrator", "1", 0, 120, 2600),
  A("F",    "16984-48-8", "Fluoride", "mg/L", "T", "Fluoride by Auto Titrator", "EK040P - EK040P: Fluoride by PC Titrator", "0.1", 1, 0.2, 1.2),
  A("Cl",   "16887-00-6", "Chloride", "mg/L", "T", "Chloride by Discrete Analyser", "ED045G - ED045G: Chloride by Discrete Analyser", "1", 0, 5, 120),
  A("SO4",  "14808-79-8_Turb", "Sulfate as SO4 - Turbidimetric", "mg/L", "F", so4_t, so4_m, "1", 0, 5, 600),
  A("RP",   "7723-14-0_Reac_AsP", "Reactive Phosphorus as P", "mg/L", "F", "Reactive Phosphorus as P-By Discrete Analyser", "EK071G - EK071G: Reactive Phosphorus as P by discrete analyser", "0.01", 2, 0.01, 0.08),
  A("NH3",  "7664-41-7 (as N)", "Ammonia as N", "mg/L", "T", "Ammonia as N by Discrete analyser", "EK055G - EK055G: Ammonia as N by Discrete Analyser", "0.01", 2, 0.02, 6),
  A("ANI",  "TOTALANIONS", "Total Anions", "meq/L", "T", ion_t, ion_m, "0.01", 2, 1, 10),
  A("CAT",  "TOTALCATIONS", "Total Cations", "meq/L", "T", ion_t, ion_m, "0.01", 2, 1, 10),
  A("NO3",  "14797-55-8(as N)", "Nitrate as N", "mg/L", "T", "Nitrate as N by Discrete Analyser", "EK058G - EK058G:  Nitrate as N by Discrete Analyser", "0.01", 2, 0.05, 1.5),
  A("NO2",  "14797-65-0(as N)", "Nitrite as N", "mg/L", "T", "Nitrite as N by Discrete Analyser", "EK057G - EK057G:  Nitrite as N by Discrete Analyser", "0.01", 2, 0.01, 1),
  A("NOX",  "NO3+NO2 (as N)", "Nitrite + Nitrate as N", "mg/L", "T", nox_t, nox_m, "0.01", 2, 0.05, 1.5),
  A("Ca",   "7440-70-2", "Calcium", "mg/L", "F", cat_t, cat_m, "1", 0, 5, 120),
  A("Mg",   "7439-95-4", "Magnesium", "mg/L", "F", cat_t, cat_m, "1", 0, 2, 90),
  A("Na",   "7440-23-5", "Sodium", "mg/L", "F", cat_t, cat_m, "1", 0, 10, 380),
  A("K",    "7440-09-7", "Potassium", "mg/L", "F", cat_t, cat_m, "1", 0, 2, 40),
  A("HARD", "Hardness_as_CaCO3", "Total Hardness as CaCO3", "mg/L", "F", cat_t, "ED093F - EA065: Total Hardness as CaCO3", "1", 0, 20, 600),
  A("TOC",  "TOC", "Total Organic Carbon", "mg/L", "T", "Total Organic Carbon", "EP005 - EP005: Total Organic Carbon (TOC)", "1", 0, 2, 15),
  A("TSS",  "TSS", "Suspended Solids (SS)", "mg/L", "T", "Suspended Solids (High Level)", tss_method, "5", 0, 6, 90)
)
rownames(cat_) <- cat_$key

# ---- delivery structure (ids invented; `@` = this work order) ---------------
# Sample2e: SampleCode | Sampled_Date_Time | Field_ID | Sample_Type |
#           Parent_Sample | received (Blank3) | SDG set? | trailing comma?
samples_spec <- "
@001|28 May 2026 11:09|Q.E01|Normal||28 May 2026|Y|
QC-3610101-001_@|28 May 2026 12:41||LCS||||
QC-3610101-002_@|28 May 2026 12:41||LCS||||
QC-3610102-002_@|28 May 2026 12:41||LCS||||
QC-3610102-025_@|28 May 2026 12:41||MB||||
QC-3610102-026_@|28 May 2026 12:41||LCS||||
QC-3610102-050_@|28 May 2026 12:41||MB||||
QC-3610102-051_@|28 May 2026 12:41||LCS||||
QC-3610103-001_@|28 May 2026 12:41||LCS||||
QC-3610103-002_@|28 May 2026 12:41||LCS||||
QC-3610104-005_@|28 May 2026 12:41||MS|@001|||Y
QC-3611017-001_@|01 Jun 2026 06:04||MB||||
QC-3611017-002_@|01 Jun 2026 06:04||LCS||||
QC-3611017-004_@|01 Jun 2026 06:04||LAB_D|ES2664187002_@|||Y
QC-3611017-005_@|01 Jun 2026 06:04||MS|ES2664187003_@|||Y
QC-3611017-016_@|01 Jun 2026 06:04||LAB_D|ES2664218003_@|||Y
QC-3612586-004_@|29 May 2026 14:06||LAB_D|ES2664106001_@|||Y
QC-3612586-005_@|29 May 2026 14:06||MS|ES2664106001_@|||Y
QC-3612586-015_@|29 May 2026 14:06||LAB_D|ES2664288005_@|||Y
QC-3612589-015_@|29 May 2026 14:06||LAB_D|ES2664288007_@|||Y
QC-3615720-004_@|01 Jun 2026 11:37||LAB_D|ES2664164005_@|||Y
QC-3619454-004_@|03 Jun 2026 06:58||LAB_D|ES2664153001_@|||Y
QC-3619454-005_@|03 Jun 2026 06:58||MS|ES2664153001_@|||Y
QC-3619455-004_@|03 Jun 2026 06:58||LAB_D|ES2664158001_@|||Y
QC-3619455-005_@|03 Jun 2026 06:58||MS|ES2664158001_@|||Y
QC-3620290-002_@|03 Jun 2026 14:13||LCS||||
QC-3620290-003_@|03 Jun 2026 14:13||LCS||||
QC-3620290-004_@|03 Jun 2026 14:13||LCS||||
QC-3620290-006_@|03 Jun 2026 14:13||LAB_D|ES2664152001_@|||Y
QC-3620290-017_@|03 Jun 2026 14:13||LAB_D|@001|||Y
QC-3620290-027_@|03 Jun 2026 14:13||MB||||
QC-3620290-028_@|03 Jun 2026 14:13||LCS||||
QC-3620290-029_@|03 Jun 2026 14:13||LCS||||
QC-3620290-031_@|03 Jun 2026 14:13||LAB_D|ES2664778003_@|||Y
QC-MRG2-3610101004_@|28 May 2026 12:41||LAB_D|ES2664158001_@|||Y
QC-MRG2-3610101014_@|28 May 2026 12:41||LAB_D|ES2664158010_@|||Y
QC-MRG2-3610102001_@|28 May 2026 12:41||MB||||
QC-MRG2-3610102003_@|28 May 2026 12:41||LCS||||
QC-MRG2-3612587003_@|29 May 2026 14:06||LCS||||
QC-MRG2-3612587016_@|29 May 2026 14:06||LAB_D|ME2660785001_@|||Y
QC-MRG2-3615720015_@|01 Jun 2026 11:37||LAB_D|ES2664218003_@|||Y
QC-MRG2-3615721002_@|01 Jun 2026 11:37||MB||||
QC-MRG2-3615721003_@|01 Jun 2026 11:37||LCS||||
QC-MRG2-3619454001_@|03 Jun 2026 06:58||MB||||
QC-MRG2-3619454002_@|03 Jun 2026 06:58||LCS||||
QC-MRG2-3619454015_@|03 Jun 2026 06:58||LAB_D|ES2664218006_@|||Y
QC-MRG2-3620290001_@|03 Jun 2026 14:13||MB||||
QC-MRG3-3612587005_@|29 May 2026 14:06||LAB_D|ES2664164011_@|||Y
QC-MRG3-3612587006_@|29 May 2026 14:06||MS|ES2664164011_@|||Y
QC-MRG4-3610105004_@|28 May 2026 12:41||LAB_D|ES2664220002_@|||Y
QC-MRG4-3610105014_@|28 May 2026 12:41||LAB_D|ES2664220011_@|||Y
QC-MRG4-3610108004_@|28 May 2026 12:41||LAB_D|ES2664221001_@|||Y
QC-MRG4-3612586001_@|29 May 2026 14:06||MB||||
QC-MRG4-3612586002_@|29 May 2026 14:06||LCS||||
ES2664106001_@|28 May 2026 06:05||NCP||28 May 2026||
ES2664152001_@|28 May 2026 12:26||NCP||28 May 2026||
ES2664153001_@|27 May 2026 07:15||NCP||28 May 2026||
ES2664158001_@|28 May 2026 07:35||NCP||28 May 2026||
ES2664158010_@|28 May 2026 12:03||NCP||28 May 2026||
ES2664164005_@|27 May 2026 15:07||NCP||28 May 2026||
ES2664164011_@|28 May 2026 09:40||NCP||28 May 2026||
ES2664187002_@|25 May 2026 16:37||NCP||28 May 2026||
ES2664187003_@|25 May 2026 06:36||NCP||28 May 2026||
ES2664218003_@|27 May 2026 15:25||NCP||28 May 2026||
ES2664218006_@|27 May 2026 06:14||NCP||28 May 2026||
ES2664220002_@|28 May 2026 06:35||NCP||28 May 2026||
ES2664220011_@|28 May 2026 08:18||NCP||28 May 2026||
ES2664221001_@|28 May 2026 12:09||NCP||28 May 2026||
ES2664288005_@|28 May 2026 11:09||NCP||28 May 2026||
ES2664288007_@|28 May 2026 11:09||NCP||28 May 2026||
ES2664778003_@|02 Jun 2026 14:07||NCP||02 Jun 2026||
ME2660785001_@|27 May 2026 15:19||NCP||28 May 2026||"
# Chemistry2e: SampleCode | analyte key | kind | Extraction_Date | Analysed_Date
#   kind: v = value, < = below EQL, p = % recovery, nd = not determined
chem_spec <- "
@001|pH|v|28 May 2026|28 May 2026
@001|OH|<|28 May 2026|28 May 2026
@001|CO3|<|28 May 2026|28 May 2026
@001|HCO3|v|28 May 2026|28 May 2026
@001|ALK|v|28 May 2026|28 May 2026
@001|TDS|v||01 Jun 2026
@001|EC|v|28 May 2026|28 May 2026
@001|F|<|28 May 2026|28 May 2026
@001|Cl|v|29 May 2026|29 May 2026
@001|SO4|v|29 May 2026|29 May 2026
@001|RP|<|29 May 2026|29 May 2026
@001|NH3|v|03 Jun 2026|03 Jun 2026
@001|ANI|v||02 Jun 2026
@001|CAT|v||02 Jun 2026
@001|NO3|v||03 Jun 2026
@001|NO2|<|29 May 2026|29 May 2026
@001|NOX|v|03 Jun 2026|03 Jun 2026
@001|Ca|v|01 Jun 2026|01 Jun 2026
@001|Mg|v|01 Jun 2026|01 Jun 2026
@001|Na|v|01 Jun 2026|01 Jun 2026
@001|K|v|01 Jun 2026|01 Jun 2026
@001|HARD|v|01 Jun 2026|01 Jun 2026
@001|TOC|v||01 Jun 2026
@001|TSS|<|03 Jun 2026|03 Jun 2026
ES2664106001_@|NO2|v||29 May 2026
ES2664152001_@|TSS|v||03 Jun 2026
ES2664153001_@|NOX|<||03 Jun 2026
ES2664158001_@|pH|v||01 Jun 2026
ES2664158001_@|EC|v||28 May 2026
ES2664158001_@|NH3|v||03 Jun 2026
ES2664158010_@|pH|v||28 May 2026
ES2664158010_@|EC|v||28 May 2026
ES2664164005_@|Ca|v||01 Jun 2026
ES2664164005_@|Mg|v||01 Jun 2026
ES2664164005_@|Na|v||01 Jun 2026
ES2664164005_@|K|v||01 Jun 2026
ES2664164011_@|Cl|v||29 May 2026
ES2664164011_@|SO4|v||29 May 2026
ES2664164011_@|RP|<||29 May 2026
ES2664187002_@|TOC|v||01 Jun 2026
ES2664187003_@|TOC|<||01 Jun 2026
ES2664218003_@|Ca|v||01 Jun 2026
ES2664218003_@|Mg|v||01 Jun 2026
ES2664218003_@|Na|v||01 Jun 2026
ES2664218003_@|K|<||01 Jun 2026
ES2664218003_@|TOC|v||01 Jun 2026
ES2664218006_@|NH3|v||03 Jun 2026
ES2664218006_@|NOX|v||03 Jun 2026
ES2664220002_@|OH|<||28 May 2026
ES2664220002_@|CO3|<||28 May 2026
ES2664220002_@|HCO3|v||28 May 2026
ES2664220002_@|ALK|v||28 May 2026
ES2664220002_@|F|v||28 May 2026
ES2664220002_@|EC|v||28 May 2026
ES2664220011_@|OH|<||28 May 2026
ES2664220011_@|CO3|<||28 May 2026
ES2664220011_@|HCO3|v||28 May 2026
ES2664220011_@|ALK|v||28 May 2026
ES2664220011_@|F|v||28 May 2026
ES2664220011_@|EC|v||28 May 2026
ES2664221001_@|EC|v||28 May 2026
ES2664288005_@|NO2|v||29 May 2026
ES2664288007_@|RP|v||29 May 2026
ES2664778003_@|TSS|v||03 Jun 2026
ME2660785001_@|Cl|v||29 May 2026
ME2660785001_@|SO4|v||29 May 2026
QC-3610101-001_@|pH|p|28 May 2026|28 May 2026
QC-3610101-002_@|pH|p|28 May 2026|28 May 2026
QC-3610102-002_@|EC|p|28 May 2026|28 May 2026
QC-3610102-025_@|EC|<|28 May 2026|28 May 2026
QC-3610102-026_@|EC|p|28 May 2026|28 May 2026
QC-3610102-050_@|EC|<|28 May 2026|28 May 2026
QC-3610102-051_@|EC|p|28 May 2026|28 May 2026
QC-3610103-001_@|ALK|p|28 May 2026|28 May 2026
QC-3610103-002_@|ALK|p|28 May 2026|28 May 2026
QC-3610104-005_@|F|p|28 May 2026|28 May 2026
QC-3611017-001_@|TOC|<||01 Jun 2026
QC-3611017-002_@|TOC|p||01 Jun 2026
QC-3611017-004_@|TOC|v||01 Jun 2026
QC-3611017-005_@|TOC|p||01 Jun 2026
QC-3611017-016_@|TOC|v||01 Jun 2026
QC-3612586-004_@|NO2|v|29 May 2026|29 May 2026
QC-3612586-005_@|NO2|p|29 May 2026|29 May 2026
QC-3612586-015_@|NO2|v|29 May 2026|29 May 2026
QC-3612589-015_@|RP|v|29 May 2026|29 May 2026
QC-3615720-004_@|Ca|v|01 Jun 2026|01 Jun 2026
QC-3615720-004_@|Mg|v|01 Jun 2026|01 Jun 2026
QC-3615720-004_@|Na|v|01 Jun 2026|01 Jun 2026
QC-3615720-004_@|K|v|01 Jun 2026|01 Jun 2026
QC-3619454-004_@|NOX|<|03 Jun 2026|03 Jun 2026
QC-3619454-005_@|NOX|p|03 Jun 2026|03 Jun 2026
QC-3619455-004_@|NH3|v|03 Jun 2026|03 Jun 2026
QC-3619455-005_@|NH3|p|03 Jun 2026|03 Jun 2026
QC-3620290-002_@|TSS|p|03 Jun 2026|03 Jun 2026
QC-3620290-003_@|TSS|p|03 Jun 2026|03 Jun 2026
QC-3620290-004_@|TSS|p|03 Jun 2026|03 Jun 2026
QC-3620290-006_@|TSS|v|03 Jun 2026|03 Jun 2026
QC-3620290-017_@|TSS|<|03 Jun 2026|03 Jun 2026
QC-3620290-027_@|TSS|<|03 Jun 2026|03 Jun 2026
QC-3620290-028_@|TSS|p|03 Jun 2026|03 Jun 2026
QC-3620290-029_@|TSS|p|03 Jun 2026|03 Jun 2026
QC-3620290-031_@|TSS|v|03 Jun 2026|03 Jun 2026
QC-MRG2-3610101004_@|pH|v|28 May 2026|01 Jun 2026
QC-MRG2-3610101004_@|EC|v|28 May 2026|28 May 2026
QC-MRG2-3610101014_@|pH|v|28 May 2026|28 May 2026
QC-MRG2-3610101014_@|EC|v|28 May 2026|28 May 2026
QC-MRG2-3610102001_@|EC|<|28 May 2026|28 May 2026
QC-MRG2-3610102001_@|F|<|28 May 2026|28 May 2026
QC-MRG2-3610102003_@|EC|p|28 May 2026|28 May 2026
QC-MRG2-3610102003_@|F|p|28 May 2026|28 May 2026
QC-MRG2-3612587003_@|Cl|p|29 May 2026|29 May 2026
QC-MRG2-3612587003_@|SO4|p|29 May 2026|29 May 2026
QC-MRG2-3612587016_@|SO4|v|29 May 2026|29 May 2026
QC-MRG2-3612587016_@|Cl|v|29 May 2026|29 May 2026
QC-MRG2-3615720015_@|Ca|v|01 Jun 2026|01 Jun 2026
QC-MRG2-3615720015_@|Mg|v|01 Jun 2026|01 Jun 2026
QC-MRG2-3615720015_@|Na|v|01 Jun 2026|01 Jun 2026
QC-MRG2-3615720015_@|K|<|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721002_@|Ca|<|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721002_@|Mg|<|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721002_@|Na|<|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721002_@|K|<|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721003_@|Ca|p|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721003_@|Mg|p|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721003_@|Na|p|01 Jun 2026|01 Jun 2026
QC-MRG2-3615721003_@|K|p|01 Jun 2026|01 Jun 2026
QC-MRG2-3619454001_@|NOX|<|03 Jun 2026|03 Jun 2026
QC-MRG2-3619454001_@|NH3|<|03 Jun 2026|03 Jun 2026
QC-MRG2-3619454002_@|NOX|p|03 Jun 2026|03 Jun 2026
QC-MRG2-3619454002_@|NH3|p|03 Jun 2026|03 Jun 2026
QC-MRG2-3619454015_@|NH3|v|03 Jun 2026|03 Jun 2026
QC-MRG2-3619454015_@|NOX|v|03 Jun 2026|03 Jun 2026
QC-MRG2-3620290001_@|TSS|<|03 Jun 2026|03 Jun 2026
QC-MRG3-3612587005_@|Cl|v|29 May 2026|29 May 2026
QC-MRG3-3612587005_@|SO4|v|29 May 2026|29 May 2026
QC-MRG3-3612587005_@|RP|<|29 May 2026|29 May 2026
QC-MRG3-3612587006_@|Cl|p|29 May 2026|29 May 2026
QC-MRG3-3612587006_@|SO4|nd|29 May 2026|29 May 2026
QC-MRG3-3612587006_@|RP|p|29 May 2026|29 May 2026
QC-MRG4-3610105004_@|OH|<|28 May 2026|28 May 2026
QC-MRG4-3610105004_@|CO3|<|28 May 2026|28 May 2026
QC-MRG4-3610105004_@|HCO3|v|28 May 2026|28 May 2026
QC-MRG4-3610105004_@|ALK|v|28 May 2026|28 May 2026
QC-MRG4-3610105004_@|F|v|28 May 2026|28 May 2026
QC-MRG4-3610105004_@|EC|v|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|OH|<|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|CO3|<|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|HCO3|v|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|ALK|v|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|F|v|28 May 2026|28 May 2026
QC-MRG4-3610105014_@|EC|v|28 May 2026|28 May 2026
QC-MRG4-3610108004_@|EC|v|28 May 2026|28 May 2026
QC-MRG4-3612586001_@|NO2|<|29 May 2026|29 May 2026
QC-MRG4-3612586001_@|Cl|<|29 May 2026|29 May 2026
QC-MRG4-3612586001_@|SO4|<|29 May 2026|29 May 2026
QC-MRG4-3612586001_@|RP|<|29 May 2026|29 May 2026
QC-MRG4-3612586002_@|NO2|p|29 May 2026|29 May 2026
QC-MRG4-3612586002_@|Cl|p|29 May 2026|29 May 2026
QC-MRG4-3612586002_@|SO4|p|29 May 2026|29 May 2026
QC-MRG4-3612586002_@|RP|p|29 May 2026|29 May 2026"

rd <- function(txt, cols) {
  x <- utils::read.table(text = trimws(txt), sep = "|", header = FALSE,
                         col.names = cols, colClasses = "character",
                         quote = "", comment.char = "", na.strings = NULL)
  x[] <- lapply(x, function(v) gsub("@", WO, v, fixed = TRUE))
  x
}
S <- rd(samples_spec, c("code", "dt", "field", "type", "parent", "recv", "sdg", "trail"))
C <- rd(chem_spec, c("code", "key", "kind", "ext", "ana"))
stype <- stats::setNames(S$type, S$code)
sparent <- stats::setNames(S$parent, S$code)

# ---- invented values --------------------------------------------------------
fmt <- function(x, dp) formatC(x, format = "f", digits = dp)
draw <- function(key) {
  a <- cat_[key, ]
  exp(stats::runif(1, log(a$lo), log(a$hi)))
}
val <- list()              # numeric value per sample|key (for derived + dups)
getv <- function(code, key) val[[paste(code, key, sep = "|")]]
derive <- function(code, key) {
  g <- function(k) { v <- getv(code, k); if (is.null(v)) NA_real_ else v }
  switch(key,
    ALK  = g("HCO3"),
    NOX  = sum(g("NO3"), if (is.na(g("NO2"))) 0 else g("NO2")),
    HARD = 2.497 * g("Ca") + 4.118 * g("Mg"),
    TDS  = 0.65 * g("EC"),
    ANI  = g("HCO3") / 50.04 + g("Cl") / 35.45 + g("SO4") / 48.03,
    CAT  = g("Ca") / 20.04 + g("Mg") / 12.15 + g("Na") / 22.99 + g("K") / 39.10,
    NA_real_)
}
res <- character(nrow(C)); pre <- character(nrow(C)); unit <- character(nrow(C))
equ <- character(nrow(C)); com <- character(nrow(C)); ucl <- character(nrow(C)); lcl <- character(nrow(C))
# Measured analytes first, then the ones derived from them (alkalinity, NOx,
# hardness, TDS, ion sums), then LAB_D rows, so each duplicate can echo its
# parent's value.
derived <- C$key %in% c("ALK", "NOX", "HARD", "TDS", "ANI", "CAT")
labd <- stype[C$code] == "LAB_D"
ord <- c(which(!labd & !derived), which(!labd & derived), which(labd))
for (i in ord) {
  a <- cat_[C$key[i], ]
  unit[i] <- a$unit; equ[i] <- a$unit
  if (C$kind[i] == "<") {
    pre[i] <- "<"; res[i] <- a$eql
  } else if (C$kind[i] %in% c("p", "nd")) {
    unit[i] <- "%"; equ[i] <- "%"
    lims <- if (stype[[C$code[i]]] == "MS") c(130, 70) else
      c(round(stats::runif(1, 108, 128)), round(stats::runif(1, 80, 92), 1))
    ucl[i] <- fmt(lims[1], 0); lcl[i] <- fmt(lims[2], 1)
    if (C$kind[i] == "nd") {
      res[i] <- "-999"; unit[i] <- "-"; com[i] <- "\"ND\""
    } else {
      r <- stats::runif(1, lims[2] + 0.3 * diff(rev(lims)), lims[1] - 0.3 * diff(rev(lims)))
      res[i] <- if (r >= 100) fmt(r, 0) else fmt(r, 1)
    }
  } else {
    code <- C$code[i]
    parent <- sparent[[code]]
    pv <- if (stype[[code]] == "LAB_D" && nzchar(parent)) getv(parent, C$key[i]) else NULL
    x <- if (!is.null(pv)) pv * stats::runif(1, 0.93, 1.07) else {
      d <- derive(code, C$key[i]); if (is.na(d)) draw(C$key[i]) else d
    }
    x <- max(x, 2 * as.numeric(a$eql))
    x <- round(x, a$dp)
    val[[paste(code, C$key[i], sep = "|")]] <- x
    res[i] <- fmt(x, a$dp)
  }
}

# ---- write ------------------------------------------------------------------
q <- function(s) paste0("\"", s, "\"")
write_crlf <- function(lines, path, latin1 = FALSE) {
  txt <- paste(lines, collapse = "\r\n")            # no final terminator
  bytes <- if (latin1) iconv(txt, from = "UTF-8", to = "latin1", toRaw = TRUE)[[1]] else charToRaw(txt)
  writeBin(bytes, path)
}

chem_header <- "SampleCode,ChemCode,OriginalChemName,Prefix,Result,Result_Unit,Total_or_Filtered,Result_Type,Method_Type,Method_Name,Extraction_Date,Analysed_Date,EQL,EQL_Units,Comments,Lab_Qualifier,UCL,LCL"
a <- cat_[C$key, ]
chem_lines <- paste(C$code, q(a$code), q(a$name), pre, res, unit, a$tf, "REG",
                    q(a$mtype), q(a$mname), C$ext, C$ana, a$eql, equ, com, "",
                    ucl, lcl, sep = ",")
write_crlf(c(chem_header, chem_lines), file.path(here, paste0(STEM, ".Chemistry2e.CSV")), latin1 = TRUE)

sample_header <- "SampleCode,Sampled_Date_Time,Field_ID,Blank1,Depth,Blank2,Matrix_Type,Sample_Type,Parent_Sample,Blank3,SDG,Lab_Name,Lab_SampleID,Lab_Comments,Lab_Report_Number"
sample_lines <- paste0(
  paste(S$code, S$dt, ifelse(nzchar(S$field), q(S$field), ""), "", "", "",
        "WATER", S$type, S$parent, S$recv, ifelse(S$sdg == "Y", COC, ""), LAB,
        sub(paste0("_", WO, "$"), "", S$code), "", WO, sep = ","),
  ifelse(S$trail == "Y", ",", ""))
write_crlf(c(sample_header, sample_lines), file.path(here, paste0(STEM, ".Sample2e.CSV")))

header <- paste0(
  '<?xml version="1.0" encoding="utf-8"?>',
  '<ESdat xmlns="http://www.escis.com.au/2013/XML" generated="', REPORTED,
  'T09:15:42.107+10:00" fileType="eLabResultsHeader" schemaVersion="1.0.1">',
  '<LabReport Lab_Report_Number="', WO, '" Date_Reported="', REPORTED,
  '" Project_ID="', PROJECT, '" Project_Number="', PROJECT, '" Lab_Name="', LAB,
  '" Lab_Signatory="A. Analyst" Lab_Contact_Email="esdat@lab.example">',
  '<Associated_Files xmlns="http://www.escis.com.au/2013/XML/LabReport"/>',
  '<Copies_Sent_To xmlns="http://www.escis.com.au/2013/XML/LabReport"/>',
  '<eCoCs xmlns="http://www.escis.com.au/2013/XML/LabReport"><eCoC CoC_Number="', COC,
  '"><Lab_Requests><Lab_Request Number="1" Version="1"/></Lab_Requests></eCoC></eCoCs>',
  '</LabReport></ESdat>')
writeBin(charToRaw(header), file.path(here, paste0(STEM, ".Header.XML")))

# ---- guards: the shape the tests rely on ------------------------------------
chem_raw <- readBin(file.path(here, paste0(STEM, ".Chemistry2e.CSV")), "raw", 1e6)
stopifnot(
  nrow(C) == 160, nrow(S) == 72,
  identical(as.vector(table(S$type)[c("LAB_D", "LCS", "MB", "MS", "NCP", "Normal")]),
            c(20L, 18L, 9L, 6L, 18L, 1L)),
  sum(as.integer(chem_raw) > 127) == 72,
  chem_raw[length(chem_raw)] != as.raw(0x0a)
)
message("wrote ", STEM, ".{Chemistry2e.CSV,Sample2e.CSV,Header.XML}")
