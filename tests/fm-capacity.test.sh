#!/usr/bin/env bash
# Machine-wide capacity reports, admission, publication and placement behavior.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-capacity)
CAPACITY="$ROOT/bin/fm-capacity.sh"
mkdir -p "$TMP_ROOT/home/"{state,config,data} "$TMP_ROOT/mate/"{state,config,data}
export FM_HOME="$TMP_ROOT/home" FM_CAPACITY_MEMINFO="$TMP_ROOT/meminfo"
printf '5 3\n' > "$FM_HOME/config/lane-capacity"
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
rm "$TMP_ROOT/mate/state/task-5.meta"
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 0 "$rc" 'removed worker record frees a place'
assert_contains "$out" 'free_lanes=1' 'secondmate holds no place'
pass 'machine ceiling spans local homes and projects; handoffs count while live, secondmates excluded'
# External bots do not create local task records. A local walk cannot evade
# admission by naming itself after an exempt external bot.
fm_write_meta "$FM_HOME/state/local-walk.meta" kind=ship walk_owner=grok-bot
out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
expect_code 75 "$rc" 'ordinary local walk holds a lane'
rm "$FM_HOME/state/local-walk.meta"
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
assert_contains "$out" "$FM_CAPACITY_MEMINFO" 'reading named'
pass 'memory reserve is fixed and refuses below zero headroom'
for bad in '' '5' '5 -1' '5 3 extra' 'NaN 3'; do
  printf '%s\n' "$bad" > "$FM_HOME/config/lane-capacity"
  out=$(bash "$CAPACITY" --admit 2>&1); rc=$?
  expect_code 75 "$rc" "invalid config: $bad"
  assert_contains "$out" "$FM_HOME/config/lane-capacity" 'bad file named'
done
rm "$FM_HOME/config/lane-capacity"
bash "$CAPACITY" --admit >/dev/null 2>&1; rc=$?
expect_code 75 "$rc" 'missing declaration'
printf '5 3\n' > "$FM_HOME/config/lane-capacity"
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
cp "$FM_HOME/state/lane-capacity.json" "$TMP_ROOT/laptop.json"
printf 'MemAvailable: nope kB\n' > "$FM_CAPACITY_MEMINFO"
bash "$CAPACITY" --publish >/dev/null 2>&1; rc=$?
expect_code 1 "$rc" 'unreadable publication reports failure'
jq -e '.readable == false and .free_lanes == 0' "$FM_HOME/state/lane-capacity.json" >/dev/null || fail 'old good publication survived unreadable host'
printf 'MemAvailable: 4194304 kB\n' > "$FM_CAPACITY_MEMINFO"
jq '.machine="server" | .free_lanes=3 | .lanes=2 | .headroom_kb=2097152 | .mem_available_kb=5242880' "$TMP_ROOT/laptop.json" > "$TMP_ROOT/server.json"
out=$(bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/laptop.json" "$TMP_ROOT/server.json" "$TMP_ROOT/missing.json") || fail 'placement failed'
assert_contains "$out" 'Placement: server' 'machine with most room'
jq '.readable=false' "$TMP_ROOT/server.json" > "$TMP_ROOT/unreadable.json"
out=$(bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/unreadable.json" "$TMP_ROOT/missing.json" 2>&1); rc=$?
expect_code 75 "$rc" 'unreadable machines never chosen'
jq '.generated_epoch=1' "$TMP_ROOT/laptop.json" > "$TMP_ROOT/stale.json"
bash "$ROOT/bin/fm-place.sh" "$TMP_ROOT/stale.json" >/dev/null 2>&1; rc=$?
expect_code 75 "$rc" 'stale machine never chosen'
pass 'published facts drive placement; unreadable and stale hosts refused'

# Exercise the record loop through its public read API. Endpoint states are
# supplied at the existing backend boundary; cwd scans use real processes.
(
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-backend.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-project-capacity-lib.sh"
  . "$ROOT/bin/fm-capacity-lib.sh"
  mkdir -p "$TMP_ROOT/live/"{state,config,data} "$TMP_ROOT/empty-worktree"
  FM_HOME="$TMP_ROOT/live"
  printf '5 3\n' > "$TMP_ROOT/live/config/lane-capacity"
  fm_backend_agent_state() {
    case "$2" in
      live-*) printf alive ;;
      gone-*) printf missing ;;
      *) printf unreadable ;;
    esac
  }
  for n in 1 2; do
    fm_write_meta "$TMP_ROOT/live/state/dead-$n.meta" kind=ship "window=gone-$n" "worktree=$TMP_ROOT/empty-worktree"
  done
  for n in 1 2 3 4 5; do
    fm_write_meta "$TMP_ROOT/live/state/live-$n.meta" kind=ship "window=live-$n" "worktree=$TMP_ROOT/empty-worktree"
  done
  fm_capacity_read "$TMP_ROOT/live" "$TMP_ROOT/live/config" "$TMP_ROOT/live/state"; rc=$?
  expect_code 75 "$rc" 'five live workers fill ceiling despite dead records'
  expect_code 5 "$FM_CAPACITY_LANES" 'dead endpoints with no worktree process hold no seats'
  [ "$FM_CAPACITY_REASON" = full ] || fail 'live workers should fill ceiling'
  rm "$TMP_ROOT/live/state/live-5.meta"
  fm_capacity_read "$TMP_ROOT/live" "$TMP_ROOT/live/config" "$TMP_ROOT/live/state" || fail 'four live workers should admit'
  expect_code 1 "$FM_CAPACITY_FREE" 'dead records leave one seat free'
  fm_write_meta "$TMP_ROOT/live/state/unknown.meta" kind=ship window=unknown "worktree=$TMP_ROOT/empty-worktree"
  fm_capacity_read "$TMP_ROOT/live" "$TMP_ROOT/live/config" "$TMP_ROOT/live/state"; rc=$?
  expect_code 75 "$rc" 'unknown endpoint liveness holds a seat'
  expect_code 5 "$FM_CAPACITY_LANES" 'unknown record counted'
  rm "$TMP_ROOT/live/state/unknown.meta"
  pass 'capacity counts live endpoints, frees dead records, and retains unknowns'
) || exit 1

