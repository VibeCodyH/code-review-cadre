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
# ★ An EMPTY base rev is the mode switch, and it is positional on purpose: the
# caller cannot forget to pass it the way it could forget an env var, and no
# adapter environment carries it. Empty means "review this content as it
# stands", which is the only mode a non-git target can be reviewed in.
BASE_REV="${2-}"
MODE=diff; [ -n "$BASE_REV" ] || MODE=target
OUT="${3:?need an out dir}"
# ★ NOT `.log-*`, `.status-*`, `.len-*` or `.sha-*`. Those four globs are wiped at the
# bottom of this file, and a record that a cleanup line can match is a record
# that will eventually be deleted by someone extending that line. The name is
# the enforcement. Per-panel and under $OUT, because `cadre receipts` finds
# records by walking panel roots.
RUNLOG="$OUT/runs.jsonl"
JOBS="${4:-1}"
shift 4 2>/dev/null || shift $#
reviewers=("$@")
skipped_rows=()
[ -n "${CADRE_SKIPPED:-}" ] && mapfile -t skipped_rows <<< "$CADRE_SKIPPED"
[ ${#reviewers[@]} -gt 0 ] || [ ${#skipped_rows[@]} -gt 0 ] || die "no reviewers given"

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

# ---- diff mode: resolve the two commits and build the checkout --------------
#
# Unchanged behaviour, moved into a function so target mode can build its own
# checkout without either path having to test the mode as it goes.
build_diff_checkout() {

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
}

# ---- target mode: review content as it stands -------------------------------
#
# No base, no diff, and the target need not be a git repo. A file, a docs
# directory, a vendored tree someone handed you: whatever you point at.
#
# ★ This mode is strictly MORE exposing than a diff review, and the code has to
# be built around that fact rather than around the convenience of reusing the
# diff path. A diff review shows a reviewer what changed; this shows it
# everything under the target. So there is no fetch and no clone here at all:
# nothing but the named files is copied, and history cannot leak because it is
# never transferred in any form.
#
# The base is the EMPTY TREE. That is not a trick to reuse the diff plumbing --
# it is what the content is: `BASE...HEAD` resolves normally and shows the whole
# target as added, so a reviewer's own git commands work the way they do in
# every other mode, with nothing before it to compare against.
build_target_checkout() {
  mkdir -p "$CADRE_WORK" || die "cannot create $CADRE_WORK"
  WORKDIR=$(mktemp -d "$CADRE_WORK/review-XXXXXXXX") || die "cannot create a work dir"
  chmod 700 "$WORKDIR"
  TPL="$WORKDIR/template"
  git init -q "$TPL" || die "could not init the review checkout"

  # ★ WHAT ENTERS THE CHECKOUT is the whole safety question in this mode, and
  # .gitignore is the only place a repo says which of its files are not for
  # sharing. Three sources, one rule:
  #   - a single file: just that file.
  #   - a git repo: ask git. --cached --others --exclude-standard is tracked plus
  #     new, minus ignored, which is the same rule the diff path uses.
  #   - anything else: copy the tree, then apply any .gitignore that came with
  #     it below. A directory that is not a repo can still carry the file, and
  #     honouring it is the difference between reviewing a project and handing
  #     four auto-approving CLIs its .env.
  # NUL-delimited throughout: a filename with a space in it is ordinary, and a
  # newline-delimited list silently splits it into two names that do not exist.
  local flist="$WORKDIR/filelist" src base_dir
  if [ -f "$REPO" ]; then
    src=file; base_dir=$(dirname "$REPO")
    printf '%s\0' "$(basename "$REPO")" > "$flist" || die "cannot write the file list"
  elif git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1; then
    src=git; base_dir="$REPO"
    git -C "$REPO" ls-files -z --cached --others --exclude-standard > "$flist" \
      || die "could not list the files under $REPO"
  else
    src=plain; base_dir="$REPO"
    # Paths keep their leading ./ -- tar handles them, and stripping it portably
    # needs GNU find -printf or GNU sed -z, neither of which is on macOS.
    (cd "$REPO" && find . -name .git -prune -o -type f -print0) > "$flist" \
      || die "could not list the files under $REPO"
  fi
  [ -s "$flist" ] || die "nothing to review under $REPO.
     Either it is empty, or every file in it is ignored by .gitignore."

  tar -C "$base_dir" --null -T "$flist" -cf - 2>/dev/null \
    | tar -xf - -C "$TPL" 2>/dev/null \
    || die "could not copy $REPO into the review checkout"

  git -C "$TPL" add -A || die "git add failed in the review checkout"
  # ★ .gitignore applied to the WORKTREE, not just the index. `git add` skips an
  # ignored file, which keeps it out of the diff and leaves it sitting in the
  # directory every reviewer runs in -- and secrets_preflight skips ignored files
  # too, so an ignored .env passed the credential check and was still readable.
  # Only reachable for a plain tree, since git's own listing never emits one.
  if [ "$src" = plain ]; then
    local ign nign
    ign=$(git -C "$TPL" ls-files -z --others --ignored --exclude-standard) || ign=""
    if [ -n "$ign" ]; then
      nign=$(printf '%s' "$ign" | tr -dc '\0' | wc -c | tr -d ' ')
      # No -r: it is a GNU extension that BSD xargs rejects outright, and the
      # empty case it guards is already excluded by the test above.
      (cd "$TPL" && printf '%s' "$ign" | xargs -0 rm -f) \
        || die "could not remove gitignored files from the checkout.
     They would be readable by every reviewer and invisible to the preflight."
      find "$TPL" -mindepth 1 -name .git -prune -o -type d -empty -delete 2>/dev/null
      git -C "$TPL" add -A || die "git add failed after applying .gitignore"
      echo "  $nign file(s) excluded by .gitignore"
    fi
  fi

  # ★ The size ceiling, checked after the copy and before any reviewer exists.
  # secrets_preflight catches credentials; nothing caught "you pointed this at a
  # tree with node_modules in it and handed 40,000 files to four models". Counted
  # from the CHECKOUT so the number is what will actually be read, and measured
  # with find/du rather than du --files0-from, which is GNU-only.
  local nfiles nkb maxf maxk
  nfiles=$(find "$TPL" -path "$TPL/.git" -prune -o -type f -print 2>/dev/null | grep -c . || true)
  nkb=$(du -sk "$TPL" 2>/dev/null | cut -f1); case "$nkb" in ''|*[!0-9]*) nkb=0 ;; esac
  maxf="${CADRE_TARGET_MAX_FILES:-2000}"
  maxk="${CADRE_TARGET_MAX_KB:-20480}"
  case "$maxf$maxk" in *[!0-9]*) die "CADRE_TARGET_MAX_FILES and CADRE_TARGET_MAX_KB must be numbers" ;; esac
  if [ "$nfiles" -gt "$maxf" ] || [ "$nkb" -gt "$maxk" ]; then
    local big
    big=$(git -C "$TPL" ls-files | sed -n 's|/.*||p' | sort | uniq -c | sort -rn | head -3 \
          | awk '{printf "       %s (%s files)\n", $2, $1}')
    die "that target is too big to review whole: $nfiles file(s), ${nkb}KB.
     Biggest directories:
$big
     Every reviewer on the roster reads all of it, so this is a bill as much as
     it is a review. Point --full at a subdirectory, or raise
     CADRE_TARGET_MAX_FILES (now $maxf) / CADRE_TARGET_MAX_KB (now $maxk)."
  fi

  # The base is the EMPTY TREE, so BASE...HEAD is the whole target and the
  # reviewers' own git commands behave the way they do in diff mode.
  local empty tree c1 c2
  mk() { git -C "$TPL" -c user.name=cadre -c user.email=cadre@localhost \
           -c commit.gpgsign=false commit-tree "$@"; }
  # -w, so the object is WRITTEN and not merely hashed. git has the empty tree
  # hardcoded, so commit-tree accepts it either way today; a version that did
  # not would fail with "not a valid object name" and this costs nothing.
  empty=$(git -C "$TPL" hash-object -w -t tree /dev/null) || die "could not resolve the empty tree"
  tree=$(git -C "$TPL" write-tree) || die "could not write the content tree"
  c1=$(mk "$empty" -m "empty") || die "could not build the base commit"
  c2=$(mk "$tree" -p "$c1" -m "content under review") || die "could not build the review commit"
  git -C "$TPL" checkout -q --detach "$c2" || die "could not check out the content"
  git -C "$TPL" reflog expire --expire=now --all >/dev/null 2>&1
  git -C "$TPL" gc --prune=now -q >/dev/null 2>&1

  BASE="$c1"; SNAP="$c2"; btree="$empty"
  # No source revisions exist in this mode. The manifest must not print an empty
  # field where a sha goes, so it branches on MODE rather than on these.
  REAL_BASE=""; REAL_SNAP=""; DIRTY=0; NEW=0
  # ★ The provenance record for this mode. WORKDIR is a mktemp that gets deleted,
  # so once the run ends nothing on disk would say which files a reviewer saw --
  # and "reviewed the docs directory" is not a record anyone can check. The tree
  # id is a content address, so it verifies a re-run even after the temp dir dies.
  TARGET_TREE="$tree"; TARGET_NFILES="$nfiles"; TARGET_KB="$nkb"; TARGET_SRC="$src"
  echo "  $nfiles file(s), ${nkb}KB, from $REPO"
}

