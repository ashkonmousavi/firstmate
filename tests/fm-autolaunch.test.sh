#!/usr/bin/env bash
# Behavior tests for bin/fm-autolaunch.sh and bin/fm-autolaunch-check.sh.
#
# A real markdown backlog drives bin/fm-tasks-axi.sh; capacity and spawn are
# replaced through the FM_TEST_SEAM hooks with fakes that record their calls.
# The quota gate reads fixture snapshots only.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for the autolaunch backlog fixtures'
TMP_ROOT=$(fm_test_tmproot fm-autolaunch)
AL="$ROOT/bin/fm-autolaunch.sh"
CHECK="$ROOT/bin/fm-autolaunch-check.sh"
H="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$FAKE"
fm_test_tasks_toml "$H/.tasks.toml"
export FM_HOME="$H"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TYPESAFE_API_KEY

# Fake capacity: free lanes from $FAKE/free; the fake spawn spends one.
cat > "$FAKE/capacity" <<'SH'
#!/usr/bin/env bash
free=$(cat "$FAKE_DIR/free")
if [ "$free" -gt 0 ]; then
  printf 'capacity: free_lanes=%s reason=ok lanes=1 target=4\n' "$free"; exit 0
fi
printf 'capacity: free_lanes=0 reason=full lanes=4 target=4\n'; exit 75
SH
# Fake spawn: argv to $FAKE/spawn.log; quota refusal for a harness named in
# $FAKE/quota-refuse; exit code from $FAKE/rc-<id>.
cat > "$FAKE/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/spawn.log"
id=$1; h=
while [ "$#" -gt 0 ]; do [ "$1" = --harness ] && h=$2; shift; done
if [ -n "$h" ] && [ -f "$FAKE_DIR/quota-refuse" ] && grep -qx "$h" "$FAKE_DIR/quota-refuse"; then
  echo "error: fm-spawn refuses explicit harness $h: provider $h runway exhausted_now. Best alternative: none." >&2; exit 1
fi
if [ -f "$FAKE_DIR/rc-$id" ]; then
  rc=$(cat "$FAKE_DIR/rc-$id")
  [ "$rc" = 75 ] && echo "deferred: project capacity for proj is held; task $id stays queued" >&2
  [ "$rc" = 1 ] && echo "error: brief mismatch for $id" >&2
  exit "$rc"
fi
[ ! -f "$FAKE_DIR/rotate-log" ] || mv "$FM_HOME/state/autolaunch.log" "$FM_HOME/state/autolaunch.previous.log"
free=$(cat "$FAKE_DIR/free"); echo $((free - 1)) > "$FAKE_DIR/free"
echo "spawned $id"
SH
chmod +x "$FAKE/capacity" "$FAKE/spawn"
export FAKE_DIR="$FAKE" FM_AUTOLAUNCH_CAPACITY_BIN="$FAKE/capacity" \
  FM_AUTOLAUNCH_SPAWN_BIN="$FAKE/spawn"
LOG="$H/state/autolaunch.log"

backlog() {  # writes the queued section lines given on stdin
  { printf '## In flight\n## Queued\n'; cat; printf '## Done\n- [x] old-done - finished (since 2026-10-01)\n'; } > "$H/data/backlog.md"
}
prep() {  # <id> <project> [extra key=value...]
  local id=$1 project=$2; shift 2
  mkdir -p "$H/data/$id"
  printf '# Task\nbrief for %s\n' "$id" > "$H/data/$id/brief.md"
  printf '# Prep\nprep for %s\n' "$id" > "$H/data/$id/prep.md"
  { printf 'project=%s\nkind=ship\nmode=direct-PR\nyolo=off\n' "$project"; printf '%s\n' "$@"; } > "$H/data/$id/autolaunch-prep"
}
reset() {
  rm -f "$LOG" "$FAKE"/spawn.log "$FAKE"/rc-* "$FAKE/quota-refuse" \
    "$H/config/crew-dispatch.json" "$H/state/.autolaunch-check.red" \
    "$H/config/crew-exclude-tools" "$H/config/pi-account" "$H/config/claude-account" \
    "$FAKE/rotate-log" "$H/state/autolaunch.previous.log" "$H/data/projects.md"
  rm -rf "$H/data"/*/ "$H/state/spawn-deferred"
  printf '%s\n' "${1:-1}" > "$FAKE/free"
}
field() {  # <record-line> <n>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# Builder-owned regressions for independently identified controller defects.
test_controller_agent_identity_refreshes_after_spawn_probe() {
  k1_setup current-agent-probe mate
  cat > "$KF/scheduler" <<'SH'
#!/usr/bin/env bash
bash "$AL_REAL" "$@" || exit $?
if [ "$1" = --controller-spawn-lock ]; then
  python3 - "$FM_HOME/state/$2.meta" "$KF" <<'PYCASE'
import json,os,subprocess,sys
from pathlib import Path
p=subprocess.Popen(['sleep','100000'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
start=Path(f'/proc/{p.pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
Path(sys.argv[1]).write_text(f'agent_root_pid={p.pid}\nagent_root_start={start}\nboot_id='+Path('/proc/sys/kernel/random/boot_id').read_text())
Path(sys.argv[2],'probe-agent.pid').write_text(str(p.pid))
PYCASE
fi
SH
  AL_REAL="$AL" FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 - "$ROOT/bin/fm-autolaunch-steps.py" "$KF/scheduler" "$H" <<'PYCASE' || fail 'an agent published by the real spawn-lock callback must be launched without ownership'
import json,runpy,sys
from pathlib import Path
c=runpy.run_path(sys.argv[1])['Controller'](sys.argv[2]);c.process_snapshot()
r=c.create('ctl-b-launch-k1-probe','k1-probe','launch',['true'])
c.launch_timeout(r,'failed:timeout',False)
r=json.loads(c.path(r['key']).read_text())
assert r['phase']=='complete' and 'handoff' not in r,r
assert 'launched' in Path(sys.argv[3],'state/autolaunch.log').read_text()
PYCASE
  k1_teardown
  pass 'timeout reconciliation rereads current agent identity after its one real spawn-lock probe'
}

test_controller_late_agent_identity_is_current() {
  k1_setup current-agent-closure mate
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 - "$ROOT/bin/fm-autolaunch-steps.py" "$AL" "$H/state" <<'PYCASE' || fail 'late closure requires current matching PID/start/boot evidence'
import json,runpy,subprocess,sys
from pathlib import Path
c=runpy.run_path(sys.argv[1])['Controller'](sys.argv[2]);state=Path(sys.argv[3])
for mode in ('appeared','dead','start-mismatch','boot-mismatch'):
    r=c.create('ctl-b-launch-'+mode,mode,'launch',['true']);c.own(r,'failed:timeout',False)
    c.process_snapshot()
    p=subprocess.Popen(['sleep','100000'])
    try:
        start=c.identity(p.pid)
        (state/(mode+'.meta')).write_text(f'agent_root_pid={p.pid}\nagent_root_start={start}\nboot_id={c.boot}\n')
        if mode!='appeared': c.process_snapshot()
        if mode=='dead': p.terminate();p.wait()
        if mode=='start-mismatch': (state/(mode+'.meta')).write_text(f'agent_root_pid={p.pid}\nagent_root_start=1\nboot_id={c.boot}\n')
        if mode=='boot-mismatch': (state/(mode+'.meta')).write_text(f'agent_root_pid={p.pid}\nagent_root_start={start}\nboot_id=wrong\n')
        c.launch_timeout(r,'failed:timeout',False)
        saved=json.loads(c.path(r['key']).read_text())
        assert bool(saved.get('closed'))==(mode=='appeared'),(mode,saved)
        if mode=='appeared': assert saved['close_handoff']['receipt'],saved
    finally:
        if p.poll() is None: p.terminate();p.wait()
PYCASE
  k1_teardown
  pass 'late-agent closure accepts newly live identities and rejects dead or mismatched cached evidence'
}

controller_ordered_spawn_fixture() {
  cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KF/spawn.log"
if [ "$1" = k1-first ] && [ -e "$KF/project-full" ]; then echo 'deferred: project full'; exit 75; fi
free=$(cat "$KF/free")
[ "$free" -gt 0 ] || { echo 'deferred: machine full'; exit 75; }
printf '%s\n' "$1" >> "$KF/launched"
echo $((free - 1)) > "$KF/free"
SH
  chmod +x "$KB/spawn"
}

test_controller_project_refusal_preserves_lane_order() {
  k1_setup project-order mate
  k1_ready k1-first k1-second
  mkdir "$H/projects/other"
  git init -q "$H/projects/proj"
  git init -q "$H/projects/other"
  prep k1-second other
  printf 'proj 1\n' > "$H/config/project-capacity"
  printf 'kind=ship\nproject=%s/projects/proj\n' "$H" > "$H/state/holder.meta"
  : > "$KF/project-full"
  controller_ordered_spawn_fixture
  k1_pass 0; k1_pass 55
  assert_equals k1-second "$(cat "$KF/launched")" 'project-full first item yields the only free machine lane to the eligible second item'
  assert_equals 0 "$(cat "$KF/free")" 'one machine lane permits one launch'
  rm "$H/state/holder.meta" "$KF/project-full"
  printf '1\n' > "$KF/free"
  k1_pass 110; k1_pass 165
  assert_equals $'k1-second\nk1-first' "$(cat "$KF/launched")" 'clearing temporary project capacity restores the first item without replaying completed work'
  k1_teardown
  pass 'project-capacity refusal yields to later ready work and is reconsidered after capacity clears'
}

test_controller_saved_lane_rechecks_project_capacity() {
  local token rc=0
  k1_setup saved-project-admission mate
  k1_ready k1-first k1-second
  mkdir "$H/projects/other"
  git init -q "$H/projects/proj"
  git init -q "$H/projects/other"
  prep k1-second other
  printf 'proj 1\nother 1\n' > "$H/config/project-capacity"
  printf 'kind=ship\nproject=%s/projects/proj\n' "$H" > "$H/state/holder.meta"
  controller_save_pending_launch
  controller_ordered_spawn_fixture
  k1_pass 0
  token=$(cat "$KF/pending-action")
  printf 'kind=ship\nproject=%s/projects/other\n' "$H" > "$H/state/other-holder.meta"
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" || rc=$?
  expect_code 75 "$rc" 'a saved second task cannot bypass a newly full project'
  assert_absent "$KF/launched" 'saved commands refresh project admission before invoking spawn'
  rm "$H/state/other-holder.meta"
  prep k1-second other base_branch=refreshed
  k1_pass 55
  token=$(cat "$KF/pending-action")
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" || fail 'cleared project capacity permits the saved eligible task'
  assert_equals k1-second "$(cat "$KF/launched")" 'the matching saved task launches once after capacity clears'
  assert_contains "$(cat "$KF/spawn.log")" '--base-branch refreshed' 'the admitted second task receives current argv'
  k1_teardown
  pass 'saved lane actions refresh project capacity and argv before spending the machine lane'
}

test_controller_blocked_rows_do_not_reserve_lanes() {
  local phase row
  for phase in retry-wait exhausted owned running complete; do
    k1_setup "lane-$phase" mate
    k1_ready k1-first k1-second
    controller_save_pending_launch
    k1_pass 0
    row="$H/state/autolaunch-controller/ctl-b-launch-k1-first.json"
    python3 - "$row" "$phase" "$K1_T0" <<'PYCASE'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads(p.read_text());r.update(phase=sys.argv[2],due=int(sys.argv[3])+10000)
if sys.argv[2]=='owned': r['handoff']=dict(payload='owned',request='1'*32,receipt=True)
p.write_text(json.dumps(r))
PYCASE
    k1_write_stubs
    controller_ordered_spawn_fixture
    k1_pass 55; k1_pass 110
    assert_equals k1-second "$(cat "$KF/launched")" "$phase first item cannot consume a hypothetical lane"
    assert_equals 0 "$(cat "$KF/free")" 'eligible work respects the existing machine lane limit'
    k1_teardown
  done
  k1_setup lane-priority mate
  k1_ready k1-first k1-second
  controller_ordered_spawn_fixture
  k1_pass 0; k1_pass 55
  assert_equals k1-first "$(cat "$KF/launched")" 'the original first item keeps priority when both are eligible'
  k1_teardown
  pass 'backoff, terminal, active and completed rows yield lanes while eligible queue priority is retained'
}

controller_save_pending_launch() {
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$KF/pending-action"
printf '%s\n' "$*" >> "$KF/queued-units.log"
exit 0
SH
}

controller_result_tail_setup() {
  case "$1" in
    launch) k1_ready k1-tail ;;
    step) k1_ready k1-tail; printf '0\n' > "$KF/free"; printf 'act k1-tail\n' > "$H/config/autolaunch-steps" ;;
    ring) k1_inbox_due k1-tail ;;
    remote-inbox) printf 'kind=secondmate\nremote_host=fixture.invalid\n' > "$H/state/k1-tail.meta" ;;
  esac
  controller_save_pending_launch
  k1_pass 0
}

controller_publish_result_tail() {
  python3 - "$1" "$KF" "$H/state" "$2" "$3" <<'PYCASE' &
import fcntl,json,os,sys,time
from pathlib import Path
p,fake,state=map(Path,sys.argv[1:4]);r=json.loads(p.read_text());root=p.parent
with (state/'autolaunch-slots'/(r['key']+'.lock')).open('a') as slot:
    fcntl.flock(slot,fcntl.LOCK_EX)
    identity=dict(pid=os.getpid(),start=Path('/proc/self/stat').read_text().rsplit(') ',1)[1].split()[19],boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
    (root/(r['attempt']+'.identity')).write_text(json.dumps(identity))
    result=dict(rc=int(sys.argv[4]),wait=sys.argv[5],at=int((fake/'clock').read_text()))
    (root/(r['attempt']+'.result')).write_text(json.dumps(result))
    (fake/'tail-original-result.json').write_text(json.dumps(result))
    (fake/'result-tail-ready').write_text('ready')
    while not (fake/'result-tail-release').exists(): time.sleep(.02)
PYCASE
  RESULT_TAIL_PID=$!
  k1_wait_file "$KF/result-tail-ready" || fail 'the result fixture must hold the actual slot with a matching live identity'
}

controller_result_tail_row() {
  python3 - "$H/state/autolaunch-controller" "$1" <<'PYCASE'
import json,sys
from pathlib import Path
print(next(p for p in Path(sys.argv[1]).glob('ctl-*.json') if json.loads(p.read_text())['kind']==sys.argv[2]))
PYCASE
}

test_controller_all_outcomes_wait_for_attempt_settlement() {
  local kind outcome row token rc wait_condition held_at resume_at
  for kind in step ring remote-inbox launch; do
    for outcome in deferred quota failure; do
      k1_setup "outcome-tail-$kind-$outcome" mate
      controller_result_tail_setup "$kind"
      row=$(controller_result_tail_row "$kind")
      token=$(cat "$KF/pending-action")
      rc=75; wait_condition=
      if [ "$outcome" = quota ]; then rc=1; wait_condition=quota; fi
      [ "$outcome" != failure ] || rc=1
      controller_publish_result_tail "$row" "$rc" "$wait_condition"
      k1_pass 25
      held_at=50; resume_at=75
      if [ "$outcome" = failure ]; then held_at=90; resume_at=145; fi
      k1_pass "$held_at"
      python3 - "$row" "$token" "$KF/tail-original-result.json" <<'PYCASE' || fail 'deferred, quota and failed receipts must retain their original attempt through restarted discovery and promotion'
import json,sys
from pathlib import Path
p=Path(sys.argv[1]);r=json.loads(p.read_text())
assert r['generation']==1 and r['attempt']==sys.argv[2],r
assert json.loads((p.parent/(sys.argv[2]+'.result')).read_text())==json.loads(Path(sys.argv[3]).read_text()),r
PYCASE
      assert_equals 1 "$(grep -c . "$KF/queued-units.log")" 'no replacement unit may run into an occupied outcome-producing wrapper'
      : > "$KF/result-tail-release"
      wait "$RESULT_TAIL_PID" || fail 'the matching wrapper must exit and release its slot'
      k1_pass "$resume_at"
      python3 - "$row" "$token" <<'PYCASE' || fail 'eligible work must resume within the same generation using a fresh attempt after release'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['generation']==1 and r['attempt']!=sys.argv[2],r
PYCASE
      assert_equals 2 "$(grep -c . "$KF/queued-units.log")" 'settlement permits exactly one eligible redispatch'
      k1_pass $((resume_at + 25))
      assert_equals 2 "$(grep -c . "$KF/queued-units.log")" 'the replacement is not submitted twice'
      assert_equals 0 "$(k1_count "$LOG" "${token%-g1*}" failed:timeout)" 'a replacement may not create a false timeout while the old receipt is retained'
      k1_teardown
    done
  done
  pass 'all deferred, quota and failed outcomes preserve identity/slot settlement before attempt replacement'
}

test_controller_published_results_keep_r9_supervision() {
  local kind row token limit
  for kind in step ring remote-inbox; do
    k1_setup "published-r9-$kind" mate
    controller_result_tail_setup "$kind"
    row=$(controller_result_tail_row "$kind")
    token=$(cat "$KF/pending-action")
    limit=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print(r["deadline"]-r["started"])' "$H/state/autolaunch-controller/$token")
    controller_publish_result_tail "$row" 75 ''
    k1_pass 25
    k1_pass $((limit + 25))
    python3 - "$row" "$token" <<'PYCASE' || fail 'an early result cannot hide an execution that survives its deadline and grace'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['attempt']==sys.argv[2] and r['handoff']['receipt'],r
PYCASE
    assert_equals 1 "$(grep -c . "$KF/queued-units.log")" 'deadline ownership cannot replace the still-held attempt'
    : > "$KF/result-tail-release"
    wait "$RESULT_TAIL_PID" || fail 'the surviving result wrapper must release normally'
    k1_pass $((limit + 80))
    assert_equals 2 "$(grep -c . "$KF/queued-units.log")" 'ordinary deferred work resumes once after real execution settlement'
    k1_teardown
  done
  pass 'published deferrals retain bounded R9 supervision and resume after identity/slot settlement'
}

test_controller_rung2_owns_before_wrapper_release() {
  local mode row token
  for mode in release expire; do
    k1_setup "rung2-tail-$mode" mate
    controller_result_tail_setup ring
    row=$(controller_result_tail_row ring)
    token=$(cat "$KF/pending-action")
    printf '{"rc":1,"at":%s,"wait":""}\n' "$(k1_now)" > "$H/state/autolaunch-controller/$token.result"
    k1_pass 55; k1_pass 165
    token=$(cat "$KF/pending-action")
    printf '{"rc":1,"at":%s,"wait":""}\n' "$(k1_now)" > "$H/state/autolaunch-controller/$token.result"
    k1_pass 220; k1_pass 385
    token=$(cat "$KF/pending-action")
    controller_publish_result_tail "$row" 1 ''
    k1_pass 410; k1_pass 435
    python3 - "$row" "$token" "$K1_T0" <<'PYCASE' || fail 'rung-2 ownership must publish within its bound without replacing the occupied attempt'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
assert r['rung']==2 and r['attempt']==sys.argv[2] and r['handoff']['receipt'],r
assert r['owned_at']-int(sys.argv[3])<=480,r
PYCASE
    assert_equals 0 "$(k1_count "$KF/queued-units.log" RuntimeMaxSec=900)" 'diagnosis cannot overwrite an occupied rung-2 attempt'
    if [ "$mode" = expire ]; then
      k1_pass 685
      python3 - "$row" <<'PYCASE' || fail 'diagnosis queue expiry must progress even while the prior execution remains occupied'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['phase']=='exhausted',r
PYCASE
      assert_equals 1 "$(k1_count "$H/state/autolaunch-diag/${token%-g1*}-summary.md" skipped-capacity)" 'the occupied queue records one bounded capacity skip'
    fi
    : > "$KF/result-tail-release"
    wait "$RESULT_TAIL_PID" || fail 'the failed-rung wrapper must release its slot'
    if [ "$mode" = release ]; then k1_pass 460; else k1_pass 740; fi
    if [ "$mode" = release ]; then
      assert_equals 1 "$(k1_count "$KF/queued-units.log" RuntimeMaxSec=900)" 'eligible diagnosis starts once after the failed execution settles'
    else
      assert_equals 0 "$(k1_count "$KF/queued-units.log" RuntimeMaxSec=900)" 'expired diagnosis remains expired after settlement'
    fi
    assert_equals 1 "$(k1_owned k1-tail | grep -c .)" 'queueing and settlement never duplicate rung-2 ownership'
    k1_teardown
  done
  pass 'rung-2 ownership and queue bounds remain independent of execution settlement and diagnosis admission'
}

test_controller_timeout_stops_inflight_profile_fallback() {
  local mode token row process_pid rc
  for mode in timely overdue; do
    k1_setup "fallback-terminal-$mode" mate
    k1_ready k1-profile-tail
    printf '%s\n' '{"shared_quota":true,"default":[{"harness":"codex","model":"gpt-5.5"},{"harness":"claude","model":"opus"}]}' > "$H/config/crew-dispatch.json"
    controller_save_pending_launch
    cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KF/spawn.log"
case " $* " in
  *' --harness codex '*)
    printf 'ready\n' > "$KF/first-profile-ready"
    while [ ! -e "$KF/first-profile-finish" ]; do "$REAL_SLEEP" 0.02; done
    echo 'error: fm-spawn refuses explicit harness codex: provider codex runway exhausted_now' >&2
    exit 1 ;;
esac
exit 0
SH
    chmod +x "$KB/spawn"
    k1_pass 0
    token=$(cat "$KF/pending-action")
    row="$H/state/autolaunch-controller/ctl-b-launch-k1-profile-tail.json"
    if [ "$mode" = timely ]; then rc=30; else rc=590; fi
    printf '%s\n' $((K1_T0 + rc)) > "$KF/clock"
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" > "$KF/profile-action.out" 2>&1 &
    process_pid=$!
    k1_wait_file "$KF/first-profile-ready" || fail 'the first eligible candidate must be executing before ownership changes'
    if [ "$mode" = overdue ]; then
      k1_pass 625; k1_pass 680
      python3 - "$row" "$KF/profile-handoff.json" <<'PYCASE' || fail 'the overdue first candidate must have a stable terminal ownership record'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['handoff']['receipt'],r
Path(sys.argv[2]).write_text(json.dumps(r['handoff']))
PYCASE
    fi
    : > "$KF/first-profile-finish"
    wait "$process_pid" 2>/dev/null || true
    if [ "$mode" = timely ]; then
      assert_equals 2 "$(k1_count "$KF/spawn.log" k1-profile-tail)" 'ordinary pre-timeout fallback reaches the next eligible profile'
    else
      assert_equals 1 "$(k1_count "$KF/spawn.log" k1-profile-tail)" 'late quota refusal cannot invoke a second candidate after timeout ownership'
      k1_pass 735
      python3 - "$row" "$KF/profile-handoff.json" "$H/state/autolaunch-controller/$token" <<'PYCASE' || fail 'in-flight cancellation preserves ownership and actual executed-model attribution'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); h=json.loads(Path(sys.argv[2]).read_text()); a=json.loads(Path(sys.argv[3]).read_text())
assert r['handoff']==h and a['model']=='codex:gpt-5.5',r
assert json.loads(Path(sys.argv[3]+'.result').read_text())['wait']=='quota'
PYCASE
    fi
    k1_teardown
  done
  pass 'in-flight fallback rechecks terminal ownership before each candidate while ordinary fallback remains available'
}

test_controller_saved_terminal_launch_commands_do_not_execute() {
  local kind row token rc
  for kind in launch relaunch recovery; do
    k1_setup "saved-terminal-$kind" mate
    k1_ready k1-saved-terminal
    controller_save_pending_launch
    k1_pass 0
    token=$(cat "$KF/pending-action")
    row="$H/state/autolaunch-controller/ctl-b-launch-k1-saved-terminal.json"
    python3 - "$row" "$H/state/autolaunch-controller/$token" "$kind" <<'PYCASE'
import json,sys
from pathlib import Path
for name in sys.argv[1:3]:
    p=Path(name); r=json.loads(p.read_text()); r['kind']=sys.argv[3]; p.write_text(json.dumps(r))
PYCASE
    k1_pass 625
    controller_publish_result_tail "$row" 0 ''
    rc=0
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" > "$KF/saved-terminal.out" 2>&1 || rc=$?
    expect_code 75 "$rc" 'saved launch-family commands refuse execution after durable timeout ownership'
    assert_absent "$KF/spawn.log" 'first candidate invocation must honor a terminal same-key obligation'
    python3 - "$H/state/autolaunch-controller/$token.result" <<'PYCASE' || fail 'refused saved execution must publish its own controlled result receipt'
import json,sys
from pathlib import Path
assert json.loads(Path(sys.argv[1]).read_text())['rc']==75
PYCASE
    cp "$H/state/autolaunch-controller/$token.result" "$KF/first-refusal.json"
    printf '%s\n' $(( $(k1_now) + 1 )) > "$KF/clock"
    rc=0
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" > "$KF/replayed-terminal.out" 2>&1 || rc=$?
    expect_code 75 "$rc" 'replayed terminal commands remain controlled refusals'
    cmp -s "$H/state/autolaunch-controller/$token.result" "$KF/first-refusal.json" || fail 'terminal replay cannot overwrite an existing refusal receipt'
    : > "$KF/result-tail-release"
    wait "$RESULT_TAIL_PID" || fail 'the current occupied action must remain intact during stale-command refusal'
    k1_teardown
  done
  pass 'saved launch, relaunch and recovery commands reread terminal ownership before their first invocation'
}

test_controller_timeout_handoff_rejects_late_results() {
  local kind outcome token row process_pid result_at
  for kind in launch relaunch recovery; do
    for outcome in failure deferred quota; do
      k1_setup "terminal-$kind-$outcome" mate
      k1_ready k1-terminal
      controller_save_pending_launch
      cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$KF/spawn.log"
printf 'ready\n' > "$KF/spawn-ready"
while [ ! -e "$KF/spawn-finish" ]; do "$REAL_SLEEP" 0.02; done
case "$(cat "$KF/late-outcome")" in
  failure) echo 'unexpected fault'; exit 1 ;;
  deferred) exit 75 ;;
  quota) echo 'error: fm-spawn refuses explicit harness codex: provider runway exhausted_now'; exit 1 ;;
esac
SH
      chmod +x "$KB/spawn"
      printf '%s\n' "$outcome" > "$KF/late-outcome"
      k1_pass 0
      token=$(cat "$KF/pending-action")
      row="$H/state/autolaunch-controller/ctl-b-launch-k1-terminal.json"
      python3 - "$row" "$H/state/autolaunch-controller/$token" "$kind" <<'PYCASE'
import json,sys
from pathlib import Path
for name in sys.argv[1:3]:
    p=Path(name); r=json.loads(p.read_text()); r['kind']=sys.argv[3]; p.write_text(json.dumps(r))
PYCASE
      printf '%s\n' $((K1_T0 + 590)) > "$KF/clock"
      FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
        python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" > "$KF/late-action.out" 2>&1 &
      process_pid=$!
      k1_wait_file "$KF/spawn-ready" || fail 'the delayed action must reach the actual spawn boundary'
      k1_pass 625
      python3 - "$row" "$KF/terminal-handoff.json" <<'PYCASE' || fail 'the surviving launch must first publish timeout ownership'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['phase']=='running' and r['handoff']['receipt'],r
Path(sys.argv[2]).write_text(json.dumps(r['handoff']))
PYCASE
      : > "$KF/spawn-finish"
      wait "$process_pid" 2>/dev/null || true
      k1_wait_file "$H/state/autolaunch-controller/$token.result" || fail 'the real action must publish its late failure or deferral'
      for result_at in 680 1010 1395 2055; do
        k1_pass "$result_at"
        python3 - "$row" "$KF/terminal-handoff.json" <<'PYCASE' || fail 'late results and restarted promotion/discovery cannot restore launch retries'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); original=json.loads(Path(sys.argv[2]).read_text())
assert r['phase'] not in ('queued','wait','retry-wait') and r['rung']==0,r
assert r['handoff']==original,r
PYCASE
        assert_equals 1 "$(k1_count "$KF/queued-units.log" RuntimeMaxSec=600)" 'timeout ownership forbids a second launch/relaunch/recovery unit'
        assert_equals 1 "$(k1_count "$KF/spawn.log" k1-terminal)" 'a late action result cannot cause another spawn'
      done
      python3 - "$K1/agent/claude" "$H/state/k1-terminal.meta" <<'PYCASE'
import subprocess,sys
from pathlib import Path
p=subprocess.Popen([sys.argv[1],'100000'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True)
start=Path(f'/proc/{p.pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
with Path(sys.argv[2]).open('a') as f:
    f.write(f'agent_root_pid={p.pid}\nagent_root_start={start}\nboot_id='+Path('/proc/sys/kernel/random/boot_id').read_text().strip()+'\n')
PYCASE
      k1_pass 2110
      assert_equals 1 "$(k1_count "$H/state/k1-terminal.status" resolved launched-late)" 'terminal timeout handling still recognizes and closes a later live agent'
      assert_equals 1 "$(k1_owned k1-terminal | grep -c .)" 'late failure/deferral and later closure keep one ownership record'
      k1_teardown
    done
  done
  pass 'timeout handoffs stay terminal across late failure, deferral and quota results for all launch kinds'
}

controller_notice_publication_fault() {
  cat > "$KB/fault-controller.py" <<'PYCASE'
import os,runpy,signal,sys
from pathlib import Path
source=Path(os.environ['ROOT'])/'bin/fm-autolaunch-steps.py'
module=runpy.run_path(str(source))
original=module['Controller'].save
def publish(self,row):
    original(self,row)
    if row['kind']=='notice' and 'handoff' not in row:
        (Path(os.environ['KF'])/'notice-published').write_text(row['key'])
        os.kill(os.getpid(),signal.SIGKILL)
module['Controller'].save=publish
sys.argv=[str(source),*sys.argv[1:]]
sys.exit(module['main']() or 0)
PYCASE
}

test_controller_notice_publication_is_not_executable() {
  local producer answered key rc
  for producer in technical busy cut error; do
    for answered in open answered; do
      [ "$producer" = technical ] || [ "$answered" = open ] || continue
      k1_setup "notice-$producer-$answered" mate
      controller_notice_publication_fault
      printf '%s\n' $((K1_T0 + 220)) > "$KF/clock"
      rc=0
      case "$producer" in
        technical)
          printf 'needs-decision [key=api] [at=%s]: choose interval\n' "$K1_T0" > "$H/state/k1-notice.status"
          FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$KB/fault-controller.py" controller-plan "$AL" > "$KF/fault.out" 2>&1 || rc=$?
          ;;
        busy)
          k1_pass_lock_holder
          k1_pass 55; k1_pass 110
          printf '%s\n' $((K1_T0 + 165)) > "$KF/clock"
          FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$KB/fault-controller.py" controller-effects "$AL" 73 > "$KF/fault.out" 2>&1 || rc=$?
          kill "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null || true; K1_HOLDER=
          rm -rf "$H/state/.autolaunch.lock"
          ;;
        cut)
          mkdir -p "$H/state/autolaunch-controller"
          printf '{"cuts":2,"cut_at":%s}\n' "$K1_T0" > "$H/state/autolaunch-controller/pass.json"
          FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$KB/fault-controller.py" controller-effects "$AL" 124 > "$KF/fault.out" 2>&1 || rc=$?
          ;;
        error)
          FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" python3 "$KB/fault-controller.py" controller-effects "$AL" 1 > "$KF/fault.out" 2>&1 || rc=$?
          ;;
      esac
      expect_code 137 "$rc" 'fault injection must stop immediately after the first durable notice publication'
      key=$(cat "$KF/notice-published")
      python3 - "$H/state/autolaunch-controller/$key.json" <<'PYCASE' || fail 'a notice must be non-executable even at its first durable publication'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['kind']=='notice' and r['phase']!='queued' and 'handoff' not in r,r
PYCASE
      if [ "$answered" = answered ]; then
        printf 'resolved [key=api] [at=%s]: answered\n' $((K1_T0 + 235)) >> "$H/state/k1-notice.status"
      fi
      k1_inbox_due k1-unrelated
      k1_pass 275; k1_pass 330
      assert_equals 0 "$(tail -1 "$KF/pass-rc.log" | cut -f2)" 'restart after interrupted publication must keep the pass functional'
      assert_equals 0 "$(k1_count "$KF/systemd-run.log" "$key")" 'a notice never requests an executable transient unit'
      [ "$(k1_units_max_count 60 k1-unrelated)" -ge 1 ] || fail 'notice recovery cannot suppress unrelated due delivery'
      if [ "$producer" = technical ] && [ "$answered" = open ]; then
        assert_equals 1 "$(k1_owned k1-notice | grep -c .)" 'a still-open technical source can finish publishing its real handoff'
      else
        python3 - "$H/state/autolaunch-controller/$key.json" <<'PYCASE' || fail 'an unpublished orphan cannot invent ownership or a receipt'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert 'handoff' not in r and r['phase']!='queued',r
PYCASE
      fi
      k1_teardown
    done
  done
  pass 'technical and busy/cut/error notices stay non-executable through interrupted publication and restart'
}

test_controller_legacy_queued_notices_do_not_block_actions() {
  k1_setup legacy-notices mate
  k1_ready k1-slice
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  printf '0\n' > "$KF/free"
  mkdir -p "$H/state/autolaunch-controller"
  python3 - "$H/state/autolaunch-controller" "$K1_T0" <<'PYCASE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
for key in ('ctl-c-ask-legacy','ctl-e-pass-lock-legacy','ctl-e-pass-interrupted','ctl-e-pass-error'):
    (root/(key+'.json')).write_text(json.dumps(dict(key=key,kind='notice',task='',phase='queued',argv=[],rung=0,generation=1,opened=int(sys.argv[2]),overrun=0)))
PYCASE
  k1_inbox_due k1-unrelated
  k1_pass 0; k1_pass 55
  assert_equals 0 "$(tail -1 "$KF/pass-rc.log" | cut -f2)" 'legacy queued notices must recover without deadline lookup failures'
  [ "$(k1_units_max_count 120)" -ge 1 ] || fail 'legacy notices cannot block unrelated leased steps'
  [ "$(k1_units_max_count 60 k1-unrelated)" -ge 1 ] || fail 'legacy notices cannot block unrelated non-seat delivery'
  python3 - "$H/state/autolaunch-controller" <<'PYCASE' || fail 'legacy notice repair cannot execute or synthesize ownership'
import json,sys
from pathlib import Path
for p in Path(sys.argv[1]).glob('ctl-*.json'):
    r=json.loads(p.read_text())
    if r['kind']=='notice': assert r['phase']!='queued' and 'attempt' not in r and 'handoff' not in r,r
PYCASE
  k1_teardown
  pass 'legacy queued notices recover safely while seat and non-seat actions continue'
}

test_controller_success_receipt_waits_for_execution_and_slot() {
  local kind row token holder_pid slot_pid at
  for kind in step ring remote-inbox; do
    k1_setup "success-slot-$kind" mate
    printf '0\n' > "$KF/free"
    case "$kind" in
      step) k1_ready k1-tail; printf 'act k1-tail\n' > "$H/config/autolaunch-steps" ;;
      ring) k1_inbox_due k1-tail ;;
      remote-inbox) printf 'kind=secondmate\nremote_host=fixture.invalid\n' > "$H/state/k1-tail.meta" ;;
    esac
    controller_save_pending_launch
    k1_pass 0
    token=$(cat "$KF/pending-action")
    row=$(python3 - "$H/state/autolaunch-controller" "$kind" <<'PYCASE'
import json,sys
from pathlib import Path
print(next(p for p in Path(sys.argv[1]).glob('ctl-*.json') if json.loads(p.read_text())['kind']==sys.argv[2]))
PYCASE
    )
    python3 - "$row" "$KF" "$H/state" <<'PYCASE' &
import fcntl,json,os,sys,time
from pathlib import Path
p,fake,state=map(Path,sys.argv[1:]);r=json.loads(p.read_text());root=p.parent
with (state/'autolaunch-slots'/(r['key']+'.lock')).open('a') as slot:
    fcntl.flock(slot,fcntl.LOCK_EX)
    identity=dict(pid=os.getpid(),start=Path('/proc/self/stat').read_text().rsplit(') ',1)[1].split()[19],boot_id=Path('/proc/sys/kernel/random/boot_id').read_text().strip())
    (root/(r['attempt']+'.identity')).write_text(json.dumps(identity))
    (root/(r['attempt']+'.result')).write_text(json.dumps(dict(rc=0,at=int((fake/'clock').read_text()),wait='')))
    (fake/'success-held').write_text('ready')
    while not (fake/'release-slot').exists(): time.sleep(.02)
(fake/'slot-released').write_text('ready')
while not (fake/'exit-main').exists(): time.sleep(.02)
PYCASE
    holder_pid=$!
    k1_wait_file "$KF/success-held" || fail 'a matching live main must publish success while holding the real slot'
    for at in 55 110; do
      k1_pass "$at"
      python3 - "$row" "$token" <<'PYCASE' || fail 'published success cannot replace a generation whose matching main and slot remain live'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['generation']==1 and r['attempt']==sys.argv[2],r
PYCASE
      assert_equals 1 "$(grep -c . "$KF/queued-units.log")" 'a held completed action cannot request another unit'
    done
    : > "$KF/release-slot"
    k1_wait_file "$KF/slot-released" || fail 'the holder must release its real flock before the identity-only check'
    k1_pass 165
    assert_equals 1 "$(grep -c . "$KF/queued-units.log")" 'a released slot alone cannot replace a still-live matching execution'
    : > "$KF/exit-main"
    wait "$holder_pid" || fail 'the matching execution must exit normally'
    python3 - "$row" "$KF" "$H/state" <<'PYCASE' &
import fcntl,json,sys,time
from pathlib import Path
p,fake,state=map(Path,sys.argv[1:]);r=json.loads(p.read_text())
with (state/'autolaunch-slots'/(r['key']+'.lock')).open('a') as slot:
    fcntl.flock(slot,fcntl.LOCK_EX)
    (fake/'other-slot-held').write_text('ready')
    while not (fake/'other-slot-release').exists(): time.sleep(.02)
PYCASE
    slot_pid=$!
    k1_wait_file "$KF/other-slot-held" || fail 'a separate real holder must exercise the slot-only boundary'
    k1_pass 220
    assert_equals 1 "$(grep -c . "$KF/queued-units.log")" 'a dead main alone cannot replace a generation whose slot is still occupied'
    : > "$KF/other-slot-release"
    wait "$slot_pid" || fail 'the real slot holder must release normally'
    k1_pass 275
    python3 - "$row" "$token" <<'PYCASE' || fail 'settled execution and slot must permit exactly the next recurring generation'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['generation']==2 and r['attempt']!=sys.argv[2],r
PYCASE
    assert_equals 2 "$(grep -c . "$KF/queued-units.log")" 'recurrence resumes once after both identity and slot settle'
    assert_equals 0 "$(k1_count "$LOG" "${token%-g1*}" failed:timeout)" 'success-tail suspension cannot manufacture an action timeout'
    k1_teardown
  done
  pass 'all recurring kinds wait for the matching main and real slot to settle after a success receipt'
}

controller_recurring_handoff_case() {
  local kind=$1 route_home=$2 row token limit deadline request close_request body
  k1_setup "recurring-handoff-$kind-$route_home" "$route_home"
  printf '0\n' > "$KF/free"
  case "$kind" in
    step)
      k1_ready k1-recurring
      printf 'act k1-recurring\n' > "$H/config/autolaunch-steps"
      ;;
    ring) k1_inbox_due k1-recurring ;;
    remote-inbox) printf 'kind=secondmate\nremote_host=fixture.invalid\n' > "$H/state/k1-recurring.meta" ;;
  esac
  cp "$KB/systemd-run" "$KB/systemd-run-original"
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
python3 - "$@" <<'PYCASE'
import json,os,sys
from pathlib import Path
root=Path(os.environ['KF'])
(root/'pending-unit.json').write_text(json.dumps(sys.argv[1:]))
with (root/'requested-actions').open('a') as f: f.write(sys.argv[-1]+'\n')
PYCASE
SH
  chmod +x "$KB/systemd-run"
  k1_pass 0
  IFS=$'\t' read -r row token limit deadline < <(python3 - "$H/state/autolaunch-controller" "$kind" <<'PYCASE'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
p=next(p for p in root.glob('ctl-*.json') if json.loads(p.read_text())['kind']==sys.argv[2])
r=json.loads(p.read_text()); a=json.loads((root/r['attempt']).read_text())
print(p,r['attempt'],a['deadline']-a['started'],a['deadline'],sep='\t')
PYCASE
  )
  export FM_RECUR_KEY REAL_BASH
  FM_RECUR_KEY=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["key"])' "$row")
  REAL_BASH=$(command -v bash)
  printf 'fail\n' > "$KF/opener-gate"
  printf 'fail\n' > "$KF/closure-gate"
  {
    printf '#!%s\n' "$REAL_BASH"
    cat <<'SH'
if [ "${1:-}" = "$ROOT/bin/fm-autolaunch.sh" ]; then
  case "${2:-}:${3:-}" in
    --steps-only:*|--controller-ring:*|--controller-remote-inbox:run)
      printf 'ready\n' > "$KF/action-entered"
      while [ ! -e "$KF/action-finish" ]; do "$REAL_SLEEP" 0.02; done
      exit 0 ;;
  esac
fi
if [ "${1##*/}" = fm-status-append.sh ] && [ "${5:-}" = "$FM_RECUR_KEY" ]; then
  gate=opener
  [ "${3:-}" != resolved ] || gate=closure
  mode=$(cat "$KF/$gate-gate")
  [ "$mode" != fail ] || exit 1
  "$REAL_BASH" "$@" || exit $?
  if [ "$mode" = uncertain ]; then
    printf 'ok\n' > "$KF/$gate-gate"
    printf 'accepted\n' > "$KF/$gate-crashed"
    kill -KILL "$PPID"
  fi
  exit 0
