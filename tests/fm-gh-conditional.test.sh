#!/usr/bin/env bash
# Conditional GitHub reads: the shared ETag helper (bin/fm-gh-etag-lib.sh) and
# the polls that use it (bin/fm-pr-poll.sh, bin/fm-pr-orphan-sweep.sh). The
# contribution poll's 304 path is covered in tests/fm-contributions.test.sh.
#
# A fake gh speaks the wire shape the real one does: `api -i` prints headers
# and then the body, a matching If-None-Match answers 304 with headers only and
# exit status 1, and every call is logged so each tick's call count is asserted.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/bin/fm-gh-etag-lib.sh"
POLL="$ROOT/bin/fm-pr-poll.sh"
SWEEP="$ROOT/bin/fm-pr-orphan-sweep.sh"
URL=https://github.com/o/r/pull/7
TMP_ROOT=$(fm_test_tmproot fm-gh-conditional)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
fm_git_identity fmtest fmtest@example.invalid

command -v jq >/dev/null 2>&1 || fail "jq is required"
FM_TEST_JQ_BIN=$(command -v jq)
export FM_TEST_JQ_BIN
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

iso_ago() {  # <seconds>
  # shellcheck disable=SC2016 # A jq program, not shell.
  "$FM_TEST_JQ_BIN" -nr --argjson s "$1" 'now - $s | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
# Fixtures live under $FAKE: rest/<endpoint with non-alphanumerics as _>.json
# is a body, .link adds a Link header, .fail makes the endpoint answer 502,
# .cut sends a 200 whose body is cut off and exits as a killed transfer would.
set -u
log() { printf '%s\n' "$1" >> "$FAKE/log"; }
case "${1:-} ${2:-}" in
  "api -i")
    shift 2
    inm=''
    ep=''
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -H) inm=${2#If-None-Match: }; shift 2 ;;
        *) ep=$1; shift ;;
      esac
    done
    name=$(printf '%s' "$ep" | tr -c 'A-Za-z0-9\n' '_')
    log "rest $ep inm=${inm:-none}"
    if [ -e "$FAKE/rest/$name.fail" ] || [ ! -e "$FAKE/rest/$name.json" ]; then
      printf 'HTTP/2.0 502 Bad Gateway\r\n\r\n{}\n'
      exit 1
    fi
    tag="\"$(sha256sum "$FAKE/rest/$name.json" | cut -c1-16)\""
    if [ "$inm" = "$tag" ]; then
      printf 'HTTP/2.0 304 Not Modified\r\nEtag: %s\r\n\r\n' "$tag"
      exit 1
    fi
    printf 'HTTP/2.0 200 OK\r\nEtag: %s\r\n' "$tag"
    [ ! -e "$FAKE/rest/$name.link" ] || printf 'Link: <https://api.github.com/next>; rel="next"\r\n'
    printf '\r\n'
    if [ -e "$FAKE/rest/$name.cut" ]; then
      head -c 3 "$FAKE/rest/$name.json"
      exit 124
    fi
    cat "$FAKE/rest/$name.json"
    ;;
  "api graphql")
    log graphql
    cat "$FAKE/graphql.out"
    ;;
  "pr view")
    log prview
    cat "$FAKE/prview.out"
    ;;
  "pr list")
    log prlist
    cat "$FAKE/prlist.out"
    ;;
  *)
    printf 'unexpected gh: %s\n' "$*" >&2
    exit 91
    ;;
esac
SH
chmod +x "$FAKEBIN/gh"

# A clock the test can move: only `date -u +%s`, the poll's own age arithmetic,
# honors $FAKE/clock-offset (seconds); every other date call is the real one.
cat > "$FAKEBIN/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-u +%s" ] && [ -n "${FAKE:-}" ] && [ -f "$FAKE/clock-offset" ]; then
  printf '%s\n' $(( $(/bin/date -u +%s) + $(cat "$FAKE/clock-offset") ))
else
  exec /bin/date "$@"
fi
SH
chmod +x "$FAKEBIN/date"

