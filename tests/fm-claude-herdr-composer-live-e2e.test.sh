#!/usr/bin/env bash
# Read-only guard for the Claude composer rendered in an existing Herdr pane.
# Select an idle Claude pane with FM_CLAUDE_HERDR_COMPOSER_TARGET=session:workspace:pane.
# No pane, server, or agent lifecycle operation is performed here.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_HERDR_COMPOSER_LIVE herdr jq claude

. "$ROOT/bin/fm-backend.sh"

versions="Claude $(claude --version | head -1), $(herdr --version | head -1)"
fm_backend_source herdr || fail "$versions: cannot load Herdr adapter"
check_composer() {
  local target=$1 expected=$2 scroll=$3 text=$4 plain_expected=$5 capture_expected session pane identity offset verdict content ansi cap caps visible
  case "$target" in
    *:*:*) ;;
    *) fail "$versions: missing prepared $scroll $expected target" ;;
  esac
  session=${target%%:*}
  pane=${target#*:}
  identity=$(herdr agent get "$pane" --session "$session" 2>/dev/null \
    | jq -r '(.result.agent.agent // "") + "\t" + (.result.agent.agent_status // "")') \
    || fail "$versions: cannot read native identity for $target"
  case "$identity" in
    $'claude\tidle'|$'claude\tdone') ;;
    *) fail "$versions: $target needs idle Claude, got $identity" ;;
  esac
  offset=$(fm_backend_herdr_scroll_offset "$target") || fail "$versions: $target has no scroll metadata"
  if [ "$scroll" = scrolled ]; then
    [ "$offset" -gt 0 ] || fail "$versions: $target must be scrolled, offset=$offset"
  else
    [ "$offset" -eq 0 ] || fail "$versions: $target must be at the bottom, offset=$offset"
  fi
  verdict=$(fm_backend_composer_state herdr "$target")
  [ "$verdict" = "$expected" ] || fail "$versions: $target expected $expected, got $verdict"
  content=$(fm_backend_herdr_composer_content "$target") || fail "$versions: $target content proof failed"
  [ "$content" = "$text" ] || fail "$versions: $target content proof differs from the prepared draft"
  for ansi in 1 0; do
    cap=$(fm_backend_herdr_composer_capture "$target" "$ansi" "$offset") || fail "$versions: $target capture failed (ansi=$ansi)"
    caps=$(printf 'styled=%s\ncursor=0\nidentity=1' "$ansi")
    capture_expected=$expected
    [ "$ansi" = 1 ] || capture_expected=$plain_expected
    verdict=$(fm_composer_classify_screen "$caps" "$cap" '' "$identity")
    [ "$verdict" = "$capture_expected" ] || fail "$versions: $target ansi=$ansi expected $capture_expected, got $verdict"
    content=$(FM_COMPOSER_GHOST_LUMA_MAX=0 fm_composer_extract_selected_content "$caps" "$cap" "$identity") \
      || fail "$versions: $target ansi=$ansi content extraction failed"
    [ "$content" = "$text" ] || fail "$versions: $target ansi=$ansi content differs from the prepared draft"
    if [ "$scroll" = scrolled ]; then
      if [ "$ansi" = 1 ]; then
        visible=$(fm_backend_herdr_visible_capture_ansi "$target")
      else
        visible=$(fm_backend_herdr_visible_capture "$target")
      fi
      [ "$visible" != "$cap" ] || fail "$versions: $target does not separate history from the live bottom"
    fi
  done
  pass "$versions: $scroll $expected composer: ANSI=$expected, plain=$plain_expected; both content reads match the prepared draft"
}

check_composer "${FM_CLAUDE_HERDR_COMPOSER_TARGET:-}" empty unscrolled '' empty
check_composer "${FM_CLAUDE_HERDR_COMPOSER_SCROLLED_EMPTY_TARGET:-}" empty scrolled '' empty
[ -n "${FM_CLAUDE_HERDR_COMPOSER_PENDING_TEXT:-}" ] || fail "$versions: missing prepared pending draft text"
check_composer "${FM_CLAUDE_HERDR_COMPOSER_SCROLLED_PENDING_TARGET:-}" pending scrolled "$FM_CLAUDE_HERDR_COMPOSER_PENDING_TEXT" unknown
