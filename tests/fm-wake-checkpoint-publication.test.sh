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
      # shellcheck disable=SC2016 # Variables expand in the child shell with its supplied arguments.
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

test_minimal_wake_callers_preserve_options
test_captured_process_event_is_published
