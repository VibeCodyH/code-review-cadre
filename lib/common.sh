# Shared helpers. Sourced by bin/cadre and the lib/ scripts.
# shellcheck shell=bash

# Exported so lib/run-pass.sh resolves the same state dir when cadre invokes it.
export CADRE_HOME="${CADRE_HOME:-${XDG_STATE_HOME:-$HOME/.local/state}/cadre}"

# ★ MUST be a different tree from the keys. Under $CADRE_HOME the agent's own
# cwd spells out the layout and `cat ../../keys/$(basename $PWD).md` reaches the
# answer. Scrubbing the environment does nothing about that. docs/METHOD.md §5.
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
#   render_review_prompt <template> <base> <checkout-dir>
render_review_prompt() {
  local tpl="$1" base="$2" dir="$3" stack testcmd testp=""
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
  awk -v base="$base" -v stack="$stack" -v testp="$testp" '
    { gsub(/\{\{BASE\}\}/, base)
      gsub(/\{\{STACK_LINE\}\}/, stack)
      gsub(/\{\{TEST_PARAGRAPH\}\}/, testp)
      print }
  ' "$tpl"
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
CADRE_SCRUB_ENV=(CADRE_HOME CADRE_ROOT CADRE_JUDGE CADRE_PROMPT_FILE
                 CADRE_STACK CADRE_TEST_CMD CADRE_ALLOW_SECRETS
                 CADRE_PASS_DIR CADRE_AGENTS_D)
scrubbed_env() {
  local a=(env) v
  for v in "${CADRE_SCRUB_ENV[@]}"; do a+=(-u "$v"); done
  printf '%s\n' "${a[@]}"
}
