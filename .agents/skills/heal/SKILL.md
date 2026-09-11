---
name: heal
description: >-
  Manually verify accepted goal and plan completion, current-work correctness, and delivery progress, then advance bounded authorized repairs when the captain invokes /heal, optionally with a recent-event window such as /heal 4h.
user-invocable: true
disable-model-invocation: true
metadata:
  internal: true
---

# heal

Run a bounded evidence-led recovery pass against the complete accepted goal and plan while keeping the next application outcome progressing.
Read [workflow.md](workflow.md) completely, then open with its Direction first step: account for retained obligations and completion evidence, and check whether current assignments and recent deliveries actually serve that destination.
A cleared goal, checkbox, artifact path, or completed scan does not establish correct or complete delivery.
Use the current session and its completed startup digest; do not run session start again merely because this skill was invoked.
Treat `$ARGUMENTS` as the optional recent-event window, with a bounded four-hour default on the first pass.
Older unresolved findings always carry forward regardless of that window.

No automated task/status consumer invokes `bin/fm-heal.sh`; a human or agent runs `/heal`, or exercises the CLI directly the way `tests/fm-heal.test.sh`'s C4 case does.
Whether a recurring failure actually reaches this workflow through Firstmate's ordinary bounded consuming cycle, without someone explicitly invoking `/heal`, is unverified until observed in production; do not build or assume a second, automatic heal-triggering consumer.

Resolve the intended tracked Firstmate code root and operational home from explicit invocation or established session context, never from an unrelated current directory or a guessed project parent.
If either binding is missing or ambiguous, report it and remain advisory without running fleet helpers.
Read the resolved helper's header for the absolute-path invocation and explicit-home routing, then run its `owner-status` check.
If it prints `advisor`, follow [workflow.md](workflow.md#advisor-mode): fleet state stays read-only, while separately authorized isolated preparation may produce reviewable repairs.
If it prints `owner`, follow the workflow through existing fleet owners and supported delivery procedures.
Only in verified-owner mode, initialize the private ledger lazily with `bin/fm-heal.sh init`.
Use the helper for lifecycle transitions, occurrence accounting, source-bound checkpoints, archive moves, index rebuilds, and safe finding publication.
Never write scan progress before the corresponding finding evidence is safely preserved.

Use current authoritative state to disprove stale reports before promoting repairs.
Refresh the promoted findings' current accounts and link existing tasks, Changes, releases, and owners instead of creating a parallel queue.
Follow the workflow's distinction between a bounded repair and the wider application outcome; stale notebook cleanup must not become a delivery gate.
Advance authorized repairs only through their existing owners and supported delivery procedures.
Do not reserve an idle worker merely to watch for recurrence.

Reserved spending, trading, destructive work, disposal of unlanded work, disruptive production actions, and merge or deploy authority remain independently governed.
Never touch existing supervisor notification or queue cursors.

Lead the response with what changed and what it unblocked.
Then distinguish verified repairs, containment, ongoing work, coverage gaps, owners and release triggers, the next application outcome, and genuine captain decisions.
