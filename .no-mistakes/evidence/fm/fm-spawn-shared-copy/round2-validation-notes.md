# Shared-copy live validation, final target

Date: 2026-11-03. Target: ec1cd2b1c9646fb19a1e77e2542fde46dd1f5140.

## Evidence and independent expectations

The acceptance oracle is the recorded intent: each retained record protects its physical copy; allocation/reuse must refuse a collision; cleanup must preserve a different recorded branch even with force; ordinary foreign-claim cleanup must retire the two finished records without touching the current designer. Recorded decisions also require retained secondmate-home reuse, preserved ownership after failed dispatch, and removal of the extra custody-transfer option.

Research book: no entry is available in this worktree (data/research-book is absent); other project clones were not read. Primary sources consulted through Exa on 2026-11-03:

- https://github.com/kunchenguid/treehouse : native durable leases survive zero running processes; state-only lease takeover preserves work when the original interactive shell exits.
- https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/internal/config/config.go : explicit roots resolve with the .treehouse component.
- https://raw.githubusercontent.com/kunchenguid/treehouse/v3.1.8/cmd/lease.go : lease resolves and protects the registered existing slot without resetting its checkout.

The installed CLI reports v3.1.8. Native tests use that actual binary, public Firstmate scripts, real Git repositories, and dimensioned private tmux servers. Harmless raw sleep workers consume no model tokens. No real model-harness behavior, Herdr lifecycle, or macOS compatibility is claimed.

## Live scenario receipts

| Observable result | Product evidence |
| --- | --- |
| Default and configured-root interactive spawns acquire native durable leases, survive endpoint exit with branch and edits intact, and allocate a separate copy next time | round2-native-default.log, round2-native-explicit.log |
| A legacy process-only held reservation becomes leased in place before another allocation; its branch and edits survive shell exit | round2-legacy.log |
| Capped and uncapped same-ID retries retain the original record, lease and edits without allocating a replacement | round2-cleanup.log |
| Fresh spawn, direct/transactional relaunch and promotion refuse duplicate records before mutation | round2-expanded-boundaries-final.log |
| Deferred retry and a separate prepared automatic item reach real spawn and refuse shared ownership | round2-expanded-boundaries-final.log |
| Explicit home adoption and leased home seeding refuse colliding retained copies | round2-expanded-boundaries-final.log |
| Ordinary and forced cleanup refuse a mismatched recorded branch | round2-expanded-boundaries-final.log |
| The removed custody-transfer flag is rejected with records and claim unchanged | round2-expanded-boundaries-final.log |
| Missing report still refuses cleanup; after honest completion, both stale ship/scout records retire while designer HEAD, branch, untracked work, claim, native lease and record remain | round2-expanded-boundaries-final.log |
| A real tasks-axi backlog write gets EACCES after the raw worker closes its endpoint; failed spawn preserves its native lease, claim and provisional record | round2-failed-launch.log |
| Real secondmate respawn into an absent endpoint reuses its recorded home and preserves notes | round2-secondmate-live.log |
| Ordinary completed-scout cleanup returns both native leases and removes only their own records | round2-cleanup.log |

All listed native drivers completed with exit 0 in this test phase. The earlier baseline round2-live-boundaries.log also completed with exit 0. Drivers next to these logs are rerunnable from the target worktree and remove their private servers and scratch homes in EXIT traps. The retained-secondmate driver archives the exact target into disposable code storage so its home is outside that code directory while all intentional fixture writes remain inside the assigned worktree.

One expanded-driver setup attempt, round2-expanded-boundaries.log, exited 1: the automatic launch correctly skipped an item that already had a deferred request. Hypothesis: pending deferred ownership, rather than the pool guard, prevented that item from reaching spawn. A separate prepared queued item in the same isolated home disproved any product failure: its automatic launch reached the real spawn guard and refused the shared copy. The final expanded transcript includes this corrected proof and the removed-option refusal.

No UI changed; CLI transcripts and native pool state are the reviewer-visible evidence, so no screenshot was needed. No source or permanent tests were modified. No linter, formatter, static analysis, broad repository suite, pipeline control, push, PR, or CI phase was run. Dedicated fixture-suite logs are supporting non-live evidence only; they are never substituted for the native scenario receipts above.

## Cleanup

Every native driver was awaited and its exit observed. After completion, each lab directory (.l, .b, .g, .j, .f, .k, .matecheck, .q) was absent. All process IDs reported by native pool status in these runs were checked through ps and none remained. The worktree had no changes. Private tmux servers were killed by their exact lab sockets; no default terminal server, operator home, shared pool, login, or credential was modified.

## Targeted fixture receipts

The targeted runner completed with exit 0 after these five affected suites, with no gate skips. These tests use boundary adapters and are supplemental, not live harness or native-pool proof.

```text
FM_TEST_END 2026-11-03T21:36:48Z tests/fm-shared-copy.test.sh exit=0 duration_ms=22614 gate_skip=false
FM_TEST_END 2026-11-03T21:39:28Z tests/fm-spawn-pool-base-freshen.test.sh exit=0 duration_ms=159887 gate_skip=false
FM_TEST_END 2026-11-03T21:40:46Z tests/fm-secondmate-liveness.test.sh exit=0 duration_ms=77730 gate_skip=false
FM_TEST_END 2026-11-03T21:42:51Z tests/fm-project-capacity.test.sh exit=0 duration_ms=125751 gate_skip=false
FM_TEST_END 2026-11-03T21:43:16Z tests/fm-rovo-harness.test.sh exit=0 duration_ms=24198 gate_skip=false
```

Command: `env -u TMPDIR bash bin/fm-test-run.sh --jobs 1 tests/fm-shared-copy.test.sh tests/fm-spawn-pool-base-freshen.test.sh tests/fm-secondmate-liveness.test.sh tests/fm-project-capacity.test.sh tests/fm-rovo-harness.test.sh`.

No baseline command was supplied or run before this phase; the complete executed scope is documented above and in the structured result.
