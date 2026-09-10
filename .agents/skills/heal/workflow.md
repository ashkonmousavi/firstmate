# Heal workflow

This file owns the detailed `/heal` procedure, finding lifecycle, transition conditions, curation limits, and private-ledger operating rules.
The concise [SKILL.md](SKILL.md) owns discovery and routes here only after manual invocation.
`bin/fm-heal.sh` owns the mechanical record formats, verified-ownership check, safe publication, transition enforcement, index rebuild, checkpoint writes, and archive moves.

## Authority and ownership

Self-healing is investigation followed by authorized correction, verification, and record reconciliation.
A finding filed, a rule written, or an isolated passing test is an intermediate result.

With verified fleet-lock ownership, Firstmate may maintain this home's healing ledger and advance authorized repairs through existing owners and supported procedures.
The helper verifies ownership for every mutation and never acquires or recovers the lock.
The existing backlog, task, project, Change, release, merge, deployment, and acceptance records remain authoritative for scheduling and delivery.
The healing ledger references those owners and never becomes a second queue.

Preserve current task ownership, protected landing candidates, unlanded work, and independent application progress.
Use settled merge and deployment authority without asking the captain to repeat it.
Reserved spending, trading, destructive actions, unlanded-work disposal, security-sensitive work, and disruptive production actions remain independently governed.
Never alter existing supervisor notification, queue, presentation, or acknowledgement cursors.

## Read-only advisor mode

Without verified lock ownership, inspect only evidence already readable under existing authority.
Do not run any mutating `bin/fm-heal.sh` subcommand.
Do not initialize, edit, archive, rebuild, or checkpoint the ledger.
Do not acquire or recover the lock, start or steer workers, acknowledge queues, alter fleet state, or publish an advisory file unless a separate current instruction authorizes that exact output.

Return a prioritized chat recommendation with machine observation times and relevant project, task, run, commit, deployment, and runtime identities.
Separate facts, hypotheses, uncertainty, containment suggestions, and proof still needed.
State that the lock-owning Firstmate must refresh volatile evidence before acting because an advisory report is not authority.

## Private ledger

Resolve the operational home from `FM_HOME`, falling back only through the repository's established Firstmate-root behavior.
Resolve instructions and `bin/fm-heal.sh` from the tracked code root, not from the private home.
Create `$FM_HOME/data/heal/` lazily on the first lock-owning invocation.

`README.md` is a navigation pointer only.
`INDEX.md` is a rebuildable current view.
`checkpoint.json` records only the healing scan's own source identities and progress.
`findings/<stable-id>.md` is the authoritative current record.
`archive/YYYY-MM/<stable-id>.md` holds recoverable closed history.
`indexes/` may hold complete compact unresolved lists only when the current priority view overflows.

Keep private projects, incidents, paths, and evidence out of tracked skill files.
Do not store secret values.
Do not copy full logs, transcripts, screenshots, or artifacts when a small extract or link to the existing evidence owner is sufficient.
Preserve volatile evidence through its existing owner or as the smallest relevant extract.

One finding has one stable ID, one cause-oriented fingerprint, and one authoritative record.
Check current findings first and use targeted `bin/fm-heal.sh lookup <term>` when component or symptom metadata suggests recurrence.
The helper refuses a second record with an existing ID or fingerprint and returns the surviving record and owner.
Similar symptoms alone do not prove a shared cause.

Use `bin/fm-heal.sh observe` for notifications and occurrences.
One independently identified incident increments the occurrence count once, while repeated notices increment only the notification count.
Use `bin/fm-heal.sh verify` only when the existing current account still matches the evidence and no recurrence was found; verification never reopens a closed record.
Changed ownership, configuration, release conditions, or remaining work require refreshing the account, not merely appending a verification line.
New occurrence evidence against an archived closed record restores the same ID as Open.

To refresh a finding, copy the complete record to a private temporary candidate and rewrite its current account without changing the copied JSON metadata.
Use `bin/fm-heal.sh publish` to publish that account together with refreshed triage fields and observation evidence; the script's header owns the flags.
The helper refuses unfinished template instructions and a candidate whose original metadata no longer matches the record.
Keep material evidence and history, but replace obsolete current instructions instead of appending their corrections underneath them.
Use `transition` for lifecycle changes; updating the current owner or next action does not require an artificial state transition.
The helper records observations and checks their structure; it cannot establish that a claimed cause, owner, or successful journey is true.

Each current record must keep these facts concise and current:

