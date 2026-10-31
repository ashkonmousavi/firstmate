#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Two signals decide ownership, either one sufficient: the recorded pid
# is a member of this process's contiguous harness ancestry, or the trusted
# Claude session id below matches the id recorded beside a live lock. Neither
# signal ever fails open: no id, no sidecar, an untrusted id, or a different
# recorded id leaves the ancestry verdict exactly as it was.
# Idle fork-resume takeover is decided only by
# fm_session_lock_idle_fork_takeover_allowed below. These ownership signals
# never treat that successor as the current owner.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
_FM_SESSION_LOCK_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_SESSION_LOCK_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_SESSION_LOCK_LIB_DIR=.
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_SESSION_LOCK_LIB_DIR:-/}/fm-cursor-lib.sh"
unset _FM_SESSION_LOCK_LIB_DIR

# Known harness command names; extend when a new adapter is verified. omp is
# anchored exactly like pi: its process name is the bare word `omp` (verified,
# omp 18.1.11), and a substring match would claim ompd or comp.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^pi$|^pi-signed$|^omp$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the outermost pid of this session's contiguous harness run for callers
# that need that ancestry identity. This is not necessarily the pid written to
# the session lock: fm_session_lock_anchor_pid owns that choice and uses a
# trusted Claude session's model-loop pid instead. Every non-Claude harness
# reports a single pid, so this remains its innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  _fm_harness_outermost_pid "$pids"
}

