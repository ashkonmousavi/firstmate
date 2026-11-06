#!/usr/bin/env bash
# Fork-only readers of the stock session-lock format.
# Source this module for a guarded snapshot or holder idle-time report.
# Stock session-lock identity, ownership, reclaim and acquisition functions stay
# in fm-session-lock-lib.sh and fm-lock.sh without fork overrides.
# This module defines only additional readers; it acquires no session ownership.

if ! command -v fm_session_lock_recorded_session_id >/dev/null 2>&1; then
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "${BASH_SOURCE[0]%/*}/fm-session-lock-lib.sh"
fi

FM_LOCK_TAKEOVER_TRANSCRIPT_MAX=$((256 * 1024 * 1024))

fm_session_lock_read_record() {
  # shellcheck disable=SC2034 # Dynamic context for the lazily sourced wake library.
  local state=$1 STATE=$1 FM_STATE_OVERRIDE=$1 mutex=$1/.lock.acquire current acquired=0
  FM_SESSION_LOCK_PID=
  FM_SESSION_LOCK_SESSION=
  FM_SESSION_LOCK_PRIOR_SESSION=
  [ -d "$state" ] || return 1
  if ! command -v fm_lock_try_acquire >/dev/null 2>&1; then
    # shellcheck source=/dev/null
    . "${BASH_SOURCE[0]%/*}/fm-wake-lib.sh"
  fi
  fm_current_pid current || return 1
  if [ "$(cat "$mutex/pid" 2>/dev/null || true)" != "$current" ]; then
    if [ "${2:-}" = 0 ]; then
      fm_lock_try_acquire "$mutex" || return 2
    else
      fm_lock_acquire_wait "$mutex" || return 2
    fi
    acquired=1
  fi
  if [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ]; then
    FM_SESSION_LOCK_PID=$(cat "$state/.lock" 2>/dev/null || true)
    FM_SESSION_LOCK_SESSION=$(fm_session_lock_recorded_session_id "$state" 2>/dev/null || true)
    if [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ]; then
      FM_SESSION_LOCK_PRIOR_SESSION=$(sed -n '2p;2q' "$state/.lock-session" 2>/dev/null || true)
    fi
  fi
  if [ "$acquired" -eq 1 ]; then
    fm_lock_release "$mutex"
  fi
  fm_session_pid_valid "$FM_SESSION_LOCK_PID" || return 1
}

fm_session_lock_id_token() {  # <session-id>
  local id=$1 n
  case "$id" in
    ''|*[!A-Za-z0-9-]*) return 1 ;;
  esac
  n=${#id}
  [ "$n" -ge 8 ] && [ "$n" -le 128 ] || return 1
  case "$id" in
    [A-Za-z0-9]*) return 0 ;;
  esac
  return 1
}

# Print the one regular transcript for session id $1, or return 1 when none
# exists and 2 when the match is missing, multiple, or not a regular file.
# Claude stores <config>/projects/<slug>/<session-id>.jsonl. The slug is not
# trusted: zero or two or more matches refuse, and a symlink is not a match
# (find -type f plus a second lstat).
fm_session_lock_transcript_file() {  # <session-id>
  local id=$1 root count=0 one='' path
  fm_session_lock_id_token "$id" || return 2
  root=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
  [ -d "$root" ] && [ ! -L "$root" ] || return 1
  while IFS= read -r -d '' path; do
    count=$((count + 1))
    one=$path
    [ "$count" -le 1 ] || break
  done < <(find "$root" -mindepth 2 -maxdepth 3 -type f -name "$id.jsonl" -print0 2>/dev/null)
  [ "$count" -eq 1 ] || {
    [ "$count" -eq 0 ] && return 1
    return 2
  }
  [ -f "$one" ] && [ ! -L "$one" ] || return 2
  case "$one" in
    *$'\n'*|*$'\r'*) return 2 ;;
  esac
  printf '%s\n' "$one"
}

