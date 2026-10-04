#!/usr/bin/env bash
# Public metadata sampling and unchanged-episode warning regression.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-nm-config-staleness)
HELPER="${FM_NM_TEST_HELPER:-$ROOT/bin/fm-nm-config-staleness-check.sh}"
fm_git_init_commit "$T/selection"
mkdir -p "$T/selection/bin" "$T/selection/tests/fixtures"
cp "$ROOT/bin/fm-test-run.sh" "$T/selection/bin/"
cp "$ROOT/tests/fm-nm-config-staleness.test.sh" "$T/selection/tests/"
git -C "$T/selection" add bin tests
git -C "$T/selection" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'test selection baseline'
cp "$ROOT/tests/fixtures/server-idle-watch.check.sh" "$T/selection/tests/fixtures/"
selected=$(bash "$T/selection/bin/fm-test-run.sh" --list --changed --base HEAD)
assert_equals 'tests/fm-nm-config-staleness.test.sh' "$selected" 'fixture-only change must select its owning test'
pass 'changed-file selection maps the server idle fixture to its owning test'
mkdir -p "$T/nm" "$T/proc/123"
python3 - "$T" <<'PY'
import json, os, sys
from datetime import datetime, timezone
from pathlib import Path
p=Path(sys.argv[1]); start=1791108000
(p/'nm/daemon.pid').write_text(json.dumps({'pid':123,'started_at':'2026-10-04T10:00:00Z'}))
(p/'nm/config.yaml').write_text('DO NOT READ CONFIG VALUES\n')
os.utime(p/'nm/config.yaml', ns=((start+20)*10**9,)*2)
(p/'proc/stat').write_text('btime '+str(start-5)+'\n')
fields=['S']+['0']*18+[str(5*os.sysconf('SC_CLK_TCK'))]
(p/'proc/123/stat').write_text('123 (no-mistakes) '+' '.join(fields)+'\n')
(p/'proc/123/comm').write_text('no-mistakes\n')
(p/'proc/123/status').write_text('Uid:\t'+('\t'.join([str(os.getuid())]*4))+'\n')
PY
sample() { FM_NM_PROC_ROOT="$T/proc" "$HELPER" "$T/nm" "${1:-pc}"; }
out=$(sample)
assert_contains "$out" '"status": "stale"' 'config beyond tolerance must be stale'
pass 'config beyond tolerance is stale through public CLI'
# Public comparison boundaries use derived process start, not record wall time.
FM_NM_PROC_ROOT="$T/proc" python3 - "$T/nm/config.yaml" "$HELPER" "$T/nm" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
config=Path(sys.argv[1]); start=1791108000*10**9
for delta,expected in ((-1,'current'),(0,'current'),(1,'current'),
                       (10*10**9-1,'current'),(10*10**9,'current'),(10*10**9+1,'stale')):
    os.utime(config, ns=(start+delta,)*2)
    observed=json.loads(subprocess.check_output([sys.argv[2],sys.argv[3],'pc'], text=True))
    assert observed['status']==expected, (delta,observed)
# btime affects only the comparison, including when it crosses the tolerance.
os.utime(config, ns=(start+10*10**9+1,)*2)
proc=Path(os.environ['FM_NM_PROC_ROOT'])
for boot,expected in ((1791107996,'current'),(1791107994,'stale')):
    (proc/'stat').write_text(f'btime {boot}\n')
    observed=json.loads(subprocess.check_output([sys.argv[2],sys.argv[3],'pc'], text=True))
    assert observed['status']==expected and observed['pid']==123
    assert observed['process_start_ticks']==5*os.sysconf('SC_CLK_TCK')
(proc/'stat').write_text('btime 1791107995\n')
os.utime(config, ns=(start+20*10**9,)*2)
PY
pass 'older, equal, inside tolerance and exact 10-second boundary are current'
# Wall-clock steps change btime, not the live process or its PID record.
for boot in 1791107992 1791107998; do
  printf 'btime %s\n' "$boot" > "$T/proc/stat"
  assert_contains "$(sample)" '"status": "stale"' 'clock movement must preserve the unchanged daemon observation'
