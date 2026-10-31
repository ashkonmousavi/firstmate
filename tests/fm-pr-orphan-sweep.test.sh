#!/usr/bin/env bash
# Conflicted pull requests that no task poll watches: bin/fm-pr-orphan-sweep.sh
# and the watcher's check sweep that runs it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

SWEEP="$ROOT/bin/fm-pr-orphan-sweep.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
URL=https://github.com/o/r/pull/7
TMP_ROOT=$(fm_test_tmproot fm-pr-orphan-sweep)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid

FM_TEST_JQ_BIN=$(command -v jq) || fail "jq is required to build the label fixtures"
export FM_TEST_JQ_BIN

# A recording gh: `pr list` prints the fixture listing (the sweep asks gh to
# render number<TAB>head itself), `pr view` the fixture state, and
# `api graphql` runs the poll's own jq program over the label fixture.
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_GH_LOG"
case "${1:-} ${2:-}" in
  "pr list")
    [ "${FM_TEST_LIST_FAIL:-0}" = 0 ] || { printf 'fixture listing failed\n' >&2; exit 41; }
    cat "$FM_TEST_PR_LIST"
    ;;
  "pr view")
    printf '%s\n' "${FM_TEST_GH_STATE-OPEN}"
    ;;
  "api graphql")
    prog=
    prev=
    for arg in "$@"; do
      [ "$prev" != --jq ] || prog=$arg
      prev=$arg
    done
    [ -n "$prog" ] || exit 91
    "$FM_TEST_JQ_BIN" -r "$prog" "$FM_CONFLICT_JSON"
    ;;
  *)
    printf 'unexpected gh: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != list-windows ] || exit 0
exit 1
SH
chmod +x "$FAKEBIN/tmux"

iso_ago() {  # <seconds>
  # shellcheck disable=SC2016 # A jq program, not shell.
  "$FM_TEST_JQ_BIN" -nr --argjson s "$1" 'now - $s | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

write_label_json() {  # <file> <labeled-at>
  # shellcheck disable=SC2016 # A jq program, not shell.
  "$FM_TEST_JQ_BIN" -n --arg labeled "$2" '
    { data: { repository: { pullRequest: {
      labels: { nodes: [{name: "conflict"}] },
      timelineItems: { nodes: [
        {__typename: "LabeledEvent", createdAt: $labeled, label: {name: "conflict"}}
      ] }
    } } } }' > "$1"
}

# A home whose task "lane" opened $URL on branch fm/lane and was then torn
# down: no state/lane.meta, no poll, only the backlog may still name it.
make_home() {  # <home> [registry-annotation]
  local home=$1 annotation=${2:-direct-PR +yolo}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf -- '- proj [%s] - orphan sweep fixture\n' "$annotation" > "$home/data/projects.md"
  git init -q -b main "$home/projects/proj"
  git -C "$home/projects/proj" remote add origin https://github.com/o/r.git
  printf '7\tfm/lane\n12\tdependabot/pip/x\n' > "$home/pr-list.tsv"
  write_label_json "$home/label.json" "$(iso_ago 1200)"
  : > "$home/gh.log"
}

run_sweep() {  # <home> [args...]
  local home=$1
  shift
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_TEST_GH_LOG="$home/gh.log" \
    FM_TEST_PR_LIST="$home/pr-list.tsv" FM_CONFLICT_JSON="$home/label.json" \
    FM_PR_ORPHAN_SHOW_CMD="${SHOW_CMD:-false}" \
    bash "$SWEEP" "$@"
}

orphan_wakes() {  # <state>
  [ -f "$1/.wake-queue" ] || { printf '0\n'; return 0; }
  awk -F '\t' '$3 == "check" && $5 ~ /^check: pr-orphan-conflict: / { n++ } END { print n+0 }' "$1/.wake-queue"
}

test_torn_down_task_conflict_wakes_once() {
  local home=$TMP_ROOT/torn-down out
  make_home "$home"
  out=$(run_sweep "$home" 2> "$home/err") || fail "sweep failed: $(cat "$home/err")"
  case "$out" in
    "check: pr-orphan-conflict: $URL (branch fm/lane) has carried the conflict label since "*"no task poll watches it; owner: no task in this home's backlog is named lane") ;;
    *) fail "torn-down task's conflicted pull request did not wake: [$out] $(cat "$home/err")" ;;
  esac
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "a branch outside the ship prefix woke: $out"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the wake was not queued durably"
  [ -f "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "no episode marker was recorded"
  out=$(run_sweep "$home" 2>&1) || fail "second sweep failed"
  [ -z "$out" ] || fail "the same label episode woke twice: $out"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the same label episode queued a second wake"
  [ "$(grep -c '^api graphql' "$home/gh.log")" = 1 ] \
    || fail "a recorded episode was read from the forge again"
  pass "a torn-down task's conflicted pull request wakes its home once per label episode"
}

test_young_label_is_quiet() {
  local home=$TMP_ROOT/young out
  make_home "$home"
  write_label_json "$home/label.json" "$(iso_ago 300)"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 0 ] \
    || fail "a label younger than 15 minutes woke: $out"
  [ ! -e "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "a young label recorded an episode"
  write_label_json "$home/label.json" "$(iso_ago 901)"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the label did not wake once it passed 15 minutes: $out"
  pass "a conflict label wakes only once it is at least 15 minutes old"
}

