#!/usr/bin/env bash
# Conflict-label observations and the read-only pull-request overlap note.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
OVERLAP="$ROOT/bin/fm-pr-overlap.sh"
LEGACY_POLL="$ROOT/tests/fixtures/fm-pr-poll-v1.sh"
CONFLICT_ADDED_AT=2026-01-01T00:00:00Z
TMP_ROOT=$(fm_test_tmproot fm-pr-conflict)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid
unset FM_PR_CONFLICT_SEND FM_PR_CONFLICT_RELAUNCH

FM_TEST_JQ_BIN=$(command -v jq) || fail "jq is required to build the label fixtures"
export FM_TEST_JQ_BIN

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' "${FM_TEST_GH_STATE-OPEN}"
    ;;
  "api graphql")
    slurp=0
    filter=0
    prog=
    prev=
    for arg in "$@"; do
      [ "$arg" != --slurp ] || slurp=1
      [ "$arg" != --jq ] || filter=1
      [ "$prev" != --jq ] || prog=$arg
      prev=$arg
    done
    if [ "$slurp" -eq 1 ] && [ "$filter" -eq 1 ]; then
      printf 'cannot use --slurp with --jq\n' >&2
      exit 91
    fi
    if [ "${FM_TEST_GRAPHQL_FAIL:-0}" = 1 ]; then
      printf 'fixture lookup failed\n' >&2
      exit 47
    fi
    [ -n "$prog" ] || exit 91
    "$FM_TEST_JQ_BIN" -r "$prog" "$FM_CONFLICT_JSON"
    ;;
  "pr list")
    cat "$FM_OVERLAP_PRS"
    ;;
  "api repos/"*)
    endpoint=${2%/files}
    number=${endpoint##*/}
    list="$FM_OVERLAP_DIFF_DIR/$number"
    [ -f "$list" ] || exit 91
    "$FM_TEST_JQ_BIN" -r "$5" "$list"
    ;;
  *)
    printf 'unexpected gh: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"
cat > "$FAKEBIN/jq" <<'SH'
#!/usr/bin/env bash
if [ "${FM_TEST_NO_STANDALONE_JQ:-0}" = 1 ] \
  && { [ "${FM_CHECK_OWNED_GROUP:-0}" = 1 ] || [ "${FM_TEST_DIRECT_POLL:-0}" = 1 ]; }; then
  printf 'standalone jq called\n' >> "$FM_TEST_JQ_CALLS"
  exit 97
fi
exec "$FM_TEST_JQ_BIN" "$@"
SH
chmod +x "$FAKEBIN/jq"


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
  FM_TEST_DIRECT_POLL=1 PATH="$FAKEBIN:$PATH" FM_CONFLICT_JSON="${FM_CONFLICT_JSON:-}" "$POLL" --validated github \
    https://github.com/o/r/pull/7 github.com o/r 7
}

setup_task() {
  local state=$1
  mkdir -p "$state"
  fm_write_meta "$state/lane.meta" 'base_branch=curated'
  export FM_TEST_INBOX_STATE=$state FM_TEST_INBOX_LOG=$state/inbox-send.log
}

test_graphql_failure_and_flag_contract() {
  local json out rc
  json="$TMP_ROOT/graphql-failure.json"
  write_label_json "$json" yes "$CONFLICT_ADDED_AT"
  rc=0
  FM_TEST_DIRECT_POLL=1 PATH="$FAKEBIN:$PATH" FM_CONFLICT_JSON="$json" gh api graphql --slurp --jq . \
    > "$TMP_ROOT/invalid-flags.out" 2> "$TMP_ROOT/invalid-flags.err" || rc=$?
  [ "$rc" -eq 91 ] || fail "the GitHub recorder accepted mutually exclusive flags"
  rc=0
  out=$(FM_CONFLICT_JSON="$json" FM_TEST_GRAPHQL_FAIL=1 run_poll 2> "$TMP_ROOT/lookup.err") || rc=$?
  [ "$rc" -eq 47 ] && [ -z "$out" ] || fail "lookup failure became a successful observation"
  grep -qx 'fixture lookup failed' "$TMP_ROOT/lookup.err" || fail "lookup diagnostics were lost"
  printf '{broken json\n' > "$json"
  rc=0
  out=$(FM_CONFLICT_JSON="$json" run_poll 2> "$TMP_ROOT/parse.err") || rc=$?
  [ "$rc" -ne 0 ] && [ -z "$out" ] || fail "invalid API JSON became a successful observation"
  pass "GraphQL rejects conflicting flags and preserves lookup and JSON failures"
}

