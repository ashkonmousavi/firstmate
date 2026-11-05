#!/usr/bin/env bash
# fm-autolaunch.sh - fill free machine lanes from this home's prepared backlog,
# with no model in the loop, and keep one record per decision.
#
# Usage:
#   fm-autolaunch.sh                 one pass: launch or refuse, one record each
#   fm-autolaunch.sh --steps-only [--dry-run]  leased slice transitions only
#   fm-autolaunch.sh --dry-run       print a decision for every ready item and the
#                                    spawn commands; write nothing
#   fm-autolaunch.sh --list-prepared print, in launch order, the ids a pass would try
#   fm-autolaunch.sh --print-timer [--steps-only]
#                                    print a timer and cron line with this PATH
#   fm-autolaunch.sh --backfill [--apply]
#                                    print (default) or write the derived launch
#                                    record for every queued item lacking one
#   fm-autolaunch.sh --explain        prepared entries and current wait reasons
#   fm-autolaunch.sh --help
#
# Timer proposals capture the caller's PATH and resolved FM_HOME for both
# systemd and cron; --steps-only limits the proposed pass to slice progression.
# Printing installs nothing and does not run a launch pass.
#
# A plain scheduler (cron or a systemd user timer, see --print-timer) runs one
# pass every five minutes with FM_HOME set explicitly. Nothing here enables a
# schedule; docs/configuration.md "Auto-launch" owns enabling it per machine.
# The pass never rides the watcher's check sweep, whose 30 s bound a spawn does
# not fit; only the companion throttle check bin/fm-autolaunch-check.sh does.
#
# CONTROLLER. CUT1 selects the bounded controller with config/autolaunch-sole
# or an existing state/autolaunch-controller journal. A verified user manager
# is required; a missing manager never falls back with durable controller work.
# Without activation evidence the legacy path preserves leased slice progress.
# The explicit fake-clock seam selects the controller in isolated tests only.
# Controller planning holds .autolaunch.lock under PATH-resolved GNU timeout
# -k 5 20. Busy or killed plans still run non-seat delivery reconciliation;
# action units run separately, with non-inherited per-key slot descriptors.
# bin/fm-autolaunch-steps.py Controller owns journal, deadlines and ladder.
# This cut does not change the timer recipe or install/enable any service.
#
# LEGACY PASS (before controller activation).
#   1. Single instance: state/.autolaunch.lock (fm_lock_try_acquire). A busy
#      lock exits 0 with one stderr notice and no record; a holder stuck for
#      ten minutes is exactly what the throttle check turns red.
#      Leased slice transitions run under this lock before the ready queue;
#      --steps-only stops after them. bin/fm-autolaunch-steps.py owns their
#      inputs, receipts, reconciliation and forge/pipeline evidence reads.
#   2. Capacity: bin/fm-capacity.sh --admit, the machine admission owner. A
#      refusal or zero free lanes is one `refused:no capacity: <reason>`
#      record and the pass ends. Nothing here relaxes or re-derives admission;
#      fm-spawn.sh re-checks machine and project capacity at launch.
#   3. Candidates: `bin/fm-tasks-axi.sh ready`, which already excludes held
#      (including parked) and blocked work, and treats a blocked-by edge whose
#      target is Done, archived, or absent as cleared. Items run in the order
#      it returns them.
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
#        refused:step-receipt-required  a step-owned child stays with its receipt
#        refused:same-or-unknown-tester-model  tester model admission failed
#        refused:quota: <reason>       every candidate profile is exhausted or
#                                      short of runway under quota enforcement
#        refused:deferred: <line>      fm-spawn.sh exit 75 (machine or project
#                                      capacity, project lock); the pass ends
#                                      when the machine has no lane left
#        refused:spawn error: <line>   any other fm-spawn.sh failure
#      A launch is one `launched` record, after which capacity is read again.
#      When candidates run out with a lane still open, one
#      `refused:no prepared item` record names the first open lane.
#
# PREP. An item is prepared when it has a brief, data/<id>/brief.md (delivered
# by fm-spawn.sh unchanged), and a non-empty prep file: data/<id>/prep.md, or
# the file named by a `Prep: data/<path>` line of the item's backlog body, a
# relative path inside this home's data/ directory with no `..` part. Without
# either it is refused with that exact reason.
# X (NOT_Q) ship preps require filled PERSONA, DOCTOR and XAI-SURFACE lines. Small fixes
# may name PERSONA inline in SLICE or PROOF. A no-Doctor-change declaration
# needs its reason, as does XAI-SURFACE: none. Prep files last written before
# 2026-11-03T08:00:00Z (Pacific
# midnight on the introduction date) retain
# dated grace until revised; task filing dates and prose dates grant no grace.
# Filled PERSONA values use semicolon-separated declarations, for example
# surfaces=pages,chat; usage=beginner,experienced,middle (the covered subsets).
# Allowed surface tokens are pages, chat, none; usage tokens are beginner,
# experienced, middle, none. Comma-separated tokens have no intervening spaces;
# unsupported suffixes refuse, and none must stand alone in either declaration.
# Page+chat outcomes require beginner/XAI-first and experienced/pages-only;
# middle switches on the same task. usage=none is valid only with surfaces=none.
# Scouts and other projects keep their existing preparation contract.
# Its launch record is then DERIVED, field by field, from the
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
# bin/fm-brief.sh writes one for each ship or scout brief it scaffolds, and --backfill writes
# the derived record for existing items; neither writes yolo, which stays
# derived from the registry at launch:
# without --apply it prints `would-write:`, `kept:` (a record already exists,
# never rewritten) and `skip: <id>: <reason>` lines and changes nothing, so a
# rerun is idempotent. Only a kind of ship or scout launches. The values become
# fm-spawn.sh flags as written; fm-spawn.sh validates them against the brief
# and refuses any disagreement, which is recorded.
#
# DISPATCH. No model inference selects a profile. The configured `default` profile(s) of
# config/crew-dispatch.json are tried deterministically: passing ones by
# highest known spendPriority, then uncertain ones in declared order, through
# fm-quota-axi-lib.sh's gate verdict over one quota-axi snapshot. Exhausted or
# short-runway profiles are excluded unless config/quota-gate=rank-only.
# Under rank-only, numeric refused profiles join numeric passes by descending
# spendPriority, using the minimum across their applicable bounds; notices
# remain uncertain in declared order even with a numeric spendPriority.
# Admitted profiles without a numeric priority also follow in declared order.
# With no config/crew-dispatch.json,
# use fm-spawn.sh's static crew harness.
# With shared_quota=true, eligible defaults retain declared order without
# requesting a quota snapshot or applying quota ranking.
# A spawn whose own quota gate refuses moves to the next candidate.
#
# RECORDS. Ready-queue decisions in state/autolaunch.log, append-only:
#   <UTC time>\t<lane>\t<item>\t<model>\t<result>
# lane is the 1-based free-lane ordinal of this pass, or - with no lane; item
# and model are - when not applicable; model is <harness>[:<model>] or static.
# Tabs and line breaks inside a reason become spaces. Each record is also
# printed on stdout. --dry-run prints `would-record:` lines and `would-run:`
# spawn commands, takes no lock, writes no file and spawns nothing; it still
# reads quota so its decisions match a real pass, and assumes each would-be
# launch uses one lane. Unlike a pass it evaluates every ready item, even with
# no free lane: a prepared item beyond the free lanes is recorded with lane -
# and result `would-launch-when-a-lane-frees`, with its would-run command.
# Step-effect witnesses in the same log use the engine header's format.
#
# Exit: 0 after a pass (refusals included) or a busy lock; 1 when the backlog
# or its log cannot be read or written; 2 usage.
# Test seams, honored only with FM_TEST_SEAM=1: FM_AUTOLAUNCH_CAPACITY_BIN,
# FM_AUTOLAUNCH_SPAWN_BIN replace fm-capacity.sh and fm-spawn.sh.
# FM_AUTOLAUNCH_NOW_FILE selects a dynamic controller clock and
# FM_AUTOLAUNCH_SEND_BIN replaces responder sends (both test-only).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
export FM_HOME

