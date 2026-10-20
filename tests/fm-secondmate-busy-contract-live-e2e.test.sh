#!/usr/bin/env bash
# Live guard for the secondmate busy contract (live-harness-optin family).
#
# The active-turn gate reads a busy verdict from the parent home's semantic
# record and from the tmux pane. A fake pane can only confirm the command
# this tree already built. This guard runs bin/fm-spawn.sh --secondmate
# against a private tmux server.
#
# Spawn uses a sleeper only to generate the secondmate wiring without
# delivering a fleet launch brief. The real harness then runs a bounded tool
# round trip through that wiring, including Claude's real blocking Stop guard.
# This submits prompts and requires managed authentication, so it is opt-in.
# An absent binary is reported and skipped. A run that checks nothing fails.
#
# Refresh docs/verification/runtime-backends.md ("Secondmate busy contract")
# from this guard after a harness upgrade.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_SECONDMATE_BUSY_LIVE tmux jq

# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-sm-busy-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-secondmate-busy-live.XXXXXX")
CHECKED=0
FAILED=0
SKIPPED=

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  if [ -n "${LAB:-}" ]; then
    # fm-spawn leaves each mate's per-task git hooks directory read-only.
    chmod -R u+w "$LAB" 2>/dev/null || true
    rm -rf "$LAB"
  fi
  fm_test_cleanup
}
trap cleanup_all EXIT

note() { printf '# %s\n' "$1"; }

resolve_bin() {  # <name>
  local candidate
  candidate=$(command -v "$1" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  return 1
}

install_tmux_shim() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$dir/tmux"
}

install_sleeper() {  # <dir> <name> <real-bin>
  local dir=$1 name=$2 real=$3
  mkdir -p "$dir"
  cat > "$dir/$name" <<SH
#!/usr/bin/env bash
# Spawn probes the resolved executable with --help before it builds the
# launch. Those probes must reach the real binary. The pane command is the
# launch itself, which carries the brief, and that one must not.
case "\${1:-}" in
  --help|--version|-v|-V) exec $(printf '%q' "$real") "\$@" ;;
esac
printf 'working\n'
exec sleep 300
SH
  chmod +x "$dir/$name"
}

seed_home() {  # <home> <id>
  local home=$1 id=$2
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  printf 'charter\n' > "$home/data/charter.md"
  cp -R "$ROOT/bin/." "$home/bin/"
  fm_git_init_commit "$home"
}

spawn_mate() {  # <case> <id> <harness> <sleeper-dir> <shim-dir>
  local case_dir=$1 id=$2 harness=$3 sleeper=$4 shim=$5
  local primary="$case_dir/primary" sm="$case_dir/sm" user_home="$case_dir/user-home"
  mkdir -p "$case_dir" "$user_home"
  fm_test_spawn_home "$primary" "$harness"
  seed_home "$sm" "$id"
  FM_BACKEND=tmux FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$primary" \
    HOME="$user_home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$primary/state" FM_DATA_OVERRIDE="$primary/data" \
    FM_PROJECTS_OVERRIDE="$primary/projects" FM_CONFIG_OVERRIDE="$primary/config" \
    FM_SPAWN_NO_GUARD=1 \
    env -u TMUX -u TMUX_PANE \
    PATH="$sleeper:$shim:$PATH" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$sm" "$harness" --secondmate
}

wait_for_file() {
  local path=$1 harness=$2 version=$3 case_dir=$4 i
  for ((i=0; i<360; i++)); do
    [ ! -e "$path" ] || return 0
    [ ! -e "$case_dir/rc" ] || break
    sleep 0.5
  done
  fail "$harness $version: missing ${path##*/}: $(tail -15 "$case_dir/live.log" 2>/dev/null)"
}

real_harness_lifecycle() {
  local harness=$1 version=$2 case_dir=$3 id=$4 bin=$5 armed=$6
  local sm="$case_dir/sm" state="$case_dir/primary/state" target="firstmate:live-$harness"
  local prompt source out i
  local -a args
  cat > "$sm/live-step.sh" <<'SH'
#!/usr/bin/env bash
set -eu
: > tool-started
for ((i=0; i<120; i++)); do
  [ ! -e release-tool ] || exit 0
  sleep 1
done
exit 1
SH
  prompt='Use the shell tool to run exactly `bash live-step.sh` in the current directory, wait for it to finish, then reply DONE. Do not use other tools or modify any files. If a Stop hook asks you to continue, reply DONE without tools.'
  case "$harness" in
    claude)
      source=claude-hook
      mkdir -p "$sm/.claude"
      printf 'kind=ship\nwindow=fixture:pending\nbackend=tmux\n' > "$sm/state/pending.meta"
      cat > "$sm/observe-stop.sh" <<'SH'
