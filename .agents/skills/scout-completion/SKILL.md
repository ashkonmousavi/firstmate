---
name: scout-completion
description: Load when a scout reports completion, presents a visual artifact for iteration, or is being considered for promotion to implementation.
user-invocable: false
metadata:
  internal: true
---

# Scout outcome and promotion

A completed scout must leave a self-contained report before its scratch worktree can be discarded; read and relay its findings, retain the report, and re-evaluate the queue.
A report may recommend implementation but does not authorize it.
Before treating the investigation or any visual review as complete, load `captain-hold-lifecycle`; teardown enforces that shared completion gate.
After that completion gate passes, record the report through the guarded completion command documented in [`bin/fm-tasks-axi.sh`](../../../bin/fm-tasks-axi.sh) before ordinary teardown.
This accepts a standalone scout row; a scout phase on a ship or slice owner row records its deliverable without accepting the parent outcome, which requires its green walk.
The [retention contract](../../../bin/fm-backlog-transition-lib.sh) owns parent-state preservation and cleanup replay.
For a safe worker awaiting external proof, use the preserved-task exit and resumption sequence in `ship-landing` instead of destructive cleanup.
A recommendation, a technical ambiguity, a scope disposition, or a repeated-theme correction is decided, recorded, and reported, and does not become a captain call.
When a scout's deliverable is a visual artifact the captain will iterate on, keep it alive and follow the crew-hosted Lavish board contract in `docs/configuration.md` rather than arming or polling the board from firstmate.
When implementation is separately authorized, promote the existing scout through `bin/fm-promote.sh` rather than creating a duplicate task.
The promoted worker must inventory scratch state, return to a clean copy of the task's base (its recorded base branch, else the default branch), carry over only intended fix changes, create the ship branch, and follow the project's selected delivery path while leaving scratch commits and debug edits behind and turning a reproduced bug into the regression test.
