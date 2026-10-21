#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.lab-validation/home"
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB" >/dev/null
ln -s "$ROOT/bin" "$LAB/bin"
ln -s "$ROOT/AGENTS.md" "$LAB/AGENTS.md"
printf 'rsm\n' > "$LAB/.fm-secondmate-home"
mkdir -p "$LAB/state/parent-route"
cat > "$LAB/state/parent-route/rsm.meta" <<'META'
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
. bin/fm-task-inbox-lib.sh
state="$LAB/state/parent-route"
control() { env -i PATH="$PATH" HOME="$HOME" FM_HOME="$LAB" "$ROOT/bin/fm-remote-secondmate-control.sh" inbox rsm "$@"; }
check() { local expected=$1; shift; local actual; actual=$("$@"); printf '%s => %s\n' "$*" "$actual"; [ "$actual" = "$expected" ]; }
rec=$(fm_task_inbox_write_idempotent "$state" rsm 'live inbox instruction')
check quiet control due 3600 1
touch -t 202001010000 "$rec"
check 'ring 001.msg' control due 1 1
# A saved attempt is protocol state; no claim is made that a doorbell was delivered.
printf '001.msg\t1\t%s\n' "$(date +%s)" > "$state/rsm.inbox/.ring-state"
check quiet control due 3600 3
check 'escalate 001.msg 1' control due 1 1
check escalated control escalated 001.msg
check quiet control due 1 1
mv "$rec" "$state/rsm.inbox/handled/"
check quiet control due 0 0
check handled control ring 001.msg
check "$state/rsm.inbox/handled/001.msg" fm_task_inbox_write_idempotent "$state" rsm 'live inbox instruction'
check "$state/rsm.inbox/002.msg" fm_task_inbox_write_idempotent "$state" rsm 'live inbox instructioN'
check "$state/rsm.inbox/003.msg" fm_task_inbox_write_idempotent "$state" rsm 'live inbox instruction' fire-and-forget
check "$state/rsm.inbox/003.msg" fm_task_inbox_write_idempotent "$state" rsm 'live inbox instruction' fire-and-forget
# Zero budget exposes the different next record, while the fire-and-forget record is excluded.
check 'escalate 002.msg 0' control due 0 0
mv "$state/rsm.inbox/002.msg" "$state/rsm.inbox/handled/"
check quiet control due 0 0
printf 'Direct host-local CLI checks completed; no transport or agent delivery was exercised.\n'
