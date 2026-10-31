# Focused test-phase fix

Root cause: immediately after Ctrl+E/Ctrl+U, a narrow Claude redraw can leave the separately sampled tmux cursor row and screen inconsistent. The classifier reports unknown, so recovery previously returned after its first edit despite settled captures proving pending text. The initial real reproduction returned exit 1 and retained partial text. An independent read-only diagnosis confirmed this boundary.

Primary reference: https://code.claude.com/docs/en/interactive-mode#text-editing documents Ctrl+E and repeated Ctrl+U. Exa searched vendor documentation, changelog and first-party issue reports; no vendor-specific parser change was justified. Existing research-book entry claude-prompt-suggestion-ghost-composer.md describes a distinct dimmed-suggestion failure; prompt suggestions were disabled for this reproduction.

Fix: both clear loops retry unknown readback five times with 0.1-second waits, without sending any keys during those retries. A readable pending verdict permits another edit pair; persistent unknowns and failed reads refuse clearing. Ownership matching and character-based deletion budgets are unchanged.

## Actual results

- New test_composer_clear_waits_for_redraw failed before the fix (exit 1), then passed after it (exit 0), for tmux and Herdr.
- Focused portable runner selected test_composer_clear_waits_for_redraw, test_composer_clear_stops_on_unreadable_readback and test_composer_clear_at_narrow_widths from tests/fm-task-inbox.test.sh; exit 0. It also checks at most ten readbacks independently of a 10,000-character payload and exactly one edit on persistent unknown.
- Focused Herdr runner selected test_send_text_submit_refused_suffix_that_will_not_clear_is_unknown, test_send_text_submit_unreadable_clear_stops_after_one_edit, test_send_text_submit_clears_a_wrapped_suffix_one_row_per_press and test_send_text_submit_refused_suffix_then_clean_retry_submits_only_the_message; exit 0. Like the owning suite at line 6413, it unsets FM_HERDR_SCRIPT_PANE_GET before these cases. Its initial missing-unset setup attempt failed; no production change was made for that fixture setup error.
- Real Claude Code 2.1.314: narrow interrupt and exit, moved cursor, foreign-draft preservation, no doorbell submission, retained agent/inbox/endpoint as appropriate: exit 0.
- Real relaunch with a disposable unpublished commit: exit 0, replacement agent alive and original unpublished work file preserved. Initial retained-driver setup had the endpoint outside its recorded worktree; corrected by creating and launching inside the disposable worktree before running the same scenario. This setup problem surfaced only after composer clearing succeeded.
- Real Claude with injected post-edit tmux capture failure: exit 0, exactly one edit pair, no submission, live agent and retained inbox record.
- An initial full fm-task-inbox script invocation was interrupted with status 130 and replaced by the selected-function runner; it is not claimed as a suite pass. No full repository suite, lint, formatter, static analysis, pipeline control, push, PR or CI phase ran.

## Reproduction

Use disposable HOME, CLAUDE_CONFIG_DIR, TMPDIR and XDG_CONFIG_HOME under the worktree, copy existing account state privately, disable autoupdates and prompt suggestions, and complete local Claude permission-mode onboarding. No credentials are retained in evidence.

Run FM_SEND_INBOX_LIVE_E2E=1 FM_SEND_INBOX_LIVE_LIFECYCLE_ONLY=1 FM_SEND_INBOX_LIVE_HARNESSES=claude FM_SEND_INBOX_LIVE_TRACE_READS=1 FM_SEND_INBOX_LIVE_EVIDENCE_DIR=<worktree-evidence> bash tests/fm-send-inbox-doorbell-live-e2e.test.sh.
The fix-relaunch-driver.sh and fix-unreadable-driver.sh are executable adaptations of that guard with the same disposable environment.
For portable selection, copy the owning test file's definitions (before its first top-level invocation) into a temporary tests/.focused.sh, append only the named functions, run it under bash with worktree TMPDIR, and remove the temporary runner.

All test processes completed or were interrupted and awaited; each live guard killed its private tmux server. Relaunch cleanup encountered intentionally read-only Git hook directories; owner write permission was restored only in the disposable worktree fixture before removing it. Dependencies prepared by the outer executor were left untouched.
