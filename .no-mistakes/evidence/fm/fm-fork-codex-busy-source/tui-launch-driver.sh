#!/usr/bin/env bash
set -eu
export PRODUCT_ROOT="$PWD" LAB="$PWD/.l" EVIDENCE=~/.no-mistakes/evidence/01M5EFYR8TJSF6027SV80VBGR7
export FM_CODEX_BUSY_WORKTREE="$LAB/worktree" FM_CODEX_BUSY_STATE="$LAB/state"
export FM_CODEX_BUSY_ID=live FM_CODEX_BUSY_HOOK="$LAB/observe.sh" FM_CODEX_BUSY_REAL_HOOK="$PWD/bin/fm-codex-busy.sh"
export FM_CODEX_BUSY_GEN
FM_CODEX_BUSY_GEN=$(bin/fm-busy-event.sh arm "$LAB/state" live)
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" "codex --no-alt-screen --enable hooks --dangerously-bypass-hook-trust --dangerously-bypass-approvals-and-sandbox -c 'mcp_servers.figma.enabled=false' -c 'model_reasoning_effort=\"low\"' -C '$LAB/worktree' 'Reply with exactly CODEX_TUI_VERIFIED. Do not use tools.'"