test_gh_only_poll_and_terminal_states() {
  local json old out pr_state
  json="$TMP_ROOT/gh-only.json"
  old=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$json" yes "$old"
  out=$(FM_CONFLICT_JSON="$json" FM_TEST_NO_STANDALONE_JQ=1 \
    FM_TEST_JQ_CALLS="$TMP_ROOT/jq.calls" run_poll) \
    || fail "GitHub conflict polling required standalone jq"
  [ "$out" = "conflict:$old" ] || fail "gh-only polling lost the label application"
  [ ! -e "$TMP_ROOT/jq.calls" ] || fail "the poll invoked standalone jq"
  for pr_state in CLOSED UNKNOWN ''; do
    out=$(FM_TEST_GH_STATE="$pr_state" FM_TEST_GRAPHQL_FAIL=1 run_poll) \
      || fail "a non-open PR reached the label API ($pr_state)"
    [ -z "$out" ] || fail "a non-open PR produced recovery output ($pr_state)"
  done
  out=$(FM_TEST_GH_STATE=MERGED FM_TEST_GRAPHQL_FAIL=1 run_poll) \
    || fail "merge polling reached the label API"
  [ "$out" = merged ] || fail "merged PR lost its observation"
  pass "gh-only polling works and terminal PRs never emit conflict observations"
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
  [ "$out" = "conflict:$old" ] || fail "a conflict label older than 15 minutes must report conflict, got: $out"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "with no live worker the old label must wake once, got: $decision"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "an unpublished wake must remain retryable"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "interruption before publication must retry the wake"
  fm_pr_conflict_episode_open "$state" lane github github.com o/r 7 "$CONFLICT_ADDED_AT" \
    || fail "could not commit the published wake episode"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
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
"\$FM_TEST_INBOX_WRITER" "\$1" "\$2" || exit 1
printf 'steered lane\\n'
printf 'CALLED\\n' >> "$log"
printf '%s\\n' "\$2" >> "$log"
SH
  chmod +x "$TMP_ROOT/send.sh"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send.sh
  # shellcheck disable=SC2329 # replaced for this case; fm_pr_conflict_handle calls it
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
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
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
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
"\$FM_TEST_INBOX_WRITER" "\$1" "\$2" || exit 1
printf 'steered lane\\n'
printf 'CALLED\\n' >> "$send_log"
SH
  cat > "$TMP_ROOT/relaunch.sh" <<SH
#!/usr/bin/env bash
[ "\$1" = lane ] && [ "\$2" = relaunch ] && [ "\$3" = --note ] && [ -n "\${4:-}" ] || exit 92
printf 'relaunched lane\\n'
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
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "an exited worker must be relaunched instead of woken, got: $decision"
  [ ! -s "$send_log" ] || fail "a dead worker was steered"
  [ -s "$relaunch_log" ] || fail "the exited worker was not relaunched with a progress note"
  [ -f "$state/lane.pr-conflict-episode" ] || fail "relaunch did not commit the episode"
  cp "$relaunch_log" "$relaunch_log.once"
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "the relaunched live worker must remain quiet, got: $decision"
  cmp -s "$relaunch_log" "$relaunch_log.once" \
    || fail "the relaunched live worker was relaunched again"
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "an exited replacement must raise a fallback wake, got: $decision"
  assert_conflict_wake_published_once "$state"
  cmp -s "$relaunch_log" "$relaunch_log.once" \
    || fail "the same episode relaunched the dead worker again"
  [ ! -s "$send_log" ] || fail "the same episode steered the dead worker"
  pass "an exited worker is relaunched once and not steered"
}

test_steered_worker_exit_recovers() {
  local state decision
  reset_lib
  state="$TMP_ROOT/steer-exit-state"
  setup_task "$state"
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send-relaunch.sh
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/relaunch.sh
  : > "$TMP_ROOT/relaunch-send.log"
  : > "$TMP_ROOT/relaunch.log"
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "initial steering failed"
  [ "$(grep -c '^CALLED$' "$TMP_ROOT/relaunch-send.log")" -eq 1 ] \
    || fail "the live worker was not steered once"
  : > "$TMP_ROOT/relaunch.log"
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] && [ -s "$TMP_ROOT/relaunch.log" ] \
    || fail "a worker exiting before handling its steer must relaunch"
  [ "$(grep -c '^CALLED$' "$TMP_ROOT/relaunch-send.log")" -eq 1 ] \
    || fail "the exit recovery steered the worker again"
  cp "$TMP_ROOT/relaunch.log" "$TMP_ROOT/relaunch.log.once"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "an exited replacement must raise a fallback wake, got: $decision"
  assert_conflict_wake_published_once "$state"
  cmp -s "$TMP_ROOT/relaunch.log" "$TMP_ROOT/relaunch.log.once" \
    || fail "the same episode relaunched the exited worker again"
  pass "a steered worker exiting before handling the inbox recovers once"
}

test_action_failures_preserve_decision_protocol() {
  local state decision action_posture
  reset_lib
  state="$TMP_ROOT/action-failure-state"
  setup_task "$state"
  cat > "$TMP_ROOT/action-failure.sh" <<'SH'
#!/usr/bin/env bash
printf 'action status on stdout\n'
printf 'action diagnostic on stderr\n' >&2
exit 1
SH
  chmod +x "$TMP_ROOT/action-failure.sh"
  # shellcheck disable=SC2034 # read by the imported fm_pr_conflict_relaunch
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/action-failure.sh
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf '%s\n' "$action_posture"; }
  for action_posture in live exited; do
    if [ "$action_posture" = live ]; then
      FM_PR_CONFLICT_SEND=$TMP_ROOT/action-failure.sh
    else
      FM_PR_CONFLICT_SEND=$TMP_ROOT/send-relaunch.sh
    fi
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT" 2> "$state/diagnostics")
    [ "$decision" = wake ] || fail "failed $action_posture recovery contaminated the wake decision: $decision"
    grep -qx 'action status on stdout' "$state/diagnostics" \
      || fail "action stdout was not preserved as diagnostics"
    grep -qx 'action diagnostic on stderr' "$state/diagnostics" \
      || fail "action stderr was lost"
    [ ! -e "$state/lane.pr-conflict-episode" ] || fail "failed recovery suppressed a future attempt"
  done
  pass "failed steering and relaunch preserve decisions, diagnostics, and retryability"
}

