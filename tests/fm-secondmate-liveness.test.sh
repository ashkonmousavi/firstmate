#!/usr/bin/env bash
# tests/fm-secondmate-liveness.test.sh - the session-start secondmate liveness
# guarantee owned by bin/fm-backend.sh's detailed fm_backend_agent_state and
# bin/fm-bootstrap.sh's secondmate_liveness_sweep that acts on it.
#
# The gap under test (AGENTS.md "Session start"; evidence 2026-07-07): a
# secondmate agent that has exited leaves its backend endpoint alive as a bare
# shell. fm_backend_target_exists only checks pane PRESENCE, so it reports
# that shell "alive"; recovery only respawns endpoints reported dead, and the
# watcher deliberately exempts secondmates from stale-pane detection (an idle
# secondmate pane is healthy by design). A dead-shell secondmate was therefore
# invisible to every existing check and sat dead indefinitely.
#
# The guarantees under test:
#   - fm_backend_agent_state is the detailed owner that distinguishes alive,
#     dead, missing, ambiguous, unreadable, and unverified.
#   - The tmux classifier returns missing only after a readable session
#     inventory omits the exact window, regardless of display-message fallback.
#   - The Herdr classifier preserves the proven husk mapping while separating a
#     missing pane from an existing agent-less pane.
#   - fm_backend_agent_alive preserves the older three-state compatibility view.
#   - bin/fm-bootstrap.sh's secondmate_liveness_sweep recovers only dead or
#     missing endpoints, keeps successful recovery and already-live results
#     silent by default, and reports ambiguous and unreadable targets distinctly.
#   - The sweep converges: once a secondmate reads alive, a later run never
#     re-touches it (idempotent by construction, not by remembering what it
#     already did).
#   - The sweep is skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1 (the
#     read-only session path), matching the other mutating sweeps.
#   - The sweep is naturally scoped to the primary: with no kind=secondmate
#     meta present (a secondmate's own state/ never holds one, since
#     secondmates never spawn secondmates), it is a silent no-op.
#   - An owner park (config/secondmate-parked/<id>) keeps that mate stopped
#     through this sweep. Rearm of the crash-loop bound does not clear it.
#     bin/fm-secondmate-park.sh unpark is what makes relaunch eligible again.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-secondmate-liveness)

# --- unit level: fm_backend_tmux_agent_state --------------------------------

# make_probe_tmux <dir> <pane_current_command>: a fake tmux whose
# #{pane_current_command} display-message query answers with the fixed value;
# every other subcommand is a silent no-op success.
make_probe_tmux() {
  local dir=$1 comm=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    for a in "\$@"; do case "\$a" in *pane_current_command*) printf '%s\n' '$comm'; exit 0 ;; esac; done
    exit 0 ;;
  list-windows) printf '%s\n' win; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_failed_probe_tmux <dir> <inventory>: missing and present fail the pane
# read, while unreadable returns a misleading fallback node process but fails
# the inventory that must be authoritative.
make_failed_probe_tmux() {
  local dir=$1 inventory=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
case "\${1:-}" in
  display-message)
    [ '$inventory' = unreadable ] && { printf '%s\n' node; exit 0; }
    exit 1
    ;;
  list-windows)
    case '$inventory' in
      missing) printf '%s\n' main ; exit 0 ;;
      missing-session) printf '%s\n' "can't find session: sess" >&2; exit 1 ;;
      missing-server) printf '%s\n' "no server running on /tmp/tmux-test/default" >&2; exit 1 ;;
      missing-socket) printf '%s\n' "error connecting to /tmp/tmux-test/default (No such file or directory)" >&2; exit 1 ;;
      present) printf '%s\n' fm-sm1 ; exit 0 ;;
      *) printf '%s\n' "permission denied" >&2; exit 1 ;;
    esac
    ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"
  printf '%s\n' "$fakebin"
}

test_tmux_agent_state_classifies() {
  local fb out

  for harness in claude codex opencode grok kimi pi pi-signed pi-launcher Pi; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-$harness" "$harness")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = alive ] || fail "a live $harness foreground process should classify as alive, got '$out'"
  done

  for shell in zsh bash -zsh; do
    fb=$(make_probe_tmux "$TMP_ROOT/tmux-${shell#-}" "$shell")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
    [ "$out" = dead ] || fail "a bare $shell foreground process should classify as dead, got '$out'"
  done

  fb=$(make_probe_tmux "$TMP_ROOT/tmux-node" node)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = ambiguous ] || fail "an existing node process should classify as ambiguous, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:win' "$ROOT")" = unknown ] \
    || fail "the compatibility view must keep an existing node process unknown"

  fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-missing" missing)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
  [ "$out" = missing ] || fail "a readable inventory omitting the target should classify as missing, got '$out'"
  [ "$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive tmux sess:fm-sm1' "$ROOT")" = dead ] \
    || fail "the compatibility view should treat an authoritatively missing target as dead"

  for inventory in present unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = unreadable ] || fail "a $inventory inventory case should stay unreadable, got '$out'"
  done

  for inventory in missing-session missing-server missing-socket; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/tmux-$inventory" "$inventory")
    out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:fm-sm1' "$ROOT")
    [ "$out" = missing ] || fail "a confirmed $inventory inventory failure should classify as missing, got '$out'"
  done

  pass "fm_backend_tmux_agent_state: separates live, dead, missing, ambiguous, and unreadable"
}

test_tmux_agent_state_rejects_malformed_targets_before_probe() {
  local fakebin marker target out
  fakebin=$(fm_fakebin "$TMP_ROOT/tmux-malformed")
  marker="$TMP_ROOT/tmux-malformed-called"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'called\n' > "$FM_TEST_TMUX_MARKER"
printf 'bash\n'
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"

  for target in sess sess: :win sess:win:extra; do
    out=$(PATH="$fakebin:$BASE_PATH" FM_TEST_TMUX_MARKER="$marker" \
      bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux "$1"' "$ROOT" "$target")
    [ "$out" = unreadable ] || fail "malformed tmux target '$target' should classify as unreadable, got '$out'"
    [ ! -e "$marker" ] || fail "malformed tmux target '$target' invoked tmux"
  done

  pass "fm_backend_tmux_agent_state: rejects malformed targets before probing tmux"
}

# --- unit level: fm_backend_herdr_agent_state -------------------------------

test_herdr_agent_state_preserves_husk_classifier() {
  local pane_state expected out

  # Pin the session server as running so an installed herdr on the host
  # cannot turn the unknown row into a stopped-server `missing`.
  for row in 'dead missing' 'no-agent dead' 'live alive' 'unknown unreadable'; do
    pane_state=${row%% *}
    expected=${row#* }
    out=$(FM_TEST_PANE_STATE="$pane_state" bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "%s" "$FM_TEST_PANE_STATE"; }; fm_backend_herdr_server_running_state() { printf running; }; fm_backend_herdr_agent_state "sess:p1"' "$ROOT")
    [ "$out" = "$expected" ] || fail "Herdr pane state $pane_state should map to $expected, got '$out'"
  done

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_agent_state "no-colon-target"' "$ROOT")
  [ "$out" = unreadable ] || fail "an unparseable Herdr target should classify as unreadable, got '$out'"

  out=$(bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_pane_agent_state() { printf "no-agent"; }; fm_backend_herdr_agent_alive "sess:p1"' "$ROOT")
  [ "$out" = dead ] || fail "the Herdr compatibility view should keep a no-agent husk dead, got '$out'"

  pass "fm_backend_herdr_agent_state: preserves missing/no-agent/live/unknown husk behavior"
}

# --- unit level: the generic dispatchers ------------------------------------

test_agent_state_dispatcher_and_compatibility() {
  local fb out

  fb=$(make_probe_tmux "$TMP_ROOT/dispatch-tmux" claude)
  out=$(PATH="$fb:$BASE_PATH" bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state tmux sess:win' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route tmux, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_pane_agent_state() { printf "live"; }; fm_backend_agent_state herdr sess:p1' "$ROOT")
  [ "$out" = alive ] || fail "detailed dispatcher should route Herdr, got '$out'"

  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_state zellij sess:7' "$ROOT")
  [ "$out" = unverified ] || fail "Zellij should remain unverified, got '$out'"
  out=$(bash -c '. "$0/bin/fm-backend.sh"; fm_backend_agent_alive zellij sess:7' "$ROOT")
  [ "$out" = unknown ] || fail "the compatibility dispatcher should map unverified to unknown, got '$out'"

  pass "fm_backend_agent_state: routes tmux/Herdr and keeps Zellij unverified"
}

# --- sweep level: bin/fm-bootstrap.sh's secondmate_liveness_sweep -----------

# make_toolchain <dir>: the fixed set of stubs bin/fm-bootstrap.sh's read-only
# diagnostics need to stay quiet (mirrors tests/fm-secondmate-sync.test.sh's
# make_fake_toolchain), MINUS tmux - callers add their own controllable tmux.
make_toolchain() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" node chrome-devtools-axi pi-signed
  fm_fake_version_tool "$fakebin" lavish-axi FM_FAKE_LAVISH_AXI_VERSION 0.1.80
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.29'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  --version:*) printf '%s\n' 'v3.1.8' ;;
  get:--help) printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>] [--json]' ;;
  return:--help) printf '%s\n' 'Usage: treehouse return [--if-lease-id <id>] [--if-lease-holder <holder>]' ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' 'no-mistakes version v1.46.0 (fake)'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "--version ") printf '%s\n' '0.2.6' ;;
  "update --help") printf '%s\n' 'usage: tasks-axi update <id> [flags]' '  --archive-body' ;;
  "mv --help") printf '%s\n' 'usage: tasks-axi mv <id> [<id>...] --to <path-or-dir>' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tasks-axi"
  cat > "$fakebin/quota-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
  printf '%s\n' '0.1.51'
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/quota-axi"
  printf '%s\n' "$fakebin"
}

