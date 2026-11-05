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

# === BEGIN tester-owned: lc-core-scheduler K1-R1..K1-R12 oracles ==========
# Frozen plan LC-KUN-v26, section "K1 build-time requirements of
# fleet-ops:lc-core-scheduler". The builder runs these and never edits this
# region (or the R6 edit to the busy-lock block below); a disputed case goes
# back to the tester. Expected numbers are the plan's, never the code's:
# deadlines 600/300/60/120/900 s, stop grace 5 s, passes at most 55 s apart,
# step (1) bounded by `timeout -k 5 20`, bounds 75/130/165/255/310/315/680/735 s.
#
# Seams these cases fix for the build (all inert unless FM_TEST_SEAM=1):
#   FM_AUTOLAUNCH_NOW_FILE   fake clock: a file holding the epoch the pass
#                            reads for every time it uses (record stamps,
#                            deadlines, lock `at`, key ages).
#   FM_AUTOLAUNCH_SEND_BIN   replaces bin/fm-send.sh for responder hand-offs.
#   FM_AUTOLAUNCH_SPAWN_BIN, FM_AUTOLAUNCH_CAPACITY_BIN  (existing).
#   PATH stubs               systemd-run, systemctl, timeout, codex, claude:
#                            the pass resolves them from PATH. The fake
#                            `timeout` advances the clock by 20 s for every
#                            step (1) it runs (`-k 5 20`), the plan's worst
#                            case, and can cut one step (1) at TERM (exit 124,
#                            +20 s) or KILL (exit 137, +25 s); the same stub
#                            answers as `gnutimeout`. The fake
#                            `systemd-run` runs the command as the unit's main
#                            process; k1_tick plays systemd at each pass time:
#                            TERM to the main pid only at RuntimeMaxSec and
#                            KILL TimeoutStopSec later (KillMode=process).
#   Agent identity           a started agent is recorded as agent_root_pid,
#                            agent_root_start (/proc/<pid>/stat field 22) and
#                            boot_id lines in state/<task>.meta (the K2a
#                            identity fields).
# Run one case alone: FM_AUTOLAUNCH_TEST_ONLY='<test name>...' (or k1 for all).
K1_T0=1800000000
REAL_TIMEOUT=$(command -v timeout)
REAL_SLEEP=$(command -v sleep)
K1_TESTS=''

k1_setup() {  # <case> <mate|main>
  K1="$TMP_ROOT/k1-$1" H="$TMP_ROOT/k1-$1/home"
  KF="$K1/fake" KB="$K1/bin" LOG="$H/state/autolaunch.log"
  mkdir -p "$H/state" "$H/data" "$H/config" "$H/projects/proj" "$KF/units" "$KB" "$K1/agent" "$K1/tmux"
  fm_test_tasks_toml "$H/.tasks.toml"
  K1_TEST_PID=$$
  export FM_HOME="$H" K1 KF KB REAL_TIMEOUT ROOT K1_TEST_PID
  [ "$2" = main ] || printf 'k1-mate\n' > "$H/.fm-secondmate-home"
  printf '%s\n' "$K1_T0" > "$KF/clock"
  printf '1\n' > "$KF/free"
  printf 'ok\n' > "$KF/spawn-mode"
  cp "$REAL_SLEEP" "$KB/k1-sleep"
  cp "$REAL_SLEEP" "$K1/agent/claude"
  k1_write_stubs
  export FM_AUTOLAUNCH_SPAWN_BIN="$KB/spawn" FM_AUTOLAUNCH_CAPACITY_BIN="$KB/capacity" \
    FM_AUTOLAUNCH_SEND_BIN="$KB/fm-send" TMUX_TMPDIR="$K1/tmux"
  : > "$KF/observe"
}

k1_write_stubs() {
  cat > "$KB/capacity" <<'SH'
#!/usr/bin/env bash
free=$(cat "$KF/free")
if [ "$free" -gt 0 ]; then printf 'capacity: free_lanes=%s reason=ok lanes=1 target=10\n' "$free"; exit 0; fi
printf 'capacity: free_lanes=0 reason=full lanes=10 target=10\n'; exit 75
SH
  # Spawn modes (fake/spawn-mode): ok, fail-unknown, hung (a child takes the
  # real spawn lock and lives on; the stub never returns), hung-child-exits,
  # hung-agent-first (starts the agent, then hangs). fake/agent-go-<id> makes
  # a hung child start the agent late.
  cat > "$KB/spawn" <<'SH'
#!/usr/bin/env bash
id=$1
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/spawn.log"
mode=$(cat "$KF/spawn-mode")
start_agent() {
  "$K1/agent/claude" 100000 </dev/null >/dev/null 2>&1 &
  apid=$!
  astart=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$apid/stat")
  printf 'agent_root_pid=%s\nagent_root_start=%s\nboot_id=%s\n' "$apid" "$astart" \
    "$(cat /proc/sys/kernel/random/boot_id)" >> "$FM_HOME/state/$id.meta"
  printf '%s\n' "$apid" > "$KF/agent-$id.pid"
}
case "$mode" in
  ok) printf 'spawned %s\n' "$id"; exit 0 ;;
  fail-unknown) echo "error: k1 unexpected internal fault 0x2a" >&2; exit 1 ;;
esac
[ "$mode" != hung-agent-first ] || start_agent
(
  STATE="$FM_HOME/state"; export STATE
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$STATE/.spawn-$id.lock" || exit 3
  printf '%s\n' "$BASHPID" > "$KF/holder-$id.pid"
  [ "$mode" != hung-child-exits ] || exit 0
  while [ ! -e "$KF/agent-go-$id" ]; do "$KB/k1-sleep" 0.2; done
  start_agent
  exec "$KB/k1-sleep" 100000
) </dev/null >/dev/null 2>&1 &
while [ ! -s "$KF/holder-$id.pid" ]; do "$KB/k1-sleep" 0.05; done
exec "$KB/k1-sleep" 100000
SH
  cat > "$KB/systemd-run" <<'SH'
#!/usr/bin/env bash
# Fake systemd-run: records the call at the fake time and runs the command as
# the unit's main process (in its own session); never reaches real systemd.
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/systemd-run.log"
unit='' props=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --) shift; break ;;
    -p|--property) props="$props $2"; shift 2 ;;
    --property=*) props="$props ${1#*=}"; shift ;;
    -p*) props="$props ${1#-p}"; shift ;;
    -u|--unit) unit=$2; shift 2 ;;
    --unit=*) unit=${1#*=}; shift ;;
    -E|--setenv|--description|--slice|--working-directory|-M|--machine|--uid|--gid|--nice|--service-type|-H|--host) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
max='' stop=''
for p in $props; do
  case "$p" in RuntimeMaxSec=*) max=${p#*=} ;; TimeoutStopSec=*) stop=${p#*=} ;; esac
done
n=$(( $(find "$KF/units" -type f | wc -l) + 1 ))
argv="$*"
cmd=("$@")
if [ -s "$KF/hang-match" ] && printf '%s\n' "$argv" | grep -qF -f "$KF/hang-match"; then
  cmd=("$KB/k1-sleep" 100000)
fi
if [ -e "$KF/ignore-term" ]; then
  setsid bash -c 'trap "" TERM; exec "$@"' k1-unit "${cmd[@]}" </dev/null >>"$KF/unit-$n.out" 2>&1 &
else
  setsid "${cmd[@]}" </dev/null >>"$KF/unit-$n.out" 2>&1 &
fi
pid=$!
printf 'unit=%s\npid=%s\nstart=%s\nmax=%s\nstop=%s\nargv=%s\n' \
  "${unit:-run-k1-$n}" "$pid" "$(cat "$KF/clock")" "$max" "$stop" "$argv" > "$KF/units/$n"
echo "Running as unit: ${unit:-run-k1-$n}.service" >&2
SH
  cat > "$KB/systemctl" <<'SH'
#!/usr/bin/env bash
# Fake systemctl --user over the fake units: show MainPID/ActiveState, is-active.
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/systemctl.log"
sub='' unit='' props='' value=0
for a in "$@"; do
  case "$a" in
    --user|--quiet|-q|--no-pager) ;;
    --value) value=1 ;;
    -p|--property) ;;
    --property=*) props="$props,${a#*=}" ;;
    MainPID*|ActiveState*|SubState*|ExecMainStartTimestamp*) props="$props,$a" ;;
    show|is-active|stop|kill|status) sub=$a ;;
    *) [ -n "$unit" ] || unit=${a%.service} ;;
  esac
