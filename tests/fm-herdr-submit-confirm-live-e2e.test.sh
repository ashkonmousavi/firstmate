#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then requires the same submit path to prove and submit a
# typed /exit slash command behind the command popup Claude renders below the
# composer (the fm-control exit breakage on 2.1.283) and verifies the agent
# actually exited. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry. Claude draws the popup above or below the
# composer depending on the account, so run it under each config directory the
# fleet's workers use ("Claude slash-command popup below the composer").
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle-input.sh
. "$(dirname "${BASH_SOURCE[0]}")/lifecycle-input.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude python3

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=default
TMP_ROOT=$(mktemp -d "$ROOT/.hs.XXXXXX")
mkdir "$ROOT/.x" || { rm -rf "$TMP_ROOT"; fail "private Herdr config directory already exists"; }
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0
SERVER_PID=
STALL_PID=
CLAUDE_PID=
REAL_HERDR=$(command -v herdr)
export HERDR_SESSION="$SESSION" HERDR_SOCKET_PATH="$TMP_ROOT/s"
export XDG_CONFIG_HOME="$ROOT/.x" XDG_DATA_HOME="$TMP_ROOT/data"
export XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache"
mkdir -p "$XDG_CONFIG_HOME/herdr" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
printf '#!/bin/sh\nexec /bin/bash --noprofile --norc\n' > "$TMP_ROOT/shell"
chmod +x "$TMP_ROOT/shell"
printf '[terminal]\ndefault_shell = "%s"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n' \
  "$TMP_ROOT/shell" > "$XDG_CONFIG_HOME/herdr/config.toml"
CONTROL_HOME="$TMP_ROOT/control-home"
mkdir -p "$CONTROL_HOME/state/doorbell.inbox" "$CONTROL_HOME/worktree"

cleanup() {
  local rc=$?
  trap - EXIT
  if [ -n "$STALL_PID" ]; then
    kill "$STALL_PID" 2>/dev/null || true
    wait "$STALL_PID" 2>/dev/null || true
  fi
  [ -z "$CLAUDE_PID" ] || kill -CONT "$CLAUDE_PID" 2>/dev/null || true
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT" "$XDG_CONFIG_HOME"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
if [ -n "\${FM_LIFECYCLE_INPUT_LOG:-}" ]; then
  case "\${args[0]:-} \${args[1]:-}" in
    'pane send-text') printf 'text=%s\\n' "\${args[3]}" >> "\$FM_LIFECYCLE_INPUT_LOG" ;;
    'pane send-keys') printf 'key=%s\\n' "\${args[@]:3}" >> "\$FM_LIFECYCLE_INPUT_LOG" ;;
  esac
fi
if [ -n "\${FM_HERDR_RENDER_STALL_DIR:-}" ]; then
  stall=\$FM_HERDR_RENDER_STALL_DIR
  case "\${args[0]:-} \${args[1]:-}" in
    'pane send-text')
      [ ! -e "\$stall/typed" ] || exit 95
      pid=\$(cat "$TMP_ROOT/claude.pid") || exit 96
      kill -STOP "\$pid" || exit 96
      for ((i=0; i<300; i++)); do
        status=\$(ps -p "\$pid" -o stat=)
        case "\$status" in *T*) break ;; esac
        sleep 0.1
      done
      case "\$status" in *T*) ;; *) exit 96 ;; esac
      "$REAL_HERDR" "\${args[@]}" --session "$SESSION" || exit 97
      python3 -c 'import time; print(time.monotonic())' > "\$stall/typed"
      exit 0
      ;;
    'pane read')
      if [ -s "\$stall/typed" ] && [ ! -e "\$stall/probe" ]; then
        case " \${args[*]} " in
          *' --format ansi '*)
            "$REAL_HERDR" "\${args[@]}" --session "$SESSION" > "\$stall/probe.tmp" || exit 98
            cat "\$stall/probe.tmp"
            mv "\$stall/probe.tmp" "\$stall/probe"
            exit 0
            ;;
        esac
      fi
      ;;
    'pane send-keys')
      case " \${args[*]} " in
        *' enter '*) printf 'enter\\n' >> "\$stall/enters" ;;
      esac
      ;;
  esac
fi
exec "$REAL_HERDR" "\${args[@]}" --session "$SESSION"
EOF
chmod +x "$FAKEBIN/herdr"

