# Delivered AGENTS.md section 7 work-order contract

Materialized by running the product's own governance installer against the edited file:
`bin/fm-ensure-agents-md.sh <fresh project dir>` -> wrote CLAUDE.md @AGENTS.md pointer, AGENTS.md byte-identical (sha256 unchanged across two runs).

What an agent session loads from the installed AGENTS.md (section 7, dispatch/work-order passage):

```

Treat file or subsystem overlap as a risk signal rather than an automatic reason to wait, and dispatch isolated work as soon as a writing lane is free when each change can be independently implemented and validated and the selected delivery path can reconcile ordinary rebases or conflicts.
For work larger than one task, build the shared structure the later work attaches to first, under one owner, then split by vertical outcome with one lane per area owning its files.
A shared or unstable module has exactly one integration owner: a lane that needs it changed asks that owner rather than editing it, and keeps working on its own files until that change lands (`wayfinding` owns the multi-task procedure).
Size concurrent writing lanes to review capacity, not to the number of ready items.
Serialize only for a true semantic dependency, shared mutable external state, incompatible concurrent migration, or another concrete condition that makes independent progress or reconciliation unsafe; incidental same-file editing alone is insufficient, and genuine blockers remain durable.
```

Skill index entry the same file delivers (line 580):

```
- `wayfinding` - load before scoping work larger than one task, such as a stage, a release, a migration, or a campaign of related changes; before dispatching a task whose backlog dependency names a stage, a release, or a final acceptance; when work is blocked only at its final step or the queue looks fully gated; and whenever the ready frontier lists only umbrellas or nothing while holds still exist.
```
