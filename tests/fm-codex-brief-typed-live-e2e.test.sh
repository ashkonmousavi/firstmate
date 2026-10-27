#!/usr/bin/env bash
# tests/fm-codex-brief-typed-live-e2e.test.sh - live guard for the codex typed
# launch brief against the REAL installed codex on an isolated tmux server
# (live-harness-optin family; it submits a brief, so it spends codex tokens -
# run it with FM_CODEX_LIVE_E2E=1).
#
# codex-cli 0.163.0 never runs the positional launch prompt, so bin/fm-spawn.sh
# starts codex bare and delivers `FIRSTMATE_OP: v1 launch-brief` through
# fm_backend_send_text_submit after a readiness gate that answers the
# folder-trust dialog with Enter and skips the update dialog with Escape.
# Per .agents/skills/firstmate-coding-guidelines "Harness-dependent checks",
# that gate is built on vendor-rendered dialog and composer text, so the
# portable suite (tests/fm-codex-harness.test.sh) is not enough on its own:
# this guard drives the REAL bin/fm-spawn.sh and the REAL installed codex and
# proves both halves of the fix's DONE MEANS on the tmux backend - a codex
# scout spawned in a NEW folder (trust dialog answered by the gate) and in the
# SAME now-TRUSTED folder (a relaunch, captured to prove no trust dialog
# rendered) each start processing their launch brief within 60 s through the
# typed submit, and the turn's reply lands. The named herdr-lab proof is
# tests/fm-codex-brief-typed-herdr-lab-e2e.test.sh; this guard covers every
# machine with codex and tmux and no lab session. It fails naming codex and
# `codex --version`. Refresh docs/verification/runtime-backends.md ("Codex
# typed launch brief") from this guard's output after any codex upgrade.
#
# Isolation: every tmux call, fm-spawn's own included, rides a PATH shim that
# pins a private tmux server (the same pattern as
# tests/fm-composer-codex-idle-live-e2e.test.sh), so no fleet session is
# touched. The worktree comes from the real treehouse pool and is returned in
# cleanup.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CODEX_LIVE_E2E codex tmux treehouse

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

CODEX_VERSION=$(codex --version 2>/dev/null | head -1)

SOCKET="fm-codex-typed-$$"
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-typed-live.XXXXXX")
REAL_TMUX=$(command -v tmux)
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-codex-typed-live.XXXXXX")
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
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  # Spawn leaves each state/<id>.git-hooks strip dir read-only.
  find "$TMP_ROOT" -type d -exec chmod u+rwx {} + 2>/dev/null
  rm -rf "$TMP_ROOT" "$SHIM_DIR"
  return "$status"
}
trap cleanup_all EXIT

tmux -L "$SOCKET" -f /dev/null new-session -d -s firstmate -x 200 -y 50 -c "$TMP_ROOT" \
  || fail "could not start the isolated tmux server"

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

# spawn_scout <id> [extra args...]: a REAL fm-spawn scout spawn on the private
# tmux server. Sets SPAWN_RC, SPAWN_ELAPSED, and SPAWN_OUT in the caller's
# shell (run directly, never inside a command substitution).
SPAWN_OUT=; SPAWN_RC=; SPAWN_ELAPSED=
spawn_scout() {  # <fm-spawn args...> (the exact args fm-spawn takes)
  local start=$SECONDS
  SPAWN_OUT=$(env -u TMUX \
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
  local target
  target=$(grep '^window=' "$HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2- | tail -1)
  [ -n "$target" ] || return 1
  tmux capture-pane -p -t "$target" -S -400 2>/dev/null
}

pane_visible_capture() {
  local target
  target=$(grep '^window=' "$HOME_DIR/state/$1.meta" 2>/dev/null | cut -d= -f2- | tail -1)
  [ -n "$target" ] || return 1
  tmux capture-pane -p -t "$target" -S -0 2>/dev/null
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

spawn_scout "$SCOUT" "$PROJ" --scout --harness codex --backend tmux
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
  || fail "the new-folder pane never showed the typed launch-brief envelope"$'\n'"$(pane_capture "$SCOUT" | tail -25)"
wait_for_pane_text "$SCOUT" 'codex-brief-ok' 90 \
  || fail "the new-folder scout never replied codex-brief-ok"$'\n'"$(pane_capture "$SCOUT" | tail -25)"
pass "real codex $CODEX_VERSION on tmux: a new-folder scout starts processing its typed launch brief within ${SPAWN_ELAPSED}s and answers it"

# --- 2. TRUSTED folder: a relaunch of the same worktree, captured to prove
#        no trust dialog stood between launch and the typed brief -------------

sed 's/codex-brief-ok/codex-relaunch-ok/' "$HOME_DIR/data/$SCOUT/brief.md" >"$TMP_ROOT/relaunch-brief.md"
cp "$TMP_ROOT/relaunch-brief.md" "$HOME_DIR/data/$SCOUT/brief.md"

TRUST_POLL="$TMP_ROOT/trust-poll.log"
( for _ in $(seq 1 200); do
    pane_visible_capture "$SCOUT" >>"$TRUST_POLL" 2>/dev/null || :
    sleep 0.3
  done ) &
TRUST_POLLER=$!

env -u TMUX FM_SPAWN_NO_GUARD=1 FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  "$ROOT/bin/fm-control.sh" "$SCOUT" exit >/dev/null 2>&1 \
  || fail "the scout's codex agent could not be exited before the relaunch"

spawn_scout "$SCOUT" --relaunch
kill "$TRUST_POLLER" 2>/dev/null || true
wait "$TRUST_POLLER" 2>/dev/null || true
if [ "$SPAWN_RC" -ne 0 ]; then
  fail "a codex relaunch in the trusted folder failed within ${SPAWN_ELAPSED}s"$'\n'"$SPAWN_OUT"
fi
[ "$SPAWN_ELAPSED" -le 60 ] || fail "the trusted-folder relaunch took ${SPAWN_ELAPSED}s to start processing its brief (bound: 60s)"
wait_for_pane_text "$SCOUT" 'codex-relaunch-ok' 90 \
  || fail "the trusted-folder scout never replied codex-relaunch-ok"$'\n'"$(pane_capture "$SCOUT" | tail -25)"
[ -s "$TRUST_POLL" ] || fail "codex $CODEX_VERSION trusted-folder viewport was never observed"
if grep -Fq 'Trust this folder' "$TRUST_POLL"; then
  fail "codex $CODEX_VERSION showed a trust dialog in the trusted-folder case"
fi
pass "real codex $CODEX_VERSION on tmux: the trusted-folder relaunch rendered no trust dialog"
pass "real codex $CODEX_VERSION on tmux: a trusted-folder relaunch starts processing its typed launch brief within ${SPAWN_ELAPSED}s"

cleanup_all
trap - EXIT
printf 'ok - real codex %s typed launch brief verified end to end on an isolated tmux server\n' "$CODEX_VERSION"
