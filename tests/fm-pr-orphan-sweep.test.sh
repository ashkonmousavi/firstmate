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
    repo=
    limit=
    prev=
    for arg in "$@"; do
      [ "$prev" != -R ] || repo=$arg
      [ "$prev" != --limit ] || limit=$arg
      prev=$arg
    done
    [ "$repo" = o/r ] || { printf 'unexpected repository: %s\n' "$repo" >&2; exit 91; }
    [ "${FM_TEST_LIST_FAIL:-0}" = 0 ] || { printf 'fixture listing failed\n' >&2; exit 41; }
    head -n "$limit" "$FM_TEST_PR_LIST"
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
  [ "$(grep -c '^api graphql' "$home/gh.log")" = 2 ] \
    || fail "a recorded episode's current label timestamp was not checked again"
  pass "a torn-down task's conflicted pull request wakes its home once per label episode"
}

test_publication_target_selection() {
  local layout home clone out
  for layout in upstream github marked-custom marked-origin upstream-only scp ssh local-hop; do
    home=$TMP_ROOT/target-$layout
    make_home "$home"
    clone=$home/projects/proj
    git -C "$clone" remote set-url origin https://github.com/personal/fork.git
    case "$layout" in
      upstream|upstream-only)
        git -C "$clone" remote add upstream https://github.com/o/r.git
        git -C "$clone" remote add github https://github.com/other/repo.git
        [ "$layout" != upstream-only ] || git -C "$clone" remote remove origin
        ;;
      github)
        git -C "$clone" remote add github https://github.com/o/r.git
        ;;
      marked-custom|marked-origin)
        git -C "$clone" remote add upstream https://github.com/other/repo.git
        if [ "$layout" = marked-custom ]; then
          git -C "$clone" remote add destination ssh://git@github.com/O/R.git
          git -C "$clone" config remote.destination.gh-resolved base
        else
          git -C "$clone" remote set-url origin https://github.com/o/r.git
          git -C "$clone" config remote.origin.gh-resolved base
        fi
        ;;
      scp)
        git -C "$clone" remote set-url origin git@github.com:O/R.git
        ;;
      ssh)
        git -C "$clone" remote set-url origin ssh://git@github.com/O/R.git
        ;;
      local-hop)
        git init -q -b main "$home/destination"
        git -C "$home/destination" remote add origin https://github.com/o/r.git
        git -C "$clone" remote add upstream "$home/destination"
        ;;
    esac
    out=$(run_sweep "$home" 2> "$home/err") || fail "$layout sweep failed"
    case "$out" in
      "check: pr-orphan-conflict: $URL "*) ;;
      *) fail "$layout did not wake for the destination PR: [$out] $(cat "$home/err")" ;;
    esac
    [ "$(orphan_wakes "$home/state")" = 1 ] || fail "$layout did not queue the destination wake"
    [ -f "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "$layout did not mark the destination episode"
    grep -q "pr-orphan:$URL" "$home/state/.wake-queue" || fail "$layout queued the wrong PR identity"
    grep -Fq "pr view $URL " "$home/gh.log" || fail "$layout polled the wrong PR"
    grep -Fq 'api graphql --paginate -f owner=o -f repo=r -F number=7 ' "$home/gh.log" \
      || fail "$layout read the wrong destination label"
  done
  pass "orphan discovery uses the documented publication target across fork layouts and remote forms"
}

test_unsupported_publication_targets_are_quiet() {
  local layout home clone out
  for layout in non-github malformed empty-marked no-remote; do
    home=$TMP_ROOT/unsupported-$layout
    make_home "$home"
    clone=$home/projects/proj
    case "$layout" in
      non-github) git -C "$clone" remote add upstream https://gitlab.com/o/r.git ;;
      malformed) git -C "$clone" remote add upstream https://github.com/o/r/extra.git ;;
      empty-marked)
        git -C "$clone" config remote.destination.gh-resolved base
        ;;
      no-remote) git -C "$clone" remote remove origin ;;
    esac
    out=$(run_sweep "$home" 2>&1) || fail "$layout sweep failed"
    [ -z "$out" ] && [ ! -s "$home/gh.log" ] && [ "$(orphan_wakes "$home/state")" = 0 ] \
      || fail "$layout queried or woke for an unsupported destination: $out"
  done
  pass "unsupported or unresolved publication targets never fall back to the fork"
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
  local home out path poll_url i=0
  for path in o/r O/r o/R O/R; do
    i=$((i + 1))
    home=$TMP_ROOT/covered-$i
    poll_url=https://github.com/$path/pull/7
    make_home "$home"
    git -C "$home/projects/proj" remote set-url origin https://github.com/personal/fork.git
    git -C "$home/projects/proj" remote add upstream "https://github.com/$path.git"
    fm_write_meta "$home/state/lane.meta" 'kind=ship' "pr=$poll_url"
    if ! fm_pr_poll_prepare "$home/state" lane github "$poll_url" github.com "$path" 7 "$POLL" \
      || ! fm_pr_poll_publish_prepared; then
      fail "could not arm the task poll fixture"
    fi
    cp "$home/state/lane.pr-poll" "$home/poll.before"
    cp "$home/state/lane.pr-poll-registration" "$home/registration.before"
    cp "$home/state/lane.meta" "$home/meta.before"
    out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
    [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 0 ] \
      || fail "$path's watched pull request woke the sweep: $out"
    ! grep -q '^api graphql' "$home/gh.log" || fail "a covered pull request was read from the forge"
    cmp -s "$home/state/lane.pr-poll" "$home/poll.before" || fail "coverage changed authenticated poll bytes"
    cmp -s "$home/state/lane.pr-poll-registration" "$home/registration.before" || fail "coverage changed registration bytes"
    cmp -s "$home/state/lane.meta" "$home/meta.before" || fail "coverage changed task metadata"
    fm_pr_poll_artifacts_valid "$home/state" lane "$POLL" || fail "coverage invalidated poll authentication"
    rm -f "$home/state/lane.meta" "$home/state/lane.check.sh" "$home/state/lane.pr-poll" \
      "$home/state/lane.pr-poll-registration"
    out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
    [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the pull request was not noticed after its poll was removed: $out"
  done
  pass "authenticated polls cover the destination regardless of owner and repository case until teardown"
}

