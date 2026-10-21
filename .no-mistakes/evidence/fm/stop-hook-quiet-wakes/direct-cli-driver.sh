#!/usr/bin/env bash
set -e
export FM_HOME="$PWD/.gate-test/cli-home"
mkdir -p "$FM_HOME/state" "$FM_HOME/config"
. "$PWD/bin/fm-wake-lib.sh"
. "$PWD/bin/fm-timeout-lib.sh"
printf 'kind=secondmate\n' > "$STATE/mate.meta"
printf 'working: checking the queue\npaused: waiting for assigned work\n' > "$STATE/mate.status"
fm_wake_status_reported_commit "$STATE" "$STATE/mate.status" "$(fm_wake_signal_sig "$STATE/mate.status")"
fm_wake_append signal mate.status "signal: $STATE/mate.status"
fm_wake_append check rearm-resurface 'check: rearm-resurface'
bin/fm-branch-outcome.sh append --task mate --verdict routine --summary 'routine progress'
fm_wake_append check supervision-host-return:1 'check: supervision-host outcome 1 for mate [routine]'
fm_recovery_marker_publish "$STATE/.watcher-down" downtime
printf 'check: rearm-resurface\n' > "$FM_HOME/close"
printf 'BEFORE: raw wake rows\n'
cat "$STATE/.wake-queue"
ack=$(fm_wake_routine_peek "$FM_HOME/close")
printf 'PROVEN ROUTINE: cutoff and recovery generation: %s\n' "$ack"
bin/fm-wake-drain.sh --ack-through "${ack%%$'\t'*}" --recovery-generation "${ack#*$'\t'}"
printf 'AFTER: queue bytes=%s; recovery=' "$(wc -c < "$STATE/.wake-queue")"
cat "$STATE/.watcher-down"
for f in .status-presentation-cursor .branch-outcomes-cursor; do
  [ ! -e "$STATE/$f" ]
  printf 'presentation cursor %s remains absent\n' "$f"
done
[ ! -s "$STATE/.wake-queue" ]
grep -q '^acked:downtime:' "$STATE/.watcher-down"
