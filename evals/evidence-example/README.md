# Cadre offline evidence

Raw reviews, run records, the original manifest, and synthesis/report artifacts are preserved without redaction. They may contain private text or original paths. Only the named evidence artifacts are copied; configuration and authentication files are not included. States describe delivery, not review quality.

Every cell includes the full saved binary diff. Missing evidence stays explicit; tokens are unmeasured because these receipts record bytes, not token usage. [manifest.json](manifest.json) inventories every exported file except itself by SHA256. Its source_locations maps original artifact filenames, including findings.json source references, to exported paths. runs.jsonl and slots.tsv are per-seat projections preserving original records.

| Seat | synthetic&#45;task |
| --- | --- |
| alpha | [ok](cells/e6457efde14068219109a2e93b10fb114c9df7cdfbf5a38f42717a3df917aba3/) |
| beta | [degraded](cells/fae5fee8e864e2c53f535ca0b6062f62a24922473cee28a1c86814d367975e8b/) |
| broken | [failed](cells/11c96a6b559f4ba7c8eb770a3c83dd464d1644b1ea484b02c27ee25b96cd5f3d/) |
