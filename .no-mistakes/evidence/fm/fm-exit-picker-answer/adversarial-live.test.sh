#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "~/.no-mistakes/worktrees/049a88734b0e/01M68P0P3YHBVJF2JJFA12JV05/tests/lib.sh"
fm_live_gate opt-in FM_EXIT_PICKER_LIVE claude tmux python3

version=$(claude --version 2>/dev/null | head -1)
[ -n "$version" ] || fail 'Claude: installed version unavailable'
printf '# harness: %s; transport: %s\n' "$version" "$(tmux -V)"
mkdir -p "$ROOT/.no-mistakes"
lab=$(mktemp -d "$ROOT/.no-mistakes/exit-picker-live.XXXXXX")
real_tmux=$(command -v tmux)
socket="$ROOT/.ep-$$.sock"
background_pid=
frozen_pid=
cleanup() {
  [ -z "$frozen_pid" ] || kill -CONT "$frozen_pid" 2>/dev/null || true
  "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || true
  if [ -n "$background_pid" ]; then kill "$background_pid" 2>/dev/null || true; fi
  rm -f "$socket"
  rm -rf "$lab"
  fm_test_cleanup
}
trap cleanup EXIT

source_config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
source_store=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
"$ROOT/bin/fm-lab-home.sh" create "$lab/home" >/dev/null
unset FM_GATE_REFUSE_BYPASS
mkdir -p "$lab/claude" "$lab/bin"
chmod 700 "$lab/claude"
if [ -f "$source_config/.credentials.json" ]; then
  cp "$source_config/.credentials.json" "$lab/claude/.credentials.json"
  chmod 600 "$lab/claude/.credentials.json"
