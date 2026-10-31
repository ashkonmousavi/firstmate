# Fleet update review evidence

Prepared for the outer validation and PR phases on 2026-10-31.
This is a private task handoff, not maintained product documentation.
The report named in R4 lives in another checkout and was not read under this phase's worktree-only project-read boundary.
The inventory below was reconstructed from the current worktree; it is not a verbatim copy of that report.
The outer PR phase should carry this inventory and the subsequent validation results into the PR evidence without publishing private home data.

## Review decisions

- R1/review-1: `fleet_branch` selects a checked-out `curated` branch, otherwise the existing default-branch resolver; upstream configuration no longer grants arbitrary feature branches fleet authority.
- R2: retain the existing shared branch/commit resolution gate before any home update; failed fetch, absent origin, unresolved branch, or absent remote commit aborts the pass.
- R3: remove the unpinned status-2 retry; name the rejecting secondmate and host as requiring a manual update, leave them out of both action sets, and retain remote commit comparison.
- R4: supply this affected-class inventory and distinguish executable coverage from live evidence that remains for the outer validation phase.

## Class inventory

| Class boundary | Affected paths and transitions | Executable regression or inspected reason | Evidence limits / handoff |
| --- | --- | --- | --- |
| Fleet branch selection | `fleet_branch` feeds `primary_head_commit`, bootstrap/spawn sync, `ff_target`'s home branch guard, and `fm-update.sh` target resolution and remote propagation. | `tests/fm-secondmate-sync.test.sh`: curated primary and standalone home; detached home; primary pushed with `git push -u origin feature/wip`; feature checkout remains skipped. `tests/fm-update.test.sh`: curated fleet and pushed-feature primary. | Curated/default only; no new configured branch aliases or matching rules. |
| Shared update resolution | Primary, live local worktree, registry-only worktree, detached standalone clone, and registered remote route; unresolved target to aborted pass. | `test_unresolved_target_leaves_all_homes_untouched` in `tests/fm-update.test.sh`: transient first-fetch failure, missing origin, unresolved default branch, missing origin/curated ref; unchanged HEADs, no remote contact, no second fetch. | Real fixture Git repositories; fetch failure injected at the Git executable boundary. |
| Target pin and remote handoff | Parent target to remote configured code root through `cmd_update`, then `cmd_sync` to persistent home; updated/current to settled, mismatch/rejection to skipped. | `tests/fm-update.test.sh`: curated branch/commit arguments, remote mismatch, and status-2 legacy rejection. `tests/fm-remote-secondmate-lifecycle-e2e.test.sh`: pinned code-root/home update. | Status-2 regression records one request and checks real remote fixture HEADs remain unchanged; stub models the old updater advancing both to main if an unpinned retry occurs. Lifecycle suite is an existing validation entry point, not claimed run in this fix phase. |
| Remote step bounds | Update and agent-state reads, timeout to skipped with no restart; next registry home remains reachable. | `test_remote_steps_are_bounded` in `tests/fm-update.test.sh` exercises both named timeout steps. | Uses shared `fm_run_timed`; `tests/fm-timeout-lib.test.sh` owns timeout mechanism behavior. No timeout implementation changes in this round. |
| Local ancestry and state guards | Behind/current, dirty, feature checkout, genuinely divergent, content-equivalent squash divergence, unsafe or duplicate home; successful update to rebind/restart/nudge. | `tests/fm-update.test.sh` and `tests/fm-secondmate-sync.test.sh` exercise these existing safety decisions. | The branch selector changes acceptance only; no reset, stash, force, ancestry, deduplication, or operational-directory guard is added or relaxed. |
| Serving progress | Worker startup to first progress stamp; each serving pass to next stamp; stalled main loop with live heartbeat to withheld readiness; resumed progress to readiness. | `tests/fm-remote-job.test.sh`: wedged serving process while heartbeat remains alive, stale readiness, replacement, and queued side effect; existing idle-heartbeat and execution-rate checks. | Existing regression uses real worker processes and SIGSTOP for a non-progressing loop, not a reproduction of Bash's exact blocked-SIGCHLD internals. It was inspected, not run in this review round. |
| Linux replacement ownership | Ready owner/current identity to reuse; identity mismatch or verified live unready owner to whole-tree stop and restart; quarantine or changed ownership to refusal. | `tests/fm-remote-job.test.sh`: stale ownership, quarantine, resumed ousted worker, replacement safety, and stalled-loop drain. | Replacement continues through the existing owner identity and isolated process-group boundaries; no unverified PID is killed. Existing tests need refresh in the outer validation phase. |
| macOS worker lifecycle | Same heartbeat/progress loop; readiness repair uses the existing LaunchAgent path rather than Linux start/replacement. | `fm_remote_job_ensure_worker` dispatches Darwin to `fm_remote_job_ensure_launchagent`; `tests/fm-remote-job-launchagent.test.sh` owns simulated LaunchAgent repair coverage. | Native macOS, Aqua login, launchctl repair, and suspend/resume were not exercised here. Tick-based stall detection avoids treating elapsed suspended wall time alone as a stall; native proof remains a validation gap. |
| Platforms and Git representation | Linux and macOS; named curated/default checkouts, detached homes, linked worktrees sharing refs, standalone clones, remote clones. | Git selection uses symbolic refs and commit ancestry, without OS-specific branch logic; the two focused suites use real fixture Git operations. | Focused execution here runs only on the current Linux host. Portable tests do not establish native macOS behavior. |
| Runtime backends | tmux, Herdr, cmux, zellij, Orca, Paseo; local/remote live state and restart capability. | Git selection, target pinning, and worker progress execute before or independently of backend operations. `fm_secondmate_restart_capable` and agent-state adapters retain their existing ownership; update tests cover restartable tmux/remote Herdr, dead endpoint, and unprovable runtime nudge. | No backend command or classifier changed. `tests/fm-secondmate-restart.test.sh` and lifecycle suites remain outer-phase regression entry points. Real endpoint replacement is not claimed by SSH/backend stubs. |
| Harnesses and task kinds | Primary and persistent secondmates; ships/scouts only as unrelated queued job payloads. Claude, Codex, OpenCode, Pi/Pi Signed, Grok, Kimi, Cursor, OMP, Muse, Gemini, Rovo, AGY, Devin, Command Code, Polytoken. | Changed selection and transport paths do not inspect model output, executable names, or vendor UI. Harness launch, dispatch, model choice, and instruction reload semantics are unchanged; existing restart-capability policy still owns each adapter's restart/nudge decision. | No live model or vendor CLI was launched. `tests/fm-harness-liveness-drift-live-e2e.test.sh` and `tests/fm-secondmate-busy-contract-live-e2e.test.sh` are existing live guards if validation claims real harness liveness or persist/restart proof; record installed harness versions and missing coverage rather than treating stubs as native proof. |
| Accounts and route ownership | Local Git origin; explicit SSH route; remote account home/uid; inherited parent target; persistent home metadata. | Branch selection no longer reads `branch.<name>.remote/merge`. Worker state canonicalization, identity checks, quarantine, SSH route resolution, and remote account-home selection remain unchanged. | No credentials, account pins, provider selection, login, or global tool configuration changed. The tests use isolated Git identities and fake SSH boundaries, not production account access. |
| Restart and recovery lifecycle | Updated/current to restart or nudge; dead/missing, dirty/divergent, timeout, mismatched commit, and rejected pin to no action; worker supervisor replacement to queued-job service. | Focused update tests assert disjoint action summaries, no action for rejected hosts, and unchanged rejected root/home HEADs. Existing remote lifecycle suite covers startup readiness repair and dead endpoint relaunch. | No production fleet restart or live-machine repair is authorized in this review phase. |

## Verification

The new regressions' independent oracle is the owner's recorded R1/R3 decision: publishing a feature branch must not make it a fleet target, and rejecting pinned arguments must leave the host untouched with a manual-update diagnostic.
They reject the old behaviors of accepting any same-named tracked feature branch and making a second unpinned request that advances remote clones to main.
The focused review verification is `bash tests/fm-update.test.sh` followed by `bash tests/fm-secondmate-sync.test.sh`.
Executed together on 2026-10-31 as `bash tests/fm-update.test.sh && bash tests/fm-secondmate-sync.test.sh`; exit status 0.
Relevant output:

```text
ok - T9 firstmate off its default branch is skipped, not forced
ok - T13 a curated fleet updates the primary, local and remote homes to one curated commit
ok - unresolved targets abort before updating primary, live, registry, cloned or remote homes
ok - a status-2 host is reported for manual update without an unpinned retry or mutation
# all fm-update tests passed
ok - T1b curated is followed and feature branches are excluded even with an origin upstream
# all fm-secondmate-sync tests passed
```

The outer executor owns broader worker, lifecycle, lint, live-harness, native-platform, PR, and CI phases.
