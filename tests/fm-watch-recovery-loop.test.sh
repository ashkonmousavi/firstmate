#!/usr/bin/env bash
# Pin the recovery-loop bounds: one announcement per generation for Pi/OpenCode
# handling successors and for Claude's bare Stop-owned re-arms across goal-only
# turns, a handling successor that keeps supervising instead of going blind, and
# genuine queued, inbox, decision, and close work that still surfaces.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)
export NODE_NO_WARNINGS=1

install_pi_watch_extension_fixture() {
  local repo=$1
  mkdir -p \
    "$repo/.pi/extensions/lib" \
    "$repo/node_modules/@earendil-works/pi-coding-agent" \
    "$repo/node_modules/@earendil-works/pi-tui" \
    "$repo/node_modules/typebox" \
    "$repo/bin"
  cp "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" "$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-branch-dispatch.ts" "$repo/.pi/extensions/lib/fm-branch-dispatch.ts"
  cp "$ROOT/.pi/extensions/lib/fm-native-contract.ts" "$repo/.pi/extensions/lib/fm-native-contract.ts"
  cp "$ROOT/.pi/extensions/lib/fm-async-exec.ts" "$repo/.pi/extensions/lib/fm-async-exec.ts"
  cp "$ROOT/.pi/extensions/lib/fm-calm-visibility.ts" "$repo/.pi/extensions/lib/fm-calm-visibility.ts"
  cp "$ROOT/.pi/extensions/lib/fm-operational-input.ts" "$repo/.pi/extensions/lib/fm-operational-input.ts"
  cp "$ROOT/bin/fm-operational-input.sh" "$repo/bin/fm-operational-input.sh"
  chmod +x "$repo/bin/fm-operational-input.sh"
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/package.json" <<'JSON'
{"name":"@earendil-works/pi-coding-agent","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-coding-agent/index.js" <<'JS'
export function getMarkdownTheme() { return {}; }
export class UserMessageComponent {
  render() { return []; }
  invalidate() {}
}
JS
  cat > "$repo/node_modules/@earendil-works/pi-tui/package.json" <<'JSON'
{"name":"@earendil-works/pi-tui","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/@earendil-works/pi-tui/index.js" <<'JS'
export class Box {
  addChild() {}
  clear() {}
  setBgFn() {}
}
export class Container {}
export class Text {}
JS
  cat > "$repo/node_modules/typebox/package.json" <<'JSON'
{"name":"typebox","type":"module","exports":"./index.js"}
JSON
  cat > "$repo/node_modules/typebox/index.js" <<'JS'
export const Type = {
  Object(properties) {
    return { type: "object", properties, additionalProperties: false };
  },
};
JS
}

# T1: a lost --handling-delivered handshake must not re-announce forever.
# The real Pi extension drives the real arm/watcher, with only the handshake
# RPC forced to fail. After the first recovery follow-up, wait past the old
# ~52s loop period so a regression would emit a second follow-up.
test_unacknowledged_recovery_is_announced_once_per_generation() {
  local repo home plugin fakebin out status lock_pid messages
  repo="$TMP_ROOT/t1-root"
  home="$TMP_ROOT/t1-home"
  fakebin="$TMP_ROOT/t1-fakebin"
  mkdir -p "$repo/bin" "$home/state" "$home/config" "$fakebin"
  install_pi_watch_extension_fixture "$repo"
  plugin="$repo/.pi/extensions/fm-primary-pi-watch.ts"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$repo/bin/fm-watch-arm.sh" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = --handling-delivered ]; then
  exit 1
fi
export FM_ROOT_OVERRIDE="$ROOT"
export PATH="$fakebin:\$PATH"
exec "$ROOT/bin/fm-watch-arm.sh" "\$@"
SH
  chmod +x "$repo/bin/fm-watch-arm.sh"
  : > "$home/state/seed.meta"
  printf 'pending:downtime:seed.1.aaa\n' > "$home/state/.watcher-down"
  chmod 600 "$home/state/.watcher-down"
  printf '%s\t1\tcheck\tseed\tcheck: seed recovery\n' "$(date +%s)" > "$home/state/.wake-queue"
  out=$(
    PLUGIN="$plugin" FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
      FM_STATE_OVERRIDE="$home/state" PATH="$fakebin:$PATH" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      node --input-type=module 2>&1 <<'EOF'
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const prompts = [];
const pi = {
  on() {},
  registerCommand() {},
  registerTool(candidate) {
    if (candidate.name === "fm_watch_arm_pi") tool = candidate;
  },
  sendUserMessage: async (message) => {
    prompts.push(String(message));
  },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
if (!tool) throw new Error("Pi watch tool was not registered");
await tool.execute("tool-call-t1", {}, undefined, undefined, {});
const deadline = Date.now() + 75000;
let firstAt = 0;
while (Date.now() < deadline) {
  const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
  if (rearm.length > 1) {
    throw new Error(`unbounded recovery loop: ${rearm.length} rearm-resurface follow-ups`);
  }
  if (rearm.length === 1 && firstAt === 0) firstAt = Date.now();
  if (firstAt && Date.now() - firstAt >= 55000) break;
  await new Promise((resolve) => setTimeout(resolve, 200));
}
const rearm = prompts.filter((message) => message.includes("check: rearm-resurface"));
if (rearm.length !== 1) {
  throw new Error(`expected exactly one recovery follow-up, got ${rearm.length}: ${prompts.join(" || ")}`);
}
const lockPid = existsSync(`${process.env.FM_HOME}/state/.watch.lock/pid`)
  ? readFileSync(`${process.env.FM_HOME}/state/.watch.lock/pid`, "utf8").trim()
  : "";
if (!/^[0-9]+$/.test(lockPid)) throw new Error("successor watcher lock pid missing");
try {
  process.kill(Number(lockPid), 0);
} catch {
  throw new Error(`successor watcher ${lockPid} is not alive`);
}
const marker = readFileSync(`${process.env.FM_HOME}/state/.watcher-down`, "utf8").trim();
if (!marker.startsWith("announced:") && !marker.startsWith("pending:")) {
  throw new Error(`successor did not keep a live recovery episode: ${marker}`);
}
console.log(`T1_MESSAGES=${rearm.length}`);
console.log(`T1_LOCK_PID=${lockPid}`);
console.log(`T1_MARKER=${marker}`);
process.exit(0);
EOF
  )
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '%s\n' "$out"
  fi
  lock_pid=$(sed -n 's/^T1_LOCK_PID=//p' <<<"$out" | tail -1)
  messages=$(sed -n 's/^T1_MESSAGES=//p' <<<"$out" | tail -1)
  if [ -n "$lock_pid" ]; then
    kill -TERM "$lock_pid" 2>/dev/null || true
  fi
  expect_code 0 "$status" "an unacknowledged recovery must be announced at most once per generation: $out"
  [ "$messages" = 1 ] || fail "T1 did not report a single recovery follow-up: $out"
  pass "unacknowledged recovery is announced at most once per generation and the successor stays alive"
}

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# Claude's Stop hook (bin/fm-claude-stop-autoarm.sh) foregrounds a bare
# bin/fm-watch-arm.sh on every Stop - no predecessor pid, so never a handling
# successor - and defers while its own earlier claim is still live. One
# goal-evaluator-only turn is modelled the same way: launch a bare arm only
# when the previous one has exited, then wait past the new cycle's first poll,
# where resurface_after_downtime speaks.
STOP_ARM_PID=
STOP_ARM_COUNT=0
OPEN_DECISION='t1 [key=t1-signoff] needs-decision: t1 is held for captain sign-off'

stop_rearm() {  # <case-dir>
  local dir=$1 out i
  if [ -n "$STOP_ARM_PID" ] && is_live_non_zombie "$STOP_ARM_PID"; then
    return 0
  fi
  STOP_ARM_COUNT=$((STOP_ARM_COUNT + 1))
  out="$dir/stop-arm-$STOP_ARM_COUNT.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/state" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)' \
    FM_FAKE_TMUX_CAPTURE="$dir/idle.capture" \
    FM_TASK_INBOX_GRACE_SECS=1 FM_TASK_INBOX_RING_MAX=1 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-arm.sh" > "$out" 2>&1 &
  STOP_ARM_PID=$!
  i=0
  while [ "$i" -lt 60 ]; do
    is_live_non_zombie "$STOP_ARM_PID" || break
    grep -q '^watcher: \(started\|attached\) ' "$out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  sleep 2
  if ! is_live_non_zombie "$STOP_ARM_PID"; then
    wait "$STOP_ARM_PID" 2>/dev/null || true
  fi
}

stop_rearm_count() {  # <case-dir> -> rearm-resurface wakes across every Stop arm
  cat "$1"/stop-arm-*.out 2>/dev/null | grep -c 'check: rearm-resurface' || true
}

stop_rearm_teardown() {  # <case-dir>
  local lockpid
  if [ -n "$STOP_ARM_PID" ] && is_live_non_zombie "$STOP_ARM_PID"; then
    kill -TERM "$STOP_ARM_PID" 2>/dev/null || true
    wait "$STOP_ARM_PID" 2>/dev/null || true
  fi
  STOP_ARM_PID=
  lockpid=$(cat "$1/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$lockpid" ] && is_live_non_zombie "$lockpid"; then
    kill -TERM "$lockpid" 2>/dev/null || true
  fi
}

goal_fail() {  # <case-dir> <message>
  stop_rearm_teardown "$1"
  fail "$2"
}

recovery_drain() {  # <case-dir> <name>
  FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/state" "$DRAIN" > "$1/$2.out" 2> "$1/$2.err"
}

# A case carrying one unresolved structured decision supervision has already
# seen, so it stays open across every down stretch as a live home's do.
goal_loop_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  mkdir -p "$dir/home/data"
  printf '╭────╮\n│    │\n╰────╯\n' > "$dir/idle.capture"
  printf 'needs-decision [key=t1-signoff]: t1 is held for captain sign-off\n' > "$dir/state/t1.status"
  prime_status_seen "$dir/state" "$dir/state/t1.status"
  printf '%s\n' "$dir"
}

# T3 (G3, no idle notification loop): once the legitimate recovery wake has
# been delivered, repeated goal-only Stop re-arms with no new work produce no
# further rearm-resurface wake, settle on one supervised cycle, and leave the
# durable queue, the open decision, and the recovery generation unchanged.
# Covers a goal-only turn that never drained and one that drained without
# acknowledging; both leave the episode announced.
test_goal_only_stop_rearms_do_not_repeat_a_delivered_recovery() {
  local mode dir state status_before first_launch rearms launched lockpid
  for mode in no-drain drain-without-ack; do
    dir=$(goal_loop_case "goal-only-$mode")
    state="$dir/state"
    printf 'pending:downtime:goal.1.aaa\n' > "$state/.watcher-down"
    chmod 600 "$state/.watcher-down"
    status_before=$(cksum < "$state/t1.status")
    STOP_ARM_PID=
    STOP_ARM_COUNT=0

    stop_rearm "$dir"
    grep -F 'check: rearm-resurface' "$dir/stop-arm-1.out" >/dev/null \
      || goal_fail "$dir" "$mode: the legitimate recovery was not announced: $(cat "$dir/stop-arm-1.out")"
    if [ "$mode" = drain-without-ack ]; then
      recovery_drain "$dir" drain \
        || goal_fail "$dir" "$mode: the recovery drain failed: $(cat "$dir/drain.err")"
      grep -F "$OPEN_DECISION" "$dir/drain.out" >/dev/null \
        || goal_fail "$dir" "$mode: the recovery drain did not fold the open decision"
      grep -F -- '--ack-through 0 --recovery-generation goal.1.aaa' "$dir/drain.err" >/dev/null \
        || goal_fail "$dir" "$mode: the recovery drain did not print its acknowledgement"
    fi

    first_launch=$STOP_ARM_COUNT
    for _ in 1 2 3 4; do
      stop_rearm "$dir"
    done
    rearms=$(stop_rearm_count "$dir")
    [ "$rearms" = 1 ] \
      || goal_fail "$dir" "$mode: goal-only Stop re-arms repeated the recovery wake with no new work ($rearms rearm-resurface wakes, expected 1)"
    launched=$((STOP_ARM_COUNT - first_launch))
    lockpid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
    if ! { [ "$launched" = 1 ] && is_live_non_zombie "$lockpid" \
      && grep -F "watcher: started pid=$lockpid" "$dir/stop-arm-$STOP_ARM_COUNT.out" >/dev/null; }; then
      goal_fail "$dir" "$mode: goal-only Stops did not settle on one live supervised cycle ($launched launched, lock pid ${lockpid:-none})"
    fi
    [ ! -s "$state/.wake-queue" ] \
      || goal_fail "$dir" "$mode: goal-only Stops changed the durable queue: $(cat "$state/.wake-queue")"
    [ "$(cksum < "$state/t1.status")" = "$status_before" ] \
      || goal_fail "$dir" "$mode: goal-only Stops changed the open decision's status log"
    [ "$(recovery_marker_generation "$state/.watcher-down")" = goal.1.aaa ] \
      || goal_fail "$dir" "$mode: goal-only Stops minted a new recovery generation: $(cat "$state/.watcher-down")"
    stop_rearm_teardown "$dir"
  done
  pass "goal-only Stop re-arms after a delivered recovery keep one supervised cycle and never repeat the recovery wake"
}

# T4 (genuine recovery is bounded, not suppressed): after the first recovery is
# handled and acknowledged, goal-only Stops stay quiet. Tearing the supervised
# cycle down is a genuine down stretch, announced exactly once even though that
# wake's drain-and-acknowledge handshake is lost while goal-only Stops keep
# re-arming: suppressing recovery whenever the queue is empty would announce it
# zero times, and re-opening at every start would repeat it.
test_genuine_down_stretch_is_announced_exactly_once_across_bare_rearms() {
  local dir state generation first_launch rearms launched lockpid
  dir=$(goal_loop_case genuine-down-stretch)
  state="$dir/state"
  printf 'pending:downtime:down.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  STOP_ARM_PID=
  STOP_ARM_COUNT=0

  stop_rearm "$dir"
  grep -F 'check: rearm-resurface' "$dir/stop-arm-1.out" >/dev/null \
    || goal_fail "$dir" "the first recovery was not announced: $(cat "$dir/stop-arm-1.out")"
  recovery_drain "$dir" handled \
    || goal_fail "$dir" "the handling drain failed: $(cat "$dir/handled.err")"
  ack_drain_err "$state" "$dir/handled.err" >/dev/null 2>&1 \
    || goal_fail "$dir" "the handled recovery could not be acknowledged"
  for _ in 1 2 3; do
    stop_rearm "$dir"
  done
  [ "$(stop_rearm_count "$dir")" = 1 ] \
    || goal_fail "$dir" "goal-only Stops re-announced a handled and acknowledged recovery"
  is_live_non_zombie "$STOP_ARM_PID" \
    || goal_fail "$dir" "no supervised cycle stayed live after the acknowledged recovery"

  kill -TERM "$STOP_ARM_PID" 2>/dev/null || true
  wait "$STOP_ARM_PID" 2>/dev/null || true
  generation=$(sed -n 's/^pending:downtime:\(.*\)$/\1/p' "$state/.watcher-down")
  [ -n "$generation" ] && [ "$generation" != down.1.aaa ] \
    || goal_fail "$dir" "tearing down the supervised cycle did not open a new recovery episode: $(cat "$state/.watcher-down")"

  first_launch=$STOP_ARM_COUNT
  for _ in 1 2 3 4 5; do
    stop_rearm "$dir"
  done
  rearms=$(( $(stop_rearm_count "$dir") - 1 ))
  [ "$rearms" = 1 ] \
    || goal_fail "$dir" "a genuine down stretch whose recovery handshake was lost was announced $rearms times across goal-only Stops, expected exactly 1"
  launched=$((STOP_ARM_COUNT - first_launch))
  lockpid=$(cat "$state/.watch.lock/pid" 2>/dev/null || true)
  if ! { [ "$launched" = 2 ] && is_live_non_zombie "$lockpid"; }; then
    goal_fail "$dir" "expected the recovery cycle plus one live supervised cycle, got $launched launched (lock pid ${lockpid:-none})"
  fi
  [ "$(recovery_marker_generation "$state/.watcher-down")" = "$generation" ] \
    || goal_fail "$dir" "goal-only Stops minted a new generation over the genuine episode: $(cat "$state/.watcher-down")"

  recovery_drain "$dir" late \
    || goal_fail "$dir" "the late drain failed: $(cat "$dir/late.err")"
  grep -F "$OPEN_DECISION" "$dir/late.out" >/dev/null \
    || goal_fail "$dir" "the genuine recovery did not fold the still-open decision"
  ack_drain_err "$state" "$dir/late.err" >/dev/null 2>&1 \
    || goal_fail "$dir" "the genuine recovery could not be acknowledged later"
  case "$(cat "$state/.watcher-down" 2>/dev/null || true)" in
    acked:*) ;;
    *) goal_fail "$dir" "the late acknowledgement did not retire the genuine episode" ;;
  esac
  stop_rearm_teardown "$dir"
  pass "a genuine down stretch is announced exactly once across bare re-arms, and a handled recovery stays quiet"
}

