#!/usr/bin/env bash
# Behavior tests for bin/fm-autolaunch.sh and bin/fm-autolaunch-check.sh.
#
# A real markdown backlog drives bin/fm-tasks-axi.sh; capacity and spawn are
# replaced through the FM_TEST_SEAM hooks with fakes that record their calls.
# The quota gate reads fixture snapshots only.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for the autolaunch backlog fixtures'
TMP_ROOT=$(fm_test_tmproot fm-autolaunch)
AL="$ROOT/bin/fm-autolaunch.sh"
CHECK="$ROOT/bin/fm-autolaunch-check.sh"
H="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$FAKE"
fm_test_tasks_toml "$H/.tasks.toml"
export FM_HOME="$H"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TYPESAFE_API_KEY

# Fake capacity: free lanes from $FAKE/free; the fake spawn spends one.
cat > "$FAKE/capacity" <<'SH'
#!/usr/bin/env bash
free=$(cat "$FAKE_DIR/free")
if [ "$free" -gt 0 ]; then
  printf 'capacity: free_lanes=%s reason=ok lanes=1 target=4\n' "$free"; exit 0
fi
printf 'capacity: free_lanes=0 reason=full lanes=4 target=4\n'; exit 75
SH
# Fake spawn: argv to $FAKE/spawn.log; quota refusal for a harness named in
# $FAKE/quota-refuse; exit code from $FAKE/rc-<id>.
cat > "$FAKE/spawn" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/spawn.log"
id=$1; h=
while [ "$#" -gt 0 ]; do [ "$1" = --harness ] && h=$2; shift; done
if [ -n "$h" ] && [ -f "$FAKE_DIR/quota-refuse" ] && grep -qx "$h" "$FAKE_DIR/quota-refuse"; then
  echo "error: fm-spawn refuses explicit harness $h: provider $h runway exhausted_now. Best alternative: none." >&2; exit 1
fi
if [ -f "$FAKE_DIR/rc-$id" ]; then
  rc=$(cat "$FAKE_DIR/rc-$id")
  [ "$rc" = 75 ] && echo "deferred: project capacity for proj is held; task $id stays queued" >&2
  [ "$rc" = 1 ] && echo "error: brief mismatch for $id" >&2
  exit "$rc"
fi
[ ! -f "$FAKE_DIR/rotate-log" ] || mv "$FM_HOME/state/autolaunch.log" "$FM_HOME/state/autolaunch.previous.log"
free=$(cat "$FAKE_DIR/free"); echo $((free - 1)) > "$FAKE_DIR/free"
echo "spawned $id"
SH
chmod +x "$FAKE/capacity" "$FAKE/spawn"
export FAKE_DIR="$FAKE" FM_AUTOLAUNCH_CAPACITY_BIN="$FAKE/capacity" \
  FM_AUTOLAUNCH_SPAWN_BIN="$FAKE/spawn"
LOG="$H/state/autolaunch.log"

