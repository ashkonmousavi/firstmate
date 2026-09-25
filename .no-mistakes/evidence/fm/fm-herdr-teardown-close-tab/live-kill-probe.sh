#!/usr/bin/env bash
# Live probe: flat adapter kill (fm_backend_herdr_kill_serialized from <root>) of
# a task pane whose tab holds the real herdr-sidebar plugin's settled "Sidebar"
# pane, in a throwaway fm-lab-* session. Records the tab state right after the
# kill and 4s later. Usage: live-kill-probe.sh <root> <outdir>
set -u
ROOT=$(cd "$1" && pwd); OUT=$2; mkdir -p "$OUT"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"; herdr_forget_inherited_pane
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d /tmp/fm-live-kill.XXXXXX); FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-kill)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
trap 'env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 && echo "lab teardown ok" || echo "LAB TEARDOWN FAILED"; rm -rf "$TMP_ROOT"' EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 || exit 1
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
C=$(lab workspace create --cwd /tmp --label kill-probe --no-focus); WS=$(printf '%s' "$C" | jq -r .result.workspace.workspace_id)
R=$(lab tab create --workspace "$WS" --cwd /tmp --label fm-kill --no-focus)
TAB=$(printf '%s' "$R" | jq -r .result.tab.tab_id); PANE=$(printf '%s' "$R" | jq -r .result.root_pane.pane_id)
for i in $(seq 1 60); do lab pane list --workspace "$WS" | jq -e --arg t "$TAB" 'any(.result.panes[]; .tab_id == $t and .label == "Sidebar")' >/dev/null && break; sleep 0.25; done
sleep 2
snap() { lab api snapshot | jq -c --arg t "$TAB" '{tab_present: any(.result.snapshot.tabs[]; .tab_id == $t), panes_in_tab: [.result.snapshot.panes[] | select(.tab_id == $t) | {pane_id, label, agent_status}]}'; }
echo "before kill: $(snap)"
PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_kill_serialized "$2" "$3"' _ "$ROOT" "$HERDR_LAB_SESSION" "$PANE" 2>&1
echo "right after kill: $(snap)"
sleep 4
echo "4s after kill: $(snap)"
