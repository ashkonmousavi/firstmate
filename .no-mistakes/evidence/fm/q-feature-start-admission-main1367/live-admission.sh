#!/usr/bin/env bash
set -eu
ROOT=$PWD
EVIDENCE=/home/tegris/.no-mistakes/evidence/01M4DGV9CBW7VD4WRCHY5X7TZK
LAB=$(mktemp -d "$ROOT/.gate-live.XXXXXX")
trap 'rm -rf -- "$LAB"' EXIT
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_SPAWN_NO_GUARD FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID TMUX
export FM_HOME="$LAB"
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/projects/Q" "$LAB/projects/Other"
. "$ROOT/tests/prep-record-helper.sh"
STATE="$LAB/state"
. "$ROOT/bin/fm-wake-lib.sh"
# A real independent allocation lock prevents worker launch after admission.
fm_lock_try_acquire "$STATE/.task-set.lock"
NOW=$(date +%s)
FACTS="$LAB/facts.json"
UNOWNED='[{"id":"main-e2e-red","kind":"main-failure","detail":"main e2e failure","owner_task":null,"owner_state":null},{"id":"zenbook-frozen","kind":"frozen-machine","detail":"Zenbook has no working worker","owner_task":"zb-repair","owner_state":"paused"}]'
COVERED='[{"id":"main-e2e-red","kind":"main-failure","detail":"main e2e failure","owner_task":"main-repair","owner_state":"working"},{"id":"zenbook-frozen","kind":"frozen-machine","detail":"Zenbook has no working worker","owner_task":"zb-repair","owner_state":"working"}]'
map() { printf '{"Q":{"facts":"%s"}}\n' "$FACTS" > "$LAB/config/start-gate.json"; }
facts() { printf '{"schema":"fm-start-facts.v1","project":"Q","generated_at":%s,"causes":%s}\n' "${2:-$NOW}" "$1" > "$FACTS"; }
prep() {
  local id=$1 class=$2
  fm_test_prep_record "$LAB/data" "$id"
  if [ "$class" != none ]; then
    sed "/^## Tier$/a - Work class:$class" "$LAB/data/$id/prep.md" > "$LAB/data/$id/prep.new"
    mv "$LAB/data/$id/prep.new" "$LAB/data/$id/prep.md"
  fi
}
check() {
  local id=$1 class=$2 expected=$3 project=${4:-Q} rc=0 out
  prep "$id" "$class"
  printf '\nSCENARIO %s: class=%s project=%s\n' "$id" "$class" "$project"
  printf 'COMMAND: FM_HOME=<disposable marked lab> bin/fm-spawn.sh %s projects/%s --mode no-mistakes --yolo off --harness codex --backend tmux\n' "$id" "$project"
  out=$(bin/fm-spawn.sh "$id" "projects/$project" --mode no-mistakes --yolo off --harness codex --backend tmux 2>&1) || rc=$?
  printf '%s\nEXIT=%s\n' "$out" "$rc"
  [[ "$rc" != 0 && "$out" == *"$expected"* ]] || { echo 'ASSERTION FAILED: expected diagnostic absent'; exit 1; }
  [ ! -e "$LAB/state/$id.meta" ] && [ ! -e "$LAB/state/$id.inbox" ] && [ ! -e "$LAB/data/$id/launch-brief.md" ] || { echo 'ASSERTION FAILED: allocation occurred'; exit 1; }
  if [[ "$expected" != *'task set is locked'* && "$expected" != *'Delivery risk and Delivery depth'* ]]; then
    [[ "$out" != *'task set is locked'* ]] || { echo 'ASSERTION FAILED: gate refusal reached allocation guard'; exit 1; }
  fi
  echo 'OBSERVED: no metadata, inbox, launch brief or endpoint allocated; existing task-set lock still held'
}
map; facts "$UNOWNED"
check unowned-feature feature 'no worker on main-failure main-e2e-red'
facts "$UNOWNED"
printf 'working [at=%s]: now repairing\n' "$NOW" > "$LAB/state/zb-repair.status"
check misleading-status feature 'owner: zb-repair, paused'
for class in fix revert live-breakage; do check "repair-$class" "$class" 'task set is locked'; done
facts "$COVERED"
check covered-feature feature 'task set is locked'
facts '[]'
check healthy-feature feature 'task set is locked'
for kind in missing badjson stale future badowner badstate wrong-project; do
  case "$kind" in
    missing) rm -f "$FACTS"; expect='facts unknown: no readable snapshot' ;;
    badjson) printf 'not json\n' > "$FACTS"; expect='snapshot is not valid JSON' ;;
    stale) facts '[]' "$((NOW-1000))"; expect='over the 900s limit' ;;
    future) facts '[]' "$((NOW+1000))"; expect='generated_at is in the future' ;;
    badowner) facts '[{"id":"main","kind":"main-failure","detail":"failure","owner_task":"../fake","owner_state":"working"}]'; expect='facts unknown: a cause lacks' ;;
    badstate) facts '[{"id":"main","kind":"main-failure","detail":"failure","owner_task":"repair","owner_state":"validating"}]'; expect='no worker on main-failure main' ;;
    wrong-project) facts '[]'; sed 's/"project":"Q"/"project":"Other"/' "$FACTS" > "$FACTS.new"; mv "$FACTS.new" "$FACTS"; expect='snapshot is for project "Other", not Q' ;;
  esac
  check "invalid-$kind" feature "$expect"
  for class in fix revert live-breakage; do check "$kind-$class" "$class" 'task set is locked'; done
done
facts '[]'
for class in none xfix xrevert xlive-breakage xfeature 'f ix'; do check "class-$(printf '%s' "$class" | tr ' ' '-')" "$class" 'must declare one Tier line'; done
printf '[1]\n' > "$LAB/config/start-gate.json"
check malformed-feature feature 'is not one JSON object'
for class in none chore fix revert live-breakage; do check "malformed-$class" "$class" 'task set is locked' Other; done
rm "$LAB/config/start-gate.json"; ln -s missing-map.json "$LAB/config/start-gate.json"
check dangling-feature feature 'is not one JSON object'
check dangling-fix fix 'task set is locked'
rm "$LAB/config/start-gate.json"; map; facts "$UNOWNED"
check unnamed-project none 'task set is locked' Other
rm "$LAB/config/start-gate.json"
check absent-map none 'task set is locked'
map; facts "$UNOWNED"
# An existing record and held control lock model a concurrent lifecycle action.
# The recovery invocation must reach that independent guard without health admission.
printf 'kind=ship\nharness=codex\nproject=%s\n' "$LAB/projects/Q" > "$LAB/state/existing.meta"
fm_lock_try_acquire "$LAB/state/.control-existing.lock"
printf '\nSCENARIO existing-work-recovery\nCOMMAND: bin/fm-spawn.sh existing --relaunch\n'
rc=0
out=$(bin/fm-spawn.sh existing --relaunch 2>&1) || rc=$?
printf '%s\nEXIT=%s\n' "$out" "$rc"
[[ "$rc" != 0 && "$out" == *'another lifecycle action is already running'* && "$out" != *'start gate:'* ]] || exit 1
cmp <(printf 'kind=ship\nharness=codex\nproject=%s\n' "$LAB/projects/Q") "$LAB/state/existing.meta"
echo 'OBSERVED: existing record unchanged; recovery bypassed feature health and respected its existing lifecycle guard'
printf '\nLIVE COMMAND ADMISSION CHECKS COMPLETE; disposable lab removed by EXIT trap\n'
