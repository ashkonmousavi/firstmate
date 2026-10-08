#!/usr/bin/env bash
# fm-start-gate-lib.sh - the new-feature start gate a fresh ship spawn passes.
#
# A new feature task does not start while any main failure cause or frozen
# machine of its project has no active worker; fixes, reverts, live-breakage
# work and already-open work are never refused by this gate, and it is not a
# merge freeze. bin/fm-spawn.sh calls fm_start_gate_admit once for a fresh
# ship, before any lock, slot, endpoint, task record or backlog transition, so
# a refusal allocates nothing. Relaunch (recovery of open work), scouts and
# secondmates never reach it, and every existing allocation, isolation and
# account guard keeps its own authority after this gate permits.
#
# Applicability is configured, never inferred: only a project named in this
# home's config/start-gate.json is gated, so an absent file or an unnamed
# project keeps today's spawn contract unchanged. docs/configuration.md
# ("Feature start gate") owns that file's schema.
#
# Task class is authored in the preparation record's Tier section as one line,
#   - Work class: <feature|fix|revert|live-breakage>
# read by bin/fm-dod-lib.sh's fm_prep_work_class. It is never guessed from a
# title, model or UI tier. A gated project refuses a fresh ship whose class is
# missing or unrecognised, naming the line to add, without consulting facts.
# Any class other than feature passes without reading facts, so a repair is
# never refused by fact health.
#
# Facts are produced outside spawn by the project's fact owner (the private
# collector registered as a check), never by a fleet scan here. The locator is
# the configured "facts" path; the snapshot is one JSON object:
#   {"schema": "fm-start-facts.v1",
#    "generated_at": <integer epoch seconds>,
#    "project": "<registered project name>",
#    "causes": [
#      {"id": "<stable cause id>",
#       "kind": "main-failure" | "frozen-machine",
#       "detail": "<one-line human cause>",
#       "owner_task": "<task id>" | null,
#       "owner_state": "<reconciled worker state>" | null}
#    ]}
# causes lists every current main failure cause and frozen machine; an empty
# array is the healthy claim. owner_state is the producer's reconciled live
# worker state (bin/fm-crew-state.sh from a live source, never a status line).
# A cause is covered only when owner_task satisfies fm-pr-lib.sh's
# fm_task_id_path_safe contract and owner_state is working or validating.
#
# A feature start is refused, naming the reason, when the snapshot is missing,
# unreadable, not that schema, for another project, older than the configured
# max_age_seconds (default 900) or dated more than 300 seconds ahead, or any
# cause is malformed; unknown facts are never treated as healthy. Otherwise it
# is refused naming each uncovered cause, or permitted.
#
# Requires bin/fm-dod-lib.sh already sourced and jq on PATH for a gated
# project. No side effects on source; set -u / set -e safe.

FM_START_GATE_DEFAULT_MAX_AGE=900
FM_START_GATE_FUTURE_SKEW=300

