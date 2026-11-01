# Restart/relaunch collision validation

Target: 1566d645676871893015ffee868f96c356fe6b2d.

Oracle: the author requires liveness recovery to leave a deliberate restart alone and requires restart to wait for and verify the winning spawn instead of reporting unreached.
A plausible wrong implementation would kill or launch into the deliberately stopped endpoint, consume a recovery attempt while the lock is held, or accept an endpoint that never became alive.

`bash tests/fm-secondmate-restart.test.sh` completed with exit 0.
This suite uses a simulated session provider and SSH boundary; its local/remote winner, timeout, persist-ordering, and stale-owner results are supplemental and are not live evidence.

`live-watcher.py` ran the actual watcher liveness tick against a real Pi 1.0.0 process in a 120x40 private tmux session.
The fixture contained copied, unmodified target bin/ scripts, sibling disposable product/parent/mate directories inside the worktree, and a parent stamped by bin/fm-lab-home.sh.
The sibling layout satisfies the product refusal against secondmate homes inside its own source root.
All calls retained the gate check and used the marked-home allowance; no gate bypass was set.
The real fm-control exit stopped Pi; the real liveness probe read dead.
A live process held the per-mate lock through three actual watcher ticks: the endpoint identity, dead verdict, and attempt ledger remained unchanged.
A real process then acquired that lock and exited without unlocking.
The watcher reclaimed its abandoned lock, recorded one attempt and one relaunched outcome, and spawned the real Pi runtime.
The recovered runtime answered ACK to an actual fm-send delivery.
The lock was created by the driver, so this proves watcher lock behavior, not that fm-secondmate-restart holds the lock at every required stage.

`live-collision.py` attempted the complete restart race with a live spawn-lock holder and real Pi.
It could not pass the persist stage: fm-secondmate-restart supplies FM_STATE_OVERRIDE to its fm-send child even for a stock marked lab.
The gate allowance rejects all nonempty FM_*_OVERRIDE variables.
The real CLI returned unreached before touching the old agent.
A counterfactual check using the original bin/fm-send.sh succeeded with no override and was refused with exit 3 when only that override was added (lab-gate-boundary.txt).
Therefore the full restart/winner wait, verification timeout, actual restart lock lifetime, and remote route-refresh paths remain untested live.
The trusted runbook requires the gate context and marked-home allowance; bypassing that guard or moving execution outside the gate context was not used as a workaround.

Claude's normal login reached its TUI, but a fresh mate requires workspace trust registration in the user store, outside this run's intentional write boundary.
Pi's Anthropic provider returned invalid_grant / Refresh token expired.
The already authenticated openai-codex provider passed `pi auth check --provider openai-codex --no-refresh --json` and drove the successful live checks.
No sign-in, sign-out, re-login, or manual credential-store edit was performed.

Read-only primary-source research:
- tmux maintainer documentation describes pane respawn and remain-on-exit semantics: https://github.com/tmux/tmux/wiki/Advanced-Use/c0f4727fc35e6cdd301660ff6ef1161ebe890605
- Pi's upstream OAuth contract says refresh can throw invalid_grant: https://github.com/badlogic/pi-mono/blob/351efc82/packages/ai/src/auth/types.ts
- Upstream tests distinguish expired-token refresh failure from a valid-token read: https://github.com/badlogic/pi-mono/blob/351efc82/packages/ai/test/models-runtime.test.ts
The operator research book is not present inside this worktree; findings are retained here within the assigned evidence boundary.

Cleanup: fm-teardown sm1 returned exit 0; the private fm-lab server was killed and confirmed absent; the disposable workspace was removed.
No source or test files were changed.
This is a shell lifecycle change, so terminal transcripts are the relevant product artifacts; no visual layout changed.
