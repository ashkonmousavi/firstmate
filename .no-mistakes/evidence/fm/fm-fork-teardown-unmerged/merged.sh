#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=~/.no-mistakes/evidence/01M5EQXJN10KS8EDT1707ND2XG
. tests/git-config-helpers.sh
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.test-phase-tmp"
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" TREEHOUSE_ROOT="$LAB/pool" TMUX="$E/private-socket,0,0"
touch "$LAB/state/.last-watcher-beat"
git init -q --bare "$LAB/origin.git"
git -C "$LAB/origin.git" symbolic-ref HEAD refs/heads/main
git clone -q "$LAB/origin.git" "$LAB/project"
git -C "$LAB/project" -c user.name=lab -c user.email=lab@example.invalid commit -q --allow-empty -m baseline
git -C "$LAB/project" push -q origin main
WT=$(cd "$LAB/project" && treehouse get --lease --no-fetch --base main --branch fm/live-task)
printf 'lab feature\n' > "$WT/feature.txt"
git -C "$WT" add feature.txt
git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -q -m feature
git -C "$WT" push -q origin HEAD:fm/live-task
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
tasks-axi add live-task 'disposable teardown verification' --kind ship --file "$LAB/data/backlog.md"
tasks-axi start live-task --file "$LAB/data/backlog.md"
write_meta() {
 printf '%s\n' 'window=primary:fm-live-task' 'endpoint_task_id=live-task' "worktree=$WT" "project=$LAB/project" 'kind=ship' 'mode=direct-PR' 'spawn_gen=live-gate-teardown' "pr=$1" > "$LAB/state/live-task.meta"
}
printf '\nSCENARIO merged\n'
write_meta https://github.com/cli/cli/pull/14770
bin/fm-teardown.sh live-task
[ ! -f "$LAB/state/live-task.meta" ]
tasks-axi show live-task --file "$LAB/data/backlog.md" --full
(cd "$LAB/project" && treehouse status)
