#!/usr/bin/env bash
set -eu
code=$1 account=$2 state=$3 root=$4 home=$5
shift 5
export HOME="$account" FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PROGRESS_STALL_SECONDS=2 FM_REMOTE_JOB_QUEUE_TIMEOUT=90 FM_REMOTE_JOB_TIMEOUT=60
. "$code/bin/fm-remote-job-lib.sh"
fm_remote_job_ensure_worker "$root" "$account" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 70; }
fm_remote_job_stage "$account" "$root" "$home" "$@" </dev/null >/dev/null || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 70; }
job=$FM_REMOTE_JOB_ID
fm_remote_job_wait "$account" "$job" || { printf '%s\n' "$FM_REMOTE_JOB_ERROR" >&2; exit 70; }
cat "$FM_REMOTE_JOB_STDOUT"
cat "$FM_REMOTE_JOB_STDERR" >&2
rc=$FM_REMOTE_JOB_EXIT
fm_remote_job_reap "$account" "$job"
exit "$rc"