# T5 (pairing control for T3 and T4): the bound must not bury real work. Across
# bare Stop re-arms, work queued while no watcher ran, a pending steering-inbox
# record, an unresolved structured decision, and crew close work all surface.
test_bare_rearm_recovery_still_surfaces_queued_inbox_decision_and_close_work() {
  local dir state rec
  dir=$(goal_loop_case real-work)
  state="$dir/state"
  fm_write_meta "$state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=grok"
  : > "$state/t2.meta"
  rec=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_task_inbox_write "$2" t1 "please continue"' \
    _ "$ROOT/bin/fm-task-inbox-lib.sh" "$state") || fail "could not write the pending inbox record"
  touch -t 202001010000 "$rec"
  append_wake "$state" check downtime-row 'check: work queued while no watcher ran' \
    || fail "could not queue durable work"
  STOP_ARM_PID=
  STOP_ARM_COUNT=0

  stop_rearm "$dir"
  grep -F 'check: rearm-resurface' "$dir/stop-arm-1.out" >/dev/null \
    || goal_fail "$dir" "queued work did not trigger recovery: $(cat "$dir/stop-arm-1.out")"
  recovery_drain "$dir" recovery \
    || goal_fail "$dir" "the recovery drain failed: $(cat "$dir/recovery.err")"
  grep "$(printf '\tcheck\tdowntime-row\t')" "$dir/recovery.out" >/dev/null \
    || goal_fail "$dir" "recovery did not present the queued work"
  grep -F "$OPEN_DECISION" "$dir/recovery.out" >/dev/null \
    || goal_fail "$dir" "recovery did not fold the unresolved decision"
  ack_drain_err "$state" "$dir/recovery.err" >/dev/null 2>&1 \
    || goal_fail "$dir" "the recovery could not be acknowledged"

  stop_rearm "$dir"
  if is_live_non_zombie "$STOP_ARM_PID"; then
    wait_for_exit "$STOP_ARM_PID" 80 || true
  fi
  grep -F 'unread firstmate instruction:' "$dir/stop-arm-2.out" 2>/dev/null | grep -F "${rec##*/}" >/dev/null \
    || goal_fail "$dir" "the pending inbox record was not surfaced: $(cat "$dir/stop-arm-2.out")"
  [ -f "$rec" ] || goal_fail "$dir" "surfacing the inbox record consumed it"
  recovery_drain "$dir" inbox \
    || goal_fail "$dir" "the inbox drain failed: $(cat "$dir/inbox.err")"
  grep "$(printf '\tstale\tsess:fm-t1\t')" "$dir/inbox.out" >/dev/null \
    || goal_fail "$dir" "the inbox escalation was not durably queued"
  ack_drain_err "$state" "$dir/inbox.err" >/dev/null 2>&1 \
    || goal_fail "$dir" "the inbox escalation could not be acknowledged"

  for _ in 1 2 3; do
    stop_rearm "$dir"
  done
  [ "$(stop_rearm_count "$dir")" = 1 ] \
    || goal_fail "$dir" "handled real work was followed by a repeated recovery wake"
  is_live_non_zombie "$STOP_ARM_PID" \
    || goal_fail "$dir" "no supervised cycle stayed live after the real work was handled: $(cat "$dir/stop-arm-$STOP_ARM_COUNT.out")"
  printf 'done: t2 finished its task\n' >> "$state/t2.status"
  wait_for_exit "$STOP_ARM_PID" 100 \
    || goal_fail "$dir" "the supervised cycle did not surface crew close work"
  if ! { grep -q '^signal:' "$dir/stop-arm-$STOP_ARM_COUNT.out" \
    && grep -F 't2.status' "$dir/stop-arm-$STOP_ARM_COUNT.out" >/dev/null; }; then
    goal_fail "$dir" "crew close work was not surfaced as a signal: $(cat "$dir/stop-arm-$STOP_ARM_COUNT.out")"
  fi
  grep "$(printf '\tsignal\tt2.status\t')" "$state/.wake-queue" >/dev/null \
    || goal_fail "$dir" "crew close work was not durably queued"
  stop_rearm_teardown "$dir"
  pass "bare Stop re-arms still surface queued work, a pending inbox record, an open decision, and crew close work"
}

test_goal_only_stop_rearms_do_not_repeat_a_delivered_recovery
test_genuine_down_stretch_is_announced_exactly_once_across_bare_rearms
test_bare_rearm_recovery_still_surfaces_queued_inbox_decision_and_close_work
test_handling_successor_does_not_go_blind
test_unacknowledged_recovery_is_announced_once_per_generation
