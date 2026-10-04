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
os.utime(p/'nm/config.yaml', ns=((start+1)*10**9,)*2)
(p/'proc/stat').write_text('btime '+str(start-5)+'\n')
fields=['S']+['0']*18+[str(5*os.sysconf('SC_CLK_TCK'))]
(p/'proc/123/stat').write_text('123 (no-mistakes) '+' '.join(fields)+'\n')
(p/'proc/123/comm').write_text('no-mistakes\n')
(p/'proc/123/status').write_text('Uid:\t'+('\t'.join([str(os.getuid())]*4))+'\n')
PY
sample() { FM_NM_PROC_ROOT="$T/proc" "$HELPER" "$T/nm" "${1:-pc}"; }
out=$(sample)
assert_contains "$out" '"status": "stale"' 'newer config must be stale'
pass 'strictly newer config is stale through public CLI'
mkdir -p "$T/home/state" "$T/fakebin"
cp "$ROOT/tests/fixtures/server-idle-watch.check.sh" "$T/home/state/server-idle-watch.check.sh"
chmod 700 "$T/home/state/server-idle-watch.check.sh"
cat > "$T/fakebin/ssh" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FIXTURE/commands"
if [ -n "${NM_HANG_HOST:-}" ]; then
  case "$*" in *"fixture-$NM_HANG_HOST"*) sleep 60;; esac
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
out=$(check)
assert_contains "$out" 'config newer than running daemon on: pc' 'existing check must warn before early returns'
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
set_time server 1791108002000000000
[ "$(check)" = "$warning, server" ] || fail 'server change must create one sorted warning'
cp "$T/nm/daemon.pid" "$T/record.good"
cp "$T/proc/123/stat" "$T/stat.good"
printf '{"pid":123,"started_at":"2026-10-04T10:00:03Z"}\n' > "$T/nm/daemon.pid"
python3 - "$T/proc/123/stat" <<'PY'
import os,sys
from pathlib import Path
p=Path(sys.argv[1]); f=p.read_text().split(); f[-1]=str(8*os.sysconf('SC_CLK_TCK')); p.write_text(' '.join(f))
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
set_time zenbook 1791108001000000000
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
set_time zenbook 1791108000000000000
for machine in server zenbook; do
  rm "$T/home/state/.server-idle-watch-nm-config-episode"
  out=$(NM_HANG_HOST="$machine" check) || fail "$machine timeout exceeded the check deadline"
  assert_contains "$out" "observation unavailable on: $machine" 'timed-out host remains visible'
  assert_contains "$out" "$warning" 'remote health and metadata timeouts must not suppress stale pc'
done
pass 'both remote timeout paths preserve stale pc within the watcher deadline'

expect_unknown() { assert_contains "$(sample)" '"status": "unavailable"' "$1 must be unavailable"; }
for record in '123' '{"pid":-1,"started_at":"2026-10-04T10:00:00Z"}' '{"pid":123,"started_at":"invalid"}' '{"pid":999,"started_at":"2026-10-04T10:00:00Z"}' '{"pid":123,"started_at":"2026-10-04T09:00:00Z"}'; do
  printf '%s\n' "$record" > "$T/nm/daemon.pid"; expect_unknown 'bad record/dead or reused PID'
done
cp "$T/record.good" "$T/nm/daemon.pid"
chmod 000 "$T/nm/config.yaml"; expect_unknown 'unreadable config'; chmod 600 "$T/nm/config.yaml"
mv "$T/nm/config.yaml" "$T/config.good"
ln -s "$T/config.good" "$T/nm/config.yaml"; expect_unknown 'symlink config'
rm "$T/nm/config.yaml"; cp "$T/config.good" "$T/nm/config.yaml"
# FIFO supplies two different kernel identities at the public proc-reader seam.
rm "$T/proc/123/stat" "$T/proc/123/comm"; mkfifo "$T/proc/123/stat" "$T/proc/123/comm"
( printf 'no-mistakes\n' > "$T/proc/123/comm"; cat "$T/stat.good" > "$T/proc/123/stat"; printf 'no-mistakes\n' > "$T/proc/123/comm"; sed 's/500$/800/' "$T/stat.good" > "$T/proc/123/stat" ) &
writer=$!
expect_unknown 'changed process identity'; wait "$writer"
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
