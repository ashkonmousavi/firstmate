#!/usr/bin/env bash
# fm-walk-request-check.sh - dispatch a mate's typed walk request through the
# home-private walker dispatcher, and return the outcome to the mate.
#
# Usage:
#   fm-walk-request-check.sh [check]
#   fm-walk-request-check.sh arm
#   fm-walk-request-check.sh disarm
#   fm-walk-request-check.sh --help
#
# THE OTHER HALF of the walk-request carrier (bin/fm-walk-request.sh owns the
# mate-side typed line). A secondmate with no access to the walker dispatcher
# writes one request on its parent channel; this standing check, armed in the
# home that owns the dispatcher (MAIN), reads those typed lines and acts:
#
#   1. discovery: every state/<mate-id>.status whose state/<mate-id>.meta
#      records kind=secondmate is scanned for the typed request format owned
#      by bin/fm-walk-request.sh, including its local-path alternative.
#      Accepted briefs are copied to data/walk-requests/<corr>/brief.md.
#      Both mate shapes land there: a local route appends into the parent
#      home directly and a remote route's reply adapter mirrors its channel
#      into the same file (bin/fm-parent-channel-lib.sh).
#   2. dispatch: each walk is sent at most once through
#      $FM_HOME/data/bin/fm-grok-bot-dispatch.sh (overridable with
#      FM_WALK_REQUEST_DISPATCH) as
#        fm-grok-bot-dispatch.sh <brief> --bot <bot> --walk <walk-id>
#          --walk-owner <mate-id> --timeout <sec> --once-key <walk>@<sha>
#          [--project <name> --target <name>]
#      The project/target pair is the request's project= and target= fields,
#      else the FM_WALK_REQUEST_PROJECT/FM_WALK_REQUEST_TARGET pair, else
#      omitted (a dispatcher that needs neither keeps working). The pair is
#      one space-free token each; the dispatcher validates its values, so a
#      request cannot name anything it does not accept. A request carrying
#      only one field, or a field of the wrong shape, is refused.
#      The once-key is the dispatcher's own at-most-once claim, so a re-spawn
#      after an interrupted sweep converges instead of duplicating a send.
#      The bridge and its sign-in stay private to that home: this check only
#      invokes the dispatcher and never reads, copies, or configures the
#      bridge. When the dispatcher does not exist the check reports that
#      plainly (one printed line per episode, which the watcher surfaces as a
#      check wake) and the failure outcome is still returned to the mate.
#   3. the outcome returns to the requesting mate through its existing reply
#      path: one fire-and-forget message (bin/fm-send.sh --fire-and-forget,
#      no reply expectation) into the mate's steering inbox, one per walk,
#      with up to 8192 bytes of the dispatcher report and its full MAIN log path. The
#      delivery id is derived from the corr and walk id, so an interrupted
#      delivery retries as the same send.
#
# The dispatcher call waits minutes, not seconds, while a watcher check must
# finish inside FM_CHECK_TIMEOUT (default 30). Each dispatch therefore runs
# DETACHED (Python subprocess, log under state/walk-requests/) and this check only
# spawns, collects finished logs, and delivers; a sweep never blocks on a
# walk in flight.
# A launch refreshes log freshness without truncating existing report bytes.
# Recovery consumes its one retry only after the launcher acknowledges launch
# or records failure; interruption before bookkeeping can repeat the launch
# safely with the same once-key. If a resumed request's brief becomes invalid,
# only its unstarted walks are refused; already-spawned results still return.
# tests/fm-walk-request.test.sh covers these interruption and report invariants.
#
# `arm` writes state/walk-request.check.sh and binds its bytes with
# fm-check-register.sh (the bin/fm-mail-check.sh pattern); `disarm` removes
# the shim, its trust binding, and the state record/log directory, retaining
# brief snapshots under data/walk-requests/. The check is silent
# on success: dispatch and outcome delivery are the mate's business, and a
# printed line is reserved for what this home's firstmate must see - a
# missing dispatcher, an invalid request, or an outcome that cannot be
# returned - each reported once per episode (the record's reported= line
# dedupes), because every printed check line is a wake.
#
# Tunables (env):
#   FM_WALK_REQUEST_DISPATCH     dispatcher path (default
#                                $FM_HOME/data/bin/fm-grok-bot-dispatch.sh)
#   FM_WALK_REQUEST_SEND         fm-send path (tests; default sibling script)
#   FM_WALK_REQUEST_BOT          default bot name for requests that omit one
#   FM_WALK_REQUEST_PROJECT      default dispatcher --project for requests with
#   FM_WALK_REQUEST_TARGET       no project/target fields; set both or neither
#                                (one alone is a usage error, exit 2)
#   FM_WALK_REQUEST_TIMEOUT      per-walk dispatcher --timeout (default 1800)
#   FM_WALK_REQUEST_SEND_BOUND   bounded seconds for one fm-send (default 25)
#   FM_WALK_REQUEST_STALE_SECS   a dispatch log untouched this long with no
#                                exit is respawned once, then failed
#                                (default 3600)
#   FM_WALK_REQUEST_NOW          fixed epoch for deterministic tests
#
# Exit codes: 0 the sweep ran (printed lines are wake-worthy output, never
# failure); 2 usage; 1 the sweep itself could not run (unreadable state).
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID='walk-request'
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REQUESTS_DIR="$STATE/walk-requests"
RECORD_SCHEMA='fm-walk-request-v1'
MAX_LINE=240
TYPED_MARKER=' walk-request: '

# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-line-cap-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-walk-request-check.sh [check]   sweep typed walk requests; dispatch and return outcomes
  fm-walk-request-check.sh arm       write and register state/walk-request.check.sh
  fm-walk-request-check.sh disarm    remove the check shim, its trust binding, and the records
  fm-walk-request-check.sh --help    print this help

Armed in the home that owns data/bin/fm-grok-bot-dispatch.sh. Reads typed
walk-request lines from secondmate channel files, dispatches each walk at
most once per <walk>@<release> through the dispatcher, and returns each
outcome to the requesting mate as a fire-and-forget inbox message.
EOF
}

die_usage() {
  printf 'fm-walk-request-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

walk_request_now() {
  case "${FM_WALK_REQUEST_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_WALK_REQUEST_NOW" ;;
  esac
}

age_of_file() {  # <path>
  local path=$1 epoch mtime
  epoch=$(walk_request_now)
  mtime=$(stat -c %Y "$path" 2>/dev/null || stat -f %m "$path" 2>/dev/null || printf '%s' "$epoch")
  case "$mtime" in ''|*[!0-9]*) printf 0; return 0 ;; esac
  printf '%s' "$((epoch - mtime))"
}

# --- record IO -------------------------------------------------------------

record_path() {  # <corr>
  printf '%s/%s.record' "$REQUESTS_DIR" "$1"
}

record_log_path() {  # <corr> <walk>
  printf '%s/%s.%s.log' "$REQUESTS_DIR" "$1" "$2"
}

