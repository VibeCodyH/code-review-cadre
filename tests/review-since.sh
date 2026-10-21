#!/usr/bin/env bash
# `cadre review --since`: the re-review focus. Only a local stub adapter. The
# stub runs git INSIDE the reviewers' checkout, so these checks prove the delta
# the brief names actually resolves there, not just that the prompt says so.
set -uo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SANDBOX=$(mktemp -d) || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0
check() {
  local name="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); echo "  ok   $name"
  else FAIL=$((FAIL + 1)); echo "  FAIL $name"; fi
}
mkdir -p "$SANDBOX/bin" "$SANDBOX/agents.d" "$SANDBOX/state" "$SANDBOX/seen"
printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/focus"; chmod +x "$SANDBOX/bin/focus"
# $dir and $prompt are agentcall's. The stub records the prompt, then asks the
# checkout for both diffs the brief tells a reviewer to run.
cat > "$SANDBOX/agents.d/focus.sh" <<A
run_focus() {
  local seen="$SANDBOX/seen" base since
  printf '%s\n' "\$prompt" > "\$seen/prompt.txt"
  base=\$(printf '%s\n' "\$prompt" | sed -n 's/^  git diff \([0-9a-f]*\)\.\.\.HEAD\$/\1/p')
  since=\$(printf '%s\n' "\$prompt" | sed -n 's/^  git diff \([0-9a-f]*\)\.\.HEAD\$/\1/p')
  git -C "\$dir" diff --name-only "\$base...HEAD" > "\$seen/full.txt" 2>&1
  : > "\$seen/delta.txt"
  [ -z "\$since" ] || git -C "\$dir" diff --name-only "\$since..HEAD" > "\$seen/delta.txt" 2>&1
  git -C "\$dir" rev-list --count "\$base..HEAD" > "\$seen/commits.txt" 2>&1
  echo "- nit: fixture"
  echo "Verdict: ship it"
}
A
run_cadre() {
  CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work" \
    CADRE_AGENTS_D="$SANDBOX/agents.d" PATH="$SANDBOX/bin:$PATH" \
    "$ROOT/bin/cadre" "$@" 2>&1
}
review() {  # <label> <args...>: must succeed
  local label="$1"; shift
  rm -f "$SANDBOX/seen/"*
  OUT=$(run_cadre review --label "$label" --synth none --roster focus "$@"); RC=$?
  R="$SANDBOX/state/reviews/$label"
  [ "$RC" -eq 0 ] || printf '%s\n' "$OUT"
  check "$label completes" test "$RC" -eq 0
}
refused() {  # <label> <want-rc> <phrase> <args...>: must refuse before any seat
  local label="$1" want="$2" phrase="$3"; shift 3
  rm -f "$SANDBOX/seen/"*
  OUT=$(run_cadre review --label "$label" --synth none --roster focus "$@"); RC=$?
  if [ "$RC" -eq "$want" ] && [[ "$OUT" == *"$phrase"* ]] && [ ! -e "$SANDBOX/seen/prompt.txt" ]; then
    PASS=$((PASS + 1)); echo "  ok   $label refused"
  else
    FAIL=$((FAIL + 1)); echo "  FAIL $label refused (rc=$RC, want $want / '$phrase')"; printf '%s\n' "$OUT"
  fi
}
lines() { printf '%s\n' "$@"; }
same() { [ "$(cat "$1")" = "$2" ] || { echo "    got: $(tr '\n' ' ' < "$1")"; return 1; }; }
has() { grep -qF -- "$1" "$2"; }
lacks() { ! has "$1" "$2"; }

S="$SANDBOX/repo"
git init -q -b main "$S" && git -C "$S" config user.name Test \
  && git -C "$S" config user.email test@example.invalid || exit 1
printf 'initial\n' > "$S/app.js"; git -C "$S" add .; git -C "$S" commit -qm initial
git -C "$S" checkout -qb feature
printf 'round one\n' > "$S/a.js"; git -C "$S" add .; git -C "$S" commit -qm 'round 1'
SINCE=$(git -C "$S" rev-parse HEAD)
printf 'round two\n' > "$S/b.js"; printf 'fix\n' >> "$S/app.js"
git -C "$S" add .; git -C "$S" commit -qm 'round 2 fixes'
printf 'untracked\n' > "$S/new.js"
cd "$S" || exit 1

echo '== --since: delta resolves in the checkout, full diff still there =='
review since --base main --since "$SINCE"
check 'brief opens the re-review paragraph' has 'Re-review: this change was last reviewed at' "$SANDBOX/seen/prompt.txt"
check 'no placeholder left in the brief' lacks '{{' "$SANDBOX/seen/prompt.txt"
# Oracle: what git says changed after round 1, plus the carried untracked file.
check 'delta is exactly the post-review files' same "$SANDBOX/seen/delta.txt" "$(lines app.js b.js new.js)"
check 'full base...HEAD diff unchanged' same "$SANDBOX/seen/full.txt" "$(lines a.js app.js b.js new.js)"
check 'manifest names the real since sha' has "since:     $SINCE" "$R/manifest.txt"
check 'manifest records the since tree' has "since-tree: $(git -C "$S" rev-parse "$SINCE^{tree}")" "$R/manifest.txt"
check 'banner names the focus' has "(focus: since ${SINCE:0:9})" <(printf '%s\n' "$OUT")

echo '== no --since: two-commit checkout, no re-review text =='
review nosince --base main
check 'no re-review paragraph' lacks 'Re-review' "$SANDBOX/seen/prompt.txt"
check 'no placeholder left in the brief' lacks '{{' "$SANDBOX/seen/prompt.txt"
check 'no delta asked for' same "$SANDBOX/seen/delta.txt" ""
check 'base..HEAD is the one change commit plus untracked' same "$SANDBOX/seen/commits.txt" 2
check 'manifest has no since line' lacks 'since:' "$R/manifest.txt"
check 'manifest has no since tree' lacks 'since-tree:' "$R/manifest.txt"

echo '== refusals =='
rm -f "$S/new.js"
refused full 2 '--since needs a diff to narrow' --full --since "$SINCE" "$S"
refused bogus 2 '--since does not resolve' --base main --since no-such-rev
git -C "$S" checkout -qb other main
printf 'elsewhere\n' > "$S/c.js"; git -C "$S" add .; git -C "$S" commit -qm elsewhere
OTHER=$(git -C "$S" rev-parse HEAD)
git -C "$S" checkout -q feature
refused rebased 2 'is not an ancestor of HEAD' --base main --since "$OTHER"
refused unchanged 2 'nothing changed since' --base main --since HEAD
# The `gh pr update-branch` shape: main moves, the branch merges it in. The
# since sha is still an ancestor, but since..HEAD would carry main's commit.
git -C "$S" checkout -q main
printf 'upstream\n' > "$S/up.js"; git -C "$S" add .; git -C "$S" commit -qm upstream
git -C "$S" checkout -q feature
git -C "$S" merge -q --no-edit main
refused merged 2 'is not an ancestor of --since' --base main --since "$SINCE"

echo '== a credential only in the since tree is refused =='
git -C "$S" checkout -qb leak main
printf 'TOKEN=x\n' > "$S/.env"; git -C "$S" add -f .env; git -C "$S" commit -qm 'oops'
LEAK=$(git -C "$S" rev-parse HEAD)
git -C "$S" rm -q .env; printf 'more\n' > "$S/d.js"; git -C "$S" add .; git -C "$S" commit -qm 'drop it'
review leak-full --base main
refused leak-since 3 'Credential-shaped files' --base main --since "$LEAK"

echo
echo "since: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
