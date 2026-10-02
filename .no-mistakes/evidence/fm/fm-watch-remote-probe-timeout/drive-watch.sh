#!/usr/bin/env bash
# drive-watch.sh <bin-root> <label> <run-seconds>: run the real fm-watch.sh from
# <bin-root> in a disposable lab home whose one remote secondmate sits on a host
# whose ssh never returns, and sample the watcher liveness beacon.
set -u
ROOTDIR=$1 LABEL=$2 RUN=${3:-60}
WT=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M3Z6X7ZXE8BRXM5E7JZ46BTT
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cat > "$LAB/state/rsm.meta" <<M
window=fm-remote:w1:p1
kind=secondmate
mode=secondmate
harness=claude
remote_host=remote-mac
remote_root=/remote/root
remote_backend=herdr
remote_herdr_session=fm-remote
remote_target=fm-remote:w1:p1
home=/remote/home
M
cat > "$LAB/data/secondmates.md" <<R
- rsm - remote mate on an overloaded host (host: remote-mac; root: /remote/root; home: /remote/home; scope: remote testing; projects: alpha; added 2026-10-02)
R
# The overloaded host: ssh connects, keepalives answer, the remote command never finishes.
cat > "$LAB/stall-ssh" <<'S'
#!/usr/bin/env bash
printf '%s start pid=%s cmd=%s\n' "$(date +%T)" "$$" "$(printf '%s' "${@: -1}" | base64 -d 2>/dev/null | tr '\0' ' ')" >> "$FM_FAKE_SSH_LOG"
cat > /dev/null
sleep 150
printf '%s finished pid=%s\n' "$(date +%T)" "$$" >> "$FM_FAKE_SSH_LOG"
S
chmod +x "$LAB/stall-ssh"
# A delivered request awaiting the remote mate's report, as fm-send leaves it.
FM_HOME="$LAB" bash -c '. "$0/bin/fm-pending-reply-lib.sh"; c=$(fm_pending_reply_create "$1" "$1/state" rsm "status of the remote build") && fm_pending_reply_mark_delivered "$1/state" "$c" && echo "seeded pending reply $c"' "$ROOTDIR" "$LAB"
LOG=/tmp/fmlive/$LABEL; rm -rf "$LOG"; mkdir -p "$LOG"
export FM_FAKE_SSH_LOG="$LOG/ssh.log"
: > "$FM_FAKE_SSH_LOG"
start=$(date +%s)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_SECONDMATE_LIVENESS_SECS=1 \
  FM_SSH_BIN="$LAB/stall-ssh" ${PB+FM_SECONDMATE_LIVENESS_PROBE_BUDGET=$PB} ${OB+FM_PENDING_REPLY_OBSERVE_BUDGET=$OB} \
  setsid "$ROOTDIR/bin/fm-watch.sh" > "$LOG/watch.out" 2> "$LOG/watch.err" &
wpid=$!
{
  printf 'watcher (%s) pid %s started %s in lab %s\n' "$LABEL" "$wpid" "$(date +%T)" "$LAB"
  for ((t = 3; t <= RUN; t += 3)); do
    sleep 3
    now=$(date +%s)
    if [ -e "$LAB/state/.last-watcher-beat" ]; then
      beat=$(stat -c %Y "$LAB/state/.last-watcher-beat"); age=$((now - beat))
    else age=never; fi
    alive=yes; kill -0 "$wpid" 2>/dev/null || alive=no
    printf 't=+%3ss  watcher alive=%s  beacon age=%ss\n' "$((now - start))" "$alive" "$age"
  done
} | tee "$LOG/beacon.txt"
echo "--- hung ssh processes still running while watcher alive: $(pgrep -fc "$LAB/stall-ssh")"
echo "--- pending reply records:"; for r in "$LAB"/state/.pending-replies/* "$LAB"/state/pending-replies/*; do [ -f "$r" ] && grep -E "^(task_id|phase)=" "$r"; done 2>/dev/null
kill -TERM -- -"$wpid" 2>/dev/null; sleep 1; kill -KILL -- -"$wpid" 2>/dev/null
pkill -f "$LAB/stall-ssh" 2>/dev/null
cp "$LAB/state/.watch-triage.log" "$LOG/triage.log" 2>/dev/null
echo "--- ssh log"; cat "$FM_FAKE_SSH_LOG"
echo "--- triage log (secondmate lines)"; grep -i "secondmate\|pending" "$LOG/triage.log" 2>/dev/null | tail -8
echo "--- watcher stdout"; cat "$LOG/watch.out"; echo "--- watcher stderr"; tail -5 "$LOG/watch.err"
rm -rf "$LAB"
