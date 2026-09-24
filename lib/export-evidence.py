#!/usr/bin/env python3
"""Export a completed live panel without reconstructing its reviewed content."""
import argparse
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile


STATES = {"ok": ".md", "degraded": ".md.partial", "failed": ".md.failed",
          "inconclusive": ".md.inconclusive", "skipped": None}
FIELDS = ("panel", "seat", "family", "state", "bytes", "secs", "prompt_bytes",
          "v", "prompt_sha", "adapter_sha", "harness_sha", "model")
NUMBERS = {"bytes", "secs", "prompt_bytes", "v"}
# The panel's own wall clock and its residual (#10). Only the residual may be
# negative: that is double counting or --jobs overlap, reported, never clamped.
PANEL_NUMBERS = {"jobs", "wall_secs", "prerun_secs", "seat_secs", "timed_seats",
                 "untimed_seats", "unattributed_secs", "est_tokens", "unattributed_tokens", "ts"}
SHARED = ("manifest.txt", "findings.json", "report.md", "synthesis.md",
          "synthesis.md.failed", "synthesis.md.partial", "synthesis.md.inconclusive")
NOTICE = ("Raw reviews, run records, the original manifest, and synthesis/report artifacts "
          "are preserved without redaction. They may contain private text or original paths. "
          "Only the named evidence artifacts are copied; configuration and authentication "
          "files are not included. States describe delivery, not review quality.")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def parse_json(data):
    def invalid(value):
        raise ValueError("invalid JSON number: " + value)
    return json.loads(data, object_pairs_hook=unique_object, parse_constant=invalid)


def markdown(value):
    # Entity-encode markup, including pipes, so labels cannot add links or cells.
    return "".join(c if c.isalnum() or c == " " else f"&#{ord(c)};" for c in value)


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size,
            info.st_mtime_ns, info.st_ctime_ns)


def no_symlink_components(path):
    for part in (path, *path.parents):
        if part.is_symlink():
            raise ValueError("symlink path components are not allowed")


