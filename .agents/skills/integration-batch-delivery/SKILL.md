---
name: integration-batch-delivery
description: >-
  Agent-only contract for choosing, preparing, proving, landing, recording, and
  closing a bounded combined pull request that absorbs compatible ready work.
user-invocable: false
metadata:
  internal: true
---

# Integration batch delivery

Load this skill before deciding whether compatible ready work lands alone or through a combined pull request, and before preparing, validating, landing, recording, or tearing down an integration batch.
This is a delivery shape under the existing selected-path and merge-authority rules, not a new approval hierarchy.

## Choose the delivery shape

Use an integration batch when two or more ready changes for the same project are compatible, their reviewed commits can be preserved together on current main, and one combined proof gives a clearer or less wasteful result than restarting each constituent only because main advanced.
Land a change alone when it has no compatible ready peer, needs a materially different or urgent landing window, cannot satisfy every constituent's required delivery path in one combined pull request, or would make the joins, evidence, or risk harder to review.
Do not batch merely because files differ, and do not use a different-files or range-diff waiver.
Preparation may continue in parallel, but landing windows remain serial: one batch or standalone pull request is the current landing candidate at a time.

## Establish the batch

Assign exactly one integration owner.
The owner starts the combined branch from current main and integrates the exact reviewed constituent commits without squashing or rebasing them away.
Use merge commits for conflict resolution so the constituent heads remain reachable and the join is explicit.
Select the combined task's existing delivery path so it satisfies every constituent's required review, attestation, checks, and affected user journeys.
Freeze the bounded membership when the combined validation run starts.
Work that becomes ready after that point lands alone or enters a later batch.

Before validation, compare the combined candidate with current main and with every constituent head.
Review every join, conflict resolution, changed assumption, and affected consumer.
Preserve each constituent's review and evidence, but do not treat that earlier evidence as proof of the joins.
A material integration change requires renewed review of the affected surface.

## Prove and land the combined candidate

Run the selected delivery process once on the frozen combined candidate, including its required review or attestation, checks, and affected user journeys.
Do not additionally restart every constituent's separate pipeline merely because main advanced.
Rule F still requires conclusions at the combined pull request's exact current head.
The `bin/fm-pr-merge.sh` current-main containment guard still applies to that combined head.
If either condition fails, repair the combined candidate and re-prove the repaired combined head; never reuse evidence from its stale predecessor.

Use a commit-preserving merge method for the combined pull request.
The GitHub default of `bin/fm-pr-merge.sh` is squash, so an integration batch must pass its explicit merge-commit option.
Existing merge authority still decides who may run that guarded merge.

## Bind and close every constituent

Use the exact conditional batch-owner Definition of done and pull-request body table rendered by `bin/fm-dod-lib.sh`.
Close every original pull request as superseded by the combined pull request, never as merged.
After that close and before landing, run `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` for every constituent so its own watcher reports the actual combined landing.
That command preserves the original pull request identity, records its closed-superseded-not-merged disposition and exact constituent branch and head, verifies that the combined head contains the constituent head, replaces the task's canonical watched `pr=` with the combined pull request, and arms the ordinary merge poll.

After the combined pull request lands, reconcile every included task to that same landing and confirm the superseded pull requests remain closed.
Release each eligible branch, worktree, and lease only through the existing guarded lifecycle.
Teardown must still refuse an unmerged combined pull request, a constituent head absent from current main, later unlanded constituent work, dirty state, or any other genuinely unlanded work.
