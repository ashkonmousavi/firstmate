#!/usr/bin/env bash
# fm-relaunch-note-lib.sh - the one writer of a relaunch's progress note in a
# ship or scout brief, sourced by bin/fm-control.sh (an ordinary relaunch) and
# bin/fm-spawn.sh (a relaunch that recreated a released copy).
#
# A replacement worker inherits the brief but none of the conversation, so the
# note is its only continuity. It must say plainly what the replacement's local
# copy holds: an ordinary relaunch reuses the copy exactly as left, while a
# recreated copy is a fresh checkout of the pull request's branch that carries
# no uncommitted file, ignored file, or local no-mistakes run state from the
# copy teardown released (docs/agent-control.md "Relaunching a released copy").

# fm_relaunch_note_append <brief> <inbox-dir> <note-file> [<branch> <head>]
# Appends one "## Progress note" block carrying the text of <note-file>.
# With <branch> and <head> the block describes a recreated copy instead.
fm_relaunch_note_append() {
  local brief=$1 inbox=$2 note_file=$3 branch=${4-} head=${5-} stamp inbox_q
  stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  inbox_q=$(printf '%s' "$inbox" | sed "s/'/'\\\\''/g")
  {
    echo
    echo "## Progress note ($stamp)"
    echo
    if [ -n "$branch" ]; then
      echo "This task was relaunched on a recreated local copy: branch $branch at"
      echo "$head, checked out fresh from its pull request's remote. Uncommitted"
      echo "files, ignored files (installed dependencies, build output, caches) and"
      echo "a no-mistakes run's local state from the previous copy were not carried"
      echo "over; reinstall what you need, then continue from here."
    else
      echo "This task was relaunched. Continue from here; the local copy and every"
      echo "uncommitted change are exactly as the previous worker left them."
    fi
    echo
    echo "First, check your instruction inbox: list it with"
    echo "\`find '$inbox_q' -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V\`, act on"
    echo "each message in numeric order, then mv each handled file into"
    echo "'$inbox_q/handled/'. A steer sent before the relaunch survives there."
    echo
    cat -- "$note_file"
  } >> "$brief"
}
