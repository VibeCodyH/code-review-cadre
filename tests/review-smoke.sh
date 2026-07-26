#!/usr/bin/env bash
# Smoke tests for `cadre review`. Stub adapters only: this checks the harness,
# not any model. Runs in seconds.
#
#   tests/review-smoke.sh
#
# Every case here is a bug that was actually in the code at some point. The
# three marked ★ were found by a panel run against this repo's own diff.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $*"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $*"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1"; fi; }

SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT

# One stub agent that echoes what it can see, one that truncates.
setup_agents() {
  mkdir -p "$1/bin" "$1/agents.d"
  local n
  for n in good good2 trunc; do
    printf '#!/bin/sh\nexit 0\n' > "$1/bin/$n"; chmod +x "$1/bin/$n"
  done
  cat > "$1/agents.d/good.sh" <<'A'
run_good() {
  echo "REVIEW by good"
  ( cd "$dir" && echo "--ls-files--" && git ls-files \
      && echo "--diff--" && git diff --name-only "$CADRE_PASS_BASE...HEAD" )
}
A
  sed 's/good/good2/g' "$1/agents.d/good.sh" > "$1/agents.d/good2.sh"
  cat > "$1/agents.d/trunc.sh" <<'A'
run_trunc() {
  echo "partial finding"
  echo
  echo "_TRUNCATED, grok stopped early (stopReason=MaxTokens); this review is INCOMPLETE, not a clean pass._"
}
A
}

# A fresh repo on branch `feature`, forked from `main`.
new_repo() {
  local d="$1"
  git init -q "$d"
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name t
  echo orig > "$d/app.js"; echo '*.log' > "$d/.gitignore"
  echo 'TEMPLATE=' > "$d/.env.example"
  git -C "$d" add -A; git -C "$d" commit -qm base; git -C "$d" branch -M main
}

case_dir() {
  # Separate statements: bash expands every word of a `local` line BEFORE any
  # of its assignments take effect, so `local a="$1" b="$SANDBOX/$a"` leaves b
  # pointing at /src.
  local name="$1"
  local d="$SANDBOX/$name"
  mkdir -p "$d"
  setup_agents "$d"
  new_repo "$d/src"
  echo "$d"
}

run_cadre() {  # run_cadre <case-dir> <args...>
  local d="$1"; shift
  CADRE_HOME="$d/state" CADRE_WORK="$d/work" CADRE_AGENTS_D="$d/agents.d" \
  PATH="$d/bin:$PATH" "$ROOT/bin/cadre" "$@" 2>&1
}

