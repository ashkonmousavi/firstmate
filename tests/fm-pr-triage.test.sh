#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-triage.sh.
#
# A real markdown backlog drives bin/fm-tasks-axi.sh; gh, gh-axi, mergify,
# capacity, the control plane and worker liveness are replaced through the
# FM_TEST_SEAM hooks with fakes that read fixtures and record their calls.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for the PR triage backlog fixtures'
command -v jq >/dev/null 2>&1 || fail 'jq is required for the PR triage fixtures'
TMP_ROOT=$(fm_test_tmproot fm-pr-triage)
TRIAGE="$ROOT/bin/fm-pr-triage.sh"
H="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$FAKE"
fm_test_tasks_toml "$H/.tasks.toml"
printf '%s\n' '- proj [direct-PR +yolo] - triage fixture project' > "$H/data/projects.md"
export FM_HOME="$H" FM_TEST_SEAM=1
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE

# Fake gh: the GraphQL listing from $FAKE/prs.json (an array of nodes).
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/gh.log"
[ -f "$FAKE_DIR/gh-fail" ] && { echo 'gh: HTTP 502' >&2; exit 1; }
jq -c '{data:{repository:{pullRequests:{pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}}' "$FAKE_DIR/prs.json"
SH
# Fake gh-axi: records every write.
cat > "$FAKE/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/ghaxi.log"
exit 0
SH
# Fake mergify: status from $FAKE/queue-status.json; show from $FAKE/show-<n>.json.
cat > "$FAKE/mergify" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/mergify.log"
[ -f "$FAKE_DIR/mergify-fail" ] && { echo 'mergify: unauthorized' >&2; exit 1; }
case "$2" in
  status) cat "$FAKE_DIR/queue-status.json" ;;
  show)
    if [ -f "$FAKE_DIR/show-$3.json" ]; then cat "$FAKE_DIR/show-$3.json"
    else printf '{"number":%s,"queued":false,"dequeued":false}\n' "$3"; fi ;;
esac
SH
cat > "$FAKE/capacity" <<'SH'
#!/usr/bin/env bash
if [ "$(cat "$FAKE_DIR/free")" -gt 0 ]; then
  printf 'capacity: free_lanes=%s reason=ok lanes=1 target=4\n' "$(cat "$FAKE_DIR/free")"; exit 0
fi
printf 'capacity: free_lanes=0 reason=full lanes=4 target=4\n'; exit 75
SH
# Fake control plane: argv to $FAKE/control.log, exit code from $FAKE/control-rc.
cat > "$FAKE/control" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/control.log"
rc=0; [ -f "$FAKE_DIR/control-rc" ] && rc=$(cat "$FAKE_DIR/control-rc")
[ "$rc" = 75 ] && echo 'deferred: no free machine lane' >&2
exit "$rc"
SH
# Fake liveness: $FAKE/posture-<id>, default none.
cat > "$FAKE/posture" <<'SH'
#!/usr/bin/env bash
if [ -f "$FAKE_DIR/posture-$2" ]; then cat "$FAKE_DIR/posture-$2"; else echo none; fi
SH
# Fake fm-send.sh: every attempt logs target and FM_SEND_REQUEST_ID to send-ids.log;
# a delivered one adds target|flag|text, line breaks as spaces, to send.log.
cat > "$FAKE/send" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "$1" "${FM_SEND_REQUEST_ID:-}" >> "$FAKE_DIR/send-ids.log"
[ -f "$FAKE_DIR/send-fail" ] && { echo 'error: endpoint retired' >&2; exit 1; }
printf '%s|%s|%s\n' "$1" "$2" "$(printf '%s' "$3" | tr '\n' ' ')" >> "$FAKE_DIR/send.log"
SH
# Fake fm-on.sh: a remote home's backlog holds only the ids in $FAKE/remote-open;
# u-task makes the transport fail.
cat > "$FAKE/on" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/on.log"
[ "$4" = u-task ] && { echo 'ssh: connect to host q-crew: No route to host' >&2; exit 255; }
if grep -qx "$4" "$FAKE_DIR/remote-open" 2>/dev/null; then printf 'task:\n  id: %s\n  state: queued\n' "$4"; exit 0; fi
printf 'error: "Task not found"\ncode: NOT_FOUND\n'; exit 1
SH
chmod +x "$FAKE/gh" "$FAKE/gh-axi" "$FAKE/mergify" "$FAKE/capacity" "$FAKE/control" "$FAKE/posture" \
  "$FAKE/send" "$FAKE/on"
