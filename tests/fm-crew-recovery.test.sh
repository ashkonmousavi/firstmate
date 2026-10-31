#!/usr/bin/env bash
# Startup recovery relaunches a dead ship or scout in this home when its
# recorded copy still holds unlanded work. bin/fm-crew-recovery-lib.sh owns the
# decision. bin/fm-bootstrap.sh's deferred network phase is the caller.
# These cases drive that function and, once, the bootstrap executable.
# They never invoke the real bin/fm-control.sh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-crew-recovery)
fm_git_identity fmtest fmtest@example.invalid
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH \
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID CMUX_SOCKET_PATH CMUX_TAB_ID CMUX_PANEL_ID 2>/dev/null || true

LOG="$TMP_ROOT/control.log"
CONTROL="$TMP_ROOT/control"
: > "$LOG"

cat > "$CONTROL" <<'SH'
#!/usr/bin/env bash
set -u
log=${FM_CREW_RECOVERY_LOG:?}
printf '%s\n%s\n%s\n%s\n\n' "$1" "$2" "$3" "${4-}" >> "$log"
if [ -n "${FM_CREW_RECOVERY_WAIT_TIMING:-}" ]; then
  i=0
  while ! grep -q 'secondmate-liveness' "$FM_TIMING_LOG" && [ "$i" -lt 300 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  grep -q 'secondmate-liveness' "$FM_TIMING_LOG" || exit 1
fi
rc=0
spec=${FM_CREW_RECOVERY_STUB_RC:-}
case ",$spec," in
  *",$1="*)
    rc=${spec#*"$1="}
    rc=${rc%%,*}
    ;;
esac
case "$rc" in
  ''|*[!0-9]*) rc=0 ;;
esac
exit "$rc"
SH
chmod +x "$CONTROL"

# make_tmux <dir> <mode>: a tmux whose recovery-grade read is dead, missing,
# alive, ambiguous, or unreadable. The recorded window under test is sess:win.
make_tmux() {
  local dir=$1 mode=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do
      case "\$a" in
        *pane_current_command*)
          case '$mode' in
            alive) printf '%s\n' claude ;;
            ambiguous) printf '%s\n' node ;;
            *) printf '%s\n' bash ;;
          esac
          exit 0
          ;;
      esac
    done
    exit 0
    ;;
  list-windows)
    case '$mode' in
      missing)
        printf '%s\n' 'no server running on /tmp/tmux-crew/default' >&2
        exit 1
        ;;
      unreadable)
        printf '%s\n' 'permission denied' >&2
        exit 1
        ;;
      absent-window)
        printf '%s\n' other
        exit 0
        ;;
      *)
        printf '%s\n' win
        exit 0
        ;;
    esac
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

plant_copy() {  # <mode> <dir>
  local mode=$1 dir=$2
  case "$mode" in
    dirty)
      fm_git_worktree "$dir/repo" "$dir/wt" task
      printf 'unlanded\n' > "$dir/wt/unlanded.txt"
      ;;
    clean)
      fm_git_worktree "$dir/repo" "$dir/wt" task
      ;;
    ahead)
      fm_git_worktree "$dir/repo" "$dir/wt" task
      printf 'unlanded\n' > "$dir/wt/unlanded.txt"
      git -C "$dir/wt" add unlanded.txt
      git -C "$dir/wt" commit -qm 'unlanded'
      ;;
    nobase)
      mkdir -p "$dir/wt"
      git -C "$dir/wt" init -q -b topic
      printf 'a\n' > "$dir/wt/README.md"
      git -C "$dir/wt" add README.md
      git -C "$dir/wt" commit -qm 'only topic'
      ;;
    unborn)
      mkdir -p "$dir/wt"
      git -C "$dir/wt" init -q -b main
      ;;
    *)
      fail "unknown copy mode $mode"
      ;;
  esac
}

write_task() {  # <file> <kind> <worktree> [window]
  local file=$1 kind=$2 wt=$3 window=${4-sess:win}
  if [ -n "$window" ]; then
    fm_write_meta "$file" "window=$window" "worktree=$wt" "kind=$kind"
  else
    fm_write_meta "$file" "worktree=$wt" "kind=$kind"
  fi
}

