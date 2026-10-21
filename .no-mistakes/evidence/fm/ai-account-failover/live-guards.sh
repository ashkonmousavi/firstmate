#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.test-tmp/account-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export HOME="$LAB/user" TMPDIR="$LAB" XDG_CONFIG_HOME="$LAB/xdg"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$LAB/config" "$LAB/claude-1" "$LAB/claude-2" "$LAB/codex-1" "$LAB/codex-2"
unset CLAUDE_CONFIG_DIR CODEX_HOME OPENAI_API_KEY ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN QUOTA_AXI_SNAPSHOT
. "$ROOT/bin/fm-worker-account-lib.sh"
printf 'Real tools: '; claude --version; codex --version; quota-axi --version
printf '{"apiKeyHelper":"echo sk-ant-fm-live-synthetic"}\n' > "$LAB/claude-2/settings.json"
printf '{"OPENAI_API_KEY":"sk-fm-live-synthetic"}\n' > "$LAB/codex-2/auth.json"
for harness in claude codex; do
  printf '\nSelect isolated %s-2 using real vendor login-status:\n' "$harness"
  fm_worker_account_select "$harness" "$LAB/config" default "$harness" '' "$LAB/$harness-2" | sed "s|$LAB|LAB|g"
  printf 'Empty %s-1 with ambient credential must refuse:\n' "$harness"
  if OPENAI_API_KEY=sk-fm-live-synthetic ANTHROPIC_API_KEY=sk-ant-fm-live-synthetic fm_worker_account_select "$harness" "$LAB/config" default "$harness" '' "$LAB/$harness-1"; then exit 1; fi
  printf 'Real strict quota for empty %s-1: ' "$harness"
  answer=$(fm_worker_account_quota "$harness" "$LAB/$harness-1" default)
  printf '%s\n' "$answer"
  [ "$answer" = unknown ]
  printf 'No usable next account without vendor quota: '
  if fm_worker_account_next "$harness" "$LAB/$harness-1" default; then exit 1; else echo refused; fi
  printf 'Ambient account selection remains empty: '
  selected=$(fm_worker_account_select "$harness" "$LAB/config" default "$harness")
  [ -z "$selected" ]; echo empty
 done
printf '%s\n' "$LAB/claude-1" > "$LAB/config/claude-account"
printf '\nConflicting home pin refuses before vendor launch:\n'
if fm_worker_account_select claude "$LAB/config" default claude '' "$LAB/claude-2"; then exit 1; fi
printf 'Home pin unchanged: '; test "$(cat "$LAB/config/claude-account")" = "$LAB/claude-1"; echo yes
printf '\nLive guards complete; no model requests submitted.\n'
