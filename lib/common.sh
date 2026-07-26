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

# Run $CADRE_JUDGE on stdin. It takes the same agent:provider/model spec a
# candidate does, so the judge model is choosable: the judge is a model too, and
# a free one is enough for it. agentcall itself takes -M, not the spec form.
judge_call() {
  local a m mm=()
  a=$(spec_agent "$CADRE_JUDGE"); m=$(spec_model "$CADRE_JUDGE")
  [ -n "$m" ] && mm=(-M "$m")
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
  hits=$(cd "$dir" && find . \
           \( -name '.git' -o -name node_modules -o -name vendor -o -name target \) -prune -o \
           \( \( -name '.env' -o -name '.env.*' -o -name '.envrc' \
              -o -name '*.pem' -o -name '*.key' -o -name '*.p12' -o -name '*.pfx' \
              -o -name 'id_rsa' -o -name 'id_dsa' -o -name 'id_ecdsa' -o -name 'id_ed25519' \
              -o -name 'credentials' -o -name '*credentials*.json' -o -name 'service-account*.json' \
              -o -name '.npmrc' -o -name '.netrc' -o -name '.pypirc' -o -name '.dockercfg' \
              -o -name 'terraform.tfstate' \) \
              ! -name '*.example' ! -name '*.sample' ! -name '*.template' \
              ! -name '*.dist' ! -name '*.tmpl' \) -print 2>"$errs" | head -40)
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
  local f="$1" rc="$2"
  if [ "$rc" -ne 0 ] || [ ! -s "$f" ]; then echo failed; return 0; fi
  # ★ Empty means empty of CONTENT, not of bytes. CLIs wrap the model's text in
  # their own chrome -- colour escapes, a "> build <model>" banner -- so a run
  # that returned nothing still leaves a non-empty file and scores as a clean
  # review that found no defects. Measured with opencode, which is the free
  # route the README sends people down first. NOT a minimum-length rule:
  # "findings=0" is a valid review and a length floor threw those away.
  if [ -z "$(sed -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' -e 's/[[:space:]]//g' "$f")" ]; then
    echo failed; return 0
  fi
  if rate_limited "$f"; then echo failed; return 0; fi
  if head -3 "$f" | grep -qE '^(DID NOT RUN|DID NOT COMPLETE)'; then echo failed; return 0; fi
  if tail -3 "$f" | grep -qE '^_TRUNCATED'; then echo degraded; return 0; fi
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
CADRE_SCRUB_ENV=(CADRE_HOME CADRE_ROOT CADRE_JUDGE CADRE_PROMPT_FILE
                 CADRE_STACK CADRE_TEST_CMD CADRE_ALLOW_SECRETS
                 CADRE_PASS_DIR CADRE_AGENTS_D CADRE_WORK
                 CADRE_PRERUN CADRE_PRERUN_TIMEOUT)
scrubbed_env() {
  local a=(env) v
  for v in "${CADRE_SCRUB_ENV[@]}"; do a+=(-u "$v"); done
  printf '%s\n' "${a[@]}"
}
