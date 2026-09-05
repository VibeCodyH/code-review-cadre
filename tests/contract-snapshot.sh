#!/usr/bin/env bash
# Synthetic captures only. This command never needs adapters, credentials or network.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export CADRE_ROOT="$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export CADRE_HOME="$TMP/state" CADRE_WORK="$TMP/work"
python3 - "$ROOT" "$TMP" <<'PY'
import copy
import json
import pathlib
import subprocess
import sys

root, tmp = map(pathlib.Path, sys.argv[1:])
fixtures = root / "tests/fixtures/contract-snapshot"
base = json.loads((fixtures / "openai.json").read_text())
anthropic = json.loads((fixtures / "anthropic.json").read_text())
count = 0


def run(value, code=0, baseline=None, raw=False, error=None):
    global count
    count += 1
    path = tmp / "response.json"
    path.write_text(value if raw else json.dumps(value))
    command = [str(root / "bin/cadre"), "contract-snapshot", str(path)]
    if baseline is not None:
        saved = tmp / "baseline.json"
        saved.write_text(json.dumps(baseline))
        command += ["--compare", str(saved)]
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == code, (count, result.returncode, result.stdout, result.stderr)
    assert not result.stderr, (count, result.stderr)
    parsed = json.loads(result.stdout)
    assert "SECRET-ARGUMENT-VALUE" not in result.stdout
    if error:
        assert parsed["error"] == error, (count, parsed)
    if code == 1:
        assert parsed["status"] == "mismatch" and parsed["differences"], parsed
        assert set(parsed) == {"kind", "version", "status", "differences"}
    return parsed


saved = run(base)
assert saved == {
    "kind": "ContractSnapshot", "version": 1, "provider": "openai-chat-completions",
    "choices": [{"index": 0, "finish_reason": "tool_call", "tool_call_count": 2, "tool_calls": [
        {"name": "inspect", "argument_encoding": "string", "argument_keys": ["path"]},
        {"name": "lookup", "argument_encoding": "string", "argument_keys": ["limit", "query"]},
    ]}],
}
assert run((fixtures / "openai-equivalent.json").read_text(), baseline=saved, raw=True)["status"] == "match"
assert run(json.dumps(base, indent=4), raw=True) == saved

# Every observed contract dimension can cause a mismatch.
for field in ("keys", "encoding", "name", "arity", "finish", "choices", "index"):
    changed = copy.deepcopy(base)
    c = changed["choices"][0]
    calls = c["message"]["tool_calls"]
    if field == "keys":
        calls[0]["function"]["arguments"] = '{"different":"SECRET-ARGUMENT-VALUE"}'
    elif field == "encoding":
        calls[0]["function"]["arguments"] = {"query": "SECRET-ARGUMENT-VALUE", "limit": 2}
    elif field == "name":
        calls[0]["function"]["name"] = "other_tool"
    elif field == "arity":
        calls.append(copy.deepcopy(calls[0]))
    elif field == "finish":
        c["finish_reason"] = "length"
    elif field == "choices":
        changed["choices"].append(copy.deepcopy(c))
        changed["choices"][1]["index"] = 1
    elif field == "index":
        c["index"] = 2
    run(changed, 1, saved)

# Choice and parallel-call list order are immaterial; multiplicity is retained.
multi = copy.deepcopy(base)
multi["choices"].append(copy.deepcopy(multi["choices"][0]))
multi["choices"][1]["index"] = 1
multi_saved = run(multi)
multi["choices"].reverse()
assert run(multi, baseline=multi_saved)["status"] == "match"
unsorted = copy.deepcopy(saved)
unsorted["choices"][0]["tool_calls"].reverse()
unsorted["choices"][0]["tool_calls"][0]["argument_keys"].reverse()
assert run(base, baseline=unsorted)["status"] == "match"

anth_saved = run(anthropic)
assert anth_saved["provider"] == "anthropic-messages"
assert anth_saved["choices"][0]["finish_reason"] == "tool_call"
assert all(c["argument_encoding"] == "object" for c in anth_saved["choices"][0]["tool_calls"])
equivalent = copy.deepcopy(anthropic)
equivalent["content"].reverse()
equivalent["content"][0]["input"]["path"] = "SECRET-ARGUMENT-VALUE"
equivalent["content"][0]["id"] = "new-id"
assert run(equivalent, baseline=anth_saved)["status"] == "match"
changed = copy.deepcopy(anthropic)
changed["content"][1]["input"] = json.dumps(changed["content"][1]["input"])
run(changed, 1, anth_saved)
changed["content"][1]["input"] = "{SECRET-ARGUMENT-VALUE"
run(changed, 2, anth_saved, error="malformed_arguments")
run(anthropic, 1, saved)
for reason, normalized in (("end_turn", "end_turn"), ("stop_sequence", "stop_sequence"),
                           ("max_tokens", "token_limit"), ("refusal", "refusal"),
                           ("pause_turn", "pause_turn"), ("model_context_window_exceeded", "context_limit")):
    changed = copy.deepcopy(anthropic)
    changed["stop_reason"] = reason
    assert run(changed)["choices"][0]["finish_reason"] == normalized
    run(changed, 1, anth_saved)
