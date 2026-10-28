# Backstop exit-76 live validation

The oracle is the supplied intent: three reissues per read, the same offset and prefix on each reissue, four useful windows per pass, durable cursor progress on failure, and an alarm only after consecutive failed passes.

The real backstop CLI, fm-on router, remote job worker, delta reader, file reader, timestamp parser, and durable inbox ran in disposable workspace homes. A local transport adapter replaced SSH delivery with the real queue staging/wait APIs; no fleet service or operator home was accessed. A disposable Perl wrapper waited at the reader snapshot boundary while a real non-preemptible command was queued for the same home. The real worker generated each exit 76; the adapter did not synthesize results.

| Scenario | Observed product behavior |
| --- | --- |
| One preemption | Exits 76, 0, 75; first two argv identical; multiline reply consumed; no read failure. |
| Three preemptions | Exits 76, 76, 76, 0, 75; fourth attempt succeeds at unchanged cursor. |
| Four useful windows | Exits 76, 0, 76, 0, 76, 0, 76, 75; three data windows and tail observation complete in one pass. |
| Persistent preemption | One successful window followed by exactly four exits 76; first failed pass tolerated. Next pass has exactly four exits 76 and writes REPLY DELIVERY UNVERIFIED to the real durable inbox. Offset, prefix and pending timestamps survive unchanged. |
| Recovery | Removing contention resumes at the saved cursor, reaches the tail, and clears the read failure and incident. |

`live-transcript.log` retains CLI output, call arguments, exits, timings, and persisted state for each pass. `durable-alarm.txt` is the actual persisted inbox record. `final-cursors.json` contains the final journals. The worker exited with status 0 and was awaited.

The first setup used a fixed three-second tool delay, which occasionally expired before preemption. Its logs are retained as `initial-*`; replacing that delay with the boundary wait made the above final run deterministic. This was a setup race, not a product failure.

To reproduce from this worktree: `python3 ~/.no-mistakes/evidence/01M615XS1Y6YNQK6X4ABEX9M6G/live-driver.py`; remove `.test-exit76` afterwards. The script requires bash, Python, git, Perl, and the usual Unix tools already on PATH. It starts the worker directly with --serve and awaits it; it never installs a service.

The eight initial focused tests and all 66 tests in `tests/fm-main-backstop.test.py` passed. The two new regressions failed against the base executable (missing retry; one attempt instead of four). Final source-integrity and cleanup checks passed. No project source changes were needed.