record_get() {  # <record> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

record_write() {  # <record> <key=value>...
  local rec=$1 tmp
  shift
  tmp=$(umask 077; mktemp "$REQUESTS_DIR/.record.XXXXXX") || return 1
  printf '%s\n' "$@" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
}

record_set() {
  local rec=$1 tmp line key i
  shift
  local fields=("$@") written=()
  [ -f "$rec" ] || return 1
  tmp=$(umask 077; mktemp "$REQUESTS_DIR/.record.XXXXXX") || return 1
  # shellcheck disable=SC2094  # tmp is only written or removed on failure; rec is the input
  while IFS= read -r line || [ -n "$line" ]; do
    for ((i=0; i<${#fields[@]}; i+=2)); do
      key=${fields[$i]}
      case "$line" in
        "$key="*) line="$key=${fields[$((i + 1))]}"; written[i]=1; break ;;
      esac
    done
    printf '%s\n' "$line" || { rm -f -- "$tmp"; return 1; }
  done < "$rec" > "$tmp"
  for ((i=0; i<${#fields[@]}; i+=2)); do
    [ "${written[$i]:-}" = 1 ] || printf '%s=%s\n' "${fields[$i]}" "${fields[$((i + 1))]}" >> "$tmp" \
      || { rm -f -- "$tmp"; return 1; }
  done
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
}

walk_request_budget() {
  local bound=${FM_WALK_REQUEST_SEND_BOUND:-25}
  case "$bound" in ''|*[!0-9]*) bound=25 ;; esac
  [ "$bound" -gt 0 ] 2>/dev/null || bound=25
  fm_checkpoint_budget "$bound"
}

# --- outcome delivery ------------------------------------------------------

# Deterministic 16-hex fire-and-forget delivery id for one (corr, walk), so an
# interrupted delivery retries as the same send (bin/fm-send.sh contract).
delivery_id() {  # <corr> <walk>
  local hash
  hash=$(printf 'fm-walk-request|%s|%s' "$1" "$2" \
    | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } \
    | awk '{print $1}' | cut -c1-16)
  case "$hash" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s' "$hash" ;;
    *) return 1 ;;
  esac
}

deliver_outcome() {  # <mate> <corr> <walk> <release> <text>
  local mate=$1 corr=$2 walk=$3 release=$4 text=$5 report=${6:-} send id bound rc=0
  send=${FM_WALK_REQUEST_SEND:-$SCRIPT_DIR/fm-send.sh}
  id=$(delivery_id "$corr" "$walk")
  text=$(printf '%s' "$text" | LC_ALL=C tr -d '\000-\010\013-\037\177' | head -c 8192)
  [ -z "$report" ] || text="$text"$'\n'"Full report (MAIN): $report"
  bound=$(walk_request_budget) || { printf 124; return 0; }
  fm_run_timed "$bound" \
    "$send" "$mate" --fire-and-forget "$id" \
    "walk $walk@$release (corr=$corr) outcome: $text" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || printf '%s' "$rc"
  return 0
}

# --- intake -----------------------------------------------------------------

# One line from a mate channel becomes one record. Returns 0 when a record was
# written (valid or failed), 1 when the line yields nothing new.
intake_line() {  # <mate> <line>
  local mate=$1 line=$2 corr payload walks brief brief64 brief_format release bot project target rest token key value
  case "$line" in
    *"$TYPED_MARKER"*) ;;
    *) return 1 ;;
  esac
  corr=$(printf '%s' "$line" | grep -oE 'corr=[0-9a-fA-F]{16}' | head -1 | cut -d= -f2- | tr 'A-F' 'a-f')
  [ -n "$corr" ] || return 1
  [ -e "$(record_path "$corr")" ] && return 1
  payload=${line#*"$TYPED_MARKER"}
  walks=''
  brief=''
  brief64=''
  brief_format=''
  release=''
  bot=''
  project=''
  target=''
  rest=$payload
  while :; do
    token=${rest%% *}
    key=${token%%=*}
    value=${token#*=}
    [ "$key" != "$token" ] || break
    case "$key" in
      walks) walks=$value ;;
      brief) brief=$value ;;
      brief64) brief64=$value; brief_format=inline ;;
      release) release=$value ;;
      bot) bot=$value ;;
      project) project=$value ;;
      target) target=$value ;;
    esac
    case "$rest" in
      *' '*) rest=${rest#* } ;;
      *) break ;;
    esac
  done
  record_write "$(record_path "$corr")" \
    "schema=$RECORD_SCHEMA" \
    "corr=$corr" \
    "mate=$mate" \
    "walks=$walks" \
    "brief=$brief" \
    "brief64=$brief64" \
    "brief_format=$brief_format" \
    "release=$release" \
    "bot=$bot" \
    "project=$project" \
    "target=$target" \
    "created_epoch=$(walk_request_now)" \
    "phase=new" \
    "reason=" \
    "reported=" \
    "outcome=" \
    "retried=" \
    "spawned=" \
    "delivered=" || return 2
  return 0
}

