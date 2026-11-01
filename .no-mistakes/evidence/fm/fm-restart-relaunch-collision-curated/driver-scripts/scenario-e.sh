#!/usr/bin/env bash
# Scenario E: a liveness recovery holds the mate's liveness lock when the restart starts.
# Usage: scenario-e.sh <name> <hold-seconds> <lock-wait>
. /tmp/fm-drive-01M6/env.sh
NAME=$1 HOLD=$2 LW=$3
OUT=$EV/$NAME; mkdir -p $OUT; rm -f $OUT/*
sed -n 's/^spawn_gen=//p' $LAB/state/$ID.meta > $OUT/spawn-gen-before.txt
/tmp/fm-drive-01M6/episode.sh > $OUT/episode-before.log 2>&1
labenv STATE="$LAB/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.secondmate-liveness-$2.lock" || { echo "holder: could not acquire" >&2; exit 1; }
  echo "$BASHPID" > "$3/holder-pid"; echo "$(date +%T) recovery holder $BASHPID acquired liveness lock" >> "$3/holder.log"
  /bin/sleep "$4"
  fm_lock_release "$STATE/.secondmate-liveness-$2.lock"; echo "$(date +%T) recovery holder released liveness lock" >> "$3/holder.log"
' _ "$LAB" "$ID" "$OUT" "$HOLD" </dev/null >/dev/null 2>>$OUT/holder.log &
hp=$!
until [ -s $OUT/holder-pid ]; do sleep 0.1; done
start=$(date +%s)
echo "== restart start $(date +%T) (LOCK_WAIT=$LW, recovery holder pid $(cat $OUT/holder-pid), hold ${HOLD}s)" > $OUT/restart.out
labenv FM_SECONDMATE_PERSIST_WAIT=300 FM_SECONDMATE_RESTART_LOCK_WAIT=$LW "$LAB/bin/fm-secondmate-restart.sh" "$ID" >> $OUT/restart.out 2>&1
echo "exit=$? elapsed=$(( $(date +%s) - start ))s end=$(date +%T)" >> $OUT/restart.out
sed -n 's/^spawn_gen=//p' $LAB/state/$ID.meta > $OUT/spawn-gen-after.txt
wait $hp 2>/dev/null
/tmp/fm-drive-01M6/episode.sh > $OUT/episode-after.log 2>&1
echo done