export FAKE_DIR="$FAKE" FM_PR_TRIAGE_GH_BIN="$FAKE/gh" FM_PR_TRIAGE_GHAXI_BIN="$FAKE/gh-axi" \
  FM_PR_TRIAGE_MERGIFY_BIN="$FAKE/mergify" FM_PR_TRIAGE_CAPACITY_BIN="$FAKE/capacity" \
  FM_PR_TRIAGE_CONTROL_BIN="$FAKE/control" FM_PR_TRIAGE_POSTURE_BIN="$FAKE/posture" \
  FM_PR_TRIAGE_SEND_BIN="$FAKE/send" FM_PR_TRIAGE_ON_BIN="$FAKE/on"
LOG="$H/state/pr-triage.log"
URL=https://github.com/o/r/pull

rules() {  # extra rules lines on stdin
  { printf 'repo=o/r\nproject=proj\n'; cat; } > "$H/config/pr-triage-rules"
}
backlog() {  # queued section lines on stdin
  { printf '## In flight\n## Queued\n'; cat; printf '## Done\n- [x] old-done - finished (since 2026-10-01)\n'; } > "$H/data/backlog.md"
}
# pr <number> <head> <mergeable> <rollup> [title] [labels-csv] [draft] [author] [files-csv]
pr() {
  jq -n --argjson n "$1" --arg head "$2" --arg m "$3" --arg r "$4" --arg t "${5:-piece $1}" \
    --arg labels "${6:-}" --arg draft "${7:-false}" --arg author "${8:-dev}" --arg files "${9:-src/a.py}" '
    {number:$n, url:"https://github.com/o/r/pull/\($n)", title:$t, isDraft:($draft == "true"),
     headRefName:$head, headRefOid:"sha\($n)aaaaaaaaaaaa", baseRefName:"main", mergeable:$m,
     author:{login:$author},
     labels:{nodes:[$labels | split(",")[] | select(. != "") | {name:.}]},
     files:{nodes:[$files | split(",")[] | select(. != "") | {path:.}]},
     commits:{nodes:[{commit:{statusCheckRollup:(if $r == "NONE" then null else {state:$r} end)}}]}}'
}
prs() {  # pr objects on stdin
  jq -s '.' > "$FAKE/prs.json"
}
queue() {  # queued numbers as args
  jq -n --args '{batches:[{pull_requests:[$ARGS.positional[] | {number:tonumber}]}],
    forming_batches:[], waiting_pull_requests:[], pause:null}' "$@" > "$FAKE/queue-status.json"
}
meta() {  # <id> [worktree]
  printf 'kind=ship\nworktree=%s\n' "${2:-/tmp/wt-$1}" > "$H/state/$1.meta"
}
reset() {
  rm -f "$LOG" "$FAKE"/*.log "$FAKE"/show-*.json "$FAKE"/posture-* "$FAKE/control-rc" \
    "$FAKE/gh-fail" "$FAKE/mergify-fail" "$FAKE/send-fail" "$FAKE/remote-open" \
    "$H/data/secondmates.md" "$H/state"/*.meta "$H/state/.wake-queue" "$H/state/.wake-queue.seq"
  rm -rf "$H/state/pr-triage" "$H/state/spawn-deferred" "$H/state/.pr-triage.lock"
  printf '1\n' > "$FAKE/free"
  queue
  printf '' | rules
}
wakes() {  # <number>: wake-queue rows naming that pull request (fm-wake-lib's row format)
  awk -F'\t' -v k="pr-triage-unowned:$URL/$1" '$3 == "check" && $4 == k' "$H/state/.wake-queue" 2>/dev/null | wc -l | tr -d ' '
}
field() {  # <record-line> <n>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}
rec() {  # <number>: that pull request's last record
  grep -F "	$URL/$1	" "$LOG" | tail -1
}

# --- conflicting and red: fix worker through the guarded relaunch path ------
reset
backlog <<'MD'
- [ ] red-task - J-01 step that broke (repo: proj) (kind: ship) (since 2026-10-30)
MD
meta red-task
echo exited > "$FAKE/posture-red-task"
pr 10 fm/red-task CONFLICTING FAILURE | prs
out=$(bash "$TRIAGE" --apply 2>&1); rc=$?
expect_code 0 "$rc" 'apply pass'
r=$(rec 10)
assert_equals 1 "$(field "$r" 3)" 'J-01 backlog item is rank 1'
assert_equals fix "$(field "$r" 4)" 'conflicting and red is a fix'
assert_equals 'launched red-task (queue=not queued)' "$(field "$r" 5)" 'fix launched and names the real queue state'
assert_contains "$(head -1 "$FAKE/control.log")" 'red-task relaunch --note' 'fix goes through fm-control relaunch'
assert_contains "$(cat "$FAKE/control.log")" 'conflicting and red' 'note names why'
assert_contains "$(cat "$FAKE/control.log")" 'Do not force-push.' 'note forbids force-push'
assert_absent "$FAKE/ghaxi.log" 'a fix writes nothing to GitHub'
assert_contains "$out" "$r" 'records are echoed on stdout'
printf '%s\n' "$r" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	' || fail "record time is UTC ISO: $r"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 10)" 'refused:fix already launched for head sha10' 'second pass on the same head launches nothing'
[ "$(grep -c " relaunch --note" "$FAKE/control.log")" -eq 1 ] || fail 'at most one fix launch per pull request head'
echo live > "$FAKE/posture-red-task"; rm -rf "$H/state/pr-triage"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 10)" 'refused:worker live for red-task' 'a live worker gets no second worker'
[ "$(grep -c " relaunch --note" "$FAKE/control.log")" -eq 1 ] || fail 'live worker: no launch'
pass 'conflicting and red relaunches the owning task once, never beside a live worker'

reset
backlog <<'MD'
- [ ] rel-task - J-01 released copy (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] gone-task - J-01 no record (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] busy-task - J-01 unproved (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] cap-task - J-01 no room (repo: proj) (kind: ship) (since 2026-10-30)
MD
meta rel-task "$H/state/rel-task.released-copy"
meta busy-task; echo unknown > "$FAKE/posture-busy-task"
pr 20 fm/rel-task MERGEABLE FAILURE | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 'launched rel-task (queue=not queued)' "$(field "$(rec 20)" 5)" 'a released copy relaunches'
{ pr 21 fm/gone-task CONFLICTING SUCCESS; pr 22 fm/busy-task CONFLICTING SUCCESS; pr 23 fm/other-home CONFLICTING FAILURE "J-01 fix"; } | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 21)" 'refused:no task record for gone-task' 'no record, no launch'
assert_contains "$(rec 22)" 'refused:worker liveness unknown for busy-task' 'unproved liveness, no launch'
assert_contains "$(rec 23)" 'refused:no home owns other-home' 'no registered home holds it'
meta cap-task; echo exited > "$FAKE/posture-cap-task"; printf '0\n' > "$FAKE/free"
pr 24 fm/cap-task CONFLICTING FAILURE | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 24)" 'refused:no capacity: full' 'machine admission refuses'
printf '1\n' > "$FAKE/free"; echo 75 > "$FAKE/control-rc"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 24)" 'refused:deferred: deferred: no free machine lane' 'a deferred launch is recorded'
assert_absent "$H/state/pr-triage/fix-24" 'a deferred launch leaves no launch marker'
rm -f "$FAKE/control-rc"
mkdir -p "$H/state/spawn-deferred/queue"; printf 'task=cap-task\n' > "$H/state/spawn-deferred/queue/0001"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 24)" 'refused:spawn deferred pending for cap-task' 'deferred retry is not doubled'
pass 'fix refusals: no record, unproved liveness, no owning home, capacity, deferral'

# --- green and not queued: label and one queue comment ------------------------
reset
backlog <<'MD'
- [ ] ci-task - speed up the unit leg (repo: proj) (kind: ship) (since 2026-10-30)
MD
printf 'title=unit leg\n' | rules
pr 30 fm/ci-task MERGEABLE SUCCESS 'speed up the unit leg' | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
r=$(rec 30)
assert_equals 1 "$(field "$r" 3)" 'title rule is rank 1'
assert_equals queue "$(field "$r" 4)" 'green is a queue action'
assert_contains "$(field "$r" 5)" 'labelled main-red and commented queue (queue=not queued)' 'queue result'
assert_equals "pr edit 30 --repo o/r --add-label main-red" "$(sed -n 1p "$FAKE/ghaxi.log")" 'label added'
assert_equals "pr comment 30 --repo o/r --body @mergifyio queue" "$(sed -n 2p "$FAKE/ghaxi.log")" 'queue comment'
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 30)" 'refused:queue comment already made for head sha30' 'slow pickup gets no second comment'
[ "$(grep -c 'pr comment' "$FAKE/ghaxi.log")" -eq 1 ] || fail 'exactly one queue comment'
jq '.[0].headRefOid = "pushed30bbbbbbbb"' "$FAKE/prs.json" > "$FAKE/p.tmp" && mv "$FAKE/p.tmp" "$FAKE/prs.json"
bash "$TRIAGE" --apply >/dev/null 2>&1
bash "$TRIAGE" --apply >/dev/null 2>&1
[ "$(grep -c 'pr comment' "$FAKE/ghaxi.log")" -eq 2 ] || fail 'a new push earns exactly one new comment'
pr 30 fm/ci-task MERGEABLE SUCCESS 'speed up the unit leg' main-red | prs
rm -rf "$H/state/pr-triage"; rm -f "$FAKE/ghaxi.log"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_not_contains "$(cat "$FAKE/ghaxi.log")" 'add-label' 'an existing main-red label is not re-added'
assert_contains "$(cat "$FAKE/ghaxi.log")" 'pr comment 30' 'label alone is not queue state: still comments'
pass 'green unqueued pull request gets the label and exactly one queue comment per head'

# --- already queued: no duplicate comment ---------------------------------------
reset
printf 'label=ci\n' | rules
backlog < /dev/null
{ pr 40 fm/a MERGEABLE SUCCESS t ci; pr 41 fm/b MERGEABLE SUCCESS t ci; } | prs
queue 40
printf '{"number":41,"queued":true}\n' > "$FAKE/show-41.json"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 'already queued' "$(field "$(rec 40)" 5)" 'queued in a batch'
assert_equals 'already queued' "$(field "$(rec 41)" 5)" 'queued per queue show'
assert_absent "$FAKE/ghaxi.log" 'already queued: no label, no comment'
jq '.pause = {"reason":"freeze"}' "$FAKE/queue-status.json" > "$FAKE/q.tmp" && mv "$FAKE/q.tmp" "$FAKE/queue-status.json"
pr 42 fm/c MERGEABLE SUCCESS t ci | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 'refused:queue paused' "$(field "$(rec 42)" 5)" 'paused queue: no comment'
touch "$FAKE/mergify-fail"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 'refused:queue state unreadable' "$(field "$(rec 42)" 5)" 'unreadable queue: no comment'
assert_absent "$FAKE/ghaxi.log" 'no write without a readable, running queue'
pass 'already-queued, paused and unreadable queues get no comment'

# --- rank ordering ---------------------------------------------------------------
reset
backlog <<'MD'
- [ ] j-step - J-01 step three blocked-by: j-dep (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] j-dep - plain blocker of a J-01 step (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] one-blocker - blocks one (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] two-blocker - blocks two (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] w1 - waits blocked-by: two-blocker (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] w2 - waits blocked-by: two-blocker blocked-by: one-blocker (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] plain - nothing (repo: proj) (kind: ship) (since 2026-10-30)
MD
printf 'path=.github/workflows/*\n' | rules
{
  pr 50 fm/plain MERGEABLE PENDING
  pr 51 fm/one-blocker MERGEABLE PENDING
  pr 52 fm/two-blocker MERGEABLE PENDING
  pr 53 fm/j-dep MERGEABLE PENDING
  pr 54 fm/ci-path MERGEABLE PENDING t '' false dev 'src/x.py,.github/workflows/ci.yml'
  pr 55 fm/x-j01-thing MERGEABLE PENDING
} | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
order=$(awk -F'\t' '{split($2, a, "/"); printf "%s:%s ", a[7], $3}' "$LOG")
assert_equals '53:1 54:1 55:1 52:2 51:2 50:3 ' "$order" 'rank 1 (J-01 path, rules), then most-blocking, then the rest'
assert_equals 'refused:checks PENDING' "$(field "$(rec 52)" 5)" 'pending checks: no action'
assert_equals 'none' "$(field "$(rec 50)" 5)" 'rank 3 gets a record and no action'
[ "$(grep -c . "$LOG")" -eq 6 ] || fail 'one record per pull request per pass'
pass 'ranking: J-01 path and rules first, then blocked-by count, then the rest'

# --- done backlog items are closed work -------------------------------------------
# Oracle: the header's rank 2 counts blocked-by edges of open backlog items only,
# and a done item is neither on the J-01 path nor a task this home still owns.
reset
cat > "$H/data/backlog.md" <<'MD'
## In flight
## Queued
- [ ] open-task - plain open work (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] closed-dep - open work only a done item waits on (repo: proj) (kind: ship) (since 2026-10-30)
## Done
- [x] closed-j - J-01 finished step blocked-by: closed-dep blocked-by: open-task (since 2026-10-01)
MD
meta closed-j; echo exited > "$FAKE/posture-closed-j"
{
  pr 90 fm/closed-dep MERGEABLE SUCCESS
  pr 91 fm/open-task MERGEABLE SUCCESS
  pr 92 fm/closed-j CONFLICTING FAILURE 'J-01 late fix'
} | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 3 "$(field "$(rec 90)" 3)" 'a blocker of only done work is rank 3'
assert_equals 3 "$(field "$(rec 91)" 3)" 'blocking a done item counts for nothing'
assert_equals 'refused:task done (queue=not queued)' "$(field "$(rec 92)" 5)" 'a done task with an exited worker record gets no fix worker'
assert_absent "$FAKE/control.log" 'done work launches nothing'
assert_absent "$FAKE/ghaxi.log" 'done work queues nothing'
pass 'done backlog items neither rank pull requests nor own fix workers'

# --- a head branch without the project prefix has no task ---------------------------
reset
backlog < /dev/null
printf 'label=ci\n' | rules
{
  pr 95 dependabot/pip/x CONFLICTING FAILURE t ci
  pr 96 human-branch MERGEABLE SUCCESS t ci true
} | prs
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 1 "$(field "$(rec 95)" 3)" 'label rule ranks an unprefixed branch'
assert_equals 'refused:no task branch (queue=not queued)' "$(field "$(rec 95)" 5)" 'no task branch is named'
assert_equals 'refused:draft (label:ci)' "$(field "$(rec 96)" 5)" 'the class survives an empty task'
pass 'an unprefixed head branch keeps an empty task and its rank class'

# --- the proposed schedule carries the caller's PATH --------------------------------
# Oracle: systemd user units and cron start with a minimal PATH (systemd.exec,
# crontab(5)), so the tools a pass needs are only found when the unit sets it.
odd="$TMP_ROOT/bin dir/%x"
mkdir -p "$odd"
out=$(PATH="$PATH:$odd" bash "$TRIAGE" --print-timer); rc=$?
expect_code 0 "$rc" 'print-timer'
want=$(printf '%s' "$PATH:$odd" | sed 's/%/%%/g')
assert_contains "$out" "Environment=\"PATH=$want\"" 'service sets the caller PATH, quoted with % escaped'
assert_contains "$out" "Environment=\"FM_HOME=$H\"" 'service sets FM_HOME'
cron=$(printf '%s\n' "$out" | sed -n 's|^\*/5 \* \* \* \* ||p')
cron=${cron% >/dev/null 2>&1}
cron=${cron//\\%/%}
got=$(env -i /bin/sh -c "${cron%% FM_HOME=*}; printf '%s' \"\$PATH\"")
assert_equals "$PATH:$odd" "$got" 'cron line sets the caller PATH'
pass 'the proposed timer and cron line carry the PATH the pass needs'

# --- skips -------------------------------------------------------------------------
# Oracle: the owner's rule acts on every top-two-rank pull request; only a draft
# and a Mergify batch, which a queue command cannot act on, are skipped.
reset
backlog < /dev/null
printf 'label=ci\n' | rules
{
  pr 60 fm/ex MERGEABLE SUCCESS t ci
  pr 61 fm/dr CONFLICTING FAILURE t ci true
  pr 62 fm/hd MERGEABLE SUCCESS t ci,hold
  pr 63 mergify/merge-queue/abc MERGEABLE PENDING 'merge queue: checking' ci true mergify
  pr 64 fm/unk UNKNOWN SUCCESS t ci
} | prs
printf '# parked\nfm/ex\n' > "$H/config/pr-triage-exclude"
bash "$TRIAGE" --apply >/dev/null 2>&1
rm -f "$H/config/pr-triage-exclude"
assert_contains "$(field "$(rec 60)" 5)" 'commented queue' 'no exclusion list: a listed pull request is still queued'
assert_contains "$(rec 61)" 'refused:draft' 'draft gets no action'
assert_contains "$(field "$(rec 62)" 5)" 'commented queue' 'a hold label does not skip the queue action'
assert_equals 'refused:merge-queue batch' "$(field "$(rec 63)" 5)" 'Mergify batch pull request is skipped'
assert_equals 'refused:mergeability UNKNOWN' "$(field "$(rec 64)" 5)" 'unknown mergeability: no action'
assert_equals 2 "$(grep -c 'pr comment' "$FAKE/ghaxi.log")" 'only the two acted-on pull requests get comments'
assert_absent "$FAKE/control.log" 'skips launch nothing'
pass 'draft, merge-queue batches and unknown mergeability are skipped; exclusion files and hold labels are not'

# --- another registered home owns the task -------------------------------------------
# Oracle: the owner's decision: a task another registered home holds gets no
# worker here, a record naming that home, and one steer with the URL per head.
reset
H2="$TMP_ROOT/home2"
mkdir -p "$H2/data" "$H2/state"
fm_test_tasks_toml "$H2/.tasks.toml"
printf '## In flight\n## Queued\n- [ ] sm-task - J-01 their step (since 2026-10-30)\n## Done\n- [x] sm-done - J-01 old (since 2026-10-01)\n' > "$H2/data/backlog.md"
backlog < /dev/null
{
  printf -- '- sm1 - local mate (home: %s; scope: proj work; projects: proj; added 2026-10-30)\n' "$H2"
  printf -- '- sm2 - remote mate (host: q-crew; root: /srv/fm; home: /srv/home; scope: proj work; projects: proj; added 2026-10-30)\n'
} > "$H/data/secondmates.md"
printf 'r-task\n' > "$FAKE/remote-open"
{
  pr 100 fm/sm-task CONFLICTING FAILURE 'J-01 their fix'
  pr 101 fm/r-task MERGEABLE FAILURE 'J-01 remote'
  pr 102 fm/nobody MERGEABLE FAILURE 'J-01 orphan'
  pr 103 fm/sm-done MERGEABLE FAILURE 'J-01 closed there'
  pr 104 fm/u-task MERGEABLE FAILURE 'J-01 unreachable'
  pr 105 fm/orphan-meta CONFLICTING FAILURE 'J-01 left behind'
} | prs
meta orphan-meta; echo exited > "$FAKE/posture-orphan-meta"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 1 "$(field "$(rec 100)" 3)" 'the J-01 title ranks it 1'
assert_equals 'refused:owned by sm1: steered sm-task (queue=not queued)' "$(field "$(rec 100)" 5)" 'local owner named and steered'
assert_equals 'refused:owned by sm2: steered r-task (queue=not queued)' "$(field "$(rec 101)" 5)" 'remote owner read through fm-on and steered'
assert_contains "$(cat "$FAKE/on.log")" 'sm2 fm-tasks-axi.sh show r-task' 'remote backlog read with fm-tasks-axi show'
assert_equals 'refused:no home owns nobody: firstmate notified (queue=not queued)' "$(field "$(rec 102)" 5)" 'no home holds it: firstmate told'
assert_equals 'refused:no home owns orphan-meta: firstmate notified (queue=not queued)' "$(field "$(rec 105)" 5)" 'a record here but no backlog item: no relaunch, firstmate told'
assert_equals 'refused:no home owns sm-done: firstmate notified (queue=not queued)' "$(field "$(rec 103)" 5)" 'done in the other home is not owned'
assert_equals 1 "$(wakes 105)" 'one wake for the unowned pull request'
assert_contains "$(awk -F'\t' -v k="pr-triage-unowned:$URL/105" '$4 == k {print $5}' "$H/state/.wake-queue")" "check: pr-triage-unowned: $URL/105 (rank 1, conflicting and red)" 'the wake names the URL and rank'
assert_equals 'refused:owner unknown for u-task: unreadable sm2 (queue=not queued)' "$(field "$(rec 104)" 5)" 'an unreadable home is named'
assert_contains "$(grep '^sm1|' "$FAKE/send.log")" "sm1|--one-way|PR triage: $URL/100 belongs to your task sm-task." 'steer names the URL'
assert_contains "$(grep '^sm1|' "$FAKE/send.log")" 'Do not force-push.' 'steer carries the fix instruction'
assert_absent "$FAKE/control.log" 'no worker is spawned here for another home or an unowned task'
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 100)" 'refused:owned by sm1: already steered for head sha100' 'same head: no second steer'
assert_equals 'refused:no home owns orphan-meta: firstmate already notified for head sha105aaaaaa (queue=not queued)' "$(field "$(rec 105)" 5)" 'same head: a record, no second notice'
assert_equals 1 "$(wakes 105)" 'one wake per head'
jq '(.[] | select(.number == 105) | .headRefOid) = "pushed105bbbbbb"' "$FAKE/prs.json" > "$FAKE/p.tmp" && mv "$FAKE/p.tmp" "$FAKE/prs.json"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_equals 2 "$(wakes 105)" 'a new head earns one new wake'
[ "$(grep -c '^sm1|' "$FAKE/send.log")" -eq 1 ] || fail 'one steer per head'
jq '(.[] | select(.number == 100) | .headRefOid) = "pushed100bbbbbb"' "$FAKE/prs.json" > "$FAKE/p.tmp" && mv "$FAKE/p.tmp" "$FAKE/prs.json"
touch "$FAKE/send-fail"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(rec 100)" 'refused:owned by sm1: steer failed: error: endpoint retired' 'a failed steer is recorded'
rm -f "$FAKE/send-fail"
bash "$TRIAGE" --apply >/dev/null 2>&1
bash "$TRIAGE" --apply >/dev/null 2>&1
[ "$(grep -c '^sm1|' "$FAKE/send.log")" -eq 2 ] || fail 'a new head earns one new steer after a failed one'
# Oracle: bin/fm-send.sh's one-way retry contract: FM_SEND_REQUEST_ID is 32
# lowercase hex, the same for a retried uncertain request, new for a new one.
ids=$(sed -n 's/^sm1 //p' "$FAKE/send-ids.log")
[ "$(printf '%s\n' "$ids" | wc -l | tr -d ' ')" -eq 3 ] || fail "three sm1 send attempts: $ids"
first=$(printf '%s\n' "$ids" | sed -n 1p); failed=$(printf '%s\n' "$ids" | sed -n 2p); retried=$(printf '%s\n' "$ids" | sed -n 3p)
printf '%s\n' "$first" | grep -Eqx '[0-9a-f]{32}' || fail "request id is 32 lowercase hex: $first"
assert_equals "$failed" "$retried" 'a retried send for the same head reuses its request id'
[ "$first" != "$failed" ] || fail 'a new head sends under a new request id'
# Oracle: bin/fm-task-inbox-lib.sh: under one request id a different body is a
# conflict, so a changed message for the same head must carry a new id.
jq '(.[] | select(.number == 100) | .headRefOid) = "pushed100cccccc"' "$FAKE/prs.json" > "$FAKE/p.tmp" && mv "$FAKE/p.tmp" "$FAKE/prs.json"
touch "$FAKE/send-fail"
bash "$TRIAGE" --apply >/dev/null 2>&1
rm -f "$FAKE/send-fail"
jq '(.[] | select(.number == 100) | .mergeable) = "MERGEABLE"' "$FAKE/prs.json" > "$FAKE/p.tmp" && mv "$FAKE/p.tmp" "$FAKE/prs.json"
bash "$TRIAGE" --apply >/dev/null 2>&1
ids=$(sed -n 's/^sm1 //p' "$FAKE/send-ids.log")
[ "$(printf '%s\n' "$ids" | sed -n 4p)" != "$(printf '%s\n' "$ids" | sed -n 5p)" ] || fail 'a changed message under the same head gets a new request id'
assert_contains "$(rec 100)" 'refused:owned by sm1: steered sm-task' 'the changed message is delivered'
pass 'another home is steered and an unowned task notifies firstmate, once per head each'

# --- one GraphQL read per pass, whatever the number of pull requests ---------------
# Oracle: the owner's rate-limit requirement: the single paginated read serves
# every decision, so the gh call count does not grow with the pull request count.
count_gh() {  # <number of pull requests>
  reset
  backlog < /dev/null
  printf 'label=ci\n' | rules
  for i in $(seq 1 "$1"); do pr $((200 + i)) "fm/many-$i" MERGEABLE PENDING t ci; done | prs
  bash "$TRIAGE" --apply >/dev/null 2>&1
  [ "$(grep -c . "$LOG")" -eq "$1" ] || fail "one record per pull request for $1"
  grep -c . "$FAKE/gh.log"
}
assert_equals 1 "$(count_gh 3)" 'three pull requests: one gh call'
assert_equals 1 "$(count_gh 12)" 'twelve pull requests: still one gh call'
pass 'one gh GraphQL read per pass regardless of the pull request count'

# --- dry run writes nothing --------------------------------------------------------
reset
backlog <<'MD'
- [ ] dry-red - J-01 red (repo: proj) (kind: ship) (since 2026-10-30)
MD
meta dry-red; echo exited > "$FAKE/posture-dry-red"
printf 'label=ci\n' | rules
{ pr 70 fm/dry-red CONFLICTING FAILURE; pr 71 fm/dry-green MERGEABLE SUCCESS t ci; } | prs
out=$(bash "$TRIAGE" 2>&1); rc=$?
expect_code 0 "$rc" 'dry run'
assert_absent "$LOG" 'dry run writes no log'
assert_absent "$H/state/pr-triage" 'dry run writes no marker'
assert_absent "$H/state/.pr-triage.lock" 'dry run takes no lock'
assert_absent "$FAKE/ghaxi.log" 'dry run writes nothing to GitHub'
assert_absent "$FAKE/control.log" 'dry run launches nothing'
assert_contains "$out" "would-record: " 'dry run prints records'
assert_contains "$out" 'launched dry-red (queue=not queued)' 'dry run prints the fix decision'
assert_contains "$out" 'dry-red relaunch --note' 'dry run prints the relaunch command'
assert_contains "$out" 'pr comment 71 --repo o/r --body @mergifyio\ queue' 'dry run prints the queue comment'
pass 'dry run prints decisions and commands and writes nothing'

# --- lock ----------------------------------------------------------------------------
reset
backlog < /dev/null
pr 80 fm/locked MERGEABLE SUCCESS | prs
sleep 300 &
holder=$!
mkdir "$H/state/.pr-triage.lock"; printf '%s\n' "$holder" > "$H/state/.pr-triage.lock/pid"
out=$(bash "$TRIAGE" --apply 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect_code 0 "$rc" 'busy lock exits quietly'
assert_contains "$out" 'another pass holds' 'busy lock is named'
assert_absent "$LOG" 'busy lock writes no record'
assert_absent "$FAKE/gh.log" 'busy lock reads nothing'
rm -rf "$H/state/.pr-triage.lock"
bash "$TRIAGE" --apply >/dev/null 2>&1
assert_contains "$(cat "$LOG")" "$URL/80" 'released lock lets the next pass run'
assert_absent "$H/state/.pr-triage.lock" 'a pass releases its lock'
pass 'a single-instance lock keeps a second pass from running'

# --- PR 2775: conflicting and red, believed queued ----------------------------------
# Every false claim is planted: the main-red label, an earlier record and a
# Mergify comment trail would all say "queued"; only the real queue state counts.
reset
backlog <<'MD'
- [ ] hub-cut - J-01 cut the hub shims (repo: proj) (kind: ship) (since 2026-10-30)
MD
meta hub-cut; echo exited > "$FAKE/posture-hub-cut"
pr 2775 fm/hub-cut CONFLICTING FAILURE 'cut hub shims' main-red | prs
queue 2779 2780
printf '{"number":2775,"queued":false,"dequeued":false,"queue_leave":null}\n' > "$FAKE/show-2775.json"
printf '2026-11-01T00:00:00Z\t%s/2775\t1\tqueue\talready queued\n' "$URL" > "$LOG"
bash "$TRIAGE" --apply >/dev/null 2>&1
r=$(rec 2775)
assert_equals fix "$(field "$r" 4)" 'believed-queued but red: fix, not queue'
assert_equals 'launched hub-cut (queue=not queued)' "$(field "$r" 5)" 'real queue state is read and recorded'
assert_contains "$(cat "$FAKE/mergify.log")" 'queue show 2775 --repository o/r --json' 'per-PR queue state is read from Mergify'
assert_contains "$(cat "$FAKE/control.log")" 'hub-cut relaunch' 'a fix worker launches at once'
assert_absent "$FAKE/ghaxi.log" 'no queue comment on a red pull request'
pass 'PR 2775 case: a red, conflicting pull request believed queued gets a fix worker and its real queue state'

# --- unreadable listing ------------------------------------------------------------
reset
backlog < /dev/null
touch "$FAKE/gh-fail"
bash "$TRIAGE" --apply >/dev/null 2>&1; rc=$?
expect_code 1 "$rc" 'unreadable listing exits 1'
assert_contains "$(cat "$LOG")" '-	-	-	refused:pull requests unreadable: gh: HTTP 502' 'one refusal record'
rm -f "$H/config/pr-triage-rules"
out=$(bash "$TRIAGE" 2>&1); rc=$?
expect_code 1 "$rc" 'missing rules exits 1'
assert_contains "$out" 'missing rules file' 'missing rules are named'
pass 'an unreadable listing or missing rules fail visibly'
