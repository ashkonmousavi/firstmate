#!/usr/bin/env bash
# fm-autolaunch.sh - fill free machine lanes from this home's prepared backlog,
# with no model in the loop, and keep one record per decision.
#
# Usage:
#   fm-autolaunch.sh                 one pass: launch or refuse, one record each
#   fm-autolaunch.sh --dry-run       print the decisions and spawn commands; write nothing
#   fm-autolaunch.sh --list-prepared print, in launch order, the ids a pass would try
#   fm-autolaunch.sh --print-timer   print a proposed systemd user timer and cron line
#   fm-autolaunch.sh --backfill [--apply]
#                                    print (default) or write the derived launch
#                                    record for every queued item lacking one
#   fm-autolaunch.sh --help
#
# A plain scheduler (cron or a systemd user timer, see --print-timer) runs one
# pass every five minutes with FM_HOME set explicitly. Nothing here enables a
# schedule; docs/configuration.md "Auto-launch" owns enabling it per machine.
# The pass never rides the watcher's check sweep, whose 30 s bound a spawn does
# not fit; only the companion throttle check bin/fm-autolaunch-check.sh does.
#
# ONE PASS.
#   1. Single instance: state/.autolaunch.lock (fm_lock_try_acquire). A busy
#      lock exits 0 with one stderr notice and no record; a holder stuck for
#      ten minutes is exactly what the throttle check turns red.
#   2. Capacity: bin/fm-capacity.sh --admit, the machine admission owner. A
#      refusal or zero free lanes is one `refused:no capacity: <reason>`
#      record and the pass ends. Nothing here relaxes or re-derives admission;
#      fm-spawn.sh re-checks machine and project capacity at launch.
#   3. Candidates: `bin/fm-tasks-axi.sh ready`, which already excludes held
#      (including parked) and blocked work, and treats a blocked-by edge whose
#      target is Done, archived, or absent as cleared. Items run in backlog
#      priority order (tasks-axi --priority 0 first, unprioritized last), ties
#      keeping ready-queue order; that priority is how J-01 work goes first.
#   4. Per lane, the first candidate that passes every check below launches.
#      Each refused candidate gets its own record and the next is tried:
#        refused:held                  `show` reports the item held
#        refused:not prepared: <why>   no brief, no prep file, a kind other
#                                      than ship or scout, no project clone, or
#                                      an invalid override record
#        refused:spawn deferred pending  state/spawn-deferred/queue already
#                                      holds this item; fm-spawn-deferred.sh
#                                      owns its retry, so it is never doubled
#        refused:dispatch: <reason>   no configured default
#        refused:quota: <reason>       every candidate profile is exhausted or
#                                      short of runway
#        refused:deferred: <line>      fm-spawn.sh exit 75 (machine or project
#                                      capacity, project lock); the pass ends
#                                      when the machine has no lane left
#        refused:spawn error: <line>   any other fm-spawn.sh failure
#      A launch is one `launched` record, after which capacity is read again.
#      When candidates run out with a lane still open, one
#      `refused:no prepared item` record names the first open lane.
#
# PREP. An item is prepared when it has a brief, data/<id>/brief.md (delivered
# by fm-spawn.sh unchanged), and a prep file: data/<id>/prep.md, or a data/*.md
# document linked from the item's backlog body whose path names prep, plan or
# spec and that exists in this home. Without either it is refused with that
# exact reason. Its launch record is then DERIVED, field by field, from the
# first source that has it:
#   1. data/<id>/autolaunch-prep, an optional override record;
#   2. the brief's own contract lines: "Delivery contract: mode=<m>" and its
#      upstream-consent= token, "Ship branch: <prefix><id>", "Base branch: <b>";
#   3. the backlog row: kind and repo (the project is $FM_HOME/projects/<repo>);
#   4. bin/fm-project-mode.sh for that project: registered mode, yolo, and
#      --branch-prefix (data/projects.md; no-mistakes-prod-only maps to
#      no-mistakes, its most rigorous leg).
# The record format is key=value lines, # comments and blank lines allowed,
# unknown keys refused, every key optional:
#   project=<name>  kind=ship|scout  mode=<no-mistakes|direct-PR|local-only>
#   yolo=on|off  branch_prefix=<p>  base_branch=<b>
#   upstream_consent=<host>/<owner>/<repo>
# bin/fm-brief.sh writes one for each brief it scaffolds (never yolo, which
# stays derived), and --backfill writes the derived record for existing items:
# without --apply it prints `would-write:`, `kept:` (a record already exists,
# never rewritten) and `skip: <id>: <reason>` lines and changes nothing, so a
# rerun is idempotent. Only a kind of ship or scout launches. The values become
# fm-spawn.sh flags as written; fm-spawn.sh validates them against the brief
# and refuses any disagreement, which is recorded.
#
# DISPATCH. No model is in the loop at all. The script makes no network call
# beyond fm-spawn.sh's own. The configured `default` profile(s) of
# config/crew-dispatch.json are tried deterministically: passing ones by
# highest known spendPriority, then uncertain ones in declared order, through
# fm-quota-axi-lib.sh's gate verdict over one quota-axi snapshot. Exhausted or
# short-runway profiles are never tried. With no config/crew-dispatch.json,
# use fm-spawn.sh's static crew harness.
# A spawn whose own quota gate refuses moves to the next candidate.
#
# RECORDS. state/autolaunch.log, append-only, one line per decision:
#   <UTC time>\t<lane>\t<item>\t<model>\t<result>
# lane is the 1-based free-lane ordinal of this pass, or - with no lane; item
# and model are - when not applicable; model is <harness>[:<model>] or static.
# Tabs and line breaks inside a reason become spaces. Each record is also
# printed on stdout. --dry-run prints `would-record:` lines and `would-run:`
# spawn commands, takes no lock, writes no file and spawns nothing; it still
# reads quota so its decisions match a real pass, and assumes each would-be
# launch uses one lane.
#
# Exit: 0 after a pass (refusals included) or a busy lock; 1 when the backlog
# or its log cannot be read or written; 2 usage.
# Test seams, honored only with FM_TEST_SEAM=1: FM_AUTOLAUNCH_CAPACITY_BIN,
# FM_AUTOLAUNCH_SPAWN_BIN replace fm-capacity.sh and fm-spawn.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