"$REAL_HERDR" server --session "$SESSION" > "$TMP_ROOT/server.log" 2>&1 &
SERVER_PID=$!
for ((i=0; i<150; i++)); do
  kill -0 "$SERVER_PID" 2>/dev/null || { cat "$TMP_ROOT/server.log" >&2; fail "private Herdr server exited"; }
  "$REAL_HERDR" pane list --session "$SESSION" >/dev/null 2>&1 && break
  sleep 0.2
done
[ "$i" -lt 150 ] || fail "private Herdr server did not become ready"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { herdr "$@" --session "$SESSION"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

# The viewport regression needs native terminal scrollback. Fullscreen Claude
# uses the alternate screen buffer, whose Herdr scroll maximum stays zero.
printf -v launch 'set +m; FM_HOME=%q FM_TASK_INBOX=%q CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 bash -c %q _ %q claude --dangerously-skip-permissions --setting-sources user --settings %q' \
  "$CONTROL_HOME" "$CONTROL_HOME/state/doorbell.inbox" 'printf "%s\n" "$$" > "$1"; shift; exec "$@"' \
  "$TMP_ROOT/claude.pid" '{"feedbackDrafts":"off","disableAllHooks":true}'
lab pane run "$PANE" "$launch" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"
CLAUDE_PID=$(cat "$TMP_ROOT/claude.pid") || fail "Claude Code ($VERSION) on $HERDR_VER: launch PID unavailable"
case "$CLAUDE_PID" in ''|*[!0-9]*) fail "invalid lab Claude PID" ;; esac

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Print $TOKEN on its own line, then print 120 numbered lines of plain text, one number per line, without using tools." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. The viewport
# capture must prove the typed /exit and submit it; Claude must actually
# exit. This scenario runs last because it ends the lab's Claude process.
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
case "$st" in
  idle|done) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: never became idle for the viewport recovery checks" ;;
esac

