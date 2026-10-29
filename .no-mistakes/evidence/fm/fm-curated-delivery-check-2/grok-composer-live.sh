#!/usr/bin/env bash
set -euo pipefail
E=~/.no-mistakes/evidence/01M63G7WF3X155CM0Z0SN1J1EQ
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 220 -y 50 -c "$PWD" -e FM_HOME="$LAB" "grok --always-approve --leader-socket $LAB/grok.sock"
export TMUX_TMPDIR="$LAB/tmux"
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),0,0
. bin/fm-tmux-lib.sh
for i in $(seq 1 25); do
  sleep 2
  tmux -L fm-lab capture-pane -p -t primary > "$E/grok-composer-idle.txt" || break
  state=$(fm_tmux_composer_state primary)
  printf 'Observation %s: composer=%s\n' "$i" "$state"
  if [ "$state" = empty ]; then
    tmux -L fm-lab send-keys -t primary -l 'Unsubmitted composer check'
    sleep 1
    tmux -L fm-lab capture-pane -p -t primary > "$E/grok-composer-draft.txt"
    state=$(fm_tmux_composer_state primary)
    printf 'After typing an unsubmitted draft: composer=%s\n' "$state"
    [ "$state" = pending ]
    exit 0
  fi
done
printf 'No steerable idle composer reached; inspect the retained terminal capture.\n'
exit 3