# Print the last (outermost) pid of ancestry list $1, or return 1 when empty.
_fm_harness_outermost_pid() {  # <ancestry-pids>
  local pid outermost=''
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$1
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True when pid $1 is one of the lines of ancestry list $2.
fm_harness_pid_listed() {  # <pid> <ancestry-pids>
  local pid
  while IFS= read -r pid; do
    [ "$pid" = "$1" ] && return 0
  done <<EOF
$2
EOF
  return 1
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# --- trusted same-session identity -------------------------------------------
# Claude Code hands every hook and tool shell CLAUDE_CODE_SESSION_ID (the
# session's conversation id) and CLAUDE_PID (the pid of the process running the
# model loop). A background session runs that model loop in a transient helper
# bridged to its front-end by a shared daemon, and when that bridge is recycled
# the contiguous claude-named ancestry from a hook to the recorded lock owner
# breaks while the owner pid stays alive, so ancestry alone reads the session's
# own lock as another live session's. The id is the one identity that survives
# the recycling, so it is accepted as a second ownership signal - but only from
# an environment proven to belong to the current Claude run.
#
# Trust gate: CLAUDE_PID must be a Claude-shaped member of this process's
# contiguous harness ancestry. An id merely retained in a helper environment
# fails that membership and is ignored: a hand-started Pi or codex primary under
# a Claude pane still carries the pane's CLAUDE_CODE_SESSION_ID and CLAUDE_PID,
# and must never own a lock with them. Ids are read from the environment only,
# never from ps argv, where prompts and briefs are visible.
#
# A --fork-session successor mints a new id, so it is not this session
# (https://code.claude.com/docs/en/cli-reference,
# https://code.claude.com/docs/en/sessions). Whether that successor may take a
# live holder's lock is fm_session_lock_idle_fork_takeover_allowed, not this
# ownership check. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print the Claude session id this process may own with, or return 1. $1 is the
# ancestry list an earlier walk already produced, so a caller that walked once
# need not walk again.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  case "$claude_pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$claude_pid" ] || continue
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    fm_harness_process_matches "$comm" "$args" || return 1
    [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || return 1
    printf '%s\n' "$id"
    return 0
  done <<EOF
$pids
EOF
  return 1
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# carriage return, is simply no recorded id. The optional second row retains
# the immediately prior session after a same-process rekey.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(sed -n '1p;1q' "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

fm_session_lock_read_record() {
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
  case "$FM_SESSION_LOCK_PID" in ''|*[!0-9]*) return 1 ;; esac
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  fm_session_lock_read_record "$state" || return 1
  [ "$FM_SESSION_LOCK_SESSION" = "$trusted" ]
}

# Print the pid bin/fm-lock.sh records on lock line 1 for this session. For a
# Claude session with a trusted id that is CLAUDE_PID, the model-loop process:
# never the shared transient daemon and never a front-end that outlives the
# session, so "recorded pid dead" keeps meaning "session gone" instead of
# wedging a home behind a live daemon whose session died. A replaced background
# helper leaves a dead pid that its own session's next hook reclaims, because
# the sidecar still names that session. Every other session records the
# outermost pid of its contiguous run, exactly as before.
fm_session_lock_anchor_pid() {
  local pids
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns:
# the recorded pid is ANY harness ancestor of the current process, or the lock
# was recorded by this same trusted Claude session and its recorded pid is still
# a live harness. Membership is the honest ancestry test, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids trusted
  fm_session_lock_read_record "$state" "${2:-}" || return "$?"
  lock_pid=$FM_SESSION_LOCK_PID
  pids=$(fm_harness_ancestry_pids) || return 1
  fm_harness_pid_listed "$lock_pid" "$pids" && return 0
  trusted=$(fm_session_lock_trusted_session_id "$pids") || return 1
  [ "$trusted" = "$FM_SESSION_LOCK_SESSION" ] || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# contiguous harness ancestry that was not recorded by this same trusted Claude
# session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids trusted
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  fm_session_lock_read_record "$state" || return 1
  lock_pid=$FM_SESSION_LOCK_PID
  fm_harness_pid_alive "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  fm_harness_pid_listed "$lock_pid" "$pids" && return 1
  trusted=$(fm_session_lock_trusted_session_id "$pids" 2>/dev/null || true)
  [ -n "$trusted" ] && [ "$trusted" = "$FM_SESSION_LOCK_SESSION" ] && return 1
  # shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
  return 0
}

# Read-only classification of state/.lock for machine-readable callers.
# Never acquires the lock. A held lock is not proof the holder is consuming
# wakes; that question belongs to the inbox readiness projection.
#
# Sets:
#   FM_LOCK_INSPECT_STATE         free|held|stale|unreadable|unknown
#   FM_LOCK_INSPECT_PID           recorded pid, or empty
#   FM_LOCK_INSPECT_LIVE_HARNESS  true|false|unknown
#
# held: the recorded pid is a live verified harness.
# stale: the recorded pid is gone.
# unknown: the file or pid cannot be classified without guessing, including a
# live process that is not a verified harness. Existence of a lock file, a
# session record, or a pane is never treated as liveness.
# shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
FM_LOCK_INSPECT_STATE=unknown
FM_LOCK_INSPECT_PID=
FM_LOCK_INSPECT_LIVE_HARNESS=unknown
fm_session_lock_inspect() {  # <state>
  local state=$1 lock pid
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=unknown
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=
  # shellcheck disable=SC2034 # Output globals, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=unknown
  lock="$state/.lock"
  if [ ! -e "$lock" ]; then
    FM_LOCK_INSPECT_STATE=free
    FM_LOCK_INSPECT_LIVE_HARNESS=false
    return 0
  fi
  if [ ! -f "$lock" ] || [ -L "$lock" ]; then
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  fi
  pid=$(cat "$lock" 2>/dev/null) || {
    FM_LOCK_INSPECT_STATE=unreadable
    return 0
  }
  pid=${pid%%$'\n'*}
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_PID=$pid
  case "$pid" in
    ''|*[!0-9]*)
      FM_LOCK_INSPECT_STATE=unknown
      return 0
      ;;
  esac
  if kill -0 "$pid" 2>/dev/null; then
    if fm_harness_pid_alive "$pid"; then
      FM_LOCK_INSPECT_STATE=held
      FM_LOCK_INSPECT_LIVE_HARNESS=true
    else
      FM_LOCK_INSPECT_STATE=unknown
      FM_LOCK_INSPECT_LIVE_HARNESS=false
    fi
    return 0
  fi
  if ps -o comm= -p "$pid" >/dev/null 2>&1; then
    FM_LOCK_INSPECT_STATE=unknown
    return 0
  fi
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_STATE=stale
  # shellcheck disable=SC2034 # Output global, read by lock status and inbox ready.
  FM_LOCK_INSPECT_LIVE_HARNESS=false
}

# --- idle fork-resume takeover ------------------------------------------------
# A holder turn newer than this is never taken over. There is no override.
FM_LOCK_TAKEOVER_QUIET_SECONDS=1800
# A transcript larger than this cannot be proved quiet, so takeover is refused.
FM_LOCK_TAKEOVER_TRANSCRIPT_MAX=$((256 * 1024 * 1024))

# True when $1 is a session id safe to place in a path and a JSON string.
# Claude conversation ids are UUIDs; anything shorter, empty, or punctuated
# stays on the ordinary refusal path.
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

# Print the start epoch of the first harness ancestor whose argv is exactly
# --fork-session plus a --resume/-r of session id $1, or return 1.
# Argv comes from Linux /proc/<pid>/cmdline so a prompt cannot look like a
# flag. Without /proc, or without a readable elapsed time, this proof is
# absent and the transcript-prefix proof is the only remaining one.
fm_session_lock_fork_epoch() {  # <recorded-session-id>
  local id=$1 pid now etimes pids='' ancestry list
  fm_session_lock_id_token "$id" || return 1
  case "${CLAUDE_PID:-}" in
    ''|*[!0-9]*) ;;
    *) pids=$CLAUDE_PID ;;
  esac
  ancestry=$(fm_harness_ancestry_pids 2>/dev/null || true)
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in
    ''|*[!0-9]*) return 1 ;;
  esac
  list=$(printf '%s\n%s\n' "$pids" "$ancestry" | awk 'NF && !seen[$0]++')
  # Pids are decimal. Splitting is the whole list.
  # shellcheck disable=SC2086
  for pid in $list; do
    [ -r "/proc/$pid/cmdline" ] || continue
    python3 - "$pid" "$id" <<'PY' || continue
