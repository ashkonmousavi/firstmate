# Restart shell-cleanup live validation

Official contract: https://code.claude.com/docs/en/interactive-mode#background-bash-commands documents background task IDs, stopping tasks, and exit cleanup.
The existing research-book entry `claude-exit-backgrounds.md` records the exit picker and background handoff behavior.
The observed installed version was Claude Code 2.1.316 with tmux 3.4.

The opt-in live guard started a real authenticated Claude session with a background sleep, confirmed the rendered shell count, delivered the actual persist-request cleanup sentence, independently verified the process stopped, observed the count clear, and observed Claude exit without the picker.
The live guard completed with exit status 0 and removed its isolated config, worktree, socket, and session.

A separate driver minted a fresh marked home with bin/fm-lab-home.sh, launched real Claude on its private tmux socket with a 180x45 grid, and attempted the actual fm-secondmate-restart.sh command.
The command could not deliver its persist request because it invokes fm-send.sh with FM_STATE_OVERRIDE set to the marked lab's own stock state directory.
The lab allowance in fm-gate-refuse-lib.sh rejects every nonempty FM_*_OVERRIDE.
Removing ambient overrides did not help: the restart command itself supplies this one.
A Herdr lab does not solve this local fm-send guard, and the host-local remote capture verb also requires session fm-remote rather than an allowed fm-lab-* session.
No production sessions, remote homes, or credentials were modified; no gate bypass was used by the manual driver.
The driver stopped its private tmux server and removed the lab in its finally block.
The refusal prevented the deadline and unreadable-screen cases from reaching their intended product boundary, so those full live scenarios remain untested.
Live completion requires a supported lab route that accepts explicit stock-layout state paths or omits redundant overrides; this is outside this test phase's source-fix authority.

The targeted restart suite completed all behavioral assertions with exit status 0; its provider and SSH are modeled, so its outcomes are supporting evidence, not live scenarios.
The first attempt had TMPDIR inside the source worktree, which correctly triggers the separate prohibition on secondmate homes inside the repository; rerunning with the suite's normal /tmp layout resolved that setup issue.
The targeted composer suite completed with exit status 0.
Neither the full repository suite nor any linter or static analyzer was run.

Two test-only changes remain in the worktree: remove the restart suite's replacement EXIT trap so tests/lib.sh can clean its registered read-only fixture directories, and add an optional evidence directory to the live guard to retain actual pane captures.
After these changes the targeted restart suite completed with exit status 0 and no fixture-removal errors (`restart-targeted-cleanup-fixed.log`).
The live guard completed again with exit status 0 (`claude-live-guard-captured.log`) and retained `shell-running.txt`, `shell-stopped.txt`, and `claude-exited.txt`.
The initial gate-driver attempt exited 1 on its setup assertion; its exact CLI refusal is retained in `running-restart.txt` and its successful teardown in `live-refusal.log`.
No live failure is asserted for the restart behavior: it was never reached in that attempt.
All required check children have exited; no disposable test server or lab remains running.
Worktree-local transient fixtures and the exact old /tmp fixture retained by the replaced trap were removed.