test_relabel_starts_a_new_episode() {
  local state json first second out decision cleared
  reset_lib
  state="$TMP_ROOT/relabel-state"
  json="$TMP_ROOT/relabel.json"
  setup_task "$state"
  FM_CONFLICT_JSON=$json
  # shellcheck disable=SC2034 # read by the imported fm_pr_conflict_steer
  FM_PR_CONFLICT_SEND=$TMP_ROOT/send.sh
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'live\n'; }
  first=$(jq -nr 'now - 3600 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  second=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$json" yes "$first"
  jq '.data.repository.pullRequest.timelineItems.nodes = []' "$json" > "$TMP_ROOT/last-page.json"
  cat "$TMP_ROOT/last-page.json" >> "$json"
  [ "$(run_poll)" = "conflict:$first" ] \
    || fail "pagination lost the application identity from an earlier timeline page"
  for cleared in no yes; do
    write_label_json "$json" yes "$first"
    out=$(run_poll)
    [ "$out" = "conflict:$first" ] || fail "poll lost the first application identity"
    fm_pr_conflict_episode_open "$state" lane github github.com o/r 7 "$first" \
      || fail "could not save first application"
    : > "$TMP_ROOT/steer.log"
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "$out")
    [ "$decision" = quiet ] && [ ! -s "$TMP_ROOT/steer.log" ] \
      || fail "one application should be suppressed after publication"
    if [ "$cleared" = yes ]; then
      write_label_json "$json" no "$first" "$second"
      out=$(run_poll)
      decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
        https://github.com/o/r/pull/7 "$out")
      [ "$decision" = quiet ] && [ ! -e "$state/lane.pr-conflict-episode" ] \
        || fail "clear did not retire the first episode"
    fi
    write_label_json "$json" yes "$second"
    out=$(run_poll)
    [ "$out" = "conflict:$second" ] || fail "poll lost the new application identity"
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "$out")
    [ "$decision" = quiet ] && [ -s "$TMP_ROOT/steer.log" ] \
      || fail "a new label application was suppressed (clear observed: $cleared)"
    mkdir -p "$state/lane.inbox/handled"
    mv "$state/lane.inbox/"*.msg "$state/lane.inbox/handled/"
  done
  write_label_json "$json" yes ''
  [ -z "$(run_poll)" ] || fail "an unknown label application must not invent an episode identity"
  pass "relabel raises a new fix-now episode with or without an observed clear"
}

test_legacy_poll_authentication() {
  local state check
  reset_lib
  state="$TMP_ROOT/legacy-state"
  setup_task "$state"
  printf 'pr=https://github.com/o/r/pull/7\n' >> "$state/lane.meta"
  if ! fm_pr_poll_prepare "$state" lane github https://github.com/o/r/pull/7 \
    github.com o/r 7 "$LEGACY_POLL" || ! fm_pr_poll_publish_prepared; then
    fail "could not arm the historical poll protocol fixture"
  fi
  fm_pr_poll_snapshot_capture "$state" lane "$POLL" \
    || fail "a legacy registration lost authentication"
  check="$state/lane.check.sh"
  [ "$(PATH="$FAKEBIN:$PATH" FM_TEST_GH_STATE=MERGED bash "$check")" = merged ] \
    || fail "the legacy poll lost merge notifications"
  printf '\n' >> "$check"
  if fm_pr_poll_snapshot_capture "$state" lane "$POLL"; then
    fail "legacy compatibility accepted modified program bytes"
  fi
  pass "legacy polls authenticate and report merges while tampered programs fail"
}

test_watcher_conflict_recovery() {
  local home state mode pid i template gh_state endpoint graphql_fail watch_rc decision watch_added_at
  reset_lib
  cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = list-windows ]; then
  [ "${FM_TEST_ENDPOINT:-}" != live ] || printf 'fm-lane\n'
  exit 0
fi
if [ "${FM_TEST_ENDPOINT:-}" = live ] && [ "${1:-}" = display-message ]; then
  printf 'codex\n'
  exit 0
fi
exit 1
SH
  cat > "$TMP_ROOT/watch-send.sh" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_INBOX_WRITER" "$1" "$2" || exit 1
printf 'steered lane\n'
printf 'steered\n' > "$FM_HOME/steered"
exit 0
SH
  cat > "$TMP_ROOT/watch-relaunch.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = lane ] && [ "$2" = relaunch ] && [ "$3" = --note ] && [ -n "${4:-}" ] || exit 92