usage() { echo 'usage: fm-autolaunch.sh [--steps-only [--dry-run]|--dry-run|--list-prepared|--print-timer [--steps-only]|--backfill [--apply]|--explain|--help]' >&2; }

ACTION=run
STEP_TARGET=
STEP_EXCLUDE=
STEP_FAMILY=
STEP_DRY=0
TIMER_STEPS=0
case "${1:-}" in
  -h|--help) sed -n '2,/^set -u/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  --run-action) ACTION=controller-action; STEP_TARGET=${2:-} ;;
  --controller-plan) ACTION=controller-plan ;;
  --controller-remote-inbox) ACTION=controller-remote-inbox; STEP_TARGET=${2:-} ;;
  --controller-decisions) ACTION=controller-decisions ;;
  --controller-spawn-lock) ACTION=controller-spawn-lock; STEP_TARGET=${2:-} ;;
  --controller-inbox-due) ACTION=controller-inbox-due; STEP_TARGET=${2:-} ;;
  --controller-spawn-result) ACTION=controller-spawn-result; STEP_TARGET=${2:-}; STEP_EXCLUDE=${3:-} ;;
  --controller-ring) ACTION=controller-ring; STEP_TARGET=${2:-}; STEP_EXCLUDE=${3:-}; STEP_FAMILY=${4:-} ;;
  --explain) ACTION=explain ;;
  --dry-run) ACTION=dry ;;
  --steps-only) ACTION=steps ;;
  --step-dispatch) ACTION="step-dispatch"; STEP_TARGET=${2:-}; STEP_EXCLUDE=${3:-}; STEP_FAMILY=${4:-}; STEP_ACTION_ID=${5:-} ;;
  --step-family) ACTION="step-family"; STEP_TARGET=${2:-}; STEP_EXCLUDE=${3:-} ;;
  --step-agent) ACTION="step-agent"; STEP_TARGET=${2:-} ;;
  --step-nm) ACTION="step-nm"; STEP_TARGET=${2:-} ;;
  --step-accept) ACTION="step-accept"; STEP_TARGET=${2:-}; STEP_EXCLUDE=${3:-} ;;
  --list-prepared) ACTION=list ;;
  --print-timer) ACTION=timer ;;
  --backfill) ACTION=backfill ;;
  *) usage; exit 2 ;;
