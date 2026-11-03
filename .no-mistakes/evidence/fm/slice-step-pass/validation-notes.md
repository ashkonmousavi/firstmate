All work used the gate worktree. No source or permanent tests were changed.

The first focused launcher run failed because TMPDIR was deliberately placed inside this Git worktree: an uninitialized disposable project inherited the enclosing repository identity and its publication gate refused mismatched fixture consent. Git documentation confirms enclosing-worktree discovery: https://git-scm.com/docs/git-rev-parse and https://git-scm.com/docs/git#Documentation/git.txt-GITCEILINGDIRECTORIES . Setting GIT_CEILING_DIRECTORIES to the disposable test root corrected the setup; the complete focused launcher rerun exited 0.

The first live tmux location exceeded the Unix socket path limit. The private socket was moved to .t inside the worktree. All panes were 120x40. Metadata used the actual recorded tmux window name, not an index.

The Codex primary was launched without hooks and selected Run without daemon this time; no shared daemon was restarted and no credentials or global settings were edited. The durable cut receipt/inbox was verified; agent acknowledgement was not claimed. The initial live stdout log was accidentally truncated by importing the additional driver; actual persisted records are retained in live-product-state.log and the successful assertions in live-results.json.

Fresh spawn and changed-cut continuation were additionally driven through real OMP, real tmux, real Treehouse, real backlog, real model metadata, and real fm-control, with TREEHOUSE_ROOT confined to the worktree. Both completed launch replay and same-task/same-worktree/new-incarnation continuation were verified. Normal model login was used unchanged.

The dispatcher data/bin/fm-grok-bot-dispatch.sh and the P2 board publisher are private installation material absent from this worktree. The real remote carrier was exercised against a disposable parent home, including duplicate replay and pending-until-sent behavior. No Grok chat or production PR was created. Mocked dispatcher/forge/agent cases in the executable matrix are fixture evidence, not live proof of those external services.