discover_requests() {
  local FM_CHECKPOINT_DEADLINE=${FM_CHECKPOINT_DEADLINE:-} remaining slice=5
  fm_checkpoint_clock
  if [ -n "$FM_CHECKPOINT_DEADLINE" ]; then
    remaining=$((FM_CHECKPOINT_DEADLINE - FM_CHECKPOINT_NOW))
    [ "$remaining" -gt 1 ] || return 0
    [ "$((remaining / 2))" -ge "$slice" ] || slice=$((remaining / 2))
  fi
  FM_CHECKPOINT_DEADLINE=$((FM_CHECKPOINT_NOW + slice))
  local meta mate status_file line bound identity saved offset progress next rc
  local pass cursor='' cursor_file="$REQUESTS_DIR/.discovery-cursor"
  [ ! -f "$cursor_file" ] || IFS= read -r cursor < "$cursor_file" || true
  for pass in after before; do
    [ "$pass" != before ] || [ -n "$cursor" ] || break
    for meta in "$STATE"/*.meta; do
      fm_checkpoint_expired && return 0
      [ -f "$meta" ] && [ ! -L "$meta" ] || continue
      mate=${meta##*/}; mate=${mate%.meta}
      if [ -n "$cursor" ]; then
        if [ "$pass" = after ]; then [[ "$mate" > "$cursor" ]] || continue
        else [[ "$mate" > "$cursor" ]] && continue; fi
      fi
      grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
      status_file="$STATE/$mate.status"
      [ -f "$status_file" ] && [ ! -L "$status_file" ] || continue
      printf '%s\n' "$mate" > "$cursor_file" || return 1
      progress="$REQUESTS_DIR/.discovered-$mate"
      saved=''; offset=0
      [ ! -f "$progress" ] || read -r saved offset < "$progress" || true
      case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
      bound=$(fm_checkpoint_budget 5) || return 0
      while IFS=$'\t' read -r identity next line; do
        fm_checkpoint_expired && return 0
        rc=0
        intake_line "$mate" "$line" || rc=$?
        [ "$rc" -ne 2 ] || return 1
        printf '%s %s\n' "$identity" "$next" > "$progress" || return 1
      done < <(fm_run_timed "$bound" python3 - "$status_file" "$saved" "$offset" <<'PYTHON'
import os
import sys

path, saved, offset = sys.argv[1:]
with open(path, "rb") as source:
    stat = os.fstat(source.fileno())
    identity = f"{stat.st_dev}:{stat.st_ino}"
    offset = int(offset) if saved == identity else 0
    source.seek(offset if offset <= stat.st_size else 0)
    for line in iter(source.readline, b""):
        if not line.endswith(b"\n"):
            break
        sys.stdout.buffer.write(f"{identity}\t{source.tell()}\t".encode() + line)
PYTHON
      )
    done
  done
  return 0
}

# --- reporting --------------------------------------------------------------

# Print one wake-worthy line for a record, once per distinct line.
report_record() {  # <record> <line>
  local rec=$1 line=$2 reported
  reported=$(record_get "$rec" reported)
  [ "$reported" = "$line" ] && return 0
  fm_cap_line_var "walk-request: $line" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
  record_set "$rec" reported "$line" || true
}

# --- dispatch ---------------------------------------------------------------

dispatcher_path() {
  printf '%s' "${FM_WALK_REQUEST_DISPATCH:-$FM_HOME/data/bin/fm-grok-bot-dispatch.sh}"
}

# Internal action, run detached: run ONE walk's dispatch in the foreground and
# append the exit sentinel the sweep collects. The once-key inside the
# dispatcher is what makes a respawn of this action safe.
staged_brief() {
  python3 "$SCRIPT_DIR/fm-walk-request-path.py" snapshot "$FM_HOME" "$1"
}

