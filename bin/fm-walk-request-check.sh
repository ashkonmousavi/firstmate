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
#      records kind=secondmate is scanned for
#        note [corr=<16hex>] [at=...]: walk-request: walks=<ids>
#             brief=<absolute-path> release=<sha> [bot=<name>]
#      Both mate shapes land there: a local route appends into the parent
#      home directly and a remote route's reply adapter mirrors its channel
#      into the same file (bin/fm-parent-channel-lib.sh).
#   2. dispatch: each walk is dispatched exactly once through
#      $FM_HOME/data/bin/fm-grok-bot-dispatch.sh (overridable with
#      FM_WALK_REQUEST_DISPATCH) as
#        fm-grok-bot-dispatch.sh <brief> --bot <bot> --walk <walk-id>
#          --walk-owner <mate-id> --timeout <sec> --once-key <walk>@<sha>
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
#      with the dispatch result and the dispatcher's first reply line. The
#      delivery id is derived from the corr and walk id, so an interrupted
#      delivery retries as the same send.
#
# The dispatcher call waits minutes, not seconds, while a watcher check must
# finish inside FM_CHECK_TIMEOUT (default 30). Each dispatch therefore runs
# DETACHED (setsid, log under state/walk-requests/) and this check only
# spawns, collects finished logs, and delivers; a sweep never blocks on a
# walk in flight.
#
# `arm` writes state/walk-request.check.sh and binds its bytes with
# fm-check-register.sh (the bin/fm-mail-check.sh pattern); `disarm` removes
# the shim, its trust binding, and the record directory. The check is silent
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

record_set() {  # <record> <key> <value>
  local rec=$1 key=$2 value=$3 tmp
  [ -f "$rec" ] || return 1
  [ "$(record_get "$rec" "$key")" = "$value" ] && return 0
  tmp=$(umask 077; mktemp "$REQUESTS_DIR/.record.XXXXXX") || return 1
  sed "s/^$key=.*/$key=$(printf '%s' "$value" | sed 's/[&/\]/\\&/g')/" "$rec" > "$tmp" \
    || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
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
  local mate=$1 corr=$2 walk=$3 release=$4 text=$5 send id rc=0
  send=${FM_WALK_REQUEST_SEND:-$SCRIPT_DIR/fm-send.sh}
  id=$(delivery_id "$corr" "$walk")
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177' | cut -c1-400)
  fm_run_timed "${FM_WALK_REQUEST_SEND_BOUND:-25}" \
    "$send" "$mate" --fire-and-forget "$id" \
    "walk $walk@$release (corr=$corr) outcome: $text" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || printf '%s' "$rc"
  return 0
}

# --- intake -----------------------------------------------------------------

# One line from a mate channel becomes one record. Returns 0 when a record was
# written (valid or failed), 1 when the line yields nothing new.
intake_line() {  # <mate> <line>
  local mate=$1 line=$2 corr payload walks brief release bot rest token key value
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
  release=''
  bot=''
  rest=$payload
  while :; do
    token=${rest%% *}
    key=${token%%=*}
    value=${token#*=}
    [ "$key" != "$token" ] || break
    case "$key" in
      walks) walks=$value ;;
      brief) brief=$value ;;
      release) release=$value ;;
      bot) bot=$value ;;
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
    "release=$release" \
    "bot=$bot" \
    "created_epoch=$(walk_request_now)" \
    "phase=new" \
    "reason=" \
    "reported=" \
    "attempts=0" \
    "spawned=" \
    "delivered=" || return 1
  return 0
}