esac
APPLY=0
if [ "$ACTION" = timer ] && [ "${2:-}" = --steps-only ] && [ "$#" -eq 2 ]; then
  TIMER_STEPS=1
elif [ "$ACTION" = steps ] && [ "${2:-}" = --dry-run ] && [ "$#" -eq 2 ]; then
  STEP_DRY=1
elif [ "$ACTION" = controller-ring ] && [ "$#" -eq 4 ] && { [ "$STEP_FAMILY" = ring ] || [ "$STEP_FAMILY" = retry ]; }; then
  :
elif [ "$ACTION" = controller-spawn-result ] && [ "$#" -eq 3 ]; then
  :
elif [ "$ACTION" = controller-remote-inbox ] && [ "$#" -eq 2 ] && { [ "$STEP_TARGET" = due ] || [ "$STEP_TARGET" = run ]; }; then
  :
elif { [ "$ACTION" = controller-action ] || [ "$ACTION" = controller-spawn-lock ] || [ "$ACTION" = controller-inbox-due ]; } && [ "$#" -eq 2 ]; then
  :
elif [ "$ACTION" = step-dispatch ] && [ "$#" -eq 5 ]; then
  :
elif [ "$ACTION" = step-family ] && [ "$#" -eq 3 ]; then
  :
elif [ "$ACTION" = step-accept ] && [ "$#" -eq 3 ]; then
  :
elif { [ "$ACTION" = step-agent ] || [ "$ACTION" = step-nm ]; } && [ "$#" -eq 2 ]; then
  :
