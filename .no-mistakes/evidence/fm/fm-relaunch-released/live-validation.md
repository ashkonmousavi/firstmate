# Released-copy live validation

All acceptance scenarios passed on Linux/WSL2 6.6.114.1 x86_64 using real tmux 3.4, Herdr 0.9.5, Treehouse 3.1.4, Codex CLI 0.159.3 and a disposable Forgejo 17.0.1 server with tea 0.16.0.
No source changes were necessary.

Real `fm-teardown`, `fm-control relaunch`, `fm-spawn --relaunch`, Git fetch/push, Treehouse leases, endpoint creation/closure and tasks-axi backlog transitions were exercised.
Runtime providers were real; utility wrappers injected failures while delegating all other operations to the installed tools.
The expected behavior came from the supplied intent and later release/rollback decisions.
Codex used an isolated profile: the real CLI started at its sign-in screen; no model turn, credential copying, or sign-in was performed.
The generated launch brief, progress note, durable note_file, branch/head, slot state and actual endpoint lifecycle were the deterministic acceptance surfaces; model interpretation was not tested.
This is a shell/CLI lifecycle change, so there is no changed rendered browser surface requiring screenshots.

| Scenario | Evidence |
| --- | --- |
| tmux round trip, same branch/head, durable note and push | [tmux-roundtrip-final.txt](tmux-roundtrip-final.txt); [recreated-note.md](recreated-note.md); [relaunch-journal.txt](relaunch-journal.txt) |
| Herdr round trip, merge hold and lane deferral | [herdr-cli.log](herdr-cli.log) |
| Dirty files and gate-only commits retained | [live-attempt-4.log](live-attempt-4.log) |
| Publicsrc cannot authorize release | [edge-cli.log](edge-cli.log) |
| Existing window, lane, closed/unreadable PR refusals leave state unchanged | [live-attempt-5.log](live-attempt-5.log) |
| Valid unsupported backends and captain holds refuse | [final-guards-cli.log](final-guards-cli.log) |
| Merged PR requires cleanup | [final-guards-cli.log](final-guards-cli.log) |
| Descendant remote accepted with pushable branch | [edge-cli.log](edge-cli.log) |
| Rewritten remote refused with resources returned | [edge-cli.log](edge-cli.log) |
| Real pool exhaustion on tmux and Herdr returns 75 unchanged | [edge-cli.log](edge-cli.log); [herdr-failure-cli.log](herdr-failure-cli.log) |
| Transport failure rolls back; retry adds one note on both backends | [delivery-cli.log](delivery-cli.log); [herdr-transport-cli.log](herdr-transport-cli.log) |
| TERM during partial snapshot preserves original data | [edge-cli.log](edge-cli.log) |
| Failed copy return and failed close preserve proof; retry and recreation succeed | [release-retry-cli.log](release-retry-cli.log); [release-retry-resume-cli.log](release-retry-resume-cli.log) |
| Live GitHub PR reader agrees with independent REST head | [github-live-reader.txt](github-live-reader.txt) |

Targeted baseline: `bash bin/fm-test-run.sh --jobs 1 tests/fm-control-relaunch.test.sh tests/fm-teardown.test.sh tests/fm-control.test.sh` exited 0; each child exited 0 and none gate-skipped.
No full-suite, lint, format, static-analysis, push, PR or CI phase was run.

Setup failures were corrected before accepting evidence: socket path length/context, isolated Git/tea configuration, fixture policy/metadata/brief shape, and the missing isolated Codex directory.
A late memory-PSI admission refusal was an actual environment deferral, not a product failure; the unexercised launch was retried only after PSI fell below the configured threshold.
The first delivery oracle unnecessarily required deletion of a detached branch; the acceptance contract requires returning the copy and preserving work, so the corrected live check verifies detachment, resource return and successful retry.
The journal note_file intentionally contains the supplied note; the generated brief contains the expanded recreated-copy message.
Initial setup/oracle attempts remain in separate logs and are superseded by the accepted transcripts above.

Replay drivers are under `replay/`.
They create only disposable repositories and marked homes under `.validation-live` in the current checkout, with evidence selected by `FM_LIVE_EVIDENCE`.
Provide the existing tools on PATH and place the downloaded Forgejo and tea binaries under `.validation-live/tools` using the official release URLs recorded below.
Start `replay/server.py` after copying the replay scripts to `.validation-live`, then drive the named scripts with `python3 .validation-live/<driver>.py`.
`drive.py` should be assessed with its corrected durable-note oracle; the accepted supplemental verification is in `tmux-roundtrip-final.txt`.
Herdr drivers require the helper's real running-default tripwire: create `.validation-live/herdr-xdg/herdr/` and a local `herdr.sock` symlink pointing at the existing default socket reported by `herdr session list --json`.
They operate only on named `fm-lab-*` sessions and tear them down through the helper, with a nonzero terminal grid for the tmux CLI.
To stop the local forge, create `.validation-live/stop` and await the server process before removing `.validation-live`.

Primary setup references:
- https://forgejo.org/docs/latest/admin/installation/binary/
- https://forgejo.org/docs/latest/admin/command-line/
- https://github.com/kunchenguid/treehouse (max_trees and root configuration)
- https://codeberg.org/forgejo/forgejo/releases/download/v17.0.1/forgejo-17.0.1-linux-amd64
- https://gitea.com/gitea/tea/releases/download/v0.16.0/tea-0.16.0-linux-amd64

[Cleanup confirmation](cleanup.txt).