# make_liveness_tmux <dir>: a controllable tmux stub. FM_TEST_PANE_CMD may be
# a foreground command, `missing` (readable inventory omits the window), or
# `unreadable` (both pane and inventory reads fail).
make_liveness_tmux() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
mode=${FM_TEST_PANE_CMD:-zsh}
windows="${FM_TMUX_CALL_LOG:?}.windows"
case "${1:-}" in
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      for arg in "$@"; do
        case "$arg" in
          ". '"*"'") staged=${arg#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || cat "$staged" >> "$FM_FAKE_LAUNCH_LOG" ;;
          *'encode launch-brief'*|*'Firstmate operational input waiting: read'*) printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*)
          case "$mode" in
            missing) printf '%s\n' node; exit 0 ;;
            unreadable) exit 1 ;;
            *) printf '%s\n' "$mode"; exit 0 ;;
          esac
          ;;
      esac
    done
    exit 0
    ;;
  list-windows)
    case "$mode" in
      missing)
        printf '%s\n' main
        [ ! -s "$windows" ] || cat "$windows"
        exit 0 ;;
      unreadable) exit 1 ;;
      *)
        [ -e "${FM_TMUX_CALL_LOG:?}.killed" ] || printf '%s\n' fm-sm1
        [ ! -s "$windows" ] || cat "$windows"
        exit 0 ;;
    esac
    ;;
  new-window|kill-window)
    printf '%s\n' "$*" >> "${FM_TMUX_CALL_LOG:?}"
    [ "${FM_TEST_FAIL_KILL:-0}" = 1 ] && [ "${1:-}" = kill-window ] && exit 1
    if [ "${1:-}" = new-window ] && [ -n "${FM_TEST_NEW_WINDOW_PAUSE:-}" ]; then
      sleep "$FM_TEST_NEW_WINDOW_PAUSE"
    fi
    if [ "${1:-}" = new-window ]; then
      name=
      previous=
      for arg in "$@"; do
        [ "$previous" = -n ] && name=$arg
        previous=$arg
      done
      grep -Fqx -- "$name" "$windows" 2>/dev/null || printf '%s\n' "$name" >> "$windows"
    fi
    [ "${1:-}" = kill-window ] && : > "${FM_TMUX_CALL_LOG}.killed"
    [ "${FM_TEST_FAIL_NEW_WINDOW:-0}" = 1 ] && [ "${1:-}" = new-window ] && exit 1
    [ "${1:-}" = new-window ] && rm -f "${FM_TMUX_CALL_LOG}.killed"
    exit 0
    ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_test_codex_first_turn_wrap "$fakebin"
  printf '%s\n' "$fakebin"
}

# new_world <name>: a scratch firstmate HOME (state/, watcher beacon, pinned
# harness) with no kind=secondmate meta yet. FM_ROOT is left to resolve
# naturally to the real checkout under test ($ROOT), exactly as production
# always has it - this sweep's own fm-spawn.sh invocation resolves the
# secondmate harness through $FM_ROOT/bin/fm-harness.sh, which only exists in
# the real tree. The harness is pinned because ambient own-harness detection is
# environment-dependent: interactive harness sessions expose markers or parent
# process names, while a plain pipeline shell can fall through to "unknown",
# which has no fm-spawn.sh launch template.
new_world() {
  local name=$1 w
  w="$TMP_ROOT/$name"
  mkdir -p "$w/home/state" "$w/home/config"
  touch "$w/home/state/.last-watcher-beat"
  printf 'codex\n' > "$w/home/config/crew-harness"
  printf '%s\n' "$w"
}

# add_sm_home <w> <id> <window>: a plain (non-git) secondmate home - the
# probe/respawn machinery under test never requires the home to be a real
# worktree; a non-git home just makes the unrelated fast-forward sweep log a
# harmless "not a git repo" skip.
add_sm_home() {
  local w=$1 id=$2 window=$3 harness=${4:-claude}
  local home="$w/$id"
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$home/.gitignore"
  git -C "$home" init -q -b main
  {
    printf 'window=%s\n' "$window"
    printf 'kind=secondmate\n'
    printf 'harness=%s\n' "$harness"
    printf 'home=%s\n' "$home"
  } > "$w/home/state/$id.meta"
}

run_bootstrap() {  # <fakebin> <home> <pane-cmd> <call-log> [extra env...] -> stdout
  local fb=$1 home=$2 cmd=$3 log=$4; shift 4
  PATH="$fb:$BASE_PATH" TMUX='' FM_BACKEND=tmux FM_HOME="$home" \
    FM_TEST_PANE_CMD="$cmd" FM_TMUX_CALL_LOG="$log" \
    env "$@" "$ROOT/bin/fm-bootstrap.sh" 2>&1
}

test_sweep_respawns_confirmed_dead_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawned" \
    "a successfully respawned secondmate should be handled silently"
  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" \
    "the stale endpoint must be killed before respawn (tmux refuses a same-named window over a live one)"
  assert_contains "$(cat "$log")" "new-window" \
    "a confirmed-dead secondmate should actually be relaunched"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" \
    "the shared library did not leave the durable per-mate relaunch record"
  pass "sweep: a confirmed-dead secondmate endpoint is killed and respawned"
}

test_sweep_reuses_retained_secondmate_home() {
  local w fb tmuxfb log out
  w=$(new_world sweep-retained-home)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  printf 'worktree=%s\n' "$w/sm1" >> "$w/home/state/sm1.meta"
  printf 'retained secondmate work\n' > "$w/sm1/notes.txt"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" 'SECONDMATE_LIVENESS:' 'retained-home recovery failed'
  assert_grep 'new-window' "$log" 'missing secondmate was not respawned'
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" 'sweep did not finish recovery'
  assert_grep "worktree=$w/sm1" "$w/home/state/sm1.meta" 'sweep replaced the retained home'
  assert_grep "home=$w/sm1" "$w/home/state/sm1.meta" 'sweep lost the validated home'
  assert_grep 'retained secondmate work' "$w/sm1/notes.txt" 'sweep discarded retained home work'
  pass 'sweep: a missing secondmate reuses its validated retained home'
}

test_sweep_recovers_the_durable_secondmate_account() {
  local w fb tmuxfb log out
  w=$(new_world sweep-account)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  mkdir -p "$w/home/config/secondmate-accounts/sm1" "$w/mate-account" "$w/primary-account" "$w/user-home"
  printf 'claude\n' > "$w/home/config/secondmate-harness"
  printf '%s\n' "$w/primary-account" > "$w/home/config/claude-account"
  printf '%s\n' "$w/mate-account" > "$w/home/config/secondmate-accounts/sm1/claude-account"
  : > "$w/mate-account/.credentials.json"
  cat > "$fb/claude" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = auth ] && [ "${2:-}" = status ] || exit 0
[ -f "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json" ]
SH
  chmod +x "$fb/claude"
  log="$w/calls.log"; : > "$log"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" \
    HOME="$w/user-home" CLAUDE_CONFIG_DIR="$w/ambient-account" FM_FAKE_LAUNCH_LOG="$w/launch.log")
  assert_not_contains "$out" 'SECONDMATE_LIVENESS: secondmate sm1:' "account recovery should succeed: $out"
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" "recovery must finish"
  assert_grep "account=$w/mate-account" "$w/home/state/sm1.meta" "recovery must record the configured mate account"
  assert_grep "CLAUDE_CONFIG_DIR='$w/mate-account'" "$w/launch.log" "recovery must launch on the durable mate pin, not the ambient account"
  pass "sweep: secondmate recovery resolves its durable account despite a different ambient login"
}

test_sweep_serializes_distinct_secondmate_relaunches() {
  local w fb tmuxfb log out id
  w=$(new_world sweep-concurrent-relaunch)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  add_sm_home "$w" sm2 firstmate:fm-sm2
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Keep the first fresh spawn inside new-window with its task-set lock held.
  # A parallel sweep races the second spawn into that lock and loses it.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_NEW_WINDOW_PAUSE=2)

  assert_not_contains "$out" 'SECONDMATE_LIVENESS: secondmate sm' \
    "both distinct mates should relaunch without task-set contention"
  for id in sm1 sm2; do
    assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-$id" \
      "$id did not complete its relaunch"
  done
  [ "$(grep -c '^new-window ' "$log")" -eq 2 ] \
    || fail "both mates should reach a fresh spawn: $(cat "$log")"
  pass "sweep: distinct secondmate relaunches serialize across the task-set lock"
}

# The T3-only close refusal (fm_secondmate_liveness_relaunch) must leave every
# other backend on its existing best-effort kill: a tmux close that fails is
# still followed by the guarded spawn, exactly as before.
test_sweep_keeps_tmux_best_effort_kill_when_close_fails() {
  local w fb tmuxfb log out
  w=$(new_world sweep-dead-close-fails)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_TEST_FAIL_KILL=1)

  assert_contains "$(cat "$log")" "kill-window -t =firstmate:=fm-sm1" "the close is attempted"
  assert_not_contains "$out" "could not prove the old" "a non-T3 close failure must not take the T3-only refusal path"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after confirmed agent absence on existing endpoint" \
    "the guarded spawn still runs after a failed tmux close, as before"
  pass "sweep: a tmux secondmate whose close fails keeps the existing best-effort kill and guarded spawn"
}

