#!/usr/bin/env bash
set -e
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M5H0602RYM6MA32MJ8ABYCP8
LAB=$(mktemp -d "$PWD/.test-tmp/fm-lab.XXXXXX")
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/shim"
SOCKET=fm-boundary-$$
trap 'tmux -L "$SOCKET" kill-server 2>/dev/null || true; rm -rf "$LAB"' EXIT
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH" FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" FM_CONFIG_OVERRIDE="$LAB/config" FM_DATA_OVERRIDE="$LAB/data" FM_PROJECTS_OVERRIDE="$LAB/projects" FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_RING_MAX=2
unset FM_ROOT_OVERRIDE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
# A real interactive shell left after an agent exit, never a fake backend.
tmux new-session -d -s lab -n fm-exited -x 180 -y 45 -c "$ROOT" 'bash --noprofile --norc'
printf 'window=lab:fm-exited\nkind=ship\nharness=cursor\nbackend=tmux\nworktree=%s\n' "$ROOT" > "$LAB/state/exited.meta"
sleep 1
. bin/fm-task-inbox-lib.sh
rec=$(fm_task_inbox_write "$LAB/state" exited 'Please continue the assigned work')
for n in 1 2 3; do
  bash -c '. "$1/bin/fm-watch.sh"; inbox_steer_check lab:fm-exited exited' _ "$ROOT"
done
printf 'Exited recipient wake queue after three checks:\n'
cat "$LAB/state/.wake-queue"
[ "$(wc -l < "$LAB/state/.wake-queue")" -eq 1 ]
[ ! -e "$LAB/state/exited.inbox/.ring-state" ]
[ -f "$rec" ]
printf 'No re-ring state was created; the instruction remains unhandled.\n'
printf 'Real shell screen:\n'
tmux capture-pane -p -t lab:fm-exited

printf 'Foreign-draft budget against a real idle Cursor interface:\n'
tmux new-window -d -t lab: -n fm-draft -c "$ROOT" 'env -u CLAUDECODE -u CURSOR_INVOKED_AS cursor-agent --trust --yolo'
printf 'window=lab:fm-draft\nkind=secondmate\nharness=cursor\nbackend=tmux\n' > "$LAB/state/draft.meta"
for n in $(seq 1 60); do
  verdict=$(fm_backend_composer_state tmux lab:fm-draft)
  [ "$verdict" != empty ] || break
  sleep 1
done
[ "$verdict" = empty ]
tmux send-keys -t lab:fm-draft -l -- 'A private unfinished draft; do not submit'
sleep 1
[ "$(fm_backend_composer_state tmux lab:fm-draft)" = pending ]
rec=$(fm_task_inbox_write "$LAB/state" draft 'Please continue the assigned work')
for n in 1 2; do
  bash -c '. "$1/bin/fm-watch.sh"; inbox_steer_check lab:fm-draft draft' _ "$ROOT"
done
printf 'Ring state after two skipped attempts:\n'
cat "$LAB/state/draft.inbox/.ring-state"
for n in 3 4; do
  bash -c '. "$1/bin/fm-watch.sh"; inbox_steer_check lab:fm-draft draft' _ "$ROOT"
done
printf 'Wake queue after budget and repeat check:\n'
cat "$LAB/state/.wake-queue"
[ "$(wc -l < "$LAB/state/.wake-queue")" -eq 2 ]
[ -f "$rec" ]
[ "$(fm_backend_composer_state tmux lab:fm-draft)" = pending ]
tmux capture-pane -p -e -t lab:fm-draft > "$EVIDENCE/foreign-draft-screen.ansi"
printf 'Draft remains pending and message remains unhandled.\n'
