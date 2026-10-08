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
for class in feature fix revert live-breakage none chore; do prep "no-jq-$class" "$class"; done
# Populate an isolated executable PATH with the existing system tools, excluding jq.
mkdir "$LAB/no-jq"
for tool in bash env dirname git find mkdir sed awk perl readlink realpath stat date cat tr id uname basename sleep head tail cut wc ps rm rmdir sort mv grep mktemp cmp touch cksum timeout; do
  exe=$(command -v "$tool") || continue
  ln -s "$exe" "$LAB/no-jq/$tool"
done
printf '\nSCENARIO no-jq-public-spawn\n'
for class in feature fix revert live-breakage none chore; do
  id="no-jq-$class"
  printf 'COMMAND: PATH=<workspace tools excluding jq> bin/fm-spawn.sh %s projects/Q --mode no-mistakes --yolo off --harness codex --backend tmux\n' "$id"
  rc=0
  out=$(PATH="$LAB/no-jq" bin/fm-spawn.sh "$id" projects/Q --mode no-mistakes --yolo off --harness codex --backend tmux 2>&1) || rc=$?
  printf '%s\nEXIT=%s\n' "$out" "$rc"
  [[ "$rc" != 0 ]] || exit 1
  case "$class" in
    feature) [[ "$out" == *'jq is required'* && "$out" != *'task set is locked'* ]] || exit 1 ;;
    none|chore) [[ "$out" == *'warning: start gate:'* && "$out" == *'jq is required'* && "$out" == *'task set is locked'* && "$out" != *'feature start permitted'* ]] || exit 1 ;;
    *) [[ "$out" == *"work class $class is never refused"* && "$out" == *'task set is locked'* ]] || exit 1 ;;
  esac
  [ ! -e "$LAB/state/$id.meta" ] && [ ! -e "$LAB/state/$id.inbox" ] && [ ! -e "$LAB/data/$id/launch-brief.md" ] || exit 1
  echo 'OBSERVED: dependency failure preserves authored repair/unknown-applicability boundaries; no allocation'
done
echo 'LIVE MISSING-JQ CHECKS COMPLETE; disposable lab removed by EXIT trap'
