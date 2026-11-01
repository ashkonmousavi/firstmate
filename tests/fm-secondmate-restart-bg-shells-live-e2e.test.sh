#!/usr/bin/env bash
# Live guard for the second-mate restart's background-shell handling against
# real Claude Code through tmux and Herdr: the status-row shell count and the persist
# request's own shell-stopping sentence clearing it, so a later exit opens
# no picker.
# FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR optionally retains the real pane captures.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_RESTART_BG_SHELLS_LIVE claude tmux herdr jq python3

version=$(claude --version 2>/dev/null | head -1)
[ -n "$version" ] || fail 'Claude: installed version unavailable'
mkdir -p "$ROOT/.no-mistakes"
lab=$(mktemp -d "$ROOT/.no-mistakes/restart-bg-shells-live.XXXXXX")
real_tmux=$(command -v tmux)
socket="$ROOT/.rbs-$$.sock"
background_pid=
server_pid=
cleanup() {
  "$real_tmux" -S "$socket" kill-server >/dev/null 2>&1 || true
  if [ -n "$background_pid" ]; then kill "$background_pid" 2>/dev/null || true; fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  rm -f "$socket"
  rm -rf "$lab"
  fm_test_cleanup
}
trap cleanup EXIT

source_config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
source_store=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
mkdir -p "$lab/claude" "$lab/bin" "$lab/worktree"
chmod 700 "$lab/claude"
if [ -f "$source_config/.credentials.json" ]; then
  cp "$source_config/.credentials.json" "$lab/claude/.credentials.json"
  chmod 600 "$lab/claude/.credentials.json"
elif [ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  fail "$version: no reusable file or environment authentication for an isolated config"
fi
git -C "$lab/worktree" init -q
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
export DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$ROOT/bin/fm-secondmate-restart-lib.sh"

# The sentence of the real persist request that asks the mate to stop its
# shells, sent on its own so the guard spends no turn on the rest of /stow.
stop_request=$(printf '%s\n' "$FM_SECONDMATE_PERSIST_REQUEST" \
  | sed -n 's/.*\(Also stop every background shell[^.]*\.\).*/\1/p')
[ -n "$stop_request" ] || fail "the persist request no longer asks the mate to stop its background shells"

screen() {
  if [ "$backend" = herdr ]; then
    fm_backend_capture herdr "$target" 60
  else
    fm_backend_visible_capture tmux "$target"
  fi
}
visible_screen() { fm_backend_visible_capture "$backend" "$target"; }
record_screen() {
  [ -z "${FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR:-}" ] \
    || screen > "$FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR/$backend-$1.txt"
}
wait_for() {  # <seconds> <command...>
  local limit=$1 attempt
  shift
  for ((attempt=0; attempt<limit; attempt++)); do
    "$@" && return 0
    sleep 1
  done
  return 1
}
shell_count_is() {
  local capture
  capture=$(screen) && [ -n "$capture" ] || return 1
  [ "$(fm_composer_claude_background_shells "$capture" || true)" = "$1" ] || return 1
  capture=$(visible_screen) && [ -n "$capture" ] || return 1
  [ "$(fm_composer_claude_background_shells "$capture" || true)" = "$1" ]
}
no_shell_count() {
  local capture
  capture=$(screen) && [ -n "$capture" ] || return 1
  ! fm_composer_claude_background_shells "$capture" >/dev/null || return 1
  capture=$(visible_screen) && [ -n "$capture" ] || return 1
  ! fm_composer_claude_background_shells "$capture" >/dev/null
}
idle_with_word() { composer_idle && screen | grep -q "$1"; }
background_dead() { ! kill -0 "$background_pid" 2>/dev/null; }
composer_idle() { [ "$(fm_backend_composer_state "$backend" "$target")" = empty ]; }
agent_dead() { [ "$(fm_backend_agent_state "$backend" "$target")" = dead ]; }
send() {
  "fm_backend_${backend}_send_literal" "$target" "$1" \
    && fm_backend_send_key "$backend" "$target" Enter
}
server_ready() { herdr pane list --session default >/dev/null 2>&1; }

cat > "$lab/launch.sh" <<'SH'
#!/usr/bin/env bash
unset CLAUDECODE
prompt='Use Bash exactly once with run_in_background=true to run: sh -c '\''echo $$ > background.pid; exec sleep 300'\''. Then reply with the uppercase word ready and stop. Leave the background task running. Do not use other tools or change any other files.'
exec claude --no-chrome --permission-mode dontAsk --allowedTools Bash,KillShell,TaskStop --model haiku --effort low \
  --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --system-prompt 'Follow the user instruction exactly.' "$prompt"
SH
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
cd "$lab"
export XDG_CONFIG_HOME=.config XDG_DATA_HOME="$lab/data"
export XDG_STATE_HOME="$lab/state" XDG_CACHE_HOME="$lab/cache"
mkdir -p "$XDG_CONFIG_HOME/herdr" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
printf '#!/bin/sh\nexec /bin/bash --noprofile --norc\n' > "$lab/shell"
chmod +x "$lab/shell"
printf '[terminal]\ndefault_shell = "%s"\nshell_mode = "non_login"\n[update]\nversion_check = false\nmanifest_check = false\n' \
  "$lab/shell" > "$XDG_CONFIG_HOME/herdr/config.toml"
herdr server --session default > "$lab/server.log" 2>&1 &
server_pid=$!
wait_for 30 server_ready || { cat "$lab/server.log" >&2; fail 'private Herdr server did not become ready'; }

for backend in tmux herdr; do
  fm_backend_source "$backend"
  case "$backend" in
    tmux)
      transport=$(tmux -V)
      target=live:fm-bg
      tmux new-session -d -s live -n fm-bg -c "$lab/worktree" -x 180 -y 45 'bash --noprofile --norc'
      ;;
    herdr)
      transport=$(herdr --version)
      workspace=$(herdr workspace create --cwd "$lab/worktree" --label fm-bg --no-focus --session default)
      pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id')
      target="default:$pane"
      ;;
  esac
  label="$version on $transport"
  printf '# harness: %s; transport: %s\n' "$version" "$transport"
  send "bash '$lab/launch.sh'"
  wait_for 90 idle_with_word READY || { screen >&2; fail "$label: never reached an idle composer"; }
  background_pid=$(cat "$lab/worktree/background.pid")
  kill -0 "$background_pid" 2>/dev/null || fail "$label: the background shell is not running"

  wait_for 10 shell_count_is 1 || { screen >&2; fail "$label: capture does not report 1 running shell"; }
  record_screen shell-running
  pass "$label: viewport and restart capture report 1 running background shell"

  send "$stop_request Then reply with one word."
  wait_for 120 background_dead || { screen >&2; fail "$label: the background shell survived the persist request's stop sentence"; }
  background_pid=
  wait_for 60 composer_idle \
    || { screen >&2; fail "$label: the agent never returned to an idle composer"; }
  wait_for 10 no_shell_count || { screen >&2; fail "$label: capture still reports a running shell"; }
  record_screen shell-stopped
  pass "$label: the persist request stopped its shell and cleared viewport and restart captures"

  send /exit
  wait_for 30 agent_dead \
    || { screen >&2; fail "$label: Claude did not exit after its shells were stopped"; }
  record_screen claude-exited
  pass "$label: with its shells stopped, /exit closed Claude without a picker"
done