echo "== normal branch review =="
D=$(case_dir normal); S="$D/src"
git -C "$S" checkout -qb feature
echo committed >> "$S/app.js"; git -C "$S" commit -qam feat
echo uncommitted >> "$S/app.js"
mkdir -p "$S/src"; echo new > "$S/src/newfeature.js"      # untracked
echo 'SECRET=1' > "$S/.env.local"; echo '.env.local' >> "$S/.gitignore"
echo noise > "$S/debug.log"                                # ignored
BEFORE="$(git -C "$S" status --porcelain | md5sum)$(git -C "$S" rev-parse HEAD)"
OUT=$(run_cadre "$D" review --roster good,trunc,ghost --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "source repo untouched"        "[ \"\$BEFORE\" = \"\$(git -C '$S' status --porcelain | md5sum)\$(git -C '$S' rev-parse HEAD)\" ]"
check "no refs/cadre left behind"    "[ -z \"\$(git -C '$S' for-each-ref refs/cadre)\" ]"
check "work dir cleaned"             "[ -z \"\$(ls -A '$D/work')\" ]"
check "untracked file in the DIFF"   "grep -q 'src/newfeature.js' '$R'/report.md"
check "gitignored secret excluded"   "! grep -q 'env.local' '$G'"
check "ignored log excluded"         "! grep -q 'debug.log' '$G'"
check ".env.example did not refuse"  "[ -n '$G' ]"
check "truncated review -> FAILED"   "ls '$R'/trunc-*.md.failed >/dev/null 2>&1"
check "missing agent -> FAILED"      "grep -q 'NOT INSTALLED' '$R'/ghost-*.failed"
check "all 3 roster rows in report"  "[ \$(grep -c '^- \`' '$R/report.md') -eq 3 ]"
# ★ The checkout is synthetic, so its shas die with it. The manifest has to name
# commits that still resolve in the user's repo or it is not provenance.
MB=$(grep '^base:' "$R/manifest.txt" | awk '{print $2}')
MS=$(grep '^snapshot:' "$R/manifest.txt" | awk '{print $2}')
check "manifest base resolves in repo"     "git -C '$S' cat-file -e '$MB^{commit}' 2>/dev/null"
check "manifest snapshot resolves in repo" "git -C '$S' cat-file -e '$MS^{commit}' 2>/dev/null"

echo "== ★ untracked-only change on the default branch =="
# stash create does not consider a new file a change, so SNAP == BASE == HEAD.
# This used to exit "nothing to review" while sitting on the whole feature.
D=$(case_dir untracked_only); S="$D/src"
echo brand new > "$S/feature.js"
OUT=$(run_cadre "$D" review --roster good --base HEAD "$S")
check "reviews an untracked-only change" "grep -q '1 ok' <<<\"\$OUT\""
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "the new file reached the diff"    "grep -q 'feature.js' '$R'/report.md"

echo "== ★ broken index must abort, not silently review HEAD =="
D=$(case_dir bad_index); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"
OUT=$(GIT_INDEX_FILE=/dev/null run_cadre "$D" review --roster good --base main "$S")
check "aborts on stash-create failure"   "grep -qi 'stash create failed' <<<\"\$OUT\""
check "no review dir was created"        "[ ! -d '$D/state/reviews' ] || [ -z \"\$(ls -A '$D/state/reviews')\" ]"

echo "== ★ unsignable commit must abort, not claim 'carried' =="
D=$(case_dir gpgsign); S="$D/src"
echo brand new > "$S/feature.js"
git -C "$S" config commit.gpgsign true
git -C "$S" config user.signingkey NO_SUCH_KEY
OUT=$(run_cadre "$D" review --roster good --base HEAD "$S")
check "carries new files despite gpgsign" "grep -q 'carried 1 untracked' <<<\"\$OUT\""
check "and does not fail the run"         "grep -q '1 ok' <<<\"\$OUT\""

echo "== roster parsing =="
D=$(case_dir roster); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
mkdir -p "$D/state"
printf '# staffed\ngood\ngood2' > "$D/state/roster"          # NO trailing newline
OUT=$(run_cadre "$D" review --base main "$S")
check "last roster line not dropped"  "grep -q '2 reviewer(s)' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good,good --base main "$S")
check "duplicate spec refused"        "grep -q 'listed twice' <<<\"\$OUT\""
printf '# good\n' > "$D/state/roster"
OUT=$(run_cadre "$D" review --base main "$S")
check "all-commented roster refused"  "grep -q 'commented out' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good --label reuse --base main "$S")
OUT=$(run_cadre "$D" review --roster good --label reuse --base main "$S")
check "label is single-use"           "grep -q 'already exists' <<<\"\$OUT\""

echo "== parallel =="
D=$(case_dir parallel); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good,good2,trunc --jobs 3 --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "all 3 accounted for in parallel" "[ \$(grep -c '^- \`' '$R/report.md') -eq 3 ]"
check "parallel work dir cleaned"       "[ -z \"\$(ls -A '$D/work')\" ]"

# ★ jobs < roster size. With --jobs 3 and three reviewers the slot loop never
# runs, so the one branch that can deadlock or miscount stayed untested.
OUT=$(run_cadre "$D" review --roster good,good2,trunc --jobs 2 --label throttle --base main "$S")
R2="$D/state/reviews/throttle"
check "throttled queue runs everyone"   "[ \$(grep -c '^- \`' '$R2/report.md') -eq 3 ]"
check "throttled work dir cleaned"      "[ -z \"\$(ls -A '$D/work')\" ]"

echo "== ★ deleted credentials must not reach reviewers =="
# A full clone carries history the preflight cannot scan: a .env committed once
# and deleted still answers `git log -p`. The checkout is built as a synthetic
# two-commit repo so there is no earlier history to mine.
D=$(case_dir history_leak); S="$D/src"
echo 'API_TOKEN=history-only-secret' > "$S/.env"
git -C "$S" add -A; git -C "$S" commit -qm "oops"
git -C "$S" rm -q "$S/.env" 2>/dev/null || git -C "$S" rm -q .env
git -C "$S" commit -qm "remove it"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"
cat > "$D/agents.d/good.sh" <<'A'
run_good() {
  echo "REVIEW by good"
  ( cd "$dir" && echo "--history--" && git log -p --all 2>/dev/null | head -200 )
}
A
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "deleted secret NOT reachable"  "! grep -q 'history-only-secret' '$G'"
check "history is only the two commits" "[ \$(grep -c '^commit ' '$G') -le 2 ]"
check "the run still succeeded"       "grep -q '1 ok' <<<\"\$OUT\""

echo "== ★ CADRE_HOME inside the reviewed repo is refused =="
D=$(case_dir nested_home); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
mkdir -p "$S/.cadre/keys"; echo "K1 the answer" > "$S/.cadre/keys/secret.md"
OUT=$(CADRE_HOME="$S/.cadre" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "nested CADRE_HOME refused"     "grep -q 'inside the repo being reviewed' <<<\"\$OUT\""

echo "== default base resolution =="
# Every other case passes --base. This is the path a real user hits first.
D=$(case_dir defaultbase); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good "$S")
check "falls back to main with no origin" "grep -q 'base: main' <<<\"\$OUT\""
check "and completes the run"             "grep -q '1 ok' <<<\"\$OUT\""

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
