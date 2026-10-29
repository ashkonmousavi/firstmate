#!/usr/bin/env bash
set -eu
export RING_ROOT="$PWD" RING_LAB_SESSION=fm-lab-ring-reasons-01m64 RING_ORIGINAL_PATH="$PATH"
export TMPDIR="$PWD/.tmp-ring-validation" FM_HERDR_LAB_STATE_DIR="$PWD/.tmp-ring-validation/herdr-state"
export PATH="$PWD/.tmp-ring-validation/bin:$PATH" FM_HOME="$(cat .tmp-ring-validation/lab-home)"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
. bin/fm-task-inbox-lib.sh
fm_backend_source herdr
rec=$(fm_task_inbox_write "$FM_HOME/state" ring-check 'Live validation payload; do not execute project changes.')
cp "$rec" "$FM_HOME/original.msg"
target="$RING_LAB_SESSION:w1:p1"
run_ring() {
  local name=$1 expected_rc=$2 expected_token=$3 record=${4:-$rec} endpoint=${5:-$target} rc=0 output
  output="$FM_HOME/ring-stdout"
  fm_task_inbox_ring herdr "$endpoint" "$record" > "$output" || rc=$?
  printf '%s: rc=%s token=%s stdout_bytes=%s sibling=%s\n' "$name" "$rc" "$FM_TASK_INBOX_RING_REASON" "$(wc -c < "$output")" "$(cat "${record%.msg}.ring-reason")"
  [ "$rc" = "$expected_rc" ] && [ "$FM_TASK_INBOX_RING_REASON" = "$expected_token" ] && [ ! -s "$output" ]
  [ "$(cat "${record%.msg}.ring-reason")" = "rc=$expected_rc token=$expected_token" ]
}
printf 'Live Claude native state: %s\n' "$(fm_backend_agent_state herdr "$target")"
# A real invalid sink path; the actual backend must refuse before typing.
FM_COMPOSER_DIALOG_SINK="$FM_HOME/no-such-dir/dialog"
run_ring dialog-sink-failure 2 dialog-sink-failed
FM_COMPOSER_DIALOG_SINK=
cmp "$rec" "$FM_HOME/original.msg"
# Non-printable inbox component must be refused before input reaches Claude.
bad_dir="$FM_HOME/state/"$'unsafe\nname.inbox'
mkdir -p "$bad_dir"; cp "$rec" "$bad_dir/001.msg"
run_ring unsafe-inbox-name 2 doorbell-rejected "$bad_dir/001.msg"
# A live real Claude composer containing a human's unsent draft is protected.
fm_backend_herdr_send_literal "$target" 'PRESERVE THIS FOREIGN DRAFT' >/dev/null
run_ring foreign-draft 1 foreign-pending-draft
held=$(fm_backend_herdr_composer_content "$target")
printf 'Composer preserved: %s\n' "$held"
case "$held" in *'PRESERVE THIS FOREIGN DRAFT'*) ;; *) exit 1 ;; esac
cmp "$rec" "$FM_HOME/original.msg"
fm_backend_send_key herdr "$target" C-u >/dev/null
# Sibling write failure cannot change a ring's result or the message body.
rm -f "${rec%.msg}.ring-reason"; mkdir "${rec%.msg}.ring-reason"
rc=0; fm_task_inbox_ring herdr "$RING_LAB_SESSION:w999:p999" "$rec" || rc=$?
printf 'Missing endpoint with unwritable reason sibling: rc=%s token=%s\n' "$rc" "$FM_TASK_INBOX_RING_REASON"
[ "$rc" = 3 ] && [ "$FM_TASK_INBOX_RING_REASON" = agent-dead ]
rmdir "${rec%.msg}.ring-reason"
run_ring missing-endpoint 3 agent-dead "$rec" "$RING_LAB_SESSION:w999:p999"
cmp "$rec" "$FM_HOME/original.msg"
printf 'All live checks preserved the original .msg bytes.\n'
