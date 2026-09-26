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
}
