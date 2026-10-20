# Review fix class inventory

Run: 01M5CQ28GVNT8CAP3NH9XQNRE0
Reviewed head: 791edadfe00af2e8b863ac1c2fb4a3aba080ee21
Base: cb61185f2624afb748094c2a982d361f28edaad5

## Cause and invariant inventory, retained before edits

- review-1: vendor-rendered evidence cannot be inferred from a synthetic capture or a different idle border. Both empty and typed input must be observed on the actual weekly-limit surface, through fm_tmux_composer_state and styled/plain cursorless fm_composer_classify_screen. The prior real Grok 1.0.62 run rendered no weekly-limit field. This remains an external precondition gap, not a demonstrated matcher defect. Installed configuration documentation exposes no weekly-limit display switch. Do not manufacture quota data or mutate account state to make the guard pass.
- R2: a live guard must be discoverable through the single family registry. The only newly added live guard is tests/fm-composer-grok-weekly-live-e2e.test.sh, omitted from family_for_basename in bin/fm-test-run.sh. That registry controls explicit family listing, scheduling, and changed-file selection. The existing bin/fm-composer-lib.sh mapping already selects live-harness-optin, so one registry entry closes every affected selection path.
- R3: the next Review must receive the retained cause inventory and observable regression results. This file is the run evidence handoff. Review must read this exact file and focused-verification.log, verify the registered guard via the runner public selection interface, and leave review-1 unresolved unless real weekly-limit empty/pending output exists.

## Search scope and negative evidence

Inspected the complete branch diff, bin/fm-test-run.sh family registry and composer change mapping, tests/fm-composer-grok-weekly-live-e2e.test.sh, tests/fm-composer-lib.test.sh, bin/fm-composer-lib.sh titled-bottom boundary, bin/fm-control-lib.sh, and docs/verification/runtime-backends.md.
Searched weekly-limit occurrences in bin/ and tests/ and the Grok harness reference. The control-library weekly-limit picker detection is a separate dialog contract; it is not a sibling composer-border matcher. Backend wrappers share fm-composer-lib.sh rather than owning duplicate weekly-border parsers. There is only one newly added guard requiring registry repair. No matcher changes are needed for R2 or R3.

## Independent oracle and regressions

The runner public --list output must include the guard exactly once for live-harness-optin and changed selection relative to the base; omission or duplication is a failure. This tests observable selection, not implementation-source strings.
The live oracle is real vendor rendering plus known keystrokes: idle must read empty; visibly typed, unsubmitted text must read pending. The weekly-limit field must actually render before either verdict counts as proof.
The preceding round passed bash tests/fm-composer-lib.test.sh, including weekly-limit empty/pending/unknown behavior, and bin/fm-doc-audience-check.sh. Those portable results do not close review-1.
Focused results for this round will be retained in focused-verification.log beside this inventory. Any absent weekly-limit surface remains a failed live proof.

## Completed focused verification

Both public runner selections passed and included the weekly guard exactly once: --list --family live-harness-optin and --list --changed --base cb61185f2624afb748094c2a982d361f28edaad5.
A fresh real Grok 1.0.62 run again returned exit 1: weekly-limit border not rendered; live coverage unavailable. No quota data, model responses, or captures were fabricated. review-1 remains unresolved. R2 is repaired. R3 now has this retained inventory and focused-verification.log for the next Review to consume; actual downstream consumption must be checked by that Review.
The only project-source edit this round is the single family-registry entry in bin/fm-test-run.sh. git diff --check passed. No complete test or lint suite was run.
