from pathlib import Path
import os, subprocess, json, shutil, signal, time
root=Path.cwd(); evidence=Path('~/.no-mistakes/evidence/01M6JDN2W8CM7GVHC43VG5248M'); lab=root/'.test-tmp/real-guard'
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True)
shutil.copytree(root/'bin',lab/'bin'); (lab/'AGENTS.md').write_text('Use only the Bash commands requested in the prompt.\n')
subprocess.run(['git','init','-q',str(lab)],check=True)
(lab/'.claude').mkdir()
settings=json.loads((root/'.claude/settings.json').read_text()); selected={}
for event in ['UserPromptSubmit','PreToolUse']:
    selected[event]=[]
    for group in settings['hooks'][event]:
        hooks=[h for h in group['hooks'] if 'fm-claude-watch-guard' in h['command']]
        if hooks: selected[event].append({**group,'hooks':hooks})
(lab/'.claude/settings.json').write_text(json.dumps({'hooks':selected}))
(lab/'state/check-observations').touch()
(lab/'state/live.check.sh').write_text('#!/usr/bin/env bash\ndate +%s >> "$FM_HOME/state/check-observations"\n')
(lab/'state/live.check.sh').chmod(0o700)
env=os.environ.copy()
for key in list(env):
    if key in ['FM_TASK_ID','FM_ROOT','FM_STATE_OVERRIDE','FM_ROOT_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS']: env.pop(key,None)
