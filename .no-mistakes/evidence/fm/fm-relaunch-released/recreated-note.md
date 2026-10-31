# Task
## Captain's intent
Validate copy recreation.
## Firstmate spec
Read the relaunch progress note and respond with LAB_NOTE_RECEIVED. Do not edit files or run any commands.
<!-- fm-pr-overlap:start -->
## SHARED
Overlap was not checked: no planned paths found in SCOPE, FILES, or BLAST RADIUS.
<!-- fm-pr-overlap:end -->

## Progress note (2026-10-31T06:41:05Z)

This task was relaunched on a recreated local copy: branch fm/liveround6 at
63e4b22f1a581584d5152ccf88644aaf8f782af5, checked out fresh from its pull request's remote. Uncommitted
files, ignored files (installed dependencies, build output, caches) and
a no-mistakes run's local state from the previous copy were not carried
over; reinstall what you need, then continue from here.

First, check your instruction inbox: list it with
`find '~/.no-mistakes/worktrees/049a88734b0e/01M686061E2SDSA85JWZVGQT51/.validation-live/liveround6/home/state/liveround6.inbox' -maxdepth 1 -name '*.msg' 2>/dev/null | sort -V`, act on
each message in numeric order, then mv each handled file into
'~/.no-mistakes/worktrees/049a88734b0e/01M686061E2SDSA85JWZVGQT51/.validation-live/liveround6/home/state/liveround6.inbox/handled/'. A steer sent before the relaunch survives there.

Live lab recreation
