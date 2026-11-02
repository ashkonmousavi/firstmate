#!/usr/bin/env bash
# tests/fm-session-lock-ancestry.test.sh - session-lock harness identity
# (bin/fm-session-lock-lib.sh).
#
# Two layers. The unit cases drive the library's own functions behind a
# deterministic fake ps, so both platforms' reporting semantics are covered from
# either host: macOS reports argv[0] in `ps -o comm=`, while procps on Linux
# reports the kernel exec name and ignores argv[0] entirely. The end-to-end cases
# run the REAL Stop auto-arm inside real process trees whose shapes differ only
# in how the per-session process is named and what its parent is. Those trees are
# orphaned before the hook fires, so the ancestry walk terminates inside the
# fixture and can never escape into the session running this suite.
# shellcheck disable=SC2016 # single quotes are deliberate: $FM_HOME and $$ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ancestry)
fm_git_identity fmtest fmtest@example.invalid

LIB="$ROOT/bin/fm-session-lock-lib.sh"

# Claude Code's native installer names the per-session executable by its version,
# so the harness identity has to survive a basename that says nothing.
CLAUDE_VERSION_DIR="$TMP_ROOT/claude-install/share/claude/versions"
mkdir -p "$CLAUDE_VERSION_DIR"
ln -s /bin/bash "$CLAUDE_VERSION_DIR/2.1.220"
VERSIONED_CLAUDE="$CLAUDE_VERSION_DIR/2.1.220"

FAKEBIN=$(fm_fakebin "$TMP_ROOT/harness-bin")
ln -s /bin/bash "$FAKEBIN/claude"
NAMED_CLAUDE="$FAKEBIN/claude"

# --- unit layer: identity behind a deterministic process table ---------------

# Run one library expression with <fakebin> shadowing ps. kill is stubbed so
# liveness questions are decided by the process table alone (FM_TEST_KILL_RC=1
# makes every pid dead). The suite itself may run inside a Claude session whose
# CLAUDE_CODE_SESSION_ID and CLAUDE_PID would leak into the expression, so both
# are scrubbed and only FM_TEST_SESSION_ID and FM_TEST_CLAUDE_PID reach it.
lib_eval() {  # <fakebin> <expression>
  local fakebin=$1 expr=$2
  local -a session_env=()
  [ -z "${FM_TEST_SESSION_ID:-}" ] || session_env+=("CLAUDE_CODE_SESSION_ID=$FM_TEST_SESSION_ID")
  [ -z "${FM_TEST_CLAUDE_PID:-}" ] || session_env+=("CLAUDE_PID=$FM_TEST_CLAUDE_PID")
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID ${session_env[@]+"${session_env[@]}"} \
    PATH="$fakebin:$PATH" bash -c "
    . \"\$0\"
    kill() { return \${FM_TEST_KILL_RC:-0}; }
    $expr
  " "$LIB"
}

test_version_named_session_is_identified_on_both_platforms() {
  local dir fakebin shape got
  dir="$TMP_ROOT/version-named"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_CLAUDE_SHAPE:-linux}" in
  700:comm=:linux) printf '%s\n' '2.1.220' ;;
  700:args=:linux) printf '%s\n' '/opt/claude/versions/2.1.220 --resume' ;;
  700:comm=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220' ;;
  700:args=:macos) printf '%s\n' '/Users/u/.local/share/claude/versions/2.1.220 --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 700 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '700\n' > "$dir/state/.lock"

  for shape in linux macos; do
    got=$(FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
      || fail "$shape: the version-named session was not found in the ancestry at all"
    [ "$got" = 700 ] || fail "$shape: ancestry resolved '$got', expected the version-named session pid 700"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 700' \
      || fail "$shape: a live version-named session was not recognized as a harness"
    FM_TEST_CLAUDE_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
      || fail "$shape: the session holding the lock did not recognize itself as the owner"
  done
  pass "session-lock: a version-named Claude Code session is identified from its install path and argv[0]"
}

# A harness that is pid 1 of its own PID namespace - a container, or the
# `codex sandbox` this shape was verified in - used to be invisible: the walk
# stopped as soon as the NEXT pid was 1, so the one process that identifies the
# session was never examined and the session could not recognize its own lock.
test_harness_at_namespace_pid1_is_examined() {
  local dir fakebin got
  dir="$TMP_ROOT/namespace-pid1"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  1:comm=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:args=) printf '%s\n' "${FM_TEST_PID1_COMM:-claude}" ;;
  1:ppid=) printf '%s\n' 0 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' 'bash /repo/bin/fm-watch.sh' ;;
  *:ppid=) printf '%s\n' 1 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '1\n' > "$dir/state/.lock"

  # Non-vacuity: with a host-shaped pid 1 the same table must find nothing, so
  # this case cannot pass by the walk matching everything it reaches.
  if FM_TEST_PID1_COMM=systemd lib_eval "$fakebin" 'fm_harness_ancestry_pid' >/dev/null 2>&1; then
    fail "a host-shaped pid 1 was read as a harness process"
  fi

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') \
    || fail "the harness at namespace pid 1 was not found in the ancestry at all"
  [ "$got" = 1 ] || fail "ancestry resolved '$got', expected the namespace harness pid 1"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the session holding the lock at namespace pid 1 did not recognize itself as the owner"
  pass "session-lock: a harness that is pid 1 of its own namespace is examined, not skipped"
}

test_ordinary_paths_are_never_harness_processes() {
  local dir fakebin shape
  dir="$TMP_ROOT/ordinary-paths"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_PATH_SHAPE:-hookdir}" in
  810:comm=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh' ;;
  810:args=:hookdir) printf '%s\n' '/home/u/.claude/hooks/notify.sh --quiet' ;;
  810:comm=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner' ;;
  810:args=:piprefix) printf '%s\n' '/opt/pipeline/bin/runner --once' ;;
  810:ppid=:*) printf '%s\n' 1 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-watch-arm.sh' ;;
  *:ppid=:*) printf '%s\n' 810 ;;
esac
SH
  chmod +x "$fakebin/ps"
  printf '810\n' > "$dir/state/.lock"

  # Identity may be read from an executable path, but only from whole path
  # components: anything merely living under ~/.claude, and any component that
  # merely starts with a harness name, must stay outside the harness identity.
  for shape in hookdir piprefix; do
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_ancestry_pid'; then
      fail "$shape: an ordinary script path was treated as a harness process"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" 'fm_harness_pid_alive 810'; then
      fail "$shape: an ordinary script path passed the harness-liveness predicate"
    fi
    if FM_TEST_PATH_SHAPE="$shape" lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
      fail "$shape: an ordinary script path claimed the home's session lock"
    fi
  done
  pass "session-lock: ordinary script paths under a harness directory are not harness processes"
}

test_harness_beyond_a_gap_never_owns_the_lock() {
  local dir fakebin got
  dir="$TMP_ROOT/gap"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  900:comm=) printf '%s\n' claude ;;
  900:args=) printf '%s\n' 'claude' ;;
  900:ppid=) printf '%s\n' 910 ;;
  910:comm=) printf '%s\n' bash ;;
  910:args=) printf '%s\n' 'bash tests/run.sh' ;;
  910:ppid=) printf '%s\n' 920 ;;
  920:comm=) printf '%s\n' claude ;;
  920:args=) printf '%s\n' 'claude' ;;
  920:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 900 ;;
esac
SH
  chmod +x "$fakebin/ps"

  got=$(lib_eval "$fakebin" 'fm_harness_ancestry_pid') || fail "the contiguous harness run was not resolved"
  [ "$got" = 900 ] || fail "ancestry crossed a non-harness gap, resolved '$got' instead of 900"
  printf '920\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "an unrelated harness beyond a non-harness gap was accepted as this session's lock owner"
  fi
  printf '900\n' > "$dir/state/.lock"
  lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'" \
    || fail "the contiguous harness run did not recognize its own lock"
  pass "session-lock: ownership stops at the first non-harness gap above the contiguous run"
}

test_competing_version_named_session_is_seen_as_live() {
  local dir fakebin
  dir="$TMP_ROOT/competing"
  fakebin=$(fm_fakebin "$dir")
  mkdir -p "$dir/state"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field" in
  600:comm=) printf '%s\n' '2.1.220' ;;
  600:args=) printf '%s\n' '/opt/claude/versions/2.1.220' ;;
  600:ppid=) printf '%s\n' 1 ;;
  650:comm=) printf '%s\n' claude ;;
  650:args=) printf '%s\n' claude ;;
  650:ppid=) printf '%s\n' 1 ;;
  *:comm=) printf '%s\n' bash ;;
  *:args=) printf '%s\n' bash ;;
  *:ppid=) printf '%s\n' 650 ;;
esac
SH
  chmod +x "$fakebin/ps"
  # pid 600 is a different live session that holds the lock; this process
  # descends from 650 instead. Treating 600 as dead would let this session
  # reclaim a live competitor's home.
  printf '600\n' > "$dir/state/.lock"
  if lib_eval "$fakebin" "fm_session_lock_owned_by_self '$dir/state'"; then
    fail "a lock held outside this ancestry was claimed as this session's own"
  fi
  lib_eval "$fakebin" 'fm_harness_pid_alive 600' \
    || fail "a live competing version-named session was classified as a dead lock owner"
  pass "session-lock: a live version-named session holding the lock is not mistaken for a stale owner"
}

# A background Claude session's process table. The hook fires inside
# `claude bg-spare` (710), whose parent is `claude bg-pty-host` (720). With the
# transient daemon gone the pty-host is reparented to launchd, so the contiguous
# claude-named run from the hook ends at 720 and the live front-end 700 that
# holds the lock is no longer an ancestor at all. FM_TEST_DAEMON_PRESENT=1 puts
# the daemon (730) back between 720 and 700: the healthy topology.
write_background_session_ps() {  # <fakebin>
  cat > "$1/ps" <<'SH'
#!/usr/bin/env bash
set -u
field= pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) field=$2; shift 2 ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
case "$pid:$field:${FM_TEST_DAEMON_PRESENT:-0}" in
  700:comm=:*) printf '%s\n' claude ;;
  700:args=:*) printf '%s\n' 'claude --resume' ;;
  700:ppid=:*) printf '%s\n' 1 ;;
  730:comm=:*) printf '%s\n' claude ;;
  730:args=:*) printf '%s\n' 'claude daemon run --origin transient' ;;
  730:ppid=:*) printf '%s\n' 700 ;;
  720:comm=:*) printf '%s\n' 'claude bg-pty-host' ;;
  720:args=:*) printf '%s\n' 'claude bg-pty-host /tmp/pty.sock 120 40 -- claude --bg-spare' ;;
  720:ppid=:1) printf '%s\n' 730 ;;
  720:ppid=:*) printf '%s\n' 1 ;;
  710:comm=:*) printf '%s\n' 'claude bg-spare' ;;
  710:args=:*) printf '%s\n' 'claude bg-spare /tmp/claim.sock' ;;
  710:ppid=:*) printf '%s\n' 720 ;;
  *:comm=:*) printf '%s\n' bash ;;
  *:args=:*) printf '%s\n' 'bash /repo/bin/fm-claude-stop-autoarm.sh' ;;
  *:ppid=:*) printf '%s\n' 710 ;;