test_sweep_skips_mate_whose_liveness_lock_is_held() {
  local w fb tmuxfb log out holder i=0
  w=$(new_world sweep-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # A concurrent liveness episode (the watcher's tick) owns the per-mate lock;
  # the sweep must skip rather than probe or relaunch a moving target.
  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_acquire_wait "$2" && sleep 30' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$w/home/state/.secondmate-liveness-sm1.lock" ) &
  holder=$!
  while [ ! -d "$w/home/state/.secondmate-liveness-sm1.lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -d "$w/home/state/.secondmate-liveness-sm1.lock" ] || fail "the fixture never acquired the liveness lock"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: another liveness check is already in progress" \
    "a mate under an active liveness lock should be skipped, not probed"
  [ ! -s "$log" ] || fail "a locked mate must never be killed or respawned: $(cat "$log")"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "sweep: a mate mid-episode under the shared liveness lock is skipped entirely"
}

test_relaunch_waits_for_other_mates_relaunch_lock() {
  local w fb tmuxfb log out holder i=0 lock
  w=$(new_world sweep-relaunch-lock-held)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  lock="$w/home/state/.secondmate-relaunch.lock"

  ( STATE="$w/home/state" bash -c \
      '. "$1" && fm_lock_try_acquire "$2" && trap '\''fm_lock_release "$2"'\'' EXIT && sleep 5' \
      _ "$ROOT/bin/fm-wake-lib.sh" "$lock" ) &
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$lock" ] || fail "the fixture never acquired the per-home relaunch lock"

  out=$(PATH="$tmuxfb:$fb:$BASE_PATH" FM_HOME="$w/home" FM_BACKEND=tmux \
    FM_ROOT="$ROOT" FM_TEST_PANE_CMD=zsh FM_TMUX_CALL_LOG="$log" \
    STATE="$w/home/state" bash -c '
      . "$1/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$2" sm1 poll
      rc=0
      fm_secondmate_liveness_relaunch "$2" sm1 1 || rc=$?
      printf "rc=%s status=%s reason=%s\n" "$rc" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    ' _ "$ROOT" "$w/home/state/sm1.meta")
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true

  assert_contains "$out" "rc=1 status=skipped" \
    "a relaunch blocked on another mate must return a skipped failure"
  assert_contains "$out" "another secondmate relaunch still owns the per-home relaunch lock after 1s" \
    "a liveness relaunch must bound its lock wait by the spawn timeout"
  [ ! -e "$w/home/state/.secondmate-relaunch-sm1" ] \
    || fail "a relaunch blocked on another mate was counted as an attempt"
  [ ! -s "$log" ] || fail "a blocked relaunch touched the endpoint: $(cat "$log")"
  pass "relaunch: the spawn timeout bounds the lock wait before touching the endpoint"
}

test_sweep_refuses_relaunch_on_ledger_errors() {
  local w fb tmuxfb log out mode ledger word
  if [ "$(id -u)" -eq 0 ]; then
    pass "sweep: ledger permission errors skipped (root ignores file modes)"
    return 0
  fi
  for mode in 200 444; do
    case "$mode" in 200) word=unreadable ;; *) word=unwritable ;; esac
    w=$(new_world "sweep-ledger-$mode")
    add_sm_home "$w" sm1 firstmate:fm-sm1
    fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
    log="$w/calls.log"; : > "$log"
    ledger="$w/home/state/.secondmate-relaunch-sm1"
    : > "$ledger"
    chmod "$mode" "$ledger"

    out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
    chmod 644 "$ledger"

    assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: relaunch ledger $ledger is $word" \
      "a mode-$mode relaunch ledger should skip the relaunch with its reason"
    [ ! -s "$log" ] || fail "a mode-$mode relaunch ledger still killed or spawned: $(cat "$log")"
    [ ! -s "$ledger" ] || fail "a mode-$mode ledger gained rows: $(cat "$ledger")"
  done
  pass "sweep: an unreadable or unwritable relaunch ledger refuses to kill or spawn"
}

test_sweep_leaves_alive_secondmate_untouched() {
  local w fb tmuxfb log out
  w=$(new_world sweep-alive)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: already-live" \
    "an already-live secondmate should be handled silently"
  [ ! -s "$log" ] || fail "an already-live secondmate must never be killed or respawned: $(cat "$log")"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log" FM_BOOTSTRAP_VERBOSE_FACTS=1)
  assert_contains "$out" "BOOTSTRAP_INFO: secondmate sm1 already live (backend=tmux)" \
    "verbose diagnostics should identify the already-live outcome"
  [ ! -s "$log" ] || fail "verbose reporting must not touch an already-live secondmate: $(cat "$log")"
  pass "sweep: an already-live secondmate is untouched and distinguishable in verbose diagnostics"
}

test_sweep_respawns_authoritatively_missing_pi_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" "a successful missing-window recovery should stay silent by default"
  assert_contains "$(cat "$log")" "new-window" "an authoritatively missing Pi secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" "an absent window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing Pi secondmate window is relaunched"
}

test_sweep_respawns_authoritatively_missing_pi_signed_secondmate() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-pi-signed)
  printf '%s\n' pi-signed > "$w/home/config/secondmate-harness"
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi-signed
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log")

  assert_not_contains "$out" "unverified for recovery" \
    "a recorded pi-signed secondmate should be verified for recovery"
  assert_contains "$(cat "$log")" "new-window" \
    "an authoritatively missing pi-signed secondmate should be relaunched"
  assert_not_contains "$(cat "$log")" "kill-window" \
    "an absent pi-signed window should not need a destructive pre-kill"
  pass "sweep: an authoritatively missing pi-signed secondmate window is relaunched"
}

test_sweep_never_acts_on_ambiguous_existing_process() {
  local w fb tmuxfb log out
  w=$(new_world sweep-ambiguous)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" node "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: existing endpoint has ambiguous agent process" \
    "an existing Pi-shaped node process should be reported as ambiguous"
  [ ! -s "$log" ] || fail "an ambiguous existing process must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an existing ambiguous Pi process prevents duplicate recovery"
}

test_sweep_never_acts_on_transient_unreadability() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unreadable)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" unreadable "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: endpoint probe unreadable" \
    "a transiently unreadable target should be distinguished from an absent one"
  [ ! -s "$log" ] || fail "an unreadable target must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: transient target unreadability never licenses recovery"
}

test_sweep_reports_missing_endpoint_relaunch_failure() {
  local w fb tmuxfb log out
  w=$(new_world sweep-missing-failure)
  add_sm_home "$w" sm1 firstmate:fm-sm1 pi
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" missing "$log" FM_TEST_FAIL_NEW_WINDOW=1)

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: respawn failed after recorded endpoint confidently missing" \
    "a failed missing-endpoint relaunch should retain its authorizing cause"
  pass "sweep: failed relaunch diagnostics distinguish a confidently missing endpoint"
}

test_sweep_never_acts_on_unverified_harness_dead_reading() {
  local w fb tmuxfb log out
  w=$(new_world sweep-unverified-harness)
  add_sm_home "$w" sm1 firstmate:fm-sm1 custom-agent
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate sm1: skipped: recorded harness 'custom-agent' is unverified for recovery" \
    "an unverified harness should not let a dead endpoint become actionable"
  [ ! -s "$log" ] || fail "an unverified harness must never trigger kill or relaunch: $(cat "$log")"
  pass "sweep: an unverified harness blocks recovery with a concrete diagnostic"
}

test_sweep_converges_no_retouch_once_alive() {
  local w fb tmuxfb log out1 out2
  w=$(new_world sweep-idempotent)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  # Round 1: dead -> respawned silently (kill + new-window logged).
  out1=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_not_contains "$out1" "SECONDMATE_LIVENESS: secondmate sm1: respawned" "round 1 should handle the successful respawn silently"
  [ -s "$log" ] || fail "round 1 should have logged the kill+respawn window operations"

  # Round 2: the (now-respawned) secondmate is genuinely alive - a second
  # sweep must converge to a pure no-op, not respawn again.
  : > "$log"
  out2=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  assert_not_contains "$out2" "SECONDMATE_LIVENESS: secondmate sm1: already-live" "round 2 should handle the already-live secondmate silently"
  [ ! -s "$log" ] || fail "round 2 must not re-kill or re-respawn an already-live secondmate: $(cat "$log")"
  pass "sweep: idempotent by construction - a live secondmate is never re-touched on a later run"
}

test_sweep_skipped_under_detect_only() {
  local w fb tmuxfb log out
  w=$(new_world sweep-detect-only)
  add_sm_home "$w" sm1 firstmate:fm-sm1
  mkdir -p "$w/home/config"
  printf 'codex\n' > "$w/home/config/crew-harness"
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log" FM_BOOTSTRAP_DETECT_ONLY=1)

  assert_not_contains "$out" "CREW_HARNESS_OVERRIDE:" \
    "detect-only should keep routine harness facts silent"
  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "the read-only detect-only path must never run the mutating liveness sweep"
  [ ! -s "$log" ] || fail "detect-only must never touch any endpoint: $(cat "$log")"
  pass "sweep: skipped entirely under FM_BOOTSTRAP_DETECT_ONLY=1, exactly like the other mutating sweeps"
}

test_sweep_noop_with_no_secondmate_meta() {
  local w fb tmuxfb log out
  w=$(new_world sweep-no-secondmates)
  # No add_sm_home call: this state/ dir looks exactly like what a
  # secondmate's OWN home always has (secondmates never spawn secondmates),
  # proving the sweep's primary-only scoping falls out naturally.
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"

  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")

  assert_not_contains "$out" "SECONDMATE_LIVENESS:" \
    "with no kind=secondmate meta present, the sweep must print nothing"
  [ ! -s "$log" ] || fail "with no secondmate meta, no endpoint should ever be touched: $(cat "$log")"
  pass "sweep: a silent no-op with no kind=secondmate meta present (a secondmate home's own natural scoping)"
}

# --- library level: the watcher's poll-mode remote probe ---------------------
# bin/fm-secondmate-liveness-lib.sh's `poll` mode is the read-only probe the
# watcher tick runs per cadence: exactly one remote `state` call, `dead` and
# `missing` alone authorize relaunch, and transport failure (ssh exit 255) is
# never evidence of death. Full-mode remote readiness repair and route
# revalidation remain the startup sweep's own behavior, covered by the sweep
# tests above and tests/fm-remote-secondmate-lifecycle-e2e.test.sh.

# make_remote_probe_world <name>: a parent home carrying one remote-route
# secondmate meta plus a fake ssh that logs every call and answers with
# FM_FAKE_REMOTE_REPLY on FM_FAKE_REMOTE_RC.
make_remote_probe_world() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FM_FAKE_SSH_LOG:?}"
if [ -n "${FM_FAKE_REMOTE_SLEEP:-}" ]; then
  sleep "$FM_FAKE_REMOTE_SLEEP"