fi
exec "$REAL_BASH" "$@"
SH
  } > "$KB/bash"
  chmod +x "$KB/bash"
  cp "$KB/fm-send" "$KB/fm-send-original"
  cat > "$KB/fm-send" <<'SH'
#!/usr/bin/env bash
case "${3:-}" in
  "$FM_RECUR_KEY "*)
    gate=opener
    case "$3" in "$FM_RECUR_KEY resolved "*) gate=closure ;; esac
    mode=$(cat "$KF/$gate-gate")
    [ "$mode" != fail ] || exit 1
    "$KB/fm-send-original" "$@" || exit $?
    if [ "$mode" = uncertain ]; then
      printf 'ok\n' > "$KF/$gate-gate"
      printf 'accepted\n' > "$KF/$gate-crashed"
      kill -KILL "$PPID"
    fi
    exit 0 ;;
esac
exec "$KB/fm-send-original" "$@"
SH
  chmod +x "$KB/fm-send"
  printf '%s\n' $((deadline - 10)) > "$KF/clock"
  PATH="$KB:$PATH" python3 - "$KB/systemd-run-original" "$KF/pending-unit.json" <<'PYCASE' || fail 'the delayed service must activate through the existing unit fixture'
import json,subprocess,sys
from pathlib import Path
sys.exit(subprocess.run([sys.argv[1],*json.loads(Path(sys.argv[2]).read_text())]).returncode)
PYCASE
  k1_wait_file "$KF/action-entered" || fail 'the delayed action must execute and retain its real slot'
  k1_wait_file "$H/state/autolaunch-controller/$token.identity" || fail 'the delayed action must publish its real identity'
  assert_equals "$((deadline - 10))" "$(k1_units_max_start 1 "$limit")" 'runtime starts later than the original controller deadline origin'
  k1_slot_locks_free && fail 'the running action must still occupy its slot'
  deadline=$((deadline - K1_T0 + 5))
  k1_pass "$deadline"
  request=$(python3 - "$row" "$KF/retained-generation.json" <<'PYCASE'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
assert r['phase']=='running' and not r['handoff']['receipt'],r
Path(sys.argv[2]).write_text(json.dumps(r))
print(r['handoff']['request'])
PYCASE
  ) || fail 'controller expiry must preserve the surviving action and its failed handoff'
  : > "$KF/action-finish"
  k1_wait_file "$H/state/autolaunch-controller/$token.result" || fail 'the delayed action must publish its actual successful result'
  python3 - "$H/state/autolaunch-controller/$token.result" <<'PYCASE' || fail 'the success receipt is the real action result'
import json,sys
from pathlib import Path
assert json.loads(Path(sys.argv[1]).read_text())['rc']==0
PYCASE
  for body in 25 80 135; do
    k1_pass $((deadline + body))
    python3 - "$row" "$KF/retained-generation.json" <<'PYCASE' || fail 'success and restarted discovery must retain the pending generation and all dispatch metadata'
import json,sys
from pathlib import Path
r,old=[json.loads(Path(p).read_text()) for p in sys.argv[1:]]
for key in ('generation','attempt','argv','dispatch','handoff'):
    assert r[key]==old[key],(key,r,old)
assert r['phase']=='complete' and not r.get('closed') and 'close_handoff' in r,r
PYCASE
    assert_equals 1 "$(grep -c . "$KF/requested-actions")" 'pending ownership cannot start another recurring generation'
  done
  close_request=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["close_handoff"]["request"])' "$row")
  printf 'uncertain\n' > "$KF/opener-gate"
  k1_pass $((deadline + 190))
  k1_wait_file "$KF/opener-crashed" || fail 'the opener must be accepted before its controller receipt can be saved'
  k1_pass $((deadline + 245))
  python3 - "$row" "$request" "$close_request" <<'PYCASE' || fail 'accepted opener replay must retain the unsettled closure and original identities'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
assert r['generation']==1 and r['handoff']['receipt'] and not r.get('closed'),r
assert r['handoff']['request']==sys.argv[2] and r['close_handoff']['request']==sys.argv[3],r
assert not r['close_handoff']['receipt'],r
PYCASE
  assert_equals 1 "$(grep -c . "$KF/requested-actions")" 'an accepted opener cannot recur before its closure settles'
  printf 'uncertain\n' > "$KF/closure-gate"
  k1_pass $((deadline + 300))
  k1_wait_file "$KF/closure-crashed" || fail 'closure must be accepted before the receipt-saving process is lost'
  k1_pass $((deadline + 355))
  python3 - "$row" <<'PYCASE' || fail 'recurrence must resume with exactly the next generation after settlement'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['generation']==2 and r['phase']=='running' and 'handoff' not in r,r
PYCASE
  assert_equals 2 "$(grep -c . "$KF/requested-actions")" 'settled completion creates exactly one next recurring attempt'
  k1_pass $((deadline + 380))
  assert_equals 2 "$(grep -c . "$KF/requested-actions")" 'the pending next unit is not dispatched twice'
  if [ "$route_home" = main ] && [ "$kind" != ring ]; then
    assert_equals 1 "$(k1_count "$KF/accepted" "$request")" 'MAIN accepts the original opener once'
    assert_equals 1 "$(k1_count "$KF/accepted" "$close_request")" 'MAIN accepts its stable closure once'
    assert_equals 1 "$(k1_lines "$KF/send.log" "$FM_RECUR_KEY owned" | cut -f3 | sort -u | grep -c .)" 'uncertain opener retries keep one request identity'
    assert_equals 1 "$(k1_lines "$KF/send.log" "$FM_RECUR_KEY resolved" | cut -f3 | sort -u | grep -c .)" 'uncertain closure retries keep one request identity'
  else
    body=autolaunch
    [ "$kind" != ring ] || body=k1-recurring
    assert_equals 1 "$(k1_count "$H/state/$body.status" blocked "$FM_RECUR_KEY" 'generation=1')" 'local status accepts the original generation opener once'
    assert_equals 1 "$(k1_count "$H/state/$body.status" resolved "$FM_RECUR_KEY" 'generation=1')" 'local status accepts the original generation closure once'
  fi
  k1_teardown
  unset FM_RECUR_KEY REAL_BASH
}

test_controller_step_handoff_survives_successful_recurrence() {
  controller_recurring_handoff_case step mate
  controller_recurring_handoff_case step main
  pass 'delayed successful steps settle durable ownership and closure before recurring on both routes'
}

test_controller_ring_handoff_survives_successful_recurrence() {
  controller_recurring_handoff_case ring mate
  pass 'delayed successful rings preserve pending opener and closure through restart before recurring'
}

test_controller_remote_handoff_survives_successful_recurrence() {
  controller_recurring_handoff_case remote-inbox mate
  controller_recurring_handoff_case remote-inbox main
  pass 'delayed successful remote inbox actions settle both routes before the next generation'
}

test_controller_busy_steps_reconcile_technical_decisions() {
  local n at
  k1_setup busy-technical mate
  k1_ready k1-slice
  printf '0\n' > "$KF/free"
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  printf 'mode=no-mistakes\n' > "$H/state/k1-slice.meta"
  cat > "$KB/step-nm" <<'SH'
#!/usr/bin/env bash
printf 'ready\n' > "$KF/step-reading"
while [ ! -e "$KF/step-go" ]; do "$REAL_SLEEP" 0.02; done
printf 'state: unknown\n'
SH
  chmod +x "$KB/step-nm"
  export FM_AUTOLAUNCH_STEPS_NM_BIN="$KB/step-nm"
  for n in 0 1 2 3 4 5 6 7 8 9; do
    at=0; [ "$n" -lt 5 ] || at=40
    printf 'needs-decision [key=api-shape] [at=%s]: choose interval\n' $((K1_T0 + at)) > "$H/state/k1-busy-key-$n.status"
  done
  k1_pass 165
  k1_wait_file "$KF/step-reading" || fail 'the first legal step must hold the actual primary lock'
  assert_equals "$((K1_T0 + 185))" "$(k1_units_max_start 1 120)" 'the concrete technical-key timeline starts its step at t185'
  k1_pass 220
  python3 - "$H/state/autolaunch-controller" "$K1_T0" <<'PYCASE' || fail 'all ten technical keys must be owned within their 255-second bound during a legal step'
import json,sys
from pathlib import Path
root,zero=Path(sys.argv[1]),int(sys.argv[2])
rows=[json.loads(p.read_text()) for p in root.glob('ctl-c-ask-*.json')]
assert len(rows)==10,len(rows)
for r in rows:
    assert r['handoff']['receipt'] and r['owned_at']-r['source_at']<=255,r
PYCASE
  printf '%s\n' $((K1_T0 + 235)) > "$KF/clock"
  for n in 0 1 2 3 4; do
    printf 'resolved [key=api-shape] [at=%s]: answered\n' $((K1_T0 + 230)) >> "$H/state/k1-busy-key-$n.status"
    if [ "$n" -lt 3 ]; then
      printf 'needs-decision [key=api-shape] [at=%s]: choose replacement\n' $((K1_T0 + 235)) >> "$H/state/k1-busy-key-$n.status"
    fi
  done
  k1_pass 275
  for n in 0 1 2 3 4; do
    assert_equals 1 "$(k1_count "$H/state/k1-busy-key-$n.status" resolved ctl-c-ask-)" 'answer and reopen must close the prior occurrence on a busy pass'
  done
  printf '%s\n' $((K1_T0 + 300)) > "$KF/clock"
  : > "$KF/step-go"
  controller_wait_action_receipt ctl-a-step || fail 'the first legal step must finish at t300'
  rm "$KF/step-reading" "$KF/step-go"
  k1_pass 330
  k1_wait_file "$KF/step-reading" || fail 'the second legal step must hold the actual primary lock'
  k1_pass 440
  for n in 0 1 2 3 4 5 6 7 8 9; do
    if [ "$n" -lt 3 ]; then at=2; else at=1; fi
    assert_equals "$at" "$(k1_owned "k1-busy-key-$n" | grep -c .)" 'busy reconciliation must reopen only the changed source occurrences'
  done
  python3 - "$H/state/autolaunch-controller" "$K1_T0" <<'PYCASE' || fail 'reopened occurrences must keep their own age and one bounded handoff'
import json,sys
from pathlib import Path
root,zero=Path(sys.argv[1]),int(sys.argv[2])
for p in root.glob('ctl-c-ask-*.json'):
    r=json.loads(p.read_text())
    if r['task'] in ('k1-busy-key-0','k1-busy-key-1','k1-busy-key-2'):
        assert r['generation']==2 and r['source_at']==zero+235,r
        assert r['handoff']['receipt'] and r['owned_at']<=zero+490,r
PYCASE
  assert_equals 0 "$(k1_units_max_count 900)" 'unattended technical keys never start diagnosis'
  printf '%s\n' $((K1_T0 + 465)) > "$KF/clock"
  : > "$KF/step-go"
  controller_wait_action_receipt ctl-a-step || fail 'the second legal step must finish before its deadline'
  unset FM_AUTOLAUNCH_STEPS_NM_BIN
  k1_teardown
  pass 'legal busy steps preserve ten-key age, source closure and reopen bounds without diagnosis'
}

controller_lock_closure_restart_case() {
  local kind=$1 mode row request
  for mode in fail uncertain; do
    k1_setup "closure-$kind-$mode" "$kind"
    k1_pass_lock_holder
    k1_pass 55; k1_pass 110; k1_pass 165
    row=$(printf '%s\n' "$H"/state/autolaunch-controller/ctl-e-pass-lock-*.json)
    kill "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null || true
    K1_HOLDER=
    rm -rf "$H/state/.autolaunch.lock"
    if [ "$kind" = mate ]; then
      if [ "$mode" = fail ]; then
        mv "$H/state/autolaunch.status" "$KF/saved.status"
        mkdir "$H/state/autolaunch.status"
      else
        export REAL_BASH
        REAL_BASH=$(command -v bash)
        {
          printf '#!%s\n' "$REAL_BASH"
          cat <<'SH'
if [ "${1##*/}" = fm-status-append.sh ] && [ "${3:-}" = resolved ] && [ ! -e "$KF/closure-crashed" ]; then
  "$REAL_BASH" "$@" || exit $?
  : > "$KF/closure-crashed"
  kill -KILL "$PPID"
  exit 0
fi
exec "$REAL_BASH" "$@"
SH
        } > "$KB/bash"
        chmod +x "$KB/bash"
      fi
    else
      if [ "$mode" = fail ]; then printf 'fail\n' > "$KF/send-mode"; else printf 'crash\n' > "$KF/send-mode"; fi
    fi
    k1_pass 220
    request=$(python3 - "$row" <<'PYCASE'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
assert 'close_handoff' in r and not r.get('closed'),r
assert not r['close_handoff'].get('receipt',False),r
print(r['close_handoff']['request'])
PYCASE
    ) || fail 'the first acquired pass must persist closure intent before failed or uncertain delivery'
    if [ "$kind" = mate ] && [ "$mode" = fail ]; then
      rmdir "$H/state/autolaunch.status"
      mv "$KF/saved.status" "$H/state/autolaunch.status"
    fi
    k1_pass_lock_holder
    printf '%s\n' $((K1_T0 + 275)) > "$H/state/.autolaunch.lock/at"
    k1_inbox_due k1-rering
    k1_pass 275
    python3 - "$row" "$request" <<'PYCASE' || fail 'a restarted busy pass must finish the prior closure with the original identity'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text())
assert r['closed'] and r['close_handoff']['receipt'],r
assert r['close_handoff']['request']==sys.argv[2],r
PYCASE
    assert_equals 1 "$(k1_units_max_count 60 k1-rering)" 'closure reconciliation cannot suppress another due re-ring'
    if [ "$kind" = mate ]; then
      assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'retrying closure cannot duplicate its accepted opener'
      assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'local closure is accepted exactly once for its generation'
    else
      assert_equals 2 "$(grep -c . "$KF/accepted")" 'MAIN accepts exactly one opener and one closure'
      assert_equals 1 "$(k1_lines "$KF/send.log" "${request}" | cut -f3 | sort -u | grep -c .)" 'MAIN retries retain the persisted closure identity'
    fi
    k1_pass 330; k1_pass 385
    python3 - "$row" <<'PYCASE' || fail 'the different verified live holder must open a fresh incident generation'
import json,sys
from pathlib import Path
r=json.loads(Path(sys.argv[1]).read_text()); assert r['generation']==2 and r['handoff']['receipt'] and not r.get('closed'),r
PYCASE
    assert_equals 2 "$(k1_count "$LOG" ctl-e-pass-lock- ' owned ')" 'there is one accepted ownership event per incident generation'
    k1_alive "$K1_HOLDER" || fail 'closure retry cannot steal or kill the next live holder'
    if [ "$kind" = mate ]; then
      assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'the first generation closure cannot replay into the next incident'
    else
      assert_equals 3 "$(grep -c . "$KF/accepted")" 'a new MAIN incident adds one fresh opener without replaying the prior closure'
    fi
    k1_teardown
    unset REAL_BASH
  done
}

test_controller_local_closure_retry_survives_busy_restart() {
  controller_lock_closure_restart_case mate
  pass 'local closure intent survives failure, uncertain append, restart and a different busy holder'
}

test_controller_main_closure_retry_survives_busy_restart() {
  controller_lock_closure_restart_case main
  pass 'MAIN closure keeps its request identity through failure, uncertainty, restart and a new incident'
}

test_controller_runtime_quota_falls_through_profiles() {
  local mode token rc
  for mode in normal saved all retry; do
    k1_setup "profile-$mode" mate
    k1_ready k1-profile
    printf '%s\n' '{"shared_quota":true,"default":[{"harness":"codex","model":"gpt-5.5"},{"harness":"claude","model":"opus"}]}' > "$H/config/crew-dispatch.json"
    printf '%s\n' "$mode" > "$KF/profile-mode"
    cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
harness=
while [ "$#" -gt 0 ]; do [ "$1" != --harness ] || harness=$2; shift; done
if [ "$(cat "$KF/profile-mode")" = retry ]; then
  echo 'error: unknown fixture failure' >&2; exit 1
fi
if [ "$harness" = codex ] || [ "$(cat "$KF/profile-mode")" = all ]; then
  echo "error: fm-spawn refuses explicit harness $harness: provider $harness runway exhausted_now. Best alternative: none." >&2
  exit 1
fi
echo 'spawned k1-profile'
SH
    if [ "$mode" = saved ] || [ "$mode" = all ]; then
      controller_save_pending_launch
    fi
    k1_pass 0
    if [ "$mode" = retry ]; then
      controller_wait_action_receipt ctl-b-launch-k1-profile || fail 'the initial unknown failure must complete'
      k1_pass 55
      printf 'normal\n' > "$KF/profile-mode"
      k1_pass 165
    elif [ "$mode" = saved ] || [ "$mode" = all ]; then
      token=$(cat "$KF/pending-action")
      prep k1-profile proj base_branch=refreshed
      rc=0
      FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
        python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" || rc=$?
      if [ "$mode" = all ]; then
        expect_code 1 "$rc" 'all runtime quota refusals retain the final failed spawn code'
      else
        expect_code 0 "$rc" 'a saved action must reach its next eligible profile'
      fi
    fi
    controller_wait_action_receipt ctl-b-launch-k1-profile || fail 'the bounded profile attempt must publish one result'
    k1_pass_lock_holder
    k1_pass 220
    python3 - "$H/state/autolaunch-controller" "$KF/spawn.log" "$mode" <<'PYCASE' || fail 'ordered fallback must finish within one unchanged action identity and deadline'
import json,sys
from pathlib import Path
root, log, mode=Path(sys.argv[1]),Path(sys.argv[2]),sys.argv[3]
row=json.loads((root/'ctl-b-launch-k1-profile.json').read_text())
attempt=json.loads((root/row['attempt']).read_text())
result=json.loads((root/(row['attempt']+'.result')).read_text())
lines=log.read_text().splitlines()
assert len(lines)==(3 if mode=='retry' else 2),lines
assert '--harness codex' in lines[-2] and '--harness claude' in lines[-1],lines
assert attempt['deadline']-attempt['started']==600,attempt
assert attempt['argv'][attempt['argv'].index('--harness')+1]=='claude',attempt
if mode in ('saved','all'):
    assert all('--base-branch refreshed' in line for line in lines),lines
if mode=='all':
    assert result['wait']=='quota' and result['rc']==1,result
else:
    assert result['rc']==0 and not result['wait'],result
assert row['dispatch']==(2 if mode=='retry' else 1),row
assert row['model']=='claude:opus',row
assert row['phase']==('wait' if mode=='all' else 'complete'),row
if mode=='all': assert row['rung']==0 and row['wait']=='quota' and 'handoff' not in row,row
PYCASE
    k1_teardown
  done
  pass 'runtime quota refusal falls through current profiles within one action, including saved and retry paths'
}

test_controller_busy_step_preserves_launch_deadline() {
  local started task
  k1_setup busy-launch-bound mate
  k1_ready k1-due k1-late k1-alive k1-slice
  printf '3\n' > "$KF/free"
  printf 'hung-child-exits\n' > "$KF/spawn-mode"
  printf 'ctl-b-launch-k1-alive\nctl-b-launch-k1-late\n' > "$KF/unkillable-match"
  k1_pass 0
  k1_wait_file "$KF/holder-k1-due.pid" || fail 'the bounded launch must start'
  started=$(k1_units_max_start 1 600 k1-due)
  assert_equals "$((K1_T0 + 20))" "$started" 'the concrete timeline starts launch at t20'
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  printf 'mode=no-mistakes\n' > "$H/state/k1-slice.meta"
  cat > "$KB/step-nm" <<'SH'
#!/usr/bin/env bash
printf 'ready\n' > "$KF/step-reading"
while [ ! -e "$KF/step-go" ]; do "$REAL_SLEEP" 0.02; done
printf 'state: unknown\n'
SH
  chmod +x "$KB/step-nm"
  export FM_AUTOLAUNCH_STEPS_NM_BIN="$KB/step-nm"
  k1_pass 550
  k1_wait_file "$KF/step-reading" || fail 'the leased step must hold the real primary lock'
  assert_equals "$((K1_T0 + 570))" "$(k1_units_max_start 1 120)" 'the concrete bounded step starts at t570'
  k1_pass 605
  k1_pass 660
  for task in k1-due k1-late k1-alive; do
    assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'a busy recording pass must deliver the due handoff within 680 seconds of launch'
    assert_equals 1 "$(k1_units_max_count 600 "$task")" 'busy reconciliation cannot duplicate a launch'
  done
  assert_equals 0 "$(k1_units_max_count 900)" 'a busy pass cannot start fresh diagnosis work'
  python3 - "$H/state/autolaunch-controller" <<'PYCASE' || fail 'a surviving main must preserve its identity and occupied slot on the busy pass'
import fcntl,json,sys
from pathlib import Path
root=Path(sys.argv[1]); row=json.loads((root/'ctl-b-launch-k1-alive.json').read_text())
identity=json.loads((root/(row['attempt']+'.identity')).read_text())
assert Path(f"/proc/{identity['pid']}/stat").read_text().rsplit(') ',1)[1].split()[19]==identity['start']
with (root.parent/'autolaunch-slots'/"ctl-b-launch-k1-alive.lock").open('a') as lock:
    try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: raise AssertionError('surviving action released its slot')
PYCASE
  python3 - "$K1/agent/claude" "$H/state/k1-late.meta" <<'PYCASE'
from pathlib import Path
import subprocess,sys
p=subprocess.Popen([sys.argv[1],'100000'],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
start=Path(f'/proc/{p.pid}/stat').read_text().rsplit(') ',1)[1].split()[19]
Path(sys.argv[2]).write_text(f'agent_root_pid={p.pid}\nagent_root_start={start}\nboot_id='+Path('/proc/sys/kernel/random/boot_id').read_text())
PYCASE
  k1_pass 675
  assert_equals 1 "$(k1_count "$LOG" k1-late 'resolved launched-late')" 'the busy pass must close a late start without a new ownership record'
  python3 - "$H/state/autolaunch-controller/ctl-b-launch-k1-late.json" <<'PYCASE' || fail 'closing a late key must retain its live action accounting'
import json,sys
from pathlib import Path
row=json.loads(Path(sys.argv[1]).read_text()); assert row['closed'] and row['phase']=='running',row
PYCASE
  printf '%s\n' $((K1_T0 + 685)) > "$KF/clock"
  : > "$KF/step-go"
  controller_wait_action_receipt ctl-a-step || fail 'the leased step must finish at t685'
  : > "$KF/unkillable-match"
  k1_pass 715
  assert_equals 1 "$(k1_count "$LOG" k1-alive failed:timeout)" 'a surviving main that later exits must reconcile its timeout'
  assert_equals 1 "$(k1_count "$LOG" k1-late failed:timeout)" 'a resolved late key must still reconcile its gone main timeout'
  assert_equals 1 "$(k1_owned k1-alive | grep -c .)" 'the later exit cannot create a second ownership record'
  assert_equals 1 "$(k1_units_max_count 600 k1-alive)" 'the later exit cannot retry a timed-out launch'
  flock -n "$H/state/autolaunch-slots/ctl-b-launch-k1-alive.lock" true || fail 'the gone main must release its existing slot'
  unset FM_AUTOLAUNCH_STEPS_NM_BIN
  k1_teardown
  pass 'busy bounded steps retain the t20 launch handoff bound, late closure, and surviving identity'
}

test_controller_busy_pass_reconciles_receipt_siblings() {
  k1_setup busy-receipts mate
  k1_ready k1-diag
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  cat > "$KB/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\tcodex %s\n' "$(cat "$KF/clock")" "$*" >> "$KF/diag.log"
while [ ! -e "$KF/diag-go" ]; do "$REAL_SLEEP" 0.02; done
SH
  k1_pass 0
  controller_wait_action_receipt ctl-b-launch-k1-diag || fail 'the first failed launch must finish'
  k1_pass 55; k1_pass 165
  controller_wait_action_receipt ctl-b-launch-k1-diag || fail 'the first retry must finish'
  k1_pass 220; k1_pass 385
  controller_wait_action_receipt ctl-b-launch-k1-diag || fail 'the second retry must finish'
  k1_pass 440
  k1_wait_file "$KF/diag.log" || fail 'the pre-existing diagnosis must start'
  k1_ready k1-diag k1-receipt k1-retry k1-slice
  printf '3\n' > "$KF/free"
  cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
[ "$1" != k1-retry ] || { echo 'error: unexpected fixture fault' >&2; exit 1; }
echo 'spawned'
SH
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  k1_pass 550
  controller_wait_action_receipt ctl-b-launch-k1-receipt || fail 'the success receipt must be ready'
  controller_wait_action_receipt ctl-b-launch-k1-retry || fail 'the failure receipt must be ready'
  controller_wait_action_receipt ctl-a-step || fail 'the step receipt must be ready'
  k1_pass_lock_holder
  printf '%s\n' $((K1_T0 + 570)) > "$H/state/.autolaunch.lock/at"
  : > "$KF/diag-go"
  controller_wait_action_receipt ctl-b-launch-k1-diag || fail 'the diagnosis receipt must be ready'
  k1_pass 605; k1_pass 715
  python3 - "$H/state/autolaunch-controller" <<'PYCASE' || fail 'all existing seat transitions must reconcile under the busy-pass journal guard'
import json,sys
from pathlib import Path
root=Path(sys.argv[1])
def row(key): return json.loads((root/(key+'.json')).read_text())
assert row('ctl-b-launch-k1-receipt')['phase']=='complete'
assert row('ctl-a-step')['phase']=='complete'
retry=row('ctl-b-launch-k1-retry'); assert retry['phase']=='queued' and retry['rung']==1,retry
diag=row('ctl-b-launch-k1-diag'); assert diag['phase']=='diagnose-queued' and diag['diag_rung']==4,diag
PYCASE
  assert_equals 1 "$(k1_units_max_count 600 k1-retry)" 'a promoted retry cannot dispatch while planning is busy'
  assert_equals 1 "$(k1_units_max_count 120)" 'a completed step cannot redispatch on a busy pass'
  assert_equals 1 "$(k1_units_max_count 900)" 'diagnosis completion cannot bypass fresh seat admission'
  k1_pass 880
  python3 - "$H/state/autolaunch-controller/ctl-b-launch-k1-diag.json" <<'PYCASE' || fail 'a busy pass must expire the diagnosis queue within 315 seconds'
import json,sys
from pathlib import Path
row=json.loads(Path(sys.argv[1]).read_text()); assert row['phase']=='exhausted',row
PYCASE
  assert_equals 1 "$(k1_count "$H/state/autolaunch-diag/ctl-b-launch-k1-diag-summary.md" 'diagnosis=skipped-capacity')" 'queue expiry records one skipped diagnosis without starting a new seat'
  kill "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null || true
  K1_HOLDER=
  rm -rf "$H/state/.autolaunch.lock"
  k1_pass 935
  assert_equals 2 "$(k1_units_max_count 120)" 'the next successful pass immediately resumes leased progression'
  k1_teardown
  pass 'busy passes reconcile success, step, retry and diagnosis receipts while gating new seats'
}

test_controller_lock_recovery_uses_actual_acquisition() {
  local mode
  for mode in error term kill; do
    k1_setup "recovery-$mode" mate
    k1_pass_lock_holder
    k1_pass 55; k1_pass 110; k1_pass 165
    assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'the persistent live holder must open one incident'
    kill "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null || true
    K1_HOLDER=
    rm -rf "$H/state/.autolaunch.lock"
    if [ "$mode" = error ]; then
      printf '#!/usr/bin/env bash\nexit 1\n' > "$KB/tasks-axi"
      chmod +x "$KB/tasks-axi"
      k1_pass 220
      rm "$KB/tasks-axi"
      assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-error)" 'the acquired pass must report its actual discovery failure'
    else
      k1_pass 220 "$mode"
      assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'recovery must preserve the interrupted-pass verdict'
    fi
    assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'the first acquired and released pass closes the incident despite its planning result'
    python3 - "$H/state/autolaunch-controller/pass.json" <<'PYCASE' || fail 'lock recovery must clear holder observations but preserve overrun'
import json,sys
from pathlib import Path
p=json.loads(Path(sys.argv[1]).read_text()); assert 'holder' not in p and p['overrun']==1,p
PYCASE
    k1_pass_lock_holder
    printf '%s\n' $((K1_T0 + 275)) > "$H/state/.autolaunch.lock/at"
    k1_pass 330; k1_pass 385; k1_pass 440
    assert_equals 2 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a later genuine holder opens one fresh generation'
    k1_teardown
  done
  pass 'actual lock acquisition closes incidents across planning error, TERM and KILL and permits recurrence'
}

