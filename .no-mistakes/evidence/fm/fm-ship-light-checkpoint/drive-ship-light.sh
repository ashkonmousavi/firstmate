#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/tegris/.no-mistakes/evidence/01M4G0K80WBNTDBXT67M2SZ8F3
LAB="$ROOT/.test-phase/lab"
BASE="$ROOT/.test-phase"
export TMPDIR="$ROOT/.test-phase/tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB"
bin/fm-lab-home.sh create "$LAB"
trap 'rm -rf -- "$LAB"' EXIT
. tests/prep-record-helper.sh
. bin/fm-dod-lib.sh
: > "$EVIDENCE/live-transcript.log"
exec > >(tee -a "$EVIDENCE/live-transcript.log") 2>&1
printf 'Product head: '; git rev-parse HEAD
check_admit() {
  local label=$1 file=$2 expected=$3 path=${4:-current} output status
  if [ "$path" = historical ]; then
    if output=$(fm_prep_delivery_mode "$file" historical); then status=0; else status=$?; fi
  else
    if output=$(fm_prep_delivery_mode "$file"); then status=0; else status=$?; fi
  fi
  printf 'fm_prep_delivery_mode %s [%s]: exit=%s output=%s\n' "$label" "$path" "$status" "${output:-<empty>}"
  [ "$status" -eq "$expected" ]
  if [ "$expected" -eq 0 ]; then [ "$output" = direct-PR ]; fi
}
fm_test_prep_record "$LAB/data" quick no no no direct-PR
fm_test_prep_depth "$LAB/data/quick/prep.md" ship-light
PREP="$LAB/data/quick/prep.md"
sed 's/^- Delivery depth:.*$/- Delivery depth: ship-light (direct-PR), the completed live journey checkpoint covers the corrected control label./' "$PREP" > "$PREP.next"
mv "$PREP.next" "$PREP"
cp "$PREP" "$EVIDENCE/ship-light-prep.md"
check_admit quick "$PREP" 0
check_admit quick "$PREP" 0 historical
if red=$(bash -c '. "$1/bin/fm-dod-lib.sh"; fm_prep_delivery_mode "$2"' _ "$BASE" "$PREP"); then red_status=0; else red_status=$?; fi
printf 'BASE 44feb924 fm_prep_delivery_mode quick: exit=%s output=%s (expected rejection before change)\n' "$red_status" "${red:-<empty>}"
[ "$red_status" -eq 1 ]
for variant in money security shared-code q2-yes presentation-q2 missing-risk missing-checkpoint duplicate-depth smuggled-depth; do
  case "$variant" in
    money|security) sed "s/^- Delivery risk:.*$/- Delivery risk: $variant, changed behavior affects this risk./" "$PREP" ;;
    shared-code) sed 's/^- Delivery risk:.*$/- Delivery risk: shared code, changed logic has shared callers./' "$PREP" ;;
    q2-yes) sed -E 's/^(- Q2 .*): .*$/\1: yes/' "$PREP" ;;
    presentation-q2) sed -E -e 's/^(- Q2 .*): .*$/\1: yes/' -e 's/^- Delivery risk:.*$/- Delivery risk: other, presentation-only: moved the control./' "$PREP" ;;
    missing-risk) sed '/^- Delivery risk:/d' "$PREP" ;;
    missing-checkpoint) sed 's/^- Delivery depth:.*$/- Delivery depth: ship-light (direct-PR), /' "$PREP" ;;
    duplicate-depth) sed '/^- Delivery depth:/a\- Delivery depth: checks-only (direct-PR), try another depth.' "$PREP" ;;
    smuggled-depth) sed 's/^- Delivery depth:.*$/- Delivery depth: checks + one review (direct-PR), ship-light (direct-PR) because a walk covers it./' "$PREP" ;;
  esac > "$LAB/$variant.md"
  check_admit "$variant" "$LAB/$variant.md" 1
  check_admit "$variant" "$LAB/$variant.md" 1 historical
  cp "$LAB/$variant.md" "$LAB/data/quick/prep.md"
  if output=$(bin/fm-spawn.sh quick "$LAB/projects/check" claude --mode direct-PR --yolo off 2>&1); then spawn_status=0; else spawn_status=$?; fi
  printf 'fm-spawn.sh quick --mode direct-PR [%s]: exit=%s\n%s\n' "$variant" "$spawn_status" "$output"
  [ "$spawn_status" -ne 0 ]
  printf '%s' "$output" | grep -E 'Delivery risk|Delivery depth|preparation record' >/dev/null
  [ ! -f "$LAB/state/quick.meta" ]
  cp "$EVIDENCE/ship-light-prep.md" "$PREP"