usage() { echo 'usage: fm-autolaunch.sh [--dry-run|--list-prepared|--print-timer|--backfill [--apply]|--help]' >&2; }

ACTION=run
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  --dry-run) ACTION=dry ;;
  --list-prepared) ACTION=list ;;
  --print-timer) ACTION=timer ;;
  --backfill) ACTION=backfill ;;
  *) usage; exit 2 ;;
esac
APPLY=0
if [ "$ACTION" = backfill ] && [ "${2:-}" = --apply ] && [ "$#" -eq 2 ]; then
  APPLY=1
elif [ "$#" -gt 1 ]; then
  usage; exit 2
fi

LOG="$STATE/autolaunch.log"
LOCK="$STATE/.autolaunch.lock"
RULES="$CONFIG/crew-dispatch.json"

CAPACITY_BIN="$SCRIPT_DIR/fm-capacity.sh"
SPAWN_BIN="$SCRIPT_DIR/fm-spawn.sh"
if [ "${FM_TEST_SEAM:-}" = 1 ]; then
  CAPACITY_BIN=${FM_AUTOLAUNCH_CAPACITY_BIN:-$CAPACITY_BIN}
  SPAWN_BIN=${FM_AUTOLAUNCH_SPAWN_BIN:-$SPAWN_BIN}
fi

home_abs() {
  case "$FM_HOME" in
    /*) printf '%s\n' "$FM_HOME" ;;
    *) (CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) ;;
  esac
}

if [ "$ACTION" = timer ]; then
  home=$(home_abs) || { echo "fm-autolaunch: cannot resolve FM_HOME" >&2; exit 1; }
  cmd="FM_HOME=$(printf '%q' "$home") $(printf '%q' "$SCRIPT_DIR/fm-autolaunch.sh")"
  cat <<EOF
# Proposed schedule for $home (not installed; see docs/configuration.md "Auto-launch").
# Register the unit in the machine inventory and route pause/resume through
# the fleet pause tool before enabling it.
#
# ~/.config/systemd/user/fm-autolaunch.service
[Unit]
Description=Firstmate auto-launch pass for $home

[Service]
Type=oneshot
Environment=FM_HOME=$home
ExecStart=$SCRIPT_DIR/fm-autolaunch.sh

# ~/.config/systemd/user/fm-autolaunch.timer
[Unit]
Description=Firstmate auto-launch every five minutes for $home

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target

# Or one crontab line instead of the two units:
*/5 * * * * $cmd >/dev/null 2>&1
EOF
  exit 0
fi

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"

flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300; }

