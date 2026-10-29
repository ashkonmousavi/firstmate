# Claude carried-work cleanup evidence (2026-10-29)

The official lifecycle contract says carried background shell commands survive session-process restarts and stop when the session is deleted: https://code.claude.com/docs/en/agent-view#the-supervisor-process.
The official deletion description is https://code.claude.com/docs/en/agent-view#what-deleting-a-session-removes.
These were checked through Exa in this run; the project research-book entry `claude-exit-backgrounds.md` was also read.

Hypothesis: disappearance from the session list after `claude rm` proves carried work stopped.
Disproof: `respawn-confirm.log` records a real respawn, stop, Firstmate exit and ten-second wait.
The original non-zombie sleep process retains its PID and exact start time despite the background session disappearing and Firstmate reporting success.
The neighboring session and shell remain alive.
The unchanged opt-in repository guard independently fails the same shell-termination assertion.

This run used disposable lab folders and private tmux servers; cleanup traps stopped their sessions and identity-matched background shells.
No product source was changed.
This evidence note stays in the assigned test evidence directory because this phase may not update the operational research book outside its worktree.
