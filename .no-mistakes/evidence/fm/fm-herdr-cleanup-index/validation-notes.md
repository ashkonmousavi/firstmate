# Cleanup validation

The executable cleanup command was driven against Herdr 0.9.5 / protocol 22 in named non-default labs, using the repository helper for every CLI transport and lifecycle call. The helper verified the default-session tripwire at teardown. The 59-workspace / 83-journal workload was disposable and home-local. The base executable exceeded its 100-second diagnostic comparison limit; its process group was killed and awaited. Every target invocation completed normally, below 30 seconds.

The independent safety oracle is docs/herdr-backend.md, Startup cleanup of restored projections. Saved API snapshots demonstrate exact topology, labels, endpoint relationships and focus. Foreground/background sleep fixtures were independently confirmed through real Herdr process-info and their disposable shell child processes. A transport intervention published an actual duplicate journal after discovery at the real locked snapshot boundary; it returned the real API response unchanged, and immediate revalidation preserved the pane and both journals.

Reproduce the scale and safety checks from a run worktree with `mkdir -p .test-tmp` then `python3 <evidence>/live-cleanup-driver.py`. The driver writes only disposable worktree fixtures and evidence in this run directory, and tears down its named lab. Journal snapshot checks and tests/fm-herdr-session-cleanup.test.sh are supplemental focused tests, not live Herdr evidence.

The measured runtime is this gate host, not the laptop. The driver invokes cleanup directly with an isolated home lock marker; it does not prove a real harness acquired its session lock or that the laptop delivered its complete startup digest. That remaining hardware/startup check needs the same lab contract executed in a disposable laptop worktree with its existing harness login.

Primary-source research consulted: [Herdr CLI reference](https://herdr.dev/tui/docs/cli-reference/) and [Herdr agent skill](https://github.com/herdrdev/herdr/blob/master/skills/herdr/SKILL.md). They document explicit endpoint IDs, named sessions, background workspace creation and process-info. No independent dependency bug was implicated in this change.
