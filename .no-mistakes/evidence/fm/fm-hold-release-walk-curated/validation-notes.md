# Live validation evidence

Target: 8797976169b061d3deed2b93d5e32036d52b8f1c; base: c07d32f373ad2884ffa7b680624c73db15772ec0.

Ten isolated product scenarios passed. `live-scenarios-final.json` supersedes the two initial driver assertions described below. No project source or test files changed. All manual product commands were awaited and all disposable marked homes were removed. No primary, real fleet pane, production credential, Herdr session, or real walker dispatch was used.

## Commands and completion

| Command | Actual exit | Outcome |
| --- | --- | --- |
| `TMPDIR="$PWD/.test-phase/tmp" bash tests/fm-hold-release.test.sh` | 1 | Setup: peer handoff correctly refuses a destination inside the source repository. |
| `TMPDIR="$PWD/.test-phase/tmp" bash tests/fm-walk-request.test.sh` | 1 | Setup: approved brief paths reject hidden ancestors, including `.no-mistakes`. |
| `TMPDIR=/tmp bash tests/fm-hold-release.test.sh` | 0 | Targeted hold regressions completed. |
| `TMPDIR=/tmp bash tests/fm-walk-request.test.sh` | 0 | Targeted carrier and dispatcher-boundary regressions completed; dispatcher/transport fakes are not live Grok evidence. |
| `TMPDIR=/tmp bash tests/fm-remote-delta-read.test.sh` | 0 | Targeted delta contract checks completed. |
| `python3 live-validation.py` | 1 | Eight scenarios passed; two driver assertions needed corrections below. |
| `LIVE_RECHECK=1 python3 live-validation.py` | 0 | Only the two affected scenarios re-driven; both passed. |

`live-validation-initial.py` preserves the initial driver. `live-validation.py` is the corrected replayable driver, stored here as evidence rather than project source. Run it from this worktree using its evidence-directory absolute path. It creates disposable test-toolchain fixtures under `/tmp` following `bin/fm-lab-home.sh create` and removes them in `finally`.

## Independent oracles and rejected wrong behavior

- The author's hold contract requires event/date guards, a durable decision on activation, once-only announcement, and disposition through release or re-hold. Public CLI results, the real watcher, wake drain, and persisted status/inbox contracts provide the observations. A missing wake, automatic release, repeated episode, or premature decision closure fails these checks.
- GitHub's public REST response independently confirms `cli/cli#14854` merged at `2026-10-28T09:58:30Z`, more than 24 hours before this run. `public-pr-oracle.json` retains those fields. Product evaluation used its ordinary `gh` path with no replacement. Open `#14846`, closed-unmerged `#100`, and nonexistent `#999999999` reject false readiness.
- Cache-loss/stale-cache fixtures retain the real committed native hold. A previous met condition must never override a new unmet condition. Task moves and upload/receipt use the real executable interfaces and rebuild the condition without transferring a sidecar.
- The documented 64 KiB brief limit is the remote-size oracle: exactly 65536 source bytes must traverse the actual delta reader as an intact complete channel line; 65537 bytes, binary bytes, private paths and symlink escapes must be refused without a channel append.
- A missing dispatcher must be reported and returned through the real steering inbox exactly once. This succeeded with the normal `fm-send.sh`, with the terminal doorbell recorded unavailable; no model consumption is claimed.

## Corrected driver assumptions

The first marker replay observed `check: rearm-resurface`, the watcher's documented restart-recovery wake, before reaching the hold sweep. The corrected driver permits only that recovery wake before demanding the actual hold wake. The next checkpoint produced it; another checkpoint and wake drain preserved the decision, and unhold retired it. This was an assertion-order assumption, not a product failure.

This installed markdown backend emits `code: NOT_FOUND` on stdout. The first removal driver incorrectly required stderr. The corrected behavior check accepts the actual diagnostic stream and demands the observable cleanup; the real evaluator retired both record and decision. The targeted regression suite separately exercises NOT_FOUND on both stdout and stderr, and unknown-read preservation.

## Accepted remaining limitation

The successful real Grok round trip is untested. The private `fm-grok-bot-dispatch.sh` is absent from PATH and this repository and from every disposable home. This phase forbids accessing operator private data/services and moving credentials. A fake dispatcher proves only the boundary contract. A disposable authorized copy of the real dispatcher with its signed-in Grok bridge would enable the final leg. The same test-round-1 limitation was already declined as a blocking concern; no new finding is raised.

Evidence is CLI transcripts and persisted protocol output. This change has no rendered browser or native visual surface requiring a screenshot.
