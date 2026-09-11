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
Keep the candidate containing current main at all times, merging main into it rather than rebasing onto it.
That is what preserves the shape everything else depends on, for two independent reasons.
A rebase rewrites the constituent commits themselves, so the exact recorded head each constituent's binding and teardown proof reads stops being an ancestor of the candidate and that constituent can no longer be proven landed; and the pipeline only rebases a candidate that does not already contain its target, so a candidate that contains main is left alone (`shouldSkipRebase` returns "already ahead of" at `internal/pipeline/steps/rebase.go:448` in the installed no-mistakes `bdfc272`, honoured by both `tryRebase` and `rebaseWithAgent`).
A candidate proven this way is also attested on its own exact head, so a project whose attestation refuses merge commits refuses them only in its rebase-equivalence fallback and never sees this candidate: in `.github/workflows/xau-ci-attestation.yml` the rebase-equivalence step runs only when the exact-head recheck failed, and the merge-commit refusal lives in that fallback alone (`scripts/ci_check_rebase_attestation_equivalence.py:296-299` at XAUUSD main `c4b3eee19`).
That fallback is not a safety net worth planning around either: its equivalence rule is stricter than a byte-identical diff, and it has been observed refusing a genuinely content-free rebase because the predicate follows one import hop beyond the paths the change touched (a moved module the changed test imported).
Never rebase a batch candidate to make main move under it, and never reach for a different-files or range-diff waiver to excuse the result.
Select the combined task's existing delivery path so it satisfies every constituent's required review, attestation, checks, and affected user journeys.
Freeze the bounded membership when the combined validation run starts.
Work that becomes ready after that point lands alone or enters a later batch.

Before validation, compare the combined candidate with current main and with every constituent head.
Review every join, conflict resolution, changed assumption, and affected consumer.
Preserve each constituent's review and evidence, but do not treat that earlier evidence as proof of the joins.
A material integration change requires renewed review of the affected surface.
State the result of that comparison explicitly, per constituent: what is missing from the candidate, what was deliberately replaced and why, and what the joins themselves had to repair.
An unchanged tree after a binding merge is not evidence that every constituent behavior survived, so never let a tree, diff, or range comparison stand in for that statement, and never reach for a patch-equivalence waiver to avoid writing it.

## Hold the landing window

While the current candidate is in its final verification - absorbing current main, its checks at that exact head, and the merge - unrelated merges into main hold.
The hold covers merges only.
Every other lane keeps building, reviewing, and running its own pipeline throughout; nothing waits for the window except the act of merging.
This is scheduling discipline, not another queue: it is opened for one candidate that is actually in final verification, never held open for work that has not started.

Firstmate opens the window when the candidate enters that final verification and is the only actor who may release it.
It releases when the candidate lands, or when firstmate judges the candidate needs substantial further work - a failed check that needs a real fix, or a changed assumption found in the join review.
Substantial means it goes back through the pipeline rather than finishing this window.
A released window frees main immediately; the released candidate re-enters the queue behind whatever lands next and is proven again from that new main.

## Prove and land the combined candidate

Run the selected delivery process once on the frozen combined candidate, including its required review or attestation, checks, and affected user journeys.
Do not additionally restart every constituent's separate pipeline merely because main advanced.
Rule F still requires conclusions at the combined pull request's exact current head.
The `bin/fm-pr-merge.sh` current-main containment guard still applies to that combined head.
If either condition fails, repair the combined candidate and re-prove the repaired combined head; never reuse evidence from its stale predecessor.

When an earlier landing moves main out from under a candidate that already passed, merge the new main into that candidate and run the combined delivery process once more at that exact head.
That is one combined run, never a restart of each constituent's own pipeline, and it is the only supported answer: rebasing the candidate instead would rewrite the exact constituent heads every binding reads and push the attestation onto a fallback that refuses merge commits.
The held landing window is what keeps this rare.
Record in the combined pull request body which commit the pipeline actually tested and which commit the merge actually produced.
Under a squash-merge landing those are two different commits, and the record states both: the pipeline-tested head is the exact combined head that was proven, and the landed commit is the one the merge itself created on the default branch, read from the forge rather than inferred, because a pull request head that exists is not evidence that it landed.

Land the combined pull request through `bin/fm-pr-merge.sh` under the project's own landing shape.
Its GitHub default is squash, which is correct wherever the project's own contract makes every commit on its default branch a squash merge - XAUUSD decides exactly that in its `AGENTS.md` and in `scripts/generate_stage_gate_record.py`'s binding-truth contract, and its `verify-records` enforces it, so no commit of any pull request is ever an ancestor of that project's main and a merge-commit landing is not available there at all.
`--merge` remains available for a project whose contract allows it, but it is not prescribed for a batch: an absorbed constituent is proven from the combined pull request's own permanent head ref, not from its commits reaching main, so a squash landing strands nothing.
Existing merge authority still decides who may run that guarded merge.

## Bind and close every constituent

Use the exact conditional batch Definition of done and route-specific pull-request body records rendered by `bin/fm-dod-lib.sh`.
Never create a constituent pull request merely to make a prepared branch eligible for the batch, and never record an original pull request as merged when the combined pull request is the landing.
For a PR-backed constituent, close its original pull request as superseded by the combined pull request, never as merged.
Register that original pull request as the constituent's own `pr=` first, with an ordinary `bin/fm-pr-check.sh <task-id> <original-pr-url>`, if it is not already recorded there: `--absorbed-by` reads only this task's own metadata, so a constituent with no recorded `pr=` is always taken as PR-less, even when it actually has an original pull request. `--absorbed-by` prints a note naming this when it takes the PR-less path, so a constituent's real pull request never binds silently down the stricter PR-less route.
After that close and before landing, run `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` so the constituent's watcher reports the actual combined landing.
An integration owner that is itself a PR-backed constituent is bound with `--absorbed-by` like every constituent, and `bin/fm-pr-merge.sh` refreshes that same binding when it lands the combined pull request.
That route preserves the original pull request identity, records its closed-superseded-not-merged disposition and exact constituent branch and head, verifies that the combined head contains the constituent head, replaces the task's canonical watched `pr=` with the combined pull request, and arms the ordinary merge poll.
When a constituent advanced after its closed original pull request, it may instead record the original head and exact absorbed head only after proving the former is an ancestor of the latter and the combined head contains the latter; that record captures what the combined run proved, not a waiver.
For a constituent prepared without an original pull request, wait until the combined pull request merges, then run the same `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` command.
That route binds only after proving the combined pull request merged, the forge-reported merge commit is present on the current default branch, and the combined pull request's permanent head ref contains the constituent's exact reviewed head.
Preserve any independent publication obligation the constituent's selected delivery route requires; PR-less batch membership does not erase such an obligation.
The binding connects three facts, and cleanup later proves all three: the reviewed constituent work, the verified combined pull request head, and the actual landing - the pull request merged per the forge and the commit its merge produced present on the default branch.

The landing record's second commit does not exist until the merge has happened, so complete that row in the body immediately after landing rather than leaving it as a placeholder.
After the combined pull request lands, reconcile every included task to that same landing and confirm the superseded pull requests remain closed.
Release each eligible branch, worktree, and lease only through the existing guarded lifecycle.
Teardown must still refuse an unmerged combined pull request, a constituent head the combined pull request's own permanent head ref does not contain, a merge commit the forge does not report or that is absent from the default branch, later unlanded constituent work, dirty state, or any other genuinely unlanded work.
It never requires the constituent head itself on the default branch: under a squash-merge contract it never gets there, and requiring it refused work that had genuinely landed.
This binding records identities for cleanup; it waives no re-verification anywhere.
