#!/usr/bin/env bash
# Live driver: real fm-watch-arm.sh / fm-watch.sh / fm-wake-drain.sh on a marked lab home.
# Usage: live-driver.sh <checkout-root> <scenario: restart|take-over|stop|crash> <label>
set -u
ROOT=$1 SCEN=$2 LABEL=$3
WT=~/.no-mistakes/worktrees/049a88734b0e/01M6KJVHFZFSKVX5RNVVHNPQRY
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
STATE="$LAB/state"
ARM="$ROOT/bin/fm-watch-arm.sh" DRAIN="$ROOT/bin/fm-wake-drain.sh" LIB="$ROOT/bin/fm-wake-lib.sh"
run() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 "$@"; }
bgexec() { exec env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX \
  TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB" FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 "$@"; }
append() { run bash -c '. "$1"; fm_wake_append "$2" "$3" "$4"' _ "$LIB" signal live "$1"; }
log() { printf '[%s %s] %s\n' "$LABEL" "$SCEN" "$*"; }
cleanup() { kill -TERM "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" 2>/dev/null; pkill -TERM -f "$LAB" 2>/dev/null; for p in $(jobs -p); do kill -TERM "$p" 2>/dev/null; done; sleep 1; pkill -KILL -f "$LAB" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
waitfor() { local f=$1 pat=$2 n=${3:-600} i=0; while [ $i -lt $n ]; do grep -q "$pat" "$f" 2>/dev/null && return 0; sleep 0.05; i=$((i+1)); done; return 1; }

log "checkout=$ROOT commit=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || cat "$ROOT/.commit")"
log "lab home=$LAB"
bgexec env FM_POLL=60 "$ARM" > "$LAB/owner.out" 2>&1 &
OWNER=$!
waitfor "$LAB/owner.out" 'watcher: started pid=' || { log "FIXTURE: first arm did not start: $(cat "$LAB/owner.out")"; exit 9; }
SEED=$(cat "$STATE/.watch.lock/pid")
log "first arm (pid $OWNER, cmd: $(ps -o args= -p $OWNER | cut -c1-80)): $(head -1 "$LAB/owner.out")"
sleep 2
append "signal: fixture handled by main"
D=$(run "$DRAIN" 2>&1 >/dev/null)
ACKCMD=$(printf '%s\n' "$D" | sed -n 's/^WAKE_ACK_REQUIRED:.*\(--ack-through [0-9]* --recovery-generation [A-Za-z0-9._-]*\)$/\1/p')
log "drain asked: ${ACKCMD:-<none>}"
# shellcheck disable=SC2086
[ -n "$ACKCMD" ] && run "$DRAIN" $ACKCMD >/dev/null 2>&1
ACKED=$(cat "$STATE/.watcher-down")
log "marker after main's ack: $ACKED ; queue bytes=$(wc -c < "$STATE/.wake-queue" 2>/dev/null || echo 0)"
case "$SCEN" in
  restart|take-over)
    if [ "$SCEN" = restart ]; then set -- --restart; else set -- --take-over "$OWNER"; fi
    bgexec env FM_POLL=1 "$ARM" "$@" > "$LAB/arm.out" 2>&1 &
    ARMPID=$!
    waitfor "$LAB/arm.out" '^watcher: started ' 700 || log "next cycle did not report started"
    sleep 5
    log "next-cycle arm output after 5s quiet window:"; sed 's/^/    | /' "$LAB/arm.out"
    log "marker now: $(cat "$STATE/.watcher-down")"
    if grep -q 'check: rearm-resurface' "$LAB/arm.out"; then log "RESULT: EMPTY rearm-resurface wake (main woken with nothing to do)"; else log "RESULT: quiet (no empty wake); arm still waiting=$(kill -0 $ARMPID 2>/dev/null && echo yes || echo no)"; fi
    append "signal: genuinely new work after the owner stop"
    i=0; while [ $i -lt 400 ] && kill -0 $ARMPID 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    log "after genuine new work, arm output:"; sed 's/^/    | /' "$LAB/arm.out"
    if grep -q 'genuinely new work\|^check: rearm-resurface' "$LAB/arm.out"; then log "RESULT: new work surfaced"; else log "RESULT: new work NOT surfaced"; fi
    DOUT=$(run "$DRAIN" 2>/dev/null); log "main's drain after that wake shows:"; printf '%s\n' "$DOUT" | grep -n 'genuinely new work' | sed 's/^/    | /' || log "drain: (no row)"
    if printf '%s' "$DOUT" | grep -q 'genuinely new work'; then log "RESULT: drain non-empty (real work delivered)"; else log "RESULT: drain EMPTY"; fi
    ;;
  stop)
    OUT=$(run "$ARM" --stop 2>&1); log "--stop said: $OUT (rc=$?)"
    M=$(cat "$STATE/.watcher-down"); log "marker after --stop: $M"
    case "$M" in pending:downtime:*|announced:downtime:*) log "RESULT: downtime published for owner rewake";; *) log "RESULT: NO downtime published";; esac
    ;;
  crash)
    kill -KILL "$SEED"; sleep 0.5
    log "watcher pid $SEED SIGKILLed (genuine outage); marker: $(cat "$STATE/.watcher-down")"
    bgexec env FM_POLL=1 "$ARM" > "$LAB/arm.out" 2>&1 &
    ARMPID=$!
    i=0; while [ $i -lt 400 ] && kill -0 $ARMPID 2>/dev/null; do sleep 0.1; i=$((i+1)); done
    log "re-arm output:"; sed 's/^/    | /' "$LAB/arm.out"
    log "marker now: $(cat "$STATE/.watcher-down")"
    if grep -q 'rearm-resurface\|downtime\|recover' "$LAB/arm.out"; then log "RESULT: genuine outage surfaced to main"; else log "RESULT: genuine outage NOT surfaced"; fi
    ;;
esac
