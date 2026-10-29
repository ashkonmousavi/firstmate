#!/usr/bin/env bash
set -eu
ROOT=$PWD
export TMPDIR="$PWD/.validation"
EVIDENCE=~/.no-mistakes/evidence/01M644V5T0RZ7AA08H11AYG9KM
LAB=$(mktemp -d "$PWD/.validation/fm-lab.XXXXXX")
cleanup() {
  tmux -L fm-lab-haiku-canonical kill-server 2>/dev/null || true
  for hooks in "$LAB"~/*.git-hooks; do
    [ ! -d "$hooks" ] || chmod u+w "$hooks"
  done
  sleep 1
  rm -rf "$LAB"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB/home"
mkdir -p "$LAB/tmux" "$LAB/user" "$LAB/account with spaces" "$LAB/project"
unset TMUX_TMPDIR
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_PANE_ID TMUX
export DISABLE_AUTOUPDATER=1
export FM_HOME="$LAB/home" HOME="$LAB/user" CLAUDE_CONFIG_DIR="$LAB/account with spaces"
printf '2 0\n' > "$FM_HOME/config/lane-capacity"
printf '{"schema":"fm-machine-admission.v1","memory_floor_gib":0,"memory_full_avg60_max":100,"disk_floor_gib":0,"disk_paths":["%s"]}\n' "$LAB" > "$FM_HOME/config/machine-admission.json"
printf 'tmux\n' > "$FM_HOME/config/backend"
touch "$FM_HOME/state/.last-watcher-beat"
git -C "$LAB/project" init -q -b main
printf '# disposable project\n' > "$LAB/project/README.md"
git -C "$LAB/project" add README.md
git -C "$LAB/project" -c user.name='Lab' -c user.email=lab@example.invalid commit -qm init
git -C "$LAB/project" worktree add -q -b worker "$LAB/wt"
tmux -L fm-lab-haiku-canonical -f /dev/null new-session -d -s lab -n controller -x 160 -y 44 -c "$LAB/wt" bash
export TMUX="$(tmux -L fm-lab-haiku-canonical display-message -p '#{socket_path},#{pid},0')"
for kind in ship scout; do
for form in canonical; do
 id="probe-$kind-$form"
 wt="$LAB/wt"
 if [ "$kind" = secondmate ]; then
   wt="$LAB/mate-$id"
   mkdir -p "$wt/bin" "$wt/data" "$wt/state" "$wt/config" "$wt/projects"
   printf '# Disposable lab home\n' > "$wt/AGENTS.md"
   printf '%s\n' "$id" > "$wt/.fm-secondmate-home"
   git -C "$wt" init -q -b main
 fi
 tmux -L fm-lab-haiku-canonical new-window -d -t lab: -n "fm-$id" -c "$wt" bash
 tmux -L fm-lab-haiku-canonical set-window-option -t "lab:fm-$id" automatic-rename off
 mkdir -p "$FM_HOME/data/$id"
 printf '# Task\n## Captain\x27s intent\nValidate isolated launch exports.\n\n## Firstmate spec\nExecute the supplied CLI expression.\n' > "$FM_HOME/data/$id/brief.md"
 printf 'window=lab:fm-%s\nendpoint_task_id=%s\nworktree=%s\nproject=%s\nharness=claude\nkind=%s\nmode=no-mistakes\nyolo=off\nbackend=tmux\nmodel=default\neffort=default\n' "$id" "$id" "$wt" "$LAB/project" "$kind" > "$FM_HOME/state/$id.meta"
 printf 'home=%s\n' "$wt" >> "$FM_HOME/state/$id.meta"
 expression=claude
 CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF=0 CLAUDE_CODE_DISABLE_AGENT_VIEW=0 bash "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness "$expression" --model haiku > "$EVIDENCE/matrix-$id-spawn.txt" 2>&1 || { cat "$EVIDENCE/matrix-$id-spawn.txt"; exit 1; }
 python3 - "lab:fm-$id" "$kind" "$CLAUDE_CONFIG_DIR" "$EVIDENCE" <<'CHECK'
import subprocess,sys,pathlib,os,json,time
socket='fm-lab-haiku-canonical'
target,kind,account,out=sys.argv[1:]
rows=[]
for i in range(100):
    shell=int(subprocess.check_output(['tmux','-L',socket,'display-message','-p','-t',target,'#{pane_pid}']))
    tree={int(a):(int(b),c) for line in subprocess.check_output(['ps','-axo','pid=,ppid=,comm='],text=True).splitlines() for a,b,c in [line.split(None,2)]}
    owned={shell}
    while True:
        more={pid for pid,(parent,name) in tree.items() if parent in owned}-owned
        if not more: break
        owned|=more
    for pid in owned:
        if tree.get(pid,(0,''))[1].split('/')[-1].startswith('claude'):
            cmd=pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0',b' ').decode()
            if '--advisor opus' not in cmd: continue
            env=dict(e.decode().split('=',1) for e in pathlib.Path(f'/proc/{pid}/environ').read_bytes().split(b'\0') if b'=' in e)
            selected={k:env.get(k) for k in ['CLAUDE_CONFIG_DIR','CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF','CLAUDE_CODE_DISABLE_AGENT_VIEW']}
            assert selected==dict(CLAUDE_CONFIG_DIR=account,CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF='1',CLAUDE_CODE_DISABLE_AGENT_VIEW='1'), selected
            rows.append(dict(kind=kind,pid=pid,command=cmd,environment=selected))
    if rows: break
    time.sleep(.25)
assert rows, 'canonical '+kind+' failed to launch real Claude with Opus advisor'
pathlib.Path(out,f'current-haiku-{kind}.json').write_text(json.dumps(rows,indent=2))
print(json.dumps(rows))
CHECK

done

done
