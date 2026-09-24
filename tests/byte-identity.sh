#!/usr/bin/env bash
# Byte-identity gate (#10). Replays one fixed synthetic fixture through the
# deterministic parts of the harness -- a live panel with a synthesis, then a
# graded benchmark pass -- and compares every artifact they leave, byte for
# byte, against the goldens committed in tests/fixtures/byte-identity/.
#
#   bash tests/byte-identity.sh            check; prints a unified diff on mismatch
#   bash tests/byte-identity.sh --accept   regenerate the goldens after an
#                                          INTENDED change, then commit them
#
# Stub adapters only: no model, no network. "Should not change results" is
# this gate passing. A change that is meant to move an artifact regenerates the
# goldens, and the move is then a diff in the commit a reviewer can read.
# docs/BYTE-IDENTITY.md lists every normalized field and why.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
GOLDEN="$ROOT/tests/fixtures/byte-identity"
MODE=check
case "${1:-}" in
  '') ;;
  --accept) MODE=accept ;;
  *) echo "usage: bash tests/byte-identity.sh [--accept]" >&2; exit 2 ;;
esac
# ★ A clean environment, the same one test.sh gives every test, so a
# contributor's exported CADRE_* or GIT_* settings cannot make the goldens
# theirs rather than the harness's.
if [ -z "${CADRE_BYTE_IDENTITY_CLEAN:-}" ]; then
  exec env -i CADRE_BYTE_IDENTITY_CLEAN=1 PATH=/usr/bin:/bin bash "${BASH_SOURCE[0]}" "$@"
fi

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
# ★ Pinned INPUTS, not normalized outputs. Every commit this fixture makes,
# and every synthetic commit run-review.sh builds from it, takes its identity
# from these, so base and snapshot shas -- and the prompts that name them --
# are the same on every machine and every day.
export HOME="$SANDBOX/home" PATH="$SANDBOX/bin:/usr/bin:/bin" TZ=UTC LC_ALL=C.UTF-8
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.invalid
export GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.invalid
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
export CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work"
export CADRE_AGENTS_D="$SANDBOX/agents.d" CADRE_RETRY_WAIT=0 CADRE_JUDGE=judge
export CADRE_LOCK_FILE="$SANDBOX/state/fixture.lock.json"
mkdir -p "$HOME" "$CADRE_HOME" "$CADRE_AGENTS_D" "$SANDBOX/bin" "$SANDBOX/captured"

# ---- stub adapters -----------------------------------------------------------
# One per delivery state the renderers branch on, plus a synthesizer and a
# judge that save the prompt they were handed: the brief a model receives is
# the harness's first output, and a refactor that moves it is not neutral.
for n in finder trunc dead waffle twice gated synth candidate judge; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$n"; chmod +x "$SANDBOX/bin/$n"
done
# The optional SDK adapter can be installed beside the checkout; keep the
# inventory down to these stubs.
printf 'bin_pireview() { echo cadre-fixture-pireview-not-installed; }\n' > "$CADRE_AGENTS_D/pireview.sh"
cat > "$CADRE_AGENTS_D/finder.sh" <<'A'
run_finder() {
  echo "- blocking: app.js drops the write when the retry path runs"
  echo "* **Severity**: should-fix"
  echo "#### **1. \`nit\`** rename the counter"
  echo "Verdict: blocking"
}
A
cat > "$CADRE_AGENTS_D/trunc.sh" <<'A'
run_trunc() {
  echo "- should-fix: the counter is never reset"
  echo
  echo "_TRUNCATED, stopped early (stopReason=MaxTokens); this review is INCOMPLETE, not a clean pass._"
}
A
cat > "$CADRE_AGENTS_D/dead.sh" <<'A'
run_dead() { echo "DID NOT COMPLETE, no text returned (stopReason=Error)."; return 1; }
A
# Ran, exited 0, and never reviewed: no finding and no verdict.
cat > "$CADRE_AGENTS_D/waffle.sh" <<'A'
run_waffle() { echo "I have looked over the changes you provided. They touch the save path."; }
A
cat > "$CADRE_AGENTS_D/twice.sh" <<'A'
run_twice() { echo "- nit: the fixture file has no trailing comment"; echo "Verdict: ship it"; }
A
cat > "$CADRE_AGENTS_D/gated.sh" <<'A'
run_gated() { echo "SHOULD NOT RUN: the roster gate skips this seat"; }
A
# The capture directory is found from the adapter file itself, never baked
# in: an adapter's bytes are hashed onto the run record, and a sandbox path
# inside them would move that hash on every run. Inside a function sourced
# from agents.d, BASH_SOURCE names the file the function came from.
cat > "$CADRE_AGENTS_D/synth.sh" <<'A'
run_synth() {
  local cap; cap="$(dirname "${BASH_SOURCE[0]}")/../captured"
  printf '%s\n' "$prompt" > "$cap/synth-prompt.txt"
  echo "- blocking [1/3]: app.js drops the write when the retry path runs"
  echo "- should-fix [2/3]: the counter is never reset"
  echo "Verdict: blocking"
}
A
# Run 1 finds both blocking items, run 2 one of them: a spread to render.
cat > "$CADRE_AGENTS_D/candidate.sh" <<'A'
run_candidate() {
  local c n; c="$(dirname "${BASH_SOURCE[0]}")/../captured/candidate.count"
  n=$(cat "$c" 2>/dev/null || echo 0); echo $((n + 1)) > "$c"
  echo "- blocking: FOUND-K1 the retry path drops the write"
  [ "$n" -gt 0 ] || echo "- blocking: FOUND-K2 the token is logged"
  echo "Verdict: blocking"
}
A
# A judge that reads the review it was given: HIT where the review names the
# item's token, MISS otherwise. Deterministic, and it still depends on what
# the harness put in front of it.
cat > "$CADRE_AGENTS_D/judge.sh" <<'A'
run_judge() {
  local cap k n items="" quotes=""
  cap="$(dirname "${BASH_SOURCE[0]}")/../captured"
  n=$(find "$cap" -name 'judge-prompt-*' | wc -l | tr -d ' ')
  printf '%s\n' "$prompt" > "$cap/judge-prompt-$((n + 1)).txt"
  for k in K1 K2 K3; do
    # A case match, not `printf | grep -q`: under pipefail grep's early exit
    # can hand back printf's SIGPIPE and turn a HIT into a MISS at random.
    case "$prompt" in
      *"FOUND-$k"*) items="$items,\"$k\":\"HIT\""; quotes="$quotes,\"$k\":\"FOUND-$k\"" ;;
      *) items="$items,\"$k\":\"MISS\"" ;;
    esac
  done
  printf '{"items":{%s},"quotes":{%s},"verdict":"found","extras":[]}\n' "${items#,}" "${quotes#,}"
}
A

