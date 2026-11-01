---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A `forge=external` task reports `done [at=<epoch>]: review <url> uploaded for review` instead: run `bin/fm-review-check.sh <id> <review url>` rather than `bin/fm-pr-check.sh`, which arms no merge watch, then always escalate the review URL to the captain whatever the yolo setting, because firstmate can neither observe nor perform its approval or merge.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
For an earlier no-mistakes implementation handoff, use the [crew-state header's classification contract](../../../bin/fm-crew-state.sh) and the [inactive-reconcile header's upstream publication contract](../../../bin/fm-inactive-reconcile.sh).
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; `yolo` is the only standing routine merge authority.
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, exit 0 with no output otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

## Resource release and accepted completion

A merged PR establishes landing; the task's recorded acceptance criteria establish completion.
On a merge, inactive-worker report, or cleanup request, claim the task's lease, then read its current identity, branch/head, brief, proof obligation, hold and evidence before deciding which transition applies.

When deployment, product proof or another external condition is pending, preserve the task's existing owner, branch, durable progress and resumption note, proof obligation, dependency edges and merge watch.
Record the pending condition on that same task as an external hold using the [wrapper's hold-release syntax](../../../bin/fm-tasks-axi.sh), keeping the durable proof/resumption reference in its reason; preserve an existing captain hold through its own lifecycle instead of replacing it.
Once the work and follow-up are durable and no active validation or worktree process requires the worker, claim its lease, re-read the recorded PR through its forge and require a merged result, then run `bin/fm-control.sh <id> exit --landed-work`.
An open, closed-unmerged or unreadable PR does not authorize this pending-proof release.
Confirm the exit and read `bin/fm-capacity.sh --json`: retained metadata and an idle shell are not a live worker, but remaining non-shell work still occupies the seat.
Keep supervising the recorded condition through its existing owner; releasing a worker does not accept the task or unblock its dependents.
`--keep-open` teardown returns a local copy and is not a substitute for preserving pending-proof resume artifacts.

When the recorded resumption condition is satisfied and work remains, clear only that satisfied external hold through `bin/fm-tasks-axi.sh unhold <id>`, then use `bin/fm-control.sh <id> relaunch --note '<durable progress, proof still owed and next action>'` in the same home.
The existing worktree and task identity remain; the relaunch publishes a new generation.

After every required acceptance criterion has current evidence for the delivered revision, recheck the task under its lease and record its durable proof link with `bin/fm-tasks-axi.sh done <id> --note '<acceptance evidence>'`, clearing only a satisfied external hold first.
Acceptance precedes cleanup so a completed parent unblocks its eligible dependents while their dependency edges remain recorded.
With that lease still held, run ordinary `bin/fm-teardown.sh <id>` if its worker record remains; the script still proves work preservation and owns generation-safe cleanup.
An already accepted task with no worker record needs no further teardown.
A teardown refusal is a stop-and-investigate result, never an obstacle to bypass or force without explicit discard authority.
Retain the configured recent Done history and re-evaluate queued work only after the acceptance transition.
Use the configured manual-backend equivalent when automatic task transitions do not apply, preserving the same proof and ordering.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
