#!/usr/bin/env bash
set -u
. ./tests/lib.sh
root=$(fm_test_tmproot fm-test-counterfactual)
for mode in bare-signal wait-helper; do
  state="$root/$mode"
  mkdir -p "$state"
  bash -c '
    trap '\''sleep 1; mkdir -p "$1/late"; echo done > "$1/late/shutdown"; exit 0'\'' TERM
    touch "$1/ready"
    while :; do sleep 0.1; done
  ' _ "$state" &
  child=$!
  echo "$child" > "$state/worker.pid"
  for ((i=0; i<100; i++)); do
    [ ! -f "$state/ready" ] || break
    sleep 0.05
  done
  [ -f "$state/ready" ] || { kill -KILL "$child"; wait "$child"; exit 1; }
  if [ "$mode" = bare-signal ]; then
    kill "$child"
  else
    fm_test_stop_remote_job_worker "$state"
    [ -f "$state/late/shutdown" ] || exit 1
    echo 'wait-helper: shutdown write present before removal'
  fi
  fm_test_remove_tree "$state"
  wait "$child" || exit 1
  if [ "$mode" = bare-signal ]; then
    [ -f "$state/late/shutdown" ] || exit 1
    echo 'bare-signal: worker recreated the removed fixture during delayed shutdown (race reproduced)'
  else
    [ ! -e "$state" ] || exit 1
    echo 'wait-helper: worker exited and fixture remained absent after removal'
  fi
done
