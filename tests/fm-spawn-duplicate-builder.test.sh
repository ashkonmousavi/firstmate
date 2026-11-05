#!/usr/bin/env bash
# Duplicate-builder admission for fresh ship spawns (bin/fm-spawn-admission-lib.sh
# fm_spawn_duplicate_admit, bin/fm-open-pr-lookup.py): before any worktree,
# record or lease exists, a fresh ship reads the forge and refuses when an open
# pull request already carries the task, so a second builder never starts on
# work another machine is already delivering (problem register row 77: a second
# builder started on a task whose pull request had been open for over three hours).
# These drive the real spawn path with a fake terminal. The fake gh below is a
# fixture forge listing: it answers `gh pr list --head` from head.json and
# `gh pr list --search` from search.json in its directory, or fails, hangs, or
# prints garbage on request; the project's origin names GitHub while
# url.<base>.insteadOf points its fetches at a local bare repository.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-duplicate-builder)

# make_case <name> <id> [registry-forge-token]: a home, a project whose origin
# is https://github.com/o/r (fetched from a local bare repository), a pooled
# worktree, a filled brief, and an empty fixture forge.
make_case() {
  local name=$1 id=$2 forge=${3-}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJECT_DIR="$CASE_DIR/proj"
  POOL_DIR="$CASE_DIR/pool"
  BARE_DIR="$CASE_DIR/origin.git"
  FORGE_DIR="$CASE_DIR/forge"
  FAKEBIN_DIR=$(make_spawn_fakebin "$CASE_DIR/fake")
  mkdir -p "$FORGE_DIR"
  printf '[]\n' > "$FORGE_DIR/head.json"
  printf '[]\n' > "$FORGE_DIR/search.json"
  : > "$FORGE_DIR/argv.log"
  cat > "$FAKEBIN_DIR/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE/argv.log"
case $(cat "$FM_TEST_FORGE/mode" 2>/dev/null) in
fail) echo 'HTTP 502: Bad Gateway' >&2; exit 1 ;;
slow) sleep 30 ;;
garbage) echo 'not json'; exit 0 ;;
esac
case " $* " in
*' --head '*) cat "$FM_TEST_FORGE/head.json" ;;
*' --search '*) cat "$FM_TEST_FORGE/search.json" ;;
*) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
  chmod +x "$FAKEBIN_DIR/gh"
  fm_test_spawn_home "$HOME_DIR" codex
  printf -- '- proj [direct-PR%s] - fixture (added 2026-01-01)\n' "${forge:+ $forge}" > "$HOME_DIR/data/projects.md"
  git init --quiet --bare -b main "$BARE_DIR"
  git init --quiet -b main "$PROJECT_DIR"
  printf 'base\n' > "$PROJECT_DIR/README.md"
  git -C "$PROJECT_DIR" add README.md
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$PROJECT_DIR" remote add origin https://github.com/o/r.git
  git -C "$PROJECT_DIR" config "url.file://$BARE_DIR.insteadOf" https://github.com/o/r.git
  git -C "$PROJECT_DIR" push --quiet origin main
  git -C "$PROJECT_DIR" fetch --quiet origin
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$POOL_DIR" "$(git -C "$PROJECT_DIR" rev-parse HEAD)"
  fm_test_spawn_brief "$HOME_DIR" "$id" "Build the duplicate-guarded change."
}

# pr_json <number> <branch> [body] [head-sha]: one gh pr list --json record.
pr_json() {
  python3 -c 'import json, sys; n, b, body, head = sys.argv[1:5]
print(json.dumps([{"number": int(n), "url": "https://github.com/o/r/pull/" + n, "headRefName": b,
  "headRefOid": head, "body": body, "state": "OPEN"}]))' "$1" "$2" "${3-}" "${4-}"
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  FM_OPEN_PR_LOOKUP="$ROOT/bin/fm-open-pr-lookup.py" FM_TEST_FORGE="$FORGE_DIR" FM_SPAWN_FORGE_TIMEOUT="${FORGE_TIMEOUT:-10}" \
    fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --mode direct-PR --yolo off "$@"
}

assert_nothing_created() {  # <id> <what>
  [ ! -e "$HOME_DIR/state/$1.meta" ] || fail "$2: the refused spawn still published a task record"
  [ ! -e "$HOME_DIR/data/$1/launch-brief.md" ] || fail "$2: the refused spawn still rendered a launch brief"
  [ -z "$(git -C "$PROJECT_DIR" branch --list "fm/$1")" ] || fail "$2: the refused spawn still created a branch"
}

