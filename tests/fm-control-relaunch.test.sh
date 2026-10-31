#!/usr/bin/env bash
# fm-control.sh relaunch: the transactional replace-the-agent verb.
#
# Relaunch is the only control verb that changes durable records, so these
# tests pin the transaction itself, hermetically (stubbed session provider, no
# real agent):
#   1. A same-harness relaunch keeps every identity axis and reuses the SAME
#      endpoint and worktree - it replaces an agent, it never forks a task.
#   2. A harness switch is one ordinary relaunch: the record follows, the
#      previous harness's per-task wiring is cleared, and profile axes chosen
#      for the old harness do not silently carry to the new one.
#   3. The progress note is required where the replacement needs it, lands in
#      the instructions the replacement reads, and never rewrites a charter.
#   4. A refusal before the agent is stopped changes nothing.
#   5. A launch failure after the agent is stopped keeps the prior record,
#      reports the concrete state, and preserves the work.
#   6. fm-spawn --relaunch refuses on its own: a live agent, a contradicting
#      flag, an extra positional, or a backend that cannot prove the previous
#      agent exited.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-tasks-axi-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
X_LINK="$ROOT/bin/fm-x-link.sh"
# fm_test_tmproot's own cleanup trap fires when its command substitution exits,
# so recreate the root before resolving it and clean it up from this file's trap.
TMP_ROOT=$(fm_test_tmproot fm-control-relaunch)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && fm_test_remove_tree "$d"
  done
  fm_test_cleanup
}
trap relaunch_cleanup EXIT

# The same lifecycle-modelling tmux stub as tests/fm-control.test.sh: the
# harness's exit command stops the agent, and a launch-brief literal starts the
# harness named in `becomes`.
make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # A relaunch of a Claude task exits it first, and fm-control then lists
  # `claude agents --json`. This fake lists no background session, so the suite
  # never reaches the developer's real Claude account.
  cat > "$fb/claude" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  agents) echo '[]' ;;
esac
exit 0
SH
  chmod +x "$fb/claude"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in
        ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
      esac
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          [ -z "${FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP:-}" ] || exit 1
          ;;
        *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
          cat "$D/becomes" > "$D/command"
          : > "$D/launch-typed"
          [ ! -e "$D/fail-launch-literal" ] || exit 1
          [ -z "${FM_FAKE_CAPACITY_AFTER_LAUNCH:-}" ] || printf '0 0\n' > "$FM_FAKE_CAPACITY_AFTER_LAUNCH"
          [ -z "${FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START:-}" ] || exit 1
          ;;
      esac
    else
      printf '%s\n' "$payload" >> "$D/keys"
      if [ "$payload" = Enter ] && [ -e "$D/launch-typed" ]; then
        [ ! -x "$D/worker-action" ] || "$D/worker-action"
        [ ! -e "$D/fail-launch-enter" ] || exit 1
      fi
      case "$payload" in
        'treehouse get')
          # A released relaunch allocates its copy through the pane's shell:
          # model treehouse moving that shell into the pool slot.
          [ ! -f "$D/treehouse-slot" ] || cp "$D/treehouse-slot" "$D/cwd"
          ;;
        'export GOTMPDIR='*)
          if [ -n "${FM_FAKE_TRACE_PREPARE:-}" ]; then
            : > "$FM_FAKE_TRACE_PREPARE"
            while [ ! -e "$FM_FAKE_TRACE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          ;;
        'export TRACEPARENT='*)
          [ -z "${FM_FAKE_TRACE_EXPORTED:-}" ] || : > "$FM_FAKE_TRACE_EXPORTED"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*)
          if [ -n "${FM_FAKE_RECOVERY_PROBE_READY:-}" ] && [ ! -e "$FM_FAKE_RECOVERY_PROBE_RELEASE" ]; then
            : > "$FM_FAKE_RECOVERY_PROBE_READY"
            while [ ! -e "$FM_FAKE_RECOVERY_PROBE_RELEASE" ]; do /bin/sleep 0.01; done
          fi
          cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*)
          if [ -n "${FM_FAKE_CWD_RACE_READY:-}" ]; then
            : > "$FM_FAKE_CWD_RACE_READY"
            /bin/sleep 1
          fi
          cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    [ -z "${FM_FAKE_COMPOSER_READ_FAIL:-}" ] || exit 1
    if [ -s "$D/composer" ]; then
      printf '╭────╮\n│ %s  │\n╰────╯\n' "$(cat "$D/composer")"
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows)
    # The three shapes real tmux answers a per-session inventory with. The
    # first two are DEFINITIVE and classify `missing`; the third is not and
    # classifies `unreadable`.
    if [ -f "$D/server-dead" ]; then
      echo 'no server running on /tmp/tmux-1000/default' >&2
      exit 1
    fi
    if [ -f "$D/session-missing" ]; then
      echo "can't find session: $(cat "$D/session-name")" >&2
      exit 1
    fi
    if [ -f "$D/inventory-broken" ]; then
      echo 'lost server' >&2
      exit 1
    fi
    [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
  has-session)
    [ ! -f "$D/server-dead" ] && [ ! -f "$D/session-missing" ]
    exit $? ;;
  new-session)
    # Nothing in the relaunch path may ever create a session; recording the
    # call is how a refusal test proves that.
    shift
    ses=
    while [ $# -gt 0 ]; do
      case "$1" in
        -s) ses=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$ses" >> "$D/created-sessions"
    rm -f "$D/server-dead" "$D/session-missing"
    : > "$D/windows"
    exit 0 ;;
  kill-window)
    : > "$D/close-attempted"
    [ ! -e "$D/keep-endpoint-open" ] || exit 0
    : > "$D/windows"
    printf 'zsh' > "$D/command"
    exit 0 ;;
  new-window)
    # Model the one thing an endpoint re-creation depends on: the window now
    # appears in the session inventory, so the very next agent-state read stops
    # answering `missing`. Echo a stable window id the way the real -P -F does.
    shift
    name=
    while [ $# -gt 0 ]; do
      case "$1" in
        -n) name=${2:-}; shift 2 ;;
        -c) printf '%s' "${2:-}" > "$D/cwd"; shift 2 ;;
        -t) shift 2 ;;
        *) shift ;;
      esac
    done
    printf '%s\n' "$name" >> "$D/windows"
    printf '%s\n' "$name" >> "$D/created-windows"
    printf '@9\n'
    [ ! -x "$D/signal-endpoint" ] || "$D/signal-endpoint"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_test_codex_first_turn_wrap "$fb"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
[ -z "${FM_FAKE_LOCK_WAITING:-}" ] || : > "$FM_FAKE_LOCK_WAITING"
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_case <name> [id] -> echoes a case dir with a live claude ship task.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  mkdir -p "$dir/home/config"
  printf '999999 0\n' > "$dir/home/config/lane-capacity"
  fm_test_machine_policy "$dir/home/config"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' fmses > "$dir/fake/session-name"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [harness] [session]
add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude} ses=${4:-fmses}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise relaunch behavior for $id.

## Firstmate spec
Preserve the task while replacing its agent process.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=$harness"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$ses" > "$dir/fake/session-name"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("/tmp/fm-$id")
}

run_control() {  # <case-dir> <args...>
  local dir=$1; shift
  run_lifecycle_fixture "$dir" "$CONTROL" "$@"
}

run_lifecycle_fixture() {
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), and a relaunch reaches it through fm-control.sh, so this runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_REAL_GIT="${FM_REAL_GIT:-}" FM_FAKE_GIT_FAILURE="${FM_FAKE_GIT_FAILURE:-}" \
    FM_REAL_MV="${FM_REAL_MV:-}" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL="${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" \
    FM_FAKE_META_PUBLISH_MV_FAIL="${FM_FAKE_META_PUBLISH_MV_FAIL:-}" \
    FM_FAKE_TRACE_PREPARE="${FM_FAKE_TRACE_PREPARE:-}" \
    FM_FAKE_TRACE_RELEASE="${FM_FAKE_TRACE_RELEASE:-}" \
    FM_FAKE_META_WRITER_READY="${FM_FAKE_META_WRITER_READY:-}" \
    FM_FAKE_TRACE_EXPORTED="${FM_FAKE_TRACE_EXPORTED:-}" \
    "$@" 2>&1
}

run_recovery() {
  local dir=$1
  # shellcheck disable=SC2016 # Expand $1 in the child shell.
  FM_CREW_RECOVERY_CONTROL="$ROOT/bin/fm-control.sh" run_lifecycle_fixture "$dir" \
    bash -c '. "$1"; fm_crew_recovery_sweep' _ "$ROOT/bin/fm-crew-recovery-lib.sh"
}

make_recovery_nm_stub() {
  cat > "$1/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "$*" in
  'axi status'*)
    if [ -f "$D/run-status" ]; then
      [ "$*" != 'axi status --run 01RECOVERY' ] || [ ! -f "$D/run-unreadable" ] || exit 1
      cat "$D/run-status"
    else
      printf 'current_branch: %s\nruns_on_current_branch: 0\n' "$(git branch --show-current)"
    fi
    ;;
  axi) [ ! -f "$D/run-overview" ] || cat "$D/run-overview" ;;
  'daemon status') printf 'daemon running\n' ;;
esac
SH
  chmod +x "$1/fakebin/no-mistakes"
}

run_spawn() {  # <case-dir> <args...>
  local dir=$1; shift
  # A claude spawn pre-registers workspace trust in the launching user's own
  # store (bin/fm-claude-trust.sh), so it runs against a throwaway HOME;
  # without it this suite would write the developer's real ~/.claude.json.
  mkdir -p "$dir/user-home"
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 GROK_HOME="$dir/grokhome" \
    "$SPAWN" "$@" 2>&1
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

make_git_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/git" <<'SH'
#!/usr/bin/env bash
case "${FM_FAKE_GIT_FAILURE:-}:$*" in
  head:*' rev-parse --verify HEAD'|head:*' symbolic-ref -q HEAD') exit 128 ;;
  status:*' status --porcelain') exit 128 ;;
esac
exec "$FM_REAL_GIT" "$@"
SH
  chmod +x "$1/fakebin/git"
}

make_mv_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/mv" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_FAKE_COMPLETE_JOURNAL_MV_FAIL:-}" ]; then
  for path in "$@"; do
    if [ -f "$path" ] && grep -Fqx 'phase=complete' "$path"; then
      exit 1
    fi
  done
fi
if [ -n "${FM_FAKE_META_PUBLISH_MV_FAIL:-}" ]; then
  for path in "$@"; do
    [ "$path" != "$FM_FAKE_META_PUBLISH_MV_FAIL" ] || exit 1
  done
fi
source_path=
target_path=
for path in "$@"; do
  source_path=$target_path
  target_path=$path
done
if [ -n "${FM_FAKE_META_WRITER_TARGET:-}" ] \
   && [ "$target_path" = "$FM_FAKE_META_WRITER_TARGET" ] \
   && grep -q '^x_request=' "$source_path" 2>/dev/null; then
  : > "$FM_FAKE_META_WRITER_READY"
  while [ ! -e "$FM_FAKE_META_WRITER_RELEASE" ]; do /bin/sleep 0.01; done
fi
exec "$FM_REAL_MV" "$@"
SH
  chmod +x "$1/fakebin/mv"
}

make_rm_failure_stub() {  # <case-dir>
  cat > "$1/fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_FAKE_RM_FAIL_PATH:-}" ] && [ "$arg" = "$FM_FAKE_RM_FAIL_PATH" ]; then
    exit 1
  fi
done
exec "$FM_REAL_RM" "$@"
SH
  chmod +x "$1/fakebin/rm"
}

# Give a case home a real backlog carrying <id>, so the relaunch path's paired
# backlog transition (bin/fm-backlog-transition-lib.sh) is live rather than
# skipped for want of a backlog file.
seed_backlog() {  # <case-dir> <id> <queued|in_flight>
  local dir=$1 id=$2 want=$3 file="$1/home/data/backlog.md"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$file"
  tasks-axi add "$id" "relaunch fixture task" --kind ship --file "$file" >/dev/null
  [ "$want" != in_flight ] || tasks-axi start "$id" --file "$file" >/dev/null
}

backlog_state() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Shadow tasks-axi so every `start` fails and every other verb is real. A
# relaunch that re-reads the row before acting never calls it; one that assumes
# it must re-run the transition trips over it.
break_tasks_axi_start() {  # <case-dir>
  local dir=$1 real
  real=$(command -v tasks-axi)
  cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = start ]; then
  echo 'error: "start refused"' >&2
  exit 1
fi
exec "$real" "\$@"
SH
  chmod +x "$dir/fakebin/tasks-axi"
}

# --- 1. same-harness relaunch -----------------------------------------------

# --- relaunch of a released copy ---------------------------------------------
#
# A released record names bin/fm-teardown.sh's <id>.released-copy sentinel and
# the head, branch and pull request teardown proved. The fixture is a real round
# trip on git: a bare origin the project reaches through the pull request's
# GitHub URL (an insteadOf rewrite), the task branch pushed there, a Treehouse-
# shaped pool slot the pane's `treehouse get` moves into, and a fake forge
# answering for the pull request.

# add_released_ship_task <case-dir> <id>: echoes nothing; sets up the record.
add_released_ship_task() {
  local dir=$1 id=$2 home="$1/home" proj="$1/proj" origin="$1/origin.git" pool="$1/pool" head
  fm_git_init_commit "$proj"
  git clone --quiet --bare "$proj" "$origin"
  git -C "$proj" remote add origin https://github.com/example/repo.git
  git -C "$proj" config "url.file://$origin.insteadOf" https://github.com/example/repo.git
  git -C "$proj" checkout -q -b "fm/$id"
  printf 'released work\n' > "$proj/work.txt"
  git -C "$proj" add work.txt
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm 'released work'
  head=$(git -C "$proj" rev-parse HEAD)
  git -C "$proj" push -q origin "fm/$id"
  # Teardown deleted the local branch when it released the copy.
  git -C "$proj" checkout -q main
  git -C "$proj" branch -q -D "fm/$id"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  git -C "$proj" worktree add --quiet --detach "$pool/1/repo" main
  printf '%s' "$pool/1/repo" > "$dir/fake/treehouse-slot"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise the relaunch of a released copy for $id.

## Firstmate spec
Recreate the copy from its pull request's branch.
EOF
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$home/state/$id.released-copy"
    echo "released_head=$head"
    echo "released_branch=fm/$id"
    echo "released_pr=https://github.com/example/repo/pull/7"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "branch=fm/$id"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s$(date +%s).1.1"
    echo "pr=https://github.com/example/repo/pull/7"
  } > "$home/state/$id.meta"
  # Teardown closed the endpoint before writing the sentinel.
  : > "$dir/fake/windows"
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$proj" > "$dir/fake/cwd"
  printf '%s\n' "$head" > "$dir/fake/pr-head"
  printf 'OPEN\n' > "$dir/fake/pr-state"
  printf 'example/repo\n' > "$dir/fake/pr-head-path"
  printf 'fm/%s\n' "$id" > "$dir/fake/pr-head-branch"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-} ${2:-}" in
  'api graphql')
    [ ! -e "$D/pr-unreadable" ] || exit 1
    state=$(cat "$D/pr-state")
    merged=false
    [ "$state" != MERGED ] || merged=true
    printf 'state=%s\nmerged=%s\nhead=%s\nhead_path=%s\nhead_branch=%s\n' "$state" "$merged" "$(cat "$D/pr-head")" "$(cat "$D/pr-head-path")" "$(cat "$D/pr-head-branch")"
    ;;
  *) exit 1 ;;
esac
SH
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$dir/fakebin/gh-axi"
  cat > "$dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_DIR/treehouse-log"
[ ! -e "$FM_FAKE_DIR/fail-return" ] || exit 1
exit 0
SH
  chmod +x "$dir/fakebin/gh" "$dir/fakebin/gh-axi" "$dir/fakebin/treehouse"
  TASK_TMPS+=("/tmp/fm-$id")
}

released_note_count() {  # <case-dir> <id>
  grep -c 'This task was relaunched on a recreated local copy' "$1/home/data/$2/brief.md"
}

# Refusals before or after allocation leave the released record, its brief and
# the relaunch journal exactly as they were.
assert_released_untouched() {  # <case-dir> <id> <meta-before> <brief-before> <what>
  local dir=$1 id=$2 what=$5
  [ "$(cat "$dir/home/state/$id.meta")" = "$3" ] || fail "$what: the released record changed"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$4" ] || fail "$what: the brief changed"
  assert_absent "$dir/home/state/$id.control-relaunch" "$what: a relaunch journal was written"
  assert_absent "$dir/home/state/$id.control-relaunch.meta-prior" "$what: a prior-record copy was written"
}

test_released_copy_relaunch_recreates_the_branch_and_notes_it_once() {
  local dir out rc head slot
  dir=$(new_case released rr1)
  add_released_ship_task "$dir" rr1
  head=$(cat "$dir/fake/pr-head")
  slot="$dir/pool/1/repo"
  out=$(run_control "$dir" rr1 relaunch --note "picked back up after release"); rc=$?
  expect_code 0 "$rc" "a released copy should be recreated and relaunched"$'\n'"$out"
  assert_contains "$out" "recreated-from=released-copy" "the outcome should say the copy was recreated"
  [ "$(meta_field "$dir" rr1 worktree)" = "$slot" ] \
    || fail "the record should name the new copy, got '$(meta_field "$dir" rr1 worktree)'"
  assert_no_grep 'released-copy' "$dir/home/state/rr1.meta" "the sentinel is still in the record"
  assert_no_grep 'released_head=' "$dir/home/state/rr1.meta" "the released fields were kept after recreation"
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = fm/rr1 ] || fail "the new copy is not on the task branch"
  [ "$(git -C "$slot" rev-parse HEAD)" = "$head" ] || fail "the new copy is not at the released head"
  [ "$(git -C "$slot" rev-parse --abbrev-ref '@{upstream}')" = origin/fm/rr1 ] \
    || fail "the new copy's branch does not track the pull request's remote"
  [ -z "$(git -C "$slot" status --porcelain --untracked-files=no)" ] || fail "the new copy is not clean"
  assert_grep 'task=rr1' "$dir/pool/1/.fm-slot-owner" "the new copy's pool slot is not claimed for the task"
  [ "$(released_note_count "$dir" rr1)" = 1 ] || fail "the brief should carry exactly one recreated-copy note"
  assert_grep "$head" "$dir/home/data/rr1/brief.md" "the note does not name the recreated head"
  assert_grep 'picked back up after release' "$dir/home/data/rr1/brief.md" "the note text is missing"
  assert_grep 'were not carried' "$dir/home/data/rr1/brief.md" "the note does not say what was not carried over"
  assert_grep 'This task was relaunched on a recreated local copy' "$dir/home/data/rr1/launch-brief.md" \
    "the launch contract the worker reads does not carry the note"
  [ "$(journal_field "$dir" rr1 phase)" = complete ] || fail "the relaunch journal should end complete"
  assert_no_grep '/exit' "$dir/fake/literal" "no agent was running, so nothing should have been exited"
  pass "relaunch of a released copy recreates the branch at its head in a claimed slot and notes it once"
}

test_released_copy_relaunch_refuses_and_changes_nothing() {
  local dir out rc meta brief why
  for why in merged unreadable alive window-exists; do
    dir=$(new_case "released-refuse-$why" rr2)
    add_released_ship_task "$dir" rr2
    case "$why" in
      merged) printf 'MERGED\n' > "$dir/fake/pr-state" ;;
      unreadable) : > "$dir/fake/pr-unreadable" ;;
      alive) printf 'fm-rr2\n' > "$dir/fake/windows"; printf 'claude' > "$dir/fake/command" ;;
      window-exists) printf 'fm-rr2\n' > "$dir/fake/windows" ;;
    esac
    meta=$(cat "$dir/home/state/rr2.meta")
    brief=$(cat "$dir/home/data/rr2/brief.md")
    out=$(run_control "$dir" rr2 relaunch --note "should not land"); rc=$?
    [ "$rc" -ne 0 ] || fail "$why: the released relaunch should refuse"$'\n'"$out"
    case "$why" in
      merged) assert_contains "$out" "needs cleanup" "merged: the refusal should send it to cleanup" ;;
      unreadable) assert_contains "$out" "could not be read" "unreadable: the refusal should say the pull request could not be read" ;;
      alive) assert_contains "$out" "no agent runs" "alive: the refusal should say an agent is running" ;;
      window-exists) assert_contains "$out" "close that window first" "window-exists: the refusal should ask to close the window" ;;
    esac
    assert_released_untouched "$dir" rr2 "$meta" "$brief" "$why"
    assert_no_grep 'treehouse get' "$dir/fake/keys" "$why: a copy was allocated before the refusal"
  done
  pass "a released relaunch refuses a merged or unreadable pull request and a live or existing endpoint, changing nothing"
}

test_released_copy_relaunch_returns_the_slot_when_the_branch_cannot_be_recreated() {
  local dir out rc meta brief why
  for why in branch-missing rewritten; do
    dir=$(new_case "released-branch-$why" rr3)
    add_released_ship_task "$dir" rr3
    case "$why" in
      branch-missing) git -C "$dir/origin.git" branch -q -D fm/rr3 ;;
      rewritten)
        git -C "$dir/proj" checkout -q -b rewrite main
        git -C "$dir/proj" -c user.name=t -c user.email=t@t commit -q --allow-empty -m 'rewritten history'
        git -C "$dir/proj" push -q -f origin rewrite:fm/rr3
        git -C "$dir/proj" rev-parse HEAD > "$dir/fake/pr-head"
        git -C "$dir/proj" checkout -q main
        git -C "$dir/proj" branch -q -D rewrite
        ;;
    esac
    meta=$(cat "$dir/home/state/rr3.meta")
    brief=$(cat "$dir/home/data/rr3/brief.md")
    out=$(run_control "$dir" rr3 relaunch --note "should not land"); rc=$?
    [ "$rc" -ne 0 ] || fail "$why: the released relaunch should refuse"$'\n'"$out"
    case "$why" in
      branch-missing) assert_contains "$out" "does not exist on origin" "branch-missing: the refusal should name the missing branch" ;;
      rewritten) assert_contains "$out" "does not contain task rr3's released head" "rewritten: the refusal should name the rewritten branch" ;;
    esac
    assert_released_untouched "$dir" rr3 "$meta" "$brief" "$why"
    assert_grep 'treehouse get' "$dir/fake/keys" "$why: the refusal should come after allocation"
    assert_grep "return $dir/pool/1/repo" "$dir/fake/treehouse-log" "$why: the allocated copy was not returned"
    assert_absent "$dir/pool/1/.fm-slot-owner" "$why: the returned slot is still claimed"
  done
  pass "a released relaunch that cannot recreate the branch returns the slot and keeps the sentinel"
}

test_released_copy_relaunch_defers_without_a_free_lane() {
  local dir out rc meta brief
  dir=$(new_case released-defer rr4)
  add_released_ship_task "$dir" rr4
  printf '0 0\n' > "$dir/home/config/lane-capacity"
  meta=$(cat "$dir/home/state/rr4.meta")
  brief=$(cat "$dir/home/data/rr4/brief.md")
  out=$(run_control "$dir" rr4 relaunch --note "should not land"); rc=$?
  expect_code 75 "$rc" "a released relaunch with no free lane should defer"$'\n'"$out"
  assert_released_untouched "$dir" rr4 "$meta" "$brief" "deferred"
  assert_no_grep 'treehouse get' "$dir/fake/keys" "deferred: a copy was allocated"
  pass "a released relaunch with no free lane defers and leaves the brief, journal and record unchanged"
}

test_released_copy_relaunch_retry_adds_no_second_note() {
  local dir out rc
  dir=$(new_case released-retry rr5)
  add_released_ship_task "$dir" rr5
  git -C "$dir/origin.git" branch -q -m fm/rr5 parked
  out=$(run_control "$dir" rr5 relaunch --note "retry note"); rc=$?
  [ "$rc" -ne 0 ] || fail "the first attempt should refuse while the branch is missing"
  git -C "$dir/origin.git" branch -q -m parked fm/rr5
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  : > "$dir/fake/windows"
  out=$(run_control "$dir" rr5 relaunch --note "retry note"); rc=$?
  expect_code 0 "$rc" "the retry should recreate the copy"$'\n'"$out"
  [ "$(released_note_count "$dir" rr5)" = 1 ] || fail "a retried released relaunch left $(released_note_count "$dir" rr5) notes"
  pass "a retried released relaunch adds exactly one progress note"
}

