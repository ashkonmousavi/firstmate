# Integration live validation

Target: 14728501663ff66cf7ab510227db54ccb7ae854c. No publication, PR, CI, merge, or pipeline-control command was run.

## Observed Codex launch flake

Installed CLI: codex-cli 0.166.0. Run the existing `tests/fm-codex-brief-typed-live-e2e.test.sh` with `FM_CODEX_LIVE_E2E=1 FM_CODEX_TYPED_LAUNCH=1`, workspace-local TMPDIR and TREEHOUSE_ROOT, and a private tmux server. The guard itself sets a 200x50 grid and cleans up its sessions.

Two stock runs failed: `codex-typed-live.log` reports unconfirmed submission (unknown) after 18 seconds; `codex-typed-retry.log` reports unconfirmed submission (pending) after 7 seconds. The captured live terminal during those attempts displayed the launch envelope and “Waiting for startup”. The readiness gate accepted the composer before startup finished; its short submit confirmation then refused the launch.

Hypothesis: startup latency exposes a readiness/submission race. It would be disproven if the same CLI could not deliver the same task even after startup had time to finish. Control: adding `FM_CODEX_SUBMIT_SETTLE=60` passed both new-folder and trusted-folder launches (`codex-typed-startup-delay.log`). A later stock run also passed both (`codex-typed-default-final.log`), establishing intermittent behavior rather than a universal refusal. Default positional delivery passed both cases (`codex-positional-live.log`). No account, credential, or global configuration was edited by the test driver.

Official upstream research: https://github.com/openai/codex/issues/55000 describes one separate cause of “Waiting for startup”; this run did not reproduce its deleted-cwd premise, and successful positional/delayed controls mean it is not established as this run's cause. Do not infer a credential fault from that issue.

## Rex

The binary was absent on PATH. Downloaded the official Linux preview archive into the worktree, without running its installer. Source: https://www.superlogical.com/rex/docs/linux/installation and https://blob.superlogical.com/api/releases/rex/preview . Archive: https://blob.superlogical.com/download/rex/preview/e6592f74969959db77f1f84261901ef599a025cf/rex-linux-amd64.tar.gz . SHA-256 verified: 01044e9e21c0e664d47dd5c52ff715f79ae767859eaaa351c5b273ad5e11e82f. Version: 0.1.0-preview.12, API revision 8.

The workspace absolute path exceeds Linux's Unix-socket length limit. The live runner opened the workspace's `.no-mistakes` directory and used `unix:///proc/<runner-pid>/fd/<directory-fd>/rex-live.sock`, so the socket still resides inside the workspace. It changed only the disposable copy of `tests/rex-test-safety.sh` to accept that endpoint. Every server had isolated state and an empty configuration, and was stopped afterward.

The metadata-aware gone proof was exercised against live native blocks: present rejected; killed with matching recorded server accepted; target-only, missing recorded server, and wrong recorded server rejected. The actual fm-spawn/Codex carrier scenario ran with FM_CODEX_TYPED_LAUNCH=1 on Rex, answered the scratch folder's trust dialog, observed `rex-carrier-ok`, killed the task, and proved that task's recorded endpoint absent. See `rex-recorded-server-live.txt`, `rex-codex-carrier-clean-live.log`, and `rex-codex-pane.txt`.

The existing smoke guard's restart assertion failed because preview.12 preserves the block in the same state directory. A separate live check confirmed this directly: native block `size` still succeeds after restart, the adapter reads `dead`, and the metadata-aware proof correctly refuses absence; after explicit native deletion, it accepts absence. See `rex-restart-retention-live.txt`. Thus the adapter is safe, but the smoke test's assumption that restart loses the session is stale.

The first custom carrier run proved delivery but its cleanup hit read-only generated Git hooks. The runner was corrected to stop its server, return the worktree before removing its project, and make its own hook directories writable. `rex-codex-carrier-clean-live.log` is the completed, exit-0 re-drive.

## Targeted deterministic checks and isolation

The Codex-harness and worker-account suites passed from an unchanged `git archive HEAD` source copy under `.no-mistakes/runtime`, with their fixture homes as siblings. Initial attempts placed secondmate homes below the code root and were correctly refused. This copy resolves that setup problem while staying in the worktree. These mocked-boundary suites are supporting evidence, not live harness proofs.

The remote secondmate lifecycle suite's initial attempts encountered the gate backstop in nested fixture directories. The final run used a standalone fixture repository in the temporary root; its SSH and backends remain deterministic boundary fixtures, not live SSH/Rex/Herdr proof.

## T3 live limitation

A real fm-spawn attempt with an isolated lab home and deferred Codex account configuration stopped at the earlier MCP capability boundary: no `config/t3code-token` credential. There is no `t3` executable on PATH. No operator token or runtime configuration was read. `docs/t3code-backend.md` requires a full-access OAuth mcp-client sign-in, reserved to the captain; this test phase explicitly forbids signing in or changing production credentials. To drive the scenario live, provide a disposable capable T3 server and its authorized OAuth token in the lab's config. The worker-account suite did exercise all three roles with omitted/default models through a boundary fixture.

## Other live evidence

The watcher test ran the production watcher against a real isolated tmux workload, observed repeated default escalations, the configured terminal cap, and new wakes after its 300-second expiry. Its full end-user wake transcript is `watcher-wedge-live.log`. The already declined readiness concern in that guard was left unchanged; this result is not a new assertion about its readiness implementation.

Merge topology was checked read-only: both curated base and Kun's head are ancestors, and the integration commit has those two parents. See `integration-history.txt`. No merge or publication was attempted.

## Pre-merge control

The same installed Codex and stock typed-launch guard also passed both new-folder and trusted-folder cases from an unchanged archive of base commit 1b243d56 (`codex-typed-base-control.log`, 20s and 18s). This is additional context, not proof that the intermittent target failure was introduced by the merge: the target's readiness/submission code already existed at base, while shared composer/backend code changed. No narrower causal attribution is established by this test phase.

## Final remote fixture result

The final remote lifecycle suite exited 0 and printed ALL TESTS PASSED, including the requested Rex liveness recovery regression and subsequent retirement/archive boundaries. See `remote-secondmate-nested-repo.log`.

## Cleanup

All started check processes returned their actual exit codes. The disposable source copies, fixture directories, downloaded Rex binary/archive, Treehouse pool, and replay working files were removed. No owned test process remained in the process-table check. `git status --short` is clean; the pre-existing empty `state/` and pre-existing `bin/__pycache__/` were retained. No browser or server child remains from this validation.