TMPD=
LOCK_HELD=0
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup() {
  [ -z "$TMPD" ] || rm -rf -- "$TMPD"
  [ "$LOCK_HELD" = 0 ] || fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# record <lane> <item> <model> <result>
record() {
  local line
  line="$(date -u +%Y-%m-%dT%H:%M:%SZ)	$(flat "$1")	$(flat "$2")	$(flat "$3")	$(flat "$4")"
  if [ "$ACTION" = dry ]; then
    printf 'would-record: %s\n' "$line"
    return 0
  fi
  printf '%s\n' "$line" >&9 || { echo "fm-autolaunch: cannot append to $LOG" >&2; exit 1; }
  printf '%s\n' "$line"
}

# capacity_read: sets CAP_FREE and CAP_REASON; returns the admit status.
capacity_read() {
  local out rc=0 first
  out=$("$CAPACITY_BIN" --admit 2>&1) || rc=$?
  first=$(printf '%s\n' "$out" | sed -n '/^capacity:/{p;q;}')
  CAP_FREE=$(printf '%s\n' "$first" | sed -n 's/.*[[:space:]]free_lanes=\([0-9][0-9]*\).*/\1/p')
  CAP_REASON=$(printf '%s\n' "$first" | sed -n 's/.*[[:space:]]reason=\([^[:space:]]*\).*/\1/p')
  case "$CAP_FREE" in ''|*[!0-9]*) CAP_FREE=0 ;; esac
  if [ "$rc" != 0 ]; then
    CAP_REASON="${CAP_REASON:-unreadable}$(printf '%s\n' "$out" | sed -n 's/^fm-capacity: /; /p' | head -1)"
    CAP_FREE=0
  fi
  [ -n "$CAP_REASON" ] || CAP_REASON=unknown
  return "$rc"
}

# ready_ids: the ready queue's ids in backlog order, one per line.
ready_ids() {
  local out
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" ready 2>&1) || {
    printf 'backlog unreadable: %s\n' "$(flat "$out")" >&2
    return 1
  }
  printf '%s\n' "$out" | awk '
    /^ready\[[0-9]+\]/ { inside = 1; next }
    inside && /^  [^ ]/ { sub(/^  /, ""); sub(/,.*/, ""); print; next }
    inside { inside = 0 }'
}

# queued_ids: every queued item's id, in backlog order.
queued_ids() {
  local out
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --state queued 2>&1) || {
    printf 'backlog unreadable: %s\n' "$(flat "$out")" >&2
    return 1
  }
  printf '%s\n' "$out" | awk '
    /^tasks\[[0-9]+\]/ { inside = 1; next }
    inside && /^  [^ ]/ { sub(/^  /, ""); sub(/,.*/, ""); print; next }
    inside { inside = 0 }'
}

# field <show-output> <name>: one `show` field, outer quotes removed, - as empty.
show_field() {
  local v
  v=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$v" in \"*\") v=${v#\"} v=${v%\"} ;; esac
  [ "$v" != - ] || v=''
  printf '%s' "$v"
}

# item_show <id>: sets ITEM_HELD, ITEM_KIND, ITEM_REPO, ITEM_PRIORITY,
# ITEM_BODY from `show --full`.
item_show() {
  local out
  ITEM_HELD='' ITEM_KIND='' ITEM_REPO='' ITEM_PRIORITY='' ITEM_BODY=''
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  ITEM_HELD=$(show_field "$out" held)
  ITEM_KIND=$(show_field "$out" kind)
  ITEM_REPO=$(show_field "$out" repo)
  ITEM_PRIORITY=$(show_field "$out" priority)
  ITEM_BODY=$(show_field "$out" body)
}

# ordered_ids: ready ids by backlog priority (0 first, none last), stable.
ordered_ids() {
  local ids id n=0
  ids=$(ready_ids) || return 1
  for id in $ids; do
    n=$((n + 1))
    item_show "$id" || ITEM_PRIORITY=''
    case "$ITEM_PRIORITY" in [0-9]) ;; *) ITEM_PRIORITY=9 ;; esac
    printf '%s %06d %s\n' "$ITEM_PRIORITY" "$n" "$id"
  done | sort -k1,1n -k2,2n | awk '{print $3}'
}