mkdir "$FM_HOME/state/.control-lane.lock" || exit 93
rmdir "$FM_HOME/state/.control-lane.lock" || exit 94
printf 'relaunched lane\n'
printf '%s\n' "$4" > "$FM_HOME/relaunched"
SH
  chmod +x "$FAKEBIN/tmux" "$TMP_ROOT/watch-send.sh" "$TMP_ROOT/watch-relaunch.sh"
  watch_added_at=$(jq -nr 'now - 1200 | strftime("%Y-%m-%dT%H:%M:%SZ")')
  write_label_json "$TMP_ROOT/watch.json" yes "$watch_added_at"
  for mode in wake relaunch legacy-conflict legacy-merged secondmate-live secondmate-exited secondmate-none current-failure legacy-failure closed; do
    home="$TMP_ROOT/watch-$mode"
    state="$home/state"
    mkdir -p "$home/config" "$home/data"
    setup_task "$state"
    if [ "$mode" = relaunch ]; then
      fm_write_meta "$state/lane.meta" 'base_branch=curated' 'window=firstmate:fm-lane'
    fi
    endpoint=
    case "$mode" in
      secondmate-*)
        fm_write_meta "$state/lane.meta" 'base_branch=curated' 'kind=secondmate'
        endpoint=${mode#secondmate-}
        [ "$endpoint" = none ] || printf 'window=firstmate:fm-lane\n' >> "$state/lane.meta"
        ;;
    esac
    printf 'pr=https://github.com/o/r/pull/7\n' >> "$state/lane.meta"
    template=$POLL
    gh_state=OPEN
    graphql_fail=0
    case "$mode" in *-failure) graphql_fail=1 ;; closed) gh_state=CLOSED ;; esac
    case "$mode" in legacy-*|secondmate-*) template=$LEGACY_POLL ;; esac
    [ "$mode" != legacy-merged ] || gh_state=MERGED
    if ! fm_pr_poll_prepare "$state" lane github https://github.com/o/r/pull/7 \
      github.com o/r 7 "$template" || ! fm_pr_poll_publish_prepared; then
      fail "could not arm the watcher fixture"
    fi
    fm_test_track_watcher_state "$state"
    PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_PR_CONFLICT_SEND="$TMP_ROOT/watch-send.sh" \
      FM_PR_CONFLICT_RELAUNCH="$TMP_ROOT/watch-relaunch.sh" \
      FM_TEST_NO_STANDALONE_JQ=1 FM_TEST_JQ_CALLS="$home/jq.calls" FM_TEST_GRAPHQL_FAIL="$graphql_fail" \
      FM_TEST_ENDPOINT="$endpoint" FM_TEST_GH_STATE="$gh_state" FM_CONFLICT_JSON="$TMP_ROOT/watch.json" FM_CHECK_INTERVAL=0 \
      FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      bash "$ROOT/bin/fm-watch.sh" > "$home/out" 2> "$home/err" &
    pid=$!
    i=0
    while [ "$i" -lt 600 ]; do
      if [ "$mode" = relaunch ]; then
        if fm_pr_conflict_episode_matches "$state" lane github github.com o/r 7 "$watch_added_at"; then
          break
        fi
      elif [ "$mode" = legacy-merged ]; then
        [ ! -s "$home/out" ] || break
      elif [ -n "$endpoint" ] || [ "$mode" = closed ]; then
        [ ! -f "$state/.last-check" ] || break
      else
        [ ! -f "$state/lane.pr-conflict-episode" ] || break
      fi
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.05
      i=$((i + 1))
    done
    kill "$pid" 2>/dev/null || true
    watch_rc=0
    wait "$pid" 2>/dev/null || watch_rc=$?
    [ ! -e "$home/jq.calls" ] || fail "watcher polling required standalone jq ($mode)"
    if [ "$mode" = relaunch ]; then
      [ -s "$home/relaunched" ] \
        || fail "watcher could not relaunch with its control lock and note requirements: $(cat "$home/err")"
      [ ! -e "$home/steered" ] \
        || fail "watcher steered a dead endpoint"
      [ "$(awk -F '\t' '$3 == "check" && $5 ~ /lane.check.sh: conflict$/ { n++ } END { print n+0 }' \
        "$state/.wake-queue")" -eq 1 ] || fail "watcher did not publish exactly one fallback wake"
      decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
        https://github.com/o/r/pull/7 "conflict:$watch_added_at")
      [ "$decision" = quiet ] || fail "watcher publication did not suppress the fallback"
    elif [ "$graphql_fail" -eq 1 ]; then
      [ "$watch_rc" -eq 47 ] || fail "$mode watcher swallowed the failed gh invocation ($watch_rc)"
      [ ! -s "$state/.wake-queue" ] && [ ! -e "$state/lane.pr-conflict-episode" ] \
        || fail "failed polling published successful conflict recovery"
    elif [ "$mode" = closed ]; then
      [ -f "$state/.last-check" ] || fail "closed fixture never completed its poll"
      [ ! -e "$home/steered" ] && [ ! -e "$home/relaunched" ] \
        && [ ! -s "$state/.wake-queue" ] && [ ! -e "$state/lane.pr-conflict-episode" ] \
        || fail "a closed pull request triggered conflict recovery"
    elif [ -n "$endpoint" ]; then
      [ -f "$state/.last-check" ] || fail "secondmate fixture never completed its poll"
      [ ! -e "$home/steered" ] && [ ! -e "$home/relaunched" ] \
        || fail "a secondmate conflict reached its parent worker ($endpoint)"
      [ ! -s "$state/.wake-queue" ] && [ ! -e "$state/lane.pr-conflict-episode" ] \
        || fail "a secondmate conflict published fallback recovery ($endpoint)"
    elif [ "$mode" = legacy-merged ]; then
      grep -q 'lane.check.sh: merged' "$home/out" \
        || fail "a legacy-armed watcher lost its merge notification: output=$(cat "$home/out") errors=$(cat "$home/err") triage=$(cat "$state/.watch-triage.log" 2>/dev/null)"
    else
      [ -f "$state/lane.pr-conflict-episode" ] \
        || fail "watcher did not commit the fallback episode: $(cat "$home/err")"
      awk -F '\t' '$3 == "check" && $5 ~ /lane.check.sh: conflict$/ { found=1 } END { exit !found }' \
        "$state/.wake-queue" || fail "watcher suppressed a conflict without durable notification"
      [ ! -e "$home/steered" ] && [ ! -e "$home/relaunched" ] \
        || fail "fallback wake also steered or relaunched ($mode)"
      if [ "$mode" = legacy-conflict ]; then
        cmp -s "$POLL" "$state/lane.check.sh" || fail "legacy poll was not upgraded through publication"
      fi
    fi
  done
  pass "watcher publishes fallback wakes and releases the relaunch lock"
}

test_overlap_names_both_pull_requests() {
  local repo brief sha1 sha2 sha4 prs out variant
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
  printf '[{"filename":"shared.txt"}]\n' > "$TMP_ROOT/overlap-diffs/3"
  jq -n --arg sha1 "$sha1" --arg sha2 "$sha2" --arg sha4 "$sha4" '[
    {number: 2, url: "https://github.com/o/r/pull/2", headRefOid: $sha2},
    {number: 1, url: "https://github.com/o/r/pull/1", headRefOid: $sha1},
    {number: 4, url: "https://github.com/o/r/pull/4", headRefOid: $sha4},
    {number: 3, url: "https://github.com/o/r/pull/3", headRefOid: "0123456789abcdef0123456789abcdef01234567"},
    {number: 5, url: "https://github.com/o/r/pull/5", headRefOid: "0123456789abcdef0123456789abcdef01234567"}
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
  grep -F 'https://github.com/o/r/pull/5 (unchecked:' "$brief" >/dev/null \
    || fail "a failed PR lookup was not reported as unchecked"
  for variant in "FILES: \`shared.txt\`" 'BLAST RADIUS: shared.txt' $'## FILES\n- `shared.txt`' $'## BLAST RADIUS\n- shared.txt'; do
    printf '# Task\n## Firstmate spec\n%s\n' "$variant" > "$brief"
    FM_OVERLAP_PRS=$prs FM_OVERLAP_DIFF_DIR=$TMP_ROOT/overlap-diffs \
      PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
      || fail "overlap blocked an ordinary brief"
    grep -F 'https://github.com/o/r/pull/1 (shared.txt)' "$brief" >/dev/null \
      || fail "planned paths in $variant were not compared"
  done
  printf '# Task\nNo paths declared.\n' > "$brief"
  PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
    || fail "missing planned paths blocked dispatch"
  grep -F 'Overlap was not checked: no planned paths' "$brief" >/dev/null \
    || fail "missing planned paths were silently skipped"
  [ "$(grep -c '^## SHARED$' "$brief")" -eq 1 ] || fail "missing paths duplicated SHARED"
  printf '## SCOPE\nshared.txt\n' > "$brief"
  printf '[{"number":5,"url":"https://github.com/o/r/pull/5"}]\n' > "$prs"
  FM_OVERLAP_PRS=$prs FM_OVERLAP_DIFF_DIR=$TMP_ROOT/overlap-diffs \
    PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
    || fail "failed lookups blocked dispatch"
  grep -F 'No overlap found among 0 compared open pull requests.' "$brief" >/dev/null \
    || fail "an unchecked PR was counted as compared"
  grep -F 'https://github.com/o/r/pull/5 (unchecked:' "$brief" >/dev/null \
    || fail "an unread PR was reported clean"
  printf '[]\n' > "$TMP_ROOT/overlap-diffs/5"
  FM_OVERLAP_PRS=$prs FM_OVERLAP_DIFF_DIR=$TMP_ROOT/overlap-diffs \
    PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
    || fail "an empty PR file list blocked dispatch"
  grep -F 'No overlap found among 1 compared open pull requests.' "$brief" >/dev/null \
    || fail "a successfully read empty file list was counted as unchecked"
  pass "overlap handles ordinary briefs and distinguishes compared from unchecked PRs"
}

