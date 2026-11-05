#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-owner.sh, the pull request -> owning task lookup.
#
# Oracles: the live 2026-11-05 census, where task id x-j09-basket-approval-build is
# an open prep-scout row on the Zenbook (its note says the task stays with the
# server) and the server's open build row, so a home asking only its own backlog
# claims the server's work (the fixture adds the pull request URL a build row
# records once it opens one); and the rule fleet-ops set for cut 13 on 2026-11-05:
# ownership comes from a row's full pull request URL and the fm/<task-id> branch
# across every home's rows, and an unresolved or ambiguous case is UNKNOWN with
# the candidate homes, never a guess.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
TMP_ROOT=$(fm_test_tmproot fm-pr-owner)
OWNER="$ROOT/bin/fm-pr-owner.sh"
PR=https://github.com/ashkonmousavi/NOT_Q/pull/1700
ID=x-j09-basket-approval-build

home_with() {  # <name> <backlog row lines...>: a home whose backlog holds those rows
  local home=$TMP_ROOT/$1 row
  shift
  mkdir -p "$home/data"
  { printf '# Backlog\n\n## Queued\n'; for row in "$@"; do printf '%s\n' "$row"; done; } > "$home/data/backlog.md"
  printf '%s\n' "$home"
}

fleet_list() {  # <home> <self> <generated-epoch> <homes> <home|id|state|urls ...>
  local home=$1 self=$2 gen=$3 homes=$4 entry h i s u
  shift 4
  { printf '# blocked-by fleet rows v1\nself\t%s\ngenerated\t%s\nhomes\t%s\n' "$self" "$gen" "$homes"
    for entry in "$@"; do
      IFS='|' read -r h i s u <<<"$entry"
      printf 'row\t%s\t%s\t%s\t%s\n' "$h" "$i" "$s" "$u"
    done; } > "$home/data/blocked-by-fleet-rows.tsv"
}

owner() {  # <home> <args...>: prints output, then "exit=<status>"
  local home=$1 rc
  shift
  FM_HOME=$home bash "$OWNER" "$@"
  rc=$?
  printf 'exit=%s\n' "$rc"
}

expect() {  # <output> <glob> <message>
  # shellcheck disable=SC2254 # The glob is the expectation.
  case "$1" in $2) ;; *) fail "$3: $1" ;; esac
}

test_branch_id_in_two_homes_goes_to_the_row_citing_the_pull_request() {
  local home out now
  now=$(date +%s)
  home=$(home_with laptop "- [ ] $ID - Basket approval prep (kind: scout) (since 2026-11-05)")
  fleet_list "$home" laptop "$now" laptop,server "server|$ID|open|$PR"
  out=$(owner "$home" "$PR" --branch "fm/$ID")
  expect "$out" "known	server	$ID	elsewhere	branch fm/$ID names rows in laptop,server; only server's cites the pull request
exit=0" "the build row's home did not own its pull request"
  fleet_list "$home" laptop "$now" laptop,server "server|$ID|open|-"
  out=$(owner "$home" "$PR" --branch "fm/$ID")
  expect "$out" "unknown	laptop,server	here	branch fm/$ID names rows in laptop,server and 0 of them cite the pull request
exit=3" "two homes holding the branch's id without a citing row were not UNKNOWN"
  fleet_list "$home" laptop "$now" laptop,server "server|$ID|open|$PR" "zen|$ID|done|$PR"
  out=$(owner "$home" "$PR" --branch "fm/$ID")
  expect "$out" "unknown	laptop,server,zen	here	*2 of them cite*exit=3" "two citing homes were resolved to one"
  pass "a branch id held in several homes goes to the one home whose row cites the pull request, else UNKNOWN"
}

test_branch_names_a_task_in_one_home() {
  local home out
  home=$(home_with pc)
  fleet_list "$home" pc "$(date +%s)" pc,server "server|lane|archive|-"
  out=$(owner "$home" "$PR" --branch fm/lane)
  expect "$out" "known	server	lane	elsewhere	branch fm/lane names a row only in server
exit=0" "an archived row in another home did not own its branch"
  home=$(home_with pc-own "- [ ] lane - Lane work (kind: ship) (since 2026-11-05)")
  fleet_list "$home" pc "$(date +%s)" pc,server
  out=$(owner "$home" "$PR" --branch fm/lane)
  expect "$out" "known	pc	lane	here	branch fm/lane names a row only in pc
exit=0" "this home's own row was not named as here"
  out=$(owner "$home" "$PR" --task lane)
  expect "$out" "known	pc	lane	here	task lane names a row only in pc
exit=0" "--task did not name the task directly"
  out=$(owner "$home" "$PR" --task lane --branch fm/lane 2>&1)
  expect "$out" "*alternatives*exit=2" "--task and --branch were both accepted"
  pass "a branch whose id has rows in exactly one home belongs to that home, archived rows included"
}

