---
name: wayfinding
description: >-
  Agent-only judgment for designing and sequencing multi-task work: a stage, a release, a migration, or any campaign larger than one task.
  Use before scoping such work, and before dispatching a task whose backlog dependency names a stage, a release, or a final acceptance.
  Also use when work is blocked only at its final step or the queue looks fully gated, to find the work that can still be pre-staged, and whenever the ready frontier lists only umbrellas or nothing while holds still exist.
  Owns the destination and completion boundary, the plan-versus-build boundary, the unknown-classification split, the retained tracer, vertical outcomes, integration ownership, the ownership-and-sequencing shape of a parallel split, new-request classification, pre-staging around a blocked final step, the frontier-reset expansion of a stalled queue, the proof ladder, and the named-dependency reconciliation that must happen before dispatch.
user-invocable: false
metadata:
  internal: true
---

# wayfinding

Load this when the work in front of you is larger than one task: a stage, a release, a migration, a rewrite, or a campaign of related changes.
It is project-neutral judgment about where the work is going and in what order it should arrive.
It is not a planning system: no tracker, scheduler, ledger, policy engine, or completion database comes out of it, and nothing here fixes which model or harness fills any role.

Ordinary single-task work does not need this skill when none of its explicit triggers applies: it has no stage, release, or final-acceptance dependency to reconcile and is not blocked only at its final step.
When either trigger applies, load this skill for a single task and perform the named-dependency reconciliation or pre-staging judgment that triggered it.
`AGENTS.md` section 7 already owns per-task intake, delivery mode, dispatch, and merge authority, and section 8 owns supervision; a triggered single task does not inherit tracer, vertical-outcome, or frontier-dispatch machinery, and this skill otherwise adds only what sequencing multiple tasks needs without restating those contracts.

## This skill plans; it does not build

Wayfinding produces decisions and an order of work, never deliverables.
The pull to just start building is the signal that the route is already clear enough, which means this skill is finished and the work belongs in ordinary tasks under section 7.
Hand off at that point rather than carrying execution into the planning.

Never grant yourself the exemption.
The external method this is adapted from allows an effort to override the boundary in its own notes, and the reported failure is exactly what that permits: an agent wrote the override into the notes it owned and read it back later as its own authority to build.
Here the override is the captain's word for a named piece of work, in the moment, and nothing an agent writes to a record becomes authority by being read again.

## Name the destination before designing the route

State the destination and its completion boundary before decomposing anything: what is true when this is done, and what is explicitly not in it.
Work without a stated completion boundary expands until something else stops it, and every later "is this in scope" question resolves by whoever is asked.

Scope the destination to one bounded outcome, not to the whole product.
A long plan invalidates itself: the reported failure mode is a route whose later half stopped making sense once its earlier half was actually resolved, because every later step rested on assumptions the earlier ones changed.
Prefer resolving uncertainty with cheap concrete artifacts over planning further past it, and stop planning at the point where the next real slice would teach you more than the next planned step would.

Then classify each unknown, because each takes a different route:

- **Operator decision** - the captain's call.
  Ask it; do not research it or prototype around it.
- **Bounded research** - a selection among candidates.
  Route it through `research-first-decisions`.
- **Disposable prototype** - a question answerable by building something you will throw away.
  Say up front it is disposable, and throw it away.
  Where the question is how something should look or behave, building the options is the work and choosing between them is the captain's; presenting several and picking one yourself answers a question that was never yours.
- **Blocking chore** - nothing to decide, but manual work stands in front of the decision: an account to open before its interface can be judged, access to provision, data to move before its shape can be seen.
  It is the only one of these that does rather than decides, and it earns its place by unblocking a decision, never by delivering a piece of the destination.
  Do it where you can, otherwise hand the captain a precise checklist, and record the facts it produced that later work depends on.
- **Genuine fog** - not yet answerable.
  Design so the first real slice reduces it, rather than planning past it.

Misclassifying fog as a decision produces a confident wrong answer; misclassifying a decision as fog produces a scout nobody needed.
A blocking chore mistaken for a slice of the build is how planning turns into building without anyone deciding to.

## Tracer first, then vertical outcomes

The first slice is a tracer: the smallest **retained, production-quality** path end to end through a real entry point, the core behavior, a durable record, and an observable result.
Retained and production-quality are the load-bearing words.
A tracer that is thrown away proves the route existed once; a tracer that is kept becomes the spine every later slice attaches to, and it surfaces integration problems while they are still cheap.
For an application with several destinations or pages, the tracer is its navigation and the shared structure every later piece attaches to.

After the tracer, decompose into vertical outcomes, not layer lanes.
A vertical outcome is independently landable and independently observable.
Backend, frontend, test, and documentation lanes are not outcomes: each lands nothing on its own, and every one of them defers integration risk to the end, where it is most expensive and least reversible.

Give an unstable or shared contract, or a head several slices build on, exactly one integration owner.
Multiple owners of one contract produce divergence that only appears at merge.

## Dispatching the frontier

The frontier is the set of nodes whose dependencies have cleared.
Recompute it whenever the graph changes: `AGENTS.md` section 10 owns when that happens after a teardown or heartbeat, and section 7 owns how many independent nodes may go at once and when to serialize.
Do not restate either here, and never set how many lanes go at once or a cap those sections do not impose.
That limit is about the count, not the shape: how the split is shaped and ordered is this skill's own to state.