# fm_start_gate_admit <config-file> <project> <prep-file> [now]
# Exit 0 permits (stderr carries one notice when the project is gated);
# exit 1 refuses with one stderr error line per reason.
fm_start_gate_admit() {
  local config=$1 project=$2 prep=$3 now=${4:-} entry facts max_age class verdict
  [ -e "$config" ] || return 0
  command -v jq >/dev/null 2>&1 || {
    echo "error: start gate: jq is required to read $config" >&2
    return 1
  }
  if ! entry=$(jq -cs --arg p "$project" '
      if length != 1 or (.[0] | type) != "object" then error("config must be one JSON object")
      else .[0] |
        if has($p) then .[$p] |
          if type == "object" then . else error("project entry must be an object") end
        else empty end
      end
    ' "$config" 2>/dev/null); then
    echo "error: start gate: $config is not one JSON object with an object entry for $project; correct it before spawning" >&2
    return 1
  fi
  [ -n "$entry" ] || return 0
  facts=$(printf '%s\n' "$entry" | jq -r 'if (.facts | type) == "string" and (.facts | startswith("/")) then .facts else empty end')
  max_age=$(printf '%s\n' "$entry" | jq -r --argjson d "$FM_START_GATE_DEFAULT_MAX_AGE" '
    (if has("max_age_seconds") then .max_age_seconds else $d end)
    | if type == "number" and . > 0 and . == floor then . else empty end')
  if [ -z "$facts" ] || [ -z "$max_age" ]; then
    echo "error: start gate: $config entry for $project needs an absolute \"facts\" path and an optional positive integer \"max_age_seconds\"" >&2
    return 1
  fi
  if ! class=$(fm_prep_work_class "$prep"); then
    echo "error: start gate: $project gates new features, so $prep must declare one Tier line '- Work class: <feature|fix|revert|live-breakage>'; add it and spawn again" >&2
    return 1
  fi
  if [ "$class" != feature ]; then
    echo "notice: start gate: $project work class $class is never refused by main or machine health" >&2
    return 0
  fi
  [ -n "$now" ] || now=$(date +%s)
  if [ ! -f "$facts" ] || [ ! -r "$facts" ]; then
    echo "error: start gate: $project feature start refused - facts unknown: no readable snapshot at $facts" >&2
    return 1
  fi
  verdict=$(jq -r -s --arg p "$project" --argjson now "$now" --argjson age "$max_age" \
    --argjson skew "$FM_START_GATE_FUTURE_SKEW" '
    def bad($m): "unknown\t" + $m;
    if length != 1 or (.[0] | type) != "object" then bad("snapshot is not one JSON object")
    else .[0] |
      if .schema != "fm-start-facts.v1" then bad("schema is not fm-start-facts.v1")
      elif .project != $p then bad("snapshot is for project \(.project | tojson), not \($p)")
      elif (.generated_at | type) != "number" or .generated_at != (.generated_at | floor) then bad("generated_at is not integer epoch seconds")
      elif .generated_at > $now + $skew then bad("generated_at is in the future")
      elif $now - .generated_at > $age then bad("snapshot is \($now - .generated_at)s old, over the \($age)s limit")
      elif (.causes | type) != "array" then bad("causes is not an array")
      elif any(.causes[]; type != "object"
          or (.id | type) != "string" or .id == ""
          or (.kind | IN("main-failure", "frozen-machine") | not)
          or (.detail | type) != "string"
          or ((.owner_task | type) | IN("string", "null") | not)
          or (.owner_task | if type == "string" and . != "" then test("\\A[A-Za-z0-9_-][A-Za-z0-9._-]*\\z") | not else false end)
          or ((.owner_state | type) | IN("string", "null") | not))
        then bad("a cause lacks a string id, a main-failure or frozen-machine kind, a string detail, a valid task id or empty/null owner_task, or string-or-null owner_state")
      else
        [.causes[] | select(((.owner_task // "") == "") or ((.owner_state // "") | IN("working", "validating") | not))]
        | if length == 0 then "permit"
          else .[] | "uncovered\t\(.kind) \(.id): \(.detail) (owner: \(.owner_task // "none")\(if .owner_task then ", " + (.owner_state // "unknown") else "" end))"
          end
      end
    end' "$facts" 2>/dev/null) || verdict=$'unknown\tsnapshot is not valid JSON'
  case "$verdict" in
  permit)
    echo "notice: start gate: $project feature start permitted - every main failure and frozen machine has an active worker" >&2
    return 0
    ;;
  unknown*)
    echo "error: start gate: $project feature start refused - facts unknown: ${verdict#unknown$'\t'} ($facts)" >&2
    return 1
    ;;
  esac
  printf '%s\n' "$verdict" | while IFS=$'\t' read -r _ cause; do
    echo "error: start gate: $project feature start refused - no worker on $cause" >&2
  done
  echo "error: start gate: start a fix, revert or live-breakage task for each cause above, or wait until its worker is active; open work is unaffected" >&2
  return 1
}