fi
[ -z "${FM_FAKE_REMOTE_REPLY:-}" ] || printf '%s\n' "$FM_FAKE_REMOTE_REPLY"
exit "${FM_FAKE_REMOTE_RC:-0}"
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

# probe_remote <w> <mode> [env...] -> "<status>|<state>|<kill>|<cause>|<where>|<reason>"
probe_remote() {
  local w=$1 mode=$2; shift 2
  # shellcheck disable=SC2016 # positional params expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" "$@" \
    bash -c '
      . "$0/bin/fm-secondmate-liveness-lib.sh"
      fm_secondmate_liveness_probe "$1" rsm1 "$2"
      printf "%s|%s|%s|%s|%s|%s\n" \
        "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL" \
        "$FM_SM_LIVE_CAUSE" "$FM_SM_LIVE_WHERE" "$FM_SM_LIVE_REASON"
    ' "$ROOT" "$w/home/state/rsm1.meta" "$mode"
}

test_remote_poll_probe_maps_states() {
  local w out
  w=$(make_remote_probe_world probe-states)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=dead)
  [ "$out" = 'relaunchable|dead|0|remote endpoint dead on its configured host|host=lab-host|' ] \
    || fail "a dead remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=missing)
  [ "$out" = 'relaunchable|missing|0|remote endpoint missing on its configured host|host=lab-host|' ] \
    || fail "a missing remote reply should authorize relaunch on its own host, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=alive)
  [ "$out" = 'alive|alive|0|||' ] || fail "an alive remote reply should be a quiet no-op, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=ambiguous)
  [ "$out" = 'skipped|ambiguous|0|||remote endpoint state is ambiguous on lab-host' ] \
    || fail "an ambiguous remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=unverified)
  [ "$out" = 'skipped|unverified|0|||remote endpoint state is unverified on lab-host' ] \
    || fail "an unverified remote reply must preserve the endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_REPLY=bogus)
  [ "$out" = 'skipped|bogus|0|||remote endpoint returned an invalid state' ] \
    || fail "an invalid remote reply must preserve the endpoint, got: $out"

  [ "$(wc -l < "$w/ssh.log" | tr -d ' ')" -eq 6 ] \
    || fail "each poll-mode probe should spend exactly one remote state call: $(cat "$w/ssh.log")"
  pass "poll probe: remote states map to the same contract as local, one call each"
}

test_remote_poll_probe_unreachable_preserves_route() {
  local w out
  w=$(make_remote_probe_world probe-unreachable)

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "ssh exit 255 must never read as a dead endpoint, got: $out"

  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_RC=1)
  [ "$out" = 'skipped|unknown|0|||remote endpoint probe unreadable on lab-host' ] \
    || fail "a non-transport remote probe failure must stay inconclusive, got: $out"
  pass "poll probe: unreachable or inconclusive remote reads preserve the route"
}

parked_remote() {
  local w=$1; shift
  # shellcheck disable=SC2016 # STATE and positional parameters expand in the child shell.
  env STATE="$w/home/state" FM_HOME="$w/home" FM_DATA_OVERRIDE="$w/home/data" \
    FM_SSH_BIN="$w/fakebin/ssh" FM_FAKE_SSH_LOG="$w/ssh.log" "$@" \
    bash -c '. "$0/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_parked "$STATE" rsm1' "$ROOT"
}

test_remote_parked_requires_positive_agent_absence() {
  local w reply rc before
  w=$(make_remote_probe_world parked-remote)
  printf '123\tdead\n' > "$w/home/state/.secondmate-relaunch-bound-rsm1"
  printf '123\tattempt\n' > "$w/home/state/.secondmate-relaunch-rsm1"
  before=$(cat "$w/home/state/.secondmate-relaunch-rsm1")
  for reply in dead missing; do
    parked_remote "$w" FM_FAKE_REMOTE_REPLY="$reply" \
      || fail "a valid park record and positive $reply probe must allow skipping"
  done
  for reply in alive ambiguous unreadable unverified bogus ''; do
    if parked_remote "$w" FM_FAKE_REMOTE_REPLY="$reply"; then
      fail "a $reply probe must retain the reread even with a park record"
    fi
  done
  for rc in 1 255; do
    if parked_remote "$w" FM_FAKE_REMOTE_REPLY=dead FM_FAKE_REMOTE_RC="$rc"; then
      fail "failed transport $rc must not authorize skipping, even if it printed dead"
    fi
  done
  cp "$w/home/state/rsm1.meta" "$w/valid.meta"
  printf 'remote_host=other-host\n' >> "$w/home/state/rsm1.meta"
  if parked_remote "$w" FM_FAKE_REMOTE_REPLY=dead; then
    fail "duplicate remote identity must not authorize skipping"
  fi
  cp "$w/valid.meta" "$w/home/state/rsm1.meta"
  sed '/^remote_host=/d' "$w/valid.meta" > "$w/home/state/rsm1.meta"
  if parked_remote "$w" FM_FAKE_REMOTE_REPLY=dead; then
    fail "missing remote identity must not fall through to local marker semantics"
  fi
  rm "$w/home/state/rsm1.meta"
  ln -s "$w/valid.meta" "$w/home/state/rsm1.meta"
  if parked_remote "$w" FM_FAKE_REMOTE_REPLY=dead; then
    fail "unowned metadata must not authorize skipping"
  fi
  [ "$(cat "$w/home/state/.secondmate-relaunch-bound-rsm1")" = $'123\tdead' ] \
    || fail "read-only parked classification changed the bound record"
  [ "$(cat "$w/home/state/.secondmate-relaunch-rsm1")" = "$before" ] \
    || fail "read-only parked classification changed the recovery budget"
  pass "remote parked skips require positive absence; live or uncertain agents retain notices"
}

parked_local() {
  local state=$1; shift
  # shellcheck disable=SC2016 # STATE and positional parameters expand in the child shell.
  env STATE="$state" FM_HOME="${state%/state}" "$@" \
    bash -c '. "$0/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_parked "$STATE" sm' "$ROOT"
}

test_local_parked_requires_positive_agent_absence() {
  local state="$TMP_ROOT/parked-local/state" fb command inventory verdict harness backend
  mkdir -p "$state"
  printf '123\tdead\n' > "$state/.secondmate-relaunch-bound-sm"
  printf '123\tattempt\n' > "$state/.secondmate-relaunch-sm"
  fm_write_secondmate_meta "$state/sm.meta" "${state%/state}/sm" sess:win alpha codex
  for command in codex bash node; do
    fb=$(make_probe_tmux "$TMP_ROOT/parked-tmux-$command" "$command")
    verdict=send
    if parked_local "$state" PATH="$fb:$BASE_PATH"; then verdict=skip; fi
    case "$command:$verdict" in
      bash:skip|codex:send|node:send) ;;
      *) fail "local park marker with foreground $command unexpectedly chose $verdict" ;;
    esac
  done
  for inventory in missing unreadable; do
    fb=$(make_failed_probe_tmux "$TMP_ROOT/parked-tmux-$inventory" "$inventory")
    verdict=send
    if parked_local "$state" PATH="$fb:$BASE_PATH"; then verdict=skip; fi
    case "$inventory:$verdict" in
      missing:skip|unreadable:send) ;;
      *) fail "local park marker with $inventory inventory unexpectedly chose $verdict" ;;
    esac
  done
  fb=$(make_probe_tmux "$TMP_ROOT/parked-tmux-unverified" bash)
  for harness in cursor unknown ''; do
    fm_write_secondmate_meta "$state/sm.meta" "${state%/state}/sm" sess:win alpha codex
    printf 'harness=%s\n' "$harness" >> "$state/sm.meta"
    if parked_local "$state" PATH="$fb:$BASE_PATH"; then
      fail "an unverified local recovery harness must not authorize a skip"
    fi
  done
  for backend in zellij unknown; do
    fm_write_secondmate_meta "$state/sm.meta" "${state%/state}/sm" sess:win alpha codex
    printf 'backend=%s\n' "$backend" >> "$state/sm.meta"
    if parked_local "$state" PATH="$fb:$BASE_PATH"; then
      fail "unverified $backend backend must retain the notice"
    fi
  done
  fm_write_secondmate_meta "$state/sm.meta" "${state%/state}/sm" invalid-target alpha codex
  if parked_local "$state" PATH="$fb:$BASE_PATH"; then
    fail "an unreadable local endpoint must retain the notice"
  fi
  fb=$(fm_fakebin "$TMP_ROOT/parked-herdr")
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  'pane get')
    case "$FM_TEST_HERDR_STATE" in
      missing) printf '{"error":{"code":"pane_not_found"}}\n' ;;
      unreadable|stopped) printf '{}\n' ;;
      *) printf '{"result":{"pane":{"pane_id":"w1:p1"}}}\n' ;;
    esac
    ;;
  'agent get')
    case "$FM_TEST_HERDR_STATE" in
      dead) printf '{"error":{"code":"agent_not_found"}}\n' ;;
      alive) printf '{"result":{"agent":{"agent_status":"idle"}}}\n' ;;
    esac
    ;;
  'pane process-info')
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":200,"foreground_processes":[{"pid":201,"name":"codex","argv":["codex"]}]}}}\n'
    ;;
  'status --json')
    case "$FM_TEST_HERDR_STATE" in
      stopped) printf '{"server":{"running":false}}\n' ;;
      *) printf '{"server":{"running":true}}\n' ;;
    esac
    ;;
  *) exit 99 ;;
esac
SH
  chmod +x "$fb/herdr"
  fm_write_secondmate_meta "$state/sm.meta" "${state%/state}/sm" sess:w1:p1 alpha codex
  printf 'backend=herdr\n' >> "$state/sm.meta"
  for command in alive dead missing unreadable stopped; do
    verdict=send
    if parked_local "$state" PATH="$fb:$BASE_PATH" FM_TEST_HERDR_STATE="$command"; then verdict=skip; fi
    case "$command:$verdict" in
      alive:send|unreadable:send|dead:skip|missing:skip|stopped:skip) ;;
      *) fail "Herdr park marker with $command protocol state unexpectedly chose $verdict" ;;
    esac
  done
  [ "$(cat "$state/.secondmate-relaunch-bound-sm")" = $'123\tdead' ] \
    || fail "local read-only classification changed the bound record"
  [ "$(cat "$state/.secondmate-relaunch-sm")" = $'123\tattempt' ] \
    || fail "local read-only classification changed the recovery budget"
  pass "local parked skips require positive tmux or Herdr absence; live and uncertain endpoints send"
}

