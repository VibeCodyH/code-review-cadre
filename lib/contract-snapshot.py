#!/usr/bin/env python3
"""Offline structural smoke check for captured tool-calling responses."""
import argparse
import json
import sys


REASONS = {
    "openai-chat-completions": {
        "tool_calls": "tool_call", "stop": "stop", "length": "token_limit",
        "content_filter": "content_filter", "function_call": "legacy_function_call",
    },
    "anthropic-messages": {
        "tool_use": "tool_call", "end_turn": "end_turn", "max_tokens": "token_limit",
        "stop_sequence": "stop_sequence", "pause_turn": "pause_turn",
        "refusal": "refusal", "model_context_window_exceeded": "context_limit",
    },
}


class Invalid(Exception):
    def __init__(self, code, path):
        self.code, self.path = code, path


def require(ok, code, path):
    if not ok:
        raise Invalid(code, path)


def reject_constant(_):
    raise ValueError("non-JSON numeric constant")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


def parse_json(raw):
    return json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)


def read_json(filename, label):
    try:
        with open(filename, encoding="utf-8") as stream:
            raw = stream.read()
    except (OSError, UnicodeError):
        raise Invalid("unreadable_file", label) from None
    require(bool(raw.strip()), "empty_input", label)
    try:
        return parse_json(raw)
    except (ValueError, RecursionError):
        raise Invalid("malformed_json", label) from None


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def tool(name, args, path):
    require(isinstance(name, str) and bool(name.strip()), "malformed_tool_call", path + ".name")
    encoding = "string" if isinstance(args, str) else "object"
    if isinstance(args, str):
        try:
            args = parse_json(args)
        except (ValueError, RecursionError):
            raise Invalid("malformed_arguments", path + ".arguments") from None
    require(isinstance(args, dict), "malformed_arguments", path + ".arguments")
    return {"name": name, "argument_encoding": encoding, "argument_keys": sorted(args)}


def choice(index, reason, calls):
    return {"index": index, "finish_reason": reason, "tool_call_count": len(calls),
            "tool_calls": sorted(calls, key=lambda call: (call["name"], call["argument_encoding"], canonical(call["argument_keys"])))}


def finish(raw, provider, path):
    require(isinstance(raw, str), "malformed_response", path)
    require(raw in REASONS[provider], "unsupported_finish_reason", path)
    return REASONS[provider][raw]


def snapshot(response):
    require(isinstance(response, dict), "unsupported_schema", "response")
    choices = []
    if response.get("object") == "chat.completion":
        provider = "openai-chat-completions"
        raw_choices = response.get("choices")
        require(isinstance(raw_choices, list), "malformed_response", "response.choices")
        require(bool(raw_choices), "zero_output", "response.choices")
        indices = set()
        for offset, item in enumerate(raw_choices):
            path = f"response.choices[{offset}]"
            require(isinstance(item, dict), "malformed_response", path)
            index = item.get("index")
            require(type(index) is int and index >= 0 and index not in indices,
                    "malformed_response", path + ".index")
            indices.add(index)
            reason = finish(item.get("finish_reason"), provider, path + ".finish_reason")
            message = item.get("message")
            require(isinstance(message, dict) and message.get("role") == "assistant",
                    "malformed_response", path + ".message")
            require(not message.get("function_call"), "unsupported_schema", path + ".message.function_call")
            content = message.get("content")
            refusal = message.get("refusal")
            require(content is None or isinstance(content, str), "unsupported_schema", path + ".message.content")
            require(refusal is None or isinstance(refusal, str), "malformed_response", path + ".message.refusal")
            raw_calls = message.get("tool_calls", [])
            require(isinstance(raw_calls, list), "malformed_response", path + ".message.tool_calls")
            require(bool(raw_calls), "missing_tool_calls" if content or refusal else "zero_output", path + ".message")
            calls = []
            for n, call in enumerate(raw_calls):
                call_path = path + f".message.tool_calls[{n}]"
                require(isinstance(call, dict), "malformed_tool_call", call_path)
                require(call.get("type") == "function", "unsupported_schema", call_path + ".type")
                require(isinstance(call.get("id"), str) and bool(call["id"]), "malformed_tool_call", call_path + ".id")
                function = call.get("function")
                require(isinstance(function, dict), "malformed_tool_call", call_path + ".function")
                calls.append(tool(function.get("name"), function.get("arguments"), call_path + ".function"))
            choices.append(choice(index, reason, calls))
    elif response.get("type") == "message":
        provider = "anthropic-messages"
        require(response.get("role") == "assistant", "malformed_response", "response.role")
        reason = finish(response.get("stop_reason"), provider, "response.stop_reason")
        content = response.get("content")
        require(isinstance(content, list), "malformed_response", "response.content")
        require(bool(content), "zero_output", "response.content")
        calls, has_output = [], False
        for n, block in enumerate(content):
            path = f"response.content[{n}]"
            require(isinstance(block, dict), "malformed_response", path)
            if block.get("type") == "tool_use":
                require(isinstance(block.get("id"), str) and bool(block["id"]), "malformed_tool_call", path + ".id")
                calls.append(tool(block.get("name"), block.get("input"), path))
            elif block.get("type") == "text":
                require(isinstance(block.get("text"), str), "malformed_response", path + ".text")
                has_output = has_output or bool(block["text"])
            else:
                # Server tools, thinking and streaming events need their own contracts.
                raise Invalid("unsupported_schema", path + ".type")
        require(bool(calls), "missing_tool_calls" if has_output else "zero_output", "response.content")
        choices.append(choice(0, reason, calls))
    else:
        raise Invalid("unsupported_schema", "response")
    return {"kind": "ContractSnapshot", "version": 1, "provider": provider,
            "choices": sorted(choices, key=lambda item: item["index"])}


