#!/usr/bin/env bash
set -eu
. "$1"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-date-divergence.XXXXXX")
mkdir "$LAB/account"
export FM_REMOTE_JOB_STATE_ROOT="$LAB/jobs"
fm_remote_job_prepare_state "$LAB/account"
LOCK=$(fm_remote_job_worker_lock_path)
mkdir "$LOCK"
sleep 60 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$LAB"' EXIT
printf '%s\n' "$PID" > "$LOCK/pid"
TZ=UTC0 fm_remote_job_process_start "$PID" > "$LOCK/start"
fm_remote_job_process_command "$PID" > "$LOCK/command"
UTC_DATE=$(TZ=UTC0 /bin/ps -p "$PID" -o lstart=)
HST_DATE=$(TZ=HST10 /bin/ps -p "$PID" -o lstart=)
printf 'ps-UTC=%s\nps-HST=%s\n' "$UTC_DATE" "$HST_DATE"
[ "$UTC_DATE" != "$HST_DATE" ]
printf 'recorded-cookie=%s\nHST-cookie=%s\n' "$(cat "$LOCK/start")" "$(TZ=HST10 fm_remote_job_process_start "$PID")"
TZ=UTC0 fm_remote_job_lock_owner_matches_process "$LAB/account"
if TZ=HST10 fm_remote_job_lock_owner_matches_process "$LAB/account"; then
  printf 'same-live-process-under-changed-TZ=accepted\n'
else
  kill -0 "$PID"
  printf 'same-live-process-under-changed-TZ=REJECTED process-still-alive=true\n'
  exit 1
fi
