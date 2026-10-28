#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M61T4DT0DWZ6683608ERTGB5
LAB=$(mktemp -d "$ROOT/.gXXXXXX")
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
export GROK_CLAUDE_HOOKS_ENABLED=0 GROK_CURSOR_HOOKS_ENABLED=0 GROK_CLAUDE_MCPS_ENABLED=0 GROK_CURSOR_MCPS_ENABLED=0
export TMUX_TMPDIR="$LAB/tmux" GROK_HOME="$LAB/grok" GROK_DISABLE_AUTOUPDATER=1 GROK_AUTO_UPDATE=0
mkdir -p "$LAB/tmux" "$GROK_HOME"
cp "$HOME/.grok/auth.json" "$GROK_HOME/auth.json"
chmod 600 "$GROK_HOME/auth.json"
cleanup() { python3 "$ROOT/.test-validation/cleanup.py" "$LAB"; }
trap cleanup EXIT
real_tmux=$(command -v tmux)
mkdir "$LAB/shim"
printf '#!/usr/bin/env bash\nexec %q -L fm-lab "$@"\n' "$real_tmux" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
. bin/fm-tmux-lib.sh
version=$(grok --version)
tmux new-session -d -s primary -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" grok --always-approve
for ((i=0;i<60;i++)); do
  screen=$(tmux capture-pane -p -t primary)
  case "$screen" in
    *'Do you trust the contents of this directory?'*) tmux send-keys -t primary Enter;;
  esac
  verdict=$(fm_tmux_composer_state primary)
  [ "$verdict" != empty ] || break
  sleep 1
done
tmux capture-pane -p -t primary > "$EVIDENCE/grok-always-approve-idle.txt"
[ "$verdict" = empty ] || { printf 'FAIL: %s idle composer was %s\n' "$version" "$verdict"; exit 1; }
printf '%s real always-approve idle composer: %s\n' "$version" "$verdict"
tmux send-keys -t primary -l 'validation-unsent-probe'
sleep .5
verdict=$(fm_tmux_composer_state primary)
tmux capture-pane -p -t primary > "$EVIDENCE/grok-always-approve-pending.txt"
[ "$verdict" = pending ]
printf '%s real unsent draft composer: %s\n' "$version" "$verdict"
