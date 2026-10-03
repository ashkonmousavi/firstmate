#!/usr/bin/env bash
set -eu
. bin/fm-remote-job-lib.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-legacy-cookie.XXXXXX")
mkdir "$LAB/account"
export FM_REMOTE_JOB_STATE_ROOT="$LAB/queue"
fm_remote_job_prepare_state "$LAB/account"
LOCK=$(fm_remote_job_worker_lock_path)
mkdir "$LOCK"
sleep 60 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$LAB"' EXIT
printf '%s\n' "$PID" > "$LOCK/pid"
fm_remote_job_process_command "$PID" > "$LOCK/command"
CURRENT=$(fm_remote_job_process_start "$PID")
LEGACY=$(/bin/ps -p "$PID" -o lstart=)
printf '%s\n' "$CURRENT" > "$LOCK/start"
fm_remote_job_lock_owner_matches_process "$LAB/account"
printf 'control=current-cookie-accepted pid=%s cookie=%s\n' "$PID" "$CURRENT"
printf '%s\n' "$LEGACY" > "$LOCK/start"
if fm_remote_job_lock_owner_matches_process "$LAB/account"; then exit 1; fi
kill -0 "$PID"
printf 'legacy-cookie=%s\nlegacy-comparison=rejected matching-live-pid-and-command=true\n' "$LEGACY"
