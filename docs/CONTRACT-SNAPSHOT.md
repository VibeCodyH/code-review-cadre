# Tool-call contract snapshots

`cadre contract-snapshot` checks the structure of a saved tool-calling response
before you spend on an evaluation. It runs offline, requires Python 3 with its
standard library, and does not invoke an adapter, model, tool, or network request.
Python is needed only for this optional command.

```sh
cadre contract-snapshot response.json
cadre contract-snapshot response.json --compare known-good-snapshot.json
```

`cadre preflight` reports capability declarations recorded for a seat. A contract
snapshot records the tool-call shape observed in one response. Use both when
testing an adapter change: a declaration can describe a known restriction;
a snapshot can catch changed argument encoding or dropped calls in a capture.
Neither establishes review quality or contributes to Cadre scores, grades,
panel recommendations, or assurance metrics.

## Capture and compare

Capture a complete, non-streaming response using your own provider client under
a small, fixed probe that requests a client tool call. Keep the prompt, tool
definitions, requested choice count, sampling settings and client conversion
path identical between captures. Record those conditions separately; the
snapshot cannot verify them. Use synthetic arguments and inspect the initial
capture before accepting it as known good.

```sh
# After capturing and inspecting the baseline response yourself:
cadre contract-snapshot known-good-response.json > known-good-snapshot.json

# After capturing the candidate response under the same probe conditions:
cadre preflight --roster codex
cadre contract-snapshot candidate-response.json --compare known-good-snapshot.json &&
  cadre run codex 1
```

The `&&` makes a successful comparison a prerequisite for that optional expensive
run. Nothing installs a gate into existing Cadre commands. Capture files can
contain sensitive data; this command reads them but does not copy or modify them.
Choose where to store them and the output redirects yourself.

## Version 1 format

Normalization prints one deterministic JSON object to stdout:

```json
{"choices":[{"finish_reason":"tool_call","index":0,"tool_call_count":1,"tool_calls":[{"argument_encoding":"string","argument_keys":["path"],"name":"inspect"}]}],"kind":"ContractSnapshot","provider":"openai-chat-completions","version":1}
```

The snapshot retains the provider envelope, each choice index, call count, tool
names, sorted top-level argument keys and actual argument encoding (`string` or
`object`). Repeated calls and repeated choices remain separate. Choices are sorted
by index; calls are sorted by name, encoding and argument keys. Parallel call
order, JSON whitespace and object-key order do not affect comparison.

IDs, model labels, timestamps, token usage, prose, argument values and nested
argument structure are omitted. In particular, two argument values with different
types can match. The tool does not validate arguments against a tool definition or
judge whether the requested tool or its values were correct. Tool names and
argument key names remain visible structural data; use non-sensitive names in
the probe.

These explicit complete-response envelopes are supported:

| Envelope | Tool-call location | Native argument encoding |
| --- | --- | --- |
| OpenAI Chat Completions (`object: "chat.completion"`) | `choices[].message.tool_calls[]`, type `function` | `function.arguments`: JSON string |
| Anthropic Messages (`type: "message"`, assistant role) | `content[]`, type `tool_use` | `input`: object |

Text blocks may accompany Anthropic client tool calls. Both parsers also record
the opposite argument encoding if encountered in a converted capture, so a
string-to-object change produces a mismatch. Accepting that capture for inspection
does not certify conformance with the provider's native wire schema.

OpenAI `tool_calls` and Anthropic `tool_use` become `tool_call`; `length` and
`max_tokens` become `token_limit`. Other supported reasons remain distinct:
OpenAI `stop`, `content_filter`, and deprecated `function_call` (recorded as
`legacy_function_call`); Anthropic `end_turn`, `stop_sequence`, `pause_turn`,
`refusal`, and `model_context_window_exceeded` (recorded as `context_limit`).
Null, missing and unknown stop reasons fail. A parseable response with calls and
a token-limit finish can be snapshotted, but differs from a tool-call finish.
Normalization success alone does not mean the response completed successfully.

The envelope fields follow the [OpenAI Chat Completions reference](https://developers.openai.com/api/reference/resources/chat)
and Anthropic's [client tool-call documentation](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls).
Anthropic finish classes follow its [stop-reason reference](https://platform.claude.com/docs/en/build-with-claude/handling-stop-reasons).
Synthetic examples are in `tests/fixtures/contract-snapshot/`.

## Results and limits

| Exit | Meaning | JSON output |
| --- | --- | --- |
| 0 | Normalized successfully, or comparison matched | `ContractSnapshot`, or `ContractComparison` with `status: "match"` |
| 1 | Valid response differs from a valid baseline | `ContractComparison` with `status: "mismatch"` and changed JSON-pointer paths |
| 2 | Malformed, empty, unreadable or unsupported input; invalid baseline or usage | `ContractError` with `error` and `path` |

Comparison emits paths only, for example
`{"differences":["/choices/0/finish_reason"],"kind":"ContractComparison","status":"mismatch","version":1}`.
Errors never echo raw argument strings, parser exception text or input filenames.
CLI help is text; a missing Python installation is reported on stderr.

Every choice must contain at least one valid call. Empty files (`empty_input`),
empty response output (`zero_output`), text with no tool calls
(`missing_tool_calls`), malformed argument JSON (`malformed_arguments`) and
unrecognized envelopes (`unsupported_schema`) fail distinctly. Duplicate JSON
keys, duplicate choice indices, non-object arguments and invalid baselines also
fail. A broken baseline cannot turn a broken candidate into a match.

Streaming chunks, OpenAI Responses API, legacy `function_call` payloads, custom
tools, Anthropic server tools, thinking blocks and other envelopes are outside
version 1. Assemble or capture a supported complete response at the appropriate
client boundary; do not rename fields to make an unrelated envelope pass.

This is a one-response compatibility smoke check. It does not test multi-turn
tool loops, tool execution, reasoning, findings, transport reliability or model
quality. Equal snapshots can still contain incorrect calls. A mismatch needs
inspection of the probe and adapter before drawing conclusions about a model.

Run the offline checks with `bash tests/contract-snapshot.sh`.
