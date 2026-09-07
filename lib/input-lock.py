#!/usr/bin/env python3
"""Pin review inputs before dispatch. This is a drift check, not a sandbox."""
import argparse
import hashlib
import json
import locale
import os
from pathlib import Path
import sys
import tempfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def content_sha(keys, entries):
    # Same ordered per-file digest contract as common.sh, including duplicates.
    return digest("".join(entries[key]["computedHash"] for key in keys).encode())[:12]


def adapter_paths(directory):
    # Match Bash's *.sh expansion, including the locale and equal-collation tie.
    return sorted((p for p in directory.glob("*.sh") if not p.name.startswith(".")),
                  key=lambda p: (locale.strxfrm(str(p)), os.fsencode(p)))


def inventory(root, user, prompt):
    files = {}
    for path in adapter_paths(root / "agents.d"):
        files["root:" + path.relative_to(root).as_posix()] = path
    for path in sorted((root / "lib/prompts").rglob("*.md")):
        files["root:" + path.relative_to(root).as_posix()] = path
    for name in ("cli.mjs", "review.mjs", "package.json", "package-lock.json"):
        path = root / "integrations/pi-review" / name
        files["root:" + path.relative_to(root).as_posix()] = path
    for path in adapter_paths(user):
        files["user:" + path.name] = path
    if prompt:
        files["custom:review-prompt"] = prompt
    if not any(k.startswith("root:agents.d/") for k in files):
        raise ValueError("no shipped adapters found")
    if not any(k.startswith("root:lib/prompts/") for k in files):
        raise ValueError("no shipped prompts found")
    return files


def read_lock(path):
    def unique(pairs):
        obj = {}
        for key, value in pairs:
            if key in obj:
                raise ValueError("duplicate lock key: " + key)
            obj[key] = value
        return obj

    lock = json.loads(path.read_text(), object_pairs_hook=unique)
    if not isinstance(lock, dict) or lock.get("schema") != "cadre/input-lock@1":
        raise ValueError("unsupported input lock schema")
    entries = lock.get("files")
    if not isinstance(entries, dict) or not entries:
        raise ValueError("lock must contain a nonempty files object")
    for key, entry in entries.items():
        if not isinstance(entry, dict):
            raise ValueError("invalid lock entry: " + key)
        sha = entry.get("computedHash")
        if not isinstance(sha, str) or len(sha) != 64 or any(c not in "0123456789abcdef" for c in sha):
            raise ValueError("invalid computedHash: " + key)
        for field in ("source", "skillPath"):
            if field in entry and (not isinstance(entry[field], str) or not entry[field].strip()):
                raise ValueError("invalid " + field + ": " + key)
    return lock


def snapshot(files, previous):
    entries = {}
    for key, path in sorted(files.items()):
        old = previous.get(key, {})
        entries[key] = {field: old[field] for field in ("source", "skillPath") if field in old}
        entries[key]["computedHash"] = digest(path.read_bytes())
    return {"schema": "cadre/input-lock@1", "files": entries}


def write_lock(path, lock):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".cadre-lock-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as out:
            json.dump(lock, out, indent=2, sort_keys=True)
            out.write("\n")
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def receipt(root, user, prompt, agent, lock_path, entries):
    keys = []
    for prefix, directory in (("root:agents.d/", root / "agents.d"), ("user:", user)):
        for path in adapter_paths(directory):
            if path.name == agent + ".sh" or ("_" + agent + "(").encode() in path.read_bytes():
                keys.append(prefix + path.name)
    if agent == "pireview":
        keys.extend("root:integrations/pi-review/" + name for name in
                    ("cli.mjs", "review.mjs", "package.json", "package-lock.json"))
    if not keys:
        raise ValueError("no locked adapter files for " + agent)
    return {"lock_sha": digest(lock_path.read_bytes()),
            "lock_adapter_sha": content_sha(keys, entries),
            "lock_prompt_sha": content_sha(
                ["custom:review-prompt" if prompt else "root:lib/prompts/review.md"], entries)}


def main():
    locale.setlocale(locale.LC_COLLATE, "")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("update", "check"))
    parser.add_argument("--agent", help="print a JSON receipt after checking")
    args = parser.parse_args()
    root = Path(os.environ["CADRE_ROOT"])
    home = Path(os.environ["CADRE_HOME"])
    user = Path(os.environ.get("CADRE_AGENTS_D", str(home / "agents.d")))
    prompt = Path(os.environ["CADRE_PROMPT_FILE"]) if os.environ.get("CADRE_PROMPT_FILE") else None
    lock_path = Path(os.environ.get("CADRE_LOCK_FILE", str(root / "cadre.lock.json")))
    files = inventory(root, user, prompt)
    if args.action == "update":
        old = read_lock(lock_path)["files"] if lock_path.exists() else {}
        write_lock(lock_path, snapshot(files, old))
        print("Updated input lock: " + str(lock_path))
        return 0
    expected = read_lock(lock_path)
    actual = snapshot(files, {})
    problems = []
    for key in sorted(expected["files"].keys() | actual["files"].keys()):
        if key not in expected["files"]:
            problems.append("unlocked input: " + key)
        elif key not in actual["files"]:
            problems.append("missing input: " + key)
        elif expected["files"][key]["computedHash"] != actual["files"][key]["computedHash"]:
            problems.append("modified input: " + key)
    if problems:
        for problem in problems:
            print("cadre: " + problem, file=sys.stderr)
        print("Review the changes, then run cadre lock --update with the same environment.", file=sys.stderr)
        return 1
    if args.agent:
        print(json.dumps(receipt(root, user, prompt, args.agent, lock_path, expected["files"]), sort_keys=True))
    else:
        print("Input lock matches (" + str(len(files)) + " files).")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError) as exc:
        print("cadre: input lock: " + str(exc), file=sys.stderr)
        sys.exit(2)
