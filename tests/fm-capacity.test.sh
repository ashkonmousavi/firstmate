#!/usr/bin/env bash
# Machine-wide capacity reports, admission, publication and placement behavior.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity)
CAPACITY="$ROOT/bin/fm-capacity.sh"
PRESSURE_CAPTURE="$ROOT/tests/captures/capacity-pressure"
export FM_ACTIVITY_READER="$TMP_ROOT/activity.sh" FM_CAPACITY_ACTIVITY_FACTS="$TMP_ROOT/activity.json"
cat > "$FM_ACTIVITY_READER" <<'SH'
#!/usr/bin/env bash
cat "$FM_CAPACITY_ACTIVITY_FACTS"
SH
activity_reading() {
  jq -cn --argjson lanes "$1" --argjson target "$2" --argjson free "$3" \
    '{readable:true,lanes:$lanes,target:$target,free_lanes:$free}' > "$FM_CAPACITY_ACTIVITY_FACTS"
}
activity_reading 5 5 0
mkdir -p "$TMP_ROOT/home/"{state,config,data} "$TMP_ROOT/mate/"{state,config,data}
export FM_HOME="$TMP_ROOT/home" FM_CAPACITY_MEMINFO="$TMP_ROOT/meminfo"
printf '5 3\n' > "$FM_HOME/config/lane-capacity"
fm_test_machine_policy "$FM_HOME/config"
printf 'MemTotal: 16777216 kB\nMemAvailable: 4194304 kB\n' > "$FM_CAPACITY_MEMINFO"
printf -- '- mate - local (home: %s; scope: tests; projects: a; added 2026-09-01)\n' "$TMP_ROOT/mate" > "$FM_HOME/data/secondmates.md"
for n in 1 2 3; do
  fm_write_meta "$FM_HOME/state/task-$n.meta" kind=ship "project=project-$n"
done
for n in 4 5; do
  fm_write_meta "$TMP_ROOT/mate/state/task-$n.meta" kind=scout "project=project-$n"
done
fm_write_meta "$FM_HOME/state/mate.meta" kind=secondmate
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 75 "$rc" "sixth lane at ceiling five"
assert_contains "$out" 'lanes=5 target=5' 'all projects and local homes count'
printf 'pr=https://github.com/o/r/pull/1\n' >> "$TMP_ROOT/mate/state/task-5.meta"
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 75 "$rc" 'a ready PR does not hide a live or unknown worker'
activity_reading 4 5 1
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 0 "$rc" 'activity confirms a stopped worker frees a place despite its retained record'
assert_contains "$out" 'free_lanes=1' 'secondmate holds no place'
pass 'machine ceiling spans local homes and projects; handoffs count while live, secondmates excluded'
# External bots do not create local task records. A local walk cannot evade
# admission by naming itself after an exempt external bot.
fm_write_meta "$FM_HOME/state/local-walk.meta" kind=ship walk_owner=grok-bot
activity_reading 5 5 0
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 75 "$rc" 'ordinary local walk holds a lane'
rm "$FM_HOME/state/local-walk.meta"
activity_reading 4 5 1
out=$(bash "$ROOT/bin/fm-fleet-view.sh" --capacity) || fail 'activity facts failed'
assert_contains "$out" 'lanes=4 target=5' 'activity uses machine reading'
out=$(bash "$ROOT/bin/fm-fleet-ledger.sh" capacity --json) || fail 'ledger facts failed'
jq -e '.lanes == 4 and .target == 5 and .reserve_kb == 3145728' <<< "$out" >/dev/null || fail 'ledger facts differ'
pass 'activity, ledger and admission share facts; local walk markers do not bypass limits'