elif [ "$ACTION" = backfill ] && [ "${2:-}" = --apply ] && [ "$#" -eq 2 ]; then
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
  sd_env() { local v=${2//\\/\\\\}; v=${v//\"/\\\"}; printf 'Environment="%s=%s"\n' "$1" "${v//%/%%}"; }
  args=''
  [ "$TIMER_STEPS" = 0 ] || args=' --steps-only'
  cmd="PATH=$(printf '%q' "$PATH") FM_HOME=$(printf '%q' "$home") $(printf '%q' "$SCRIPT_DIR/fm-autolaunch.sh")$args"
  cmd=${cmd//%/\\%}
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
$(sd_env PATH "$PATH")
$(sd_env FM_HOME "$home")
ExecStart=$SCRIPT_DIR/fm-autolaunch.sh$args

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

# The engine owns validation; absence is an early, byte-for-byte quiet no-op.
if [ "$ACTION" = steps ] && [ ! -f "$CONFIG/autolaunch-steps" ]; then
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
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

flat() { printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-300; }

TMPD=
LOCK_HELD=0
PASS_LOCK_OWNER=
STEP_ACCEPT_LOCK=
# shellcheck disable=SC2329 # Invoked through the EXIT trap below.
cleanup() {
  [ -z "$STEP_ACCEPT_LOCK" ] || fm_lock_release "$STEP_ACCEPT_LOCK"
  [ -z "$TMPD" ] || rm -rf -- "$TMPD"
  [ "$LOCK_HELD" = 0 ] || pass_lock_release
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

# item_show <id>: sets ITEM_HELD, ITEM_KIND, ITEM_REPO,
# ITEM_BODY from `show --full`.
item_show() {
  local out
  ITEM_HELD='' ITEM_KIND='' ITEM_REPO='' ITEM_BODY=''
  out=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$1" --full 2>/dev/null) || return 1
  ITEM_HELD=$(show_field "$out" held)
  ITEM_KIND=$(show_field "$out" kind)
  ITEM_REPO=$(show_field "$out" repo)
  ITEM_BODY=$(show_field "$out" body)
}

# prep_doc <id>: prints the item's prep file (home-relative), or returns 1.
# Needs item_show first for the body.
prep_doc() {
  local id=$1 p
  [ -s "$DATA/$id/prep.md" ] && { printf 'data/%s/prep.md\n' "$id"; return 0; }
  while IFS= read -r p; do
    case "/$p/" in */../*) continue ;; esac
    [ -f "$DATA/${p#data/}" ] && [ -s "$DATA/${p#data/}" ] || continue
    printf '%s\n' "$p"
    return 0
  done < <(printf '%s\n' "$ITEM_BODY" | awk '{ gsub(/\\n/, "\n"); print }' |
    sed -n 's|^[[:space:]]*Prep: \(data/[^[:space:]]*[^[:space:]/]\).*|\1|p')
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
  local b_mode b_consent b_branch b_base prep_path
  P_PROJECT='' P_KIND='' P_MODE='' P_YOLO='' P_BRANCH_PREFIX='' P_BASE_BRANCH='' P_CONSENT='' PREP_ERR=''
  if [ ! -f "$DATA/$id/brief.md" ] || [ ! -s "$DATA/$id/brief.md" ]; then
    PREP_ERR="no brief data/$id/brief.md"; return 1
  fi
  prep_path=$(prep_doc "$id") || {
    PREP_ERR="no prep file (data/$id/prep.md or a Prep: data/<path> line in the item)"; return 1
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
  if [ "$P_PROJECT" = NOT_Q ]; then
    PREP_ERR=$(python3 - "$DATA/${prep_path#data/}" <<'PY'
import datetime as dt
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
try:
    # Fixed introduction date, not a rolling age exemption.
    cutoff = dt.datetime(2026, 11, 3, 8, tzinfo=dt.timezone.utc).timestamp()
    text = path.read_text(encoding="utf-8")
    if path.stat().st_mtime < cutoff:
        raise SystemExit(0)
except (OSError, UnicodeError):
    print("unreadable X prep")
    raise SystemExit(1)

values = {}
fence = None
for line in text.splitlines():
    line = line.strip()
    # Hex keeps Bash 3.2 from parsing backticks inside this heredoc.
    if line.startswith(("\x60" * 3, "~~~")):
        marker = line[:3]
        fence = None if fence == marker else marker if fence is None else fence
        continue
    if fence:
        continue
    # Accept ordinary Markdown field labels, without treating prose as a field.
    line = re.sub(r"^[-*+] +", "", line).replace("**", "")
    field = re.match(r"(PERSONA|DOCTOR|XAI-SURFACE|SLICE|PROOF)[ \t]*:[ \t]*(.*)$", line, re.I)
    if not field:
        continue
    key, value = field[1].upper(), field[2].strip()
    if key in ("SLICE", "PROOF"):
        field = re.search(r"(?:^|[;|])[ \t]*PERSONA[ \t]*:[ \t]*(\S.*)", value, re.I)
        if field:
            values["PERSONA"] = field[1].strip()
    elif value:
        values[key] = value

persona = values.get("PERSONA", "")
if not persona or persona.lower() in ("none", "tbd", "todo") or persona.startswith("job/outcome;"):
    print("PERSONA missing or unfilled in X prep (small fix: name PERSONA in SLICE/proof)")
    raise SystemExit(1)
declarations = {}
for key, allowed in (("surfaces", {"pages", "chat", "none"}), ("usage", {"beginner", "experienced", "middle", "none"})):
    match = re.search(r"\b" + key + r"[ \t]*=[ \t]*([^;]*)", persona, re.I)
    valueset = set(match[1].strip().lower().split(",")) if match else set()
    if not valueset or not valueset <= allowed or ("none" in valueset and len(valueset) != 1):
        print("PERSONA " + key + " missing or invalid (declare surfaces=pages,chat and usage=beginner,experienced as applicable)")
        raise SystemExit(1)
    declarations[key] = valueset
if declarations["usage"] == {"none"} and declarations["surfaces"] != {"none"}:
    print("PERSONA usage=none requires surfaces=none")
    raise SystemExit(1)
if declarations["surfaces"] == {"pages", "chat"} and not {"beginner", "experienced"} <= declarations["usage"]:
    print("PERSONA page-and-chat coverage needs beginner (XAI-first) and experienced (pages-only)")
    raise SystemExit(1)
doctor = values.get("DOCTOR", "")
if not doctor or doctor.lower() in ("none", "tbd", "todo"):
    print("DOCTOR missing or unfilled in X prep (name the check or no Doctor change with reason)")
    raise SystemExit(1)
if doctor.lower().startswith("no doctor change"):
    reason = doctor[len("no Doctor change"):].lstrip(";,:. -")
    reason = re.sub(r"^because\b[ :]*", "", reason, flags=re.I).strip()
    if not reason or reason.lower() in ("none", "tbd", "todo"):
        print("DOCTOR no Doctor change needs a reason")
        raise SystemExit(1)
surface = values.get("XAI-SURFACE", "")
if not surface or surface.lower() in ("tbd", "todo"):
    print("XAI-SURFACE missing or unfilled in X prep (name changed surfaces or none with reason)")
    raise SystemExit(1)
if re.match(r"none\b", surface, re.I):
    reason = surface[len("none"):].lstrip(";,:. -")
    reason = re.sub(r"^because\b[ :]*", "", reason, flags=re.I).strip()
    if not reason or reason.lower() in ("none", "tbd", "todo"):
        print("XAI-SURFACE none needs a reason")
        raise SystemExit(1)
PY
    ) || return 1
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

# prep_record: the derived record as key=value lines, without yolo.
prep_record() {
  printf 'project=%s\nkind=%s\n' "$P_PROJECT" "$P_KIND"
  if [ "$P_KIND" = ship ]; then
    printf 'mode=%s\nbranch_prefix=%s\n' "$P_MODE" "$P_BRANCH_PREFIX"
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
# harness, model, effort; DEFAULT_REFUSAL names a refused default. The quota
# snapshot is taken on first need and QUOTA_SNAP (ok or failed) keeps its
# outcome for the rest of the pass.
QUOTA_SNAP=
default_candidates() {
  local kind=$1 backend=$2 defaults all snap resolved='[]' eligible='[]' p r h rank_only=false
  fm_quota_gate_rank_only "$CONFIG" && rank_only=true
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
  if jq -e '.shared_quota == true' "$RULES" >/dev/null 2>&1; then
    jq -r '.[] | [.harness, (.model // ""), (.effort // "")] | @tsv' <<<"$defaults"
    return 0
  fi
  snap="$TMPD/quota.json"
  if [ -z "$QUOTA_SNAP" ]; then
    QUOTA_SNAP=failed
    fm_quota_gate_snapshot "$snap" >/dev/null 2>&1 && QUOTA_SNAP=ok
  fi
  if [ "$QUOTA_SNAP" = failed ]; then
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
    --slurpfile quota "$snap" --argjson cands "$resolved" --argjson rank_only "$rank_only" \
    "$FM_QUOTA_ROW_JQ$FM_QUOTA_EVAL_JQ$FM_QUOTA_GATE_JQ"'
    ($quota[0]) as $q | now as $now |
    [$cands[] | quota_gate_verdict($q; .; $now)
     # Refused rows retain bounds but normally omit the ranking scalar.
     # Reuse the same limiting-bound minimum when enforcement is disabled.
     | if $rank_only and .verdict == "refuse" and ((.bounds // []) | length) > 0
          and all(.bounds[]; (.spendPriority | type) == "number")
       then . + {spendPriority: ([.bounds[].spendPriority] | min)} else . end] as $v |
    ([$v[] | select((.verdict == "pass" or ($rank_only and .verdict == "refuse")) and (.spendPriority | type) == "number")] | sort_by(-.spendPriority))
    + [$v[] | select(.verdict == "notice" or ((.verdict == "pass" or ($rank_only and .verdict == "refuse")) and (.spendPriority | type) != "number"))]
    | (.[] | "cand\t\(.profile.harness)\t\(.profile.model // "")\t\(.profile.effort // "")"),
      ([$v[] | select(.verdict == "refuse" and ($rank_only | not))] | first | select(. != null)
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

step_family() {
  local family
  family=$(jq -r --arg h "$1" --arg m "$2" '
    [.. | objects | select(.harness? == $h and (.model? // "") == $m) | .model_family? // empty] | unique |
    if length == 1 then .[0] elif length > 1 then "unknown" else empty end' "$RULES" 2>/dev/null) || family=
  if [ -n "$family" ]; then
    printf '%s\n' "$family"
  else
    case "$1" in
      claude|codex|grok|kimi) fm_quota_single_provider_for_harness "$1" || printf 'unknown\n' ;;
      *) printf 'unknown\n' ;;
    esac
  fi
}

spawn_quota_refused() {
  [ "$1" = 1 ] && grep -q 'refuses explicit harness' "${2:-$TMPD/spawn.out}"
}

# The generic lock library intentionally removes only its known files.
# K1 owns the additional at file, including its cleanup on dead-holder reclaim.
# Never remove that file from a live or freshly publishing owner.
pass_lock_try() {
  local steal="$LOCK.steal" steal_owner primary_owner pid
  if [ -f "$LOCK/at" ] && ! fm_lock_holder_alive "$LOCK" "$(cat "$LOCK/pid" 2>/dev/null || true)"; then
    if fm_lock_try_acquire_steal_mutex "$steal"; then
      steal_owner=${FM_LOCK_OWNER_DIR:-}
      primary_owner=''
      if [ -L "$LOCK" ]; then
        primary_owner=$(fm_lock_link_owner "$LOCK" 2>/dev/null || true)
      fi
      pid=$(cat "$LOCK/pid" 2>/dev/null || true)
      if fm_lock_points_to_owner "$steal" "$steal_owner" \
        && fm_lock_recheck_stale_owner "$LOCK" "$primary_owner" "$pid"; then
        rm -f -- "$LOCK/at"
      fi
      fm_lock_release "$steal"
    fi
  fi
  fm_lock_try_acquire "$LOCK" || return 1
  PASS_LOCK_OWNER=${FM_LOCK_OWNER_DIR:-}
}

pass_lock_release() {
  if [ -n "$PASS_LOCK_OWNER" ] && fm_lock_points_to_owner "$LOCK" "$PASS_LOCK_OWNER"; then
    rm -f -- "$LOCK/at"
  fi
  fm_lock_release "$LOCK"
  PASS_LOCK_OWNER=''
}

# Private K1 callbacks share the existing admission and inbox primitives.
controller_now() {
  if [ "${FM_TEST_SEAM:-}" = 1 ] && [ -n "${FM_AUTOLAUNCH_NOW_FILE:-}" ]; then
    local now
    now=$(cat "$FM_AUTOLAUNCH_NOW_FILE") || return 1
    case "$now" in ''|*[!0-9]*) echo 'invalid controller clock' >&2; return 1 ;; esac
    printf '%s\n' "$now"
  else
    date +%s
  fi
}

controller_enabled() {
  if [ "${FM_TEST_SEAM:-}" = 1 ]; then
    # Explicit fixture seam: existing synchronous fixtures stay independent of
    # whether the test host happens to run a user manager.
    if [ -n "${FM_AUTOLAUNCH_NOW_FILE:-}" ]; then
      controller_now >/dev/null || return 2
      return 0
    fi
  fi
  # CUT1 is dormant until the existing rollout marker is present. A journal
  # is continuity evidence: removing the marker must not replay live work via
  # the synchronous path. Later carrier/canary integration owns early entry.
  if [ ! -f "$CONFIG/autolaunch-sole" ] && [ ! -d "$STATE/autolaunch-controller" ]; then
    return 1
  fi
  local manager=''
  manager=$(fm_run_timed 3 systemctl --user show -p Version --value 2>/dev/null) || manager=''
  if [[ "$manager" =~ ^[0-9]{3}([.[:alnum:]+~:_-]+)?([[:space:]]\(.*\))?$ ]]; then
    return 0
  fi
  echo 'fm-autolaunch: user service manager unavailable; controller obligations preserved' >&2
  return 2
}

if [ "${FM_TEST_SEAM:-}" = 1 ] && [ "${FM_AUTOLAUNCH_INSPECT_SELECTION:-}" = 1 ]; then
  mode_rc=0
  controller_enabled || mode_rc=$?
  case "$mode_rc" in 0) echo controller ;; 1) echo legacy ;; *) exit 1 ;; esac
  exit 0
fi

case "$ACTION" in
  controller-remote-inbox)
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-watch.sh"
    if [ "$STEP_TARGET" = due ]; then
      [ "$(age_of "$STATE/.remote-inbox-tick")" -ge "$(fm_task_inbox_grace_secs)" ]
      exit $?
    fi
    remote_inbox_tick
    exit $?
    ;;
  controller-decisions)
    # The existing fold owns the status grammar, terminal behavior, reserved
    # namespaces and close semantics. The controller only supplies age policy.
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    for status in "$STATE"/*.status; do
      [ -f "$status" ] && [ ! -L "$status" ] || continue
      task=${status##*/}; task=${task%.status}
      while IFS= read -r decision || [ -n "$decision" ]; do
        [ -n "$decision" ] || continue
        reserved=0
        for prefix in ${FM_CLASSIFY_RESERVED_KEY_PREFIXES:-$FM_CLASSIFY_RESERVED_KEY_PREFIXES_DEFAULT} remote-reply-continuity- captain-hold- ctl-; do
          case "$decision" in "$prefix"*) reserved=1; break ;; esac
        done
        [ "$reserved" = 0 ] || continue
        printf '%s\t%s\n' "$task" "$decision"
      done < <(status_open_decisions_incremental "$status" '' timed)
    done
    exit 0
    ;;
  controller-spawn-result)
    if spawn_quota_refused "$STEP_TARGET" "$STEP_EXCLUDE"; then
      printf 'quota\n'
    fi
    exit 0
    ;;
  controller-action)
    exec python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" controller-action "$SCRIPT_DIR/fm-autolaunch.sh" "$STEP_TARGET"
    ;;
  controller-plan)
    plan_owner=$(cat "$LOCK/pid" 2>/dev/null || true)
    [ -n "${FM_CONTROLLER_PLAN_OWNER:-}" ] && [ "$plan_owner" = "$FM_CONTROLLER_PLAN_OWNER" ] \
      && fm_lock_holder_alive "$LOCK" "$plan_owner" || exit 73
    python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" controller-plan "$SCRIPT_DIR/fm-autolaunch.sh"
    exit $?
    ;;
  controller-spawn-lock)
    fm_task_id_creation_valid "$STEP_TARGET" || exit 2
    if fm_lock_try_acquire "$STATE/.spawn-$STEP_TARGET.lock"; then
      fm_lock_release "$STATE/.spawn-$STEP_TARGET.lock"
    else
      printf '%s\n' "${FM_LOCK_HELD_PID:-}"
    fi
    exit 0
    ;;
  controller-inbox-due|controller-ring)
    fm_task_id_creation_valid "$STEP_TARGET" || exit 2
    # shellcheck source=bin/fm-task-inbox-lib.sh
    . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
    # shellcheck source=bin/fm-classify-lib.sh
    . "$SCRIPT_DIR/fm-classify-lib.sh"
    if [ "$ACTION" = controller-inbox-due ]; then
      due=$(fm_task_inbox_due_action "$STATE" "$STEP_TARGET") || exit $?
      if [ "${due%% *}" = retry ] && [ -n "$(status_own_open_decisions "$STATE/$STEP_TARGET.status")" ]; then
        printf quiet
      else
        printf '%s' "$due"
      fi
      exit 0
    fi
    if [ "$STEP_FAMILY" = retry ] && [ -n "$(status_own_open_decisions "$STATE/$STEP_TARGET.status")" ]; then
      exit 75
    fi
    meta="$STATE/$STEP_TARGET.meta"
    window=$(sed -n 's/^window=//p' "$meta" | head -1)
    backend=$(sed -n 's/^backend=//p' "$meta" | head -1)
    harness=$(sed -n 's/^harness=//p' "$meta" | head -1)
    ring_rc=0
    fm_task_inbox_ring "${backend:-tmux}" "$window" "$STEP_EXCLUDE" "fm-$STEP_TARGET" "$harness" || ring_rc=$?
    if [ "$STEP_FAMILY" = retry ]; then
      fm_task_inbox_clear_retry "$STATE" "$STEP_TARGET" "$STEP_EXCLUDE" || exit 1
      exit 0
    fi
    fm_task_inbox_record_ring "$STATE" "$STEP_TARGET" "$STEP_EXCLUDE" || exit 1
    exit "$ring_rc"
    ;;
  explain)
    ids=$(ready_ids) || exit 1
    for id in $ids; do
      if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
        printf '%s pass-lock-held\n' "$id"
      elif check_item "$id"; then
        printf '%s prepared\n' "$id"
      else
        printf '%s %s\n' "$id" "$CHECK_ERR"
      fi
    done
    exit 0
    ;;
