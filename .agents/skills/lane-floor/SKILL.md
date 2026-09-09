---
name: lane-floor
description: >-
  Agent-only procedure for filling the fleet back to its lane floor.
  Use on any LANE FLOOR line, whether it comes from a wake drain or from a blocked turn end.
  Owns the order work is taken in, what a brief for an openspec Change must point at, and the memory bound that is the only legitimate reason to stop short of the floor.
user-invocable: false
metadata:
  internal: true
---

# lane-floor

A `LANE FLOOR` line means this home is running fewer PRODUCTIVE lanes than `config/lane-floor` while work is dispatchable without a captain decision.
That is a defect, not a status: the captain is paying for idle capacity.
Fill the fleet in this turn, before ending it.

A lane is productive when it is working, when a pipeline run is driving it, or when it is holding an actionable gate for its own task, read from that task's reconciled current state rather than from the newest line of its status log.
A lane that is waiting on something outside itself, whose agent has gone, or whose state could not be determined is not productive, and each of those is reported on its own.

The report names the numbers, accounts for every lane, and lists the work:

```
LANE FLOOR: productive=4 floor=10 dispatchable=17 - load the lane-floor skill and dispatch before ending this turn
LANES: total=9 gated=1 waiting=2 exited=2 unknown=1 finished=0 unreconciled=0
SLOTS: XAUUSD=20/20 firstmate=3/6
VALIDATION: waiting-for-slot=2 live-validation=1
  backlog xau-run-ledger-ceiling
  openspec XAUUSD:dashboard-v21-redesign-part5-comparison-view:6
```

`backlog <id>` is an item already in this home's queue.
`openspec <project>:<change>:<n>` is a Change under a registered project clone whose `tasks.md` still carries `n` unticked boxes and that no live worker's instructions name.

On the `LANES` line, `gated` is the subset of the productive count holding an actionable gate rather than computing, `waiting` is lanes declaring a bounded external wait, `exited` is agents gone or dead with their local copy kept, `unknown` is lanes whose state could not be determined, `finished` is terminal lanes still holding a slot, and `unreconciled` is lanes whose state could not be read at all and were therefore counted as productive rather than assumed idle.
A large `gated`, `waiting`, `exited`, `unknown`, or `unreconciled` number is itself the finding: those lanes hold slots without producing anything.
`SLOTS` is occupied worktree slots per project, so a full pool is visible before you try to dispatch into it.

## Capacity-blocked

```
LANE FLOOR: productive=1 floor=10 dispatchable=17 capacity-blocked cap=14 - load the lane-floor skill: release a lane below, or tell the captain what is holding them
LANES: total=14 gated=0 waiting=3 exited=9 unknown=1 finished=1 unreconciled=0
RELEASABLE:
  xau-rules-wording-batch-r18 (finished, nothing uncommitted)
```

This is the same shortfall with no room to dispatch into: the fleet is at its concurrency cap, so spawning is not the action and the line deliberately does not ask for one.
`RELEASABLE` names the lanes holding a slot with nothing uncommitted in their local copy - the only lanes a full home can free.
Confirm each one's work actually landed and clean it up through the ordinary teardown path, which owns that test and refuses rather than discarding anything; a refusal is a finding, never an obstacle to force past.
Then re-read the count: each released lane is one dispatch the ordinary procedure below can make.
`RELEASABLE: none` means nothing here can be freed - report the capacity blocker to the captain in that turn, naming the productive count, the floor, and what the lanes are holding.

## Procedure

Work the list until productive lanes reach the floor, or until the memory bound below stops you.
Validation concurrency and review serialization never lower the lane floor, and the memory bound below is the only dispatch limiter.
A lane preparing or proving locally while it waits for a validation slot is productive work, not an idle lane.

1. **The printed order is an enumeration, not a priority.** Dispatch in this order instead: first, actionable gates and repairs that unblock other work (shared machinery, supervision, delivery guards, validation tooling); second, the constituents of the next completed application outcome (what the current landing candidate or its immediate successor depends on); third, remaining capacity to useful independent work. Order within a class by actual dependency, never by batch number or list position. Backlog items still precede openspec lines within a class because they are already filed, already scoped, and already carry their delivery mode.
2. **For a `backlog` line, dispatch it.** Resolve delivery mode and merge posture at intake exactly as any other dispatch, write the brief, and spawn.
   An item whose hold you cannot dispatch under is one the enumeration should not have listed; a `captain` hold, and a still-unmet `external`, `parked`, or `future` hold, are already excluded, so a remaining blocker means the item's own note is wrong.
   Fix the note by recording the exact blocking rule on the item, and move to the next line rather than dispatching blind.
3. **For an `openspec` line, file a task first.** The Change is work the fleet has not tracked, so it has no item yet.
   File one with a title naming the Change, `repo` set to that project, and a note pointing at the Change's own `tasks.md` path.
4. **Point the brief at the authority, not at a copy.** The brief's intent names the Change and its `tasks.md` path as the task's own scope, and says to complete its unticked boxes under that project's current authority.
   Never transcribe the boxes into the brief: `tasks.md` moves while the worker runs, and a copied list goes stale the moment another lane ticks a box.
5. **Spawn, then re-read the count.** After each spawn the productive count rises by one; stop as soon as it reaches the floor.

Nothing here changes merge authority, delivery mode, or the captain-decision boundary.
A Change that turns out to need a captain call is filed and held `--kind captain` like any other, which removes it from the enumeration by its own record rather than by being skipped silently: the enumerator excludes an openspec Change whenever the Change's directory name or `tasks.md` path is named in the title or body of a backlog item that is held `captain`, held `external`/`parked`/`future` with its named event still unmet, or blocked by a still-open item, so the filed item's own wording is what keeps the Change out, not a side channel.

## The memory bound

A lane costs memory, and a host that swaps serves nobody.
Before each additional spawn, read the host's available memory and require at least 2 GB free per lane you are about to add:

```
free -g | awk '/^Mem:/ { print $7 }'
```

When that headroom is gone, stop spawning and report it to the captain in the same turn, naming the productive count, the floor, and the measured headroom.
A memory shortage is a real constraint the captain needs to know about; it is never a reason to go quiet.
Say plainly that the fleet is short of its floor because the machine is out of memory, not that the fleet is fine.

## What does not clear a breach

- Ending the turn. The turn-end block and the drain escalation both return.
- Re-reading the list. Nothing is dispatched by looking at it.
- Choosing which ready item runs first. That is ordinary engineering and needs no captain call. What stays the captain's is dropping, cancelling, or re-scoping an accepted requirement, and every genuine captain hold is preserved as recorded. A ready item passed over for a higher-priority one still carries a recorded reason, owner, and recheck trigger on the item itself (the wayfinding accounting), so a deprioritized item is never an unrecorded skip and the breach is not cleared by deprioritizing.
- A lane that is paused, gone, or unreadable. The count already excludes it, so replacing it is exactly the point.
- Reporting the buckets. Naming what the lanes are doing is not the same as filling the fleet or releasing a slot.