# prep_doc <id>: prints the item's prep file (home-relative), or returns 1.
# Needs item_show first for the body.
prep_doc() {
  local id=$1 p abs
  [ -s "$DATA/$id/prep.md" ] && { printf 'data/%s/prep.md\n' "$id"; return 0; }
  for p in $(printf '%s\n' "$ITEM_BODY" | grep -oE '(/[A-Za-z0-9_.-]+)*/data/[A-Za-z0-9_./-]+\.md|data/[A-Za-z0-9_./-]+\.md'); do
    printf '%s\n' "$p" | grep -Eqi 'prep|plan|spec' || continue
    case "$p" in
      /*) abs=$p ;;
      *) abs="$DATA/${p#data/}" ;;
    esac
    [ -f "$abs" ] && [ -s "$abs" ] || continue
    printf '%s\n' "$p"
    return 0
  done
  return 1
}

# brief_line <id> <sed-expression>: the first match from the item's brief.
brief_line() {
  sed -n "$2" "$DATA/$1/brief.md" 2>/dev/null | head -1
}

# prep_read <id>: derives P_* (see PREP above) or sets PREP_ERR and returns 1.
# Needs item_show first.
prep_read() {
  local id=$1 file key value line reg o_project='' o_kind='' o_mode='' o_yolo='' o_bp='' o_bp_set=0 o_base='' o_consent=''
  local b_mode b_consent b_branch b_base
  P_PROJECT='' P_KIND='' P_MODE='' P_YOLO='' P_BRANCH_PREFIX='' P_BASE_BRANCH='' P_CONSENT='' PREP_ERR=''
  if [ ! -f "$DATA/$id/brief.md" ] || [ ! -s "$DATA/$id/brief.md" ]; then
    PREP_ERR="no brief data/$id/brief.md"; return 1
  fi
  prep_doc "$id" >/dev/null || {
    PREP_ERR="no prep file (data/$id/prep.md or a prep, plan or spec document linked from the item)"; return 1
  }
  file="$DATA/$id/autolaunch-prep"
  if [ -e "$file" ]; then
    [ -f "$file" ] && [ -r "$file" ] || { PREP_ERR="unreadable record data/$id/autolaunch-prep"; return 1; }
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ''|'#'*) continue ;; esac
      case "$line" in *=*) ;; *) PREP_ERR="record line without key=value: $line"; return 1 ;; esac
      key=${line%%=*} value=${line#*=}
      case "$key" in
        project) o_project=$value ;;
        kind) o_kind=$value ;;
        mode) o_mode=$value ;;
        yolo) o_yolo=$value ;;
        branch_prefix) o_bp=$value o_bp_set=1 ;;
        base_branch) o_base=$value ;;
        upstream_consent) o_consent=$value ;;
        *) PREP_ERR="record has unknown key $key"; return 1 ;;
      esac
    done < "$file"
  fi
  P_KIND=${o_kind:-$ITEM_KIND}
  P_PROJECT=${o_project:-$ITEM_REPO}
  case "$P_KIND" in
    ship|scout) ;;
    '') PREP_ERR="no kind on the backlog row"; return 1 ;;
    *) PREP_ERR="kind $P_KIND is not ship or scout"; return 1 ;;
  esac
  case "$P_PROJECT" in
    '') PREP_ERR="no repo on the backlog row"; return 1 ;;
    .|..|*/*) PREP_ERR="project $P_PROJECT is not a plain name"; return 1 ;;
  esac
  [ -d "$FM_HOME/projects/$P_PROJECT" ] || { PREP_ERR="no project clone projects/$P_PROJECT"; return 1; }
  b_base=$(brief_line "$id" 's/^Base branch: \([^[:space:]]*\).*/\1/p')
  P_BASE_BRANCH=${o_base:-$b_base}
  if [ "$P_KIND" = scout ]; then
    [ -z "$o_mode$o_yolo$o_consent" ] && [ "$o_bp_set" = 0 ] || { PREP_ERR="scout record carries ship-only keys"; return 1; }
    return 0
  fi
  b_mode=$(brief_line "$id" 's/^Delivery contract: mode=\([^[:space:]]*\).*/\1/p')
  b_consent=$(brief_line "$id" 's/^Delivery contract: mode=.*[[:space:]]upstream-consent=\([^[:space:]]*\).*/\1/p')
  b_branch=$(brief_line "$id" 's/^Ship branch: \([^[:space:]]*\).*/\1/p')
  reg=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" "$P_PROJECT" 2>/dev/null) || reg=''
  P_MODE=${o_mode:-${b_mode:-${reg%% *}}}
  P_YOLO=${o_yolo:-${reg#* }}
  if [ "$o_bp_set" = 1 ]; then
    P_BRANCH_PREFIX=$o_bp
  elif [ -n "$b_branch" ] && [ "${b_branch%"$id"}" != "$b_branch" ]; then
    P_BRANCH_PREFIX=${b_branch%"$id"}
  else
    P_BRANCH_PREFIX=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --branch-prefix "$P_PROJECT" 2>/dev/null) || P_BRANCH_PREFIX=fm/
  fi
  P_CONSENT=${o_consent:-$b_consent}
  case "$P_MODE" in no-mistakes|direct-PR|local-only) ;; *) PREP_ERR="no delivery mode for ship (brief, record or project registry)"; return 1 ;; esac
  case "$P_YOLO" in on|off) ;; *) PREP_ERR="no yolo posture for ship (record or project registry)"; return 1 ;; esac
}

