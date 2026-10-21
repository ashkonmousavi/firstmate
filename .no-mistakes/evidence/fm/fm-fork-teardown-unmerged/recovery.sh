#!/usr/bin/env bash
set -eu
ROOT=$PWD
. tests/git-config-helpers.sh
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.test-phase-tmp"
LAB=$(mktemp -d "$TMPDIR/fm-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB" FM_BOOTSTRAP_NETWORK=skip
. bin/fm-tasks-axi-lib.sh
. bin/fm-backlog-transition-lib.sh
for forge in github gitlab; do
 case "$forge" in
 github) url=https://github.com/cli/cli/pull/14768 ;;
 gitlab) url=https://gitlab.com/example/repo/-/merge_requests/7 ;;
 esac
 for incomplete in 0 1; do
  id="replay-$forge-$incomplete"
  printf '\nSCENARIO %s\n' "$id"
  if [ ! -e "$LAB/data/backlog.md" ]; then
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
  fi
  tasks-axi add "$id" 'disposable merge recovery' --kind ship --file "$LAB/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$LAB/data/backlog.md" >/dev/null
  fm_backlog_close_marker_write "$LAB/state" "$id" "$LAB/data" "gen-$id" --await-merge --pr "$url"
  if [ "$incomplete" = 1 ]; then
   fm_backlog_close_marker_mark_cleanup_incomplete "$LAB/state" "$LAB/state/$id.backlog-close" "$id" "$LAB/data" "gen-$id" --await-merge --pr "$url"
  fi
  bin/fm-bootstrap.sh > "$LAB/bootstrap.log" 2>&1
  cat "$LAB/bootstrap.log"
  grep -F "kept the backlog item for $id open" "$LAB/bootstrap.log"
  if grep -F "kept the captain call for $id" "$LAB/bootstrap.log"; then exit 1; fi
  tasks-axi show "$id" --file "$LAB/data/backlog.md" --full
  [ ! -f "$LAB/state/$id.backlog-close" ]
 done
done
