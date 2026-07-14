# sampleFlow

> A project of [`tidyWaste`](https://github.com/vorpalvorpal/tidyWaste) — an ecosystem of R packages for waste management facilities.

> Ingest and reconcile environmental monitoring sample data.
> Part of the [`tidyWaste`](https://github.com/vorpalvorpal/tidyWaste) family of packages.

`sampleFlow` is an email-triggered pipeline that turns the messy stream of
laboratory and field results an environmental monitoring programme receives —
ALS CSVs, human-made ACIRL spreadsheets, chain-of-custody PDFs, the occasional
internal or third-party result — into clean, reconciled rows in a DuckDB-backed
monitoring database, with every value linked back to its archived original file.

## Design

The architecture, data model and ingestion-pipeline design live in the pinned
**[design issue](https://github.com/vorpalvorpal/sampleFlow/issues/1)**. In short:

- **Generic/specific divide.** Lab- and format-specific *adapters* parse each
  source into a common **intermediate representation (IR)**. Everything
  downstream — reconciliation, unit handling, deduplication, storage, archiving,
  alerting — is generic and written once. A new lab or sampler is one new
  adapter.
- **Claude as proposer, never writer.** Ambiguous cases (new vs. mistyped
  analyte, unrecognised units, PDF free-text) become proposals in a review
  queue, resolved headlessly for high-confidence items or interactively via a
  skill. Ambiguity fails loud into quarantine — never a silent drop.
- **Local transport.** Outlook rules + Power Automate land attachments in a
  SharePoint folder synced to the Mac; the pipeline just watches a local
  directory. No API credentials in the pipeline.
- **DuckDB storage.** A single short-lived read-write connection is the write
  lock; analysis and reporting read a read-only snapshot copy.

## Status

Greenfield, pre-alpha. Skeleton only.
