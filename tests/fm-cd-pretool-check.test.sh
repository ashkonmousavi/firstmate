#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the cd-guard PreToolUse seatbelt (docs/cd-guard.md).
#
# bin/fm-cd-command-policy.mjs is the single owner of the block/allow decision;
# it reuses the shell classifier owned by bin/fm-arm-command-policy.mjs.
# bin/fm-cd-pretool-check.sh is the stable transport: it scopes the guard to the
# real primary checkout, then drives the harness entry forms. This suite
# proves the decision matrix, the harness-output shaping, the primary-checkout
# scoping (including the deliberate secondmate-home difference from the turn-end
# guard), the fail-open transport behavior, the prefilter fast path, the
# end-to-end cwd-leak regression, and the per-harness wiring. No harness is
# spawned; live per-harness evidence lives in docs/verification/runtime-backends.md.
set -u

unset FM_HOME

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-cd-pretool-check)

# A primary-shaped checkout: plain (non-worktree) git repo, AGENTS.md, bin/ with
# the transport plus both policy files (fm-cd-command-policy.mjs imports the
# shared classifier from fm-arm-command-policy.mjs). This is what the transport's
# scoping treats as the real primary firstmate checkout.
install_cd_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-pretool-check.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-cd-command-policy.mjs" "$dir/bin/fm-cd-command-policy.mjs"
  cp "$ROOT/bin/fm-arm-command-policy.mjs" "$dir/bin/fm-arm-command-policy.mjs"
  chmod +x "$dir/bin/fm-cd-pretool-check.sh" "$dir/bin/fm-cd-command-policy.mjs"
}

