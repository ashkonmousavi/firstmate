#!/usr/bin/env bash
payload=$(cat)
printf '%s\n' "$payload" >> "$EVIDENCE/events.jsonl"
printf '%s' "$payload" | bash "$FM_CODEX_BUSY_REAL_HOOK"
{
  cat "$FM_CODEX_BUSY_STATE/$FM_CODEX_BUSY_ID.busy-state"
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" bash "$PRODUCT_ROOT/bin/fm-crew-state.sh" "$FM_CODEX_BUSY_ID"
} >> "$EVIDENCE/lifecycle.log" 2>&1
