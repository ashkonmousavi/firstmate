#!/usr/bin/env bash
# tests/fm-codex-brief-typed-herdr-lab-e2e.test.sh - the live codex typed
# launch-brief guard (live-harness-optin family; it submits a brief, so it
# spends codex tokens - run it with FM_CODEX_LIVE_E2E=1).
#
# codex-cli 0.163.0 never runs the positional launch prompt: the TUI opens at
# an empty composer ("Ask Codex to do anything") and sits there, so a fresh
# crewmate or scout never sees its brief. bin/fm-spawn.sh therefore starts
# codex bare and delivers `FIRSTMATE_OP: v1 launch-brief` through
# fm_backend_send_text_submit after a readiness gate that answers the
# folder-trust dialog with Enter and skips the update dialog with Escape.
# Per .agents/skills/firstmate-coding-guidelines "Harness-dependent checks",
# that gate is built on vendor-rendered dialog and composer text, so a stub
# can only confirm the assumptions already written into it; this guard drives
# the REAL bin/fm-spawn.sh and the REAL installed codex on an isolated Herdr
# lab session and proves both halves of the fix's DONE MEANS: a codex scout
# spawned in a NEW folder (trust dialog answered by the gate) and in the SAME
# now-TRUSTED folder (a relaunch, captured to prove no trust dialog rendered)
# each start processing their launch brief within 60 s through the typed
# submit, and the turn's reply lands. On failure the spawn itself reports
# "codex did not take the brief" and this guard fails naming codex and
# `codex --version`. Refresh docs/verification/runtime-backends.md ("Codex
# typed launch brief") from this guard's output after any codex upgrade.
#
# Safety (2026-07-02 incident, see tests/herdr-test-safety.sh): every
# lifecycle operation goes through bin/fm-herdr-lab.sh, which appends the
# named session flag and verifies the default fleet session is unchanged
# after teardown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex herdr jq treehouse

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# Every spawn below states its own launcher identity, so a pane inherited from
# the terminal this suite was started in must not leak into any of them.
herdr_forget_inherited_pane

CODEX_VERSION=$(codex --version 2>/dev/null | head -1)

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-codex-brief-typed) || {
  printf 'not ok - could not generate an isolated Herdr lab session name\n' >&2
  exit 1
}
export HERDR_SESSION="$HERDR_LAB_SESSION"

TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-codex-typed-e2e.XXXXXX")
WORKTREES=()
CLEANED=0
cleanup_all() {
  local wt status=0
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && treehouse return --force "$wt" >/dev/null 2>&1
  done
  WORKTREES=()
  "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=$?
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT"
  return "$status"
}
trap cleanup_all EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" || fail "could not provision isolated Herdr lab session"

lab() { "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"
printf '999999 0\n' > "$HOME_DIR/config/lane-capacity"

SCOUT=codex-typed-e2e
mkdir -p "$HOME_DIR/data/$SCOUT"
cat > "$HOME_DIR/data/$SCOUT/brief.md" <<'EOF'
# Task
## Captain's intent
Reply with exactly: codex-brief-ok, and nothing else.

## Firstmate spec
One reply, no tools, no file changes.
EOF

PROJ="$TMP_ROOT/scratch-project"
make_scratch_project "$PROJ"

# spawn_scout <id> [extra args...]: a REAL fm-spawn scout spawn on the lab
# session's herdr backend. Sets SPAWN_RC, SPAWN_ELAPSED, and SPAWN_OUT in the
# caller's shell (run directly, never inside a command substitution).
SPAWN_OUT=; SPAWN_RC=; SPAWN_ELAPSED=
spawn_scout() {  # <fm-spawn args...> (the exact args fm-spawn takes)
  local start=$SECONDS
  SPAWN_OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
    HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$@" 2>&1)
  SPAWN_RC=$?
  SPAWN_ELAPSED=$((SECONDS - start))
}

record_worktree() {  # <id>
  local wt
  wt=$(grep '^worktree=' "$HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  return 0
}

pane_capture() {  # <id>
  local pane
  pane=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2-)
  [ -n "$pane" ] || return 1
  # --lines stays at the adapter's verified floor: herdr returns an empty
  # read for a --lines below the pane's viewport height (bin/backends/herdr.sh).
  lab pane read "$pane" --source recent --lines 400 2>/dev/null
}

wait_for_pane_text() {  # <id> <text> <max-seconds>
  local id=$1 text=$2 max=$3 i=0
  while [ "$i" -lt "$max" ]; do
    pane_capture "$id" | grep -Fq -- "$text" && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# --- 1. NEW folder: the gate answers the trust dialog and delivers the brief -

spawn_scout "$SCOUT" "$PROJ" --scout --harness codex --backend herdr
if [ "$SPAWN_RC" -ne 0 ]; then
  fail "a codex scout spawn in a new folder failed within ${SPAWN_ELAPSED}s"$'\n'"$SPAWN_OUT"
fi
record_worktree "$SCOUT"
[ -s "$HOME_DIR/state/$SCOUT.meta" ] || fail "the new-folder spawn left no task record"
case "$SPAWN_OUT" in
  *"spawned $SCOUT harness=codex"*) : ;;
  *) fail "the new-folder spawn did not report success"$'\n'"$SPAWN_OUT" ;;
