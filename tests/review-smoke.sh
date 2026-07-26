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

# One stub agent that echoes what it can see, one that truncates, one that dies.
setup_agents() {
  mkdir -p "$1/bin" "$1/agents.d"
  local n
  for n in good good2 trunc dead echoer chrome terse ratepart ratelim \
           synthquote synthtrunc synthrate; do
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
  # ★ Nothing to salvage, but it PRINTS raw output after the marker, the way
  # agents.d/grok.sh dumps its JSON. Any "is there text before the marker"
  # heuristic reads that dump as a review and files this as a partial. The
  # marker name is the discriminator precisely so this case stays failed.
  cat > "$1/agents.d/dead.sh" <<'A'
run_dead() {
  echo "DID NOT COMPLETE, no text returned (stopReason=Error). Raw:"
  echo '{"error":"upstream","detail":"a wall of raw output that is not a review"}'
}
A
  # Echoes the prompt it was handed, so a test can assert on what the
  # synthesizer was actually TOLD rather than on a stub's invented answer.
  cat > "$1/agents.d/echoer.sh" <<'A'
run_echoer() { printf '%s\n' "$prompt"; }
A
  # ★ Returns NO review, only the CLI's own chrome. Measured with opencode,
  # which prints colour escapes and a banner around the model's text: the file
  # is non-empty, rc is 0, and a reviewer that said nothing scored as a clean
  # pass. Emptiness has to mean empty of content, not of bytes.
  cat > "$1/agents.d/chrome.sh" <<'A'
run_chrome() { printf '\033[0m\n\033[0m\n   \n'; }
A
  # Same chrome, but with a real (very short) review inside it. Must stay ok:
  # "findings=0" is a valid review and a length floor used to throw those away.
  cat > "$1/agents.d/terse.sh" <<'A'
run_terse() { printf '\033[0m\nfindings=0\n\033[0m\n'; }
A
  # ★ A SHORT partial review that happens to TALK about rate limiting, then the
  # truncation marker. rate_limited() is a keyword match over files under 2KB,
  # so this shape matched it and was binned `failed` -- findings discarded --
  # while the adapter was explicitly reporting a partial. Reviewing cadre itself
  # produces exactly this, since cadre handles 429s and a reviewer quotes them.
  cat > "$1/agents.d/ratepart.sh" <<'A'
run_ratepart() {
  printf 'blocking: the 429 too many requests path retries forever.\n'
  printf '_TRUNCATED, stopped early.\n'
}
A
  # A GENUINE rate limit, no review at all: the case the retry loop is for.
  cat > "$1/agents.d/ratelim.sh" <<'A'
run_ratelim() { printf 'Error: 429 too many requests.\n'; }
A
  # ★ A COMPLETE synthesis that ends by QUOTING a reviewer's truncation marker,
  # which the synthesis prompt explicitly asks it to report. Exits 0, because
  # nothing went wrong. Must survive: this is a good merge.
  cat > "$1/agents.d/synthquote.sh" <<'A'
run_synthquote() {
  printf 'Merged. One reviewer was cut off; it ended with:\n'
  printf '_TRUNCATED, stopped early._\n'
}
A
  # ★ A healthy, SHORT synthesis that discusses rate limiting -- which is what
  # merging reviews of this repo produces. Exits 0. Must survive: the keyword
  # scan is not evidence the provider refused anything.
  cat > "$1/agents.d/synthrate.sh" <<'A'
run_synthrate() {
  echo "Panel: 2 reviewers, 2 complete, 0 stopped early."
  echo "Agreed: the retry path for 429 too many requests never gives up. [2/2]"
  printf 'padding %s\n' $(seq 1 60)
}
A
  # The same text from a synthesizer that really DID stop early. Identical bytes,
  # nonzero exit. Must fail closed -- a partial merge is worthless while the
  # reviews it was merging are complete on disk.
  cat > "$1/agents.d/synthtrunc.sh" <<'A'
run_synthtrunc() {
  printf 'Merged. One reviewer was cut off; it ended with:\n'
  printf '_TRUNCATED, stopped early._\n'
  return 1
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
OUT=$(run_cadre "$D" review --roster good,trunc,dead,ghost --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "source repo untouched"        "[ \"\$BEFORE\" = \"\$(git -C '$S' status --porcelain | md5sum)\$(git -C '$S' rev-parse HEAD)\" ]"
check "no refs/cadre left behind"    "[ -z \"\$(git -C '$S' for-each-ref refs/cadre)\" ]"
check "work dir cleaned"             "[ -z \"\$(ls -A '$D/work')\" ]"
check "untracked file in the DIFF"   "grep -q 'src/newfeature.js' '$R'/report.md"
check "gitignored secret excluded"   "! grep -q 'env.local' '$G'"
check "ignored log excluded"         "! grep -q 'debug.log' '$G'"
check ".env.example did not refuse"  "[ -n '$G' ]"
check "missing agent -> FAILED"      "grep -q 'NOT INSTALLED' '$R'/ghost-*.failed"
check "all 4 roster rows in report"  "[ \$(grep -c '^- \`' '$R/report.md') -eq 4 ]"

# ---- three-state reviewer health ---------------------------------------------
# ★ The truncated case used to assert .md.failed. That was the overcorrection for
# a partial grok review scoring as COMPLETE: it stopped the overstatement by
# throwing the findings away. Both halves are wrong, so it is its own state now.
check "truncated -> .partial not .failed" "ls '$R'/trunc-*.md.partial >/dev/null 2>&1"
check "truncated is NOT a clean review"   "! ls '$R'/trunc-*.md >/dev/null 2>&1"
check "partial findings kept, not binned" "grep -q 'partial finding' '$R'/trunc-*.md.partial"
check "DEGRADED row in the report"        "grep -q 'DEGRADED' '$R/report.md'"
check "report says silence is not clean"  "grep -q 'silence is not' '$R/report.md'"
check "partial review body in report"     "grep -q 'partial finding' '$R/report.md'"
check "counts name all three states"      "grep -qE '1 ok, 1 degraded, 2 failed' <<<\"\$OUT\""
# ★ Marker name decides, not content. This stub prints a raw dump AFTER its
# marker; a "text before the marker" heuristic would file it as a partial.
check "DID NOT COMPLETE + raw -> FAILED"  "ls '$R'/dead-*.md.failed >/dev/null 2>&1"
check "dead reviewer has no .partial"     "! ls '$R'/dead-*.md.partial >/dev/null 2>&1"
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

echo "== ★ CADRE_HOME inside or EQUAL TO the reviewed repo is refused =="
D=$(case_dir nested_home); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
mkdir -p "$S/.cadre/keys"; echo "K1 the answer" > "$S/.cadre/keys/secret.md"
OUT=$(CADRE_HOME="$S/.cadre" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "nested CADRE_HOME refused"     "grep -q 'sits inside it' <<<\"\$OUT\""
# ★ is_inside returns false for identical paths, so exact equality needs its own
# test: CADRE_HOME="$repo" used to sail through and copy state into the checkout.
OUT=$(CADRE_HOME="$S" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "CADRE_HOME == repo refused"    "grep -q 'sits inside it' <<<\"\$OUT\""
OUT=$(CADRE_HOME="$D/state" CADRE_WORK="$S" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:$PATH" "$ROOT/bin/cadre" review --roster good --base main "$S" 2>&1)
check "CADRE_WORK == repo refused"    "grep -q 'sits inside it' <<<\"\$OUT\""

echo "== ★ sha256 source repo =="
if git init -q --object-format=sha256 "$SANDBOX/fmtprobe" 2>/dev/null; then
  D=$(case_dir sha256); rm -rf "$D/src"
  git init -q --object-format=sha256 "$D/src"; S="$D/src"
  git -C "$S" config user.email t@example.com; git -C "$S" config user.name t
  echo orig > "$S/app.js"; git -C "$S" add -A; git -C "$S" commit -qm base
  git -C "$S" branch -M main; git -C "$S" checkout -qb feature
  echo x >> "$S/app.js"; git -C "$S" commit -qam f; echo dirty >> "$S/app.js"
  OUT=$(run_cadre "$D" review --roster good --base main "$S")
  check "sha256 repo reviews cleanly" "grep -q '1 ok' <<<\"\$OUT\""
else
  echo "  skip sha256 (this git does not support it)"
fi

echo "== ★ manifest survives a source gc =="
D=$(case_dir gc_manifest); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
echo dirty >> "$S/app.js"; echo new > "$S/extra.js"
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
BT=$(grep '^base-tree:' "$R/manifest.txt" | awk '{print $2}')
RT=$(grep '^reviewed-tree:' "$R/manifest.txt" | awk '{print $2}')
check "manifest records both trees"  "[ -n '$BT' ] && [ -n '$RT' ] && [ '$RT' != unknown ]"
check "base tree survives a gc"      "git -C '$S' reflog expire --expire=now --all >/dev/null 2>&1; git -C '$S' gc --prune=now -q >/dev/null 2>&1; git -C '$S' cat-file -e '$BT^{tree}' 2>/dev/null"

echo "== default base resolution =="
# Every other case passes --base. This is the path a real user hits first.
D=$(case_dir defaultbase); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good "$S")
check "falls back to main with no origin" "grep -q 'base: main' <<<\"\$OUT\""
check "and completes the run"             "grep -q '1 ok' <<<\"\$OUT\""

echo "== ★ deterministic pre-pass (--prerun) =="
# No --prerun: the placeholder must not survive into a reviewer's brief.
D=$(case_dir prerun_off); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "no leftover placeholder"      "! grep -q 'TEST_RESULT' '$R/prompt.txt'"
check "no prerun line in manifest"   "! grep -q '^prerun:' '$R/manifest.txt'"

# Passing command: the transcript reaches the prompt and the manifest.
D=$(case_dir prerun_pass); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo all green' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "prerun transcript written"    "[ -s '$R/prerun.md' ]"
check "exit 0 in the brief"          "grep -q 'exit 0' '$R/prompt.txt'"
check "output in the brief"          "grep -q 'all green' '$R/prompt.txt'"
check "manifest records the command" "grep -q '^prerun: *exit 0 | echo all green' '$R/manifest.txt'"

# ★ Failing command: reviewers must be told the suite is RED. The whole point
# of the pre-pass is the case where the deterministic signal disagrees with a
# panel that would otherwise call the change clean.
D=$(case_dir prerun_fail); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo boom; exit 3' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "non-zero exit in the brief"   "grep -q 'exit 3' '$R/prompt.txt'"
check "failure output carried"       "grep -q 'boom' '$R/prompt.txt'"
check "run still completed"          "grep -q '1 ok' <<<\"\$OUT\""
check "warned on the console"        "grep -q 'pre-pass exit 3' <<<\"\$OUT\""

# ★ An & in test output. awk's gsub reads & in the replacement as "the matched
# text", so splicing this with gsub would silently corrupt the transcript.
D=$(case_dir prerun_amp); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo "a && b"' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "ampersand output intact"      "grep -qF 'a && b' '$R/prompt.txt'"

# ★ The pre-pass is arbitrary code next to the answer keys. It gets the same
# environment scrub the reviewers get, or a build script that dumps its env
# writes CADRE_HOME into a transcript handed to the whole panel.
D=$(case_dir prerun_env); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main \
        --prerun 'echo "HOME_IS:[${CADRE_HOME:-unset}] WORK_IS:[${CADRE_WORK:-unset}]"' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "CADRE_HOME scrubbed from prerun" "grep -q 'HOME_IS:\[unset\]' '$R/prompt.txt'"
check "CADRE_WORK scrubbed from prerun" "grep -q 'WORK_IS:\[unset\]' '$R/prompt.txt'"

# A multi-line command must not split the manifest into bogus rows.
D=$(case_dir prerun_multiline); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo one
echo two' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "manifest stays one line per field" "[ \$(wc -l < '$R/manifest.txt') -eq \$(grep -c ':' '$R/manifest.txt') ]"

# ★ A command that cannot run is a refusal, not a finding. Feeding the panel
# "exit 127" as though it were a test result is worse than not measuring.
D=$(case_dir prerun_bad); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'no-such-command-xyz' "$S")
check "unrunnable prerun refuses"    "grep -q 'could not be executed' <<<\"\$OUT\""
check "and produced no review"       "[ -z \"\$(ls -A '$D/state/reviews' 2>/dev/null)\" ]"

# ★ The pre-pass runs in a THROWAWAY copy. Artifacts it drops must not reach a
# reviewer, or every panel diffs a tree that has been built in.
D=$(case_dir prerun_clean); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good --base main --prerun 'echo art > build-artifact.txt' "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
G=$(ls "$R"/good-*.md 2>/dev/null | head -1)
check "artifact not in the checkout" "! grep -q 'build-artifact' '$G'"
check "artifact not in source repo"  "[ ! -e '$S/build-artifact.txt' ]"
check "work dir still cleaned"       "[ -z \"\$(ls -A '$D/work')\" ]"

echo "== ★ install-aware adapter listing =="
# An adapter ships for every CLI cadre knows about. Unmarked, the list reads as
# a wall of caveats about tools you do not have.
D=$(case_dir installed)
printf 'run_phantom() { echo x; }\n' > "$D/agents.d/phantom.sh"   # adapter, no binary
LIST=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" "$ROOT/bin/agentcall" --list)
INST=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" "$ROOT/bin/agentcall" --installed)
check "installed adapter marked"   "grep -q '^✓ good ' <<<\"\$LIST\""
check "absent adapter marked"      "grep -q '^· phantom' <<<\"\$LIST\""
check "--installed lists good"     "grep -qx good <<<\"\$INST\""
check "--installed omits phantom"  "! grep -qx phantom <<<\"\$INST\""
# The mark is its own field: printf pads by BYTES and ✓ is three of them, so
# folding it into the name column shifts installed rows against the rule.
check "columns still line up"      "[ \$(grep -c '^. [a-z0-9]* *(no notes)' <<<\"\$LIST\") -ge 1 ]"

echo "== ★ no roster names what you actually have =="
# 'cadre panel --save' needs graded passes. Sending a first-time user there is
# sending them down the one path that is closed to them.
D=$(case_dir noroster); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --base main "$S" || true)
check "suggests a runnable command" "grep -q 'cadre review --roster' <<<\"\$OUT\""
check "names an installed adapter"  "grep -q 'good' <<<\"\$OUT\""
check "still mentions panel --save" "grep -q 'panel --save' <<<\"\$OUT\""

# With nothing installed there is nothing to suggest, so say that instead.
D=$(case_dir noagents); S="$D/src"
rm -f "$D"/bin/*
OUT=$(CADRE_HOME="$D/state" CADRE_WORK="$D/work" CADRE_AGENTS_D="$D/agents.d" \
      PATH="$D/bin:/usr/bin:/bin" "$ROOT/bin/cadre" review --base main "$S" 2>&1 || true)
check "empty box says so"           "grep -q 'none of cadre.s adapters' <<<\"\$OUT\""

echo "== ★ one-reviewer nudge (data, not a warning) =="
D=$(case_dir nudge)
# Everything except `good`, by exclusion rather than by name: this listed the
# stubs to delete, so adding a stub anywhere else in this file silently gave the
# case two reviewers and the nudge stopped firing.
find "$D/bin" -type f ! -name good -delete
find "$D/agents.d" -type f ! -name good.sh -delete
OUT=$(env -i PATH="$D/bin:/usr/bin:/bin" CADRE_HOME="$D/state" CADRE_WORK="$D/work" \
        CADRE_AGENTS_D="$D/agents.d" "$ROOT/bin/cadre" doctor 2>&1); RC=$?
check "nudge shown at one reviewer" "grep -q 'one reviewer installed' <<<\"\$OUT\""
check "nudge carries the numbers"   "grep -q '47% at one' <<<\"\$OUT\""
check "doctor still exits 0"        "[ $RC -eq 0 ]"
# Two installed reviewers is a panel; do not nag.
D=$(case_dir nonudge)
rm -f "$D/bin/trunc" "$D/agents.d/trunc.sh"
OUT=$(env -i PATH="$D/bin:/usr/bin:/bin" CADRE_HOME="$D/state" CADRE_WORK="$D/work" \
        CADRE_AGENTS_D="$D/agents.d" "$ROOT/bin/cadre" doctor 2>&1)
check "no nudge at two reviewers"   "! grep -q 'one reviewer installed' <<<\"\$OUT\""

echo "== ★ onboard prints, and never handles a key =="
D=$(case_dir onboard)
ON=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:/usr/bin:/bin" \
       "$ROOT/bin/cadre" onboard 2>&1)
BR=$(CADRE_HOME="$D/state" CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:/usr/bin:/bin" \
       "$ROOT/bin/cadre" onboard --brief 2>&1)
check "onboard names what you have"  "grep -q 'You have installed: .*good' <<<\"\$ON\""
check "onboard points at the doc"    "grep -q 'FREE-PANEL.md' <<<\"\$ON\""
# opencode is absent from this PATH, and two of the three routes need it.
check "warns opencode is missing"    "grep -q 'opencode is not installed' <<<\"\$ON\""
# ★ The brief must tell the agent to use a PLACEHOLDER. An onboarding flow that
# has an agent handle the real key is a credential path wearing a helper's coat.
check "brief demands a placeholder"  "grep -qF '{env:PROVIDER_API_KEY}' <<<\"\$BR\""
check "brief forbids asking for it"  "grep -q 'Do NOT ask me for the key' <<<\"\$BR\""
check "brief warns off repo .env"    "grep -q \"repo's .env\" <<<\"\$BR\""
check "onboard rejects bad options"  "! CADRE_HOME='$D/state' '$ROOT/bin/cadre' onboard --nope >/dev/null 2>&1"
# It prints and exits. Writing config or touching a key is the one thing it
# must never do, so no run of it may create anything under the user's config.
check "onboard wrote nothing"        "[ ! -e '$D/state/reviews' ]"

echo "== ★ a CLI's own chrome is not a review =="
# Measured with opencode, the free route the README sends people to first: it
# wraps the model's text in colour escapes and a banner, so a run that returned
# NOTHING still leaves a non-empty file and scored as a reviewer that looked and
# found no defects. Emptiness has to mean empty of content, not of bytes.
D=$(case_dir chrome_only); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster chrome,terse --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
check "chrome-only run -> FAILED"      "ls '$R'/chrome-*.md.failed >/dev/null 2>&1"
check "chrome-only is not a review"    "! ls '$R'/chrome-*.md >/dev/null 2>&1"
# ★ The other half. A length floor would catch the banner AND this, and the
# repo already threw away valid "findings=0" reviews that way once.
check "a terse review still counts"    "ls '$R'/terse-*.md >/dev/null 2>&1"
check "counts split them correctly"    "grep -q '1 ok, 0 degraded, 1 failed' <<<\"\$OUT\""

echo "== ★ chrome-stripping must not eat the review itself =="
# Found by a codex-led panel on cadre's own diff: `/^> build /d` was written to
# drop opencode's banner and also deleted a reviewer's markdown blockquote that
# happened to start with the word build. Silent loss of review content is worse
# than the chrome it was removing.
ESC=$(printf '\033')
STRIP="sed -e 's/${ESC}\[[0-9;]*[a-zA-Z]//g' -e '1,5{' -e '/^> build · /d' -e '}'"
BQ='> build the release pipeline silently fails'
check "a '> build ...' quote survives" "[ \"\$(printf '%s\n' '$BQ' | $STRIP)\" = '$BQ' ]"
check "the real banner still goes"     "[ -z \"\$(printf '> build · m\n' | $STRIP | tr -d '[:space:]')\" ]"
# ★ Anchored to the first lines too: the banner cannot appear deep in a review,
# but a quoted example of one can.
check "a late banner-lookalike stays"  "[ -n \"\$(printf 'a\nb\nc\nd\ne\nf\n> build · m\n' | $STRIP | grep '^> build')\" ]"

echo "== ★ no GNU-only sed escapes =="
# Found by a panel reviewer: `\x1b` is a GNU sed extension. BSD sed (macOS)
# reads it as a literal `x1b`, matches nothing, and every strip built on it
# silently no-ops -- so the chrome-only run above is filed as a clean review
# again, on a whole platform, with no error raised. A silent no-op is the worst
# available failure, so this bans the construct rather than trusting a comment.
# Comment lines are exempt: the comments explaining this ban say `\x1b`, and the
# first version of this check failed on them.
check "no \\x1b in shipped code" \
  "! grep -rn 'x1b' $ROOT/bin $ROOT/lib $ROOT/agents.d | grep -qvE ':[[:space:]]*#'"

echo "== ★ the prompt must name the delimiters the harness actually emits =="
# A remediation commit renamed the partial delimiter in bin/cadre and left
# lib/prompts/synthesize.md teaching the old string, so the static rule no
# longer bound to anything in the body. The suite asserted the emitted string
# and the prompt's text separately, and neither noticed they had stopped
# matching. Assert the SAME literal against both, so a rename must touch both.
P_PARTIAL='===== REVIEWER (PARTIAL, THIS REVIEWER STOPPED EARLY):'
P_CAPPED='===== REVIEWER (COMPLETE, BUT CADRE SENT ONLY ITS FIRST'
check "harness emits the partial delimiter" "grep -qF '$P_PARTIAL' $ROOT/bin/cadre"
check "prompt teaches the partial delimiter" "grep -qF '$P_PARTIAL' $ROOT/lib/prompts/synthesize.md"
check "harness emits the capped delimiter"  "grep -qF '$P_CAPPED' $ROOT/bin/cadre"
check "prompt teaches the capped delimiter" "grep -qF '$P_CAPPED' $ROOT/lib/prompts/synthesize.md"

echo "== ★ a retry must not destroy the partial it is retrying =="
# Also from the codex panel, and a regression introduced the same day: the
# benchmark path deleted the previous .partial BEFORE the replacement attempt,
# so a retry that produced nothing took the only copy of real findings with it.
#
# ⚠ STRUCTURAL, not behavioural. Reaching this at runtime needs a registered
# pass with a corrected answer key, which is a model-built fixture and does not
# belong in a suite that runs in seconds. So this asserts the shape of the code
# instead, which is weaker than a real run: it would not catch a third place
# that deletes the file. It exists to stop this exact line coming back.
PRE=$(sed -n '/^    rm -f "\$f/p' "$ROOT/lib/run-pass.sh")
check "pre-attempt rm spares .partial" "! grep -q 'f.partial' <<<\"\$PRE\""
check "pre-attempt rm still clears .failed" "grep -q 'f.failed' <<<\"\$PRE\""
check "success clears the stale .partial" \
  "grep -A3 '^      ok)' '$ROOT/lib/run-pass.sh' | grep -q 'rm -f \"\$f.partial\"'"

echo "== ★ a partial reviewer must not corrupt the agreement math =="
# The synthesizer is told the counts. If a partial review arrives under the same
# delimiter as a complete one, tagging a finding [1/3] reads as two dissents when
# really it is one reviewer and two absences. `echoer` replays the prompt it was
# handed, so these assert on what the synthesizer was TOLD, not on a stub's answer.
D=$(case_dir synth_partial); S="$D/src"
git -C "$S" checkout -qb feature; echo x >> "$S/app.js"; git -C "$S" commit -qam f
OUT=$(run_cadre "$D" review --roster good,good2,trunc,dead --synth echoer --base main "$S")
R="$D/state/reviews/$(ls "$D/state/reviews" | head -1)"
P="$R/synthesis.md"
check "synthesis ran with a partial"   "[ -s '$P' ]"
check "partial gets its OWN delimiter" "grep -q 'PARTIAL, THIS REVIEWER STOPPED EARLY): trunc' '$P'"
check "complete reviews stay plain"    "grep -qE '^===== REVIEWER: good =====' '$P'"
check "partial text still delivered"   "grep -q 'partial finding' '$P'"
check "unraised = neither side"          "grep -q 'counts in NEITHER' '$P'"
check "and never a Disagreement"         "grep -q 'under Disagreements' '$P'"
check "dead reviewer still declared"   "grep -q 'FAILED, NO REVIEW: dead' '$P'"
check "panel size stated for dead"     "grep -q 'panel was 4 reviewers' '$P'"
check "dead kept OUT of the tags"      "grep -q 'out of every agreement tag' '$P'"
check "raised-by-partial counts BOTH"  "grep -q 'numerator and the' '$P'"
check "one counting rule, no conflict" "! grep -q 'not out of' '$P'"
check "run line counts the partial"    "grep -q '3 review(s) (2 full, 1 partial)' <<<\"\$OUT\""

# ★ Over the byte cap, `head -c` MAKES a review partial: it goes silent about
# everything past the cut for the same reason a truncated one does. Re-labelled,
# or the rule above skips the very reviews this code truncated.
OUT=$(CADRE_SYNTH_MAX=100 run_cadre "$D" review --roster good,good2 --synth echoer \
        --base main --label capped "$S")
P="$D/state/reviews/capped/synthesis.md"
check "cap truncation is announced"    "grep -q 'over CADRE_SYNTH_MAX' <<<\"\$OUT\""
check "a cut review says CADRE cut it"  "grep -q 'BUT CADRE SENT ONLY ITS FIRST' '$P'"
check "and is NOT called stopped-early" "! grep -q 'STOPPED EARLY): good' '$P'"
check "and the silence rule travels"   "grep -q 'counts in NEITHER' '$P'"
# ★ Every survivor capped is the case that exposed the two meanings of $n: the
# console counted only reviews sent whole, so it announced "synthesizing 0
# review(s)" and then synthesized two. Found by a grok-led panel.
check "never announces 0 while merging" "! grep -q 'synthesizing 0 review' <<<\"\$OUT\""
check "capped counted in the run line"  "grep -q '2 review(s) (0 full, 2 sent short)' <<<\"\$OUT\""

# ★ The same count in prose, where it is handed to the MODEL rather than the
# reader: a capped reviewer did return a complete review, cadre just sent part
# of it. Needs a dead reviewer present, since that is the block carrying the
# sentence, and a capped one, since $n and the completed count only diverge
# when something was cut.
OUT=$(CADRE_SYNTH_MAX=100 run_cadre "$D" review --roster good,good2,dead --synth echoer \
        --base main --label capdead "$S")
P="$D/state/reviews/capdead/synthesis.md"
check "capped counted as completed"    "grep -q 'of whom 2' '$P'"
check "and the dead one is not"        "grep -q 'panel was 3 reviewers' '$P'"

# ★ The adapter's own verdict outranks anything cadre infers from the text. A
# short partial that merely DISCUSSES rate limiting matched rate_limited() and
# was binned `failed`, findings and all, because that keyword check ran before
# the truncation marker. Found by a grok-led panel, on a diff where reviewing
# cadre's own 429 handling is what produces the shape.
OUT=$(run_cadre "$D" review --roster ratepart,good --synth none \
        --base main --label ratepart "$S")
R="$D/state/reviews/ratepart"
check "rate-limit TALK is not a failure" "! ls '$R'/ratepart-*.md.failed >/dev/null 2>&1"
check "it is degraded, findings kept"    "grep -q 'retries forever' '$R'/ratepart-*.md.partial"

# ★ A REAL rate limit must still give up loudly -- and say so in the documented
# contract shape at the TOP of the file, not appended under whatever the adapter
# printed. The note used to go at the end, which is exactly where it displaced a
# tail-anchored marker.
OUT=$(CADRE_RETRIES=1 run_cadre "$D" review --roster ratelim,good --synth none \
        --base main --label ratelim "$S")
R="$D/state/reviews/ratelim"
check "a real rate limit still fails"   "ls '$R'/ratelim-*.md.failed >/dev/null 2>&1"
check "give-up note leads the file"     "head -1 '$R'/ratelim-*.md.failed | grep -q '^DID NOT COMPLETE, rate limited'"
check "and the error text is kept"      "grep -q '429 too many requests' '$R'/ratelim-*.md.failed"

echo "== ★ a synthesis QUOTING a marker is not a truncated synthesis =="
# The synthesis prompt asks the model to report which reviewers were cut off, so
# a correct merge can legitimately END by quoting a _TRUNCATED line -- the exact
# window a tail-anchored text check inspects. No window fixes that: the check
# must both catch a real truncated merge and ignore a quoted one, and the bytes
# are identical. So the marker is not read here at all; the EXIT STATUS is.
# These two stubs print the SAME text and differ only in what they return.
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthquote \
        --base main --label sq "$S")
check "quoted marker survives"        "[ -s '$D/state/reviews/sq/synthesis.md' ]"
check "and is not filed as failed"    "[ ! -e '$D/state/reviews/sq/synthesis.md.failed' ]"
# ★ A healthy SHORT merge that discusses rate limiting. Two of the three retry
# loops were taught to stop trusting the keyword scan; this one was left, so a
# merge like this burned three retries of the synthesizer's quota and was then
# filed failed with a healthy panel underneath it. Merging reviews of THIS repo
# is what produces the text.
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthrate \
        --base main --label sr "$S")
check "rate-limit TALK in a merge is ok" "[ -s '$D/state/reviews/sr/synthesis.md' ]"
check "and burns no retries"             "! grep -q 'synthesis rate limited' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good,good2 --synth synthtrunc \
        --base main --label st "$S")
check "same text, nonzero -> failed"  "[ -s '$D/state/reviews/st/synthesis.md.failed' ]"
check "and no synthesis was saved"    "[ ! -e '$D/state/reviews/st/synthesis.md' ]"
check "the reviews survive it"        "ls '$D/state/reviews/st'/good-*.md >/dev/null 2>&1"

echo "== ★ settled-decisions ledger =="
# ★ The loop-breaker. Cadre reviews once, but anything that WRAPS it re-raises
# findings the human already dismissed, because the reviewers have no memory.
D=$(case_dir settle)
mkdir -p "$D/state"
printf '# notes to self, must not be matched against\nL1 | wontfix | timestamps are strings, callers wrap them\nL2 | accepted | missing retry test, tracked in #412\n' > "$D/state/ledger"
printf 'REVIEW\n\n1. blocking - timestamps are strings\n2. should-fix - unchecked exit code in run.sh\n' > "$D/review.md"
# A judge stub: echoes canned JSON so this tests the plumbing, not a model.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  echo '{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"},
                     {"summary":"unchecked exit code in run.sh","status":"NEW","ledger_id":null}]}'
}
A
printf '#!/bin/sh\nexit 0\n' > "$D/bin/judgestub"; chmod +x "$D/bin/judgestub"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub); RC=$?
check "settle reports the NEW one"    "grep -q 'unchecked exit code' <<<\"\$OUT\""
check "settle marks the settled one"  "grep -q '\[L1\]' <<<\"\$OUT\""
check "non-zero while something new"  "[ $RC -ne 0 ]"
check "review file left alone"        "grep -q 'timestamps are strings' '$D/review.md'"

# ★ Everything settled means a wrapper can stop. That exit status IS the
# stopping rule, so it has to be exact.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() {
  echo '{"findings":[{"summary":"timestamps are strings","status":"SETTLED","ledger_id":"L1"}]}'
}
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub); RC=$?
check "exits 0 when nothing is new"   "[ $RC -eq 0 ]"

# ★ A judge that returns junk must FAIL, not read as "all settled". Silence and
# "nothing new" are the same output, and one of them hides a live defect.
cat > "$D/agents.d/judgestub.sh" <<'A'
run_judgestub() { echo "Sorry, I could not process that request."; }
A
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1); RC=$?
check "unparseable judge fails loudly" "grep -q 'nothing was matched' <<<\"\$OUT\""
check "and does not exit 0"            "[ $RC -ne 0 ]"

# Comment lines are notes to the human, not ledger entries.
printf '# only a comment\n' > "$D/state/ledger"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1)
check "comment-only ledger refused"   "grep -q 'no entries, only comments' <<<\"\$OUT\""
# No ledger at all is a clear message, not a crash.
rm -f "$D/state/ledger"
OUT=$(run_cadre "$D" settle "$D/review.md" --judge judgestub 2>&1)
check "missing ledger explains itself" "grep -q 'nothing settled yet' <<<\"\$OUT\""
OUT=$(run_cadre "$D" ledger show 2>&1)
check "ledger show without a file"    "grep -q 'no ledger at' <<<\"\$OUT\""

echo "== ★ two seats, one lineage =="
# The property the whole tool rests on, and the easiest to lose by accident:
# adding a CLI feels like adding a reviewer, but a harness fronting gpt-5 or
# claude is the same opinion in a different wrapper. Cursor alone can collide
# with the codex, claude and grok adapters. Warn, never refuse -- running one
# family twice on purpose is a real experiment.
D=$(case_dir family); S="$D/src"
git -C "$S" checkout -qb feature
echo committed >> "$S/app.js"; git -C "$S" commit -qam feat
OUT=$(run_cadre "$D" review --roster good:claude-opus-5,good2:sonnet-4-thinking \
        --synth none --base main --label fam1 "$S")
check "same family is called out"     "grep -q 'one lineage in two seats' <<<\"\$OUT\""
check "it names both seats"           "grep -q 'good:claude-opus-5' <<<\"\$OUT\""
check "and says why it matters"       "grep -q 'overstates the panel' <<<\"\$OUT\""
check "warns, does not refuse"        "grep -q '2 ok' <<<\"\$OUT\""
OUT=$(run_cadre "$D" review --roster good:claude-opus-5,good2:qwen3-coder \
        --synth none --base main --label fam2 "$S")
check "different families stay quiet" "! grep -q 'one lineage in two seats' <<<\"\$OUT\""

echo "== ★ a prompt too big for argv must say so, not die in the shell =="
# Measured live: a 184KB synthesis over a 3-reviewer panel killed an argv-only
# adapter with `timeout: Argument list too long` -- an error naming neither the
# agent nor the cause, landing in the artifact as non-empty text, which is a
# review that found nothing. Linux caps ONE argv entry near 128KB whatever
# ARG_MAX says. Adapters whose CLI has stdin or a prompt file use it instead;
# this guard is for the ones with neither.
D=$(case_dir argvbig)
cat > "$D/agents.d/argvonly.sh" <<'A'
run_argvonly() {
  argv_prompt_ok || return 0
  echo "REVIEW by argvonly"
}
A
printf '#!/bin/sh\nexit 0\n' > "$D/bin/argvonly"; chmod +x "$D/bin/argvonly"
BIG=$(python3 -c "print('x'*120000)" 2>/dev/null || printf 'x%.0s' $(seq 1 120000))
OUT=$(printf '%s' "$BIG" | CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" \
        "$ROOT/bin/agentcall" argvonly -d /tmp -m ro 2>&1)
check "oversize prompt says DID NOT RUN" "grep -q '^DID NOT RUN, prompt is 120000 bytes' <<<\"\$OUT\""
check "it names a way out"               "grep -q 'CADRE_SYNTH_MAX' <<<\"\$OUT\""
check "and it never ran the CLI"         "! grep -q 'REVIEW by argvonly' <<<\"\$OUT\""
OUT=$(printf 'small' | CADRE_AGENTS_D="$D/agents.d" PATH="$D/bin:$PATH" \
        "$ROOT/bin/agentcall" argvonly -d /tmp -m ro 2>&1)
check "a normal prompt is untouched"     "grep -q 'REVIEW by argvonly' <<<\"\$OUT\""

echo "== ★ unset HOME must name the variable, not die in bash =="
# cron, containers and scrubbed CI runners have no HOME. set -u turned that into
# "HOME: unbound variable" pointing into common.sh.
OUT=$(env -i PATH=/usr/bin:/bin "$ROOT/bin/cadre" doctor 2>&1); RC=$?
check "unset HOME names CADRE_HOME"  "grep -q 'HOME is unset' <<<\"\$OUT\""
check "and exits 2, not a bash trap" "[ $RC -eq 2 ]"
check "no raw unbound-variable error" "! grep -q 'unbound variable' <<<\"\$OUT\""
OUT=$(env -i PATH=/usr/bin:/bin "$ROOT/bin/agentcall" --list 2>&1)
check "agentcall guards HOME too"    "grep -q 'HOME is unset' <<<\"\$OUT\""

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