backlog() {  # writes the queued section lines given on stdin
  { printf '## In flight\n## Queued\n'; cat; printf '## Done\n- [x] old-done - finished (since 2026-10-01)\n'; } > "$H/data/backlog.md"
}
prep() {  # <id> <project> [extra key=value...]
  local id=$1 project=$2; shift 2
  mkdir -p "$H/data/$id"
  printf '# Task\nbrief for %s\n' "$id" > "$H/data/$id/brief.md"
  printf '# Prep\nprep for %s\n' "$id" > "$H/data/$id/prep.md"
  { printf 'project=%s\nkind=ship\nmode=direct-PR\nyolo=off\n' "$project"; printf '%s\n' "$@"; } > "$H/data/$id/autolaunch-prep"
}
reset() {
  rm -f "$LOG" "$FAKE"/spawn.log "$FAKE"/rc-* "$FAKE/quota-refuse" \
    "$H/config/crew-dispatch.json" "$H/state/.autolaunch-check.red" \
    "$H/config/crew-exclude-tools" "$H/config/pi-account" "$H/config/claude-account" \
    "$FAKE/rotate-log" "$H/state/autolaunch.previous.log" "$H/data/projects.md"
  rm -rf "$H/data"/*/ "$H/state/spawn-deferred"
  printf '%s\n' "${1:-1}" > "$FAKE/free"
}
field() {  # <record-line> <n>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# --- launch and stale blocked-by -------------------------------------------
reset 2
backlog <<'MD'
- [ ] plain-1 - ordinary piece (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] plain-2 - second ordinary piece (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] after-done - waits on finished work blocked-by: old-done (repo: proj) (kind: ship) (since 2026-10-30)
MD
prep plain-1 proj; prep plain-2 proj; prep after-done proj
out=$(bash "$AL" 2>&1); rc=$?
expect_code 0 "$rc" 'launch pass'
[ "$(wc -l < "$LOG")" -eq 2 ] || fail "two free lanes give two records, got: $(cat "$LOG")"
first=$(sed -n 1p "$LOG"); second=$(sed -n 2p "$LOG")
assert_equals "1" "$(field "$first" 2)" 'first record names lane 1'
assert_equals "plain-1" "$(field "$first" 3)" 'first ready item launches first'
assert_equals "launched" "$(field "$first" 5)" 'first result'
assert_equals "static" "$(field "$first" 4)" 'no dispatch config: static crew harness'
assert_equals "plain-2" "$(field "$second" 3)" 'second ready item launches second'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" "plain-1 $H/projects/proj --mode direct-PR --yolo off" 'prep becomes spawn flags'
assert_not_contains "$(cat "$FAKE/spawn.log")" '--harness' 'no harness without dispatch config'
assert_equals $'plain-1\nplain-2\nafter-done' "$(bash "$AL" --list-prepared)" 'prepared listing preserves ready-queue order'
[ "$(grep -c . "$FAKE/spawn.log")" -eq 2 ] || fail 'spawn called once per free lane'
printf '%s\n' "$first" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	' || fail "record time is UTC ISO: $first"
assert_contains "$out" "$first" 'records are echoed on stdout'
pass 'free lanes launch in ready-queue order, one launched record per lane'

reset 1
printf '%s\n' "- [ ] after-done - waits on finished work blocked-by: old-done (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] after-live - waits on queued work blocked-by: other-q (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] other-q - unprepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep after-done proj; prep after-live proj
bash "$AL" >/dev/null 2>&1
assert_equals "after-done	-	launched" "$(cut -f3,4,5 "$LOG" | head -1 | sed 's/	static	/	-	/')" 'blocked-by on finished work is not blocked'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'after-live' 'blocked-by on queued work is never launched'
pass 'a blocked-by edge to finished work clears; one to queued work blocks'

# --- refusal reasons -------------------------------------------------------
reset 1
printf '%s\n' "- [ ] no-brief - nothing prepared (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] no-prep - brief only (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] bad-prep - wrong prep (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] held-item - held (repo: proj) (kind: ship) (since 2026-10-30) (hold: parked: off the slices) (hold-kind: external) (hold-until: 2026-12-01)" \
  "- [ ] deferred-item - already deferred (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
mkdir -p "$H/data/no-prep"; printf 'brief\n' > "$H/data/no-prep/brief.md"
prep bad-prep proj 'colour=blue'
prep held-item proj
prep deferred-item proj
mkdir -p "$H/state/spawn-deferred/queue"; printf 'schema=fm-deferred-spawn.v1\ntask=deferred-item\n' > "$H/state/spawn-deferred/queue/0001"
bash "$AL" >/dev/null 2>&1
results=$(cut -f3,5 "$LOG")
assert_contains "$results" 'no-brief	refused:not prepared: no brief data/no-brief/brief.md' 'no brief'
assert_contains "$results" 'no-prep	refused:not prepared: no prep file (data/no-prep/prep.md or a Prep: data/<path> line in the item)' 'no prep file'
assert_contains "$results" 'bad-prep	refused:not prepared: record has unknown key colour' 'invalid override record'
assert_contains "$results" 'deferred-item	refused:spawn deferred pending' 'deferred retry is not doubled'
assert_not_contains "$results" 'held-item' 'held item is never a candidate'
assert_contains "$(tail -1 "$LOG")" '1	-	-	refused:no prepared item' 'running out of items is one record'
[ ! -f "$FAKE/spawn.log" ] || fail "no refused item is spawned: $(cat "$FAKE/spawn.log")"
pass 'unprepared, held and already-deferred items refuse with their reason and never spawn'

reset 1
printf '%s\n' '- [ ] foo.bar - literal task (repo: proj) (kind: ship)' \
  '- [ ] exact - deferred task (repo: proj) (kind: ship)' | backlog
prep foo.bar proj; prep exact proj
mkdir -p "$H/state/spawn-deferred/queue"
printf 'task=foo-bar\n' > "$H/state/spawn-deferred/queue/other"
printf 'task=exact\n' > "$H/state/spawn-deferred/queue/exact"
assert_equals 'foo.bar' "$(bash "$AL" --list-prepared)" 'deferred queue identity uses literal whole lines'
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$FAKE/spawn.log")" 'foo.bar ' 'regex-like task id remains launchable'
rm -f "$LOG" "$FAKE/spawn.log"; echo 1 > "$FAKE/free"
printf 'task=foo.bar\n' > "$H/state/spawn-deferred/queue/other"
assert_equals '' "$(bash "$AL" --list-prepared)" 'exact deferred identities are excluded from the list'
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" $'foo.bar\t-\trefused:spawn deferred pending' 'exact deferred identity is refused'
assert_absent "$FAKE/spawn.log" 'exact deferred tasks never spawn'
pass 'deferred identity contract distinguishes foo.bar from foo-bar in listing and launching'

reset 1
printf '%s\n' '- [ ] recorded - prepared (repo: proj) (kind: ship)' | backlog
prep recorded proj
printf 'existing record\n' > "$LOG"
chmod 0400 "$LOG"
out=$(bash "$AL" 2>&1); rc=$?
chmod 0600 "$LOG"
expect_code 1 "$rc" 'an unwritable log refuses before dispatch'
assert_absent "$FAKE/spawn.log" 'no launch without an open record destination'
assert_equals 'existing record' "$(cat "$LOG")" 'unwritable log is preserved'
touch "$FAKE/rotate-log"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$H/state/autolaunch.previous.log")" $'recorded\tstatic\tlaunched' 'records retain the opened log descriptor across rename'
assert_absent "$LOG" 'launch recording does not reopen the log path'
pass 'launches require a writable record destination and retain it for recording'

reset 0
printf '%s\n' "- [ ] ready-1 - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep ready-1 proj
bash "$AL" >/dev/null 2>&1
assert_equals "-	-	-	refused:no capacity: full" "$(cut -f2- "$LOG")" 'no capacity is one record'
[ ! -f "$FAKE/spawn.log" ] || fail 'no spawn without capacity'
pass 'a machine without a free lane records one no-capacity refusal and spawns nothing'

reset 2
printf '%s\n' "- [ ] proj-busy - project full (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] broken - spawn fails (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] fine - launches (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep proj-busy proj; prep broken proj; prep fine proj
echo 75 > "$FAKE/rc-proj-busy"; echo 1 > "$FAKE/rc-broken"
bash "$AL" >/dev/null 2>&1
results=$(cut -f2,3,5 "$LOG")
assert_contains "$results" '1	proj-busy	refused:deferred: deferred: project capacity for proj is held' 'spawn deferral recorded'
assert_contains "$results" '1	broken	refused:spawn error: error: brief mismatch for broken (exit 1)' 'spawn error recorded'
assert_contains "$results" '1	fine	launched' 'a lane survives a project deferral'
assert_contains "$(tail -1 "$LOG")" '2	-	-	refused:no prepared item' 'second lane has no item'
pass 'spawn deferral and spawn errors are recorded and the lane moves to the next item'

# --- dispatch and quota ------------------------------------------------------
reset 1
printf '%s\n' "- [ ] routed - default profiles (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep routed proj
printf '{"default":[{"harness":"codex","model":"gpt-5.5","effort":"high"},{"harness":"claude","model":"opus","effort":"low"}]}\n' > "$H/config/crew-dispatch.json"
jq '(.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 5' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/requeue-quota.json"
echo codex > "$FAKE/quota-refuse"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/requeue-quota.json" bash "$AL" >/dev/null 2>&1
assert_equals $'claude:opus\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" 'quota refusal requeues on the next default profile'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex --model gpt-5.5 --effort high' 'highest spendPriority default tried first'
assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness claude --model opus --effort low' 'next default tried after quota refusal'
echo claude >> "$FAKE/quota-refuse"
rm -f "$LOG"; echo 1 > "$FAKE/free"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/requeue-quota.json" bash "$AL" >/dev/null 2>&1
assert_contains "$(head -1 "$LOG")" 'refused:quota: error: fm-spawn refuses explicit harness claude' 'all candidates exhausted is a quota refusal'
pass 'a quota refusal advances through ranked defaults and all refused records quota'

reset 1
printf '%s\n' '- [ ] deterministic - prepared work (repo: proj) (kind: ship)' | backlog
prep deterministic proj
printf '{"rules":[{"when":"prepared work","approval":"captain","use":{"harness":"grok"}}],"default":{"harness":"codex","effort":"high"}}\n' > "$H/config/crew-dispatch.json"
cat > "$FAKE/curl" <<'SH'
#!/usr/bin/env bash
printf 'network call\n' >> "$FAKE_DIR/network.log"
exit 7
SH
chmod +x "$FAKE/curl"
out=$(TYPESAFE_API_KEY=synthetic-unused-key PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1); rc=$?
expect_code 0 "$rc" 'deterministic dry-run'
assert_contains "$out" '--harness codex --effort high' 'dry-run uses only the default profile'
assert_absent "$LOG" 'deterministic dry-run writes no record'
TYPESAFE_API_KEY=synthetic-unused-key PATH="$FAKE:$PATH" bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$FAKE/spawn.log")" '--harness codex --effort high' 'configured rules do not replace the default'
assert_absent "$FAKE/network.log" 'neither real nor dry passes call the model endpoint with a configured key'
rm "$FAKE/curl"
pass 'default-only dispatch ignores natural-language rules and makes no model request'

reset 1
printf '%s\n' '- [ ] no-default - prepared (repo: proj) (kind: ship)' | backlog
prep no-default proj
printf '{"rules":[{"when":"prepared","use":{"harness":"codex"}}]}\n' > "$H/config/crew-dispatch.json"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" 'refused:dispatch: no configured default' 'a configured file without defaults refuses'
assert_absent "$FAKE/spawn.log" 'configured rules alone never launch a static or rule profile'
pass 'static dispatch applies only when the dispatch file is absent'

reset 1
printf '%s\n' "- [ ] ranked - default array (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep ranked proj
printf '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"},{"harness":"grok"}]}\n' > "$H/config/crew-dispatch.json"
jq --arg generated "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
    .generatedAt = $generated
    | (.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[])
      |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    | (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].runway)
      = {status:"projected_exhaustion",projectionConfidence:"established",usableRunwaySeconds:60}
    | (.providers[] | select(.provider == "grok") | .quotaSemantics.effectiveAvailability[].selection.spendPriority) = 5' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/quota.json"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/quota.json" bash "$AL" >/dev/null 2>&1
assert_equals "grok	launched" "$(cut -f4,5 "$LOG" | head -1)" 'highest spendPriority default launches'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'claude' 'an exhausted default is never tried'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'codex' 'a short-runway default is never tried'
pass 'defaults rank by spendPriority and exhausted or short-runway profiles are skipped'

reset 0
printf '%s\n' '- [ ] snap-1 - prepared (repo: proj) (kind: ship)' \
  '- [ ] snap-2 - prepared (repo: proj) (kind: ship)' \
  '- [ ] snap-3 - prepared (repo: proj) (kind: ship)' | backlog
prep snap-1 proj; prep snap-2 proj; prep snap-3 proj
printf '{"default":[{"harness":"claude"}]}\n' > "$H/config/crew-dispatch.json"
cat > "$FAKE/quota-axi" <<SH
#!/usr/bin/env bash
echo call >> "$FAKE/quota-calls"
cat "$ROOT/tests/fixtures/quota-axi-healthy.json"
SH
chmod +x "$FAKE/quota-axi"
rm -f "$FAKE/quota-calls"
out=$(FM_QUOTA_SNAPSHOT_FILE='' PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t-\tsnap-3\tclaude\twould-launch-when-a-lane-frees' 'every item is ranked with zero capacity'
assert_equals 1 "$(wc -l < "$FAKE/quota-calls" | tr -d ' ')" 'a dry run over three items reads quota once'
rm -f "$FAKE/quota-calls"; printf '3\n' > "$FAKE/free"
FM_QUOTA_SNAPSHOT_FILE='' PATH="$FAKE:$PATH" bash "$AL" >/dev/null 2>&1
assert_equals 3 "$(wc -l < "$FAKE/spawn.log" | tr -d ' ')" 'three lanes launch three items'
assert_equals 1 "$(wc -l < "$FAKE/quota-calls" | tr -d ' ')" 'a real pass over three lanes reads quota once'
rm -f "$FAKE/quota-axi" "$FAKE/quota-calls"
pass 'one pass takes at most one quota snapshot'

reset 1
printf '%s\n' '- [ ] uncertain - prepared (repo: proj) (kind: ship)' | backlog
prep uncertain proj
printf '{"default":[{"harness":"opencode"},{"harness":"codex"},{"harness":"pi"}]}\n' > "$H/config/crew-dispatch.json"
printf 'opencode\ncodex\npi\n' > "$FAKE/quota-refuse"
bash "$AL" >/dev/null 2>&1
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex' 'a measured passing profile precedes uncertain profiles'
assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness opencode' 'first uncertain profile retains declared order'
assert_contains "$(sed -n 3p "$FAKE/spawn.log")" '--harness pi' 'second uncertain profile retains declared order'
pass 'uncertain defaults follow passing profiles in declared order'

for profile in '{"harness":"codex","effort":"high"}' \
  '{"harness":"codex","model":"gpt-5.5"}' '{"harness":"codex"}'; do
  reset 1
  printf '%s\n' '- [ ] fields - prepared (repo: proj) (kind: ship)' | backlog
  prep fields proj
  printf '{"default":%s}\n' "$profile" > "$H/config/crew-dispatch.json"
  expected='--harness codex'
  case "$profile" in
    *effort*) expected="$expected --effort high" ;;
    *model*) expected="$expected --model gpt-5.5" ;;
  esac
  out=$(bash "$AL" --dry-run 2>&1)
  assert_contains "$out" "$expected" 'dry-run preserves optional profile fields'
  assert_not_contains "$out" '--model high' 'effort never occupies the model field'
  bash "$AL" >/dev/null 2>&1
  assert_equals "fields $H/projects/proj --mode direct-PR --yolo off --branch-prefix fm/ $expected" "$(cat "$FAKE/spawn.log")" 'spawn flags preserve each profile field position'
done
pass 'profile contract preserves absent model and effort fields in the candidate reader'

for mode in no-mistakes direct-PR local-only; do
  for yolo in on off; do
    reset 1
    printf '%s\n' '- [ ] arguments - prepared ship (repo: proj) (kind: ship)' | backlog
    prep arguments proj "mode=$mode" "yolo=$yolo" branch_prefix=lane base_branch=curated
    bash "$AL" >/dev/null 2>&1
    assert_equals "arguments $H/projects/proj --mode $mode --yolo $yolo --branch-prefix lane --base-branch curated" "$(cat "$FAKE/spawn.log")" 'each ship delivery mode preserves its explicit arguments'
  done
done
reset 1
printf '%s\n' '- [ ] arguments - prepared scout (repo: proj) (kind: scout)' | backlog
prep arguments proj
printf 'project=proj\nkind=scout\nbase_branch=curated\n' > "$H/data/arguments/autolaunch-prep"
bash "$AL" >/dev/null 2>&1
assert_equals "arguments $H/projects/proj --scout --base-branch curated" "$(cat "$FAKE/spawn.log")" 'scouts receive the scout flag and shared base branch without ship flags'
pass 'ship and scout dispatch preserve their distinct argument contracts'

jq '(.providers[] | select(.provider == "zai").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 9' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/eligibility-quota.json"
for snapshot in "$FAKE/eligibility-quota.json" "$FAKE/missing-quota.json"; do
  for kind in ship scout; do
    for condition in tools pi-account claude-account kimi-capture codex-capture backend profile; do
      reset 1
      printf '%s\n' '- [ ] eligible - prepared (repo: proj) (kind: ship)' | backlog
      prep eligible proj
      [ "$kind" != scout ] || printf 'project=proj\nkind=scout\n' > "$H/data/eligible/autolaunch-prep"
      backend=tmux typed=0 expected=claude
      case "$condition" in
        tools)
          printf 'hidden_tool\n' > "$H/config/crew-exclude-tools"
          profiles='[{"harness":"codex"},{"harness":"pi","model":"zai/glm-5.3","provider":"zai"}]'
          expected=pi ;;
        pi-account)
          mkdir -p "$FAKE/pi-root"
          printf '%s\ncodex-native\n' "$FAKE/pi-root" > "$H/config/pi-account"
          profiles='[{"harness":"pi","model":"zai/glm-5.3","provider":"zai"},{"harness":"pi","model":"codex-native/gpt-6-astra","provider":"codex"}]'
          expected=pi ;;
        claude-account)
          printf '%s\n' "$FAKE/missing-account" > "$H/config/claude-account"
          profiles='[{"harness":"claude"},{"harness":"codex"}]'
          expected=codex ;;
        kimi-capture)
          backend=orca
          profiles='[{"harness":"kimi","provider":"codex"},{"harness":"claude"}]' ;;
        codex-capture)
          backend=paseo typed=1
          profiles='[{"harness":"codex"},{"harness":"claude"}]' ;;
        backend)
          backend=zellij
          profiles='[{"harness":"commandcode","provider":"codex"},{"harness":"claude"}]' ;;
        profile)
          profiles='[{"harness":"polytoken","provider":"codex"},{"harness":"claude"}]' ;;
      esac
      printf '{"default":%s}\n' "$profiles" > "$H/config/crew-dispatch.json"
      FM_BACKEND=$backend FM_CODEX_TYPED_LAUNCH=$typed FM_QUOTA_SNAPSHOT_FILE="$snapshot" bash "$AL" >/dev/null 2>&1
      assert_equals 1 "$(wc -l < "$FAKE/spawn.log" | tr -d ' ')" "only an eligible default is dispatched: $condition"
      assert_contains "$(cat "$FAKE/spawn.log")" "--harness $expected" "launch eligibility precedes ranking: $condition"
      if [ "$condition" = pi-account ]; then
        assert_contains "$(cat "$FAKE/spawn.log")" '--model codex-native/gpt-6-astra' 'configured provider restriction excludes the other Pi profile'
      fi
    done
  done
done
pass 'default eligibility honors tool, account, capture, backend and profile contracts with known or unavailable quota'

# --- derived launch record ----------------------------------------------------
reset 2
printf '%s\n' '- [ ] derived - brief contract wins (repo: proj) (kind: ship)' \
  '- [ ] derived-scout - scout brief (repo: proj) (kind: scout)' | backlog
bash "$ROOT/bin/fm-brief.sh" derived proj --mode direct-PR --branch-prefix lane/ --base-branch curated \
  --upstream-consent github.com/o/r --project "$H/projects/proj" >/dev/null || fail 'ship scaffold for derivation'
bash "$ROOT/bin/fm-brief.sh" derived-scout proj --scout --base-branch curated >/dev/null || fail 'scout scaffold for derivation'
rm -f "$H/data/derived/autolaunch-prep" "$H/data/derived-scout/autolaunch-prep"
printf 'prep\n' > "$H/data/derived/prep.md"; printf 'prep\n' > "$H/data/derived-scout/prep.md"
printf -- '- proj [no-mistakes +yolo branch=reg/] - test project (added 2026-10-01)\n' > "$H/data/projects.md"
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" "would-run: $FAKE/spawn derived $H/projects/proj --mode direct-PR --yolo on --branch-prefix lane/ --upstream-consent github.com/o/r --base-branch curated" 'fm-brief.sh ship contract lines win; yolo comes from the registry'
assert_contains "$out" "would-run: $FAKE/spawn derived-scout $H/projects/proj --scout --base-branch curated" 'fm-brief.sh scout base branch is carried'
reset 1
reset 1
printf '%s\n' '- [ ] reg-only - registry fallback (repo: proj) (kind: ship)' | backlog
mkdir -p "$H/data/reg-only"; printf '# Task\nplain brief\n' > "$H/data/reg-only/brief.md"; printf 'prep\n' > "$H/data/reg-only/prep.md"
printf -- '- proj [local-only branch=x/] - test project (added 2026-10-01)\n' > "$H/data/projects.md"
bash "$AL" >/dev/null 2>&1
assert_equals "reg-only $H/projects/proj --mode local-only --yolo off --branch-prefix x/" "$(cat "$FAKE/spawn.log")" 'registry supplies mode, yolo and branch prefix'
reset 1
printf '%s\n' '- [ ] override - record wins (repo: proj) (kind: ship)' | backlog
mkdir -p "$H/data/override"
printf 'Delivery contract: mode=direct-PR\nShip branch: fm/override\n' > "$H/data/override/brief.md"; printf 'prep\n' > "$H/data/override/prep.md"
printf 'yolo=on\nbranch_prefix=\n' > "$H/data/override/autolaunch-prep"
bash "$AL" >/dev/null 2>&1
assert_equals "override $H/projects/proj --mode direct-PR --yolo on --branch-prefix " "$(cat "$FAKE/spawn.log")" 'an override record replaces only the fields it names'
pass 'the launch record derives from override, brief lines, backlog row and project registry in that order'

# Laptop layout: X items with a prep file and a brief, beside unprepared work,
# in backlog order; a backlog priority does not reorder launches.
laptop_layout() {  # <free lanes>
  reset "$1"
  mkdir -p "$H/projects/NOT_Q" "$H/outside"
  printf '%s\n' \
    '- [ ] x-region-registry - X region registry (repo: NOT_Q) (kind: ship) (priority: 2)' \
    '  Prep: data/x-prep-region-registry/prep.md' \
    '- [ ] x-no-brief - prep but no brief (repo: NOT_Q) (kind: ship)' \
    '- [ ] x-ops-task - operational task (repo: NOT_Q) (kind: task)' \
    '- [ ] x-no-prep - brief but no prep (repo: NOT_Q) (kind: ship)' \
    '- [ ] x-plan-mention - mentions a plan without a Prep line (repo: NOT_Q) (kind: ship)' \
    '  drafts data/x-plan/plan.md' \
    '- [ ] x-escape - Prep line outside data (repo: NOT_Q) (kind: ship)' \
    '  Prep: data/../outside/prep.md' \
    '- [ ] x-engine-account-currency - X engine account currency (repo: NOT_Q) (kind: ship) (priority: 1)' | backlog
  printf -- '- NOT_Q [direct-PR branch=] - X (added 2026-10-01)\n' > "$H/data/projects.md"
  for id in x-region-registry x-engine-account-currency x-ops-task x-no-prep x-plan-mention x-escape; do
    mkdir -p "$H/data/$id"
    printf 'Delivery contract: mode=direct-PR\nShip branch: %s\n' "$id" > "$H/data/$id/brief.md"
  done
  mkdir -p "$H/data/x-prep-region-registry" "$H/data/x-no-brief" "$H/data/x-plan"
  printf 'prep\n' > "$H/data/x-prep-region-registry/prep.md"
  printf 'prep\n' > "$H/data/x-engine-account-currency/prep.md"
  printf 'prep\n' > "$H/data/x-ops-task/prep.md"
  printf 'prep\n' > "$H/data/x-no-brief/prep.md"
  printf 'plan\n' > "$H/data/x-plan/plan.md"
  printf 'prep\n' > "$H/outside/prep.md"
}
laptop_layout 2
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t1\tx-region-registry\tstatic\tlaunched' 'Prep-linked item, first in the backlog, would launch first'
assert_contains "$out" $'\t2\tx-no-brief\t-\trefused:not prepared: no brief data/x-no-brief/brief.md' 'no brief reason'
assert_contains "$out" $'\t2\tx-ops-task\t-\trefused:not prepared: kind task is not ship or scout' 'task kind reason'
assert_contains "$out" $'\t2\tx-no-prep\t-\trefused:not prepared: no prep file' 'no prep file reason'
assert_contains "$out" $'\t2\tx-plan-mention\t-\trefused:not prepared: no prep file' 'an unlabelled plan mention is not a prep file'
assert_contains "$out" $'\t2\tx-escape\t-\trefused:not prepared: no prep file' 'a Prep path escaping data/ is not a prep file'
assert_contains "$out" $'\t2\tx-engine-account-currency\tstatic\tlaunched' 'the later prepared item takes the second lane despite its priority'
assert_contains "$out" "x-engine-account-currency $H/projects/NOT_Q --mode direct-PR --yolo off --branch-prefix ''" 'bare branch from the brief'
pass 'a dry run on the laptop layout would launch the prepared X items in backlog order and names every refusal'

laptop_layout 1
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t1\tx-region-registry\tstatic\tlaunched' 'the free lane goes to the first prepared item'
for id in x-no-brief x-ops-task x-no-prep x-plan-mention x-escape; do
  assert_contains "$out" $'\t-\t'"$id"$'\t-\trefused:not prepared: ' "an item beyond the free lane still names its refusal: $id"
done
assert_contains "$out" $'\t-\tx-engine-account-currency\tstatic\twould-launch-when-a-lane-frees' 'a prepared item beyond the free lane waits for one'
assert_contains "$out" "would-run: $FAKE/spawn x-engine-account-currency $H/projects/NOT_Q" 'a waiting item still shows its spawn command'
bash "$AL" >/dev/null 2>&1
assert_equals "x-region-registry $H/projects/NOT_Q --mode direct-PR --yolo off --branch-prefix " "$(cat "$FAKE/spawn.log")" 'a real pass still stops at the free lanes'
assert_not_contains "$(cat "$LOG")" 'x-engine-account-currency' 'a real pass records nothing beyond the free lanes'
laptop_layout 0
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" $'\t-\t-\t-\trefused:no capacity: full' 'zero capacity is named first'
assert_contains "$out" $'\t-\tx-region-registry\tstatic\twould-launch-when-a-lane-frees' 'with no capacity the first prepared item waits'
assert_contains "$out" $'\t-\tx-engine-account-currency\tstatic\twould-launch-when-a-lane-frees' 'with no capacity the second prepared item waits'
assert_contains "$out" $'\t-\tx-no-brief\t-\trefused:not prepared: no brief data/x-no-brief/brief.md' 'with no capacity refusals are still named'
assert_not_contains "$out" 'no prepared item' 'no lane is reported open with zero capacity'
pass 'a dry run names every ready item beyond the free lanes and with no capacity'

reset 1
printf '%s\n' '- [ ] bf-new - derivable (repo: proj) (kind: ship)' \
  '- [ ] bf-kept - has a record (repo: proj) (kind: ship)' \
  '- [ ] bf-held - held but derivable (repo: proj) (kind: ship) (hold: wait) (hold-kind: captain)' \
  '- [ ] bf-skip - no prep (repo: proj) (kind: ship)' | backlog
printf -- '- proj [direct-PR +yolo] - test (added 2026-10-01)\n' > "$H/data/projects.md"
for id in bf-new bf-kept bf-held bf-skip; do mkdir -p "$H/data/$id"; printf 'brief\n' > "$H/data/$id/brief.md"; done
for id in bf-new bf-kept bf-held; do printf 'prep\n' > "$H/data/$id/prep.md"; done
printf 'yolo=off\n' > "$H/data/bf-kept/autolaunch-prep"
out=$(bash "$AL" --backfill 2>&1); rc=$?
expect_code 0 "$rc" 'backfill dry run'
assert_contains "$out" 'would-write: data/bf-new/autolaunch-prep: project=proj kind=ship mode=direct-PR branch_prefix=fm/' 'dry backfill prints the derived record without yolo'
assert_contains "$out" 'would-write: data/bf-held/autolaunch-prep' 'held items are backfilled too'
assert_contains "$out" 'kept: bf-kept' 'an existing record is kept'
assert_contains "$out" 'skip: bf-skip: no prep file' 'an underivable item names its reason'
assert_absent "$H/data/bf-new/autolaunch-prep" 'dry backfill writes nothing'
bash "$AL" --backfill --apply >/dev/null 2>&1 || fail 'backfill apply'
assert_equals $'project=proj\nkind=ship\nmode=direct-PR\nbranch_prefix=fm/' "$(cat "$H/data/bf-new/autolaunch-prep")" 'apply writes the derived record'
printf -- '- proj [direct-PR] - test (added 2026-10-01)\n' > "$H/data/projects.md"
out=$(bash "$AL" --dry-run 2>&1)
assert_contains "$out" "bf-new $H/projects/proj --mode direct-PR --yolo off" 'a backfilled record follows a later registry yolo change'
printf -- '- proj [direct-PR +yolo] - test (added 2026-10-01)\n' > "$H/data/projects.md"
assert_equals 'yolo=off' "$(cat "$H/data/bf-kept/autolaunch-prep")" 'apply never rewrites an existing record'
out=$(bash "$AL" --backfill --apply 2>&1)
assert_contains "$out" 'kept: bf-new' 'a second apply is idempotent'
assert_not_contains "$out" 'wrote:' 'a second apply writes nothing'
pass 'backfill prints first, writes only on --apply, and is idempotent'

reset 1
BH="$TMP_ROOT/brief-home"
mkdir -p "$BH/data" "$BH/state" "$BH/config" "$BH/projects/proj"
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-ship proj --mode direct-PR --branch-prefix lane/ --base-branch curated --project "$BH/projects/proj" >/dev/null || fail 'ship scaffold'
assert_equals $'project=proj\nkind=ship\nmode=direct-PR\nbranch_prefix=lane/\nbase_branch=curated' "$(cat "$BH/data/new-ship/autolaunch-prep")" 'ship scaffold writes its launch record'
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-scout proj --scout >/dev/null || fail 'scout scaffold'
assert_equals $'project=proj\nkind=scout' "$(cat "$BH/data/new-scout/autolaunch-prep")" 'scout scaffold writes its launch record'
rm -f "$BH/data/new-ship/brief.md"
FM_HOME=$BH bash "$ROOT/bin/fm-brief.sh" new-ship proj --scout >/dev/null || fail 're-scaffold as scout'
assert_equals $'project=proj\nkind=scout' "$(cat "$BH/data/new-ship/autolaunch-prep")" 'a re-scaffold replaces the stale kind and base branch'
assert_equals '' "$(find "$BH/data/new-ship" -name '.autolaunch-prep.*')" 'the record write leaves no temporary file'
pass 'fm-brief.sh writes the launch record for every ship and scout it scaffolds, replacing a stale one'

# --- dry-run and lock --------------------------------------------------------
reset 1
printf '%s\n' "- [ ] dry-item - prepared (repo: proj) (kind: ship) (since 2026-10-30)" \
  "- [ ] dry-unprep - unprepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep dry-item proj base_branch=curated upstream_consent=github.com/o/r
out=$(bash "$AL" --dry-run 2>&1); rc=$?
expect_code 0 "$rc" 'dry run'
assert_absent "$LOG" 'dry run writes no log'
[ ! -f "$FAKE/spawn.log" ] || fail 'dry run spawned'
[ ! -e "$H/state/.autolaunch.lock" ] || fail 'dry run took the lock'
assert_contains "$out" 'would-record: ' 'dry run prints records'
assert_contains "$out" 'dry-item	static	launched' 'dry run prints the launch decision'
assert_contains "$out" "would-run: " 'dry run prints the spawn command'
assert_contains "$out" '--upstream-consent github.com/o/r --base-branch curated' 'dry run command carries the prep flags'
list=$(bash "$AL" --list-prepared 2>&1)
assert_equals 'dry-item' "$list" 'list-prepared names only launchable items'
pass 'dry run prints decisions and commands and writes nothing'

reset 1
printf '%s\n' "- [ ] locked - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep locked proj
sleep 300 &
holder=$!
mkdir "$H/state/.autolaunch.lock"; printf '%s\n' "$holder" > "$H/state/.autolaunch.lock/pid"
out=$(bash "$AL" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect_code 0 "$rc" 'busy lock exits quietly'
assert_contains "$out" 'another pass holds' 'busy lock is named'
assert_absent "$LOG" 'busy lock writes no record'
[ ! -f "$FAKE/spawn.log" ] || fail 'second instance spawned'
rm -rf "$H/state/.autolaunch.lock"
bash "$AL" >/dev/null 2>&1
assert_contains "$(cat "$LOG")" 'locked' 'released lock lets the next pass run'
assert_absent "$H/state/.autolaunch.lock" 'a pass releases its lock'
pass 'a single-instance lock keeps a second pass from launching'

# --- throttle check ----------------------------------------------------------
reset 1
printf '%s\n' "- [ ] waiting - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep waiting proj
NOW=$(date +%s)
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'free lane + prepared item + no record is red'
assert_contains "$out" 'first: waiting' 'red names the item'
[ "$(printf '%s\n' "$out" | grep -c .)" -eq 1 ] || fail "red is one line: $out"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'one episode reports once'
out=$(FM_AUTOLAUNCH_CHECK_NOW=$((NOW + 3600)) bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'a continuing episode reports again after one hour'
printf 'x\n' > "$LOG"; fm_touch_epoch $((NOW - 300)) "$LOG"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'a recent record is silent'
assert_absent "$H/state/.autolaunch-check.red" 'quiet clears the episode'
fm_touch_epoch $((NOW - 700)) "$LOG"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_contains "$out" 'last record 11 min ago' 'a stale record is red'
rm -f "$H/state/.autolaunch-check.red"
echo 0 > "$FAKE/free"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'no free lane is silent'
echo 1 > "$FAKE/free"; rm -f "$H/data/waiting/prep.md"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'no prepared item is silent'
pass 'throttle check is red only for free lane + prepared item + no recent record'

reset 1
printf '%s\n' "- [ ] waiting - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep waiting proj
PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/state"
printf 'mate-a\n' > "$H/.fm-secondmate-home"
out=$(bash "$CHECK" 2>&1); rc=$?
expect_code 0 "$rc" 'evaluation remains a watcher-compatible success on parent delivery failure'
assert_contains "$out" 'parent delivery failed (exit 3); will retry' 'missing parent binding is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'failed delivery does not suppress retry'
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$H/.fm-secondmate-parent"
mkdir "$PARENT/state/mate-a.status"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'parent delivery failed (exit 4); will retry' 'parent append failure is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'failed append does not suppress retry'
rmdir "$PARENT/state/mate-a.status"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'mate home still prints red'
if [ -f "$PARENT/state/mate-a.status" ]; then
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'blocked [at=' 'mate red reaches the parent channel'
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'RED auto-launch stalled' 'parent line carries the red text'
else
  fail "secondmate red line did not reach the parent channel"
fi
assert_present "$H/state/.autolaunch-check.red" 'successful parent delivery publishes the episode marker'
out=$(bash "$CHECK" 2>&1)
assert_equals '' "$out" 'successful retry is throttled'
assert_equals 1 "$(wc -l < "$PARENT/state/mate-a.status" | tr -d ' ')" 'successful recovery delivers once'
rm -f "$H/state/.autolaunch-check.red" "$H/.fm-secondmate-home"
ln -s "$PARENT" "$H/.fm-secondmate-home"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'parent delivery failed (exit 2); will retry' 'unusable identity is surfaced'
assert_absent "$H/state/.autolaunch-check.red" 'unusable identity remains retryable'
rm -f "$H/.fm-secondmate-home" "$H/.fm-secondmate-parent"
pass 'in a secondmate home the red line also reaches the parent channel'

out=$(bash "$CHECK" arm 2>&1) || fail "arm failed: $out"
assert_contains "$out" 'armed: state/autolaunch.check.sh' 'arm reports the shim'
assert_present "$H/state/autolaunch.check.sh" 'shim written'
assert_present "$H/state/autolaunch.check-trust" 'shim registered'
out=$(bash "$CHECK" arm 2>&1) || fail "re-arm failed: $out"
assert_contains "$out" 'armed: state/autolaunch.check.sh' 'repeated arm refreshes registration'
chmod 0500 "$H/state"
out=$(bash "$CHECK" disarm 2>&1); rc=$?
chmod 0700 "$H/state"
expect_code 1 "$rc" 'failed unregistration propagates failure'
assert_not_contains "$out" 'disarmed:' 'failed unregistration never reports success'
assert_present "$H/state/autolaunch.check.sh" 'failed retirement preserves the check'
mv "$H/state/autolaunch.check-trust" "$H/state/original-trust"
ln -s "$H/state/original-trust" "$H/state/autolaunch.check-trust"
out=$(bash "$CHECK" disarm 2>&1); rc=$?
expect_code 1 "$rc" 'unregistration rejects unsafe trust artifacts'
assert_present "$H/state/autolaunch.check.sh" 'shared retirement validation runs before removal'
rm "$H/state/autolaunch.check-trust"
mv "$H/state/original-trust" "$H/state/autolaunch.check-trust"
bash "$CHECK" disarm >/dev/null
assert_absent "$H/state/autolaunch.check.sh" 'disarm removes the shim'
assert_absent "$H/state/autolaunch.check-trust" 'disarm retires trust through the shared owner'
bash "$CHECK" disarm >/dev/null || fail 'repeated disarm must succeed'
out=$(bash "$AL" --print-timer)
assert_contains "$out" "Environment=FM_HOME=$H" 'timer proposal pins FM_HOME'
assert_contains "$out" 'OnUnitActiveSec=5min' 'timer proposal runs every five minutes'
pass 'the check arms through fm-check-register and the timer is only a printed proposal'