esac
SH
  chmod +x "$1/ps"
}

owned() {  # <fakebin> <state>
  lib_eval "$1" "fm_session_lock_owned_by_self '$2'"
}

foreign_owner() {  # <fakebin> <state>  -> prints the foreign pid
  lib_eval "$1" "fm_session_lock_foreign_owner_live '$2' && printf '%s' \"\$FM_SESSION_LOCK_FOREIGN_OWNER_PID\""
}

test_same_session_id_owns_a_recycled_background_chain() {
  local dir fakebin state got
  dir="$TMP_ROOT/background-session"
  fakebin=$(fm_fakebin "$dir")
  state="$dir/state"
  mkdir -p "$state"
  write_background_session_ps "$fakebin"
  printf '700\n' > "$state/.lock"
  printf 'S1\n' > "$state/.lock-session"

  # The divergence itself, so none of the verdicts below can be vacuous: with
  # the daemon gone the front-end is not an ancestor, with it back it is.
  if lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700; then
    fail "the recycled chain still reached the front-end, so the id cases would prove nothing"
  fi
  FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_harness_ancestry_pids' | grep -qx 700 \
    || fail "the healthy chain did not reach the front-end"

  # 1. The session's own id from its model-loop process: owned, not foreign.
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "the same session's trusted id did not own the lock after the helper chain was recycled"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "the session's own live front-end was reported as a foreign owner despite the matching id"
  fi
  # 2. A different id: the existing refusal, naming the live owner.
  if FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a different session id claimed a live owner's lock"
  fi
  got=$(FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state") \
    || fail "a different session id did not see the live owner as foreign"
  [ "$got" = 700 ] || fail "the foreign owner pid was '$got', expected 700"
  # 3. The trust gate: the right id carried by a CLAUDE_PID outside the run.
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 owned "$fakebin" "$state"; then
    fail "an id whose CLAUDE_PID is outside the current Claude run was trusted"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "an untrusted id suppressed the foreign-owner verdict"
  printf 'S1:x\n' > "$state/.lock-session"
  FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "a trusted id containing a colon did not own the lock"
  if FM_TEST_SESSION_ID='S1:x' FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "a matching id containing a colon was reported as a foreign owner"
  fi
  printf 'S1\r' > "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a recorded id containing a carriage return was treated as a session id"
  fi
  FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "a carriage-return sidecar suppressed the foreign-owner verdict"
  printf 'S1\n' > "$state/.lock-session"
  # 4. No id at all: the legacy ancestry verdict, unchanged.
  if owned "$fakebin" "$state"; then
    fail "with no session id the recycled chain claimed the lock"
  fi
  foreign_owner "$fakebin" "$state" >/dev/null \
    || fail "with no session id the live owner was not reported as foreign"
  # 5. The healthy chain owns by ancestry whatever the environment says.
  FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state" \
    || fail "ancestry membership lost to a different session id"
  FM_TEST_DAEMON_PRESENT=1 owned "$fakebin" "$state" \
    || fail "ancestry membership lost with no session id"
  if FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S2 FM_TEST_CLAUDE_PID=710 foreign_owner "$fakebin" "$state" >/dev/null; then
    fail "an ancestor was reported as a foreign owner"
  fi
  # 6. Never fail open: no sidecar, a symlinked sidecar, and a dead recorded pid
  # are all ancestry-only, so the dead one is left for the ordinary reclaim.
  rm -f "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a lock with no recorded session id was owned through the environment id"
  fi
  printf 'S1\n' > "$dir/elsewhere"
  ln -s "$dir/elsewhere" "$state/.lock-session"
  if FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a symlinked sidecar was trusted"
  fi
  rm -f "$state/.lock-session"
  printf 'S1\n' > "$state/.lock-session"
  if FM_TEST_KILL_RC=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 owned "$fakebin" "$state"; then
    fail "a same-session lock whose recorded pid is dead was owned instead of left for reclaim"
  fi
  pass "session-lock: a trusted same-session id keeps owning a recycled background chain, and nothing weaker does"
}

test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id() {
  local dir fakebin got
  dir="$TMP_ROOT/background-anchor"
  fakebin=$(fm_fakebin "$dir")
  write_background_session_ps "$fakebin"

  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for a trusted id"
  [ "$got" = 710 ] || fail "a trusted id anchored '$got', expected the model-loop process 710"
  got=$(lib_eval "$fakebin" 'fm_session_lock_anchor_pid') || fail "no anchor pid was resolved without an id"
  [ "$got" = 720 ] || fail "without an id the anchor was '$got', expected the outermost pid 720"
  got=$(FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=700 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for an untrusted id"
  [ "$got" = 720 ] || fail "an untrusted id anchored '$got', expected the outermost pid 720"
  got=$(FM_TEST_DAEMON_PRESENT=1 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain"
  [ "$got" = 700 ] || fail "the healthy chain without an id anchored '$got', expected the outermost pid 700"
  got=$(FM_TEST_DAEMON_PRESENT=1 FM_TEST_SESSION_ID=S1 FM_TEST_CLAUDE_PID=710 lib_eval "$fakebin" 'fm_session_lock_anchor_pid') \
    || fail "no anchor pid was resolved for the healthy chain with a trusted id"
  [ "$got" = 710 ] || fail "the healthy chain with a trusted id anchored '$got', expected 710 rather than the front-end"
  pass "session-lock: a trusted id anchors the lock on the model-loop process, anything else on the outermost pid"
}

# --- end-to-end layer: the real Stop auto-arm in real process trees ----------

install_autoarm_scripts() {
  local dir=$1
  mkdir -p "$dir/bin"
  cp "$ROOT/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-claude-stop-autoarm.sh"
  cp "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/fm-primary-scope-lib.sh"
  cp "$ROOT/bin/fm-supervision-lib.sh" "$dir/bin/fm-supervision-lib.sh"
  cp "$ROOT/bin/fm-wake-lib.sh" "$dir/bin/fm-wake-lib.sh"
  cp "$ROOT/bin/fm-path-lib.sh" "$dir/bin/fm-path-lib.sh"
  cp "$ROOT/bin/fm-session-lock-lib.sh" "$dir/bin/fm-session-lock-lib.sh"
  cp "$ROOT/bin/fm-cursor-lib.sh" "$dir/bin/fm-cursor-lib.sh"
  # Launch probe sibling of fm-cursor-lib.sh; keep it next to the copy so a
  # fixture that ever verifies an executable does not source a missing file.
  cp "$ROOT/bin/fm-timeout-lib.sh" "$dir/bin/fm-timeout-lib.sh"
  cp "$ROOT/bin/fm-hook-host-lib.sh" "$dir/bin/fm-hook-host-lib.sh"
  cp "$ROOT/bin/fm-lock.sh" "$dir/bin/fm-lock.sh"
  cp "$ROOT/bin/fm-supervision-engine-lib.sh" "$dir/bin/fm-supervision-engine-lib.sh"
  chmod +x "$dir/bin/fm-claude-stop-autoarm.sh" "$dir/bin/fm-lock.sh"
  # The fixture arm written here stands in for the watcher arm, so the home opts out
  # of the supervision host a Claude home otherwise runs by default.
  mkdir -p "$dir/config"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
}

# A primary home with one task in flight, so the hook's scope and supervision-need
# gates both pass and only identity decides the outcome.
make_primary_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  install_autoarm_scripts "$dir"
  # The process that fires the hook records its own pid as the session lock
  # owner, exactly as a real session does at session start.
  cat > "$dir/session.sh" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FIXTURE_ORPHAN_HERE:-0}" = 1 ]; then
  i=0
  while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
    sleep 0.05
    i=$((i + 1))
  done
fi
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
"$FM_HOME/bin/fm-claude-stop-autoarm.sh" </dev/null > "$FM_HOME/state/hook.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/hook.rc"
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
"$FM_SESSION_BIN" "$FM_HOME/session.sh"
exit 0
SH
  chmod +x "$dir/session.sh" "$dir/daemon.sh"
}

# Start the fixture tree detached from this suite's own process tree: the
# launcher exits immediately, so the tree is reparented to init and the ancestry
# walk terminates inside the fixture. Returns once the hook has recorded its exit
# code.
run_fixture_tree() {  # <dir> <session-bin> [<daemon-bin>]
  local dir=$1 session_bin=$2 daemon_bin=${3:-} i
  if [ -n "$daemon_bin" ]; then
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_SESSION_BIN="$session_bin" FM_FIXTURE_ORPHAN_HERE=0 \
      bash -c '"$0" "$1" &' "$daemon_bin" "$dir/daemon.sh"
  else
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
      FM_HOME="$dir" FM_FIXTURE_ORPHAN_HERE=1 \
      bash -c '"$0" "$1" &' "$session_bin" "$dir/session.sh"
  fi
  i=0
  while [ "$i" -lt 400 ] && [ ! -s "$dir/state/hook.rc" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$dir/state/hook.rc" ] || fail "the fixture hook never finished"
}

hook_rc() {
  tr -d '[:space:]' < "$1/state/hook.rc"
}

epoch_outcome() {
  sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$1/state/.claude-autoarm-epoch" 2>/dev/null || true
}

test_e2e_version_named_session_claims_the_home() {
  local dir
  dir="$TMP_ROOT/e2e-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named session"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "no claim was recorded, got: $(epoch_outcome "$dir")"
  pass "session-lock e2e: a version-named session claims the home and arms supervision"
}

test_e2e_daemon_parented_session_claims_the_home() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-parented"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$NAMED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  [ -n "$session_pid" ] && [ "$session_pid" != "$daemon_pid" ] \
    || fail "fixture did not produce a distinct daemon and session: session=$session_pid daemon=$daemon_pid"
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  expect_code 2 "$(hook_rc "$dir")" "a session parented by a harness-named daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a daemon-parented session"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  pass "session-lock e2e: a session parented by a harness-named daemon claims the home and arms supervision"
}

test_e2e_daemon_parented_version_named_session_keeps_its_lock() {
  local dir session_pid daemon_pid lock_after
  dir="$TMP_ROOT/e2e-daemon-version-named"
  make_primary_home "$dir"
  run_fixture_tree "$dir" "$VERSIONED_CLAUDE" "$NAMED_CLAUDE"
  session_pid=$(tr -d '[:space:]' < "$dir/state/session-pid")
  daemon_pid=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  lock_after=$(tr -d '[:space:]' < "$dir/state/.lock")
  [ "$lock_after" != "$daemon_pid" ] \
    || fail "the live session's lock was reclaimed as stale and rewritten to the shared daemon pid $daemon_pid"
  [ "$lock_after" = "$session_pid" ] || fail "the session lock moved off the session: expected $session_pid, got $lock_after"
  expect_code 2 "$(hook_rc "$dir")" "a version-named session under a daemon must claim its home and rewake"
  [ -e "$dir/state/arm-ran" ] || fail "supervision never armed for a version-named daemon-parented session"
  pass "session-lock e2e: a version-named session under a harness-named daemon keeps its own lock"
}

# --- end-to-end layer: a background session whose helper chain is recycled ---
#
# The topology the four issue reports (#3902, #2314, #3398, #4066) recorded with
# real process listings: a front-end that acquired the lock, a transient daemon
# under it, the pty-host the daemon spawned, and the bg-spare inside the pty-host
# that runs the model loop and therefore fires every hook. Every fixture process
# is the fake claude, so the ancestry walk sees a contiguous claude-named run
# exactly as in production, and the tree is orphaned before use. The daemon is
# then ended while the front-end stays alive - the recycling that breaks the run
# above the pty-host - and the spare fires the real Stop auto-arm, the real
# turn-end guard, and the real lock script once per phase under a chosen hook
# environment, recording every verdict for the assertions below.

BG_FIXTURE_PIDS=()
reap_background_fixture() {
  local pid
  for pid in ${BG_FIXTURE_PIDS[@]+"${BG_FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
}
trap 'reap_background_fixture; fm_test_cleanup' EXIT

make_background_session_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  # The whole bin, because the real turn-end guard composes far more of it than
  # the auto-arm alone; only the arm is replaced by the recording stub above.
  cp -R "$ROOT/bin" "$dir/bin"
  install_autoarm_scripts "$dir"
  # Every fixture script ends in an explicit exit so bash can never tail-exec the
  # script under test in place of the fake claude, which would collapse the
  # chain the assertions depend on.
  cat > "$dir/frontend.sh" <<'SH'
#!/usr/bin/env bash
i=0
while [ "$i" -lt 200 ] && [ "$(ps -o ppid= -p $$ 2>/dev/null | tr -d ' ')" != 1 ]; do
  sleep 0.05
  i=$((i + 1))
done
printf '%s\n' "$$" > "$FM_HOME/state/frontend-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_HOME/bin/fm-lock.sh" > "$FM_HOME/state/frontend-lock.out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/state/frontend-lock.rc"
"$FM_FIXTURE_CLAUDE" "$FM_HOME/daemon.sh" &
disown
while [ ! -e "$FM_HOME/state/stop-frontend" ]; do sleep 0.05; done
exit 0
SH
  cat > "$dir/daemon.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/daemon-pid"
exec -a 'claude bg-pty-host' "$FM_FIXTURE_CLAUDE" "$FM_HOME/ptyhost.sh" &
while :; do sleep 0.1; done
exit 0
SH
  cat > "$dir/ptyhost.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/ptyhost-pid"
exec -a 'claude bg-spare' "$FM_FIXTURE_CLAUDE" "$FM_HOME/spare.sh" &
while [ ! -e "$FM_HOME/state/stop-spare" ]; do sleep 0.1; done
exit 0
SH
  cat > "$dir/spare.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/state/spare-pid"
n=1
while [ ! -e "$FM_HOME/state/stop-spare" ]; do
  req="$FM_HOME/state/fire-$n"
  if [ -f "$req" ]; then
    out="$FM_HOME/state/phase-$n"
    mkdir -p "$out"
    unset CLAUDE_CODE_SESSION_ID CLAUDE_PID
    # shellcheck disable=SC1090
    . "$req"
    ( . "$FM_HOME/bin/fm-session-lock-lib.sh" && fm_harness_ancestry_pids ) > "$out/ancestry" 2>/dev/null
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-claude-stop-autoarm.sh" > "$out/hook.out" 2>&1
    printf '%s\n' "$?" > "$out/hook.rc"
    printf '%s\n' '{"session_id":"fixture","stop_hook_active":true}' \
      | "$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$out/guard.out" 2>&1
    printf '%s\n' "$?" > "$out/guard.rc"
    "$FM_HOME/bin/fm-lock.sh" > "$out/lock.out" 2>&1
    printf '%s\n' "$?" > "$out/lock.rc"
    cp "$FM_HOME/state/.lock" "$out/lock-after"
    [ ! -e "$FM_HOME/state/.lock-session" ] || cp "$FM_HOME/state/.lock-session" "$out/session-after"
    : > "$out/done"
    n=$((n + 1))
  fi
  sleep 0.05
done
exit 0
SH
  chmod +x "$dir/frontend.sh" "$dir/daemon.sh" "$dir/ptyhost.sh" "$dir/spare.sh"
}

wait_for_file() {  # <path> <what>
  local i=0
  while [ "$i" -lt 400 ] && [ ! -s "$1" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -s "$1" ] || fail "background-session fixture never produced $2"
}

fire_phase() {  # <dir> <n> <hook-environment-script>
  local dir=$1 n=$2
  printf '%s\n' "$3" > "$dir/state/fire-$n.tmp"
  mv "$dir/state/fire-$n.tmp" "$dir/state/fire-$n"
  wait_for_file "$dir/state/phase-$n/hook.rc" "phase $n"
  local i=0
  while [ "$i" -lt 400 ] && [ ! -e "$dir/state/phase-$n/done" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$dir/state/phase-$n/done" ] || fail "background-session fixture never finished phase $n"
}

phase_value() {  # <dir> <n> <file>
  tr -d '[:space:]' < "$1/state/phase-$2/$3"
}

arm_count() {  # <dir>
  [ -e "$1/state/arm-ran" ] || { printf '0'; return; }
  wc -l < "$1/state/arm-ran" | tr -d ' '
}

# The recycled chain must still be treated as the owner: arm, no diagnostic,
# lock accepted, line 1 naming <expected-lock-pid>, and the sidecar either
# byte-identical to the one the owner wrote or, when <expected-session-id> is
# given, re-keyed to that id. An owned actionable close records two arm
# invocations - the foreground arm plus the handling successor the hook starts
# before the rewake - so the cumulative <expected-arms> grows by two for every
# owned phase.
expect_phase_owned() {  # <dir> <n> <expected-arms> <expected-lock-pid> <label> [<expected-session-id>]
  local dir=$1 n=$2 arms=$3 lock_pid=$4 label=$5 session_id=${6:-}
  expect_code 2 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not rewake"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: expected $arms arm(s), got $(arm_count "$dir")"
  [ "$(epoch_outcome "$dir")" = rewake ] || fail "$label: no rewake claim was recorded, got: $(epoch_outcome "$dir")"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: the turn-end guard did not allow the stop"
  if grep -q 'OWNED BY ANOTHER LIVE SESSION' "$dir/state/phase-$n/guard.out"; then
    fail "$label: the turn-end guard took the foreign-owner exit: $(cat "$dir/state/phase-$n/guard.out")"
  fi
  expect_code 0 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh refused the session's own lock: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$lock_pid" ] \
    || fail "$label: lock line 1 is $(phase_value "$dir" "$n" lock-after), expected $lock_pid"
  if [ -n "$session_id" ]; then
    [ "$(sed -n '1p' "$dir/state/phase-$n/session-after")" = "$session_id" ] \
      || fail "$label: the session sidecar names $(phase_value "$dir" "$n" session-after), expected $session_id"
  else
    cmp -s "$dir/state/phase-$n/session-after" "$dir/sidecar-initial" \
      || fail "$label: the session sidecar is not byte-identical to the one the owner wrote"
  fi
}

# Not the owner: no arm, the guard's foreign-owner diagnostic naming the live
# owner, and the lock refusal naming both the owner pid and its recorded id.
expect_phase_foreign() {  # <dir> <n> <expected-arms> <owner-pid> <label>
  local dir=$1 n=$2 arms=$3 owner=$4 label=$5
  expect_code 0 "$(phase_value "$dir" "$n" hook.rc)" "$label: the Stop auto-arm did not stand down"
  [ "$(arm_count "$dir")" = "$arms" ] || fail "$label: a non-owner armed: $(arm_count "$dir") arm(s), expected $arms"
  expect_code 0 "$(phase_value "$dir" "$n" guard.rc)" "$label: a non-owner Stop did not end safely"
  grep -q "OWNED BY ANOTHER LIVE SESSION.*lock owner pid $owner" "$dir/state/phase-$n/guard.out" \
    || fail "$label: the guard did not report the live owner $owner: $(cat "$dir/state/phase-$n/guard.out")"
  expect_code 1 "$(phase_value "$dir" "$n" lock.rc)" "$label: fm-lock.sh accepted a lock this session does not own"
  grep -q "another live firstmate session holds the lock (pid $owner, session S1)" "$dir/state/phase-$n/lock.out" \
    || fail "$label: the refusal did not name the owner pid and recorded session: $(cat "$dir/state/phase-$n/lock.out")"
  [ "$(phase_value "$dir" "$n" lock-after)" = "$owner" ] || fail "$label: a non-owner rewrote the lock"
}

test_e2e_background_session_keeps_its_lock_across_a_recycled_chain() {
  local dir frontend daemon ptyhost spare i pty_ppid
  dir="$TMP_ROOT/e2e-background-session"
  make_background_session_home "$dir"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_FIXTURE_CLAUDE="$NAMED_CLAUDE" FM_POLL=1 FM_HEARTBEAT=999999 \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    bash -c '"$0" "$1" &' "$NAMED_CLAUDE" "$dir/frontend.sh"
  wait_for_file "$dir/state/frontend-lock.rc" "the front-end's lock result"
  wait_for_file "$dir/state/spare-pid" "the bg-spare"
  frontend=$(tr -d '[:space:]' < "$dir/state/frontend-pid")
  daemon=$(tr -d '[:space:]' < "$dir/state/daemon-pid")
  ptyhost=$(tr -d '[:space:]' < "$dir/state/ptyhost-pid")
  spare=$(tr -d '[:space:]' < "$dir/state/spare-pid")
  BG_FIXTURE_PIDS+=("$frontend" "$daemon" "$ptyhost" "$spare")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/frontend-lock.rc")" "the front-end could not acquire the lock: $(cat "$dir/state/frontend-lock.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$frontend" ] \
    || fail "the front-end's lock names $(cat "$dir/state/.lock"), expected its own pid $frontend"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the front-end did not record its trusted session id beside the lock"
  cp "$dir/state/.lock-session" "$dir/sidecar-initial"

  # Phase 1: the healthy contiguous chain, the session's own id.
  fire_phase "$dir" 1 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  grep -qx "$frontend" "$dir/state/phase-1/ancestry" || fail "the healthy chain did not reach the front-end"
  expect_phase_owned "$dir" 1 2 "$frontend" "healthy chain"

  # Recycle the bridge: the daemon ends and an orphan reaper adopts the
  # pty-host. That reaper is init on a plain host, and a subreaper when one
  # is in this process's ancestry. Either way the new parent is outside the
  # front-end, so the harness chain above the pty-host is broken.
  kill -TERM "$daemon"
  i=0
  pty_ppid=$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')
  while [ "$i" -lt 200 ] && { kill -0 "$daemon" 2>/dev/null || [ "$pty_ppid" = "$daemon" ] || [ -z "$pty_ppid" ]; }; do
    sleep 0.05
    i=$((i + 1))
    pty_ppid=$(ps -o ppid= -p "$ptyhost" 2>/dev/null | tr -d ' ')
  done
  kill -0 "$daemon" 2>/dev/null && fail "the daemon was still alive after it was ended"
  [ -n "$pty_ppid" ] || fail "the pty-host exited with the daemon, so the recycled case cannot be exercised"
  [ "$pty_ppid" != "$frontend" ] || fail "the pty-host was reparented onto the front-end, so the chain is not broken"
  [ "$pty_ppid" != "$daemon" ] || fail "the pty-host was not reparented after the daemon ended"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end died with the daemon, so the recycled case cannot be exercised"

  # Phases 2-4: before the spare proves anything, a different id, the right id
  # from a CLAUDE_PID outside the run, and no id at all are each a non-owner
  # over the broken chain.
  fire_phase "$dir" 2 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  if grep -qx "$frontend" "$dir/state/phase-2/ancestry"; then
    fail "the recycled chain still reached the front-end, so these phases prove nothing"
  fi
  grep -qx "$spare" "$dir/state/phase-2/ancestry" || fail "the hook's ancestry lost its own spare"
  expect_phase_foreign "$dir" 2 2 "$frontend" "recycled chain, different session"
  fire_phase "$dir" 3 "export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$frontend"
  expect_phase_foreign "$dir" 3 2 "$frontend" "recycled chain, untrusted id"
  fire_phase "$dir" 4 ''
  expect_phase_foreign "$dir" 4 2 "$frontend" "recycled chain, no id"

  # Phase 5: the same session id over the broken chain - the reported drift. The
  # confirmation re-anchors line 1 from the live non-ancestor front-end onto the
  # spare - the model-loop process - not onto the outermost pty-host.
  fire_phase "$dir" 5 'export CLAUDE_CODE_SESSION_ID=S1; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 5 4 "$spare" "recycled chain, same session"
  [ "$spare" != "$ptyhost" ] || fail "fixture collapsed the spare into the pty-host"
  kill -0 "$frontend" 2>/dev/null || fail "the front-end exited, so the re-anchor was not over a live owner"

  # Phase 6: /clear - the same spare under a new id while the front-end that
  # first recorded the lock is still alive. Ancestry still proves ownership and
  # the sidecar is re-keyed.
  fire_phase "$dir" 6 'export CLAUDE_CODE_SESSION_ID=S2; export CLAUDE_PID=$$'
  expect_phase_owned "$dir" 6 6 "$spare" "same process after a session-id change" S2
  [ "$(sed -n '2p' "$dir/state/phase-6/session-after")" = S1 ] || fail "clear lost the prior session"

  : > "$dir/state/stop-frontend"
  : > "$dir/state/stop-spare"
  pass "session-lock e2e: a background session keeps its lock and its supervision across a recycled helper chain and a same-process session-id change"
}

# A same-session confirmation must refresh a /clear re-key even while another
# process holds .lock.acquire. The prior-session-sweep-is-finishing refusal is
# a takeover rule and does not apply here; the confirmation waits, then writes
# the new id.
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock() {
  local dir session_pid holder_pid confirm_pid
  dir="$TMP_ROOT/confirm-under-claim"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/sidecar-after-acquire")" = S1 ] \
    || fail "the initial acquire did not record S1"
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" \
    "the same-session confirmation failed while the claim lock was held: $(cat "$dir/state/confirm.out")"
  [ "$(cat "$dir/state/.lock-session")" = "$(printf 'S2\nS1')" ] \
    || fail "the sidecar still names $(cat "$dir/state/.lock-session"), expected the re-keyed id S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/session-pid")" ] \
    || fail "the confirmation rewrote lock line 1"
  grep -q 'lock acquired: harness pid' "$dir/state/confirm.out" \
    || fail "the confirmation did not report acquisition: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a same-session confirmation waits for the claim lock and refreshes a re-keyed id"
}

