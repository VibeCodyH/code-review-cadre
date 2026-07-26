#!/usr/bin/env bash
# Run a staffed roster against a REAL change. The live half of cadre.
#
#   run-review.sh <repo> <base-rev> <out-dir> <jobs> <agent-spec ...>
#
# Deliberately NOT lib/run-pass.sh. That script resumes, pins a known sha,
# skips missing agents, and resets the checkout between reviewers. Every one of
# those is correct for a benchmark pass and wrong here, the last one
# destructively so. docs/METHOD.md, and the header comments below.
set -uo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CADRE_ROOT="${CADRE_ROOT:-$(dirname "$LIB_DIR")}"
# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"

REPO="${1:?usage: run-review.sh <repo> <base-rev> <out-dir> <jobs> <spec ...>}"
BASE_REV="${2:?need a base rev}"
OUT="${3:?need an out dir}"
JOBS="${4:-1}"
shift 4 2>/dev/null || shift $#
reviewers=("$@")
[ ${#reviewers[@]} -gt 0 ] || die "no reviewers given"

need git

# ★ Everything below runs against the USER'S repo, not a disposable clone. The
# only thing written into it is a temp ref, and it comes back out in this trap
# even on ^C. TMPREFS accumulates as they are created.
TMPREFS=()
WORKDIR=""
cleanup() {
  local r
  for r in ${TMPREFS+"${TMPREFS[@]}"}; do
    # Loud on failure. A ref left behind pins the snapshot commit in the user's
    # repo forever, so gc never reclaims their uncommitted work and a stale
    # refs/cadre/* collides with the next run.
    git -C "$REPO" update-ref -d "$r" 2>/dev/null \
      || echo "cadre: ⚠ could not delete $r in $REPO. Remove it with:
     git -C $REPO update-ref -d $r" >&2
  done
  [ -n "$WORKDIR" ] && [ -d "$WORKDIR" ] && rm -rf "$WORKDIR"
  return 0
}
# ★ INT/TERM must EXIT, not just clean up. A handler that returns lets execution
# resume where it was interrupted: Ctrl-C during a reviewer or a retry sleep
# tore down the refs and the checkout, then carried on running reviewers and
# writing a report against state that no longer existed. EXIT stays bare so the
# normal path cleans up once.
trap cleanup EXIT
trap 'echo; echo "cadre: interrupted, cleaning up." >&2; cleanup; trap - EXIT; exit 130' INT TERM

# ---- resolve the two commits ------------------------------------------------

git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $REPO"
git -C "$REPO" rev-parse --verify -q HEAD >/dev/null 2>&1 \
  || die "$REPO has no commits yet. Nothing to review against."

BASE=$(git -C "$REPO" rev-parse --verify -q "${BASE_REV}^{commit}") \
  || die "base does not resolve to a commit: $BASE_REV"

# ★ stash create builds a real commit whose tree IS the working tree, without
# touching the working tree and without writing a ref. Measured: it captures
# unstaged edits, staged-only files, renames, binaries and mode changes exactly,
# and EXCLUDES gitignored files. The obvious alternative,
# `git diff HEAD --binary | git apply --index`, round-trips through the patch
# format and corrupts anything behind a .gitattributes clean/smudge filter (LFS
# especially), because apply --index writes smudged bytes straight to the index.
# ★ Check the STATUS, not just the output. Measured: a clean tree gives rc=0
# with empty output, but a broken index (GIT_INDEX_FILE=/dev/null, an
# unresolved merge) gives rc=128 with empty output too. Reading "empty" as
# "clean" silently reviews HEAD and drops every working-tree change, which is
# a wrong answer wearing a correct one's clothes.
SNAP=$(git -C "$REPO" stash create "cadre review" 2>/dev/null); rc=$?
if [ "$rc" -ne 0 ]; then
  die "git stash create failed in $REPO (exit $rc).
     Cadre cannot snapshot the working tree, and reviewing HEAD instead would
     silently drop your changes. Check for an unresolved merge or a bad index."
fi
DIRTY=1
if [ -z "$SNAP" ]; then
  # Clean tree. stash create prints nothing; review HEAD itself.
  DIRTY=0
  SNAP=$(git -C "$REPO" rev-parse --verify HEAD) || die "cannot resolve HEAD"
fi

# Count untracked BEFORE deciding there is nothing to review: stash create does
# not consider new files a change, so a branch whose whole contribution is new
# files looks identical to HEAD here. Rejecting it would contradict the promise
# that untracked work is included.
# Checked: piping straight into wc -l would turn a git failure into "0 new
# files" and drop them from the review without a word.
newlist=$(git -C "$REPO" ls-files --others --exclude-standard) \
  || die "could not list untracked files in $REPO"
NEW=$(printf '%s' "$newlist" | grep -c . || true)

if [ "$BASE" = "$SNAP" ] && [ "$NEW" -eq 0 ]; then
  die "base and the reviewed state are the same commit ($(printf '%.9s' "$BASE"))
     and there are no new files. There is nothing to review. Pass --base
     explicitly, e.g. --base HEAD~1."
fi

# ★ Publish BOTH commits as temp refs before cloning. Resolving a rev in the
# source proves nothing about the clone: the stash commit is unreferenced, and
# a base that lives on another branch or a remote-tracking ref does not arrive
# under the same name. Fetching explicit refs is the only version that always
# has both objects present.
SR="refs/cadre/snap-$$"; BR="refs/cadre/base-$$"
git -C "$REPO" update-ref "$SR" "$SNAP" || die "could not write $SR in $REPO"
TMPREFS+=("$SR")
git -C "$REPO" update-ref "$BR" "$BASE" || die "could not write $BR in $REPO"
TMPREFS+=("$BR")

# ---- build the template checkout --------------------------------------------

mkdir -p "$CADRE_WORK" || die "cannot create $CADRE_WORK"
WORKDIR=$(mktemp -d "$CADRE_WORK/review-XXXXXXXX") || die "cannot create a work dir"
chmod 700 "$WORKDIR"
TPL="$WORKDIR/template"

# ★ A SYNTHETIC two-commit repo, not a clone of yours. This is the difference
# between a reviewer seeing your change and a reviewer seeing your history.
#
# A full clone carries every commit ever made, while secrets_preflight can only
# scan the tree that is checked out. Measured: a `.env` committed once and
# deleted long before the review base survives in a clone, passes the preflight
# because it is not in the current tree, and comes straight back out of
# `git log -p --all -- .env`. Auto-approving reviewers have git.
#
# So: fetch ONLY the two trees this review is about, --depth=1 so no ancestors
# come with them, and build two fresh commits with commit-tree. The result has
# exactly the base and the change under review in it, `BASE...HEAD` resolves
# normally, and there is no earlier history to mine because it was never
# transferred. Verified: the deleted-credential case yields zero hits.
# Match the source's object format. A sha1 client cannot fetch from a sha256
# repo at all: "fatal: mismatched algorithms". Measured, and it aborts the run.
fmt=$(git -C "$REPO" rev-parse --show-object-format 2>/dev/null) || fmt=sha1
git init -q --object-format="$fmt" "$TPL" \
  || git init -q "$TPL" \
  || die "could not init the review checkout"
git -C "$TPL" remote add origin "file://$(readlink -f "$REPO")" \
  || die "could not add the source remote"
git -C "$TPL" fetch -q --depth=1 --no-tags origin "+$SR:$SR" "+$BR:$BR" \
  || die "could not fetch the review refs"
btree=$(git -C "$TPL" rev-parse "$BR^{tree}") || die "cannot resolve the base tree"
stree=$(git -C "$TPL" rev-parse "$SR^{tree}") || die "cannot resolve the snapshot tree"
mk() { git -C "$TPL" -c user.name=cadre -c user.email=cadre@localhost \
         -c commit.gpgsign=false commit-tree "$@"; }
c1=$(mk "$btree" -m "base") || die "could not build the base commit"
c2=$(mk "$stree" -p "$c1" -m "change under review") || die "could not build the review commit"
# Checked. These refs are the ONLY thing keeping the source commits reachable
# in the checkout, and a commit is reachable means its message and its parents
# are readable. A silent failure here quietly undoes the isolation above.
git -C "$TPL" update-ref -d "$SR" || die "could not drop the snapshot ref from the checkout"
git -C "$TPL" update-ref -d "$BR" || die "could not drop the base ref from the checkout"
# The remote is a live file:// path into the user's repo, and every reviewer
# runs with tool auto-approval. It goes before anything is checked out.
git -C "$TPL" remote remove origin \
  || die "could not remove the origin remote from the checkout"
git -C "$TPL" checkout -q --detach "$c2" || die "could not check out the change"
# Drop the fetched objects that are no longer referenced, so the original
# commits are not merely unreferenced but gone. Checked: unreferenced is not
# unreadable, `git cat-file` and `git fsck --lost-found` both still reach an
# unpruned object, so a failure here leaves the source commits recoverable.
git -C "$TPL" reflog expire --expire=now --all >/dev/null 2>&1 \
  || die "could not expire the reflog in the checkout"
git -C "$TPL" gc --prune=now -q >/dev/null 2>&1 \
  || die "could not prune the checkout; the original commits would stay recoverable"
# What the reviewers diff against is the synthetic base. Keep the REAL shas for
# the manifest: a provenance record naming commits that exist only in a deleted
# temp directory cannot be used to reproduce anything.
REAL_BASE="$BASE" REAL_SNAP="$SNAP"
BASE="$c1"

# ★ Untracked files. stash create does not carry them, and most changes worth
# reviewing add a file, so a reviewer that cannot see it reviews half the
# change. --exclude-standard honours .gitignore, so .env.local still never
# enters the checkout.
# NOT gated on a dirty tree: a tree whose only change is new files is clean as
# far as stash create is concerned, and that is exactly a new-feature branch.
if [ "$NEW" -gt 0 ]; then
  # ★ -C must come BEFORE -cf. GNU tar treats it as positional, so with the
  # -C last it prints "has no effect" and exits 2. Measured: the copy silently
  # did nothing while the run reported the files as carried.
  git -C "$REPO" ls-files -z --others --exclude-standard \
    | tar -C "$REPO" --null -T - -cf - 2>/dev/null \
    | tar -xf - -C "$TPL" 2>/dev/null \
    || die "could not copy untracked files into the checkout.
     Reviewing without them would silently omit $NEW new file(s) from the diff."
  git -C "$TPL" add -A \
    || die "git add failed in the checkout; the new files would not reach the diff"
  # ★ -c commit.gpgsign=false and an inline identity. A clone inherits neither
  # the source repo's local user.name/user.email nor an available signing key,
  # and a global commit.gpgsign=true then fails the commit. Unchecked, that
  # left the new files in the worktree but OUT of HEAD, so the reviewers' own
  # `git diff BASE...HEAD` omitted every one of them while the run said
  # "carried". Failing loudly beats reviewing half a change.
  git -C "$TPL" -c user.name=cadre -c user.email=cadre@localhost \
      -c commit.gpgsign=false commit -q -m "cadre: working tree" \
    || die "could not commit the untracked files into the checkout"
  # The reviewed state is now this commit, not the stash. The manifest and the
  # banner both read SNAP, and recording a commit other than the one reviewed
  # makes the run unreproducible.
  SNAP=$(git -C "$TPL" rev-parse HEAD) || die "cannot resolve the checkout HEAD"
  echo "  carried $NEW untracked file(s) into the checkout"
fi

# Refuse before any auto-approving CLI sees the tree. This scans the CHECKOUT
# only, which is exactly why the checkout is synthetic: in a full clone a
# credential committed once and deleted long ago is absent from the tree, so it
# passes here, and is still one `git log -p` away. Two commits, no history.
secrets_preflight "$TPL"

SUB=$(git -C "$TPL" ls-files -s | awk '$1 == "160000"' | head -3)
[ -n "$SUB" ] && echo "  ⚠ submodules present; their contents are NOT in the checkout"

# ---- deterministic pre-pass ---------------------------------------------------

# ★ The one signal on this panel that is not a language model's opinion. Every
# reviewer here is wrong in correlated ways; a suite that exits non-zero is not
# wrong at all. Running it ONCE and handing all of them the same transcript
# costs one execution and removes a whole class of "by inspection" guessing
# about whether the change builds.
# Deliberately opt-in and deliberately not auto-detected. detect_test_cmd emits
# TEMPLATES with placeholders (`go test ./<pkg>`), which are examples for a
# reviewer to adapt and are not runnable. Guessing a runnable command would mean
# cadre executing whatever a repo's package.json says on a diff the user may not
# trust. The command has to be one a human typed.
# Ordered AFTER secrets_preflight on purpose: never execute a build in a tree
# that just failed the credential check.
PRERUN_FILE=""
PRERUN_RC=""
if [ -n "${CADRE_PRERUN:-}" ]; then
  mkdir -p "$OUT" || die "cannot create $OUT"
  PRERUN_FILE="$OUT/prerun.md"
  echo "  running the pre-pass: $CADRE_PRERUN"
  run_prerun "$TPL" "$WORKDIR" "$CADRE_PRERUN" "$PRERUN_FILE" \
    || die "the --prerun command did not run. Fix it or drop --prerun;
     handing reviewers a failed measurement as if it were a test result
     is worse than handing them none."
  if [ "$PRERUN_RC" = 0 ]; then echo "  pre-pass: exit 0"
  elif [ "$PRERUN_RC" = 124 ]; then echo "  ⚠ pre-pass TIMED OUT; reviewers are told so"
  else echo "  ⚠ pre-pass exit $PRERUN_RC; reviewers are told so"
  fi
fi

# ---- prompt ------------------------------------------------------------------

mkdir -p "$OUT" || die "cannot create $OUT"
PROMPT="$OUT/prompt.txt"
if [ -n "${CADRE_PROMPT_FILE:-}" ]; then
  # Rendered, not copied. run-pass.sh copies it verbatim, which silently drops
  # {{BASE}} and leaves the placeholder in the brief.
  render_review_prompt "$CADRE_PROMPT_FILE" "$BASE" "$TPL" "$PRERUN_FILE" > "$PROMPT"
else
  render_review_prompt "$CADRE_ROOT/lib/prompts/review-live.md" "$BASE" "$TPL" "$PRERUN_FILE" > "$PROMPT"
fi

{
  # ★ The REAL shas, the ones that exist in $REPO. The checkout is a synthetic
  # two-commit repo, so its own shas are meaningless the moment it is deleted,
  # and a provenance record you cannot resolve is not provenance.
  echo "repo:      $(readlink -f "$REPO")"
  echo "base:      $REAL_BASE"
  echo "snapshot:  $REAL_SNAP$([ "$DIRTY" = 1 ] && echo '  (working tree)')"
  echo "untracked: $NEW file(s) carried in"
  # ★ The snapshot sha is a STASH commit: unreferenced in the source once the
  # temp ref is dropped, so the next `git gc` reclaims it and the manifest
  # stops resolving. Measured. The TREE ids are what the reviewers actually
  # saw, and the reviewed tree includes the untracked files, which the count
  # above does not identify. These are content addresses: identical trees
  # produce identical ids, so they verify a re-run even after the commits die.
  echo "base-tree: $btree"
  echo "reviewed-tree: $(git -C "$TPL" rev-parse HEAD^{tree} 2>/dev/null || echo unknown)"
  echo "roster:    ${reviewers[*]}"
  # Provenance for the one non-model input. A report saying the suite passed is
  # only checkable if the manifest names the command that was run.
  # tr, because the manifest is one field per line and a multi-line command
  # would split into rows that parse as other fields.
  [ -n "$PRERUN_FILE" ] && echo "prerun:    exit $PRERUN_RC | $(printf '%s' "$CADRE_PRERUN" | tr '\n' ' ')"
  echo "prompt:    $(cksum < "$PROMPT" | cut -d' ' -f1)"
  echo "cadre:     $(git -C "$CADRE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$OUT/manifest.txt"

echo "reviewing ${REAL_BASE:0:9}..${REAL_SNAP:0:9} | ${#reviewers[@]} reviewer(s) | jobs=$JOBS"

mapfile -t SCRUB < <(scrubbed_env)

# ---- one reviewer ------------------------------------------------------------

run_one() {
  local spec="$1" idx="$2"
  local sl; sl=$(slug "$spec")
  local f="$OUT/$sl.md" log="$OUT/.log-$sl" st="$OUT/.status-$sl"
  local agent model dir attempt=1 rc w start took
  agent=$(spec_agent "$spec"); model=$(spec_model "$spec")

  : > "$log"
  # ★ A roster member that is not installed is a FAILURE, not a skip. run-pass
  # prints "skipping" and moves on, which in a live review is indistinguishable
  # from a reviewer that ran and found nothing.
  # ★ Ask agentcall rather than testing the name here. An adapter may run a
  # binary that is not called after it -- cursor's adapter runs `agent` -- and
  # this check declared such a reviewer missing on a machine where it works,
  # which is the most confusing failure available: it names a tool the user can
  # see on their PATH. agentcall owns the adapter contract, so it answers.
  # CADRE_AGENTS_D has to travel, exactly as it does on the real call below, or
  # agentcall answers about a different set of adapters than the one about to run.
  # ★ Captured, NOT piped into grep -q. Under `set -o pipefail` a -q consumer
  # exits on the first match, agentcall takes SIGPIPE, and the pipeline reports
  # failure -- so every reviewer whose name sorted early enough to match was
  # declared NOT INSTALLED. The suite caught it at 43 failures.
  local inst
  inst=$(CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
         "$CADRE_ROOT/bin/agentcall" --installed 2>/dev/null)
  case $'\n'"$inst"$'\n' in
    *$'\n'"$agent"$'\n'*) ;;
    *)
    echo "NOT INSTALLED: $agent is not on PATH" > "$f.failed"
    echo "failed" > "$st"
    echo "  $spec: NOT INSTALLED" >> "$log"
    return 0 ;;
  esac

  # Its own pristine checkout. Reviewers never share a tree, so nothing needs
  # resetting between them and --jobs is safe by construction.
  dir="$WORKDIR/r$idx"
  cp -a "$TPL" "$dir" || { echo "checkout copy failed" > "$f.failed"; echo failed > "$st"; return 0; }

  local m=(); [ -n "$model" ] && m=(-M "$model")
  start=$(date +%s)
  while :; do
    "${SCRUB[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
      CADRE_PASS_BASE="$BASE" \
      "$CADRE_ROOT/bin/agentcall" "$agent" -d "$dir" -m ro "${m[@]}" \
      < "$PROMPT" > "$f.part" 2>&1
    rc=$?
    # ★ The adapter's own verdict outranks the keyword match HERE too, not only
    # inside classify_run. rate_limited() is a keyword scan over small files, so
    # a short partial review that merely DISCUSSES rate limiting drove three
    # real retries with exponential backoff -- burning the quota the check
    # exists to protect -- and then had cadre's own "gave up" note appended
    # AFTER the adapter's _TRUNCATED line, displacing the marker out of the tail
    # window so the artifact was filed `failed` regardless. Fixing only
    # classify_run left both halves alive; a test on the end-to-end path is what
    # found them, after the unit-level order was already correct.
    [ "$(classify_run "$f.part" "$rc")" = failed ] || break
    rate_limited "$f.part" || break
    if [ "$attempt" -ge "${CADRE_RETRIES:-3}" ]; then
      # ★ PREPENDED, in the documented contract shape. Appending is the one
      # placement a tail-anchored marker cannot survive, and cadre writing into
      # the adapter's output at all is what made its own contract unreadable.
      { echo "DID NOT COMPLETE, rate limited, gave up after $attempt attempts."
        cat "$f.part"; } > "$f.part.tmp" && mv "$f.part.tmp" "$f.part"
      break
    fi
    w=$(retry_wait "$attempt")
    echo "  $spec: rate limited, waiting ${w}s ($((attempt + 1))/${CADRE_RETRIES:-3})" >> "$log"
    sleep "$w"; attempt=$((attempt + 1))
  done
  took=$(( $(date +%s) - start ))

  # Same classification as the benchmark path, in the same function. A partial
  # review lands at $f.partial, NOT at $f: every "is there a clean review here"
  # test downstream is `[ -s "$sl.md" ]`, so naming it anything else is what
  # keeps a truncated review out of the agreement math by construction.
  local state; state=$(classify_run "$f.part" "$rc")
  case "$state" in
    ok)
      mv "$f.part" "$f"
      echo ok > "$st"
      echo "  $spec: $(wc -c < "$f") bytes in ${took}s" >> "$log" ;;
    degraded)
      mv "$f.part" "$f.partial"
      echo degraded > "$st"
      echo "  $spec: DEGRADED after ${took}s, stopped early, partial review kept as $(basename "$f.partial")" >> "$log" ;;
    *)
      mv "$f.part" "$f.failed"
      echo failed > "$st"
      echo "  $spec: FAILED after ${took}s (rc=$rc), kept as $(basename "$f.failed")" >> "$log" ;;
  esac
  rm -rf "$dir"
}