if [ "$MODE" = target ]; then build_target_checkout; else build_diff_checkout; fi

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
  # ★ A different brief, not the diff brief with the diff sentence deleted. A
  # reviewer told to review a change reports on volume: pointed at a whole tree
  # with the diff framing left in, it treats every file as new work and inflates
  # accordingly. The target brief says so explicitly.
  BRIEF=review-live.md; [ "$MODE" = diff ] || BRIEF=review-target.md
  render_review_prompt "$CADRE_ROOT/lib/prompts/$BRIEF" "$BASE" "$TPL" "$PRERUN_FILE" > "$PROMPT"
fi

# ★ Frozen HERE, once, before a single seat is dispatched (#37). Recomputing per
# seat would let a mid-panel edit land in half the rows and read as two seats
# legitimately disagreeing about the harness, which is the opposite of what the
# field is for. Same reasoning as docs/METHOD.md's refusal to edit lib/ mid-sweep,
# made checkable instead of asked for.
HARNESS_SHA=$(harness_sha)
PROMPT_SHA=$(content_sha "$PROMPT")
# Dominant language of the change, from the checkout itself (#9). In target
# mode the base is the empty tree, so this is the whole target.
CHANGE_LANG=$(detect_language "$TPL" "$BASE" HEAD)

# ★ Capability preflight BEFORE any paid call. A seat whose adapter (or model)
# has declared it cannot do this job is skipped loudly, not dispatched. Same
# skipped-seat path as roster gates: slots.tsv status, report line, out of
# panel seat counts and synthesis. See seat_declarations in common.sh.
_kept=(); _block=""; _decl=""; _reason=""
for _spec in "${reviewers[@]}"; do
  _block=""
  if _block=$(capability_block "$_spec" reviewer "$PROMPT"); then
    IFS=$'\t' read -r _decl _reason <<< "$_block"
    skipped_rows+=("$_spec"$'\t'"$_decl"$'\t'"$_reason")
    echo "  $_spec: SKIPPED by capability preflight ($_decl: $_reason)"
    continue
  fi
  _kept+=("$_spec")
