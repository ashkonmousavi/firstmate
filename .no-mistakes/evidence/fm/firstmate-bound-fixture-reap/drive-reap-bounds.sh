#!/usr/bin/env bash
# Drives the shared cleanup helpers (tests/wake-helpers.sh reap / wait_for_exit)
# at the target commit against real processes, and replays the new regression
# fixture from tests/fm-watch-triage.test.sh against the BASE-commit helper
# bodies to show the fixture fails (bounded) before the fix and passes after.
# Usage: drive-reap-bounds.sh <worktree>
set -u
WT=$1
# shellcheck source=/dev/null
. "$WT/tests/wake-helpers.sh"
# The exact regression fixture from the changed suite (function body only).
eval "$(sed -n '/^run_against_term_resistant_child() {/,/^}/p' "$WT/tests/fm-watch-triage.test.sh")"

# Base-commit (cfd9941) helper bodies, verbatim apart from the names.
reap_base() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_for_exit_base() {
  local pid=$1 limit=${2:-50} i=0
  while [ "$i" -lt "$limit" ]; do
    if ! is_live_non_zombie "$pid"; then
      wait "$pid"
      return "$?"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  return 124
}

now() { date +%s.%N; }
el() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.2fs", b - a }'; }
term_resistant() { bash -c "trap '' TERM; : > '$1'; while :; do sleep 0.05; done" & }
await_file() { local i=0; while [ ! -e "$1" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i+1)); done; }
alive() { is_live_non_zombie "$1" && echo alive || echo gone; }

T=$(mktemp -d)
echo "== 1. reap() (target) vs TERM-resistant owned child"
term_resistant "$T/r1"; c=$!; await_file "$T/r1"; t=$(now)
reap "$c"; rc=$?
echo "   reap rc=$rc elapsed=$(el "$t") child=$(alive "$c")"

echo "== 2. wait_for_exit(pid, 5) (target) vs TERM-resistant owned child"
term_resistant "$T/r2"; c=$!; await_file "$T/r2"; t=$(now)
wait_for_exit "$c" 5; rc=$?
echo "   wait_for_exit rc=$rc elapsed=$(el "$t") child=$(alive "$c")"

echo "== 3. reap() (target) vs an ordinary child that honors TERM"
bash -c 'while :; do sleep 0.05; done' & c=$!; sleep 0.3; t=$(now)
reap "$c"; rc=$?
echo "   reap rc=$rc elapsed=$(el "$t") child=$(alive "$c")"

echo "== 4. reap() (target) vs an already-exited, unreaped (zombie) child"
bash -c 'exit 0' & c=$!; sleep 0.5
echo "   before: ps stat=$(ps -p "$c" -o stat= 2>/dev/null | tr -d ' ')"
t=$(now); reap "$c"; rc=$?
echo "   reap rc=$rc elapsed=$(el "$t") ps-entry-after=$(ps -p "$c" -o stat= >/dev/null 2>&1 && echo present || echo reaped)"

echo "== 5. wait_for_exit (target) passes through a normal exit status"
bash -c 'sleep 0.3; exit 3' & c=$!; t=$(now)
wait_for_exit "$c" 50; rc=$?
echo "   wait_for_exit rc=$rc elapsed=$(el "$t")"

echo "== 6. regression fixture from fm-watch-triage.test.sh vs BASE reap (expect bounded FAIL)"
d=$(mktemp -d); t=$(now)
out=$( (run_against_term_resistant_child "$d" reap_base) 2>&1 ); rc=$?
echo "   fixture rc=$rc elapsed=$(el "$t") output: $out"
kill -KILL "$(cat "$d/child.pid" 2>/dev/null)" 2>/dev/null || true

echo "== 7. regression fixture vs BASE wait_for_exit (expect bounded FAIL)"
d=$(mktemp -d); t=$(now)
out=$( (run_against_term_resistant_child "$d" wait_for_exit_base 5) 2>&1 ); rc=$?
echo "   fixture rc=$rc elapsed=$(el "$t") output: $out"
kill -KILL "$(cat "$d/child.pid" 2>/dev/null)" 2>/dev/null || true

echo "== 8. regression fixture vs TARGET reap / wait_for_exit (expect PASS)"
d=$(mktemp -d); t=$(now)
( run_against_term_resistant_child "$d" reap ) 2>&1; rc=$?
echo "   reap fixture rc=$rc status=$(cat "$d/status" 2>/dev/null) elapsed=$(el "$t")"
d=$(mktemp -d); t=$(now)
( run_against_term_resistant_child "$d" wait_for_exit 5 ) 2>&1; rc=$?
echo "   wait_for_exit fixture rc=$rc status=$(cat "$d/status" 2>/dev/null) elapsed=$(el "$t")"

echo "== 9. fault injection: KILL never takes effect (kill shadowed) -> reap reports, returns 1, bounded"
term_resistant "$T/r9"; c=$!; await_file "$T/r9"; t=$(now)
( kill() { [ "$1" = -KILL ] && return 0; builtin kill "$@"; }; reap "$c" ); rc=$?
echo "   reap rc=$rc elapsed=$(el "$t") child=$(alive "$c")"
builtin kill -KILL "$c" 2>/dev/null; wait "$c" 2>/dev/null

echo "== leftover TERM-resistant fixtures owned by this driver:"
pgrep -f "trap '' TERM" -u "$(id -u)" -a | grep -v pgrep || echo "   none"