i=0; running=0
for spec in "${reviewers[@]}"; do
  i=$((i + 1))
  echo "  $spec: started"
  if [ "$JOBS" -le 1 ]; then
    run_one "$spec" "$i"; cat "$OUT/.log-$(slug "$spec")"
  else
    while [ "$running" -ge "$JOBS" ]; do wait -n 2>/dev/null; running=$((running - 1)); done
    run_one "$spec" "$i" & running=$((running + 1))
  fi
done
[ "$JOBS" -gt 1 ] && { wait; for spec in "${reviewers[@]}"; do cat "$OUT/.log-$(slug "$spec")" 2>/dev/null; done; }

# ---- report ------------------------------------------------------------------

REPORT="$OUT/report.md"
{
  echo "# Review: ${REAL_BASE:0:9}..${REAL_SNAP:0:9}"
  echo
  sed 's/^/    /' "$OUT/manifest.txt"
  echo
  echo "## Reviewers"
  echo
} > "$REPORT"

ok_count=0 degraded_count=0 fail_count=0
for spec in "${reviewers[@]}"; do
  sl=$(slug "$spec")
  case "$(cat "$OUT/.status-$sl" 2>/dev/null)" in
    ok)
      ok_count=$((ok_count + 1)); echo "- \`$spec\` — ok" >> "$REPORT" ;;
    degraded)
      degraded_count=$((degraded_count + 1))
      echo "- \`$spec\` — **DEGRADED**, stopped early. Its findings are real; its" >> "$REPORT"
      echo "  silence is not. See \`$sl.md.partial\`." >> "$REPORT" ;;
    *)
      fail_count=$((fail_count + 1))
      echo "- \`$spec\` — **FAILED**, see \`$sl.md.failed\`" >> "$REPORT" ;;
  esac