# Two relaunches of one released copy never allocate two copies: the control
# lock refuses the overlapping one, and one that starts after the first
# finished finds an ordinary record and relaunches that copy instead.
test_concurrent_released_relaunches_serialise() {
  local dir rc1 rc2 p1 p2
  dir=$(new_case released-race rr6)
  add_released_ship_task "$dir" rr6
  run_control "$dir" rr6 relaunch --note "first" > "$dir/out1" & p1=$!
  run_control "$dir" rr6 relaunch --note "second" > "$dir/out2" & p2=$!
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?
  { [ "$rc1" -eq 0 ] || [ "$rc2" -eq 0 ]; } \
    || fail "one of two concurrent released relaunches should win (rc $rc1 and $rc2)"$'\n'"$(cat "$dir/out1" "$dir/out2")"
  [ "$(grep -c 'recreated-from=released-copy' "$dir/out1" "$dir/out2" | awk -F: '{ n += $2 } END { print n }')" = 1 ] \
    || fail "exactly one relaunch should recreate the copy"$'\n'"$(cat "$dir/out1" "$dir/out2")"
  [ "$(grep -cx 'treehouse get' "$dir/fake/keys")" = 1 ] || fail "two relaunches allocated two copies"
  [ "$(released_note_count "$dir" rr6)" = 1 ] || fail "concurrent released relaunches left $(released_note_count "$dir" rr6) recreated-copy notes"
  pass "two relaunches of one released copy serialise: one recreates it, and only one copy is allocated"
}

# The launch owner holds the same line on its own: for a released record a
# missing tmux window is gone, while a window that still exists or a live
# agent refuses before anything is allocated.
test_spawn_relaunch_of_a_released_copy_gates_its_endpoint() {
  local dir out rc meta why
  for why in window-exists alive; do
    dir=$(new_case "released-spawn-$why" rr8)
    add_released_ship_task "$dir" rr8
    printf 'fm-rr8\n' > "$dir/fake/windows"
    [ "$why" != alive ] || printf 'claude' > "$dir/fake/command"
    meta=$(cat "$dir/home/state/rr8.meta")
    out=$(run_spawn "$dir" rr8 --relaunch); rc=$?
    [ "$rc" -ne 0 ] || fail "$why: fm-spawn --relaunch of a released copy should refuse"$'\n'"$out"
    [ "$why" != window-exists ] || assert_contains "$out" "close that window first" \
      "window-exists: the refusal should ask to close the window"
    [ "$(cat "$dir/home/state/rr8.meta")" = "$meta" ] || fail "$why: the released record changed"
    assert_no_grep 'treehouse get' "$dir/fake/keys" "$why: a copy was allocated before the refusal"
  done
  dir=$(new_case released-spawn-missing rr8)
  add_released_ship_task "$dir" rr8
  out=$(run_spawn "$dir" rr8 --relaunch); rc=$?
  expect_code 0 "$rc" "a released copy's missing tmux window is gone for its relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" rr8 worktree)" = "$dir/pool/1/repo" ] || fail "the direct relaunch did not recreate the copy"
  pass "fm-spawn --relaunch of a released copy accepts its missing tmux window and refuses an existing or live one"
}

# Teardown held the released item "awaiting merge <pr>". The relaunch lifts
# exactly that hold, and only once its worker is launched; any other hold
# refuses, and a relaunch that fails first leaves the hold where it was.
backlog_held() {  # <case-dir> <id>
  tasks-axi show "$2" --file "$1/home/data/backlog.md" 2>/dev/null | sed -n 's/^  held: *//p' | head -1
}

test_released_relaunch_lifts_only_the_merge_hold_teardown_set() {
  local dir out rc meta why
  for why in teardown-hold captain-hold failed-launch; do
    dir=$(new_case "released-hold-$why" rr11)
    add_released_ship_task "$dir" rr11
    seed_backlog "$dir" rr11 in_flight
    case "$why" in
      captain-hold)
        tasks-axi hold rr11 --kind captain --reason "awaiting merge https://github.com/example/repo/pull/7" \
          --file "$dir/home/data/backlog.md" >/dev/null
        ;;
      *)
        tasks-axi hold rr11 --kind external --reason "awaiting merge https://github.com/example/repo/pull/7" \
          --file "$dir/home/data/backlog.md" >/dev/null
        ;;
    esac
    [ "$why" != failed-launch ] || git -C "$dir/origin.git" branch -q -D fm/rr11
    meta=$(cat "$dir/home/state/rr11.meta")
    out=$(run_control "$dir" rr11 relaunch --note "held"); rc=$?
    case "$why" in
      teardown-hold)
        expect_code 0 "$rc" "teardown-hold: the released relaunch should lift teardown's own merge hold"$'\n'"$out"
        [ "$(backlog_state "$dir" rr11)" = in_flight ] || fail "teardown-hold: the item is not In flight"
        [ "$(backlog_held "$dir" rr11)" = no ] || fail "teardown-hold: the merge hold was not lifted"
        ;;
      captain-hold)
        [ "$rc" -ne 0 ] || fail "captain-hold: a captain hold must refuse the released relaunch"
        assert_contains "$out" "not dispatchable" "captain-hold: the refusal should name the hold"
        [ "$(backlog_held "$dir" rr11)" = yes ] || fail "captain-hold: the captain hold was lifted"
        [ "$(cat "$dir/home/state/rr11.meta")" = "$meta" ] || fail "captain-hold: the released record changed"
        ;;
      failed-launch)
        [ "$rc" -ne 0 ] || fail "failed-launch: the relaunch should fail without its branch"
        [ "$(backlog_held "$dir" rr11)" = yes ] || fail "failed-launch: a failed relaunch lifted the merge hold"
        [ "$(cat "$dir/home/state/rr11.meta")" = "$meta" ] || fail "failed-launch: the released record changed"
        ;;
    esac
  done
  pass "a released relaunch lifts teardown's merge hold only at launch and refuses any other hold"
}

