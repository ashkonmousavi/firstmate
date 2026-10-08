#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-checkpoint-publication)
ACTIVE_HOLDER=''
cleanup() {
  if [ -n "$ACTIVE_HOLDER" ]; then
    kill "$ACTIVE_HOLDER" 2>/dev/null || true
    wait "$ACTIVE_HOLDER" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT

new_home() {
  mkdir -p "$TMP_ROOT/$1/state" "$TMP_ROOT/$1/data" "$TMP_ROOT/$1/config"
  printf '%s\n' "$TMP_ROOT/$1"
}

test_minimal_wake_callers_preserve_options() {
  local option mode home
  for option in off on; do
    for mode in ordinary checkpoint; do
      home=$(new_home "minimal-$option-$mode")
      fm_run_timed 10 env -u FM_CHECKPOINT_DEADLINE FM_HOME="$home" bash -c '
        [ "$2" = off ] || set -u
        before=$-
        . "$1/bin/fm-wake-lib.sh"
        if [ "$3" = checkpoint ]; then FM_CHECKPOINT_DEADLINE=$(( $(date +%s) + 30 )); fi
        fm_wake_append check ordinary "check: ordinary caller" || exit 1
        marker="$STATE/.watcher-down"
        fm_recovery_marker_read "$marker" || exit 2
        fm_recovery_marker_ack "$marker" "${FM_RECOVERY_MARKER_TOKEN##*:}" || exit 3
        fm_recovery_marker_handover_snapshot "$marker" || exit 4
        token=$FM_RECOVERY_HANDOVER_TOKEN
        seq=$FM_RECOVERY_HANDOVER_SEQ
        fm_recovery_marker_publish "$marker" downtime || exit 5
        fm_recovery_marker_handover_restore "$marker" "$token" "$seq" || exit 6
        fm_recovery_marker_read "$marker" || exit 7
        [ "$FM_RECOVERY_MARKER_TOKEN" = "$token" ] || exit 8
        fm_recovery_marker_arm_check "$marker" || exit 9
        [ "$FM_RECOVERY_MARKER_ACTION" = recover ] || exit 10
        fm_recovery_marker_reopen_announced "$marker" || exit 11
        fm_recovery_marker_read "$marker" || exit 12
        case "$FM_RECOVERY_MARKER_TOKEN" in pending:downtime:*) ;; *) exit 13 ;; esac
        [ "$before" = "$-" ] || exit 14
      ' _ "$ROOT" "$option" "$mode" > "$home/out" 2> "$home/err" \
        || fail "minimal $option/$mode wake caller failed: $(cat "$home/err")"
      [ "$(awk -F '\t' '$3 == "check" && $4 == "ordinary" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] \
        || fail 'ordinary wake was lost or duplicated'
    done
  done
  pass 'minimal wake callers resolve checkpoint locking and retain shell options across recovery transitions'
}

