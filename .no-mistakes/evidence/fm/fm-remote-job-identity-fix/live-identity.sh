#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-identity.XXXXXX")
REMOTE_ROOT="$LAB/code"
ACCOUNT="$LAB/account"
REMOTE_HOME="$LAB/home"
mkdir -p "$REMOTE_ROOT/bin" "$ACCOUNT" "$REMOTE_HOME"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
cp bin/fm-remote-job-lib.sh bin/fm-remote-job-worker.sh "$REMOTE_ROOT/bin/"
printf 'Disposable queue validation\n' > "$REMOTE_ROOT/AGENTS.md"
cat > "$REMOTE_ROOT/bin/fm-live-result.sh" <<'JOB'
#!/usr/bin/env bash
printf 'job-started\n'
sleep "$1"
printf 'job-completed\n'
JOB
chmod +x "$REMOTE_ROOT/bin/"*.sh
git -C "$REMOTE_ROOT" init -q -b main
git -C "$REMOTE_ROOT" -c user.name=Validation -c user.email=validation@example.invalid add .
git -C "$REMOTE_ROOT" -c user.name=Validation -c user.email=validation@example.invalid commit -qm 'Disposable validation fixture'
export FM_REMOTE_JOB_STATE_ROOT="$LAB/queue"
export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_TIMEOUT=30 FM_REMOTE_JOB_QUEUE_TIMEOUT=30
. "$REMOTE_ROOT/bin/fm-remote-job-lib.sh"
cleanup() {
  if [ -f "$LAB/queue/worker.pid" ]; then fm_remote_job_stop_worker_tree "$(cat "$LAB/queue/worker.pid")" || true; fi
  rm -rf "$LAB"
}
trap cleanup EXIT
TZ=UTC0 fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT" || { printf 'ensure-error=%s\n' "$FM_REMOTE_JOB_ERROR"; exit 1; }
WORKER=$(cat "$LAB/queue/worker.pid")
BIRTH=$(fm_remote_job_process_start "$WORKER")
GROUP=$(fm_remote_job_process_pgid "$WORKER")
printf 'initial-worker=%s group=%s cookie=%s\n' "$WORKER" "$GROUP" "$BIRTH"
UTC_DATE=$(TZ=UTC0 /bin/ps -p "$WORKER" -o lstart=)
HST_DATE=$(TZ=HST10 /bin/ps -p "$WORKER" -o lstart=)
printf 'ps-UTC=%s\nps-HST=%s\n' "$UTC_DATE" "$HST_DATE"
[ "$UTC_DATE" != "$HST_DATE" ]
fm_remote_job_stage "$ACCOUNT" "$REMOTE_ROOT" "$REMOTE_HOME" fm-live-result.sh 6 </dev/null >/dev/null
JOB=$FM_REMOTE_JOB_ID
JOB_DIR="$LAB/queue/jobs/$JOB"
for _ in $(seq 1 200); do
  [ "$(fm_remote_job_read_state "$JOB_DIR" 2>/dev/null || true)" != running ] || break
  sleep 0.05
done
[ "$(fm_remote_job_read_state "$JOB_DIR")" = running ]
printf 'job=%s state=%s\n' "$JOB" "$(fm_remote_job_read_state "$JOB_DIR")"
for record in "$LAB/queue/worker.lock/start" "$JOB_DIR/.claim/owner_start" "$JOB_DIR/.claim/supervisor_start" "$JOB_DIR/.claim/group_start"; do
  printf 'persisted-%s=%s\n' "${record##*/}" "$(cat "$record")"
  case "$(cat "$record")" in proc-starttime=*) ;; *) exit 1 ;; esac
done
for CALLER_TZ in UTC0 HST10 UTC0; do
  TZ=$CALLER_TZ fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT"
  NOW_PID=$(cat "$LAB/queue/worker.pid")
  NOW_START=$(fm_remote_job_process_start "$NOW_PID")
  NOW_GROUP=$(fm_remote_job_process_pgid "$NOW_PID")
  printf 'ensure-TZ=%s worker=%s group=%s cookie=%s job-state=%s\n' "$CALLER_TZ" "$NOW_PID" "$NOW_GROUP" "$NOW_START" "$(fm_remote_job_read_state "$JOB_DIR")"
  [ "$NOW_PID:$NOW_START:$NOW_GROUP" = "$WORKER:$BIRTH:$GROUP" ]
