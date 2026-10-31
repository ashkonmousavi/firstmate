#!/usr/bin/env bash

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