make_primary_fixture() {
  local dir=$1
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

# Same shape as primary plus the .fm-secondmate-home marker: a secondmate's own
# primary session, which the cd-guard DOES guard (unlike the turn-end guard).
make_secondmate_fixture() {
  local dir=$1
  make_primary_fixture "$dir" >/dev/null
  printf 'sm-cd-1\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

# A genuine linked git worktree - the shape bin/fm-spawn.sh hands crewmate/scout
# tasks. git-dir and git-common-dir differ, so the guard must be inert.
make_child_worktree_fixture() {
  local base=$1 dir=$2
  fm_git_worktree "$base" "$dir" fm/cd-guard-test-branch
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"
  printf '%s\n' "$dir"
}

PRIMARY=$(make_primary_fixture "$TMP_ROOT/primary")
CHECK="$PRIMARY/bin/fm-cd-pretool-check.sh"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()
MATRIX_CWDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
  MATRIX_CWDS+=("${4-$PRIMARY}")
}

# BLOCK: a persistent top-level cd or pushd into the home's projects folder.
# Other persistent directory changes are allowed.
matrix_case B01 deny 'cd projects/foo'
matrix_case B02 allow 'cd ..'
matrix_case B03 allow 'cd'
matrix_case B04 allow 'cd -'
matrix_case B05 allow 'cd /abs/path'
matrix_case B06 deny 'pushd projects/foo'
matrix_case B07 allow 'popd'
matrix_case B08 deny 'X=1 cd projects/foo'
matrix_case B09 deny 'cd projects/foo && tasks-axi add x'
matrix_case B10 deny 'echo before; cd projects/foo'
matrix_case B11 deny 'true && cd projects/foo'
matrix_case B12 deny 'tasks-axi done x || cd projects/foo'
matrix_case B13 deny 'cd "projects/foo"'
matrix_case B14 deny '"cd" projects/foo'
matrix_case B15 deny 'sleep 1 & cd projects/foo'
matrix_case B16 deny 'command cd projects/foo'
matrix_case B17 deny 'cd projects/foo >/dev/null'
matrix_case B18 deny $'cd projects/foo\necho done'
matrix_case B19 deny "\$'\\143d' projects/foo"
matrix_case B20 deny "c'd' projects/foo"
matrix_case B21 deny 'c"d" projects/foo'
matrix_case B22 deny 'c\d projects/foo'
matrix_case B23 deny 'builtin cd projects/foo'
matrix_case B24 deny 'command builtin cd projects/foo'
matrix_case B25 deny 'builtin command cd projects/foo'
matrix_case B26 deny 'command -p cd projects/foo'
matrix_case B27 deny 'command -- cd projects/foo'
matrix_case B28 deny 'cd projects'
matrix_case B29 deny 'cd ./projects/foo'
matrix_case B30 deny "cd '$PRIMARY/projects/foo'"

for directory_command in cd pushd; do
  matrix_case "T01-$directory_command" deny "$directory_command ~/primary/projects/foo"
  matrix_case "T02-$directory_command" deny "$directory_command ~/primary/projects/\"my clone\""
  matrix_case "T03-$directory_command" deny "$directory_command ~/primary/projects/'my clone'"
  matrix_case "T04-$directory_command" deny "$directory_command ~/primary/projects/my\\ clone"
  matrix_case "T05-$directory_command" deny "$directory_command ~/primary/projects/\$'my clone'"
  matrix_case "T06-$directory_command" allow "$directory_command \\~/primary/projects/foo"
  matrix_case "T07-$directory_command" allow "$directory_command '~/primary/projects/foo'"
  matrix_case "T08-$directory_command" allow "$directory_command \"~\"/primary/projects/foo"
  matrix_case "T09-$directory_command" allow "$directory_command ''~/primary/projects/foo"
  matrix_case "T10-$directory_command" allow "$directory_command ~\"\"/primary/projects/foo"
  matrix_case "T11-$directory_command" allow "$directory_command ~\\/primary/projects/foo"
  matrix_case "T12-$directory_command" deny "$directory_command "$'\\\n''~/primary/projects/"my clone"'
  matrix_case "T13-$directory_command" allow "$directory_command ~unknown/primary/projects/\"my clone\""
  matrix_case "T14-$directory_command" deny "$directory_command ~"$'\\\n''/primary/projects/"my clone"'
  matrix_case "T15-$directory_command" deny "$directory_command ~/primary/projects/\$\"my clone\""
  matrix_case "T16-$directory_command" allow "$directory_command \$'~'/primary/projects/foo"
  matrix_case "T17-$directory_command" allow "$directory_command \$\"~\"/primary/projects/foo"
done

# ALLOW: not a persistent top-level cwd change (scoped, data, or non-cd).
matrix_case A01 allow 'git -C projects/foo status'
matrix_case A02 allow 'cat /abs/path/file'
matrix_case A03 allow 'ls projects/foo'
matrix_case A04 allow 'echo "cd projects/foo"'
matrix_case A05 allow 'grep cd file'
matrix_case A06 allow '(cd projects/foo && pwd)'
matrix_case A07 allow "bash -c 'cd projects/foo'"
matrix_case A08 allow 'env -C projects/foo make'
matrix_case A09 allow 'make -C projects/foo build'
matrix_case A10 allow 'find . -execdir cd {} \;'
matrix_case A11 allow 'cd projects/foo | cat'
matrix_case A12 allow 'cat foo | cd bar'
matrix_case A13 allow 'cd projects/foo &'
matrix_case A14 allow 'abcd project'
matrix_case A15 allow 'cdk deploy'
matrix_case A16 allow 'env cd projects/foo'
matrix_case A17 allow 'sudo cd projects/foo'
matrix_case A18 allow 'x=$(cd foo && pwd)'
matrix_case A19 allow 'dirs'
matrix_case A20 allow "echo 'pushd x'"
matrix_case A21 allow 'git checkout main'
matrix_case A22 allow "sh -c 'cd projects/foo && ls'"
matrix_case A23 allow "printf '%s\\n' 'cd projects/foo'"
matrix_case A24 allow 'ls -la'
matrix_case A25 allow './cd projects/foo'
matrix_case A26 allow '/tmp/cd projects/foo'
matrix_case A27 allow '/usr/bin/cd projects/foo'
matrix_case A28 allow './builtin cd projects/foo'
matrix_case A29 allow 'c\d\ projects/foo'
matrix_case A30 allow './command cd projects/foo'
matrix_case A31 allow '/usr/bin/command cd projects/foo'
matrix_case A32 allow '/tmp/builtin cd projects/foo'
matrix_case A33 allow 'command -v cd'
matrix_case A34 allow 'command -V cd'
matrix_case A35 allow 'command -pv cd'
matrix_case A36 allow 'command -vp cd'
matrix_case A37 allow 'cd /tmp'
matrix_case A38 allow 'cd bin'
matrix_case A39 allow 'cd projectsfoo'

matrix_case C01 deny 'cd bin && cd ../projects/foo && tasks-axi add x'
matrix_case C02 allow 'cd projects/foo' /tmp
matrix_case C03 deny "cd '$PRIMARY/projects/foo'" /tmp
matrix_case C04 allow 'cd /tmp && cd projects/foo'
matrix_case C05 deny 'pushd bin && cd ../projects/foo'
matrix_case C06 deny 'cd bin && pushd ../projects/foo'
matrix_case C07 deny $'cd bin\ncd ../projects/foo'
matrix_case C08 allow 'cd /tmp; cd projects/foo'
matrix_case C09 deny 'cd missing-directory; cd projects/foo'
matrix_case C10 allow 'cd bin || cd projects/foo'
matrix_case C11 deny 'cd ../projects/foo' "$PRIMARY/bin"
matrix_case C12 allow 'cd projectsfoo' /tmp
matrix_case C13 allow 'cd "$TARGET" && cd projects/foo'
matrix_case C14 deny '(cd /tmp) && cd projects/foo'
matrix_case C15 deny 'cd bin & cd projects/foo'
matrix_case C16 allow 'cd projects/foo' ''
matrix_case C17 deny "cd '$PRIMARY/projects/foo'" ''
matrix_case C18 deny 'cd bin || true; cd ../projects/foo && tasks-axi add x'
matrix_case C19 deny 'cd missing-directory && true; cd projects/foo'
matrix_case C20 allow 'cd /tmp || true; cd projects/foo'
matrix_case C21 deny 'pushd bin || true; pushd ../projects/foo'
matrix_case C22 deny 'pushd missing-directory && true; pushd projects/foo'
matrix_case C23 allow 'pushd /tmp || true; pushd projects/foo'
matrix_case C24 deny 'false && cd /tmp; cd projects/foo'
matrix_case C25 deny 'true || cd /tmp; cd projects/foo'
matrix_case C26 allow 'false || cd /tmp; cd projects/foo'
matrix_case C27 deny 'false && cd /tmp || cd bin; cd ../projects/foo'
matrix_case C28 allow 'true && cd /tmp || cd bin; cd projects/foo'
matrix_case C29 deny 'cd missing-directory || cd bin; cd ../projects/foo'
matrix_case C30 deny 'true && cd bin || cd /tmp; pushd ../projects/foo'
matrix_case C31 allow 'cd /tmp && false; cd projects/foo'
matrix_case C32 deny 'false && cd bin; cd projects/foo'
matrix_case C33 allow 'cd missing-directory && cd projects/foo'
matrix_case C34 deny $'cd bin || false\ncd ../projects/foo'
matrix_case C35 allow 'command true || cd projects/foo'
matrix_case C36 allow 'false | true || cd projects/foo'
matrix_case C37 deny 'true | false || cd projects/foo'
matrix_case C38 deny 'true >missing-directory/output || cd projects/foo'
matrix_case C39 deny 'builtin false && cd /tmp; cd projects/foo'
matrix_case C40 deny 'cd "$TARGET" || cd projects/foo'

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-cd-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 cwd=$5 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" --arg cwd "$cwd" '{tool_name:"Bash",tool_input:{command:$command,workdir:$cwd},cwd:$cwd}')
      printf '%s' "$payload" | env HOME="$TMP_ROOT" "$CHECK" --codex >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" --arg cwd "$cwd" '{tool_name:"Bash",tool_input:{command:$command},cwd:$cwd}')
      printf '%s' "$payload" | env HOME="$TMP_ROOT" "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" --arg cwd "$cwd" '{toolName:"run_terminal_command",toolInput:{command:$command},cwd:$cwd}')
      printf '%s' "$payload" | env HOME="$TMP_ROOT" "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi|pi-signed|omp)
      env HOME="$TMP_ROOT" "$CHECK" --command "$cmd" --cwd "$cwd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    cursor)
      payload=$(jq -cn --arg command "$cmd" --arg cwd "$cwd" '{tool_name:"Shell",tool_input:{command:$command},cwd:$cwd,cursor_version:"fixture"}')
      printf '%s' "$payload" | env HOME="$TMP_ROOT" "$CHECK" --cursor >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  if [ "$entry" = cursor ]; then
    [ "$rc" -eq 0 ] && [ ! -s "$err_file" ] || fail "$id via cursor must return its deny object"
    jq -e '.permission == "deny" and (.user_message | test("\\[persistent-cd\\]"))' "$out_file" >/dev/null 2>&1 \
      || fail "$id via cursor must carry the persistent-cd deny object"
    return
  fi
  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[persistent-cd\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry the persistent-cd reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi pi-signed omp cursor; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}" "${MATRIX_CWDS[$i]}"
    done
  done
  pass "cd-guard acceptance matrix: ${#MATRIX_IDS[@]} cases x 8 harness entry forms, block/allow all correct"
}