import os, sys
pid, sid = sys.argv[1], sys.argv[2]
try:
    raw = open('/proc/' + pid + '/cmdline', 'rb').read(1024 * 1024)
except OSError:
    sys.exit(1)
args = [part for part in raw.decode('utf-8', 'replace').split('\0') if part]

def resumes(value):
    return value == sid or value.endswith('/' + sid) or value.endswith('/' + sid + '.jsonl')

if '--fork-session' not in args:
    sys.exit(1)
for index, arg in enumerate(args):
    if arg in ('--resume', '-r') and index + 1 < len(args) and resumes(args[index + 1]):
        sys.exit(0)
    if arg.startswith('--resume=') and resumes(arg.split('=', 1)[1]):
        sys.exit(0)
sys.exit(1)
PY
    etimes=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d '[:space:]') || return 1
    case "$etimes" in
      ''|*[!0-9]*) return 1 ;;
    esac
    printf '%s\n' $((now - etimes))
    return 0
  done
  return 1
}

# Scan holder and successor transcripts. Prints a verdict and successful turn digest:
# ok, unreadable, recent, after-fork, or not-fork.
# User and assistant rows count; summary and other rows do not. A missing
# timestamp refuses. Quiet is FM_LOCK_TAKEOVER_QUIET_SECONDS from this file.
fm_session_lock_turn_verdict() {  # <holder-path> <successor-path-or-empty> <successor-state> <fork-epoch>
  python3 - "$1" "$2" "$3" "$4" "$FM_LOCK_TAKEOVER_QUIET_SECONDS" "$FM_LOCK_TAKEOVER_TRANSCRIPT_MAX" "${5:-}" "${6:-0}" <<'PY'
import datetime, hashlib, json, os, stat, sys, time
holder_path, successor_path, successor_state, fork_s, quiet_s, cap_s, prior_path, proof_prior = sys.argv[1:9]
quiet = int(quiet_s)
cap = int(cap_s)
fork_epoch = int(fork_s)
now = time.time()

def emit(token):
    if token == 'ok':
        token += ' ' + hashlib.sha256(json.dumps([holder_path, holder, prior_path, prior]).encode()).hexdigest()
    sys.stdout.write(token + '\n')
    sys.exit(0)

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

def load(path):
    try:
        info = os.lstat(path)
    except OSError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode) or info.st_size > cap:
        return None
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError:
        return None
    turns = []
    try:
        with os.fdopen(fd, 'r', encoding='utf-8', errors='replace') as handle:
            for line in handle:
                text = line.strip()
                if not text:
                    continue
                try:
                    obj = json.loads(text)
                except json.JSONDecodeError:
                    return None
                if not isinstance(obj, dict) or obj.get('type') not in ('user', 'assistant'):
                    continue
                stamp = parse_ts(obj.get('timestamp'))
                if stamp is None:
                    return None
                uid = obj.get('uuid')
                if not isinstance(uid, str) or not uid:
                    return None
                turns.append((uid, stamp))
    except OSError:
        return None
    return turns