env.update(FM_HOME=str(lab),FM_POLL='1',FM_CHECK_INTERVAL='1',FM_HEARTBEAT='999999',DISABLE_AUTOUPDATER='1',TMPDIR=str(root/'.test-tmp'),CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false',CLAUDE_CODE_SEND_FEEDBACK='0')
subprocess.run(['bash',str(lab/'bin/fm-check-register.sh'),'live'],env=env,check=True)
(lab/'scenario.sh').write_text('''#!/usr/bin/env bash
set -eu
guard=
repair=
cleanup() {
  touch state/.afk
  [ -z "$guard" ] || kill -CONT "$guard" 2>/dev/null || true
  [ -z "$repair" ] || { kill -TERM "$repair" 2>/dev/null || true; wait "$repair" 2>/dev/null || true; }
}
trap cleanup EXIT
for i in $(seq 1 30); do
  [ ! -f state/.last-watcher-beat ] || break
  sleep 1
done
[ -f state/.last-watcher-beat ] || exit 1
for i in $(seq 1 12); do
  now=$(date +%s)
  beat=$(stat -c %Y state/.last-watcher-beat)
  printf 'sample=%s beat_age_seconds=%s checks=%s\\n' "$i" "$((now-beat))" "$(wc -l < state/check-observations)"
  [ "$((now-beat))" -le 300 ] || exit 1
  sleep 1
done
guard=$(cat state/.claude-watch-guard.lock/pid)
kill -STOP "$guard"
watcher=$(cat state/.watch.lock/pid)
kill -TERM "$watcher"
sleep 1
# The stopped owning guard leaves the authentic owner marker in place.
for beat in stale absent; do
  if [ "$beat" = stale ]; then touch -t 200001010000 state/.last-watcher-beat; else rm -f state/.last-watcher-beat; fi
  rc=0
  env -S 'bash -c' 'bin/fm-send.sh absent-worker hello' > state/send.out 2> state/send.err || rc=$?
  printf '%s send_exit=%s\\n' "$beat" "$rc"; cat state/send.err
  [ "$rc" -eq 2 ] || exit 1
  rc=0
  bin/fm-spawn.sh blocked "$FM_HOME" --scout > state/spawn.out 2> state/spawn.err || rc=$?
  printf '%s spawn_exit=%s\\n' "$beat" "$rc"; cat state/spawn.err
  [ "$rc" -eq 2 ] || exit 1
  command -v bin/fm-send.sh
  command -V bin/fm-spawn.sh
  cat bin/fm-send.sh > /dev/null
  [ ! -e state/blocked.meta ] && [ ! -e state/absent-worker.inbox ] || exit 1
done
# Callers outside guard ownership must reach normal entrypoint validation.
for actor in worker secondmate unmarked; do
  rc=0
  case "$actor" in
    worker) FM_TASK_ID=worker bin/fm-send.sh absent-worker hello > state/scope.out 2> state/scope.err || rc=$? ;;
    secondmate)
      printf 'fixture-mate\\n' > .fm-secondmate-home
      bin/fm-send.sh absent-worker hello > state/scope.out 2> state/scope.err || rc=$?
      rm .fm-secondmate-home ;;
    unmarked)
      mv state/.claude-watch-guard.lock/session state/guard-session
      bin/fm-send.sh absent-worker hello > state/scope.out 2> state/scope.err || rc=$?
      mv state/guard-session state/.claude-watch-guard.lock/session ;;
  esac
  printf 'scope=%s send_exit=%s\\n' "$actor" "$rc"
  [ "$rc" -eq 1 ] && ! grep -q 'New spawns and sends are refused' state/scope.err || exit 1
done
FM_WATCH_HANDLING_SUCCESSOR=1 bin/fm-watch-arm.sh --restart > state/repair.out 2>&1 &
repair=$!
for i in $(seq 1 30); do
  if [ -f state/.last-watcher-beat ] && [ "$(( $(date +%s) - $(stat -c %Y state/.last-watcher-beat) ))" -le 300 ]; then break; fi
  sleep 1
done
[ -f state/.last-watcher-beat ] || exit 1
rc=0
bin/fm-send.sh absent-worker hello > state/fresh.out 2> state/fresh.err || rc=$?
printf 'fresh send_exit=%s\\n' "$rc"; cat state/fresh.err
! grep -q 'New spawns and sends are refused' state/fresh.err || exit 1
cat state/repair.out
# End guard ownership before exercising legacy Stop attachment on real watchers.
touch state/.afk
kill -CONT "$guard"
kill -TERM "$repair" 2>/dev/null || true
wait "$repair" 2>/dev/null || true
repair=
bin/fm-watch-arm.sh --stop >/dev/null 2>&1
for i in $(seq 1 20); do [ -e state/.claude-watch-guard.lock/session ] || break; sleep 1; done
[ ! -e state/.claude-watch-guard.lock/session ] || exit 1
guard=
export FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1
. bin/fm-wake-lib.sh
for host in off on; do
  rm -f state/.afk
  if [ "$host" = off ]; then touch config/supervision-host-off; else rm -f config/supervision-host-off; fi
  fm_wake_append check fixture "unacknowledged handling wake"
  touch state/.last-check
  FM_WATCH_HANDLING_SUCCESSOR=1 bin/fm-watch-arm.sh > "state/owner-$host.out" 2>&1 &
  owner=$!
  for i in $(seq 1 60); do
    fm_watcher_healthy "$STATE" "$PWD/bin/fm-watch.sh" 300 "$FM_HOME" && break
    sleep 1
  done
  fm_watcher_healthy "$STATE" "$PWD/bin/fm-watch.sh" 300 "$FM_HOME" || exit 1
  first=$(cat state/.watch.lock/pid)
  fm_recovery_marker_snapshot state/.watcher-down
  [[ "$FM_RECOVERY_MARKER_TOKEN" == announced:downtime:* ]] || exit 1
  bin/fm-claude-stop-autoarm.sh > "state/stop-$host.out" 2> "state/stop-$host.err" <<EOF_STOP &
{}
EOF_STOP
  stop=$!
  attached=no
  for i in $(seq 1 60); do
    if grep -q "^watcher: attached pid=$first " state/.claude-autoarm-output.* 2>/dev/null; then attached=yes; break; fi
    kill -0 "$first" || exit 1
    sleep 1
  done
  [ "$attached" = yes ] || exit 1
  sleep 1
  kill -0 "$first"
  [ "$(cat state/.watch.lock/pid)" = "$first" ]
  grep -qF "unacknowledged handling wake" state/.wake-queue
  printf 'unguarded_stop host=%s attached_pid=%s preserved=yes pending_wake=yes\\n' "$host" "$first"
  touch state/.afk
  kill -TERM "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  bin/fm-watch-arm.sh --stop >/dev/null 2>&1
  kill -TERM "$stop" 2>/dev/null || true
  wait "$stop" 2>/dev/null || true
done
touch state/scenarios-passed
printf 'REAL_WATCHER_SCENARIOS_PASSED\\n'
''')
prompt='Run exactly these two Bash tool calls in order: 1. bin/fm-lock.sh 2. bash scenario.sh . Do not read any files or use any other tools. After the second command returns say FINISHED and stop. Do not repair or retry failures.'
proc=None
try:
    with (evidence/'real-watcher-transcript.jsonl').open('w') as output:
        proc=subprocess.Popen(['claude','-p',prompt,'--dangerously-skip-permissions','--effort','low','--output-format','stream-json','--verbose'],cwd=lab,env=env,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        code=proc.wait(timeout=240)
    transcript=(evidence/'real-watcher-transcript.jsonl').read_text()
    print('Claude exit:',code)
    if code !=0 or not (lab/'state/scenarios-passed').exists(): raise RuntimeError('live scenario did not complete; inspect transcript')
    for name in ['check-observations','repair.out','send.err','spawn.err','fresh.err']:
        path=lab/'state'/name
        if path.exists(): shutil.copyfile(path,evidence/('real-watcher-'+name))
    print('REAL_WATCHER_SCENARIOS_PASSED')
finally:
    if proc:
        try: os.killpg(proc.pid,signal.SIGTERM)
        except ProcessLookupError: pass
        if proc.poll() is None: proc.wait(timeout=15)
    shutil.rmtree(lab)
