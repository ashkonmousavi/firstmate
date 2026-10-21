#!/usr/bin/env bash
set -eu
p=~/.no-mistakes/evidence/01M5EFYR8TJSF6027SV80VBGR7
before=$(sha256sum .l/state/live.busy-state .l/state/guard.busy-state)
env -u FM_CODEX_BUSY_HOOK -u FM_CODEX_BUSY_WORKTREE -u FM_CODEX_BUSY_STATE -u FM_CODEX_BUSY_ID -u FM_CODEX_BUSY_GEN -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$PWD/.l" timeout 90 codex exec --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check -c 'mcp_servers.figma.enabled=false' -c 'model_reasoning_effort="low"' -C "$PWD/.l/worktree" --json 'Reply exactly UNBOUND_VERIFIED. Do not use tools.' </dev/null > "$p/unbound-codex.jsonl" 2>&1
after=$(sha256sum .l/state/live.busy-state .l/state/guard.busy-state)
[ "$before" = "$after" ]
printf 'Real unbound Codex session completed; both armed task records remained byte-identical.\n%s\n' "$after" > "$p/unbound-state.log"