# --- primary-checkout scoping ----------------------------------------------

test_fires_in_secondmate_home() {
  local dir out rc
  dir=$(make_secondmate_fixture "$TMP_ROOT/secondmate")
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' --cwd "$dir" 2>&1); rc=$?
  expect_code 2 "$rc" "cd-guard must fire in a secondmate's own primary session (unlike the turn-end guard)"
  assert_contains "$out" '[persistent-cd]' "secondmate-home block must carry the reason code"
  pass "cd-guard: fires in a secondmate home (its own primary session is a primary)"
}

test_inert_in_child_worktree() {
  local base dir out rc
  base="$TMP_ROOT/child-base"
  dir="$TMP_ROOT/child-wt"
  make_child_worktree_fixture "$base" "$dir" >/dev/null
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert in a crewmate/scout linked worktree"
  [ -z "$out" ] || fail "cd-guard produced output in a child worktree: $out"
  pass "cd-guard: inert in a crewmate/scout task worktree (linked git worktree)"
}

test_inert_when_not_firstmate_repo() {
  local dir out rc
  dir="$TMP_ROOT/not-firstmate"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  install_cd_scripts "$dir"   # bin/ present but no AGENTS.md
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert without AGENTS.md (not a firstmate checkout)"
  [ -z "$out" ] || fail "cd-guard produced output outside a firstmate checkout: $out"
  pass "cd-guard: inert in a non-firstmate repo (no AGENTS.md)"
}