new_home() {  # <name>
  local home="$TMP_ROOT/$1/home"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

reset_log() {
  : > "$LOG"
}

run_sweep() {  # <home> <fakebin>
  local home=$1 fakebin=$2
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" \
    FM_CREW_RECOVERY_LOG="$LOG" \
    FM_CREW_RECOVERY_STUB_RC="${FM_CREW_RECOVERY_STUB_RC:-}" \
    bash -c 'set -u; . "$1"; fm_crew_recovery_sweep' _ \
    "$ROOT/bin/fm-crew-recovery-lib.sh"
}

assert_called() {
  grep -Fx -- "$1" "$LOG" >/dev/null || fail "$2"
}

assert_not_called() {
  if grep -Fx -- "$1" "$LOG" >/dev/null; then
    fail "$2"$'\n'"$(cat "$LOG")"
  fi
}

note_of() {
  awk -v id="$1" '
    prev3 == id && prev2 == "relaunch" && prev == "--note" { print; exit }
    { prev3 = prev2; prev2 = prev; prev = $0 }
  ' "$LOG"
}

# Dead endpoint, dirty copy, and a committed copy that is not in main.
# Both kinds relaunch. The note names the endpoint state and the unlanded copy.
# Nothing in the recorded copy is removed.
test_dead_unlanded_ship_and_scout_are_relaunched() {
  local home fakebin out rc note
  home=$(new_home dead-unlanded)
  plant_copy dirty "$TMP_ROOT/dead-unlanded/ship"
  plant_copy ahead "$TMP_ROOT/dead-unlanded/scout"
  write_task "$home/state/ship-dirty.meta" ship "$TMP_ROOT/dead-unlanded/ship/wt"
  write_task "$home/state/scout-ahead.meta" scout "$TMP_ROOT/dead-unlanded/scout/wt"
  fakebin=$(make_tmux "$TMP_ROOT/dead-unlanded" dead)
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  rc=$?
  [ "$rc" -eq 0 ] || fail "sweep exited $rc: $out"
  assert_contains "$out" "CREW_RECOVERY: relaunched ship-dirty after dead" \
    "a dead ship with a dirty copy was not relaunched"
  assert_contains "$out" "CREW_RECOVERY: relaunched scout-ahead after dead" \
    "a dead scout with commits outside main was not relaunched"
  assert_called ship-dirty "control was not asked to relaunch the dirty ship"
  assert_called scout-ahead "control was not asked to relaunch the ahead scout"
  note=$(note_of ship-dirty)
  assert_contains "$note" "endpoint state: dead" "the replacement was not told the endpoint state"
  assert_contains "$note" "unlanded work" "the replacement was not told the copy still holds work"
  assert_contains "$note" "Nothing was torn down" "the replacement was not told the copy was kept"
  [ -f "$TMP_ROOT/dead-unlanded/ship/wt/unlanded.txt" ] \
    || fail "the dirty file was removed"
  [ -f "$home/state/ship-dirty.meta" ] || fail "the ship record was removed"
  [ -f "$home/state/scout-ahead.meta" ] || fail "the scout record was removed"
  pass "dead ship and scout with unlanded work are relaunched in place"
}

# A worker its lane release stopped on purpose carries an active marker
# (bin/fm-lane-release-lib.sh): startup recovery leaves it for acceptance or an
# explicit relaunch even though its copy still reads unlanded (a squash-merged
# PR's head is never an ancestor of main). A marker from an earlier incarnation
# does not hide a genuinely dead worker.
test_released_worker_is_not_relaunched() {
  local home fakebin out
  home=$(new_home released)
  plant_copy ahead "$TMP_ROOT/released/ship"
  plant_copy ahead "$TMP_ROOT/released/old"
  fm_write_meta "$home/state/ship-released.meta" "window=sess:win" \
    "worktree=$TMP_ROOT/released/ship/wt" "kind=ship" "spawn_gen=s1000.1.1"
  printf 'fm-lane-release-v1\ntask=ship-released\nspawn_gen=s1000.1.1\nreleased_at=2000\nanchor=1900\nclass=merged-ship\nresult=released\n' \
    > "$home/state/ship-released.released"
  fm_write_meta "$home/state/ship-relaunched.meta" "window=sess:win" \
    "worktree=$TMP_ROOT/released/old/wt" "kind=ship" "spawn_gen=s3000.1.1"
  printf 'fm-lane-release-v1\ntask=ship-relaunched\nspawn_gen=s1000.1.1\nreleased_at=2000\nanchor=1900\nclass=merged-ship\nresult=released\n' \
    > "$home/state/ship-relaunched.released"
  fakebin=$(make_tmux "$TMP_ROOT/released" dead)
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  assert_not_called ship-released "startup recovery relaunched a worker its lane release stopped"
  assert_not_contains "$out" "ship-released" "a released worker must not be reported as recovered or failed"
  assert_called ship-relaunched "a stale marker from an earlier incarnation hid a dead worker"
  pass "startup recovery never relaunches a released worker, and ignores a stale marker"
}

test_missing_endpoint_with_unlanded_work_is_relaunched() {
  local home fakebin out
  home=$(new_home missing-unlanded)
  plant_copy dirty "$TMP_ROOT/missing-unlanded/ship"
  write_task "$home/state/ship-missing.meta" ship "$TMP_ROOT/missing-unlanded/ship/wt"
  fakebin=$(make_tmux "$TMP_ROOT/missing-unlanded" missing)
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  assert_contains "$out" "CREW_RECOVERY: relaunched ship-missing after missing" \
    "a missing endpoint with a dirty copy was not relaunched"
  note=$(note_of ship-missing)
  assert_contains "$note" "endpoint state: missing" "the replacement was not told the endpoint was missing"
  [ -f "$TMP_ROOT/missing-unlanded/ship/wt/unlanded.txt" ] || fail "the dirty file was removed"
  pass "a missing endpoint with unlanded work is relaunched"
}

test_no_unlanded_work_is_not_relaunched() {
  local home fakebin
  home=$(new_home no-unlanded)
  plant_copy clean "$TMP_ROOT/no-unlanded/clean"
  plant_copy nobase "$TMP_ROOT/no-unlanded/nobase"
  plant_copy unborn "$TMP_ROOT/no-unlanded/unborn"
  plant_copy clean "$TMP_ROOT/no-unlanded/report"
  plant_copy dirty "$TMP_ROOT/no-unlanded/linked-target"
  mkdir -p "$home/data/ship-report"
  printf 'findings\n' > "$home/data/ship-report/report.md"
  ln -s "$TMP_ROOT/no-unlanded/linked-target/wt" "$TMP_ROOT/no-unlanded/linked"
  write_task "$home/state/ship-clean.meta" ship "$TMP_ROOT/no-unlanded/clean/wt"
  write_task "$home/state/ship-nobase.meta" ship "$TMP_ROOT/no-unlanded/nobase/wt"
  write_task "$home/state/ship-unborn.meta" ship "$TMP_ROOT/no-unlanded/unborn/wt"
  write_task "$home/state/ship-report.meta" scout "$TMP_ROOT/no-unlanded/report/wt"
  write_task "$home/state/ship-link.meta" ship "$TMP_ROOT/no-unlanded/linked"
  fakebin=$(make_tmux "$TMP_ROOT/no-unlanded" dead)
  reset_log
  run_sweep "$home" "$fakebin" >/dev/null
  assert_not_called ship-clean "a clean copy already contained in main was relaunched"
  assert_not_called ship-nobase "a clean copy with no resolvable base was relaunched"
  assert_not_called ship-unborn "an unborn copy was relaunched"
  assert_not_called ship-report "a scout report outside the copy was treated as unlanded work"
  assert_not_called ship-link "a symlink copy was treated as proof of unlanded work"
  pass "unlanded work must be shown in the recorded copy itself"
}

test_base_ref_containment_controls_clean_recovery() {
  local home fakebin mode direction kind dir wt repo base old current out id
  home=$(new_home base-containment)
  fakebin=$(make_tmux "$TMP_ROOT/base-containment" dead)
  for mode in explicit default main master; do
    case "$mode" in
      explicit|default) base=curated ;;
      *) base=$mode ;;
    esac
    for direction in remote-newer local-newer; do
      dir="$TMP_ROOT/base-containment/$mode-$direction"
      plant_copy clean "$dir"
      wt="$dir/wt"
      repo="$dir/repo"
      old=$(git -C "$wt" rev-parse HEAD)
      printf 'base update\n' > "$wt/base-update.txt"
      git -C "$wt" add base-update.txt
      git -C "$wt" commit -qm 'advance base'
      current=$(git -C "$wt" rev-parse HEAD)
      if [ "$base" != main ]; then
        git -C "$repo" branch -m main "$base"
        git -C "$repo" update-ref -d refs/remotes/origin/main
      fi
      case "$direction" in
        remote-newer)
          git -C "$repo" update-ref "refs/remotes/origin/$base" "$current"
          git -C "$repo" update-ref "refs/heads/$base" "$old"
          ;;
        local-newer)
          git -C "$repo" update-ref "refs/heads/$base" "$current"
          git -C "$repo" update-ref "refs/remotes/origin/$base" "$old"
          ;;
      esac
      if [ "$mode" = default ]; then
        git -C "$repo" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$base"
      fi
      for kind in ship scout; do
        id="$mode-$direction-$kind"
        write_task "$home/state/$id.meta" "$kind" "$wt"
        [ "$mode" != explicit ] || printf 'base_branch=%s\n' "$base" >> "$home/state/$id.meta"
      done
    done
  done
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  [ ! -s "$LOG" ] || fail "a clean worker contained in an available base ref was relaunched: $out"
  for mode in explicit default main master; do
    for direction in remote-newer local-newer; do
      wt="$TMP_ROOT/base-containment/$mode-$direction/wt"
      printf 'worker change\n' > "$wt/worker-change.txt"
      git -C "$wt" add worker-change.txt
      git -C "$wt" commit -qm 'unlanded worker change'
    done
  done
  out=$(run_sweep "$home" "$fakebin")
  for mode in explicit default main master; do
    for direction in remote-newer local-newer; do
      for kind in ship scout; do
        id="$mode-$direction-$kind"
        assert_called "$id" "a worker ahead of both available base refs was skipped: $out"
      done
    done
  done
  pass "clean recovery checks both base refs and still recovers work ahead of both"
}

