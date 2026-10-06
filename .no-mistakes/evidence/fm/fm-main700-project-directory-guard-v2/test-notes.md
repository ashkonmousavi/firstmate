# Test evidence for project-directory guard

Public transport and policy behavior passed on target 7db498716d77d0032384bb658f473bec48b28561.
The base public transport denied `cd bin` and `cd ..`; the target allows them while retaining protected-project denial.
The targeted behavior suite passed with only its prohibited lint invocation omitted.
No lint, formatter, static-analysis, or complete repository suite was run.

Native Claude Code 2.1.292 passed chained destinations and actual persistent cwd changes.
Native Pi 1.0.0 passed with the real extension and callback ctx.cwd.
Native Codex 0.160.0 passed session-cwd cases after session-only project trust was supplied.
Early Codex attempts lacked project trust and did not load the local hook; those were setup failures, repaired before validation.
The final Codex run retained the Bash matcher and exercised explicit exec_command workdir values.
Codex's final PreToolUse payload contained only tool_input.command and the session cwd, omitting the execution workdir.
The command `cd ../projects/foo` executed from the lab bin directory and created DENIED_SENTINEL, whereas an unrelated `cd projects/foo` from outside was blocked.
The control sentinel was created.
Replaying the captured payloads reproduced both incorrect verdicts; overriding only cwd corrected both.
This is a native emitter API gap, distinct from the declined literal-policy findings, and cannot safely be repaired by guessing cwd in the transport.

The required Cursor portable suite failed at its missing-cwd cd-guard fixture, exactly as the declined R-cursor-o5 decision described.
That recorded behavior was preserved.
Valid-cwd Cursor output shape and missing-cwd fail-open behavior passed through the real public transport.
Cursor's normal status command confirmed an existing login, but that login cannot be called unavailable merely because the isolated home lacks it.
The workspace-contained Cursor launch returned Authentication required and did not issue tool calls.
A permitted credential source for that isolated home or permission for normal Cursor session-data writes is needed for native validation.
The workspace-contained Grok 1.0.46 launch returned Not signed in and did not issue tool calls.
Grok likewise needs an authenticated isolated home; no sign-in or credential-store edits were attempted.

Omp 18.2.7 first reported No API key found for openai-codex.
Its initial missing helper module was a disposable setup error and was corrected before a second launch.
The corrected real extension loaded, but the second launch did not issue a tool event before the 150-second bound.
An existing authenticated Omp provider in the isolated environment is needed.

OpenCode was absent from PATH, so OpenCode 1.18.35 was materialized only inside the disposable workspace.
Its real plugin initialized with the lab directory and worktree.
Both the headless CLI and a 120x35 TUI received HTTP 403: OpenCode's free tier can only be used from within OpenCode.
No tool call reached the plugin.
An authorized OpenCode provider credential or resolution of that provider refusal is needed.
The native signed Pi launcher was absent from PATH; native ordinary Pi demonstrated the shared extension, not separate signed-loader adoption.

Native Windows discovery was attempted through powershell.exe -NoProfile -NonInteractive -Command Get-Command.
The WSL bridge failed with UtilAcceptVsock:271: accept4 failed 110 before command discovery.
A working WSL-to-Windows process bridge and authenticated workspace-contained native harness are required.

The narrowed public documentation scope was read as its owned text contract.
The doc-audience checker was not run because this phase prohibits static analysis.
Documentation has no independent live executable surface.

All native labs used marked disposable homes inside this worktree and a private fm-lab tmux socket with a 120x35 grid.
Each native lab server was stopped and its home removed in its evidence turn.
No default Herdr session or default tmux server was used.
No source, test, documentation, or memory-file change is retained.
No pipeline-control, publication, PR, CI, merge, or installation-adoption operation was performed.
