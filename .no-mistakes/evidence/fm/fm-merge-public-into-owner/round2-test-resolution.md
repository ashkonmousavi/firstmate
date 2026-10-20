# Local Test round 2

Target: 3920544e4e30c9fd605c9a7ab7de30cbb2b81dc8.
The prior watcher failure is resolved.
No source or test files were changed during this validation turn.

## Fresh execution

- `python3 concurrency-repro.py` (the retained driver in this evidence directory): the real watcher survived repeated per-home relaunch lock timeouts for both secondmates on a private 120x40 tmux session; both endpoints survived, and neither attempt budget was consumed. See round2-concurrency-live.log.
- `python3 round2-checkpoint-repro.py`: the real bounded checkpoint requested a foreground recovery; `--recover` deferred both mates safely; the next checkpoint returned the same still-actionable request without duplicate durable rows. See round2-checkpoint-live.log.
- `timeout 240 bash tests/fm-secondmate-liveness.test.sh`: exit 0, including the new actual-watcher contention regression and existing safety/remote-probe checks. See round2-liveness.log.
- `timeout 180 bash tests/fm-home-summary-refresh.test.sh`: exit 0, covering startup readiness, watcher-driven publication, cadence, atomic replacement, bounded failures, large ledgers, and restart behavior. See round2-home-summary.log.

The first additional checkpoint experiment expected a quiet exit, but the executable interface deliberately requests recovery before any bounded-cycle relaunch.
The final driver follows that documented interface and verifies recovery plus retention of its request; this was a driver expectation correction, not a product failure.
All temporary lab homes and private terminal servers were cleaned up; final git status was clean.

## Retained evidence from the preceding round of this same run

The broader integration was already exercised before this focused fix.
The records and setup corrections remain in test-resolution.md, core-live.log, forge-live.log, forge-brief.md, herdr-live.log, teardown-live.log, home-seed-live.log, secondmate-live.log, pi-live-recheck.log, opencode-live.log, claude-ineligible-live.log and cursor-kimi-live.log.
Those records are earlier-round executions, not new executions in round 2.
The new target changes the contended recovery verdict and test readiness; it does not change the previously proven forge, cleanup, activity-hook, backlog, home-seeding or Herdr behavior.

Grok remains untested beyond its real HTTP 402 exhausted-balance response; Kimi remains untested beyond its real unconfigured-LLM response; Pi-signed's separate launcher is absent, although the shared Pi extension was exercised through Pi.
No sign-in, credential-store mutation, pipeline control, push, PR, CI, linter, formatter or full-suite run was performed here.
No rendered interface was changed; CLI transcripts are the product evidence.
