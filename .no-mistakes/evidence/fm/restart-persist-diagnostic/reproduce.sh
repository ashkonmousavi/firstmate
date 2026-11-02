#!/usr/bin/env bash
# Run from the gate worktree with its authenticated Codex session and tmux.
set -eu
EVIDENCE=$(cd "$(dirname "$0")" && pwd)
[ ! -e .lv ] && [ ! -e bin/.lv-base-restart.sh ] || { echo 'Refusing to overwrite an existing .lv lab'; exit 1; }
mkdir .lv
cleanup() {
  if [ -f .lv/socket-dir ]; then
    TMUX_TMPDIR="$(cat .lv/socket-dir)" tmux -L fm-lab kill-server
    bash bin/fm-lab-home.sh teardown "$PWD/.lv/home"
  fi
  rm -rf .lv
  rm -f bin/.lv-base-restart.sh
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$PWD/.lv/home"
bash bin/fm-lab-home.sh tmux-dir "$PWD/.lv/home" > .lv/socket-dir
mkdir -p .lv/home/tmux
touch .lv/home/config/supervision-host
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$(cat .lv/socket-dir)" tmux -L fm-lab new-session -d -x 120 -y 40 -s primary -n fm-probe -c "$PWD" -e FM_HOME="$PWD/.lv/home" codex
for n in {1..50}; do
  current=$(TMUX_TMPDIR="$(cat .lv/socket-dir)" tmux -L fm-lab display-message -p -t primary '#{pane_current_command}')
  [ "$current" != codex ] || break
  sleep .1
done
python3 "$EVIDENCE/live-restart-driver.py"
git show 81be4ee4f3fa324085124db5d3f1beca5b421d41:bin/fm-secondmate-restart.sh > bin/.lv-base-restart.sh
python3 "$EVIDENCE/baseline-driver.py"
