#!/usr/bin/env bash
set -eu
REPO=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6A1RBDBTX6W12NDNV591RNK
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
bg_pid=
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  if [ -n "$bg_pid" ]; then kill "$bg_pid" 2>/dev/null || true; fi
  rm -rf "$LAB"
  printf 'teardown: private tmux server and disposable homes removed\n'
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
bash bin/fm-lab-home.sh create "$LAB/mate"
mkdir -p "$LAB/tmux" "$LAB/claude" "$LAB/data/lab-mate"
chmod 700 "$LAB/claude"
printf 'lab-mate\n' > "$LAB/mate/.fm-secondmate-home"
printf 'Isolated restart validation mate.\n' > "$LAB/data/lab-mate/brief.md"
source_config=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
source_store=${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json
if [ -f "$source_config/.credentials.json" ]; then
  cp "$source_config/.credentials.json" "$LAB/claude/.credentials.json"
  chmod 600 "$LAB/claude/.credentials.json"
elif [ -z "${ANTHROPIC_API_KEY:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
  printf 'No reusable authentication is available\n' >&2
  exit 1
fi
python3 - "$source_store" "$LAB/claude/.claude.json" "$REPO" <<'PY'
import json, pathlib, sys
source, target, worktree = map(pathlib.Path, sys.argv[1:])
original = json.loads(source.read_text()) if source.is_file() else {}
config = {'hasCompletedOnboarding': True, 'theme': 'dark',
          'projects': {str(worktree): {'hasTrustDialogAccepted': True}}}
if 'oauthAccount' in original:
    config['oauthAccount'] = original['oauthAccount']
target.write_text(json.dumps(config))
PY
cat > "$LAB/state/lab-mate.meta" <<META
kind=secondmate
mode=secondmate
harness=claude
backend=tmux
window=primary:fm-lab-mate
endpoint_task_id=lab-mate
home=$LAB/mate
worktree=$LAB/mate
project=$LAB/mate
model=default
effort=default
yolo=off
META
export LAB
cat > "$LAB/launch.sh" <<'LAUNCH'
#!/usr/bin/env bash
unset CLAUDECODE
prompt="Use Bash exactly once with run_in_background=true to run: sh -c 'echo \$\$ > $LAB/mate/background.pid; exec sleep 300'. Then reply with the uppercase word READY and stop. Leave the background task running. Do not use other tools or change any other files."
exec claude --no-chrome --permission-mode dontAsk --allowedTools Bash,KillShell,TaskStop --model haiku --effort low \
  --setting-sources '' --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
  --system-prompt 'Follow the user instruction exactly. Only change the explicitly named disposable file.' "$prompt"
LAUNCH
export CLAUDE_CONFIG_DIR="$LAB/claude" DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
export CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
screen() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary:fm-lab-mate; }
. "$REPO/bin/fm-composer-lib.sh"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -n fm-lab-mate -c "$PWD" -x 180 -y 45 -e FM_HOME="$LAB/mate" "bash '$LAB/launch.sh'"
ready=0
for ((i=0; i<90; i++)); do
  capture=$(screen)
  if [ -f "$LAB/mate/background.pid" ] && [ "$(fm_composer_claude_background_shells "$capture" || true)" = 1 ] && printf '%s' "$capture" | grep -q READY; then ready=1; break; fi
  sleep 1
done
screen > "$EVIDENCE/restart-lab-before.txt"
[ "$ready" = 1 ] || { cat "$EVIDENCE/restart-lab-before.txt"; exit 1; }
bg_pid=$(cat "$LAB/mate/background.pid")
kill -0 "$bg_pid"
printf 'Real Claude pane: one running background shell; grid=180x45\n'
socket=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary:fm-lab-mate '#{socket_path}')
pane=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary:fm-lab-mate '#{pane_id}')
set +e
FM_HOME="$LAB" TMUX="$socket,0,0" TMUX_PANE="$pane" TMUX_TMPDIR="$LAB/tmux" \
  FM_SECONDMATE_PERSIST_WAIT=3 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_BG_SHELL_WAIT=0 \
  bash bin/fm-secondmate-restart.sh lab-mate > "$EVIDENCE/restart-lab-cli.txt" 2>&1
rc=$?
set -e
cat "$EVIDENCE/restart-lab-cli.txt"
printf 'restart exit status: %s\n' "$rc"
screen > "$EVIDENCE/restart-lab-after.txt"
kill -0 "$bg_pid"
printf 'Original background process is still alive. No cleanup observation or relaunch was reached.\n'
[ ! -e "$LAB/state/lab-mate.control-relaunch" ]
printf 'No relaunch transaction was created.\n'
[ "$rc" = 3 ]
grep -q 'refusing fleet lifecycle from inside a no-mistakes gate worktree\|gate agent must not drive the fleet' "$EVIDENCE/restart-lab-cli.txt"
