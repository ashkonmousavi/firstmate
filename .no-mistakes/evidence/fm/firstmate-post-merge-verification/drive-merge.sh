#!/usr/bin/env bash
# Live driver: runs the real bin/fm-pr-merge.sh against a fake GitHub CLI and
# captures the operator-visible stdout plus the durable wake-queue rows.
# Reuses the fixture helpers from tests/fm-pr-merge.test.sh (definitions only).
set -u
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M2GMCM5B8H6G2HP5S8SNSV8K
EV=/home/tegris/.no-mistakes/evidence/01M2GMCM5B8H6G2HP5S8SNSV8K
defs=$(sed -n '1,3011p' "$WT/tests/fm-pr-merge.test.sh")
defs=${defs//'$(dirname "${BASH_SOURCE[0]}")'/$WT/tests}
eval "$defs"

transcript() {  # <case_dir> <rc> <title> <cmd>
  local case_dir=$1 rc=$2 title=$3 cmd=$4
  printf '# %s\n$ %s\nexit=%s\n--- stdout\n' "$title" "$cmd" "$rc"
  cat "$case_dir/stdout"
  printf -- '--- stderr\n'
  cat "$case_dir/stderr"
  printf -- '--- durable wake-queue rows (kind | key | payload)\n'
  if [ -f "$case_dir/state/.wake-queue" ]; then
    awk -F'\t' '{ print $3 " | " $4 " | " $5 }' "$case_dir/state/.wake-queue"
  else
    echo '(no wake queue)'
  fi
}

# 1. Synchronous self-merge on GitHub: forge reports MERGED.
case_dir=$(make_case live-sync-merge)
mkdir -p "$case_dir/wt"
add_gh_mocks "$case_dir" 1010101010101010101010101010101010101010
: > "$case_dir/gh-axi.log"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/51 \
  > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
transcript "$case_dir" "$rc" "synchronous GitHub self-merge (fake forge: MERGED)" \
  "bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/51" \
  > "$EV/01-sync-self-merge.txt"

# 2. GitHub merge-queue entry: accepted but not merged yet.
case_dir=$(make_case live-queued-merge)
mkdir -p "$case_dir/wt"
add_gh_mocks "$case_dir" 3030303030303030303030303030303030303030
write_github_outcome "$case_dir" OPEN false true master
: > "$case_dir/gh-axi.log"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/53 \
  --attended-override -- --auto --merge \
  > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
transcript "$case_dir" "$rc" "GitHub merge-queue entry (fake forge: OPEN, queued)" \
  "bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/53 --attended-override -- --auto --merge" \
  > "$EV/02-queued-self-merge.txt"

# 3. Adversarial: the merge lands but committing the notification marker fails.
case_dir=$(make_case live-marker-fail)
mkdir -p "$case_dir/wt"
add_gh_mocks "$case_dir" 5050505050505050505050505050505050505050
: > "$case_dir/gh-axi.log"
cat > "$case_dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *pr-poll-merge-notified*) exit 1 ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
chmod +x "$case_dir/fakebin/mv"
run_pr_merge "$case_dir" task-x1 https://github.com/example/repo/pull/55 \
  > "$case_dir/stdout" 2> "$case_dir/stderr"
rc=$?
{
  transcript "$case_dir" "$rc" "adversarial: merge lands, notification marker commit fails" \
    "bin/fm-pr-merge.sh task-x1 https://github.com/example/repo/pull/55   (mv of the marker forced to fail)"
  printf -- '--- marker committed?\n'
  if [ -e "$case_dir/state/task-x1.pr-poll-merge-notified" ]; then echo yes; else echo no; fi
} > "$EV/03-marker-commit-fails.txt"

echo "driver-merge done"
