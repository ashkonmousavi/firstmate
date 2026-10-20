#!/usr/bin/env bash
set -eu
umask 022
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5C1241WSKP7RTSG6105D627
. "$ROOT/bin/fm-pending-reply-lib.sh"
. "$ROOT/bin/fm-classify-lib.sh"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_BACKEND=tmux FM_POLL=1 FM_PENDING_REPLY_GRACE_SECS=0
SOCKET_DIR=$(cat .test-phase/socket-path)
export TMUX="$SOCKET_DIR/tmux-$(id -u)/fm-lab,0,0" TMUX_TMPDIR="$SOCKET_DIR"
for mode in warm missing invalid behind scratch cache-write; do
  export FM_HOME="$ROOT/.test-phase/watch-v2-$mode"
  bash bin/fm-lab-home.sh create "$FM_HOME" >/dev/null
  touch "$FM_HOME/config/wait-no-turns"
  state="$FM_HOME/state"
  status="$state/task.status"
  printf 'needs-decision [key=scope]: approval is required\n' > "$status"
  case "$mode" in
    behind) status_open_decisions_incremental "$status" >/dev/null ;;
    invalid) printf 'version=obsolete\noffset=900000\nident=old\n' > "$state/.task.open-decisions-cursor" ;;
  esac
  case "$mode" in
    warm|missing|invalid|behind)
      awk 'BEGIN {for(i=1;i<=3000;i++) {printf "done [key=item-%d] [at=1792400000]: long status note for item %d\nworking: ongoing audit step %d\n",i,i,i}}' >> "$status"
      count=15
      ;;
    *) count=2 ;;
  esac
  if [ "$mode" = warm ]; then status_open_decisions_incremental "$status" >/dev/null; fi
  printf 'working: newest line\n' >> "$status"
  for i in $(seq 1 "$count"); do
    corr=$(fm_pending_reply_create "$FM_HOME" "$state" task "live request $i")
    fm_pending_reply_mark_delivered "$state" "$corr"
    fm_pending_reply_mark_turn_completed "$state" "$corr"
  done
  FM_HOME="$FM_HOME" bash -c '. bin/fm-wake-lib.sh; fm_wake_status_mark_current "$FM_HOME/state" "$FM_HOME/state/task.status"'
  printf 'needs-decision [key=pulse]: observable next-stage delivery\n' > "$state/pulse.status"
  before=$(cat "$state/.task.open-decisions-cursor" 2>/dev/null || true)
  export FM_OPEN_DECISIONS_READ_PROBE="$FM_HOME/read-probe"
  started=$SECONDS
  # The wrapper creates an actual filesystem failure, then becomes the real
  # watcher, preserving $$ as the production scratch-file suffix.
  FM_WATCH_CHECKPOINT_SECONDS=45 bash -c '
    case "$1" in
      scratch) mkdir "$FM_HOME/state/.task.open-decisions-cursor.peek.read.$$" ;;
      cache-write) mkdir "$FM_HOME/state/.task.open-decisions-cursor.peek.tmp.$$" ;;
    esac
    exec bash bin/fm-watch.sh
  ' _ "$mode" > "$FM_HOME/watcher.out" 2>&1 || {
    cat "$FM_HOME/watcher.out"; echo "watcher failed: $mode"; exit 1;
  }
  elapsed=$((SECONDS-started))
  cat "$FM_HOME/watcher.out"
  grep -q 'signal:.*pulse.status' "$FM_HOME/watcher.out"
  test -f "$state/.last-watcher-beat"
  for rec in "$state/pending-replies"/*; do
    test "$(fm_pending_reply_get "$rec" phase)" = awaiting_report
    test -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)"
  done
  test "$(cat "$state/.task.open-decisions-cursor" 2>/dev/null || true)" = "$before"
  size=$(wc -c < "$status")
  folded=0
  if [ -f "$FM_OPEN_DECISIONS_READ_PROBE" ]; then folded=$(awk -F '\t' -v f="$status" '$1==f {n+=$2} END {print n+0}' "$FM_OPEN_DECISIONS_READ_PROBE"); fi
  if [ "$mode" != cache-write ]; then test "$folded" -le "$size"; fi
  printf 'MODE %s: %s delivered requests remain awaiting_report; no recovery attempts; watcher reached signal delivery in %ss; folded=%s log_bytes=%s; drain cursor unchanged\n' "$mode" "$count" "$elapsed" "$folded" "$size"
  if [ "$mode" = scratch ]; then
    test ! -f "$state/.task.open-decisions-cursor.peek"
    printf 'Filesystem scratch collision: decision retained through whole-file fallback; no cursor committed\n'
  fi
  if [ "$mode" = cache-write ]; then
    printf 'Filesystem cursor-write collision: decision retained in watcher recovery gate\n'
  fi
done
printf 'LIVE WATCHER SCENARIOS PASSED\n'