test_released_copy_frees_its_seat_and_the_relaunch_holds_one() {
  local dir out rc
  dir=$(new_case released-seat rr7)
  add_released_ship_task "$dir" rr7
  # shellcheck disable=SC2016 # Expand in the child shell.
  if PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-project-capacity-lib.sh"
      fm_task_record_holds_seat "$2" "$(cat "$2")" "$3"' _ "$ROOT" "$dir/home/state/rr7.meta" "$dir/home/state"; then
    fail "a released record with no agent should hold no seat"
  fi
  out=$(run_control "$dir" rr7 relaunch --note "seat"); rc=$?
  expect_code 0 "$rc" "the released relaunch should succeed"$'\n'"$out"
  # shellcheck disable=SC2016 # Expand in the child shell.
  PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-project-capacity-lib.sh"
      fm_task_record_holds_seat "$2" "$(cat "$2")" "$3"' _ "$ROOT" "$dir/home/state/rr7.meta" "$dir/home/state" \
    || fail "the relaunched worker should hold its seat"
  [ "$(find "$dir/home/state" -maxdepth 1 -name '*.meta' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the relaunch should leave exactly one task record"
  pass "a released record frees its seat and the relaunched worker holds exactly one"
}

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint() {
  local dir out rc gen_before gen_after
  dir=$(new_case same rl1)
  add_ship_task "$dir" rl1 claude
  gen_before=$("$ROOT/bin/fm-busy-event.sh" arm "$dir/home/state" rl1)
  printf 'busy_gen=%s\n' "$gen_before" >> "$dir/home/state/rl1.meta"
  out=$(run_control "$dir" rl1 relaunch --note "stopped mid-refactor"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched rl1 harness=claude from=claude" "the outcome should name the transition"
  [ "$(meta_field "$dir" rl1 window)" = "fmses:fm-rl1" ] \
    || fail "the endpoint must be reused, not recreated"
  [ "$(meta_field "$dir" rl1 worktree)" = "$dir/wt" ] \
    || fail "the worktree must be reused, not reallocated"
  [ "$(meta_field "$dir" rl1 kind)" = ship ] || fail "kind must survive the relaunch"
  [ "$(meta_field "$dir" rl1 project)" = "$dir/proj" ] || fail "project must survive the relaunch"
  gen_after=$(meta_field "$dir" rl1 busy_gen)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] \
    || fail "a relaunch must arm a fresh busy generation, got '$gen_after'"
  [ "$(journal_field "$dir" rl1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "/exit" "$dir/fake/literal" "the previous agent should have been exited"
  assert_grep "cd -- '$dir/wt'" "$dir/fake/keys" "the replacement launch must enter the recorded worktree"
  assert_grep "Firstmate operational input waiting: read" "$dir/fake/literal" "the replacement should have been launched"
  pass "fm-control relaunch: a same-harness relaunch replaces the agent in the same endpoint and worktree"
}

test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text() {
  local dir out rc
  dir=$(new_case pending-exit rl43)
  add_ship_task "$dir" rl43 claude
  printf 'i' > "$dir/fake/composer"

  out=$(run_control "$dir" rl43 relaunch --note "preserve the pending draft"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command into pending composer text"
  assert_contains "$out" "composer visibly holds pending text" \
    "the refusal should name the pending composer text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a pending composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be concatenated onto pending composer text"
  pass "fm-control relaunch: pending composer text refuses before the exit command is typed"
}

test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven() {
  local dir out rc
  dir=$(new_case unproven-exit rl44)
  add_ship_task "$dir" rl44 claude

  out=$(FM_FAKE_COMPOSER_READ_FAIL=1 \
    run_control "$dir" rl44 relaunch --note "preserve on an unreadable composer"); rc=$?

  expect_code 1 "$rc" "a relaunch must refuse before typing an exit command when the composer state cannot be proven empty"
  assert_contains "$out" "not proven empty" \
    "the refusal should name the unproven composer state, not claim pending text"
  assert_not_contains "$out" "visibly holds pending text" \
    "an unreadable composer is not the same claim as observed pending text"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "an unproven composer refusal must leave the old agent running"
  assert_no_grep "/exit" "$dir/fake/literal" \
    "the exit command must not be typed when the composer state is not proven empty"
  pass "fm-control relaunch: an unreadable composer fails safe before the exit command is typed"
}

test_relaunch_from_linked_home_preserves_recorded_worktree() {
  local dir out rc head fetch_head
  dir=$(new_case linked-home rl42)
  add_ship_task "$dir" rl42 claude
  git -C "$dir/proj" worktree add --quiet --detach "$dir/secondmate" HEAD
  sed "s|^project=.*|project=$dir/secondmate|" "$dir/home/state/rl42.meta" > "$dir/linked.meta"
  mv "$dir/linked.meta" "$dir/home/state/rl42.meta"
  printf 'committed task work\n' > "$dir/wt/task.txt"
  git -C "$dir/wt" add task.txt
  git -C "$dir/wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm task-work
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'unfinished task work\n' >> "$dir/wt/task.txt"
  fetch_head=$(git -C "$dir/wt" rev-parse --git-path FETCH_HEAD)

  out=$(run_control "$dir" rl42 relaunch --note "continue from linked home"); rc=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home relaunch\n'
    printf '$ bin/fm-control.sh rl42 relaunch --note "continue from linked home"\n%s\nexit=%s\n' "$out" "$rc"
    printf 'worker HEAD before=%s after=%s\n' "$head" "$(git -C "$dir/wt" rev-parse HEAD)"
    printf 'saved task metadata:\n'; cat "$dir/home/state/rl42.meta"
    printf 'worker status:\n'; git -C "$dir/wt" status --short
    printf 'preserved task.txt:\n'; cat "$dir/wt/task.txt"
    if [ -e "$fetch_head" ]; then
      printf 'worker FETCH_HEAD:\n'; cat "$fetch_head"
    else
      printf 'worker FETCH_HEAD absent\n'
    fi
    printf '# evidence end\n'
  fi
  expect_code 0 "$rc" "a linked spawning home should relaunch its recorded copy"$'\n'"$out"
  [ "$(meta_field "$dir" rl42 worktree)" = "$dir/wt" ] || fail "relaunch replaced the recorded copy"
  [ "$(meta_field "$dir" rl42 project)" = "$dir/secondmate" ] || fail "relaunch replaced the linked spawning home"
  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head" ] || fail "relaunch reset committed task work"
  assert_grep 'unfinished task work' "$dir/wt/task.txt" "relaunch discarded unfinished task work"
  [ ! -e "$fetch_head" ] || fail "relaunch fetched instead of preserving the recorded copy"
  pass "fm-control relaunch: a linked spawning home preserves committed and unfinished work in the recorded copy"
}

test_relaunch_preserves_durable_task_metadata() {
  local dir out rc
  dir=$(new_case durable-meta rl19)
  add_ship_task "$dir" rl19 claude
  {
    printf '%s\n' 'pr=https://github.com/example/repo/pull/19'
    printf '%s\n' 'pr_head=feature/relaunch'
    printf '%s\n' 'x_request=request-19'
    printf '%s\n' 'decisions_reviewed=1'
  } >> "$dir/home/state/rl19.meta"

  out=$(run_control "$dir" rl19 relaunch --note "continuing review work"); rc=$?
  expect_code 0 "$rc" "relaunch should preserve durable metadata"$'\n'"$out"
  [ "$(meta_field "$dir" rl19 pr)" = "https://github.com/example/repo/pull/19" ] \
    || fail "the task PR must survive relaunch"
  [ "$(meta_field "$dir" rl19 pr_head)" = "feature/relaunch" ] \
    || fail "the task PR head must survive relaunch"
  [ "$(meta_field "$dir" rl19 x_request)" = "request-19" ] \
    || fail "the task X request must survive relaunch"
  [ "$(meta_field "$dir" rl19 decisions_reviewed)" = 1 ] \
    || fail "the task decision state must survive relaunch"
  pass "fm-control relaunch: durable task metadata survives replacement launch publication"
}

# shellcheck disable=SC2030 # This case intentionally isolates its exported fixture environment.
test_relaunched_conflict_replacement_exit_wakes_once() (
  local dir state id=rl-conflict url=https://github.com/example/repo/pull/7
  local added_at=2026-01-01T00:00:00Z decision out
  # R1's oracle: an unresolved replacement's exit must request one conflict
  # wake. A successful launch that invalidates its registered poll fails this.
  dir=$(new_case conflict-poll "$id")
  add_ship_task "$dir" "$id" claude
  state="$dir/home/state"
  printf 'pr=%s\n' "$url" >> "$state/$id.meta"
  mkdir -p "$dir/user-home"
  export FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" PATH="$dir/fakebin:$PATH"
  export HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' GROK_HOME="$dir/grokhome"
  export FM_SPAWN_NO_GUARD=1 FM_CONTROL_POLL=0.01
  export FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-pr-lib.sh"
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-backend.sh"
  if ! fm_pr_poll_prepare "$state" "$id" github "$url" github.com example/repo 7 \
    "$ROOT/bin/fm-pr-poll.sh" || ! fm_pr_poll_publish_prepared; then
    fail "could not register the conflict poll before relaunch"
  fi
  fm_pr_poll_snapshot_capture "$state" "$id" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "the initial conflict poll did not authenticate"

  out=$(run_control "$dir" "$id" exit) \
    || fail "could not stop the original worker: $out"
  decision=$(fm_pr_conflict_handle "$state" "$id" github github.com example/repo 7 \
    "$url" "conflict:$added_at")
  [ "$decision" = quiet ] || fail "the dead worker was not relaunched: $decision"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "relaunch did not start the replacement"
  out=$(run_control "$dir" "$id" exit) \
    || fail "could not stop the unresolved replacement: $out"
  fm_pr_poll_snapshot_capture "$state" "$id" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "relaunch invalidated the conflict poll, suppressing replacement-exit recovery"
  decision=$(fm_pr_conflict_handle "$state" "$id" github github.com example/repo 7 \
    "$url" "conflict:$added_at")
  [ "$decision" = wake ] || fail "an exited replacement must request a conflict wake: $decision"
  fm_pr_conflict_episode_open "$state" "$id" github github.com example/repo 7 "$added_at" \
    || fail "could not record the published conflict wake"
  decision=$(fm_pr_conflict_handle "$state" "$id" github github.com example/repo 7 \
    "$url" "conflict:$added_at")
  [ "$decision" = quiet ] || fail "the published replacement-exit wake repeated: $decision"
  pass "real relaunch preserves poll authentication and wakes once after unresolved replacement exit"
)

# shellcheck disable=SC2031 # PATH intentionally retains the parent environment between cases.
test_relaunch_serializes_concurrent_durable_metadata_publication() {
  local dir control_pid link_pid rc i=0 traceparent prepare launch_release waiting ready release
  dir=$(new_case metadata-race rl28)
  add_ship_task "$dir" rl28 claude
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s on\n' "$$" > "$dir/home/state/.trace-context-effective"
  make_mv_failure_stub "$dir"
  prepare="$dir/trace-prepare"
  launch_release="$dir/trace-release"
  waiting="$dir/meta-writer-waiting"
  ready="$dir/meta-writer-ready"
  release="$dir/meta-writer-release"
  FM_REAL_MV=$(command -v mv) \
    FM_FAKE_TRACE_PREPARE="$prepare" \
    FM_FAKE_TRACE_RELEASE="$launch_release" \
    run_control "$dir" rl28 relaunch --note "continue after publication" > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$prepare" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$prepare" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach trace delivery"
  }
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_REAL_MV="$(command -v mv)" \
    FM_FAKE_LOCK_WAITING="$waiting" \
    FM_FAKE_META_WRITER_TARGET="$dir/home/state/rl28.meta" \
    FM_FAKE_META_WRITER_READY="$ready" \
    FM_FAKE_META_WRITER_RELEASE="$release" \
    "$X_LINK" rl28 request-28 --carry-count 1 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 > "$dir/link.out" 2>&1 &
  link_pid=$!
  i=0
  while [ ! -e "$waiting" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$waiting" ] && [ ! -e "$ready" ] || {
    : > "$launch_release"
    : > "$release"
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "a durable metadata writer was not blocked during relaunch delivery"
  }
  : > "$launch_release"
  i=0
  while [ ! -e "$ready" ] && [ "$i" -lt 500 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$ready" ] || {
    kill "$link_pid" "$control_pid" 2>/dev/null || true
    wait "$link_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "durable metadata writer did not resume after relaunch delivery committed"
  }
  : > "$release"
  wait "$link_pid"; rc=$?
  expect_code 0 "$rc" "concurrent X metadata publication should serialize"$'\n'"$(cat "$dir/link.out")"
  wait "$control_pid"; rc=$?
  expect_code 0 "$rc" "relaunch should complete before serialized metadata publication"$'\n'"$(cat "$dir/control.out")"
  [ "$(meta_field "$dir" rl28 x_request)" = request-28 ] \
    || fail "relaunch erased metadata published concurrently through the X interface"
  [ "$(meta_field "$dir" rl28 x_followups)" = 1 ] \
    || fail "relaunch erased the concurrent follow-up count"
  traceparent=$(meta_field "$dir" rl28 traceparent)
  fm_trace_context_valid "$traceparent" \
    || fail "concurrent metadata publication erased the replacement's trace carrier"
  pass "fm-control relaunch: delivery and concurrent task metadata publication serialize"
}

test_disabled_relaunch_clears_prior_trace_context() {
  local dir out rc
  dir=$(new_case trace-off rl33)
  add_ship_task "$dir" rl33 claude
  printf '%s\n' 'traceparent=00-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-bbbbbbbbbbbbbbbb-01' \
    >> "$dir/home/state/rl33.meta"
  printf '%s\n' "$$" > "$dir/home/state/.lock"
  printf '%s off\n' "$$" > "$dir/home/state/.trace-context-effective"

  out=$(run_control "$dir" rl33 relaunch --note "crossing trace boundary"); rc=$?
  expect_code 0 "$rc" "disabled relaunch should succeed"$'\n'"$out"
  [ -z "$(meta_field "$dir" rl33 traceparent)" ] \
    || fail "disabled relaunch must remove the prior trace carrier from metadata"
  grep -q '^unset TRACEPARENT; .*claude' "$dir/fake/literal" \
    || fail "disabled relaunch must clear the pane carrier before replacement launch"
  ! grep -q '^export TRACEPARENT=' "$dir/fake/literal" \
    || fail "disabled relaunch must not export a replacement trace carrier"
  pass "fm-control relaunch: disabling tracing clears metadata and pane context"
}

test_relaunch_appends_the_progress_note_to_the_instructions() {
  local dir out rc brief launch_brief first_line role_line task_line
  dir=$(new_case note rl2)
  add_ship_task "$dir" rl2 claude
  cp "$ROOT/AGENTS.md" "$dir/wt/AGENTS.md"
  out=$(run_control "$dir" rl2 relaunch --note "reproduced the crash in parser.go"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2/brief.md"
  assert_grep "Exercise relaunch behavior for rl2." "$brief" "the original instructions must survive"
  assert_grep "## Progress note" "$brief" "the note should be a dated section in the instructions"
  assert_grep "reproduced the crash in parser.go" "$brief" "the note text should reach the replacement"
  assert_grep "reproduced the crash in parser.go" "$dir/home/state/rl2.control-relaunch.note" \
    "the note should also be preserved beside the transaction record"
  launch_brief="$dir/home/data/rl2/launch-brief.md"
  first_line=$(sed -n '1p' "$launch_brief")
  [ "$first_line" = '# Current worker role contract' ] ||
    fail "a Firstmate-worktree relaunch did not establish the crewmate identity first"
  role_line=$(grep -n '^# Current worker role contract$' "$launch_brief" | cut -d: -f1)
  task_line=$(grep -n '^# Task$' "$launch_brief" | head -1 | cut -d: -f1)
  [ "$role_line" -lt "$task_line" ] || fail "the relaunched worker identity followed its task content"
  assert_grep "$dir/home/state/rl2.inbox" "$launch_brief" \
    "the Firstmate-worktree relaunch omitted the worker's exact steering inbox"
  assert_grep 'do not reject it as another home' "$launch_brief" \
    "the Firstmate-worktree relaunch did not distinguish its inbox from cross-home state"
  pass "fm-control relaunch: progress and the Firstmate-worktree worker identity reach the replacement"
}

test_relaunch_note_inbox_listing_is_safe_on_empty_inbox() {
  local dir out rc brief cmd inbox shell_name status
  dir=$(new_case notelist rl2b)
  add_ship_task "$dir" rl2b claude
  out=$(run_control "$dir" rl2b relaunch --note "resume"); rc=$?
  expect_code 0 "$rc" "relaunch should succeed"$'\n'"$out"
  brief="$dir/home/data/rl2b/brief.md"
  # shellcheck disable=SC2016
  cmd=$(sed -n 's/^`\(find [^`]*\)`.*/\1/p' "$brief" | head -1)
  [ -n "$cmd" ] || fail "the progress note does not give a find-based inbox listing command"
  inbox="$dir/home/state/rl2b.inbox"
  for shell_name in bash zsh; do
    command -v "$shell_name" >/dev/null 2>&1 || continue
    rm -rf "$inbox"
    status=0
    out=$("$shell_name" -c "$cmd" 2>&1) || status=$?
    [ "$status" -eq 0 ] && [ -z "$out" ] || fail "$shell_name: absent inbox listing was not silent success (exit $status): $out"
    mkdir -p "$inbox"
    status=0
    out=$("$shell_name" -c "$cmd" 2>&1) || status=$?
    [ "$status" -eq 0 ] && [ -z "$out" ] || fail "$shell_name: empty inbox listing was not silent success (exit $status): $out"
    : > "$inbox/1000.msg"
    : > "$inbox/999.msg"
    out=$("$shell_name" -c "$cmd" 2>&1 | sed 's#.*/##' | tr '\n' ' ')
    [ "$out" = "999.msg 1000.msg " ] || fail "$shell_name: messages not listed in numeric order: $out"
  done
  pass "fm-control relaunch: the progress note's inbox listing is silent on an empty inbox"
}

test_relaunch_requires_a_note_for_a_ship_task() {
  local dir out rc before
  dir=$(new_case nonote rl3)
  add_ship_task "$dir" rl3 claude
  before=$(cat "$dir/home/data/rl3/brief.md")
  out=$(run_control "$dir" rl3 relaunch); rc=$?
  expect_code 1 "$rc" "a ship relaunch without a note should refuse"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(cat "$dir/home/data/rl3/brief.md")" = "$before" ] \
    || fail "a refused relaunch must not touch the instructions"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a ship task refuses without the progress note its replacement needs"
}

# --- 2. harness switch -------------------------------------------------------

test_harness_switch_moves_the_record_and_clears_prior_wiring() {
  local dir out rc
  dir=$(new_case switch rl4)
  add_ship_task "$dir" rl4 claude
  # Wiring the previous claude incarnation left in the worktree.
  mkdir -p "$dir/wt/.claude"
  printf '{"hooks":{}}\n' > "$dir/wt/.claude/settings.local.json"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl4 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  assert_contains "$out" "harness=codex from=claude" "the outcome should name both harnesses"
  [ "$(meta_field "$dir" rl4 harness)" = codex ] || fail "the record should follow the switch"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "the previous harness's per-task wiring must be cleared on a switch"
  assert_grep "codex" "$dir/fake/literal" "the replacement launch should be the new harness"
  [ "$(journal_field "$dir" rl4 from_harness)" = claude ] || fail "the journal should record the origin harness"
  [ "$(journal_field "$dir" rl4 to_harness)" = codex ] || fail "the journal should record the target harness"
  pass "fm-control relaunch: switching harness is one ordinary relaunch, and the old wiring goes with the old agent"
}

test_refused_relaunch_onto_polytoken_keeps_the_project_hook_layer() {
  local dir out rc
  dir=$(new_case polytokenownhooks rl45)
  add_ship_task "$dir" rl45 claude
  # The project's own polytoken hook layer and a same-named facet, neither
  # generated by firstmate; the refused arm and its abort cleanup must keep both.
  mkdir -p "$dir/wt/.polytoken/facets"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$dir/wt/.polytoken/hooks.json"
  printf -- '---\nname: firstmate-worker\n---\nproject facet\n' \
    > "$dir/wt/.polytoken/facets/firstmate-worker.md"
  printf 'polytoken' > "$dir/fake/becomes"
  # Profile validation precedes the hook-layer refusal, so the fixture must
  # advertise its explicit pin without requiring a real Polytoken installation.
  cat > "$dir/fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'print models') printf '%s\n' 'zai/glm-5.3-flash' 'zai/glm-5.3-flash(low)' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/polytoken"
  out=$(run_control "$dir" rl45 relaunch --harness polytoken \
    --model zai/glm-5.3-flash --effort low --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a relaunch onto polytoken over a project hook layer must refuse"$'\n'"$out"
  assert_contains "$out" "not firstmate's to clobber" \
    "the refusal must come from the polytoken arm"$'\n'"$out"
  assert_contains "$(cat "$dir/wt/.polytoken/hooks.json" 2>/dev/null)" "project-own" \
    "an aborted relaunch must leave the project's own hook layer in place"
  assert_contains "$(cat "$dir/wt/.polytoken/facets/firstmate-worker.md" 2>/dev/null)" "project facet" \
    "an aborted relaunch must leave a facet it did not generate in place"
  [ "$(meta_field "$dir" rl45 harness)" = claude ] \
    || fail "a refused relaunch must keep the prior record"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch onto polytoken must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch onto polytoken must not stop the agent"
  pass "fm-control relaunch: a refused relaunch onto polytoken keeps the project's own hook layer and the running agent"
}

test_refused_polytoken_profile_leaves_the_running_agent() {
  local dir out rc
  dir=$(new_case polytokenprofile rl47)
  add_ship_task "$dir" rl47 claude
  printf 'polytoken' > "$dir/fake/becomes"
  cat > "$dir/fakebin/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  'print models') printf '%s\n' 'zai/glm-5.3-flash' 'zai/glm-5.3-flash(low)' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/polytoken"
  out=$(run_control "$dir" rl47 relaunch --harness polytoken --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a switch onto polytoken with default axes must refuse"$'\n'"$out"
  assert_contains "$out" "requires concrete --model and --effort" \
    "the refusal must name the missing worker profile"$'\n'"$out"
  out=$(run_control "$dir" rl47 relaunch --harness polytoken \
    --model zai/unlisted --effort low --note "switching runtime"); rc=$?
  [ "$rc" -ne 0 ] || fail "a switch onto an unlisted polytoken model must refuse"$'\n'"$out"
  assert_contains "$out" "is not listed by 'polytoken print models'" \
    "the refusal must come from the polytoken catalog"$'\n'"$out"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused polytoken profile must send nothing"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused polytoken profile must not stop the agent"
  [ "$(meta_field "$dir" rl47 harness)" = claude ] || fail "a refused polytoken profile must keep the prior record"
  [ ! -e "$dir/wt/.polytoken" ] || fail "a refused polytoken profile must write no wiring"
  pass "fm-control relaunch: a refused polytoken profile leaves the running agent untouched"
}

test_relaunch_off_opencode_removes_tracked_wiring() {
  local dir out
  dir=$(new_case opencodetracked rl78)
  add_ship_task "$dir" rl78 opencode
  mkdir -p "$dir/wt/.opencode/plugins"
  printf 'prior busy plugin\n' > "$dir/wt/.opencode/plugins/fm-busy-state.js"
  git -C "$dir/wt" add .opencode/plugins/fm-busy-state.js
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "tracked prior wiring"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl78 --relaunch --harness claude)
  assert_contains "$out" "spawned rl78 harness=claude" "the relaunch off opencode should complete"
  [ ! -e "$dir/wt/.opencode/plugins/fm-busy-state.js" ] \
    || fail "retiring opencode wiring must still remove tracked files as on main"
  pass "fm-spawn --relaunch: tracked opencode wiring is retired as on main"
}

test_relaunch_from_a_raw_polytoken_launch_keeps_the_project_layers() {
  local dir out
  dir=$(new_case polytokenrawprior rl46)
  add_ship_task "$dir" rl46 polytoken
  # A raw-launched polytoken task never had firstmate wiring, so the tracked
  # project hook layer and an untracked facet it did not generate both belong
  # to the project and must outlive the prior-wiring retirement.
  mkdir -p "$dir/wt/.polytoken/facets"
  printf '[{"name":"project-own","event":"stop","handler":{"bash":"/bin/true"}}]\n' \
    > "$dir/wt/.polytoken/hooks.json"
  git -C "$dir/wt" add .polytoken/hooks.json
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m "project hook layer"
  printf -- '---\nname: firstmate-worker\n---\nproject facet\n' \
    > "$dir/wt/.polytoken/facets/firstmate-worker.md"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl46 --relaunch --harness claude)
  assert_contains "$out" "spawned rl46 harness=claude" "the relaunch off polytoken should complete"
  assert_contains "$(cat "$dir/wt/.polytoken/hooks.json" 2>/dev/null)" "project-own" \
    "retiring the prior polytoken wiring must keep the project's tracked hook layer"
  assert_contains "$(cat "$dir/wt/.polytoken/facets/firstmate-worker.md" 2>/dev/null)" "project facet" \
    "retiring the prior polytoken wiring must keep a facet firstmate did not generate"
  [ -z "$(git -C "$dir/wt" status --porcelain -- .polytoken/hooks.json)" ] \
    || fail "the tracked project hook layer must be left unmodified"
  pass "fm-spawn --relaunch: retiring a raw polytoken launch's wiring keeps the project's own layers"
}

test_harness_switch_does_not_carry_the_old_profile_axes() {
  local dir out rc
  dir=$(new_case profile rl5)
  add_ship_task "$dir" rl5 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=xhigh/' \
    "$dir/home/state/rl5.meta" > "$dir/home/state/rl5.meta.tmp"
  mv "$dir/home/state/rl5.meta.tmp" "$dir/home/state/rl5.meta"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" rl5 relaunch --harness codex --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "a harness switch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl5 model)" = default ] \
    || fail "a model chosen for the old harness must not carry to a different one"
  [ "$(meta_field "$dir" rl5 effort)" = default ] \
    || fail "an effort chosen for the old harness must not carry to a different one"
  pass "fm-control relaunch: a harness switch resets model and effort unless they are named too"
}

test_harness_switch_resolves_a_prefixed_recorded_harness() {
  local dir out rc auth
  dir=$(new_case prefixcontrol rl32)
  add_ship_task "$dir" rl32 grok-2
  printf 'grok-2' > "$dir/fake/command"
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl32.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl32.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"

  out=$(run_control "$dir" rl32 relaunch --harness claude --note "switching runtime"); rc=$?
  expect_code 0 "$rc" "relaunch should resolve a prefixed recorded harness"$'\n'"$out"
  [ "$(sed -n '1p' "$dir/fake/literal")" = /exit ] \
    || fail "relaunch should stop a grok-prefixed task with grok's exit command"
  [ "$(meta_field "$dir" rl32 harness)" = claude ] \
    || fail "relaunch should publish the explicitly selected replacement harness"
  [ "$(journal_field "$dir" rl32 from_harness)" = grok-2 ] \
    || fail "relaunch should retain the recorded harness basename in its provenance"
  assert_contains "$out" "harness=claude from=grok-2" \
    "relaunch should report the recorded-to-selected harness transition"
  [ ! -e "$auth" ] && [ ! -e "$dir/home/state/rl32.grok-turnend-token" ] \
    && [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "relaunch should retire wiring owned by the prefixed prior harness"
  pass "fm-control relaunch: a prefixed recorded harness can switch adapters transactionally"
}

test_prefixed_recorded_harness_requires_explicit_replacement() {
  local dir out rc meta brief
  dir=$(new_case prefixrefuse rl34)
  add_ship_task "$dir" rl34 grok-2
  printf 'grok-2' > "$dir/fake/command"
  meta="$dir/home/state/rl34.meta"
  brief="$dir/home/data/rl34/brief.md"
  cp "$meta" "$dir/meta.before"
  cp "$brief" "$dir/brief.before"

  out=$(run_control "$dir" rl34 relaunch --note "continue safely"); rc=$?
  expect_code 1 "$rc" "implicit relaunch from a prefixed command should refuse"
  assert_contains "$out" "original launch command cannot be reconstructed from its recorded basename" \
    "the refusal should name the missing launch identity"
  assert_contains "$out" "would substitute the canonical adapter 'grok'" \
    "the refusal should name the unsafe substitution"
  assert_contains "$out" "Pass an explicit --harness" \
    "the refusal should name the deliberate replacement path"
  cmp -s "$meta" "$dir/meta.before" \
    || fail "a refused prefixed relaunch must leave metadata byte-identical"
  cmp -s "$brief" "$dir/brief.before" \
    || fail "a refused prefixed relaunch must leave instructions byte-identical"
  [ "$(cat "$dir/fake/command")" = grok-2 ] \
    || fail "a refused prefixed relaunch must leave the original agent alive"
  [ -z "$(cat "$dir/fake/literal")" ] && [ -z "$(cat "$dir/fake/keys")" ] \
    || fail "a refused prefixed relaunch must deliver no lifecycle input"
  [ ! -e "$dir/home/state/rl34.control-relaunch" ] \
    || fail "a refused prefixed relaunch must not create a durable journal"
  pass "fm-control relaunch: a prefixed command requires an explicit replacement harness"
}

test_same_harness_relaunch_keeps_the_profile_axes() {
  local dir out rc
  dir=$(new_case keepprofile rl6)
  add_ship_task "$dir" rl6 claude
  sed 's/^model=default$/model=opus/; s/^effort=default$/effort=high/' \
    "$dir/home/state/rl6.meta" > "$dir/home/state/rl6.meta.tmp"
  mv "$dir/home/state/rl6.meta.tmp" "$dir/home/state/rl6.meta"
  out=$(run_control "$dir" rl6 relaunch --note "same runtime"); rc=$?
  expect_code 0 "$rc" "a same-harness relaunch should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl6 model)" = opus ] || fail "the model should carry across a same-harness relaunch"
  [ "$(meta_field "$dir" rl6 effort)" = high ] || fail "the effort should carry across a same-harness relaunch"
  pass "fm-control relaunch: a same-harness relaunch keeps the profile axes it was running with"
}

test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop() {
  local dir out rc id=rl-ultra
  dir=$(new_case native-ultra "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  sed 's|^model=default$|model=codex-native/gpt-6-astra|; s/^effort=default$/effort=ultra/' \
    "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.tmp"
  mv "$dir/home/state/$id.meta.tmp" "$dir/home/state/$id.meta"
  out=$(run_control "$dir" "$id" relaunch --model openai-codex/gpt-6-astra --note "invalid native effort transfer"); rc=$?
  expect_code 1 "$rc" "Ultra transferred to ordinary Pi"
  assert_contains "$out" "ultra effort requires pi or pi-signed" "model-aware relaunch refusal missing"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "invalid Ultra relaunch stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "invalid Ultra relaunch sent lifecycle input"
  out=$(run_control "$dir" "$id" relaunch --note "preserve explicit native effort"); rc=$?
  expect_code 0 "$rc" "native Ultra relaunch failed: $out"
  [ "$(meta_field "$dir" "$id" effort)" = ultra ] || fail "relaunch lost Ultra metadata"
  [ "$(meta_field "$dir" "$id" model)" = codex-native/gpt-6-astra ] || fail "relaunch lost native model"
  assert_contains "$(cat "$dir/fake/literal")" "--codex-effort 'ultra'" "relaunch lost native flag"
  assert_not_contains "$(cat "$dir/fake/literal")" "--thinking 'ultra'" "relaunch used an invalid Pi level"
  pass "native Ultra relaunch preserves its profile and rejects an unsupported model before stopping"
}

# A fake claude that answers `claude auth status` the way the real runner
# does: signed in only when the selected config root holds a stored login.
make_claude_auth_stub() {  # <case-dir>
  cat > "$1/fakebin/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$1/fakebin/claude"
}

test_signed_out_worker_account_pin_refuses_before_stop() {
  local dir out rc id=rl-acct-out
  dir=$(new_case acct-out "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  cp "$dir/home/state/$id.meta" "$dir/meta-before"
  out=$(run_control "$dir" "$id" relaunch --note "account signed out"); rc=$?
  expect_code 1 "$rc" "a relaunch under a signed-out account pin must refuse"
  assert_contains "$out" "config/claude-account pins Claude workers to $dir/work, which is not signed in" \
    "the refusal should name the pin and the signed-out root"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a signed-out pin must refuse before the running agent stops"
  [ ! -s "$dir/fake/literal" ] || fail "a signed-out pin must refuse before any lifecycle input is sent"
  cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "a refused relaunch must leave the task record untouched"
  pass "fm-control relaunch: a signed-out worker account pin refuses before the old agent stops"
}

test_worker_account_pin_follows_the_relaunch() {
  local dir out rc id=rl-acct
  dir=$(new_case acct "$id")
  add_ship_task "$dir" "$id" claude
  make_claude_auth_stub "$dir"
  mkdir -p "$dir/home/config" "$dir/work"
  : > "$dir/work/.credentials.json"
  printf '%s\n' "$dir/work" > "$dir/home/config/claude-account"
  out=$(run_control "$dir" "$id" relaunch --note "pinned account"); rc=$?
  expect_code 0 "$rc" "a relaunch under a signed-in account pin should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" account)" = "$dir/work" ] || fail "the relaunched record should carry the pinned account"
  [ "$(meta_field "$dir" "$id" claude_config_dir)" = "$dir/work" ] \
    || fail "the replacement must record the pinned Claude config root"
  assert_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR='$dir/work'" \
    "the replacement should launch under the pinned root"
  rm "$dir/home/config/claude-account"
  : > "$dir/fake/literal"
  out=$(run_control "$dir" "$id" relaunch --note "pin removed"); rc=$?
  expect_code 0 "$rc" "a relaunch after the pin is removed should succeed"$'\n'"$out"
  assert_no_grep "account=" "$dir/home/state/$id.meta" "a relaunch without a pin must drop the previous account from the record"
  # shellcheck disable=SC2031 # The earlier subshell fixture leaves the ambient root unchanged.
  [ "$(meta_field "$dir" "$id" claude_config_dir)" = "${CLAUDE_CONFIG_DIR:-}" ] \
    || fail "an unpinned replacement must record its ambient Claude root for later cleanup"
  assert_not_contains "$(cat "$dir/fake/literal")" "CLAUDE_CONFIG_DIR=" \
    "an unpinned replacement must launch exactly as before"
  pass "fm-control relaunch: the replacement follows the home's current worker account pin"
}

test_secondmate_account_pin_follows_relaunch_and_refuses_before_stop() {
  local dir out rc id=rl-sm-acct harness file variable pin
  for harness in claude pi; do
    dir=$(new_case "sm-account-$harness" "$id")
    add_ship_task "$dir" "$id" "$harness"
    make_claude_auth_stub "$dir"
    cat > "$dir/fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) printf 'Options: --tui-mode\n' ;;
  auth)
    if grep -qx "$4" "$PI_CODING_AGENT_DIR/signed-in" 2>/dev/null; then
      printf '{"status":"ready"}\n'
    else
      printf '{"status":"not_ready","reason":"credentials_not_configured"}\n'
      exit 1
    fi ;;
esac
SH
    chmod +x "$dir/fakebin/pi"
    file=claude-account; variable=CLAUDE_CONFIG_DIR
    if [ "$harness" = pi ]; then file=pi-account; variable=PI_CODING_AGENT_DIR; fi
    printf '%s' "$harness" > "$dir/fake/command"
    printf '%s' "$harness" > "$dir/fake/becomes"
    mkdir -p "$dir/wt/state" "$dir/wt/data" "$dir/wt/bin" \
      "$dir/home/config/secondmate-accounts/$id" "$dir/primary" "$dir/mate" "$dir/new-mate"
    printf '%s\n' "$id" > "$dir/wt/.fm-secondmate-home"
    printf '# agents\n' > "$dir/wt/AGENTS.md"
    printf '# charter\n' > "$dir/wt/data/charter.md"
    printf '%s openai-codex/gpt-5.5\n' "$harness" > "$dir/home/config/secondmate-harness"
    {
      printf 'window=fmses:fm-%s\nendpoint_task_id=%s\n' "$id" "$id"
      printf 'worktree=%s\nproject=%s\nhome=%s\n' "$dir/wt" "$dir/wt" "$dir/wt"
      printf 'harness=%s\nkind=secondmate\nmode=secondmate\nyolo=off\nmodel=default\neffort=default\n' "$harness"
    } > "$dir/home/state/$id.meta"
    : > "$dir/primary/.credentials.json"
    : > "$dir/mate/.credentials.json"
    : > "$dir/new-mate/.credentials.json"
    printf 'openai-codex\n' > "$dir/primary/signed-in"
    printf 'openai-codex\n' > "$dir/mate/signed-in"
    printf 'openai-codex\n' > "$dir/new-mate/signed-in"
    printf '%s\n' "$dir/primary" > "$dir/home/config/$file"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$dir/home/config/$file"
    pin="$dir/home/config/secondmate-accounts/$id/$file"
    printf '%s\n' "$dir/mate" > "$pin"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "the secondmate should relaunch on its $harness pin: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/mate'" "the replacement must use the mate's pin"
    [ "$(meta_field "$dir" "$id" account)" = "$dir/mate" ] || fail "the record must name the mate's account"
    printf '%s\n' "$dir/new-mate" > "$pin"
    [ "$harness" = claude ] || printf 'openai-codex\n' >> "$pin"
    : > "$dir/fake/literal"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "a changed durable pin should govern relaunch: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/new-mate'" "relaunch must not reuse the old recorded account"
    rm "$dir/new-mate/.credentials.json" "$dir/new-mate/signed-in"
    cp "$dir/home/state/$id.meta" "$dir/meta-before"
    : > "$dir/fake/literal"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 1 "$rc" "a signed-out mate account must refuse before stop"
    assert_contains "$out" "$pin" "the refusal must name the mate setting"
    assert_contains "$out" 'not signed in' "the refusal must name the reason"
    [ "$(cat "$dir/fake/command")" = "$harness" ] || fail "the running mate must remain alive"
    [ ! -s "$dir/fake/literal" ] || fail "the refused relaunch must send no lifecycle input"
    cmp -s "$dir/meta-before" "$dir/home/state/$id.meta" || fail "the refused relaunch must preserve metadata"
    rm "$pin"
    out=$(run_control "$dir" "$id" relaunch); rc=$?
    expect_code 0 "$rc" "removing the mate pin should restore the primary's pin: $out"
    assert_contains "$(cat "$dir/fake/literal")" "$variable='$dir/primary'" "an absent mate setting must restore the primary's pin"
  done
  pass "fm-control relaunch: mate pins are re-read for Claude and Pi, and unusable pins refuse before stopping the agent"
}

test_pi_exclude_tools_follow_the_relaunch() {
  local dir out rc id=rl-pi-excl
  dir=$(new_case pi-exclude "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' '# hide writes' 'mcp__srv__writeTool' 'mcp__srv__adminTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "keep exclusions"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch with exclusions should succeed"$'\n'"$out"
  assert_contains "$(cat "$dir/fake/literal")" "--exclude-tools 'mcp__srv__writeTool,mcp__srv__adminTool'" \
    "the relaunched Pi worker must keep the home's tool exclusions"
  rm "$dir/home/config/crew-exclude-tools"
  : > "$dir/fake/literal"
  printf pi > "$dir/fake/command"
  out=$(run_control "$dir" "$id" relaunch --note "exclusions removed"); rc=$?
  expect_code 0 "$rc" "a Pi relaunch after the file is removed should succeed"$'\n'"$out"
  assert_not_contains "$(cat "$dir/fake/literal")" "--exclude-tools" \
    "a relaunch without the file must launch with no exclusions"
  pass "fm-control relaunch: a Pi replacement keeps the home's tool exclusions"
}

test_exclude_tools_refusals_happen_before_the_agent_stops() {
  local dir out rc id=rl-excl-refuse
  dir=$(new_case excl-refuse "$id")
  add_ship_task "$dir" "$id" pi
  printf pi > "$dir/fake/command"
  printf pi > "$dir/fake/becomes"
  printf '#!/usr/bin/env bash\nprintf "Options: --tui-mode\\n"\n' > "$dir/fakebin/pi"
  chmod +x "$dir/fakebin/pi"
  mkdir -p "$dir/home/config"
  printf '%s\n' 'two words' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --note "bad list"); rc=$?
  expect_code 1 "$rc" "a malformed exclusion list must refuse the relaunch"
  assert_contains "$out" "config/crew-exclude-tools has a malformed entry" "refusal must name the entry"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "a malformed exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  printf '%s\n' 'mcp__srv__writeTool' > "$dir/home/config/crew-exclude-tools"
  out=$(run_control "$dir" "$id" relaunch --harness codex --note "switch runtime"); rc=$?
  expect_code 1 "$rc" "relaunching onto a runtime that cannot hide tools must refuse"
  assert_contains "$out" "config/crew-exclude-tools" "refusal must name the config file"
  [ "$(cat "$dir/fake/command")" = pi ] || fail "an unhonorable exclusion list stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch sent lifecycle input"
  pass "fm-control relaunch: exclusion-list refusals happen before the running agent stops"
}

# The spawn quota gate runs on an explicit --harness before the old agent stops
# (bin/fm-quota-axi-lib.sh fm_quota_gate_run).
quota_relaunch_case() {  # <name> <id> <grok-state>
  local dir
  dir=$(new_case "$1" "$2")
  add_ship_task "$dir" "$2" claude
  printf '%s\n' '{"rules":[{"when":"fix","use":[{"harness":"grok","model":"grok-4.7"},{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"},{"harness":"pi","model":"glm-5.3","effort":"high","provider":"zai"}]}],"default":{"harness":"claude"}}' \
    > "$dir/home/config/crew-dispatch.json"
  fm_test_quota_snapshot "$dir/quota.json" "$3"
  printf '%s\n' "$dir"
}

test_quota_gate_refuses_an_explicit_relaunch_before_the_agent_stops() {
  local dir out rc id=rl-quota-refuse
  dir=$(quota_relaunch_case quota-refuse "$id" short:7200)
  printf 'grok' > "$dir/fake/becomes"
  out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/quota.json" run_control "$dir" "$id" relaunch --harness grok --model grok-4.7 --note "move to grok"); rc=$?
  expect_code 1 "$rc" "a relaunch onto grok with under three hours of runway must refuse"$'\n'"$out"
  assert_contains "$out" "fm-control refuses explicit harness grok model grok-4.7: provider grok runway at all_products" \
    "the refusal must name the harness, model and runway"
  assert_contains "$out" "Best alternative: provider codex (spendPriority 0.85): --harness codex --model gpt-6.1-sol." \
    "the refusal must name the best-spendPriority alternative"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a quota refusal stopped the running agent"
  [ ! -s "$dir/fake/literal" ] || fail "a quota refusal sent lifecycle input"
  [ "$(meta_field "$dir" "$id" harness)" = claude ] || fail "a quota refusal changed the task record"
  pass "fm-control relaunch: an explicit harness with too little quota refuses before the agent stops and names the best alternative"
}

test_secondmate_quota_relaunch_names_a_supported_alternative() {
  local dir out rc id=rl-quota-secondmate
  dir=$(quota_relaunch_case quota-secondmate "$id" exhausted)
  sed -i.bak 's/^kind=ship$/kind=secondmate/' "$dir/home/state/$id.meta"
  printf '%s\n' '{"default":[{"harness":"agy","provider":"codex"},{"harness":"claude"}]}' \
    > "$dir/home/config/crew-dispatch.json"
  out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/quota.json" run_control "$dir" "$id" relaunch --harness grok); rc=$?
  expect_code 1 "$rc" "an exhausted secondmate relaunch must refuse"$'\n'"$out"
  assert_contains "$out" 'Best alternative: provider claude (spendPriority -0.39): --harness claude.' \
    "secondmate relaunch must skip higher-ranked AGY"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a quota refusal stopped the running secondmate"
  [ ! -s "$dir/fake/literal" ] || fail "a quota refusal sent secondmate lifecycle input"
  [ "$(meta_field "$dir" "$id" harness)" = claude ] || fail "a quota refusal changed the secondmate record"
  pass "secondmate relaunch quota refusals recommend a supported harness before stopping the agent"
}

test_quota_override_relaunches_and_is_recorded() {
  local dir out rc id=rl-quota-override
  dir=$(quota_relaunch_case quota-override "$id" exhausted)
  printf 'grok' > "$dir/fake/becomes"
  out=$(FM_QUOTA_SNAPSHOT_FILE="$dir/quota.json" run_control "$dir" "$id" relaunch --harness grok --model grok-4.7 \
    --quota-override "captain asked for grok" --note "move to grok"); rc=$?
  expect_code 0 "$rc" "an explicit override must relaunch onto the refused harness"$'\n'"$out"
  [ "$(meta_field "$dir" "$id" harness)" = grok ] || fail "the override relaunch should move the record to grok"
  [ "$(meta_field "$dir" "$id" quota_override)" = "captain asked for grok" ] \
    || fail "the override reason must be recorded: $(cat "$dir/home/state/$id.meta")"
  case "$(meta_field "$dir" "$id" quota_override_evidence)" in
    "refuse: provider grok runway exhausted_now at all_products; best alternative: provider codex"*) ;;
    *) fail "the overridden refusal must be recorded: $(cat "$dir/home/state/$id.meta")" ;;
  esac
  out=$(run_control "$dir" "$id" relaunch --note "same runtime again"); rc=$?
  expect_code 0 "$rc" "a relaunch with no explicit harness is not gated"$'\n'"$out"
  [ -z "$(meta_field "$dir" "$id" quota_override)" ] \
    || fail "a later relaunch without the override must not inherit the earlier override"
  pass "fm-control relaunch: --quota-override relaunches a refused harness and records the reason and evidence"
}