for reason in ("stop", "content_filter", "function_call"):
    changed = copy.deepcopy(base)
    changed["choices"][0]["finish_reason"] = reason
    run(changed, 1, saved)

# Invalid captures fail before comparison, even against an equally broken baseline.
for raw, error in (("", "empty_input"), ("  \n", "empty_input"), ("{", "malformed_json"),
                   ('{"x":1,"x":2}', "malformed_json"), ('{"x":NaN}', "malformed_json"),
                   ("[]", "unsupported_schema"), ('{"type":"message_delta"}', "unsupported_schema")):
    run(raw, 2, raw=True, error=error)
for args in (None, [], 2, "", "not-json-SECRET-ARGUMENT-VALUE", "[]", "null", '{"x":NaN}', '{"x":1,"x":2}'):
    changed = copy.deepcopy(base)
    changed["choices"][0]["message"]["tool_calls"][0]["function"]["arguments"] = args
    run(changed, 2, saved, error="malformed_arguments")
for provider in (base, anthropic):
    changed = copy.deepcopy(provider)
    if provider is base:
        changed["choices"] = []
    else:
        changed["content"] = []
    run(changed, 2, error="zero_output")
    for text, error in (("some output", "missing_tool_calls"), ("", "zero_output")):
        changed = copy.deepcopy(provider)
        if provider is base:
            changed["choices"][0]["message"] = {"role": "assistant", "content": text}
        else:
            changed["content"] = [{"type": "text", "text": text}]
        run(changed, 2, error=error)
    for stop in (None, "unknown-SECRET-ARGUMENT-VALUE"):
        changed = copy.deepcopy(provider)
        if provider is base:
            changed["choices"][0]["finish_reason"] = stop
        else:
            changed["stop_reason"] = stop
        run(changed, 2, error="malformed_response" if stop is None else "unsupported_finish_reason")

changed = copy.deepcopy(base)
changed["choices"].append(copy.deepcopy(changed["choices"][0]))
run(changed, 2, error="malformed_response")
for invalid in ({}, {**saved, "version": 2}, {**saved, "choices": []},
                {**saved, "raw": "SECRET-ARGUMENT-VALUE"}):
    run(base, 2, invalid)
changed = copy.deepcopy(anthropic)
changed["content"].append({"type": "server_tool_use", "input": {"secret": "SECRET-ARGUMENT-VALUE"}})
run(changed, 2, error="unsupported_schema")
changed = copy.deepcopy(base)
changed["choices"][0]["message"]["tool_calls"][0]["type"] = "custom"
run(changed, 2, error="unsupported_schema")
for field in ("id", "function"):
    changed = copy.deepcopy(base)
    del changed["choices"][0]["message"]["tool_calls"][0][field]
    run(changed, 2, error="malformed_tool_call")
changed = copy.deepcopy(base)
changed["choices"][0]["message"]["tool_calls"] = None
run(changed, 2, error="malformed_response")
changed = copy.deepcopy(base)
changed["object"] = "chat.completion.chunk"
run(changed, 2, error="unsupported_schema")
changed = copy.deepcopy(saved)
changed["choices"][0]["tool_call_count"] = 1
run(base, 2, changed, error="invalid_snapshot")
changed = copy.deepcopy(saved)
changed["choices"][0]["tool_calls"][0]["argument_keys"] = ["path", "path"]
run(base, 2, changed, error="invalid_snapshot")

# CLI usage and missing files are machine-readable errors too.
for extra, error in (([], "usage"), (["--unknown"], "usage"), ([str(tmp / "missing")], "unreadable_file")):
    result = subprocess.run([str(root / "bin/cadre"), "contract-snapshot", *extra], capture_output=True, text=True)
    assert result.returncode == 2 and json.loads(result.stdout)["error"] == error
    count += 1
print(f"contract-snapshot: {count} checks passed")
PY
