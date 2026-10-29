# Background-exit validation

Read the existing research-book entry `claude-exit-backgrounds.md` before testing.
Checked the current vendor lifecycle contract at https://code.claude.com/docs/en/agent-view and settings precedence at https://code.claude.com/docs/en/settings.
The independent acceptance oracles are the recorded owner decisions and the observable process/lifecycle properties below.

- Without protection, background work plus exit must offer handoff and leave a session: the positive control prevents a vacuous pass.
- With protection, exit must end Claude and its shell without creating a background session.
- After respawn and stop, original carried work must still be alive before cleanup, then be gone after public `fm-control exit` succeeds.
- Exact-folder cleanup must leave the neighboring live session and shell alive.
- Whole-expression safeguards and the effective account must reach the final real Claude process after a failing first command and after directory changes, including a spaced account path and environment filtering.
- Crew, scout, secondmate, and relaunch paths must all retain those safeguards and matching cleanup metadata.

Current successful evidence is `bg-live.log`, `bg-scope-live.log`, `spawn-live-final.log`, `spawn-live.json`, and `spawn-matrix-confirmed.log`.
`account-regression.log`, `spawn-live.log`, `spawn-live-confirmed.log`, and `spawn-matrix-current.log` retain superseded setup attempts: nested secondmate homes are refused, the initial advisor assertion incorrectly applied the worker-only rule to a secondmate, and the initial process observer sampled the failing invocation before fallback.
Those were corrected through a nested disposable source snapshot, worker-only advisor expectations, and waiting specifically for the final `claude --model haiku` process.
No product source was changed.
The operational research book is outside the authorized write boundary; this report retains the evidence instead.

The final canonical Haiku ship/scout launch check is `current-haiku-canonical-confirmed.log`; both actual Claude process argument lists include `--model haiku --advisor opus` and both safeguards.
The first canonical setup had one worker lane and deferred the scout; giving the disposable fixture two lanes allowed both real launches.
All required children completed with exit status zero after setup corrections, and all private tmux servers and recorded live shells/Claude processes have stopped.

To reproduce the evidence drivers from this worktree, create `.validation` and, for the snapshot-based drivers, copy `bin/`, `.agents/`, and `.tasks.toml` into `.validation/product/`; use `TMPDIR="$PWD/.validation"` for the regression drivers and `EVIDENCE` set to the assigned evidence directory for the background-exit drivers.
The background-exit drivers additionally require `FM_CLAUDE_BG_EXIT_LIVE_E2E=1`, the installed Claude login, and tmux.
