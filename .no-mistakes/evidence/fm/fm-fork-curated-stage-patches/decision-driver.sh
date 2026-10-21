#!/usr/bin/env bash
set -eu
. bin/fm-classify-lib.sh
D="$PWD/.test-tmp/decision-live"
mkdir -p "$D"
f="$D/task.status"
printf 'kind=ship\n' > "$D/task.meta"
printf 'needs-decision [key=design]: choose blue\n' > "$f"
expected=$'design\tneeds-decision\tchoose blue'
out=$(status_open_decisions_peek "$f")
[ "$out" = "$expected" ]
cf=$(_fm_open_decisions_cursor_path "$f")
[ ! -e "$cf" ]
printf 'Peek with no saved cursor: %s; cursor absent\n' "$out"
status_open_decisions_incremental "$f" >/dev/null
cp "$cf" "$D/before"
printf 'resolved [key=design]: blue selected\nneeds-decision [key=ship]: release now\nneeds-decision [key=remote-reply-continuity-x]: transport\nneeds-decision [key=captain-hold-x]: held\n' >> "$f"
for i in 1 2 3; do
 out=$(status_own_open_decisions "$f")
 [ "$out" = $'ship\tneeds-decision\trelease now' ]
 cmp "$cf" "$D/before"
done
printf 'Repeated own-decision peek after appends: %s; saved cursor byte-identical; reserved keys excluded\n' "$out"
status_open_decisions_incremental "$f" >/dev/null
! cmp -s "$cf" "$D/before"
printf 'Ordinary drain subsequently advances cursor:\n'
cat "$cf"
cp "$cf" "$D/before"
printf 'needs-decision [key=new]: rotated record\n' > "$D/replacement"
mv "$D/replacement" "$f"
out=$(status_open_decisions_peek "$f")
[ "$out" = $'new\tneeds-decision\trotated record' ]
cmp "$cf" "$D/before"
printf 'Rotated log peek: %s; old cursor still byte-identical\n' "$out"
. bin/fm-pending-reply-lib.sh
mkdir -p "$D/parent/state"
H="$D/parent"; S="$H/state"
export FM_PENDING_REPLY_NOW=1000
a=$(fm_pending_reply_create "$H" "$S" mate 'Please inspect A')
b=$(fm_pending_reply_create "$H" "$S" mate 'Please inspect B')
fm_pending_reply_mark_delivered "$S" "$a"
fm_pending_reply_mark_delivered "$S" "$b"
printf 'done [corr=%s,%s]: answered both\n' "$a" "$b" > "$S/mate.status"
fm_pending_reply_try_resolve "$S" "$a"
fm_pending_reply_try_resolve "$S" "$b"
printf 'Comma-list acknowledgement resolved records: %s=%s %s=%s\n' "$a" "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$a")" phase)" "$b" "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$b")" phase)"
c=$(fm_pending_reply_create "$H" "$S" mate 'Correction to prior FYI')
r=$(fm_pending_reply_create "$H" "$S" mate 'Please make a decision')
export FM_PENDING_REPLY_NOW=8199
! fm_pending_reply_try_resolve "$S" "$c"
export FM_PENDING_REPLY_NOW=8200
fm_pending_reply_try_resolve "$S" "$c"
[ "$(fm_pending_reply_get "$(fm_pending_reply_path "$S" "$c")" resolved_via)" = expired-one-way ]
! fm_pending_reply_try_resolve "$S" "$r"
printf 'One-way notice expires at 7200 seconds as expired-one-way; reply-bearing request remains awaiting_report\n'