holder = load(holder_path)
prior = load(prior_path) if prior_path else []
if holder is None or prior is None:
    emit('unreadable')
for turns in (holder, prior):
    for _uid, stamp in turns:
        if now - stamp < quiet:
            emit('recent')
        if fork_epoch > 0 and stamp > fork_epoch:
            emit('after-fork')
if successor_state == 'ok':
    successor = load(successor_path)
    if successor is None:
        emit('ok' if fork_epoch > 0 else 'not-fork')
    histories = ([prior if proof_prior == '1' else holder]
                 if fork_epoch > 0 else [holder, prior])
    for turns in histories:
        shared = 0
        for left, right in zip(turns, successor):
            if left[0] != right[0]:
                break
            shared += 1
        if shared < len(turns):
            emit('after-fork')
    if any(histories):
        emit('ok')
    emit('ok' if fork_epoch > 0 else 'not-fork')
emit('ok' if fork_epoch > 0 else 'not-fork')
PY
}

# True only when state dir $1's live holder pid $2 can be taken by this
# fork-resume successor. Current and retained prior session transcripts must
# each be one readable regular file, with no user or assistant turn in the last
# FM_LOCK_TAKEOVER_QUIET_SECONDS and none after this process's fork. The fork
# is this process's --fork-session --resume of either id, or both histories
# being prefixes of this session's transcript with at least one shared turn. A missing python3, an
# unreadable holder, or any failed proof returns 1.
fm_session_lock_idle_fork_takeover_allowed() {  # <state> <holder-pid>
  local state=$1 holder=$2 recorded prior trusted holder_file prior_file='' succ_file succ_rc
  local fork_epoch=0 verdict succ_state=missing proof_prior=0
  case "$holder" in
    ''|*[!0-9]*) return 1 ;;
  esac
  command -v python3 >/dev/null 2>&1 || return 1
  fm_harness_pid_alive "$holder" || return 1
  fm_session_lock_read_record "$state" || return 1
  [ "$holder" = "$FM_SESSION_LOCK_PID" ] || return 1
  recorded=$FM_SESSION_LOCK_SESSION
  prior=$FM_SESSION_LOCK_PRIOR_SESSION
  fm_session_lock_id_token "$recorded" || return 1
  trusted=$(fm_session_lock_trusted_session_id) || return 1
  fm_session_lock_id_token "$trusted" || return 1
  [ "$trusted" != "$recorded" ] || return 1
  holder_file=$(fm_session_lock_transcript_file "$recorded") || return 1
  if [ -n "$prior" ]; then
    fm_session_lock_id_token "$prior" || return 1
    prior_file=$(fm_session_lock_transcript_file "$prior") || return 1
  fi
  succ_rc=0
  succ_file=$(fm_session_lock_transcript_file "$trusted") || succ_rc=$?
  case "$succ_rc" in
    0) succ_state=ok ;;
    1) succ_file='' ; succ_state=missing ;;
    *) succ_file='' ; succ_state=unreadable ;;
  esac
  if fork_epoch=$(fm_session_lock_fork_epoch "$recorded"); then
    :
  elif [ -n "$prior" ] && fork_epoch=$(fm_session_lock_fork_epoch "$prior"); then
    proof_prior=1
  else
    fork_epoch=0
  fi
  case "$fork_epoch" in
    ''|*[!0-9]*) return 1 ;;
  esac
  verdict=$(fm_session_lock_turn_verdict "$holder_file" "$succ_file" "$succ_state" "$fork_epoch" "$prior_file" "$proof_prior") || return 1
  case "$verdict" in
    'ok '*) FM_LOCK_TAKEOVER_EVIDENCE=${verdict#ok }; return 0 ;;
    *) return 1 ;;
  esac
}

# Print state=held with pid, tty and idle_seconds, or state=free/stale/unknown.
# Idle is the age of the newest readable current or prior user/assistant turn,
# falling back to process elapsed time. Tty '?' or empty is none.
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
