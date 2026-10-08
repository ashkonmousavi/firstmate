# Watcher checkpoint live validation, repaired output collector

Verdict: go for the assigned Test phase at b624aa5ea88e4b29134937590fab7773bb0a066b.
No source or permanent test files were changed during this phase.

## Product results

- The real installed Codex CLI ran a foreground quiet checkpoint through `codex sandbox`, returning 124.
  This is native source execution, not an interactive primary-session or loaded-fleet claim.
- One real tmux pane and 180 recorded aliases over 30 real panes closed quietly under the original three-second checkpoints.
  The long inventory continued into pane observations on later cycles.
- A distinct later lane retained its metadata and pending inbox through budget exhaustion, surfaced on the fifth resumed cycle, and produced one durable notification.
  Explicit generation acknowledgement prevented replay.
- Stopping the owned private tmux server exercised the actual capture client.
  The repaired three-second checkpoint returned quiet 124 in 2.737 seconds, before the server resumed at six seconds.
  An independent one-second pipe capture still waited 4.001 seconds until its server resumed, isolating the output-descriptor failure.
- Fresh baseline RED returned the quiet-bound error, exit 1, at 14.048 seconds.
  The repaired collector returned quiet 124 at 2.885 seconds.
  The corrected independent fault copy reinstated only the immediate parent's `fm-timeout-lib.sh`, preserving all deadline APIs, and returned exit 1 at 14.049 seconds.
  Its target GREEN and restored quiet controls returned 124 at 3.785 and 2.613 seconds respectively.
- Repeated bounded missing-mate checks retained one recovery obligation without consuming an attempt or changing custody.
  The real recovery path refused the deliberately invalid lab route and recorded one failed attempt, without inventing a successful relaunch.
- Default-grace status and bare turn-end notifications each delivered once and stayed quiet after acknowledgement.
- A real competing queue owner acquired the durable lock after the first notification append.
  The first notification remained committed through expiry, and the deferred second notification delivered once after release.
  Neither replayed after acknowledgement.
- Zero-second bounds and combining recovery mode with a quiet bound returned refusal exit 2.

## Targeted checks and evidence

`bin/fm-test-run.sh tests/fm-watch-checkpoint.test.sh tests/fm-timeout-lib.test.sh tests/fm-wake-checkpoint-publication.test.sh --json <evidence>/targeted-tests.json` completed with exit 0 and no gate skips.
The automated checks include controlled backend and recovery fixtures; they are supplemental to the real tmux and native Codex product evidence.
No full repository suite, linter, formatter, static analysis, delivery phase, or CI phase was run.

The first fault-driver setup accidentally installed the baseline timeout library, which predates the new checkpoint APIs, and therefore did not create a valid output-collection fault.
That attempt remains in `r2-slow-read-controls.json` and its log.
The corrected isolated fault above uses the immediate parent implementation and is retained in `r2-output-owner-controls.json` and its log.
This was a verification setup correction, not a product failure.

Product transcripts and exact repeatable drivers are the `r2-live-checkpoints`, `r2-live-handoff-signals`, `r2-live-publication`, `r2-output-owner-controls`, and `r2-live-backend-resume` files.
Fresh baseline RED is retained in `r2-slow-read-controls.json`.
All disposable homes, source copies, private tmux servers, and socket directories were removed.
The CLI and durable records are the changed user surface; no rendered UI changed, so screenshots were not required.
Current-head PR/CI, merge, and loaded-home adoption remain outside this assigned phase.
