# Retained inventory: accepted R1–R3 account-failover fixes

Run: 01M5EQCF52XET4T3A5JE77RBZK. Reviewed target: 29effc4689c0dbe5fa0ff3d29e4e51cba4ff01fd. Pre-fix comparison: 22fbe491 (the merged account-failover implementation immediately before the accepted fixes). This report and adjacent logs are retained test evidence for subsequent Review turns. No behavior or permanent test was changed in this phase.

## R1: selected Codex root must own setup and execution

Cause reproduced: run the target's existing `test_explicit_account_roots` against an archived pre-fix tree, using its own real spawn script and the established fake session/CLI boundaries. The synthetic pane failed opening codex-2/hooks.json: setup installed into the ambient root, while the launched worker selected codex-2. See `r1-before.log`. This is regression evidence, not a live Codex lifecycle proof.

Affected occurrences, all checked at target:

- bin/fm-spawn.sh:2809 selects the account; :2821 exports its CODEX_HOME before startup setup.
- bin/fm-spawn.sh:5216 invokes fm-codex-busy.sh install using that exported root; :5989 supplies that root while shedding credential overrides; :6052 exports the same CODEX_HOME to the launched hook environment.
- bin/fm-spawn.sh:2206 restores an explicit same-harness root on direct relaunch; bin/fm-control.sh:1057 validates and :1247 forwards the replacement root into spawn.

Search scope: tracked bin/ callers of `fm_worker_account_select`, CODEX_HOME uses in fm-spawn, Codex hook installation, and account transaction/launch tests. Exact searches: `rg -n 'fm_worker_account_(select|quota|next|recover)' bin tests/fm-worker-account.test.sh` and `rg -n 'hooks|CODEX_HOME' bin/fm-spawn.sh`.

Negative evidence: no second account-selection owner exists among those bin/ callers. Claude already assigns its selected config root at the same early setup boundary. The target regression drives UserPromptSubmit and Stop through the selected root's installed hooks, asserts persisted idle state, and asserts the ambient hooks file was not created. Unselected and other-runner launches retain their original branch. No credential store from the operator was consulted or changed.

Regression result: target's explicit-root cases passed in focused-tests.log, while the identical selected test failed before the fix. Real installed Codex login-status accepted the disposable stored-key fixture and rejected an empty root even with ambient credentials (`live-account-guards.log`, and existing live E2E log). This does not prove the installed Codex TUI emits these hooks during a real task.

## R2: applicable model aliases must constrain quota decisions

Cause reproduced: the independent documented example from docs/verification/dispatch-auth.md states that `model:codex_bengalfox` bounds gpt-5.3-codex-spark and nothing else. Feed 50% all_models and 0% Bengalfox into the shared classifier. Pre-fix returned healthy; target returns exhausted. Both return healthy for gpt-5.5. See `r2-r3-before-after.log`.

Affected occurrences: bin/fm-worker-account-lib.sh:372 shared scope matching, :398 replacement eligibility, :433 current-account exhaustion, and bin/fm-control.sh:1046 transaction revalidation. The single classifier fix reaches all three consumers.

Search scope: all `fm_worker_account_quota`/`next`/`recover` references in bin/, the shared classifier's scope branches, docs/verification/dispatch-auth.md and existing account recovery tests. Negative evidence: no duplicate scope classifier was introduced in those consumers. Other models still observe the all-model bound without inheriting Spark's additional bound. Unknown/auth-error evidence does not become exhaustion; replacement selection skips a Spark-exhausted candidate and chooses the later usable account in the targeted regression.

Regression result: reproduced healthy-before/exhausted-after with unchanged unrelated-model output. The target existing tests additionally passed ordered replacement skipping, strict reread after renewal, and unknown auth refusal. These use quota fixtures and are not live vendor exhaustion evidence.

## R3: foreground checkpoint must defer recovery and bound quota reads

Cause reproduced independently of R2: an all-model-exhausted account with a 30-second checkpoint deadline invokes a recording control boundary. Pre-fix returns success and launches relaunch inline without queueing. Target returns 124, queues `checkpoint-recovery-relaunch-t`, and invokes no relaunch. A provider taking three seconds with a one-second remaining checkpoint returns healthy after three seconds before the fix; target returns unknown under the timed-read bound. See `r2-r3-before-after.log` (timing is integer/wall-clock quantized).

Affected occurrences: bin/fm-worker-account-lib.sh:349 first strict read, :362 delegated renewal, :365 strict reread all obtain remaining checkpoint budgets. :433 exhaustion check reaches those bounded probes; :435 clears the cadence stamp before :437 fm_checkpoint_admit queues relaunch. bin/fm-watch.sh:4053 invokes recovery, then :4057–4058 surfaces the deferred reason and checks the deadline before more triage. bin/fm-control.sh:1046 and replacement checks share the bounded classifier.