# prep_record: the derived record as key=value lines.
prep_record() {
  printf 'project=%s\nkind=%s\n' "$P_PROJECT" "$P_KIND"
  if [ "$P_KIND" = ship ]; then
    printf 'mode=%s\nyolo=%s\nbranch_prefix=%s\n' "$P_MODE" "$P_YOLO" "$P_BRANCH_PREFIX"
    [ -z "$P_CONSENT" ] || printf 'upstream_consent=%s\n' "$P_CONSENT"
  fi
  [ -z "$P_BASE_BRANCH" ] || printf 'base_branch=%s\n' "$P_BASE_BRANCH"
}

deferred_pending() {
  local f
  for f in "$STATE/spawn-deferred/queue"/*; do
    [ -f "$f" ] || continue
    grep -qxF "task=$1" "$f" 2>/dev/null && return 0
  done
  return 1
}

# check_item <id>: 0 when launchable; else CHECK_ERR holds the refusal.
check_item() {
  local id=$1
  CHECK_ERR=
  item_show "$id" || { CHECK_ERR="not prepared: backlog show failed"; return 1; }
  [ "$ITEM_HELD" != yes ] || { CHECK_ERR=held; return 1; }
  prep_read "$id" || { CHECK_ERR="not prepared: $PREP_ERR"; return 1; }
  ! deferred_pending "$id" || { CHECK_ERR="spawn deferred pending"; return 1; }
}

# default_candidates <kind> <backend>: ranked default profiles as TSV
# harness, model, effort; DEFAULT_REFUSAL names a refused default.
default_candidates() {
  local kind=$1 backend=$2 defaults all snap resolved='[]' eligible='[]' p r h
  DEFAULT_REFUSAL=
  defaults=$(jq -c '
    def profiles($v): if ($v | type) == "array" then $v elif ($v | type) == "object" then [$v] else [] end;
    profiles(.default // null) | map(select(type == "object" and (.harness | type) == "string"))' "$RULES" 2>/dev/null) || defaults='[]'
  [ "$defaults" != '[]' ] || return 0
  all=$defaults
  while IFS= read -r p; do
    h=$(jq -r '.harness' <<<"$p")
    if [ "$h" = kimi ] || { [ "$h" = codex ] && [ "${FM_CODEX_TYPED_LAUNCH:-0}" = 1 ]; }; then
      fm_backend_visible_capture_supported "$backend" || continue
    fi
    fm_exclude_tools_check "$h" 0 "$CONFIG" >/dev/null 2>&1 || continue
    fm_quota_gate_account_eligible "$h" "$(jq -r '.model // ""' <<<"$p")" "$CONFIG" '' >/dev/null 2>&1 || continue
    eligible=$(jq -c --argjson p "$p" '. + [$p]' <<<"$eligible")
  done < <(jq -c --arg kind "$kind" --arg backend "$backend" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$FM_QUOTA_GATE_JQ"'.[] | select(quota_gate_launch_eligible($kind; $backend; false))' <<<"$defaults")
  defaults=$eligible
  snap="$TMPD/quota.json"
  if ! fm_quota_gate_snapshot "$snap" >/dev/null 2>&1; then
    # Unmeasurable quota is disclosed uncertainty: declared order, and
    # fm-spawn.sh's own gate prints its notice.
    jq -r '.[] | [.harness, (.model // ""), (.effort // "")] | @tsv' <<<"$defaults"
    return 0
  fi
  while IFS= read -r p; do
    r=$(fm_quota_gate_profile "$p" "$snap" "$all") || continue
    resolved=$(jq -c --argjson r "$r" '. + [$r]' <<<"$resolved")
  done < <(jq -c '.[]' <<<"$defaults")
  FM_QUOTA_GATE_HORIZON_SECONDS=$FM_QUOTA_GATE_HORIZON_SECONDS jq -r -n \
    --slurpfile quota "$snap" --argjson cands "$resolved" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$FM_QUOTA_GATE_JQ"'
    ($quota[0]) as $q | now as $now |
    [$cands[] | quota_gate_verdict($q; .; $now)] as $v |
    ([$v[] | select(.verdict == "pass" and (.spendPriority | type) == "number")] | sort_by(-.spendPriority))
    + [$v[] | select(.verdict == "notice" or (.verdict == "pass" and (.spendPriority | type) != "number"))]
    | (.[] | "cand\t\(.profile.harness)\t\(.profile.model // "")\t\(.profile.effort // "")"),
      ([$v[] | select(.verdict == "refuse")] | first | select(. != null)
       | "refused\t\(.profile.harness):\(.profile.model // "-") \(.reason // "refused")")' 2>/dev/null \
    > "$TMPD/defaults.tsv" || return 0
  DEFAULT_REFUSAL=$(sed -n 's/^refused\t//p' "$TMPD/defaults.tsv" | head -1)
  sed -n 's/^cand\t//p' "$TMPD/defaults.tsv"
}

# dispatch_candidates <kind>: writes candidates to $TMPD/cands.tsv
# (harness, model, effort; an empty harness means fm-spawn's static default);
# returns 1 with DISPATCH_ERR set when there is none.
dispatch_candidates() {
  local kind=$1 backend
  DISPATCH_ERR=
  if [ ! -f "$RULES" ]; then
    printf '\t\t\n' > "$TMPD/cands.tsv"
    return 0
  fi
  backend=$(FM_BACKEND_CONFIG_DIR="$CONFIG" fm_backend_name 2>/dev/null) || backend=tmux
  default_candidates "$kind" "$backend" > "$TMPD/cands.tsv"
  [ -s "$TMPD/cands.tsv" ] && return 0
  if [ -n "$DEFAULT_REFUSAL" ] || jq -e '(.default // null) != null' "$RULES" >/dev/null 2>&1; then
    DISPATCH_ERR="quota: ${DEFAULT_REFUSAL:-every default profile is ineligible, exhausted or short of runway}"
  else
    DISPATCH_ERR="dispatch: no configured default"
  fi
  return 1
}

# spawn_argv <id> <harness> <model> <effort>: fills SPAWN_ARGV.
spawn_argv() {
  SPAWN_ARGV=("$1" "$FM_HOME/projects/$P_PROJECT")
  if [ "$P_KIND" = scout ]; then
    SPAWN_ARGV+=(--scout)
  else
    SPAWN_ARGV+=(--mode "$P_MODE" --yolo "$P_YOLO" --branch-prefix "$P_BRANCH_PREFIX")
    [ -z "$P_CONSENT" ] || SPAWN_ARGV+=(--upstream-consent "$P_CONSENT")
  fi
  [ -z "$P_BASE_BRANCH" ] || SPAWN_ARGV+=(--base-branch "$P_BASE_BRANCH")
  [ -z "$2" ] || SPAWN_ARGV+=(--harness "$2")
  [ -z "$3" ] || SPAWN_ARGV+=(--model "$3")
  [ -z "$4" ] || SPAWN_ARGV+=(--effort "$4")
}

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-autolaunch.XXXXXX") || exit 1

if [ "$ACTION" = backfill ]; then
  ids=$(queued_ids) || exit 1
  for id in $ids; do
    if [ -e "$DATA/$id/autolaunch-prep" ]; then
      printf 'kept: %s (data/%s/autolaunch-prep exists)\n' "$id" "$id"
      continue
    fi
    item_show "$id" || { printf 'skip: %s: backlog show failed\n' "$id"; continue; }
    prep_read "$id" || { printf 'skip: %s: %s\n' "$id" "$PREP_ERR"; continue; }
    rec=$(prep_record | tr '\n' ' ')
    if [ "$APPLY" = 0 ]; then
      printf 'would-write: data/%s/autolaunch-prep: %s\n' "$id" "${rec% }"
      continue
    fi
    tmp=$(mktemp "$DATA/$id/.autolaunch-prep.XXXXXX") || exit 1
    if ! prep_record > "$tmp" || ! mv -f -- "$tmp" "$DATA/$id/autolaunch-prep"; then
      rm -f -- "$tmp"; exit 1
    fi
    printf 'wrote: data/%s/autolaunch-prep: %s\n' "$id" "${rec% }"
  done
  exit 0
fi

if [ "$ACTION" = list ]; then
  ids=$(ordered_ids) || exit 1
  for id in $ids; do
    check_item "$id" && printf '%s\n' "$id"
  done
  exit 0
fi

[ -d "$STATE" ] || { echo "fm-autolaunch: state directory $STATE is unavailable" >&2; exit 1; }
if [ "$ACTION" = run ]; then
  if ! fm_lock_try_acquire "$LOCK"; then
    echo "fm-autolaunch: another pass holds $LOCK${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}; nothing done" >&2
    exit 0
  fi
  LOCK_HELD=1
  exec 9>> "$LOG" || { echo "fm-autolaunch: cannot append to $LOG" >&2; exit 1; }
fi

capacity_read || true
if [ "$CAP_FREE" -eq 0 ]; then
  record - - - "refused:no capacity: $CAP_REASON"
  exit 0
fi
FREE=$CAP_FREE
if ! ids=$(ordered_ids 2>"$TMPD/ready.err"); then
  record - - - "refused:$(head -1 "$TMPD/ready.err")"
  exit 1
fi

LANE=1
STOP=0
for id in $ids; do
  [ "$LANE" -le "$FREE" ] || break
  if ! check_item "$id"; then
    record "$LANE" "$id" - "refused:$CHECK_ERR"
    continue
  fi
  if ! dispatch_candidates "$P_KIND"; then
    record "$LANE" "$id" - "refused:$DISPATCH_ERR"
    continue
  fi
  outcome='' quota_reason='' model=-
  while IFS= read -r line; do
    h=${line%%$'\t'*} line=${line#*$'\t'}
    m=${line%%$'\t'*} e=${line#*$'\t'}
    model=${h:-static}${m:+:$m}
    spawn_argv "$id" "$h" "$m" "$e"
    if [ "$ACTION" = dry ]; then
      printf 'would-run: %s' "$(printf '%q' "$SPAWN_BIN")"
      printf ' %q' "${SPAWN_ARGV[@]}"
      printf '\n'
      outcome="launched"
      break
    fi
    rc=0
    "$SPAWN_BIN" "${SPAWN_ARGV[@]}" > "$TMPD/spawn.out" 2>&1 < /dev/null || rc=$?
    if [ "$rc" = 0 ]; then
      outcome=launched
      break
    fi
    if [ "$rc" = 1 ] && grep -q 'refuses explicit harness' "$TMPD/spawn.out"; then
      quota_reason=$(grep -m1 'refuses explicit harness' "$TMPD/spawn.out")
      continue
    fi
    if [ "$rc" = 75 ]; then
      outcome="refused:deferred: $(grep -m1 -E '^(deferred|error):' "$TMPD/spawn.out" || tail -1 "$TMPD/spawn.out")"
    else
      outcome="refused:spawn error: $(grep -m1 '^error:' "$TMPD/spawn.out" || tail -1 "$TMPD/spawn.out") (exit $rc)"
    fi
    break
  done < "$TMPD/cands.tsv"
  [ -n "$outcome" ] || outcome="refused:quota: ${quota_reason:-no candidate profile launched}"
  record "$LANE" "$id" "$model" "$outcome"
  case "$outcome" in
    launched)
      LANE=$((LANE + 1))
      if [ "$ACTION" = run ]; then
        capacity_read || true
        FREE=$((LANE - 1 + CAP_FREE))
      fi
      ;;
    refused:deferred:*)
      capacity_read || true
      [ "$CAP_FREE" -gt 0 ] || { STOP=1; break; }
      ;;
  esac
done
if [ "$STOP" = 0 ] && [ "$LANE" -le "$FREE" ]; then
  record "$LANE" - - "refused:no prepared item"
fi
exit 0
