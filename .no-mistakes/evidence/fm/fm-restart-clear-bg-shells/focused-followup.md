# Focused test-phase follow-up

The selected finding requests three real restart scenarios, with an explicit instruction to leave the lab guard and fm-send unchanged and report scenarios as untested if the guard refuses restart's own FM_STATE_OVERRIDE.

Reproduction: `python3 ~/.no-mistakes/evidence/01M6A1RBDBTX6W12NDNV591RNK/live-refusal-driver.py` exited 1 on its cleanup-reason assertion.
The actual restart exited 3 before persist delivery, reporting the gate-worktree refusal instead of a background-cleanup reason.
The private real Claude pane and its background sleep were started successfully, but the parent report was missing because persist delivery was refused.
The driver's finally block stopped its private tmux server and removed its disposable lab.
See running-restart.txt, running-before.txt, and running-after.txt for current raw evidence.

Root cause of incomplete live verification: restart invokes fm-send with its own nonempty FM_STATE_OVERRIDE, which the supported marked-lab allowance rejects.
This is a test-environment authorization incompatibility, not evidence that the cleanup behavior failed.
The successful-cleanup restart, surviving-shell deadline, and unreadable-screen restart scenarios remain UNTESTED LIVE because they share this blocked prerequisite.
No guard, fm-send, production home, registered mate, shared tmux server, or fleet configuration was changed.

Focused verification: `TMPDIR=/tmp bash tests/fm-secondmate-restart.test.sh` exited 0.
T17 and T19 proved local/remote wait-before-exit through modeled transports; T18 proved local/remote surviving-shell and unreadable-capture refusal with no exit or relaunch.
These are portable behavioral checks, not live restart evidence.

Focused live verification: `FM_RESTART_BG_SHELLS_LIVE=1 FM_RESTART_BG_SHELLS_LIVE_EVIDENCE_DIR=~/.no-mistakes/evidence/01M6A1RBDBTX6W12NDNV591RNK bash tests/fm-secondmate-restart-bg-shells-live-e2e.test.sh` exited 0 with Claude Code 2.1.316 and tmux 3.4.
All three remaining guard checks passed: status row reports one shell, the real cleanup sentence stops that process and clears the row, and /exit closes Claude without a picker.
The refreshed shell-running.txt, shell-stopped.txt, and claude-exited.txt retain the actual captures.
Official external contract: https://code.claude.com/docs/en/interactive-mode#background-bash-commands describes background task IDs, task stopping, and exit cleanup (checked through Exa).

The existing test-only worktree changes were preserved: the shared fixture-cleanup EXIT trap is no longer replaced, and the live guard optionally retains pane captures.
No additional source change is justified by the reproduced gate refusal under the recorded bounded decision.
Both targeted test processes completed, and the live guard removed its lab and socket.
No full-suite, lint, formatter, static-analysis, pipeline-control, push, PR, or CI command was run.
Overall live restart verdict: inconclusive; all three selected full-restart scenarios remain untested.
