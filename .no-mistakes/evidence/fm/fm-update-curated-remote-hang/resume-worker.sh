#!/usr/bin/env bash
set -eu
code=$PWD
world=$PWD/.live-validation/world
account=$world/account-remote
state=$world/queue-remote
export HOME="$account" TMPDIR="$PWD/.live-validation/tmp" FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PROGRESS_STALL_SECONDS=2
. "$code/bin/fm-remote-job-lib.sh"
cleanup() {
  [ ! -f "$state/worker.pid" ] || {
    kill -CONT "$(cat "$state/worker.pid")" 2>/dev/null || true
    fm_remote_job_stop_worker_tree "$(cat "$state/worker.pid")"
  }
}
trap cleanup EXIT
fm_remote_job_ensure_worker "$world/remote" "$account" || { echo "$FM_REMOTE_JOB_ERROR"; exit 1; }
pid=$(cat "$state/worker.pid")
kill -STOP "$pid"
for ((i=0;i<220;i++)); do fm_remote_job_probe "$account" || break; sleep .1; done
! fm_remote_job_probe "$account"
printf 'worker %s: readiness stale during stopped serving loop\n' "$pid"
kill -CONT "$pid"
for ((i=0;i<100;i++)); do fm_remote_job_probe "$account" && break; sleep .1; done
fm_remote_job_probe "$account"
fm_remote_job_ensure_worker "$world/remote" "$account" || { echo "$FM_REMOTE_JOB_ERROR"; exit 1; }
[ "$(cat "$state/worker.pid")" = "$pid" ]
printf 'worker %s: readiness resumed; ensure reused the same owner\n' "$pid"
tail -7 "$state/logs/dev.firstmate.remote-job.log"
