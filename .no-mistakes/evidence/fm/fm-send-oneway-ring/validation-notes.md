# Targeted live validation

Target: `beba5a22d3d1b0e5d6ad8e0e306c43addbc98154`; base: `6be965824a45a1b08efca91a876ed281b9ce7904`.

## Independent acceptance oracles

The supplied author intent requires no correlation for a one-way send, explicit acknowledgement of an existing exact correlation, Claude queued consumption during an existing turn, nonqueue busy deferral followed by idle re-ring, and no doorbell input into exhausted Cursor followed by seat release.
The recorded decisions further require identity-based idempotency and conflicts, bulk request-id candidate selection, preservation of idle ring debt through checkpoint aborts, Rovo busy deferral, and retention of the Grok always-approve path.
No existing operator reply debt was reviewed or closed.

## Product proofs

- `data-plane-live.log`: real fm-send, real private tmux, marked lab home, no transport mocks. Two-line one-way sends leave no correlation. An identical request stays one record before and after acknowledgement; another identity creates a new record; conflicting reuse is refused. Ordinary sends create two genuine correlations; moving one inbox record to handled alone leaves it open. The acknowledgement CLI resolves exactly one, closes its persisted escalation, and preserves the unrelated ask. Wrong identity and malformed correlation are refused. Status and correlation records are retained separately.
- `claude-live.log`, `claude-busy-submitted.txt`, `hx-claude-finished.txt`, and `claude-home-state`: real Claude Code 2.1.312. A real foreground shell tool remains blocked when a second doorbell is submitted. After release, the second instruction creates its file and moves record 003 to handled without an idle re-ring.
- `cursor-live.log`, `cursor-unknown-before-ring.txt`, `cursor-residue-before-ring.txt`, and the input/send logs: real Cursor Agent 2026.10.19-6bbf2c4 on an actually exhausted Grok 4.7 model. The real 220x8 viewport is classified unknown; a separate concatenated-doorbell composer is pending. Ring return is 4 with zero keystrokes. fm-send durably enqueues and fm-control stops the real process; only Escape is sent, with no exit text or Enter.
- `grok-idle-live.log` and `grok-idle-state`: real Grok 1.0.70. Exact real busy and idle classifications are required. Two busy observations escalate without injected input. An expired deadline and checkpoint admission each preserve the same busy marker. Recovery sends exactly one doorbell, and the agent creates the requested file and moves its record to handled.
- `grok-watcher-live.log` and `grok-watcher-state`: the same real runtime exercised through the public fm-watch-checkpoint --recover executable for busy observations and recovery. The public checkpoint also preserves the owed ring while deferring recovery.
- `opencode118-live.log`, `opencode-busy-submitted.txt`, `hx-opencode-finished.txt`: workspace-local OpenCode 1.18.4 and its real free provider passed both idle and busy consumption. The model was executing a real blocked foreground tool before the queued steer was sent. Record 003 was acted on and acknowledged with no idle re-ring. The successful run used a 120x40 viewport and waited for the initial response to settle.
- `grok-live.log`: the real always-approve composer is empty, then becomes pending after typing an unsent draft. Identity-aware cleanup awaits the private pane's descendants before deleting its lab.

A plausible wrong implementation would leave reply debt on a one-way send, collapse a distinct repeated instruction, accept a conflicting retry, close the unrelated correlation, send keys into exhausted Cursor, lose the busy marker before ringing, or require an extra idle ring for Claude. Each is rejected by observable state or a real harness side effect, rather than source text matching.

## Targeted deterministic checks

All six commands exited 0, with TMPDIR under the worktree:

- bash tests/fm-send-inbox.test.sh
- bash tests/fm-task-inbox.test.sh
- bash tests/fm-pending-reply-retire-notice.test.sh
- bash tests/fm-send-remote-delivery.test.sh
- bash tests/fm-control.test.sh
- bash tests/fm-composer-lib.test.sh