done
fm_remote_job_wait "$ACCOUNT" "$JOB"
printf 'completed-state=%s exit=%s stdout-begin\n' "$(fm_remote_job_read_state "$JOB_DIR")" "$FM_REMOTE_JOB_EXIT"
cat "$JOB_DIR/stdout"
printf 'stdout-end\n'
[ "$FM_REMOTE_JOB_EXIT" = 0 ]
fm_remote_job_reap "$ACCOUNT" "$JOB"
(
  export FM_REMOTE_JOB_STATE_ROOT="$LAB/guards"
  fm_remote_job_prepare_state "$ACCOUNT"
  LOCK=$(fm_remote_job_worker_lock_path)
  mkdir "$LOCK"
  sleep 60 &
  FIRST=$!
  sleep 0.1
  sleep 60 &
  SECOND=$!
  FIRST_START=$(fm_remote_job_process_start "$FIRST")
  SECOND_START=$(fm_remote_job_process_start "$SECOND")
  [ "$FIRST_START" != "$SECOND_START" ]
  FIRST_COMMAND=$(fm_remote_job_process_command "$FIRST")
  printf '%s\n' "$FIRST" > "$LOCK/pid"
  printf '%s\n' "$FIRST_START" > "$LOCK/start"
  printf '%s\n' "$FIRST_COMMAND" > "$LOCK/command"
  fm_remote_job_lock_owner_matches_process "$ACCOUNT"
  printf 'guard-control=accepted pid=%s cookie=%s\n' "$FIRST" "$FIRST_START"
  printf '%s\n' "$SECOND_START" > "$LOCK/start"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT"; then exit 1; fi
  printf 'tick-mismatch=rejected actual=%s recorded=%s\n' "$FIRST_START" "$SECOND_START"
  printf '%s\n' "$FIRST_START" > "$LOCK/start"
  printf 'wrong-command\n' > "$LOCK/command"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT"; then exit 1; fi
  printf 'command-mismatch=rejected matching-pid-and-cookie=true\n'
  printf '%s\n' "$FIRST_COMMAND" > "$LOCK/command"
  printf '%s\n' "$SECOND" > "$LOCK/pid"
  if fm_remote_job_lock_owner_matches_process "$ACCOUNT"; then exit 1; fi
  printf 'pid-mismatch=rejected first=%s replacement=%s unrelated-alive=' "$FIRST" "$SECOND"
  kill -0 "$SECOND" && printf 'true\n'
  FALLBACK=$(FM_PROC_ROOT_OVERRIDE="$LAB/no-proc" fm_remote_job_process_start "$FIRST")
  PS_START=$(/bin/ps -p "$FIRST" -o lstart=)
  printf 'unavailable-proc-cookie=%s\nactual-ps-cookie=%s\n' "$FALLBACK" "$PS_START"
  [ "$FALLBACK" = "$PS_START" ]
  LIVE_STAGE="$FM_REMOTE_JOB_JOBS/.stage.live"
  DEAD_STAGE="$FM_REMOTE_JOB_JOBS/.stage.stale"
  mkdir "$LIVE_STAGE" "$DEAD_STAGE"
  printf '%s\n' "$FIRST" > "$LIVE_STAGE/.owner-pid"
  printf '%s\n' "$FIRST_START" > "$LIVE_STAGE/.owner-start"
  printf '%s\n' "$FIRST" > "$DEAD_STAGE/.owner-pid"
  printf '%s\n' "$SECOND_START" > "$DEAD_STAGE/.owner-start"
  touch -t 200001010000 "$LIVE_STAGE" "$DEAD_STAGE"
  TZ=HST10 fm_remote_job_reap_stale "$ACCOUNT"
  [ -d "$LIVE_STAGE" ] && [ ! -d "$DEAD_STAGE" ]
  printf 'staging-after-changed-TZ-sweep=live-retained,stale-removed cookie=%s\n' "$(cat "$LIVE_STAGE/.owner-start")"
  kill "$FIRST" "$SECOND"
  wait "$FIRST" 2>/dev/null || true
  wait "$SECOND" 2>/dev/null || true
)
printf 'crash-serving-worker=%s\n' "$WORKER"
kill -KILL "$WORKER"
fm_remote_job_ensure_worker "$REMOTE_ROOT" "$ACCOUNT"
RECOVERED=$(cat "$LAB/queue/worker.pid")
[ "$RECOVERED" != "$WORKER" ]
fm_remote_job_worker_identity_matches "$REMOTE_ROOT" "$ACCOUNT"
printf 'recovered-worker=%s cookie=%s\n' "$RECOVERED" "$(fm_remote_job_process_start "$RECOVERED")"
fm_remote_job_stage "$ACCOUNT" "$REMOTE_ROOT" "$REMOTE_HOME" fm-live-result.sh 0 </dev/null >/dev/null
fm_remote_job_wait "$ACCOUNT" "$FM_REMOTE_JOB_ID"
printf 'recovery-job-exit=%s stdout-begin\n' "$FM_REMOTE_JOB_EXIT"
cat "$LAB/queue/jobs/$FM_REMOTE_JOB_ID/stdout"
printf 'stdout-end\n'
[ "$FM_REMOTE_JOB_EXIT" = 0 ]
fm_remote_job_reap "$ACCOUNT" "$FM_REMOTE_JOB_ID"
printf 'live-product-scenarios=complete\n'
