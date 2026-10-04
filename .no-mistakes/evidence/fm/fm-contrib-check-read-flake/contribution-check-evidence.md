# Focused contribution-check evidence

Validated target 4441e44df2a1f9bf042b4b1cb36d2caa80c5a93e against base 5e21b96150e4e834254a6a5c6f8ce1b3a7fb05fb.
The tracked diff changes only tests/fm-contributions.test.sh, so this provides targeted regression proof rather than live product acceptance.
The driver executes the actual generated contributions.check.sh and production fm-contributions.sh against the existing stub forge in disposable workspace homes.
No real GitHub service, operator data, credentials, fleet lifecycle, or harness was used.

Run from the gate worktree: `python3 /home/tegris/.no-mistakes/evidence/01M43JPN5CQXVHJPWPJ4KJAKEC/contribution-check-driver.py`.
The driver retains test definitions and selects only test_arm_plumbs_a_configured_budget_into_the_check_shim; it does not execute the full script or repository suite.
The accelerated fallback advances by one second per +%s call, while the existing clock file still wins.
Transient test copies and fixture roots were removed after execution.

| Run | Exit | Elapsed seconds | Observable result |
| --- | --- | --- | --- |
| target-baseline | 0 | 3.912 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| target-ticking-1 | 0 | 4.34 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| target-ticking-2 | 0 | 2.631 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| target-ticking-3 | 0 | 2.552 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| target-ticking-4 | 0 | 2.567 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| target-ticking-5 | 0 | 2.584 | Both modes attempted exactly api repos/o/r/pulls/8; empty stdout/stderr; prior record byte-identical; no durable wake; pinned clock used. |
| base-ticking-configured | 1 | 0.317 | No read occurred; original missing forge/calls diagnostic and generated check did not attempt a read failure reproduced. |
| target-unpinned-configured | 1 | 0.311 | No read occurred; exact missing-read failure retained without grep diagnostic. |
| target-unlogged-configured | 1 | 1.312 | Read log suppressed; exact missing-read failure retained immediately after the bounded check returned. |
| base-ticking-inherited | 1 | 0.358 | No read occurred; original missing forge/calls diagnostic and generated check did not attempt a read failure reproduced. |
| target-unpinned-inherited | 1 | 0.344 | No read occurred; exact missing-read failure retained without grep diagnostic. |
| target-unlogged-inherited | 1 | 1.374 | Read log suppressed; exact missing-read failure retained immediately after the bounded check returned. |

All nonzero exits above are deliberately failing regression controls.
Captured state JSON files retain the generated shim, forge call log, clock trace, before/after durable contribution records, and wake state for each invocation.
The original-head slow-tail elapsed assertion is outside this cause class and was not run or changed.

## Retained human-authorized cause-class inventory

Cause-class inventory: at reviewed head 2328688d, tests/fm-contributions.test.sh:1037-1042 polls a forge log only after the synchronous generated check returned (configured line1028, inherited line1033).
The single affected occurrence is this loop and its local attempt variable at line1015; both budget modes share it.
Search scope: the entire target function and wrap_forge plus fm_run_timed direct tracing; the forge wrapper writes its call before sleeping, so no late writer can make post-completion polling useful.
Other suite condition waits involve active processes and are outside this cause class; do not change them or the unrelated slow-tail test.
This test phase retained the supplied inventory and validated the already-committed removal; it did not perform the separately owned next Review phase.