controller_inventory_failure_pass() {
  local at=$1 rc=0
  printf '%s\n' $((K1_T0 + at)) > "$KF/clock"
  k1_tick
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-plan "$KB/scheduler" >> "$KF/pass.out" 2>&1 || rc=$?
  expect_code 1 "$rc" 'the unavailable discovery boundary must still report its failure'
  printf '%s\n' $((K1_T0 + at + 20)) > "$KF/clock"
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$KB/scheduler" "$rc" >> "$KF/pass.out" 2>&1 || fail 'effects must deliver existing ownership after a discovery failure'
}

controller_wait_action_receipt() {
  local token
  token=$(python3 - "$H/state/autolaunch-controller/$1.json" <<'PYCASE'
import json, sys
from pathlib import Path
print(json.loads(Path(sys.argv[1]).read_text())['attempt'])
PYCASE
  )
  k1_wait_file "$H/state/autolaunch-controller/$token.result"
}

test_controller_discovery_failures_reconcile_existing_actions() {
  local source agent start
  for source in preparation decisions; do
    k1_setup "failed-$source" mate
    k1_ready k1-due k1-late k1-retry k1-slice
    printf '3\n' > "$KF/free"
    printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
    printf 'hung-child-exits\n' > "$KF/spawn-mode"
    cp "$KB/spawn" "$KB/spawn-original"
    cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
if [ "$1" = k1-retry ]; then
  printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
  echo 'error: unexpected fixture fault' >&2
  exit 1
fi
exec "$KB/spawn-original" "$@"
SH
    cat > "$KB/scheduler" <<'SH'
#!/usr/bin/env bash
case "$(cat "$KF/inventory-failure"):$1" in
  preparation:--dry-run|decisions:--controller-decisions) echo 'inventory unavailable' >&2; exit 1 ;;
esac
exec bash "$ROOT/bin/fm-autolaunch.sh" "$@"
SH
    chmod +x "$KB/scheduler" "$KB/spawn"
    printf '%s\n' "$source" > "$KF/inventory-failure"
    k1_pass 0
    k1_wait_file "$KF/holder-k1-due.pid" || fail 'the timeout launch must start'
    k1_wait_file "$KF/holder-k1-late.pid" || fail 'the late launch must start'
    controller_wait_action_receipt ctl-b-launch-k1-retry || fail 'the failed retry source must publish its receipt'
    controller_wait_action_receipt ctl-a-step || fail 'the successful step must publish its receipt'
    controller_inventory_failure_pass 55
    controller_inventory_failure_pass 165
    python3 - "$H/state/autolaunch-controller" <<'PYCASE' || fail 'failed discovery must reconcile step receipts and promote due retries'
import json, sys
from pathlib import Path
root=Path(sys.argv[1])
step=json.loads((root/'ctl-a-step.json').read_text())
retry=json.loads((root/'ctl-b-launch-k1-retry.json').read_text())
assert step['phase']=='complete',step
assert retry['phase']=='queued' and retry['rung']==1,retry
PYCASE
    controller_inventory_failure_pass 660
    for task in k1-due k1-late; do
      assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'a discovery failure cannot suppress a due launch timeout handoff by 680 seconds'
      assert_equals 1 "$(k1_units_max_count 600 "$task")" 'timeout reconciliation cannot duplicate a launch'
    done
    assert_equals 0 "$(k1_units_max_count 900)" 'failed discovery cannot dispatch a fresh diagnosis'
    printf 'ctl-a-step\n' > "$KF/hang-match"
    k1_pass 715
    assert_equals 2 "$(k1_units_max_count 120)" 'the next successful pass recreates and dispatches the completed leased step immediately'
    controller_wait_action_receipt ctl-b-launch-k1-due || fail 'the first diagnosis must publish its receipt'
    controller_inventory_failure_pass 770
    python3 - "$H/state/autolaunch-controller/ctl-b-launch-k1-due.json" <<'PYCASE' || fail 'failed discovery must reconcile diagnosis completion'
import json, sys
from pathlib import Path
row=json.loads(Path(sys.argv[1]).read_text())
assert row['diag_rung']==4,row
PYCASE
    "$K1/agent/claude" 100000 </dev/null >/dev/null 2>&1 &
    agent=$!
    start=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$agent/stat")
    printf 'agent_root_pid=%s\nagent_root_start=%s\nboot_id=%s\n' "$agent" "$start" "$(cat /proc/sys/kernel/random/boot_id)" >> "$H/state/k1-late.meta"
    controller_inventory_failure_pass 825
    assert_equals 1 "$(k1_count "$LOG" k1-late 'resolved launched-late')" 'late agent identity closes existing ownership even when discovery fails'
    controller_inventory_failure_pass 990
    python3 - "$H/state/autolaunch-controller/ctl-a-step.json" <<'PYCASE' || fail 'failed discovery must reconcile a step timeout'
import json, sys
from pathlib import Path
row=json.loads(Path(sys.argv[1]).read_text())
assert row['phase']=='retry-wait',row
PYCASE
    assert_equals 1 "$(k1_count "$LOG" ctl-a-step failed:timeout)" 'the expired step is one ordinary failed attempt'
    k1_teardown
  done
  pass 'preparation and decision failures preserve timeout, receipt, retry, diagnosis and late-start reconciliation'
}

test_controller_vanished_holders_never_accumulate() {
  local at holder
  k1_setup vanished-holders mate
  k1_pass_lock_holder
  holder=$K1_HOLDER
  for at in 0 55; do
    printf '%s\n' $((K1_T0 + at)) > "$KF/clock"
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
      python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$AL" 73 || fail 'a live observation must finish'
  done
  kill "$holder"; wait "$holder" 2>/dev/null || true
  K1_HOLDER=
  rm -rf "$H/state/.autolaunch.lock"
  for at in 110 165 220; do
    printf '%s\n' $((K1_T0 + at)) > "$KF/clock"
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
      python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$AL" 73 || fail 'a vanished observation must finish'
  done
  mkdir "$H/state/.autolaunch.lock"
  printf '999999999\n' > "$H/state/.autolaunch.lock/pid"
  for at in 275 330 385; do
    printf '%s\n' $((K1_T0 + at)) > "$KF/clock"
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
      python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$AL" 73 || fail 'a stale identity must finish'
  done
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'missing and stale identities spanning sixty seconds never become persistent live holders'
  python3 - "$H/state/autolaunch-controller/pass.json" <<'PYCASE' || fail 'vanished observations must clear prior holder state'
import json, sys
from pathlib import Path
assert 'holder' not in json.loads(Path(sys.argv[1]).read_text())
PYCASE
  rm -rf "$H/state/.autolaunch.lock"
  k1_pass_lock_holder
  printf '%s\n' $((K1_T0 + 440)) > "$H/state/.autolaunch.lock/at"
  for at in 440 495 550; do
    printf '%s\n' $((K1_T0 + at)) > "$KF/clock"
    FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
      python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$AL" 73 || fail 'a persistent live identity must finish'
  done
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a new real persistent holder still receives one bounded handoff'
  k1_alive "$K1_HOLDER" || fail 'the persistent live holder must not be killed'
  k1_teardown
  pass 'vanished holder observations are discarded while genuine persistent holders still escalate'
}

test_controller_interrupted_launch_rechecks_preparation() {
  k1_setup interrupted-preparation mate
  k1_ready k1-prepared
  cp "$KB/timeout" "$KB/timeout-original"
  cat > "$KB/timeout" <<'SH'
#!/usr/bin/env bash
"$KB/timeout-original" "$@" || exit $?
case "$*" in *--controller-plan*) exit 124 ;; esac
SH
  cp "$KB/timeout" "$KB/gnutimeout"
  k1_pass 0
  assert_absent "$KF/spawn.log" 'interrupted planning leaves the launch pending'
  rm "$H/data/k1-prepared/prep.md"
  cp "$KB/timeout-original" "$KB/timeout"
  cp "$KB/timeout-original" "$KB/gnutimeout"
  k1_pass 55; k1_pass 110
  assert_absent "$KF/spawn.log" 'withdrawn preparation prevents a saved queued launch'
  prep k1-prepared proj
  k1_pass 165; k1_pass 220
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-prepared)" 'restored preparation admits one launch without replaying a deferred receipt'
  k1_teardown
  pass 'interrupted queued launches require current preparation before spawning'
}

test_controller_saved_action_refreshes_launch_argv() {
  local token
  k1_setup saved-current-argv mate
  k1_ready k1-argv
  printf 'base_branch=before\n' >> "$H/data/k1-argv/autolaunch-prep"
  controller_save_pending_launch
  k1_pass 0
  token=$(cat "$KF/pending-action")
  prep k1-argv proj base_branch=after
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" || fail 'the current prepared action must execute'
  assert_contains "$(cat "$KF/spawn.log")" '--base-branch after' 'saved actions select current preparation arguments'
  assert_not_contains "$(cat "$KF/spawn.log")" '--base-branch before' 'saved command arguments cannot survive a preparation change'
  python3 - "$H/state/autolaunch-controller/$token" <<'PYCASE' || fail 'the actual attempt must record the refreshed argv'
import json
from pathlib import Path
import sys
argv = json.loads(Path(sys.argv[1]).read_text())['argv']
assert argv[argv.index('--base-branch') + 1] == 'after', argv
PYCASE
  k1_teardown
  pass 'pending saved actions execute and record freshly selected launch argv'
}

test_controller_saved_action_refuses_withdrawn_preparation() {
  local token rc=0
  k1_setup saved-preparation-refused mate
  k1_ready k1-pending
  controller_save_pending_launch
  k1_pass 0
  token=$(cat "$KF/pending-action")
  rm "$H/data/k1-pending/prep.md"
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" "$token" || rc=$?
  expect_code 75 "$rc" 'withdrawn preparation defers an already-dispatched saved action'
  assert_absent "$KF/spawn.log" 'an admitted old action cannot bypass a later preparation refusal'
  k1_slot_locks_free || fail 'a preparation deferral must release its action slot'
  k1_teardown
  pass 'saved actions defer safely when current preparation is refused'
}

test_controller_retry_rechecks_preparation_and_argv() {
  k1_setup retry-preparation mate
  k1_ready k1-retry-prep
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  k1_pass 0; k1_pass 55
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-retry-prep)" 'the initial admitted attempt reaches the spawn boundary'
  rm "$H/data/k1-retry-prep/prep.md"
  k1_pass 165; k1_pass 220
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-retry-prep)" 'promoting a retry never bypasses withdrawn preparation'
  assert_absent "$KF/diag.log" 'preparation waits do not advance the failure ladder'
  prep k1-retry-prep proj base_branch=fresh
  printf 'ok\n' > "$KF/spawn-mode"
  k1_pass 275; k1_pass 330
  assert_equals 2 "$(k1_count "$KF/spawn.log" k1-retry-prep)" 'a cleared preparation wait permits one retry'
  assert_contains "$(tail -1 "$KF/spawn.log")" '--base-branch fresh' 'retry dispatch uses the current selected argv'
  k1_teardown
  pass 'promoted retries recheck admission and refresh their launch arguments'
}

test_controller_busy_delivery_defers_and_recovers() {
  local verb record rc mode
  for verb in ring retry; do
    k1_setup "busy-$verb" mate
    printf 'window=sess:fm-k1-busy\nkind=ship\nharness=grok\nbackend=tmux\n' > "$H/state/k1-busy.meta"
    mode=
    [ "$verb" != retry ] || mode=fire-and-forget
    record=$( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$H/state" k1-busy 'continue work' "$mode" )
    if [ "$verb" = retry ]; then
      ( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_mark_retry "$H/state" k1-busy "$record" ) || fail 'the retry fixture must retain a delivery token'
    fi
    cat > "$KB/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'fm-k1-busy\n' ;;
  capture-pane) cat "$KF/capture" ;;
  display-message)
    case "$*" in
      *pane_current_command*) sed -n 's/^harness=//p' "$FM_HOME/state/k1-busy.meta" ;;
      *cursor_y*) printf '1\n' ;;
      *pane_tty*) printf '\n' ;;
      *) printf 'fakepane\n' ;;
    esac ;;
  send-keys)
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) shift; printf 'literal:%s\n' "$*" >> "$KF/send.log"; exit 0 ;; *) break ;; esac
    done
    printf 'key:%s\n' "$*" >> "$KF/send.log" ;;
esac
SH
    chmod +x "$KB/tmux"
    printf 'BUSYTOKEN active\n╭────╮\n│    │\n╰────╯\n' > "$KF/capture"
    rc=0
    FM_BUSY_REGEX=BUSYTOKEN PATH="$KB:$PATH" bash "$AL" --controller-ring k1-busy "$record" "$verb" >/dev/null 2>&1 || rc=$?
    expect_code 75 "$rc" 'a busy non-queue task defers either delivery verb'
    assert_absent "$KF/send.log" 'a busy Grok task receives neither typing nor Enter'
    assert_absent "$H/state/k1-busy.inbox/.ring-state" 'busy deferral does not advance the ring ladder'
    [ "$verb" != retry ] || assert_present "$H/state/k1-busy.inbox/.retry-ring" 'busy deferral preserves its retry token'
    printf '╭────╮\n│    │\n╰────╯\n' > "$KF/capture"
    FM_BUSY_REGEX=BUSYTOKEN PATH="$KB:$PATH" bash "$AL" --controller-ring k1-busy "$record" "$verb" >/dev/null 2>&1 || true
    assert_contains "$(cat "$KF/send.log")" 'Firstmate instruction waiting' 'idle recovery types the owed doorbell'
    assert_contains "$(cat "$KF/send.log")" 'key:Enter' 'idle recovery submits the owed doorbell'
    if [ "$verb" = retry ]; then
      assert_absent "$H/state/k1-busy.inbox/.retry-ring" 'an attempted idle retry spends its token'
    else
      assert_present "$H/state/k1-busy.inbox/.ring-state" 'an attempted idle ring advances its ladder'
    fi
    printf 'window=sess:fm-k1-busy\nkind=ship\nharness=claude\nbackend=tmux\n' > "$H/state/k1-busy.meta"
    if [ "$verb" = retry ]; then
      ( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_mark_retry "$H/state" k1-busy "$record" ) || fail 'the queued retry fixture must be owed'
    fi
    "$ROOT/bin/fm-busy-event.sh" arm "$H/state" k1-busy --state busy --source claude-hook --event user-prompt-submit >/dev/null || fail 'the queued-submit task must be semantically busy'
    : > "$KF/send.log"
    FM_BUSY_REGEX=BUSYTOKEN PATH="$KB:$PATH" bash "$AL" --controller-ring k1-busy "$record" "$verb" >/dev/null 2>&1 || true
    assert_contains "$(cat "$KF/send.log")" 'Firstmate instruction waiting' 'queue-capable busy tasks retain allowed submission'
    assert_contains "$(cat "$KF/send.log")" 'key:Enter' 'queue-capable busy tasks receive Enter'
    k1_teardown
  done
  pass 'ordinary and retry delivery defer busy non-queue tasks and preserve idle and queued submission'
}

test_controller_deferred_attempt_has_fresh_receipts() {
  k1_setup deferred-generation mate
  k1_ready k1-deferred
  printf 'hung\n' > "$KF/spawn-mode"
  cp "$KB/spawn" "$KB/spawn-original"
  cat > "$KB/spawn" <<'STUB'
#!/usr/bin/env bash
if [ ! -e "$KF/deferred-once" ]; then
  : > "$KF/deferred-once"
  printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
  echo 'deferred: capacity condition'; exit 75
fi
exec "$KB/spawn-original" "$@"
STUB
  k1_pass 0; k1_pass 55; k1_pass 110
  assert_equals 2 "$(k1_units_max_count 600 k1-deferred)" 'a stale deferred receipt never authorizes a third launch over a live second attempt'
  k1_passes 165 880
  assert_equals 2 "$(k1_units_max_count 600 k1-deferred)" 'a deferred then timed-out launch is never duplicated'
  assert_equals 1 "$(k1_owned k1-deferred | grep -c .)" 'the fresh hung attempt reaches its timeout responder'
  k1_teardown
  pass 'deferred redispatch uses fresh attempt receipts and still times out once'
}

test_controller_equal_decision_keys_remain_task_scoped() {
  local task
  k1_setup task-key-scope mate
  for task in k1-equal-a k1-equal-b; do
    printf 'kind=ship\nharness=claude\nbackend=tmux\n' > "$H/state/$task.meta"
    printf 'needs-decision [key=api-shape] [at=%s]: choose a technical retry interval\n' "$K1_T0" > "$H/state/$task.status"
  done
  k1_pass 220
  for task in k1-equal-a k1-equal-b; do
    assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'each task owns its aged decision even when another task uses the same key'
  done
  for task in k1-equal-a k1-equal-b; do
    printf 'resolved [key=api-shape] [at=%s]: answered\n' $((K1_T0 + 275)) >> "$H/state/$task.status"
  done
  printf 'needs-decision [key=api-shape] [at=%s]: choose a technical retry interval\n' $((K1_T0 + 280)) >> "$H/state/k1-equal-a.status"
  k1_pass 500
  for task in k1-equal-a k1-equal-b; do
    assert_equals 1 "$(k1_count "$H/state/$task.status" resolved ctl-c-ask-)" 'answering a source decision closes only its controller notice'
  done
  printf 'needs-decision [key=api-shape] [at=%s]: choose a technical retry interval\n' $((K1_T0 + 550)) >> "$H/state/k1-equal-b.status"
  k1_pass 770
  assert_equals 2 "$(k1_owned k1-equal-a | grep -c .)" 'reopening the source decision receives a new notice generation'
  assert_equals 2 "$(k1_owned k1-equal-b | grep -c .)" 'an answered sibling task can reopen independently'
  assert_absent "$KF/diag.log" 'known unanswered decisions never launch diagnosis'
  k1_teardown
  pass 'equal decision keys on different tasks each receive their own handoff'
}

test_controller_lock_incident_reopens_after_recovery() {
  k1_setup lock-recurrence mate
  k1_pass_lock_holder
  k1_pass 55; k1_pass 110; k1_pass 165
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'first persistent holder has one incident'
  kill -KILL "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null; K1_HOLDER=
  k1_pass 220
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'recovery closes the first incident'
  k1_pass_lock_holder
  printf '%s\n' $((K1_T0 + 220)) > "$H/state/.autolaunch.lock/at"
  k1_pass 275; k1_pass 330; k1_pass 385
  assert_equals 2 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a new persistent holder opens a fresh delivery generation'
  k1_pass 440
  assert_equals 2 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a second incident is still delivered only once'
  k1_teardown
  pass 'a recovered pass-lock incident can recur with one fresh handoff'
}

test_controller_diagnosis_charge_survives_dispatch_crash() {
  local t
  k1_setup diagnosis-budget-crash mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  k1_ready k1-budget
  cp "$KB/systemd-run" "$KB/systemd-run-original"
  cat > "$KB/systemd-run" <<'STUB'
#!/usr/bin/env bash
"$KB/systemd-run-original" "$@" || exit $?
case "$*" in
  *RuntimeMaxSec=900*)
    if [ ! -e "$KF/diagnosis-dispatch-crash" ]; then
      : > "$KF/diagnosis-dispatch-crash"
      kill -KILL "$PPID"
    fi
    ;;
esac
STUB
  for t in 0 55 110 165 220 275 330 385 440 495 550; do
    k1_pass "$t"
    [ ! -e "$KF/diagnosis-dispatch-crash" ] || break
  done
  assert_present "$KF/diagnosis-dispatch-crash" 'the fixture actually crashes immediately after diagnosis service dispatch'
  assert_equals 1 "$(k1_units_max_count 900 k1-budget)" 'exactly one diagnosis reached service dispatch at the crash'
  python3 - "$H/state/autolaunch-controller/diagnosis-history.json" <<'PY' || fail 'a dispatched diagnosis lost its hourly-cap charge across the crash'
import json
from pathlib import Path
import sys
p = Path(sys.argv[1])
charges = json.loads(p.read_text()) if p.exists() else []
assert len(charges) == 1, f'one dispatched diagnosis must retain one durable hourly charge after crash; got {charges}'
PY
  k1_teardown
  pass 'diagnosis dispatch reserves its hourly charge durably before service creation'
}

test_controller_quota_refusal_is_a_wait() {
  k1_setup quota-wait mate
  k1_ready k1-quota
  printf 'quota\n' > "$KF/spawn-mode"
  cat > "$KB/spawn" <<'STUB'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
if [ "$(cat "$KF/spawn-mode")" = quota ]; then
  echo 'error: fm-spawn refuses explicit harness codex: provider runway exhausted_now' >&2
  exit 1
fi
echo "spawned $1"
STUB
  k1_passes 0 550
  assert_equals 0 "$(k1_owned k1-quota | grep -c .)" 'a typed quota wait never enters the failure ladder'
  assert_absent "$KF/diag.log" 'quota waits never spend diagnosis calls'
  printf 'ok\n' > "$KF/spawn-mode"
  k1_pass 605; k1_pass 660
  [ -n "$(k1_lines "$LOG" k1-quota launched)" ] || fail 'clearing the quota condition resumes the waiting launch'
  k1_teardown
  pass 'typed quota refusal waits without escalation and resumes after admission clears'
}

test_controller_decision_pair_is_injective() {
  local task key
  k1_setup decision-pair-injective mate
  for task in build-api build; do
    case "$task" in build-api) key=shape ;; *) key=api-shape ;; esac
    printf 'kind=ship\nharness=claude\nbackend=tmux\n' > "$H/state/$task.meta"
    printf 'needs-decision [key=%s] [at=%s]: choose a technical retry interval\n' "$key" "$K1_T0" > "$H/state/$task.status"
  done
  k1_pass 220
  for task in build-api build; do
    assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'the exact build-api/shape and build/api-shape pair each receives one responder handoff'
  done
  assert_present "$H/state/autolaunch-controller/ctl-c-ask-9.build-api-shape.json" 'decision identity preserves task length and original key'
  assert_present "$H/state/autolaunch-controller/ctl-c-ask-5.build-api-shape.json" 'the colliding textual pair has a different persisted identity'
  k1_pass 275
  for task in build-api build; do
    assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'a distinct structured pair still deduplicates its own handoff'
  done
  k1_teardown
  pass 'decision identity is injective for the exact separator-collision pair'
}

test_controller_inbox_pair_preserves_task_and_message() {
  k1_setup inbox-pair-identity mate
  k1_inbox_due build-api
  k1_inbox_due build
  k1_pass 0
  python3 - "$H/state/autolaunch-controller" <<'PYCASE' || fail 'inbox obligations must use the shared reversible task/message identity'
import json
from pathlib import Path
import sys
rows = [json.loads(p.read_text()) for p in Path(sys.argv[1]).glob('ctl-*.json')]
rows = [r for r in rows if r['kind'] == 'ring']
assert len(rows) == 2, rows
pairs = set()
for row in rows:
    encoded = row['key'].removeprefix('ctl-c-ring-')
    size, rest = encoded.split('.', 1)
    assert size.isdigit(), f'inbox task/key pair has no length prefix: {row["key"]}'
    n = int(size)
    task, sep, key = rest[:n], rest[n:n+1], rest[n+1:]
    assert sep == '-' and task == row['task'], row
    assert key == Path(row['argv'][-2]).name, row
    pairs.add((task, key))
assert {t for t, _ in pairs} == {'build-api', 'build'}
PYCASE
  assert_equals 1 "$(k1_units_max_count 60 ctl-c-ring- 9.build-api-)" 'first inbox has one action unit'
  assert_equals 2 "$(k1_units_max_count 60 ctl-c-ring-)" 'each task/message obligation starts independently'
  k1_teardown
  pass 'inbox task/message identities are reversible and use the shared pair encoding'
}