elif [ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  fail "$version: no reusable file or environment authentication for an isolated config"
fi
fm_git_worktree "$lab/project" "$lab/worktree" exit-picker-live
printf '%s\n' 'Original tracked content.' > "$lab/worktree/unstaged.txt"
git -C "$lab/worktree" add unstaged.txt
git -C "$lab/worktree" -c user.name='Test Fixture' -c user.email='fixture@example.invalid' \
  commit -qm 'Seed preservation fixture'
export CLAUDE_CONFIG_DIR="$lab/claude"
python3 - "$source_store" "$CLAUDE_CONFIG_DIR/.claude.json" "$lab/worktree" <<'PY'
import json, pathlib, sys
source, target, worktree = map(pathlib.Path, sys.argv[1:])
original = json.loads(source.read_text()) if source.is_file() else {}
config = {"hasCompletedOnboarding": True,
          "theme": "dark", "projects": {str(worktree): {"hasTrustDialogAccepted": True}}}
if "oauthAccount" in original:
    config["oauthAccount"] = original["oauthAccount"]
target.write_text(json.dumps(config))
PY
printf '#!/usr/bin/env bash\nexec %q -S %q "$@"\n' "$real_tmux" "$socket" > "$lab/bin/tmux"
chmod +x "$lab/bin/tmux"
export PATH="$lab/bin:$PATH"
export FM_HOME="$lab/home" DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
printf '%s\n' 'Keep this unstaged change.' > "$lab/unstaged.expected"
printf '%s\n' 'Keep this staged change.' > "$lab/staged.expected"
printf '%s\n' 'Keep this untracked change.' > "$lab/untracked.expected"

for scenario in adversarial; do
  background_pid=
  rm -f "$lab/worktree/background.pid"
  cp "$lab/unstaged.expected" "$lab/worktree/unstaged.txt"
  cp "$lab/staged.expected" "$lab/worktree/staged.txt"
  git -C "$lab/worktree" add staged.txt
  git -C "$lab/worktree" diff --cached --binary > "$lab/index.before"
  cp "$lab/untracked.expected" "$lab/worktree/untracked.txt"
  cat > "$lab/launch.sh" <<'SH'
#!/usr/bin/env bash
unset CLAUDECODE
prompt='Use Bash exactly once with run_in_background=true to run: sh -c '\''echo $$ > background.pid; exec sleep 300'\''. Then reply with the uppercase word ready and stop. Leave the background task running. Do not use other tools or change any other files.'
exec claude --no-chrome --permission-mode dontAsk --allowedTools Bash --model haiku --effort low \
  --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --system-prompt 'Follow the user instruction exactly.' "$prompt"
SH
  tmux new-session -d -s live -n fm-picker -c "$lab/worktree" -x 180 -y 45 'bash --noprofile --norc'
  tmux send-keys -t live:fm-picker -l "set +m; bash '$lab/launch.sh'"
  tmux send-keys -t live:fm-picker Enter
  ready=0
  for ((attempt=0; attempt<90; attempt++)); do
    if [ -s "$lab/worktree/background.pid" ]; then
      background_pid=$(cat "$lab/worktree/background.pid")
      if kill -0 "$background_pid" 2>/dev/null \
        && [ "$(fm_tmux_composer_state live:fm-picker)" = empty ] \
        && tmux capture-pane -p -t live:fm-picker | grep -q READY; then
        ready=1
        break
      fi
    fi
    sleep 1
  done
  [ "$ready" = 1 ] || {
    tmux capture-pane -p -t live:fm-picker >&2
    fail "$version: $scenario never reached an idle composer with a live background task"
  }
  printf 'window=live:fm-picker\nendpoint_task_id=picker\nworktree=%s\nproject=%s\nharness=claude\nbackend=tmux\nkind=ship\n' \
    "$lab/worktree" "$lab/project" > "$FM_HOME/state/picker.meta"

  # A draft must not be submitted, cleared, or turned into an exit command.
  tmux send-keys -t live:fm-picker -l 'Preserve this unsubmitted draft.'
  sleep 1
  rc=0
  output=$(bash "$ROOT/bin/fm-control.sh" picker exit 2>&1) || rc=$?
  printf 'pending-draft rc=%s: %s\n' "$rc" "$output"
  [ "$rc" = 1 ] || fail 'pending draft exit should refuse'
  tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/pending-draft.txt"
  grep -q 'Preserve this unsubmitted draft.' "$EVIDENCE/pending-draft.txt" || fail 'draft lost'
  kill -0 "$background_pid" || fail 'draft refusal stopped background task'
  tmux send-keys -t live:fm-picker C-u
  sleep 1

  if [ "$scenario" = adversarial ]; then
    tmux send-keys -t live:fm-picker -l /exit
    tmux send-keys -t live:fm-picker Enter
    dialog=
    for ((attempt=0; attempt<30; attempt++)); do
      dialog=$(fm_composer_blocking_dialog "$(tmux capture-pane -p -t live:fm-picker)" || true)
      [ "$dialog" != 'Claude background-task exit picker' ] || break
      sleep 1
    done
    [ "$dialog" = 'Claude background-task exit picker' ] || fail "$version: exit picker not rendered"
  fi
  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = alive ] || fail "$version: Claude was not alive before exit"

  tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/adversarial-picker.txt"
  # Reproduce the pre-fix refusal against this actual live Claude picker.
  rc=0
  output=$(bash "$ROOT/.test-tmp/base/bin/fm-control.sh" picker exit 2>&1) || rc=$?
  printf 'pre-fix rc=%s: %s\n' "$rc" "$output"
  [ "$rc" = 1 ] || fail 'old control should reproduce the refusal'
  [[ "$output" = *'blocked on a prompt: Claude background-task exit picker'* ]] || fail 'wrong pre-fix failure'
  kill -0 "$background_pid" || fail 'old control stopped background task'
  # Moving to background is forbidden: the non-stop option must stay unconfirmed.
  tmux send-keys -t live:fm-picker Down
  sleep 1
  tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/alternate-row-before.txt"
  grep -q '❯ 2. Move to background and exit' "$EVIDENCE/alternate-row-before.txt" || fail 'alternative row not selected'
  rc=0
  output=$(FM_CONTROL_EXIT_WAIT=2 bash "$ROOT/bin/fm-control.sh" picker exit 2>&1) || rc=$?
  printf 'alternate-row rc=%s: %s\n' "$rc" "$output"
  [ "$rc" = 1 ] || fail 'must not confirm alternative row'
  tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/alternate-row-after.txt"
  cmp "$EVIDENCE/alternate-row-before.txt" "$EVIDENCE/alternate-row-after.txt" || fail 'alternative picker changed'
  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = alive ] || fail 'alternate row exited Claude'
  kill -0 "$background_pid" || fail 'alternate row stopped background task'
  tmux send-keys -t live:fm-picker Up
  sleep 1
  rc=0
  output=$(bash "$ROOT/bin/fm-control.sh" picker interrupt 2>&1) || rc=$?
  printf 'interrupt-picker rc=%s: %s\n' "$rc" "$output"
  [ "$rc" = 0 ] || fail 'interrupt should deliver cancellation while leaving Claude alive'
  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = alive ] || fail 'interrupt exited Claude'
  kill -0 "$background_pid" || fail 'interrupt stopped background task'
  for ((attempt=0; attempt<50; attempt++)); do
    tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/after-interrupt.txt"
    [ "$(fm_composer_blocking_dialog "$(cat "$EVIDENCE/after-interrupt.txt")" || true)" = 'Claude background-task exit picker' ] || break
    sleep 0.1
  done
  [ "$(fm_composer_blocking_dialog "$(cat "$EVIDENCE/after-interrupt.txt")" || true)" != 'Claude background-task exit picker' ] || fail 'Escape did not cancel picker within 5 seconds'
  printf 'interrupt-picker: Escape cancelled the picker, Claude and background task stayed alive\n'
  tmux send-keys -t live:fm-picker -l /exit
  tmux send-keys -t live:fm-picker Enter
  for ((attempt=0; attempt<15; attempt++)); do
    [ "$(fm_composer_blocking_dialog "$(tmux capture-pane -p -t live:fm-picker)" || true)" != 'Claude background-task exit picker' ] || break
    sleep 1
  done
  [ "$(fm_composer_blocking_dialog "$(tmux capture-pane -p -t live:fm-picker)" || true)" = 'Claude background-task exit picker' ] || fail 'picker did not reopen'
  # Make real Claude unable to consume the confirmation. The control path must
  # send exactly one Enter, observe it remains alive, and return a refusal.
  pane_pid=$(tmux display-message -p -t live:fm-picker '#{pane_pid}')
  foreground_group=$(ps -o tpgid= -p "$pane_pid" | tr -d ' ')
  frozen_pid=$(ps -o pid=,comm= --ppid "$pane_pid" | awk '$2 == "claude" {print $1}')
  [[ "$frozen_pid" =~ ^[0-9]+$ ]] || fail 'no unique direct Claude child'
  [ "$foreground_group" = "$pane_pid" ] || fail 'job-control isolation not established'
  [ "$(ps -o pgid= -p "$frozen_pid" | tr -d ' ')" = "$foreground_group" ] || fail 'Claude group differs'
  kill -STOP "$frozen_pid"
  sleep 0.2
  ps -o pid,ppid,pgid,tpgid,stat,comm -p "$pane_pid,$frozen_pid"
  [[ "$(ps -o stat= -p "$frozen_pid")" = *T* ]] || fail 'Claude did not stay stopped'
  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = alive ] || fail 'freeze setup no longer has a live classified agent'
  [ "$(fm_composer_blocking_dialog "$(tmux capture-pane -p -t live:fm-picker)" || true)" = 'Claude background-task exit picker' ] || fail 'freeze setup lost the picker'
  # A forwarding transport recorder records actual CLI calls without replacing
  # the product or changing the real tmux result.
  cat > "$lab/bin/tmux" <<'PYRECORDER'
