#!/usr/bin/env bash
# Opt-in post-merge Codex successor lifecycle proof.
#
# Run only from an updated plain main checkout.
# Every Herdr call is constrained to a generated non-default lab session, and
# teardown verifies that the running default session stayed byte-identical.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
case "$LAB_HELPER" in
  /*) ;;
  *) LAB_HELPER="$ROOT/${LAB_HELPER#./}" ;;
esac

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 after merge/update to run the Codex successor lifecycle proof"
  exit 0
fi

for tool in codex git herdr jq ps; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done
[ -x "$LAB_HELPER" ] || fail "Herdr lab helper is not executable at $LAB_HELPER"
[ -d "$ROOT/.git" ] || fail "run only from an updated plain primary checkout, not a linked worktree"
[ "$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null)" = main ] \
  || fail "run only from the updated main branch"
git -C "$ROOT" diff --quiet --no-ext-diff \
  || fail "tracked primary checkout changes would make the live result ambiguous"
git -C "$ROOT" diff --cached --quiet --no-ext-diff \
  || fail "staged primary checkout changes would make the live result ambiguous"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name codex-successor)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-codex-successor.XXXXXX")
HOME_DIR="$TMP_ROOT/home"
STATE="$HOME_DIR/state"
CONFIG="$HOME_DIR/config"
FAKEBIN="$TMP_ROOT/fakebin"
LAUNCHER="$TMP_ROOT/launch-codex"
FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"
export FM_HERDR_LAB_STATE_DIR
TARGET=
DAEMON_STARTED=0
OWNER_SESSION_PID=
OWNER_SESSION_IDENTITY=

cleanup() {
  local status=$?
  trap - EXIT
  if [ "$DAEMON_STARTED" -eq 1 ]; then
    PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
      FM_CONFIG_OVERRIDE="$CONFIG" FM_ROOT_OVERRIDE="$ROOT" \
      FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
      "$ROOT/bin/fm-afk-launch.sh" stop-attended-codex \
        "$OWNER_SESSION_PID" "$OWNER_SESSION_IDENTITY" >/dev/null 2>&1 || true
  fi
  if [ -e "$FM_HERDR_LAB_STATE_DIR/$SESSION.fleet-state.json" ]; then
    if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
      status=1
    fi
  fi
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT

mkdir -p "$STATE" "$CONFIG" "$FAKEBIN"
printf 'window=synthetic\nbackend=herdr\nkind=ship\n' > "$STATE/task1.meta"

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -eu
helper='$LAB_HELPER'
session='$SESSION'
real_path='$ORIGINAL_PATH'
args=("\$@")
count=\${#args[@]}
if [ "\$count" -lt 2 ] || [ "\${args[\$((count - 2))]}" != --session ]; then
  echo "Codex lab wrapper requires a trailing --session" >&2
  exit 98
fi
[ "\${args[\$((count - 1))]}" = "\$session" ] || {
  echo "Codex lab wrapper refused a foreign session" >&2
  exit 97
}
args=("\${args[@]:0:\$((count - 2))}")
exec env PATH="\$real_path" "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

PATH="$ORIGINAL_PATH" "$LAB_HELPER" provision "$SESSION" \
  || fail "could not provision isolated Herdr lab session $SESSION"

lab() {
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"
}

WORKSPACE_JSON=$(lab workspace create --cwd "$ROOT" --label codex-successor --no-focus) \
  || fail "could not create the captain workspace"
PANE=$(printf '%s' "$WORKSPACE_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "captain workspace did not return a pane id"
TARGET="$SESSION:$PANE"

cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
set -eu
cd '$ROOT'
export PATH='$FAKEBIN:$ORIGINAL_PATH'
export FM_HOME='$HOME_DIR'
export FM_STATE_OVERRIDE='$STATE'
export FM_CONFIG_OVERRIDE='$CONFIG'
export FM_ROOT_OVERRIDE='$ROOT'
export FM_SUPERVISOR_BACKEND=herdr
export FM_SUPERVISOR_TARGET='$TARGET'
export HERDR_SESSION='$SESSION'
printf '%s\n' "\$\$" > '$STATE/.lock'
exec codex --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c 'model_reasoning_effort="low"'
EOF
chmod +x "$LAUNCHER"

lab pane run "$PANE" "$LAUNCHER" >/dev/null \
  || fail "could not launch interactive Codex in $TARGET"

wait_for_idle() {
  local status stable=0 attempt=0
  while [ "$attempt" -lt 240 ]; do
    status=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty' 2>/dev/null || true)
    case "$status" in
      idle|done|blocked)
        stable=$((stable + 1))
        [ "$stable" -ge 3 ] && return 0
        ;;
      *) stable=0 ;;
    esac
    attempt=$((attempt + 1))
    sleep 0.25
  done
  return 1
}

wait_for_screen() {
  local needle=$1 screen attempt=0
  while [ "$attempt" -lt 360 ]; do
    screen=$(lab pane read "$PANE" --source recent --lines 500 2>/dev/null || true)
    if printf '%s\n' "$screen" | grep -F "$needle" >/dev/null 2>&1; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
  done
  return 1
}

daemon_owner_path() {
  local lock="$STATE/.supervise-daemon.lock" owner
  if [ -L "$lock" ]; then
    owner=$(readlink "$lock" 2>/dev/null) || return 1
    case "$owner" in
      /*) printf '%s\n' "$owner" ;;
      *) printf '%s/%s\n' "$STATE" "$owner" ;;
    esac
    return
  fi
  [ -d "$lock" ] || return 1
  printf '%s\n' "$lock"
}

successor_ready() {
  local owner owner_record terminal_record
  local mode session_id session_pid session_identity backend target
  local terminal_backend terminal_target terminal_extra current_identity
  owner=$(daemon_owner_path) || return 1
  owner_record=$(cat "$owner/supervision-owner" 2>/dev/null) || return 1
  IFS=$'\t' read -r mode session_id session_pid session_identity backend target <<< "$owner_record"
  [ "$mode" = attended-codex ] || return 1
  [ "$backend" = herdr ] || return 1
  [ "$target" = "$TARGET" ] || return 1
  [ "$session_pid" = "$(cat "$STATE/.lock" 2>/dev/null)" ] || return 1
  current_identity=$(
    FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" bash -c \
      '. "$1/bin/fm-wake-lib.sh"; fm_pid_identity "$2"' _ "$ROOT" "$session_pid"
  ) || return 1
  [ "$session_identity" = "$current_identity" ] || return 1
  terminal_record=$(cat "$STATE/.afk-daemon-terminal" 2>/dev/null) || return 1
  IFS=$'\t' read -r terminal_backend terminal_target terminal_extra <<< "$terminal_record"
  [ "$terminal_backend" = herdr ] || return 1
  PATH="$FAKEBIN:$ORIGINAL_PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
    FM_CONFIG_OVERRIDE="$CONFIG" FM_ROOT_OVERRIDE="$ROOT" \
    FM_SUPERVISOR_BACKEND=herdr FM_SUPERVISOR_TARGET="$TARGET" \
    FM_SUPERVISION_DELIVERY_MODE=attended-codex \
    FM_SUPERVISION_SESSION_ID="$session_id" \
    FM_SUPERVISION_SESSION_PID="$session_pid" \
    FM_SUPERVISION_SESSION_PID_IDENTITY="$session_identity" \
    bash -c '. "$1"; fm_afk_launch_successor_ready "$2" "$3"' \
      _ "$ROOT/bin/fm-afk-launch.sh" "$terminal_backend" "$terminal_target"
}

wait_for_successor() {
  local attempt=0
  while [ "$attempt" -lt 240 ]; do
    successor_ready && return 0
    attempt=$((attempt + 1))
    sleep 0.25
  done
  return 1
}

wait_for_idle || fail "Codex never became idle in the isolated captain pane"

FIRST_TOKEN="CODEX_SUCCESSOR_HANDOFF_$$_$RANDOM"
FIRST_PROMPT="Run exactly \`bin/fm-watch-checkpoint.sh --seconds 1\` as one foreground shell call. Do not background it and do not run fm-watch-arm.sh. After it returns, reply exactly $FIRST_TOKEN."
lab pane send-text "$PANE" "$FIRST_PROMPT" >/dev/null \
  || fail "could not type the checkpoint prompt"
lab pane send-keys "$PANE" enter >/dev/null \
  || fail "could not submit the checkpoint prompt"
wait_for_screen 'checkpoint: no actionable wake within 1s' \
  || fail "Codex pane never rendered the real quiet checkpoint expiry"
wait_for_screen "$FIRST_TOKEN" \
  || fail "Codex did not finish the checkpoint turn"
wait_for_successor \
  || fail "Stop returned without an identity-matched daemon-owned healthy watcher"
OWNER=$(daemon_owner_path) || fail "successor daemon lock disappeared"
DAEMON_PID=$(cat "$OWNER/pid" 2>/dev/null) || fail "successor daemon pid is unreadable"
IFS=$'\t' read -r _ _ OWNER_SESSION_PID OWNER_SESSION_IDENTITY _ _ \
  < "$OWNER/supervision-owner" || fail "successor session identity is unreadable"
DAEMON_STARTED=1
pass "quiet checkpoint expiry handed off to one verified persistent successor"

wait_for_idle || fail "Codex did not return to an available captain conversation"
SECOND_TOKEN="CODEX_CONVERSATION_AVAILABLE_$$_$RANDOM"
lab pane send-text "$PANE" "Reply exactly $SECOND_TOKEN." >/dev/null \
  || fail "could not type the second captain prompt"
lab pane send-keys "$PANE" enter >/dev/null \
  || fail "could not submit the second captain prompt"
wait_for_screen "$SECOND_TOKEN" \
  || fail "captain conversation did not remain available after successor handoff"
wait_for_successor \
  || fail "successor became unhealthy after the next captain turn"
OWNER=$(daemon_owner_path) || fail "successor daemon lock disappeared after the next turn"
[ "$(cat "$OWNER/pid" 2>/dev/null)" = "$DAEMON_PID" ] \
  || fail "the next captain turn created a duplicate successor daemon"
pass "captain conversation remained available with one stable successor owner"

wait_for_idle || fail "Codex did not become idle before the actionable wake"
printf 'done: live Codex successor wake\n' > "$STATE/task1.status"
wait_for_screen 'FIRSTMATE_OP: v1 watcher:' \
  || fail "the one-shot watcher did not deliver an attended operational wake to the same captain pane"
pass "attended watcher wake returned through $TARGET"

CODEX_VERSION=$(PATH="$ORIGINAL_PATH" codex --version 2>/dev/null | head -1 || printf version-unknown)
printf 'evidence: codex=%s lab=%s default_fleet_tripwire=verified_on_teardown\n' \
  "$CODEX_VERSION" "$SESSION"