#!/usr/bin/env bash
status=0
"$FM_HOME/bin/fm-turnend-guard.sh" --claude > "$FM_HOME/guard.out" 2> "$FM_HOME/guard.err" || status=$?
if [ "$status" -eq 2 ]; then
  cp "$PARENT_STATE/$MATE_ID.busy-state" "$FM_HOME/blocked-record"
  for ((i=0; i<120; i++)); do
    [ ! -e "$FM_HOME/release-stop" ] || break
    sleep 1
  done
  [ -e "$FM_HOME/release-stop" ] || exit 1
  rm -f "$FM_HOME/state/pending.meta"
  printf 'Reply DONE without tools. The test supervisor has resolved the missing watcher.\n' >&2
else
  cp "$PARENT_STATE/$MATE_ID.busy-state" "$FM_HOME/allowed-record"
  cat "$FM_HOME/guard.out"
  cat "$FM_HOME/guard.err" >&2
fi
exit "$status"
SH
      chmod +x "$sm/observe-stop.sh"
      jq -n --arg cmd "bash $(printf '%q' "$sm/observe-stop.sh")" \
        '{hooks:{Stop:[{hooks:[{type:"command",command:$cmd,timeout:180}]}]}}' > "$sm/.claude/settings.json"
      args=(-p "$prompt" --dangerously-skip-permissions --settings "$state/$id.claude-settings.json" --output-format stream-json --verbose --no-session-persistence)
      ;;
    pi|pi-signed)
      source=pi-ext
      args=(-p --no-session --no-extensions --no-skills --no-prompt-templates --no-context-files --tools bash -e "$state/$id.pi-ext.ts" "$prompt")
      ;;
    omp)
      source=omp-ext
      args=(-p --auto-approve --no-session --no-extensions --no-skills --no-rules --tools bash -e "$state/$id.omp-ext.ts" "$prompt")
      ;;
    opencode)
      source=opencode-plugin
      args=(run "$prompt")
      ;;
    grok)
      source=
      args=(--single "$prompt" --always-approve --leader-socket "$case_dir/leader.sock")
      ;;
    codex)
      source=
      args=(exec --ephemeral --dangerously-bypass-approvals-and-sandbox "$prompt")
      ;;
  esac
  {
    printf '#!/usr/bin/env bash\n'
    printf 'cd %q || exit 1\n' "$sm"
    printf 'export HOME=%q FM_ROOT_OVERRIDE=%q FM_HOME=%q FM_STATE_OVERRIDE=%q FM_CONFIG_OVERRIDE=%q FM_DATA_OVERRIDE=%q PARENT_STATE=%q MATE_ID=%q\n' \
      "$HOME" "$sm" "$sm" "$sm/state" "$sm/config" "$sm/data" "$state" "$id"
    printf 'unset CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_TASK_ID FM_PI_HARNESS\n'
    [ "$harness" != omp ] || printf 'export FM_OMP_HARNESS=omp OMP_SKIP_SETUP=1\n'
    if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
      printf 'export CLAUDE_CONFIG_DIR=%q\n' "$CLAUDE_CONFIG_DIR"
    else
      printf 'unset CLAUDE_CONFIG_DIR\n'
    fi
    printf 'export OPENCODE_CONFIG_CONTENT=%q\n' '{"permission":{"*":"allow"}}'
    printf '%q ' "$bin" "${args[@]}"
    printf '> %q 2>&1\nprintf "%%s\\n" "$?" > %q\nsleep 300\n' "$case_dir/live.log" "$case_dir/rc"
  } > "$case_dir/run-live.sh"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "live-$harness" -c "$sm" -- \
    bash "$case_dir/run-live.sh" || fail "$harness $version: real launch failed"
  wait_for_file "$sm/tool-started" "$harness" "$version" "$case_dir"
  if [ "$armed" -eq 1 ]; then
    out=$(fm_busy_classify tmux "$target" "$harness" "$id" "$state")
    [ "$out" = "busy $source" ] || fail "$harness $version: real tool run classified '$out'"
  else
    [ ! -e "$state/$id.busy-gen" ] && [ ! -e "$state/$id.busy-state" ] \
      || fail "$harness $version: unarmed live tool run emitted busy state"
  fi
  : > "$sm/release-tool"
  if [ "$harness" = claude ]; then
    wait_for_file "$sm/blocked-record" "$harness" "$version" "$case_dir"
    out=$(fm_busy_record_read "$state" "$id")
    case "$out" in
      'busy claude-hook stop-blocked '*) ;;
      *) fail "$harness $version: blocked Stop lost busy: $out" ;;
    esac
    : > "$sm/release-stop"
    wait_for_file "$sm/allowed-record" "$harness" "$version" "$case_dir"
    out=$(cat "$sm/allowed-record")
    case "$out" in
      *' state=idle source=claude-hook event=stop '*) ;;
      *) fail "$harness $version: continued Stop did not settle: $out" ;;
    esac
  fi
  for ((i=0; i<360; i++)); do
    [ ! -e "$case_dir/rc" ] || break
    sleep 0.5
  done
  [ "$(cat "$case_dir/rc" 2>/dev/null)" = 0 ] \
    || fail "$harness $version: live lifecycle failed: $(tail -15 "$case_dir/live.log")"
  if [ "$armed" -eq 1 ]; then
    out=$(fm_busy_classify tmux "$target" "$harness" "$id" "$state")
    [ "$out" = "idle $source" ] || fail "$harness $version: completed run classified '$out'"
  else
    [ ! -e "$state/$id.busy-gen" ] && [ ! -e "$state/$id.busy-state" ] \
      || fail "$harness $version: unarmed completed run emitted busy state"
  fi
  [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: lifecycle touched the parent's turn-ended marker"
  note "$harness $version: real tool lifecycle completed; armed=$armed"
  "$REAL_TMUX" -L "$SOCKET" kill-window -t "$target" >/dev/null 2>&1 || true
}

