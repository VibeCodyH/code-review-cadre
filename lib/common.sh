# Shared helpers. Sourced by bin/cadre and the lib/ scripts.
# shellcheck shell=bash

# ★ Under set -u an unset HOME becomes "HOME: unbound variable" naming a line in
# this file, which is a useless thing to hand someone running cadre from cron, a
# container, or a scrubbed CI environment. Only the two defaults below need it,
# and either can be replaced, so say which variable is actually missing. Inline
# rather than via die(), which is not defined yet this early.
_need_home() {
  [ -n "${HOME:-}" ] && return 0
  echo "cadre: HOME is unset, so the default for \$$1 cannot be computed.
     Set $1 explicitly, or $2, or set HOME." >&2
  exit 2
}

# Exported so lib/run-pass.sh resolves the same state dir when cadre invokes it.
[ -n "${CADRE_HOME:-}" ] || [ -n "${XDG_STATE_HOME:-}" ] || _need_home CADRE_HOME XDG_STATE_HOME
export CADRE_HOME="${CADRE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/cadre}"

# ★ MUST be a different tree from the keys. Under $CADRE_HOME the agent's own
# cwd spells out the layout and `cat ../../keys/$(basename $PWD).md` reaches the
# answer. Scrubbing the environment does nothing about that. docs/METHOD.md §5.
[ -n "${CADRE_WORK:-}" ] || [ -n "${XDG_CACHE_HOME:-}" ] || _need_home CADRE_WORK XDG_CACHE_HOME
export CADRE_WORK="${CADRE_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/cadre/checkouts}"
# ★ Enforced HERE, once, so both tracks inherit it. run-pass.sh refused a
# nested checkout; the live path never did, so CADRE_WORK=$CADRE_HOME/checkouts
# quietly reopened the `cat ../../keys/...` hole on the flagship command.
case "$(readlink -m "$CADRE_WORK")/" in
  "$(readlink -m "$CADRE_HOME")"/*)
    echo "cadre: CADRE_WORK ($CADRE_WORK) is inside CADRE_HOME ($CADRE_HOME).
     A reviewer's own working directory would spell out where the answer keys
     are. Point CADRE_WORK at a separate tree." >&2
    exit 2 ;;
esac
CADRE_JUDGE="${CADRE_JUDGE:-}"

die() { echo "cadre: $*" >&2; exit 2; }

# Filename-safe and INJECTIVE. tr ':/' '--' alone collides: "vendor/model" and
# "vendor-model" share a slug, and the second spec reports the first's results.
slug() {
  local safe h
  safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s-%s' "$safe" "$h"
}

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# "agent" or "agent:provider/model".
spec_agent() { printf '%s' "${1%%:*}"; }
spec_model() { local s="$1"; [ "${s#*:}" = "$s" ] || printf '%s' "${s#*:}"; }

# Is this adapter runnable here? ASK AGENTCALL -- never test the adapter name
# with command -v. An adapter may run a binary it is not named after: cursor's
# runs `agent`, kiro's runs `kiro-cli`. Testing the name declares those missing
# on a machine where they work, which is the most confusing failure available
# because it names a tool the user can see on their own PATH. agentcall owns the
# adapter contract, so agentcall answers. Three call sites got this wrong
# independently; this is the one copy so there is no fourth.
#
# ★ Captured, NOT piped into grep -q. Under `set -o pipefail` a -q consumer
# exits on the first match, agentcall takes SIGPIPE, and the whole pipeline
# reports failure -- so every adapter whose name sorted early enough to match
# was declared NOT INSTALLED. The suite caught that at 43 failures.
# CADRE_AGENTS_D has to travel, or agentcall answers about a different set of
# adapters than the one about to run.
agent_installed() {
  local inst
  inst=$(CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
         "$CADRE_ROOT/bin/agentcall" --installed 2>/dev/null)
  case $'\n'"$inst"$'\n' in
    *$'\n'"$1"$'\n'*) return 0 ;;
    *) return 1 ;;
  esac
}

# ★ Which MODEL FAMILY a roster slot actually is, which is not the same question
# as which CLI it runs. A panel is worth exactly its independence, and the fastest
# way to lose that without noticing is to add a harness that fronts models you
# already have: `claude` beside `cursor:claude-opus-5-thinking-high` reads as two
# reviewers and is one lineage twice. Cursor's model list alone spans four
# families that other adapters here already cover.
#
# Classify by the MODEL when a slot names one, because a single adapter can front
# many lineages -- opencode reaches about thirty -- and by the agent otherwise.
# Anything unrecognised falls through to its own name, so two unknown families
# never collide, and two slots of the SAME bare adapter do, which is right: they
# are the same default model.
spec_family() {
  local s="$1" a m key
  a=$(spec_agent "$s"); m=$(spec_model "$s")
  key=$(printf '%s' "${m:-$a}" | tr 'A-Z' 'a-z')
  case "$key" in
    *nemotron*)                                    echo nvidia ;;
    *claude*|*opus*|*sonnet*|*haiku*|*fable*)      echo anthropic ;;
    *codex*|*gpt-*|*gpt5*|*o1-*|*o3-*|*sol*)       echo openai ;;
    *grok*)                                        echo xai ;;
    *qwen*)                                        echo alibaba ;;
    *kimi*|*moonshot*)                             echo moonshot ;;
    *deepseek*)                                    echo deepseek ;;
    *composer*)                                    echo cursor ;;
    *minimax*)                                     echo minimax ;;
    swe-1*|*inkling*)                              echo cognition ;;
    *glm*)                                         echo zhipu ;;
    *gemini*|*gemma*)                              echo google ;;
    *llama*|*muse-spark*)                          echo meta ;;
    *mistral*|*magistral*|*ministral*|*codestral*|*pixtral*|*mixtral*) echo mistral ;;
    vibe)                                          echo mistral ;;
    copilot)                                       echo openai ;;
    *) printf '%s' "$key" | tr -c 'a-z0-9' '-' ;;
  esac
}

# Run $CADRE_JUDGE on stdin. It takes the same agent:provider/model spec a
# candidate does, so the judge model is choosable: the judge is a model too, and
# a free one is enough for it. agentcall itself takes -M, not the spec form.
# ★ CADRE_JUDGE may name TWO judges, comma separated, and two is the supported
# way to grade. One judge's reading of a review is a hypothesis about the
# candidate, not a measurement: two graders on this harness split on about ONE
# ITEM IN THREE. The rule that follows from that is not "break the tie" -- it is
# that an item they disagree on scores nothing and the disagreement is evidence
# the KEY is underspecified. docs/METHOD.md §3.
judge_specs() {
  local raw="${CADRE_JUDGE:-}" j out=() seen=" "
  raw=${raw//,/$'\n'}
  while IFS= read -r j; do
    j=$(trim "$j"); [ -n "$j" ] || continue
    case "$seen" in *" $j "*) continue ;; esac
    seen="$seen$j "; out+=("$j")
  done <<< "$raw"
  [ ${#out[@]} -gt 0 ] && printf '%s\n' "${out[@]}"
  return 0
}

judge_call() {
  local a m mm=()
  a=$(spec_agent "$CADRE_JUDGE"); m=$(spec_model "$CADRE_JUDGE")
  [ -n "$m" ] && mm=(-M "$m")
  # Scrubbed like every other model call. The judge is handed the key by
  # design, but CADRE_WORK in its environment is still a map to trees it has
  # no business in -- the same rule adjudicate_one already follows.
  local sc; mapfile -t sc < <(scrubbed_env)
  "${sc[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
    "$CADRE_ROOT/bin/agentcall" "$a" "${mm[@]}" -d /tmp -m ro
}

# Test command for the review brief. Empty result drops that paragraph.
detect_test_cmd() {
  local d="$1"
  [ -n "${CADRE_TEST_CMD:-}" ] && { printf '%s' "$CADRE_TEST_CMD"; return; }
  if   [ -f "$d/go.mod" ];        then printf 'go test ./<pkg>'
  elif [ -f "$d/Cargo.toml" ];    then printf 'cargo test <name>'
  elif [ -f "$d/pyproject.toml" ] || [ -f "$d/setup.py" ]; then printf 'pytest <path-to-test-file>'
  elif [ -f "$d/package.json" ]; then
    if   grep -qs '"vitest"' "$d/package.json"; then printf 'npx vitest run <path-to-test-file>'
    elif grep -qs '"jest"'   "$d/package.json"; then printf 'npx jest <path-to-test-file>'
    else printf 'npm test'
    fi
  fi
}

# Render lib/prompts/review.md for one pass.
#   render_review_prompt <template> <base> <checkout-dir> [prerun-result-file]
# The 4th argument is optional and only the live path passes it. run-pass.sh
# calls this with three, and review.md has no {{TEST_RESULT}} in it, so the
# benchmark prompt is byte-identical either way.
render_review_prompt() {
  local tpl="$1" base="$2" dir="$3" resf="${4:-}" stack testcmd testp=""
  stack="${CADRE_STACK:-}"
  [ -n "$stack" ] && stack="$stack"$'\n\n'
  testcmd=$(detect_test_cmd "$dir")
  if [ -n "$testcmd" ]; then
    testp="You may run targeted tests, e.g.
  $testcmd
If you assert that something fails or reproduces, actually run it. If you did
not run it, say \"by inspection\" instead. Never claim to have executed
something you did not.
"
  else
    testp="Never claim to have executed something you did not. If a finding is
reasoning rather than a reproduction, say \"by inspection\".
"
  fi
  # ★ {{TEST_RESULT}} is spliced by READING THE FILE, never by gsub. In awk an
  # unescaped & in a gsub replacement means "the text that matched", and test
  # output is exactly the kind of string that contains one. Substituting it
  # would corrupt the result silently, and a corrupted transcript of a test run
  # is worse than no transcript. Whole-line directive, no substitution.
  # With no result file the line is dropped, leaving no placeholder behind.
  awk -v base="$base" -v stack="$stack" -v testp="$testp" -v resf="$resf" '
    /^\{\{TEST_RESULT\}\}$/ {
      if (resf != "") { while ((getline l < resf) > 0) print l; close(resf) }
      next }
    { gsub(/\{\{BASE\}\}/, base)
      gsub(/\{\{STACK_LINE\}\}/, stack)
      gsub(/\{\{TEST_PARAGRAPH\}\}/, testp)
      print }
  ' "$tpl"
}

# Run one user-supplied command against a THROWAWAY copy of the checkout and
# write a transcript the reviewers can be handed.
#   run_prerun <checkout> <workdir> <cmd> <out-file>
# Never the user's repo, never $TPL itself: a suite that builds leaves artifacts,
# and every reviewer would then diff a tree that has been built in. The copy is
# deleted before any reviewer starts.
run_prerun() {
  # Separate statements. bash expands every word of a `local` line before any
  # of its assignments take effect, so dir="$work/prerun" on the same line reads
  # an unset $work and dies under set -u.
  local tpl="$1" work="$2" cmd="$3" out="$4"
  local dir="$work/prerun" rc raw
  cp -a "$tpl" "$dir" || { echo "cadre: could not copy the checkout for --prerun" >&2; return 1; }
  raw=$(mktemp)
  # ★ Same environment scrub the reviewers get. This command is arbitrary code
  # running against the checkout, and CADRE_HOME is the path to the answer keys
  # and to every previous review. A build script that dumps its environment
  # would otherwise write them into a transcript handed to the whole panel.
  local sc; mapfile -t sc < <(scrubbed_env)
  ( cd "$dir" && "${sc[@]}" timeout "${CADRE_PRERUN_TIMEOUT:-600}" bash -c "$cmd" ) \
    > "$raw" 2>&1
  rc=$?
  rm -rf "$dir"
  # 126/127 are the shell's own "cannot execute" and "not found". The user asked
  # for a measurement and did not get one; feeding the panel "exit 127" as if it
  # were a test result is worse than stopping.
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    echo "cadre: --prerun command could not be executed (exit $rc): $cmd" >&2
    sed 's/^/     /' "$raw" | head -5 >&2
    rm -f "$raw"; return 1
  fi
  {
    echo "The test command below was run ONCE on this exact checkout before you"
    echo "started. Every reviewer on this panel was given this same transcript."
    echo
    echo "  \$ $cmd"
    if [ "$rc" -eq 124 ]; then
      echo "  TIMED OUT after ${CADRE_PRERUN_TIMEOUT:-600}s"
    else
      echo "  exit $rc"
    fi
    echo
    echo "Last lines of its output:"
    echo '```'
    tail -c 4000 "$raw" | tail -40
    echo '```'
    echo
    echo "Treat that as measured fact. Do not re-run the whole suite to confirm"
    echo "it; targeted tests are still worth running. If a finding of yours"
    echo "contradicts this transcript, say so and say which one is wrong."
    echo
  } > "$out"
  rm -f "$raw"
  PRERUN_RC="$rc"
  return 0
}

# Refuse to point auto-approving CLIs at a checkout holding credentials.
# Fails CLOSED: an unreadable directory is a refusal, not a pass.
secrets_preflight() {
  local dir="$1" hits
  [ "${CADRE_ALLOW_SECRETS:-}" = 1 ] && return 0
  [ -d "$dir" ] && [ -r "$dir" ] || {
    echo "cadre: cannot read $dir to run the secrets preflight, refusing" >&2
    exit 3
  }
  # No maxdepth: a credential at depth 7 is still a credential. find's stderr is
  # captured, not discarded: an unreadable subdir means the tree was not fully
  # inspected, and "clean" is then a lie.
  local errs; errs=$(mktemp)
  # ★ The trailing ! -name tests exempt committed TEMPLATES. '.env.*' matches
  # the '.env.example' most repos track, so without this the preflight exits 3
  # on the first run against a real repo and the tool looks broken. A template
  # is the one file in this list that is meant to be committed.
  # ★ -type f -o -type l, because the name tests below match DIRECTORIES too.
  # `src/app/integrations/olo/credentials/page.tsx` is a route segment in every
  # Next.js app that has a credentials screen, and without this the whole repo
  # is refused over a folder name.
  local name_hits config_hits
  name_hits=$(cd "$dir" && find . \
           \( -name '.git' -o -name node_modules -o -name vendor -o -name target \) -prune -o \
           \( \( -type f -o -type l \) \
              \( -name '.env' -o -name '.env.*' -o -name '.envrc' \
              -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
              -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' \
              -o -name 'credentials' -o -name '*credentials*.json' -o -name 'service-account*.json' \
              -o -name 'terraform.tfstate' \) \
              ! -name '*.example' ! -name '*.sample' ! -name '*.template' \
              ! -name '*.dist' ! -name '*.tmpl' \) -print 2>"$errs" | head -40)
  # ★ These four are CONFIG files that usually carry no credential at all. The
  # most common .npmrc in the world is one line of `package-lock=false`, and
  # refusing on the filename alone fails every Node repo on its first run --
  # the same "the tool looks broken" failure the *.example exemption prevents.
  # So gate them on CONTENT: an auth-shaped line, or a file we cannot read.
  # Unreadable counts as a hit, same principle as the find-stderr check below.
  config_hits=$(cd "$dir" && find . \
           \( -name '.git' -o -name node_modules -o -name vendor -o -name target \) -prune -o \
           \( \( -type f -o -type l \) \
              \( -name '.npmrc' -o -name '.netrc' -o -name '_netrc' \
              -o -name '.pypirc' -o -name '.dockercfg' \) \
              ! -name '*.example' ! -name '*.sample' ! -name '*.template' \
              ! -name '*.dist' ! -name '*.tmpl' \) -print 2>>"$errs" \
         | while IFS= read -r f; do
             # A value that is an env-var REFERENCE carries no credential:
             # `_authToken=${NPM_TOKEN}` is the standard committed-safe .npmrc
             # line, and refusing on it is the "tool looks broken" failure
             # again. A literal value after the auth key still refuses.
             if [ ! -r "$f" ] || grep -iE '_auth|_password|"auth"|password|machine[[:space:]]' "$f" \
                                  | grep -qvE '=[[:space:]]*"?\$\{?[A-Za-z_]'; then
               printf '%s\n' "$f"
             fi
           done | head -40)
  hits=$(printf '%s\n%s\n' "$name_hits" "$config_hits" | grep -v '^[[:space:]]*$' || true)
  if [ -s "$errs" ]; then
    {
      echo "cadre: refusing to run. The secrets preflight could not read all of $dir:"
      sed 's/^/  /' "$errs" | head -10
      echo "A tree the preflight could not inspect is not a tree it can clear."
    } >&2
    rm -f "$errs"; exit 3
  fi
  rm -f "$errs"
  [ -z "$hits" ] && return 0
  {
    echo "cadre: refusing to run. Credential-shaped files in the checkout:"
    printf '%s\n' "$hits" | sed 's/^/  /'
    echo
    echo "Reviewers run with tool auto-approval and several upload context to a"
    echo "third party. Remove them from the checkout, or set CADRE_ALLOW_SECRETS=1"
    echo "if you have decided these are safe to expose."
  } >&2
  exit 3
}

# Findings the review states, counted in the two shapes reviewers actually emit:
#   codex        1. **blocking** - [file:line](...)
#   grok/claude  ### 1. blocking - ...
# Deliberately loose. Callers only ever compare against small thresholds, so
# over-counting a stray line costs nothing and under-counting hides a bug.
# Lives here, not grade.sh: classify_run needs it and run-pass/run-review
# source only this file.
review_findings() {
  grep -cEi '^ *(#{1,6} *)?([0-9]+[.)]|[-*+])? *\**(blocking|should[ -]fix|must[ -]fix|nit|critical|major)\**' "$1"
}

# Does this output look like a rate-limit refusal rather than a review?
# ★ Length-guarded on purpose. A genuine review OF a rate limiter says "rate
# limit exceeded" while quoting the code, and misreading that as a refusal would
# throw away a real review. A refusal is short; a review is not.
rate_limited() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f")" -le 2000 ] || return 1
  # Providers and SDK wrappers each phrase this differently. An unrecognised
  # shape is not a disaster: it falls through and the run is recorded FAILED,
  # which is the safe direction. It is never scored as a review.
  grep -qiE '(\b(429|529)\b|too many requests|rate[ _-]?limit[a-z]*([ _-](exceeded|reached|hit|error))?|quota (exceeded|exhausted)|exceeded your [a-z ]{0,20}quota|resource[ _-]exhausted|retry[- ]after|slow down|overloaded|capacity constraints|AI_RetryError)' "$f"
}

# ★ The same question for a SYNTHESIS, which needs a different answer. A
# reviewer that trips the keyword scan can be rescued by its adapter's marker; a
# synthesis carries no marker, so the scan is the last word and it is wrong more
# often here. Merging reviews OF THIS REPO produces text about rate limiting as a
# matter of course, and a small panel with few findings merges to under 2KB --
# so a healthy merge matched, burned three retries of the synthesizer's quota,
# and was filed failed with the panel intact underneath it.
#
# The distinction that actually holds: a provider refusal is not something the
# model WRITES, it is something the CLI RETURNS. So believe the keywords only
# when the CLI also failed, or when the body is far too small to be a merge.
provider_refused() {
  local f="$1" rc="$2"
  rate_limited "$f" || return 1
  [ "$rc" -ne 0 ] && return 0
  [ "$(wc -c < "$f")" -lt 500 ]
}

# Classify one agent run: ok | degraded | failed. THE one copy of this rule.
#
# ★ Three states, not two. A reviewer that ran but stopped early holds real
# findings AND coverage it never reached, and both halves matter: the findings
# are worth reading, and its SILENCE about a file is not clearance. Collapsing
# it into "ok" is the bug that already shipped (a partial grok review scored as
# complete). Collapsing it into "failed" is the overcorrection: it throws away
# findings a reviewer actually produced.
#
# ★ Marker names only, no content heuristic. Deciding "did I have partial text?"
# belongs in the ADAPTER, which is the only layer that knows -- grok prints its
# raw JSON dump after DID NOT COMPLETE, so any "is there text before the marker"
# test in here reads that dump as a review. The contract is in
# docs/ADDING-AN-AGENT.md: partial text ends with _TRUNCATED, nothing at all
# says DID NOT RUN or DID NOT COMPLETE.
#
# Returns 0 always. A nonzero return from $(classify_run ...) would abort a
# caller running under set -e.
# ★ Markers count only at the EDGES. An adapter says DID NOT RUN instead of
# output, so it lands at the top; it appends _TRUNCATED after the text it did
# get, so it lands at the bottom. Anywhere else it is the reviewed code or a
# reviewer quoting one. Found by a test: a synthesis that quoted a partial
# reviewer's marker line while explaining WHY it was partial was itself thrown
# away as truncated -- and the synthesizer is now explicitly asked to discuss
# exactly that. Line-anchoring alone was not enough.
classify_run() {
  # ctx is `run` (an adapter reviewing) or `synth` (an adapter merging reviews).
  # Same rule, one copy; the only difference is whether the truncation MARKER is
  # readable in that context. See the marker check below for why it is not.
  local f="$1" rc="$2" ctx="${3:-run}"
  if [ ! -s "$f" ]; then echo failed; return 0; fi
  # ★ Empty means empty of CONTENT, not of bytes. CLIs wrap the model's text in
  # their own chrome -- colour escapes, a "> build <model>" banner -- so a run
  # that returned nothing still leaves a non-empty file and scores as a clean
  # review that found no defects. Measured with opencode, which is the free
  # route the README sends people down first. NOT a minimum-length rule:
  # "findings=0" is a valid review and a length floor threw those away.
  # ★ A LITERAL escape byte, not `\x1b`. `\x1b` is a GNU sed extension; BSD sed
  # (macOS, and macOS keeps BSD sed even with GNU coreutils installed, because
  # sed is not part of coreutils) reads it as a literal `x1b`, matches nothing,
  # and this whole check silently no-ops -- filing a chrome-only run as a clean
  # review again, on an entire platform, with no error. Found by a panel
  # reviewer on cadre's own diff.
  local esc; esc=$(printf '\033')
  if [ -z "$(sed -e "s/${esc}\[[0-9;?]*[a-zA-Z]//g" -e 's/[[:space:]]//g' "$f")" ]; then
    echo failed; return 0
  fi
  # ★ THE ADAPTER'S OWN VERDICT COMES FIRST, both markers together, ahead of
  # anything inferred from the text or the exit code. The adapter is the only
  # layer that watched the run; everything below this is cadre guessing from
  # what the run happened to print.
  #
  # That ordering is not cosmetic. rate_limited() is a keyword match over files
  # under 2KB, so a SHORT partial review that merely DISCUSSES rate limiting --
  # quoting a 429, naming retry-after -- matched it and was binned `failed`,
  # findings and all, while the adapter was explicitly saying "I stopped early
  # and here is what I got". Reviewing this repo is enough to trigger it: cadre
  # has rate-limit handling, so a reviewer reading it quotes those very words.
  # Found by a grok-led panel; the earlier fix moved this marker ahead of the
  # exit code and stopped one line short of the check that actually shadowed it.
  if head -3 "$f" | grep -qE '^(DID NOT RUN|DID NOT COMPLETE)'; then echo failed; return 0; fi
  # ★ Checked BEFORE the exit status too. _TRUNCATED is an adapter saying "I
  # stopped early and this is what I got", exactly the situation where a CLI
  # plausibly also exits nonzero -- rc 124 from a timeout is the obvious one.
  # Testing rc first threw away the partial output of any adapter that honoured
  # the contract without also normalising its exit code. The shipped adapters
  # all normalise, so this costs nothing today and stops a third-party adapter
  # from being silently wrong tomorrow.
  # ★ ...but ONLY for an adapter run. A synthesis is not an adapter run, and the
  # prompt asks it to report which reviewers were truncated -- so its own last
  # lines are the most likely place in the whole system for a legitimate,
  # complete answer to quote a `_TRUNCATED` marker, and a text check there binned
  # good merges. Narrowing the window relocated that collision onto exactly the
  # spot the prompt drives the model toward; it did not remove it, and no window
  # can, because the two requirements are contradictory for a text test. A
  # synthesizer that really did stop early is caught by its EXIT STATUS instead,
  # which the model cannot forge. docs/ADDING-AN-AGENT.md makes that the price
  # of a synth slot.
  if [ "$ctx" = run ] && tail -3 "$f" | grep -qE '^_TRUNCATED'; then echo degraded; return 0; fi
  if [ "$ctx" = run ]; then
    # ★ ...and a refusal never states a severity-tagged finding. A COMPLETE
    # short review of rate-limiter code says "429" while listing findings, has
    # no adapter marker to rescue it, and was binned failed -- the README's
    # length-guard claim was only true above 2KB. A refusal that happens to
    # open with "critical:" slips through here and lands on the judge instead,
    # which is the cheaper direction: a destroyed real review is unrecoverable.
    if rate_limited "$f" && [ "$(review_findings "$f")" -eq 0 ]; then echo failed; return 0; fi
  elif provider_refused "$f" "$rc"; then
    echo failed; return 0
  fi
  if [ "$rc" -ne 0 ]; then echo failed; return 0; fi
  echo ok
  return 0
}

# Seconds to wait before retry $1 (1-based). Exponential, capped at 10 min.
retry_wait() {
  local base="${CADRE_RETRY_WAIT:-60}" n="$1" w
  w=$(( base * (1 << (n - 1)) ))
  [ "$w" -gt 600 ] && w=600
  echo "$w"
}

# Names to strip from an agent's environment before it runs. $CADRE_HOME is the
# path to the keys and to every other reviewer's output. The DERIVED names are
# on the list too: scrubbing one variable is useless while another spells the
# same path out. Mitigation, not a sandbox. docs/METHOD.md §5.
# ★ CADRE_WORK belongs here and was missing. Reviewer checkouts are $CADRE_WORK/
# review-XXXX/rN, so an agent that can read this variable can `ls` straight into
# the tree another reviewer on the same panel is reading. That is exactly the
# cross-contamination the output-directory containment check exists to stop, and
# leaving the variable in the environment routed around it. Nothing downstream
# of the scrub needs it: the runner resolves the work dir before dispatch and
# hands each agent its own -d.
# NOT scrubbed: CADRE_TIMEOUT (agentcall reads it from its own environment to
# size the timeout) and CADRE_PASS_BASE (adapters need it, it is only a git rev).
CADRE_SCRUB_ENV=(CADRE_HOME CADRE_ROOT CADRE_JUDGE CADRE_PROMPT_FILE
                 CADRE_STACK CADRE_TEST_CMD CADRE_ALLOW_SECRETS
                 CADRE_PASS_DIR CADRE_AGENTS_D CADRE_WORK
                 CADRE_PRERUN CADRE_PRERUN_TIMEOUT
                 CADRE_ADJUDICATOR CADRE_LEDGER CADRE_ROSTER
                 CADRE_SYNTH CADRE_SYNTH_MAX
                 CADRE_TARGET_MAX_FILES CADRE_TARGET_MAX_KB)
scrubbed_env() {
  local a=(env) v
  for v in "${CADRE_SCRUB_ENV[@]}"; do a+=(-u "$v"); done
  printf '%s\n' "${a[@]}"
}