done
rec=$(grep -lx "unit=$unit" "$KF"/units/* 2>/dev/null | head -1)
pid=0; state=inactive
if [ -n "$rec" ]; then
  p=$(sed -n 's/^pid=//p' "$rec")
  st=$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$p/stat" 2>/dev/null) || st=
  if [ -n "$st" ] && [ "$st" != Z ]; then pid=$p; state=active; fi
fi
case "$sub" in
  is-active) echo "$state"; [ "$state" = active ] ;;
  show)
    for p in $(printf '%s' "${props#,}" | tr ',' ' '); do
      case "$p" in
        MainPID) v=$pid ;; ActiveState) v=$state ;; SubState) [ "$state" = active ] && v=running || v=dead ;; *) v= ;;
      esac
      if [ "$value" = 1 ]; then echo "$v"; else echo "$p=$v"; fi
    done ;;
  *) exit 0 ;;
esac
SH
  # Fake timeout: only the step-(1) signature `-k 5 20` is clock-managed.
  cat > "$KB/timeout" <<'SH'
#!/usr/bin/env bash
orig=("$@") kill='' dur=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -k|--kill-after|-s|--signal) [ "$1" = -k ] || [ "$1" = --kill-after ] && kill=$2; shift 2 ;;
    --kill-after=*) kill=${1#*=}; shift ;;
    -k*) kill=${1#-k}; shift ;;
    --signal=*|-s*|--preserve-status|--foreground|-v|--verbose) shift ;;
    *) dur=$1; shift; break ;;
  esac
done
printf '%s\t%s\n' "$(cat "$KF/clock")" "${orig[*]}" >> "$KF/timeout.log"
if [ "${kill%s}" != 5 ] || [ "${dur%s}" != 20 ]; then exec "$REAL_TIMEOUT" "${orig[@]}"; fi
cut=$(head -1 "$KF/cut-step1" 2>/dev/null)
if [ -n "$cut" ]; then
  sed -i 1d "$KF/cut-step1"
  if [ "$cut" = kill ]; then echo $(( $(cat "$KF/clock") + 25 )) > "$KF/clock"; exit 137; fi
  echo $(( $(cat "$KF/clock") + 20 )) > "$KF/clock"; exit 124
fi
rc=0
"$REAL_TIMEOUT" "${orig[@]}" || rc=$?
echo $(( $(cat "$KF/clock") + 20 )) > "$KF/clock"
exit "$rc"
SH
  # Fake responder send (fm-send.sh). fake/send-mode lines, one per call:
  # fail (nothing accepted), crash (accepted, then the calling pass dies
  # before it can record a receipt), ok. Accepted identities: fake/accepted.
  cat > "$KB/fm-send" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$(cat "$KF/clock")" "$*" >> "$KF/send.log"
mode=$(head -1 "$KF/send-mode" 2>/dev/null); [ -z "$mode" ] || sed -i 1d "$KF/send-mode"
case "${mode:-ok}" in fail) echo 'error: k1 enqueue failed' >&2; exit 1 ;; esac
id=$(printf '%s' "$*" | sha256sum | cut -c1-16)
grep -qx "$id" "$KF/accepted" 2>/dev/null || printf '%s\n' "$id" >> "$KF/accepted"
if [ "$mode" = crash ]; then
  p=$PPID
  while [ -n "$p" ] && [ "$p" -gt 1 ] && [ "$p" != "$K1_TEST_PID" ]; do
    case "$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)" in */bin/fm-autolaunch.sh*) kill -KILL "$p" 2>/dev/null ;; esac
    p=$(awk '{sub(/^.*\) /, ""); print $2}' "/proc/$p/stat" 2>/dev/null)
  done
fi
exit 0
SH
  # Diagnosis stubs: fake/codex-mode hang keeps rung 3 running.
  cat > "$KB/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\tcodex %s\n' "$(cat "$KF/clock")" "$*" >> "$KF/diag.log"
[ "$(cat "$KF/codex-mode" 2>/dev/null)" != hang ] || exec "$KB/k1-sleep" 100000
echo 'k1 rung-3 advice'
SH
  cat > "$KB/claude" <<'SH'
