#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
OUT=~/.no-mistakes/evidence/01M6QG4GJ98YRTXTMHF63ZZK56
LAB=$(mktemp -d "$ROOT/.revert-lab.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bash bin/fm-lab-home.sh create "$LAB"
export FM_HOME="$LAB"
unset FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_BACKEND FM_GATE_REFUSE_BYPASS
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"
[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
mkdir -p "$LAB/projects/proj"
cat > "$LAB/data/backlog.md" <<'MD'
## In flight
- [ ] active - active blocker (repo: proj) (kind: scout)
## Queued
- [ ] free - a ready item, "quoted, title" (repo: proj) (kind: scout)
- [ ] wait-live - blocked by active work (repo: proj) (kind: scout) blocked-by: active
- [ ] after-done - completed blocker clears (repo: proj) (kind: scout) blocked-by: finished
- [ ] after-missing - absent blocker clears in restored readiness (repo: proj) (kind: scout) blocked-by: absent
## Done
- [x] finished - finished dependency (repo: proj) (kind: scout)
MD
for id in free wait-live after-done after-missing; do
  mkdir -p "$LAB/data/$id"
  printf '# Scout brief\n' > "$LAB/data/$id/brief.md"
  printf '# Verified preparation\n' > "$LAB/data/$id/prep.md"
  printf 'project=proj\nkind=scout\n' > "$LAB/data/$id/autolaunch-prep"
done
printf '\n--- Real task readiness before completing blocker ---\n'
bash bin/fm-tasks-axi.sh ready | tee "$OUT/ready-before.txt"
python3 - "$OUT/ready-before.txt" <<'PY'
import csv,sys
lines=open(sys.argv[1]).read().splitlines()
ids={next(csv.reader([line.strip()]))[0] for line in lines if line.startswith('  ') and not line.startswith('  - ')}
assert ids == {'free','after-done','after-missing'},ids
PY
printf '\n--- Scheduler prepared list excludes active blockers ---\n'
bash bin/fm-autolaunch.sh --list-prepared | tee "$OUT/prepared-before.txt"
python3 - "$OUT/prepared-before.txt" <<'PYCASE'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == ['free','after-done','after-missing']
PYCASE
printf '\n--- Real hold removes ready work from scheduler selection ---\n'
bash bin/fm-tasks-axi.sh hold free --kind parked --reason 'temporary verification hold'
bash bin/fm-autolaunch.sh --list-prepared | tee "$OUT/prepared-held.txt"
python3 - "$OUT/prepared-held.txt" <<'PYCASE'
from pathlib import Path
import sys
assert Path(sys.argv[1]).read_text().splitlines() == ['after-done','after-missing']
PYCASE
bash bin/fm-tasks-axi.sh unhold free
printf '\n--- Complete real task through wrapper ---\n'
bash bin/fm-tasks-axi.sh done active
bash bin/fm-tasks-axi.sh ready | tee "$OUT/ready-after.txt"
python3 - "$OUT/ready-after.txt" <<'PY'
import csv,sys
lines=open(sys.argv[1]).read().splitlines()
ids={next(csv.reader([line.strip()]))[0] for line in lines if line.startswith('  ') and not line.startswith('  - ')}
assert ids == {'free','wait-live','after-done','after-missing'},ids
PY
printf '\n--- Restored snapshot dependency view ---\n'
bash bin/fm-fleet-snapshot.sh --json > "$OUT/fleet-snapshot.json"
jq '.backlog.records | map(select(.id == "after-done" or .id == "after-missing" or .id == "wait-live") | {id,blocked_by_ids,unresolved_blocker_ids})' "$OUT/fleet-snapshot.json"
python3 - "$OUT/fleet-snapshot.json" <<'PY'
import json,sys
rows={r.get('id'):r for r in json.load(open(sys.argv[1]))['backlog']['records']}
assert rows['after-done']['unresolved_blocker_ids'] == []
assert rows['wait-live']['unresolved_blocker_ids'] == []
assert rows['after-missing']['unresolved_blocker_ids'] == ['absent']
PY
printf '\n--- Real candidate producer reads native ready output ---\n'
bash bin/fm-tasks-axi.sh ready | tee "$OUT/ready-native.txt"
bash bin/fm-autolaunch.sh --publish-candidates > "$OUT/candidates.json"
jq '{schema,complete,tasks:.sources.tasks,entries:[.entries[].owner.task]}' "$OUT/candidates.json"
python3 - "$OUT/candidates.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1])); assert x['sources']['tasks']['status']=='ok',x
assert {r['owner']['task'] for r in x['entries']}=={'free','wait-live','after-done','after-missing'},x
assert x['complete'] is False
PY
printf '\n--- Incomplete production evidence must refuse selection ---\n'
set +e
bash bin/fm-autolaunch.sh --join > "$OUT/join-incomplete.json"
rc=$?
set -e
cat "$OUT/join-incomplete.json"
test "$rc" -eq 75
jq -e '.status == "NO_PICK" and (.entries|length) == 0' "$OUT/join-incomplete.json" >/dev/null
printf '\n--- Malformed persisted publication must refuse selection ---\n'
printf '{"schema":"fm-seat-candidates/v1","complete":true,"entries":[' > "$LAB/state/autolaunch-steps.candidates"
set +e
bash bin/fm-autolaunch.sh --join > "$OUT/join-malformed.json"
rc=$?
set -e
cat "$OUT/join-malformed.json"
test "$rc" -eq 75
jq -e '.status == "NO_PICK" and (.entries|length) == 0 and .homes[0].status == "unavailable"' "$OUT/join-malformed.json" >/dev/null
printf '\nAll real CLI observations matched the restored pre-cut-13 contracts. Lab removed on exit.\n'
