#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.test-phase/spawn-lab"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" TMPDIR="$ROOT/.test-phase/tmp"
bin/fm-lab-home.sh create "$LAB"
trap 'rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/data/quick"
cp /home/tegris/.no-mistakes/evidence/01M4G0K80WBNTDBXT67M2SZ8F3/ship-light-prep.md "$LAB/data/quick/prep.md"
if output=$(bin/fm-spawn.sh quick "$LAB/projects/absent" claude --mode no-mistakes --yolo off 2>&1); then status=0; else status=$?; fi
printf 'fm-spawn.sh quick --mode no-mistakes: exit=%s\n%s\n' "$status" "$output"
[ "$status" -eq 1 ]
printf '%s' "$output" | grep -F 'selected --mode no-mistakes but declared Delivery depth: checks-only (direct-PR)' >/dev/null
[ ! -f "$LAB/state/quick.meta" ]