test_rearm_only_resets_a_parked_mate() {
  local state="$TMP_ROOT/rearm-state"
  mkdir -p "$state"
  (
    STATE="$state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    now=$(date +%s)
    printf '%s\tattempt\n%s\tattempt\n%s\tattempt\n' "$now" "$now" "$now" > "$STATE/.secondmate-relaunch-sm"
    fm_secondmate_liveness_rearm sm || fail "ordinary rearm failed"
    [ "$(fm_secondmate_liveness_recent_attempts sm 3600)" = 3 ] \
      || fail "an ordinary launch erased its attempt budget"
    printf '%s\tdead\n' "$now" > "$STATE/.secondmate-relaunch-bound-sm"
    fm_secondmate_liveness_rearm sm || fail "parked rearm failed"
    assert_absent "$STATE/.secondmate-relaunch-bound-sm" "rearm left the park record"
    [ "$(fm_secondmate_liveness_recent_attempts sm 3600)" = 0 ] \
      || fail "rearm did not restore the parked mate's full budget"
    fm_secondmate_liveness_ledger_add sm attempt || fail "could not record the next crash"
    fm_secondmate_liveness_rearm sm || fail "repeated rearm failed"
    [ "$(fm_secondmate_liveness_recent_attempts sm 3600)" = 1 ] \
      || fail "repeated rearm reset an ordinary attempt"
    [ "$(awk -F '\t' '$2 == "rearmed" { n++ } END { print n + 0 }' "$STATE/.secondmate-relaunch-sm")" = 1 ] \
      || fail "rearm was ledgered more than once"
    mkdir "$STATE/.secondmate-relaunch-blocked"
    printf '%s\tdead\n' "$now" > "$STATE/.secondmate-relaunch-bound-blocked"
    if fm_secondmate_liveness_rearm blocked 2>/dev/null; then
      fail "an unwritable ledger was accepted"
    fi
    assert_present "$STATE/.secondmate-relaunch-bound-blocked" "ledger failure cleared the park record"
  ) || fail "park-to-live recovery state regression"
  pass "park-to-live rearming restores the budget once and retains failed recovery state"
}

test_remote_poll_probe_timeout_preserves_route() {
  local w out started elapsed
  w=$(make_remote_probe_world probe-timeout)
  started=$(date +%s)
  out=$(probe_remote "$w" poll FM_FAKE_REMOTE_SLEEP=60)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -ge 25 ] && [ "$elapsed" -lt 45 ] \
    || fail "a hung remote state probe was not bounded, elapsed ${elapsed}s: $out"
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "a timed-out remote state probe must preserve the route, got: $out"
  pass "poll probe: a remote state hop that exceeds its bound preserves the route"
}

# make_remote_probe_world_rex <name>: the same remote probe world on a rex
# route, whose fake ssh answers the doctor, the state verb, and the route verb
# separately so a full-mode probe exercises readiness plus the route re-check.
make_remote_probe_world_rex() {
  local name=$1 w fakebin
  w="$TMP_ROOT/$name"
  fakebin=$(fm_fakebin "$w")
  mkdir -p "$w/home/state" "$w/home/data" "$w/home/config"
  cat > "$w/home/state/rsm1.meta" <<EOF
window=remote:rsm1
kind=secondmate
harness=claude
remote_host=lab-host
remote_backend=rex
remote_rex_session_id=session:00000001-0000-7000-8000-000000000002
remote_rex_server=unix:///remote/rex.sock
remote_target=00000001-0000-7000-8000-000000000002:00000003-0000-7000-8000-000000000004
home=/remote/rsm1-home
EOF
  cat > "$w/home/data/secondmates.md" <<EOF
- rsm1 - Remote mate (host: lab-host; root: /remote/root; home: /remote/rsm1-home; scope: remote work; projects: alpha; added 2026-01-01)
EOF
  cat > "$fakebin/ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = lab-host ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..2]);
' "$argv_b64")
IFS=$'\t' read -r command_name _command_action command_rel <<EOF
$command_fields
EOF
printf '%s %s %s\n' "$command_name" "$_command_action" "$command_rel" >> "${FM_FAKE_SSH_LOG:?}"
case "$command_name:$_command_action" in
  fm-remote-doctor.sh:*)
    [ -z "${FM_FAKE_DOCTOR_OUT:-}" ] || printf '%s\n' "$FM_FAKE_DOCTOR_OUT"
    exit "${FM_FAKE_DOCTOR_RC:-0}"
    ;;
  fm-remote-secondmate-control.sh:route)
    [ "${FM_FAKE_REMOTE_RC:-0}" -eq 0 ] || exit "$FM_FAKE_REMOTE_RC"
    printf 'schema=fm-remote-secondmate-control.v1\n'
    printf 'backend=%s\n' "${FM_FAKE_ROUTE_BACKEND:-rex}"
    printf 'target=%s\n' "${FM_FAKE_ROUTE_TARGET:-00000001-0000-7000-8000-000000000002:00000003-0000-7000-8000-000000000004}"
    printf 'rex_session_id=session:00000001-0000-7000-8000-000000000002\n'
    printf 'rex_server=unix:///remote/rex.sock\n'
    printf 'harness=claude\n'
    exit 0
    ;;
  fm-remote-secondmate-control.sh:state)
    printf '%s\n' "${FM_FAKE_REMOTE_REPLY:-alive}"
    exit "${FM_FAKE_REMOTE_RC:-0}"
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/ssh"
  printf '%s\n' "$w"
}

test_remote_full_probe_rex_route() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex)

  # A green readiness gate, an alive rex endpoint, and a matching route keep
  # the recorded rex backend live.
  out=$(probe_remote "$w" full)
  [ "$out" = 'alive|alive|0|||' ] || fail "a live rex route should stay a quiet no-op, got: $out"
  grep -q -- '--backend rex' "$w/ssh.log" \
    || fail "the readiness gate did not ask the remote doctor about rex: $(cat "$w/ssh.log")"
  pass "full probe: a live rex route stays alive through the rex readiness gate"
}

test_remote_full_probe_rex_backend_drift() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex-drift)

  # The remote reports a different backend than this home recorded: a skip,
  # never a silent migration.
  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=herdr)
  [ "$out" = "skipped|alive|0|||alive remote endpoint runs on backend 'herdr', but this home recorded 'rex'; migrate or retire it explicitly" ] \
    || fail "a herdr route under a rex record must be reported, got: $out"

  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=tmux)
  [ "$out" = "skipped|alive|0|||alive remote endpoint is recorded on backend 'tmux'; migrate or retire it explicitly" ] \
    || fail "an unsupported remote backend must be reported, got: $out"
  pass "full probe: remote backend drift is reported, never migrated"
}

test_remote_full_probe_rex_readiness_verdicts() {
  local w out
  w=$(make_remote_probe_world_rex probe-rex-readiness)

  out=$(probe_remote "$w" full FM_FAKE_DOCTOR_RC=1 \
    FM_FAKE_DOCTOR_OUT='check rex-server=fixable: no persistent rex server answers')
  case "$out" in
    'skipped|unknown|0|||remote readiness failed on lab-host: check rex-server=fixable:'*) : ;;
    *) fail "a rex readiness gap must be reported, got: $out" ;;
  esac

  out=$(probe_remote "$w" full FM_FAKE_DOCTOR_RC=255)
  [ "$out" = 'skipped|unknown|0|||remote host unavailable or endpoint state unknown; route preserved on lab-host' ] \
    || fail "an unreachable rex readiness probe must preserve the route, got: $out"
  pass "full probe: rex readiness gaps and unreachable hosts stay explicit"
}

test_remote_full_probe_legacy_record_defaults_herdr() {
  local w out
  w=$(make_remote_probe_world_rex probe-legacy)

  # A record written before rex existed carries no remote_backend; it is a
  # herdr route, so the gate asks the doctor about herdr and a herdr route
  # reply keeps it alive.
  sed -i.bak '/^remote_backend=/d;/^remote_rex_/d' "$w/home/state/rsm1.meta"
  rm -f "$w/home/state/rsm1.meta.bak"
  printf 'remote_herdr_session=fm-remote\nremote_target=fm-remote:w1:p1\n' >> "$w/home/state/rsm1.meta"
  out=$(probe_remote "$w" full FM_FAKE_ROUTE_BACKEND=herdr)
  [ "$out" = 'alive|alive|0|||' ] || fail "a legacy route should stay alive on herdr, got: $out"
  grep -q -- '--backend herdr' "$w/ssh.log" \
    || fail "a legacy record did not ask the remote doctor about herdr: $(cat "$w/ssh.log")"
  pass "full probe: a record without remote_backend stays a herdr route"
}

# register_fixture_mate <registry> <id> <home>: one local registry line the
# park command accepts. The home path is not required to exist.
register_fixture_mate() {
  mkdir -p "$(dirname "$1")"
  printf -- '- %s - Fixture mate (home: %s; scope: fixture; projects: none; added 2026-11-03)\n' \
    "$2" "$3" >> "$1"
}

# park_in <home> <args...>: the public park command against one fixture home.
park_in() {
  local home=$1
  shift
  env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    FM_HOME="$home" "$ROOT/bin/fm-secondmate-park.sh" "$@"
}

