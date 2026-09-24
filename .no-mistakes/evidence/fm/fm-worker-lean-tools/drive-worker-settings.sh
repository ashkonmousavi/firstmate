#!/usr/bin/env bash
# Live driver for config/claude-worker-settings.json.
# Runs the real bin/fm-spawn.sh and bin/fm-config-push.sh in throwaway homes.
# The pane backend (tmux) is faked so no real worker starts, and the captured
# launch line is executed against an argv-capturing claude stub so we read the
# exact --settings value a worker would receive. That value is then handed to
# the real claude binary (`claude --settings ... mcp list`) to show which MCP
# servers a worker would actually start.
set -u
WT=${WT:?worktree}
EVID=${EVID:?evidence dir}
cd "$WT"
export GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=fmtest@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=fmtest@example.invalid
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-worker-settings-live)
EXAMPLE='{"enabledPlugins":{"pdf-viewer@synced":false},"deniedMcpServers":[{"serverName":"sequential-thinking"}]}'

fakebin_for() {
  local fb
  fb=$(fm_test_make_spawn_fakebin "$1")
  printf '#!/usr/bin/env bash\nshift\nexec "$@"\n' > "$fb/timeout"; chmod +x "$fb/timeout"
  printf '%s\n' "$fb"
}

spawn_claude() {  # <home> <id> <fakebin> <wt> <launchlog> <project> -> prints fm-spawn output
  local home=$1 id=$2 fb=$3 wt=$4 log=$5 proj=$6
  : > "$log"
  fm_test_spawn_brief "$home" "$id"
  CLAUDE_CONFIG_DIR= FM_FAKE_LAUNCH_LOG="$log" \
    fm_test_run_spawn "$home" "$wt" "$fb" "$id" "$proj" --mode no-mistakes --yolo off
}

settings_from_launch() {  # <launchlog> <fakebin> -> --settings value claude would get
  local log=$1 fb=$2 argv prev='' arg
  argv=$(mktemp)
  printf '#!/usr/bin/env bash\nprintf "%%s\\0" "$@" > "$FM_CLAUDE_ARGV"\n' > "$fb/claude"; chmod +x "$fb/claude"
  FM_CLAUDE_ARGV="$argv" PATH="$fb:$PATH" bash -c "$(cat "$log")"
  while IFS= read -r -d '' arg; do
    if [ "$prev" = --settings ]; then printf '%s' "$arg"; rm -f "$argv"; return 0; fi
    prev=$arg
  done < "$argv"
  rm -f "$argv"; return 1
}

echo "### Scenario A: primary home with the captain's example file -> claude crewmate spawn"
A=$TMP_ROOT/primary; fm_test_spawn_home "$A/home" claude
fm_git_worktree "$A/project" "$A/wt" wt-a >/dev/null
printf '%s\n' "$EXAMPLE" > "$A/home/config/claude-worker-settings.json"
FB=$(fakebin_for "$A/fake")
spawn_claude "$A/home" lean-a1 "$FB" "$A/wt" "$A/launch.log" "$A/project"; echo "fm-spawn exit=$?"
echo "--- launch line typed into the worker pane:"; cat "$A/launch.log"; echo
SA=$(settings_from_launch "$A/launch.log" "$FB") || echo "NO --settings"
echo "--- --settings value claude receives:"; printf '%s\n' "$SA" | jq -c .
printf '%s' "$SA" > "$EVID/settings-primary-crewmate.json"

echo; echo "### Scenario B: no file -> launch unchanged (firstmate keys only)"
B=$TMP_ROOT/absent; fm_test_spawn_home "$B/home" claude
fm_git_worktree "$B/project" "$B/wt" wt-b >/dev/null
FB=$(fakebin_for "$B/fake")
spawn_claude "$B/home" plain-b1 "$FB" "$B/wt" "$B/launch.log" "$B/project"; echo "fm-spawn exit=$?"
cat "$B/launch.log"; echo

