# Watcher checkpoint live validation

Verdict: no-go.
Source and permanent tests were unchanged.
All disposable homes, private tmux servers, socket directories and baseline/fault source copies were removed.

## Blocking result

The new bounded read can time out its process while its caller still waits for captured stdout.
With a real private tmux server stopped by SIGSTOP, the target's three-second checkpoint returned exit 1 after 14.061 seconds with `checkpoint: watcher exceeded the quiet bound without a clean close`.
The base reproduced the same original symptom, and an isolated target copy with the old watcher reinstated also failed.
Fresh short controls before and after returned quiet exit 124.
These controls are in `slow-read-controls.json` and `slow-read-controls.log`.

The target trace entered `fm_checkpoint_read` with a two-second budget and its timed runner returned 124.
The tmux capture client disappeared around the deadline, but the enclosing watcher remained alive until the outer watchdog.
The trace and owned process trees are in `stalled-tmux-trace.log`, `stalled-client-lifetime.json`, and `stalled-reader-process-trees.json`.

An independent causal probe resumed the stopped server at six seconds.
The three-second checkpoint then returned quiet 124 at 6.015 seconds, rather than at its deadline.
A separate one-second `timeout` around the real tmux capture inside a shell command substitution returned only at 4.001 seconds when its stopped server resumed.
This isolates the output-pipe lifetime from missing deadline propagation or client process escape.
See `live-backend-resume.json` and `live-backend-resume.log`.
The new read owner must also bound collection of stdout, preserving unknown observations and the original checkpoint budget.
This is a distinct failure of a read that received its cap, rather than reopening the declined inventories of uncapped reads or locks.

## Passing product scenarios

- Installed Codex CLI 0.160.1 ran the real foreground checkpoint through `codex sandbox`, returning quiet 124.
- One real pane and 180 recorded aliases over 30 real panes closed quietly, with continuation eventually entering pane observations.
- A later owned lane survived exhaustion and produced one durable permission-prompt wake after four resumed cycles in the retained run.
  Its metadata and pending inbox bytes stayed unchanged, and its generation acknowledgement prevented replay.
- A real missing endpoint queued one recovery obligation across repeated bounded calls without consuming an attempt or changing custody.
  The real `--recover` path surfaced a refused spawn as a durable failed outcome, without inventing success.
- Real status and bare turn-end files delivered once under the default signal grace, then stayed quiet after generation acknowledgement.
- Real queue contention after the first signal publication deferred the second signal until the next cycle.
  The first acknowledged file never repeated, the second delivered once, and both then stayed quiet.
- Zero-second bounds and combining `--recover` with `--seconds` returned argument refusal exit 2.

Product transcripts are in `live-checkpoints.json`, `live-handoff-signals.json`, and `live-publication.json` and their matching logs.
The Codex probe proves execution under the native CLI sandbox, not an interactive primary session, installed fleet adoption, or current-head CI.
The recovery probe proves refusal reporting and pre-mutation handoff, not a successful native secondmate launch.
PR, CI, merge and loaded-home acceptance remain owned by the outer executor and Main.
No rendered UI changed, so CLI and durable-state evidence were retained instead of screenshots.

## Targeted automated checks and setup attempts

`bash tests/fm-watch-checkpoint.test.sh` and `bash tests/fm-wake-checkpoint-publication.test.sh` both exited 0.
Their logs are retained, and their fake backend or spawn fixtures are not classified as native live proof.
No full suite, linter, formatter or static analysis was run.

Initial manual-driver assertions expired before pane coverage, imposed too short a cycle allowance on the 180-record fairness witness, or expected quiet while a different real idle pane or downtime recovery was actionable.
Those attempts are retained separately and do not qualify as passing scenarios.
The smaller later-lane witness, separate restored controls, handoff/signal driver and post-publication contention driver supplied the final product evidence.
The original shell contender missed the narrow between-appends window; a real Python owner acquired the documented queue lock after the first append and drove the intended interruption without replacing the product.
