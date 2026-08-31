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

# ★ <runs> is POSITIONAL, so anything in that slot becomes the run count. This
# tool's own report printed `cadre grade <spec> --rescore`, which made
# `seq 1 --rescore` produce nothing: zero runs graded, and a 0/0 verdict on a
# candidate whose reviews were all sitting on disk waiting to be read. A number
# taken from an argument position has to be checked as a number.
need_runs() {
  case "${1:-}" in
    ''|*[!0-9]*)
      die "runs must be a whole number, got '${1:-}'.
     Usage is positional: cadre grade <agent-spec> [runs] [pass-label].
     There is no --rescore flag -- 'cadre grade' always re-grades." ;;
  esac
  [ "$1" -gt 0 ] || die "runs must be at least 1, got '$1'"
}

# Filename-safe and INJECTIVE. tr ':/' '--' alone collides: "vendor/model" and
# "vendor-model" share a slug, and the second spec reports the first's results.
slug() {
  local safe h
  safe=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-')
  h=$(printf '%s' "$1" | cksum | cut -d' ' -f1)
  printf '%s-%s' "$safe" "$h"
}


# ---- content identity (#37) --------------------------------------------------
# ★ A benchmark whose inputs are not pinned is not reproducible, however careful
# the grading is. `prompt_bytes` is a SIZE: two prompts that differ but happen to
# be the same length are indistinguishable in the record, and CADRE_PROMPT_FILE
# replaces the brief wholesale, so the input with the largest effect on a review
# is the one the record described least. These hashes close that.
#
# Scope is PROVENANCE, not tamper-proofing. A local hash cannot stop anyone
# editing the tree; it makes a comparison across an edit visible instead of
# silent. docs/ASSURANCE_CASE.md says so where the guarantees are listed.
#
# ★ Never cksum as a substitute. It is already used for slug() where a collision
# costs a filename, but a 32-bit CRC collides often enough that "same hash" would
# stop meaning "same bytes" -- which is the only property these fields are for.
# No sha256 tool on the box means EMPTY, which every consumer already reads as
# unknown; a weaker hash under the same column name would read as measured.
SHA_CMD=""
if command -v sha256sum >/dev/null 2>&1; then SHA_CMD="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA_CMD="shasum -a 256"
fi

# content_sha <file>... -- 12 hex chars over the files' bytes, concatenated in
# the order given. EMPTY if any input is missing: a hash that silently describes
# a subset is worse than none, because it compares equal to a run that had the
# same subset for a different reason.
content_sha() {
  [ -n "$SHA_CMD" ] || return 0
  local f
  for f in "$@"; do [ -f "$f" ] || return 0; done
  [ "$#" -gt 0 ] || return 0
  # shellcheck disable=SC2086  # SHA_CMD may carry an argument (shasum -a 256)
  cat -- "$@" | $SHA_CMD | cut -c1-12
}

# The adapter files that ACTUALLY load for an agent, in agentcall's order.
# ★ BOTH, when both exist. agentcall sources the shipped file and then the user
# one, so hashing only the override describes half of what ran -- the same
# partial-override shape that once left a shipped noprompt_ marker alive
# underneath a user adapter that supported prompts.
adapter_files() {
  local a="$1" d
  for d in "$CADRE_ROOT/agents.d" "${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}"; do
    if [ -f "$d/$a.sh" ]; then printf '%s\n' "$d/$a.sh"; fi
  done
}

adapter_sha() {
  local files=()
  mapfile -t files < <(adapter_files "$1")
  [ "${#files[@]}" -gt 0 ] || return 0
  content_sha "${files[@]}"
}

# One hash over every harness file that shapes a review.
# ★ `cadre:` in the manifest is a git short sha, and it says nothing at all
# while lib/ is dirty -- which is the normal state of the tree whenever any of
# this is being worked on, and exactly when a comparison is most likely to span
# an edit. Content, not revision.
# sort, because find's order is filesystem-dependent and an unstable input order
# would make the same tree hash differently on two machines.
HARNESS_FILES=(lib/common.sh lib/run-review.sh lib/run-pass.sh lib/grade.sh)
harness_sha() {
  local f files=()
  for f in "${HARNESS_FILES[@]}"; do files+=("$CADRE_ROOT/$f"); done
  while IFS= read -r f; do files+=("$f"); done \
    < <(find "$CADRE_ROOT/lib/prompts" -type f -name '*.md' -print 2>/dev/null | LC_ALL=C sort)
  content_sha "${files[@]}"
}

# ★ slots.tsv schema version, stamped on every row THIS harness writes (#20).
# It describes the ROW, not the run: what the columns mean and which rule
# produced them. A row without it is not "version 1", it is UNKNOWN -- rows
# predating this column span the #19 change to what `secs` means on a failed
# seat, and nothing on disk can tell those halves apart after the fact. That is
# why `cadre receipts` groups by it instead of guessing a default.
SLOTS_SCHEMA_V=2

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

# Does this adapter ignore the prompt? coderabbit does: it ships its own review
# contract. Such an adapter cannot synthesize, and its dispatched prompt size is
# zero even when the harness has a shared brief ready for the rest of the panel.
is_promptless() {
  local a="$1" d
  ( for d in "$CADRE_ROOT/agents.d" "${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}"; do
      [ -f "$d/$a.sh" ] && . "$d/$a.sh"
    done
    declare -F "noprompt_$a" >/dev/null ) 2>/dev/null
}

# ---- capability preflight ----------------------------------------------------
# Adapters may declare what they CANNOT do. Undeclared = unrestricted: a missed
# declaration wastes a paid call, it does not lose a review. Loose is safe.
#
# Optional per adapter: cannot_<agent>() prints one tag per line. $model is in
# scope so a multi-provider front-end can key on the model half of the spec.
# Tags currently checked:
#   role:reviewer | role:judge | role:synth
#   prompt:security-audit
# Model-level quirks that are not CLI-level live in model_cannot below so every
# adapter that reaches that model inherits them.

