#!/usr/bin/env bash
# Project selection and path-gate integration tests. Only local stub adapters.
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
mkdir -p "$SANDBOX/bin" "$SANDBOX/agents.d" "$SANDBOX/state"
for seat in project environment explicit global; do
  printf '#!/bin/sh\nexit 0\n' > "$SANDBOX/bin/$seat"
  chmod +x "$SANDBOX/bin/$seat"
  printf 'run_%s() { echo "REVIEW by %s"; printf "ROSTER_ENV=%%s|%%s\\n" "${CADRE_ROSTER_LAYER-unset}" "${CADRE_ROSTER_PATH-unset}"; echo "Verdict: ship it"; }\n' "$seat" "$seat" \
    > "$SANDBOX/agents.d/$seat.sh"
done
new_repo() {
  git init -q -b main "$1" && git -C "$1" config user.name Test \
    && git -C "$1" config user.email test@example.invalid \
    && printf 'initial\n' > "$1/app.js" && git -C "$1" add . \
    && git -C "$1" commit -qm initial
}
run_cadre() {
  CADRE_ROOT="$ROOT" CADRE_HOME="$SANDBOX/state" CADRE_WORK="$SANDBOX/work" \
    CADRE_AGENTS_D="$SANDBOX/agents.d" CADRE_ROSTER="${CADRE_ROSTER:-}" \
    PATH="$SANDBOX/bin:$PATH" "$ROOT/bin/cadre" "$@" 2>&1
}
review() {
  local label="$1"; shift
  OUT=$(run_cadre review --label "$label" --synth none "$@"); RC=$?
  R="$SANDBOX/state/reviews/$label"
  if [ "$RC" -ne 0 ]; then printf '%s\n' "$OUT"; fi
  check "$label completes" test "$RC" -eq 0
}
seat_state() {
  awk -F '\t' -v seat="$1" -v state="$2" '$2 == seat && $4 == state { found=1 } END { exit !found }' "$R/slots.tsv"
}
has() { grep -qF -- "$1" "$2"; }
lacks() { ! has "$1" "$2"; }
refused() {
  local phrase="$1"; shift
  OUT=$(run_cadre "$@"); RC=$?
  [ "$RC" -ne 0 ] && [[ "$OUT" == *"$phrase"* ]]
}

echo '== target roster and precedence =='
S="$SANDBOX/target"; C="$SANDBOX/caller"
new_repo "$S"; new_repo "$C"
mkdir -p "$S/.cadre" "$S/nested" "$C/.cadre"
printf 'project # CONFIG_COMMENT_SENTINEL\n' > "$S/.cadre/roster"
printf 'explicit\n' > "$C/.cadre/roster"
printf 'global\n' > "$SANDBOX/state/roster"
printf 'change\n' >> "$S/app.js"
cd "$C" || exit 1
review project --base main "$S/nested"
check 'target root wins over invocation root and global' seat_state project ok
check 'project layer in manifest' has 'roster-layer: project' "$R/manifest.txt"
check 'project path in manifest' has "roster-path: $S/.cadre/roster" "$R/manifest.txt"
check 'report carries selection provenance' has 'roster-layer: project' "$R/report.md"
check 'raw config comment not recorded in manifest' lacks CONFIG_COMMENT_SENTINEL "$R/manifest.txt"

CADRE_ROSTER=environment review env --base main "$S"
check 'environment beats project and global' seat_state environment ok
check 'environment provenance' has 'roster-layer: environment' "$R/manifest.txt"
check 'environment has no configuration path' has "roster-path: ''" "$R/manifest.txt"
CADRE_ROSTER=environment review flag --roster explicit --base main "$S"
check 'explicit beats environment' seat_state explicit ok
check 'explicit provenance' has 'roster-layer: explicit' "$R/manifest.txt"

mv "$S/.cadre/roster" "$SANDBOX/project-roster"
review global --base main "$S"
check 'absent project falls back to global' seat_state global ok
check 'global provenance' has 'roster-layer: global' "$R/manifest.txt"
check 'global path recorded in manifest' has "roster-path: $SANDBOX/state/roster" "$R/manifest.txt"
check 'reviewer environment does not disclose selected layer or source path' has 'ROSTER_ENV=unset|unset' "$R/report.md"
mv "$SANDBOX/project-roster" "$S/.cadre/roster"

cd "$S/nested" || exit 1
OUT=$(run_cadre preflight); RC=$?
check 'preflight resolves current git root' test "$RC" -eq 0
check 'preflight selects project roster' test "${OUT#*Roster source: project}" != "$OUT"
printf '# nobody selected\n' > "$S/.cadre/roster"
check 'comment-only project refuses review instead of global fallback' refused 'commented out' review --base main "$S"
check 'comment-only project refuses preflight' refused 'commented out' preflight
: > "$S/.cadre/roster"
check 'empty project refuses review' refused 'empty or commented out' review --base main "$S"
printf 'project ?paths=\n' > "$S/.cadre/roster"
check 'empty paths gate refused' refused "malformed gate '?paths='" review --base main "$S"
check 'invalid project refuses preflight' refused "malformed gate '?paths='" preflight
rm "$S/.cadre/roster"
ln -s "$SANDBOX/missing-roster" "$S/.cadre/roster"
check 'unreadable project refuses fallback' refused 'cannot read project roster' review --base main "$S"
review unreadableoverride --roster explicit --base main "$S"
check 'explicit selection overrides unreadable project policy' seat_state explicit ok
rm "$S/.cadre/roster"
printf '$(touch %s)\n' "$SANDBOX/executed" > "$S/.cadre/roster"
check 'project config shell expression refused as invalid syntax' refused 'malformed gate' review --base main "$S"
check 'project config was never sourced' test ! -e "$SANDBOX/executed"
printf 'project\n' > "$S/.cadre/roster"

