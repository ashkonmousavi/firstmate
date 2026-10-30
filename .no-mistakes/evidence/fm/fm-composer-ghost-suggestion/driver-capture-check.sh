#!/usr/bin/env bash
set -euo pipefail
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
SOCKDIR=$(cat .phase-lab/home/state/.fm-lab-tmux-dir)
export TMUX_TMPDIR=$SOCKDIR
. bin/fm-composer-lib.sh
mode=$1
target=${2:-primary:warm}
pane=$(tmux -L fm-lab capture-pane -p -e -t "$target")
plain=$(tmux -L fm-lab capture-pane -p -t "$target")
cy=$(tmux -L fm-lab display-message -p -t "$target" '#{cursor_y}')
printf '%s\n' "$pane" > "$E/tmux-$mode.ansi"
printf '%s\n' "$plain" > "$E/tmux-$mode.txt"
for caps in $'styled=1\ncursor=1\nidentity=1' $'styled=1\ncursor=0\nidentity=0' $'styled=1\ncursor=0\nidentity=1'; do
  actual=$(fm_composer_classify_screen "$caps" "$pane" "$cy" $'claude\tidle')
  printf '%s caps=%s cursor=%s verdict=%s\n' "$mode" "${caps//$'\n'/,}" "$cy" "$actual"
  case "$mode" in ghost) test "$actual" = empty ;; wrapped|newline) test "$actual" = pending ;; esac
done
if [ "$mode" = ghost ]; then
 for caps in $'styled=0\ncursor=1\nidentity=1' $'styled=0\ncursor=0\nidentity=1'; do
  actual=$(fm_composer_classify_screen "$caps" "$plain" "$cy" $'claude\tidle')
  printf '%s caps=%s verdict=%s\n' "$mode" "${caps//$'\n'/,}" "$actual"
  test "$actual" = unknown
 done
fi
