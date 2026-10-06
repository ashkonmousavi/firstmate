# Walk evidence
When this task commissions an end-to-end user journey, follow the project walk procedure from the real user entry point through the intended result and its return or reopen step where applicable.
Before walking, verify the assigned actor, candidate and data, plus working Chrome DevTools or equivalent console, network and application diagnostics within the access this brief authorizes.
Record each step as the human expectation, actual observed result, pass/fail/not exercised, and evidence tied to that candidate; retain the first failing boundary and enough permitted diagnostics for its owner to investigate.
Source inspection and isolated checks support diagnosis but do not substitute for the walked result.
Unavailable setup or diagnostic access is a named gap with an owner and next action, never a successful walk or permission to sign in or change production.
# Rules
1. Never push to the default branch (push only your `fm/direct-pr-none` branch). Never merge a PR.
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state} [at=<epoch>]: {one short line}" >> '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.status' && { [ ! -e '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/config/fleet-ledger' ] || '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/bin/fm-fleet-ledger.sh' appended '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/config' '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.status' >/dev/null 2>&1 || true; }`
   States: working, needs-decision, blocked, paused, done, failed.
   Substitute `<epoch>` with the current Unix time in seconds - run `date +%s` and write the number it printed; a stamp that is not plain digits records no time at all.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor
   would act on (setup done, bug reproduced, fix implemented, validation passed) and the
   needs-decision/blocked/paused/done/failed states. No step-by-step FYI progress lines;
   firstmate reads your pane for that.
   Whenever you mention a PR anywhere - a status line, your terminal, a summary - write its full
   https:// URL exactly as the forge printed it, never a bare number such as "PR 108"; firstmate
   copies that URL from your line rather than assembling one.
   A mid-task `working:` line (including setup complete) is nonterminal: do not end the
   turn after it; continue the same stage until a defined `done:` gate under Definition of done.
   Use `paused: {why}` - distinct from `blocked:` - when deliberately waiting for work or an external condition expected to clear on its own, including your own validation round.
   Before ending your turn with your own background shell or monitor still running, or before waiting on your own pipeline run or a long foreground command, append `paused [at=<epoch>]: {job and completion condition}` to the status file.
   Name what you are waiting for and what will let you resume; do not repeat the declaration on every poll.
   Do not declare active implementation or reasoning as a wait.
   Firstmate may still raise one first-sight alert; the declared wait then uses the existing long recheck cadence instead of repeated possible-wedge alarms.
   When you know when the wait clears, include `until <YYYY-MM-DDTHH:MMZ>` (UTC) for a recheck at that time.
   Follow the resolution rule below when the wait clears, then resume the task.
   Use `blocked:` when you are stuck and need help.
5. If you hit the same obstacle twice, append `blocked [at=<epoch>]: {why}` and stop; firstmate will help.
   When the obstacle is a failing test or check, first reproduce it with one command and rank three to five hypotheses with disproof observations, and put the command and leading hypothesis in the blocked line.
6. If a decision belongs above the implementation worker (product choices, destructive actions),
   append `needs-decision [at=<epoch>]: {summary of options}` and stop. Firstmate will reply with the decision.
   Review follow-ups: A review finding left unfixed when its review closes is a follow-up item, never a claimed fix: write each one verbatim and unparaphrased (id, severity, file, line, action, description) to `/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/data/direct-pr-none/review-followups-<review>.txt`, where `<review>` is the no-mistakes run id or `pr`, then file that file as one queued backlog item with
   `FM_DATA_OVERRIDE='/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/data' '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/bin/fm-tasks-axi.sh' add --mint "review follow-ups: direct-pr-none <review>" --body-file '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/data/direct-pr-none/review-followups-<review>.txt'`
   and name the file and the printed item id in your next status line.
   These records are the only writes outside this worktree this rule permits.
   A decision or blocker you opened stays open until a `resolved` line carrying its exact key lands; a later `done:` or `working:` line never closes it, even when the answer is what started that work.
   Firstmate's reply normally writes that closing line at answer time; when a blocker or wait clears WITHOUT a firstmate reply, append `resolved [at=<epoch>]: {how it cleared}` yourself (same `[key=<slug>]` if you opened it with one) as you resume.
7. Never administer infrastructure that every lane shares. Two things are shared:
   - The `no-mistakes` daemon - one instance serving every lane/home, so stopping, restarting, or
     updating it kills other lanes' in-flight pipeline runs; only firstmate manages the daemon.
     Before you append `blocked:` about the pipeline, run `no-mistakes daemon status` and
     `no-mistakes axi status`. If the daemon socket refuses connections or is missing, append
     `blocked [at=<epoch>]: {the daemon error}` and stop even when the local run record still says running or
     fixing, because that record can be stale after the daemon exits. A run record failed with a
     daemon error is also a real block.
     Only after ruling out socket refusal, if the run is still running or fixing, reattach and keep
     going. A drive-call error, timeout, slow read, or generic unreachability is NOT a daemon error:
     the daemon accepts `respond` immediately and runs the round in the background, so a killed or
     timed-out call was only waiting for a read while the run kept working.
   - The worktree pool your own worktree came from, and the repository every lane's worktree
     shares. Never create, remove, return, prune, move, or reassign a worktree or pool slot, and
     never write into a sibling slot's directory. Rule 2 does not cover this: removing a worktree
     is administration rather than an edit outside your directory, and it lands on lanes that are
     running right now. The act is the rule and commands are only examples of it - `treehouse`
     get/return/remove/prune, the equivalent operations on any other worktree provider or runtime
     backend, and `git worktree add|remove|move|prune`. A slot that looks unused is not evidence
     that it is free, and returning your own worktree is firstmate's job at cleanup, not yours.
   If you genuinely need a second checkout, another slot, or the daemon touched, append
   `blocked [at=<epoch>]: {what you need}` and stop; firstmate arranges it.

# Firstmate instruction inbox
Firstmate steers you through durable message files in '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.inbox'/NNN.msg '/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/.gate-review-lab-yeub5bi9/state/direct-pr-none.inbox'/handled/`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.

# Project memory
A project's `AGENTS.md` or `CLAUDE.md` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run `/home/tegris/.no-mistakes/worktrees/65cfe886f9df/01M49KKA9G4BTVR16V17MDQ3V1/bin/fm-ensure-agents-md.sh`, create either file, or add sections, headings, or pointers alongside it.

# Definition of done
Delivery contract: mode=direct-PR
Ship branch: fm/direct-pr-none
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
Perform exactly one code review round against the preparation outcomes and project standards using the existing review mechanism.
Record the reviewed head, findings and their resolution in the task report; fix the findings without another review round, then validate the final head through the selected delivery path's checks.
That round's finding list is the only one: never request a second review list, and record any finding you leave unfixed under the review follow-up rule as a follow-up item, never as fixed.
Do not commission a separate preparation review or add a second implementation review.
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
