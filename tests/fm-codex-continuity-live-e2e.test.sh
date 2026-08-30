#!/usr/bin/env bash
# Opt-in credentialed Codex/Herdr regression for the persistent turn-end
# successor. Every Herdr operation, including production-adapter calls, routes
# through the named non-default lab helper and its default-fleet tripwire.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

GIT_DIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null) \
  || { echo "skip: cannot confirm an updated plain primary checkout"; exit 0; }
GIT_COMMON_DIR=$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || { echo "skip: cannot confirm an updated plain primary checkout"; exit 0; }
if [ "$GIT_DIR" != "$GIT_COMMON_DIR" ]; then
  echo "skip: Codex continuity live proof requires an updated plain primary checkout"
  exit 0
fi
command -v jq >/dev/null 2>&1 \
  || { echo "skip: cannot inspect the tracked plain-primary Stop registration without jq"; exit 0; }
TRACKED_HOOKS=$(git -C "$ROOT" show HEAD:.codex/hooks.json 2>/dev/null) \
  || { echo "skip: plain primary has no tracked Codex hook registration"; exit 0; }
if ! jq -e '
  any(.hooks.Stop[]?.hooks[]?.command?;
    type == "string" and contains("fm-turnend-guard.sh") and contains("--codex"))
' <<< "$TRACKED_HOOKS" >/dev/null 2>&1; then
  echo "skip: plain primary tracked Stop registration does not contain --codex"
  exit 0
fi

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
for tool in codex herdr; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool not found"
done
[ -x "$HERDR_LAB_HELPER" ] || fail "Herdr lab helper is not executable at $HERDR_LAB_HELPER"

REAL_CODEX=$(command -v codex)
ORIGINAL_PATH=$PATH
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name firstmate-codex-successor-adapter) \
  || fail "could not generate an isolated Herdr session name"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-successor-live.XXXXXX")
HOME_DIR="$LAB/fmhome"
FAKEBIN="$LAB/fakebin"
LAUNCH_SCRIPT="$LAB/launch-codex.sh"
CODEX_VERSION=$($REAL_CODEX --version)

# Installed before provisioning, as required by the Herdr lab safety contract.
trap '"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" \
  || fail "could not provision the isolated Herdr lab session"

mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"

# Production adapters append a trailing --session pair. Strip only that exact
# lab identity, then delegate to the helper, which appends it again itself.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -lt 2 ] || [ "\${args[\$((n-2))]}" != --session ]; then
  echo "wrapper requires a trailing isolated --session" >&2
  exit 98
fi
[ "\${args[\$((n-1))]}" = "$HERDR_LAB_SESSION" ] \
  || { echo "wrapper refused a foreign session" >&2; exit 97; }
args=("\${args[@]:0:\$((n-2))}")
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

lab() {
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
}

CAPTAIN_JSON=$(lab workspace create --cwd "$ROOT" --label codex-captain --no-focus) \
  || fail "could not create the isolated Codex workspace"
