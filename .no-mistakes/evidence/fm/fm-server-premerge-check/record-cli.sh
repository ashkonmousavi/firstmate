#!/usr/bin/env bash
if command -v python3 >/dev/null 2>&1; then
  exec python3 -I "$FM_LIVE_WORKTREE/.gate-live-tmp/record-cli.py" "$@"
fi
exec "$BASH" "$FM_LIVE_WORKTREE/bin/fm-q-premerge-plan-check.sh" "$@"
