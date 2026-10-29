#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH" RING_REMAP_REMOTE=1
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export FM_HOME="$(cat .tmp-ring-validation/lab-home)"
trap 'env PATH="$RING_ORIGINAL_PATH" bin/fm-herdr-lab.sh stop "$RING_LAB_SESSION" > ~/.no-mistakes/evidence/01M64NPQ8218XYJRT9WNGFRNBA/busy-remote-stop.json' EXIT
bin/fm-herdr-lab.sh provision "$RING_LAB_SESSION"
bin/fm-herdr-lab.sh run "$RING_LAB_SESSION" agent start ring-busy --kind claude --pane w1:p1 --timeout 15000
bin/fm-herdr-lab.sh run "$RING_LAB_SESSION" agent prompt ring-busy 'Live validation only: write a detailed explanation of ocean tides, without using any tools or changing any files.'
bin/fm-herdr-lab.sh run "$RING_LAB_SESSION" agent wait ring-busy --until working --timeout 10000
export PATH="$PWD/.tmp-ring-validation/bin:$PATH"
export FM_COMPOSER_DIALOG_SINK="$FM_HOME/no-such-directory/dialog"
cs="$FM_HOME/state/parent-route/rsm.inbox"
before=$(cut -f2 "$cs/.ring-state")
out=$(bin/fm-remote-secondmate-control.sh inbox rsm ring 001.msg)
after=$(cut -f2 "$cs/.ring-state")
printf 'Busy remote ring: %s; attempt count before=%s after=%s\n' "$out" "$before" "$after"
[ "$out" = 'rang 2 reason=dialog-sink-failed' ]
[ "$after" -eq "$((before + 1))" ]
[ ! -e "$cs/.busy-state" ]
cmp "$cs/001.msg" "$FM_HOME/remote-original.msg"
printf 'A real working Claude agent did not introduce deferral or a busy budget; the ring attempted delivery and preserved .msg bytes.\n'
