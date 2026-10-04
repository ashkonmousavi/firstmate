#!/bin/bash
# Sanitized server-idle-watch fixture with a proposed private-owner hook.
# Existing five-minute cadence and A/B/D behavior:
#  A) the Q server has 0 working crewmates on two checks in a row while it has room;
#  D) more than 2 serving remote job workers on a remote (the update-time worker storm);
#  B) any lane's or second mate's latest status is a paused:/blocked: resource wait (memory/load/headroom/admission)
#     older than 10 minutes while some machine has room, so the work can be reclaimed for, moved, or given a lane.
# "Room" is real headroom: MemAvailable (counts reclaimable cache) > 6 GiB and real CPU busy < 75% from a /proc/stat
# delta. Load average is never used: on WSL it counts I/O wait and read the Zenbook as full at 4 of 16 cores busy.
set -u
ST="${STATE:-/unused/state}"
LAST="$ST/.server-idle-watch-last-run"; IDLE="$ST/.server-idle-watch-idle-since"
ALERT_A="$ST/.server-idle-watch-last-alert"; ALERT_B="$ST/.server-idle-watch-last-alert-wait"
now=$(date +%s)
if [ -f "$LAST" ] && [ $((now - $(stat -c %Y "$LAST"))) -lt 240 ]; then exit 0; fi
touch "$LAST"

# Prints "<cpu-busy-%> <MemAvailable-GiB>" for the machine it runs on.
probe='read -r _ a b c d e f g _ < /proc/stat; sleep 1; read -r _ A B C D E F G _ < /proc/stat;
t=$(( (A+B+C+D+E+F+G) - (a+b+c+d+e+f+g) )); i=$(( (D+E) - (d+e) )); [ $t -gt 0 ] || t=1;
echo "$(( 100 * (t - i) / t )) $(awk "/MemAvailable/{print int(\$2/1048576)}" /proc/meminfo)"'
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

# Proposed private hook: same authenticated hosts and existing cadence.
# Keep this before A/B/D early returns. Main substitutes installed paths.
NM_HELPER="${NM_HELPER:?installed helper required}"
NM_HOME="${NM_HOME:?local no-mistakes home required}"
timeout -k 1 15 ssh -o BatchMode=yes -o ConnectTimeout=5 fixture-server \
  "$probe; sudo -n -u qcrew bash -c 'cd /fixture-server/fm-home/state && for m in *.meta; do tail -n1 \"\${m%.meta}.status\" 2>/dev/null | grep -Ec \"^(working|validating)\"; done' 2>/dev/null | awk '{s+=\$1} END{print s+0}'; pgrep -u qcrew -fc '^/bin/bash /fixture-server/firstmate/bin/fm-remote-job-worker.sh --serve'" >"$tmp/s" 2>/dev/null &
timeout -k 1 15 ssh -o BatchMode=yes -o ConnectTimeout=5 fixture-zenbook "$probe; pgrep -u zcrew -fc '^/bin/bash /fixture-zenbook/firstmate/bin/fm-remote-job-worker.sh --serve'" >"$tmp/z" 2>/dev/null &
timeout -k 1 15 bash -c "$probe" >"$tmp/p" 2>/dev/null &
(timeout -k 1 15 "$NM_HELPER" "$NM_HOME" pc > "$tmp/pc.nm" || : > "$tmp/pc.nm") &
(timeout -k 1 15 ssh -o BatchMode=yes -o ConnectTimeout=5 fixture-server \
  "sudo -n -u qcrew /fixture-server/firstmate/bin/fm-nm-config-staleness-check.sh /fixture-server/.no-mistakes server" > "$tmp/server.nm" 2>/dev/null || : > "$tmp/server.nm") &
(timeout -k 1 15 ssh -o BatchMode=yes -o ConnectTimeout=5 fixture-zenbook \
  "/fixture-zenbook/firstmate/bin/fm-nm-config-staleness-check.sh /fixture-zenbook/.no-mistakes zenbook" > "$tmp/zenbook.nm" 2>/dev/null || : > "$tmp/zenbook.nm") &
wait
for machine in pc server zenbook; do
  if [ -s "$tmp/$machine.nm" ]; then cat "$tmp/$machine.nm"
  else printf '{"schema":"fm-nm-config-age/1","machine":"%s","status":"unavailable"}\n' "$machine"; fi
