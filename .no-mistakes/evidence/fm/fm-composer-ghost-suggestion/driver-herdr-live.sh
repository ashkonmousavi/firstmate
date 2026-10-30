#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
export FM_HERDR_LAB_STATE_DIR="$ROOT/.phase-lab/herdr-state"
SESSION=fm-lab-ghost-integration
H="$ROOT/bin/fm-herdr-lab.sh"
lab() { "$H" run "$SESSION" "$@"; }
cleanup() { rc=$?; trap - EXIT; "$H" teardown "$SESSION" || rc=1; exit "$rc"; }
"$H" provision "$SESSION"
trap cleanup EXIT
"$H" viewer start "$SESSION"
lab pane split --help
WS=$(lab workspace create --cwd "$ROOT" --label fm-ghost-live --no-focus)
printf '%s\n' "$WS" > "$E/herdr-workspace.json"
PANE=$(jq -r '.result.root_pane.pane_id' <<< "$WS")
printf '%s\n' "$PANE" > "$ROOT/.phase-lab/herdr-pane"
lab pane run "$PANE" "env -u CLAUDECODE CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 claude --name fm-wrap-live --setting-sources '' --settings '{\"disableAllHooks\":true,\"promptSuggestionEnabled\":true}' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --tools '' --permission-mode default --append-system-prompt 'For this test answer briefly. Do not use tools or change files.'"
sleep 5
lab pane read "$PANE" --source visible --format ansi > "$E/herdr-startup.ansi"
lab pane send-text "$PANE" 'Explain in one sentence why terminal width matters for multiline composer detection. Next I will ask you to outline a detailed regression test plan for wrapped suggestions and multiline drafts.'
lab pane send-keys "$PANE" enter
sleep 15
lab pane read "$PANE" --source visible --format ansi > "$E/herdr-first-turn.ansi"
lab pane send-text "$PANE" 'List three short regression cases now; after that I will ask you to write detailed implementation steps for the test plan.'
lab pane send-keys "$PANE" enter
sleep 15
lab pane read "$PANE" --source visible --format ansi > "$E/herdr-second-turn.ansi"
printf 'READY pane=%s\n' "$PANE"
# Keep the owned server available for commands from this same test process.
for ((i=0;i<90;i++)); do
  if [ -e "$ROOT/.phase-lab/herdr-finish" ]; then break; fi
  sleep 1
done
