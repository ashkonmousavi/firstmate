#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M68YZ3V3MCTBD3KN3E967737
export LAB_SESSION=fm-lab-dg LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh" ORIGINAL_PATH="$PATH"
export XDG_CONFIG_HOME=.x XDG_STATE_HOME="$ROOT/.doorbell-lab/xdg-state" XDG_CACHE_HOME="$ROOT/.doorbell-lab/cache" XDG_DATA_HOME="$ROOT/.doorbell-lab/data"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.doorbell-lab/tripwire-local" TMPDIR="$ROOT/.doorbell-lab/tmp"
export TEST_ROOT="$ROOT/.doorbell-lab" TEST_EVIDENCE="$EVIDENCE"
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
LAB="$ROOT/.doorbell-lab/home"
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_TASK_INBOX="$LAB/state/doorbell.inbox"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
CLAUDE_PID= BACKGROUND=
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }
cleanup() {
  status=$?
  trap - EXIT
  [ -z "$CLAUDE_PID" ] || kill -CONT "$CLAUDE_PID" 2>/dev/null || true
  [ -z "$BACKGROUND" ] || { kill "$BACKGROUND" 2>/dev/null || true; wait "$BACKGROUND" 2>/dev/null || true; }
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$LAB_SESSION" || status=1
  printf 'TEARDOWN exit=%s\n' "$status"
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION"
lab workspace create --cwd "$ROOT/.doorbell-lab" --label doorbell-proof --no-focus > "$TEST_ROOT/workspace.json"
PANE=$(jq -er '.result.root_pane.pane_id' "$TEST_ROOT/workspace.json")
export TARGET="$LAB_SESSION:$PANE"
printf -v launch 'set +m; env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME=%q FM_TASK_INBOX=%q CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 bash -c %q _ %q claude --dangerously-skip-permissions --setting-sources user --strict-mcp-config --mcp-config %q --settings %q --system-prompt %q' "$LAB" "$FM_TASK_INBOX" 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' "$TEST_ROOT/claude.pid" '{"mcpServers":{}}' '{"disableAllHooks":true,"feedbackDrafts":"off","autoMemoryEnabled":false}' 'You are an isolated doorbell verification worker. Only process explicitly supplied test requests. When told an instruction is waiting, read all *.msg files in FM_TASK_INBOX, carry out their specified local sentinel operations, move each message to handled/, then reply DONE. Never access other files, run fleet supervision, spawn agents, or use external services besides this conversation.'
lab pane run "$PANE" "$launch"
for ((i=0;i<90;i++)); do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  printf '%s\n' "$screen" > "$EVIDENCE/startup-pane.txt"
  case "$screen" in
    *'bypass permissions on'*) break;;
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null;;
  esac
  sleep 1
