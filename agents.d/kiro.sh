# agentcall adapter: kiro  (Kiro CLI)

notes_kiro() {
  cat <<'NOTES'
Installs as `kiro-cli`, not `kiro`. Needs `chat --no-interactive` and refuses to
start without the prompt as an ARGUMENT, so it is argv-bound: reviews are fine,
a big synthesis is not, and the adapter says DID NOT RUN rather than letting the
shell fail. Prefer a stdin adapter for --synth.
★ -a/--trust-all-tools or it asks for confirmation and hangs headless. ro is NOT
enforced: --trust-tools exists but the tool names are undocumented, and a
reviewer that cannot run git is not a reviewer. The disposable checkout is the
containment here, as with kimi and opencode.
★ WORTH IT FOR minimax-m2.5, minimax-m2.1 and glm-5, which no other adapter here
reaches. Measured list (docs oversell -- they advertise GPT-5.6, the CLI does not
offer it): auto, claude-sonnet-4.5, claude-sonnet-4, claude-haiku-4.5,
deepseek-3.2, minimax-m2.5, minimax-m2.1, glm-5, qwen3-coder-next.
⚠ The claude-*, deepseek-* and qwen3-* entries are families the claude, opencode
and qwen adapters already cover. Rostering them beside those is one lineage in
two seats; cadre warns, but pick the ones nothing else can reach.
A leading "> " prompt echo is left ALONE on purpose. Stripping `^> ` would also
eat a review that opens with a markdown blockquote, and losing review text is
worse than a stray marker -- opencode's banner rule already made that mistake.
--model is per invocation, so ONE adapter can hold several distinct slots:
kiro:minimax-m2.5 and kiro:glm-5 are genuinely different reviewers.
NOTES
}

# Binary is `kiro-cli`; the adapter keeps the short name so a roster reads well.
bin_kiro() { echo kiro-cli; }

run_kiro() {
  local m=()
  [ -n "$model" ] && m=(--model "$model")
  if [ -n "$DRY" ]; then
    _run timeout -k 30 "$TIMEOUT" kiro-cli chat --no-interactive --trust-all-tools "${m[@]}"
    return 0
  fi
  argv_prompt_ok || return 0
  # ★ Strip its chrome, or a run that returned NO review is still a non-empty
  # file and scores as a reviewer that looked and found nothing. Kiro wraps every
  # answer in a trust banner, retry notices, a `> ` echo and a credits footer,
  # plus private-mode escapes like [?25h. Anchored: the banner only appears at
  # the top, and a reviewer quoting "Credits:" mid-review must survive.
  # ★ Kiro blames the wrong thing on its way out. When a run dies for a REAL
  # reason -- "Kiro rate limit reached: Request quota exceeded", or "The model
  # you've selected is temporarily unavailable" -- it still signs off with
  #   error: Tool approval required but --no-interactive was specified.
  #          Use --trust-all-tools to automatically approve tools.
  # as the last line, and cadre passes --trust-all-tools on every call, so that
  # sentence is never true here. It is the last thing in the .failed file, which
  # is the first thing a human reads, and it sends them hunting a config bug in
  # this adapter while the actual cause scrolls by above. Annotated rather than
  # deleted: if kiro ever emits it alone, the line still has to survive.
  local esc; esc=$(printf '\033')
  ( cd "$dir" && timeout -k 30 "$TIMEOUT" kiro-cli chat --no-interactive \
      --trust-all-tools "${m[@]}" "$prompt" 2>&1 ) \
    | sed -e "s/${esc}\[[0-9;?]*[a-zA-Z]//g" \
          -e '1,8{' -e '/^All tools are now trusted/d' -e '/^Agents can sometimes do/d' \
          -e '/^Learn more at https:\/\/kiro\.dev/d' -e '}' \
          -e '/^WARNING: Retry #[0-9]/d' \
          -e '/^ *▸ Credits: .* Time: /d' \
          -e 's|^error: Tool approval required but --no-interactive was specified.*|[cadre] Ignore the "tool approval" error kiro prints here: this call passed --trust-all-tools, so that is never the cause. The real reason is above.|'
}
