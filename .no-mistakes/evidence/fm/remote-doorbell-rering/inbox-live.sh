#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.inbox-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB/home" >/dev/null
export FM_HOME="$LAB/home"
. bin/fm-task-inbox-lib.sh
mkdir -p "$FM_HOME/bin" "$FM_HOME/state/parent-route"
printf 'rsm\n' > "$FM_HOME/.fm-secondmate-home"
printf 'isolated protocol validation home\n' > "$FM_HOME/AGENTS.md"
printf '%s\n' 'window=fm-remote:p1' 'worktree=-' 'project=-' 'backend=herdr' 'endpoint_task_id=rsm' 'harness=claude' 'herdr_session=fm-remote' 'herdr_workspace_id=w1' 'herdr_tab_id=t1' 'herdr_pane_id=p1' > "$FM_HOME/state/parent-route/rsm.meta"
state="$FM_HOME/state/parent-route"
ctl() { env -i PATH="$PATH" HOME="$HOME" FM_HOME="$FM_HOME" "$ROOT/bin/fm-remote-secondmate-control.sh" inbox rsm "$@"; }
# Oracle: author intent requires grace, configured budget and acknowledgement boundaries.
a=$(fm_task_inbox_write_idempotent "$state" rsm 'rename metric')
result=$(ctl due 3600 1); printf 'fresh record, 3600s grace: %s\n' "$result"; [ "$result" = quiet ]
touch -d '2 minutes ago' "$a"
result=$(ctl due 1 1); printf 'aged record, 1s grace / 1 attempt maximum: %s\n' "$result"; [ "$result" = 'ring 001.msg' ]
fm_task_inbox_record_ring "$state" rsm "$a"
result=$(ctl due 1 1); printf 'after one recorded attempt, maximum=1: %s\n' "$result"; [ "$result" = 'escalate 001.msg 1' ]
result=$(ctl due 0 3); printf 'same state, maximum=3, zero grace: %s\n' "$result"; [ "$result" = 'ring 001.msg' ]
ctl escalated 001.msg
result=$(ctl due 1 1); printf 'after escalation marker: %s\n' "$result"; [ "$result" = quiet ]
mv "$a" "$state/rsm.inbox/handled/"
result=$(ctl ring 001.msg); printf 'ring requested after acknowledgement: %s\n' "$result"; [ "$result" = handled ]
result=$(ctl due 1 1); printf 'acknowledged inbox: %s\n' "$result"; [ "$result" = quiet ]
[ ! -e "$state/rsm.inbox/.ring-state" ]
# Oracle: equal bodies and equal delivery modes dedup, same-size unequal bodies do not.
dedup="$LAB/dedup"
a=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond line')
b=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond line')
c=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond lime')
d=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond line' fire-and-forget)
e=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond line' fire-and-forget)
[ "$a" = "$b" ]; [ "$a" != "$c" ]; [ "$d" != "$a" ]; [ "$d" = "$e" ]
mv "$a" "$dedup/rsm.inbox/handled/"
f=$(fm_task_inbox_write_idempotent "$dedup" rsm $'multi-byte héllo\nsecond line')
[ "$f" = "$dedup/rsm.inbox/handled/001.msg" ]
printf 'dedup: exact=%s repeated=%s distinct-same-size=%s fire-and-forget=%s repeated-fire-and-forget=%s post-ack=%s\n' "${a##*/}" "${b##*/}" "${c##*/}" "${d##*/}" "${e##*/}" "handled/${f##*/}"
for rec in "$dedup/rsm.inbox/handled/001.msg" "$c" "$d"; do printf '\nPersisted record %s:\n' "${rec#"$dedup/"}"; cat "$rec"; done
printf '\nAll direct protocol assertions passed; no Herdr ring or lifecycle command was invoked.\n'