test_rename_overlap_endpoints() {
  local repo brief prs head mode path
  repo="$TMP_ROOT/rename-repo"
  brief="$TMP_ROOT/rename-brief.md"
  prs="$TMP_ROOT/rename-prs.json"
  mkdir -p "$repo" "$TMP_ROOT/rename-files"
  git init -q -b main "$repo"
  printf 'preserve this content\n' > "$repo/old.txt"
  git -C "$repo" add old.txt
  git -C "$repo" commit -qm base
  git -C "$repo" checkout -qb rename
  git -C "$repo" mv old.txt new.txt
  git -C "$repo" commit -qm rename
  head=$(git -C "$repo" rev-parse HEAD)
  git -C "$repo" checkout -q main
  printf '[{"filename":"new.txt","previous_filename":"old.txt","status":"renamed"}]\n' \
    > "$TMP_ROOT/rename-files/6"
  for mode in merge-tree fallback; do
    [ "$mode" != fallback ] || head=0123456789abcdef0123456789abcdef01234567
    jq -n --arg head "$head" \
      '[{number:6,url:"https://github.com/o/r/pull/6",headRefOid:$head}]' > "$prs"
    for path in old.txt new.txt; do
      printf '## SCOPE\n%s\n' "$path" > "$brief"
      FM_OVERLAP_PRS="$prs" FM_OVERLAP_DIFF_DIR="$TMP_ROOT/rename-files" \
        PATH="$FAKEBIN:$PATH" "$OVERLAP" --project "$repo" --brief "$brief" \
        || fail "rename overlap blocked dispatch"
      grep -Fx -- "- https://github.com/o/r/pull/6 ($path)" "$brief" >/dev/null \
        || fail "$mode lost rename endpoint $path"
    done
  done
  pass "merge-tree and GitHub fallback report both rename endpoints"
}

load_inbox_helpers() {
  mkdir -p "$TMP_ROOT/inbox-home/state"
  export FM_HOME="$TMP_ROOT/inbox-home"
  export FM_STATE_OVERRIDE="$TMP_ROOT/inbox-home/state"
  export STATE="$FM_STATE_OVERRIDE"
  type fm_task_inbox_dir >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-task-inbox-lib.sh"
}

load_classify_helpers() {
  type last_status_line >/dev/null 2>&1 && type status_line_verb >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-classify-lib.sh"
}

write_inbox_send() {  # <path>
  cat > "$1" <<'SH'
#!/usr/bin/env bash
dir=$FM_TEST_INBOX_STATE/$1.inbox
mkdir -p "$dir/handled"
seq=1
while [ -e "$dir/$(printf '%03d' "$seq").msg" ] || [ -e "$dir/handled/$(printf '%03d' "$seq").msg" ]; do
  seq=$((seq + 1))
done
name=$(printf '%03d.msg' "$seq")
{
  printf 'schema=fm-task-inbox.v1\n'
  printf 'at=2026-01-01T00:00:00Z\n'
  printf -- '--\n'
  printf '%s' "$2"
} > "$dir/$name"
printf '1\n' >> "$FM_TEST_INBOX_LOG"
SH
  chmod +x "$1"
}

assert_conflict_wake_published_once() {
  local state=$1 decision
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "an unpublished fallback wake must remain retryable"
  fm_pr_conflict_episode_open "$state" lane github github.com o/r 7 "$CONFLICT_ADDED_AT" \
    || fail "could not commit the fallback wake"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "a published fallback wake must not repeat"
}

test_successful_steer_becomes_unavailable() {
  local state decision want_posture completed
  for completed in no yes; do
    for want_posture in live exited none unknown; do
      reset_lib
      load_classify_helpers
      state="$TMP_ROOT/steer-unavailable-$completed-$want_posture"
      setup_task "$state"
      FM_PR_CONFLICT_SEND=$TMP_ROOT/send.sh
      # shellcheck disable=SC2329
      fm_pr_conflict_posture() { printf 'live\n'; }
      decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
        https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
      [ "$decision" = quiet ] || fail "could not establish the successful steer"
      if [ "$completed" = yes ]; then
        printf 'done [at=1700000000]: finished\n' > "$state/lane.status"
      fi
      # shellcheck disable=SC2329
      fm_pr_conflict_posture() { printf '%s\n' "$want_posture"; }
      FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/action-failure.sh
      decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
        https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
      if [ "$completed" = no ] && [ "$want_posture" = live ]; then
        [ "$decision" = quiet ] || fail "an active steered worker must stay quiet"
      else
        [ "$decision" = wake ] || fail "unavailable $completed/$want_posture recovery must wake"
        assert_conflict_wake_published_once "$state"
      fi
    done
  done
  pass "successful steering wakes once when task or endpoint recovery becomes unavailable"
}

