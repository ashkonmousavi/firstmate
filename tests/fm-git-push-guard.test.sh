#!/usr/bin/env bash
# Behavior tests for bin/fm-git-push-guard.sh, the forge=external pre-push guard,
# and bin/fm-git-ruff-format-check.sh, the automatic Ruff pre-push check.
# Every case pushes with real git through a hooks directory installed by
# bin/fm-git-strip-ai-trailers.sh install, the way a fleet
# pane does, and asserts both the exit status and which ref the bare remote ended
# up holding. The ruff cases put a fake ruff on PATH that calls a file unformatted
# when its text contains the word UNFORMATTED.
set -u

# A fleet pane already carries GIT_CONFIG core.hooksPath. These cases set that
# override themselves, so drop the inherited one before any git command.
unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-git-push-guard.sh"
STRIP="$ROOT/bin/fm-git-strip-ai-trailers.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-push-guard)
fm_git_identity fmtest fmtest@example.invalid

with_hooks() {  # <hooks-dir> <command...>
  local hooks=$1
  shift
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=$hooks "$@"
}

# fixture <name> <task-prefix> [backup]: a project with a bare origin, an
# optional bare backup remote, a worktree on <task-prefix>t1 with one commit,
# and the hooks dir installed with the guard. Sets FX_WT, FX_HOOKS, FX_ORIGIN,
# FX_BACKUP, FX_BRANCH.
fixture() {
  local name=$1 prefix=$2 backup=${3:-} dir guard
  dir="$TMP_ROOT/$name"
  FX_BRANCH="${prefix}t1"
  fm_git_worktree "$dir/repo" "$dir/wt" "$FX_BRANCH"
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_BACKUP=
  git -C "$FX_WT" commit -q --allow-empty -m 'the task change'
  guard="$dir/guard"
  if [ -n "$backup" ]; then
    FX_BACKUP="$dir/backup.git"
    git init -q --bare "$FX_BACKUP"
    git -C "$FX_WT" remote add backup "file://$FX_BACKUP"
    "$GUARD" write "$guard" "$FX_WT" "$FX_BRANCH" "$prefix" backup backup/ || fail "guard write failed"
  else
    "$GUARD" write "$guard" "$FX_WT" "$FX_BRANCH" "$prefix" || fail "guard write failed"
  fi
  FX_HOOKS="$dir/hooks"
  "$STRIP" install --push-guard "$guard" "$FX_HOOKS" "$FX_WT" || fail "install --push-guard failed"
}

push() {  # <args...>; sets PUSH_OUT and PUSH_RC
  PUSH_OUT=$(with_hooks "$FX_HOOKS" git -C "$FX_WT" push "$@" 2>&1)
  PUSH_RC=$?
}

refused() {  # <label> <needle> <bare-repo> <ref>
  [ "$PUSH_RC" -ne 0 ] || fail "$1 was accepted"
  assert_contains "$PUSH_OUT" "fm-git-push-guard: refused:" "$1 was refused without the guard naming itself"
  assert_contains "$PUSH_OUT" "$2" "$1 was refused without naming its rule"
  if git -C "$3" rev-parse --verify --quiet "$4" >/dev/null; then
    fail "$1 still reached the remote as $4"
  fi
}

test_origin_pushes_are_refused() {
  fixture origin fm/
  push origin "HEAD:refs/heads/$FX_BRANCH"
  refused "the task branch pushed to origin" "nothing is ever pushed to origin" "$FX_ORIGIN" "refs/heads/$FX_BRANCH"
  push origin HEAD:refs/heads/other
  refused "another branch pushed to origin" "nothing is ever pushed to origin" "$FX_ORIGIN" refs/heads/other
  push "file://$FX_ORIGIN" HEAD:refs/heads/by-url
  refused "a push to origin's URL" "shared origin" "$FX_ORIGIN" refs/heads/by-url
  # git resolves a local path without its .git suffix, so this alias reaches
  # the same bare repository origin names with one.
  git -C "$FX_WT" remote add alias "file://${FX_ORIGIN%.git}"
  push alias HEAD:refs/heads/alias-dotgit
  refused "a remote aliasing origin without its trailing .git" "shared origin" "$FX_ORIGIN" refs/heads/alias-dotgit
  git -C "$FX_WT" remote set-url alias "file://$FX_ORIGIN/"
  push alias HEAD:refs/heads/alias-slash
  refused "a remote aliasing origin with a trailing slash" "shared origin" "$FX_ORIGIN" refs/heads/alias-slash
  pass "push guard: origin, origin's URL, and a remote aliasing origin's URL are all refused"
}

test_backup_namespace_rules() {
  fixture backup fm/ backup
  push backup "HEAD:refs/heads/$FX_BRANCH"
  refused "the task branch pushed to the backup remote" "your task branch" "$FX_BACKUP" "refs/heads/$FX_BRANCH"
  push backup HEAD:refs/heads/fm/other
  refused "a task-prefixed branch pushed to the backup remote" "task branch prefix fm/" "$FX_BACKUP" refs/heads/fm/other
  push backup HEAD:refs/heads/elsewhere
  refused "a ref outside the backup prefix" "outside refs/heads/backup/" "$FX_BACKUP" refs/heads/elsewhere
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -eq 0 ] || fail "the durable copy to backup/t1 was refused: $PUSH_OUT"
  assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_BACKUP" rev-parse refs/heads/backup/t1)" \
    "the durable copy did not land on the backup remote"
  git -C "$FX_WT" rev-parse --verify --quiet refs/remotes/backup/backup/t1 >/dev/null \
    || fail "the durable copy left no remote-tracking ref for the done gate to read"
  pass "push guard: the backup remote takes only backup/<id>, never the task branch or prefix"
}

test_empty_prefix_still_refuses_the_task_branch() {
  local other
  fixture bare-prefix ''
  other="$TMP_ROOT/bare-prefix/other.git"
  git init -q --bare "$other"
  git -C "$FX_WT" remote add other "file://$other"
  push other "HEAD:refs/heads/$FX_BRANCH"
  refused "the bare task branch pushed with an empty prefix" "your task branch" "$other" "refs/heads/$FX_BRANCH"
  push other HEAD:refs/heads/unrelated
  [ "$PUSH_RC" -eq 0 ] || fail "an unrelated branch to a non-shared remote was refused: $PUSH_OUT"
  pass "push guard: with an empty task prefix the bare task branch is still refused anywhere"
}

