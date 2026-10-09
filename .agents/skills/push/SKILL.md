---
name: push
description: >-
  Take over the live Firstmate fleet for one bounded pass when the captain invokes /push, $push, or asks to check and push the fleet forward, during a tangle, as reinforcement, or as a routine check against waste.
  Map every tangle to its one cause from live evidence, untangle by hand where the machinery refuses, judge every rule or gate that cost time, correct the work sequence and method on every machine, sequence ready work within admitted capacity, and report outcomes in minutes saved in Captain Signal v2 style.
user-invocable: true
metadata:
  internal: true
---

# push

Take over the fleet for one bounded pass, the way a hands-on operator would: find exactly where work is tangled, untangle it by hand where the machinery refuses, and leave every lane doing the right work, in the right order, by the right method.
The pass is the same whether it is called during a tangle, as reinforcement, or as a routine push to catch waste.
It is judged in minutes saved, because the fleet loses hours to machinery (a refusing installer, a queue switched on before its proof, a protection rule that blocks every merge, a long preparation gate on a small change, backlog items pointing at merged PRs, a top priority with no lane) more often than to code, and the captain treats lost time as the real loss.

## Gather

Confirm this home has completed the session-start digest and holds its required lock before any fleet mutation, as `AGENTS.md` section 3 requires.
Drain the durable wake queue first unless the session-start digest already presented it, as `AGENTS.md` section 8 requires.
Use `bin/fm-bearings-snapshot.sh --json --include-prs --all-pr-repos --all-in-flight --all-decisions --all-secondmates --all-queued --all-unhealthy` for a fresh fleet and open-PR view; if its `omitted[]` names an actionable surface, rerun with that entry's reveal flag.
Build the tangle map from live evidence only: each PR's checks, each worker's current state from `bin/fm-crew-state.sh`, the merge queue, the served commit from the project's served-version reader, and every mate's backlog on its own machine.
The backlog's own notes, a recorded URL, a surviving terminal, a delivered steer or an old status line are not evidence of an active owner or of current state.
Group every stuck item by its one cause: a rule, a tool, a missing right, or a person.
Read the captain's standing decisions in `data/captain-shared.md` and `data/captain.md` before raising anything; a question they already answer is applied, not re-asked.
Before sequencing, read the backlog's blocked-by links and priorities, the latest planner roadmap wave file, and the Q bug list.
The [backlog contract](../../../AGENTS.md#10-backlog-contract) identifies the configured backlog where the blocked-by links and priorities are recorded.
The latest roadmap wave file is the current wave file the registered navigation-scoped planner already publishes, and the Q bug list is the list that project already keeps.
Find the wave file and the bug list through that home or project's existing discovery, and do not copy private paths or file contents into these instructions.

## Untangle and correct

For each tangle, untangle it by hand this pass (install, merge, relaunch, re-file, re-sequence) through the owning guarded path, or name the single thing still blocking it and who owns that.
Fix by hand before fixing the tool, because the hand fix lands in minutes and the tool fix is a PR; file the tool fix as a separate item.
Treat repeated failures as one class fixed at the root through its existing owner, because one-by-one fixes multiply.
Judge every rule, gate, hook, queue or check that cost time in this period: name its cost in minutes and decide keep, cut, or make advisory; cut directly where the fleet is empty and by PR otherwise, and prefer removing a rule to adding one.
Check the sequence of every in-flight item and every ready item: its stage, whether it serves the stable base in the captain's recorded priority order, and whether it is duplicated, stale, out of order, or on the wrong method.
Wrong methods include a class of failures fixed one by one, review rounds beyond the selected delivery contract in [`bin/fm-dod-lib.sh`](../../../bin/fm-dod-lib.sh), a redesign delivered as a bandaid, and, for fixes outside the [class-fix rule](../diagnostic-reasoning/SKILL.md#class-fix), a quick or surgical fix pushed through full review or test rounds when a live journey walk or another checkpoint already tests it.
Correct each such item: close, re-sequence, bundle, merge, or hand it to the right mate through the parent channel, with the planner confirming readiness before any handoff.
Sequence ready work under the [dispatch limits](../../../AGENTS.md#intake-and-authority) and [delivery backpressure contract](../../../docs/configuration.md#writing-lane-capacity-configwriting-lane-cap-configrelease-capacity).
Recheck every wait's actual release condition, including supervisor-imposed holds; when it clears, notify its owner in the same pass and verify continuation.
Never park work behind "wait for my go"; decide alone on relaunches, re-sequencing, waivers, cancelling doomed CI, hand installs, closing stale items, and cutting a rule the captain already ruled against.
Ask the captain only for discarding unlanded work, money, destructive or irreversible steps, product choices, and cutting a safety boundary the captain never addressed.
Claim "live" only from the served commit, because the deploy target is not the served version.
For ready work, `AGENTS.md` section 7 owns checks, merge authority, guarded landing, post-merge checks, and cleanup; for an active live journey walk, load `journey-walk`; for escalated findings, load `ask-user-authority` and `captain-hold-lifecycle`.
Before closing the pass, read back each intervention once against its expected change and record the evidence in the same task note.
Count movement only for observed resumed work, a substantive execution or validation milestone, a cleared blocker with continuation, or verified delivery; sending a message, relaunching an idle endpoint, retrying the same failure, or an unchanged CI label does not count.
Stop after this bounded pass; ordinary supervision continues under its existing cycle.

## Report

Follow `AGENTS.md` section 9 for captain-facing authority, plain language, full PR URLs, and a self-contained final reply, in Captain Signal v2 style with its five status emoji only.
Report, in this order: what was tangled and its cause, what was cut or changed and why, what each lane does now and its stage, what is owed and when the captain will see it live, and minutes saved or lost.
Keep it under 60 lines, with each full `https://` link on its own line and no PR numbers in prose.
Put captain actions first, with short lettered choices and a marked recommendation; ask at most two decisions in one reply.
Work that remains stuck is not the no-op case, even when no new action was possible.
If the pass changed nothing, found no current failure or wait to report, and nothing needs the captain, reply exactly `Captain, shipshape.`
