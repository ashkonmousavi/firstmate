# Cancellation policy Test-phase review

Reviewed head: `05aaa56818539399997ae88f51b69b3b86e7a2b9`.
Base: `3cc72174ed8110d415ea408fed2b6f6365287726`.

The complete change modifies only AGENTS.md section 7, replacing one sentence with three sentences.
No executable code, workflow, skill, test, or fm-wait-board change is present.

## Manual wording assessment

AGENTS.md lines 247-249 retain main repair and current-main proof priority, permit lower-priority PR cancellation and rerun with a logged reason, forbid cancelling a running main run, and limit replacement after a newer merge to main legs that have not started.
The ship-landing skill contains no old main-cancellation wording requiring an update.
Its red-main response still requires a revert within one hour unless a fix is already green on main, and forbids a fix chain ahead of the queue.
Related-owner searches found no additional copy of the obsolete superseded-main cancellation instruction.
The existing CONTRIBUTING.md CI description and workflow already describe main-push cancellation protection; those files are unchanged.
These observations assess the instruction text and change scope only.
They do not demonstrate model interpretation or cancellation behavior in a running product.

## Live-validation disposition

Verdict: no-surface.
The changed natural-language instruction has no executable interface to exercise.
A disposable Firstmate home or harness would still need model interpretation and external CI runs to act on this rule, and would not provide a deterministic live surface introduced by this change.
Operating real CI or another delivery phase is outside this assigned Test phase.
No fleet, harness, GitHub, CI, or pipeline lifecycle operation was performed.
No automated tests, linters, formatters, or static-analysis tools were run.
No visual evidence is applicable because no rendered user interface changed.
All runtime scenarios remain untested, pending the outer executor's human disposition of no-surface.

## Checks performed

- Full base-to-target git diff, changed-file list, and current-head inspection.
- Manual inspection of AGENTS.md sections 1 and 7 and firstmate-coding-guidelines.
- Manual inspection of ship-landing and scoped related-owner cancellation references.
- Read-only inspection of the existing workflow concurrency description and contributor reference.
- Git status inspection confirmed no worktree modifications.
