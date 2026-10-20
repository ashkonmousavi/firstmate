#!/usr/bin/env bash
set -eu
repo=$PWD
lib=$1
mode=$2
. "$lib"
. "$ROOT/bin/fm-remote-job-lib.sh"
container=$(mktemp -d "$TMPDIR/manual-cleanup.XXXXXX")
owned=$(fm_test_tmproot fm-manual-owned)
outside="$container/outside"
mkdir -p "$owned/account" "$outside/account"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
export FM_REMOTE_JOB_STATE_ROOT="$owned/remote-jobs"
fm_remote_job_ensure_worker "$ROOT" "$owned/account"
owned_pid=$(cat "$owned/remote-jobs/worker.pid")
owned_group=$(fm_remote_job_process_pgid "$owned_pid")
printf 'before cleanup: owned worker pid=%s pgid=%s ready=%s\n' "$owned_pid" "$owned_group" "$(test -f "$owned/remote-jobs/worker.ready" && echo yes)"
export FM_REMOTE_JOB_STATE_ROOT="$outside/remote-jobs"
fm_remote_job_ensure_worker "$ROOT" "$outside/account"
outside_pid=$(cat "$outside/remote-jobs/worker.pid")
finish() {
  fm_remote_job_stop_worker_tree "$owned_pid" || true
  fm_remote_job_stop_worker_tree "$outside_pid" || true
  fm_test_cleanup
  rm -rf "$container"
}
trap finish EXIT
# A stale identity points at the outside worker but has a wrong start cookie.
mkdir -p "$owned/stale/worker.lock"
printf '%s\n' "$outside_pid" > "$owned/stale/worker.lock/pid"
printf '%s\n' wrong-start-cookie > "$owned/stale/worker.lock/start"
fm_remote_job_process_command "$outside_pid" > "$owned/stale/worker.lock/command"
fm_test_cleanup
sleep 2
owned_alive=no
kill -0 -- "-$owned_group" 2>/dev/null && owned_alive=yes
outside_alive=no
kill -0 "$outside_pid" 2>/dev/null && outside_alive=yes
root_present=no
[ ! -e "$owned" ] || root_present=yes
printf 'after cleanup: owned worker group alive=%s; fixture exists=%s; unrelated worker alive=%s\n' "$owned_alive" "$root_present" "$outside_alive"
[ "$outside_alive" = yes ]
if [ "$mode" = baseline ]; then
  [ "$owned_alive" = yes ]
  echo 'BASELINE REPRODUCED: suite cleanup returned while its detached worker remained alive.'
else
  [ "$owned_alive" = no ]
  [ "$root_present" = no ]
  echo 'PASS: cleanup stopped the owned worker and removed its tree without signalling the stale-record/unregistered worker.'
fi