prepare_brief() {
  local rec=$1 mate=$2 corr=$3 home remote mode source
  [ -f "$STATE/$mate.meta" ] && [ ! -L "$STATE/$mate.meta" ] || return 1
  grep -qx kind=secondmate "$STATE/$mate.meta" || return 1
  mode=$(record_get "$rec" brief_format)
  if [ "$mode" = inline ]; then
    source=$(record_get "$rec" brief64)
  else
    remote=$(record_get "$STATE/$mate.meta" remote_host)
    [ -z "$remote" ] || return 1
    mode=local
    source=$(record_get "$rec" brief)
  fi
  home=$(record_get "$STATE/$mate.meta" home)
  if [ -z "$home" ] && [ "$mode" = local ]; then
    # shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
    . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
    home=$(secondmate_registry_field "${FM_DATA_OVERRIDE:-$FM_HOME/data}/secondmates.md" "$mate" home) || home=''
  fi
  python3 "$SCRIPT_DIR/fm-walk-request-path.py" stage "$FM_HOME" "$corr" "$mode" "$source" "$home"
}

# project_target_resolve <record>: prints "<project> <target>" (or nothing when
# no pair is known). Returns 1 for a request pair that is half-set or has a
# token outside the carrier's class.
project_target_resolve() {
  local rec=$1 project target
  project=$(record_get "$rec" project)
  target=$(record_get "$rec" target)
  if [ -n "$project$target" ]; then
    [ -n "$project" ] && [ -n "$target" ] || return 1
    case "$project$target" in *[!A-Za-z0-9._-]*) return 1 ;; esac
    case "$project" in [!A-Za-z0-9]*) return 1 ;; esac
    case "$target" in [!A-Za-z0-9]*) return 1 ;; esac
  else
    project=${FM_WALK_REQUEST_PROJECT:-}
    target=${FM_WALK_REQUEST_TARGET:-}
    [ -n "$project" ] || return 0
  fi
  printf '%s %s' "$project" "$target"
}