test_live_poll_covers_then_teardown_uncovers() {
  local home=$TMP_ROOT/covered out
  make_home "$home"
  fm_write_meta "$home/state/lane.meta" 'kind=ship' "pr=$URL"
  if ! fm_pr_poll_prepare "$home/state" lane github "$URL" github.com o/r 7 "$POLL" \
    || ! fm_pr_poll_publish_prepared; then
    fail "could not arm the task poll fixture"
  fi
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 0 ] \
    || fail "a pull request its task poll still watches woke the sweep: $out"
  ! grep -q '^api graphql' "$home/gh.log" || fail "a covered pull request was read from the forge"
  # Cleanup removes the record and its poll, as bin/fm-teardown.sh does.
  rm -f "$home/state/lane.meta" "$home/state/lane.check.sh" "$home/state/lane.pr-poll" \
    "$home/state/lane.pr-poll-registration"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the pull request was not noticed after its poll was removed: $out"
  pass "a live task poll owns its pull request and the sweep takes over once it is gone"
}

test_label_removal_prunes_and_relabel_wakes_again() {
  local home=$TMP_ROOT/relabel out
  make_home "$home"
  run_sweep "$home" > /dev/null 2>&1 || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "first episode did not wake"
  FM_TEST_LIST_FAIL=1 run_sweep "$home" > "$home/out" 2> "$home/err" || fail "a failed listing failed the sweep"
  grep -q 'could not list conflicted pull requests for proj (o/r)' "$home/err" \
    || fail "a failed listing was not reported: $(cat "$home/err")"
  [ -f "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "a failed listing pruned an episode"
  : > "$home/pr-list.tsv"
  run_sweep "$home" > /dev/null 2>&1 || fail "sweep failed"
  [ ! -e "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "a removed label kept its episode"
  printf '7\tfm/lane\n' > "$home/pr-list.tsv"
  write_label_json "$home/label.json" "$(iso_ago 1000)"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 2 ] || fail "a re-applied label did not wake again: $out"
  pass "a removed label clears its episode, a failed listing keeps it, and a new label wakes again"
}

test_owner_routing() {
  local home=$TMP_ROOT/owned mate=$TMP_ROOT/mate out
  make_home "$home"
  out=$(SHOW_CMD=true run_sweep "$home" 2>&1) || fail "sweep failed"
  case "$out" in
    *"owner: task lane in this home's backlog") ;;
    *) fail "a task this home's backlog holds was not named as its owner: $out" ;;
  esac
  make_home "$mate"
  printf 'q-server\n' > "$mate/.fm-secondmate-home"
  out=$(run_sweep "$mate" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$mate/state")" = 0 ] \
    || fail "a secondmate woke for a pull request its backlog does not hold: $out"
  ! grep -q '^api graphql' "$mate/gh.log" || fail "a secondmate read an unclaimed pull request's label"
  out=$(SHOW_CMD=true run_sweep "$mate" 2>&1) || fail "sweep failed"
  [ "$(orphan_wakes "$mate/state")" = 1 ] || fail "a secondmate did not wake for its own task: $out"
  pass "the wake names this home's task, a main home reports unclaimed work, and a secondmate only its own"
}

test_unswept_projects_and_report_mode() {
  local home=$TMP_ROOT/local-only out
  make_home "$home" local-only
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ ! -s "$home/gh.log" ] || fail "a local-only project was swept: $out"
  home=$TMP_ROOT/report
  make_home "$home"
  out=$(run_sweep "$home" --report 2>&1) || fail "report failed"
  case "$out" in
    "check: pr-orphan-conflict: $URL "*) ;;
    *) fail "report mode did not print the would-be wake: $out" ;;
  esac
  [ "$(orphan_wakes "$home/state")" = 0 ] && [ ! -e "$home/state/pr-orphan-conflict" ] \
    || fail "report mode wrote a wake or an episode"
  run_sweep "$home" --bogus > /dev/null 2>&1 && fail "bad usage was accepted"
  pass "local-only projects are not swept and report mode writes nothing"
}

test_watcher_wakes_owner_home() {
  local home=$TMP_ROOT/watch pid i
  make_home "$home"
  fm_test_track_watcher_state "$home/state"
  PATH="$FAKEBIN:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_GH_LOG="$home/gh.log" FM_TEST_PR_LIST="$home/pr-list.tsv" \
    FM_CONFLICT_JSON="$home/label.json" FM_PR_ORPHAN_SHOW_CMD=false \
    FM_CHECK_INTERVAL=0 FM_POLL=0.05 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    bash "$ROOT/bin/fm-watch.sh" > "$home/out" 2> "$home/err" &
  pid=$!
  i=0
  while [ "$i" -lt 600 ]; do
    [ "$(orphan_wakes "$home/state")" = 0 ] || break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  i=0
  while [ "$i" -lt 200 ] && ! grep -q 'pr-orphan-conflict' "$home/out"; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [ "$(orphan_wakes "$home/state")" = 1 ] \
    || fail "the watcher did not queue the orphan conflict wake: $(cat "$home/err")"
  grep -q "check: pr-orphan-conflict: $URL" "$home/out" \
    || fail "the watcher did not wake its home: out=$(cat "$home/out") err=$(cat "$home/err")"
  pass "the watcher's check sweep wakes the home for a torn-down task's conflicted pull request"
}

test_torn_down_task_conflict_wakes_once
test_young_label_is_quiet
test_live_poll_covers_then_teardown_uncovers
test_label_removal_prunes_and_relabel_wakes_again
test_owner_routing
test_unswept_projects_and_report_mode
test_watcher_wakes_owner_home
