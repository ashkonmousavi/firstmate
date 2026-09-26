#!/usr/bin/env bash
# Live adversarial check: a real Claude Code worker whose composer already holds
# unsent draft text is steered through the real bin/fm-send.sh. The send must
# record the message durably but must NOT type the doorbell on top of the draft
# (no merged submission). After the draft is cleared, the watcher's re-ring
# (fm_task_inbox_ring) must get the message acted on and acknowledged.
# Isolation: private tmux socket, throwaway FM_HOME under a temp dir.
set -u
# Runs as a no-mistakes gate agent: fm-send is authorized only against a marked
# disposable lab home (bin/fm-lab-home.sh) with no FM_*_OVERRIDE.
ROOT=${1:?worktree root}
SOCKET="fm-draft-live-$$"
SESSION=draftlive
WIN=hx-claude
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-draft-live.XXXXXX")
TIMEOUT=${TIMEOUT:-150}
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
SHIM="$LAB/shim"; mkdir -p "$SHIM"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$SHIM/tmux"; chmod +x "$SHIM/tmux"
PATH="$SHIM:$PATH"
. "$ROOT/bin/fm-tmux-lib.sh"
. "$ROOT/bin/fm-task-inbox-lib.sh"
snap() { echo "----- pane: $1"; tmux -L "$SOCKET" capture-pane -p -t "$SESSION:$WIN" | grep '[^[:space:]]' | tail -8; }

tmux -L "$SOCKET" new-session -d -s "$SESSION" -x 220 -y 50 -c "$ROOT"
tmux -L "$SOCKET" new-window -d -t "$SESSION:" -n "$WIN" -c "$ROOT" -- bash -lc \
  "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'"
i=0; while [ $i -lt 60 ]; do [ "$(fm_tmux_composer_state "$SESSION:$WIN")" = empty ] && break; sleep 1; i=$((i+1)); done
echo "composer before draft: $(fm_tmux_composer_state "$SESSION:$WIN")"

DRAFT="CAPTAIN_DRAFT_do_not_send_yet"
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" -l "$DRAFT"
sleep 2
echo "composer with draft: $(fm_tmux_composer_state "$SESSION:$WIN")"
snap "draft typed, before fm-send"

home=$("$ROOT/bin/fm-lab-home.sh" create "$LAB/home") || { echo "lab home create failed"; exit 1; }; mkdir -p "$home/state"; task=live-draft; acted="$LAB/acted"
printf 'window=%s:%s\nkind=ship\nharness=claude\n' "$SESSION" "$WIN" > "$home/state/$task.meta"
FM_HOME="$home" "$ROOT/bin/fm-send.sh" "$task" \
  "Firstmate live check: run exactly this shell command now: touch $acted - then follow the mv instruction you were given for this message. Reply with one short line."
echo "fm-send exit=$?"
rec="$home/state/$task.inbox/001.msg"; handled="$home/state/$task.inbox/handled/001.msg"
[ -f "$rec" ] && echo "durable record: present" || echo "durable record: MISSING"
sleep 8
snap "after fm-send with draft present"
pane=$(tmux -L "$SOCKET" capture-pane -p -S -200 -t "$SESSION:$WIN")
fail=0
printf '%s\n' "$pane" | grep -q "$DRAFT" && echo "draft still in composer: yes" || { echo "draft still in composer: NO"; fail=1; }
if printf '%s\n' "$pane" | grep -qE "inbox|\.msg"; then echo "doorbell text visible in pane: YES (typed over draft)"; fail=1; else echo "doorbell text visible in pane: no"; fi
[ -e "$acted" ] && { echo "worker acted while draft present: YES"; fail=1; } || echo "worker acted while draft present: no"

# Captain clears the draft; the watcher re-rings.
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" C-u
sleep 1
tmux -L "$SOCKET" send-keys -t "$SESSION:$WIN" Escape
sleep 2
echo "composer after clearing: $(fm_tmux_composer_state "$SESSION:$WIN")"
fm_task_inbox_ring tmux "$SESSION:$WIN" "$rec"; echo "re-ring rc=$?"
i=0; while [ $i -lt "$TIMEOUT" ]; do [ -f "$handled" ] && [ -e "$acted" ] && break; sleep 1; i=$((i+1)); done
snap "after re-ring"
if [ -f "$handled" ] && [ -e "$acted" ]; then echo "after re-ring: acted=yes acked=yes (${i}s)"; else echo "after re-ring: acted=$([ -e "$acted" ] && echo yes || echo no) acked=$([ -f "$handled" ] && echo yes || echo no)"; fail=1; fi
echo "RESULT: $([ $fail -eq 0 ] && echo PASS || echo FAIL)"
exit $fail
