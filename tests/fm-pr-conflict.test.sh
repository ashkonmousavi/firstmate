#!/usr/bin/env bash
# Conflict-label observations and the read-only pull-request overlap note.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
OVERLAP="$ROOT/bin/fm-pr-overlap.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-conflict)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid
unset FM_PR_CONFLICT_SEND FM_PR_CONFLICT_RELAUNCH

command -v jq >/dev/null 2>&1 || fail "jq is required to build the label fixtures"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}"
    ;;
  "api graphql")
    prog=
    prev=
    for arg in "$@"; do
      [ "$prev" != --jq ] || prog=$arg
      prev=$arg
    done
    [ -n "$prog" ] || exit 91
    jq -r "$prog" "$FM_CONFLICT_JSON"
    ;;
  "pr list")
    cat "$FM_OVERLAP_PRS"
    ;;
  "pr diff")
    number=$3
    list="$FM_OVERLAP_DIFF_DIR/$number"
    [ -f "$list" ] || exit 91
    cat "$list"
    ;;
  *)
    printf 'unexpected gh: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

reset_lib() {
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pr-lib.sh"
  unset FM_PR_CONFLICT_SEND FM_PR_CONFLICT_RELAUNCH
}

write_label_json() {  # <file> <present: yes|no> <labeled-at> [unlabeled-at]
  local file=$1 present=$2 labeled=$3 unlabeled=${4:-}
  if [ "$present" = yes ]; then
    jq -n --arg labeled "$labeled" --arg unlabeled "$unlabeled" '
      {
        data: { repository: { pullRequest: {
          labels: { nodes: [{name: "conflict"}] },
          timelineItems: { nodes: (
            [{__typename: "LabeledEvent", createdAt: $labeled, label: {name: "conflict"}}]
            + (if $unlabeled == "" then [] else
                [{__typename: "UnlabeledEvent", createdAt: $unlabeled, label: {name: "conflict"}}]
              end)
          ) }
        } } }
      }' > "$file"
  else
    jq -n --arg labeled "$labeled" --arg unlabeled "$unlabeled" '
      {
        data: { repository: { pullRequest: {
          labels: { nodes: [] },
          timelineItems: { nodes: (
            (if $labeled == "" then [] else
              [{__typename: "LabeledEvent", createdAt: $labeled, label: {name: "conflict"}}]
            end)
            + (if $unlabeled == "" then [] else
                [{__typename: "UnlabeledEvent", createdAt: $unlabeled, label: {name: "conflict"}}]
              end)
          ) }
        } } }
      }' > "$file"
  fi
}

run_poll() {
  PATH="$FAKEBIN:$PATH" FM_CONFLICT_JSON="${FM_CONFLICT_JSON:-}" "$POLL" --validated github \
    https://github.com/o/r/pull/7 github.com o/r 7
}

setup_task() {
  local state=$1
  mkdir -p "$state"
  fm_write_meta "$state/lane.meta" 'base_branch=curated'
}

test_old_label_wakes_once_and_clear_removes_it() {
  local state json old out decision
  reset_lib
  state="$TMP_ROOT/wake-state"
  json="$TMP_ROOT/old.json"
  rm -rf "$state"
  setup_task "$state"
  old=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$json" yes "$old"
  FM_CONFLICT_JSON=$json
  out=$(run_poll)
  [ "$out" = conflict ] || fail "a conflict label older than 15 minutes must report conflict, got: $out"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = wake ] || fail "with no live worker the old label must wake once, got: $decision"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "an unpublished wake must remain retryable"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = wake ] || fail "interruption before publication must retry the wake"
  fm_pr_conflict_episode_open "$state" lane github github.com o/r 7 \
    || fail "could not commit the published wake episode"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] || fail "a second look at the same conflict must stay quiet, got: $decision"
  write_label_json "$json" no "$old" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  out=$(run_poll)
  [ "$out" = conflict-clear ] || fail "removing the label must report conflict-clear, got: $out"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict-clear)
  [ "$decision" = quiet ] || fail "clearing the label must not wake, got: $decision"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "clearing the label must remove the episode"
  pass "conflict label older than 15 minutes wakes once, and removal clears it"
}

test_young_label_is_quiet() {
  local state json young out decision
  reset_lib
  state="$TMP_ROOT/young-state"
  json="$TMP_ROOT/young.json"
  rm -rf "$state"
  setup_task "$state"
  young=$(jq -nr 'now - 300 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$json" yes "$young"
  FM_CONFLICT_JSON=$json
  out=$(run_poll)
  [ "$out" = conflict-clear ] || fail "a conflict label younger than 15 minutes must not report conflict, got: $out"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "$out")
  [ "$decision" = quiet ] || fail "a young conflict label must stay quiet, got: $decision"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "a young conflict label must not open an episode"
  pass "a conflict label younger than 15 minutes stays quiet"
}