dispatch_one() {  # <corr> <walk>
  local corr=${1:-} walk=${2:-} rec walk bot mate brief release log dispatch rc pt
  local -a pt_args=()
  [ -n "$corr" ] && [ -n "$walk" ] || exit 2
  rec=$(record_path "$corr")
  [ -f "$rec" ] || exit 2
  mate=$(record_get "$rec" mate)
  release=$(record_get "$rec" release)
  bot=$(record_get "$rec" bot)
  [ -n "$bot" ] || bot=${FM_WALK_REQUEST_BOT:-}
  dispatch=$(dispatcher_path)
  log=$(record_log_path "$corr" "$walk")
  if ! brief=$(staged_brief "$corr" 2>/dev/null); then
    printf 'refused: brief snapshot is private or unavailable\n__FM_WALK_DISPATCH_EXIT__=2\n' >> "$log"
    exit 0
  fi
  pt=$(project_target_resolve "$rec") || pt=''
  # shellcheck disable=SC2206  # deliberate split: two validated tokens
  [ -z "$pt" ] || pt_args=(--project ${pt% *} --target ${pt#* })
  "$dispatch" "$brief" --bot "$bot" --walk "$walk" --walk-owner "$mate" \
    --timeout "${FM_WALK_REQUEST_TIMEOUT:-1800}" \
    --once-key "$walk@$release" "${pt_args[@]}" >> "$log" 2>&1
  rc=$?
  printf '\n__FM_WALK_DISPATCH_EXIT__=%s\n' "$rc" >> "$log"
  exit 0
}

spawn_walk() {
  local corr=$1 walk=$2 log rc=0
  log=$(record_log_path "$corr" "$walk")
  # shellcheck disable=SC2094  # both Python and this redirection append; neither reads the log
  python3 - "$0" "$corr" "$walk" "$log" <<'PYTHON' >> "$log" 2>&1 || rc=$?
import os
import subprocess
import sys

script, corr, walk, log = sys.argv[1:]
with open(log, "ab") as output:
    os.utime(log, None)
    subprocess.Popen(["bash", script, "dispatch-one", corr, walk],
                     stdin=subprocess.DEVNULL, stdout=output,
                     stderr=subprocess.STDOUT, start_new_session=True)
PYTHON
  if [ "$rc" -ne 0 ]; then
    printf '\n__FM_WALK_DISPATCH_EXIT__=%s\n' "$rc" >> "$log"
  fi
  return "$rc"
}

record_refused() {
  local rec=$1 reason=$2 outcome=$3
  record_set "$rec" reason "$reason" || return 1
  record_set "$rec" outcome "$outcome" || return 1
  record_set "$rec" phase refusing || return 1
  report_record "$rec" "$reason"
  process_record "$rec"
}

process_record() {
  local rec=$1 corr mate walks brief brief_format release bot phase spawned delivered retried
  local walk log sentinel outcome rc age launched=0 pending_walk rotated
  local walk_id_re='[A-Za-z0-9][A-Za-z0-9._-]{0,63}' walks_re
  corr=$(record_get "$rec" corr)
  mate=$(record_get "$rec" mate)
  walks=$(record_get "$rec" walks)
  brief=$(record_get "$rec" brief)
  brief_format=$(record_get "$rec" brief_format)
  release=$(record_get "$rec" release)
  bot=$(record_get "$rec" bot)
  phase=$(record_get "$rec" phase)
  spawned=$(record_get "$rec" spawned)
  delivered=$(record_get "$rec" delivered)
  retried=$(record_get "$rec" retried)
  case "$phase" in
    delivered|failed) return 0 ;;
    refusing)
      rc=$(deliver_outcome "$mate" "$corr" request "$release" "$(record_get "$rec" outcome)")
      if [ -z "$rc" ]; then
        record_set "$rec" phase failed || return 1
      else
        report_record "$rec" "outcome delivery to $mate failed (fm-send rc=$rc) for request $corr; will retry"
      fi
      return 0
      ;;
  esac
  if [ -z "$walks" ] || { [ -z "$brief" ] && [ "$brief_format" != inline ]; } || [ -z "$release" ]; then
    record_refused "$rec" "request $corr from $mate is incomplete (walks, brief, and release sha are all required); nothing dispatched" \
      "refused: the typed walk request was incomplete; re-send it with walks, brief, and release"
    return 0
  fi
  case "$release" in
    ''|*[!0-9a-fA-F]*)
      record_refused "$rec" "request $corr from $mate names a malformed release sha; nothing dispatched" \
        "refused: the release field must be a commit sha"
      return 0
      ;;
  esac
  [ "${#release}" -ge 7 ] && [ "${#release}" -le 64 ] || {
    record_refused "$rec" "request $corr from $mate names a malformed release sha; nothing dispatched" \
      "refused: the release field must be a 7..64 character commit sha"
    return 0
  }
  walks_re="^$walk_id_re(,$walk_id_re)*$"
  if ! [[ "$walks" =~ $walks_re ]]; then
    record_refused "$rec" "request $corr from $mate names invalid walk ids; nothing dispatched" \
      "refused: walk ids must be 1..64 character slugs starting with a letter or digit"
    return 0
  fi
  case "$phase" in
    new)
      if [ ! -x "$(dispatcher_path)" ]; then
        record_refused "$rec" "dispatcher absent at $(dispatcher_path); install the home's walker dispatcher or disarm this check" \
          "refused: MAIN has no walker dispatcher at $(dispatcher_path); the walk was not dispatched"
        return 0
      fi
      if ! project_target_resolve "$rec" >/dev/null; then
        record_refused "$rec" "request $corr carries an incomplete or malformed project/target pair; nothing dispatched" \
          "refused: the project and target fields must be given together, each one plain name; re-send with both"
        return 0
      fi
      [ -n "$bot" ] || bot=${FM_WALK_REQUEST_BOT:-}
      if [ -z "$bot" ]; then
        record_refused "$rec" "request $corr names no bot and this home sets no FM_WALK_REQUEST_BOT; nothing dispatched" \
          "refused: no bot was named for the walk and MAIN has no default; re-send with a bot field"
        return 0
      fi
      ;;
  esac
  if [ "$phase" = new ]; then
    prepare_brief "$rec" "$mate" "$corr" >/dev/null 2>&1 || true
  fi
  for walk in $(printf '%s' "$walks" | tr ',' ' '); do
    fm_checkpoint_expired && return 0
    case ",$spawned," in *",$walk,"*) continue ;; esac
    log=$(record_log_path "$corr" "$walk")
    if ! staged_brief "$corr" >/dev/null 2>&1; then
      printf 'refused: brief snapshot is private, unavailable, binary, or exceeds 64 KiB; this walk was not dispatched\n__FM_WALK_DISPATCH_EXIT__=2\n' > "$log" || return 1
      spawned="${spawned:+$spawned,}$walk"
      record_set "$rec" phase dispatching spawned "$spawned" || return 1
      report_record "$rec" "request $corr: unstarted walk $walk refused because its brief is unavailable or invalid"
      continue
    fi
    : > "$log" || return 1
    spawned="${spawned:+$spawned,}$walk"
    record_set "$rec" phase dispatching spawned "$spawned" || return 1
    spawn_walk "$corr" "$walk" || true
    launched=1
  done
  [ "$launched" -eq 0 ] || return 0
  for walk in $(printf '%s' "$spawned" | tr ',' ' '); do
    fm_checkpoint_expired && return 0
    case ",$delivered," in
      *",$walk,"*) continue ;;
    esac
    log=$(record_log_path "$corr" "$walk")
    sentinel=$(sed -n 's/^__FM_WALK_DISPATCH_EXIT__=//p' "$log" 2>/dev/null | tail -1)
    if [ -z "$sentinel" ]; then
      age=$(age_of_file "$log")
      case "$age" in ''|*[!0-9]*) age=0 ;; esac
      [ "$age" -gt "${FM_WALK_REQUEST_STALE_SECS:-3600}" ] || continue
      case ",$retried," in
        *",$walk,"*)
          outcome="dispatch failed: no completion was recorded after one recovery attempt for $walk@$release"$'\n'"$(sed '/^__FM_WALK_DISPATCH_EXIT__=/d' "$log")"
          ;;
        *)
          spawn_walk "$corr" "$walk" || true
          retried="${retried:+$retried,}$walk"
          record_set "$rec" retried "$retried" || return 1
          continue
          ;;
      esac
    else
      outcome=$(sed '/^__FM_WALK_DISPATCH_EXIT__=/d' "$log" 2>/dev/null)
      [ -n "$outcome" ] || outcome="(no dispatcher output)"
      if [ "$sentinel" = 0 ]; then
        outcome="sent, exit=0: $outcome"
      else
        outcome="dispatch failed (exit=$sentinel): $outcome"
      fi
    fi
    rotated=
    for pending_walk in $(printf '%s' "$spawned" | tr ',' ' '); do
      [ "$pending_walk" = "$walk" ] || rotated="${rotated:+$rotated,}$pending_walk"
    done
    spawned="${rotated:+$rotated,}$walk"
    record_set "$rec" spawned "$spawned" || return 1
    rc=$(deliver_outcome "$mate" "$corr" "$walk" "$release" "$outcome" "$log")
    if [ -n "$rc" ]; then
      report_record "$rec" "outcome delivery to $mate failed (fm-send rc=$rc) for request $corr; will retry"
      continue
    fi
    delivered="${delivered:+$delivered,}$walk"
    record_set "$rec" delivered "$delivered" || return 1
  done
  local pending=0
  for walk in $(printf '%s' "$spawned" | tr ',' ' '); do
    case ",$delivered," in *",$walk,"*) ;; *) pending=1 ;; esac
  done
  if [ "$pending" -eq 0 ] && [ -n "$spawned" ]; then
    record_set "$rec" phase delivered || true
  fi
  return 0
}

