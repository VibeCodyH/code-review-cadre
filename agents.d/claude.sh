# agentcall adapter: claude  (Anthropic Claude Code CLI)

notes_claude() {
  cat <<'NOTES'
Prompt MUST go on stdin, never argv, a diff-sized prompt exceeds ARG_MAX
and the failure looks like a CLI error, not a size problem.

★ ro mode DENIES by name. --allowedTools only PRE-APPROVES; it does not deny
anything else, so an allowlist alone leaves every other tool reachable.
Measured, and it voided a whole benchmark round: a candidate run under the old
--allowedTools "ro" held `advisor` (a second, stronger reviewer model), `Agent`
(subagents), and Bash/Edit/Write. It used the advisor and said so in its review.
codex runs under a real `-s read-only` sandbox, so that candidate was not a
peer -- it was a candidate plus a consultant.

★ RE-PROBE after any CLI upgrade. A deny-list cannot know about a tool that did
not exist when it was written, so the list is the fix and the probe is the
guarantee: ask the agent to enumerate its own tools and read the answer.
NOTES
}

# Everything the CLI exposes that is not needed to READ code. Explicit rather
# than computed: a name that vanishes from a future CLI is harmless here; a name
# that silently appears is exactly what the probe exists to catch.
CLAUDE_DENY="advisor Agent Bash CronCreate CronDelete CronList DesignSync Edit \
EnterWorktree ExitWorktree LSP Monitor NotebookEdit PushNotification RemoteTrigger \
ReportFindings ScheduleWakeup SendMessage Skill TaskCreate TaskGet TaskList \
TaskOutput TaskStop TaskUpdate ToolSearch Write"

run_claude() {
  local ro=() m=()
  # THREE mechanisms, because one is not enough and each closes a different hole:
  #   --strict-mcp-config   drops the OPERATOR's MCP servers. A candidate must not
  #                         inherit whatever the human running the benchmark has
  #                         installed; that is not a property of the model.
  #   --disallowedTools     denies the CLI's own registry by name.
  #   --settings advisorModel=""
  #                         ★ kills the `advisor` tool -- a SECOND, STRONGER model
  #                         the candidate can consult. It comes from the operator's
  #                         settings.json (`advisorModel`), is NOT in the CLI's tool
  #                         registry, and --disallowedTools therefore cannot touch
  #                         it: the CLI answers "deny rule advisor matches no known
  #                         tool" and leaves it available. Verified by probe --
  #                         `{"advisorModel":null}` still yields ADVISOR=YES, only
  #                         the empty string yields NO.
  # shellcheck disable=SC2206
  [ "$mode" = ro ] && ro=(--strict-mcp-config --settings '{"advisorModel":""}'
                          --disallowedTools $CLAUDE_DENY)
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" claude -p "${m[@]}" "${ro[@]}"
    return 0
  fi
  ( cd "$dir" && printf '%s' "$prompt" | timeout -k 30 "$TIMEOUT" claude -p "${m[@]}" "${ro[@]}" 2>&1 )
}
