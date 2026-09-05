# Optional execution check for mined pairs. Sourced by mine-fixes.sh only when
# explicitly enabled. This is a disposable working tree, NOT a sandbox.
# shellcheck shell=bash

verify_pairs_check() {
  local repo="$1"
  repo=$(git -C "$repo" rev-parse --show-toplevel) || die "verification needs a working-tree repository"
  case "${CADRE_VERIFY_TIMEOUT:-120}" in
    ''|*[!0-9]*|0) die "CADRE_VERIFY_TIMEOUT must be a positive integer (seconds)" ;;
  esac
  [ "${CADRE_VERIFY_TIMEOUT:-120}" -gt 0 ] 2>/dev/null || die "CADRE_VERIFY_TIMEOUT must be a positive integer (seconds)"
  command -v timeout >/dev/null || die "pair verification needs GNU timeout"
  case "$(readlink -m "$CADRE_WORK")/" in
    "$(readlink -f "$repo")"/*) die "pair verification CADRE_WORK must be outside the source repo" ;;
  esac
}

verify_pairs_init() {
  verify_pairs_check "$1"
  CADRE_WORK=$(readlink -m "$CADRE_WORK")
  CADRE_HOME=$(readlink -m "$CADRE_HOME")
  mkdir -p "$CADRE_WORK" "$CADRE_HOME/verification" || die "cannot create verification directories"
  VERIFY_RECEIPTS=$(mktemp -d "$CADRE_HOME/verification/run-XXXXXXXX") || die "cannot create verification receipts"
  echo "Executing repository tests (not sandboxed); receipts: $VERIFY_RECEIPTS" >&2
}

# detect_test_cmd supplies targeted examples for review prompts. Expand only
# those known examples; an explicit CADRE_TEST_CMD is already executable text.
verify_test_cmd() {
  local cmd; cmd=$(detect_test_cmd "$1")
  if [ -z "${CADRE_TEST_CMD:-}" ]; then
    case "$cmd" in
      'go test ./<pkg>') cmd='go test ./...' ;;
      'cargo test <name>') cmd='cargo test' ;;
      'pytest <path-to-test-file>') cmd='pytest' ;;
      'npx vitest run <path-to-test-file>') cmd='npx --no-install vitest run' ;;
      'npx jest <path-to-test-file>') cmd='npx --no-install jest' ;;
    esac
  fi
  printf '%s' "$cmd"
}

verify_pair() (
  # A subshell owns cleanup so interrupts cannot leave the execution tree
  # behind or replace the miner's own traps. Logs survive in CADRE_HOME.
  local repo="$1" fix="$2" dest receipt cmd f rc reason=checkout-error
  local status=unverified fixed_rc='' reverted_rc='' paths=() inline_tests=0
  receipt="$VERIFY_RECEIPTS/$fix"
  mkdir -p "$receipt" || exit 2
  dest=$(mktemp -d "$CADRE_WORK/verify-XXXXXXXX") || exit 2
  trap 'rm -rf -- "$dest"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Each arm starts from a fresh archive: generated files or changed tests from
  # the green run must not make the reverted run fail (or hide its failure).
  if git -C "$repo" archive "$fix" | tar -x -C "$dest"; then
    cmd=$(verify_test_cmd "$dest")
    printf '%s\n' "$cmd" > "$receipt/command.txt"
    if [ -z "$cmd" ]; then
      status=no-test-cmd; reason=no-test-cmd
    else
      (cd "$dest" && timeout --kill-after=5 "${CADRE_VERIFY_TIMEOUT:-120}" bash -c "$cmd") > "$receipt/fixed.log" 2>&1
      fixed_rc=$?
      reason=fixed-not-green
      if [ "$fixed_rc" -eq 0 ]; then
        rm -rf -- "$dest"
        mkdir -p "$dest"
        if git -C "$repo" archive "$fix" | tar -x -C "$dest"; then
          # Reverse source files only. --no-renames exposes both sides of a
          # rename; NUL records and literal pathspecs keep unusual names intact.
          while IFS= read -r -d '' f; do
            case "$f" in *.ts|*.tsx|*.js|*.jsx|*.py|*.go|*.rs|*.java|*.rb) ;; *) continue ;; esac
            case "${f##*/}" in
              *_test.go|test_*.py|*_test.py|*_spec.rb|spec_*.rb|*_test.rb|test_*.rb|*Test.java|*Tests.java|Test*.java) continue ;;
            esac
            printf '%s\n' "$f" | grep -iE '(^|/)(tests?|__tests__|spec|e2e)/|\.(test|spec)\.|\.d\.ts$' >/dev/null && continue
            # Rust commonly embeds unit tests in production files. Reverting
            # the whole file would also revert its assertions and manufacture
            # red/green evidence. Under-verify instead of attempting AST edits.
            if [[ "$f" = *.rs ]] &&
               { git -C "$repo" show "$fix:$f" 2>/dev/null || true; git -C "$repo" show "$fix^:$f" 2>/dev/null || true; } |
               grep -E '(^|[^[:alnum:]_])(test|doctest)([^[:alnum:]_]|$)' >/dev/null; then
              inline_tests=1
            fi
            paths+=(":(literal)$f")
          done < <(git -C "$repo" diff --no-renames --name-only -z "$fix^" "$fix")
          reason=source-revert-error
          [ "$inline_tests" -eq 0 ] || reason=inline-tests-not-separated
          if [ "$inline_tests" -eq 0 ] && [ "${#paths[@]}" -gt 0 ] &&
             git -C "$repo" diff --binary --no-renames "$fix" "$fix^" -- "${paths[@]}" > "$receipt/source-revert.patch" &&
             (cd "$dest" && GIT_CEILING_DIRECTORIES="$(dirname -- "$dest")" git apply --binary -- "$receipt/source-revert.patch") 2> "$receipt/revert.log"; then
            (cd "$dest" && timeout --kill-after=5 "${CADRE_VERIFY_TIMEOUT:-120}" bash -c "$cmd") > "$receipt/reverted.log" 2>&1
            reverted_rc=$?
            reason=reverted-not-red
            # timeout, launch errors, and signals do not establish a failing
            # test. Ordinary nonzero suite exits are recorded for human audit.
            if [ "$reverted_rc" -gt 0 ] && [ "$reverted_rc" -lt 124 ]; then
              status=verified; reason=fixed-green-reverted-red
            fi
          fi
        fi
      fi
    fi
  fi
  printf 'status\treason\tfixed_exit\treverted_exit\n%s\t%s\t%s\t%s\n' \
    "$status" "$reason" "$fixed_rc" "$reverted_rc" > "$receipt/result.tsv"
  printf '%s\n' "$status"
)