new_fake() {  # <name> -> fake directory
  local dir=$TMP_ROOT/$1
  mkdir -p "$dir/rest" "$dir/state"
  : > "$dir/log"
  printf 'OPEN\n' > "$dir/prview.out"
  printf 'present=false\n' > "$dir/graphql.out"
  : > "$dir/prlist.out"
  printf '%s\n' "$dir"
}

fixture() {  # <fake> <endpoint> <json>
  local name
  name=$(printf '%s' "$2" | tr -c 'A-Za-z0-9\n' '_')
  printf '%s\n' "$3" > "$1/rest/$name.json"
}
fixture_flag() {  # <fake> <endpoint> <suffix> on|off
  local name
  name=$(printf '%s' "$2" | tr -c 'A-Za-z0-9\n' '_')
  if [ "$4" = on ]; then : > "$1/rest/$name.$3"; else rm -f "$1/rest/$name.$3"; fi
}

calls() {  # <fake> <prefix> -> count of log lines starting with prefix
  grep -c "^$2" "$1/log" || true
}

# One helper call in a fresh process, so a second call proves the tag survived
# on disk and not in a shell variable. Prints "rc status etag-state".
helper_call() {  # <fake> <key> <endpoint> [extra env...]
  local fake=$1 key=$2 endpoint=$3
  shift 3
  env "$@" PATH="$FAKEBIN:$PATH" FAKE="$fake" bash -c '
    . "$1"
    fm_gh_etag_get "$2/cache" "$3" "$4"
    rc=$?
    printf "%s %s %s\n" "$rc" "${FM_GH_ETAG_STATUS:-none}" "$(cat "${FM_GH_ETAG_BODY:-/dev/null}" 2>/dev/null | tr -d "\n")"
  ' _ "$LIB" "$fake" "$key" "$endpoint"
}

test_helper_200_304_and_persistence() {
  local fake out
  fake=$(new_fake helper)
  mkdir -p "$fake/cache"
  fixture "$fake" repos/o/r/pulls/7 '{"v":1}'
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 200 {"v":1}' "$out" "first read is a fresh 200"
  grep -q '^rest repos/o/r/pulls/7 inm=none$' "$fake/log" || fail "the first read sent a tag it could not have"
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 304 {"v":1}' "$out" "unchanged object answers 304 from the cached body"
  [ "$(calls "$fake" 'rest ')" -eq 2 ] || fail "two reads made $(calls "$fake" 'rest ') requests"
  grep -q '^rest repos/o/r/pulls/7 inm="[0-9a-f]*"$' "$fake/log" || fail "the second read did not send the persisted tag"
  fixture "$fake" repos/o/r/pulls/7 '{"v":2}'
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 200 {"v":2}' "$out" "a changed object replaces the cache"
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 304 {"v":2}' "$out" "the new tag is the one persisted"
  [ "$(fm_pr_file_mode "$fake/cache/k.etag")" = 600 ] || fail "the tag record is not private"
  pass "helper: 200 stores the tag and body, 304 replays them across processes, a change replaces them"
}

test_helper_error_keeps_the_cache() {
  local fake out
  fake=$(new_fake helper-error)
  mkdir -p "$fake/cache"
  fixture "$fake" repos/o/r/pulls/7 '{"v":1}'
  helper_call "$fake" k repos/o/r/pulls/7 >/dev/null
  fixture_flag "$fake" repos/o/r/pulls/7 fail on
  out=$(helper_call "$fake" k repos/o/r/pulls/7 | cut -d' ' -f1)
  assert_equals 1 "$out" "a 502 is a failed read"
  fixture_flag "$fake" repos/o/r/pulls/7 fail off
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 304 {"v":1}' "$out" "a failed read left the stored tag and body intact"
  pass "helper: an error is rc 1 and the cache survives it"
}