test_an_open_pr_on_the_branch_refuses_and_names_it() {
  local id=dup-branch out status first
  make_case branch "$id"
  pr_json 3238 "fm/$id" > "$FORGE_DIR/head.json"
  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "a fresh ship spawned although an open pull request is on its branch"$'\n'"$out"
  assert_contains "$out" "https://github.com/o/r/pull/3238" "the refusal did not print the open pull request's URL"
  assert_contains "$out" "already has an open pull request" "the refusal did not say why"
  assert_contains "$(cat "$FORGE_DIR/argv.log")" "pr list -R o/r --state open --head fm/$id" "the forge was not asked for open pull requests on the task's branch"
  assert_nothing_created "$id" "G5"
  first=$out
  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "a second identical spawn did not refuse the same way"
  [ "$out" = "$first" ] || fail "G6: replay gave a different refusal"$'\n'"$first"$'\n---\n'"$out"
  pass "fm-spawn: an open pull request on the task's branch refuses with its URL, creates nothing, and refuses the same way twice"
}

test_a_pr_body_naming_the_task_refuses_on_another_branch() {
  local id=x-red-intake-l2-stamp out status
  make_case body "$id"
  # The real shape of the incident's pull request (NOT_Q PR 3238): a SLICE line naming the task.
  pr_json 3238 laptop/x-red-intake-l2-stamp \
    $'## Summary\n\nA repeated red-main failure now updates its incident issue.\n\nSLICE: q-server/x-red-intake-l2-stamp | CI red-main intake stamps L2 on the existing task per repeat; integration holder MAIN\n' \
    > "$FORGE_DIR/search.json"
  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "a fresh ship spawned although an open pull request names it on its SLICE line"$'\n'"$out"
  assert_contains "$out" "https://github.com/o/r/pull/3238 (branch laptop/x-red-intake-l2-stamp; body)" "the refusal did not name the pull request and why it matched"
  assert_contains "$(cat "$FORGE_DIR/argv.log")" "--search \"$id\" in:body" "the forge was not searched for the task id"
  assert_nothing_created "$id" "G1b"

  id=dup-task-line
  make_case task-line "$id"
  pr_json 41 other-branch $'Task: q-server:dup-task-line\n' > "$FORGE_DIR/search.json"
  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "a Task: line naming the task did not refuse"$'\n'"$out"
  pass "fm-spawn: a pull request whose SLICE or Task line names the task refuses even on another branch"
}

test_prose_mentions_and_closed_prs_do_not_refuse() {
  local id=dup-prose out status
  make_case prose "$id"
  pr_json 50 other $'This waits for dup-prose.\nBlocked by dup-prose until it lands.\n```\nSLICE: q-server/dup-prose | quoted example\n```\nSLICE: ops/task-system | owner slice\n' \
    > "$FORGE_DIR/search.json"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "a pull request that only mentions the task in prose, a fence or another slice refused the spawn"$'\n'"$out"

  id=dup-closed
  make_case closed "$id"
  python3 -c 'import json; print(json.dumps([{"number": 7, "url": "https://github.com/o/r/pull/7", "headRefName": "fm/dup-closed", "headRefOid": "", "body": "", "state": "MERGED"},
  {"number": 8, "url": "https://github.com/o/r/pull/8", "headRefName": "fm/dup-closed", "headRefOid": "", "body": "", "state": "CLOSED"}]))' > "$FORGE_DIR/head.json"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "G2: a closed or merged pull request refused a fresh spawn"$'\n'"$out"

  id=dup-empty
  make_case empty "$id"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "G9: an empty pull request list refused the spawn"$'\n'"$out"
  [ -e "$HOME_DIR/state/$id.meta" ] || fail "G9: an empty list did not launch"
  assert_contains "$(cat "$FORGE_DIR/argv.log")" "--head fm/$id" "G9: the empty case never asked the forge, so it proves nothing"
  pass "fm-spawn: prose mentions, fenced examples, other slices, closed and merged pull requests and an empty list do not refuse"
}

