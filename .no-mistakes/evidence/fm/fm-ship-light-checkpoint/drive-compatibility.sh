#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/tegris/.no-mistakes/evidence/01M4G0K80WBNTDBXT67M2SZ8F3
LAB="$ROOT/.test-phase/compat-lab"
BASE="$ROOT/.test-phase"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$LAB" TMPDIR="$ROOT/.test-phase/tmp"
bin/fm-lab-home.sh create "$LAB"
trap 'rm -rf -- "$LAB"' EXIT
. tests/prep-record-helper.sh
. bin/fm-dod-lib.sh
bin/fm-brief.sh surgical --prep --surgical
PREP="$LAB/data/surgical/prep.md"
python3 - "$PREP" <<'PY'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); s=p.read_text()
for key, val in {'Q1':'no','Q2':'no','UI_WIRING':'no, confined CLI output in this disposable admission scenario.','Q1_REASON':'Disposable record concerns confined CLI output.','Q2_REASON':'Disposable record excludes shared behavior.'}.items():
    s=s.replace('{'+key+'}',val)
for c in ['C1','C2','C3','C4','C5']:
    s=s.replace('{'+c+'}','yes').replace('{'+c+'_EVIDENCE}', 'Disposable scenario certificate: owned output, direct caller lookup, scope exclusions and checkpoint cover the confined correction.')
p.write_text(s)
PY
fm_test_fill_prep_common "$PREP" direct-PR
fm_test_prep_depth "$PREP" ship-light
if reason=$(fm_prep_unfilled_reason "$PREP"); then complete=0; else complete=$?; fi
printf 'fm_prep_unfilled_reason surgical: exit=%s reason=%s (exit 1 + empty is complete)\n' "$complete" "${reason:-<empty>}"
[ "$complete" -eq 1 ] && [ -z "$reason" ]
printf 'fm_prep_delivery_mode surgical: '; fm_prep_delivery_mode "$PREP"
fm_prep_ship_light "$PREP"
cp "$PREP" "$EVIDENCE/surgical-ship-light-prep.md"
bin/fm-brief.sh surgical check --mode direct-PR
command=$(sed -n '/^```bash$/,/^```$/p' "$LAB/data/surgical/brief.md" | sed '1d;$d')
bash -c "$command" > "$EVIDENCE/surgical-worker-contract.md"
grep -F 'This is a ship-light fix' "$EVIDENCE/surgical-worker-contract.md"
# Historical risk omission remains compatible only for the ordinary depth.
fm_test_prep_depth "$PREP" direct-PR
sed '/^- Delivery risk:/d' "$PREP" > "$LAB/historical.md"
printf 'fm_prep_delivery_mode historical ordinary missing-risk: '; fm_prep_delivery_mode "$LAB/historical.md" historical
# Same real scout renderer and same input directories across base and head.
fm_worker_contract_block "$ROOT" "$LAB/data" "$LAB/state" "$LAB/config" scout-check scout '' '' none > "$EVIDENCE/head-scout-contract.md"
bash -c '. "$1/bin/fm-dod-lib.sh"; fm_worker_contract_block "$2" "$3/data" "$3/state" "$3/config" scout-check scout "" "" none' _ "$BASE" "$ROOT" "$LAB" > "$EVIDENCE/base-scout-contract.md"
cmp "$EVIDENCE/head-scout-contract.md" "$EVIDENCE/base-scout-contract.md"
printf 'Scout contract: base/head byte-identical.\n'
# Secondmate output comes from the unchanged executable scaffold, with its
# code-root parameter held constant to make literal placement paths comparable.
bin/fm-brief.sh mate --secondmate --no-projects
cp "$LAB/data/mate/brief.md" "$EVIDENCE/head-secondmate-brief.md"
rm "$LAB/data/mate/brief.md"
FM_ROOT_OVERRIDE="$ROOT" "$BASE/bin/fm-brief.sh" mate --secondmate --no-projects
cp "$LAB/data/mate/brief.md" "$EVIDENCE/base-secondmate-brief.md"
cmp "$EVIDENCE/head-secondmate-brief.md" "$EVIDENCE/base-secondmate-brief.md"
printf 'Secondmate charter: base/head byte-identical.\n'
