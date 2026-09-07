import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class InputLockTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / "cadre"
        for name in ("bin", "lib", "agents.d", "templates"):
            shutil.copytree(ROOT / name, self.root / name)
        sdk = self.root / "integrations/pi-review"
        sdk.mkdir(parents=True)
        for name in ("cli.mjs", "review.mjs", "package.json", "package-lock.json"):
            shutil.copyfile(ROOT / "integrations/pi-review" / name, sdk / name)
        self.user = self.base / "adapters"
        self.user.mkdir()
        self.env = {"PATH": "/usr/bin:/bin", "HOME": str(self.base / "home"),
                    "CADRE_ROOT": str(self.root), "CADRE_HOME": str(self.base / "state"),
                    "CADRE_WORK": str(self.base / "work"), "CADRE_AGENTS_D": str(self.user),
                    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
                    "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
                    "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.invalid"}
        self.lock = self.root / "cadre.lock.json"

    def command(self, *args, ok=True):
        result = subprocess.run(args, env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def cadre(self, *args, **kwargs):
        return self.command(str(self.root / "bin/cadre"), *args, **kwargs)

    def update(self):
        self.cadre("lock", "--update")

    def test_roundtrip_and_provenance(self):
        self.update()
        original = self.lock.read_bytes()
        self.update()
        self.assertEqual(original, self.lock.read_bytes())
        lock = json.loads(original)
        entry = lock["files"]["root:agents.d/codex.sh"]
        entry.update(source="example/upstream", skillPath="adapters/codex.sh")
        self.lock.write_text(json.dumps(lock))
        self.update()
        self.assertEqual(json.loads(self.lock.read_text())["files"]["root:agents.d/codex.sh"], entry)
        self.cadre("selfcheck")

    def test_added_modified_and_deleted_inputs(self):
        self.update()
        for relative in ("agents.d/codex.sh", "lib/prompts/review.md",
                         "integrations/pi-review/review.mjs"):
            path = self.root / relative
            original = path.read_bytes()
            path.write_bytes(original + b"\n")
            self.assertIn("modified input: root:" + relative, self.cadre("selfcheck", ok=False).stderr)
            path.write_bytes(original)
        path = self.root / "agents.d/new.sh"
        path.write_text("# new adapter\n")
        self.assertIn("unlocked input", self.cadre("selfcheck", ok=False).stderr)
        self.update()
        path.unlink()
        self.assertIn("missing input", self.cadre("selfcheck", ok=False).stderr)

    def test_custom_inputs_and_namespaces(self):
        self.update()
        adapter = self.user / "odd name.sh"
        adapter.write_text("run_codex() { :; }\n")
        self.assertIn("user:odd name.sh", self.cadre("selfcheck", ok=False).stderr)
        custom = self.base / "custom prompt.md"
        custom.write_text("Review this exact change.\n")
        self.env["CADRE_PROMPT_FILE"] = str(custom)
        self.env["CADRE_LOCK_FILE"] = str(self.base / "custom.lock.json")
        self.update()
        self.cadre("selfcheck")
        custom.write_text("A different review.\n")
        self.assertIn("custom:review-prompt", self.cadre("selfcheck", ok=False).stderr)
        self.update()
        del self.env["CADRE_PROMPT_FILE"]
        self.assertIn("missing input: custom:review-prompt", self.cadre("selfcheck", ok=False).stderr)

    def test_bad_lock_does_not_become_success_or_get_overwritten(self):
        self.cadre("selfcheck", ok=False)
        self.update()
        original = self.lock.read_bytes()
        for data in ('{}', '{"schema":"cadre/input-lock@1","files":{}}',
                     '{"schema":"cadre/input-lock@1","schema":"cadre/input-lock@1"}',
                     '{"schema":"cadre/input-lock@1","files":{"x":{"computedHash":"bad"}}}'):
            self.lock.write_text(data)
            self.cadre("selfcheck", ok=False)
            self.cadre("lock", "--update", ok=False)
            self.assertEqual(self.lock.read_text(), data)
        self.lock.write_bytes(original)
        missing = self.base / "missing-prompt"
        self.env["CADRE_PROMPT_FILE"] = str(missing)
        self.cadre("lock", "--update", ok=False)
        self.assertEqual(self.lock.read_bytes(), original)

    def test_check_never_sources_modified_adapter(self):
        marker = self.base / "executed"
        adapter = self.user / "testseat.sh"
        adapter.write_text("run_testseat() { :; }\n")
        self.update()
        adapter.write_text("touch '" + str(marker) + "'\nrun_testseat() { :; }\n")
        self.cadre("selfcheck", ok=False)
        result = self.cadre("run", "testseat", "1", ok=False)
        self.assertIn("input lock check failed before dispatch", result.stderr)
        self.assertFalse(marker.exists())

    def prepare_pass(self):
        checkout = self.base / "checkout"
        checkout.mkdir()
        self.command("git", "-C", str(checkout), "init", "-q")
        for text in ("one\n", "two\n"):
            (checkout / "app.txt").write_text(text)
            self.command("git", "-C", str(checkout), "add", "app.txt")
            self.command("git", "-C", str(checkout), "commit", "-qm", "fixture")
        sha = self.command("git", "-C", str(checkout), "rev-parse", "--short", "HEAD").stdout.strip()
        self.env["CADRE_PASS_DIR"] = str(checkout)
        bin_dir = self.base / "bin"
        bin_dir.mkdir()
        cli = bin_dir / "testseat"
        cli.write_text("#!/bin/sh\nexit 0\n")
        cli.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + ":/usr/bin:/bin"
        (self.user / "testseat.sh").write_text(
            'run_testseat() { echo "Verdict: ship it"; '
            'if [ -n "${CADRE_LOCK_FILE:-}" ]; then echo "LOCK_PATH_LEAKED"; fi; }\n')
        self.env["CADRE_LOCK_FILE"] = str(self.base / "private.lock.json")
        self.update()
        return sha

    def test_dispatch_receipt_matches_existing_content_hashes(self):
        sha = self.prepare_pass()
        self.command("bash", str(self.root / "lib/run-pass.sh"), "p1", sha, "1", "testseat")
        events = [json.loads(line) for line in (self.base / "state/p1/runs.jsonl").read_text().splitlines()]
        completed = next(e for e in events if e["event"] == "complete")
        self.assertEqual(completed["adapter_sha"], completed["lock_adapter_sha"])
        self.assertEqual(completed["prompt_source_sha"], completed["lock_prompt_sha"])
        self.assertEqual(len(completed["lock_sha"]), 64)
        self.assertNotEqual(completed["prompt_sha"], completed["lock_prompt_sha"])
        self.assertEqual(events[0]["lock_sha"], completed["lock_sha"])
        review = next((self.base / "state/p1").glob("*.md"))
        self.assertNotIn("LOCK_PATH_LEAKED", review.read_text())

    def test_standalone_runner_refuses_drift_before_artifacts(self):
        sha = self.prepare_pass()
        (self.user / "late.sh").write_text("# newly loaded file\n")
        self.command("bash", str(self.root / "lib/run-pass.sh"), "p1", sha, "1", "testseat", ok=False)
        self.assertFalse((self.base / "state/p1").exists())

    def test_drift_between_runs_keeps_first_review_and_stops_second(self):
        sha = self.prepare_pass()
        adapter = self.user / "testseat.sh"
        adapter.write_text('run_testseat() { echo "Verdict: ship it"; printf "\\n# changed\\n" >> '
                           + "'" + str(adapter) + "'; }\n")
        self.update()
        result = self.command("bash", str(self.root / "lib/run-pass.sh"), "p1", sha, "2", "testseat", ok=False)
        self.assertIn("modified input: user:testseat.sh", result.stderr)
        reviews = list((self.base / "state/p1").glob("*.md"))
        self.assertEqual(len(reviews), 1)
        events = [json.loads(line) for line in (self.base / "state/p1/runs.jsonl").read_text().splitlines()]
        self.assertEqual([e["event"] for e in events], ["dispatch", "complete"])

    def test_promptless_receipt_does_not_claim_rendered_prompt(self):
        sha = self.prepare_pass()
        adapter = self.user / "testseat.sh"
        adapter.write_text(adapter.read_text() + "noprompt_testseat() { :; }\n")
        self.update()
        self.command("bash", str(self.root / "lib/run-pass.sh"), "p1", sha, "1", "testseat")
        events = [json.loads(line) for line in (self.base / "state/p1/runs.jsonl").read_text().splitlines()]
        self.assertEqual(events[-1]["prompt_sha"], "")
        self.assertEqual(events[-1]["prompt_bytes"], 0)

    def test_adapter_order_matches_bash_and_ignores_hidden_files(self):
        sha = self.prepare_pass()
        for name in ("A.sh", "a.sh", "z_.sh", "z-.sh"):
            (self.user / name).write_text("# _testseat( " + name + "\n")
        self.update()
        (self.user / ".unused.sh").write_text("# _testseat(\n")
        self.cadre("selfcheck")
        self.command("bash", str(self.root / "lib/run-pass.sh"), "p1", sha, "1", "testseat")
        locales = self.command("locale", "-a").stdout.lower().splitlines()
        if "en_us.utf8" in locales:
            self.env["LC_ALL"] = "en_US.utf8"
            self.update()
            self.command("bash", str(self.root / "lib/run-pass.sh"), "p2", sha, "1", "testseat")

    def test_direct_agentcall_does_not_export_private_lock_path(self):
        self.prepare_pass()
        (self.user / "testseat.sh").write_text("run_testseat() { testseat; }\n")
        cli = self.base / "bin/testseat"
        cli.write_text('#!/bin/sh\nprintf "%s\\n" "${CADRE_LOCK_FILE-unset}"\n')
        result = self.command(str(self.root / "bin/agentcall"), "testseat", "-d", str(self.base / "checkout"))
        self.assertEqual(result.stdout.strip(), "unset")


if __name__ == "__main__":
    unittest.main(verbosity=2)