(
  mkdir -p "$TMP_ROOT/shell-home/"{state,config,data} "$TMP_ROOT/shell-worktree" "$TMP_ROOT/fakebin"
  FM_HOME="$TMP_ROOT/shell-home"
  export FM_HOME
  printf '5 3\n' > "$FM_HOME/config/lane-capacity"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/fakebin/tmux"
  chmod +x "$TMP_ROOT/fakebin/tmux"
  mkfifo "$TMP_ROOT/shell-input" "$TMP_ROOT/shell-ready"
  exec 3<> "$TMP_ROOT/shell-input"
  bash -c 'cd "$1"; printf "ready\n"; read -r _' bash "$TMP_ROOT/shell-worktree" \
    < "$TMP_ROOT/shell-input" > "$TMP_ROOT/shell-ready" &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  parked_pid=$!
  work_pid=
  trap 'kill "$parked_pid" ${work_pid:+"$work_pid"} 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  read -r ready < "$TMP_ROOT/shell-ready"
  [ "$ready" = ready ] || fail 'parked shell did not start'
  fm_write_meta "$FM_HOME/state/parked.meta" kind=ship window=test:gone "worktree=$TMP_ROOT/shell-worktree"
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" bash "$CAPACITY" --json) || fail 'shell-only capacity report failed'
  jq -e '.lanes == 0 and .free_lanes == 5' <<< "$out" >/dev/null || fail 'idle shell incorrectly holds a seat'
  (
    cd "$TMP_ROOT/shell-worktree" || exit 1
    exec sleep 60
  ) &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  work_pid=$!
  out=$(PATH="$TMP_ROOT/fakebin:$PATH" bash "$CAPACITY" --json) || fail 'non-shell capacity report failed'
  jq -e '.lanes == 1 and .free_lanes == 4' <<< "$out" >/dev/null || fail 'non-shell worktree process lost its seat'
  pass 'public capacity command frees shell-only records and counts non-shell work'
) || exit 1

(
  . "$ROOT/tests/fixtures.sh"
  case_dir="$TMP_ROOT/relaunch"
  relaunch_home="$case_dir/home"
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$relaunch_home" codex
  printf '1 0\n' > "$relaunch_home/config/lane-capacity"
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
  export FM_FAKE_PANE_COMMAND=bash FM_FAKE_LAUNCH_LOG="$case_dir/launch.log"
  out=$(fm_test_run_spawn "$relaunch_home" "$case_dir/wt-capacity-a" "$fakebin" \
    capacity-a "$case_dir/project-capacity-a" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "initial worker A spawns: $out"
  export FM_FAKE_DUPLICATE_WINDOW=fm-capacity-a
  out=$(fm_test_run_spawn "$relaunch_home" "$case_dir/wt-capacity-b" "$fakebin" \
    capacity-b "$case_dir/project-capacity-b" --mode no-mistakes --yolo off); rc=$?
  expect_code 0 "$rc" "stopped A frees its seat for B: $out"
  export FM_FAKE_DUPLICATE_WINDOW=$'fm-capacity-a\nfm-capacity-b' CAPACITY_B_LIVE=1
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
  fakebin=$(make_probes "$TMP_ROOT/high-probes" 99.50 9 8 1048576)
  out=$(PATH="$fakebin:$PATH" FM_HOME="$TMP_ROOT/probe-home" bash "$CAPACITY") || fail 'host probe report failed'
  assert_contains "$out" 'free_lanes=5 reason=ok lanes=0 target=5' 'host load and disk probes are informational'
  assert_contains "$out" 'load1=99.50 cores=8 mem_free_pct=9 disk_free_mb=1024' 'upstream host fields are retained'
  fakebin=$(make_probes "$TMP_ROOT/unknown-probes" '' '' '' '')
  out=$(PATH="$fakebin:$PATH" FM_HOME="$TMP_ROOT/probe-home" bash "$CAPACITY") || fail 'unknown optional probes blocked admission'
  assert_contains "$out" 'load1=unknown cores=unknown mem_free_pct=unknown disk_free_mb=unknown' 'missing optional probes stay explicit'
  pass 'upstream host probes remain visible and never replace shared admission facts'
) || exit 1