test_episode_survives_listing_gaps() {
  local home=$TMP_ROOT/listing-gaps out i
  make_home "$home"
  run_sweep "$home" > /dev/null 2>&1 || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "first episode did not wake"
  cp "$home/state/pr-orphan-conflict/github.com/o/r/7" "$home/marker.before"
  FM_TEST_LIST_FAIL=1 run_sweep "$home" > "$home/out" 2> "$home/err" || fail "a failed listing failed the sweep"
  grep -q 'could not list conflicted pull requests for proj (o/r)' "$home/err" \
    || fail "a failed listing was not reported: $(cat "$home/err")"
  [ -f "$home/state/pr-orphan-conflict/github.com/o/r/7" ] || fail "a failed listing pruned an episode"
  : > "$home/pr-list.tsv"
  run_sweep "$home" > /dev/null 2>&1 || fail "sweep failed"
  cmp -s "$home/marker.before" "$home/state/pr-orphan-conflict/github.com/o/r/7" || fail "listing omission erased episode identity"
  i=100
  while [ "$i" -lt 300 ]; do
    printf '%s\tdependabot/pkg/%s\n' "$i" "$i" >> "$home/pr-list.tsv"
    i=$((i + 1))
  done
  printf '7\tfm/lane\n' >> "$home/pr-list.tsv"
  run_sweep "$home" > /dev/null 2>&1 || fail "capped sweep failed"
  cmp -s "$home/marker.before" "$home/state/pr-orphan-conflict/github.com/o/r/7" || fail "a capped listing erased episode identity"
  printf '7\tfm/lane\n' > "$home/pr-list.tsv"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 1 ] || fail "the same episode woke after a listing gap: $out"
  pass "failed, empty, and capped listings preserve an episode without another wake"
}

test_relabel_between_sweeps_wakes_again() {
  local home=$TMP_ROOT/relabel out old added
  make_home "$home"
  old=$(iso_ago 2400)
  added=$(iso_ago 1200)
  write_label_json "$home/label.json" "$old"
  run_sweep "$home" > /dev/null 2>&1 || fail "first episode sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "first episode did not wake"
  write_label_json "$home/label.json" "$added"
  out=$(run_sweep "$home" 2>&1) || fail "relabel sweep failed"
  [ "$(orphan_wakes "$home/state")" = 2 ] || fail "a re-applied label between sweeps did not wake: $out"
  [ "$(tail -1 "$home/state/pr-orphan-conflict/github.com/o/r/7")" = "$added" ] || fail "the new label timestamp was not recorded"
  out=$(run_sweep "$home" 2>&1) || fail "repeat sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 2 ] || fail "the new episode woke twice: $out"
  pass "a label reapplied between sweeps wakes once for its new timestamp"
}

