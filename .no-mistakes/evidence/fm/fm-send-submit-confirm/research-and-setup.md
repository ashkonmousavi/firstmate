# Live submit validation

The oracle is the approved five-press, two-second sender budget, prompt-correlated confirmation, and durable enqueue independent of doorbell success.
Real Claude Code 2.1.312 and Codex 0.159.3 ran in private, sized tmux panes.
Fault injection swallowed only transport Enter keys or refused pane reads; it did not replace a harness, hook producer, or product implementation.
The unrelated-event case submitted a different real prompt from a donor Claude pane after the target sender took its baseline, using the same disposable task incarnation.
The donor produced a real UserPromptSubmit receipt and Stop while the target draft remained visible and its inbox record remained unhandled.

## Setup and sources

- Claude's initial normal-profile launch stopped at workspace trust. [Official security documentation](https://code.claude.com/docs/en/security) describes that dialog and its persistence. Successful runs used a disposable CLAUDE_CONFIG_DIR inside the worktree, initialized only with onboarding/trust state, and reused the existing local OAuth access token via the CLI environment. No credential value was logged or changed, and operator configuration was unchanged.
- [Claude's hook contract](https://code.claude.com/docs/en/hooks) supplies command-hook JSON on stdin and says UserPromptSubmit also fires for automatic turns. Actual live hooks wrote prompt-correlated receipts through fm-busy-event.sh. Receipts and donor terminal output are retained.
- Codex's first launch reached its real composer, but its shell did not inherit FM_HOME/FM_TASK_INBOX, so that lab was stopped. [Official shell environment policy documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#shell-environment-policy) defines explicit invocation-local set values. The guard now passes these two disposable fixture paths explicitly; both Codex scenarios acted and acknowledged their records.
- The Herdr host-local remote send used a named fm-lab-* session through bin/fm-herdr-lab.sh. A transport wrapper mapped the host-local fm-remote namespace to that owned session, swallowed Enter, and refused subsequent pane reads. All successful reads and typing reached real Herdr and real Claude. The target started with an empty composer; the host-local executable retained 001.msg and returned 0 with NOT delivered. Teardown checked the default-session tripwire.
- Herdr driver setup attempts corrected duplicate prepare (provision performs prepare), nested workspace/tab response fields, and startup pending content (disable prompt suggestions and wait for an empty-composer verdict). Every attempt tore down its named session.
- An earlier shell run's final reporting was disrupted by editing its executing script. The final completed script was rerun in full for Claude and Codex; both actual exit statuses were 0.

The maintained guard is tests/fm-send-inbox-doorbell-live-e2e.test.sh. It now asserts retry spacing and retains optional product evidence. Focused portable inbox, typed confirmation, local enqueue, and remote delivery tests also exited 0. No complete suite, lint, formatting, static analysis, publication, or pipeline-control phase ran.