test_an_unreadable_forge_refuses_as_unknown() {
  local id mode out status
  for mode in fail garbage slow; do
    id="dup-unknown-$mode"
    make_case "unknown-$mode" "$id"
    printf '%s\n' "$mode" > "$FORGE_DIR/mode"
    out=$(FORGE_TIMEOUT=2 run_spawn "$id"); status=$?
    expect_code 1 "$status" "G3: a $mode forge launched a fresh builder blind"$'\n'"$out"
    assert_contains "$out" "UNKNOWN" "G3: a $mode forge was not reported as UNKNOWN"
    assert_nothing_created "$id" "G3 $mode"
  done
  printf '%s\n' "$(pr_json 1 x)" | python3 -c 'import json, sys; r = json.load(sys.stdin)[0]; print(json.dumps([dict(r, number=i, headRefName="other") for i in range(1, 101)]))' > "$FORGE_DIR/search.json"
  rm -f "$FORGE_DIR/mode"
  out=$(run_spawn "$id"); status=$?
  expect_code 1 "$status" "G3: a list that reached its limit was read as complete"$'\n'"$out"
  assert_contains "$out" "reached its limit" "G3: the full list was not named as the reason"

  id=dup-unknown-skip
  make_case unknown-skip "$id"
  printf 'fail\n' > "$FORGE_DIR/mode"
  out=$(run_spawn "$id" --no-forge-check "forge outage, task confirmed unowned with its owner"); status=$?
  expect_code 0 "$status" "G3: --no-forge-check with a reason did not launch"$'\n'"$out"
  assert_contains "$(cat "$HOME_DIR/state/$id.meta")" "forge_check_skipped=forge outage, task confirmed unowned with its owner" "the skip reason was not recorded in the task record"
  [ ! -s "$FORGE_DIR/argv.log" ] || fail "--no-forge-check still read the forge"
  out=$(run_spawn "$id" --no-forge-check ' '); status=$?
  expect_code 1 "$status" "--no-forge-check accepted a blank reason"
  assert_contains "$out" "needs a one-line reason" "a blank --no-forge-check reason was not refused for being blank"
  pass "fm-spawn: a failing, garbled, slow or truncated forge refuses as UNKNOWN; --no-forge-check needs and records a reason"
}

test_continue_pr_attaches_to_the_open_pr_head() {
  local id=dup-continue out status head
  make_case continue "$id"
  git -C "$PROJECT_DIR" switch --quiet -c "fm/$id"
  printf 'work in progress\n' > "$PROJECT_DIR/wip.txt"
  git -C "$PROJECT_DIR" add wip.txt
  git -C "$PROJECT_DIR" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm wip
  git -C "$PROJECT_DIR" push --quiet origin "fm/$id"
  head=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  git -C "$PROJECT_DIR" switch --quiet main
  git -C "$PROJECT_DIR" branch --quiet -D "fm/$id"
  pr_json 3238 "fm/$id" '' "$head" > "$FORGE_DIR/head.json"
  out=$(run_spawn "$id" --continue-pr 3239); status=$?
  expect_code 1 "$status" "--continue-pr attached to a number that is not the open pull request"$'\n'"$out"
  assert_contains "$out" "already has an open pull request" "a wrong --continue-pr number did not refuse as a duplicate"
  out=$(run_spawn "$id" --continue-pr 3238); status=$?
  expect_code 0 "$status" "--continue-pr did not attach to the open pull request"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail "the attached copy does not start at the pull request's head"
  assert_contains "$(cat "$HOME_DIR/state/$id.meta")" "continue_pr=https://github.com/o/r/pull/3238" "the attached pull request was not recorded"
  pass "fm-spawn: --continue-pr <N> attaches only to that open pull request and starts the copy at its head"
}

test_continue_pr_on_another_branch_refuses() {
  local id=dup-continue-other out status
  make_case continue-other "$id"
  pr_json 12 other-branch $'SLICE: h/dup-continue-other | x\n' > "$FORGE_DIR/search.json"
  out=$(run_spawn "$id" --continue-pr 12); status=$?
  expect_code 1 "$status" "--continue-pr attached to a pull request on another branch"$'\n'"$out"
  assert_contains "$out" "not this task's branch" "the refusal did not name the branch mismatch"
  pass "fm-spawn: --continue-pr refuses a pull request that is not on the task's branch"
}

