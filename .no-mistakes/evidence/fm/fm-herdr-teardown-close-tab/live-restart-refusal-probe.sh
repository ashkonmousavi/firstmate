#!/usr/bin/env bash
# Adversarial live probe for the widened restart-cleanup husk gates
# (bin/fm-herdr-session-cleanup.sh), modeled on
# tests/fm-herdr-session-cleanup-e2e.test.sh: projected husks whose only tab
# holds an idle shell plus ONE extra pane that is NOT a sidebar-predicate pane
# (labelled "Explorer" - the real plugin's transient label - or "notes") must
# be preserved with their journals across a real session restart + cleanup.
# A control husk with a "Sidebar" extra pane must be retired.
# Usage: live-restart-refusal-probe.sh <root>
set -u
ROOT=$(cd "$1" && pwd)
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
REAL_HERDR=$(command -v herdr); HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d /tmp/fm-live-refusal.XXXXXX); FAKEBIN="$TMP_ROOT/fakebin"; HOME_DIR="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/config"
touch "$HOME_DIR/config/herdr-presentation-spaces"; printf 'herdr\n' > "$HOME_DIR/config/backend"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-refusal)
export HERDR_LAB_HELPER HERDR_LAB_SESSION REAL_HERDR HERDR_ORIGINAL_PATH
trap 'env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 && echo "lab teardown ok ($HERDR_LAB_SESSION)" || echo "LAB TEARDOWN FAILED"; rm -rf "$TMP_ROOT"' EXIT
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null || exit 1
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
for arg in "$@"; do case "$arg" in --session|--session=*) exit 9 ;; esac; done
if [ "${1:-}" = --version ]; then exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"; fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
ANCHOR=$(lab workspace create --cwd "$ROOT" --label captain-anchor --focus); ANCHOR_TAB=$(printf '%s' "$ANCHOR" | jq -r .result.tab.tab_id)
declare -A WS PANE
husk() {  # <id> <token> <extra-label>
  local c; c=$(lab workspace create --cwd "$ROOT" --label "└ $1 · p:$2" --no-focus)
  WS[$1]=$(printf '%s' "$c" | jq -r .result.workspace.workspace_id); PANE[$1]=$(printf '%s' "$c" | jq -r .result.root_pane.pane_id)
  local x; x=$(lab pane split "${PANE[$1]}" --direction right --no-focus | jq -er .result.pane.pane_id); lab pane rename "$x" "$3" >/dev/null
  printf 'version=1\ntask_id=%s\nprojection_id=%s\n' "$1" "$2" > "$HOME_DIR/state/$1.herdr-presentation"
}
husk explorer-husk ExPlOrErHuSkToKeN0000A Explorer
husk notes-husk NoTeSHuSkToKeN0000000B notes
husk sidebar-husk SiDeBaRHuSkToKeN00000C Sidebar
"$HERDR_LAB_HELPER" stop "$HERDR_LAB_SESSION" >/dev/null; "$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >/dev/null
lab tab focus "$ANCHOR_TAB" >/dev/null
sleep 2
echo "before cleanup: $(lab api snapshot | jq -c '[.result.snapshot.workspaces[] | {label, pane_count}]')"
FM_HOME="$HOME_DIR" FM_BACKEND=herdr HERDR_SESSION="$HERDR_LAB_SESSION" PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" \
  "$ROOT/bin/fm-herdr-session-cleanup.sh" 2>&1 | sed 's/^/cleanup: /'
echo "after cleanup: $(lab api snapshot | jq -c '[.result.snapshot.workspaces[] | {label, pane_count}]')"
for id in explorer-husk notes-husk; do
  if lab workspace get "${WS[$id]}" >/dev/null 2>&1 && lab pane get "${PANE[$id]}" >/dev/null 2>&1 && [ -e "$HOME_DIR/state/$id.herdr-presentation" ]; then
    echo "CHECK PASS: $id (extra non-Sidebar pane) preserved with its journal"
  else echo "CHECK FAIL: $id was retired although its tab holds a non-Sidebar pane"; fi
done
if ! lab workspace get "${WS[sidebar-husk]}" >/dev/null 2>&1 && [ ! -e "$HOME_DIR/state/sidebar-husk.herdr-presentation" ]; then
  echo "CHECK PASS: control sidebar-husk retired with its sidebar-only workspace and journal"
else echo "CHECK FAIL: control sidebar-husk survived"; fi