test_owner_park_command_contract() {
  local w out rc file dir rel file_mode dir_mode park_day record
  w=$(new_world owner-park-contract)
  park_day=$(date -u +%Y-%m-%d)
  mkdir -p "$w/home/data"

  rc=0
  out=$(env -u FM_HOME "$ROOT/bin/fm-secondmate-park.sh" --help 2>&1) || rc=$?
  expect_code 0 "$rc" "park help must work without FM_HOME"$'\n'"$out"
  assert_contains "$out" "fm-secondmate-park.sh park" "help should name the park verb"

  rc=0
  out=$(park_in "$w/home" park eel-web 2>&1) || rc=$?
  expect_code 1 "$rc" "park must refuse an id this home does not register"$'\n'"$out"
  assert_contains "$out" "not registered" "the refusal must name the missing registry line"
  assert_absent "$w/home/config/secondmate-parked/eel-web" "a refused park must not write a record"

  register_fixture_mate "$w/home/data/secondmates.md" eel-web "$w/eel-web"

  rc=0
  out=$(park_in "$w/home" park eel-web --date 2000-01-01 2>&1) || rc=$?
  expect_code 2 "$rc" "park must reject a caller-selected date"$'\n'"$out"
  assert_contains "$out" "unexpected argument '--date'" "the refusal must name the unsupported option"
  assert_absent "$w/home/config/secondmate-parked/eel-web" "an unsupported option must not write a record"

  rc=0
  out=$(park_in "$w/home" park eel-web 2>&1) || rc=$?
  expect_code 0 "$rc" "park should write the owner record"$'\n'"$out"
  assert_contains "$out" "parked: eel-web: owner $park_day" "park should report the id and date"
  file="$w/home/config/secondmate-parked/eel-web"
  dir="$w/home/config/secondmate-parked"
  [ "$(cat "$file")" = "owner $park_day" ] || fail "the record must be one owner date line, got: $(cat "$file")"
  if [ "$(id -u)" != 0 ]; then
    file_mode=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")
    dir_mode=$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir")
    [ "$file_mode" = 600 ] || fail "the park record mode must be 0600, got $file_mode"
    [ "$dir_mode" = 700 ] || fail "the park directory mode must be 0700, got $dir_mode"
  fi

  printf 'owner 2000-01-01\n' > "$file"
  rc=0
  out=$(park_in "$w/home" park eel-web 2>&1) || rc=$?
  expect_code 0 "$rc" "parking again should rewrite the date"$'\n'"$out"
  [ "$(cat "$file")" = "owner $park_day" ] || fail "re-park did not rewrite the date: $(cat "$file")"

  rc=0
  out=$(park_in "$w/home" status eel-web 2>&1) || rc=$?
  expect_code 0 "$rc" "status of a parked mate should exit 0"$'\n'"$out"
  assert_contains "$out" "owner park since $park_day; relaunch refused until bin/fm-secondmate-park.sh unpark eel-web" \
    "status should print the shared refusal"

  for record in 'owner 2026-02-31' $'owner 2026-11-03\nextra'; do
    printf '%s\n' "$record" > "$file"
    rc=0
    out=$(park_in "$w/home" status eel-web 2>&1) || rc=$?
    expect_code 2 "$rc" "an invalid persisted record must be unsafe"$'\n'"$out"
    assert_contains "$out" "not a single owner YYYY-MM-DD line" "the unsafe reason must name the record shape"
  done

  rm -f "$file"
  ln -s "$w/home/data/secondmates.md" "$file"
  rc=0
  out=$(park_in "$w/home" status eel-web 2>&1) || rc=$?
  expect_code 2 "$rc" "a symlink record must be unsafe"$'\n'"$out"
  assert_contains "$out" "unpark will not remove a symlink" \
    "a symlink refusal must say unpark leaves the link in place"

  rel=$(
    unset FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE
    STATE="$w/home/state"
    # shellcheck disable=SC2030 # This fixture home must stay inside the command substitution.
    export FM_HOME="$w/home"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    if fm_secondmate_liveness_relaunch "$STATE/eel-web.meta" eel-web; then
      printf 'relaunched\n'
    else
      printf '%s\n%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    fi
  )
  assert_contains "$rel" "owner-parked" "a symlink record must refuse relaunch"$'\n'"$rel"
  assert_contains "$rel" "is a symlink" "the relaunch refusal must name the symlink"$'\n'"$rel"
  assert_absent "$w/home/state/.secondmate-relaunch-eel-web" \
    "a refused relaunch must not ledger an attempt"

  rc=0
  out=$(park_in "$w/home" unpark eel-web 2>&1) || rc=$?
  expect_code 2 "$rc" "unpark must refuse a symlink"$'\n'"$out"
  assert_contains "$out" "refuses to follow or remove" "unpark must say it will not remove the symlink"
  [ -L "$file" ] || fail "unpark removed the symlink it was required to leave"

  rc=0
  out=$(park_in "$w/home" park eel-web 2>&1) || rc=$?
  expect_code 2 "$rc" "park must refuse to replace a symlink"$'\n'"$out"
  assert_contains "$out" "refuses to replace" "park must name the symlink it will not replace"
  [ -L "$file" ] || fail "park replaced the symlink it was required to leave"
  rm -f "$file"
  rmdir "$dir" || fail "the park directory should be empty once the symlink is removed"

  rc=0
  out=$(park_in "$w/home" unpark eel-web 2>&1) || rc=$?
  expect_code 0 "$rc" "unpark of an absent record should succeed"$'\n'"$out"
  assert_contains "$out" "unparked: eel-web: already clear" "an absent record should say it is already clear"
  rc=0
  out=$(park_in "$w/home" status eel-web 2>&1) || rc=$?
  expect_code 1 "$rc" "status with no record should exit 1"$'\n'"$out"
  assert_contains "$out" "not parked: eel-web" "status should say the mate is not parked"
  assert_absent "$dir" "status must not create the park directory"
  rc=0
  out=$(park_in "$w/home" unpark eel-web 2>&1) || rc=$?
  expect_code 0 "$rc" "unpark should stay idempotent"$'\n'"$out"
  assert_contains "$out" "already clear" "a repeated unpark should say the record is already clear"

  rel=$(
    STATE="$w/home/state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    # Backend sourcing fills FM_HOME from the checkout when it is empty.
    # The refusal is the relaunch call with both names cleared after that.
    unset FM_HOME FM_CONFIG_OVERRIDE
    if fm_secondmate_liveness_relaunch "$STATE/eel-web.meta" eel-web; then
      printf 'relaunched\n'
    else
      printf '%s\n%s\n' "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
    fi
  )
  assert_contains "$rel" "owner-parked" "relaunch with no home and no config override must refuse"$'\n'"$rel"
  assert_contains "$rel" "neither FM_CONFIG_OVERRIDE nor FM_HOME is set" \
    "the refusal must name the missing home"$'\n'"$rel"
  pass "owner park: the record contract, unsafe records, and a missing home all refuse relaunch"
}

test_owner_park_waits_for_launch_transactions() {
  local w name lock holder parker i rc
  for name in .secondmate-relaunch.lock .control-eel-web.lock .spawn-eel-web.lock .remote-inherit-eel-web.lock; do
    w=$(new_world "owner-park-lock-$name")
    register_fixture_mate "$w/home/data/secondmates.md" eel-web "$w/eel-web"
    lock="$w/home/state/$name"
    STATE="$w/home/state" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_acquire_wait "$2" || exit 1
      trap '\''fm_lock_release "$2"'\'' EXIT
      touch "$3/ready"
      while [ ! -f "$3/release" ]; do sleep 0.05; done
    ' _ "$ROOT" "$lock" "$w" &
    holder=$!
    i=0
    while [ ! -f "$w/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$w/ready" ] || fail "launch transaction never acquired $name"
    ( park_in "$w/home" park eel-web > "$w/park.out" 2>&1; printf '%s\n' "$?" > "$w/park.rc" ) &
    parker=$!
    sleep 0.3
    [ ! -e "$w/park.rc" ] || fail "park completed during $name: $(cat "$w/park.out")"
    assert_absent "$w/home/config/secondmate-parked/eel-web" "park must wait for $name before publishing"
    touch "$w/release"
    wait "$holder" || fail "launch transaction failed for $name"
    wait "$parker" || fail "park worker failed for $name"
    rc=$(cat "$w/park.rc")
    expect_code 0 "$rc" "park must succeed after $name releases: $(cat "$w/park.out")"
    park_in "$w/home" status eel-web >/dev/null || fail "park record missing after $name released"
    for lock in .secondmate-relaunch.lock .control-eel-web.lock .spawn-eel-web.lock .remote-inherit-eel-web.lock; do
      assert_absent "$w/home/state/$lock" "park left $lock held"
    done
  done
  pass "owner park: publication waits for liveness, control, spawn, and remote launch transactions"
}

