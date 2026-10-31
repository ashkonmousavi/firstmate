#!/usr/bin/env bash
# Behavior tests for bin/fm-git-push-guard.sh, the forge=external pre-push guard,
# and bin/fm-git-ruff-format-check.sh, the config/prepush-ruff-format pre-push check.
# Every case pushes with real git through a hooks directory installed by
# bin/fm-git-strip-ai-trailers.sh --push-guard or --ruff-format, the way a fleet
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

# ruff_fixture <name> [listed]: a worktree on fm/t1 whose hooks dir carries the
# ruff format check when <listed> is "listed" (the project is a line of the list)
# and an absent list otherwise, plus a fake ruff. Sets FX_WT, FX_HOOKS,
# FX_ORIGIN, FX_BIN.
ruff_fixture() {
  local name=$1 listed=${2:-listed} dir list
  dir="$TMP_ROOT/$name"
  fm_git_worktree "$dir/repo" "$dir/wt" fm/t1
  FX_WT="$dir/wt"
  FX_ORIGIN="$dir/repo.origin.git"
  FX_BIN="$dir/bin"
  mkdir -p "$FX_BIN"
  cat >"$FX_BIN/ruff" <<'EOF'
#!/usr/bin/env bash
# fake ruff: format --check --force-exclude --stdin-filename NAME -
name=
while [ "$#" -gt 0 ]; do
  [ "$1" != --stdin-filename ] || { name=$2; shift; }
  shift
done
if grep -q UNFORMATTED; then
  echo "Would reformat: $name" >&2
  exit 1
fi
exit 0
EOF
  chmod +x "$FX_BIN/ruff"
  list="$dir/prepush-ruff-format"
  if [ "$listed" = listed ]; then
    printf '# comment\n\nother-project\nproj\n' >"$list"
  fi
  FX_HOOKS="$dir/hooks"
  "$STRIP" install --ruff-format "$list" proj "$FX_HOOKS" "$FX_WT" || fail "install --ruff-format failed"
}

ruff_commit() {  # <message> <file>=<text>...; commits the files in FX_WT
  local msg=$1 spec
  shift
  for spec in "$@"; do
    mkdir -p "$(dirname "$FX_WT/${spec%%=*}")"
    printf '%s\n' "${spec#*=}" >"$FX_WT/${spec%%=*}"
    git -C "$FX_WT" add "${spec%%=*}"
  done
  git -C "$FX_WT" commit -q -m "$msg"
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
  assert_contains "$PUSH_OUT" "Fix: ruff format" "$label was refused without the fix command"
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
  assert_contains "$PUSH_OUT" "Fix: ruff format pkg/a.py pkg/c\\ d.py" "the fix command does not list exactly the unformatted files"
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

test_ruff_format_missing_ruff_warns_and_allows() {
  local bare name
  ruff_fixture ruff-missing
  ruff_commit 'unformatted' 'a.py=x=UNFORMATTED'
  bare="$TMP_ROOT/ruff-missing/path-without-ruff"
  mkdir -p "$bare"
  for name in git bash env sort cat sed sh dirname basename uname mktemp rm tr; do
    ln -sf "$(command -v "$name")" "$bare/$name" 2>/dev/null || true
  done
  PUSH_OUT=$(PATH="$bare" with_hooks "$FX_HOOKS" git -C "$FX_WT" push origin HEAD:refs/heads/fm/t1 2>&1)
  PUSH_RC=$?
  [ "$PUSH_RC" -eq 0 ] || fail "a missing ruff blocked the push: $PUSH_OUT"
  assert_contains "$PUSH_OUT" "fm-ruff-format: WARNING: ruff was not found" "a missing ruff was skipped silently"
  assert_equals "$(git -C "$FX_WT" rev-parse HEAD)" "$(git -C "$FX_ORIGIN" rev-parse refs/heads/fm/t1)" \
    "the push with no ruff did not reach the remote"
  pass "ruff format check: with no ruff available it warns loudly and allows the push"
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

test_ruff_format_is_off_unless_the_project_is_listed() {
  ruff_fixture ruff-unlisted unlisted
  ruff_commit 'unformatted' 'a.py=x=UNFORMATTED'
  ruff_push origin HEAD:refs/heads/fm/t1
  [ "$PUSH_RC" -eq 0 ] || fail "an absent list still refused an unformatted push: $PUSH_OUT"
  printf 'other-project\n' >"$TMP_ROOT/ruff-unlisted/prepush-ruff-format"
  "$STRIP" install --ruff-format "$TMP_ROOT/ruff-unlisted/prepush-ruff-format" proj "$TMP_ROOT/ruff-unlisted/hooks2" "$FX_WT" \
    || fail "install --ruff-format failed for a list without the project"
  FX_HOOKS="$TMP_ROOT/ruff-unlisted/hooks2"
  ruff_push origin HEAD:refs/heads/fm/t2
  [ "$PUSH_RC" -eq 0 ] || fail "a list without this project still refused an unformatted push: $PUSH_OUT"
  pass "ruff format check: an absent list, or one that does not name the project, leaves pushes alone"
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
  printf 'proj\n' >"$dir/prepush-ruff-format"
  FX_HOOKS="$dir/hooks"
  "$STRIP" install --push-guard "$guard" --ruff-format "$dir/prepush-ruff-format" proj "$FX_HOOKS" "$FX_WT" || fail "install failed"
  ruff_commit 'unformatted' 'a.py=x=UNFORMATTED'
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

test_origin_pushes_are_refused
test_backup_namespace_rules
test_empty_prefix_still_refuses_the_task_branch
test_repository_pre_push_still_chains
test_unreadable_guard_refuses_everything
test_ruff_format_passes_formatted_files
test_ruff_format_refuses_unformatted_files
test_ruff_format_only_checks_the_pushed_changes
test_ruff_format_new_branch_uses_the_merge_base
test_ruff_format_missing_ruff_warns_and_allows
test_ruff_format_prefers_the_project_venv
test_ruff_format_is_off_unless_the_project_is_listed
test_ruff_format_and_push_guard_each_refuse_visibly
test_ruff_format_uses_committed_configuration
test_ruff_format_uses_each_pushed_refs_configuration

echo "# all fm-git-push-guard and ruff format check tests passed"
