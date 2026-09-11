#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh concrete dispatch profile flags.
#
# These tests drive fm-spawn through meta writing and launch construction with a
# fake tmux pane and a real isolated git worktree. The fake tmux captures the
# literal launch command sent with `tmux send-keys -l`, so assertions pin the
# command firstmate would run without starting any real harness.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-dispatch-profile)
FABLE_DISALLOWED_TOOLS='Task,Agent,Workflow,RemoteTrigger,Monitor,ScheduleWakeup,SendMessage,EnterWorktree,ExitWorktree,CronCreate,CronDelete,CronList,TaskCreate,TaskGet,TaskList,TaskUpdate,TaskStop,TaskOutput'

make_spawn_pi_probe() {
  local fakebin=$1 tool=$2
  cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --help ]; then
  if [ "${FM_FAKE_PI_VERSION:-0.84.0}" = 0.82.0 ]; then
    printf '%s\n' 'Pi 0.82.0' 'Options: --help --no-extensions'
  else
    printf '%s\n' "Pi ${FM_FAKE_PI_VERSION:-0.84.0}" 'Options: --help --tui-mode <mode> --no-extensions'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/$tool"
}

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
shift
exec "$@"
SH
  cat > "$fakebin/cursor-agent" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --list-models ]; then
  [ "${FM_FAKE_CURSOR_LIST_STATUS:-0}" -eq 0 ] || exit "${FM_FAKE_CURSOR_LIST_STATUS}"
  printf '%b\n' "${FM_FAKE_CURSOR_MODELS:-Available models\ncursor-grok-4.5-high - Grok 4.5 High}"
fi
exit 0
SH
  cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = mcp ] && [ "${2:-}" = list ] && [ "${3:-}" = --json ]; then
  if [ -n "${FM_FAKE_CODEX_MCP_JSON:-}" ]; then
    printf '%s\n' "$FM_FAKE_CODEX_MCP_JSON"
  else
    printf '%s\n' '[{"name":"gitnexus","enabled":true},{"name":"serena","enabled":true},{"name":"disabled-example","enabled":false}]'
  fi
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/cursor-agent" "$fakebin/codex"
  make_spawn_pi_probe "$fakebin" pi
  make_spawn_pi_probe "$fakebin" pi-signed
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 harness=$2 case_dir home proj wt fakebin launchlog id
  shift 2
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  for id in "$@"; do
    fm_test_spawn_brief "$home" "$id"
  done
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

enable_dispatch_profile() {
  local home=$1
  printf '%s\n' '{"rules":[{"when":"current events","use":{"harness":"grok","model":"grok-4","effort":"high"}}],"default":{"harness":"codex","model":"gpt-5","effort":"medium"}}' \
    > "$home/config/crew-dispatch.json"
}

make_seeded_secondmate_home() {
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$home/data/charter.md"
}

run_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4
  shift 4
  : > "$launchlog"
  # CLAUDE_CONFIG_DIR is forwarded onto claude launches by fm-spawn, so pin it
  # explicitly (empty by default) instead of leaking the invoking shell's value,
  # which would make launch assertions depend on the developer's environment.
  # A test opts in to the set case via FM_TEST_CLAUDE_CONFIG_DIR.
  CLAUDE_CONFIG_DIR="${FM_TEST_CLAUDE_CONFIG_DIR:-}" \
    FM_FAKE_LAUNCH_LOG="$launchlog" FM_FAKE_PI_VERSION="${FM_TEST_PI_VERSION:-0.84.0}" \
    FM_FAKE_CURSOR_MODELS="${FM_TEST_CURSOR_MODELS:-}" \
    FM_FAKE_CURSOR_LIST_STATUS="${FM_TEST_CURSOR_LIST_STATUS:-0}" \
    GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@"
}

# Ship spawns carry an explicit delivery contract (AGENTS.md section 7); these
# tests are about profile resolution, so they pass a fixed valid one.
run_ship_spawn() {
  run_spawn "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

write_c3_effective_brief() {  # <home> <id> <package> <proof-clause>
  local home=$1 id=$2 package=$3 proof_clause=$4
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Deliver the instruction-consumption repair so a fresh worker validates the current accepted contract.

## Firstmate spec
Consume controlled package $package and preserve unrelated work.

# Proof bar
Prep: Tier 1 - controlled package $package
Resource: one isolated shell test process
Surface: none: instruction-delivery machinery has no operator-visible surface
Journey: none: this is a machinery consumer case

$proof_clause

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

make_c3_no_mistakes_capture() {  # <fakebin>
  cat > "$1/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version 1.65.0 (65e2262)'
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = run ]; then
  if [ "${3:-}" = --help ]; then
    printf '%s\n' '      --launch-nonce string' '      --validation-generation string'
    exit 0
  fi
  if [ "${FM_FAKE_VALIDATION_CUSTODY:-released}" = pipeline-owned ]; then
    printf '%s\n' 'pipeline already owns this branch; abort and confirm custody release before another run' >&2
    exit 7
  fi
  shift 2
  intent=
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --intent) intent=${2:-}; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$intent" ] || exit 8
  printf '%s' "$intent" > "$FM_FAKE_VALIDATION_INTENT_LOG"
  printf 'run\n' >> "$FM_FAKE_VALIDATION_CALL_LOG"
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = abort ]; then
  printf 'abort\n' >> "$FM_FAKE_VALIDATION_CALL_LOG"
  exit 0
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  printf 'status\n' >> "$FM_FAKE_VALIDATION_CALL_LOG"
  # run-validation parses this before axi run, so print the real status shapes:
  # released lists no run on the branch; pipeline-owned lists the cancelled old
  # run whose unpublished pipeline commits still hold custody (terminal, so
  # run-validation proceeds and this fake's axi run refusal answers).
  case "${FM_FAKE_VALIDATION_CUSTODY:-released}" in
    pipeline-owned)
      printf 'run:\n  id: "controlled-b"\n  status: cancelled\n  head_sha: "%s"\noutcome: cancelled\ncustody: pipeline-owned\n' \
        "$(git rev-parse HEAD 2>/dev/null)" ;;
    *) printf 'current_branch: fixture\nruns_on_current_branch: 0\ncustody: %s\n' "${FM_FAKE_VALIDATION_CUSTODY:-released}" ;;
  esac
  exit 0
fi
exit 9
SH
  chmod +x "$1/no-mistakes"
}

c3_validation_command() {  # <launch-brief>
  sed -n '/^    .* run-validation --brief /{s/^    //;p;}' "$1" | tail -1
}

c3_brief_revision() {  # <effective-brief> <trusted-project-root> <fakebin>
  FM_DOD_TRUSTED_PROJECT_ROOT=$2 PATH="$3:$PATH" \
    bash -c '. "$1"; fm_brief_source_revision "$2"' _ "$ROOT/bin/fm-dod-lib.sh" "$1"
}

c3_tasks_in() {  # <home> <tasks-axi args...>
  local home=$1
  shift
  (cd "$home" && tasks-axi "$@" --file "$home/data/backlog.md")
}

