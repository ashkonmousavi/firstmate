# Live validation evidence and limits

Oracle: supplied intent requires dim suggestions empty, real drafts pending, unstyled captures refusing, and worker suppression=false. Declined edge cases were left unchanged.

Official docs: https://code.claude.com/docs/en/interactive-mode#prompt-suggestions documents dim suggestions, background requests, cold-cache/first-turn skips, and the environment variable overriding settings. First-party issue https://github.com/anthropics/claude-code/issues/90755 documents the scraping hazard on 2.1.246–2.1.251. Research remains here because operator research-book data is outside the workspace boundary.

WSL/Linux; tmux 3.4; Herdr 0.9.5; normal-login Claude 2.1.314 and workspace-local npm Claude 2.1.283 and 2.1.251. No credentials copied or login performed; each CLI used its account default model.

All three CLI versions truncated long suggestions with ellipsis at 40 columns; Herdr at about 35 columns did likewise. Styled actual suggestions read empty; unstyled re-reads unknown. No multirow ghost was observed. The core wrapped-ghost scenario, including exit/relaunch/doorbell from that exact surface, remains untested. Completing it needs a CLI/rendering configuration that actually renders the reported titled SGR-2 multirow suggestion.

Wrapped and independently checked newline-leading unsent drafts classified pending with cursor and cursorless reads. The newline oracle required a blank first composer row followed by exactly the known unsent draft, ignoring terminal wrapping whitespace. Exit refused drafts.

Herdr fm-send queued 001.msg and skipped the doorbell while the draft remained pending. One Ctrl-U had cleared only part of the draft. After complete clearing, fm_task_inbox_ring delivered it; Claude wrote HERDR_DOORBELL_OK and moved 001.msg to handled. fm-control then reported stopped with background-sessions=none.

The direct-command tmux lifecycle probe removed its own pane on exit and therefore returned unconfirmed. Retesting in a persistent shell with Claude 2.1.251 returned stopped with background-sessions=none. This was corrected setup, not an established classifier defect.

Authenticated live relaunch would rewrite normal-account Claude trust configuration outside the workspace. The isolated CLAUDE_CONFIG_DIR used for the successful real spawn/environment proof stopped at onboarding without login. To complete authenticated relaunch, provide an authenticated disposable account directory inside the workspace whose configuration may change.

Lab viewer detach checks initially timed out; their scripts returned 1. After the owning commands ended, guarded teardown succeeded. No clean script pass is claimed; product assertions and subsequent cleanup are reported separately.

The real spawn unexpectedly put its disposable project copy in ~/.treehouse/proj-d302ec/1/proj. Its worker was stopped. The external fixture was neither read nor deleted afterward because intentional writes there are outside the workspace boundary. Future runs must set TREEHOUSE_ROOT inside the workspace; external fixture cleanup requires separate authority. Workspace-local transients were removed.