test_repository_pre_push_still_chains() {
  local hooks_dir marker
  fixture chain fm/ backup
  hooks_dir=$(git -C "$FX_WT" rev-parse --path-format=absolute --git-path hooks)
  mkdir -p "$hooks_dir"
  marker="$TMP_ROOT/chain/pre-push-ran"
  cat >"$hooks_dir/pre-push" <<EOF
#!/usr/bin/env bash
cat >"$marker"
[ ! -e "$TMP_ROOT/chain/block" ]
EOF
  chmod +x "$hooks_dir/pre-push"
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -eq 0 ] || fail "a passing guard did not let the push through: $PUSH_OUT"
  assert_contains "$(cat "$marker")" "refs/heads/backup/t1" "the repository pre-push hook did not receive git's ref lines"
  rm -f "$marker"
  : >"$TMP_ROOT/chain/block"
  git -C "$FX_WT" commit -q --allow-empty -m 'second change'
  push backup HEAD:refs/heads/backup/t1
  [ "$PUSH_RC" -ne 0 ] || fail "a failing repository pre-push hook no longer blocks the push"
  assert_present "$marker" "the repository pre-push hook did not run after the guard passed"
  rm -f "$marker"
  push origin HEAD:refs/heads/x
  [ "$PUSH_RC" -ne 0 ] || fail "origin push was accepted"
  assert_absent "$marker" "the repository pre-push hook ran even though the guard refused"
  pass "push guard: the repository's own pre-push hook runs after the guard passes and still blocks"
}

test_unreadable_guard_refuses_everything() {
  local out rc
  out=$(printf 'refs/heads/a 1 refs/heads/a 0\n' | "$GUARD" "$TMP_ROOT/no-such-guard" other https://example.test/x 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a missing guard file let a push through"
  assert_contains "$out" "unreadable" "a missing guard file was refused without saying why"
  pass "push guard: an unreadable guard file refuses every push"
}

ruff_fixture() {
  local name=$1 declaration=${2:-declared} dir
  dir="$TMP_ROOT/$name"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/t1
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_BIN="$dir/bin"
  mkdir -p "$FX_BIN"
  cat >"$FX_BIN/ruff" <<'EOF'
#!/usr/bin/env bash
# fake ruff: format --check --force-exclude --stdin-filename=NAME -
name=
while [ "$#" -gt 0 ]; do
  case "$1" in --stdin-filename=*) name=${1#--stdin-filename=} ;; esac
  shift
done
if grep -q UNFORMATTED; then
  echo "Would reformat: $name" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$FX_BIN/ruff"
  FX_HOOKS="$dir/hooks"
  "$STRIP" install "$FX_HOOKS" "$FX_WT" || fail "install failed"
  if [ "$declaration" = declared ]; then
    ruff_commit 'declare Ruff' 'requirements-dev.txt=ruff'
  fi
}

ruff_commit() {  # <message> <file>=<text>...; commits the files in FX_WT
  local msg=$1 spec
  shift
  for spec in "$@"; do
    mkdir -p "$(dirname "$FX_WT/${spec%%=*}")"
    printf '%s\n' "${spec#*=}" >"$FX_WT/${spec%%=*}"
    git -C "$FX_WT" add -f -- "${spec%%=*}" || fail "could not stage $spec"
  done
  git -C "$FX_WT" commit -q -m "$msg" || fail "could not commit $msg"
}

ruff_push() {  # <args...>; sets PUSH_OUT and PUSH_RC with the fake ruff on PATH
  PUSH_OUT=$(PATH="$FX_BIN:$PATH" with_hooks "$FX_HOOKS" git -C "$FX_WT" push "$@" 2>&1)
  PUSH_RC=$?
}

ruff_refused() {  # <label> <file>...
  local label=$1 f
  shift
  [ "$PUSH_RC" -ne 0 ] || fail "$label was accepted"
  assert_contains "$PUSH_OUT" "fm-ruff-format: refused:" "$label was refused without naming the format check"
  for f in "$@"; do
    assert_contains "$PUSH_OUT" "  $f" "$label was refused without naming $f"
  done
  assert_contains "$PUSH_OUT" "Fix: " "$label was refused without the fix command"
  assert_contains "$PUSH_OUT" " format -- " "$label was refused without a format invocation"
  assert_contains "$PUSH_OUT" "commit the formatting and push again" "$label was refused without telling the worker to push again"
}

test_ruff_format_passes_formatted_files() {
  ruff_fixture ruff-pass
  ruff_commit 'formatted' 'pkg/a.py=x = 1'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "a formatted .py push was refused: $PUSH_OUT"
  assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" \
    "the formatted push did not reach the remote"
  pass "ruff format check: a push of formatted .py files is allowed"
}

test_ruff_format_refuses_unformatted_files() {
  ruff_fixture ruff-refuse
  ruff_commit 'unformatted' 'pkg/a.py=x=UNFORMATTED' 'b.py=y = 1' 'pkg/c d.py=z=UNFORMATTED'
  ruff_push origin HEAD:refs/heads/fm/t1
  ruff_refused "an unformatted .py push" 'pkg/a.py' 'pkg/c d.py'
  assert_not_contains "$PUSH_OUT" "  b.py" "the formatted file was named as unformatted"
  assert_contains "$PUSH_OUT" " format -- pkg/a.py pkg/c\\ d.py" "the fix command does not list exactly the unformatted files"
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail "the refused push still reached the remote"
  ruff_commit 'format' 'pkg/a.py=x = 1' 'pkg/c d.py=z = 1'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "the push was still refused after formatting: $PUSH_OUT"
  pass "ruff format check: unformatted .py files are refused with the fix command, and pass once formatted"
}

test_ruff_format_only_checks_the_pushed_changes() {
  ruff_fixture ruff-scope
  ruff_commit 'old unformatted work already on the remote' 'old.py=a=UNFORMATTED'
  git -C "$FX_WT" push -q origin HEAD:refs/heads/main --no-verify
  git -C "$FX_WT" fetch -q origin
  ruff_commit 'notes and a deleted file' 'notes.txt=UNFORMATTED' 'data.json=UNFORMATTED' 'gone.py=ok = 1'
  git -C "$FX_WT" rm -q gone.py
  git -C "$FX_WT" commit -q -m 'delete gone.py'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "non-.py changes, deleted files or untouched old files were checked: $PUSH_OUT"
  ruff_commit 'touch old file again' 'old.py=a=UNFORMATTED2'
  ruff_push origin HEAD:refs/heads/fm/t1
  ruff_refused "a push that changes an unformatted file" 'old.py'
  ruff_commit 'format it' 'old.py=a = 1'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "an update push of a formatted change was refused: $PUSH_OUT"
  pass "ruff format check: non-.py and deleted files are ignored, and an update checks only what the push changes"
}

test_ruff_format_new_branch_uses_the_merge_base() {
  ruff_fixture ruff-newbranch
  ruff_commit 'old unformatted work on main' 'old.py=a=UNFORMATTED'
  git -C "$FX_WT" push -q origin HEAD:refs/heads/main --no-verify
  git -C "$FX_WT" fetch -q origin
  ruff_commit 'branch work' 'new.py=b = 1'
  ruff_push origin HEAD:refs/heads/fm/brand-new
  [ "$PUSH_RC" -eq 0 ] || fail "a new branch was checked against files already on the default branch: $PUSH_OUT"
  ruff_commit 'branch work, unformatted' 'new2.py=c=UNFORMATTED'
  ruff_push origin HEAD:refs/heads/fm/brand-new-2
  ruff_refused "a new branch with an unformatted file" 'new2.py'
  assert_not_contains "$PUSH_OUT" "  old.py" "a file already on the default branch was named"
  pass "ruff format check: a new branch is checked against its merge base with the default branch"
}

isolate_ruff_path() {
  local bare name
  bare="$FX_WT/../isolated-bin"
  mkdir -p "$bare"
  for name in git bash env sort cat sed sh dirname basename uname mktemp rm tr mkdir grep; do
    ln -s "$(command -v "$name")" "$bare/$name" || fail "could not expose $name to the isolated PATH"
  done
  FX_BIN="$bare"
}

isolated_ruff_push() {
  PUSH_OUT=$(PATH="$FX_BIN" with_hooks "$FX_HOOKS" git -C "$FX_WT" push "$@" 2>&1)
  PUSH_RC=$?
}

test_ruff_format_missing_ruff_refuses() {
  ruff_fixture ruff-missing
  ruff_commit 'unformatted with pinned Ruff' 'a.py=x=UNFORMATTED' 'requirements-dev.txt=ruff == 0.12.7 # CI formatter'
  isolate_ruff_path
  isolated_ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -ne 0 ] || fail "a missing Ruff let an unchecked push through"
  assert_contains "$PUSH_OUT" 'fm-ruff-format: refused: Ruff was not found' 'missing Ruff was refused without naming the cause'
  assert_contains "$PUSH_OUT" 'Install: python3 -m pip install ruff==0.12.7' 'missing Ruff did not name the pinned install command'
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'a missing Ruff still let the remote advance'
  pass 'ruff format check: missing Ruff refuses with the pinned install command'
}