fm_session_lock_holder_report() {  # <state>
  local state=$1 pid tty idle='' recorded file newest now etimes comm args read_rc age ps_rc
  if fm_session_lock_read_record "$state" 0; then
    :
  else
    read_rc=$?
    if [ "$read_rc" -ne 2 ] && [ ! -e "$state/.lock" ] && [ ! -L "$state/.lock" ]; then
      printf 'state=free\n'
    else
      printf 'state=unknown\n'
    fi
    return 0
  fi
  pid=$FM_SESSION_LOCK_PID
  if ! kill -0 "$pid" 2>/dev/null; then
    if ps -o comm= -p "$pid" >/dev/null 2>&1; then
      printf 'state=unknown\n'
    else
      ps_rc=$?
      if [ "$ps_rc" -eq 1 ]; then
        printf 'state=stale pid=%s\n' "$pid"
      else
        printf 'state=unknown\n'
      fi
    fi
    return 0
  fi
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || { printf 'state=unknown\n'; return 0; }
  args=$(ps -o args= -p "$pid" 2>/dev/null) || { printf 'state=unknown\n'; return 0; }
  if ! fm_harness_process_matches "$comm" "$args"; then
    printf 'state=stale pid=%s\n' "$pid"
    return 0
  fi
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d '[:space:]') || tty=
  case "$tty" in
    ''|'?'|*[!A-Za-z0-9_./-]*) tty=none ;;
  esac
  for recorded in "$FM_SESSION_LOCK_SESSION" "$FM_SESSION_LOCK_PRIOR_SESSION"; do
    if fm_session_lock_id_token "$recorded" \
      && file=$(fm_session_lock_transcript_file "$recorded"); then
      newest=$(python3 - "$file" "$FM_LOCK_TAKEOVER_TRANSCRIPT_MAX" <<'PY'
import datetime, json, os, stat, sys, time
path, cap_s = sys.argv[1], sys.argv[2]
cap = int(cap_s)

def parse_ts(value):
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        try:
            number = float(text)
        except ValueError:
            if text.endswith('Z'):
                text = text[:-1] + '+00:00'
            try:
                parsed = datetime.datetime.fromisoformat(text)
            except ValueError:
                return None
            if parsed.tzinfo is None:
                return None
            return parsed.timestamp()
    else:
        return None
    if number > 1e12:
        number /= 1000.0
    return number

try:
    info = os.lstat(path)
except OSError:
    sys.exit(1)
if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_size > cap:
    sys.exit(1)
newest = None
try:
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, 'r', encoding='utf-8', errors='replace') as handle:
        for line in handle:
            text = line.strip()
            if not text:
                continue
            try:
                obj = json.loads(text)
            except json.JSONDecodeError:
                continue
            if not isinstance(obj, dict) or obj.get('type') not in ('user', 'assistant'):
                continue
            stamp = parse_ts(obj.get('timestamp'))
            if stamp is None:
                sys.exit(1)
            if newest is None or stamp > newest:
                newest = stamp
except OSError:
    sys.exit(1)
if newest is None:
    sys.exit(1)
sys.stdout.write(str(int(newest)) + '\n')
PY
      ) || newest=
      if [ -n "$newest" ]; then
        now=$(date +%s 2>/dev/null) || return 1
        case "$newest" in
          ''|*[!0-9]*) newest= ;;
        esac
      fi
      if [ -n "$newest" ]; then
        age=$((now - newest))
        [ "$age" -ge 0 ] || age=0
        if [ -z "$idle" ] || [ "$age" -lt "$idle" ]; then
          idle=$age
        fi
      fi
    fi
  done
  if [ -z "$idle" ]; then
    etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$etimes" in
      ''|*[!0-9]*) return 1 ;;
    esac
    idle=$etimes
  fi
  printf 'state=held pid=%s tty=%s idle_seconds=%s\n' "$pid" "$tty" "$idle"
}
