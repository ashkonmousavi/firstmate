#!/usr/bin/env bash
set -eu
umask 022
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_PROCEVENT_CLAIM_ROOT="$PWD/.test-phase/boundary-claims" FM_PROCEVENT_OWNER_LEASE_SECONDS=60 FM_PROCEVENT_OWNER_CHECK_SECONDS=1
mkdir -m 700 "$FM_PROCEVENT_CLAIM_ROOT"
for label in a b; do
  home="$PWD/.test-phase/boundary-$label"
  bash bin/fm-lab-home.sh create "$home" >/dev/null
  : > "$home/state/stream"
  FM_HOME="$home" bash bin/fm-procevent.sh register lavish "boundary-$label" -- /usr/bin/tail -f "$home/state/stream"
  FM_HOME="$home" bash bin/fm-procevent.sh reconcile
 done
for _ in $(seq 1 100); do
  test ! -f "$FM_PROCEVENT_CLAIM_ROOT/boundary-a.claim" || test ! -f "$FM_PROCEVENT_CLAIM_ROOT/boundary-b.claim" || break
  sleep .1
 done
pa=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/boundary-a.claim")
pb=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/boundary-b.claim")
printf 'Initial runner pids: A=%s B=%s\n' "$pa" "$pb"
mv .test-phase/boundary-a/state .test-phase/boundary-a/old-state
mkdir -p .test-phase/boundary-a/state/procevent
cp .test-phase/boundary-a/old-state/procevent/.owner-lease .test-phase/boundary-a/state/procevent/.owner-lease
for _ in $(seq 1 100); do
  kill -0 "$pa" 2>/dev/null || break
  sleep .1
 done
if kill -0 "$pa" 2>/dev/null; then echo 'A survived physical root replacement'; exit 1; fi
kill -0 "$pb"
printf 'A stopped despite copied fresh lease; B remains alive at pid %s\n' "$pb"
cat .test-phase/boundary-a/state/procevent/.boundary-a.exits
grep -q 'state_root=changed-or-gone' .test-phase/boundary-a/state/procevent/.boundary-a.exits
FM_HOME="$PWD/.test-phase/boundary-b" bash bin/fm-procevent.sh list
FM_HOME="$PWD/.test-phase/boundary-b" bash bin/fm-procevent.sh sweep-home
FM_HOME="$PWD/.test-phase/boundary-a" bash bin/fm-procevent.sh sweep-home
printf 'LIVE OWNER-ROOT ISOLATION PASSED\n'