test_ruff_format_uses_pinned_uv_tools() {
  local tool expected
  for tool in uvx uv; do
    ruff_fixture "ruff-$tool"
    ruff_commit 'pinned formatter' 'requirements-dev.txt=ruff==0.12.7' 'a.py=x=UNFORMATTED'
    printf 'ruff==0.13.1\n' >"$FX_WT/requirements-dev.txt"
    isolate_ruff_path
    cat >"$FX_BIN/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$0.args"
if grep -q UNFORMATTED; then exit 1; fi
SH
    chmod +x "$FX_BIN/$tool"
    isolated_ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused "a push checked by $tool" a.py
    expected=$'--from\nruff==0.12.7\nruff\nformat\n--check\n--force-exclude\n--stdin-filename=a.py\n-'
    [ "$tool" != uv ] || expected=$'tool\nrun\n'"$expected"
    assert_equals "$expected" "$(cat "$FX_BIN/$tool.args")" "$tool did not receive the committed pin and the documented tool invocation"
    git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail "$tool let unformatted code reach the remote"
    ruff_commit 'formatted' 'a.py=x = 1'
    isolated_ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "$tool refused formatted code: $PUSH_OUT"
    assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" "$tool did not let the formatted commit reach the remote"
  done
  pass 'ruff format check: uvx and uv tool run receive the committed Ruff pin'
}

test_ruff_format_errors_refuse() {
  local status
  for status in 2 137; do
    ruff_fixture "ruff-error-$status"
    ruff_commit 'formatted' 'a.py=x = 1'
    printf '#!/usr/bin/env bash\necho formatter-broken >&2\nexit %s\n' "$status" >"$FX_BIN/ruff"
    ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -ne 0 ] || fail "Ruff exit $status let an unchecked push through"
    assert_contains "$PUSH_OUT" "Ruff could not check a.py (exit $status)" 'Ruff failure did not name its status'
    assert_contains "$PUSH_OUT" 'formatter-broken' 'Ruff failure hid the tool diagnostic'
    git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail "Ruff exit $status still advanced the remote"
  done
  pass 'ruff format check: formatter errors and crashes refuse the push'
}

test_ruff_format_without_a_base_checks_every_supported_file() {
  ruff_fixture ruff-no-base
  ruff_commit 'unformatted old files' 'old.py=a=UNFORMATTED' 'api.pyi=b=UNFORMATTED' 'book.ipynb=UNFORMATTED'
  ruff_commit 'formatted recent file' 'new.py=c = 1'
  git -C "$FX_WT" update-ref refs/heads/main HEAD^
  PUSH_OUT=$(printf 'refs/heads/fm/t1 %s refs/heads/fm/t1 %s\n' "$(git -C "$FX_WT" rev-parse HEAD)" 1111111111111111111111111111111111111111 | (
    cd "$FX_WT" && PATH="$FX_BIN:$PATH" "$ROOT/bin/fm-git-ruff-format-check.sh" origin "file://$FX_ORIGIN"
  ) 2>&1)
  PUSH_RC=$?
  ruff_refused 'a push whose remote tip is unavailable locally' old.py api.pyi book.ipynb
  git -C "$FX_WT" update-ref -d refs/heads/main
  ruff_push origin HEAD:refs/heads/fm/t1
  ruff_refused 'a push with no comparison base' old.py api.pyi book.ipynb
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'a push with no comparison base still advanced the remote'
  ruff_commit 'format all' 'old.py=a = 1' 'api.pyi=b = 1' 'book.ipynb=formatted'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "formatted files without a comparison base were refused: $PUSH_OUT"
  pass 'ruff format check: no comparison base checks every tracked supported file'
}

