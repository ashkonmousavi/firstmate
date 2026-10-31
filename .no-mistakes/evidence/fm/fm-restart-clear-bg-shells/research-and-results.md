# Restart background-shell validation

Primary source: https://code.claude.com/docs/en/interactive-mode#background-bash-commands documents real background Bash task IDs, task stopping, and exit cleanup.
The existing research-book entry claude-exit-backgrounds.md was consulted before the live checks.

The real Claude Code 2.1.316 / tmux 3.4 guard completed with exit status 0.
Its retained running/stopped/exited pane captures demonstrate that the request stopped the actual shell and /exit then closed Claude without the picker.

Both targeted portable commands completed with exit status 0:
- bash tests/fm-composer-lib.test.sh
- bash tests/fm-secondmate-restart.test.sh

The separate marked parent/mate lab used a private tmux socket and a 180x45 terminal, with a real Claude process and a verified running background shell.
The actual restart CLI exited 3 because its fm-send call was refused by the gate before the persist request was delivered.
Consequently cleanup ordering, timeout refusal, and unreadable-capture refusal remain untested live.
The portable tests exercise all three, including remote capture failure propagation.
No lab guard, fm-send implementation, registered mate, default session, or production credentials were changed.

The manual lab driver initially exited 1 during teardown because Claude was finishing writes to its disposable config after the tmux server stopped.
A follow-up process inspection found no surviving process with the unique lab path; the leftover directory was then removed successfully (teardown.txt).
The retained replay script is the exact driver executed, including that original cleanup implementation.
No repository source or tests were modified.
