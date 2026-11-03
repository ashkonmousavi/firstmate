# Owner-park proof and test isolation

The independent oracle is the supplied owner intent: a durable owner decision must survive recovery and only explicit unpark clears it. The CLI transcript records actual park/status/restart/spawn/control/bootstrap/watch behavior with real tmux inventory in a marked disposable home. The receiving-home proof runs the actual remote-inherit receiver and then actual spawn using the mirrored record; it does not claim a successful SSH round-trip or a real Claude session. SSH error handling uses the actual OpenSSH client against a reserved, non-listening loopback port, with isolated SSH configuration and no login attempt.

Primary sources: [OpenSSH ssh(1)](https://man.openbsd.org/ssh.1) documents remote-command status versus error exit 255; [ssh_config(5)](https://man.openbsd.org/ssh_config.5) owns keepalive/disconnect settings. A connection error is not publication acknowledgement. Observed park and unpark both return failure and retain the local park when actual SSH fails.

Replay from the target worktree:

```
python3 ~/.no-mistakes/evidence/01M6GJ8YJKZ2XE36Z9WMW993A5/live-owner-park.py
python3 ~/.no-mistakes/evidence/01M6GJ8YJKZ2XE36Z9WMW993A5/live-remote-ack.py
```

The scripts assert persisted records, permissions, refusal exit codes, actual missing/dead tmux endpoints, absence of launch attempts, waiting for transaction locks, explicit unpark, and remote generation ordering. Both clean their disposable homes and processes.

The initial regression runs used TMPDIR inside the repository. Existing safety checks reject secondmate homes inside the repository, so liveness/restart first failed in setup. Moving fixture data to the explicitly permitted evidence directory fixed that setup: the complete liveness suite passed, and the owner-park restart and watcher cases passed. The initial full watcher suite also hit an existing stale-wake polling timeout; its precise failing case passed on focused rerun together with the new owner-park case.

The restart suite stopped at its existing whole-command <6-second timing assertion (18/19 seconds), before reaching the new owner-park case. Independent inspection confirmed the earlier behavioral assertions succeeded and that its timer also includes persistence, screen capture, and dispatch before the configured verification deadline begins. The same existing case passed for both base and target in equivalent disposable tracked repositories. It also passed from the original gate worktree after removing the nested disposable source/fixture copies. This establishes sensitivity to test context, not an observed owner-park failure. The new owner-park restart case was run separately and passed. No permanent test expectations were changed.

All recorded operational changes to real eel-web were excluded by the supplied human decisions and workspace boundary. No fleet home, credentials, server, laptop, or default multiplexer session was modified. No UI changes require screenshots. No source files changed during this phase.
