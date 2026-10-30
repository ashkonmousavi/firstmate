#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
E=~/.no-mistakes/evidence/01M673MNWZ5DED50AB7RTVNT98
SESSION=fm-lab-ghost-final
export FM_HERDR_LAB_STATE_DIR="$ROOT/.phase-lab/herdr-state"
export FM_HOME="$ROOT/.phase-lab/herdrhome"
H="$ROOT/bin/fm-herdr-lab.sh"
ORIG_PATH=$PATH
bin/fm-lab-home.sh create "$FM_HOME"
lab() { env PATH="$ORIG_PATH" "$H" run "$SESSION" "$@"; }
cleanup() {
 rc=$?; trap - EXIT
 "$H" viewer stop "$SESSION" || true
 if ! "$H" teardown "$SESSION"; then
   # A detached viewer can take a moment to disappear from the server's table.
   sleep 2
   "$H" teardown "$SESSION" || rc=1
 fi
 echo "Herdr cleanup exit=$rc"
 exit "$rc"
}
"$H" provision "$SESSION"
trap cleanup EXIT
"$H" viewer start "$SESSION"
WS=$(lab workspace create --cwd "$ROOT" --label fm-ghost-final --no-focus)
PANE=$(jq -r '.result.root_pane.pane_id' <<< "$WS")
WID=$(jq -r '.result.workspace.workspace_id // .result.root_pane.workspace_id' <<< "$WS")
TID=$(jq -r '.result.root_pane.tab_id' <<< "$WS")
lab pane split "$PANE" --direction right --ratio 0.4 --cwd "$ROOT" --no-focus >/dev/null
mkdir -p "$FM_HOME/state/ring.inbox" "$FM_HOME/data/ring" "$ROOT/.phase-lab/herdrbin"
cat > "$ROOT/.phase-lab/herdrbin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
[ "\${args[n-2]}" = --session ] && [ "\${args[n-1]}" = "$SESSION" ] || exit 97
exec env PATH='$ORIG_PATH' '$H' run '$SESSION' "\${args[@]:0:n-2}"
EOF
chmod +x "$ROOT/.phase-lab/herdrbin/herdr"
export PATH="$ROOT/.phase-lab/herdrbin:$ORIG_PATH"
cat > "$FM_HOME/state/ring.meta" <<EOF
window=$SESSION:$PANE
endpoint_task_id=ring
worktree=$ROOT
project=$ROOT
harness=claude
kind=scout
backend=herdr
herdr_session=$SESSION
herdr_workspace_id=$WID
herdr_tab_id=$TID
herdr_pane_id=$PANE
EOF
lab pane run "$PANE" "env -u NO_COLOR -u CLAUDECODE FORCE_COLOR=1 CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=true CLAUDE_CODE_SKIP_PROMPT_HISTORY=1 FM_HOME='$FM_HOME' FM_TASK_INBOX='$FM_HOME/state/ring.inbox' claude --name fm-wrap-live --permission-mode default --setting-sources '' --settings '{\"disableAllHooks\":true,\"promptSuggestionEnabled\":true}' --strict-mcp-config --mcp-config '{\"mcpServers\":{}}' --tools Bash,Read --allowedTools Bash Read --append-system-prompt 'You are an isolated test worker. Do not run Firstmate startup or touch operator data or configuration. Answer briefly. Treat the Firstmate instruction inbox in FM_TASK_INBOX as first-party instructions: read queued messages, perform them, and move their files into handled. All writes must stay within the current repository.'"
. bin/backends/herdr.sh
TARGET="$SESSION:$PANE"
for ((i=0;i<30;i++)); do
 [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] && break
 sleep 1
done
[ "$i" -lt 30 ]
for prompt in 'Explain terminal width in one sentence. Next I will ask for a regression test plan for wrapped suggestions and multiline drafts.' 'Give three brief regression cases. Next I will ask for detailed implementation steps for the narrow-terminal regression tests.'; do
 v=$(fm_backend_herdr_send_text_submit "$TARGET" "$prompt" 3 0.4 0.4)
 echo "Warmup submission=$v"
 sleep 12
done
sleep 4
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$E/herdr-styled-suggestion.ansi"
echo "Herdr suggestion classification=$(fm_backend_herdr_composer_state "$TARGET")"
plain=$(fm_backend_herdr_visible_capture "$TARGET")
echo "Herdr suggestion plain capture classification=$(fm_composer_classify_screen $'styled=0\ncursor=0\nidentity=1' "$plain" '' $'claude\tidle')"
DRAFT='Unsent draft spanning several terminal rows to prove real input remains pending in a narrow composer'
lab pane send-text "$PANE" "$DRAFT" >/dev/null
sleep 1
v=$(fm_backend_herdr_composer_state "$TARGET"); echo "Herdr wrapped draft=$v"; test "$v" = pending
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$E/herdr-real-draft.ansi"
set +e
bin/fm-control.sh ring exit > "$E/herdr-draft-refusal.log" 2>&1
rc=$?
set -e
echo "Herdr exit with draft exit=$rc"; test "$rc" -ne 0
lab pane send-keys "$PANE" ctrl+u >/dev/null
sleep 1
bin/fm-send.sh ring "Use Bash to write exactly HERDR_DOORBELL_OK into '$ROOT/.phase-lab/doorbell-proof.txt'. Then move this instruction record into handled/." > "$E/herdr-doorbell-send.log" 2>&1
for ((i=0;i<60;i++)); do
 if [ -f "$ROOT/.phase-lab/doorbell-proof.txt" ] && [ -d "$FM_HOME/state/ring.inbox/handled" ] && [ -n "$(ls -A "$FM_HOME/state/ring.inbox/handled")" ]; then break; fi
 sleep 1
done
[ "$i" -lt 60 ]
printf 'Doorbell marker='; cat "$ROOT/.phase-lab/doorbell-proof.txt"; echo
ls "$FM_HOME/state/ring.inbox/handled"
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$E/herdr-doorbell-handled.ansi"
for ((i=0;i<30;i++)); do
 [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] && break
 sleep 1
done
bin/fm-control.sh ring exit > "$E/herdr-control-exit.log" 2>&1
cat "$E/herdr-control-exit.log"