#!/usr/bin/env bash
printf '%s\tclaude %s\n' "$(cat "$KF/clock")" "$*" >> "$KF/diag.log"
echo 'k1 rung-4 advice'
SH
  cp "$KB/timeout" "$KB/gnutimeout"
  chmod +x "$KB"/*
}

k1_now() { cat "$KF/clock"; }
k1_alive() {  # <pid>: running and not a zombie
  local st
  [ -n "$1" ] && st=$(awk '{sub(/^.*\) /, ""); print $1}' "/proc/$1/stat" 2>/dev/null) && [ -n "$st" ] && [ "$st" != Z ]
}
k1_unit_field() { sed -n "s/^$2=//p" "$1"; }

# Play systemd at the current fake time for every fake unit.
k1_tick() {
  local now rec pid start max stop i
  now=$(k1_now)
  for rec in "$KF"/units/*; do
    [ -f "$rec" ] || continue
    pid=$(k1_unit_field "$rec" pid) start=$(k1_unit_field "$rec" start)
    max=$(k1_unit_field "$rec" max) stop=$(k1_unit_field "$rec" stop)
    case "$max" in ''|*[!0-9]*) continue ;; esac
    case "$stop" in ''|*[!0-9]*) stop=90 ;; esac
    k1_alive "$pid" || continue
    [ "$now" -ge $((start + max)) ] || continue
    if [ -s "$KF/unkillable-match" ] && grep -qF -f "$KF/unkillable-match" "$rec"; then continue; fi
    grep -qx 'termed=1' "$rec" || { kill -TERM "$pid" 2>/dev/null; printf 'termed=1\n' >> "$rec"; }
    i=0; while k1_alive "$pid" && [ "$i" -lt 10 ]; do "$KB/k1-sleep" 0.1; i=$((i + 1)); done
    if k1_alive "$pid" && [ "$now" -ge $((start + max + stop)) ]; then
      kill -KILL "$pid" 2>/dev/null
      i=0; while k1_alive "$pid" && [ "$i" -lt 20 ]; do "$KB/k1-sleep" 0.1; i=$((i + 1)); done
    fi
  done
}

# One pass at fake time T0+<t>; term|kill cuts its step (1). A pass that
# blocks is ended after 30 real seconds and counts as red evidence.
k1_pass() {  # <t> [term|kill]
  local rc=0
  printf '%s\n' $((K1_T0 + $1)) > "$KF/clock"
  k1_tick
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$KF/cut-step1"
  FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" \
    "$REAL_TIMEOUT" -k 2 30 bash "$AL" >> "$KF/pass.out" 2>&1 || rc=$?
  rm -f "$KF/cut-step1"
  printf '%s\t%s\n' "$1" "$rc" >> "$KF/pass-rc.log"

  k1_observe
}
k1_passes() {  # <from> <to>: timer passes 55 s apart
  local t=$1
  while [ "$t" -le "$2" ]; do k1_pass "$t"; t=$((t + 55)); done
}
k1_blocked_passes() { awk -F'\t' '$2 == 124 || $2 == 137 { n++ } END { print n + 0 }' "$KF/pass-rc.log"; }

# First fake time (clock after the pass) at which a condition held.
k1_watch() {  # <name> <condition evaluated with eval>
  printf '%s\t%s\n' "$1" "$2" >> "$KF/observe"
}
k1_observe() {
  local name cond
  while IFS=$'\t' read -r name cond; do
    [ -e "$KF/seen-$name" ] && continue
    if eval "$cond"; then k1_now > "$KF/seen-$name"; fi
  done < "$KF/observe"
}
k1_seen() { cat "$KF/seen-$1" 2>/dev/null; }
k1_within() {  # <name> <origin epoch> <bound s> <message>
  local at
  at=$(k1_seen "$1")
  [ -n "$at" ] || fail "$4: never observed"
  [ $((at - $2)) -le "$3" ] || fail "$4: observed $((at - $2)) s after its origin, bound $3 s"
}

k1_lines() {  # <file> <fixed string>...: lines of the file holding every string
  local f=$1 out s
  shift
  [ -f "$f" ] || return 0
  out=$(cat "$f")
  for s in "$@"; do out=$(printf '%s\n' "$out" | grep -F -- "$s" || true); done
  [ -z "$out" ] || printf '%s\n' "$out"
}
k1_count() { k1_lines "$@" | grep -c . || true; }
k1_owned() {  # <task>: the task's responder hand-offs (keyed blocked: ctl-... owned)
  k1_lines "$H/state/$1.status" blocked ctl- "$1" owned
}
k1_units() {  # <fixed string>...: fake systemd-run calls holding every string
  k1_lines "$KF/systemd-run.log" "$@"
}
k1_units_max() {  # <RuntimeMaxSec> <fixed string>...: matching calls with exactly that deadline
  local max=$1 l
  shift
  k1_units "$@" | while IFS= read -r l; do [ "$(k1_prop "$l" RuntimeMaxSec)" != "$max" ] || printf '%s\n' "$l"; done
}
k1_units_max_count() { k1_units_max "$@" | grep -c . || true; }
k1_units_max_start() {  # <n> <RuntimeMaxSec> <fixed string>...
  local n=$1
  shift
  k1_units_max "$@" | sed -n "${n}p" | cut -f1
}
k1_unit_start() {  # <n> <fixed string>...: fake start time of the n-th matching call
  local n=$1
  shift
  k1_units "$@" | sed -n "${n}p" | cut -f1
}
k1_slot_locks_free() {  # every slot lock under state/autolaunch-slots is free
  local f
  for f in "$H"/state/autolaunch-slots/*; do
    [ -e "$f" ] || continue
    flock -n "$f" true || return 1
  done
}
k1_slot_lock_held() {
  local f
  for f in "$H"/state/autolaunch-slots/*; do
    [ -e "$f" ] || continue
    flock -n "$f" true || return 0
  done
  return 1
}

k1_ready() {  # <id>...: prepared ready entries
  local id
  for id in "$@"; do printf -- '- [ ] %s - k1 fixture (repo: proj) (kind: ship)\n' "$id"; done | backlog
  for id in "$@"; do prep "$id" proj; done
}
k1_inbox_due() {  # <task>: a live task with one unacknowledged message past its grace
  printf 'window=sess:fm-%s\nkind=ship\nharness=claude\nbackend=tmux\n' "$1" > "$H/state/$1.meta"
  ( . "$ROOT/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$H/state" "$1" "k1 steer for $1" >/dev/null ) \
    || fail "k1 fixture: inbox write for $1"
  find "$H/state/$1.inbox" -maxdepth 1 -name '*.msg' -exec touch -d '-1 hour' {} +
}
# shellcheck disable=SC2031 # $! is read in this shell, right after the background start
k1_pass_lock_holder() {  # a live holder of state/.autolaunch.lock from T0
  "$KB/k1-sleep" 100000 &
  K1_HOLDER=$!
  mkdir "$H/state/.autolaunch.lock"
  printf '%s\n' "$K1_HOLDER" > "$H/state/.autolaunch.lock/pid"
  printf '%s\n' "$K1_T0" > "$H/state/.autolaunch.lock/at"
}
k1_teardown() {
  local rec
  for rec in "$KF"/units/*; do [ -f "$rec" ] && kill -KILL "$(k1_unit_field "$rec" pid)" 2>/dev/null; done
  [ -z "${K1_HOLDER:-}" ] || kill -KILL "$K1_HOLDER" 2>/dev/null
  K1_HOLDER=
  fm_test_reap_root_processes "$K1"
}
k1_need_unit() {  # <message> <fixed string>...: fail unless a matching unit started
  local msg=$1
  shift
  [ -n "$(k1_units "$@")" ] || fail "$msg (no fake systemd-run call; $(k1_blocked_passes) pass(es) blocked past 30 s; spawn calls: $(grep -c . "$KF/spawn.log" 2>/dev/null || echo 0); last pass output: $(tail -2 "$KF/pass.out" 2>/dev/null | tr '\n\t' '  ')"
}

k1_prop() { printf '%s\n' "$1" | grep -o "$2=[0-9]*" | head -1 | cut -d= -f2; }
k1_evidence_has() {  # <hand-off line> <fixed string>: the line or the evidence file it names holds it
  local line=$1 want=$2 path
  printf '%s\n' "$line" | grep -qwF -- "$want" && return 0
  path=$(printf '%s\n' "$line" | sed -n 's/.* owned \([^ ]*\).*/\1/p')
  [ -n "$path" ] || return 1
  case "$path" in /*) ;; *) path="$H/$path" ;; esac
  grep -qwF -- "$want" "$path" 2>/dev/null
}
k1_main_of() {  # <fixed string>: main pid of the first fake unit whose call holds it
  local rec
  rec=$(grep -lF -- "$1" "$KF"/units/* 2>/dev/null | head -1)
  [ -n "$rec" ] && k1_unit_field "$rec" pid
}
k1_wait_file() {  # <file>: up to 5 real seconds
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 50 ]; do "$KB/k1-sleep" 0.1; i=$((i + 1)); done
  [ -s "$1" ]
}
k1_live_units() {  # <RuntimeMaxSec>: fake units of that deadline whose main still runs
  local rec n=0
  for rec in "$KF"/units/*; do
    [ -f "$rec" ] && [ "$(k1_unit_field "$rec" max)" = "$1" ] || continue
    k1_alive "$(k1_unit_field "$rec" pid)" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}
k1_teardown_all() {
  local rec
  for rec in "$TMP_ROOT"/k1-*/fake/units/*; do [ -f "$rec" ] && kill -KILL "$(k1_unit_field "$rec" pid)" 2>/dev/null; done
  [ -z "${K1_HOLDER:-}" ] || kill -KILL "$K1_HOLDER" 2>/dev/null
  return 0
}

# K1-R1: every action is a transient unit with its kind's deadline.
test_actions_start_as_transient_units() {
  local c launch rering
  k1_setup r1-units mate
  k1_ready k1-launch
  k1_inbox_due k1-rering
  k1_pass 0
  k1_need_unit 'K1-R1: no due obligation started as a transient unit; the pass ran the launch itself' --user
  while IFS= read -r c; do
    for want in --user --collect KillMode=process TimeoutStopSec=5 fm-al- --run-action; do
      assert_contains "$c" "$want" "K1-R1: every action unit call carries $want"
    done
  done < <(cut -f2- "$KF/systemd-run.log")
  launch=$(k1_units k1-launch) rering=$(k1_units k1-rering)
  assert_equals 1 "$(printf '%s\n' "$launch" | grep -c .)" 'K1-R1: one unit for the claimed launch'
  assert_equals 600 "$(k1_prop "$launch" RuntimeMaxSec)" 'K1-R1: a launch unit has RuntimeMaxSec=600'
  assert_equals 1 "$(printf '%s\n' "$rering" | grep -c .)" 'K1-R1: one unit for the due re-ring'
  assert_equals 60 "$(k1_prop "$rering" RuntimeMaxSec)" 'K1-R1: a local re-ring unit has RuntimeMaxSec=60'
  assert_equals 2 "$(grep -c . "$KF/systemd-run.log")" 'K1-R1: one unit call per due obligation'
  k1_teardown
  pass 'K1-R1 test_actions_start_as_transient_units: one unit per due obligation, 600 s launch, 60 s re-ring, TimeoutStopSec=5'
}

# K1-R1/R3/R4: a hung launch (stub fm-spawn never returns; its child keeps the
# real spawn lock). Variants: base, term-ignored, recording-cut, child-exited,
# late-start, agent-first.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_hung_launch() {  # <case> <variant>
  local variant=$2 start main holder t cut_done=0 line bound=680 last req
  k1_setup "$1" mate
  case "$variant" in
    child-exited) printf 'hung-child-exits\n' > "$KF/spawn-mode" ;;
    agent-first) printf 'hung-agent-first\n' > "$KF/spawn-mode" ;;
    *) printf 'hung\n' > "$KF/spawn-mode" ;;
  esac
  [ "$variant" != term-ignored ] || : > "$KF/ignore-term"
  [ "$variant" != recording-cut ] || bound=735
  k1_ready k1-hung
  k1_pass 0
  case "$variant" in
    base) req='K1-R1 (base): the never-returning launch has no transient unit and no deadline; it stays attempted and holds its slot for ever' ;;
    term-ignored|recording-cut) req="K1-R4 ($variant): no hand-off bound exists; the never-returning launch has no deadline, so no hand-off ever comes by 680 or 735 s" ;;
    *) req="K1-R3 ($variant): no hand-off; the never-returning launch has no deadline, so no timeout, spawn-lock read or owned record ever happens" ;;
  esac
  k1_need_unit "$req" k1-hung
  line=$(k1_units k1-hung | head -1)
  assert_equals 600 "$(k1_prop "$line" RuntimeMaxSec)" "K1-R1 ($variant): launch deadline RuntimeMaxSec=600"
  assert_equals 5 "$(k1_prop "$line" TimeoutStopSec)" "K1-R1 ($variant): stop grace TimeoutStopSec=5"
  start=$(k1_unit_start 1 k1-hung)
  main=$(k1_main_of k1-hung)
  k1_wait_file "$KF/holder-k1-hung.pid" || fail "K1-R1 ($variant): the launch unit never ran the spawn"
  holder=$(cat "$KF/holder-k1-hung.pid")
  k1_alive "$main" || fail "K1-R1 ($variant): the unit's main process ended before its deadline"
  k1_slot_lock_held || fail "K1-R1 ($variant): the running action holds no slot lock under state/autolaunch-slots/"
  k1_watch owned '[ -n "$(k1_owned k1-hung)" ]'
  k1_watch launched '[ -n "$(k1_lines "$LOG" k1-hung launched)" ]'
  last=$((start - K1_T0 + bound + 165))
  t=55
  while [ "$t" -le "$last" ]; do
    if [ "$variant" = recording-cut ] && [ "$cut_done" = 0 ] && [ $((K1_T0 + t)) -ge $((start + 600)) ]; then
      k1_pass "$t" kill; cut_done=1
    else
      k1_pass "$t"
    fi
    if [ "$variant" = late-start ] && [ -n "$(k1_seen owned)" ]; then : > "$KF/agent-go-k1-hung"; fi
    t=$((t + 55))
  done
  ! k1_alive "$main" || fail "K1-R1 ($variant): the main process outlived deadline plus 5 s"
  k1_slot_locks_free || fail "K1-R1 ($variant): the slot lock is still held after the main process ended"
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-hung)" "K1-R3 ($variant): the loop never retries a timed-out launch"
  assert_equals 1 "$(k1_units_max_count 600 k1-hung)" "K1-R3 ($variant): no second launch unit"
  assert_absent "$KF/send.log" "K1-R3 ($variant): a mate-home task key is never sent through fm-send"
  if [ "$variant" = agent-first ]; then
    assert_equals 0 "$(k1_owned k1-hung | grep -c .)" 'K1-R3 (started before hang): a live agent means no owned record'
    [ -n "$(k1_seen launched)" ] || fail 'K1-R3 (started before hang): the pass never recorded launched for the live agent'
    k1_teardown; return 0
  fi
  [ -n "$(k1_lines "$LOG" k1-hung failed:timeout)" ] || fail "K1-R1 ($variant): no failed:timeout record after the main process was gone"
  assert_equals 1 "$(k1_owned k1-hung | grep -c .)" "K1-R3 ($variant): exactly one owned hand-off for the timed-out launch"
  k1_within owned "$start" "$bound" "K1-R4 ($variant): owned hand-off within $bound s of the launch unit start"
  line=$(k1_owned k1-hung)
  case "$variant" in
    child-exited)
      assert_absent "$H/state/.spawn-k1-hung.lock" 'K1-R3 (child exited): the spawn lock was taken and released' ;;
    *)
      k1_alive "$holder" || fail "K1-R3 ($variant): fixture holder died"
      k1_evidence_has "$line" "spawn_lock_holder=$holder" || fail "K1-R3 ($variant): the owned record does not name spawn_lock_holder=$holder: $line" ;;
  esac
  if [ "$variant" = recording-cut ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R4 (recording pass cut): the cut pass records pass killed=1'
    k1_evidence_has "$line" overrun=1 || [ -n "$(k1_lines "$LOG" k1-hung overrun=1)" ] \
      || fail 'K1-R4 (recording pass cut): the late hand-off is not marked overrun=1'
  fi
  if [ "$variant" = late-start ]; then
    [ -n "$(k1_seen launched)" ] || fail 'K1-R3 (late start): the late agent start was never recorded launched'
    assert_equals 1 "$(k1_count "$H/state/k1-hung.status" resolved launched-late)" 'K1-R3 (late start): the key closes resolved: launched-late'
  fi
  k1_teardown
}
test_hung_action_times_out_and_reaches_responder_once() {
  k1_hung_launch r1-hung base
  pass 'K1-R1/R3 test_hung_action_times_out_and_reaches_responder_once: deadline, free slot, failed:timeout, one owned spawn_lock_holder hand-off by 680 s'
}
test_hung_action_times_out_and_reaches_responder_once_term_ignored() {
  k1_hung_launch r4-term term-ignored
  pass 'K1-R4 term-ignored main: gone by the KILL, hand-off by 680 s'
}
test_hung_action_times_out_and_reaches_responder_once_recording_pass_cut() {
  k1_hung_launch r4-cut recording-cut
  pass 'K1-R4 recording pass cut: pass killed=1, hand-off by 735 s marked overrun=1'
}
test_hung_action_times_out_and_reaches_responder_once_child_exited() {
  k1_hung_launch r3-exited child-exited
  pass 'K1-R3 child exited: lock taken and released, one owned hand-off'
}
test_hung_action_times_out_and_reaches_responder_once_late_start() {
  k1_hung_launch r3-late late-start
  pass 'K1-R3 late start: one launch, launched, resolved: launched-late'
}
test_hung_action_times_out_and_reaches_responder_once_started_before_hang() {
  k1_hung_launch r3-first agent-first
  pass 'K1-R3 started before hang: launched, no owned record'
}

# K1-R2: a hung delivery is an ordinary failed attempt; rungs 1 and 2, then
# one owned record; an unrelated re-ring due meanwhile runs on time.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_hung_action_times_out_and_reaches_responder_once_delivery() {
  local t rung2 other_due=''
  k1_setup r2-delivery mate
  k1_inbox_due k1-dlv
  printf 'k1-dlv\n' > "$KF/hang-match"
  k1_pass 0
  k1_need_unit 'K1-R2 (delivery): the due re-ring never became a 60 s unit, so a hang has no timeout path' k1-dlv
  assert_equals 60 "$(k1_prop "$(k1_units k1-dlv | head -1)" RuntimeMaxSec)" 'K1-R2 (delivery): re-ring deadline 60 s'
  k1_watch owned '[ -n "$(k1_owned k1-dlv)" ]'
  t=55
  while [ "$t" -le 1100 ]; do
    if [ "$t" = 165 ]; then k1_inbox_due k1-other; other_due=$((K1_T0 + t)); fi
    k1_pass "$t"
    if [ "$t" = 165 ]; then
      [ -n "$(k1_units k1-other)" ] || fail 'K1-R2 (delivery): the unrelated re-ring due at 165 s did not start on that pass'
      [ "$(k1_unit_start 1 k1-other)" -le $((other_due + 20)) ] || fail 'K1-R2 (delivery): the unrelated re-ring started late'
    fi
    t=$((t + 55))
  done
  [ -n "$(k1_lines "$LOG" k1-dlv failed:timeout)" ] || fail 'K1-R2 (delivery): the timed-out delivery was never recorded failed:timeout'
  assert_equals 3 "$(k1_units_max_count 60 k1-dlv)" 'K1-R2 (delivery): attempt, rung 1 and rung 2, then no more delivery units'
  assert_equals 1 "$(k1_owned k1-dlv | grep -c .)" 'K1-R2 (delivery): one owned record at the failed rung 2'
  rung2=$(k1_units_max_start 3 60 k1-dlv)
  k1_within owned $((rung2 + 60 + 5)) 75 'K1-R2/R7 (delivery): responder within 75 s of the failed rung 2'
  k1_teardown
  pass 'K1-R2 delivery variant: rungs 1-2 on timeout, one owned record, unrelated re-ring on time'
}

# K1-R2: a timed-out diagnosis records diagnosis=failed:timeout and the next
# rung, with no new owned record.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_hung_action_times_out_and_reaches_responder_once_diagnosis() {
  local diag_unit
  k1_setup r2-diag mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  printf 'hang\n' > "$KF/codex-mode"
  k1_ready k1-dx
  k1_watch owned '[ -n "$(k1_owned k1-dx)" ]'
  k1_passes 0 1925
  assert_equals 1 "$(k1_owned k1-dx | grep -c .)" 'K1-R2 (diagnosis): an unknown failure is handed to the responder once (no ladder today)'
  diag_unit=$(k1_units_max 900 --user | head -1)
  [ -n "$diag_unit" ] || fail 'K1-R1/R2 (diagnosis): rung 3 never ran as a 900 s unit'
  grep -q 'codex' "$KF/diag.log" 2>/dev/null || fail 'K1-R2 (diagnosis): rung 3 never called the diagnosis command'
  { grep -rqsF 'diagnosis=failed:timeout' "$LOG" "$H/state/autolaunch-diag"; } \
    || fail 'K1-R2 (diagnosis): the timed-out rung 3 is not recorded diagnosis=failed:timeout'
  grep -q 'claude' "$KF/diag.log" 2>/dev/null || fail 'K1-R2 (diagnosis): the key did not move to rung 4 after the timeout'
  assert_equals 1 "$(k1_owned k1-dx | grep -c .)" 'K1-R2 (diagnosis): the diagnosis timeout adds no owned record'
  k1_teardown
  pass 'K1-R2 diagnosis variant: 900 s rung-3 unit, diagnosis=failed:timeout, rung 4, no new owned record'
}

# K1-R5: a dropped event is repaired by 130 s through a killed pass.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_dropped_event() {  # <case> <cut: term|none> <bound>
  k1_setup "$1" mate
  k1_ready k1-ev
  printf '0\n' > "$KF/free"
  k1_pass 0
  printf '1\n' > "$KF/free"   # an agent exits; its pane event is dropped (no kick)
  # Repaired = the freed seat's launch is under way: its unit call (written by
  # the pass itself) or, in-process, its spawn call.
  k1_watch repaired '[ -n "$(k1_units k1-ev)$(k1_lines "$KF/spawn.log" k1-ev)" ]'
  if [ "$2" = term ]; then k1_pass 55 term; else k1_pass 55; fi
  k1_pass 110
  if [ "$2" = term ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R5: the cut pass records pass killed=1 (today a cut pass leaves no record)'
    [ -n "$(k1_lines "$LOG" k1-ev overrun=1)" ] || fail 'K1-R5: the late repair sample is not marked overrun=1'
  fi
  k1_within repaired "$K1_T0" "$3" "K1-R5: dropped event repaired within $3 s"
  k1_teardown
}
test_dropped_event_repaired_after_killed_pass() {
  k1_dropped_event r5-cut term 130
  pass 'K1-R5 test_dropped_event_repaired_after_killed_pass: pass killed=1, repaired by 130 s, overrun=1'
}
test_dropped_event_repaired_after_killed_pass_step_completes() {
  k1_dropped_event r5-whole none 75
  pass 'K1-R5 (K2c case) dropped event repaired within 75 s when step (1) completes'
}

# K1-R6: a never-releasing live holder of .autolaunch.lock.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_persistent_pass_lock_holder_opens_one_responder_key() {
  local explain key
  k1_setup r6-lock mate
  k1_ready k1-wait
  k1_inbox_due k1-rr
  k1_pass_lock_holder
  k1_watch key '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" ]'
  k1_pass 55
  assert_equals 1 "$(k1_count "$LOG" overrun "holder=$K1_HOLDER held_s=")" 'K1-R6: a busy pass writes one overrun holder=<pid> held_s=<n> record (today it exits silently)'
  [ -n "$(k1_units k1-rr)" ] || fail 'K1-R6: the due re-ring was not started in step (2) behind the busy lock'
  k1_pass 110; k1_pass 165; k1_pass 220
  assert_equals 4 "$(k1_count "$LOG" overrun "holder=$K1_HOLDER held_s=")" 'K1-R6: one overrun record per busy pass'
  k1_within key "$K1_T0" 165 'K1-R6: ctl-e-pass-lock key within 165 s of the hold starting'
  key=$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)
  assert_equals 1 "$(printf '%s\n' "$key" | grep -c .)" 'K1-R6: exactly one key for one persistent holder'
  k1_evidence_has "$key" "$K1_HOLDER" || fail "K1-R6: the key does not name the holder pid: $key"
  explain=$(FM_AUTOLAUNCH_NOW_FILE="$KF/clock" PATH="$KB:$PATH" bash "$AL" --explain 2>&1)
  printf '%s\n' "$explain" | grep -F k1-wait | grep -qF pass-lock-held || fail "K1-R6: --explain does not list k1-wait as pass-lock-held: $explain"
  assert_absent "$KF/spawn.log" 'K1-R6: the prepared entry is never launched while the lock is held'
  assert_equals "$K1_HOLDER" "$(cat "$H/state/.autolaunch.lock/pid")" 'K1-R6: the live holder lock is never taken'
  k1_alive "$K1_HOLDER" || fail 'K1-R6: the live holder was killed'
  kill -KILL "$K1_HOLDER"; wait "$K1_HOLDER" 2>/dev/null; K1_HOLDER=
  k1_pass 275
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" resolved ctl-e-pass-lock-)" 'K1-R6: the key closes on the first pass that acquires the lock'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'K1-R6: no second key'
  k1_teardown
  pass 'K1-R6 test_persistent_pass_lock_holder_opens_one_responder_key: overrun per pass, re-ring on time, pass-lock-held, one key by 165 s, closed after release'
}

# K1-R7: unknown failure ladder bound, then the queued-diagnosis skip bound.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_unknown_failure_escalation_is_bounded() {
  local rung2
  k1_setup r7-unknown mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  k1_ready k1-unk
  k1_watch owned '[ -n "$(k1_owned k1-unk)" ]'
  k1_watch diag '[ -s "$KF/diag.log" ]'
  k1_passes 0 1210
  assert_equals 1 "$(k1_owned k1-unk | grep -c .)" 'K1-R7: an unknown failure reaches one responder record after its failed rung 2 (today: a refused record every pass)'
  assert_equals 2 "$(k1_count "$LOG" k1-unk retry)" 'K1-R7: two deterministic retries (rungs 1-2)'
  assert_equals 3 "$(k1_units_max_count 600 k1-unk)" 'K1-R7: attempt plus two retries'
  rung2=$(k1_units_max_start 3 600 k1-unk)
  k1_within owned "$rung2" 75 'K1-R7: responder record within 75 s of the failed rung 2'
  [ -n "$(k1_seen diag)" ] || fail 'K1-R7: no diagnosis call after the hand-off'
  [ "$(k1_seen owned)" -le "$(k1_seen diag)" ] || fail 'K1-R7: ownership waited for a diagnosis call'
  grep -F codex "$KF/diag.log" | grep -qF gpt-6.1-sol || fail 'K1-R7: rung 3 is not the gpt-6.1-sol call'
  grep -F claude "$KF/diag.log" | grep -qF claude-opus-5-5 || fail 'K1-R7: rung 4 is not the claude-opus-5-5 call'
  assert_equals 1 "$(k1_count "$LOG" k1-unk exhausted)" 'K1-R7: one exhausted record'
  assert_equals 1 "$(k1_owned k1-unk | grep -c .)" 'K1-R7: no second responder record'
  k1_teardown
  pass 'K1-R7 test_unknown_failure_escalation_is_bounded: 2 retries, responder within 75 s of failed rung 2, rungs 3-5 after'
}
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_unknown_failure_escalation_is_bounded_ten_keys() {
  local i id ids='' queued=0
  k1_setup r7-ten mate
  printf 'fail-unknown\n' > "$KF/spawn-mode"
  printf 'hang\n' > "$KF/codex-mode"
  printf '10\n' > "$KF/free"
  for i in 01 02 03 04 05 06 07 08 09 10; do ids="$ids k1-u$i"; done  # no id is a substring of another
  # shellcheck disable=SC2086 # one id per word
  k1_ready $ids
  for id in $ids; do
    k1_watch "owned-$id" "[ -n \"\$(k1_owned $id)\" ]"
    k1_watch "queued-$id" "[ -n \"\$(k1_lines \"\$LOG\" $id diagnose-queued)\" ]"
    k1_watch "skipped-$id" "grep -lsF skipped-capacity \"\$H\"/state/autolaunch-diag/*$id*summary* >/dev/null"
  done
  k1_watch two-diag '[ "$(k1_live_units 900)" -gt 1 ]'
  k1_passes 0 1485
  for id in $ids; do
    assert_equals 1 "$(k1_owned "$id" | grep -c .)" "K1-R7 (ten keys): $id has exactly one responder record (today: none)"
    k1_within "owned-$id" "$(k1_units_max_start 3 600 "$id")" 75 "K1-R7 (ten keys): $id responder within 75 s of its failed rung 2"
    if [ -n "$(k1_seen "queued-$id")" ]; then
      queued=$((queued + 1))
      k1_within "skipped-$id" "$(k1_seen "queued-$id")" 315 "K1-R7 (ten keys): queued $id gets diagnosis=skipped-capacity within 315 s"
    fi
  done
  [ "$queued" -ge 9 ] || fail "K1-R7 (ten keys): with one diagnosis running, nine keys must wait as diagnose-queued; saw $queued"
  [ -z "$(k1_seen two-diag)" ] || fail 'K1-R7 (ten keys): two diagnosis calls ran at once'
  k1_teardown
  pass 'K1-R7 ten keys: every responder within 75 s, every queued key skipped-capacity within 315 s'
}

# K1-R8: every step (1) cut under a new pass PID.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_repeated_cut_passes_reach_responder() {
  local t
  k1_setup r8-cuts mate
  k1_ready k1-int
  k1_inbox_due k1-rr8
  k1_watch incident '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-)" ]'
  for t in 0 55 110 165 220 275; do k1_pass "$t" kill; done
  [ -n "$(k1_seen incident)" ] || fail 'K1-R8: six consecutive cut passes reached no technical responder'
  k1_within incident "$K1_T0" 165 'K1-R8: repeated cut passes reach the responder within 165 s (tester-chosen bound, see report)'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-)" 'K1-R8: exactly one incident'
  assert_equals 6 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R8: every cut pass records pass killed=1'
  [ -n "$(k1_units k1-rr8)" ] || fail 'K1-R8: the unrelated re-ring did not continue'
  assert_absent "$KF/spawn.log" 'K1-R8: interrupted work is not launched'
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" resolved)" 'K1-R8: interrupted work stays unresolved'
  k1_teardown
  pass 'K1-R8 test_repeated_cut_passes_reach_responder: one incident within 165 s, re-rings continue, work unresolved'
}

# K1-R9: the unit's main process survives KILL.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_action_alive_after_kill_deadline() {
  local start main
  k1_setup r9-alive mate
  printf 'hung\n' > "$KF/spawn-mode"
  printf 'k1-stuck\n' > "$KF/unkillable-match"
  k1_ready k1-stuck
  k1_pass 0
  k1_need_unit 'K1-R9: the action has no unit or deadline, so it stays attempted for ever' k1-stuck
  start=$(k1_unit_start 1 k1-stuck)
  main=$(k1_main_of k1-stuck)
  k1_watch owned '[ -n "$(k1_owned k1-stuck)" ]'
  k1_passes 55 $((start - K1_T0 + 680 + 165))
  assert_equals 1 "$(k1_owned k1-stuck | grep -c .)" 'K1-R9: deadline plus grace expiry with a live main produces one responder hand-off'
  k1_within owned "$start" 680 'K1-R9: hand-off within 680 s of the unit start (tester-chosen: the R4 bound)'
  k1_alive "$main" || fail 'K1-R9: fixture main process died'
  k1_slot_lock_held || fail 'K1-R9: the live action no longer occupies its slot'
  assert_equals 1 "$(k1_count "$KF/spawn.log" k1-stuck)" 'K1-R9: no duplicate launch while the main lives'
  assert_equals 1 "$(k1_units_max_count 600 k1-stuck)" 'K1-R9: no second launch unit'
  k1_teardown
  pass 'K1-R9 test_action_alive_after_kill_deadline: one hand-off by 680 s, slot and identity kept, no duplicate launch'
}

# K1-R10: an event burst is not three 55 s observations.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
test_event_burst_does_not_escalate_normal_lock() {
  k1_setup r10-burst mate
  k1_ready k1-b
  k1_pass_lock_holder
  k1_pass 1; k1_pass 3; k1_pass 5
  assert_equals 0 "$(k1_count "$H/state/autolaunch.status" ctl-e-pass-lock-)" 'K1-R10: three rapid event passes escalated a lock held for 5 s'
  k1_watch key '[ -n "$(k1_lines "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" ]'
  k1_passes 55 220
  k1_within key "$K1_T0" 165 'K1-R10: a genuinely persistent holder still reaches its responder within 165 s'
  assert_equals 1 "$(k1_count "$H/state/autolaunch.status" blocked ctl-e-pass-lock-)" 'K1-R10: one key'
  k1_teardown
  pass 'K1-R10 test_event_burst_does_not_escalate_normal_lock: no key on a burst, one key by 165 s when persistent'
}

# K1-R11: MAIN-home hand-off (no-task key -> fm-send fleet-ops --one-way).
test_responder_handoff_survives_failed_send_and_restart() {
  k1_setup r11-send main
  k1_pass_lock_holder
  printf 'fail\ncrash\n' > "$KF/send-mode"
  k1_passes 55 495
  [ -s "$KF/send.log" ] || fail 'K1-R11: no responder hand-off was ever sent for the persistent-lock key'
  assert_equals 0 "$(cut -f2 "$KF/send.log" | awk '$1 != "fleet-ops"' | grep -c . || true)" 'K1-R11: every hand-off goes to fleet-ops'
  assert_equals 0 "$(cut -f2 "$KF/send.log" | grep -vcF -- --one-way || true)" 'K1-R11: every hand-off is --one-way'
  [ "$(grep -c . "$KF/send.log")" -ge 3 ] || fail "K1-R11: the hand-off was not retried after the failed enqueue and the crash: $(cat "$KF/send.log")"
  assert_equals 1 "$(cut -f2- "$KF/send.log" | sort -u | grep -c .)" 'K1-R11: every retry carries the same identity'
  assert_equals 1 "$(grep -c . "$KF/accepted")" 'K1-R11: exactly one accepted hand-off'
  assert_equals 3 "$(grep -c . "$KF/send.log")" 'K1-R11: no send after the receipt is recorded'
  [ ! -s "$H/state/.wake-queue" ] || fail 'K1-R11: the hand-off woke MAIN'
  assert_equals '' "$(find "$H/state" -maxdepth 1 -name '*.status' -size +0)" 'K1-R11: a MAIN-home no-task key writes no status line'
  k1_teardown
  pass 'K1-R11 test_responder_handoff_survives_failed_send_and_restart: one accepted hand-off, same identity, no MAIN wake'
}

# K1-R7/R12: an unanswered technical decision key.
# shellcheck disable=SC2016 # k1_watch conditions are evaluated after each pass
k1_unanswered() {  # <case> <cut pass t or none> <bound>
  local t line
  k1_setup "$1" mate
  printf 'window=sess:fm-k1-ask\nkind=ship\nharness=claude\nbackend=tmux\n' > "$H/state/k1-ask.meta"
  printf 'needs-decision [key=k1-tech] [at=%s]: pick the retry backoff for the flaky fetch\n' "$K1_T0" > "$H/state/k1-ask.status"
  : > "$H/config/open-decision-reminders"
  k1_watch ask '[ -n "$(k1_lines "$H/state/k1-ask.status" blocked ctl-c-ask-)" ]'
  t=0
  while [ "$t" -le 495 ]; do
    if [ "$t" = "$2" ]; then k1_pass "$t" term; else k1_pass "$t"; fi
    t=$((t + 55))
  done
  line=$(k1_lines "$H/state/k1-ask.status" blocked ctl-c-ask-)
  [ -n "$line" ] || fail 'K1-R12: the unanswered technical key never got a ctl-c-ask responder record (today: no owner)'
  assert_equals 1 "$(printf '%s\n' "$line" | grep -c .)" 'K1-R12: exactly one ctl-c-ask record, never repeated'
  assert_contains "$line" k1-tech 'K1-R12: the record names the key'
  assert_contains "$line" unanswered 'K1-R12: the record says unanswered'
  k1_within ask "$K1_T0" "$3" "K1-R12: responder owns the key within $3 s of opening"
  assert_absent "$KF/diag.log" 'K1-R12: no diagnosis call for a known case'
  assert_equals 0 "$(k1_count "$LOG" diagnose)" 'K1-R12: no diagnose record'
  assert_absent "$KF/send.log" 'K1-R12: a mate-home key is never sent through fm-send'
  if [ "$2" != none ]; then
    assert_equals 1 "$(k1_count "$LOG" 'pass killed=1')" 'K1-R12: the interrupted recording pass records pass killed=1'
    case "$line" in *overrun=1*) ;; *) [ -n "$(k1_lines "$LOG" ctl-c-ask- overrun=1)" ] || fail 'K1-R12: the hand-off after an interrupted pass is not marked overrun=1 (falsely on time)' ;; esac
  fi
  k1_teardown
}
test_unanswered_technical_key_goes_to_responder_without_diagnosis() {
  k1_unanswered r12-ask none 255
  pass 'K1-R7/R12 test_unanswered_technical_key_goes_to_responder_without_diagnosis: one ctl-c-ask within 255 s, no diagnosis'
}
test_unanswered_technical_key_goes_to_responder_without_diagnosis_interrupted() {
  k1_unanswered r12-cut 220 310
  pass 'K1-R12 interrupted recording pass: one ctl-c-ask within 310 s, overrun=1, no diagnosis'
}

K1_TESTS='test_actions_start_as_transient_units
test_hung_action_times_out_and_reaches_responder_once
test_hung_action_times_out_and_reaches_responder_once_delivery
test_hung_action_times_out_and_reaches_responder_once_diagnosis
test_hung_action_times_out_and_reaches_responder_once_child_exited
test_hung_action_times_out_and_reaches_responder_once_late_start
test_hung_action_times_out_and_reaches_responder_once_started_before_hang
test_hung_action_times_out_and_reaches_responder_once_term_ignored
test_hung_action_times_out_and_reaches_responder_once_recording_pass_cut
test_dropped_event_repaired_after_killed_pass
test_dropped_event_repaired_after_killed_pass_step_completes
test_persistent_pass_lock_holder_opens_one_responder_key
test_unknown_failure_escalation_is_bounded
test_unknown_failure_escalation_is_bounded_ten_keys
test_repeated_cut_passes_reach_responder
test_action_alive_after_kill_deadline
test_event_burst_does_not_escalate_normal_lock
test_responder_handoff_survives_failed_send_and_restart
test_unanswered_technical_key_goes_to_responder_without_diagnosis
test_unanswered_technical_key_goes_to_responder_without_diagnosis_interrupted'
k1_run() {  # <test name>... (k1 = all)
  local name
  trap 'k1_teardown_all; fm_test_cleanup' EXIT
  # shellcheck disable=SC2086 # one test name per word
  [ "$*" != k1 ] || set -- $K1_TESTS
  for name in "$@"; do
    [ "$(type -t "$name")" = function ] || fail "unknown K1 case $name"
    "$name"
  done
}
if [ -n "${FM_AUTOLAUNCH_TEST_ONLY:-}" ]; then
  # shellcheck disable=SC2086 # one test name per word
  k1_run $FM_AUTOLAUNCH_TEST_ONLY
  exit 0
fi
# === END tester-owned (definitions; the full run calls k1_run k1 below) ====

# --- x-prep persona, Doctor and XAI surface admission -------------------------
reset 2
mkdir -p "$H/projects/NOT_Q"
backlog <<'MD'
- [ ] persona-missing - standard screen (repo: NOT_Q) (kind: ship)
- [ ] doctor-missing - add an XAI tool (repo: NOT_Q) (kind: ship)
- [ ] surface-missing - changed system prompt (repo: NOT_Q) (kind: ship)
- [ ] valid-persona - complete full prep (repo: NOT_Q) (kind: ship)
- [ ] small-persona - small fix (repo: NOT_Q) (kind: ship)
- [ ] legacy-persona - legacy prep (repo: NOT_Q) (kind: ship)
MD
for id in persona-missing doctor-missing surface-missing valid-persona small-persona legacy-persona; do prep "$id" NOT_Q; done
printf '%s\n' 'DOCTOR: no Doctor change; because this changes only labels.' 'XAI-SURFACE: none; because labels only.' >> "$H/data/persona-missing/prep.md"
printf '%s\n' 'PERSONA: researcher new to X; see the same strategy evidence.; surfaces=chat; usage=beginner' 'SCOPE: openwebui/tools/new_tool.py' 'XAI-SURFACE: tool openwebui/tools/new_tool.py' >> "$H/data/doctor-missing/prep.md"
printf '%s\n' 'PERSONA: researcher familiar with X; observe unchanged factual evidence.; surfaces=pages; usage=experienced' 'DOCTOR: knowledge question for the changed prompt; expected evidence.' >> "$H/data/surface-missing/prep.md"
printf '%s\n' 'PERSONA: admin/owner familiar with X; grants unchanged; observe saved settings.; surfaces=pages; usage=experienced' 'DOCTOR: battery Read-settings; expected saved settings.' 'XAI-SURFACE: tool Read-settings' >> "$H/data/valid-persona/prep.md"
printf '%s\n' 'SLICE: main/labels; PERSONA: expert trader new to X; unchanged figures.; surfaces=chat; usage=beginner' 'PROOF: existing label check, unchanged factual outcome.' 'DOCTOR: no Doctor change; because this changes labels only.' 'XAI-SURFACE: none; because labels only.' > "$H/data/small-persona/prep.md"
# Fixed introduction date: 2026-11-03 Pacific midnight, not the filing date.
python3 - "$H" <<'PY'
import os, sys
from pathlib import Path
h = Path(sys.argv[1])
for name in ('persona-missing', 'doctor-missing', 'surface-missing', 'valid-persona', 'small-persona'):
    os.utime(h / 'data' / name / 'prep.md', (1793692800, 1793692800))
os.utime(h / 'data/legacy-persona/prep.md', (1793692799, 1793692799))
PY
list=$(bash "$AL" --list-prepared 2>&1)
assert_equals $'valid-persona\nsmall-persona\nlegacy-persona' "$list" 'new X preps require PERSONA, DOCTOR and XAI-SURFACE; pre-cutoff prep has dated grace'
bash "$AL" >/dev/null 2>&1
for pair in persona-missing:PERSONA doctor-missing:DOCTOR surface-missing:XAI-SURFACE; do
  id=${pair%:*} label=${pair#*:}
  assert_contains "$(cat "$LOG")" "$id"$'\t-\trefused:not prepared: '"$label missing" "missing $label refusal is actionable"
  assert_not_contains "$(cat "$FAKE/spawn.log")" "$id " "missing $label never reaches spawn"
done
assert_contains "$(cat "$FAKE/spawn.log")" 'valid-persona ' 'complete full prep reaches spawn'
assert_contains "$(cat "$FAKE/spawn.log")" 'small-persona ' 'small fix uses persona in SLICE'
printf '%s\n' 'PERSONA: tester/debugger familiar with X; reproduce the same visible result.; surfaces=pages; usage=experienced' >> "$H/data/persona-missing/prep.md"
printf '%s\n' 'DOCTOR: knowledge question for the new tool; expected invocation and refusal.' >> "$H/data/doctor-missing/prep.md"
printf '%s\n' 'XAI-SURFACE: system prompt openwebui/system-prompt.md' >> "$H/data/surface-missing/prep.md"
assert_equals $'persona-missing\ndoctor-missing\nsurface-missing\nvalid-persona\nsmall-persona\nlegacy-persona' "$(bash "$AL" --list-prepared)" 'adding the missing lines admits the same tasks'
touch "$H/data/legacy-persona/prep.md"
assert_not_contains "$(bash "$AL" --list-prepared)" 'legacy-persona' 'revised legacy prep loses grace'

# One complete task, then one malformed declaration at a time, at the CLI seam.
for invalid in persona-empty doctor-empty surface-empty persona-template doctor-reason surface-reason fenced; do
  reset 1
  printf '%s\n' '- [ ] malformed - X prep (repo: NOT_Q) (kind: ship)' | backlog
  prep malformed NOT_Q
  persona='PERSONA: researcher new to X; see the same evidence.; surfaces=chat; usage=beginner'
  doctor='DOCTOR: no Doctor change; because labels only.'
  surface='XAI-SURFACE: none; because labels only.'
  case "$invalid" in
    persona-empty) persona='PERSONA:   ' ;;
    doctor-empty) doctor='DOCTOR:   ' ;;
    surface-empty) surface='XAI-SURFACE:   ' ;;
    persona-template) persona='PERSONA: job/outcome; market expertise; familiarity with X and its terms; explanation preference; desired automation; access principal/grants; starting profile/card state; observable success.' ;;
    doctor-reason) doctor='DOCTOR: no Doctor change; because' ;;
    surface-reason) surface='XAI-SURFACE: none' ;;
  esac
  if [ "$invalid" = fenced ]; then
    printf '%s\n' '```' "$persona" "$doctor" "$surface" '```' > "$H/data/malformed/prep.md"
  else
    printf '%s\n' "$persona" "$doctor" "$surface" > "$H/data/malformed/prep.md"
  fi
  assert_equals '' "$(bash "$AL" --list-prepared)" "$invalid cannot satisfy admission"
done
printf '%s\n' '**PERSONA:** researcher new to X; surfaces=chat; usage=beginner' '**DOCTOR:** no Doctor change; because labels only.' '**XAI-SURFACE:** none; because labels only.' > "$H/data/malformed/prep.md"
assert_equals 'malformed' "$(bash "$AL" --list-prepared)" 'real Markdown fields count'
# The brief cannot supply a line missing from the selected linked prep.
printf '%s\n' 'PERSONA: example; surfaces=pages; usage=experienced' 'DOCTOR: battery example' 'XAI-SURFACE: tool example' >> "$H/data/malformed/brief.md"
mkdir -p "$H/data/shared-prep"
printf '%s\n' 'PERSONA: researcher new to X; surfaces=chat; usage=beginner' 'DOCTOR: battery Read-settings' > "$H/data/shared-prep/prep.md"
rm "$H/data/malformed/prep.md"
printf '%s\n' '- [ ] malformed - X prep (repo: NOT_Q) (kind: ship)' '  Prep: data/shared-prep/prep.md' | backlog
assert_equals '' "$(bash "$AL" --list-prepared)" 'linked prep must carry its own XAI-SURFACE'
printf '%s\n' 'XAI-SURFACE: tool Read-settings' >> "$H/data/shared-prep/prep.md"
assert_equals 'malformed' "$(bash "$AL" --list-prepared)" 'correcting the linked prep admits it'
# Page+chat outcome: neither middle-only nor either endpoint alone suffices.
reset 1
printf '%s\n' '- [ ] dual-channel - same outcome on page and chat (repo: NOT_Q) (kind: ship)' | backlog
prep dual-channel NOT_Q
for usage in middle beginner experienced; do
  printf '%s\n' "PERSONA: researcher; surfaces=pages,chat; usage=$usage; same factual outcome." 'DOCTOR: battery Read-settings; expected unchanged settings.' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals '' "$(bash "$AL" --list-prepared)" "page+chat prep with $usage only misses beginner/experienced coverage"
done
printf '%s\n' 'PERSONA: researcher; surfaces=pages,chat; usage=beginner,experienced,middle; same task and facts.' 'DOCTOR: battery Read-settings; expected unchanged settings.' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
assert_equals 'dual-channel' "$(bash "$AL" --list-prepared)" 'beginner chat-first and experienced pages-only coverage admits the same dual-channel slice'
for declarations in \
  'surfaces=pages/chat; usage=middle' \
  'surfaces=pages+chat; usage=middle' \
  'surfaces=pages chat; usage=middle' \
  'surfaces=pages,chat/other; usage=beginner,experienced' \
  'surfaces=pages,chat; usage=beginner,experienced/other' \
  'surfaces=pages,chat; usage=beginner,experienced+middle' \
  'surfaces=pages,chat; usage=beginner,experienced middle' \
  'surfaces=pages,chat; usage=beginner,experienced2'; do
  printf '%s\n' "PERSONA: researcher; $declarations" 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals '' "$(bash "$AL" --list-prepared)" "malformed declaration is not prefix-admitted: $declarations"
done
for declarations in \
  'surfaces=pages; usage=experienced' \
  'surfaces=chat; usage=beginner' \
  'surfaces=pages,chat; usage=beginner,experienced' \
  'surfaces=none; usage=none'; do
  printf '%s\n' "PERSONA: researcher; $declarations; same factual outcome." 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
  assert_equals 'dual-channel' "$(bash "$AL" --list-prepared)" "complete declaration is admitted: $declarations"
done
# Missing declarations cannot silently classify a dual-channel slice as single-channel.
printf '%s\n' 'PERSONA: researcher; same outcome.' 'DOCTOR: battery Read-settings' 'XAI-SURFACE: tool Read-settings' > "$H/data/dual-channel/prep.md"
assert_equals '' "$(bash "$AL" --list-prepared)" 'persona must name surfaces and usage styles'
pass 'X prep PERSONA/DOCTOR/XAI-SURFACE refusal, correction, small fix, Markdown, linked prep, dated grace and usage coverage'
[ "${1:-}" != --x-prep-only ] || exit 0

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
for setting in invalid rank-only absent; do
  case "$setting" in
    invalid) printf 'typo\n' > "$H/config/quota-gate" ;;
    rank-only) printf 'rank-only\n' > "$H/config/quota-gate" ;;
    absent) rm "$H/config/quota-gate" ;;
  esac
  for _ in 1 2; do
    out=$(PATH="$FAKE:$PATH" bash "$AL" --dry-run 2>&1); rc=$?
    expect_code 0 "$rc" "$setting dry-run failed: $out"
    assert_absent "$H/state/.quota-gate-invalid" 'dry-run must not create an invalid-value receipt'
    assert_absent "$LOG" 'dry-run must not write a launch record'
    if [ "$setting" = invalid ]; then
      assert_contains "$out" 'expected rank-only' 'every invalid dry-run must diagnose the setting'
    fi
  done
done
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

# Even when every default is tight, rank-only retains spendPriority order.
reset 1
printf '%s\n' '- [ ] rank-only - prepared (repo: proj) (kind: ship)' | backlog
prep rank-only proj
printf 'rank-only\n' > "$H/config/quota-gate"
printf '%s\n' '{"default":[{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"}]}' > "$H/config/crew-dispatch.json"
jq '(.providers[].quotaSemantics.effectiveAvailability[]) |=
  (.effectivePercentRemaining = 0 | .runway.status = "exhausted_now") |
  (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 9' \
  "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/rank-only.json"
FM_QUOTA_SNAPSHOT_FILE="$FAKE/rank-only.json" bash "$AL" >/dev/null 2>&1
assert_equals $'codex:gpt-5.5\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" 'rank-only retains exhausted defaults and ranks them'
rm "$H/config/quota-gate"
pass 'rank-only autolaunch never removes a default because of quota'

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

for policy in absent rank-only; do
  reset 1
  [ "$policy" != rank-only ] || printf 'rank-only\n' > "$H/config/quota-gate"
  printf '%s\n' '- [ ] numeric-notice - prepared (repo: proj) (kind: ship)' | backlog
  prep numeric-notice proj
  printf '%s\n' '{"default":[{"harness":"opencode"},{"harness":"claude","model":"opus"},{"harness":"codex","model":"gpt-5.5"}]}' > "$H/config/crew-dispatch.json"
  jq '(.providers[] | select(.provider == "claude") | .quotaSemantics.effectiveAvailability[]) |=
      (.runway = {status:"projected_exhaustion",projectionConfidence:"established"} | .selection.spendPriority = 9) |
    (.providers[] | select(.provider == "codex").quotaSemantics.effectiveAvailability[].selection.spendPriority) = 2' \
    "$ROOT/tests/fixtures/quota-axi-healthy.json" > "$FAKE/numeric-notice.json"
  printf 'codex\nopencode\n' > "$FAKE/quota-refuse"
  out=$(FM_QUOTA_SNAPSHOT_FILE="$FAKE/numeric-notice.json" bash "$AL" 2>&1); rc=$?
  expect_code 0 "$rc" "$policy must retain uncertain defaults after passing candidates: $out"
  assert_contains "$(sed -n 1p "$FAKE/spawn.log")" '--harness codex --model gpt-5.5' "$policy ranks passing priority 2 before uncertain priority 9"
  assert_contains "$(sed -n 2p "$FAKE/spawn.log")" '--harness opencode' "$policy retains the first uncertain profile in declared order"
  assert_contains "$(sed -n 3p "$FAKE/spawn.log")" '--harness claude --model opus' "$policy retains numeric notices in the uncertain bucket"
  assert_equals $'claude:opus\tlaunched' "$(cut -f4,5 "$LOG" | head -1)" "$policy keeps numeric notices available for fallback"
  rm -f "$H/config/quota-gate"
done
pass 'passing defaults precede numeric notices and uncertain profiles retain declared order under either policy'

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
  printf 'PERSONA: admin/owner new to X; observe the saved region; surfaces=chat; usage=beginner\nDOCTOR: no Doctor change; because registry-only fixture.\nXAI-SURFACE: none; because registry-only fixture.\n' > "$H/data/x-prep-region-registry/prep.md"
  printf 'PERSONA: trader familiar with X; observe the account currency; surfaces=pages; usage=experienced\nDOCTOR: battery Read-settings, expected saved currency.\nXAI-SURFACE: tool Read-settings\n' > "$H/data/x-engine-account-currency/prep.md"
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
# shellcheck disable=SC2031 # read in this shell; the K1 helpers' own background starts are separate
holder=$!
mkdir "$H/state/.autolaunch.lock"; printf '%s\n' "$holder" > "$H/state/.autolaunch.lock/pid"
out=$(bash "$AL" 2>&1); rc=$?
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
expect_code 0 "$rc" 'busy lock exits quietly'
assert_contains "$out" 'another pass holds' 'busy lock is named'
# Tester-owned (K1-R6): a busy pass now writes one overrun record, so the
# former 'busy lock writes no record' assertion is retired; no launch stays.
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
assert_contains "$out" "Environment=\"FM_HOME=$H\"" 'timer proposal pins FM_HOME'
assert_contains "$out" 'OnUnitActiveSec=5min' 'timer proposal runs every five minutes'
pass 'the check arms through fm-check-register and the timer is only a printed proposal'

# The step-pass matrix uses this same executable seam and hermetic task store.
[ "${1:-}" != --launch-only ] || exit 0
python3 "$ROOT/tests/autolaunch_steps_cases.py" "$ROOT" || fail 'slice step-pass fixtures'
pass 'slice step-pass crash, replay, lease and stall fixtures'

# Tester-owned (lc-core-scheduler K1-R1..R12 oracles, defined above): they
# run last so every earlier case keeps its coverage while they are red.
k1_run k1
