# Local Test resolution

The change is not ready: the real watcher exits 1 when its newly added per-home secondmate relaunch lock times out. The standalone concurrency-repro.py drives actual tmux panes, the production lock library, and bin/fm-watch.sh; it preserves both endpoints and attempt budgets, then fails because supervision has stopped. Run from this worktree with `python3 ~/.no-mistakes/evidence/01M5BWRW59W3MTA812H0ZFHQK2/concurrency-repro.py`. It cleans its private socket and temporary worktree files on exit.

## Live evidence

- forge-live.log: real local Forgejo 17.0.0 with tea 0.16.0; no-CI refusal, a failed context behind 50 green statuses, all-green exact-head merge and merged poll, empty-method refusal, and review of repository named pulls. Server stopped afterward.
- forge-brief.md: final generated Forgejo ship brief and the resolved executable worker contract.
- core-live.log: daily growth alert registration, gating, estimation, deduplication, unsafe symlink detection and disarming; real foreground checkpoint recovery and concurrent wake retention; plain-file lock refusal; dependency-preserving and idempotent receipt through real tasks-axi under conflicting backend config.
- herdr-live.log: real Herdr 0.9.5 in a named non-default session and isolated test HOME, using the helper for provisioning, transport, stop and teardown. Only the live-default socket was shared read-only for the helper tripwire. Stopped probes stayed stopped and returned immediately. No TUI was started.
- teardown-live.log: real Treehouse and private tmux panes; scout return removes nested repositories and retains ignored data; ship refusal preserves uncommitted bytes. Private tmux server stopped afterward.
- home-seed-live.log: unchanged copied product scripts seed real git clones whose names contain spaces and ` - `, preserve their exact forge/posture, and converge on reseed.
- secondmate-live.log: Claude and OMP busy-to-idle, including Claude Stop blocking, and Codex unarmed lifecycle passed. Initial Pi attempt failed with expired Anthropic refresh credentials; pi-live-recheck.log passes through existing OpenAI Codex authentication. Initial Grok attempt returned HTTP 402 (balance exhausted).
- opencode-live.log: OpenCode 1.19.3 materialized only in the disposable worktree, using the available opencode/beam-free model, passes the real busy-to-idle lifecycle.
- claude-ineligible-live.log: actual Claude tool round trips with hooks disabled, a custom synchronous blocking Stop hook, and an older guard all preserve settings and remain unarmed.
- cursor-kimi-live.log: Cursor tool lifecycle emits no parent turn-end. Kimi wiring-only setup cannot satisfy native readiness; kimi-isolated.log independently runs real Kimi and reports LLM not set. No login or credential mutation was attempted.

## Targeted test commands and setup corrections

The initial targeted-regressions.log runs twenty explicitly named scripts, not the repository suite. Setting TMPDIR inside the checkout made several secondmate fixture homes violate the intentional containment guard and made a generated brief exceed its byte bound because paths were unusually long. Those are test setup failures. Reruns use /tmp, the normal ephemeral toolchain fixture root:

- fm-brief.test.sh -> brief-recheck.log, exit 0.
- fm-pr-merge.test.sh -> initial 300-second bound expired; retry with timeout 900 -> pr-merge-recheck.log, exit 0.
- fm-busy-adapter-wiring.test.sh -> busy-wiring-recheck.log, exit 0.
- fm-secondmate-liveness.test.sh -> liveness-recheck.log, exit 0 (the isolated library test misses the watcher-level failure).
- fm-control-relaunch.test.sh -> control-relaunch-recheck.log, exit 0.
- fm-teardown.test.sh -> environment-rechecks.log, exit 0.
- fm-backlog-handoff.test.sh -> environment-rechecks.log, exit 0.
- fm-backlog-atomicity.test.sh completed its preceding cases then failed on under-checkout secondmate containment; its exact failing test_a_persistent_secondmate_is_never_a_backlog_item -> backlog-spawn-recheck.log, exit 0.
- fm-secondmate-safety.test.sh initially failed on under-checkout secondmate containment; selected rerun of that case, spaced-name seeding, and four new task-set lock guards -> safety-recheck.log, exit 0.
- fm-home-summary-refresh.test.sh initially reached the large-child case under the invalid nested layout. First /tmp rerun failed at the five-second initial watcher-readiness wait with empty stderr; an unchanged second /tmp rerun -> home-summary-recheck.log, exit 0. This startup check was intermittent in this run.

The remaining initial scripts passed: fm-project-mode, fm-review-diff, fm-pr-check-security, fm-startup-growth-check, fm-watch-checkpoint, fm-wake-checkpoint-publication, fm-watch-gate-nudge, fm-idle-lane-wake, fm-remote-backlog-handoff, fm-crew-state. fm-backend-herdr.test.sh also passed separately (herdr-targeted.log).

No linter, formatter, static-analysis phase, full suite, push, PR or CI phase was run. Product source was not changed. Temporary drivers, cloned repositories, labs, downloaded Forgejo/tea/OpenCode binaries, and generated test selections were removed from the worktree. Evidence remains here.