test_only_captain_hold_blocks_unowned_work() {
  local home fakebin id
  home=$(new_home terminal-records)
  plant_copy dirty "$TMP_ROOT/terminal-records/wt"
  fakebin=$(make_tmux "$TMP_ROOT/terminal-records" dead)
  for id in ship-done ship-failed ship-held; do
    write_task "$home/state/$id.meta" ship "$TMP_ROOT/terminal-records/wt/wt"
  done
  printf '%s\n' 'done [at=1]: finished' > "$home/state/ship-done.status"
  printf '%s\n' 'failed [at=1]: stopped' > "$home/state/ship-failed.status"
  printf '%s\n' 'captain-held [at=1]: waiting on a decision' > "$home/state/ship-held.status"
  reset_log
  run_sweep "$home" "$fakebin" >/dev/null
  for id in ship-done ship-failed; do
    assert_called "$id" "$id was excluded by a status event without an attributed run"
  done
  assert_not_called ship-held "the captain-held task was relaunched"
  # The dirty file path is wt/wt because plant_copy writes dir/wt.
  [ -f "$TMP_ROOT/terminal-records/wt/wt/unlanded.txt" ] || fail "a refused relaunch removed the dirty file"
  pass "unowned done and failed work recover while captain-held work stays held"
}

test_in_flight_records_are_relaunched() {
  local home fakebin id
  home=$(new_home in-flight)
  plant_copy dirty "$TMP_ROOT/in-flight/wt"
  fakebin=$(make_tmux "$TMP_ROOT/in-flight" dead)
  write_task "$home/state/ship-open.meta" ship "$TMP_ROOT/in-flight/wt/wt"
  for id in ship-paused ship-asking ship-blocked ship-working; do
    write_task "$home/state/$id.meta" ship "$TMP_ROOT/in-flight/wt/wt"
  done
  printf '%s\n' 'paused [at=1]: waiting on review' > "$home/state/ship-paused.status"
  printf '%s\n' 'needs-decision [at=1]: which name' > "$home/state/ship-asking.status"
  printf '%s\n' 'blocked [at=1]: forge unavailable' > "$home/state/ship-blocked.status"
  printf '%s\n' 'working [at=1]: editing' > "$home/state/ship-working.status"
  reset_log
  run_sweep "$home" "$fakebin" >/dev/null
  for id in ship-open ship-paused ship-asking ship-blocked ship-working; do
    assert_called "$id" "$id was not relaunched"
  done
  pass "an absent record and a worker wait stay eligible"
}

