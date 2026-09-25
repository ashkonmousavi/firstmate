#!/usr/bin/env bash
# Live probe (no-mistakes test phase): drive the direct-mode seeded-default-tab
# prune against a throwaway fm-lab-* session with the real herdr-sidebar plugin,
# in two timings: (A) immediately after workspace+tab create, as flat spawn does,
# and (B) after the plugin has docked its Sidebar pane into the seeded tab.
# Usage: live-seeded-prune-probe.sh <root> <outdir>
set -u
ROOT=$(cd "$1" && pwd)
OUT=$2
mkdir -p "$OUT"
HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
HERDR_ORIGINAL_PATH=$PATH
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-live-prune.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"; mkdir -p "$FAKEBIN"
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name live-prune)
export HERDR_LAB_HELPER HERDR_LAB_SESSION HERDR_ORIGINAL_PATH
cleanup() {
  env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 \
    && echo "lab teardown ok ($HERDR_LAB_SESSION)" || echo "LAB TEARDOWN FAILED"
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION" >>"$OUT/lab.log" 2>&1 || { echo provision failed; exit 1; }
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
args=("$@"); last=$((${#args[@]} - 1)); flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] && [ "${args[$flag]}" = --session ] && [ "${args[$last]}" = "$HERDR_LAB_SESSION" ]; then unset "args[$last]" "args[$flag]"; fi
set -- "${args[@]}"
out=$(env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"); rc=$?
printf '%s ms=%s\t%s\t-> rc=%s %s\n' "$(date +%T)" "$(date +%3N)" "$*" "$rc" "$(printf '%s' "$out" | tr -d '\n' | cut -c1-600)" >> "$PROBE_LOG"
printf '%s' "$out"; exit $rc
SH
chmod +x "$FAKEBIN/herdr"
lab() { env PATH="$HERDR_ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }

probe() {  # <name> <wait-for-sidebar:0|1>
  local name=$1 wait=$2 create ws seeded i
  export PROBE_LOG="$OUT/$name-herdr-calls.log"; : > "$PROBE_LOG"
  create=$(lab workspace create --cwd /tmp --label "probe-$name" --no-focus)
  ws=$(printf '%s' "$create" | jq -r '.result.workspace.workspace_id')
  seeded=$(printf '%s' "$create" | jq -r '.result.tab.tab_id')
  if [ "$wait" = 1 ]; then
    for i in $(seq 1 40); do
      lab pane list --workspace "$ws" | jq -e --arg t "$seeded" 'any(.result.panes[]; .tab_id == $t and .label == "Sidebar")' >/dev/null && break
      sleep 0.25
    done
  fi
  lab tab create --workspace "$ws" --cwd /tmp --label "fm-$name" --no-focus >/dev/null
  PATH="$FAKEBIN:$HERDR_ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_workspace_prune_seeded_default_tab "$2" "$3" "$4"' \
    _ "$ROOT" "$HERDR_LAB_SESSION" "$ws" "$seeded" 2>>"$OUT/$name-stderr.log"
  sleep 3
  lab api snapshot | jq --arg ws "$ws" '.result.snapshot as $s | {tabs: [$s.tabs[] | select(.workspace_id == $ws) | {tab_id, label}], panes: [$s.panes[] | select(.workspace_id == $ws) | {pane_id, tab_id, label, agent_status}]}' > "$OUT/$name-after.json"
  if lab tab list --workspace "$ws" | jq -e --arg t "$seeded" 'any(.result.tabs[]; .tab_id == $t)' >/dev/null; then
    echo "PROBE $name: seeded tab $seeded STILL PRESENT after prune: $(jq -c . "$OUT/$name-after.json")"
  else
    echo "PROBE $name: seeded tab $seeded removed"
  fi
}
probe A-spawn-timing 0
probe B-sidebar-docked-first 1
probe C-spawn-timing-repeat 0
