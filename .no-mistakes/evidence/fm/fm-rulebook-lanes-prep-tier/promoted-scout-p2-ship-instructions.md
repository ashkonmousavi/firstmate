Your scout task has been promoted to a ship task, mode=direct-PR. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Investigate the fixture.

## Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/scout-p2` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/scout-p2 --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch (push only your `fm/scout-p2` branch). Never merge a PR.

# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/scout-p2
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
This task is complete only with an existing non-draft PR and every required check green for its current head.
When it is implemented and committed, push your branch and open a PR with `gh-axi` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Wait for every required check on the current PR head to be green, reading the forge with `gh-axi pr checks <number>` (consult its `--help` for current usage).
Pending checks use `paused [at=<epoch>]: {checks awaited and completion condition}`; resume when they finish, fixing failed checks and pushing the repair through this direct-PR path before checking again.
Then append `done [at=<epoch>]: PR {full https URL from the forge} checks green` to the status file and stop.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