printf 'MemAvailable: 3145728 kB\n' > "$FM_CAPACITY_MEMINFO"
bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
expect_code 0 "$rc" 'exact reserve has zero headroom and is admissible'
printf 'MemAvailable: 356000 kB\n' > "$FM_CAPACITY_MEMINFO"
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 75 "$rc" 'low memory'
assert_contains "$out" 'reason=memory' 'memory refusal'
assert_contains "$out" 'available_kb=356000' 'measured memory reported'
pass 'memory reserve is fixed and refuses below zero headroom'
for bad in '' '5' '5 -1' '5 3 extra' 'NaN 3'; do
  printf '%s\n' "$bad" > "$FM_HOME/config/lane-capacity"
  fm_test_machine_policy "$FM_HOME/config"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" "invalid config: $bad"
  assert_contains "$out" "$FM_HOME/config/lane-capacity" 'bad file named'
done
rm "$FM_HOME/config/lane-capacity"
bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
expect_code 75 "$rc" 'missing declaration'
printf '5 3\n' > "$FM_HOME/config/lane-capacity"
fm_test_machine_policy "$FM_HOME/config"
for bad in '' 'MemAvailable: nope kB' 'MemAvailable: 4 MB' $'MemAvailable: 4 kB\nMemAvailable: 8 kB'; do
  printf '%s\n' "$bad" > "$FM_CAPACITY_MEMINFO"
  bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
  expect_code 75 "$rc" 'unreadable host reading'
done
printf 'MemAvailable: 4194304 kB\n' > "$FM_CAPACITY_MEMINFO"
if [ "$(id -u)" != 0 ]; then
  for denied in "$FM_HOME/config/lane-capacity" "$FM_CAPACITY_MEMINFO" "$FM_HOME/data/secondmates.md"; do
    chmod 000 "$denied"
    bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
    chmod 600 "$denied"
    expect_code 75 "$rc" "unreadable file: $denied"
  done
