# Doorbell lifecycle: no-go

Claude Code 2.1.314 at 20 columns reproducibly leaves a partial own doorbell and refuses interrupt. A fully configured real relaunch with a disposable unpublished commit also refused during clearing, keeping its original agent alive. Both failure transcripts contain only Ctrl+E and Ctrl+U. Settled readback remains pending at 0, 0.2 and 1 seconds.

The supplied intent and existing lifecycle transport oracle independently require no doorbell submission, no foreign-draft edits, and a retained inbox record. Claude documents Ctrl+E and Ctrl+U here: https://code.claude.com/docs/en/interactive-mode#text-editing
An independent reader identified cursor/screen redraw mismatch as the likely cause of the immediate unknown readback. The captures prove the failure; the race explanation remains a diagnosis hypothesis.

## Isolation

All intentionally created homes, Git fixtures, configuration copies and browser profiles lived inside this worktree. Existing account state was reused in disposable configurations. No sign-in, sign-out, global installation, production configuration mutation, or pipeline operation was performed.
Kimi needed its current .kimi-code configuration; OMP needed disposable model databases and quiet startup with project MCP configuration disabled; AGY reused existing Gemini OAuth state and completed disposable onboarding with interaction-data collection unchecked and automatic updates disabled.

The retained Herdr driver adapts the existing guard to a named fm-lab session through bin/fm-herdr-lab.sh. Its private configuration aliases only the default socket for the helper's read-only tripwire. Pane calls use helper run; provision owns prepare; teardown verified the tripwire. The full unrelated scrollback guard was attempted but could not consume the relative socket path required by the long checkout; the retained driver selects the relevant lifecycle scenarios. No default-session lifecycle or fleet-pane interaction occurred.

## Observed results

- Real tmux interrupt/exit and foreign-draft preservation passed for Cursor 2026.10.19-6bbf2c4, Codex 0.159.3, Pi 1.0.0, Grok 1.0.70, Kimi 2.4.1 and OMP 18.2.7.
- Real Claude on Herdr 0.9.5 passed own-doorbell interrupt/exit, foreign-draft preservation and actual agent-exit proof.
- AGY 1.4.12 preserved own and foreign drafts and refused exit without lifecycle input on its unreadable surface.
- Narrow Claude interrupt failed in three focused drives; real relaunch also failed at the same clear boundary.
- Real Claude with injected post-edit tmux capture failure stopped after one edit pair, submitted nothing, and retained its agent and inbox record.
- Portable lifecycle-input, composer, control, task-inbox and Herdr backend scripts exited zero. No full repository suite, lint, PR or CI phase was run.

## Reproduction

Live commands used disposable HOME, CLAUDE_CONFIG_DIR, TMPDIR and XDG_CONFIG_HOME under .lv, with DISABLE_AUTOUPDATER=1 and CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false. Supply existing account state again; no account state is retained in evidence.

```sh
FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_LIFECYCLE_ONLY=1 FM_SEND_INBOX_LIVE_HARNESSES=claude FM_SEND_INBOX_LIVE_TRACE_READS=1 FM_SEND_INBOX_LIVE_EVIDENCE_DIR=<evidence-dir> bash tests/fm-send-inbox-doorbell-live-e2e.test.sh
```

The three retained *-driver.sh files are executable scenario adaptations. The HTML and PNG render actual terminal captures. Multi-harness logs contain initial setup failures; later focused logs record corrected setup outcomes. All disposable sessions, servers and browser children completed or were stopped before cleanup.
