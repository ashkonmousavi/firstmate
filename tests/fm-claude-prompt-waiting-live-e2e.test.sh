#!/usr/bin/env bash
# Opt-in live guard for the Claude prompt-waiting marker.
#
# bin/fm-spawn.sh registers a Claude PermissionRequest hook that writes
# state/<id>.prompt-waiting whenever a dialog is about to ask a human, and
# bin/fm-watch.sh surfaces each new marker ahead of any declared pause.
# Whether Claude fires that hook is a vendor fact no stub can prove, so this
# guard runs the REAL installed Claude, in bypass mode as every worker does,
# with the hook settings the REAL fm-spawn writes. It first asserts that an
# ordinary call bypass mode auto-approves leaves no marker, then asserts a
# fresh marker for each of the three ways a question reaches a worker pane:
#   - a main-thread Bash call bypass mode still refuses to auto-approve,
#   - the same call from a background subagent, and
#   - an AskUserQuestion question.
# tests/fm-watch-triage.test.sh and tests/fm-busy-adapter-wiring.test.sh pin
# the watcher and hook logic portably; this guard covers only what CI cannot.
#
# Run it after every Claude upgrade and before trusting refreshed evidence in
# docs/verification/runtime-backends.md:
#
#   FM_CLAUDE_PROMPT_LIVE_E2E=1 tests/fm-claude-prompt-waiting-live-e2e.test.sh
#
# It spends a few model turns (FM_CLAUDE_PROMPT_LIVE_MODEL, default haiku).
# The spawn runs against a throwaway home with fake tmux; Claude itself runs in
# a private tmux server on its own socket, and every dialog is dismissed, so
# no command it asks about ever runs.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_CLAUDE_PROMPT_LIVE_E2E claude tmux

CLAUDE_VERSION=$(claude --version 2>/dev/null | head -n 1)
MODEL=${FM_CLAUDE_PROMPT_LIVE_MODEL:-haiku}
LAB="${TMPDIR:-/tmp}/fm-claude-prompt-live-e2e.$$"
SOCKET="fm-prompt-live-$$"
SESSION=prompt
CHECKED=0

fail() {
  printf 'not ok - claude %s: %s\n' "$CLAUDE_VERSION" "$1" >&2
  capture >&2
  exit 1
}

