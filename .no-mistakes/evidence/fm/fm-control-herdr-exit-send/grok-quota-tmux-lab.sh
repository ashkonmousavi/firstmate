#!/usr/bin/env bash
# Live lab driver: real bin/fm-control.sh against a real tmux server on a
# private lab socket, real ps/kill, a disposable marked lab home, and a Grok
# stand-in process that renders the recorded usage-limit screens.
# Usage: grok-quota-tmux-lab.sh <firstmate-root> <scenario>
set -u
ROOT=$(cd "$1" && pwd); SCEN=$2
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
PRE_T1=$(ls -d /tmp/fm-t1+* 2>/dev/null)
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null
  for d in /tmp/fm-t1+*; do [ -d "$d" ] || continue; printf '%s\n' "$PRE_T1" | grep -Fqx "$d" || rm -rf "$d"; done
  chmod -R u+w "$LAB" 2>/dev/null; rm -rf "$LAB"
}
trap cleanup EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null || { echo "lab home create failed"; exit 99; }
mkdir -p "$LAB/tmux" "$LAB/bin" "$LAB/real" "$LAB/user-home" "$LAB/home/data/t1"
# Real executables whose file names are grok/codex (bash under those names), so
# the kernel comm, argv0, and tmux pane_current_command all read the harness.
ln -s "$(command -v bash)" "$LAB/real/grok"; ln -s "$(command -v bash)" "$LAB/real/codex"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID

# Project and task worktree.
PROJ="$LAB/proj"; WT="$LAB/wt"
git init -q "$PROJ"; printf '# p\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm init
git init -q --bare "$PROJ.origin.git"; git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" push -q origin HEAD 2>/dev/null
git -C "$PROJ" worktree add --quiet -b task-t1 "$WT"
printf '# Task\n## Captain'"'"'s intent\nFinish t1.\n\n## Firstmate spec\nKeep the task while its runtime changes.\n' > "$LAB/home/data/t1/brief.md"
cat > "$LAB/home/state/t1.meta" <<EOF
window=fmses:fm-t1
endpoint_task_id=t1
worktree=$WT
project=$PROJ
harness=grok
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
EOF

# Screens.
NOTICE_PICKER=$(cat "$ROOT/tests/captures/grok-weekly-limit-picker.txt")
case "$SCEN" in
  picker-int|picker-term|picker-exit|picker-base) SCREEN=$NOTICE_PICKER; CUR= ;;
  dismissed) SCREEN=$'  You hit your weekly limit.\n\n  Tab:next answer  │  Esc:scrollback'; CUR= ;;
  pending-unproven) SCREEN=$'  You hit your weekly limit.\n\n╭─ grok ─╮\n│ hello  │\n╰────────╯'; CUR='4;9' ;;
  pending) SCREEN=$'  You hit your weekly limit.\n\n╭────╮\n│ i  │\n╰────╯'; CUR='4;4' ;;
  no-notice) SCREEN=$'\n\n  Tab:next answer  │  Esc:scrollback'; CUR= ;;
  *) echo "unknown scenario"; exit 98 ;;
esac
printf '%s' "$SCREEN" > "$LAB/screen"
[ -n "$CUR" ] && printf '%s' "$CUR" > "$LAB/cursor"

# Grok stand-in: an executable named grok (so comm/pane_current_command read
# grok). It draws the screen, records every byte typed into it, records the
# signals it gets, and survives SIGINT only when told to.
cat > "$LAB/grok-body.sh" <<EOF
L=$LAB
trap 'echo TERM >> "\$L/signals"; exit 143' TERM
if [ -e "\$L/ignore-int" ]; then trap 'echo INT-ignored >> "\$L/signals"' INT
else trap 'echo INT-exit >> "\$L/signals"; exit 130' INT; fi
stty -icanon -echo 2>/dev/null
printf '\033[2J\033[H'; cat "\$L/screen"
[ -e "\$L/cursor" ] && printf '\033[%sH' "\$(cat "\$L/cursor")"
: > "\$L/grok-ready"
while :; do
  if IFS= read -r -n1 -t 1 c; then printf '%s' "\${c:-<NL>}" >> "\$L/typed"; fi
done
EOF
printf '#!/bin/sh\nexec "%s/real/grok" "%s/grok-body.sh"\n' "$LAB" "$LAB" > "$LAB/bin/grok"
printf 'while :; do read -r -t 3600 _ || true; done\n' > "$LAB/codex-body.sh"
printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/codex-args"; : > "%s/codex-launched"\nexec "%s/real/codex" "%s/codex-body.sh"\n' "$LAB" "$LAB" "$LAB" "$LAB" > "$LAB/bin/codex"
chmod +x "$LAB/bin/grok" "$LAB/bin/codex"
case "$SCEN" in picker-term|dismissed|pending-unproven|pending|no-notice) : > "$LAB/ignore-int" ;; esac

tmux -L fm-lab -f /dev/null new-session -d -s fmses -n fm-t1 -x 200 -y 40 -c "$WT" \
  "env PATH=$LAB/bin:\$PATH PS1='lab\$ ' bash --norc --noprofile"
SOCK=$(tmux -L fm-lab display-message -p '#{socket_path}')
export TMUX="$SOCK,$$,0"
tmux send-keys -t fmses:fm-t1 "grok" Enter
for _ in $(seq 1 50); do [ -e "$LAB/grok-ready" ] && break; sleep 0.1; done
sleep 0.3
echo "--- pane before (tmux capture-pane on lab socket) ---"
tmux capture-pane -p -t fmses:fm-t1 | sed '/^$/N;/^\n$/D'
echo "--- pane_current_command: $(tmux display-message -p -t fmses:fm-t1 '#{pane_current_command}')"
echo "--- composer verdict: $(bash -c '. "$1/bin/fm-backend.sh" && fm_backend_composer_state tmux fmses:fm-t1' _ "$ROOT")"
echo "--- agent state: $(bash -c '. "$1/bin/fm-backend.sh" && fm_backend_agent_state tmux fmses:fm-t1' _ "$ROOT")"

VERB="relaunch --harness codex --note grok-is-out-of-usage"
[ "$SCEN" = picker-exit ] && VERB=exit
echo "--- \$ fm-control.sh t1 $VERB"
# shellcheck disable=SC2086
OUT=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  PATH="$LAB/bin:$PATH" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR= CODEX_HOME="$LAB/user-home/.codex" \
  FM_HOME="$LAB/home" FM_SPAWN_NO_GUARD=1 FM_CONTROL_EXIT_WAIT=10 FM_CONTROL_LAUNCH_WAIT=15 \
  "$ROOT/bin/fm-control.sh" t1 $VERB 2>&1); RC=$?
printf '%s\n' "$OUT"
echo "--- rc=$RC"
sleep 0.5
echo "--- signals received by grok stand-in: $(tr '\n' ' ' < "$LAB/signals" 2>/dev/null)"
echo "--- bytes typed into grok stand-in: '$(cat "$LAB/typed" 2>/dev/null)'"
echo "--- pane_current_command after: $(tmux display-message -p -t fmses:fm-t1 '#{pane_current_command}')"
echo "--- replacement codex launched: $([ -e "$LAB/codex-launched" ] && echo yes || echo no)"
echo "--- recorded harness: $(grep '^harness=' "$LAB/home/state/t1.meta" | tail -1)"
echo "--- pane after ---"
tmux capture-pane -p -t fmses:fm-t1 | sed '/^$/N;/^\n$/D' | tail -8