done | "$NM_HELPER" --episode "$ST/.server-idle-watch-nm-config-episode"

roomy() { awk -v c="$1" -v m="$2" 'BEGIN{print (c!="" && m!="" && c<75 && m>6)?1:0}'; }
read -r s_cpu s_mem < <(head -1 "$tmp/s"); s_work=$(sed -n 2p "$tmp/s")
read -r z_cpu z_mem < <(head -1 "$tmp/z" 2>/dev/null); z_helpers=$(sed -n 2p "$tmp/z" 2>/dev/null); s_helpers=$(sed -n 3p "$tmp/s" 2>/dev/null)
read -r p_cpu p_mem < "$tmp/p"

# D) remote job-worker storm: more than 2 serving message helpers on a remote (healthy is 1). Every 15 min at most.
ALERT_D="$ST/.server-idle-watch-last-alert-helpers"; jam=""
[ "${s_helpers:-0}" -gt 2 ] 2>/dev/null && jam="$jam server=$s_helpers"
[ "${z_helpers:-0}" -gt 2 ] 2>/dev/null && jam="$jam zenbook=$z_helpers"
if [ -n "$jam" ] && { [ ! -f "$ALERT_D" ] || [ $((now - $(stat -c %Y "$ALERT_D"))) -ge 900 ]; }; then
  touch "$ALERT_D"
  echo "server-idle-watch: remote message helpers jammed:$jam (healthy is 1): stop sends, check the worker lock cookie, clear per learnings REMOTE WORKER STORM, then one send"; exit 0
fi
rooms=""
[ "$(roomy "${s_cpu:-}" "${s_mem:-}")" = 1 ] && rooms="$rooms server(${s_cpu}% cpu, ${s_mem} GiB)"
[ "$(roomy "${z_cpu:-}" "${z_mem:-}")" = 1 ] && rooms="$rooms zenbook(${z_cpu}% cpu, ${z_mem} GiB)"
[ "$(roomy "${p_cpu:-}" "${p_mem:-}")" = 1 ] && rooms="$rooms pc(${p_cpu}% cpu, ${p_mem} GiB)"

# A) server idle with room
if [ -n "${s_work:-}" ] && [ "$s_work" -eq 0 ] && [ "$(roomy "${s_cpu:-}" "${s_mem:-}")" = 1 ]; then
  if [ ! -f "$IDLE" ]; then touch "$IDLE"
  elif [ ! -f "$ALERT_A" ] || [ $((now - $(stat -c %Y "$ALERT_A"))) -ge 1800 ]; then
    touch "$ALERT_A"
    echo "server-idle-watch: Q server has 0 working crewmates for $(( (now - $(stat -c %Y "$IDLE")) / 60 )) min with room (${s_cpu}% cpu, ${s_mem} GiB free): find it work or a blocker"; exit 0
  fi
else rm -f "$IDLE"; fi

# B) resource waits older than 10 minutes while some machine has room
[ -n "$rooms" ] || exit 0
waits=""
for f in "$ST"/*.status; do
  l=$(tail -n1 "$f" 2>/dev/null) || continue
  case "$l" in paused*|blocked*) ;; *) continue;; esac
  # A lane waiting on its own live run (same-run fix, CI, validation) is working, not a resource wait (10-04 false alarm).
  printf '%s' "$l" | grep -qiE 'same[- ]?run|ci fix|fix return|own run|checks? (are )?re-?running|validation (run|running)' && continue
  printf '%s' "$l" | grep -qiE 'memory|headroom|load [0-9<>]|load gate|admission|resource wait|shared-slice|slice free' || continue
  at=$(printf '%s' "$l" | sed -n 's/.*\[at=\([0-9]\{10\}\)\].*/\1/p'); [ -n "$at" ] || continue
  [ $((now - at)) -ge 600 ] && waits="$waits $(basename "$f" .status)($(( (now - at) / 60 ))m)"
done
[ -n "$waits" ] || exit 0
if [ -f "$ALERT_B" ] && [ $((now - $(stat -c %Y "$ALERT_B"))) -lt 1800 ]; then exit 0; fi
touch "$ALERT_B"
echo "server-idle-watch: resource waits over 10 min:$waits while room exists on:$rooms: reclaim, move the work, or open a lane"
exit 0