test_captured_process_event_is_published() {
  local home output before
  home=$(new_home process-event)
  mkdir -p "$home/state/procevent-inbox"
  printf 'retained captured result\n' > "$home/state/procevent-inbox/demo.7.result"
  printf 'lavish\n' > "$home/state/procevent-inbox/demo.7.adapter"
  chmod 0600 "$home/state/procevent-inbox/demo.7."*
  output=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" \
    bash "$ROOT/bin/fm-procevent.sh" reconcile 2> "$home/reconcile.err") || fail 'process-event reconcile failed'
  assert_contains "$output" 'published=1 started=0' 'unhandled captured result was not published'
  [ "$(awk -F '\t' '$3 == "check" && $4 == "procevent:demo:7" {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] \
    || fail 'captured process-event wake was not queued once'
  assert_absent "$home/state/procevent-inbox/demo.7.handled" 'publication acknowledged captured work'
  FM_HOME="$home" bash "$ROOT/bin/fm-procevent.sh" handled demo 7 >/dev/null || fail 'process-event handling failed'
  before=$(cat "$home/state/.wake-queue")
  output=$(FM_HOME="$home" FM_PROCEVENT_CLAIM_ROOT="$home/claims" bash "$ROOT/bin/fm-procevent.sh" reconcile) \
    || fail 'handled process-event reconcile failed'
  assert_contains "$output" 'published=0 started=0' 'handled result was announced again'
  [ "$before" = "$(cat "$home/state/.wake-queue")" ] || fail 'handled result changed the queue'
  [ "$(cat "$home/state/procevent-inbox/demo.7.result")" = 'retained captured result' ] \
    || fail 'publication changed the durable capture'
  pass 'public process-event reconciliation publishes an ordinary capture until explicitly handled'
}

prepare_contention() {
  local home=$1 real_rm real_date
  real_rm=$(command -v rm)
  real_date=$(command -v date)
  mkdir -p "$home/fakebin"
  cat > "$home/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for path in "$@"; do
  if [ "$path" = "$FM_HOME/state/.wake-queue.lock" ] \
    && [ -s "$FM_HOME/state/.wake-queue" ] && [ ! -e "$FM_HOME/released" ]; then
    "$FM_REAL_RM" "$@" || exit $?
    : > "$FM_HOME/released"
    while [ ! -e "$FM_HOME/holder-ready" ]; do
      [ "$SECONDS" -lt 8 ] || exit 1
      sleep 0.01
    done
    exit 0
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  cat > "$home/fakebin/date" <<'SH'
#!/usr/bin/env bash
if [ -d "$FM_HOME/state/.seen-a_status" ] && [ -s "$FM_HOME/state/.seen-b_status" ]; then
  rmdir "$FM_HOME/state/.seen-a_status" || exit 1
  : > "$FM_HOME/commit-fault-restored"
fi
exec "$FM_REAL_DATE" "$@"
SH
  cat > "$home/fakebin/crew-state" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: run-step · fixture running\n'
SH
  chmod +x "$home/fakebin/"*
  printf '%s\n' "$real_rm" > "$home/real-rm"
  printf '%s\n' "$real_date" > "$home/real-date"
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    trap "fm_lock_release \"\$FM_WAKE_QUEUE_LOCK\"" EXIT
    while [ ! -e "$FM_HOME/released" ]; do
      [ "$SECONDS" -lt 10 ] || exit 1
      sleep 0.01
    done
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 2
    : > "$FM_HOME/holder-ready"
    while [ ! -e "$FM_HOME/release-holder" ]; do
      [ "$SECONDS" -lt 20 ] || exit 3
      sleep 0.01
    done
  ' _ "$ROOT" > "$home/holder.out" 2> "$home/holder.err" &
  ACTIVE_HOLDER=$!
}

run_checkpoint() {
  local home=$1 mode=${2:-normal}
  local -a arguments=()
  if [ "$mode" = fallback ]; then arguments+=("FM_CREW_STATE_BIN=$home/fakebin/crew-state"); fi
  STATUS=0
  fm_run_timed 12 env PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_TIMEOUT=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_REAL_RM="$(cat "$home/real-rm")" FM_REAL_DATE="$(cat "$home/real-date")" \
    ${arguments[@]+"${arguments[@]}"} bash "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 \
    > "$home/checkpoint.out" 2> "$home/checkpoint.err" || STATUS=$?
}

drain_and_ack() {
  local home=$1 seq generation
  FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh" > "$home/drained" 2> "$home/drain.err" || fail 'wake drain failed'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$home/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$home/drain.err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail 'missing generation acknowledgement'
  FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null \
    || fail 'generation acknowledgement failed'
}

test_partial_signal_publication_is_committed() {
  local kind home first later drained
  for kind in status turn-ended unreadable fallback; do
    home=$(new_home "partial-$kind")
    touch "$home/state/.last-check" "$home/state/.last-heartbeat" "$home/state/home-summary.json"
    case "$kind" in
      status)
        first=a.status; later=b.status
        printf 'done: first\n' > "$home/state/$first"
        printf 'done: later\n' > "$home/state/$later"
        ;;
      turn-ended)
        first=a.turn-ended; later=b.turn-ended
        printf 'finished\n' > "$home/state/$first"
        printf 'finished\n' > "$home/state/$later"
        ;;
      unreadable)
        first=a.status; later=b.turn-ended
        ln -s "$home/missing-status" "$home/state/$first"
        printf 'finished\n' > "$home/state/$later"
        ;;
      fallback)
        first=a.status; later=b.status
        printf 'working: first\n' > "$home/state/$first"
        printf 'working: later\n' > "$home/state/$later"
        mkdir "$home/state/.seen-a_status"
        ;;
    esac
    prepare_contention "$home"
    run_checkpoint "$home" "$kind"
    expect_code 124 "$STATUS" "partial $kind publication missed the clean bound: $(cat "$home/checkpoint.err")"
    [ -f "$home/holder-ready" ] || fail 'contention did not reach the post-publication acquisition'
    [ "$(awk -F '\t' -v key="$first" '$3 == "signal" && $4 == key {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 1 ] \
      || fail 'first file was not durably published exactly once before deferral'
    [ "$(awk -F '\t' -v key="$later" '$3 == "signal" && $4 == key {n++} END {print n+0}' "$home/state/.wake-queue")" -eq 0 ] \
      || fail 'contended later file was unexpectedly queued'
    if [ "$kind" = unreadable ]; then
      awk -F '\t' '$1 == "v2" && $3 == "-" {found=1} END {exit !found}' "$home/state/.seen-a_status" \
        || fail 'unreadable publication invented a classified endpoint'
    elif [ "$kind" = fallback ]; then
      [ -f "$home/commit-fault-restored" ] || fail 'the fallback did not exercise and restore its classification-commit failure'
    fi
    : > "$home/release-holder"
    wait "$ACTIVE_HOLDER" || fail "queue holder failed: $(cat "$home/holder.err")"
    ACTIVE_HOLDER=''
    drain_and_ack "$home"
    run_checkpoint "$home" "$kind"
    if [ "$kind" = fallback ]; then
      expect_code 124 "$STATUS" 'fallback re-published its acknowledged first file'
    else
      expect_code 0 "$STATUS" "deferred $kind signal did not resume: $(cat "$home/checkpoint.err")"
      drain_and_ack "$home"
      [ "$(awk -F '\t' -v key="$first" '$3 == "signal" && $4 == key {n++} END {print n+0}' "$home/drained")" -eq 0 ] \
        || fail 'acknowledged first signal was published again'
      [ "$(awk -F '\t' -v key="$later" '$3 == "signal" && $4 == key {n++} END {print n+0}' "$home/drained")" -eq 1 ] \
        || fail 'later signal was lost or duplicated'
    fi
    run_checkpoint "$home" "$kind"
    expect_code 124 "$STATUS" 'unchanged acknowledged signals resurfaced'
    drained=$(FM_HOME="$home" bash "$ROOT/bin/fm-wake-drain.sh")
    assert_not_contains "$drained" $'\tsignal\t' 'acknowledged signal left another queue row'
    if [ "$kind" = status ]; then
      printf 'done: new event\n' >> "$home/state/$first"
      run_checkpoint "$home"
      expect_code 0 "$STATUS" 'publication marker swallowed a later status append'
      drain_and_ack "$home"
      [ "$(awk -F '\t' -v key="$first" '$3 == "signal" && $4 == key {n++} END {print n+0}' "$home/drained")" -eq 1 ] \
        || fail 'later status append did not produce exactly one new delivery'
    fi
  done
  pass 'contended primary and fallback publication commit each successful file before deferral without duplicate acknowledgement'
}

test_minimal_wake_callers_preserve_options
test_captured_process_event_is_published
test_partial_signal_publication_is_committed
