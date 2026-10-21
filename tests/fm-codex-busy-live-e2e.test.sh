#!/usr/bin/env bash
# Opt-in credentialed guard: installed Codex must emit all three global
# lifecycle events through the actual busy writer. No credential file is read
# or copied. Installs the inert global dispatcher, just as fm-spawn does.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CODEX_BUSY_LIVE codex
VERSION=$(codex --version)
TMP_ROOT=$(fm_test_tmproot fm-codex-busy-live)
mkdir -p "$TMP_ROOT/state" "$TMP_ROOT/worktree"
# shellcheck source=bin/fm-busy-lib.sh
. "$ROOT/bin/fm-busy-lib.sh"
bash "$ROOT/bin/fm-codex-busy.sh" install || fail "Codex $VERSION: global hook installation failed"
export FM_CODEX_BUSY_WORKTREE="$TMP_ROOT/worktree" FM_CODEX_BUSY_STATE="$TMP_ROOT/state"
export FM_CODEX_BUSY_ID=live FM_CODEX_BUSY_GEN
FM_CODEX_BUSY_GEN=$("$ROOT/bin/fm-busy-event.sh" arm "$FM_CODEX_BUSY_STATE" live)
export FM_CODEX_BUSY_HOOK="$TMP_ROOT/observe.sh" FM_CODEX_BUSY_REAL_HOOK="$ROOT/bin/fm-codex-busy.sh"
cat > "$FM_CODEX_BUSY_HOOK" <<'EOF'
#!/usr/bin/env bash
bash "$FM_CODEX_BUSY_REAL_HOOK"
cat "$FM_CODEX_BUSY_STATE/$FM_CODEX_BUSY_ID.busy-state" >> "$FM_CODEX_BUSY_STATE/observed"
EOF
codex exec --enable hooks --dangerously-bypass-hook-trust \
  --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check \
  -C "$FM_CODEX_BUSY_WORKTREE" -c 'model_reasoning_effort="low"' \
  --json 'Reply with exactly CODEX_BUSY_VERIFIED. Do not use tools.' \
  </dev/null > "$TMP_ROOT/codex.jsonl" 2>&1 \
  || fail "Codex $VERSION: live hook probe failed (log: $TMP_ROOT/codex.jsonl)"
for edge in 'state=busy source=codex-hook event=UserPromptSubmit.' \
  'state=idle source=codex-hook event=Stop.' 'state=idle source=codex-hook event=SessionEnd.'; do
  grep -F "$edge" "$FM_CODEX_BUSY_STATE/observed" >/dev/null \
    || fail "Codex $VERSION: missing lifecycle edge $edge"
done
[ "$(fm_busy_classify tmux live codex live "$FM_CODEX_BUSY_STATE")" = 'idle codex-hook' ] \
  || fail "Codex $VERSION: completed session did not classify idle"
printf 'ok - %s global hooks emitted busy/UserPromptSubmit, idle/Stop, idle/SessionEnd\n' "$VERSION"
