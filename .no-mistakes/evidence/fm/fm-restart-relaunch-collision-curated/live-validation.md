# Restart collision live validation

Oracle: the supplied intent and later recorded R1/R2/R5/R6/R7 decisions. A normal restart must succeed after correlated persistence; liveness must skip the in-progress mate; independent collision winners without existing completion proof must remain unreached, including alive processes whose brief gate fails. Probe waits must remain bounded, and dead lock owners must not suppress recovery.

All product runs used unchanged target scripts copied into `.live-validation/product`, with a lab home and secondmate fixture beside that code root inside the gate worktree. A nested Git index made the copied tracked-command consumer valid. The initial direct test attempt rejected fixtures nested below the original code root; the first copied-root attempt needed that Git index. Both setup restrictions were corrected without source edits.

Actual tmux and Codex v0.166.0 were used on a private fm-lab socket with a 140x40 terminal. A workspace-local wrapper executed the existing real Codex CLI with `--no-daemon --disable hooks`; this avoided shared-daemon changes and hook trust writes. Login was the existing login. The failed-gate adversarial launch intentionally omitted only `--disable hooks`, reached the real hook-review gate, and failed the product readiness check. The normal successful restart used the supported positional launch path; an exploratory typed-launch attempt was unconfirmed and was not counted as the successful restart.

## Observed results

Normal restart (exit 0):
```
restarted: sm-live (codex)
summary: 1 of 1 restarted, 0 nudged, 0 unreached
```

Concurrent liveness interface observations include:
```
1793510572 probe=alive state=alive
1793510598 skipped: restart holds liveness lock
```

The full watcher subsequently ran eight seconds against an actually dead endpoint under the same exclusion lock. Its timeout was intentional; the watcher process was reaped. Its tick marker appeared and its attempt ledger remained byte-identical:
```
{
  "watcher_exit": 124,
  "liveness_tick_ran": true,
  "ledger_unchanged": true
}
```

### Collision: complete

```
unreached: sm-live: the old agent was stopped, but no replacement launch was confirmed successful within 35s (endpoint reads 'alive'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
summary: 0 of 1 restarted, 0 nudged, 1 unreached
competing launch holds spawn lock
restart lost spawn lock; stopped endpoint state=dead
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
spawned sm-live harness=codex kind=secondmate mode=secondmate yolo=off window=primary:fm-sm-live worktree=~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/secondmate
winner completed with exit=0; endpoint state=alive
{
  "mode": "complete",
  "restart_exit": 3,
  "winner_exit": 0,
  "elapsed_seconds": 54.2,
  "liveness_lock_left": false
}
```

### Collision: gate-failed

```
unreached: sm-live: the old agent was stopped, but no replacement launch was confirmed successful within 35s (endpoint reads 'alive'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
summary: 0 of 1 restarted, 0 nudged, 1 unreached
competing launch holds spawn lock
restart lost spawn lock; stopped endpoint state=dead
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
error: codex did not take the brief: the positional launch brief did not start a first turn within 4 s in window primary:fm-sm-live; inspect window primary:fm-sm-live
winner completed with exit=1; endpoint state=alive
{
  "mode": "gate-failed",
  "restart_exit": 3,
  "winner_exit": 1,
  "elapsed_seconds": 133.01,
  "liveness_lock_left": false
}
```

### Collision: probe-hang

```
unreached: sm-live: the old agent was stopped, but no replacement launch was confirmed successful within 3s (endpoint reads 'unreadable'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
summary: 0 of 1 restarted, 0 nudged, 1 unreached
competing launch holds spawn lock
restart lost spawn lock; stopped endpoint state=dead
private tmux server 2129129 stopped to stall the real endpoint probe
private tmux server resumed
{
  "mode": "probe-hang",
  "restart_exit": 3,
  "winner_exit": 0,
  "elapsed_seconds": 15.72,
  "frozen_seconds": 3.45,
  "liveness_lock_left": false
}
```

### Stale restarter lock

```
dead owner lock left at ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home/state/.secondmate-liveness-sm-live.lock
next recovery acquired stale lock
probe=relaunchable state=dead
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/home
spawned sm-live harness=codex kind=secondmate mode=secondmate yolo=off window=primary:fm-sm-live worktree=~/.no-mistakes/worktrees/049a88734b0e/01M6ARDD44DB5QEFFM79A1RJS3/.live-validation/secondmate
after recovery probe=alive state=alive
relaunch ledger:
1793510911	attempt
1793510953	relaunched
```

## Remote validation boundary

The named Herdr lab prepare command succeeded. A real invocation of the remote control route interface against an isolated fm-lab-* record refused it:
```
error: remote secondmate sm-live endpoint is recorded in Herdr session 'fm-lab-restart-validati-3032894-23931', expected 'fm-remote'; refusing access until it is explicitly migrated
```

The host-local remote command requires `fm-remote`, while this run authorizes lifecycle only in named `fm-lab-*` sessions. A workspace-local SSH server would not remove that session validation. No remote lifecycle was attempted outside the lab contract, and no production service or source was changed to bypass it. A supported lab-session override, or an explicitly authorized separate disposable host whose `fm-remote` session is isolated, is needed to run that placement live. Targeted fake-transport remote collision, gate-failure, hanging/late probes, oversized polls, and zero-budget cases passed; these are supplemental non-live evidence.

## Targeted checks

`TMPDIR="$PWD/.live-validation/tmp" bash .live-validation/product/tests/fm-secondmate-restart.test.sh` exited 0; retained `restart-tests-final.log`.

`TMPDIR="$PWD/.live-validation/tmp" bash .live-validation/product/tests/fm-secondmate-liveness.test.sh` exited 0; retained `liveness-tests-final.log`.

No complete suite, linter, formatter, push, PR, or CI phase was run. No project source edits were made. This changes CLI lifecycle logic; terminal transcripts and persisted state are the product evidence. No visual layout or copy placement changed.
