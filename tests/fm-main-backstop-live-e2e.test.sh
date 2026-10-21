#!/usr/bin/env bash
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_MAIN_BACKSTOP_LIVE herdr python3
export ROOT
python3 "$ROOT/tests/fm-main-backstop-live.test.py"
