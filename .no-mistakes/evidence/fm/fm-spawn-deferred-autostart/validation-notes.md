Validated deferred-spawn behavior through real Firstmate CLI entrypoints, a private 120×40 tmux session, installed Codex, tasks-axi, Treehouse, Git, and disposable marked homes entirely inside the gate worktree. No Herdr/default fleet session was used.

The CLI transcripts retain initial driver/setup failures and the successful continuations. Real Codex workers reached their folder-trust screen; it was left unaccepted so no project-trust configuration was persisted. The acceptance oracle was automatic creation of the correct worker endpoint, live Codex process, metadata and In flight backlog transition, rather than execution of a task by the model.

Observed results:
- Full-machine spawns returned 75 and persisted deferred requests. A real watcher launched older first, left younger queued at one available lane, and produced no duplicate endpoint. After the next lane release it launched younger.
- Tasks changed to held, dependency-blocked or Done after deferral did not launch. Manual-backlog and missing-backlog homes reported inability to establish queued eligibility. A corrupted recorded argument checksum was reported stale and removed.
- A real retry stopped at an AFK spend cap without accumulating a permanent failure; after archiving the temporary cap, the watcher launched it.
- Memory, malformed machine configuration and disk-floor refusals returned 75 without recording requests. A stopped worker refused for full-machine relaunch also created no automatic request.
- A delayed local Git upload-pack transport held a real retry open. The watcher returned an authenticated custom-check wake in two seconds while the transport was still held, and a younger request did not overlap. Both requests subsequently launched. Retained dead fixture records conservatively counted a recycled live worktree; the disposable ceiling was increased before completing the younger launch.
- Retried metadata retained the absolute project and tmux endpoint even with FM_BACKEND=orca in the watcher environment.
- The actual spawn entrypoint still refused a marked lab with relocated data, exit 3, before writing lifecycle state.

Test-phase fixes:
- The new deferred helper unconditionally exported the default data path, which the existing gate guard correctly rejects as an unsupported override. The helper now omits that redundant override and retains explicit relocation. The guard is unchanged. tests/fm-spawn-deferred-lab.test.sh reproduced failure before the fix and passed afterward, including continued relocation refusal. Independent review confirmed the cause and fix.
- Two Orca project-lock assertions expected exit 1 despite the accepted temporary-refusal contract requiring exit 75. Both now use the suite’s existing DEFER_EXIT constant and retain the diagnostic and no-mutation assertions. Independent review confirmed this expectation correction.

Completed targeted commands:
- bash tests/fm-spawn-deferred.test.sh — exit 0 before and after the helper correction.
- bash tests/fm-spawn-deferred-lab.test.sh — exit 1 before correction, exit 0 afterward.
- bash tests/fm-project-capacity.test.sh — reproduced the outdated Orca assertion, then exited 0 after correcting both expectations.

The CLI configuration research used the official OpenAI configuration reference, https://developers.openai.com/codex/config-reference.md. No global configuration or credentials were changed. All recorded pane processes exited, no deferred claims remained, and the private tmux server and all disposable worktree fixtures were removed. No screenshots were required because the change alters CLI scheduling, not a rendered UI.
