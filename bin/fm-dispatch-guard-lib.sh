#!/usr/bin/env bash
# fm-dispatch-guard-lib.sh - the one owner of the crew-dispatch table check a
# ship or scout launch must pass. bin/fm-spawn.sh applies it at launch, and
# bin/fm-control.sh applies it before a relaunch stops the running agent, so a
# refused profile never costs a live worker.
#
# A profile passes when data/<id>/dispatch-override records the captain's
# explicit override, or when its harness, model, and effort match a candidate
# of the named rule that is not "off" (docs/configuration.md "Crew dispatch
# profiles"). With no configured default, the default rule accepts the static
# crew harness from bin/fm-harness.sh crew, a bare adapter name. Refusals print
# one line on stderr.
#
# A matched profile then passes the runway-feasibility check: one bounded
# `quota-axi --json` snapshot is read, every non-off candidate of the rule is
# evaluated by quota_evaluate and quota_runway_gate in bin/fm-quota-axi-lib.sh
# (the one owner shared with bin/fm-dispatch-resolve.sh), and a profile whose
# runway ends before its reset is refused while another candidate of the same
# rule runs through its reset; the refusal lists those candidates by
# spendPriority, highest first. An all-tight rule refuses nothing. Missing
# quota data never refuses: an absent quota-axi is skipped silently (bootstrap
# already reports it MISSING), and a failed, timed-out, or invalid snapshot
# prints one note on stderr and admits. The captain override skips this check
# like the match above.

# fm_dispatch_table_admits <bin-dir> <config-file> <override-file> <rule> <harness> <model> <effort>
fm_dispatch_table_admits() {
  local bin=$1 config=$2 override=$3 rule=$4 harness=$5 model=$6 effort=$7 out rc=0 crew
  if [ -f "$override" ] && [ ! -L "$override" ] && [ -s "$override" ]; then
    return 0
  fi
  out=$("$bin/fm-dispatch-select.sh" "$config" "$rule" 2>&1) || rc=$?
  if [ "$rc" -eq 2 ] && [ "$rule" = default ] && [ "$out" = "error: selector default names no rule" ]; then
    crew=$("$bin/fm-harness.sh" crew 2>/dev/null) || crew=
    if [ -n "$crew" ] && [ "$harness" = "$crew" ]; then
      return 0
    fi
    echo "error: spawn refused - crew-dispatch.json has no default, and $harness is not the static crew harness ${crew:-<unresolved>}; record the captain's explicit override at $override or pass that harness" >&2
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    echo "error: spawn refused - crew-dispatch rule '$rule' did not resolve through bin/fm-dispatch-select.sh: $out" >&2
    return 1
  fi
  if ! jq -e --arg s "$rule" --arg h "$harness" --arg m "$model" --arg e "$effort" '
    def field($k): if (.[$k] | type) == "string" then .[$k] else "" end;
    (if $s == "default" then .default else .rules[$s | tonumber].use end)
    | (if type == "array" then . else [.] end)
    | any(.[]; .off != true and .harness == $h and field("model") == $m and field("effort") == $e)
  ' "$config" >/dev/null 2>&1; then
    echo "error: spawn refused - $harness/${model:-<none>}/${effort:-<none>} does not match crew-dispatch rule $rule: no candidate profile of that rule has this harness, model, and effort; record the captain's explicit override at $override or pass one of its profiles" >&2
    return 1
  fi
  fm_dispatch_runway_admits "$bin" "$config" "$override" "$rule" "$harness" "$model" "$effort"
}

# fm_dispatch_runway_admits <bin-dir> <config-file> <override-file> <rule> <harness> <model> <effort>
fm_dispatch_runway_admits() {
  local bin=$1 config=$2 override=$3 rule=$4 harness=$5 model=$6 effort=$7 snapshot pmap refusal
  command -v quota-axi >/dev/null 2>&1 || return 0
  # shellcheck source=bin/fm-quota-axi-lib.sh
  . "$bin/fm-quota-axi-lib.sh"
  # shellcheck source=bin/fm-timeout-lib.sh
  . "$bin/fm-timeout-lib.sh"
  if ! snapshot=$(fm_run_timed 20 quota-axi --json 2>/dev/null </dev/null) ||
     ! printf '%s\n' "$snapshot" | fm_quota_json_valid; then
    echo "note: crew-dispatch runway not checked - quota-axi --json gave no valid snapshot; admitting $harness/${model:-<none>}/${effort:-<none>} with that uncertainty" >&2
    return 0
  fi
  pmap=$(fm_quota_provider_map "$config" 2>/dev/null) || pmap='{}'
  refusal=$(printf '%s\n' "$snapshot" | jq -r --slurpfile cfg "$config" --argjson pmap "$pmap" \
    --arg s "$rule" --arg h "$harness" --arg m "$model" --arg e "$effort" "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ"'
    . as $q |
    def field($p; $k): if ($p[$k] | type) == "string" then $p[$k] else "" end;
    ($cfg[0] | if $s == "default" then .default else .rules[$s | tonumber].use end
      | if type == "array" then . else [.] end | map(select(.off != true))) as $use |
    quota_runway_gate($use | map(quota_evaluate($q; $pmap; .))) as $cands |
    ([$cands[] | select((.profile.grok_bot | not) and .profile.harness == $h
       and field(.profile; "model") == $m and field(.profile; "effort") == $e)] | first) as $mine |
    if $mine == null or ($mine.runway_refused | not) then empty
    else $mine.reason end' 2>/dev/null) || {
    echo "note: crew-dispatch runway not checked - the quota snapshot could not be evaluated; admitting $harness/${model:-<none>}/${effort:-<none>} with that uncertainty" >&2
    return 0
  }
  [ -n "$refusal" ] || return 0
  echo "error: spawn refused - $harness/${model:-<none>}/${effort:-<none>} on crew-dispatch rule $rule: $refusal; pass one of those profiles or record the captain's explicit override at $override" >&2
  return 1
}
