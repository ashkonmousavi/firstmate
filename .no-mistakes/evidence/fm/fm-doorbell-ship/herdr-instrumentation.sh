#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
[ "${args[n-2]:-}" = --session ] && [ "${args[n-1]:-}" = "$LAB_SESSION" ] || { echo 'refused unscoped Herdr call' >&2; exit 97; }
args=("${args[@]:0:n-2}")
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }
printf '%s %q ' "$(date +%s.%N)" "${args[@]}" >> "$TEST_EVIDENCE/product-api.log"
printf '\n' >> "$TEST_EVIDENCE/product-api.log"
if [ -n "${FM_RENDER_MODE:-}" ]; then
  case "${args[0]:-} ${args[1]:-}" in
    'pane send-text')
      if [ "$FM_RENDER_MODE" = prefix ]; then
        payload=${args[3]}
        printf '%s' "${payload:60}" > "$FM_RENDER_DIR/remainder"
        args[3]=${payload:0:60}
        lab "${args[@]}"
        python3 -c 'import time; print(time.monotonic())' > "$FM_RENDER_DIR/typed-at"
        exit 0
      fi
      [ ! -e "$FM_RENDER_DIR/typed-at" ] || exit 95
      kill -STOP "$CLAUDE_PID"
      lab "${args[@]}"
      python3 -c 'import time; print(time.monotonic())' > "$FM_RENDER_DIR/typed-at"
      exit 0;;
    'pane read')
      if [ -s "$FM_RENDER_DIR/typed-at" ] && [ ! -e "$FM_RENDER_DIR/probe.ansi" ] && [[ " ${args[*]} " = *' --format ansi '* ]]; then
        lab "${args[@]}" > "$FM_RENDER_DIR/probe.tmp"
        cat "$FM_RENDER_DIR/probe.tmp"
        mv "$FM_RENDER_DIR/probe.tmp" "$FM_RENDER_DIR/probe.ansi"
        exit 0
      fi;;
    'pane send-keys')
      printf '%s\n' "${args[*]}" >> "$FM_RENDER_DIR/keys"
      if [ "$FM_RENDER_MODE" = timeout ] && [[ " ${args[*]} " = *' ctrl+u '* ]]; then kill -CONT "$CLAUDE_PID"; fi;;
  esac
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "${args[@]}"
