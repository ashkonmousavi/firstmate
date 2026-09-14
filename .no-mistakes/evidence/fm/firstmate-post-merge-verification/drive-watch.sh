#!/usr/bin/env bash
# Live driver: runs the real bin/fm-pr-check.sh, bin/fm-pr-merge.sh and the
# bounded bin/fm-watch.sh loop against a fake GitHub CLI, then captures the
# watcher stdout, the durable wake-queue rows, and the parent-channel lines.
# Reuses the fixture helpers from tests/fm-pr-check-security.test.sh
# (definitions only).
set -u
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M2GMCM5B8H6G2HP5S8SNSV8K
EV=/home/tegris/.no-mistakes/evidence/01M2GMCM5B8H6G2HP5S8SNSV8K
defs=$(sed -n '1,2421p' "$WT/tests/fm-pr-check-security.test.sh")
defs=${defs//'$(dirname "${BASH_SOURCE[0]}")'/$WT/tests}
eval "$defs"

queue_rows() {  # <state>
  printf -- '--- durable wake-queue rows (kind | key | payload)\n'
  if [ -f "$1/.wake-queue" ]; then
    awk -F'\t' '{ print $3 " | " $4 " | " $5 }' "$1/.wake-queue"
  else
    echo '(no wake queue)'
  fi
}

parent_lines() {  # <state>
  printf -- '--- parent channel (state/parent-replies.status)\n'
  if [ -f "$1/parent-replies.status" ]; then cat "$1/parent-replies.status"; else echo '(none)'; fi
}

url=https://github.com/o/r/pull/1

# 4. Main home: merge-queue entry, then the watcher poll observes the landing.
dir=$(make_case live-queued-then-landed)
state="$dir/home/state"
write_task_meta "$dir" task-a
run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err"
queue_merge "$dir" "$url"
{
  echo "# main home: GitHub merge-queue entry, later landed and observed by the watcher poll"
  echo "\$ bin/fm-pr-check.sh task-a $url"
  echo "\$ bin/fm-pr-merge.sh task-a $url   (fake forge: OPEN, queued)"
  echo "--- merge stdout"
  cat "$dir/merge.out"
  queue_rows "$state"
  run_merged_poll_cycle "$dir"
  echo
  echo "\$ bin/fm-watch.sh   (bounded; fake forge now reports MERGED)"
  echo "--- watcher stdout"
  cat "$dir/watch.out"
  queue_rows "$state"
} > "$EV/04-queued-then-poll-landed.txt"

# 5. Secondmate home: the watcher poll observes a merge this home did not run.
dir=$(make_case live-secondmate-poll)
state="$dir/home/state"
seed_secondmate_home "$dir"
write_poll_meta "$state" task-a "$url"
seed_canonical_poll "$dir" task-a "$url"
run_merged_poll_cycle "$dir"
{
  echo "# secondmate home: watcher poll observes the merge"
  echo "\$ bin/fm-watch.sh   (bounded; fake forge reports MERGED)"
  echo "--- watcher stdout"
  cat "$dir/watch.out"
  parent_lines "$state"
  queue_rows "$state"
} > "$EV/05-secondmate-poll-landed.txt"

# 6. Secondmate home: this home runs the merge itself.
dir=$(make_case live-secondmate-self)
state="$dir/home/state"
seed_secondmate_home "$dir"
write_task_meta "$dir" task-a
run_check_entry "$dir" task-a "$url" >/dev/null 2> "$dir/seed.err"
run_merge_entry "$dir" task-a "$url" > "$dir/merge.out" 2> "$dir/merge.err"
rc=$?
{
  echo "# secondmate home: self-merge"
  echo "\$ bin/fm-pr-merge.sh task-a $url   (fake forge: MERGED)"
  echo "exit=$rc"
  echo "--- merge stdout"
  cat "$dir/merge.out"
  echo "--- merge stderr"
  cat "$dir/merge.err"
  parent_lines "$state"
  queue_rows "$state"
} > "$EV/06-secondmate-self-merge.txt"

echo "driver-watch done"
