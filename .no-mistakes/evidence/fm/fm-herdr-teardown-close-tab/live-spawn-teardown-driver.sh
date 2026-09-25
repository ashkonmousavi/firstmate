#!/usr/bin/env bash
# Live validation driver (no-mistakes test phase, not part of the repo).
# Drives the REAL bin/fm-spawn.sh and bin/fm-teardown.sh from <root> against a
# throwaway fm-lab-* Herdr session created and torn down through
# bin/fm-herdr-lab.sh, with the machine's real herdr-sidebar plugin docking its
# own "Sidebar" pane (never a stand-in). Records Herdr layout JSON after every
# step into <outdir> and prints one CHECK line per observable result.
# Usage: live-spawn-teardown-driver.sh <root> <outdir>
set -u
ROOT=$(cd "$1" && pwd)
OUT=$2
mkdir -p "$OUT"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

HERDR_ORIGINAL_PATH=$PATH
REAL_HERDR=$(command -v herdr)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-sidebar.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-sidebar)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH REAL_HERDR
WTS=()
cleanup() {
  local w
  for w in "${WTS[@]}"; do treehouse return --force "$w" >/dev/null 2>&1; done
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 \
    && echo "lab teardown ok ($HERDR_LAB_SESSION)" || echo "LAB TEARDOWN FAILED ($HERDR_LAB_SESSION)"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 || { echo "provision failed"; exit 1; }
echo "lab session: $HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do case "$arg" in --session|--session=*) echo "shim: foreign session flag" >&2; exit 9 ;; esac; done
if [ "${1:-}" = --version ]; then exec env PATH="$HERDR_ORIGINAL_PATH" "$REAL_HERDR" "$@" --session "$HERDR_LAB_SESSION"; fi
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"
export HERDR_SESSION="$HERDR_LAB_SESSION"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
check() { if eval "$2"; then echo "CHECK PASS: $1"; else echo "CHECK FAIL: $1"; fi; }

layout() {  # <step-name>: dump workspaces -> tabs -> panes
  lab api snapshot | jq '.result.snapshot as $s | [$s.workspaces[] | {workspace_id, label, tabs: [ $s.tabs[] as $t | select($t.workspace_id == .workspace_id) | {tab_id: $t.tab_id, label: $t.label, panes: [ $s.panes[] | select(.tab_id == $t.tab_id) | {pane_id, label, agent: (.agent // null), agent_status: (.agent_status // null)} ]} ]}]' \
    > "$OUT/$1.json"
}
ws_of() { lab pane get "$1" 2>/dev/null | jq -r '.result.pane.workspace_id // empty'; }
tab_of() { lab pane get "$1" 2>/dev/null | jq -r '.result.pane.tab_id // empty'; }
ws_present() { lab workspace list | jq -e --arg w "$1" 'any(.result.workspaces[]; .workspace_id == $w)' >/dev/null 2>&1; }
tab_present() { lab api snapshot | jq -e --arg t "$1" 'any(.result.snapshot.tabs[]; .tab_id == $t)' >/dev/null 2>&1; }
tab_labels() { lab tab list --workspace "$1" 2>/dev/null | jq -c '[.result.tabs[].label]'; }
wait_sidebar() {  # <tab-id>: wait for the real plugin to dock; record its pane
  local i
  for i in $(seq 1 40); do
    if lab api snapshot | jq -e --arg t "$1" 'any(.result.snapshot.panes[]; .tab_id == $t and .label == "Sidebar")' >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

make_home() {  # <dir> <off|on>
  mkdir -p "$1/state" "$1/data" "$1/config"
  [ "$2" = off ] && printf 'off\n' > "$1/config/herdr-presentation-spaces"
  return 0
}
brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  fm_test_prep_record "$1/data" "$2" || exit 1
  printf '# Task\n## Captain'"'"'s intent\nLive sidebar-tab validation %s.\n\n## Firstmate spec\nNothing to do.\n' "$2" > "$1/data/$2/brief.md"
}
spawn() {  # <home> <id> <project>
  brief "$1" "$2"
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    "$ROOT/bin/fm-spawn.sh" "$2" "$3" "sh -c 'echo $2-ok; while :; do sleep 60; done'" --mode local-only --yolo off --backend herdr \
    >"$OUT/spawn-$2.log" 2>&1 || { echo "SPAWN FAILED $2 (see spawn-$2.log)"; tail -5 "$OUT/spawn-$2.log"; return 1; }
  local wt; wt=$(grep '^worktree=' "$1/state/$2.meta" | cut -d= -f2-); [ -n "$wt" ] && WTS+=("$wt")
  grep '^herdr_pane_id=' "$1/state/$2.meta" | cut -d= -f2-
}
teardown() {  # <home> <id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" FM_GATE_REFUSE_BYPASS=1 FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$1/state" FM_DATA_OVERRIDE="$1/data" FM_CONFIG_OVERRIDE="$1/config" \
    "$ROOT/bin/fm-teardown.sh" "$2" --force >"$OUT/teardown-$2.log" 2>&1 \
    || { echo "TEARDOWN FAILED $2 (see teardown-$2.log)"; tail -5 "$OUT/teardown-$2.log"; return 1; }
}

PROJ="$TMP_ROOT/project"
mkdir -p "$PROJ"; git -C "$PROJ" init -q; printf '# scratch\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md; git -C "$PROJ" -c user.name=t -c user.email=t@example.invalid commit -qm initial
git clone --quiet --bare "$PROJ" "$PROJ.origin.git"; git -C "$PROJ" remote add origin "file://$PROJ.origin.git"
HOME_DIR="$TMP_ROOT/home"; make_home "$HOME_DIR" off
layout 00-initial

# --- Flat: first spawn creates the per-home workspace; seeded tab "1" must go whole.
FA=$(spawn "$HOME_DIR" fa "$PROJ") || exit 1
FA_TAB=$(tab_of "$FA"); FLAT_WS=$(ws_of "$FA")
wait_sidebar "$FA_TAB" && echo "real plugin docked a Sidebar pane in fa's tab" || echo "NOTE: no plugin Sidebar docked in fa's tab"
sleep 2
layout 01-after-spawn-fa
lab api snapshot | jq --arg t "$FA_TAB" '[.result.snapshot.panes[] | select(.tab_id == $t and .label == "Sidebar")]' > "$OUT/real-plugin-sidebar-pane.json"
check "flat spawn fa: per-home workspace keeps no seeded tab \"1\" (tabs=$(tab_labels "$FLAT_WS"))" \
  '! lab tab list --workspace "$FLAT_WS" | jq -e "any(.result.tabs[]; .label == \"1\")" >/dev/null'
check "real plugin Sidebar pane matches the cleanup predicate (label Sidebar, no agent, status unknown/absent)" \
  'jq -e "length > 0 and all(.[]; .label == \"Sidebar\" and (.agent // null) == null and ((.agent_status // \"unknown\") == \"unknown\"))" "$OUT/real-plugin-sidebar-pane.json" >/dev/null'

FB=$(spawn "$HOME_DIR" fb "$PROJ") || exit 1
FB_TAB=$(tab_of "$FB")
wait_sidebar "$FB_TAB" || echo "NOTE: no plugin Sidebar docked in fb's tab"
layout 02-after-spawn-fb

teardown "$HOME_DIR" fa || exit 1
sleep 1
layout 03-after-teardown-fa
check "flat teardown fa: fa's task tab is closed, not left holding only the Sidebar pane" '! tab_present "$FA_TAB"'
check "flat teardown fa: fb's tab and pane survive" 'tab_present "$FB_TAB" && lab pane get "$FB" >/dev/null 2>&1'

# --- Projected: presentation spaces on (default); per-task workspace must go.
rm -f "$HOME_DIR/config/herdr-presentation-spaces"
PJ=$(spawn "$HOME_DIR" pj1 "$PROJ") || exit 1
PJ_WS=$(ws_of "$PJ"); PJ_TAB=$(tab_of "$PJ")
wait_sidebar "$PJ_TAB" && echo "real plugin docked a Sidebar pane in pj1's projected tab" || echo "NOTE: no plugin Sidebar docked in pj1's tab"
layout 04-after-spawn-pj1
check "projected spawn pj1: has a presentation journal and its own workspace" \
  '[ -f "$HOME_DIR/state/pj1.herdr-presentation" ] && [ "$PJ_WS" != "$FLAT_WS" ]'
teardown "$HOME_DIR" pj1 || exit 1
sleep 1
layout 05-after-teardown-pj1
check "projected teardown pj1: its per-task workspace is removed, not left sidebar-only" '! ws_present "$PJ_WS"'
check "projected teardown pj1: flat fb survives" 'lab pane get "$FB" >/dev/null 2>&1'
printf 'off\n' > "$HOME_DIR/config/herdr-presentation-spaces"

# --- Flat last tab: tearing down fb empties the per-home workspace.
teardown "$HOME_DIR" fb || exit 1
sleep 1
layout 06-after-teardown-fb
check "flat teardown fb (last task tab): the per-home workspace is removed, not left with a sidebar-only tab" '! ws_present "$FLAT_WS"'

# --- Respawn recreates the workspace without a leftover seeded tab.
FC=$(spawn "$HOME_DIR" fc "$PROJ") || exit 1
FC_WS=$(ws_of "$FC"); FC_TAB=$(tab_of "$FC")
wait_sidebar "$FC_TAB" || echo "NOTE: no plugin Sidebar docked in fc's tab"
sleep 2
layout 07-after-spawn-fc
check "respawn fc: recreated per-home workspace holds only fc's tab (tabs=$(tab_labels "$FC_WS"))" \
  'lab tab list --workspace "$FC_WS" | jq -e "[.result.tabs[].label] == [\"fm-fc\"]" >/dev/null'
teardown "$HOME_DIR" fc || exit 1
sleep 1
layout 08-after-teardown-fc
check "teardown fc: workspace removed again" '! ws_present "$FC_WS"'
check "no task-labelled tab lingers anywhere in the lab session" \
  '! lab api snapshot | jq -e "any(.result.snapshot.tabs[]; .label | startswith(\"fm-\"))" >/dev/null'
