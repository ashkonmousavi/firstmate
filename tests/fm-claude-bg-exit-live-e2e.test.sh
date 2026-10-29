#!/usr/bin/env bash
# Opt-in credentialed live regression for the Claude background-exit class.
# Claude Code's /exit does not exit a session that still has background work: it
# moves the session to a background session ("Moving to background...
# backgrounded <id>") that keeps running outside every lane
# (https://code.claude.com/docs/en/agent-view.md). Against the installed Claude
# Code, in a real TUI under tmux, with one trusted temporary folder, this proves
# the two halves of the fix and that the proof is not vacuous:
#   1. CONTROL, with no switch: a session with a running background shell and
#      /exit is offered "Move to background and exit"; taking it leaves a
#      background session for that folder. If it does not, the
#      vendor behavior this fix answers is gone or the prompt never started
#      background work, and the guard fails rather than passing vacuously.
#   2. LAUNCH ENVIRONMENT, with the two switches bin/fm-spawn.sh puts on every
#      Claude launch (CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1,
#      CLAUDE_CODE_DISABLE_AGENT_VIEW=1): the same /exit no longer offers the
#      handoff, ends the process, and leaves no background session for that
#      folder.
#   3. VERB BACKSTOP: bin/fm-control.sh's session check (the same listing and
#      matching it uses after an exit) finds the control run's leftover session
#      by its exact cwd and `claude rm` ends it.
# The project is isolated; Claude keeps using its existing managed
# authentication. A few Haiku turns are submitted and any background session
# this test creates is stopped by exact id before it exits.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_BG_EXIT_LIVE_E2E claude tmux

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-claude-bg-exit-live)
SOCKET="fm-claude-bg-exit-$$"
SESSION="fm-claude-bg-exit-e2e"
PROJECT=
CREATED_IDS=''

# Every id this test might have left behind, stopped by exact id.
stop_created() {
  local id
  for id in $CREATED_IDS; do
    env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude rm "$id" >/dev/null 2>&1 || true
  done
}

lab_process_live() {
  local folder=$1 pid started current
  [ -f "$folder/bg.pid" ] && [ -f "$folder/bg.started" ] || return 1
  pid=$(cat "$folder/bg.pid")
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  started=$(cat "$folder/bg.started")
  [ -n "$started" ] || return 1
  current=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  [ "$current" = "$started" ] || return 1
  case "$(ps -p "$pid" -o stat= 2>/dev/null)" in
    ''|*Z*) return 1 ;;
  esac
}

