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
expect_code 0 "$rc" 'PR handoff frees a place'
assert_contains "$out" 'free_lanes=1' 'secondmate holds no place'
pass 'machine ceiling spans local homes and projects; PR handoff and secondmates excluded'
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
  export PATH="$TMP_ROOT/fakebin:$PATH"
  coproc PARKED_SHELL { exec bash -c 'cd "$1"; printf "ready\n"; read -r _' bash "$TMP_ROOT/shell-worktree"; }
  parked_pid=$PARKED_SHELL_PID
  work_pid=
  trap 'kill "$parked_pid" ${work_pid:+"$work_pid"} 2>/dev/null || true; wait 2>/dev/null || true' EXIT
  read -r ready <&"${PARKED_SHELL[0]}"
  [ "$ready" = ready ] || fail 'parked shell did not start'
  fm_write_meta "$FM_HOME/state/parked.meta" kind=ship window=test:gone "worktree=$TMP_ROOT/shell-worktree"
  out=$(bash "$CAPACITY" --json) || fail 'shell-only capacity report failed'
  jq -e '.lanes == 0 and .free_lanes == 5' <<< "$out" >/dev/null || fail 'idle shell incorrectly holds a seat'
  (
    cd "$TMP_ROOT/shell-worktree" || exit 1
    exec sleep 60
  ) &
  work_pid=$!
  out=$(bash "$CAPACITY" --json) || fail 'non-shell capacity report failed'
  jq -e '.lanes == 1 and .free_lanes == 4' <<< "$out" >/dev/null || fail 'non-shell worktree process lost its seat'
  pass 'public capacity command frees shell-only records and counts non-shell work'
) || exit 1
