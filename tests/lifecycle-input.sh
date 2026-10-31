#!/usr/bin/env bash

# Retain the real terminal and control output when a live guard requests
# evidence. This is a capture of the running harness, never a canned screen.
fm_test_lifecycle_capture() { # <name> <stage> <backend> <target> [control-output] [input-log]
  [ -n "${FM_SEND_INBOX_LIVE_EVIDENCE_DIR:-}" ] || return 0
  local prefix="$FM_SEND_INBOX_LIVE_EVIDENCE_DIR/lifecycle-$1-$2"
  mkdir -p "$FM_SEND_INBOX_LIVE_EVIDENCE_DIR" || return 1
  case "$3" in
    tmux) tmux capture-pane -e -p -t "$4" > "$prefix.ansi" || return 1 ;;
    herdr) fm_backend_capture herdr "$4" 200 > "$prefix.ansi" || return 1 ;;
    *) return 1 ;;
  esac
  {
    printf 'harness=%s\nstage=%s\ncontrol output:\n%s\n' "$1" "$2" "${5:-<not invoked>}"
    if [ -n "${6:-}" ]; then printf '\ntransport input:\n'; cat "$6"; fi
  } > "$prefix.txt"
}

fm_test_lifecycle_input() {
  local log=$1 verb=$2 command=${3:-}
  [ -s "$log" ] || return 1
  awk -v verb="$verb" -v expected="text=$command" '
    /^text=/ {
      if (verb != "exit" || $0 != expected) bad = 1
      typed = 1
      next
    }
    /^key=/ {
      key = substr($0, 5)
      if (key ~ /^(Enter|enter|C-m|C-j|ctrl\+m|ctrl\+j)$/ && (verb != "exit" || !typed)) bad = 1
      next
    }
    { bad = 1 }
    END { exit (bad || (verb == "exit" && !typed)) }
  ' "$log"
}
