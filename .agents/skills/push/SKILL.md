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
Use `bin/fm-bearings-snapshot.sh --json` for a fresh fleet view, including registered projects, routed secondmate outcomes, queued work, and current decisions.
Handle and acknowledge every presented wake under the emitted supervision protocol and `AGENTS.md` section 8.
Use current-state readers before acting on an old status event, and refresh the snapshot as needed after material changes.
Read current project registry, delivery posture, captain preferences, and task records where an action depends on them; do not infer today's projects or priorities from this skill or memory.

## Advance once

Review every actionable wake and each ready, blocked, paused, stale, and queued lane visible in the current fleet view.
Resolve decisions within standing authority and record them through their owning lifecycle; load `ask-user-authority` for review findings and `captain-hold-lifecycle` for captain-held calls.
For ready work, use `AGENTS.md` section 7 to verify current checks, merge authority, guarded landing, post-merge checks, and cleanup before calling it landed.
For landed work with a deploy target, route any pending install through the project's established worker and verify deploy health and the served version before describing it as live.
For blocked or unresponsive work, inspect its current state, steer or recover through the owning procedure, and preserve unlanded changes.
For queued work, reassess blockers, dates, priorities, dependencies, and available writing capacity before dispatching eligible items in order.
For an active live journey walk, load `journey-walk` and route actionable fixes and dependent validation through its recorded stage and evidence contract.
Handle due reminders and follow-ups through their existing owners.
Use the parent channel for secondmate work rather than supervising a secondmate's child lanes directly.
Stop after this bounded pass; ordinary supervision continues under its existing cycle.

## Report

Follow `AGENTS.md` section 9 for captain-facing authority, plain language, full PR URLs, and a self-contained final reply.
Report only changed outcomes, current failures or waits, and decisions that truly require the captain; omit unchanged fleet inventory.
Use Captain Signal v2's five status emoji only: 👉 for a captain action, ❌ for a problem, ⏳ for work still moving, ✅ for completed work not yet verified live, and 🎉 only for verified live behavior.
Address the captain once early and bold one key phrase on each status line.
Put captain actions first, with short lettered choices and a marked recommendation when a decision is needed; ask at most two decisions in one reply.
Keep the reply scannable, normally three to eight short lines, with each full `https://` link on its own line.
If the pass changed nothing, found no current failure or wait to report, and nothing needs the captain, reply exactly `Captain, shipshape.`