done

# ★ Spell out what degraded costs the reader, once, where the counts are. The
# tempting read of a short partial review is "it looked and found little".
[ "$degraded_count" -gt 0 ] && {
  echo >> "$REPORT"
  echo "> A **DEGRADED** reviewer ran out of tokens or time partway through. Read" >> "$REPORT"
  echo "> what it found, but do not count the files it never mentioned as cleared," >> "$REPORT"
  echo "> and do not read it as disagreeing with anything it never reached." >> "$REPORT"
}

# CodeRabbit ships its own review contract and takes no prompt, so its row is
# not answering the same question as the others. Say so where it is read.
printf '%s\n' "${reviewers[@]}" | grep -q '^coderabbit' && {
  echo >> "$REPORT"
  echo "> \`coderabbit\` ignores the shared brief and applies its own review" >> "$REPORT"
  echo "> contract, so its findings are not answering the same question as the" >> "$REPORT"
  echo "> rest of this panel. Weigh agreement with it accordingly." >> "$REPORT"
}

for spec in "${reviewers[@]}"; do
  sl=$(slug "$spec")
  { echo; echo "## $spec"; echo; } >> "$REPORT"
  if [ -s "$OUT/$sl.md" ]; then cat "$OUT/$sl.md" >> "$REPORT"
  # ★ A partial review is printed IN FULL, not truncated to 20 lines like a
  # failure. It is a review; it is just not a complete one.
  elif [ -s "$OUT/$sl.md.partial" ]; then
    echo "_DEGRADED. Stopped early, so this covers only part of the diff._"$'\n' >> "$REPORT"
    cat "$OUT/$sl.md.partial" >> "$REPORT"
  else echo "_FAILED. Not a clean review._"$'\n' >> "$REPORT"
       head -20 "$OUT/$sl.md.failed" 2>/dev/null | sed 's/^/    /' >> "$REPORT"
  fi
done

rm -f "$OUT"/.log-* "$OUT"/.status-*
echo
echo "$ok_count ok, $degraded_count degraded, $fail_count failed. Report: $REPORT"
# Degraded counts toward having something to synthesize: partial findings are
# still findings. Only a panel with nothing at all is a dead run.
[ $((ok_count + degraded_count)) -gt 0 ] || {
  echo "every reviewer failed. Nothing to synthesize." >&2; exit 1; }
exit 0
