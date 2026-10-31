#!/usr/bin/env bash
# fm-tmux-lib.sh — shared tmux pane primitives for firstmate.
#
# ONE tmux source for delivery-busy detection, composer capture primitives,
# and verified submit.
# Both the away-mode daemon and bin/fm-send.sh reach these primitives through
# backend dispatch, while bin/fm-composer-lib.sh owns the shared verdict.
#
# Composer shapes and verdicts are owned by bin/fm-composer-lib.sh.
# This file owns only tmux's styled capture, cursor and Pi identity primitives,
# delivery busy read, and submit confirmation that consumes the shared verdict.
# Styled captures remain internal; fm-peek and every human-facing capture stay
# plain.
#
# Submit confirmation requires a cleared composer or a matching prompt receipt
# under bin/fm-busy-lib.sh's submit-signal contract. Busy state alone cannot
# distinguish an accepted prompt from an unrelated turn with an unsent draft.
#
# FM_COMPOSER_IDLE_RE is interpreted by the shared classifier with its structural
# and styling safety gates.
# FM_BUSY_REGEX overrides the rendered delivery-busy matching used here.
#
# NOT a task-state source: task busy state is owned by bin/fm-busy-lib.sh's
# semantic contract. The matching below serves composer identity and the
# away-mode supervisor-pane busy guard, not submit acknowledgement. Both ask about
# the pane receiving input, not the state of a recorded worker task. Matching
# stays harness-scoped so one harness's output cannot make another read busy.
#
# All functions are `set -u` and `set -e` safe (guarded tmux calls, explicit
# returns) so they can be sourced into either context.
#
# Composer classification is NOT owned here: every shape, glyph, border
# family, geometry rule, and verdict decision lives in the shared
# bin/fm-composer-lib.sh (fm_composer_classify_screen), sourced below and
# reused by every backend adapter so the decision cannot drift. This file
# keeps only tmux's genuine capture-side primitives - the styled pane
# capture, the #{cursor_y} cursor read, the pi foreground-process identity
# probe, and the capability descriptor - plus the busy detection and submit
# cores that consume the shared verdict.

