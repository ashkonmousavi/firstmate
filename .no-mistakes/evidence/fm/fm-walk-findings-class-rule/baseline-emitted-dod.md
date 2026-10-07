# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/baseline
This task is complete only with an existing non-draft PR and every required check green for its current head.
After your implementation commit, append a `working [at=<epoch>]: implementation committed; starting validation` milestone and start the pipeline yourself immediately with `no-mistakes axi run`, supplying `--intent` under the contract below.
The pipeline owns the push; follow its version-matched skill and help to drive every gate through the green PR return.

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
Only a drive call's return reports the green PR: `no-mistakes axi status` shows progress but never reports `checks-passed` while the ci step is still monitoring the PR for merge, so never wait on a status poll for the next gate or outcome.
Whenever a drive call returns without a gate or an outcome - its own wait elapsed, or it was killed or timed out - reattach at once by re-running `no-mistakes axi run` without flags, backgrounded the same way; once checks are green it returns `checks-passed` immediately, and if it refuses because no run is active, read the finished outcome from `no-mistakes axi status`.
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


After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {full https URL from the forge} checks green` and stop. You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
Pending checks use `paused [at=<epoch>]: {checks awaited and completion condition}`; resume through the active pipeline when they finish, letting the pipeline own failed-check repairs.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.
