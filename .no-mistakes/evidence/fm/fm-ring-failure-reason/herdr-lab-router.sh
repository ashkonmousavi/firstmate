#!/usr/bin/env bash
set -eu
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --session) [ "$2" = "$RING_LAB_SESSION" ] || { [ "${RING_REMAP_REMOTE:-0}" = 1 ] && [ "$2" = fm-remote ]; } || { echo 'refused non-lab session' >&2; exit 1; }; shift 2 ;;
    --session=*) echo 'refused alternate session argument' >&2; exit 1 ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ -f "$RING_ROOT/.tmp-ring-validation/outage-armed" ] && [ "${args[0]:-}" = pane ] && [ "${args[1]:-}" = send-keys ] && [ "${args[3]:-}" = enter ]; then
  env PATH="$RING_ORIGINAL_PATH" "$RING_ROOT/bin/fm-herdr-lab.sh" run "$RING_LAB_SESSION" "${args[@]}"
  rm "$RING_ROOT/.tmp-ring-validation/outage-armed"
  env PATH="$RING_ORIGINAL_PATH" "$RING_ROOT/bin/fm-herdr-lab.sh" stop "$RING_LAB_SESSION" > "$RING_OUTAGE_LOG"
  exit 0
fi
exec env PATH="$RING_ORIGINAL_PATH" "$RING_ROOT/bin/fm-herdr-lab.sh" run "$RING_LAB_SESSION" "${args[@]}"
