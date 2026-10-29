#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export PATH="$PWD/.tmp-ring-validation/bin:$PATH" FM_HOME="$(cat .tmp-ring-validation/lab-home)"
. bin/fm-task-inbox-lib.sh
FM_RING_REASON_SINK="$FM_HOME/direct-preflight-reason"
rc=0
fm_backend_send_text_submit herdr "$RING_LAB_SESSION:w1:p1" 'MUST NOT TYPE THIS' 5 2 0.3 > "$FM_HOME/preflight.stdout" 2> "$FM_HOME/preflight.stderr" || rc=$?
printf 'Backend submit: rc=%s reason=%s stdout_bytes=%s stderr=%s\n' "$rc" "$(cat "$FM_RING_REASON_SINK")" "$(wc -c < "$FM_HOME/preflight.stdout")" "$(cat "$FM_HOME/preflight.stderr")"
[ "$rc" = 1 ] && [ "$(cat "$FM_RING_REASON_SINK")" = preflight-dialog ] && [ ! -s "$FM_HOME/preflight.stdout" ]
