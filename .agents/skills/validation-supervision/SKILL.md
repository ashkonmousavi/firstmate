---
name: validation-supervision
description: Load when a ship starts or already has an active no-mistakes validation run, including a mid-run requirement change or finding, and before deciding an escalated no-mistakes finding.
user-invocable: false
metadata:
  internal: true
---

# Validation supervision

Fresh no-mistakes PR-path workers start their own run under `bin/fm-dod-lib.sh`; trigger validation on the same worker only for an older brief or a worker that has not started its run, using the harness invocation owned by `harness-adapters`.
The task worker that starts a no-mistakes run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.
Firstmate never invokes `no-mistakes axi respond` for a crew-owned run.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.
Once validation starts, prefer routing new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated; however, the smallest downstream changes needed to keep already accepted product or engineering behavior correct, add behavioral tests where an executable contract exists, or keep documentation accurate remain within the current task even when they touch files not named at intake, and corrections required to satisfy already accepted intent are not new requirements.

Only a current, explicit captain instruction that completely invalidates the work being validated keeps the task with the same worker instead of routing it to follow-up work or handing it to a replacement.
That worker cancels the active run through no-mistakes axi's supported abort command and confirms through axi status that the run has stopped before changing any code.
The worker then follows `branch_sync.next_action` from structured axi status: use axi sync's supported guarded recovery only when its code is `recover_custody`, and otherwise proceed only when structured status confirms that branch ownership is already returned and no recovery is required.
Custody recovery settles branch ownership, not content: the worker must replace the obsolete work from the correct pre-invalidation base rather than building on top of the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
Apart from that single supported abort, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
Once ownership is settled, validate exactly once against that final head so no obsolete or intermediate head is ever treated as authoritative.

A finding in the worker triage stop set returns as keyed `needs-decision`; firstmate loads `ask-user-authority` and either decides or escalates per that skill.
Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

`bin/fm-dod-lib.sh`'s `fm_nm_driving_block` owns the common triage, class-inventory payload and repeated-finding handoff for ordinary and promoted workers on both forges.
For each authorized fix, require the worker's actual respond call with its inventory guidance in the active step input and retained run evidence; launch prose alone does not prove the next Review checked the inventory.
Keep a mixed gate parked until its stop-set decision arrives; require installed help and a controlled receipt for singular-action selection semantics rather than guessing.
A repeated finding in the same run returns with a `working:` event and the exact response command when outside the stop set, not a new decision solely because it repeated.
On the third distinct Review list, `fm_nm_driving_block`'s last-list rule bounds a stop-set decision to approve with recorded follow-ups or hold, never another fix.
Check the current quoted code before relaying a repeat, following `ask-user-authority`; a stale repeat carries file:line proof.
If inventory propagation or mixed-gate semantics remain unproven, retain that precise external gap as unverified without adding a new pipeline or round cap.

Judge validation by the resolved state line from [`bin/fm-crew-state.sh`](../../../bin/fm-crew-state.sh), whose header owns outcome mappings and CI-monitor/daemon exceptions, never by shell liveness, the last status event, or a raw run record.
Workers parked at approval or fix-review must follow the active gate help.
A worker hand-editing, committing, aborting, or restarting during an active validation run duplicates pipeline ownership outside the supersession sequence above; steer it back to the gate response flow.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.
