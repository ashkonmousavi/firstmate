#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB="$ROOT/.gate-live-home"
EVIDENCE=~/.no-mistakes/evidence/01M5J5C380C8ZB801RAERAHSHE
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/gh" "$LAB/xdg"
printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$LAB/data/backlog.md"
tasks-axi add task-live 'Disposable unreadable PR check' --kind ship --file "$LAB/data/backlog.md" >/dev/null
tasks-axi start task-live --file "$LAB/data/backlog.md" >/dev/null
git init -q --bare "$LAB/projects/origin.git"
git init -q -b main "$LAB/projects/project"
git -C "$LAB/projects/project" -c user.email=test@example.invalid -c user.name=Test commit -q --allow-empty -m baseline
git -C "$LAB/projects/project" remote add origin "$LAB/projects/origin.git"
git -C "$LAB/projects/project" push -q -u origin main
git -C "$LAB/projects/project" worktree add -q -b fm/task-live "$LAB/projects/copy" main
cat > "$LAB/state/task-live.meta" <<META
harness=codex
worktree=$LAB/projects/copy
project=$LAB/projects/project
kind=ship
mode=local-only
pr=https://github.com/example/repo/pull/7
META
cp "$LAB/state/task-live.meta" "$LAB/before.meta"
for option in normal force keep-open; do
  args=(); case "$option" in force) args=(--force);; keep-open) args=(--keep-open);; esac
  rc=0
  env -u GH_TOKEN -u GITHUB_TOKEN -u GH_ENTERPRISE_TOKEN -u GITHUB_ENTERPRISE_TOKEN -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" GH_CONFIG_DIR="$LAB/gh" XDG_CONFIG_HOME="$LAB/xdg" timeout 35 bin/fm-teardown.sh task-live "${args[@]}" > "$EVIDENCE/live-unreadable-$option.log" 2>&1 || rc=$?
  cat "$EVIDENCE/live-unreadable-$option.log"
  printf 'option=%s exit=%s\n' "$option" "$rc"
  test "$rc" = 1
  test -f "$LAB/state/task-live.meta"
  tasks-axi show task-live --file "$LAB/data/backlog.md"
  git -C "$LAB/projects/copy" status --porcelain
  test -d "$LAB/projects/copy"
  printf 'record and copy retained\n'
done