test_ruff_format_prefers_the_project_venv() {
  ruff_fixture ruff-venv
  mkdir -p "$FX_WT/.venv/bin"
  cat >"$FX_WT/.venv/bin/ruff" <<'EOF'
#!/usr/bin/env bash
echo "Would reformat: from-venv" >&2
exit 1
EOF
  chmod +x "$FX_WT/.venv/bin/ruff"
  printf '.venv/\n' >>"$(git -C "$FX_WT" rev-parse --git-path info/exclude)"
  ruff_commit 'formatted' 'a.py=x = 1'
  ruff_push origin HEAD:refs/heads/fm/t1
  ruff_refused "a push judged by the project venv's ruff" 'a.py'
  pass "ruff format check: the project's own venv ruff is used before ruff on PATH"
}

test_ruff_format_uses_repository_declarations() {
  local variant declaration
  for variant in toml dot-toml pyproject pyproject-format requirements; do
    ruff_fixture "ruff-declaration-$variant" undeclared
    ruff_commit 'no Ruff declaration' 'a.py=x=UNFORMATTED' 'pyproject.toml=[project]
name = "example"
version = "1.0"'
    ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "a repository without Ruff was affected: $PUSH_OUT"
    assert_not_contains "$PUSH_OUT" 'fm-ruff-format:' 'a repository without Ruff emitted a formatter diagnostic'
    case "$variant" in
      toml) declaration='ruff.toml=' ;;
      dot-toml) declaration='.ruff.toml=' ;;
      pyproject) declaration='pyproject.toml=[tool.ruff]' ;;
      pyproject-format) declaration='pyproject.toml=[tool.ruff.format]' ;;
      requirements) declaration='requirements-dev.txt=ruff>=0.12' ;;
    esac
    ruff_commit 'declare Ruff and change Python' "$declaration" 'a.py=y=UNFORMATTED'
    ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused "automatic enforcement from $variant" a.py
    assert_not_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'a refused declaration update advanced the remote'
  done
  pass 'ruff format check: repository declarations enable enforcement without home configuration'
}

test_ruff_format_and_push_guard_each_refuse_visibly() {
  local dir guard
  dir="$TMP_ROOT/ruff-both"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/t1
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_BIN="$dir/bin"
  mkdir -p "$FX_BIN"
  cp "$TMP_ROOT/ruff-refuse/bin/ruff" "$FX_BIN/ruff"
  guard="$dir/guard"
  "$GUARD" write "$guard" "$FX_WT" fm/t1 fm/ || fail "guard write failed"
  FX_HOOKS="$dir/hooks"
  "$STRIP" install --push-guard "$guard" "$FX_HOOKS" "$FX_WT" || fail "install failed"
  ruff_commit 'unformatted' 'requirements-dev.txt=ruff' 'a.py=x=UNFORMATTED'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -ne 0 ] || fail "a push both checks refuse was accepted"
  assert_contains "$PUSH_OUT" "fm-git-push-guard: refused:" "the format refusal hid the push guard refusal"
  assert_contains "$PUSH_OUT" "fm-ruff-format: refused:" "the push guard refusal hid the format refusal"
  ruff_commit 'formatted' 'a.py=x = 1'
  ruff_push origin HEAD:refs/heads/fm/t1
  assert_not_contains "$PUSH_OUT" "fm-ruff-format: refused:" "a formatted push was still refused for format"
  assert_contains "$PUSH_OUT" "fm-git-push-guard: refused:" "the push guard stopped refusing when the format check passed"
  pass "ruff format check: it and the push guard each refuse, and neither hides the other"
}

test_ruff_format_uses_committed_configuration() {
  local real_ruff variant config section committed local_config bad good before
  real_ruff=$(command -v ruff) || { echo '# SKIP committed configuration checks require real ruff'; return; }
  for variant in pyproject staged nested deleted untracked extended excluded ignored; do
    ruff_fixture "ruff-config-$variant"
    ln -sf "$real_ruff" "$FX_BIN/ruff"
    config=ruff.toml section='[format]' committed=double local_config=single
    bad="x = 'a'" good='x = "a"'
    case "$variant" in
      pyproject | staged) config=pyproject.toml section='[tool.ruff.format]' ;;
      nested) config=pkg/.ruff.toml ;;
      deleted) committed=single; bad='x = "a"'; good="x = 'a'" ;;
      extended) config=settings.toml ;;
    esac
    if [ "$variant" = extended ]; then
      ruff_commit 'inherited configuration' 'ruff.toml=extend = "settings.toml"'
    fi
    ruff_commit 'committed configuration' "$config=$section
quote-style = \"$committed\""
    ruff_commit 'incorrect committed quotes' "pkg/a.py=$bad"
    case "$variant" in
      deleted) rm "$FX_WT/$config" ;;
      untracked) printf '[format]\nquote-style = "single"\n' >"$FX_WT/.ruff.toml" ;;
      excluded) printf 'extend-exclude = ["pkg"]\n' >"$FX_WT/$config" ;;
      ignored) printf 'pkg/\n' >"$FX_WT/.gitignore" ;;
      *) printf '%s\nquote-style = "%s"\n' "$section" "$local_config" >"$FX_WT/$config" ;;
    esac
    [ "$variant" != staged ] || git -C "$FX_WT" add "$config"
    before=$(git -C "$FX_WT" status --porcelain=v1)
    ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused "committed formatting with $variant local configuration" pkg/a.py
    git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null \
      && fail "$variant local configuration let incorrect quotes reach the remote"
    assert_equals "$before" "$(git -C "$FX_WT" status --porcelain=v1)" "checking $variant configuration changed the index or working tree"
    git -C "$FX_WT" restore --staged .
    ruff_commit 'correct committed quotes' "pkg/a.py=$good"
    ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "correct quotes were refused with $variant local configuration: $PUSH_OUT"
    assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" \
      "correct quotes with $variant local configuration did not reach the remote"
  done
  pass 'ruff format check: committed quote styles and exclusions govern despite staged, unstaged, missing or untracked local configuration'
}

