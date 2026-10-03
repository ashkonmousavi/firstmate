#!/usr/bin/env bash
set -eu
. bin/fm-remote-job-lib.sh
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-comm.XXXXXX")
python3 - "$LAB" <<'PY' &
import ctypes, pathlib, sys, time
lab = pathlib.Path(sys.argv[1])
(lab / 'ready').touch()
while not (lab / 'rename').exists(): time.sleep(0.02)
assert ctypes.CDLL(None).prctl(15, b'odd) (worker))', 0, 0, 0) == 0
(lab / 'renamed').touch()
time.sleep(60)
PY
PID=$!
trap 'kill "$PID" 2>/dev/null || true; wait "$PID" 2>/dev/null || true; rm -rf "$LAB"' EXIT
for _ in $(seq 1 200); do [ ! -f "$LAB/ready" ] || break; sleep 0.02; done
[ -f "$LAB/ready" ]
BEFORE=$(fm_remote_job_process_start "$PID")
printf 'before-rename-pid=%s comm=%s cookie=%s\n' "$PID" "$(cat "/proc/$PID/comm")" "$BEFORE"
touch "$LAB/rename"
for _ in $(seq 1 200); do [ ! -f "$LAB/renamed" ] || break; sleep 0.02; done
[ -f "$LAB/renamed" ]
AFTER=$(fm_remote_job_process_start "$PID")
printf 'after-rename-pid=%s comm=%s cookie=%s\n' "$PID" "$(cat "/proc/$PID/comm")" "$AFTER"
[ "$(cat "/proc/$PID/comm")" = 'odd) (worker))' ]
[ "$BEFORE" = "$AFTER" ]
case "$AFTER" in proc-starttime=*) ;; *) exit 1 ;; esac
printf 'comm-with-spaces-and-parentheses=identity-retained\n'