test_inconclusive_endpoints_are_not_relaunched() {
  local home fakebin mode id
  plant_copy dirty "$TMP_ROOT/inconclusive/wt"
  for mode in alive ambiguous unreadable; do
    id="ship-$mode"
    home=$(new_home "inconclusive-$mode")
    write_task "$home/state/$id.meta" ship "$TMP_ROOT/inconclusive/wt/wt"
    fakebin=$(make_tmux "$TMP_ROOT/inconclusive-$mode" "$mode")
    reset_log
    run_sweep "$home" "$fakebin" >/dev/null
    assert_not_called "$id" "an $mode endpoint was relaunched"
  done
  home=$(new_home inconclusive-rest)
  write_task "$home/state/ship-none.meta" ship "$TMP_ROOT/inconclusive/wt/wt" ""
  fm_write_meta "$home/state/ship-other.meta" \
    "backend=zellij" "window=sess:win" "worktree=$TMP_ROOT/inconclusive/wt/wt" "kind=ship"
  write_task "$home/state/mate-live.meta" secondmate "$TMP_ROOT/inconclusive/wt/wt"
  fakebin=$(make_tmux "$TMP_ROOT/inconclusive-rest" dead)
  reset_log
  run_sweep "$home" "$fakebin" >/dev/null
  assert_not_called ship-none "a record with no endpoint was relaunched"
  assert_not_called ship-other "an unverified backend was relaunched"
  assert_not_called mate-live "a secondmate was relaunched by crew recovery"
  pass "only a dead or missing ship or scout endpoint is recovery-grade"
}