check_scrolled_composer_reads() {
  local want_state=$1 want_content=$2 reader metrics offset rows socket raw actual
  for reader in state content; do
    metrics=$(lab pane get "$PANE" | jq -er '.result.pane.scroll') \
      || fail "Claude Code ($VERSION) on $HERDR_VER: scroll metrics unavailable"
    offset=$(printf '%s' "$metrics" | jq -er '.max_offset_from_bottom')
    rows=$(printf '%s' "$metrics" | jq -er '.viewport_rows')
    [ "$offset" -gt "$rows" ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: insufficient scrollback to hide the composer ($offset/$rows)"
    socket=$(fm_backend_herdr_presentation_session_socket_path "$SESSION") \
      || fail "Claude Code ($VERSION) on $HERDR_VER: could not resolve the lab socket"
    if ! python3 - "$socket" "$PANE" "$offset" <<'PYSCROLL'
import json
import socket
import sys
with socket.socket(socket.AF_UNIX) as control:
    control.settimeout(5)
    control.connect(sys.argv[1])
    request = {"id": "live-scroll", "method": "pane.scroll",
               "params": {"pane_id": sys.argv[2], "offset_from_bottom": int(sys.argv[3])}}
    control.sendall((json.dumps(request) + "\n").encode())
    response = json.loads(control.makefile().readline())
    if response.get("id") != "live-scroll" or response.get("error") is not None:
        raise SystemExit(1)
PYSCROLL
    then
      fail "Claude Code ($VERSION) on $HERDR_VER: could not scroll the lab pane"
    fi
    offset=$(fm_backend_herdr_pane_scroll_offset "$SESSION" "$PANE")
    [ "$offset" -gt 0 ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: the viewport did not scroll"
    raw=$(lab pane read "$PANE" --source visible --format ansi) \
      || fail "Claude Code ($VERSION) on $HERDR_VER: could not capture the scrolled viewport"
    [ -n "$raw" ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: scrolled capture was blank"
    case "$reader" in
      state)
        actual=$(fm_backend_herdr_composer_state "$TARGET")
        [ "$actual" = "$want_state" ] \
          || fail "Claude Code ($VERSION) on $HERDR_VER: recovered state expected '$want_state', got '$actual'"
        ;;
      content)
        actual=$(fm_backend_herdr_composer_content "$TARGET") \
          || fail "Claude Code ($VERSION) on $HERDR_VER: content read did not recover the composer"
        [ "$actual" = "$want_content" ] \
          || fail "Claude Code ($VERSION) on $HERDR_VER: recovered content expected '$want_content', got '$actual'"
        ;;
    esac
    offset=$(fm_backend_herdr_pane_scroll_offset "$SESSION" "$PANE")
    [ "$offset" = 0 ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: $reader read left the viewport scrolled ($offset)"
    actual=$(lab pane read "$PANE" --source visible --format ansi) \
      || fail "Claude Code ($VERSION) on $HERDR_VER: could not capture the recovered viewport"
    [ "$actual" != "$raw" ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: scrolling did not expose a different viewport"
  done
  pass "live Herdr viewport recovery: Claude Code ($VERSION) on $HERDR_VER recovers $want_state state and content after independent scrolls"
}

check_scrolled_composer_reads empty ''
SCROLL_DRAFT="Unsent viewport recovery draft $TOKEN"
lab pane send-text "$PANE" "$SCROLL_DRAFT" >/dev/null \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not type the recovery draft"
i=0
while [ "$i" -lt 30 ]; do
  actual=$(fm_backend_herdr_composer_content "$TARGET") || actual=''
  [ "$actual" = "$SCROLL_DRAFT" ] && break
  i=$((i + 1))
  sleep 0.1
done
[ "$actual" = "$SCROLL_DRAFT" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: recovery draft never rendered"
check_scrolled_composer_reads pending "$SCROLL_DRAFT"
lab pane send-keys "$PANE" ctrl+u >/dev/null \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not clear the recovery draft"
i=0
while [ "$i" -lt 30 ]; do
  actual=$(fm_backend_herdr_composer_state "$TARGET")
  [ "$actual" = empty ] && break
  i=$((i + 1))
  sleep 0.1
done
[ "$actual" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: recovery draft did not clear"
. "$ROOT/bin/fm-task-inbox-lib.sh"
workspace=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id') || fail "workspace identity unavailable"
tab=$(lab pane get "$PANE" | jq -er '.result.pane.tab_id') || fail "tab identity unavailable"
printf 'window=%s\nendpoint_task_id=doorbell\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nharness=claude\nkind=ship\nworktree=%s\nproject=%s\n' \
  "$TARGET" "$SESSION" "$workspace" "$tab" "$PANE" "$CONTROL_HOME/worktree" "$CONTROL_HOME/worktree" > "$CONTROL_HOME/state/doorbell.meta"
stall="$TMP_ROOT/render-stall"
mkdir "$stall"
STALL_TOKEN="FMHERDRSTALL$$_$RANDOM"
rec=$(fm_task_inbox_write "$CONTROL_HOME/state" doorbell "Use the Bash tool to run: printf '%s' '$STALL_TOKEN' > '$CONTROL_HOME/render-action'. Then acknowledge this record by moving it into handled/.") \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not write the delayed-render record"
(
  trap 'kill -CONT "$CLAUDE_PID" 2>/dev/null || true' EXIT
  for ((i=0; i<300; i++)); do [ -f "$stall/probe" ] && break; sleep 0.1; done
  [ -f "$stall/probe" ] || exit 1
  sleep 1.5
  status=$(ps -p "$CLAUDE_PID" -o stat=)
  case "$status" in *T*) ;; *) exit 1 ;; esac
  python3 - "$stall/typed" > "$stall/delay" <<'PYDELAY'
import pathlib
import sys
import time
elapsed = time.monotonic() - float(pathlib.Path(sys.argv[1]).read_text())
if elapsed < 1.5:
    raise SystemExit(1)
print(f"{elapsed:.3f}")
PYDELAY
) &
STALL_PID=$!
rc=0
FM_HERDR_RENDER_STALL_DIR="$stall" FM_STATE_OVERRIDE="$CONTROL_HOME/state" \
  fm_task_inbox_ring herdr "$TARGET" "$rec" '' claude || rc=$?
wait "$STALL_PID" || fail "Claude Code ($VERSION) on $HERDR_VER: render stall was not verified"
STALL_PID=
[ "$rc $FM_TASK_INBOX_RING_REASON" = '0 ok' ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: delayed doorbell returned $rc $FM_TASK_INBOX_RING_REASON; viewport: $(lab pane read "$PANE" --source visible 2>/dev/null)"
[ -s "$stall/delay" ] && [ -s "$stall/enters" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: no measured render stall or submission"
actual=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content \
  $'styled=1\ncursor=0\nidentity=0' "$(cat "$stall/probe")") \
  || fail "Claude Code ($VERSION) on $HERDR_VER: stalled proof capture was unreadable"
[ -z "$actual" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: delayed proof did not see an empty composer"
for ((i=0; i<480; i++)); do
  [ -f "$CONTROL_HOME/render-action" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] && break
  sleep 0.5
done
[ -f "$CONTROL_HOME/render-action" ] && [ "$(cat "$CONTROL_HOME/render-action")" = "$STALL_TOKEN" ] \
  && [ ! -e "$rec" ] && [ -f "${rec%/*}/handled/${rec##*/}" ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: delayed doorbell was not acted on and acknowledged"
pass "live Herdr render delay: Claude Code ($VERSION) on $HERDR_VER submits after a verified $(cat "$stall/delay") s stall, acts and acknowledges"
for ((i=0; i<90; i++)); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  sleep 1
done
case "$st" in idle|done) ;; *) fail "Claude Code ($VERSION) on $HERDR_VER: never became idle after the delayed doorbell" ;; esac
rec=$(fm_task_inbox_write "$CONTROL_HOME/state" doorbell "Run touch $CONTROL_HOME/unexpected-submit, then acknowledge this record.") \
  || fail "Claude Code ($VERSION) on $HERDR_VER: could not create the lifecycle record"
line=$(fm_task_inbox_doorbell_line "$rec") || fail "could not build the lifecycle doorbell"
input_log="$CONTROL_HOME/lifecycle-input.log"
for draft in 'An unsent human draft' "${line//doorbell.inbox/another-task.inbox}" "$line additional human text" "$line ctrl+c to stop"; do
  fm_backend_herdr_send_literal "$TARGET" "$draft" || fail "could not type the foreign draft"
  sleep 1
  fm_task_inbox_composer_holds herdr "$TARGET" "$draft" \
    || fail "Claude Code ($VERSION) on $HERDR_VER: foreign draft never rendered in full"
  : > "$input_log"
  if output=$(FM_LIFECYCLE_INPUT_LOG="$input_log" FM_HOME="$CONTROL_HOME" bash "$ROOT/bin/fm-control.sh" doorbell exit 2>&1); then
    fail "Claude Code ($VERSION) on $HERDR_VER: exit accepted a foreign draft: $output"
  fi
  case "$output" in *'composer visibly holds pending text'*) ;; *) fail "$output" ;; esac
  fm_task_inbox_composer_holds herdr "$TARGET" "$draft" \
    || fail "Claude Code ($VERSION) on $HERDR_VER: exit changed a foreign draft"
  [ ! -s "$input_log" ] || fail "Claude Code ($VERSION) on $HERDR_VER: refused exit sent lifecycle input"
  fm_backend_composer_clear herdr "$TARGET" "$draft" || fail "could not clear the test's foreign draft"
done
for verb in interrupt exit; do
  fm_backend_herdr_send_literal "$TARGET" "$line" || fail "could not seed the own doorbell"
  sleep 1
  fm_task_inbox_composer_holds_own herdr "$TARGET" "$line" \
    || fail "Claude Code ($VERSION) on $HERDR_VER: own doorbell never rendered"
  lab pane send-keys "$PANE" left >/dev/null || fail "could not move the test cursor left"
  : > "$input_log"
  output=$(FM_LIFECYCLE_INPUT_LOG="$input_log" FM_HOME="$CONTROL_HOME" FM_CONTROL_SETTLE_WAIT=0.2 bash "$ROOT/bin/fm-control.sh" doorbell "$verb" 2>&1) \
    || fail "Claude Code ($VERSION) on $HERDR_VER: $verb failed: $output"
  fm_test_lifecycle_input "$input_log" "$verb" /exit \
    || fail "Claude Code ($VERSION) on $HERDR_VER: $verb submitted composer text before the exit command"
  if [ "$verb" = interrupt ]; then
    [ "$(fm_backend_composer_state herdr "$TARGET")" = empty ] \
      || fail "Claude Code ($VERSION) on $HERDR_VER: interrupt did not clear the own doorbell"
    [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "interrupt stopped the agent"
  fi
  [ -f "$rec" ] && [ ! -e "$CONTROL_HOME/unexpected-submit" ] \
    || fail "Claude Code ($VERSION) on $HERDR_VER: lifecycle submitted the doorbell"
done
fm_backend_target_exists herdr "$TARGET" || fail "lifecycle removed the lab endpoint"
pass "live Herdr lifecycle: Claude Code ($VERSION) on $HERDR_VER clears its own doorbell from a moved cursor without submitting, preserves foreign drafts, interrupts and exits"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: lifecycle exit reported success but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