test_live_worker_is_steered_once() {
  local state json old decision log text
  reset_lib
  state="$TMP_ROOT/steer-state"
  json="$TMP_ROOT/steer.json"
  log="$TMP_ROOT/steer.log"
  rm -rf "$state" "$log"
  setup_task "$state"
  old=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$json" yes "$old"
  cat > "$TMP_ROOT/send.sh" <<SH
#!/usr/bin/env bash
printf 'CALLED\\n' >> "$log"
printf '%s\\n' "\$2" >> "$log"
SH
  chmod +x "$TMP_ROOT/send.sh"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send.sh
  # shellcheck disable=SC2329 # replaced for this case; fm_pr_conflict_handle calls it
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] || fail "a live worker must be steered instead of woken, got: $decision"
  text=$(cat "$log")
  printf '%s\n' "$text" | grep -qx CALLED || fail "the live worker was not steered"
  printf '%s\n' "$text" | grep -F 'https://github.com/o/r/pull/7' >/dev/null \
    || fail "the steer did not name the pull request"
  printf '%s\n' "$text" | grep -F 'Merge origin/curated into the branch with a merge commit' >/dev/null \
    || fail "the steer did not say to merge the base with a merge commit"
  printf '%s\n' "$text" | grep -Fx 'Do not rebase.' >/dev/null || fail "the steer did not forbid rebase"
  printf '%s\n' "$text" | grep -Fx 'Do not force-push.' >/dev/null || fail "the steer did not forbid force-push"
  : > "$log"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] || fail "the second steer look must stay quiet, got: $decision"
  [ ! -s "$log" ] || fail "the same conflict episode steered the worker twice"
  pass "a live worker is steered once to merge the base"
}

test_exited_worker_is_relaunched() {
  local state old decision send_log relaunch_log
  reset_lib
  state="$TMP_ROOT/relaunch-state"
  send_log="$TMP_ROOT/relaunch-send.log"
  relaunch_log="$TMP_ROOT/relaunch.log"
  rm -rf "$state" "$send_log" "$relaunch_log"
  setup_task "$state"
  old=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$TMP_ROOT/relaunch.json" yes "$old"
  cat > "$TMP_ROOT/send-relaunch.sh" <<SH
#!/usr/bin/env bash
printf 'CALLED\\n' >> "$send_log"
SH
  cat > "$TMP_ROOT/relaunch.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = lane ] && [ "\$2" = relaunch ] && [ "\$3" = --note ] && [ -n "\${4:-}" ] || exit 92
printf '%s\\n' "\$4" >> "$relaunch_log"
SH
  chmod +x "$TMP_ROOT/send-relaunch.sh" "$TMP_ROOT/relaunch.sh"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer and fm_pr_conflict_relaunch
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send-relaunch.sh
  # shellcheck disable=SC2034
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/relaunch.sh
  # shellcheck disable=SC2329 # replaced for this case; fm_pr_conflict_handle calls it
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] || fail "an exited worker must be relaunched instead of woken, got: $decision"
  grep -qx CALLED "$send_log" || fail "the relaunch did not leave the merge instruction"
  [ -s "$relaunch_log" ] || fail "the exited worker was not relaunched with a progress note"
  : > "$relaunch_log"
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] && [ ! -s "$relaunch_log" ] \
    || fail "the relaunched live worker must remain quiet"
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] && [ -s "$relaunch_log" ] \
    || fail "an unresolved episode must recover again after the worker exits"
  pass "an exited worker relaunches with a note despite a prior episode"
}

test_steered_worker_exit_recovers() {
  local state decision
  reset_lib
  state="$TMP_ROOT/steer-exit-state"
  setup_task "$state"
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send-relaunch.sh
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/relaunch.sh
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] || fail "initial steering failed"
  : > "$TMP_ROOT/relaunch.log"
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 conflict)
  [ "$decision" = quiet ] && [ -s "$TMP_ROOT/relaunch.log" ] \
    || fail "a worker exiting before handling its steer must relaunch"
  pass "a steered worker exiting before handling the inbox recovers"
}