# A 200 whose transfer was cut off (gh killed after the headers arrived) is a
# failed read: neither its tag nor its partial body is stored, so the next read
# asks afresh instead of replaying a broken body on every later 304.
test_helper_cut_off_200_is_not_cached() {
  local fake out
  fake=$(new_fake helper-cut)
  mkdir -p "$fake/cache"
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","labels":[]}'
  fixture_flag "$fake" repos/o/r/pulls/7 cut on
  out=$(helper_call "$fake" k repos/o/r/pulls/7 | cut -d' ' -f1)
  assert_equals 1 "$out" "a cut-off 200 is a failed read"
  [ ! -e "$fake/cache/k.etag" ] && [ ! -e "$fake/cache/k.body" ] || fail "a cut-off 200 was cached: $(ls -A "$fake/cache")"
  fixture_flag "$fake" repos/o/r/pulls/7 cut off
  out=$(helper_call "$fake" k repos/o/r/pulls/7)
  assert_equals '0 200 {"state":"open","labels":[]}' "$out" "the next read fetches the whole body"
  [ "$(grep -c '^rest repos/o/r/pulls/7 inm=none$' "$fake/log")" -eq 2 ] || fail "a tag from the cut-off read was sent"
  pass "helper: a 200 cut off mid-transfer is never cached behind its tag"
}

# The two-week sweep removes entries nobody uses, not entries that have not
# changed: an idle object that keeps answering 304 stays cached.
test_helper_304_keeps_an_idle_entry_from_the_sweep() {
  local fake
  fake=$(new_fake helper-idle)
  mkdir -p "$fake/cache"
  fixture "$fake" repos/o/r/pulls/7 '{"v":1}'
  fixture "$fake" repos/o/r/pulls/8 '{"v":8}'
  helper_call "$fake" idle repos/o/r/pulls/7 >/dev/null
  touch -t 202001010000 "$fake/cache/idle.etag" "$fake/cache/idle.body"
  assert_equals '0 304 {"v":1}' "$(helper_call "$fake" idle repos/o/r/pulls/7)" "the idle object answers 304"
  assert_equals '0 200 {"v":8}' "$(helper_call "$fake" other repos/o/r/pulls/8)" "another key's fresh write runs the sweep"
  [ -e "$fake/cache/idle.etag" ] && [ -e "$fake/cache/idle.body" ] || fail "an entry in use on 304s was swept: $(ls -A "$fake/cache")"
  touch -t 202001010000 "$fake/cache/idle.etag" "$fake/cache/idle.body"
  fixture "$fake" repos/o/r/pulls/8 '{"v":9}'
  helper_call "$fake" other repos/o/r/pulls/8 >/dev/null
  [ ! -e "$fake/cache/idle.etag" ] && [ ! -e "$fake/cache/idle.body" ] || fail "an entry unused for two weeks survived the sweep"
  pass "helper: a 304 keeps its entry from the two-week sweep, an unused entry is still swept"
}

# A request killed mid-flight (the watcher's check timeout) leaves its private
# temps behind; the next fresh write sweeps those older than a day.
test_helper_sweeps_abandoned_temps() {
  local fake
  fake=$(new_fake helper-temps)
  mkdir -p "$fake/cache"
  : > "$fake/cache/.raw.OLD111"
  : > "$fake/cache/.raw.OLD111.etag"
  : > "$fake/cache/.body.OLD222"
  touch -t 202001010000 "$fake/cache/.raw.OLD111" "$fake/cache/.raw.OLD111.etag" "$fake/cache/.body.OLD222"
  : > "$fake/cache/.raw.NEW333"
  fixture "$fake" repos/o/r/pulls/7 '{"v":1}'
  assert_equals '0 200 {"v":1}' "$(helper_call "$fake" k repos/o/r/pulls/7)" "a fresh read succeeds"
  [ ! -e "$fake/cache/.raw.OLD111" ] && [ ! -e "$fake/cache/.raw.OLD111.etag" ] && [ ! -e "$fake/cache/.body.OLD222" ] \
    || fail "abandoned temps survived the sweep: $(ls -A "$fake/cache")"
  [ -e "$fake/cache/.raw.NEW333" ] || fail "a temp younger than a day, possibly in use, was swept"
  pass "helper: temps abandoned by a killed request are swept after a day, live ones are kept"
}