test_explicit_model_wins_over_the_recorded_one() {
  local dir out rc
  dir=$(new_case explicit rl7)
  add_ship_task "$dir" rl7 claude
  out=$(run_control "$dir" rl7 relaunch --model sonnet --effort low --note "dialling down"); rc=$?
  expect_code 0 "$rc" "relaunch with explicit axes should succeed"$'\n'"$out"
  [ "$(meta_field "$dir" rl7 model)" = sonnet ] || fail "an explicit model should be recorded"
  [ "$(meta_field "$dir" rl7 effort)" = low ] || fail "an explicit effort should be recorded"
  pass "fm-control relaunch: explicit model and effort win over the recorded ones"
}

test_relaunch_onto_an_unverified_harness_is_refused() {
  local dir out rc
  dir=$(new_case badharness rl8)
  add_ship_task "$dir" rl8 claude
  out=$(run_control "$dir" rl8 relaunch --harness someagent --note "x"); rc=$?
  expect_code 1 "$rc" "an unverified target harness should refuse"
  assert_contains "$out" "not a verified harness" "the refusal should name the unverified adapter"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: refuses to relaunch onto an adapter with no verified mechanics"
}

test_prior_harness_turnend_registry_entry_is_cleared() {
  local dir auth
  dir=$(new_case grokauth rl9)
  add_ship_task "$dir" rl9 grok
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl9.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl9.turn-ended" > "$auth"
  printf 'grok' > "$dir/fake/command"
  printf 'grok' > "$dir/fake/becomes"
  run_control "$dir" rl9 relaunch --note "restart on the same runtime" >/dev/null
  [ ! -e "$auth" ] \
    || fail "the previous incarnation's turn-end registry entry must not outlive it"
  pass "fm-control relaunch: the retired incarnation's global turn-end token is revoked"
}

test_wiring_removal_failure_refuses_before_replacement_arm() {
  local dir hook out rc real_rm
  dir=$(new_case wiring-failure rl29)
  add_ship_task "$dir" rl29 claude
  hook="$dir/wt/.claude/settings.local.json"
  mkdir -p "${hook%/*}"
  printf '{}\n' > "$hook"
  real_rm=$(command -v rm)
  make_rm_failure_stub "$dir"
  out=$(FM_REAL_RM="$real_rm" FM_FAKE_RM_FAIL_PATH="$hook" \
    run_control "$dir" rl29 relaunch --note "retry after wiring cleanup"); rc=$?
  expect_code 1 "$rc" "an undeletable prior hook must fail closed"$'\n'"$out"
  assert_contains "$out" "could not retire claude wiring" \
    "the failure should identify prior wiring cleanup"
  [ -e "$hook" ] || fail "the fixture should retain the undeletable prior hook"
  assert_no_grep "Firstmate operational input waiting: read" "$dir/fake/literal" \
    "replacement launch must not be armed after wiring cleanup fails"
  [ "$(journal_field "$dir" rl29 phase)" = failed:launching ] \
    || fail "the transaction should record the partial launch failure"
  [ "$(journal_field "$dir" rl29 rollback)" = prior-record-kept ] \
    || fail "unpublished rollback should retain the live durable record"
  pass "fm-control relaunch: wiring cleanup failure refuses replacement arming"
}

test_turnend_auth_paths_are_owned_by_the_control_adapter() {
  local dir state grok_path kimi_path token_path
  dir=$(fm_test_tmproot fm-control-auth)
  state="$dir/state"
  mkdir -p "$state"
  printf 'fm.111111111111\n' > "$state/x.grok-turnend-token"
  printf 'fm.222222222222\n' > "$state/x.kimi-turnend-token"
  token_path=$(fm_control_harness_turnend_token_path grok "$state" x)
  [ "$token_path" = "$state/x.grok-turnend-token" ] \
    || fail "the grok token path should be computed without reading it"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok fm.111111111111)
  [ "$grok_path" = "$dir/gh/hooks/fm-turn-end.d/fm.111111111111" ] \
    || fail "grok's registry path should resolve under GROK_HOME, got '$grok_path'"
  kimi_path=$(HOME="$dir/kh" fm_control_harness_turnend_auth_path kimi fm.222222222222)
  [ "$kimi_path" = "$dir/kh/.kimi-code/fm-turn-end.d/fm.222222222222" ] \
    || fail "kimi's registry path should resolve under the home store, got '$kimi_path'"
  grok_path=$(GROK_HOME="$dir/gh" fm_control_harness_turnend_auth_path grok 'not a token/../..')
  [ -z "$grok_path" ] || fail "a malformed token must resolve to no path, got '$grok_path'"
  pass "fm-control-lib: one owner resolves each harness's turn-end registry entry, and refuses a malformed token"
}

test_secondmate_relaunch_picks_up_the_configured_harness_pin() {
  local dir home out rc
  dir=$(new_case smpin sm3)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'codex some-model high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm3"
  printf '# secondmate brief\n' > "$home/data/sm3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm3"
    echo "endpoint_task_id=sm3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm3.meta"
  printf '%s\n' "fm-sm3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm3 relaunch); rc=$?
  expect_code 0 "$rc" "a configured secondmate harness should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm3 to_harness)" = codex ] \
    || fail "a secondmate relaunch should pick up the configured harness pin, got '$(journal_field "$dir" sm3 to_harness)'"
  [ "$(journal_field "$dir" sm3 to_model)" = some-model ] \
    || fail "the configured model token should come with the pin"
  [ "$(journal_field "$dir" sm3 to_effort)" = high ] \
    || fail "the configured effort token should come with the pin"
  assert_not_contains "$out" "not a verified harness" "codex is a verified harness"
  pass "fm-control relaunch: a secondmate relaunch re-resolves its durable configured harness pin"
}

# The relaunch half of the opt-in scope: a pin file that declares no
# "mate <id>:" line is read exactly as it was before that grammar existed, so a
# second default line and a fourth token must not stop the relaunch. The mate
# still lands on the first line's runtime.
test_secondmate_relaunch_with_a_legacy_pin_file_uses_the_first_line() {
  local dir home out rc
  dir=$(new_case smlegacy sml2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml2"
  printf 'codex some-model high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sml2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sml2"
    echo "endpoint_task_id=sml2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml2.meta"
  printf '%s\n' "fm-sml2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml2 relaunch); rc=$?
  expect_code 0 "$rc" "a legacy pin file must not refuse a secondmate relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sml2 to_harness)" = codex ] \
    || fail "the relaunch should take the first line's harness, got '$(journal_field "$dir" sml2 to_harness)'"
  [ "$(journal_field "$dir" sml2 to_model)" = some-model ] \
    || fail "the relaunch should take the first line's model token, got '$(journal_field "$dir" sml2 to_model)'"
  [ "$(journal_field "$dir" sml2 to_effort)" = high ] \
    || fail "the relaunch should take the first line's effort token, got '$(journal_field "$dir" sml2 to_effort)'"
  pass "fm-control relaunch: a legacy secondmate pin file still relaunches the mate onto its first line"
}

test_secondmate_claude_relaunch_keeps_local_settings() {
  local dir home prior settings out rc
  dir=$(new_case smlocal sml)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sml"
  printf 'codex\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sml/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-local-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin" "$dir/smhome/.claude"
  printf 'sml\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  prior='{"permissions":{"allow":["Bash(echo hi)"]}}'
  printf '%s\n' "$prior" > "$dir/smhome/.claude/settings.local.json"
  printf '%s\n' '{"feedbackDrafts":"on"}' > "$home/state/sml.claude-settings.json"
  printf 'gen=retired\n' > "$dir/smhome/.fm-busy-stop"
  {
    echo "window=fmses:fm-sml"
    echo "endpoint_task_id=sml"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sml.meta"
  printf '%s\n' "fm-sml" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sml relaunch); rc=$?
  expect_code 0 "$rc" "a claude secondmate relaunch should retire wiring without touching local settings"$'\n'"$out"
  settings="$dir/smhome/.claude/settings.local.json"
  [ "$(cat "$settings")" = "$prior" ] \
    || fail "relaunch rewrote the mate home's settings.local.json"
  [ ! -e "$home/state/sml.claude-settings.json" ] \
    || fail "relaunch left the retired claude settings file in place"
  [ ! -e "$dir/smhome/.fm-busy-stop" ] \
    || fail "relaunch left the retired Stop pointer in the mate home"
  pass "fm-control relaunch: a claude secondmate keeps settings.local.json and retires the state settings file and the Stop pointer"
}

# The captain's per-mate override line must win at the relaunch decision, so a
# later change to the default pin cannot migrate a mate that has its own runtime
# ruling onto the default. Synthetic mate ids only - no real home's pin values.
test_secondmate_relaunch_lands_on_the_per_mate_pin() {
  local dir home out rc
  dir=$(new_case smpinmate smp1)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp1"
  printf 'codex default-model high\nmate smp1: claude mate-model xhigh\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp1/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp1"
    echo "endpoint_task_id=smp1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp1.meta"
  printf '%s\n' "fm-smp1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'claude' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp1 relaunch); rc=$?
  expect_code 0 "$rc" "a per-mate pin should relaunch that mate onto its own runtime"$'\n'"$out"
  [ "$(journal_field "$dir" smp1 to_harness)" = claude ] \
    || fail "the mate's own override should win over the default pin, got '$(journal_field "$dir" smp1 to_harness)'"
  [ "$(journal_field "$dir" smp1 to_model)" = mate-model ] \
    || fail "the override's model token should be used, got '$(journal_field "$dir" smp1 to_model)'"
  [ "$(journal_field "$dir" smp1 to_effort)" = xhigh ] \
    || fail "the override's effort token should be used, got '$(journal_field "$dir" smp1 to_effort)'"
  pass "fm-control relaunch: a mate with a per-mate override line lands on that override, not the default pin"
}

# A mate with no override line keeps resolving through the default line, so
# adding the override grammar cannot change any other mate's resolution.
test_secondmate_relaunch_uses_the_default_for_an_unpinned_mate() {
  local dir home out rc
  dir=$(new_case smdefault smp2)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp2"
  printf 'codex default-model high\nmate some-other-mate: claude opus max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp2/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp2\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp2"
    echo "endpoint_task_id=smp2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=codex"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp2.meta"
  printf '%s\n' "fm-smp2" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" smp2 relaunch); rc=$?
  expect_code 0 "$rc" "an unpinned mate should relaunch onto the default pin"$'\n'"$out"
  [ "$(journal_field "$dir" smp2 to_harness)" = codex ] \
    || fail "a mate with no override must take the default harness, got '$(journal_field "$dir" smp2 to_harness)'"
  [ "$(journal_field "$dir" smp2 to_model)" = default-model ] \
    || fail "the default model token should be used, got '$(journal_field "$dir" smp2 to_model)'"
  [ "$(journal_field "$dir" smp2 to_effort)" = high ] \
    || fail "the default effort token should be used, got '$(journal_field "$dir" smp2 to_effort)'"
  pass "fm-control relaunch: a mate with no override line still resolves the default pin"
}

# A pin file this home cannot parse must stop the relaunch, because the
# alternative is launching the mate onto whatever it happened to run last time -
# the silent migration the override grammar exists to prevent.
test_secondmate_relaunch_refuses_an_unreadable_configured_pin_before_stop() {
  local dir home out rc
  dir=$(new_case smbadminpin smp3)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/smp3"
  printf 'codex default-model high\nmate smp3: claude mate-model xhigh\nmate smp3: grok other-model max\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/smp3/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'smp3\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-smp3"
    echo "endpoint_task_id=smp3"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/smp3.meta"
  printf '%s\n' "fm-smp3" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" smp3 relaunch); rc=$?
  expect_code 1 "$rc" "an unparseable configured pin must refuse the relaunch"$'\n'"$out"
  assert_contains "$out" "config/secondmate-harness" \
    "the refusal should name the pin file the mate cannot be resolved from"
  assert_contains "$out" "line 3" "the refusal should name the offending line"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused relaunch must not stop or replace the running agent"
  [ "$(meta_field "$dir" smp3 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an unparseable secondmate pin refuses before anything is stopped"
}

test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop() {
  local dir home out rc
  dir=$(new_case invalid-effort sm6)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm6"
  printf 'codex some-model impossible\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm6/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "an invalid configured effort should be ignored before stop"$'\n'"$out"
  assert_contains "$out" "effort token 'impossible'" \
    "relaunch should surface the same warning as a normal secondmate spawn"
  [ "$(journal_field "$dir" sm6 to_effort)" = default ] \
    || fail "invalid configured effort should normalize to default"
  pass "fm-control relaunch: invalid configured effort is ignored before stop"
}

# muse is a verified adapter, but only for crewmates and scouts: it has no
# primary supervision protocol, so bin/fm-spawn.sh refuses it for a secondmate.
# That refusal alone is not enough here, because the launch owner is reached
# only AFTER the running agent has been stopped - a secondmate would be left
# with no agent at all. The control plane asks the same capability question
# before it touches anything, so the refusal lands while the agent is still up.
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop() {
  local dir home out rc
  dir=$(new_case smkind sm7)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm7"
  printf '# secondmate brief\n' > "$home/data/sm7/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm7\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm7"
    echo "endpoint_task_id=sm7"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm7.meta"
  printf '%s\n' "fm-sm7" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm7 relaunch --harness muse); rc=$?
  expect_code 1 "$rc" "a crewmate-only adapter should refuse a secondmate relaunch"
  assert_contains "$out" "not verified to run a secondmate task" \
    "the refusal should name the kind the adapter cannot run"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "the refusal must land before the running agent is stopped"
  [ "$(meta_field "$dir" sm7 harness)" = claude ] \
    || fail "a refused relaunch must leave the durable record on the recorded harness"
  pass "fm-control relaunch: an adapter unverified for this task kind refuses before the agent is stopped"
}

test_explicit_secondmate_harness_ignores_configured_profile_axes() {
  local dir home out rc
  dir=$(new_case smexplicit sm4)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude opus high\n' > "$home/config/secondmate-harness"
  mkdir -p "$home/data/sm4"
  printf '# secondmate brief\n' > "$home/data/sm4/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm4\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  {
    echo "window=fmses:fm-sm4"
    echo "endpoint_task_id=sm4"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=high"
    echo "home=$dir/smhome"
  } > "$home/state/sm4.meta"
  printf '%s\n' "fm-sm4" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  printf 'codex' > "$dir/fake/becomes"
  out=$(run_control "$dir" sm4 relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "an explicit secondmate harness should relaunch"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 model)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured model"
  [ "$(meta_field "$dir" sm4 effort)" = default ] \
    || fail "an explicit secondmate harness must not inherit the configured effort"
  printf 'claude opus high\nmate sm4: claude opus high\nmate sm4: codex other-model max\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore an unreadable configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  # The same explicit profile must succeed whatever the file holds, including a
  # legacy file whose later lines and fourth token the strict rules would have
  # rejected, and a file with no usable line at all.
  printf 'claude opus high extra\ngrok other-model low\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a legacy configured pin"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  printf '# only a comment\n' > "$home/config/secondmate-harness"
  out=$(run_control "$dir" sm4 relaunch --harness codex --model explicit-model --effort xhigh); rc=$?
  expect_code 0 "$rc" "an explicit profile must ignore a configured pin with no usable line"$'\n'"$out"
  [ "$(meta_field "$dir" sm4 harness)" = codex ] \
    || fail "the explicit harness must be published"
  [ "$(meta_field "$dir" sm4 model)" = explicit-model ] \
    || fail "the explicit model must be published"
  [ "$(meta_field "$dir" sm4 effort)" = xhigh ] \
    || fail "the explicit effort must be published"
  pass "fm-control relaunch: explicit secondmate harness resets unnamed profile axes"
}

test_ship_relaunch_ignores_the_crew_harness_config() {
  local dir out
  dir=$(new_case crewcfg rl20)
  add_ship_task "$dir" rl20 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  out=$(run_control "$dir" rl20 relaunch --note "same worker, same runtime")
  assert_contains "$out" "harness=claude from=claude" \
    "a ship relaunch must keep its recorded harness rather than re-reading crew config"
  [ "$(meta_field "$dir" rl20 harness)" = claude ] \
    || fail "a ship relaunch must not silently move onto the configured crew harness"
  pass "fm-control relaunch: a ship task keeps its recorded harness instead of re-reading crew config"
}

test_spawn_relaunch_without_a_harness_reuses_the_recorded_one() {
  local dir out
  dir=$(new_case spawnharness rl21)
  add_ship_task "$dir" rl21 claude
  mkdir -p "$dir/home/config"
  printf 'codex\n' > "$dir/home/config/crew-harness"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl21 --relaunch)
  [ "$(meta_field "$dir" rl21 harness)" = claude ] \
    || fail "fm-spawn --relaunch without --harness must reuse the recorded harness, got '$(meta_field "$dir" rl21 harness)'"
  assert_contains "$out" "spawned rl21 harness=claude" "the launch should report the recorded harness"
  pass "fm-spawn --relaunch: with no explicit harness it reuses the task's recorded one, never the crew default"
}

# A promoted scout records kind=ship and a custom ship branch in its meta, but
# its brief is the scout scaffold: it never gained a Ship branch line, and a
# relaunch cannot regenerate the brief (--branch-prefix is refused there). The
# recorded branch is authoritative, so the relaunch must proceed on it.
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch() {
  local dir out
  dir=$(new_case promotebranch rl42)
  add_ship_task "$dir" rl42 claude
  printf 'branch=fix/rl42\n' >> "$dir/home/state/rl42.meta"
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl42 --relaunch)
  assert_contains "$out" "spawned rl42" "the relaunch should complete on the recorded branch"
  assert_contains "$out" "records no ship branch" "the brief gap should be reported, not silent"
  assert_contains "$out" "recorded branch fix/rl42" "the relaunch should name the branch it adopted"
  [ "$(meta_field "$dir" rl42 branch)" = "fix/rl42" ] \
    || fail "the recorded branch must survive the relaunch"
  pass "fm-spawn --relaunch: a promoted scout with a recorded custom branch relaunches on it instead of being refused"
}

test_promoted_scout_relaunch_receives_the_current_delivery_contract() {
  local dir home id brief launch out mode rule
  for mode in no-mistakes direct-PR local-only; do
    id="rl-promoted-${mode}"
    dir=$(new_case "promoted-scout-$mode" "$id")
    home="$dir/home"
    fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
    FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null \
      || fail "$mode: could not scaffold the scout brief"
    brief="$home/data/$id/brief.md"
    sed 's/{TASK}/Fix the promotion relaunch contract./; s/{FIRSTMATE_SPEC}/Preserve the current delivery mode./' \
      "$brief" > "$brief.filled"
    mv "$brief.filled" "$brief"
    {
      echo "window=fmses:fm-$id"
      echo "endpoint_task_id=$id"
      echo "worktree=$dir/wt"
      echo "project=$dir/proj"
      echo "harness=claude"
      echo "kind=scout"
      echo "tasktmp=/tmp/fm-$id"
      echo "model=default"
      echo "effort=default"
    } > "$home/state/$id.meta"
    printf '%s\n' "fm-$id" > "$dir/fake/windows"
    printf '%s' "$dir/wt" > "$dir/fake/cwd"

    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
      "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: scout promotion should succeed: $out"
    assert_grep 'This is a SCOUT task' "$brief" \
      "$mode: the reproduction fixture lost the original scout delivery text"
    assert_grep 'Never push to any remote and never open a PR' "$brief" \
      "$mode: the reproduction fixture lost the stale scout prohibition"

    printf 'zsh' > "$dir/fake/command"
    out=$(run_spawn "$dir" "$id" --relaunch) \
      || fail "$mode: promoted scout relaunch should succeed: $out"
    launch="$home/data/$id/launch-brief.md"
    assert_grep "This task is now kind=ship with mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the promoted task identity"
    assert_grep 'Any earlier "Never push" or scout-only delivery language in this file is superseded' "$launch" \
      "$mode: the replacement launch left the stale scout prohibition readable at face value"
    case "$mode" in
      direct-PR)
        rule="1. Never push to the default branch (push only your \`fm/$id\` branch). Never merge a PR." ;;
      local-only)
        rule="1. Never push to any remote and never open a PR. Work only on your \`fm/$id\` branch; firstmate handles the merge into local \`main\`." ;;
      *)
        rule='1. Never push to the default branch. Never merge a PR.' ;;
    esac
    assert_grep "$rule" "$launch" \
      "$mode: the replacement launch did not receive the current ship push and merge safety rule"
    assert_grep "git checkout -b fm/$id" "$launch" \
      "$mode: the replacement launch did not receive its promoted branch name"
    assert_grep 'Inventory this worktree' "$launch" \
      "$mode: the replacement launch did not receive the scratch-state inventory step"
    assert_grep 'Carry over only the intended fix changes' "$launch" \
      "$mode: the replacement launch did not receive the carry-over boundary"
    assert_grep "Delivery contract: mode=$mode" "$launch" \
      "$mode: the replacement launch did not receive the actual ship delivery mode"
  done
  pass "fm-promote/fm-spawn --relaunch: the current ship contract supersedes stale scout delivery text"
}

# A scout its lane release stopped (an active marker, bin/fm-lane-release-lib.sh)
# can still be promoted: fm-promote never checks liveness, and the relaunch into
# the kept copy carries the ship contract and mints a new spawn_gen, which makes
# the marker inactive.
test_released_scout_promotes_and_relaunches_into_its_kept_copy() {
  local dir home id brief out launch
  id=rl-released-scout
  dir=$(new_case released-scout "$id")
  home="$dir/home"
  fm_git_worktree "$dir/proj" "$dir/wt" "task-$id"
  printf 'kept scratch\n' > "$dir/wt/scratch.txt"
  FM_HOME="$home" "$BRIEF" "$id" firstmate --scout >/dev/null || fail "could not scaffold the scout brief"
  brief="$home/data/$id/brief.md"
  sed 's/{TASK}/Investigate the thing./; s/{FIRSTMATE_SPEC}/Report findings./' "$brief" > "$brief.filled"
  mv "$brief.filled" "$brief"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$dir/wt"
    echo "project=$dir/proj"
    echo "harness=claude"
    echo "kind=scout"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s1000.1.1"
  } > "$home/state/$id.meta"
  printf 'fm-lane-release-v1\ntask=%s\nspawn_gen=s1000.1.1\nreleased_at=2000\nanchor=1900\nclass=scout\nresult=released\n' \
    "$id" > "$home/state/$id.released"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$dir/wt" > "$dir/fake/cwd"
  printf 'zsh' > "$dir/fake/command"
  out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1) \
    || fail "a released scout should still promote: $out"
  out=$(run_spawn "$dir" "$id" --relaunch) || fail "the promoted released scout should relaunch: $out"
  launch="$home/data/$id/launch-brief.md"
  assert_grep "This task is now kind=ship with mode=direct-PR" "$launch" \
    "the relaunch did not carry the promoted ship contract"
  [ -f "$dir/wt/scratch.txt" ] || fail "the kept copy lost its files"
  ! grep -qx 'spawn_gen=s1000.1.1' "$home/state/$id.meta" \
    || fail "the relaunch did not mint a new spawn_gen"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-lane-release-lib.sh"
    ! fm_lane_release_marker_active "$home/state" "$id"
  ) || fail "the release marker is still active after the relaunch"
  pass "fm-promote/fm-spawn --relaunch: a released scout promotes and relaunches into its kept copy, clearing the marker"
}

# fm-spawn arms per-task wiring on harness PREFIXES, because a task launched
# from a raw command records that command's basename rather than the exact
# adapter name. Retirement must resolve the same way, or a task recorded as
# `grok-2` would have its turn-end token and hook pointer armed and never
# retired - leaving a registry entry that outlives the agent that owned it.
test_prefixed_prior_harness_wiring_is_still_retired() {
  local dir auth
  dir=$(new_case prefixwiring rl30)
  add_ship_task "$dir" rl30 grok-2
  mkdir -p "$dir/grokhome/hooks/fm-turn-end.d"
  printf 'fm.abcdefabcdef\n' > "$dir/home/state/rl30.grok-turnend-token"
  auth="$dir/grokhome/hooks/fm-turn-end.d/fm.abcdefabcdef"
  printf '%s\n' "$dir/home/state/rl30.turn-ended" > "$auth"
  printf 'token=fm.abcdefabcdef\n' > "$dir/wt/.fm-grok-turnend"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl30 --relaunch --harness claude >/dev/null
  [ ! -e "$auth" ] \
    || fail "a prefixed prior harness must still have its turn-end registry entry revoked"
  [ ! -e "$dir/home/state/rl30.grok-turnend-token" ] \
    || fail "a prefixed prior harness must still have its private token retired"
  [ ! -e "$dir/wt/.fm-grok-turnend" ] \
    || fail "a prefixed prior harness must still have its worktree hook pointer removed"
  pass "fm-spawn --relaunch: wiring armed under a prefixed harness name is still retired"
}