test_foreign_and_unreadable_records_are_not_relaunched() {
  local home other fakebin out
  home=$(new_home foreign-home)
  other=$(new_home foreign-other)
  plant_copy dirty "$TMP_ROOT/foreign-home/wt"
  write_task "$other/state/ship-decoy.meta" ship "$TMP_ROOT/foreign-home/wt/wt"
  ln -s "$other/state/ship-decoy.meta" "$home/state/ship-decoy.meta"
  write_task "$home/state/ship-status-link.meta" ship "$TMP_ROOT/foreign-home/wt/wt"
  printf '%s\n' 'working [at=1]: go' > "$TMP_ROOT/foreign-home/real.status"
  ln -s "$TMP_ROOT/foreign-home/real.status" "$home/state/ship-status-link.status"
  write_task "$home/state/ship-status-dir.meta" ship "$TMP_ROOT/foreign-home/wt/wt"
  mkdir -p "$home/state/ship-status-dir.status"
  fakebin=$(make_tmux "$TMP_ROOT/foreign-home" dead)
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  assert_not_contains "$out" "ship-decoy" "a meta symlink was followed"
  assert_not_called ship-decoy "a meta symlink was relaunched"
  assert_not_called ship-status-link "a status symlink was trusted"
  assert_not_called ship-status-dir "a non-file status record was trusted"
  reset_log
  run_sweep "$other" "$fakebin" >/dev/null
  assert_called ship-decoy "the other home's own sweep should still see its own record"
  reset_log
  # A symlinked state path is a different home root and must not be scanned.
  mkdir -p "$TMP_ROOT/link-root"
  ln -s "$other/state" "$TMP_ROOT/link-root/state"
  PATH="$fakebin:$BASE_PATH" \
    FM_HOME="$TMP_ROOT/link-root" \
    FM_STATE_OVERRIDE="$TMP_ROOT/link-root/state" \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" \
    FM_CREW_RECOVERY_LOG="$LOG" \
    bash -c 'set -u; . "$1"; fm_crew_recovery_sweep' _ \
    "$ROOT/bin/fm-crew-recovery-lib.sh" >/dev/null
  assert_not_called ship-decoy "a symlinked state directory was scanned"
  pass "recovery stays inside this home and ignores records it cannot trust"
}

test_first_failure_stops_serial_recovery() {
  local home fakebin out rc detail
  home=$(new_home one-failure)
  plant_copy dirty "$TMP_ROOT/one-failure/wt"
  write_task "$home/state/a-first.meta" ship "$TMP_ROOT/one-failure/wt/wt"
  write_task "$home/state/b-next.meta" ship "$TMP_ROOT/one-failure/wt/wt"
  write_task "$home/state/c-last.meta" scout "$TMP_ROOT/one-failure/wt/wt"
  fakebin=$(make_tmux "$TMP_ROOT/one-failure" dead)
  for rc in 1 75; do
    reset_log
    export FM_CREW_RECOVERY_STUB_RC="a-first=$rc"
    out=$(run_sweep "$home" "$fakebin")
    unset FM_CREW_RECOVERY_STUB_RC
    if [ "$rc" = 75 ]; then detail=deferred; else detail=failed; fi
    assert_contains "$out" "CREW_RECOVERY: a-first: relaunch $detail after dead:" "the launch outcome was not reported"
    assert_called a-first "the first task was not attempted"
    assert_not_called b-next "recovery continued after a failed launch"
    assert_not_called c-last "recovery continued after a failed launch"
  done
  reset_log
  out=$(run_sweep "$home" "$fakebin")
  [ "$(awk 'NR % 5 == 1' "$LOG")" = $'a-first\nb-next\nc-last' ] || fail "the next pass did not recover remaining tasks in order: $out"
  [ -f "$home/state/a-first.meta" ] || fail "a failed relaunch removed the record"
  [ -f "$TMP_ROOT/one-failure/wt/wt/unlanded.txt" ] || fail "a failed relaunch removed the dirty file"
  pass "serial recovery stops at failure or deferral and leaves work for the next pass"
}

