# A grading table's inputs, exclusions, and saved result. Sourced after common.sh.
# shellcheck shell=bash

table_manifest_abort() {
  [ -z "${TABLE_STAGE:-}" ] || rm -rf -- "$TABLE_STAGE"
  TABLE_STAGE=""
}

table_manifest_error() {
  echo "cadre: table manifest: $*" >&2
  table_manifest_abort
  return 1
}

# Full SHA-256 of the actual file, rather than content_sha's short composite.
table_manifest_hash() {
  local digest
  [ -n "${SHA_CMD:-}" ] && [ -f "$1" ] && [ -r "$1" ] || return 1
  # shellcheck disable=SC2086 # SHA_CMD is sha256sum or shasum -a 256.
  digest=$(set -o pipefail; $SHA_CMD < "$1" | cut -d' ' -f1) || return 1
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
  printf '%s\n' "$digest"
}

# Caller holds the candidate lock. Nothing in the report changes at this gate.
table_manifest_begin() { # <report> <candidate> <runs> <selection> <freeze> <scope> <judges...>
  local report="$1" candidate="$2" runs="$3" selection="$4" freeze="$5" scope="$6" status
  shift 6
  TABLE_STAGE=""
  case "$selection" in all-runs|first-run) ;; *) table_manifest_error "unknown selection '$selection'"; return 1 ;; esac
  case "$freeze" in 0|1) ;; *) table_manifest_error "freeze must be 0 or 1"; return 1 ;; esac
  [[ "$runs" =~ ^[1-9][0-9]*$ ]] || { table_manifest_error "requested runs must be a positive integer"; return 1; }
  TABLE_DIR="${report%.md}.table"
  TABLE_SELECTION="$selection" TABLE_FREEZE="$freeze" TABLE_CANDIDATE_SLUG="$(slug "$candidate")"
  if [ -e "$TABLE_DIR/manifest.json" ]; then
    status=$(jq -ser '
      if length != 1 or (.[0] | type) != "object" then error("expected one manifest object") else .[0] end
      | def hash: type == "string" and test("^[0-9a-f]{64}$");
        if .schema == 1 and (.status == "open" or .status == "frozen")
          and (.selection == "all-runs" or .selection == "first-run")
          and (.candidate | type == "string")
          and (.requested_runs | type == "number" and . >= 1 and . == floor)
          and (.scope | . == null or type == "string")
          and (.judges | type == "array" and length > 0 and all(.[]; type == "string"))
          and (.passes | type == "array" and all(.[];
            (.label | type == "string") and (.target_sha | . == null or type == "string")
            and (.key_sha256 | . == null or hash)))
          and (.excluded | type == "array" and all(.[];
            (.kind | type == "string") and (.label | type == "string")
            and (.reason | type == "string" and test("\\S"))
            and (.run | . == null or (type == "number" and . >= 1 and . == floor))
            and (.run_id | . == null or type == "string")))
          and .results == "results.json" and (.results_sha256 | hash)
          and .report == "report.md" and (.report_sha256 | hash)
        then .status else error("invalid manifest fields") end
    ' "$TABLE_DIR/manifest.json" 2>/dev/null) || {
      table_manifest_error "invalid existing manifest: $TABLE_DIR/manifest.json"; return 1;
    }
    [ "$status" != frozen ] || { table_manifest_error "table is frozen: $TABLE_DIR/manifest.json"; return 1; }
  elif [ -e "$TABLE_DIR" ]; then
    table_manifest_error "table directory has no manifest: $TABLE_DIR"; return 1
  fi
  TABLE_STAGE=$(mktemp -d "$CADRE_HOME/.table-stage.XXXXXX") || return 1
  jq -n --arg candidate "$candidate" --arg selection "$selection" --argjson runs "$runs" \
    --arg scope "$scope" --args '
      {schema:1, candidate:$candidate, selection:$selection, requested_runs:$runs,
       scope:(if $scope == "" then null else $scope end), judges:$ARGS.positional}
    ' -- "$@" > "$TABLE_STAGE/meta.json" &&
    : > "$TABLE_STAGE/passes.jsonl" && : > "$TABLE_STAGE/excluded.jsonl" &&
    : > "$TABLE_STAGE/runs.jsonl" && : > "$TABLE_STAGE/key-checks.jsonl" || {
      table_manifest_error "could not stage table metadata"; return 1;
    }
}

table_manifest_pass() { # <label> <target-sha> <keyfile>
  local hash=""
  if [ -f "$3" ]; then
    hash=$(table_manifest_hash "$3") || { table_manifest_error "could not hash key for '$1'"; return 1; }
  fi
  jq -cn --arg label "$1" --arg target "$2" --arg hash "$hash" '
    {label:$label, target_sha:(if $target == "" then null else $target end),
     key_sha256:(if $hash == "" then null else $hash end)}
  ' >> "$TABLE_STAGE/passes.jsonl" || { table_manifest_error "could not record pass '$1'"; return 1; }
  # Absolute source paths are private staging data, removed before publication.
  jq -cn --arg label "$1" --arg path "$3" --arg hash "$hash" '{label:$label,path:$path,hash:$hash}' \
    >> "$TABLE_STAGE/key-checks.jsonl" || { table_manifest_error "could not stage key check"; return 1; }
}

