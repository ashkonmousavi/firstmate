#!/usr/bin/env bash
# Live lab phase 4: the stuck-lane incident and its stale-claim twin, driven
# through the real bin/fm-teardown.sh against real Treehouse pool copies.
# Trace 1: merged ships lab-a and lab-b plus finished scout lab-t2 all name
#   copy 2, whose claim names lab-t2 (the 2026-10-01 shape).
# Trace 2: ship lab-s has unlanded work in copy 1, whose claim names finished
#   scout lab-t1.
# The extra ship records are written by hand: that shared-copy state is the
# legacy leftover this change has to clean up, and the new spawn guard (phase 2)
# no longer lets a spawn produce it.
set -u
. /home/tegris/.no-mistakes/evidence/01M3VZF72MYDKFSVPWF8SMTY11/lab-env.sh
cd "$WT" || exit 1
POOL=$LAB/pool/.treehouse/demo-55bf35
SLOT1=$POOL/1/demo; SLOT2=$POOL/2/demo
pool_status() { (cd "$PROJ" && TREEHOUSE_ROOT="$LAB/pool" treehouse status 2>&1 | grep -v -i 'new version\|treehouse update'); }
ship_meta() { # <id> <worktree> [branch]
  { printf 'window=firstmate:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\n' "$1" "$1" "$2" "$PROJ"
    printf 'kind=ship\nmode=no-mistakes\nharness=claude\nbackend=tmux\n'
    [ -z "${3:-}" ] || printf 'branch=%s\n' "$3"; } > "$LAB/state/$1.meta"
}
teardown() { # <id> [flags]
  local id=$1; shift
  step "fm-teardown $id $*"
  fm bin/fm-teardown.sh "$id" "$@" 2>&1 | tail -8; echo "rc=${PIPESTATUS[0]}"
  echo "records: $(cd "$LAB/state" && ls -- *.meta 2>/dev/null | tr '\n' ' ')"
  claim; pool_status
}

step "trace 1 setup: lab-a, lab-b (merged ships) and lab-t2 (finished scout) name copy 2"
ship_meta lab-a "$SLOT2"; ship_meta lab-b "$SLOT2"
git -C "$SLOT2" status --short --branch; git -C "$SLOT2" log --oneline -1 --decorate
claim
teardown lab-t2 --force
teardown lab-a
teardown lab-b
teardown lab-t2 --force

step "trace 2 setup: lab-t1 finishes; ship lab-s has unlanded work in copy 1"
fm bin/fm-control.sh lab-t1 exit 2>&1 | tail -1
printf '# Report\nLab scout report.\n' > "$LAB/data/lab-t1/report.md"
git -C "$SLOT1" checkout -q -b fm/lab-s
printf 'unlanded\n' > "$SLOT1/work.txt"
ship_meta lab-s "$SLOT1" fm/lab-s
git -C "$SLOT1" status --short --branch
claim
teardown lab-t1 --force
teardown lab-s
ls "$SLOT1/work.txt" && git -C "$SLOT1" branch --show-current

step "lab-s's work lands (commit + push)"
git -C "$SLOT1" add work.txt
git -C "$SLOT1" -c user.name=lab -c user.email=lab@example.invalid commit -qm work
git -C "$SLOT1" push -q origin fm/lab-s 2>&1
teardown lab-s
teardown lab-t1 --force
git -C "$LAB/src/demo-origin.git" branch --list 'fm/*'
