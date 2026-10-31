# Live validation of curated fleet update and worker recovery

Target: `d952ffed930214e0cf3b839e1ea7ac57e58dcc8b`; baseline: `4220467f622e1095bae46961814f305d27418b97`.

All live scenarios passed on Linux. No tracked source or test changes were needed.

The live driver uses actual `fm-update.sh`, `fm-on.sh`, OpenSSH, the remote-job queue/worker library and executable, and `fm-remote-secondmate-control.sh`. Its origin, primary, detached clones, remote code root, persistent homes and account directories are disposable repositories under the gate worktree. A private loopback SSH server supplies the external transport. Its command adapter decodes fm-on's argv and drives the actual queue API with a synthetic account home, rather than running the installed remote entrypoint, which resolves the operating system account home. It does not synthesize update/sync results. For legacy rejection, it executes the actual control script from the baseline commit. For timeouts, it deliberately holds a real SSH request open. No production SSH account, credentials, fleet pane, harness login or default Herdr session is used.

Independent oracles are the recorded owner decisions: only curated/default commits may be selected; all successful homes share one resolved commit; failure to resolve that commit updates no homes; a legacy rejection causes one pinned request and no fallback; unsafe local work survives; an unserviced queue cannot remain healthy solely because its heartbeat runs. Expected hashes come from independently constructed Git branches, not the selector under test.

| Scenario | Product evidence |
| --- | --- |
| Curated primary, detached clones and remote root/home select curated even when main advances separately | `live-product.log`, `live-results.json`: Git HEADs and absence of main-only content; dirty and uniquely diverged homes preserved |
| A separate remote persistent home receives the parent's pinned target through its configured code root | `live-product.log`: real queued remote control result and matching root/home HEADs |
| A published feature/wip upstream does not confer fleet authority | `live-product.log`: primary sync selects the local default ref; updater chooses origin/main, skips the feature primary and preserves its commit |
| Shared target cannot resolve | `live-product.log`: a real absent origin fails; primary, local, remote root and remote home HEADs remain unchanged; focused suite additionally injects a transient first-fetch failure and covers missing origin/branch/ref |
| Legacy host rejects the pin | `live-product.log`: baseline control parser returns status 2, one SSH update request, manual-update diagnostic and unchanged HEAD |
| Remote update request hangs | `live-product.log`: 4-second bound, named skipped host, next remote route completes; whole pass 6.36 seconds |
| Remote returns a different commit | `mismatch-live.log`: fault injection changes the dispatched target; actual remote updater moves its root and home to main, and parent rejects their real mismatching result without restart/nudge |
| Origin moves after parent resolution | `supplement-live.log`: remote dispatch pushes a newer curated commit, then real root/home updater fetches it but retains the earlier parent pin |
| Remote state read hangs | `supplement-live.log`: 3-second bound, named state timeout, neither restart nor nudge selected; whole pass 5.40 seconds |
| Serving loop wedges while heartbeat remains alive | `live-product.log`: SIGSTOP applied only to serving PID; staged remote sync remains queued until readiness expires; verified owner is replaced and real queued sync completes |
| Healthy worker handles concurrent requests | `live-product.log`: two real queued sync requests finish and the serving PID is unchanged |
| Serving loop resumes before replacement | `resumed-worker.log`: stale readiness becomes fresh after SIGCONT; ensure retains the same verified PID and worker logs readiness resuming |

The original blocked-SIGCHLD state was not induced. SIGSTOP models its observable failure condition: the serving process makes no progress while its independent heartbeat continues. The baseline counterfactual in `before-fix.log` reproduces both the wrong-target split and the misleading ready worker with queued work, using actual baseline scripts.

Targeted behavioral suites, each awaited to exit 0: `bash tests/fm-update.test.sh`, `bash tests/fm-secondmate-sync.test.sh`, and `bash tests/fm-remote-job.test.sh`, with `TMPDIR="$PWD/.live-validation/tmp"`. These are supporting regression evidence; mock SSH/backend cases in those suites are not claimed as live fleet validation. No full suite, lint, formatter, static analysis, delivery or CI phase was run. The surface is CLI-only, so transcripts and Git/queue state are the reviewer-visible artifacts.

## Updated affected-class inventory

The supplied worktree handoff is retained as `class-inventory-handoff.md`; the following rows update its validation claims for this phase.

| Class and changed owner | Evidence and current coverage |
| --- | --- |
| Branch selection: fm-ff-lib.sh | Live curated/default/feature-upstream checks; focused sync/update suites also exercise bootstrap/spawn hooks and detached linked worktrees. Only real Git fixture state is authoritative. |
| Shared target resolution: fm-update.sh | Live absent-origin failure leaves every listed HEAD unchanged; focused suite also covers transient first-fetch failure and missing branch/ref, with no later retry/contact. |
| Remote timeout and handoff: fm-update.sh | Live OpenSSH update and state timeouts, next-host continuation, real legacy parser rejection, and origin-advance race. Live post-mutation mismatch rejection also exercised by deliberately changing the remote-dispatched target and letting the actual remote updater return its resulting commit. |
| Host propagation: fm-remote-secondmate-control.sh | Actual worker executes pinned update on a distinct code root and persistent clone; both HEADs equal parent target, even when origin advances mid-pass. |
| Serving progress: fm-remote-job-worker.sh | Live stopped main/live heartbeat, readiness withholding, resumed readiness, concurrent healthy jobs; actual baseline keeps appearing ready with a queued job. |
| Replacement: fm-remote-job-lib.sh | Live verified-owner replacement and queue drain; focused worker suite also passes identity, quarantine, lost-owner, stale-lock, shutdown, healthy active-job and restart-limit cases. |
| Platforms | Native Linux exercised. Native macOS/Aqua, launchctl and actual suspend/resume not exercised. This phase proves tick/progress behavior via real Linux workers; it makes no native macOS claim. |
| Backends and harnesses | Update/queue mechanisms exercised independently of UI backend or model. Existing focused suites use simulated tmux/Herdr boundaries for action classification and bootstrap/spawn. No backend adapter, harness CLI, login, or pane lifecycle is claimed live. No changed path requires model interpretation. |
| Accounts and lifecycle | Disposable synthetic account homes and ephemeral SSH keys only. Updated/current, dirty/divergent, rejected pin, unresolved target, update/state timeout, serving stall, recovery, concurrent service and teardown all exercised. Actual installed SSH entrypoint/account discovery and production steer/restart were deliberately outside this isolated scenario. |

## Replay and cleanup

Evidence includes `live-driver.py`, `supplement-driver.py`, `queue-call.sh`, `resume-worker.sh`, `baseline.sh`, and `mismatch-driver.py`. From a fresh copy of this worktree, create `.live-validation/tmp` and a Python venv in `.live-validation/venv`, install Paramiko into that venv, copy the drivers into `.live-validation/` (resume-worker.sh becomes resume.sh), then execute live.py, resume.sh, supplement.py, baseline.sh and mismatch.py sequentially (mismatch-driver.py becomes mismatch.py). Drivers expect their original filenames (`live.py`, `supplement.py`, `queue-call.sh`). The Python drivers write logs to this run's named evidence directory. All fixtures must remain inside the worktree. Stop fixture workers as the drivers' cleanup paths do before removing `.live-validation`.

Each required process's exit status was collected. SSH servers, request children, resumed/stopped workers and test children were stopped; `cleanup-check.json` records the final owned-process check. Transient drivers, venv and repositories were removed from the worktree; retained evidence remains in this evidence directory.