test_kinds_and_forges_that_do_not_consult_the_forge() {
  local id out status forge
  id=dup-scout
  make_case scout "$id"
  pr_json 9 "fm/$id" > "$FORGE_DIR/head.json"
  out=$(FM_TEST_FORGE="$FORGE_DIR" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --scout); status=$?
  expect_code 0 "$status" "a scout was refused by the ship duplicate check"$'\n'"$out"
  [ ! -s "$FORGE_DIR/argv.log" ] || fail "a scout read the forge"

  id=dup-local-only
  make_case local-only "$id"
  pr_json 9 "fm/$id" > "$FORGE_DIR/head.json"
  out=$(FM_TEST_FORGE="$FORGE_DIR" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" --mode local-only --yolo off); status=$?
  expect_code 0 "$status" "a local-only ship was refused although it opens no pull request"$'\n'"$out"
  [ ! -s "$FORGE_DIR/argv.log" ] || fail "a local-only ship read the forge"

  for forge in forge=gerrit forge=external; do
    id="dup-${forge#forge=}"
    make_case "${forge#forge=}" "$id" "$forge"
    pr_json 9 "fm/$id" > "$FORGE_DIR/head.json"
    out=$(run_spawn "$id"); status=$?
    [ ! -s "$FORGE_DIR/argv.log" ] || fail "a $forge project read GitHub pull requests"
    assert_contains "$out" "duplicate-builder check skipped for $id: $forge" "a $forge project skipped the check silently"
  done

  id=dup-relaunch-flag
  make_case relaunch-flag "$id"
  out=$(FM_TEST_FORGE="$FORGE_DIR" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" --relaunch --continue-pr 4); status=$?
  expect_code 1 "$status" "--continue-pr was accepted on a relaunch"
  assert_contains "$out" "apply only to a fresh ship spawn" "the relaunch refusal did not say why"
  pass "fm-spawn: scouts and local-only ships skip the forge; gerrit and external skip with a notice; relaunch refuses the flags"
}

test_relaunch_with_its_own_open_pr_is_not_refused() {
  local id=dup-relaunch out status
  make_case relaunch "$id"
  out=$(run_spawn "$id"); status=$?
  expect_code 0 "$status" "the first spawn should launch"$'\n'"$out"
  pr_json 77 "fm/$id" > "$FORGE_DIR/head.json"
  : > "$FORGE_DIR/argv.log"
  out=$(FM_FAKE_PANE_COMMAND=bash FM_TEST_FORGE="$FORGE_DIR" fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" --relaunch); status=$?
  case $out in
  *"already has an open pull request"*) fail "G8: a relaunch of a task with its own open pull request was refused as a duplicate"$'\n'"$out" ;;
  esac
  [ ! -s "$FORGE_DIR/argv.log" ] || fail "G8: a relaunch consulted the duplicate-builder check"
  pass "fm-spawn: a relaunch of a task with its own open pull request never consults the duplicate check (relaunch exit $status)"
}

# lookup <fakebin> [args...]: the lookup CLI alone, for the forges a spawn
# fixture does not reach (GitLab, Forgejo, GitHub Enterprise, an unknown host).
lookup() {
  local fakebin=$1
  shift
  PATH="$fakebin:$PATH" python3 "$ROOT/bin/fm-open-pr-lookup.py" --branch fm/t1 --task-id t1 --timeout 5 "$@"
}

test_a_deferred_launch_reads_the_forge_when_it_launches() {
  local id=dup-deferred out status
  make_case deferred "$id"
  pr_json 3240 "fm/$id" > "$FORGE_DIR/head.json"
  printf '1 0\n' > "$HOME_DIR/config/lane-capacity"
  out=$(FM_TEST_ACTIVITY_LANES=1 run_spawn "$id"); status=$?
  expect_code 75 "$status" "a spawn on a full machine was not deferred"$'\n'"$out"
  [ ! -s "$FORGE_DIR/argv.log" ] || fail "G8: a deferred spawn read the forge before it had a lane"$'\n'"$(cat "$FORGE_DIR/argv.log")"
  [ -n "$(ls -A "$HOME_DIR/state/spawn-deferred/queue" 2>/dev/null)" ] || fail "G8: the deferred spawn was not recorded for automatic retry"$'\n'"$out"
  # The retry replays the same arguments once a lane is free; the check runs then.
  out=$(FM_TEST_ACTIVITY_LANES=0 run_spawn "$id"); status=$?
  expect_code 1 "$status" "G8: the retried launch did not refuse on the open pull request (a 75 would retry forever)"$'\n'"$out"
  assert_contains "$out" "https://github.com/o/r/pull/3240" "the retried launch did not name the open pull request"
  pass "fm-spawn: a deferred launch reads the forge only when it launches, and its retry refuses on an open pull request"
}

test_every_registry_forge_kind() {
  local dir="$TMP_ROOT/forges" out status
  mkdir -p "$dir/bin"
  cat > "$dir/bin/glab" <<'SH'
#!/usr/bin/env bash
printf '%s GITLAB_HOST=%s\n' "$*" "${GITLAB_HOST-}" >> "$FM_TEST_FORGE/glab.log"
case " $* " in
*' --source-branch '*) echo '[{"iid": 5, "web_url": "https://gitlab.example.com/g/r/-/merge_requests/5", "source_branch": "fm/t1", "sha": "abc", "description": "", "state": "opened"}]' ;;
*) echo '[{"iid": 6, "web_url": "https://gitlab.example.com/g/r/-/merge_requests/6", "source_branch": "x", "sha": "", "description": "Task: t1", "state": "opened"}]' ;;
esac
SH
  cat > "$dir/bin/tea" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_FORGE/tea.log"
case "$1 $2" in
'login list') echo '[{"name": "home", "url": "https://forgejo.example.org"}]' ;;
'api --login') echo '[{"number": 3, "html_url": "https://forgejo.example.org/o/r/pulls/3", "head": {"ref": "fm/t1", "sha": "def"}, "body": "", "state": "open"},
  {"number": 4, "html_url": "https://forgejo.example.org/o/r/pulls/4", "head": {"ref": "y"}, "body": "blocked by t1", "state": "open"}]' ;;
