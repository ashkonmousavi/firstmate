#!/usr/bin/env bash
set -eu
root=$1
base=$2
STATE="$FM_HOME/state"
export STATE
# A genuine lock owner exits without releasing, as a crashed restarter would.
bash -c '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_lock sm-live' _ "$root"
printf 'dead owner lock left at %s\n' "$STATE/.secondmate-liveness-sm-live.lock"
. "$root/bin/fm-secondmate-liveness-lib.sh"
fm_secondmate_liveness_lock sm-live
trap 'fm_secondmate_liveness_unlock sm-live' EXIT
printf 'next recovery acquired stale lock\n'
fm_secondmate_liveness_probe "$STATE/sm-live.meta" sm-live poll
printf 'probe=%s state=%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"
[ "$FM_SM_LIVE_STATUS" = relaunchable ]
fm_secondmate_liveness_relaunch "$STATE/sm-live.meta" sm-live 90
printf '%s\n' "$FM_SM_LIVE_OUT"
fm_secondmate_liveness_probe "$STATE/sm-live.meta" sm-live poll
printf 'after recovery probe=%s state=%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE"
[ "$FM_SM_LIVE_STATUS" = alive ]
printf 'relaunch ledger:\n'
cat "$STATE/.secondmate-relaunch-sm-live"
