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
  sed '/^- Work class:/d' "$LAB/data/$id/prep.md" > "$LAB/data/$id/prep.new"
  mv "$LAB/data/$id/prep.new" "$LAB/data/$id/prep.md"
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
for field in risk depth; do
  id="invalid-delivery-$field"
  prep "$id" fix
  case "$field" in
    risk) sed 's/^- Delivery risk: /- Delivery risk:x/' "$LAB/data/$id/prep.md" > "$LAB/data/$id/prep.new" ;;
    depth) sed 's/^- Delivery depth: /- Delivery depth:x/' "$LAB/data/$id/prep.md" > "$LAB/data/$id/prep.new" ;;
  esac
  mv "$LAB/data/$id/prep.new" "$LAB/data/$id/prep.md"
  check "$id" fix 'Delivery risk and Delivery depth'
done
prep valid-delivery-no-space fix
sed -E 's/^(- Delivery (risk|depth):) /\1/' "$LAB/data/valid-delivery-no-space/prep.md" > "$LAB/data/valid-delivery-no-space/prep.new"
mv "$LAB/data/valid-delivery-no-space/prep.new" "$LAB/data/valid-delivery-no-space/prep.md"
check valid-delivery-no-space fix 'task set is locked'
printf '\nSCENARIO scout-on-unhealthy-Q\nCOMMAND: bin/fm-spawn.sh scout projects/Q --scout --harness codex --backend tmux\n'
rc=0
out=$(bin/fm-spawn.sh scout projects/Q --scout --harness codex --backend tmux 2>&1) || rc=$?
printf '%s\nEXIT=%s\n' "$out" "$rc"
[[ "$rc" != 0 && "$out" == *'task set is locked'* && "$out" != *'start gate:'* ]] || exit 1
[ ! -e "$LAB/state/scout.meta" ]
echo 'OBSERVED: scout bypassed feature health; no endpoint or record allocated'
# Drive the actual inherited-material receiver, using bytes/hash as its protocol.
printf '\nSCENARIO inherited-map-adoption\n'
cp "$LAB/config/start-gate.json" "$LAB/primary-map.json"
rm "$LAB/config/start-gate.json"
bytes=$(wc -c < "$LAB/primary-map.json" | tr -d ' ')
hash=$(sha256sum "$LAB/primary-map.json" | awk '{print $1}')
printf 'COMMAND: FM_HOME=<disposable lab> bin/fm-remote-inherit.sh put config/start-gate.json <bytes> <sha256> 1 < primary-map.json\n'
bin/fm-remote-inherit.sh put config/start-gate.json "$bytes" "$hash" 1 < "$LAB/primary-map.json"
cmp "$LAB/primary-map.json" "$LAB/config/start-gate.json"
echo 'OBSERVED: receiver persisted byte-identical applicability map'
check inherited-feature feature 'no worker on main-failure main-e2e-red'
: > "$LAB/empty"
hash=$(sha256sum "$LAB/empty" | awk '{print $1}')
printf 'COMMAND: bin/fm-remote-inherit.sh absent config/start-gate.json 0 <empty-sha256> 2\n'
bin/fm-remote-inherit.sh absent config/start-gate.json 0 "$hash" 2
[ ! -e "$LAB/config/start-gate.json" ]
check inheritance-absent none 'task set is locked'
echo 'SUPPLEMENTAL LIVE CHECKS COMPLETE; lab removed by EXIT trap'
