#!/usr/bin/env bash
set -eu
root=$1
base=$2
mode=$3
STATE="$FM_HOME/state"
export STATE
. "$root/bin/fm-secondmate-liveness-lib.sh"
fm_sm_live_require_locks
lock="$STATE/.spawn-sm-live.lock"
fm_lock_try_acquire "$lock"
trap 'fm_lock_release "$lock"' EXIT
touch "$base/collision-start"
printf 'competing launch holds spawn lock\n'
for ((i=0; i<1800; i++)); do
  if [ "$STATE/sm-live.control-relaunch" -nt "$base/collision-start" ] && grep -q '^phase=failed:launching' "$STATE/sm-live.control-relaunch"; then
    break
  fi
  sleep 0.1
done
[ "$i" -lt 1800 ] || { echo 'restart did not reach collision'; exit 1; }
printf 'restart lost spawn lock; stopped endpoint state=%s\n' "$(fm_backend_agent_state tmux primary:fm-sm-live)"
fm_lock_release "$lock"
trap - EXIT
if [ "$mode" = probe-hang ]; then
  server_pid=$(cut -d, -f2 "$base/tmux-env")
  kill -STOP "$server_pid"
  touch "$base/probe-frozen"
  printf 'private tmux server %s stopped to stall the real endpoint probe\n' "$server_pid"
  while [ ! -e "$base/resume-probe" ]; do sleep 0.1; done
  kill -CONT "$server_pid"
  printf 'private tmux server resumed\n'
  exit 0
fi
fm_backend_kill tmux primary:fm-sm-live
if [ "$mode" = gate-failed ]; then
  touch "$base/enable-hooks"
  export FM_CODEX_FIRST_TURN_POLLS=8
else
  export FM_CODEX_FIRST_TURN_POLLS=120
fi
rc=0
"$root/bin/fm-spawn.sh" sm-live "$base/secondmate" --secondmate || rc=$?
printf 'winner completed with exit=%s; endpoint state=%s\n' "$rc" "$(fm_backend_agent_state tmux primary:fm-sm-live)"
printf '%s\n' "$rc" > "$base/winner.rc"
exit "$rc"