# muse installs no hook; its busy source is its own session event log, bound to
# the pane by two firstmate-owned sidecars. Relaunching AWAY from muse must
# retire that binding, or a retired incarnation's session pin outlives the agent
# that produced it.
test_muse_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case musewiring rl31)
  add_ship_task "$dir" rl31 muse
  printf 'sessions_root=/nonexistent\nworkspace_root=%s\nbinding_id=1.2.3\n' "$dir/wt" \
    > "$dir/home/state/rl31.muse-session"
  printf '/nonexistent/session.jsonl\n' > "$dir/home/state/rl31.muse-session-current"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl31 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl31.muse-session" ] \
    || fail "the retired muse incarnation's session binding must not outlive it"
  [ ! -e "$dir/home/state/rl31.muse-session-current" ] \
    || fail "the retired muse incarnation's resolved session pin must not outlive it"
  pass "fm-spawn --relaunch: switching away from muse retires its session binding"
}

test_cursor_session_binding_is_retired_on_a_harness_switch() {
  local dir
  dir=$(new_case cursorwiring rl35)
  add_ship_task "$dir" rl35 cursor
  printf 'workspace=%s\nprior_conversation=old-conversation\n' "$dir/wt" \
    > "$dir/home/state/rl35.cursor-session"
  printf 'zsh' > "$dir/fake/command"
  run_spawn "$dir" rl35 --relaunch --harness claude >/dev/null
  [ ! -e "$dir/home/state/rl35.cursor-session" ] \
    || fail "the retired cursor incarnation's session binding must not outlive it"
  pass "fm-spawn --relaunch: switching away from cursor retires its session binding"
}

# --- 3 and 4. refusals before the agent is touched ---------------------------

test_missing_worktree_refuses_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nowt rl10)
  add_ship_task "$dir" rl10 claude
  rm -rf "$dir/wt"
  out=$(run_control "$dir" rl10 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "a missing worktree should refuse"
  assert_contains "$out" "recorded worktree" "the refusal should name the missing local copy"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "a refused relaunch must send nothing"
  pass "fm-control relaunch: an unaccountable local copy refuses before the agent is touched"
}

test_missing_instructions_refuse_before_stopping_anything() {
  local dir out rc
  dir=$(new_case nobrief rl11)
  add_ship_task "$dir" rl11 claude
  rm -f "$dir/home/data/rl11/brief.md"
  out=$(run_control "$dir" rl11 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "missing instructions should refuse"
  assert_contains "$out" "no instructions" "the refusal should name the missing instructions"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a worker with nothing to work from is never launched"
}

test_checkpoint_refusal_leaves_the_record_byte_identical() {
  local dir before after
  dir=$(new_case bytes rl12)
  add_ship_task "$dir" rl12 claude
  before=$(cat "$dir/home/state/rl12.meta")
  rm -rf "$dir/wt/.git"
  run_control "$dir" rl12 relaunch --note "x" >/dev/null 2>&1
  after=$(cat "$dir/home/state/rl12.meta")
  [ "$before" = "$after" ] || fail "a refused relaunch must leave the durable record byte-identical"
  pass "fm-control relaunch: a refusal before the agent is stopped leaves the durable record untouched"
}

test_checkpoint_refuses_uninspectable_head_and_status() {
  local dir out rc real_git
  real_git=$(command -v git)

  dir=$(new_case badhead rl22)
  add_ship_task "$dir" rl22 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=head \
    run_control "$dir" rl22 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable HEAD should refuse"
  assert_contains "$out" "HEAD cannot be inspected" "the refusal should name the failed HEAD proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "HEAD inspection failure must not stop the agent"

  dir=$(new_case badstatus rl23)
  add_ship_task "$dir" rl23 claude
  make_git_failure_stub "$dir"
  out=$(FM_REAL_GIT="$real_git" FM_FAKE_GIT_FAILURE=status \
    run_control "$dir" rl23 relaunch --note "x"); rc=$?
  expect_code 1 "$rc" "an uninspectable worktree status should refuse"
  assert_contains "$out" "status cannot be inspected" "the refusal should name the failed dirty-state proof"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "status inspection failure must not stop the agent"
  pass "fm-control relaunch: checkpoint inspection failures refuse before stopping"
}

# --- 5. failure after the agent is stopped -----------------------------------

test_launch_failure_keeps_the_prior_record_and_reports_it() {
  local dir out rc before
  dir=$(new_case rollback rl13)
  add_ship_task "$dir" rl13 claude
  before=$(cat "$dir/home/state/rl13.meta")
  # The endpoint's shell is not in the recorded worktree, so the launch owner
  # refuses AFTER the previous agent has already been stopped.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_control "$dir" rl13 relaunch --harness codex --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch should fail closed"$'\n'"$out"
  assert_contains "$out" "no agent is running" "the failure should say no agent is running"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(cat "$dir/home/state/rl13.meta")" = "$before" ] \
    || fail "a failed launch must keep the prior durable record"
  [ "$(journal_field "$dir" rl13 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase, got '$(journal_field "$dir" rl13 phase)'"
  [ "$(journal_field "$dir" rl13 rollback)" = "prior-record-kept" ] \
    || fail "the journal should record what the rollback did"
  assert_grep "carry this forward" "$dir/home/data/rl13/brief.md" \
    "the progress note must survive so a later recovery still has it"
  pass "fm-control relaunch: a launch failure after the stop keeps the prior record and reports the real state"
}

# shellcheck disable=SC2031 # PATH intentionally retains the parent environment between cases.
test_prepublication_failure_keeps_concurrent_durable_metadata() {
  local dir control_pid link_out rc i=0
  dir=$(new_case rollback-race rl30)
  add_ship_task "$dir" rl30 claude
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  FM_FAKE_CWD_RACE_READY="$dir/cwd-race-ready" \
    run_control "$dir" rl30 relaunch --harness codex --note "preserve concurrent metadata" \
      > "$dir/control.out" &
  control_pid=$!
  while [ ! -e "$dir/cwd-race-ready" ] && [ "$i" -lt 200 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  [ -e "$dir/cwd-race-ready" ] || {
    kill "$control_pid" 2>/dev/null || true
    wait "$control_pid" 2>/dev/null || true
    fail "relaunch did not reach its pre-publication endpoint check"
  }
  link_out=$(env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" \
    "$X_LINK" rl30 request-30 --carry-count 2 --carry-ts 1700000000 \
      --carry-platform x --carry-max 280 2>&1); rc=$?
  expect_code 0 "$rc" "concurrent durable metadata publication should succeed"$'\n'"$link_out"
  wait "$control_pid"; rc=$?
  expect_code 1 "$rc" "the staged pre-publication launch failure should fail closed"
  [ "$(meta_field "$dir" rl30 x_request)" = request-30 ] \
    || fail "rollback erased the concurrent X request"
  [ "$(meta_field "$dir" rl30 x_followups)" = 2 ] \
    || fail "rollback erased the concurrent follow-up count"
  [ "$(journal_field "$dir" rl30 rollback)" = prior-record-kept ] \
    || fail "pre-publication rollback should leave the live record untouched"
  pass "fm-control relaunch: unpublished rollback keeps concurrent durable metadata"
}

test_post_publication_launch_failure_keeps_the_new_record() {
  local dir out rc
  dir=$(new_case published rl24)
  add_ship_task "$dir" rl24 claude
  printf 'codex' > "$dir/fake/becomes"
  out=$(FM_FAKE_LAUNCH_TRANSPORT_FAIL_AFTER_START=1 \
    run_control "$dir" rl24 relaunch --harness codex --note "keep the published record"); rc=$?
  expect_code 1 "$rc" "a post-publication launch failure should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl24 harness)" = codex ] \
    || fail "a published replacement record must not be rewritten to the prior harness"
  [ -n "$(meta_field "$dir" rl24 control_relaunch_tx)" ] \
    || fail "the published replacement record should identify its relaunch transaction"
  [ "$(journal_field "$dir" rl24 rollback)" = none-new-record-kept ] \
    || fail "the journal should record that the published replacement record was kept"
  pass "fm-control relaunch: post-publication failure keeps the new durable record"
}

test_stop_transport_failure_reconciles_a_dead_agent() {
  local dir out rc
  dir=$(new_case stopfail rl25)
  add_ship_task "$dir" rl25 claude
  out=$(FM_FAKE_EXIT_TRANSPORT_FAIL_AFTER_STOP=1 \
    run_control "$dir" rl25 relaunch --note "preserve this after stop"); rc=$?
  expect_code 1 "$rc" "a stop transport failure should fail closed"$'\n'"$out"
  [ "$(cat "$dir/fake/command")" = zsh ] || fail "the fixture should stop the old agent before reporting transport failure"
  [ "$(journal_field "$dir" rl25 phase)" = failed:stopping ] \
    || fail "the journal should retain the pre-stop phase on a partial stop"
  [ "$(journal_field "$dir" rl25 rollback)" = prior-record-kept-agent-dead ] \
    || fail "rollback should reconcile the observed dead agent"
  assert_contains "$out" "no agent is running" "the failure should report the reconciled dead state"
  assert_grep "preserve this after stop" "$dir/home/data/rl25/brief.md" \
    "the progress note should survive once the old agent has stopped"
  pass "fm-control relaunch: partial stop reconciles actual agent state"
}

test_complete_journal_failure_rolls_back_from_durable_phase() {
  local dir out rc real_mv
  dir=$(new_case completejournal rl27)
  add_ship_task "$dir" rl27 claude
  printf 'codex' > "$dir/fake/becomes"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_COMPLETE_JOURNAL_MV_FAIL=1 \
    run_control "$dir" rl27 relaunch --harness codex --note "keep durable phase honest"); rc=$?
  expect_code 1 "$rc" "a failed complete journal replacement should fail closed"$'\n'"$out"
  [ "$(journal_field "$dir" rl27 phase)" = failed:launching ] \
    || fail "rollback should start from the last durable launching phase"
  [ "$(journal_field "$dir" rl27 rollback)" = none-new-agent-confirmed ] \
    || fail "rollback should retain the confirmed-running replacement"
  [ "$(meta_field "$dir" rl27 harness)" = codex ] \
    || fail "journal failure must not rewrite the published replacement record"
  assert_contains "$out" "replacement is running" \
    "journal failure should report the confirmed-running replacement"
  assert_not_contains "$out" "no running agent could be confirmed" \
    "journal failure should not contradict the confirmed agent state"
  pass "fm-control relaunch: failed journal replacement preserves durable phase"
}

test_prepublication_abort_retires_replacement_wiring_and_busy_state() {
  local dir out rc real_mv meta
  dir=$(new_case prepublishcleanup rl28)
  add_ship_task "$dir" rl28 claude
  meta="$dir/home/state/rl28.meta"
  real_mv=$(command -v mv)
  make_mv_failure_stub "$dir"
  out=$(FM_REAL_MV="$real_mv" FM_FAKE_META_PUBLISH_MV_FAIL="$meta" \
    run_control "$dir" rl28 relaunch --note "clean partial replacement state"); rc=$?
  expect_code 1 "$rc" "a failed metadata publication should fail closed"$'\n'"$out"
  [ "$(meta_field "$dir" rl28 harness)" = claude ] \
    || fail "a failed publication should retain the prior durable record"
  [ ! -e "$dir/wt/.claude/settings.local.json" ] \
    || fail "an aborted replacement should remove its harness wiring"
  [ ! -e "$dir/home/state/rl28.busy-gen" ] \
    || fail "an aborted replacement should retire its busy generation"
  [ ! -e "$dir/home/state/rl28.busy-state" ] \
    || fail "an aborted replacement should remove its seeded busy record"
  [ "$(journal_field "$dir" rl28 rollback)" = prior-record-kept ] \
    || fail "the journal should record the unpublished replacement rollback"
  pass "fm-spawn relaunch: prepublication abort removes replacement state"
}

test_journal_records_the_checkpoint_it_proved() {
  local dir head
  dir=$(new_case journal rl14)
  add_ship_task "$dir" rl14 claude
  printf 'scratch\n' > "$dir/wt/uncommitted.txt"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  run_control "$dir" rl14 relaunch --note "keeping the scratch file" >/dev/null
  [ "$(journal_field "$dir" rl14 worktree_head)" = "$head" ] \
    || fail "the checkpoint should record the head it preserved"
  [ "$(journal_field "$dir" rl14 worktree_dirty)" = yes ] \
    || fail "the checkpoint should record that uncommitted work was present"
  [ -f "$dir/wt/uncommitted.txt" ] || fail "uncommitted work must survive a relaunch"
  pass "fm-control relaunch: the checkpoint records the exact unlanded work it preserved"
}

# --- secondmate child-work safety -------------------------------------------

test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter() {
  local dir home out rc
  dir=$(new_case sm sm1)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm1\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  {
    echo "window=fmses:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf '%s\n' "fm-sm1" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  # No --note: a secondmate reconciles its own home's records at startup, so
  # the note is optional there.
  out=$(run_control "$dir" sm1 relaunch); rc=$?
  expect_code 0 "$rc" "a checkpointed secondmate should relaunch"$'\n'"$out"
  [ "$(journal_field "$dir" sm1 children)" = 2 ] \
    || fail "the checkpoint must account for the secondmate's child work, got '$(journal_field "$dir" sm1 children)'"
  assert_not_contains "$out" "requires --note" "a secondmate relaunch must not demand a progress note"
  [ "$(cat "$dir/smhome/data/charter.md")" = "# charter" ] \
    || fail "a secondmate's standing charter must never be rewritten by a relaunch"
  assert_present "$dir/smhome/state/c1.meta" "child records must survive the relaunch"
  assert_present "$dir/smhome/state/c2.meta" "child records must survive the relaunch"
  pass "fm-control relaunch: a secondmate's child work is accounted for and its charter is left alone"
}

test_secondmate_relaunch_refuses_an_unmarked_home() {
  local dir home out rc
  dir=$(new_case smbad sm2)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state"
  printf 'someone-else\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm2"
    echo "endpoint_task_id=sm2"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
  } > "$home/state/sm2.meta"
  printf '%s\n' "fm-sm2" > "$dir/fake/windows"
  out=$(run_control "$dir" sm2 relaunch); rc=$?
  expect_code 1 "$rc" "a home marked for another secondmate should refuse"
  assert_contains "$out" "not marked as its own seeded secondmate home" \
    "the refusal should name the identity mismatch"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "a refused relaunch must not stop the agent"
  pass "fm-control relaunch: a secondmate home that is not this secondmate's is refused"
}

test_secondmate_checkpoint_refuses_unreadable_child_state() {
  local dir home out rc
  dir=$(new_case smchildren sm5)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state/bad.meta"
  printf 'sm5\n' > "$dir/smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm5"
    echo "endpoint_task_id=sm5"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "home=$dir/smhome"
  } > "$home/state/sm5.meta"
  printf '%s\n' "fm-sm5" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  expect_code 1 "$rc" "a non-readable child record should refuse"
  assert_contains "$out" "not a readable regular file" "the refusal should name the unreadable child record"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "child record failure must not stop the secondmate"
  pass "fm-control relaunch: unreadable child records fail checkpoint"
  if [ "$(id -u)" = 0 ]; then
    pass "fm-control relaunch: unlistable state check skipped as root (mode 000 does not restrict root)"
    return 0
  fi
  rmdir "$dir/smhome/state/bad.meta"
  printf 'window=x:c1\n' > "$dir/smhome/state/c1.meta"
  chmod 000 "$dir/smhome/state"
  out=$(run_control "$dir" sm5 relaunch); rc=$?
  chmod 755 "$dir/smhome/state"
  expect_code 1 "$rc" "an unlistable state directory should refuse"
  assert_contains "$out" "no readable state directory" \
    "the refusal should name the unlistable home state directory"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "unlistable child state must not stop the secondmate"
  pass "fm-control relaunch: unlistable state fails checkpoint"
}

test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk() {
  local dir home out rc real_find
  dir=$(new_case smfindrace sm6)
  home="$dir/home"
  mkdir -p "$home/config"
  printf 'claude\n' > "$home/config/secondmate-harness"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm6\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# charter\n' > "$dir/smhome/data/charter.md"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  printf 'window=x:fm-c1\n' > "$dir/smhome/state/c1.meta"
  printf 'window=x:fm-c2\n' > "$dir/smhome/state/c2.meta"
  : > "$dir/smhome/state/.hash-0"
  : > "$dir/smhome/state/.count-0"
  : > "$dir/smhome/state/.last-0"
  {
    echo "window=fmses:fm-sm6"
    echo "endpoint_task_id=sm6"
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "home=$dir/smhome"
    echo "projects="
  } > "$home/state/sm6.meta"
  printf '%s\n' "fm-sm6" > "$dir/fake/windows"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  real_find=$(command -v find)
  cat > "$dir/fakebin/find" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "$dir/smhome/state" ]; then
    echo "find: \$arg/.hash-0: No such file or directory" >&2
    exit 1
  fi
done
exec "$real_find" "\$@"
SH
  chmod +x "$dir/fakebin/find"
  out=$(run_control "$dir" sm6 relaunch); rc=$?
  expect_code 0 "$rc" "a vanished watcher scratch file must not refuse relaunch"$'\n'"$out"
  assert_contains "$out" "relaunched sm6" "readable child metas must still allow the replacement launch"
  [ "$(journal_field "$dir" sm6 children)" = 2 ] \
    || fail "readable child metas must still be counted, got '$(journal_field "$dir" sm6 children)'"
  pass "fm-control relaunch: a vanished watcher scratch file does not fail the child-record checkpoint"
}

test_concurrent_relaunch_is_refused() {
  local dir out rc lock holder i
  dir=$(new_case lock rl19)
  add_ship_task "$dir" rl19 claude
  lock="$dir/home/state/.control-rl19.lock"
  # A live holder of this task's control lock, taken through the same lock
  # library fm-control uses.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  i=0
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || { kill "$holder" 2>/dev/null; fail "could not stage a held control lock"; }
  printf 'held\n' > "$dir/home/state/rl19.composer-dialog"
  out=$(run_control "$dir" rl19 relaunch --note "concurrent"); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "a second concurrent control action should refuse"
  assert_contains "$out" "another lifecycle action is already running" \
    "the refusal should name the concurrent action"
  [ "$(cat "$dir/fake/command")" = claude ] \
    || fail "a refused concurrent relaunch must not stop the agent"
  [ "$(cat "$dir/home/state/rl19.composer-dialog" 2>/dev/null)" = held ] \
    || fail "a refused concurrent relaunch must not remove the lock holder's dialog file"
  pass "fm-control relaunch: two control actions on one task serialize instead of interleaving"
}

# shellcheck disable=SC2031
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock() {
  local dir out rc lock holder i=0
  dir=$(new_case spawnlock rl26)
  add_ship_task "$dir" rl26 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.control-rl26.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the lifecycle lock"
  out=$(run_spawn "$dir" rl26 --relaunch --harness claude); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "direct relaunch spawn should refuse a held lifecycle lock"
  assert_contains "$out" "another lifecycle action is already running" \
    "direct relaunch spawn should name lifecycle contention"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "contended direct relaunch spawn must deliver no launch bytes"
  pass "fm-spawn relaunch: direct entry participates in lifecycle serialization"
}

