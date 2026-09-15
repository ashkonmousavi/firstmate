# Delivered wayfinding skill: dispatch and parallel-split guidance

Read through the path the Claude Code skill loader uses in this project: `.claude/skills -> ../.agents/skills`.
Frontmatter parses as YAML (name=wayfinding, user-invocable=false, description 932 characters). The skill loader itself was not driven in this run.

Delivered frontmatter:

```yaml
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

```

Delivered dispatch/parallel-split body (lines 62-92):

```
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
```