discover_requests() {
  local meta mate status_file line
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    grep -qx 'kind=secondmate' "$meta" 2>/dev/null || continue
    mate=${meta##*/}; mate=${mate%.meta}
    status_file="$STATE/$mate.status"
    [ -f "$status_file" ] || continue
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      intake_line "$mate" "$line" || true
    done < <(fm_run_timed "${FM_WALK_REQUEST_SEND_BOUND:-25}" grep -F "$TYPED_MARKER" "$status_file" 2>/dev/null || true)
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
dispatch_one() {  # <corr> <walk>
  local corr=${1:-} walk=${2:-} rec walk bot mate brief release log dispatch rc
  [ -n "$corr" ] && [ -n "$walk" ] || exit 2
  rec=$(record_path "$corr")
  [ -f "$rec" ] || exit 2
  mate=$(record_get "$rec" mate)
  brief=$(record_get "$rec" brief)
  release=$(record_get "$rec" release)
  bot=$(record_get "$rec" bot)
  [ -n "$bot" ] || bot=${FM_WALK_REQUEST_BOT:-}
  dispatch=$(dispatcher_path)
  log=$(record_log_path "$corr" "$walk")
  printf '%s\n' "dispatching $walk@$release brief=$brief bot=${bot:-<none>} owner=$mate" > "$log" || exit 3
  "$dispatch" "$brief" --bot "$bot" --walk "$walk" --walk-owner "$mate" \
    --timeout "${FM_WALK_REQUEST_TIMEOUT:-1800}" \
    --once-key "$walk@$release" >> "$log" 2>&1
  rc=$?
  printf '\n__FM_WALK_DISPATCH_EXIT__=%s\n' "$rc" >> "$log"
  exit 0
}

spawn_walk() {  # <record> <corr> <walk>
  local rec=$1 corr=$2 walk=$3 log
  log=$(record_log_path "$corr" "$walk")
  : > "$log" 2>/dev/null || return 1
  setsid bash "$0" dispatch-one "$corr" "$walk" </dev/null >>"$log" 2>&1 &
  return 0
}

record_failed() {  # <record> <reason>
  local rec=$1 reason=$2
  record_set "$rec" phase failed || true
  record_set "$rec" reason "$reason" || true
  report_record "$rec" "$reason"
}

# --- the sweep --------------------------------------------------------------

process_record() {  # <record>
  local rec=$1 corr mate walks brief release bot phase spawned delivered
  local walk log sentinel outcome rc attempts age
  corr=$(record_get "$rec" corr)
  mate=$(record_get "$rec" mate)
  walks=$(record_get "$rec" walks)
  brief=$(record_get "$rec" brief)
  release=$(record_get "$rec" release)
  bot=$(record_get "$rec" bot)
  phase=$(record_get "$rec" phase)
  spawned=$(record_get "$rec" spawned)
  delivered=$(record_get "$rec" delivered)
  case "$phase" in
    delivered|failed) return 0 ;;
  esac
  # Validation: the typed line must name everything the dispatcher needs.
  if [ -z "$walks" ] || [ -z "$brief" ] || [ -z "$release" ]; then
    record_failed "$rec" "request $corr from $mate is incomplete (walks, brief path, and release sha are all required); nothing dispatched"
    deliver_outcome "$mate" "$corr" request "$release" \
      "refused: the typed walk request was incomplete; re-send it with walks, brief, and release"
    return 0
  fi
  case "$release" in
    ''|*[!0-9a-fA-F]*)
      record_failed "$rec" "request $corr from $mate names a malformed release sha; nothing dispatched"
      deliver_outcome "$mate" "$corr" request "$release" \
        "refused: the release field must be a commit sha"
      return 0
      ;;
  esac
  [ "${#release}" -ge 7 ] && [ "${#release}" -le 64 ] || {
    record_failed "$rec" "request $corr from $mate names a malformed release sha; nothing dispatched"
    deliver_outcome "$mate" "$corr" request "$release" \
      "refused: the release field must be a 7..64 character commit sha"
    return 0
  }
  case "$phase" in
    new)
      if [ ! -x "$(dispatcher_path)" ]; then
        record_failed "$rec" "dispatcher absent at $(dispatcher_path); install the home's walker dispatcher or disarm this check"
        deliver_outcome "$mate" "$corr" request "$release" \
          "refused: MAIN has no walker dispatcher at $(dispatcher_path); the walk was not dispatched"
        return 0
      fi
      [ -n "$bot" ] || bot=${FM_WALK_REQUEST_BOT:-}
      if [ -z "$bot" ]; then
        record_failed "$rec" "request $corr names no bot and this home sets no FM_WALK_REQUEST_BOT; nothing dispatched"
        deliver_outcome "$mate" "$corr" request "$release" \
          "refused: no bot was named for the walk and MAIN has no default; re-send with a bot field"
        return 0
      fi
      spawned=
      for walk in $(printf '%s' "$walks" | tr ',' ' '); do
        spawn_walk "$rec" "$corr" "$walk" || {
          record_failed "$rec" "could not spawn the dispatch for $walk@$release (state dir unwritable?)"
          return 0
        }
        spawned="${spawned:+$spawned,}$walk"
      done
      record_set "$rec" phase dispatching || true
      record_set "$rec" spawned "$spawned" || true
      return 0
      ;;
  esac
  # phase=dispatching: collect finished logs, deliver outcomes.
  attempts=$(record_get "$rec" attempts)
  case "$attempts" in ''|*[!0-9]*) attempts=0 ;; esac
  for walk in $(printf '%s' "$spawned" | tr ',' ' '); do
    case ",$delivered," in
      *",$walk,"*) continue ;;
    esac
    log=$(record_log_path "$corr" "$walk")
    sentinel=$(sed -n 's/^__FM_WALK_DISPATCH_EXIT__=//p' "$log" 2>/dev/null | tail -1)
    if [ -z "$sentinel" ]; then
      age=$(age_of_file "$log")
      case "$age" in ''|*[!0-9]*) age=0 ;; esac
      if [ "$age" -gt "${FM_WALK_REQUEST_STALE_SECS:-3600}" ] && [ "$attempts" -lt 1 ]; then
        # No exit and long untouched: the detached dispatch was lost. The
        # once-key makes one respawn safe (an already-sent key exits 0).
        attempts=$((attempts + 1))
        record_set "$rec" attempts "$attempts" || true
        spawn_walk "$rec" "$corr" "$walk" || true
      fi
      continue
    fi
    outcome=$(sed -n '/^__FM_WALK_DISPATCH_EXIT__=/q; p' "$log" 2>/dev/null | sed -n '2,$p' | head -1)
    [ -n "$outcome" ] || outcome="(no dispatcher output)"
    if [ "$sentinel" = 0 ]; then
      outcome="sent, exit=0: $outcome"
    else
      outcome="dispatch failed (exit=$sentinel): $outcome"
    fi
    rc=$(deliver_outcome "$mate" "$corr" "$walk" "$release" "$outcome")
    if [ -n "$rc" ]; then
      attempts=$((attempts + 1))
      record_set "$rec" attempts "$attempts" || true
      if [ "$attempts" -ge 3 ]; then
        record_failed "$rec" "outcome delivery to $mate failed (fm-send rc=$rc) after $attempts attempts for $walk@$release"
      fi
      return 0
    fi
    delivered="${delivered:+$delivered,}$walk"
    record_set "$rec" delivered "$delivered" || true
  done
  if [ "$delivered" = "$spawned" ] && [ -n "$spawned" ]; then
    record_set "$rec" phase delivered || true
  fi
  return 0
}

action_check() {
  mkdir -p "$REQUESTS_DIR" || return 1
  discover_requests
  local rec
  for rec in "$REQUESTS_DIR"/*.record; do
    [ -e "$rec" ] || continue
    [ ! -L "$rec" ] || continue
    [ "$(record_get "$rec" schema)" = "$RECORD_SCHEMA" ] || continue
    process_record "$rec"
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
  check) action_check ;;
  dispatch-one) dispatch_one "$2" "$3" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  *)
    die_usage "unknown action: $1"
    ;;
esac
