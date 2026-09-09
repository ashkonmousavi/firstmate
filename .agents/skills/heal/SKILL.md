---
name: heal
description: >-
  Manually inspect and repair recurring failures, neglected obligations, and unnecessary delivery friction when the captain invokes /heal, optionally with a recent-event window such as /heal 4h.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# heal

Run a bounded evidence-led recovery pass while keeping the next complete application outcome progressing.
Every invocation opens with [workflow.md](workflow.md#1-direction-first)'s Direction first step, before any failure inventory: name that outcome and check whether current assignments actually serve it, questioning stale holds and apparent completion rather than accepting ownership or a done label at face value.
Use the current session and its completed startup digest; do not run session start again merely because this skill was invoked.
Treat `$ARGUMENTS` as the optional recent-event window, with a bounded four-hour default on the first pass.
Older unresolved findings always carry forward regardless of that window.

First run `bin/fm-heal.sh owner-status` from the tracked Firstmate code root.
If it prints `advisor`, remain wholly read-only and follow [workflow.md](workflow.md#read-only-advisor-mode).
Do not initialize or update the ledger, acquire or recover the fleet lock, start or steer workers, acknowledge queues, or change fleet state.
Return recommendations with observation times, identities, uncertainty, and the warning that the lock-owning Firstmate must refresh them before acting.

If it prints `owner`, read [workflow.md](workflow.md) completely and follow its invocation flow.
Initialize the private ledger lazily with `bin/fm-heal.sh init`.
Use the helper for lifecycle transitions, occurrence accounting, source-bound checkpoints, archive moves, index rebuilds, and safe finding publication.
Never write scan progress before the corresponding finding evidence is safely preserved.

Use current authoritative state to disprove stale reports before promoting repairs.
Link existing tasks, Changes, releases, and owners instead of creating a parallel queue.
Advance authorized repairs only through their existing owners and supported delivery procedures.
Do not reserve an idle worker merely to watch for recurrence.

Reserved spending, trading, destructive work, disposal of unlanded work, disruptive production actions, and merge or deploy authority remain independently governed.
Never touch existing supervisor notification or queue cursors.

Lead the response with what changed and what it unblocked.
Then distinguish verified repairs, containment, ongoing work, coverage gaps, owners and release triggers, the next application outcome, and genuine captain decisions.
