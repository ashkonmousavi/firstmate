# Walk evidence
When this task commissions an end-to-end user journey, follow the project walk procedure from the real user entry point through the intended result and its return or reopen step where applicable.
Before walking, verify the assigned actor, candidate and data, plus working Chrome DevTools or equivalent console, network and application diagnostics within the access this brief authorizes.
Record each step as the human expectation, actual observed result, pass/fail/not exercised, and evidence tied to that candidate; retain the first failing boundary and enough permitted diagnostics for its owner to investigate.
Source inspection and isolated checks support diagnosis but do not substitute for the walked result.
Unavailable setup or diagnostic access is a named gap with an owner and next action, never a successful walk or permission to sign in or change production.
# Rules
1. Never push with git and never create a change except through the one `gerrit-axi publish --squash` your Definition of done names. Never run `gerrit-axi submit`, never vote or review a change by any path, including `gerrit review` or a label option on a push, and never abandon one: a human reviewer approves and submits it on the server.
2. Stay inside this worktree; modify nothing outside it.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   `echo "{state} [at=<epoch>]: {one short line}" >> '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.status' && { [ ! -e '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/config/fleet-ledger' ] || '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/bin/fm-fleet-ledger.sh' appended '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/config' '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.status' >/dev/null 2>&1 || true; }`
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
   For a no-mistakes gate, escalate only stop-set findings as one event plus one snapshot file, using that same shape even when the gate holds only a single stop-set finding: write only the stop-set findings, verbatim and unparaphrased (id, severity, file, line, description, authority), naming the stop category, to `/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data/contract-no-mistakes-gerrit/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [at=<epoch>] [key=nm-<run>-<step>]: escalated findings=<id1>,<id2>,... file=/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data/contract-no-mistakes-gerrit/nm-<run>-findings.txt`
   naming every escalated finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
   Review follow-ups: count each distinct Review finding list once, by the `head_sha` in the drive return carrying its review gate, with
   `f='/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data/contract-no-mistakes-gerrit/nm-<run>-review-lists.txt'; if [ -s "$f" ]; then last=$(tail -c 1 "$f" && printf .) || exit 1; [ "$last" = $'\n.' ] || exit 1; fi; if [ ! -e "$f" ]; then printf '%s\n' '<head_sha>' >> "$f" || exit 1; elif grep -xF '<head_sha>' "$f" >/dev/null; then :; else [ "$?" -eq 1 ] && printf '%s\n' '<head_sha>' >> "$f" || exit 1; fi; wc -l < "$f"`
   which prints that list's ordinal only on success; on failure, stop and escalate instead of choosing a Review action.
   A review finding left unfixed when its review closes is a follow-up item, never a claimed fix: write each one verbatim and unparaphrased (id, severity, file, line, action, description) to `/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data/contract-no-mistakes-gerrit/review-followups-<review>.txt`, where `<review>` is the no-mistakes run id or `pr`, then file that file as one queued backlog item with
   `FM_DATA_OVERRIDE='/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data' '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/bin/fm-tasks-axi.sh' add --mint "review follow-ups: contract-no-mistakes-gerrit <review>" --body-file '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote's/data/contract-no-mistakes-gerrit/review-followups-<review>.txt'`
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
Firstmate steers you through durable message files in '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.inbox'.
When a terminal message says an instruction is waiting there - and at any natural checkpoint when you are unsure - list '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.inbox'/*.msg, read and act on each message in numeric order, then acknowledge each handled message by moving it: `mv '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.inbox'/NNN.msg '/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/.fm-contract-test-00gm1u8w/home with spaces and quote'\''s/state/contract-no-mistakes-gerrit.inbox'/handled/`.
The move IS the acknowledgement: without it firstmate rings again and eventually treats you as stuck. An empty or absent inbox needs no action.

# Project memory
A project's `AGENTS.md` or `CLAUDE.md` is loaded into every agent session in that project, so edit it only to correct information that is factually wrong - including information your own change made wrong - and never to add knowledge because it is missing.
A correction edits only the wrong text: do not run `/home/tegris/.no-mistakes/worktrees/825ef466523f/01M4A1DG2FKS344GNXF5BG88DG/bin/fm-ensure-agents-md.sh`, create either file, or add sections, headings, or pointers alongside it.

# Definition of done
Delivery contract: mode=no-mistakes forge=gerrit shape=squash
Ship branch: fm/contract-no-mistakes-gerrit
class fix: test fails without the fix; symptom seen twice.
This project's review server is Gerrit: it has no pull requests and no forge CI the pipeline can watch, so **no-mistakes runs here as a review pass that ends at a ready branch**, and you then publish that branch as one change.
Pass `--skip push,pr,ci` on every `no-mistakes axi run` for this task, and skip nothing else: `review`, `test`, `document`, and `lint` are the whole point of the run.
Those three are the only steps that reach a forge, and skipping them is a supported outcome, not a degraded one.
The task is complete only when committed on your branch.
When you believe it is complete, append `done [at=<epoch>]: {summary}` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate.
That first `done:` is the handoff that starts the pipeline; it is not a request to publish.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, pass `--intent` as only this brief's `## Captain's intent` subsection body, not its heading, plus any later words the captain actually said, plus, when your launch brief carries one, the preparation record's accepted specification appended after them exactly as that launch section says.
Preserve the actual words without adding speaker labels or direct address; the subsection heading supplies provenance outside the pipeline input.
For a legacy brief with no such subsection, include only words on lines marked `[captain] `, excluding that metadata prefix; never copy its mixed `# Task` wholesale.
If it has no provenance-marked captain words, stop and ask firstmate instead of starting no-mistakes.
Do not include `## Firstmate spec`, later Firstmate build constraints, or your own decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct roughly the same specification, without depending on a separate report, a PR, or context that lives only in this conversation.
When the captain's intent refers to a report, decision, or PR ("do items 1, 2, 3, and 7 of the report"), write the substance of the referenced items into `--intent` in the captain's terms, not only the pointer; that substance is the captain's ask by reference, while Firstmate's build instructions and your own decisions still stay out.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs; that advice does not apply to Firstmate-dispatched work.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call instead of sitting in one blocking hold your harness will kill, and read its return when it finishes.
Declare that wait using the brief's status-reporting rule before waiting on the backgrounded drive call.
Where a harness's own command limit is not established, assume it bounds commands and use that same backgrounded shape.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Review triage and class-fix handoff:
- The stop set is exactly a finding whose severity column is exactly error; a security, money or data-loss risk; or a product choice the accepted intent and record never settled.
  Severity is mechanical; judging the risks and unsettled choices is your responsibility. Escalate to firstmate using rule 6's stop-set format and stop until its exact decision arrives.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond`; an authorized fix carries the same class-inventory `--instructions` as the batch below. Never implement the fix yourself.
- Every other finding, ask-user ones included, is yours to batch-fix without a firstmate decision.
  Build each cause's class inventory read-only: reproduced cause, every affected occurrence, search scope and negative evidence. Select every non-stale finding being fixed in one response:
  `no-mistakes axi respond --step <step> --action fix --findings <every id being fixed> --instructions <inventory and guidance>`.
  The instructions must require the pipeline Fix step to record that inventory in retained run evidence before editing, then fix and test every occurrence in the cause class.
  They must require the next Review to check that exact retained inventory, verify every listed occurrence and regression evidence, and search for missed siblings; re-checks look at the fix rather than re-reviewing the whole change.
  Use the installed pipeline's existing evidence/configuration surfaces to demonstrate this handoff. Prompt delivery alone is not semantic success: if the next Review cannot consume the inventory, report that precise external gap as unverified rather than inventing a pipeline.
- A finding whose quoted code is already gone at the reviewed head is stale. Leave it out of the fix and record its id with file:line proof in the next status line or report; --instructions exists only with --action fix.
  For a gate containing both stop-set and other findings, keep the gate parked until the exact firstmate decision arrives, then use the installed help and proven gate semantics to select the authorized findings together; never guess how a singular action handles the remainder.
- A repeated finding returns in a later review of the same run: match the same id, or the same file and line and cause as a finding already fixed, including round-numbered ids.
  Skip a stale repeat with file:line proof. Batch-fix a still-real repeat outside the stop set again, and append `working [at=<epoch>]:` naming the run, step, repeated ids, inventory/evidence reference and exact respond command including its instructions.
  A repeat alone never authorizes needs-decision, a new captain question, hand-editing, abort or restart; only the last-list rule below ends fixing. The worker remains the sole driver of its run.
- The third distinct Review finding list is the last. Count lists with the review follow-up rule's ledger: a Review gate is a new list only when its drive return carries a `head_sha` not yet counted for this run, so a reattached read adds nothing, and internal auto-fix rounds that never park are not counted.
  The first and second lists are triaged and fixed as above. On the third, never respond `--action fix`: record every finding still listed under the review follow-up rule, then approve with `no-mistakes axi respond --step review --action approve` and append `working [at=<epoch>]:` naming the run, the list ordinal, the follow-up file and item id, and that its findings were deferred, not fixed.
  A stop-set finding on the third list still escalates under rule 6, stating it is the third list; the decision there is approve with recorded follow-ups or hold the run, never another fix.
  Approving Review ends only Review: Test, document, lint, push, PR and CI still run, and a protected-path or Test refusal still takes its explicit response; never get past them with `--yes`, a skip or a CI waiver.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, bypassing the stop-set authority boundary.


Because `push` is skipped, the pipeline's fixes DO NOT arrive in your checkout: each fix round commits onto a branch inside no-mistakes' own local gate repository, and with no push nothing carries those commits back to you.
Your tree never goes dirty and nothing interrupts you, so a passed run whose fixes are still in the gate looks exactly like a passed run whose fixes you already have.
You may not publish until you have closed that gap:
1. After the run reaches its outcome, read `branch_sync.next_action` from `no-mistakes axi status`.
2. When its code is `recover_custody`, run the exact command that status prints - `no-mistakes axi sync --recover` - and confirm `branch_sync.state` comes back `custody_returned` on a clean tree. The printed command is authoritative if it differs. The `run_pipeline` next action status reports after recovery is not an instruction to run again: the recovered head is the one the passed run validated, so publish it.
3. Confirm with `git log` that `fm/contract-no-mistakes-gerrit` now carries every fix commit the run made, whether or not step 2 was needed.
An unrecovered fix round is an unfinished task, never housekeeping: publishing without it is how the UNFIXED code reaches review.
Your ready report is refused while the run still holds your branch, while its outcome is missing or not passing, or while your HEAD's tree differs from the run's result.

When the run's outcome is passed, passed-with-skips, or passed-with-override and step 3 holds, publish.
The squashed change carries only the oldest commit's message, so the pipeline's own fix commits never reach the reviewer's description; your report is how they reach the captain.
After publishing and immediately before your ready report, append one line `note [at=<epoch>]: pipeline changes: {finding} - {fix it made}; {finding} - {fix it made}` to the status file, one short clause per finding the run fixed, taken from the run's `fixes` table and the gate findings its drive calls returned (`no-mistakes axi logs --step <step> --full` has the detail); write `note [at=<epoch>]: pipeline changes: none` when it fixed nothing.
Publish from this copy with `gerrit-axi`, never with `git push`:
1. Run `git fetch origin` so the server's branch tip is in this repository; `gerrit-axi` reads its base off the server and refuses when that tip is not here.
2. Run `gerrit-axi publish --squash --json`, adding `--branch <b>` only when the task names a target branch other than the server's default.
   It is one push to `refs/for/<branch>` that turns every commit since your branch left the server's branch into ONE change carrying the oldest commit's message, so that message is the review description: make it the one you want reviewed.
   It keeps any `Change-Id` a commit already carries and stamps one into the oldest commit when it has none, rewriting your local branch's messages only.
   Never edit, remove, or regenerate a `Change-Id`: a different one creates a different change and orphans the first one's review, while the same one adds a patch set to it.
   Never pass `--stack`: a stack of changes is not published from this fleet until it can be watched by its membership pinned when its watch is armed, and the watch follows exactly one change.
3. Read the record it prints: `ok` must be `true`, and the one row of its `changes` table is your change. Its `url` is the change URL; when `url` is null, write `https://<host>/c/<project>/+/<change>` from your `origin` remote's host and that row's `project` and `change`.
   A failure prints a typed error record instead; fix what it names and publish again, which updates the same change rather than creating another.
Then append `done [at=<epoch>]: PR {change url} published for review` to the status file and stop. You are finished.
That `done:` is accepted only when the change's current patch set on the server carries this copy's HEAD tree, so commit nothing after publishing; if you must change the work, commit it and publish again before reporting done.
A `done:` whose URL is not the canonical `https://<host>/c/<project>/+/<number>` change URL is refused.
There is no pull request, no `gh-axi` call, and no forge CI result to report: a human reviewer approves and submits the change on the server, and firstmate relays that outcome.
