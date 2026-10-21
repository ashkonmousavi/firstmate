#!/usr/bin/env bash
set -eu
D="$PWD/.test-tmp/remote-live"
mkdir -p "$D/root/bin" "$D/account" "$D/home"
cp bin/fm-remote-job-lib.sh bin/fm-remote-job-worker.sh "$D/root/bin/"
printf 'disposable fixture\n' > "$D/root/AGENTS.md"
cat > "$D/root/bin/fm-evidence-job.sh" <<'JOB'
#!/bin/bash
sleep 4
printf 'remote job executed in %s; active=%s; argument=%s\n' "$FM_HOME" "$FM_REMOTE_JOB_ACTIVE" "$1"
JOB
chmod +x "$D/root/bin/fm-evidence-job.sh"
git -C "$D/root" init -qb main
git -C "$D/root" add .
git -C "$D/root" -c user.name=Test -c user.email=test@example.com commit -qm fixture
export FM_REMOTE_JOB_STATE_ROOT="$D/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
. bin/fm-remote-job-lib.sh
worker=''
cleanup() { [ -z "$worker" ] || { kill -TERM "$worker" 2>/dev/null || true; wait "$worker" 2>/dev/null || true; }; }
trap cleanup EXIT
HOME="$D/account" FM_ROOT_OVERRIDE="$D/root" "$D/root/bin/fm-remote-job-worker.sh" --serve > "$D/worker.log" 2>&1 &
worker=$!
for ((i=0;i<100;i++)); do [ -f "$D/state/worker.ready" ] && break; sleep .1; done
printf 'Worker ownership record:\n'; cat "$D/state/worker.lock/pid" "$D/state/worker.lock/start"
fm_remote_job_recorded_owner_alive "$D/state/worker.lock"
fm_remote_job_stage "$D/account" "$D/root" "$D/home" fm-evidence-job.sh acceptance < /dev/null > /dev/null
id=$FM_REMOTE_JOB_ID
job="$D/state/jobs/$id"
for ((i=0;i<100;i++)); do [ -f "$job/.claim/group_start" ] && break; sleep .05; done
printf 'Running job %s process identities:\n' "$id"
for name in owner supervisor group; do printf '%s=' "$name"; cat "$job/.claim/$name"; printf '%s_start=' "$name"; cat "$job/.claim/${name}_start"; done
fm_remote_job_wait "$D/account" "$id"
[ "$FM_REMOTE_JOB_EXIT" = 0 ]
printf 'Published result: state=%s exit=%s\n' "$(fm_remote_job_read_state "$job")" "$FM_REMOTE_JOB_EXIT"
cat "$job/stdout"
stage="$D/adversarial-stage"
mkdir "$stage"
printf '%s\n' "$worker" > "$stage/.owner-pid"
fm_remote_job_process_start "$worker" > "$stage/.owner-start"
fm_remote_job_stage_owner_alive "$stage"
printf 'Live stage owner accepted with its actual process cookie\n'
printf 'proc-starttime=1\n' > "$stage/.owner-start"
! fm_remote_job_stage_owner_alive "$stage"
kill -0 "$worker"
printf 'Wrong process-start cookie rejected while actual worker remains alive\n'
LC_ALL=C ps -p "$worker" -o lstart= > "$stage/.owner-start"
fm_remote_job_stage_owner_alive "$stage"
printf 'Legacy lstart stage owner accepted across the identity upgrade\n'