test_episode_survives_temporary_coverage() {
  local home=$TMP_ROOT/temporary-coverage out
  make_home "$home"
  run_sweep "$home" > /dev/null 2>&1 || fail "first episode sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "first episode did not wake"
  cp "$home/state/pr-orphan-conflict/github.com/o/r/7" "$home/marker.before"
  fm_write_meta "$home/state/lane.meta" 'kind=ship' "pr=$URL"
  if ! fm_pr_poll_prepare "$home/state" lane github "$URL" github.com o/r 7 "$POLL" \
    || ! fm_pr_poll_publish_prepared; then
    fail "could not arm the temporary poll fixture"
  fi
  out=$(run_sweep "$home" 2>&1) || fail "covered sweep failed"
  [ -z "$out" ] || fail "temporary coverage woke: $out"
  cmp -s "$home/marker.before" "$home/state/pr-orphan-conflict/github.com/o/r/7" || fail "coverage erased episode identity"
  rm -f "$home/state/lane.meta" "$home/state/lane.check.sh" "$home/state/lane.pr-poll" \
    "$home/state/lane.pr-poll-registration"
  out=$(run_sweep "$home" 2>&1) || fail "uncovered sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 1 ] || fail "temporary coverage duplicated an episode wake: $out"
  printf '7\tfm/lane\n' > "$home/pr-list.tsv"
  write_label_json "$home/label.json" "$(iso_ago 1000)"
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ "$(orphan_wakes "$home/state")" = 2 ] || fail "a re-applied label did not wake again: $out"
  pass "temporary coverage preserves the episode while a different label timestamp wakes again"
}

test_episode_survives_quiet_and_failed_reads() {
  local home=$TMP_ROOT/quiet-reads out
  make_home "$home"
  run_sweep "$home" > /dev/null 2>&1 || fail "first episode sweep failed"
  [ "$(orphan_wakes "$home/state")" = 1 ] || fail "first episode did not wake"
  cp "$home/state/pr-orphan-conflict/github.com/o/r/7" "$home/marker.before"
  cp "$home/label.json" "$home/label.before"
  out=$(FM_TEST_GH_STATE=CLOSED run_sweep "$home" 2>&1) || fail "closed PR sweep failed"
  [ -z "$out" ] || fail "closed PR woke: $out"
  printf 'invalid JSON\n' > "$home/label.json"
  run_sweep "$home" > "$home/out" 2> "$home/err" || fail "failed lookup stopped the sweep"
  grep -q 'could not read the conflict label age' "$home/err" || fail "lookup failure was not reported"
  cmp -s "$home/marker.before" "$home/state/pr-orphan-conflict/github.com/o/r/7" || fail "a failed read changed episode identity"
  write_label_json "$home/label.json" "$(iso_ago 300)"
  out=$(run_sweep "$home" 2>&1) || fail "young label sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 1 ] || fail "a young replacement label woke: $out"
  cmp -s "$home/marker.before" "$home/state/pr-orphan-conflict/github.com/o/r/7" || fail "a quiet read changed episode identity"
  cp "$home/label.before" "$home/label.json"
  out=$(run_sweep "$home" 2>&1) || fail "restored label sweep failed"
  [ -z "$out" ] && [ "$(orphan_wakes "$home/state")" = 1 ] || fail "quiet or failed reads duplicated the original wake: $out"
  pass "terminal, failed, and young-label observations preserve an existing episode"
}

test_literal_fm_prefix() {
  local annotation home out
  for annotation in 'direct-PR branch=custom/' 'direct-PR branch='; do
    home=$TMP_ROOT/prefix-${annotation##*=}
    make_home "$home" "$annotation"
    printf '7\tfm/lane\n8\tcustom/lane\n9\tlane\n' > "$home/pr-list.tsv"
    out=$(SHOW_CMD=true run_sweep "$home" 2>&1) || fail "prefix sweep failed"
    case "$out" in
      "check: pr-orphan-conflict: $URL (branch fm/lane) "*"owner: task lane in this home's backlog") ;;
      *) fail "literal fm/ matching or task extraction failed: $out" ;;
    esac
    [ "$(orphan_wakes "$home/state")" = 1 ] || fail "branches outside fm/ woke"
    [ "$(grep -c '^api graphql' "$home/gh.log")" = 1 ] || fail "branches outside fm/ were polled"
  done
  pass "only literal fm/ branches wake and resolve their task regardless of the registered prefix"
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

test_unswept_projects_and_usage() {
  local home=$TMP_ROOT/local-only out
  make_home "$home" local-only
  out=$(run_sweep "$home" 2>&1) || fail "sweep failed"
  [ -z "$out" ] && [ ! -s "$home/gh.log" ] || fail "a local-only project was swept: $out"
  run_sweep "$home" --bogus > /dev/null 2>&1 && fail "bad usage was accepted"
  pass "local-only projects are not swept and arguments are refused"
}

test_watcher_wakes_owner_home() {
  local home=$TMP_ROOT/watch pid i
  make_home "$home"
  git -C "$home/projects/proj" remote set-url origin https://github.com/personal/fork.git
  git -C "$home/projects/proj" remote add upstream https://github.com/o/r.git
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
test_publication_target_selection
test_unsupported_publication_targets_are_quiet
test_young_label_is_quiet
test_live_poll_covers_then_teardown_uncovers
test_episode_survives_listing_gaps
test_relabel_between_sweeps_wakes_again
test_episode_survives_temporary_coverage
test_episode_survives_quiet_and_failed_reads
test_literal_fm_prefix
test_owner_routing
test_unswept_projects_and_usage
test_watcher_wakes_owner_home