test_ruff_format_uses_each_pushed_refs_configuration() {
  local real_ruff double_oid single_oid
  real_ruff=$(command -v ruff) || { echo '# SKIP pushed ref configuration checks require real ruff'; return; }
  ruff_fixture ruff-config-refs
  ln -sf "$real_ruff" "$FX_BIN/ruff"
  ruff_commit 'double quoted ref' 'ruff.toml=[format]
quote-style = "double"' 'pkg/a.py=x = "a"'
  double_oid=$(git -C "$FX_WT" rev-parse HEAD)
  ruff_commit 'single quoted ref' 'ruff.toml=[format]
quote-style = "single"' "pkg/a.py=x = 'a'"
  single_oid=$(git -C "$FX_WT" rev-parse HEAD)
  ruff_push origin "$double_oid:refs/heads/fm/double" "$single_oid:refs/heads/fm/single"
  [ "$PUSH_RC" -eq 0 ] || fail "a multi-ref push used another ref's configuration: $PUSH_OUT"
  assert_equals "$double_oid" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/double)" 'the double quoted ref did not reach the remote'
  assert_equals "$single_oid" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/single)" 'the single quoted ref did not reach the remote'
  ruff_commit 'incorrect single quoted update' 'pkg/a.py=x = "a"'
  ruff_push origin HEAD:refs/heads/fm/single
  ruff_refused 'an update formatted against its committed configuration' pkg/a.py
  assert_equals "$single_oid" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/single)" 'an incorrectly quoted update reached the remote'
  ruff_commit 'correct single quoted update' "pkg/a.py=x = 'b'"
  ruff_push origin HEAD:refs/heads/fm/single
  [ "$PUSH_RC" -eq 0 ] || fail "a correctly quoted update was refused: $PUSH_OUT"
  pass 'ruff format check: each pushed ref and update uses its own committed configuration'
}

test_ruff_format_checks_stubs_notebooks_and_exclusions() {
  local real_ruff notebook
  real_ruff=$(command -v ruff) || { echo '# SKIP supported-file checks require real ruff'; return; }
  ruff_fixture ruff-supported
  ln -sf "$real_ruff" "$FX_BIN/ruff"
  notebook='{"cells":[{"cell_type":"code","execution_count":null,"metadata":{},"outputs":[],"source":["x=1\n"]}],"metadata":{},"nbformat":4,"nbformat_minor":5}'
  ruff_commit 'unformatted stubs and notebook' 'api.pyi=x=1' "book.ipynb=$notebook"
  ruff_push origin HEAD:refs/heads/fm/t1
  ruff_refused 'a push of unformatted stubs and notebooks' api.pyi book.ipynb
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'unformatted supported files reached the remote'
  (cd "$FX_WT" && "$real_ruff" format api.pyi book.ipynb) >/dev/null || fail 'could not format the supported-file fixture'
  git -C "$FX_WT" add api.pyi book.ipynb
  git -C "$FX_WT" commit -q -m 'format stubs and notebook'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "formatted stubs and notebooks were refused: $PUSH_OUT"
  ruff_commit 'exclude stubs from formatting' 'ruff.toml=[format]
exclude = ["*.pyi"]' 'api.pyi=x=2'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "a committed Ruff exclusion was ignored: $PUSH_OUT"
  assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'the formatted and excluded files did not reach the remote'
  pass 'ruff format check: real Ruff checks stubs and notebooks and honors committed exclusions'
}

test_ruff_format_ignores_external_configuration() {
  local real_ruff variant user_config snapshots config section notebook
  real_ruff=$(command -v ruff) || { echo '# SKIP external configuration checks require real ruff'; return; }
  for variant in user-dot user-toml user-pyproject user-exclude parent; do
    ruff_fixture "ruff-external-$variant"
    ln -sf "$real_ruff" "$FX_BIN/ruff"
    user_config="$FX_WT/../user-config"
    snapshots="$FX_WT/../snapshots"
    mkdir -p "$user_config/ruff" "$snapshots"
    config="$user_config/ruff/ruff.toml" section='[format]'
    case "$variant" in
      user-dot) config="$user_config/ruff/.ruff.toml" ;;
      user-pyproject) config="$user_config/ruff/pyproject.toml" section='[tool.ruff.format]' ;;
      parent) config="$snapshots/.ruff.toml" ;;
    esac
    if [ "$variant" = user-exclude ]; then
      printf 'exclude = ["*.py", "*.pyi", "*.ipynb"]\n' >"$config"
    else
      printf '%s\nquote-style = "single"\n' "$section" >"$config"
    fi
    notebook="{\"cells\":[{\"cell_type\":\"code\",\"execution_count\":null,\"metadata\":{},\"outputs\":[],\"source\":[\"x = 'a'\\n\"]}],\"metadata\":{},\"nbformat\":4,\"nbformat_minor\":5}"
    ruff_commit 'default formatting and committed nested settings' \
      'pyproject.toml=[project]
name = "example"
version = "1.0"' \
      'settings.toml=[format]
quote-style = "single"
exclude = ["excluded.py"]' \
      'pkg/ruff.toml=extend = "../settings.toml"' \
      "pkg/valid.py=x = 'a'" 'pkg/excluded.py=x=UNFORMATTED' \
      "a.py=x = 'a'" "api.pyi=x = 'a'" "book.ipynb=$notebook"
    TMPDIR="$snapshots" XDG_CONFIG_HOME="$user_config" ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused "a push with $variant external Ruff settings" a.py api.pyi book.ipynb
    assert_not_contains "$PUSH_OUT" '  pkg/valid.py' 'the default root configuration replaced committed nested settings'
    assert_not_contains "$PUSH_OUT" '  pkg/excluded.py' 'the default root configuration replaced committed inherited exclusions'
    git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'external settings let incorrectly quoted files reach the remote'
    (cd "$FX_WT" && "$real_ruff" format --isolated a.py api.pyi book.ipynb) >/dev/null || fail 'could not apply default formatting to the fixture'
    git -C "$FX_WT" add a.py api.pyi book.ipynb
    git -C "$FX_WT" commit -q -m 'apply default formatting'
    TMPDIR="$snapshots" XDG_CONFIG_HOME="$user_config" ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "committed settings and defaults were refused under $variant: $PUSH_OUT"
    assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'correct formatting did not reach the remote'
  done
  pass 'ruff format check: user and parent configuration cannot replace defaults or committed nested settings'
}

