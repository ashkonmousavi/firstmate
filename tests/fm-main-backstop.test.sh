#!/usr/bin/env bash
# Verify cron recovery, shell refusal and durable lag alarms without live panes.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export ROOT
python3 "$ROOT/tests/fm-main-backstop.test.py"