esac

if [ "$ACTION" = step-family ]; then
  step_family "$STEP_TARGET" "$STEP_EXCLUDE"
  exit 0
fi
if [ "$ACTION" = step-accept ]; then
  fm_task_id_creation_valid "$STEP_TARGET" || exit 2
  accept_lock="$STATE/.control-$STEP_TARGET.lock"
  fm_lock_try_acquire "$accept_lock" || exit 75
  STEP_ACCEPT_LOCK=$accept_lock
  python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" accept-owner "$STEP_TARGET" "$STEP_EXCLUDE"
  exit $?
fi

# Private engine callbacks: these reuse the scheduler's preparation, admission,
# candidate selection and exact spawn argument path. They never acquire the
# pass lock: the invoking step engine already holds it.
if [ "$ACTION" = step-nm ]; then
  fm_task_id_creation_valid "$STEP_TARGET" || exit 2
  meta="$STATE/$STEP_TARGET.meta"
  [ -f "$meta" ] || exit 0
  # Use the shared identity-aware selector, including per-worktree NM_HOME.
  # A stale run on a different branch or code identity is never gate evidence.
  # shellcheck source=bin/fm-nm-run-lib.sh
  . "$SCRIPT_DIR/fm-nm-run-lib.sh"
  wt=$(fm_meta_get "$meta" worktree)
  branch=$(fm_meta_get "$meta" branch)
  [ -d "$wt" ] && [ -n "$branch" ] || exit 0
  overview=$(fm_nm_run_checked "$wt" 10 axi) || exit 0
  choice=$(fm_nm_select_run "$branch" "$overview" "$wt" 10)
  case "$choice" in selected\|*) ;; *) exit 0 ;; esac
  IFS='|' read -r _ run_id _ _ <<< "$choice"
  out=$(fm_nm_run_checked "$wt" 10 axi status --run "$run_id") || exit 0
  [ "$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")" = "$branch" ] || exit 0
  fm_nm_run_is_pipeline_owned_active "$out" \
    || fm_nm_head_matches_worktree "$wt" "$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")" || exit 0
  printf '%s\n' "$out"
  exit 0
