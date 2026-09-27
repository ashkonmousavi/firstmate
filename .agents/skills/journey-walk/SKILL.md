---
name: journey-walk
description: >-
  Agent-only procedure for commissioning and supervising a live end-to-end journey walk.
  Load before commissioning, scheduling, or supervising a live end-to-end journey walk, and when a walk blocker's fix is installed.
  Owns firstmate's supervisor duties: one walk owner, the install freeze and its same-turn durable record, the live-version gate, class-fix lanes, focused re-walk after install, HEALTH.md currency, and captain-language outcomes.
  The project's Journey/SOP.md owns the walk itself.
user-invocable: false
metadata:
  internal: true
---

# journey-walk

Load this before commissioning, scheduling, or supervising a live end-to-end journey walk, and when a walk blocker's fix is installed.

The project's `Journey/SOP.md` is the walk contract.
Read that file and the siblings it names (`STAGES.md`, `HEALTH.md`, `runs/`) rather than reconstructing the method here.
If that SOP is absent, stop and report the gap instead of inventing a walk method.
This skill owns only firstmate's supervisor duties around that contract.
Commission the walk as ordinary project work under `AGENTS.md` section 7.
Firstmate does not execute the walk itself.

## Lesson of 2026-09-26

The last walk stalled because fixed blockers were never re-walked, walks restarted from step 1, and installs changed the build mid-walk.
Treat those three as the standing failure modes this skill exists to prevent.

## Supervisor duties

Name one walk owner for the run, the version reservation, the stage ledger, defect grouping, and the final verdict.
Do not split those across lanes.

Hold installs for the walk window and its cleanup.
Record that freeze in the walk task's durable records the same turn it starts, and record its release the same turn it ends.
A walk that cannot hold the installed version does not start acceptance evidence.

Walk only when the version carrying the needed fixes is live.
Do not send a re-walk against a build that does not yet include the fix.

When a blocker is posted, start a class-fix lane for that blocker at once.
Group by the earliest confirmed cause named in the project's SOP.
Do not wait for the whole walk to finish before filing the fix.

After each fix is installed, send the focused re-walk of that repaired stage and its dependents.
Do not restart the walk from step 1.
The project's SOP owns how that re-walk is executed.

Never report the journey healthy from seeded passes or from fixes alone.
A healthy verdict needs one coherent signed-in pass through the dependent spine with every planned stage passing on the same frozen live version, as the project's SOP requires.

Keep the project's `HEALTH.md` current by requiring the walk owner to update it after each run or focused re-walk, and treat a missing update as unfinished supervision.
Relay outcomes in captain language under `AGENTS.md` section 9: the stage, the blocker, the live version, and the next required re-walk.
