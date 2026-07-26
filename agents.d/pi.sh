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
--model takes provider/id, so ONE adapter holds many slots. ~300 models, mostly
openrouter; `pi --list-models` prints them. Local Ollama/vLLM/LM Studio go in
~/.pi/agent/models.json -- CADRE DOES NOT WRITE THAT FILE, the user does.
NOTES
}

run_pi() {
  local m=()
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" pi -p "${m[@]}"
    return 0
  fi
  # No working-directory flag, so cd. The pipe is not optional: it is what keeps
  # pi from waiting on a terminal that is never going to type anything.
  ( cd "$dir" && printf '%s' "$prompt" \
      | timeout -k 30 "$TIMEOUT" pi -p "${m[@]}" 2>&1 )
}