W="$SANDBOX/worktree"
git -C "$S" worktree add -qb linked "$W" main
mkdir -p "$W/.cadre" "$W/nested"
printf 'environment\n' > "$W/.cadre/roster"
printf 'change\n' >> "$W/app.js"
review worktree --base main "$W/nested"
check 'linked worktree uses its own project roster' seat_state environment ok
check 'linked worktree provenance uses worktree path' has "roster-path: $W/.cadre/roster" "$R/manifest.txt"

N="$S/nested-repo"
new_repo "$N"; mkdir -p "$N/.cadre"
printf 'explicit\n' > "$N/.cadre/roster"
printf 'change\n' >> "$N/app.js"
review nestedrepo --base main "$N"
check 'nested repository selects its own root' seat_state explicit ok

echo '== path gates over the actual diff =='
G="$SANDBOX/gates"; new_repo "$G"
mkdir -p "$G/old-auth" "$G/new-auth" "$G/delete-auth"
printf 'rename body\n' > "$G/old-auth/handler.js"
printf 'deleted body\n' > "$G/delete-auth/handler.js"
git -C "$G" add .; git -C "$G" commit -qm fixtures
git -C "$G" mv old-auth/handler.js new-auth/handler.js
rm "$G/delete-auth/handler.js"
mkdir -p "$G/新規" "$G/untracked"
printf 'new\n' > "$G/新規/café.js"
printf 'new\n' > "$G/untracked/space name.js"
printf 'new\n' > "$G/untracked/"$'tab\tname.js'
printf 'new\n' > "$G/untracked/"$'line\nbreak.js'
printf 'ignored/\n' > "$G/.gitignore"
mkdir -p "$G/ignored"; printf 'ignored\n' > "$G/ignored/hidden.js"

review paths --base main --roster 'project ?paths=old-auth/,environment ?paths=new-auth/,explicit ?paths=delete-auth/,global ?paths=新規/café' "$G"
for seat in project environment explicit global; do
  check "raw old/new/deleted/Unicode path selects $seat" seat_state "$seat" ok
done
review oddpaths --base main --roster 'project ?paths=space,environment ?paths=name.js,explicit ?paths=break.js,global ?paths=untracked/' "$G"
for seat in project environment explicit global; do
  check "untracked unusual filenames select $seat" seat_state "$seat" ok
done
review negative --base main --roster 'project ?paths=*.js,environment ?paths=OLD-AUTH,explicit ?paths=ignored/,global ?paths=new-auth/ ?min-files=999' "$G"
for seat in project environment explicit global; do
  check "literal/case/ignored/AND mismatch skips $seat" seat_state "$seat" skipped
done
check 'path gate skip explains missing match' has 'no changed path contains the literal substring' "$R/report.md"
review quotedpaths --base main --roster 'project ?paths=\t,environment ?paths=\n,explicit ?paths=\303' "$G"
for seat in project environment explicit; do
  check "Git-quoted escape text is not a raw path for $seat" seat_state "$seat" skipped
done
printf 'literal wildcard\n' > "$G/untracked/*.js"
review literalglob --base main --roster 'project ?paths=*.js' "$G"
check 'literal glob characters match an actual filename' seat_state project ok
review and --base main --roster 'project ?paths=new-auth/ ?min-files=2 ?min-lines=2 ?untested' "$G"
check 'path gate combines with passing existing gates' seat_state project ok
review bypass --all-seats --base main --roster 'project ?paths=absent ?min-files=999' "$G"
check 'all-seats bypasses paths' seat_state project ok
mkdir -p "$G/.cadre"
printf 'project ?paths=absent ?min-files=999\n' > "$G/.cadre/roster"
review full --full "$G/app.js"
check 'full file target discovers project roster and ignores gates' seat_state project ok
check 'full records gates inapplicable' has '--full review: seat gates do not apply' "$R/report.md"

# Raw old names also matter to ?untested, even after a rename out of tests.
T="$SANDBOX/renamed-tests"; new_repo "$T"
printf 'test body\n' > "$T/spec-case.js"
git -C "$T" add .; git -C "$T" commit -qm test
git -C "$T" mv spec-case.js production.js
review renamedtest --base main --roster 'project ?untested,environment ?paths=spec-case ?min-files=1,explicit ?min-files=2' "$T"
check 'renamed test old path defeats untested' seat_state project skipped
check 'old name matches a pure rename' seat_state environment ok
check 'pure rename counts as one file' seat_state explicit skipped

echo "$PASS passed; $FAIL failed"
[ "$FAIL" -eq 0 ]
