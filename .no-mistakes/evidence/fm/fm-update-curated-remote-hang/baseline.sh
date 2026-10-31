#!/usr/bin/env bash
set -eu
work=$PWD/.live-validation/world
before=$work/before-code
mkdir -p "$before"
cp -a bin "$before/bin"
cp AGENTS.md "$before/AGENTS.md"
for file in fm-update.sh fm-ff-lib.sh fm-remote-job-lib.sh fm-remote-job-worker.sh; do
  git show "4220467f622e1095bae46961814f305d27418b97:bin/$file" > "$before/bin/$file"
done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
export TMPDIR="$PWD/.live-validation/tmp"
git -C "$before" init -q -b main
git -C "$before" add .
git -C "$before" commit -qm 'base product snapshot for regression counterfactual'
base=$(git -C "$work/seed" rev-list --max-parents=0 HEAD)
git clone -q "$work/origin.git" "$work/before-primary"
git -C "$work/before-primary" checkout -q -B curated "$base"
git clone -q "$work/origin.git" "$work/before-home"
git -C "$work/before-home" checkout -q --detach "$base"
printf 'before-home\n' > "$work/before-home/.fm-secondmate-home"
mkdir -p "$work/before-parent/data" "$work/before-parent/state"
printf -- '- before-home - lab (home: %s/before-home; scope: lab; projects: lab; added 2026-10-31)\n' "$work" > "$work/before-parent/data/secondmates.md"
FM_HOME="$work/before-parent" FM_ROOT_OVERRIDE="$work/before-primary" "$before/bin/fm-update.sh"
[ "$(git -C "$work/before-primary" rev-parse HEAD)" = "$base" ]
main=$(git -C "$work/seed" rev-parse main)
[ "$(git -C "$work/before-home" rev-parse HEAD)" = "$main" ]
printf 'BASELINE REPRODUCED: curated primary skipped at %s; detached home moved to main %s\n' "$base" "$main"
account=$work/account-before
state=$work/queue-before
mkdir -m 700 "$account"
export HOME="$account" FM_REMOTE_JOB_STATE_ROOT="$state" FM_REMOTE_JOB_PROGRESS_STALL_SECONDS=2 FM_REMOTE_JOB_QUEUE_TIMEOUT=90
. "$before/bin/fm-remote-job-lib.sh"
cleanup() {
  [ ! -f "$state/worker.pid" ] || fm_remote_job_stop_worker_tree "$(cat "$state/worker.pid")"
}
trap cleanup EXIT
fm_remote_job_ensure_worker "$before" "$account" || { echo "$FM_REMOTE_JOB_ERROR"; exit 1; }
pid=$(cat "$state/worker.pid")
kill -STOP "$pid"
fm_remote_job_stage "$account" "$before" "$work/before-home" fm-update.sh --help </dev/null >/dev/null
job=$FM_REMOTE_JOB_ID
sleep 15
fm_remote_job_probe "$account"
fm_remote_job_ensure_worker "$before" "$account" || { echo "$FM_REMOTE_JOB_ERROR"; exit 1; }
[ "$(cat "$state/worker.pid")" = "$pid" ]
[ "$(fm_remote_job_read_state "$FM_REMOTE_JOB_JOBS/$job")" = queued ]
printf 'BASELINE REPRODUCED: stopped serving PID %s still probes ready after 15s; ensure reuses it; job %s remains queued\n' "$pid" "$job"
