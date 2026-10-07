---
name: journey-walk
description: >-
  Agent-only procedure for commissioning and supervising a live end-to-end journey walk.
  Load before commissioning, scheduling, or supervising a live end-to-end journey walk, and when a walk blocker's fix is installed.
  Owns firstmate's supervisor duties: one walk owner, the install freeze and its same-turn durable record, the live-version gate, one triage pass per walk batch, same-day cosmetic bundles, class-fix lanes, oldest-break-first ordering, regression-first focused re-walk after install, the project's walk health record currency, batch reports, and captain-language outcomes.
  The project's own walk procedure owns the walk itself.
user-invocable: false
metadata:
  internal: true
---

# journey-walk

Load this before commissioning, scheduling, or supervising a live end-to-end journey walk, and when a walk blocker's fix is installed.

The project's own walk procedure is the walk contract.
Read that procedure and the stage, health, and run records it names rather than reconstructing the method here.
If that procedure is absent, stop and report the gap instead of inventing a walk method.
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
A walk sent through `bin/fm-grok-bot-dispatch.sh` holds them with `--walk <id> --walk-owner <owner>`, whose header owns the walk-marker contract.
Record that freeze in the walk task's durable records the same turn it starts, and record its release the same turn it ends.
A walk that cannot hold the installed version does not start acceptance evidence.

Walk only when the version carrying the needed fixes is live.
Do not send a re-walk against a build that does not yet include the fix.

A posted blocker is evidence, not authorization to change code, under `AGENTS.md` section 7.
When the walk's commissioning or a standing captain instruction authorizes fixing its blockers, start the fix lane after that batch's collection, triage, and required reproduction, following the cluster routing and priority below; a fleet blocker, defined next, opens its lane the same turn.
Otherwise raise the blocker to the captain under section 7 before any lane starts.
A blocker that stopped every walker of the last batch (no sign-in, no AI answer, no live build) is a fleet blocker: open its fix lane the same turn, using the fastest route that restores access before any code change, and dispatch no new walk that needs that stage until a walker re-proves it live.
A walk sent into a known blocker is wasted and is never relabelled "no AI steps" to keep walking.
Read every walk report the turn it lands; a report that says BLOCKED is a wake, not a note.
Once that batch's triage and required reproduction are complete, file the fix or raise the blocker without waiting for later walk batches.

Triage once per walk batch, not once per report: collect every problem from all walkers of the batch before filing.
Cluster the problems by same component and same symptom, and mark each cluster cosmetic or behaviour.
Reproduce a behaviour cluster with your own eyes before filing it; when it does not reproduce, the failed reproduction is the finding.
Cosmetic and copy clusters from all walks of the day go into one bundle per code area, shipped as a direct change with one review on the Grok lane the same day.
Never file one item per cosmetic finding, and never put a behaviour cluster inside a cosmetic bundle.
A behaviour cluster that fails a journey step, or any symptom seen twice, is a class fix under `diagnostic-reasoning`, which owns its root-cause-first repair, labelled-workaround exception, and three-round limit.
Work the oldest failing journey step first; cosmetic bundles never starve a real break.

After each fix is installed, send the focused re-walk of that repaired stage and its dependents; that re-walk is verification, not a code change, and needs no extra authority.
A re-walk waits for the installed build that contains the fix.
Every walker first re-runs the reproduction of each fix installed since its last walk, so a fix that did not hold is caught before new ground, then walks its assigned journey ids and records everything it sees.
Do not restart the walk from step 1.
The project's walk procedure and the walker's own instructions own how that re-walk is executed.

Never report the journey healthy from seeded passes or from fixes alone.
A healthy verdict needs one coherent pass, signed in where the product has sign-in, through the dependent spine with every planned stage passing on the same frozen live version, as the project's walk procedure requires.

Keep the project's walk health record current by requiring the walk owner to update it after each run or focused re-walk, and treat a missing update as unfinished supervision.
Report each walk batch as problems found, clusters, bundles opened, class fixes opened, and time from report to live.
Measure time from report to live from recorded UTC events, never estimate it, and keep the timing numbers in this home's `data/learnings.md`, never in `data/captain.md`, which keeps only the captain's words.
Relay outcomes in captain language under `AGENTS.md` section 9: the stage, the blocker, the live version, and the next required re-walk.
