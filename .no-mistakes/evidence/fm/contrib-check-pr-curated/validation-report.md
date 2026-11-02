# Contributions poll runtime validation

Target: `2c738da60533f1a9e62267f1c57f2600ce2830fc`; base: `f145078aeb3f3068169dd29ca7a1f03839fa8ec0`; platform: Linux.
No product source or permanent tests were edited.
No linter, full repository suite, publication, CI, or harness lifecycle phase was run.

## CLI proof

- Base poll exceeded a four-second watcher bound on 400 saved records and required termination.
- Target poll with `FM_CHECK_TIMEOUT=4` returned exit 0 and exactly `contributions: scan skipped (time budget exhausted)` in 1.076 seconds.
- Target retry with the ordinary bound completed silently in 6.001 seconds.
- All 400 records remained byte identical throughout.
- Under the small bound, `pending` completed its full 2.370-second read and returned the sentinel in the last owner; canonical `snapshot --all` completed its full 2.428-second read with known=400, checked=400, rows=400 and complete=true.

Actual stdout/stderr, canonical snapshot input, full snapshot and record digests are retained beside this report.

## Targeted matrix

`TMPDIR=/tmp bash .contrib-live-validation/driver.sh` executed 68 existing contributions test functions and returned exit 0.
The sole omitted case is the approved existing timing lower-bound exception `test_unmeasured_url_does_not_starve_the_tail`; assertions and permanent tests are unchanged.
Exact executed drivers and collector are retained as `executed-*` files.
To replay the selection from another target checkout: `python3 replay-targeted.py EVIDENCE_DIRECTORY`.

Cases covered nine delayed scan stages, one-scan live refresh, lock timeout/retry, concurrent terminal PR/issue settlement, new/existing owners, acknowledgement/verdict/retirement/ownership changes, 18 publisher cancellation variants, Perl/timeout/gtimeout selection, generated shims, shared URLs, conditional reads, transient and genuine failures, unsupported URL cleanup, review compaction and parent coverage.
`cli-state-evidence.json` preserves product output and durable state from 123 disposable homes.
`disposable-cli-records.tar.gz` retains the original records, CLI output, generated check shims, external-boundary call transcripts and process identities.
Generated shims identify the actual fixture roots; all those roots were absent after test-library teardown.

Forge-response cases used external-boundary fixtures while executing the real CLI, filesystem updates, locks and process signals.
This proves local product behavior, not real GitHub availability or server-machine timing.
macOS, fork-only publication and remote CI remain owned by the outer pipeline.

## Corrected setup attempts

The first matrix nested fixture homes inside the repository, correctly triggering its secondmate-home refusal in three tests.
All three passed using the test library's normal temporary directory.
The first collector rejected deliberately malformed test data; the corrected collector retained those cases and the completed matrix was recaptured.
The first manual snapshot had a hand-built backlog with the wrong shape; the successful rerun used `fm-fleet-snapshot.sh --contribution-input`.
Initial evidence remains under `initial-*` and `cross-home-*` names.
One initial natural deadline cancellation emitted an arithmetic diagnostic on stderr with exit 0 and unchanged state; the completed manual run had empty stderr for all four calls.