test_watcher_conflict_recovery() {
  local home state mode pid i
  reset_lib
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  cat > "$TMP_ROOT/watch-send.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$TMP_ROOT/watch-relaunch.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = lane ] && [ "$2" = relaunch ] && [ "$3" = --note ] && [ -n "${4:-}" ] || exit 92
mkdir "$FM_HOME/state/.control-lane.lock" || exit 93
rmdir "$FM_HOME/state/.control-lane.lock" || exit 94
printf '%s\n' "$4" > "$FM_HOME/relaunched"
SH
  chmod +x "$FAKEBIN/tmux" "$TMP_ROOT/watch-send.sh" "$TMP_ROOT/watch-relaunch.sh"
  write_label_json "$TMP_ROOT/watch.json" yes \
    "$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')"
  for mode in wake relaunch; do
    home="$TMP_ROOT/watch-$mode"
    state="$home/state"
    mkdir -p "$home/config" "$home/data"
    setup_task "$state"
    if [ "$mode" = relaunch ]; then
      fm_write_meta "$state/lane.meta" 'base_branch=curated' 'window=firstmate:fm-lane'
    fi
    printf 'pr=https://github.com/o/r/pull/7\n' >> "$state/lane.meta"
    fm_pr_poll_prepare "$state" lane github https://github.com/o/r/pull/7 \
      github.com o/r 7 "$POLL" && fm_pr_poll_publish_prepared \
      || fail "could not arm the watcher fixture"
    fm_test_track_watcher_state "$state"
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_PR_CONFLICT_SEND="$TMP_ROOT/watch-send.sh" \
      FM_PR_CONFLICT_RELAUNCH="$TMP_ROOT/watch-relaunch.sh" \
      FM_CONFLICT_JSON="$TMP_ROOT/watch.json" FM_CHECK_INTERVAL=0 \
      FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      bash "$ROOT/bin/fm-watch.sh" > "$home/out" 2> "$home/err" &
    pid=$!
    i=0
    while [ "$i" -lt 200 ]; do
      if [ "$mode" = relaunch ]; then
        [ ! -s "$home/relaunched" ] || break
      else
        [ ! -f "$state/lane.pr-conflict-episode" ] || break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
      i=$((i + 1))
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    if [ "$mode" = relaunch ]; then
      [ -s "$home/relaunched" ] \
        || fail "watcher could not relaunch with its control lock and note requirements: $(cat "$home/err")"
    else
      [ -f "$state/lane.pr-conflict-episode" ] \
        || fail "watcher did not commit the fallback episode: $(cat "$home/err")"
      awk -F '\t' '$3 == "check" && $5 ~ /lane.check.sh: conflict$/ { found=1 } END { exit !found }' \
        "$state/.wake-queue" || fail "watcher suppressed a conflict without durable notification"
    fi
  done
  pass "watcher publishes fallback wakes and releases the relaunch lock"
}

test_overlap_names_both_pull_requests() {
  local repo brief sha1 sha2 sha4 prs out
  reset_lib
  repo="$TMP_ROOT/overlap-repo"
  brief="$TMP_ROOT/overlap-brief.md"
  prs="$TMP_ROOT/overlap-prs.json"
  rm -rf "$repo" "$TMP_ROOT/overlap-diffs"
  mkdir -p "$TMP_ROOT/overlap-diffs"
  git init -q -b main "$repo"
  printf 'base\n' > "$repo/shared.txt"
  printf 'keep\n' > "$repo/other.txt"
  git -C "$repo" add shared.txt other.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -q -b pr1
  printf 'one\n' > "$repo/shared.txt"
  git -C "$repo" commit -qam pr1
  sha1=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b pr2
  printf 'two\n' > "$repo/shared.txt"
  git -C "$repo" commit -qam pr2
  sha2=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  git -C "$repo" checkout -q -b pr4
  printf 'side\n' > "$repo/other.txt"
  git -C "$repo" commit -qam pr4
  sha4=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  printf 'shared.txt\n' > "$TMP_ROOT/overlap-diffs/3"
  jq -n --arg sha1 "$sha1" --arg sha2 "$sha2" --arg sha4 "$sha4" '[
    {number: 2, url: "https://github.com/o/r/pull/2", headRefOid: $sha2},
    {number: 1, url: "https://github.com/o/r/pull/1", headRefOid: $sha1},
    {number: 4, url: "https://github.com/o/r/pull/4", headRefOid: $sha4},
    {number: 3, url: "https://github.com/o/r/pull/3", headRefOid: "0123456789abcdef0123456789abcdef01234567"}
  ]' > "$prs"
  cat > "$brief" <<'EOF'
# Task
## SCOPE
shared.txt

## Firstmate spec
ship the change
EOF
  FM_OVERLAP_PRS=$prs FM_OVERLAP_DIFF_DIR=$TMP_ROOT/overlap-diffs \
    PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
    || fail "the overlap helper must not fail the caller"
  out=$(cat "$brief")
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/1' >/dev/null \
    || fail "the overlap note did not name the first pull request: $out"
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/2' >/dev/null \
    || fail "the overlap note did not name the second pull request: $out"
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/3' >/dev/null \
    || fail "the overlap note did not name the pull request whose file list was the fallback: $out"
  printf '%s\n' "$out" | grep -F 'https://github.com/o/r/pull/4' >/dev/null \
    && fail "the overlap note named a pull request that does not touch the planned file"
  [ "$(printf '%s\n' "$out" | grep -c '^## SHARED$')" -eq 1 ] \
    || fail "the overlap note was not a single SHARED section"
  FM_OVERLAP_PRS=$prs FM_OVERLAP_DIFF_DIR=$TMP_ROOT/overlap-diffs \
    PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
    || fail "a second overlap pass must not fail"
  [ "$(grep -c '^## SHARED$' "$brief")" -eq 1 ] \
    || fail "a second overlap pass duplicated the SHARED note"
  pass "the overlap helper names both pull requests that touch the planned file"
}

test_old_label_wakes_once_and_clear_removes_it
test_young_label_is_quiet
test_live_worker_is_steered_once
test_exited_worker_is_relaunched
test_steered_worker_exit_recovers
test_watcher_conflict_recovery
test_overlap_names_both_pull_requests