# Model-keyed incapabilities, independent of which CLI fronts the model.
model_cannot() {
  local model="$1"
  case "$model" in
    # Cerebras works as a judge. As a reviewer the API rejects
    # messages.N.assistant.reasoning_content on the 2nd assistant turn after a
    # tool call, so the seat hard-fails after the first tool use.
    cerebras/*) printf '%s\n' 'role:reviewer' ;;
  esac
}

# Print every incapability tag for a seat (adapter + model). Empty = unrestricted.
seat_declarations() {
  local spec="$1" a m d
  a=$(spec_agent "$spec"); m=$(spec_model "$spec")
  model_cannot "$m"
  (
    for d in "$CADRE_ROOT/agents.d" "${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}"; do
      [ -f "$d/$a.sh" ] && . "$d/$a.sh"
    done
    # shellcheck disable=SC2034
    model="$m"
    if declare -F "cannot_$a" >/dev/null 2>&1; then cannot_"$a"; fi
  ) 2>/dev/null
}

# Is this text a security-audit-shaped brief? Mere "security" in a priority list
# is not enough -- that is every review brief. The shape that burns a paid call
# on agy is asking for a vulnerability audit of a codebase.
prompt_is_security_audit() {
  local text="${1:-}" low
  [ -n "$text" ] || return 1
  [ -f "$text" ] && text=$(cat -- "$text")
  low=$(printf '%s' "$text" | tr 'A-Z' 'a-z')
  case "$low" in
    *'security audit'*|*'security-audit'*|*'audit for vulnerabilit'*|\
    *'vulnerabilit'*'audit'*|*'audit this code'*|*'audit this codebase'*|\
    *'audit this repo'*|*'audit the codebase'*) return 0 ;;
  esac
  return 1
}

# Human-readable reason for a declaration, naming the measured quirk when known.
declaration_reason() {
  local spec="$1" decl="$2" m
  m=$(spec_model "$spec")
  case "$decl" in
    role:reviewer)
      case "$m" in
        cerebras/*)
          printf '%s' 'cerebras rejects reasoning_content on the 2nd assistant turn after a tool call' ;;
        *) printf '%s' 'declared unable to serve as a reviewer' ;;
      esac ;;
    role:judge)  printf '%s' 'declared unable to serve as a judge' ;;
    role:synth)  printf '%s' 'declared unable to serve as a synthesizer' ;;
    prompt:security-audit)
      printf '%s' 'returns a refusal, not a review, on security-audit-shaped prompts' ;;
    *) printf '%s' "declared unable ($decl)" ;;
  esac
}

# If the seat is doomed for this role (and optional prompt), print
# "declaration<TAB>reason" and return 0. Otherwise return 1 (clear to dispatch).
# role is one of: reviewer | judge | synth
capability_block() {
  local spec="$1" role="$2" prompt="${3:-}" decl
  while IFS= read -r decl; do
    [ -n "$decl" ] || continue
    case "$decl" in
      role:reviewer)
        [ "$role" = reviewer ] || continue
        printf '%s\t%s\n' "$decl" "$(declaration_reason "$spec" "$decl")"
        return 0 ;;
      role:judge)
        [ "$role" = judge ] || continue
        printf '%s\t%s\n' "$decl" "$(declaration_reason "$spec" "$decl")"
        return 0 ;;
      role:synth)
        [ "$role" = synth ] || continue
        printf '%s\t%s\n' "$decl" "$(declaration_reason "$spec" "$decl")"
        return 0 ;;
      prompt:security-audit)
        [ "$role" = reviewer ] || continue
        prompt_is_security_audit "$prompt" || continue
        printf '%s\t%s\n' "$decl" "$(declaration_reason "$spec" "$decl")"
        return 0 ;;
    esac
  done < <(seat_declarations "$spec")
  return 1
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
    *hunyuan*|hy3*)                                echo tencent ;;
    *mimo*)                                        echo xiaomi ;;
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
  local a m mm=() d rc
  a=$(spec_agent "$CADRE_JUDGE"); m=$(spec_model "$CADRE_JUDGE")
  [ -n "$m" ] && mm=(-M "$m")
  # ★ The judge gets an EMPTY directory, never /tmp. A judge on an agent CLI is
  # a tool user, `-m ro` only stops writes, and /tmp on a real machine holds
  # editor scratch, other agents' session dirs, and -- measured 2026-07-28 -- a
  # 644 copy of this harness's own answer key. A grader rooted there greps for
  # the commit and finds the answers. docs/METHOD.md §3.
  # The tool surface itself is the deeper problem; `agents.d/ollama.sh` is the
  # seat with no tools at all, and is what a judge should use.
  d=$(mktemp -d "${TMPDIR:-/tmp}/cadre-judge.XXXXXXXX") || die "judge: no temp dir"
  # Scrubbed like every other model call. The judge is handed the key by
  # design, but CADRE_WORK in its environment is still a map to trees it has
  # no business in -- the same rule adjudicate_one already follows.
  local sc; mapfile -t sc < <(scrubbed_env)
  "${sc[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
    "$CADRE_ROOT/bin/agentcall" "$a" "${mm[@]}" -d "$d" -m ro
  rc=$?
  # rmdir, not rm -rf: -m ro means nothing should have been written, and if
  # something was, failing to delete it is the signal worth keeping.
  rmdir "$d" 2>/dev/null || true
  return $rc
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

# Findings the review states, counted in the three shapes reviewers actually
# emit:
#   codex        1. **blocking** - [file:line](...)
#   grok/claude  ### 1. blocking - ...
#   coderabbit   - [major] path/to/file.ts
# Deliberately loose. Callers only ever compare against small thresholds, so
# over-counting a stray line costs nothing and under-counting hides a bug.
# Lives here, not grade.sh: classify_run needs it and run-pass/run-review
# source only this file.
#
# ★ The bracket shape is coderabbit's and it was missing, which disarmed
# judge_incoherent() for an entire reviewer family. Measured across three real
# panels: coderabbit reviews declaring findings=3, findings=13 and findings=3
# all counted 0 here, because the severity arrives as `[major]` and the prefix
# only allowed asterisks. judge_incoherent() needs >= 2 to fire, so a judge
# could return "no defects found" with extras [] against a thirteen-finding
# review and score clean -- the exact failure that check was built for, silently
# switched off for the one reviewer that ships its own output format.
# Under-counting is still possible (coderabbit also emits [minor]/[warning],
# which are not review vocabulary and stay out on purpose); the threshold
# callers use only needs two.
review_findings() {
  # ★ The backtick belongs in the leading-markup class, and leaving it out
  # discarded whole reviews. Measured 2026-08-02: gemini-3.1-pro writes its
  # severities as `### ` + backtick + should-fix, which is ordinary markdown, and
  # every one of them scored zero findings. Paired with no closing verdict that
  # is exactly classify_run's inconclusive test, so a 2.5KB review naming a real
  # priority-lookup bug, an unvalidated status transition and a stray committed
  # file was binned as "returned text but no review" and never reached a judge.
  # A format habit read as a model failure. Adding it only ever ADDS matches:
  # checked against every run in the corpus on this machine, not one existing
  # review changes its count, so no historical grade moves.
  #
  # ★ The LABELED FIELD is the same story one step further, and it is how that
  # seat writes most of its severities:
  #
  #   * **Severity**: `should-fix`
  #   * **Rating:** `should-fix` (real bug, bounded blast radius)
  #   * **Consequence**: `should-fix` (correctness bug reaching production)
  #
  # The severity is a field VALUE mid-line, so the anchor missed all of it and
  # 7 of 8 reviews in one sweep -- 27KB naming a Drizzle `IN ${array}` that
  # throws at runtime, a scope filter showing every chain modifier, a stray
  # committed file -- were binned "returned text but no review". The optional
  # group below admits ONE short bolded label before the severity and nothing
  # else, so the anchor still holds: the severity must be at the head of the
  # line or immediately behind its own label. Note `:?` INSIDE the asterisks as
  # well as after, because both `**Rating:**` and `**Severity**:` occur.
  #
  # Measured before landing. On the corpus: no existing review changes its
  # count. On prose that must stay silent: "this is not blocking", "**Note**:
  # nothing critical here", "not a nit, but worth noting", and the nastiest one,
  # "**Summary:** no major issues found" -- all still zero.
  # ★ ...and the markup class before the NUMBER, because the same seat also
  # bolds the whole heading: `#### **1. ` + backtick + `should-fix`. The bold
  # opens ahead of the digit, so the number group could never match and the
  # eighth review of that sweep stayed at zero after the label fix rescued the
  # other seven. Still anchored: everything admitted here is markup, a list
  # number, or one short label, and the severity has to arrive immediately after
  # it. Probed against `**Overall:** no critical problems` and `*not a nit* but
  # worth noting` -- both stay zero, as does the whole corpus.
  grep -cEi "$SEVERITY_RE" "$1"
}

# ★ ONE definition, two callers, and that is a correctness rail rather than
# tidiness. This function COUNTS severity lines; lib/engine/ EXTRACTS them for
# claims[]. A second copy of the pattern over there would drift the moment either
# side is tuned -- and drift silently, because nothing in cadre compares the two
# numbers: a review counted at 13 findings and projected as 4 both look fine
# alone. Same pattern, `-c` here and `-n` there.
#
# SEVERITY_WORDS is split out for the same reason. The extractor needs the
# vocabulary alternation on its own to pull the severity back off a matched line,
# and spelling that list twice is how the two ends stop agreeing about what a
# severity is. Every documented near-miss above is a change to the PREFIX; the
# vocabulary itself has been stable, which is exactly why it is safe to share.
SEVERITY_WORDS='blocking|should[ -]fix|must[ -]fix|nit|critical|major'
SEVERITY_RE='^ *(#{1,6} *)?[*_`]*([0-9]+[.)]|[-*+])? *(\*\*[A-Za-z][A-Za-z ]{0,18}:?\*\*:? *)?[*_[(`]*('"$SEVERITY_WORDS"')\**'

# Did this review state a BOTTOM LINE? Not "is it any good" -- only whether the
# reviewer answered the question it was asked. Two legal forms, both already in
# cadre's own artifacts:
#   prose        review-live.md:29 asks every reviewer to end with a one-line
#                overall verdict: blocking, should-fix, or ship it.
#   declaration  coderabbit takes no prompt and opens with `findings=N`.
#
# ★ EDGE-anchored, and that is the whole trick. A verdict is the LAST thing a
# review says and coderabbit's count is the FIRST, so both live at an edge --
# while the middle of a review of THIS repo is full of the same words, because
# cadre's own source and tests contain "ship it", "no defects found" and
# "verdict". Measured: an unanchored scan passed all three of the non-reviews
# below, every one of them a file that had merely quoted cadre's diff. Same
# collision the _TRUNCATED check hit for the same reason, and the same fix.
#
# ★★ WHICH WAY THIS FAILS, because an earlier version of this comment had it
# exactly backwards and a cross-model review caught it. The rule is
# `inconclusive == no findings AND no verdict`, so:
#
#   a phrasing this MISSES     -> a real clean review is filed `inconclusive`,
#                                 dropped from the synthesis. EXPENSIVE.
#   a phrasing it OVER-matches -> a non-review keeps its `ok`, which is merely
#                                 the behaviour of every version before this one.
#
# So LOOSE IS SAFE HERE and tight is dangerous, which is the opposite of the
# instinct this function invites. If you are adding a pattern, add it. If you are
# about to remove one to make the gate "sharper", you are about to start binning
# real reviews. The accepted cost of that choice is named at the bottom.
# ★ Chrome is stripped off both edges first, for the same reason the emptiness
# check above strips it: a verdict wrapped in a CLI's colour escapes is still a
# verdict, and the anchored patterns below would not see past the escape bytes.
# opencode puts a reset on the same line as the model's text, which is exactly
# how `findings=0` would have stopped counting as a bottom line and taken a valid
# coderabbit-shaped review down with it. A LITERAL escape byte, never `\x1b` --
# that is a GNU sed extension, BSD sed reads it as a literal `x1b`, and this
# whole strip would silently no-op on macOS. That bug has already been paid for
# once in this function.
# ★ NO `\b`. It is a GNU grep extension; BSD grep is what macOS ships, and there
# `verdict\b` searches for the literal `verdictb` -- so every "Verdict: ship it"
# would stop matching on an entire platform, silently, and file real reviews as
# non-reviews. Same class of bug as the `\x1b` one above, caught by a
# cross-model review of this commit. Dropping it only makes the pattern looser,
# which is the safe direction per the failure model above.
#
# ★ `pipefail` + `grep -q` is a REAL bug in this repo -- see agent_installed()
# above, where exactly that shape SIGPIPEd its producer and declared installed
# adapters missing, at a cost of 43 failing tests. Two independent reviews of this
# commit flagged these two pipelines for the same reason, and they were right to.
#
# The difference is the BOUND, and it is the only thing making this safe:
# `agent_installed` piped an unbounded listing, where `grep -q` really can leave
# before the producer finishes. `head -6` and `tail -12` cap the stream at a dozen
# short lines, which fits the pipe buffer whole, so `sed` is always done writing
# before `grep` exits. Measured on a 5001-line artifact whose match is the first
# line of the window: rc=0.
#
# So: if you widen these windows to something unbounded, or drop head/tail, this
# becomes agent_installed's bug and it fails by binning real reviews. Capture into
# a variable instead, the way that function had to.
has_verdict() {
  local esc; esc=$(printf '\033')
  local strip="s/${esc}\[[0-9;?]*[a-zA-Z]//g"
  # The top: coderabbit's declaration (it takes no prompt, so it is never asked
  # for the prose verdict), and a reviewer that LEADS with its verdict instead of
  # ending with one. The brief says end with it and all 13 measured clean reviews
  # do, but a review that opens "Verdict: ship it" and then explains itself would
  # otherwise be binned, and that is the expensive direction.
  # ★ Only the LINE-ANCHORED verdict pattern is safe to ask up here. The loose
  # phrases below match anywhere in a line, and a review that opens by quoting a
  # diff -- `+  echo "... or ship it."` -- is a real measured shape, so letting
  # those run against the head would undo the anchoring this function exists for.
  # `+` is deliberately not in the leading-markup class for that reason.
  # ★ Six lines, not three, and the declaration is matched loosely: reviewers
  # write `**findings=0**`, `Findings: 0` and `findings = 0`, and a heading or a
  # blank line ahead of a `## Verdict` section pushes it off line 3.
  if head -6 "$1" | sed "$strip" \
       | grep -qiE '^[-*_#> `]*(findings *[:=] *[0-9]+|(overall +)?verdict)'; then return 0; fi
  # Everyone else's, at the bottom. review-live.md asks for one line, last -- but
  # 12 lines, not 1, because a CLI or wrapper that appends a sign-off block pushes
  # a real verdict up out of a tight window.
  #
  # ★ The closer list is long because it is a list of things REAL reviewers write
  # when they found nothing, and every one missing from it is a real review binned.
  # "no defects found" alone was not enough: "no issues found", "nothing to flag",
  # "LGTM", "approved", "all good", "safe to merge" are all ordinary sign-offs, and
  # the brief's own three words are not the only way a model ends a clean review.
  # Grow this list freely; see the failure model above for why that is the safe
  # direction.
  #
  # ★ THE ACCEPTED COST, named so nobody claims more for this gate than it does.
  # A deflection that dresses itself as a bottom line keeps its `ok`: a model
  # ending "Verdict: I cannot review this, please clarify" matches the anchored
  # verdict pattern and sails through. So does "no blocking changes intended in
  # this refactor". Of the three measured non-reviews none did this, and tightening
  # to catch it means reading the verdict for MEANING, which is the substance
  # judgement the README's non-goal is about. This gate answers one structural
  # question -- did the reviewer state a bottom line at all -- and deliberately
  # stops there.
  tail -12 "$1" | sed "$strip" | grep -qiE '(ship[ -]it|lgtm|looks good|approved?|no (defects|issues|problems|concerns|bugs|blockers)|nothing (worth )?(to )?(flag|report|fix|filing|flagging|flagged)|all (good|clear)|(safe|ready|ok) to merge|recommend merging|^[-*_#> `]*((overall +)?verdict|conclusion|recommendation)|no (blocking|defects)[a-z ]*(found|here)?)'
}

# The NARROW form of has_verdict, for exempting a short zero-finding review
# from the rate-limit scan: a labelled verdict line, or one of the unambiguous
# bottom-line idioms. Deliberately without has_verdict's bare `approved?`,
# `looks good`, `conclusion` and `recommendation`, each of which a refusal can
# say ("Request not approved: 429", "Recommendation: retry after 60s").
explicit_verdict() {
  local strip='s/^[[:space:]]*//;s/[[:space:]]*$//'
  tail -12 "$1" | sed "$strip" | grep -qiE '(^[-*_#> `]*(overall +)?verdict[: *_]|\b(ship[ -]it|lgtm|safe to merge|recommend merging|no (defects|issues|problems|bugs|blockers) (found|here))\b)'
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

# Did the reviewer's ENVIRONMENT stop it before it reviewed? #28. Measured
# 2026-08-24 on a live panel: codex's shell tool died under bwrap
# (`loopback: Failed RTM_NEWADDR: Operation not permitted`), the model wrote
# 334 bytes saying it could not inspect the diff, added "Overall verdict:
# should-fix" of its own accord, and exited 0. No adapter marker, no rate-limit
# keyword, and has_verdict rescued it from `inconclusive` -- so a seat that
# reviewed nothing was counted `ok` and its silence cleared the whole diff.
#
# ★ Same guards as rate_limited and for the same reason: a small file, and the
# caller also demands findings=0. A real review that quotes "permission denied"
# from the diff states findings, and a real review is not this short. The
# model's own verdict line does NOT rescue it: a verdict on a review that never
# happened is the exact fabrication this exists to catch.
# ★ Two halves, both required: a tool/sandbox error signature AND the model
# saying it could not look. Either alone is too loose -- a reviewer of sandbox
# code quotes bwrap, and "unable to access" alone is the request-for-
# clarification shape that already lands in `inconclusive`.
env_blocked() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f")" -le 2000 ] || return 1
  grep -qiE '(bwrap:|sandbox|operation not permitted|permission denied|EPERM|EACCES|execution environment|tool call(s)? (failed|error)|command(s)? failed)' "$f" || return 1
  # ★ The second half names the DIFF as the thing it could not reach, never a
  # test run. Measured on the bot box's 758 artifacts: "could not execute the
  # tests in the sandbox" is a routine caveat in five genuine clean reviews, and
  # a looser "could not (run|execute)" binned every one of them.
  # ★ And FIRST PERSON. "the diagnostic reports permission denied when the
  # sandbox cannot access the repository" is a clean review OF such code, not a
  # reviewer that was stopped; "I could not inspect the diff" is. Found by the
  # codex review of this change.
  grep -qiE "\bI (could ?n[o']t|was unable to|am unable to|cannot|can ?not) (review|inspect|read|access|open|examine|see) (the |this |any )?(change|changes|diff|code|files?|source|repo|repository)|(^|\bI am |\bI was )unable to (complete|perform|do) (the |a |this )?review|\b(my |this |the )review (was |is )?blocked|failed before execution" "$f"
}