esac
SH
  cat > "$dir/bin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s GH_HOST=%s\n' "$*" "${GH_HOST-}" >> "$FM_TEST_FORGE/gh.log"
echo '[]'
SH
  chmod +x "$dir/bin/glab" "$dir/bin/tea" "$dir/bin/gh"
  out=$(FM_TEST_FORGE=$dir lookup "$dir/bin" --forge none --origin git@gitlab.example.com:g/r.git); status=$?
  expect_code 0 "$status" "GitLab lookup failed"$'\n'"$out"
  assert_contains "$out" '"number": 5' "GitLab: the merge request on the branch was not found"
  assert_contains "$out" '"number": 6' "GitLab: the merge request naming the task on a Task line was not found"
  assert_contains "$(cat "$dir/glab.log")" "mr list -R https://gitlab.example.com/g/r --source-branch fm/t1" "GitLab: the source branch was not asked for"
  out=$(FM_TEST_FORGE=$dir lookup "$dir/bin" --forge forgejo --origin https://forgejo.example.org/o/r.git); status=$?
  expect_code 0 "$status" "Forgejo lookup failed"$'\n'"$out"
  assert_contains "$out" '"number": 3' "Forgejo: the pull request on the branch was not found"
  case $out in *'"number": 4'*) fail "Forgejo: a prose mention counted as naming the task"$'\n'"$out" ;; esac
  assert_contains "$(cat "$dir/tea.log")" "api --login home --repo o/r" "Forgejo: the registered login and repository were not used"
  printf 'ghe.example.com\n' > "$dir/github-hosts"
  out=$(FM_TEST_FORGE=$dir lookup "$dir/bin" --forge none --origin https://ghe.example.com/o/r.git --github-hosts "$dir/github-hosts"); status=$?
  expect_code 0 "$status" "GitHub Enterprise lookup failed"$'\n'"$out"
  assert_contains "$(cat "$dir/gh.log")" "-R ghe.example.com/o/r --state open --head fm/t1" "GitHub Enterprise: the host was not named"
  assert_contains "$(cat "$dir/gh.log")" "GH_HOST=ghe.example.com" "GitHub Enterprise: GH_HOST was not exported"
  out=$(FM_TEST_FORGE=$dir lookup "$dir/bin" --forge none --origin https://git.example.net/o/r.git); status=$?
  expect_code 3 "$status" "an origin host no registry names was not unknown"$'\n'"$out"
  out=$(FM_TEST_FORGE=$dir lookup "$dir/bin" --forge none --origin "file://$dir/x.git"); status=$?
  expect_code 0 "$status" "a local origin did not skip"
  assert_contains "$out" '"state": "skip"' "a local origin was read as a forge"
  mkdir -p "$dir/empty"
  PATH="$dir/empty" "$(command -v python3)" "$ROOT/bin/fm-open-pr-lookup.py" --branch fm/t1 --task-id t1 --forge none --origin https://gitlab.com/g/r >/dev/null; status=$?
  expect_code 3 "$status" "a missing glab was not unknown"
  pass "fm-open-pr-lookup: GitHub, GitHub Enterprise, GitLab and Forgejo are read; an unknown host and a missing tool are unknown; a local origin skips"
}

test_every_registry_forge_kind
test_an_open_pr_on_the_branch_refuses_and_names_it
test_a_pr_body_naming_the_task_refuses_on_another_branch
test_prose_mentions_and_closed_prs_do_not_refuse
test_an_unreadable_forge_refuses_as_unknown
test_continue_pr_attaches_to_the_open_pr_head
test_continue_pr_on_another_branch_refuses
test_kinds_and_forges_that_do_not_consult_the_forge
test_relaunch_with_its_own_open_pr_is_not_refused
test_a_deferred_launch_reads_the_forge_when_it_launches
echo "# all fm-spawn-duplicate-builder tests passed"