# The sibling directory is derived without forking dirname, because a backend
# probe can re-source this adapter inside a subshell on every watcher cycle.
_FM_TMUX_LIB_DIR=${BASH_SOURCE[0]%/*}
[ "$_FM_TMUX_LIB_DIR" != "${BASH_SOURCE[0]}" ] || _FM_TMUX_LIB_DIR=.
# shellcheck source=bin/fm-composer-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-composer-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-cursor-lib.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "${_FM_TMUX_LIB_DIR:-/}/fm-busy-lib.sh"
unset _FM_TMUX_LIB_DIR


# fm_tmux_strip_ghost: thin adapter over the shared, fleet-wide ghost extractor
# fm_composer_strip_ghost (bin/fm-composer-lib.sh). It drops de-emphasised
# ghost/placeholder runs - dim/faint (SGR 2, claude's/codex's/cursor's ghost) AND a
# dark/muted truecolor foreground (grok's placeholder) - from one captured,
# styled composer line and prints the plain, real-typed text. Kept as a named
# tmux entry point (and for existing callers/tests) but owns no logic of its own,
# so the tmux and herdr adapters cannot drift apart on what counts as ghost text.
fm_tmux_strip_ghost() { fm_composer_strip_ghost; }

# --- tmux composer capture and capability primitives ------------------------
#
# These four functions are the ONLY tmux-specific composer knowledge left:
# how to capture a styled screen, how to read the cursor row, how to probe a
# live pi agent, and the static capability facts. Every shape, glyph, border
# family, and verdict decision lives in the shared owner
# (bin/fm-composer-lib.sh, fm_composer_classify_screen), so a new harness
# shape is taught there once and never here.

# fm_tmux_composer_capture: the visible pane WITH ANSI styling. The styled
# capture is consumed internally by the classifier and is NEVER surfaced
# (fm-peek and every human/LLM-facing path stay plain).
fm_tmux_composer_capture() {  # <target>
  tmux capture-pane -e -p -t "$1" -S 0 -E - 2>/dev/null
}

# fm_tmux_composer_cursor_row: the pane's cursor row, zero-based, relative to
# the visible pane - tmux's genuine primitive that no other backend has.
fm_tmux_composer_cursor_row() {  # <target>
  tmux display-message -p -t "$1" '#{cursor_y}' 2>/dev/null
}

# fm_tmux_composer_caps: the tmux capability descriptor - static data, not
# logic (see the capability model in bin/fm-composer-lib.sh).
fm_tmux_composer_caps() {
  printf 'styled=1\ncursor=1\nidentity=1\nrows=0\n'
}

# fm_tmux_composer_identity: the tmux agent-identity probe backing the
# separated (pi) composer shape, tmux's analogue of herdr's native
# `agent get`. It answers only for the verified owners of that shape, from
# two live signals:
#   - identity: the pane tty's FOREGROUND process group (pgid = tpgid, the
#     same scoping as fm_backend_tmux_foreground_comms) contains a
#     shape-owner process (pi, pi-signed, pi-launcher - docs/verification/
#     runtime-backends.md "Agent liveness name sources"; polytoken, whose
#     TUI pane foreground is comm `polytoken`, verified live on 0.8.19),
#     falling back to tmux's own foreground-derived #{pane_current_command}.
#     A pane whose agent died to a shell has no shape-owner foreground
#     process and gets NO identity, which is exactly what keeps the strict
#     blank-row rule honest: a blank row between two stale rules stays
#     unknown.
#   - status: the shape owner's verified busy footer via fm_pane_is_busy,
#     mapped onto the idle/working vocabulary herdr's probe reports natively.
# It answers Command Code the same way, from its anchored `command-code`
# foreground process name and its own verified busy footer: its composer is a
# bare `❯` row between the same two rules, and its placeholder needs the
# identity-scoped ghost ceiling in bin/fm-composer-lib.sh.
# Prints "<owner><TAB>idle" or "<owner><TAB>working" for owner pi,
# polytoken, or commandcode; exits 1 when the pane is not a live shape owner.
fm_tmux_composer_identity() {  # <target>
  local target=$1 tty pgid tpgid comm owner='' status
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || tty=
  case "$tty" in
    /dev/*)
      while read -r _ pgid tpgid comm; do
        [ -n "$comm" ] || continue
        [ "$pgid" = "$tpgid" ] || continue
        case "${comm##*/}" in
          pi|pi-signed|pi-launcher|Pi) owner=pi ;;
          polytoken) owner=polytoken ;;
          command-code) owner=commandcode ;;
        esac
        [ -n "$owner" ] && break
      done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
      ;;
  esac
  if [ -z "$owner" ]; then
    comm=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null) || comm=
    case "${comm##*/}" in
      pi|pi-signed|pi-launcher) owner=pi ;;
      polytoken) owner=polytoken ;;
    esac
  fi
  [ -n "$owner" ] || return 1
  # The busy footer read is scoped to the matched owner's own harness
  # signature (pi for the pi family, polytoken's `Running for` row, Command
  # Code's own footer) so one owner's ordinary output can never acknowledge
  # another's pane.
  status=$(fm_pane_busy_state "$target" "$owner")
  case "$status" in
    busy) printf '%s\tworking' "$owner" ;;
    idle) printf '%s\tidle' "$owner" ;;
    *) return 1 ;;
  esac
}

