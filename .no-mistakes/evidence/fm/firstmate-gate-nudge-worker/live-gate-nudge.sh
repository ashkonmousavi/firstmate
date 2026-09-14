#!/usr/bin/env bash
# live-gate-nudge.sh - drive the watcher's gate-nudge ladder end to end.
#
# The real bin/fm-watch.sh and the real bin/fm-crew-state.sh supervise a real,
# isolated tmux server whose task window runs a fake `claude` worker process
# (it reads as a live agent to the backend, and logs every line typed into its
# pane). The only other fake is `no-mistakes` itself: its `axi status` answers
# from a mode file that the scenario, or the fake worker when it "responds",
# rewrites mid-run. Nothing is stubbed inside firstmate.
#
# Usage: live-gate-nudge.sh <repo-root> <evidence-dir> <scenario>
#   scenarios: ladder respond busyfix cigreen cidone axifail
set -u
ROOT=$1 EVID=$2 SCEN=$3
BASE=/tmp/fm-live-gate/$SCEN
GNS=${GNS:-6}
ID=live$SCEN
SES=fmlive
WIN="$SES:fm-$ID"
STATE=$BASE/state
LOG=$EVID/live-$SCEN.transcript.log
PANE=$EVID/live-$SCEN.pane.txt
rm -rf "$BASE"
mkdir -p "$STATE" "$BASE/home" "$BASE/agentbin" "$BASE/nmbin" "$BASE/sock" "$BASE/wt"
unset TMUX
export TMUX_TMPDIR=$BASE/sock
export FM_ROOT_OVERRIDE=$BASE/home
export GIT_AUTHOR_NAME=live GIT_AUTHOR_EMAIL=live@example.invalid
export GIT_COMMITTER_NAME=live GIT_COMMITTER_EMAIL=live@example.invalid
T0=$(date +%s)
FAILS=0
WPID=
: > "$LOG"
: > "$PANE"

