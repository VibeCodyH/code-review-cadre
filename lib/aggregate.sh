#!/usr/bin/env bash
# Aggregate every review run in $CADRE_HOME/reviews into one dataset.
#
# What this is: an OPERATIONAL record -- which reviewers ran, which came back
# usable, how big and how slow. It is NOT a quality ranking, and the report it
# writes says so in its own words rather than leaving the reader to infer it.
#
# ★ The distinction this file exists to protect: `cadre review` has no answer
# key. A reviewer that returns a confident, well-formatted review of a diff it
# misread lands here as `ok`, exactly like one that found the real bug. Counting
# ok/failed measures whether a CLI DELIVERS TEXT, which is a real and useful
# question -- half the adapters in this repo were written because the answer was
# no -- but it is a different question from whether the text is any good.
# Scoring against ground truth is what `cadre run` and the answer keys are for,
# and none of the runs aggregated here used them. The report states that.
set -uo pipefail

LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CADRE_ROOT="${CADRE_ROOT:-$(dirname "$LIB_DIR")}"
# shellcheck source=lib/common.sh
. "$LIB_DIR/common.sh"

REVIEWS="$CADRE_HOME/reviews"
[ -d "$REVIEWS" ] || die "no reviews at $REVIEWS"

OUT_D="${1:-$CADRE_HOME/dataset}"
mkdir -p "$OUT_D"

SLOTS="$OUT_D/slots.tsv"
PANELS="$OUT_D/panels.tsv"

# ── slots.tsv ────────────────────────────────────────────────────────────────
# One row per reviewer slot. Panels that ran before run-review.sh started
# writing slots.tsv are reconstructed from their artifacts, which is lossy in a
# specific way: the artifacts carry status and size but NOT elapsed time or the
# dispatched prompt size, so `secs` and `prompt_bytes` are empty for them.
# Empty, not zero -- a zero would average like a real measurement and silently
# pull every mean toward the floor.
{
  printf 'panel\tslot\tfamily\tstatus\tbytes\tsecs\tprompt_bytes\tsource\n'
  for d in "$REVIEWS"/*/; do
    [ -d "$d" ] || continue
    p=$(basename "$d")
    if [ -s "$d/slots.tsv" ]; then
      # Recorded live by run-review.sh: status and timing are measured.
      # awk preserves adjacent tab fields. Bash read treats tab as IFS whitespace
      # and collapsed an empty secs field, shifting skipped prompt_bytes=0 into
      # seconds and turning the measured zero back into missing data.
      awk -F '\t' -v OFS='\t' -v panel="$p" '
        $2 != "" { print panel, $2, $3, $4, $5, $6, $7, "recorded" }
      ' "$d/slots.tsv"
      continue
    fi
    # Reconstructed. The roster line is the authority on WHICH slots ran --
    # deriving them from filenames instead would silently drop a slot whose
    # adapter produced no file at all, which is exactly the failure worth
    # counting.
    roster=$(sed -n 's/^roster: *//p' "$d/manifest.txt" 2>/dev/null)
    [ -n "$roster" ] || continue
    for spec in $roster; do
      sl=$(slug "$spec")
      st=failed; art=""
      # ★ Suffix precedence is safe here, and THREE reviewers of the commit that
      # added `.inconclusive` flagged it as a bug, so the reason is written down
      # with the line that guarantees it rather than as an assurance.
      #
      # This loop reads $CADRE_HOME/reviews only. A panel dir there is always
      # fresh, and the guarantee is `bin/cadre`'s bare `mkdir "$out" 2>/dev/null
      # || die "$out already exists. Pick another --label."` -- not `mkdir -p`, and
      # it refuses rather than reusing. An auto label also counts up
      # `review-<sha>-1`, `-2` past anything present. So one slot cannot hold two
      # terminal artifacts in this input, and the labels in the wild that look like
      # reuse (`pi-1`, `pi-2`, `lead-3state-a/b`) are separate panels.
      #
      # ⚠ The tolerance is one layer down: run-review.sh's own `mkdir -p "$OUT"`
      # would happily reuse a dir if the script were invoked directly, and unlike
      # run-pass.sh it never clears stale artifacts per slot. `run-pass.sh` DOES
      # resume and can leave `.partial` beside a newer `.inconclusive` -- its
      # consumer is grade.sh, which handles that pair explicitly. So: if
      # run-review.sh ever gets a resume path, or bin/cadre stops refusing an
      # existing label, THIS ORDER BECOMES A BUG and `.inconclusive` must win over
      # a stale `.partial`.
      if   [ -s "$d/$sl.md" ];              then st=ok;           art="$d/$sl.md"
      elif [ -s "$d/$sl.md.partial" ];      then st=degraded;     art="$d/$sl.md.partial"
      elif [ -s "$d/$sl.md.inconclusive" ]; then st=inconclusive; art="$d/$sl.md.inconclusive"
      elif [ -s "$d/$sl.md.failed" ];       then st=failed;       art="$d/$sl.md.failed"
      fi
      bytes=0
      [ -n "$art" ] && bytes=$(wc -c < "$art" | tr -d ' ')
      printf '%s\t%s\t%s\t%s\t%s\t\t\treconstructed\n' \
        "$p" "$spec" "$(spec_family "$spec")" "$st" "$bytes"
    done
  done
} > "$SLOTS"

# ── panels.tsv ───────────────────────────────────────────────────────────────
# One row per panel. `diff_id` is base-tree..reviewed-tree, and it is the field
# that decides what may be compared with what: two panels sharing a diff_id
# reviewed byte-identical code and their reviewers can be set beside each other.
# Two panels with different diff_ids cannot, however tempting the table looks.
{
  printf 'panel\tdiff_id\tseats\tok\tdegraded\tinconclusive\tfailed\tsynthesis\n'
  for d in "$REVIEWS"/*/; do
    [ -d "$d" ] || continue
    p=$(basename "$d")
    bt=$(sed -n 's/^base-tree: *//p'     "$d/manifest.txt" 2>/dev/null)
    rt=$(sed -n 's/^reviewed-tree: *//p' "$d/manifest.txt" 2>/dev/null)
    did="unknown"
    [ -n "$bt" ] && [ -n "$rt" ] && did="${bt:0:8}..${rt:0:8}"
    n=0 o=0 g=0 u=0 f=0
    while IFS=$'\t' read -r pp _s _fam st _b _sec _prompt _src; do
      [ "$pp" = "$p" ] || continue
      # A gated-off seat is retained in slots.tsv as operational provenance but
      # was never on the reviewing panel, so it cannot pad the seat denominator.
      [ "$st" = skipped ] && continue
      n=$((n+1))
      # ★ `inconclusive` gets its own column rather than falling into the `*)`
      # arm with failed. Collapsing it there is what would make this table say a
      # panel had one broken adapter when what it really had was a model that
      # will not review -- and this table is the benchmark record, so that is
      # the number a roster decision gets made on.
      case "$st" in
        ok)           o=$((o+1)) ;;
        degraded)     g=$((g+1)) ;;
        inconclusive) u=$((u+1)) ;;
        *)            f=$((f+1)) ;;
      esac
    done < <(tail -n +2 "$SLOTS")
    syn=none
    [ -s "$d/synthesis.md" ]        && syn=ok
    [ -s "$d/synthesis.md.failed" ] && syn=failed
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$p" "$did" "$n" "$o" "$g" "$u" "$f" "$syn"
  done
} > "$PANELS"

echo "wrote $SLOTS"
echo "wrote $PANELS"