test_owner_park_queued_launches_recheck_after_wait() {
  local w mode lock launcher i rc script
  for mode in respawn resume remote; do
    w=$(new_world "owner-park-queued-$mode")
    add_sm_home "$w" eel-web firstmate:fm-eel-web
    register_fixture_mate "$w/home/data/secondmates.md" eel-web "$w/eel-web"
    mkdir -p "$w/root/bin"
    for script in "$ROOT/bin/"*.sh; do
      ln -s "$script" "$w/root/bin/${script##*/}"
    done
    rm "$w/root/bin/fm-wake-lib.sh"
    cp "$ROOT/bin/fm-wake-lib.sh" "$w/root/bin/fm-wake-lib.sh"
    cat >> "$w/root/bin/fm-wake-lib.sh" <<'SH'
eval "$(declare -f fm_lock_acquire_wait | sed '1s/fm_lock_acquire_wait/fm_test_acquire_wait/')"
fm_lock_acquire_wait() {
  if [ "$1" = "$FM_TEST_WAIT_LOCK" ]; then
    touch "$FM_TEST_WAIT_DIR/ready"
    while [ ! -f "$FM_TEST_WAIT_DIR/release" ]; do sleep 0.05; done
  fi
  fm_test_acquire_wait "$@"
}
fm_lock_acquire_wait_bounded() { fm_lock_acquire_wait "$1"; }
SH
    lock="$w/home/state/.secondmate-relaunch.lock"
    if [ "$mode" = remote ]; then
      lock="$w/home/state/.remote-inherit-eel-web.lock"
      printf 'remote_host=lab-host\n' >> "$w/home/state/eel-web.meta"
      rm "$w/root/bin/fm-on.sh"
      # shellcheck disable=SC2016 # The generated script expands its own fixture environment.
      printf '#!/usr/bin/env bash\nprintf "host-hop\\n" >> "$FM_TEST_WAIT_DIR/launched"\nexit 99\n' > "$w/root/bin/fm-on.sh"
      chmod +x "$w/root/bin/fm-on.sh"
    else
      rm "$w/root/bin/fm-spawn.sh"
      # shellcheck disable=SC2016 # The generated script expands its own fixture environment.
      printf '#!/usr/bin/env bash\nprintf "spawn\\n" >> "$FM_TEST_WAIT_DIR/launched"\n' > "$w/root/bin/fm-spawn.sh"
      chmod +x "$w/root/bin/fm-spawn.sh"
    fi
    (
      # shellcheck disable=SC2031 # This independent fixture supplies its own home.
      export FM_HOME="$w/home" FM_ROOT_OVERRIDE="$w/root" FM_TEST_WAIT_DIR="$w" FM_TEST_WAIT_LOCK="$lock"
      if [ "$mode" = remote ]; then
        bash "$w/root/bin/fm-remote-secondmate-relaunch.sh" eel-web claude default default > "$w/launch.out" 2>&1
        printf '%s\n' "$?" > "$w/launch.rc"
      else
        STATE="$w/home/state" bash -c '
          . "$1/bin/fm-secondmate-liveness-lib.sh"
          FM_SM_LIVE_STATUS=relaunchable FM_SM_LIVE_STATE=dead FM_SM_LIVE_KILL=0 FM_SM_LIVE_RESUME=0
          [ "$2" != resume ] || FM_SM_LIVE_RESUME=1
          fm_backend_source() { return 0; }
          fm_backend_t3code_resume_failed() { printf "resume\n" >> "$FM_TEST_WAIT_DIR/launched"; }
          rc=0
          fm_secondmate_liveness_relaunch "$STATE/eel-web.meta" eel-web 10 || rc=$?
          printf "%s\n" "$rc" > "$FM_TEST_WAIT_DIR/launch.rc"
          printf "%s\n%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
        ' _ "$w/root" "$mode" > "$w/launch.out" 2>&1
      fi
    ) &
    launcher=$!
    i=0
    while [ ! -f "$w/ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$w/ready" ] || fail "$mode never reached the launch wait: $(cat "$w/launch.out")"
    park_in "$w/home" park eel-web >/dev/null || fail "could not park a mate while $mode was queued"
    touch "$w/release"
    wait "$launcher" || fail "$mode worker failed: $(cat "$w/launch.out")"
    rc=$(cat "$w/launch.rc")
    expect_code 1 "$rc" "queued $mode must refuse after park succeeds: $(cat "$w/launch.out")"
    assert_contains "$(cat "$w/launch.out")" "owner park" "queued $mode must report the park"
    assert_absent "$w/launched" "queued $mode must not launch after park succeeds"
    assert_absent "$w/home/state/.secondmate-relaunch-eel-web" "queued $mode must not ledger an attempt"
    assert_absent "$lock" "queued $mode left its launch lock held"
  done
  pass "owner park: queued respawn, T3 resume, and remote relaunch refuse a park published during their wait"
}

test_owner_park_remote_completion_and_late_requests() (
  local w remote file out rc holder parker launcher name lock i mode perm
  w=$(new_world owner-park-remote-completion)
  remote="$w/remote-home"
  file="$remote/config/secondmate-parked/eel-web"
  mkdir -p "$w/home/data" "$remote/config" "$remote/bin" "$remote/state/parent-route"
  printf 'eel-web\n' > "$remote/.fm-secondmate-home"
  printf '# Fixture home\n' > "$remote/AGENTS.md"
  printf -- '- eel-web - Fixture (host: lab-host; root: %s; home: %s; scope: fixture; projects: none; added 2026-11-03)\n' \
    "$ROOT" "$remote" > "$w/home/data/secondmates.md"
  cat > "$w/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
shift 2
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done < <(
  printf '%s' "$4" | base64 --decode 2>/dev/null || printf '%s' "$4" | base64 -D
)
[ "${args[0]}" = fm-remote-inherit.sh ] || exit 91
printf '%s\0' "${args[@]}" > "$FM_TEST_REMOTE_DIR/request.argv"
cat > "$FM_TEST_REMOTE_DIR/request.payload"
touch "$FM_TEST_REMOTE_DIR/request.entered"
case "${FM_TEST_REMOTE_MODE:-ok}" in
  offline) exit 255 ;;
  unconfirmed) exit 0 ;;
  delayed)
    cp "$FM_TEST_REMOTE_DIR/request.argv" "$FM_TEST_REMOTE_DIR/delayed.argv"
    cp "$FM_TEST_REMOTE_DIR/request.payload" "$FM_TEST_REMOTE_DIR/delayed.payload"
    exit 255
    ;;
esac
env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
  FM_HOME="$FM_TEST_REMOTE_DIR/remote-home" FM_ROOT_OVERRIDE="$FM_TEST_CODE_ROOT" \
  bash "$FM_TEST_CODE_ROOT/bin/${args[0]}" "${args[@]:1}" < "$FM_TEST_REMOTE_DIR/request.payload"
