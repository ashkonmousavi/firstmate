#!/usr/bin/env bash
set -u
LAB=$(cat .test-lab-path)
E=/home/tegris/.no-mistakes/evidence/01M4DT9WJSM59MB5VKZWYZCKXT
export TMUX_TMPDIR="$LAB/tmux"
export TMUX="$(tmux -L fm-lab display-message -p -t primary:codex-dialog '#{socket_path},#{pid},0')"
export FM_HOME="$LAB" FM_COMPOSER_DIALOG_SINK="$LAB/dialog-sink"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
. bin/fm-backend.sh
fm_backend_source tmux
capture() { tmux -L fm-lab capture-pane -p -t "$1" > "$E/$2-screen.txt"; }
check() {
  local state name
  state=$(fm_backend_composer_state tmux "$1")
  name=$(fm_composer_blocking_dialog_noted || true)
  printf '%s: composer=%s dialog=%s\n' "$2" "$state" "${name:-none}"
  [ "$state" = "$3" ] && [ -z "$name" ] || exit 1
  capture "$1" "$2"
}
check %6 codex-idle empty
tmux -L fm-lab send-keys -t %6 -l 'Background server has incompatible feature settings - unsubmitted user text'
sleep 0.5
check %6 codex-pending pending
tmux -L fm-lab send-keys -t %6 C-u
sleep 0.3
check %6 codex-cleared empty
sleep 0.3
check %5 shell-unknown unknown
tmux -L fm-lab send-keys -t %6 -l 'This is a disposable validation turn. Do not use tools, read or modify any files, or operate Firstmate. Output the integers 1 through 200, one per line. Do nothing else.'
tmux -L fm-lab send-keys -t %6 Enter
busy=0
for ((i=0;i<30;i++)); do
  sleep 0.2
  if fm_pane_is_busy %6 codex; then
    capture %6 codex-working
    name=$(fm_composer_blocking_dialog_noted || true)
    printf 'codex-working: busy=true dialog=%s\n' "${name:-none}"
    [ -z "$name" ] || exit 1
    busy=1
    break
  fi
done
[ "$busy" = 1 ] || { echo 'No live Codex working signal observed'; capture %6 codex-working-unobserved; exit 1; }
capture primary:codex-dialog codex-dialog
name=$(fm_composer_blocking_dialog "$(cat "$E/codex-dialog-screen.txt")")
printf 'codex-dialog: recognized=%s\n' "$name"
fm_backend_send_text_submit tmux primary:codex-dialog 'UNSAFE_SENTINEL_DO_NOT_TYPE' 3 0.2 0.2
rc=$?
printf 'dialog-submit: exit=%s\n' "$rc"
[ "$rc" -ne 0 ] || exit 1
capture primary:codex-dialog codex-dialog-after-refusal
cmp "$E/codex-dialog-screen.txt" "$E/codex-dialog-after-refusal-screen.txt" || exit 1
echo 'dialog-submit: screen byte-identical, selected Cancel unchanged'