done
reviewers=("${_kept[@]}")
unset _kept _spec _block _decl _reason

{
  # ★ The REAL shas, the ones that exist in $REPO. The checkout is a synthetic
  # two-commit repo, so its own shas are meaningless the moment it is deleted,
  # and a provenance record you cannot resolve is not provenance.
  echo "mode:      $MODE"
  echo "target:    $(readlink -f "$REPO")"
  if [ "$MODE" = diff ]; then
    echo "base:      $REAL_BASE"
    echo "snapshot:  $REAL_SNAP$([ "$DIRTY" = 1 ] && echo '  (working tree)')"
    echo "untracked: $NEW file(s) carried in"
  else
    # ★ No revision exists to record, so the file list IS the provenance. Without
    # it, "cadre review --full ./docs" leaves nothing on disk saying what was in
    # the checkout: the work dir is a mktemp that gets deleted at exit. The tree
    # id is a content address, so it verifies a re-run after the temp dir is gone.
    echo "source:    $TARGET_SRC ($TARGET_NFILES file(s), ${TARGET_KB}KB)"
    echo "files:     $OUT/files.txt"
    git -C "$TPL" ls-files > "$OUT/files.txt" || echo "cadre: ⚠ could not record the file list" >&2
  fi
  # ★ The snapshot sha is a STASH commit: unreferenced in the source once the
  # temp ref is dropped, so the next `git gc` reclaims it and the manifest
  # stops resolving. Measured. The TREE ids are what the reviewers actually
  # saw, and the reviewed tree includes the untracked files, which the count
  # above does not identify. These are content addresses: identical trees
  # produce identical ids, so they verify a re-run even after the commits die.
  echo "base-tree: $btree"
  echo "reviewed-tree: $(git -C "$TPL" rev-parse HEAD^{tree} 2>/dev/null || echo unknown)"
  echo "roster:    ${reviewers[*]}"
  # Blank when nothing recognisable changed -- the same EMPTY the record carries,
  # not a stand-in word that would read as a detected value.
  echo "language:  $CHANGE_LANG"
  # Provenance for the one non-model input. A report saying the suite passed is
  # only checkable if the manifest names the command that was run.
  # tr, because the manifest is one field per line and a multi-line command
  # would split into rows that parse as other fields.
  [ -n "$PRERUN_FILE" ] && echo "prerun:    exit $PRERUN_RC | $(printf '%s' "$CADRE_PRERUN" | tr '\n' ' ')"
  echo "prompt:    $(cksum < "$PROMPT" | cut -d' ' -f1)"
  # ★ Content, beside the revision, not instead of it. `cadre:` is a git sha and
  # goes stale the moment lib/ is dirty; this one changes with the bytes. Kept
  # here as well as on every row so a panel killed before slots.tsv was written
  # still says which harness produced its artifacts.
  echo "harness:   ${HARNESS_SHA:-unknown}"
  echo "cadre:     $(git -C "$CADRE_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} > "$OUT/manifest.txt"

if [ "$MODE" = diff ]; then
  echo "reviewing ${REAL_BASE:0:9}..${REAL_SNAP:0:9} | ${#reviewers[@]} reviewer(s) | jobs=$JOBS"
else
  echo "reviewing $TARGET_NFILES file(s) as they stand | ${#reviewers[@]} reviewer(s) | jobs=$JOBS"
fi

mapfile -t SCRUB < <(scrubbed_env)

# ---- one reviewer ------------------------------------------------------------

