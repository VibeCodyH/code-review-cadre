# Saved grading tables

Every `cadre run` or `cadre grade` report saves a matching `.table/` directory
beside the Markdown report. It contains `manifest.json`, `results.json`, a copy
of the report, and the raw judge grades used to produce it.

To publish a table based on the first numbered run of each pass:

```sh
cadre grade <agent-spec> 3 --selection first-run --freeze
```

The header reads the saved manifest and prints its selection rule, exclusion
count, and status. Share the entire `.table/` directory with the report so its
results and grade references remain available. Review the artifacts before
sharing: judge grades and reports can contain private source excerpts and
operator notes. Cadre writes these files locally; it does not upload them.

## Run selection

| Selection | Runs used |
|---|---|
| `all-runs` (default) | Every numbered run from 1 through the requested count; each contributes separately. |
| `first-run` | Numbered run 1 only, even if it is missing, invalid, or failed. Later runs cannot replace it. |

`first-run` records the other requested run numbers as selection exclusions.
It changes the grading denominator and the rows available to `cadre panel`.
Unknown selection values fail before grading. Selection options apply to
`cadre grade`; `cadre run` keeps its existing `all-runs` behavior.

A numbered run slot can have several dispatch attempts. These tables use the
latest retained artifact for that slot. `first-run` does not recover the first
historical dispatch attempt. `all-runs` reports per-run scores; the panel's
existing best-grade coverage matrix is a separate view of those rows.

## Manifest and results

The schema 1 manifest records:

- `status`: `open` or `frozen`.
- `selection`, `requested_runs`, candidate, judges, and pass scope.
- `passes`: each registered label, its resolved target commit SHA, and the
  SHA-256 of its answer key at table generation. Unavailable pins are `null`.
- `excluded`: pass labels or canonical run IDs, each with a kind and reason.
- `results` and `report`: relative paths with SHA-256 hashes.

Canonical run IDs combine the pass label, candidate slug, and numbered run.
`results.json` records each selected run's status and reconciled item grades.
Raw judge grades have relative paths and hashes and are copied into the table.
Judge outages keep their available grade artifacts and raw error replies. The summary uses the same
counters as the report, including unresolved ranges and separate graded-only
and delivery-inclusive denominators.

Exclusions include pass scope, missing keys or checkouts, selection, and
operator-invalid markers. To exclude a warmup or smoke run, use the existing
[operator-invalid marker](METHOD.md#graded-only-and-delivery-inclusive-hit-rates)
and give its reason. The count is the number of exclusion entries; an entry
can name an entire pass or one numbered run.

Delivery failures remain result rows because they can contribute MISS to the
delivery-inclusive rate. Timeout, missing-artifact, judge, and operator states
retain the grading rules in METHOD.md. Suspected key leaks invalidate both
score summaries and cannot be overridden with an operator-invalid marker.
CLEAN probes have no keyed-item denominator. Unavailable scores stay `null`
in JSON and `-` in the report.

## Freeze and regrade

Tables start `open`. Regrading an open table replaces its report, results, and
saved judge grades. A changed key changes the manifest's key hash. A key that
changes while the table is being generated makes publication fail.

`--freeze` writes a frozen table. A later `cadre run` or `cadre grade` for the
same candidate, judge list, and pass scope refuses before dispatching models
or changing its report or grades. Changing the run count or selection does not
bypass the freeze. A frozen failed measurement remains a failed measurement.

To correct a frozen table, preserve a copy of its whole `.table/` directory
first, then deliberately change the working manifest's `status` to `open` and
regrade. Cadre does not silently thaw tables or carry corrected numbers back
into the archived copy.

The saved report and grade copies remain stable when another pass scope
regrades the shared source artifacts. Freeze does not lock source checkouts,
answer keys, or every report that shares a judge. The table records the keys
present when it was generated; it cannot establish which key produced an old
cached grade that predates these manifests. Use `cadre grade` to regenerate
judge grades against the current key before publishing.

Offline verification: `bash tests/table-manifest.sh`.