test_citing_rows_compare_full_urls() {
  local home out
  home=$(home_with pc-urls)
  fleet_list "$home" pc "$(date +%s)" pc,server,zen \
    "server|lane-a|open|https://github.com/ashkonmousavi/NOT_Q/pull/1700" \
    "zen|lane-b|open|https://github.com/ashkonmousavi/other/pull/1700"
  out=$(owner "$home" https://github.com/ashkonmousavi/NOT_Q/pull/1700 --branch fm/zzz)
  expect "$out" "known	server	lane-a	elsewhere	no row is named zzz; only server:lane-a cites the pull request
exit=0" "the same number in another repository was matched"
  out=$(owner "$home" https://github.com/AshkonMousavi/not_q/pull/1700 --branch other/zzz)
  expect "$out" "known	server	lane-a	elsewhere	branch other/zzz names no task; only server:lane-a cites*exit=0" \
    "a URL differing only in owner or repository case did not match"
  out=$(owner "$home" https://github.com/ashkonmousavi/NOT_Q/pull/170 --branch fm/zzz)
  expect "$out" "unknown	-	elsewhere	no row is named zzz and no row cites the pull request
exit=3" "a number prefix matched a different pull request"
  fleet_list "$home" pc "$(date +%s)" pc,server,zen \
    "server|lane-a|open|https://github.com/ashkonmousavi/NOT_Q/pull/1700" \
    "zen|lane-c|done|https://github.com/x/y/pull/3,https://github.com/ashkonmousavi/NOT_Q/pull/1700"
  out=$(owner "$home" https://github.com/ashkonmousavi/NOT_Q/pull/1700 --branch fm/zzz)
  expect "$out" "unknown	server,zen	elsewhere	no row is named zzz; 2 tasks in server,zen cite the pull request
exit=3" "two homes citing the same pull request were resolved to one"
  pass "citing rows match the full pull request URL, and two citing tasks are UNKNOWN with both homes"
}

test_this_homes_list_rows_are_ignored() {
  local home out
  home=$(home_with pc-self)
  fleet_list "$home" pc "$(date +%s)" pc,server "pc|old-lane|done|$PR"
  out=$(owner "$home" "$PR" --branch fm/zzz)
  expect "$out" "unknown	-	elsewhere	no row is named zzz and no row cites the pull request
exit=3" "the fleet list's copy of this home's rows was read"
  pass "the fleet list's rows for this home are ignored; this home's own backlog is read instead"
}

test_head_branch_is_read_once_when_not_given() {
  local home out fake=$TMP_ROOT/fake-gh
  home=$(home_with laptop-gh "- [ ] $ID - Basket approval prep (kind: scout) (since 2026-11-05)")
  fleet_list "$home" laptop "$(date +%s)" laptop,server "server|$ID|open|$PR"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s.log"\nprintf "fm/%s\\n"\n' "$fake" "$ID" > "$fake"
  chmod +x "$fake"
  out=$(FM_TEST_SEAM=1 FM_PR_OWNER_GH=$fake owner "$home" "$PR")
  expect "$out" "known	server	$ID	elsewhere	*exit=0" "the head branch read from the forge was not used"
  [ "$(cat "$fake.log")" = "pr view $PR --json headRefName --jq .headRefName" ] \
    || fail "the forge was not read exactly once for the head branch: $(cat "$fake.log")"
  : > "$fake.log"
  out=$(FM_TEST_SEAM=1 FM_PR_OWNER_GH=$fake owner "$home" "$PR" --branch "fm/$ID")
  [ ! -s "$fake.log" ] || fail "the forge was read although the branch was given"
  pass "without --branch the head branch is read once from the forge; with it, never"
}

test_absent_or_stale_list_is_named() {
  local home out mode self args
  local -a argv
  home=$(home_with pc-absent "- [ ] lane - Lane work (kind: ship) (since 2026-11-05)" \
    "- [x] done-lane - Delivered (since 2026-11-05)" \
    "- [ ] cited-lane - Build (pr: $PR) (since 2026-11-05)")
  printf '## Archived\n- [x] archive-lane - Archived\n' > "$home/data/done-archive.md"
  for mode in absent stale; do
    self=.
    if [ "$mode" = stale ]; then
      self=pc
      fleet_list "$home" pc "$(( $(date +%s) - 7 * 3600 ))" pc,server "server|lane|open|$PR" "server|other|open|$PR"
    fi
    for args in '--branch fm/lane' '--task lane' '--branch fm/done-lane' '--branch fm/archive-lane' '--branch fm/zzz'; do
      read -r -a argv <<<"$args"
      out=$(owner "$home" "$PR" "${argv[@]}")
      expect "$out" "unknown	$self	here	fleet list $mode: *
fleet_list	fleet list $mode: *
exit=3" "$mode list made local rows definitive or lost their candidacy"
    done
    out=$(owner "$home" https://github.com/o/r/pull/8 --branch fm/other)
    expect "$out" "unknown	-	elsewhere	fleet list $mode: *
fleet_list	fleet list $mode: *
exit=3" "$mode list made a stale remote row a candidate or owner"
  done
  printf 'row\tserver\tx\topen\n' > "$home/data/blocked-by-fleet-rows.tsv"
  out=$(owner "$home" "$PR" --branch fm/zzz 2>&1)
  expect "$out" "*needs self, generated*exit=2" "a malformed fleet list was accepted"
  out=$(owner "$home" https://example.com/o/r/pull/1 2>&1)
  expect "$out" "*not a GitHub pull request URL*exit=2" "a non-GitHub URL was accepted"
  pass "an absent or stale fleet list preserves UNKNOWN and only local candidates; bad input is refused"
}

test_branch_id_in_two_homes_goes_to_the_row_citing_the_pull_request
test_branch_names_a_task_in_one_home
test_citing_rows_compare_full_urls
test_this_homes_list_rows_are_ignored
test_head_branch_is_read_once_when_not_given
test_absent_or_stale_list_is_named