- Affected component, observed problem, and consequence.
- Facts, hypotheses, uncertainty, and the cheapest disconfirming observation.
- Machine-derived first-observed, latest-occurrence, and last-verification times.
- Representative evidence and relevant code, task, run, delivery, and runtime identities.
- Established contributing cause or the specific unresolved diagnostic question.
- Existing owner and authoritative task or Change pointers.
- Containment, selected correction, next action, and release or recheck condition.
- Required proof, results, and what remains unverified.
- Lifecycle state, closure disposition when closed, and closure evidence.
- A short history of material changes in understanding.

Before acting on a promoted finding, reconcile its current account against the actual task, effective brief, implementation, consuming configuration and latest proof.
Replace a retired owner, an already-completed next action, or a cleared release trigger with the current responsible owner and remaining work.
State what the next action unblocks and the observation that will settle it; if no repair is needed, record the evidenced disposition instead.
An index refresh notice is a reading aid, never a fleet, merge, or application gate.
Refresh only the records needed for this pass's decisions; leave other unresolved records discoverable without delaying delivery to tidy them all.

## Finding lifecycle

The lifecycle has exactly five states.
Severity, blocking reason, closure disposition, evidence freshness, task state, and run state are separate facts.

- `Open` means recorded and awaiting triage, or ready work deliberately not active now.
- `Active` means an identified owner is investigating or implementing the correction.
- `Blocked` means the necessary next step cannot proceed and its reason, owner, and release trigger are explicit.
- `Unverified` means a concrete correction exists but required delivery or consuming-workflow proof is incomplete.
- `Closed` means the finding has an evidenced final disposition.

### Transition table

| From | Permitted next state | Required condition |
| --- | --- | --- |
| Open | Active | An existing owner is actively investigating or repairing. |
| Open | Blocked | The blocking reason, owner, and release trigger are explicit. |
| Open | Closed | A valid closure disposition and its required evidence are recorded. |
| Active | Open | Reprioritization records a next action or reactivation trigger. |
| Active | Blocked | The blocking reason, owner, and release trigger are explicit. |
| Active | Unverified | A concrete correction and the remaining proof are identified. |
| Active | Closed | A valid closure disposition and its required evidence are recorded. |
| Blocked | Open | The changed condition or disposition and next action are established. |
| Blocked | Active | The owner can act because the release condition has cleared. |
| Blocked | Unverified | A correction exists and the remaining proof is identified. |
| Blocked | Closed | A valid final disposition and its evidence are established. |
| Unverified | Active | Verification showed that further repair is needed. |
| Unverified | Blocked | Necessary proof cannot proceed and its release trigger is explicit. |
| Unverified | Closed | The selected closure disposition's evidence conditions hold. |
| Closed | Open | New evidence demonstrates recurrence or invalidates the prior closure. |

Every transition outside this table is refused.
Do not force a finding through every state.
Use `bin/fm-heal.sh transition` so the table and state-specific requirements are enforced mechanically.

Closure dispositions are distinct from lifecycle state:

- `Fixed` requires the correction, normal authorized behavior, and consuming-workflow proof.
- `Disproved` requires evidence that the reported premise is false.
- `Duplicate` or `Superseded` requires a surviving finding or owner that preserves the unresolved obligation.
- `Captain-authorized-scope` cites the specific captain decision and is never represented as a successful repair.

Unknown evidence never implies completion or inactivity.
A correction on a branch, absent from its consuming runtime, or lacking its required consuming proof remains Unverified.
When new evidence shows the correction is ineffective, move Unverified back to Active through the existing repair owner, or to Blocked only for a current concrete obstacle.
Inspect the effective consumer and its configuration before repeating an installation or commissioning another implementation of an already-built fix.
A legitimate hold and an ownerless accepted obligation retain different classifications.
Derive permitted actions from current evidence and authority, never from a label alone.

## Invocation flow

### 1. Direction first

Before any failure inventory, name the next complete application outcome from the project's own authority: its roadmap, open Changes, and the captain's standing instructions in `data/captain.md`.
Identify the current captain intent, applicable authority, active repair owners, protected landing candidate, and reserved operational windows.

For every live assignment relevant to that outcome, compare its effective brief (`data/<id>/brief.md`) against the task body, the hold reason, and the owning specification, and record whether the brief actually delivers the outcome.
A disagreement between them is a finding classified `neglected-obligation`; its repair is rewriting the instruction at its owning source, reclassifying the task, and verifying the worker consumed the correction, not merely filing the finding.