cleanup() {
  tmux -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$SOCKET"
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT INT TERM

capture() { tmux -L "$SOCKET" capture-pane -p -t "$SESSION" -S -200 2>/dev/null || true; }

send_line() {  # <text>
  tmux -L "$SOCKET" send-keys -t "$SESSION" -l "$1"
  sleep 2
  tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
}

# --- the real spawn writes the hook settings ----------------------------------

ID=prompt-live
HOME_DIR="$LAB/home"
PROJ="$LAB/project"
WT="$LAB/wt"
FAKEBIN=$(make_spawn_fakebin "$LAB/fake" claude)
fm_test_spawn_home "$HOME_DIR" claude
fm_git_worktree "$PROJ" "$WT" wt-prompt-live
fm_test_spawn_brief "$HOME_DIR" "$ID"
out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$FAKEBIN" "$ID" "$PROJ" --mode no-mistakes --yolo off) \
  || fail "the fixture spawn failed: $out"
MARKER="$HOME_DIR/state/$ID.prompt-waiting"
jq -e '.hooks.PermissionRequest' "$WT/.claude/settings.local.json" >/dev/null \
  || fail "fm-spawn wrote no PermissionRequest hook"
[ ! -e "$MARKER" ] || fail "a fresh spawn already carries a prompt marker"
mkdir -p "$WT/scr/trees"
: > "$WT/scr/trees/keep"

# --- the real Claude, as a worker runs it -------------------------------------

tmux -L "$SOCKET" new-session -d -s "$SESSION" -c "$WT" -x 200 -y 50 \
  "claude --dangerously-skip-permissions --model $MODEL" \
  || fail "could not start an interactive lab session"

# A folder Claude has not seen opens on its workspace-trust dialog, whose cursor
# may rest on the declining option, so move to the trusting one when it does.
n=0
while [ "$n" -lt 30 ]; do
  pane=$(capture)
  if printf '%s' "$pane" | grep -q 'Yes, I trust this folder'; then
    printf '%s' "$pane" | grep -q '❯ No, exit' && tmux -L "$SOCKET" send-keys -t "$SESSION" Down && sleep 1
    tmux -L "$SOCKET" send-keys -t "$SESSION" Enter
    sleep 5
  elif printf '%s' "$pane" | grep -q 'bypass permissions'; then
    break
  fi
  sleep 2
  n=$((n + 1))
done
sleep 5

# expect_marker <case> <prompt>: send the prompt, require a marker different
# from the one before it, then dismiss the dialog so nothing it asks about runs.
expect_marker() {
  local name=$1 before after i=0
  before=$(cat "$MARKER" 2>/dev/null || true)
  send_line "$2"
  while [ "$i" -lt 60 ]; do
    after=$(cat "$MARKER" 2>/dev/null || true)
    [ -n "$after" ] && [ "$after" != "$before" ] && break
    sleep 2
    i=$((i + 1))
  done
  [ -n "$after" ] && [ "$after" != "$before" ] \
    || fail "$name: no fresh prompt-waiting marker within 120s (still '${after:-absent}')"
  case "$after" in
    [0-9]*' '[0-9]*) : ;;
    *) fail "$name: the marker is not '<epoch> <pid>': '$after'" ;;
  esac
  tmux -L "$SOCKET" send-keys -t "$SESSION" Escape
  sleep 6
  CHECKED=$((CHECKED + 1))
  pass "claude $CLAUDE_VERSION: $name raises the PermissionRequest prompt marker in bypass mode"
}

# expect_no_marker <case> <prompt> <done-file>: send a prompt bypass mode
# auto-approves, wait until its command has run, and require the marker unchanged.
expect_no_marker() {
  local name=$1 done_file=$3 before after i=0
  before=$(cat "$MARKER" 2>/dev/null || true)
  send_line "$2"
  while [ "$i" -lt 60 ] && [ ! -e "$done_file" ]; do
    sleep 2
    i=$((i + 1))
  done
  [ -e "$done_file" ] || fail "$name: the auto-approved command did not run within 120s"
  sleep 6
  after=$(cat "$MARKER" 2>/dev/null || true)
  [ "$after" = "$before" ] \
    || fail "$name: an auto-approved call changed the prompt-waiting marker ('${before:-absent}' -> '$after')"
  CHECKED=$((CHECKED + 1))
  pass "claude $CLAUDE_VERSION: $name leaves the PermissionRequest prompt marker alone in bypass mode"
}

expect_no_marker "an auto-approved Bash call" \
  'Use the Bash tool to run exactly this command and nothing else, then stop: touch scr/auto-approved' \
  "$WT/scr/auto-approved"
expect_marker "a main-thread Bash prompt" \
  'Use the Bash tool to run exactly this command and nothing else, then stop: S=$PWD/scr; cd $S; rm -f trees/*'
expect_marker "a background subagent's Bash prompt" \
  'Use the Agent tool with run_in_background true and subagent_type general-purpose. Tell that subagent to use its Bash tool to run exactly this command and nothing else: S=$PWD/scr; cd $S; rm -f trees/*   Then end your own turn immediately without waiting.'
expect_marker "an AskUserQuestion question" \
  'Use the AskUserQuestion tool to ask me one yes/no question, "Proceed?", with options Yes and No. Do nothing else.'

[ "$CHECKED" -eq 4 ] || fail "only $CHECKED of 4 prompt cases were checked"
[ -e "$WT/scr/trees/keep" ] || fail "a dismissed prompt still ran its command"
printf '# claude %s: checked %s prompt cases\n' "$CLAUDE_VERSION" "$CHECKED"