# If another live session publishes while a confirmation is waiting on the claim
# lock, the waiter must not overwrite that session's sidecar or report success.
test_same_session_confirmation_does_not_steal_after_wait() {
  local dir session_pid holder_pid confirm_pid other_pid
  dir="$TMP_ROOT/confirm-no-steal"
  mkdir -p "$dir/state"
  cat > "$dir/run.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$FM_HOME/state/session-pid"
CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
acquire_rc=$?
if [ "$acquire_rc" != 0 ]; then
  printf '%s\n' "$acquire_rc" > "$FM_HOME/state/acquire.rc"
  printf '%s\n' 1 > "$FM_HOME/state/confirm.rc"
  exit 1
fi
cp "$FM_HOME/state/.lock-session" "$FM_HOME/state/sidecar-after-acquire"
printf '%s\n' 0 > "$FM_HOME/state/acquire.rc"

"$FM_CLAUDE" -c '
  printf "%s\n" "$$" > "$FM_HOME/state/other-pid"
  while [ ! -e "$FM_HOME/state/stop-other" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
' &
printf '%s\n' "$!" > "$FM_HOME/state/other-bash-pid"
i=0
while [ "$i" -lt 400 ] && [ ! -s "$FM_HOME/state/other-pid" ]; do
  sleep 0.05
  i=$((i + 1))
done
[ -s "$FM_HOME/state/other-pid" ] || {
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
}

bash -c '
  set -u
  . "$1"
  fm_lock_try_acquire "$2/.lock.acquire" || exit 1
  : > "$2/holder-ready"
  while [ ! -e "$2/release-holder" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    sleep 0.05
  done
  fm_lock_release "$2/.lock.acquire"
' _ "$FM_WAKE" "$FM_HOME/state" &
printf '%s\n' "$!" > "$FM_HOME/state/holder-pid"

i=0
while [ "$i" -lt 400 ] && [ ! -e "$FM_HOME/state/holder-ready" ]; do
  sleep 0.05
  i=$((i + 1))
done
if [ ! -e "$FM_HOME/state/holder-ready" ]; then
  printf '%s\n' 2 > "$FM_HOME/state/confirm.rc"
  exit 2
fi

CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/confirm.out" 2>&1 &
printf '%s\n' "$!" > "$FM_HOME/state/confirm-pid"

i=0
while [ "$i" -lt 20 ]; do
  sleep 0.05
  i=$((i + 1))
done

cp "$FM_HOME/state/other-pid" "$FM_HOME/state/.lock"
printf '%s\n' OTHER > "$FM_HOME/state/.lock-session"
: > "$FM_HOME/state/release-holder"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/confirm-pid")"
printf '%s\n' "$?" > "$FM_HOME/state/confirm.rc"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/holder-pid")" || true
: > "$FM_HOME/state/stop-other"
wait "$(tr -d '[:space:]' < "$FM_HOME/state/other-bash-pid")" || true
SH
  chmod +x "$dir/run.sh"

  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" FM_WAKE="$ROOT/bin/fm-wake-lib.sh" \
    FM_CLAUDE="$NAMED_CLAUDE" \
    "$NAMED_CLAUDE" "$dir/run.sh" &
  session_pid=$!
  BG_FIXTURE_PIDS+=("$session_pid")
  wait_for_file "$dir/state/acquire.rc" "the initial lock acquisition"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  wait_for_file "$dir/state/other-pid" "the other live harness pid"
  other_pid=$(tr -d '[:space:]' < "$dir/state/other-pid")
  BG_FIXTURE_PIDS+=("$other_pid")
  wait_for_file "$dir/state/holder-pid" "the claim-lock holder pid"
  holder_pid=$(tr -d '[:space:]' < "$dir/state/holder-pid")
  BG_FIXTURE_PIDS+=("$holder_pid")
  wait_for_file "$dir/state/confirm-pid" "the same-session confirmation pid"
  confirm_pid=$(tr -d '[:space:]' < "$dir/state/confirm-pid")
  BG_FIXTURE_PIDS+=("$confirm_pid")
  wait_for_file "$dir/state/confirm.rc" "the contended confirmation result"
  wait "$session_pid" || true
  [ "$(tr -d '[:space:]' < "$dir/state/confirm.rc")" != 0 ] \
    || fail "the waiter reported success after another live session published: $(cat "$dir/state/confirm.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = OTHER ] \
    || fail "the waiter overwrote the other session's sidecar to $(cat "$dir/state/.lock-session")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$other_pid" ] \
    || fail "the waiter rewrote lock line 1 off the other live session"
  grep -q "another live firstmate session holds the lock (pid $other_pid, session OTHER)" "$dir/state/confirm.out" \
    || fail "the waiter did not refuse the other live owner: $(cat "$dir/state/confirm.out")"
  pass "session-lock: a waiting confirmation does not steal another session's lock"
}

