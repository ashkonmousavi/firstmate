#!/usr/bin/env bash
# Live driver for the GitLab arm: the real bin/fm-pr-merge.sh against a fake
# glab (confirmed merge and auto-merge that is still open), then the real
# bounded bin/fm-watch.sh poll observing a GitLab merge. Each half evaluates
# its own test file's fixture definitions in a separate subshell.
set -u
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M2GMCM5B8H6G2HP5S8SNSV8K
EV=/home/tegris/.no-mistakes/evidence/01M2GMCM5B8H6G2HP5S8SNSV8K

(
  defs=$(sed -n '1,3011p' "$WT/tests/fm-pr-merge.test.sh")
  defs=${defs//'$(dirname "${BASH_SOURCE[0]}")'/$WT/tests}
  eval "$defs" > /dev/null

  report() {  # <case_dir> <rc> <title> <cmd>
    local case_dir=$1 rc=$2
    printf '# %s\n$ %s\nexit=%s\n--- stdout\n' "$3" "$4" "$rc"
    cat "$case_dir/stdout"
    printf -- '--- durable wake-queue payloads\n'
    if [ -f "$case_dir/state/.wake-queue" ]; then
      awk -F'\t' '{ print $5 }' "$case_dir/state/.wake-queue"
    else
      echo '(no wake queue)'
    fi
    printf -- '--- merge poll still armed?\n'
    if [ -f "$case_dir/state/task-x1.check.sh" ]; then echo yes; else echo no; fi
    echo
  }

  case_dir=$(make_gitlab_case live-gitlab-merged)
  run_pr_merge "$case_dir" task-x1 "$MR_URL" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  report "$case_dir" "$rc" "GitLab self-merge confirmed merged (fake glab: merged after merge)" \
    "bin/fm-pr-merge.sh task-x1 $MR_URL"

  case_dir=$(make_gitlab_case live-gitlab-auto-merge)
  mkdir -p "$case_dir/home"
  : > "$case_dir/glab-stays-open"
  FM_TEST_HOME="$case_dir/home" run_pr_merge "$case_dir" task-x1 "$MR_URL" \
    > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  report "$case_dir" "$rc" "GitLab merge accepted but still open (auto-merge; fake glab stays opened)" \
    "bin/fm-pr-merge.sh task-x1 $MR_URL"
) > "$EV/08-gitlab-self-merge.txt" 2>&1

(
  defs=$(sed -n '1,2421p' "$WT/tests/fm-pr-check-security.test.sh")
  defs=${defs//'$(dirname "${BASH_SOURCE[0]}")'/$WT/tests}
  eval "$defs" > /dev/null

  url=https://gitlab.example/group/subgroup/project/-/merge_requests/17
  dir=$(make_case live-gitlab-poll)
  state="$dir/home/state"
  write_poll_meta "$state" task-a "$url"
  seed_canonical_poll "$dir" task-a "$url"
  FM_TEST_GLAB_STATE=merged run_watcher_bounded "$dir/home" "$dir/fakebin" \
    > "$dir/watch.out" 2> "$dir/watch.err"
  rc=$?
  printf '# GitLab merge observed by the watcher poll (main home)\n$ bin/fm-watch.sh   (bounded; fake glab reports merged)\nexit=%s\n--- watcher stdout\n' "$rc"
  cat "$dir/watch.out"
  printf -- '--- durable wake-queue payloads\n'
  awk -F'\t' '{ print $5 }' "$state/.wake-queue"
) > "$EV/09-gitlab-poll-landed.txt" 2>&1

echo "driver-gitlab done"
