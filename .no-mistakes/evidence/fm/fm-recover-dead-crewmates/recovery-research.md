# Recovery live-validation research

Upstream tmux maintainer evidence distinguishes an absent socket from an absent process: [tmux issue 2222](https://github.com/tmux/tmux/issues/2222) explains that external socket deletion can leave a server alive, and that `-S` or `TMUX_TMPDIR` chooses a separate socket. [Issue 4640](https://github.com/tmux/tmux/issues/4640) documents the same socket-cleanup failure class.

Consequently this validation did not treat a failed tmux inventory alone as absence proof. It used isolated real sockets with seeded prior-boot generations for positive recovery, and malformed/current/future generation records as adversarial cases. A physical host reboot was not performed.

The real no-mistakes status reader was exercised with disposable SQLite records representing attributed running, parked and terminal runs. No no-mistakes daemon, pipeline initialization, validation, push, PR, or CI command was run. These records are fixture data; the consumers were the installed real CLI and tracked Firstmate executables.

All intentional fixture data stayed under the gate worktree. Normal Codex authentication was reused through a link in the disposable Codex home; configuration, trust decisions and session data stayed in that home. Lab homes and private tmux servers were removed after each run.

The first ship proof succeeded but its cleanup encountered read-only generated hook directories. Cleanup was corrected to make only disposable directories writable; the ship scenario was re-driven with successful cleanup. A manual deferred-stage setup using a shell PID correctly downgraded to read-only; the confirmed run used the actual harness anchor and published locked=1, phases=probe,sweeps, rc=0.

Oracle: the supplied intent and recorded decisions require preserved unlanded work, no duplicate healthy agent, no relaunch of attributed pipeline work, fail-closed uncertain absence, and serial capacity-bounded recovery stopping at the first refusal. The retained CLI transcripts show those observable outcomes.