These include Rovo family/alias deferral and fire-and-forget cases, bulk dedup/parser cost and acknowledgement-race cases, remote retry/conflict behavior, and checkpoint debt preservation. Mocked runtime or SSH coverage is not counted as live.

## Isolation and reproducibility

Each live lifecycle target was created with bin/fm-lab-home.sh, used stock FM_HOME layout without path overrides or gate bypass, and used a private fm-lab tmux socket with a nonzero viewport.
Vendor configuration and added tools stayed in disposable workspace directories. Existing authentication was reused without logging, signing in, signing out, or editing production credentials. No credential stores are retained in this evidence.
The initial Claude trust setup was resolved with disposable configuration. An unwired manual Codex launch intentionally classified unknown and was replaced by Grok for the nonqueue proof. A Grok downloader teardown race was resolved with identity-aware descendant termination and awaiting before deletion.

`drivers/` retains the manual drivers (no credentials). They expect to be copied to `.test-validation/` under a checkout of the target, run from that checkout, with `.test-validation/tmp` created. The CLI/core runs were `bash .test-validation/data.sh`, `FM_SEND_INBOX_LIVE_HARNESSES=claude FM_SEND_INBOX_LIVE_TIMEOUT=120 bash .test-validation/live.sh`, the analogous Cursor run with `FM_SEND_INBOX_LIVE_CURSOR_MODEL=grok-4.7-high`, `bash .test-validation/grok.sh`, `bash .test-validation/grok-idle.sh`, and `bash .test-validation/grok-watcher.sh`.

## Research used for disposable configuration

The primary sources below were consulted to resolve test setup only. The fleet research book was not modified because it lies outside the permitted workspace.

- [Claude authentication](https://code.claude.com/docs/en/authentication): separate configuration directory and existing authentication storage.
- [Claude security](https://code.claude.com/docs/en/security): interactive trust persistence.
- [Cursor authentication](https://cursor.com/docs/cli/reference/authentication) and [ACP authentication](https://cursor.com/docs/cli/acp): existing token authentication and isolated automation.
- [Grok settings reference](https://docs.x.ai/build/settings/reference): GROK_HOME and compatibility scanner switches.
- [OpenCode Zen](https://opencode.ai/docs/zen/) and [configuration](https://opencode.ai/docs/config/): disposable local tool and free-provider workaround.

## Deliberate live limits

No Rovo live scenario was run, as explicitly required by the recorded human decision. The policy was checked by targeted executable regressions and the shared nonqueue behavior was proven live with Grok.
A real remote SSH hop was not available within the lab contract: the remote endpoint helper requires the fixed fm-remote Herdr session, while this gate authorizes only fm-lab-* Herdr lifecycle. The existing remote executable regression executes the real local sender and remote leg with an SSH boundary stub; it is not live remote evidence. A separately authorized isolated SSH/Herdr host is required for that refresh.

Rendered terminal evidence is in `live-terminal-evidence.html`; these are actual tmux captures rendered as HTML, not desktop screenshots.

OpenCode was absent from PATH. Workspace-local npm installs of 1.19.5 and the previously verified 1.18.4 were tried. Initial setup attempts either skipped the blocking-tool instruction on pending composer or stalled in the free model. The same 220x50 OpenCode startup surface classified pending under both target and base classifiers (`opencode-composer-comparison.log`). Resizing the 1.18.4 lab to 120x40 produced empty, and the readiness-aware driver then completed the real busy scenario. Those earlier setup attempts are retained and are not claimed as queue proof.

The successful OpenCode driver invocation used `PATH="$PWD/.test-validation/opencode118/node_modules/.bin:$PATH"`, isolated XDG config/data paths, and `FM_SEND_INBOX_LIVE_HARNESSES=opencode FM_SEND_INBOX_LIVE_TIMEOUT=120 bash .test-validation/opencode118-live.sh`. During its startup wait, the private socket received `tmux -L fm-lab resize-window -t inboxlive:hx-opencode -x 120 -y 40`. No user-level tool installation or source change was made.
