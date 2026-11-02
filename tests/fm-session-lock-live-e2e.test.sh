#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_SESSION_LOCK_LIVE claude python3 jq tmux
export ROOT
python3 "$ROOT/tests/fm-session-lock-live.test.py"