test_pre_push_chaining_preserves_empty_and_nonempty_input() {
  local mode stripping hook_kind hooks record guard commit args
  for mode in format guard; do
    for stripping in strip keep; do
      for hook_kind in default configured; do
        ruff_fixture "ruff-stdin-$mode-$stripping-$hook_kind"
        ruff_commit 'formatted' 'a.py=x = 1'
        git init -q --bare "$FX_WT/../backup.git"
        git -C "$FX_WT" remote add backup "file://$FX_WT/../backup.git"
        args=()
        [ "$stripping" != keep ] || args+=(--no-strip)
        if [ "$mode" = guard ]; then
          guard="$FX_WT/../guard"
          "$GUARD" write "$guard" "$FX_WT" fm/t1 fm/ backup backup/ || fail 'could not write the push guard'
          args+=(--push-guard "$guard")
        fi
        "$STRIP" install "${args[@]+"${args[@]}"}" "$FX_HOOKS" "$FX_WT" || fail 'could not install pre-push hooks'
        if [ "$hook_kind" = configured ]; then
          hooks="$FX_WT/.project-hooks"
          git -C "$FX_WT" config core.hooksPath "$hooks"
        else
          hooks=$(git -C "$FX_WT" rev-parse --path-format=absolute --git-path hooks)
        fi
        mkdir -p "$hooks"
        record="$hooks/pre-push.input"
        cat >"$hooks/pre-push" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys

data = sys.stdin.buffer.read()
for line in data.decode().splitlines():
    local_ref, local_oid, remote_ref, remote_oid = line.rsplit(maxsplit=3)
pathlib.Path(__file__ + ".input").write_bytes(data)
PY
        chmod +x "$hooks/pre-push"
        ruff_push backup HEAD:refs/heads/backup/t1 HEAD:refs/heads/backup/t2
        [ "$PUSH_RC" -eq 0 ] || fail "the chained hook rejected ref records for $mode/$stripping/$hook_kind: $PUSH_OUT"
        assert_equals 2 "$(wc -l <"$record" | tr -d ' ')" 'the chained hook did not receive both ref records'
        commit=$(git -C "$FX_WT" rev-parse HEAD)
        ruff_push backup HEAD:refs/heads/backup/t1 HEAD:refs/heads/backup/t2
        [ "$PUSH_RC" -eq 0 ] || fail "an up-to-date push was refused for $mode/$stripping/$hook_kind: $PUSH_OUT"
        assert_equals 0 "$(wc -c <"$record" | tr -d ' ')" 'the chained hook received bytes instead of EOF for an up-to-date push'
        assert_equals "$commit" "$(git -C "$FX_WT/../backup.git" rev-parse refs/heads/backup/t1)" 'the up-to-date push changed the remote ref'
        ruff_commit 'another formatted change' 'a.py=x = 2'
        ruff_push backup HEAD:refs/heads/backup/t1 HEAD:refs/heads/backup/t2
        [ "$PUSH_RC" -eq 0 ] || fail "a changed push after an up-to-date push was refused: $PUSH_OUT"
        assert_equals 2 "$(wc -l <"$record" | tr -d ' ')" 'nonempty records stopped reaching the chained hook'
        assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_WT/../backup.git" rev-parse refs/heads/backup/t2)" 'the changed push did not reach the remote'
      done
    done
  done
  pass 'pre-push chaining: project hooks receive EOF for empty pushes and every record for changed pushes'
}

test_ruff_format_large_excluded_files_do_not_refuse() {
  local real_ruff exclusion comparison prefix config before path
  real_ruff=$(command -v ruff) || { echo '# SKIP large exclusion checks require real ruff'; return; }
  for exclusion in root root-format nested nested-format extended; do
    for comparison in changed all; do
      ruff_fixture "ruff-large-$exclusion-$comparison"
      ln -sf "$real_ruff" "$FX_BIN/ruff"
      prefix= config=ruff.toml
      case "$exclusion" in
        nested*) prefix=pkg/; config=pkg/ruff.toml ;;
      esac
      case "$exclusion" in
        *-format) ruff_commit 'format exclusions' "$config=[format]
exclude = [\"large.py\", \"large.pyi\", \"large.ipynb\"]" ;;
        extended) ruff_commit 'extended exclusions' "$config=extend-exclude = [\"large.py\", \"large.pyi\", \"large.ipynb\"]" ;;
        *) ruff_commit 'general exclusions' "$config=exclude = [\"large.py\", \"large.pyi\", \"large.ipynb\"]" ;;
      esac
      python3 - "$FX_WT/$prefix" <<'PY'
from pathlib import Path
import sys

directory = Path(sys.argv[1])
directory.mkdir(parents=True, exist_ok=True)
for suffix in ("py", "pyi", "ipynb"):
    (directory / f"large.{suffix}").write_bytes(b"x=UNFORMATTED\n" * 200000)
PY
      git -C "$FX_WT" add -f -- "${prefix}large.py" "${prefix}large.pyi" "${prefix}large.ipynb"
      ruff_commit 'large excluded files and formatted code' 'included.py=x = 1'
      [ "$comparison" != all ] || git -C "$FX_WT" update-ref -d refs/heads/main
      ruff_push origin HEAD:refs/heads/fm/t1
      [ "$PUSH_RC" -eq 0 ] || fail "large $exclusion exclusions refused a $comparison push: $PUSH_OUT"
      before=$(git -C "$FX_WT" rev-parse HEAD)
      assert_equals "$before" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'excluded large files did not reach the remote'
      for path in "${prefix}large.py" "${prefix}large.pyi" "${prefix}large.ipynb"; do
        printf '\n' >>"$FX_WT/$path"
        git -C "$FX_WT" add -f -- "$path"
      done
      ruff_commit 'change excluded files beside unformatted code' 'included.py=x=2'
      ruff_push origin HEAD:refs/heads/fm/t1
      ruff_refused 'unformatted included code beside large excluded files' included.py
      assert_not_contains "$PUSH_OUT" 'Ruff could not check' 'an excluded file still caused a formatter error'
      assert_equals "$before" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'unformatted included code advanced the remote'
      ruff_commit 'format included code' 'included.py=x = 2'
      ruff_push origin HEAD:refs/heads/fm/t1
      [ "$PUSH_RC" -eq 0 ] || fail "formatted code beside large excluded files was refused: $PUSH_OUT"
    done
  done
  pass 'ruff format check: large excluded py, pyi and ipynb files pass under root, nested, format and extended exclusions with or without a base'
}