say() { printf '[+%3ss] %s\n' "$(( $(date +%s) - T0 ))" "$*" | tee -a "$LOG"; }
check() { local desc=$1; shift; if "$@"; then say "PASS: $desc"; else say "FAIL: $desc"; FAILS=$((FAILS + 1)); fi; }
not() { ! "$@"; }
wait_until() { local secs=$1 i=0; shift; while [ "$i" -lt $((secs * 2)) ]; do "$@" && return 0; sleep 0.5; i=$((i + 1)); done; return 1; }
rings() { local n=0 f; for f in "$STATE/$ID.inbox"/*.msg "$STATE/$ID.inbox/handled"/*.msg; do [ -e "$f" ] && n=$((n + 1)); done; printf '%s' "$n"; }
rings_ge() { [ "$(rings)" -ge "$1" ]; }
rings_eq() { [ "$(rings)" -eq "$1" ]; }
doorbells() { local n; n=$(grep -c 'Firstmate instruction waiting' "$BASE/worker-input.log" 2>/dev/null) || n=0; printf '%s' "$n"; }
doorbells_ge() { [ "$(doorbells)" -ge "$1" ]; }
watcher_gone() { ! kill -0 "$WPID" 2>/dev/null; }
WOUT=watch.out
out_has() { grep -qF -- "$1" "$BASE/$WOUT" 2>/dev/null; }
out_empty() { [ ! -s "$BASE/$WOUT" ]; }
queue_empty() { [ ! -s "$STATE/.wake-queue" ]; }
queue_has() { grep -qF -- "$1" "$STATE/.wake-queue" 2>/dev/null; }
file_has() { grep -qF -- "$2" "$1" 2>/dev/null; }
stderr_clean() { not grep -Eq 'unexpected EOF|syntax error|command not found|unbound variable' "$BASE"/*.err; }
stale_rows() { local n; n=$(grep -cF "stale: $WIN" "$STATE/.wake-queue" 2>/dev/null) || n=0; printf '%s' "$n"; }
# Present and acknowledge everything a stopped watcher queued, exactly as a
# firstmate handling turn does before arming its successor watcher.
ack_cycle() {
  local err=$BASE/drain.err seq gen
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" >> "$BASE/drain.out" 2> "$err" || return 1
  cat "$err" >> "$BASE/drain.out"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  rm -f "$err"
  { [ -n "$seq" ] && [ -n "$gen" ]; } || return 1
  FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" \
    --recovery-generation "$gen" >> "$BASE/drain.out" 2>&1
}
record_identity() { cut -f4 "$STATE/.gate-nudge-$ID" 2>/dev/null; }
identity_is() { [ "$(record_identity)" = "$1" ]; }
head_n() { sed -n "${1}p" "$BASE/heads"; }
nm_mode() { printf '%s\n' "$*" > "$BASE/nm-mode"; say "no-mistakes run now reads: $*"; }
snap() {
  { printf '=== live tmux pane %s at +%ss (%s) ===\n' "$WIN" "$(( $(date +%s) - T0 ))" "$1"
    tmux capture-pane -p -J -t "$WIN" -S -80 2>/dev/null \
      | awk 'NF{last=NR} {l[NR]=$0} END{for(i=1;i<=last;i++) print l[i]}'
    echo; } >> "$PANE"
}

# --- the task worktree: a branch plus pipeline fix-round commits ------------
git -C "$BASE/wt" init -q -b "fm/$ID"
git -C "$BASE/wt" commit -q --allow-empty -m "task base"
prev=$(git -C "$BASE/wt" rev-parse HEAD)
tree=$(git -C "$BASE/wt" rev-parse 'HEAD^{tree}')
: > "$BASE/heads"
for n in 1 2 3 4; do
  # Descendants of the task HEAD, as a no-mistakes fix round leaves them.
  prev=$(git -C "$BASE/wt" commit-tree -p "$prev" -m "pipeline fix round $n" "$tree")
  printf '%s\n' "${prev:0:12}" >> "$BASE/heads"
done
git -C "$BASE/wt" update-ref refs/pipeline/tip "$prev"
printf '%s' "$ROOT" > "$BASE/root"
printf '%s' "$ID" > "$BASE/id"

# --- fake no-mistakes: inspection verbs only, answering from ../nm-mode -----
cat > "$BASE/nmbin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -u
D=$(cd "$(dirname "$0")/.." && pwd)
# Which firstmate process asked: the nearest fm-crew-state.sh or fm-watch.sh
# ancestor (only used to log calls, and by the parked-ladderfail fault).
caller=other
p=$PPID
for _ in 1 2 3 4 5 6 7 8; do
  [ -r "/proc/$p/cmdline" ] || break
  case "$(tr '\0' ' ' < "/proc/$p/cmdline")" in
    *fm-crew-state.sh*) caller=crew-state; break ;;
    *fm-watch.sh*) caller=watcher; break ;;
  esac
  p=$(awk '/^PPid:/{print $2}' "/proc/$p/status" 2>/dev/null)
  { [ -n "$p" ] && [ "$p" != 0 ]; } || break
done
read -r mode run_id head < "$D/nm-mode"
printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$caller" "$mode" "$PWD" "$*" >> "$D/nm-calls.log"
[ "${1:-}" = runs ] && exit 0
[ "${1:-} ${2:-}" = "axi status" ] || exit 2
branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
if [ "$mode" = parked-ladderfail ]; then
  # Fault: the watcher's own gate-identity read fails while crew-state's read
  # of the same run still reports the gate.
  [ "$caller" = crew-state ] || exit 1
  mode=parked
fi
case "$mode" in
  parked)
    printf 'run:\n  id: "%s"\n  branch: %s\n  status: awaiting_approval\n  awaiting_agent: parked 1m\n  head: "%s"\n  pr: ""\n  findings[2]{id,severity,file,line,action,description}:\n    r1,warning,a.go,,auto-fix,ignored error\n    r2,warning,b.go,,auto-fix,missing regression test\ngate: review\n' \
      "$run_id" "$branch" "$head" ;;
  fixing)
    printf 'run:\n  id: "%s"\n  branch: %s\n  status: fixing\n  head: "%s"\n  pr: ""\n' \
      "$run_id" "$branch" "$head" ;;
  green)
    printf 'run:\n  id: "%s"\n  branch: %s\n  status: completed\n  outcome: checks-passed\n  head: "%s"\n  pr: "https://github.com/example/repo/pull/7"\n' \
      "$run_id" "$branch" "$head" ;;
  *) exit 1 ;;
esac
SH
chmod +x "$BASE/nmbin/no-mistakes"

# --- fake worker agent (comm "claude", so the tmux backend reads it alive) --
cat > "$BASE/agentbin/claude" <<'SH'
#!/bin/bash
# Behaviour comes from ../worker-mode:
#   ignore   receives each doorbell and does nothing with it
#   respond  answers the FIRST doorbell: handles its record and responds to the
#            gate, so the run resumes (fixing) and its fix round re-parks on the
#            next pipeline head; ignores every later doorbell
#   busyfix  for the first two doorbells stays BUSY (claude-hook busy record)
#            while its fix round re-parks the run on the next head with the SAME
#            gate detail, never letting the run read as working; ignores later ones
D=$(cd "$(dirname "$0")/.." && pwd)
ROOT=$(cat "$D/root"); ID=$(cat "$D/id")
log() { printf '%s\t%s\n' "$(date +%s)" "$*" >> "$D/worker-events.log"; }
busy() {
  "$ROOT/bin/fm-busy-event.sh" apply "$D/state" "$ID" "$1" --current-gen \
    --source claude-hook --event "$2" >/dev/null 2>&1
  log "busy-record $1 rc=$?"
}
printf 'fake claude worker for %s - sitting at an empty prompt\n\n> ' "$ID"
k=0
while IFS= read -r line; do
  printf '%s\t%s\n' "$(date +%s)" "$line" >> "$D/worker-input.log"
  case "$line" in
    *"Firstmate instruction waiting"*) k=$((k + 1)); log "doorbell $k" ;;
    *) printf '> '; continue ;;
  esac
  read -r _ run_id head < "$D/nm-mode"
  wmode=$(cat "$D/worker-mode")
  case "$wmode" in
    respond|respondquiet|respondrace)
      # respond prints once more AFTER the fix round re-parks (its poll
      # returning), so the pane shows a new idle hash while the run is parked;
      # respondquiet prints nothing after the re-park, so the pane is unchanged;
      # respondrace re-parks and prints as soon as the watcher has read the run
      # as fixing (its gate probe and its triage read), so the new idle hash
      # lands inside the ladder's pacing window every time.
      if [ "$k" -eq 1 ]; then
        printf 'doorbell %s: reading the inbox record and responding to the gate\n' "$k"
        for f in "$D/state/$ID.inbox"/*.msg; do
          [ -e "$f" ] && mv "$f" "$D/state/$ID.inbox/handled/"
        done
        next=$(sed -n 2p "$D/heads")
        [ "$wmode" = respondquiet ] && printf 'responded; waiting on the fix round\n> '
        printf 'fixing %s %s\n' "$run_id" "$head" > "$D/nm-mode"; log "run -> fixing"
        if [ "$wmode" = respondrace ]; then
          i=0
          while [ "$(grep -c "$(printf '\tfixing\t')" "$D/nm-calls.log" 2>/dev/null)" -lt 2 ] && [ "$i" -lt 120 ]; do
            sleep 0.25; i=$((i + 1))
          done
          log "watcher has read the run as fixing"
          sleep 0.5
          wmode=respond
        else
          sleep 8
        fi
        printf 'parked %s %s\n' "$run_id" "$next" > "$D/nm-mode"; log "run -> parked at $next"
        [ "$wmode" = respond ] && printf 'responded; the fix round re-parked at a new gate\n> '
        continue
      fi ;;
    busyfix)
      if [ "$k" -le 2 ]; then
        busy busy agent-start
        printf 'doorbell %s: busy - answering the gate and polling in-turn\n' "$k"
        next=$(sed -n "$((k + 1))p" "$D/heads")
        sleep 2
        printf 'parked %s %s\n' "$run_id" "$next" > "$D/nm-mode"
        log "run -> parked at $next (same detail, never read as working)"
        sleep 4
        busy idle agent-end
        printf 'turn over\n> '
        continue
      fi ;;
  esac
  printf 'doorbell %s received - ignoring it\n> ' "$k"
done
SH
chmod +x "$BASE/agentbin/claude"

# --- task metadata, status log, and the live pane ---------------------------
printf 'window=%s\nkind=ship\nharness=claude\nworktree=%s\n' "$WIN" "$BASE/wt" > "$STATE/$ID.meta"
case "$SCEN" in
  cigreen) printf 'working: implementation committed\ndone: implemented the change, validating through no-mistakes\n' ;;
  cidone)  printf 'working: implementation committed\ndone: PR https://github.com/example/repo/pull/7 checks green\n' ;;
  *)       printf 'working: implementation committed, validating through no-mistakes\n' ;;
esac > "$STATE/$ID.status"
# Everything already in the log was surfaced before this watcher started.
FM_STATE_OVERRIDE="$STATE" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' \
  _ "$ROOT/bin/fm-wake-lib.sh" "$STATE" "$STATE/$ID.status"
echo ignore > "$BASE/worker-mode"
tmux new-session -d -s "$SES" -n "fm-$ID" -x 160 -y 45 "$BASE/agentbin/claude"
tmux set-window-option -t "$WIN" automatic-rename off >/dev/null
tmux set-window-option -t "$WIN" allow-rename off >/dev/null
sleep 1
say "scenario=$SCEN window=$WIN agent-state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source tmux; fm_backend_agent_state tmux "$2"' _ "$ROOT" "$WIN")"

start_watcher() {  # [VAR=value ...] overrides, applied after the defaults
  env PATH="$BASE/nmbin:$PATH" FM_STATE_OVERRIDE="$STATE" \
    FM_GATE_NUDGE_SECS="$GNS" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch.sh" > "$BASE/$WOUT" 2> "$BASE/${WOUT%.out}.err" &
  WPID=$!
  say "real bin/fm-watch.sh started (pid $WPID, FM_GATE_NUDGE_SECS=$GNS${*:+, $*}; default FM_STALE_ESCALATE_SECS=999)"
}

finish() {
  if ! watcher_gone; then
    check "watcher stderr carries no shell errors while running" stderr_clean
    kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null
  else
    check "watcher stderr carries no shell errors" stderr_clean
  fi
  snap "final"
  check "only inspection verbs (axi status, runs) ever reached no-mistakes" \
    not awk -F'\t' '$5 !~ /^(axi status|runs)( |$)/ {bad=1} END{exit !bad}' "$BASE/nm-calls.log"
  { for f in "$BASE"/watch*.out; do
      echo "=== watcher stdout ${f##*/} (what firstmate is woken with) ==="; cat "$f"
      echo "=== watcher stderr ${f##*/} ==="; cat "${f%.out}.err"
    done
    if [ -e "$BASE/drain.out" ]; then
      echo "=== handling-turn drain and acknowledgement (bin/fm-wake-drain.sh) ==="; cat "$BASE/drain.out"
    fi
    echo "=== durable wake queue (state/.wake-queue) ==="; cat "$STATE/.wake-queue" 2>/dev/null
    echo "=== gate-nudge record (count TAB epoch TAB held TAB identity) ==="; cat "$STATE/.gate-nudge-$ID" 2>/dev/null
    echo "=== steering-inbox records written by the ladder ==="
    for f in "$STATE/$ID.inbox"/*.msg "$STATE/$ID.inbox/handled"/*.msg; do
      [ -e "$f" ] || continue; echo "--- ${f#"$STATE"/}"; cat "$f"; echo
    done
    echo "=== watcher triage log, gate-nudge lines ==="
    grep -rhF "gate nudge" "$STATE" 2>/dev/null | grep -v '^Firstmate gate nudge'
    echo "=== no-mistakes calls (epoch, caller, run mode, cwd, argv) ==="; cat "$BASE/nm-calls.log" 2>/dev/null
    echo "=== lines typed into the worker pane (epoch, text) ==="; cat "$BASE/worker-input.log" 2>/dev/null
    echo "=== worker events ==="; cat "$BASE/worker-events.log" 2>/dev/null
  } > "$EVID/live-$SCEN.artifacts.txt"
  tmux kill-server 2>/dev/null
  if [ "$FAILS" -eq 0 ]; then say "RESULT: PASS"; else say "RESULT: FAIL ($FAILS failed checks)"; fi
  rm -rf "$BASE"
  exit "$FAILS"
}

case "$SCEN" in
  ladder)
    nm_mode parked 01LIVEA "$(head_n 1)"
    start_watcher
    check "ring 1: a steering-inbox record for the worker within 45s" wait_until 45 rings_ge 1
    check "ring 1: the doorbell line was typed into the live worker pane" wait_until 15 doorbells_ge 1
    snap "after ring 1"
    check "ring 1: firstmate was NOT woken (watcher printed nothing)" out_empty
    check "ring 1: no durable wake was queued for firstmate" queue_empty
    check "ring 1: record is fire-and-forget" file_has "$STATE/$ID.inbox/001.msg" "delivery=fire-and-forget"
    check "ring 1: record names the gate step and finding count" file_has "$STATE/$ID.inbox/001.msg" "parked at review: 2 finding(s)"
    check "ring 1: record names the exact next command" file_has "$STATE/$ID.inbox/001.msg" 'Run "no-mistakes axi status"'
    check "ring 2: the still-idle worker is rung a second time within 45s" wait_until 45 rings_ge 2
    check "ring 2: firstmate still NOT woken" out_empty
    check "escalation: watcher wakes firstmate within 60s of ring 2" wait_until 60 watcher_gone
    check "escalation: wake reason is the ordinary stale wake for this window" out_has "stale: $WIN"
    check "escalation: wake reason carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "escalation: wake reason names the gate" out_has "parked at review: 2 finding(s)"
    check "escalation: queued durably for firstmate" queue_has "gate-nudged x2"
    check "escalation: exactly two rings preceded it" rings_eq 2
    check "escalation: exactly two doorbells reached the pane" [ "$(doorbells)" -eq 2 ]
    check "gate identity is run id | step | run head" identity_is "01LIVEA|review|$(head_n 1)"
    ;;
  respond|respondquiet|respondrace*)
    echo "${SCEN%%[0-9]*}" > "$BASE/worker-mode"
    nm_mode parked 01LIVEB "$(head_n 1)"
    start_watcher
    check "ring 1 for gate 1 within 45s" wait_until 45 rings_ge 1
    check "the worker handled ring 1 (record moved to handled/)" wait_until 20 test -e "$STATE/$ID.inbox/handled/001.msg"
    check "the worker's response resumed the run, and its fix round re-parked on a new head" \
      wait_until 30 file_has "$BASE/worker-events.log" "run -> parked at"
    snap "after the worker answered gate 1"
    check "the re-parked gate (new run head) is rung within 60s" wait_until 60 rings_ge 2
    check "no escalation about the answered gate: firstmate still asleep" out_empty
    check "escalation only after the new gate is ignored twice (within 60s)" wait_until 60 watcher_gone
    check "escalation carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "three rings in all: one for the answered gate, two for the ignored one" rings_eq 3
    check "the spent identity is the second gate's run head" identity_is "01LIVEB|review|$(head_n 2)"
    ;;
  busyfix)
    gen=$("$ROOT/bin/fm-busy-event.sh" arm "$STATE" "$ID")
    "$ROOT/bin/fm-busy-event.sh" apply "$STATE" "$ID" idle --gen "$gen" --source claude-hook --event agent-end
    say "claude-hook busy record armed idle (rc=$?)"
    echo busyfix > "$BASE/worker-mode"
    nm_mode parked 01LIVEC "$(head_n 1)"
    start_watcher
    early=0; i=0
    while [ "$(rings)" -lt 3 ] && [ "$i" -lt 240 ]; do
      out_has "gate-nudged" && early=1
      watcher_gone && break
      sleep 0.5; i=$((i + 1))
    done
    snap "after gate 3 was rung"
    check "three consecutive same-detail gates (new run head each) were each rung within 120s" rings_ge 3
    check "no gate-nudged escalation fired before gate 3 was rung" [ "$early" -eq 0 ]
    check "firstmate still asleep after three gates" out_empty
    check "the run never read as working between gates" not file_has "$BASE/nm-calls.log" "fixing"
    check "the worker's claude-hook busy records applied" not grep -q 'rc=[1-9]' "$BASE/worker-events.log"
    check "no doorbell landed while the worker was busy" awk -F'\t' '
      FNR==NR { if ($2 ~ /^busy-record busy/) on=$1; else if ($2 ~ /^busy-record idle/) { s[++n]=on; e[n]=$1 }; next }
      /Firstmate instruction waiting/ { for (j=1;j<=n;j++) if ($1 > s[j] && $1 < e[j]) bad=1 }
      END { exit bad }' "$BASE/worker-events.log" "$BASE/worker-input.log"
    check "gate 3, then ignored, escalates within 60s" wait_until 60 watcher_gone
    check "escalation carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "four rings in all: gates 1 and 2 once, gate 3 twice" rings_eq 4
    check "the spent identity is gate 3's run head" identity_is "01LIVEC|review|$(head_n 3)"
    ;;
  cigreen)
    nm_mode green 01LIVED "$(head_n 1)"
    start_watcher
    check "green CI with only a pre-validation done: summary rings the worker within 45s" wait_until 45 rings_ge 1
    check "the doorbell reached the live pane" wait_until 15 doorbells_ge 1
    snap "after the green-CI ring"
    check "firstmate not woken by the first green-CI ring" out_empty
    check "the ring names the green PR" file_has "$STATE/$ID.inbox/001.msg" "checks green: PR ready for review"
    check "the ring names the report the worker owes" file_has "$STATE/$ID.inbox/001.msg" "done: PR <full https URL> checks green"
    check "ignored twice, it escalates within 90s" wait_until 90 watcher_gone
    check "escalation carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "exactly two rings preceded it" rings_eq 2
    check "the identity step is ci" identity_is "01LIVED|ci|$(head_n 1)"
    ;;
  cidone)
    nm_mode green 01LIVEE "$(head_n 1)"
    start_watcher
    # Five nudge intervals: long enough for two rings and an escalation.
    wait_until 30 watcher_gone
    snap "after 30s"
    check "a worker whose done: PR ... checks green report already landed is never rung" rings_eq 0
    check "no doorbell reached the pane" [ "$(doorbells)" -eq 0 ]
    check "no gate-nudged escalation" not out_has "gate-nudged"
    say "watcher output (ordinary triage, if any): $(tr '\n' ' ' < "$BASE/watch.out")"
    ;;
  axifail)
    nm_mode parked-ladderfail 01LIVEF "$(head_n 1)"
    start_watcher
    wait_until 30 watcher_gone
    snap "after 30s"
    check "crew-state still read the gate (its axi status call succeeded)" \
      file_has "$BASE/nm-calls.log" "$(printf 'crew-state\tparked-ladderfail')"
    check "the watcher's own gate-identity read was attempted and failed" \
      file_has "$BASE/nm-calls.log" "$(printf 'watcher\tparked-ladderfail')"
    check "a failed identity read rings nobody" rings_eq 0
    check "no doorbell reached the pane" [ "$(doorbells)" -eq 0 ]
    check "no gate-nudged escalation" not out_has "gate-nudged"
    say "watcher output (ordinary triage, if any): $(tr '\n' ' ' < "$BASE/watch.out")"
    if ! watcher_gone; then
      nm_mode parked 01LIVEF "$(head_n 1)"
      check "once the read works again, the same gate is rung within 45s" wait_until 45 rings_ge 1
    fi
    ;;
  spent)
    nm_mode parked 01LIVEG "$(head_n 1)"
    start_watcher
    check "the ignored gate reaches the gate-nudged escalation within 90s" wait_until 90 watcher_gone
    check "that escalation carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "firstmate's handling turn drains and acknowledges the wake" ack_cycle
    rows0=$(stale_rows)
    say "stale rows for $WIN left queued after the acknowledgement: $rows0"
    # Same gate, same worker ignoring it, and now a realistic wedge escalation
    # bound: the successor watcher must not wake firstmate about this gate again.
    WOUT=watch2.out
    start_watcher FM_WATCH_HANDLING_SUCCESSOR=1 FM_STALE_ESCALATE_SECS=20
    s0=$(date +%s)
    # Inside FM_STALE_ESCALATE_SECS nothing may wake firstmate about this gate.
    wait_until 16 watcher_gone
    check "spent budget: no wake of any kind for 16s (< FM_STALE_ESCALATE_SECS=20) after the successor started" not watcher_gone
    check "spent budget: no new stale row queued in that span" [ "$(stale_rows)" -eq "$rows0" ]
    # Past the bound, only the unchanged wedge timer may speak, as it does after
    # any ordinary stale surfacing (surface_nonterminal_stale).
    wait_until 30 watcher_gone
    say "successor watcher output after $(( $(date +%s) - s0 ))s: $(tr '\n' ' ' < "$BASE/$WOUT")"
    snap "after the successor watcher's span on the same gate"
    check "spent budget: no third ring about the same gate" rings_eq 2
    check "spent budget: no second gate-nudged escalation" not out_has "gate-nudged"
    check "spent budget: any later wake is the ordinary wedge escalation, not a gate re-wake" \
      eval 'out_empty || out_has "possible wedge, escalation 1"'
    if watcher_gone; then
      say "successor watcher exited; restarting a third as handling successor before moving the head"
      ack_cycle || true
      WOUT=watch3.out
      start_watcher FM_WATCH_HANDLING_SUCCESSOR=1 FM_STALE_ESCALATE_SECS=20
    fi
    # The pipeline's fix round moves the run head: a new gate re-arms the ladder.
    nm_mode parked 01LIVEG "$(head_n 2)"
    check "a new run head re-arms the spent budget: the worker is rung again within 45s" wait_until 45 rings_ge 3
    check "the re-armed identity carries the new run head" wait_until 10 identity_is "01LIVEG|review|$(head_n 2)"
    snap "after the new run head was rung"
    ;;
  nogate)
    # Adversarial cost check for the new-hash probe: a run that reads as
    # working (no gate) on a pane that idles, then settles on three new hashes
    # inside the nudge interval. Nothing may ring or wake, and crew-state reads
    # must stay inside the documented bound: one paced probe per nudge interval
    # plus, per distinct stale hash, one ladder probe and one triage read.
    nm_mode fixing 01LIVEH "$(head_n 1)"
    start_watcher
    s0=$(date +%s)
    wait_until 12 watcher_gone
    for i in 1 2 3; do
      tmux send-keys -t "$WIN" "worker progress line $i" Enter
      say "pane changed: worker printed progress line $i"
      wait_until 4 watcher_gone
    done
    wait_until 12 watcher_gone
    dur=$(( $(date +%s) - s0 ))
    calls=$(awk -F'\t' '$2 == "crew-state"' "$BASE/nm-calls.log" | wc -l)
    bound=$(( (dur + GNS - 1) / GNS + 1 + 2 * 4 ))
    snap "after ${dur}s of a working run on a changing pane"
    say "crew-state reads: $calls in ${dur}s over 4 distinct stale hashes (bound $bound; one per 1s poll would be ~$dur)"
    check "a working run on a changing pane rings nobody" rings_eq 0
    check "no doorbell reached the pane" [ "$(doorbells)" -eq 0 ]
    check "firstmate not woken (the triage absorbs a provably working run)" out_empty
    check "crew-state reads stay inside the documented bound, not one per poll" [ "$calls" -le "$bound" ]
    check "the watcher's own identity read never ran without a gate" not file_has "$BASE/nm-calls.log" "$(printf 'watcher\t')"
    ;;
  parkedchurn)
    # Adversarial cost check for the watcher's OWN axi read (gate_nudge_identity,
    # which the triage never makes): a parked gate on a pane that settles on a
    # new hash every 3s. Phase 1 has budget left; phase 2 has it spent, on a
    # handling-successor watcher.
    wrows() { awk -F'\t' -v a="$1" -v b="$2" '$2 == "watcher" && $1 >= a && $1 <= b' "$BASE/nm-calls.log" | wc -l; }
    crows() { awk -F'\t' -v a="$1" -v b="$2" '$2 == "crew-state" && $1 >= a && $1 <= b' "$BASE/nm-calls.log" | wc -l; }
    churn() { local i=0; while [ "$i" -lt "$1" ]; do i=$((i + 1)); tmux send-keys -t "$WIN" "worker output $2-$i" Enter; watcher_gone && return 0; sleep 3; done; }
    nm_mode parked 01LIVEI "$(head_n 1)"
    start_watcher
    a=$(date +%s); churn 10 p1; b=$(date +%s)
    w1=$(wrows "$a" "$b"); c1=$(crows "$a" "$b"); span=$((b - a))
    say "phase 1 (budget left): ${span}s, 10 new hashes, watcher axi reads $w1, crew-state reads $c1 (one per ${GNS}s interval = $(( span / GNS + 1 )))"
    check "phase 1: a pane that never idles ${GNS}s is not rung" rings_eq 0
    check "phase 1: firstmate not woken" out_empty
    check "phase 1: watcher axi reads stay at about one per nudge interval, not one per new hash" [ "$w1" -le $(( span / GNS + 2 )) ]
    check "the pane then idles: ring 1 within 45s" wait_until 45 rings_ge 1
    check "ignored twice, it escalates within 60s" wait_until 60 watcher_gone
    check "escalation carries the gate-nudged x2 marker" out_has "gate-nudged x2 with no response"
    check "firstmate's handling turn drains and acknowledges the wake" ack_cycle
    WOUT=watch2.out
    start_watcher FM_WATCH_HANDLING_SUCCESSOR=1
    sleep 4
    a=$(date +%s); churn 10 p2; wait_until 5 watcher_gone; b=$(date +%s)
    w2=$(wrows "$a" "$b"); c2=$(crows "$a" "$b"); span=$((b - a))
    say "phase 2 (budget spent, successor): ${span}s, watcher axi reads $w2, crew-state reads $c2, successor output: $(tr '\n' ' ' < "$BASE/$WOUT")"
    check "phase 2: no third ring about the spent gate" rings_eq 2
    check "phase 2: no second gate-nudged escalation" not out_has "gate-nudged"
    check "phase 2: watcher axi reads stay at about one per nudge interval, not one per new hash" [ "$w2" -le $(( span / GNS + 2 )) ]
    snap "after both churn phases"
    ;;
  *) say "unknown scenario $SCEN"; FAILS=1 ;;
esac
finish
