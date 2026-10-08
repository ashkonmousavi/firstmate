---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

Both PR-based ship paths report `done [at=<epoch>]: PR <full https URL from the forge> checks green` only for a non-draft PR whose required checks are green on its current head, under `bin/fm-dod-lib.sh`; pending checks or a deliberately held draft declare a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
An older no-mistakes brief's `done [at=<epoch>]: {summary}` remains an ungated pipeline handoff; fresh PR-path workers start validation themselves under `bin/fm-dod-lib.sh`.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For a PR-based landing, retain the targeted current-main candidate proof required by `AGENTS.md` section 7 and confirm the forge's actual merged state; queue enrollment alone is pending.
When the project has a deploy target, verify its deploy or release workflow, installed version, changed-area walk through `journey-walk`, and post-install health.
Report those concrete results before declaring completion or tearing the task down; a local-only landing reports its local outcome once the fast-forward merge succeeds.
The full default-branch run is a separate daily audit and never holds landing, completion or teardown; report it as a distinct fact and repair its failures in parallel.
When the next queued change's targeted run fails on a module this merge touched, the installed changed-area walker re-check fails, or post-install health fails, firstmate lands a revert of the responsible merge within one hour of the failing result; never put a fix chain ahead of the revert.
Dispatch a ship to prepare isolated revert source and publish its own real PR, then use the existing verified-head merge guard; `bin/fm-pr-merge.sh`'s header owns the worker preparation command and ordinary merge invocation.
The revert lands on its own classify pass, with any other named-check disposition recorded by firstmate under the current waiver authority; the guard still refuses every unwaived or unproved condition.
Retain the detector and revert PR/head/check receipts and verify the revert's targeted landing proof and applicable installed changed-area walk and health before reporting recovery or cleaning either task; the fix returns through the queue.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, exit 0 unless the check itself failed, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