Building in parallel stays the default here for disjoint work, and that is deliberate.
The external method this is adapted from recommends one thing at a time, because two live sessions planning the same effort re-ask each other questions they cannot see the answers to.
That cost is real for decisions and absent for building: every dispatched task carries a zero-memory brief and an isolated copy, so two builders share no context to lose.
That zero-shared-context argument holds only when builders touch disjoint files; parallel builders on one shared head make conflicting implicit decisions that surface at merge, so many lanes on one journey or page pay the cost of parallelism without its benefit.
Parallelize by area under section 7, one lane per area at a time, owning its files.
An area's slices queue behind it, and finished work across every area merges one at a time in dependency order.
Every shared module is held by its single integration owner, which a lane asks rather than edits.
Keep decisions on one shared record so a second lane never resolves what a first lane already settled.

What this skill adds is the accounting:

- A node that is ready but not dispatched carries a recorded reason, an owner, and a recheck trigger.
  Ready-but-idle with no recorded reason is indistinguishable from forgotten, and that is how a frontier quietly stalls.
- Distinguish only the states that change a dispatch decision: work executing, work ready but idle, work waiting on a durable blocker, and work complete but not yet integrated.
  "Complete but not yet integrated" is the one most often mistaken for done; unlanded work is not delivered.
  Use the existing status and backlog vocabulary for everything else rather than importing a second parallel set of labels.
- Every dispatched task's brief must stand alone as a zero-memory packet.
  The worker starts fresh and may be compacted mid-task, so a brief that leans on conversation context has no context to lean on.

Classify each new request that arrives while work is under way as **replace**, **preempt**, **parallel**, or **wait**, and say which.
An unclassified new request defaults to preempt in practice, because it is the thing most recently said.

### Frontier reset

When the ready frontier lists only umbrellas or nothing while holds still exist, expand the umbrella that same turn into concrete items filed from the project's own open records: ROADMAP rows, openspec `tasks.md` boxes, or decision records.
Evaluate every hold against those same records - the project's ROADMAP, its openspec `tasks.md`, and this home's `data/done-archive.md` - rather than against the hold's own remembered text.
Release a hold that record shows has cleared, or re-hold it with a concrete event or date; never carry a hold's text forward unchanged past the condition it named.
Resolve a dependency against this home's `data/done-archive.md` plus the project's ROADMAP and openspec `tasks.md`, never against whether an id is still visible in `data/backlog.md`, whose retention rule (section 10) prunes closed entries regardless of whether the dependency they named actually closed.

## Pre-staging: a blocker gates its step, not the task

A blocker gates only the step it actually blocks, never the whole task.
Pre-stage useful research, specifications, interfaces, fixtures, page-specific implementation, and focused tests.
Multiple prepared branches may await one dependency, but they must not independently redefine the same unstable shared contract or integration seam.
Record the integration owner, order, trigger, recheck duty, and invalidation condition.
When the dependency lands, integrate prepared consumers before extending that chain further.

Write every placeholder as the exact token `FINALIZE-AFTER(<trigger>): <what>`, inline where the value belongs.
One search, `grep -rn 'FINALIZE-AFTER('`, then finds every open placeholder with its trigger already beside it, so no separate index of pending work exists to drift out of date.

Two rules enforce it, and both are yours to run because no script checks them:

- Consuming any prepared artifact BEGINS by grepping the sentinel and resolving every hit whose trigger has landed.
- Delivered or landed material contains zero unresolved sentinels.
  Grep the branch before reporting a task ready, and name that check in the brief of any task that pre-stages, so the worker runs it rather than remembering it.

When the queue looks fully gated, enumerate what can be pre-staged before accepting that nothing can proceed.
"Everything is blocked" is usually "every final step is blocked", and the preparation standing behind those final steps is independent and useful anyway.
Start those pieces.

## Named dependencies reconcile before dispatch

A backlog dependency that names a stage, a release, or a final acceptance is a claim about another system's state, and claims go stale.
Before dispatching such an item, reconcile it against the project's official main and its current completion authority: confirm from that project's own authority that the named thing actually closed there, not from a status line, a summary, a report, or the memory of it closing.
A trailing commit id on an openspec `tasks.md` checkbox is that box's own evidence citation, never the Change's landing commit - check a Change's dependency against the project's main line itself, a merged PR or a landed sha there, not against an id quoted inside its task list.
Dispatching on a stale named dependency puts a worker on a base that the thing it was waiting for has since moved.

## Proof at the right boundary

Match proof to what changed, and stop paying for more:

- Direct proof of the affected behavior, on every change.
- The integrated journey, once a complete slice exists: the predefined per-role browser journey run end to end in the deployed-posture mirror, with a screenshot at each meaningful result step and every error captured and dispositioned.
- Broader acceptance at a capability, release, or stage boundary.
- Exact-head CI at delivery, which the selected delivery path already owns.

Running stage-boundary acceptance on every slice buys confidence already bought; running none until the end buys none when it is still affordable.

Synthetic or controlled evidence, evidence from a real admitted-data mirror, and evidence from the actual deployment are three separate classes.
None is ever promoted into another, and a claim rests only on the class that actually produced it.

## Recording decisions

Record a material decision concisely: what was decided, what it turned on, and what would reverse it.
Do not attach a reasoning transcript; the reasoning that mattered is the part that would change the decision if it were wrong.
Route anything durable per `AGENTS.md` section 6 rather than leaving it in a task note.

When a decision you already recorded turns out to be wrong, reopen it.
The instinct is to design around it instead, which buries the mistake under the work built on top of it and makes it more expensive with every slice.
Say plainly what changed, correct the affected records in the same step, and never build onward against a route known to be wrong.
