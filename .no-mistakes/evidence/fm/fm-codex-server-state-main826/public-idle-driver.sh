#!/usr/bin/env bash
set -eu
ROOT=$PWD
EV=/home/tegris/.no-mistakes/evidence/01M4AHC8K4DTK2MWYEWJS0FRWA
LAB="$ROOT/.l"
[ ! -e "$LAB" ] || exit 2
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/driver"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
export TMUX_TMPDIR="$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 160 -y 45 -c "$ROOT" -e FM_HOME="$LAB" 'codex --disable hooks --no-daemon'
cat > "$LAB/driver/tmux" <<'WRAP'
#!/usr/bin/env bash
exec /usr/bin/tmux -L fm-lab "$@"
WRAP
chmod +x "$LAB/driver/tmux"
export PATH="$LAB/driver:$PATH"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1
. bin/fm-tmux-lib.sh
. bin/fm-composer-lib.sh
for ((i=0; i<30; i++)); do
  [ "$(fm_tmux_composer_state primary:)" = empty ] && break
  sleep 1
done
[ "$(fm_tmux_composer_state primary:)" = empty ]
codex --version
tmux capture-pane -p -t primary: > "$EV/public-idle-pane.txt"
printf 'window=primary:\nworktree=%s\nkind=scout\nbackend=tmux\nharness=codex\n' "$ROOT" > "$LAB/state/idle.meta"
printf 'working: stale historical event\n' > "$LAB/state/idle.status"
check_unknown() {
  local out
  out=$(bash bin/fm-crew-state.sh idle)
  printf '%s: %s\n' "$1" "$out"
  [[ "$out" == *'state: unknown'* ]] && [[ "$out" != *'state: working'* ]]
}
check_unknown 'missing source plus stale working history'
printf 'broken serialized state\n' > "$LAB/state/idle.busy-state"
check_unknown 'malformed stored state plus stale working history'
rm "$LAB/state/idle.busy-state"
. bin/fm-busy-lib.sh
. bin/fm-backend.sh
GEN=$(bin/fm-busy-event.sh arm "$LAB/state" idle)
bin/fm-busy-event.sh apply "$LAB/state" idle busy --gen "$GEN" --source codex-hook --event user-prompt-submit
check_unknown 'unverified hook record cannot assert working'
printf 'private lab cleanup follows on EXIT\n'
