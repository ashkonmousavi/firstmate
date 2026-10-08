# Review fix inventory at 3e13a34a

This inventory was retained before this round's source edits.
The prior round's exact retained artifact was not supplied or located by the bounded worktree inventory.
That earlier evidence gap remains unverified; this file records only the current round.

## Remote claim expiry

Invariant: eligible claim mtimes through the last nanosecond of the cutoff second expire on both supported platforms, while later timestamps survive.
Cause: GNU-only touch -d clears the readiness stamp on BSD touch, leaving claims and the hourly marker unchanged despite returning success.
Occurrences: bin/fm-remote-job-lib.sh fm_remote_job_reap_stale reference creation and its marker publication; tests/fm-remote-job-claim-retention.test.sh touch_frac fixture creation.
Consumers: remote worker serving sweeps and the claim-retention and serving-latency regressions.
Search scope: bin/fm-remote*.sh and tests/fm-remote* for touch -d, date conversion, and os.utime; tests/lib.sh fm_touch_epoch.
Negative evidence: fm_touch_epoch already uses portable whole-second touch -t; no other remote fractional touch -d occurrence was found.
Fix: use Python os.utime with integer nanoseconds at both fractional timestamp sites, preserving the single directory walk.
Python3 is already used by the remote entrypoint and claim-serving fixture; no package installation is authorized or performed.
Regression: execute retention with a touch wrapper rejecting -d, testing both sides of the cutoff and the final nanosecond, marker publication and throttling.

## Live guard admission

Invariant: after tool admission, every installed harness and the shared unknown control require available inputs; missing required inputs must fail.
Cause: one branch maps missing pane inputs to a successful default-mode capability skip.
Occurrences: tests/fm-composer-dialog-live-e2e.test.sh installed-harness input loop, unknown input check, and combined zero-installed/missing branch.
Consumers: default, forced, explicitly disabled, and absent-harness executions through fm_live_gate and the live-harness-optin runner family.
Search scope: complete dialog guard and tests/lib.sh fm_live_gate, plus tests/fm-live-gate.test.sh executable guard regressions.
Negative evidence: the shared gate already handles explicit disable and absent required tools; no additional dialog-input skip exists outside this guard.
Fix: preserve zero-installed capability handling separately and remove missing-input success handling.
Regression: execute the real guard under isolated tool capabilities; missing inputs fail by default and when forced, disable exits cleanly, absent harnesses capability-skip by default and fail when forced.

## Dialog incarnation suppression

Invariant: the same named dialog is suppressed only within the same task spawn generation, and a replacement on the same pane must wake even without an intervening clear screen.
Cause: .dialog-surfaced stores only the dialog name across replacement.
Occurrences: bin/fm-watch.sh secondmate_dialog_check marker comparison and write, and its secondmate dispatch before ordinary stale exemption.
Lifecycle producers: fm-control relaunch and fm-secondmate-liveness relaunch both call fm-spawn; fm-spawn publishes a fresh spawn_gen on fresh and replacement launches.
Representations: Claude picker and Codex settings dialog; tmux, Herdr and other local backend captures share this reader.
Search scope: spawn_gen and dialog-surfaced in watcher, control, spawn, secondmate-liveness, backend, classifier and composer sources, with the watcher triage test.
Negative evidence: there is one dialog suppression owner; no manual/automatic relaunch path needs an independent reset once that owner includes spawn_gen.
Fix: compare and persist task plus spawn_gen plus dialog name at the shared reader, leaving the wake payload unchanged.
Regression: run the executable watcher for both dialogs, assert initial wake, same-generation suppression, replacement wake with unchanged screen, and new-generation suppression; retain idle control coverage.

## Verification

Pending one focused round after all source fixes and post-edit retrace.
The exact command output will be retained in verification.log beside this inventory.

## Post-edit retrace

The reaper creates its nanosecond reference before marker publication, keeps the existing batched directory sweep, removes its temporary reference, and still reaches staging cleanup.
The old GNU-only conversion state and date branches are removed.
The retention regression supplies fractional timestamps independently, rejects GNU touch -d, checks the last cutoff nanosecond and next-second timestamps, and verifies marker throttling.
The live guard preserves its initial shared fm_live_gate controls, separates zero-installed capability handling from required-input failure, and reaches the unchanged read-only captures only with complete inputs.
The watcher reads task and spawn_gen before pane capture, compares the same identity it later persists after durable wake append, and leaves wake text and daemon routing unchanged.
Both manual and automatic replacement callers continue to publish a new spawn_gen through fm-spawn, so a same-pane successor differs even if no clear screen was observed.
Idle screens still clear the marker and failed captures still preserve it.
No runtime alias, fallback, helper or parameter became unreachable.
The ordinary source paths were traced before the focused verification round.
Native macOS execution and real dialog-pane recognition remain outside this local proof.

## Focused verification receipts

Command: bash scratchpad-review-3e13a34a/verify.sh, with combined output retained in verification.log.
Exit status: 0.
The original reaper failed the retention regression with expired claim 1 still present when touch rejected -d.
The original default-on live guard succeeded with a capability skip despite two installed harnesses and missing inputs.
The original watcher timed out waiting for a same-pane replacement dialog wake.
The fixed retention regression passed numeric eligibility, nanosecond cutoff, next-second preservation, marker publication and hourly throttling.
The existing approximately 17460-claim serving regression passed its serving bound.
The live-guard admission regression passed default and forced missing-input failures, isolated missing unknown input, explicit disable, and absent-harness behavior.
The executable watcher regression passed initial wake, same-generation suppression, replacement wake without a clear screen, and replacement repeat suppression for Codex and Claude.
Changed shell scripts parsed and git diff --check passed.
No native macOS run or real dialog-pane recognition is claimed by these receipts.
No original-round retained inventory was recovered or recreated.
