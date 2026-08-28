# agentcall adapter: dsh  (DeepSeek Harness headless profile)

notes_dsh() {
  cat <<'NOTES'
Boots `dsh --profile headless "<task>"`: one fresh persisted session, prints
the final answer, exits. Providers/models are pinned by the PROFILE's
cordis.patch.yml (~/.dsh/profiles/headless/), not by this adapter -- the
$model half of a spec is IGNORED; point the profile at the model you want.
Local Ollama route needs a dummy key: the pi-ai plugin refuses a keyless
hand-declared route, so this adapter exports OLLAMA_API_KEY=ollama (Ollama
ignores the value) when it is not already set.
★ argv-only: dsh has NO stdin/prompt-file mode (measured: piped stdin +
no arg = "error: a task is required"). Fine for reviews, fatal for a
3-reviewer synthesis (~184KB > the ~128KB argv cap), so role:synth is
declared off below rather than discovered at dispatch.
★ dsh exits 0 on its own errors (measured: the "a task is required" error,
rc=0), so the empty/error checks below read the OUTPUT; the exit code alone
clears nothing.
★ Same format trap as pi (#33): a thinking model narrates severities in
prose and skips the closing verdict, and classify_run bins the run
inconclusive. The same output contract is appended here.
NOTES
}

cannot_dsh() {
  echo role:synth
}

bin_dsh() { echo dsh; }

# Duplicated from pi.sh rather than sourced: adapters load standalone, and a
# cross-file source would couple this seat's dispatch to pi's file layout.
dsh_output_contract() {
  cat <<'CONTRACT'
Format contract: state each finding under a bold severity label on its own
line -- **blocking**, **should-fix**, or **nit** -- and end the whole review
with a final line starting with `Verdict:` followed by one of: blocking,
should-fix, no defects found.
CONTRACT
}

run_dsh() {
  local out rc task
  task=$(printf '%s\n\n%s' "$prompt" "$(dsh_output_contract)")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" dsh --profile headless "$task"
    return 0
  fi
  out=$(mktemp)
  ( cd "$dir" && OLLAMA_API_KEY="${OLLAMA_API_KEY:-ollama}" \
      timeout -k 30 "$TIMEOUT" dsh --profile headless "$task" 2>/dev/null ) > "$out"
  rc=$?

  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    echo "DID NOT COMPLETE, dsh was killed at the ${TIMEOUT}s timeout"
    cat "$out"; rm -f "$out"; return 1
  fi
  # rc=0 with error-shaped or empty output IS the dsh failure shape (see notes).
  if [ ! -s "$out" ] || head -2 "$out" | grep -qiE '^(error|dsh):'; then
    echo "DID NOT COMPLETE, dsh printed no review (exit $rc)."
    cat "$out"; rm -f "$out"; return 1
  fi

  cat "$out"
  rm -f "$out"
  return "$rc"
}
