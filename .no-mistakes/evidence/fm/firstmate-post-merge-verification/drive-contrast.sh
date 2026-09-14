#!/usr/bin/env bash
# Before/after contrast: the same synchronous GitHub self-merge driven through
# the base commit's bin/fm-pr-merge.sh (exported to a temp dir) and through the
# target worktree's. Only the product root differs between the two runs.
set -u
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M2GMCM5B8H6G2HP5S8SNSV8K
EV=/home/tegris/.no-mistakes/evidence/01M2GMCM5B8H6G2HP5S8SNSV8K
BASE_COMMIT=cfd994166ee35d160e8d5aa48d94e752cee01a47
BASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-base-root.XXXXXX")
git -C "$WT" archive "$BASE_COMMIT" | tar -x -C "$BASE_ROOT"

defs=$(sed -n '1,3011p' "$WT/tests/fm-pr-merge.test.sh")
defs=${defs//'$(dirname "${BASH_SOURCE[0]}")'/$WT/tests}
eval "$defs" > /dev/null

drive() {  # <label> <root>
  local label=$1 root=$2 case_dir rc
  ROOT=$root
  PR_MERGE="$root/bin/fm-pr-merge.sh"
  case_dir=$(make_case "contrast-$label")
  mkdir -p "$case_dir/wt"
  add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
  : > "$case_dir/gh-axi.log"
  run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
    > "$case_dir/stdout" 2> /dev/null
  rc=$?
  printf '# %s (%s)\n$ bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/51   (fake forge: MERGED)\nexit=%s\n--- stdout\n' \
    "$label" "$root" "$rc"
  cat "$case_dir/stdout"
  printf -- '--- durable wake-queue payloads\n'
  awk -F'\t' '{ print $5 }' "$case_dir/state/.wake-queue"
  echo
}

{
  drive "BASE cfd9941" "$BASE_ROOT"
  drive "TARGET a7d4499" "$WT"
} > "$EV/07-base-vs-target-self-merge.txt"
rm -rf "$BASE_ROOT"
echo "driver-contrast done"
