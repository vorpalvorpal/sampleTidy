# Test fixtures

Every fixture here is **synthetic**. The lab and contractor files are modelled
on the real delivery formats (ALS ESdat, crosstab and QCI reports, ACIRL
workbooks): their structure, encodings and format quirks follow the real
files, but every work order, lab id, point code, name, date and value is
invented. Where a generator exists it is deterministic, takes no real input,
and sits next to the files it writes; re-run it from the package root.

| directory | what | generator |
|---|---|---|
| `acirl/` | ACIRL field workbooks (`.xlsx`): the original layout fixtures, and the real-geometry set (`2400-9999-1x_*`) | `generate.R`, `generate-real-geometry.R`; see `README.md`, `README-real-geometry.md` |
| `corpus-2026-10-19/` | `2400-9999-16_SerialZeroDate_WMF.xlsx`: an ACIRL quarterly whose last `Date of Sample` cell is serial 0 | `generate-serial-zero.R` |
| `corpus-2026-10-19/latin1/`, `utf8-twin/` | a crosstab report as latin-1 bytes and its UTF-8 twin | see the generator in that directory |
| `crosstab/` | ALS XTAB / ENMRG crosstab exports (`.csv`, `.CSV`, SpreadsheetML `.XLS`, `.xlsx`) | `generate.R` and the other generator in that directory; see `README.md` |
| `esdat/` | ALS ESdat deliveries (Chemistry2e / Sample2e / Header.XML): the minimal `PROJ_*` set, negative cases, and the full-size `SITEA_Rain` trio (latin-1, CRLF, every QC sample type, batched NCP rows) | `generate.R`, `generate-sitea-rain.R`; see `README.md` |
| `qc/` | QC code list, and a second copy of an ENMRG crosstab under `secondary/` | see the crosstab generator |
| `qci/` | ALS QCI reports as `pdftotext -layout` text, plus two PDF stubs (empty, truncated) | see the generator in that directory |
| `registry-names/` | feature, analyte and lab-method name lists for the reconcile tests | none (static lists) |
| `spreadsheetml/` | SpreadsheetML `.XLS` crosstabs | `make-spreadsheetml.R` |
| `srn/` | ALS sample receipt notifications as text | none (hand-written) |

The real files cannot be committed: the lab PDFs and binary `.xls` workbooks
are not anonymisable byte for byte, and the data belongs to the client. A
fixture that needs a real-file property (an encoding, a cell type, a layout)
reproduces that property and nothing else.