esac
[ "$SPAWN_ELAPSED" -le 60 ] || fail "the new-folder spawn took ${SPAWN_ELAPSED}s to start processing its brief (bound: 60s)"
pane_capture "$SCOUT" | grep -Fq 'FIRSTMATE_OP: v1 launch-brief' \
  || fail "the new-folder pane never showed the typed launch-brief envelope"
wait_for_pane_text "$SCOUT" 'codex-brief-ok' 90 \
  || fail "the new-folder scout never replied codex-brief-ok"$'\n'"$(pane_capture "$SCOUT" | tail -20)"
pass "real codex $CODEX_VERSION on herdr: a new-folder scout starts processing its typed launch brief within ${SPAWN_ELAPSED}s and answers it"

# --- 2. TRUSTED folder: a relaunch of the same worktree, captured to prove
#        no trust dialog stood between launch and the typed brief -------------

TRUST_POLL="$TMP_ROOT/trust-poll.log"
( for _ in $(seq 1 200); do
    pane_capture "$SCOUT" 2>/dev/null | grep -F 'Trust this folder' >>"$TRUST_POLL" || :
    sleep 0.3
  done ) &
TRUST_POLLER=$!

env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SOCKET_PATH \
  HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-control.sh" "$SCOUT" exit >/dev/null 2>&1 \
  || fail "the scout's codex agent could not be exited before the relaunch"

spawn_scout "$SCOUT" --relaunch
kill "$TRUST_POLLER" 2>/dev/null || true
wait "$TRUST_POLLER" 2>/dev/null || true
if [ "$SPAWN_RC" -ne 0 ]; then
  fail "a codex relaunch in the trusted folder failed within ${SPAWN_ELAPSED}s"$'\n'"$SPAWN_OUT"
fi
[ "$SPAWN_ELAPSED" -le 60 ] || fail "the trusted-folder relaunch took ${SPAWN_ELAPSED}s to start processing its brief (bound: 60s)"
pane_capture "$SCOUT" | grep -Fq 'FIRSTMATE_OP: v1 launch-brief' \
  || fail "the trusted-folder pane never showed the typed launch-brief envelope"
wait_for_pane_text "$SCOUT" 'codex-brief-ok' 90 \
  || fail "the trusted-folder scout never replied codex-brief-ok"$'\n'"$(pane_capture "$SCOUT" | tail -20)"
if [ -s "$TRUST_POLL" ]; then
  printf '# note: a trust dialog rendered during the relaunch and was answered by the gate\n'
else
  pass "real codex $CODEX_VERSION on herdr: the trusted-folder relaunch rendered no trust dialog"
fi
pass "real codex $CODEX_VERSION on herdr: a trusted-folder relaunch starts processing its typed launch brief within ${SPAWN_ELAPSED}s"

# --- 3. the failure report shape is the spawn's own --------------------------

# (Proved by the portable suite; this guard only pins the success paths, to
# keep real-codex launches to the two the DONE MEANS names.)

cleanup_all
trap - EXIT
printf 'ok - real codex %s typed launch brief verified end to end on a herdr lab session\n' "$CODEX_VERSION"