# ★ A BUDGET refusal, which is a different animal from a rate limit, and telling
# them apart is worth a function. Both look like "the provider said no". The
# difference is whether waiting inside this sweep can clear it:
#
#   rate limit  -- a throughput ceiling. Backoff clears it. Retry the same model.
#   budget      -- an account state. No backoff clears it, so every later attempt
#                  is guaranteed waste, and the sweep should stop USING THAT
#                  AGENT and say so at the top of its voice.
#
# Measured, both on the same overnight run, from opposite starting points:
#   claude  "You've hit your monthly spend limit"    matched NOTHING above, so
#           each pass failed in about a second and the sweep marched through
#           eleven more of them writing 102-byte .failed files for fifty minutes.
#   kimi    "429 ... suspended due to insufficient balance"  matched the scan
#           above, so it burned three backoff retries against an account that
#           had no balance to serve them.
# One silent hour and one pointless retry storm, from the same missing
# distinction. Checked BEFORE rate_limited for that reason.
#
# Same guards as rate_limited and for the same reason: a small file, and callers
# ask only about a run classify_run already called `failed`. A review that merely
# DISCUSSES billing is neither small nor failed. The failure direction is safe
# too -- an unrecognised phrasing falls through to the retry path, which is what
# happens today.
quota_exhausted() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f")" -le 2000 ] || return 1
  # ★ The discriminator is the PERIOD WORD, not the word "quota". A bare "quota
  # exceeded" must stay a RATE limit: agents.d/kiro.sh records "Kiro rate limit
  # reached: Request quota exceeded", which is a throughput refusal a backoff
  # really does clear. Attach a month/day/plan to it and it is a budget instead.
  # This distinction is the entire reason the two functions are separate, so the
  # patterns below never match "quota" on its own.
  grep -qiE '(spend limit|usage limit|monthly limit|plan limit|insufficient (balance|funds|credit|quota)|recharge your account|credit balance is too low|(account|organization|org)[a-z0-9 _<>-]{0,40}(is )?(suspended|deactivated|disabled)|payment required|\b402\b|billing (details|issue|problem)|purchase (more )?credits|exceeded your (monthly|daily|weekly|annual|yearly|plan)[a-z ]{0,20}quota|(monthly|daily|weekly|annual|yearly) (quota|allowance)|quota (exceeded|exhausted)[^.]{0,40}(month|billing period|plan))' "$f"
}