test_bootstrap_network_phase_runs_the_sweep() {
  local home fakebin fake_root out timing
  home=$(new_home compose)
  fake_root="$TMP_ROOT/compose/root"
  mkdir -p "$fake_root/bin" "$home/projects"
  printf '4242\n' > "$home/state/.lock"
  plant_copy dirty "$TMP_ROOT/compose/wt"
  fakebin=$(make_tmux "$TMP_ROOT/compose" dead)
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  timing="$TMP_ROOT/compose/timing.tsv"
  reset_log

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_STATE_OVERRIDE="$home/state" FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=4242 \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" FM_CREW_RECOVERY_LOG="$LOG" \
    FM_TIMING_LOG="$timing" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh")
  [ -z "$out" ] || fail "an empty home printed recovery output: $out"
  [ ! -s "$LOG" ] || fail "an empty home called control: $(cat "$LOG")"

  write_task "$home/state/ship-compose.meta" ship "$TMP_ROOT/compose/wt/wt"
  : > "$timing"
  export FM_CREW_RECOVERY_WAIT_TIMING=1
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_STATE_OVERRIDE="$home/state" FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=4242 \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" FM_CREW_RECOVERY_LOG="$LOG" \
    FM_TIMING_LOG="$timing" FM_TIMING_EPOCH_MS=0 \
    "$ROOT/bin/fm-bootstrap.sh")
  unset FM_CREW_RECOVERY_WAIT_TIMING
  assert_contains "$out" "CREW_RECOVERY: relaunched ship-compose after dead" \
    "the deferred bootstrap phase did not relaunch the dead ship"
  assert_called ship-compose "bootstrap did not invoke control relaunch"
  note=$(note_of ship-compose)
  assert_contains "$note" "unlanded work" "bootstrap did not pass a progress note"
  assert_grep 'crew-recovery' "$timing" "the crew recovery sweep was not timed"
  [ -f "$TMP_ROOT/compose/wt/wt/unlanded.txt" ] || fail "bootstrap removed the dirty file"

  reset_log
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_STATE_OVERRIDE="$home/state" FM_BOOTSTRAP_NETWORK=skip \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" FM_CREW_RECOVERY_LOG="$LOG" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "CREW_RECOVERY:" "the local half relaunched a crewmate"
  assert_not_called ship-compose "the local half called control"

  reset_log
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_STATE_OVERRIDE="$home/state" FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=4242 \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" FM_CREW_RECOVERY_LOG="$LOG" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_not_contains "$out" "CREW_RECOVERY:" "detect-only relaunched a crewmate"
  assert_not_called ship-compose "detect-only called control"

  reset_log
  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$fake_root" \
    FM_STATE_OVERRIDE="$home/state" FM_BOOTSTRAP_NETWORK=only \
    FM_BOOTSTRAP_NETWORK_LOCK_PID=111111 \
    FM_CREW_RECOVERY_CONTROL="$CONTROL" FM_CREW_RECOVERY_LOG="$LOG" \
    "$ROOT/bin/fm-bootstrap.sh")
  assert_contains "$out" "changed before dead-crewmate relaunch" \
    "a stale deferred worker did not name the crew sweep it skipped"
  assert_not_called ship-compose "a stale deferred worker relaunched a crewmate"
  pass "bootstrap runs crew recovery only on the authorized deferred pass"
}

test_dead_unlanded_ship_and_scout_are_relaunched
test_missing_endpoint_with_unlanded_work_is_relaunched
test_released_worker_is_not_relaunched
test_no_unlanded_work_is_not_relaunched
test_base_ref_containment_controls_clean_recovery
test_only_captain_hold_blocks_unowned_work
test_in_flight_records_are_relaunched
test_inconclusive_endpoints_are_not_relaunched
test_foreign_and_unreadable_records_are_not_relaunched
test_first_failure_stops_serial_recovery
test_bootstrap_network_phase_runs_the_sweep
