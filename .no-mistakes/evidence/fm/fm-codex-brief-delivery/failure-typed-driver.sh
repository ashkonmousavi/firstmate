#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M68KXX3H4JNA1PRSRSK0RV34
AUTH_SOURCE=${CODEX_HOME:-$HOME/.codex}/auth.json
LAB=$ROOT/.v/h
[ -f "$LAB/.fm-lab-home" ] || bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/t" "$ROOT/.v/os" "$ROOT/.v/codex" "$ROOT/.v/pool" "$ROOT/.v/xdg" "$ROOT/.v/noauth"
# Use the existing login only, in a disposable copy so token refresh and trust
# decisions cannot change the production credential/configuration store.
install -m 600 "$AUTH_SOURCE" "$ROOT/.v/codex/auth.json"
export HOME=$ROOT/.v/os CODEX_HOME=$ROOT/.v/codex
export XDG_CONFIG_HOME=$ROOT/.v/xdg/config XDG_DATA_HOME=$ROOT/.v/xdg/data XDG_STATE_HOME=$ROOT/.v/xdg/state XDG_CACHE_HOME=$ROOT/.v/xdg/cache
export PATH=$ROOT/.v/tool/node_modules/.bin:$PATH TREEHOUSE_ROOT=$ROOT/.v/pool
export TMPDIR=$ROOT/.v/tmp TMUX_TMPDIR=$LAB/t
export FM_HOME=$LAB
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
unset TASKS_AXI_FILE TASKS_AXI_BACKEND HERDR_ENV HERDR_PANE_ID HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
}
trap cleanup EXIT
printf '999999 0\n' > "$LAB/config/lane-capacity"
printf 'manual\n' > "$LAB/config/backlog-backend"
jq -n --arg path "$LAB" '{schema:"fm-machine-admission.v1",memory_floor_gib:0,memory_full_avg60_max:5,disk_floor_gib:0,disk_paths:[$path]}' > "$LAB/config/machine-admission.json"
PROJ=$ROOT/.v/scratch
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab -f /dev/null new-session -d -s firstmate -x 180 -y 48 -c "$PROJ" 'bash --noprofile --norc'
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
printf 'Version: '; codex --version
codex login status
write_brief() {
  local id=$1 expected=$2
  mkdir -p "$LAB/data/$id"
  cat > "$LAB/data/$id/brief.md" <<EOF
# Task
## Captain's intent
For this disposable launch test, reply with exactly: $expected

## Firstmate spec
Do not change any project files. Reply once with the exact marker above, then stop. No additional work is authorized.
EOF
}
capture() {
  local id=$1 label=$2 t
  t=$(sed -n 's/^window=//p' "$LAB/state/$id.meta" | tail -1)
  [ -n "$t" ] || return 1
  tmux -L fm-lab capture-pane -p -t "$t" -S -1000 > "$E/$label.pane.txt"
  tmux -L fm-lab capture-pane -p -e -t "$t" -S -0 > "$E/$label.visible.ansi"
}
spawn() {
  local id=$1 label=$2; shift 2
  local start=$SECONDS rc=0
  timeout 180 "$ROOT/bin/fm-spawn.sh" "$id" "$@" > "$E/$label.spawn.txt" 2>&1 || rc=$?
  printf '%s exit=%s elapsed=%ss\n' "$label" "$rc" "$((SECONDS-start))" | tee -a "$E/live-results.txt"
  cat "$E/$label.spawn.txt"
  capture "$id" "$label" || true
  return "$rc"
}
await_reply() {
  local id=$1 expected=$2 label=$3
  for ((i=0;i<100;i++)); do
    capture "$id" "$label"
    if awk -v expected="$expected" '$1 == "•" && $2 == expected && NF == 2 {found=1} END{exit !found}' "$E/$label.pane.txt"; then
      printf '%s reply=%s\n' "$label" "$expected" | tee -a "$E/live-results.txt"
      cp "$LAB/state/$id.meta" "$E/$label.meta.txt"
      return 0
    fi
    sleep 1
  done
  printf '%s missing assistant reply\n' "$label" | tee -a "$E/live-results.txt"
  return 1
}
# Missing login is a real startup condition: do not answer its sign-in UI.
tmux -L fm-lab set-environment -g CODEX_HOME "$ROOT/.v/noauth"
write_brief unauth-typed LIVE_MUST_NOT_START
export FM_CODEX_FIRST_TURN_POLLS=15 FM_CODEX_POLL_INTERVAL=0.5
if spawn unauth-typed unauth-typed "$PROJ" --scout --harness codex --backend tmux --model gpt-6-astra --effort xhigh; then
  printf 'ERROR: unauthenticated launch incorrectly reported success\n' | tee -a "$E/live-results.txt"
  exit 1
fi
cp "$LAB/state/unauth-typed.status" "$E/unauth-typed.status.txt"
grep -F 'codex did not take the brief' "$E/unauth-typed.spawn.txt"
grep -F 'failed [at=' "$E/unauth-typed.status.txt"
printf 'unauthenticated launch was refused and failure persisted\n' | tee -a "$E/live-results.txt"
cleanup
trap - EXIT
