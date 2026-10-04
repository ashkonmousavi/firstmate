# Task
## Captain's intent
Check the marker only.

## Firstmate spec
Investigate the isolated marker.


# Current ship Firstmate spec
If these promotion steps were already completed before a relaunch, preserve the existing `fm/promotion-no-mistakes` branch and continue from its current state; do not repeat them destructively.
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/promotion-no-mistakes --`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. Treat the scout-time Firstmate spec and any unmarked legacy `# Task` text as investigation context, not captain intent or current ship-time instructions.
7. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including the stop set; and every safety rule, except where the current delivery contract below explicitly replaces scout-only delivery rules.


# Current delivery mode contract
This task is now kind=ship with mode=no-mistakes.
This section supersedes every earlier brief instruction about delivery mode.
These current ship instructions supersede the scout delivery rules and report-based Definition of done.
Any earlier "Never push" or scout-only delivery language in this file is superseded.
The mode-specific Definition of done below is the current delivery contract.

# Current ship safety rule
1. Never push to the default branch. Never merge a PR.

The no-mistakes stop-set escalation below supersedes the scout rule 6 escalation shape.
   For a no-mistakes gate, escalate only stop-set findings as one event plus one snapshot file, using that same shape even when the gate holds only a single stop-set finding: write only the stop-set findings, verbatim and unparaphrased (id, severity, file, line, description, authority), naming the stop category, to `/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M42JD1EGCXV3KJW39JC23GXS/.live-preparation-wtyw01wl/data/promotion-no-mistakes/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [at=<epoch>] [key=nm-<run>-<step>]: escalated findings=<id1>,<id2>,... file=/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M42JD1EGCXV3KJW39JC23GXS/.live-preparation-wtyw01wl/data/promotion-no-mistakes/nm-<run>-findings.txt`
   naming every escalated finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.

# Definition of done
Delivery contract: mode=no-mistakes
Ship branch: fm/promotion-no-mistakes
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
  A repeat alone never authorizes needs-decision, a new captain question, hand-editing, abort, restart or a round cap. The worker remains the sole driver of its run.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, bypassing the stop-set authority boundary.


After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), read the PR back from the forge and confirm it is not a draft (`gh-axi pr view <number>` must print `draft: no`, where <number> is the PR number from your PR URL); if it is a draft, mark it ready with `gh-axi pr ready <number>`.
A draft cannot be merged, so a done report on one leaves the merge unasked.
Then append `done [at=<epoch>]: PR {full https URL from the forge} checks green` and stop. You are finished.
That CI-ready `done:` is accepted only when this copy's HEAD - your latest commit - is one the /no-mistakes run pushed, so commit nothing after the run; the check tests that commit, not merely that a branch moved.
Pending checks use `paused [at=<epoch>]: {checks awaited and completion condition}`; resume through the active pipeline when they finish, letting the pipeline own failed-check repairs.
If you deliberately keep the PR a draft, append `paused [at=<epoch>]: {why the draft is held}` instead of done.

# Task preparation record
This task has a preparation record at `/home/tegris/.no-mistakes/worktrees/befb827bbae4/01M42JD1EGCXV3KJW39JC23GXS/.live-preparation-wtyw01wl/data/promotion-no-mistakes/prep.md`.
Read it in full before you plan or write anything: it is the specification beneath this brief, and it supersedes your own reconstruction of what the change should do.
Its `## Tier` header decides how much the record says; a section it does not carry was ruled out there, not forgotten.
Builders and post-implementation verifiers use `## Expected outcomes and how to check each` as the same explicit acceptance list, alongside the applicable `## 2. Behaviour spec`, `## 11. Definition of done` and `## Captain's intent` above.
Check each outcome row with its named command/public seam or screen and region and expected value, and report actual evidence and unproven claims without promoting fixture proof into real launch or installed proof.
A section answered `n/a: <reason>` is a decision already taken, not an invitation to fill the gap yourself.
Write the tests named in Tests before their passing code, one slice at a time at the named public seams.
If the record is wrong or incomplete for what you find in the code, say so through the status file rather than silently building something else.

# Current no-mistakes intent contract
This section supersedes every earlier brief instruction about constructing `--intent`, but not later clarifications actually supplied by the captain.
Use everything under `## Captain intent authorized for --intent` through the end of this brief, including any nested subheadings but excluding that heading, plus any later words the captain actually supplied as `--intent`; never include Firstmate specification or other mixed Task content.
Preserve those words without adding speaker labels or direct address.
Firstmate-authored constraints, acceptance criteria, implementation details, decisions, and tradeoffs are specification, not captain intent.
The Definition of done's rule that `--intent` must be self-sufficient still governs the string you pass: resolve any report, decision, or PR the intent below refers to into its substance rather than passing the pointer.
The one addition is the accepted specification below, from this task's complete preparation record: after the captain's words, add a blank line, then the line `Accepted specification from the preparation record (not the captain's words):`, then every heading and body under `## Accepted specification for --intent (preparation record, not the captain's words)` exactly as written, so the review checks the work against what the record promised.
It is specification, not captain intent; `## Firstmate spec`, later Firstmate constraints, and your own decisions and tradeoffs still stay out.

## Accepted specification for --intent (preparation record, not the captain's words)
## Expected outcomes and how to check each
| Outcome | Exact observable result | Where and how to check | Expected value |
| --- | --- | --- | --- |
| Marker selection | Only the marker line is selected | `grep -F '<!-- marker -->' output.html` | \<!-- marker --> |

## 2. Behaviour spec
### Marker check
    grep -F '<!-- marker -->' output.html

## 11. Definition of done
### Marker check
	grep -F '<!-- marker -->' output.html

## Captain intent authorized for --intent
Check the marker only.
