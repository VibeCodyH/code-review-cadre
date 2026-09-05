# Optional Pi SDK reviewer. Install integrations/pi-review with npm ci first.
bin_pireview() {
  if [ -f "$CADRE_ROOT/integrations/pi-review/node_modules/@earendil-works/pi-coding-agent/package.json" ]; then
    echo node
  else
    echo cadre-pi-review-not-installed
  fi
}

cannot_pireview() { printf '%s\n' role:judge role:synth; }

notes_pireview() {
  cat <<'NOTES'
Review-specific Pi SDK adapter; requires Node 22.19+ and npm ci in
integrations/pi-review. Explicit provider/model required. Saves structured
findings, tool execution events, and a result beside the Markdown review.
Uses configured Pi providers/auth, with extensions, skills and context files
disabled. Same coding tools as stock Pi, including bash: use a disposable
checkout; this is not a filesystem sandbox. Judge and synthesis unsupported.
CADRE_PI_THINKING defaults off. Artifacts default to CADRE_HOME/pi-review;
CADRE_PI_REVIEW_ARTIFACTS overrides that directory. Never overwrite a run.
NOTES
}

run_pireview() {
  local script="$CADRE_ROOT/integrations/pi-review/cli.mjs" store run out rc state note
  [ -n "$model" ] || { echo 'DID NOT RUN, misconfigured: pireview requires provider/model'; return 1; }
  case "$TIMEOUT" in ''|*[!0-9]*) echo 'DID NOT RUN, misconfigured: pireview needs an integer CADRE_TIMEOUT'; return 1 ;; esac
  if [ -n "$DRY" ]; then
    _run node "$script" --cwd "$dir" --model "$model" --out '<new-artifact-directory>' \
      --thinking "${CADRE_PI_THINKING:-off}" --timeout "$TIMEOUT"
    return 0
  fi
  store="${CADRE_PI_REVIEW_ARTIFACTS:-$CADRE_HOME/pi-review}"
  mkdir -p "$store" || return 1
  run=$(mktemp -d "$store/run.XXXXXXXX") || return 1
  out="$run/review"
  # Keep bookkeeping paths out of the model's environment. Same uid is not isolation.
  export -n CADRE_PI_REVIEW_ARTIFACTS 2>/dev/null || true
  printf '%s' "$prompt" | PI_OFFLINE=1 PI_TELEMETRY=0 \
    timeout -k 5 "$((TIMEOUT + 10))" node "$script" --cwd "$dir" --model "$model" \
      --out "$out" --thinking "${CADRE_PI_THINKING:-off}" --timeout "$TIMEOUT" > "$run/stdout.txt" 2> "$run/stderr.txt"
  rc=$?
  state=$(jq -r '.status // empty' "$out/result.json" 2>/dev/null) || state=""
  note="pi-review artifacts: $out"
  if [ "$state" = ok ] && [ "$rc" -eq 0 ] && [ -s "$out/review.md" ]; then
    cat "$out/review.md"
    cadre_state ok "$note"
    return 0
  fi
  if [ "$state" = degraded ] && [ -s "$out/review.md" ]; then
    cat "$out/review.md"
    cadre_state degraded "$note"
    return 1
  fi
  echo "DID NOT COMPLETE, pireview failed (exit $rc); artifacts: $out"
  cadre_state failed "$note"
  return 1
}
