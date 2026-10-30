# Walk-request test phase, round 2

Target: `3b60ed85b2b5b8cd548ca54b7cd9fc778ee72428`.
All targeted checks and live scenarios passed.
No source or test files were changed.

## Independent acceptance oracle

The recorded owner decision requires MAIN-only `FM_WALK_REQUEST_PROJECT` and `FM_WALK_REQUEST_TARGET`, passed together as separate dispatcher flags.
Neither configured means neither flag; incomplete or malformed values must exit 2 before dispatch, including direct `dispatch-one` calls.
Requests must not override MAIN's environment.
The original bug requires a strict dispatcher demanding `x` / `production` to accept the changed invocation without a wrapper.
The replay checks these requirements with exact argument parsing, staged brief bytes, persisted outcomes, and duplicate-call checks.

## Live product evidence

`round2-live-routing-transcript.log` records the real `bin/fm-walk-request-check.sh` and `bin/fm-send.sh` using marked disposable lab homes under the worktree.
A documented inline secondmate parent-channel request is the input.
A strict boundary executable stands in for the home-private external walker dispatcher at its default `data/bin/fm-grok-bot-dispatch.sh` location.
The bridge, its credentials, external walks, production data, terminal fleet sessions, and operator configuration are not exercised.
The real product itself is not replaced.
The sender's durable inbox contract is verified with the terminal doorbell deliberately unavailable on a nonexistent lab-only socket.

- MAIN's `x` / `production` pair reaches the default dispatcher as separate flags, and the real inbox contains a successful outcome.
- The same strict dispatcher rejects the base checker with exit 2 because both flags are missing.
- Unset values emit neither flag; the other dispatch arguments and inbox result remain correct.
- `Project_2.v1-rc` / `Target_3.prod-v2` arrive unchanged.
- Incomplete pairs, spaces, tabs, newlines, option-like or punctuation prefixes, shell punctuation, Unicode and slash values exit 2 at both `check` and `dispatch-one` before intake or dispatch side effects.
- Hand-written request routing fields cannot override MAIN, and carrier `--project` / `--target` options exit 2 without appending requests.
- Repeated sweeps neither redispatch nor duplicate the durable inbox result.

`round2-live-bounded-delivery.log` records an additional live check with real `fm-send.sh` stalled on a metadata lock held by another live process using the real lock library.
Three sweeps return inside the registered four-second limit and retain the pending outcome.
Releasing the lock allows exactly one durable delivery; a subsequent sweep remains quiet and does not resend.
All detached dispatch children, timeout descendants, and the lock holder were awaited; disposable homes were removed.

## Focused automated and regression checks

`bash tests/fm-walk-request.test.sh` exited 0, including the previously failing slow-send budget/fairness case and environment routing tests.
`bash tests/fm-timeout-lib.test.sh` exited 0, including clock rewind, process bounds and signal handling.
`round2-checkpoint-regression.log` shows a manual execution of the actual checkpoint library with a one-second deadline and a sixty-second backwards shell-clock adjustment.
The base incorrectly grants another 25 seconds; the target reports expiration and budget status 124.
The disposable base-library copy was removed.

The research skill and diagnostic-reasoning procedure were loaded.
The supplied research-book index identifies the existing timeout research; outside primary evidence also confirms Bash SECONDS uses the system clock: [GNU Bash variable documentation](https://www.gnu.org/software/bash/manual/bash.html#Bash-Variables) and the [Bash upstream clock discussion](https://lists.nongnu.org/archive/html/bug-bash/2023-03/msg00092.html).
The clock comparison reproduces the behavior without changing the host clock.

The first contention replay exposed a driver-only bookkeeping error: it required all adopted children to exit 0, including timeout descendants correctly terminated by SIGTERM.
Its trace is retained in `round2-live-bounded-delivery-driver-setup.log`.
The corrected driver accepts only normal exit or the expected SIGTERM for those descendants; the real dispatch log must still show exit 0, and recovery and idempotence assertions passed on replay.
No product change or weakened product assertion was needed.

Replay commands:

```sh
python3 ~/.no-mistakes/evidence/01M6652CCZDGTN89BP9K68QCQS/round2-drive-routing.py
python3 ~/.no-mistakes/evidence/01M6652CCZDGTN89BP9K68QCQS/round2-live-bounded-delivery.py
python3 ~/.no-mistakes/evidence/01M6652CCZDGTN89BP9K68QCQS/round2-checkpoint-regression.py
```

This is a CLI and filesystem protocol change; no graphical surface requires screenshots.
No linters, formatters, static analyzers, full-repository suite, publication, or pipeline-control phases ran.
Final `git status --short` is empty.
