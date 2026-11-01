#!/usr/bin/env bash
# Scenario A: deliberate restart of the real mate while liveness recovery
# (library episode loop + real bootstrap sweep loop) hammers it.
. /tmp/fm-drive-01M6/env.sh
OUT=$EV/scenario-a; mkdir -p $OUT; rm -f $OUT/*
ltmux capture-pane -p -t "firstmate:=fm-$ID" > $OUT/mate-pane-before.txt
cp $LAB/state/$ID.meta $OUT/meta-before.txt
cat $LAB/state/.secondmate-relaunch-$ID > $OUT/ledger-before.txt 2>/dev/null || echo '(no ledger)' > $OUT/ledger-before.txt
touch $OUT/run
( while [ -e $OUT/run ]; do /tmp/fm-drive-01M6/episode.sh >> $OUT/episode.log 2>&1; sleep 0.3; done ) &
h1=$!
( cd $LAB; while [ -e $OUT/run ]; do { echo "== $(date +%T) bootstrap sweep"; labenv FM_BOOTSTRAP_NETWORK=only "$LAB/bin/fm-bootstrap.sh" 2>&1 | grep -i liveness; } >> $OUT/bootstrap.log; sleep 1; done ) &
h2=$!
( while [ -e $OUT/run ]; do if [ -d $LAB/state/.secondmate-liveness-$ID.lock ] || [ -e $LAB/state/.secondmate-liveness-$ID.lock ]; then echo "$(date +%T) liveness-lock held by $(cat $LAB/state/.secondmate-liveness-$ID.lock/pid 2>/dev/null)"; else echo "$(date +%T) liveness-lock free"; fi; sleep 1; done | uniq -f1 >> $OUT/lock-timeline.log ) &
h3=$!
start=$(date +%s)
echo "== restart start $(date +%T)" > $OUT/restart.out
labenv FM_SECONDMATE_PERSIST_WAIT=300 "$LAB/bin/fm-secondmate-restart.sh" "$ID" >> $OUT/restart.out 2>&1
echo "exit=$? elapsed=$(( $(date +%s) - start ))s end=$(date +%T)" >> $OUT/restart.out
sleep 3
rm -f $OUT/run; wait $h1 $h2 $h3 2>/dev/null
/tmp/fm-drive-01M6/episode.sh > $OUT/episode-after.log 2>&1
cp $LAB/state/$ID.meta $OUT/meta-after.txt
cat $LAB/state/.secondmate-relaunch-$ID > $OUT/ledger-after.txt 2>/dev/null || echo '(no ledger)' > $OUT/ledger-after.txt
ltmux list-windows -t firstmate -F '#{window_name}' > $OUT/windows-after.txt
ls -la $LAB/state/ | grep -E 'liveness|spawn-' > $OUT/locks-after.txt || echo '(no liveness/spawn locks)' > $OUT/locks-after.txt
echo done