check_harness() {  # <harness>
  local harness=$1 bin=$2 version id case_dir state out armed=0
  version=$("$bin" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version=unknown
  id="sm-$harness"
  case_dir="$LAB/$harness"
  install_sleeper "$case_dir/sleeper" "$harness" "$bin"
  install_tmux_shim "$case_dir/shim"
  out=$(spawn_mate "$case_dir" "$id" "$harness" "$case_dir/sleeper" "$case_dir/shim" 2>&1) \
    || fail "$harness $version: secondmate spawn failed: $out"
  state="$case_dir/primary/state"
  case "$harness" in
    claude|opencode|pi|pi-signed|omp) armed=1 ;;
  esac
  if [ "$armed" -eq 1 ]; then
    [ -f "$state/$id.busy-state" ] || fail "$harness $version: real tmux secondmate spawn did not arm the busy contract"
    out=$(fm_busy_classify tmux "firstmate:fm-$id" "$harness" "$id" "$state" 'working on the charter')
    [ "$out" = "busy fm-spawn" ] || fail "$harness $version: a mid-turn tail classified '$out', not busy fm-spawn"
    [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: spawn touched the parent's turn-ended marker"
    real_harness_lifecycle "$harness" "$version" "$case_dir" "$id" "$bin" "$armed"
    pass "$harness $version: real secondmate lifecycle transitions from adapter busy to idle"
  else
    [ ! -e "$state/$id.busy-gen" ] || fail "$harness $version: an unarmed secondmate spawn wrote a busy generation"
    [ ! -e "$state/$id.turn-ended" ] || fail "$harness $version: an unarmed secondmate spawn touched the parent's turn-ended marker"
    [ ! -e "$state/$id.grok-turnend-token" ] || fail "$harness $version: spawn installed a parent grok turn-end token"
    real_harness_lifecycle "$harness" "$version" "$case_dir" "$id" "$bin" "$armed"
    pass "$harness $version: real secondmate lifecycle stays unarmed and emits no parent turn-end"
  fi
}

for harness in claude opencode pi pi-signed omp grok codex; do
  if ! bin=$(resolve_bin "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its secondmate busy contract is unverified here"
    continue
  fi
  CHECKED=$((CHECKED + 1))
  (trap - EXIT; check_harness "$harness" "$bin") || FAILED=$((FAILED + 1))
done

[ "$CHECKED" -gt 0 ] || fail "secondmate busy contract live guard checked nothing (skipped:${SKIPPED:- none})"
note "checked $CHECKED harness(es); absent:${SKIPPED:- none}"
[ "$FAILED" -eq 0 ] || fail "secondmate busy contract live guard: $FAILED of $CHECKED installed harnesses failed"
pass "secondmate busy contract live guard checked every installed harness"