action_check() {
  local FM_CHECKPOINT_DEADLINE=${FM_CHECKPOINT_DEADLINE:-} seconds=${FM_CHECK_TIMEOUT:-30} deadline
  case "$seconds" in ''|0*|*[!0-9]*) seconds=30 ;; esac
  seconds=$((seconds - 2))
  [ "$seconds" -gt 0 ] || seconds=1
  fm_checkpoint_clock
  deadline=$((FM_CHECKPOINT_NOW + seconds))
  if [ -z "$FM_CHECKPOINT_DEADLINE" ] || [ "$deadline" -lt "$FM_CHECKPOINT_DEADLINE" ]; then
    FM_CHECKPOINT_DEADLINE=$deadline
  fi
  mkdir -p "$REQUESTS_DIR" || return 1
  discover_requests || return $?
  local rec name pass cursor='' cursor_file="$REQUESTS_DIR/.cursor"
  local LC_ALL=C
  [ ! -f "$cursor_file" ] || IFS= read -r cursor < "$cursor_file" || true
  for pass in after before; do
    [ "$pass" != before ] || [ -n "$cursor" ] || break
    for rec in "$REQUESTS_DIR"/*.record; do
      fm_checkpoint_expired && return 0
      [ -f "$rec" ] && [ ! -L "$rec" ] || continue
      name=${rec##*/}
      if [ -n "$cursor" ]; then
        if [ "$pass" = after ]; then [[ "$name" > "$cursor" ]] || continue
        else [[ "$name" > "$cursor" ]] && continue; fi
      fi
      [ "$(record_get "$rec" schema)" = "$RECORD_SCHEMA" ] || continue
      printf '%s\n' "$name" > "$cursor_file" || return 1
      process_record "$rec" || return $?
    done
  done
  return 0
}

