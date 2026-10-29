#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M644V5T0RZ7AA08H11AYG9KM
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  for hooks in "$LAB"~/*.git-hooks; do
    [ ! -d "$hooks" ] || chmod u+w "$hooks"
  done
  sleep 1
  rm -rf "$LAB"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB/home"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/account with spaces" "$LAB/project"
export TMUX_TMPDIR="$LAB/tmux"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_PANE_ID TMUX
export DISABLE_AUTOUPDATER=1
export FM_HOME="$LAB/home" HOME="$LAB/user" CLAUDE_CONFIG_DIR="$LAB/account with spaces"
printf '1 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":100,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$LAB" > "$FM_HOME/config/machine-admission.json"
printf 'tmux\n' > "$FM_HOME/config/backend"
touch "$FM_HOME/state/.last-watcher-beat"
git -C "$LAB/project" init -q -b main
printf '# disposable project\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name='Lab' -c user.email=lab@example.invalid commit -qm init
git -C "$LAB/project" worktree add -q -b worker "$LAB/wt"
tmux -L fm-lab -f /dev/null new-session -d -s lab -n controller -x 160 -y 44 -c "$LAB/wt" bash
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')"
for kind in ship scout secondmate; do
for form in fallback changed-directory; do
 id="probe-$kind-$form"
 wt="$LAB/wt"
 if [ "$kind" = secondmate ]; then
   wt="$LAB/mate-$id"
   mkdir -p "$wt/bin" "$wt/data" "$wt/state" "$wt/config" "$wt/projects"
   printf '# Disposable lab home\n' > "$wt/AGENTS.md"
   printf '%s\n' "$id" > "$wt/.fm-secondmate-home"
   git -C "$wt" init -q -b main
 fi
 tmux -L fm-lab new-window -d -t lab: -n "fm-$id" -c "$wt" bash
 tmux -L fm-lab set-window-option -t "lab:fm-$id" automatic-rename off
 mkdir -p "$FM_HOME/data/$id"
 printf '# Task\n## Captain\x27s intent\nValidate isolated launch exports.\n\n## Firstmate spec\nExecute the supplied CLI expression.\n' > "$FM_HOME/data/$id/brief.md"
 printf 'window=lab:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=%s\nmode=no-mistakes\nyolo=off\nbackend=tmux\nmodel=default\neffort=default\n' "$id" "$id" "$wt" "$LAB/project" "$kind" > "$FM_HOME/state/$id.meta"
 printf 'home=%s\n' "$wt" >> "$FM_HOME/state/$id.meta"
 # The real CLI rejects this first invocation. The real fallback must inherit the same exports.
 expression="claude --definitely-invalid-option || { claude --version; printf 'handoff=%s\\nview=%s\\naccount=%s\\n' \"\$CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF\" \"\$CLAUDE_CODE_DISABLE_AGENT_VIEW\" \"\$CLAUDE_CONFIG_DIR\" > '$LAB/$id.result'; }"
 if [ "$form" = changed-directory ]; then
   expression="cd '$wt' && { claude --version; printf 'handoff=%s\\nview=%s\\naccount=%s\\n' \"\$CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF\" \"\$CLAUDE_CODE_DISABLE_AGENT_VIEW\" \"\$CLAUDE_CONFIG_DIR\" > '$LAB/$id.result'; }"
 else
   expression="CLAUDE_CONFIG_DIR='$LAB/account with spaces' $expression"
   printf 'HOME\nPATH\nTERM\n' > "$FM_HOME/config/launch-env-allowlist"
 fi
 CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=0 CLAUDE_CODE_DISABLE_AGENT_VIEW=0 bash "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness "$expression" > "$EVIDENCE/$id-spawn.txt" 2>&1 || { cat "$EVIDENCE/$id-spawn.txt"; exit 1; }
 for ((i=0;i<80;i++)); do [ ! -f "$LAB/$id.result" ] || break; sleep 0.25; done
 tmux -L fm-lab capture-pane -p -t "lab:fm-$id" > "$EVIDENCE/$id-pane.txt"
 [ -f "$LAB/$id.result" ] || { cat "$EVIDENCE/$id-pane.txt"; exit 1; }
 cat "$LAB/$id.result" | tee "$EVIDENCE/$id-environment.txt"
 grep -Fxq 'handoff=1' "$LAB/$id.result"
 grep -Fxq 'view=1' "$LAB/$id.result"
 actual_account=$(sed -n 's/^account=//p' "$LAB/$id.result")
 recorded_account=$(sed -n 's/^claude_config_dir=//p' "$FM_HOME/state/$id.meta")
 [ "$actual_account" = "$LAB/account with spaces" ] && [ "$actual_account" = "$recorded_account" ]
 printf 'recorded-account=%s\n' "$recorded_account" | tee -a "$EVIDENCE/$id-environment.txt"
 printf 'Live fm-spawn %s: private tmux executed real Claude CLI; safeguards and recorded account agree.\n' "$form"
 rm -f "$FM_HOME/config/launch-env-allowlist"
done

done