class Source:
    def __init__(self, path):
        self.path = path
        no_symlink_components(path)
        if not path.is_dir():
            raise ValueError("review-dir must be a directory")
        self.directory = fingerprint(path.stat())
        self.entries = self.scan()
        self.files = {}

    def scan(self):
        entries = {}
        for path in self.path.iterdir():
            info = path.lstat()
            if stat.S_ISLNK(info.st_mode):
                raise ValueError("source symlinks are not allowed")
            if path.name in {".claim", ".claim.tmp"}:
                raise ValueError("review has an active or unreleased .claim; export a completed panel")
            entries[path.name] = fingerprint(info)
        return entries

    def read(self, name, required=False):
        if name not in self.entries:
            if required:
                raise ValueError("missing required evidence: " + name)
            return None
        if name in self.files:
            return self.files[name]
        info = self.entries[name]
        if not stat.S_ISREG(info[2]):
            raise ValueError("evidence must be a regular file: " + name)
        fd = os.open(self.path / name, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        with os.fdopen(fd, "rb") as stream:
            if fingerprint(os.fstat(stream.fileno())) != info:
                raise ValueError("source changed while exporting")
            data = stream.read()
            if fingerprint(os.fstat(stream.fileno())) != info:
                raise ValueError("source changed while exporting")
        self.files[name] = data
        return data

    def verify(self):
        no_symlink_components(self.path)
        if fingerprint(self.path.stat()) != self.directory or self.scan() != self.entries:
            raise ValueError("source changed while exporting")
        before = self.files.copy()
        self.files.clear()
        for name, data in before.items():
            if self.read(name) != data:
                raise ValueError("source changed while exporting")


def parse_manifest(data):
    result = {}
    for line in data.decode("utf-8").splitlines():
        if not line or ":" not in line:
            raise ValueError("malformed manifest.txt")
        key, value = line.split(":", 1)
        if not re.fullmatch(r"[a-z][a-z0-9-]*", key) or key in result:
            raise ValueError("malformed or duplicate manifest field")
        result[key] = value.strip()
    for key in ("base-tree", "reviewed-tree"):
        if not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", result.get(key, "")):
            raise ValueError("manifest needs a valid " + key + " content ID")
    if not re.fullmatch(r"[0-9a-f]{64}", result.get("diff-sha256", "")):
        raise ValueError("saved diff identity is missing; rerun cadre review with diff capture enabled")
    return result


def parse_slots(data):
    rows = {}
    panels = set()
    for raw in data.splitlines(keepends=True):
        values = raw.decode("utf-8").rstrip("\n").split("\t")
        if len(values) != len(FIELDS):
            raise ValueError("slots.tsv must contain 12 tab-separated columns without a header")
        row = dict(zip(FIELDS, values))
        for field, value in row.items():
            if any(ord(c) < 32 or ord(c) == 127 for c in value):
                raise ValueError("control character in slots.tsv")
            if field in NUMBERS:
                if value and not re.fullmatch(r"[0-9]+", value):
                    raise ValueError("invalid numeric slot field: " + field)
                row[field] = int(value) if value else None
            elif field.endswith("_sha") and value:
                if not re.fullmatch(r"(?:[0-9a-f]{12}|[0-9a-f]{40}|[0-9a-f]{64})", value):
                    raise ValueError("invalid slot hash: " + field)
        if not row["panel"] or not row["seat"] or row["state"] not in STATES:
            raise ValueError("invalid slot identity or state")
        if row["seat"] in rows:
            raise ValueError("duplicate slot record")
        rows[row["seat"]] = (row, raw)
        panels.add(row["panel"])
    if not rows or len(panels) != 1:
        raise ValueError("export requires one nonempty live panel")
    return rows


def seat_slug(seat):
    # POSIX cksum, matching common.sh without invoking a shell or provider CLI.
    data = seat.encode("utf-8")
    length = len(data)
    suffix = bytearray()
    while length:
        suffix.append(length & 255)
        length >>= 8
    crc = 0
    for byte in data + suffix:
        crc ^= byte << 24
        for _ in range(8):
            crc = ((crc << 1) ^ (0x04C11DB7 if crc & 0x80000000 else 0)) & 0xFFFFFFFF
    safe = re.sub(rb"[^A-Za-z0-9._-]", b"-", data).decode("ascii")
    return safe + "-" + str(crc ^ 0xFFFFFFFF)


def parse_events(data, rows):
    events = {seat: {} for seat in rows}
    raw_records = {seat: [] for seat in rows}
    panel_records = []
    task = next(iter(rows.values()))[0]["panel"] if rows else None
    for raw in (data or b"").splitlines(keepends=True):
        event = parse_json(raw)
        if (not isinstance(event, dict) or not isinstance(event.get("event"), str)
                or event["event"] not in {"dispatch", "complete", "roll_dispatch", "roll_complete", "panel"}):
            raise ValueError("malformed live run event")
        if event["event"] == "panel":
            # Belongs to no seat, so it is not split into a cell; it travels as
            # one shared record. A panel killed mid-flight never writes one.
            if panel_records:
                raise ValueError("duplicate panel event")
            if event.get("panel") != task:
                raise ValueError("panel event names a different panel")
            for field in PANEL_NUMBERS:
                value = event.get(field)
                if value is not None and (type(value) is not int
                                          or (value < 0 and field != "unattributed_secs")):
                    raise ValueError("invalid numeric panel field: " + field)
            # The residual is defined as wall minus its timed parts, with an
            # untimed part adding nothing (run-review.sh); a record where that
            # does not hold was not written by the harness.
            if event.get("wall_secs") is not None and event.get("unattributed_secs") is not None:
                if event["wall_secs"] != ((event.get("prerun_secs") or 0) + (event.get("seat_secs") or 0)
                                          + event["unattributed_secs"]):
                    raise ValueError("panel seconds do not reconcile")
            panel_records.append(raw)
            continue
        seat = event.get("seat")
        if not isinstance(seat, str) or seat not in rows:
            raise ValueError("run record names an unknown seat")
        kind = event["event"]
        row = rows[seat][0]
        if kind.startswith("roll_"):
            # One roll of a repeated seat. It is part of the seat's record and
            # travels with it, but it is not the seat's dispatch or completion:
            # those are the union's, recorded once, and slots.tsv describes them.
            if event.get("panel") != row["panel"]:
                raise ValueError("run record panel or slug does not match its slot")
            raw_records[seat].append(raw)
            continue
        if kind in events[seat]:
            raise ValueError("duplicate run event")
        if event.get("panel") != row["panel"] or event.get("slug") != seat_slug(seat):
            raise ValueError("run record panel or slug does not match its slot")
        if kind == "dispatch" and "complete" in events[seat]:
            raise ValueError("dispatch recorded after completion")
        for field in FIELDS:
            if field in event and event[field] != row[field]:
                raise ValueError("run record disagrees with slots.tsv: " + field)
            if field in event and field in NUMBERS and event[field] is not None:
                if type(event[field]) is not int or event[field] < 0:
                    raise ValueError("invalid numeric run field: " + field)
        if kind == "complete" and event.get("state") not in STATES:
            raise ValueError("completion is missing a valid state")
        events[seat][kind] = event
        raw_records[seat].append(raw)
    return events, {seat: b"".join(lines) for seat, lines in raw_records.items()}, b"".join(panel_records)


def publish(stage, destination):
    # os.rename can replace an empty directory created by another caller after
    # our existence check. Use the platform's atomic no-replace directory move.
    libc = ctypes.CDLL(None, use_errno=True)
    old, new = os.fsencode(stage), os.fsencode(destination)
    if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        call = libc.renameat2
        call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        rc = call(-100, old, -100, new, 1)  # AT_FDCWD, RENAME_NOREPLACE
    elif sys.platform == "darwin" and hasattr(libc, "renamex_np"):
        call = libc.renamex_np
        call.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rc = call(old, new, 4)  # RENAME_EXCL
    else:
        raise ValueError("atomic no-overwrite export requires Linux or macOS")
    if rc:
        code = ctypes.get_errno()
        if code in {errno.EEXIST, errno.ENOTEMPTY}:
            raise ValueError("output already exists; choose a new output directory")
        raise OSError(code, os.strerror(code))


def export(source_path, destination):
    no_symlink_components(Path(source_path))
    no_symlink_components(Path(destination))
    source_path = Path(os.path.abspath(source_path))
    destination = Path(os.path.abspath(destination))
    no_symlink_components(destination)
    if (source_path == destination or source_path in destination.parents
            or destination in source_path.parents):
        raise ValueError("source and output directories must not overlap")
    if destination.exists():
        raise ValueError("output already exists; choose a new output directory")
    if not destination.parent.is_dir():
        raise ValueError("output parent directory must already exist")
    parent_identity = fingerprint(destination.parent.stat())[:3]
    source = Source(source_path)
    # Never reconstruct old evidence from today's checkout.
    if "diff.patch" not in source.entries or "diff.sha256" not in source.entries:
        raise ValueError("saved diff.patch/diff.sha256 is missing; rerun cadre review with diff capture enabled")
    manifest = parse_manifest(source.read("manifest.txt", required=True))
    patch = source.read("diff.patch", required=True)
    patch_sha = digest(patch)
    recorded_sha = source.read("diff.sha256", required=True).decode("ascii").strip()
    if recorded_sha != patch_sha or manifest["diff-sha256"] != patch_sha:
        raise ValueError("saved diff SHA256 mismatch; evidence is inconsistent")
    rows = parse_slots(source.read("slots.tsv", required=True))
    if len({seat_slug(seat) for seat in rows}) != len(rows):
        raise ValueError("seat slugs collide; source artifact ownership is ambiguous")
    events, records, panel_record = parse_events(source.read("runs.jsonl"), rows)
    shared = {name: source.read(name) for name in SHARED if name in source.entries}
    if "findings.json" in shared:
        findings = parse_json(shared["findings.json"])
        if not isinstance(findings, dict) or findings.get("schema") != "cadre/findings@1":
            raise ValueError("malformed findings.json")
        target = findings.get("target")
        if not isinstance(target, dict) or any(target.get(key.replace("-", "_")) != manifest[key]
                                               for key in ("base-tree", "reviewed-tree")):
            raise ValueError("findings.json disagrees with manifest tree IDs")
    task = next(iter(rows.values()))[0]["panel"]
    target = {key.replace("-", "_"): manifest[key]
              for key in ("base-tree", "reviewed-tree", "diff-sha256")}
    inventory = {}
    source_locations = {}
    cells = []
    stage = Path(tempfile.mkdtemp(prefix=".cadre-evidence-", dir=destination.parent))
    try:
        def write(name, data, source_name=None):
            data = data.encode("utf-8") if isinstance(data, str) else data
            path = stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as stream:
                stream.write(data)
            inventory[name] = {"sha256": digest(data), "bytes": len(data)}
            if source_name is not None:
                source_locations.setdefault(source_name, []).append(name)

        def write_json(name, value):
            write(name, json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n")

        for name, data in shared.items():
            write("shared/" + name, data, name)
        if panel_record:
            write("shared/panel.jsonl", panel_record, "runs.jsonl")
        for seat, (row, raw_slot) in rows.items():
            cell = "cells/" + digest(json.dumps([task, seat], ensure_ascii=True).encode("ascii"))
            missing = [field for field in ("secs", "bytes", "prompt_bytes") if row[field] is None]
            missing.append("tokens")  # Byte counts are not measured token usage.
            for kind in ("dispatch", "complete"):
                if kind not in events[seat] and not (kind == "dispatch" and row["state"] == "skipped"):
                    missing.append(kind + "_event")
            if "runs.jsonl" not in source.entries:
                missing.append("runs.jsonl")
            for name in ("findings.json", "report.md"):
                if name not in shared:
                    missing.append(name)
            synthesis = [name for name in shared if name.startswith("synthesis.md")]
            if not synthesis:
                missing.append("synthesis")
            slug = seat_slug(seat)
            artifacts = []
            for suffix in (".md", ".md.partial", ".md.failed", ".md.inconclusive"):
                data = source.read(slug + suffix)
                if data is not None:
                    name = "review" + suffix
                    write(cell + "/" + name, data, slug + suffix)
                    artifacts.append(name)
            # A repeated seat's union points at its rolls by name ("see
            # <slug>.r1.md.failed"), so the rolls travel in the same cell.
            roll_names = sorted(name for name in source.entries
                                if re.fullmatch(re.escape(slug) + r"\.r\d+\.md(\.partial|\.failed|\.inconclusive)?", name))
            for name in roll_names:
                roll = name[len(slug) + 1:]
                write(cell + "/rolls/" + roll, source.read(name), name)
            expected = STATES[row["state"]]
            if expected and "review" + expected not in artifacts:
                missing.append("review" + expected)
            elif expected and row["bytes"] is not None:
                if len(source.read(slug + expected)) != row["bytes"]:
                    raise ValueError("review artifact byte count disagrees with slots.tsv")
            write(cell + "/diff.patch", patch, "diff.patch")
            write(cell + "/diff.sha256", source.read("diff.sha256"), "diff.sha256")
            write(cell + "/slots.tsv", raw_slot, "slots.tsv")
            if records[seat]:
                write(cell + "/runs.jsonl", records[seat], "runs.jsonl")
            receipt = {"schema": "cadre/evidence-receipt@1", "task": task,
                       "seat": seat, "family": row["family"], "state": row["state"],
                       "target": target, "measurements": {"secs": row["secs"],
                           "review_bytes": row["bytes"], "prompt_bytes": row["prompt_bytes"], "tokens": None},
                       "provenance": {key: row[key] for key in
                           ("v", "prompt_sha", "adapter_sha", "harness_sha", "model")},
                       "missing": missing,
                       "artifacts": {name[len(cell) + 1:]: info for name, info in inventory.items()
                                     if name.startswith(cell + "/")},
                       "shared_artifacts": {"../../" + name: inventory[name] for name in inventory
                                            if name.startswith("shared/")}}
            write_json(cell + "/receipt.json", receipt)
            secs = "unmeasured" if row["secs"] is None else str(row["secs"])
            links = ["[Full reviewed diff](diff.patch)", "[Diff SHA256](diff.sha256)",
                     "[Receipt](receipt.json)", "[Original slot row](slots.tsv)"]
            if records[seat]:
                links.append("[Original run events](runs.jsonl)")
            links.extend(f"[{name}]({name})" for name in artifacts)
            links.extend(f"[{name}](../../shared/{name})" for name in shared)
            write(cell + "/README.md", f"# {markdown(seat)}\n\nTask: {markdown(task)}\n\n"
                  f"State: **{row['state']}**. Measured seconds: {secs}. Measured tokens: unmeasured.\n\n"
                  + NOTICE + "\n\n" + "\n".join("- " + link for link in links)
                  + "\n\nMissing or unmeasured: " + ", ".join(markdown(item) for item in missing) + ".\n"
                  + ("\nNo raw review artifact is present.\n" if not artifacts else ""))
            cells.append({"seat": seat, "task": task, "state": row["state"], "directory": cell})
        write("README.md", "# Cadre offline evidence\n\n" + NOTICE
              + "\n\nEvery cell includes the full saved binary diff. Missing evidence stays explicit; "
              "tokens are unmeasured because these receipts record bytes, not token usage. "
              "[manifest.json](manifest.json) inventories every exported file except itself by SHA256. "
              "Its source_locations maps original artifact filenames, including findings.json source references, "
              "to exported paths. runs.jsonl and slots.tsv are per-seat projections preserving original records.\n\n"
              + "| Seat | " + markdown(task) + " |\n| --- | --- |\n"
              + "".join(f"| {markdown(cell['seat'])} | [{cell['state']}]({cell['directory']}/) |\n"
                        for cell in cells))
        write_json("manifest.json", {"schema": "cadre/evidence-export@1", "task": task,
                   "target": target, "cells": cells, "source_locations": source_locations, "source_artifacts": {
                       name: {"sha256": digest(data), "bytes": len(data)}
                       for name, data in source.files.items()}, "artifacts": dict(inventory)})
        source.verify()
        no_symlink_components(destination)
        if fingerprint(destination.parent.stat())[:3] != parent_identity:
            raise ValueError("output parent changed while exporting")
        publish(stage, destination)
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("review_dir")
    parser.add_argument("new_out_dir")
    args = parser.parse_args()
    try:
        export(args.review_dir, args.new_out_dir)
    except (OSError, ValueError, UnicodeError) as error:
        print("cadre export-evidence: " + str(error), file=sys.stderr)
        return 2
    print("Exported offline evidence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
