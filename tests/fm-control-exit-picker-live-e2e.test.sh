#!/usr/bin/env bash
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_EXIT_PICKER_LIVE claude tmux python3

version=$(claude --version 2>/dev/null | head -1)
[ -n "$version" ] || fail 'Claude: installed version unavailable'
printf '# harness: %s; transport: %s\n' "$version" "$(tmux -V)"
mkdir -p "$ROOT/.no-mistakes"
lab=$(mktemp -d "$ROOT/.no-mistakes/exit-picker-live.XXXXXX")
real_tmux=$(command -v tmux)
socket="$ROOT/.ep-$$.sock"
background_pid=
cleanup() {
  "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || true
  if [ -n "$background_pid" ]; then kill "$background_pid" 2>/dev/null || true; fi
  rm -f "$socket"
  rm -rf "$lab"
  fm_test_cleanup
}
trap cleanup EXIT

source_config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
source_store=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
mkdir -p "$lab/claude" "$lab/bin" "$lab/home/state" "$lab/home/config" "$lab/home/data"
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

for scenario in already-open submit-opens; do
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
  tmux send-keys -t live:fm-picker -l "bash '$lab/launch.sh'"
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
  if [ "$scenario" = already-open ]; then
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
  output=$(FM_CONTROL_EXIT_WAIT=15 bash "$ROOT/bin/fm-control.sh" picker exit 2>&1) \
    || fail "$version: $scenario: $output"
  printf '%s\n' "$output"
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
