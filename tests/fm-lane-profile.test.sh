#!/usr/bin/env bash
# Lane profiles through the spawn boundary: default compatibility, explicit
# reductions, refusal, batch forwarding, and durable relaunch selection.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-lane-profile)

make_case() {
  local name=$1 harness=${2:-codex}
  CASE_DIR="$TMP_ROOT/$name"
  HOME_DIR="$CASE_DIR/home"
  PROJ_DIR="$CASE_DIR/project"
  WT_DIR="$CASE_DIR/wt"
  LAUNCH_LOG="$CASE_DIR/launch.log"
  PANE_LOG="$CASE_DIR/pane.log"
  FAKEBIN_DIR=$(fm_test_make_spawn_fakebin "$CASE_DIR/fake")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_test_spawn_brief "$HOME_DIR" "$name"
  fm_git_worktree "$PROJ_DIR" "$WT_DIR" "wt-$name"
  cat > "$FAKEBIN_DIR/codex" <<'CLI'
#!/usr/bin/env bash
case " $* " in
*' mcp list --json '*)
  [ "${FM_PROFILE_LIST_FAIL:-0}" = 0 ] || exit 9
  if [ "${FM_PROFILE_BY_CWD:-0}" = 1 ]; then
    if [ "${2:-}" = "$FM_PROFILE_WORKTREE" ]; then
      printf '%s\n' '[{"name":"custom_index"},{"name":"retained"}]'
    else
      printf '%s\n' '[]'
    fi
  elif [ "${FM_PROFILE_SERVERS+x}" = x ]; then
    printf '%s\n' "$FM_PROFILE_SERVERS"
  else
    printf '%s\n' '[{"name":"gitnexus"},{"name":"claude-context"},{"name":"retained"}]'
  fi
  ;;
*) printf '%s\n' "$@" ;;
esac
CLI
  chmod +x "$FAKEBIN_DIR/codex"
}

spawn_case() {
  : > "$LAUNCH_LOG"
  : > "$PANE_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" FM_FAKE_PANE_LOG="$PANE_LOG" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$@"
}

assert_refused() {
  local out=$1 status=$2 reason=$3
  [ "$status" -ne 0 ] || fail "unsafe launch accepted: $reason"
  assert_contains "$out" "$reason" "refusal should identify the lane profile problem"
  [ ! -s "$LAUNCH_LOG" ] || fail 'refusal delivered a harness launch'
  [ ! -e "$HOME_DIR/state/$CASE_NAME.meta" ] || fail 'refusal published metadata'
}

test_default() {
  local out status launch
  CASE_NAME=lane-default
  make_case "$CASE_NAME"
  out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off); status=$?
  expect_code 0 "$status" "$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" 'mcp_servers.' 'default must leave MCP settings unchanged'
  assert_grep 'lane_profile=product-code' "$HOME_DIR/state/$CASE_NAME.meta" 'default profile not recorded'
  pass 'product-code default preserves MCP launch settings'
}

test_reduced() {
  local profile kind out status launch flags
  for profile in ci-tooling governance; do
    for kind in ship scout; do
      CASE_NAME="lane-$profile-$kind"
      make_case "$CASE_NAME"
      flags=(--scout)
      [ "$kind" != ship ] || flags=(--mode local-only --yolo off)
      out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" "${flags[@]}" --lane-profile "$profile"); status=$?
      expect_code 0 "$status" "$out"
      launch=$(cat "$LAUNCH_LOG")
      assert_contains "$launch" 'mcp_servers.gitnexus.enabled=false' 'GitNexus must be disabled'
      assert_contains "$launch" 'mcp_servers.claude-context.enabled=false' 'Claude Context must be disabled'
      assert_not_contains "$launch" 'mcp_servers.retained' 'unrelated server must retain its setting'
      assert_grep "lane_profile=$profile" "$HOME_DIR/state/$CASE_NAME.meta" 'reduced profile not recorded'
    done
  done
  pass 'both reduced profiles reach Codex ship and scout launches'
}

test_unknown() {
  local profile out status
  for profile in typo '' 'governance;false'; do
    CASE_NAME="lane-unknown-$RANDOM"
    make_case "$CASE_NAME"
    out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile "$profile"); status=$?
    assert_refused "$out" "$status" 'unknown --lane-profile'
    # Each refusal must leave the same fixture available for another attempt.
  done
  pass 'unknown and empty names refuse before launch or metadata'
}

test_scope() {
  local harness out status
  for harness in claude pi pi-signed opencode grok kimi cursor gemini muse rovo omp agy devin; do
    CASE_NAME="lane-scope-$harness"
    make_case "$CASE_NAME" "$harness"
    out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
    assert_refused "$out" "$status" 'requires a canonical Codex ship/scout launch'
  done
  CASE_NAME=lane-raw
  make_case "$CASE_NAME"
  out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" 'codex --model custom' --mode local-only --yolo off --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'requires a canonical Codex ship/scout launch'
  pass 'unverified reduced-profile harness and raw routes refuse'
}

