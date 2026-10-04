# Task
## Captain's intent
Check the marker only.

## Firstmate spec
Investigate the isolated marker.


# Current ship Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promotion-local-only` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promotion-local-only --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including the stop set; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=local-only.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to any remote and never open a PR. Work only on your `fm/promotion-local-only` branch; firstmate handles the merge into local `main`.

# Definition of done
Delivery contract: mode=local-only
Ship branch: fm/promotion-local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch `fm/promotion-local-only`. Do NOT push, do NOT open a PR, do NOT merge.
A `done:` is accepted when the named head is on this project's shared local branch, not only on a detached copy; the check tests that head, not merely that a branch moved.
Keep your branch a clean fast-forward onto the current default branch - if `main` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append `done [at=<epoch>]: ready in branch fm/promotion-local-only` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local `main` through the guarded fast-forward path.

# Task preparation record
This task has a preparation record at `/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M42JD1EGCXV3KJW39JC23GXS/.live-preparation-wtyw01wl/data/promotion-local-only/prep.md`.
Read it in full before you plan or write anything: it is the specification beneath this brief, and it supersedes your own reconstruction of what the change should do.
Its `## Tier` header decides how much the record says; a section it does not carry was ruled out there, not forgotten.
Builders and post-implementation verifiers use `## Expected outcomes and how to check each` as the same explicit acceptance list, alongside the applicable `## 2. Behaviour spec`, `## 11. Definition of done` and `## Captain's intent` above.
Check each outcome row with its named command/public seam or screen and region and expected value, and report actual evidence and unproven claims without promoting fixture proof into real launch or installed proof.
A section answered `n/a: <reason>` is a decision already taken, not an invitation to fill the gap yourself.
Write the tests named in Tests before their passing code, one slice at a time at the named public seams.
If the record is wrong or incomplete for what you find in the code, say so through the status file rather than silently building something else.
