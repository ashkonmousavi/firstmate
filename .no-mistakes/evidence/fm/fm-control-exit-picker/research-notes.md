# Exit-picker live validation notes

Scope: test phase for target 1cab3b7bf00a624572b5eecab0f60672d699aebb, base 22e62abe5e435f9d087230b3ac856d2cc5e4d005.

Read the existing research-book index and claude-exit-backgrounds entry before the live work. Official reference: https://code.claude.com/docs/en/interactive-mode#background-bash-commands . The vendor documents tracked background Bash tasks; the expected completion-authority rules come from the recorded human decision supplied to this run, rather than from vendor documentation or implementation code.

Observed in this run: Claude Code 2.1.316 renders “Background work is running” with “Exit and stop tasks” selected while a real background sleep is alive. The base control script refuses that same picker for a Done task. The target confirms it and the owned Claude and background sleep stop. Explicit landed-work and validated lane release also stop workers whose disposable backlog row remains In flight.

Fault oracle: freezing only the owned Claude process leaves its real terminal present but prevents it consuming the confirmation. The target returns exit 1 with agent-state=alive and does not claim stopped. Resuming that process allows its queued exit to finish and the shell is verified stopped.

Guard coverage: existing tests/fm-control.test.sh was run through bin/fm-test-run.sh and returned exit 0. It covers delayed picker rendering and revalidation races as regression fixtures; these fixtures are supplemental and are not claimed as live harness proof. The pending-proof merged-PR instruction is a skill document; the live checks here exercise its explicit --landed-work control boundary without opening or changing a real forge PR.

Herdr isolation: every Herdr lifecycle action used bin/fm-herdr-lab.sh and a named fm-lab session, with the helper’s default-session tripwire. Provision performs prepare internally. Keeping the live test within the provisioning command’s process lifetime avoids the execution host ending its background server between commands. Stopping the named lab before teardown avoids a stale foreground-client detach report. No fleet pane or default-session lifecycle action was used.