Question stale holds and apparent completion rather than accepting either at face value.
A hold is stale when its recorded blocking reason no longer matches current records; reopen or reclassify it.
Distinguish the task's bounded deliverable from the complete application outcome it supports.
Check the full chain of requirement, owning specification, effective brief, implementation and consumers, integration, deployment and user evidence before calling that application outcome complete.
A constituent task may close under its existing delivery contract once its own required proof is complete and any remaining integration or journey obligation has a durable owner and release trigger.
Reopen a task only for an unmet obligation it owns, not merely because a downstream task is unfinished; never keep its worker or worktree alive solely to represent downstream work.

Default to evidence since the previous completed pass plus every unresolved carry-forward.
On the first pass, use a bounded recent window of roughly four hours unless `$ARGUMENTS` supplies another clear window.
Treat pasted transcripts, old reports, remembered counts, and previous assurances as claims until refreshed.

Bound the pass from here: prioritize promptly (step 5), normally deepen only the highest-impact one to three investigations (curation budgets below), advance repairs through normal supervision, and never freeze independent application progress.

Begin an incomplete scan with `checkpoint-begin` and a unique scan ID.
Name each authoritative source by a stable source ID and immutable or rotation-aware identity.
Include the outcome authority and effective assignments actually checked in Direction first, plus the consuming evidence used for promoted findings; an event-log scan alone does not establish direction or completion.
Do not reuse existing supervisor notification or queue cursors.

### 2. Contain active harm

Address evidenced threats to work, runtime stability, or delivery first through the smallest authorized action.
Identify the exact process, task, isolated copy, runtime, and resources before acting.
Preserve recoverability and keep unaffected application delivery moving.
Containment does not close the underlying cause.
Measure resource behavior because full swap alone does not prove current pressure and open lanes do not prove productive concurrency.

### 3. Check obligations and delivery links lightly

Direction first already deepened the outcome-relevant assignments; broaden the same questioning lightly across the rest of current obligations.
Use current controlling requirements, ownership records, application paths, and operational paths.
Look for missing ownership, stale instructions, unsupported completion claims, actual gates, unreliable worker state, duplicate work, unjustified holds, over-broad dependencies, recurring resource or environment failures, repeated verification or landing friction, absorbed-work gaps, incomplete operator journeys, missing consumers, and inconsistent identities or timestamps.
Account for unfinished accepted obligations whose original task closed.
An adopted architecture, installed library, design record, test name, passing branch, or passing isolated test does not prove a working consumer or matching deployment.
Deepen only on observed discrepancies rather than auditing every historical file.

### 4. Diagnose

Load and apply the existing `diagnostic-reasoning` owner for causal work.
Separate visible symptom, initiating trigger, and masking conditions.
Compare failing and proven paths and seek the cheapest evidence that could disprove the leading explanation.
A worker mistake, weak-model claim, or memory warning is not a sufficient cause.
If repeated repairs fail, reopen the explanation and repair boundary.

Persist a new or changed finding before advancing the checkpoint for the source that produced it.
Then record the source identity, cursor, and read time with `checkpoint-source`.

### 5. Prioritize

Prioritize active harm, then confirmed shared causes blocking important work, then the next complete operator outcome, then other useful independent work.
Explain what each promoted repair protects or unblocks.
Select at most the normal one to three investigations by current impact and readiness, not the index's severity/state ordering or the age of a dramatic title.
An active correction that releases several important consumers normally precedes an already-contained incident or minor record cleanup.
Prefer a small correction that releases several consumers over broad cleanup.
Keep deferred accepted work with its owner and release or recheck condition.
Do not manufacture scores, findings, tasks, or wasted-time estimates.

### 6. Challenge friction and repair the source

For a delaying rule, establish the failure it protects against, whether an existing check already provides that protection, the measured delay or rework, and the smallest supported simplification that preserves necessary safety.
Correct obsolete Firstmate-written rules at their owning source within existing authority.
Bring genuinely reserved changes to the captain as one concrete proposal.
Do not weaken accepted behavior, discard work, bypass combined-code proof, or preserve redundant process merely because it is written down.

Amend an existing owner's instructions before filing a new task.
Parallelize independent repairs only within measured capacity.
A dependency blocks only the step that requires it.
When a release trigger slips or a repair recurs, reassess the hold and its owner instead of repeating the same waiting instruction.
Coordinate mutable joins and final landing windows through their existing owners.
Repair the source mechanism and give every temporary workaround an owner and removal condition.
Reporting alone is not execution.

### 7. Prove and close