#!/usr/bin/env python3
import os, sys, json
with open(os.environ['TMUX_CALLS'], 'a') as log:
    log.write(json.dumps(sys.argv[1:])+'\n')
os.execv(os.environ['REAL_TMUX'], [os.environ['REAL_TMUX'], '-S', os.environ['LAB_SOCKET'], *sys.argv[1:]])
PYRECORDER
  chmod +x "$lab/bin/tmux"
  export TMUX_CALLS="$EVIDENCE/frozen-tmux-calls.jsonl" REAL_TMUX="$real_tmux" LAB_SOCKET="$socket"
  : > "$TMUX_CALLS"
  rc=0
  output=$(FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=1 bash "$ROOT/bin/fm-control.sh" picker exit 2>&1) || rc=$?
  printf 'frozen-picker rc=%s: %s\n' "$rc" "$output"
  [ "$rc" = 1 ] || fail 'frozen picker should report failure'
  [[ "$output" = *'Enter did not clear it'* ]] || fail 'expected one-Enter refusal'
  python3 - "$TMUX_CALLS" <<'PYCHECK'
import json, sys
calls=[json.loads(line) for line in open(sys.argv[1])]
keys=[call for call in calls if call[0]=='send-keys']
assert len(keys)==1 and keys[0][-1]=='Enter', keys
assert '-l' not in keys[0], keys
print('frozen-picker: exactly one real confirming Enter; no literal text or other keys')
PYCHECK
  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = alive ] || fail 'frozen agent misclassified'
  kill -CONT "$frozen_pid"
  frozen_pid=
  for ((attempt=0; attempt<15; attempt++)); do
    [ "$(fm_backend_tmux_agent_state live:fm-picker)" != dead ] || break
    sleep 1
  done
  tmux capture-pane -p -t live:fm-picker > "$EVIDENCE/after-resuming-confirmation.txt"
  # Successful exit remains idempotent after the delayed confirming key lands.
  output=$(bash "$ROOT/bin/fm-control.sh" picker exit 2>&1) || fail 'idempotent exit failed'
  printf 'after-resume: %s\n' "$output"
  printf '%s\n' "$output" | grep -q '^already-stopped picker ' || fail 'idempotent exit not reported'

  [ "$(fm_backend_tmux_agent_state live:fm-picker)" = dead ] || fail "$version: Claude survived exit"
  for ((attempt=0; attempt<15; attempt++)); do
    kill -0 "$background_pid" 2>/dev/null || break
    sleep 1
  done
  ! kill -0 "$background_pid" 2>/dev/null || fail "$version: background task survived exit"
  background_pid=
  [ -d "$lab/worktree" ] || fail "$version: worktree removed"
  cmp "$lab/unstaged.expected" "$lab/worktree/unstaged.txt" || fail "$version: unstaged change lost"
  cmp "$lab/staged.expected" "$lab/worktree/staged.txt" || fail "$version: staged file lost"
  cmp "$lab/untracked.expected" "$lab/worktree/untracked.txt" || fail "$version: untracked change lost"
  git -C "$lab/worktree" diff --cached --binary > "$lab/index.after"
  cmp "$lab/index.before" "$lab/index.after" || fail "$version: index changed"
  pass "$version: $scenario: Claude and background task stopped; endpoint, worktree, index and file changes preserved"
  tmux kill-server
done
