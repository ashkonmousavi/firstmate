#!/usr/bin/env bash
set -euo pipefail
export XDG_CONFIG_HOME=.r FM_HERDR_LAB_STATE_DIR="$PWD/.r/ownership" FM_HOME="$PWD/.r/fm" PATH="$PWD/.r/bin:$PATH"
. bin/fm-backend.sh
fm_backend_source herdr
identity=
for mode in no-bottom empty-bottom plain-only; do
  for reader in state content; do
    rm -f .r/get-count
    export FM_LIVE_FAULT=$mode FM_LIVE_CALL_LOG=".r/$mode-$reader.jsonl"
    : > "$FM_LIVE_CALL_LOG"
    result=$("fm_backend_herdr_composer_$reader" fm-lab-v:w2:p1) && rc=0 || rc=$?
    if [ "$mode" = plain-only ]; then
      if [ "$reader" = state ]; then [ "$result" = empty ]; else if [ "$rc" -ne 0 ] || [ -n "$result" ]; then exit 1; fi; fi
    elif [ "$reader" = state ]; then [ "$result" = unknown ]; else if [ "$rc" -eq 0 ] || [ -n "$result" ]; then exit 1; fi; fi
    python3 - "$FM_LIVE_CALL_LOG" <<'PY'
import json,sys
calls=[json.loads(x)['args'] for x in open(sys.argv[1])]
assert sum(c[:2]==['pane','get'] for c in calls)==1,calls
assert all('visible' not in c for c in calls),calls
PY
    printf 'Live scrolled pane, fault=%s reader=%s: result=%q rc=%s; one offset probe, no viewport fallback\n' "$mode" "$reader" "$result" "$rc"
  done
done
unset FM_LIVE_FAULT
export FM_LIVE_CALL_LOG=.r/missing.jsonl
expected_cap=$(fm_backend_herdr_visible_capture_ansi fm-lab-v:w3:p1)
expected=$(fm_composer_classify_screen $'styled=1\ncursor=0\nidentity=1' "$expected_cap" '' $'claude\tdone')
export FM_LIVE_FAULT=missing
actual=$(fm_backend_herdr_composer_state fm-lab-v:w3:p1)
[ "$actual" = "$expected" ] && [ "$actual" = unknown ]
printf 'Live pane with missing scroll metadata: viewport has only history; state=%s, while readable bottom holds a pending draft\n' "$actual"