c3_run_captain_hold() {  # <home> <captain-hold args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

# C3 independently proves a superseded package reaches both consumers: the
# fresh worker's real launch brief and the actual no-mistakes argv. The stale
# package command is executed after B is acknowledged and must refuse before
# the fake validator records a run, so the counterexample cannot pass merely
# because an inbox file moved to handled/.
test_c3_superseded_brief_is_consumed_by_launch_and_validation() {
  local rec a_home a_proj a_wt a_fake a_launch a_brief a_cmd a_revision
  local b_home b_proj b_wt b_fake b_launch b_brief b_cmd b_revision before_revision after_revision
  local c_home c_proj c_wt c_fake c_launch c_brief c_cmd intent captain_part calls out status head_before
  local q_home q_proj q_wt q_fake q_launch q_brief q_cmd q_answer q_show
  local send_err follow_record

  rec=$(make_spawn_case c3-package-a claude c3-worker-a)
  IFS='|' read -r _ a_home a_proj a_wt a_fake a_launch <<EOF
$rec
EOF
  make_c3_no_mistakes_capture "$a_fake"
  write_c3_effective_brief "$a_home" c3-worker-a A \
    'P-A: accepted prerequisite is schema-v1; validation evidence P1 remains valid.'
  out=$(run_spawn "$a_home" "$a_wt" "$a_fake" "$a_launch" c3-worker-a "$a_proj" claude --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "package A worker should launch"$'\n'"$out"
  a_brief="$a_home/data/c3-worker-a/launch-brief.md"
  a_cmd=$(c3_validation_command "$a_brief")
  [ -n "$a_cmd" ] || fail "package A launch did not carry the revision-bound validation command"
  a_revision=$(c3_brief_revision "$a_home/data/c3-worker-a/brief.md" "$a_proj" "$a_fake")
  assert_grep "Source revision: \`$a_revision\`" "$a_brief" \
    "package A launch did not bind its effective brief revision"
  : > "$a_home/validation-calls.log"
  PATH="$a_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$a_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$a_home/validation-calls.log" bash -c "$a_cmd" \
    || fail "package A validation command should invoke the fake validator"
  assert_grep 'schema-v1' "$a_home/validation-intent.log" \
    "package A validation input did not carry proof P"

  write_c3_effective_brief "$a_home" c3-worker-a B \
    'P-B: accepted prerequisite is schema-v2; proof P1 is invalidated and must be regenerated by this run.'
  send_err="$a_home/send.err"
  FM_HOME="$a_home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    PATH="$a_fake:$PATH" "$ROOT/bin/fm-send.sh" c3-worker-a \
    'Package B is now effective: schema-v2 replaces schema-v1 and invalidates P1.' \
    >/dev/null 2>"$send_err" || fail "package B revision should be durably enqueued"
  follow_record="$a_home/state/c3-worker-a.inbox/001.msg"
  assert_present "$follow_record" "package B revision was not persisted in the task inbox"
  mkdir -p "$a_home/state/c3-worker-a.inbox/handled"
  mv "$follow_record" "$a_home/state/c3-worker-a.inbox/handled/"
  calls=$(grep -c '^run$' "$a_home/validation-calls.log" || true)
  if out=$(PATH="$a_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$a_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$a_home/validation-calls.log" bash -c "$a_cmd" 2>&1); then
    status=0
  else
    status=$?
  fi
  expect_code 3 "$status" "acknowledged B must make A's validation receipt stale"
  assert_contains "$out" 'advisor discrepancy: effective brief revision changed' \
    "the stale validation refusal did not return the material discrepancy"
  [ "$(grep -c '^run$' "$a_home/validation-calls.log" || true)" = "$calls" ] \
    || fail "acknowledging B allowed a validation run to consume A"

  rec=$(make_spawn_case c3-package-b claude c3-worker-b)
  IFS='|' read -r _ b_home b_proj b_wt b_fake b_launch <<EOF
$rec
EOF
  make_c3_no_mistakes_capture "$b_fake"
  write_c3_effective_brief "$b_home" c3-worker-b B \
    'P-B: accepted prerequisite is schema-v2; proof P1 is invalidated and must be regenerated by this run.'
  out=$(run_spawn "$b_home" "$b_wt" "$b_fake" "$b_launch" c3-worker-b "$b_proj" claude --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "fresh package B worker should launch"$'\n'"$out"
  b_brief="$b_home/data/c3-worker-b/launch-brief.md"
  b_cmd=$(c3_validation_command "$b_brief")
  b_revision=$(c3_brief_revision "$b_home/data/c3-worker-b/brief.md" "$b_proj" "$b_fake")
  assert_grep 'schema-v2' "$b_brief" "fresh worker launch did not consume package B"
  assert_grep 'proof P1 is invalidated' "$b_brief" "fresh worker launch lost B's proof disposition"
  assert_grep "Source revision: \`$b_revision\`" "$b_brief" \
    "fresh worker launch did not bind package B"
  : > "$b_home/validation-calls.log"
  PATH="$b_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$b_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$b_home/validation-calls.log" bash -c "$b_cmd" \
    || fail "package B validation command should invoke the fake validator"
  intent=$(cat "$b_home/validation-intent.log")
  assert_contains "$intent" 'Captain intent:' "actual --intent lost its self-sufficient captain part"
  assert_contains "$intent" 'Firstmate implementation context:' "actual --intent lost its separately attributed implementation part"
  assert_contains "$intent" 'Agreed proof contract:' "actual --intent lost its agreed proof part"
  assert_contains "$intent" 'schema-v2' "actual --intent did not consume package B"
  assert_contains "$intent" 'proof P1 is invalidated' "actual --intent lost B's proof invalidation"
  assert_not_contains "$intent" 'schema-v1' "actual --intent retained superseded package A"
  assert_contains "$intent" 'Consume controlled package B' \
    "actual --intent omitted the effective Firstmate specification"
  captain_part=$(printf '%s\n' "$intent" | awk '
    /^Captain intent:$/ { emit=1; next }
    /^Firstmate implementation context:$/ { exit }
    emit { print }
  ')
  assert_not_contains "$captain_part" 'Consume controlled package B' \
    "actual --intent incorrectly attributed Firstmate specification to the captain"

  # One package-B revision is produced by a real answered captain call. W is
  # routed behind Q, then its effective brief replaces the open question with
  # the recorded answer. Moving the update to handled is deliberately followed
  # by execution of the old command: acknowledgement must not make that stale
  # question acceptable to validation.
  rec=$(make_spawn_case c3-answered-question claude c3-dependent-w)
  IFS='|' read -r _ q_home q_proj q_wt q_fake q_launch <<EOF
$rec
EOF
  command -v tasks-axi >/dev/null 2>&1 \
    || fail "C3 answered-question consumer requires tasks-axi"
  cp "$ROOT/.tasks.toml" "$q_home/.tasks.toml"
  cat > "$q_home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
  c3_tasks_in "$q_home" add c3-dependent-w "Apply the captain answer" \
    --kind ship --repo sample --start >/dev/null \
    || fail "could not create dependent work W"
  make_c3_no_mistakes_capture "$q_fake"
  write_c3_effective_brief "$q_home" c3-dependent-w A \
    'P-Q: open question: should W accept schema-v1 or schema-v2? No validation proof is eligible before the answer.'
  out=$(run_spawn "$q_home" "$q_wt" "$q_fake" "$q_launch" c3-dependent-w "$q_proj" claude --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "dependent W should launch with the open question"
  q_brief="$q_home/data/c3-dependent-w/launch-brief.md"
  q_cmd=$(c3_validation_command "$q_brief")
  : > "$q_home/validation-calls.log"

  c3_run_captain_hold "$q_home" hold c3-question-q \
    --title "Choose the accepted schema" --reason "captain schema answer pending" \
    --repo sample --origin c3-dependent-w >/dev/null \
    || fail "could not create captain-held question Q"
  c3_tasks_in "$q_home" block c3-dependent-w --by c3-question-q >/dev/null \
    || fail "could not route W behind captain-held Q"

  q_answer="$q_home/captain-answer.txt"
  printf '%s\n' 'Captain answer: W must accept schema-v2, and proof P-Q must be regenerated against schema-v2.' > "$q_answer"
  c3_run_captain_hold "$q_home" answer c3-question-q --decision-file "$q_answer" >/dev/null \
    || fail "real captain-hold answer did not resolve Q"
  q_show=$(c3_tasks_in "$q_home" show c3-question-q --full)
  assert_contains "$q_show" 'Resolution mode: answered' \
    "captain-held Q did not record the answered resolution"
  assert_contains "$q_show" 'W must accept schema-v2' \
    "captain-held Q did not retain the answer that produces package B"
  q_show=$(c3_tasks_in "$q_home" show c3-dependent-w --full)
  assert_contains "$q_show" 'blocked: no' \
    "answering Q did not release dependent work W"

  cat > "$q_home/data/c3-dependent-w/brief.md" <<'EOF'
# Task
## Captain's intent
Captain answer: W must accept schema-v2, and proof P-Q must be regenerated against schema-v2.

## Firstmate spec
Apply the recorded answer from captain-held question c3-question-q to dependent work c3-dependent-w.

# Proof bar
Prep: Tier 1 - answered captain question package B
Resource: one isolated shell test process
Surface: none: instruction-delivery machinery has no operator-visible surface
Journey: none: this is a machinery consumer case

P-B-answer: schema-v2 is accepted and the prior open-question proof is invalidated.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
  FM_HOME="$q_home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    PATH="$q_fake:$PATH" "$ROOT/bin/fm-send.sh" c3-dependent-w \
    'Captain-held Q is answered; package B replaces the open question in W.' \
    >/dev/null 2>"$q_home/send.err" \
    || fail "answered-question package B was not durably delivered to W"
  follow_record="$q_home/state/c3-dependent-w.inbox/001.msg"
  assert_present "$follow_record" "answered-question package B was not persisted"
  mkdir -p "$q_home/state/c3-dependent-w.inbox/handled"
  mv "$follow_record" "$q_home/state/c3-dependent-w.inbox/handled/"
  if out=$(PATH="$q_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$q_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$q_home/validation-calls.log" bash -c "$q_cmd" 2>&1); then
    status=0
  else
    status=$?
  fi
  expect_code 3 "$status" \
    "acknowledging the answer must not let validation retain the old question"
  assert_contains "$out" 'advisor discrepancy: effective brief revision changed' \
    "old-question validation did not refuse after the answered revision"
  [ ! -s "$q_home/validation-calls.log" ] \
    || fail "old-question control reached validation after acknowledging the answer"

  out=$(run_spawn "$q_home" "$q_wt" "$q_fake" "$q_launch" c3-dependent-w --relaunch)
  status=$?
  expect_code 0 "$status" "dependent W should relaunch from the answered package B"
  q_brief="$q_home/data/c3-dependent-w/launch-brief.md"
  q_cmd=$(c3_validation_command "$q_brief")
  assert_grep 'W must accept schema-v2' "$q_brief" \
    "W's fresh launch did not consume the captain answer"
  assert_no_grep 'should W accept schema-v1 or schema-v2' "$q_brief" \
    "W's fresh launch retained the old question"
  PATH="$q_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$q_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$q_home/validation-calls.log" bash -c "$q_cmd" \
    || fail "answered package B did not reach the actual validation consumer"
  intent=$(cat "$q_home/validation-intent.log")
  assert_contains "$intent" 'W must accept schema-v2' \
    "actual rendered intent for W omitted the captain answer"
  assert_not_contains "$intent" 'should W accept schema-v1 or schema-v2' \
    "actual rendered intent for W retained the old question"

  fm_write_meta "$b_home/state/c3-follow-up.meta" \
    'window=firstmate:fm-c3-follow-up' 'endpoint_task_id=c3-follow-up' 'kind=ship' 'harness=claude'
  calls=$(grep -c '^run$' "$b_home/validation-calls.log" || true)
  FM_HOME="$b_home" FM_ROOT_OVERRIDE="$ROOT" FM_SEND_SETTLE=0 \
    PATH="$b_fake:$PATH" "$ROOT/bin/fm-send.sh" c3-follow-up \
    'Compatible package B scope belongs to named follow-up c3-follow-up.' >/dev/null 2>&1 \
    || fail "compatible active-validation scope should reach its named follow-up"
  assert_present "$b_home/state/c3-follow-up.inbox/001.msg" \
    "compatible active-validation scope did not reach the named follow-up"
  [ "$(grep -c '^run$' "$b_home/validation-calls.log" || true)" = "$calls" ] \
    || fail "compatible follow-up scope started a competing validation run"

  head_before=$(git -C "$b_wt" rev-parse HEAD)
  if out=$(cd "$b_wt" && PATH="$b_fake:$PATH" FM_FAKE_VALIDATION_CUSTODY=pipeline-owned \
    FM_FAKE_VALIDATION_INTENT_LOG="$b_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$b_home/validation-calls.log" bash -c "$b_cmd" 2>&1); then
    status=0
  else
    status=$?
  fi
  expect_code 7 "$status" "old custody must refuse a competing validation run"
  assert_contains "$out" 'abort and confirm custody release' \
    "active-custody refusal did not name the supported sequence"
  [ "$(git -C "$b_wt" rev-parse HEAD)" = "$head_before" ] \
    || fail "the invalidating instruction changed code before custody release"
  out=$(cd "$b_wt" && PATH="$b_fake:$PATH" FM_FAKE_VALIDATION_CUSTODY=pipeline-owned \
    FM_FAKE_VALIDATION_CALL_LOG="$b_home/validation-calls.log" no-mistakes axi status) \
    || fail "supported validation status should report custody"
  assert_contains "$out" 'pipeline-owned' \
    "status did not confirm the old validation run still owned custody"
  (cd "$b_wt" && PATH="$b_fake:$PATH" FM_FAKE_VALIDATION_CALL_LOG="$b_home/validation-calls.log" \
    no-mistakes axi abort --run controlled-b) || fail "supported validation abort should succeed"
  printf '%s\n' 'working: validation aborted; custody returned before package refresh' \
    >> "$b_home/state/c3-worker-b.status"
  [ "$(grep -c '^run$' "$b_home/validation-calls.log" || true)" = "$calls" ] \
    || fail "abort/status/custody handling started another run under old custody"

  before_revision=$(c3_brief_revision "$b_home/data/c3-worker-b/brief.md" "$b_proj" "$b_fake")
  printf '%s\n' unrelated > "$b_wt/unrelated-main-change.txt"
  git -C "$b_wt" add unrelated-main-change.txt
  git -C "$b_wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm 'test: unrelated main movement'
  after_revision=$(c3_brief_revision "$b_home/data/c3-worker-b/brief.md" "$b_proj" "$b_fake")
  [ "$before_revision" = "$after_revision" ] \
    || fail "an unrelated repository commit invalidated package B"
  [ "$(grep -c '^run$' "$b_home/validation-calls.log" || true)" = "$calls" ] \
    || fail "an unrelated repository commit triggered a fresh pipeline"

  write_c3_effective_brief "$b_home" c3-worker-b C \
    'P-C: accepted prerequisite is schema-v3; only the schema consumer must renew proof.'
  if out=$(PATH="$b_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$b_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$b_home/validation-calls.log" bash -c "$b_cmd" 2>&1); then
    status=0
  else
    status=$?
  fi
  expect_code 3 "$status" "material package C must invalidate B's receipt"
  assert_contains "$out" 'advisor discrepancy' "material clause drift did not reach the advisor discrepancy path"

  rec=$(make_spawn_case c3-package-c claude c3-worker-c)
  IFS='|' read -r _ c_home c_proj c_wt c_fake c_launch <<EOF
$rec
EOF
  make_c3_no_mistakes_capture "$c_fake"
  write_c3_effective_brief "$c_home" c3-worker-c C \
    'P-C: accepted prerequisite is schema-v3; only the schema consumer must renew proof.'
  out=$(run_spawn "$c_home" "$c_wt" "$c_fake" "$c_launch" c3-worker-c "$c_proj" claude --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "named refreshed package C should launch"$'\n'"$out"
  c_brief="$c_home/data/c3-worker-c/launch-brief.md"
  c_cmd=$(c3_validation_command "$c_brief")
  : > "$c_home/validation-calls.log"
  PATH="$c_fake:$PATH" FM_FAKE_VALIDATION_INTENT_LOG="$c_home/validation-intent.log" \
    FM_FAKE_VALIDATION_CALL_LOG="$c_home/validation-calls.log" bash -c "$c_cmd" \
    || fail "named package C should become eligible after its launch checks"
  assert_grep 'schema-v3' "$c_home/validation-intent.log" \
    "package C validation did not carry its objective applicability clause"
  assert_no_grep 'schema-v2' "$c_home/validation-intent.log" \
    "package C validation retained package B's affected clause"
  pass "C3: superseded instructions bind both the fresh worker launch and actual validation intent"
}

assert_meta_profile() {
  local meta=$1 harness=$2 model=$3 effort=$4
  assert_grep "harness=$harness" "$meta" "meta missing harness=$harness"
  assert_grep "model=$model" "$meta" "meta missing model=$model"
  assert_grep "effort=$effort" "$meta" "meta missing effort=$effort"
}

assert_meta_mcp() {
  local meta=$1 mode=$2
  assert_grep "mcp=$mode" "$meta" "meta missing mcp=$mode"
}

# Execute a rendered Claude command against a fake CLI which applies the
# installed CLI's documented `--disallowedTools <tools...>` variadic arity.
# A zero result proves the encoded launch brief remained a positional instead
# of being consumed as one more denied-tool name.
claude_rendered_command_keeps_brief_positional() {
  local fakebin=$1 launch=$2 expected_brief=$3 result_log=$4
  cat > "$fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
consume_denied=0
denied=
prompt_seen=0
for arg in "$@"; do
  if [ "$consume_denied" -eq 1 ]; then
    case "$arg" in
      -*) consume_denied=0 ;;
      *)
        if [ -z "$denied" ]; then
          denied=$arg
        else
          denied="$denied $arg"
        fi
        continue
        ;;
    esac
  fi
  case "$arg" in
    --disallowedTools) consume_denied=1 ;;
    --disallowedTools=*) denied=${arg#--disallowedTools=} ;;
    "$FM_FAKE_EXPECTED_BRIEF") prompt_seen=1 ;;
  esac
done
printf 'prompt_seen=%s\ndenied=%s\n' "$prompt_seen" "$denied" > "$FM_FAKE_CLAUDE_PARSE_LOG"
[ "$prompt_seen" -eq 1 ]
SH
  chmod +x "$fakebin/claude"
  FM_FAKE_EXPECTED_BRIEF="$expected_brief" FM_FAKE_CLAUDE_PARSE_LOG="$result_log" \
    PATH="$fakebin:$PATH" bash -c "$launch"
}

# Independently proves the public flag contract: ships default lean, scouts
# retain the full-service launch, and either kind can choose the other mode.
test_mcp_mode_resolves_from_kind_and_explicit_flag() {
  local rec id out status launch

  id=mcp-default-ship-z20
  rec=$(make_spawn_case mcp-default-ship claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "default ship MCP mode should launch"
  assert_meta_mcp "$HOME_DIR/state/$id.meta" lean
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--strict-mcp-config" "default ship did not render Claude's lean MCP boundary"
  assert_contains "$launch" "--setting-sources 'local'" "default ship did not exclude user and project Claude settings"

  id=mcp-default-scout-z21
  rec=$(make_spawn_case mcp-default-scout claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 0 "$status" "default scout MCP mode should launch"
  assert_meta_mcp "$HOME_DIR/state/$id.meta" full
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--strict-mcp-config" "default scout unexpectedly lost its MCP servers"
  assert_not_contains "$launch" "--setting-sources" "default scout unexpectedly lost its configured settings"

  id=mcp-full-ship-z22
  rec=$(make_spawn_case mcp-full-ship claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mcp full)
  status=$?
  expect_code 0 "$status" "explicit full-service ship should launch"
  assert_meta_mcp "$HOME_DIR/state/$id.meta" full
  assert_not_contains "$(cat "$LAUNCH_LOG")" "--strict-mcp-config" "--mcp full still rendered a lean launch"

  id=mcp-lean-scout-z23
  rec=$(make_spawn_case mcp-lean-scout claude "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout --mcp lean)
  status=$?
  expect_code 0 "$status" "explicit lean scout should launch"
  assert_meta_mcp "$HOME_DIR/state/$id.meta" lean
  assert_contains "$(cat "$LAUNCH_LOG")" "--strict-mcp-config" "--mcp lean did not render a lean scout launch"
  pass "--mcp resolves lean ships, full scouts, and explicit overrides"
}

# Proves invalid values fail before any endpoint or task metadata is created.
test_mcp_mode_rejects_unknown_value_before_spawn() {
  local rec id out status
  id=mcp-invalid-z24
  rec=$(make_spawn_case mcp-invalid claude "$id")
  read_case_record "$rec"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --mcp enormous)
  status=$?
  expect_code 1 "$status" "unknown MCP mode should refuse"
  assert_contains "$out" "--mcp must be one of lean, full" "invalid MCP mode diagnostic omitted the accepted values"
  assert_absent "$HOME_DIR/state/$id.meta" "invalid MCP mode wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "invalid MCP mode created an endpoint launch"
  pass "--mcp rejects unknown values before spawn"
}

# Each controllable adapter gets an independently rendered launch assertion.
# Gemini's boundary is carried in its Firstmate-owned settings sidecar rather
# than argv, so that file is asserted directly.
test_lean_mcp_renders_each_firstmate_controlled_harness() {
  local harness rec id out status launch settings
  for harness in claude codex pi pi-signed gemini; do
    id="mcp-render-$harness-z25"
    rec=$(make_spawn_case "mcp-render-$harness" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness lean ship should launch"
    assert_meta_mcp "$HOME_DIR/state/$id.meta" lean
    launch=$(cat "$LAUNCH_LOG")
    case "$harness" in
      claude)
        assert_contains "$launch" "--mcp-config '{\"mcpServers\":{}}' --strict-mcp-config" "Claude lean launch did not replace configured MCP servers"
        ;;
      codex)
        assert_contains "$launch" "mcp_servers.gitnexus.enabled=false" "Codex lean launch did not disable gitnexus"
        assert_contains "$launch" "mcp_servers.serena.enabled=false" "Codex lean launch did not disable serena"
        assert_not_contains "$launch" "disabled-example" "Codex lean launch rewrote an already-disabled server"
        ;;
      pi|pi-signed)
        assert_contains "$launch" "--no-extensions" "$harness lean launch did not suppress auto-loaded extensions"
        assert_contains "$launch" " -e " "$harness lean launch lost Firstmate's explicit turn-end extension"
        ;;
      gemini)
        settings="$HOME_DIR/state/$id.gemini-settings.json"
        assert_grep '"mcp":{"allowed":[]}' "$settings" "Gemini lean settings did not deny configured MCP servers"
        ;;
    esac
  done
  pass "lean MCP mode renders every Firstmate-controlled harness boundary"
}

# These verified adapters expose only user/project persistence, not a safe
# universal launch override. The test pins that Firstmate does not pretend to
# enforce lean mode by inventing unsupported flags.
test_operator_owned_mcp_harnesses_keep_verified_launch_shape() {
  local harness rec id out status launch
  for harness in opencode grok cursor; do
    id="mcp-operator-$harness-z26"
    rec=$(make_spawn_case "mcp-operator-$harness" "$harness" "$id")
    read_case_record "$rec"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 0 "$status" "$harness operator-owned MCP launch should remain usable"
    assert_meta_mcp "$HOME_DIR/state/$id.meta" lean
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--mcp-config" "$harness received an unverified MCP config flag"
    assert_not_contains "$launch" "--strict-mcp-config" "$harness received Claude's MCP flag"
    assert_not_contains "$launch" "--no-extensions" "$harness received Pi's extension flag"
    assert_contains "$out" "cannot enforce --mcp lean" "$harness did not report its operator-owned MCP boundary"
  done
  pass "operator-owned MCP adapters remain explicit and use no invented flags"
}

# Independently proves lean launch refuses when Codex cannot supply a complete
# effective-server inventory, instead of launching with unknown residents.
test_codex_lean_mcp_refuses_malformed_inventory() {
  local rec id out status
  id=mcp-codex-malformed-z27
  rec=$(make_spawn_case mcp-codex-malformed codex "$id")
  read_case_record "$rec"
  out=$(FM_FAKE_CODEX_MCP_JSON='{"not":"an array"}' \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "malformed Codex MCP inventory should refuse"
  assert_contains "$out" "unsupported shape" "Codex MCP refusal did not name the inventory problem"
  assert_absent "$HOME_DIR/state/$id.meta" "malformed Codex MCP inventory wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "malformed Codex MCP inventory launched a pane"
  pass "Codex lean MCP mode fails closed on malformed effective inventory"
}

# Independently proves Pi's version probe is a safety gate for lean mode.
test_pi_lean_mcp_refuses_without_no_extensions_support() {
  local rec id out status
  id=mcp-pi-old-z28
  rec=$(make_spawn_case mcp-pi-old pi "$id")
  read_case_record "$rec"
  cat > "$FAKEBIN_DIR/pi" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" != --help ] || printf '%s\n' 'Pi old' 'Options: --help --tui-mode <mode>'
exit 0
SH
  chmod +x "$FAKEBIN_DIR/pi"
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "Pi without --no-extensions should refuse lean mode"
  assert_contains "$out" "does not advertise --no-extensions" "Pi lean refusal omitted the missing capability"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported Pi lean mode wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported Pi lean mode launched a pane"
  pass "Pi lean MCP mode fails closed without --no-extensions support"
}

test_no_profile_keeps_claude_profile_defaults() {
  local rec id out status expected launch
  id=profile-off-z1
  rec=$(make_spawn_case profile-off claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without profile flags should succeed"
  assert_contains "$out" "spawned $id harness=claude" "spawn did not report claude"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude default default

  launch=$(cat "$LAUNCH_LOG")
  expected="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}' --setting-sources 'local' --mcp-config '{\"mcpServers\":{}}' --strict-mcp-config \"\$('${ROOT}/bin/fm-operational-input.sh' encode launch-brief < '$HOME_DIR/data/$id/launch-brief.md')\""
  [ "$launch" = "$expected" ] || fail "no-profile claude launch did not use the canonical launch kind"$'\n'"expected: $expected"$'\n'"actual:   $launch"
  pass "no --model/--effort records defaults and types the claude launch instructions"
}

test_non_cursor_launch_clears_inherited_cursor_markers() {
  local rec id out status launch
  id=profile-claude-cursor-markers-z1b
  rec=$(make_spawn_case profile-claude-cursor-markers claude "$id")
  read_case_record "$rec"

  out=$(CURSOR_AGENT=1 CURSOR_INVOKED_AS=cursor-agent \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn under Cursor markers should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI" \
    "non-cursor launch must clear both inherited Cursor identity markers"
  pass "non-cursor launches clear inherited Cursor identity markers"
}

test_relative_home_overrides_launch_with_absolute_cross_process_paths() {
  local rec id out status launch home_real
  id=profile-relative-paths-z1b
  rec=$(make_spawn_case profile-relative-paths pi "$id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)
  mkdir -p "$CASE_DIR/cdpath/home/state" "$CASE_DIR/cdpath/home/data"
  : > "$LAUNCH_LOG"

  out=$(
    cd "$CASE_DIR" || exit 1
    CDPATH="$CASE_DIR/cdpath" FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=home/data \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative home overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$id.pi-ext.ts'" \
    "relative FM_STATE_OVERRIDE leaked into Pi's cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$id/launch-brief.md'" \
    "relative FM_DATA_OVERRIDE leaked into the cross-process brief path"
  pass "relative home overrides ignore CDPATH and become absolute before spawn launch construction"
}

test_home_defaults_preserve_absolute_or_resolve_relative_paths() {
  local rec relative_id absolute_id out status launch home_real linked_home
  relative_id=profile-relative-home-defaults-z1c
  absolute_id=profile-absolute-home-defaults-z1d
  rec=$(make_spawn_case profile-home-defaults pi "$relative_id" "$absolute_id")
  read_case_record "$rec"
  home_real=$(cd "$HOME_DIR" && pwd -P)

  : > "$LAUNCH_LOG"
  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE=home/projects FM_CONFIG_OVERRIDE=home/config \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME=home/grok-home PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$relative_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with relative FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$home_real/state/$relative_id.pi-ext.ts'" \
    "relative FM_HOME leaked into Pi's default cross-process extension path"
  assert_contains "$launch" "< '$home_real/data/$relative_id/launch-brief.md'" \
    "relative FM_HOME leaked into the default cross-process brief path"

  # This path-format test intentionally performs two independent launches in
  # one synthetic worktree. Retire the first synthetic task record so the
  # worktree-ownership guard does not turn the second half into a guard test.
  rm -f "$HOME_DIR/state/$relative_id.meta"

  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"
  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$absolute_id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled FM_HOME defaults should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$absolute_id.pi-ext.ts'" \
    "absolute FM_HOME spelling changed in Pi's default cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$absolute_id/launch-brief.md'" \
    "absolute FM_HOME spelling changed in the default cross-process brief path"
  pass "FM_HOME defaults resolve relative paths and preserve absolute spellings"
}

test_absolute_override_spelling_is_preserved_in_launch_paths() {
  local rec id out status launch linked_home
  id=profile-absolute-paths-z1c
  rec=$(make_spawn_case profile-absolute-paths pi "$id")
  read_case_record "$rec"
  linked_home="$CASE_DIR/home-link"
  ln -s "$HOME_DIR" "$linked_home"
  : > "$LAUNCH_LOG"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$linked_home" \
      FM_STATE_OVERRIDE="$linked_home/state" FM_DATA_OVERRIDE="$linked_home/data" \
      FM_PROJECTS_OVERRIDE="$linked_home/projects" FM_CONFIG_OVERRIDE="$linked_home/config" \
      FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
      CLAUDE_CONFIG_DIR='' FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      GROK_HOME="$linked_home/grok-home" PATH="$FAKEBIN_DIR:$PATH" \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 0 "$status" "spawn with absolute symlink-spelled overrides should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "-e '$linked_home/state/$id.pi-ext.ts'" \
    "absolute FM_STATE_OVERRIDE spelling changed in Pi's cross-process extension path"
  assert_contains "$launch" "< '$linked_home/data/$id/launch-brief.md'" \
    "absolute FM_DATA_OVERRIDE spelling changed in the cross-process brief path"
  pass "absolute override spellings are preserved in spawn launch paths"
}

test_unresolvable_relative_overrides_fail_loudly() {
  local rec id out status
  id=profile-unresolvable-paths-z1d
  rec=$(make_spawn_case profile-unresolvable-paths pi "$id")
  read_case_record "$rec"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=missing-home \
      FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative home should fail"
  assert_contains "$out" "FM_HOME directory cannot be resolved: missing-home" \
    "spawn did not name the unresolvable FM_HOME"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=missing-state FM_DATA_OVERRIDE=home/data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative state override should fail"
  assert_contains "$out" "FM_STATE_OVERRIDE directory cannot be resolved: missing-state" \
    "spawn did not name the unresolvable FM_STATE_OVERRIDE"

  out=$(
    cd "$CASE_DIR" || exit 1
    FM_ROOT_OVERRIDE='' FM_HOME=home \
      FM_STATE_OVERRIDE=home/state FM_DATA_OVERRIDE=missing-data \
      "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn with an unresolvable relative data override should fail"
  assert_contains "$out" "FM_DATA_OVERRIDE directory cannot be resolved: missing-data" \
    "spawn did not name the unresolvable FM_DATA_OVERRIDE"
  pass "unresolvable relative spawn overrides fail with named diagnostics"
}

test_active_dispatch_profile_requires_explicit_harness_for_ship() {
  local rec id out status
  id=profile-required-ship-z11
  rec=$(make_spawn_case profile-required-ship claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 1 "$status" "ship spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "spawn did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "ship refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for ship spawns"
}

test_active_dispatch_profile_requires_explicit_harness_for_scout() {
  local rec id out status
  id=profile-required-scout-z12
  rec=$(make_spawn_case profile-required-scout claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --scout)
  status=$?
  expect_code 1 "$status" "scout spawn without explicit harness should fail when dispatch profiles are active"
  assert_contains "$out" "config/crew-dispatch.json is active - pass an explicit harness resolved from the dispatch rules" \
    "scout refusal did not explain the dispatch-profile backstop"
  assert_absent "$HOME_DIR/state/$id.meta" "scout refusal should happen before meta is written"
  pass "active crew-dispatch profile requires an explicit harness for scout spawns"
}

test_active_dispatch_profile_allows_explicit_harness() {
  local rec id out status launch
  id=profile-explicit-z13
  rec=$(make_spawn_case profile-explicit claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" --harness codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "explicit harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report explicit codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "explicit harness launch did not thread model and effort"
  pass "active crew-dispatch profile allows an explicit resolved harness"
}

test_active_dispatch_profile_allows_positional_harness() {
  local rec id out status
  id=profile-positional-z14
  rec=$(make_spawn_case profile-positional claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" codex --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "positional harness should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=codex" "spawn did not report positional codex harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  pass "active crew-dispatch profile allows the legacy positional harness form"
}

test_active_dispatch_profile_allows_raw_launch_command() {
  local rec id out status launch
  id=profile-raw-z15
  rec=$(make_spawn_case profile-raw claude "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
    "$id" "$PROJ_DIR" "custom-agent --flag")
  status=$?
  expect_code 0 "$status" "raw launch command should satisfy active dispatch-profile requirement"
  assert_contains "$out" "spawned $id harness=custom-agent" "spawn did not report raw command harness"
  assert_meta_profile "$HOME_DIR/state/$id.meta" custom-agent default default
  launch=$(cat "$LAUNCH_LOG")
  [ "$launch" = "custom-agent --flag" ] || fail "raw launch command changed"$'\n'"actual: $launch"
  pass "active crew-dispatch profile allows the raw launch-command escape hatch"
}

test_claude_threads_model_and_effort() {
  local rec id out status launch
  id=profile-claude-z2
  rec=$(make_spawn_case profile-claude claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model sonnet --effort high)
  status=$?
  expect_code 0 "$status" "claude spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude sonnet high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--strict-mcp-config --model 'sonnet' --effort 'high'" \
    "claude launch did not thread model and effort flags"
  assert_not_contains "$launch" "--tui-mode" "non-Pi launches must not receive Pi's TUI mode override"
  pass "claude receives --model and --effort profile flags"
}

# Independently proves a Fable launch keeps the operational brief outside
# Claude's variadic deny list while retaining the exact solo-launch inventory.
# It also rebuilds the swallowed-brief argument order as a counterexample and
# requires the same parser probe to fail on that old shape.
test_claude_fable_disallowed_tools_keeps_launch_brief_positional() {
  local rec id out status launch expected_brief parse_log legacy_launch
  id=profile-claude-fable-z2a
  rec=$(make_spawn_case profile-claude-fable claude "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model fable --effort high)
  status=$?
  expect_code 0 "$status" "claude/fable spawn should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" claude fable high
  launch=$(cat "$LAUNCH_LOG")
  expected_brief=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$id/launch-brief.md")
  parse_log="$CASE_DIR/claude-parse.log"

  assert_contains "$launch" "--disallowedTools='$FABLE_DISALLOWED_TOOLS'" \
    "claude/fable launch must attach the unchanged deny inventory to its option"
  if ! claude_rendered_command_keeps_brief_positional "$FAKEBIN_DIR" "$launch" "$expected_brief" "$parse_log"; then
    fail "claude/fable launch brief was consumed by --disallowedTools"
  fi
  [ "$(sed -n '1p' "$parse_log")" = 'prompt_seen=1' ] || \
    fail "claude/fable launch did not preserve the encoded brief as its own positional argument"
  [ "$(sed -n '2p' "$parse_log")" = "denied=$FABLE_DISALLOWED_TOOLS" ] || \
    fail "claude/fable launch changed the delegation-tool deny inventory"

  legacy_launch=${launch/--disallowedTools=/--disallowedTools }
  if claude_rendered_command_keeps_brief_positional "$FAKEBIN_DIR" "$legacy_launch" "$expected_brief" "$parse_log"; then
    fail "bare --disallowedTools <list> counterexample unexpectedly preserved the launch brief"
  fi
  [ "$(sed -n '1p' "$parse_log")" = 'prompt_seen=0' ] || \
    fail "bare --disallowedTools <list> counterexample did not reproduce the swallowed brief"
  pass "claude/fable deny inventory is unchanged and cannot swallow its launch brief"
}

test_claude_non_fable_models_omit_disallowed_tools() {
  local rec id out status launch model expected_brief parse_log
  for model in sonnet opus; do
    id="profile-claude-nonfable-$model-z2b"
    rec=$(make_spawn_case "profile-claude-nonfable-$model" claude "$id")
    read_case_record "$rec"

    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model "$model" --effort high)
    status=$?
    expect_code 0 "$status" "claude/$model spawn should succeed"
    launch=$(cat "$LAUNCH_LOG")
    assert_not_contains "$launch" "--disallowedTools" \
      "claude/$model launch must not carry --disallowedTools"
    expected_brief=$("$ROOT/bin/fm-operational-input.sh" encode launch-brief < "$HOME_DIR/data/$id/launch-brief.md")
    parse_log="$CASE_DIR/claude-parse.log"
    if ! claude_rendered_command_keeps_brief_positional "$FAKEBIN_DIR" "$launch" "$expected_brief" "$parse_log"; then
      fail "claude/$model launch no longer preserved its existing brief positional"
    fi
    [ "$(sed -n '2p' "$parse_log")" = 'denied=' ] || \
      fail "claude/$model launch unexpectedly gained a deny inventory"
  done
  pass "non-Fable Claude launch shape remains free of --disallowedTools"
}

test_claude_fable_allow_delegation_escape_omits_flag() {
  local rec id out status launch
  id=profile-claude-fable-allow-z2c
  rec=$(make_spawn_case profile-claude-fable-allow claude "$id")
  read_case_record "$rec"

  out=$(FM_FABLE_ALLOW_DELEGATION=1 run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model fable --effort high)
  status=$?
  expect_code 0 "$status" "claude/fable spawn under the escape should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "--disallowedTools" \
    "FM_FABLE_ALLOW_DELEGATION=1 must omit --disallowedTools"
  pass "FM_FABLE_ALLOW_DELEGATION=1 deliberately omits the solo-launch flag"
}

test_codex_threads_model_and_effort() {
  local rec id out status launch
  id=profile-codex-z3
  rec=$(make_spawn_case profile-codex codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort high)
  status=$?
  expect_code 0 "$status" "codex spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex gpt-5 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'gpt-5' -c 'model_reasoning_effort=\"high\"' --dangerously-bypass-approvals-and-sandbox" \
    "codex launch did not thread model and reasoning effort config"
  assert_not_contains "$launch" "--disallowedTools" "codex launch shape changed with Claude's Fable-only fix"
  pass "codex launch shape remains unchanged while receiving its profile flags"
}

test_codex_refuses_unsupported_max_effort_before_metadata() {
  local rec id out status launch
  id=profile-codex-max-z4
  rec=$(make_spawn_case profile-codex-max codex "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model gpt-5 --effort max)
  status=$?
  expect_code 1 "$status" "codex spawn with unsupported max effort should refuse"
  assert_contains "$out" "codex does not support requested effort max" "codex refusal did not name the unsupported effective effort"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported effort must not create misleading metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported effort must not launch Codex"
  pass "codex refuses unsupported effort before metadata"
}

test_grok_threads_model_and_reasoning_effort() {
  local rec id out status launch
  id=profile-grok-z5
  rec=$(make_spawn_case profile-grok grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort high)
  status=$?
  expect_code 0 "$status" "grok spawn with profile flags should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" grok grok-4 high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "grok --always-approve --model 'grok-4' --reasoning-effort 'high'" \
    "grok launch did not thread model and reasoning-effort flags"
  assert_not_contains "$launch" "--effort" "grok launch must use --reasoning-effort, not --effort"
  pass "grok receives --model and --reasoning-effort profile flags"
}

test_grok_refuses_unsupported_max_effort_before_metadata() {
  local rec id out status launch
  id=profile-grok-max-z6
  rec=$(make_spawn_case profile-grok-max grok "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort max)
  status=$?
  expect_code 1 "$status" "grok spawn with unsupported max reasoning effort should refuse"
  assert_contains "$out" "grok does not support requested effort max" "grok refusal did not name the unsupported effective effort"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported effort must not create misleading metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported effort must not launch Grok"
  pass "grok refuses unsupported effort before metadata"
}

test_grok_refuses_unsupported_xhigh_effort_before_metadata() {
  local rec id out status launch
  id=profile-grok-xhigh-z6b
  rec=$(make_spawn_case profile-grok-xhigh grok "$id")
  read_case_record "$rec"

  # grok 0.2.99 rejects xhigh (accepted set is only low|medium|high).
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model grok-4 --effort xhigh)
  status=$?
  expect_code 1 "$status" "grok spawn with unsupported xhigh reasoning effort should refuse"
  assert_contains "$out" "grok does not support requested effort xhigh" "grok refusal did not name the unsupported effective effort"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported effort must not create misleading metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported effort must not launch Grok"
  pass "grok refuses unsupported xhigh effort before metadata"
}

test_cursor_threads_model_workspace_and_omits_effort_axis() {
  local rec id out status launch
  id=profile-cursor-z6c
  rec=$(make_spawn_case profile-cursor cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5-high --effort high)
  status=$?
  expect_code 0 "$status" "cursor spawn with a model-qualified reasoning class should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-grok-4.5-high high
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--trust --yolo --model 'cursor-grok-4.5-high' --workspace '$WT_DIR'" \
    "cursor launch did not carry trust, autonomy, model, and exact workspace flags"
  # The executable is RESOLVED, never named: `cursor` is not the CLI, so a
  # literal `cursor agent` command cannot run on a machine that has only the
  # real installed names.
  assert_not_contains "$launch" "cursor agent --trust" \
    "cursor launch must resolve its executable, not invoke a literal 'cursor agent'"
  assert_contains "$launch" "cursor-agent" "cursor launch did not resolve a cursor executable"
  # -w/--worktree would allocate a SECOND worktree under ~/.cursor/worktrees and
  # break the isolation contract the spawn assertion depends on.
  assert_not_contains "$launch" " --worktree" "cursor launch must never allocate a second worktree"
  assert_not_contains "$launch" " -w " "cursor launch must never allocate a second worktree"
  # An inherited CLAUDECODE would otherwise outrank cursor's own marker.
  assert_contains "$launch" "env -u CLAUDECODE" "cursor launch must clear foreign primary markers"
  assert_contains "$launch" "encode launch-brief" "cursor launch did not deliver the brief positionally"
  assert_not_contains "$launch" "--effort" "cursor launch must not invent a separate effort flag"
  assert_not_contains "$launch" "--reasoning-effort" "cursor launch must not invent a separate reasoning-effort flag"
  assert_grep 'harness=cursor' "$HOME_DIR/state/$id.meta" "cursor harness was not recorded in meta"
  assert_grep 'model=cursor-grok-4.5-high' "$HOME_DIR/state/$id.meta" "cursor model was recorded as default"
  pass "cursor receives its model-qualified reasoning class and exact task workspace"
}

test_cursor_refuses_model_absent_from_live_catalog() {
  local rec id out status
  id=profile-cursor-unsupported-z6d
  rec=$(make_spawn_case profile-cursor-unsupported cursor "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model cursor-grok-4.5)
  status=$?
  expect_code 1 "$status" "cursor spawn should refuse a model absent from a successful catalog"
  assert_contains "$out" "Cursor model 'cursor-grok-4.5' is not available" \
    "cursor model refusal did not identify the unavailable model"
  assert_contains "$out" "--list-models" \
    "cursor model refusal did not tell the caller how to find valid ids"
  [ ! -s "$LAUNCH_LOG" ] || fail "cursor model refusal must happen before launch"
  pass "cursor refuses model ids absent from its resolved binary's live catalog"
}

test_cursor_failed_catalog_probe_does_not_block_spawn() {
  local rec id out status launch
  id=profile-cursor-catalog-unreachable-z6e
  rec=$(make_spawn_case profile-cursor-catalog-unreachable cursor "$id")
  read_case_record "$rec"

  FM_TEST_CURSOR_LIST_STATUS=124 \
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
      --model cursor-catalog-unreachable)
  status=$?
  expect_code 0 "$status" "cursor spawn should fail open when the bounded catalog query fails"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'cursor-catalog-unreachable'" \
    "failed catalog lookup incorrectly removed the requested model"
  assert_meta_profile "$HOME_DIR/state/$id.meta" cursor cursor-catalog-unreachable default
  pass "cursor preserves the requested model when its live catalog is unreachable"
}

test_opencode_refuses_unsupported_effort_before_metadata() {
  local rec id out status launch
  id=profile-opencode-z7
  rec=$(make_spawn_case profile-opencode opencode "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 1 "$status" "opencode spawn with unsupported effort should refuse"
  assert_contains "$out" "opencode does not support requested effort high" "opencode refusal did not name unsupported effort"
  assert_absent "$HOME_DIR/state/$id.meta" "unsupported effort must not create misleading metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "unsupported effort must not launch OpenCode"
  pass "opencode refuses unsupported effort before metadata"
}

test_pi_threads_model_and_max_effort() {
  local rec id out status launch
  id=profile-pi-z8
  rec=$(make_spawn_case profile-pi pi "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi spawn with max effort should succeed"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi '$FAKEBIN_DIR/pi' --tui-mode regular --no-extensions --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi launch did not force the regular TUI while threading the requested model and max thinking level"
  assert_not_contains "$launch" "FM_FIRSTMATE_PI_LAUNCH_BRIEF=" \
    "pi launch still exports the removed Calm input-reroute binding"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi launch lost the canonical typed launch-brief envelope"
  pass "pi receives --model and --thinking max profile flags"
}

test_pi_signed_threads_shared_pi_profile_and_preserves_identity() {
  local rec id out status launch
  id=profile-pi-signed-z8b
  rec=$(make_spawn_case profile-pi-signed pi-signed "$id")
  read_case_record "$rec"

  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model openai-codex/gpt-5.6-sol --effort max)
  status=$?
  expect_code 0 "$status" "pi-signed spawn with max effort should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed" "pi-signed spawn did not preserve its visible identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed openai-codex/gpt-5.6-sol max
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular --no-extensions --model 'openai-codex/gpt-5.6-sol' --thinking 'max' -e" \
    "pi-signed launch did not force the regular TUI with Pi's model, thinking, and extension semantics"
  assert_contains "$launch" "fm-operational-input.sh' encode launch-brief" \
    "pi-signed launch lost the canonical typed launch-brief envelope"
  assert_present "$HOME_DIR/state/$id.pi-ext.ts" "pi-signed launch did not install Pi's turn-end extension"
  assert_present "$HOME_DIR/state/$id.busy-gen" "pi-signed spawn did not arm the busy-state contract"
  assert_contains "$(cat "$HOME_DIR/state/$id.busy-state")" "state=busy source=fm-spawn" \
    "pi-signed spawn did not seed the busy-state record from the launch brief"
  local ext gen
  ext=$(cat "$HOME_DIR/state/$id.pi-ext.ts")
  gen=$(cat "$HOME_DIR/state/$id.busy-gen")
  assert_contains "$ext" 'pi.on("agent_start"' "pi extension lost the semantic agent_start busy edge"
  assert_contains "$ext" 'pi.on("agent_settled"' "pi extension lost the semantic agent_settled idle edge"
  assert_contains "$ext" 'ctx.isIdle()' "pi extension no longer confirms idle with ctx.isIdle()"
  assert_contains "$ext" "\"--gen\", \"$gen\"" "pi extension does not carry the armed incarnation gen"
  assert_contains "$ext" '"--source", "pi-ext"' "pi extension does not attribute its semantic source"
  assert_contains "$ext" 'pi.on("turn_end"' "pi extension lost the turn-end notification touch"
  pass "pi-signed shares Pi launch semantics while preserving its configured and recorded identity"
}

test_pi_tui_mode_probe_is_safe_for_old_and_new_pi() {
  local harness version rec id out status launch
  for harness in pi pi-signed; do
    for version in 0.82.0 0.84.0; do
      id="profile-${harness}-tui-${version//./}-z8d"
      rec=$(make_spawn_case "profile-__MODELFLAG__-${harness}-tui-${version//./}" "$harness" "$id")
      read_case_record "$rec"

      out=$(FM_TEST_PI_VERSION="$version" \
        run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
        "$id" "$PROJ_DIR")
      status=$?
      expect_code 0 "$status" "$harness $version spawn should succeed"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" "'$FAKEBIN_DIR/$harness'" \
        "$harness $version launch must use the executable selected for probing"
      assert_not_contains "$launch" "FM_PI_HARNESS=$harness $harness" \
        "$harness $version launch must not re-resolve a bare executable in the worker"
      if [ "$version" = 0.82.0 ]; then
        assert_not_contains "$launch" "--tui-mode" \
          "$harness $version launch must omit unsupported --tui-mode"
      else
        assert_contains "$launch" "'$FAKEBIN_DIR/$harness' --tui-mode regular" \
          "$harness $version launch must preserve the regular TUI"
      fi
    done
  done
  pass "Pi launch probing omits --tui-mode on older Pi and preserves it on supporting Pi"
}

test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata() {
  local rec id out status
  id=profile-pi-signed-missing-z8c
  rec=$(make_spawn_case profile-pi-signed-missing pi-signed "$id")
  read_case_record "$rec"
  rm -f "$FAKEBIN_DIR/pi-signed"
  : > "$LAUNCH_LOG"

  out=$(FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 1 "$status" "a missing pi-signed executable should refuse the spawn"
  assert_contains "$out" "pi-signed executable not found on PATH" \
    "missing pi-signed refusal did not name the actionable requirement"
  assert_absent "$HOME_DIR/state/$id.meta" "missing pi-signed refusal wrote task metadata"
  [ ! -s "$LAUNCH_LOG" ] || fail "missing pi-signed refusal typed a launch command"
  pass "pi-signed refuses safely and actionably when the selected executable is unavailable"
}

test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity() {
  local rec id sm out status launch
  id=profile-pi-signed-secondmate-z8d
  rec=$(make_spawn_case profile-pi-signed-secondmate codex "$id")
  read_case_record "$rec"
  printf '%s\n' pi-signed > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  sm=$(cd "$sm" && pwd -P)

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "pi-signed persistent secondmate spawn should succeed"
  assert_contains "$out" "spawned $id harness=pi-signed kind=secondmate" \
    "pi-signed secondmate spawn did not preserve its runtime identity"
  assert_meta_profile "$HOME_DIR/state/$id.meta" pi-signed default default
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "FM_PI_HARNESS=pi-signed '$FAKEBIN_DIR/pi-signed' --tui-mode regular -e '$sm/.pi/extensions/fm-primary-turnend-guard.ts' -e '$sm/.pi/extensions/fm-primary-pi-watch.ts'" \
    "pi-signed secondmate did not force the regular TUI with Pi's primary extension launch shape"
  pass "pi-signed is a distinct persistent secondmate runtime with shared Pi supervision semantics"
}

test_batch_forwards_shared_profile_and_mcp_flags() {
  local rec id1 id2 out status pane_root
  id1=profile-batch-a-z9
  id2=profile-batch-b-z10
  rec=$(make_spawn_case profile-batch claude "$id1" "$id2")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"

  pane_root="$CASE_DIR/batch-worktrees"
  git -C "$PROJ_DIR" worktree add --quiet -b "wt-$id1" "$pane_root/$id1"
  git -C "$PROJ_DIR" worktree add --quiet -b "wt-$id2" "$pane_root/$id2"

  out=$(FM_FAKE_PANE_PATH_ROOT="$pane_root" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --harness codex --model gpt-5 --effort high --mcp full)
  status=$?
  expect_code 0 "$status" "batch spawn with shared profile flags should succeed"
  assert_contains "$out" "spawned $id1 harness=codex" "first batch task did not use shared harness"
  assert_contains "$out" "spawned $id2 harness=codex" "second batch task did not use shared harness"
  assert_meta_profile "$HOME_DIR/state/$id1.meta" codex gpt-5 high
  assert_meta_profile "$HOME_DIR/state/$id2.meta" codex gpt-5 high
  assert_meta_mcp "$HOME_DIR/state/$id1.meta" full
  assert_meta_mcp "$HOME_DIR/state/$id2.meta" full
  pass "batch dispatch forwards shared --harness, --model, --effort, and --mcp to every pair"
}

test_claude_forwards_firstmate_config_dir_when_set() {
  local rec id out status launch
  id=profile-claude-cfgdir-z17
  rec=$(make_spawn_case profile-claude-cfgdir claude "$id")
  read_case_record "$rec"

  # A creatable path: this spawn now pre-registers workspace trust in that store
  # (bin/fm-claude-trust.sh), so an unwritable directory is a genuine blocker.
  # The forwarding assertion below is what this case proves and is unchanged.
  out=$(FM_TEST_CLAUDE_CONFIG_DIR="$CASE_DIR/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "CLAUDE_CONFIG_DIR='$CASE_DIR/claude-work' env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" \
    "claude launch did not forward firstmate's CLAUDE_CONFIG_DIR to the crewmate pane"
  pass "claude forwards firstmate's CLAUDE_CONFIG_DIR so the crewmate uses the same credential store"
}

test_claude_omits_config_dir_prefix_when_unset() {
  local rec id out status launch
  id=profile-claude-nocfgdir-z18
  rec=$(make_spawn_case profile-claude-nocfgdir claude "$id")
  read_case_record "$rec"

  # run_spawn pins CLAUDE_CONFIG_DIR empty by default, exercising the single-store
  # default path where fm-spawn adds no prefix.
  out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "claude spawn without CLAUDE_CONFIG_DIR should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "claude launch must not add a config-dir prefix when firstmate has no CLAUDE_CONFIG_DIR set"
  pass "claude omits the config-dir prefix when firstmate runs with the single-store default"
}

test_non_claude_harness_ignores_config_dir() {
  local rec id out status launch
  id=profile-codex-nocfgdir-z19
  rec=$(make_spawn_case profile-codex-nocfgdir codex "$id")
  read_case_record "$rec"

  out=$(FM_TEST_CLAUDE_CONFIG_DIR="/opt/test/claude-work" \
    run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
  status=$?
  expect_code 0 "$status" "codex spawn with CLAUDE_CONFIG_DIR set should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" "CLAUDE_CONFIG_DIR=" \
    "non-claude harness launch must not receive the claude-specific config-dir prefix"
  pass "non-claude harnesses do not receive the claude CLAUDE_CONFIG_DIR prefix"
}

test_active_dispatch_profile_does_not_block_secondmate_launch() {
  local rec id sm out status
  id=profile-secondmate-z16
  rec=$(make_spawn_case profile-secondmate codex "$id")
  read_case_record "$rec"
  enable_dispatch_profile "$HOME_DIR"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"

  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate spawn should be exempt from the dispatch-profile explicit harness requirement"
  assert_contains "$out" "spawned $id harness=codex kind=secondmate" "secondmate launch did not use secondmate harness resolution"
  assert_grep "kind=secondmate" "$HOME_DIR/state/$id.meta" "secondmate meta missing kind=secondmate"
  assert_meta_profile "$HOME_DIR/state/$id.meta" codex default default
  pass "active crew-dispatch profile does not block secondmate launches"
}

# Execute the emitted command in a synthetic pane environment. The fake
# backend records delivery while real shells exercise the filtering boundary;
# no developer credential value is inspected by this regression.
test_launch_environment_allowlist_filters_only_when_enabled() {
  local setting rec id out status probe result expected launch value pane_shell
  # shellcheck disable=SC2016
  value='synthetic value; $(touch SHOULD_NOT_EXIST) `false` "quoted"'
  for setting in absent missing-config enabled empty; do
    id="env-$setting"
    rec=$(make_spawn_case "$id" codex "$id")
    read_case_record "$rec"
    case "$setting" in
      missing-config) rm "$HOME_DIR/config/crew-harness"; rmdir "$HOME_DIR/config" ;;
      enabled) printf '# Synthetic name\nFM_TEST_ALLOWED\nFM_TEST_EMPTY\nFM_TEST_UNSET\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
      empty) : > "$HOME_DIR/config/launch-env-allowlist" ;;
    esac
    probe="$CASE_DIR/probe.sh"
    cat > "$probe" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "${FM_TEST_ALLOWED-unset}" \
  "${FM_TEST_EMPTY-unset}" "${FM_TEST_UNSET-unset}" "$HOME" "$PATH" "$TERM" "$TMUX" "$GOTMPDIR"
SH
    out=$(FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated \
      run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" \
      "$id" "$PROJ_DIR" --harness "/bin/sh '$probe'")
    status=$?
    expect_code 0 "$status" "allowlist=$setting spawn should succeed: $out"
    launch=$(cat "$LAUNCH_LOG")
    for pane_shell in /bin/sh /bin/bash /bin/zsh; do
      [ -x "$pane_shell" ] || continue
      result=$(env -i HOME="$HOME_DIR/user-home" PATH=/usr/bin:/bin TERM=xterm \
        TMUX=synthetic-pane GOTMPDIR=/synthetic/gotmp \
        FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED="$value" FM_TEST_EMPTY='' \
        "$pane_shell" -c "$launch") || fail "allowlist=$setting emitted launch failed in $pane_shell"
      case "$setting" in
        absent|missing-config) expected=$(printf '%s\n' synthetic-unrelated "$value" '' unset) ;;
        enabled) expected=$(printf '%s\n' unset "$value" '' unset) ;;
        empty) expected=$(printf '%s\n' unset unset unset unset) ;;
      esac
      expected="$expected"$'\n'"$HOME_DIR/user-home"$'\n/usr/bin:/bin\nxterm\nsynthetic-pane\n/synthetic/gotmp'
      [ "$result" = "$expected" ] || fail "allowlist=$setting worker environment mismatch: $result"
    done
    pass "allowlist=$setting preserves the operational floor and filters only when opted in"
  done
}

test_launch_environment_invalid_config_refuses_before_publication() {
  local rec id bad out status
  id=env-invalid
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  for bad in 'FM_TEST_ALLOWED=value' 'NAME;false' '1INVALID' '*'; do
    printf '%s\n' "$bad" > "$HOME_DIR/config/launch-env-allowlist"
    out=$(run_ship_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR")
    status=$?
    expect_code 1 "$status" "invalid allowlist must refuse spawn"
    assert_contains "$out" 'launch-env-allowlist' "refusal must identify the config file"
    [ ! -s "$LAUNCH_LOG" ] || fail "invalid allowlist delivered a launch command"
    [ ! -f "$HOME_DIR/state/$id.meta" ] || fail "invalid allowlist published a task"
  done
  pass "invalid allowlist names refuse before launch or task publication"
}

test_launch_environment_inherited_by_secondmate() {
  local rec id sm out status result
  id=env-secondmate
  rec=$(make_spawn_case "$id" codex "$id")
  read_case_record "$rec"
  printf 'FM_TEST_ALLOWED\n' > "$HOME_DIR/config/launch-env-allowlist"
  sm="$CASE_DIR/secondmate-home"
  make_seeded_secondmate_home "$sm" "$id"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$sm" --secondmate)
  status=$?
  expect_code 0 "$status" "secondmate with an allowlist should spawn: $out"
  cmp -s "$HOME_DIR/config/launch-env-allowlist" "$sm/config/launch-env-allowlist" \
    || fail "secondmate did not inherit the launch environment contract"
  cat > "$FAKEBIN_DIR/codex" <<'SH'
#!/bin/sh
printf '%s\n' "${FM_TEST_AMBIENT_SENTINEL-unset}" "$FM_TEST_ALLOWED" "$FM_HOME" "${FM_STATE_OVERRIDE-unset}"
SH
  chmod +x "$FAKEBIN_DIR/codex"
  result=$(env -i HOME="$HOME_DIR/user-home" PATH="$FAKEBIN_DIR:$PATH" \
    FM_TEST_AMBIENT_SENTINEL=synthetic-unrelated FM_TEST_ALLOWED=synthetic-provider \
    /bin/sh -c "$(cat "$LAUNCH_LOG")") || fail "secondmate's emitted command failed"
  [ "$result" = "unset"$'\nsynthetic-provider\n'"$sm" ] \
    || fail "secondmate's environment lost filtering or explicit home assignments: $result"
  if (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    rm "$HOME_DIR/config/launch-env-allowlist"
    ln -s missing-allowlist "$HOME_DIR/config/launch-env-allowlist"
    propagate_secondmate_inheritance "$HOME_DIR" "$sm" >/dev/null 2>&1
  ); then
    fail "a dangling primary allowlist was accepted as proven absence"
  fi
  [ "$(cat "$sm/config/launch-env-allowlist")" = FM_TEST_ALLOWED ] \
    || fail "source inspection failure removed or changed the inherited allowlist"
  rm "$HOME_DIR/config/launch-env-allowlist"
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-config-inherit-lib.sh"
    propagate_secondmate_inheritance "$HOME_DIR" "$sm" >/dev/null
  ) || fail "proven allowlist removal failed to converge"
  [ ! -e "$sm/config/launch-env-allowlist" ] || fail "secondmate retained a removed allowlist"
  pass "secondmate launch inherits the allowlist, preserves it on source errors, and mirrors proven release"
}

test_no_profile_keeps_claude_profile_defaults
test_c3_superseded_brief_is_consumed_by_launch_and_validation
test_mcp_mode_resolves_from_kind_and_explicit_flag
test_mcp_mode_rejects_unknown_value_before_spawn
test_lean_mcp_renders_each_firstmate_controlled_harness
test_operator_owned_mcp_harnesses_keep_verified_launch_shape
test_codex_lean_mcp_refuses_malformed_inventory
test_pi_lean_mcp_refuses_without_no_extensions_support
test_non_cursor_launch_clears_inherited_cursor_markers
test_relative_home_overrides_launch_with_absolute_cross_process_paths
test_home_defaults_preserve_absolute_or_resolve_relative_paths
test_absolute_override_spelling_is_preserved_in_launch_paths
test_unresolvable_relative_overrides_fail_loudly
test_active_dispatch_profile_requires_explicit_harness_for_ship
test_active_dispatch_profile_requires_explicit_harness_for_scout
test_active_dispatch_profile_allows_explicit_harness
test_active_dispatch_profile_allows_positional_harness
test_active_dispatch_profile_allows_raw_launch_command
test_claude_threads_model_and_effort
test_claude_fable_disallowed_tools_keeps_launch_brief_positional
test_claude_non_fable_models_omit_disallowed_tools
test_claude_fable_allow_delegation_escape_omits_flag
test_codex_threads_model_and_effort
test_codex_refuses_unsupported_max_effort_before_metadata
test_grok_threads_model_and_reasoning_effort
test_grok_refuses_unsupported_max_effort_before_metadata
test_grok_refuses_unsupported_xhigh_effort_before_metadata
test_cursor_threads_model_workspace_and_omits_effort_axis
test_cursor_refuses_model_absent_from_live_catalog
test_cursor_failed_catalog_probe_does_not_block_spawn
test_opencode_refuses_unsupported_effort_before_metadata
test_pi_threads_model_and_max_effort
test_pi_tui_mode_probe_is_safe_for_old_and_new_pi
test_pi_signed_threads_shared_pi_profile_and_preserves_identity
test_pi_signed_missing_binary_refuses_before_endpoint_or_metadata
test_pi_signed_persistent_secondmate_uses_pi_extensions_and_identity
test_batch_forwards_shared_profile_and_mcp_flags
test_claude_forwards_firstmate_config_dir_when_set
test_claude_omits_config_dir_prefix_when_unset
test_non_claude_harness_ignores_config_dir
test_active_dispatch_profile_does_not_block_secondmate_launch
test_launch_environment_allowlist_filters_only_when_enabled
test_launch_environment_invalid_config_refuses_before_publication
test_launch_environment_inherited_by_secondmate

echo "# all fm-spawn-dispatch-profile tests passed"