done
# The base renders the ordinary review/wait contract for this same authored record.
bash -c '. "$1/bin/fm-dod-lib.sh"; fm_worker_contract_block "$2" "$3/data" "$3/state" "$3/config" quick ship direct-PR fm/quick none' _ "$BASE" "$ROOT" "$LAB" > "$EVIDENCE/base-worker-contract.md"
grep -F 'Perform exactly one code review round' "$EVIDENCE/base-worker-contract.md"
grep -F 'Wait for every required check on the current PR head' "$EVIDENCE/base-worker-contract.md"
printf 'BASE quick worker output: ordinary review and hosted wait remain (RED for ship-light).\n'
# Follow the actual executable contract emitted by the fresh-brief CLI.
bin/fm-brief.sh quick check --mode direct-PR
cp "$LAB/data/quick/brief.md" "$EVIDENCE/fresh-brief.md"
command=$(sed -n '/^```bash$/,/^```$/p' "$LAB/data/quick/brief.md" | sed '1d;$d')
bash -c "$command" > "$EVIDENCE/fresh-worker-contract.md"
grep -F 'Delivery contract: mode=direct-PR' "$EVIDENCE/fresh-worker-contract.md"
grep -F 'Run only the tests of the modules you changed' "$EVIDENCE/fresh-worker-contract.md"
grep -F 'lands it on green ordinary checks' "$EVIDENCE/fresh-worker-contract.md"
! grep -F 'Perform exactly one code review round' "$EVIDENCE/fresh-worker-contract.md"
! grep -F 'Wait for every required check on the current PR head' "$EVIDENCE/fresh-worker-contract.md"
grep -F 'done [at=<epoch>]: PR {full https URL from the forge}' "$EVIDENCE/fresh-worker-contract.md"
grep -F 'not a draft' "$EVIDENCE/fresh-worker-contract.md"
# Exercise real promotion CLI, inspecting its published agent-message contract
# and durable metadata. No fm-send or worker impersonation is used.
bin/fm-brief.sh promote check --scout
python3 - "$LAB/data/promote/brief.md" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text().replace('{TASK}', 'Correct the control label covered by the completed live walk.').replace('{FIRSTMATE_SPEC}', 'Preserve the checkpoint-covered quick-fix scope.'))
PY
fm_test_prep_record "$LAB/data" promote no no no direct-PR
fm_test_prep_depth "$LAB/data/promote/prep.md" ship-light
printf 'kind=scout\nwindow=fm-promote\nworktree=%s\n' "$ROOT" > "$LAB/state/promote.meta"
bin/fm-promote.sh promote --mode direct-PR --yolo off
cp "$LAB/data/promote/ship-instructions.md" "$EVIDENCE/promotion-worker-contract.md"
cp "$LAB/data/promote/brief.md" "$EVIDENCE/promoted-relaunch-brief.md"
cp "$LAB/state/promote.meta" "$EVIDENCE/promotion.meta"
cat "$LAB/state/promote.meta"
grep -F 'Delivery contract: mode=direct-PR' "$EVIDENCE/promotion-worker-contract.md"
grep -F 'lands it on green ordinary checks' "$EVIDENCE/promotion-worker-contract.md"
! grep -F 'Perform exactly one code review round' "$EVIDENCE/promotion-worker-contract.md"
! grep -F 'Wait for every required check on the current PR head' "$EVIDENCE/promotion-worker-contract.md"
grep -F 'This is a ship-light fix' "$EVIDENCE/promoted-relaunch-brief.md"
# Existing modes must render byte-identically to base at the same interface.
for mode in direct-PR no-mistakes local-only; do
  fm_dod_block "$mode" ordinary fm/ordinary none > "$EVIDENCE/head-$mode.md"
  bash -c '. "$1/bin/fm-dod-lib.sh"; fm_dod_block "$2" ordinary fm/ordinary none' _ "$BASE" "$mode" > "$EVIDENCE/base-$mode.md"
  cmp "$EVIDENCE/base-$mode.md" "$EVIDENCE/head-$mode.md"
  printf 'fm_dod_block %s: base/head emitted contract byte-identical\n' "$mode"
done
# Preserve explicitly accepted Gerrit waiver, without publishing a change.
fm_dod_block direct-PR gerrit-check fm/gerrit-check gerrit '' ship-light > "$EVIDENCE/gerrit-worker-contract.md"
! grep -F 'Perform exactly one code review round' "$EVIDENCE/gerrit-worker-contract.md"
grep -F 'gerrit-axi publish --squash' "$EVIDENCE/gerrit-worker-contract.md"
printf 'Live public-interface scenarios complete. Lab removed by EXIT trap.\n'
