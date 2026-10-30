#!/usr/bin/env bash
set -eu
ROOT=$PWD; EVIDENCE=~/.no-mistakes/evidence/01M65B69RB6KVB3GE3TWHGKXGE
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_PENDING_REPLY_SEND_HOOK FM_PENDING_REPLY_REMOTE_PROBE_HOOK
bin/fm-lab-home.sh create "$ROOT/.lv/q2"
export FM_HOME="$ROOT/.lv/q2" FM_SSH_BIN="$ROOT/.lv/ssh" FM_PENDING_REPLY_GRACE_SECS=0 TMPDIR="$ROOT/.lv/tmp"
S="$FM_HOME/state"
cp .lv/p/data/secondmates.md "$FM_HOME/data/secondmates.md"
cp .lv/p/state/rsm.meta "$S/rsm.meta"
. bin/fm-pending-reply-lib.sh
generated=$(fm_pending_reply_create "$FM_HOME" "$S" rsm 'report slow build')
slow=0000000000000001
mv "$(fm_pending_reply_path "$S" "$generated")" "$(fm_pending_reply_path "$S" "$slow")"
fm_pending_reply_set "$(fm_pending_reply_path "$S" "$slow")" corr_id "$slow"
fm_pending_reply_mark_delivery_unknown "$S" "$slow"
printf '%s\n' "$slow" > .lv/slow-corr
# More unresolved records than one pass may probe: the ordinary cycle must remain live behind the correlation lock.
for ((i=0;i<15;i++)); do corr=$(fm_pending_reply_create "$FM_HOME" "$S" rsm "report queued build $i"); fm_pending_reply_mark_delivery_unknown "$S" "$corr"; done
python3 - <<'PY'
from pathlib import Path
Path('.lv/probe-started').unlink(missing_ok=True)
PY
touch "$S/.secondmate-liveness-tick" "$S/home-summary.json"
setsid env FM_POLL=1 FM_SIGNAL_GRACE=0 FM_HEARTBEAT=3600 FM_HOME_SUMMARY_INTERVAL=3600 FM_TASK_INBOX_GRACE_SECS=1 FM_SECONDMATE_LIVENESS_SECS=3600 bin/fm-watch.sh > "$EVIDENCE/slow-watcher-runtime.log" 2>&1 &
watcher=$!
trap 'kill -TERM -- "-$watcher" 2>/dev/null || true; wait "$watcher" 2>/dev/null || true' EXIT
# Isolate the slow correlation as the first lexical scan entry without altering its identity.
for ((i=0;i<300;i++)); do [ ! -e .lv/probe-started ] || break; sleep 0.1; done
[ -e .lv/probe-started ]
start=$(date +%s); before=$(stat -c %Y "$S/.last-watcher-beat")
sleep 4
after=$(stat -c %Y "$S/.last-watcher-beat")
printf 'real watcher pid=%s real SSH corr=%s unresolved_records=16\nbeacon_before=%s beacon_after=%s slow_phase=%s\n' "$watcher" "$slow" "$before" "$after" "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$slow")" phase)"
[ "$after" -gt "$before" ]
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$slow")" phase)" = delivery_unknown ]
for ((i=0;i<240;i++)); do [ "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$slow")" phase)" != escalated ] || break; sleep 0.1; done
elapsed=$(( $(date +%s) - start ))
printf 'probe elapsed=%ss phase=%s; configured fixed bound=20s\n' "$elapsed" "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$slow")" phase)"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$slow")" phase)" = escalated ]
[ "$elapsed" -ge 18 ] && [ "$elapsed" -lt 25 ]
kill -TERM -- "-$watcher" 2>/dev/null || true
rc=0; wait "$watcher" || rc=$?
printf 'watcher exit=%s\n' "$rc"
case "$rc" in 0|143) ;; *) exit "$rc" ;; esac
trap - EXIT
printf 'PASS: detached slow probe preserves live supervision and honors the fixed 20-second bound.\n'
