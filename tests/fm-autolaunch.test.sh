#!/usr/bin/env bash
# Behavior tests for bin/fm-autolaunch.sh and bin/fm-autolaunch-check.sh.
#
# A real markdown backlog drives bin/fm-tasks-axi.sh; capacity, spawn, and the
# dispatch resolver are replaced through the FM_TEST_SEAM hooks with fakes
# that record their calls. The quota gate reads fixture snapshots only.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v tasks-axi >/dev/null 2>&1 || fail 'tasks-axi is required for the autolaunch backlog fixtures'
TMP_ROOT=$(fm_test_tmproot fm-autolaunch)
AL="$ROOT/bin/fm-autolaunch.sh"
CHECK="$ROOT/bin/fm-autolaunch-check.sh"
H="$TMP_ROOT/home"
FAKE="$TMP_ROOT/fake"
mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$H/projects/qproj" "$FAKE"
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
free=$(cat "$FAKE_DIR/free"); echo $((free - 1)) > "$FAKE_DIR/free"
echo "spawned $id"
SH
# Fake resolver: $FAKE/resolve holds the stdout block (absent = off).
cat > "$FAKE/resolve" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_DIR/resolve.log"
[ -f "$FAKE_DIR/resolve" ] && cat "$FAKE_DIR/resolve"
[ -f "$FAKE_DIR/resolve" ] || echo 'dispatch-resolve: off' >&2
exit 0
SH
mv "$FAKE/resolve" "$FAKE/resolver"
chmod +x "$FAKE/capacity" "$FAKE/spawn" "$FAKE/resolver"
export FAKE_DIR="$FAKE" FM_AUTOLAUNCH_CAPACITY_BIN="$FAKE/capacity" \
  FM_AUTOLAUNCH_SPAWN_BIN="$FAKE/spawn" FM_AUTOLAUNCH_RESOLVE_BIN="$FAKE/resolver"
LOG="$H/state/autolaunch.log"