fi
if [ "$ACTION" = step-agent ]; then
  fm_task_id_creation_valid "$STEP_TARGET" || exit 2
  meta="$STATE/$STEP_TARGET.meta"
  [ -f "$meta" ] || { echo missing; exit 0; }
  fm_backend_agent_state "$(fm_backend_of_meta "$meta")" "$(fm_backend_target_of_meta "$meta")"
  exit $?
fi
if [ "$ACTION" = step-dispatch ]; then
  fm_task_id_creation_valid "$STEP_TARGET" || exit 2
  [ -n "$STEP_ACTION_ID" ] || exit 2
  capacity_read || true
  [ "$CAP_FREE" -gt 0 ] || exit 75
  check_item "$STEP_TARGET" || { echo "refused:$CHECK_ERR" >&2; exit 1; }
  dispatch_candidates "$P_KIND" || { echo "refused:$DISPATCH_ERR" >&2; exit 1; }
  if [ -n "$STEP_EXCLUDE" ] && [ -n "$STEP_FAMILY" ] && [ "$STEP_FAMILY" != unknown ]; then
    : > "$TMPD/preferred.tsv"
    : > "$TMPD/remaining.tsv"
    while IFS= read -r line; do
      h=${line%%$'\t'*} rest=${line#*$'\t'} m=${rest%%$'\t'*}
      family=$(step_family "$h" "$m")
      if [ "$family" != unknown ] && [ "$family" != "$STEP_FAMILY" ]; then
        printf '%s\n' "$line" >> "$TMPD/preferred.tsv"
      else
        printf '%s\n' "$line" >> "$TMPD/remaining.tsv"
      fi
    done < "$TMPD/cands.tsv"
    cat "$TMPD/preferred.tsv" "$TMPD/remaining.tsv" > "$TMPD/cands.tsv"
  fi
  while IFS= read -r line; do
    h=${line%%$'\t'*} line=${line#*$'\t'}
    m=${line%%$'\t'*} e=${line#*$'\t'}
    python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" launch-admission "$STEP_TARGET" "$m" "$STEP_ACTION_ID" > "$TMPD/admission.out" || continue
    spawn_argv "$STEP_TARGET" "$h" "$m" "$e"
    rc=0
    FM_SPAWN_STEP_ACTION="$STEP_ACTION_ID" "$SPAWN_BIN" "${SPAWN_ARGV[@]}" > "$TMPD/spawn.out" 2>&1 < /dev/null || rc=$?
    if spawn_quota_refused "$rc"; then
      continue
    fi
    if [ "$rc" = 0 ]; then cat "$TMPD/spawn.out"; else cat "$TMPD/spawn.out" >&2; fi
    exit "$rc"
  done < "$TMPD/cands.tsv"
  echo 'refused: no different-model tester candidate' >&2
  exit 1
fi
if [ "$ACTION" = steps ]; then
  if [ "$STEP_DRY" = 1 ] || ! grep -Eq '^act[[:space:]]+[^[:space:]]' "$CONFIG/autolaunch-steps"; then
    python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" dry
    exit $?
  fi
  if ! pass_lock_try; then
    echo "fm-autolaunch: another pass holds $LOCK; nothing done" >&2
    exit 0
  fi
  LOCK_HELD=1
  python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" run
  exit $?
fi

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
  ids=$(ready_ids) || exit 1
  for id in $ids; do
    check_item "$id" && printf '%s\n' "$id"
  done
  exit 0
fi

[ -d "$STATE" ] || { echo "fm-autolaunch: state directory $STATE is unavailable" >&2; exit 1; }
if [ "$ACTION" = run ]; then
  controller_rc=0
  controller_enabled || controller_rc=$?
  [ "$controller_rc" != 2 ] || exit 1
  if [ "$controller_rc" = 0 ]; then
    plan_rc=0
    if pass_lock_try; then
      LOCK_HELD=1
      controller_now > "$LOCK/at" || exit 1
      # Only the planning child is timed. Its parent releases the shared
      # directory lock even when TERM/KILL ends that child.
      plan_timeout=$(type -P gnutimeout || type -P timeout) || exit 1
      FM_CONTROLLER_PLAN_OWNER="$BASHPID" "$plan_timeout" -k 5 20 bash "$SCRIPT_DIR/fm-autolaunch.sh" --controller-plan || plan_rc=$?
      pass_lock_release
      LOCK_HELD=0
    else
      echo "fm-autolaunch: another pass holds $LOCK${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}; seat claims wait" >&2
      plan_rc=73
    fi
    python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" controller-effects "$SCRIPT_DIR/fm-autolaunch.sh" "$plan_rc"
    exit $?
  fi
fi

if [ "$ACTION" = run ]; then
  if ! pass_lock_try; then
    echo "fm-autolaunch: another pass holds $LOCK${FM_LOCK_HELD_PID:+ (pid $FM_LOCK_HELD_PID)}; nothing done" >&2
    exit 0
  fi
  LOCK_HELD=1
  exec 9>> "$LOG" || { echo "fm-autolaunch: cannot append to $LOG" >&2; exit 1; }
fi

if [ "$ACTION" = run ] && [ -f "$CONFIG/autolaunch-steps" ]; then
  python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" run || exit $?
fi
capacity_read || true
FREE=$CAP_FREE
if [ "$FREE" -eq 0 ]; then
  record - - - "refused:no capacity: $CAP_REASON"
  [ "$ACTION" = dry ] || exit 0
fi
if ! ids=$(ready_ids 2>"$TMPD/ready.err"); then
  record - - - "refused:$(head -1 "$TMPD/ready.err")"
  exit 1
fi

LANE=1
STOP=0
for id in $ids; do
  slot=$LANE
  if [ "$LANE" -gt "$FREE" ]; then
    [ "$ACTION" = dry ] || break
    slot=-
  fi
  if ! check_item "$id"; then
    record "$slot" "$id" - "refused:$CHECK_ERR"
    continue
  fi
  if ! dispatch_candidates "$P_KIND"; then
    record "$slot" "$id" - "refused:$DISPATCH_ERR"
    continue
  fi
  outcome='' quota_reason='' model=-
  while IFS= read -r line; do
    h=${line%%$'\t'*} line=${line#*$'\t'}
    m=${line%%$'\t'*} e=${line#*$'\t'}
    model=${h:-static}${m:+:$m}
    if ! admission=$(python3 "$SCRIPT_DIR/fm-autolaunch-steps.py" launch-admission "$id" "$m" "" 2>&1); then
      outcome="refused:$admission"
      continue
    fi
    outcome=''
    spawn_argv "$id" "$h" "$m" "$e"
    if [ "$ACTION" = dry ]; then
      if [ "${FM_CONTROLLER_PREPARED:-}" = 1 ]; then
        python3 -c 'import json,sys; print("would-argv: " + json.dumps(sys.argv[1:]))' "$SPAWN_BIN" "${SPAWN_ARGV[@]}"
      else
        printf 'would-run: %s' "$(printf '%q' "$SPAWN_BIN")"
        printf ' %q' "${SPAWN_ARGV[@]}"
        printf '\n'
      fi
      outcome=launched
      [ "$slot" != - ] || outcome=would-launch-when-a-lane-frees
      break
    fi
    rc=0
    FM_SPAWN_STEP_ACTION='' "$SPAWN_BIN" "${SPAWN_ARGV[@]}" > "$TMPD/spawn.out" 2>&1 < /dev/null || rc=$?
    if [ "$rc" = 0 ]; then
      outcome=launched
      break
    fi
    if spawn_quota_refused "$rc"; then
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
  record "$slot" "$id" "$model" "$outcome"
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
