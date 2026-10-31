# Live validation setup and limits

The real product entrypoints ran against marked disposable lab homes, actual Claude Code 2.1.314 with the normal managed login, tmux terminals at 120×40, and Herdr 0.9.5 with a named non-default session. All live homes and task directories were removed after their private terminals stopped. No source changes were needed.

Completion reports, statuses, and identity-matching merge receipts were disposable input records. Merge receipts came from the real Firstmate receipt writer; no production forge data or credentials were changed. `FM_LANE_RELEASE_NOW` advanced the carrier clock to exercise the 300-second debounce and 30-minute audit threshold; these checks do not establish elapsed production latency. Real model turns generated the monotonic busy records through the actual hook writer.

Initial setup attempts were corrected before the final successful runs:

- A standalone nested git repository triggered workspace trust. Removing that disposable nested repository let the trusted enclosing worktree govern startup. The first-party [Claude permissions documentation](https://code.claude.com/docs/en/permissions#project-allow-rules-and-workspace-trust) explains that trust is keyed by repository root and excludes nested repositories. No trust choice or login was changed.
- Starting Claude as tmux's window command destroys its endpoint on exit. Production creates a shell window, then types the launch command into it. The final fixture follows that topology.
- An empty status file is unreadable completion evidence; a stamped working declaration is also retained while crew-state says working. The merged-while-idle success scenario uses no status declaration and positively idle real hooks, yielding crew-state unknown as the release contract allows.
- A wrapped own-doorbell draft required multiple Control-U presses to remove the fixture text. This was manual fixture cleanup, not a product stuck-composer clearing feature.
- Herdr control requires session/workspace/tab/pane metadata. Final fixtures use the full tuple returned by the actual workspace-create call. Provision and teardown ran inside one controller, preserving server lifetime and verifying the default-session tripwire.

The evidence is terminal/CLI output, persisted public marker/ledger contracts, and the generated Markdown fleet listing. This change has no browser or graphical layout surface, so no screenshot was captured.

The broad watcher regression was stopped explicitly after discovering its `FM_TEST_ONLY` selector; its unfinished result is not represented as a pass. The release-specific selector was run separately to completion. Other selected regression files completed normally. Remote CI remains responsible for broad regression.