test_controller_ring_recurrence_preserves_spaced_paths() {
  local rec row attempt
  k1_setup 'ring recurrence' mate
  k1_inbox_due k1-ring
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/systemd-run.log"
python3 - "$FM_HOME/state/autolaunch-controller/${!#}.result" <<'PYCASE'
from pathlib import Path
import sys
Path(sys.argv[1]).write_text('{"rc": 0}')
PYCASE
SH
  k1_pass 0
  row=$(printf '%s\n' "$H"/state/autolaunch-controller/ctl-c-ring-*.json)
  rec=$(printf '%s\n' "$H"/state/k1-ring.inbox/*.msg)
  python3 - "$row" "$rec" <<'PYCASE' || fail 'a ring must retain the complete spaced record path'
import json
from pathlib import Path
import sys
row = json.loads(Path(sys.argv[1]).read_text())
assert row['argv'][-2:] == [sys.argv[2], 'ring'], row
PYCASE
  k1_pass 55 kill
  assert_equals 2 "$(k1_units_max_count 60)" 'a cut planning pass reconciles the first receipt and starts the next due ring'
  attempt=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempt"])' "$row")
  rm "$H/state/autolaunch-controller/$attempt.result"
  k1_pass 80 kill
  assert_equals 2 "$(k1_units_max_count 60)" 'a running ring suppresses overlapping attempts'
  printf '{"rc":0}\n' > "$H/state/autolaunch-controller/$attempt.result"
  k1_pass 110 kill
  assert_equals 3 "$(k1_units_max_count 60)" 'each later due ring has independent attempt receipts'
  k1_teardown
  pass 'successful rings recur during cut passes and preserve paths with spaces'
}

test_controller_partial_plan_ownership_is_late() {
  local row
  k1_setup partial-plan mate
  printf 'needs-decision [key=retry] [at=%s]: choose retry interval\n' "$K1_T0" > "$H/state/k1-partial.status"
  cp "$KB/timeout" "$KB/timeout-original"
  cat > "$KB/timeout" <<'SH'
#!/usr/bin/env bash
"$KB/timeout-original" "$@" || exit $?
case "$*" in *--controller-plan*) exit 124 ;; esac
SH
  cp "$KB/timeout" "$KB/gnutimeout"
  k1_pass 220
  assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'planning is interrupted after recording ownership'
  assert_equals 1 "$(k1_count "$H/state/k1-partial.status" blocked overrun=1)" 'pending ownership is delivered with the interrupted-pass verdict'
  row=$(printf '%s\n' "$H"/state/autolaunch-controller/ctl-c-ask-*.json)
  python3 - "$row" <<'PYCASE' || fail 'the durable ownership and evidence must record the interrupted pass'
import json
from pathlib import Path
import sys
row = json.loads(Path(sys.argv[1]).read_text())
assert row['overrun'] == 1, row
assert Path(row['evidence']).read_text().splitlines()[-1].endswith('overrun=1'), row
PYCASE
  cp "$KB/timeout-original" "$KB/timeout"
  cp "$KB/timeout-original" "$KB/gnutimeout"
  k1_pass 275
  assert_equals 1 "$(k1_owned k1-partial | grep -c .)" 'the following successful pass does not repeat ownership'
  assert_absent "$KF/diag.log" 'known unanswered decisions require no diagnosis'
  k1_teardown
  pass 'a partially recorded interrupted pass publishes one late handoff'
}

test_controller_status_timeouts_preserve_progress() {
  local row
  k1_setup status-timeouts mate
  printf 'needs-decision [key=retry] [at=%s]: choose retry interval\n' "$K1_T0" > "$H/state/k1-status.status"
  k1_inbox_due k1-other
  : > "$H/config/fleet-ledger"
  mkdir "$H/state/.fleet-ledger.lock"
  printf '%s\n' "$$" > "$H/state/.fleet-ledger.lock/pid"
  k1_pass 220
  assert_equals 0 "$(tail -1 "$KF/pass-rc.log" | cut -f2)" 'uncertain status delivery does not abort effects'
  assert_equals 1 "$(k1_units_max_count 60 k1-other)" 'an unrelated ring still starts after a status timeout'
  row=$(printf '%s\n' "$H"/state/autolaunch-controller/ctl-c-ask-*.json)
  python3 - "$row" <<'PYCASE' || fail 'optional ledger contention must not retain an accepted opener as pending'
import json
from pathlib import Path
import sys
assert json.loads(Path(sys.argv[1]).read_text())['handoff']['receipt']
PYCASE
  k1_pass 275
  assert_equals 1 "$(k1_owned k1-status | grep -c .)" 'an appended opener is reconciled without another append'
  printf 'resolved [key=retry] [at=%s]: answered\n' $((K1_T0 + 300)) >> "$H/state/k1-status.status"
  k1_pass 330
  assert_equals 0 "$(tail -1 "$KF/pass-rc.log" | cut -f2)" 'uncertain status closure does not abort effects'
  rm "$H/config/fleet-ledger"
  k1_pass 385
  assert_equals 1 "$(k1_count "$H/state/k1-status.status" resolved ctl-c-ask-)" 'the uncertain closer is reconciled without another append'
  python3 - "$row" <<'PYCASE' || fail 'an already appended closure must converge on the following pass'
import json
from pathlib import Path
import sys
assert json.loads(Path(sys.argv[1]).read_text())['closed']
PYCASE
  k1_teardown
  pass 'status opener and closer timeouts preserve receipts and unrelated progress'
}

test_controller_main_close_timeout_preserves_progress() {
  k1_setup main-close-timeout main
  k1_pass_lock_holder
  k1_pass 55; k1_pass 110; k1_pass 165
  assert_equals 1 "$(grep -c . "$KF/accepted")" 'the initial MAIN incident is accepted'
  kill -KILL "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null; K1_HOLDER=
  k1_inbox_due k1-other
  printf 'hang\nok\n' > "$KF/send-mode"
  k1_pass 220
  assert_equals 0 "$(tail -1 "$KF/pass-rc.log" | cut -f2)" 'uncertain MAIN closure does not abort effects'
  assert_equals 1 "$(k1_units_max_count 60 k1-other)" 'an unrelated ring still starts after a MAIN closure timeout'
  k1_pass 275
  assert_equals 2 "$(grep -c . "$KF/accepted")" 'exactly one opener and one closure are accepted'
  assert_equals 1 "$(tail -2 "$KF/send.log" | cut -f3 | sort -u | grep -c .)" 'closure retries retain their request identity'
  k1_teardown
  pass 'MAIN closure timeout retains its request identity and unrelated progress'
}

test_controller_retry_spends_once_after_decision() {
  local retry_record row attempt rc=0
  k1_setup retry-once mate
  : > "$H/config/wait-no-turns"
  retry_record=$( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$H/state" k1-retry 'one retry' fire-and-forget )
  ( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_mark_retry "$H/state" k1-retry "$retry_record" ) || fail 'retry fixture must publish its mark'
  fm_touch_epoch 100 "$H/state/k1-retry.inbox/.retry-ring"
  printf 'needs-decision [key=answer] [at=%s]: choose interval\n' "$K1_T0" > "$H/state/k1-retry.status"
  k1_pass 0
  assert_equals 0 "$(k1_units_max_count 60)" 'an open decision defers the fire-and-forget retry'
  PATH="$KB:$PATH" bash "$AL" --controller-ring k1-retry "$retry_record" retry >/dev/null 2>&1 || rc=$?
  expect_code 75 "$rc" 'dispatch rechecks a decision opened after discovery'
  assert_present "$H/state/k1-retry.inbox/.retry-ring" 'deferred retry retains its mark'
  printf 'resolved [key=answer] [at=%s]: answered\n' $((K1_T0 + 55)) >> "$H/state/k1-retry.status"
  k1_pass 55
  row=$(printf '%s\n' "$H"/state/autolaunch-controller/ctl-c-ring-*.json)
  attempt=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["attempt"])' "$row")
  k1_wait_file "$H/state/autolaunch-controller/$attempt.result" || fail 'retry must publish its result receipt'
  k1_pass 110
  assert_equals 1 "$(k1_units_max_count 60)" 'the retry is attempted once even when its endpoint is absent'
  assert_absent "$H/state/k1-retry.inbox/.retry-ring" 'the retry mark is spent whatever the doorbell result'
  assert_absent "$H/state/k1-retry.inbox/.ring-state" 'a fire-and-forget retry never enters the ordinary ladder'
  k1_teardown
  pass 'retry defers for a decision and spends its one mark after the attempt'
}

test_controller_prepared_argv_preserves_unicode() {
  k1_setup 'argv-é' mate
  k1_ready k1-unicode
  cat > "$KB/spawn-é" <<'SH'
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
Path(os.environ['KF'], 'spawn-argv.json').write_text(json.dumps(sys.argv))
SH
  chmod +x "$KB/spawn-é"
  export FM_AUTOLAUNCH_SPAWN_BIN="$KB/spawn-é"
  k1_pass 0
  k1_wait_file "$KF/spawn-argv.json" || fail 'a prepared Unicode executable must run'
  python3 - "$KF/spawn-argv.json" "$KB/spawn-é" "$H/projects/proj" <<'PYCASE' || fail 'prepared argv must retain Unicode and spaces byte for byte'
import json
from pathlib import Path
import sys
argv = json.loads(Path(sys.argv[1]).read_text())
assert argv[0] == sys.argv[2], argv
assert argv[2] == sys.argv[3], argv
assert argv[1] == 'k1-unicode', argv
PYCASE
  k1_teardown
  pass 'structured preparation executes Unicode paths with their exact argv'
}

test_controller_backend_context_reaches_units() {
  k1_setup unit-context mate
  mkdir -p "$H/state/autolaunch-controller"
  python3 - "$H/state/autolaunch-controller/ctl-b-context.json" <<'PYCASE'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps(dict(key='ctl-b-context', task='k1-context', kind='launch',
    argv=['bash', '-c', 'exit 0'], phase='queued', rung=0, opened=1800000000, overrun=0, generation=1)))
PYCASE
  cp "$KB/systemd-run" "$KB/systemd-run-original"
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
python3 - "$KF/unit-context.json" "$@" <<'PYCASE'
import json
from pathlib import Path
import sys
fields = dict(a[len('--setenv='):].split('=', 1) for a in sys.argv[2:] if a.startswith('--setenv='))
Path(sys.argv[1]).write_text(json.dumps(fields))
PYCASE
exec "$KB/systemd-run-original" "$@"
SH
  FM_TEST_SEAM=0 FM_ZELLIJ_SESSION=crew HERDR_SESSION=crew HERDR_SOCKET_PATH="$K1/herdr.sock" \
    FM_TERN_SESSION=crew FM_HC_SOCKET="$K1/hc.sock" CMUX_SOCKET_PASSWORD=secret \
    PATH="$KB:$PATH" python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-effects "$AL" 0 \
    || fail 'production unit dispatch must retain its routing context'
  python3 - "$KF/unit-context.json" "$K1" <<'PYCASE' || fail 'the production service envelope must preserve non-secret routing selectors'
import json
from pathlib import Path
import sys
fields = json.loads(Path(sys.argv[1]).read_text())
root = sys.argv[2]
for key, value in dict(FM_ZELLIJ_SESSION='crew', HERDR_SESSION='crew', HERDR_SOCKET_PATH=root+'/herdr.sock',
                      TMUX_TMPDIR=root+'/tmux', FM_TERN_SESSION='crew', FM_HC_SOCKET=root+'/hc.sock').items():
    assert fields.get(key) == value, (key, fields)
assert 'CMUX_SOCKET_PASSWORD' not in fields, fields
PYCASE
  k1_teardown
  pass 'production unit envelopes preserve backend routing without forwarding secrets'
}

test_controller_technical_notes_are_not_reserved() {
  local task
  k1_setup technical-prose mate
  for task in k1-login k1-destructor; do
    printf 'needs-decision [key=retry-policy] [at=%s]: Choose login retry backoff and destructor ordering\n' "$K1_T0" > "$H/state/$task.status"
  done
  printf 'needs-decision [key=pending-reply-reserved] [at=%s]: choose interval\n' "$K1_T0" > "$H/state/k1-reserved.status"
  k1_pass 220
  for task in k1-login k1-destructor; do
    assert_equals 1 "$(k1_owned "$task" | grep -c .)" 'technical prose never removes a key from the bounded handoff route'
  done
  assert_equals 0 "$(k1_owned k1-reserved | grep -c .)" 'the shared reserved namespace remains excluded'
  k1_teardown
  pass 'technical notes use shared key classification rather than prose guessing'
}

test_controller_late_launch_keeps_diagnosis_occupied() {
  local action_pid child_pid
  k1_setup diagnosis-late-close mate
  python3 - "$K1/agent/claude" "$H/state/k1-late.meta" <<'PYCASE' || fail 'late agent fixture must publish its recorded identity'
from pathlib import Path
import subprocess
import sys
proc = subprocess.Popen([sys.argv[1], '100000'], stdin=subprocess.DEVNULL,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
start = Path(f'/proc/{proc.pid}/stat').read_text().rsplit(') ', 1)[1].split()[19]
boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
Path(sys.argv[2]).write_text(f'agent_root_pid={proc.pid}\nagent_root_start={start}\nboot_id={boot}\n')
PYCASE
  mkdir -p "$H/state/autolaunch-controller" "$H/state/autolaunch-diag"
  python3 - "$H" "$K1_T0" <<'PYCASE'
import json
from pathlib import Path
import sys
home, now = Path(sys.argv[1]), int(sys.argv[2])
root = home/'state/autolaunch-controller'
evidence = home/'state/autolaunch-diag/evidence.md'
evidence.write_text('diagnosis occupancy fixture')
for task, phase in [('k1-late', 'diagnosing'), ('k1-next', 'diagnose-queued')]:
    key = 'ctl-b-launch-'+task
    row = dict(key=key, task=task, kind='launch', phase=phase, rung=0, diag_rung=3,
               opened=now, queued_at=now, generation=1, overrun=0, evidence=str(evidence),
               handoff=dict(payload=key+' owned', request='a'*32, receipt=True), argv=[])
    if phase == 'diagnosing':
        row['attempt'] = 'held-diagnosis'
    (root/(key+'.json')).write_text(json.dumps(row))
(root/'held-diagnosis').write_text(json.dumps(dict(key='ctl-b-launch-k1-late', kind='diagnosis',
    argv=['bash', '-c', 'echo $$ > "$KF/diagnosis-child.pid"; exec "$REAL_SLEEP" 100000'], deadline=now+900)))
PYCASE
  PATH="$KB:$PATH" python3 "$ROOT/bin/fm-autolaunch-steps.py" controller-action "$AL" held-diagnosis >/dev/null 2>&1 &
  k1_wait_file "$H/state/autolaunch-controller/held-diagnosis.identity" || fail 'diagnosis fixture must publish its identity'
  action_pid=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["pid"])' "$H/state/autolaunch-controller/held-diagnosis.identity")
  k1_wait_file "$KF/diagnosis-child.pid" || fail 'diagnosis fixture must occupy its real action slot'
  child_pid=$(cat "$KF/diagnosis-child.pid")
  k1_pass 0; k1_pass 55
  assert_equals 1 "$(k1_count "$H/state/k1-late.status" resolved launched-late)" 'the late launch closes its handoff'
  assert_equals 0 "$(k1_units_max_count 900)" 'a closed handoff retains the live diagnosis seat'
  kill "$child_pid"; wait "$action_pid" 2>/dev/null || true
  k1_pass 110
  assert_equals 1 "$(k1_units_max_count 900)" 'another diagnosis starts only after the first action terminates'
  k1_teardown
  pass 'late launch closure retains diagnosis occupancy until its action finishes'
}

test_controller_remote_inbox_uses_existing_due_owner() {
  local i=0
  k1_setup remote-deadline mate
  k1_pass 0
  assert_equals 0 "$(k1_units_max_count 300)" 'a home without a remote obligation creates no remote action'
  printf 'kind=secondmate\nremote_host=fixture.invalid\n' > "$H/state/k1-remote.meta"
  k1_pass 55
  assert_equals 1 "$(k1_units_max_count 300)" 'an owed remote inbox pass gets its existing 300-second deadline'
  while [ ! -e "$H/state/.remote-inbox-tick" ] && [ "$i" -lt 50 ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
  assert_present "$H/state/.remote-inbox-tick" 'the remote unit runs the existing inbox tick owner'
  k1_pass 110
  assert_equals 1 "$(k1_units_max_count 300)" 'the existing remote grace suppresses an unnecessary action'
  rm "$H/state/.remote-inbox-tick"
  k1_pass 165
  assert_equals 2 "$(k1_units_max_count 300)" 'a newly owed remote tick recurs after normal unowned completion'
  k1_teardown
  pass 'remote inbox units exist only for an owed remote tick and reuse its owner'
}

test_controller_step_deadline_qualifies_pass_lock() {
  local started holder
  k1_setup bounded-step-lock mate
  k1_ready k1-slice
  printf '0\n' > "$KF/free"
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  printf 'mode=no-mistakes\n' > "$H/state/k1-slice.meta"
  cat > "$KB/step-nm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' ready > "$KF/step-reading"
exec "$REAL_SLEEP" 100000
SH
  chmod +x "$KB/step-nm"
  export FM_AUTOLAUNCH_STEPS_NM_BIN="$KB/step-nm"
  k1_pass 0
  k1_wait_file "$KF/step-reading" || fail 'the bounded step must reach its real primary-lock hold'
  started=$(k1_units_max_start 1 120)
  holder=$(cat "$H/state/.autolaunch.lock/pid")
  k1_pass $((started - K1_T0 + 1))
  k1_pass $((started - K1_T0 + 31))
  k1_pass $((started - K1_T0 + 61))
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'events at bounded step ages 1, 31 and 61 seconds are a normal hold'
  k1_alive "$holder" || fail 'a normal step lock holder must remain alive'
  k1_pass $((started - K1_T0 + 125))
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a step holder beyond its deadline still reaches its responder by 165 seconds'
  k1_alive "$holder" || fail 'deadline escalation may not steal or kill the lock holder'
  python3 - "$H/state/autolaunch-controller/ctl-a-step.json" <<'PYCASE' || fail 'a busy pass must reconcile the expired step action'
import json,sys
from pathlib import Path
row=json.loads(Path(sys.argv[1]).read_text()); assert row['phase']=='retry-wait',row
PYCASE
  unset FM_AUTOLAUNCH_STEPS_NM_BIN
  k1_teardown
  pass 'bounded step holds stay normal and expired holders still escalate'
}

test_controller_ledger_contention_preserves_ten_key_deadlines() {
  local n
  k1_setup ledger-ten mate
  export REAL_DATE
  REAL_DATE=$(command -v date)
  cat > "$KB/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then
  python3 - "$KF" <<'PYCASE'
from pathlib import Path
import sys
import time
root = Path(sys.argv[1])
print(int((root/'clock').read_text()) + int(time.monotonic() - float((root/'wall-origin').read_text())))
PYCASE
else
  exec "$REAL_DATE" "$@"
fi
SH
  chmod +x "$KB/date"
  : > "$H/config/fleet-ledger"
  mkdir "$H/state/.fleet-ledger.lock"
  printf '%s\n' "$$" > "$H/state/.fleet-ledger.lock/pid"
  for n in 0 1 2 3 4 5 6 7 8 9; do
    printf 'needs-decision [key=retry] [at=%s]: choose interval\n' "$K1_T0" > "$H/state/k1-ledger-$n.status"
  done
  python3 -c 'import time; print(time.monotonic())' > "$KF/wall-origin"
  k1_pass 220
  python3 - "$H" "$K1_T0" k1-ledger 255 0 <<'PYCASE' || fail 'all ten ownership records must be durably accepted by 255 seconds despite ledger contention'
import json
from pathlib import Path
import re
import sys
home, origin, prefix, bound, overrun = sys.argv[1:]
home = Path(home)
for n in range(10):
    lines = (home/f'state/{prefix}-{n}.status').read_text().splitlines()
    owned = [line for line in lines if line.startswith('blocked ') and ' owned ' in line]
    assert len(owned) == 1, (n, owned)
    assert int(re.search(r'\[at=(\d+)\]', owned[0])[1]) - int(origin) <= int(bound), owned
    assert f'overrun={overrun}' in owned[0], owned
    row = next(json.loads(p.read_text()) for p in (home/'state/autolaunch-controller').glob('ctl-c-ask-*.json')
               if json.loads(p.read_text())['task'] == f'{prefix}-{n}')
    assert row['handoff']['receipt'], row
PYCASE
  for n in 0 1 2 3 4 5 6 7 8 9; do
    printf 'resolved [key=retry] [at=%s]: answered\n' $((K1_T0 + 275)) >> "$H/state/k1-ledger-$n.status"
    printf 'needs-decision [key=retry] [at=%s]: choose interval\n' $((K1_T0 + 55)) > "$H/state/k1-ledger-late-$n.status"
  done
  python3 -c 'import time; print(time.monotonic())' > "$KF/wall-origin"
  k1_pass 275 term
  python3 -c 'import time; print(time.monotonic())' > "$KF/wall-origin"
  k1_pass 330
  python3 - "$H" "$K1_T0" <<'PYCASE' || fail 'ledger closure work must not delay the interrupted batch or change its late verdict'
from pathlib import Path
import re
import sys
home, origin = Path(sys.argv[1]), int(sys.argv[2]) + 55
for n in range(10):
    lines = (home/f'state/k1-ledger-late-{n}.status').read_text().splitlines()
    owned = [line for line in lines if line.startswith('blocked ') and ' owned ' in line]
    assert len(owned) == 1 and 'overrun=1' in owned[0], (n, owned)
    assert int(re.search(r'\[at=(\d+)\]', owned[0])[1]) - origin <= 310, owned
    closed = [line for line in (home/f'state/k1-ledger-{n}.status').read_text().splitlines()
              if line.startswith('resolved ') and '[key=ctl-c-ask-' in line]
    assert len(closed) == 1, (n, closed)
PYCASE
  assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'sibling closures do not consume another planning deadline'
  rm -r "$H/state/.fleet-ledger.lock"
  k1_wait_file "$H/state/fleet-ledger.jsonl" || fail 'the optional bounded ledger hook must still run after acceptance'
  k1_teardown
  pass 'ten-key ownership and closure deadlines are independent of the optional ledger hook'
}

test_controller_journal_contention_keeps_delivery_live() {
  local journal_pid
  k1_setup journal-contention mate
  k1_inbox_due k1-journal-ring
  k1_pass_lock_holder
  mkdir -p "$H/state/autolaunch-controller"
  python3 - "$H/state/autolaunch-controller/.journal.lock" "$KF/journal-ready" <<'PYCASE' &
import fcntl
import os
from pathlib import Path
import sys
import time
with open(sys.argv[1], 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    Path(sys.argv[2]).write_text(str(os.getpid()))
    time.sleep(100000)
PYCASE
  k1_wait_file "$KF/journal-ready" || fail 'journal contention fixture did not acquire its real flock'
  journal_pid=$(cat "$KF/journal-ready")
  k1_pass 55; k1_pass 110; k1_pass 165
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'a retained planning journal cannot suppress the bounded persistent-holder handoff'
  [ "$(k1_units_max_count 60 k1-journal-ring)" -ge 1 ] || fail 'a retained planning journal cannot suppress due non-seat delivery'
  kill -0 "$journal_pid" || fail 'the live journal holder may not be killed or stolen'
  k1_alive "$K1_HOLDER" || fail 'the live primary holder may not be killed or stolen'
  k1_pass 220
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'continued contention never repeats the handoff'
  kill "$journal_pid"; wait "$journal_pid" 2>/dev/null || true
  k1_teardown
  pass 'health ownership and non-seat delivery survive a retained planning journal'
}

test_controller_existing_steps_receive_deadlines() {
  k1_setup leased-step mate
  k1_ready k1-slice
  printf '0\n' > "$KF/free"
  printf 'act k1-slice\n' > "$H/config/autolaunch-steps"
  k1_pass 0
  assert_equals 1 "$(k1_units_max_count 120)" 'activated leased progression receives the other-step-effects deadline'
  k1_wait_file "$H/state/autolaunch-steps.pass" || fail 'activated scheduling must execute the existing leased slice engine'
  python3 - "$H/state/autolaunch-steps.pass" <<'PYCASE' || fail 'the step engine must publish the active owner receipt'
import json
from pathlib import Path
import sys
assert json.loads(Path(sys.argv[1]).read_text())['owners'] == ['k1-slice']
PYCASE
  k1_pass 55
  assert_equals 2 "$(k1_units_max_count 120)" 'a completed slice pass permits the next leased progression'
  k1_teardown
  pass 'activated leased progression runs as recurring bounded step actions'
}

test_controller_activation_preserves_legacy_until_rollout() {
  local manager_bin="$FAKE/controller-manager" out rc
  mkdir -p "$manager_bin"
  cat > "$manager_bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "${FM_K1_FAKE_MANAGER:-ok}" in
  absent) exit 1 ;;
  malformed) echo success ;;
  *) echo '262' ;;
esac
SH
  chmod +x "$manager_bin/systemctl"
  out=$(FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' PATH="$manager_bin:$PATH" bash "$AL")
  assert_equals legacy "$out" 'available manager alone never activates partial K1'
  assert_absent "$H/state/autolaunch-controller" 'selection inspection creates no activation evidence'
  : > "$H/config/autolaunch-sole"
  out=$(FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' PATH="$manager_bin:$PATH" bash "$AL")
  assert_equals controller "$out" 'rollout marker selects the controller with a verified manager'
  rc=0
  FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' FM_K1_FAKE_MANAGER=absent PATH="$manager_bin:$PATH" bash "$AL" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" 'activated home never falls back when manager is unavailable'
  rm "$H/config/autolaunch-sole"
  mkdir -p "$H/state/autolaunch-controller"
  out=$(FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' PATH="$manager_bin:$PATH" bash "$AL")
  assert_equals controller "$out" 'durable controller work retains custody after marker removal'
  rc=0
  FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' FM_K1_FAKE_MANAGER=absent PATH="$manager_bin:$PATH" bash "$AL" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" 'outstanding controller work never falls back without a manager'
  rc=0
  FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE='' FM_K1_FAKE_MANAGER=malformed PATH="$manager_bin:$PATH" bash "$AL" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" 'manager protocol must have a meaningful version response'
  rmdir "$H/state/autolaunch-controller"
  printf 'invalid\n' > "$FAKE/controller-clock"
  rc=0
  FM_TEST_SEAM=1 FM_AUTOLAUNCH_INSPECT_SELECTION=1 FM_AUTOLAUNCH_NOW_FILE="$FAKE/controller-clock" PATH="$manager_bin:$PATH" bash "$AL" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" 'malformed declared test clock never selects legacy execution'
  pass 'controller activation preserves legacy until rollout and protects outstanding work'
}

# === BEGIN tester-owned: lc-core-scheduler EGM1 input-join oracles =========
# EGM point 1 (instruction 009): input join completeness and disagreement
# contract with valid-empty publication and unavailable-home disposition.
# Expected results come from the accepted cut line (EGM dispositions row 1)
# and the read-only advisor contract for cut 1, never from the code under
# test. The builder runs these and never edits this region; a disputed case
# goes back to the tester. The tester report lists, per case, the contract
# sentence behind each expectation and the hand mutant that turns it red.
#
# Seam the build exposes (names frozen by the tester; all fixtures hermetic):
#   fm-autolaunch.sh --join
#       Reads state/autolaunch-steps.candidates of every local registered
#       home (the fm_local_firstmate_state_dirs set) and prints one JSON
#       document on stdout:
#         {schema:"join/v1", status:"COMPLETE"|"NO_PICK", reasons:[...],
#          homes:[{home, status:"available"|"unavailable", reason}],
#          entries:[{owner:{home,task},
#                    result:"ELIGIBLE"|"INELIGIBLE"|"UNKNOWN", reasons}]}
#       Exit 0 for COMPLETE; NO_PICK exits nonzero and never 2 (usage).
#       COMPLETE means the join succeeded, not permission to launch.
#   fm-autolaunch.sh --publish-candidates
#       Atomically replaces this home's publication.
#   Publication fm-seat-candidates/v1: machine; home (the publishing home's
#       physical path); publication_id; completed_at and valid_until (epoch
#       seconds); complete (JSON true); sources.<name>.{status, revision,
#       evidence_digest}, required names tasks, prep, slice, catalogue, where
#       only status ok or not_applicable is a complete read; entries[] of
#       owner{home,task}, slice_id, actor{home,task,kind}, phase, cut,
#       owner_generation, prep{revision, digest, brief_digest} (digest is
#       "sha256:<hex>" of data/<task>/prep.md), source_refs.<source> (the
#       revision the entry was derived from), facts.<name>{verdict
#       allow|deny|unknown, authority, source_ref, reason}.
#   Clock: FM_TEST_SEAM=1 with FM_AUTOLAUNCH_NOW_FILE (the existing seam).
# Run alone: FM_AUTOLAUNCH_EGM1_ONLY='<case>...' (or egm1 for all).
EGM1_T0=1800000000
EGM1_BOUND=30   # tester bound on one --join call; the real budget is the producers'
EGM1_TESTS='test_egm1_g1_unreadable_home_is_no_pick
test_egm1_g1_missing_registered_home_is_no_pick
test_egm1_g1_stale_prep_or_phase_is_not_eligible
test_egm1_g2_valid_empty_home_permits_other_home
test_egm1_g2_bounded_unknown_does_not_block_other_home
test_egm1_g3_missing_garbage_timeout_are_no_pick
test_egm1_g3_unavailable_home_disposition_survives_kick
test_egm1_g3_uncertain_claim_stays_reserved_through_kick
test_egm1_g7_unsupported_or_skewed_publication_is_no_pick
test_egm1_g7_conflicting_revisions_stay_entry_scoped
test_egm1_g7_conflicting_ownership_picks_no_side
test_egm1_g9_complete_zero_rows_is_valid_empty
test_egm1_g9_missing_completion_evidence_is_never_empty
test_egm1_g9_producer_unrecognized_ready_is_not_empty
test_egm1_g1_producer_retains_unprepared_entries'

egm1_setup() {  # <case>: root home R with one registered local child home B
  E="$TMP_ROOT/egm1-$1"
  mkdir -p "$E/root/state" "$E/root/data" "$E/root/config" "$E/b/state" "$E/b/data" "$E/b/config" "$E/bin"
  R=$(cd -P -- "$E/root" && pwd -P) B=$(cd -P -- "$E/b" && pwd -P)
  local h
  for h in "$R" "$B"; do
    fm_test_tasks_toml "$h/.tasks.toml"
    printf '## In flight\n## Queued\n## Done\n' > "$h/data/backlog.md"
  done
  printf -- '- egm1-b - EGM1 fixture home (home: %s; scope: egm1 fixture; projects: proj; added 2026-11-05)\n' "$B" > "$R/data/secondmates.md"
  printf '%s\n' "$EGM1_T0" > "$E/clock"
  export FM_HOME="$R" FM_TEST_SEAM=1 FM_AUTOLAUNCH_NOW_FILE="$E/clock"
  unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
  # Fixture integrity: the existing registered-home owner sees exactly R and B.
  local homes
  homes=$(bash -c '. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-secondmate-registry-lib.sh"
    fm_local_firstmate_state_dirs "$2/state" && printf "%s\n" "${FM_LOCAL_FIRSTMATE_STATES[@]}"' _ "$ROOT" "$R") ||
    fail "EGM1 fixture: fm_local_firstmate_state_dirs refused the fixture registry"
  assert_equals "$R/state"$'\n'"$B/state" "$homes" 'EGM1 fixture: the registered-home set is R then B'
}

egm1_digest() {  # <file>: sha256:<hex> of its bytes
  python3 -c 'import hashlib,sys; print("sha256:" + hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}

egm1_mtime() {  # <file> <epoch>: portable mtime set (GNU and BSD touch differ)
  python3 -c 'import os,sys; os.utime(sys.argv[1], (int(sys.argv[2]), int(sys.argv[2])))' "$1" "$2"
}

egm1_entry() {  # <home> <task>: one entry whose every fact allows, derived from the base sources
  local h=$1 t=$2
  mkdir -p "$h/data/$t"
  [ -f "$h/data/$t/brief.md" ] || printf '# Task\nbrief for %s\n' "$t" > "$h/data/$t/brief.md"
  [ -f "$h/data/$t/prep.md" ] || printf '# Prep\nprep for %s\n' "$t" > "$h/data/$t/prep.md"
  jq -cn --arg h "$h" --arg t "$t" --arg pd "$(egm1_digest "$h/data/$t/prep.md")" \
    --arg bd "$(egm1_digest "$h/data/$t/brief.md")" '
    def fact($a; $r): {verdict: "allow", authority: $a, source_ref: $r};
    {owner: {home: $h, task: $t}, slice_id: "ops/egm1-fixture",
     actor: {home: $h, task: $t, kind: "builder"}, phase: "build", cut: "egm1",
     owner_generation: 1, prep: {revision: "prep-r1", digest: $pd, brief_digest: $bd},
     source_refs: {tasks: "tasks-r1", prep: "prep-r1", slice: "slice-r1", catalogue: "cat-r1", claims: "claims-r1"},
     facts: {task: fact("tasks"; "tasks-r1"), dependencies: fact("tasks"; "tasks-r1"),
             prep: fact("prep"; "prep-r1"), phase: fact("slice"; "slice-r1"),
             placement: fact("catalogue"; "cat-r1"), claim: fact("claims"; "claims-r1")}}'
}

egm1_pub() {  # <home> [entries-json] [jq-filter]: write a complete publication for <home>
  local h=$1 entries=${2:-[]} filter=${3:-.}
  jq -n --arg h "$h" --argjson t0 "$EGM1_T0" --argjson entries "$entries" '
    def src($r): {status: "ok", revision: $r, evidence_digest: ("sha256:" + ("0" * 64))};
    {schema: "fm-seat-candidates/v1", machine: "egm1-machine", home: $h,
     publication_id: ("pub-" + ($h | split("/") | last) + "-1"),
     completed_at: ($t0 - 10), valid_until: ($t0 + 300), complete: true,
     sources: {tasks: src("tasks-r1"), prep: src("prep-r1"), slice: src("slice-r1"),
               catalogue: src("cat-r1"), claims: src("claims-r1")},
     entries: $entries}' | jq "$filter" > "$h/state/autolaunch-steps.candidates" ||
    fail "EGM1 fixture: cannot write the publication for $h"
}

egm1_join() {  # one --join call under the tester bound
  EGM1_OUT=$(timeout -k 5 "$EGM1_BOUND" bash "$AL" --join 2>"$E/join.err")
  EGM1_RC=$?
}

egm1_doc() {  # <label>: the first assertion of every case - a join/v1 document came back
  case "$EGM1_RC" in
    124|137) fail "$1: --join was killed by the tester bound of ${EGM1_BOUND}s instead of returning" ;;
  esac
  printf '%s\n' "$EGM1_OUT" | jq -e '.schema == "join/v1" and (.status == "COMPLETE" or .status == "NO_PICK")
    and (.homes | type == "array") and (.entries | type == "array") and (.reasons | type == "array")' >/dev/null 2>&1 ||
    fail "$1: --join printed no join/v1 document (rc=$EGM1_RC; stdout: $(printf '%s' "$EGM1_OUT" | head -c 200); stderr: $(head -c 200 "$E/join.err"))"
}

egm1_complete() {  # <label>
  egm1_join
  egm1_doc "$1"
  assert_equals COMPLETE "$(printf '%s\n' "$EGM1_OUT" | jq -r .status)" "$1: join status"
  expect_code 0 "$EGM1_RC" "$1: a COMPLETE join exits 0"
}

egm1_no_pick() {  # <label> [unavailable-home]
  egm1_join
  egm1_doc "$1"
  assert_equals NO_PICK "$(printf '%s\n' "$EGM1_OUT" | jq -r .status)" "$1: join status"
  [ "$EGM1_RC" != 0 ] && [ "$EGM1_RC" != 2 ] || fail "$1: NO_PICK must exit nonzero and not 2 (usage), got $EGM1_RC"
  [ "$(printf '%s\n' "$EGM1_OUT" | jq '.reasons | length')" -gt 0 ] || fail "$1: NO_PICK carries no typed reason"
  [ -z "${2:-}" ] || egm1_unavailable "$1" "$2"
}

egm1_unavailable() {  # <label> <home>: the explicit failure disposition for a home that cannot run
  assert_equals unavailable "$(printf '%s\n' "$EGM1_OUT" | jq -r --arg h "$2" '[.homes[] | select(.home == $h) | .status] | join(",")')" \
    "$1: $2 is listed once as unavailable, never dropped"
  [ -n "$(printf '%s\n' "$EGM1_OUT" | jq -r --arg h "$2" '.homes[] | select(.home == $h) | .reason // empty')" ] ||
    fail "$1: the unavailable home $2 carries no reason"
}

egm1_result() {  # <home> <task>: the entry's results, comma-joined (one entry gives one word)
  printf '%s\n' "$EGM1_OUT" | jq -r --arg h "$1" --arg t "$2" \
    '[.entries[] | select(.owner.home == $h and .owner.task == $t) | .result] | join(",")'
}

# G1: an unreadable home is never dropped from the machine-wide join.
test_egm1_g1_unreadable_home_is_no_pick() {
  egm1_setup g1-unreadable
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1 G1 baseline: both homes readable'
  chmod 000 "$B/state/autolaunch-steps.candidates"
  if [ -r "$B/state/autolaunch-steps.candidates" ]; then
    chmod 600 "$B/state/autolaunch-steps.candidates"
    printf 'skip: EGM1 G1 unreadable-home case needs a non-root user (mode 000 stays readable)\n'
    return 0
  fi
  egm1_no_pick 'EGM1 G1: an unreadable home publication gives NO_PICK' "$B"
  chmod 600 "$B/state/autolaunch-steps.candidates"
  pass 'EGM1 G1 test_egm1_g1_unreadable_home_is_no_pick: an unreadable home is NO_PICK with an explicit unavailable disposition'
}

test_egm1_g1_missing_registered_home_is_no_pick() {
  egm1_setup g1-missing-home
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1 G1 baseline: registered home present'
  mv "$B" "$E/b-gone"
  egm1_no_pick 'EGM1 G1: a registered local home that is unavailable gives NO_PICK'
  mv "$E/b-gone" "$B"
  pass 'EGM1 G1 test_egm1_g1_missing_registered_home_is_no_pick: a failed home enumeration never returns success'
}

# G1: stale prep or phase evidence leaves no eligible entry; a sibling stays eligible.
test_egm1_g1_stale_prep_or_phase_is_not_eligible() {
  local variant filter
  egm1_setup g1-stale
  egm1_pub "$R" "[$(egm1_entry "$R" fresh),$(egm1_entry "$R" stale)]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1 G1 baseline: current revisions'
  assert_equals ELIGIBLE "$(egm1_result "$R" stale)" 'EGM1 G1 baseline: the all-allow entry is eligible'
  for variant in prep-revision phase-revision; do
    case "$variant" in
      prep-revision) filter='(.entries[] | select(.owner.task == "stale") | .source_refs.prep) = "prep-r0"' ;;
      phase-revision) filter='(.entries[] | select(.owner.task == "stale") | .source_refs.slice) = "slice-r0"' ;;
    esac
    egm1_pub "$R" "[$(egm1_entry "$R" fresh),$(egm1_entry "$R" stale)]" "$filter"
    egm1_complete "EGM1 G1 $variant: a bounded stale entry does not stop the join"
    assert_equals UNKNOWN "$(egm1_result "$R" stale)" "EGM1 G1 $variant: the stale entry is UNKNOWN, never eligible or dropped"
    assert_equals ELIGIBLE "$(egm1_result "$R" fresh)" "EGM1 G1 $variant: the current sibling stays eligible"
  done
  # The prep document changed after the publication: its digest no longer matches.
  egm1_pub "$R" "[$(egm1_entry "$R" fresh),$(egm1_entry "$R" stale)]"
  printf 'revised after publication\n' >> "$R/data/stale/prep.md"
  egm1_join
  egm1_doc 'EGM1 G1 prep-digest'
  [ "$(egm1_result "$R" stale)" != ELIGIBLE ] || fail 'EGM1 G1 prep-digest: an entry whose prep changed after publication is eligible'
  pass 'EGM1 G1 test_egm1_g1_stale_prep_or_phase_is_not_eligible: stale prep or phase gives no eligible entry'
}

# G2: a legitimate empty home must not stall another home's eligible work.
test_egm1_g2_valid_empty_home_permits_other_home() {
  egm1_setup g2-valid-empty
  egm1_pub "$R" "[]"
  egm1_pub "$B" "[$(egm1_entry "$B" b-task)]"
  egm1_complete 'EGM1 G2: valid-empty R plus eligible B'
  assert_equals ELIGIBLE "$(egm1_result "$B" b-task)" "EGM1 G2: B's entry is eligible beside a valid-empty home"
  assert_equals available "$(printf '%s\n' "$EGM1_OUT" | jq -r --arg h "$R" '[.homes[] | select(.home == $h) | .status] | join(",")')" \
    'EGM1 G2: the valid-empty home is available'
  pass 'EGM1 G2 test_egm1_g2_valid_empty_home_permits_other_home: valid-empty A plus eligible B permits B'
}

test_egm1_g2_bounded_unknown_does_not_block_other_home() {
  egm1_setup g2-bounded-unknown
  egm1_pub "$R" "[$(egm1_entry "$R" r-unknown)]" \
    '(.entries[0].facts.dependencies) = {verdict: "unknown", authority: "tasks", source_ref: "tasks-r1", reason: "dependency evidence missing"}'
  egm1_pub "$B" "[$(egm1_entry "$B" b-task)]"
  egm1_complete 'EGM1 G2: an R-only unknown entry'
  assert_equals UNKNOWN "$(egm1_result "$R" r-unknown)" 'EGM1 G2: the R entry with missing evidence is UNKNOWN'
  assert_equals ELIGIBLE "$(egm1_result "$B" b-task)" 'EGM1 G2: an R-only unknown does not block B'
  pass 'EGM1 G2 test_egm1_g2_bounded_unknown_does_not_block_other_home: a bounded unknown stays entry-scoped'
}

# G3: each dependency failure produces the specified scope.
test_egm1_g3_missing_garbage_timeout_are_no_pick() {
  local variant
  egm1_setup g3-dependency
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  for variant in missing garbage source-timeout expired fifo; do
    rm -f "$B/state/autolaunch-steps.candidates"
    egm1_pub "$B" "[]"
    egm1_complete "EGM1 G3 $variant baseline"
    case "$variant" in
      missing) rm -f "$B/state/autolaunch-steps.candidates" ;;
      garbage) printf 'ready[2]: ??? \x01 not a publication\n' > "$B/state/autolaunch-steps.candidates" ;;
      source-timeout) egm1_pub "$B" "[]" '.sources.tasks = {status: "timeout", revision: "tasks-r1", reason: "fm-tasks-axi ready did not answer"}' ;;
      expired) egm1_pub "$B" "[]" '.valid_until = (.completed_at + 5)' ;;
      fifo) rm -f "$B/state/autolaunch-steps.candidates"; mkfifo "$B/state/autolaunch-steps.candidates" ;;
    esac
    egm1_no_pick "EGM1 G3 $variant: B's publication fails" "$B"
  done
  rm -f "$B/state/autolaunch-steps.candidates"
  pass 'EGM1 G3 test_egm1_g3_missing_garbage_timeout_are_no_pick: missing, garbage, timed-out, expired and blocking input are NO_PICK naming the home'
}

# G3: a kick never stands in for the input of a home that cannot run.
test_egm1_g3_unavailable_home_disposition_survives_kick() {
  local kick
  egm1_setup g3-kick-unavailable
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  for kick in none fresh expired; do
    rm -f "$B/state/autolaunch-steps.candidates" "$B/state/.autolaunch.kick"
    case "$kick" in
      fresh) printf 'kick for %s\n' "$B" > "$B/state/.autolaunch.kick"; egm1_mtime "$B/state/.autolaunch.kick" "$EGM1_T0" ;;
      expired) printf 'kick for %s\n' "$B" > "$B/state/.autolaunch.kick"; egm1_mtime "$B/state/.autolaunch.kick" "$((EGM1_T0 - 3600))" ;;
    esac
    egm1_no_pick "EGM1 G3 kick=$kick: B has no publication" "$B"
  done
  pass 'EGM1 G3 test_egm1_g3_unavailable_home_disposition_survives_kick: a kicked, expired or unkicked home without input stays unavailable and NO_PICK'
}

# G3: an uncertain claim stays reserved; kick success or expiry is not claim absence.
test_egm1_g3_uncertain_claim_stays_reserved_through_kick() {
  local kick
  egm1_setup g3-uncertain-claim
  egm1_pub "$R" "[]"
  for kick in none fresh expired; do
    rm -f "$B/state/.autolaunch.kick"
    case "$kick" in
      fresh) printf 'kick for %s\n' "$B" > "$B/state/.autolaunch.kick"; egm1_mtime "$B/state/.autolaunch.kick" "$EGM1_T0" ;;
      expired) printf 'kick for %s\n' "$B" > "$B/state/.autolaunch.kick"; egm1_mtime "$B/state/.autolaunch.kick" "$((EGM1_T0 - 3600))" ;;
    esac
    egm1_pub "$B" "[$(egm1_entry "$B" claimed)]" \
      '(.entries[0].facts.claim) = {verdict: "unknown", authority: "claims", source_ref: "claims-r1", reason: "writer state uncertain"}'
    egm1_join
    egm1_doc "EGM1 G3 claim kick=$kick"
    assert_equals UNKNOWN "$(egm1_result "$B" claimed)" "EGM1 G3 claim kick=$kick: the uncertain-claim entry stays present and UNKNOWN"
  done
  rm -f "$B/state/.autolaunch.kick"
  pass 'EGM1 G3 test_egm1_g3_uncertain_claim_stays_reserved_through_kick: an uncertain claim stays reserved with or without a kick'
}

# G7: version skew and copied publications are rejected machine-wide.
test_egm1_g7_unsupported_or_skewed_publication_is_no_pick() {
  local variant
  egm1_setup g7-skew
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  for variant in schema-v2 duplicate-key copied-home; do
    egm1_pub "$B" "[]"
    egm1_complete "EGM1 G7 $variant baseline"
    case "$variant" in
      schema-v2) egm1_pub "$B" "[]" '.schema = "fm-seat-candidates/v2"' ;;
      duplicate-key)
        egm1_pub "$B" "[]"
        python3 - "$B/state/autolaunch-steps.candidates" <<'PY'
import sys
p = sys.argv[1]
text = open(p).read().rstrip()
# A second "complete" member: a lenient reader keeps the last value.
open(p, "w").write(text[:-1].rstrip() + ',\n  "complete": false\n}\n')
PY
        ;;
      copied-home) egm1_pub "$R" "[]"; cp "$R/state/autolaunch-steps.candidates" "$B/state/autolaunch-steps.candidates"
        egm1_pub "$R" "[$(egm1_entry "$R" r-task)]" ;;
    esac
    egm1_no_pick "EGM1 G7 $variant: B's publication is not current v1 evidence for B" "$B"
  done
  pass 'EGM1 G7 test_egm1_g7_unsupported_or_skewed_publication_is_no_pick: unsupported schema, duplicate members and a copied publication are NO_PICK'
}

# G7: conflicting revisions on one identified entry stay entry-scoped.
test_egm1_g7_conflicting_revisions_stay_entry_scoped() {
  egm1_setup g7-revisions
  egm1_pub "$R" "[$(egm1_entry "$R" ok-task),$(egm1_entry "$R" split-task)]" \
    '(.entries[] | select(.owner.task == "split-task") | .facts.prep.source_ref) = "prep-r0"
     | (.entries[] | select(.owner.task == "split-task") | .prep.revision) = "prep-r0"'
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1 G7: one entry carries a revision its source does not publish'
  assert_equals UNKNOWN "$(egm1_result "$R" split-task)" 'EGM1 G7: the entry with conflicting revisions is UNKNOWN'
  assert_equals ELIGIBLE "$(egm1_result "$R" ok-task)" 'EGM1 G7: the consistent sibling stays eligible'
  pass 'EGM1 G7 test_egm1_g7_conflicting_revisions_stay_entry_scoped: a revision conflict makes only its entry UNKNOWN'
}

# G7: two homes claiming one task are never resolved by picking a side.
test_egm1_g7_conflicting_ownership_picks_no_side() {
  egm1_setup g7-ownership
  egm1_entry "$B" shared >/dev/null
  egm1_pub "$B" "[$(egm1_entry "$B" shared)]"
  egm1_pub "$R" "[$(egm1_entry "$B" shared)]"
  egm1_no_pick 'EGM1 G7: R and B both publish the owner entry B/shared'
  [ -z "$(printf '%s\n' "$EGM1_OUT" | jq -r '.entries[] | select(.result == "ELIGIBLE") | .owner.task')" ] ||
    fail 'EGM1 G7: a side of the ownership conflict was made eligible'
  pass 'EGM1 G7 test_egm1_g7_conflicting_ownership_picks_no_side: conflicting ownership is NO_PICK and no side is eligible'
}

# G9: a complete zero-row publication is a valid empty join.
test_egm1_g9_complete_zero_rows_is_valid_empty() {
  egm1_setup g9-valid-empty
  egm1_pub "$R" "[]"
  egm1_pub "$B" "[]" '.sources.catalogue = {status: "not_applicable", revision: "cat-r1", reason: "no catalogue rows for this home"}'
  egm1_complete 'EGM1 G9: every home completed with zero rows'
  assert_equals 0 "$(printf '%s\n' "$EGM1_OUT" | jq '.entries | length')" 'EGM1 G9: a valid empty join has no entries'
  assert_equals available,available "$(printf '%s\n' "$EGM1_OUT" | jq -r --arg r "$R" --arg b "$B" \
    '[([.homes[] | select(.home == $r) | .status] | join("+")), ([.homes[] | select(.home == $b) | .status] | join("+"))] | join(",")')" \
    'EGM1 G9: both homes are listed once, available'
  pass 'EGM1 G9 test_egm1_g9_complete_zero_rows_is_valid_empty: a complete zero-row publication succeeds'
}

# G9: missing completion or source evidence never counts as valid-empty.
test_egm1_g9_missing_completion_evidence_is_never_empty() {
  local variant
  egm1_setup g9-not-empty
  egm1_pub "$R" "[]"
  for variant in incomplete no-catalogue skipped-source no-completed-at string-complete zero-byte blank; do
    egm1_pub "$B" "[]"
    egm1_complete "EGM1 G9 $variant baseline"
    case "$variant" in
      incomplete) egm1_pub "$B" "[]" '.complete = false' ;;
      no-catalogue) egm1_pub "$B" "[]" 'del(.sources.catalogue)' ;;
      skipped-source) egm1_pub "$B" "[]" '.sources.prep = {status: "skipped", revision: "prep-r1"}' ;;
      no-completed-at) egm1_pub "$B" "[]" 'del(.completed_at)' ;;
      string-complete) egm1_pub "$B" "[]" '.complete = "true"' ;;
      zero-byte) : > "$B/state/autolaunch-steps.candidates" ;;
      blank) printf '\n  \n' > "$B/state/autolaunch-steps.candidates" ;;
    esac
    egm1_no_pick "EGM1 G9 $variant: B's empty publication lacks completion evidence" "$B"
  done
  pass 'EGM1 G9 test_egm1_g9_missing_completion_evidence_is_never_empty: incomplete, skipped, absent or blank evidence is never valid-empty'
}

egm1_ready_stub() {  # <mode>: tasks-axi on PATH answers `ready` per <mode>, else the real tool
  local real
  real=$(command -v tasks-axi)
  cat > "$E/bin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = ready ]; then
  case "$1" in
    blank) exit 0 ;;
    garbage) printf 'ready[zz]: the backlog service returned something else\n'; exit 0 ;;
  esac
fi
exec "$real" "\$@"
SH
  chmod +x "$E/bin/tasks-axi"
}

egm1_publish() {  # <home> [PATH-prefix]: run the producer for <home>
  # Command-local FM_HOME and PATH: nothing leaks into the caller's shell.
  local path=$PATH
  [ -z "${2:-}" ] || path="$2:$PATH"
  FM_HOME="$1" PATH="$path" timeout -k 5 "$EGM1_BOUND" bash "$AL" --publish-candidates >"$E/publish.out" 2>&1
  EGM1_PUB_RC=$?
}

# G9 (producer): unrecognized successful ready output is not a complete empty read.
test_egm1_g9_producer_unrecognized_ready_is_not_empty() {
  local mode p tasks
  egm1_setup g9-producer
  p="$R/state/autolaunch-steps.candidates"
  egm1_pub "$B" "[]"
  egm1_publish "$R"
  jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
    fail "EGM1 G9 producer baseline: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
  assert_equals ok "$(jq -r '.sources.tasks.status' "$p")" 'EGM1 G9 producer baseline: a real empty ready queue is a complete tasks read'
  for mode in blank garbage; do
    rm -f "$p"
    egm1_ready_stub "$mode"
    egm1_publish "$R" "$E/bin"
    if [ -e "$p" ]; then
      tasks=$(jq -r '.sources.tasks.status // "absent"' "$p" 2>/dev/null)
      case "$tasks" in ok|not_applicable) fail "EGM1 G9 producer $mode: unrecognized ready output was published as tasks status $tasks" ;; esac
      [ "$(jq -r '.complete' "$p" 2>/dev/null)" != true ] ||
        fail "EGM1 G9 producer $mode: unrecognized ready output was published as complete"
    fi
    egm1_no_pick "EGM1 G9 producer $mode: the join after an unrecognized ready read"
  done
  pass 'EGM1 G9 test_egm1_g9_producer_unrecognized_ready_is_not_empty: blank or garbage ready output never publishes a complete empty home'
}

# G1 (producer): a completed scan keeps refused entries instead of omitting them.
test_egm1_g1_producer_retains_unprepared_entries() {
  local p
  egm1_setup g1-producer
  p="$R/state/autolaunch-steps.candidates"
  mkdir -p "$R/projects/proj"
  printf '## In flight\n## Queued\n- [ ] alpha - prepared (repo: proj) (kind: ship)\n- [ ] beta - not prepared (repo: proj) (kind: ship)\n## Done\n' > "$R/data/backlog.md"
  egm1_entry "$R" alpha >/dev/null
  egm1_publish "$R"
  jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
    fail "EGM1 G1 producer: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
  assert_equals ok "$(jq -r '.sources.tasks.status' "$p")" 'EGM1 G1 producer: the ready queue was read completely'
  assert_equals alpha,beta "$(jq -r --arg h "$R" '[.entries[] | select(.owner.home == $h) | .owner.task] | sort | join(",")' "$p")" \
    'EGM1 G1 producer: both ready items are published, the unprepared one included'
  [ "$(jq -r '[.entries[] | select(.owner.task == "beta") | .facts.prep.verdict] | join(",")' "$p")" != allow ] ||
    fail 'EGM1 G1 producer: the unprepared item is published with an allowing prep fact'
  pass 'EGM1 G1 test_egm1_g1_producer_retains_unprepared_entries: a completed scan retains refused entries'
}

egm1_run() {  # <case>... (egm1 = all)
  local name
  # shellcheck disable=SC2086 # one test name per word
  [ "$*" != egm1 ] || set -- $EGM1_TESTS
  for name in "$@"; do
    [ "$(type -t "$name")" = function ] || fail "unknown EGM1 case $name"
    "$name"
  done
}
if [ -n "${FM_AUTOLAUNCH_EGM1_ONLY:-}" ]; then
  # shellcheck disable=SC2086 # one test name per word
  egm1_run $FM_AUTOLAUNCH_EGM1_ONLY
  exit 0
fi
# === END tester-owned EGM1 (definitions; the full run calls egm1_run egm1 last) ===

# === BEGIN tester-owned: lc-core-scheduler EGM1-R2 join validation oracles ==
# Round 2 of the independent EGM point 1 tests: three validation gaps the
# round-1 cases above did not catch, found by the final read-only advice on
# the hermetic join. Expected results come from that advice and from the
# round-1 seam frozen in the EGM1 block header, never from the code under
# test. The builder runs these and never edits this region; a disputed case
# goes back to the tester. The cases reuse the round-1 fixture helpers
# (egm1_setup, egm1_entry, egm1_pub, egm1_publish and the join assertions)
# and change nothing in that block.
#   R2-1  every consumed authority's revision is validated: a missing claim
#         revision or reference never compares equal as absent.
#   R2-2  the producer never records malformed ready output as a successful
#         tasks read.
#   R2-3  contradictory or unscoped task detail never clears a hold.
# Run alone: FM_AUTOLAUNCH_EGM1R2_ONLY='<case>...' (or egm1r2 for all).
EGM1R2_TESTS='test_egm1r2_missing_claim_references_are_never_eligible
test_egm1r2_malformed_ready_is_not_a_successful_read
test_egm1r2_contradictory_task_detail_never_clears_a_hold
test_egm1r2_stray_top_level_held_is_unknown'

egm1r2_entry_result() {  # <label> <task> <expected>: the entry is listed once with <expected>
  assert_equals "$3" "$(egm1_result "$R" "$2")" "$1: entry $2 is listed once as $3"
}

# R2-1: missing or malformed claim evidence is entry UNKNOWN, never ELIGIBLE.
test_egm1r2_missing_claim_references_are_never_eligible() {
  local variant filter src facts
  egm1_setup r2-claims
  egm1_pub "$B" "[]"
  egm1_pub "$R" "[$(egm1_entry "$R" target),$(egm1_entry "$R" sibling)]"
  egm1_complete 'EGM1-R2 claims baseline: explicit matching claim revisions'
  egm1r2_entry_result 'EGM1-R2 claims baseline' target ELIGIBLE
  egm1r2_entry_result 'EGM1-R2 claims baseline' sibling ELIGIBLE
  # Entry-side removals and malformed values: only the target entry changes.
  for variant in no-entry-ref no-fact-ref both-entry-refs empty-fact-ref null-fact-ref numeric-entry-ref fact-not-object; do
    case "$variant" in
      no-entry-ref) filter='del(.source_refs.claims)' ;;
      no-fact-ref) filter='del(.facts.claim.source_ref)' ;;
      both-entry-refs) filter='del(.source_refs.claims) | del(.facts.claim.source_ref)' ;;
      empty-fact-ref) filter='.facts.claim.source_ref = ""' ;;
      null-fact-ref) filter='.facts.claim.source_ref = null' ;;
      numeric-entry-ref) filter='.source_refs.claims = 1' ;;
      fact-not-object) filter='.facts.claim = "allow"' ;;
    esac
    egm1_pub "$R" "[$(egm1_entry "$R" target | jq -c "$filter"),$(egm1_entry "$R" sibling)]"
    egm1_complete "EGM1-R2 claims $variant: a bounded entry-side claim defect"
    egm1r2_entry_result "EGM1-R2 claims $variant: missing or malformed claim evidence" target UNKNOWN
    egm1r2_entry_result "EGM1-R2 claims $variant: the sibling with explicit claim evidence" sibling ELIGIBLE
  done
  # Source-side removals: the claims source publishes no revision.
  for variant in no-source-revision source-and-target-refs all-claim-refs; do
    case "$variant" in
      no-source-revision) filter='.' ;;
      source-and-target-refs) filter='del(.source_refs.claims) | del(.facts.claim.source_ref)' ;;
      all-claim-refs) filter='del(.source_refs.claims) | del(.facts.claim.source_ref)' ;;
    esac
    if [ "$variant" = all-claim-refs ]; then
      egm1_pub "$R" "[$(egm1_entry "$R" target | jq -c "$filter"),$(egm1_entry "$R" sibling | jq -c "$filter")]" \
        '.sources.claims = {status: "ok"}'
    else
      egm1_pub "$R" "[$(egm1_entry "$R" target | jq -c "$filter"),$(egm1_entry "$R" sibling)]" \
        '.sources.claims = {status: "ok"}'
    fi
    # The contract fixes only the entry result here, not the top-level status.
    egm1_join
    egm1_doc "EGM1-R2 claims $variant: the optional claims source has no revision"
    [ -z "$(printf '%s\n' "$EGM1_OUT" | jq -r '.entries[] | select(.result == "ELIGIBLE") | .owner.task')" ] ||
      fail "EGM1-R2 claims $variant: an entry is ELIGIBLE against a claims source with no revision"
    if [ "$(printf '%s\n' "$EGM1_OUT" | jq -r .status)" = COMPLETE ]; then
      egm1r2_entry_result "EGM1-R2 claims $variant: a claim reference that matches no published revision" target UNKNOWN
      egm1r2_entry_result "EGM1-R2 claims $variant: the sibling consumes the same unrevisioned claims source" sibling UNKNOWN
    fi
  done
  # Every consumed authority, the required ones included: with the source
  # revision and every reference to it removed together, nothing is eligible.
  for src in tasks:task,dependencies prep:prep slice:phase catalogue:placement claims:claim; do
    facts=${src#*:} src=${src%%:*}
    filter="del(.source_refs.$src)"
    for variant in ${facts//,/ }; do filter="$filter | del(.facts.$variant.source_ref)"; done
    egm1_pub "$R" "[$(egm1_entry "$R" target | jq -c "$filter"),$(egm1_entry "$R" sibling | jq -c "$filter")]" \
      ".sources.$src |= del(.revision)"
    egm1_join
    egm1_doc "EGM1-R2 authority $src: revision and references absent together"
    [ -z "$(printf '%s\n' "$EGM1_OUT" | jq -r '.entries[] | select(.result == "ELIGIBLE") | .owner.task')" ] ||
      fail "EGM1-R2 authority $src: an entry with no $src revision on either side is ELIGIBLE"
    if [ "$(printf '%s\n' "$EGM1_OUT" | jq -r .status)" = COMPLETE ]; then
      egm1r2_entry_result "EGM1-R2 authority $src: a COMPLETE join keeps the unrevisioned entry" target UNKNOWN
    fi
  done
  pass 'EGM1-R2 test_egm1r2_missing_claim_references_are_never_eligible: absent or malformed authority revisions never compare equal'
}

egm1r2_ready_stub() {  # <file>: tasks-axi on PATH prints <file> for `ready` (exit 0), else the real tool
  local real
  real=$(command -v tasks-axi)
  cat > "$E/bin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = ready ]; then cat '$1'; exit 0; fi
exec '$real' "\$@"
SH
  chmod +x "$E/bin/tasks-axi"
}

# R2-2: malformed successful ready output is never a successful tasks read.
test_egm1r2_malformed_ready_is_not_a_successful_read() {
  local p variant real tasks
  egm1_setup r2-ready
  p="$R/state/autolaunch-steps.candidates"
  mkdir -p "$R/projects/proj"
  printf '## In flight\n## Queued\n- [ ] work - a ready item, "quoted, title" (repo: proj) (kind: scout)\n## Done\n' > "$R/data/backlog.md"
  egm1_entry "$R" work >/dev/null
  egm1_pub "$B" "[]"
  # Positive control: the real tool's own output, replayed through the stub.
  real=$( (cd "$R" && tasks-axi ready) ) || fail 'EGM1-R2 ready fixture: the real ready read failed'
  case "$real" in *'ready[1]{'*) : ;; *) fail "EGM1-R2 ready fixture: the real ready output lists no row: $real" ;; esac
  printf '%s\n' "$real" > "$E/ready.out"
  egm1r2_ready_stub "$E/ready.out"
  egm1_publish "$R" "$E/bin"
  jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
    fail "EGM1-R2 ready replay: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
  assert_equals ok "$(jq -r '.sources.tasks.status' "$p")" 'EGM1-R2 ready replay: the real one-row output is a complete tasks read'
  assert_equals work "$(jq -r --arg h "$R" '[.entries[] | select(.owner.home == $h) | .owner.task] | join(",")' "$p")" \
    'EGM1-R2 ready replay: the quoted-title row is published'
  for variant in advisor-empty-with-row empty-with-row advisor-truncated truncated-row wide-row unterminated-quote count-mismatch; do
    case "$variant" in
      advisor-empty-with-row) printf 'ready: 0\n  lost-task,ship,demo\ncount: 0\n' ;;
      empty-with-row) printf 'count: 0\nready: 0 unblocked queued tasks\n  work,queued,scout,proj,"t"\n' ;;
      advisor-truncated) printf 'ready[1]{id,kind,repo}:\n  lost-task\ncount: 1\n' ;;
      truncated-row) printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  work,queued\n' ;;
      wide-row) printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  work,queued,scout,proj,"t",extra\n' ;;
      unterminated-quote) printf 'count: 1\nready[1]{id,state,kind,repo,title}:\n  work,queued,scout,proj,"unterminated title\n' ;;
      count-mismatch) printf 'count: 2\nready[2]{id,state,kind,repo,title}:\n  work,queued,scout,proj,"t"\n' ;;
    esac > "$E/ready.out"
    rm -f "$p"
    egm1_publish "$R" "$E/bin"
    if [ -e "$p" ]; then
      tasks=$(jq -r '.sources.tasks.status // "absent"' "$p" 2>/dev/null)
      case "$tasks" in ok|not_applicable) fail "EGM1-R2 ready $variant: malformed ready output was recorded as tasks status $tasks" ;; esac
      [ "$(jq -r '.complete' "$p" 2>/dev/null)" != true ] ||
        fail "EGM1-R2 ready $variant: malformed ready output was published as complete"
    fi
    egm1_no_pick "EGM1-R2 ready $variant: the join after a malformed ready read"
  done
  pass 'EGM1-R2 test_egm1r2_malformed_ready_is_not_a_successful_read: contradictory, truncated or malformed ready output is never a successful read'
}

egm1r2_show_stub() {  # <file>: tasks-axi on PATH prints <file> for `show` (exit 0), else the real tool
  local real
  real=$(command -v tasks-axi)
  cat > "$E/bin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ]; then cat '$1'; exit 0; fi
exec '$real' "\$@"
SH
  chmod +x "$E/bin/tasks-axi"
}

egm1r2_detail() {  # <variant>: one exit-zero task detail response for the ready item work
  local held_a='  held: no' tail=''
  case "$1" in
    held-no) : ;;
    held-yes) held_a='  held: yes' ;;
    held-no-then-yes) held_a=$'  held: no\n  held: yes' ;;
    held-yes-then-no) held_a=$'  held: yes\n  held: no' ;;
    held-outside-block) held_a='' tail='held: no' ;;
    held-also-outside) tail='held: yes' ;;
  esac
  printf 'task:\n'
  case "$1" in
    id-duplicate) printf '  id: work\n  id: other\n' ;;
    id-outside-block) : ;;
    *) printf '  id: work\n' ;;
  esac
  printf '  title: "a ready item"\n  state: queued\n  blocked: no\n'
  [ -z "$held_a" ] || printf '%s\n' "$held_a"
  case "$1" in
    kind-duplicate) printf '  kind: scout\n  kind: ship\n' ;;
    *) printf '  kind: scout\n' ;;
  esac
  case "$1" in
    repo-duplicate) printf '  repo: proj\n  repo: other\n' ;;
    *) printf '  repo: proj\n' ;;
  esac
  printf '  body: ""\n'
  [ "$1" != id-outside-block ] || printf 'id: work\n'
  [ -z "$tail" ] || printf '%s\n' "$tail"
}

egm1r2_fact() {  # <fact>: the published work entry's <fact> verdicts, comma-joined
  jq -r --arg h "$R" --arg f "$1" '[.entries[] | select(.owner.home == $h and .owner.task == "work") | .facts[$f].verdict // "absent"] | join(",")' \
    "$R/state/autolaunch-steps.candidates" 2>/dev/null
}

# R2-3: contradictory or unscoped task detail stays unknown and never clears a hold.
test_egm1r2_contradictory_task_detail_never_clears_a_hold() {
  local p variant
  egm1_setup r2-detail
  p="$R/state/autolaunch-steps.candidates"
  mkdir -p "$R/projects/proj"
  printf '## In flight\n## Queued\n- [ ] work - a ready item (repo: proj) (kind: scout)\n## Done\n' > "$R/data/backlog.md"
  egm1_entry "$R" work >/dev/null
  # Positive controls: one correctly scoped held field is authoritative.
  for variant in held-no held-yes; do
    egm1r2_detail "$variant" > "$E/show.out"
    egm1r2_show_stub "$E/show.out"
    rm -f "$p"
    egm1_publish "$R" "$E/bin"
    jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
      fail "EGM1-R2 detail $variant: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
    case "$variant" in
      held-no)
        assert_equals allow "$(egm1r2_fact task)" 'EGM1-R2 detail held-no: a scoped held: no task is published as allowed'
        assert_equals allow "$(egm1r2_fact prep)" 'EGM1-R2 detail held-no: the prepared scout stays prepared' ;;
      held-yes)
        assert_equals deny "$(egm1r2_fact task)" 'EGM1-R2 detail held-yes: an authoritative hold is a denial' ;;
    esac
  done
  for variant in held-no-then-yes held-yes-then-no held-outside-block id-duplicate id-outside-block kind-duplicate repo-duplicate; do
    egm1r2_detail "$variant" > "$E/show.out"
    rm -f "$p"
    egm1_publish "$R" "$E/bin"
    jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
      fail "EGM1-R2 detail $variant: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
    assert_equals unknown "$(egm1r2_fact task)" "EGM1-R2 detail $variant: contradictory or unscoped task detail stays unknown"
    [ "$(egm1r2_fact prep)" != allow ] ||
      fail "EGM1-R2 detail $variant: contradictory or unscoped task detail produced an allowing prep fact"
  done
  pass 'EGM1-R2 test_egm1r2_contradictory_task_detail_never_clears_a_hold: duplicate, contradictory or unscoped detail never clears a hold'
}

# R2-3 (scope): a held field outside the task: block contradicts the scoped one.
test_egm1r2_stray_top_level_held_is_unknown() {
  local p
  egm1_setup r2-stray-held
  p="$R/state/autolaunch-steps.candidates"
  mkdir -p "$R/projects/proj"
  printf '## In flight\n## Queued\n- [ ] work - a ready item (repo: proj) (kind: scout)\n## Done\n' > "$R/data/backlog.md"
  egm1_entry "$R" work >/dev/null
  egm1r2_detail held-no > "$E/show.out"
  egm1r2_show_stub "$E/show.out"
  egm1_publish "$R" "$E/bin"
  jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
    fail "EGM1-R2 stray held baseline: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
  assert_equals allow "$(egm1r2_fact task)" 'EGM1-R2 stray held baseline: a scoped held: no task is published as allowed'
  egm1r2_detail held-also-outside > "$E/show.out"
  rm -f "$p"
  egm1_publish "$R" "$E/bin"
  jq -e '.schema == "fm-seat-candidates/v1"' "$p" >/dev/null 2>&1 ||
    fail "EGM1-R2 detail held-also-outside: --publish-candidates wrote no v1 publication (rc=$EGM1_PUB_RC; $(head -c 200 "$E/publish.out"))"
  assert_equals unknown "$(egm1r2_fact task)" 'EGM1-R2 detail held-also-outside: a held: yes outside the task: block leaves the hold unknown'
  [ "$(egm1r2_fact prep)" != allow ] ||
    fail 'EGM1-R2 detail held-also-outside: contradictory or unscoped task detail produced an allowing prep fact'
  pass 'EGM1-R2 test_egm1r2_stray_top_level_held_is_unknown: a hold field outside the task block never clears a hold'
}

egm1r2_run() {  # <case>... (egm1r2 = all)
  local name
  # shellcheck disable=SC2086 # one test name per word
  [ "$*" != egm1r2 ] || set -- $EGM1R2_TESTS
  for name in "$@"; do
    [ "$(type -t "$name")" = function ] || fail "unknown EGM1-R2 case $name"
    "$name"
  done
}
if [ -n "${FM_AUTOLAUNCH_EGM1R2_ONLY:-}" ]; then
  # shellcheck disable=SC2086 # one test name per word
  egm1r2_run $FM_AUTOLAUNCH_EGM1R2_ONLY
  exit 0
fi
# === END tester-owned EGM1-R2 (definitions; the full run calls egm1r2_run egm1r2 last) ===

# === BEGIN tester-owned: lc-core-scheduler EGM1-R3 unavailable-home oracles =
# EGM point 1 (instruction 009) "unavailable-home disposition" at the home
# enumeration boundary: a registered local home that cannot be enumerated
# (directory removed, or unreadable by permissions) keeps the other homes'
# membership and gets its own typed unavailable record, the same disposition
# a home with an unreadable publication already gets (round-1 G1).
# Expected results come from the cut line (EGM dispositions row 1: "a home that
# cannot run has no failure disposition"; "a negative control that drops an
# unreadable home and still returns success") and the cut-1 advisor answer
# ("Missing whole-home input still causes NO_PICK; a failed kick cannot
# justify dropping that home"), never from the code under test.
# Reuses the round-1 seam and fixtures (egm1_setup, egm1_pub, egm1_join,
# egm1_doc, egm1_unavailable) without editing them. Reason enums are the
# builder's; these cases pin only the states, identities and the presence of
# reason, owner and retry. The builder runs these and never edits this region.
# Run alone: FM_AUTOLAUNCH_EGM1R3_ONLY='<case>...' (or egm1r3 for all).
EGM1R3_TESTS=(test_egm1r3_removed_home_keeps_membership_and_typed_record
  test_egm1r3_unreadable_home_keeps_membership_and_typed_record
  test_egm1r3_readable_valid_empty_homes_are_complete)

egm1r3_status() {  # <home>: that home's homes[] statuses, comma-joined (one record gives one word)
  printf '%s\n' "$EGM1_OUT" | jq -r --arg h "$1" '[.homes[] | select(.home == $h) | .status] | join(",")'
}

egm1r3_no_pick_disposition() {  # <label>: assertions on the captured join after B was broken
  egm1_doc "$1"
  assert_equals NO_PICK "$(printf '%s\n' "$EGM1_OUT" | jq -r .status)" "$1: join status"
  [ "$EGM1_RC" != 0 ] && [ "$EGM1_RC" != 2 ] || fail "$1: NO_PICK must exit nonzero and not 2 (usage), got $EGM1_RC"
  # The unavailable home keeps its registered identity and a typed record.
  egm1_unavailable "$1" "$B"
  printf '%s\n' "$EGM1_OUT" | jq -e --arg h "$B" 'any(.reasons[]; .home == $h
    and (.owner | type == "string" and . != "") and (.retry | type == "string" and . != "")
    and (.reason | type == "string" and . != ""))' >/dev/null ||
    fail "$1: no typed reasons[] record names $B with a reason, an owner and a retry condition (reasons: $(printf '%s\n' "$EGM1_OUT" | jq -c .reasons | head -c 300))"
  # The readable home stays a member: the failure does not erase known membership.
  assert_equals available "$(egm1r3_status "$R")" "$1: the readable home $R is still listed once as available"
}

# A registered local home whose directory is gone.
test_egm1r3_removed_home_keeps_membership_and_typed_record() {
  egm1_setup r3-removed
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1-R3 removed baseline: both homes readable'
  mv "$B" "$E/b-gone"
  egm1_join
  mv "$E/b-gone" "$B"
  egm1r3_no_pick_disposition 'EGM1-R3 removed: B directory removed'
  pass 'EGM1-R3 test_egm1r3_removed_home_keeps_membership_and_typed_record: a removed registered home is NO_PICK, typed unavailable, and R stays a member'
}

# A registered local home whose directory cannot be read or entered.
test_egm1r3_unreadable_home_keeps_membership_and_typed_record() {
  egm1_setup r3-unreadable
  egm1_pub "$R" "[$(egm1_entry "$R" r-task)]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1-R3 unreadable baseline: both homes readable'
  chmod 000 "$B"
  if [ -r "$B" ] || [ -x "$B" ]; then
    chmod 755 "$B"
    printf 'skip: EGM1-R3 unreadable-home case needs a non-root user (mode 000 stays accessible)\n'
    return 0
  fi
  egm1_join
  chmod 755 "$B"
  egm1r3_no_pick_disposition 'EGM1-R3 unreadable: B directory mode 000'
  pass 'EGM1-R3 test_egm1r3_unreadable_home_keeps_membership_and_typed_record: an unreadable registered home is NO_PICK, typed unavailable, and R stays a member'
}

# Control: both homes readable and valid-empty.
test_egm1r3_readable_valid_empty_homes_are_complete() {
  egm1_setup r3-control
  egm1_pub "$R" "[]"
  egm1_pub "$B" "[]"
  egm1_complete 'EGM1-R3 control: both homes valid-empty'
  assert_equals available "$(egm1r3_status "$R")" 'EGM1-R3 control: R is listed once as available'
  assert_equals available "$(egm1r3_status "$B")" 'EGM1-R3 control: B is listed once as available'
  assert_equals 2 "$(printf '%s\n' "$EGM1_OUT" | jq '.homes | length')" 'EGM1-R3 control: exactly the two registered homes are listed'
  pass 'EGM1-R3 test_egm1r3_readable_valid_empty_homes_are_complete: two readable valid-empty homes are COMPLETE with both listed'
}

egm1r3_run() {  # <case>... (egm1r3 = all)
  local name
  [ "$*" != egm1r3 ] || set -- "${EGM1R3_TESTS[@]}"
  for name in "$@"; do
    [ "$(type -t "$name")" = function ] || fail "unknown EGM1-R3 case $name"
    "$name"
  done
}
if [ -n "${FM_AUTOLAUNCH_EGM1R3_ONLY:-}" ]; then
  read -r -a EGM1R3_ONLY <<<"$FM_AUTOLAUNCH_EGM1R3_ONLY"
  egm1r3_run "${EGM1R3_ONLY[@]}"
  exit 0
fi
# === END tester-owned EGM1-R3 (definitions; the full run calls egm1r3_run egm1r3 last) ===

# === BEGIN tester-owned: lc-core-scheduler K1-R1..K1-R12 oracles ==========
# Frozen plan LC-KUN-v26, section "K1 build-time requirements of
# fleet-ops:lc-core-scheduler". The builder runs these and never edits this
# region (or the R6 edit to the busy-lock block below); a disputed case goes
# back to the tester. Expected numbers are the plan's, never the code's:
# deadlines 600/300/60/120/900 s, stop grace 5 s, passes at most 55 s apart,
# step (1) bounded by `timeout -k 5 20`, bounds 75/130/165/255/310/315/680/735 s.
#
# Seams these cases fix for the build (all inert unless FM_TEST_SEAM=1):
#   FM_AUTOLAUNCH_NOW_FILE   fake clock: a file holding the epoch the pass
#                            reads for every time it uses (record stamps,
#                            deadlines, lock `at`, key ages).
#   FM_AUTOLAUNCH_SEND_BIN   replaces bin/fm-send.sh for responder hand-offs.
#                            Every send carries FM_SEND_REQUEST_ID (32
#                            lowercase hex), fm-send's one-way retry identity.
#   FM_AUTOLAUNCH_SPAWN_BIN, FM_AUTOLAUNCH_CAPACITY_BIN  (existing).
#   PATH stubs               systemd-run, systemctl, timeout, codex, claude:
#                            the pass resolves them from PATH. The fake
#                            `timeout` advances the clock by 20 s for every
#                            step (1) it runs (`-k 5 20`), the plan's worst
#                            case, and can cut one step (1) at TERM (exit 124,
#                            +20 s) or KILL (exit 137, +25 s); the same stub
#                            answers as `gnutimeout`. The fake
#                            `systemd-run` runs the command as the unit's main
#                            process; k1_tick plays systemd at each pass time:
#                            TERM to the main pid only at RuntimeMaxSec and
#                            KILL TimeoutStopSec later (KillMode=process).
#   Agent identity           a started agent is recorded as agent_root_pid,
#                            agent_root_start (/proc/<pid>/stat field 22) and
#                            boot_id lines in state/<task>.meta (the K2a
#                            identity fields).
# Run one case alone: FM_AUTOLAUNCH_TEST_ONLY='<test name>...' (or k1 for all).
K1_T0=1800000000
REAL_TIMEOUT=$(command -v timeout)
REAL_SLEEP=$(command -v sleep)
K1_TESTS=''

k1_setup() {  # <case> <mate|main>
  K1="$TMP_ROOT/k1-$1" H="$TMP_ROOT/k1-$1/home"
  KF="$K1/fake" KB="$K1/bin" LOG="$H/state/autolaunch.log"
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$KF/units" "$KB" "$K1/agent" "$K1/tmux"
  fm_test_tasks_toml "$H/.tasks.toml"
  K1_TEST_PID=$$
  export FM_HOME="$H" K1 KF KB REAL_TIMEOUT REAL_SLEEP ROOT K1_TEST_PID
  unset TMUX TMUX_PANE
  [ "$2" = main ] || printf 'k1-mate\n' > "$H/.fm-secondmate-home"
  printf '%s\n' "$K1_T0" > "$KF/clock"
  printf '1\n' > "$KF/free"
  printf 'ok\n' > "$KF/spawn-mode"
  ln -s "$K1_STANDIN" "$K1/agent/claude"
  k1_write_stubs
  export FM_AUTOLAUNCH_SPAWN_BIN="$KB/spawn" FM_AUTOLAUNCH_CAPACITY_BIN="$KB/capacity" \
    FM_AUTOLAUNCH_SEND_BIN="$KB/fm-send" TMUX_TMPDIR="$K1/tmux"
  : > "$KF/observe"
}

k1_write_stubs() {
  cat > "$KB/capacity" <<'SH'
#!/usr/bin/env bash
free=$(cat "$KF/free")
if [ "$free" -gt 0 ]; then printf 'capacity: free_lanes=%s reason=ok lanes=1 target=10\n' "$free"; exit 0; fi
printf 'capacity: free_lanes=0 reason=full lanes=10 target=10\n'; exit 75
SH
  # Spawn modes (fake/spawn-mode): ok, fail-unknown, hung (a child takes the
  # real spawn lock and lives on; the stub never returns), hung-child-exits,
  # hung-agent-first (starts the agent, then hangs). fake/agent-go-<id> makes
  # a hung child start the agent late.
  cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
id=$1
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
mode=$(cat "$KF/spawn-mode")
start_agent() {
  "$K1/agent/claude" 100000 </dev/null >/dev/null 2>&1 &
  apid=$!
  astart=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$apid/stat")
  printf 'agent_root_pid=%s\nagent_root_start=%s\nboot_id=%s\n' "$apid" "$astart" \
    "$(cat /proc/sys/kernel/random/boot_id)" >> "$FM_HOME/state/$id.meta"
  printf '%s\n' "$apid" > "$KF/agent-$id.pid"
}
case "$mode" in
  ok) printf 'spawned %s\n' "$id"; exit 0 ;;
  fail-unknown) echo "error: k1 unexpected internal fault 0x2a" >&2; exit 1 ;;
esac
[ "$mode" != hung-agent-first ] || start_agent
(
  STATE="$FM_HOME/state"; export STATE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.spawn-$id.lock" || exit 3
  printf '%s\n' "$BASHPID" > "$KF/holder-$id.pid"
  [ "$mode" != hung-child-exits ] || exit 0
  while [ ! -e "$KF/agent-go-$id" ]; do "$REAL_SLEEP" 0.2; done
  start_agent
  exec "$REAL_SLEEP" 100000
) </dev/null >/dev/null 2>&1 &
while [ ! -s "$KF/holder-$id.pid" ]; do "$REAL_SLEEP" 0.05; done
exec "$REAL_SLEEP" 100000
SH
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
# Fake systemd-run: records the call at the fake time and runs the command as
# the unit's main process (in its own session); never reaches real systemd.
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/systemd-run.log"
unit='' props=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -p|--property) props="$props $2"; shift 2 ;;
    --property=*) props="$props ${1#*=}"; shift ;;
    -p*) props="$props ${1#-p}"; shift ;;
    -u|--unit) unit=$2; shift 2 ;;
    --unit=*) unit=${1#*=}; shift ;;
    -E|--setenv|--description|--slice|--working-directory|-M|--machine|--uid|--gid|--nice|--service-type|-H|--host) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
max='' stop=''
for p in $props; do
  case "$p" in RuntimeMaxSec=*) max=${p#*=} ;; TimeoutStopSec=*) stop=${p#*=} ;; esac
done
n=$(( $(find "$KF/units" -type f | wc -l) + 1 ))
argv="$*"
cmd=("$@")
if [ -s "$KF/hang-match" ] && printf '%s\n' "$argv" | grep -qF -f "$KF/hang-match"; then
  cmd=("$REAL_SLEEP" 100000)
fi
if [ -e "$KF/ignore-term" ]; then
  setsid bash -c 'trap "" TERM; exec "$@"' k1-unit "${cmd[@]}" </dev/null >>"$KF/unit-$n.out" 2>&1 &
else
  setsid "${cmd[@]}" </dev/null >>"$KF/unit-$n.out" 2>&1 &
fi
pid=$!
printf 'unit=%s\npid=%s\nstart=%s\nmax=%s\nstop=%s\nargv=%s\n' \
  "${unit:-run-k1-$n}" "$pid" "$(cat "$KF/clock")" "$max" "$stop" "$argv" > "$KF/units/$n"
echo "Running as unit: ${unit:-run-k1-$n}.service" >&2
SH
  cat > "$KB/systemctl" <<'SH'
#!/usr/bin/env bash
# Fake systemctl --user over the fake units: show MainPID/ActiveState, is-active.
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/systemctl.log"
sub='' unit='' props='' value=0
for a in "$@"; do
  case "$a" in
    --user|--quiet|-q|--no-pager) ;;
    --value) value=1 ;;
    -p|--property) ;;
    --property=*) props="$props,${a#*=}" ;;
    MainPID*|ActiveState*|SubState*|ExecMainStartTimestamp*) props="$props,$a" ;;
    show|is-active|stop|kill|status) sub=$a ;;
    *) [ -n "$unit" ] || unit=${a%.service} ;;
  esac
done
rec=$(grep -lx "unit=$unit" "$KF"/units/* 2>/dev/null | head -1)
pid=0; state=inactive
if [ -n "$rec" ]; then
  p=$(sed -n 's/^pid=//p' "$rec")
  st=$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$p/stat" 2>/dev/null) || st=
  if [ -n "$st" ] && [ "$st" != Z ]; then pid=$p; state=active; fi
fi
case "$sub" in
  is-active) echo "$state"; [ "$state" = active ] ;;
  show)
    for p in $(printf '%s' "${props#,}" | tr ',' ' '); do
      case "$p" in
        MainPID) v=$pid ;; ActiveState) v=$state ;; SubState) [ "$state" = active ] && v=running || v=dead ;; *) v= ;;
      esac
      if [ "$value" = 1 ]; then echo "$v"; else echo "$p=$v"; fi
    done ;;
  *) exit 0 ;;
esac
SH
  # Fake timeout: only the step-(1) signature `-k 5 20` is clock-managed.
  cat > "$KB/timeout" <<'SH'
#!/usr/bin/env bash
orig=("$@") kill='' dur=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill-after|-s|--signal) [ "$1" = -k ] || [ "$1" = --kill-after ] && kill=$2; shift 2 ;;
    --kill-after=*) kill=${1#*=}; shift ;;
    -k*) kill=${1#-k}; shift ;;
    --signal=*|-s*|--preserve-status|--foreground|-v|--verbose) shift ;;
    *) dur=$1; shift; break ;;
  esac
done
printf '%s\t%s\n' "$(cat "$KF/clock")" "${orig[*]}" >> "$KF/timeout.log"
if [ "${kill%s}" != 5 ] || [ "${dur%s}" != 20 ]; then exec "$REAL_TIMEOUT" "${orig[@]}"; fi
cut=$(head -1 "$KF/cut-step1" 2>/dev/null)
if [ -n "$cut" ]; then
  sed -i 1d "$KF/cut-step1"
  if [ "$cut" = kill ]; then echo $(( $(cat "$KF/clock") + 25 )) > "$KF/clock"; exit 137; fi
  echo $(( $(cat "$KF/clock") + 20 )) > "$KF/clock"; exit 124
fi
rc=0
"$REAL_TIMEOUT" "${orig[@]}" || rc=$?
echo $(( $(cat "$KF/clock") + 20 )) > "$KF/clock"
exit "$rc"
SH
  # Fake responder send (fm-send.sh). fake/send-mode lines, one per call:
  # fail (nothing accepted), crash (accepted, then the calling pass dies
  # before it can record a receipt), ok. Accepted identities: fake/accepted.
  cat > "$KB/fm-send" <<'SH'
#!/usr/bin/env bash
id=${FM_SEND_REQUEST_ID:-}
printf '%s\t%s\t%s\n' "$(cat "$KF/clock")" "$*" "$id" >> "$KF/send.log"
[[ "$id" =~ ^[0-9a-f]{32}$ ]] || exit 2
mode=$(head -1 "$KF/send-mode" 2>/dev/null); [ -z "$mode" ] || sed -i 1d "$KF/send-mode"
case "${mode:-ok}" in
  fail) echo 'error: k1 enqueue failed' >&2; exit 1 ;;
  hang) exec "$REAL_SLEEP" 100000 ;;
esac
. "$ROOT/bin/fm-task-inbox-lib.sh"
fm_task_inbox_write_idempotent "$KF/delivery-state" fleet-ops "$*" '' "$id" >/dev/null || exit 1
grep -qx "$id" "$KF/accepted" 2>/dev/null || printf '%s\n' "$id" >> "$KF/accepted"
if [ "$mode" = crash ]; then
  p=$PPID
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$p" != "$K1_TEST_PID" ]; do
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in */bin/fm-autolaunch.sh*) kill -KILL "$p" 2>/dev/null ;; esac
    p=$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$p/stat" 2>/dev/null)
  done
fi
exit 0
SH
  # Diagnosis stubs: fake/codex-mode hang keeps rung 3 running.
  cat > "$KB/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\tcodex %s\n' "$(cat "$KF/clock")" "$*" >> "$KF/diag.log"
[ "$(cat "$KF/codex-mode" 2>/dev/null)" != hang ] || exec "$REAL_SLEEP" 100000
echo 'k1 rung-3 advice'
SH
  cat > "$KB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\tclaude %s\n' "$(cat "$KF/clock")" "$*" >> "$KF/diag.log"
echo 'k1 rung-4 advice'
SH
  cp "$KB/timeout" "$KB/gnutimeout"
  chmod +x "$KB"/*
}

k1_now() { cat "$KF/clock"; }
k1_alive() {  # <pid>: running and not a zombie
  local st
  [ -n "$1" ] && st=$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$1/stat" 2>/dev/null) && [ -n "$st" ] && [ "$st" != Z ]
}
k1_unit_field() { sed -n "s/^$2=//p" "$1"; }

# Play systemd at the current fake time for every fake unit.
k1_tick() {
  local now rec pid start max stop i
  now=$(k1_now)
  for rec in "$KF"/units/*; do
    [ -f "$rec" ] || continue
    pid=$(k1_unit_field "$rec" pid) start=$(k1_unit_field "$rec" start)
    max=$(k1_unit_field "$rec" max) stop=$(k1_unit_field "$rec" stop)
    case "$max" in ''|*[!0-9]*) continue ;; esac
    case "$stop" in ''|*[!0-9]*) stop=90 ;; esac
    k1_alive "$pid" || continue
    [ "$now" -ge $((start + max)) ] || continue
    if [ -s "$KF/unkillable-match" ] && grep -qF -f "$KF/unkillable-match" "$rec"; then continue; fi
    grep -qx 'termed=1' "$rec" || { kill -TERM "$pid" 2>/dev/null; printf 'termed=1\n' >> "$rec"; }
    i=0; while k1_alive "$pid" && [ "$i" -lt 10 ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
    if k1_alive "$pid" && [ "$now" -ge $((start + max + stop)) ]; then
      kill -KILL "$pid" 2>/dev/null
      i=0; while k1_alive "$pid" && [ "$i" -lt 20 ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
    fi
  done
}

# One pass at fake time T0+<t>; term|kill cuts its step (1). A pass that
# blocks is ended after 30 real seconds and counts as red evidence.
k1_pass() {  # <t> [term|kill]
  local rc=0
  printf '%s\n' $((K1_T0 + $1)) > "$KF/clock"
  k1_tick
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$KF/cut-step1"
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    "$REAL_TIMEOUT" -k 2 30 bash "$AL" >> "$KF/pass.out" 2>&1 || rc=$?
  rm -f "$KF/cut-step1"
  printf '%s\t%s\n' "$1" "$rc" >> "$KF/pass-rc.log"

  k1_observe
}
k1_passes() {  # <from> <to>: timer passes 55 s apart
  local t=$1
  while [ "$t" -le "$2" ]; do k1_pass "$t"; t=$((t + 55)); done
}
k1_blocked_passes() { awk -F'\t' '$2 == 124 || $2 == 137 { n++ } END { print n + 0 }' "$KF/pass-rc.log"; }

# First fake time (clock after the pass) at which a condition held.
k1_watch() {  # <name> <condition evaluated with eval>
  printf '%s\t%s\n' "$1" "$2" >> "$KF/observe"
}
k1_observe() {
  local name cond
  while IFS=$'\t' read -r name cond; do
    [ -e "$KF/seen-$name" ] && continue
    if eval "$cond"; then k1_now > "$KF/seen-$name"; fi
  done < "$KF/observe"
}
k1_seen() { cat "$KF/seen-$1" 2>/dev/null; }
k1_within() {  # <name> <origin epoch> <bound s> <message>
  local at
  at=$(k1_seen "$1")
  [ -n "$at" ] || fail "$4: never observed"
  [ $((at - $2)) -le "$3" ] || fail "$4: observed $((at - $2)) s after its origin, bound $3 s"
}

k1_lines() {  # <file> <fixed string>...: lines of the file holding every string
  local f=$1 out s
  shift
  [ -f "$f" ] || return 0
  out=$(cat "$f")
  for s in "$@"; do out=$(printf '%s\n' "$out" | grep -F -- "$s" || true); done
  [ -z "$out" ] || printf '%s\n' "$out"
}
k1_count() { k1_lines "$@" | grep -c . || true; }
k1_owned() {  # <task>: the task's responder hand-offs (keyed blocked: ctl-... owned)
  k1_lines "$H/state/$1.status" blocked ctl- "$1" owned
}
k1_units() {  # <fixed string>...: fake systemd-run calls holding every string
  k1_lines "$KF/systemd-run.log" "$@"
}
k1_units_max() {  # <RuntimeMaxSec> <fixed string>...: matching calls with exactly that deadline
  local max=$1 l
  shift
  k1_units "$@" | while IFS= read -r l; do [ "$(k1_prop "$l" RuntimeMaxSec)" != "$max" ] || printf '%s\n' "$l"; done
}
k1_units_max_count() { k1_units_max "$@" | grep -c . || true; }
k1_units_max_start() {  # <n> <RuntimeMaxSec> <fixed string>...
  local n=$1
  shift
  k1_units_max "$@" | sed -n "${n}p" | cut -f1
}
k1_unit_start() {  # <n> <fixed string>...: fake start time of the n-th matching call
  local n=$1
  shift
  k1_units "$@" | sed -n "${n}p" | cut -f1
}
k1_slot_locks_free() {  # every slot lock under state/autolaunch-slots is free
  local f
  for f in "$H"/state/autolaunch-slots/*; do
    [ -e "$f" ] || continue
    flock -n "$f" true || return 1
  done
}
k1_slot_lock_held() {
  local f
  for f in "$H"/state/autolaunch-slots/*; do
    [ -e "$f" ] || continue
    flock -n "$f" true || return 0
  done
  return 1
}

k1_ready() {  # <id>...: prepared ready entries
  local id
  for id in "$@"; do printf -- '- [ ] %s - k1 fixture (repo: proj) (kind: ship)\n' "$id"; done | backlog
  for id in "$@"; do prep "$id" proj; done
}
k1_inbox_due() {  # <task>: a live task with one unacknowledged message past its grace
  printf 'window=sess:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$1" > "$H/state/$1.meta"
  ( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$H/state" "$1" "k1 steer for $1" >/dev/null ) \
    || fail "k1 fixture: inbox write for $1"
  find "$H/state/$1.inbox" -maxdepth 1 -name '*.msg' -exec touch -d '-1 hour' {} +
}
# shellcheck disable=SC2031 # $! is read in this shell, right after the background start
k1_pass_lock_holder() {  # a live holder of state/.autolaunch.lock from T0
  "$REAL_SLEEP" 100000 &
  K1_HOLDER=$!
  mkdir "$H/state/.autolaunch.lock"
  printf '%s\n' "$K1_HOLDER" > "$H/state/.autolaunch.lock/pid"
  printf '%s\n' "$K1_T0" > "$H/state/.autolaunch.lock/at"
}
k1_reap_env() {  # <K1 prefix>: kill every process whose environment holds K1=<prefix>...
  # Fixture helpers run the host sleep, whose argv does not name the case root,
  # so fm_test_reap_root_processes cannot see them; k1_setup exports K1 to them.
  local p pid e env
  for p in /proc/[0-9]*; do
    pid=${p#/proc/}
    [ "$pid" != "$$" ] && [ "$pid" != "$BASHPID" ] || continue
    mapfile -d '' -t env < "$p/environ" 2>/dev/null || continue
    for e in "${env[@]}"; do
      case $e in "K1=$1"*) kill -KILL "$pid" 2>/dev/null; break ;; esac
    done
  done
  return 0
}
k1_teardown() {
  local rec
  for rec in "$KF"/units/*; do [ -f "$rec" ] && kill -KILL "$(k1_unit_field "$rec" pid)" 2>/dev/null; done
  [ -z "${K1_HOLDER:-}" ] || kill -KILL "$K1_HOLDER" 2>/dev/null
  K1_HOLDER=
  k1_reap_env "$K1"
  fm_test_reap_root_processes "$K1"
}
k1_need_unit() {  # <message> <fixed string>...: fail unless a matching unit started
  local msg=$1
  shift
  [ -n "$(k1_units "$@")" ] || fail "$msg (no fake systemd-run call; $(k1_blocked_passes) pass(es) blocked past 30 s; spawn calls: $(grep -c . "$KF/spawn.log" 2>/dev/null || echo 0); last pass output: $(tail -2 "$KF/pass.out" 2>/dev/null | tr '\n\t' '  ')"
}

k1_prop() { printf '%s\n' "$1" | grep -o "$2=[0-9]*" | head -1 | cut -d= -f2; }
k1_evidence_has() {  # <hand-off line> <fixed string>: the line or the evidence file it names holds it
  local line=$1 want=$2 path
  printf '%s\n' "$line" | grep -qwF -- "$want" && return 0
  path=$(printf '%s\n' "$line" | sed -n 's/.* owned \([^ ]*\).*/\1/p')
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) path="$H/$path" ;; esac
  grep -qwF -- "$want" "$path" 2>/dev/null
}
k1_main_of() {  # <fixed string>: main pid of the first fake unit whose call holds it
  local rec
  rec=$(grep -lF -- "$1" "$KF"/units/* 2>/dev/null | head -1)
  [ -n "$rec" ] && k1_unit_field "$rec" pid
}
k1_wait_file() {  # <file>: up to 5 real seconds
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do "$REAL_SLEEP" 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}
k1_live_units() {  # <RuntimeMaxSec>: fake units of that deadline whose main still runs
  local rec n=0
  for rec in "$KF"/units/*; do
    [ -f "$rec" ] && [ "$(k1_unit_field "$rec" max)" = "$1" ] || continue
    k1_alive "$(k1_unit_field "$rec" pid)" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
k1_teardown_all() {
  local rec
  for rec in "$TMP_ROOT"/k1-*/fake/units/*; do [ -f "$rec" ] && kill -KILL "$(k1_unit_field "$rec" pid)" 2>/dev/null; done
  [ -z "${K1_HOLDER:-}" ] || kill -KILL "$K1_HOLDER" 2>/dev/null
  k1_reap_env "$TMP_ROOT/k1-"
  return 0
}

# K1-R1: every action is a transient unit with its kind's deadline.
test_actions_start_as_transient_units() {
  local c launch rering
  k1_setup r1-units mate
  k1_ready k1-launch
  k1_inbox_due k1-rering
  k1_pass 0
  k1_need_unit 'K1-R1: no due obligation started as a transient unit; the pass ran the launch itself' --user
  while IFS= read -r c; do
    for want in --user --collect KillMode=process TimeoutStopSec=5 fm-al- --run-action; do
      assert_contains "$c" "$want" "K1-R1: every action unit call carries $want"
    done
  done < <(cut -f2- "$KF/systemd-run.log")
  launch=$(k1_units k1-launch) rering=$(k1_units k1-rering)
  assert_equals 1 "$(printf '%s\n' "$launch" | grep -c .)" 'K1-R1: one unit for the claimed launch'
  assert_equals 600 "$(k1_prop "$launch" RuntimeMaxSec)" 'K1-R1: a launch unit has RuntimeMaxSec=600'
  assert_equals 1 "$(printf '%s\n' "$rering" | grep -c .)" 'K1-R1: one unit for the due re-ring'
  assert_equals 60 "$(k1_prop "$rering" RuntimeMaxSec)" 'K1-R1: a local re-ring unit has RuntimeMaxSec=60'
  assert_equals 2 "$(grep -c . "$KF/systemd-run.log")" 'K1-R1: one unit call per due obligation'
  k1_teardown
  pass 'K1-R1 test_actions_start_as_transient_units: one unit per due obligation, 600 s launch, 60 s re-ring, TimeoutStopSec=5'
}

# K1-R1/R3/R4: a hung launch (stub fm-spawn never returns; its child keeps the
# real spawn lock). Variants: base, term-ignored, recording-cut, child-exited,
# late-start, agent-first.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_hung_launch() {  # <case> <variant>
  local variant=$2 start main holder t cut_done=0 line bound=680 last req
  k1_setup "$1" mate
  case "$variant" in
    child-exited) printf 'hung-child-exits\n' > "$KF/spawn-mode" ;;
    agent-first) printf 'hung-agent-first\n' > "$KF/spawn-mode" ;;
    *) printf 'hung\n' > "$KF/spawn-mode" ;;
  esac
  [ "$variant" != term-ignored ] || : > "$KF/ignore-term"
  [ "$variant" != recording-cut ] || bound=735
  k1_ready k1-hung
  k1_pass 0
  case "$variant" in
    base) req='K1-R1 (base): the never-returning launch has no transient unit and no deadline; it stays attempted and holds its slot for ever' ;;
    term-ignored|recording-cut) req="K1-R4 ($variant): no hand-off bound exists; the never-returning launch has no deadline, so no hand-off ever comes by 680 or 735 s" ;;
    *) req="K1-R3 ($variant): no hand-off; the never-returning launch has no deadline, so no timeout, spawn-lock read or owned record ever happens" ;;
  esac
  k1_need_unit "$req" k1-hung
  line=$(k1_units k1-hung | head -1)
  assert_equals 600 "$(k1_prop "$line" RuntimeMaxSec)" "K1-R1 ($variant): launch deadline RuntimeMaxSec=600"
  assert_equals 5 "$(k1_prop "$line" TimeoutStopSec)" "K1-R1 ($variant): stop grace TimeoutStopSec=5"
  start=$(k1_unit_start 1 k1-hung)
  main=$(k1_main_of k1-hung)
  k1_wait_file "$KF/holder-k1-hung.pid" || fail "K1-R1 ($variant): the launch unit never ran the spawn"
  holder=$(cat "$KF/holder-k1-hung.pid")
  k1_alive "$main" || fail "K1-R1 ($variant): the unit's main process ended before its deadline"
  k1_slot_lock_held || fail "K1-R1 ($variant): the running action holds no slot lock under state/autolaunch-slots/"
  k1_watch owned '[ -n "$(k1_owned k1-hung)" ]'
  k1_watch launched '[ -n "$(k1_lines "$LOG" k1-hung launched)" ]'
  last=$((start - K1_T0 + bound + 165))
  t=55
  while [ "$t" -le "$last" ]; do
    if [ "$variant" = recording-cut ] && [ "$cut_done" = 0 ] && [ $((K1_T0 + t)) -ge $((start + 600)) ]; then
      k1_pass "$t" kill; cut_done=1
    else
      k1_pass "$t"
    fi
    if [ "$variant" = late-start ] && [ -n "$(k1_seen owned)" ]; then : > "$KF/agent-go-k1-hung"; fi
    t=$((t + 55))
  done
  ! k1_alive "$main" || fail "K1-R1 ($variant): the main process outlived deadline plus 5 s"
  k1_slot_locks_free || fail "K1-R1 ($variant): the slot lock is still held after the main process ended"
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-hung)" "K1-R3 ($variant): the loop never retries a timed-out launch"
  assert_equals 1 "$(k1_units_max_count 600 k1-hung)" "K1-R3 ($variant): no second launch unit"
  assert_absent "$KF/send.log" "K1-R3 ($variant): a mate-home task key is never sent through fm-send"
  if [ "$variant" = agent-first ]; then
    assert_equals 0 "$(k1_owned k1-hung | grep -c .)" 'K1-R3 (started before hang): a live agent means no owned record'
    [ -n "$(k1_seen launched)" ] || fail 'K1-R3 (started before hang): the pass never recorded launched for the live agent'
    k1_teardown; return 0
  fi
  [ -n "$(k1_lines "$LOG" k1-hung failed:timeout)" ] || fail "K1-R1 ($variant): no failed:timeout record after the main process was gone"
  assert_equals 1 "$(k1_owned k1-hung | grep -c .)" "K1-R3 ($variant): exactly one owned hand-off for the timed-out launch"
  k1_within owned "$start" "$bound" "K1-R4 ($variant): owned hand-off within $bound s of the launch unit start"
  line=$(k1_owned k1-hung)
  case "$variant" in
    child-exited)
      assert_absent "$H/state/.spawn-k1-hung.lock" 'K1-R3 (child exited): the spawn lock was taken and released' ;;
    *)
      k1_alive "$holder" || fail "K1-R3 ($variant): fixture holder died"
      k1_evidence_has "$line" "spawn_lock_holder=$holder" || fail "K1-R3 ($variant): the owned record does not name spawn_lock_holder=$holder: $line" ;;
  esac
  if [ "$variant" = recording-cut ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R4 (recording pass cut): the cut pass records pass killed=1'
    k1_evidence_has "$line" overrun=1 || [ -n "$(k1_lines "$LOG" k1-hung overrun=1)" ] \
      || fail 'K1-R4 (recording pass cut): the late hand-off is not marked overrun=1'
  fi
  if [ "$variant" = late-start ]; then
    [ -n "$(k1_seen launched)" ] || fail 'K1-R3 (late start): the late agent start was never recorded launched'
    assert_equals 1 "$(k1_count "$H/state/k1-hung.status" resolved launched-late)" 'K1-R3 (late start): the key closes resolved: launched-late'
  fi
  k1_teardown
}
test_hung_action_times_out_and_reaches_responder_once() {
  k1_hung_launch r1-hung base
  pass 'K1-R1/R3 test_hung_action_times_out_and_reaches_responder_once: deadline, free slot, failed:timeout, one owned spawn_lock_holder hand-off by 680 s'
}
test_hung_action_times_out_and_reaches_responder_once_term_ignored() {
  k1_hung_launch r4-term term-ignored
  pass 'K1-R4 term-ignored main: gone by the KILL, hand-off by 680 s'
}
test_hung_action_times_out_and_reaches_responder_once_recording_pass_cut() {
  k1_hung_launch r4-cut recording-cut
  pass 'K1-R4 recording pass cut: pass killed=1, hand-off by 735 s marked overrun=1'
}
test_hung_action_times_out_and_reaches_responder_once_child_exited() {
  k1_hung_launch r3-exited child-exited
  pass 'K1-R3 child exited: lock taken and released, one owned hand-off'
}
test_hung_action_times_out_and_reaches_responder_once_late_start() {
  k1_hung_launch r3-late late-start
  pass 'K1-R3 late start: one launch, launched, resolved: launched-late'
}
test_hung_action_times_out_and_reaches_responder_once_started_before_hang() {
  k1_hung_launch r3-first agent-first
  pass 'K1-R3 started before hang: launched, no owned record'
}

# K1-R2: a hung delivery is an ordinary failed attempt; rungs 1 and 2, then
# one owned record; an unrelated re-ring due meanwhile runs on time.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_hung_action_times_out_and_reaches_responder_once_delivery() {
  local t rung2 other_due=''
  k1_setup r2-delivery mate
  k1_inbox_due k1-dlv
  printf 'k1-dlv\n' > "$KF/hang-match"
  k1_pass 0
  k1_need_unit 'K1-R2 (delivery): the due re-ring never became a 60 s unit, so a hang has no timeout path' k1-dlv
  assert_equals 60 "$(k1_prop "$(k1_units k1-dlv | head -1)" RuntimeMaxSec)" 'K1-R2 (delivery): re-ring deadline 60 s'
  k1_watch owned '[ -n "$(k1_owned k1-dlv)" ]'
  t=55
  while [ "$t" -le 1100 ]; do
    if [ "$t" = 165 ]; then k1_inbox_due k1-other; other_due=$((K1_T0 + t)); fi
    k1_pass "$t"
    if [ "$t" = 165 ]; then
      [ -n "$(k1_units k1-other)" ] || fail 'K1-R2 (delivery): the unrelated re-ring due at 165 s did not start on that pass'
      [ "$(k1_unit_start 1 k1-other)" -le $((other_due + 20)) ] || fail 'K1-R2 (delivery): the unrelated re-ring started late'
    fi
    t=$((t + 55))
  done
  [ -n "$(k1_lines "$LOG" k1-dlv failed:timeout)" ] || fail 'K1-R2 (delivery): the timed-out delivery was never recorded failed:timeout'
  assert_equals 3 "$(k1_units_max_count 60 k1-dlv)" 'K1-R2 (delivery): attempt, rung 1 and rung 2, then no more delivery units'
  assert_equals 1 "$(k1_owned k1-dlv | grep -c .)" 'K1-R2 (delivery): one owned record at the failed rung 2'
  rung2=$(k1_units_max_start 3 60 k1-dlv)
  k1_within owned $((rung2 + 60 + 5)) 75 'K1-R2/R7 (delivery): responder within 75 s of the failed rung 2'
  k1_teardown
  pass 'K1-R2 delivery variant: rungs 1-2 on timeout, one owned record, unrelated re-ring on time'
}

# K1-R2: a timed-out diagnosis records diagnosis=failed:timeout and the next
# rung, with no new owned record.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_hung_action_times_out_and_reaches_responder_once_diagnosis() {
  local diag_unit
  k1_setup r2-diag mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  printf 'hang\n' > "$KF/codex-mode"
  k1_ready k1-dx
  k1_watch owned '[ -n "$(k1_owned k1-dx)" ]'
  k1_passes 0 1925
  assert_equals 1 "$(k1_owned k1-dx | grep -c .)" 'K1-R2 (diagnosis): an unknown failure is handed to the responder once (no ladder today)'
  diag_unit=$(k1_units_max 900 --user | head -1)
  [ -n "$diag_unit" ] || fail 'K1-R1/R2 (diagnosis): rung 3 never ran as a 900 s unit'
  grep -q 'codex' "$KF/diag.log" 2>/dev/null || fail 'K1-R2 (diagnosis): rung 3 never called the diagnosis command'
  { grep -rqsF 'diagnosis=failed:timeout' "$LOG" "$H/state/autolaunch-diag"; } \
    || fail 'K1-R2 (diagnosis): the timed-out rung 3 is not recorded diagnosis=failed:timeout'
  grep -q 'claude' "$KF/diag.log" 2>/dev/null || fail 'K1-R2 (diagnosis): the key did not move to rung 4 after the timeout'
  assert_equals 1 "$(k1_owned k1-dx | grep -c .)" 'K1-R2 (diagnosis): the diagnosis timeout adds no owned record'
  k1_teardown
  pass 'K1-R2 diagnosis variant: 900 s rung-3 unit, diagnosis=failed:timeout, rung 4, no new owned record'
}

# K1-R5: a dropped event is repaired by 130 s through a killed pass.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_dropped_event() {  # <case> <cut: term|none> <bound>
  k1_setup "$1" mate
  k1_ready k1-ev
  printf '0\n' > "$KF/free"
  k1_pass 0
  printf '1\n' > "$KF/free"   # an agent exits; its pane event is dropped (no kick)
  # Repaired = the freed seat's launch is under way: its unit call (written by
  # the pass itself) or, in-process, its spawn call.
  k1_watch repaired '[ -n "$(k1_units k1-ev)$(k1_lines "$KF/spawn.log" k1-ev)" ]'
  if [ "$2" = term ]; then k1_pass 55 term; else k1_pass 55; fi
  k1_pass 110
  if [ "$2" = term ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R5: the cut pass records pass killed=1 (today a cut pass leaves no record)'
    [ -n "$(k1_lines "$LOG" k1-ev overrun=1)" ] || fail 'K1-R5: the late repair sample is not marked overrun=1'
  fi
  k1_within repaired "$K1_T0" "$3" "K1-R5: dropped event repaired within $3 s"
  k1_teardown
}
test_dropped_event_repaired_after_killed_pass() {
  k1_dropped_event r5-cut term 130
  pass 'K1-R5 test_dropped_event_repaired_after_killed_pass: pass killed=1, repaired by 130 s, overrun=1'
}
test_dropped_event_repaired_after_killed_pass_step_completes() {
  k1_dropped_event r5-whole none 75
  pass 'K1-R5 (K2c case) dropped event repaired within 75 s when step (1) completes'
}

# K1-R6: a never-releasing live holder of .autolaunch.lock.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_persistent_pass_lock_holder_opens_one_responder_key() {
  local explain key
  k1_setup r6-lock mate
  k1_ready k1-wait
  k1_inbox_due k1-rr
  k1_pass_lock_holder
  k1_watch key '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" ]'
  k1_pass 55
  assert_equals 1 "$(k1_count "$LOG" overrun "holder=$K1_HOLDER held_s=")" 'K1-R6: a busy pass writes one overrun holder=<pid> held_s=<n> record (today it exits silently)'
  [ -n "$(k1_units k1-rr)" ] || fail 'K1-R6: the due re-ring was not started in step (2) behind the busy lock'
  k1_pass 110; k1_pass 165; k1_pass 220
  assert_equals 4 "$(k1_count "$LOG" overrun "holder=$K1_HOLDER held_s=")" 'K1-R6: one overrun record per busy pass'
  k1_within key "$K1_T0" 165 'K1-R6: ctl-e-pass-lock key within 165 s of the hold starting'
  key=$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)
  assert_equals 1 "$(printf '%s\n' "$key" | grep -c .)" 'K1-R6: exactly one key for one persistent holder'
  k1_evidence_has "$key" "$K1_HOLDER" || fail "K1-R6: the key does not name the holder pid: $key"
  explain=$(FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" bash "$AL" --explain 2>&1)
  printf '%s\n' "$explain" | grep -F k1-wait | grep -qF pass-lock-held || fail "K1-R6: --explain does not list k1-wait as pass-lock-held: $explain"
  assert_absent "$KF/spawn.log" 'K1-R6: the prepared entry is never launched while the lock is held'
  assert_equals "$K1_HOLDER" "$(cat "$H/state/.autolaunch.lock/pid")" 'K1-R6: the live holder lock is never taken'
  k1_alive "$K1_HOLDER" || fail 'K1-R6: the live holder was killed'
  kill -KILL "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null; K1_HOLDER=
  k1_pass 275
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'K1-R6: the key closes on the first pass that acquires the lock'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'K1-R6: no second key'
  k1_teardown
  pass 'K1-R6 test_persistent_pass_lock_holder_opens_one_responder_key: overrun per pass, re-ring on time, pass-lock-held, one key by 165 s, closed after release'
}

# K1-R7: unknown failure ladder bound, then the queued-diagnosis skip bound.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_unknown_failure_escalation_is_bounded() {
  local rung2
  k1_setup r7-unknown mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  k1_ready k1-unk
  k1_watch owned '[ -n "$(k1_owned k1-unk)" ]'
  k1_watch diag '[ -s "$KF/diag.log" ]'
  k1_passes 0 1210
  assert_equals 1 "$(k1_owned k1-unk | grep -c .)" 'K1-R7: an unknown failure reaches one responder record after its failed rung 2 (today: a refused record every pass)'
  assert_equals 2 "$(k1_count "$LOG" k1-unk retry)" 'K1-R7: two deterministic retries (rungs 1-2)'
  assert_equals 3 "$(k1_units_max_count 600 k1-unk)" 'K1-R7: attempt plus two retries'
  rung2=$(k1_units_max_start 3 600 k1-unk)
  k1_within owned "$rung2" 75 'K1-R7: responder record within 75 s of the failed rung 2'
  [ -n "$(k1_seen diag)" ] || fail 'K1-R7: no diagnosis call after the hand-off'
  [ "$(k1_seen owned)" -le "$(k1_seen diag)" ] || fail 'K1-R7: ownership waited for a diagnosis call'
  grep -F codex "$KF/diag.log" | grep -qF gpt-6.1-sol || fail 'K1-R7: rung 3 is not the gpt-6.1-sol call'
  grep -F claude "$KF/diag.log" | grep -qF claude-opus-5-5 || fail 'K1-R7: rung 4 is not the claude-opus-5-5 call'
  assert_equals 1 "$(k1_count "$LOG" k1-unk exhausted)" 'K1-R7: one exhausted record'
  assert_equals 1 "$(k1_owned k1-unk | grep -c .)" 'K1-R7: no second responder record'
  k1_teardown
  pass 'K1-R7 test_unknown_failure_escalation_is_bounded: 2 retries, responder within 75 s of failed rung 2, rungs 3-5 after'
}
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_unknown_failure_escalation_is_bounded_ten_keys() {
  local i id ids='' queued=0
  k1_setup r7-ten mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  printf 'hang\n' > "$KF/codex-mode"
  printf '10\n' > "$KF/free"
  for i in 01 02 03 04 05 06 07 08 09 10; do ids="$ids k1-u$i"; done  # no id is a substring of another
  # shellcheck disable=SC2086 # one id per word
  k1_ready $ids
  for id in $ids; do
    k1_watch "owned-$id" "[ -n \"\$(k1_owned $id)\" ]"
    k1_watch "queued-$id" "[ -n \"\$(k1_lines \"\$LOG\" $id diagnose-queued)\" ]"
    k1_watch "skipped-$id" "grep -lsF skipped-capacity \"\$H\"/state/autolaunch-diag/*$id*summary* >/dev/null"
  done
  k1_watch two-diag '[ "$(k1_live_units 900)" -gt 1 ]'
  k1_passes 0 1485
  for id in $ids; do
    assert_equals 1 "$(k1_owned "$id" | grep -c .)" "K1-R7 (ten keys): $id has exactly one responder record (today: none)"
    k1_within "owned-$id" "$(k1_units_max_start 3 600 "$id")" 75 "K1-R7 (ten keys): $id responder within 75 s of its failed rung 2"
    if [ -n "$(k1_seen "queued-$id")" ]; then
      queued=$((queued + 1))
      k1_within "skipped-$id" "$(k1_seen "queued-$id")" 315 "K1-R7 (ten keys): queued $id gets diagnosis=skipped-capacity within 315 s"
    fi
  done
  [ "$queued" -ge 9 ] || fail "K1-R7 (ten keys): with one diagnosis running, nine keys must wait as diagnose-queued; saw $queued"
  [ -z "$(k1_seen two-diag)" ] || fail 'K1-R7 (ten keys): two diagnosis calls ran at once'
  k1_teardown
  pass 'K1-R7 ten keys: every responder within 75 s, every queued key skipped-capacity within 315 s'
}

# K1-R8: every step (1) cut under a new pass PID.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_repeated_cut_passes_reach_responder() {
  local t
  k1_setup r8-cuts mate
  k1_ready k1-int
  k1_inbox_due k1-rr8
  k1_watch incident '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-)" ]'
  for t in 0 55 110 165 220 275; do k1_pass "$t" kill; done
  [ -n "$(k1_seen incident)" ] || fail 'K1-R8: six consecutive cut passes reached no technical responder'
  k1_within incident "$K1_T0" 165 'K1-R8: repeated cut passes reach the responder within 165 s (tester-chosen bound, see report)'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-)" 'K1-R8: exactly one incident'
  assert_equals 6 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R8: every cut pass records pass killed=1'
  [ -n "$(k1_units k1-rr8)" ] || fail 'K1-R8: the unrelated re-ring did not continue'
  assert_absent "$KF/spawn.log" 'K1-R8: interrupted work is not launched'
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" resolved)" 'K1-R8: interrupted work stays unresolved'
  k1_teardown
  pass 'K1-R8 test_repeated_cut_passes_reach_responder: one incident within 165 s, re-rings continue, work unresolved'
}

# K1-R9: the unit's main process survives KILL.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_action_alive_after_kill_deadline() {
  local start main
  k1_setup r9-alive mate
  printf 'hung\n' > "$KF/spawn-mode"
  printf 'k1-stuck\n' > "$KF/unkillable-match"
  k1_ready k1-stuck
  k1_pass 0
  k1_need_unit 'K1-R9: the action has no unit or deadline, so it stays attempted for ever' k1-stuck
  start=$(k1_unit_start 1 k1-stuck)
  main=$(k1_main_of k1-stuck)
  k1_watch owned '[ -n "$(k1_owned k1-stuck)" ]'
  k1_passes 55 $((start - K1_T0 + 680 + 165))
  assert_equals 1 "$(k1_owned k1-stuck | grep -c .)" 'K1-R9: deadline plus grace expiry with a live main produces one responder hand-off'
  k1_within owned "$start" 680 'K1-R9: hand-off within 680 s of the unit start (tester-chosen: the R4 bound)'
  k1_alive "$main" || fail 'K1-R9: fixture main process died'
  k1_slot_lock_held || fail 'K1-R9: the live action no longer occupies its slot'
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-stuck)" 'K1-R9: no duplicate launch while the main lives'
  assert_equals 1 "$(k1_units_max_count 600 k1-stuck)" 'K1-R9: no second launch unit'
  k1_teardown
  pass 'K1-R9 test_action_alive_after_kill_deadline: one hand-off by 680 s, slot and identity kept, no duplicate launch'
}

# K1-R10: an event burst is not three 55 s observations.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_event_burst_does_not_escalate_normal_lock() {
  k1_setup r10-burst mate
  k1_ready k1-b
  k1_pass_lock_holder
  k1_pass 1; k1_pass 3; k1_pass 5
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" ctl-e-pass-lock-)" 'K1-R10: three rapid event passes escalated a lock held for 5 s'
  k1_watch key '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" ]'
  k1_passes 55 220
  k1_within key "$K1_T0" 165 'K1-R10: a genuinely persistent holder still reaches its responder within 165 s'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'K1-R10: one key'
  k1_teardown
  pass 'K1-R10 test_event_burst_does_not_escalate_normal_lock: no key on a burst, one key by 165 s when persistent'
}

# K1-R11: MAIN-home hand-off (no-task key -> fm-send fleet-ops --one-way).
test_responder_handoff_survives_failed_send_and_restart() {
  k1_setup r11-send main
  k1_pass_lock_holder
  printf 'fail\ncrash\n' > "$KF/send-mode"
  k1_passes 55 495
  [ -s "$KF/send.log" ] || fail 'K1-R11: no responder hand-off was ever sent for the persistent-lock key'
  assert_equals 0 "$(cut -f2 "$KF/send.log" | awk '$1 != "fleet-ops"' | grep -c . || true)" 'K1-R11: every hand-off goes to fleet-ops'
  assert_equals 0 "$(cut -f2 "$KF/send.log" | grep -vcF -- --one-way || true)" 'K1-R11: every hand-off is --one-way'
  [ "$(grep -c . "$KF/send.log")" -ge 3 ] || fail "K1-R11: the hand-off was not retried after the failed enqueue and the crash: $(cat "$KF/send.log")"
  assert_equals 1 "$(cut -f2- "$KF/send.log" | sort -u | grep -c .)" 'K1-R11: every retry carries the same identity'
  assert_equals 1 "$(grep -c . "$KF/accepted")" 'K1-R11: exactly one accepted hand-off'
  assert_equals 1 "$(cut -f3 "$KF/send.log" | sort -u | grep -Ec '^[0-9a-f]{32}$')" 'K1-R11: retries preserve the actual request identity'
  assert_equals 1 "$(find "$KF/delivery-state/fleet-ops.inbox" -name '*.msg' | wc -l | tr -d ' ')" 'K1-R11: the real enqueue boundary accepts one record'
  assert_equals 3 "$(grep -c . "$KF/send.log")" 'K1-R11: no send after the receipt is recorded'
  [ ! -s "$H/state/.wake-queue" ] || fail 'K1-R11: the hand-off woke MAIN'
  assert_equals '' "$(find "$H/state" -maxdepth 1 -name '*.status' -size +0)" 'K1-R11: a MAIN-home no-task key writes no status line'
  k1_teardown
  pass 'K1-R11 test_responder_handoff_survives_failed_send_and_restart: one accepted hand-off, same identity, no MAIN wake'
}

# K1-R7/R12: an unanswered technical decision key.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_unanswered() {  # <case> <cut pass t or none> <bound>
  local t line
  k1_setup "$1" mate
  printf 'window=sess:fm-k1-ask\nkind=ship\nharness=claude\nbackend=tmux\n' > "$H/state/k1-ask.meta"
  printf 'needs-decision [key=k1-tech] [at=%s]: pick the retry backoff for the flaky fetch\n' "$K1_T0" > "$H/state/k1-ask.status"
  : > "$H/config/open-decision-reminders"
  k1_watch ask '[ -n "$(k1_lines "$H/state/k1-ask.status" blocked ctl-c-ask-)" ]'
  t=0
  while [ "$t" -le 495 ]; do
    if [ "$t" = "$2" ]; then k1_pass "$t" term; else k1_pass "$t"; fi
    t=$((t + 55))
  done
  line=$(k1_lines "$H/state/k1-ask.status" blocked ctl-c-ask-)
  [ -n "$line" ] || fail 'K1-R12: the unanswered technical key never got a ctl-c-ask responder record (today: no owner)'
  assert_equals 1 "$(printf '%s\n' "$line" | grep -c .)" 'K1-R12: exactly one ctl-c-ask record, never repeated'
  assert_contains "$line" k1-tech 'K1-R12: the record names the key'
  assert_contains "$line" unanswered 'K1-R12: the record says unanswered'
  k1_within ask "$K1_T0" "$3" "K1-R12: responder owns the key within $3 s of opening"
  assert_absent "$KF/diag.log" 'K1-R12: no diagnosis call for a known case'
  assert_equals 0 "$(k1_count "$LOG" diagnose)" 'K1-R12: no diagnose record'
  assert_absent "$KF/send.log" 'K1-R12: a mate-home key is never sent through fm-send'
  if [ "$2" != none ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R12: the interrupted recording pass records pass killed=1'
    case "$line" in *overrun=1*) ;; *) [ -n "$(k1_lines "$LOG" ctl-c-ask- overrun=1)" ] || fail 'K1-R12: the hand-off after an interrupted pass is not marked overrun=1 (falsely on time)' ;; esac
  fi
  k1_teardown
}
test_unanswered_technical_key_goes_to_responder_without_diagnosis() {
  k1_unanswered r12-ask none 255
  pass 'K1-R7/R12 test_unanswered_technical_key_goes_to_responder_without_diagnosis: one ctl-c-ask within 255 s, no diagnosis'
}
test_unanswered_technical_key_goes_to_responder_without_diagnosis_interrupted() {
  k1_unanswered r12-cut 220 310
  pass 'K1-R12 interrupted recording pass: one ctl-c-ask within 310 s, overrun=1, no diagnosis'
}

K1_TESTS='test_actions_start_as_transient_units
test_hung_action_times_out_and_reaches_responder_once
test_hung_action_times_out_and_reaches_responder_once_delivery
test_hung_action_times_out_and_reaches_responder_once_diagnosis
test_hung_action_times_out_and_reaches_responder_once_child_exited
test_hung_action_times_out_and_reaches_responder_once_late_start
test_hung_action_times_out_and_reaches_responder_once_started_before_hang
test_hung_action_times_out_and_reaches_responder_once_term_ignored
test_hung_action_times_out_and_reaches_responder_once_recording_pass_cut
test_dropped_event_repaired_after_killed_pass
test_dropped_event_repaired_after_killed_pass_step_completes
test_persistent_pass_lock_holder_opens_one_responder_key
test_unknown_failure_escalation_is_bounded
test_unknown_failure_escalation_is_bounded_ten_keys
test_repeated_cut_passes_reach_responder
test_action_alive_after_kill_deadline
test_event_burst_does_not_escalate_normal_lock
test_responder_handoff_survives_failed_send_and_restart
test_unanswered_technical_key_goes_to_responder_without_diagnosis
test_unanswered_technical_key_goes_to_responder_without_diagnosis_interrupted'
k1_run() {  # <test name>... (k1 = all)
  local name tool
  if [ "$(uname -s)" != Linux ] || [ ! -r /proc/sys/kernel/random/boot_id ] || [ ! -r /proc/self/stat ]; then
    printf 'skip: K1 fixtures require Linux process identity\n'
    return 0
  fi
  for tool in timeout flock setsid; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf 'skip: K1 fixtures require %s\n' "$tool"
      return 0
    fi
  done
  K1_STANDIN=$(fm_agent_standin "$TMP_ROOT/k1-standin") || {
    printf 'skip: K1 fixtures require a working agent stand-in\n'
    return 0
  }
  trap 'k1_teardown_all; fm_test_cleanup' EXIT
  # shellcheck disable=SC2086 # one test name per word
  [ "$*" != k1 ] || set -- $K1_TESTS
  for name in "$@"; do
    [ "$(type -t "$name")" = function ] || fail "unknown K1 case $name"
    "$name"
  done
}
if [ -n "${FM_AUTOLAUNCH_TEST_ONLY:-}" ]; then
  # shellcheck disable=SC2086 # one test name per word
  k1_run $FM_AUTOLAUNCH_TEST_ONLY
  exit 0
fi
# === END tester-owned (definitions; the full run calls k1_run k1 below) ====

# --- x-prep persona, Doctor and XAI surface admission -------------------------
reset 2
mkdir -p "$H/projects/NOT_Q"
backlog <<'MD'
- [ ] persona-missing - standard screen (repo: NOT_Q) (kind: ship)
- [ ] doctor-missing - add an XAI tool (repo: NOT_Q) (kind: ship)
- [ ] surface-missing - changed system prompt (repo: NOT_Q) (kind: ship)
- [ ] valid-persona - complete full prep (repo: NOT_Q) (kind: ship)
- [ ] small-persona - small fix (repo: NOT_Q) (kind: ship)
- [ ] legacy-persona - legacy prep (repo: NOT_Q) (kind: ship)
MD
for id in persona-missing doctor-missing surface-missing valid-persona small-persona legacy-persona; do prep "$id" NOT_Q; done
printf '%s\n' 'DOCTOR: no Doctor change; because this changes only labels.' 'XAI-SURFACE: none; because labels only.' >> "$H/data/persona-missing/prep.md"
printf '%s\n' 'PERSONA: researcher new to X; see the same strategy evidence.; surfaces=chat; usage=beginner' 'SCOPE: openwebui/tools/new_tool.py' 'XAI-SURFACE: tool openwebui/tools/new_tool.py' >> "$H/data/doctor-missing/prep.md"
printf '%s\n' 'PERSONA: researcher familiar with X; observe unchanged factual evidence.; surfaces=pages; usage=experienced' 'DOCTOR: knowledge question for the changed prompt; expected evidence.' >> "$H/data/surface-missing/prep.md"
printf '%s\n' 'PERSONA: admin/owner familiar with X; grants unchanged; observe saved settings.; surfaces=pages; usage=experienced' 'DOCTOR: battery Read-settings; expected saved settings.' 'XAI-SURFACE: tool Read-settings' >> "$H/data/valid-persona/prep.md"
printf '%s\n' 'SLICE: main/labels; PERSONA: expert trader new to X; unchanged figures.; surfaces=chat; usage=beginner' 'PROOF: existing label check, unchanged factual outcome.' 'DOCTOR: no Doctor change; because this changes labels only.' 'XAI-SURFACE: none; because labels only.' > "$H/data/small-persona/prep.md"
# Fixed introduction date: 2026-11-03 Pacific midnight, not the filing date.
python3 - "$H" <<'PY'
import os, sys
from pathlib import Path
h = Path(sys.argv[1])
for name in ('persona-missing', 'doctor-missing', 'surface-missing', 'valid-persona', 'small-persona'):
    os.utime(h / 'data' / name / 'prep.md', (1793692800, 1793692800))
os.utime(h / 'data/legacy-persona/prep.md', (1793692799, 1793692799))
PY
list=$(bash "$AL" --list-prepared 2>&1)
assert_equals $'valid-persona\nsmall-persona\nlegacy-persona' "$list" 'new X preps require PERSONA, DOCTOR and XAI-SURFACE; pre-cutoff prep has dated grace'
bash "$AL" >/dev/null 2>&1
for pair in persona-missing:PERSONA doctor-missing:DOCTOR surface-missing:XAI-SURFACE; do
  id=${pair%:*} label=${pair#*:}
  assert_contains "$(cat "$LOG")" "$id"$'\t-\trefused:not prepared: '"$label missing" "missing $label refusal is actionable"
  assert_not_contains "$(cat "$FAKE/spawn.log")" "$id " "missing $label never reaches spawn"
done
assert_contains "$(cat "$FAKE/spawn.log")" 'valid-persona ' 'complete full prep reaches spawn'
assert_contains "$(cat "$FAKE/spawn.log")" 'small-persona ' 'small fix uses persona in SLICE'
printf '%s\n' 'PERSONA: tester/debugger familiar with X; reproduce the same visible result.; surfaces=pages; usage=experienced' >> "$H/data/persona-missing/prep.md"
printf '%s\n' 'DOCTOR: knowledge question for the new tool; expected invocation and refusal.' >> "$H/data/doctor-missing/prep.md"
printf '%s\n' 'XAI-SURFACE: system prompt openwebui/system-prompt.md' >> "$H/data/surface-missing/prep.md"
assert_equals $'persona-missing\ndoctor-missing\nsurface-missing\nvalid-persona\nsmall-persona\nlegacy-persona' "$(bash "$AL" --list-prepared)" 'adding the missing lines admits the same tasks'
touch "$H/data/legacy-persona/prep.md"
assert_not_contains "$(bash "$AL" --list-prepared)" 'legacy-persona' 'revised legacy prep loses grace'

# One complete task, then one malformed declaration at a time, at the CLI seam.
for invalid in persona-empty doctor-empty surface-empty persona-template doctor-reason surface-reason fenced; do
  reset 1
  printf '%s\n' '- [ ] malformed - X prep (repo: NOT_Q) (kind: ship)' | backlog
  prep malformed NOT_Q
  persona='PERSONA: researcher new to X; see the same evidence.; surfaces=chat; usage=beginner'
  doctor='DOCTOR: no Doctor change; because labels only.'
  surface='XAI-SURFACE: none; because labels only.'
  case "$invalid" in
    persona-empty) persona='PERSONA:   ' ;;
    doctor-empty) doctor='DOCTOR:   ' ;;
    surface-empty) surface='XAI-SURFACE:   ' ;;
    persona-template) persona='PERSONA: job/outcome; market expertise; familiarity with X and its terms; explanation preference; desired automation; access principal/grants; starting profile/card state; observable success.' ;;
    doctor-reason) doctor='DOCTOR: no Doctor change; because' ;;
    surface-reason) surface='XAI-SURFACE: none' ;;
  esac
  if [ "$invalid" = fenced ]; then
    printf '%s\n' '```' "$persona" "$doctor" "$surface" '```' > "$H/data/malformed/prep.md"
  else
    printf '%s\n' "$persona" "$doctor" "$surface" > "$H/data/malformed/prep.md"
  fi
  assert_equals '' "$(bash "$AL" --list-prepared)" "$invalid cannot satisfy admission"
done
printf '%s\n' '**PERSONA:** researcher new to X; surfaces=chat; usage=beginner' '**DOCTOR:** no Doctor change; because labels only.' '**XAI-SURFACE:** none; because labels only.' > "$H/data/malformed/prep.md"
assert_equals 'malformed' "$(bash "$AL" --list-prepared)" 'real Markdown fields count'
# The brief cannot supply a line missing from the selected linked prep.
printf '%s\n' 'PERSONA: example; surfaces=pages; usage=experienced' 'DOCTOR: battery example' 'XAI-SURFACE: tool example' >> "$H/data/malformed/brief.md"
mkdir -p "$H/data/shared-prep"
printf '%s\n' 'PERSONA: researcher new to X; surfaces=chat; usage=beginner' 'DOCTOR: battery Read-settings' > "$H/data/shared-prep/prep.md"
rm "$H/data/malformed/prep.md"
printf '%s\n' '- [ ] malformed - X prep (repo: NOT_Q) (kind: ship)' '  Prep: data/shared-prep/prep.md' | backlog
assert_equals '' "$(bash "$AL" --list-prepared)" 'linked prep must carry its own XAI-SURFACE'
printf '%s\n' 'XAI-SURFACE: tool Read-settings' >> "$H/data/shared-prep/prep.md"
assert_equals 'malformed' "$(bash "$AL" --list-prepared)" 'correcting the linked prep admits it'
# Page+chat outcome: neither middle-only nor either endpoint alone suffices.
reset 1
printf '%s\n' '- [ ] dual-channel - same outcome on page and chat (repo: NOT_Q) (kind: ship)' | backlog
prep dual-channel NOT_Q
for usage in middle beginner experienced; do
  printf '%s\n' "PERSONA: researcher; surfaces=pages,chat; usage=$usage; same factual outcome." 'DOCTOR: battery Read-settings; expected unchanged settings.' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals '' "$(bash "$AL" --list-prepared)" "page+chat prep with $usage only misses beginner/experienced coverage"
done
printf '%s\n' 'PERSONA: researcher; surfaces=pages,chat; usage=beginner,experienced,middle; same task and facts.' 'DOCTOR: battery Read-settings; expected unchanged settings.' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
assert_equals 'dual-channel' "$(bash "$AL" --list-prepared)" 'beginner chat-first and experienced pages-only coverage admits the same dual-channel slice'
for declarations in \
  'surfaces=pages/chat; usage=middle' \
  'surfaces=pages+chat; usage=middle' \
  'surfaces=pages chat; usage=middle' \
  'surfaces=pages,chat/other; usage=beginner,experienced' \
  'surfaces=pages,chat; usage=beginner,experienced/other' \
  'surfaces=pages,chat; usage=beginner,experienced+middle' \
  'surfaces=pages,chat; usage=beginner,experienced middle' \
  'surfaces=pages,chat; usage=beginner,experienced2'; do
  printf '%s\n' "PERSONA: researcher; $declarations" 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals '' "$(bash "$AL" --list-prepared)" "malformed declaration is not prefix-admitted: $declarations"
done
for declarations in \
  'surfaces=pages; usage=experienced' \
  'surfaces=chat; usage=beginner' \
  'surfaces=pages,chat; usage=beginner,experienced' \
  'surfaces=none; usage=none'; do
  printf '%s\n' "PERSONA: researcher; $declarations; same factual outcome." 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals 'dual-channel' "$(bash "$AL" --list-prepared)" "complete declaration is admitted: $declarations"
done
# Missing declarations cannot silently classify a dual-channel slice as single-channel.
printf '%s\n' 'PERSONA: researcher; same outcome.' 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
assert_equals '' "$(bash "$AL" --list-prepared)" 'persona must name surfaces and usage styles'
pass 'X prep PERSONA/DOCTOR/XAI-SURFACE refusal, correction, small fix, Markdown, linked prep, dated grace and usage coverage'
[ "${1:-}" != --x-prep-only ] || exit 0

# --- launch and stale blocked-by -------------------------------------------
reset 2
backlog <<'MD'
- [ ] plain-1 - ordinary piece (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] plain-2 - second ordinary piece (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] after-done - waits on finished work blocked-by: old-done (repo: proj) (kind: ship) (since 2026-10-30)
MD
prep plain-1 proj; prep plain-2 proj; prep after-done proj
out=$(bash "$AL" 2>&1); rc=$?
expect_code 0 "$rc" 'launch pass'
[ "$(wc -l < "$LOG")" -eq 2 ] || fail "two free lanes give two records, got: $(cat "$LOG")"
first=$(sed -n 1p "$LOG"); second=$(sed -n 2p "$LOG")
assert_equals "1" "$(field "$first" 2)" 'first record names lane 1'
assert_equals "plain-1" "$(field "$first" 3)" 'first ready item launches first'
assert_equals "launched" "$(field "$first" 5)" 'first result'
assert_equals "static" "$(field "$first" 4)" 'no dispatch config: static crew harness'
assert_equals "plain-2" "$(field "$second" 3)" 'second ready item launches second'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" "plain-1 $H/projects/proj --mode direct-PR --yolo off" 'prep becomes spawn flags'
assert_not_contains "$(cat "$FAKE/spawn.log")" '--harness' 'no harness without dispatch config'
assert_equals $'plain-1\nplain-2\nafter-done' "$(bash "$AL" --list-prepared)" 'prepared listing preserves ready-queue order'
[ "$(grep -c . "$FAKE/spawn.log")" -eq 2 ] || fail 'spawn called once per free lane'
printf '%s\n' "$first" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	' || fail "record time is UTC ISO: $first"
assert_contains "$out" "$first" 'records are echoed on stdout'
pass 'free lanes launch in ready-queue order, one launched record per lane'

reset 1
printf '%s\n' "- [ ] after-done - waits on finished work blocked-by: old-done (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] after-live - waits on queued work blocked-by: other-q (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] other-q - unprepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep after-done proj; prep after-live proj
bash "$AL" >/dev/null 2>&1
assert_equals "after-done	-	launched" "$(cut -f3,4,5 "$LOG" | head -1 | sed 's/	static	/	-	/')" 'blocked-by on finished work is not blocked'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'after-live' 'blocked-by on queued work is never launched'
pass 'a blocked-by edge to finished work clears; one to queued work blocks'

# --- refusal reasons -------------------------------------------------------
reset 1
printf '%s\n' "- [ ] no-brief - nothing prepared (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] no-prep - brief only (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] bad-prep - wrong prep (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] held-item - held (repo: proj) (kind: ship) (since 2026-10-30) (hold: parked: off the slices) (hold-kind: external) (hold-until: 2026-12-01)" \
  "- [ ] deferred-item - already deferred (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
mkdir -p "$H/data/no-prep"; printf 'brief\n' > "$H/data/no-prep/brief.md"
prep bad-prep proj 'colour=blue'
prep held-item proj
prep deferred-item proj
mkdir -p "$H/state/spawn-deferred/queue"; printf 'schema=fm-deferred-spawn.v1\ntask=deferred-item\n' > "$H/state/spawn-deferred/queue/0001"
bash "$AL" >/dev/null 2>&1
results=$(cut -f3,5 "$LOG")
assert_contains "$results" 'no-brief	refused:not prepared: no brief data/no-brief/brief.md' 'no brief'
assert_contains "$results" 'no-prep	refused:not prepared: no prep file (data/no-prep/prep.md or a Prep: data/<path> line in the item)' 'no prep file'
assert_contains "$results" 'bad-prep	refused:not prepared: record has unknown key colour' 'invalid override record'
assert_contains "$results" 'deferred-item	refused:spawn deferred pending' 'deferred retry is not doubled'
assert_not_contains "$results" 'held-item' 'held item is never a candidate'
assert_contains "$(tail -1 "$LOG")" '1	-	-	refused:no prepared item' 'running out of items is one record'
[ ! -f "$FAKE/spawn.log" ] || fail "no refused item is spawned: $(cat "$FAKE/spawn.log")"
pass 'unprepared, held and already-deferred items refuse with their reason and never spawn'

reset 1
printf '%s\n' '- [ ] foo.bar - literal task (repo: proj) (kind: ship)' \
  '- [ ] exact - deferred task (repo: proj) (kind: ship)' | backlog
prep foo.bar proj; prep exact proj
mkdir -p "$H/state/spawn-deferred/queue"
printf 'task=foo-bar\n' > "$H/state/spawn-deferred/queue/other"
printf 'task=exact\n' > "$H/state/spawn-deferred/queue/exact"
assert_equals 'foo.bar' "$(bash "$AL" --list-prepared)" 'deferred queue identity uses literal whole lines'
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$FAKE/spawn.log")" 'foo.bar ' 'regex-like task id remains launchable'
rm -f "$LOG" "$FAKE/spawn.log"; echo 1 > "$FAKE/free"
printf 'task=foo.bar\n' > "$H/state/spawn-deferred/queue/other"
assert_equals '' "$(bash "$AL" --list-prepared)" 'exact deferred identities are excluded from the list'
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" $'foo.bar\t-\trefused:spawn deferred pending' 'exact deferred identity is refused'
assert_absent "$FAKE/spawn.log" 'exact deferred tasks never spawn'
pass 'deferred identity contract distinguishes foo.bar from foo-bar in listing and launching'

reset 1
printf '%s\n' '- [ ] recorded - prepared (repo: proj) (kind: ship)' | backlog
prep recorded proj
printf 'existing record\n' > "$LOG"
chmod 0400 "$LOG"
out=$(bash "$AL" 2>&1); rc=$?
chmod 0600 "$LOG"
expect_code 1 "$rc" 'an unwritable log refuses before dispatch'
assert_absent "$FAKE/spawn.log" 'no launch without an open record destination'
assert_equals 'existing record' "$(cat "$LOG")" 'unwritable log is preserved'
touch "$FAKE/rotate-log"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$H/state/autolaunch.previous.log")" $'recorded\tstatic\tlaunched' 'records retain the opened log descriptor across rename'
assert_absent "$LOG" 'launch recording does not reopen the log path'
pass 'launches require a writable record destination and retain it for recording'

reset 0
printf '%s\n' "- [ ] ready-1 - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep ready-1 proj
bash "$AL" >/dev/null 2>&1
assert_equals "-	-	-	refused:no capacity: full" "$(cut -f2- "$LOG")" 'no capacity is one record'
[ ! -f "$FAKE/spawn.log" ] || fail 'no spawn without capacity'
pass 'a machine without a free lane records one no-capacity refusal and spawns nothing'

reset 2
printf '%s\n' "- [ ] proj-busy - project full (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] broken - spawn fails (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] fine - launches (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep proj-busy proj; prep broken proj; prep fine proj
echo 75 > "$FAKE/rc-proj-busy"; echo 1 > "$FAKE/rc-broken"
bash "$AL" >/dev/null 2>&1
results=$(cut -f2,3,5 "$LOG")
assert_contains "$results" '1	proj-busy	refused:deferred: deferred: project capacity for proj is held' 'spawn deferral recorded'
assert_contains "$results" '1	broken	refused:spawn error: error: brief mismatch for broken (exit 1)' 'spawn error recorded'
assert_contains "$results" '1	fine	launched' 'a lane survives a project deferral'
assert_contains "$(tail -1 "$LOG")" '2	-	-	refused:no prepared item' 'second lane has no item'
pass 'spawn deferral and spawn errors are recorded and the lane moves to the next item'

# --- dispatch and quota ------------------------------------------------------
reset 1
printf '%s\n' "- [ ] routed - default profiles (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep routed proj
printf '{"default":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"claude","model":"opus","effort":"low"}]}\n' > "$H/config/crew-dispatch.json"
jq '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 5' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/requeue-quota.json"
echo codex > "$FAKE/quota-refuse"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/requeue-quota.json" bash "$AL" >/dev/null 2>&1
assert_equals $'claude:opus\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" 'quota refusal requeues on the next default profile'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex --model gpt-5.5 --effort high' 'highest spendPriority default tried first'
assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness claude --model opus --effort low' 'next default tried after quota refusal'
echo claude >> "$FAKE/quota-refuse"
rm -f "$LOG"; echo 1 > "$FAKE/free"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/requeue-quota.json" bash "$AL" >/dev/null 2>&1
assert_contains "$(head -1 "$LOG")" 'refused:quota: error: fm-spawn refuses explicit harness claude' 'all candidates exhausted is a quota refusal'
pass 'a quota refusal advances through ranked defaults and all refused records quota'

reset 1
printf '%s\n' '- [ ] deterministic - prepared work (repo: proj) (kind: ship)' | backlog
prep deterministic proj
printf '{"rules":[{"when":"prepared work","approval":"captain","use":{"harness":"grok"}}],"default":{"harness":"codex","effort":"high"}}\n' > "$H/config/crew-dispatch.json"
cat > "$FAKE/curl" <<'SH'
#!/usr/bin/env bash
printf 'network call\n' >> "$FAKE_DIR/network.log"
exit 7
SH
chmod +x "$FAKE/curl"
out=$(TYPESAFE_API_KEY=synthetic-unused-key PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1); rc=$?
expect_code 0 "$rc" 'deterministic dry-run'
assert_contains "$out" '--harness codex --effort high' 'dry-run uses only the default profile'
assert_absent "$LOG" 'deterministic dry-run writes no record'
for setting in invalid rank-only absent; do
  case "$setting" in
    invalid) printf 'typo\n' > "$H/config/quota-gate" ;;
    rank-only) printf 'rank-only\n' > "$H/config/quota-gate" ;;
    absent) rm "$H/config/quota-gate" ;;
  esac
  for _ in 1 2; do
    out=$(PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1); rc=$?
    expect_code 0 "$rc" "$setting dry-run failed: $out"
    assert_absent "$H/state/.quota-gate-invalid" 'dry-run must not create an invalid-value receipt'
    assert_absent "$LOG" 'dry-run must not write a launch record'
    if [ "$setting" = invalid ]; then
      assert_contains "$out" 'expected rank-only' 'every invalid dry-run must diagnose the setting'
    fi
  done
done
TYPESAFE_API_KEY=synthetic-unused-key PATH="$FAKE:$PATH" bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$FAKE/spawn.log")" '--harness codex --effort high' 'configured rules do not replace the default'
assert_absent "$FAKE/network.log" 'neither real nor dry passes call the model endpoint with a configured key'
rm "$FAKE/curl"
pass 'default-only dispatch ignores natural-language rules and makes no model request'

reset 1
printf '%s\n' '- [ ] no-default - prepared (repo: proj) (kind: ship)' | backlog
prep no-default proj
printf '{"rules":[{"when":"prepared","use":{"harness":"codex"}}]}\n' > "$H/config/crew-dispatch.json"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" 'refused:dispatch: no configured default' 'a configured file without defaults refuses'
assert_absent "$FAKE/spawn.log" 'configured rules alone never launch a static or rule profile'
pass 'static dispatch applies only when the dispatch file is absent'

reset 1
printf '%s\n' "- [ ] ranked - default array (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep ranked proj
printf '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"},{"harness":"grok"}]}\n' > "$H/config/crew-dispatch.json"
jq --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .generatedAt = $generated
    | (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[])
      |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    | (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].runway)
      = {status:"projected_exhaustion",projectionConfidence:"established",usableRunwaySeconds:60}
    | (.providers[] | select(.provider == "grok") | .quotaSemantics.effectiveAvailability[].selection.spendPriority) = 5' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/quota.json"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/quota.json" bash "$AL" >/dev/null 2>&1
assert_equals "grok	launched" "$(cut -f4,5 "$LOG" | head -1)" 'highest spendPriority default launches'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'claude' 'an exhausted default is never tried'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'codex' 'a short-runway default is never tried'
pass 'defaults rank by spendPriority and exhausted or short-runway profiles are skipped'

# Even when every default is tight, rank-only retains spendPriority order.
reset 1
printf '%s\n' '- [ ] rank-only - prepared (repo: proj) (kind: ship)' | backlog
prep rank-only proj
printf 'rank-only\n' > "$H/config/quota-gate"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"}]}' > "$H/config/crew-dispatch.json"
jq '(.providers[].quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now") |
  (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 9' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/rank-only.json"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/rank-only.json" bash "$AL" >/dev/null 2>&1
assert_equals $'codex:gpt-5.5\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" 'rank-only retains exhausted defaults and ranks them'
rm "$H/config/quota-gate"
pass 'rank-only autolaunch never removes a default because of quota'

reset 0
printf '%s\n' '- [ ] snap-1 - prepared (repo: proj) (kind: ship)' \
  '- [ ] snap-2 - prepared (repo: proj) (kind: ship)' \
  '- [ ] snap-3 - prepared (repo: proj) (kind: ship)' | backlog
prep snap-1 proj; prep snap-2 proj; prep snap-3 proj
printf '{"default":[{"harness":"claude"}]}\n' > "$H/config/crew-dispatch.json"
cat > "$FAKE/quota-axi" <<SH
#!/usr/bin/env bash
echo call >> "$FAKE/quota-calls"
cat "$ROOT/tests/fixtures/quota-axi-healthy.json"
SH
chmod +x "$FAKE/quota-axi"
rm -f "$FAKE/quota-calls"
out=$(FM_QUOTA_SNAPSHOT_FILE='' PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t-\tsnap-3\tclaude\twould-launch-when-a-lane-frees' 'every item is ranked with zero capacity'
assert_equals 1 "$(wc -l < "$FAKE/quota-calls" | tr -d ' ')" 'a dry run over three items reads quota once'
rm -f "$FAKE/quota-calls"; printf '3\n' > "$FAKE/free"
FM_QUOTA_SNAPSHOT_FILE='' PATH="$FAKE:$PATH" bash "$AL" >/dev/null 2>&1
assert_equals 3 "$(wc -l < "$FAKE/spawn.log" | tr -d ' ')" 'three lanes launch three items'
assert_equals 1 "$(wc -l < "$FAKE/quota-calls" | tr -d ' ')" 'a real pass over three lanes reads quota once'
rm -f "$FAKE/quota-axi" "$FAKE/quota-calls"
pass 'one pass takes at most one quota snapshot'

reset 1
printf '%s\n' '- [ ] uncertain - prepared (repo: proj) (kind: ship)' | backlog
prep uncertain proj
printf '{"default":[{"harness":"opencode"},{"harness":"codex"},{"harness":"pi"}]}\n' > "$H/config/crew-dispatch.json"
printf 'opencode\ncodex\npi\n' > "$FAKE/quota-refuse"
bash "$AL" >/dev/null 2>&1
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex' 'a measured passing profile precedes uncertain profiles'
assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness opencode' 'first uncertain profile retains declared order'
assert_contains "$(sed -n 3p "$FAKE/spawn.log")" '--harness pi' 'second uncertain profile retains declared order'
pass 'uncertain defaults follow passing profiles in declared order'

for policy in absent rank-only; do
  reset 1
  [ "$policy" != rank-only ] || printf 'rank-only\n' > "$H/config/quota-gate"
  printf '%s\n' '- [ ] numeric-notice - prepared (repo: proj) (kind: ship)' | backlog
  prep numeric-notice proj
  printf '%s\n' '{"default":[{"harness":"opencode"},{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"}]}' > "$H/config/crew-dispatch.json"
  jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[]) |=
      (.runway = {status:"projected_exhaustion",projectionConfidence:"established"} | .selection.spendPriority = 9) |
    (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 2' \
    "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/numeric-notice.json"
  printf 'codex\nopencode\n' > "$FAKE/quota-refuse"
  out=$(FM_QUOTA_SNAPSHOT_FILE="$FAKE/numeric-notice.json" bash "$AL" 2>&1); rc=$?
  expect_code 0 "$rc" "$policy must retain uncertain defaults after passing candidates: $out"
  assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex --model gpt-5.5' "$policy ranks passing priority 2 before uncertain priority 9"
  assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness opencode' "$policy retains the first uncertain profile in declared order"
  assert_contains "$(sed -n 3p "$FAKE/spawn.log")" '--harness claude --model opus' "$policy retains numeric notices in the uncertain bucket"
  assert_equals $'claude:opus\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" "$policy keeps numeric notices available for fallback"
  rm -f "$H/config/quota-gate"
done
pass 'passing defaults precede numeric notices and uncertain profiles retain declared order under either policy'

for profile in '{"harness":"codex","effort":"high"}' \
  '{"harness":"codex","model":"gpt-5.5"}' '{"harness":"codex"}'; do
  reset 1
  printf '%s\n' '- [ ] fields - prepared (repo: proj) (kind: ship)' | backlog
  prep fields proj
  printf '{"default":%s}\n' "$profile" > "$H/config/crew-dispatch.json"
  expected='--harness codex'
  case "$profile" in
    *effort*) expected="$expected --effort high" ;;
    *model*) expected="$expected --model gpt-5.5" ;;
  esac
  out=$(bash "$AL" --dry-run 2>&1)
  assert_contains "$out" "$expected" 'dry-run preserves optional profile fields'
  assert_not_contains "$out" '--model high' 'effort never occupies the model field'
  bash "$AL" >/dev/null 2>&1
  assert_equals "fields $H/projects/proj --mode direct-PR --yolo off --branch-prefix fm/ $expected" "$(cat "$FAKE/spawn.log")" 'spawn flags preserve each profile field position'
done
pass 'profile contract preserves absent model and effort fields in the candidate reader'

for mode in no-mistakes direct-PR local-only; do
  for yolo in on off; do
    reset 1
    printf '%s\n' '- [ ] arguments - prepared ship (repo: proj) (kind: ship)' | backlog
    prep arguments proj "mode=$mode" "yolo=$yolo" branch_prefix=lane base_branch=curated
    bash "$AL" >/dev/null 2>&1
    assert_equals "arguments $H/projects/proj --mode $mode --yolo $yolo --branch-prefix lane --base-branch curated" "$(cat "$FAKE/spawn.log")" 'each ship delivery mode preserves its explicit arguments'
  done
done
reset 1
printf '%s\n' '- [ ] arguments - prepared scout (repo: proj) (kind: scout)' | backlog
prep arguments proj
printf 'project=proj\nkind=scout\nbase_branch=curated\n' > "$H/data/arguments/autolaunch-prep"
bash "$AL" >/dev/null 2>&1
assert_equals "arguments $H/projects/proj --scout --base-branch curated" "$(cat "$FAKE/spawn.log")" 'scouts receive the scout flag and shared base branch without ship flags'
pass 'ship and scout dispatch preserve their distinct argument contracts'

jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 9' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/eligibility-quota.json"
for snapshot in "$FAKE/eligibility-quota.json" "$FAKE/missing-quota.json"; do
  for kind in ship scout; do
    for condition in tools pi-account claude-account kimi-capture codex-capture backend profile; do
      reset 1
      printf '%s\n' '- [ ] eligible - prepared (repo: proj) (kind: ship)' | backlog
      prep eligible proj
      [ "$kind" != scout ] || printf 'project=proj\nkind=scout\n' > "$H/data/eligible/autolaunch-prep"
      backend=tmux typed=0 expected=claude
      case "$condition" in
        tools)
          printf 'hidden_tool\n' > "$H/config/crew-exclude-tools"
          profiles='[{"harness":"codex"},{"harness":"pi","model":"zai/glm-5.3","provider":"zai"}]'
          expected=pi ;;
        pi-account)
          mkdir -p "$FAKE/pi-root"
          printf '%s\ncodex-native\n' "$FAKE/pi-root" > "$H/config/pi-account"
          profiles='[{"harness":"pi","model":"zai/glm-5.3","provider":"zai"},{"harness":"pi","model":"codex-native/gpt-6-astra","provider":"codex"}]'
          expected=pi ;;
        claude-account)
          printf '%s\n' "$FAKE/missing-account" > "$H/config/claude-account"
          profiles='[{"harness":"claude"},{"harness":"codex"}]'
          expected=codex ;;
        kimi-capture)
          backend=orca
          profiles='[{"harness":"kimi","provider":"codex"},{"harness":"claude"}]' ;;
        codex-capture)
          backend=paseo typed=1
          profiles='[{"harness":"codex"},{"harness":"claude"}]' ;;
        backend)
          backend=zellij
          profiles='[{"harness":"commandcode","provider":"codex"},{"harness":"claude"}]' ;;
        profile)
          profiles='[{"harness":"polytoken","provider":"codex"},{"harness":"claude"}]' ;;
      esac
      printf '{"default":%s}\n' "$profiles" > "$H/config/crew-dispatch.json"
      FM_BACKEND=$backend FM_CODEX_TYPED_LAUNCH=$typed FM_QUOTA_SNAPSHOT_FILE="$snapshot" bash "$AL" >/dev/null 2>&1
      assert_equals 1 "$(wc -l < "$FAKE/spawn.log" | tr -d ' ')" "only an eligible default is dispatched: $condition"
      assert_contains "$(cat "$FAKE/spawn.log")" "--harness $expected" "launch eligibility precedes ranking: $condition"
      if [ "$condition" = pi-account ]; then
        assert_contains "$(cat "$FAKE/spawn.log")" '--model codex-native/gpt-6-astra' 'configured provider restriction excludes the other Pi profile'
      fi
    done
  done
done
pass 'default eligibility honors tool, account, capture, backend and profile contracts with known or unavailable quota'

# --- derived launch record ----------------------------------------------------
reset 2
printf '%s\n' '- [ ] derived - brief contract wins (repo: proj) (kind: ship)' \
  '- [ ] derived-scout - scout brief (repo: proj) (kind: scout)' | backlog
bash "$ROOT/bin/fm-brief.sh" derived proj --mode direct-PR --branch-prefix lane/ --base-branch curated \
  --upstream-consent github.com/o/r --project "$H/projects/proj" >/dev/null || fail 'ship scaffold for derivation'
bash "$ROOT/bin/fm-brief.sh" derived-scout proj --scout --base-branch curated >/dev/null || fail 'scout scaffold for derivation'
rm -f "$H/data/derived/autolaunch-prep" "$H/data/derived-scout/autolaunch-prep"
printf 'prep\n' > "$H/data/derived/prep.md"; printf 'prep\n' > "$H/data/derived-scout/prep.md"
printf -- '- proj [no-mistakes +yolo branch=reg/] - test project (added 2026-10-01)\n' > "$H/data/projects.md"
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" "would-run: $FAKE/spawn derived $H/projects/proj --mode direct-PR --yolo on --branch-prefix lane/ --upstream-consent github.com/o/r --base-branch curated" 'fm-brief.sh ship contract lines win; yolo comes from the registry'
assert_contains "$out" "would-run: $FAKE/spawn derived-scout $H/projects/proj --scout --base-branch curated" 'fm-brief.sh scout base branch is carried'
reset 1
reset 1
printf '%s\n' '- [ ] reg-only - registry fallback (repo: proj) (kind: ship)' | backlog
mkdir -p "$H/data/reg-only"; printf '# Task\nplain brief\n' > "$H/data/reg-only/brief.md"; printf 'prep\n' > "$H/data/reg-only/prep.md"
printf -- '- proj [local-only branch=x/] - test project (added 2026-10-01)\n' > "$H/data/projects.md"
bash "$AL" >/dev/null 2>&1
assert_equals "reg-only $H/projects/proj --mode local-only --yolo off --branch-prefix x/" "$(cat "$FAKE/spawn.log")" 'registry supplies mode, yolo and branch prefix'
reset 1
printf '%s\n' '- [ ] override - record wins (repo: proj) (kind: ship)' | backlog
mkdir -p "$H/data/override"
printf 'Delivery contract: mode=direct-PR\nShip branch: fm/override\n' > "$H/data/override/brief.md"; printf 'prep\n' > "$H/data/override/prep.md"
printf 'yolo=on\nbranch_prefix=\n' > "$H/data/override/autolaunch-prep"
bash "$AL" >/dev/null 2>&1
assert_equals "override $H/projects/proj --mode direct-PR --yolo on --branch-prefix " "$(cat "$FAKE/spawn.log")" 'an override record replaces only the fields it names'
pass 'the launch record derives from override, brief lines, backlog row and project registry in that order'

# Laptop layout: X items with a prep file and a brief, beside unprepared work,
# in backlog order; a backlog priority does not reorder launches.
laptop_layout() {  # <free lanes>
  reset "$1"
  mkdir -p "$H/projects/NOT_Q" "$H/outside"
  printf '%s\n' \
    '- [ ] x-region-registry - X region registry (repo: NOT_Q) (kind: ship) (priority: 2)' \
    '  Prep: data/x-prep-region-registry/prep.md' \
    '- [ ] x-no-brief - prep but no brief (repo: NOT_Q) (kind: ship)' \
    '- [ ] x-ops-task - operational task (repo: NOT_Q) (kind: task)' \
    '- [ ] x-no-prep - brief but no prep (repo: NOT_Q) (kind: ship)' \
    '- [ ] x-plan-mention - mentions a plan without a Prep line (repo: NOT_Q) (kind: ship)' \
    '  drafts data/x-plan/plan.md' \
    '- [ ] x-escape - Prep line outside data (repo: NOT_Q) (kind: ship)' \
    '  Prep: data/../outside/prep.md' \
    '- [ ] x-engine-account-currency - X engine account currency (repo: NOT_Q) (kind: ship) (priority: 1)' | backlog
  printf -- '- NOT_Q [direct-PR branch=] - X (added 2026-10-01)\n' > "$H/data/projects.md"
  for id in x-region-registry x-engine-account-currency x-ops-task x-no-prep x-plan-mention x-escape; do
    mkdir -p "$H/data/$id"
    printf 'Delivery contract: mode=direct-PR\nShip branch: %s\n' "$id" > "$H/data/$id/brief.md"
  done
  mkdir -p "$H/data/x-prep-region-registry" "$H/data/x-no-brief" "$H/data/x-plan"
  printf 'PERSONA: admin/owner new to X; observe the saved region; surfaces=chat; usage=beginner\nDOCTOR: no Doctor change; because registry-only fixture.\nXAI-SURFACE: none; because registry-only fixture.\n' > "$H/data/x-prep-region-registry/prep.md"
  printf 'PERSONA: trader familiar with X; observe the account currency; surfaces=pages; usage=experienced\nDOCTOR: battery Read-settings, expected saved currency.\nXAI-SURFACE: tool Read-settings\n' > "$H/data/x-engine-account-currency/prep.md"
  printf 'prep\n' > "$H/data/x-ops-task/prep.md"
  printf 'prep\n' > "$H/data/x-no-brief/prep.md"
  printf 'plan\n' > "$H/data/x-plan/plan.md"
  printf 'prep\n' > "$H/outside/prep.md"
}
laptop_layout 2
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t1\tx-region-registry\tstatic\tlaunched' 'Prep-linked item, first in the backlog, would launch first'
assert_contains "$out" $'\t2\tx-no-brief\t-\trefused:not prepared: no brief data/x-no-brief/brief.md' 'no brief reason'
assert_contains "$out" $'\t2\tx-ops-task\t-\trefused:not prepared: kind task is not ship or scout' 'task kind reason'
assert_contains "$out" $'\t2\tx-no-prep\t-\trefused:not prepared: no prep file' 'no prep file reason'
assert_contains "$out" $'\t2\tx-plan-mention\t-\trefused:not prepared: no prep file' 'an unlabelled plan mention is not a prep file'
assert_contains "$out" $'\t2\tx-escape\t-\trefused:not prepared: no prep file' 'a Prep path escaping data/ is not a prep file'
assert_contains "$out" $'\t2\tx-engine-account-currency\tstatic\tlaunched' 'the later prepared item takes the second lane despite its priority'
assert_contains "$out" "x-engine-account-currency $H/projects/NOT_Q --mode direct-PR --yolo off --branch-prefix ''" 'bare branch from the brief'
pass 'a dry run on the laptop layout would launch the prepared X items in backlog order and names every refusal'

laptop_layout 1
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t1\tx-region-registry\tstatic\tlaunched' 'the free lane goes to the first prepared item'
for id in x-no-brief x-ops-task x-no-prep x-plan-mention x-escape; do
  assert_contains "$out" $'\t-\t'"$id"$'\t-\trefused:not prepared: ' "an item beyond the free lane still names its refusal: $id"
done
assert_contains "$out" $'\t-\tx-engine-account-currency\tstatic\twould-launch-when-a-lane-frees' 'a prepared item beyond the free lane waits for one'
assert_contains "$out" "would-run: $FAKE/spawn x-engine-account-currency $H/projects/NOT_Q" 'a waiting item still shows its spawn command'
bash "$AL" >/dev/null 2>&1
assert_equals "x-region-registry $H/projects/NOT_Q --mode direct-PR --yolo off --branch-prefix " "$(cat "$FAKE/spawn.log")" 'a real pass still stops at the free lanes'
assert_not_contains "$(cat "$LOG")" 'x-engine-account-currency' 'a real pass records nothing beyond the free lanes'
laptop_layout 0
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t-\t-\t-\trefused:no capacity: full' 'zero capacity is named first'
assert_contains "$out" $'\t-\tx-region-registry\tstatic\twould-launch-when-a-lane-frees' 'with no capacity the first prepared item waits'
assert_contains "$out" $'\t-\tx-engine-account-currency\tstatic\twould-launch-when-a-lane-frees' 'with no capacity the second prepared item waits'
assert_contains "$out" $'\t-\tx-no-brief\t-\trefused:not prepared: no brief data/x-no-brief/brief.md' 'with no capacity refusals are still named'
assert_not_contains "$out" 'no prepared item' 'no lane is reported open with zero capacity'
pass 'a dry run names every ready item beyond the free lanes and with no capacity'

reset 1
printf '%s\n' '- [ ] bf-new - derivable (repo: proj) (kind: ship)' \
  '- [ ] bf-kept - has a record (repo: proj) (kind: ship)' \
  '- [ ] bf-held - held but derivable (repo: proj) (kind: ship) (hold: wait) (hold-kind: captain)' \
  '- [ ] bf-skip - no prep (repo: proj) (kind: ship)' | backlog
printf -- '- proj [direct-PR +yolo] - test (added 2026-10-01)\n' > "$H/data/projects.md"
for id in bf-new bf-kept bf-held bf-skip; do mkdir -p "$H/data/$id"; printf 'brief\n' > "$H/data/$id/brief.md"; done
for id in bf-new bf-kept bf-held; do printf 'prep\n' > "$H/data/$id/prep.md"; done
printf 'yolo=off\n' > "$H/data/bf-kept/autolaunch-prep"
out=$(bash "$AL" --backfill 2>&1); rc=$?
expect_code 0 "$rc" 'backfill dry run'
assert_contains "$out" 'would-write: data/bf-new/autolaunch-prep: project=proj kind=ship mode=direct-PR branch_prefix=fm/' 'dry backfill prints the derived record without yolo'
assert_contains "$out" 'would-write: data/bf-held/autolaunch-prep' 'held items are backfilled too'
assert_contains "$out" 'kept: bf-kept' 'an existing record is kept'
assert_contains "$out" 'skip: bf-skip: no prep file' 'an underivable item names its reason'
assert_absent "$H/data/bf-new/autolaunch-prep" 'dry backfill writes nothing'
bash "$AL" --backfill --apply >/dev/null 2>&1 || fail 'backfill apply'
assert_equals $'project=proj\nkind=ship\nmode=direct-PR\nbranch_prefix=fm/' "$(cat "$H/data/bf-new/autolaunch-prep")" 'apply writes the derived record'
printf -- '- proj [direct-PR] - test (added 2026-10-01)\n' > "$H/data/projects.md"
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" "bf-new $H/projects/proj --mode direct-PR --yolo off" 'a backfilled record follows a later registry yolo change'
printf -- '- proj [direct-PR +yolo] - test (added 2026-10-01)\n' > "$H/data/projects.md"
assert_equals 'yolo=off' "$(cat "$H/data/bf-kept/autolaunch-prep")" 'apply never rewrites an existing record'
out=$(bash "$AL" --backfill --apply 2>&1)
assert_contains "$out" 'kept: bf-new' 'a second apply is idempotent'
assert_not_contains "$out" 'wrote:' 'a second apply writes nothing'
pass 'backfill prints first, writes only on --apply, and is idempotent'

reset 1
BH="$TMP_ROOT/brief-home"
mkdir -p "$BH/data" "$BH/state" "$BH/config" "$BH/projects/proj"
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-ship proj --mode direct-PR --branch-prefix lane/ --base-branch curated --project "$BH/projects/proj" >/dev/null || fail 'ship scaffold'
assert_equals $'project=proj\nkind=ship\nmode=direct-PR\nbranch_prefix=lane/\nbase_branch=curated' "$(cat "$BH/data/new-ship/autolaunch-prep")" 'ship scaffold writes its launch record'
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-scout proj --scout >/dev/null || fail 'scout scaffold'
assert_equals $'project=proj\nkind=scout' "$(cat "$BH/data/new-scout/autolaunch-prep")" 'scout scaffold writes its launch record'
rm -f "$BH/data/new-ship/brief.md"
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-ship proj --scout >/dev/null || fail 're-scaffold as scout'
assert_equals $'project=proj\nkind=scout' "$(cat "$BH/data/new-ship/autolaunch-prep")" 'a re-scaffold replaces the stale kind and base branch'
assert_equals '' "$(find "$BH/data/new-ship" -name '.autolaunch-prep.*')" 'the record write leaves no temporary file'
pass 'fm-brief.sh writes the launch record for every ship and scout it scaffolds, replacing a stale one'

# --- dry-run and lock --------------------------------------------------------
reset 1
printf '%s\n' "- [ ] dry-item - prepared (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] dry-unprep - unprepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep dry-item proj base_branch=curated upstream_consent=github.com/o/r
out=$(bash "$AL" --dry-run 2>&1); rc=$?
expect_code 0 "$rc" 'dry run'
assert_absent "$LOG" 'dry run writes no log'
[ ! -f "$FAKE/spawn.log" ] || fail 'dry run spawned'
[ ! -e "$H/state/.autolaunch.lock" ] || fail 'dry run took the lock'
assert_contains "$out" 'would-record: ' 'dry run prints records'
assert_contains "$out" 'dry-item	static	launched' 'dry run prints the launch decision'
assert_contains "$out" "would-run: " 'dry run prints the spawn command'
assert_contains "$out" '--upstream-consent github.com/o/r --base-branch curated' 'dry run command carries the prep flags'
list=$(bash "$AL" --list-prepared 2>&1)
assert_equals 'dry-item' "$list" 'list-prepared names only launchable items'
pass 'dry run prints decisions and commands and writes nothing'

reset 1
printf '%s\n' "- [ ] locked - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep locked proj
sleep 300 &
# shellcheck disable=SC2031 # read in this shell; the K1 helpers' own background starts are separate
holder=$!
mkdir "$H/state/.autolaunch.lock"; printf '%s\n' "$holder" > "$H/state/.autolaunch.lock/pid"
out=$(bash "$AL" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect_code 0 "$rc" 'busy lock exits quietly'
assert_contains "$out" 'another pass holds' 'busy lock is named'
# Tester-owned (K1-R6): a busy pass now writes one overrun record, so the
# former 'busy lock writes no record' assertion is retired; no launch stays.
[ ! -f "$FAKE/spawn.log" ] || fail 'second instance spawned'
rm -rf "$H/state/.autolaunch.lock"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" 'locked' 'released lock lets the next pass run'
assert_absent "$H/state/.autolaunch.lock" 'a pass releases its lock'
pass 'a single-instance lock keeps a second pass from launching'

# --- throttle check ----------------------------------------------------------
reset 1
printf '%s\n' "- [ ] waiting - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep waiting proj
NOW=$(date +%s)
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'free lane + prepared item + no record is red'
assert_contains "$out" 'first: waiting' 'red names the item'
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "red is one line: $out"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'one episode reports once'
out=$(FM_AUTOLAUNCH_CHECK_NOW=$((NOW + 3600)) bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'a continuing episode reports again after one hour'
printf 'x\n' > "$LOG"; fm_touch_epoch $((NOW - 300)) "$LOG"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'a recent record is silent'
assert_absent "$H/state/.autolaunch-check.red" 'quiet clears the episode'
fm_touch_epoch $((NOW - 700)) "$LOG"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_contains "$out" 'last record 11 min ago' 'a stale record is red'
rm -f "$H/state/.autolaunch-check.red"
echo 0 > "$FAKE/free"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'no free lane is silent'
echo 1 > "$FAKE/free"; rm -f "$H/data/waiting/prep.md"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'no prepared item is silent'
pass 'throttle check is red only for free lane + prepared item + no recent record'

reset 1
printf '%s\n' "- [ ] waiting - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep waiting proj
PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/state"
printf 'mate-a\n' > "$H/.fm-secondmate-home"
out=$(bash "$CHECK" 2>&1); rc=$?
expect_code 0 "$rc" 'evaluation remains a watcher-compatible success on parent delivery failure'
assert_contains "$out" 'parent delivery failed (exit 3); will retry' 'missing parent binding is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'failed delivery does not suppress retry'
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$H/.fm-secondmate-parent"
mkdir "$PARENT/state/mate-a.status"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'parent delivery failed (exit 4); will retry' 'parent append failure is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'failed append does not suppress retry'
rmdir "$PARENT/state/mate-a.status"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'mate home still prints red'
if [ -f "$PARENT/state/mate-a.status" ]; then
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'blocked [at=' 'mate red reaches the parent channel'
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'RED auto-launch stalled' 'parent line carries the red text'
else
  fail "secondmate red line did not reach the parent channel"
fi
assert_present "$H/state/.autolaunch-check.red" 'successful parent delivery publishes the episode marker'
out=$(bash "$CHECK" 2>&1)
assert_equals '' "$out" 'successful retry is throttled'
assert_equals 1 "$(wc -l < "$PARENT/state/mate-a.status" | tr -d ' ')" 'successful recovery delivers once'
rm -f "$H/state/.autolaunch-check.red" "$H/.fm-secondmate-home"
ln -s "$PARENT" "$H/.fm-secondmate-home"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'parent delivery failed (exit 2); will retry' 'unusable identity is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'unusable identity remains retryable'
rm -f "$H/.fm-secondmate-home" "$H/.fm-secondmate-parent"
pass 'in a secondmate home the red line also reaches the parent channel'

out=$(bash "$CHECK" arm 2>&1) || fail "arm failed: $out"
assert_contains "$out" 'armed: state/autolaunch.check.sh' 'arm reports the shim'
assert_present "$H/state/autolaunch.check.sh" 'shim written'
assert_present "$H/state/autolaunch.check-trust" 'shim registered'
out=$(bash "$CHECK" arm 2>&1) || fail "re-arm failed: $out"
assert_contains "$out" 'armed: state/autolaunch.check.sh' 'repeated arm refreshes registration'
chmod 0500 "$H/state"
out=$(bash "$CHECK" disarm 2>&1); rc=$?
chmod 0700 "$H/state"
expect_code 1 "$rc" 'failed unregistration propagates failure'
assert_not_contains "$out" 'disarmed:' 'failed unregistration never reports success'
assert_present "$H/state/autolaunch.check.sh" 'failed retirement preserves the check'
mv "$H/state/autolaunch.check-trust" "$H/state/original-trust"
ln -s "$H/state/original-trust" "$H/state/autolaunch.check-trust"
out=$(bash "$CHECK" disarm 2>&1); rc=$?
expect_code 1 "$rc" 'unregistration rejects unsafe trust artifacts'
assert_present "$H/state/autolaunch.check.sh" 'shared retirement validation runs before removal'
rm "$H/state/autolaunch.check-trust"
mv "$H/state/original-trust" "$H/state/autolaunch.check-trust"
bash "$CHECK" disarm >/dev/null
assert_absent "$H/state/autolaunch.check.sh" 'disarm removes the shim'
assert_absent "$H/state/autolaunch.check-trust" 'disarm retires trust through the shared owner'
bash "$CHECK" disarm >/dev/null || fail 'repeated disarm must succeed'
out=$(bash "$AL" --print-timer)
assert_contains "$out" "Environment=\"FM_HOME=$H\"" 'timer proposal pins FM_HOME'
assert_contains "$out" 'OnUnitActiveSec=5min' 'timer proposal runs every five minutes'
pass 'the check arms through fm-check-register and the timer is only a printed proposal'

# Builder-owned coverage for the staged activation boundary. These cases use
# the production selector and a manager protocol stub, with no action dispatch.
test_controller_activation_preserves_legacy_until_rollout

# The step-pass matrix uses this same executable seam and hermetic task store.
[ "${1:-}" != --launch-only ] || exit 0
python3 "$ROOT/tests/autolaunch_steps_cases.py" "$ROOT" || fail 'slice step-pass fixtures'
pass 'slice step-pass crash, replay, lease and stall fixtures'

k1_run test_controller_agent_identity_refreshes_after_spawn_probe \
  test_controller_late_agent_identity_is_current \
  test_controller_project_refusal_preserves_lane_order \
  test_controller_saved_lane_rechecks_project_capacity \
  test_controller_blocked_rows_do_not_reserve_lanes \
  test_controller_all_outcomes_wait_for_attempt_settlement \
  test_controller_published_results_keep_r9_supervision \
  test_controller_rung2_owns_before_wrapper_release \
  test_controller_timeout_stops_inflight_profile_fallback \
  test_controller_saved_terminal_launch_commands_do_not_execute \
  test_controller_timeout_handoff_rejects_late_results \
  test_controller_notice_publication_is_not_executable \
  test_controller_legacy_queued_notices_do_not_block_actions \
  test_controller_success_receipt_waits_for_execution_and_slot \
  test_controller_step_handoff_survives_successful_recurrence \
  test_controller_ring_handoff_survives_successful_recurrence \
  test_controller_remote_handoff_survives_successful_recurrence \
  test_controller_busy_steps_reconcile_technical_decisions \
  test_controller_local_closure_retry_survives_busy_restart \
  test_controller_main_closure_retry_survives_busy_restart \
  test_controller_runtime_quota_falls_through_profiles \
  test_controller_busy_step_preserves_launch_deadline \
  test_controller_busy_pass_reconciles_receipt_siblings \
  test_controller_lock_recovery_uses_actual_acquisition \
  test_controller_discovery_failures_reconcile_existing_actions \
  test_controller_vanished_holders_never_accumulate \
  test_controller_interrupted_launch_rechecks_preparation \
  test_controller_saved_action_refreshes_launch_argv \
  test_controller_saved_action_refuses_withdrawn_preparation \
  test_controller_retry_rechecks_preparation_and_argv \
  test_controller_busy_delivery_defers_and_recovers \
  test_controller_decision_pair_is_injective \
  test_controller_inbox_pair_preserves_task_and_message \
  test_controller_quota_refusal_is_a_wait \
  test_controller_deferred_attempt_has_fresh_receipts \
  test_controller_equal_decision_keys_remain_task_scoped \
  test_controller_lock_incident_reopens_after_recovery \
  test_controller_diagnosis_charge_survives_dispatch_crash \
  test_controller_ring_recurrence_preserves_spaced_paths \
  test_controller_partial_plan_ownership_is_late \
  test_controller_status_timeouts_preserve_progress \
  test_controller_main_close_timeout_preserves_progress \
  test_controller_journal_contention_keeps_delivery_live \
  test_controller_existing_steps_receive_deadlines \
  test_controller_retry_spends_once_after_decision \
  test_controller_prepared_argv_preserves_unicode \
  test_controller_backend_context_reaches_units \
  test_controller_technical_notes_are_not_reserved \
  test_controller_late_launch_keeps_diagnosis_occupied \
  test_controller_remote_inbox_uses_existing_due_owner \
  test_controller_step_deadline_qualifies_pass_lock \
  test_controller_ledger_contention_preserves_ten_key_deadlines

# Tester-owned (lc-core-scheduler K1-R1..R12 oracles, defined above): they
# run last so every earlier case keeps its coverage while they are red.
k1_run k1

# Tester-owned (lc-core-scheduler EGM1 input-join oracles, defined above the
# K1 block): they run after every earlier case so those keep their coverage.
egm1_run egm1

# Tester-owned (lc-core-scheduler EGM1-R2 join validation oracles, defined
# after the EGM1 block): they run last so every earlier case keeps its coverage.
egm1r2_run egm1r2

# Tester-owned (lc-core-scheduler EGM1-R3 unavailable-home oracles, defined
# after the EGM1-R2 block): they run last so every earlier case keeps its coverage.
egm1r3_run egm1r3
