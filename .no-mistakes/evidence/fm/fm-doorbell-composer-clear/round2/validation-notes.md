# Live validation of 8b3cc822475440b75bc0582e0704cc274d4fc667

All final targeted checks and live scenarios passed. No tracked source or test changes were needed.

## Oracle and results

The supplied intent requires freeing an own-doorbell composer without submitting the doorbell, altering foreign drafts, losing steering records or discarding unpublished work. Claude documents line-end positioning and repeated deletion: https://code.claude.com/docs/en/interactive-mode#text-editing . The research-book index and prior ghost-composer entry were consulted; prompt suggestions were disabled. Exa supplied primary vendor references. Kimi token-file isolation followed https://moonshotai.github.io/kimi-code/en/configuration/env-vars and https://github.com/MoonshotAI/kimi-cli/blob/bfd9d273/src/kimi_cli/auth/oauth.py .

Real Claude Code 2.1.314 passed 20-column interrupt from one character left and exit from the middle of its doorbell. Interrupt retained the agent; exit stopped it; both retained endpoint/inbox without submitting the doorbell. Stronger relaunch reached a real replacement Claude composer, retained three unread records, and retained the exact unpublished commit as replacement HEAD (relaunch-three-fixed/relaunch-preserved-state.txt). Retained transport proves no Enter preceded the literal /exit command (relaunch-transport-check.txt).

Real Claude on Herdr 0.9.5 passed moved-cursor interrupt/exit, foreign-draft preservation and independent exit proof. driver-herdr.sh uses bin/fm-herdr-lab.sh provision/run/teardown and a named non-default fm-lab session. Teardown verified the read-only default-session tripwire and exited 0.

Cursor 2026.10.19-6bbf2c4, Codex 0.159.3, Pi 1.0.0, Grok 1.0.70, Kimi 2.4.1 and omp 18.2.7 passed real interrupt/exit and ownership guards. Refused exits preserved human text, another task's doorbell, appended human text and literal stop-hint text. AGY 1.4.12's deliberately unreadable surface preserved own and foreign drafts, refused exit with no lifecycle input and retained the agent; successful clearing is not claimed for that surface.

A real Claude session with injected post-edit capture failure refused exit after exactly one Ctrl+E/Ctrl+U pair, submitted nothing and retained its agent/inbox (unreadable-corrected.log). Only the external transport failure was injected; product and terminal were real.

The full composer, control and lifecycle-input test files exited 0. Targeted selections from task-inbox (persistent unreadable, transient redraw, narrow widths) and Herdr backend (eight suffix/paste/unreadable-recovery cases) exited 0. These are supplementary deterministic checks, not live evidence. Private tmux grids were explicitly 220x50, narrowed to 20x50 for Claude.

## Corrected fixture attempts

Initial setup failures were corrected and re-driven: isolated Herdr config needed the existing default-session tripwire; Codex needed disposable-checkout trust; Kimi needed its separate existing token file; omp needed default Unicode footer furniture, quiet startup and disabled project MCP configuration; AGY onboarding completed with interaction-data collection unchecked. Stronger relaunch needed fixture-only trust for newly created Git paths. The injected capture failure initially bypassed the fault through a trace wrapper; tracing was disabled for the corrected successful run. Initial failed attempts are retained in logs, not claimed as successful checks.

All homes, account copies, Git fixtures, temporary scripts and Chrome profiles were created inside the worktree. No production credentials, global configuration or source files were modified. Every required final child was awaited to exit 0. Private tmux servers, named Herdr labs and Chrome children were stopped. The PNG renders actual terminal captures; HTML and ANSI retain their full text. No full repository suite, lint, formatter, static analysis, push, PR, CI or pipeline-control phase ran.
