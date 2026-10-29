#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=~/.no-mistakes/evidence/01M63R443T82ZMZXQEE1THNFZV
ORIGINAL_PATH=$PATH
export FM_HERDR_LAB_STATE_DIR="$PWD/.test-phase-tmp/herdr-state"
LAB_HELPER="$PWD/bin/fm-herdr-lab.sh"
SESSION=$("$LAB_HELPER" name submit-remote)
LAB=$(mktemp -d "$PWD/.test-phase-tmp/remote.XXXXXX")
export LAB SESSION LAB_HELPER ORIGINAL_PATH
cleanup() {
  rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" > "$EVIDENCE/remote-live-teardown.log" 2>&1 || rc=1
  rm -rf "$LAB"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"
lab() { PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
ws=$(lab workspace create --cwd "$ROOT" --label fm-remote-live --no-focus)
pane=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
wid=$(printf '%s' "$ws" | jq -er '.result.workspace.workspace_id')
tid=$(printf '%s' "$ws" | jq -er '.result.tab.tab_id')
"$ROOT/bin/fm-lab-home.sh" create "$LAB/home" >/dev/null
home="$LAB/home"
printf 'rsm\n' > "$home/.fm-secondmate-home"
ln -s "$ROOT/AGENTS.md" "$home/AGENTS.md"
ln -s "$ROOT/bin" "$home/bin"
mkdir -p "$home/state/parent-route" "$LAB/shim"
printf 'window=fm-remote:%s\nworktree=-\nproject=-\nbackend=herdr\nendpoint_task_id=rsm\nharness=claude\nherdr_session=fm-remote\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$pane" "$wid" "$tid" "$pane" > "$home/state/parent-route/rsm.meta"
printf -v cmd 'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 FM_HOME=%q %q --dangerously-skip-permissions --setting-sources user --settings %q' "$home" "$ROOT/.test-phase-tmp/auth-shim/claude" '{"feedbackDrafts":"off"}'
lab pane run "$pane" "$cmd" >/dev/null
ready=0
for i in {1..60}; do
  screen=$(lab pane read "$pane" --source visible)
  if [[ "$screen" == *'bypass permissions on'* ]]; then ready=1; break; fi
  sleep 1
done
[ "$ready" = 1 ] || { printf 'Claude never reached a composer\n'; exit 1; }
cat > "$LAB/shim/herdr" <<'WRAP'
#!/usr/bin/env bash
set -euo pipefail
args=("$@")
n=${#args[@]}
[ "${args[n-2]}" = --session ] && [ "${args[n-1]}" = fm-remote ] || exit 97
args=("${args[@]:0:n-2}")
if [ "${args[0]:-}" = pane ] && [ "${args[1]:-}" = send-keys ]; then
  printf '%s\n' "${args[*]}" >> "$LAB/swallowed"
  touch "$LAB/hide-capture"
  exit 0
fi
if [ -e "$LAB/hide-capture" ] && [ "${args[0]:-}" = pane ] && [ "${args[1]:-}" = read ]; then exit 1; fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "${args[@]}"
WRAP
chmod +x "$LAB/shim/herdr"
export PATH="$LAB/shim:$PATH"
. "$ROOT/bin/fm-backend.sh"
for i in {1..30}; do
  cstate=$(fm_backend_composer_state herdr "fm-remote:$pane" fm-rsm)
  [ "$cstate" != pending ] && break
  sleep 1
done
lab pane read "$pane" --source visible > "$EVIDENCE/remote-before-send.txt"
printf 'composer before send=%s\n' "$cstate"
rc=0
FM_HOME="$home" PATH="$LAB/shim:$PATH" bash "$ROOT/bin/fm-remote-secondmate-control.sh" send rsm 'Reply with REMOTE_RECORD_OK.' > "$EVIDENCE/remote-live-send.txt" 2>&1 || rc=$?
[ "$rc" = 0 ]
[ -f "$home/state/parent-route/rsm.inbox/001.msg" ]
[ ! -e "$home/state/parent-route/rsm.inbox/handled/001.msg" ]
grep -F 'doorbell NOT delivered:' "$EVIDENCE/remote-live-send.txt"
{
  printf 'exit=%s\ndurable record:\n' "$rc"
  cat "$home/state/parent-route/rsm.inbox/001.msg"
  printf '\nintercepted keys:\n'
  cat "$LAB/swallowed"
  printf '\nreal Herdr terminal:\n'
  lab pane read "$pane" --source visible
} >> "$EVIDENCE/remote-live-send.txt"
printf 'remote host-local send retained its record and reported NOT delivered with exit 0\n'