CAPTAIN_PANE=$(printf '%s' "$CAPTAIN_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "Codex workspace did not return a pane id"
CAPTAIN_TARGET="$HERDR_LAB_SESSION:$CAPTAIN_PANE"

for task in 1 2 3 4 5; do
  : > "$HOME_DIR/state/task${task}.meta"
done

# Literal backticks are prompt syntax, not shell expansion.
# shellcheck disable=SC2016
PROMPT='Run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as one foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After it expires, reply with exactly CHECKPOINT_DONE.'
TRACKED_DIFF_BEFORE=$(git -C "$ROOT" diff --binary HEAD | sha256sum | awk '{print $1}')
{
  printf '#!/usr/bin/env bash\nset -u\n'
  printf 'printf "%%s\\n" "\$\$" > %q\n' "$HOME_DIR/state/.lock"
  printf 'exec env PATH=%q FM_HOME=%q FM_ROOT_OVERRIDE=%q FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET=%q HERDR_ENV=1 HERDR_SESSION=%q HERDR_PANE_ID=%q FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_INJECT_CONFIRM_SLEEP=0.1 FM_GUARD_GRACE=30 %q --no-alt-screen --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c %q %q\n' \
    "$FAKEBIN:$ORIGINAL_PATH" "$HOME_DIR" "$ROOT" "$CAPTAIN_TARGET" \
    "$HERDR_LAB_SESSION" "$CAPTAIN_PANE" "$REAL_CODEX" \
    'model_reasoning_effort="low"' "$PROMPT"
} > "$LAUNCH_SCRIPT"
chmod +x "$LAUNCH_SCRIPT"

printf -v START_COMMAND 'exec %q' "$LAUNCH_SCRIPT"
lab pane run "$CAPTAIN_PANE" "$START_COMMAND" >/dev/null \
  || fail "could not launch Codex in the isolated Herdr pane"

read_screen() {
  lab pane read "$CAPTAIN_PANE" --source recent --lines 400 2>/dev/null || true
}

wait_for_screen() {  # <needle> [attempts]
  local needle=$1 attempts=${2:-360} i=0
  while [ "$i" -lt "$attempts" ]; do
    read_screen | grep -Fq "$needle" && return 0
    sleep 0.5
    i=$((i + 1))
  done
  read_screen >&2
  return 1
}

wait_for_screen_occurrences() {  # <needle> <count> [attempts]
  local needle=$1 count=$2 attempts=${3:-360} i=0 seen
  while [ "$i" -lt "$attempts" ]; do
    seen=$(read_screen | grep -Fo "$needle" | wc -l | tr -d ' ')
    [ "$seen" -ge "$count" ] && return 0
    sleep 0.5
    i=$((i + 1))
  done
  read_screen >&2
  return 1
}

wait_for_successor() {
  local i=0 daemon_pid watcher_pid watcher_ppid
  while [ "$i" -lt 240 ]; do
    daemon_pid=$(cat "$HOME_DIR/state/.supervise-daemon.lock/pid" 2>/dev/null || true)
    watcher_pid=$(cat "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
    watcher_ppid=$(ps -o ppid= -p "$watcher_pid" 2>/dev/null | tr -d '[:space:]' || true)
    if [ -n "$daemon_pid" ] && [ -n "$watcher_pid" ] \
      && [ "$watcher_ppid" = "$daemon_pid" ] \
      && kill -0 "$daemon_pid" 2>/dev/null \
      && kill -0 "$watcher_pid" 2>/dev/null; then
      return 0
    fi
    sleep 0.5
    i=$((i + 1))
  done
  return 1
}

wait_for_screen 'checkpoint: no actionable wake within 1s' 360 \
  || fail "Codex did not complete the real bounded foreground checkpoint"
wait_for_screen CHECKPOINT_DONE 360 \
  || fail "Codex did not finish the checkpoint turn"
wait_for_successor \
  || fail "turn-end did not establish a daemon-owned watcher successor"

[ "$(find "$HOME_DIR/state" -maxdepth 1 -name '*.meta' | wc -l | tr -d ' ')" = 5 ] \
  || fail "checkpoint handoff did not preserve all five in-flight tasks"
[ "$(awk -F '\t' 'NR == 1 { print NF }' "$HOME_DIR/state/.afk-daemon-terminal")" = 7 ] \
  || fail "persistent successor terminal record is not the attended ownership shape"
[ "$(cut -f7 "$HOME_DIR/state/.afk-daemon-terminal")" = "$CAPTAIN_TARGET" ] \
  || fail "successor is not bound to the isolated captain-facing session"

successor_count=$(lab workspace list | jq --arg prefix 'firstmate-afk-daemon-' \
  '[.result.workspaces[]? | select(.label | startswith($prefix))] | length')
[ "$successor_count" = 1 ] || fail "expected exactly one successor workspace, found $successor_count"
DAEMON_PID=$(cat "$HOME_DIR/state/.supervise-daemon.lock/pid")

# A real captain turn remains possible while the persistent owner stays active.
CONTROL_TOKEN="CODEX_CONTROL_$$_$RANDOM"
lab pane send-text "$CAPTAIN_PANE" "Reply with exactly $CONTROL_TOKEN." >/dev/null
lab pane send-keys "$CAPTAIN_PANE" enter >/dev/null
wait_for_screen_occurrences "$CONTROL_TOKEN" 2 360 \
  || fail "captain control did not return while the successor stayed active"
wait_for_successor || fail "successor disappeared after a captain turn"
[ "$(cat "$HOME_DIR/state/.supervise-daemon.lock/pid")" = "$DAEMON_PID" ] \
  || fail "captain turn replaced the persistent successor instead of reusing it"

# This token can reach the pane only through the daemon's watcher/drain/inject path.
WAKE_TOKEN="CODEX_SUCCESSOR_WAKE_$$_$RANDOM"
printf 'done: %s\n' "$WAKE_TOKEN" >> "$HOME_DIR/state/task1.status"
wait_for_screen "$WAKE_TOKEN" 360 \
  || fail "later synthetic worker wake did not reach the same Codex session"
wait_for_successor || fail "successor did not remain healthy after wake delivery"
[ "$(cat "$HOME_DIR/state/.supervise-daemon.lock/pid")" = "$DAEMON_PID" ] \
  || fail "wake delivery created a replacement daemon"
[ "$(ps -o ppid= -p "$(cat "$HOME_DIR/state/.watch.lock/pid")" | tr -d '[:space:]')" = "$DAEMON_PID" ] \
  || fail "wake delivery left a watcher outside the one persistent successor"
successor_count=$(lab workspace list | jq --arg prefix 'firstmate-afk-daemon-' \
  '[.result.workspaces[]? | select(.label | startswith($prefix))] | length')
[ "$successor_count" = 1 ] || fail "wake handling left $successor_count successor workspaces"
[ ! -s "$HOME_DIR/state/.wake-queue" ] \
  || fail "generation-bound wake acknowledgement did not drain the delivered wake"

PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" \
  "$ROOT/bin/fm-afk-launch.sh" stop-attended-codex >/dev/null 2>&1 \
  || fail "attended successor teardown failed"
[ ! -e "$HOME_DIR/state/.supervise-daemon.lock" ] \
  || fail "successor daemon lock survived exact teardown"
[ ! -e "$HOME_DIR/state/.watch.lock" ] \
  || fail "successor watcher lock survived exact teardown"
[ ! -e "$HOME_DIR/state/.afk-daemon-terminal" ] \
  || fail "successor terminal ownership record survived exact teardown"
successor_count=$(lab workspace list | jq --arg prefix 'firstmate-afk-daemon-' \
  '[.result.workspaces[]? | select(.label | startswith($prefix))] | length')
[ "$successor_count" = 0 ] || fail "successor workspace survived exact teardown"

TRACKED_DIFF_AFTER=$(git -C "$ROOT" diff --binary HEAD | sha256sum | awk '{print $1}')
[ "$TRACKED_DIFF_AFTER" = "$TRACKED_DIFF_BEFORE" ] \
  || fail "read-only Codex live turn mutated the task worktree tracked diff"

"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" \
  || fail "isolated Herdr teardown or default-fleet tripwire failed"
trap - EXIT
rm -rf "$LAB"

printf 'ok - %s live E2E proved checkpoint expiry, exact turn-end handoff, captain control, later same-session wake delivery, one successor, and clean isolated teardown\n' "$CODEX_VERSION"