test_unread_steer_survives_relabel_and_clear() {
  local state decision log cleared next_added_at
  next_added_at=2026-02-02T00:00:00Z
  for cleared in no yes; do
    reset_lib
    load_inbox_helpers
    state="$TMP_ROOT/unread-relabel-$cleared"
    log="$TMP_ROOT/unread-relabel-$cleared.log"
    setup_task "$state"
    write_inbox_send "$TMP_ROOT/inbox-send.sh"
    export FM_TEST_INBOX_STATE=$state FM_TEST_INBOX_LOG=$log
    FM_PR_CONFLICT_SEND=$TMP_ROOT/inbox-send.sh
    # shellcheck disable=SC2329
    fm_pr_conflict_posture() { printf 'live\n'; }
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
    [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 1 ] \
      || fail "could not establish the unread steer"
    if [ "$cleared" = yes ]; then
      decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
        https://github.com/o/r/pull/7 conflict-clear)
      [ "$decision" = quiet ] || fail "conflict-clear must stay quiet"
    fi
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$next_added_at")
    [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 1 ] \
      || fail "relabel duplicated an unread steer (clear observed: $cleared)"
    mkdir -p "$state/lane.inbox/handled"
    mv "$state/lane.inbox/"*.msg "$state/lane.inbox/handled/"
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 conflict-clear)
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$next_added_at")
    [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 2 ] \
      || fail "an acknowledged steer blocked a later episode"
  done
  pass "unread steers deduplicate across relabeling with or without an observed clear"
}

test_upgrade_recovers_unbound_conflict_steer() {
  local state log decision marker legacy_text
  legacy_text=$(cat <<'TEXT'
The pull request https://github.com/o/r/pull/7 has carried the conflict label for more than 15 minutes.
Merge origin/old-base into the branch with a merge commit, regenerate generated files, run their tests, and push once.
Do not rebase.
Do not force-push.
TEXT
)
  for marker in absent v2; do
    reset_lib
    state="$TMP_ROOT/upgrade-unbound-$marker"
    setup_task "$state"
    log=$FM_TEST_INBOX_LOG
    "$FM_TEST_INBOX_WRITER" lane "$legacy_text" || fail "could not seed the pre-upgrade instruction"
    if [ "$marker" = v2 ]; then
      printf '%s\n' fm-pr-conflict-episode-v2 github github.com o/r 7 "$CONFLICT_ADDED_AT" \
        > "$state/lane.pr-conflict-episode"
      chmod 600 "$state/lane.pr-conflict-episode"
    fi
    FM_PR_CONFLICT_SEND=$FM_TEST_INBOX_WRITER
    # shellcheck disable=SC2329
    fm_pr_conflict_posture() { printf 'live\n'; }
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 conflict:2026-02-02T00:00:00Z)
    [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 1 ] \
      || fail "upgrade duplicated the unbound instruction ($marker)"
    [ "$(fm_pr_conflict_steer_recorded_basename "$state" lane github github.com o/r 7)" = 001.msg ] \
      || fail "upgrade did not bind the original unread record ($marker)"
  done
  pass "upgrade binds an unread conflict instruction despite changed base or label identity"
}

test_restart_recovers_enqueue_before_binding() {
  local state log decision
  reset_lib
  state="$TMP_ROOT/interrupted-binding"
  setup_task "$state"
  log=$FM_TEST_INBOX_LOG
  cat > "$TMP_ROOT/interrupted-send.sh" <<'SH'
#!/usr/bin/env bash
"$FM_TEST_INBOX_WRITER" "$1" "$2" || exit 1
exit 75
SH
  chmod +x "$TMP_ROOT/interrupted-send.sh"
  FM_PR_CONFLICT_SEND=$TMP_ROOT/interrupted-send.sh
  # shellcheck disable=SC2329
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] && [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "interrupted send did not leave exactly one durable instruction"
  [ ! -e "$state/lane.pr-conflict-steer" ] && [ ! -e "$state/lane.pr-conflict-episode" ] \
    || fail "interrupted send unexpectedly committed its binding"
  reset_lib
  FM_PR_CONFLICT_SEND=$FM_TEST_INBOX_WRITER
  # shellcheck disable=SC2329
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "restart duplicated the instruction enqueued before binding"
  [ "$(fm_pr_conflict_steer_recorded_basename "$state" lane github github.com o/r 7)" = 001.msg ] \
    || fail "restart did not bind the surviving instruction"
  pass "restart recovers an enqueue interrupted before sidecar binding"
}

test_binding_failure_blocks_repeat_send() {
  local state log decision
  reset_lib
  state="$TMP_ROOT/binding-failure"
  setup_task "$state"
  log=$FM_TEST_INBOX_LOG
  mkdir "$state/lane.pr-conflict-steer"
  FM_PR_CONFLICT_SEND=$FM_TEST_INBOX_WRITER
  # shellcheck disable=SC2329
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] && [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "post-send binding failure must wake after one enqueue"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "failed binding committed a successful action"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] && [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "pre-send binding failure allowed a duplicate enqueue"
  rmdir "$state/lane.pr-conflict-steer"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 1 ] \
    || fail "repaired binding did not recover the original instruction"
  pass "binding errors wake and block repeat sends until the existing record can be bound"
}