backlog() {  # writes the queued section lines given on stdin
  { printf '## In flight\n## Queued\n'; cat; printf '## Done\n- [x] old-done - finished (since 2026-10-01)\n'; } > "$H/data/backlog.md"
}
prep() {  # <id> <project> [extra key=value...]
  local id=$1 project=$2; shift 2
  mkdir -p "$H/data/$id"
  printf '# Task\nbrief for %s\n' "$id" > "$H/data/$id/brief.md"
  { printf 'project=%s\nkind=ship\nmode=direct-PR\nyolo=off\n' "$project"; printf '%s\n' "$@"; } > "$H/data/$id/autolaunch-prep"
}
reset() {
  rm -f "$LOG" "$FAKE"/spawn.log "$FAKE"/resolve.log "$FAKE"/rc-* "$FAKE/quota-refuse" "$FAKE/resolve" \
    "$H/config/autolaunch-exclude" "$H/config/crew-dispatch.json" "$H/state/.autolaunch-check.red"
  rm -rf "$H/data"/*/ "$H/state/spawn-deferred"
  printf '%s\n' "${1:-1}" > "$FAKE/free"
}
field() {  # <record-line> <n>
  printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'
}

# --- launch, J-01 first, stale blocked-by --------------------------------
reset 2
backlog <<'MD'
- [ ] plain-1 - ordinary piece (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] j-piece - J-01 step two (repo: proj) (kind: ship) (since 2026-10-30)
- [ ] after-done - waits on finished work blocked-by: old-done (repo: proj) (kind: ship) (since 2026-10-30)
MD
prep plain-1 proj; prep j-piece proj; prep after-done proj
out=$(bash "$AL" 2>&1); rc=$?
expect_code 0 "$rc" 'launch pass'
[ "$(wc -l < "$LOG")" -eq 2 ] || fail "two free lanes give two records, got: $(cat "$LOG")"
first=$(sed -n 1p "$LOG"); second=$(sed -n 2p "$LOG")
assert_equals "1" "$(field "$first" 2)" 'first record names lane 1'
assert_equals "j-piece" "$(field "$first" 3)" 'J-01 item launches first'
assert_equals "launched" "$(field "$first" 5)" 'first result'
assert_equals "static" "$(field "$first" 4)" 'no dispatch config: static crew harness'
assert_equals "plain-1" "$(field "$second" 3)" 'backlog order after J-01'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" "j-piece $H/projects/proj --mode direct-PR --yolo off" 'prep becomes spawn flags'
assert_not_contains "$(cat "$FAKE/spawn.log")" '--harness' 'no harness without dispatch config'
[ "$(grep -c . "$FAKE/spawn.log")" -eq 2 ] || fail 'spawn called once per free lane'
printf '%s\n' "$first" | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z	' || fail "record time is UTC ISO: $first"
assert_contains "$out" "$first" 'records are echoed on stdout'
pass 'free lanes launch J-01 first then backlog order, one launched record per lane'

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
  "- [ ] q-item - Q work (repo: qproj) (kind: ship) (since 2026-10-30)" \
  "- [ ] held-item - held (repo: proj) (kind: ship) (since 2026-10-30) (hold: parked: off the slices) (hold-kind: external) (hold-until: 2026-12-01)" \
  "- [ ] deferred-item - already deferred (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
mkdir -p "$H/data/no-prep"; printf 'brief\n' > "$H/data/no-prep/brief.md"
prep bad-prep proj 'colour=blue'
prep q-item qproj
prep held-item proj
prep deferred-item proj
mkdir -p "$H/state/spawn-deferred/queue"; printf 'schema=fm-deferred-spawn.v1\ntask=deferred-item\n' > "$H/state/spawn-deferred/queue/0001"
printf '# Q is parked\nqproj\n' > "$H/config/autolaunch-exclude"
bash "$AL" >/dev/null 2>&1
results=$(cut -f3,5 "$LOG")
assert_contains "$results" 'no-brief	refused:not prepared: no brief data/no-brief/brief.md' 'no brief'
assert_contains "$results" 'no-prep	refused:not prepared: no prep data/no-prep/autolaunch-prep' 'no prep'
assert_contains "$results" 'bad-prep	refused:not prepared: prep has unknown key colour' 'invalid prep'
assert_contains "$results" 'q-item	refused:excluded: qproj' 'exclusion list honoured'
assert_contains "$results" 'deferred-item	refused:spawn deferred pending' 'deferred retry is not doubled'
assert_not_contains "$results" 'held-item' 'held item is never a candidate'
assert_contains "$(tail -1 "$LOG")" '1	-	-	refused:no prepared item' 'running out of items is one record'
[ ! -f "$FAKE/spawn.log" ] || fail "no refused item is spawned: $(cat "$FAKE/spawn.log")"
pass 'unprepared, excluded, held and already-deferred items refuse with their reason and never spawn'

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
printf '%s\n' "- [ ] esc - needs approval (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep esc proj
printf 'dispatch-resolve:\n  status: escalate\n  reason: rule requires captain approval\n' > "$FAKE/resolve"
bash "$AL" >/dev/null 2>&1
assert_contains "$(head -1 "$LOG")" 'refused:dispatch escalate: rule requires captain approval' 'escalate is never launched'
[ ! -f "$FAKE/spawn.log" ] || fail 'escalated item spawned'
pass 'a resolver escalation refuses rather than guessing past the approval'

reset 1
printf '%s\n' "- [ ] routed - clear profile (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep routed proj
printf 'dispatch-resolve:\n  status: clear\n  profile: --harness codex --model gpt-5.5 --effort high\n' > "$FAKE/resolve"
printf '{"rules":[],"default":{"harness":"claude","model":"opus","effort":"low"}}\n' > "$H/config/crew-dispatch.json"
echo codex > "$FAKE/quota-refuse"
bash "$AL" >/dev/null 2>&1
assert_equals "claude:opus	launched" "$(cut -f4,5 "$LOG" | head -1)" 'quota refusal requeues on the next profile'
assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex --model gpt-5.5 --effort high' 'clear profile tried first'
assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness claude --model opus --effort low' 'configured default tried next'
assert_contains "$(cat "$FAKE/resolve.log")" "$H/data/routed/brief.md --project proj" 'resolver reads the item brief'
echo claude >> "$FAKE/quota-refuse"
rm -f "$LOG"; echo 1 > "$FAKE/free"
bash "$AL" >/dev/null 2>&1
assert_contains "$(head -1 "$LOG")" 'refused:quota: error: fm-spawn refuses explicit harness claude' 'all candidates exhausted is a quota refusal'
pass 'a clear profile launches first, a quota refusal moves to the next profile, all refused records quota'

reset 1
printf '%s\n' "- [ ] ranked - default array (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep ranked proj
printf '{"rules":[],"default":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"},{"harness":"grok"}]}\n' > "$H/config/crew-dispatch.json"
jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[])
      |= (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now")
    | (.providers[] | select(.provider == "grok") | .quotaSemantics.effectiveAvailability[].selection.spendPriority) = 5' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/quota.json"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/quota.json" bash "$AL" >/dev/null 2>&1
assert_equals "grok	launched" "$(cut -f4,5 "$LOG" | head -1)" 'highest spendPriority default launches'
assert_not_contains "$(cat "$FAKE/spawn.log")" 'claude' 'an exhausted default is never tried'
pass 'with no clear profile, defaults rank by spendPriority and exhausted ones are skipped'

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
echo 1 > "$FAKE/free"; rm -f "$H/data/waiting/autolaunch-prep"
out=$(FM_AUTOLAUNCH_CHECK_NOW=$NOW bash "$CHECK" 2>&1)
assert_equals '' "$out" 'no prepared item is silent'
pass 'throttle check is red only for free lane + prepared item + no recent record'

reset 1
printf '%s\n' "- [ ] waiting - prepared (repo: proj) (kind: ship) (since 2026-10-30)" | backlog
prep waiting proj
PARENT="$TMP_ROOT/parent"
mkdir -p "$PARENT/state"
printf 'mate-a\n' > "$H/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$H/.fm-secondmate-parent"
out=$(bash "$CHECK" 2>&1)
assert_contains "$out" 'RED auto-launch stalled' 'mate home still prints red'
if [ -f "$PARENT/state/mate-a.status" ]; then
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'blocked [at=' 'mate red reaches the parent channel'
  assert_contains "$(cat "$PARENT/state/mate-a.status")" 'RED auto-launch stalled' 'parent line carries the red text'
else
  fail "secondmate red line did not reach the parent channel"
fi
rm -f "$H/.fm-secondmate-home" "$H/.fm-secondmate-parent"
pass 'in a secondmate home the red line also reaches the parent channel'

out=$(bash "$CHECK" arm 2>&1) || fail "arm failed: $out"
assert_contains "$out" 'armed: state/autolaunch.check.sh' 'arm reports the shim'
assert_present "$H/state/autolaunch.check.sh" 'shim written'
assert_present "$H/state/autolaunch.check-trust" 'shim registered'
bash "$CHECK" disarm >/dev/null
assert_absent "$H/state/autolaunch.check.sh" 'disarm removes the shim'
out=$(bash "$AL" --print-timer)
assert_contains "$out" "Environment=FM_HOME=$H" 'timer proposal pins FM_HOME'
assert_contains "$out" 'OnUnitActiveSec=5min' 'timer proposal runs every five minutes'
pass 'the check arms through fm-check-register and the timer is only a printed proposal'