test_ruff_format_unreadable_committed_content_refuses() {
  local real_git
  ruff_fixture ruff-unreadable-content
  ruff_commit 'formatted' 'a.py=x = 1'
  real_git=$(command -v git)
  printf '#!/usr/bin/env bash\nif [ "${1:-}" = show ] && [[ "${2:-}" = *:a.py ]]; then echo object-read-failed >&2; exit 42; fi\nexec %q "$@"\n' "$real_git" >"$FX_BIN/git"
  chmod +x "$FX_BIN/git"
  GIT_EXEC_PATH="$FX_BIN" ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -ne 0 ] || fail 'unreadable committed content let an unchecked push through'
  assert_contains "$PUSH_OUT" 'fm-ruff-format: refused: could not read committed content for a.py' 'the refusal did not name the unreadable committed file'
  assert_contains "$PUSH_OUT" 'object-read-failed' 'the refusal hid the object-read failure'
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'unreadable committed content advanced the remote'
  pass 'ruff format check: failure to materialize committed content refuses the push'
}

collect_reported_fixes() {
  local line
  FIX_COMMANDS=()
  while IFS= read -r line; do
    case "$line" in 'Fix: '*) FIX_COMMANDS+=("${line#Fix: }") ;; esac
  done <<<"$PUSH_OUT"
}

write_real_ruff_uv_runner() {
  local tool=$1 real_ruff=$2
  {
    printf '#!/usr/bin/env bash\n'
    cat <<'SH'
printf '%s\n' "$@" >"$0.args"
[ "${1:-}" != tool ] || shift 2
[ "$#" -ge 3 ] && [ "$1" = --from ] && [ "$3" = ruff ] || exit 2
printf '%s\n' "$2" >>"$0.packages"
shift 3
SH
    printf 'exec %q "$@"\n' "$real_ruff"
  } >"$FX_BIN/$tool"
  chmod +x "$FX_BIN/$tool"
}

test_ruff_format_unpinned_uv_refuses() {
  local tool declaration requirement
  for tool in uvx uv; do
    for declaration in config unpinned range wildcard local-pin; do
      ruff_fixture "ruff-no-pin-$tool-$declaration"
      requirement=ruff
      case "$declaration" in
        config) git -C "$FX_WT" rm -q requirements-dev.txt ;;
        range) requirement='ruff>=0.12.7' ;;
        wildcard) requirement='ruff==0.12.*' ;;
      esac
      if [ "$declaration" = config ]; then
        ruff_commit 'config without requirements pin' 'ruff.toml=' 'a.py=x=UNFORMATTED'
      else
        ruff_commit 'no exact committed pin' "requirements-dev.txt=$requirement" 'a.py=x=UNFORMATTED'
      fi
      [ "$declaration" != local-pin ] || printf 'ruff==0.12.7\n' >"$FX_WT/requirements-dev.txt"
      isolate_ruff_path
      printf '#!/usr/bin/env bash\nprintf invoked >"$0.ran"\nexit 0\n' >"$FX_BIN/$tool"
      chmod +x "$FX_BIN/$tool"
      isolated_ruff_push origin HEAD:refs/heads/fm/t1
      [ "$PUSH_RC" -ne 0 ] || fail "$tool accepted $declaration without an exact committed pin"
      assert_contains "$PUSH_OUT" 'exact committed requirements-dev.txt pin' 'unpinned uv refusal did not explain the missing pin'
      assert_contains "$PUSH_OUT" 'Install: python3 -m pip install ruff' 'unpinned uv refusal omitted the install command'
      assert_absent "$FX_BIN/$tool.ran" 'uv was invoked despite the missing committed pin'
      git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'unpinned uv advanced the remote'
    done
  done
  pass 'ruff format check: uvx and uv refuse absent, ranged, wildcard and local-only pins'
}

test_ruff_format_committed_symlinks_refuse() {
  local suffix symlinks comparison path object before
  for suffix in py pyi ipynb; do
    for symlinks in true false; do
      for comparison in changed all; do
        ruff_fixture "ruff-link-$suffix-$symlinks-$comparison"
        git -C "$FX_WT" config core.symlinks "$symlinks"
        path="alias.$suffix"
        ruff_commit 'regular candidate and target' "$path=x = 1" 'module.txt=x = 1'
        before=
        if [ "$comparison" = changed ]; then
          ruff_push origin HEAD:refs/heads/fm/t1
          [ "$PUSH_RC" -eq 0 ] || fail "regular file was refused: $PUSH_OUT"
          before=$(git -C "$FX_WT" rev-parse HEAD)
        fi
        object=$(printf 'module.txt' | git -C "$FX_WT" hash-object -w --stdin)
        git -C "$FX_WT" update-index --add --cacheinfo "120000,$object,$path"
        git -C "$FX_WT" commit -q -m 'replace regular candidate with a committed symlink'
        [ "$comparison" != all ] || git -C "$FX_WT" update-ref -d refs/heads/main
        ruff_push origin HEAD:refs/heads/fm/t1
        [ "$PUSH_RC" -ne 0 ] || fail "a committed $suffix symlink was accepted with core.symlinks=$symlinks and $comparison selection"
        assert_contains "$PUSH_OUT" "cannot format-check symlink or non-regular committed file $path (mode 120000)" 'symlink refusal did not identify the committed file and mode'
        if [ -n "$before" ]; then
          assert_equals "$before" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'a regular-to-symlink transition advanced the remote'
        else
          git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/t1 >/dev/null && fail 'a committed symlink reached the remote'
        fi
        object=$(printf 'x = 2\n' | git -C "$FX_WT" hash-object -w --stdin)
        git -C "$FX_WT" update-index --cacheinfo "100644,$object,$path"
        git -C "$FX_WT" commit -q -m 'restore a regular committed candidate'
        ruff_push origin HEAD:refs/heads/fm/t1
        [ "$PUSH_RC" -eq 0 ] || fail "restoring a regular candidate was refused: $PUSH_OUT"
      done
    done
  done
  pass 'ruff format check: committed symlinks refuse by mode for every type and selection, even when checkout materializes link text'
}

