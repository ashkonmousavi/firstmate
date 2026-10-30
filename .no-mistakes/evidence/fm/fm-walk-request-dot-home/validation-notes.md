The supplied owner intent and R1 fix decision are the independent oracle for path tests.
The live driver invokes the real carrier and path CLI against disposable homes, inspects generated parent-channel records and staged brief bytes, and verifies refused requests leave the parent channel unchanged.
It reproduces the original refusal using the base commit's helper before testing the fixed helper.

Official documentation consulted through Exa:
- https://docs.python.org/3/library/pathlib.html: resolve follows symlinks; relative_to is lexical. Both literal and resolved boundaries therefore need behavioral checks.
- https://docs.python.org/3/library/time.html: monotonic is unaffected by system-clock updates.
- https://peps.python.org/pep-0418/: use monotonic clocks for timeouts.

The first targeted walk-request run exited 1: the `last` outcome had not received a transport attempt after eight sweeps.
The timeout test file exited 0.
An instrumented isolated fairness run retained each sweep's attempted walk names and record phase/rotation. It exited 0 after sixteen bounded sweeps and recovery, demonstrating continued progress rather than permanent starvation.
Independent review identified a legal schedule needing ten sweeps: record launch and retries across three records can consume earlier sweeps before the third sibling gets a turn.
The test now waits for all five observable attempts, up to twenty sweeps, preserving the four-second outer bound on every sweep and the existing recovery/no-duplicate assertions.
Only this test was changed; runtime code was unchanged by the test phase.

No GUI surface changed; CLI and persisted-channel transcripts are the product evidence.
No production home, session, dispatcher, sign-in, or fleet machinery was used.

Final results: the revised complete targeted walk-request test file exited 0, including the slow-send fairness, dot-home, cross-home alias, disclosure-boundary, and recovery checks. The targeted timeout-library test file exited 0. The live path/carrier driver and live checkpoint probe both exited 0. All disposable home and probe files were removed; only the intended test fix remains modified in the worktree.