done
[ "$i" -lt 90 ] || { echo 'FAIL Claude startup'; exit 1; }
CLAUDE_PID=$(cat "$TEST_ROOT/claude.pid")
export CLAUDE_PID
printf 'VERSIONS: '; herdr --version; claude --version
printf 'LAB session=%s pane=%s claude_pid=%s\n' "$LAB_SESSION" "$PANE" "$CLAUDE_PID"
export PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_backend_source herdr
ring() {
  local result=0
  fm_task_inbox_ring herdr "$TARGET" "$1" '' claude || result=$?
  printf 'RING %s rc=%s reason=%s\n' "${1##*/}" "$result" "$FM_TASK_INBOX_RING_REASON"
  printf '%s %s\n' "$result" "$FM_TASK_INBOX_RING_REASON" > "$TEST_ROOT/last-result"
}
wait_action() {
  local label=$1 rec=$2
  for ((j=0;j<180;j++)); do
    [ -f "$LAB/$label" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] && break
    sleep 0.5
  done
  [ -f "$LAB/$label" ] && [ "$(cat "$LAB/$label")" = "$label" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] || { echo "FAIL no sentinel/ack $label"; exit 1; }
  echo "ACTION $label sentinel=$(cat "$LAB/$label") acknowledgement=handled/${rec##*/}"
  for ((j=0;j<90;j++)); do
    st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    case "$st" in idle|done) break;; esac
    sleep 0.5
  done
  sleep 1
  lab pane read "$PANE" --source visible > "$EVIDENCE/$label-pane.txt"
  lab pane read "$PANE" --source visible --format ansi > "$EVIDENCE/$label-pane.ansi"
  cp "${rec%/*}/handled/${rec##*/}" "$EVIDENCE/$label-record.msg"
}
make_record() {
  fm_task_inbox_write "$LAB/state" doorbell "Use the Bash tool to run exactly: printf '%s' '$1' > '$LAB/$1'. Then move this .msg into handled/."
}
# Ordinary delivery proves the real login and durable inbox consumption.
rec=$(make_record ordinary)
ring "$rec"
[ "$(cat "$TEST_ROOT/last-result")" = '0 ok' ]
wait_action ordinary "$rec"
# A stopped real Claude gives a guaranteed empty first proof, then resumes.
mkdir "$TEST_ROOT/delay"
export FM_RENDER_MODE=delay FM_RENDER_DIR="$TEST_ROOT/delay"
(
  for ((k=0;k<300;k++)); do [ -f "$FM_RENDER_DIR/probe.ansi" ] && break; sleep 0.1; done
  [ -f "$FM_RENDER_DIR/probe.ansi" ] || exit 1
  sleep 1.5
  ps -p "$CLAUDE_PID" -o stat= | rg T
  python3 -c 'import time,pathlib,os; p=pathlib.Path(os.environ["FM_RENDER_DIR"]); print("VERIFIED_RENDER_STALL_SECONDS",time.monotonic()-float((p/"typed-at").read_text()))'
  kill -CONT "$CLAUDE_PID"
) &
BACKGROUND=$!
rec=$(make_record delayed)
ring "$rec"
wait "$BACKGROUND"; BACKGROUND=
[ "$(cat "$TEST_ROOT/last-result")" = '0 ok' ]
actual=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content $'styled=1\ncursor=0\nidentity=0' "$(cat "$FM_RENDER_DIR/probe.ansi")")
[ -z "$actual" ]
echo "DELAYED_FIRST_PROOF composer_empty=true"
cp "$FM_RENDER_DIR/probe.ansi" "$EVIDENCE/delayed-first-proof.ansi"
wait_action delayed "$rec"
unset FM_RENDER_MODE FM_RENDER_DIR
# Remaining adversarial scenarios are appended below.
# Overlap: the first ringer is inside a real delayed backend submission.
mkdir "$TEST_ROOT/overlap"
export FM_RENDER_MODE=delay FM_RENDER_DIR="$TEST_ROOT/overlap"
rec1=$(make_record overlap-one)
rec2=$(make_record overlap-two)
ring "$rec1" > "$TEST_ROOT/overlap/first-result" &
BACKGROUND=$!
for ((k=0;k<300;k++)); do [ -f "$FM_RENDER_DIR/probe.ansi" ] && break; sleep 0.1; done
[ -f "$FM_RENDER_DIR/probe.ansi" ]
ring "$rec2"
[ "$(cat "$TEST_ROOT/last-result")" = '1 ring-in-flight' ]
[ -f "$rec1" ] && [ -f "$rec2" ]
cp "${rec2%.msg}.ring-reason" "$EVIDENCE/overlap-skip.ring-reason"
kill -CONT "$CLAUDE_PID"
wait "$BACKGROUND"; BACKGROUND=
cat "$TEST_ROOT/overlap/first-result"
rg -q 'rc=0 reason=ok' "$TEST_ROOT/overlap/first-result"
unset FM_RENDER_MODE FM_RENDER_DIR
wait_action overlap-one "$rec1"
wait_action overlap-two "$rec2"
# Hold Claude through the entire default proof budget. Resume only for clear.
mkdir "$TEST_ROOT/timeout"
export FM_RENDER_MODE=timeout FM_RENDER_DIR="$TEST_ROOT/timeout"
rec=$(make_record never-submitted)
start=$SECONDS
ring "$rec"
elapsed=$((SECONDS-start))
kill -CONT "$CLAUDE_PID"
[ "$(cat "$TEST_ROOT/last-result")" = '2 payload-not-shown' ]
[ -f "$rec" ] && [ ! -f "$LAB/never-submitted" ]
! rg ' enter( |$)' "$FM_RENDER_DIR/keys"
printf 'BOUNDED_REFUSAL elapsed=%ss no_enter=true record_preserved=true sentinel_absent=true\n' "$elapsed"
cp "$FM_RENDER_DIR/probe.ansi" "$EVIDENCE/timeout-first-proof.ansi"
cp "$FM_RENDER_DIR/keys" "$EVIDENCE/timeout-keys.txt"
lab pane read "$PANE" --source visible > "$EVIDENCE/timeout-pane.txt"
unset FM_RENDER_MODE FM_RENDER_DIR
# Successful retry demonstrates that the refused delivery lost no durable work.
ring "$rec"
[ "$(cat "$TEST_ROOT/last-result")" = '0 ok' ]
wait_action never-submitted "$rec"
# Dead-owner recovery with a real backend: pause reclamation after primary removal.
export FM_RING_LOCK="$LAB/state/doorbell.inbox/.ring.lock" FM_RING_GATE="$TEST_ROOT/reclaim"
mkdir "$FM_RING_GATE"
rec1=$(make_record reclaim-one)
rec2=$(make_record reclaim-two)
FM_HOME="$LAB" bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_lock_try_acquire "$2"' _ "$ROOT" "$FM_RING_LOCK"
[ -f "$FM_RING_LOCK/pid" ]
! kill -0 "$(cat "$FM_RING_LOCK/pid")" 2>/dev/null
FM_RING_RECLAIMER=1 ring "$rec1" > "$FM_RING_GATE/first-result" &
BACKGROUND=$!
for ((k=0;k<300;k++)); do [ -f "$FM_RING_GATE/gap" ] && break; sleep 0.1; done
[ -f "$FM_RING_GATE/gap" ]
[ ! -e "$FM_RING_LOCK" ] && [ ! -L "$FM_RING_LOCK" ]
[ -s "$FM_RING_LOCK.steal/pid" ]
printf 'RECLAIM_GAP primary_absent=true steal_owner=%s\n' "$(cat "$FM_RING_LOCK.steal/pid")"
ring "$rec2"
[ "$(cat "$TEST_ROOT/last-result")" = '1 ring-in-flight' ]
[ -f "$rec1" ] && [ -f "$rec2" ]
cp "${rec2%.msg}.ring-reason" "$EVIDENCE/reclaim-skip.ring-reason"
: > "$FM_RING_GATE/release"
wait "$BACKGROUND"; BACKGROUND=
cat "$FM_RING_GATE/first-result"
rg -q 'rc=0 reason=ok' "$FM_RING_GATE/first-result"
wait_action reclaim-one "$rec1"
wait_action reclaim-two "$rec2"
# A live foreign draft must be preserved, with no doorbell submission.
rec=$(make_record foreign-protected)
lab pane send-text "$PANE" 'MY UNSENT HUMAN DRAFT' --literal >/dev/null
sleep 1
ring "$rec"
[ "$(cat "$TEST_ROOT/last-result")" = '1 foreign-pending-draft' ]
lab pane read "$PANE" --source visible > "$EVIDENCE/foreign-draft-pane.txt"
rg -q 'MY UNSENT HUMAN DRAFT' "$EVIDENCE/foreign-draft-pane.txt"
[ -f "$rec" ] && [ ! -f "$LAB/foreign-protected" ]
echo 'FOREIGN_DRAFT preserved=true record_preserved=true sentinel_absent=true'
lab pane send-keys "$PANE" ctrl+u >/dev/null
sleep 1
ring "$rec"
[ "$(cat "$TEST_ROOT/last-result")" = '0 ok' ]
wait_action foreign-protected "$rec"
printf 'ALL_LIVE_SCENARIOS_PASSED\n'
