#!/usr/bin/env bash
# Behavior tests for primary-authoritative shared captain-preference inheritance.
#
# The narrow shared surface is exactly data/captain-shared.md.
# data/captain.md and data/learnings.md remain domain-local in every home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-shared-captain)

fm_git_identity fmtest fmtest@example.invalid

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

shared_header() {
  cat <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes and must not be edited there.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF
}

write_shared() {
  local path=$1 body=$2
  shared_header > "$path"
  printf '%s\n' "$body" >> "$path"
}

new_home_pair() {
  local name=$1 base primary second
  base="$TMP_ROOT/$name"
  primary="$base/primary"
  second="$base/second"
  mkdir -p "$primary/data" "$primary/config" "$second/data" "$second/config"
  printf '%s\n' "primary local captain" > "$primary/data/captain.md"
  printf '%s\n' "second local captain" > "$second/data/captain.md"
  printf '%s\n' "primary local learning" > "$primary/data/learnings.md"
  printf '%s\n' "second local learning" > "$second/data/learnings.md"
  printf '%s\n' "$primary|$second"
}

assert_shared_readonly() {
  local path=$1
  [ "$(file_mode "$path")" = "$FM_SHARED_CAPTAIN_MODE" ] \
    || fail "$path mode should be $FM_SHARED_CAPTAIN_MODE, got $(file_mode "$path")"
}

assert_secondmate_write_fails() {
  local path=$1
  if ( printf '%s\n' "secondmate edit" >> "$path" ) 2>/dev/null; then
    fail "ordinary write unexpectedly succeeded for read-only shared captain file"
  fi
}

test_first_copy_readonly_and_local_files_preserved() {
  local rec primary second report out qcount
  rec=$(new_home_pair first-copy)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v1"
  report="$TMP_ROOT/first-copy.report"

  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")

  [ -z "$out" ] || fail "first copy should not emit a quarantine diagnostic: $out"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "first copy did not converge secondmate shared preferences"
  assert_shared_readonly "$second/data/captain-shared.md"
  assert_secondmate_write_fails "$second/data/captain-shared.md"
  assert_grep $'data/captain-shared.md\tpushed\t' "$report" "first copy should report pushed"
  assert_grep "second local captain" "$second/data/captain.md" "domain-local captain.md was changed"
  assert_grep "second local learning" "$second/data/learnings.md" "domain-local learnings.md was changed"

  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "unchanged convergence should stay quiet: $out"
  assert_grep $'data/captain-shared.md\tunchanged\t' "$report" "unchanged bytes should report unchanged"
  assert_shared_readonly "$second/data/captain-shared.md"

  write_shared "$primary/data/captain-shared.md" "shared v2"
  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "source-only edit should not emit a quarantine diagnostic: $out"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "source-only edit did not converge secondmate shared preferences"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 0 ] || fail "source-only edit quarantined an untouched inherited destination"
  assert_grep $'data/captain-shared.md\tpushed\t' "$report" "source-only edit should report pushed"
  assert_not_contains "$(cat "$report")" "quarantined local drift" \
    "source-only edit should not report local drift"
  assert_shared_readonly "$second/data/captain-shared.md"
  pass "shared captain first copy, unchanged copy, and source-only edit stay quiet"
}

test_true_divergence_after_inherit_still_quarantines() {
  local rec primary second report out diag qpath qcount
  rec=$(new_home_pair true-divergence)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v1"
  report="$TMP_ROOT/true-divergence.report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "setup inherit should stay quiet: $out"

  chmod u+w "$second/data/captain-shared.md"
  write_shared "$second/data/captain-shared.md" "local edit after inherit"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"
  write_shared "$primary/data/captain-shared.md" "shared v2"
  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  diag=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate home ' || true)
  [ -n "$diag" ] || fail "edited destination should emit a SECONDMATE_SYNC diagnostic"
  qpath=${diag##* at }
  assert_grep "local edit after inherit" "$qpath" "true-divergence quarantine lost the edited bytes"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "true-divergence convergence did not install primary bytes"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 1 ] || fail "true-divergence should leave exactly one quarantine artifact"
  assert_grep $'data/captain-shared.md\tpushed\tquarantined local drift at '"$qpath" "$report" \
    "true-divergence push should name the quarantine artifact"
  pass "shared captain true divergence after inherit is still quarantined"
}

