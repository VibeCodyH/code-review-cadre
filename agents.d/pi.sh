# agentcall adapter: pi  (Pi coding agent, earendil-works)

notes_pi() {
  cat <<'NOTES'
Prompt on STDIN, and stdin MUST be redirected -- see the trap below. -p is
non-interactive. Text mode, not --mode json: see the exit-code trap.
★★ THE TRAP: `pi -p 'prompt'` with an inherited terminal on stdin HANGS until
killed. Measured: rc=124 at every timeout, zero bytes on stdout AND stderr, with
a model and prompt that answer fine otherwise. Under cadre that is survivable
(CADRE_TIMEOUT kills it and it files as failed) but it wastes the whole timeout
and reports nothing about why, so this adapter always feeds the prompt through a
pipe. Do not "simplify" it to an argv call.
★ NOT --mode json, even though the JSON is richer. On an API error json mode
exits 0 with the error only on stderr; text mode exits 1. An adapter's exit
status is load-bearing in cadre -- classify_run reads it, and the synth slot has
nothing else to read -- so the mode that tells the truth about failure wins over
the mode with better structure. Text output needs no stripping either: measured
clean, no banner, no escapes.
★ ro is NOT enforced. Tools are read, bash, edit, write; --tools read,bash looks
like a read-only pair and is not, because bash writes -- measured, it edited the
file. `--tools read` alone cannot run git, and a reviewer that cannot run git is
not a reviewer. The disposable checkout is the containment, as with kimi, kiro
and opencode.
★ WHY IT IS HERE: pi is a HARNESS, not a lineage, and a harness cannot decorrelate
a panel by itself -- rostering pi:anthropic/claude-opus-5 beside claude is one
model twice, exactly like cursor. What pi adds is that the same open model scores
better under it. On a 16-task, 5-harness benchmark pi led every harness at
123/160 vs claude 106/160 and aider 100/160, and the only perfect cell in 85 was
Qwen3.6-27B under pi. Two of that benchmark's top three pi cells are in this
catalog: openai/gpt-oss-120b and google/gemma-4-31b-it:free. Those are the slots
worth taking, and both are lineages no other adapter here reaches.
⚠ MEASURED, and it cost a panel seat: openai/gpt-oss-120b through openrouter is
NOT usable as a reviewer here. Its turn ends with a `thinking` part and no
`text` part -- the harmony reasoning leaks the tool call into the reasoning
channel -- so pi prints nothing and exits 0. It answers a one-line prompt fine
(5/5 on "reply PONG"), which is exactly what makes it look installed and
working. --thinking off does not help: the endpoint answers 400, "Reasoning is
mandatory for this endpoint and cannot be disabled." google/gemma-4-26b-a4b-it
:free was measured emitting real text on the same prompts and is the free pi
seat to use. Check a NEW model with a prompt that needs a tool call, not a
greeting, before you roster it.
--model needs the FULL provider/vendor/id: `openrouter/openai/gpt-oss-120b`.
Given `openai/gpt-oss-120b`, pi reads `openai` as the PROVIDER and answers with
a "use /login" message instead of a review -- prose, not an error, so it scores
as a reviewer that had nothing to say.
~300 models, mostly openrouter; `pi --list-models` prints them. ONE adapter
holds many slots. Local Ollama/vLLM/LM Studio go in ~/.pi/agent/models.json --
CADRE DOES NOT WRITE THAT FILE, the user does.
NOTES
}

# ★ issue #33, measured: pi-routed qwen3.8 reviews that DID state real findings
# were still binned inconclusive, because review_findings and has_verdict saw
# no severity labels and no closing Verdict: -- the model narrated both in
# prose, and the classifier reads only the shape. The adapter's one lever on
# the shape that arrives is the prompt, so the prompt is told the shape.
pi_output_contract() {
  cat <<'CONTRACT'
Format contract: state each finding under a bold severity label on its own
line -- **blocking**, **should-fix**, or **nit** -- and end the whole review
with a final line starting with `Verdict:` followed by one of: blocking,
should-fix, no defects found.
CONTRACT
}

run_pi() {
  local m=() out rc
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" pi -p "${m[@]}"
    return 0
  fi
  # No working-directory flag, so cd. The pipe is not optional: it is what keeps
  # pi from waiting on a terminal that is never going to type anything.
  out=$(mktemp)
  ( cd "$dir" && printf '%s\n\n%s' "$prompt" "$(pi_output_contract)" \
      | timeout -k 30 "$TIMEOUT" pi -p "${m[@]}" 2>&1 ) > "$out"
  rc=$?

  # ★ EMPTY AT EXIT 0 is a real shape here, not a hypothetical. A model whose
  # turn ends with a `thinking` part and no `text` part leaves pi's text-mode
  # printer nothing to print, and it exits 0 anyway -- so the adapter returns a
  # clean success carrying no review. Measured with openai/gpt-oss-120b through
  # openrouter, whose harmony reasoning leaks the tool call INTO the reasoning
  # channel ("Let's check git log.{\"command\":\"git rev-parse HEAD\"}"); the
  # json event stream showed a full 92KB turn, stopReason "stop", no error, and
  # a final message whose only content part was thinking.
  # classify_run already files an empty file as failed, so cadre never scored
  # this as a review -- but it landed as a 0-byte .failed with no cause in it,
  # and a reviewer cannot debug that. Say which model did it and why.
  if [ ! -s "$out" ]; then
    echo "DID NOT COMPLETE, pi returned no text (exit $rc)."
    echo
    echo "pi exited without printing an answer. The usual cause is a model whose"
    echo "turn ends with reasoning and no text part -- pi's text mode has nothing"
    echo "to print and still exits 0. Reasoning-only models are not usable as"
    echo "cadre reviewers through this adapter; pick a model that emits text."
    [ -n "$model" ] && echo "Model was: $model"
    echo "To see what actually happened, rerun the same call with --mode json"
    echo "and look at the last message's content parts."
    rm -f "$out"
    # Nonzero: the run produced nothing, and an adapter that returns 0 here is
    # indistinguishable from a reviewer that looked and found no defects.
    return 1
  fi

  cat "$out"
  rm -f "$out"
  return "$rc"
}
