#!/usr/bin/env bash
# Mine (target, fix) commit pairs: B repairs A.
#
# For each fix-shaped commit B, blame B's parent at the exact lines B changed.
# The commit that last touched those lines is the candidate target A. Reported
# only when one A dominates the blame AND A is recent relative to B: that pairing
# is what makes A a plausible reviewable diff whose defect the author repaired
# next. The two non-obvious filters below are argued in docs/METHOD.md §2.
#
# Usage: mine-fixes.sh <repo-dir> [max-fix-commits] [max-age-days] [--verify]
set -uo pipefail

REPO="${1:?repo dir}"
LIMIT="${2:-150}"
MAXAGE="${3:-120}"
VERIFY="${CADRE_VERIFY_PAIRS:-0}"
[ "${4:-}" != --verify ] || VERIFY=1
case "$VERIFY" in 0|1) ;; *) echo 'CADRE_VERIFY_PAIRS must be 0 or 1' >&2; exit 2 ;; esac

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo: $REPO" >&2; exit 1; }
REPO=$(git -C "$REPO" rev-parse --show-toplevel) || exit 1
if [ "$VERIFY" = 1 ]; then
  CADRE_ROOT="${CADRE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"
  . "$CADRE_ROOT/lib/common.sh"
  . "$CADRE_ROOT/lib/verify-pair.sh"
  verify_pairs_init "$REPO"
fi

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

printf 'fix_sha\ttarget_sha\tsrc\ttest\tshare\tage\tfix_subject\tverification\n'

# ★ Every filter below is a place the table can silently become empty. Without
# a tally the output is a bare header and the reader cannot tell an empty repo
# from a filter that ate everything -- measured on a 1004-commit repo where all
# 200 fix-shaped commits died on the test-change filter alone. Counted here,
# reported on stderr so the TSV on stdout stays parseable.
n_cand=0 n_kept=0
d_footprint=0 d_nosrc=0 d_notest=0 d_noblame=0 d_nodominant=0 d_share=0 d_age=0

for line in "${FIXES[@]}"; do
  [ -n "$line" ] || continue
  n_cand=$((n_cand + 1))
  B=$(cut -f1 <<<"$line"); BT=$(cut -f2 <<<"$line"); BS=$(cut -f3- <<<"$line")

  # Only single-parent commits with a modest, code-shaped footprint.
  nfiles=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null | grep -cE '\.(ts|tsx|js|jsx|py|go|rs|java|rb)$') || { d_footprint=$((d_footprint + 1)); continue; }
  [ "${nfiles:-0}" -ge 1 ] && [ "${nfiles:-0}" -le 4 ] || { d_footprint=$((d_footprint + 1)); continue; }

  # A fix that only edits tests or type declarations is not a behavioural defect
  # a reviewer could have caught in the target diff. Require at least one real
  # source file outside test/ and outside *.d.ts.
  nsrc=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null \
         | grep -E '\.(ts|tsx|js|jsx|py|go|rs|java|rb)$' \
         | grep -viE '(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.|\.d\.ts$' -c) || nsrc=0
  [ "${nsrc:-0}" -ge 1 ] || { d_nosrc=$((d_nosrc + 1)); continue; }

  # A test change is a useful proxy, not proof that the test detects the defect.
  # Optional execution verification below checks both directions.
  has_test=$(git -C "$REPO" diff --name-only "$B^" "$B" 2>/dev/null \
             | grep -ciE '(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.') || has_test=0
  [ "${has_test:-0}" -ge 1 ] || { d_notest=$((d_notest + 1)); continue; }

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

  [ "$total" -gt 0 ] || { unset votes; d_noblame=$((d_noblame + 1)); continue; }

  # Dominant blame target.
  A=""; best=0
  for k in "${!votes[@]}"; do
    if [ "${votes[$k]}" -gt "$best" ]; then best=${votes[$k]}; A=$k; fi
  done
  unset votes
  [ -n "$A" ] || { d_nodominant=$((d_nodominant + 1)); continue; }
  [ "$A" != "$B" ] || { d_nodominant=$((d_nodominant + 1)); continue; }

  share=$(( best * 100 / total ))
  [ "$share" -ge 60 ] || { d_share=$((d_share + 1)); continue; }

  AT=$(git -C "$REPO" log -1 --format=%at "$A" 2>/dev/null) || { d_age=$((d_age + 1)); continue; }
  age=$(( (BT - AT) / 86400 ))
  [ "$age" -ge 0 ] && [ "$age" -le "$MAXAGE" ] || { d_age=$((d_age + 1)); continue; }

  n_kept=$((n_kept + 1))
  verification=unverified
  if [ "$VERIFY" = 1 ]; then
    verification=$(verify_pair "$REPO" "$B") || exit $?
  fi
  printf '%s\t%s\t%s\t%s\t%s%%\t%s\t%s\t%s\n' "${B:0:9}" "${A:0:9}" "$nsrc" "$has_test" "$share" "$age" "$BS" "$verification"
done

# ---- why the table is the size it is ------------------------------------
# stderr on purpose: cmd_setup pipes stdout through `tee`, and a diagnostic
# mixed into the TSV would corrupt every downstream reader of the file.
{
  echo
  echo "kept $n_kept of $n_cand fix-shaped commit(s). Dropped:"
  printf '  %5d  not 1-4 code files\n'                        "$d_footprint"
  printf '  %5d  no source file outside tests/ or *.d.ts\n'   "$d_nosrc"
  printf '  %5d  the fix changed no test file\n'              "$d_notest"
  printf '  %5d  nothing to blame in the parent\n'            "$d_noblame"
  printf '  %5d  no single dominant target commit\n'          "$d_nodominant"
  printf '  %5d  dominant target under 60%% of the blame\n'   "$d_share"
  printf '  %5d  target older than %s days\n'                 "$d_age" "$MAXAGE"

  if [ "$n_kept" -eq 0 ] && [ "$n_cand" -gt 0 ]; then
    echo
    echo "NOTHING SURVIVED. That is a property of this repo's history, not a crash."
    if [ "$d_notest" -ge $(( (n_cand + 1) / 2 )) ]; then
      cat <<'EOF'
The test-change filter took most of them. It is the strongest signal that a
defect was real (the author proved it with a test), but a repo that does not
commit tests alongside fixes will never satisfy it, and plenty of working repos
do not.

You do not need the miner. `cadre make-pass` takes the two shas directly:

  cadre make-pass <label> <repo-dir> <target-sha> <fix-sha>

Pick a fix commit you remember, find what it repaired, and read the draft key
carefully. Without the test filter the pairing is a guess, so the burden of
proving the target really introduced the defect moves onto you. ★ Check the
target against the code AROUND it at that time, not against the fix's subject
line: a commit titled "fix: ..." is often a requirements change, and a key built
on one scores every reviewer as missing a bug that was never there.
EOF
    else
      echo "Try a larger limit (cadre setup <repo> 500) or a longer max age"
      echo "(mine-fixes.sh <repo> <limit> <max-age-days>) before hand-picking."
    fi
  fi
} >&2