test_inert_when_not_a_git_repo() {
  local dir out rc
  dir="$TMP_ROOT/no-git"
  mkdir -p "$dir"
  : > "$dir/AGENTS.md"
  install_cd_scripts "$dir"   # AGENTS.md + bin/ but no git repo
  out=$("$dir/bin/fm-cd-pretool-check.sh" --claude --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "cd-guard must be inert when the checkout is not a git repo"
  [ -z "$out" ] || fail "cd-guard produced output in a non-git dir: $out"
  pass "cd-guard: inert when not inside a git repo"
}

# --- end-to-end cwd-leak regression ----------------------------------------

test_e2e_cwd_leak_regression() {
  local sandbox home home_updated leaked out rc
  sandbox="$TMP_ROOT/e2e"
  home="$sandbox/home"
  mkdir -p "$home/data" "$home/bin" "$home/projects/clone/data"
  printf '## In flight\n' > "$home/data/backlog.md"

  # Without the guard, the persistent primary shell's cwd leaks: a stray
  # `cd projects/clone` makes the next firstmate-owned backlog write land in the
  # clone, and the home backlog is never updated.
  (
    cd "$home" || fail "cannot enter home"
    cd bin || fail "cannot enter bin"
    cd ../projects/clone || fail "cannot enter clone"
    printf -- '- [x] demo done\n' >> data/backlog.md
  )
  home_updated=0
  grep -q 'demo done' "$home/data/backlog.md" && home_updated=1
  leaked=0
  grep -q 'demo done' "$home/projects/clone/data/backlog.md" 2>/dev/null && leaked=1
  [ "$home_updated" -eq 0 ] || fail "baseline: home backlog was updated, cwd leak did not reproduce"
  [ "$leaked" -eq 1 ] || fail "baseline: backlog write did not leak into the clone"

  # With the guard, the exact stray command is denied before it can run, so the
  # real harness never lets cwd leave the home.
  out=$(FM_HOME="$home" "$CHECK" --claude --command 'cd projects/clone' --cwd "$home" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the stray persistent cd that caused the leak"
  assert_contains "$out" '[persistent-cd]' "leak-preventing block must carry the reason code"
  out=$(FM_HOME="$home" "$CHECK" --claude --command 'cd bin && cd ../projects/clone && tasks-axi add x' --cwd "$home" 2>&1); rc=$?
  expect_code 2 "$rc" "guard must deny the chained move before tasks-axi runs"
  assert_contains "$out" '[persistent-cd]' "chained leak block must carry the reason code"
  pass "cd-guard: reproduces the cwd leak and denies the exact command that causes it"
}

# --- fail-open transport behavior ------------------------------------------

test_fail_open_empty_stdin() {
  local out rc
  out=$("$CHECK" < /dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on empty stdin"
  [ -z "$out" ] || fail "transport produced output on empty stdin: $out"
  pass "cd-guard: fails open on empty stdin"
}

test_fail_open_unparseable_json() {
  local out rc
  out=$(printf 'not json at all' | "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "transport must exit 0 on unparseable stdin JSON"
  [ -z "$out" ] || fail "transport produced output on unparseable JSON: $out"
  pass "cd-guard: fails open on unparseable stdin JSON"
}

test_fail_open_missing_node() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nonode")
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # node deliberately absent from this PATH.
  out=$(PATH="$fakebin" "$CHECK" --command 'cd projects/foo' 2>&1); rc=$?
  expect_code 0 "$rc" "transport must fail open when node is unavailable"
  [ -z "$out" ] || fail "transport produced output without node: $out"
  pass "cd-guard: fails open (never blocks) when node is missing"
}

test_fail_open_missing_jq_on_stdin() {
  local fakebin tool tool_path out rc
  fakebin=$(fm_fakebin "$TMP_ROOT/nojq")
  for tool in bash sh git dirname cat printf sed tr node; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  # jq deliberately absent: the stdin transport cannot extract the command.
  out=$(printf '{"tool_input":{"command":"cd projects/foo"}}' | PATH="$fakebin" "$CHECK" 2>&1); rc=$?
  expect_code 0 "$rc" "stdin transport must fail open when jq is unavailable"
  [ -z "$out" ] || fail "transport produced output without jq on the stdin path: $out"
  pass "cd-guard: fails open on the stdin path when jq is missing"
}

# --- prefilter fast path ----------------------------------------------------

test_prefilter_skips_node_without_cd_substring() {
  local dir fakebin marker tool tool_path out rc
  dir="$TMP_ROOT/prefilter"
  make_primary_fixture "$dir" >/dev/null
  fakebin=$(fm_fakebin "$TMP_ROOT/prefilter-fake")
  marker="$TMP_ROOT/prefilter-node-called"
  for tool in bash sh git dirname cat printf sed tr jq; do
    tool_path=$(command -v "$tool") || continue
    ln -s "$tool_path" "$fakebin/$tool"
  done
  cat > "$fakebin/node" <<EOF
#!/usr/bin/env bash
: > "$marker"
exit 0
EOF
  chmod +x "$fakebin/node"
  # No cd/pushd/popd substring: the prefilter must fast-allow before scoping or
  # the policy runtime is ever consulted.
  out=$(PATH="$fakebin" "$dir/bin/fm-cd-pretool-check.sh" --command 'git status' 2>&1); rc=$?
  expect_code 0 "$rc" "prefilter must fast-allow a command with no cd/pushd/popd substring"
  [ -z "$out" ] || fail "prefilter fast-allow produced output: $out"
  [ ! -e "$marker" ] || fail "prefilter fast-allow still invoked the node policy owner"
  pass "cd-guard: prefilter fast-allows (skips node) when no cd/pushd/popd substring is present"
}

# --- policy CLI contract ----------------------------------------------------

test_policy_cli_direct() {
  local policy projects_root absolute
  policy="$ROOT/bin/fm-cd-command-policy.mjs"
  projects_root="$TMP_ROOT/policy-home/projects"
  mkdir -p "$projects_root"
  absolute="$projects_root/clone"
  [ "$(node "$policy" --command 'cd projects/foo' --projects-root "$projects_root" --cwd "${projects_root%/projects}" | cut -f1)" = deny ] \
    || fail "policy CLI must deny a bare top-level cd into projects"
  [ "$(node "$policy" --command "cd $absolute" --projects-root "$projects_root" | cut -f1)" = deny ] \
    || fail "policy CLI must deny an absolute cd under the projects root"
  [ "$(node "$policy" --command 'cd /tmp' --projects-root "$projects_root")" = allow ] \
    || fail "policy CLI must allow an absolute cd outside the projects root"
  [ "$(node "$policy" --command 'git -C projects/foo status' --projects-root "$projects_root")" = allow ] \
    || fail "policy CLI must allow git -C"
  [ "$(node "$policy" --command '(cd projects/foo && pwd)' --projects-root "$projects_root")" = allow ] \
    || fail "policy CLI must allow a subshell-local cd"
  [ "$(node "$policy" --projects-root "$projects_root")" = allow ] \
    || fail "policy CLI must allow when no command is supplied"
  [ "$(cd "${projects_root%/projects}" && node "$policy" --command 'cd projects/foo' --projects-root "$projects_root" | cut -f1)" = deny ] \
    || fail "policy CLI must use its real cwd when no override is supplied"
  pass "cd-guard: fm-cd-command-policy.mjs CLI honors the deny/allow output contract"
}

# --- per-harness wiring -----------------------------------------------------

# Delegated to bin/fm-lint.sh, the single owner of the lint definition including
# --external-sources; calling the linter directly here would be a second copy of
# that definition, and would disagree the moment this checker sourced a shared
# library.
test_cwd_adapters() {
  local config
  mkdir -p "$PRIMARY/.pi/extensions/lib" "$PRIMARY/.omp/extensions"
  cp "$ROOT/.pi/extensions/fm-primary-turnend-guard.ts" "$PRIMARY/.pi/extensions/"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$ROOT/.pi/extensions/lib/fm-sessionstart-supervisor.mjs" "$PRIMARY/.pi/extensions/lib/"
  cp "$ROOT/.omp/extensions/fm-primary-turnend-guard.ts" "$PRIMARY/.omp/extensions/"
  cp "$ROOT/bin/fm-arm-pretool-check.sh" "$PRIMARY/bin/"
  for config in .codex/hooks.json .claude/settings.json .cursor/hooks.json .grok/hooks/fm-primary-cd-check.json; do
    mkdir -p "$PRIMARY/${config%/*}"
    cp "$ROOT/$config" "$PRIMARY/$config"
  done
  FM_CD_PRIMARY="$PRIMARY" FM_CD_ROOT="$ROOT" FM_HOME="$PRIMARY" node --input-type=module <<'JS' || fail "cd-guard cwd adapter contracts"
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { pathToFileURL } from "node:url";
const primary = process.env.FM_CD_PRIMARY;
const root = process.env.FM_CD_ROOT;
const cases = [
  ["cd bin && cd ../projects/foo && tasks-axi add x", primary, true],
  ["cd projects/foo", "/tmp", false],
  ["cd '" + primary + "/projects/foo'", "/tmp", true],
  ["cd bin", primary, false],
  ["cd /tmp && cd projects/foo", primary, false],
  ["cd bin || true; cd ../projects/foo", primary, true],
  ["cd missing-directory && true; cd projects/foo", primary, true],
  ["cd /tmp || true; cd projects/foo", primary, false],
  ["pushd bin || true; pushd ../projects/foo", primary, true],
];
const { decision } = await import(pathToFileURL(root + "/bin/fm-cd-command-policy.mjs").href);
for (const [command, cwd, denied] of cases) {
  assert.equal(decision(command, primary + "/projects", cwd).decision, denied ? "deny" : "allow", "exported policy API");
}
const env = {
  ...process.env,
  CLAUDE_PROJECT_DIR: primary,
  CURSOR_PROJECT_DIR: primary,
  GROK_WORKSPACE_ROOT: primary,
  GROK_AGENT: "",
  GROK_HOOK_EVENT: "",
};
const config = (name) => JSON.parse(readFileSync(primary + "/" + name, "utf8"));
const commandHook = (hooks) => hooks.find((hook) => hook.command.includes("fm-cd-pretool-check.sh")).command;
const registrations = [
  ["claude", commandHook(config(".claude/settings.json").hooks.PreToolUse.flatMap((entry) => entry.hooks))],
  ["codex", commandHook(config(".codex/hooks.json").hooks.PreToolUse.flatMap((entry) => entry.hooks))],
  ["grok", commandHook(config(".grok/hooks/fm-primary-cd-check.json").hooks.PreToolUse.flatMap((entry) => entry.hooks))],
  ["cursor", commandHook(config(".cursor/hooks.json").hooks.preToolUse)],
];
for (const [name, hook] of registrations) {
  for (const [command, cwd, denied] of cases) {
    const payload = name === "grok"
      ? { toolName: "run_terminal_command", toolInput: { command }, cwd }
      : { tool_name: name === "cursor" ? "Shell" : "Bash", tool_input: { command, ...(name === "codex" ? { workdir: cwd } : {}) }, cwd, ...(name === "cursor" ? { cursor_version: "fixture" } : {}) };
    const result = spawnSync("bash", ["-c", hook], { cwd: primary, env, input: JSON.stringify(payload), encoding: "utf8" });
    assert.equal(result.error, undefined, name);
    assert.equal(result.status, denied && name !== "cursor" ? 2 : 0, name + ": " + command);
    if (denied && name === "cursor") {
      assert.equal(JSON.parse(result.stdout).permission, "deny");
      assert.equal(result.stderr, "");
    } else if (denied) {
      assert.match(result.stderr, /\[persistent-cd\]/);
    } else {
      assert.equal(result.stdout + result.stderr, "", name);
    }
  }
}
for (const [cwd, workdir, command, denied] of [
  [primary, "/tmp", "cd projects/foo", false],
  ["/tmp", primary, "cd projects/foo", true],
  [primary, "bin", "cd ../projects/foo", true],
]) {
  const payload = { cwd, tool_name: "Bash", tool_input: { command, workdir } };
  const result = spawnSync(primary + "/bin/fm-cd-pretool-check.sh", ["--claude"], { env, input: JSON.stringify(payload), encoding: "utf8" });
  assert.equal(result.status, denied ? 2 : 0, "tool workdir: " + workdir);
  if (denied) assert.match(result.stderr, /\[persistent-cd\]/);
  else assert.equal(result.stdout + result.stderr, "");
}
const { FmPrimaryCdCheck } = await import(pathToFileURL(root + "/.opencode/plugins/fm-primary-cd-check.js").href);
for (const [command, directory, denied] of cases) {
  const adapter = await FmPrimaryCdCheck({ directory, worktree: primary });
  let blocked = false;
  try {
    await adapter["tool.execute.before"]({ tool: "bash" }, { args: { command } });
  } catch (error) {
    assert.match(error.message, /\[persistent-cd\]/);
    blocked = true;
  }
  assert.equal(blocked, denied, "OpenCode directory: " + command);
}
for (const [workdir, command, denied] of [["/tmp", "cd projects/foo", false], ["bin", "cd ../projects/foo", true]]) {
  const adapter = await FmPrimaryCdCheck({ directory: primary, worktree: primary });
  let blocked = false;
  try {
    await adapter["tool.execute.before"]({ tool: "bash" }, { args: { command, workdir } });
  } catch (error) {
    assert.match(error.message, /\[persistent-cd\]/);
    blocked = true;
  }
  assert.equal(blocked, denied, "OpenCode workdir");
}
for (const name of ["pi", "omp"]) {
  const handlers = new Map();
  const extension = await import(pathToFileURL(primary + "/." + name + "/extensions/fm-primary-turnend-guard.ts").href);
  extension.default({ on(event, handler) { handlers.set(event, handler); } });
  for (const [command, cwd, denied] of cases) {
    const result = await handlers.get("tool_call")({ type: "tool_call", toolName: "bash", input: { command } }, { cwd });
    assert.equal(result.block === true, denied, name + " context cwd: " + command);
    if (denied) assert.match(result.reason, /\[persistent-cd\]/);
  }
  await handlers.get("session_shutdown")({}, {});
}
JS
  pass "cd-guard: registered hooks, tool workdir overrides, OpenCode, Pi and omp execute with their supplied cwd"
}

test_codex_supported_coverage() {
  mkdir -p "$PRIMARY/.codex"
  cp "$ROOT/.codex/hooks.json" "$PRIMARY/.codex/hooks.json"
  FM_CD_PRIMARY="$PRIMARY" HOME="$TMP_ROOT" FM_HOME="$PRIMARY" node --input-type=module <<'JS' || fail "Codex supported cwd coverage"
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
const primary = process.env.FM_CD_PRIMARY;
const hooks = JSON.parse(readFileSync(primary + "/.codex/hooks.json", "utf8")).hooks.PreToolUse;
const hook = hooks.flatMap((entry) => entry.hooks).find((entry) => entry.command.includes("fm-cd-pretool-check.sh")).command;
function check(command, cwd, denied, toolDirectory = {}) {
  // Codex 0.160.0 emits session cwd and command, omitting exec_command.workdir.
  const payload = { session_id: "codex-coverage", transcript_path: null, hook_event_name: "PreToolUse", tool_name: "Bash", cwd, tool_input: { command, ...toolDirectory } };
  const result = spawnSync("bash", ["-c", hook], { cwd: primary, env: process.env, input: JSON.stringify(payload), encoding: "utf8" });
  assert.equal(result.error, undefined);
  assert.equal(result.status, denied ? 2 : 0, command + ": " + JSON.stringify(toolDirectory));
  if (denied) {
    assert.equal(JSON.parse(result.stderr).hookSpecificOutput.permissionDecision, "deny");
    assert.match(result.stderr, /\[persistent-cd\]/);
  } else assert.equal(result.stdout + result.stderr, "", command);
}
for (const builtin of ["cd", "pushd"]) {
  for (const command of [
    builtin + " projects/foo",
    builtin + " ../projects/foo",
    builtin + " ./projects/foo",
    builtin + " bin && " + builtin + " ../projects/foo",
    "cd '" + primary + "' && " + builtin + " projects/foo",
  ]) check(command, primary, false);
  check(builtin + " '" + primary + "/projects/foo'", primary + "/outside", true);
  check(builtin + " '" + primary + "/outside/projects/foo'", primary, false);
  check(builtin + " ~/primary/projects/\"my clone\"", primary + "/outside", true);
  check(builtin + " ~/primary/outside/projects/foo", primary, false);
  check(builtin + " '~/primary/projects/foo'", primary, false);
  check(builtin + " \\~/primary/projects/foo", primary, false);
  check(builtin + " projects/foo", primary + "/outside", true, { workdir: primary });
  check(builtin + " projects/foo", primary, false, { workdir: primary + "/outside" });
  check(builtin + " ../projects/foo", primary, true, { workdir: "bin" });
  check(builtin + " projects/foo", primary + "/outside", true, { cwd: primary });
  check(builtin + " projects/foo", undefined, true, { workdir: primary });
}
check('printf "native-control\\n" > CONTROL_SENTINEL', primary, false);
JS
  pass "cd-guard: Codex checks anchored targets, allows unresolved relatives, and honors supplied tool cwd"
}

test_literal_list_execution() {
  FM_CD_PRIMARY="$PRIMARY" FM_CD_ROOT="$ROOT" node --input-type=module <<'JS' || fail "cd-guard literal list execution regression"
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync } from "node:fs";
import { pathToFileURL } from "node:url";
const home = process.env.FM_CD_PRIMARY;
const { decision } = await import(pathToFileURL(process.env.FM_CD_ROOT + "/bin/fm-cd-command-policy.mjs").href);
mkdirSync(home + "/projects/flow-clone", { recursive: true });
mkdirSync(home + "/locked");
chmodSync(home + "/locked", 0);
for (const command of [
  "cd bin || true; cd ../projects/flow-clone",
  "cd missing-directory && true; cd projects/flow-clone",
  "pushd bin || true; pushd ../projects/flow-clone",
  "false && cd /tmp; cd projects/flow-clone",
  "true || cd /tmp; cd projects/flow-clone",
  "cd /tmp || true; cd projects/flow-clone",
  "cd missing-directory && cd projects/flow-clone",
  "cd locked && true; cd projects/flow-clone",
]) {
  const executed = spawnSync("bash", ["--noprofile", "--norc", "-c", command + "; pwd -P"], { cwd: home, encoding: "utf8", env: { ...process.env, CDPATH: "" } });
  assert.equal(executed.status, 0, command);
  const destination = executed.stdout.trim().split("\n").at(-1);
  const protectedDestination = destination.startsWith(home + "/projects/");
  assert.equal(decision(command, home + "/projects", home).decision, protectedDestination ? "deny" : "allow", command);
}
chmodSync(home + "/locked", 0o700);
JS
  pass "cd-guard: literal branch and rejoin verdicts match executed shell destinations"
}

test_scripts_are_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$ROOT/bin/fm-cd-pretool-check.sh" 2>&1) \
    || fail "bin/fm-cd-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-cd-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_fires_in_secondmate_home
test_inert_in_child_worktree
test_inert_when_not_firstmate_repo
test_inert_when_not_a_git_repo
test_e2e_cwd_leak_regression
test_fail_open_empty_stdin
test_fail_open_unparseable_json
test_fail_open_missing_node
test_fail_open_missing_jq_on_stdin
test_prefilter_skips_node_without_cd_substring
test_policy_cli_direct
test_cwd_adapters
test_codex_supported_coverage
test_literal_list_execution
test_scripts_are_shellcheck_clean
