#!/usr/bin/env bash
set -eu
lab="$PWD/.live-inbox-state"
trap 'rm -rf "$lab"' EXIT
mkdir "$lab"
bin/fm-lab-home.sh create "$lab/home" >/dev/null
export FM_HOME="$lab/home"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
mkdir -p "$FM_HOME/bin" "$FM_HOME/state/parent-route/rsm.inbox/handled"
printf 'rsm\n' > "$FM_HOME/.fm-secondmate-home"
printf '# Disposable test fixture only\n' > "$FM_HOME/AGENTS.md"
cat > "$FM_HOME/state/parent-route/rsm.meta" <<'META'
window=fm-remote:p1
worktree=-
project=-
backend=herdr
endpoint_task_id=rsm
harness=claude
herdr_session=fm-remote
herdr_workspace_id=w1
herdr_tab_id=t1
herdr_pane_id=p1
META
inbox="$FM_HOME/state/parent-route/rsm.inbox"
printf 'accepted test instruction\n' > "$inbox/001.msg"
ctl=bin/fm-remote-secondmate-control.sh
out=$($ctl inbox rsm due 3600 1)
printf 'Fresh record, grace=3600: %s\n' "$out"
[ "$out" = quiet ]
touch -t 202001010000 "$inbox/001.msg"
out=$($ctl inbox rsm due 1 1)
printf 'Aged unhandled record: %s\n' "$out"
[ "$out" = 'ring 001.msg' ]
mv "$inbox/001.msg" "$inbox/handled/"
out=$($ctl inbox rsm due 1 1)
printf 'After worker acknowledgement via handled/: %s\n' "$out"
[ "$out" = quiet ]
printf 'second accepted instruction\n' > "$inbox/002.msg"
touch -t 202001010000 "$inbox/002.msg"
printf '002.msg\t1\t1\n' > "$inbox/.ring-state"
out=$($ctl inbox rsm due 1 1)
printf 'Persisted exhausted budget, second record: %s\n' "$out"
[ "$out" = 'escalate 002.msg 1' ]
out=$($ctl inbox rsm escalated 002.msg)
printf 'Persist escalation marker: %s\n' "$out"
[ "$out" = escalated ]
out=$($ctl inbox rsm due 1 1)
printf 'After durable escalation marker: %s\n' "$out"
[ "$out" = quiet ]
