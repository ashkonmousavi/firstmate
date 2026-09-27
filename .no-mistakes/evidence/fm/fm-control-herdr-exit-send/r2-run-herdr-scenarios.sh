#!/usr/bin/env bash
# Runs round-2 live Herdr Claude scenarios in parallel, each in its own fm-lab-* session.
# Usage: r2-run-herdr-scenarios.sh <worktree> <evidence-dir> <scenario>...
W=$1; E=$2; shift 2
D=$E/herdr-claude-exit-lab-r2.sh
export LAB_CLAUDE_ENV_STRIP="$(env | grep -o '^CLAUDE[A-Z_]*' | sed 's/^/-u /' | tr '\n' ' ')"
n=0
for s in "$@"; do
  ( sleep $((n*3))
    case $s in
      idle-relaunch) bash $D $W $W "relaunch --harness claude --note lab" ;;
      sendtrace) LAB_SENDTRACE=1 bash $D $W $W ;;
      pending-text-exit-refused) LAB_PRETYPE="hello captain" bash $D $W $W exit ;;
      pending-slash-text-relaunch-refused) LAB_PRETYPE="/compact keep" bash $D $W $W "relaunch --harness claude --note lab" ;;
      done-exit) LAB_PRIME=1 bash $D $W $W exit ;;
      done-relaunch) LAB_PRIME=1 bash $D $W $W "relaunch --harness claude --note lab" ;;
    esac > "$E/r2-live-herdr-claude-$s.txt" 2>&1 ) &
  n=$((n+1))
done
wait
