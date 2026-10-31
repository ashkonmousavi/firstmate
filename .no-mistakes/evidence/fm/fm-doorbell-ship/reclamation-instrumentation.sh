#!/usr/bin/env bash
set -euo pipefail
/bin/rm "$@"
if [ "${FM_RING_RECLAIMER:-0}" = 1 ] && [ "${!#}" = "${FM_RING_LOCK:-}" ] && [ ! -e "$FM_RING_GATE/gap" ]; then
  : > "$FM_RING_GATE/gap"
  for ((i=0;i<300;i++)); do [ -e "$FM_RING_GATE/release" ] && exit 0; sleep 0.1; done
  exit 1
fi
