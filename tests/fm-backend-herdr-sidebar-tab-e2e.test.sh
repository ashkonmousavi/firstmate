#!/usr/bin/env bash
# Real-Herdr regression for task cleanup closing the task's own tab when only
# plugin sidebar panes remain in it (a sidebar plugin such as herdr-sidebar
# docks a pane labelled "Sidebar" into every new tab). A tab holding any other
# pane, and a workspace's last tab, must survive the cleanup.
# Works with or without the plugin installed: when the plugin docks no sidebar,
# the test stands one in with a split pane labelled "Sidebar".
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo 'skip: herdr not found'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq not found'; exit 0; }
[ -x "$HERDR_LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $HERDR_LAB_HELPER"; exit 0; }

HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-sidebar-tab-e2e.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name fm-herdr-sidebar-tab-close)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
cleanup() {
  local status=$?
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || status=1
  rm -rf "$TMP_ROOT"
  exit "$status"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

kill_task_pane() {  # <pane-id>
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      local session=$1
      shift
      HERDR_SESSION="$session" herdr "$@" --session "$session"
    }
    fm_backend_herdr_kill_serialized "$2" "$3"
  ' _ "$ROOT" "$HERDR_LAB_SESSION" "$1" 2>&1
}

tab_present() {  # <workspace-id> <tab-id>
  lab tab list --workspace "$1" | jq -e --arg tab "$2" 'any(.result.tabs[]; .tab_id == $tab)' >/dev/null 2>&1
}

split_pane() {  # <pane-id> <label> -> new pane id
  local out new
  out=$(lab pane split "$1" --direction right --no-focus) || return 1
  new=$(printf '%s' "$out" | jq -er '.result.pane.pane_id') || return 1
  lab pane rename "$new" "$2" >/dev/null || return 1
  printf '%s' "$new"
}

# ensure_sidebar: give <tab-id> a pane labelled "Sidebar". An installed
# sidebar plugin docks its own shortly after the tab appears; wait briefly for
# it so a later plugin replacement cannot race the cleanup, and otherwise
# stand one in.
ensure_sidebar() {  # <workspace-id> <tab-id> <root-pane-id>
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    lab pane list --workspace "$1" | jq -e --arg tab "$2" \
      'any(.result.panes[]; .tab_id == $tab and .label == "Sidebar")' >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  split_pane "$3" Sidebar >/dev/null
}

create_tab() {  # <workspace-id> <label> -> "<tab-id> <root-pane-id>"
  lab tab create --workspace "$1" --cwd /tmp --label "$2" --no-focus \
    | jq -er '"\(.result.tab.tab_id) \(.result.root_pane.pane_id)"'
}

CREATE=$(lab workspace create --cwd /tmp --label 'sidebar-tab' --no-focus) \
  || fail 'could not create the lab workspace'
WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') || fail 'could not read the workspace id'
KEEPER_TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id') || fail 'could not read the seeded tab id'

ROW=$(create_tab "$WS" fm-sidebar-close) || fail 'could not create the sidebar-only task tab'
read -r CLOSE_TAB CLOSE_PANE <<< "$ROW"
ensure_sidebar "$WS" "$CLOSE_TAB" "$CLOSE_PANE" || fail 'could not give the task tab a sidebar pane'
OUT=$(kill_task_pane "$CLOSE_PANE") || fail "cleanup failed: $OUT"
lab pane get "$CLOSE_PANE" >/dev/null 2>&1 && fail 'cleanup left the task pane behind'
tab_present "$WS" "$CLOSE_TAB" && fail "cleanup left the task tab open with only a sidebar pane in it: $OUT"
tab_present "$WS" "$KEEPER_TAB" || fail 'cleanup closed a tab that did not belong to the task'
pass 'cleanup closes the task tab once only a sidebar pane remains in it'

ROW=$(create_tab "$WS" fm-sidebar-keep) || fail 'could not create the mixed task tab'
read -r KEEP_TAB KEEP_PANE <<< "$ROW"
ensure_sidebar "$WS" "$KEEP_TAB" "$KEEP_PANE" || fail 'could not give the mixed tab a sidebar pane'
OTHER_PANE=$(split_pane "$KEEP_PANE" notes) || fail 'could not add a non-sidebar pane to the mixed tab'
OUT=$(kill_task_pane "$KEEP_PANE") || fail "cleanup failed: $OUT"
lab pane get "$KEEP_PANE" >/dev/null 2>&1 && fail 'cleanup left the mixed tab task pane behind'
tab_present "$WS" "$KEEP_TAB" || fail 'cleanup closed a tab that still held a non-sidebar pane'
lab pane get "$OTHER_PANE" >/dev/null 2>&1 || fail 'cleanup removed the non-sidebar pane'
pass 'cleanup leaves a tab holding any non-sidebar pane open'

CREATE=$(lab workspace create --cwd /tmp --label 'sidebar-last-tab' --no-focus) \
  || fail 'could not create the single-tab workspace'
LAST_WS=$(printf '%s' "$CREATE" | jq -er '.result.workspace.workspace_id') || fail 'could not read the single-tab workspace id'
LAST_TAB=$(printf '%s' "$CREATE" | jq -er '.result.tab.tab_id') || fail 'could not read the single tab id'
LAST_PANE=$(printf '%s' "$CREATE" | jq -er '.result.root_pane.pane_id') || fail 'could not read the single tab pane id'
ensure_sidebar "$LAST_WS" "$LAST_TAB" "$LAST_PANE" || fail 'could not give the single tab a sidebar pane'
OUT=$(kill_task_pane "$LAST_PANE") || fail "cleanup failed: $OUT"
tab_present "$LAST_WS" "$LAST_TAB" || fail "cleanup closed a workspace's last tab, deleting the workspace"
pass "cleanup never closes a workspace's last tab"