done
printf 'btime 1791107995\n' > "$T/proc/stat"
pass 'forward and backward clock steps preserve stale daemon evidence'
# Clock movement and valid record wall time do not alter episode identity.
FM_NM_PROC_ROOT="$T/proc" python3 - "$T" "$HELPER" <<'PY'
import json, os, subprocess, sys
from pathlib import Path
root=Path(sys.argv[1]); helper=sys.argv[2]; marker=root/'clock-episode'
original=(root/'nm/daemon.pid').read_bytes(); ticks=None; digest=None
try:
    for boot,record_time in ((1791107995,'2026-10-04T10:00:00Z'),
                             (1791107992,'2026-10-04T10:00:00Z'),
                             (1791107998,'2026-10-04T10:00:00Z'),
                             (1791107995,'2026-10-04T09:00:00Z'),
                             (1791107995,'2026-10-04T11:00:00.123456789Z')):
        (root/'proc/stat').write_text(f'btime {boot}\n')
        (root/'nm/daemon.pid').write_text(json.dumps(dict(pid=123,started_at=record_time)))
        r=json.loads(subprocess.check_output([helper,str(root/'nm'),'pc'], text=True))
        assert r['status']=='stale',r
        if ticks is None: ticks=r['process_start_ticks']
        assert r['pid']==123 and r['process_start_ticks']==ticks
        observations=json.dumps(r)+'\n'+''.join(json.dumps(dict(schema='fm-nm-config-age/1',machine=m,status='current',pid=123,process_start_ticks=ticks,config_mtime_ns=0))+'\n' for m in ('server','zenbook'))
        output=subprocess.check_output([helper,'--episode',str(marker)], input=observations, text=True)
        if digest is None:
            assert output.strip()=='server-idle-watch: no-mistakes config newer than running daemon on: pc'
            digest=marker.read_bytes()
        else:
            assert output=='',output
            assert marker.read_bytes()==digest
finally:
    (root/'nm/daemon.pid').write_bytes(original)
    (root/'proc/stat').write_text('btime 1791107995\n')
PY
pass 'clock steps and record wall time preserve PID/tick episode deduplication'
mkdir -p "$T/home/state" "$T/fakebin"
cp "$ROOT/tests/fixtures/server-idle-watch.check.sh" "$T/home/state/server-idle-watch.check.sh"
chmod 700 "$T/home/state/server-idle-watch.check.sh"
cat > "$T/fakebin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/commands"
if [ -n "${NM_HANG_HOST:-}" ]; then
  case "$*" in
    *"fixture-$NM_HANG_HOST"*)
      case "$*" in *fm-nm-config-staleness-check*) phase=metadata;; *) phase=health;; esac
      printf '%s\n' "$$" > "$FIXTURE/pending-$NM_HANG_HOST-$phase"
      sleep 60;;
  esac
fi
case "$*" in
  *fm-nm-config-staleness-check*)
    case "$*" in *fixture-server*) machine=server;; *) machine=zenbook;; esac
    if [ "$machine" = zenbook ] && [ "${NM_BAD_PROBE:-0}" = 1 ]; then printf 'broken transport output\n'; exit 0; fi
    FM_NM_PROC_ROOT="$FIXTURE/proc" "$HELPER" "$FIXTURE/$machine" "$machine";;
  *fixture-server*)
    case "${FIXTURE_MODE:-normal}" in
      idle) printf '10 10\n0\n1\n';;
      storm) printf '90 1\n1\n3\n';;
      *) printf '90 1\n1\n1\n';;
    esac;;
  *) printf '90 1\n1\n';;
