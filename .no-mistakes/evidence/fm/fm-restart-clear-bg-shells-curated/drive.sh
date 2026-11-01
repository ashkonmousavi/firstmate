#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M6ABEANQHANCK9Z0N0FC6S6P
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/mate" "$LAB/state/sm.inbox/handled"
export TMUX_TMPDIR="$LAB/tmux"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.no-mistakes/live-validation/herdr-state"
HERDR_LAB=
PIDS=()
cleanup() {
  status=$?
  trap - EXIT
  if [ "$status" != 0 ] && [ -n "${target:-}" ]; then screen > "$EVIDENCE/$backend-setup-failure.txt" 2>/dev/null || true; fi
  tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  if [ -n "$HERDR_LAB" ]; then bash "$ROOT/bin/fm-herdr-lab.sh" teardown "$HERDR_LAB" >> "$EVIDENCE/live-transcript.log" 2>&1 || status=1; fi
  for pid in "${PIDS[@]}"; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$LAB"
  printf 'cleanup exit=%s\n' "$status"
  exit "$status"
}
trap cleanup EXIT
. bin/fm-backend.sh
. bin/fm-secondmate-restart-lib.sh
# The prompt is an emitted agent-facing interface; its meaning is evaluated by
# Claude acting on real tasks, not by assertions about implementation text.
CLEAN_REQUEST=${FM_SECONDMATE_PERSIST_REQUEST#*Also stop}
CLEAN_REQUEST="Also stop${CLEAN_REQUEST%% Then reply*}"
record() { screen 2>/dev/null > "$EVIDENCE/$backend-$1.txt" || { [ "$backend" = tmux ] && printf "CLI exited; direct-command tmux session closed.\n" > "$EVIDENCE/$backend-$1.txt"; }; }
wait_for() { local limit=$1 n; shift; for ((n=0;n<limit;n++)); do "$@" && return 0; sleep 1; done; record timeout; return 1; }
idle() { [ "$(fm_backend_composer_state "$backend" "$target")" = empty ]; }
ready() { [ -s "$LAB/mate/$backend-harmless.pid" ] && kill -0 "$(cat "$LAB/mate/$backend-harmless.pid")" 2>/dev/null && idle && screen | grep -q READY; }
count() { local text; text=$(screen); [ "$(fm_composer_claude_background_shells "$text" || true)" = "$1" ]; }
no_count() { local text; text=$(screen); ! fm_composer_claude_background_shells "$text" >/dev/null; }
screen() { fm_backend_visible_capture "$backend" "$target"; }
send() {
 if [ "$backend" = herdr ]; then
   bash bin/fm-herdr-lab.sh run "$HERDR_LAB" pane send-text "$PANE" "$1" >/dev/null
   sleep 0.5
   bash bin/fm-herdr-lab.sh run "$HERDR_LAB" pane send-keys "$PANE" enter >/dev/null
 else
   tmux -L fm-lab send-keys -t primary -l "$1"
   sleep 0.5
   tmux -L fm-lab send-keys -t primary Enter
 fi
}
dead() { ! kill -0 "$BACKGROUND_PID" 2>/dev/null; }
agent_dead() { case "$(fm_backend_agent_state "$backend" "$target")" in dead|missing) return 0;; *) return 1;; esac; }
export DISABLE_AUTOUPDATER=1 DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
for backend in ${FM_EVAL_BACKENDS:-tmux herdr}; do
  fm_backend_source "$backend"
  export FM_EVAL_PROMPT="Use Bash exactly once with run_in_background=true to run: sh -c 'echo \$\$ > $LAB/mate/$backend-harmless.pid; exec sleep 600'. Then reply READY and stop. Leave the harmless sleep running. Do not change any other files."
  if [ "$backend" = tmux ]; then
    target=primary:fm-sm
    env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE tmux -L fm-lab new-session -d -s primary -n fm-sm -x 180 -y 45 -c "$ROOT" -e FM_HOME="$LAB" -e FM_EVAL_PROMPT="$FM_EVAL_PROMPT" "bash '$ROOT/.no-mistakes/live-validation/launch.sh'"
    export TMUX=$(tmux -L fm-lab display-message -p "#{socket_path},#{pid},0")
  else
    HERDR_LAB=$(bash bin/fm-herdr-lab.sh name restart-bg)
    unset TMUX
    bash bin/fm-herdr-lab.sh provision "$HERDR_LAB"
    out=$(bash bin/fm-herdr-lab.sh run "$HERDR_LAB" workspace create --cwd "$ROOT" --label fm-bg --no-focus)
    PANE=$(printf '%s' "$out" | jq -er '.result.root_pane.pane_id')
    target="$HERDR_LAB:$PANE"
    bash bin/fm-herdr-lab.sh run "$HERDR_LAB" pane send-text "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' FM_EVAL_PROMPT=$(printf '%q' "$FM_EVAL_PROMPT") bash '$ROOT/.no-mistakes/live-validation/launch.sh'" >/dev/null
    sleep 0.5
   bash bin/fm-herdr-lab.sh run "$HERDR_LAB" pane send-keys "$PANE" enter >/dev/null
  fi
  wait_for 100 ready
  BACKGROUND_PID=$(cat "$LAB/mate/$backend-harmless.pid")
  PIDS+=("$BACKGROUND_PID")
  kill -0 "$BACKGROUND_PID"
  wait_for 15 count 1
  record harmless-running
  printf '%s: harmless sleep alive pid=%s, production parser count=1\n' "$backend" "$BACKGROUND_PID"
  send "$CLEAN_REQUEST Then reply STOPPED."
  wait_for 100 dead
  wait_for 60 idle
  sleep 3
  wait_for 10 no_count
  record harmless-stopped
  printf '%s: cleanup request killed its harmless sleep, composer count cleared\n' "$backend"
  send /exit
  wait_for 30 agent_dead
  record exit-without-picker
  printf '%s: /exit closed Claude without a background-work picker\n' "$backend"
done