# A failed line-1 write after publishing a new id must restore the previous
# sidecar, not leave the new id beside the unclaimed pid.
test_failed_lock_write_restores_previous_sidecar() {
  local dir stale_pid
  dir="$TMP_ROOT/restore-sidecar"
  mkdir -p "$dir/state"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/acquire.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/acquire.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/stale-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/acquire.rc")" \
    "the first session could not acquire its lock: $(cat "$dir/state/acquire.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the first session did not record S1"
  stale_pid=$(tr -d '[:space:]' < "$dir/state/stale-pid")
  cp "$dir/state/.lock" "$dir/state/lock-before-reclaim"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S1 ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected the previous id S1"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$stale_pid" ] \
    || fail "the failed reclaim rewrote lock line 1"
  cmp -s "$dir/state/lock-before-reclaim" "$dir/state/.lock" \
    || fail "the failed reclaim changed lock bytes when line 1 was unwritable"
  pass "session-lock: a failed lock write restores the previous sidecar"
}

# A failed line-1 write that had no previous sidecar must not leave the new id
# behind; the lock stays ancestry-only.
test_failed_lock_write_removes_new_sidecar_when_none_existed() {
  local dir
  dir="$TMP_ROOT/restore-absent-sidecar"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  chmod a-w "$dir/state/.lock" || fail "could not make the stale lock read-only"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
    '
  chmod u+w "$dir/state/.lock" 2>/dev/null || true
  [ "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" != 0 ] \
    || fail "a read-only stale lock was overwritten: $(cat "$dir/state/reclaim.out")"
  grep -q 'cannot write session lock' "$dir/state/reclaim.out" \
    || fail "the reclaim did not fail on the lock write: $(cat "$dir/state/reclaim.out")"
  [ ! -e "$dir/state/.lock-session" ] \
    || fail "the failed reclaim left sidecar $(cat "$dir/state/.lock-session"), expected none"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = 1 ] \
    || fail "the failed reclaim rewrote lock line 1"
  pass "session-lock: a failed lock write removes a newly created sidecar"
}