test_helper_multi_page_and_switches() {
  local fake out
  fake=$(new_fake helper-multi)
  mkdir -p "$fake/cache"
  fixture "$fake" 'repos/o/r/issues/1/comments?per_page=100' '[1]'
  fixture_flag "$fake" 'repos/o/r/issues/1/comments?per_page=100' link on
  out=$(helper_call "$fake" m 'repos/o/r/issues/1/comments?per_page=100' | cut -d' ' -f1)
  assert_equals 3 "$out" "a page-spanning list is refused"
  [ ! -e "$fake/cache/m.etag" ] || fail "a page-spanning list stored a tag for page one"
  out=$(helper_call "$fake" m 'repos/o/r/issues/1/comments?per_page=100' | cut -d' ' -f1)
  assert_equals 3 "$out" "the mark keeps refusing"
  [ "$(calls "$fake" 'rest ')" -eq 1 ] || fail "the page-spanning probe was repeated: $(calls "$fake" 'rest ') requests"

  : > "$fake/log"
  fixture "$fake" repos/o/r/pulls/7 '{"v":1}'
  out=$(helper_call "$fake" off repos/o/r/pulls/7 FM_GH_CONDITIONAL=0 | cut -d' ' -f1)
  assert_equals 2 "$out" "the off switch declines"
  [ "$(calls "$fake" 'rest ')" -eq 0 ] || fail "the off switch still called gh"
  out=$(env PATH="$FAKEBIN:$PATH" FAKE="$fake" bash -c '. "$1"; fm_gh_etag_get "$2" k repos/o/r/pulls/7; echo $?' _ "$LIB" "$fake/no/such/parent/cache")
  assert_equals 2 "$out" "an unusable cache directory declines"
  out=$(env PATH="$FAKEBIN:$PATH" FAKE="$fake" bash -c '. "$1"; fm_gh_etag_get "$2" "../x" repos/o/r/pulls/7; echo $?' _ "$LIB" "$fake/cache")
  assert_equals 2 "$out" "a path-like key declines"
  pass "helper: page-spanning lists, the off switch, an unusable directory and a bad key are all declined"
}

poll_tick() {  # <fake> [env...]
  local fake=$1
  shift
  env "$@" PATH="$FAKEBIN:$PATH" FAKE="$fake" \
    bash "$POLL" --validated github "$URL" github.com o/r 7 2>/dev/null
}

test_poll_calls_per_tick() {
  local fake out used
  fake=$(new_fake poll)
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","merged":false,"labels":[{"name":"bug"}]}'
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "an open PR without the label is clear"
  assert_equals 1 "$(calls "$fake" 'rest ')" "tick one: one REST read"
  assert_equals 0 "$(( $(calls "$fake" graphql) + $(calls "$fake" prview) ))" "tick one: no GraphQL read"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "tick two answer"
  assert_equals 2 "$(calls "$fake" 'rest ')" "tick two: one more REST read"
  grep -q '^rest repos/o/r/pulls/7 inm="[0-9a-f]*"$' "$fake/log" || fail "tick two did not send the tag"
  assert_equals 0 "$(( $(calls "$fake" graphql) + $(calls "$fake" prview) ))" "tick two: still no GraphQL read"
  fixture "$fake" repos/o/r/pulls/7 '{"state":"closed","merged":true,"labels":[]}'
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals merged "$out" "a merged PR is reported"
  used=$(calls "$fake" 'rest ')
  assert_equals 3 "$used" "tick three: one REST read"
  assert_equals 0 "$(( $(calls "$fake" graphql) + $(calls "$fake" prview) ))" "a merge needs no GraphQL read"
  fixture "$fake" repos/o/r/pulls/7 '{"state":"closed","merged":false,"labels":[]}'
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals '' "$out" "a closed, unmerged PR says nothing"
  pass "pr-poll: one REST read per tick, tag sent from the second, no GraphQL for clear, merged and closed PRs"
}

