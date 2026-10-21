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
write_meta https://github.com/cli/cli/pull/14768
for scenario in dirty unpushed; do
 printf '\nSCENARIO keep-open-%s\n' "$scenario"
 if [ "$scenario" = dirty ]; then
  printf 'dirty\n' >> "$WT/feature.txt"
 else
  printf "unpublished\n" > "$WT/unpublished.txt"
  git -C "$WT" add unpublished.txt
  git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -q -m unpushed
 fi
 cp "$LAB/state/live-task.meta" "$LAB/before.meta"
 rc=0
 bin/fm-teardown.sh live-task --keep-open || rc=$?
 printf 'exit=%s\n' "$rc"
 [ "$rc" -ne 0 ]
 cmp "$LAB/before.meta" "$LAB/state/live-task.meta"
 tasks-axi show live-task --file "$LAB/data/backlog.md" --full
 if [ "$scenario" = dirty ]; then git -C "$WT" restore feature.txt; fi
done
printf '\nSCENARIO discard-disposable-closed-work\n'
write_meta https://github.com/cli/cli/pull/14765
bin/fm-teardown.sh live-task --force
tasks-axi show live-task --file "$LAB/data/backlog.md" --full