# ★ A THIRD refusal, and the reason it needs its own function is that the two
# above prescribe the wrong ACTION for it. Measured 2026-07-28, on the candidate
# this whole benchmark is about:
#
#   You've hit your session limit · resets 7:10pm (America/New_York)
#   You've hit your weekly limit  · resets 5am (America/New_York)
#
# Neither matched rate_limited NOR quota_exhausted, so a run failed in two
# seconds with zero retries and the sweep stopped 26 reviews into 30 -- four
# minutes before the window it was waiting on reopened.
#
# Filing it under either existing bucket is wrong, not just imprecise:
#   as a rate limit -- three retries over ~7 minutes (60/120/240). A reset hours
#                     away outlasts that, and then every remaining pass retries
#                     and fails: the kimi burn quota_exhausted exists to end.
#   as a budget     -- skips the agent for the whole sweep and reports a FAILED
#                      MEASUREMENT. Waiting really does clear a usage window, so
#                      that discards a candidate that would work fine in 20
#                      minutes, and calls a wall clock a defect.
# So the action is its own: stop, keep everything, resume after the stated time.
# Exit 6 carries it. See lib/run-pass.sh.
#
# ★ The discriminator is a STATED RESET, not the period word -- which is what
# separates this from quota_exhausted, whose own claude case is
# "monthly spend limit · raise it at claude.ai/settings/usage": no reset time,
# because only money lifts that one. A limit that tells you when it lifts is
# waitable; a limit that tells you where to pay is not.
#
# Deliberately NOT matching "rate limit ... resets in 60s": a throughput ceiling
# with a short reset belongs on the retry path, where backoff already handles it.
# Only a named USAGE WINDOW counts here.
#
# ★ Checked BEFORE quota_exhausted, and that order is load-bearing rather than
# arbitrary. quota_exhausted's pattern list contains `usage limit`, which is a
# WINDOW phrasing sitting in the budget matcher -- and which was added
# speculatively in 96b9697 rather than from any observed string. Ask the budget
# first and "You've hit your usage limit · resets 3pm" gets the budget treatment
# this function exists to disprove: agent dropped for the whole sweep, exit 4,
# "fix the cause". Asking here first makes the stated reset the authoritative
# discriminator instead of an accident of call order.
#
# Safe against every refusal in the corpus, checked one by one: the spend cap
# says "raise it at", the suspended account says "recharge your account", the
# periodic quotas say "billing period" -- not one of them states a reset, so not
# one of them reaches this function's second test. A future "monthly usage limit
# · resets Aug 1" would land here instead of in quota_exhausted, which is
# correct: it resets, so waiting clears it.
provider_window_closed() {
  local f="$1"
  [ -s "$f" ] || return 1
  [ "$(wc -c < "$f")" -le 2000 ] || return 1
  # ★ `quota reached` earns its place here rather than in quota_exhausted, and
  # the two are one word apart. Measured 2026-08-02, agy on a bundled plan:
  #
  #   Individual quota reached. Please upgrade your subscription to increase
  #   your limits. Resets in 4h22m55s.
  #
  # It matched NOTHING -- not this function (it says "your limits", never
  # "usage limit"), not quota_exhausted (no period word), not rate_limited. So
  # the sweep aborted on its first pass, filed a 4-hour clock as a failed
  # measurement, and left 11 passes NOT ATTEMPTED. Exactly the case the comment
  # above describes, arriving through a phrasing the pattern did not cover.
  # The upgrade pitch is a red herring: it states a reset, so waiting clears it.
  # Safe against kiro's "rate limit reached: Request quota exceeded" -- that is
  # `quota exceeded`, stays on the retry path where a throughput ceiling belongs.
  # ★ A MODEL-TIER window is the one shape that states NO reset, so it gets
  # its own two-half test rather than another alternative in the pattern below,
  # which the `reset` requirement would refuse anyway. Measured 2026-08-30
  # benchmarking the claudecr seat (#48), verbatim:
  #
  #   You've reached your Fable 5 limit. Switch to another model to continue.
  #
  # It matched nothing at all -- no 429, no period word, no stated reset -- so
  # it fell through to `inconclusive` and one spent model tier was reported as a
  # failed measurement of the candidate. The account was healthy: the five-hour
  # bucket sat at 5% and the all-model weekly at 59%, and only the one tier was
  # at 100%. Its reset is real and knowable, it just lives in the usage endpoint
  # and not in the message.
  #
  # So the REMEDY stands in for the reset as the discriminator. "Switch to
  # another model" is a sentence only a PER-MODEL window can say: a spend cap
  # names a payment page ("raise it at", "recharge your account") precisely
  # because no other model on the account would help.
  #
  # ★ The remedy has to be ISSUED, not mentioned -- start of a line or start of
  # a sentence. Both halves alone were not enough, measured against this repo's
  # own prose while writing the fix:
  #
  #   blocking: the retry path reached your rate limit ceiling and should
  #   switch to another model provider
  #   The docs say you have reached your quota limit; the fix is to switch to
  #   another model.
  #
  # Both matched, and the second one has no findings and no verdict, so it
  # would have reached classify_run's guards and STOPPED A SWEEP over a review.
  # A refusal instructs; prose refers. The real string ends the previous
  # sentence first: "... limit. Switch to another model to continue."
  #
  # ★★ AND IT YIELDS TO THE OTHER TWO, which is the opposite of the rule the
  # stated-reset branch below follows. That branch deliberately claims
  # "You've hit your usage limit - resets 3pm" out of quota_exhausted's hands,
  # because a stated reset PROVES waiting clears it. A remedy proves nothing of
  # the kind, and a multi-model router can phrase either of the others this way:
  #
  #   You've reached your rate limit. Switch to another model to continue.
  #   You've reached your monthly spend limit. Switch to another model to continue.
  #
  # Window is asked FIRST in both dispatch paths, so without this a throughput
  # ceiling loses its retries and -- far worse -- a spend cap is reported as a
  # clock that will clear itself, and the operator waits out a window that money
  # is the only thing that opens. Found by the codex review of this change.
  if grep -qiE 'reached your [a-z0-9. ]{0,20}limit' "$f" \
     && grep -qiE '(^|[.!?][[:space:]]+)switch to another model' "$f" \
     && ! rate_limited "$f" && ! quota_exhausted "$f"; then return 0; fi
  grep -qiE '(session|weekly|daily|hourly|usage|[0-9]+[ -]?hour) limit|quota reached' "$f" || return 1
  grep -qiE 'reset' "$f"
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

# Does this artifact hold nothing at all? THE one copy of the chrome strip.
#
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
# ★ Extracted from inside classify_run (#12) because the answer is needed TWICE
# and used to be computed once and thrown away: classify_run asks it to reach
# `failed`, and the reporters ask it to say WHICH failure. A second copy at each
# print site would be the free-text-grep debt #2 exists to delete, so there is
# one function and three renderers over it.
content_empty() {  # <file> -> 0 when the file holds no content
  local f="$1"
  [ -s "$f" ] || return 0
  local esc; esc=$(printf '\033')
  [ -z "$(sed -e "s/${esc}\[[0-9;?]*[a-zA-Z]//g" -e 's/[[:space:]]//g' "$f")" ]
}

# ★ WHICH nothing (#12). Three root causes rendered one identical line -- a
# `FAILED after Ns (rc=124)` that meant, on the same opencode-go sweep:
#   1. the adapter was ALIVE and producing (a 72KB transcript) and cadre's own
#      clock killed it. Raising CADRE_TIMEOUT turned that exact pass into a
#      graded blocking HIT.
#   2. the provider returned NOTHING -- 2 bytes, two newlines -- and burned the
#      full timeout doing it. A whole-sweep streak of this was a provider
#      OUTAGE: every model hung on `Reply with exactly: OK`.
#   3. a genuine refusal / capability block, which classify_run already splits.
# Read as one message, case 1 is a verdict about the MODEL manufactured out of a
# harness kill. That is the fabricated-grade failure mode, so the split is not
# cosmetic.
#
# ★ This does NOT return a new classify_run state, and must not. Three call
# sites string-compare that function (`= failed || break` in run-pass.sh and
# run-review.sh, `!= ok` in bin/cadre); a fourth bucket would silently rewire
# their retry loops. Same `.failed` bucket, different operator-facing line.
#
# ★ CONTENT-EMPTY WINS over the timeout code, because case 2 is both: nothing
# came back AND the clock ran out. "The provider sent nothing" is the actionable
# half; "raise the timeout" would be advice that cannot help.
#
# rc is OPTIONAL. `cadre grade` re-reads .failed artifacts off disk long after
# the exit code is gone, and the content discriminator still works there -- so
# with no rc the timeout case is simply not claimed rather than guessed at.
# The one copy of the misconfiguration markers, and the line that matched --
# the renderers quote it, so a marker on line 2 or 3 is quoted, not line 1.
CADRE_MISCONF_RE="^(NOT INSTALLED: [^ ]+ is not on PATH|agentcall: (unknown agent '|[^ ]+ takes no model, drop|no such directory: |mode must be ro or rw|no prompt \\()|DID NOT RUN, misconfigured: )"
misconfigured_line() {  # <file> -> the matching marker line, or ""
  head -3 "$1" 2>/dev/null | grep -E -m1 "$CADRE_MISCONF_RE"
}

failure_kind() {  # <file> [rc] -> misconfigured | no-output | timed-out | failed
  local f="$1" rc="${2:-}"
  # ★ FIRST, ahead of every provider-shaped answer (#31): these are things the
  # OPERATOR did, and they are fixed on this box -- a roster member not on
  # PATH, a spec with a model on an adapter that takes none, a seat with no
  # adapter file at all. None of it is evidence about a reviewer, and a sweep
  # that files it as a reviewer failure manufactures a verdict on a model that
  # was never called. Every marker here is one the HARNESS writes (run-review
  # / run-pass's NOT INSTALLED line, agentcall's own die), plus one an adapter
  # may opt into when its CLI reports a fault it can attribute to configuration
  # rather than the provider: `DID NOT RUN, misconfigured: <why>`.
  # Same rails as the other kinds: renderer layer only, classify_run's four
  # states untouched, so the retry loops keep string-comparing `failed`.
  # ★ Whole harness sentences, not their first words: a reviewer of THIS repo
  # opening with "NOT INSTALLED handling is too broad" is a review, and the
  # first draft of this check filed it as a seat that never ran.
  if [ -n "$(misconfigured_line "$f")" ]; then echo misconfigured; return 0; fi
  if content_empty "$f"; then echo no-output; return 0; fi
  # ★ THE ADAPTER'S OWN VERDICT BEFORE THE EXIT CODE, the same rail classify_run
  # follows and for the same reason: the adapter is the only layer that watched
  # the run. This is not decoration here, it is most of the roster. Adapters
  # NORMALISE their exit code on a clock kill -- agents.d/codex.sh:107 prints
  # "codex was killed at the 900s timeout with no output" and then returns 0,
  # because the trailing `rm -f` is the last command in the function. So for the
  # codex family, and for agy.sh:137, the rc test below can NEVER see the
  # timeout, and the case this whole issue is about would keep printing FAILED.
  # Measured on codex 0.145.0, where `-o` is written only at final completion:
  # a mid-turn kill leaves it empty, so this branch is the COMMON codex timeout,
  # not the rare one.
  # ★ head -3 for the reason classify_run anchors its markers there: past the
  # edge, a timeout sentence is the reviewed code or a reviewer quoting one.
  # Over-claiming here is cheap in a way it is not elsewhere -- failure_phrase
  # is only ever asked about a run already binned `failed`, so the worst case is
  # a wording change, never a bucket change and never a score.
  if head -3 "$f" | grep -qE '^(DID NOT RUN|DID NOT COMPLETE).*[0-9]+s timeout'; then
    echo timed-out; return 0
  fi
  # 124 is GNU timeout's "the command timed out"; 137 is the -k SIGKILL landing
  # as 128+9 on a child that ignored the TERM. bin/agentcall wraps every adapter
  # in `timeout -k 30 "$TIMEOUT"`, so both codes are CADRE'S clock, not the
  # provider's -- which is exactly the confusion this exists to end.
  case "$rc" in 124|137) echo timed-out; return 0 ;; esac
  echo failed
}

# The operator-facing phrase for a failed run. Renderers append their own
# "kept as X" suffix.
#
# ★ Names CADRE_TIMEOUT and its current value. It took a `bin/agentcall` grep to
# learn the knob existed and that rc=124 was cadre's own clock rather than the
# provider's; a message that costs a source dive to act on is a message that
# does not work. Default mirrors bin/agentcall:33 -- if that number moves, move
# this one.
# ★ Vocabulary is agents.d/codex.sh's ("killed at the Ns timeout", "with no
# output", "Raise CADRE_TIMEOUT"), not a third phrasing for the same split.
# ★ rc=0 is NOT printed. A failure line carrying `(rc=0)` sends an operator
# hunting for a crash that never happened -- which is this issue's own disease
# in miniature, and it is not hypothetical: an adapter that normalises its exit
# code produces exactly that line. No exit code beats a meaningless one.
failure_phrase() {  # <file> <rc> [secs] -> leading phrase, no trailing period
  local f="$1" rc="$2" secs="${3:-}" after="" rcp="" tmo="${CADRE_TIMEOUT:-900}"
  [ -n "$secs" ] && after=" after ${secs}s"
  case "$rc" in ''|0) ;; *) rcp=" (rc=$rc)" ;; esac
  case "$(failure_kind "$f" "$rc")" in
    no-output)
      local burned=""
      case "$rc" in 124|137) burned=", burning the full ${tmo}s CADRE_TIMEOUT" ;; esac
      echo "NO OUTPUT$after$rcp: the provider returned nothing$burned" ;;
    # ★ Says HOW it ended, and deliberately does not say how much the run had
    # produced. Both routes into `timed-out` land here and they disagree on
    # that: an rc=124 kill means the adapter was mid-flight, while the codex
    # marker means the clock ran out with nothing written yet. The artifact
    # itself states which, and a phrase that guessed would be a claim about the
    # model built from a harness setting -- the exact move this issue exists to
    # stop, one level up.
    timed-out)
      echo "TIMED OUT$after$rcp: killed at the ${tmo}s CADRE_TIMEOUT, so this is cadre's clock and not a verdict on the model -- raise CADRE_TIMEOUT and re-run" ;;
    # ★ Quotes the harness's own line, because it already names the fix (the
    # binary, the spec, the adapter). No rc: the seat never ran, so there is
    # no exit status that means anything about it.
    misconfigured)
      echo "MISCONFIGURED$after: $(misconfigured_line "$f" | cut -c1-160) -- a fault on this box, not a verdict on the model; fix the roster or the install and re-run" ;;
    *)
      echo "FAILED$after$rcp" ;;
  esac
}