test_dependency() {
  local out status
  CASE_NAME=lane-list-down
  make_case "$CASE_NAME"
  out=$(FM_PROFILE_LIST_FAIL=1 spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'lane-profile could not read a valid Codex MCP server list'
  CASE_NAME=lane-list-garbage
  make_case "$CASE_NAME"
  out=$(FM_PROFILE_SERVERS='{}' spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'lane-profile could not read a valid Codex MCP server list'
  pass 'failed and malformed native server discovery refuse'
}

test_custom_and_absent() {
  local out status launch
  CASE_NAME=lane-custom
  make_case "$CASE_NAME"
  printf '%s\n' '# extra code-index server alias' 'custom_index' 'custom_index' > "$HOME_DIR/config/code-index-mcp-servers"
  out=$(FM_PROFILE_SERVERS='[{"name":"custom_index"},{"name":"retained"}]' spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile=ci-tooling); status=$?
  expect_code 0 "$status" "$out"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" 'mcp_servers.custom_index.enabled=false' 'configured alias was missed'
  assert_not_contains "$launch" 'mcp_servers.gitnexus' 'absent index must not get an invalid partial transport'
  assert_not_contains "$launch" 'mcp_servers.retained' 'unrelated server must survive'
  CASE_NAME=lane-other-home
  make_case "$CASE_NAME"
  out=$(FM_PROFILE_SERVERS='[{"name":"custom_index"}]' spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  expect_code 0 "$status" "$out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'mcp_servers.custom_index' 'one home must not inherit another home alias file'
  CASE_NAME=lane-no-servers
  make_case "$CASE_NAME"
  out=$(FM_PROFILE_SERVERS='[]' spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  expect_code 0 "$status" "$out"
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'mcp_servers.' 'no configured index means no override'
  pass 'additional aliases and absent servers use valid per-launch configuration'
}

test_batch() {
  local out status id1=lane-batch-a id2=lane-batch-b id
  CASE_NAME=$id1
  make_case "$CASE_NAME"
  fm_test_spawn_brief "$HOME_DIR" "$id2"
  git -C "$PROJ_DIR" worktree add --quiet -b wt-lane-batch-b "$CASE_DIR/wt-b"
  printf '%s\n' "$WT_DIR" > "$FAKEBIN_DIR/.pane-path-fm-$id1"
  printf '%s\n' "$CASE_DIR/wt-b" > "$FAKEBIN_DIR/.pane-path-fm-$id2"
  out=$(spawn_case "$id1=$PROJ_DIR" "$id2=$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  expect_code 0 "$status" "$out"
  for id in "$id1" "$id2"; do
    assert_grep 'lane_profile=governance' "$HOME_DIR/state/$id.meta" 'batch lost explicit lane profile'
  done
  pass 'batch dispatch forwards its explicit profile to every isolated task'
}

test_names_and_replay() {
  local first second out status
  CASE_NAME=lane-replay
  make_case "$CASE_NAME"
  first=$(PATH="$FAKEBIN_DIR:$PATH" bash -c '. "$1"; fm_lane_profile_flags governance codex 0 ship "$2" "$3"' _ "$ROOT/bin/fm-lane-profile-lib.sh" "$HOME_DIR/config" "$PROJ_DIR") || fail 'first profile resolution failed'
  second=$(PATH="$FAKEBIN_DIR:$PATH" bash -c '. "$1"; fm_lane_profile_flags governance codex 0 ship "$2" "$3"' _ "$ROOT/bin/fm-lane-profile-lib.sh" "$HOME_DIR/config" "$PROJ_DIR") || fail 'repeated profile resolution failed'
  [ "$first" = "$second" ] || fail 'same input must resolve to identical flags'
  printf '%s\n' 'bad.id' > "$HOME_DIR/config/code-index-mcp-servers"
  out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'requires one server ID per line'
  rm "$HOME_DIR/config/code-index-mcp-servers"
  mkdir "$HOME_DIR/config/code-index-mcp-servers"
  out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'readable regular file'
  pass 'profile replay is stable and malformed or unreadable alias sources refuse'
}

test_secondmate() {
  local out status
  CASE_NAME=lane-secondmate
  make_case "$CASE_NAME"
  out=$(spawn_case "$CASE_NAME" "$PROJ_DIR" --secondmate --lane-profile governance); status=$?
  assert_refused "$out" "$status" 'requires a canonical Codex ship/scout launch'
  pass 'reduced footprint never leaks into a secondmate primary'
}

test_worktree() {
  local out status
  CASE_NAME=lane-worktree
  make_case "$CASE_NAME"
  printf '%s\n' custom_index > "$HOME_DIR/config/code-index-mcp-servers"
  out=$(FM_PROFILE_BY_CWD=1 FM_PROFILE_WORKTREE="$WT_DIR" spawn_case "$CASE_NAME" "$PROJ_DIR" --mode local-only --yolo off --lane-profile governance); status=$?
  expect_code 0 "$status" "$out"
  assert_contains "$(cat "$LAUNCH_LOG")" 'mcp_servers.custom_index.enabled=false' 'actual worker cwd must determine configured index servers'
  assert_not_contains "$(cat "$LAUNCH_LOG")" 'mcp_servers.gitnexus' 'absent worktree server must not acquire a partial transport override'
  pass 'actual isolated worker configuration wins over the primary checkout'
}

for subject in "${@:-default reduced unknown scope dependency custom_and_absent batch names_and_replay secondmate worktree}"; do
  # Word splitting here permits the default subject list; caller-supplied names
  # are restricted to this executable's declared cases.
  for name in $subject; do
    case "$name" in
    default | reduced | unknown | scope | dependency | custom_and_absent | batch | names_and_replay | secondmate | worktree) "test_$name" ;;
    *) fail "unknown test subject: $name" ;;
    esac
  done
done
