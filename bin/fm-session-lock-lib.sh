#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process run inside that same session?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock and its
# state/.lock-session sidecar; bin/fm-claude-stop-autoarm.sh uses it to prove a
# Stop hook fires inside the lock-owning primary session before it may arm or
# rewake. Claude and the other direct harnesses use verified ancestry or a
# trusted same-session id. Codex requires its exact live foreground client,
# process birth, and session id, because tools may run under a shared daemon.
# Missing or mismatched identity never grants ownership.
# This file is sourced by scripts and has no side effects on source.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

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

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Codex may run tool commands under a managed app-server shared by several
# foreground clients. Its process ancestry is therefore not a session owner.
# The primary launcher passes its own pid, birth, and home through Codex's
# per-thread shell_environment_policy.set; a direct Codex run can use its
# immediate Codex ancestor instead. Never accept the app-server as a client.
fm_codex_pid_birth() {  # <pid>
  local pid=$1 stat_line out
  local -a fields
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$pid/stat" ]; then
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    read -r -a fields <<< "${stat_line##*)}"
    [ "${#fields[@]}" -ge 20 ] || return 1
    case "${fields[19]}" in ''|*[!0-9]*) return 1 ;; esac
    printf 'proc:%s\n' "${fields[19]}"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf 'ps:%s\n' "${out#"${out%%[![:space:]]*}"}"
}

fm_codex_ancestry_pid() {  # [<ancestry-pids>]
  local pids=${1:-} pid comm
  [ -n "$pids" ] || pids=$(fm_harness_ancestry_pids) || return 1
  pid=${pids%%$'\n'*}
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  [ "$(basename -- "$comm")" = codex ] || return 1
  printf '%s\n' "$pid"
}

fm_codex_client_pid() {  # [<ancestry-pids>]
  local pids=${1:-} ancestor pid birth args home
  ancestor=$(fm_codex_ancestry_pid "$pids") || return 1
  if [ -n "${FM_CODEX_CLIENT_PID:-}${FM_CODEX_CLIENT_BIRTH:-}${FM_CODEX_CLIENT_HOME:-}" ]; then
    pid=${FM_CODEX_CLIENT_PID:-}
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "${FM_CODEX_CLIENT_BIRTH:-}" ] && [ -n "${FM_CODEX_CLIENT_HOME:-}" ] || return 1
    home=$(cd -P -- "${FM_HOME:-.}" 2>/dev/null && pwd -P) || return 1
    [ "$home" = "$FM_CODEX_CLIENT_HOME" ] || return 1
    birth=$(fm_codex_pid_birth "$pid") || return 1
    [ "$birth" = "$FM_CODEX_CLIENT_BIRTH" ] || return 1
  else
    pid=$ancestor
  fi
  fm_harness_pid_alive "$pid" || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null) || return 1
  case " $args " in *' app-server '*|*' exec-server '*) return 1 ;; esac
  printf '%s\n' "$pid"
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
# A --fork-session successor mints a new id, so it stays a foreign live owner
# until the pre-fork process exits; that is the safe direction and a documented
# non-goal. Two genuinely different live sessions sharing one id is not a
# supported state (Claude refuses to resume a running session under its id).

# Print a trusted Claude or Codex session identity, or return 1. $1 is an
# ancestry list an earlier walk already produced.
fm_session_lock_trusted_session_id() {  # [<ancestry-pids>]
  local id=${CLAUDE_CODE_SESSION_ID:-} claude_pid=${CLAUDE_PID:-} pids=${1:-} pid comm args birth
  if [ -z "$pids" ]; then
    pids=$(fm_harness_ancestry_pids) || return 1
  fi
  # A Codex launched inside a Claude pane can inherit Claude's variables.
  # An untrusted Claude claim must not prevent the Codex trust gate below.
  if [ -n "$id" ] && [[ "$id" != *$'\n'* && "$id" != *$'\r'* ]] \
    && [[ "$claude_pid" =~ ^[0-9]+$ ]]; then
    while IFS= read -r pid; do
      [ "$pid" = "$claude_pid" ] || continue
      comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      fm_harness_process_matches "$comm" "$args" || break
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      printf '%s\n' "$id"
      return 0
    done <<EOF
$pids
EOF
  fi
  id=${CODEX_SESSION_ID:-}
  [ -n "$id" ] || return 1
  case "$id" in *$'\n'*|*$'\r'*) return 1 ;; esac
  pid=$(fm_codex_client_pid "$pids") || return 1
  birth=$(fm_codex_pid_birth "$pid") || return 1
  printf 'codex:%s:%s:%s\n' "$pid" "$birth" "$id"
}

# A Codex sidecar pins both the session and the foreground client's birth.
# This makes a recycled pid stale even when its command is again `codex`.
# A shared Codex app-server or exec-server outlives every client, so it never
# holds a lock even when an older release recorded it on line 1.
fm_session_lock_holder_alive() {  # <state> <pid>
  local state=$1 pid=$2 recorded prefix birth comm
  fm_harness_pid_alive "$pid" || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  if [ "$(basename -- "$comm")" = codex ]; then
    case " $(ps -o args= -p "$pid" 2>/dev/null) " in *' app-server '*|*' exec-server '*) return 1 ;; esac
  fi
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 0
  case "$recorded" in
    codex:"$pid":*)
      birth=$(fm_codex_pid_birth "$pid") || return 1
      prefix="codex:$pid:$birth:"
      case "$recorded" in "$prefix"*) return 0 ;; *) return 1 ;; esac
      ;;
    codex:*) return 1 ;;
  esac
  return 0
}