# One completion event per terminal path in run_one. Every `return` in that
# function pairs with a call to this, so "dispatched but never completed" stays
# a fact about the run rather than an artefact of where the code exits.
#
# ★ secs is passed EMPTY, never 0, for a path that never timed anything -- a
# roster member that was not installed did not take zero seconds, it was never
# measured, and record_event turns an empty numeric into `null`. Bytes come from
# the artifact rather than any log line, so the number always describes the file
# that is actually on disk.
#
# ★ The hashes are read from the DISPATCH scratch file, not recomputed here.
# Recomputing would describe the tree as it stands after the seat finished,
# which on a long panel is a different tree than the one that was reviewed --
# and the whole point of the field is to make that difference visible.
# They are STRINGS, not `#` numerics: EMPTY means "not determined" and must stay
# an empty field, where a numeric null would print the same but claim a measure.
record_complete() {  # <slug> <spec> <state> [rc] [secs]
  local sl="$1" spec="$2" state="$3" rc="${4:-}" secs="${5:-}" art bytes shaf
  art="$OUT/$sl.md"
  [ -s "$art" ] || art="$OUT/$sl.md.partial"
  [ -s "$art" ] || art="$OUT/$sl.md.inconclusive"
  [ -s "$art" ] || art="$OUT/$sl.md.failed"
  bytes=$(wc -c < "$art" 2>/dev/null | tr -d ' ')
  shaf="$OUT/.sha-$sl"
  # ★ `model` is what the ADAPTER declared over the meta channel (cadre_model,
  # #51), read before the caller deletes the file. EMPTY unless declared: the
  # spec already names the model for every seat that pins one, and this field
  # exists for the seat that cannot -- so a value here is a measurement of what
  # served, never a copy of what was asked for.
  record_event "$RUNLOG" event=complete panel="$(basename "$OUT")" \
    seat="$spec" family="$(spec_family "$spec")" slug="$sl" \
    state="$state" "rc#=$rc" "secs#=$secs" "bytes#=${bytes:-0}" \
    "prompt_bytes#=$(cat "$OUT/.len-$sl" 2>/dev/null)" \
    "v#=$SLOTS_SCHEMA_V" \
    prompt_sha="$(sed -n 1p "$shaf" 2>/dev/null)" \
    adapter_sha="$(sed -n 2p "$shaf" 2>/dev/null)" \
    harness_sha="$HARNESS_SHA" \
    model="$(sed -n 's/^model=//p' "$OUT/$sl.md.part.meta" 2>/dev/null | tail -1)" \
    language="$CHANGE_LANG" "ts#=$(date +%s)"
}