echo; echo "### Scenario C: file tries to re-enable attribution/feedback -> firstmate keys win"
C=$TMP_ROOT/override; fm_test_spawn_home "$C/home" claude
fm_git_worktree "$C/project" "$C/wt" wt-c >/dev/null
printf '%s\n' '{"enabledPlugins":{"pdf-viewer@synced":false},"feedbackDrafts":"on","attribution":{"commit":"Co-Authored-By: bot","pr":"made by bot"}}' > "$C/home/config/claude-worker-settings.json"
FB=$(fakebin_for "$C/fake")
spawn_claude "$C/home" override-c1 "$FB" "$C/wt" "$C/launch.log" "$C/project"; echo "fm-spawn exit=$?"
settings_from_launch "$C/launch.log" "$FB" | jq -c .

echo; echo "### Scenario D: malformed file -> spawn refused, nothing launched, no record"
for content in '{"enabledPlugins":' '[{"enabledPlugins":{}}]' ''; do
  D=$TMP_ROOT/bad-$RANDOM; fm_test_spawn_home "$D/home" claude
  fm_git_worktree "$D/project" "$D/wt" wt-d >/dev/null
  printf '%s\n' "$content" > "$D/home/config/claude-worker-settings.json"
  FB=$(fakebin_for "$D/fake")
  out=$(spawn_claude "$D/home" bad-d1 "$FB" "$D/wt" "$D/launch.log" "$D/project"); rc=$?
  printf 'file=%q exit=%s output=%s launch-log-bytes=%s meta=%s\n' "$content" "$rc" "$out" \
    "$(wc -c < "$D/launch.log")" "$([ -e "$D/home/state/bad-d1.meta" ] && echo present || echo absent)"
done

echo; echo "### Scenario E: primary file -> fm-config-push -> secondmate home -> secondmate's own crewmate"
W=$TMP_ROOT/world; mkdir -p "$W/home/state" "$W/home/data" "$W/home/config"
touch "$W/home/state/.last-watcher-beat"
git init -q -b main "$W/main"
printf 'projects/\nstate/\ndata/\n.no-mistakes/\nconfig/claude-worker-settings.json\nconfig/crew-harness\n' > "$W/main/.gitignore"
mkdir -p "$W/main/bin"; printf 'echo a\n' > "$W/main/bin/tool.sh"; printf 'v1\n' > "$W/main/AGENTS.md"; git -C "$W/main" add -A; git -C "$W/main" commit -qm c1
git -C "$W/main" worktree add -q --detach "$W/sm" HEAD
printf 'sm\n' > "$W/sm/.fm-secondmate-home"
printf 'window=firstmate:fm-sm\nkind=secondmate\nhome=%s/sm\n' "$W" > "$W/home/state/sm.meta"
printf '%s\n' "$EXAMPLE" > "$W/home/config/claude-worker-settings.json"
PFB="$W/pushbin"; mkdir -p "$PFB"; fm_fake_exit0 "$PFB" tmux node
PATH="$PFB:$PATH" FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/main" FM_SEND_SETTLE=0 "$WT/bin/fm-config-push.sh"; echo "fm-config-push exit=$?"
echo "--- secondmate home config/claude-worker-settings.json:"; cat "$W/sm/config/claude-worker-settings.json"
fm_test_spawn_home "$W/sm" claude
fm_git_worktree "$W/project" "$W/smwt" wt-e >/dev/null
FB=$(fakebin_for "$W/fake")
spawn_claude "$W/sm" smcrew-e1 "$FB" "$W/smwt" "$W/launch.log" "$W/project"; echo "fm-spawn (secondmate home) exit=$?"
SE=$(settings_from_launch "$W/launch.log" "$FB") || echo "NO --settings"
echo "--- --settings value the secondmate's crewmate receives:"; printf '%s\n' "$SE" | jq -c .
printf '%s' "$SE" > "$EVID/settings-secondmate-crewmate.json"
rm -f "$W/home/config/claude-worker-settings.json"
PATH="$PFB:$PATH" FM_HOME="$W/home" FM_ROOT_OVERRIDE="$W/main" FM_SEND_SETTLE=0 "$WT/bin/fm-config-push.sh" >/dev/null 2>&1
echo "after primary removal + push, secondmate copy: $([ -e "$W/sm/config/claude-worker-settings.json" ] && echo present || echo removed)"
git -C "$W/main" worktree remove --force "$W/sm" 2>/dev/null
rm -rf "$TMP_ROOT"
