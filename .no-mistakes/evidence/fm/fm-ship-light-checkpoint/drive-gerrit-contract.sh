#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.test-phase/gerrit-lab"
EVIDENCE=/home/tegris/.no-mistakes/evidence/01M4G0K80WBNTDBXT67M2SZ8F3
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" TMPDIR="$ROOT/.test-phase/tmp"
bin/fm-lab-home.sh create "$LAB"
trap 'rm -rf -- "$LAB"' EXIT
mkdir -p "$LAB/data/gerrit-quick"
cp "$EVIDENCE/ship-light-prep.md" "$LAB/data/gerrit-quick/prep.md"
bin/fm-brief.sh gerrit-quick check --mode direct-PR --forge gerrit --shape squash
command=$(sed -n '/^```bash$/,/^```$/p' "$LAB/data/gerrit-quick/brief.md" | sed '1d;$d')
bash -c "$command" > "$EVIDENCE/gerrit-worker-contract.md"
grep -F 'Delivery contract: mode=direct-PR forge=gerrit shape=squash' "$EVIDENCE/gerrit-worker-contract.md"
grep -F 'Run only the tests of the modules you changed' "$EVIDENCE/gerrit-worker-contract.md"
! grep -F 'Perform exactly one code review round' "$EVIDENCE/gerrit-worker-contract.md"
grep -F 'gerrit-axi publish --squash' "$EVIDENCE/gerrit-worker-contract.md"