table_manifest_exclude() { # <kind> <label> <run-or-empty> <reason>
  local id=""
  [ -z "$3" ] || id="$2/$TABLE_CANDIDATE_SLUG-run$3"
  jq -cn --arg kind "$1" --arg label "$2" --arg run "$3" --arg id "$id" --arg reason "$4" '
    if ($reason | test("\\S")) then
      {kind:$kind, label:$label, run:(if $run == "" then null else ($run | tonumber) end),
       run_id:(if $id == "" then null else $id end), reason:$reason}
    else error("exclusion needs a reason") end
  ' >> "$TABLE_STAGE/excluded.jsonl" || { table_manifest_error "could not record exclusion for '$2'"; return 1; }
}

table_manifest_run() { # <label> <run> <status> <item-row-or-empty> <grade-paths...>
  local label="$1" run="$2" status="$3" row="$4" items refs='[]' source path hash raw_ref raw_hash
  shift 4
  items=$(jq -cn --arg row "$row" '
    ($row | [splits("\\s+") | select(length > 0)]) as $terms
    | if all($terms[]; test("^K[0-9]+=(HIT|MISS|DEFER|UNRESOLVED)$")) then
        $terms | map(capture("^(?<key>K[0-9]+)=(?<value>HIT|MISS|DEFER|UNRESOLVED)$")) | from_entries
      else error("invalid item row") end
  ') || { table_manifest_error "invalid item row for '$label' run $run"; return 1; }
  for source in "$@"; do
    [ -f "$source" ] || continue
    path="grades/$(slug "$label")/$(basename "$source")"
    mkdir -p "$TABLE_STAGE/$(dirname "$path")" && cp -- "$source" "$TABLE_STAGE/$path" || {
      table_manifest_error "could not snapshot grade for '$label' run $run"; return 1;
    }
    hash=$(table_manifest_hash "$TABLE_STAGE/$path") || { table_manifest_error "could not hash saved grade"; return 1; }
    raw_ref=null
    if [ -f "$source.judge-raw" ]; then
      cp -- "$source.judge-raw" "$TABLE_STAGE/$path.judge-raw" || {
        table_manifest_error "could not snapshot judge failure output"; return 1;
      }
      raw_hash=$(table_manifest_hash "$TABLE_STAGE/$path.judge-raw") || { table_manifest_error "could not hash judge failure output"; return 1; }
      raw_ref=$(jq -cn --arg file "$path.judge-raw" --arg hash "$raw_hash" '{file:$file,sha256:$hash}') || return 1
    fi
    refs=$(jq -cn --argjson refs "$refs" --arg file "$path" --arg hash "$hash" --argjson raw "$raw_ref" \
      '$refs + [({file:$file,sha256:$hash} + if $raw == null then {} else {judge_raw:$raw} end)]') || {
        table_manifest_error "could not record grade reference"; return 1;
      }
  done
  jq -cn --arg label "$label" --argjson run "$run" --arg status "$status" \
    --arg id "$label/$TABLE_CANDIDATE_SLUG-run$run" --argjson items "$items" --argjson grades "$refs" '
      {label:$label,run:$run,run_id:$id,status:$status,items:$items,grades:$grades}
    ' >> "$TABLE_STAGE/runs.jsonl" || { table_manifest_error "could not record run"; return 1; }
}

table_manifest_totals() { # <blocking hit/total/unresolved> <all hit/total/unresolved> <delivery blocking/all miss> <suspect>
  jq -n --argjson bh "$1" --argjson bt "$2" --argjson bu "$3" \
    --argjson ah "$4" --argjson at "$5" --argjson au "$6" \
    --argjson db "$7" --argjson da "$8" --argjson suspect "$9" '
      def cell($hit; $total; $unresolved):
        if $total == 0 then null
        else {hit_low:$hit,hit_high:($hit + $unresolved),total:$total,unresolved:$unresolved} end;
      def basis($blocking; $all):
        if $all == 0 then null
        else {blocking:cell($bh;$blocking;$bu),all_items:cell($ah;$all;$au)} end;
      if $suspect > 0 then {scored:false,graded_only:null,delivery_inclusive:null}
      else {scored:($at + $da > 0),graded_only:basis($bt;$at),
            delivery_inclusive:basis($bt + $db;$at + $da)} end
    ' > "$TABLE_STAGE/summary.json" || { table_manifest_error "could not record table totals"; return 1; }
}

table_manifest_finish() { # <finished-report> [published-report]
  local report="$1" published="${2:-$1}" hash report_hash title metadata report_tmp backup="" state=open check key_path initial
  # A key edited during grading cannot be published under its starting hash.
  # Missing-to-present and present-to-missing changes count as drift too.
  while IFS= read -r check; do
    key_path=$(jq -r '.path' <<< "$check")
    initial=$(jq -r '.hash' <<< "$check")
    hash=""
    if [ -f "$key_path" ]; then
      hash=$(table_manifest_hash "$key_path") || { table_manifest_error "could not recheck key hash"; return 1; }
    fi
    [ "$hash" = "$initial" ] || { table_manifest_error "key changed during grading for '$(jq -r '.label' <<< "$check")'; re-grade"; return 1; }
  done < "$TABLE_STAGE/key-checks.jsonl"
  [ "$TABLE_FREEZE" = 0 ] || state=frozen
  [ -f "$TABLE_STAGE/summary.json" ] || printf 'null\n' > "$TABLE_STAGE/summary.json"
  jq -n --slurpfile meta "$TABLE_STAGE/meta.json" --slurpfile runs "$TABLE_STAGE/runs.jsonl" \
    --slurpfile summary "$TABLE_STAGE/summary.json" '
    (reduce $runs[] as $run ({}; .[$run.run_id] = $run) | [.[]]) as $latest
    | {schema:1,candidate:$meta[0].candidate,selection:$meta[0].selection,
       run_source:"Latest retained completion for each numbered run slot; not historical dispatch attempts.",
       runs:$latest,summary:$summary[0]}
  ' > "$TABLE_STAGE/results.json" || { table_manifest_error "could not save results"; return 1; }
  hash=$(table_manifest_hash "$TABLE_STAGE/results.json") || { table_manifest_error "could not hash results"; return 1; }
  jq -n --slurpfile meta "$TABLE_STAGE/meta.json" --slurpfile passes "$TABLE_STAGE/passes.jsonl" \
    --slurpfile excluded "$TABLE_STAGE/excluded.jsonl" --arg state "$state" --arg hash "$hash" '
      $meta[0] + {status:$state,passes:$passes,excluded:$excluded,
                  results:"results.json",results_sha256:$hash,report:"report.md"}
    ' > "$TABLE_STAGE/manifest.json" || { table_manifest_error "could not save manifest"; return 1; }
  # Read the saved manifest, so prose cannot disagree with the recorded table.
  metadata=$(jq -r --arg path "$(basename "$TABLE_DIR")/manifest.json" '
    "Selection: `\(.selection)`. Excluded: **\(.excluded | length)** entries. Table: `\($path)`. Status: `\(.status)`."
  ' "$TABLE_STAGE/manifest.json") || { table_manifest_error "could not read saved manifest"; return 1; }
  IFS= read -r title < "$report" || { table_manifest_error "could not read report title"; return 1; }
  {
    printf '%s\n\n%s\n' "$title" "$metadata"
    tail -n +2 "$report"
  } > "$TABLE_STAGE/report.md" || { table_manifest_error "could not snapshot report"; return 1; }
  report_hash=$(table_manifest_hash "$TABLE_STAGE/report.md") || { table_manifest_error "could not hash report"; return 1; }
  jq --arg hash "$report_hash" '. + {report_sha256:$hash}' "$TABLE_STAGE/manifest.json" \
    > "$TABLE_STAGE/manifest.new" && mv "$TABLE_STAGE/manifest.new" "$TABLE_STAGE/manifest.json" || {
      table_manifest_error "could not record report hash"; return 1;
    }
  rm -f "$TABLE_STAGE/meta.json" "$TABLE_STAGE/passes.jsonl" "$TABLE_STAGE/excluded.jsonl" \
    "$TABLE_STAGE/runs.jsonl" "$TABLE_STAGE/summary.json" "$TABLE_STAGE/key-checks.jsonl"
  rm -f "$TABLE_STAGE/working-report.md"
  report_tmp=$(mktemp "$published.table.XXXXXX") || { table_manifest_error "could not stage report publication"; return 1; }
  cp "$TABLE_STAGE/report.md" "$report_tmp" || {
    rm -f "$report_tmp"; table_manifest_error "could not stage report publication"; return 1;
  }
  # The candidate lock serializes publishers. Retain the old directory until
  # both renames succeed, and restore it if publication fails.
  if [ -e "$TABLE_DIR" ]; then
    backup=$(mktemp -d "$TABLE_DIR.previous.XXXXXX") && rmdir "$backup" && mv "$TABLE_DIR" "$backup" || {
      rm -f "$report_tmp"; table_manifest_error "could not retain previous table"; return 1;
    }
  fi
  if ! mv "$TABLE_STAGE" "$TABLE_DIR"; then
    [ -z "$backup" ] || mv "$backup" "$TABLE_DIR"
    rm -f "$report_tmp"; table_manifest_error "could not publish table"; return 1
  fi
  TABLE_STAGE=""
  if ! mv "$report_tmp" "$published"; then
    rm -rf -- "$TABLE_DIR"
    [ -z "$backup" ] || mv "$backup" "$TABLE_DIR"
    rm -f "$report_tmp"; table_manifest_error "could not publish report"; return 1
  fi
  [ -z "$backup" ] || rm -rf -- "$backup"
}
