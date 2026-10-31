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
. '~/.no-mistakes/worktrees/049a88734b0e/01M67PW789PCJGAFDEVCTMZ3RM/tests/lib.sh'
. '~/.no-mistakes/worktrees/049a88734b0e/01M67PW789PCJGAFDEVCTMZ3RM/tests/lifecycle-input.sh'

ROOT='~/.no-mistakes/worktrees/049a88734b0e/01M67PW789PCJGAFDEVCTMZ3RM'

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude python3

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
DEFAULT_SOCKET=$("$REAL_HERDR" session list --json | jq -er '.sessions[] | select(.default and .running) | .socket_path') \
  || fail "the guarded lab requires a running default-session tripwire"
SESSION=$(bash "$ROOT/bin/fm-herdr-lab.sh" name submit)
TMP_ROOT=$(mktemp -d "$ROOT/.hs.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0
LAB_PREPARED=0
# Relative XDG paths keep the named lab's Unix socket below sun_path's limit
# even when this checkout lives under a long gate-worktree path.
export XDG_CONFIG_HOME="${TMP_ROOT#"$ROOT"/}/config" XDG_DATA_HOME="$TMP_ROOT/data"
export XDG_STATE_HOME="$TMP_ROOT/state" XDG_CACHE_HOME="$TMP_ROOT/cache"
export FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/lab-state"
mkdir -p "$XDG_CONFIG_HOME/herdr" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
# Only session-list's read-only tripwire observes this socket. All lifecycle
# and pane calls go through the helper and address the named fm-lab session.
ln -s "$DEFAULT_SOCKET" "$XDG_CONFIG_HOME/herdr/herdr.sock"
unset HERDR_SOCKET_PATH
export HERDR_SESSION="$SESSION"
printf '#!/bin/sh\nexec /bin/bash --noprofile --norc\n' > "$TMP_ROOT/shell"
chmod +x "$TMP_ROOT/shell"
printf '[terminal]\ndefault_shell = "%s"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n' \
  "$TMP_ROOT/shell" > "$XDG_CONFIG_HOME/herdr/config.toml"
CONTROL_HOME="$TMP_ROOT/control-home"
bash "$ROOT/bin/fm-lab-home.sh" create "$CONTROL_HOME" >/dev/null || fail "could not mint control home"
mkdir -p "$CONTROL_HOME/state/doorbell.inbox" "$CONTROL_HOME/worktree"

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$LAB_PREPARED" = 1 ]; then
    PATH="$ORIGINAL_PATH" bash "$ROOT/bin/fm-herdr-lab.sh" teardown "$SESSION" || rc=1
  fi
  rm -rf "$TMP_ROOT"
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
exec env PATH="$ORIGINAL_PATH" bash "$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

# Provision owns prepare for a fresh session; preparing twice refuses adoption.
LAB_PREPARED=1
bash "$ROOT/bin/fm-herdr-lab.sh" provision "$SESSION" || fail "could not provision the named lab"
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
printf -v launch 'FM_HOME=%q FM_TASK_INBOX=%q CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --setting-sources user --settings %q' \
  "$CONTROL_HOME" "$CONTROL_HOME/state/doorbell.inbox" '{"feedbackDrafts":"off","disableAllHooks":true}'
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

. "$ROOT/bin/fm-task-inbox-lib.sh"
workspace=$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id') || fail "workspace identity unavailable"
tab=$(lab pane get "$PANE" | jq -er '.result.pane.tab_id') || fail "tab identity unavailable"
printf 'window=%s\nendpoint_task_id=doorbell\nbackend=herdr\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\nharness=claude\nkind=ship\nworktree=%s\nproject=%s\n' \
  "$TARGET" "$SESSION" "$workspace" "$tab" "$PANE" "$CONTROL_HOME/worktree" "$CONTROL_HOME/worktree" > "$CONTROL_HOME/state/doorbell.meta"
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
  fm_test_lifecycle_capture claude-herdr foreign-refused herdr "$TARGET" "$output" "$input_log" || fail "could not retain refusal evidence"
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
  fm_test_lifecycle_capture claude-herdr "$verb-before" herdr "$TARGET" || fail "could not retain pending evidence"
  : > "$input_log"
  output=$(FM_LIFECYCLE_INPUT_LOG="$input_log" FM_HOME="$CONTROL_HOME" FM_CONTROL_SETTLE_WAIT=0.2 bash "$ROOT/bin/fm-control.sh" doorbell "$verb" 2>&1) \
    || fail "Claude Code ($VERSION) on $HERDR_VER: $verb failed: $output"
  fm_test_lifecycle_capture claude-herdr "$verb-after" herdr "$TARGET" "$output" "$input_log" || fail "could not retain lifecycle evidence"
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


