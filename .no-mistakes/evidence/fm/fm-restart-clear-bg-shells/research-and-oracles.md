# Restart validation basis

Acceptance oracle: the supplied user intent and recorded SPEC-1/SPEC-2 decisions require shell cleanup before exit; surviving shells or an unreadable screen must leave the mate running, without relaunch, and return 3.

Official Claude Code background Bash documentation: https://code.claude.com/docs/en/interactive-mode#background-bash-commands and https://code.claude.com/docs/en/tools-reference . Retrieved through Exa during this run. Claude supports run_in_background, task IDs, and TaskStop; task cleanup occurs on exit. These facts justify creating a real background task and checking its PID independently of the rendered shell counter. They do not prove Firstmate restart ordering.

Read the project research index and its claude-exit-backgrounds.md entry (2026-10-29). It distinguishes exiting from handing work to a background agent, so the live guard additionally checks that Claude itself stops.

Live proof: tests/fm-secondmate-restart-bg-shells-live-e2e.test.sh launched installed Claude Code 2.1.316 in a disposable git fixture, reused existing authentication in an isolated config, and used a private tmux socket with a 180x45 grid. It checked a running shell PID, its rendered count, PID death after the stop request, count disappearance, then agent death after /exit.

A second run added a marked parent home and a secondmate record pointing to that real Claude pane, then invoked the real restart CLI without lifecycle bypass or path overrides. The command returned 3 before delivering the persist request because restart internally supplies FM_STATE_OVERRIDE to fm-send. The marked-lab allowance rejects that override. The shell remained alive. This is prerequisite refusal evidence, not a live proof of the timeout or unreadable-screen cleanup branches. The recorded decision prohibits changing fm-send or the lab guard; no bypass was attempted.

Portable regression setup: a first run with TMPDIR inside the repository failed because seeded secondmate homes are forbidden inside the repository. The test was rerun using its normal disposable temporary directory, retaining both logs. No product code or test source was changed.
