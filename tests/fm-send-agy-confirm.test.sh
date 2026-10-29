#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-send-agy-confirm)

make_stubs() {
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_CASE_DIR/typed.log"
    elif [ "${1:-}" = Enter ]; then
      printf 'Enter\n' >> "$FM_CASE_DIR/enter.log"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_tty*) printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ ! -s "$FM_CASE_DIR/typed.log" ]; then
      printf '╭────╮\n│    │\n╰────╯\n'
      exit 0
    fi
    case "$FM_COMPOSER_MODE" in
      unknown-busy) printf '> \n? for shortcuts\n ⏺ 5s · esc to cancel · gemini-3.8-flash-low\n' ;;
      capture-failure) exit 1 ;;
      pending)
        count=$(wc -l < "$FM_CASE_DIR/enter.log")
        if [ "$count" -ge "$FM_ACCEPT_AT" ]; then
          printf '╭────╮\n│    │\n╰────╯\n'
        else
          printf '╭────────────╮\n│ typed text │\n╰────────────╯\n'
        fi ;;
    esac
    exit 0 ;;
  list-windows) printf 'win\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${1:-}" >> "$FM_CASE_DIR/sleep.log"
SH
  chmod +x "$fb/sleep"
}

run_send() {
  local name=$1 harness=$2 mode=$3 accept_at=$4
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/state"
  make_stubs "$CASE_DIR"
  : > "$CASE_DIR/enter.log"
  : > "$CASE_DIR/typed.log"
  : > "$CASE_DIR/sleep.log"
  fm_write_meta "$CASE_DIR/state/worker.meta" "window=sess:win" "harness=$harness"
  SEND_RC=0
  env FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0 \
    PATH="$CASE_DIR/fakebin:$PATH" FM_ROOT_OVERRIDE="$CASE_DIR" FM_HOME="$CASE_DIR" \
    FM_CASE_DIR="$CASE_DIR" FM_COMPOSER_MODE="$mode" FM_ACCEPT_AT="$accept_at" \
    "$SEND" sess:win 'Append steer1 line to notes.md' > "$CASE_DIR/out" 2> "$CASE_DIR/err" || SEND_RC=$?
}

for harness in agy claude codex; do
  run_send "$harness-fifth-enter" "$harness" pending 5
  expect_code 0 "$SEND_RC" "$harness typed send confirms a composer cleared on the fifth Enter"
  [ "$(wc -l < "$CASE_DIR/enter.log")" -eq 5 ] || fail "$harness must reach the fifth Enter"
  [ "$(grep -c '^2$' "$CASE_DIR/sleep.log")" -eq 5 ] || fail "$harness must wait two seconds after each Enter"
  [ "$(wc -l < "$CASE_DIR/typed.log")" -eq 1 ] || fail "$harness must type the message exactly once"
  pass "$harness typed send uses the fixed five-press two-second budget"

  run_send "$harness-never-accepted" "$harness" pending 6
  expect_code 3 "$SEND_RC" "$harness typed send preserves unconfirmed delivery when its budget expires"
  [ "$(wc -l < "$CASE_DIR/enter.log")" -eq 5 ] || fail "$harness must stop after five Enter presses"
  [ "$(grep -c '^2$' "$CASE_DIR/sleep.log")" -eq 5 ] || fail "$harness must spend five two-second waits"
  [ "$(wc -l < "$CASE_DIR/typed.log")" -eq 1 ] || fail "$harness must never retype pending text"
  assert_contains "$(cat "$CASE_DIR/err")" "submission is unconfirmed" "$harness exhausted budget must report uncertainty"
  pass "$harness typed send refuses to confirm text still pending after ten seconds"
done

for mode in unknown-busy capture-failure; do
  run_send "agy-$mode" agy "$mode" 1
  expect_code 1 "$SEND_RC" "an unreadable typed composer must not confirm delivery from a busy footer"
  assert_contains "$(cat "$CASE_DIR/err")" "not submitted" "an unknown typed verdict must fail loudly"
  assert_contains "$(cat "$CASE_DIR/err")" "verdict=unknown" "the refusal must identify the unknown verdict"
  [ "$(wc -l < "$CASE_DIR/typed.log")" -eq 1 ] || fail "an unreadable composer must not cause a duplicate typed message"
  pass "typed send rejects $mode without claiming submission"
done
