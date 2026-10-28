#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M61T4DT0DWZ6683608ERTGB5
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE NO_MISTAKES_GATE
LAB=$(mktemp -d "$ROOT/.iXXXXXX")
bash bin/fm-lab-home.sh create "$LAB" >/dev/null
export FM_HOME=$LAB TMUX_TMPDIR="$LAB/tmux" TMPDIR="$ROOT/.test-validation/tmp"
mkdir -p "$LAB/tmux" "$LAB/shim"
cleanup() {
  tmux -L fm-lab capture-pane -p -t primary:fm-mate > "$EVIDENCE/codex-idle-final.txt" 2>/dev/null || true
  cp "$LAB/input.log" "$EVIDENCE/codex-idle-input.log" 2>/dev/null || true
  cp -R "$LAB/state" "$EVIDENCE/codex-idle-state"
  tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
REAL_TMUX=$(command -v tmux)
cat > "$LAB/shim/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = send-keys ]; then printf '%q ' "\$@" >> "$LAB/input.log"; printf '\\n' >> "$LAB/input.log"; fi
exec "$REAL_TMUX" -L fm-lab "\$@"
EOF
chmod +x "$LAB/shim/tmux"
export PATH="$LAB/shim:$PATH"
export FM_TASK_INBOX="$LAB/state/mate.inbox"
printf -v prompt 'Only work on this disposable lab test. Run this exact foreground shell command, do not background it, wait until it returns: touch %q; while [ ! -f %q ]; do sleep 1; done; touch %q . Then reply READY. Do not use any other files or instructions.' "$LAB/started" "$LAB/release" "$LAB/finished"
tmux new-session -d -s primary -n fm-mate -x 220 -y 50 -c "$ROOT" -e FM_HOME="$LAB" -e FM_TASK_INBOX="$FM_TASK_INBOX" python3 "$ROOT/.test-validation/codex-launch.py" --dangerously-bypass-approvals-and-sandbox "$prompt"
cat > "$LAB/state/mate.meta" <<EOF
window=primary:fm-mate
kind=secondmate
mode=secondmate
backend=tmux
harness=codex
endpoint_task_id=mate
worktree=$ROOT
project=$ROOT
home=$LAB
projects=alpha
EOF
. bin/fm-task-inbox-lib.sh
. bin/fm-busy-lib.sh
for ((i=0;i<150;i++)); do
  [ ! -e "$LAB/started" ] || break
  sleep 1
done
[ -f "$LAB/started" ] || { tmux capture-pane -p -t primary:fm-mate; echo 'FAIL: codex foreground tool never began'; exit 1; }
rec=$(fm_task_inbox_write "$LAB/state" mate "Run this exact shell command: touch $LAB/acted . Then move this record to handled/. Reply one line.")
# Ask the ordinary product watcher to observe the real busy agent twice.
export FM_TASK_INBOX_GRACE_SECS=0 FM_TASK_INBOX_BUSY_MAX=2 FM_POLL=1
for n in 1 2; do
  FM_HOME="$LAB" bash -c '. bin/fm-watch.sh; watcher_capture tmux primary:fm-mate 40 fm-mate; printf "semantic-state: "; fm_busy_classify_meta "$STATE/mate.meta" mate "$STATE" "$WATCHER_CAPTURE"; inbox_steer_check primary:fm-mate mate'
done
[ -f "$LAB/state/mate.inbox/.busy-state" ] || { echo 'FAIL: no busy debt retained'; exit 1; }
[ -f "$LAB/state/mate.inbox/.escalated" ] || { echo 'FAIL: busy escalation missing'; exit 1; }
[ ! -s "$LAB/input.log" ] || { echo 'FAIL: busy nonqueue agent received input'; exit 1; }
printf 'busy marker before release: '; cat "$LAB/state/mate.inbox/.busy-state"
tmux capture-pane -p -t primary:fm-mate > "$EVIDENCE/codex-busy-deferred.txt"
touch "$LAB/release"
for ((i=0;i<90;i++)); do
  screen=$(tmux capture-pane -p -t primary:fm-mate)
  verdict=$(fm_busy_classify_meta "$LAB/state/mate.meta" mate "$LAB/state" "$screen")
  if [ -f "$LAB/finished" ] && [ "${verdict%% *}" != busy ]; then break; fi
  sleep 1
done
[ -f "$LAB/finished" ] && [ "${verdict%% *}" != busy ]
printf 'state on idle: %s\n' "$verdict"
marker=$(cat "$LAB/state/mate.inbox/.busy-state")
# A real bounded checkpoint may only queue recovery, never spend the owed ring.
FM_CHECKPOINT_DEADLINE=$(( $(date +%s)+60 )) FM_HOME="$LAB" bash -c '. bin/fm-watch.sh; inbox_steer_check primary:fm-mate mate'
[ "$(cat "$LAB/state/mate.inbox/.busy-state")" = "$marker" ]
[ ! -s "$LAB/input.log" ]
printf 'checkpoint deferred the ring and retained the busy marker\n'
# The production recovery pass must deliver that same owed ring exactly once.
FM_TASK_INBOX_GRACE_SECS=3600 FM_HOME="$LAB" bash -c '. bin/fm-watch.sh; inbox_steer_check primary:fm-mate mate'
[ ! -f "$LAB/state/mate.inbox/.busy-state" ]
for ((i=0;i<120;i++)); do
  [ ! -f "$LAB/acted" ] || [ ! -f "$LAB/state/mate.inbox/handled/001.msg" ] || break
  sleep 1
done
[ -f "$LAB/acted" ] && [ -f "$LAB/state/mate.inbox/handled/001.msg" ] || { echo 'FAIL: idle ring not consumed and acknowledged'; exit 1; }
[ "$(grep -c 'Firstmate' "$LAB/input.log")" -eq 1 ]
printf 'PASS: real Codex busy deferral, escalation, checkpoint preservation, one idle re-ring consumed and acknowledged\n'