# ---- the per-run record (#2) ------------------------------------------------
# ★ Why this exists. Every adapter's stdout IS its own format, so status and
# timing were recovered by grepping prose: run-review.sh reconstructed a seat's
# elapsed seconds with `sed -n 's/.*in \([0-9]*\)s.*/\1/p'` over its own console
# log. That is a FIELD being parsed back out of a sentence, and the sentence was
# written to a scratch file the panel deleted on the way out -- so the first
# fourteen panels' timings are simply gone, not reconstructible, because no
# artifact on disk carries them.
#
# ★ Written DURING the panel, not assembled after it. That is the whole point of
# the append-only shape: a panel killed halfway still leaves a record of every
# seat it dispatched. Assembling at the end means a kill loses everything.
#
# ★ EMPTY IS NOT ZERO, and JSON `null` is why this is JSONL rather than another
# TSV. A seat whose seconds were never measured must not carry a 0 that averages
# like a real measurement and pulls every mean toward the floor -- the rule
# aggregate.sh and grade.sh already follow, now with a type that can express it.

# The relaxed JSON slice, on stdin: drop fence lines, then take the first `{` to
# the LAST `}`. Survives prose on either side of the block and an unbalanced
# brace inside a string, which the balanced scan in grade.sh cannot -- that scan
# stays first, because on a reply echoing prompt text with braces it finds the
# clean object and this slice would not.
#
# ★ ONE copy, because there were two that had to agree: grade.sh's fallback and
# the settle judge in bin/cadre. #26.
#
# ★ No `RS`. Both copies slurped by setting awk's record separator to a NUL,
# which is a gawk extension: in awk source `"\0"` is a NUL-terminated
# string, so an awk that reads it as C does sees the EMPTY string -- which is
# awk paragraph mode, splitting on blank lines instead of slurping. A judge that
# answers with prose, a blank line, then a fenced JSON block would leave the
# JSON in a later record, `index($0,"{")` would find nothing, and a judge that
# answered correctly would be reported as one that "failed or stopped early".
# In settle that direction is worse than a wrong answer, because its exit status
# is a stopping rule and an empty match reads as "nothing new is left".
# NOT REPRODUCED: this box has only gawk, which slurps under --posix and
# --traditional too, and no BSD awk was available to confirm the paragraph-mode
# read. The RS dependency is removed rather than the failure measured. README
# names bash 4.4+ and macOS, and a test already bans GNU-only sed/grep escapes
# for the same reason, so the portable form is the one to ship either way.
# Accumulating in END is identical on gawk: same first-{ to last-} over the
# same bytes.
extract_json_slice() {
  sed -e '/^[[:space:]]*```/d' \
  | awk '
      { buf = buf $0 "\n" }
      END {
        i = index(buf, "{"); if (!i) exit 1
        s = substr(buf, i)
        for (k = length(s); k > 0; k--)
          if (substr(s, k, 1) == "}") { printf "%s", substr(s, 1, k); exit 0 }
        exit 1
      }'
}