A repair is proven only by four recorded facts on the finding: the original failure detected, the correction made at its owning source, the correction consumed by the worker or runtime, and the intended application work resumed.
A green isolated test, a filed task, or a notebook entry alone is not a repair; record all four facts in the finding's existing prose fields rather than treating any one of them as sufficient.
Substantiate the original failure, show that the correction addresses it, prove normal authorized behavior, prove the actual consumer uses it, and show the blocked work or affected operator journey proceeds.
For guards, prove both intended refusals and authorized operations.
For runtime repairs, distinguish isolated behavior from activation in the real tool and environment.
For application work, distinguish branch tests, merged code, matching deployment, and user evidence.
Close a finding against the specific failure it records, while leaving broader application obligations with their existing owners.
For an assignment defect, a corrected effective brief, verified worker consumption and resumed intended work can prove the assignment repair; they do not prove the resulting application feature is deployed or accepted.
For a runtime defect, an installed binary is insufficient when the actual consuming configuration bypasses or disables its repair.

Carry eligible work through commit, required checks and review, authorized merge, activation or deployment, affected journey, and safe cleanup through existing owners.
Preserve unlanded work and bind absorbed work correctly.
Use machine timestamps and preserve meaningful age across renamed or successor tasks.
Absence of another incident is not proof that a recurring cause was eliminated.

### 8. Curate and continue

Rewrite the promoted findings' current summaries from new evidence, reconcile owners and release triggers, rebuild the index, and archive eligible closures.
Record scan completion only after every expected source identity exactly matches the sources safely preserved in the checkpoint.
Missing, unreadable, rotated, or truncated input keeps the scan incomplete with the gap stated.
A diagnostic pass may finish while repairs continue through normal supervision, but pending proof remains visible with an owner and observation trigger.

Lead the outcome with material change and what it unblocked.
Suppress unchanged narration.
Report verified repairs, containment, ongoing work, coverage gaps, owners and triggers, the next application outcome, and only genuine captain decisions.
For each promoted repair, state the action actually taken or the concrete blocker and next observation; a filed finding alone is not reported as healing.

## Checkpoint and interruption rules

Use `checkpoint-begin` before scanning and leave it incomplete during work.
Use one `checkpoint-source` write only after the corresponding findings are safely present.
Use `checkpoint-complete` with every expected `SOURCE=IDENTITY` binding.
The helper refuses completion if recorded and expected source identities differ.

Repeated `checkpoint-begin` for the same incomplete scan preserves source progress when the window and start identity match.
Beginning a different scan preserves the prior incomplete record under a timestamped `checkpoint.incomplete.*.json` name before publishing the fresh checkpoint.
A missing checkpoint means no prior scan completion is known.
A corrupt checkpoint is preserved under a timestamped `checkpoint.corrupt.*.json` name before a fresh incomplete record is created.
Never infer completion from an incomplete or unreadable checkpoint.

A missing or malformed index is rebuilt from finding records.
A malformed finding remains named as damaged and is not treated as resolved.
Repeated invocation reconciles active repairs and repeated event keys instead of duplicating them.
Never recursively invoke `/heal` to repair `/heal`.

## Curation and reading budgets

Aim for roughly 2,000 estimated tokens in the initial index and checkpoint view.
Normally deepen the highest-impact one to three findings per pass.
Keep a current finding explanation near 600 words or less and link detailed proof.
Keep only a few recently closed outcomes in the current index.
These are attention budgets, not delivery gates or permission to lose information.

Every unresolved finding remains discoverable.
When the priority view overflows, rebuild it with an explicit unresolved count and links to complete compact unresolved indexes.
Never silently omit overflow.
An unresolved finding never expires from age, lack of reinforcement, or budget pressure.

Archive only an evidenced closure or an explicit supersession with a surviving owner.
Archive under the closure month while preserving stable identity, disposition, and evidence pointers.
Search archive metadata only when the component, fingerprint, or symptom suggests recurrence.
Deleting unique history is not normal curation.
Rewrite current summaries instead of appending a pass diary.

The healing ledger is excluded from automatic startup memory and the startup digest.
Proven general lessons go to their existing owning source through normal write and review rules.
Do not copy `/stow` migration, decay-counter, cascade, or budget-escalation machinery.
Housekeeping never interrupts important delivery.

Aim to produce an initial triage in roughly ten minutes, as a progress checkpoint rather than a worker timeout.
Avoid automatic full-suite runs, indexing, cloud reviews, extra advisors, and heavy services unless a specific question requires them.
Measure problems resolved, consumers unblocked, recurrence addressed, and investigation effort rather than finding counts or new rules.