run_one() {
  local spec="$1" idx="$2"
  local sl; sl=$(slug "$spec")
  local f="$OUT/$sl.md" log="$OUT/.log-$sl" st="$OUT/.status-$sl" len="$OUT/.len-$sl"
  local shaf="$OUT/.sha-$sl"
  local agent model dir attempt=1 rc w start took
  agent=$(spec_agent "$spec"); model=$(spec_model "$spec")

  : > "$log"
  # Zero is measured here: until agentcall is reached, the harness has sent no
  # prompt. Overwrite it at the dispatch site so adapter failures still retain
  # the exact prompt size after the scratch files disappear.
  echo 0 > "$len"
  # ★ Line 1 prompt, line 2 adapter (#37). Written BEFORE the installed check,
  # so a seat that never runs still records which adapter file was consulted --
  # "the adapter is missing" and "the adapter is present and broken" are
  # different facts and the row should not need the console to tell them apart.
  # Line 1 stays EMPTY until dispatch: the prompt this seat is charged for is
  # the one agentcall actually receives, and a promptless adapter never receives
  # one at all.
  printf '\n%s\n' "$(adapter_sha "$agent")" > "$shaf"
  # ★ Recorded BEFORE anything can go wrong, which is the entire reason the log
  # is append-only rather than assembled at the end: a panel killed here leaves
  # proof this seat was dispatched. Every `return` below has a matching
  # `complete`, so a dispatch with no completion IS the signal that a seat was
  # cut off mid-flight -- not a gap to be guessed at later.
  record_event "$RUNLOG" event=dispatch panel="$(basename "$OUT")" \
    seat="$spec" family="$(spec_family "$spec")" slug="$sl" language="$CHANGE_LANG" "ts#=$(date +%s)"
  # ★ A roster member that is not installed is a FAILURE, not a skip. run-pass
  # prints "skipping" and moves on, which in a live review is indistinguishable
  # from a reviewer that ran and found nothing.
  # agent_installed asks agentcall rather than testing the name; the reasons it
  # has to work that way are in lib/common.sh, and they cost two bugs to learn.
  if ! agent_installed "$agent"; then
    echo "NOT INSTALLED: $agent is not on PATH" > "$f.failed"
    echo "failed" > "$st"
    echo "  $spec: NOT INSTALLED" >> "$log"
    record_complete "$sl" "$spec" failed
    return 0
  fi

  # Its own pristine checkout. Reviewers never share a tree, so nothing needs
  # resetting between them and --jobs is safe by construction.
  dir="$WORKDIR/r$idx"
  cp -a "$TPL" "$dir" || {
    echo "checkout copy failed" > "$f.failed"; echo failed > "$st"
    record_complete "$sl" "$spec" failed
    return 0
  }

  local m=(); [ -n "$model" ] && m=(-M "$model")
  start=$(date +%s)
  # Promptless adapters use their own contract; zero is the exact number of
  # shared-brief bytes they send to their provider.
  if ! is_promptless "$agent"; then
    wc -c < "$PROMPT" | tr -d ' ' > "$len"
    # ★ EMPTY for a promptless adapter, never the hash of a prompt it did not
    # get. `prompt_bytes` records a measured 0 there because zero shared-brief
    # bytes really were sent; the identity of a prompt that was never dispatched
    # is not zero, it is unknown, and a sha of the empty string would compare
    # equal across every promptless seat as if they shared an input.
    local asha; asha=$(sed -n 2p "$shaf" 2>/dev/null)
    printf '%s\n%s\n' "$PROMPT_SHA" "$asha" > "$shaf"
  fi
  while :; do
    # ★ A TEMP path, never "$f.part.meta". The meta file is handed to the
    # adapter, and $OUT is the directory holding every other reviewer's output --
    # the exact thing CADRE_WORK was added to the scrub list to protect. A temp
    # path gives an adapter somewhere to declare its state while telling it
    # nothing about where the panel lives. Moved next to the artifact afterward,
    # by cadre, so classify_run can find it by convention.
    # ★ A private DIRECTORY, not a bare mktemp file. The declaration is trusted
    # over the artifact's own text, so who can write it matters. A model with a
    # shell runs as the SAME UID as cadre -- grok's ro mode allows bash -- and
    # the cheap attack is a blind spray: `for f in /tmp/tmp.*; [ -w "$f" ] &&
    # echo state=ok >> "$f"`, which upgrades a truncated review to a complete
    # one. A directory does not match that `[ -f ]`. It is a speed bump, not a
    # boundary: same-uid means no filesystem barrier, and a child that walks
    # /proc/<pid>/environ can still find the path. See docs/ADDING-AN-AGENT.md --
    # a declaration is trusted exactly as much as the adapter is.
    metad=$(mktemp -d); meta="$metad/state"; rm -f "$f.part.meta"
    "${SCRUB[@]}" CADRE_AGENTS_D="${CADRE_AGENTS_D:-$CADRE_HOME/agents.d}" \
      CADRE_PASS_BASE="$BASE" CADRE_RUN_META="$meta" \
      "$CADRE_ROOT/bin/agentcall" "$agent" -d "$dir" -m ro "${m[@]}" \
      < "$PROMPT" > "$f.part" 2>&1
    rc=$?
    [ -s "$meta" ] && mv "$meta" "$f.part.meta"
    rm -rf "$metad"
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
    # ★ The benchmark path's three refusals, in the benchmark path's order, and
    # this path never had them. Measured on the live runner, 2026-08-29: the
    # copilot seat's "You have exceeded your monthly quota" matched the rate
    # scan below and was retried three times at 60/120/240s -- on 164 reviews,
    # 31,322 seconds of a single-lane queue waiting on an account that no
    # backoff could refill. A usage window is the same waste with a reset time
    # attached. Neither is a throughput ceiling; neither gets a retry.
    if provider_window_closed "$f.part"; then
      { echo "DID NOT COMPLETE, provider usage window closed, not retried: $(head -c 160 "$f.part" | tr '\n' ' ')"
        cat "$f.part"; } > "$f.part.tmp" && mv "$f.part.tmp" "$f.part"
      echo "  $spec: ⏸ usage window CLOSED, not a rate limit; not retried" >> "$log"
      break
    fi
    if quota_exhausted "$f.part"; then
      { echo "DID NOT COMPLETE, out of budget, not retried: $(head -c 160 "$f.part" | tr '\n' ' ')"
        cat "$f.part"; } > "$f.part.tmp" && mv "$f.part.tmp" "$f.part"
      echo "  $spec: ⛔ OUT OF BUDGET, not a rate limit; not retried" >> "$log"
      break
    fi
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
    # ★ Its own suffix, so cmd_synthesize excludes it by construction: that
    # function picks up .md and .md.partial and drops everything else into
    # dead[], which is already told to keep those members out of every
    # agreement tag. The false green closes there, with no prompt change.
    inconclusive)
      mv "$f.part" "$f.inconclusive"
      echo inconclusive > "$st"
      echo "  $spec: INCONCLUSIVE after ${took}s (rc=$rc), returned text but no review, kept as $(basename "$f.inconclusive")" >> "$log" ;;
    # ★ Same one-bucket-three-messages split as the benchmark path (#12), in the
    # same function, for the same reason the classification is shared: a panel
    # operator reading "FAILED (rc=124)" cannot tell a timeout kill from a
    # provider outage, and the two need opposite responses.
    *)
      mv "$f.part" "$f.failed"
      echo failed > "$st"
      echo "  $spec: $(failure_phrase "$f.failed" "$rc" "$took"), kept as $(basename "$f.failed")" >> "$log" ;;
  esac
  # After the `mv`, so `bytes` describes the artifact under its final name.
  record_complete "$sl" "$spec" "$state" "$rc" "$took"
  # ★ The declaration has done its job: classify_run read it, and runs.jsonl is
  # where the state lives durably now. Leaving it behind would strand a `.meta`
  # naming an artifact that has since been renamed -- and a stale declaration
  # that outlives the run it describes is worse than none, because the next
  # attempt at this slot would be classified by the last one's field.
  rm -f "$f.part.meta"
  rm -rf "$dir"
}

