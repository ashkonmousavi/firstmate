# Walk-request routing validation

The requested environment-only routing works at the executable dispatcher boundary. The complete targeted test file does not finish cleanly: its existing slow-delivery budget assertion fails intermittently, including against the base checker. No tracked files changed.

## Product evidence

Run from the gate worktree:

```sh
python3 ~/.no-mistakes/evidence/01M6652CCZDGTN89BP9K68QCQS/drive-routing.py
```

This replay creates marked disposable homes inside the worktree, writes a secondmate's documented inline parent-channel request, executes the actual `fm-walk-request-check.sh`, waits for its detached dispatch children, and executes the actual `fm-send.sh` to save the result in the secondmate's durable inbox. The only substitute is the external private dispatcher: a strict argument-parsing executable at the default `data/bin/fm-grok-bot-dispatch.sh` path. No route wrapper, send stub, harness CLI, Grok bridge, real credentials, shared services, or operator data are used. Terminal notification is deliberately unavailable on a nonexistent lab-only socket; inbox persistence is the asserted delivery contract.

Independent oracle: the owner's recorded decision requires the pair exactly as configured, no pair when absent, exit 2 before dispatch for incomplete or malformed values, and no request-level route overrides. The probe rejects omitted `x`/`production` when that route is required. Incorrect routing, split arguments, missing or duplicate flags, dispatch on invalid input, and duplicate later sweeps are rejected by assertions.

Observed results in `live-routing-transcript.log`:

- `x` and `production` arrived as separate `--project x --target production` arguments. A hand-written `project=untrusted target=other` did not override them. The real inbox contained `outcome: sent, exit=0: dispatcher boundary accepted: project=x target=production`.
- No configured values: neither route flag appeared. The rest of the dispatcher call, staged brief bytes, once-key, and outcome inbox remained correct.
- `Project_2.v1-rc` / `Target_3.prod-v2` arrived unchanged.
- Incomplete pairs and invalid whitespace, option-like prefixes, punctuation, Unicode, or slash values exited 2 at both `check` and `dispatch-one`; no dispatch or request-intake side effects occurred.
- Carrier `--project` and `--target` options exited 2 without appending a request.
- Later sweeps did not repeat dispatch or inbox delivery.
- The base checker, given the same route environment and staged request, omitted both flags and recorded dispatcher exit 2: `explicit supported --project and --target required`. The changed checker recorded exit 0.

All replay scenarios passed. Disposable homes and the base-script copy were removed, adopted dispatch children were awaited, and `git status --short` was empty.

## Targeted test results and unresolved failure

`routing-focused-tests.log` records successful execution of the existing environment pair, absence, and validation tests selected from `tests/fm-walk-request.test.sh`.

`env -u TMPDIR bash tests/fm-walk-request.test.sh` exited 1 at `test_slow_deliveries_are_bounded_and_fair`, reporting `a sweep must yield inside the registered check's bound`. The same isolated behavioral test exited 1 against the unmodified base checker (`base-delivery-budget-test.log`). An isolated target trace failed too (`target-delivery-budget-trace.log`), while a more detailed product trace passed (`delivery-budget-product-trace.log`); the issue is intermittent. A subsequent complete targeted-file run with diagnostic-only GNU timeout logging also failed (`walk-request-with-timeout-observations.log`). Individual timeout invocation diagnostics are retained under `timeout-observations/`.

`reproduce-budget-test.py` reconstructs the disposable selector and base checker, runs that existing behavioral test against both commits, prints their exit statuses, and removes its temporary source files. Intermittency means a replay can pass.

The base comparison and independent source review establish that the routing diff does not introduce the timeout/delivery-budget code. The exact cause remains unresolved. One trace returned outer timeout status 124 without a child exit-status record. Inner delivery budgets were capped to 2 seconds in the detailed trace. These observations do not justify weakening the four-second assertion or changing unrelated product code in this routing task.

GNU coreutils timeout is version 9.4. Its upstream [implementation](https://github.com/coreutils/coreutils/blob/master/src/timeout.c) and [behavior tests](https://github.com/coreutils/coreutils/blob/master/tests/timeout/timeout.sh) document status 124 and signal handling; the observed binary is not uutils timeout. `strace` was absent from PATH, so optional signal-sender tracing was unavailable; GNU timeout `--verbose` was used instead. No installation or host search was attempted. No project research book is present in this worktree, and the operator's private book was not read.

## Setup corrections

The initial suite invocation placed its temporary briefs under a hidden worktree path; the product correctly refused them under its existing privacy rule. Running the existing test toolchain with standard ephemeral temporary fixtures corrected that setup (`walk-request-targeted-tests.log` retains the first attempt). The first manual replay had a driver-only JSON key collision between brief content and brief path; it was corrected before the passing replay (`live-routing-driver-setup.log` retains that attempt). Neither required a product change.

The surface is a shell CLI and filesystem protocol, so CLI transcripts and persisted inbox output are the visible product evidence; no graphical UI was changed. No linters, formatters, full-repository suite, publication, or pipeline-control commands ran.