# A completed reclaim must keep the new id beside the new pid after the writer
# exits, so a late signal cannot unwind a verified publication.
test_verified_reclaim_keeps_new_sidecar() {
  local dir
  dir="$TMP_ROOT/verified-reclaim"
  mkdir -p "$dir/state"
  printf '1\n' > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S2 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reclaim.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reclaim.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/new-pid"
    '
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reclaim.rc")" \
    "the reclaim failed: $(cat "$dir/state/reclaim.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = S2 ] \
    || fail "the verified reclaim left sidecar $(cat "$dir/state/.lock-session"), expected S2"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(tr -d '[:space:]' < "$dir/state/new-pid")" ] \
    || fail "the verified reclaim did not record the new anchor pid"
  pass "session-lock: a verified reclaim keeps the new sidecar beside the new pid"
}

# A re-anchor moves leases recorded against the old live line 1 onto the new
# anchor, so the other supervision actor still cannot claim a held task.
test_reanchor_keeps_task_leases_live() {
  local dir front_pid model_pid lease_rc
  dir="$TMP_ROOT/reanchor-leases"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'branch\t%s\t100\n' "$front_pid" > "$dir/state/.lease-t1"
  printf 'main\t%s\t200\n' "$front_pid" > "$dir/state/.lease-t2"
  printf 'branch\t%s\t300\n' "$$" > "$dir/state/.lease-t3"
  cp "$dir/state/.lease-t3" "$dir/state/lease-t3-before"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.lease-t1")" = "$(printf 'branch\t%s\t100' "$model_pid")" ] \
    || fail "the branch lease was not moved to the new anchor: $(cat "$dir/state/.lease-t1")"
  [ "$(cat "$dir/state/.lease-t2")" = "$(printf 'main\t%s\t200' "$model_pid")" ] \
    || fail "the main lease was not moved to the new anchor: $(cat "$dir/state/.lease-t2")"
  cmp -s "$dir/state/lease-t3-before" "$dir/state/.lease-t3" \
    || fail "a lease recorded against another pid changed: $(cat "$dir/state/.lease-t3")"
  env -u FM_SUPERVISION_ACTOR -u FM_LEASE_HOLDER_PID FM_HOME="$dir" \
    "$ROOT/bin/fm-lease.sh" claim t1 > "$dir/state/main-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "main claimed the branch's task after the re-anchor: $(cat "$dir/state/main-claim.out")"
  env -u FM_SUPERVISION_ACTOR FM_HOME="$dir" FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$model_pid" \
    "$ROOT/bin/fm-lease.sh" claim t2 > "$dir/state/branch-claim.out" 2>&1
  lease_rc=$?
  expect_code 6 "$lease_rc" "the branch claimed main's task after the re-anchor: $(cat "$dir/state/branch-claim.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor keeps both supervision actors' task leases live"
}

autoarm_midturn_healthy() {  # <state-dir>
  FM_STATE_OVERRIDE="$1" bash -c '. "$0"; fm_autoarm_midturn_healthy "$FM_STATE_OVERRIDE" 300' "$ROOT/bin/fm-wake-lib.sh"
}