# shellcheck disable=SC2031
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution() {
  local dir out rc lock holder i=0
  dir=$(new_case promotelock rl29)
  add_ship_task "$dir" rl29 claude
  lock="$dir/home/state/.control-rl29.lock"
  (
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    sleep 30
  ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "could not stage the promotion lifecycle lock"
  out=$(FM_HOME="$dir/home" "$PROMOTE" rl29 --mode direct-PR --yolo on 2>&1); rc=$?
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  expect_code 1 "$rc" "promotion should refuse a concurrent lifecycle action"
  assert_contains "$out" "another lifecycle action is already running" \
    "promotion should lock before interpreting the task metadata"
  [ "$(meta_field "$dir" rl29 kind)" = ship ] \
    || fail "a contended promotion must leave task metadata unchanged"
  pass "fm-promote: promotion participates in lifecycle serialization"
}

# --- 6. fm-spawn --relaunch's own refusals -----------------------------------

test_spawn_relaunch_refuses_a_live_agent() {
  local dir out rc
  dir=$(new_case live rl15)
  add_ship_task "$dir" rl15 claude
  out=$(run_spawn "$dir" rl15 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching into a live endpoint should refuse"
  assert_contains "$out" "positively agent-free endpoint" "the refusal should demand an agent-free endpoint"
  assert_contains "$out" "fm-control.sh rl15 exit" "the refusal should point at the way to stop it"
  pass "fm-spawn --relaunch: refuses to launch a second agent into a live endpoint"
}

test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection() {
  local dir meta target out rc
  dir=$(new_case symlink-meta rl37)
  add_ship_task "$dir" rl37 claude
  meta="$dir/home/state/rl37.meta"
  target="$dir/foreign-task-record"
  mv "$meta" "$target"
  ln -s "$target" "$meta"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
: > "$dir/relaunch-endpoint-inspected"
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  fm_test_codex_first_turn_wrap "$dir/fakebin"

  out=$(run_spawn "$dir" rl37 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching from symlinked metadata should refuse"
  assert_contains "$out" "task record resolves outside its authorized directory" \
    "relaunch did not identify the unsafe task record"
  [ -L "$meta" ] || fail "relaunch replaced or removed the symlinked record"
  assert_present "$target" "relaunch removed the foreign record target"
  assert_absent "$dir/relaunch-endpoint-inspected" \
    "relaunch inspected or acted on an endpoint from unsafe metadata"
  pass "fm-spawn --relaunch: symlinked records refuse before inspection"
}

test_spawn_relaunch_keeps_its_early_meta_lock_continuous() {
  local dir lock out rc
  dir=$(new_case continuous-meta-lock rl38)
  add_ship_task "$dir" rl38 claude
  printf 'zsh' > "$dir/fake/command"
  lock="$dir/home/state/.meta-rl38.lock"
  mv "$dir/fakebin/tmux" "$dir/fakebin/tmux-real"
  cat > "$dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
if [ -d "$lock" ]; then
  if [ ! -e "$dir/lock-observation-started" ]; then
    : > "$dir/lock-observation-started"
    : > "$lock/continuity-sentinel"
  elif [ ! -e "$lock/continuity-sentinel" ]; then
    : > "$dir/meta-lock-was-recreated"
  fi
fi
exec "$dir/fakebin/tmux-real" "\$@"
SH
  chmod +x "$dir/fakebin/tmux"
  fm_test_codex_first_turn_wrap "$dir/fakebin"

  out=$(run_spawn "$dir" rl38 --relaunch --harness claude); rc=$?
  expect_code 0 "$rc" "relaunch with one continuous meta lock should succeed"$'\n'"$out"
  assert_present "$dir/lock-observation-started" \
    "test did not observe the relaunch-held meta lock"
  assert_absent "$dir/meta-lock-was-recreated" \
    "relaunch released or recreated its already-held meta lock"
  pass "fm-spawn --relaunch: keeps its early meta lock continuous"
}

test_spawn_relaunch_refuses_a_pending_authoritative_close() {
  local dir meta marker out rc
  dir=$(new_case pending-close rl36)
  add_ship_task "$dir" rl36 claude
  meta="$dir/home/state/rl36.meta"
  printf 'spawn_gen=spawn-pending\n' >> "$meta"
  cp "$meta" "$dir/meta.before"
  mkdir -p "$dir/wt/.claude"
  printf 'prior wiring\n' > "$dir/wt/.claude/settings.local.json"
  marker="$dir/home/state/rl36.backlog-close"
  printf 'id=rl36\ndata=%s\nspawn_gen=spawn-pending\narg=--note\narg=local%%20main\n' \
    "$dir/home/data" > "$marker"
  printf 'zsh' > "$dir/fake/command"

  out=$(run_spawn "$dir" rl36 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunching over a pending close should refuse"
  assert_contains "$out" "pending authoritative backlog close" \
    "the refusal should identify the close that still owns the task"
  cmp -s "$dir/meta.before" "$meta" \
    || fail "pending-close refusal replaced the task incarnation"
  assert_grep 'prior wiring' "$dir/wt/.claude/settings.local.json" \
    "pending-close refusal cleared the prior worker wiring"
  assert_present "$marker" "pending-close refusal discarded the authoritative close"
  pass "fm-spawn --relaunch: pending closes refuse before replacement begins"
}

test_spawn_relaunch_refuses_contradicting_flags() {
  local dir out rc
  dir=$(new_case flags rl16)
  add_ship_task "$dir" rl16 claude
  printf 'zsh' > "$dir/fake/command"
  out=$(run_spawn "$dir" rl16 --relaunch --backend herdr); rc=$?
  expect_code 1 "$rc" "--backend should be refused alongside --relaunch"
  assert_contains "$out" "recorded backend" "the refusal should name the recorded backend rule"
  out=$(run_spawn "$dir" rl16 --relaunch --scout); rc=$?
  expect_code 1 "$rc" "--scout should be refused alongside --relaunch"
  assert_contains "$out" "recorded kind" "the refusal should name the recorded kind rule"
  out=$(run_spawn "$dir" rl16 "$dir/proj" --relaunch); rc=$?
  expect_code 1 "$rc" "a project positional should be refused alongside --relaunch"
  assert_contains "$out" "takes the task id only" "the refusal should name the positional rule"
  pass "fm-spawn --relaunch: every identity axis comes from the record, and a contradicting flag refuses"
}

test_spawn_relaunch_refuses_an_unrecorded_task() {
  local dir out rc
  dir=$(new_case norecord rl17)
  add_ship_task "$dir" rl17 claude
  out=$(run_spawn "$dir" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" "an unrecorded task should refuse"
  assert_contains "$out" "needs an existing task record" "the refusal should name the missing record"
  pass "fm-spawn --relaunch: an unrecorded task is refused"
}

test_spawn_relaunch_refuses_a_pane_outside_the_worktree() {
  local dir out rc
  dir=$(new_case wrongcwd rl18)
  add_ship_task "$dir" rl18 claude
  printf 'zsh' > "$dir/fake/command"
  printf '%s' "$dir/proj" > "$dir/fake/cwd"
  out=$(run_spawn "$dir" rl18 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a pane outside the worktree should refuse"
  assert_contains "$out" "not its recorded worktree" "the refusal should name the wrong location"
  [ ! -s "$dir/fake/keys" ] || fail "a refused tmux relaunch must send nothing to the pane"
  pass "fm-spawn --relaunch: refuses to start a replacement outside the copy holding its work"
}

# --- 7. reclaiming a task whose endpoint is gone ----------------------------
#
# Before this, `missing` was a terminal state: fm-spawn --relaunch accepted only
# `dead` and told the caller to stop the agent first, while fm-control exit
# refused `missing` outright and told the caller to reconcile the task first -
# and there is no reconcile verb. Each command named the other as its
# prerequisite, so a task whose pane or workspace was destroyed could not be
# reclaimed by anything, and any no-mistakes approval it was parked on had no
# seat left to answer it.

# strand_endpoint <case-dir> <id>: make a tmux endpoint read `missing` the way
# a destroyed window does - a successful session inventory that omits the exact
# window.
strand_endpoint() {  # <case-dir> <id>
  : > "$1/fake/windows"
}

# Every tmux `missing` refuses on BOTH verbs, whatever produced it. tmux is the
# one verified backend whose absence cannot be proven from a task record: the
# record carries no socket identity for the endpoint, and any inventory
# describes only the server this process happens to address. So a window that
# is merely on a server this seat cannot reach is indistinguishable from one
# that was destroyed, and neither verb will guess.
assert_tmux_missing_refuses() {  # <case-dir> <id> <what-was-staged>
  local dir=$1 id=$2 what=$3 out rc brief_before

  out=$(run_spawn "$dir" "$id" --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "relaunch must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_absent "$dir/fake/created-windows" "a refused relaunch must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused relaunch must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must send nothing into any pane ($what)"

  brief_before=$(cat "$dir/home/data/$id/brief.md")
  out=$(run_control "$dir" "$id" exit); rc=$?
  expect_code 1 "$rc" "exit must refuse a tmux endpoint whose absence cannot be proven ($what)"$'\n'"$out"
  assert_not_contains "$out" "endpoint-gone" \
    "exit must not report a stop it cannot see ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused exit must send nothing into any pane ($what)"

  out=$(run_control "$dir" "$id" relaunch --note "this note must never reach a live agent"); rc=$?
  expect_code 1 "$rc" "the relaunch transaction must fail closed ($what)"$'\n'"$out"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused relaunch edited instructions an agent that may still be running is reading ($what)"
  assert_absent "$dir/fake/created-windows" "a refused transaction must not create a window ($what)"
  assert_absent "$dir/fake/created-sessions" "a refused transaction must not create a session ($what)"
  [ ! -s "$dir/fake/literal" ] || fail "a refused transaction must launch nothing ($what)"
}

test_tmux_refuses_a_window_missing_from_its_session() {
  local dir
  dir=$(new_case tmux-gone rl60)
  add_ship_task "$dir" rl60 claude
  strand_endpoint "$dir" rl60
  assert_tmux_missing_refuses "$dir" rl60 "window absent from a readable session inventory"
  pass "tmux: a window absent from its session refuses both verbs rather than being assumed gone"
}

test_tmux_refuses_a_session_that_cannot_be_found() {
  local dir
  dir=$(new_case tmux-nosession rl61)
  add_ship_task "$dir" rl61 claude
  # Real tmux's answer to a renamed session, and to a different
  # TMUX_TMPDIR/socket: definitive about the SESSION, silent about whether the
  # window and its agent survived elsewhere.
  : > "$dir/fake/session-missing"
  assert_tmux_missing_refuses "$dir" rl61 "recorded session not found"
  pass "tmux: an unfindable session refuses both verbs, so a live agent is never duplicated"
}

test_tmux_refuses_when_the_server_is_gone() {
  local dir
  dir=$(new_case tmux-noserver rl62)
  add_ship_task "$dir" rl62 claude
  # No server on the socket this process addresses. Another server may still be
  # running the task's window, and the record cannot say which socket is its.
  : > "$dir/fake/server-dead"
  assert_tmux_missing_refuses "$dir" rl62 "no tmux server on this socket"
  pass "tmux: a dead server on this socket refuses both verbs rather than proving absence"
}

test_reclaim_refuses_an_unreadable_endpoint() {
  local dir out rc
  dir=$(new_case gone-unreadable rl63)
  add_ship_task "$dir" rl63 claude
  # The inventory itself fails non-definitively. That is not evidence of
  # absence, and reading it as one is exactly how two agents end up in one
  # endpoint.
  : > "$dir/fake/inventory-broken"

  out=$(run_spawn "$dir" rl63 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "an unreadable endpoint must still refuse"
  assert_contains "$out" "positively agent-free endpoint" \
    "only a POSITIVELY proven agent-free endpoint may be relaunched into"
  assert_absent "$dir/fake/created-windows" \
    "a refused relaunch must not create an endpoint"
  [ ! -s "$dir/fake/literal" ] || fail "a refused relaunch must launch nothing"
  pass "reclaim: an unclassifiable endpoint is still refused, so two agents cannot share one"
}

# --- herdr: a stopped server is not a destroyed endpoint --------------------
#
# Stopping and restarting a named Herdr server preserves workspace, tab, pane
# and label ids; only the harness processes and their registrations die
# (docs/herdr-backend.md "Restart and liveness behavior"). The recovery-grade
# classifier still reads a stopped server as `missing`, so a reclaim that
# believed that verdict would abandon a pane that was about to come back and
# open a second tab beside it.
#
# Canned/stateful fake only - never a real herdr session.
make_herdr_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # The herdr server-ensure poll must actually wait between reads, so this case
  # keeps the real sleep rather than the tmux cases' instant stub.
  rm -f "$fb/sleep"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  if [ -f "$D/herdr-stopped" ]; then
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":false}}\n'
  else
    printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true}}\n'
  fi
  exit 0
fi
if [ "${1:-}" = server ]; then
  rm -f "$D/herdr-stopped"
  exit 0
fi
if [ -f "$D/herdr-stopped" ]; then
  # Every operational call against a stopped server fails at the transport,
  # with no JSON body to classify.
  echo 'error: could not connect to the herdr server' >&2
  exit 1
fi
case "${1:-} ${2:-}" in
  'session list')
    printf '{"sessions":[{"name":"%s","running":true,"socket_path":"%s/herdr.sock"}]}\n' "${HERDR_SESSION:-fmlab}" "$D"
    exit 0 ;;
  'pane get')
    if [ "${3:-}" = "$(cat "$D/herdr-pane")" ]; then
      printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"%s"}}}\n' \
        "${3:-}" "$(cat "$D/cwd")"
    else
      # Only the pane this case says survived can be read back. Any other pane
      # id is structurally gone, which is herdr's `pane_not_found`.
      printf '{"error":{"code":"pane_not_found"}}\n'
    fi
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-registration" ]; then
      cat "$D/herdr-agent-registration"
    elif [ -f "$D/herdr-agent-live" ]; then
      # The agent came back with its server. Nothing here is reclaimable.
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      # A pane that comes back holding no agent is the adoptable state.
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'pane process-info')
    # A retained registration with a shell-only pane models an exited agent
    # whose Herdr status authority still belongs to its previous session.
    if [ -f "$D/herdr-agent-registration" ]; then
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[]}}}\n' \
        "$(cat "$D/herdr-pane")"
    else
      printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"%s","shell_pid":4242,"foreground_processes":[{"pid":4243,"name":"claude","argv":["claude"],"cmdline":"claude"}]}}}\n' \
        "$(cat "$D/herdr-pane")"
    fi
    exit 0 ;;
  'pane send-text')
    # Mirrors the tmux fake's `becomes`: delivering the launch brief is what
    # makes an agent exist on this pane, so the control plane's alive-wait can
    # observe the replacement come up. A launch arrives as a short line sourcing
    # the staged launch file rather than the literal command, so read that file
    # back before deciding what was delivered - exactly as the tmux fake above
    # and tests/fixtures.sh do.
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live"
        : > "$D/launch-typed"
        [ ! -e "$D/fail-launch-literal" ] || exit 1 ;;
    esac
    exit 0 ;;
  'pane send-keys')
    if [ "${4:-}" = enter ] && [ -e "$D/launch-typed" ]; then
      [ ! -x "$D/worker-action" ] || "$D/worker-action"
      [ ! -e "$D/fail-launch-enter" ] || exit 1
    fi
    exit 0 ;;
  'pane close')
    : > "$D/close-attempted"
    [ ! -e "$D/keep-endpoint-open" ] || exit 0
    printf '%s' '%none' > "$D/herdr-pane"
    rm -f "$D/herdr-agent-live"
    exit 0 ;;
  'pane run')
    # A released relaunch allocates its copy through the pane's shell.
    [ "${4:-}" != 'treehouse get' ] || [ ! -f "$D/treehouse-slot" ] || cp "$D/treehouse-slot" "$D/cwd"
    exit 0 ;;
  'workspace list')
    printf '{"result":{"workspaces":[]}}\n'
    exit 0 ;;
  'workspace create')
    if [ -f "$D/herdr-workspace-create-fails" ]; then
      echo 'error: workspace create failed' >&2
      exit 1
    fi
    printf '{"result":{"workspace":{"workspace_id":"wsnew"},"tab":{"tab_id":"seedtab"}}}\n'
    exit 0 ;;
  'tab list')
    printf '{"result":{"tabs":[]}}\n'
    exit 0 ;;
  'tab create')
    # The re-created endpoint. Recording it lets a case prove the pane the
    # record ends up naming is the one this call minted.
    printf '%s\n' "$*" >> "$D/herdr-created-tabs"
    printf '{"result":{"tab":{"tab_id":"tabnew"},"root_pane":{"pane_id":"%%9"}}}\n'
    # From here on the new pane is the one that reads back.
    printf '%s' '%9' > "$D/herdr-pane"
    [ ! -x "$D/signal-endpoint" ] || "$D/signal-endpoint"
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/herdr"
  cat > "$fb/ps" <<'SH'
#!/usr/bin/env bash
if [ -f "$FM_FAKE_DIR/herdr-agent-registration" ]; then
  case "$*" in
    '-axo pid=,ppid=,comm=') printf '4242 1 bash\n' ;;
    '-p 4242 -o args=') printf 'bash\n' ;;
    *) exec /bin/ps "$@" ;;
  esac
else
  exec /bin/ps "$@"
fi
SH
  chmod +x "$fb/ps"
}