test_unbound_scan_respects_acknowledgement_and_identity() {
  local state log decision axis task host path number url text
  for axis in handled host path number task; do
    reset_lib
    state="$TMP_ROOT/unbound-scope-$axis"
    setup_task "$state"
    log=$FM_TEST_INBOX_LOG
    text=$(fm_pr_conflict_instruction https://github.com/o/r/pull/7 main)
    "$FM_TEST_INBOX_WRITER" lane "$text" || fail "could not seed the identity fixture"
    task=lane host=github.com path=o/r number=7
    case "$axis" in
      handled) cp "$state/lane.inbox/001.msg" "$state/lane.inbox/handled/001.msg" ;;
      host) host=github.example ;;
      path) path=other/repository ;;
      number) number=8 ;;
      task) task=other ;;
    esac
    url="https://$host/$path/pull/$number"
    FM_PR_CONFLICT_SEND=$FM_TEST_INBOX_WRITER
    # shellcheck disable=SC2329
    fm_pr_conflict_posture() { printf 'live\n'; }
    decision=$(fm_pr_conflict_handle "$state" "$task" github "$host" "$path" "$number" \
      "$url" "conflict:$CONFLICT_ADDED_AT")
    [ "$decision" = quiet ] && [ "$(wc -l < "$log")" -eq 2 ] \
      || fail "the inbox scan incorrectly suppressed a new steer ($axis)"
  done
  pass "unbound scans ignore acknowledgements and instructions for another task or PR"
}

test_v2_episode_preserves_recovery() {
  local state decision
  reset_lib
  load_classify_helpers
  state="$TMP_ROOT/v2-episode"
  setup_task "$state"
  printf '%s\n' fm-pr-conflict-episode-v2 github github.com o/r 7 "$CONFLICT_ADDED_AT" \
    > "$state/lane.pr-conflict-episode"
  chmod 600 "$state/lane.pr-conflict-episode"
  fm_pr_conflict_episode_matches "$state" lane github github.com o/r 7 "$CONFLICT_ADDED_AT" action \
    || fail "the v2 serialized episode must remain readable as a previous action"
  FM_PR_CONFLICT_SEND=$FM_TEST_INBOX_WRITER
  # shellcheck disable=SC2329
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] && [ ! -e "$FM_TEST_INBOX_LOG" ] \
    || fail "a live v2 episode repeated its action after upgrade"
  printf 'done [at=1700000000]: finished\n' > "$state/lane.status"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "a v2 episode suppressed unavailable recovery"
  assert_conflict_wake_published_once "$state"
  pass "v2 episodes suppress live repeats and preserve the unavailable-recovery fallback"
}

