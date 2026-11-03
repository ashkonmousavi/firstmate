---
name: ship-landing
description: Load before selecting or driving delivery validation, ordering CI work, or merging; when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
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

## Selected delivery path and merge authority

The selected delivery path owns its own rigor.
When no-mistakes is selected, no-mistakes alone owns review, fixes, tests, documentation, push, PR, and CI; otherwise follow the faster path without adding an independent reviewer.
Never hold work outside no-mistakes for a manual clean verdict, stack serial manual reviews, or infer authority for one from security, architecture, or risk alone.
A separate review or audit is allowed only when the captain explicitly requests that deliverable or the authorized task is a knowledge-only review; one named question remains scoped to that question.
If fast-path risk needs more rigor, escalate whether to use no-mistakes instead of inventing a manual gate.
The path's worker, automated gates, and captain approval remain authoritative:

- **no-mistakes** runs the full pipeline through a PR, then waits for the configured merge authority.
- **direct-PR** has the worker push and open a PR without the no-mistakes pipeline, then waits for the configured merge authority.
- **local-only** has the worker stop with a clean ready branch, then waits for the configured merge authority before firstmate uses the guarded fast-forward merge path.

Delivery mode and `yolo` are orthogonal.
`yolo` governs merge authority only: with it off, the captain approves every PR merge and every local-only landing; with it on, firstmate merges green, in-scope work itself.
Never merge a red PR, or one with a required check that has not reported, under either setting unless a current explicit captain instruction names the GitHub check to waive or orders that merge for a GitLab merge request with no head pipeline; `bin/fm-pr-merge.sh`'s header owns the attended-only waiver mechanics and remaining guards.
Destructive, irreversible, and security-sensitive merges still escalate.
Without a current explicit captain instruction that states the concrete merge, the green default stands, and standing `yolo` cannot authorize a red merge; section 1 owns when such an instruction overrides a Firstmate-written standing rule within its exact scope.
Load `ask-user-authority` and `validation-supervision` before deciding or answering any ask-user finding; the implementation worker never answers its own finding.
Use `bin/fm-pr-merge.sh` for every task PR merge so merge metadata is recorded and an unproved merge is refused instead of reported as landed, and use `bin/fm-merge-local.sh` for approved local-only landing; never call a lower-level merge command around their guards.
After an autonomous merge, give the captain a one-line full-URL or local-main outcome.

## Red post-merge main

When a post-merge main run turns red, firstmate lands a revert within one hour unless a fix is already green on main; never put a fix chain ahead of the queue.
Use the guarded PR merge path and verify the post-revert main result before reporting recovery.