# ---- the fixture repository -------------------------------------------------
REPO="$SANDBOX/repo"
git init -q -b main "$REPO"
printf 'let count = 0;\nfunction save(x) { count++; return write(x); }\n' > "$REPO/app.js"
git -C "$REPO" add -A; git -C "$REPO" commit -qm base
git -C "$REPO" checkout -qb feature
printf 'let count = 0;\nfunction save(x) { count++; if (retry) return; return write(x); }\n' > "$REPO/app.js"
git -C "$REPO" commit -qam change

# Console output is an artifact too. A step that fails prints it and stops the
# gate: a fixture that did not run cannot be compared.
step() {  # <name> <cmd...>
  local name="$1"; shift
  "$@" > "$SANDBOX/captured/$name.stdout" 2>&1 || {
    echo "byte-identity: fixture step '$name' failed (exit $?):" >&2
    cat "$SANDBOX/captured/$name.stdout" >&2
    exit 1
  }
}

# ---- stage 1: a live panel, then its synthesis ------------------------------
step review "$ROOT/bin/cadre" review --base main --label fixture --synth synth \
  --roster 'finder,trunc,dead,waffle,ghost,twice x2,gated ?min-lines=999' "$REPO"
step receipts "$ROOT/bin/cadre" receipts "$CADRE_HOME/reviews"

# ---- stage 2: a graded benchmark pass ---------------------------------------
cat > "$CADRE_HOME/key.md" <<'KEY'
#### K1 blocking - the retry path drops the write
The early return skips write(x).
#### K2 blocking - the token is logged
A credential reaches the log.
#### K3 should-fix - the counter is never reset
count grows without bound.
KEY
SHA=$(git -C "$REPO" rev-parse feature)
BASE=$(git -C "$REPO" rev-parse main)
git clone -q "$REPO" "$SANDBOX/checkout"
printf 'p1|%s|%s|%s|key.md\n' "$SHA" "$SANDBOX/checkout" "$BASE" > "$CADRE_HOME/passes.conf"
"$ROOT/bin/cadre" lock --update > /dev/null
step run "$ROOT/bin/cadre" run candidate 2
step panel "$ROOT/bin/cadre" panel