# One field value, escaped for JSON. Backslash BEFORE quote, or the escape this
# adds is itself re-escaped. Control characters are dropped rather than encoded:
# one event is one LINE, and a stray newline inside a value would split it into
# two malformed records.
# ★ No `\t` in the sed script. BSD sed reads it as a literal `t` -- the same trap
# that silently disarmed the chrome strip on macOS. `tr` handles the whole
# control range in one pass and is portable.
json_escape() {
  printf '%s' "${1:-}" | tr -d '\000-\037' | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# record_event <logfile> <name>=<value>...
#
# Appends ONE JSON object as ONE line. A name ending in `#` is numeric: it is
# emitted bare, or as `null` when the value is empty. Every other name is a
# string, and an empty value stays `""` -- an unmeasured NUMBER and an empty
# STRING are different facts and the record keeps them apart.
#
# ★ Atomic by construction, because seats run in parallel under --jobs and this
# is the first file in that path two writers touch at once. One event is one
# `printf` of one short line to a file opened O_APPEND, which is well under the
# 4KB a write is guaranteed not to be torn at. Anything that built the line in
# two writes, or seeked, would interleave.
record_event() {
  local log="$1"; shift
  local out="" nv n v sep=""
  for nv in "$@"; do
    n=${nv%%=*}; v=${nv#*=}
    if [ "${n%\#}" != "$n" ]; then
      n=${n%\#}
      out="$out$sep\"$(json_escape "$n")\":${v:-null}"
    else
      out="$out$sep\"$(json_escape "$n")\":\"$(json_escape "$v")\""
    fi
    sep=","
  done
  printf '{%s}\n' "$out" >> "$log"
}

# record_rows <logfile> <event> <key>...
#
# One tab-separated row per matching event, in file order, with the requested
# keys in the order given. A key the record does not carry, or one holding JSON
# `null`, prints EMPTY -- never 0, never the string "null".
#
# ★ Parsing our OWN flat schema, which is the distinction #2 draws: a field read
# from a record cadre wrote is not the same act as a regex over whatever an
# adapter chose to print. Values are scanned character by character rather than
# with a greedy pattern, so an escaped quote inside a spec name cannot end the
# string early.
record_rows() {
  local log="$1" want="$2"; shift 2
  [ -s "$log" ] || return 0
  awk -v want="$want" -v keys="$*" '
    function val(line, key,   i, n, c, out, esc) {
      i = index(line, "\"" key "\":")
      if (i == 0) return ""
      i += length(key) + 3
      c = substr(line, i, 1)
      if (c != "\"") {                      # bare token: number, null, bool
        out = ""
        while (i <= length(line)) {
          c = substr(line, i, 1)
          if (c == "," || c == "}") break
          out = out c; i++
        }
        return (out == "null") ? "" : out
      }
      i++; out = ""; esc = 0
      while (i <= length(line)) {
        c = substr(line, i, 1)
        if (esc) { out = out c; esc = 0 }
        else if (c == "\\") esc = 1
        else if (c == "\"") break
        else out = out c
        i++
      }
      return out
    }
    BEGIN { nk = split(keys, k, " ") }
    {
      if (val($0, "event") != want) next
      row = ""
      for (j = 1; j <= nk; j++) row = row (j > 1 ? "\t" : "") val($0, k[j])
      print row
    }
  ' "$log"
}

# Classify one agent run: ok | degraded | inconclusive | failed. THE one copy of
# this rule.
#
# ★ FOUR states, and each one answers a different question about the same file:
#   ok            a review, complete.
#   degraded      a review, cut short. Findings real, silence is not clearance.
#   inconclusive  ran fine, produced text, never reviewed. See the bottom of
#                 this function -- it is the newest and the least obvious.
#   failed        no usable output at all.
# `inconclusive` and `failed` behave the same downstream (excluded from
# synthesis, never scored, retried) and are still kept apart, because the report
# and slots.tsv have to tell an operator WHICH of the two happened: "the CLI
# broke" sends you to the adapter, "the model would not hold the contract" sends
# you to the roster, and calling the second one FAILED sends you hunting for a
# crash that never happened.
#
# ★ `degraded` is not two states collapsed. A reviewer that ran but stopped early holds real
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
  if content_empty "$f"; then echo failed; return 0; fi
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
    # ★ ...and never states a BOTTOM LINE either. Measured 2026-08-29 on the
    # live runner: a 1.4KB clean review of a comment-only diff about a 429
    # throttle -- "there is no rate-limit check ... Verdict: ship it" -- had
    # findings=0, matched the scan, was retried three times over 250s of the
    # seat's quota, and was filed failed under a DID NOT COMPLETE banner. The
    # discriminator provider_refused() already names: a refusal is something
    # the CLI RETURNS, a verdict is something the model WRITES. A refusal
    # that happens to say "ship it" lands on the judge, the cheap direction.
    # ★ explicit_verdict, not has_verdict: the broad gate accepts a bare
    # "approved" or a leading "Recommendation:", and "Request not approved:
    # 429" / "Recommendation: retry after 60s" are refusal shapes. Found by
    # the codex review of this change.
    if rate_limited "$f" && [ "$(review_findings "$f")" -eq 0 ] && ! explicit_verdict "$f"; then echo failed; return 0; fi
    # ★ #28. A seat whose sandbox broke before the model could look wrote a
    # short apology, no findings, and a verdict of its own -- and that verdict
    # carried it past the inconclusive test below into `ok`. Checked here with
    # the same findings=0 gate as the rate-limit scan, and ahead of has_verdict
    # on purpose: a bottom line on a review that never happened is not a
    # bottom line. `failed`, not `inconclusive`: the report must send the
    # operator to the box, not to the roster.
    if env_blocked "$f" && [ "$(review_findings "$f")" -eq 0 ]; then echo failed; return 0; fi
    # ★ #48. A window refusal that exits ZERO never reached the refusal chain at
    # all. Both dispatch paths ask provider_window_closed() only about a run this
    # function already called `failed`, and every window in the corpus until now
    # arrived with a nonzero exit, so the rc test below did that binning for
    # free. The model-tier limit does not: "You've reached your <Model> limit.
    # Switch to another model to continue." states no findings and no verdict and
    # exits 0, so it landed in `inconclusive` and run-pass aborted the sweep as a
    # failed measurement -- with the regex fixed and this line missing, it still
    # would.
    # ★ Same findings=0 guard as its two neighbours -- but has_verdict, the
    # BROAD one, where the rate scan above uses the narrow explicit_verdict. The
    # blast radius is what moves the line. A wrong `failed` on the rate path
    # costs one run; a wrong `failed` here stops the ENTIRE SWEEP at exit 6 and
    # sends the operator off to wait out a window that never closed, and the
    # re-run does it again. So this one protects a real review as hard as it can
    # and accepts the pre-existing exit 4 as the cost of a miss.
    # ★ Safe in the other direction, checked against every refusal in the
    # corpus one by one: not one of them states a bottom line at all. The
    # shapes explicit_verdict exists to exclude -- "Request not approved: 429",
    # "Recommendation: retry after 60s" -- are RATE refusals, and a rate refusal
    # never reaches this line.
    # ★ And that makes the guards here IDENTICAL to the inconclusive test at the
    # bottom of this function -- findings=0 and no broad bottom line, the same
    # two predicates. So this branch can only ever move a run from
    # `inconclusive` to `failed`. It cannot reach a run that would have been
    # `ok`, which is the only direction that destroys a real review. Keep the
    # two in step if either one moves.
    if provider_window_closed "$f" && [ "$(review_findings "$f")" -eq 0 ] && ! has_verdict "$f"; then echo failed; return 0; fi
  elif provider_refused "$f" "$rc"; then
    echo failed; return 0
  fi
  if [ "$rc" -ne 0 ]; then echo failed; return 0; fi
  # ★ LAST, so it can only ever reclassify something that would otherwise be
  # `ok`. Nothing above it changes; a run that any earlier check already binned
  # never reaches here.
  #
  # `ok` used to mean "has content, no adapter marker, exit 0" -- which is not
  # the same thing as "is a review". A model that returns fluent prose without
  # ever reviewing lands here, and the consequence is the worst one in the
  # system: cmd_synthesize counts a complete review in EVERY finding's
  # denominator, and its silence about a file reads as ordinary non-mention, so
  # a non-review clears the whole diff. That is the grok-partial bug again with
  # a different cause.
  #
  # Measured, not hypothesised. Three artifacts across the 26 review dirs on
  # this machine, all classified `ok`, none of them a review:
  #   grok-lead-b/opencode-ollama-qwen3-judge  50KB of CLI chrome and praise,
  #                                            ending "more resilient, ... 🚀"
  #   lead-3state-b/opencode-ollama-qwen3-judge  39KB ending "no tool call is
  #                                            required here ... please clarify"
  #   fresh-1/opencode-...-nemotron-3-ultra-free  37KB that echoes the diff back
  #                                            and stops mid-hunk
  # All three are opencode-routed, the free path the README sends people down
  # first -- the same route that produced the chrome-only runs handled above.
  # The third one also shows why this cannot be left to the adapter contract:
  # it is an UNMARKED truncation, so no `_TRUNCATED` was ever coming.
  #
  # The test is deliberately narrow: no findings AND no bottom line. Either one
  # alone keeps the run `ok`, because "findings=0, ship it" is a real review and
  # a length floor already threw those away once. Checked against every
  # zero-finding artifact on disk: 13 genuine clean reviews all state a verdict
  # and stay `ok`, the 3 above do not and move.
  #
  # ★ ctx=run only. A synthesis of a clean panel legitimately names no findings
  # and gives no verdict of its own -- it reports each reviewer's -- so applying
  # this there would bin good merges.
  if [ "$ctx" = run ] && [ "$(review_findings "$f")" -eq 0 ] && ! has_verdict "$f"; then
    echo inconclusive; return 0
  fi
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
# The judge is a model too. Default to the first installed candidate and SAY
# which one, because a silently-chosen judge is a silently-chosen bias.
#
# ★ SHARED, not bin/cadre-local, because lib/engine/settle.sh calls it: settle
# picks a judge when none was passed. It worked from bin/cadre only because
# everything is sourced into one binary, so the engine was quietly depending on
# a symbol the benchmark's entrypoint owned -- which is exactly the coupling the
# two-binary split will trip over. Living here it belongs to neither half.
pick_judge() {
  [ -n "${CADRE_JUDGE:-}" ] && return 0
  local a
  for a in claude codex grok opencode; do
    agent_installed "$a" && { CADRE_JUDGE="$a"; return 0; }
  done
  return 1
}

scrubbed_env() {
  local a=(env) v
  for v in "${CADRE_SCRUB_ENV[@]}"; do a+=(-u "$v"); done
  printf '%s\n' "${a[@]}"
}