Search scope: all account quota/recovery references in bin/, fm-checkpoint-budget/admit definitions in bin/fm-timeout-lib.sh, existing watcher checkpoint handoff precedent, and the account regression tests. Negative evidence: none of the three quota subprocess call sites retains a fixed unbounded checkpoint read. Outside a foreground checkpoint, admission returns normally and recovery proceeds through the existing control transaction. The target regression proves a deferred observation does not leave a cadence stamp suppressing the next recovery; duplicate ordinary polls remain throttled.

Regression result: pre-fix inline launch/no queue versus target deferred/no launch/queued recovery; slow quota read returns unknown at target. Both are executable behavior probes with external-boundary fixtures, not a live exhausted-account watcher walk.

## Reproduction and interpretation

`class-regressions.sh` contains the exact R2/R3 behavior probe. Prepare its comparison tree from this run's source with `mkdir -p .test-tmp/before` and `git archive 22fbe491 | tar -x -C .test-tmp/before`; invoke from the run root. For R1, take target tests/fm-worker-account.test.sh, retain its function definitions and source imports, replace the final bare test invocation block with `test_explicit_account_roots`, and execute that temporary test under the archived tree's tests/ directory. No assertions inspect implementation strings: the probes execute account selection, spawn, hook commands, quota classification, timers and recovery, and assert their output/state.

Initial focused run explicitly relocated TMPDIR inside the repository. Its unrelated local-secondmate test correctly refused a secondmate home inside the repository. This is a setup error in this test phase, not a regression. The ordinary temporary-directory reruns are retained separately in account-tests-retry.log and relaunch-tests-retry.log. The account suite passed after correcting the setup. Incidental test-toolchain temporary files are permitted by the workspace contract.

Live boundary: installed Claude 2.1.306, Codex 0.160.0 and quota-axi 0.1.64 were executed against disposable roots. `live-guards.sh` and `live-account-guards.log` prove selected-root validation, empty-root refusal despite ambient credentials, unknown real quota refusal, ambient opt-out, and home-pin precedence. The existing live E2E also exercises installed Pi; pi-signed is absent and outside this Claude/Codex change.

No authorized disposable vendor OAuth profiles with known exhausted/usable quotas were supplied. Synthetic API-key/helper profiles pass local login-status but cannot provide subscription quota; real quota-axi returns unknown and the product correctly refuses advancement. quota-axi help provides profile-only reads and snapshot fixtures, but no documented vendor endpoint override. A snapshot or fake quota executable would repeat the fixture regressions above, not prove live exhaustion. Operator profiles/credentials and shared services are out of bounds; no sign-in/out or credential copying was attempted. Consequently real Claude/Codex continuation, native Codex hook emission, stale replay after a real switch, and exhausted-account checkpoint recovery remain untested live. Provide two authorized disposable numbered subscription profiles and controllable exhausted/healthy quota conditions to complete those walks; no new owner decision is requested in this phase.

## Final focused execution results

- `bash bin/fm-test-run.sh --jobs 1 tests/fm-worker-account.test.sh`: passed with ordinary temporary-directory placement (account-tests-retry.log).
- `tests/fm-worker-account-live-e2e.test.sh` through the initial canonical runner: passed against installed Claude, Codex and Pi (focused-tests.log). pi-signed is absent and outside this change's required providers.
- Initial in-repository TMPDIR run also made tests/fm-control-relaunch.test.sh refuse a secondmate home inside the repository. Ordinary placement corrected that refusal, and the retry proceeded further before a different readiness timeout at tests/fm-control-relaunch.test.sh:1618–1625 (relaunch-tests-retry.log). The full relaunch file did not complete and is not reported green.
- Isolated existing `test_explicit_account_transaction`: passed at target. It exercises Codex explicit switch, work preservation, stale observation convergence, selected-root preservation on ordinary recovery, quota-driven next-account switch, home pin refusal before stopping, and Claude explicit switch (selected-relaunch-target.log). Agent/session/quota boundaries are simulated, so this is not a live vendor continuation claim.
- Isolated existing `test_prepublication_failure_keeps_concurrent_durable_metadata`: passed on both base 0846a727 and target 29effc46 (selected-relaunch-base.log, selected-relaunch-target.log). The failed larger invocation waited only 200 x 0.01 seconds for readiness; the isolated result identifies an intermittent readiness timeout, with no reproducible product failure here. No permanent timeout or product change was made to conceal it.

For the isolated relaunch reruns, each source file was copied into a temporary test in the same tests/ directory, all bare top-level `test_*` invocation lines were removed, and the named selectors above were appended. Function definitions and assertions were unchanged; an added failure-only `cat control.out` exposed the fixture's diagnostic if it failed. The base was extracted with `git archive 0846a727` into a disposable in-worktree directory. These drivers, archive and all other transient in-worktree files were removed after execution. Git reports no source changes.

Overall: accepted R1–R3 regression evidence retained; live isolated auth/selection/refusal checks passed; selected account transaction regression passed; one existing readiness test was intermittent; core vendor-backed continuation remains inconclusive. Subsequent Review should consume this exact report and its adjacent before/after and live-guard artifacts rather than treating the synthetic transaction as a live account-switch proof.