# fm_tmux_composer_state: the tmux composer verdict - a thin adapter over the
# shared screen classifier. The verdict contract (empty | pending |
# pending-unproven | unknown, positive proof required for empty, unrecognized
# future verdicts failing safe) is owned by bin/fm-composer-lib.sh. Identity
# is fetched lazily, only when the classifier reports the verdict depends on
# it (a pi separator pair under the cursor) or the cursor-anchored read is
# `unknown` (the Command Code check below), so an `unknown` read pays one
# process probe and a definite read never does.
fm_tmux_composer_state() {  # <target> -> empty|pending|pending-unproven|unknown
  local target=$1 cy pane verdict identity
  cy=$(fm_tmux_composer_cursor_row "$target") || { printf 'unknown'; return 0; }
  case "$cy" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  pane=$(fm_tmux_composer_capture "$target") || { printf 'unknown'; return 0; }
  verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy")
  if [ "$verdict" = need-identity ]; then
    if ! identity=$(fm_tmux_composer_identity "$target") || [ -z "$identity" ]; then
      identity='probe-absent'
    fi
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" "$cy" "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  # Cursor Agent CLI parks its terminal cursor OUTSIDE its composer, below the
  # footer, with #{cursor_flag} 0 - so on a Cursor pane tmux's cursor row is not
  # a composer locator and the cursor-anchored read can only ever answer
  # `unknown`. Reclassify that pane the way every cursorless backend already
  # classifies it, letting the bottom-most shape win, which is the same rule
  # herdr, zellij, cmux, and orca use for every harness including this one.
  # Gated on Cursor's own structural process identity, never on the verdict
  # alone, so the strict blank-row posture that owns `unknown` for every other
  # harness is untouched.
  if [ "$verdict" = unknown ] && fm_tmux_pane_is_cursor "$target"; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '')
  fi
  # Command Code parks its terminal cursor below its footer too, drawing its
  # own reverse-video cursor cell in the composer (verified live, Command Code
  # 1.74.1), so it takes the same cursorless reclassification, gated on its own
  # process identity and read with that identity.
  if [ "$verdict" = unknown ] && identity=$(fm_tmux_composer_identity "$target") \
     && [ "${identity%%$'\t'*}" = commandcode ]; then
    verdict=$(fm_composer_classify_screen "$(fm_tmux_composer_caps)" "$pane" '' "$identity")
    [ "$verdict" != need-identity ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

# fm_tmux_pane_is_cursor: true when the pane's FOREGROUND process group contains
# a genuine Cursor Agent CLI process. Cursor runs as a bundled node script, so
# tmux's own #{pane_current_command} reports a bare `node`; identity therefore
# comes from Cursor's name or install tree in the command path or argv[0], whose
# single owner is bin/fm-cursor-lib.sh. The foreground scoping (pgid = tpgid)
# matches fm_tmux_composer_identity, so a pane whose agent exited to a shell has
# no Cursor foreground process and gets no reclassification.
fm_tmux_pane_is_cursor() {  # <target>
  local target=$1 tty pid pgid tpgid comm args argv0
  tty=$(tmux display-message -p -t "$target" '#{pane_tty}' 2>/dev/null) || return 1
  case "$tty" in /dev/*) ;; *) return 1 ;; esac
  while read -r pid pgid tpgid comm; do
    [ -n "$comm" ] || continue
    [ "$pgid" = "$tpgid" ] || continue
    args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || args=
    args=${args#"${args%%[![:space:]]*}"}
    argv0=${args%%[[:space:]]*}
    fm_cursor_process_matches "$comm" '' "$argv0" && return 0
  done <<EOF
$(LC_ALL=C ps -t "${tty#/dev/}" -o pid=,pgid=,tpgid=,comm= 2>/dev/null)
EOF
  return 1
}

# fm_pane_input_pending: 0 when the composer is not proven empty, so pending
# text, ambiguous structure, unreadable state, and future verdicts all defer.
fm_pane_input_pending() {  # <target>
  [ "$(fm_tmux_composer_state "$1")" != empty ]
}

# fm_pane_is_busy: 0 if the pane's last few non-blank lines show a busy footer
# (an agent mid-turn). Scans a 40-line tail like fm-watch.sh.
fm_pane_busy_state() {  # <target> [harness] -> busy|idle|unknown
  local win=$1 harness=${2:-} tail40 visible
  tail40=$(tmux capture-pane -p -t "$win" -S -40 2>/dev/null) \
    || { printf 'unknown'; return 0; }
  visible=$(printf '%s' "$tail40" | grep -v '^[[:space:]]*$' | tail -12)
  [ -n "$visible" ] || { printf 'unknown'; return 0; }
  if printf '%s' "$visible" | fm_busy_lines_match "$harness"; then
    printf 'busy'
  else
    printf 'idle'
  fi
}

fm_pane_is_busy() {  # <target> [harness]
  [ "$(fm_pane_busy_state "$1" "${2:-}")" = busy ]
}

fm_tmux_submit_enter_core() {
  local target=$1 retries=$2 sleep_s=$3 i=0 state
  while [ "$i" -lt "$retries" ]; do
    if declare -F fm_control_lane_release_guard >/dev/null; then fm_control_lane_release_guard || return 75; fi
    tmux send-keys -t "$target" Enter 2>/dev/null || { printf 'send-failed'; return 0; }
    if fm_busy_submit_wait "$sleep_s"; then
      printf 'empty'
      return 0
    fi
    state=$(fm_tmux_composer_state "$target") || state=unknown
    if fm_composer_blocking_dialog_noted >/dev/null; then
      printf 'unknown'
      return 0
    fi
    case "$state" in
      empty) printf 'empty'; return 0 ;;
      pending|pending-unproven) ;;
      *) printf 'unknown'; return 0 ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$state"
}

fm_tmux_submit_core() {
  local target=$1 text=$2 retries=$3 sleep_s=$4 settle=$5 err
  if declare -F fm_control_lane_release_guard >/dev/null; then fm_control_lane_release_guard || return 75; fi
  if ! err=$(tmux send-keys -t "$target" -l "$text" 2>&1 >/dev/null); then
    [ -z "$err" ] || printf '%s\n' "$err" >&2
    printf 'send-failed'
    return 0
  fi
  sleep "$settle"
  fm_tmux_submit_enter_core "$target" "$retries" "$sleep_s"
}