# ★ A gated-off seat is a STATE, not a special case. Recording it as an ordinary
# completion whose `state` is `skipped` is what lets every downstream renderer
# read one stream instead of joining the record against a second list -- which
# is the join that produced slots.tsv's separate skipped block and the Receipts
# table's dependence on that file. Zero spend is MEASURED here: a seat that
# never ran sent no prompt and received no bytes, so those are real zeroes.
# `secs` stays null, because nothing was timed.
for row in "${skipped_rows[@]}"; do
  IFS=$'\t' read -r sk_spec _sk_gate _sk_reason <<< "$row"
  # prompt_sha is EMPTY for the same reason prompt_bytes is a measured 0: the
  # seat sent nothing, so there is no dispatched prompt to identify. The adapter
  # and the harness are still recorded -- the gate that skipped it is a harness
  # decision, and which version made it is exactly what a later reader asks.
  record_event "$RUNLOG" event=complete panel="$(basename "$OUT")" \
    seat="$sk_spec" family="$(spec_family "$sk_spec")" slug="$(slug "$sk_spec")" \
    state=skipped "rc#=" "secs#=" "bytes#=0" "prompt_bytes#=0" \
    "v#=$SLOTS_SCHEMA_V" prompt_sha= \
    adapter_sha="$(adapter_sha "$(spec_agent "$sk_spec")")" \
    harness_sha="$HARNESS_SHA" model= language="$CHANGE_LANG" "ts#=$(date +%s)"
done

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
  if [ "$MODE" = diff ]; then
    echo "# Review: ${REAL_BASE:0:9}..${REAL_SNAP:0:9}"
  else
    echo "# Review: $(basename "$(readlink -f "$REPO")") as it stands ($TARGET_NFILES file(s))"
  fi
  echo
  sed 's/^/    /' "$OUT/manifest.txt"
  echo
  echo "## Reviewers"
  echo
  [ -n "${CADRE_GATE_NOTICE:-}" ] && echo "$CADRE_GATE_NOTICE."
} > "$REPORT"

ok_count=0 degraded_count=0 inconc_count=0 fail_count=0 misconf_count=0
for spec in "${reviewers[@]}"; do
  sl=$(slug "$spec")
  case "$(cat "$OUT/.status-$sl" 2>/dev/null)" in
    ok)
      ok_count=$((ok_count + 1)); echo "- \`$spec\` — ok" >> "$REPORT" ;;
    degraded)
      degraded_count=$((degraded_count + 1))
      echo "- \`$spec\` — **DEGRADED**, stopped early. Its findings are real; its" >> "$REPORT"
      echo "  silence is not. See \`$sl.md.partial\`." >> "$REPORT" ;;
    inconclusive)
      inconc_count=$((inconc_count + 1))
      echo "- \`$spec\` — **INCONCLUSIVE**. It ran and returned text, but the text" >> "$REPORT"
      echo "  is not a review: no findings and no verdict. Not counted as a" >> "$REPORT"
      echo "  reviewer. See \`$sl.md.inconclusive\`." >> "$REPORT" ;;
    *)
      fail_count=$((fail_count + 1))
      # ★ Same bucket, different sentence (#31). A seat that never ran because
      # of a fault on this box is not a reviewer that failed, and the reader
      # of "FAILED" goes looking for a model problem that does not exist.
      if [ "$(failure_kind "$OUT/$sl.md.failed")" = misconfigured ]; then
        misconf_count=$((misconf_count + 1))
        echo "- \`$spec\` — **MISCONFIGURED**, never ran: $(misconfigured_line "$OUT/$sl.md.failed" | cut -c1-160). A fault on this box, not a reviewer verdict." >> "$REPORT"
      else
        echo "- \`$spec\` — **FAILED**, see \`$sl.md.failed\`" >> "$REPORT"
      fi ;;
  esac
done

for row in "${skipped_rows[@]}"; do
  IFS=$'\t' read -r spec gate reason <<< "$row"
  # Roster gates are ?min-lines / ?min-files / ?untested. Anything else is a
  # capability declaration (role:reviewer, prompt:security-audit, …).
  case "$gate" in
    \?*)
      echo "- \`$spec\` — SKIPPED by its roster gate ($gate: $reason)." >> "$REPORT" ;;
    *)
      echo "- \`$spec\` — SKIPPED by capability preflight ($gate: $reason)." >> "$REPORT" ;;
  esac
done

# ★ A misconfigured seat is counted under failed above, so the totals stay
# comparable across runs; this line is where the reader learns the panel was
# smaller than requested for a reason that is theirs to fix.
[ "$misconf_count" -gt 0 ] && {
  echo >> "$REPORT"
  echo "> $misconf_count requested seat(s) were **MISCONFIGURED** on this box and never ran." >> "$REPORT"
  echo "> The panel is smaller than the roster asked for. That is not a finding about" >> "$REPORT"
  echo "> any reviewer; fix the roster or the install and re-run." >> "$REPORT"
}

# ★ Spell out what degraded costs the reader, once, where the counts are. The
# tempting read of a short partial review is "it looked and found little".
[ "$degraded_count" -gt 0 ] && {
  echo >> "$REPORT"
  echo "> A **DEGRADED** reviewer ran out of tokens or time partway through. Read" >> "$REPORT"
  echo "> what it found, but do not count the files it never mentioned as cleared," >> "$REPORT"
  echo "> and do not read it as disagreeing with anything it never reached." >> "$REPORT"
}

