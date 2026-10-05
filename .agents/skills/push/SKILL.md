---
name: push
description: >-
  Take one bounded pass over the live Firstmate fleet when the captain invokes /push, $push, or explicitly asks to check and push the fleet forward.
  Advance work within current authority and report only changed outcomes, current failures or waits, and captain decisions in Captain Signal v2 style.
user-invocable: true
metadata:
  internal: true
---

# push

The captain wants every currently actionable item advanced as far as Firstmate's present authority allows in one pass.
Finish the pass with a short account of what changed and what genuinely needs the captain.

## Gather

Confirm this home has completed the session-start digest and holds its required lock before any fleet mutation, as `AGENTS.md` section 3 requires.
Start by draining the durable wake queue, unless the session-start digest already presented it, as `AGENTS.md` section 8 requires.
Use `bin/fm-bearings-snapshot.sh --json --include-prs --all-pr-repos --all-in-flight --all-decisions --all-secondmates --all-queued --all-unhealthy` for a fresh fleet and open-PR view.
If its `omitted[]` still names an actionable surface, rerun with that entry's reveal flag so no lane is skipped.
Cover every active project's open PRs, including projects known only through a secondmate; disclose unreadable or incomplete coverage.
Reconcile each PR to its owning home and current worker or authoritative pipeline, or an explicit supervised wait with an owner, unmet resume condition and next check.
A recorded URL, surviving terminal, delivered steer or old status is not proof of an active owner; route missing ownership through the owning home's recovery procedure.
For each stuck item, read the previous intervention and retain its current head or run/step, blocker, last substantive movement and next expected observable change in its existing task note.
Handle and acknowledge every presented wake under the emitted supervision protocol and `AGENTS.md` section 8.
Use current-state readers before acting on an old status event, and refresh the snapshot with the same flags as needed after material changes.
Read current project registry, delivery posture, captain preferences, and task records where an action depends on them; do not infer today's projects or priorities from this skill or memory.

## Advance once

Review every actionable wake and each ready, blocked, paused, stale, and queued lane visible in the current fleet view.
Resolve decisions within standing authority and record them through their owning lifecycle; load `ask-user-authority` for review findings and `captain-hold-lifecycle` for captain-held calls.
For ready work, use `AGENTS.md` section 7 to verify current checks, merge authority, guarded landing, post-merge checks, and cleanup before calling it landed.
For landed work with a deploy target, route any pending install through the project's established worker and verify deploy health and the served version before describing it as live.
For blocked or unresponsive work, inspect its current state, steer or recover through the owning procedure, and preserve unlanded changes.
Group repeated blockers by demonstrated cause; route one repair through its existing owner before repeating dependent retries.
Use the home's stuck-validation playbook when present, applying current authority over superseded examples.
Recheck every wait's actual release condition, including supervisor-imposed holds; when it clears, notify its owner in the same pass and verify continuation.
For queued work, reassess blockers, dates, priorities, dependencies, and available writing capacity before dispatching eligible items in order.
For an active live journey walk, load `journey-walk` and route actionable fixes and dependent validation through its recorded stage and evidence contract.
Handle due reminders and follow-ups through their existing owners.
Use the parent channel for secondmate work rather than supervising a secondmate's child lanes directly.
Before closing the pass, read back each intervention once against its expected change and record the evidence in the same task note.
Count movement only for observed resumed work, a substantive execution or validation milestone, a cleared blocker with continuation, or verified delivery.
Sending or acknowledging a message, relaunching an idle endpoint, retrying the same failure, and an unchanged queued/running CI label do not count.
If an action has not taken effect yet, report it as pending verification and give ordinary supervision its completion condition and next check; do not wait through a whole CI run.
If nothing moved, name the limiting cause, owner and next check; if the previous intervention also produced no movement, inspect why and use the next supported recovery or shared-cause action instead of repeating the same steer.
If an external wait is healthy, preserve it without needless retries; escalate only a concrete missing authority or exhausted recovery path.
Stop after this bounded pass; ordinary supervision continues under its existing cycle.

## Report

Follow `AGENTS.md` section 9 for captain-facing authority, plain language, full PR URLs, and a self-contained final reply.
Report only changed outcomes, current failures or waits, and decisions that truly require the captain; omit unchanged fleet inventory.
State how many stuck items measurably moved and the evidence for those changes; separate actions awaiting verification and healthy external waits.
Work that remains stuck is not the no-op case, even when no new action was possible.
Use Captain Signal v2's five status emoji only: 👉 for a captain action, ❌ for a problem, ⏳ for work still moving, ✅ for completed work not yet verified live, and 🎉 only for verified live behavior.
Address the captain once early and bold one key phrase on each status line.
Put captain actions first, with short lettered choices and a marked recommendation when a decision is needed; ask at most two decisions in one reply.
Keep the reply scannable, normally three to eight short lines, with each full `https://` link on its own line.
If the pass changed nothing, found no current failure or wait to report, and nothing needs the captain, reply exactly `Captain, shipshape.`