esac
FAKE
chmod +x "$T/fakebin/ssh"
cp -r "$T/nm" "$T/server"
cp -r "$T/nm" "$T/zenbook"
export FIXTURE="$T" HELPER
check() {
  rm -f "$T/home/state/.server-idle-watch-last-run"
  PATH="$T/fakebin:$PATH" STATE="$T/home/state" NM_HOME="$T/nm" NM_HELPER="$HELPER" FM_NM_PROC_ROOT="$T/proc" \
    timeout -k 1 25 /bin/bash "$T/home/state/server-idle-watch.check.sh"
}
assert_episode_output() {
  python3 - "$1" "$2" <<'PY'
import sys
prefix="server-idle-watch: no-mistakes config newer than running daemon on: "
lines=[line for line in sys.argv[1].splitlines() if line.startswith(prefix)]
if not lines or lines[-1]!=sys.argv[2]:
    raise SystemExit("unexpected final stale set: "+sys.argv[1])
for line in lines:
    machines=line[len(prefix):].split(", ")
    if machines!=sorted(set(machines)) or not set(machines)<={"pc","server","zenbook"}:
        raise SystemExit("unsorted or invalid warning: "+line)
PY
}
out=$(check)
assert_episode_output "$out" 'server-idle-watch: no-mistakes config newer than running daemon on: pc, server, zenbook'
[ -z "$(check)" ] || fail 'unchanged three-host episode repeats'
set_time() { python3 - "$T/$1/config.yaml" "$2" <<'PY'
import os, sys
n=int(sys.argv[2]); os.utime(sys.argv[1], ns=(n,n))
PY
}
set_time server 1791107999000000000
set_time zenbook 1791108000000000000
assert_contains "$(FM_NM_PROC_ROOT="$T/proc" "$HELPER" "$T/server" server)" '"status": "current"' 'older is current'
assert_contains "$(FM_NM_PROC_ROOT="$T/proc" "$HELPER" "$T/zenbook" zenbook)" '"status": "current"' 'equal is current'
rm -f "$T/home/state/.server-idle-watch-nm-config-episode"
warning='server-idle-watch: no-mistakes config newer than running daemon on: pc'
[ "$(check)" = "$warning" ] || fail 'first episode must name only pc'
[ -z "$(check)" ] || fail 'unchanged episode repeats'
set_time server 1791108021000000000
assert_episode_output "$(check)" "$warning, server"
cp "$T/nm/daemon.pid" "$T/record.good"
cp "$T/proc/123/stat" "$T/stat.good"
printf '{"pid":123,"started_at":"2026-10-04T10:00:20Z"}\n' > "$T/nm/daemon.pid"
python3 - "$T/proc/123/stat" <<'PY'
import os,sys
from pathlib import Path
p=Path(sys.argv[1]); f=p.read_text().split(); f[-1]=str(25*os.sysconf('SC_CLK_TCK')); p.write_text(' '.join(f))
PY
# Remote observations retain their own independent process/start identity.
# Give each remote PID metadata its own matching synthetic process.
for pair in server:124 zenbook:125; do
  machine=${pair%:*}; pid=${pair#*:}
  cp -r "$T/proc/123" "$T/proc/$pid"
  cp "$T/stat.good" "$T/proc/$pid/stat"
  printf '{"pid":%s,"started_at":"2026-10-04T10:00:00Z"}\n' "$pid" > "$T/$machine/daemon.pid"
done
[ "$(check)" = 'server-idle-watch: no-mistakes config newer than running daemon on: server' ] || fail 'new pc identity must clear only pc'
set_time zenbook 1791108020000000000
# A bad remote record does not suppress independently confirmed stale pc.
cp "$T/record.good" "$T/nm/daemon.pid"; cp "$T/stat.good" "$T/proc/123/stat"
printf 'legacy-pid\n' > "$T/zenbook/daemon.pid"
out=$(check)
assert_contains "$out" 'observation unavailable on: zenbook' 'partial probe failure is visible'
assert_contains "$out" "$warning, server" 'partial probe failure must not hide pc'
rm "$T/home/state/.server-idle-watch-nm-config-episode"
out=$(NM_BAD_PROBE=1 check)
assert_contains "$out" 'observation unavailable on: zenbook' 'malformed transport remains visible'
assert_contains "$out" "$warning, server" 'malformed transport must not suppress stale machines'
pass 'three-host comparisons, unchanged episodes, restart and partial failure'

cp "$T/server/daemon.pid" "$T/zenbook/daemon.pid"
set_time zenbook 1791108020000000000
python3 - "$T" <<'PY'
import os, selectors, subprocess, sys, time
from pathlib import Path

root=Path(sys.argv[1]); errors=[]
prefix="server-idle-watch: no-mistakes config newer than running daemon on: "
for machine in ("server", "zenbook"):
    available="zenbook" if machine=="server" else "server"
    warning=(prefix+"pc, "+available).encode()
    state=root/"home/state"
    for name in (".server-idle-watch-last-run", ".server-idle-watch-nm-config-episode"):
        (state/name).unlink(missing_ok=True)
    env=dict(os.environ, PATH=str(root/"fakebin")+":"+os.environ["PATH"],
             STATE=str(state), NM_HOME=str(root/"nm"), NM_HELPER=os.environ["HELPER"],
             FM_NM_PROC_ROOT=str(root/"proc"), NM_HANG_HOST=machine)
    started=time.monotonic()
    proc=subprocess.Popen(["timeout", "-k", "1", "25", "/bin/bash", str(state/"server-idle-watch.check.sh")],
                          env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    early=b""
    while time.monotonic()-started<5:
        try:
            for phase in ("health", "metadata"):
                os.kill(int((root/f"pending-{machine}-{phase}").read_text()), 0)
            break
        except (OSError, ValueError): time.sleep(0.01)
    with selectors.DefaultSelector() as ready:
        ready.register(proc.stdout, selectors.EVENT_READ)
        while time.monotonic()-started<5 and warning+b"\n" not in early:
            if ready.select(max(0, 5-(time.monotonic()-started))):
                chunk=os.read(proc.stdout.fileno(), 4096)
                if not chunk: break
                early+=chunk
    prompt=time.monotonic()-started
    pending=[]
    for phase in ("health", "metadata"):
        try:
            os.kill(int((root/f"pending-{machine}-{phase}").read_text()), 0)
            pending.append(phase)
        except (OSError, ValueError): pass
    if warning+b"\n" not in early or len(pending)!=2 or proc.poll() is not None:
        errors.append(f"{machine}: confirmed stale stdout missing while both probes pending (observed {prompt:.3f}s)")
    rest,stderr=proc.communicate(timeout=30)
    output=(early+rest).decode()
    if proc.returncode!=0 or f"observation unavailable on: {machine}" not in output or warning.decode() not in output:
        errors.append(f"{machine}: bounded completion lost warning or unavailable diagnostic: {output} {stderr.decode()}")
    lines=[line for line in output.splitlines() if line.startswith(prefix)]
    if not lines or lines[-1]!=warning.decode():
        errors.append(f"{machine}: final warning lost the sorted affected set")
    for line in lines:
        names=line[len(prefix):].split(", ")
        if names!=sorted(set(names)):
            errors.append(f"{machine}: warning is not sorted: {line}")
    print(f"{machine}: pc and {available} stdout observed at {prompt:.3f}s; pending={','.join(pending)}; check completed at {time.monotonic()-started:.3f}s", flush=True)
    print(output, end="", flush=True)
if errors:
    raise SystemExit("\n".join(errors))
PY
pass 'both remote timeout paths preserve stale pc within the watcher deadline'

expect_unknown() { assert_contains "$(sample)" '"status": "unavailable"' "$1 must be unavailable"; }
for record in '123' '{"pid":-1,"started_at":"2026-10-04T10:00:00Z"}' '{"pid":123,"started_at":"invalid"}' '{"pid":999,"started_at":"2026-10-04T10:00:00Z"}'; do
  printf '%s\n' "$record" > "$T/nm/daemon.pid"; expect_unknown 'malformed record or dead PID'
done
cp "$T/record.good" "$T/nm/daemon.pid"
chmod 000 "$T/nm/config.yaml"; expect_unknown 'unreadable config'; chmod 600 "$T/nm/config.yaml"
mv "$T/nm/config.yaml" "$T/config.good"
ln -s "$T/config.good" "$T/nm/config.yaml"; expect_unknown 'symlink config'
rm "$T/nm/config.yaml"; cp "$T/config.good" "$T/nm/config.yaml"
# FIFO supplies two different kernel identities at the public proc-reader seam.
rm "$T/proc/123/stat" "$T/proc/123/comm"; mkfifo "$T/proc/123/stat" "$T/proc/123/comm"
( printf 'no-mistakes\n' > "$T/proc/123/comm"; cat "$T/stat.good" > "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"; awk '{$NF=$NF+1; print}' "$T/stat.good" > "$T/proc/123/stat" ) &
writer=$!
expect_unknown 'PID reused with changed kernel start ticks during sampling'; wait "$writer"
rm "$T/proc/123/stat" "$T/proc/123/comm"; cp "$T/stat.good" "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"
# PID record changes between identity reads, independently of process identity.
rm "$T/proc/123/stat" "$T/proc/123/comm"; mkfifo "$T/proc/123/stat" "$T/proc/123/comm"
( printf 'no-mistakes\n' > "$T/proc/123/comm"; cat "$T/stat.good" > "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"; printf '123\n' > "$T/nm/daemon.pid"; cat "$T/stat.good" > "$T/proc/123/stat" ) &
writer=$!
expect_unknown 'changed record'; wait "$writer"
rm "$T/proc/123/stat" "$T/proc/123/comm"; cp "$T/stat.good" "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"
# A config changed while the second identity read is pending is unknown.
cp "$T/record.good" "$T/nm/daemon.pid"
rm "$T/proc/123/stat" "$T/proc/123/comm"; mkfifo "$T/proc/123/stat" "$T/proc/123/comm"
( printf 'no-mistakes\n' > "$T/proc/123/comm"; cat "$T/stat.good" > "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"; touch "$T/nm/config.yaml"; cat "$T/stat.good" > "$T/proc/123/stat" ) &
writer=$!
expect_unknown 'config changed during sampling'; wait "$writer"
rm "$T/proc/123/stat" "$T/proc/123/comm"; cp "$T/stat.good" "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"
rm "$T/nm/daemon.pid"
mkdir "$T/emptyproc"; printf 'btime 1791107995\n' > "$T/emptyproc/stat"
assert_contains "$(FM_NM_PROC_ROOT="$T/emptyproc" "$HELPER" "$T/nm" pc)" '"status": "not_running"' 'verified absence'
expect_unknown 'missing record with running daemon'
pass 'distinct unknown cases never become current'

# Old alert paths still operate after all observations become current.
cp "$T/record.good" "$T/nm/daemon.pid"
cp "$T/server/daemon.pid" "$T/zenbook/daemon.pid"
for machine in nm server zenbook; do set_time "$machine" 1791107999000000000; done
export FIXTURE_MODE=idle
[ -z "$(check)" ] || fail 'first idle observation should only arm old idle episode'
assert_contains "$(check)" 'Q server has 0 working crewmates' 'A alert survives new hook'
export FIXTURE_MODE=storm
assert_contains "$(check)" 'remote message helpers jammed:' 'D alert survives new hook'
export FIXTURE_MODE=idle
printf 'paused [at=1791100000]: resource wait memory headroom\n' > "$T/home/state/lane.status"
assert_contains "$(check)" 'resource waits over 10 min:' 'B alert survives new hook'
rm "$T/home/state/lane.status"
unset FIXTURE_MODE
pass 'existing A/B/D alerts survive through the full custom check'
set_time nm 1791108020000000000
assert_episode_output "$(check)" "$warning"
[ -z "$(check)" ] || fail 'unchanged episode after clear repeats'
set_time nm 1791107999000000000
[ -z "$(check)" ] || fail 'cleared episode must be quiet'
pass 'cleared episode warns again on new evidence and stays deduplicated'

# Exercise the registration/snapshot public interface on the proposed hook.
FM_HOME="$T/home" "$ROOT/bin/fm-check-register.sh" server-idle-watch >/dev/null
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$ROOT/bin/fm-check-lib.sh"
fm_custom_check_snapshot_prepare "$T/home/state" server-idle-watch || fail 'snapshot rejected registered bytes'
[ "$(sha256sum "$FM_CUSTOM_CHECK_SNAPSHOT" | cut -d' ' -f1)" = "$(sha256sum "$T/home/state/server-idle-watch.check.sh" | cut -d' ' -f1)" ] || fail 'snapshot changed bytes'
rm -f "$T/home/state/.server-idle-watch-last-run"
out=$(PATH="$T/fakebin:$PATH" STATE="$T/home/state" NM_HOME="$T/nm" NM_HELPER="$HELPER" FM_NM_PROC_ROOT="$T/proc" /bin/bash "$FM_CUSTOM_CHECK_SNAPSHOT")
[ -z "$out" ] || fail 'registered snapshot should stay quiet with current configs'
fm_custom_check_snapshot_cleanup
printf '\n# intentional byte change\n' >> "$T/home/state/server-idle-watch.check.sh"
if fm_custom_check_snapshot_prepare "$T/home/state" server-idle-watch; then fail 'changed check accepted old registration'; fi
fm_custom_check_snapshot_cleanup
if rg -q 'restart| stop | update |config.yaml' "$T/commands"; then fail 'collector invoked lifecycle/config-value command'; fi
cmp "$T/config.good" "$T/nm/config.yaml" || fail 'sampling changed config bytes'
pass 'private byte registration and read-only collector'
