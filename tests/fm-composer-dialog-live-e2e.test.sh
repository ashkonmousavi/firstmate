#!/usr/bin/env bash
# Read-only live dialog guard. Supply exact tmux pane IDs (%N) for each
# installed harness in FM_DIALOG_{CLAUDE,CODEX}_{DIALOG,IDLE,PENDING,WORKING},
# plus FM_DIALOG_UNKNOWN for a plain shell pane with no composer.
# Preparing the panes is operator-owned: this guard never submits a prompt,
# answers a dialog, or restarts a shared server. FM_COMPOSER_DIALOG_LIVE=1
# requires all live inputs; =0 disables the guard.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate default-on FM_COMPOSER_DIALOG_LIVE tmux

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail 'live dialog guard: tmux adapter unavailable'

installed=0
missing=''
for harness in claude codex; do
  if ! command -v "$harness" >/dev/null 2>&1; then
    printf '# harness absent, not verified here: %s\n' "$harness"
    continue
  fi
  installed=$((installed + 1))
  version=$("$harness" --version 2>/dev/null | head -1)
  [ -n "$version" ] || fail "$harness: installed version unavailable"
  printf '# installed harness: %s (%s)\n' "$harness" "$version"
  upper=$(printf '%s' "$harness" | tr '[:lower:]' '[:upper:]')
  for state in DIALOG IDLE PENDING WORKING; do
    var="FM_DIALOG_${upper}_${state}"
    if [ -z "${!var:-}" ]; then
      missing="${missing}${missing:+; }$harness ($version): $var unavailable"
    fi
  done
done
if [ "$installed" -eq 0 ]; then
  case "${FM_COMPOSER_DIALOG_LIVE:-${FM_LIVE:-}}" in
    1) fail 'live dialog guard verified nothing; no installed harnesses' ;;
    *) printf 'skip: live: no installed dialog harnesses\n'; exit 0 ;;
  esac
fi
[ -n "${FM_DIALOG_UNKNOWN:-}" ] || missing="${missing}${missing:+; }FM_DIALOG_UNKNOWN unavailable"
[ -z "$missing" ] || fail "live dialog guard verified nothing; $installed installed harnesses; $missing"

lab=$(fm_test_tmproot fm-dialog-live)
export FM_COMPOSER_DIALOG_SINK="$lab/dialog"
checked=0

capture_live() {
  local target=$1 actual
  case "$target" in
    %*[!0-9]*|%|'') fail "$harness ($version): expected an exact tmux pane ID, got '$target'" ;;
    %*) ;;
    *) fail "$harness ($version): expected an exact tmux pane ID, got '$target'" ;;
  esac
  actual=$(tmux display-message -p -t "$target" '#{pane_id}' 2>/dev/null)
  [ "$actual" = "$target" ] || fail "$harness ($version): live pane $target unavailable"
  screen=$(fm_tmux_composer_capture "$target") || fail "$harness ($version): capture failed for $target"
  [ -n "$screen" ] || fail "$harness ($version): empty capture for $target"
}

for harness in claude codex; do
  command -v "$harness" >/dev/null 2>&1 || continue
  version=$("$harness" --version 2>/dev/null | head -1)
  upper=$(printf '%s' "$harness" | tr '[:lower:]' '[:upper:]')
  case "$harness" in
    claude) expected='Claude background-task exit picker' ;;
    codex) expected='Codex background-server settings dialog' ;;
  esac
  for state in DIALOG IDLE PENDING WORKING; do
    var="FM_DIALOG_${upper}_${state}"; target=${!var}
    capture_live "$target"
    identity=$(fm_backend_tmux_foreground_comms "$target")
    case "$identity" in
      *"$harness"*) ;;
      *) fail "$harness ($version): $state pane has no live foreground $harness process" ;;
    esac
    name=$(fm_composer_blocking_dialog "$screen")
    plain_name=$(fm_composer_blocking_dialog "$(printf '%s\n' "$screen" | fm_composer_strip_ansi)")
    verdict=$(fm_tmux_composer_state "$target")
    noted=$(fm_composer_blocking_dialog_noted || true)
    cursorless=$(fm_composer_classify_screen 'styled=1' "$screen")
    case "$state" in
      DIALOG)
        [ "$name" = "$expected" ] && [ "$plain_name" = "$expected" ] && [ "$noted" = "$expected" ] \
          && [ "$(fm_composer_blocking_dialog_noted)" = "$expected" ] \
          || fail "$harness ($version): live dialog not recognized (name='$name', noted='$noted')"
        [ "$verdict" != empty ] && [ "$cursorless" != empty ] \
          || fail "$harness ($version): a live dialog read as an empty composer"
        ;;
      *)
        [ -z "$name$plain_name$noted" ] && ! fm_composer_blocking_dialog_noted >/dev/null \
          || fail "$harness ($version): $state control misidentified as a dialog"
        case "$state:$verdict:$cursorless" in
          IDLE:empty:empty|PENDING:pending:pending) ;;
          WORKING:*)
            fm_pane_is_busy "$target" "$harness" \
              || fail "$harness ($version): WORKING control has no live busy signal"
            ;;
          *) fail "$harness ($version): $state control read $verdict/$cursorless" ;;
        esac
        ;;
    esac
    checked=$((checked + 1))
    pass "$harness ($version): live $state surface verified ($verdict/$cursorless)"
  done
done
capture_live "$FM_DIALOG_UNKNOWN"
[ "$(fm_tmux_composer_state "$FM_DIALOG_UNKNOWN")" = unknown ] \
  && ! fm_composer_blocking_dialog "$screen" >/dev/null \
  && ! fm_composer_blocking_dialog_noted >/dev/null \
  || fail 'live dialog guard: unrecognized pane did not remain unknown without a dialog'
[ "$checked" -gt 0 ] || fail 'live dialog guard verified nothing; refusing a vacuous pass'
pass "live dialog guard verified $checked harness surfaces and an unknown control"
