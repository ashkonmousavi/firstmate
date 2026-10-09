You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
## Captain's intent
Correct the control label covered by the completed live walk.

## Firstmate spec
Preserve the checkpoint-covered quick-fix scope.




# Herdr lifecycle declaration - NOT ENABLED
**HARD SAFETY GATE:** this scaffold cannot inspect the task text filled in above.
If the task will start, stop, delete, restart, profile, or otherwise drive Herdr lifecycle behavior, stop and regenerate the brief with `--herdr-lab` before dispatch.
Do not add Herdr lifecycle commands to this unguarded brief by hand.

# Setup
You are in a disposable git worktree of check, at a detached HEAD on a clean default branch.
This is a SCOUT task: write `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/report.md`; no branch, push or PR.
Confirm `pwd -P` and `git rev-parse --show-toplevel` name the assigned isolated worktree, never the primary checkout.
Read `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/prep.md` when present; its expected outcomes govern verification.
The worktree is your laboratory - install, run, edit, and make scratch commits freely; all of it is discarded at teardown.
The report is the only thing that survives, so anything worth keeping must be in it.

# Communication
Status: '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state/promote.status'
Append: `echo "{state} [at=<epoch>]: {one short line}" >> '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state/promote.status' && { [ ! -e '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/config/fleet-ledger' ] || '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/bin/fm-fleet-ledger.sh' appended '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/config' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state/promote.status' >/dev/null 2>&1 || true; }`
Inbox: '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state/promote.inbox'
Read messages numerically and move handled messages to `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state/promote.inbox/handled/`.
An absent or empty inbox needs no action.
Declare long waits; report only actionable phase changes, decisions, blockers and outcomes.

# Worker contract
Before work, run and read this task's rules, communication, wait and completion contract:
```bash
FM_CLASSIFY_PAUSED_VERB='paused' bash -c '. "$1" || exit; shift; fm_worker_contract_block "$@"' _ '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/bin/fm-dod-lib.sh' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/state' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/config' 'promote' 'scout' '' 'fm/promote' 'none' '2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.'
```
For a visual deliverable, use the lavish-axi rule in `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.agents/skills/scout-completion/SKILL.md`; the process-event owner `bin/fm-procevent-lavish.sh` owns board arming and acknowledgement.



# Current ship Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promote` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promote --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including the stop set; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=direct-PR.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
This replaces the scout rule limiting outside-worktree writes to the report and status file.
Keep project edits inside this worktree; keep proof and scratch output outside it, under `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/` or a temporary directory.
Outside the worktree, write only that task material and the status and steering-inbox records authorized below.
Leave the worktree clean before reporting done.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch (push only your `fm/promote` branch). Never merge a PR.

   Review follow-ups: A review finding left unfixed when its review closes is a follow-up item, never a claimed fix: write each one verbatim and unparaphrased (id, severity, file, line, action, description) to `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/review-followups-<review>.txt`, where `<review>` is the no-mistakes run id or `pr`, then file that file as one queued backlog item with
   `FM_DATA_OVERRIDE='/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data' '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/bin/fm-tasks-axi.sh' add --mint "review follow-ups: promote <review>" --body-file '/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/review-followups-<review>.txt'`
   and name the file and the printed item id in your next status line.
   These records are the only writes outside this worktree this rule permits.

# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/promote
class fix: test fails without the fix; symptom seen twice.
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
This is a ship-light fix: its preparation record names the live journey walk or other checkpoint that already tests it, so it gets no review round, no extra test round and no hosted-check wait.
Run only the tests of the modules you changed, then publish.
This task is complete with an existing non-draft PR for your latest commit.
When it is implemented and committed, push your branch and open a PR with `gh-axi` that is ready for review, not a draft.
Before you report done, read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {full https URL from the forge}` to the status file and stop; do not wait for its checks.
That `done:` is accepted only when this copy's HEAD - your latest commit - is pushed to your PR branch; the check tests that commit, not merely that a branch moved.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
Do NOT run /no-mistakes. The configured merge authority lands it on green ordinary checks; firstmate relays the outcome.

# Task preparation record
This task has a preparation record at `/home/tegris/.no-mistakes/worktrees/92d12cd65d25/01M4G0K80WBNTDBXT67M2SZ8F3/.test-phase/lab/data/promote/prep.md`.
Read it in full before you plan or write anything: it is the specification beneath this brief, and it supersedes your own reconstruction of what the change should do.
Its `## Tier` header decides how much the record says; a section it does not carry was ruled out there, not forgotten.
Builders and post-implementation verifiers use `## Expected outcomes and how to check each` as the same explicit acceptance list, alongside the applicable `## 2. Behaviour spec`, `## 11. Definition of done` and `## Captain's intent` above.
Before building, compare the recorded Still valid evidence with the current task and base; report any invalidating change to firstmate before implementing obsolete scope.
Check each outcome row with its named command/public seam or journey and expected value.
In the existing task report or delivery evidence, record outcome ID, actual observation, pass/fail/not exercised, candidate/environment, evidence pointer, and the owner and next action for anything unproven; do not overwrite the expected result to match the implementation.
Only list a sibling as closed when its linked outcome has passed at the required evidence class.
Keep fixture, real launch and installed proof separate.
A section answered `n/a: <reason>` is a decision already taken, not an invitation to fill the gap yourself.
Write the tests named in Tests before their passing code, one slice at a time at the named public seams.
If the record is wrong or incomplete for what you find in the code, say so through the status file rather than silently building something else.