# A re-anchor during a rewake handling turn that has outrun grace moves the
# auto-arm ledger's session_pid with line 1 and keeps the ledger's other bytes
# and mtime, so the mid-turn guard still sees healthy supervision.
test_reanchor_keeps_autoarm_midturn_healthy() {
  local dir front_pid model_pid
  dir="$TMP_ROOT/reanchor-autoarm"
  mkdir -p "$dir/state"
  "$NAMED_CLAUDE" -c '
    printf "%s\n" "$$" > "$0/state/front-pid"
    while [ ! -e "$0/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
  ' "$dir" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/front-pid" "the front-end pid"
  front_pid=$(tr -d '[:space:]' < "$dir/state/front-pid")
  printf '%s\n' "$front_pid" > "$dir/state/.lock"
  printf 'S1\n' > "$dir/state/.lock-session"
  printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1\n' \
    "$front_pid" > "$dir/state/.claude-autoarm-epoch"
  printf 'acked:handling:g1\n' > "$dir/state/.watcher-down"
  touch -t 201901010000 "$dir/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/state/.claude-autoarm-epoch" "$dir/state/epoch-mtime"
  autoarm_midturn_healthy "$dir/state" || fail "the rewake fixture is not healthy before the re-anchor, so this case proves nothing"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    FM_HOME="$dir" FM_LOCK="$ROOT/bin/fm-lock.sh" \
    "$NAMED_CLAUDE" -c '
      CLAUDE_CODE_SESSION_ID=S1 CLAUDE_PID=$$ "$FM_LOCK" > "$FM_HOME/state/reanchor.out" 2>&1
      printf "%s\n" "$?" > "$FM_HOME/state/reanchor.rc"
      printf "%s\n" "$$" > "$FM_HOME/state/model-pid"
      while [ ! -e "$FM_HOME/state/stop" ] && [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do sleep 0.05; done
    ' &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/model-pid" "the model-loop pid"
  model_pid=$(tr -d '[:space:]' < "$dir/state/model-pid")
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/reanchor.rc")" \
    "the same-session re-anchor failed: $(cat "$dir/state/reanchor.out")"
  kill -0 "$front_pid" 2>/dev/null || fail "the front-end exited, so the lock line was never live"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$model_pid" ] \
    || fail "the re-anchor left lock line 1 at $(cat "$dir/state/.lock"), expected $model_pid"
  [ "$(cat "$dir/state/.claude-autoarm-epoch")" = "$(printf 'epoch=7 owner_pid=1 outcome=rewake updated_at=1 session_pid=%s recovery_generation=g1\nidentity-1' "$model_pid")" ] \
    || fail "the rewake was not moved to the new anchor intact: $(cat "$dir/state/.claude-autoarm-epoch")"
  if [ "$dir/state/.claude-autoarm-epoch" -nt "$dir/state/epoch-mtime" ] \
    || [ "$dir/state/.claude-autoarm-epoch" -ot "$dir/state/epoch-mtime" ]; then
    fail "the rewake move changed the ledger mtime"
  fi
  autoarm_midturn_healthy "$dir/state" \
    || fail "the mid-turn guard rejects the rewake after the re-anchor: $(cat "$dir/state/reanchor.out")"
  : > "$dir/state/stop"
  pass "session-lock: a re-anchor during a rewake turn keeps the mid-turn auto-arm proof healthy"
}

# --- idle fork-resume takeover ------------------------------------------------
# Two Claude-shaped processes. The second is a fork-resume of the first, or
# its transcript has the holder's turns as a prefix. The holder stays alive.

IDLE_FORK_HOLDER=holder11111
IDLE_FORK_SUCC=succ222222
IDLE_FORK_SHIM=$TMP_ROOT/share/claude

prepare_idle_fork_shim() {
  mkdir -p "$(dirname "$IDLE_FORK_SHIM")"
  [ -x "$IDLE_FORK_SHIM" ] && return 0
  cat > "$IDLE_FORK_SHIM" <<'PY'
#!/usr/bin/env python3
import os, subprocess, time
os.environ['CLAUDE_PID'] = str(os.getpid())
proc = subprocess.run([os.environ['FM_CHILD']], stdin=subprocess.DEVNULL,
                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
out = os.environ['FM_OUT']
tag = os.environ['FM_TAG']
open(os.path.join(out, tag + '.out'), 'w').write(proc.stdout or '')
open(os.path.join(out, tag + '.rc'), 'w').write(str(proc.returncode) + '\n')
open(os.path.join(out, tag + '.pid'), 'w').write(str(os.getpid()) + '\n')
stop = os.path.join(out, 'stop-' + tag)
while not os.path.exists(stop):
    probe = os.path.join(out, 'probe-' + tag)
    if os.path.exists(probe):
        os.unlink(probe)
        verdict = subprocess.run(['bash', '-c', '. "$1/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$2" "${3:-}"',
                                  'probe', os.environ['FM_LOCK_TEST_ROOT'], out,
                                  '0' if os.path.exists(os.path.join(out, 'gap')) and not os.path.exists(os.path.join(out, 'release')) else '']).returncode
        open(os.path.join(out, 'verdict-' + tag), 'w').write(str(verdict))
    rekey = os.path.join(out, 'rekey-' + tag)
    if os.path.exists(rekey):
        os.environ['CLAUDE_CODE_SESSION_ID'] = open(rekey).read().strip()
        os.unlink(rekey)
        result = subprocess.run([os.environ['FM_LOCK_TEST_ROOT'] + '/bin/fm-lock.sh'],
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        open(os.path.join(out, 'rekey-' + tag + '.out'), 'w').write(result.stdout)
        open(os.path.join(out, 'rekey-' + tag + '.rc'), 'w').write(str(result.returncode))
    time.sleep(0.05)
PY
  chmod +x "$IDLE_FORK_SHIM"
}

write_idle_fork_turns() {  # <config> <session-id> <age-seconds> <uuid>...
  local config=$1 sid=$2 age=$3
  shift 3
  mkdir -p "$config/projects/lab"
  python3 - "$config/projects/lab/$sid.jsonl" "$age" "$@" <<'PY'
import datetime, json, sys
path, age = sys.argv[1], int(sys.argv[2])
stamp = (datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=age)).strftime('%Y-%m-%dT%H:%M:%SZ')
lines = [json.dumps({'type': 'summary', 'timestamp': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')})]
for index, uid in enumerate(sys.argv[3:]):
    kind = 'user' if index % 2 == 0 else 'assistant'
    lines.append(json.dumps({'type': kind, 'uuid': uid, 'timestamp': stamp}))
open(path, 'w').write('\n'.join(lines) + '\n')
PY
}

start_idle_fork_proc() {  # <tag> <session-id> <home> <config> <child> [argv...]
  local tag=$1 sid=$2 home=$3 config=$4 child=$5
  shift 5
  mkdir -p "$home/state" "$TMP_ROOT/home-$tag"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
    -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE \
    CLAUDE_CODE_SESSION_ID="$sid" \
    CLAUDE_CONFIG_DIR="$config" \
    HOME="$TMP_ROOT/home-$tag" \
    FM_HOME="$home" \
    FM_CHILD="$child" \
    FM_LOCK_TEST_ROOT="$ROOT" \
    FM_OUT="$home/state" \
    FM_TAG="$tag" \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=0 \
    FM_POLL=1 \
    FM_HEARTBEAT=999999 \
    "$IDLE_FORK_SHIM" "$@" >/dev/null 2>&1 &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$home/state/$tag.rc" "$tag result"
}

stop_idle_fork_procs() {  # <home> <tag>...
  local home=$1 tag
  shift
  for tag in "$@"; do
    : > "$home/state/stop-$tag"
  done
}

idle_fork_pid() {  # <home> <tag>
  tr -d '[:space:]' < "$1/state/$2.pid"
}

assert_takeover_leases() {
  local dir=$1 pid=$2 actor task rc
  for actor in branch main; do
    task=takeover-$actor
    [ "$(cat "$dir/state/.lease-$task")" = "$(printf '%s\t%s\t1234' "$actor" "$pid")" ] \
      || fail "takeover changed lease actor/epoch or lost its holder: $task"
    rc=0
    FM_HOME="$dir" STATE="$dir/state" FM_SUPERVISION_ACTOR="$actor" bash -c '
      . "$1/bin/fm-lease-lib.sh"
      fm_lease_guard "$2" takeover-test
      fm_lease_guard_release
    ' bash "$ROOT" "$task" >/dev/null 2>&1 || rc=$?
    expect_code 0 "$rc" "the existing $actor actor lost its lease"
    rc=0
    FM_HOME="$dir" STATE="$dir/state" FM_SUPERVISION_ACTOR="$actor" bash -c '
      . "$1/bin/fm-lease-lib.sh"
      fm_lease_guard "$2" takeover-test
      fm_lease_guard_release
    ' bash "$ROOT" "takeover-$([ "$actor" = main ] && echo branch || echo main)" >/dev/null 2>&1 || rc=$?
    expect_code 6 "$rc" "takeover allowed the $actor actor to enter the other actor lease"
  done
}

seed_takeover_leases() {
  printf 'branch\t%s\t1234\n' "$2" > "$1/state/.lease-takeover-branch"
  printf 'main\t%s\t1234\n' "$2" > "$1/state/.lease-takeover-main"
}

prepare_takeover_boundary() {
  local dir=$1 stage=$2 mode=$3 config=$4
  mkdir -p "$dir/state" "$dir/config" "$dir/shim"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  : > "$dir/config/supervision-host-off"
  cp -R "$ROOT/bin" "$dir/bin"
  mv "$dir/bin/fm-lock.sh" "$dir/bin/fm-lock-real.sh"
  cat > "$dir/bin/fm-lock.sh" <<'SH'
#!/usr/bin/env bash
export FM_BOUNDARY_WRITER=$$
if [ "$FM_BOUNDARY_STAGE" = delegation ]; then
  printf '{"type":"user","uuid":"arrived-before-delegation","timestamp":1}\n' >> "$FM_BOUNDARY_TRANSCRIPT"
fi
exec "$FM_HOME/bin/fm-lock-real.sh"
SH
  printf '%s\n' "$stage" > "$dir/stage"
  printf '%s\n' "$mode" > "$dir/mode"
  printf '%s\n' "$config/projects/lab/$IDLE_FORK_HOLDER.jsonl" > "$dir/transcript"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo armed >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:boundary\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\nstale: boundary actionable\n' "$$"
SH
  cat > "$dir/claim" <<'SH'
#!/usr/bin/env bash
export FM_BOUNDARY_REAL_MV=$(command -v mv)
export FM_BOUNDARY_REAL_CAT=$(command -v cat)
export FM_BOUNDARY_REAL_CP=$(command -v cp)
export FM_BOUNDARY_REAL_MKTEMP=$(command -v mktemp)
export FM_BOUNDARY_REAL_DATE=$(command -v date)
export FM_BOUNDARY_STAGE=$(cat "$FM_HOME/stage")
export FM_BOUNDARY_TRANSCRIPT=$(cat "$FM_HOME/transcript")
export FM_BOUNDARY_WRITER=$$
mode=$(cat "$FM_HOME/mode")
export PATH="$FM_HOME/shim:$PATH"
printf '%s\n' "$CLAUDE_PID" > "$FM_HOME/state/succ-live-pid"
if [ "$mode" = stop ]; then
  exec "$FM_HOME/bin/fm-claude-stop-autoarm.sh"
fi
exec "$FM_HOME/bin/fm-lock.sh"
SH
  cat > "$dir/shim/mv" <<'SH'
#!/usr/bin/env bash
"$FM_BOUNDARY_REAL_MV" "$@" || exit "$?"
target=${*: -1}
case "$FM_BOUNDARY_STAGE:$target" in
  gap:*/.lock-session)
    rc=0
    bash -c '. "$1/bin/fm-session-lock-lib.sh"; fm_session_lock_owned_by_self "$2" 0' \
      probe "$FM_LOCK_TEST_ROOT" "$FM_HOME/state" || rc=$?
    printf '%s\n' "$rc" > "$FM_HOME/state/succ-gap"
    printf 'paused\n' > "$FM_HOME/state/gap"
    for ((i=0; i<400; i++)); do
      [ ! -e "$FM_HOME/state/release" ] || exit 0
      sleep 0.05
    done
    exit 1
    ;;
  publication:*/.lock-session|leases:*/.lease-takeover-branch)
    if [ ! -e "$FM_HOME/state/cancelled" ]; then
      : > "$FM_HOME/state/cancelled"
      kill -TERM "$FM_BOUNDARY_WRITER"
    fi
    ;;
esac
SH
  cat > "$dir/shim/cat" <<'SH'
#!/usr/bin/env bash
if [ "$FM_BOUNDARY_STAGE" = verification ] && [ "$#" = 1 ] \
  && [ "$1" = "$FM_HOME/state/.lock" ] \
  && [ "$("$FM_BOUNDARY_REAL_CAT" "$1")" = "$CLAUDE_PID" ] \
  && [ ! -e "$FM_HOME/state/cancelled" ]; then
  : > "$FM_HOME/state/cancelled"
  kill -TERM "$FM_BOUNDARY_WRITER"
fi
exec "$FM_BOUNDARY_REAL_CAT" "$@"
SH
  cat > "$dir/shim/mktemp" <<'SH'
#!/usr/bin/env bash
path=$("$FM_BOUNDARY_REAL_MKTEMP" "$@") || exit "$?"
case "$FM_BOUNDARY_STAGE:${*: -1}" in
  activity:*/.lock-session.XXXXXX|backdated:*/.lock-session.XXXXXX)
    if [ "$FM_BOUNDARY_STAGE" = activity ]; then
      stamp=$("$FM_BOUNDARY_REAL_DATE" +%s)
    else
      stamp=1
    fi
    printf '{"type":"user","uuid":"arrived-between-scans","timestamp":%s}\n' "$stamp" >> "$FM_BOUNDARY_TRANSCRIPT"
    ;;
esac
printf '%s\n' "$path"
SH
  cat > "$dir/shim/cp" <<'SH'
#!/usr/bin/env bash
case "$FM_BOUNDARY_STAGE:${*: -1}" in
  backup:*/.lock.pre.*)
    : > "${*: -1}"
    : > "$FM_HOME/state/cancelled"
    kill -TERM "$FM_BOUNDARY_WRITER"
    exit 1
    ;;
esac
exec "$FM_BOUNDARY_REAL_CP" "$@"
SH
  cat > "$dir/shim/date" <<'SH'
#!/usr/bin/env bash
if [ "$FM_BOUNDARY_STAGE" = journal ] && [ ! -e "$FM_HOME/state/cancelled" ] \
  && [ "$("$FM_BOUNDARY_REAL_CAT" "$FM_HOME/state/.lock")" = "$CLAUDE_PID" ]; then
  : > "$FM_HOME/state/cancelled"
  kill -TERM "$FM_BOUNDARY_WRITER"
fi
exec "$FM_BOUNDARY_REAL_DATE" "$@"
SH
  chmod +x "$dir/claim" "$dir/shim/"* "$dir/bin/fm-watch-arm.sh" "$dir/bin/fm-lock.sh"
}

test_takeover_boundaries_share_one_commit() {
  local mode stage dir config holder succ launch rc old_verdict
  prepare_idle_fork_shim
  for mode in startup stop; do
    for stage in gap activity backdated delegation backup publication verification leases journal; do
      [ "$stage:$mode" != delegation:startup ] || continue
      dir=$TMP_ROOT/boundary-$mode-$stage
      config=$TMP_ROOT/boundary-config-$mode-$stage
      prepare_takeover_boundary "$dir" "$stage" "$mode" "$config"
      write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
      start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
      holder=$(idle_fork_pid "$dir" holder)
      seed_takeover_leases "$dir" "$holder"
      if [ "$stage" = gap ]; then
        start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$dir/claim" \
          --fork-session --resume "$IDLE_FORK_HOLDER" &
        launch=$!
        BG_FIXTURE_PIDS+=("$launch")
        wait_for_file "$dir/state/succ-live-pid" "the successor process identity"
        BG_FIXTURE_PIDS+=("$(cat "$dir/state/succ-live-pid")")
        wait_for_file "$dir/state/gap" "the split publication boundary"
        kill -0 "$holder" || fail "the predecessor is not alive at publication"
        [ "$(cat "$dir/state/.lock")" = "$holder" ] || fail "gap missed predecessor pid"
        [ "$(cat "$dir/state/.lock-session")" = "$IDLE_FORK_SUCC" ] || fail "gap missed successor session"
        FM_HOME="$dir" STATE="$dir/state" bash -c '
          . "$1/bin/fm-wake-lib.sh"
          identity=$(fm_pid_identity "$2")
          printf "epoch=1 owner_pid=%s outcome=arming updated_at=1 session_pid=%s\n%s\n" "$2" "$2" "$identity" > "$STATE/.claude-autoarm-epoch"
          fm_autoarm_claim_open "$STATE" 300
        ' test "$ROOT" "$holder" || fail "a busy publication invalidated a live auto-arm claim"
        : > "$dir/state/probe-holder"
        wait_for_file "$dir/state/verdict-holder" "the predecessor ownership verdict"
        old_verdict=$(cat "$dir/state/verdict-holder")
        [ "$old_verdict" != 0 ] || [ "$(cat "$dir/state/succ-gap")" != 0 ] \
          || fail "$mode: both sessions authorize during publication"
        : > "$dir/state/release"
        wait "$launch"
        succ=$(idle_fork_pid "$dir" succ)
        assert_takeover_leases "$dir" "$succ"
        rm -f "$dir/state/verdict-holder"
        : > "$dir/state/probe-holder"
        : > "$dir/state/probe-succ"
        wait_for_file "$dir/state/verdict-holder" "the retired holder verdict"
        wait_for_file "$dir/state/verdict-succ" "the successor holder verdict"
        expect_code 1 "$(cat "$dir/state/verdict-holder")" "$mode: retired predecessor still owns"
        expect_code 0 "$(cat "$dir/state/verdict-succ")" "$mode: committed successor does not own"
      else
        start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$dir/claim" \
          --fork-session --resume "$IDLE_FORK_HOLDER"
        rc=$(cat "$dir/state/succ.rc")
        if [ "$mode" = startup ]; then
          expect_code 1 "$rc" "$stage: startup unexpectedly acquired"
        else
          expect_code 0 "$rc" "$stage: refused Stop should remain silent"
        fi
        [ "$(cat "$dir/state/.lock")" = "$holder" ] || fail "$mode/$stage: predecessor pid lost"
        [ "$(cat "$dir/state/.lock-session")" = "$IDLE_FORK_HOLDER" ] || fail "$mode/$stage: predecessor session lost"
        [ ! -e "$dir/state/.lock-handover.jsonl" ] || fail "$mode/$stage: aborted handover recorded"
        [ ! -e "$dir/state/arm-ran" ] || fail "$mode/$stage: refused Stop armed"
        assert_takeover_leases "$dir" "$holder"
      fi
      stop_idle_fork_procs "$dir" holder succ
    done
  done
  pass "session-lock: startup and Stop serialize ownership, reject new turns, and roll back every interrupted takeover"
}

test_rekeyed_holder_retains_prior_session_takeover_proof() {
  local mode scenario dir config holder succ resume expected prior current=holder22222
  prepare_idle_fork_shim
  for mode in startup stop; do
    for scenario in prior current unrelated recent-prior recent-current missing-prior missing-current changed-prior malformed-prior; do
      dir=$TMP_ROOT/prior-$mode-$scenario
      config=$TMP_ROOT/prior-config-$mode-$scenario
      prepare_takeover_boundary "$dir" "$([ "$scenario" = changed-prior ] && echo backdated || echo lineage)" "$mode" "$config"
      write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 prior-turn
      write_idle_fork_turns "$config" "$current" 7200
      start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
      holder=$(idle_fork_pid "$dir" holder)
      printf '%s\n' "$current" > "$dir/state/rekey-holder"
      wait_for_file "$dir/state/rekey-holder.rc" "the same-process clear rekey"
      expect_code 0 "$(cat "$dir/state/rekey-holder.rc")" "the holder could not rekey"
      [ "$(cat "$dir/state/.lock")" = "$holder" ] || fail "clear changed the holder pid"
      [ "$(cat "$dir/state/.lock-session")" = "$(printf '%s\n%s' "$current" "$IDLE_FORK_HOLDER")" ] \
        || fail "clear did not retain exactly the prior session"
      seed_takeover_leases "$dir" "$holder"
      resume=$IDLE_FORK_HOLDER
      prior=$IDLE_FORK_HOLDER
      expected=1
      case "$scenario" in
        malformed-prior)
          prior=$IDLE_FORK_HOLDER$'\r'
          printf '%s\n%s\n' "$current" "$prior" > "$dir/state/.lock-session" ;;
        current) resume=$current ;;
        unrelated) resume=unrelated999 ;;
        recent-prior) write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 60 recent-prior-turn ;;
        recent-current) write_idle_fork_turns "$config" "$current" 60 recent-current-turn ;;
        missing-prior) rm "$config/projects/lab/$IDLE_FORK_HOLDER.jsonl" ;;
        missing-current) rm "$config/projects/lab/$current.jsonl" ;;
      esac
      case "$scenario" in prior|current) expected=0 ;; esac
      start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$dir/claim" \
        --fork-session --resume "$resume"
      if [ "$expected" -eq 0 ]; then
        succ=$(idle_fork_pid "$dir" succ)
        [ "$(cat "$dir/state/.lock")" = "$succ" ] || fail "$mode/$scenario: prior-session takeover failed"
        [ "$(cat "$dir/state/.lock-session")" = "$IDLE_FORK_SUCC" ] || fail "takeover inherited another holder's lineage"
        assert_takeover_leases "$dir" "$succ"
        [ -s "$dir/state/.lock-handover.jsonl" ] || fail "prior-session takeover was not recorded"
        if [ "$mode" = stop ]; then expected=2; fi
      else
        [ "$(cat "$dir/state/.lock")" = "$holder" ] || fail "$mode/$scenario: an ineligible successor took over"
        [ "$(cat "$dir/state/.lock-session")" = "$(printf '%s\n%s' "$current" "$prior")" ] || fail "refused takeover changed lineage"
        [ ! -e "$dir/state/.lock-handover.jsonl" ] || fail "$mode/$scenario: refused takeover was recorded"
        assert_takeover_leases "$dir" "$holder"
        if [ "$mode" = stop ]; then expected=0; fi
      fi
      expect_code "$expected" "$(cat "$dir/state/succ.rc")" "$mode/$scenario: wrong takeover verdict"
      kill -0 "$holder" || fail "the predecessor exited before the verdict"
      stop_idle_fork_procs "$dir" holder succ
    done
  done
  pass "session-lock: rekey A to empty B retains A; startup and Stop accept A or B and reject unrelated, recent, missing, or changed histories"
}