# ---- collect and normalize --------------------------------------------------
# ★ ONLY these rewrites, and each one is a value that differs between two runs
# of unchanged code, or between two commits that change nothing the fixture
# can observe. Anything else that moves is a behavior change, and fails.
normalize() {
  sed -E \
    -e "s#$SANDBOX#<SANDBOX>#g" \
    -e 's/"(ts|secs|wall_secs|seat_secs|prerun_secs|unattributed_secs)":-?[0-9]+/"\1":<n>/g' \
    -e 's/"(harness_sha|lock_sha)":"[0-9a-f]+"/"\1":"<\1>"/g' \
    -e 's/^( *)(harness|cadre):( +)([0-9a-f]+|unknown)$/\1\2:\3<\2>/' \
    -e 's/^(Harness: every row (that names one )?ran against )[0-9a-f]+\.$/\1<harness_sha>./' \
    -e 's/^(\| `[^`]*` \| [^|]* \| [a-z]+ \| )[0-9]+ \|/\1<n> |/' \
    -e 's/^(\| \*\*panel total\*\* \| \| \| )[0-9]+ \|/\1<n> |/' \
    -e 's/^> Wall clock: \*\*[0-9]+s\*\* for this panel up to this table; [0-9]+s in seats\. \*\*Unattributed: -?[0-9]+s\*\*/> Wall clock: **<n>s** for this panel up to this table; <n>s in seats. **Unattributed: <n>s**/'
}
# Console progress lines only: "<bytes> bytes in Ns", "DEGRADED after Ns".
normalize_console() {
  sed -E -e 's/ bytes in [0-9]+s$/ bytes in <n>s/' \
    -e 's/( (DEGRADED|FAILED|INCONCLUSIVE) after )[0-9]+s/\1<n>s/'
}
# slots.tsv: column 6 is seconds, column 11 the harness hash.
normalize_slots() {
  awk -F '\t' -v OFS='\t' '{ if ($6 ~ /^[0-9]+$/) $6 = "<n>"; if ($11 != "") $11 = "<harness_sha>"; print }'
}
# `cadre receipts`: SECS is the fixed-width column at characters 80-87.
normalize_receipts() {
  awk '{ s = substr($0, 80, 8); if (s ~ /^ *[0-9]+$/) $0 = substr($0, 1, 79) sprintf("%8s", "<n>") substr($0, 88); print }'
}
ACTUAL="$SANDBOX/actual"
mkdir -p "$ACTUAL"
collect() {  # <source> <name>
  mkdir -p "$(dirname "$ACTUAL/$2")"
  case "$2" in
    *slots.tsv) normalize_slots < "$1" | normalize > "$ACTUAL/$2" ;;
    *receipts.stdout) normalize_receipts < "$1" | normalize > "$ACTUAL/$2" ;;
    *.stdout) normalize_console < "$1" | normalize > "$ACTUAL/$2" ;;
    *) normalize < "$1" > "$ACTUAL/$2" ;;
  esac
}
# The panel directory whole, so a new or vanished artifact is a diff too.
PANEL="$CADRE_HOME/reviews/fixture"
while IFS= read -r f; do collect "$PANEL/$f" "panel/$f"; done \
  < <(cd "$PANEL" && find . -type f ! -name '.*' | sed 's#^\./##' | LC_ALL=C sort)
# The graded side: the pass's outputs, grades and record, the gauntlet report
# and its table. The lock file and the gauntlet's own lock are identity and
# mutex, not results.
while IFS= read -r f; do collect "$CADRE_HOME/$f" "graded/$f"; done \
  < <(cd "$CADRE_HOME" && find . -type f ! -name '.*' ! -name fixture.lock.json \
        ! -path './reviews/*' ! -path './agents.d/*' | sed 's#^\./##' | LC_ALL=C sort)
while IFS= read -r f; do collect "$SANDBOX/captured/$f" "captured/$f"; done \
  < <(cd "$SANDBOX/captured" && find . -type f ! -name '*.count' | sed 's#^\./##' | LC_ALL=C sort)

if [ "$MODE" = accept ]; then
  rm -rf "$GOLDEN"
  mkdir -p "$(dirname "$GOLDEN")"
  cp -R "$ACTUAL" "$GOLDEN"
  echo "byte-identity: accepted $(find "$GOLDEN" -type f | wc -l | tr -d ' ') golden file(s) into tests/fixtures/byte-identity/"
  echo "Review what moved with: git status --short -- tests/fixtures/byte-identity/ && git diff -- tests/fixtures/byte-identity/"
  exit 0
fi

[ -d "$GOLDEN" ] || { echo "byte-identity: no goldens at $GOLDEN; run: bash tests/byte-identity.sh --accept" >&2; exit 1; }
if ! diff -ru "$GOLDEN" "$ACTUAL" > "$SANDBOX/golden.diff"; then
  sed -e "s#$GOLDEN#golden#g" -e "s#$ACTUAL#actual#g" "$SANDBOX/golden.diff"
  echo
  echo "byte-identity: FAIL, the fixture's artifacts differ from the committed goldens (diff above)."
  echo "A change that claims to be behavior-neutral must not move them. If this change is"
  echo "MEANT to, regenerate and commit the goldens so the move is visible in review:"
  echo "  bash tests/byte-identity.sh --accept && git add tests/fixtures/byte-identity"
  exit 1
fi
echo "byte-identity: $(find "$GOLDEN" -type f | wc -l | tr -d ' ') artifact(s) byte-identical to the goldens"
