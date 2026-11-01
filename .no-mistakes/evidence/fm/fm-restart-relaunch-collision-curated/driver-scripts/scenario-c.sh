#!/usr/bin/env bash
# Scenario C/D: another launch holds the mate's spawn lock (via the real
# fm-wake-lib lock helper) when the restart's own relaunch runs.
# Usage: scenario-c.sh <name> <hold-seconds> <verify-wait>
. /tmp/fm-drive-01M6/env.sh
NAME=$1 HOLD=$2 VW=$3
OUT=$EV/$NAME; mkdir -p $OUT; rm -f $OUT/*
ltmux capture-pane -p -t "firstmate:=fm-$ID" > $OUT/mate-pane-before.txt
/tmp/fm-drive-01M6/episode.sh > $OUT/episode-before.log 2>&1
labenv STATE="$LAB/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.spawn-$2.lock" || { echo "holder: could not acquire" >&2; exit 1; }
  echo "$BASHPID" > "$3/holder-pid"; echo "$(date +%T) holder $BASHPID acquired spawn lock" >> "$3/holder.log"
  /bin/sleep "$4"
  fm_lock_release "$STATE/.spawn-$2.lock"; echo "$(date +%T) holder released spawn lock" >> "$3/holder.log"
' _ "$LAB" "$ID" "$OUT" "$HOLD" </dev/null >/dev/null 2>>$OUT/holder.log &
hp=$!
until [ -s $OUT/holder-pid ]; do sleep 0.1; done
start=$(date +%s)
echo "== restart start $(date +%T) (VERIFY_WAIT=$VW, holder pid $(cat $OUT/holder-pid), hold ${HOLD}s)" > $OUT/restart.out
labenv FM_SECONDMATE_PERSIST_WAIT=300 FM_SECONDMATE_RESTART_VERIFY_WAIT=$VW "$LAB/bin/fm-secondmate-restart.sh" "$ID" >> $OUT/restart.out 2>&1
echo "exit=$? elapsed=$(( $(date +%s) - start ))s end=$(date +%T)" >> $OUT/restart.out
ls -la $LAB/state/ | grep -E 'liveness|spawn-' > $OUT/locks-at-verdict.txt || echo '(no liveness/spawn locks)' > $OUT/locks-at-verdict.txt
kill -0 $hp 2>/dev/null && echo "holder still running at verdict" >> $OUT/locks-at-verdict.txt
ltmux capture-pane -p -t "firstmate:=fm-$ID" > $OUT/mate-pane-at-verdict.txt
/tmp/fm-drive-01M6/episode.sh > $OUT/episode-at-verdict.log 2>&1 &
ep=$!
wait $hp 2>/dev/null; wait $ep
echo done