hold_sweep_for_ownership_test() {
  local dir=$1
  rm -f "$dir/state/sweep-ready"
  FM_HOME="$dir" STATE="$dir/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.lock.acquire"
    printf ready > "$STATE/sweep-ready"
    sleep 6
    fm_lock_release "$STATE/.lock.acquire"
  ' test "$ROOT" &
  BG_FIXTURE_PIDS+=("$!")
  wait_for_file "$dir/state/sweep-ready" "the bounded sweep claim"
}

test_bounded_sweep_does_not_discard_ownership_admission() {
  local dir=$TMP_ROOT/ownership-sweep config=$TMP_ROOT/ownership-sweep-config
  prepare_idle_fork_shim
  prepare_takeover_boundary "$dir" lineage stop "$config"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 prior-turn
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  hold_sweep_for_ownership_test "$dir"
  start_idle_fork_proc stop "$IDLE_FORK_HOLDER" "$dir" "$config" "$dir/bin/fm-claude-stop-autoarm.sh"
  expect_code 2 "$(cat "$dir/state/stop.rc")" "a six-second sweep discarded the owning Stop"
  [ -s "$dir/state/arm-ran" ] || fail "the owning Stop did not arm after the sweep"
  cat > "$dir/claim-generation" <<'SH'
#!/usr/bin/env bash
. "$FM_LOCK_TEST_ROOT/bin/fm-wake-lib.sh"
fm_autoarm_claim_next "$STATE" 300
SH
  chmod +x "$dir/claim-generation"
  hold_sweep_for_ownership_test "$dir"
  start_idle_fork_proc claim "$IDLE_FORK_HOLDER" "$dir" "$config" "$dir/claim-generation"
  expect_code 0 "$(cat "$dir/state/claim.rc")" "a six-second sweep discarded generation admission"
  stop_idle_fork_procs "$dir" holder stop claim
  pass "session-lock: a bounded sweep longer than five seconds preserves Stop and generation admission"
}

test_idle_fork_resume_of_a_quiet_holder_takes_the_lock() {
  local dir config holder succ
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-takeover
  config=$TMP_ROOT/idle-fork-takeover-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
  write_idle_fork_turns "$config" "$IDLE_FORK_SUCC" 7200 holder-turn-aaa successor-turn-bbb
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the idle holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] \
    || fail "the holder lock is $(cat "$dir/state/.lock"), expected $holder"
  seed_takeover_leases "$dir" "$holder"
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "the fork-resume successor was refused: $(cat "$dir/state/succ.out")"
  succ=$(idle_fork_pid "$dir" succ)
  kill -0 "$holder" 2>/dev/null || fail "the holder exited, so this was not a takeover from a live process"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$succ" ] \
    || fail "lock line 1 is $(cat "$dir/state/.lock"), expected the successor $succ"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = "$IDLE_FORK_SUCC" ] \
    || fail "the sidecar is $(cat "$dir/state/.lock-session"), expected $IDLE_FORK_SUCC"
  grep -q "\"from_pid\":$holder" "$dir/state/.lock-handover.jsonl" \
    || fail "the handover does not name the holder pid: $(cat "$dir/state/.lock-handover.jsonl")"
  grep -q "\"from_session\":\"$IDLE_FORK_HOLDER\"" "$dir/state/.lock-handover.jsonl" \
    || fail "the handover does not name the holder session: $(cat "$dir/state/.lock-handover.jsonl")"
  grep -q "\"to_pid\":$succ" "$dir/state/.lock-handover.jsonl" \
    || fail "the handover does not name the successor pid: $(cat "$dir/state/.lock-handover.jsonl")"
  grep -q "\"to_session\":\"$IDLE_FORK_SUCC\"" "$dir/state/.lock-handover.jsonl" \
    || fail "the handover does not name the successor session: $(cat "$dir/state/.lock-handover.jsonl")"
  assert_takeover_leases "$dir" "$succ"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a fork-resume successor of an idle holder takes the lock and records the handover"
}

test_failed_takeover_lease_move_preserves_exclusion() {
  local dir config holder rc
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-lease-failure
  config=$TMP_ROOT/idle-fork-lease-failure-config
  mkdir -p "$dir/state" "$dir/shim"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  holder=$(idle_fork_pid "$dir" holder)
  seed_takeover_leases "$dir" "$holder"
  cat > "$dir/shim/mv" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in */.lease-takeover-main) exit 1 ;; esac
exec /bin/mv "$@"
SH
  cat > "$dir/claim" <<'SH'
#!/usr/bin/env bash
export PATH="$FM_HOME/shim:$PATH"
exec "$FM_LOCK_TEST_ROOT/bin/fm-lock.sh"
SH
  chmod +x "$dir/shim/mv" "$dir/claim"
  FM_LOCK_TEST_ROOT="$ROOT" start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$dir/claim" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  rc=$(tr -d '[:space:]' < "$dir/state/succ.rc")
  expect_code 1 "$rc" "a failed lease move completed the takeover"
  [ "$(cat "$dir/state/.lock")" = "$holder" ] || fail "a failed lease move retired the holder"
  [ "$(cat "$dir/state/.lock-session")" = "$IDLE_FORK_HOLDER" ] || fail "a failed lease move lost the holder session"
  [ ! -e "$dir/state/.lock-handover.jsonl" ] || fail "a failed lease move recorded a handover"
  assert_takeover_leases "$dir" "$holder"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a partial lease move rolls back and keeps both actors excluded"
}

test_idle_fork_resume_without_a_successor_transcript_takes_the_lock_on_linux() {
  local dir config holder
  [ -r /proc/self/cmdline ] || {
    pass "session-lock: cmdline fork proof skipped where /proc cmdline is absent"
    return 0
  }
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-cmdline
  config=$TMP_ROOT/idle-fork-cmdline-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the idle holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "cmdline fork-resume without a successor transcript was refused: $(cat "$dir/state/succ.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$(idle_fork_pid "$dir" succ)" ] \
    || fail "cmdline proof did not move the lock: $(cat "$dir/state/.lock")"
  kill -0 "$holder" 2>/dev/null || fail "the holder was not still alive"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: Linux /proc argv proves an idle fork-resume when the successor transcript is absent"
}

test_holder_turn_within_thirty_minutes_is_not_taken_over() {
  local dir config holder
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-recent
  config=$TMP_ROOT/idle-fork-recent-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 60 holder-turn-recent
  write_idle_fork_turns "$config" "$IDLE_FORK_SUCC" 60 holder-turn-recent
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the recent holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "a holder with a turn in the last 30 minutes was taken over: $(cat "$dir/state/succ.out")"
  grep -q "another live firstmate session holds the lock (pid $holder, session $IDLE_FORK_HOLDER)" \
    "$dir/state/succ.out" || fail "the refusal did not name the live holder: $(cat "$dir/state/succ.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail "a recent holder lost the lock"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = "$IDLE_FORK_HOLDER" ] \
    || fail "a recent holder's session id was replaced"
  [ ! -e "$dir/state/.lock-handover.jsonl" ] || fail "a refused takeover wrote a handover"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a holder with a turn in the last 30 minutes is not taken over"
}