test_poll_label_age_crosses_on_a_304() {
  local fake out labeled
  fake=$(new_fake poll-age)
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","merged":false,"labels":[{"name":"conflict"}]}'
  labeled=$(iso_ago 840)
  printf 'present=true\nlabeled_at=%s\n' "$labeled" > "$fake/graphql.out"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "a label younger than 15 minutes is not yet a conflict"
  assert_equals 1 "$(calls "$fake" graphql)" "the label timeline is read once on the 200"
  # Nothing about the PR changes; only the clock moves past the 15-minute threshold.
  printf '120\n' > "$fake/clock-offset"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals "conflict:$labeled" "$out" "the same unchanged PR crosses the age threshold on a 304"
  grep -q '^rest repos/o/r/pulls/7 inm="[0-9a-f]*"$' "$fake/log" || fail "the second tick was not conditional"
  assert_equals 1 "$(calls "$fake" graphql)" "the 304 tick replayed the stored timeline without another GraphQL read"
  assert_equals 0 "$(calls "$fake" prview)" "no pr view on either tick"
  # The label is removed: the PR body changes, so the stored facts are not replayed.
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","merged":false,"labels":[]}'
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "removing the label clears the conflict"
  pass "pr-poll: a 304 re-evaluates the stored label time against the clock and a change drops the stored facts"
}

test_poll_unprovable_label_age_is_asked_again() {
  local fake out
  fake=$(new_fake poll-unprovable)
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","merged":false,"labels":[{"name":"conflict"}]}'
  printf 'present=true\n' > "$fake/graphql.out"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals '' "$out" "a label whose age cannot be proved says nothing"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals '' "$out" "still nothing on the next tick"
  assert_equals 2 "$(calls "$fake" graphql)" "an unproved age is not cached: the timeline is asked again on a 304"
  # A timeline lagging the REST body: it has not yet seen the label applied, or
  # still shows a removal newer than the re-add. Neither is stored, so the
  # unchanged PR's 304 asks again and the caught-up timeline is reported.
  printf 'present=false\nlabeled_at=%s\n' "$(iso_ago 3600)" > "$fake/graphql.out"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "a lagging timeline without the label answers clear for this tick"
  printf 'present=true\nlabeled_at=%s\nunlabeled_at=%s\n' "$(iso_ago 3600)" "$(iso_ago 1800)" > "$fake/graphql.out"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals '' "$out" "a removal newer than the last add says nothing"
  printf 'present=true\nlabeled_at=%s\nunlabeled_at=%s\n' "$(iso_ago 1200)" "$(iso_ago 1800)" > "$fake/graphql.out"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  case "$out" in conflict:*) ;; *) fail "the caught-up timeline was not asked on the 304: $out" ;; esac
  assert_equals 5 "$(calls "$fake" graphql)" "every lagging answer was asked again"
  grep -q '^rest repos/o/r/pulls/7 inm="[0-9a-f]*"$' "$fake/log" || fail "the later ticks were not conditional"
  pass "pr-poll: an unprovable or lagging label timeline is retried every tick, as the original reads did"
}

test_poll_falls_back_to_the_original_reads() {
  local fake out
  fake=$(new_fake poll-fallback)
  # No REST fixture: the endpoint answers 502, so the original reads run.
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state")
  assert_equals conflict-clear "$out" "a failed REST read falls back to pr view and GraphQL"
  assert_equals 1 "$(calls "$fake" prview)" "the fallback made its pr view read"
  assert_equals 1 "$(calls "$fake" graphql)" "the fallback made its timeline read"
  : > "$fake/log"
  fixture "$fake" repos/o/r/pulls/7 '{"state":"open","merged":false,"labels":[]}'
  out=$(poll_tick "$fake")
  assert_equals conflict-clear "$out" "no state directory still answers"
  assert_equals 0 "$(calls "$fake" 'rest ')" "no state directory means no conditional read"
  out=$(poll_tick "$fake" FM_STATE_OVERRIDE="$fake/state" FM_GH_CONDITIONAL=0)
  assert_equals conflict-clear "$out" "the off switch still answers"
  assert_equals 0 "$(calls "$fake" 'rest ')" "the off switch means no conditional read"
  pass "pr-poll: a failed REST read, a missing state directory and the off switch all use the original reads"
}