SH
  chmod +x "$w/fake-ssh"
  export FM_SSH_BIN="$w/fake-ssh" FM_TEST_REMOTE_DIR="$w" FM_TEST_CODE_ROOT="$ROOT"
  for mode in offline unconfirmed; do
    rc=0
    out=$(FM_TEST_REMOTE_MODE="$mode" park_in "$w/home" park eel-web 2>&1) || rc=$?
    expect_code 1 "$rc" "park must refuse success without remote publication ($mode): $out"
    assert_present "$w/home/config/secondmate-parked/eel-web" "failed remote acknowledgement must retain the local park"
    assert_not_contains "$out" "parked: eel-web:" "unconfirmed remote park must not report success"
    assert_absent "$file" "a missing remote acknowledgement must not stand in for publication"
  done

  (
    touch "$w/launch.queued"
    while [ ! -f "$w/launch.release" ]; do sleep 0.05; done
    rc=0
    FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-remote-secondmate-control.sh" \
      launch eel-web claude - - herdr > "$w/launch.out" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$w/launch.rc"
  ) &
  launcher=$!
  i=0
  while [ ! -f "$w/launch.queued" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
  [ -f "$w/launch.queued" ] || fail "the delayed remote request never entered the transport"
  for name in .control-eel-web.lock .spawn-eel-web.lock; do
    lock="$remote/state/parent-route/$name"
    rm -f "$w/holder.ready" "$w/holder.release" "$w/request.entered" "$w/park.rc"
    STATE="$remote/state/parent-route" bash -c '
      . "$1/bin/fm-wake-lib.sh"
      fm_lock_acquire_wait "$2" || exit 1
      trap '\''fm_lock_release "$2"'\'' EXIT
      touch "$3/holder.ready"
      while [ ! -f "$3/holder.release" ]; do sleep 0.05; done
    ' _ "$ROOT" "$lock" "$w" &
    holder=$!
    i=0
    while [ ! -f "$w/holder.ready" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$w/holder.ready" ] || fail "remote launch never acquired $name"
    ( park_in "$w/home" park eel-web > "$w/park.out" 2>&1; printf '%s\n' "$?" > "$w/park.rc" ) &
    parker=$!
    i=0
    while [ ! -f "$w/request.entered" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$w/request.entered" ] || fail "park never reached the remote publication: $(cat "$w/park.out")"
    sleep 0.2
    assert_absent "$w/park.rc" "park must wait for remote $name before reporting success"
    touch "$w/holder.release"
    wait "$holder" || fail "remote lock holder failed"
    wait "$parker" || fail "park worker failed"
    expect_code 0 "$(cat "$w/park.rc")" "remote park must succeed after $name completes: $(cat "$w/park.out")"
    cmp -s "$w/home/config/secondmate-parked/eel-web" "$file" || fail "acknowledged remote park differs from the primary record"
  done
  perm=$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")
  [ "$perm" = 600 ] || fail "remote owner park mode must be 0600"
  perm=$(stat -c %a "${file%/*}" 2>/dev/null || stat -f %Lp "${file%/*}")
  [ "$perm" = 700 ] || fail "remote owner park directory mode must be 0700"
  touch "$w/launch.release"
  wait "$launcher" || fail "delayed remote launch worker failed"
  expect_code 1 "$(cat "$w/launch.rc")" "a remote request delivered after park must refuse: $(cat "$w/launch.out")"
  assert_contains "$(cat "$w/launch.out")" "owner-parked" "the remote execution boundary must name the park"
  assert_absent "$remote/state/parent-route/eel-web.meta" "a late launch must not publish an endpoint"

  for mode in unpark park; do
    rc=0
    out=$(FM_TEST_REMOTE_MODE=delayed park_in "$w/home" "$mode" eel-web 2>&1) || rc=$?
    expect_code 1 "$rc" "unknown remote $mode completion must refuse success: $out"
    assert_present "$w/home/config/secondmate-parked/eel-web" "unknown $mode must leave local recovery blocked"
    if [ "$mode" = unpark ]; then
      park_in "$w/home" park eel-web >/dev/null || fail "newer remote park failed"
    else
      park_in "$w/home" unpark eel-web >/dev/null || fail "newer remote unpark failed"
    fi
    rc=0
    out=$(
      args=()
      while IFS= read -r -d '' arg; do args+=("$arg"); done < "$w/delayed.argv"
      env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
        FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/${args[0]}" "${args[@]:1}" < "$w/delayed.payload" 2>&1
    ) || rc=$?
    expect_code 1 "$rc" "a delayed older $mode must be rejected"
    assert_contains "$out" "superseded" "a stale $mode must not overwrite the newer decision"
    if [ "$mode" = unpark ]; then
      assert_present "$file" "a stale unpark cleared the newer remote park"
      park_in "$w/home" unpark eel-web >/dev/null || fail "explicit remote unpark failed"
    else
      assert_absent "$file" "a stale park restored the explicitly cleared remote park"
    fi
    assert_absent "$w/home/config/secondmate-parked/eel-web" "explicit unpark must clear the local record"
    assert_absent "$file" "explicit unpark must clear the remote record"
  done
  rc=0
  out=$(
    args=()
    while IFS= read -r -d '' arg; do args+=("$arg"); done < "$w/delayed.argv"
    args[2]=config/secondmate-parked/sibling
    env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
      FM_HOME="$remote" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/${args[0]}" "${args[@]:1}" < "$w/delayed.payload" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "a remote home must reject another mate's owner record"
  assert_contains "$out" "does not match the seeded secondmate home" "the receiver must restrict the park exception to its own identity"
  assert_absent "$remote/config/secondmate-parked/sibling" "the receiver wrote another mate's owner record"
  pass "owner park: remote acknowledgement, host launch exclusion, and stale-request rejection keep late launches stopped"
)

test_owner_park_session_start_leaves_eel_web_stopped() {
  local w fb tmuxfb log out rel park_day
  park_day=$(date -u +%Y-%m-%d)
  w=$(new_world owner-park-eel)
  add_sm_home "$w" eel-web firstmate:fm-eel-web
  add_sm_home "$w" sm1 firstmate:fm-sm1
  register_fixture_mate "$w/home/data/secondmates.md" eel-web "$w/eel-web"
  register_fixture_mate "$w/home/data/secondmates.md" sm1 "$w/sm1"
  park_in "$w/home" park eel-web >/dev/null
  fb=$(make_toolchain "$w"); tmuxfb=$(make_liveness_tmux "$w")
  log="$w/calls.log"; : > "$log"
  printf 'fm-eel-web\n' > "$log.windows"

  # A live parked mate is not killed. The companion is live too, so this pass
  # must not touch the session at all. The park record stays.
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" claude "$log")
  [ ! -s "$log" ] || fail "a live parked mate was killed or relaunched: $(cat "$log")"
  assert_not_contains "$out" "respawn failed" \
    "a live parked mate must not be reported as a failed respawn"$'\n'"$out"
  out=$(park_in "$w/home" status eel-web 2>&1) || fail "a live pass cleared the owner park: $out"
  assert_contains "$out" "owner park since $park_day" "status must still report the owner park"
  assert_absent "$w/home/state/.secondmate-relaunch-eel-web" \
    "a live parked mate must not gain a relaunch ledger"

  # Session start used to relaunch any dead or missing mate and rearm the
  # crash-loop bound. The owner park refuses that, including for eel-web,
  # while an unparked companion still relaunches.
  printf '%s\tdead\n' "$(date +%s)" > "$w/home/state/.secondmate-relaunch-bound-eel-web"
  : > "$log"
  : > "$log.windows"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_contains "$(cat "$log")" "new-window" \
    "an unparked dead companion should still be relaunched"
  assert_contains "$(cat "$log")" "fm-sm1" \
    "the companion relaunch should name sm1"
  assert_not_contains "$(cat "$log")" "fm-eel-web" \
    "a parked eel-web must not be killed or relaunched: $(cat "$log")"
  assert_contains "$out" "SECONDMATE_LIVENESS: secondmate eel-web: owner park since $park_day; relaunch refused until bin/fm-secondmate-park.sh unpark eel-web" \
    "session start must report the owner park and not relaunch"$'\n'"$out"
  assert_present "$w/home/state/.secondmate-relaunch-bound-eel-web" \
    "the session-start pass must not clear the crash-loop bound"
  if [ -e "$w/home/state/.secondmate-relaunch-eel-web" ]; then
    assert_no_grep 'attempt' "$w/home/state/.secondmate-relaunch-eel-web" \
      "a parked sweep must not ledger an attempt"
    assert_no_grep 'relaunched' "$w/home/state/.secondmate-relaunch-eel-web" \
      "a parked sweep must not ledger a relaunch"
  fi
  assert_grep 'relaunched' "$w/home/state/.secondmate-relaunch-sm1" \
    "the unparked companion should still record its relaunch"

  rel=$(
    unset FM_HOME FM_CONFIG_OVERRIDE
    STATE="$w/home/state"
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-secondmate-liveness-lib.sh"
    fm_secondmate_liveness_rearm eel-web || exit 1
    printf 'rearmed\n'
  )
  [ "$rel" = rearmed ] || fail "rearm of the crash-loop bound failed: $rel"
  assert_absent "$w/home/state/.secondmate-relaunch-bound-eel-web" \
    "rearm should still lift the crash-loop bound"
  [ "$(cat "$w/home/config/secondmate-parked/eel-web")" = "owner $park_day" ] \
    || fail "rearm cleared the owner park: $(cat "$w/home/config/secondmate-parked/eel-web")"
  assert_grep 'rearmed' "$w/home/state/.secondmate-relaunch-eel-web" \
    "rearm should ledger that it lifted the crash-loop bound"
  assert_no_grep 'attempt' "$w/home/state/.secondmate-relaunch-eel-web" \
    "rearm must not look like a relaunch attempt"
  assert_no_grep 'relaunched' "$w/home/state/.secondmate-relaunch-eel-web" \
    "rearm must not record a relaunch"

  park_in "$w/home" unpark eel-web >/dev/null
  : > "$log"
  out=$(run_bootstrap "$tmuxfb:$fb" "$w/home" zsh "$log")
  assert_contains "$(cat "$log")" "fm-eel-web" \
    "unpark must make the next session start relaunch eel-web: $(cat "$log")"
  assert_not_contains "$out" "owner park since" \
    "an unparked mate must not be reported as owner-parked"$'\n'"$out"
  rc=0
  out=$(park_in "$w/home" status eel-web 2>&1) || rc=$?
  expect_code 1 "$rc" "eel-web should stay unparked after the relaunch"$'\n'"$out"
  pass "owner park: session start leaves eel-web stopped, rearm keeps the record, and unpark restores relaunch"
}

test_owner_park_refuses_spawn_and_remote_relaunch() {
  local w out rc park_day
  park_day=$(date -u +%Y-%m-%d)
  w=$(new_world owner-park-spawn)
  mkdir -p "$w/home/data" "$w/eel-web"
  register_fixture_mate "$w/home/data/secondmates.md" eel-web "$w/eel-web"
  park_in "$w/home" park eel-web >/dev/null

  rc=0
  out=$(env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    FM_HOME="$w/home" FM_SPAWN_NO_GUARD=1 \
    timeout 30 "$ROOT/bin/fm-spawn.sh" eel-web --secondmate 2>&1) || rc=$?
  expect_code 1 "$rc" "a fresh secondmate spawn must refuse an owner park"$'\n'"$out"
  assert_contains "$out" "error: secondmate eel-web is owner-parked (owner park since $park_day; relaunch refused until bin/fm-secondmate-park.sh unpark eel-web)" \
    "spawn must name the owner park"$'\n'"$out"
  assert_absent "$w/home/state/eel-web.meta" "a refused spawn must not write endpoint metadata"

  cat > "$w/home/state/eel-web.meta" <<EOF
window=remote:eel-web
kind=secondmate
harness=claude
remote_host=lab-host
home=$w/eel-web
EOF
  rc=0
  out=$(env -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_STATE_OVERRIDE \
    FM_HOME="$w/home" \
    timeout 20 "$ROOT/bin/fm-remote-secondmate-relaunch.sh" eel-web claude default default 2>&1) || rc=$?
  expect_code 1 "$rc" "a remote relaunch must refuse an owner park before the host hop"$'\n'"$out"
  assert_contains "$out" "error: secondmate eel-web is owner-parked" \
    "the remote refusal must name the owner park"$'\n'"$out"
  pass "owner park: spawn and remote relaunch refuse before they change the endpoint"
}

test_tmux_agent_state_classifies
test_tmux_agent_state_rejects_malformed_targets_before_probe
test_herdr_agent_state_preserves_husk_classifier
test_agent_state_dispatcher_and_compatibility
test_sweep_respawns_confirmed_dead_secondmate
test_sweep_reuses_retained_secondmate_home
test_sweep_recovers_the_durable_secondmate_account
test_sweep_serializes_distinct_secondmate_relaunches
test_sweep_keeps_tmux_best_effort_kill_when_close_fails
test_sweep_leaves_alive_secondmate_untouched
test_sweep_respawns_authoritatively_missing_pi_secondmate
test_sweep_respawns_authoritatively_missing_pi_signed_secondmate
test_sweep_never_acts_on_ambiguous_existing_process
test_sweep_never_acts_on_transient_unreadability
test_sweep_reports_missing_endpoint_relaunch_failure
test_sweep_never_acts_on_unverified_harness_dead_reading
test_sweep_converges_no_retouch_once_alive
test_sweep_skipped_under_detect_only
test_sweep_noop_with_no_secondmate_meta
test_sweep_skips_mate_whose_liveness_lock_is_held
test_relaunch_waits_for_other_mates_relaunch_lock
test_sweep_refuses_relaunch_on_ledger_errors
test_remote_poll_probe_maps_states
test_remote_poll_probe_unreachable_preserves_route
test_remote_poll_probe_timeout_preserves_route

test_remote_parked_requires_positive_agent_absence
test_local_parked_requires_positive_agent_absence
test_rearm_only_resets_a_parked_mate
test_remote_full_probe_rex_route
test_remote_full_probe_rex_backend_drift
test_remote_full_probe_rex_readiness_verdicts
test_remote_full_probe_legacy_record_defaults_herdr
test_owner_park_command_contract
test_owner_park_waits_for_launch_transactions
test_owner_park_queued_launches_recheck_after_wait
test_owner_park_remote_completion_and_late_requests
test_owner_park_session_start_leaves_eel_web_stopped
test_owner_park_refuses_spawn_and_remote_relaunch

echo "# all fm-secondmate-liveness tests passed"