# ★ The same warning for the other silent failure, and it needs its own words:
# a degraded reviewer looked at SOME of the diff, an inconclusive one looked at
# none of it. The tempting read here is worse than for a partial, because the
# artifact is often long and fluent.
[ "$inconc_count" -gt 0 ] && {
  echo >> "$REPORT"
  echo "> An **INCONCLUSIVE** reviewer exited cleanly and produced text that is" >> "$REPORT"
  echo "> not a review — a summary of the diff, a request for clarification, or" >> "$REPORT"
  echo "> the diff echoed back. Length is not coverage: treat it as a reviewer" >> "$REPORT"
  echo "> that did not run. It is excluded from the synthesis and clears nothing." >> "$REPORT"
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
  # ★ Excerpted like a failure, NOT printed in full like a partial. A partial is
  # a review and every line of it is worth reading; this is 40KB of chrome or a
  # parroted diff, and pasting it whole buries the reviews that are real.
  elif [ -s "$OUT/$sl.md.inconclusive" ]; then
    echo "_INCONCLUSIVE. Ran, but returned no findings and no verdict. Not a review._"$'\n' >> "$REPORT"
    head -20 "$OUT/$sl.md.inconclusive" 2>/dev/null | sed 's/^/    /' >> "$REPORT"
  elif [ "$(failure_kind "$OUT/$sl.md.failed")" = misconfigured ]; then
    echo "_MISCONFIGURED. The seat never ran; this is a fault on this box, not a review._"$'\n' >> "$REPORT"
    head -5 "$OUT/$sl.md.failed" 2>/dev/null | sed 's/^/    /' >> "$REPORT"
  else echo "_FAILED. Not a clean review._"$'\n' >> "$REPORT"
       head -20 "$OUT/$sl.md.failed" 2>/dev/null | sed 's/^/    /' >> "$REPORT"
  fi
done

# ★ Write the per-slot record to disk BEFORE deleting the scratch files it is
# built from. Status and timing used to live only in .status-*/.log-*, both
# removed below, so the moment a panel finished the only surviving record of
# WHICH reviewer failed and HOW LONG each took was the console scrollback.
# Fourteen panels ran before this existed and their timings are simply gone --
# not reconstructible, because the artifacts on disk carry neither. The prompt
# length follows the same rule: capture it at dispatch, never reconstruct it
# later. report.md is prose for a human; this is the same run as data.
# One line per reviewer slot, tab-separated, no header: greppable, joinable,
# and append-safe. Bytes come from the artifact rather than the log so the
# number always describes the file that is actually there.
# ★ Built ONCE, then written twice. slots.tsv and the report's Receipts table
# are the same rows in two shapes, and the first cut of this had them iterating
# different things -- slots.tsv over the roster, Receipts over the record. That
# is two views of one panel disagreeing about which seats exist, which is the
# exact divergence #2 was opened to delete, reintroduced pointing the other way.
# Sharing the rows makes them identical by construction rather than by care.
slot_rows=$(
  # ★ Rendered FROM the record, not reconstructed from prose. This block used to
  # recover a seat's elapsed seconds with
  #   sed -n 's/.*in \([0-9][0-9]*\)s.*/\1/p' "$OUT/.log-$sl"
  # -- a number parsed back out of the sentence that had printed it, from a
  # scratch file deleted moments later. Every field below is now read as a field.
  # Same file, same columns, same order: bin/cadre's `receipts` and
  # lib/aggregate.sh both parse slots.tsv positionally and must not notice.
  # ★ The ROSTER drives the rows, not the record. Deriving them from what the
  # log happens to contain would silently drop a seat that was dispatched and
  # never completed -- which is exactly the seat worth a row, and the same
  # reasoning aggregate.sh gives for trusting the roster line over filenames.
  # A seat with no completion event prints `failed` with EMPTY secs: it did not
  # take zero seconds, it was never measured.
  # ★ `v` is a CONSTANT here, not a field read back from the record (#20). It
  # describes the ROW -- which columns these are and which rule wrote them --
  # and this harness wrote every row below, including one for a seat that left
  # no completion event at all. Reading it from the record would blank exactly
  # that row and lose the provenance for the only row whose provenance is in
  # question.
  # ★ Column 12, `model`, is the served model the adapter declared (#51) and
  # EMPTY otherwise. Appended after harness_sha so every positional reader of
  # $1..$11 is untouched; the schema version does not move, because no existing
  # column changed meaning -- `v` marks a change to what a column MEANS, not
  # to how many there are.
  all_complete=$(record_rows "$RUNLOG" complete seat family state bytes secs prompt_bytes \
                   prompt_sha adapter_sha harness_sha model)
  for spec in "${reviewers[@]}"; do
    rec_row=$(printf '%s\n' "$all_complete" | awk -F '\t' -v s="$spec" '$1 == s { print; exit }')
    rec_row="${rec_row//$'\t'/$'\034'}"
    IFS=$'\034' read -r _seat r_fam r_state r_bytes r_secs r_prompt r_psha r_asha r_hsha r_model <<< "$rec_row"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$OUT")" "$spec" "${r_fam:-$(spec_family "$spec")}" \
      "${r_state:-failed}" "${r_bytes:-0}" "$r_secs" "$r_prompt" \
      "$SLOTS_SCHEMA_V" "$r_psha" "$r_asha" "${r_hsha:-$HARNESS_SHA}" "$r_model"
  done
  # Skipped seats come from the same stream, for the same reason: one source, so
  # a change to how spend is recorded cannot land in one renderer and not the
  # other. Still roster-driven, and still `0\t\t0` -- measured zero spend, and
  # seconds that were never measured at all.
  for row in "${skipped_rows[@]}"; do
    IFS=$'\t' read -r spec _gate _reason <<< "$row"
    rec_row=$(printf '%s\n' "$all_complete" | awk -F '\t' -v s="$spec" '$1 == s { print; exit }')
    rec_row="${rec_row//$'\t'/$'\034'}"
    IFS=$'\034' read -r _seat r_fam r_state r_bytes r_secs r_prompt r_psha r_asha r_hsha r_model <<< "$rec_row"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(basename "$OUT")" "$spec" "${r_fam:-$(spec_family "$spec")}" \
      "${r_state:-skipped}" "${r_bytes:-0}" "$r_secs" "${r_prompt:-0}" \
      "$SLOTS_SCHEMA_V" "$r_psha" "$r_asha" "${r_hsha:-$HARNESS_SHA}" "$r_model"
  done
)
printf '%s\n' "$slot_rows" > "$OUT/slots.tsv"

{
  echo
  echo "## Receipts"
  echo
  echo "| seat | model | status | secs | prompt KB | review KB | est. tokens |"
  echo "|---|---|---|---|---|---|---|"
  total_secs=0; have_secs=0; total_prompt=0; have_prompt=0; total_review=0; total_est=0
  # ★ The SAME rows slots.tsv got, not a second query against the record. Both
  # views owe their row set to the roster, so a seat dispatched and never
  # completed appears in both or neither -- never in one.
  while IFS= read -r slot_row; do
    # Tabs are IFS whitespace, so plain `read` collapses the empty secs field in
    # a skipped row. Translate to a non-whitespace delimiter before splitting.
    slot_row="${slot_row//$'\t'/$'\034'}"
    IFS=$'\034' read -r _run spec _fam st bytes secs prompt_bytes _v _psha _asha _hsha model <<< "$slot_row"
    prompt_kb=""
    if [ -n "${prompt_bytes:-}" ]; then
      prompt_kb=$(awk -v n="$prompt_bytes" 'BEGIN { printf "%.1f", n / 1024 }')
      total_prompt=$((total_prompt + prompt_bytes)); have_prompt=1
    fi
    review_kb=$(awk -v n="${bytes:-0}" 'BEGIN { printf "%.1f", n / 1024 }')
    est_tokens=$(( (${prompt_bytes:-0} + ${bytes:-0}) / 4 ))
    total_est=$((total_est + est_tokens))
    [ -n "${secs:-}" ] && { total_secs=$((total_secs + secs)); have_secs=1; }
    total_review=$((total_review + ${bytes:-0}))
    # The model column is blank for every seat that pins its model in the spec;
    # it is filled only by an adapter that read the served model (#51).
    printf '| `%s` | %s | %s | %s | %s | %s | %s |\n' \
      "$spec" "${model:-}" "$st" "${secs:-}" "$prompt_kb" "$review_kb" "$est_tokens"
  done <<< "$slot_rows"
  total_secs_display=""; [ "$have_secs" -eq 1 ] && total_secs_display="$total_secs"
  total_prompt_kb=""; [ "$have_prompt" -eq 1 ] && \
    total_prompt_kb=$(awk -v n="$total_prompt" 'BEGIN { printf "%.1f", n / 1024 }')
  total_review_kb=$(awk -v n="$total_review" 'BEGIN { printf "%.1f", n / 1024 }')
  printf '| **panel total** | | | %s | %s | %s | %s |\n' \
    "$total_secs_display" "$total_prompt_kb" "$total_review_kb" "$total_est"
  echo
  echo "> Estimated as bytes/4 of what the harness sent and received. Hidden reasoning tokens are invisible from outside the CLI and are NOT in this number: a seat that thinks long and answers short costs more than its row shows. This is a relative-spend signal, not a bill."
} >> "$REPORT"

rm -f "$OUT"/.log-* "$OUT"/.status-* "$OUT"/.len-* "$OUT"/.sha-*
echo
skipped_count=${#skipped_rows[@]}
if [ "$skipped_count" -gt 0 ]; then
  echo "$ok_count ok, $degraded_count degraded, $inconc_count inconclusive, $fail_count failed, $skipped_count skipped. Report: $REPORT"
else
  echo "$ok_count ok, $degraded_count degraded, $inconc_count inconclusive, $fail_count failed. Report: $REPORT"
fi
# Degraded counts toward having something to synthesize: partial findings are
# still findings. Only a panel with nothing at all is a dead run.
[ $((ok_count + degraded_count)) -gt 0 ] || {
  [ ${#reviewers[@]} -eq 0 ] && [ "$skipped_count" -gt 0 ] && exit 0
  echo "every reviewer failed. Nothing to synthesize." >&2; exit 1; }
exit 0