test_unread_conflict_steer_is_not_repeated() {
  local state decision log unhandled f
  reset_lib
  load_inbox_helpers
  state="$TMP_ROOT/unread-state"
  log="$TMP_ROOT/unread-send.log"
  rm -rf "$state" "$log"
  setup_task "$state"
  write_inbox_send "$TMP_ROOT/inbox-send.sh"
  export FM_TEST_INBOX_STATE=$state FM_TEST_INBOX_LOG=$log
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer
  FM_PR_CONFLICT_SEND=$TMP_ROOT/inbox-send.sh
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "unread steer setup did not steer, got: $decision"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "first sweep did not write one steer"
  [ -f "$state/lane.pr-conflict-episode" ] || fail "first sweep did not commit the episode"
  rm -f "$state/lane.pr-conflict-episode"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "repeat sweep with an unread steer woke, got: $decision"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "repeat sweep wrote another steer"
  [ -f "$state/lane.pr-conflict-episode" ] || fail "outstanding steer did not reopen the episode"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "third sweep woke, got: $decision"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "third sweep wrote another steer"
  unhandled=0
  for f in "$state/lane.inbox"/*.msg; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    unhandled=$((unhandled + 1))
  done
  [ "$unhandled" -eq 1 ] || fail "expected one unhandled steer, got $unhandled"
  pass "an unread conflict steer is not repeated"
}

test_done_task_wakes_once_without_steering() {
  local state decision want_posture send_log relaunch_log
  reset_lib
  load_classify_helpers
  state="$TMP_ROOT/done-state"
  send_log="$TMP_ROOT/done-send.log"
  relaunch_log="$TMP_ROOT/done-relaunch.log"
  rm -rf "$state" "$send_log" "$relaunch_log"
  setup_task "$state"
  printf 'done [at=1700000000]: finished\n' > "$state/lane.status"
  cat > "$TMP_ROOT/done-send.sh" <<EOF
#!/usr/bin/env bash
printf '1\\n' >> "$send_log"
EOF
  cat > "$TMP_ROOT/done-relaunch.sh" <<EOF
#!/usr/bin/env bash
printf '1\\n' >> "$relaunch_log"
EOF
  chmod +x "$TMP_ROOT/done-send.sh" "$TMP_ROOT/done-relaunch.sh"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer and fm_pr_conflict_relaunch
  FM_PR_CONFLICT_SEND=$TMP_ROOT/done-send.sh
  # shellcheck disable=SC2034
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/done-relaunch.sh
  for want_posture in live exited none; do
    rm -f "$state/lane.pr-conflict-episode" "$state/lane.pr-conflict-relaunched" \
      "$state/lane.pr-conflict-steer" "$send_log" "$relaunch_log"
    # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
    fm_pr_conflict_posture() { printf '%s\n' "$want_posture"; }
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
    [ "$decision" = wake ] || fail "done $want_posture first look must wake, got: $decision"
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
    [ "$decision" = wake ] || fail "done $want_posture unpublished wake must retry, got: $decision"
    [ ! -s "$send_log" ] || fail "done $want_posture was steered"
    [ ! -s "$relaunch_log" ] || fail "done $want_posture was relaunched"
    [ ! -e "$state/lane.pr-conflict-episode" ] \
      || fail "done $want_posture opened an episode before publication"
    fm_pr_conflict_episode_open "$state" lane github github.com o/r 7 "$CONFLICT_ADDED_AT" \
      || fail "could not commit the done-task wake"
    decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
      https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
    [ "$decision" = quiet ] || fail "done $want_posture published look must stay quiet, got: $decision"
    [ ! -s "$send_log" ] && [ ! -s "$relaunch_log" ] \
      || fail "done $want_posture acted after the wake"
  done
  pass "a done task is not steered and wakes once"
}

test_dead_endpoint_relaunches_or_wakes_once() {
  local state decision send_log relaunch_log
  reset_lib
  state="$TMP_ROOT/dead-state"
  send_log="$TMP_ROOT/dead-send.log"
  relaunch_log="$TMP_ROOT/dead-relaunch.log"
  rm -rf "$state" "$send_log" "$relaunch_log"
  setup_task "$state"
  export FM_TEST_SEND_LOG=$send_log FM_TEST_RELAUNCH_LOG=$relaunch_log
  cat > "$TMP_ROOT/dead-send.sh" <<'SH'
#!/usr/bin/env bash
printf '1\n' >> "$FM_TEST_SEND_LOG"
SH
  cat > "$TMP_ROOT/dead-relaunch.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" = lane ] && [ "$2" = relaunch ] && [ "$3" = --note ] && [ -n "${4:-}" ] || exit 92
printf '1\n' >> "$FM_TEST_RELAUNCH_LOG"
SH
  cat > "$TMP_ROOT/dead-relaunch-fail.sh" <<'SH'
#!/usr/bin/env bash
printf '1\n' >> "$FM_TEST_RELAUNCH_LOG"
exit 1
SH
  chmod +x "$TMP_ROOT/dead-send.sh" "$TMP_ROOT/dead-relaunch.sh" "$TMP_ROOT/dead-relaunch-fail.sh"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer and fm_pr_conflict_relaunch
  FM_PR_CONFLICT_SEND=$TMP_ROOT/dead-send.sh
  # shellcheck disable=SC2034
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/dead-relaunch.sh
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'exited\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "a dead endpoint must relaunch instead of waking, got: $decision"
  [ "$(wc -l < "$relaunch_log")" -eq 1 ] || fail "a dead endpoint was not relaunched once"
  [ ! -s "$send_log" ] || fail "a dead endpoint was steered"
  [ -f "$state/lane.pr-conflict-episode" ] || fail "relaunch did not commit the episode"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "an exited replacement must raise a fallback wake, got: $decision"
  assert_conflict_wake_published_once "$state"
  [ "$(wc -l < "$relaunch_log")" -eq 1 ] || fail "the same episode relaunched again"
  [ ! -s "$send_log" ] || fail "the second dead sweep steered"
  rm -rf "$state"
  setup_task "$state"
  : > "$relaunch_log"
  rm -f "$send_log"
  # shellcheck disable=SC2034 # read by fm_pr_conflict_relaunch
  FM_PR_CONFLICT_RELAUNCH=$TMP_ROOT/dead-relaunch-fail.sh
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "a failed relaunch must wake, got: $decision"
  [ "$(wc -l < "$relaunch_log")" -eq 1 ] || fail "a failed relaunch was not attempted once"
  [ ! -e "$state/lane.pr-conflict-episode" ] || fail "a failed relaunch committed the episode"
  [ ! -s "$send_log" ] || fail "a failed relaunch steered"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = wake ] || fail "an unpublished failed relaunch must still wake, got: $decision"
  [ "$(wc -l < "$relaunch_log")" -eq 1 ] || fail "a failed relaunch was attempted again"
  pass "a dead endpoint relaunches once or wakes once and is not steered"
}

test_acked_steer_allows_next_episode() {
  local state decision log next_added_at
  reset_lib
  load_inbox_helpers
  state="$TMP_ROOT/ack-state"
  log="$TMP_ROOT/ack-send.log"
  next_added_at=2026-02-02T00:00:00Z
  rm -rf "$state" "$log"
  setup_task "$state"
  write_inbox_send "$TMP_ROOT/inbox-send.sh"
  export FM_TEST_INBOX_STATE=$state FM_TEST_INBOX_LOG=$log
  # shellcheck disable=SC2034 # read by fm_pr_conflict_steer
  FM_PR_CONFLICT_SEND=$TMP_ROOT/inbox-send.sh
  # shellcheck disable=SC2329 # called by the imported fm_pr_conflict_handle
  fm_pr_conflict_posture() { printf 'live\n'; }
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "first episode did not steer, got: $decision"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "first episode did not write one steer"
  mkdir -p "$state/lane.inbox/handled"
  mv "$state/lane.inbox/"*.msg "$state/lane.inbox/handled/"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$CONFLICT_ADDED_AT")
  [ "$decision" = quiet ] || fail "acknowledged same episode woke, got: $decision"
  [ "$(wc -l < "$log")" -eq 1 ] || fail "acknowledged same episode steered again"
  decision=$(fm_pr_conflict_handle "$state" lane github github.com o/r 7 \
    https://github.com/o/r/pull/7 "conflict:$next_added_at")
  [ "$decision" = quiet ] || fail "next episode did not steer, got: $decision"
  [ "$(wc -l < "$log")" -eq 2 ] || fail "an acknowledged steer blocked the next episode"
  pass "an acknowledged steer allows the next episode's steer"
}

load_inbox_helpers
write_inbox_send "$TMP_ROOT/inbox-write.sh"
export FM_TEST_INBOX_WRITER=$TMP_ROOT/inbox-write.sh

test_graphql_failure_and_flag_contract
test_gh_only_poll_and_terminal_states
test_old_label_wakes_once_and_clear_removes_it
test_young_label_is_quiet
test_live_worker_is_steered_once
test_exited_worker_is_relaunched
test_steered_worker_exit_recovers
test_action_failures_preserve_decision_protocol
test_legacy_poll_authentication
test_relabel_starts_a_new_episode
test_watcher_conflict_recovery
test_overlap_names_both_pull_requests
test_rename_overlap_endpoints
test_upgrade_recovers_unbound_conflict_steer
test_restart_recovers_enqueue_before_binding
test_binding_failure_blocks_repeat_send
test_unbound_scan_respects_acknowledgement_and_identity
test_v2_episode_preserves_recovery
test_unread_conflict_steer_is_not_repeated
test_unread_steer_survives_relabel_and_clear
test_successful_steer_becomes_unavailable
test_done_task_wakes_once_without_steering
test_dead_endpoint_relaunches_or_wakes_once
test_acked_steer_allows_next_episode
