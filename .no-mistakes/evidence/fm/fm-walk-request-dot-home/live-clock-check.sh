#!/usr/bin/env bash
set -eu
. bin/fm-timeout-lib.sh
fm_checkpoint_clock
FM_CHECKPOINT_DEADLINE=$((FM_CHECKPOINT_NOW + 3))
start=$FM_CHECKPOINT_NOW
printf 'Initial epoch-compatible deadline: %s\n' "$FM_CHECKPOINT_DEADLINE"
initial=$(fm_checkpoint_budget 25)
printf 'Initial budget: %s\n' "$initial"
[ "$initial" -le 3 ]
SECONDS=$((SECONDS-60))
backward=$(fm_checkpoint_budget 25)
printf 'Budget after shell SECONDS moves backward 60 seconds: %s\n' "$backward"
[ "$backward" -le 3 ]
SECONDS=$((SECONDS+120))
if fm_checkpoint_expired; then echo 'Premature expiry'; exit 1; fi
printf 'Moving shell SECONDS forward 120 seconds did not expire the deadline.\n'
sleep 3
fm_checkpoint_expired
rc=0
fm_checkpoint_budget 25 || rc=$?
printf 'Budget status after actual elapsed interval: %s\n' "$rc"
[ "$rc" -eq 124 ]
printf 'PASS: real checkpoint functions preserve elapsed-time expiry.\n'
