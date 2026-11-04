#!/usr/bin/env bash
# Opt-in real Claude transport proof: asynchronous hooks keep cycling during a
# long Bash call; synchronous PreToolUse refuses a stale fleet send. The arm
# and send are fixture executables, so no real fleet or endpoint is touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CLAUDE_WATCH_GUARD_LIVE_E2E claude
LAB=$(fm_test_tmproot fm-claude-watch-guard-live)
fm_git_identity fmtest fmtest@example.invalid
git init -q "$LAB"
mkdir -p "$LAB/.claude" "$LAB/state" "$LAB/config"
cp -R "$ROOT/bin" "$LAB/bin"
printf 'Use only the exact Bash commands in the prompt.\n' > "$LAB/AGENTS.md"
# Exercise the tracked entries, excluding unrelated startup and Stop policies.
jq '{hooks:{UserPromptSubmit:[{hooks:[.hooks.UserPromptSubmit[].hooks[] | select(.command | contains("fm-claude-watch-guard"))]}],PreToolUse:[{matcher:".*",hooks:[.hooks.PreToolUse[].hooks[] | select(.command | contains("fm-claude-watch-guard"))]}]}}' \
  "$ROOT/.claude/settings.json" > "$LAB/.claude/settings.json"
cat > "$LAB/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
[ ! -e "$FM_HOME/state/fail-arm" ] || exit 1
touch "$FM_HOME/state/.last-watcher-beat"
printf '%s\n' "$$" >> "$FM_HOME/state/cycles"
sleep 0.1
printf 'signal: fixture\n'
SH
cat > "$LAB/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
touch "$FM_HOME/state/sent"
SH
chmod +x "$LAB/bin/fm-watch-arm.sh" "$LAB/bin/fm-send.sh"
# The first command records the real harness ancestor via the production lock
# owner. Following tools then run under its ordinary session ownership proof.
PROMPT='Run these Bash commands in order, with no other tools:
1. bin/fm-lock.sh
2. echo "project=fixture" > state/task.meta; (wc -l < state/cycles 2>/dev/null || echo 0) > state/cycles-before-tool; sleep 8; wc -l < state/cycles > state/cycles-after-tool
3. touch state/fail-arm; sleep 1; touch -t 200001010000 state/.last-watcher-beat
4. bin/fm-send.sh fixture hello
After the fourth command is denied, say FINISHED and stop. Do not retry or bypass a denial.'
VERSION=$(claude --version)
(
  cd "$LAB" || exit 1
  FM_HOME="$LAB" FM_TEST_SEAM=1 FM_TEST_CLAUDE_WATCH_INTERVAL=0.05 \
    CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --effort low \
    --output-format stream-json --verbose
) > "$LAB/transcript.jsonl" 2>&1 || fail "$VERSION live hook session failed"
[ -s "$LAB/state/cycles-before-tool" ] && [ -s "$LAB/state/cycles-after-tool" ] || fail "$VERSION missing tool interval observations"
[ "$(( $(cat "$LAB/state/cycles-after-tool") - $(cat "$LAB/state/cycles-before-tool") ))" -ge 3 ] || fail "$VERSION fewer than three new during-tool cycles"
[ ! -e "$LAB/state/sent" ] || fail "$VERSION stale send executed"
grep -q 'New spawns and sends are refused' "$LAB/transcript.jsonl" || fail "$VERSION no observed PreToolUse denial"
pass "$VERSION async continuity ran during a tool; synchronous stale send refused"
printf 'FM_TEST_COMPLETE\n'