fi
pass 'missing and malformed machine facts refuse placement'
if [ "$(id -u)" != 0 ]; then
  printf '%s\n' schema=fm-secondmate-parent.v1 route=local "parent_home=$FM_HOME" > "$TMP_ROOT/mate/.fm-secondmate-parent"
  for denied in "$FM_HOME/data" "$TMP_ROOT/mate/data"; do
    for mode in 000 400 100; do
      chmod "$mode" "$denied"
      out=$(FM_HOME="$TMP_ROOT/mate" bash "$CAPACITY" --admit 2>&1); rc=$?
      expect_code 75 "$rc" "inaccessible registry parent: $denied mode $mode"
      assert_contains "$out" "$denied" 'registry parent refusal names the directory'
      FM_HOME="$TMP_ROOT/mate" bash "$CAPACITY" --publish >/dev/null 2>&1; rc=$?
      expect_code 1 "$rc" 'inaccessible registry parent publication fails'
      jq -e '.readable == false and .reason == "unreadable"' "$TMP_ROOT/mate/state/lane-capacity.json" >/dev/null || fail 'inaccessible registry parent published room'
      bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/mate/state/lane-capacity.json" >/dev/null 2>&1; rc=$?
      expect_code 75 "$rc" 'inaccessible registry parent never gets placement'
      chmod 755 "$denied"
    done
  done
  out=$(FM_HOME="$TMP_ROOT/mate" bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 0 "$rc" 'restored registry parents admit'
  assert_contains "$out" 'lanes=4 target=5' 'restored registry counts every holder'
  pass 'inaccessible root and nested registry parents refuse admission and placement'
fi
printf 'MemAvailable: 4194304 kB\n' > "$FM_CAPACITY_MEMINFO"
bash "$CAPACITY" --publish > "$TMP_ROOT/report.json" || fail 'publish failed'
jq -e '.schema == "fm-lane-capacity.v1" and .free_lanes == 1 and .headroom_kb == 1048576' "$FM_HOME/state/lane-capacity.json" >/dev/null || fail 'published facts wrong'
jq -e '.admitted == true and .reason == "ok"' "$FM_HOME/state/lane-capacity.json" >/dev/null || fail 'admitting machine must publish admitted=true'
cp "$FM_HOME/state/lane-capacity.json" "$TMP_ROOT/laptop.json"
printf 'MemAvailable: nope kB\n' > "$FM_CAPACITY_MEMINFO"
bash "$CAPACITY" --publish >/dev/null 2>&1; rc=$?
expect_code 1 "$rc" 'unreadable publication reports failure'
jq -e '.readable == false and .free_lanes == 0' "$FM_HOME/state/lane-capacity.json" >/dev/null || fail 'old good publication survived unreadable host'
jq -e '.admitted == false' "$FM_HOME/state/lane-capacity.json" >/dev/null || fail 'unreadable host must publish admitted=false'
printf 'MemAvailable: 4194304 kB\n' > "$FM_CAPACITY_MEMINFO"
jq '.machine="server" | .free_lanes=3 | .lanes=2 | .headroom_kb=2097152 | .mem_available_kb=5242880' "$TMP_ROOT/laptop.json" > "$TMP_ROOT/server.json"
out=$(bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/laptop.json" "$TMP_ROOT/server.json" "$TMP_ROOT/missing.json") || fail 'placement failed'
assert_contains "$out" 'Placement: server' 'machine with most room'
jq '.free_lanes=0 | .lanes=.target | .reason="full" | .admitted=false' "$TMP_ROOT/server.json" > "$TMP_ROOT/full.json"
bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/full.json" >/dev/null 2>&1; rc=$?
expect_code 75 "$rc" 'full machine never chosen'
jq '.readable=false' "$TMP_ROOT/server.json" > "$TMP_ROOT/unreadable.json"
out=$(bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/unreadable.json" "$TMP_ROOT/missing.json" 2>&1); rc=$?
expect_code 75 "$rc" 'unreadable machines never chosen'
jq '.generated_epoch=1' "$TMP_ROOT/laptop.json" > "$TMP_ROOT/stale.json"
bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/stale.json" >/dev/null 2>&1; rc=$?
expect_code 75 "$rc" 'stale machine never chosen'
pass 'published facts drive placement; full, unreadable and stale hosts refused'

(
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-backend.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-project-capacity-lib.sh"
  . "$ROOT/bin/fm-capacity-lib.sh"
  mkdir -p "$TMP_ROOT/live/"{state,config,data}
  FM_HOME="$TMP_ROOT/live"
  printf '5 3\n' > "$FM_HOME/config/lane-capacity"
  fm_test_machine_policy "$FM_HOME/config"
  for n in 1 2 3 4 5 6 7 8; do
    fm_write_meta "$FM_HOME/state/retained-$n.meta" kind=ship window=unknown "worktree=$TMP_ROOT/reused-copy"
  done
  activity_reading 3 5 2
  fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state" || fail 'canonical occupancy should admit'
  expect_code 3 "$FM_CAPACITY_LANES" 'retained metadata cannot replace the activity reading'
  expect_code 2 "$FM_CAPACITY_FREE" 'physical free seats come from the canonical reading'
  activity_reading 5 5 0
  fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state"; rc=$?
  expect_code 75 "$rc" 'a full activity reading refuses admission'
  [ "$FM_CAPACITY_REASON" = full ] || fail 'full canonical reading should name capacity'
  activity_reading 0 5 5
  fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state" || fail 'empty activity reading should admit'
  expect_code 0 "$FM_CAPACITY_LANES" 'dead records do not hold physical seats'
  for bad in '{}' '{"readable":false,"lanes":0,"target":5}' '{"readable":true,"lanes":-1,"target":5}' 'broken'; do
    printf '%s\n' "$bad" > "$FM_CAPACITY_ACTIVITY_FACTS"
    fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state"; rc=$?
    expect_code 75 "$rc" 'unreadable or malformed activity evidence refuses admission'
    [ "$FM_CAPACITY_REASON" = unreadable ] || fail 'bad activity evidence must stay unknown'
  done
  activity_reading 0 6 6
  fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state"; rc=$?
  expect_code 75 "$rc" 'mismatched activity target refuses admission'
  activity_reading 0 5 5
  FM_ACTIVITY_READER="$TMP_ROOT/missing-reader" fm_capacity_read "$FM_HOME" "$FM_HOME/config" "$FM_HOME/state"; rc=$?
  expect_code 75 "$rc" 'failed activity read refuses admission'
  pass 'capacity follows canonical activity facts and refuses unknown or inconsistent evidence'
) || exit 1

(
  . "$ROOT/tests/fixtures.sh"
  case_dir="$TMP_ROOT/relaunch"
  relaunch_home="$case_dir/home"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$relaunch_home" codex
  printf '1 0\n' > "$relaunch_home/config/lane-capacity"
  fm_test_machine_policy "$relaunch_home/config"
  for task in capacity-a capacity-b; do
    fm_git_worktree "$case_dir/project-$task" "$case_dir/wt-$task" "wt-$task"
    fm_test_spawn_brief "$relaunch_home" "$task"
  done
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [[ "$*" == *'#{pane_current_command}'* && "$*" == *'fm-capacity-b'* && "${CAPACITY_B_LIVE:-}" = 1 ]]; then
  printf 'codex\n'
  exit 0
fi
exec "${BASH_SOURCE[0]%/*}/tmux-original" "$@"
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"
  activity_reading 0 1 1
  export FM_FAKE_PANE_COMMAND=bash FM_FAKE_LAUNCH_LOG="$case_dir/launch.log"
  out=$(fm_test_run_spawn "$relaunch_home" "$case_dir/wt-capacity-a" "$fakebin" \
    capacity-a "$case_dir/project-capacity-a" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "initial worker A spawns: $out"
  export FM_FAKE_DUPLICATE_WINDOW=fm-capacity-a
  out=$(fm_test_run_spawn "$relaunch_home" "$case_dir/wt-capacity-b" "$fakebin" \
    capacity-b "$case_dir/project-capacity-b" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "stopped A frees its seat for B: $out"
  export FM_FAKE_DUPLICATE_WINDOW=$'fm-capacity-a\nfm-capacity-b' CAPACITY_B_LIVE=1
  activity_reading 1 1 0
  cp "$relaunch_home/state/capacity-a.meta" "$case_dir/prior.meta"
  : > "$FM_FAKE_LAUNCH_LOG"
  out=$(fm_test_run_spawn "$relaunch_home" "$case_dir/wt-capacity-a" "$fakebin" capacity-a --relaunch); rc=$?
  expect_code 75 "$rc" "direct relaunch refuses B's occupied seat: $out"
  cmp -s "$case_dir/prior.meta" "$relaunch_home/state/capacity-a.meta" || fail 'direct refusal changed stopped record'
  [ ! -s "$FM_FAKE_LAUNCH_LOG" ] || fail 'direct refusal delivered a launch'
  out=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$fakebin:$PATH" FM_HOME="$relaunch_home" HOME="$relaunch_home/user-home" \
    FM_FAKE_PANE_PATH="$case_dir/wt-capacity-a" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-control.sh" capacity-a relaunch --note 'continue stopped work' 2>&1); rc=$?
  expect_code 75 "$rc" "control relaunch preserves admission refusal: $out"
  cmp -s "$case_dir/prior.meta" "$relaunch_home/state/capacity-a.meta" || fail 'control refusal changed stopped record'
  [ ! -s "$FM_FAKE_LAUNCH_LOG" ] || fail 'control refusal delivered a launch'
  pass 'stopped A frees a ceiling-one seat for B; both relaunch entry points refuse A'
) || exit 1

activity_reading 0 5 5
make_probes() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  printf '#!/usr/bin/env bash\necho Darwin\n' > "$fakebin/uname"
  cat > "$fakebin/sysctl" <<SH
#!/usr/bin/env bash
case "\$2" in
  vm.loadavg) [ -n "$2" ] && echo "{ $2 1.00 1.00 }" ;;
  kern.memorystatus_level) [ -n "$3" ] && echo "$3" ;;
  hw.logicalcpu) [ -n "$4" ] && echo "$4" ;;
esac
SH
  printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/getconf"
  cat > "$fakebin/df" <<SH
#!/usr/bin/env bash
[ -n "$5" ] || exit 1
echo "Filesystem 1024-blocks Used Available Capacity Mounted"
echo "/dev/fake 999999999 1 $5 1% /"
SH
  chmod +x "$fakebin"/*
  printf '%s\n' "$fakebin"
}


(
  mkdir -p "$TMP_ROOT/probe-home/"{state,config,data}
  printf '5 3\n' > "$TMP_ROOT/probe-home/config/lane-capacity"
  fm_test_machine_policy "$TMP_ROOT/probe-home/config"
  fakebin=$(make_probes "$TMP_ROOT/high-probes" 99.50 9 8 1048576)
  out=$(PATH="$fakebin:$PATH" FM_HOME="$TMP_ROOT/probe-home" bash "$CAPACITY") || fail 'host probe report failed'
  assert_contains "$out" 'free_lanes=5 reason=ok lanes=0 target=5' 'host load is informational; disk satisfies its separate floor'
  assert_contains "$out" 'load1=99.50 cores=8 mem_free_pct=9 disk_free_mb=1024' 'upstream host fields are retained'
  fakebin=$(make_probes "$TMP_ROOT/unknown-probes" '' '' '' '')
  out=$(PATH="$fakebin:$PATH" FM_HOME="$TMP_ROOT/probe-home" bash "$CAPACITY") || fail 'optional display probes blocked independent resource reader'
  assert_contains "$out" 'load1=unknown cores=unknown mem_free_pct=unknown disk_free_mb=unknown' 'missing optional probes stay explicit'
  pass 'upstream host probes remain visible and never replace shared admission facts'
) || exit 1

test_cgroup_memory() {
  local FM_HOME="$TMP_ROOT/cgroup-home" FM_CAPACITY_MEMINFO="$TMP_ROOT/cgroup-meminfo"
  local FM_RESOURCE_CGROUP_FILE="$TMP_ROOT/self-cgroup" FM_RESOURCE_CGROUP_ROOT="$TMP_ROOT/cgroup"
  local out rc bad field
  export FM_HOME FM_CAPACITY_MEMINFO FM_RESOURCE_CGROUP_FILE FM_RESOURCE_CGROUP_ROOT
  mkdir -p "$FM_HOME/"{config,state,data} "$FM_RESOURCE_CGROUP_ROOT/crew/lane"
  printf '5 4\n' > "$FM_HOME/config/lane-capacity"
  fm_test_machine_policy "$FM_HOME/config"
  printf '0::/crew/lane\n' > "$FM_RESOURCE_CGROUP_FILE"
  printf 'MemAvailable: 67108864 kB\n' > "$FM_CAPACITY_MEMINFO"
  for group in "$FM_RESOURCE_CGROUP_ROOT/crew" "$FM_RESOURCE_CGROUP_ROOT/crew/lane"; do
    printf 'max\n' > "$group/memory.high"
    printf 'max\n' > "$group/memory.max"
    printf '4294967296\n' > "$group/memory.current"
    printf 'file 0\nshmem 0\nactive_file 0\ninactive_file 0\nfile_dirty 0\nfile_writeback 0\n' > "$group/memory.stat"
    cp "$PRESSURE_CAPTURE" "$group/memory.pressure"
  done
  printf '17179869184\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
  printf '21474836480\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.current"
  printf 'file 9663676416\nshmem 1073741824\nactive_file 4294967296\ninactive_file 4294967296\nfile_dirty 0\nfile_writeback 0\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
  out=$(bash "$CAPACITY" --json) || fail 'cache-heavy cgroup reading failed'
  jq -e '.reason == "ok" and .mem_available_kb == 4194304 and .reserve_kb == 4194304 and .headroom_kb == 0' <<< "$out" >/dev/null || fail 'clean active and inactive cache must leave exactly four GiB'
  pass 'cache-aware effective availability supplies reserve and hard floor on one snapshot'

  printf '8589934592\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/lane/memory.high"
  printf '16106127360\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
  printf '15032385536\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.current"
  printf 'file 0\nshmem 0\nactive_file 0\ninactive_file 0\nfile_dirty 0\nfile_writeback 0\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'one GiB enclosing balance refuses despite four GiB child balance'
  out=$(bash "$CAPACITY" --json) || fail 'resource refusal must remain readable'
  jq -e '.reason == "memory" and .readable == true and .admitted == false and .free_lanes == 5 and .mem_available_kb == 1048576 and .headroom_kb == -3145728' <<< "$out" >/dev/null || fail 'resource refusal must preserve physical free seats'
  printf '17179869184\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
  printf '18253611009\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.current"
  out=$(bash "$CAPACITY" --json) || fail 'over-limit ancestor must remain readable'
  jq -e '.mem_available_kb == -1048577 and .headroom_kb == -5242881' <<< "$out" >/dev/null || fail 'negative availability must round down to KiB'
  printf '11811160064\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.current"
  out=$(bash "$CAPACITY" --json) || fail 'ample ancestor balance must admit'
  jq -e '.headroom_kb == 0' <<< "$out" >/dev/null || fail 'child balance must still be limiting'

  for field in memory.high memory.max memory.current memory.stat memory.pressure; do
    cp "$FM_RESOURCE_CGROUP_ROOT/crew/$field" "$FM_RESOURCE_CGROUP_ROOT/$field"
  done
  printf '16106127360\n' > "$FM_RESOURCE_CGROUP_ROOT/memory.current"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'outermost finite ancestor must also constrain admission'
  rm "$FM_RESOURCE_CGROUP_ROOT/"memory.{high,max,current,stat,pressure}
  for field in memory.high memory.max; do
    for bad in '' broken; do
      printf '%s\n' "$bad" > "$FM_RESOURCE_CGROUP_ROOT/crew/$field"
      bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
      expect_code 75 "$rc" 'malformed ancestor limit refuses despite a readable child'
    done
    printf '17179869184\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/$field"
  done
  for bad in '' 'file nope' 'file 0' $'file 0\nshmem -1\nactive_file 0\ninactive_file 0\nfile_dirty 0\nfile_writeback 0'; do
    printf '%s\n' "$bad" > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
    bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
    expect_code 75 "$rc" 'missing or malformed required cache counters refuse'
  done
  rm "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'missing ancestor statistics refuse'
  assert_contains "$out" 'memory.stat' 'missing controller evidence named'
  printf 'file 0\nshmem 0\nactive_file 0\ninactive_file 0\nfile_dirty 0\nfile_writeback 0\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
  pass 'all finite ancestors constrain admission and require readable limits and cache counters'

  printf '4294967297\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/lane/memory.current"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'one byte below the reserve refuses'
  assert_contains "$out" 'headroom=-1 kB' 'sub-KiB reserve deficit reported'
  printf 'max\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/lane/memory.high"
  printf 'max\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
  printf 'max\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.max"
  printf 'MemAvailable: 8388608 kB\n' > "$FM_CAPACITY_MEMINFO"
  out=$(bash "$CAPACITY" --json) || fail 'unlimited cgroups must use host memory'
  jq -e '.mem_available_kb == 8388608 and .headroom_kb == 4194304' <<< "$out" >/dev/null || fail 'host fallback differs'
  printf '0::/\n' > "$FM_RESOURCE_CGROUP_FILE"
  out=$(bash "$CAPACITY" --json) || fail 'root without a controller must use host memory'
  jq -e '.mem_available_kb == 8388608' <<< "$out" >/dev/null || fail 'root fallback differs'
  printf '0::/crew/lane\n' > "$FM_RESOURCE_CGROUP_FILE"
  printf 'broken\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
  bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
  expect_code 75 "$rc" 'malformed controller evidence never falls back to host memory'
  if [ "$(id -u)" != 0 ]; then
    printf 'max\n' > "$FM_RESOURCE_CGROUP_ROOT/crew/memory.high"
    chmod 000 "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
    bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
    chmod 600 "$FM_RESOURCE_CGROUP_ROOT/crew/memory.stat"
    expect_code 75 "$rc" 'permission denied statistics refuse'
  fi
  pass 'reserve boundaries, host fallback and unreadable controller evidence remain safe'
}
test_cgroup_memory || exit 1


test_resource_policy() {
  local FM_HOME="$TMP_ROOT/resource-home" FM_CAPACITY_MEMINFO="$TMP_ROOT/resource-memory"
  local FM_CAPACITY_PRESSURE_FILE="$TMP_ROOT/resource-pressure" out rc
  export FM_HOME FM_CAPACITY_MEMINFO FM_CAPACITY_PRESSURE_FILE
  mkdir -p "$FM_HOME/"{config,state,data}
  printf '5 2\n' > "$FM_HOME/config/lane-capacity"
  fm_test_machine_policy "$FM_HOME/config"
  printf 'MemAvailable: 8388608 kB\n' > "$FM_CAPACITY_MEMINFO"
  printf 'full avg10=0.00 avg60=5.00 avg300=0.00 total=0\n' > "$FM_CAPACITY_PRESSURE_FILE"
  jq -n --arg path "$TMP_ROOT" '{schema:"fm-machine-admission.v1",memory_floor_gib:1.5,memory_full_avg60_max:5,disk_floor_gib:0,disk_paths:[$path]}' > "$FM_HOME/config/machine-admission.json"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'pressure threshold refuses direct shared admission'
  assert_contains "$out" 'reason=pressure' 'pressure is not a parser error'
  printf 'full avg10=0.00 avg60=4.99 avg300=0.00 total=0\n' > "$FM_CAPACITY_PRESSURE_FILE"
  out=$(bash "$CAPACITY" --json) || fail 'below pressure threshold should be readable'
  jq -e '.reason == "ok" and .memory_floor_kb == 1572864 and .reserve_kb == 2097152 and (.resource_policy_sha256 | length == 64)' <<< "$out" >/dev/null || fail 'floor and reserve must stay independent'
  printf 'MemAvailable: 2000000 kB\n' > "$FM_CAPACITY_MEMINFO"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'above floor but below reserve still refuses'
  printf 'MemAvailable: 8388608 kB\n' > "$FM_CAPACITY_MEMINFO"
  jq '.disk_floor_gib=999999' "$FM_HOME/config/machine-admission.json" > "$TMP_ROOT/policy-next"
  mv "$TMP_ROOT/policy-next" "$FM_HOME/config/machine-admission.json"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'real measured disk below configured floor refuses'
  assert_contains "$out" 'reason=disk' 'disk refusal is named'
  rm "$FM_HOME/config/machine-admission.json"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" 'missing numeric policy refuses'
  assert_contains "$out" 'machine-admission.json' 'missing policy named'
  for malformed in '{}' '{"schema":"wrong"}' '{"memory_full_avg60_max":101}' 'not-json'; do
    printf '%s\n' "$malformed" > "$FM_HOME/config/machine-admission.json"
    bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
    expect_code 75 "$rc" 'malformed numeric policy refuses'
  done
  pass 'shared admission enforces numeric policy without confusing floor and reserve'
}
test_resource_policy || exit 1