test_ruff_format_symlink_to_regular_is_checked() {
  local suffix path object before
  for suffix in py pyi ipynb; do
    ruff_fixture "ruff-link-to-regular-$suffix"
    path="alias.$suffix"
    object=$(printf 'module.txt' | git -C "$FX_WT" hash-object -w --stdin)
    git -C "$FX_WT" update-index --add --cacheinfo "120000,$object,$path"
    git -C "$FX_WT" commit -q -m 'old symlink on the remote'
    git -C "$FX_WT" push -q --no-verify origin HEAD:refs/heads/fm/t1
    before=$(git -C "$FX_WT" rev-parse HEAD)
    object=$(printf 'x=UNFORMATTED\n' | git -C "$FX_WT" hash-object -w --stdin)
    git -C "$FX_WT" update-index --cacheinfo "100644,$object,$path"
    git -C "$FX_WT" commit -q -m 'replace symlink with unformatted regular source'
    ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused 'a symlink-to-regular transition containing unformatted source' "$path"
    assert_equals "$before" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'an unformatted type transition advanced the remote'
    object=$(printf 'x = 1\n' | git -C "$FX_WT" hash-object -w --stdin)
    git -C "$FX_WT" update-index --cacheinfo "100644,$object,$path"
    git -C "$FX_WT" commit -q -m 'format the regular source'
    ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "a formatted symlink-to-regular transition was refused: $PUSH_OUT"
  done
  pass 'ruff format check: symlink-to-regular transitions are formatted rather than omitted'
}

test_ruff_format_reported_runner_commands_execute() {
  local real_ruff runner executable fix file
  real_ruff=$(command -v ruff) || { echo '# SKIP executable fix checks require real ruff'; return; }
  for runner in .venv venv path uvx uv; do
    ruff_fixture "ruff-fix-$runner with spaces"
    ruff_commit 'unformatted names and default settings' 'ruff.toml=' 'requirements-dev.txt=ruff==0.12.7' \
      'a file.py=x=1' "quote'file.py=x=1" '-leading.py=x=1'
    isolate_ruff_path
    case "$runner" in
      .venv | venv)
        mkdir -p "$FX_WT/$runner/bin"
        executable="$FX_WT/$runner/bin/ruff"
        ln -s "$real_ruff" "$executable"
        ;;
      path) executable="$FX_BIN/ruff"; ln -s "$real_ruff" "$executable" ;;
      *) write_real_ruff_uv_runner "$runner" "$real_ruff" ;;
    esac
    isolated_ruff_push origin HEAD:refs/heads/fm/t1
    ruff_refused "a push checked through $runner" 'a file.py' "quote'file.py" '-leading.py'
    collect_reported_fixes
    assert_equals 1 "${#FIX_COMMANDS[@]}" 'the push did not report one fix for its ref'
    fix=${FIX_COMMANDS[0]}
    (cd "$FX_WT" && PATH="$FX_BIN" bash -c "$fix") >/dev/null || fail "the printed $runner command could not execute: $fix"
    for file in 'a file.py' "quote'file.py" '-leading.py'; do
      assert_equals 'x = 1' "$(cat "$FX_WT/$file")" 'the reported command did not format the intended file'
    done
    git -C "$FX_WT" add -- 'a file.py' "quote'file.py" '-leading.py'
    git -C "$FX_WT" commit -q -m 'apply the printed fix'
    isolated_ruff_push origin HEAD:refs/heads/fm/t1
    [ "$PUSH_RC" -eq 0 ] || fail "the printed $runner fix did not allow the push: $PUSH_OUT"
    assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" 'the fixed commit did not reach the remote'
  done
  pass 'ruff format check: quoted fix commands execute via venv, PATH and pinned uv runners for special filenames'
}

test_ruff_format_reports_each_refs_pinned_runner() {
  local real_ruff first second fix
  real_ruff=$(command -v ruff) || { echo '# SKIP per-ref runner fix checks require real ruff'; return; }
  ruff_fixture 'ruff-fix-multiple refs'
  ruff_commit 'first pin and bad source' 'ruff.toml=' 'requirements-dev.txt=ruff==0.12.7' 'a.py=x=1'
  first=$(git -C "$FX_WT" rev-parse HEAD)
  ruff_commit 'second pin and bad source' 'requirements-dev.txt=ruff==0.13.1' 'a.py=x=2'
  second=$(git -C "$FX_WT" rev-parse HEAD)
  isolate_ruff_path
  write_real_ruff_uv_runner uvx "$real_ruff"
  isolated_ruff_push origin "$first:refs/heads/fm/one" "$second:refs/heads/fm/two"
  [ "$PUSH_RC" -ne 0 ] || fail 'unformatted multiple refs were accepted'
  collect_reported_fixes
  assert_equals 2 "${#FIX_COMMANDS[@]}" 'multiple refs did not retain separate runner fixes'
  : >"$FX_BIN/uvx.packages"
  for fix in "${FIX_COMMANDS[@]}"; do
    (cd "$FX_WT" && PATH="$FX_BIN" bash -c "$fix") >/dev/null || fail 'a per-ref pinned runner fix could not execute'
  done
  assert_equals $'ruff==0.12.7\nruff==0.13.1' "$(cat "$FX_BIN/uvx.packages")" "the fix commands reused another ref's formatter pin"
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/one >/dev/null && fail 'the first unformatted ref reached the remote'
  git -C "$FX_ORIGIN" rev-parse --verify --quiet refs/heads/fm/two >/dev/null && fail 'the second unformatted ref reached the remote'
  pass 'ruff format check: multiple refs retain and execute their own pinned runner fixes'
}

test_origin_pushes_are_refused
test_backup_namespace_rules
test_empty_prefix_still_refuses_the_task_branch
test_repository_pre_push_still_chains
test_unreadable_guard_refuses_everything
test_ruff_format_passes_formatted_files
test_ruff_format_refuses_unformatted_files
test_ruff_format_only_checks_the_pushed_changes
test_ruff_format_new_branch_uses_the_merge_base
test_ruff_format_missing_ruff_refuses
test_ruff_format_uses_pinned_uv_tools
test_ruff_format_errors_refuse
test_ruff_format_without_a_base_checks_every_supported_file
test_ruff_format_prefers_the_project_venv
test_ruff_format_uses_repository_declarations
test_ruff_format_and_push_guard_each_refuse_visibly
test_ruff_format_uses_committed_configuration
test_ruff_format_uses_each_pushed_refs_configuration
test_ruff_format_checks_stubs_notebooks_and_exclusions
test_ruff_format_ignores_external_configuration
test_pre_push_chaining_preserves_empty_and_nonempty_input
test_ruff_format_large_excluded_files_do_not_refuse
test_ruff_format_unreadable_committed_content_refuses
test_ruff_format_unpinned_uv_refuses
test_ruff_format_committed_symlinks_refuse
test_ruff_format_symlink_to_regular_is_checked
test_ruff_format_reported_runner_commands_execute
test_ruff_format_reports_each_refs_pinned_runner

echo "# all fm-git-push-guard and ruff format check tests passed"