kill_lab_processes() {
  local folder
  for folder in "$LAB"/*; do
    if lab_process_live "$folder"; then
      kill "$(cat "$folder/bg.pid")" 2>/dev/null || true
    fi
  done
}

cleanup() {
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
  stop_created
  kill_lab_processes
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

# Claude Code refuses to nest inside another Claude session, so the inherited
# session markers are dropped from the lab's environment.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+)=' | cut -d= -f1 | sort -u)
}

screen() {
  tmux -L "$SOCKET" capture-pane -p -t "$SESSION" 2>/dev/null || true
}

send() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
}

enter() {
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

dialog_open() {  # <screen text>
  case "$1" in
    *'trust this folder'*|*'Enter to confirm'*) return 0 ;;
  esac
  return 1
}

# The folder-trust dialog opens with its cursor on "No, exit": move onto the
# trusting option first, then confirm.
answer_trust_dialog() {  # <screen text>
  local selected
  case "$1" in
    *'Yes, I trust this folder'*) : ;;
    *) return 0 ;;
  esac
  selected=$(printf '%s\n' "$1" | grep -F '❯' | head -1)
  case "$selected" in
    *'Yes, I trust this folder'*) enter ;;
    *) tmux -L "$SOCKET" send-keys -t "$SESSION" Down ;;
  esac
}

# Wait until the screen shows <text> (a fixed string), answering the trust
# dialog on the way. The wait is iteration-counted so it stretches under load.
wait_screen() {  # <text> <what> [iterations]
  local text=$1 what=$2 limit=${3:-400} i=0 shot
  while [ "$i" -lt "$limit" ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*)
        printf '%s\n' "$shot" >&2
        fail "Claude Code $CLAUDE_VERSION exited while waiting for $what"
        ;;
    esac
    if dialog_open "$shot"; then
      answer_trust_dialog "$shot"
    else
      case "$shot" in
        *"$text"*) return 0 ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $what"
}

# Background sessions of exactly this folder, through the same matcher
# bin/fm-control.sh uses after an exit.
bg_ids() {  # <folder>
  local json
  json=$(env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude agents --json --all 2>/dev/null) \
    || fail "claude agents --json --all failed on Claude Code $CLAUDE_VERSION"
  fm_control_claude_bg_ids "$1" "$json"
}

# run_arm <name> <switches> <control|switched>: start Claude with a background
# shell and type /exit. Claude Code 2.1.312 answers with a "Background work is
# running" dialog: "Exit and stop tasks" (the default), "Move to background and
# exit" (offered only while the handoff is enabled), and "Stay". The control arm
# must be offered the handoff and takes it; the switched arm must not be offered
# it and takes the default. Leaves the pane text in ARM_SCREEN and the dialog
# text in ARM_DIALOG.
run_arm() {
  local name=$1 switches=$2 mode=$3 i=0 shot
  PROJECT="$LAB/$name"
  ARM_DIALOG=''
  mkdir -p "$PROJECT"
  tmux -L "$SOCKET" kill-session -t "$SESSION" 2>/dev/null || true
  tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 160 -y 44 -c "$PROJECT" \
    "env $(unset_inherited) $switches CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --model haiku --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'; printf '\nCLAUDE_EXIT=%s\n' \"\$?\"; sleep 60"
  wait_screen '❯' 'the composer prompt'
  sleep 1
  send "$(cat <<'PROMPT'
Use the Bash tool with run_in_background set to true to run: sh -c 'echo $$ > bg.pid; LC_ALL=C ps -p $$ -o lstart= > bg.started; exec sleep 600'   Then reply with the single word done.
PROMPT
)"
  sleep 2
  enter
  # An Enter typed before the composer settles can be dropped: while the typed
  # prompt still sits in the composer with no turn started, press it again.
  while [ "$i" -lt 600 ]; do
    shot=$(screen)
    case "$shot" in
      *'still running'*) break ;;
      *'CLAUDE_EXIT='*) fail "Claude Code $CLAUDE_VERSION exited before the background shell started: $shot" ;;
    esac
    if [ "$i" -gt 0 ] && [ $((i % 60)) -eq 0 ]; then
      case "$shot" in
        *'Running in the background'*|*'esc to interrupt'*) : ;;
        *) enter ;;
      esac
    fi
    sleep 0.25
    i=$((i + 1))
  done
  [ "$i" -lt 600 ] || fail "Claude Code $CLAUDE_VERSION never showed the background shell to be running: $(screen)"
  lab_process_live "$PROJECT" || fail "the background shell did not record a live process for $name"
  i=0
  send '/exit'
  sleep 1
  enter
  while [ "$i" -lt 160 ]; do
    shot=$(screen)
    case "$shot" in
      *'CLAUDE_EXIT='*) break ;;
      *'Background work is running'*)
        ARM_DIALOG=$shot
        if [ "$mode" = control ]; then
          case "$shot" in
            *'Move to background and exit'*) : ;;
            *) fail "control arm: Claude Code $CLAUDE_VERSION did not offer 'Move to background and exit' without the switch: $shot" ;;
          esac
          tmux -L "$SOCKET" send-keys -t "$SESSION" Down
          sleep 0.5
        else
          case "$shot" in
            *'Move to background and exit'*) fail "switched arm: Claude Code $CLAUDE_VERSION still offers 'Move to background and exit' with CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1: $shot" ;;
          esac
        fi
        enter
        sleep 1
        ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  ARM_SCREEN=$(screen)
  tmux -L "$SOCKET" kill-server 2>/dev/null || true
}

# --- 1. control: no switch, the handoff leaves a background session -----------

run_arm control '' control
CONTROL_PROJECT=$PROJECT
CONTROL_IDS=$(bg_ids "$CONTROL_PROJECT")
CREATED_IDS="$CONTROL_IDS"
[ -n "$CONTROL_IDS" ] \
  || fail "control arm: /exit on Claude Code $CLAUDE_VERSION left no background session for $CONTROL_PROJECT, so this guard would pass vacuously (the vendor behavior changed, or the prompt did not start background work): $ARM_SCREEN"
pass "control: Claude Code $CLAUDE_VERSION /exit with background work leaves background session(s) $CONTROL_IDS"

# --- 2. the launch environment bin/fm-spawn.sh sets ---------------------------

run_arm switched 'CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1 CLAUDE_CODE_DISABLE_AGENT_VIEW=1' switched
SWITCHED_IDS=$(bg_ids "$PROJECT")
CREATED_IDS="$CREATED_IDS $SWITCHED_IDS"
case "$ARM_SCREEN" in
  *'CLAUDE_EXIT='*) : ;;
  *) fail "switched arm: Claude Code $CLAUDE_VERSION did not exit on /exit: $ARM_SCREEN" ;;
esac
[ -z "$SWITCHED_IDS" ] \
  || fail "switched arm: Claude Code $CLAUDE_VERSION left background session(s) $SWITCHED_IDS despite CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=1 CLAUDE_CODE_DISABLE_AGENT_VIEW=1"
if lab_process_live "$PROJECT"; then
  fail "switched arm: Claude Code $CLAUDE_VERSION left its background shell running"
fi
pass "switched: Claude Code $CLAUDE_VERSION /exit with background work ends the process and leaves no background session"

# --- 3. the verb backstop stops the control run's leftover session ------------

for id in $CONTROL_IDS; do
  old_pid=$(env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude agents --json --all | jq -r --arg id "$id" '.[] | select(.id == $id) | .pid')
  env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude respawn "$id" >/dev/null 2>&1 \
    || fail "claude respawn $id failed on Claude Code $CLAUDE_VERSION"
  new_pid=$old_pid
  for ((i=0; i<80; i++)); do
    new_pid=$(env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude agents --json --all | jq -r --arg id "$id" '.[] | select(.id == $id) | .pid // empty')
    [ -z "$new_pid" ] || [ "$new_pid" = "$old_pid" ] || break
    sleep 0.25
  done
  [ -n "$new_pid" ] && [ "$new_pid" != "$old_pid" ] \
    || fail "claude respawn did not replace the session process on Claude Code $CLAUDE_VERSION"
  lab_process_live "$CONTROL_PROJECT" \
    || fail "the carried shell did not survive Claude session respawn on Claude Code $CLAUDE_VERSION"
  env -u CLAUDE_CODE_DISABLE_AGENT_VIEW -u CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF claude stop "$id" >/dev/null 2>&1 \
    || fail "claude stop $id failed on Claude Code $CLAUDE_VERSION"
  stopped_state=
  for ((i=0; i<80; i++)); do
    stopped_state=$(env -u CLAUDE_CODE_DISABLE_AGENT_VIEW claude agents --json --all | jq -r --arg id "$id" '.[] | select(.id == $id) | .state')
    [ "$stopped_state" != stopped ] || break
    sleep 0.25
  done
  [ "$stopped_state" = stopped ] || fail "the stopped session was not retained by --all on Claude Code $CLAUDE_VERSION"
  lab_process_live "$CONTROL_PROJECT" \
    || fail "the carried shell did not survive stopping its session on Claude Code $CLAUDE_VERSION"
  env -u CLAUDE_CODE_DISABLE_AGENT_VIEW -u CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF claude rm "$id" >/dev/null 2>&1 \
    || fail "background cleanup of $id failed on Claude Code $CLAUDE_VERSION"
done
i=0
while [ "$i" -lt 40 ] && [ -n "$(bg_ids "$CONTROL_PROJECT")" ]; do
  sleep 0.5
  i=$((i + 1))
done
[ -z "$(bg_ids "$CONTROL_PROJECT")" ] \
  || fail "claude rm did not end background session(s) $CONTROL_IDS on Claude Code $CLAUDE_VERSION"
if lab_process_live "$CONTROL_PROJECT"; then
  fail "background cleanup left the control arm's shell running on Claude Code $CLAUDE_VERSION"
fi
pass "backstop: exact-session removal ends the respawned session and its earlier carried shell"
