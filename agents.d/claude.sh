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
#
# ★ `advisor` is deliberately NOT in this list, even though killing it is the
# whole point of ro mode. It is not in the CLI's tool registry, so denying it
# prints `Permission deny rule "advisor" matches no known tool` -- on STDERR,
# which run_claude merges into the review text. That warning became line 1 of
# every claude review in a corpus run, a contaminant no other candidate carried.
# The deny never disabled it anyway; --settings advisorModel="" does. Denying a
# name the CLI does not know is not a belt-and-braces, it is data corruption.
#
# ★ Bash is deliberately ALLOWED. The review prompt tells every candidate "You
# may run targeted tests ... if you assert something reproduces, actually run
# it" -- detect_test_cmd fires on all 12 passes, and codex has executed under
# its read-only sandbox from day one. Denying Bash here does not create parity,
# it inverts it: claude alone would be told to run tests it cannot run. Measured:
# grok ran `tsc --noEmit` in a real pass and reported the result.
#
# ★ Workflow is denied because it orchestrates MULTI-AGENT runs -- the advisor
# hole wearing a different name. It is not in this list because anyone reasoned
# about it; it is here because the probe printed it. Deny lists cannot be
# derived, only observed: re-probe after every CLI upgrade.
CLAUDE_DENY="Agent CronCreate CronDelete CronList DesignSync Edit \
EnterWorktree ExitWorktree LSP Monitor NotebookEdit PushNotification RemoteTrigger \
ReportFindings ScheduleWakeup SendMessage Skill TaskCreate TaskGet TaskList \
TaskOutput TaskStop TaskUpdate ToolSearch Workflow Write"

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
