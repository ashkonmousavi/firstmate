#!/usr/bin/env bash
set -eu
umask 022
ROOT=$PWD
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export FM_HOME="$ROOT/.test-phase/split-v2-home"
bash bin/fm-lab-home.sh create "$FM_HOME" >/dev/null
export FM_BACKEND=tmux FM_POLL=1 FM_SIGNAL_GRACE=0 FM_PENDING_REPLY_GRACE_SECS=0
SOCKET_DIR=$(cat .test-phase/socket-path)
export TMUX="$SOCKET_DIR/tmux-$(id -u)/fm-lab,0,0" TMUX_TMPDIR="$SOCKET_DIR"
. bin/fm-pending-reply-lib.sh
state="$FM_HOME/state"
touch "$FM_HOME/config/wait-no-turns"
printf 'needs-decision [key=anchor]: keep waiting\nneeds-deci' > "$state/task.status"
corr=$(fm_pending_reply_create "$FM_HOME" "$state" task 'split record request')
fm_pending_reply_mark_delivered "$state" "$corr"
fm_pending_reply_mark_turn_completed "$state" "$corr"
FM_WATCH_CHECKPOINT_SECONDS=30 bash bin/fm-watch.sh
printf 'FIRST APPEND CURSORS:\n'
cat "$state/.task.open-decisions-cursor.peek"
FM_HOME="$FM_HOME" bash bin/fm-wake-drain.sh > "$FM_HOME/first-drain"
grep -F '[key=anchor]' "$FM_HOME/first-drain"
printf 'sion [key=x]: café' >> "$state/task.status"
FM_WATCH_CHECKPOINT_SECONDS=30 bash bin/fm-watch.sh
FM_HOME="$FM_HOME" bash bin/fm-wake-drain.sh > "$FM_HOME/tail-drain"
printf 'UNTERMINATED SECOND APPEND PRESENTATION:\n'
grep -F '[key=x]' "$FM_HOME/tail-drain"
printf 'PEEK AND DRAIN OFFSETS WITH UNTERMINATED TAIL:\n'
grep '^offset=' "$state/.task.open-decisions-cursor" "$state/.task.open-decisions-cursor.peek"
test "$(sed -n 's/^offset=//p' "$state/.task.open-decisions-cursor")" = 42
test "$(sed -n 's/^offset=//p' "$state/.task.open-decisions-cursor.peek")" = 42
printf ' and more\nresolved [key=anchor]: answered\n' >> "$state/task.status"
FM_WATCH_CHECKPOINT_SECONDS=30 bash bin/fm-watch.sh
FM_HOME="$FM_HOME" bash bin/fm-wake-drain.sh > "$FM_HOME/completed-drain"
printf 'COMPLETED RECORD PRESENTATION:\n'
grep -F '[key=x]' "$FM_HOME/completed-drain"
rec=$(fm_pending_reply_path "$state" "$corr")
test "$(fm_pending_reply_get "$rec" phase)" = awaiting_report
test -z "$(fm_pending_reply_get "$rec" recovery_attempted_epoch)"
printf 'Only x remains open: real watcher kept recovery unattempted after the anchor closed\n'
printf 'LIVE SPLIT-APPEND SCENARIO PASSED\n'
