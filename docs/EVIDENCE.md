# Export a panel's evidence

`cadre export-evidence` turns one finished `cadre review` panel into a local
directory with a linked table and one evidence directory per seat and task.
It requires Python 3 on Linux or macOS. No reviewer or judge runs during export.

Open the [synthetic example](../evals/evidence-example/README.md) to inspect
complete, partial and failed seats. Its reviews are hand-written fixtures;
no model was called and timing/token measurements are unmeasured.

```bash
cadre export-evidence "$CADRE_HOME/reviews/my-change" evals/my-change
```

The output directory must be new. Open its `README.md` to follow each table cell
to the raw review, synthesis, full diff and receipt. Inspect the files before
committing the output directory to your repository.

## What survives the export

Each seat keeps its recorded delivery status, including `degraded`, `failed`,
`inconclusive` and `skipped`. Missing review artifacts and missing completion
events remain visible gaps. A missing measurement is unmeasured, never zero.
The export does not infer dollar cost from output length.

The diff includes binary changes and full object IDs. For `--full` reviews,
the diff starts at an empty tree and includes the entire reviewed target.
Unchanged input produces a valid empty patch.

The artifact manifest records SHA-256 digests so copied evidence can be checked
byte for byte. These hashes detect changed files; they are not signatures and
do not prove that a provider produced the review.

Raw `findings.json` keeps its original `source.file` references. The export
manifest's `source_locations` maps those filenames to their exported paths.
Run events and slot rows are split by seat; the mapping lists every resulting
file, while source hashes describe the original unsplit inputs.

## Capture happens before the reviewers run

New panel runs save `diff.patch` and `diff.sha256` from their synthetic checkout,
then record the same digest in `manifest.txt`. This retains the change even
after the checkout is removed or the source branch moves. Capture disables
external diff and text conversion helpers.

Export checks the saved patch against both digests. It refuses an active run,
a changed source snapshot, invalid records, symlinked inputs and an existing
output directory. It does not overwrite an earlier export.

Older panels without a saved diff cannot be exported. Run a new review of the
intended change. A fresh diff from today's branch would describe different
evidence, so the exporter does not reconstruct one. If neither `sha256sum` nor
`shasum` is installed, reviews can still run, but evidence export is unavailable.

## Publication is a separate step

The exporter copies selected review artifacts, not arbitrary files from the
run directory. It does not copy provider configuration or credential files.
Selected raw reviews, synthesis and diffs are preserved without redaction and
can contain private source code, paths or text supplied by a reviewer. Check
those contents before publishing. The command does not commit, push or upload
anything.

This format covers live review panels. It does not export keyed grading tables
or turn a delivery status into a quality score. `ok` means the harness received
usable review text. It does not establish that the findings are correct. See
[the dataset contract](DATASET.md) and [the assurance case](ASSURANCE_CASE.md).

## Verification

```bash
python3 tests/export-evidence.py
bash tests/evidence-capture.sh
```

The capture test applies the saved binary patch to its recorded base and checks
the reconstructed tree against the reviewed tree ID. It also checks full-target
and empty changes, then exports after moving the source branch. The exporter
fixtures test byte preservation, linked cells, missing evidence and refused
inputs. These tests use synthetic reviews and make no quality claim about a
model.