test_interrupted_publication_matching_source_does_not_quarantine() {
  local rec primary second report out qcount
  rec=$(new_home_pair interrupted-pub)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v1"
  report="$TMP_ROOT/interrupted-pub.report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "setup inherit should stay quiet: $out"

  write_shared "$primary/data/captain-shared.md" "shared v2"
  chmod u+w "$second/data/captain-shared.md"
  cp "$primary/data/captain-shared.md" "$second/data/captain-shared.md"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"

  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "destination already matching the new source should not quarantine: $out"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 0 ] || fail "interrupted publication matching source created a quarantine artifact"
  assert_grep $'data/captain-shared.md\tunchanged\t' "$report" \
    "destination already matching source should report unchanged"
  assert_shared_readonly "$second/data/captain-shared.md"

  write_shared "$primary/data/captain-shared.md" "shared v3"
  : > "$report"
  out=$(FM_CONFIG_INHERIT_REPORT="$report" propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "healed receipt should accept a later source-only edit quietly: $out"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "later source-only edit after healed receipt did not converge"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 0 ] || fail "later source-only edit after healed receipt quarantined"
  pass "interrupted publication that already matches source heals without quarantine"
}

# The remote secondmate route reaches the same destination through
# bin/fm-remote-inherit.sh, so it owes the same answer: an untouched inherited
# copy is ordinary convergence, a locally edited one is drift worth keeping.
remote_put_shared() {
  local home=$1 payload=$2 generation=$3 bytes hash
  bytes=$(LC_ALL=C wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash remote inheritance payload"
  PATH="$BASE_PATH" FM_HOME="$home" "$ROOT/bin/fm-remote-inherit.sh" \
    put data/captain-shared.md "$bytes" "$hash" "$generation" < "$payload" 2>&1
}

remote_quarantine_count() {
  find "$1/data" -name 'captain-shared.md.remote-quarantine-*' | wc -l | tr -d ' '
}

test_remote_receiver_accepts_source_only_edit_without_quarantine() {
  local home source out qpath
  home="$TMP_ROOT/remote-receiver/home"
  source="$TMP_ROOT/remote-receiver/source.md"
  mkdir -p "$home/data" "$home/config" "$TMP_ROOT/remote-receiver"

  write_shared "$source" "shared v1"
  out=$(remote_put_shared "$home" "$source" 1) || fail "remote first inherit failed: $out"
  assert_contains "$out" "pushed: data/captain-shared.md" "remote first inherit did not publish"
  assert_shared_readonly "$home/data/captain-shared.md"

  write_shared "$source" "shared v2"
  out=$(remote_put_shared "$home" "$source" 2) || fail "remote source-only edit failed: $out"
  assert_not_contains "$out" "quarantined:" \
    "remote source-only edit quarantined an untouched inherited copy"
  [ "$(remote_quarantine_count "$home")" -eq 0 ] \
    || fail "remote source-only edit left a recovery copy for an untouched destination"
  cmp -s "$source" "$home/data/captain-shared.md" \
    || fail "remote source-only edit did not converge the destination"
  assert_shared_readonly "$home/data/captain-shared.md"

  chmod u+w "$home/data/captain-shared.md"
  write_shared "$home/data/captain-shared.md" "remote local edit"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$home/data/captain-shared.md"
  write_shared "$source" "shared v3"
  out=$(remote_put_shared "$home" "$source" 3) || fail "remote divergent inherit failed: $out"
  assert_contains "$out" "quarantined:" "remote edited destination was replaced without a recovery copy"
  [ "$(remote_quarantine_count "$home")" -eq 1 ] \
    || fail "remote divergence should leave exactly one recovery copy"
  qpath=$(find "$home/data" -name 'captain-shared.md.remote-quarantine-*')
  assert_grep "remote local edit" "$qpath" "remote quarantine lost the edited bytes"
  cmp -s "$source" "$home/data/captain-shared.md" \
    || fail "remote divergent inherit did not install the primary bytes"
  assert_shared_readonly "$home/data/captain-shared.md"
  pass "remote receiver accepts a source-only edit quietly and still quarantines real drift"
}

test_drift_quarantine_collision_and_repeated_convergence() {
  local rec primary second fakebin hash collision report out diag qpath qcount
  rec=$(new_home_pair drift)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$primary/data/captain-shared.md" "shared v2"
  write_shared "$second/data/captain-shared.md" "local drift"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"
  hash=$(fm_inherit_sha256 "$second/data/captain-shared.md")
  collision="$second/data/.captain-shared.md.quarantine.20260102T030405Z.$hash"
  printf '%s\n' "preexisting different artifact" > "$collision"
  chmod 0600 "$collision"

  fakebin="$TMP_ROOT/fake-date"
  mkdir -p "$fakebin"
  cat > "$fakebin/date" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 20260102T030405Z
SH
  chmod +x "$fakebin/date"
  report="$TMP_ROOT/drift.report"

  out=$(PATH="$fakebin:$BASE_PATH" FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_secondmate_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate home ' || true)
  [ -n "$diag" ] || fail "drift quarantine should emit a SECONDMATE_SYNC diagnostic"
  qpath=${diag##* at }
  [ "$qpath" = "$collision.1" ] || fail "collision-safe quarantine name should use .1, got $qpath"
  assert_grep "local drift" "$qpath" "quarantine artifact lost the secondmate-local bytes"
  assert_grep $'data/captain-shared.md\tpushed\tquarantined local drift at '"$qpath" "$report" \
    "drift push should name the quarantine artifact in the report"
  cmp -s "$primary/data/captain-shared.md" "$second/data/captain-shared.md" \
    || fail "drift convergence did not install primary bytes"
  assert_shared_readonly "$second/data/captain-shared.md"

  : > "$report"
  out=$(PATH="$fakebin:$BASE_PATH" FM_CONFIG_INHERIT_REPORT="$report" \
    propagate_secondmate_inheritance "$primary" "$second")
  [ -z "$out" ] || fail "repeated convergence should not quarantine again: $out"
  qcount=$(find "$second/data" -name '.captain-shared.md.quarantine.*' | wc -l | tr -d ' ')
  [ "$qcount" -eq 2 ] || fail "repeated convergence created extra quarantine artifacts"
  assert_grep $'data/captain-shared.md\tunchanged\t' "$report" "repeated convergence should report unchanged"
  pass "shared captain drift is quarantined collision-safely and repeated convergence is idempotent"
}

test_missing_source_mirrors_absence_without_losing_local_bytes() {
  local rec primary second out diag qpath
  rec=$(new_home_pair missing-source)
  primary=${rec%%|*}
  second=${rec#*|}
  write_shared "$second/data/captain-shared.md" "orphaned local shared file"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"

  out=$(propagate_secondmate_inheritance "$primary" "$second")

  diag=$(printf '%s\n' "$out" | grep '^SECONDMATE_SYNC: secondmate home ' || true)
  [ -n "$diag" ] || fail "primary absence with a local copy should quarantine before removal"
  qpath=${diag##* at }
  assert_absent "$second/data/captain-shared.md" "primary absence should converge destination to absence"
  assert_grep "orphaned local shared file" "$qpath" "missing-source quarantine lost local bytes"
  assert_grep "second local captain" "$second/data/captain.md" "missing-source changed local captain.md"
  assert_grep "second local learning" "$second/data/learnings.md" "missing-source changed local learnings.md"
  pass "missing primary shared file mirrors absence only after quarantining a local copy"
}

test_unsafe_artifacts_and_failure_restore_readonly_mode() {
  local rec primary second other err before_mode rc
  rec=$(new_home_pair unsafe)
  primary=${rec%%|*}
  second=${rec#*|}

  ln -s "$primary/data/captain.md" "$primary/data/captain-shared.md"
  err="$TMP_ROOT/unsafe-source.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked primary source should be rejected"
  assert_grep "unsafe primary source" "$err" "unsafe source error should be explicit"
  rm -f "$primary/data/captain-shared.md"
  write_shared "$primary/data/captain-shared.md" "safe source"

  ln -s "$second/data/captain.md" "$second/data/captain-shared.md"
  err="$TMP_ROOT/unsafe-dest-symlink.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "symlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination symlink error should be explicit"
  rm -f "$second/data/captain-shared.md"

  write_shared "$second/data/captain-shared.md" "hardlinked local drift"
  other="$second/data/hardlink-copy"
  ln "$second/data/captain-shared.md" "$other"
  err="$TMP_ROOT/unsafe-dest-hardlink.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  [ "$rc" -ne 0 ] || fail "hardlinked destination should be rejected"
  assert_grep "unsafe destination" "$err" "unsafe destination hardlink error should be explicit"
  rm -f "$second/data/captain-shared.md" "$other"

  # Root reads a mode-000 file regardless, which would make this case vacuous.
  if [ "$(id -u)" != 0 ]; then
    write_shared "$second/data/captain-shared.md" "unreadable local bytes"
    chmod 000 "$second/data/captain-shared.md"
    err="$TMP_ROOT/unreadable-dest.err"
    propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
    chmod 600 "$second/data/captain-shared.md"
    [ "$rc" -ne 0 ] || fail "an unhashable destination should not converge silently"
    assert_grep "failed to hash destination" "$err" "unhashable destination error should be explicit"
    assert_grep "unreadable local bytes" "$second/data/captain-shared.md" \
      "unhashable destination was replaced without keeping its bytes"
    rm -f "$second/data/captain-shared.md"
  fi

  write_shared "$second/data/captain-shared.md" "permission drift"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$second/data/captain-shared.md"
  before_mode=$(file_mode "$second/data/captain-shared.md")
  chmod 500 "$second/data"
  err="$TMP_ROOT/restore-readonly.err"
  propagate_secondmate_inheritance "$primary" "$second" >/dev/null 2>"$err"; rc=$?
  chmod 700 "$second/data"
  [ "$rc" -ne 0 ] || fail "unwritable destination directory should make quarantine fail"
  [ "$(file_mode "$second/data/captain-shared.md")" = "$before_mode" ] \
    || fail "failed quarantine did not restore read-only mode"
  assert_grep "failed to quarantine divergent destination" "$err" \
    "recoverable failure should explain quarantine failure"
  pass "unsafe shared captain artifacts are rejected and failure restores read-only mode"
}

test_header_check_names_the_missing_phrase() {
  local valid_path missing_path out rc

  valid_path="$TMP_ROOT/valid-header.md"
  shared_header > "$valid_path"
  out=$(shared_captain_header_valid "$valid_path"); rc=$?
  [ "$rc" -eq 0 ] || fail "the valid fixture header should still pass"
  [ -z "$out" ] || fail "a passing header should not report a missing phrase, got: $out"

  missing_path="$TMP_ROOT/missing-phrase-header.md"
  cat > "$missing_path" <<'EOF'
# Shared captain preferences

This file is main-authoritative in the main firstmate home.
In secondmate homes it is read-only in secondmate homes.
Route new captain-preference discoveries to the main firstmate through marked status or a document pointer.
EOF
  out=$(shared_captain_header_valid "$missing_path"); rc=$?
  [ "$rc" -ne 0 ] || fail "a header missing a required phrase should still fail"
  assert_contains "$out" "must not be edited there" \
    "the failure should name the one phrase this header is missing"

  pass "the header check names the first required phrase it did not find, without widening the accept set"
}

make_fake_spawn_toolchain() {
  local dir=$1 fakebin
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# Version-aware stubs so bootstrap's tool floors stay quiet in fixture PATH.
add_bootstrap_compatible_tools() {
  local fakebin=$1
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi gh treehouse
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi" "$fakebin/no-mistakes" "$fakebin/tasks-axi" "$fakebin/quota-axi"
}

new_git_world() {
  local name=$1 w root home c1
  w="$TMP_ROOT/$name"
  root="$w/root"
  home="$w/home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  git init -q -b main "$root"
  {
    printf '%s\n' '.fm-secondmate-home'
    printf '%s\n' 'data/'
    printf '%s\n' 'state/'
    printf '%s\n' 'config/'
    printf '%s\n' 'projects/'
  } > "$root/.gitignore"
  printf '%s\n' "instructions" > "$root/AGENTS.md"
  mkdir -p "$root/bin" "$root/.agents/skills"
  printf '%s\n' "echo spawn" > "$root/bin/fm-spawn.sh"
  printf '%s\n' "skill" > "$root/.agents/skills/example.md"
  git -C "$root" add -A
  git -C "$root" commit -qm initial
  c1=$(git -C "$root" rev-parse HEAD)
  git -C "$root" worktree add -q --detach "$w/sm" "$c1"
  printf '%s\n' sm > "$w/sm/.fm-secondmate-home"
  mkdir -p "$w/sm/data" "$w/sm/state" "$w/sm/config" "$w/sm/projects"
  printf '%s\n' "charter" > "$w/sm/data/charter.md"
  write_shared "$home/data/captain-shared.md" "shared from primary"
  printf '%s|%s|%s|%s\n' "$w" "$root" "$home" "$w/sm"
}

test_spawn_convergence_point_copies_shared_file() {
  local rec w root home sm fakebin data_override
  rec=$(new_git_world spawn-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/captain-shared.md" "shared from override"
  fakebin=$(make_fake_spawn_toolchain "$w")

  PATH="$fakebin:$BASE_PATH" TMUX='' \
    FM_ROOT_OVERRIDE="$root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$data_override" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" sm "$sm" codex --secondmate >/dev/null 2>&1 || true

  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "spawn convergence point did not copy shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "spawn convergence point propagates data/captain-shared.md from FM_DATA_OVERRIDE"
}

test_bootstrap_convergence_point_copies_shared_file() {
  local rec w root home sm fakebin data_override out
  rec=$(new_git_world bootstrap-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  write_shared "$data_override/captain-shared.md" "shared from bootstrap override"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
  } > "$home/state/sm.meta"
  printf -- '- sm - fixture secondmate (home: %s; scope: fixture; projects: sample; added 2026-07-16)\n' "$sm" \
    > "$data_override/secondmates.md"
  fakebin=$(make_fake_spawn_toolchain "$w")
  add_bootstrap_compatible_tools "$fakebin"

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)

  assert_not_contains "$out" "SECONDMATE_SYNC: secondmate sm: skipped: inheritance failed" \
    "bootstrap inheritance should succeed"
  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "bootstrap convergence point did not copy shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "bootstrap convergence point propagates data/captain-shared.md from FM_DATA_OVERRIDE"
}

test_config_push_convergence_point_updates_changed_source() {
  local rec w root home sm data_override out
  rec=$(new_git_world config-push-point)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  write_shared "$sm/data/captain-shared.md" "old shared bytes"
  chmod "$FM_SHARED_CAPTAIN_MODE" "$sm/data/captain-shared.md"
  write_shared "$data_override/captain-shared.md" "changed override shared bytes"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-config-push.sh" 2>/dev/null)

  assert_contains "$out" "data/captain-shared.md: pushed - quarantined local drift at" \
    "config-push should report the shared file update and quarantine"
  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "config-push convergence point did not update shared captain preferences from FM_DATA_OVERRIDE"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "fm-config-push convergence point updates changed shared captain source bytes from FM_DATA_OVERRIDE"
}

test_config_push_source_only_edit_after_inherit_stays_quiet() {
  local rec w root home sm data_override out
  rec=$(new_git_world config-push-source-only)
  IFS='|' read -r w root home sm <<EOF
$rec
EOF
  data_override="$w/primary-data-override"
  mkdir -p "$data_override"
  {
    printf 'window=firstmate:fm-sm\n'
    printf 'kind=secondmate\n'
    printf 'home=%s\n' "$sm"
  } > "$home/state/sm.meta"
  write_shared "$data_override/captain-shared.md" "inherited shared bytes"
  PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-config-push.sh" >/dev/null 2>&1
  write_shared "$data_override/captain-shared.md" "updated shared bytes"

  out=$(PATH="$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_DATA_OVERRIDE="$data_override" \
    "$ROOT/bin/fm-config-push.sh" 2>/dev/null)

  assert_contains "$out" "data/captain-shared.md: pushed" \
    "config-push should report the shared file source-only update"
  assert_not_contains "$out" "quarantined local drift" \
    "config-push source-only edit after inherit should not report drift"
  cmp -s "$data_override/captain-shared.md" "$sm/data/captain-shared.md" \
    || fail "config-push source-only edit after inherit did not converge"
  assert_shared_readonly "$sm/data/captain-shared.md"
  pass "fm-config-push source-only edit after inherit stays quiet"
}

test_session_start_digest_labels_shared_file_and_read_once_rule() {
  local rec w root home _sm fakebin out contract
  rec=$(new_git_world session-start-label)
  IFS='|' read -r w root home _sm <<EOF
$rec
EOF
  fakebin=$(make_fake_spawn_toolchain "$w")
  add_bootstrap_compatible_tools "$fakebin"
  fm_fake_exit0 "$fakebin" pgrep

  out=$(PATH="$fakebin:$BASE_PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    "$ROOT/bin/fm-session-start.sh")

  assert_contains "$out" "data/captain-shared.md (shared, main-authoritative, read-only in secondmate homes)" \
    "session-start digest should label the shared captain file unmistakably"
  assert_contains "$out" "shared from primary" "session-start digest should render the shared file"
  contract=$(printf '%s\n' "$out" | awk '/^READ-ONCE CONTRACT$/ { f = 1 } /^FLEET STATE$/ { f = 0 } f')
  assert_contains "$contract" "data/captain-shared.md" \
    "read-once contract should name captain-shared.md among the files it covers"
  pass "session-start digest renders data/captain-shared.md with the shared read-only label"
}

test_first_copy_readonly_and_local_files_preserved
test_true_divergence_after_inherit_still_quarantines
test_interrupted_publication_matching_source_does_not_quarantine
test_remote_receiver_accepts_source_only_edit_without_quarantine
test_drift_quarantine_collision_and_repeated_convergence
test_missing_source_mirrors_absence_without_losing_local_bytes
test_unsafe_artifacts_and_failure_restore_readonly_mode
test_spawn_convergence_point_copies_shared_file
test_bootstrap_convergence_point_copies_shared_file
test_config_push_convergence_point_updates_changed_source
test_config_push_source_only_edit_after_inherit_stays_quiet
test_session_start_digest_labels_shared_file_and_read_once_rule
test_header_check_names_the_missing_phrase

echo "# all fm-shared-captain-inheritance tests passed"

# Worker policy uses the existing config inheritance path; home-local brief
# additions and host facts must never be overwritten by this shared source.
test_worker_sheet_config_inheritance() {
  local base primary second remote hash bytes before
  base="$TMP_ROOT/worker-policy"
  primary="$base/primary"
  second="$base/second"
  remote="$base/remote"
  mkdir -p "$primary/config" "$second/config" "$second/data" "$remote/config" "$remote/data"
  printf 'Shared scope: all workers; X scope: full walker access.\n' > "$primary/config/worker-sheet.md"
  printf 'Host-specific room check and cache paths.\n' > "$second/config/brief-include.md"
  cp "$second/config/brief-include.md" "$remote/config/brief-include.md"
  propagate_inheritable_config "$primary/config" "$second/config" "$primary" || fail "worker policy local propagation failed"
  cmp "$primary/config/worker-sheet.md" "$second/data/worker-sheet.md" || fail "worker source not inherited through compatibility alias"
  before=$(cat "$second/config/brief-include.md")
  printf 'Updated full condition: act only after current proof; keep all task rules.\n' >> "$primary/config/worker-sheet.md"
  propagate_inheritable_config "$primary/config" "$second/config" "$primary" || fail "worker policy update failed"
  cmp "$primary/config/worker-sheet.md" "$second/data/worker-sheet.md" || fail "worker source update drifted"
  [ "$(cat "$second/config/brief-include.md")" = "$before" ] || fail "home brief additions overwritten"
  hash=$(fm_inherit_sha256 "$primary/config/worker-sheet.md") || fail "source hash failed"
  bytes=$(wc -c < "$primary/config/worker-sheet.md" | tr -d ' ')
  FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 1 < "$primary/config/worker-sheet.md" || fail "remote worker policy transfer refused"
  cmp "$primary/config/worker-sheet.md" "$remote/data/worker-sheet.md" || fail "remote worker policy differs"
  [ "$(cat "$remote/config/brief-include.md")" = "$before" ] || fail "remote host additions overwritten"
  FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 1 < "$primary/config/worker-sheet.md" || fail "same generation should be idempotent"
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/brief-include.md "$bytes" "$hash" 2 < "$primary/config/worker-sheet.md" >/dev/null 2>&1; then
    fail "host-specific include unexpectedly inherited"
  fi
  if printf 'wrong bytes\n' | FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 2 >/dev/null 2>&1; then
    fail "wrong worker source digest accepted"
  fi
  cmp "$primary/config/worker-sheet.md" "$remote/data/worker-sheet.md" || fail "refused transfer damaged source"
  FM_HOME="$second" bash "$ROOT/bin/fm-brief.sh" fresh-local project --mode direct-PR >/dev/null || fail "fresh inherited local home cannot scaffold"
  FM_HOME="$remote" bash "$ROOT/bin/fm-brief.sh" fresh-remote project --scout >/dev/null || fail "fresh inherited remote home cannot scaffold"
  printf 'New unique owner edit.\n' > "$remote/data/new-edit"
  mv "$remote/data/new-edit" "$remote/data/worker-sheet.md"
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 2 < "$primary/config/worker-sheet.md" >/dev/null 2>&1; then
    fail "remote propagation silently ignored an independent owner edit"
  fi
  assert_grep 'New unique owner edit.' "$remote/data/worker-sheet.md" "remote owner edit was lost"
  pass "worker-sheet config converges through native local and remote routes without replacing home facts"
}

test_worker_sheet_config_inheritance

# The native sender must not publish an older config source after an editor
# atomically replaces its data compatibility alias with a new owner edit.
test_worker_sheet_sender_refuses_alias_drift() {
  local base bin home config data alias calls name
  base="$TMP_ROOT/worker-sender"
  bin="$base/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-remote-inherit-push.sh" "$bin/"
  for name in fm-config-inherit-lib.sh fm-secondmate-registry-lib.sh fm-startup-memory-budget-lib.sh fm-role-lib.sh; do
    ln -s "$ROOT/bin/$name" "$bin/$name"
  done
  cat > "$bin/fm-on.sh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FM_TEST_CALL_LOG"
cat >/dev/null
printf 'transport called\n'
EOF
  chmod 755 "$bin/fm-on.sh"
  calls="$base/calls"

  home="$base/default"
  config="$home/config"
  data="$home/data"
  mkdir -p "$config" "$data"
  printf 'canonical policy\n' > "$config/worker-sheet.md"
  ln -s ../config/worker-sheet.md "$data/worker-sheet.md"
  printf '%s\n' '- test - fixture (host: fixture; root: /tmp/fixture; home: /tmp/fixture; scope: test; projects: none; added 2026-10-25)' > "$data/secondmates.md"
  FM_HOME="$home" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 1 > "$base/default-valid.out" 2>&1 \
    || fail "valid default source could not be sent"
  [ -L "$data/worker-sheet.md" ] && [ "$data/worker-sheet.md" -ef "$config/worker-sheet.md" ] \
    || fail "valid default source compatibility alias was not preserved"
  assert_grep 'config/worker-sheet.md' "$calls" "valid default source was not sent"
  : > "$calls"
  printf 'new owner edit\n' > "$data/new-edit"
  mv "$data/new-edit" "$data/worker-sheet.md"
  if FM_HOME="$home" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 2 > "$base/default-drift.out" 2>&1; then
    fail "atomic default alias replacement sent stale canonical policy"
  fi
  [ ! -s "$calls" ] || fail "default alias drift reached remote transport"
  assert_grep 'new owner edit' "$data/worker-sheet.md" "default owner edit was lost"
  assert_grep 'canonical policy' "$config/worker-sheet.md" "default canonical bytes changed"
  rm "$config/worker-sheet.md"
  if FM_HOME="$home" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 3 > "$base/default-orphan-regular.out" 2>&1; then
    fail "sender accepted regular alias after canonical source disappeared"
  fi
  [ ! -s "$calls" ] || fail "orphaned regular alias reached remote transport"
  rm "$data/worker-sheet.md"
  ln -s ../config/worker-sheet.md "$data/worker-sheet.md"
  if FM_HOME="$home" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 4 > "$base/default-orphan-link.out" 2>&1; then
    fail "sender accepted dangling alias after canonical source disappeared"
  fi
  [ ! -s "$calls" ] || fail "orphaned dangling alias reached remote transport"

  home="$base/override"
  config="$home/config-override"
  data="$home/data-override"
  alias="$data/worker-sheet.md"
  mkdir -p "$config" "$data"
  printf 'canonical policy\n' > "$config/worker-sheet.md"
  ln -s ../config-override/worker-sheet.md "$alias"
  printf '%s\n' '- test - fixture (host: fixture; root: /tmp/fixture; home: /tmp/fixture; scope: test; projects: none; added 2026-10-25)' > "$data/secondmates.md"
  : > "$calls"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 1 > "$base/override-valid.out" 2>&1 \
    || fail "valid overridden source could not be sent"
  assert_grep 'config/worker-sheet.md' "$calls" "valid overridden source was not sent"
  : > "$calls"
  printf 'new override owner edit\n' > "$data/new-edit"
  mv "$data/new-edit" "$alias"
  if FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 2 > "$base/override-drift.out" 2>&1; then
    fail "atomic overridden alias replacement sent stale canonical policy"
  fi
  [ ! -s "$calls" ] || fail "overridden alias drift reached remote transport"
  assert_grep 'new override owner edit' "$alias" "overridden owner edit was lost"
  assert_grep 'canonical policy' "$config/worker-sheet.md" "overridden canonical bytes changed"
  rm "$config/worker-sheet.md"
  if FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 3 > "$base/override-orphan-regular.out" 2>&1; then
    fail "sender accepted overridden regular alias without canonical source"
  fi
  [ ! -s "$calls" ] || fail "overridden orphaned alias reached remote transport"
  rm "$alias"
  ln -s ../config-override/worker-sheet.md "$alias"
  if FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" FM_DATA_OVERRIDE="$data" FM_INHERITABLE_CONFIG=worker-sheet.md FM_REMOTE_INHERIT_PUSH_JOBS=1 FM_TEST_CALL_LOG="$calls" \
    bash "$bin/fm-remote-inherit-push.sh" test 4 > "$base/override-orphan-link.out" 2>&1; then
    fail "sender accepted overridden dangling alias without canonical source"
  fi
  [ ! -s "$calls" ] || fail "overridden dangling alias reached remote transport"
  pass "worker policy sender checks default and overridden aliases before remote transport"
}

test_worker_sheet_sender_refuses_alias_drift

test_worker_sheet_orphans_refuse_local_and_receiver_writes() {
  local base primary second remote payload bytes hash empty_hash
  base="$TMP_ROOT/worker-orphans"
  primary="$base/primary"
  second="$base/second"
  remote="$base/remote"
  mkdir -p "$primary/config" "$primary/data" "$second/config" "$second/data" "$remote/config" "$remote/data"
  printf 'current owner policy\n' > "$primary/config/worker-sheet.md"
  FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary" \
    || fail "worker policy setup inheritance failed"
  rm "$primary/config/worker-sheet.md"
  if FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary"; then
    fail "local inheritance accepted dangling source alias and removed destination policy"
  fi
  assert_grep 'current owner policy' "$second/config/worker-sheet.md" "destination policy was deleted"
  rm "$primary/data/worker-sheet.md"
  printf 'new owner edit\n' > "$primary/data/worker-sheet.md"
  if FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary"; then
    fail "local inheritance accepted independent source edit without canonical policy"
  fi
  assert_grep 'new owner edit' "$primary/data/worker-sheet.md" "source owner edit was lost"
  rm "$primary/data/worker-sheet.md"
  printf 'current owner policy\n' > "$primary/config/worker-sheet.md"
  ln -s ../config/worker-sheet.md "$primary/data/worker-sheet.md"
  rm "$second/config/worker-sheet.md"
  if FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary"; then
    fail "local inheritance silently repaired an orphaned destination alias"
  fi
  [ ! -e "$second/config/worker-sheet.md" ] && [ -L "$second/data/worker-sheet.md" ] \
    || fail "orphaned destination alias was changed"
  rm "$primary/config/worker-sheet.md" "$primary/data/worker-sheet.md" "$second/data/worker-sheet.md"
  FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary" \
    || fail "optional policy with both paths absent was refused"
  [ ! -e "$second/data/worker-sheet.md" ] && [ ! -L "$second/data/worker-sheet.md" ] \
    || fail "optional absence created an alias"

  payload="$base/payload"
  printf 'current owner policy\n' > "$payload"
  bytes=$(wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash policy fixture"
  : > "$base/empty"
  empty_hash=$(fm_inherit_sha256 "$base/empty") || fail "cannot hash empty fixture"
  printf 'new remote owner edit\n' > "$remote/data/worker-sheet.md"
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 1 < "$payload" >/dev/null 2>&1; then
    fail "remote receiver overwrote orphaned regular alias"
  fi
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" absent config/worker-sheet.md 0 "$empty_hash" 1 >/dev/null 2>&1; then
    fail "remote receiver accepted absence with orphaned regular alias"
  fi
  assert_grep 'new remote owner edit' "$remote/data/worker-sheet.md" "remote owner edit was lost"
  rm "$remote/data/worker-sheet.md"
  ln -s ../config/worker-sheet.md "$remote/data/worker-sheet.md"
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 1 < "$payload" >/dev/null 2>&1; then
    fail "remote receiver accepted orphaned dangling alias"
  fi
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" absent config/worker-sheet.md 0 "$empty_hash" 1 >/dev/null 2>&1; then
    fail "remote receiver accepted absence with orphaned dangling alias"
  fi
  [ -L "$remote/data/worker-sheet.md" ] && [ ! -e "$remote/config/worker-sheet.md" ] \
    || fail "remote orphaned alias state was changed"
  rm "$remote/data/worker-sheet.md"
  FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" absent config/worker-sheet.md 0 "$empty_hash" 1 >/dev/null \
    || fail "remote receiver refused optional absence with both paths absent"
  pass "worker policy orphaned aliases refuse local and remote writes while preserving optional absence"
}

test_worker_sheet_orphans_refuse_local_and_receiver_writes

test_worker_sheet_failed_publication_leaves_fresh_alias_absent() {
  local base primary second remote payload bytes hash empty_hash report out
  base="$TMP_ROOT/worker-failed-publication"
  primary="$base/primary"
  second="$base/second"
  remote="$base/remote"
  mkdir -p "$primary/config" "$primary/data" "$second/config" "$second/data" "$remote/config" "$remote/data"
  printf 'current owner policy\n' > "$primary/config/worker-sheet.md"
  if (
    copy_inheritable_file() { return 1; }
    FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary"
  ) >/dev/null 2>&1; then
    fail "injected local copy failure unexpectedly succeeded"
  fi
  [ ! -e "$second/config/worker-sheet.md" ] && [ ! -e "$second/data/worker-sheet.md" ] && [ ! -L "$second/data/worker-sheet.md" ] \
    || fail "failed local copy created a dangling destination alias"
  FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary" \
    || fail "valid local retry did not converge"
  [ -L "$second/data/worker-sheet.md" ] && [ "$second/data/worker-sheet.md" -ef "$second/config/worker-sheet.md" ] \
    || fail "valid local retry omitted the alias"
  rm "$second/data/worker-sheet.md"
  report="$base/alias-restored.report"
  FM_CONFIG_INHERIT_REPORT="$report" FM_INHERITABLE_CONFIG=worker-sheet.md propagate_inheritable_config "$primary/config" "$second/config" "$primary" \
    || fail "unchanged local retry did not restore the alias"
  [ -L "$second/data/worker-sheet.md" ] && [ "$second/data/worker-sheet.md" -ef "$second/config/worker-sheet.md" ] \
    || fail "unchanged local retry omitted the alias"
  assert_grep $'worker-sheet.md\tpushed\t' "$report" "restored local alias was not reported as a change"

  payload="$base/payload"
  printf 'current owner policy\n' > "$payload"
  bytes=$(wc -c < "$payload" | tr -d ' ')
  hash=$(fm_inherit_sha256 "$payload") || fail "cannot hash policy fixture"
  : > "$base/empty"
  empty_hash=$(fm_inherit_sha256 "$base/empty") || fail "cannot hash empty fixture"
  FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" absent config/worker-sheet.md 0 "$empty_hash" 2 >/dev/null \
    || fail "fresh remote absence setup failed"
  if FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 1 < "$payload" >/dev/null 2>&1; then
    fail "stale remote generation unexpectedly succeeded"
  fi
  [ ! -e "$remote/config/worker-sheet.md" ] && [ ! -e "$remote/data/worker-sheet.md" ] && [ ! -L "$remote/data/worker-sheet.md" ] \
    || fail "rejected stale generation created a dangling remote alias"
  FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 3 < "$payload" >/dev/null \
    || fail "valid remote retry did not converge"
  [ -L "$remote/data/worker-sheet.md" ] && [ "$remote/data/worker-sheet.md" -ef "$remote/config/worker-sheet.md" ] \
    || fail "valid remote retry omitted the alias"
  rm "$remote/data/worker-sheet.md"
  out=$(FM_HOME="$remote" bash "$ROOT/bin/fm-remote-inherit.sh" put config/worker-sheet.md "$bytes" "$hash" 3 < "$payload") \
    || fail "unchanged remote retry did not restore the alias"
  [ -L "$remote/data/worker-sheet.md" ] && [ "$remote/data/worker-sheet.md" -ef "$remote/config/worker-sheet.md" ] \
    || fail "unchanged remote retry omitted the alias"
  [ "$out" = 'pushed: config/worker-sheet.md' ] || fail "restored remote alias was not reported as a change: $out"
  pass "failed local and remote policy publications leave fresh aliases absent; valid retries converge"
}

test_worker_sheet_failed_publication_leaves_fresh_alias_absent