fm_session_lock_codex_same_client() {  # <state> <ancestry-pids>
  local state=$1 pids=$2 lock_pid client recorded trusted
  client=$(fm_codex_client_pid "$pids") || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  [ "$lock_pid" = "$client" ] || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  trusted=$(fm_session_lock_trusted_session_id "$pids") || return 1
  [ "$recorded" = "$trusted" ]
}

# The foreground checkpoint marks only the handling interval after a normal
# return. Its one-line record is the exact Codex lock-session value, which pins
# the session and live client's birth. Starting another checkpoint clears the
# prior interval before it runs, so a failed cycle cannot inherit old proof.
fm_codex_checkpoint_begin() {  # <state>
  local state=$1 recorded
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  case "$recorded" in codex:*) : ;; *) return 1 ;; esac
  fm_session_lock_owned_by_self "$state" || return 1
  rm -f "$state/.codex-checkpoint-handling"
}

fm_codex_checkpoint_finish() {  # <state>
  local state=$1 recorded tmp
  fm_session_lock_owned_by_self "$state" || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  case "$recorded" in codex:*) : ;; *) return 1 ;; esac
  tmp=$(mktemp "$state/.codex-checkpoint-handling.XXXXXX") || return 1
  if ! { printf '%s\n' "$recorded" > "$tmp" && mv -f "$tmp" "$state/.codex-checkpoint-handling"; }; then
    rm -f "$tmp"
    return 1
  fi
}

fm_codex_checkpoint_owns_supervision() {  # <state>
  local state=$1 marker recorded pid
  [ -f "$state/.codex-checkpoint-handling" ] && [ ! -L "$state/.codex-checkpoint-handling" ] || return 1
  marker=$(cat "$state/.codex-checkpoint-handling" 2>/dev/null) || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  case "$recorded" in codex:*) : ;; *) return 1 ;; esac
  [ "$marker" = "$recorded" ] || return 1
  pid=$(cat "$state/.lock" 2>/dev/null) || return 1
  fm_session_lock_holder_alive "$state" "$pid"
}

# Print the session id recorded beside the lock in state dir $1, or return 1.
# bin/fm-lock.sh is the only writer of state/.lock-session; a missing,
# symlinked, unreadable, or empty sidecar, or one whose first line contains a
# newline or carriage return, is simply no recorded id.
fm_session_lock_recorded_session_id() {  # <state>
  local state=$1 recorded
  [ -f "$state/.lock-session" ] && [ ! -L "$state/.lock-session" ] || return 1
  recorded=$(head -n 1 "$state/.lock-session" 2>/dev/null) || return 1
  [ -n "$recorded" ] || return 1
  case "$recorded" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s\n' "$recorded"
}

# True when the lock in state dir $1 was recorded by this same Claude session:
# the trusted id equals the id recorded beside the lock. No trusted id, no
# sidecar, or a different recorded id is false.
fm_session_lock_same_session() {  # <state> [<ancestry-pids>]
  local state=$1 trusted recorded
  trusted=$(fm_session_lock_trusted_session_id "${2:-}") || return 1
  recorded=$(fm_session_lock_recorded_session_id "$state") || return 1
  [ "$recorded" = "$trusted" ]
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
  if fm_codex_ancestry_pid "$pids" >/dev/null; then
    fm_session_lock_trusted_session_id "$pids" >/dev/null || return 1
    fm_codex_client_pid "$pids"
    return $?
  fi
  if fm_session_lock_trusted_session_id "$pids" >/dev/null; then
    printf '%s\n' "$CLAUDE_PID"
    return 0
  fi
  _fm_harness_outermost_pid "$pids"
}

# True when state dir $1 holds a session lock that this process's session owns.
# Codex requires an exact live client pid, birth, and session id match. Other
# harnesses use ancestry membership or their trusted session id. Membership is
# the honest ancestry test for Claude, because the lock owner
# sits at an unknown depth in a contiguous Claude run - it is the outermost pid
# when the hook fires inside the session's own nested worker chain, and an inner
# pid when a harness-named daemon parents the session. The same-session path
# requires the recorded pid alive so that a dead one is reclaimed through
# bin/fm-lock.sh's ordinary stale-owner path, which refreshes line 1, rather than
# silently owned with a dead anchor. A missing lock, a malformed lock, a lock
# held by a harness outside this ancestry under another (or no) session id, or
# an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_codex_ancestry_pid "$pids" >/dev/null; then
    fm_session_lock_codex_same_client "$state" "$pids"
    return $?
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" || return 1
  fm_harness_pid_alive "$lock_pid"
}

# True when state dir $1 records a live verified harness outside this process's
# owned session. Sets FM_SESSION_LOCK_FOREIGN_OWNER_PID for a diagnostic caller.
# Malformed, missing, dead, and ancestry-uncertain locks are not foreign-owner
# evidence.
# shellcheck disable=SC2034 # Output global, read by the sourcing guard caller.
FM_SESSION_LOCK_FOREIGN_OWNER_PID=
fm_session_lock_foreign_owner_live() {
  local state=$1 lock_pid pids pid
  FM_SESSION_LOCK_FOREIGN_OWNER_PID=
  [ -f "$state/.lock" ] && [ ! -L "$state/.lock" ] || return 1
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_session_lock_holder_alive "$state" "$lock_pid" || return 1
  pids=$(fm_harness_ancestry_pids) || return 1
  if fm_codex_ancestry_pid "$pids" >/dev/null; then
    fm_session_lock_codex_same_client "$state" "$pids" && return 1
    FM_SESSION_LOCK_FOREIGN_OWNER_PID=$lock_pid
    return 0
  fi
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 1
  done <<EOF
$pids
EOF
  fm_session_lock_same_session "$state" "$pids" && return 1
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
    if fm_session_lock_holder_alive "$state" "$pid"; then
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
