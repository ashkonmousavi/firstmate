#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-lock-handoff)
real_sleep=$(command -v sleep)
real_mv=$(command -v mv)
mkdir -p "$TMP_ROOT/fakebin"
cat > "$TMP_ROOT/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 0.1 ] && [ ! -L "$FM_HANDOFF_LOCK" ]; then
  rm -f "$FM_HANDOFF_LOCK/pid"
  rmdir "$FM_HANDOFF_LOCK" || exit 1
fi
exec "$FM_HANDOFF_REAL_SLEEP" "$@"
SH
cat > "$TMP_ROOT/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *identity.tmp*)
    [ ! -e "$FM_HANDOFF_INTERRUPTED" ] || exec "$FM_HANDOFF_REAL_MV" "$@"
    printf '%s\n' "$FM_HANDOFF_MODE" > "$FM_HANDOFF_INTERRUPTED"
    case "$FM_HANDOFF_MODE" in
      term) kill -TERM "$PPID"; exit 1 ;;
      timeout) exec "$FM_HANDOFF_REAL_SLEEP" 30 ;;
    esac
    ;;
esac
exec "$FM_HANDOFF_REAL_MV" "$@"
SH
chmod +x "$TMP_ROOT/fakebin/sleep" "$TMP_ROOT/fakebin/mv"

for mode in normal term timeout; do
  dir="$TMP_ROOT/$mode"
  mkdir -p "$dir/state/.handoff.lock"
  "$real_sleep" 30 &
  holder=$!
  printf '%s\n' "$holder" > "$dir/state/.handoff.lock/pid"
  rc=0
  PATH="$TMP_ROOT/fakebin:$PATH" FM_STATE_OVERRIDE="$dir/state" \
    FM_HANDOFF_LOCK="$dir/state/.handoff.lock" FM_HANDOFF_MODE="$mode" \
    FM_HANDOFF_INTERRUPTED="$dir/interrupted" FM_HANDOFF_REAL_SLEEP="$real_sleep" \
    FM_HANDOFF_REAL_MV="$real_mv" bash -c '
      . "$1"
      fm_lock_acquire_wait_bounded "$2" 1 || exit 10
      fm_current_pid current || exit 17
      [ "$(cat "$2/pid")" = "$current" ] || exit 11
      [ "$(cat "$2/identity")" = "$(fm_pid_identity "$current")" ] || exit 12
      [ "$(cat "$3")" = "$4" ] || exit 13
      (
        if fm_lock_try_acquire "$2"; then exit 14; fi
        [ "$FM_LOCK_HELD_PID" = "$current" ] || exit 15
      ) || exit $?
      fm_lock_release "$2"
      [ ! -e "$2" ] && [ ! -L "$2" ] || exit 16
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$dir/state/.handoff.lock" \
      "$dir/interrupted" "$mode" || rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  [ "$rc" -eq 0 ] || fail "$mode handoff did not publish caller identity, exclude contenders, and release (rc=$rc)"
  pass "$mode handoff publishes caller identity before accepting ownership"
done