def validate_baseline(value):
    """Accept only the documented structural schema, never arbitrary report data."""
    def fields(item, keys):
        require(isinstance(item, dict) and set(item) == set(keys), "invalid_snapshot", "baseline")

    fields(value, ("kind", "version", "provider", "choices"))
    require(value["kind"] == "ContractSnapshot" and type(value["version"]) is int and value["version"] == 1,
            "unsupported_snapshot_version", "baseline")
    provider = value["provider"]
    require(isinstance(provider, str) and provider in REASONS, "invalid_snapshot", "baseline.provider")
    require(isinstance(value["choices"], list) and bool(value["choices"]), "invalid_snapshot", "baseline.choices")
    normalized, indices = [], set()
    for item in value["choices"]:
        fields(item, ("index", "finish_reason", "tool_call_count", "tool_calls"))
        index = item["index"]
        require(type(index) is int and index >= 0 and index not in indices, "invalid_snapshot", "baseline.choices")
        indices.add(index)
        require(item["finish_reason"] in REASONS[provider].values(), "invalid_snapshot", "baseline.choices")
        calls = item["tool_calls"]
        require(isinstance(calls, list) and bool(calls) and type(item["tool_call_count"]) is int
                and item["tool_call_count"] == len(calls), "invalid_snapshot", "baseline.choices")
        for call in calls:
            fields(call, ("name", "argument_encoding", "argument_keys"))
            require(isinstance(call["name"], str) and bool(call["name"].strip())
                    and call["argument_encoding"] in ("string", "object"), "invalid_snapshot", "baseline.choices")
            keys = call["argument_keys"]
            require(isinstance(keys, list) and all(isinstance(key, str) for key in keys), "invalid_snapshot", "baseline.choices")
            require(len(keys) == len(set(keys)), "invalid_snapshot", "baseline.choices")
            call["argument_keys"] = sorted(keys)
        normalized.append(choice(index, item["finish_reason"], calls))
    require(provider != "anthropic-messages" or indices == {0}, "invalid_snapshot", "baseline.choices")
    return {**value, "choices": sorted(normalized, key=lambda item: item["index"])}


def differences(expected, actual, path=""):
    """Report structural paths only; no captured argument values or raw errors."""
    if type(expected) is not type(actual):
        return [path]
    if isinstance(expected, dict):
        return [p for key in sorted(expected) for p in differences(expected[key], actual[key], f"{path}/{key}")]
    if isinstance(expected, list):
        if len(expected) != len(actual):
            return [path]
        return [p for n, (a, b) in enumerate(zip(expected, actual)) for p in differences(a, b, f"{path}/{n}")]
    return [] if expected == actual else [path]


class Parser(argparse.ArgumentParser):
    def error(self, _message):
        raise Invalid("usage", "arguments")


def main():
    try:
        parser = Parser(prog="cadre contract-snapshot", description=__doc__)
        parser.add_argument("response", help="captured, non-streaming response JSON")
        parser.add_argument("--compare", metavar="SNAPSHOT", help="known-good ContractSnapshot JSON")
        args = parser.parse_args()
        actual = snapshot(read_json(args.response, "response"))
        if args.compare is None:
            print(canonical(actual))
            return 0
        expected = validate_baseline(read_json(args.compare, "baseline"))
        changed = differences(expected, actual)
        print(canonical({"kind": "ContractComparison", "version": 1,
                         "status": "mismatch" if changed else "match", "differences": changed}))
        return 1 if changed else 0
    except Invalid as error:
        print(canonical({"kind": "ContractError", "version": 1, "status": "error",
                         "error": error.code, "path": error.path}))
        return 2
    except RecursionError:
        print(canonical({"kind": "ContractError", "version": 1, "status": "error",
                         "error": "malformed_json", "path": "input"}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
