---
name: backlog-operations
description: Use before filing, updating, holding, handing off, or reconciling backlog work and task notes.
user-invocable: false
metadata:
  internal: true
---

# Backlog operations

## Backlog contract

The configured `tasks-axi` backend is the durable queue; the tracked default is `data/backlog.md`.
It tracks work items only, never agents; persistent secondmates never appear as backlog items.
Work routed to a secondmate is recorded in that secondmate home's own backlog, not the main backlog.
A decision is simply a task held for the captain: create the task with `bin/fm-tasks-axi.sh add` when needed, then always hold it through `bin/fm-captain-hold.sh hold <id>` with the flags its header requires, with `--until <date>` when the captain defers it.
Every hold and Captain's Call item names its origin as `bin/fm-captain-hold.sh`'s header requires, and only an owner-request origin is the owner's word; that header also owns re-deciding an owner claim with no traceable owner message.
When a main-side thread such as a pending captain decision or relay reminder is worth durable tracking, file it as its own work item and hold it through that wrapper.
Captain calls discovered by investigations or visual reviews follow `captain-hold-lifecycle`, which owns their completion gate and recorded-answer rules.
When the automatic transition gate applies, `bin/fm-spawn.sh` owns dispatch and `bin/fm-teardown.sh` owns cleanup; `ship-landing` owns pending-proof resource release and acceptance-before-cleanup ordering through the existing task commands.
Keep filing, ownership, decisions and acceptance evidence current; `docs/configuration.md` owns gate applicability and the manual-backend exception.
Re-evaluate queued work after every teardown and heartbeat, and also after a recorded PR-ready handoff when `config/project-capacity` caps that project, dispatching items only when dependencies, time gates, and project capacity have cleared.
Use `bin/fm-capacity.sh` for that re-evaluation under the [machine admission requirements](../../../docs/configuration.md#machine-capacity-configlane-capacity).

`.tasks.toml`, `docs/configuration.md`, and current `tasks-axi --help` own the backlog schema, compatibility, retention, and routine command syntax.
Use compatible `tasks-axi` when the configured backend selects it, always through `bin/fm-tasks-axi.sh` so the call reaches this home's backlog from any directory, and the documented manual path otherwise; keep only the configured recent Done entries.
`secondmate-provisioning` and `bin/fm-backlog-handoff.sh` own cross-home handoff safety.

Keep free-form notes free of temporary paths, moving versions, ephemeral identifiers, and copied state that will rot.
Inspect the current task note before replacing its considered body, and archive the superseded body when recoverability matters rather than appending by default.
Verify volatile details against their authoritative config, live system, or API before acting, and correct or delete stale prose immediately.
Preserve durable structured identifiers, dependencies, and completion artifact links, and route reusable knowledge through [stow's knowledge-placement contract](../stow/SKILL.md#knowledge-placement) rather than scattering it through task notes.
