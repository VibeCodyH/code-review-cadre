# agentcall adapter: agy  (Antigravity / Gemini CLI)

notes_agy() {
  cat <<'NOTES'
★ GRADING ONLY. Do not roster this as a reviewer or an adjudicator.

Two separate limits, and only one of them applies to grading:

  1. It refuses security-flavoured analysis. Asked to audit code for
     vulnerabilities it declines outright, so a review or an adjudication of a
     security-adjacent change comes back as a refusal rather than a result.
  2. Headless, it auto-denies its OWN tool permissions, and the
     --dangerously-skip-permissions retry is blocked by its classifier. Any job
     that needs to read a checkout therefore cannot run unattended.

Judging is exempt from BOTH. The judge prompt is bookkeeping over text that is
already in the prompt -- "do not evaluate the code yourself, do not open the
repository" -- so it needs no tools, and it is not being asked to find
vulnerabilities. Measured: it graded a review of an ungated destructive-write
route without refusing, and returned clean unfenced JSON with `quotes`
populated. That makes it a genuinely useful THIRD grader, which is otherwise
scarce -- copilot and kimi are out of quota, vibe is metered, and every local
option is either the incumbent judge's own weights or too small.
NOTES
}

run_agy() {
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" agy -p "$prompt"
    return 0
  fi
  argv_prompt_ok || return 0
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" agy -p "$prompt" 2>&1 )
}

# No model flag on this CLI. Refuse agent:model instead of running the
# default and filing the result under a model that never ran.
nomodel_agy() { :; }
