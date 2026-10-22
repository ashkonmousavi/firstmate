Automatic dispatch and exited-worker relaunch were not driven live.

A real authenticated Claude TUI was started in the marked lab on the private fm-lab socket, and the real watcher/fm-send route delivered an instruction that the worker handled by merging and pushing to a disposable local remote.

Preflight of the automatic launch route found that bin/fm-spawn.sh invokes bin/fm-claude-trust.sh for Claude; the trust helper writes ${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json. This run forbids intentional user-level tool-configuration writes outside the worktree. No CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY, or ANTHROPIC_AUTH_TOKEN was available in the environment to authenticate a workspace-local configuration without accessing/copying the operator credential store. An empty isolated configuration was not used to claim the normal login unavailable: the normal login was proven working by the live TUI.

To exercise automatic dispatch/relaunch within the same boundary, provide an already authenticated workspace-local CLAUDE_CONFIG_DIR whose trust/configuration files may be changed. The targeted fixture suite covered the recovery decision and relaunch arguments, but that evidence is not live automatic relaunch.

Claude displayed an unnamed MCP server authentication warning. No MCP connector was used by these tests.
