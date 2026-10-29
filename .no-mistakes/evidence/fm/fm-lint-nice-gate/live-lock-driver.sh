#!/usr/bin/env bash
set -euo pipefail
. "$PWD/bin/fm-remote-job-lib.sh"
base="$PWD/.gate-test/live-state"
mkdir -p "$base"
lock="$base/repair"
log="$base/trace"
children=()
cleanup() {
  for pid in "${children[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in "${children[@]}"; do wait "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT
for worker in 1 2 3 4; do
  (
    for cycle in 1 2 3 4 5 6; do
      fm_remote_job_reload_lock_acquire "$lock"
      # An independent mkdir sentinel rejects simultaneous successful holders.
      mkdir "$base/exclusive"
      printf 'acquired worker=%s cycle=%s pid=%s target=%s\n' "$worker" "$cycle" "$BASHPID" "$(readlink "$lock")" >> "$log"
      sleep 0.025
      rmdir "$base/exclusive"
      fm_remote_job_reload_lock_release "$lock"
      printf 'released worker=%s cycle=%s\n' "$worker" "$cycle" >> "$log"
    done
  ) &
  children+=("$!")
done
for pid in "${children[@]}"; do wait "$pid"; done
children=()
[ ! -e "$lock" ] && [ ! -L "$lock" ]
# A holder exits without releasing: the next real process must reclaim it.
(
  fm_remote_job_reload_lock_acquire "$lock"
  printf 'abandoned pid=%s target=%s\n' "$BASHPID" "$(readlink "$lock")" >> "$log"
) &
pid=$!
children+=("$pid")
wait "$pid"
children=()
fm_remote_job_reload_lock_acquire "$lock"
printf 'reclaimed pid=%s target=%s\n' "$BASHPID" "$(readlink "$lock")" >> "$log"
fm_remote_job_reload_lock_release "$lock"
[ ! -e "$lock" ] && [ ! -L "$lock" ]
[ "$(ls -A "$base")" = trace ]
printf 'final lock=absent remaining-state=trace-only\n' >> "$log"
cat "$log"