# add_herdr_ship_task <case-dir> <id> [session] [surviving-pane]: a ship task
# recorded on the herdr backend, with its server stopped so its endpoint
# classifies `missing`. <surviving-pane> is the pane id the fake will answer for
# once that server is back; default is the recorded one (it survived the
# restart). Pass a different id to model a pane that genuinely did not.
add_herdr_ship_task() {  # <case-dir> <id> [session] [surviving-pane]
  local dir=$1 id=$2 ses=${3:-fmlab} survivor=${4:-'%7'}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise a herdr reclaim safely.

## Firstmate spec
Keep the recorded endpoint when it outlives its server.
EOF
  {
    echo "window=$ses:%7"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "backend=herdr"
    echo "herdr_session=$ses"
    echo "herdr_workspace_id=ws1"
    echo "herdr_tab_id=tab1"
    echo "herdr_pane_id=%7"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf '%s' "$survivor" > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
  TASK_TMPS+=("/tmp/fm-$id")
}

# Sets HERDR_CASE_DIR rather than echoing it, so callers invoke it as a plain
# statement. A `dir=$(herdr_case_or_skip ...)` would run add_herdr_ship_task in
# a command-substitution subshell, where its TASK_TMPS registration would
# mutate a discarded copy and the EXIT trap would never remove the
# out-of-tmproot /tmp/fm-<id> root the spawn creates.
HERDR_CASE_DIR=
herdr_case_or_skip() {  # <name> <id> [session] [surviving-pane]
  HERDR_CASE_DIR=
  command -v jq >/dev/null 2>&1 || return 1
  HERDR_CASE_DIR=$(new_case "$1" "$2")
  add_herdr_ship_task "$HERDR_CASE_DIR" "$2" "${3:-fmlab}" "${4:-%7}"
  make_herdr_stub "$HERDR_CASE_DIR"
  return 0
}

released_use_herdr() {
  local dir=$1 id=$2
  make_herdr_stub "$dir"
  awk '
    /^window=/ { print "window=fmlab:%7"; next }
    /^pr=/ { print "backend=herdr"; print "herdr_session=fmlab"; print "herdr_workspace_id=ws1"
             print "herdr_tab_id=tab1"; print "herdr_pane_id=%7" }
    { print }
  ' "$dir/home/state/$id.meta" > "$dir/home/state/$id.meta.new"
  mv "$dir/home/state/$id.meta.new" "$dir/home/state/$id.meta"
  # Teardown closed the pane: it does not come back with its server.
  printf '%s' '%none' > "$dir/fake/herdr-pane"
  : > "$dir/fake/herdr-log"
  : > "$dir/fake/herdr-stopped"
}

test_herdr_relaunch_of_a_released_copy_recreates_it() {
  local dir out rc=0 head
  command -v jq >/dev/null 2>&1 || {
    echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$(new_case released-herdr rr10)
  add_released_ship_task "$dir" rr10
  released_use_herdr "$dir" rr10
  head=$(cat "$dir/fake/pr-head")
  out=$(run_control "$dir" rr10 relaunch --note "herdr pick-up") || rc=$?
  expect_code 0 "$rc" "a released herdr copy should be recreated and relaunched"$'\n'"$out"
  [ "$(meta_field "$dir" rr10 worktree)" = "$dir/pool/1/repo" ] || fail "the herdr record does not name the new copy"
  [ "$(meta_field "$dir" rr10 herdr_pane_id)" = '%9' ] || fail "the herdr record does not name the new pane"
  [ "$(git -C "$dir/pool/1/repo" rev-parse HEAD)" = "$head" ] || fail "the new herdr copy is not at the released head"
  [ "$(released_note_count "$dir" rr10)" = 1 ] || fail "the herdr relaunch should leave exactly one recreated-copy note"
  pass "herdr: relaunch of a released copy recreates it in a new pane and claimed slot"
}

test_herdr_relaunch_resumes_only_the_registered_pi_session() {
  local dir out rc=0 command registered
  for registered in pi claude; do
    herdr_case_or_skip "resume-$registered" "resume-$registered" || {
      echo "skip - herdr relaunch needs jq (the herdr adapter parses JSON with it)"
      return 0
    }
    dir=$HERDR_CASE_DIR
    rm -f "$dir/fake/herdr-stopped"
    sed -i 's/^harness=claude$/harness=pi/' "$dir/home/state/resume-$registered.meta"
    # Keep the pane's status authority registered to an existing Pi session,
    # while process-info proves that its previous agent has exited.
    printf '{"result":{"agent":{"agent":"%s","agent_status":"idle","agent_session":{"kind":"path","value":"/tmp/pi-bound-session.jsonl"}}}}\n' \
      "$registered" > "$dir/fake/herdr-agent-registration"
    out=$(run_spawn "$dir" "resume-$registered" --relaunch --harness pi) || rc=$?
    expect_code 0 "$rc" "Herdr Pi relaunch should complete ($registered registration)"$'\n'"$out"
    command=$(cat "$dir/fake/launched-command")
    if [ "$registered" = pi ]; then
      assert_contains "$command" "--session '/tmp/pi-bound-session.jsonl'" \
        "the replacement Pi must resume the session that owns Herdr status authority"
    else
      assert_not_contains "$command" "--session" \
        "a Pi replacement must not resume a foreign adapter's conversation"
    fi
    rc=0
  done
  pass "fm-spawn --relaunch: resumes the bound Pi session only for a Pi registration"
}

test_herdr_reclaim_adopts_a_pane_that_outlived_its_server() {
  local dir out rc=0 log stray
  herdr_case_or_skip gone-herdr rl68 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl68 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a pane that outlived its stopped server is adoptable"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "server --session fmlab" \
    "the reclaim must bring the RECORDED session's server back before deciding anything"
  assert_contains "$log" "agent get %7 --session fmlab" \
    "the reclaim must re-read the recorded pane once its server is running"
  assert_not_contains "$log" "workspace create" \
    "adopting a preserved pane must not create a workspace"
  assert_not_contains "$log" "tab create" \
    "adopting a preserved pane must not open a second tab beside it"
  # Every call belongs to the session the record names. A rebind resolves its
  # container from the ambient session instead, which is how the preserved pane
  # ends up orphaned in a workspace nothing points at.
  stray=$(printf '%s\n' "$log" | grep -v -- '--session fmlab$' | grep -v '^status --json$' || true)
  [ -z "$stray" ] || fail "a herdr reclaim touched a session the record does not name: $stray"
  assert_contains "$out" "window=fmlab:%7" "the reclaim should report the adopted endpoint"
  [ "$(meta_field "$dir" rl68 herdr_pane_id)" = '%7' ] \
    || fail "the adopted record's pane id changed, got $(meta_field "$dir" rl68 herdr_pane_id)"
  [ "$(meta_field "$dir" rl68 herdr_tab_id)" = tab1 ] \
    || fail "the adopted record's tab id changed, got $(meta_field "$dir" rl68 herdr_tab_id)"
  [ "$(meta_field "$dir" rl68 window)" = 'fmlab:%7' ] \
    || fail "the adopted record's endpoint moved, got $(meta_field "$dir" rl68 window)"
  assert_contains "$log" "pane send-text %7 " \
    "the replacement's launch brief must be delivered into the adopted pane"
  pass "reclaim: a herdr pane that outlived its stopped server is adopted, never orphaned beside a new tab"
}

test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server() {
  local dir out rc=0
  herdr_case_or_skip gone-herdr-exit rl72 || {
    echo "skip - herdr exit needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_control "$dir" rl72 exit) || rc=$?
  expect_code 0 "$rc" "a pane that outlived its stopped server holds no agent, which is success"$'\n'"$out"
  assert_contains "$out" "already-stopped" \
    "the endpoint is there and idle, which is the ordinary already-stopped outcome"
  assert_not_contains "$out" "endpoint-gone" \
    "a pane that survived its server's restart was never gone"
  [ "$(meta_field "$dir" rl72 window)" = 'fmlab:%7' ] \
    || fail "exit must leave the recorded endpoint exactly as it found it"
  pass "fm-control exit: a herdr pane that outlived its stopped server is already-stopped, not gone"
}

test_herdr_rebind_stays_in_the_recorded_session() {
  local dir out rc=0 log
  # The record names session `fmlab`; this seat has no ambient HERDR_SESSION, so
  # the adapter's own default is `default`. The recorded pane does NOT come back
  # with the server, so this reclaim really does rebind - and the rebind must
  # land in `fmlab`, never in `default`.
  herdr_case_or_skip gone-herdr-pin rl73 fmlab '%none' || {
    echo "skip - herdr rebind needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR

  out=$(run_spawn "$dir" rl73 --relaunch --harness claude) || rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 0 "$rc" "a herdr pane that did not survive its server should be rebound"$'\n'"$out"$'\n'"$log"

  assert_contains "$log" "tab create" "a destroyed pane must be replaced by a fresh tab"
  [ -z "$(grep -v -- '--session fmlab$' <<<"$log" | grep -v '^status --json$' || true)" ] \
    || fail "the rebind used a herdr session the record does not name: $log"
  [ "$(meta_field "$dir" rl73 herdr_session)" = fmlab ] \
    || fail "the rebound record left its recorded herdr session, got $(meta_field "$dir" rl73 herdr_session)"
  [ "$(meta_field "$dir" rl73 window)" = 'fmlab:%9' ] \
    || fail "the rebound endpoint should be the new pane in the recorded session, got $(meta_field "$dir" rl73 window)"
  [ "$(meta_field "$dir" rl73 herdr_pane_id)" = '%9' ] \
    || fail "the rebound record should name the pane the reclaim minted, got $(meta_field "$dir" rl73 herdr_pane_id)"
  pass "reclaim: a herdr rebind is created in the session the record names, never the ambient one"
}

test_herdr_reclaim_refuses_an_agent_that_came_back() {
  local dir out rc log
  herdr_case_or_skip gone-herdr-alive rl74 || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  # The server was stopped, so the first read says `missing` - but starting it
  # brings the pane AND its agent back. A rebind here would put a second agent
  # in this task's worktree, which is the whole reason absence is re-proven.
  : > "$dir/fake/herdr-agent-live"

  out=$(run_spawn "$dir" rl74 --relaunch --harness claude); rc=$?
  log=$(cat "$dir/fake/herdr-log")
  expect_code 1 "$rc" "a returning agent must refuse, never be duplicated"$'\n'"$out"$'\n'"$log"
  assert_contains "$out" "alive" "the refusal should name the state it actually read"
  assert_not_contains "$log" "tab create" "a refused reclaim must not mint a second tab"
  assert_not_contains "$log" "workspace create" "a refused reclaim must not create a workspace"
  [ "$(meta_field "$dir" rl74 herdr_pane_id)" = '%7' ] \
    || fail "a refused reclaim rewrote the record's pane id"
  pass "reclaim: a herdr agent that came back with its server refuses, so one worktree keeps one agent"
}

test_herdr_reclaim_keeps_the_task_whole() {
  local dir out rc=0 head_before
  herdr_case_or_skip gone-herdr-work rl75 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf 'landed on the branch\n' > "$dir/wt/committed.txt"
  git -C "$dir/wt" add committed.txt
  git -C "$dir/wt" -c user.email=t@example.com -c user.name=t commit -qm "work in progress"
  head_before=$(git -C "$dir/wt" rev-parse HEAD)
  printf 'never committed\n' > "$dir/wt/dirty.txt"

  # A reclaim rebinds the ENDPOINT and nothing else. Everything that identifies
  # the task must come through untouched: a record row the reclaim does not
  # own, the armed watcher check and the private binding that authorizes it,
  # and the status log the supervisor reads.
  printf '%s\n' "pr=https://example.invalid/pr/7" >> "$dir/home/state/rl75.meta"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/home/state/rl75.check.sh"
  chmod 0700 "$dir/home/state/rl75.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" rl75 >/dev/null \
    || fail "could not arm a custom check for the reclaim fixture"
  printf 'working: parked on an approval nobody can answer\n' >> "$dir/home/state/rl75.status"

  out=$(run_control "$dir" rl75 relaunch --note "the pane was destroyed; pick the work back up") || rc=$?
  expect_code 0 "$rc" "the owning seat should be able to reclaim a task whose pane is gone"$'\n'"$out"

  [ "$(git -C "$dir/wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "a reclaim moved the worktree's HEAD"
  [ "$(git -C "$dir/wt" rev-parse --abbrev-ref HEAD)" = "task-rl75" ] \
    || fail "a reclaim changed the worktree's branch"
  assert_contains "$(cat "$dir/wt/dirty.txt")" "never committed" \
    "a reclaim destroyed or rewrote an uncommitted change"
  assert_present "$dir/wt/committed.txt" "a reclaim destroyed committed work"

  [ "$(meta_field "$dir" rl75 worktree)" = "$dir/wt" ] \
    || fail "a reclaim must keep the recorded worktree"
  [ "$(meta_field "$dir" rl75 pr)" = "https://example.invalid/pr/7" ] \
    || fail "a reclaim dropped a record row it does not own"
  assert_present "$dir/home/state/rl75.check.sh" "a reclaim retired the task's armed check"
  assert_present "$dir/home/state/rl75.check-trust" "a reclaim broke the armed check's registration"
  assert_contains "$(cat "$dir/home/state/rl75.status")" "parked on an approval nobody can answer" \
    "a reclaim truncated the status log"
  assert_contains "$(cat "$dir/home/data/rl75/brief.md")" "the pane was destroyed" \
    "the replacement must inherit the progress note"
  [ "$(journal_field "$dir" rl75 exit_result)" = endpoint-gone ] \
    || fail "the transaction should record that the endpoint was already gone"
  [ "$(journal_field "$dir" rl75 exit_background)" = background-sessions=none ] \
    || fail "the transaction should record the Claude background-session check beside the exit result"
  pass "reclaim: a herdr reclaim rebinds the endpoint and leaves the whole rest of the task alone"
}

test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause() {
  local dir out rc
  # No HERDR_* env at all, which is how an operator reclaims from ssh or cron.
  # The adapter's ambient session then reads `default` while the record names
  # `fmlab`, but the cross-session launcher guard was never consulted - this
  # seat claims no launcher pane, so placement fell back to the recorded
  # session's labeled container and the container failed for its own reason.
  herdr_case_or_skip gone-herdr-plain rl77 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  : > "$dir/fake/herdr-workspace-create-fails"

  out=$(run_spawn "$dir" rl77 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a container that cannot be ensured must refuse"$'\n'"$out"
  assert_contains "$out" "fmlab" "the refusal should name the session the reclaim was targeting"
  assert_not_contains "$out" "this seat is running in herdr session" \
    "a seat with no launcher pane never hit the cross-session guard, so the refusal must not blame one"
  assert_not_contains "$out" "a reclaim never moves a task to another session" \
    "the operator must not be sent to re-run from another seat when that would not help"
  pass "reclaim: a rebind refused from a plain shell reports the real cause, not a fabricated session mismatch"
}

test_herdr_reclaim_of_a_secondmate_names_its_own_owner() {
  local dir out rc
  herdr_case_or_skip gone-herdr-secondmate rl76 fmlab '%none' || {
    echo "skip - herdr reclaim needs jq (the herdr adapter parses JSON with it)"
    return 0
  }
  dir=$HERDR_CASE_DIR
  printf '%s\n' "kind=secondmate" "home=$dir/wt" >> "$dir/home/state/rl76.meta"

  out=$(run_spawn "$dir" rl76 --relaunch --harness claude); rc=$?
  expect_code 1 "$rc" "a secondmate reclaim belongs to the secondmate respawn path"
  assert_contains "$out" "--secondmate" "the refusal should name the path that owns this recovery"
  assert_not_contains "$(cat "$dir/fake/herdr-log")" "tab create" \
    "the refusal must happen before any endpoint is created"
  pass "reclaim: a herdr secondmate whose endpoint is gone is sent to its own respawn owner"
}

test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case reverify rl40)
  add_ship_task "$dir" rl40 claude
  seed_backlog "$dir" rl40 in_flight
  break_tasks_axi_start "$dir"

  out=$(run_control "$dir" rl40 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch must not re-run a transition the row already reflects"$'\n'"$out"
  [ "$(backlog_state "$dir" rl40)" = in_flight ] \
    || fail "a relaunch changed an already In-flight item to $(backlog_state "$dir" rl40)"
  pass "relaunch re-reads the backlog item instead of blindly re-running the transition"
}

test_relaunch_moves_a_drifted_item_back_in_flight() {
  local dir out rc=0
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }
  dir=$(new_case drifted rl41)
  add_ship_task "$dir" rl41 claude
  seed_backlog "$dir" rl41 queued

  out=$(run_control "$dir" rl41 relaunch --note "picking the work back up") || rc=$?
  expect_code 0 "$rc" "a relaunch onto a drifted item should succeed"$'\n'"$out"
  [ "$(backlog_state "$dir" rl41)" = in_flight ] \
    || fail "a relaunch left its item at $(backlog_state "$dir" rl41)"
  pass "relaunch heals an item that drifted out of In flight while the task stayed live"
}

test_away_branch_relaunch_accepts_existing_dispatchable_items() {
  local dir id out rc state
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  fm_tasks_axi_compatible || {
    pass "skipped: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so dispatch refuses automatic backlog transitions"
    return 0
  }

  for state in in_flight queued; do
    id="rl-away-$state"
    dir=$(new_case "away-$state" "$id")
    add_ship_task "$dir" "$id" claude
    seed_backlog "$dir" "$id" "$state"
    FM_HOME="$dir/home" "$ROOT/bin/fm-afk-contract.sh" enter --spend 1 >/dev/null \
      || fail "away entry failed for a $state relaunch"

    rc=0
    out=$(FM_SUPERVISION_ACTOR=branch run_control "$dir" "$id" relaunch \
      --note "continue the existing task under away supervision") || rc=$?
    expect_code 0 "$rc" "the away branch must relaunch an existing $state item"$'\n'"$out"
    assert_contains "$out" "relaunched $id" \
      "the away branch did not complete the existing $state task's relaunch"
    [ "$(backlog_state "$dir" "$id")" = in_flight ] \
      || fail "the away branch left a relaunched $state item at $(backlog_state "$dir" "$id")"
  done
  pass "away supervision relaunches existing In-flight and queued items under the saturated fresh-spawn spend cap"
}

test_exit_and_relaunch_remove_the_dialog_file() {
  local dir out rc
  dir=$(new_case dialog-file-exit rl70)
  add_ship_task "$dir" rl70 claude
  out=$(run_control "$dir" rl70 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl70.composer-dialog" ] \
    || fail "exit should remove the dialog file"

  dir=$(new_case dialog-file-relaunch rl71)
  add_ship_task "$dir" rl71 claude
  out=$(run_control "$dir" rl71 relaunch --note "replace the agent"); rc=$?
  expect_code 0 "$rc" "relaunch should replace the agent"$'\n'"$out"
  [ ! -e "$dir/home/state/rl71.composer-dialog" ] \
    || fail "relaunch should remove the dialog file"
  pass "fm-control removes the dialog file after exit and after relaunch"
}

# The lock release removes paths at or under the control lock with rm, so a
# recording rm sees the state directory at the moment of release without a
# second overlapping command.
test_exit_removes_the_dialog_file_before_releasing_the_lock() {
  local dir out rc lock sink trace
  dir=$(new_case dialog-file-order rl72)
  add_ship_task "$dir" rl72 claude
  lock="$dir/home/state/.control-rl72.lock"
  sink="$dir/home/state/rl72.composer-dialog"
  trace="$dir/fake/rm-trace"
  cat > "$dir/fakebin/rm" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    "$lock"|"$lock"/*)
      if [ -e "$sink" ]; then echo present; else echo absent; fi >> "$trace"
      break
      ;;
  esac
done
exec "$(command -v rm)" "\$@"
SH
  chmod +x "$dir/fakebin/rm"
  out=$(run_control "$dir" rl72 exit); rc=$?
  expect_code 0 "$rc" "exit should stop the agent"$'\n'"$out"
  [ ! -e "$lock" ] || fail "exit should release the control lock"
  [ "$(tail -n 1 "$trace" 2>/dev/null)" = absent ] \
    || fail "the dialog file must be gone when the control lock is released, got: $(cat "$trace" 2>/dev/null)"
  pass "fm-control exit removes the dialog file before it releases the control lock"
}

test_recovery_rechecks_eligibility_after_manual_relaunch() {
  local dir out rc before
  dir=$(new_case recovery-recheck)
  add_ship_task "$dir" t1
  printf 'unlanded\n' > "$dir/wt/unlanded.txt"
  printf zsh > "$dir/fake/command"
  # shellcheck disable=SC2016 # Expand positional parameters in the child shell.
  out=$(run_lifecycle_fixture "$dir" \
    bash -c '. "$1"; fm_crew_recovery_agent_state "$2" t1' _ \
    "$ROOT/bin/fm-crew-recovery-lib.sh" "$dir/home/state")
  [ "$out" = dead ] || fail "startup did not discover the dead task: $out"
  out=$(run_control "$dir" t1 relaunch --note manual)
  expect_code 0 "$?" "manual relaunch failed: $out"
  printf 'pending\n' > "$dir/home/state/t1.composer-dialog"
  before=$(cat "$dir/home/state/t1.meta" "$dir/home/data/t1/brief.md" "$dir/fake/literal")
  out=$(run_control "$dir" t1 relaunch --note recovery --if-recoverable); rc=$?
  expect_code 3 "$rc" "recovery must skip the healthy replacement: $out"
  [ "$before" = "$(cat "$dir/home/state/t1.meta" "$dir/home/data/t1/brief.md" "$dir/fake/literal")" ] \
    || fail "recovery modified the healthy replacement"
  [ "$(cat "$dir/home/state/t1.composer-dialog")" = pending ] || fail "skipped recovery removed the dialog record"
  pass "recovery skips a task relaunched since startup discovery"
}

test_recovery_eligibility_holds_the_lifecycle_lock() {
  local dir worker out rc i deferred deferred_rc
  dir=$(new_case recovery-lock)
  add_ship_task "$dir" t1
  printf 'unlanded\n' > "$dir/wt/unlanded.txt"
  printf zsh > "$dir/fake/command"
  FM_FAKE_RECOVERY_PROBE_READY="$dir/probe-ready" \
    FM_FAKE_RECOVERY_PROBE_RELEASE="$dir/probe-release" \
    run_control "$dir" t1 relaunch --note recovery --if-recoverable > "$dir/recovery.out" &
  # shellcheck disable=SC2031 # $! is set by the background launch in this shell.
  worker=$!
  i=0
  while [ ! -e "$dir/probe-ready" ] && [ "$i" -lt 300 ]; do
    /bin/sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$dir/probe-ready" ]; then
    : > "$dir/probe-release"
    wait "$worker" || true
    fail "recovery did not reach the eligibility probe: $(cat "$dir/recovery.out")"
  fi
  out=$(run_control "$dir" t1 relaunch --note manual); rc=$?
  deferred=$(run_control "$dir" t1 relaunch --note recovery --if-recoverable); deferred_rc=$?
  : > "$dir/probe-release"
  wait "$worker"; i=$?
  expect_code 1 "$rc" "manual relaunch must not interrupt recovery eligibility: $out"
  assert_contains "$out" 'another lifecycle action' 'manual relaunch bypassed the recovery lock'
  expect_code 75 "$deferred_rc" "overlapping recovery must defer to the lifecycle owner: $deferred"
  expect_code 0 "$i" "recovery failed after releasing the probe: $(cat "$dir/recovery.out")"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "recovery did not start the replacement"
  out=$(run_control "$dir" t1 relaunch --note manual)
  expect_code 0 "$?" "manual relaunch failed after recovery released its lock: $out"
  pass "recovery locks eligibility through replacement and releases the lifecycle lock"
}

test_recovery_rechecks_task_records_and_work() {
  local dir out rc mutation
  for mutation in held clean secondmate; do
    dir=$(new_case "recovery-$mutation")
    add_ship_task "$dir" t1
    printf zsh > "$dir/fake/command"
    printf 'unlanded\n' > "$dir/wt/unlanded.txt"
    case "$mutation" in
      held) printf 'captain-held [at=1]: waiting\n' > "$dir/home/state/t1.status" ;;
      clean)
        git -C "$dir/wt" add unlanded.txt
        git -C "$dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm landed
        git -C "$dir/proj" merge -q --ff-only task-t1
        ;;
      secondmate) printf 'kind=secondmate\n' >> "$dir/home/state/t1.meta" ;;
    esac
    out=$(run_control "$dir" t1 relaunch --note recovery --if-recoverable); rc=$?
    expect_code 3 "$rc" "recovery must recheck $mutation eligibility: $out"
    [ ! -s "$dir/fake/literal" ] || fail "recovery sent input to an ineligible $mutation task"
  done
  pass "conditional recovery rechecks the task kind, record, and unlanded work"
}

test_reboot_recovery_uses_the_real_control_and_spawn_paths() {
  local dir route kind out rc
  for route in sweep control spawn; do
    for kind in ship scout; do
      dir=$(new_case "reboot-$route-$kind")
      add_ship_task "$dir" t1
      make_recovery_nm_stub "$dir"
      printf 'kind=%s\nspawn_gen=s1.1.1\n' "$kind" >> "$dir/home/state/t1.meta"
      printf 'unlanded\n' > "$dir/wt/unlanded.txt"
      : > "$dir/fake/server-dead"
      case "$route" in
        sweep) out=$(run_recovery "$dir"); rc=$? ;;
        control) out=$(run_control "$dir" t1 relaunch --note reboot --if-recoverable); rc=$? ;;
        spawn) out=$(run_spawn "$dir" t1 --relaunch); rc=$? ;;
      esac
      expect_code 0 "$rc" "reboot $route recovery failed for $kind: $out"
      [ "$(cat "$dir/fake/command")" = claude ] || fail "reboot recovery did not launch the agent: $out"
      [ "$(meta_field "$dir" t1 window)" = fmses:fm-t1 ] || fail "reboot recovery changed the recorded session"
      [ "$(cat "$dir/fake/created-sessions")" = fmses ] || fail "reboot recovery created the wrong session"
      [ "$(cat "$dir/fake/created-windows")" = fm-t1 ] || fail "reboot recovery created duplicate windows"
      [ "$(cat "$dir/wt/unlanded.txt")" = unlanded ] || fail "reboot recovery discarded work"
      out=$(run_recovery "$dir")
      assert_not_contains "$out" 'CREW_RECOVERY: relaunched' 'a second pass replaced the healthy worker'
      [ "$(cat "$dir/fake/created-windows")" = fm-t1 ] || fail "a second pass created another window"
    done
  done
  pass "rebooted tmux ship and scout recovery preserves work through control and spawn"
}

test_tmux_absence_needs_prior_boot_evidence() {
  local dir generation out rc
  for generation in '' broken s999999999999.1.1 "s$(date +%s).1.1"; do
    dir=$(new_case reboot-unproven)
    add_ship_task "$dir" t1
    printf 'spawn_gen=%s\n' "$generation" >> "$dir/home/state/t1.meta"
    : > "$dir/fake/server-dead"
    out=$(run_control "$dir" t1 relaunch --note reboot); rc=$?
    expect_code 1 "$rc" "unproven tmux absence must refuse: $out"
    [ ! -e "$dir/fake/created-windows" ] || fail "unproven absence created a replacement"
    [ ! -s "$dir/fake/literal" ] || fail "unproven absence sent lifecycle input"
  done
  pass "missing malformed future and current-boot generations never prove tmux absence"
}

test_recovery_respects_reconciled_run_ownership() {
  local dir status out rc head
  for status in running fix_review completed failed unreadable; do
    dir=$(new_case "recovery-run-$status")
    add_ship_task "$dir" t1
    make_recovery_nm_stub "$dir"
    printf 'unlanded\n' > "$dir/wt/unlanded.txt"
    printf zsh > "$dir/fake/command"
    printf 'paused: waiting for validation\n' > "$dir/home/state/t1.status"
    head=$(git -C "$dir/wt" rev-parse HEAD)
    [ "$status" != unreadable ] || { : > "$dir/fake/run-unreadable"; status=running; }
    cat > "$dir/fake/run-status" <<EOF
run:
  id: "01RECOVERY"
  branch: task-t1
  status: $status
  head: "$head"
  pr: ""
  findings: none
branch_sync:
  state: pipeline_owned
EOF
    case "$status" in
      completed) printf 'outcome: passed\n' >> "$dir/fake/run-status" ;;
      failed) printf 'outcome: failed\n' >> "$dir/fake/run-status" ;;
    esac
    printf 'count: 1 of 1 total\nruns[1]{id,branch,status,head,pr}:\n  01RECOVERY,task-t1,%s,%s,""\n' "$status" "$head" > "$dir/fake/run-overview"
    if [ "$status" = running ] && [ ! -f "$dir/fake/run-unreadable" ]; then
      out=$(run_lifecycle_fixture "$dir" "$ROOT/bin/fm-crew-state.sh" t1)
      assert_contains "$out" 'source: none' 'the fixture did not reach the ordinary dead-endpoint override'
      assert_contains "$out" 'agent gone' 'the fixture did not classify the dead agent'
    fi
    out=$(run_control "$dir" t1 relaunch --note recovery --if-recoverable); rc=$?
    expect_code 3 "$rc" "recovery must leave an attributed $status run alone: $out"
    out=$(run_recovery "$dir")
    assert_not_contains "$out" 'CREW_RECOVERY: relaunched' 'the sweep relaunched a run-owned worker'
    [ ! -s "$dir/fake/literal" ] || fail "recovery sent input to a run-owned worker"
  done
  pass "recovery respects active parked terminal and unreadable attributed runs"
}

test_recovery_relaunches_the_prevalidation_done_handoff() {
  local dir out
  dir=$(new_case recovery-handoff)
  add_ship_task "$dir" t1
  make_recovery_nm_stub "$dir"
  printf 'unpublished\n' > "$dir/wt/unpublished.txt"
  git -C "$dir/wt" add unpublished.txt
  git -C "$dir/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm 'implementation complete'
  printf 'done: implementation complete\n' > "$dir/home/state/t1.status"
  printf 'spawn_gen=s1.1.1\n' >> "$dir/home/state/t1.meta"
  : > "$dir/fake/server-dead"
  out=$(run_recovery "$dir")
  assert_contains "$out" 'CREW_RECOVERY: relaunched t1 after missing' 'the prevalidation done handoff was skipped'
  [ "$(cat "$dir/fake/command")" = claude ] || fail "the handoff did not resume"
  [ "$(cat "$dir/wt/unpublished.txt")" = unpublished ] || fail "the handoff lost its implementation"
  pass "a done-before-validation worker resumes its unpublished commits after reboot"
}

test_serial_recovery_rereads_capacity_before_each_launch() {
  local dir id out
  dir=$(new_case recovery-capacity a-first)
  add_ship_task "$dir" a-first
  make_recovery_nm_stub "$dir"
  printf 'unlanded\n' > "$dir/wt/unlanded.txt"
  printf 'spawn_gen=s1.1.1\n' >> "$dir/home/state/a-first.meta"
  for id in b-next c-last; do
    sed "s/a-first/$id/g" "$dir/home/state/a-first.meta" > "$dir/home/state/$id.meta"
    mkdir -p "$dir/home/data/$id"
    cp "$dir/home/data/a-first/brief.md" "$dir/home/data/$id/brief.md"
  done
  printf '1 0\n' > "$dir/home/config/lane-capacity"
  : > "$dir/fake/server-dead"
  out=$(FM_FAKE_CAPACITY_AFTER_LAUNCH="$dir/home/config/lane-capacity" run_recovery "$dir")
  assert_contains "$out" 'CREW_RECOVERY: relaunched a-first after missing' 'the available lane was not used'
  assert_contains "$out" 'CREW_RECOVERY: b-next: relaunch deferred' 'capacity was not reread after the first launch'
  assert_not_contains "$out" 'c-last' 'the sweep continued after the capacity deferral'
  [ "$(cat "$dir/fake/created-windows")" = fm-a-first ] || fail "serial recovery over-admitted workers"
  [ ! -e "$dir/home/state/c-last.control-relaunch" ] || fail "a later task was touched after deferral"
  pass "serial recovery rereads capacity and stops at the first deferred launch"
}


test_released_launch_delivery_failure_rolls_back() {
  local dir backend failure out rc meta brief
  for backend in tmux herdr; do
    for failure in literal enter; do
      dir=$(new_case "released-delivery-$backend-$failure" rr12)
      add_released_ship_task "$dir" rr12
      [ "$backend" != herdr ] || released_use_herdr "$dir" rr12
      seed_backlog "$dir" rr12 in_flight
      tasks-axi hold rr12 --kind external --reason "awaiting merge https://github.com/example/repo/pull/7" \
        --file "$dir/home/data/backlog.md" >/dev/null
      : > "$dir/fake/fail-launch-$failure"
      meta=$(cat "$dir/home/state/rr12.meta")
      brief=$(cat "$dir/home/data/rr12/brief.md")
      printf 'sentinel contents\n' > "$dir/home/state/rr12.released-copy"
      out=$(run_control "$dir" rr12 relaunch --note "delivery retry"); rc=$?
      [ "$rc" -ne 0 ] || fail "$backend/$failure: failed delivery should refuse"$'\n'"$out"
      assert_present "$dir/fake/launch-typed" "$backend/$failure: the failure did not reach launch delivery"
      assert_released_untouched "$dir" rr12 "$meta" "$brief" "$backend/$failure"
      [ "$(cat "$dir/home/state/rr12.released-copy")" = 'sentinel contents' ] || fail "the sentinel was touched"
      [ "$(backlog_held "$dir" rr12)" = yes ] || fail "$backend/$failure: the merge hold was lifted"
      assert_absent "$dir/pool/1/.fm-slot-owner" "$backend/$failure: the slot is still claimed"
      assert_grep "return $dir/pool/1/repo" "$dir/fake/treehouse-log" "$backend/$failure: the copy was not returned"
      if [ "$backend" = tmux ]; then
        [ ! -s "$dir/fake/windows" ] || fail "the failed launch left its window open"
      else
        [ "$(cat "$dir/fake/herdr-pane")" = '%none' ] || fail "the failed launch left its pane open"
      fi
      rm "$dir/fake/fail-launch-$failure" "$dir/fake/launch-typed"
      printf '%s' "$dir/proj" > "$dir/fake/cwd"
      out=$(run_control "$dir" rr12 relaunch --note "delivery retry"); rc=$?
      expect_code 0 "$rc" "$backend/$failure: the retry should succeed"$'\n'"$out"
      [ "$(released_note_count "$dir" rr12)" = 1 ] || fail "the retry duplicated the progress note"
      [ "$(backlog_held "$dir" rr12)" = no ] || fail "the successful retry left the merge hold"
    done
  done
  pass "released relaunch delivery failures restore state and return resources on both backends"
}

test_released_pool_exhaustion_defers() {
  local backend dir out rc meta brief
  for backend in tmux herdr; do
    dir=$(new_case "released-pool-$backend" rr13)
    add_released_ship_task "$dir" rr13
    [ "$backend" != herdr ] || released_use_herdr "$dir" rr13
    printf '%s' "$dir/proj" > "$dir/fake/treehouse-slot"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$dir/fakebin/sleep"
    chmod +x "$dir/fakebin/sleep"
    meta=$(cat "$dir/home/state/rr13.meta")
    brief=$(cat "$dir/home/data/rr13/brief.md")
    out=$(run_control "$dir" rr13 relaunch --note "no slot"); rc=$?
    expect_code 75 "$rc" "$backend: an exhausted pool should defer"$'\n'"$out"
    assert_released_untouched "$dir" rr13 "$meta" "$brief" "$backend pool exhaustion"
    assert_absent "$dir/pool/1/.fm-slot-owner" "$backend: no slot should be claimed"
    if [ "$backend" = tmux ]; then
      [ ! -s "$dir/fake/windows" ] || fail "the deferred launch left its window open"
    else
      [ "$(cat "$dir/fake/herdr-pane")" = '%none' ] || fail "the deferred launch left its pane open"
    fi
  done
  pass "an exhausted pool defers with exit 75 and closes the endpoint on both backends"
}

test_released_fork_branch_uses_head_repository() {
  local dir out rc head
  dir=$(new_case released-fork rr14)
  add_released_ship_task "$dir" rr14
  head=$(cat "$dir/fake/pr-head")
  git clone --quiet --bare "$dir/origin.git" "$dir/fork.git"
  git -C "$dir/fork.git" branch -m fm/rr14 topic
  git -C "$dir/origin.git" branch -D fm/rr14 >/dev/null
  git -C "$dir/proj" remote add fork https://github.com/contributor/repo.git
  git -C "$dir/proj" config "url.file://$dir/fork.git.insteadOf" https://github.com/contributor/repo.git
  printf 'contributor/repo\n' > "$dir/fake/pr-head-path"
  printf 'topic\n' > "$dir/fake/pr-head-branch"
  out=$(run_control "$dir" rr14 relaunch --note "fork pickup"); rc=$?
  expect_code 0 "$rc" "the branch must be fetched from the fork, not the base repo"$'\n'"$out"
  [ "$(git -C "$dir/pool/1/repo" rev-parse HEAD)" = "$head" ] || fail "the fork head was not recreated"
  [ "$(git -C "$dir/pool/1/repo" symbolic-ref --short HEAD)" = fm/rr14 ] || fail "the local task branch changed"
  [ "$(git -C "$dir/pool/1/repo" rev-parse --abbrev-ref '@{upstream}')" = fork/topic ] || fail "the recreated branch tracks the wrong remote branch"
  pass "a fork relaunch fetches the PR head repository and branch"
}

test_teardown_to_relaunch_round_trip() {
  local dir out rc slot head
  dir=$(new_case released-roundtrip rr15)
  add_released_ship_task "$dir" rr15
  git -C "$dir/proj" remote add duplicate https://github.com/example/repo.git
  seed_backlog "$dir" rr15 in_flight
  slot="$dir/pool/1/repo"
  head=$(cat "$dir/fake/pr-head")
  git -C "$slot" checkout -q -b fm/rr15 origin/fm/rr15
  awk -v slot="$slot" '/^released_/ { next } /^worktree=/ { print "worktree=" slot; next } { print }' \
    "$dir/home/state/rr15.meta" > "$dir/active.meta"
  mv "$dir/active.meta" "$dir/home/state/rr15.meta"
  printf 'fm-rr15\n' > "$dir/fake/windows"
  printf '%s' "$slot" > "$dir/fake/cwd"
  make_recovery_nm_stub "$dir"
  cat > "$dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in *' -d cwd '*) exit 0 ;; esac
exit 1
SH
  chmod +x "$dir/fakebin/lsof"
  out=$(run_lifecycle_fixture "$dir" bash "$ROOT/bin/fm-teardown.sh" rr15); rc=$?
  expect_code 0 "$rc" "teardown should release the real pushed copy"$'\n'"$out"
  [ "$(meta_field "$dir" rr15 worktree)" = "$dir/home/state/rr15.released-copy" ] || fail "teardown did not release the record"
  [ "$(meta_field "$dir" rr15 released_head)" = "$head" ] || fail "teardown recorded the wrong head"
  [ "$(backlog_held "$dir" rr15)" = yes ] || fail "teardown did not apply its merge hold"
  git -C "$dir/proj" show-ref --verify --quiet refs/heads/fm/rr15 && fail "teardown left the task branch checked out"
  out=$(run_control "$dir" rr15 relaunch --note "after real release"); rc=$?
  expect_code 0 "$rc" "relaunch should consume teardown's record and hold"$'\n'"$out"
  [ "$(meta_field "$dir" rr15 worktree)" = "$slot" ] || fail "the round trip did not allocate the slot"
  [ "$(git -C "$slot" symbolic-ref --short HEAD)" = fm/rr15 ] || fail "the round trip changed branches"
  [ "$(git -C "$slot" rev-parse HEAD)" = "$head" ] || fail "the round trip changed the head"
  [ "$(backlog_held "$dir" rr15)" = no ] || fail "the round trip did not lift the merge hold"
  [ "$(backlog_state "$dir" rr15)" = in_flight ] || fail "the round trip left the task out of flight"
  [ "$(released_note_count "$dir" rr15)" = 1 ] || fail "the round trip did not deliver exactly one progress note"
  pass "real teardown and relaunch accept matching remote aliases, preserve the branch and lift the release hold"
}


test_released_signals_roll_back_until_commit() {
  local dir backend signal stage out rc meta brief
  for backend in tmux herdr; do
    for signal in HUP TERM; do
      for stage in before-literal after-literal; do
        dir=$(new_case "released-signal-$backend-$signal-$stage" rr16)
        add_released_ship_task "$dir" rr16
        [ "$backend" != herdr ] || released_use_herdr "$dir" rr16
        printf '%s\n' "$signal" > "$dir/fake/signal"
        printf '%s\n' "$stage" > "$dir/fake/signal-stage"
        cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
if [ "${1:-}" = 0.3 ] && [ ! -e "$D/signal-sent" ]; then
  if [ "$(cat "$D/signal-stage")" = before-literal ] || [ -e "$D/launch-typed" ]; then
    : > "$D/signal-sent"
    kill -"$(cat "$D/signal")" "$PPID"
  fi
fi
exit 0
SH
        chmod +x "$dir/fakebin/sleep"
        meta=$(cat "$dir/home/state/rr16.meta")
        brief=$(cat "$dir/home/data/rr16/brief.md")
        out=$(run_control "$dir" rr16 relaunch --note "interrupted pickup"); rc=$?
        [ "$rc" -ne 0 ] || fail "$backend/$signal/$stage: the interrupted launch should fail"
        assert_present "$dir/fake/signal-sent" "the launch did not reach the signal boundary"
        assert_released_untouched "$dir" rr16 "$meta" "$brief" "$backend/$signal/$stage"
        assert_absent "$dir/pool/1/.fm-slot-owner" "the interrupted launch retained its claim"
        assert_grep "return $dir/pool/1/repo" "$dir/fake/treehouse-log" "the interrupted launch did not return its copy"
      done
    done
  done
  pass "HUP and TERM roll back released relaunches before and after literal delivery on both backends"
}

test_released_rollback_preserves_new_work_and_unconfirmed_endpoints() {
  local dir backend change out rc slot head meta brief
  for backend in tmux herdr; do
    for change in clean dirty ignored commit close-unconfirmed return-failed; do
      dir=$(new_case "released-preserve-$backend-$change" rr17)
      add_released_ship_task "$dir" rr17
      [ "$backend" != herdr ] || released_use_herdr "$dir" rr17
      slot="$dir/pool/1/repo"
      head=$(cat "$dir/fake/pr-head")
      seed_backlog "$dir" rr17 queued
      tasks-axi hold rr17 --kind external --reason "awaiting merge https://github.com/example/repo/pull/7" \
        --file "$dir/home/data/backlog.md" >/dev/null
      break_tasks_axi_start "$dir"
      meta=$(cat "$dir/home/state/rr17.meta")
      brief=$(cat "$dir/home/data/rr17/brief.md")
      printf '%s\n' "$change" > "$dir/fake/worker-change"
      (cd "$slot" && printf 'ignored-work.log\n' >> "$(git rev-parse --git-path info/exclude)")
      cat > "$dir/fake/worker-action" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
slot=$(cat "$D/treehouse-slot")
case "$(cat "$D/worker-change")" in
  dirty) printf 'new uncommitted work\n' > "$slot/work.txt" ;;
  ignored) printf 'new ignored work\n' > "$slot/ignored-work.log" ;;
  commit)
    printf 'new committed work\n' > "$slot/worker.txt"
    git -C "$slot" add worker.txt
    git -C "$slot" -c user.name=Tests -c user.email=t@t commit -qm 'new worker commit'
    git -C "$slot" rev-parse HEAD > "$D/worker-head"
    ;;
  close-unconfirmed) : > "$D/keep-endpoint-open" ;;
  return-failed) : > "$D/fail-return" ;;
esac
: > "$D/worker-ran"
SH
      chmod +x "$dir/fake/worker-action"
      out=$(run_control "$dir" rr17 relaunch --note "preserve any new work"); rc=$?
      [ "$rc" -ne 0 ] || fail "$backend/$change: the dispatch failure should fail the launch"
      assert_present "$dir/fake/worker-ran" "$backend/$change: the worker never started"
      assert_present "$dir/fake/close-attempted" "$backend/$change: rollback never attempted closure"
      [ "$(backlog_held "$dir" rr17)" = yes ] || fail "$backend/$change: rollback lost the merge hold"
      if [ "$change" = clean ]; then
        assert_released_untouched "$dir" rr17 "$meta" "$brief" "$backend clean dispatch failure"
        assert_absent "$dir/pool/1/.fm-slot-owner" "the clean copy remained claimed"
        assert_grep "return $slot" "$dir/fake/treehouse-log" "the clean copy was not returned"
      else
        [ "$(meta_field "$dir" rr17 worktree)" = "$slot" ] || fail "$backend/$change: the sentinel hid a retained copy"
        git -C "$slot" show-ref --verify --quiet refs/heads/fm/rr17 || fail "$backend/$change: the worker branch was deleted"
        if [ "$change" != return-failed ]; then
          [ "$(git -C "$slot" symbolic-ref --short HEAD)" = fm/rr17 ] || fail "$backend/$change: the worker branch was detached"
        fi
        assert_grep 'task=rr17' "$dir/pool/1/.fm-slot-owner" "$backend/$change: the retained copy lost its claim"
        if [ "$change" = return-failed ]; then
          assert_grep "return $slot" "$dir/fake/treehouse-log" "$backend: the return failure was not reached"
        else
          assert_absent "$dir/fake/treehouse-log" "$backend/$change: an unsafe copy was returned"
        fi
        assert_contains "$out" 'safe rollback was not proven' "$backend/$change: control claimed a complete rollback"
        assert_absent "$dir/home/state/rr17.control-relaunch" "$backend/$change: failure rewrote the journal"
        case "$change" in
          dirty) [ "$(cat "$slot/work.txt")" = 'new uncommitted work' ] || fail "new tracked work was lost" ;;
          ignored) [ "$(cat "$slot/ignored-work.log")" = 'new ignored work' ] || fail "new ignored work was lost" ;;
          commit)
            [ "$(git -C "$slot" rev-parse HEAD)" = "$(cat "$dir/fake/worker-head")" ] || fail "new commits were lost"
            [ "$(git -C "$slot" rev-parse HEAD)" != "$head" ] || fail "the commit fixture was vacuous"
            ;;
          close-unconfirmed) assert_present "$slot/.claude/settings.local.json" "live worker wiring was retired" ;;
        esac
      fi
    done
  done
  pass "rollback returns only proven clean copies and retains new work or unconfirmed endpoints on both backends"
}

test_released_signals_defer_through_mutation_bookkeeping() {
  local dir backend signal boundary out rc meta brief real_mv real_tasks
  real_mv=$(command -v mv)
  real_tasks=$(command -v tasks-axi)
  for backend in tmux herdr; do
    for signal in HUP TERM; do
      for boundary in endpoint claim unhold; do
        dir=$(new_case "released-mutation-$backend-$signal-$boundary" rr18)
        add_released_ship_task "$dir" rr18
        [ "$backend" != herdr ] || released_use_herdr "$dir" rr18
        seed_backlog "$dir" rr18 queued
        tasks-axi hold rr18 --kind external --reason 'awaiting merge https://github.com/example/repo/pull/7' \
          --file "$dir/home/data/backlog.md" >/dev/null
        printf '%s\n' "$signal" > "$dir/fake/signal"
        cat > "$dir/fake/signal-spawn" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
[ ! -e "$D/signal-sent" ] || exit 0
pid=$PPID
target=
while [ "$pid" -gt 1 ]; do
  args=$(ps -p "$pid" -o args=)
  case "$args" in
    *'/bin/fm-spawn.sh rr18 --relaunch'*) target=$pid ;;
    *) [ -z "$target" ] || break ;;
  esac
  pid=$(ps -p "$pid" -o ppid= | tr -d ' ')
done
[ -n "$target" ] || exit 1
: > "$D/signal-sent"
kill -"$(cat "$D/signal")" "$target"
SH
        chmod +x "$dir/fake/signal-spawn"
        case "$boundary" in
          endpoint) cp "$dir/fake/signal-spawn" "$dir/fake/signal-endpoint" ;;
          claim)
            cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
"$real_mv" "\$@" || exit \$?
case "\${!#}" in */.fm-slot-owner) "\$FM_FAKE_DIR/signal-spawn" ;; esac
exit 0
SH
            chmod +x "$dir/fakebin/mv"
            ;;
          unhold)
            cat > "$dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
"$real_tasks" "\$@" || exit \$?
[ "\${1:-}" != unhold ] || "\$FM_FAKE_DIR/signal-spawn"
exit 0
SH
            chmod +x "$dir/fakebin/tasks-axi"
            ;;
        esac
        meta=$(cat "$dir/home/state/rr18.meta")
        brief=$(cat "$dir/home/data/rr18/brief.md")
        out=$(run_control "$dir" rr18 relaunch --note 'interrupted mutation'); rc=$?
        [ "$rc" -ne 0 ] || fail "$backend/$signal/$boundary: interrupted relaunch succeeded"
        assert_present "$dir/fake/signal-sent" "$backend/$signal/$boundary: mutation was not reached"
        assert_released_untouched "$dir" rr18 "$meta" "$brief" "$backend/$signal/$boundary"
        assert_present "$dir/fake/close-attempted" "$backend/$signal/$boundary: endpoint was leaked"
        assert_absent "$dir/pool/1/.fm-slot-owner" "$backend/$signal/$boundary: slot claim was leaked"
        [ "$(backlog_held "$dir" rr18)" = yes ] || fail "$backend/$signal/$boundary: merge hold was lost"
        if [ "$boundary" != endpoint ]; then
          assert_grep "return $dir/pool/1/repo" "$dir/fake/treehouse-log" "$backend/$signal/$boundary: copy was not returned"
        fi
      done
    done
  done
  pass "HUP and TERM wait for endpoint, claim and unhold bookkeeping on both backends"
}

test_released_rollback_retains_each_failed_restoration_backup() {
  local dir restoration out rc meta brief real_cp real_mv backup count
  real_cp=$(command -v cp)
  real_mv=$(command -v mv)
  for restoration in record brief; do
    dir=$(new_case "released-restore-$restoration" rr19)
    add_released_ship_task "$dir" rr19
    meta=$(cat "$dir/home/state/rr19.meta")
    brief=$(cat "$dir/home/data/rr19/brief.md")
    : > "$dir/fake/fail-launch-enter"
    if [ "$restoration" = record ]; then
      cat > "$dir/fakebin/mv" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    */.rr19.meta-prior.*) : > "\$FM_FAKE_DIR/restore-attempted"; exit 1 ;;
  esac
done
exec "$real_mv" "\$@"
SH
      chmod +x "$dir/fakebin/mv"
    else
      cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${2:-}" in
  */.rr19.brief-prior.*) : > "\$FM_FAKE_DIR/restore-attempted"; exit 1 ;;
esac
exec "$real_cp" "\$@"
SH
      chmod +x "$dir/fakebin/cp"
    fi
    out=$(run_control "$dir" rr19 relaunch --note 'restore failure'); rc=$?
    [ "$rc" -ne 0 ] || fail "$restoration: delivery failure succeeded"
    assert_present "$dir/fake/restore-attempted" "$restoration: restoration failure was not reached"
    count=0
    for backup in "$dir/home/state/.rr19.meta-prior."* "$dir/home/state/.rr19.brief-prior."*; do
      [ -f "$backup" ] || continue
      count=$((count + 1))
      if [ "$restoration" = record ]; then
        [ "$(cat "$backup")" = "$meta" ] || fail "the retained record backup changed"
      else
        [ "$(cat "$backup")" = "$brief" ] || fail "the retained brief backup changed"
      fi
      assert_contains "$out" "$backup" 'the warning did not identify the retained backup'
    done
    [ "$count" = 1 ] || fail "$restoration: expected only the failed restoration's backup, found $count"
    if [ "$restoration" = record ]; then
      [ "$(cat "$dir/home/data/rr19/brief.md")" = "$brief" ] || fail 'the independent brief restoration failed'
    else
      [ "$(cat "$dir/home/state/rr19.meta")" = "$meta" ] || fail 'the independent record restoration failed'
    fi
  done
  pass "each rollback backup survives its own restoration failure independently"
}

test_released_journal_publishes_its_staged_note_after_success() {
  local dir out rc note_file
  dir=$(new_case released-journal-note rr20)
  add_released_ship_task "$dir" rr20
  note_file="$dir/home/state/rr20.control-relaunch.note"
  printf 'earlier note\n' > "$note_file"
  : > "$dir/fake/fail-launch-enter"
  out=$(run_control "$dir" rr20 relaunch --note 'current pickup'); rc=$?
  [ "$rc" -ne 0 ] || fail 'the failed launch succeeded'
  [ "$(cat "$note_file")" = 'earlier note' ] || fail 'failed launch replaced the durable note'
  rm "$dir/fake/fail-launch-enter"
  out=$(run_control "$dir" rr20 relaunch --note 'current pickup'); rc=$?
  expect_code 0 "$rc" "the retry should publish its note: $out"
  [ "$(journal_field "$dir" rr20 note_file)" = "$note_file" ] || fail 'journal points at another note'
  [ "$(cat "$note_file")" = 'current pickup' ] || fail 'completed journal references an absent or stale note'
  [ "$(journal_field "$dir" rr20 phase)" = complete ] || fail 'the relaunch did not complete'
  pass "failed launch preserves the prior note and completed relaunch publishes the journal's current note"
}

test_released_snapshot_signals_preserve_complete_brief_and_record() {
  local dir backend signal snapshot completion out rc meta brief real_cp
  real_cp=$(command -v cp)
  for backend in tmux herdr; do
    for signal in HUP TERM; do
      for snapshot in brief meta; do
        for completion in complete partial; do
          dir=$(new_case "released-snapshot-$backend-$signal-$snapshot-$completion" rr21)
          add_released_ship_task "$dir" rr21
          [ "$backend" != herdr ] || released_use_herdr "$dir" rr21
          meta=$(cat "$dir/home/state/rr21.meta")
          brief=$(cat "$dir/home/data/rr21/brief.md")
          cat > "$dir/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\${!#}" in
  */.rr21.$snapshot-prior.*)
    if [ ! -e "\$FM_FAKE_DIR/snapshot-interrupted" ]; then
      : > "\$FM_FAKE_DIR/snapshot-interrupted"
      printf 'incomplete snapshot\\n' > "\${!#}"
      kill -$signal "\$PPID"
      [ "$completion" != partial ] || exit 1
    fi
    ;;
esac
exec "$real_cp" "\$@"
SH
          chmod +x "$dir/fakebin/cp"
          out=$(run_control "$dir" rr21 relaunch --note 'snapshot interrupted'); rc=$?
          [ "$rc" -ne 0 ] || fail "$backend/$signal/$snapshot: interrupted snapshot launched a worker"
          assert_present "$dir/fake/snapshot-interrupted" "$backend/$signal/$snapshot: snapshot boundary was not reached"
          assert_released_untouched "$dir" rr21 "$meta" "$brief" "$backend/$signal/$snapshot"
          assert_absent "$dir/fake/created-windows" 'snapshot interruption opened an endpoint'
          assert_absent "$dir/fake/herdr-created-tabs" 'snapshot interruption opened a pane'
          assert_absent "$dir/pool/1/.fm-slot-owner" 'snapshot interruption claimed a copy'
        done
      done
    done
  done
  pass "HUP and TERM during complete or partial snapshots preserve the brief and record on both backends"
}

