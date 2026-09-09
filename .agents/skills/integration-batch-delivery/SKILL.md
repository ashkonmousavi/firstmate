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
A plain `git rebase` carries no `--rebase-merges`, so it flattens the candidate and drops exactly the merge commits each constituent's binding and teardown proof read; and the pipeline only rebases a candidate that does not already contain its target, so a candidate that contains main is left alone (`shouldSkipRebase` returns "already ahead of" at `internal/pipeline/steps/rebase.go:448` in the installed no-mistakes `bdfc272`, honoured by both `tryRebase` and `rebaseWithAgent`).
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
That is one combined run, never a restart of each constituent's own pipeline, and it is the only supported answer: rebasing the candidate instead would drop the merge commits every constituent binding reads and push the attestation onto a fallback that refuses merge commits.
The held landing window is what keeps this rare.
Record in the combined pull request body which commit the pipeline actually tested and which commit actually landed; under this shape they are the same commit, and a body that cannot say so honestly is a candidate that has not finished its verification.

Land the combined pull request with `bin/fm-pr-merge.sh --merge`.
The GitHub default of `bin/fm-pr-merge.sh` is squash, which is right for a standalone pull request with one reviewed outcome and wrong here: it would collapse the constituent commits and strand every absorbed constituent at cleanup, because each one's landing proof reads its own exact head from the merged combined history.
Existing merge authority still decides who may run that guarded merge.

## Bind and close every constituent

Use the exact conditional batch-owner Definition of done and pull-request body table rendered by `bin/fm-dod-lib.sh`.
Close every original pull request as superseded by the combined pull request, never as merged.
After that close and before landing, run `bin/fm-pr-check.sh --absorbed-by <task-id> <combined-pr-url>` for every constituent so its own watcher reports the actual combined landing.
That command preserves the original pull request identity, records its closed-superseded-not-merged disposition and exact constituent branch and head, verifies that the combined head contains the constituent head, replaces the task's canonical watched `pr=` with the combined pull request, and arms the ordinary merge poll.

After the combined pull request lands, reconcile every included task to that same landing and confirm the superseded pull requests remain closed.
Release each eligible branch, worktree, and lease only through the existing guarded lifecycle.
Teardown must still refuse an unmerged combined pull request, a constituent head absent from current main, later unlanded constituent work, dirty state, or any other genuinely unlanded work.
