#!/usr/bin/env bash
# Live guard for the second-mate restart's background-shell handling against
# real Claude Code through tmux: the status-row shell count and the persist
# request's own shell-stopping sentence clearing it, so a later exit opens
# no picker.
# FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR optionally retains the real pane captures.
set -eu

# shellcheck source=tests/lib.sh
. "~/.no-mistakes/worktrees/049a88734b0e/01M6A537XCX37RCJF1C26J6ASG/tests/lib.sh"
fm_live_gate opt-in FM_RESTART_BG_SHELLS_LIVE claude tmux python3

version=$(claude --version 2>/dev/null | head -1)
[ -n "$version" ] || fail 'Claude: installed version unavailable'
printf '# harness: %s; transport: %s\n' "$version" "$(tmux -V)"
mkdir -p "$ROOT/.no-mistakes"
lab=$(mktemp -d "$ROOT/.no-mistakes/restart-bg-shells-live.XXXXXX")
real_tmux=$(command -v tmux)
socket="$ROOT/.rbs-$$.sock"
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

screen() { tmux capture-pane -p -t live:fm-bg -S -0; }
record_screen() {
  [ -z "${FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR:-}" ] \
    || screen > "$FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR/$1.txt"
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
shell_count_is() { [ "$(fm_composer_claude_background_shells "$(screen)" || true)" = "$1" ]; }
no_shell_count() { ! fm_composer_claude_background_shells "$(screen)" >/dev/null; }
idle_with_word() { [ "$(fm_tmux_composer_state live:fm-bg)" = empty ] && screen | grep -q "$1"; }
background_dead() { ! kill -0 "$background_pid" 2>/dev/null; }
composer_idle() { [ "$(fm_tmux_composer_state live:fm-bg)" = empty ]; }
agent_dead() { [ "$(fm_backend_tmux_agent_state live:fm-bg)" = dead ]; }

cat > "$lab/launch.sh" <<'SH'
#!/usr/bin/env bash
unset CLAUDECODE
prompt='Use Bash exactly once with run_in_background=true to run: sh -c '\''echo $$ > background.pid; exec sleep 300'\''. Then reply with the uppercase word ready and stop. Leave the background task running. Do not use other tools or change any other files.'
exec claude --no-chrome --permission-mode dontAsk --allowedTools Bash,KillShell,TaskStop --model haiku --effort low \
  --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --system-prompt 'Follow the user instruction exactly.' "$prompt"
SH
tmux new-session -d -s live -n fm-bg -c "$lab/worktree" -x 180 -y 45 'bash --noprofile --norc'
tmux send-keys -t live:fm-bg -l "bash '$lab/launch.sh'"
tmux send-keys -t live:fm-bg Enter
wait_for 90 idle_with_word READY || { screen >&2; fail "$version: never reached an idle composer"; }
background_pid=$(cat "$lab/worktree/background.pid")
kill -0 "$background_pid" 2>/dev/null || fail "$version: the background shell is not running"

wait_for 10 shell_count_is 1 || { screen >&2; fail "$version: the status row does not report 1 running shell"; }
record_screen shell-running
pass "$version: the status row below the composer reports 1 running background shell"


# Drive the real restart CLI against the already-running isolated Claude pane.
parent="$lab/parent"
"$ROOT/bin/fm-lab-home.sh" create "$parent" >/dev/null
mkdir -p "$lab/worktree/state"
printf 'lab-bg\n' > "$lab/worktree/.fm-secondmate-home"
cat > "$parent/state/lab-bg.meta" <<META
window=live:fm-bg
endpoint_task_id=lab-bg
worktree=$lab/worktree
project=$lab/worktree
home=$lab/worktree
harness=claude
backend=tmux
kind=secondmate
mode=secondmate
META
set +e
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$parent" FM_SECONDMATE_PERSIST_WAIT=3 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_BG_SHELL_WAIT=0 \
  bash "$ROOT/bin/fm-secondmate-restart.sh" lab-bg > "$FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR/restart-attempt.txt" 2>&1
probe_rc=$?
set -e
printf 'restart CLI exit status: %s\n' "$probe_rc" >> "$FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR/restart-attempt.txt"
kill -0 "$background_pid" 2>/dev/null || fail 'the blocked restart stopped the background task'
screen > "$FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR/after-restart-attempt.txt"
printf '# isolated restart prerequisite attempted: exit %s; background shell remains alive\n' "$probe_rc"

tmux send-keys -t live:fm-bg -l "$stop_request Then reply with one word."
tmux send-keys -t live:fm-bg Enter
wait_for 120 background_dead || { screen >&2; fail "$version: the background shell survived the persist request's stop sentence"; }
background_pid=
wait_for 60 composer_idle \
  || { screen >&2; fail "$version: the agent never returned to an idle composer"; }
wait_for 10 no_shell_count || { screen >&2; fail "$version: the status row still reports a running shell"; }
record_screen shell-stopped
pass "$version: the persist request's sentence made the agent stop its own shell, and the status row cleared"

tmux send-keys -t live:fm-bg -l /exit
tmux send-keys -t live:fm-bg Enter
wait_for 30 agent_dead \
  || { screen >&2; fail "$version: Claude did not exit after its shells were stopped"; }
record_screen claude-exited
pass "$version: with its shells stopped, /exit closed Claude without a picker"
