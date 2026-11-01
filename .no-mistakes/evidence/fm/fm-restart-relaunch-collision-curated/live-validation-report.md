# Restart collision live validation

Target: b0513083c54c9b8868c79292eecb663124ce6424.

The accepted decisions require conservative failure after a lost spawn lock when existing parent records cannot prove the competing launch completed. An alive endpoint is insufficient.

All live operations used marked disposable homes, real authenticated Codex/Cursor CLIs, and one private 120-column by 40-row tmux server. Persistence acknowledgements were supplied by the tester through the real fm-secondmate-report.sh producer because the disposable home had no open work; these checks do not claim to test model-driven persistence. Canonical Codex launches encountered the real hook-review dialog and failed their readiness gate without changing hook consent. Isolated old Codex targets used per-invocation --no-daemon --disable hooks. Cursor Auto produced an actual Ready response after the default model reported an exhausted quota.

The focused tests/fm-secondmate-restart.test.sh suite passed. It pins PATH=fakebin, FM_FAKE_DIR and FM_BACKEND=tmux; its remote checks are supplemental deterministic evidence, not live remote validation. The first suite attempt placed fixture homes inside the source repository and was refused; rerunning in the evidence area corrected that setup. No source, test, configuration, or memory-file changes remain in the worktree.

## Normal restart and a working replacement

[live-success-restart.txt](live-success-restart.txt)

```text
restarted: sm1 (cursor)
summary: 1 of 1 restarted, 0 nudged, 0 unreached
```

[live-success-result.json](live-success-result.json)

```text
{
  "restart_exit": "0",
  "lock_released": true
}
```

## Independent launch succeeds but lacks an accepted parent completion record

[live-complete-winner.txt](live-complete-winner.txt)

```text
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.qkc2py8r
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
warning: secondmate sm1 sync skipped before launch: primary default-branch commit cannot be resolved
spawned sm1 harness=cursor kind=secondmate mode=secondmate yolo=off window=primary:fm-sm1 worktree=~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/sm.5k909e5n
```

[live-complete-restart.txt](live-complete-restart.txt)

```text
unreached: sm1: the old agent was stopped, but no replacement launch was confirmed successful within 8s (endpoint reads 'alive'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.qkc2py8r
summary: 0 of 1 restarted, 0 nudged, 1 unreached
```

[live-complete-results.json](live-complete-results.json)

```text
{
  "verification_elapsed_seconds": 6.53367018699646,
  "restart_exit": "3",
  "winner_exit": "0",
  "watcher_exit": "0",
  "verification_wait": 8,
  "verification_poll": 20,
  "lock_released": true,
  "attempt_ledger_absent": true
}
```

## Competing Codex launch pending then readiness fails

[live-failed-winner.txt](live-failed-winner.txt)

```text
fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.qkc2py8r
WARNING: watcher still down (same stale episode; last beat: never, grace 300s) - full banner already printed this episode.
warning: secondmate sm1 sync skipped before launch: primary default-branch commit cannot be resolved
error: codex did not take the brief: the positional launch brief did not start a first turn within 6 s in window primary:fm-sm1; inspect window primary:fm-sm1
```

[live-failed-restart.txt](live-failed-restart.txt)

```text
unreached: sm1: the old agent was stopped, but no replacement launch was confirmed successful within 8s (endpoint reads 'missing'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.qkc2py8r
summary: 0 of 1 restarted, 0 nudged, 1 unreached
```

[live-failed-results.json](live-failed-results.json)

```text
{
  "restart_exit": "3",
  "winner_exit": "1",
  "watcher_exit": "0",
  "verification_wait": 8,
  "verification_poll": 20,
  "lock_released": true,
  "attempt_ledger_absent": true
}
```

## Monitoring skips restart without spending a recovery attempt

[live-failed-watcher.txt](live-failed-watcher.txt)

```text
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=stopping
observed phase=launching
observed phase=launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
observed phase=failed:launching
watcher tick exit=0
attempt ledger absent
restart lock:
16009
```

## Actually hung runtime probe is bounded

[live-hung-probe-restart.txt](live-hung-probe-restart.txt)

```text
unreached: sm1: the old agent was stopped, but no replacement launch was confirmed successful within 3s (endpoint reads 'unreadable'); its own launch reported: fm-gate-refuse: gate agent lifecycle permitted only against lab home ~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.qkc2py8r
summary: 0 of 1 restarted, 0 nudged, 1 unreached
```

[live-hung-probe-result.json](live-hung-probe-result.json)

```text
{
  "restart_exit": "3",
  "verification_wait_seconds": 3,
  "elapsed_since_transport_suspended_seconds": 3.9108694779861253,
  "lock_released": true
}
```

## An abandoned marker is reclaimed

[live-stale-marker-recovery.txt](live-stale-marker-recovery.txt)

```text
watcher tick exit=0
probe=alive state=alive
abandoned lock reclaimed and released
attempt ledger absent
```

## An existing recovery owner prevents stopping the current agent

[live-busy-recovery-restart.txt](live-busy-recovery-restart.txt)

```text
unreached: sm1: another liveness recovery of this mate still held its lock after 1s (holder pid 274500), so nothing was stopped
summary: 0 of 1 restarted, 0 nudged, 1 unreached
```

[live-busy-recovery-result.json](live-busy-recovery-result.json)

```text
{
  "restart_exit": "3",
  "metadata_unchanged": true
}
```

## Live remote scenario unavailable under the lab-session contract

[remote-lab-boundary.txt](remote-lab-boundary.txt)

```text
~/.no-mistakes/evidence/01M6ABB3CG4YQMA6RX128VE4E6/fm-lab.remote-iinndkul
$ FM_HOME=<disposable lab> bin/fm-remote-secondmate-control.sh relaunch sm2 codex default default
error: remote secondmate sm2 endpoint is recorded in Herdr session 'fm-lab-remote-proof', expected 'fm-remote'; refusing access until it is explicitly migrated
exit=1
Removed disposable remote home. No Herdr server or endpoint was accessed.
```

## Cleanup

[cleanup.txt](cleanup.txt)

```text
Private lab tmux server: kill-server exited 0 (live-driver.log).
Removed both disposable homes after making their generated read-only hook directories removable.
No real fleet session was stopped.
```

The hung-probe measurement includes the existing parent result-reaping cadence; the configured probe budget was three seconds and the parent observed its nonzero result in 3.91 seconds. A separate collision used an eight-second verification budget with a twenty-second poll interval and returned within that bound.

Remote limitation: the real remote controller rejects a named fm-lab-* route before any endpoint access because it requires fm-remote. The trusted runbook permits live Herdr operations only in named fm-lab-* sessions. A disposable local SSH server would not remove that conflict. Driving the real remote lifecycle requires a supported lab-session selector, or explicit authority to use fm-remote on an isolated remote host; no fleet session was accessed.

Working replacement transcript: [live-auto-ready.txt](live-auto-ready.txt). The actual agent says Ready and confirms its charter.

Research setup references: the existing Firstmate research book timeout entry; [GNU timeout](https://www.gnu.org/software/coreutils/manual/html_node/timeout-invocation.html); [Codex hooks](https://developers.openai.com/codex/hooks); the installed codex --help documents --no-daemon.
