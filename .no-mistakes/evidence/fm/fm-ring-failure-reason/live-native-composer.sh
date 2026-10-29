#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export FM_HOME="$(cat .tmp-ring-validation/lab-home)"
trap 'env PATH="$RING_ORIGINAL_PATH" bin/fm-herdr-lab.sh stop "$RING_LAB_SESSION" > ~/.no-mistakes/evidence/01M64NPQ8218XYJRT9WNGFRNBA/native-composer-stop.json' EXIT
bin/fm-herdr-lab.sh provision "$RING_LAB_SESSION"
bin/fm-herdr-lab.sh run "$RING_LAB_SESSION" agent start ring-native --kind claude --pane w1:p1 --timeout 15000
export PATH="$PWD/.tmp-ring-validation/bin:$PATH"
. bin/fm-task-inbox-lib.sh
fm_backend_source herdr
fm_backend_herdr_send_literal "$RING_LAB_SESSION:w1:p1" ' '
FM_RING_REASON_SINK="$FM_HOME/native-composer-reason"
rc=0
verdict=$(fm_backend_send_text_submit herdr "$RING_LAB_SESSION:w1:p1" /permissions 5 2 0.3) || rc=$?
printf 'Permissions submit: exit=%s verdict=%s reason=%s\n' "$rc" "$verdict" "$(cat "$FM_RING_REASON_SINK" 2>/dev/null || true)"
fm_backend_herdr_cli "$RING_LAB_SESSION" agent get w1:p1
fm_backend_herdr_cli "$RING_LAB_SESSION" pane read w1:p1 --source visible --format text
[ "$rc" = 0 ] && [ "$verdict" = unknown ] && [ "$(cat "$FM_RING_REASON_SINK")" = post-enter-unreadable ]
