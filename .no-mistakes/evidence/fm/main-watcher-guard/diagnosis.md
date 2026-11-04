# Live validation diagnosis and repeatable proof

Validated 2026-11-04 UTC with the existing Claude Code 2.1.318 login. No account, live fleet home, endpoint or global configuration was changed.

Research-book lookup: `data/research-book` is absent in this gate snapshot. Other project checkouts were outside the permitted read scope, so no entry was available here. Primary source consulted on 2026-11-04: [Claude Code hooks reference](https://code.claude.com/docs/en/hooks). It specifies independent async hook processes, print-session teardown cancellation, PreToolUse exit-2 refusal and asyncRewake exit-2 feedback. These are transport expectations; the retained live transcripts are the behavioral evidence.

## Stop fixture diagnosis

Expected from the existing independent assertions: two foreground arm calls, three drains including SessionStart, two distinct Stop feedback reasons, no model-issued arm, preserved competing owner.

Observed before repair: six total arm calls. Diagnostic repetition identified eleven guard calls (`handling-successor=1`) consuming the rapid-event fixture counter. Hypothesis: independent during-turn guard and immediate-return replacement arm cannot share this fixture. Disproof: failure persists as a Stop-only failure after removing the guard. The Stop-only run did fail with four calls and only one feedback turn.

Independent source/evidence review identified a second fixture defect: Stop handling successors carry `FM_WATCH_PREDECESSOR_ARM_PID`; they were counted as the next foreground rapid event. The base d62d3d174e8fd750a72381834f18a8e0ed2f7619 reproduced the same four-call failure (live-stop-baseline.log), establishing that component predates this change.

Repair: keep this existing regression explicitly about the unguarded Stop path; keep all SessionStart/Stop hook registrations and outcome assertions; acknowledge handling successors separately before consuming foreground events, following the existing portable Stop fixture. Retain optional transcript/caller diagnostics. No product code changed. live-stop-final.log and live-stop-refresh.log both pass; stop-final/ contains two foreground calls and two separate successors, the transcript and three drains. This test remains the guard against recurrence of the fixture mistake.

## Real product proof

`drive-real-guard.py` is a retained disposable verification driver; run it from the gate worktree with `python3 <path-to-driver>`. It creates a marked lab home under `.test-tmp`, copies the actual bin scripts, uses a plain isolated git root and the tracked guard hooks, and runs real Claude print mode with the existing login. The production arm, watcher, check registration, spawn and send scripts are not replaced. The only custom program is a registered watcher check that logs execution time. It creates no real worker or endpoint.

It records actual beat ages and check progress during a tool, stops only its lab guard/watcher to induce stale and missing beats, exercises real entrypoint refusal including GNU env -S, checks read/lookup access and worker/secondmate/unmarked exclusions, and uses the emitted recovery-aware restart. A fresh-beat send then reaches ordinary absent-target validation, proving admission resumed without inventing a delivered worker message. It also runs plain and hosted Stop against real healthy handling successors with queued unacknowledged wakes and proves both attach to the same live PID without losing the queue.

The accelerated 20-minute regression is complementary, not 20 wall-clock minutes of live Claude. targeted-tests.log records guarded maximum age 31.622 simulated seconds versus unguarded age 1201.383 simulated seconds.

The initial manual driver used the wrong watcher lock filename and was corrected from observed persisted state; its failed setup transcript is retained. An expanded check initially stopped the hosted Stop parent before its foreground child, delaying shell signal handling; teardown-assisted evidence retains that successful product proof and the separate lab-only stop command. The final driver stops the owned watcher before awaiting Stop, matching the repository fixture teardown order. The final repeat is the independently runnable proof.