# --- arm / disarm (the fm-mail-check.sh pattern) ----------------------------

# The home is embedded already resolved, because the watcher runs the shim
# from its own working directory and a relative spelling would send the check
# to a different home, or to none at all.
shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-walk-request-check.sh - typed walk-request carrier shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-walk-request-check.sh") check"
}

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-walk-request-check.XXXXXX" 2>/dev/null) || return 1
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

arm_rollback() {
  if [ -n "${ARM_BACKUP:-}" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

action_arm() {
  local want device tmp rc=0
  mkdir -p "$STATE" || return 1
  want=$(shim_content "$FM_HOME")
  device=$(fm_pr_file_device "$STATE") || return 1
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ]; then
    tmp=$(umask 077; mktemp "$STATE/.fm-walk-request-check.XXXXXX" 2>/dev/null) || return 1
    if cat "$CHECK_SHIM" > "$tmp" 2>/dev/null && chmod 0700 "$tmp" \
      && fm_pr_private_file_valid "$tmp" 700 "$device"; then
      ARM_BACKUP=$tmp
    else
      rm -f -- "$tmp"
    fi
  fi
  if ! shim_write "$want"; then
    arm_rollback
    printf 'fm-walk-request-check: could not write the check shim at %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID"; then
    arm_rollback
    printf 'fm-walk-request-check: could not register the check shim\n' >&2
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  local rc=0
  "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" || rc=$?
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  rm -rf -- "$REQUESTS_DIR"
  if [ "$rc" -ne 0 ]; then
    printf 'fm-walk-request-check: unregistration reported rc=%s; the shim and records were still removed\n' "$rc" >&2
  fi
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "${1:-check}" in
  -h|--help)
    usage
    exit 0
    ;;
  check)
    if [ -n "${FM_WALK_REQUEST_PROJECT:-}" ] || [ -n "${FM_WALK_REQUEST_TARGET:-}" ]; then
      [ -n "${FM_WALK_REQUEST_PROJECT:-}" ] && [ -n "${FM_WALK_REQUEST_TARGET:-}" ] \
        || die_usage "FM_WALK_REQUEST_PROJECT and FM_WALK_REQUEST_TARGET must be set together"
    fi
    action_check
    ;;
  dispatch-one) dispatch_one "$2" "$3" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  *)
    die_usage "unknown action: $1"
    ;;
esac