test_unreadable_holder_transcript_is_not_taken_over() {
  local dir config holder real
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-unread
  config=$TMP_ROOT/idle-fork-unread-config
  mkdir -p "$dir/state"
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the holder without a transcript could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "a missing holder transcript was taken over: $(cat "$dir/state/succ.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail "a missing transcript lost the lock"
  stop_idle_fork_procs "$dir" holder succ

  dir=$TMP_ROOT/idle-fork-symlink
  config=$TMP_ROOT/idle-fork-symlink-config
  mkdir -p "$dir/state" "$config/projects/lab"
  real=$config/projects/lab/real.jsonl
  printf '%s\n' '{"type":"user","uuid":"holder-turn-aaa","timestamp":"2020-01-01T00:00:00Z"}' > "$real"
  ln -s real.jsonl "$config/projects/lab/$IDLE_FORK_HOLDER.jsonl"
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the symlink-holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "a symlinked holder transcript was taken over: $(cat "$dir/state/succ.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail "a symlink transcript lost the lock"
  [ ! -e "$dir/state/.lock-handover.jsonl" ] || fail "a symlink transcript wrote a handover"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a missing or symlinked holder transcript is not taken over"
}

test_transcript_prefix_without_fork_argv_takes_the_lock() {
  local dir config holder succ
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-prefix
  config=$TMP_ROOT/idle-fork-prefix-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa holder-turn-bbb
  write_idle_fork_turns "$config" "$IDLE_FORK_SUCC" 7200 holder-turn-aaa holder-turn-bbb successor-turn-ccc
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the prefix holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "a transcript-prefix successor was refused: $(cat "$dir/state/succ.out")"
  succ=$(idle_fork_pid "$dir" succ)
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$succ" ] \
    || fail "prefix proof did not move the lock: $(cat "$dir/state/.lock")"
  kill -0 "$holder" 2>/dev/null || fail "the holder was not still alive"
  stop_idle_fork_procs "$dir" holder succ

  dir=$TMP_ROOT/idle-fork-diverge
  config=$TMP_ROOT/idle-fork-diverge-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
  write_idle_fork_turns "$config" "$IDLE_FORK_SUCC" 7200 other-turn-zzz
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the diverged holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "a transcript that is not a prefix was taken over: $(cat "$dir/state/succ.out")"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$holder" ] || fail "a diverged transcript lost the lock"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a shared transcript prefix takes an idle lock, and a diverged transcript does not"
}

test_stop_hook_of_an_idle_fork_successor_takes_the_lock() {
  local dir config holder succ
  prepare_idle_fork_shim
  dir=$TMP_ROOT/idle-fork-stop
  config=$TMP_ROOT/idle-fork-stop-config
  mkdir -p "$dir/state" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  : > "$dir/state/task.meta"
  cp -R "$ROOT/bin" "$dir/bin"
  : > "$dir/config/supervision-host-off"
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
echo "$$" >> "$FM_HOME/state/arm-ran"
printf 'pending:downtime:fixture-generation\n' > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-win actionable\n'
exit 0
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  write_idle_fork_turns "$config" "$IDLE_FORK_HOLDER" 7200 holder-turn-aaa
  write_idle_fork_turns "$config" "$IDLE_FORK_SUCC" 7200 holder-turn-aaa successor-turn-bbb
  start_idle_fork_proc holder "$IDLE_FORK_HOLDER" "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/holder.rc")" \
    "the stop-hook holder could not acquire the lock: $(cat "$dir/state/holder.out")"
  holder=$(idle_fork_pid "$dir" holder)
  seed_takeover_leases "$dir" "$holder"
  start_idle_fork_proc succ "$IDLE_FORK_SUCC" "$dir" "$config" "$dir/bin/fm-claude-stop-autoarm.sh" \
    --fork-session --resume "$IDLE_FORK_HOLDER"
  succ=$(idle_fork_pid "$dir" succ)
  expect_code 2 "$(tr -d '[:space:]' < "$dir/state/succ.rc")" \
    "the Stop hook did not rewake after takeover: $(cat "$dir/state/succ.out")"
  kill -0 "$holder" 2>/dev/null || fail "the holder exited before the Stop hook took the lock"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$succ" ] \
    || fail "the Stop hook left the lock at $(cat "$dir/state/.lock"), expected $succ"
  [ -e "$dir/state/arm-ran" ] || fail "the Stop hook took the lock but did not arm"
  assert_takeover_leases "$dir" "$succ"
  stop_idle_fork_procs "$dir" holder succ
  pass "session-lock: a Stop hook of an idle fork-resume successor takes the lock"
}

# Phone remote-continue is a fork-resume background copy of the terminal
# session. Each switch moves the one lock line. A return while the phone
# transcript still has a turn inside 30 minutes stays refused, so the phone
# remains the only holder.
test_repeated_remote_continue_switches_keep_one_holder() {
  local dir config term phone term2
  prepare_idle_fork_shim
  dir=$TMP_ROOT/remote-continue-switch
  config=$TMP_ROOT/remote-continue-switch-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" term11111 7200 t-turn
  write_idle_fork_turns "$config" phone22222 7200 t-turn p-turn
  write_idle_fork_turns "$config" term33333 7200 t-turn p-turn t2-turn
  start_idle_fork_proc term term11111 "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/term.rc")" \
    "the terminal could not acquire the lock: $(cat "$dir/state/term.out")"
  term=$(idle_fork_pid "$dir" term)
  [ "$(wc -l < "$dir/state/.lock" | tr -d ' ')" = 1 ] || fail "the terminal lock is not one line"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$term" ] || fail "the terminal is not the only holder"

  seed_takeover_leases "$dir" "$term"
  start_idle_fork_proc phone phone22222 "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume term11111
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/phone.rc")" \
    "the phone remote-continue was refused: $(cat "$dir/state/phone.out")"
  phone=$(idle_fork_pid "$dir" phone)
  [ "$(wc -l < "$dir/state/.lock" | tr -d ' ')" = 1 ] || fail "the phone lock is not one line"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$phone" ] || fail "the phone is not the only holder"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = phone22222 ] \
    || fail "the sidecar did not follow the phone"
  kill -0 "$term" 2>/dev/null || fail "the terminal exited when the phone took the lock"
  [ "$(grep -c '"to_pid":' "$dir/state/.lock-handover.jsonl")" = 1 ] \
    || fail "the phone switch did not record exactly one handover"

  assert_takeover_leases "$dir" "$phone"
  start_idle_fork_proc term2 term33333 "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume phone22222
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/term2.rc")" \
    "the return to the terminal was refused: $(cat "$dir/state/term2.out")"
  term2=$(idle_fork_pid "$dir" term2)
  [ "$(wc -l < "$dir/state/.lock" | tr -d ' ')" = 1 ] || fail "the return lock is not one line"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$term2" ] || fail "the returned terminal is not the only holder"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock-session")" = term33333 ] \
    || fail "the sidecar did not follow the returned terminal"
  kill -0 "$term" 2>/dev/null || fail "the first terminal exited during the return"
  kill -0 "$phone" 2>/dev/null || fail "the phone exited during the return"
  [ "$(grep -c '"to_pid":' "$dir/state/.lock-handover.jsonl")" = 2 ] \
    || fail "the round trip did not record exactly two handovers"
  assert_takeover_leases "$dir" "$(idle_fork_pid "$dir" term2)"
  stop_idle_fork_procs "$dir" term phone term2

  dir=$TMP_ROOT/remote-continue-recent-return
  config=$TMP_ROOT/remote-continue-recent-return-config
  mkdir -p "$dir/state"
  write_idle_fork_turns "$config" term11111 7200 t-turn
  write_idle_fork_turns "$config" phone22222 60 t-turn p-turn
  write_idle_fork_turns "$config" term33333 60 t-turn p-turn t2-turn
  start_idle_fork_proc term term11111 "$dir" "$config" "$ROOT/bin/fm-lock.sh"
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/term.rc")" \
    "the recent-return terminal could not acquire: $(cat "$dir/state/term.out")"
  term=$(idle_fork_pid "$dir" term)
  start_idle_fork_proc phone phone22222 "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume term11111
  expect_code 0 "$(tr -d '[:space:]' < "$dir/state/phone.rc")" \
    "an idle terminal refused the phone: $(cat "$dir/state/phone.out")"
  phone=$(idle_fork_pid "$dir" phone)
  start_idle_fork_proc term2 term33333 "$dir" "$config" "$ROOT/bin/fm-lock.sh" \
    --fork-session --resume phone22222
  expect_code 1 "$(tr -d '[:space:]' < "$dir/state/term2.rc")" \
    "a recent phone turn was taken over: $(cat "$dir/state/term2.out")"
  [ "$(wc -l < "$dir/state/.lock" | tr -d ' ')" = 1 ] || fail "a refused return left more than one lock line"
  [ "$(tr -d '[:space:]' < "$dir/state/.lock")" = "$phone" ] || fail "a refused return moved the only holder"
  [ "$(grep -c '"to_pid":' "$dir/state/.lock-handover.jsonl")" = 1 ] \
    || fail "a refused return wrote a second handover"
  stop_idle_fork_procs "$dir" term phone term2
  pass "session-lock: phone and terminal switches leave exactly one holder"
}

test_version_named_session_is_identified_on_both_platforms
test_harness_at_namespace_pid1_is_examined
test_ordinary_paths_are_never_harness_processes
test_harness_beyond_a_gap_never_owns_the_lock
test_competing_version_named_session_is_seen_as_live
test_same_session_id_owns_a_recycled_background_chain
test_anchor_pid_is_the_model_loop_process_only_for_a_trusted_id
test_e2e_version_named_session_claims_the_home
test_e2e_daemon_parented_session_claims_the_home
test_e2e_daemon_parented_version_named_session_keeps_its_lock
test_e2e_background_session_keeps_its_lock_across_a_recycled_chain
test_same_session_confirmation_refreshes_rekeyed_id_under_claim_lock
test_same_session_confirmation_does_not_steal_after_wait
test_failed_lock_write_restores_previous_sidecar
test_failed_lock_write_removes_new_sidecar_when_none_existed
test_verified_reclaim_keeps_new_sidecar
test_reanchor_keeps_task_leases_live
test_reanchor_keeps_autoarm_midturn_healthy
test_idle_fork_resume_of_a_quiet_holder_takes_the_lock
test_failed_takeover_lease_move_preserves_exclusion
test_idle_fork_resume_without_a_successor_transcript_takes_the_lock_on_linux
test_holder_turn_within_thirty_minutes_is_not_taken_over
test_unreadable_holder_transcript_is_not_taken_over
test_transcript_prefix_without_fork_argv_takes_the_lock
test_stop_hook_of_an_idle_fork_successor_takes_the_lock
test_repeated_remote_continue_switches_keep_one_holder
test_takeover_boundaries_share_one_commit
test_rekeyed_holder_retains_prior_session_takeover_proof
test_bounded_sweep_does_not_discard_ownership_admission