# Reuse these hermetic fixtures in the pending-proof lifecycle regression.
[ "${FM_TEST_FIXTURE_IMPORT:-}" != "control-relaunch" ] || return 0

test_reboot_recovery_uses_the_real_control_and_spawn_paths
test_tmux_absence_needs_prior_boot_evidence
test_recovery_respects_reconciled_run_ownership

test_recovery_relaunches_the_prevalidation_done_handoff
test_serial_recovery_rereads_capacity_before_each_launch

test_recovery_rechecks_eligibility_after_manual_relaunch
test_recovery_eligibility_holds_the_lifecycle_lock
test_recovery_rechecks_task_records_and_work

test_relaunch_off_opencode_removes_tracked_wiring
test_exit_and_relaunch_remove_the_dialog_file
test_exit_removes_the_dialog_file_before_releasing_the_lock

test_same_harness_relaunch_keeps_identity_and_reuses_the_endpoint
test_relaunch_refuses_before_exit_when_the_composer_holds_pending_text
test_relaunch_refuses_before_exit_when_the_composer_state_is_unproven
test_relaunch_from_linked_home_preserves_recorded_worktree
test_relaunch_preserves_durable_task_metadata
test_relaunched_conflict_replacement_exit_wakes_once
test_relaunch_serializes_concurrent_durable_metadata_publication
test_disabled_relaunch_clears_prior_trace_context
test_relaunch_appends_the_progress_note_to_the_instructions
test_relaunch_note_inbox_listing_is_safe_on_empty_inbox
test_relaunch_requires_a_note_for_a_ship_task
test_harness_switch_moves_the_record_and_clears_prior_wiring
test_refused_relaunch_onto_polytoken_keeps_the_project_hook_layer
test_refused_polytoken_profile_leaves_the_running_agent
test_relaunch_from_a_raw_polytoken_launch_keeps_the_project_layers
test_harness_switch_does_not_carry_the_old_profile_axes
test_harness_switch_resolves_a_prefixed_recorded_harness
test_prefixed_recorded_harness_requires_explicit_replacement
test_same_harness_relaunch_keeps_the_profile_axes
test_native_ultra_relaunch_preserves_profile_and_rejects_before_stop
test_signed_out_worker_account_pin_refuses_before_stop
test_worker_account_pin_follows_the_relaunch
test_secondmate_account_pin_follows_relaunch_and_refuses_before_stop
test_pi_exclude_tools_follow_the_relaunch
test_exclude_tools_refusals_happen_before_the_agent_stops
test_quota_gate_refuses_an_explicit_relaunch_before_the_agent_stops
test_secondmate_quota_relaunch_names_a_supported_alternative
test_quota_override_relaunches_and_is_recorded
test_explicit_model_wins_over_the_recorded_one
test_relaunch_onto_an_unverified_harness_is_refused
test_prior_harness_turnend_registry_entry_is_cleared
test_wiring_removal_failure_refuses_before_replacement_arm
test_turnend_auth_paths_are_owned_by_the_control_adapter
test_secondmate_relaunch_picks_up_the_configured_harness_pin
test_secondmate_claude_relaunch_keeps_local_settings
test_secondmate_relaunch_lands_on_the_per_mate_pin
test_secondmate_relaunch_uses_the_default_for_an_unpinned_mate
test_secondmate_relaunch_with_a_legacy_pin_file_uses_the_first_line
test_secondmate_relaunch_refuses_an_unreadable_configured_pin_before_stop
test_secondmate_relaunch_ignores_invalid_configured_effort_before_stop
test_secondmate_relaunch_onto_a_crewmate_only_adapter_refuses_before_stop
test_explicit_secondmate_harness_ignores_configured_profile_axes
test_ship_relaunch_ignores_the_crew_harness_config
test_spawn_relaunch_without_a_harness_reuses_the_recorded_one
test_spawn_relaunch_of_promoted_scout_uses_the_recorded_branch
test_promoted_scout_relaunch_receives_the_current_delivery_contract
test_released_scout_promotes_and_relaunches_into_its_kept_copy
test_prefixed_prior_harness_wiring_is_still_retired
test_muse_session_binding_is_retired_on_a_harness_switch
test_cursor_session_binding_is_retired_on_a_harness_switch
test_missing_worktree_refuses_before_stopping_anything
test_missing_instructions_refuse_before_stopping_anything
test_checkpoint_refusal_leaves_the_record_byte_identical
test_checkpoint_refuses_uninspectable_head_and_status
test_launch_failure_keeps_the_prior_record_and_reports_it
test_prepublication_failure_keeps_concurrent_durable_metadata
test_post_publication_launch_failure_keeps_the_new_record
test_stop_transport_failure_reconciles_a_dead_agent
test_complete_journal_failure_rolls_back_from_durable_phase
test_prepublication_abort_retires_replacement_wiring_and_busy_state
test_journal_records_the_checkpoint_it_proved
test_secondmate_relaunch_checkpoints_child_work_and_spares_the_charter
test_secondmate_relaunch_refuses_an_unmarked_home
test_secondmate_checkpoint_refuses_unreadable_child_state
test_secondmate_checkpoint_ignores_a_vanished_scratch_find_walk
test_concurrent_relaunch_is_refused
test_direct_spawn_relaunch_participates_in_the_lifecycle_lock
test_promotion_participates_in_the_lifecycle_lock_before_metadata_resolution
test_spawn_relaunch_refuses_a_live_agent
test_spawn_relaunch_refuses_a_symlinked_task_record_before_inspection
test_spawn_relaunch_keeps_its_early_meta_lock_continuous
test_spawn_relaunch_refuses_a_pending_authoritative_close
test_spawn_relaunch_refuses_contradicting_flags
test_spawn_relaunch_refuses_an_unrecorded_task
test_spawn_relaunch_refuses_a_pane_outside_the_worktree
test_tmux_refuses_a_window_missing_from_its_session
test_tmux_refuses_a_session_that_cannot_be_found
test_tmux_refuses_when_the_server_is_gone
test_reclaim_refuses_an_unreadable_endpoint
test_herdr_relaunch_resumes_only_the_registered_pi_session
test_herdr_reclaim_adopts_a_pane_that_outlived_its_server
test_herdr_exit_reports_already_stopped_when_the_pane_outlived_its_server
test_herdr_rebind_stays_in_the_recorded_session
test_herdr_reclaim_refuses_an_agent_that_came_back
test_herdr_reclaim_keeps_the_task_whole
test_herdr_reclaim_of_a_secondmate_names_its_own_owner
test_herdr_rebind_failure_from_a_plain_shell_names_the_real_cause
test_relaunch_reverifies_an_already_in_flight_item_instead_of_rewriting_it
test_relaunch_moves_a_drifted_item_back_in_flight
test_away_branch_relaunch_accepts_existing_dispatchable_items
test_released_copy_relaunch_recreates_the_branch_and_notes_it_once
test_released_copy_relaunch_refuses_and_changes_nothing
test_released_copy_relaunch_returns_the_slot_when_the_branch_cannot_be_recreated
test_released_copy_relaunch_defers_without_a_free_lane
test_released_copy_relaunch_retry_adds_no_second_note
test_concurrent_released_relaunches_serialise
test_spawn_relaunch_of_a_released_copy_gates_its_endpoint
test_herdr_relaunch_of_a_released_copy_recreates_it
test_released_relaunch_lifts_only_the_merge_hold_teardown_set
test_released_copy_frees_its_seat_and_the_relaunch_holds_one
test_released_launch_delivery_failure_rolls_back
test_released_pool_exhaustion_defers
test_released_fork_branch_uses_head_repository
test_teardown_to_relaunch_round_trip
test_released_signals_roll_back_until_commit
test_released_rollback_preserves_new_work_and_unconfirmed_endpoints

test_released_signals_defer_through_mutation_bookkeeping
test_released_rollback_retains_each_failed_restoration_backup
test_released_journal_publishes_its_staged_note_after_success

test_released_snapshot_signals_preserve_complete_brief_and_record