make_home() {  # <home>
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  printf -- '- proj [direct-PR +yolo] - orphan sweep fixture\n' > "$home/data/projects.md"
  git init -q -b main "$home/projects/proj"
  git -C "$home/projects/proj" remote add origin https://github.com/o/r.git
}

run_sweep() {  # <home> <fake>
  env PATH="$FAKEBIN:$PATH" FM_HOME="$1" FAKE="$2" FM_PR_ORPHAN_SHOW_CMD=false bash "$SWEEP"
}

test_sweep_lists_conditionally() {
  local fake home out labeled
  fake=$(new_fake sweep)
  home=$TMP_ROOT/sweep-home
  make_home "$home"
  labeled=$(iso_ago 1200)
  printf 'present=true\nlabeled_at=%s\n' "$labeled" > "$fake/graphql.out"
  fixture "$fake" 'repos/o/r/pulls?state=open&per_page=100' \
    '[{"number":7,"head":{"ref":"fm/lane"},"labels":[{"name":"conflict"}]},{"number":9,"head":{"ref":"fm/quiet"},"labels":[]},{"number":12,"head":{"ref":"dependabot/x"},"labels":[{"name":"conflict"}]}]'
  out=$(run_sweep "$home" "$fake" 2>"$home/err") || fail "sweep failed: $(cat "$home/err")"
  case "$out" in
    "check: pr-orphan-conflict: https://github.com/o/r/pull/7 (branch fm/lane) has carried the conflict label since "*) ;;
    *) fail "the conditional listing did not wake the conflicted fm/ branch: [$out] $(cat "$home/err")" ;;
  esac
  assert_equals 0 "$(calls "$fake" prlist)" "no gh pr list read when the REST list answers"
  grep -q '^rest repos/o/r/pulls?state=open&per_page=100 inm=none$' "$fake/log" || fail "the list was not read through the helper"
  out=$(run_sweep "$home" "$fake" 2>"$home/err") || fail "second sweep failed: $(cat "$home/err")"
  assert_equals '' "$out" "the same episode wakes once"
  grep -q '^rest repos/o/r/pulls?state=open&per_page=100 inm="[0-9a-f]*"$' "$fake/log" || fail "the second pass did not send the list tag"
  assert_equals 0 "$(calls "$fake" prlist)" "still no gh pr list read on a 304 pass"
  fixture "$fake" 'repos/o/r/pulls?state=open&per_page=100' '[{"number":9,"head":{"ref":"fm/quiet"},"labels":[]}]'
  out=$(run_sweep "$home" "$fake" 2>"$home/err") || fail "empty sweep failed: $(cat "$home/err")"
  assert_equals '' "$out" "a project with no conflict label wakes nothing"
  assert_equals 0 "$(calls "$fake" prlist)" "an empty REST answer is trusted, not re-asked through GraphQL"
  fixture_flag "$fake" 'repos/o/r/pulls?state=open&per_page=100' fail on
  printf '7\tfm/lane\n' > "$fake/prlist.out"
  run_sweep "$home" "$fake" >/dev/null 2>"$home/err" || fail "fallback sweep failed: $(cat "$home/err")"
  assert_equals 1 "$(calls "$fake" prlist)" "a failed REST list falls back to gh pr list"
  pass "pr-orphan-sweep: the project list is one conditional REST read, trusted when empty, with gh pr list as the fallback"
}

failures=0
for test_name in test_helper_200_304_and_persistence test_helper_error_keeps_the_cache test_helper_sweeps_abandoned_temps test_helper_cut_off_200_is_not_cached \
  test_helper_304_keeps_an_idle_entry_from_the_sweep \
  test_helper_multi_page_and_switches test_poll_calls_per_tick test_poll_label_age_crosses_on_a_304 test_poll_unprovable_label_age_is_asked_again \
  test_poll_falls_back_to_the_original_reads test_sweep_lists_conditionally; do
  ( "$test_name" ) || failures=$((failures + 1))
done
[ "$failures" -eq 0 ] || fail "$failures conditional-read regressions"
