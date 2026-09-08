"""Offline evidence export: integrity, missing measurements, and filesystem safety."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("export_evidence", ROOT / "lib/export-evidence.py")
EXPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EXPORT)
SLUGS = {"alpha": "alpha-328085594", "beta": "beta-67507236",
         "broken": "broken-1200683011", "unclear": "unclear-3816757414",
         "skip": "skip-543254895", "missing": "missing-4100588414",
         "vendor/model": "vendor-model-3980496318", "vendor-model": "vendor-model-1945066908",
         "seat|[x](https://example.invalid)<b>": "seat--x--https---example.invalid--b--1866264149"}
STATES = {"alpha": "ok", "beta": "degraded", "broken": "failed", "unclear": "inconclusive",
          "skip": "skipped", "missing": "failed"}
SUFFIXES = {"ok": ".md", "degraded": ".md.partial", "failed": ".md.failed",
            "inconclusive": ".md.inconclusive"}


def make_panel(directory, seats=("alpha", "beta", "broken", "unclear", "skip", "missing")):
    """Create a public-safe synthetic panel, including an actual binary git diff."""
    directory = Path(directory)
    directory.mkdir()
    with tempfile.TemporaryDirectory() as temp:
        repo = Path(temp)
        env = {"PATH": "/usr/bin:/bin", "HOME": temp, "GIT_CONFIG_GLOBAL": "/dev/null",
               "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Synthetic fixture",
               "GIT_AUTHOR_EMAIL": "fixture@example.invalid", "GIT_COMMITTER_NAME": "Synthetic fixture",
               "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}

        def git(*args):
            return subprocess.run(["git", "-C", temp, *args], env=env, check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

        git("init", "-q")
        (repo / "image.bin").write_bytes(bytes(range(256)))
        (repo / "app.txt").write_text("before\n")
        git("add", "image.bin", "app.txt")
        git("commit", "-qm", "synthetic base")
        base_tree = git("rev-parse", "HEAD^{tree}").decode().strip()
        (repo / "image.bin").write_bytes(bytes(reversed(range(256))))
        (repo / "app.txt").write_text("after\n" + "".join(f"line {i}\n" for i in range(300)))
        git("add", "image.bin", "app.txt")
        reviewed_tree = git("write-tree").decode().strip()
        diff = git("diff", "--binary", "--full-index", "--cached", "HEAD")
    sha = hashlib.sha256(diff).hexdigest()
    (directory / "diff.patch").write_bytes(diff)
    (directory / "diff.sha256").write_text(sha + "\n")
    (directory / "manifest.txt").write_text(
        "mode: diff\ntarget: synthetic-example\nbase-tree: " + base_tree
        + "\nreviewed-tree: " + reviewed_tree + "\ndiff-sha256: " + sha
        + "\nroster: " + " ".join(seats) + "\nharness: " + "c" * 12 + "\n")
    rows, events = [], []
    for seat in seats:
        state = STATES.get(seat, "ok")
        raw = ("Synthetic " + state + " output.\n" + "Full artifact line.\n" * 100).encode()
        absent = seat in {"skip", "missing"}
        row = {"panel": "synthetic-task", "seat": seat, "family": "fixture", "state": state,
               "bytes": 0 if absent else len(raw), "secs": None if absent else 7,
               "prompt_bytes": None if seat == "missing" else 0 if seat == "skip" else 2048,
               "v": 2, "prompt_sha": "" if absent else "a" * 12,
               "adapter_sha": "b" * 12, "harness_sha": "c" * 12, "model": ""}
        rows.append("\t".join("" if row[key] is None else str(row[key]) for key in EXPORT.FIELDS) + "\n")
        if not absent:
            (directory / (SLUGS[seat] + SUFFIXES[state])).write_bytes(raw)
        if seat != "skip":
            events.append({"event": "dispatch", "panel": row["panel"], "seat": seat,
                           "family": "fixture", "slug": SLUGS[seat], "ts": 100})
        if seat != "missing":
            events.append({"event": "complete", **row, "slug": SLUGS[seat], "rc": None if absent else 0,
                           "adapter_attempts": None, "adapter_note": "", "language": "", "ts": 107})
    (directory / "slots.tsv").write_text("".join(rows))
    # Whitespace is intentional: exports must preserve original record bytes.
    (directory / "runs.jsonl").write_text("".join(json.dumps(event, separators=(", ", ": ")) + "\n"
                                                    for event in events))
    (directory / "findings.json").write_text(json.dumps({"schema": "cadre/findings@1",
        "target": {"base_tree": base_tree, "reviewed_tree": reviewed_tree}, "panel": [],
        "synthesis": {"status": "failed", "agent": "fixture"}, "verify": {"ran": False},
        "claims": [], "findings": []}) + "\n")
    (directory / "synthesis.md.failed").write_text("Synthetic synthesis failed; no merged verdict.\n")
    (directory / "report.md").write_text("# Synthetic panel\n\nDelivery evidence only.\n")
    return directory


class EvidenceExportTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.source = make_panel(self.base / "panel")
        self.out = self.base / "export"

    def export(self):
        EXPORT.export(self.source, self.out)
        return json.loads((self.out / "manifest.json").read_text())

    def cells(self, manifest):
        return {cell["seat"]: self.out / cell["directory"] for cell in manifest["cells"]}

    def reject(self, phrase):
        with self.assertRaisesRegex((ValueError, OSError), phrase):
            EXPORT.export(self.source, self.out)
        self.assertFalse(self.out.exists())
        self.assertEqual(list(self.base.glob(".cadre-evidence-*")), [])

    def test_full_bytes_links_inventory_and_records(self):
        original_diff = (self.source / "diff.patch").read_bytes()
        self.assertIn(b"GIT binary patch", original_diff)
        self.assertIn(b"+line 299", original_diff)
        manifest = self.export()
        files = {p.relative_to(self.out).as_posix() for p in self.out.rglob("*") if p.is_file()}
        self.assertEqual(files - {"manifest.json"}, set(manifest["artifacts"]))
        for name, info in manifest["artifacts"].items():
            data = (self.out / name).read_bytes()
            self.assertEqual(info, {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)})
        for seat, cell in self.cells(manifest).items():
            self.assertEqual((cell / "diff.patch").read_bytes(), original_diff)
            source_records = (self.source / "runs.jsonl").read_bytes().splitlines(keepends=True)
            self.assertEqual((cell / "runs.jsonl").read_bytes(),
                             b"".join(line for line in source_records if json.loads(line)["seat"] == seat))
            state = STATES[seat]
            if seat not in {"skip", "missing"}:
                self.assertEqual((cell / ("review" + SUFFIXES[state])).read_bytes(),
                                 (self.source / (SLUGS[seat] + SUFFIXES[state])).read_bytes())
        for readme in self.out.rglob("README.md"):
            for link in re.findall(r"\]\(([^)]+)\)", readme.read_text()):
                linked = (readme.parent / link).resolve()
                self.assertTrue(linked.exists(), link)
                self.assertTrue(linked.is_relative_to(self.out))
        self.assertEqual((self.out / "shared/synthesis.md.failed").read_bytes(),
                         (self.source / "synthesis.md.failed").read_bytes())

    def test_raw_findings_sources_resolve_through_manifest_mapping(self):
        path = self.source / "findings.json"
        findings = json.loads(path.read_text())
        references = [SLUGS["alpha"] + ".md", SLUGS["beta"] + ".md.partial", "synthesis.md.failed"]
        findings["claims"] = [{"source": {"file": name}} for name in references]
        original = (json.dumps(findings, indent=3) + "\n").encode()
        path.write_bytes(original)
        manifest = self.export()
        locations = manifest["source_locations"]
        self.assertEqual((self.out / "shared/findings.json").read_bytes(), original)
        for claim in json.loads((self.out / "shared/findings.json").read_bytes())["claims"]:
            name = claim["source"]["file"]
            self.assertEqual(len(locations[name]), 1)
            self.assertEqual((self.out / locations[name][0]).read_bytes(), (self.source / name).read_bytes())
        for name in ("diff.patch", "diff.sha256", "runs.jsonl", "slots.tsv"):
            self.assertEqual(len(locations[name]), len(manifest["cells"]))
        for name, exported_paths in locations.items():
            self.assertTrue((self.source / name).is_file())
            for exported_path in exported_paths:
                self.assertIn(exported_path, manifest["artifacts"])
                if name not in {"runs.jsonl", "slots.tsv"}:
                    self.assertEqual((self.out / exported_path).read_bytes(), (self.source / name).read_bytes())
        self.assertIn("per-seat projections", (self.out / "README.md").read_text())

    def test_missing_and_null_are_preserved(self):
        for name in ("findings.json", "report.md", "synthesis.md.failed"):
            (self.source / name).unlink()
        manifest = self.export()
        cells = self.cells(manifest)
        missing = json.loads((cells["missing"] / "receipt.json").read_text())
        self.assertEqual(missing["state"], "failed")
        self.assertIsNone(missing["measurements"]["secs"])
        self.assertIsNone(missing["measurements"]["prompt_bytes"])
        self.assertIsNone(missing["measurements"]["tokens"])
        self.assertTrue({"complete_event", "review.md.failed", "synthesis", "findings.json", "report.md"}
                        <= set(missing["missing"]))
        skipped = json.loads((cells["skip"] / "receipt.json").read_text())
        self.assertEqual(skipped["state"], "skipped")
        self.assertEqual(skipped["measurements"]["prompt_bytes"], 0)
        self.assertIsNone(skipped["measurements"]["secs"])
        self.assertNotIn("dispatch_event", skipped["missing"])
        self.assertIn("unmeasured", (cells["missing"] / "README.md").read_text())

    def test_missing_run_log_is_a_gap(self):
        (self.source / "runs.jsonl").unlink()
        manifest = self.export()
        cell = self.cells(manifest)["alpha"]
        self.assertIn("runs.jsonl", json.loads((cell / "receipt.json").read_text())["missing"])
        self.assertFalse((cell / "runs.jsonl").exists())

    def test_zero_byte_failed_artifact_survives(self):
        path = self.source / (SLUGS["broken"] + ".md.failed")
        old_size = len(path.read_bytes())
        path.write_bytes(b"")
        text = (self.source / "slots.tsv").read_text()
        (self.source / "slots.tsv").write_text(text.replace(f"broken\tfixture\tfailed\t{old_size}\t",
                                                          "broken\tfixture\tfailed\t0\t"))
        events = [json.loads(line) for line in (self.source / "runs.jsonl").read_text().splitlines()]
        for event in events:
            if event["seat"] == "broken" and event["event"] == "complete":
                event["bytes"] = 0
        (self.source / "runs.jsonl").write_text("".join(json.dumps(e) + "\n" for e in events))
        cell = self.cells(self.export())["broken"]
        self.assertEqual((cell / "review.md.failed").read_bytes(), b"")

    def test_empty_patch(self):
        old_sha = (self.source / "diff.sha256").read_text().strip()
        sha = hashlib.sha256(b"").hexdigest()
        (self.source / "diff.patch").write_bytes(b"")
        (self.source / "diff.sha256").write_text(sha + "\n")
        path = self.source / "manifest.txt"
        path.write_text(path.read_text().replace(old_sha, sha))
        self.export()

    def test_legacy_requires_rerun(self):
        (self.source / "diff.patch").unlink()
        self.reject("rerun cadre review")

    def test_patch_and_digest_tamper(self):
        for name, replacement in (("diff.patch", b"truncated"), ("diff.sha256", b"0" * 64)):
            with self.subTest(name=name):
                path = self.source / name
                original = path.read_bytes()
                path.write_bytes(replacement)
                self.reject("SHA256 mismatch")
                path.write_bytes(original)

    def test_manifest_and_findings_identity(self):
        path = self.source / "manifest.txt"
        original = path.read_text()
        for data, message in ((original + "base-tree: " + "a" * 40 + "\n", "duplicate"),
                              (re.sub(r"base-tree: [a-f0-9]+", "base-tree: unknown", original), "base-tree")):
            path.write_text(data)
            self.reject(message)
        path.write_text(original)
        findings = self.source / "findings.json"
        obj = json.loads(findings.read_text())
        obj["target"]["reviewed_tree"] = "f" * 40
        findings.write_text(json.dumps(obj))
        self.reject("disagrees")

    def test_malformed_duplicate_and_inconsistent_records(self):
        path = self.source / "runs.jsonl"
        original = path.read_bytes()
        first = original.splitlines(keepends=True)[0]
        variants = [(original + first, "duplicate run event"), (original + b"{bad}\n", "property name"),
                    (b'{"event": []}\n', "malformed live run event"),
                    (original.replace(b'"secs": 7', b'"secs": null', 1), "disagrees"),
                    (original.replace(b'"state": "ok"', b'"state": "failed"', 1), "disagrees"),
                    (original.replace(b'"event": "dispatch"', b'"event": "dispatch", "event": "dispatch"', 1),
                     "duplicate JSON")]
        for data, message in variants:
            with self.subTest(message=message):
                path.write_bytes(data)
                self.reject(message)
        path.write_bytes(original)
        slots = self.source / "slots.tsv"
        slots.write_bytes(slots.read_bytes() + slots.read_bytes().splitlines(keepends=True)[0])
        self.reject("duplicate slot")

    def test_review_byte_count_mismatch(self):
        (self.source / (SLUGS["alpha"] + ".md")).write_text("tampered\n")
        self.reject("byte count disagrees")

    def test_slug_traversal_refused(self):
        path = self.source / "runs.jsonl"
        path.write_text(path.read_text().replace(SLUGS["alpha"], "../../outside"))
        self.reject("slug")

    def test_colliding_labels_and_markdown_do_not_create_paths_or_links(self):
        source = self.base / "labels"
        seats = ("vendor/model", "vendor-model", "seat|[x](https://example.invalid)<b>")
        self.source = make_panel(source, seats)
        manifest = self.export()
        self.assertEqual(len(set(cell["directory"] for cell in manifest["cells"])), 3)
        for cell in manifest["cells"]:
            self.assertRegex(cell["directory"], r"^cells/[a-f0-9]{64}$")
        readme = (self.out / "README.md").read_text()
        self.assertNotIn("https://", readme)
        self.assertNotIn("<b>", readme)
        self.assertIn("&#124;", readme)
        self.assertEqual(len(re.findall(r"\]\(([^)]+)\)", readme)), 4)

    def test_symlinks_claim_and_overlap(self):
        link = self.base / "source-link"
        link.symlink_to(self.source, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            EXPORT.export(link, self.out)
        artifact = self.source / (SLUGS["alpha"] + ".md")
        data = artifact.read_bytes()
        artifact.unlink()
        artifact.symlink_to(self.source / "report.md")
        self.reject("symlink")
        artifact.unlink()
        artifact.write_bytes(data)
        (self.source / ".claim").write_text("123\nfixture-host\n100\n")
        self.reject(".claim")
        (self.source / ".claim").unlink()
        for destination in (self.source, self.source / "nested", self.base):
            with self.assertRaisesRegex(ValueError, "overlap"):
                EXPORT.export(self.source, destination)
        parent_link = self.base / "parent-link"
        parent_link.symlink_to(self.base, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink"):
            EXPORT.export(self.source, parent_link / "export")

    def test_no_overwrite_and_atomic_destination_race(self):
        self.out.mkdir()
        with self.assertRaisesRegex(ValueError, "already exists"):
            EXPORT.export(self.source, self.out)
        self.out.rmdir()
        real_publish = EXPORT.publish

        def racing_publish(stage, destination):
            destination.mkdir()
            real_publish(stage, destination)

        with patch.object(EXPORT, "publish", racing_publish):
            with self.assertRaisesRegex(ValueError, "already exists"):
                EXPORT.export(self.source, self.out)
        self.assertEqual(list(self.out.iterdir()), [])
        self.assertEqual(list(self.base.glob(".cadre-evidence-*")), [])

    def test_source_mutation_during_export_cleans_staging(self):
        original_verify = EXPORT.Source.verify

        def changed(source):
            (self.source / "report.md").write_text("changed during export\n")
            original_verify(source)

        with patch.object(EXPORT.Source, "verify", changed):
            self.reject("source changed")

    def test_allowlist_and_generated_metadata_do_not_expose_source_path(self):
        for name in (".env", "auth.json", "config.toml", "prompt.txt", "unrelated.md"):
            (self.source / name).write_text("PRIVATE_UNSELECTED_CONTENT\n")
        nested = self.source / "config"
        nested.mkdir()
        (nested / "private").write_text("PRIVATE_NESTED_CONTENT")
        manifest = self.export()
        for path in self.out.rglob("*"):
            if path.is_file():
                self.assertNotIn(b"PRIVATE_UNSELECTED_CONTENT", path.read_bytes())
                self.assertNotIn(b"PRIVATE_NESTED_CONTENT", path.read_bytes())
        for path in [self.out / "manifest.json", *self.out.rglob("receipt.json")]:
            self.assertNotIn(str(self.source), path.read_text())
        self.assertNotIn(".env", manifest["source_artifacts"])
        self.assertIn("without redaction", (self.out / "README.md").read_text())

    def test_cli_error_is_actionable_without_traceback(self):
        (self.source / "diff.patch").unlink()
        result = subprocess.run([sys.executable, str(ROOT / "lib/export-evidence.py"),
                                 str(self.source), str(self.out)], text=True, capture_output=True,
                                env={"PATH": "/usr/bin:/bin", "HOME": str(self.base)})
        self.assertEqual(result.returncode, 2)
        self.assertIn("rerun cadre review", result.stderr)
        self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
