#!/usr/bin/env bash
# Mine (target, fix) commit pairs: B repairs A.
#
# For each fix-shaped commit B, blame B's parent at the exact lines B changed.
# The commit that last touched those lines is the candidate target A. Reported
# only when one A dominates the blame AND A is recent relative to B: that pairing
# is what makes A a plausible reviewable diff whose defect the author repaired
# next. The two non-obvious filters below are argued in docs/METHOD.md §2.
#
# Usage: mine-fixes.sh <repo-dir> [max-fix-commits] [max-age-days]
set -uo pipefail

REPO="${1:?repo dir}"
LIMIT="${2:-150}"
MAXAGE="${3:-120}"

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }

# Fix-shaped commits, excluding merges and version bumps.
# Reverts are dropped here, not left for the reader to spot: the "defect" is the
# whole feature, so the correct review comment is unbounded. docs/METHOD.md §2.
# The revert filter builds its tab with printf. A literal \t in a GNU grep -E
# pattern matches the letter "t", so the filter silently never fires.
mapfile -t FIXES < <(
  git -C "$REPO" log --no-merges -n "$LIMIT" \
      --format='%H%x09%at%x09%s' \
      --grep='^fix' --grep='[Ff]ixes #' -i \
  | grep -viE "^[0-9a-f]+$(printf '\t')[0-9]+$(printf '\t')\"?revert" \
  | grep -viE 'bump|release|changeset|v[0-9]+\.[0-9]+\.[0-9]+|typo|lint|format' \
  | grep -viE 'tsc|type ?check|deno type|\bCI\b|failing test|flaky|satisfy .* types|jsdoc|comment' || true
)

printf 'fix_sha\ttarget_sha\tsrc\ttest\tshare\tage\tfix_subject\n'

for line in "${FIXES[@]}"; do
  [ -n "$line" ] || continue
  B=$(cut -f1 <<<"$line"); BT=$(cut -f2 <<<"$line"); BS=$(cut -f3- <<<"$line")

  # Only single-parent commits with a modest, code-shaped footprint.
  nfiles=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null | grep -cE '\.(ts|tsx|js|jsx|py|go|rs|java|rb)$') || continue
  [ "${nfiles:-0}" -ge 1 ] && [ "${nfiles:-0}" -le 4 ] || continue

  # A fix that only edits tests or type declarations is not a behavioural defect
  # a reviewer could have caught in the target diff. Require at least one real
  # source file outside test/ and outside *.d.ts.
  nsrc=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null \
         | grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|rb)$' \
         | grep -viE '(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.|\.d\.ts$' -c) || nsrc=0
  [ "${nsrc:-0}" -ge 1 ] || continue

  # Require the fix to carry a test change too, the author proving the defect
  # was real. This is the single strongest signal that the target is gradeable.
  has_test=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null \
             | grep -ciE '(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.') || has_test=0
  [ "${has_test:-0}" -ge 1 ] || continue

  # Blame the parent at the pre-image line ranges B touched.
  declare -A votes=(); total=0
  while IFS= read -r f; do
    ranges=$(git -C "$REPO" diff -U0 "$B^" "$B" -- "$f" 2>/dev/null \
             | grep -oE '^@@ -[0-9]+(,[0-9]+)?' | sed 's/^@@ -//')
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      st=${r%%,*}; len=${r##*,}; [ "$len" = "$r" ] && len=1
      [ "$len" -eq 0 ] && continue
      [ "$st" -eq 0 ] && continue
      while IFS= read -r a; do
        [ -n "$a" ] || continue
        votes["$a"]=$(( ${votes["$a"]:-0} + 1 )); total=$((total+1))
      done < <(git -C "$REPO" blame -l --line-porcelain -L "$st,+$len" "$B^" -- "$f" 2>/dev/null \
               | grep -E '^[0-9a-f]{40} ' | cut -d' ' -f1)
    done <<<"$ranges"
  done < <(git -C "$REPO" diff --name-only "$B^" "$B" -- 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|rb)$')

  [ "$total" -gt 0 ] || { unset votes; continue; }

  # Dominant blame target.
  A=""; best=0
  for k in "${!votes[@]}"; do
    if [ "${votes[$k]}" -gt "$best" ]; then best=${votes[$k]}; A=$k; fi
  done
  unset votes
  [ -n "$A" ] || continue
  [ "$A" != "$B" ] || continue

  share=$(( best * 100 / total ))
  [ "$share" -ge 60 ] || continue

  AT=$(git -C "$REPO" log -1 --format=%at "$A" 2>/dev/null) || continue
  age=$(( (BT - AT) / 86400 ))
  [ "$age" -ge 0 ] && [ "$age" -le "$MAXAGE" ] || continue

  printf '%s\t%s\t%s\t%s\t%s%%\t%s\t%s\n' "${B:0:9}" "${A:0:9}" "$nsrc" "$has_test" "$share" "$age" "$BS"
done
